use axum::extract::{Path, State};
use axum::Json;

use crate::app_state::AppState;
use crate::error::ApiError;
use crate::memory::engine::{
    approve_candidate, create_candidates, ApproveCandidateRequest, ExtractCandidatesRequest,
    ExtractCandidatesResponse, MemoryResponse,
};

pub async fn extract(
    State(state): State<AppState>,
    Json(request): Json<ExtractCandidatesRequest>,
) -> Result<Json<ExtractCandidatesResponse>, ApiError> {
    Ok(Json(create_candidates(&state.db, request).await?))
}

pub async fn approve(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Json(request): Json<ApproveCandidateRequest>,
) -> Result<Json<MemoryResponse>, ApiError> {
    Ok(Json(approve_candidate(&state.db, &id, request).await?))
}
