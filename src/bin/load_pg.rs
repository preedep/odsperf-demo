// =============================================================================
// load_pg — Load mock_transactions.csv → PostgreSQL
// Reads the SAME CSV produced by generate_csv for apple-to-apple benchmark.
//
// Usage:
//   cargo run --release --bin load_pg
//   CSV_PATH=data/mock_transactions.csv DATABASE_URL=... cargo run --release --bin load_pg
// =============================================================================

use anyhow::Result;
use chrono::NaiveDate;
use csv::ReaderBuilder;
use rust_decimal::Decimal;
use sqlx::postgres::PgPoolOptions;
use std::env;
use std::str::FromStr;
use std::time::Instant;

const BATCH_SIZE: usize = 5_000;

#[derive(Debug)]
struct Row {
    iacct:       String,
    drun:        NaiveDate,
    cseq:        i32,
    ddate:       NaiveDate,
    dtrans:      NaiveDate,
    ttime:       String,
    cmnemo:      String,
    cchannel:    String,
    ctr:         String,
    cbr:         String,
    cterm:       String,
    camt:        String,
    aamount:     Decimal,
    abal:        Decimal,
    description: String,
    time_hms:    String,
}

#[tokio::main]
async fn main() -> Result<()> {
    let csv_path = env::var("CSV_PATH")
        .unwrap_or_else(|_| "data/mock_transactions.csv".to_string());

    let database_url = env::var("DATABASE_URL")
        .unwrap_or_else(|_| {
            "postgresql://odsuser:odspassword@localhost:5432/odsperf".to_string()
        });

    println!("🚀 PostgreSQL CSV Loader");
    println!("📁 CSV     : {}", csv_path);
    println!("🔌 Target  : PostgreSQL");

    let pool = PgPoolOptions::new()
        .max_connections(5)
        .connect(&database_url)
        .await?;
    println!("✅ Connected to PostgreSQL");

    // Count total rows for progress display
    let total_rows = {
        let mut rdr = ReaderBuilder::new().from_path(&csv_path)?;
        rdr.records().count()
    };
    println!("📊 Rows    : {}", total_rows);

    let start = Instant::now();
    let mut rdr = ReaderBuilder::new().from_path(&csv_path)?;
    let mut batch: Vec<Row> = Vec::with_capacity(BATCH_SIZE);
    let mut total_inserted: usize = 0;
    let mut batch_num: usize = 0;

    for result in rdr.records() {
        let record = result?;
        batch.push(parse_row(&record)?);

        if batch.len() == BATCH_SIZE {
            batch_num += 1;
            let batch_start = Instant::now();
            insert_batch(&pool, &batch).await?;
            total_inserted += batch.len();
            batch.clear();

            let overall = start.elapsed().as_secs_f64();
            let speed = total_inserted as f64 / overall;
            println!(
                "✓ Batch {:>4} | {:>9} / {} | {:.2}s batch | {:.0} rows/s",
                batch_num, total_inserted, total_rows,
                batch_start.elapsed().as_secs_f64(), speed
            );
        }
    }

    // Flush remaining rows
    if !batch.is_empty() {
        insert_batch(&pool, &batch).await?;
        total_inserted += batch.len();
    }

    let elapsed = start.elapsed();
    println!("\n🎉 PostgreSQL load complete!");
    println!("📊 Inserted : {}", total_inserted);
    println!("⏱️  Time     : {:.2}s", elapsed.as_secs_f64());
    println!(
        "⚡ Speed    : {:.0} rows/s",
        total_inserted as f64 / elapsed.as_secs_f64()
    );

    Ok(())
}

// ─── Batch INSERT ─────────────────────────────────────────────────────────────
async fn insert_batch(pool: &sqlx::PgPool, rows: &[Row]) -> Result<()> {
    let mut tx = pool.begin().await?;

    for r in rows {
        sqlx::query(
            r#"
            INSERT INTO odsperf.account_transaction (
                iacct, drun, cseq, ddate, dtrans, ttime, cmnemo, cchannel,
                ctr, cbr, cterm, camt, aamount, abal, description, time_hms
            ) VALUES (
                $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16
            )
            ON CONFLICT (iacct, drun, cseq) DO NOTHING
            "#,
        )
        .bind(&r.iacct)
        .bind(r.drun)
        .bind(r.cseq)
        .bind(r.ddate)
        .bind(r.dtrans)
        .bind(&r.ttime)
        .bind(&r.cmnemo)
        .bind(&r.cchannel)
        .bind(&r.ctr)
        .bind(&r.cbr)
        .bind(&r.cterm)
        .bind(&r.camt)
        .bind(r.aamount)
        .bind(r.abal)
        .bind(&r.description)
        .bind(&r.time_hms)
        .execute(&mut *tx)
        .await?;
    }

    tx.commit().await?;
    Ok(())
}

// ─── CSV row parser ───────────────────────────────────────────────────────────
fn parse_row(r: &csv::StringRecord) -> Result<Row> {
    Ok(Row {
        iacct:       r[0].to_string(),
        drun:        NaiveDate::parse_from_str(&r[1], "%Y-%m-%d")?,
        cseq:        r[2].parse()?,
        ddate:       NaiveDate::parse_from_str(&r[3], "%Y-%m-%d")?,
        dtrans:      NaiveDate::parse_from_str(&r[4], "%Y-%m-%d")?,
        ttime:       r[5].to_string(),
        cmnemo:      r[6].to_string(),
        cchannel:    r[7].to_string(),
        ctr:         r[8].to_string(),
        cbr:         r[9].to_string(),
        cterm:       r[10].to_string(),
        camt:        r[11].to_string(),
        aamount:     Decimal::from_str(&r[12])?,
        abal:        Decimal::from_str(&r[13])?,
        description: r[14].to_string(),
        time_hms:    r[15].to_string(),
    })
}
