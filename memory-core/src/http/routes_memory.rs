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
    let item = create_manual_memory(&state.db, request).await?;
    best_effort_index(&state, &item).await;
    Ok(Json(item))
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
    let item = patch_memory(&state.db, &id, request).await?;
    best_effort_index(&state, &item).await;
    Ok(Json(item))
}

pub async fn delete(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<serde_json::Value>, ApiError> {
    soft_delete_memory(&state.db, &id).await?;
    if let Err(error) = crate::vector::sqlite_vec_store::delete(&state.db, &id).await {
        tracing::warn!(%error, memory_id = %id, "failed to delete memory vector");
    }
    Ok(Json(serde_json::json!({ "ok": true })))
}

pub async fn search(
    State(state): State<AppState>,
    Json(request): Json<SearchRequest>,
) -> Result<Json<SearchResponse>, ApiError> {
    Ok(Json(
        search_memory(
            &state.db,
            request,
            state.embedder.as_ref(),
            state.embedding_dimension,
        )
        .await?,
    ))
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
    let indexed = crate::vector::sqlite_vec_store::rebuild(
        &state.db,
        state.embedder.as_ref(),
        state.embedding_dimension,
    )
    .await?;
    Ok(Json(serde_json::json!({ "ok": true, "indexed": indexed })))
}

pub async fn best_effort_index(state: &AppState, item: &MemoryResponse) {
    let memory = crate::vector::sqlite_vec_store::IndexedMemory {
        id: item.id.clone(),
        user_id: item.user_id.clone(),
        workspace_id: item.workspace_id.clone(),
        repo_id: item.repo_id.clone(),
        agent_id: item.agent_id.clone(),
        session_id: item.session_id.clone(),
        kind: serde_json::to_value(item.kind)
            .ok()
            .and_then(|value| value.as_str().map(ToOwned::to_owned))
            .unwrap_or_else(|| "unknown".to_string()),
        scope: item.scope.clone(),
        status: item.status.clone(),
        text: item.text.clone(),
    };
    if let Err(error) = crate::vector::sqlite_vec_store::upsert(
        &state.db,
        state.embedder.as_ref(),
        state.embedding_dimension,
        &memory,
    )
    .await
    {
        tracing::warn!(
            %error,
            memory_id = %item.id,
            "failed to update memory vector index"
        );
    }
}
