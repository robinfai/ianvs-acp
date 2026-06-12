use crate::embedding::embedder::Embedder;
use crate::memory::types::{MemoryKind, MemoryScope};
use crate::memory::{ranker, redactor};
use chrono::Utc;
use serde::{Deserialize, Serialize};
use sqlx::{Row, SqlitePool};
use std::collections::{HashMap, HashSet};
use uuid::Uuid;

const MIN_VECTOR_ONLY_SCORE: f32 = 0.5;

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

#[derive(Debug, Clone, Serialize)]
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

#[derive(Debug, Serialize)]
pub struct ListAuditResponse {
    pub items: Vec<MemoryAuditResponse>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MemoryAuditResponse {
    pub id: String,
    pub actor: String,
    pub action: String,
    pub memory_id: Option<String>,
    pub candidate_id: Option<String>,
    pub change_request_id: Option<String>,
    pub payload: serde_json::Value,
    pub created_at: i64,
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
    pub auto_approve_threshold: Option<f32>,
    #[serde(default)]
    pub pre_extracted_candidates: Vec<PreExtractedCandidate>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ExtractCandidatesResponse {
    pub candidates: Vec<MemoryCandidateResponse>,
    pub approved_memories: Vec<MemoryResponse>,
}

#[derive(Debug, Serialize)]
pub struct ListCandidatesResponse {
    pub items: Vec<MemoryCandidateResponse>,
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
    pub created_at: i64,
    pub reviewed_at: Option<i64>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CreateChangeRequestRequest {
    pub scope: MemoryScope,
    pub action: String,
    pub source: Option<String>,
    pub target_memory_id: Option<String>,
    #[serde(default)]
    pub target_memory_ids: Vec<String>,
    pub proposed_kind: Option<MemoryKind>,
    pub proposed_scope: Option<String>,
    pub proposed_text: Option<String>,
    pub reason: Option<String>,
    pub confidence: Option<f32>,
}

#[derive(Debug, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct ApproveChangeRequestRequest {
    pub proposed_kind: Option<MemoryKind>,
    pub proposed_scope: Option<String>,
    pub proposed_text: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct ListChangeRequestsResponse {
    pub items: Vec<MemoryChangeRequestResponse>,
}

#[derive(Debug, Serialize)]
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
    pub scope: MemoryScope,
    pub enabled: Option<bool>,
    pub mode: Option<String>,
    pub cost_mode: Option<String>,
    pub high_confidence_threshold: Option<f32>,
    pub review_threshold: Option<f32>,
    pub max_items_per_batch: Option<i64>,
    pub manual_only_actions: Option<Vec<String>>,
    #[serde(default)]
    pub pre_extracted_change_requests: Vec<PreExtractedMaintenanceChangeRequest>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PreExtractedMaintenanceChangeRequest {
    pub action: String,
    pub source: Option<String>,
    #[serde(default)]
    pub target_memory_ids: Vec<String>,
    pub proposed_kind: Option<MemoryKind>,
    pub proposed_scope: Option<String>,
    pub proposed_text: Option<String>,
    pub confidence: Option<f32>,
    pub reason: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MaintenanceRunResponse {
    pub auto_applied: i64,
    pub needs_review: i64,
    pub skipped: i64,
    pub change_requests: Vec<MemoryChangeRequestResponse>,
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
        serde_json::json!({
            "source": "manual",
            "kind": kind,
            "scope": request.scope,
            "text": text
        }),
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

pub async fn list_visible_memory(
    pool: &SqlitePool,
    scope: &MemoryScope,
    status: Option<&str>,
) -> sqlx::Result<ListMemoryResponse> {
    let status = status.unwrap_or("%");
    let rows = sqlx::query(
        "select id, kind, scope, text, user_id, workspace_id, repo_id, agent_id, session_id, source, status, created_at, updated_at
         from memory_items
         where status like ?
           and user_id = ?
           and (
             scope = 'global'
             or (scope = 'workspace' and workspace_id = ?)
             or (scope = 'repo' and repo_id = ?)
             or (
               scope = 'session'
               and workspace_id is ?
               and repo_id is ?
               and agent_id is ?
               and session_id is ?
             )
           )
         order by updated_at desc",
    )
    .bind(status)
    .bind(&scope.user_id)
    .bind(&scope.workspace_id)
    .bind(&scope.repo_id)
    .bind(&scope.workspace_id)
    .bind(&scope.repo_id)
    .bind(&scope.agent_id)
    .bind(&scope.session_id)
    .fetch_all(pool)
    .await?;

    let items = rows
        .into_iter()
        .map(row_to_memory)
        .collect::<sqlx::Result<Vec<_>>>()?;
    Ok(ListMemoryResponse { items })
}

pub async fn list_audit(pool: &SqlitePool, limit: Option<i64>) -> sqlx::Result<ListAuditResponse> {
    let limit = limit.unwrap_or(100).clamp(1, 500);
    let rows = sqlx::query(
        "select id, actor, action, memory_id, candidate_id, change_request_id, payload_json, created_at
         from memory_audit_log
         order by created_at desc
         limit ?",
    )
    .bind(limit)
    .fetch_all(pool)
    .await?;
    Ok(ListAuditResponse {
        items: rows
            .into_iter()
            .map(row_to_audit)
            .collect::<sqlx::Result<Vec<_>>>()?,
    })
}

pub async fn list_visible_audit(
    pool: &SqlitePool,
    scope: &MemoryScope,
    limit: Option<i64>,
) -> sqlx::Result<ListAuditResponse> {
    let limit = limit.unwrap_or(100).clamp(1, 500);
    let rows = sqlx::query(
        "select a.id, a.actor, a.action, a.memory_id, a.candidate_id, a.change_request_id,
                a.payload_json, a.created_at
         from memory_audit_log a
         left join memory_items m on m.id = a.memory_id
         left join memory_candidates c on c.id = a.candidate_id
         left join memory_change_requests cr on cr.id = a.change_request_id
         left join memory_items crm on crm.id = cr.target_memory_id
         where (
           (
             m.id is not null
             and m.user_id = ?
             and (
               m.scope = 'global'
               or (m.scope = 'workspace' and m.workspace_id = ?)
               or (m.scope = 'repo' and m.repo_id = ?)
               or (
                 m.scope = 'session'
                 and m.workspace_id is ?
                 and m.repo_id is ?
                 and m.agent_id is ?
                 and m.session_id is ?
               )
             )
           )
           or (
             c.id is not null
             and c.user_id = ?
             and (
               c.scope = 'global'
               or (c.scope = 'workspace' and c.workspace_id = ?)
               or (c.scope = 'repo' and c.repo_id = ?)
               or (
                 c.scope = 'session'
                 and c.workspace_id is ?
                 and c.repo_id is ?
                 and c.agent_id is ?
                 and c.session_id is ?
               )
             )
           )
           or (
             cr.id is not null
             and cr.user_id = ?
             and (
               coalesce(cr.proposed_scope, crm.scope) = 'global'
               or (
                 coalesce(cr.proposed_scope, crm.scope) = 'workspace'
                 and case when cr.proposed_scope is null then crm.workspace_id else cr.workspace_id end = ?
               )
               or (
                 coalesce(cr.proposed_scope, crm.scope) = 'repo'
                 and case when cr.proposed_scope is null then crm.repo_id else cr.repo_id end = ?
               )
               or (
                 coalesce(cr.proposed_scope, crm.scope) = 'session'
                 and case when cr.proposed_scope is null then crm.workspace_id else cr.workspace_id end is ?
                 and case when cr.proposed_scope is null then crm.repo_id else cr.repo_id end is ?
                 and case when cr.proposed_scope is null then crm.agent_id else cr.agent_id end is ?
                 and case when cr.proposed_scope is null then crm.session_id else cr.session_id end is ?
               )
             )
           )
           or (
             a.memory_id is null
             and a.candidate_id is null
             and a.change_request_id is null
             and json_extract(a.payload_json, '$.scope.workspaceId') is ?
             and json_extract(a.payload_json, '$.scope.repoId') is ?
             and json_extract(a.payload_json, '$.scope.agentId') is ?
             and json_extract(a.payload_json, '$.scope.sessionId') is ?
           )
         )
         order by a.created_at desc
         limit ?",
    )
    .bind(&scope.user_id)
    .bind(&scope.workspace_id)
    .bind(&scope.repo_id)
    .bind(&scope.workspace_id)
    .bind(&scope.repo_id)
    .bind(&scope.agent_id)
    .bind(&scope.session_id)
    .bind(&scope.user_id)
    .bind(&scope.workspace_id)
    .bind(&scope.repo_id)
    .bind(&scope.workspace_id)
    .bind(&scope.repo_id)
    .bind(&scope.agent_id)
    .bind(&scope.session_id)
    .bind(&scope.user_id)
    .bind(&scope.workspace_id)
    .bind(&scope.repo_id)
    .bind(&scope.workspace_id)
    .bind(&scope.repo_id)
    .bind(&scope.agent_id)
    .bind(&scope.session_id)
    .bind(&scope.workspace_id)
    .bind(&scope.repo_id)
    .bind(&scope.agent_id)
    .bind(&scope.session_id)
    .bind(limit)
    .fetch_all(pool)
    .await?;
    Ok(ListAuditResponse {
        items: rows
            .into_iter()
            .map(row_to_audit)
            .collect::<sqlx::Result<Vec<_>>>()?,
    })
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
    .bind(&scope)
    .bind(&text)
    .bind(&status)
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
        serde_json::json!({
            "kind": kind,
            "scope": scope,
            "text": text,
            "status": status
        }),
    )
    .await?;
    get_memory(pool, id).await
}

pub async fn soft_delete_memory(pool: &SqlitePool, id: &str) -> sqlx::Result<()> {
    let current = get_memory(pool, id).await?;
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
        serde_json::json!({"soft": true, "text": current.text}),
    )
    .await
}

pub async fn create_candidates(
    pool: &SqlitePool,
    request: ExtractCandidatesRequest,
) -> sqlx::Result<ExtractCandidatesResponse> {
    let mut accepted = Vec::new();
    let mut approved_memories = Vec::new();
    let now = Utc::now().timestamp_millis();
    for candidate in request.pre_extracted_candidates {
        if !crate::memory::policy::accepts_candidate(&candidate.text, candidate.confidence) {
            continue;
        }

        let candidate_kind = candidate.kind;
        let candidate_scope = candidate.scope;
        let candidate_text = candidate.text;
        let candidate_reason = candidate.reason;
        let candidate_confidence = candidate.confidence;
        if let Some(source) = candidate_duplicate_source(
            pool,
            &request.scope,
            candidate_kind,
            &candidate_scope,
            &candidate_text,
        )
        .await?
        {
            write_audit(
                pool,
                "extractor",
                "candidate.skip_duplicate",
                None,
                None,
                None,
                serde_json::json!({
                    "kind": kind_to_wire(candidate_kind),
                    "scope": candidate_scope,
                    "source": source
                }),
            )
            .await?;
            continue;
        }

        if let Some(threshold) = request.auto_approve_threshold {
            let threshold = threshold.clamp(0.0, 1.0);
            let Some(confidence) =
                candidate_confidence.map(|confidence| confidence.clamp(0.0, 1.0))
            else {
                write_audit(
                    pool,
                    "extractor",
                    "candidate.skip_below_auto_threshold",
                    None,
                    None,
                    None,
                    serde_json::json!({
                        "kind": kind_to_wire(candidate_kind),
                        "scope": candidate_scope,
                        "confidence": candidate_confidence,
                        "threshold": threshold
                    }),
                )
                .await?;
                continue;
            };
            if confidence < threshold {
                write_audit(
                    pool,
                    "extractor",
                    "candidate.skip_below_auto_threshold",
                    None,
                    None,
                    None,
                    serde_json::json!({
                        "kind": kind_to_wire(candidate_kind),
                        "scope": candidate_scope,
                        "confidence": candidate_confidence,
                        "threshold": threshold
                    }),
                )
                .await?;
                continue;
            }
        }

        let id = format!("cand_{}", Uuid::new_v4());
        let kind = kind_to_wire(candidate_kind);
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
        .bind(&candidate_scope)
        .bind(&candidate_text)
        .bind(&candidate_reason)
        .bind(candidate_confidence)
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
            serde_json::json!({
                "kind": kind,
                "scope": &candidate_scope,
                "text": &candidate_text,
                "reason": &candidate_reason,
                "confidence": candidate_confidence
            }),
        )
        .await?;
        let should_auto_approve = request
            .auto_approve_threshold
            .map(|threshold| {
                candidate_confidence.is_some_and(|confidence| {
                    confidence.clamp(0.0, 1.0) >= threshold.clamp(0.0, 1.0)
                })
            })
            .unwrap_or(false);
        let (status, reviewed_at) = if should_auto_approve {
            let approved = approve_candidate_with_audit(
                pool,
                &id,
                ApproveCandidateRequest {
                    kind: candidate_kind,
                    scope: candidate_scope.clone(),
                    text: candidate_text.clone(),
                },
                "system",
                "candidate.auto_approve",
            )
            .await?;
            let reviewed_at = approved.updated_at;
            approved_memories.push(approved);
            ("approved".to_string(), Some(reviewed_at))
        } else {
            ("pending".to_string(), None)
        };
        accepted.push(MemoryCandidateResponse {
            id,
            kind: candidate_kind,
            scope: candidate_scope,
            text: candidate_text,
            confidence: candidate_confidence,
            reason: candidate_reason,
            status,
            created_at: now,
            reviewed_at,
        });
    }
    if !approved_memories.is_empty() {
        run_post_approval_maintenance(pool, &request.scope).await?;
    }

    Ok(ExtractCandidatesResponse {
        candidates: accepted,
        approved_memories,
    })
}

async fn run_post_approval_maintenance(pool: &SqlitePool, scope: &MemoryScope) -> sqlx::Result<()> {
    let _ = run_maintenance(
        pool,
        MaintenanceRunRequest {
            scope: scope.clone(),
            enabled: Some(true),
            mode: Some("high_confidence_auto".to_string()),
            cost_mode: Some("low_cost".to_string()),
            high_confidence_threshold: Some(0.90),
            review_threshold: Some(0.90),
            max_items_per_batch: Some(50),
            manual_only_actions: Some(default_manual_cleanup_actions()),
            pre_extracted_change_requests: Vec::new(),
        },
    )
    .await?;
    Ok(())
}

pub async fn list_candidates(
    pool: &SqlitePool,
    user_id: Option<&str>,
    repo_id: Option<&str>,
    status: Option<&str>,
) -> sqlx::Result<ListCandidatesResponse> {
    let user_id = user_id.unwrap_or("%");
    let repo_id = repo_id.unwrap_or("%");
    let status = status.unwrap_or("%");
    let rows = sqlx::query(
        "select id, kind, scope, text, reason, confidence, status, created_at, reviewed_at
         from memory_candidates
         where user_id like ? and coalesce(repo_id, '') like ? and status like ?
         order by created_at desc",
    )
    .bind(user_id)
    .bind(repo_id)
    .bind(status)
    .fetch_all(pool)
    .await?;
    Ok(ListCandidatesResponse {
        items: rows
            .into_iter()
            .map(row_to_candidate)
            .collect::<sqlx::Result<Vec<_>>>()?,
    })
}

pub async fn list_visible_candidates(
    pool: &SqlitePool,
    scope: &MemoryScope,
    status: Option<&str>,
) -> sqlx::Result<ListCandidatesResponse> {
    let status = status.unwrap_or("%");
    let rows = sqlx::query(
        "select id, kind, scope, text, reason, confidence, status, created_at, reviewed_at
         from memory_candidates
         where status like ?
           and user_id = ?
           and (
             scope = 'global'
             or (scope = 'workspace' and workspace_id = ?)
             or (scope = 'repo' and repo_id = ?)
             or (
               scope = 'session'
               and workspace_id is ?
               and repo_id is ?
               and agent_id is ?
               and session_id is ?
             )
           )
         order by created_at desc",
    )
    .bind(status)
    .bind(&scope.user_id)
    .bind(&scope.workspace_id)
    .bind(&scope.repo_id)
    .bind(&scope.workspace_id)
    .bind(&scope.repo_id)
    .bind(&scope.agent_id)
    .bind(&scope.session_id)
    .fetch_all(pool)
    .await?;
    Ok(ListCandidatesResponse {
        items: rows
            .into_iter()
            .map(row_to_candidate)
            .collect::<sqlx::Result<Vec<_>>>()?,
    })
}

pub async fn approve_candidate(
    pool: &SqlitePool,
    candidate_id: &str,
    request: ApproveCandidateRequest,
) -> sqlx::Result<MemoryResponse> {
    let item =
        approve_candidate_with_audit(pool, candidate_id, request, "user", "candidate.approve")
            .await?;
    let scope = MemoryScope {
        user_id: item.user_id.clone(),
        workspace_id: item.workspace_id.clone(),
        repo_id: item.repo_id.clone(),
        agent_id: item.agent_id.clone(),
        session_id: item.session_id.clone(),
    };
    run_post_approval_maintenance(pool, &scope).await?;
    Ok(item)
}

async fn approve_candidate_with_audit(
    pool: &SqlitePool,
    candidate_id: &str,
    request: ApproveCandidateRequest,
    actor: &str,
    audit_action: &str,
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
        actor,
        audit_action,
        Some(&item.id),
        Some(candidate_id),
        None,
        serde_json::json!({
            "kind": kind_to_wire(item.kind),
            "scope": &item.scope,
            "text": &item.text
        }),
    )
    .await?;
    Ok(item)
}

pub async fn reject_candidate(
    pool: &SqlitePool,
    candidate_id: &str,
) -> sqlx::Result<MemoryCandidateResponse> {
    let now = Utc::now().timestamp_millis();
    let result = sqlx::query(
        "update memory_candidates set status = 'rejected', reviewed_at = ? where id = ? and status = 'pending'",
    )
    .bind(now)
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
    get_candidate(pool, candidate_id).await
}

pub async fn create_change_request(
    pool: &SqlitePool,
    request: CreateChangeRequestRequest,
) -> sqlx::Result<MemoryChangeRequestResponse> {
    let now = Utc::now().timestamp_millis();
    let id = format!("cr_{}", Uuid::new_v4());
    let action = normalize_change_action(&request.action);
    let source = request
        .source
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or("user")
        .to_string();
    let target_memory_ids = normalize_target_memory_ids(
        request.target_memory_id.as_deref(),
        &request.target_memory_ids,
    );
    let target_memory_id = target_memory_ids.first().cloned();
    let target_memory_ids_json = serde_json::to_string(&target_memory_ids)
        .map_err(|error| sqlx::Error::Decode(Box::new(error)))?;
    let proposed_kind = request.proposed_kind.map(kind_to_wire);
    let proposed_scope = normalize_change_request_proposed_scope(
        pool,
        &action,
        &target_memory_ids,
        clean_optional_text(request.proposed_scope.as_deref()),
    )
    .await?;
    let proposed_text =
        clean_optional_text(request.proposed_text.as_deref()).map(|text| redactor::redact(&text));
    sqlx::query(
        "insert into memory_change_requests
        (id, user_id, workspace_id, repo_id, agent_id, session_id, action, source,
         target_memory_id, target_memory_ids_json, proposed_kind, proposed_scope, proposed_text,
         reason, confidence, status, created_at)
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
            "proposedText": proposed_text,
            "confidence": request.confidence
        }),
    )
    .await?;
    get_change_request(pool, &id).await
}

pub async fn list_change_requests(
    pool: &SqlitePool,
    user_id: Option<&str>,
    repo_id: Option<&str>,
    status: Option<&str>,
) -> sqlx::Result<ListChangeRequestsResponse> {
    let user_id = user_id.unwrap_or("%");
    let repo_id = repo_id.unwrap_or("%");
    let status = status.unwrap_or("%");
    let rows = sqlx::query(
        "select cr.id, cr.action, cr.source, cr.target_memory_id, cr.target_memory_ids_json,
                cr.proposed_kind, cr.proposed_scope, cr.proposed_text, cr.reason, cr.confidence,
                cr.status, cr.created_at, cr.reviewed_at, m.text as target_memory_text
         from memory_change_requests cr
         left join memory_items m on m.id = cr.target_memory_id
         where cr.user_id like ? and coalesce(cr.repo_id, '') like ? and cr.status like ?
         order by cr.created_at desc",
    )
    .bind(user_id)
    .bind(repo_id)
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

pub async fn list_visible_change_requests(
    pool: &SqlitePool,
    scope: &MemoryScope,
    status: Option<&str>,
) -> sqlx::Result<ListChangeRequestsResponse> {
    let status = status.unwrap_or("%");
    let rows = sqlx::query(
        "select cr.id, cr.action, cr.source, cr.target_memory_id, cr.target_memory_ids_json,
                cr.proposed_kind, cr.proposed_scope, cr.proposed_text, cr.reason, cr.confidence,
                cr.status, cr.created_at, cr.reviewed_at, m.text as target_memory_text
         from memory_change_requests cr
         left join memory_items m on m.id = cr.target_memory_id
         where cr.status like ?
           and cr.user_id = ?
           and (
             coalesce(cr.proposed_scope, m.scope) = 'global'
             or (
               coalesce(cr.proposed_scope, m.scope) = 'workspace'
               and case when cr.proposed_scope is null then m.workspace_id else cr.workspace_id end = ?
             )
             or (
               coalesce(cr.proposed_scope, m.scope) = 'repo'
               and case when cr.proposed_scope is null then m.repo_id else cr.repo_id end = ?
             )
             or (
               coalesce(cr.proposed_scope, m.scope) = 'session'
               and case when cr.proposed_scope is null then m.workspace_id else cr.workspace_id end is ?
               and case when cr.proposed_scope is null then m.repo_id else cr.repo_id end is ?
               and case when cr.proposed_scope is null then m.agent_id else cr.agent_id end is ?
               and case when cr.proposed_scope is null then m.session_id else cr.session_id end is ?
             )
           )
         order by cr.created_at desc",
    )
    .bind(status)
    .bind(&scope.user_id)
    .bind(&scope.workspace_id)
    .bind(&scope.repo_id)
    .bind(&scope.workspace_id)
    .bind(&scope.repo_id)
    .bind(&scope.agent_id)
    .bind(&scope.session_id)
    .fetch_all(pool)
    .await?;
    Ok(ListChangeRequestsResponse {
        items: rows
            .into_iter()
            .map(row_to_change_request)
            .collect::<sqlx::Result<Vec<_>>>()?,
    })
}

pub async fn approve_change_request(
    pool: &SqlitePool,
    id: &str,
    request: ApproveChangeRequestRequest,
) -> sqlx::Result<MemoryChangeRequestResponse> {
    let (approved, followup_scope) = match approve_change_request_inner(pool, id, request).await {
        Ok(result) => result,
        Err(sqlx::Error::RowNotFound) => {
            let existing = get_change_request(pool, id).await?;
            if existing.status == "approved" {
                return Ok(existing);
            }
            return Err(sqlx::Error::RowNotFound);
        }
        Err(error) => return Err(error),
    };
    if let Some(scope) = followup_scope {
        run_post_approval_maintenance(pool, &scope).await?;
    }
    Ok(approved)
}

async fn approve_change_request_inner(
    pool: &SqlitePool,
    id: &str,
    request: ApproveChangeRequestRequest,
) -> sqlx::Result<(MemoryChangeRequestResponse, Option<MemoryScope>)> {
    let change_request = get_pending_change_request(pool, id).await?;
    let action = normalize_change_action(&change_request.action);
    let followup_scope = match first_change_request_target(&change_request) {
        Ok(target_id) => match get_memory(pool, target_id).await {
            Ok(memory) => Some(scope_from_memory(&memory)),
            Err(sqlx::Error::RowNotFound) => None,
            Err(error) => return Err(error),
        },
        Err(_) => None,
    };
    match action.as_str() {
        "update" | "summarize" => {
            let target_id = first_change_request_target(&change_request)?;
            let current = get_memory(pool, target_id).await?;
            let kind = request
                .proposed_kind
                .or(change_request.proposed_kind)
                .unwrap_or(current.kind);
            let current_scope = current.scope.clone();
            let scope = request
                .proposed_scope
                .or(change_request.proposed_scope.clone())
                .unwrap_or_else(|| current_scope.clone());
            let scope = directional_update_scope(&current_scope, scope);
            let text = request
                .proposed_text
                .or(change_request.proposed_text.clone())
                .unwrap_or(current.text);
            update_memory_from_change_request(
                pool,
                target_id,
                kind,
                scope,
                text,
                if action == "summarize" {
                    "memory.summarize"
                } else {
                    "memory.update"
                },
                id,
            )
            .await?;
        }
        "disable" | "expire" => {
            let audit_action = if action == "expire" {
                "memory.expire"
            } else {
                "memory.disable"
            };
            for target_id in &change_request.target_memory_ids {
                set_memory_status_from_change_request(
                    pool,
                    target_id,
                    "disabled",
                    audit_action,
                    id,
                )
                .await?;
            }
        }
        "delete" => {
            for target_id in &change_request.target_memory_ids {
                soft_delete_memory_from_change_request(pool, target_id, id).await?;
            }
        }
        "merge" => {
            merge_memory_from_change_request(pool, &change_request, request, id).await?;
        }
        _ => return Err(sqlx::Error::RowNotFound),
    }
    mark_change_request_reviewed(pool, id, "approved").await?;
    write_audit(
        pool,
        "user",
        "change_request.approve",
        None,
        None,
        Some(id),
        serde_json::json!({"action": action}),
    )
    .await?;
    let approved = get_change_request(pool, id).await?;
    Ok((approved, followup_scope))
}

pub async fn reject_change_request(
    pool: &SqlitePool,
    id: &str,
) -> sqlx::Result<MemoryChangeRequestResponse> {
    get_pending_change_request(pool, id).await?;
    mark_change_request_reviewed(pool, id, "rejected").await?;
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
) -> sqlx::Result<MaintenanceRunResponse> {
    let mode = request
        .mode
        .as_deref()
        .map(normalize_change_action)
        .unwrap_or_else(|| "high_confidence_auto".to_string());
    let mut response = MaintenanceRunResponse {
        auto_applied: 0,
        needs_review: 0,
        skipped: 0,
        change_requests: Vec::new(),
    };

    if !request.enabled.unwrap_or(true) || matches!(mode.as_str(), "disabled" | "off") {
        write_maintenance_run_audit(pool, &response, &mode).await?;
        return Ok(response);
    }

    let max_items = request.max_items_per_batch.unwrap_or(50).clamp(2, 50);
    let high_confidence_threshold = request
        .high_confidence_threshold
        .unwrap_or(0.90)
        .clamp(0.0, 1.0);
    let review_threshold = request.review_threshold.unwrap_or(0.75).clamp(0.0, 1.0);
    let manual_only_actions = request
        .manual_only_actions
        .map(manual_cleanup_actions)
        .unwrap_or_else(default_manual_cleanup_actions)
        .into_iter()
        .map(|action| normalize_change_action(&action))
        .collect::<Vec<_>>();

    let mut used_memory_ids = HashSet::new();
    let mut used_suggestion_keys = HashSet::new();
    for suggestion in &request.pre_extracted_change_requests {
        let action = normalize_change_action(&suggestion.action);
        let target_memory_ids = normalize_target_memory_ids(None, &suggestion.target_memory_ids);
        if !action.is_empty() && !target_memory_ids.is_empty() {
            let key = maintenance_suggestion_key(&action, &target_memory_ids)?;
            if !used_suggestion_keys.insert(key) {
                response.skipped += 1;
                continue;
            }
        }
        let change_request_count = response.change_requests.len();
        process_maintenance_suggestion(
            pool,
            &mut response,
            &request.scope,
            suggestion,
            &mode,
            high_confidence_threshold,
            review_threshold,
            &manual_only_actions,
        )
        .await?;
        if response.change_requests.len() > change_request_count {
            for id in target_memory_ids {
                used_memory_ids.insert(id);
            }
        }
    }

    let memories = list_maintenance_memory(pool, &request.scope, max_items).await?;

    for group in semantic_merge_groups(&memories, &used_memory_ids) {
        let target_memory_ids = group
            .iter()
            .map(|memory| memory.id.clone())
            .collect::<Vec<_>>();
        let suggestion = PreExtractedMaintenanceChangeRequest {
            action: "merge".to_string(),
            source: None,
            target_memory_ids,
            proposed_kind: Some(group[0].kind),
            proposed_scope: None,
            proposed_text: Some(shortest_memory_text(group.iter().map(|memory| memory.text.as_str()))),
            confidence: Some(0.93),
            reason: Some(
                "These memories describe the same user preference; merging keeps retrieval concise."
                    .to_string(),
            ),
        };
        let key = maintenance_suggestion_key("merge", &suggestion.target_memory_ids)?;
        if !used_suggestion_keys.insert(key) {
            response.skipped += 1;
            continue;
        }
        let change_request_count = response.change_requests.len();
        process_maintenance_suggestion(
            pool,
            &mut response,
            &request.scope,
            &suggestion,
            &mode,
            high_confidence_threshold,
            review_threshold,
            &manual_only_actions,
        )
        .await?;
        if response.change_requests.len() > change_request_count {
            for id in &suggestion.target_memory_ids {
                used_memory_ids.insert(id.clone());
            }
        }
    }

    for left_index in 0..memories.len() {
        let left = &memories[left_index];
        if used_memory_ids.contains(&left.id) {
            continue;
        }
        for right in memories.iter().skip(left_index + 1) {
            if used_memory_ids.contains(&right.id) {
                continue;
            }
            if let Some(cleanup) = disabled_cleanup_proposal(left, right) {
                if cleanup.confidence < review_threshold {
                    response.skipped += 1;
                    continue;
                }
                if mode == "high_confidence_auto" && cleanup.confidence < high_confidence_threshold
                {
                    response.skipped += 1;
                    continue;
                }
                let suggestion = PreExtractedMaintenanceChangeRequest {
                    action: "delete".to_string(),
                    source: None,
                    target_memory_ids: vec![cleanup.target_memory_id],
                    proposed_kind: None,
                    proposed_scope: None,
                    proposed_text: None,
                    confidence: Some(cleanup.confidence),
                    reason: Some(cleanup.reason),
                };
                let key = maintenance_suggestion_key("delete", &suggestion.target_memory_ids)?;
                if !used_suggestion_keys.insert(key) {
                    response.skipped += 1;
                    continue;
                }
                let change_request_count = response.change_requests.len();
                process_maintenance_suggestion(
                    pool,
                    &mut response,
                    &request.scope,
                    &suggestion,
                    &mode,
                    high_confidence_threshold,
                    review_threshold,
                    &manual_only_actions,
                )
                .await?;
                if response.change_requests.len() > change_request_count {
                    for id in &suggestion.target_memory_ids {
                        used_memory_ids.insert(id.clone());
                    }
                }
                if used_memory_ids.contains(&left.id) {
                    break;
                }
                continue;
            }

            let Some(proposal) = merge_proposal(left, right) else {
                continue;
            };
            if proposal.confidence < review_threshold {
                response.skipped += 1;
                continue;
            }
            let confidence = proposal.confidence;
            if mode == "high_confidence_auto" && confidence < high_confidence_threshold {
                response.skipped += 1;
                continue;
            }
            let suggestion = PreExtractedMaintenanceChangeRequest {
                action: "merge".to_string(),
                source: None,
                target_memory_ids: vec![left.id.clone(), right.id.clone()],
                proposed_kind: Some(left.kind),
                proposed_scope: Some(proposal.scope),
                proposed_text: Some(proposal.text),
                confidence: Some(confidence),
                reason: Some(proposal.reason),
            };
            let key = maintenance_suggestion_key("merge", &suggestion.target_memory_ids)?;
            if !used_suggestion_keys.insert(key) {
                response.skipped += 1;
                continue;
            }
            let change_request_count = response.change_requests.len();
            process_maintenance_suggestion(
                pool,
                &mut response,
                &request.scope,
                &suggestion,
                &mode,
                high_confidence_threshold,
                review_threshold,
                &manual_only_actions,
            )
            .await?;
            if response.change_requests.len() > change_request_count {
                for id in &suggestion.target_memory_ids {
                    used_memory_ids.insert(id.clone());
                }
            }
            break;
        }
    }

    write_maintenance_run_audit(pool, &response, &mode).await?;
    Ok(response)
}

async fn process_maintenance_suggestion(
    pool: &SqlitePool,
    response: &mut MaintenanceRunResponse,
    scope: &MemoryScope,
    suggestion: &PreExtractedMaintenanceChangeRequest,
    mode: &str,
    high_confidence_threshold: f32,
    review_threshold: f32,
    manual_only_actions: &[String],
) -> sqlx::Result<()> {
    let action = normalize_change_action(&suggestion.action);
    let target_memory_ids = normalize_target_memory_ids(None, &suggestion.target_memory_ids);
    if action.is_empty() || target_memory_ids.is_empty() {
        response.skipped += 1;
        return Ok(());
    }
    let Some(confidence) = suggestion
        .confidence
        .map(|confidence| confidence.clamp(0.0, 1.0))
    else {
        response.skipped += 1;
        return Ok(());
    };
    if confidence < review_threshold {
        response.skipped += 1;
        return Ok(());
    }
    if mode == "high_confidence_auto" && confidence < high_confidence_threshold {
        response.skipped += 1;
        return Ok(());
    }
    if maintenance_action_writes_memory_text(&action)
        && !suggestion
            .proposed_text
            .as_deref()
            .is_some_and(crate::memory::policy::accepts_memory_text)
    {
        response.skipped += 1;
        return Ok(());
    }
    if pending_change_request_exists(pool, &action, &target_memory_ids).await? {
        response.skipped += 1;
        return Ok(());
    }

    let change_request = create_change_request(
        pool,
        CreateChangeRequestRequest {
            scope: scope.clone(),
            action: action.clone(),
            source: Some(
                suggestion
                    .source
                    .as_deref()
                    .map(str::trim)
                    .filter(|value| !value.is_empty())
                    .unwrap_or("maintenance")
                    .to_string(),
            ),
            target_memory_id: None,
            target_memory_ids,
            proposed_kind: suggestion.proposed_kind,
            proposed_scope: suggestion.proposed_scope.clone(),
            proposed_text: suggestion.proposed_text.clone(),
            reason: suggestion.reason.clone(),
            confidence: Some(confidence),
        },
    )
    .await?;

    if should_auto_approve_maintenance(
        mode,
        &action,
        confidence,
        high_confidence_threshold,
        manual_only_actions,
    ) {
        let (approved, _) = approve_change_request_inner(
            pool,
            &change_request.id,
            ApproveChangeRequestRequest::default(),
        )
        .await?;
        write_audit(
            pool,
            "system",
            "maintenance.auto_approve",
            None,
            None,
            Some(&approved.id),
            serde_json::json!({"action": action, "confidence": confidence}),
        )
        .await?;
        response.auto_applied += 1;
        response.change_requests.push(approved);
    } else {
        response.needs_review += 1;
        response.change_requests.push(change_request);
    }
    Ok(())
}

async fn pending_change_request_exists(
    pool: &SqlitePool,
    action: &str,
    target_memory_ids: &[String],
) -> sqlx::Result<bool> {
    let mut target_memory_ids = target_memory_ids.to_vec();
    target_memory_ids.sort();
    let target_memory_ids_json = serde_json::to_string(&target_memory_ids)
        .map_err(|error| sqlx::Error::Decode(Box::new(error)))?;
    let count: i64 = sqlx::query_scalar(
        "select count(*)
         from memory_change_requests
         where action = ?
           and status = 'pending'
           and target_memory_ids_json = ?",
    )
    .bind(action)
    .bind(target_memory_ids_json)
    .fetch_one(pool)
    .await?;
    Ok(count > 0)
}

fn maintenance_suggestion_key(action: &str, target_memory_ids: &[String]) -> sqlx::Result<String> {
    let mut target_memory_ids = target_memory_ids.to_vec();
    target_memory_ids.sort();
    let target_memory_ids_json = serde_json::to_string(&target_memory_ids)
        .map_err(|error| sqlx::Error::Decode(Box::new(error)))?;
    Ok(format!("{action}:{target_memory_ids_json}"))
}

pub async fn search_memory(
    pool: &SqlitePool,
    request: SearchRequest,
    embedder: &dyn Embedder,
    embedding_dimension: usize,
) -> sqlx::Result<SearchResponse> {
    let limit = request.limit.unwrap_or(12).clamp(1, 50);
    let tokens = query_tokens(&request.query);
    let vector_scores = vector_scores_for_query(pool, embedder, embedding_dimension, &request)
        .await
        .unwrap_or_default();
    let rows = sqlx::query(
        "select id, kind, scope, text, source_session_id, source_turn_id, repo_id, workspace_id, agent_id, session_id, updated_at
         from memory_items
         where status = 'active'
           and user_id = ?
           and (
             scope = 'global'
             or (scope = 'workspace' and workspace_id = ?)
             or (scope = 'repo' and repo_id = ?)
             or (
               scope = 'session'
               and workspace_id is ?
               and repo_id is ?
               and agent_id is ?
               and session_id is ?
             )
           )
         order by updated_at desc",
    )
    .bind(&request.scope.user_id)
    .bind(&request.scope.workspace_id)
    .bind(&request.scope.repo_id)
    .bind(&request.scope.workspace_id)
    .bind(&request.scope.repo_id)
    .bind(&request.scope.agent_id)
    .bind(&request.scope.session_id)
    .fetch_all(pool)
    .await?;
    let mut scored = Vec::new();
    for row in rows {
        let id: String = row.get("id");
        let text: String = row.get("text");
        let lexical_score = lexical_score(&text, &tokens);
        let vector_score = vector_scores.get(&id).copied();
        if lexical_score <= 0.0
            && vector_score
                .map(|score| score < MIN_VECTOR_ONLY_SCORE)
                .unwrap_or(true)
        {
            continue;
        }
        let kind: String = row.get("kind");
        let scope: String = row.get("scope");
        let relevance_score = vector_score.unwrap_or(0.0).max(lexical_score);
        let score = ranker::final_score(
            relevance_score,
            scope_score(
                &scope,
                row.get::<Option<String>, _>("repo_id").as_deref(),
                row.get::<Option<String>, _>("workspace_id").as_deref(),
                row.get::<Option<String>, _>("agent_id").as_deref(),
                row.get::<Option<String>, _>("session_id").as_deref(),
                request.scope.repo_id.as_deref(),
                request.scope.workspace_id.as_deref(),
                request.scope.agent_id.as_deref(),
                request.scope.session_id.as_deref(),
            ),
            1.0,
        );
        scored.push((
            score,
            ranker::kind_priority(&kind),
            row.get::<i64, _>("updated_at"),
            SearchItem {
                id,
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
    let items = scored
        .into_iter()
        .take(limit as usize)
        .map(|(_, _, _, item)| item)
        .collect::<Vec<_>>();
    let first_memory_id = items.first().map(|item| item.id.clone());
    let memory_ids = items.iter().map(|item| item.id.clone()).collect::<Vec<_>>();
    let hits = items
        .iter()
        .map(|item| {
            serde_json::json!({
                "id": &item.id,
                "kind": &item.kind,
                "scope": &item.scope,
                "text": &item.text
            })
        })
        .collect::<Vec<_>>();
    write_audit(
        pool,
        "system",
        "memory.search",
        first_memory_id.as_deref(),
        None,
        None,
        serde_json::json!({
            "memoryIds": memory_ids,
            "hits": hits,
            "resultCount": items.len(),
            "queryHash": stable_text_hash(&request.query),
            "scope": {
                "workspaceId": request.scope.workspace_id,
                "repoId": request.scope.repo_id,
                "agentId": request.scope.agent_id,
                "sessionId": request.scope.session_id
            }
        }),
    )
    .await?;
    Ok(SearchResponse { items })
}

fn stable_text_hash(text: &str) -> String {
    let mut hash = 0xcbf29ce484222325_u64;
    for byte in text.as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x100000001b3);
    }
    format!("{hash:016x}")
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

async fn get_candidate(pool: &SqlitePool, id: &str) -> sqlx::Result<MemoryCandidateResponse> {
    let row = sqlx::query(
        "select id, kind, scope, text, reason, confidence, status, created_at, reviewed_at
         from memory_candidates where id = ?",
    )
    .bind(id)
    .fetch_one(pool)
    .await?;
    row_to_candidate(row)
}

async fn candidate_duplicate_source(
    pool: &SqlitePool,
    request_scope: &MemoryScope,
    kind: MemoryKind,
    candidate_scope: &str,
    text: &str,
) -> sqlx::Result<Option<&'static str>> {
    let normalized = normalize_memory_text(text);
    if normalized.is_empty() {
        return Ok(None);
    }

    let kind = kind_to_wire(kind);
    let active_rows = sqlx::query(
        "select text, workspace_id, repo_id, agent_id, session_id
         from memory_items
         where status = 'active' and user_id = ? and kind = ? and scope = ?",
    )
    .bind(&request_scope.user_id)
    .bind(&kind)
    .bind(candidate_scope)
    .fetch_all(pool)
    .await?;
    if rows_contain_duplicate(active_rows, request_scope, candidate_scope, &normalized) {
        return Ok(Some("active_memory"));
    }

    let pending_rows = sqlx::query(
        "select text, workspace_id, repo_id, agent_id, session_id
         from memory_candidates
         where status = 'pending' and user_id = ? and kind = ? and scope = ?",
    )
    .bind(&request_scope.user_id)
    .bind(&kind)
    .bind(candidate_scope)
    .fetch_all(pool)
    .await?;
    if rows_contain_duplicate(pending_rows, request_scope, candidate_scope, &normalized) {
        return Ok(Some("pending_candidate"));
    }

    Ok(None)
}

fn rows_contain_duplicate(
    rows: Vec<sqlx::sqlite::SqliteRow>,
    request_scope: &MemoryScope,
    candidate_scope: &str,
    normalized: &str,
) -> bool {
    rows.into_iter().any(|row| {
        stored_scope_matches_request(
            candidate_scope,
            &row.get::<Option<String>, _>("workspace_id"),
            &row.get::<Option<String>, _>("repo_id"),
            &row.get::<Option<String>, _>("agent_id"),
            &row.get::<Option<String>, _>("session_id"),
            request_scope,
        ) && normalize_memory_text(&row.get::<String, _>("text")) == normalized
    })
}

fn stored_scope_matches_request(
    scope: &str,
    workspace_id: &Option<String>,
    repo_id: &Option<String>,
    agent_id: &Option<String>,
    session_id: &Option<String>,
    request_scope: &MemoryScope,
) -> bool {
    match scope {
        "global" => true,
        "workspace" => workspace_id == &request_scope.workspace_id,
        "repo" => repo_id == &request_scope.repo_id,
        "session" => {
            workspace_id == &request_scope.workspace_id
                && repo_id == &request_scope.repo_id
                && agent_id == &request_scope.agent_id
                && session_id == &request_scope.session_id
        }
        _ => false,
    }
}

async fn list_maintenance_memory(
    pool: &SqlitePool,
    scope: &MemoryScope,
    limit: i64,
) -> sqlx::Result<Vec<MemoryResponse>> {
    let rows = sqlx::query(
        "select id, kind, scope, text, user_id, workspace_id, repo_id, agent_id, session_id, source, status, created_at, updated_at
         from memory_items
         where status in ('active', 'disabled')
           and user_id = ?
           and (
             scope = 'global'
             or (scope = 'workspace' and workspace_id = ?)
             or (scope = 'repo' and repo_id = ?)
             or (
               scope = 'session'
               and workspace_id is ?
               and repo_id is ?
               and agent_id is ?
               and session_id is ?
             )
           )
         order by updated_at desc
         limit ?",
    )
    .bind(&scope.user_id)
    .bind(&scope.workspace_id)
    .bind(&scope.repo_id)
    .bind(&scope.workspace_id)
    .bind(&scope.repo_id)
    .bind(&scope.agent_id)
    .bind(&scope.session_id)
    .bind(limit)
    .fetch_all(pool)
    .await?;
    rows.into_iter().map(row_to_memory).collect()
}

async fn get_change_request(
    pool: &SqlitePool,
    id: &str,
) -> sqlx::Result<MemoryChangeRequestResponse> {
    let row = sqlx::query(
        "select cr.id, cr.action, cr.source, cr.target_memory_id, cr.target_memory_ids_json,
                cr.proposed_kind, cr.proposed_scope, cr.proposed_text, cr.reason, cr.confidence,
                cr.status, cr.created_at, cr.reviewed_at, m.text as target_memory_text
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

async fn mark_change_request_reviewed(
    pool: &SqlitePool,
    id: &str,
    status: &str,
) -> sqlx::Result<()> {
    let result = sqlx::query(
        "update memory_change_requests set status = ?, reviewed_at = ? where id = ? and status = 'pending'",
    )
    .bind(status)
    .bind(Utc::now().timestamp_millis())
    .bind(id)
    .execute(pool)
    .await?;
    if result.rows_affected() == 0 {
        return Err(sqlx::Error::RowNotFound);
    }
    Ok(())
}

async fn update_memory_from_change_request(
    pool: &SqlitePool,
    id: &str,
    kind: MemoryKind,
    scope: String,
    text: String,
    audit_action: &str,
    change_request_id: &str,
) -> sqlx::Result<()> {
    let now = Utc::now().timestamp_millis();
    let text = redactor::redact(text.trim());
    let kind_wire = kind_to_wire(kind);
    let result = sqlx::query(
        "update memory_items set kind = ?, scope = ?, text = ?, updated_at = ? where id = ?",
    )
    .bind(kind_wire)
    .bind(&scope)
    .bind(&text)
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
        audit_action,
        Some(id),
        None,
        Some(change_request_id),
        serde_json::json!({
            "kind": kind_wire,
            "scope": scope,
            "text": text
        }),
    )
    .await
}

async fn set_memory_status_from_change_request(
    pool: &SqlitePool,
    id: &str,
    status: &str,
    audit_action: &str,
    change_request_id: &str,
) -> sqlx::Result<()> {
    let current = get_memory(pool, id).await?;
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
        "user",
        audit_action,
        Some(id),
        None,
        Some(change_request_id),
        serde_json::json!({"text": current.text, "status": status}),
    )
    .await
}

async fn soft_delete_memory_from_change_request(
    pool: &SqlitePool,
    id: &str,
    change_request_id: &str,
) -> sqlx::Result<()> {
    let current = get_memory(pool, id).await?;
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
        Some(change_request_id),
        serde_json::json!({"soft": true, "text": current.text}),
    )
    .await
}

async fn soft_delete_merged_memory_from_change_request(
    pool: &SqlitePool,
    id: &str,
    change_request_id: &str,
) -> sqlx::Result<()> {
    let current = get_memory(pool, id).await?;
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
        "memory.merge",
        Some(id),
        None,
        Some(change_request_id),
        serde_json::json!({"text": current.text, "status": "deleted"}),
    )
    .await
}

async fn merge_memory_from_change_request(
    pool: &SqlitePool,
    change_request: &MemoryChangeRequestResponse,
    request: ApproveChangeRequestRequest,
    change_request_id: &str,
) -> sqlx::Result<()> {
    let first_id = first_change_request_target(change_request)?;
    let first = get_memory(pool, first_id).await?;
    let kind = request
        .proposed_kind
        .or(change_request.proposed_kind)
        .unwrap_or(first.kind);
    let scope = request
        .proposed_scope
        .or(change_request.proposed_scope.clone())
        .unwrap_or(first.scope);
    let scope = directional_merge_scope_for_target_ids(pool, &change_request.target_memory_ids)
        .await?
        .unwrap_or(scope);
    let text = request
        .proposed_text
        .or(change_request.proposed_text.clone())
        .unwrap_or(first.text);
    let scope_data = MemoryScope {
        user_id: first.user_id,
        workspace_id: first.workspace_id,
        repo_id: first.repo_id,
        agent_id: first.agent_id,
        session_id: first.session_id,
    };
    let merged = create_manual_memory(
        pool,
        CreateMemoryRequest {
            kind,
            scope,
            text,
            scope_data,
        },
    )
    .await?;
    for target_id in &change_request.target_memory_ids {
        soft_delete_merged_memory_from_change_request(pool, target_id, change_request_id).await?;
    }
    write_audit(
        pool,
        "user",
        "memory.merge",
        Some(&merged.id),
        None,
        Some(change_request_id),
        serde_json::json!({
            "targetMemoryIds": &change_request.target_memory_ids,
            "kind": kind_to_wire(merged.kind),
            "scope": &merged.scope,
            "text": &merged.text
        }),
    )
    .await
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

fn scope_from_memory(memory: &MemoryResponse) -> MemoryScope {
    MemoryScope {
        user_id: memory.user_id.clone(),
        workspace_id: memory.workspace_id.clone(),
        repo_id: memory.repo_id.clone(),
        agent_id: memory.agent_id.clone(),
        session_id: memory.session_id.clone(),
    }
}

fn row_to_candidate(row: sqlx::sqlite::SqliteRow) -> sqlx::Result<MemoryCandidateResponse> {
    let kind: String = row.get("kind");
    Ok(MemoryCandidateResponse {
        id: row.get("id"),
        kind: serde_json::from_value(serde_json::Value::String(kind))
            .map_err(|error| sqlx::Error::Decode(Box::new(error)))?,
        scope: row.get("scope"),
        text: row.get("text"),
        confidence: row.get("confidence"),
        reason: row.get("reason"),
        status: row.get("status"),
        created_at: row.get("created_at"),
        reviewed_at: row.get("reviewed_at"),
    })
}

fn row_to_audit(row: sqlx::sqlite::SqliteRow) -> sqlx::Result<MemoryAuditResponse> {
    let payload_json: String = row.get("payload_json");
    let payload = serde_json::from_str(&payload_json).unwrap_or_else(|_| serde_json::json!({}));
    Ok(MemoryAuditResponse {
        id: row.get("id"),
        actor: row.get("actor"),
        action: row.get("action"),
        memory_id: row.get("memory_id"),
        candidate_id: row.get("candidate_id"),
        change_request_id: row.get("change_request_id"),
        payload,
        created_at: row.get("created_at"),
    })
}

fn row_to_change_request(
    row: sqlx::sqlite::SqliteRow,
) -> sqlx::Result<MemoryChangeRequestResponse> {
    let proposed_kind = match row.get::<Option<String>, _>("proposed_kind") {
        Some(kind) => Some(
            serde_json::from_value(serde_json::Value::String(kind))
                .map_err(|error| sqlx::Error::Decode(Box::new(error)))?,
        ),
        None => None,
    };
    Ok(MemoryChangeRequestResponse {
        id: row.get("id"),
        action: row.get("action"),
        source: row.get("source"),
        target_memory_ids: row_target_memory_ids(&row),
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

fn row_target_memory_ids(row: &sqlx::sqlite::SqliteRow) -> Vec<String> {
    if let Some(json) = row.get::<Option<String>, _>("target_memory_ids_json") {
        if let Ok(ids) = serde_json::from_str::<Vec<String>>(&json) {
            let ids = ids
                .into_iter()
                .map(|id| id.trim().to_string())
                .filter(|id| !id.is_empty())
                .collect::<Vec<_>>();
            if !ids.is_empty() {
                return ids;
            }
        }
    }
    row.get::<Option<String>, _>("target_memory_id")
        .map(|id| vec![id])
        .unwrap_or_default()
}

fn kind_to_wire(kind: MemoryKind) -> &'static str {
    match kind {
        MemoryKind::UserPreference => "user_preference",
        MemoryKind::ProjectRule => "project_rule",
        MemoryKind::ArchitectureDecision => "architecture_decision",
        MemoryKind::SessionSummary => "session_summary",
    }
}

fn normalize_change_action(action: &str) -> String {
    action.trim().to_ascii_lowercase().replace('-', "_")
}

fn default_manual_cleanup_actions() -> Vec<String> {
    ["delete", "disable", "expire"]
        .into_iter()
        .map(String::from)
        .collect()
}

fn manual_cleanup_actions(actions: Vec<String>) -> Vec<String> {
    let mut merged = default_manual_cleanup_actions();
    for action in actions {
        let action = action.trim();
        if !action.is_empty() && !merged.iter().any(|existing| existing == action) {
            merged.push(action.to_string());
        }
    }
    merged
}

struct MaintenanceMergeProposal {
    text: String,
    reason: String,
    confidence: f32,
    scope: String,
}

struct MaintenanceCleanupProposal {
    target_memory_id: String,
    reason: String,
    confidence: f32,
}

fn disabled_cleanup_proposal(
    left: &MemoryResponse,
    right: &MemoryResponse,
) -> Option<MaintenanceCleanupProposal> {
    if left.kind != right.kind {
        return None;
    }
    let left_disabled = left.status == "disabled";
    let right_disabled = right.status == "disabled";
    if !left_disabled && !right_disabled {
        return None;
    }
    let left_normalized = normalize_memory_text(&left.text);
    let right_normalized = normalize_memory_text(&right.text);
    if left_normalized.is_empty() || right_normalized.is_empty() {
        return None;
    }
    let confidence = duplicate_confidence(&left_normalized, &right_normalized)?;
    if confidence < 0.90 {
        return None;
    }
    let target_memory_id = if left_disabled && right.status == "active" {
        left.id.clone()
    } else if right_disabled {
        right.id.clone()
    } else {
        left.id.clone()
    };
    Some(MaintenanceCleanupProposal {
        target_memory_id,
        reason: "Disabled memory duplicates an existing memory; delete keeps the store compact."
            .to_string(),
        confidence,
    })
}

fn semantic_merge_groups<'a>(
    memories: &'a [MemoryResponse],
    used_memory_ids: &HashSet<String>,
) -> Vec<Vec<&'a MemoryResponse>> {
    let mut grouped: HashMap<String, Vec<&MemoryResponse>> = HashMap::new();
    for memory in memories {
        if used_memory_ids.contains(&memory.id) {
            continue;
        }
        if !matches!(memory.status.as_str(), "active" | "disabled") {
            continue;
        }
        let Some(key) = semantic_memory_key(memory.kind, &memory.text) else {
            continue;
        };
        grouped.entry(key).or_default().push(memory);
    }
    grouped
        .into_values()
        .filter(|group| group.len() >= 2 && group.iter().any(|memory| memory.status == "active"))
        .collect()
}

fn semantic_memory_key(kind: MemoryKind, text: &str) -> Option<String> {
    match kind {
        MemoryKind::UserPreference => user_language_preference_key(text),
        _ => None,
    }
}

fn user_language_preference_key(text: &str) -> Option<String> {
    let normalized = normalize_memory_text(text);
    let compact = normalized.split_whitespace().collect::<String>();
    let language = if compact.contains("中文") || compact.contains("汉语") {
        "zh"
    } else if compact.contains("英文") || compact.contains("英语") {
        "en"
    } else {
        return None;
    };
    let mentions_preference = compact.contains("偏好")
        || compact.contains("喜欢")
        || compact.contains("倾向")
        || normalized.contains("prefer");
    let mentions_communication = compact.contains("回复")
        || compact.contains("交流")
        || compact.contains("沟通")
        || normalized.contains("reply")
        || normalized.contains("response")
        || normalized.contains("communicat");
    if mentions_preference && mentions_communication {
        Some(format!("user_preference:language:{language}"))
    } else {
        None
    }
}

fn merge_proposal(
    left: &MemoryResponse,
    right: &MemoryResponse,
) -> Option<MaintenanceMergeProposal> {
    if left.kind != right.kind {
        return None;
    }
    let left_can_merge = matches!(left.status.as_str(), "active" | "disabled");
    let right_can_merge = matches!(right.status.as_str(), "active" | "disabled");
    let has_active_memory = left.status == "active" || right.status == "active";
    if !left_can_merge || !right_can_merge || !has_active_memory {
        return None;
    }
    let scope = directional_merge_scope(&left.scope, &right.scope)?;
    let left_normalized = normalize_memory_text(&left.text);
    let right_normalized = normalize_memory_text(&right.text);
    if left_normalized.is_empty() || right_normalized.is_empty() {
        return None;
    }
    let confidence = duplicate_confidence(&left_normalized, &right_normalized)?;
    Some(MaintenanceMergeProposal {
        text: shorter_memory_text(&left.text, &right.text),
        reason: merge_reason(&left.scope, &right.scope, &scope),
        confidence,
        scope,
    })
}

fn duplicate_confidence(left_normalized: &str, right_normalized: &str) -> Option<f32> {
    if left_normalized == right_normalized {
        Some(0.93)
    } else if left_normalized.contains(right_normalized)
        || right_normalized.contains(left_normalized)
    {
        Some(0.90)
    } else {
        let overlap = token_overlap_score(left_normalized, right_normalized);
        if overlap >= 0.60 {
            Some(0.82)
        } else {
            None
        }
    }
}

fn directional_merge_scope(left: &str, right: &str) -> Option<String> {
    let left_rank = merge_scope_rank(left)?;
    let right_rank = merge_scope_rank(right)?;
    if left == right {
        next_promotion_scope(left).map(str::to_string)
    } else if left_rank == right_rank {
        canonical_merge_scope((left_rank + 1).min(2)).map(str::to_string)
    } else {
        canonical_merge_scope(left_rank.max(right_rank)).map(str::to_string)
    }
}

async fn directional_merge_scope_for_target_ids(
    pool: &SqlitePool,
    target_memory_ids: &[String],
) -> sqlx::Result<Option<String>> {
    if target_memory_ids.len() < 2 {
        return Ok(None);
    }
    let mut max_rank: Option<u8> = None;
    let mut same_rank: Option<u8> = None;
    let mut all_same_rank = true;
    let mut same_scope: Option<String> = None;
    let mut all_same_scope = true;
    for id in target_memory_ids {
        let memory = match get_memory(pool, id).await {
            Ok(memory) => memory,
            Err(sqlx::Error::RowNotFound) => return Ok(None),
            Err(error) => return Err(error),
        };
        let Some(rank) = merge_scope_rank(&memory.scope) else {
            return Ok(None);
        };
        max_rank = Some(max_rank.map_or(rank, |current| current.max(rank)));
        match same_rank {
            None => same_rank = Some(rank),
            Some(current) if current == rank => {}
            Some(_) => all_same_rank = false,
        }
        match same_scope.as_deref() {
            None => same_scope = Some(memory.scope),
            Some(scope) if scope == memory.scope => {}
            Some(_) => all_same_scope = false,
        }
    }
    if all_same_scope {
        Ok(same_scope
            .as_deref()
            .and_then(next_promotion_scope)
            .map(str::to_string))
    } else if all_same_rank {
        Ok(same_rank
            .and_then(|rank| canonical_merge_scope((rank + 1).min(2)))
            .map(str::to_string))
    } else {
        Ok(max_rank.and_then(canonical_merge_scope).map(str::to_string))
    }
}

async fn directional_update_scope_for_target_ids(
    pool: &SqlitePool,
    target_memory_ids: &[String],
    proposed_scope: Option<String>,
) -> sqlx::Result<Option<String>> {
    let Some(proposed_scope) = proposed_scope else {
        return Ok(None);
    };
    let Some(target_id) = target_memory_ids.first() else {
        return Ok(Some(proposed_scope));
    };
    let memory = match get_memory(pool, target_id).await {
        Ok(memory) => memory,
        Err(sqlx::Error::RowNotFound) => return Ok(Some(proposed_scope)),
        Err(error) => return Err(error),
    };
    Ok(Some(directional_update_scope(
        &memory.scope,
        proposed_scope,
    )))
}

async fn normalize_change_request_proposed_scope(
    pool: &SqlitePool,
    action: &str,
    target_memory_ids: &[String],
    proposed_scope: Option<String>,
) -> sqlx::Result<Option<String>> {
    match action {
        "merge" => Ok(
            directional_merge_scope_for_target_ids(pool, target_memory_ids)
                .await?
                .or(proposed_scope),
        ),
        "update" | "summarize" => {
            directional_update_scope_for_target_ids(pool, target_memory_ids, proposed_scope).await
        }
        _ => Ok(proposed_scope),
    }
}

fn directional_update_scope(current_scope: &str, proposed_scope: String) -> String {
    let Some(current_rank) = merge_scope_rank(current_scope) else {
        return proposed_scope;
    };
    let Some(proposed_rank) = merge_scope_rank(&proposed_scope) else {
        return proposed_scope;
    };
    if proposed_rank < current_rank {
        current_scope.to_string()
    } else if proposed_rank > current_rank + 1 {
        canonical_merge_scope((current_rank + 1).min(2))
            .unwrap_or(proposed_scope.as_str())
            .to_string()
    } else {
        proposed_scope
    }
}

fn merge_scope_rank(scope: &str) -> Option<u8> {
    match scope {
        "session" => Some(0),
        "repo" => Some(1),
        "workspace" => Some(1),
        "global" => Some(2),
        _ => None,
    }
}

fn canonical_merge_scope(rank: u8) -> Option<&'static str> {
    match rank {
        0 => Some("session"),
        1 => Some("repo"),
        2 => Some("global"),
        _ => None,
    }
}

fn next_promotion_scope(scope: &str) -> Option<&'static str> {
    match scope {
        "session" => Some("repo"),
        "repo" | "workspace" => Some("global"),
        "global" => Some("global"),
        _ => None,
    }
}

fn merge_reason(left_scope: &str, right_scope: &str, target_scope: &str) -> String {
    if left_scope == right_scope {
        "These memories appear to describe the same fact; merging keeps retrieval concise."
            .to_string()
    } else {
        format!(
            "These memories describe the same fact across scopes; merging toward {target_scope} follows session to repo to global promotion."
        )
    }
}

fn should_auto_approve_maintenance(
    mode: &str,
    action: &str,
    confidence: f32,
    high_confidence_threshold: f32,
    manual_only_actions: &[String],
) -> bool {
    mode == "high_confidence_auto"
        && confidence >= high_confidence_threshold
        && !manual_only_actions
            .iter()
            .any(|manual_action| manual_action == action)
}

fn maintenance_action_writes_memory_text(action: &str) -> bool {
    matches!(action, "update" | "summarize" | "merge")
}

async fn write_maintenance_run_audit(
    pool: &SqlitePool,
    response: &MaintenanceRunResponse,
    mode: &str,
) -> sqlx::Result<()> {
    write_audit(
        pool,
        "system",
        "maintenance.run",
        None,
        None,
        None,
        serde_json::json!({
            "mode": mode,
            "autoApplied": response.auto_applied,
            "needsReview": response.needs_review,
            "skipped": response.skipped
        }),
    )
    .await
}

fn normalize_memory_text(text: &str) -> String {
    text.chars()
        .map(|character| {
            if character.is_alphanumeric() {
                character.to_ascii_lowercase()
            } else {
                ' '
            }
        })
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

fn shorter_memory_text(left: &str, right: &str) -> String {
    let left = left.trim();
    let right = right.trim();
    if right.chars().count() < left.chars().count() {
        right.to_string()
    } else {
        left.to_string()
    }
}

fn shortest_memory_text<'a>(texts: impl Iterator<Item = &'a str>) -> String {
    texts
        .map(str::trim)
        .filter(|text| !text.is_empty())
        .min_by_key(|text| text.chars().count())
        .unwrap_or_default()
        .to_string()
}

fn token_overlap_score(left: &str, right: &str) -> f32 {
    let left_tokens = memory_tokens(left);
    let right_tokens = memory_tokens(right);
    let min_len = left_tokens.len().min(right_tokens.len());
    if min_len == 0 {
        return 0.0;
    }
    let matches = left_tokens
        .iter()
        .filter(|token| right_tokens.contains(*token))
        .count();
    matches as f32 / min_len as f32
}

fn memory_tokens(text: &str) -> Vec<String> {
    text.split_whitespace()
        .map(str::trim)
        .filter(|token| token.chars().count() >= 2)
        .map(str::to_string)
        .collect()
}

fn normalize_target_memory_ids(target_memory_id: Option<&str>, ids: &[String]) -> Vec<String> {
    let mut values = ids
        .iter()
        .map(|id| id.trim().to_string())
        .filter(|id| !id.is_empty())
        .collect::<Vec<_>>();
    if values.is_empty() {
        if let Some(id) = target_memory_id.map(str::trim).filter(|id| !id.is_empty()) {
            values.push(id.to_string());
        }
    }
    values.sort();
    values.dedup();
    values
}

fn clean_optional_text(value: Option<&str>) -> Option<String> {
    value
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
}

fn first_change_request_target(request: &MemoryChangeRequestResponse) -> sqlx::Result<&str> {
    request
        .target_memory_ids
        .first()
        .map(String::as_str)
        .ok_or(sqlx::Error::RowNotFound)
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
