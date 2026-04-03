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

const COLLECTION_NAME: &str = "final_statements";
const SOURCE_COLLECTION: &str = "account_transaction";  // Source collection to read dates from
const NUM_HOT_ACCOUNTS: usize = 10;
const WRITES_PER_DOCUMENT: usize = 100;  // Number of times we append to same document
const STATEMENTS_PER_WRITE: usize = 10;  // Statements added per append

#[tokio::main]
async fn main() -> Result<()> {
    let mongodb_uri = env::var("MONGODB_URI")
        .unwrap_or_else(|_| "mongodb://odsuser:odspassword@localhost:27017/odsperf".to_string());
    let mongodb_db = env::var("MONGODB_DB").unwrap_or_else(|_| "odsperf".to_string());

    let db = connect_to_mongodb(&mongodb_uri, &mongodb_db).await?;
    let collection = setup_collection(&db).await?;

    let mut rng = thread_rng();
    let hot_accounts = generate_hot_accounts();
    
    println!("📅 Reading distinct dates from {}...", SOURCE_COLLECTION);
    let hot_dates = read_distinct_dates(&db).await?;
    println!("✅ Found {} distinct dates\n", hot_dates.len());
    
    print_test_configuration(hot_dates.len());
    initialize_account_documents(&collection, &hot_accounts, &hot_dates, &mut rng).await?;

    let stats = run_hot_document_test(&collection, &hot_accounts, &hot_dates, &mut rng).await?;
    
    print_test_results(&stats);
    print_document_analysis(&collection, &hot_accounts).await?;

    println!();
    println!("╔════════════════════════════════════════════════════════════════════════╗");
    println!("║                      Test Completed Successfully!                      ║");
    println!("╚════════════════════════════════════════════════════════════════════════╝");

    Ok(())
}

// ─── Setup & Initialization Functions ─────────────────────────────────────────

async fn connect_to_mongodb(
    mongodb_uri: &str,
    mongodb_db: &str,
) -> Result<mongodb::Database> {
    println!("🔌 Connecting to MongoDB...");
    let client_options = ClientOptions::parse(mongodb_uri).await?;
    let client = Client::with_options(client_options)?;

    let db = client.database(mongodb_db);
    db.run_command(doc! { "ping": 1 }).await?;
    println!("✅ Connected successfully\n");

    Ok(db)
}

async fn setup_collection(
    db: &mongodb::Database,
) -> Result<mongodb::Collection<bson::Document>> {
    let collection = db.collection::<bson::Document>(COLLECTION_NAME);

    println!("🗑️  Dropping existing collection (if any)...");
    let _ = collection.drop().await;
    println!("✅ Collection cleared\n");

    println!("🔧 Creating index on {{iacct: 1, dtrans: 1}}...");
    let index_model = mongodb::IndexModel::builder()
        .keys(doc! { "iacct": 1, "dtrans": 1 })
        .build();
    collection.create_index(index_model).await?;
    println!("✅ Index created\n");

    Ok(collection)
}

fn generate_hot_accounts() -> Vec<String> {
    (0..NUM_HOT_ACCOUNTS)
        .map(|i| format!("{:011}", 10000000000u64 + i as u64))
        .collect()
}

async fn read_distinct_dates(db: &mongodb::Database) -> Result<Vec<NaiveDate>> {
    let source_collection = db.collection::<bson::Document>(SOURCE_COLLECTION);
    
    // Check if source collection has data
    let count = source_collection.count_documents(doc! {}).await?;
    
    if count == 0 {
        println!("⚠️  Source collection is empty, generating dates for 2025 (365 days)...");
        let start_date = NaiveDate::from_ymd_opt(2025, 1, 1).unwrap();
        let dates: Vec<NaiveDate> = (0..365)
            .map(|i| start_date + chrono::Duration::days(i))
            .collect();
        return Ok(dates);
    }
    
    // Get distinct dtrans dates from source collection
    let distinct_dates = source_collection
        .distinct("dtrans", doc! {})
        .await?;
    
    let mut dates: Vec<NaiveDate> = distinct_dates
        .iter()
        .filter_map(|bson_val| {
            if let Bson::DateTime(dt) = bson_val {
                let chrono_dt = dt.to_chrono();
                Some(chrono_dt.date_naive())
            } else {
                None
            }
        })
        .collect();
    
    dates.sort();
    dates.dedup();
    
    if dates.is_empty() {
        return Err(anyhow::anyhow!("No dates found in source collection"));
    }
    
    Ok(dates)
}

fn print_test_configuration(num_dates: usize) {
    let total_documents = NUM_HOT_ACCOUNTS * num_dates;
    let total_writes = total_documents * WRITES_PER_DOCUMENT;
    let total_statements = total_writes * STATEMENTS_PER_WRITE;
    
    println!("📋 Test Configuration:");
    println!("   • Source collection: {}", SOURCE_COLLECTION);
    println!("   • Target collection: {}", COLLECTION_NAME);
    println!("   • Hot accounts: {}", NUM_HOT_ACCOUNTS);
    println!("   • Distinct dates (from source): {}", num_dates);
    println!("   • Documents (account × date): {}", total_documents);
    println!("   • Writes per document: {}", WRITES_PER_DOCUMENT);
    println!("   • Statements per write: {}", STATEMENTS_PER_WRITE);
    println!("   • Total writes: {}", total_writes);
    println!("   • Total statements: {}\n", total_statements);
}

async fn initialize_account_documents(
    collection: &mongodb::Collection<bson::Document>,
    hot_accounts: &[String],
    hot_dates: &[NaiveDate],
    rng: &mut ThreadRng,
) -> Result<()> {
    let total_docs = hot_accounts.len() * hot_dates.len();
    println!("🔧 Initializing {} documents (account × date)...", total_docs);
    
    for account_no in hot_accounts {
        for date in hot_dates {
            let doc = generate_account_date_document(account_no, *date, rng);
            collection.insert_one(doc).await?;
        }
    }
    
    println!("✅ Initialization complete\n");
    Ok(())
}

// ─── Test Execution Functions ─────────────────────────────────────────────────

struct TestStatistics {
    total_writes: usize,
    total_statements: usize,
    total_duration: std::time::Duration,
    min_write_time: f64,
    max_write_time: f64,
    avg_write_time: f64,
}

async fn run_hot_document_test(
    collection: &mongodb::Collection<bson::Document>,
    hot_accounts: &[String],
    hot_dates: &[NaiveDate],
    rng: &mut ThreadRng,
) -> Result<TestStatistics> {
    println!("╔════════════════════════════════════════════════════════════════════════╗");
    println!("║              Starting Hot Document Write Test                          ║");
    println!("╚════════════════════════════════════════════════════════════════════════╝\n");

    let test_start = Instant::now();
    let mut total_writes = 0;
    let mut total_statements_written = 0;
    let mut min_write_time = f64::MAX;
    let mut max_write_time = 0.0f64;
    let mut sum_write_time = 0.0f64;

    // Simulate batch writes: repeatedly append to same account+date documents
    for write_num in 0..WRITES_PER_DOCUMENT {
        let batch_start = Instant::now();

        // Write to all account+date combinations
        for account_no in hot_accounts {
            for date in hot_dates {
                let write_time = perform_single_write(collection, account_no, *date, rng).await?;
                
                min_write_time = min_write_time.min(write_time);
                max_write_time = max_write_time.max(write_time);
                sum_write_time += write_time;
                total_writes += 1;
                total_statements_written += STATEMENTS_PER_WRITE;
            }
        }

        if (write_num + 1) % 10 == 0 || write_num == 0 {
            print_progress(
                write_num + 1,
                total_writes,
                total_statements_written,
                batch_start.elapsed(),
                test_start.elapsed(),
            );
        }
    }

    Ok(TestStatistics {
        total_writes,
        total_statements: total_statements_written,
        total_duration: test_start.elapsed(),
        min_write_time,
        max_write_time,
        avg_write_time: sum_write_time / total_writes as f64,
    })
}

async fn perform_single_write(
    collection: &mongodb::Collection<bson::Document>,
    account_no: &str,
    date: NaiveDate,
    rng: &mut ThreadRng,
) -> Result<f64> {
    let write_start = Instant::now();

    // Generate statements for this specific date
    let statements: Vec<Bson> = (0..STATEMENTS_PER_WRITE)
        .map(|_| Bson::Document(generate_transaction(account_no, date, rng)))
        .collect();

    let update_doc = doc! {
        "$push": { "statements": { "$each": statements } }
    };

    // Update document with compound key: account + date
    collection
        .update_one(
            doc! { 
                "iacct": account_no,
                "dtrans": naive_date_to_bson(date)
            },
            update_doc
        )
        .await?;

    Ok(write_start.elapsed().as_secs_f64() * 1000.0)
}


// ─── Reporting Functions ──────────────────────────────────────────────────────

fn print_progress(
    iteration: usize,
    total_writes: usize,
    total_statements: usize,
    batch_elapsed: std::time::Duration,
    overall_elapsed: std::time::Duration,
) {
    let writes_per_sec = total_writes as f64 / overall_elapsed.as_secs_f64();
    let statements_per_sec = total_statements as f64 / overall_elapsed.as_secs_f64();

    println!(
        "✓ Iteration {:>4}/{} | Writes: {:>6} | Batch: {:>6.2}ms | Total: {:>7.2}s | {:>7.0} writes/s | {:>8.0} stmt/s",
        iteration,
        WRITES_PER_DOCUMENT,
        total_writes,
        batch_elapsed.as_millis(),
        overall_elapsed.as_secs_f64(),
        writes_per_sec,
        statements_per_sec
    );
}

fn print_test_results(stats: &TestStatistics) {
    println!("\n╔════════════════════════════════════════════════════════════════════════╗");
    println!("║                        Test Results Summary                            ║");
    println!("╚════════════════════════════════════════════════════════════════════════╝\n");

    println!("📊 Write Statistics:");
    println!("   • Total writes:           {:>10}", stats.total_writes);
    println!("   • Total statements:       {:>10}", stats.total_statements);
    println!("   • Total duration:         {:>10.2} seconds", stats.total_duration.as_secs_f64());
    println!();

    println!("⚡ Performance Metrics:");
    println!("   • Writes per second:      {:>10.2}", stats.total_writes as f64 / stats.total_duration.as_secs_f64());
    println!("   • Statements per second:  {:>10.2}", stats.total_statements as f64 / stats.total_duration.as_secs_f64());
    println!();

    println!("⏱️  Write Latency (ms):");
    println!("   • Average:                {:>10.2}", stats.avg_write_time);
    println!("   • Minimum:                {:>10.2}", stats.min_write_time);
    println!("   • Maximum:                {:>10.2}", stats.max_write_time);
    println!();
}

async fn print_document_analysis(
    collection: &mongodb::Collection<bson::Document>,
    hot_accounts: &[String],
) -> Result<()> {
    println!("📄 Hot Document Analysis:");
    println!("   Analyzing document growth per account (showing sample dates)...\n");
    
    for (idx, account_no) in hot_accounts.iter().enumerate() {
        let stats = analyze_account_documents(collection, account_no).await?;
        print_account_statistics(account_no, idx + 1, &stats);
    }
    
    let overall_stats = calculate_overall_statistics(collection).await?;
    print_overall_summary(&overall_stats);
    
    Ok(())
}

struct AccountStatistics {
    doc_count: usize,
    total_statements: usize,
    total_size: usize,
    min_stmts: usize,
    max_stmts: usize,
    sample_docs: Vec<(String, usize, usize)>,
}

async fn analyze_account_documents(
    collection: &mongodb::Collection<bson::Document>,
    account_no: &str,
) -> Result<AccountStatistics> {
    let mut cursor = collection.find(doc! { "iacct": account_no }).await?;
    
    let mut total_statements = 0;
    let mut total_size = 0;
    let mut doc_count = 0;
    let mut min_stmts = usize::MAX;
    let mut max_stmts = 0;
    let mut sample_docs = Vec::new();
    
    while cursor.advance().await? {
        let doc = cursor.deserialize_current()?;
        let stmt_count = doc.get_array("statements").map(|arr| arr.len()).unwrap_or(0);
        let doc_size = bson::to_vec(&doc)?.len();
        
        total_statements += stmt_count;
        total_size += doc_size;
        doc_count += 1;
        min_stmts = min_stmts.min(stmt_count);
        max_stmts = max_stmts.max(stmt_count);
        
        if sample_docs.len() < 3 {
            if let Some(dtrans) = doc.get_datetime("dtrans").ok() {
                sample_docs.push((dtrans.to_string(), stmt_count, doc_size));
            }
        }
    }
    
    Ok(AccountStatistics {
        doc_count,
        total_statements,
        total_size,
        min_stmts: if min_stmts == usize::MAX { 0 } else { min_stmts },
        max_stmts,
        sample_docs,
    })
}

fn print_account_statistics(account_no: &str, index: usize, stats: &AccountStatistics) {
    println!("   🔥 Account {} ({}/{})", account_no, index, NUM_HOT_ACCOUNTS);
    println!("      • Documents (hot dates):     {:>6}", stats.doc_count);
    println!("      • Total statements:          {:>6}", stats.total_statements);
    println!("      • Total size:                {:>6} KB", stats.total_size / 1024);
    println!(
        "      • Avg statements/document:   {:>6}",
        if stats.doc_count > 0 { stats.total_statements / stats.doc_count } else { 0 }
    );
    println!(
        "      • Avg size/document:         {:>6} KB",
        if stats.doc_count > 0 { stats.total_size / stats.doc_count / 1024 } else { 0 }
    );
    println!("      • Min/Max statements:        {:>6} / {}", stats.min_stmts, stats.max_stmts);
    
    if !stats.sample_docs.is_empty() {
        println!("      • Sample documents:");
        for (date, stmts, size) in &stats.sample_docs {
            println!("        - {}: {} stmts, {} KB", &date[..10], stmts, size / 1024);
        }
    }
    println!();
}

struct OverallStatistics {
    total_docs: u64,
    total_statements: usize,
}

async fn calculate_overall_statistics(
    collection: &mongodb::Collection<bson::Document>,
) -> Result<OverallStatistics> {
    let total_docs = collection.count_documents(doc! {}).await?;
    
    let pipeline = vec![
        doc! { "$project": { "stmt_count": { "$size": "$statements" } } },
        doc! { "$group": { "_id": null, "total": { "$sum": "$stmt_count" } } }
    ];
    
    let mut cursor = collection.aggregate(pipeline).await?;
    let mut total_statements = 0;
    
    if cursor.advance().await? {
        let result = cursor.deserialize_current()?;
        total_statements = result.get_i32("total").unwrap_or(0) as usize;
    }
    
    Ok(OverallStatistics {
        total_docs,
        total_statements,
    })
}

fn print_overall_summary(stats: &OverallStatistics) {
    println!("   📊 Overall Summary:");
    println!("      • Total documents:           {:>6}", stats.total_docs);
    println!("      • Total statements:          {:>6}", stats.total_statements);
    println!(
        "      • Avg statements/document:   {:>6}",
        if stats.total_docs > 0 { stats.total_statements / stats.total_docs as usize } else { 0 }
    );
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

// ─── Generate Account+Date Document ───────────────────────────────────────────
fn generate_account_date_document(
    account_no: &str,
    date: NaiveDate,
    rng: &mut ThreadRng,
) -> bson::Document {
    let dopen = NaiveDate::from_ymd_opt(2020, 1, 1).unwrap()
        + chrono::Duration::days(rng.gen_range(0..=1825));

    let statuses = ["ACTIVE", "DORMANT", "CLOSED"];
    let cstatus = statuses[rng.gen_range(0..statuses.len())];

    let types = ["SAVINGS", "CURRENT", "FIXED"];
    let ctype = types[rng.gen_range(0..types.len())];

    let segments = ["RETAIL", "SME", "CORPORATE", "PREMIUM"];
    let segment = segments[rng.gen_range(0..segments.len())];

    doc! {
        "iacct": account_no,
        "dtrans": naive_date_to_bson(date),  // Transaction date - part of compound key
        "custid": format!("{:010}", rng.gen_range(1000000000u64..9999999999u64)),
        "ctype": ctype,
        "dopen": naive_date_to_bson(dopen),
        "dclose": Bson::Null,
        "cstatus": cstatus,
        "cbranch": format!("{:04}", rng.gen_range(1u32..9999u32)),
        "segment": segment,
        "credit_limit": Bson::Decimal128(decimal_to_bson(Decimal::new(rng.gen_range(10000i64..1000000i64), 2))),
        "statements": Bson::Array(vec![]),  // Will be populated with transactions for this date
    }
}

// ─── Generate Transaction Document ────────────────────────────────────────────
fn generate_transaction(account_no: &str, date: NaiveDate, rng: &mut ThreadRng) -> bson::Document {
    // All transactions in this document happen on the same date
    let dtrans = date;
    let drun = date + chrono::Duration::days(rng.gen_range(0..=3));
    let ddate = date;

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
