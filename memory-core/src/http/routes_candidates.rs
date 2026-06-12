use axum::extract::{Path, Query, State};
use axum::Json;
use serde::Deserialize;

use crate::app_state::AppState;
use crate::error::ApiError;
use crate::memory::engine::{
    approve_candidate, create_candidates, list_candidates, list_visible_candidates,
    reject_candidate, ApproveCandidateRequest, ExtractCandidatesRequest, ExtractCandidatesResponse,
    ListCandidatesResponse, MemoryCandidateResponse, MemoryResponse,
};
use crate::memory::types::MemoryScope;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ListCandidatesQuery {
    pub user_id: Option<String>,
    pub workspace_id: Option<String>,
    pub repo_id: Option<String>,
    pub agent_id: Option<String>,
    pub session_id: Option<String>,
    pub status: Option<String>,
    pub visible: Option<bool>,
}

pub async fn list(
    State(state): State<AppState>,
    Query(query): Query<ListCandidatesQuery>,
) -> Result<Json<ListCandidatesResponse>, ApiError> {
    if query.visible.unwrap_or(false) {
        let scope = MemoryScope {
            user_id: query
                .user_id
                .clone()
                .unwrap_or_else(|| "local-user".to_string()),
            workspace_id: query.workspace_id.clone(),
            repo_id: query.repo_id.clone(),
            agent_id: query.agent_id.clone(),
            session_id: query.session_id.clone(),
        };
        return Ok(Json(
            list_visible_candidates(&state.db, &scope, query.status.as_deref()).await?,
        ));
    }
    Ok(Json(
        list_candidates(
            &state.db,
            query.user_id.as_deref(),
            query.repo_id.as_deref(),
            query.status.as_deref(),
        )
        .await?,
    ))
}

pub async fn extract(
    State(state): State<AppState>,
    Json(request): Json<ExtractCandidatesRequest>,
) -> Result<Json<ExtractCandidatesResponse>, ApiError> {
    let response = create_candidates(&state.db, request).await?;
    for item in &response.approved_memories {
        crate::http::routes_memory::best_effort_index(&state, item).await;
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
) -> Result<Json<MemoryCandidateResponse>, ApiError> {
    Ok(Json(reject_candidate(&state.db, &id).await?))
}
