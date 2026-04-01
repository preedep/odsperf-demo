use sqlx::{postgres::PgPoolOptions, PgPool};
use tracing::info;

pub async fn connect(url: &str) -> anyhow::Result<PgPool> {
    info!("connecting to PostgreSQL...");

    let pool = PgPoolOptions::new()
        .max_connections(10)
        .min_connections(2)
        .acquire_timeout(std::time::Duration::from_secs(5))
        .connect(url)
        .await?;

    // Smoke-test
    sqlx::query("SELECT 1").execute(&pool).await?;

    info!("PostgreSQL connected");
    Ok(pool)
}
