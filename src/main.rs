mod config;
mod db;
mod error;
mod handlers;
mod models;
mod state;

use std::{net::SocketAddr, sync::Arc};
use tracing::info;

use crate::config::LogFormat;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // ── Load configuration ───────────────────────────────────────────────
    let cfg = config::Config::from_env()?;

    // ── Initialize structured logging ────────────────────────────────────
    init_tracing(&cfg.log_format);

    info!(
        service = "odsperf-demo",
        version = env!("CARGO_PKG_VERSION"),
        "starting"
    );

    // ── Database connections ─────────────────────────────────────────────
    let pg    = db::postgres::connect(&cfg.database_url).await?;
    let mongo = db::mongodb::connect(&cfg.mongodb_uri, &cfg.mongodb_db).await?;

    let state = Arc::new(state::AppState { pg, mongo });

    // ── Initialize Prometheus metrics exporter ───────────────────────────
    let metrics_handle = init_metrics();

    // ── Build router ─────────────────────────────────────────────────────
    let app = handlers::router(state, metrics_handle);

    // ── Serve ────────────────────────────────────────────────────────────
    let addr = SocketAddr::from(([0, 0, 0, 0], cfg.port));
    let listener = tokio::net::TcpListener::bind(addr).await?;

    info!(%addr, "listening");

    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await?;

    info!("server stopped");
    Ok(())
}

/// Wait for SIGTERM (Kubernetes pod termination) or Ctrl-C.
async fn shutdown_signal() {
    use tokio::signal;

    let ctrl_c = async {
        signal::ctrl_c().await.expect("ctrl-c handler failed");
    };

    #[cfg(unix)]
    let sigterm = async {
        signal::unix::signal(signal::unix::SignalKind::terminate())
            .expect("sigterm handler failed")
            .recv()
            .await;
    };

    #[cfg(not(unix))]
    let sigterm = std::future::pending::<()>();

    tokio::select! {
        _ = ctrl_c  => info!("received ctrl-c"),
        _ = sigterm => info!("received SIGTERM"),
    }
}

fn init_tracing(format: &LogFormat) {
    use tracing_subscriber::{fmt, prelude::*, EnvFilter};

    let filter = EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| EnvFilter::new("info"));

    match format {
        LogFormat::Json => {
            tracing_subscriber::registry()
                .with(filter)
                .with(fmt::layer().json().flatten_event(true))
                .init();
        }
        LogFormat::Pretty => {
            tracing_subscriber::registry()
                .with(filter)
                .with(fmt::layer().pretty())
                .init();
        }
    }
}

fn init_metrics() -> metrics_exporter_prometheus::PrometheusHandle {
    use metrics_exporter_prometheus::PrometheusBuilder;

    PrometheusBuilder::new()
        .set_buckets(&[
            0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0,
        ])
        .expect("failed to set histogram buckets")
        .install_recorder()
        .expect("failed to install Prometheus recorder")
}
