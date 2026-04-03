// =============================================================================
// load_mongo — Load mock_transactions.csv → MongoDB
// Reads the SAME CSV produced by generate_csv for apple-to-apple benchmark.
//
// Usage:
//   cargo run --release --bin load_mongo
//   CSV_PATH=data/mock_transactions.csv MONGODB_URI=... cargo run --release --bin load_mongo
// =============================================================================

use anyhow::Result;
use bson::{doc, Bson, DateTime as BsonDateTime, Decimal128};
use chrono::{NaiveDate, TimeZone, Utc};
use csv::ReaderBuilder;
use mongodb::{options::ClientOptions, Client};
use std::env;
use std::str::FromStr;
use std::time::Instant;

const BATCH_SIZE: usize = 5_000;

#[tokio::main]
async fn main() -> Result<()> {
    let csv_path = env::var("CSV_PATH")
        .unwrap_or_else(|_| "data/mock_transactions.csv".to_string());

    let mongodb_uri = env::var("MONGODB_URI")
        .unwrap_or_else(|_| {
            "mongodb://odsuser:odspassword@localhost:27017/odsperf".to_string()
        });

    let mongodb_db = env::var("MONGODB_DB")
        .unwrap_or_else(|_| "odsperf".to_string());

    println!("🚀 MongoDB CSV Loader");
    println!("📁 CSV     : {}", csv_path);
    println!("🔌 Target  : MongoDB / {}", mongodb_db);

    let client_options = ClientOptions::parse(&mongodb_uri).await?;
    let client = Client::with_options(client_options)?;
    client
        .database(&mongodb_db)
        .run_command(doc! { "ping": 1 })
        .await?;
    println!("✅ Connected to MongoDB");

    let collection = client
        .database(&mongodb_db)
        .collection::<bson::Document>("account_transaction");

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
                "✓ Batch {:>4} | {:>9} / {} | {:.2}s batch | {:.0} docs/s",
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
    println!("\n🎉 MongoDB load complete!");
    println!("📊 Inserted : {}", total_inserted);
    println!("⏱️  Time     : {:.2}s", elapsed.as_secs_f64());
    println!(
        "⚡ Speed    : {:.0} docs/s",
        total_inserted as f64 / elapsed.as_secs_f64()
    );
    println!("\n💡 Tip: Run ./scripts/init-mongo-indexes.sh to create indexes");

    Ok(())
}

// ─── CSV row → BSON Document ──────────────────────────────────────────────────
fn parse_doc(r: &csv::StringRecord) -> Result<bson::Document> {
    Ok(doc! {
        "iacct":       &r[0],
        "drun":        Bson::DateTime(naive_str_to_bson(&r[1])?),
        "cseq":        r[2].parse::<i32>()?,
        "ddate":       Bson::DateTime(naive_str_to_bson(&r[3])?),
        "dtrans":      Bson::DateTime(naive_str_to_bson(&r[4])?),
        "ttime":       &r[5],
        "cmnemo":      &r[6],
        "cchannel":    &r[7],
        "ctr":         &r[8],
        "cbr":         &r[9],
        "cterm":       &r[10],
        "camt":        &r[11],
        "aamount":     Bson::Decimal128(str_to_decimal128(&r[12])?),
        "abal":        Bson::Decimal128(str_to_decimal128(&r[13])?),
        "description": &r[14],
        "time_hms":    &r[15],
    })
}

// ─── Helpers ──────────────────────────────────────────────────────────────────
fn naive_str_to_bson(s: &str) -> Result<BsonDateTime> {
    let d = NaiveDate::parse_from_str(s, "%Y-%m-%d")?;
    let dt = Utc.from_utc_datetime(&d.and_hms_opt(0, 0, 0).unwrap());
    Ok(BsonDateTime::from_chrono(dt))
}

fn str_to_decimal128(s: &str) -> Result<Decimal128> {
    Ok(Decimal128::from_str(s).map_err(|e| anyhow::anyhow!("Decimal128 parse: {}", e))?)
}
