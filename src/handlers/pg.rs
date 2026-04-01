use std::sync::Arc;
use std::time::Instant;

use axum::{
    Json,
    extract::State,
    http::HeaderMap,
};
use tracing::{info, instrument};

use crate::{
    error::AppError,
    models::{PgTransaction, Period, QueryRequest, QueryResponse, TransactionDto},
    state::AppState,
};

/// POST /v1/query-pg
///
/// Query `odsperf.account_transaction` in PostgreSQL for a given account
/// and month/year range. Returns matching transactions ordered by
/// `dtrans ASC, cseq ASC`.
#[instrument(
    name  = "query_pg",
    skip(state, headers, body),
    fields(
        db         = "postgresql",
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

    info!(
        request_id = %request_id,
        start_date = %start,
        end_date   = %end,
        "executing PostgreSQL query"
    );

    let timer = Instant::now();

    // ── Query ────────────────────────────────────────────────────────────
    let rows: Vec<PgTransaction> = sqlx::query_as(
        r#"
        SELECT
            iacct, drun, cseq, dtrans, ddate,
            ttime, cmnemo, cchannel, ctr, cbr,
            cterm, camt, aamount, abal,
            description, time_hms
        FROM odsperf.account_transaction
        WHERE iacct  = $1
          AND dtrans >= $2
          AND dtrans <= $3
        ORDER BY dtrans ASC NULLS LAST, cseq ASC
        "#,
    )
    .bind(&body.account_no)
    .bind(start)
    .bind(end)
    .fetch_all(&state.pg)
    .await?;

    let elapsed_ms = timer.elapsed().as_millis();
    let total      = rows.len();

    info!(
        request_id = %request_id,
        total      = total,
        elapsed_ms = elapsed_ms,
        "PostgreSQL query complete"
    );

    let data: Vec<TransactionDto> = rows.into_iter().map(TransactionDto::from).collect();

    Ok(Json(QueryResponse {
        request_id,
        db:         "postgresql".to_string(),
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
