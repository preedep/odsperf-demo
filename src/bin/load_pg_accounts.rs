// =============================================================================
// load_pg_accounts — Load mock_accounts.csv → PostgreSQL odsperf.account_master
// Reads the CSV produced by generate_account_csv.
//
// Usage:
//   cargo run --release --bin load_pg_accounts
//   CSV_PATH=data/mock_accounts.csv DATABASE_URL=... cargo run --release --bin load_pg_accounts
// =============================================================================

use anyhow::Result;
use chrono::NaiveDate;
use csv::ReaderBuilder;
use rust_decimal::Decimal;
use sqlx::postgres::PgPoolOptions;
use std::env;
use std::str::FromStr;
use std::time::Instant;

const BATCH_SIZE: usize = 2_000;

#[derive(Debug)]
struct AccountRow {
    iacct:        String,
    custid:       String,
    ctype:        String,
    dopen:        NaiveDate,
    dclose:       Option<NaiveDate>,
    cstatus:      String,
    cbranch:      String,
    segment:      String,
    credit_limit: Option<Decimal>,
}

#[tokio::main]
async fn main() -> Result<()> {
    let csv_path = env::var("CSV_PATH")
        .unwrap_or_else(|_| "data/mock_accounts.csv".to_string());

    let database_url = env::var("DATABASE_URL")
        .unwrap_or_else(|_| {
            "postgresql://odsuser:odspassword@localhost:5432/odsperf".to_string()
        });

    println!("🚀 PostgreSQL Account Master Loader");
    println!("📁 CSV     : {}", csv_path);
    println!("🔌 Target  : odsperf.account_master");

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
    let mut batch: Vec<AccountRow> = Vec::with_capacity(BATCH_SIZE);
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
                "✓ Batch {:>4} | {:>7} / {} | {:.2}s batch | {:.0} rows/s",
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
    println!("\n🎉 PostgreSQL account_master load complete!");
    println!("📊 Inserted : {}", total_inserted);
    println!("⏱️  Time     : {:.2}s", elapsed.as_secs_f64());
    println!(
        "⚡ Speed    : {:.0} rows/s",
        total_inserted as f64 / elapsed.as_secs_f64()
    );

    Ok(())
}

// ─── Batch INSERT ─────────────────────────────────────────────────────────────
async fn insert_batch(pool: &sqlx::PgPool, rows: &[AccountRow]) -> Result<()> {
    let mut tx = pool.begin().await?;

    for r in rows {
        sqlx::query(
            r#"
            INSERT INTO odsperf.account_master (
                iacct, custid, ctype, dopen, dclose,
                cstatus, cbranch, segment, credit_limit
            ) VALUES (
                $1, $2, $3, $4, $5, $6, $7, $8, $9
            )
            ON CONFLICT (iacct) DO NOTHING
            "#,
        )
        .bind(&r.iacct)
        .bind(&r.custid)
        .bind(&r.ctype)
        .bind(r.dopen)
        .bind(r.dclose)
        .bind(&r.cstatus)
        .bind(&r.cbranch)
        .bind(&r.segment)
        .bind(r.credit_limit)
        .execute(&mut *tx)
        .await?;
    }

    tx.commit().await?;
    Ok(())
}

// ─── CSV row parser ───────────────────────────────────────────────────────────
fn parse_row(r: &csv::StringRecord) -> Result<AccountRow> {
    // iacct, custid, ctype, dopen, dclose, cstatus, cbranch, segment, credit_limit
    let dclose = if r[4].is_empty() {
        None
    } else {
        Some(NaiveDate::parse_from_str(&r[4], "%Y-%m-%d")?)
    };

    let credit_limit = if r[8].is_empty() {
        None
    } else {
        Some(Decimal::from_str(&r[8])?)
    };

    Ok(AccountRow {
        iacct:        r[0].to_string(),
        custid:       r[1].to_string(),
        ctype:        r[2].to_string(),
        dopen:        NaiveDate::parse_from_str(&r[3], "%Y-%m-%d")?,
        dclose,
        cstatus:      r[5].to_string(),
        cbranch:      r[6].to_string(),
        segment:      r[7].to_string(),
        credit_limit,
    })
}
