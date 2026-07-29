use axum::extract::Query;
use axum::extract::{Path, State};
use axum::Json;
use serde::Deserialize;

use crate::app_state::AppState;
use crate::error::ApiError;
use crate::memory::engine::{
    approve_candidate, create_candidates, list_candidates, reject_candidate,
    ApproveCandidateRequest, ExtractCandidatesRequest, ExtractCandidatesResponse,
    ListCandidatesResponse, MemoryResponse,
};

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ListCandidatesQuery {
    pub user_id: Option<String>,
    pub workspace_id: Option<String>,
    pub repo_id: Option<String>,
    pub agent_id: Option<String>,
    pub session_id: Option<String>,
    pub status: Option<String>,
    pub limit: Option<i64>,
    pub offset: Option<i64>,
}

pub async fn list(
    State(state): State<AppState>,
    Query(query): Query<ListCandidatesQuery>,
) -> Result<Json<ListCandidatesResponse>, ApiError> {
    Ok(Json(
        list_candidates(
            &state.db,
            query.user_id.as_deref(),
            query.workspace_id.as_deref(),
            query.repo_id.as_deref(),
            query.agent_id.as_deref(),
            query.session_id.as_deref(),
            query.status.as_deref(),
            query.limit,
            query.offset,
        )
        .await?,
    ))
}

pub async fn extract(
    State(state): State<AppState>,
    Json(request): Json<ExtractCandidatesRequest>,
) -> Result<Json<ExtractCandidatesResponse>, ApiError> {
    let response = create_candidates(&state.db, request).await?;
    if response.auto_applied_change_requests > 0 {
        best_effort_rebuild_vector_index(&state).await;
    }
    Ok(Json(response))
}

pub async fn approve(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Json(request): Json<ApproveCandidateRequest>,
) -> Result<Json<MemoryResponse>, ApiError> {
    let item = approve_candidate(&state.db, &id, request).await?;
    crate::http::routes_memory::best_effort_index(&state, &item).await;
    Ok(Json(item))
}

pub async fn reject(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<serde_json::Value>, ApiError> {
    reject_candidate(&state.db, &id).await?;
    Ok(Json(serde_json::json!({ "ok": true })))
}

async fn best_effort_rebuild_vector_index(state: &AppState) {
    if let Err(error) = crate::vector::sqlite_vec_store::rebuild(
        &state.db,
        state.embedder.as_ref(),
        state.embedding_dimension,
    )
    .await
    {
        tracing::warn!(%error, "failed to rebuild memory vector index after candidate auto-change");
    }
}
