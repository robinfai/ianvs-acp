use crate::memory::types::{MemoryKind, MemoryScope};
use chrono::Utc;
use serde::{Deserialize, Serialize};
use sqlx::{Row, SqlitePool};
use uuid::Uuid;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CreateMemoryRequest {
    pub kind: MemoryKind,
    pub scope: String,
    pub text: String,
    pub scope_data: MemoryScope,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PatchMemoryRequest {
    pub kind: Option<MemoryKind>,
    pub scope: Option<String>,
    pub text: Option<String>,
    pub status: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MemoryResponse {
    pub id: String,
    pub kind: MemoryKind,
    pub scope: String,
    pub text: String,
    pub user_id: String,
    pub workspace_id: Option<String>,
    pub repo_id: Option<String>,
    pub agent_id: Option<String>,
    pub session_id: Option<String>,
    pub source: String,
    pub status: String,
    pub created_at: i64,
    pub updated_at: i64,
}

#[derive(Debug, Serialize)]
pub struct ListMemoryResponse {
    pub items: Vec<MemoryResponse>,
}

pub async fn create_manual_memory(
    pool: &SqlitePool,
    request: CreateMemoryRequest,
) -> sqlx::Result<MemoryResponse> {
    let now = Utc::now().timestamp_millis();
    let id = format!("mem_{}", Uuid::new_v4());
    let kind = kind_to_wire(request.kind);
    sqlx::query(
        "insert into memory_items
        (id, user_id, workspace_id, repo_id, agent_id, session_id, kind, scope, text, source, status, created_at, updated_at)
        values (?, ?, ?, ?, ?, ?, ?, ?, ?, 'manual', 'active', ?, ?)",
    )
    .bind(&id)
    .bind(&request.scope_data.user_id)
    .bind(&request.scope_data.workspace_id)
    .bind(&request.scope_data.repo_id)
    .bind(&request.scope_data.agent_id)
    .bind(&request.scope_data.session_id)
    .bind(&kind)
    .bind(&request.scope)
    .bind(&request.text)
    .bind(now)
    .bind(now)
    .execute(pool)
    .await?;
    write_audit(
        pool,
        "user",
        "memory.create",
        Some(&id),
        None,
        None,
        serde_json::json!({"source": "manual"}),
    )
    .await?;
    get_memory(pool, &id).await
}

pub async fn list_memory(
    pool: &SqlitePool,
    user_id: Option<&str>,
    repo_id: Option<&str>,
    status: Option<&str>,
) -> sqlx::Result<ListMemoryResponse> {
    let user_id = user_id.unwrap_or("%");
    let repo_id = repo_id.unwrap_or("%");
    let status = status.unwrap_or("%");
    let rows = sqlx::query(
        "select id, kind, scope, text, user_id, workspace_id, repo_id, agent_id, session_id, source, status, created_at, updated_at
         from memory_items
         where user_id like ? and coalesce(repo_id, '') like ? and status like ?
         order by updated_at desc",
    )
    .bind(user_id)
    .bind(repo_id)
    .bind(status)
    .fetch_all(pool)
    .await?;

    let items = rows
        .into_iter()
        .map(row_to_memory)
        .collect::<sqlx::Result<Vec<_>>>()?;
    Ok(ListMemoryResponse { items })
}

pub async fn patch_memory(
    pool: &SqlitePool,
    id: &str,
    request: PatchMemoryRequest,
) -> sqlx::Result<MemoryResponse> {
    let current = get_memory(pool, id).await?;
    let kind = kind_to_wire(request.kind.unwrap_or(current.kind));
    let scope = request.scope.unwrap_or(current.scope);
    let text = request.text.unwrap_or(current.text);
    let status = request.status.unwrap_or(current.status);
    let now = Utc::now().timestamp_millis();
    let result = sqlx::query(
        "update memory_items set kind = ?, scope = ?, text = ?, status = ?, updated_at = ? where id = ?",
    )
    .bind(kind)
    .bind(scope)
    .bind(text)
    .bind(status)
    .bind(now)
    .bind(id)
    .execute(pool)
    .await?;
    if result.rows_affected() == 0 {
        return Err(sqlx::Error::RowNotFound);
    }
    write_audit(
        pool,
        "user",
        "memory.update",
        Some(id),
        None,
        None,
        serde_json::json!({}),
    )
    .await?;
    get_memory(pool, id).await
}

pub async fn soft_delete_memory(pool: &SqlitePool, id: &str) -> sqlx::Result<()> {
    let now = Utc::now().timestamp_millis();
    let result = sqlx::query(
        "update memory_items set status = 'deleted', deleted_at = ?, updated_at = ? where id = ?",
    )
    .bind(now)
    .bind(now)
    .bind(id)
    .execute(pool)
    .await?;
    if result.rows_affected() == 0 {
        return Err(sqlx::Error::RowNotFound);
    }
    write_audit(
        pool,
        "user",
        "memory.delete",
        Some(id),
        None,
        None,
        serde_json::json!({"soft": true}),
    )
    .await
}

async fn get_memory(pool: &SqlitePool, id: &str) -> sqlx::Result<MemoryResponse> {
    let row = sqlx::query(
        "select id, kind, scope, text, user_id, workspace_id, repo_id, agent_id, session_id, source, status, created_at, updated_at
         from memory_items where id = ?",
    )
    .bind(id)
    .fetch_one(pool)
    .await?;
    row_to_memory(row)
}

async fn write_audit(
    pool: &SqlitePool,
    actor: &str,
    action: &str,
    memory_id: Option<&str>,
    candidate_id: Option<&str>,
    change_request_id: Option<&str>,
    payload: serde_json::Value,
) -> sqlx::Result<()> {
    sqlx::query(
        "insert into memory_audit_log (id, actor, action, memory_id, candidate_id, change_request_id, payload_json, created_at)
         values (?, ?, ?, ?, ?, ?, ?, ?)",
    )
    .bind(format!("audit_{}", Uuid::new_v4()))
    .bind(actor)
    .bind(action)
    .bind(memory_id)
    .bind(candidate_id)
    .bind(change_request_id)
    .bind(payload.to_string())
    .bind(Utc::now().timestamp_millis())
    .execute(pool)
    .await?;
    Ok(())
}

fn row_to_memory(row: sqlx::sqlite::SqliteRow) -> sqlx::Result<MemoryResponse> {
    let kind: String = row.get("kind");
    Ok(MemoryResponse {
        id: row.get("id"),
        kind: serde_json::from_value(serde_json::Value::String(kind))
            .map_err(|error| sqlx::Error::Decode(Box::new(error)))?,
        scope: row.get("scope"),
        text: row.get("text"),
        user_id: row.get("user_id"),
        workspace_id: row.get("workspace_id"),
        repo_id: row.get("repo_id"),
        agent_id: row.get("agent_id"),
        session_id: row.get("session_id"),
        source: row.get("source"),
        status: row.get("status"),
        created_at: row.get("created_at"),
        updated_at: row.get("updated_at"),
    })
}

fn kind_to_wire(kind: MemoryKind) -> &'static str {
    match kind {
        MemoryKind::UserPreference => "user_preference",
        MemoryKind::ProjectRule => "project_rule",
        MemoryKind::ArchitectureDecision => "architecture_decision",
        MemoryKind::SessionSummary => "session_summary",
    }
}
