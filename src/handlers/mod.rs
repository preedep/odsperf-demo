pub mod health;
pub mod mongo;
pub mod pg;

use crate::state::AppState;
use axum::{
    Router,
    routing::{get, post},
};
use std::sync::Arc;
use tower_http::{
    cors::CorsLayer,
    request_id::{MakeRequestUuid, PropagateRequestIdLayer, SetRequestIdLayer},
    timeout::TimeoutLayer,
    trace::TraceLayer,
};
use tracing::Span;

pub fn router(state: Arc<AppState>) -> Router {
    let request_id_header =
        axum::http::HeaderName::from_static("x-request-id");

    Router::new()
        // Health
        .route("/health", get(health::handle))
        // ODS query APIs
        .route("/v1/query-pg",    post(pg::handle))
        .route("/v1/query-mongo", post(mongo::handle))
        // Shared state
        .with_state(state)
        // ── Middleware stack (applied bottom-up) ───────────────────────────
        // 1. Request ID — generate and propagate x-request-id
        .layer(PropagateRequestIdLayer::new(request_id_header.clone()))
        .layer(SetRequestIdLayer::new(
            request_id_header,
            MakeRequestUuid,
        ))
        // 2. Structured HTTP access log
        .layer(
            TraceLayer::new_for_http()
                .make_span_with(|req: &axum::http::Request<_>| {
                    let request_id = req
                        .headers()
                        .get("x-request-id")
                        .and_then(|v| v.to_str().ok())
                        .unwrap_or("-");
                    tracing::info_span!(
                        "http",
                        method  = %req.method(),
                        path    = %req.uri().path(),
                        request_id = %request_id,
                    )
                })
                .on_response(
                    |resp: &axum::http::Response<_>,
                     latency: std::time::Duration,
                     _span: &Span| {
                        tracing::info!(
                            status     = resp.status().as_u16(),
                            latency_ms = latency.as_millis(),
                            "response"
                        );
                    },
                ),
        )
        // 3. Timeout — reject requests that take > 30 s
        .layer(TimeoutLayer::new(std::time::Duration::from_secs(30)))
        // 4. CORS — allow all origins (tighten for production)
        .layer(CorsLayer::permissive())
}
