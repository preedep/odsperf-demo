use axum::{http::StatusCode, Json};
use serde_json::{json, Value};

/// GET /health
/// Used by Kubernetes liveness and readiness probes.
pub async fn handle() -> (StatusCode, Json<Value>) {
    (
        StatusCode::OK,
        Json(json!({
            "status":  "ok",
            "service": "odsperf-demo",
            "version": env!("CARGO_PKG_VERSION"),
        })),
    )
}
