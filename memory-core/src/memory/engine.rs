use crate::config::MaintenanceLlmConfig;
use crate::embedding::embedder::Embedder;
use crate::memory::types::{MemoryKind, MemoryScope, TaskEpisodeData};
use crate::memory::{formatter, ranker, redactor};
use chrono::Utc;
use serde::{Deserialize, Serialize};
use sqlx::{Row, SqlitePool};
use std::collections::{HashMap, HashSet};
use uuid::Uuid;

const MIN_VECTOR_ONLY_SCORE: f32 = 0.5;
const MEMORY_DECAY_RECENT_WINDOW_MS: i64 = 7 * 24 * 60 * 60 * 1000;
const MEMORY_DECAY_NEUTRAL_WINDOW_MS: i64 = 30 * 24 * 60 * 60 * 1000;
const MEMORY_DECAY_STALE_WINDOW_MS: i64 = 90 * 24 * 60 * 60 * 1000;
const MEMORY_DECAY_OLD_WINDOW_MS: i64 = 180 * 24 * 60 * 60 * 1000;
const PINNED_LAYER_RELEVANCE_SCORE: f32 = 0.88;
const PROFILE_AUTO_CONFIDENCE_THRESHOLD: f32 = 0.75;
const AUTO_SUPERSEDE_CONFIDENCE_THRESHOLD: f32 = 0.90;
const PINNED_AUTO_ACCESS_THRESHOLD: i64 = 3;
const MAX_EPISODIC_SEARCH_ITEMS: usize = 2;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CreateMemoryRequest {
    pub kind: MemoryKind,
    pub scope: String,
    pub text: String,
    pub source: Option<String>,
    pub source_session_id: Option<String>,
    pub source_turn_id: Option<String>,
    pub scope_data: MemoryScope,
    #[serde(default)]
    pub entities: Vec<MemoryEntityInput>,
    pub episode: Option<TaskEpisodeData>,
    pub observed_at: Option<i64>,
    pub valid_from: Option<i64>,
    pub valid_until: Option<i64>,
    pub supersedes_memory_id: Option<String>,
    #[serde(default)]
    pub pinned: bool,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MemoryEntityInput {
    pub text: String,
    #[serde(rename = "type")]
    pub entity_type: Option<String>,
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
    pub pinned: bool,
    pub profile_block: Option<serde_json::Value>,
    pub user_id: String,
    pub workspace_id: Option<String>,
    pub repo_id: Option<String>,
    pub agent_id: Option<String>,
    pub session_id: Option<String>,
    pub source: String,
    pub source_session_id: Option<String>,
    pub source_turn_id: Option<String>,
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
    #[serde(default)]
    pub pinned: bool,
    #[serde(default, alias = "instruction_scopes")]
    pub instruction_scopes: Vec<String>,
    #[serde(default)]
    pub entities: Vec<MemoryEntityInput>,
    pub episode: Option<TaskEpisodeData>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExtractCandidatesRequest {
    pub scope: MemoryScope,
    pub source: Option<String>,
    pub source_turn_id: Option<String>,
    #[serde(default)]
    pub pre_extracted_candidates: Vec<PreExtractedCandidate>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ExtractCandidatesResponse {
    pub candidates: Vec<MemoryCandidateResponse>,
    pub auto_applied_change_requests: i64,
}

#[derive(Debug, Serialize)]
pub struct ListCandidatesResponse {
    pub candidates: Vec<MemoryCandidateResponse>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MemoryCandidateResponse {
    pub id: String,
    pub kind: MemoryKind,
    pub source: String,
    pub scope: String,
    pub text: String,
    pub confidence: Option<f32>,
    pub reason: Option<String>,
    pub instruction_scopes: Vec<String>,
    pub episode: Option<TaskEpisodeData>,
    pub status: String,
}

#[derive(Debug, Deserialize)]
pub struct ApproveCandidateRequest {
    pub kind: MemoryKind,
    pub scope: String,
    pub text: String,
    pub actor: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SearchRequest {
    pub query: String,
    pub scope: MemoryScope,
    pub limit: Option<i64>,
    pub pinned_profile_limit: Option<i64>,
    pub turn_id: Option<String>,
    pub reference_time: Option<i64>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClearMemoryRequest {
    pub scope: MemoryScope,
    pub level: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ClearMemoryResponse {
    pub cleared_memory: u64,
    pub rejected_candidates: u64,
    pub rejected_change_requests: u64,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DestroyDatabaseRequest {
    pub confirm: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DestroyDatabaseResponse {
    pub destroyed_memory: i64,
    pub destroyed_candidates: i64,
    pub destroyed_change_requests: i64,
}

#[derive(Debug, Serialize)]
pub struct SearchResponse {
    pub items: Vec<SearchItem>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MemoryFeedbackRequest {
    pub rating: String,
    pub reason: Option<String>,
    pub turn_id: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct MemoryFeedbackResponse {
    pub ok: bool,
}

#[derive(Debug, Serialize)]
pub struct ListAuditResponse {
    pub items: Vec<AuditEventResponse>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AuditEventResponse {
    pub id: String,
    pub actor: String,
    pub action: String,
    pub memory_id: Option<String>,
    pub candidate_id: Option<String>,
    pub change_request_id: Option<String>,
    pub memory_text: Option<String>,
    pub candidate_text: Option<String>,
    pub change_request_text: Option<String>,
    pub payload: serde_json::Value,
    pub created_at: i64,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CreateChangeRequestRequest {
    pub scope: MemoryScope,
    pub action: String,
    pub source: Option<String>,
    #[serde(default)]
    pub target_memory_ids: Vec<String>,
    pub proposed_kind: Option<MemoryKind>,
    pub proposed_scope: Option<String>,
    pub proposed_text: Option<String>,
    pub reason: Option<String>,
    pub confidence: Option<f32>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ApproveChangeRequestRequest {
    pub proposed_kind: Option<MemoryKind>,
    pub proposed_scope: Option<String>,
    pub proposed_text: Option<String>,
    pub actor: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PatchChangeRequestRequest {
    pub proposed_kind: Option<MemoryKind>,
    pub proposed_scope: Option<String>,
    pub proposed_text: Option<String>,
    pub reason: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct ListChangeRequestsResponse {
    pub items: Vec<MemoryChangeRequestResponse>,
}

#[derive(Debug, Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct MemoryChangeRequestResponse {
    pub id: String,
    pub action: String,
    pub source: String,
    pub target_memory_ids: Vec<String>,
    pub target_memory_text: Option<String>,
    pub proposed_kind: Option<MemoryKind>,
    pub proposed_scope: Option<String>,
    pub proposed_text: Option<String>,
    pub reason: Option<String>,
    pub confidence: Option<f32>,
    pub status: String,
    pub created_at: i64,
    pub reviewed_at: Option<i64>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MaintenanceRunRequest {
    pub enabled: Option<bool>,
    pub mode: Option<String>,
    pub cost_mode: Option<String>,
    pub scope: MemoryScope,
    pub high_confidence_threshold: Option<f32>,
    pub review_threshold: Option<f32>,
    pub max_items_per_batch: Option<i64>,
    pub manual_only_actions: Option<Vec<String>>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MaintenanceRunResponse {
    pub auto_applied: i64,
    pub needs_review: i64,
    pub skipped: i64,
    pub existing_auto_approved_change_requests: i64,
    pub auto_rejected_candidates: u64,
    pub auto_rejected_change_requests: i64,
    pub change_requests: Vec<MemoryChangeRequestResponse>,
}

struct MaintenanceProposal {
    action: String,
    target_memory_ids: Vec<String>,
    proposed_kind: MemoryKind,
    proposed_scope: String,
    proposed_text: Option<String>,
    reason: Option<String>,
    confidence: f32,
}

#[derive(Default)]
struct FeedbackStats {
    helpful: i64,
    not_relevant: i64,
    stale: i64,
}

#[derive(Default)]
struct AccessStats {
    access_count: i64,
    last_accessed_at: Option<i64>,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct MemoryEntity {
    text: String,
    #[serde(rename = "type")]
    entity_type: String,
    normalized_text: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct MaintenanceExtractorEnvelope {
    #[serde(default)]
    change_requests: Vec<MaintenanceExtractorItem>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct MaintenanceExtractorItem {
    action: Option<String>,
    #[serde(default)]
    target_memory_ids: Vec<String>,
    proposed_kind: Option<MemoryKind>,
    proposed_scope: Option<String>,
    proposed_text: Option<String>,
    confidence: Option<f32>,
    reason: Option<String>,
}

#[derive(Debug, Deserialize)]
struct ChatCompletionsResponse {
    choices: Vec<ChatChoice>,
}

#[derive(Debug, Deserialize)]
struct ChatChoice {
    message: ChatMessage,
}

#[derive(Debug, Deserialize)]
struct ChatMessage {
    content: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct SearchItem {
    pub id: String,
    pub kind: String,
    pub scope: String,
    pub text: String,
    pub score: f32,
    pub metadata: serde_json::Value,
}

type ScoredSearchItem = (f32, i64, i64, SearchItem);

pub async fn create_manual_memory(
    pool: &SqlitePool,
    request: CreateMemoryRequest,
) -> sqlx::Result<MemoryResponse> {
    let now = Utc::now().timestamp_millis();
    let id = format!("mem_{}", Uuid::new_v4());
    let kind = kind_to_wire(request.kind);
    let text = redactor::redact(request.text.trim());
    let source = normalize_memory_source(request.source.as_deref());
    let episode = normalize_task_episode(request.kind, request.episode);
    let pinned = request.pinned && request.kind != MemoryKind::TaskEpisode;
    sqlx::query(
        "insert into memory_items
        (id, user_id, workspace_id, repo_id, agent_id, session_id, kind, scope, text, source, source_session_id, source_turn_id, observed_at, valid_from, valid_until, supersedes_memory_id, pinned, status, created_at, updated_at)
        values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'active', ?, ?)",
    )
    .bind(&id)
    .bind(&request.scope_data.user_id)
    .bind(&request.scope_data.workspace_id)
    .bind(&request.scope_data.repo_id)
    .bind(&request.scope_data.agent_id)
    .bind(&request.scope_data.session_id)
    .bind(kind)
    .bind(&request.scope)
    .bind(&text)
    .bind(&source)
    .bind(request.source_session_id.as_deref())
    .bind(request.source_turn_id.as_deref())
    .bind(request.observed_at)
    .bind(request.valid_from)
    .bind(request.valid_until)
    .bind(request.supersedes_memory_id.as_deref())
    .bind(if pinned { 1_i64 } else { 0_i64 })
    .bind(now)
    .bind(now)
    .execute(pool)
    .await?;
    upsert_memory_entities(pool, &id, &request.entities).await?;
    upsert_memory_episode(pool, &id, episode.as_ref(), now).await?;
    write_audit(
        pool,
        "user",
        "memory.create",
        Some(&id),
        None,
        None,
        serde_json::json!({"source": source, "episodic": episode.is_some()}),
    )
    .await?;
    get_memory(pool, &id).await
}

#[allow(clippy::too_many_arguments)]
pub async fn list_memory(
    pool: &SqlitePool,
    user_id: Option<&str>,
    workspace_id: Option<&str>,
    repo_id: Option<&str>,
    agent_id: Option<&str>,
    session_id: Option<&str>,
    kind: Option<MemoryKind>,
    status: Option<&str>,
    limit: Option<i64>,
    offset: Option<i64>,
) -> sqlx::Result<ListMemoryResponse> {
    let kind = kind.map(kind_to_wire);
    let limit = limit.unwrap_or(200).clamp(1, 500);
    let offset = offset.unwrap_or(0).max(0);
    let rows = sqlx::query(
        "select id, kind, scope, text, user_id, workspace_id, repo_id, agent_id, session_id, source, source_session_id, source_turn_id, pinned, status, created_at, updated_at
         from memory_items
         where (? is null or user_id = ?)
           and (? is null or kind = ?)
           and (? is null or status = ?)
           and (
               scope = 'global'
               or (
                   scope = 'workspace'
                   and (? is null or workspace_id is null or workspace_id = ?)
               )
               or (
                   scope = 'repo'
                   and (? is null or workspace_id is null or workspace_id = ?)
                   and (? is null or repo_id is null or repo_id = ?)
               )
               or (
                   scope = 'session'
                   and (? is null or workspace_id is null or workspace_id = ?)
                   and (? is null or repo_id is null or repo_id = ?)
                   and (? is null or agent_id is null or agent_id = ?)
                   and (? is null or session_id is null or session_id = ?)
               )
               or (
                   scope not in ('global', 'workspace', 'repo', 'session')
                   and (? is null or workspace_id is null or workspace_id = ?)
                   and (? is null or repo_id is null or repo_id = ?)
                   and (? is null or agent_id is null or agent_id = ?)
                   and (? is null or session_id is null or session_id = ?)
               )
           )
         order by updated_at desc, created_at desc
         limit ? offset ?",
    )
    .bind(user_id)
    .bind(user_id)
    .bind(kind)
    .bind(kind)
    .bind(status)
    .bind(status)
    .bind(workspace_id)
    .bind(workspace_id)
    .bind(workspace_id)
    .bind(workspace_id)
    .bind(repo_id)
    .bind(repo_id)
    .bind(workspace_id)
    .bind(workspace_id)
    .bind(repo_id)
    .bind(repo_id)
    .bind(agent_id)
    .bind(agent_id)
    .bind(session_id)
    .bind(session_id)
    .bind(workspace_id)
    .bind(workspace_id)
    .bind(repo_id)
    .bind(repo_id)
    .bind(agent_id)
    .bind(agent_id)
    .bind(session_id)
    .bind(session_id)
    .bind(limit)
    .bind(offset)
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
    let current_status = current.status.clone();
    let kind = kind_to_wire(request.kind.unwrap_or(current.kind));
    let scope = request.scope.unwrap_or(current.scope);
    let text = request
        .text
        .map(|text| redactor::redact(text.trim()))
        .unwrap_or(current.text);
    let status = request.status.unwrap_or_else(|| current_status.clone());
    let now = Utc::now().timestamp_millis();
    let result = sqlx::query(
        "update memory_items set kind = ?, scope = ?, text = ?, status = ?, updated_at = ? where id = ?",
    )
    .bind(kind)
    .bind(scope)
    .bind(text)
    .bind(&status)
    .bind(now)
    .bind(id)
    .execute(pool)
    .await?;
    if result.rows_affected() == 0 {
        return Err(sqlx::Error::RowNotFound);
    }
    let audit_action = if status == "disabled" && current_status != "disabled" {
        "memory.disable"
    } else if status == "active" && current_status == "disabled" {
        "memory.restore"
    } else if status == "deleted" && current_status != "deleted" {
        "memory.delete"
    } else {
        "memory.update"
    };
    write_audit(
        pool,
        "user",
        audit_action,
        Some(id),
        None,
        None,
        serde_json::json!({"status": status}),
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

pub async fn clear_memory(
    pool: &SqlitePool,
    request: ClearMemoryRequest,
) -> sqlx::Result<ClearMemoryResponse> {
    let now = Utc::now().timestamp_millis();
    let cleared_memory = clear_memory_items(pool, &request.level, &request.scope, now).await?;
    let rejected_candidates =
        reject_pending_candidates(pool, &request.level, &request.scope, now).await?;
    let rejected_change_requests =
        reject_pending_change_requests(pool, &request.level, &request.scope, now).await?;
    write_audit(
        pool,
        "user",
        "memory.clear",
        None,
        None,
        None,
        serde_json::json!({
            "level": request.level,
            "scope": {
                "userId": request.scope.user_id,
                "workspaceId": request.scope.workspace_id,
                "repoId": request.scope.repo_id,
                "agentId": request.scope.agent_id,
                "sessionId": request.scope.session_id
            },
            "clearedMemory": cleared_memory,
            "rejectedCandidates": rejected_candidates,
            "rejectedChangeRequests": rejected_change_requests,
            "soft": true
        }),
    )
    .await?;
    Ok(ClearMemoryResponse {
        cleared_memory,
        rejected_candidates,
        rejected_change_requests,
    })
}

pub async fn destroy_database(pool: &SqlitePool) -> sqlx::Result<DestroyDatabaseResponse> {
    let destroyed_memory: i64 = sqlx::query_scalar("select count(*) from memory_items")
        .fetch_one(pool)
        .await?;
    let destroyed_candidates: i64 = sqlx::query_scalar("select count(*) from memory_candidates")
        .fetch_one(pool)
        .await?;
    let destroyed_change_requests: i64 =
        sqlx::query_scalar("select count(*) from memory_change_requests")
            .fetch_one(pool)
            .await?;
    for table in [
        "memory_items",
        "memory_candidates",
        "memory_change_requests",
        "memory_audit_log",
        "prompt_injections",
        "memory_accesses",
        "memory_feedback",
        "memory_entities",
        "memory_episodes",
        "vector_index_metadata",
    ] {
        sqlx::query(&format!("delete from {table}"))
            .execute(pool)
            .await?;
    }
    Ok(DestroyDatabaseResponse {
        destroyed_memory,
        destroyed_candidates,
        destroyed_change_requests,
    })
}

pub async fn record_memory_feedback(
    pool: &SqlitePool,
    memory_id: &str,
    request: MemoryFeedbackRequest,
) -> sqlx::Result<MemoryFeedbackResponse> {
    let rating = request.rating.trim().to_ascii_lowercase();
    if !matches!(rating.as_str(), "helpful" | "not_relevant" | "stale") {
        return Err(sqlx::Error::RowNotFound);
    }
    let feedback_reason = request.reason.clone();
    let turn_id = request.turn_id.clone();
    let row = sqlx::query("select kind, scope, pinned from memory_items where id = ?")
        .bind(memory_id)
        .fetch_optional(pool)
        .await?;
    let row = row.ok_or(sqlx::Error::RowNotFound)?;
    let memory_kind = kind_from_wire(row.get::<String, _>("kind"))?;
    let memory_scope: String = row.get("scope");
    let was_pinned = row.get::<i64, _>("pinned") != 0;

    let now = Utc::now().timestamp_millis();
    sqlx::query(
        "insert into memory_feedback (id, memory_id, rating, reason, turn_id, created_at)
         values (?, ?, ?, ?, ?, ?)",
    )
    .bind(format!("fb_{}", Uuid::new_v4()))
    .bind(memory_id)
    .bind(&rating)
    .bind(feedback_reason.as_deref())
    .bind(turn_id.as_deref())
    .bind(now)
    .execute(pool)
    .await?;
    write_audit(
        pool,
        "user",
        "memory.feedback",
        Some(memory_id),
        None,
        None,
        serde_json::json!({
            "rating": rating,
            "reason": feedback_reason,
            "turnId": turn_id
        }),
    )
    .await?;
    if rating == "helpful" && !was_pinned && is_profile_layer_kind(memory_kind, &memory_scope) {
        let result = sqlx::query(
            "update memory_items set pinned = 1, updated_at = ? where id = ? and pinned = 0",
        )
        .bind(now)
        .bind(memory_id)
        .execute(pool)
        .await?;
        if result.rows_affected() > 0 {
            write_audit(
                pool,
                "system",
                "memory.promote",
                Some(memory_id),
                None,
                None,
                serde_json::json!({
                    "reason": "helpful_feedback",
                    "rating": rating,
                    "feedbackReason": feedback_reason,
                    "turnId": turn_id
                }),
            )
            .await?;
        }
    } else if rating == "stale" {
        let result = sqlx::query(
            "update memory_items
             set status = 'disabled', pinned = 0, valid_until = coalesce(valid_until, ?), updated_at = ?
             where id = ? and status = 'active'",
        )
        .bind(now)
        .bind(now)
        .bind(memory_id)
        .execute(pool)
        .await?;
        if result.rows_affected() > 0 {
            write_audit(
                pool,
                "system",
                "memory.expire",
                Some(memory_id),
                None,
                None,
                serde_json::json!({
                    "reason": "stale_feedback",
                    "rating": rating,
                    "feedbackReason": feedback_reason,
                    "turnId": turn_id,
                    "validUntil": now
                }),
            )
            .await?;
            if was_pinned {
                write_audit(
                    pool,
                    "system",
                    "memory.unpin",
                    Some(memory_id),
                    None,
                    None,
                    serde_json::json!({
                        "reason": "stale_feedback",
                        "rating": rating,
                        "feedbackReason": feedback_reason,
                        "turnId": turn_id
                    }),
                )
                .await?;
            }
        }
    } else if rating == "not_relevant" {
        if was_pinned {
            let result = sqlx::query(
                "update memory_items set pinned = 0, updated_at = ? where id = ? and pinned != 0",
            )
            .bind(now)
            .bind(memory_id)
            .execute(pool)
            .await?;
            if result.rows_affected() > 0 {
                write_audit(
                    pool,
                    "system",
                    "memory.unpin",
                    Some(memory_id),
                    None,
                    None,
                    serde_json::json!({
                        "reason": "negative_feedback",
                        "rating": rating,
                        "feedbackReason": feedback_reason,
                        "turnId": turn_id
                    }),
                )
                .await?;
            }
        }
        maybe_disable_repeated_not_relevant_feedback(
            pool,
            memory_id,
            now,
            feedback_reason.as_deref(),
            turn_id.as_deref(),
        )
        .await?;
    }
    Ok(MemoryFeedbackResponse { ok: true })
}

async fn maybe_disable_repeated_not_relevant_feedback(
    pool: &SqlitePool,
    memory_id: &str,
    now: i64,
    feedback_reason: Option<&str>,
    turn_id: Option<&str>,
) -> sqlx::Result<()> {
    let row = sqlx::query(
        "select sum(case when rating = 'not_relevant' then 1 else 0 end) as not_relevant,
                sum(case when rating = 'helpful' then 1 else 0 end) as helpful
         from memory_feedback
         where memory_id = ?",
    )
    .bind(memory_id)
    .fetch_one(pool)
    .await?;
    let not_relevant_count = row.get::<i64, _>("not_relevant");
    let helpful_count = row.get::<i64, _>("helpful");
    if not_relevant_count < 2 || helpful_count > 0 {
        return Ok(());
    }

    let result = sqlx::query(
        "update memory_items
         set status = 'disabled', pinned = 0, valid_until = coalesce(valid_until, ?), updated_at = ?
         where id = ? and status = 'active'",
    )
    .bind(now)
    .bind(now)
    .bind(memory_id)
    .execute(pool)
    .await?;
    if result.rows_affected() > 0 {
        write_audit(
            pool,
            "system",
            "memory.disable",
            Some(memory_id),
            None,
            None,
            serde_json::json!({
                "reason": "repeated_not_relevant_feedback",
                "feedbackReason": feedback_reason,
                "turnId": turn_id,
                "notRelevantCount": not_relevant_count,
                "helpfulCount": helpful_count,
                "validUntil": now
            }),
        )
        .await?;
    }
    Ok(())
}

pub async fn create_candidates(
    pool: &SqlitePool,
    request: ExtractCandidatesRequest,
) -> sqlx::Result<ExtractCandidatesResponse> {
    let mut accepted = Vec::new();
    let mut seen_candidate_keys = HashSet::new();
    let mut auto_applied_change_requests = 0_i64;
    let source = normalize_candidate_source(request.source.as_deref());
    let now = Utc::now().timestamp_millis();
    for candidate in request.pre_extracted_candidates {
        let episode = normalize_task_episode(candidate.kind, candidate.episode);
        if candidate.kind == MemoryKind::TaskEpisode && episode.is_none() {
            continue;
        }
        if !crate::memory::policy::accepts_candidate(&candidate.text, candidate.confidence) {
            continue;
        }

        let kind = kind_to_wire(candidate.kind);
        let duplicate_key = candidate_duplicate_key(kind, &candidate.scope, &candidate.text);
        if seen_candidate_keys.contains(&duplicate_key)
            || candidate_duplicate_exists(
                pool,
                &request.scope,
                kind,
                &candidate.scope,
                &candidate.text,
            )
            .await?
        {
            write_audit(
                pool,
                &source,
                "candidate.skip_duplicate",
                None,
                None,
                None,
                serde_json::json!({
                    "kind": kind,
                    "scope": &candidate.scope,
                    "textHash": stable_text_hash(&candidate.text),
                    "reason": "duplicate_candidate",
                }),
            )
            .await?;
            continue;
        }
        seen_candidate_keys.insert(duplicate_key);

        if let Some(target_memory_id) = find_auto_supersede_target(
            pool,
            &request.scope,
            candidate.kind,
            &candidate.scope,
            &candidate.text,
            candidate.confidence,
        )
        .await?
        {
            let change_request = create_change_request(
                pool,
                CreateChangeRequestRequest {
                    scope: request.scope.clone(),
                    action: "supersede".to_string(),
                    source: Some(source.clone()),
                    target_memory_ids: vec![target_memory_id.clone()],
                    proposed_kind: Some(candidate.kind),
                    proposed_scope: Some(candidate.scope.clone()),
                    proposed_text: Some(candidate.text.clone()),
                    reason: candidate.reason.clone().or_else(|| {
                        Some(
                            "High-confidence candidate updates an existing scoped memory."
                                .to_string(),
                        )
                    }),
                    confidence: candidate.confidence,
                },
            )
            .await?;
            approve_change_request_as(
                pool,
                &change_request.id,
                ApproveChangeRequestRequest {
                    proposed_kind: Some(candidate.kind),
                    proposed_scope: Some(candidate.scope.clone()),
                    proposed_text: Some(candidate.text.clone()),
                    actor: None,
                },
                &source,
            )
            .await?;
            write_audit(
                pool,
                &source,
                "candidate.auto_supersede",
                Some(&target_memory_id),
                None,
                Some(&change_request.id),
                serde_json::json!({
                    "kind": kind,
                    "scope": &candidate.scope,
                    "textHash": stable_text_hash(&candidate.text),
                    "confidence": candidate.confidence,
                }),
            )
            .await?;
            auto_applied_change_requests += 1;
            continue;
        }

        let id = format!("cand_{}", Uuid::new_v4());
        let pinned = should_pin_candidate(
            candidate.kind,
            &candidate.scope,
            candidate.confidence,
            candidate.pinned,
        );
        let entities_json =
            serde_json::to_string(&candidate.entities).unwrap_or_else(|_| "[]".to_string());
        let episode_json = episode
            .as_ref()
            .and_then(|value| serde_json::to_string(value).ok());
        let instruction_scopes = clean_instruction_scopes(candidate.instruction_scopes);
        let instruction_scopes_json =
            serde_json::to_string(&instruction_scopes).unwrap_or_else(|_| "[]".to_string());
        sqlx::query(
            "insert into memory_candidates
            (id, user_id, workspace_id, repo_id, agent_id, session_id, source_turn_id, source, kind, scope, text, reason, confidence, pinned, entities_json, episode_json, instruction_scopes_json, status, created_at)
            values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?)",
        )
        .bind(&id)
        .bind(&request.scope.user_id)
        .bind(&request.scope.workspace_id)
        .bind(&request.scope.repo_id)
        .bind(&request.scope.agent_id)
        .bind(&request.scope.session_id)
        .bind(request.source_turn_id.as_deref())
        .bind(&source)
        .bind(kind)
        .bind(&candidate.scope)
        .bind(&candidate.text)
        .bind(&candidate.reason)
        .bind(candidate.confidence)
        .bind(if pinned { 1_i64 } else { 0_i64 })
        .bind(&entities_json)
        .bind(&episode_json)
        .bind(&instruction_scopes_json)
        .bind(now)
        .execute(pool)
        .await?;
        write_audit(
            pool,
            &source,
            "candidate.create",
            None,
            Some(&id),
            None,
            serde_json::json!({
                "source": &source,
                "instructionScopes": instruction_scopes.clone(),
            }),
        )
        .await?;
        accepted.push(MemoryCandidateResponse {
            id,
            kind: candidate.kind,
            source: source.clone(),
            scope: candidate.scope,
            text: candidate.text,
            confidence: candidate.confidence,
            reason: candidate.reason,
            instruction_scopes,
            episode,
            status: "pending".to_string(),
        });
    }
    Ok(ExtractCandidatesResponse {
        candidates: accepted,
        auto_applied_change_requests,
    })
}

#[allow(clippy::too_many_arguments)]
pub async fn list_candidates(
    pool: &SqlitePool,
    user_id: Option<&str>,
    workspace_id: Option<&str>,
    repo_id: Option<&str>,
    agent_id: Option<&str>,
    session_id: Option<&str>,
    status: Option<&str>,
    limit: Option<i64>,
    offset: Option<i64>,
) -> sqlx::Result<ListCandidatesResponse> {
    let limit = limit.unwrap_or(200).clamp(1, 500);
    let offset = offset.unwrap_or(0).max(0);
    let rows = sqlx::query(
        "select id, kind, source, scope, text, confidence, reason, instruction_scopes_json, episode_json, status
         from memory_candidates
         where (? is null or user_id = ?)
           and (? is null or status = ?)
           and (
               scope = 'global'
               or (
                   scope = 'workspace'
                   and (? is null or workspace_id is null or workspace_id = ?)
               )
               or (
                   scope = 'repo'
                   and (? is null or workspace_id is null or workspace_id = ?)
                   and (? is null or repo_id is null or repo_id = ?)
               )
               or (
                   scope = 'session'
                   and (? is null or workspace_id is null or workspace_id = ?)
                   and (? is null or repo_id is null or repo_id = ?)
                   and (? is null or agent_id is null or agent_id = ?)
                   and (? is null or session_id is null or session_id = ?)
               )
               or (
                   scope not in ('global', 'workspace', 'repo', 'session')
                   and (? is null or workspace_id is null or workspace_id = ?)
                   and (? is null or repo_id is null or repo_id = ?)
                   and (? is null or agent_id is null or agent_id = ?)
                   and (? is null or session_id is null or session_id = ?)
               )
           )
         order by created_at desc
         limit ? offset ?",
    )
    .bind(user_id)
    .bind(user_id)
    .bind(status)
    .bind(status)
    .bind(workspace_id)
    .bind(workspace_id)
    .bind(workspace_id)
    .bind(workspace_id)
    .bind(repo_id)
    .bind(repo_id)
    .bind(workspace_id)
    .bind(workspace_id)
    .bind(repo_id)
    .bind(repo_id)
    .bind(agent_id)
    .bind(agent_id)
    .bind(session_id)
    .bind(session_id)
    .bind(workspace_id)
    .bind(workspace_id)
    .bind(repo_id)
    .bind(repo_id)
    .bind(agent_id)
    .bind(agent_id)
    .bind(session_id)
    .bind(session_id)
    .bind(limit)
    .bind(offset)
    .fetch_all(pool)
    .await?;
    Ok(ListCandidatesResponse {
        candidates: rows
            .into_iter()
            .map(row_to_candidate)
            .collect::<sqlx::Result<Vec<_>>>()?,
    })
}

async fn candidate_duplicate_exists(
    pool: &SqlitePool,
    scope: &MemoryScope,
    kind: &str,
    candidate_scope: &str,
    text: &str,
) -> sqlx::Result<bool> {
    let normalized = normalize_duplicate_text(text);
    if normalized.is_empty() {
        return Ok(false);
    }
    if find_active_duplicate_memory_id(pool, scope, kind, candidate_scope, text)
        .await?
        .is_some()
    {
        return Ok(true);
    }

    let pending_rows = sqlx::query(
        "select text, workspace_id, repo_id, agent_id, session_id
         from memory_candidates
         where status = 'pending' and user_id = ? and kind = ? and scope = ?",
    )
    .bind(&scope.user_id)
    .bind(kind)
    .bind(candidate_scope)
    .fetch_all(pool)
    .await?;
    Ok(pending_rows.iter().any(|row| {
        scoped_duplicate_row_matches(scope, candidate_scope, row)
            && normalize_duplicate_text(row.get::<String, _>("text").as_str()) == normalized
    }))
}

async fn find_active_duplicate_memory_id(
    pool: &SqlitePool,
    scope: &MemoryScope,
    kind: &str,
    candidate_scope: &str,
    text: &str,
) -> sqlx::Result<Option<String>> {
    let normalized = normalize_duplicate_text(text);
    if normalized.is_empty() {
        return Ok(None);
    }
    let active_rows = sqlx::query(
        "select id, text, workspace_id, repo_id, agent_id, session_id
         from memory_items
         where status = 'active' and user_id = ? and kind = ? and scope = ?",
    )
    .bind(&scope.user_id)
    .bind(kind)
    .bind(candidate_scope)
    .fetch_all(pool)
    .await?;
    Ok(active_rows.into_iter().find_map(|row| {
        if scoped_duplicate_row_matches(scope, candidate_scope, &row)
            && normalize_duplicate_text(row.get::<String, _>("text").as_str()) == normalized
        {
            Some(row.get("id"))
        } else {
            None
        }
    }))
}

fn scoped_duplicate_row_matches(
    scope: &MemoryScope,
    candidate_scope: &str,
    row: &sqlx::sqlite::SqliteRow,
) -> bool {
    let workspace_id = row.get::<Option<String>, _>("workspace_id");
    let repo_id = row.get::<Option<String>, _>("repo_id");
    let agent_id = row.get::<Option<String>, _>("agent_id");
    let session_id = row.get::<Option<String>, _>("session_id");
    match candidate_scope {
        "global" => true,
        "workspace" => field_matches(scope.workspace_id.as_deref(), workspace_id.as_deref()),
        "repo" => {
            field_matches(scope.workspace_id.as_deref(), workspace_id.as_deref())
                && field_matches(scope.repo_id.as_deref(), repo_id.as_deref())
        }
        "session" => {
            field_matches(scope.workspace_id.as_deref(), workspace_id.as_deref())
                && field_matches(scope.repo_id.as_deref(), repo_id.as_deref())
                && field_matches(scope.agent_id.as_deref(), agent_id.as_deref())
                && field_matches(scope.session_id.as_deref(), session_id.as_deref())
        }
        _ => scoped_context_matches(
            workspace_id.as_deref(),
            repo_id.as_deref(),
            agent_id.as_deref(),
            session_id.as_deref(),
            scope.workspace_id.as_deref(),
            scope.repo_id.as_deref(),
            scope.agent_id.as_deref(),
            scope.session_id.as_deref(),
        ),
    }
}

fn candidate_duplicate_key(kind: &str, scope: &str, text: &str) -> String {
    format!("{}|{}|{}", kind, scope, normalize_duplicate_text(text))
}

fn normalize_duplicate_text(text: &str) -> String {
    text.chars()
        .filter(|character| character.is_alphanumeric())
        .flat_map(char::to_lowercase)
        .collect()
}

async fn find_auto_supersede_target(
    pool: &SqlitePool,
    scope: &MemoryScope,
    kind: MemoryKind,
    candidate_scope: &str,
    text: &str,
    confidence: Option<f32>,
) -> sqlx::Result<Option<String>> {
    if !can_auto_supersede_candidate(kind, candidate_scope, confidence) {
        return Ok(None);
    }
    let normalized = normalize_duplicate_text(text);
    if normalized.is_empty() {
        return Ok(None);
    }
    let rows = sqlx::query(
        "select id, text, workspace_id, repo_id, agent_id, session_id, valid_until
         from memory_items
         where status = 'active' and user_id = ? and kind = ? and scope = ?
         order by
           case when valid_until is null then 0 else 1 end,
           updated_at desc,
           created_at desc",
    )
    .bind(&scope.user_id)
    .bind(kind_to_wire(kind))
    .bind(candidate_scope)
    .fetch_all(pool)
    .await?;

    let reference_time = Utc::now().timestamp_millis();
    for row in rows {
        if !scoped_duplicate_row_matches(scope, candidate_scope, &row) {
            continue;
        }
        if let Some(valid_until) = row.get::<Option<i64>, _>("valid_until") {
            if valid_until <= reference_time {
                continue;
            }
        }
        let existing_text = row.get::<String, _>("text");
        let existing_normalized = normalize_duplicate_text(&existing_text);
        if existing_normalized == normalized {
            continue;
        }
        if memory_texts_conflict_for_auto_supersede(&existing_text, text) {
            return Ok(Some(row.get("id")));
        }
    }
    Ok(None)
}

fn can_auto_supersede_candidate(
    kind: MemoryKind,
    candidate_scope: &str,
    confidence: Option<f32>,
) -> bool {
    if confidence.unwrap_or(0.0) < AUTO_SUPERSEDE_CONFIDENCE_THRESHOLD {
        return false;
    }
    if candidate_scope == "session" {
        return false;
    }
    matches!(
        kind,
        MemoryKind::UserPreference | MemoryKind::ProjectRule | MemoryKind::ArchitectureDecision
    )
}

fn memory_texts_conflict_for_auto_supersede(existing: &str, candidate: &str) -> bool {
    if let (Some(existing_topic), Some(candidate_topic)) = (
        memory_topic_signature(existing),
        memory_topic_signature(candidate),
    ) {
        if existing_topic == candidate_topic {
            return true;
        }
    }

    let existing_tokens = maintenance_tokens(existing);
    let candidate_tokens = maintenance_tokens(candidate);
    if existing_tokens.len() < 3 || candidate_tokens.len() < 3 {
        return false;
    }
    let overlap = existing_tokens.intersection(&candidate_tokens).count() as f32;
    let union = existing_tokens.union(&candidate_tokens).count() as f32;
    union > 0.0 && overlap / union >= 0.62
}

fn memory_topic_signature(text: &str) -> Option<String> {
    let normalized = text
        .trim()
        .trim_matches(|character: char| {
            character.is_ascii_punctuation()
                || matches!(character, '。' | '，' | '；' | '：' | '！' | '？')
        })
        .to_lowercase();
    let markers = [
        " verification phrase is ",
        " passphrase is ",
        " secret phrase is ",
        " codename is ",
        " goes by ",
        " is called ",
        " name is ",
        " prefers ",
        " should use ",
        " must use ",
        " uses ",
        " is ",
        " are ",
        "验证暗号是",
        "暗号是",
        "口令是",
        "称呼是",
        "叫我",
        "是",
        "：",
        ":",
    ];
    for marker in markers {
        if let Some(index) = normalized.find(marker) {
            let topic = normalized[..index].trim();
            if topic_is_specific_enough(topic, marker) {
                return Some(normalize_duplicate_text(topic));
            }
        }
    }
    None
}

fn topic_is_specific_enough(topic: &str, marker: &str) -> bool {
    if topic.is_empty() {
        return false;
    }
    let topic_words = topic.split_whitespace().count();
    let compact_len = normalize_duplicate_text(topic).chars().count();
    if compact_len >= 12 || topic_words >= 3 {
        return true;
    }
    matches!(
        marker,
        " goes by " | " is called " | " name is " | "称呼是" | "叫我"
    ) && topic.contains("user")
}

pub async fn approve_candidate(
    pool: &SqlitePool,
    candidate_id: &str,
    request: ApproveCandidateRequest,
) -> sqlx::Result<MemoryResponse> {
    let actor = candidate_approval_actor(request.actor.as_deref());
    let row = sqlx::query(
        "select user_id, workspace_id, repo_id, agent_id, session_id, source, source_turn_id, entities_json, episode_json, pinned
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
    let entities_json = row.get::<Option<String>, _>("entities_json");
    let entities = entities_json
        .as_deref()
        .and_then(|value| serde_json::from_str::<Vec<MemoryEntityInput>>(value).ok())
        .unwrap_or_default();
    let episode = row
        .get::<Option<String>, _>("episode_json")
        .as_deref()
        .and_then(|value| serde_json::from_str::<TaskEpisodeData>(value).ok());
    let item = create_manual_memory(
        pool,
        CreateMemoryRequest {
            kind: request.kind,
            scope: request.scope,
            text: request.text,
            source: Some(row.get("source")),
            source_session_id: row.get("session_id"),
            source_turn_id: row.get("source_turn_id"),
            scope_data,
            entities,
            episode,
            observed_at: None,
            valid_from: None,
            valid_until: None,
            supersedes_memory_id: None,
            pinned: row.get::<i64, _>("pinned") != 0,
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
        &actor,
        "candidate.approve",
        Some(&item.id),
        Some(candidate_id),
        None,
        serde_json::json!({}),
    )
    .await?;
    Ok(item)
}

fn candidate_approval_actor(raw: Option<&str>) -> String {
    match raw
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_ascii_lowercase)
        .as_deref()
    {
        Some("extractor" | "mcp" | "maintenance" | "system" | "user") => {
            raw.map(str::trim).unwrap_or("user").to_ascii_lowercase()
        }
        _ => "user".to_string(),
    }
}

fn normalize_memory_source(source: Option<&str>) -> String {
    match source
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_ascii_lowercase)
        .as_deref()
    {
        Some("manual" | "extractor" | "mcp" | "maintenance" | "system" | "user") => source
            .map(str::trim)
            .unwrap_or("manual")
            .to_ascii_lowercase(),
        _ => "manual".to_string(),
    }
}

fn normalize_candidate_source(source: Option<&str>) -> String {
    match source
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_ascii_lowercase)
        .as_deref()
    {
        Some("extractor" | "mcp" | "maintenance" | "system" | "user") => source
            .map(str::trim)
            .unwrap_or("extractor")
            .to_ascii_lowercase(),
        _ => "extractor".to_string(),
    }
}

pub async fn reject_candidate(pool: &SqlitePool, candidate_id: &str) -> sqlx::Result<()> {
    let result = sqlx::query("update memory_candidates set status = 'rejected', reviewed_at = ? where id = ? and status = 'pending'")
        .bind(Utc::now().timestamp_millis())
        .bind(candidate_id)
        .execute(pool)
        .await?;
    if result.rows_affected() == 0 {
        return Err(sqlx::Error::RowNotFound);
    }
    write_audit(
        pool,
        "user",
        "candidate.reject",
        None,
        Some(candidate_id),
        None,
        serde_json::json!({}),
    )
    .await?;
    Ok(())
}

pub async fn create_change_request(
    pool: &SqlitePool,
    request: CreateChangeRequestRequest,
) -> sqlx::Result<MemoryChangeRequestResponse> {
    let now = Utc::now().timestamp_millis();
    let action = request.action.trim().to_ascii_lowercase();
    let source = normalize_change_request_source(request.source.as_deref());
    let target_memory_ids =
        normalized_change_request_target_ids(&action, &request.target_memory_ids);
    let proposed_kind = request.proposed_kind.map(kind_to_wire);
    let proposed_scope = request
        .proposed_scope
        .as_deref()
        .map(str::trim)
        .filter(|scope| !scope.is_empty())
        .map(str::to_string);
    let proposed_text = normalize_change_request_text(request.proposed_text.as_deref());
    if let Some(existing) = find_duplicate_pending_change_request(
        pool,
        &request.scope,
        &action,
        &target_memory_ids,
        proposed_kind,
        proposed_scope.as_deref(),
        proposed_text.as_deref(),
    )
    .await?
    {
        let existing_id = existing.id.clone();
        write_audit(
            pool,
            "system",
            "change_request.skip_duplicate",
            None,
            None,
            Some(&existing_id),
            serde_json::json!({
                "action": action,
                "source": source,
                "targetMemoryIds": target_memory_ids,
                "existingChangeRequestId": existing_id
            }),
        )
        .await?;
        return Ok(existing);
    }

    let id = format!("cr_{}", Uuid::new_v4());
    let target_memory_id = target_memory_ids.first().cloned();
    let target_memory_ids_json = serde_json::to_string(&target_memory_ids)
        .map_err(|error| sqlx::Error::Decode(Box::new(error)))?;
    sqlx::query(
        "insert into memory_change_requests
        (id, user_id, workspace_id, repo_id, agent_id, session_id, action, source, target_memory_id,
         target_memory_ids_json, proposed_kind, proposed_scope, proposed_text, reason, confidence, status, created_at)
         values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?)",
    )
    .bind(&id)
    .bind(&request.scope.user_id)
    .bind(&request.scope.workspace_id)
    .bind(&request.scope.repo_id)
    .bind(&request.scope.agent_id)
    .bind(&request.scope.session_id)
    .bind(&action)
    .bind(&source)
    .bind(&target_memory_id)
    .bind(&target_memory_ids_json)
    .bind(proposed_kind)
    .bind(&proposed_scope)
    .bind(&proposed_text)
    .bind(&request.reason)
    .bind(request.confidence)
    .bind(now)
    .execute(pool)
    .await?;
    write_audit(
        pool,
        "system",
        "change_request.create",
        None,
        None,
        Some(&id),
        serde_json::json!({
            "action": action,
            "source": source,
            "targetMemoryIds": target_memory_ids,
            "confidence": request.confidence
        }),
    )
    .await?;
    get_change_request(pool, &id).await
}

fn normalized_change_request_target_ids(action: &str, target_memory_ids: &[String]) -> Vec<String> {
    let mut ids = target_memory_ids
        .iter()
        .map(|id| id.trim().to_string())
        .filter(|id| !id.is_empty())
        .collect::<Vec<_>>();
    if action != "supersede" {
        ids.sort();
    }
    ids.dedup();
    ids
}

fn normalize_change_request_text(text: Option<&str>) -> Option<String> {
    text.map(str::trim)
        .filter(|text| !text.is_empty())
        .map(redactor::redact)
}

async fn find_duplicate_pending_change_request(
    pool: &SqlitePool,
    scope: &MemoryScope,
    action: &str,
    target_memory_ids: &[String],
    proposed_kind: Option<&str>,
    proposed_scope: Option<&str>,
    proposed_text: Option<&str>,
) -> sqlx::Result<Option<MemoryChangeRequestResponse>> {
    let target_memory_ids_json = serde_json::to_string(target_memory_ids)
        .map_err(|error| sqlx::Error::Decode(Box::new(error)))?;
    let row = sqlx::query(
        "select id
         from memory_change_requests
         where status = 'pending'
           and user_id = ?
           and (? is null or workspace_id is null or workspace_id = ?)
           and (? is null or repo_id is null or repo_id = ?)
           and (? is null or agent_id is null or agent_id = ?)
           and (? is null or session_id is null or session_id = ?)
           and action = ?
           and target_memory_ids_json = ?
           and proposed_kind is ?
           and proposed_scope is ?
           and proposed_text is ?
         order by created_at asc
         limit 1",
    )
    .bind(&scope.user_id)
    .bind(&scope.workspace_id)
    .bind(&scope.workspace_id)
    .bind(&scope.repo_id)
    .bind(&scope.repo_id)
    .bind(&scope.agent_id)
    .bind(&scope.agent_id)
    .bind(&scope.session_id)
    .bind(&scope.session_id)
    .bind(action)
    .bind(&target_memory_ids_json)
    .bind(proposed_kind)
    .bind(proposed_scope)
    .bind(proposed_text)
    .fetch_optional(pool)
    .await?;

    if let Some(row) = row {
        let id: String = row.get("id");
        return get_change_request(pool, &id).await.map(Some);
    }
    Ok(None)
}

fn normalize_change_request_source(source: Option<&str>) -> String {
    match source
        .map(str::trim)
        .map(str::to_ascii_lowercase)
        .as_deref()
    {
        Some("extractor" | "mcp" | "maintenance" | "system" | "user") => {
            source.unwrap().trim().to_ascii_lowercase()
        }
        _ => "user".to_string(),
    }
}

pub async fn list_change_requests(
    pool: &SqlitePool,
    user_id: Option<&str>,
    workspace_id: Option<&str>,
    repo_id: Option<&str>,
    agent_id: Option<&str>,
    session_id: Option<&str>,
    status: Option<&str>,
) -> sqlx::Result<ListChangeRequestsResponse> {
    let rows = sqlx::query(
        "select cr.id, cr.action, cr.source, cr.target_memory_id, cr.target_memory_ids_json,
                cr.proposed_kind, cr.proposed_scope, cr.proposed_text, cr.reason,
                cr.confidence, cr.status, cr.created_at, cr.reviewed_at,
                m.text as target_memory_text
         from memory_change_requests cr
         left join memory_items m on m.id = cr.target_memory_id
         where (? is null or cr.user_id = ?)
           and (? is null or cr.workspace_id is null or cr.workspace_id = ?)
           and (? is null or cr.repo_id is null or cr.repo_id = ?)
           and (? is null or cr.agent_id is null or cr.agent_id = ?)
           and (? is null or cr.session_id is null or cr.session_id = ?)
           and (? is null or cr.status = ?)
         order by cr.created_at desc",
    )
    .bind(user_id)
    .bind(user_id)
    .bind(workspace_id)
    .bind(workspace_id)
    .bind(repo_id)
    .bind(repo_id)
    .bind(agent_id)
    .bind(agent_id)
    .bind(session_id)
    .bind(session_id)
    .bind(status)
    .bind(status)
    .fetch_all(pool)
    .await?;
    Ok(ListChangeRequestsResponse {
        items: rows
            .into_iter()
            .map(row_to_change_request)
            .collect::<sqlx::Result<Vec<_>>>()?,
    })
}

pub async fn patch_change_request(
    pool: &SqlitePool,
    id: &str,
    request: PatchChangeRequestRequest,
) -> sqlx::Result<MemoryChangeRequestResponse> {
    let current = get_pending_change_request(pool, id).await?;
    let current_kind = current.proposed_kind.map(kind_to_wire).map(str::to_string);
    let next_kind = request
        .proposed_kind
        .map(kind_to_wire)
        .map(str::to_string)
        .or_else(|| current_kind.clone());
    let next_scope = request
        .proposed_scope
        .as_deref()
        .map(str::trim)
        .filter(|scope| !scope.is_empty())
        .map(str::to_string)
        .or_else(|| current.proposed_scope.clone());
    let next_text = normalize_change_request_text(request.proposed_text.as_deref())
        .or_else(|| current.proposed_text.clone());
    let next_reason = request
        .reason
        .as_deref()
        .map(str::trim)
        .filter(|reason| !reason.is_empty())
        .map(str::to_string)
        .or_else(|| current.reason.clone());

    sqlx::query(
        "update memory_change_requests
         set proposed_kind = ?, proposed_scope = ?, proposed_text = ?, reason = ?
         where id = ? and status = 'pending'",
    )
    .bind(&next_kind)
    .bind(&next_scope)
    .bind(&next_text)
    .bind(&next_reason)
    .bind(id)
    .execute(pool)
    .await?;

    let changed = serde_json::json!({
        "proposedKind": {"from": current_kind, "to": next_kind},
        "proposedScope": {"from": current.proposed_scope, "to": next_scope},
        "proposedText": {"from": current.proposed_text, "to": next_text},
        "reason": {"from": current.reason, "to": next_reason}
    });
    write_audit(
        pool,
        "user",
        "change_request.update",
        None,
        None,
        Some(id),
        changed,
    )
    .await?;
    get_change_request(pool, id).await
}

pub async fn approve_change_request(
    pool: &SqlitePool,
    id: &str,
    request: ApproveChangeRequestRequest,
) -> sqlx::Result<MemoryChangeRequestResponse> {
    let actor = change_request_approval_actor(request.actor.as_deref());
    approve_change_request_as(pool, id, request, &actor).await
}

fn change_request_approval_actor(raw: Option<&str>) -> String {
    match raw.map(str::trim).filter(|value| !value.is_empty()) {
        Some("extractor" | "mcp" | "maintenance" | "system" | "user") => {
            raw.unwrap().trim().to_string()
        }
        _ => "user".to_string(),
    }
}

async fn approve_change_request_as(
    pool: &SqlitePool,
    id: &str,
    request: ApproveChangeRequestRequest,
    actor: &str,
) -> sqlx::Result<MemoryChangeRequestResponse> {
    let current = get_pending_change_request(pool, id).await?;
    let target_memory_ids = current.target_memory_ids.clone();
    match current.action.as_str() {
        "update" | "summarize" => {
            let target_id = target_memory_ids
                .first()
                .ok_or(sqlx::Error::RowNotFound)?
                .to_owned();
            let existing = get_memory(pool, &target_id).await?;
            let kind = request
                .proposed_kind
                .or(current.proposed_kind)
                .unwrap_or(existing.kind);
            let scope = request
                .proposed_scope
                .or(current.proposed_scope.clone())
                .unwrap_or(existing.scope);
            let text = request
                .proposed_text
                .or(current.proposed_text.clone())
                .unwrap_or(existing.text);
            let action = if current.action == "summarize" {
                "memory.summarize"
            } else {
                "memory.update"
            };
            update_memory_from_change_request(
                pool,
                &target_id,
                kind,
                scope,
                text,
                "active",
                action,
                id,
                actor,
                &current.source,
            )
            .await?;
        }
        "disable" | "expire" => {
            for target_id in &target_memory_ids {
                let action = if current.action == "expire" {
                    "memory.expire"
                } else {
                    "memory.disable"
                };
                set_memory_status_from_change_request(
                    pool, target_id, "disabled", action, id, actor,
                )
                .await?;
            }
        }
        "delete" => {
            for target_id in &target_memory_ids {
                soft_delete_memory_from_change_request(pool, target_id, id, actor).await?;
            }
        }
        "merge" => {
            merge_memory_from_change_request(pool, &current, request, actor).await?;
        }
        "supersede" => {
            supersede_memory_from_change_request(pool, &current, request, actor).await?;
        }
        _ => return Err(sqlx::Error::RowNotFound),
    }
    let reviewed_at = Utc::now().timestamp_millis();
    sqlx::query(
        "update memory_change_requests set status = 'approved', reviewed_at = ? where id = ? and status = 'pending'",
    )
    .bind(reviewed_at)
    .bind(id)
    .execute(pool)
    .await?;
    write_audit(
        pool,
        actor,
        "change_request.approve",
        None,
        None,
        Some(id),
        serde_json::json!({"action": current.action, "targetMemoryIds": target_memory_ids}),
    )
    .await?;
    get_change_request(pool, id).await
}

pub async fn reject_change_request(
    pool: &SqlitePool,
    id: &str,
) -> sqlx::Result<MemoryChangeRequestResponse> {
    let result = sqlx::query(
        "update memory_change_requests set status = 'rejected', reviewed_at = ? where id = ? and status = 'pending'",
    )
    .bind(Utc::now().timestamp_millis())
    .bind(id)
    .execute(pool)
    .await?;
    if result.rows_affected() == 0 {
        return Err(sqlx::Error::RowNotFound);
    }
    write_audit(
        pool,
        "user",
        "change_request.reject",
        None,
        None,
        Some(id),
        serde_json::json!({}),
    )
    .await?;
    get_change_request(pool, id).await
}

pub async fn run_maintenance(
    pool: &SqlitePool,
    request: MaintenanceRunRequest,
    llm_config: Option<&MaintenanceLlmConfig>,
) -> sqlx::Result<MaintenanceRunResponse> {
    let mode = maintenance_mode_from_wire(request.mode.as_deref());
    let cost_mode = normalize_mode(request.cost_mode.as_deref().unwrap_or("low_cost"));
    if request.enabled == Some(false) || matches!(mode.as_str(), "disabled" | "off") {
        write_audit(
            pool,
            "maintenance",
            "maintenance.run",
            None,
            None,
            None,
            serde_json::json!({
                "enabled": false,
                "mode": mode,
                "costMode": cost_mode,
                "autoApplied": 0,
                "needsReview": 0,
                "skipped": 0,
                "candidateCount": 0
            }),
        )
        .await?;
        return Ok(MaintenanceRunResponse {
            auto_applied: 0,
            needs_review: 0,
            skipped: 0,
            existing_auto_approved_change_requests: 0,
            auto_rejected_candidates: 0,
            auto_rejected_change_requests: 0,
            change_requests: Vec::new(),
        });
    }

    let high_threshold = request.high_confidence_threshold.unwrap_or(0.90);
    let review_threshold = request.review_threshold.unwrap_or(0.75);
    let max_items = request.max_items_per_batch.unwrap_or(12).clamp(2, 50);
    let manual_only_actions = request
        .manual_only_actions
        .unwrap_or_else(|| vec!["delete".to_string()])
        .into_iter()
        .map(|action| normalize_mode(&action))
        .filter(|action| !action.is_empty())
        .collect::<HashSet<_>>();
    let high_confidence_auto = mode == "high_confidence_auto";
    let now = Utc::now().timestamp_millis();
    let memories = list_maintenance_memory(pool, &request.scope, max_items)
        .await?
        .into_iter()
        .filter(|memory| memory.kind != MemoryKind::TaskEpisode)
        .collect::<Vec<_>>();
    let expired_memories =
        list_expired_maintenance_memory(pool, &request.scope, max_items, now).await?;
    let entities_by_memory = load_entities_by_memory(pool).await?;
    let mut auto_applied = 0;
    let mut needs_review = 0;
    let mut skipped = 0;
    let mut seen = HashSet::new();
    let mut change_requests = Vec::new();

    let auto_rejected_obsolete_change_requests =
        auto_reject_obsolete_change_requests(pool, &request.scope, now).await?;
    let auto_rejected_covered_change_requests =
        auto_reject_change_requests_covered_by_active_memory(pool, &request.scope, now).await?;
    let auto_rejected_change_requests =
        auto_rejected_obsolete_change_requests + auto_rejected_covered_change_requests;
    let existing_approved = auto_approve_existing_change_requests(
        pool,
        &request.scope,
        high_confidence_auto,
        high_threshold,
        &manual_only_actions,
    )
    .await?;
    let existing_auto_approved_change_requests = existing_approved.len() as i64;
    auto_applied += existing_auto_approved_change_requests;
    for request in &existing_approved {
        for target_id in &request.target_memory_ids {
            seen.insert(target_id.clone());
        }
    }
    change_requests.extend(existing_approved);

    for memory in &expired_memories {
        let proposal = expired_memory_proposal(memory);
        let change_request = create_change_request(
            pool,
            CreateChangeRequestRequest {
                scope: request.scope.clone(),
                action: proposal.action.clone(),
                source: Some("maintenance".to_string()),
                target_memory_ids: proposal.target_memory_ids.clone(),
                proposed_kind: Some(proposal.proposed_kind),
                proposed_scope: Some(proposal.proposed_scope.clone()),
                proposed_text: proposal.proposed_text.clone(),
                reason: proposal.reason.clone(),
                confidence: Some(proposal.confidence),
            },
        )
        .await?;
        let action_requires_review =
            manual_only_actions.contains(&normalize_mode(&proposal.action));
        if high_confidence_auto && proposal.confidence >= high_threshold && !action_requires_review
        {
            let approved = approve_change_request_as(
                pool,
                &change_request.id,
                ApproveChangeRequestRequest {
                    proposed_kind: None,
                    proposed_scope: None,
                    proposed_text: None,
                    actor: None,
                },
                "maintenance",
            )
            .await?;
            write_audit(
                pool,
                "maintenance",
                "maintenance.auto_approve",
                None,
                None,
                Some(&approved.id),
                serde_json::json!({"action": approved.action, "confidence": proposal.confidence}),
            )
            .await?;
            change_requests.push(approved);
            auto_applied += 1;
        } else {
            change_requests.push(change_request);
            needs_review += 1;
        }
        seen.insert(memory.id.clone());
    }

    for left_index in 0..memories.len() {
        if seen.contains(&memories[left_index].id) {
            continue;
        }
        for right in memories.iter().skip(left_index + 1) {
            if seen.contains(&right.id) {
                continue;
            }
            let confidence =
                maintenance_similarity(&memories[left_index], right, &entities_by_memory);
            if confidence < review_threshold {
                skipped += 1;
                continue;
            }
            let mut proposal =
                maintenance_supersede_proposal(&memories[left_index], right, confidence)
                    .unwrap_or_else(|| {
                        fallback_merge_proposal(&memories[left_index], right, confidence)
                    });
            if let Some(config) = llm_config.filter(|_| {
                should_call_maintenance_llm(
                    &cost_mode,
                    &proposal,
                    high_threshold,
                    &manual_only_actions,
                )
            }) {
                match maintenance_llm_proposal(
                    config,
                    &request.scope,
                    &memories[left_index],
                    right,
                    &proposal,
                )
                .await
                {
                    Ok(Some(extracted)) => proposal = extracted,
                    Ok(None) => {}
                    Err(error) => {
                        tracing::warn!(%error, "maintenance llm extractor failed");
                    }
                }
            }
            if proposal.confidence < review_threshold {
                skipped += 1;
                write_audit(
                    pool,
                    "maintenance",
                    "maintenance.diagnostic",
                    None,
                    None,
                    None,
                    serde_json::json!({
                        "reason": "llm_confidence_below_review_threshold",
                        "confidence": proposal.confidence,
                        "targetMemoryIds": proposal.target_memory_ids
                    }),
                )
                .await?;
                continue;
            }
            let change_request = create_change_request(
                pool,
                CreateChangeRequestRequest {
                    scope: request.scope.clone(),
                    action: proposal.action.clone(),
                    source: Some("maintenance".to_string()),
                    target_memory_ids: proposal.target_memory_ids.clone(),
                    proposed_kind: Some(proposal.proposed_kind),
                    proposed_scope: Some(proposal.proposed_scope.clone()),
                    proposed_text: proposal.proposed_text.clone(),
                    reason: proposal.reason.clone(),
                    confidence: Some(proposal.confidence),
                },
            )
            .await?;
            let action_requires_review = proposal.action == "delete"
                || manual_only_actions.contains(&normalize_mode(&proposal.action));
            if high_confidence_auto
                && proposal.confidence >= high_threshold
                && !action_requires_review
            {
                let approved = approve_change_request_as(
                    pool,
                    &change_request.id,
                    ApproveChangeRequestRequest {
                        proposed_kind: None,
                        proposed_scope: None,
                        proposed_text: None,
                        actor: None,
                    },
                    "maintenance",
                )
                .await?;
                write_audit(
                    pool,
                    "maintenance",
                    "maintenance.auto_approve",
                    None,
                    None,
                    Some(&approved.id),
                    serde_json::json!({"action": approved.action, "confidence": proposal.confidence}),
                )
                .await?;
                change_requests.push(approved);
                auto_applied += 1;
            } else {
                change_requests.push(change_request);
                needs_review += 1;
            }
            for target_id in &proposal.target_memory_ids {
                seen.insert(target_id.clone());
            }
            break;
        }
    }

    let auto_rejected_candidates =
        reject_pending_candidates_covered_by_active_memory(pool, &request.scope, now).await?;

    write_audit(
        pool,
        "maintenance",
        "maintenance.run",
        None,
        None,
        None,
        serde_json::json!({
            "enabled": true,
            "mode": mode,
            "costMode": cost_mode,
            "manualOnlyActions": manual_only_actions.iter().cloned().collect::<Vec<_>>(),
            "autoApplied": auto_applied,
            "existingAutoApprovedChangeRequests": existing_auto_approved_change_requests,
            "autoRejectedChangeRequests": auto_rejected_change_requests,
            "autoRejectedObsoleteChangeRequests": auto_rejected_obsolete_change_requests,
            "autoRejectedCoveredChangeRequests": auto_rejected_covered_change_requests,
            "needsReview": needs_review,
            "skipped": skipped,
            "autoRejectedCandidates": auto_rejected_candidates,
            "candidateCount": memories.len()
        }),
    )
    .await?;
    Ok(MaintenanceRunResponse {
        auto_applied,
        needs_review,
        skipped,
        existing_auto_approved_change_requests,
        auto_rejected_candidates,
        auto_rejected_change_requests,
        change_requests,
    })
}

fn maintenance_mode_from_wire(value: Option<&str>) -> String {
    let mode = value
        .map(normalize_mode)
        .unwrap_or_else(|| "high_confidence_auto".to_string());
    match mode.as_str() {
        "disabled" | "off" | "manual_review" | "high_confidence_auto" => mode,
        _ => "high_confidence_auto".to_string(),
    }
}

fn should_call_maintenance_llm(
    cost_mode: &str,
    proposal: &MaintenanceProposal,
    high_threshold: f32,
    _manual_only_actions: &HashSet<String>,
) -> bool {
    if cost_mode != "low_cost" {
        return true;
    }
    if proposal.confidence >= high_threshold {
        return false;
    }
    true
}

async fn auto_approve_existing_change_requests(
    pool: &SqlitePool,
    scope: &MemoryScope,
    high_confidence_auto: bool,
    high_threshold: f32,
    manual_only_actions: &HashSet<String>,
) -> sqlx::Result<Vec<MemoryChangeRequestResponse>> {
    if !high_confidence_auto {
        return Ok(Vec::new());
    }
    let pending = list_change_requests(
        pool,
        Some(&scope.user_id),
        scope.workspace_id.as_deref(),
        scope.repo_id.as_deref(),
        scope.agent_id.as_deref(),
        scope.session_id.as_deref(),
        Some("pending"),
    )
    .await?;
    let mut approved = Vec::new();
    for request in pending.items {
        let normalized_action = normalize_mode(&request.action);
        if request.confidence.unwrap_or(0.0) < high_threshold
            || normalized_action == "delete"
            || manual_only_actions.contains(&normalized_action)
        {
            continue;
        }
        let reviewed = approve_change_request_as(
            pool,
            &request.id,
            ApproveChangeRequestRequest {
                proposed_kind: None,
                proposed_scope: None,
                proposed_text: None,
                actor: None,
            },
            "maintenance",
        )
        .await?;
        write_audit(
            pool,
            "maintenance",
            "maintenance.auto_approve",
            None,
            None,
            Some(&reviewed.id),
            serde_json::json!({
                "action": reviewed.action,
                "confidence": request.confidence,
                "source": "existing_change_request"
            }),
        )
        .await?;
        approved.push(reviewed);
    }
    Ok(approved)
}

async fn auto_reject_obsolete_change_requests(
    pool: &SqlitePool,
    scope: &MemoryScope,
    now: i64,
) -> sqlx::Result<i64> {
    let pending = list_change_requests(
        pool,
        Some(&scope.user_id),
        scope.workspace_id.as_deref(),
        scope.repo_id.as_deref(),
        scope.agent_id.as_deref(),
        scope.session_id.as_deref(),
        Some("pending"),
    )
    .await?;
    let mut rejected = 0_i64;
    for request in pending.items {
        let obsolete_target_ids =
            obsolete_change_request_target_ids(pool, &request.target_memory_ids).await?;
        if obsolete_target_ids.is_empty() {
            continue;
        }
        let result = sqlx::query(
            "update memory_change_requests
             set status = 'rejected', reviewed_at = ?
             where id = ? and status = 'pending'",
        )
        .bind(now)
        .bind(&request.id)
        .execute(pool)
        .await?;
        if result.rows_affected() == 0 {
            continue;
        }
        rejected += result.rows_affected() as i64;
        write_audit(
            pool,
            "maintenance",
            "change_request.auto_reject_obsolete",
            None,
            None,
            Some(&request.id),
            serde_json::json!({
                "action": request.action,
                "targetMemoryIds": request.target_memory_ids,
                "obsoleteTargetMemoryIds": obsolete_target_ids,
                "reason": "target_memory_deleted_or_missing"
            }),
        )
        .await?;
    }
    Ok(rejected)
}

async fn auto_reject_change_requests_covered_by_active_memory(
    pool: &SqlitePool,
    scope: &MemoryScope,
    now: i64,
) -> sqlx::Result<i64> {
    let pending = list_change_requests(
        pool,
        Some(&scope.user_id),
        scope.workspace_id.as_deref(),
        scope.repo_id.as_deref(),
        scope.agent_id.as_deref(),
        scope.session_id.as_deref(),
        Some("pending"),
    )
    .await?;
    let mut rejected = 0_i64;
    for request in pending.items {
        let normalized_action = normalize_mode(&request.action);
        if normalized_action == "merge" && request.target_memory_ids.len() > 1 {
            continue;
        }
        if !can_auto_reject_change_request_as_covered(&request.action) {
            continue;
        }
        let Some(kind) = request.proposed_kind else {
            continue;
        };
        let Some(proposed_scope) = request.proposed_scope.as_deref() else {
            continue;
        };
        let Some(proposed_text) = request.proposed_text.as_deref() else {
            continue;
        };
        let kind_wire = kind_to_wire(kind);
        let Some(memory_id) =
            find_active_duplicate_memory_id(pool, scope, kind_wire, proposed_scope, proposed_text)
                .await?
        else {
            continue;
        };
        let result = sqlx::query(
            "update memory_change_requests
             set status = 'rejected', reviewed_at = ?
             where id = ? and status = 'pending'",
        )
        .bind(now)
        .bind(&request.id)
        .execute(pool)
        .await?;
        if result.rows_affected() == 0 {
            continue;
        }
        rejected += result.rows_affected() as i64;
        write_audit(
            pool,
            "maintenance",
            "change_request.auto_reject_duplicate",
            Some(&memory_id),
            None,
            Some(&request.id),
            serde_json::json!({
                "action": request.action,
                "targetMemoryIds": request.target_memory_ids,
                "proposedKind": kind_wire,
                "proposedScope": proposed_scope,
                "textHash": stable_text_hash(proposed_text),
                "reason": "covered_by_active_memory"
            }),
        )
        .await?;
    }
    Ok(rejected)
}

fn can_auto_reject_change_request_as_covered(action: &str) -> bool {
    matches!(
        normalize_mode(action).as_str(),
        "update" | "summarize" | "merge"
    )
}

async fn obsolete_change_request_target_ids(
    pool: &SqlitePool,
    target_memory_ids: &[String],
) -> sqlx::Result<Vec<String>> {
    if target_memory_ids.is_empty() {
        return Ok(vec!["<missing-target>".to_string()]);
    }
    let mut obsolete = Vec::new();
    for target_id in target_memory_ids {
        let status =
            sqlx::query_scalar::<_, String>("select status from memory_items where id = ?")
                .bind(target_id)
                .fetch_optional(pool)
                .await?;
        if matches!(status.as_deref(), None | Some("deleted")) {
            obsolete.push(target_id.clone());
        }
    }
    Ok(obsolete)
}

fn normalize_mode(value: &str) -> String {
    value
        .trim()
        .to_ascii_lowercase()
        .chars()
        .map(|character| match character {
            '-' => '_',
            character if character.is_ascii_whitespace() => '_',
            character => character,
        })
        .collect()
}

pub async fn list_audit(
    pool: &SqlitePool,
    user_id: Option<&str>,
    workspace_id: Option<&str>,
    repo_id: Option<&str>,
    agent_id: Option<&str>,
    session_id: Option<&str>,
) -> sqlx::Result<ListAuditResponse> {
    let rows = sqlx::query(
        "select a.id, a.actor, a.action, a.memory_id, a.candidate_id, a.change_request_id,
                a.payload_json, a.created_at, m.text as memory_text, c.text as candidate_text,
                cr.proposed_text as change_request_text,
                m.scope as memory_scope, m.workspace_id as memory_workspace_id,
                m.repo_id as memory_repo_id, m.agent_id as memory_agent_id,
                m.session_id as memory_session_id,
                c.scope as candidate_scope, c.workspace_id as candidate_workspace_id,
                c.repo_id as candidate_repo_id, c.agent_id as candidate_agent_id,
                c.session_id as candidate_session_id,
                cr.proposed_scope as change_request_scope,
                cr.workspace_id as change_request_workspace_id,
                cr.repo_id as change_request_repo_id,
                cr.agent_id as change_request_agent_id,
                cr.session_id as change_request_session_id
         from memory_audit_log a
         left join memory_items m on m.id = a.memory_id
         left join memory_candidates c on c.id = a.candidate_id
         left join memory_change_requests cr on cr.id = a.change_request_id
         where (
             ? is null
             or coalesce(m.user_id, c.user_id, cr.user_id, '') = ?
             or (a.memory_id is null and a.candidate_id is null and a.change_request_id is null)
           )
         order by a.created_at desc
         limit 1000",
    )
    .bind(user_id)
    .bind(user_id)
    .fetch_all(pool)
    .await?;
    Ok(ListAuditResponse {
        items: rows
            .into_iter()
            .filter(|row| audit_row_matches_scope(row, workspace_id, repo_id, agent_id, session_id))
            .take(200)
            .map(row_to_audit_event)
            .collect::<sqlx::Result<Vec<_>>>()?,
    })
}

fn audit_row_matches_scope(
    row: &sqlx::sqlite::SqliteRow,
    workspace_id: Option<&str>,
    repo_id: Option<&str>,
    agent_id: Option<&str>,
    session_id: Option<&str>,
) -> bool {
    if workspace_id.is_none() && repo_id.is_none() && agent_id.is_none() && session_id.is_none() {
        return true;
    }

    if let Some(scope) = row.get::<Option<String>, _>("memory_scope") {
        return semantic_scope_matches(
            &scope,
            row.get::<Option<String>, _>("memory_workspace_id")
                .as_deref(),
            row.get::<Option<String>, _>("memory_repo_id").as_deref(),
            row.get::<Option<String>, _>("memory_agent_id").as_deref(),
            row.get::<Option<String>, _>("memory_session_id").as_deref(),
            workspace_id,
            repo_id,
            agent_id,
            session_id,
        );
    }

    if let Some(scope) = row.get::<Option<String>, _>("candidate_scope") {
        return semantic_scope_matches(
            &scope,
            row.get::<Option<String>, _>("candidate_workspace_id")
                .as_deref(),
            row.get::<Option<String>, _>("candidate_repo_id").as_deref(),
            row.get::<Option<String>, _>("candidate_agent_id")
                .as_deref(),
            row.get::<Option<String>, _>("candidate_session_id")
                .as_deref(),
            workspace_id,
            repo_id,
            agent_id,
            session_id,
        );
    }

    if row.get::<Option<String>, _>("change_request_id").is_some() {
        if let Some(scope) = row.get::<Option<String>, _>("change_request_scope") {
            return semantic_scope_matches(
                &scope,
                row.get::<Option<String>, _>("change_request_workspace_id")
                    .as_deref(),
                row.get::<Option<String>, _>("change_request_repo_id")
                    .as_deref(),
                row.get::<Option<String>, _>("change_request_agent_id")
                    .as_deref(),
                row.get::<Option<String>, _>("change_request_session_id")
                    .as_deref(),
                workspace_id,
                repo_id,
                agent_id,
                session_id,
            );
        }
        return scoped_context_matches(
            row.get::<Option<String>, _>("change_request_workspace_id")
                .as_deref(),
            row.get::<Option<String>, _>("change_request_repo_id")
                .as_deref(),
            row.get::<Option<String>, _>("change_request_agent_id")
                .as_deref(),
            row.get::<Option<String>, _>("change_request_session_id")
                .as_deref(),
            workspace_id,
            repo_id,
            agent_id,
            session_id,
        );
    }

    true
}

#[allow(clippy::too_many_arguments)]
fn semantic_scope_matches(
    scope: &str,
    item_workspace_id: Option<&str>,
    item_repo_id: Option<&str>,
    item_agent_id: Option<&str>,
    item_session_id: Option<&str>,
    query_workspace_id: Option<&str>,
    query_repo_id: Option<&str>,
    query_agent_id: Option<&str>,
    query_session_id: Option<&str>,
) -> bool {
    match scope {
        "global" => true,
        "workspace" => field_matches(query_workspace_id, item_workspace_id),
        "repo" => {
            field_matches(query_workspace_id, item_workspace_id)
                && field_matches(query_repo_id, item_repo_id)
        }
        "session" => {
            field_matches(query_workspace_id, item_workspace_id)
                && field_matches(query_repo_id, item_repo_id)
                && field_matches(query_agent_id, item_agent_id)
                && field_matches(query_session_id, item_session_id)
        }
        _ => scoped_context_matches(
            item_workspace_id,
            item_repo_id,
            item_agent_id,
            item_session_id,
            query_workspace_id,
            query_repo_id,
            query_agent_id,
            query_session_id,
        ),
    }
}

#[allow(clippy::too_many_arguments)]
fn scoped_context_matches(
    item_workspace_id: Option<&str>,
    item_repo_id: Option<&str>,
    item_agent_id: Option<&str>,
    item_session_id: Option<&str>,
    query_workspace_id: Option<&str>,
    query_repo_id: Option<&str>,
    query_agent_id: Option<&str>,
    query_session_id: Option<&str>,
) -> bool {
    field_matches(query_workspace_id, item_workspace_id)
        && field_matches(query_repo_id, item_repo_id)
        && field_matches(query_agent_id, item_agent_id)
        && field_matches(query_session_id, item_session_id)
}

fn field_matches(query_value: Option<&str>, item_value: Option<&str>) -> bool {
    match (query_value, item_value) {
        (Some(query), Some(item)) => query == item,
        _ => true,
    }
}

pub async fn search_memory(
    pool: &SqlitePool,
    request: SearchRequest,
    embedder: &dyn Embedder,
    embedding_dimension: usize,
) -> sqlx::Result<SearchResponse> {
    let limit = request.limit.unwrap_or(12).clamp(1, 50);
    let pinned_profile_limit = request.pinned_profile_limit.unwrap_or(4).clamp(0, 50) as usize;
    let tokens = query_tokens(&request.query);
    let vector_scores = vector_scores_for_query(pool, embedder, embedding_dimension, &request)
        .await
        .unwrap_or_default();
    let feedback_stats = load_feedback_stats(pool).await?;
    let access_stats = load_access_stats(pool).await?;
    let entities_by_memory = load_entities_by_memory(pool).await?;
    let episodes_by_memory = load_task_episodes_by_memory(pool).await?;
    let query_entity_terms = query_entity_terms(&request.query, &tokens);
    let decay_reference_time = request
        .reference_time
        .unwrap_or_else(|| Utc::now().timestamp_millis());
    let rows = sqlx::query(
        "select id, kind, scope, text, source_session_id, source_turn_id, repo_id, workspace_id, agent_id, session_id, observed_at, valid_from, valid_until, supersedes_memory_id, pinned, updated_at
         from memory_items
         where status = 'active'
           and user_id = ?
           and (
             scope = 'global'
             or (
               scope = 'workspace'
               and (? is null or workspace_id is null or workspace_id = ?)
             )
             or (
               scope = 'repo'
               and (? is null or workspace_id is null or workspace_id = ?)
               and (? is null or repo_id is null or repo_id = ?)
             )
             or (
               scope = 'session'
               and (? is null or workspace_id is null or workspace_id = ?)
               and (? is null or repo_id is null or repo_id = ?)
               and (? is null or agent_id is null or agent_id = ?)
               and (? is null or session_id is null or session_id = ?)
             )
             or (
               scope not in ('global', 'workspace', 'repo', 'session')
               and (? is null or workspace_id is null or workspace_id = ?)
               and (? is null or repo_id is null or repo_id = ?)
               and (? is null or agent_id is null or agent_id = ?)
               and (? is null or session_id is null or session_id = ?)
             )
           )
         order by updated_at desc",
    )
    .bind(&request.scope.user_id)
    .bind(&request.scope.workspace_id)
    .bind(&request.scope.workspace_id)
    .bind(&request.scope.workspace_id)
    .bind(&request.scope.workspace_id)
    .bind(&request.scope.repo_id)
    .bind(&request.scope.repo_id)
    .bind(&request.scope.workspace_id)
    .bind(&request.scope.workspace_id)
    .bind(&request.scope.repo_id)
    .bind(&request.scope.repo_id)
    .bind(&request.scope.agent_id)
    .bind(&request.scope.agent_id)
    .bind(&request.scope.session_id)
    .bind(&request.scope.session_id)
    .bind(&request.scope.workspace_id)
    .bind(&request.scope.workspace_id)
    .bind(&request.scope.repo_id)
    .bind(&request.scope.repo_id)
    .bind(&request.scope.agent_id)
    .bind(&request.scope.agent_id)
    .bind(&request.scope.session_id)
    .bind(&request.scope.session_id)
    .fetch_all(pool)
    .await?;
    let mut scored = Vec::new();
    for row in rows {
        let id: String = row.get("id");
        let text: String = row.get("text");
        let kind: String = row.get("kind");
        let episode = episodes_by_memory.get(&id);
        let searchable_text = episode_search_text(&text, episode);
        let lexical_score = lexical_score(&searchable_text, &tokens);
        let vector_score = vector_scores.get(&id).copied();
        let entities = entities_by_memory.get(&id).cloned().unwrap_or_default();
        let entity_score = entity_score(&entities, &query_entity_terms);
        let pinned = row.get::<i64, _>("pinned") != 0;
        let semantic_hit = lexical_score > 0.0
            || entity_score > 0.0
            || vector_score
                .map(|score| score >= MIN_VECTOR_ONLY_SCORE)
                .unwrap_or(false);
        if lexical_score <= 0.0
            && entity_score <= 0.0
            && !pinned
            && vector_score
                .map(|score| score < MIN_VECTOR_ONLY_SCORE)
                .unwrap_or(true)
        {
            continue;
        }
        let scope: String = row.get("scope");
        let relevance_score = vector_score
            .unwrap_or(0.0)
            .max(lexical_score)
            .max(entity_score)
            .max(if pinned {
                PINNED_LAYER_RELEVANCE_SCORE
            } else {
                0.0
            });
        let scope_score_value = scope_score(
            &scope,
            row.get::<Option<String>, _>("repo_id").as_deref(),
            row.get::<Option<String>, _>("workspace_id").as_deref(),
            row.get::<Option<String>, _>("agent_id").as_deref(),
            row.get::<Option<String>, _>("session_id").as_deref(),
            request.scope.repo_id.as_deref(),
            request.scope.workspace_id.as_deref(),
            request.scope.agent_id.as_deref(),
            request.scope.session_id.as_deref(),
        );
        let feedback_score_value = feedback_score(feedback_stats.get(&id));
        let access = access_stats.get(&id);
        let decay_score_value = memory_decay_score(access, decay_reference_time);
        let recency_score = decay_score_value;
        let base_score = ranker::final_score(relevance_score, scope_score_value, recency_score);
        let reinforcement_score_value = reinforcement_score(access);
        let temporal_score_value = temporal_score(
            row.get::<Option<i64>, _>("valid_from"),
            row.get::<Option<i64>, _>("valid_until"),
            decay_reference_time,
        );
        let score =
            base_score * feedback_score_value * reinforcement_score_value * temporal_score_value;
        let access_count = access.map(|value| value.access_count).unwrap_or_default();
        let last_accessed_at = access.and_then(|value| value.last_accessed_at);
        let profile_block = if pinned {
            formatter::profile_block_for(&kind, Some(&scope)).map(|block| {
                serde_json::json!({
                    "label": block.label,
                    "description": block.description,
                    "limit": block.limit
                })
            })
        } else {
            None
        };
        scored.push((
            score,
            ranker::kind_priority(&kind),
            row.get::<i64, _>("updated_at"),
            SearchItem {
                id,
                kind,
                scope,
                text: episode.map(episode_prompt_text).unwrap_or(text),
                score,
                metadata: serde_json::json!({
                    "pinned": pinned,
                    "profileBlock": profile_block,
                    "sourceSessionId": row.get::<Option<String>, _>("source_session_id"),
                    "sourceTurnId": row.get::<Option<String>, _>("source_turn_id"),
                    "observedAt": row.get::<Option<i64>, _>("observed_at"),
                    "validFrom": row.get::<Option<i64>, _>("valid_from"),
                    "validUntil": row.get::<Option<i64>, _>("valid_until"),
                    "supersedesMemoryId": row.get::<Option<String>, _>("supersedes_memory_id"),
                    "entities": entities,
                    "episode": episode,
                    "diagnostics": {
                        "lexicalScore": lexical_score,
                        "vectorScore": vector_score.unwrap_or(0.0),
                        "entityScore": entity_score,
                        "pinnedLayer": pinned,
                        "semanticHit": semantic_hit,
                        "pinnedScore": if pinned { PINNED_LAYER_RELEVANCE_SCORE } else { 0.0 },
                        "relevanceScore": relevance_score,
                        "scopeScore": scope_score_value,
                        "recencyScore": recency_score,
                        "decayScore": decay_score_value,
                        "feedbackScore": feedback_score_value,
                        "reinforcementScore": reinforcement_score_value,
                        "temporalScore": temporal_score_value,
                        "accessCount": access_count,
                        "lastAccessedAt": last_accessed_at,
                        "baseScore": base_score,
                        "finalScore": score
                    }
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
    let items = select_search_items(scored, limit as usize);
    if let Some(session_id) = request.scope.session_id.as_deref() {
        if !items.is_empty() {
            let turn_id = request
                .turn_id
                .as_deref()
                .filter(|value| !value.trim().is_empty())
                .map(str::to_string)
                .unwrap_or_else(|| format!("search:{}", Uuid::new_v4()));
            if let Err(error) =
                record_prompt_injection(pool, session_id, &turn_id, &items, pinned_profile_limit)
                    .await
            {
                tracing::warn!(%error, session_id, "failed to record prompt memory injection");
            }
        }
    }
    if let Err(error) = record_memory_accesses(
        pool,
        request.scope.session_id.as_deref(),
        request.turn_id.as_deref(),
        &items,
    )
    .await
    {
        tracing::warn!(%error, "failed to record memory retrieval accesses");
    }
    for item in &items {
        if let Err(error) = write_audit(
            pool,
            "system",
            "memory.retrieve",
            Some(&item.id),
            None,
            None,
            serde_json::json!({
                "kind": item.kind,
                "scope": item.scope,
                "score": item.score,
                "diagnostics": item.metadata.get("diagnostics").cloned()
            }),
        )
        .await
        {
            tracing::warn!(%error, memory_id = %item.id, "failed to audit memory retrieval");
        }
    }
    Ok(SearchResponse { items })
}

fn select_search_items(scored: Vec<ScoredSearchItem>, limit: usize) -> Vec<SearchItem> {
    if scored.is_empty() || limit == 0 {
        return Vec::new();
    }
    let mut selected_indexes = Vec::with_capacity(scored.len().min(limit));
    let mut episodic_items = 0;
    for (index, item) in scored.iter().enumerate() {
        if item.3.kind == "task_episode" {
            if episodic_items >= MAX_EPISODIC_SEARCH_ITEMS {
                continue;
            }
            episodic_items += 1;
        }
        selected_indexes.push(index);
        if selected_indexes.len() >= limit {
            break;
        }
    }
    balance_selected_pinned_profiles(&scored, &mut selected_indexes);
    selected_indexes
        .into_iter()
        .map(|index| scored[index].3.clone())
        .collect()
}

fn balance_selected_pinned_profiles(scored: &[ScoredSearchItem], selected_indexes: &mut [usize]) {
    let mut selected_by_block = HashMap::<String, usize>::new();
    for index in selected_indexes.iter().copied() {
        if let Some(block_key) = search_item_profile_block_key(&scored[index].3) {
            *selected_by_block.entry(block_key).or_default() += 1;
        }
    }
    if selected_by_block.is_empty() {
        return;
    }

    for candidate_index in 0..scored.len() {
        if selected_indexes.contains(&candidate_index) {
            continue;
        }
        let Some(candidate_key) = search_item_profile_block_key(&scored[candidate_index].3) else {
            continue;
        };
        if selected_by_block.contains_key(&candidate_key) {
            continue;
        }
        let Some(replacement_position) =
            replacement_duplicate_profile_position(scored, selected_indexes, &selected_by_block)
        else {
            break;
        };
        if let Some(old_key) =
            search_item_profile_block_key(&scored[selected_indexes[replacement_position]].3)
        {
            if let Some(count) = selected_by_block.get_mut(&old_key) {
                *count = count.saturating_sub(1);
            }
        }
        selected_indexes[replacement_position] = candidate_index;
        selected_by_block.insert(candidate_key, 1);
    }
}

fn replacement_duplicate_profile_position(
    scored: &[ScoredSearchItem],
    selected_indexes: &[usize],
    selected_by_block: &HashMap<String, usize>,
) -> Option<usize> {
    selected_indexes
        .iter()
        .enumerate()
        .rev()
        .find_map(|(position, index)| {
            let key = search_item_profile_block_key(&scored[*index].3)?;
            let count = selected_by_block.get(&key).copied().unwrap_or_default();
            (count > 1).then_some(position)
        })
}

fn search_item_profile_block_key(item: &SearchItem) -> Option<String> {
    if item
        .metadata
        .get("pinned")
        .and_then(|value| value.as_bool())
        != Some(true)
    {
        return None;
    }
    item.metadata
        .get("profileBlock")
        .and_then(|value| value.get("label"))
        .and_then(|value| value.as_str())
        .filter(|value| !value.trim().is_empty())
        .map(str::to_string)
}

async fn record_prompt_injection(
    pool: &SqlitePool,
    session_id: &str,
    turn_id: &str,
    items: &[SearchItem],
    pinned_profile_limit: usize,
) -> sqlx::Result<()> {
    let memory_ids = items.iter().map(|item| item.id.clone()).collect::<Vec<_>>();
    let context_items = items
        .iter()
        .map(|item| formatter::ContextItem {
            kind: item.kind.as_str(),
            scope: Some(item.scope.as_str()),
            text: item.text.as_str(),
            pinned: item
                .metadata
                .get("pinned")
                .and_then(|value| value.as_bool())
                .unwrap_or(false),
        })
        .collect::<Vec<_>>();
    let injected_text = formatter::format_context_items(&context_items, pinned_profile_limit);
    sqlx::query(
        "insert into prompt_injections (id, session_id, turn_id, memory_ids_json, injected_text_hash, created_at)
         values (?, ?, ?, ?, ?, ?)",
    )
    .bind(format!("inj_{}", Uuid::new_v4()))
    .bind(session_id)
    .bind(turn_id)
    .bind(serde_json::to_string(&memory_ids).unwrap_or_else(|_| "[]".to_string()))
    .bind(stable_text_hash(&injected_text))
    .bind(Utc::now().timestamp_millis())
    .execute(pool)
    .await?;
    Ok(())
}

async fn vector_scores_for_query(
    pool: &SqlitePool,
    embedder: &dyn Embedder,
    embedding_dimension: usize,
    request: &SearchRequest,
) -> anyhow::Result<HashMap<String, f32>> {
    let query_embedding = embedder.embed(&request.query).await?;
    if query_embedding.len() != embedding_dimension {
        return Err(anyhow::anyhow!(
            "query embedding dimension mismatch: got {}, expected {embedding_dimension}",
            query_embedding.len()
        ));
    }
    let hits = crate::vector::sqlite_vec_store::search(
        pool,
        &query_embedding,
        request.limit.unwrap_or(12).clamp(1, 50) * 5,
    )
    .await?;
    let mut scores = HashMap::new();
    for hit in hits {
        let distance = hit.distance.max(0.0);
        let score = 1.0 / (1.0 + distance);
        scores
            .entry(hit.memory_id)
            .and_modify(|existing: &mut f32| *existing = existing.max(score))
            .or_insert(score);
    }
    Ok(scores)
}

async fn upsert_memory_entities(
    pool: &SqlitePool,
    memory_id: &str,
    entities: &[MemoryEntityInput],
) -> sqlx::Result<()> {
    if entities.is_empty() {
        return Ok(());
    }
    let now = Utc::now().timestamp_millis();
    let mut seen = HashSet::new();
    for entity in entities {
        let text = entity.text.trim();
        let normalized = normalize_entity(text);
        if normalized.is_empty() || !seen.insert(normalized.clone()) {
            continue;
        }
        let entity_type = entity
            .entity_type
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .unwrap_or("entity");
        sqlx::query(
            "insert into memory_entities
             (id, memory_id, entity_text, entity_type, normalized_text, created_at)
             values (?, ?, ?, ?, ?, ?)",
        )
        .bind(format!("ent_{}", Uuid::new_v4()))
        .bind(memory_id)
        .bind(text)
        .bind(entity_type)
        .bind(normalized)
        .bind(now)
        .execute(pool)
        .await?;
    }
    Ok(())
}

pub fn task_episode_is_acceptable(kind: MemoryKind, episode: Option<&TaskEpisodeData>) -> bool {
    kind != MemoryKind::TaskEpisode || normalize_task_episode(kind, episode.cloned()).is_some()
}

fn normalize_task_episode(
    kind: MemoryKind,
    episode: Option<TaskEpisodeData>,
) -> Option<TaskEpisodeData> {
    if kind != MemoryKind::TaskEpisode {
        return None;
    }
    let episode = episode?;
    if !episode.is_valid() {
        return None;
    }
    let goal = clean_episode_field(&episode.goal, 1_000)?;
    let successful_pattern = clean_episode_field(&episode.successful_pattern, 1_000)?;
    let mistake = episode
        .mistake
        .as_deref()
        .and_then(|value| clean_episode_field(value, 1_000));
    let constraints = clean_episode_list(episode.constraints, 12, 400);
    let tools_used = clean_episode_list(episode.tools_used, 12, 200);
    Some(TaskEpisodeData {
        goal,
        constraints,
        tools_used,
        mistake,
        successful_pattern,
    })
}

fn clean_episode_field(value: &str, max_chars: usize) -> Option<String> {
    let trimmed = value.trim();
    if trimmed.is_empty()
        || trimmed.chars().count() > max_chars
        || redactor::contains_secret(trimmed)
    {
        return None;
    }
    Some(redactor::redact(trimmed))
}

fn clean_episode_list(values: Vec<String>, max_items: usize, max_chars: usize) -> Vec<String> {
    let mut cleaned = Vec::new();
    for value in values {
        let Some(value) = clean_episode_field(&value, max_chars) else {
            continue;
        };
        if cleaned.contains(&value) {
            continue;
        }
        cleaned.push(value);
        if cleaned.len() >= max_items {
            break;
        }
    }
    cleaned
}

async fn upsert_memory_episode(
    pool: &SqlitePool,
    memory_id: &str,
    episode: Option<&TaskEpisodeData>,
    now: i64,
) -> sqlx::Result<()> {
    let Some(episode) = episode else {
        return Ok(());
    };
    let constraints_json =
        serde_json::to_string(&episode.constraints).unwrap_or_else(|_| "[]".to_string());
    let tools_used_json =
        serde_json::to_string(&episode.tools_used).unwrap_or_else(|_| "[]".to_string());
    sqlx::query(
        "insert into memory_episodes
         (memory_id, goal, constraints_json, tools_used_json, mistake,
          successful_pattern, created_at, updated_at)
         values (?, ?, ?, ?, ?, ?, ?, ?)
         on conflict(memory_id) do update set
           goal = excluded.goal,
           constraints_json = excluded.constraints_json,
           tools_used_json = excluded.tools_used_json,
           mistake = excluded.mistake,
           successful_pattern = excluded.successful_pattern,
           updated_at = excluded.updated_at",
    )
    .bind(memory_id)
    .bind(&episode.goal)
    .bind(constraints_json)
    .bind(tools_used_json)
    .bind(episode.mistake.as_deref())
    .bind(&episode.successful_pattern)
    .bind(now)
    .bind(now)
    .execute(pool)
    .await?;
    Ok(())
}

async fn load_task_episodes_by_memory(
    pool: &SqlitePool,
) -> sqlx::Result<HashMap<String, TaskEpisodeData>> {
    let rows = sqlx::query(
        "select memory_id, goal, constraints_json, tools_used_json, mistake,
                successful_pattern
         from memory_episodes",
    )
    .fetch_all(pool)
    .await?;
    let mut episodes = HashMap::new();
    for row in rows {
        let constraints_json: String = row.get("constraints_json");
        let tools_used_json: String = row.get("tools_used_json");
        episodes.insert(
            row.get("memory_id"),
            TaskEpisodeData {
                goal: row.get("goal"),
                constraints: serde_json::from_str(&constraints_json).unwrap_or_default(),
                tools_used: serde_json::from_str(&tools_used_json).unwrap_or_default(),
                mistake: row.get("mistake"),
                successful_pattern: row.get("successful_pattern"),
            },
        );
    }
    Ok(episodes)
}

fn episode_search_text(summary: &str, episode: Option<&TaskEpisodeData>) -> String {
    let Some(episode) = episode else {
        return summary.to_string();
    };
    format!("{summary} {}", episode_prompt_text(episode))
}

fn episode_prompt_text(episode: &TaskEpisodeData) -> String {
    let mut parts = vec![format!("Goal: {}", episode.goal)];
    if !episode.constraints.is_empty() {
        parts.push(format!("Constraints: {}", episode.constraints.join(", ")));
    }
    if !episode.tools_used.is_empty() {
        parts.push(format!("Tools used: {}", episode.tools_used.join(", ")));
    }
    if let Some(mistake) = episode
        .mistake
        .as_deref()
        .filter(|value| !value.trim().is_empty())
    {
        parts.push(format!("Mistake to avoid: {mistake}"));
    }
    parts.push(format!(
        "Successful pattern: {}",
        episode.successful_pattern
    ));
    parts.join(" | ")
}

async fn load_entities_by_memory(
    pool: &SqlitePool,
) -> sqlx::Result<HashMap<String, Vec<MemoryEntity>>> {
    let rows = sqlx::query(
        "select memory_id, entity_text, entity_type, normalized_text
         from memory_entities
         order by rowid asc",
    )
    .fetch_all(pool)
    .await?;
    let mut entities = HashMap::<String, Vec<MemoryEntity>>::new();
    for row in rows {
        entities
            .entry(row.get("memory_id"))
            .or_default()
            .push(MemoryEntity {
                text: row.get("entity_text"),
                entity_type: row.get("entity_type"),
                normalized_text: row.get("normalized_text"),
            });
    }
    Ok(entities)
}

async fn load_feedback_stats(pool: &SqlitePool) -> sqlx::Result<HashMap<String, FeedbackStats>> {
    let rows = sqlx::query(
        "select memory_id,
                sum(case when rating = 'helpful' then 1 else 0 end) as helpful,
                sum(case when rating = 'not_relevant' then 1 else 0 end) as not_relevant,
                sum(case when rating = 'stale' then 1 else 0 end) as stale
         from memory_feedback
         group by memory_id",
    )
    .fetch_all(pool)
    .await?;
    let mut stats = HashMap::new();
    for row in rows {
        stats.insert(
            row.get("memory_id"),
            FeedbackStats {
                helpful: row.get::<i64, _>("helpful"),
                not_relevant: row.get::<i64, _>("not_relevant"),
                stale: row.get::<i64, _>("stale"),
            },
        );
    }
    Ok(stats)
}

async fn load_access_stats(pool: &SqlitePool) -> sqlx::Result<HashMap<String, AccessStats>> {
    let rows = sqlx::query(
        "select memory_id,
                count(*) as access_count,
                max(accessed_at) as last_accessed_at
         from memory_accesses
         group by memory_id",
    )
    .fetch_all(pool)
    .await?;
    let mut stats = HashMap::new();
    for row in rows {
        stats.insert(
            row.get("memory_id"),
            AccessStats {
                access_count: row.get("access_count"),
                last_accessed_at: row.get("last_accessed_at"),
            },
        );
    }
    Ok(stats)
}

async fn record_memory_accesses(
    pool: &SqlitePool,
    session_id: Option<&str>,
    turn_id: Option<&str>,
    items: &[SearchItem],
) -> sqlx::Result<()> {
    let now = Utc::now().timestamp_millis();
    for item in items {
        if !should_record_memory_access(item) {
            continue;
        }
        sqlx::query(
            "insert into memory_accesses (id, memory_id, session_id, turn_id, accessed_at)
             values (?, ?, ?, ?, ?)",
        )
        .bind(format!("access_{}", Uuid::new_v4()))
        .bind(&item.id)
        .bind(session_id)
        .bind(turn_id)
        .bind(now)
        .execute(pool)
        .await?;
        maybe_promote_access_reinforced_memory(pool, item, now).await?;
    }
    Ok(())
}

fn should_record_memory_access(item: &SearchItem) -> bool {
    item.metadata
        .get("diagnostics")
        .and_then(|value| value.get("semanticHit"))
        .and_then(|value| value.as_bool())
        .unwrap_or(true)
}

async fn maybe_promote_access_reinforced_memory(
    pool: &SqlitePool,
    item: &SearchItem,
    now: i64,
) -> sqlx::Result<()> {
    if !is_profile_layer_kind_wire(&item.kind, &item.scope) {
        return Ok(());
    }
    let access_count: i64 =
        sqlx::query_scalar("select count(*) from memory_accesses where memory_id = ?")
            .bind(&item.id)
            .fetch_one(pool)
            .await?;
    if access_count < PINNED_AUTO_ACCESS_THRESHOLD {
        return Ok(());
    }
    let negative_feedback_count: i64 = sqlx::query_scalar(
        "select count(*) from memory_feedback
         where memory_id = ? and rating in ('not_relevant', 'stale')",
    )
    .bind(&item.id)
    .fetch_one(pool)
    .await?;
    if negative_feedback_count > 0 {
        return Ok(());
    }
    let result = sqlx::query(
        "update memory_items
         set pinned = 1, updated_at = ?
         where id = ? and status = 'active' and pinned = 0",
    )
    .bind(now)
    .bind(&item.id)
    .execute(pool)
    .await?;
    if result.rows_affected() > 0 {
        write_audit(
            pool,
            "system",
            "memory.promote",
            Some(&item.id),
            None,
            None,
            serde_json::json!({
                "reason": "access_reinforcement",
                "accessCount": access_count,
                "threshold": PINNED_AUTO_ACCESS_THRESHOLD
            }),
        )
        .await?;
    }
    Ok(())
}

fn feedback_score(stats: Option<&FeedbackStats>) -> f32 {
    let Some(stats) = stats else {
        return 1.0;
    };
    let helpful_boost = stats.helpful as f32 * 0.08;
    let not_relevant_penalty = stats.not_relevant as f32 * 0.35;
    let stale_penalty = stats.stale as f32 * 0.20;
    (1.0 + helpful_boost - not_relevant_penalty - stale_penalty).clamp(0.55, 1.25)
}

fn reinforcement_score(stats: Option<&AccessStats>) -> f32 {
    let Some(stats) = stats else {
        return 1.0;
    };
    if stats.access_count <= 0 {
        return 1.0;
    }
    (1.0 + (stats.access_count as f32).ln_1p() * 0.04).min(1.20)
}

fn memory_decay_score(stats: Option<&AccessStats>, reference_time: i64) -> f32 {
    let Some(last_accessed_at) = stats.and_then(|value| value.last_accessed_at) else {
        return 1.0;
    };
    let age = reference_time.saturating_sub(last_accessed_at);
    if age <= MEMORY_DECAY_RECENT_WINDOW_MS {
        1.05
    } else if age <= MEMORY_DECAY_NEUTRAL_WINDOW_MS {
        1.0
    } else if age <= MEMORY_DECAY_STALE_WINDOW_MS {
        0.92
    } else if age <= MEMORY_DECAY_OLD_WINDOW_MS {
        0.84
    } else {
        0.78
    }
}

fn temporal_score(valid_from: Option<i64>, valid_until: Option<i64>, reference_time: i64) -> f32 {
    if valid_until.is_some_and(|value| value < reference_time) {
        return 0.55;
    }
    if valid_from.is_some_and(|value| value > reference_time) {
        return 0.70;
    }
    1.0
}

async fn list_maintenance_memory(
    pool: &SqlitePool,
    scope: &MemoryScope,
    limit: i64,
) -> sqlx::Result<Vec<MemoryResponse>> {
    let workspace_id = scope.workspace_id.as_deref();
    let repo_id = scope.repo_id.as_deref();
    let agent_id = scope.agent_id.as_deref();
    let session_id = scope.session_id.as_deref();
    let rows = sqlx::query(
        "select id, kind, scope, text, user_id, workspace_id, repo_id, agent_id, session_id, source, source_session_id, source_turn_id, pinned, status, created_at, updated_at
         from memory_items
         where status = 'active'
           and user_id = ?
           and (
               scope = 'global'
               or (
                   scope = 'workspace'
                   and (? is null or workspace_id is null or workspace_id = ?)
               )
               or (
                   scope = 'repo'
                   and (? is null or workspace_id is null or workspace_id = ?)
                   and (? is null or repo_id is null or repo_id = ?)
               )
               or (
                   scope = 'session'
                   and (? is null or workspace_id is null or workspace_id = ?)
                   and (? is null or repo_id is null or repo_id = ?)
                   and (? is null or agent_id is null or agent_id = ?)
                   and (? is null or session_id is null or session_id = ?)
               )
               or (
                   scope not in ('global', 'workspace', 'repo', 'session')
                   and (? is null or workspace_id is null or workspace_id = ?)
                   and (? is null or repo_id is null or repo_id = ?)
                   and (? is null or agent_id is null or agent_id = ?)
                   and (? is null or session_id is null or session_id = ?)
               )
           )
         order by updated_at desc
         limit ?",
    )
    .bind(&scope.user_id)
    .bind(workspace_id)
    .bind(workspace_id)
    .bind(workspace_id)
    .bind(workspace_id)
    .bind(repo_id)
    .bind(repo_id)
    .bind(workspace_id)
    .bind(workspace_id)
    .bind(repo_id)
    .bind(repo_id)
    .bind(agent_id)
    .bind(agent_id)
    .bind(session_id)
    .bind(session_id)
    .bind(workspace_id)
    .bind(workspace_id)
    .bind(repo_id)
    .bind(repo_id)
    .bind(agent_id)
    .bind(agent_id)
    .bind(session_id)
    .bind(session_id)
    .bind(limit)
    .fetch_all(pool)
    .await?;
    rows.into_iter().map(row_to_memory).collect()
}

async fn list_expired_maintenance_memory(
    pool: &SqlitePool,
    scope: &MemoryScope,
    limit: i64,
    reference_time: i64,
) -> sqlx::Result<Vec<MemoryResponse>> {
    let workspace_id = scope.workspace_id.as_deref();
    let repo_id = scope.repo_id.as_deref();
    let agent_id = scope.agent_id.as_deref();
    let session_id = scope.session_id.as_deref();
    let rows = sqlx::query(
        "select id, kind, scope, text, user_id, workspace_id, repo_id, agent_id, session_id, source, source_session_id, source_turn_id, pinned, status, created_at, updated_at
         from memory_items
         where status = 'active'
           and valid_until is not null
           and valid_until < ?
           and user_id = ?
           and (
               scope = 'global'
               or (
                   scope = 'workspace'
                   and (? is null or workspace_id is null or workspace_id = ?)
               )
               or (
                   scope = 'repo'
                   and (? is null or workspace_id is null or workspace_id = ?)
                   and (? is null or repo_id is null or repo_id = ?)
               )
               or (
                   scope = 'session'
                   and (? is null or workspace_id is null or workspace_id = ?)
                   and (? is null or repo_id is null or repo_id = ?)
                   and (? is null or agent_id is null or agent_id = ?)
                   and (? is null or session_id is null or session_id = ?)
               )
               or (
                   scope not in ('global', 'workspace', 'repo', 'session')
                   and (? is null or workspace_id is null or workspace_id = ?)
                   and (? is null or repo_id is null or repo_id = ?)
                   and (? is null or agent_id is null or agent_id = ?)
                   and (? is null or session_id is null or session_id = ?)
               )
           )
         order by valid_until asc, updated_at desc
         limit ?",
    )
    .bind(reference_time)
    .bind(&scope.user_id)
    .bind(workspace_id)
    .bind(workspace_id)
    .bind(workspace_id)
    .bind(workspace_id)
    .bind(repo_id)
    .bind(repo_id)
    .bind(workspace_id)
    .bind(workspace_id)
    .bind(repo_id)
    .bind(repo_id)
    .bind(agent_id)
    .bind(agent_id)
    .bind(session_id)
    .bind(session_id)
    .bind(workspace_id)
    .bind(workspace_id)
    .bind(repo_id)
    .bind(repo_id)
    .bind(agent_id)
    .bind(agent_id)
    .bind(session_id)
    .bind(session_id)
    .bind(limit)
    .fetch_all(pool)
    .await?;
    rows.into_iter().map(row_to_memory).collect()
}

async fn clear_memory_items(
    pool: &SqlitePool,
    level: &str,
    scope: &MemoryScope,
    now: i64,
) -> sqlx::Result<u64> {
    let result = match level {
        "session" => {
            sqlx::query(
                "update memory_items
             set status = 'deleted', deleted_at = ?, updated_at = ?
             where status != 'deleted'
               and user_id = ?
               and workspace_id is ?
               and repo_id is ?
               and agent_id is ?
               and session_id is ?",
            )
            .bind(now)
            .bind(now)
            .bind(&scope.user_id)
            .bind(&scope.workspace_id)
            .bind(&scope.repo_id)
            .bind(&scope.agent_id)
            .bind(&scope.session_id)
            .execute(pool)
            .await?
        }
        "workspace" => {
            sqlx::query(
                "update memory_items
             set status = 'deleted', deleted_at = ?, updated_at = ?
             where status != 'deleted'
               and user_id = ?
               and workspace_id is ?",
            )
            .bind(now)
            .bind(now)
            .bind(&scope.user_id)
            .bind(&scope.workspace_id)
            .execute(pool)
            .await?
        }
        "all" => {
            sqlx::query(
                "update memory_items
             set status = 'deleted', deleted_at = ?, updated_at = ?
             where status != 'deleted' and user_id = ?",
            )
            .bind(now)
            .bind(now)
            .bind(&scope.user_id)
            .execute(pool)
            .await?
        }
        _ => {
            sqlx::query(
                "update memory_items
             set status = 'deleted', deleted_at = ?, updated_at = ?
             where status != 'deleted'
               and user_id = ?
               and repo_id is ?",
            )
            .bind(now)
            .bind(now)
            .bind(&scope.user_id)
            .bind(&scope.repo_id)
            .execute(pool)
            .await?
        }
    };
    Ok(result.rows_affected())
}

async fn reject_pending_candidates(
    pool: &SqlitePool,
    level: &str,
    scope: &MemoryScope,
    now: i64,
) -> sqlx::Result<u64> {
    let result = match level {
        "session" => {
            sqlx::query(
                "update memory_candidates
             set status = 'rejected', reviewed_at = ?
             where status = 'pending'
               and user_id = ?
               and workspace_id is ?
               and repo_id is ?
               and agent_id is ?
               and session_id is ?",
            )
            .bind(now)
            .bind(&scope.user_id)
            .bind(&scope.workspace_id)
            .bind(&scope.repo_id)
            .bind(&scope.agent_id)
            .bind(&scope.session_id)
            .execute(pool)
            .await?
        }
        "workspace" => {
            sqlx::query(
                "update memory_candidates
             set status = 'rejected', reviewed_at = ?
             where status = 'pending'
               and user_id = ?
               and workspace_id is ?",
            )
            .bind(now)
            .bind(&scope.user_id)
            .bind(&scope.workspace_id)
            .execute(pool)
            .await?
        }
        "all" => {
            sqlx::query(
                "update memory_candidates
             set status = 'rejected', reviewed_at = ?
             where status = 'pending' and user_id = ?",
            )
            .bind(now)
            .bind(&scope.user_id)
            .execute(pool)
            .await?
        }
        _ => {
            sqlx::query(
                "update memory_candidates
             set status = 'rejected', reviewed_at = ?
             where status = 'pending'
               and user_id = ?
               and repo_id is ?",
            )
            .bind(now)
            .bind(&scope.user_id)
            .bind(&scope.repo_id)
            .execute(pool)
            .await?
        }
    };
    Ok(result.rows_affected())
}

async fn reject_pending_candidates_covered_by_active_memory(
    pool: &SqlitePool,
    scope: &MemoryScope,
    now: i64,
) -> sqlx::Result<u64> {
    let rows = sqlx::query(
        "select id, kind, scope, text, workspace_id, repo_id, agent_id, session_id
         from memory_candidates
         where status = 'pending' and user_id = ?",
    )
    .bind(&scope.user_id)
    .fetch_all(pool)
    .await?;
    let mut rejected = 0_u64;
    for row in rows {
        let candidate_scope: String = row.get("scope");
        if !scoped_duplicate_row_matches(scope, &candidate_scope, &row) {
            continue;
        }
        let kind: String = row.get("kind");
        let text: String = row.get("text");
        let Some(memory_id) =
            find_active_duplicate_memory_id(pool, scope, &kind, &candidate_scope, &text).await?
        else {
            continue;
        };
        let candidate_id: String = row.get("id");
        let result = sqlx::query(
            "update memory_candidates
             set status = 'rejected', reviewed_at = ?
             where id = ? and status = 'pending'",
        )
        .bind(now)
        .bind(&candidate_id)
        .execute(pool)
        .await?;
        if result.rows_affected() == 0 {
            continue;
        }
        rejected += result.rows_affected();
        write_audit(
            pool,
            "maintenance",
            "candidate.auto_reject_duplicate",
            Some(&memory_id),
            Some(&candidate_id),
            None,
            serde_json::json!({
                "kind": kind,
                "scope": candidate_scope,
                "textHash": stable_text_hash(&text),
                "reason": "covered_by_active_memory"
            }),
        )
        .await?;
    }
    Ok(rejected)
}

async fn reject_pending_change_requests(
    pool: &SqlitePool,
    level: &str,
    scope: &MemoryScope,
    now: i64,
) -> sqlx::Result<u64> {
    let result = match level {
        "session" => {
            sqlx::query(
                "update memory_change_requests
             set status = 'rejected', reviewed_at = ?
             where status = 'pending'
               and user_id = ?
               and workspace_id is ?
               and repo_id is ?
               and agent_id is ?
               and session_id is ?",
            )
            .bind(now)
            .bind(&scope.user_id)
            .bind(&scope.workspace_id)
            .bind(&scope.repo_id)
            .bind(&scope.agent_id)
            .bind(&scope.session_id)
            .execute(pool)
            .await?
        }
        "workspace" => {
            sqlx::query(
                "update memory_change_requests
             set status = 'rejected', reviewed_at = ?
             where status = 'pending'
               and user_id = ?
               and workspace_id is ?",
            )
            .bind(now)
            .bind(&scope.user_id)
            .bind(&scope.workspace_id)
            .execute(pool)
            .await?
        }
        "all" => {
            sqlx::query(
                "update memory_change_requests
             set status = 'rejected', reviewed_at = ?
             where status = 'pending' and user_id = ?",
            )
            .bind(now)
            .bind(&scope.user_id)
            .execute(pool)
            .await?
        }
        _ => {
            sqlx::query(
                "update memory_change_requests
             set status = 'rejected', reviewed_at = ?
             where status = 'pending'
               and user_id = ?
               and repo_id is ?",
            )
            .bind(now)
            .bind(&scope.user_id)
            .bind(&scope.repo_id)
            .execute(pool)
            .await?
        }
    };
    Ok(result.rows_affected())
}

fn fallback_merge_proposal(
    left: &MemoryResponse,
    right: &MemoryResponse,
    confidence: f32,
) -> MaintenanceProposal {
    MaintenanceProposal {
        action: "merge".to_string(),
        target_memory_ids: vec![left.id.clone(), right.id.clone()],
        proposed_kind: left.kind,
        proposed_scope: left.scope.clone(),
        proposed_text: Some(merged_memory_text(left, right)),
        reason: Some(
            "Two memories appear to describe the same fact; merge keeps retrieval concise."
                .to_string(),
        ),
        confidence,
    }
}

fn expired_memory_proposal(memory: &MemoryResponse) -> MaintenanceProposal {
    MaintenanceProposal {
        action: "expire".to_string(),
        target_memory_ids: vec![memory.id.clone()],
        proposed_kind: memory.kind,
        proposed_scope: memory.scope.clone(),
        proposed_text: None,
        reason: Some(
            "Memory valid_until is before the maintenance run time; expire removes it from active retrieval."
                .to_string(),
        ),
        confidence: 0.99,
    }
}

async fn maintenance_llm_proposal(
    config: &MaintenanceLlmConfig,
    scope: &MemoryScope,
    left: &MemoryResponse,
    right: &MemoryResponse,
    fallback: &MaintenanceProposal,
) -> anyhow::Result<Option<MaintenanceProposal>> {
    let url = format!("{}/chat/completions", config.base_url.trim_end_matches('/'));
    let user_payload = serde_json::json!({
        "scope": {
            "userId": &scope.user_id,
            "workspaceId": &scope.workspace_id,
            "repoId": &scope.repo_id,
            "agentId": &scope.agent_id,
            "sessionId": &scope.session_id
        },
        "memories": [
            {
                "id": &left.id,
                "kind": kind_to_wire(left.kind),
                "scope": &left.scope,
                "text": &left.text
            },
            {
                "id": &right.id,
                "kind": kind_to_wire(right.kind),
                "scope": &right.scope,
                "text": &right.text
            }
        ],
        "allowedActions": ["update", "disable", "delete", "merge", "summarize", "expire", "supersede"],
        "fallback": {
            "action": &fallback.action,
            "targetMemoryIds": &fallback.target_memory_ids,
            "proposedKind": kind_to_wire(fallback.proposed_kind),
            "proposedScope": &fallback.proposed_scope,
            "proposedText": &fallback.proposed_text,
            "confidence": fallback.confidence,
            "reason": &fallback.reason
        }
    });
    let body = serde_json::json!({
        "model": config.model,
        "temperature": 0,
        "response_format": {"type": "json_object"},
        "messages": [
            {
                "role": "system",
                "content": "You are a maintenance extractor for a local memory store. Return compact JSON only. Do not invent facts. Prefer merge or summarize over delete. Use delete only when the memory is clearly invalid and still mark it for review."
            },
            {
                "role": "user",
                "content": format!(
                    "Review these scoped memory items and return JSON as {{\"changeRequests\":[...]}}. Each request may include action,targetMemoryIds,proposedKind,proposedScope,proposedText,confidence,reason. Input: {}",
                    user_payload
                )
            }
        ]
    });
    let http = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(5))
        .build()?;
    let mut request = http.post(url).json(&body);
    if let Some(api_key) = &config.api_key {
        request = request.bearer_auth(api_key);
    }
    let response = request.send().await?.error_for_status()?;
    let response = response.json::<ChatCompletionsResponse>().await?;
    let content = response
        .choices
        .first()
        .map(|choice| choice.message.content.trim())
        .filter(|content| !content.is_empty());
    let Some(content) = content else {
        return Ok(None);
    };
    let envelope = serde_json::from_str::<MaintenanceExtractorEnvelope>(
        extract_json_object(content).unwrap_or(content),
    )?;
    let Some(item) = envelope.change_requests.into_iter().next() else {
        return Ok(None);
    };
    Ok(proposal_from_extractor_item(item, fallback))
}

fn proposal_from_extractor_item(
    item: MaintenanceExtractorItem,
    fallback: &MaintenanceProposal,
) -> Option<MaintenanceProposal> {
    let mut action = item
        .action
        .unwrap_or_else(|| fallback.action.clone())
        .trim()
        .to_ascii_lowercase();
    if !matches!(
        action.as_str(),
        "update" | "disable" | "delete" | "merge" | "summarize" | "expire" | "supersede"
    ) {
        return None;
    }
    let target_memory_ids = if item.target_memory_ids.is_empty() {
        fallback.target_memory_ids.clone()
    } else {
        item.target_memory_ids
            .into_iter()
            .map(|id| id.trim().to_string())
            .filter(|id| !id.is_empty())
            .collect::<Vec<_>>()
    };
    if action == "summarize" && target_memory_ids.len() > 1 {
        action = "merge".to_string();
    }
    if !valid_maintenance_targets(
        action.as_str(),
        &target_memory_ids,
        &fallback.target_memory_ids,
    ) {
        return None;
    }
    let confidence = item
        .confidence
        .unwrap_or(fallback.confidence)
        .clamp(0.0, 1.0);
    Some(MaintenanceProposal {
        action,
        target_memory_ids,
        proposed_kind: item.proposed_kind.unwrap_or(fallback.proposed_kind),
        proposed_scope: item
            .proposed_scope
            .unwrap_or_else(|| fallback.proposed_scope.clone()),
        proposed_text: item
            .proposed_text
            .or_else(|| fallback.proposed_text.clone()),
        reason: item.reason.or_else(|| fallback.reason.clone()),
        confidence,
    })
}

fn valid_maintenance_targets(
    action: &str,
    target_memory_ids: &[String],
    allowed_memory_ids: &[String],
) -> bool {
    if target_memory_ids.is_empty() || allowed_memory_ids.is_empty() {
        return false;
    }
    let allowed = allowed_memory_ids
        .iter()
        .map(String::as_str)
        .collect::<HashSet<_>>();
    let targets = target_memory_ids
        .iter()
        .map(String::as_str)
        .collect::<HashSet<_>>();
    if targets.len() != target_memory_ids.len() {
        return false;
    }
    if !targets.iter().all(|id| allowed.contains(id)) {
        return false;
    }
    match action {
        "merge" | "supersede" => {
            targets.len() == allowed.len() && allowed.iter().all(|id| targets.contains(id))
        }
        "update" | "summarize" => targets.len() == 1,
        "disable" | "delete" | "expire" => true,
        _ => false,
    }
}

fn extract_json_object(content: &str) -> Option<&str> {
    let start = content.find('{')?;
    let end = content.rfind('}')?;
    if end < start {
        return None;
    }
    Some(&content[start..=end])
}

#[allow(clippy::too_many_arguments)]
async fn update_memory_from_change_request(
    pool: &SqlitePool,
    id: &str,
    kind: MemoryKind,
    scope: String,
    text: String,
    status: &str,
    audit_action: &str,
    change_request_id: &str,
    actor: &str,
    source: &str,
) -> sqlx::Result<MemoryResponse> {
    let now = Utc::now().timestamp_millis();
    let text = redactor::redact(text.trim());
    let result = sqlx::query(
        "update memory_items set kind = ?, scope = ?, text = ?, source = ?, status = ?, updated_at = ? where id = ?",
    )
    .bind(kind_to_wire(kind))
    .bind(scope)
    .bind(text)
    .bind(source)
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
        actor,
        audit_action,
        Some(id),
        None,
        Some(change_request_id),
        serde_json::json!({}),
    )
    .await?;
    get_memory(pool, id).await
}

async fn set_memory_status_from_change_request(
    pool: &SqlitePool,
    id: &str,
    status: &str,
    audit_action: &str,
    change_request_id: &str,
    actor: &str,
) -> sqlx::Result<()> {
    let now = Utc::now().timestamp_millis();
    let result = sqlx::query("update memory_items set status = ?, updated_at = ? where id = ?")
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
        actor,
        audit_action,
        Some(id),
        None,
        Some(change_request_id),
        serde_json::json!({}),
    )
    .await
}

async fn soft_delete_memory_from_change_request(
    pool: &SqlitePool,
    id: &str,
    change_request_id: &str,
    actor: &str,
) -> sqlx::Result<()> {
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
        actor,
        "memory.delete",
        Some(id),
        None,
        Some(change_request_id),
        serde_json::json!({"soft": true}),
    )
    .await
}

async fn merge_memory_from_change_request(
    pool: &SqlitePool,
    change_request: &MemoryChangeRequestResponse,
    request: ApproveChangeRequestRequest,
    actor: &str,
) -> sqlx::Result<MemoryResponse> {
    let first_id = change_request
        .target_memory_ids
        .first()
        .ok_or(sqlx::Error::RowNotFound)?;
    let first = get_memory(pool, first_id).await?;
    let kind = request
        .proposed_kind
        .or(change_request.proposed_kind)
        .unwrap_or(first.kind);
    let scope = request
        .proposed_scope
        .or(change_request.proposed_scope.clone())
        .unwrap_or_else(|| first.scope.clone());
    let text = request
        .proposed_text
        .or(change_request.proposed_text.clone())
        .unwrap_or_else(|| first.text.clone());
    let now = Utc::now().timestamp_millis();
    let text = redactor::redact(text.trim());
    let pinned = is_profile_layer_kind(kind, &scope);
    let merge_scope = MemoryScope {
        user_id: first.user_id.clone(),
        workspace_id: first.workspace_id.clone(),
        repo_id: first.repo_id.clone(),
        agent_id: first.agent_id.clone(),
        session_id: first.session_id.clone(),
    };
    if let Some(existing_id) =
        find_active_duplicate_memory_id(pool, &merge_scope, kind_to_wire(kind), &scope, &text)
            .await?
            .filter(|id| !change_request.target_memory_ids.contains(id))
    {
        for target_id in &change_request.target_memory_ids {
            set_memory_status_from_change_request(
                pool,
                target_id,
                "disabled",
                "memory.disable",
                &change_request.id,
                actor,
            )
            .await?;
        }
        write_audit(
            pool,
            actor,
            "memory.merge",
            Some(&existing_id),
            None,
            Some(&change_request.id),
            serde_json::json!({
                "mergedFrom": change_request.target_memory_ids,
                "mergedIntoExisting": true,
                "pinned": pinned
            }),
        )
        .await?;
        return get_memory(pool, &existing_id).await;
    }
    let merged_id = format!("mem_{}", Uuid::new_v4());
    sqlx::query(
        "insert into memory_items
        (id, user_id, workspace_id, repo_id, agent_id, session_id, kind, scope, text, source, pinned, status, created_at, updated_at)
        values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'active', ?, ?)",
    )
    .bind(&merged_id)
    .bind(&first.user_id)
    .bind(&first.workspace_id)
    .bind(&first.repo_id)
    .bind(&first.agent_id)
    .bind(&first.session_id)
    .bind(kind_to_wire(kind))
    .bind(&scope)
    .bind(&text)
    .bind(&change_request.source)
    .bind(if pinned { 1_i64 } else { 0_i64 })
    .bind(now)
    .bind(now)
    .execute(pool)
    .await?;
    for target_id in &change_request.target_memory_ids {
        set_memory_status_from_change_request(
            pool,
            target_id,
            "disabled",
            "memory.disable",
            &change_request.id,
            actor,
        )
        .await?;
    }
    write_audit(
        pool,
        actor,
        "memory.merge",
        Some(&merged_id),
        None,
        Some(&change_request.id),
        serde_json::json!({
            "mergedFrom": change_request.target_memory_ids,
            "pinned": pinned
        }),
    )
    .await?;
    get_memory(pool, &merged_id).await
}

async fn supersede_memory_from_change_request(
    pool: &SqlitePool,
    change_request: &MemoryChangeRequestResponse,
    request: ApproveChangeRequestRequest,
    actor: &str,
) -> sqlx::Result<MemoryResponse> {
    let old_id = change_request
        .target_memory_ids
        .first()
        .ok_or(sqlx::Error::RowNotFound)?;
    let old = get_memory(pool, old_id).await?;
    let kind = request
        .proposed_kind
        .or(change_request.proposed_kind)
        .unwrap_or(old.kind);
    let scope = request
        .proposed_scope
        .or(change_request.proposed_scope.clone())
        .unwrap_or_else(|| old.scope.clone());
    let proposed_text = request
        .proposed_text
        .or(change_request.proposed_text.clone());
    if let Some(existing_new_id) = change_request
        .target_memory_ids
        .get(1)
        .filter(|id| id.as_str() != old_id)
    {
        let existing_new = get_memory(pool, existing_new_id).await?;
        let text = proposed_text
            .clone()
            .unwrap_or_else(|| existing_new.text.clone());
        if existing_new.kind == kind
            && existing_new.scope == scope
            && normalize_duplicate_text(&existing_new.text) == normalize_duplicate_text(&text)
        {
            return link_existing_superseding_memory(
                pool,
                old_id,
                existing_new_id,
                &change_request.id,
                actor,
            )
            .await;
        }
    }
    let text = proposed_text.unwrap_or_else(|| old.text.clone());
    let text = redactor::redact(text.trim());
    let supersede_scope = MemoryScope {
        user_id: old.user_id.clone(),
        workspace_id: old.workspace_id.clone(),
        repo_id: old.repo_id.clone(),
        agent_id: old.agent_id.clone(),
        session_id: old.session_id.clone(),
    };
    if let Some(existing_new_id) =
        find_active_duplicate_memory_id(pool, &supersede_scope, kind_to_wire(kind), &scope, &text)
            .await?
            .filter(|id| !change_request.target_memory_ids.contains(id))
    {
        return link_existing_superseding_memory(
            pool,
            old_id,
            &existing_new_id,
            &change_request.id,
            actor,
        )
        .await;
    }
    let now = Utc::now().timestamp_millis();
    let new_id = format!("mem_{}", Uuid::new_v4());
    let pinned = is_profile_layer_kind(kind, &scope);
    sqlx::query(
        "insert into memory_items
        (id, user_id, workspace_id, repo_id, agent_id, session_id, kind, scope, text, source,
         valid_from, supersedes_memory_id, pinned, status, created_at, updated_at)
        values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'active', ?, ?)",
    )
    .bind(&new_id)
    .bind(&old.user_id)
    .bind(&old.workspace_id)
    .bind(&old.repo_id)
    .bind(&old.agent_id)
    .bind(&old.session_id)
    .bind(kind_to_wire(kind))
    .bind(&scope)
    .bind(&text)
    .bind(&change_request.source)
    .bind(now)
    .bind(old_id)
    .bind(if pinned { 1_i64 } else { 0_i64 })
    .bind(now)
    .bind(now)
    .execute(pool)
    .await?;

    let result =
        sqlx::query("update memory_items set valid_until = ?, updated_at = ? where id = ?")
            .bind(now)
            .bind(now)
            .bind(old_id)
            .execute(pool)
            .await?;
    if result.rows_affected() == 0 {
        return Err(sqlx::Error::RowNotFound);
    }

    write_audit(
        pool,
        actor,
        "memory.expire",
        Some(old_id),
        None,
        Some(&change_request.id),
        serde_json::json!({"supersededBy": new_id, "validUntil": now}),
    )
    .await?;
    write_audit(
        pool,
        actor,
        "memory.supersede",
        Some(&new_id),
        None,
        Some(&change_request.id),
        serde_json::json!({"supersedes": old_id, "validFrom": now}),
    )
    .await?;
    get_memory(pool, &new_id).await
}

async fn link_existing_superseding_memory(
    pool: &SqlitePool,
    old_id: &str,
    new_id: &str,
    change_request_id: &str,
    actor: &str,
) -> sqlx::Result<MemoryResponse> {
    let now = Utc::now().timestamp_millis();
    let new = get_memory(pool, new_id).await?;
    let pinned = is_profile_layer_kind(new.kind, &new.scope);
    let result =
        sqlx::query("update memory_items set valid_until = ?, updated_at = ? where id = ?")
            .bind(now)
            .bind(now)
            .bind(old_id)
            .execute(pool)
            .await?;
    if result.rows_affected() == 0 {
        return Err(sqlx::Error::RowNotFound);
    }

    let result = sqlx::query(
        "update memory_items
         set valid_from = coalesce(valid_from, ?),
             supersedes_memory_id = coalesce(supersedes_memory_id, ?),
             pinned = case when ? then 1 else pinned end,
             updated_at = ?
         where id = ? and status = 'active'",
    )
    .bind(now)
    .bind(old_id)
    .bind(pinned)
    .bind(now)
    .bind(new_id)
    .execute(pool)
    .await?;
    if result.rows_affected() == 0 {
        return Err(sqlx::Error::RowNotFound);
    }

    write_audit(
        pool,
        actor,
        "memory.expire",
        Some(old_id),
        None,
        Some(change_request_id),
        serde_json::json!({"supersededBy": new_id, "validUntil": now}),
    )
    .await?;
    write_audit(
        pool,
        actor,
        "memory.supersede",
        Some(new_id),
        None,
        Some(change_request_id),
        serde_json::json!({
            "supersedes": old_id,
            "validFrom": now,
            "pinned": pinned
        }),
    )
    .await?;
    get_memory(pool, new_id).await
}

async fn get_memory(pool: &SqlitePool, id: &str) -> sqlx::Result<MemoryResponse> {
    let row = sqlx::query(
        "select id, kind, scope, text, user_id, workspace_id, repo_id, agent_id, session_id, source, source_session_id, source_turn_id, pinned, status, created_at, updated_at
         from memory_items where id = ?",
    )
    .bind(id)
    .fetch_one(pool)
    .await?;
    row_to_memory(row)
}

async fn get_change_request(
    pool: &SqlitePool,
    id: &str,
) -> sqlx::Result<MemoryChangeRequestResponse> {
    let row = sqlx::query(
        "select cr.id, cr.action, cr.source, cr.target_memory_id, cr.target_memory_ids_json,
                cr.proposed_kind, cr.proposed_scope, cr.proposed_text, cr.reason,
                cr.confidence, cr.status, cr.created_at, cr.reviewed_at,
                m.text as target_memory_text
         from memory_change_requests cr
         left join memory_items m on m.id = cr.target_memory_id
         where cr.id = ?",
    )
    .bind(id)
    .fetch_one(pool)
    .await?;
    row_to_change_request(row)
}

async fn get_pending_change_request(
    pool: &SqlitePool,
    id: &str,
) -> sqlx::Result<MemoryChangeRequestResponse> {
    let request = get_change_request(pool, id).await?;
    if request.status != "pending" {
        return Err(sqlx::Error::RowNotFound);
    }
    Ok(request)
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
    let scope: String = row.get("scope");
    let pinned = row.get::<i64, _>("pinned") != 0;
    let profile_block = if pinned {
        formatter::profile_block_for(&kind, Some(&scope)).map(|block| {
            serde_json::json!({
                "label": block.label,
                "description": block.description,
                "limit": block.limit
            })
        })
    } else {
        None
    };
    Ok(MemoryResponse {
        id: row.get("id"),
        kind: serde_json::from_value(serde_json::Value::String(kind))
            .map_err(|error| sqlx::Error::Decode(Box::new(error)))?,
        source: row.get("source"),
        scope,
        text: row.get("text"),
        pinned,
        profile_block,
        user_id: row.get("user_id"),
        workspace_id: row.get("workspace_id"),
        repo_id: row.get("repo_id"),
        agent_id: row.get("agent_id"),
        session_id: row.get("session_id"),
        source_session_id: row.get("source_session_id"),
        source_turn_id: row.get("source_turn_id"),
        status: row.get("status"),
        created_at: row.get("created_at"),
        updated_at: row.get("updated_at"),
    })
}

fn row_to_audit_event(row: sqlx::sqlite::SqliteRow) -> sqlx::Result<AuditEventResponse> {
    let payload_json: String = row.get("payload_json");
    let payload = serde_json::from_str(&payload_json)
        .map_err(|error| sqlx::Error::Decode(Box::new(error)))?;
    Ok(AuditEventResponse {
        id: row.get("id"),
        actor: row.get("actor"),
        action: row.get("action"),
        memory_id: row.get("memory_id"),
        candidate_id: row.get("candidate_id"),
        change_request_id: row.get("change_request_id"),
        memory_text: row.get("memory_text"),
        candidate_text: row.get("candidate_text"),
        change_request_text: row.get("change_request_text"),
        payload,
        created_at: row.get("created_at"),
    })
}

fn row_to_candidate(row: sqlx::sqlite::SqliteRow) -> sqlx::Result<MemoryCandidateResponse> {
    let kind: String = row.get("kind");
    let instruction_scopes = row
        .get::<Option<String>, _>("instruction_scopes_json")
        .and_then(|json| serde_json::from_str::<Vec<String>>(&json).ok())
        .map(clean_instruction_scopes)
        .unwrap_or_default();
    let episode = row
        .get::<Option<String>, _>("episode_json")
        .and_then(|json| serde_json::from_str::<TaskEpisodeData>(&json).ok());
    Ok(MemoryCandidateResponse {
        id: row.get("id"),
        kind: serde_json::from_value(serde_json::Value::String(kind))
            .map_err(|error| sqlx::Error::Decode(Box::new(error)))?,
        source: row.get("source"),
        scope: row.get("scope"),
        text: row.get("text"),
        confidence: row.get("confidence"),
        reason: row.get("reason"),
        instruction_scopes,
        episode,
        status: row.get("status"),
    })
}

fn clean_instruction_scopes(scopes: Vec<String>) -> Vec<String> {
    let mut cleaned = Vec::new();
    for scope in scopes {
        let trimmed = scope.trim();
        if !matches!(trimmed, "global" | "workspace" | "repo") {
            continue;
        }
        if cleaned.iter().any(|existing| existing == trimmed) {
            continue;
        }
        cleaned.push(trimmed.to_string());
    }
    cleaned
}

fn row_to_change_request(
    row: sqlx::sqlite::SqliteRow,
) -> sqlx::Result<MemoryChangeRequestResponse> {
    let proposed_kind = row
        .get::<Option<String>, _>("proposed_kind")
        .map(kind_from_wire)
        .transpose()?;
    Ok(MemoryChangeRequestResponse {
        id: row.get("id"),
        action: row.get("action"),
        source: row.get("source"),
        target_memory_ids: change_request_target_ids(
            row.get("target_memory_id"),
            row.get("target_memory_ids_json"),
        )?,
        target_memory_text: row.get("target_memory_text"),
        proposed_kind,
        proposed_scope: row.get("proposed_scope"),
        proposed_text: row.get("proposed_text"),
        reason: row.get("reason"),
        confidence: row.get("confidence"),
        status: row.get("status"),
        created_at: row.get("created_at"),
        reviewed_at: row.get("reviewed_at"),
    })
}

fn kind_to_wire(kind: MemoryKind) -> &'static str {
    match kind {
        MemoryKind::UserPreference => "user_preference",
        MemoryKind::ProjectRule => "project_rule",
        MemoryKind::ArchitectureDecision => "architecture_decision",
        MemoryKind::SessionSummary => "session_summary",
        MemoryKind::TaskEpisode => "task_episode",
    }
}

fn kind_from_wire(kind: String) -> sqlx::Result<MemoryKind> {
    serde_json::from_value(serde_json::Value::String(kind))
        .map_err(|error| sqlx::Error::Decode(Box::new(error)))
}

fn change_request_target_ids(
    target_memory_id: Option<String>,
    target_memory_ids_json: Option<String>,
) -> sqlx::Result<Vec<String>> {
    if let Some(json) = target_memory_ids_json.filter(|value| !value.trim().is_empty()) {
        let ids =
            serde_json::from_str(&json).map_err(|error| sqlx::Error::Decode(Box::new(error)))?;
        return Ok(ids);
    }
    Ok(target_memory_id.into_iter().collect())
}

fn maintenance_similarity(
    left: &MemoryResponse,
    right: &MemoryResponse,
    entities_by_memory: &HashMap<String, Vec<MemoryEntity>>,
) -> f32 {
    if left.kind != right.kind || left.scope != right.scope {
        return 0.0;
    }
    maintenance_text_similarity(left, right).max(maintenance_entity_similarity(
        left,
        right,
        entities_by_memory,
    ))
}

fn maintenance_text_similarity(left: &MemoryResponse, right: &MemoryResponse) -> f32 {
    let left_tokens = maintenance_tokens(&left.text);
    let right_tokens = maintenance_tokens(&right.text);
    if left_tokens.is_empty() || right_tokens.is_empty() {
        return 0.0;
    }
    let overlap = left_tokens.intersection(&right_tokens).count();
    if overlap == 0 {
        return 0.0;
    }
    if left_tokens
        .intersection(&right_tokens)
        .any(|token| token.chars().count() >= 5)
    {
        return 0.93;
    }
    let union = left_tokens.union(&right_tokens).count();
    if union == 0 {
        return 0.0;
    }
    (overlap as f32 / union as f32).min(0.89)
}

fn maintenance_entity_similarity(
    left: &MemoryResponse,
    right: &MemoryResponse,
    entities_by_memory: &HashMap<String, Vec<MemoryEntity>>,
) -> f32 {
    if let Some(confidence) =
        maintenance_strong_identifier_similarity(left, right, entities_by_memory)
    {
        return confidence;
    }
    let left_entities = maintenance_entity_terms(entities_by_memory.get(&left.id));
    let right_entities = maintenance_entity_terms(entities_by_memory.get(&right.id));
    if left_entities.is_empty() || right_entities.is_empty() {
        return 0.0;
    }
    let overlap = left_entities.intersection(&right_entities).count();
    if overlap == 0 {
        return 0.0;
    }
    let comparable = left_entities.len().min(right_entities.len()).max(1);
    let overlap_ratio = overlap as f32 / comparable as f32;
    (0.78 + overlap_ratio * 0.08).min(0.89)
}

fn maintenance_entity_terms(entities: Option<&Vec<MemoryEntity>>) -> HashSet<String> {
    entities
        .into_iter()
        .flat_map(|items| items.iter())
        .map(|entity| entity.normalized_text.trim().to_string())
        .filter(|value| value.chars().count() >= 3)
        .collect()
}

fn maintenance_strong_identifier_similarity(
    left: &MemoryResponse,
    right: &MemoryResponse,
    entities_by_memory: &HashMap<String, Vec<MemoryEntity>>,
) -> Option<f32> {
    if !matches!(
        left.kind,
        MemoryKind::ProjectRule | MemoryKind::ArchitectureDecision
    ) || !matches!(
        right.kind,
        MemoryKind::ProjectRule | MemoryKind::ArchitectureDecision
    ) {
        return None;
    }
    if !matches!(left.scope.as_str(), "repo" | "workspace") {
        return None;
    }
    if !looks_like_verification_memory(&left.text) || !looks_like_verification_memory(&right.text) {
        return None;
    }
    let left_entities = maintenance_identifier_entity_terms(entities_by_memory.get(&left.id));
    let right_entities = maintenance_identifier_entity_terms(entities_by_memory.get(&right.id));
    if left_entities.is_empty() || right_entities.is_empty() {
        return None;
    }
    if left_entities.intersection(&right_entities).next().is_some() {
        return Some(0.93);
    }
    None
}

fn maintenance_identifier_entity_terms(entities: Option<&Vec<MemoryEntity>>) -> HashSet<String> {
    entities
        .into_iter()
        .flat_map(|items| items.iter())
        .filter(|entity| {
            let entity_type = entity.entity_type.to_ascii_lowercase();
            entity_type == "identifier" || entity_type.contains("identifier")
        })
        .map(|entity| entity.normalized_text.trim().to_string())
        .filter(|value| value.chars().count() >= 3)
        .collect()
}

fn looks_like_verification_memory(text: &str) -> bool {
    let normalized = text.to_lowercase();
    let compact = normalized.split_whitespace().collect::<String>();
    [
        "verification",
        "passphrase",
        "secret phrase",
        "release phrase",
        "验证暗号",
        "验证口令",
        "验证短语",
        "暗号",
        "口令",
    ]
    .iter()
    .any(|marker| normalized.contains(marker) || compact.contains(marker))
}

fn maintenance_supersede_proposal(
    left: &MemoryResponse,
    right: &MemoryResponse,
    confidence: f32,
) -> Option<MaintenanceProposal> {
    if left.kind != right.kind || left.scope != right.scope {
        return None;
    }
    if !is_profile_layer_kind(left.kind, &left.scope) {
        return None;
    }
    let (newer, older) = if left.updated_at >= right.updated_at {
        (left, right)
    } else {
        (right, left)
    };
    if normalize_duplicate_text(&newer.text) == normalize_duplicate_text(&older.text) {
        return None;
    }
    if !memory_texts_conflict_for_auto_supersede(&older.text, &newer.text) {
        return None;
    }
    Some(MaintenanceProposal {
        action: "supersede".to_string(),
        target_memory_ids: vec![older.id.clone(), newer.id.clone()],
        proposed_kind: newer.kind,
        proposed_scope: newer.scope.clone(),
        proposed_text: Some(newer.text.clone()),
        reason: Some(
            "A newer same-topic profile memory supersedes an older conflicting memory.".to_string(),
        ),
        confidence,
    })
}

fn should_pin_candidate(
    kind: MemoryKind,
    scope: &str,
    confidence: Option<f32>,
    explicitly_pinned: bool,
) -> bool {
    if kind == MemoryKind::TaskEpisode {
        return false;
    }
    if explicitly_pinned {
        return true;
    }
    if confidence.unwrap_or(0.0) < PROFILE_AUTO_CONFIDENCE_THRESHOLD {
        return false;
    }
    is_profile_layer_kind(kind, scope)
}

fn is_profile_layer_kind(kind: MemoryKind, scope: &str) -> bool {
    is_profile_layer_kind_wire(kind_to_wire(kind), scope)
}

fn is_profile_layer_kind_wire(kind: &str, scope: &str) -> bool {
    matches!(
        (kind, scope),
        ("user_preference", "global")
            | ("project_rule", "workspace")
            | ("project_rule", "repo")
            | ("architecture_decision", "workspace")
            | ("architecture_decision", "repo")
    )
}

fn maintenance_tokens(text: &str) -> HashSet<String> {
    let stopwords = [
        "about",
        "answer",
        "answers",
        "called",
        "goes",
        "into",
        "prefers",
        "replies",
        "reply",
        "response",
        "responses",
        "that",
        "this",
        "user",
        "with",
    ];
    query_tokens(text)
        .into_iter()
        .filter(|token| token.chars().count() >= 3)
        .filter(|token| !stopwords.contains(&token.as_str()))
        .collect()
}

fn merged_memory_text(left: &MemoryResponse, right: &MemoryResponse) -> String {
    if left.text.chars().count() <= right.text.chars().count() {
        left.text.clone()
    } else {
        right.text.clone()
    }
}

fn stable_text_hash(text: &str) -> String {
    let mut hash = 0xcbf29ce484222325_u64;
    for byte in text.as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x100000001b3);
    }
    format!("fnv1a64:{hash:016x}")
}

fn query_tokens(query: &str) -> Vec<String> {
    let mut tokens = Vec::new();
    let mut seen = HashSet::new();
    for chunk in query
        .split(|character: char| !character.is_alphanumeric())
        .map(str::trim)
        .filter(|token| !token.is_empty())
    {
        let mut latin_or_digit_run = String::new();
        let mut cjk_run = String::new();
        for character in chunk.chars() {
            if is_cjk_character(character) {
                push_query_token(&mut tokens, &mut seen, &latin_or_digit_run);
                latin_or_digit_run.clear();
                cjk_run.push(character);
            } else {
                push_cjk_query_tokens(&mut tokens, &mut seen, &cjk_run);
                cjk_run.clear();
                latin_or_digit_run.push(character);
            }
        }
        push_query_token(&mut tokens, &mut seen, &latin_or_digit_run);
        push_cjk_query_tokens(&mut tokens, &mut seen, &cjk_run);
    }
    tokens
}

fn push_query_token(tokens: &mut Vec<String>, seen: &mut HashSet<String>, value: &str) {
    let token = value.trim().to_lowercase();
    if token.chars().count() < 2 || !seen.insert(token.clone()) {
        return;
    }
    tokens.push(token);
}

fn push_cjk_query_tokens(tokens: &mut Vec<String>, seen: &mut HashSet<String>, value: &str) {
    let characters = value.chars().collect::<Vec<_>>();
    if characters.len() < 2 {
        return;
    }
    if characters.len() == 2 {
        push_query_token(tokens, seen, value);
        return;
    }
    for window in characters.windows(2) {
        let token = window.iter().collect::<String>();
        push_query_token(tokens, seen, &token);
    }
}

fn is_cjk_character(character: char) -> bool {
    matches!(
        character as u32,
        0x3400..=0x4dbf | 0x4e00..=0x9fff | 0xf900..=0xfaff
    )
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

fn query_entity_terms(query: &str, tokens: &[String]) -> HashSet<String> {
    let mut terms = tokens
        .iter()
        .map(|token| normalize_entity(token))
        .filter(|token| !token.is_empty())
        .collect::<HashSet<_>>();
    let normalized_query = normalize_entity(query);
    if !normalized_query.is_empty() {
        terms.insert(normalized_query);
    }
    terms
}

fn entity_score(entities: &[MemoryEntity], query_terms: &HashSet<String>) -> f32 {
    if entities.is_empty() || query_terms.is_empty() {
        return 0.0;
    }
    let matches = entities
        .iter()
        .filter(|entity| {
            query_terms.contains(&entity.normalized_text)
                || query_terms
                    .iter()
                    .any(|term| term.contains(&entity.normalized_text))
        })
        .count();
    if matches == 0 {
        return 0.0;
    }
    (matches as f32 / entities.len() as f32).max(0.85)
}

fn normalize_entity(value: &str) -> String {
    value
        .chars()
        .filter(|character| character.is_alphanumeric())
        .flat_map(char::to_lowercase)
        .collect()
}

#[allow(clippy::too_many_arguments)]
fn scope_score(
    scope: &str,
    item_repo_id: Option<&str>,
    item_workspace_id: Option<&str>,
    item_agent_id: Option<&str>,
    item_session_id: Option<&str>,
    query_repo_id: Option<&str>,
    query_workspace_id: Option<&str>,
    query_agent_id: Option<&str>,
    query_session_id: Option<&str>,
) -> f32 {
    if scope == "session"
        && item_session_id.is_some()
        && item_workspace_id == query_workspace_id
        && item_repo_id == query_repo_id
        && item_agent_id == query_agent_id
        && item_session_id == query_session_id
    {
        return 1.0;
    }
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
