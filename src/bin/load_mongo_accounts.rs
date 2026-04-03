// =============================================================================
// load_mongo_accounts — Load mock_accounts.csv → MongoDB account_master
// Reads the CSV produced by generate_account_csv.
//
// Usage:
//   cargo run --release --bin load_mongo_accounts
//   CSV_PATH=data/mock_accounts.csv MONGODB_URI=... cargo run --release --bin load_mongo_accounts
// =============================================================================

use anyhow::Result;
use bson::{doc, Bson, DateTime as BsonDateTime, Decimal128};
use chrono::{NaiveDate, TimeZone, Utc};
use csv::ReaderBuilder;
use mongodb::{options::ClientOptions, Client};
use std::env;
use std::str::FromStr;
use std::time::Instant;

const BATCH_SIZE: usize = 2_000;

#[tokio::main]
async fn main() -> Result<()> {
    let csv_path = env::var("CSV_PATH")
        .unwrap_or_else(|_| "data/mock_accounts.csv".to_string());

    let mongodb_uri = env::var("MONGODB_URI")
        .unwrap_or_else(|_| {
            "mongodb://odsuser:odspassword@localhost:27017/odsperf".to_string()
        });

    let mongodb_db = env::var("MONGODB_DB")
        .unwrap_or_else(|_| "odsperf".to_string());

    println!("🚀 MongoDB Account Master Loader");
    println!("📁 CSV     : {}", csv_path);
    println!("🔌 Target  : MongoDB / {} / account_master", mongodb_db);

    let client_options = ClientOptions::parse(&mongodb_uri).await?;
    let client = Client::with_options(client_options)?;
    client
        .database(&mongodb_db)
        .run_command(doc! { "ping": 1 })
        .await?;
    println!("✅ Connected to MongoDB");

    let collection = client
        .database(&mongodb_db)
        .collection::<bson::Document>("account_master");

    // Count total rows for progress display
    let total_rows = {
        let mut rdr = ReaderBuilder::new().from_path(&csv_path)?;
        rdr.records().count()
    };
    println!("📊 Rows    : {}", total_rows);

    let start = Instant::now();
    let mut rdr = ReaderBuilder::new().from_path(&csv_path)?;
    let mut batch: Vec<bson::Document> = Vec::with_capacity(BATCH_SIZE);
    let mut total_inserted: usize = 0;
    let mut batch_num: usize = 0;

    for result in rdr.records() {
        let record = result?;
        batch.push(parse_doc(&record)?);

        if batch.len() == BATCH_SIZE {
            batch_num += 1;
            let batch_start = Instant::now();
            collection.insert_many(batch.drain(..).collect::<Vec<_>>()).await?;
            total_inserted += BATCH_SIZE;

            let overall = start.elapsed().as_secs_f64();
            let speed = total_inserted as f64 / overall;
            println!(
                "✓ Batch {:>4} | {:>7} / {} | {:.2}s batch | {:.0} docs/s",
                batch_num, total_inserted, total_rows,
                batch_start.elapsed().as_secs_f64(), speed
            );
        }
    }

    // Flush remaining documents
    if !batch.is_empty() {
        total_inserted += batch.len();
        collection.insert_many(batch).await?;
    }

    let elapsed = start.elapsed();
    println!("\n🎉 MongoDB account_master load complete!");
    println!("📊 Inserted : {}", total_inserted);
    println!("⏱️  Time     : {:.2}s", elapsed.as_secs_f64());
    println!(
        "⚡ Speed    : {:.0} docs/s",
        total_inserted as f64 / elapsed.as_secs_f64()
    );

    Ok(())
}

// ─── CSV row → BSON Document ──────────────────────────────────────────────────
// CSV columns: iacct, custid, ctype, dopen, dclose, cstatus, cbranch, segment, credit_limit
fn parse_doc(r: &csv::StringRecord) -> Result<bson::Document> {
    let dclose: Bson = if r[4].is_empty() {
        Bson::Null
    } else {
        Bson::DateTime(naive_str_to_bson(&r[4])?)
    };

    let credit_limit: Bson = if r[8].is_empty() {
        Bson::Null
    } else {
        Bson::Decimal128(str_to_decimal128(&r[8])?)
    };

    Ok(doc! {
        "iacct":        &r[0],
        "custid":       &r[1],
        "ctype":        &r[2],
        "dopen":        Bson::DateTime(naive_str_to_bson(&r[3])?),
        "dclose":       dclose,
        "cstatus":      &r[5],
        "cbranch":      &r[6],
        "segment":      &r[7],
        "credit_limit": credit_limit,
    })
}

// ─── Helpers ──────────────────────────────────────────────────────────────────
fn naive_str_to_bson(s: &str) -> Result<BsonDateTime> {
    let d = NaiveDate::parse_from_str(s, "%Y-%m-%d")?;
    let dt = Utc.from_utc_datetime(&d.and_hms_opt(0, 0, 0).unwrap());
    Ok(BsonDateTime::from_chrono(dt))
}

fn str_to_decimal128(s: &str) -> Result<Decimal128> {
    Decimal128::from_str(s).map_err(|e| anyhow::anyhow!("Decimal128 parse: {}", e))
}
