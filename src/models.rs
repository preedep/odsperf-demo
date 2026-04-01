use chrono::NaiveDate;
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};

// ─────────────────────────────────────────────────────────────────────────────
// Request
// ─────────────────────────────────────────────────────────────────────────────

/// POST body for both /v1/query-pg and /v1/query-mongo
#[derive(Debug, Deserialize)]
pub struct QueryRequest {
    /// Account number — max 11 characters
    pub account_no:  String,
    /// Start month  1–12
    pub start_month: u32,
    /// Start year   e.g. 2025
    pub start_year:  i32,
    /// End month    1–12
    pub end_month:   u32,
    /// End year     e.g. 2025
    pub end_year:    i32,
}

impl QueryRequest {
    /// Validate and return (start_date, end_date) — inclusive date range
    pub fn date_range(&self) -> Result<(NaiveDate, NaiveDate), String> {
        if self.account_no.trim().is_empty() {
            return Err("account_no must not be empty".into());
        }
        if self.account_no.len() > 11 {
            return Err("account_no max length is 11".into());
        }
        if !(1..=12).contains(&self.start_month) || !(1..=12).contains(&self.end_month) {
            return Err("month must be between 1 and 12".into());
        }

        let start = NaiveDate::from_ymd_opt(self.start_year, self.start_month, 1)
            .ok_or("invalid start date")?;

        // last day of end_month
        let end = if self.end_month == 12 {
            NaiveDate::from_ymd_opt(self.end_year + 1, 1, 1)
        } else {
            NaiveDate::from_ymd_opt(self.end_year, self.end_month + 1, 1)
        }
        .ok_or("invalid end date")?
        .pred_opt()
        .ok_or("date overflow")?;

        if start > end {
            return Err("start date must not be after end date".into());
        }
        Ok((start, end))
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// PostgreSQL row model
// ─────────────────────────────────────────────────────────────────────────────

#[derive(Debug, sqlx::FromRow)]
pub struct PgTransaction {
    pub iacct:       String,
    pub drun:        NaiveDate,
    pub cseq:        i32,
    pub dtrans:      Option<NaiveDate>,
    pub ddate:       NaiveDate,
    pub ttime:       Option<String>,
    pub cmnemo:      Option<String>,
    pub cchannel:    Option<String>,
    pub ctr:         Option<String>,
    pub cbr:         Option<String>,
    pub cterm:       Option<String>,
    pub camt:        Option<String>,
    pub aamount:     Option<Decimal>,
    pub abal:        Option<Decimal>,
    pub description: Option<String>,
    pub time_hms:    Option<String>,
}

// ─────────────────────────────────────────────────────────────────────────────
// MongoDB document model
// ─────────────────────────────────────────────────────────────────────────────

#[derive(Debug, serde::Deserialize)]
pub struct MongoTransaction {
    pub iacct:       String,
    pub drun:        bson::DateTime,
    pub cseq:        i32,
    pub dtrans:      Option<bson::DateTime>,
    pub ddate:       bson::DateTime,
    pub ttime:       Option<String>,
    pub cmnemo:      Option<String>,
    pub cchannel:    Option<String>,
    pub ctr:         Option<String>,
    pub cbr:         Option<String>,
    pub cterm:       Option<String>,
    pub camt:        Option<String>,
    pub aamount:     Option<bson::Decimal128>,
    pub abal:        Option<bson::Decimal128>,
    pub description: Option<String>,
    pub time_hms:    Option<String>,
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared DTO — serialized in API response
// ─────────────────────────────────────────────────────────────────────────────

#[derive(Debug, Serialize)]
pub struct TransactionDto {
    pub iacct:                               String,
    pub drun:                                String,
    pub cseq:                                i32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub dtrans:                              Option<String>,
    pub ddate:                               String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ttime:                               Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cmnemo:                              Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cchannel:                            Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ctr:                                 Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cbr:                                 Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cterm:                               Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub camt:                                Option<String>,
    /// Amount serialized as string to preserve NUMERIC(13,2) precision
    #[serde(skip_serializing_if = "Option::is_none")]
    pub aamount:                             Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub abal:                                Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description:                         Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub time_hms:                            Option<String>,
}

impl From<PgTransaction> for TransactionDto {
    fn from(t: PgTransaction) -> Self {
        let fmt = |d: NaiveDate| d.format("%Y-%m-%d").to_string();
        // CHAR columns from PostgreSQL are right-padded with spaces — trim them
        let trim = |s: Option<String>| s.map(|v| v.trim().to_string()).filter(|v| !v.is_empty());
        Self {
            iacct:       t.iacct.trim().to_string(),
            drun:        fmt(t.drun),
            cseq:        t.cseq,
            dtrans:      t.dtrans.map(fmt),
            ddate:       fmt(t.ddate),
            ttime:       trim(t.ttime),
            cmnemo:      trim(t.cmnemo),
            cchannel:    trim(t.cchannel),
            ctr:         trim(t.ctr),
            cbr:         trim(t.cbr),
            cterm:       trim(t.cterm),
            camt:        trim(t.camt),
            aamount:     t.aamount.map(|d| d.to_string()),
            abal:        t.abal.map(|d| d.to_string()),
            description: trim(t.description),
            time_hms:    trim(t.time_hms),
        }
    }
}

impl From<MongoTransaction> for TransactionDto {
    fn from(t: MongoTransaction) -> Self {
        let fmt_bson = |d: bson::DateTime| -> String {
            d.to_chrono().format("%Y-%m-%d").to_string()
        };
        Self {
            iacct:       t.iacct,
            drun:        fmt_bson(t.drun),
            cseq:        t.cseq,
            dtrans:      t.dtrans.map(fmt_bson),
            ddate:       fmt_bson(t.ddate),
            ttime:       t.ttime,
            cmnemo:      t.cmnemo,
            cchannel:    t.cchannel,
            ctr:         t.ctr,
            cbr:         t.cbr,
            cterm:       t.cterm,
            camt:        t.camt,
            aamount:     t.aamount.map(|d| d.to_string()),
            abal:        t.abal.map(|d| d.to_string()),
            description: t.description,
            time_hms:    t.time_hms,
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// API Response
// ─────────────────────────────────────────────────────────────────────────────

#[derive(Debug, Serialize)]
pub struct QueryResponse {
    pub request_id: String,
    pub db:         String,
    pub account_no: String,
    pub period:     Period,
    pub total:      usize,
    /// Query + serialization time in milliseconds
    pub elapsed_ms: u128,
    pub data:       Vec<TransactionDto>,
}

#[derive(Debug, Serialize)]
pub struct Period {
    pub from: String, // "YYYY-MM"
    pub to:   String, // "YYYY-MM"
}
