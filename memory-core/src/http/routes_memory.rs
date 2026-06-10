use axum::extract::{Path, Query, State};
use axum::Json;
use serde::Deserialize;

use crate::app_state::AppState;
use crate::error::ApiError;
use crate::memory::engine::{
    create_manual_memory, list_memory, patch_memory, search_memory, soft_delete_memory,
    CreateMemoryRequest, ListMemoryResponse, MemoryResponse, PatchMemoryRequest, SearchRequest,
    SearchResponse,
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

pub async fn search(
    State(state): State<AppState>,
    Json(request): Json<SearchRequest>,
) -> Result<Json<SearchResponse>, ApiError> {
    Ok(Json(search_memory(&state.db, request).await?))
}

pub async fn format_context(Json(items): Json<Vec<(String, String)>>) -> Json<serde_json::Value> {
    let borrowed = items
        .iter()
        .map(|(kind, text)| (kind.as_str(), text.as_str()))
        .collect::<Vec<_>>();
    Json(serde_json::json!({
        "text": crate::memory::formatter::format_context(&borrowed)
    }))
}

pub async fn rebuild_vector_index(
    State(state): State<AppState>,
) -> Result<Json<serde_json::Value>, ApiError> {
    crate::vector::sqlite_vec_store::rebuild(&state.db, 384).await?;
    Ok(Json(serde_json::json!({ "ok": true })))
}
