use mongodb::Database;
use sqlx::PgPool;
use tokio::time::{interval, Duration};
use std::sync::Arc;

/// Shared application state injected into every handler via axum `State`.
pub struct AppState {
    pub pg:    PgPool,
    pub mongo: Database,
}

impl AppState {
    /// Start background task to collect database connection pool metrics
    pub fn start_pool_metrics_collector(state: Arc<Self>) {
        tokio::spawn(async move {
            let mut interval = interval(Duration::from_secs(5));
            
            loop {
                interval.tick().await;
                
                // PostgreSQL connection pool metrics
                let pg_size = state.pg.size();
                let pg_idle = state.pg.num_idle() as u32;
                let pg_active = pg_size.saturating_sub(pg_idle);
                
                metrics::gauge!("db_pool_connections_total", "database" => "postgresql")
                    .set(pg_size as f64);
                metrics::gauge!("db_pool_connections_active", "database" => "postgresql")
                    .set(pg_active as f64);
                metrics::gauge!("db_pool_connections_idle", "database" => "postgresql")
                    .set(pg_idle as f64);
            }
        });
    }
}
