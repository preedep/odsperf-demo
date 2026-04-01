use mongodb::Database;
use sqlx::PgPool;

/// Shared application state injected into every handler via axum `State`.
pub struct AppState {
    pub pg:    PgPool,
    pub mongo: Database,
}
