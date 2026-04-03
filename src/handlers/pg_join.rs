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
    models::{
        AccountMasterDto, AccountWithStatementsDto, Period, PgAccountMaster, PgTransaction,
        QueryJoinResponse, QueryRequest, TransactionDto,
    },
    state::AppState,
};

/// POST /v1/query-pg-join
///
/// Query `odsperf.account_transaction` JOIN `odsperf.account_master` in PostgreSQL
/// for a given account and month/year range. Returns account info with matching
/// transactions ordered by `dtrans ASC, cseq ASC`.
#[instrument(
    name  = "query_pg_join",
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
) -> Result<Json<QueryJoinResponse>, AppError> {
    let request_id = extract_request_id(&headers);

    // ── Validate date range ──────────────────────────────────────────────
    let (start, end) = body
        .date_range()
        .map_err(AppError::BadRequest)?;

    info!(
        request_id = %request_id,
        start_date = %start,
        end_date   = %end,
        "executing PostgreSQL JOIN query"
    );

    let timer = Instant::now();

    // ── Query Account Master ─────────────────────────────────────────────
    let account: Option<PgAccountMaster> = sqlx::query_as(
        r#"
        SELECT
            iacct, custid, ctype, dopen, dclose,
            cstatus, cbranch, segment, credit_limit
        FROM odsperf.account_master
        WHERE iacct = $1
        "#,
    )
    .bind(&body.account_no)
    .fetch_optional(&state.pg)
    .await?;

    // Return error if account not found
    let account = account.ok_or_else(|| {
        AppError::NotFound(format!("Account {} not found", body.account_no))
    })?;

    // ── Query Transactions ───────────────────────────────────────────────
    let rows: Vec<PgTransaction> = sqlx::query_as(
        r#"
        SELECT
            t.iacct, t.drun, t.cseq, t.dtrans, t.ddate,
            t.ttime, t.cmnemo, t.cchannel, t.ctr, t.cbr,
            t.cterm, t.camt, t.aamount, t.abal,
            t.description, t.time_hms
        FROM odsperf.account_transaction t
        WHERE t.iacct  = $1
          AND t.dtrans >= $2
          AND t.dtrans <= $3
        ORDER BY t.dtrans ASC NULLS LAST, t.cseq ASC
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
        "PostgreSQL JOIN query complete"
    );

    let statements: Vec<TransactionDto> = rows.into_iter().map(TransactionDto::from).collect();
    let account_dto: AccountMasterDto = account.into();

    Ok(Json(QueryJoinResponse {
        request_id,
        db:         "postgresql".to_string(),
        account_no: body.account_no,
        period:     Period {
            from: format!("{}-{:02}", body.start_year, body.start_month),
            to:   format!("{}-{:02}", body.end_year,   body.end_month),
        },
        total,
        elapsed_ms,
        data:       AccountWithStatementsDto {
            account: account_dto,
            statements,
        },
    }))
}

fn extract_request_id(headers: &HeaderMap) -> String {
    headers
        .get("x-request-id")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("-")
        .to_string()
}
