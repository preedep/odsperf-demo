use anyhow::Result;
use chrono::NaiveDate;
use rand::prelude::*;
use rust_decimal::Decimal;
use sqlx::postgres::PgPoolOptions;
use std::env;
use std::time::Instant;

const TOTAL_RECORDS: usize = 1_000_000;
const BATCH_SIZE: usize = 5_000;

#[tokio::main]
async fn main() -> Result<()> {
    println!("🚀 Starting PostgreSQL Mock Data Generator");
    println!("📊 Target: {} records", TOTAL_RECORDS);
    println!("📦 Batch size: {}", BATCH_SIZE);

    let database_url = env::var("DATABASE_URL")
        .unwrap_or_else(|_| "postgresql://odsuser:odspassword@localhost:5432/odsperf".to_string());

    println!("🔌 Connecting to PostgreSQL...");
    let pool = PgPoolOptions::new()
        .max_connections(5)
        .connect(&database_url)
        .await?;

    println!("✅ Connected successfully");

    let start_time = Instant::now();
    let mut rng = thread_rng();

    let mut total_inserted = 0;

    for batch_num in 0..(TOTAL_RECORDS / BATCH_SIZE) {
        let batch_start = Instant::now();

        let mut tx = pool.begin().await?;

        for _ in 0..BATCH_SIZE {
            let record = generate_random_record(&mut rng);

            sqlx::query(
                r#"
                INSERT INTO odsperf.account_transaction (
                    iacct, drun, cseq, ddate, dtrans, ttime, cmnemo, cchannel,
                    ctr, cbr, cterm, camt, aamount, abal, description, time_hms
                ) VALUES (
                    $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16
                )
                "#,
            )
            .bind(&record.iacct)
            .bind(record.drun)
            .bind(record.cseq)
            .bind(record.ddate)
            .bind(record.dtrans)
            .bind(&record.ttime)
            .bind(&record.cmnemo)
            .bind(&record.cchannel)
            .bind(&record.ctr)
            .bind(&record.cbr)
            .bind(&record.cterm)
            .bind(&record.camt)
            .bind(record.aamount)
            .bind(record.abal)
            .bind(&record.description)
            .bind(&record.time_hms)
            .execute(&mut *tx)
            .await?;
        }

        tx.commit().await?;

        total_inserted += BATCH_SIZE;
        let batch_elapsed = batch_start.elapsed();
        let overall_elapsed = start_time.elapsed();
        let records_per_sec = total_inserted as f64 / overall_elapsed.as_secs_f64();

        println!(
            "✓ Batch {}/{} | Inserted: {} | Batch time: {:.2}s | Total time: {:.2}s | Speed: {:.0} rec/s",
            batch_num + 1,
            TOTAL_RECORDS / BATCH_SIZE,
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

struct TransactionRecord {
    iacct: String,
    drun: NaiveDate,
    cseq: i32,
    ddate: NaiveDate,
    dtrans: Option<NaiveDate>,
    ttime: Option<String>,
    cmnemo: Option<String>,
    cchannel: Option<String>,
    ctr: Option<String>,
    cbr: Option<String>,
    cterm: Option<String>,
    camt: Option<String>,
    aamount: Option<Decimal>,
    abal: Option<Decimal>,
    description: Option<String>,
    time_hms: Option<String>,
}

fn generate_random_record(rng: &mut ThreadRng) -> TransactionRecord {
    let start_date = NaiveDate::from_ymd_opt(2025, 1, 1).unwrap();
    let end_date = NaiveDate::from_ymd_opt(2025, 12, 31).unwrap();
    let days_in_range = (end_date - start_date).num_days();

    let dtrans = start_date + chrono::Duration::days(rng.gen_range(0..=days_in_range));
    let drun = dtrans + chrono::Duration::days(rng.gen_range(0..=3));
    let ddate = dtrans;

    let iacct = format!("{:011}", rng.gen_range(10000000000u64..99999999999u64));

    let cseq = rng.gen_range(1..=9999);

    let hour = rng.gen_range(8..18);
    let minute = rng.gen_range(0..60);
    let second = rng.gen_range(0..60);
    let ttime = Some(format!("{:02}:{:02}", hour, minute));
    let time_hms = Some(format!("{:02}:{:02}:{:02}", hour, minute, second));

    let mnemonics = ["DEP", "WDL", "TRF", "CHQ", "FEE", "INT", "ATM", "POS"];
    let cmnemo = Some(mnemonics[rng.gen_range(0..mnemonics.len())].to_string());

    let channels = ["ATM ", "INET", "MOB ", "BRNC"];
    let cchannel = Some(channels[rng.gen_range(0..channels.len())].to_string());

    let ctr = Some(format!("{:02}", rng.gen_range(1..99)));

    let cbr = Some(format!("{:04}", rng.gen_range(1..9999)));

    let cterm = Some(format!("{:05}", rng.gen_range(1..99999)));

    let is_credit = rng.gen_bool(0.5);
    let camt = Some(if is_credit { "C" } else { "D" }.to_string());

    let amount = Decimal::new(rng.gen_range(100..1000000), 2);
    let aamount = Some(amount);

    let balance = Decimal::new(rng.gen_range(1000..10000000), 2);
    let abal = Some(balance);

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
    let description = Some(descriptions[rng.gen_range(0..descriptions.len())].to_string());

    TransactionRecord {
        iacct,
        drun,
        cseq,
        ddate,
        dtrans: Some(dtrans),
        ttime,
        cmnemo,
        cchannel,
        ctr,
        cbr,
        cterm,
        camt,
        aamount,
        abal,
        description,
        time_hms,
    }
}
