use crate::memory::types::{MemoryKind, MemoryScope};
use crate::memory::{ranker, redactor};
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

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PreExtractedCandidate {
    pub kind: MemoryKind,
    pub scope: String,
    pub text: String,
    pub confidence: Option<f32>,
    pub reason: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExtractCandidatesRequest {
    pub scope: MemoryScope,
    #[serde(default)]
    pub pre_extracted_candidates: Vec<PreExtractedCandidate>,
}

#[derive(Debug, Serialize)]
pub struct ExtractCandidatesResponse {
    pub candidates: Vec<MemoryCandidateResponse>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MemoryCandidateResponse {
    pub id: String,
    pub kind: MemoryKind,
    pub scope: String,
    pub text: String,
    pub confidence: Option<f32>,
    pub reason: Option<String>,
    pub status: String,
}

#[derive(Debug, Deserialize)]
pub struct ApproveCandidateRequest {
    pub kind: MemoryKind,
    pub scope: String,
    pub text: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SearchRequest {
    pub query: String,
    pub scope: MemoryScope,
    pub limit: Option<i64>,
}

#[derive(Debug, Serialize)]
pub struct SearchResponse {
    pub items: Vec<SearchItem>,
}

#[derive(Debug, Serialize)]
pub struct SearchItem {
    pub id: String,
    pub kind: String,
    pub scope: String,
    pub text: String,
    pub score: f32,
    pub metadata: serde_json::Value,
}

pub async fn create_manual_memory(
    pool: &SqlitePool,
    request: CreateMemoryRequest,
) -> sqlx::Result<MemoryResponse> {
    let now = Utc::now().timestamp_millis();
    let id = format!("mem_{}", Uuid::new_v4());
    let kind = kind_to_wire(request.kind);
    let text = redactor::redact(request.text.trim());
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
    .bind(&text)
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
    let text = request
        .text
        .map(|text| redactor::redact(text.trim()))
        .unwrap_or(current.text);
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

pub async fn create_candidates(
    pool: &SqlitePool,
    request: ExtractCandidatesRequest,
) -> sqlx::Result<ExtractCandidatesResponse> {
    let mut accepted = Vec::new();
    let now = Utc::now().timestamp_millis();
    for candidate in request.pre_extracted_candidates {
        if !crate::memory::policy::accepts_candidate(&candidate.text, candidate.confidence) {
            continue;
        }

        let id = format!("cand_{}", Uuid::new_v4());
        let kind = kind_to_wire(candidate.kind);
        sqlx::query(
            "insert into memory_candidates
            (id, user_id, workspace_id, repo_id, agent_id, session_id, kind, scope, text, reason, confidence, status, created_at)
            values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?)",
        )
        .bind(&id)
        .bind(&request.scope.user_id)
        .bind(&request.scope.workspace_id)
        .bind(&request.scope.repo_id)
        .bind(&request.scope.agent_id)
        .bind(&request.scope.session_id)
        .bind(kind)
        .bind(&candidate.scope)
        .bind(&candidate.text)
        .bind(&candidate.reason)
        .bind(candidate.confidence)
        .bind(now)
        .execute(pool)
        .await?;
        write_audit(
            pool,
            "extractor",
            "candidate.create",
            None,
            Some(&id),
            None,
            serde_json::json!({}),
        )
        .await?;
        accepted.push(MemoryCandidateResponse {
            id,
            kind: candidate.kind,
            scope: candidate.scope,
            text: candidate.text,
            confidence: candidate.confidence,
            reason: candidate.reason,
            status: "pending".to_string(),
        });
    }
    Ok(ExtractCandidatesResponse {
        candidates: accepted,
    })
}

pub async fn approve_candidate(
    pool: &SqlitePool,
    candidate_id: &str,
    request: ApproveCandidateRequest,
) -> sqlx::Result<MemoryResponse> {
    let row = sqlx::query(
        "select user_id, workspace_id, repo_id, agent_id, session_id
         from memory_candidates where id = ? and status = 'pending'",
    )
    .bind(candidate_id)
    .fetch_one(pool)
    .await?;
    let scope_data = MemoryScope {
        user_id: row.get("user_id"),
        workspace_id: row.get("workspace_id"),
        repo_id: row.get("repo_id"),
        agent_id: row.get("agent_id"),
        session_id: row.get("session_id"),
    };
    let item = create_manual_memory(
        pool,
        CreateMemoryRequest {
            kind: request.kind,
            scope: request.scope,
            text: request.text,
            scope_data,
        },
    )
    .await?;
    sqlx::query("update memory_candidates set status = 'approved', reviewed_at = ? where id = ?")
        .bind(Utc::now().timestamp_millis())
        .bind(candidate_id)
        .execute(pool)
        .await?;
    write_audit(
        pool,
        "user",
        "candidate.approve",
        Some(&item.id),
        Some(candidate_id),
        None,
        serde_json::json!({}),
    )
    .await?;
    Ok(item)
}

pub async fn search_memory(
    pool: &SqlitePool,
    request: SearchRequest,
) -> sqlx::Result<SearchResponse> {
    let limit = request.limit.unwrap_or(12).clamp(1, 50);
    let tokens = query_tokens(&request.query);
    let rows = sqlx::query(
        "select id, kind, scope, text, source_session_id, source_turn_id, repo_id, workspace_id, updated_at
         from memory_items
         where status = 'active'
           and user_id = ?
           and (repo_id = ? or workspace_id = ? or scope = 'global')
         order by updated_at desc
         limit 200",
    )
    .bind(&request.scope.user_id)
    .bind(&request.scope.repo_id)
    .bind(&request.scope.workspace_id)
    .fetch_all(pool)
    .await?;
    let mut scored = Vec::new();
    for row in rows {
        let text: String = row.get("text");
        let lexical_score = lexical_score(&text, &tokens);
        if lexical_score <= 0.0 {
            continue;
        }
        let kind: String = row.get("kind");
        let scope: String = row.get("scope");
        let score = ranker::final_score(
            lexical_score,
            scope_score(
                &scope,
                row.get::<Option<String>, _>("repo_id").as_deref(),
                row.get::<Option<String>, _>("workspace_id").as_deref(),
                request.scope.repo_id.as_deref(),
                request.scope.workspace_id.as_deref(),
            ),
            1.0,
        );
        scored.push((
            score,
            ranker::kind_priority(&kind),
            row.get::<i64, _>("updated_at"),
            SearchItem {
                id: row.get("id"),
                kind,
                scope,
                text,
                score,
                metadata: serde_json::json!({
                    "sourceSessionId": row.get::<Option<String>, _>("source_session_id"),
                    "sourceTurnId": row.get::<Option<String>, _>("source_turn_id")
                }),
            },
        ));
    }
    scored.sort_by(|left, right| {
        right
            .0
            .partial_cmp(&left.0)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| left.1.cmp(&right.1))
            .then_with(|| right.2.cmp(&left.2))
    });
    Ok(SearchResponse {
        items: scored
            .into_iter()
            .take(limit as usize)
            .map(|(_, _, _, item)| item)
            .collect(),
    })
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

fn query_tokens(query: &str) -> Vec<String> {
    query
        .split(|character: char| !character.is_alphanumeric())
        .map(str::trim)
        .filter(|token| token.chars().count() >= 2)
        .map(|token| token.to_ascii_lowercase())
        .collect()
}

fn lexical_score(text: &str, tokens: &[String]) -> f32 {
    if tokens.is_empty() {
        return 1.0;
    }
    let lower = text.to_ascii_lowercase();
    let matches = tokens
        .iter()
        .filter(|token| lower.contains(token.as_str()))
        .count();
    if matches == 0 {
        return 0.0;
    }
    matches as f32 / tokens.len() as f32
}

fn scope_score(
    scope: &str,
    item_repo_id: Option<&str>,
    item_workspace_id: Option<&str>,
    query_repo_id: Option<&str>,
    query_workspace_id: Option<&str>,
) -> f32 {
    if item_repo_id.is_some() && item_repo_id == query_repo_id {
        return 1.0;
    }
    if item_workspace_id.is_some() && item_workspace_id == query_workspace_id {
        return 0.85;
    }
    if scope == "global" {
        return 0.65;
    }
    0.5
}
