use crate::service;
use crate::state::AppState;
use axum::{Json, Router, extract::State, http::StatusCode, routing::get};
use serde_json::json;
use std::sync::Arc;
use std::sync::atomic::Ordering;

const PATH_HIT: &str = "/api/hit";
const PATH_ERROR: &str = "/api/error";
const PATH_HEALTH: &str = "/health";
const PATH_SPAN: &str = "/api/span";

pub fn router(state: Arc<AppState>) -> Router {
    Router::new()
        .route(PATH_HEALTH, get(health))
        .route(PATH_HIT, get(hit))
        .route(PATH_ERROR, get(report_error))
        .route(PATH_SPAN, get(test_span))
        .with_state(state)
}

#[tracing::instrument]
async fn health() -> Json<serde_json::Value> {
    Json(json!({ "status": "ok" }))
}

#[tracing::instrument(skip(state))]
async fn hit(State(state): State<Arc<AppState>>) -> Json<serde_json::Value> {
    let n = state.hit_count.fetch_add(1, Ordering::Relaxed) + 1;
    Json(json!({ "hits": n }))
}

#[tracing::instrument]
async fn report_error() -> StatusCode {
    let err = std::io::Error::other("mock failure for k6");
    sentry::capture_error(&err);
    StatusCode::INTERNAL_SERVER_ERROR
}

fn span_summary() -> String {
    sentry::configure_scope(|scope| match scope.get_span() {
        Some(span) => {
            let ctx = span.get_trace_context();
            format!(
                "span_id={} trace_id={} op={:?}",
                ctx.span_id, ctx.trace_id, ctx.op
            )
        }
        None => "none".to_string(),
    })
}

#[tracing::instrument]
async fn test_span() -> Json<serde_json::Value> {
    let user = service::get_user(crate::config::TEST_USER_ID).await;
    let span = span_summary();
    tracing::warn!(sentry_span = %span, "span:{span},user:{user}");
    Json(json!({ "user": user }))
}
