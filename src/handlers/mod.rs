pub mod health;
pub mod mongo;
pub mod pg;

use crate::state::AppState;
use axum::{
    Router,
    routing::{get, post},
    response::IntoResponse,
    extract::Request,
    middleware::{self, Next},
};
use std::sync::Arc;
use tower_http::{
    cors::CorsLayer,
    request_id::{MakeRequestUuid, PropagateRequestIdLayer, SetRequestIdLayer},
    timeout::TimeoutLayer,
    trace::TraceLayer,
};
use tracing::Span;
use metrics_exporter_prometheus::PrometheusHandle;

pub fn router(state: Arc<AppState>, metrics_handle: PrometheusHandle) -> Router {
    let request_id_header =
        axum::http::HeaderName::from_static("x-request-id");

    // Wrap metrics_handle in Arc for sharing across requests
    let metrics_handle = Arc::new(metrics_handle);

    Router::new()
        // Health
        .route("/health", get(health::handle))
        // Metrics endpoint for Prometheus
        .route("/metrics", get({
            let handle = Arc::clone(&metrics_handle);
            move || async move { handle.render() }
        }))
        // ODS query APIs
        .route("/v1/query-pg",    post(pg::handle))
        .route("/v1/query-mongo", post(mongo::handle))
        // Shared state
        .with_state(state)
        // ── Middleware stack (applied bottom-up) ───────────────────────────
        // 0. Metrics tracking
        .layer(middleware::from_fn(metrics_middleware))
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
                    let path = req.uri().path().to_string();
                    tracing::info_span!(
                        "http",
                        method  = %req.method(),
                        path    = %path,
                        request_id = %request_id,
                    )
                })
                .on_response(
                    |resp: &axum::http::Response<_>,
                     latency: std::time::Duration,
                     _span: &Span| {
                        let status = resp.status().as_u16();
                        let latency_ms = latency.as_millis();
                        
                        tracing::info!(
                            status     = status,
                            latency_ms = latency_ms,
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

async fn metrics_middleware(req: Request, next: Next) -> impl IntoResponse {
    // Skip /metrics scrape endpoint to avoid self-referential noise
    let path = req.uri().path().to_string();
    if path == "/metrics" {
        return next.run(req).await;
    }

    let method = req.method().to_string();

    let start    = std::time::Instant::now();
    let response = next.run(req).await;
    let latency  = start.elapsed();

    let status = response.status().as_u16().to_string();

    // Record metrics with labels
    metrics::counter!("http_requests_total", "method" => method.clone(), "path" => path.clone(), "status" => status).increment(1);
    metrics::histogram!("http_request_duration_seconds", "method" => method, "path" => path).record(latency.as_secs_f64());

    response
}
