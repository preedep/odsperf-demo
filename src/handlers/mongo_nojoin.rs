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

/// Parse account master data from a BSON document
fn parse_account_master(doc: &bson::Document) -> Result<AccountMasterDto, AppError> {
    let iacct = doc.get_str("iacct")
        .map_err(|e| AppError::Internal(anyhow::anyhow!("Failed to parse iacct: {}", e)))?;
    
    Ok(AccountMasterDto {
        iacct:        iacct.to_string(),
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
    })
}

/// Parse a single statement from BSON document
fn parse_statement(stmt_doc: &bson::Document, account_no: &str) -> Option<TransactionDto> {
    let fmt_bson = |d: bson::DateTime| -> String {
        d.to_chrono().format("%Y-%m-%d").to_string()
    };
    
    let drun = stmt_doc.get_datetime("drun").ok().map(|d| fmt_bson(*d))?;
    let cseq = stmt_doc.get_i32("cseq").ok()?;
    let ddate = stmt_doc.get_datetime("ddate").ok().map(|d| fmt_bson(*d))?;
    
    Some(TransactionDto {
        iacct:       account_no.to_string(),
        drun,
        cseq,
        dtrans:      stmt_doc.get_datetime("dtrans").ok().map(|d| fmt_bson(*d)),
        ddate,
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
}

/// Parse statements array from a document
fn parse_statements_from_doc(doc: &bson::Document) -> Vec<TransactionDto> {
    let mut statements = Vec::new();
    
    if let Ok(statements_array) = doc.get_array("statements") {
        let account_no = doc.get_str("iacct").unwrap_or("");
        
        for stmt_bson in statements_array {
            if let bson::Bson::Document(stmt_doc) = stmt_bson {
                if let Some(stmt) = parse_statement(stmt_doc, account_no) {
                    statements.push(stmt);
                }
            }
        }
    }
    
    statements
}

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

    // ── Query with dtrans range filter ──────────────────────────────────
    // Query documents by account AND dtrans range
    // Each document = 1 account + 1 dtrans + statements for that day
    let collection = state
        .mongo
        .collection::<bson::Document>(COLLECTION);

    let filter = doc! {
        "iacct": &body.account_no,
        "dtrans": {
            "$gte": bson_start,
            "$lte": bson_end
        }
    };

    let mut cursor = collection.find(filter).await
        .map_err(|e| {
            metrics::counter!("db_errors_total",
                "database" => "mongodb",
                "operation" => "find"
            ).increment(1);
            e
        })?;

    // Collect all matching documents
    let mut all_statements = Vec::new();
    let mut account_dto: Option<AccountMasterDto> = None;
    
    while let Some(doc) = cursor.try_next().await.map_err(|e| {
        metrics::counter!("db_errors_total",
            "database" => "mongodb",
            "operation" => "cursor"
        ).increment(1);
        e
    })? {
        // Parse account info from first document
        if account_dto.is_none() {
            account_dto = Some(parse_account_master(&doc)?);
        }
        
        // Parse and collect statements from this document
        all_statements.extend(parse_statements_from_doc(&doc));
    }
    
    let account_dto = account_dto
        .ok_or_else(|| AppError::NotFound(format!("Account {} not found", body.account_no)))?;
    
    let total = all_statements.len();
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
        total,
        elapsed_ms,
        "MongoDB no-join query completed"
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
        statements: all_statements,
    }))
}

fn extract_request_id(headers: &HeaderMap) -> String {
    headers
        .get("x-request-id")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("-")
        .to_string()
}
