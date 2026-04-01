// =============================================================================
// generate_csv — Generate mock transaction data → CSV
// No database dependency. Run this first, then load_pg / load_mongo.
//
// Output: data/mock_transactions.csv (1,000,000 rows)
// Usage:
//   cargo run --release --bin generate_csv
//   OUTPUT_PATH=data/custom.csv TOTAL_RECORDS=500000 cargo run --release --bin generate_csv
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

fn main() -> Result<()> {
    let output_path = env::var("OUTPUT_PATH")
        .unwrap_or_else(|_| "data/mock_transactions.csv".to_string());

    let total_records: usize = env::var("TOTAL_RECORDS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(1_000_000);

    println!("🚀 Mock Transaction CSV Generator");
    println!("📊 Target  : {} records", total_records);
    println!("📁 Output  : {}", output_path);

    // Create output directory if needed
    if let Some(parent) = Path::new(&output_path).parent() {
        fs::create_dir_all(parent)?;
    }

    let mut wtr = Writer::from_path(&output_path)?;

    // Header — matches column order of account_transaction in both DBs
    wtr.write_record([
        "iacct", "drun", "cseq", "ddate", "dtrans",
        "ttime", "cmnemo", "cchannel", "ctr", "cbr",
        "cterm", "camt", "aamount", "abal", "description", "time_hms",
    ])?;

    let mut rng = thread_rng();
    let start = Instant::now();
    let log_every = total_records / 10; // log every 10%

    for i in 0..total_records {
        let row = generate_row(&mut rng);
        wtr.write_record(&row)?;

        if log_every > 0 && (i + 1) % log_every == 0 {
            let pct = (i + 1) * 100 / total_records;
            let elapsed = start.elapsed().as_secs_f64();
            let speed = (i + 1) as f64 / elapsed;
            println!(
                "  {:>3}% | {:>9} rows | {:.1}s elapsed | {:.0} rows/s",
                pct, i + 1, elapsed, speed
            );
        }
    }

    wtr.flush()?;

    let elapsed = start.elapsed();
    let size_mb = fs::metadata(&output_path)?.len() as f64 / 1_048_576.0;

    println!("\n✅ Done!");
    println!("📊 Records  : {}", total_records);
    println!("📁 File     : {} ({:.1} MB)", output_path, size_mb);
    println!("⏱️  Time     : {:.2}s", elapsed.as_secs_f64());
    println!(
        "⚡ Speed    : {:.0} rows/s",
        total_records as f64 / elapsed.as_secs_f64()
    );

    Ok(())
}

// ─── Row generator (same logic across PG + Mongo loaders) ────────────────────
fn generate_row(rng: &mut ThreadRng) -> [String; 16] {
    let start_date = NaiveDate::from_ymd_opt(2025, 1, 1).unwrap();
    let end_date   = NaiveDate::from_ymd_opt(2025, 12, 31).unwrap();
    let days       = (end_date - start_date).num_days();

    let dtrans = start_date + chrono::Duration::days(rng.gen_range(0..=days));
    let drun   = dtrans + chrono::Duration::days(rng.gen_range(0..=3));
    let ddate  = dtrans;

    let iacct  = format!("{:011}", rng.gen_range(10_000_000_000u64..=99_999_999_999u64));
    let cseq   = rng.gen_range(1u32..=9999u32);

    let hour   = rng.gen_range(8u32..18u32);
    let minute = rng.gen_range(0u32..60u32);
    let second = rng.gen_range(0u32..60u32);
    let ttime    = format!("{:02}:{:02}", hour, minute);
    let time_hms = format!("{:02}:{:02}:{:02}", hour, minute, second);

    let mnemonics = ["DEP", "WDL", "TRF", "CHQ", "FEE", "INT", "ATM", "POS"];
    let cmnemo = mnemonics[rng.gen_range(0..mnemonics.len())];

    let channels = ["ATM", "INET", "MOB", "BRNC"];
    let cchannel = channels[rng.gen_range(0..channels.len())];

    let ctr   = format!("{:02}", rng.gen_range(1u32..99u32));
    let cbr   = format!("{:04}", rng.gen_range(1u32..9999u32));
    let cterm = format!("{:05}", rng.gen_range(1u32..99999u32));

    let camt   = if rng.gen_bool(0.5) { "C" } else { "D" };
    let aamount = Decimal::new(rng.gen_range(100i64..1_000_000i64), 2);
    let abal    = Decimal::new(rng.gen_range(1_000i64..10_000_000i64), 2);

    let descriptions = [
        "SALARY PAYMENT", "ATM WITHDRAWAL", "TRANSFER OUT",
        "TRANSFER IN",    "BILL PAYMENT",   "INTEREST CREDIT",
        "SERVICE FEE",    "LOAN PAYMENT",   "DEPOSIT", "PURCHASE",
    ];
    let description = descriptions[rng.gen_range(0..descriptions.len())];

    [
        iacct,
        drun.format("%Y-%m-%d").to_string(),
        cseq.to_string(),
        ddate.format("%Y-%m-%d").to_string(),
        dtrans.format("%Y-%m-%d").to_string(),
        ttime,
        cmnemo.to_string(),
        cchannel.to_string(),
        ctr,
        cbr,
        cterm,
        camt.to_string(),
        format!("{:.2}", aamount),
        format!("{:.2}", abal),
        description.to_string(),
        time_hms,
    ]
}
