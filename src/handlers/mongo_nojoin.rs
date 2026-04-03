use std::sync::Arc;
use std::time::Instant;

use axum::{
    Json,
    extract::State,
    http::HeaderMap,
};
use bson::doc;
use chrono::{TimeZone, Utc};
use tracing::{info, instrument};

use crate::{
    error::AppError,
    models::{
        MongoFinalStatement, Period, QueryRequest, QueryMongoNoJoinResponse,
        TransactionDto, AccountMasterDto,
    },
    state::AppState,
};

const COLLECTION: &str = "final_statements";

/// POST /v1/query-mongo-nojoin
///
/// Query `final_statements` collection in MongoDB for a given account.
/// This collection contains account master data with embedded statements array.
/// Filters statements by dtrans date range.
#[instrument(
    name  = "query_mongo_nojoin",
    skip(state, headers, body),
    fields(
        db         = "mongodb",
        account_no = %body.account_no,
        start      = %format!("{}-{:02}", body.start_year, body.start_month),
        end        = %format!("{}-{:02}", body.end_year,   body.end_month),
    )
)]
pub async fn handle(
    State(state): State<Arc<AppState>>,
    headers:      HeaderMap,
    Json(body):   Json<QueryRequest>,
) -> Result<Json<QueryMongoNoJoinResponse>, AppError> {
    let request_id = extract_request_id(&headers);

    // ── Validate date range ──────────────────────────────────────────────
    let (start, end) = body
        .date_range()
        .map_err(AppError::BadRequest)?;

    // Convert NaiveDate → BSON DateTime (UTC midnight)
    let bson_start = bson::DateTime::from_chrono(
        Utc.from_utc_datetime(&start.and_hms_opt(0, 0, 0).unwrap()),
    );
    let bson_end = bson::DateTime::from_chrono(
        Utc.from_utc_datetime(&end.and_hms_opt(23, 59, 59).unwrap()),
    );

    info!(
        request_id = %request_id,
        start_date = %start,
        end_date   = %end,
        "executing MongoDB no-join query"
    );

    let timer = Instant::now();

    // ── Query ────────────────────────────────────────────────────────────
    let collection = state
        .mongo
        .collection::<MongoFinalStatement>(COLLECTION);

    // Find document by account number
    let filter = doc! {
        "iacct": &body.account_no,
    };

    let doc = collection
        .find_one(filter)
        .await
        .map_err(|e| {
            metrics::counter!("db_errors_total",
                "database" => "mongodb",
                "operation" => "find_one"
            ).increment(1);
            e
        })?
        .ok_or_else(|| AppError::NotFound(format!("Account {} not found", body.account_no)))?;

    // Extract account info
    let account_no = doc.iacct.clone();
    let account_dto = AccountMasterDto::from(MongoFinalStatement {
        iacct:        doc.iacct.clone(),
        custid:       doc.custid.clone(),
        ctype:        doc.ctype.clone(),
        dopen:        doc.dopen,
        dclose:       doc.dclose,
        cstatus:      doc.cstatus.clone(),
        cbranch:      doc.cbranch.clone(),
        segment:      doc.segment.clone(),
        credit_limit: doc.credit_limit,
        dtrans:       doc.dtrans,
        statements:   vec![],
    });

    // Filter statements by dtrans date range
    let filtered_statements: Vec<TransactionDto> = doc
        .statements
        .into_iter()
        .filter(|stmt| {
            if let Some(dtrans) = stmt.dtrans {
                dtrans >= bson_start && dtrans <= bson_end
            } else {
                false
            }
        })
        .map(|stmt| {
            let mut dto = TransactionDto::from(stmt);
            dto.iacct = account_no.clone();
            dto
        })
        .collect();

    let total = filtered_statements.len();
    let elapsed = timer.elapsed();
    let elapsed_ms = elapsed.as_millis();

    // Histogram: query duration
    metrics::histogram!("db_query_duration_seconds",
        "database" => "mongodb",
        "operation" => "find_one_nojoin"
    ).record(elapsed.as_secs_f64());

    // Counter: successful queries
    metrics::counter!("db_queries_total",
        "database" => "mongodb",
        "operation" => "find_one_nojoin"
    ).increment(1);

    info!(
        request_id = %request_id,
        total      = total,
        elapsed_ms = elapsed_ms,
        "MongoDB no-join query complete"
    );

    Ok(Json(QueryMongoNoJoinResponse {
        request_id,
        db:         "mongodb-nojoin".to_string(),
        account_no: body.account_no,
        period:     Period {
            from: format!("{}-{:02}", body.start_year, body.start_month),
            to:   format!("{}-{:02}", body.end_year,   body.end_month),
        },
        total,
        elapsed_ms,
        account:    account_dto,
        statements: filtered_statements,
    }))
}

fn extract_request_id(headers: &HeaderMap) -> String {
    headers
        .get("x-request-id")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("-")
        .to_string()
}
