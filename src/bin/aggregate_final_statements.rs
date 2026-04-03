use anyhow::Result;
use bson::{doc, Document};
use futures_util::TryStreamExt;
use mongodb::{options::ClientOptions, Client, Collection, Database};
use std::collections::HashMap;
use std::env;
use std::time::Instant;

const TARGET_COLLECTION: &str = "final_statements";
const ACCOUNT_MASTER_COLLECTION: &str = "account_master";
const ACCOUNT_TRANSACTION_COLLECTION: &str = "account_transaction";
const BATCH_SIZE: usize = 1000;

/// Connect to MongoDB and verify connection
async fn connect_to_mongodb(uri: &str, db_name: &str) -> Result<Database> {
    println!("🔌 Connecting to MongoDB...");
    let client_options = ClientOptions::parse(uri).await?;
    let client = Client::with_options(client_options)?;
    let db = client.database(db_name);
    db.run_command(doc! { "ping": 1 }).await?;
    println!("✅ Connected successfully\n");
    Ok(db)
}

/// Load all account master documents into a HashMap
async fn load_account_masters(collection: &Collection<Document>) -> Result<HashMap<String, Document>> {
    println!("📊 Reading account_master collection...");
    let mut account_masters = HashMap::new();
    let mut cursor = collection.find(doc! {}).await?;
    
    while let Some(doc) = cursor.try_next().await? {
        if let Ok(iacct) = doc.get_str("iacct") {
            account_masters.insert(iacct.to_string(), doc);
        }
    }
    
    println!("✅ Found {} accounts\n", account_masters.len());
    Ok(account_masters)
}

/// Build aggregation pipeline for grouping transactions by account AND dtrans
fn build_aggregation_pipeline() -> Vec<Document> {
    vec![
        doc! {
            "$sort": {
                "iacct": 1,
                "dtrans": 1,
                "cseq": 1
            }
        },
        doc! {
            "$group": {
                "_id": {
                    "iacct": "$iacct",
                    "dtrans": "$dtrans"
                },
                "statements": {
                    "$push": {
                        "drun": "$drun",
                        "cseq": "$cseq",
                        "dtrans": "$dtrans",
                        "ddate": "$ddate",
                        "ttime": "$ttime",
                        "cmnemo": "$cmnemo",
                        "cchannel": "$cchannel",
                        "ctr": "$ctr",
                        "cbr": "$cbr",
                        "cterm": "$cterm",
                        "camt": "$camt",
                        "aamount": "$aamount",
                        "abal": "$abal",
                        "description": "$description",
                        "time_hms": "$time_hms"
                    }
                }
            }
        }
    ]
}

/// Merge account master data with aggregated statements
fn merge_account_with_statements(
    account_master: &Document,
    iacct: &str,
    dtrans: &bson::Bson,
    statements: &bson::Array,
) -> Document {
    let mut final_doc = account_master.clone();
    // Remove _id to let MongoDB generate new ones
    final_doc.remove("_id");
    final_doc.insert("iacct", iacct);
    final_doc.insert("dtrans", dtrans.clone());
    final_doc.insert("statements", statements.clone());
    final_doc
}

/// Aggregate transactions and merge with account masters
async fn aggregate_and_merge(
    transaction_collection: &Collection<Document>,
    target_collection: &Collection<Document>,
    account_masters: &HashMap<String, Document>,
) -> Result<(usize, usize)> {
    println!("📊 Aggregating transactions by account...");
    let start = Instant::now();
    
    let pipeline = build_aggregation_pipeline();
    let mut cursor = transaction_collection.aggregate(pipeline).await?;
    
    let mut documents_to_insert = Vec::new();
    let mut processed = 0;
    let mut skipped = 0;

    while let Some(result) = cursor.try_next().await? {
        // Parse _id as document with iacct and dtrans
        let id_doc = result.get_document("_id")?;
        let iacct = id_doc.get_str("iacct")?;
        let dtrans = id_doc.get("dtrans")
            .ok_or_else(|| anyhow::anyhow!("Missing dtrans in _id"))?;
        
        if let Some(account_master) = account_masters.get(iacct) {
            let statements = result.get_array("statements")?;
            
            let final_doc = merge_account_with_statements(account_master, iacct, dtrans, statements);
            documents_to_insert.push(final_doc);
            processed += 1;
            
            // Batch insert
            if documents_to_insert.len() >= BATCH_SIZE {
                target_collection.insert_many(&documents_to_insert).await?;
                println!("   → Inserted {} documents...", processed);
                documents_to_insert.clear();
            }
        } else {
            skipped += 1;
            eprintln!("   ⚠ Warning: No account_master found for {}", iacct);
        }
    }

    // Insert remaining documents
    if !documents_to_insert.is_empty() {
        target_collection.insert_many(&documents_to_insert).await?;
    }

    let elapsed = start.elapsed();
    println!("✅ Aggregation complete in {:.2}s", elapsed.as_secs_f64());
    println!("   • Processed: {} accounts", processed);
    if skipped > 0 {
        println!("   • Skipped: {} accounts (no master data)", skipped);
    }
    println!();
    
    Ok((processed, skipped))
}

/// Create index on the target collection
async fn create_index(collection: &Collection<Document>) -> Result<()> {
    println!("🔧 Creating index on {{iacct: 1, dtrans: 1}}...");
    let index_model = mongodb::IndexModel::builder()
        .keys(doc! { "iacct": 1, "dtrans": 1 })
        .build();
    collection.create_index(index_model).await?;
    println!("✅ Index created\n");
    Ok(())
}

/// Display collection statistics and sample document
async fn show_statistics(collection: &Collection<Document>) -> Result<()> {
    println!("╔══════════════════════════════════════════════════════════════╗");
    println!("║                    Collection Statistics                     ║");
    println!("╚══════════════════════════════════════════════════════════════╝\n");

    let count = collection.count_documents(doc! {}).await?;
    println!("📊 Documents: {}", count);

    if let Some(sample) = collection.find_one(doc! {}).await? {
        println!("\n📄 Sample Document:");
        if let Ok(iacct) = sample.get_str("iacct") {
            println!("   • Account: {}", iacct);
        }
        if let Ok(custid) = sample.get_str("custid") {
            println!("   • Customer: {}", custid);
        }
        if let Ok(ctype) = sample.get_str("ctype") {
            println!("   • Type: {}", ctype);
        }
        if let Ok(statements) = sample.get_array("statements") {
            println!("   • Statements: {} transactions", statements.len());
        }
    }
    
    Ok(())
}

/// Print next steps instructions
fn print_next_steps(mongodb_uri: &str) {
    println!("\n╔══════════════════════════════════════════════════════════════╗");
    println!("║                         Success!                             ║");
    println!("╚══════════════════════════════════════════════════════════════╝\n");

    println!("💡 Next Steps:");
    println!("  1. Test the API endpoint:");
    println!("     ./scripts/test-api.sh --nojoin");
    println!();
    println!("  2. Compare with JOIN query:");
    println!("     ./scripts/test-api.sh --join");
    println!();
    println!("  3. Query directly:");
    println!("     mongosh \"{}\" --eval 'db.{}.findOne({{iacct: \"10000007942\"}})'\n", 
             mongodb_uri, TARGET_COLLECTION);
}

#[tokio::main]
async fn main() -> Result<()> {
    let mongodb_uri = env::var("MONGODB_URI")
        .unwrap_or_else(|_| "mongodb://odsuser:odspassword@localhost:27017/odsperf".to_string());
    let mongodb_db = env::var("MONGODB_DB").unwrap_or_else(|_| "odsperf".to_string());

    println!("╔══════════════════════════════════════════════════════════════╗");
    println!("║  Aggregate final_statements from Real Data                  ║");
    println!("╚══════════════════════════════════════════════════════════════╝\n");

    // Connect to MongoDB
    let db = connect_to_mongodb(&mongodb_uri, &mongodb_db).await?;
    
    // Get collections
    let target_collection = db.collection::<Document>(TARGET_COLLECTION);
    let account_master_collection = db.collection::<Document>(ACCOUNT_MASTER_COLLECTION);
    let account_transaction_collection = db.collection::<Document>(ACCOUNT_TRANSACTION_COLLECTION);

    // Drop existing collection
    println!("🗑️  Dropping existing '{}' collection...", TARGET_COLLECTION);
    let _ = target_collection.drop().await;
    println!("✅ Collection dropped\n");

    // Load account masters
    let account_masters = load_account_masters(&account_master_collection).await?;

    // Aggregate and merge
    aggregate_and_merge(&account_transaction_collection, &target_collection, &account_masters).await?;

    // Create index
    create_index(&target_collection).await?;

    // Show statistics
    show_statistics(&target_collection).await?;

    // Print next steps
    print_next_steps(&mongodb_uri);

    Ok(())
}
