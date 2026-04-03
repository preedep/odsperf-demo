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

    // ── Query with Aggregation Pipeline ─────────────────────────────────
    // Use aggregation to filter statements at database level
    // This provides fair comparison with PostgreSQL JOIN query
    let collection = state
        .mongo
        .collection::<bson::Document>(COLLECTION);

    let pipeline = vec![
        // Match account
        doc! {
            "$match": {
                "iacct": &body.account_no
            }
        },
        // Filter statements by dtrans range
        doc! {
            "$project": {
                "iacct": 1,
                "custid": 1,
                "ctype": 1,
                "dopen": 1,
                "dclose": 1,
                "cstatus": 1,
                "cbranch": 1,
                "segment": 1,
                "credit_limit": 1,
                "dtrans": 1,
                "statements": {
                    "$filter": {
                        "input": "$statements",
                        "as": "stmt",
                        "cond": {
                            "$and": [
                                { "$gte": ["$$stmt.dtrans", bson_start] },
                                { "$lte": ["$$stmt.dtrans", bson_end] }
                            ]
                        }
                    }
                }
            }
        }
    ];

    let mut cursor = collection.aggregate(pipeline).await
        .map_err(|e| {
            metrics::counter!("db_errors_total",
                "database" => "mongodb",
                "operation" => "aggregate"
            ).increment(1);
            e
        })?;

    let doc = cursor.try_next().await
        .map_err(|e| {
            metrics::counter!("db_errors_total",
                "database" => "mongodb",
                "operation" => "aggregate"
            ).increment(1);
            e
        })?
        .ok_or_else(|| AppError::NotFound(format!("Account {} not found", body.account_no)))?;

    // Parse account info
    let account_no = doc.get_str("iacct")
        .map_err(|e| AppError::Internal(anyhow::anyhow!("Failed to parse iacct: {}", e)))?
        .to_string();
    
    let account_dto = AccountMasterDto {
        iacct:        account_no.clone(),
        custid:       doc.get_str("custid")
            .map_err(|e| AppError::Internal(anyhow::anyhow!("Failed to parse custid: {}", e)))?
            .to_string(),
        ctype:        doc.get_str("ctype")
            .map_err(|e| AppError::Internal(anyhow::anyhow!("Failed to parse ctype: {}", e)))?
            .to_string(),
        dopen:        doc.get_datetime("dopen")
            .map_err(|e| AppError::Internal(anyhow::anyhow!("Failed to parse dopen: {}", e)))?
            .to_chrono().format("%Y-%m-%d").to_string(),
        dclose:       doc.get_datetime("dclose").ok().map(|d| d.to_chrono().format("%Y-%m-%d").to_string()),
        cstatus:      doc.get_str("cstatus")
            .map_err(|e| AppError::Internal(anyhow::anyhow!("Failed to parse cstatus: {}", e)))?
            .to_string(),
        cbranch:      doc.get_str("cbranch")
            .map_err(|e| AppError::Internal(anyhow::anyhow!("Failed to parse cbranch: {}", e)))?
            .to_string(),
        segment:      doc.get_str("segment")
            .map_err(|e| AppError::Internal(anyhow::anyhow!("Failed to parse segment: {}", e)))?
            .to_string(),
        credit_limit: doc.get("credit_limit").and_then(|v| {
            if let bson::Bson::Decimal128(d) = v {
                Some(d.to_string())
            } else {
                None
            }
        }),
    };

    // Parse filtered statements
    let statements_array = doc.get_array("statements")
        .map_err(|e| AppError::Internal(anyhow::anyhow!("Failed to parse statements: {}", e)))?;
    let filtered_statements: Vec<TransactionDto> = statements_array
        .iter()
        .filter_map(|stmt_bson| {
            if let bson::Bson::Document(stmt_doc) = stmt_bson {
                let fmt_bson = |d: bson::DateTime| -> String {
                    d.to_chrono().format("%Y-%m-%d").to_string()
                };
                
                Some(TransactionDto {
                    iacct:       account_no.clone(),
                    drun:        stmt_doc.get_datetime("drun").ok().map(|d| fmt_bson(*d))?,
                    cseq:        stmt_doc.get_i32("cseq").ok()?,
                    dtrans:      stmt_doc.get_datetime("dtrans").ok().map(|d| fmt_bson(*d)),
                    ddate:       stmt_doc.get_datetime("ddate").ok().map(|d| fmt_bson(*d))?,
                    ttime:       stmt_doc.get_str("ttime").ok().map(|s| s.to_string()),
                    cmnemo:      stmt_doc.get_str("cmnemo").ok().map(|s| s.to_string()),
                    cchannel:    stmt_doc.get_str("cchannel").ok().map(|s| s.to_string()),
                    ctr:         stmt_doc.get_str("ctr").ok().map(|s| s.to_string()),
                    cbr:         stmt_doc.get_str("cbr").ok().map(|s| s.to_string()),
                    cterm:       stmt_doc.get_str("cterm").ok().map(|s| s.to_string()),
                    camt:        stmt_doc.get_str("camt").ok().map(|s| s.to_string()),
                    aamount:     stmt_doc.get("aamount").and_then(|v| {
                        if let bson::Bson::Decimal128(d) = v {
                            Some(d.to_string())
                        } else {
                            None
                        }
                    }),
                    abal:        stmt_doc.get("abal").and_then(|v| {
                        if let bson::Bson::Decimal128(d) = v {
                            Some(d.to_string())
                        } else {
                            None
                        }
                    }),
                    description: stmt_doc.get_str("description").ok().map(|s| s.to_string()),
                    time_hms:    stmt_doc.get_str("time_hms").ok().map(|s| s.to_string()),
                })
            } else {
                None
            }
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
