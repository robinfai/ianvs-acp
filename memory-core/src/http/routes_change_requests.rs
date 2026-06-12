use axum::extract::{Path, Query, State};
use axum::Json;
use serde::Deserialize;

use crate::app_state::AppState;
use crate::error::ApiError;
use crate::memory::engine::{
    approve_change_request, create_change_request, list_change_requests,
    list_visible_change_requests, reject_change_request, run_maintenance,
    ApproveChangeRequestRequest, CreateChangeRequestRequest, ListChangeRequestsResponse,
    MaintenanceRunRequest, MaintenanceRunResponse, MemoryChangeRequestResponse,
};
use crate::memory::types::MemoryScope;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ListChangeRequestsQuery {
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
    Query(query): Query<ListChangeRequestsQuery>,
) -> Result<Json<ListChangeRequestsResponse>, ApiError> {
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
            list_visible_change_requests(&state.db, &scope, query.status.as_deref()).await?,
        ));
    }
    Ok(Json(
        list_change_requests(
            &state.db,
            query.user_id.as_deref(),
            query.repo_id.as_deref(),
            query.status.as_deref(),
        )
        .await?,
    ))
}

pub async fn create(
    State(state): State<AppState>,
    Json(request): Json<CreateChangeRequestRequest>,
) -> Result<Json<MemoryChangeRequestResponse>, ApiError> {
    Ok(Json(create_change_request(&state.db, request).await?))
}

pub async fn approve(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Json(request): Json<ApproveChangeRequestRequest>,
) -> Result<Json<MemoryChangeRequestResponse>, ApiError> {
    let change_request = approve_change_request(&state.db, &id, request).await?;
    best_effort_rebuild_vector_index(&state).await;
    Ok(Json(change_request))
}

pub async fn reject(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<MemoryChangeRequestResponse>, ApiError> {
    Ok(Json(reject_change_request(&state.db, &id).await?))
}

pub async fn maintenance_run(
    State(state): State<AppState>,
    Json(request): Json<MaintenanceRunRequest>,
) -> Result<Json<MaintenanceRunResponse>, ApiError> {
    let result = run_maintenance(&state.db, request).await?;
    if result.auto_applied > 0 {
        best_effort_rebuild_vector_index(&state).await;
    }
    Ok(Json(result))
}

async fn best_effort_rebuild_vector_index(state: &AppState) {
    if let Err(error) = crate::vector::sqlite_vec_store::rebuild(
        &state.db,
        state.embedder.as_ref(),
        state.embedding_dimension,
    )
    .await
    {
        tracing::warn!(%error, "failed to rebuild memory vector index after change request");
    }
}
