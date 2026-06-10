use axum::extract::{Path, Query, State};
use axum::Json;
use serde::Deserialize;

use crate::app_state::AppState;
use crate::error::ApiError;
use crate::memory::engine::{
    create_manual_memory, list_memory, patch_memory, soft_delete_memory, CreateMemoryRequest,
    ListMemoryResponse, MemoryResponse, PatchMemoryRequest,
};

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ListQuery {
    pub user_id: Option<String>,
    pub repo_id: Option<String>,
    pub status: Option<String>,
}

pub async fn create(
    State(state): State<AppState>,
    Json(request): Json<CreateMemoryRequest>,
) -> Result<Json<MemoryResponse>, ApiError> {
    Ok(Json(create_manual_memory(&state.db, request).await?))
}

pub async fn list(
    State(state): State<AppState>,
    Query(query): Query<ListQuery>,
) -> Result<Json<ListMemoryResponse>, ApiError> {
    Ok(Json(
        list_memory(
            &state.db,
            query.user_id.as_deref(),
            query.repo_id.as_deref(),
            query.status.as_deref(),
        )
        .await?,
    ))
}

pub async fn patch(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Json(request): Json<PatchMemoryRequest>,
) -> Result<Json<MemoryResponse>, ApiError> {
    Ok(Json(patch_memory(&state.db, &id, request).await?))
}

pub async fn delete(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<serde_json::Value>, ApiError> {
    soft_delete_memory(&state.db, &id).await?;
    Ok(Json(serde_json::json!({ "ok": true })))
}
