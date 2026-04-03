use std::sync::Arc;
use std::time::Instant;

use axum::{
    Json,
    extract::State,
    http::HeaderMap,
};
use bson::doc;
use chrono::{TimeZone, Utc};
use futures_util::TryStreamExt;
use tracing::{info, instrument};

use crate::{
    error::AppError,
    models::{MongoTransaction, Period, QueryRequest, QueryResponse, TransactionDto},
    state::AppState,
};

const COLLECTION: &str = "account_transaction";

/// POST /v1/query-mongo
///
/// Query `account_transaction` collection in MongoDB for a given account
/// and month/year range. Matches on `dtrans` field, sorted by
/// `dtrans ASC, cseq ASC`.
#[instrument(
    name  = "query_mongo",
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
) -> Result<Json<QueryResponse>, AppError> {
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
        "executing MongoDB query"
    );

    let timer = Instant::now();

    // ── Query ────────────────────────────────────────────────────────────
    let collection = state
        .mongo
        .collection::<MongoTransaction>(COLLECTION);

    let filter = doc! {
        "iacct":  &body.account_no,
        "dtrans": { "$gte": bson_start, "$lte": bson_end }
    };

    let sort = doc! { "dtrans": 1, "cseq": 1 };

    let cursor = collection
        .find(filter)
        .sort(sort)
        .await
        .map_err(|e| {
            // Counter: database errors
            metrics::counter!("db_errors_total",
                "database" => "mongodb",
                "operation" => "find"
            ).increment(1);
            e
        })?;

    let rows: Vec<MongoTransaction> = cursor.try_collect().await
        .map_err(|e| {
            metrics::counter!("db_errors_total",
                "database" => "mongodb",
                "operation" => "collect"
            ).increment(1);
            e
        })?;

    let elapsed = timer.elapsed();
    let elapsed_ms = elapsed.as_millis();
    let total = rows.len();
    
    // Histogram: query duration
    metrics::histogram!("db_query_duration_seconds",
        "database" => "mongodb",
        "operation" => "find"
    ).record(elapsed.as_secs_f64());
    
    // Counter: successful queries
    metrics::counter!("db_queries_total",
        "database" => "mongodb",
        "operation" => "find"
    ).increment(1);

    info!(
        request_id = %request_id,
        total      = total,
        elapsed_ms = elapsed_ms,
        "MongoDB query complete"
    );

    let data: Vec<TransactionDto> = rows.into_iter().map(TransactionDto::from).collect();

    Ok(Json(QueryResponse {
        request_id,
        db:         "mongodb".to_string(),
        account_no: body.account_no,
        period:     Period {
            from: format!("{}-{:02}", body.start_year, body.start_month),
            to:   format!("{}-{:02}", body.end_year,   body.end_month),
        },
        total,
        elapsed_ms,
        data,
    }))
}

fn extract_request_id(headers: &HeaderMap) -> String {
    headers
        .get("x-request-id")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("-")
        .to_string()
}
