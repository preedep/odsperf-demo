// =============================================================================
// generate_account_csv — Generate mock account master data → CSV
//
// Generates the ACCOUNT_POOL used by generate_csv so that transactions
// reference valid account numbers (enables JOIN testing).
//
// Account pool: ACCOUNT_POOL_SIZE accounts with iacct starting at
//   10_000_000_000 (11-digit, same namespace as generate_csv pool).
//
// Output: data/mock_accounts.csv (10,000 rows by default)
// Usage:
//   cargo run --release --bin generate_account_csv
//   ACCOUNT_OUTPUT_PATH=data/mock_accounts.csv ACCOUNT_POOL_SIZE=10000 \
//     cargo run --release --bin generate_account_csv
// =============================================================================

use anyhow::Result;
use chrono::NaiveDate;
use csv::Writer;
use rand::prelude::*;
use rust_decimal::Decimal;
use std::env;
use std::fs;
use std::path::Path;
use std::time::Instant;

// ─── Pool config (must match generate_csv) ───────────────────────────────────
pub const ACCOUNT_BASE: u64 = 10_000_000_000;

fn main() -> Result<()> {
    let output_path = env::var("ACCOUNT_OUTPUT_PATH")
        .unwrap_or_else(|_| "data/mock_accounts.csv".to_string());

    let pool_size: usize = env::var("ACCOUNT_POOL_SIZE")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(10_000);

    println!("🚀 Mock Account Master CSV Generator");
    println!("📊 Pool size : {} accounts", pool_size);
    println!("📋 iacct pool: {} → {}", ACCOUNT_BASE, ACCOUNT_BASE + pool_size as u64 - 1);
    println!("📁 Output    : {}", output_path);

    // Create output directory if needed
    if let Some(parent) = Path::new(&output_path).parent() {
        fs::create_dir_all(parent)?;
    }

    let mut wtr = Writer::from_path(&output_path)?;

    // Header — matches account_master columns in both DBs
    wtr.write_record([
        "iacct", "custid", "ctype", "dopen", "dclose",
        "cstatus", "cbranch", "segment", "credit_limit",
    ])?;

    let mut rng = thread_rng();
    let start = Instant::now();

    // Generate one row per account in pool (sequential iacct)
    for i in 0..pool_size {
        let iacct = format!("{:011}", ACCOUNT_BASE + i as u64);
        let row = generate_row(&iacct, &mut rng);
        wtr.write_record(&row)?;
    }

    wtr.flush()?;

    let elapsed = start.elapsed();
    let size_kb = fs::metadata(&output_path)?.len() as f64 / 1_024.0;

    println!("\n✅ Done!");
    println!("📊 Accounts : {}", pool_size);
    println!("📁 File     : {} ({:.1} KB)", output_path, size_kb);
    println!("⏱️  Time     : {:.3}s", elapsed.as_secs_f64());

    Ok(())
}

// ─── Row generator ────────────────────────────────────────────────────────────
fn generate_row(iacct: &str, rng: &mut ThreadRng) -> [String; 9] {
    // Customer ID: 10-char alphanumeric (CUS + 7 digits)
    let custid = format!("CUS{:07}", rng.gen_range(1u32..=9_999_999u32));

    // Account type
    let ctypes = ["SAV", "CHK", "CUR", "FXD"];
    let ctype = ctypes[rng.gen_range(0..ctypes.len())];

    // Open date: between 2015-01-01 and 2024-12-31 (account pre-dates transactions)
    let open_start = NaiveDate::from_ymd_opt(2015, 1, 1).unwrap();
    let open_end   = NaiveDate::from_ymd_opt(2024, 12, 31).unwrap();
    let open_days  = (open_end - open_start).num_days();
    let dopen = open_start + chrono::Duration::days(rng.gen_range(0..=open_days));

    // Status & close date
    // 75% ACTV, 15% INAC, 10% CLSD
    let status_roll: u8 = rng.gen_range(0..100);
    let (cstatus, dclose) = if status_roll < 75 {
        ("ACTV", String::new())
    } else if status_roll < 90 {
        ("INAC", String::new())
    } else {
        // Closed: close date after open date, before today
        let close_start = dopen + chrono::Duration::days(30);
        let close_end   = NaiveDate::from_ymd_opt(2025, 6, 30).unwrap();
        if close_start < close_end {
            let close_days = (close_end - close_start).num_days();
            let dclose_date = close_start + chrono::Duration::days(rng.gen_range(0..=close_days));
            ("CLSD", dclose_date.format("%Y-%m-%d").to_string())
        } else {
            ("CLSD", close_end.format("%Y-%m-%d").to_string())
        }
    };

    // Branch: 4-digit (same format as cbr in transactions)
    let cbranch = format!("{:04}", rng.gen_range(1u32..=9999u32));

    // Customer segment
    // 60% RETAIL, 25% SME, 10% CORP, 5% PRIV
    let seg_roll: u8 = rng.gen_range(0..100);
    let segment = if seg_roll < 60 {
        "RETAIL"
    } else if seg_roll < 85 {
        "SME"
    } else if seg_roll < 95 {
        "CORP"
    } else {
        "PRIV"
    };

    // Credit limit — NULL for ~40% (SAV accounts often have no credit limit)
    let credit_limit = if ctype == "SAV" && rng.gen_bool(0.4) || rng.gen_bool(0.2) {
        String::new() // empty = NULL
    } else {
        // Credit limit bands by segment
        let limit_cents: i64 = match segment {
            "PRIV" => rng.gen_range(5_000_000_00i64..=50_000_000_00i64),  // 5M–50M
            "CORP" => rng.gen_range(1_000_000_00i64..=20_000_000_00i64),  // 1M–20M
            "SME"  => rng.gen_range(200_000_00i64..=5_000_000_00i64),     // 200K–5M
            _      => rng.gen_range(10_000_00i64..=500_000_00i64),        // 10K–500K
        };
        format!("{:.2}", Decimal::new(limit_cents, 2))
    };

    [
        iacct.to_string(),
        custid,
        ctype.to_string(),
        dopen.format("%Y-%m-%d").to_string(),
        dclose,
        cstatus.to_string(),
        cbranch,
        segment.to_string(),
        credit_limit,
    ]
}
