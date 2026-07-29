use axum::extract::{Request, State};
use axum::http::header::AUTHORIZATION;
use axum::middleware::{self, Next};
use axum::response::Response;
use axum::routing::{get, patch, post};
use axum::Router;

use crate::app_state::AppState;
use crate::error::ApiError;

pub mod routes_candidates;
pub mod routes_change_requests;
pub mod routes_health;
pub mod routes_memory;

pub fn router(state: AppState) -> Router {
    let protected = Router::new()
        .route(
            "/v1/memory",
            get(routes_memory::list).post(routes_memory::create),
        )
        .route(
            "/v1/memory/extract-candidates",
            post(routes_candidates::extract),
        )
        .route("/v1/memory/candidates", get(routes_candidates::list))
        .route("/v1/memory/search", post(routes_memory::search))
        .route("/v1/memory/export", post(routes_memory::export))
        .route("/v1/memory/import", post(routes_memory::import))
        .route("/v1/memory/clear", post(routes_memory::clear))
        .route(
            "/v1/memory/destroy-database",
            post(routes_memory::destroy_database),
        )
        .route("/v1/memory/audit", get(routes_memory::audit))
        .route(
            "/v1/memory/format-context",
            post(routes_memory::format_context),
        )
        .route(
            "/v1/memory/rebuild-vector-index",
            post(routes_memory::rebuild_vector_index),
        )
        .route(
            "/v1/memory/candidates/{id}/approve",
            post(routes_candidates::approve),
        )
        .route(
            "/v1/memory/candidates/{id}/reject",
            post(routes_candidates::reject),
        )
        .route(
            "/v1/memory/change-requests",
            get(routes_change_requests::list).post(routes_change_requests::create),
        )
        .route(
            "/v1/memory/change-requests/{id}",
            patch(routes_change_requests::patch),
        )
        .route(
            "/v1/memory/change-requests/{id}/approve",
            post(routes_change_requests::approve),
        )
        .route(
            "/v1/memory/change-requests/{id}/reject",
            post(routes_change_requests::reject),
        )
        .route(
            "/v1/memory/maintenance/run",
            post(routes_change_requests::maintenance_run),
        )
        .route(
            "/v1/memory/{id}",
            patch(routes_memory::patch).delete(routes_memory::delete),
        )
        .route("/v1/memory/{id}/feedback", post(routes_memory::feedback))
        .route_layer(middleware::from_fn_with_state(state.clone(), auth));

    Router::new()
        .route("/health", get(routes_health::health))
        .merge(protected)
        .with_state(state)
}

async fn auth(
    State(state): State<AppState>,
    request: Request,
    next: Next,
) -> Result<Response, ApiError> {
    let expected = format!("Bearer {}", state.token);
    let actual = request
        .headers()
        .get(AUTHORIZATION)
        .and_then(|value| value.to_str().ok());
    if actual != Some(expected.as_str()) {
        return Err(ApiError::Unauthorized);
    }
    Ok(next.run(request).await)
}
