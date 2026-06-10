use axum::extract::{Request, State};
use axum::http::header::AUTHORIZATION;
use axum::middleware::{self, Next};
use axum::response::Response;
use axum::routing::get;
use axum::Router;

use crate::app_state::AppState;
use crate::error::ApiError;

pub mod routes_health;

pub fn router(state: AppState) -> Router {
    let protected = Router::new()
        .route("/v1/memory", get(|| async { "[]" }))
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
