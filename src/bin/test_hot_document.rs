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
const TOP_HOT_DOCUMENTS: usize = 10;  // Top N hottest account+date combinations
const WRITES_PER_DOCUMENT: usize = 100;  // Number of times we append to same document

#[tokio::main]
async fn main() -> Result<()> {
    let mongodb_uri = env::var("MONGODB_URI")
        .unwrap_or_else(|_| "mongodb://odsuser:odspassword@localhost:27017/odsperf".to_string());
    let mongodb_db = env::var("MONGODB_DB").unwrap_or_else(|_| "odsperf".to_string());

    let db = connect_to_mongodb(&mongodb_uri, &mongodb_db).await?;
    let collection = setup_collection(&db).await?;
    let source_collection = db.collection::<bson::Document>(SOURCE_COLLECTION);

    println!("📊 Analyzing source collection...");
    let all_account_dates = find_all_account_dates(&source_collection).await?;
    println!("✅ Found {} unique account+date combinations\n", all_account_dates.len());
    
    if all_account_dates.is_empty() {
        return Err(anyhow::anyhow!("No data found in source collection"));
    }
    
    println!("🔥 Finding top {} hottest documents for testing...", TOP_HOT_DOCUMENTS);
    let hot_documents = find_top_hot_documents(&source_collection).await?;
    println!("✅ Selected {} hot documents for write test\n", hot_documents.len());
    
    print_test_configuration(&all_account_dates, &hot_documents);
    
    println!("🔧 Initializing ALL {} account+date documents...", all_account_dates.len());
    initialize_all_documents(&collection, &source_collection, &all_account_dates).await?;
    println!("✅ All documents initialized\n");

    let stats = run_hot_document_test(&collection, &source_collection, &hot_documents).await?;
    
    print_test_results(&stats);
    print_document_analysis(&collection, &hot_documents).await?;

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

#[derive(Debug, Clone)]
struct HotDocument {
    account: String,
    date: NaiveDate,
    transaction_count: i32,
}

async fn find_top_hot_documents(
    source_collection: &mongodb::Collection<bson::Document>,
) -> Result<Vec<HotDocument>> {
    // Aggregate to find top account+date combinations by transaction count
    let pipeline = vec![
        doc! {
            "$group": {
                "_id": {
                    "iacct": "$iacct",
                    "date": {
                        "$dateToString": {
                            "format": "%Y-%m-%d",
                            "date": "$dtrans"
                        }
                    }
                },
                "count": { "$sum": 1 }
            }
        },
        doc! {
            "$sort": { "count": -1 }
        },
        doc! {
            "$limit": TOP_HOT_DOCUMENTS as i64
        }
    ];
    
    let mut cursor = source_collection.aggregate(pipeline).await?;
    let mut hot_docs = Vec::new();
    
    while cursor.advance().await? {
        let doc = cursor.deserialize_current()?;
        
        if let (Some(id_doc), Some(count)) = (doc.get_document("_id").ok(), doc.get_i32("count").ok()) {
            if let (Some(account), Some(date_str)) = (
                id_doc.get_str("iacct").ok(),
                id_doc.get_str("date").ok()
            ) {
                if let Ok(date) = NaiveDate::parse_from_str(date_str, "%Y-%m-%d") {
                    hot_docs.push(HotDocument {
                        account: account.to_string(),
                        date,
                        transaction_count: count,
                    });
                }
            }
        }
    }
    
    Ok(hot_docs)
}

fn print_test_configuration(all_docs: &[(String, NaiveDate)], hot_documents: &[HotDocument]) {
    let total_writes = hot_documents.len() * WRITES_PER_DOCUMENT;
    let total_transactions: i32 = hot_documents.iter().map(|d| d.transaction_count).sum();
    let total_statements_per_test = total_transactions as usize * WRITES_PER_DOCUMENT;
    
    println!("📋 Test Configuration:");
    println!("   • Source collection: {}", SOURCE_COLLECTION);
    println!("   • Target collection: {}", COLLECTION_NAME);
    println!("   • Total account+date combinations: {}", all_docs.len());
    println!("   • Hot documents for testing: {}", hot_documents.len());
    println!("   • Writes per hot document: {}", WRITES_PER_DOCUMENT);
    println!("   • Total test writes: {}", total_writes);
    println!("   • Avg transactions/hot doc: {}", if !hot_documents.is_empty() { total_transactions / hot_documents.len() as i32 } else { 0 });
    println!("   • Total statements in test: {}\n", total_statements_per_test);
    
    println!("🔥 Top {} Hot Documents (for write testing):", hot_documents.len());
    for (idx, doc) in hot_documents.iter().enumerate() {
        println!("   {}. Account {} on {}: {} transactions", 
            idx + 1, doc.account, doc.date, doc.transaction_count);
    }
    println!();
}

async fn find_all_account_dates(
    source_collection: &mongodb::Collection<bson::Document>,
) -> Result<Vec<(String, NaiveDate)>> {
    let pipeline = vec![
        doc! {
            "$group": {
                "_id": {
                    "iacct": "$iacct",
                    "date": {
                        "$dateToString": {
                            "format": "%Y-%m-%d",
                            "date": "$dtrans"
                        }
                    }
                }
            }
        }
    ];
    
    let mut cursor = source_collection.aggregate(pipeline).await?;
    let mut account_dates = Vec::new();
    
    while cursor.advance().await? {
        let doc = cursor.deserialize_current()?;
        
        if let Some(id_doc) = doc.get_document("_id").ok() {
            if let (Some(account), Some(date_str)) = (
                id_doc.get_str("iacct").ok(),
                id_doc.get_str("date").ok()
            ) {
                if let Ok(date) = NaiveDate::parse_from_str(date_str, "%Y-%m-%d") {
                    account_dates.push((account.to_string(), date));
                }
            }
        }
    }
    
    Ok(account_dates)
}

async fn initialize_all_documents(
    collection: &mongodb::Collection<bson::Document>,
    source_collection: &mongodb::Collection<bson::Document>,
    account_dates: &[(String, NaiveDate)],
) -> Result<()> {
    let mut rng = thread_rng();
    
    for (account, date) in account_dates {
        // Read actual transactions for this account+date
        let date_start = naive_date_to_bson(*date);
        let date_end = naive_date_to_bson(*date + chrono::Duration::days(1));
        
        let mut cursor = source_collection
            .find(doc! {
                "iacct": account,
                "dtrans": {
                    "$gte": date_start,
                    "$lt": date_end
                }
            })
            .await?;
        
        let mut statements = Vec::new();
        while cursor.advance().await? {
            let doc = cursor.deserialize_current()?;
            statements.push(Bson::Document(doc));
        }
        
        // Create document with initial statements
        let mut doc = generate_account_date_document(account, *date, &mut rng);
        doc.insert("statements", Bson::Array(statements));
        
        collection.insert_one(doc).await?;
    }
    
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
    source_collection: &mongodb::Collection<bson::Document>,
    hot_documents: &[HotDocument],
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

    // Simulate batch writes: repeatedly append to same hot documents
    for write_num in 0..WRITES_PER_DOCUMENT {
        let batch_start = Instant::now();

        // Write to all hot documents
        for hot_doc in hot_documents {
            let (write_time, stmt_count) = perform_single_write(
                collection,
                &hot_doc.account,
                hot_doc.date,
                source_collection
            ).await?;
            
            // Skip if no data was written
            if write_time > 0.0 {
                min_write_time = min_write_time.min(write_time);
                max_write_time = max_write_time.max(write_time);
                sum_write_time += write_time;
                total_writes += 1;
                total_statements_written += stmt_count;
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
        min_write_time: if min_write_time == f64::MAX { 0.0 } else { min_write_time },
        max_write_time,
        avg_write_time: if total_writes > 0 { sum_write_time / total_writes as f64 } else { 0.0 },
    })
}

async fn perform_single_write(
    collection: &mongodb::Collection<bson::Document>,
    account_no: &str,
    date: NaiveDate,
    source_collection: &mongodb::Collection<bson::Document>,
) -> Result<(f64, usize)> {
    let write_start = Instant::now();

    // Read ALL transactions from source collection for this account and date (no limit)
    let date_start = naive_date_to_bson(date);
    let date_end = naive_date_to_bson(date + chrono::Duration::days(1));
    
    let mut cursor = source_collection
        .find(doc! {
            "iacct": account_no,
            "dtrans": {
                "$gte": date_start,
                "$lt": date_end
            }
        })
        .await?;
    
    let mut statements = Vec::new();
    while cursor.advance().await? {
        let doc = cursor.deserialize_current()?;
        statements.push(Bson::Document(doc));
    }
    
    // If no transactions found, skip this write
    if statements.is_empty() {
        return Ok((0.0, 0));
    }

    let stmt_count = statements.len();
    let update_doc = doc! {
        "$push": { "statements": { "$each": statements } }
    };

    // Update document with compound key: account + date
    collection
        .update_one(
            doc! { 
                "iacct": account_no,
                "dtrans": date_start
            },
            update_doc
        )
        .await?;

    Ok((write_start.elapsed().as_secs_f64() * 1000.0, stmt_count))
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
    hot_documents: &[HotDocument],
) -> Result<()> {
    println!("📄 Hot Document Analysis:");
    println!("   Analyzing document growth for hot documents...\n");
    
    for (idx, hot_doc) in hot_documents.iter().enumerate() {
        let stats = analyze_hot_document(collection, &hot_doc.account, hot_doc.date).await?;
        print_hot_document_statistics(&hot_doc.account, hot_doc.date, idx + 1, hot_documents.len(), &stats);
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

async fn analyze_hot_document(
    collection: &mongodb::Collection<bson::Document>,
    account_no: &str,
    date: NaiveDate,
) -> Result<AccountStatistics> {
    let doc = collection
        .find_one(doc! {
            "iacct": account_no,
            "dtrans": naive_date_to_bson(date)
        })
        .await?;
    
    if let Some(doc) = doc {
        let stmt_count = doc.get_array("statements").map(|arr| arr.len()).unwrap_or(0);
        let doc_size = bson::to_vec(&doc)?.len();
        
        Ok(AccountStatistics {
            doc_count: 1,
            total_statements: stmt_count,
            total_size: doc_size,
            min_stmts: stmt_count,
            max_stmts: stmt_count,
            sample_docs: vec![],
        })
    } else {
        Ok(AccountStatistics {
            doc_count: 0,
            total_statements: 0,
            total_size: 0,
            min_stmts: 0,
            max_stmts: 0,
            sample_docs: vec![],
        })
    }
}

fn print_hot_document_statistics(
    account_no: &str,
    date: NaiveDate,
    index: usize,
    total: usize,
    stats: &AccountStatistics,
) {
    println!("   🔥 Hot Document {} ({}/{})", index, index, total);
    println!("      • Account: {}", account_no);
    println!("      • Date: {}", date);
    println!("      • Statements in document:    {:>6}", stats.total_statements);
    println!("      • Document size:             {:>6} KB ({:.2} MB)", 
        stats.total_size / 1024,
        stats.total_size as f64 / 1024.0 / 1024.0
    );
    
    // Calculate write rate for this hot document
    let writes_performed = WRITES_PER_DOCUMENT;
    let initial_count = stats.total_statements / (writes_performed + 1); // Approximate
    let writes_per_sec = if initial_count > 0 {
        format!("{} writes × {} stmt/write", writes_performed, initial_count)
    } else {
        "N/A".to_string()
    };
    println!("      • Write pattern:             {}", writes_per_sec);
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
