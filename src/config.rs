use anyhow::Context;

/// Runtime configuration loaded from environment variables.
///
/// | Variable          | Required | Default   | Description                     |
/// |-------------------|----------|-----------|---------------------------------|
/// | DATABASE_URL      | ✅        | —         | PostgreSQL connection string     |
/// | MONGODB_URI       | ✅        | —         | MongoDB connection string        |
/// | MONGODB_DB        | ❌        | odsperf   | MongoDB database name            |
/// | PORT              | ❌        | 8080      | HTTP listen port                 |
/// | RUST_LOG          | ❌        | info      | tracing filter (e.g. debug)      |
/// | RUST_LOG_FORMAT   | ❌        | pretty    | "json" for structured output     |
#[derive(Debug, Clone)]
pub struct Config {
    pub database_url:  String,
    pub mongodb_uri:   String,
    pub mongodb_db:    String,
    pub port:          u16,
    pub log_format:    LogFormat,
}

#[derive(Debug, Clone, PartialEq)]
pub enum LogFormat {
    Json,
    Pretty,
}

impl Config {
    pub fn from_env() -> anyhow::Result<Self> {
        Ok(Self {
            database_url: std::env::var("DATABASE_URL")
                .context("DATABASE_URL is required")?,
            mongodb_uri: std::env::var("MONGODB_URI")
                .context("MONGODB_URI is required")?,
            mongodb_db: std::env::var("MONGODB_DB")
                .unwrap_or_else(|_| "odsperf".to_string()),
            port: std::env::var("PORT")
                .unwrap_or_else(|_| "8080".to_string())
                .parse::<u16>()
                .context("PORT must be a valid u16")?,
            log_format: match std::env::var("RUST_LOG_FORMAT")
                .unwrap_or_default()
                .as_str()
            {
                "json" => LogFormat::Json,
                _      => LogFormat::Pretty,
            },
        })
    }
}
