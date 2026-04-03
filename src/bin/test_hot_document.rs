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

const COLLECTION_NAME: &str = "account_statements";
const NUM_HOT_ACCOUNTS: usize = 10;
const WRITES_PER_ACCOUNT: usize = 1000;
const STATEMENTS_PER_WRITE: usize = 10;

#[tokio::main]
async fn main() -> Result<()> {
    let mongodb_uri = env::var("MONGODB_URI")
        .unwrap_or_else(|_| "mongodb://odsuser:odspassword@localhost:27017/odsperf".to_string());
    let mongodb_db = env::var("MONGODB_DB").unwrap_or_else(|_| "odsperf".to_string());

    println!("🔌 Connecting to MongoDB...");
    let client_options = ClientOptions::parse(&mongodb_uri).await?;
    let client = Client::with_options(client_options)?;

    client
        .database(&mongodb_db)
        .run_command(doc! { "ping": 1 })
        .await?;
    println!("✅ Connected successfully\n");

    let db = client.database(&mongodb_db);
    let collection = db.collection::<bson::Document>(COLLECTION_NAME);

    // Drop collection if exists to start fresh
    let _ = collection.drop().await;
    println!("🗑️  Dropped existing collection (if any)\n");

    let mut rng = thread_rng();

    // Generate hot account numbers
    let hot_accounts: Vec<String> = (0..NUM_HOT_ACCOUNTS)
        .map(|i| format!("{:011}", 10000000000u64 + i as u64))
        .collect();

    println!("📋 Test Configuration:");
    println!("   • Collection: {}", COLLECTION_NAME);
    println!("   • Hot accounts: {}", NUM_HOT_ACCOUNTS);
    println!("   • Writes per account: {}", WRITES_PER_ACCOUNT);
    println!("   • Statements per write: {}", STATEMENTS_PER_WRITE);
    println!("   • Total writes: {}", NUM_HOT_ACCOUNTS * WRITES_PER_ACCOUNT);
    println!("   • Total statements: {}\n", NUM_HOT_ACCOUNTS * WRITES_PER_ACCOUNT * STATEMENTS_PER_WRITE);

    // Initialize documents with account master data
    println!("🔧 Initializing {} account documents...", NUM_HOT_ACCOUNTS);
    for account_no in &hot_accounts {
        let account_doc = generate_account_master(account_no, &mut rng);
        collection.insert_one(account_doc).await?;
    }
    println!("✅ Initialization complete\n");

    println!("╔════════════════════════════════════════════════════════════════════════╗");
    println!("║              Starting Hot Document Write Test                          ║");
    println!("╚════════════════════════════════════════════════════════════════════════╝\n");

    let test_start = Instant::now();
    let mut total_writes = 0;
    let mut total_statements_written = 0;

    // Statistics tracking
    let mut min_write_time = f64::MAX;
    let mut max_write_time = 0.0f64;
    let mut sum_write_time = 0.0f64;

    // Perform writes
    for write_num in 0..WRITES_PER_ACCOUNT {
        let batch_start = Instant::now();

        // Write to all hot accounts in this iteration
        for account_no in &hot_accounts {
            let write_start = Instant::now();

            // Generate statements for this write
            let statements: Vec<Bson> = (0..STATEMENTS_PER_WRITE)
                .map(|_| Bson::Document(generate_transaction(account_no, &mut rng)))
                .collect();

            // Append to the statements array using $push with $each
            collection
                .update_one(
                    doc! { "iacct": account_no },
                    doc! { "$push": { "statements": { "$each": statements } } },
                )
                .await?;

            let write_elapsed = write_start.elapsed().as_secs_f64() * 1000.0; // ms
            min_write_time = min_write_time.min(write_elapsed);
            max_write_time = max_write_time.max(write_elapsed);
            sum_write_time += write_elapsed;

            total_writes += 1;
            total_statements_written += STATEMENTS_PER_WRITE;
        }

        let batch_elapsed = batch_start.elapsed();
        let overall_elapsed = test_start.elapsed();
        let writes_per_sec = total_writes as f64 / overall_elapsed.as_secs_f64();
        let statements_per_sec = total_statements_written as f64 / overall_elapsed.as_secs_f64();

        // Progress report every 100 iterations
        if (write_num + 1) % 100 == 0 || write_num == 0 {
            println!(
                "✓ Iteration {:>4}/{} | Writes: {:>6} | Batch: {:>6.2}ms | Total: {:>7.2}s | {:>7.0} writes/s | {:>8.0} stmt/s",
                write_num + 1,
                WRITES_PER_ACCOUNT,
                total_writes,
                batch_elapsed.as_millis(),
                overall_elapsed.as_secs_f64(),
                writes_per_sec,
                statements_per_sec
            );
        }
    }

    let total_elapsed = test_start.elapsed();
    let avg_write_time = sum_write_time / total_writes as f64;

    println!("\n╔════════════════════════════════════════════════════════════════════════╗");
    println!("║                        Test Results Summary                            ║");
    println!("╚════════════════════════════════════════════════════════════════════════╝\n");

    println!("📊 Write Statistics:");
    println!("   • Total writes:           {:>10}", total_writes);
    println!("   • Total statements:       {:>10}", total_statements_written);
    println!("   • Total duration:         {:>10.2} seconds", total_elapsed.as_secs_f64());
    println!();

    println!("⚡ Performance Metrics:");
    println!("   • Writes per second:      {:>10.2}", total_writes as f64 / total_elapsed.as_secs_f64());
    println!("   • Statements per second:  {:>10.2}", total_statements_written as f64 / total_elapsed.as_secs_f64());
    println!();

    println!("⏱️  Write Latency (ms):");
    println!("   • Average:                {:>10.2}", avg_write_time);
    println!("   • Minimum:                {:>10.2}", min_write_time);
    println!("   • Maximum:                {:>10.2}", max_write_time);
    println!();

    // Verify final document sizes
    println!("📄 Document Analysis:");
    for (idx, account_no) in hot_accounts.iter().enumerate() {
        if let Some(doc) = collection
            .find_one(doc! { "iacct": account_no })
            .await?
        {
            let stmt_count = doc
                .get_array("statements")
                .map(|arr| arr.len())
                .unwrap_or(0);
            
            let doc_size = bson::to_vec(&doc)?.len();
            
            println!(
                "   • Account {} ({:>2}/{}): {:>6} statements, {:>8} bytes",
                account_no,
                idx + 1,
                NUM_HOT_ACCOUNTS,
                stmt_count,
                doc_size
            );
        }
    }

    println!();
    println!("╔════════════════════════════════════════════════════════════════════════╗");
    println!("║                      Test Completed Successfully!                      ║");
    println!("╚════════════════════════════════════════════════════════════════════════╝");

    Ok(())
}

// ─── Helper: NaiveDate → bson::DateTime (UTC midnight) ───────────────────────
fn naive_date_to_bson(d: NaiveDate) -> BsonDateTime {
    let dt = Utc.from_utc_datetime(&d.and_hms_opt(0, 0, 0).unwrap());
    BsonDateTime::from_chrono(dt)
}

// ─── Helper: Decimal → bson::Decimal128 via string ────────────────────────────
fn decimal_to_bson(d: Decimal) -> Decimal128 {
    Decimal128::from_str(&format!("{:.2}", d)).expect("valid decimal string")
}

// ─── Generate Account Master Document ─────────────────────────────────────────
fn generate_account_master(account_no: &str, rng: &mut ThreadRng) -> bson::Document {
    let dopen = NaiveDate::from_ymd_opt(2020, 1, 1).unwrap()
        + chrono::Duration::days(rng.gen_range(0..=1825)); // 5 years range

    let statuses = ["ACTIVE", "DORMANT", "CLOSED"];
    let cstatus = statuses[rng.gen_range(0..statuses.len())];

    let types = ["SAVINGS", "CURRENT", "FIXED"];
    let ctype = types[rng.gen_range(0..types.len())];

    let segments = ["RETAIL", "SME", "CORPORATE", "PREMIUM"];
    let segment = segments[rng.gen_range(0..segments.len())];

    doc! {
        "iacct": account_no,
        "custid": format!("{:010}", rng.gen_range(1000000000u64..9999999999u64)),
        "ctype": ctype,
        "dopen": naive_date_to_bson(dopen),
        "dclose": Bson::Null,
        "cstatus": cstatus,
        "cbranch": format!("{:04}", rng.gen_range(1u32..9999u32)),
        "segment": segment,
        "credit_limit": Bson::Decimal128(decimal_to_bson(Decimal::new(rng.gen_range(10000i64..1000000i64), 2))),
        "statements": Bson::Array(vec![]),
    }
}

// ─── Generate Transaction Document ────────────────────────────────────────────
fn generate_transaction(account_no: &str, rng: &mut ThreadRng) -> bson::Document {
    let start_date = NaiveDate::from_ymd_opt(2025, 1, 1).unwrap();
    let end_date = NaiveDate::from_ymd_opt(2025, 12, 31).unwrap();
    let days_in_range = (end_date - start_date).num_days();

    let dtrans = start_date + chrono::Duration::days(rng.gen_range(0..=days_in_range));
    let drun = dtrans + chrono::Duration::days(rng.gen_range(0..=3));
    let ddate = dtrans;

    let cseq = rng.gen_range(1i32..=9999i32);

    let hour = rng.gen_range(8u32..18u32);
    let minute = rng.gen_range(0u32..60u32);
    let second = rng.gen_range(0u32..60u32);
    let ttime = format!("{:02}:{:02}", hour, minute);
    let time_hms = format!("{:02}:{:02}:{:02}", hour, minute, second);

    let mnemonics = ["DEP", "WDL", "TRF", "CHQ", "FEE", "INT", "ATM", "POS"];
    let cmnemo = mnemonics[rng.gen_range(0..mnemonics.len())].to_string();

    let channels = ["ATM", "INET", "MOB", "BRNC"];
    let cchannel = channels[rng.gen_range(0..channels.len())].to_string();

    let ctr = format!("{:02}", rng.gen_range(1u32..99u32));
    let cbr = format!("{:04}", rng.gen_range(1u32..9999u32));
    let cterm = format!("{:05}", rng.gen_range(1u32..99999u32));

    let camt = if rng.gen_bool(0.5) { "C" } else { "D" }.to_string();

    let aamount = Decimal::new(rng.gen_range(100i64..1_000_000i64), 2);
    let abal = Decimal::new(rng.gen_range(1_000i64..10_000_000i64), 2);

    let descriptions = [
        "SALARY PAYMENT",
        "ATM WITHDRAWAL",
        "TRANSFER OUT",
        "TRANSFER IN",
        "BILL PAYMENT",
        "INTEREST CREDIT",
        "SERVICE FEE",
        "LOAN PAYMENT",
        "DEPOSIT",
        "PURCHASE",
    ];
    let description = descriptions[rng.gen_range(0..descriptions.len())].to_string();

    doc! {
        "iacct": account_no,
        "drun": naive_date_to_bson(drun),
        "cseq": cseq,
        "ddate": naive_date_to_bson(ddate),
        "dtrans": Bson::DateTime(naive_date_to_bson(dtrans)),
        "ttime": &ttime,
        "cmnemo": &cmnemo,
        "cchannel": &cchannel,
        "ctr": &ctr,
        "cbr": &cbr,
        "cterm": &cterm,
        "camt": &camt,
        "aamount": Bson::Decimal128(decimal_to_bson(aamount)),
        "abal": Bson::Decimal128(decimal_to_bson(abal)),
        "description": &description,
        "time_hms": &time_hms,
    }
}
