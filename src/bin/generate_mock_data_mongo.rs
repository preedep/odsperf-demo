use anyhow::Result;
use bson::{doc, Bson, DateTime as BsonDateTime, Decimal128};
use chrono::{TimeZone, Utc};
use chrono::NaiveDate;
use mongodb::{options::ClientOptions, Client};
use rand::prelude::*;
use rust_decimal::Decimal;
use std::env;
use std::str::FromStr;
use std::time::Instant;

const TOTAL_RECORDS: usize = 1_000_000;
const BATCH_SIZE: usize = 5_000;

#[tokio::main]
async fn main() -> Result<()> {
    println!("🚀 Starting MongoDB Mock Data Generator");
    println!("📊 Target: {} records", TOTAL_RECORDS);
    println!("📦 Batch size: {}", BATCH_SIZE);

    let mongodb_uri = env::var("MONGODB_URI")
        .unwrap_or_else(|_| {
            "mongodb://odsuser:odspassword@localhost:27017/odsperf".to_string()
        });

    let mongodb_db = env::var("MONGODB_DB").unwrap_or_else(|_| "odsperf".to_string());

    println!("🔌 Connecting to MongoDB...");
    let client_options = ClientOptions::parse(&mongodb_uri).await?;
    let client = Client::with_options(client_options)?;

    // Ping to verify connection
    client
        .database(&mongodb_db)
        .run_command(doc! { "ping": 1 })
        .await?;
    println!("✅ Connected successfully");

    let db = client.database(&mongodb_db);
    let collection = db.collection::<bson::Document>("account_transaction");

    let start_time = Instant::now();
    let mut rng = thread_rng();
    let mut total_inserted: usize = 0;

    let num_batches = TOTAL_RECORDS / BATCH_SIZE;

    for batch_num in 0..num_batches {
        let batch_start = Instant::now();

        let mut docs = Vec::with_capacity(BATCH_SIZE);

        for _ in 0..BATCH_SIZE {
            docs.push(generate_random_document(&mut rng));
        }

        collection.insert_many(docs).await?;

        total_inserted += BATCH_SIZE;
        let batch_elapsed = batch_start.elapsed();
        let overall_elapsed = start_time.elapsed();
        let records_per_sec = total_inserted as f64 / overall_elapsed.as_secs_f64();

        println!(
            "✓ Batch {}/{} | Inserted: {:>7} | Batch time: {:.2}s | Total time: {:.2}s | Speed: {:.0} rec/s",
            batch_num + 1,
            num_batches,
            total_inserted,
            batch_elapsed.as_secs_f64(),
            overall_elapsed.as_secs_f64(),
            records_per_sec
        );
    }

    let total_elapsed = start_time.elapsed();
    println!("\n🎉 Data generation completed!");
    println!("📊 Total records inserted: {}", total_inserted);
    println!("⏱️  Total time: {:.2}s", total_elapsed.as_secs_f64());
    println!(
        "⚡ Average speed: {:.0} records/second",
        total_inserted as f64 / total_elapsed.as_secs_f64()
    );

    Ok(())
}

// ─── Helper: NaiveDate → bson::DateTime (UTC midnight) ───────────────────────
fn naive_date_to_bson(d: NaiveDate) -> BsonDateTime {
    let dt = Utc
        .from_utc_datetime(&d.and_hms_opt(0, 0, 0).unwrap());
    BsonDateTime::from_chrono(dt)
}

// ─── Helper: Decimal → bson::Decimal128 via string ────────────────────────────
fn decimal_to_bson(d: Decimal) -> Decimal128 {
    Decimal128::from_str(&format!("{:.2}", d)).expect("valid decimal string")
}

// ─── Document generator (same random logic as generate_mock_data.rs) ─────────
fn generate_random_document(rng: &mut ThreadRng) -> bson::Document {
    let start_date = NaiveDate::from_ymd_opt(2025, 1, 1).unwrap();
    let end_date   = NaiveDate::from_ymd_opt(2025, 12, 31).unwrap();
    let days_in_range = (end_date - start_date).num_days();

    let dtrans = start_date + chrono::Duration::days(rng.gen_range(0..=days_in_range));
    let drun   = dtrans + chrono::Duration::days(rng.gen_range(0..=3));
    let ddate  = dtrans;

    let iacct = format!("{:011}", rng.gen_range(10000000000u64..99999999999u64));
    let cseq  = rng.gen_range(1i32..=9999i32);

    let hour   = rng.gen_range(8u32..18u32);
    let minute = rng.gen_range(0u32..60u32);
    let second = rng.gen_range(0u32..60u32);
    let ttime    = format!("{:02}:{:02}", hour, minute);
    let time_hms = format!("{:02}:{:02}:{:02}", hour, minute, second);

    let mnemonics = ["DEP", "WDL", "TRF", "CHQ", "FEE", "INT", "ATM", "POS"];
    let cmnemo = mnemonics[rng.gen_range(0..mnemonics.len())].to_string();

    // MongoDB schema: cchannel maxLength=4, no padding (not CHAR fixed-width)
    let channels = ["ATM", "INET", "MOB", "BRNC"];
    let cchannel = channels[rng.gen_range(0..channels.len())].to_string();

    let ctr   = format!("{:02}", rng.gen_range(1u32..99u32));
    let cbr   = format!("{:04}", rng.gen_range(1u32..9999u32));
    let cterm = format!("{:05}", rng.gen_range(1u32..99999u32));

    let camt = if rng.gen_bool(0.5) { "C" } else { "D" }.to_string();

    let aamount = Decimal::new(rng.gen_range(100i64..1_000_000i64), 2);
    let abal    = Decimal::new(rng.gen_range(1_000i64..10_000_000i64), 2);

    // description maxLength=20 in MongoDB schema
    let descriptions = [
        "SALARY PAYMENT",   // 14
        "ATM WITHDRAWAL",   // 14
        "TRANSFER OUT",     // 12
        "TRANSFER IN",      // 11
        "BILL PAYMENT",     // 12
        "INTEREST CREDIT",  // 15
        "SERVICE FEE",      // 11
        "LOAN PAYMENT",     // 12
        "DEPOSIT",          //  7
        "PURCHASE",         //  8
    ];
    let description = descriptions[rng.gen_range(0..descriptions.len())].to_string();

    doc! {
        "iacct":       &iacct,
        "drun":        naive_date_to_bson(drun),
        "cseq":        cseq,
        "ddate":       naive_date_to_bson(ddate),
        "dtrans":      Bson::DateTime(naive_date_to_bson(dtrans)),
        "ttime":       &ttime,
        "cmnemo":      &cmnemo,
        "cchannel":    &cchannel,
        "ctr":         &ctr,
        "cbr":         &cbr,
        "cterm":       &cterm,
        "camt":        &camt,
        "aamount":     Bson::Decimal128(decimal_to_bson(aamount)),
        "abal":        Bson::Decimal128(decimal_to_bson(abal)),
        "description": &description,
        "time_hms":    &time_hms,
    }
}
