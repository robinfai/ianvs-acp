use crate::error::ApiError;
use crate::memory::engine::MemoryEntityInput;
use crate::memory::redactor;
use crate::memory::types::{MemoryKind, MemoryScope};
use chrono::Utc;
use serde::{Deserialize, Serialize};
use sqlx::{FromRow, Row, SqlitePool};
use std::collections::{HashMap, HashSet};
use uuid::Uuid;

const TRANSFER_VERSION: u32 = 1;
const MAX_EXPORT_RECORDS: usize = 10_000;
const MAX_IMPORT_BYTES: usize = 20 * 1024 * 1024;
const MAX_IMPORT_RECORDS: usize = 10_000;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExportMemoryRequest {
    pub scope_data: MemoryScope,
    pub memory_scope: Option<String>,
    pub kind: Option<MemoryKind>,
    pub status: Option<String>,
    pub created_from: Option<i64>,
    pub created_until: Option<i64>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ExportMemoryResponse {
    pub jsonl: String,
    pub exported: usize,
    pub truncated: bool,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ImportMemoryRequest {
    pub jsonl: String,
    pub mode: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ImportMemoryResponse {
    pub imported: usize,
    pub pending_review: usize,
    pub skipped: usize,
    pub errors: Vec<ImportLineError>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ImportLineError {
    pub line: usize,
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct MemoryTransferRecord {
    #[serde(default = "transfer_version")]
    version: u32,
    #[serde(rename = "type", default = "memory_record_type")]
    record_type: String,
    original_id: Option<String>,
    kind: MemoryKind,
    scope: String,
    text: String,
    scope_data: MemoryScope,
    source: Option<String>,
    source_session_id: Option<String>,
    source_turn_id: Option<String>,
    #[serde(default)]
    entities: Vec<MemoryEntityInput>,
    observed_at: Option<i64>,
    valid_from: Option<i64>,
    valid_until: Option<i64>,
    supersedes_original_id: Option<String>,
    #[serde(default)]
    pinned: bool,
    confidence: Option<f32>,
    #[serde(default = "active_status")]
    status: String,
    created_at: Option<i64>,
    updated_at: Option<i64>,
}

#[derive(Debug, FromRow)]
struct ExportRow {
    id: String,
    user_id: String,
    workspace_id: Option<String>,
    repo_id: Option<String>,
    agent_id: Option<String>,
    session_id: Option<String>,
    source: String,
    kind: String,
    scope: String,
    text: String,
    source_session_id: Option<String>,
    source_turn_id: Option<String>,
    observed_at: Option<i64>,
    valid_from: Option<i64>,
    valid_until: Option<i64>,
    supersedes_memory_id: Option<String>,
    pinned: i64,
    confidence: Option<f32>,
    status: String,
    created_at: i64,
    updated_at: i64,
}

struct ParsedRecord {
    line: usize,
    record: MemoryTransferRecord,
}

struct TrustedRecord {
    line: usize,
    id: String,
    duplicate: bool,
    record: MemoryTransferRecord,
}

pub async fn export_memory(
    pool: &SqlitePool,
    request: ExportMemoryRequest,
) -> Result<ExportMemoryResponse, ApiError> {
    validate_optional_filter("scope", request.memory_scope.as_deref(), valid_scope)?;
    validate_optional_filter("status", request.status.as_deref(), valid_status)?;
    if matches!(
        (request.created_from, request.created_until),
        (Some(from), Some(until)) if from > until
    ) {
        return Err(ApiError::BadRequest(
            "createdFrom must be less than or equal to createdUntil".to_string(),
        ));
    }

    let kind = request.kind.map(kind_to_wire);
    let rows = sqlx::query_as::<_, ExportRow>(
        "select id, user_id, workspace_id, repo_id, agent_id, session_id, source,
                kind, scope, text, source_session_id, source_turn_id, observed_at,
                valid_from, valid_until, supersedes_memory_id, pinned, confidence,
                status, created_at, updated_at
         from memory_items
         where user_id = ?
           and (? is null or scope = ?)
           and (? is null or kind = ?)
           and (? is null or status = ?)
           and (? is null or created_at >= ?)
           and (? is null or created_at <= ?)
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
           )
         order by created_at asc, id asc
         limit ?",
    )
    .bind(&request.scope_data.user_id)
    .bind(request.memory_scope.as_deref())
    .bind(request.memory_scope.as_deref())
    .bind(kind)
    .bind(kind)
    .bind(request.status.as_deref())
    .bind(request.status.as_deref())
    .bind(request.created_from)
    .bind(request.created_from)
    .bind(request.created_until)
    .bind(request.created_until)
    .bind(request.scope_data.workspace_id.as_deref())
    .bind(request.scope_data.workspace_id.as_deref())
    .bind(request.scope_data.workspace_id.as_deref())
    .bind(request.scope_data.workspace_id.as_deref())
    .bind(request.scope_data.repo_id.as_deref())
    .bind(request.scope_data.repo_id.as_deref())
    .bind(request.scope_data.workspace_id.as_deref())
    .bind(request.scope_data.workspace_id.as_deref())
    .bind(request.scope_data.repo_id.as_deref())
    .bind(request.scope_data.repo_id.as_deref())
    .bind(request.scope_data.agent_id.as_deref())
    .bind(request.scope_data.agent_id.as_deref())
    .bind(request.scope_data.session_id.as_deref())
    .bind(request.scope_data.session_id.as_deref())
    .bind((MAX_EXPORT_RECORDS + 1) as i64)
    .fetch_all(pool)
    .await?;

    let truncated = rows.len() > MAX_EXPORT_RECORDS;
    let mut lines = Vec::with_capacity(rows.len().min(MAX_EXPORT_RECORDS));
    for row in rows.into_iter().take(MAX_EXPORT_RECORDS) {
        let entities = load_entities(pool, &row.id).await?;
        let kind = serde_json::from_value(serde_json::Value::String(row.kind))
            .map_err(|error| ApiError::Anyhow(error.into()))?;
        let record = MemoryTransferRecord {
            version: TRANSFER_VERSION,
            record_type: memory_record_type(),
            original_id: Some(row.id),
            kind,
            scope: row.scope,
            text: row.text,
            scope_data: MemoryScope {
                user_id: row.user_id,
                workspace_id: row.workspace_id,
                repo_id: row.repo_id,
                agent_id: row.agent_id,
                session_id: row.session_id,
            },
            source: Some(row.source),
            source_session_id: row.source_session_id,
            source_turn_id: row.source_turn_id,
            entities,
            observed_at: row.observed_at,
            valid_from: row.valid_from,
            valid_until: row.valid_until,
            supersedes_original_id: row.supersedes_memory_id,
            pinned: row.pinned != 0,
            confidence: row.confidence,
            status: row.status,
            created_at: Some(row.created_at),
            updated_at: Some(row.updated_at),
        };
        lines.push(serde_json::to_string(&record).map_err(|error| ApiError::Anyhow(error.into()))?);
    }
    let jsonl = if lines.is_empty() {
        String::new()
    } else {
        format!("{}\n", lines.join("\n"))
    };
    Ok(ExportMemoryResponse {
        exported: lines.len(),
        jsonl,
        truncated,
    })
}

pub async fn import_memory(
    pool: &SqlitePool,
    request: ImportMemoryRequest,
) -> Result<ImportMemoryResponse, ApiError> {
    if request.jsonl.len() > MAX_IMPORT_BYTES {
        return Err(ApiError::BadRequest(format!(
            "JSONL import exceeds the {} byte limit",
            MAX_IMPORT_BYTES
        )));
    }
    let mode = normalize_import_mode(&request.mode)?;
    let (records, mut errors) = parse_records(&request.jsonl)?;
    let mut response = ImportMemoryResponse {
        imported: 0,
        pending_review: 0,
        skipped: 0,
        errors: Vec::new(),
    };
    if records.is_empty() {
        response.errors.append(&mut errors);
        return Ok(response);
    }

    match mode {
        ImportMode::PendingReview => {
            import_pending(pool, records, &mut response, &mut errors).await?
        }
        ImportMode::Trusted => import_trusted(pool, records, &mut response, &mut errors).await?,
    }
    response.errors.append(&mut errors);
    Ok(response)
}

async fn import_pending(
    pool: &SqlitePool,
    records: Vec<ParsedRecord>,
    response: &mut ImportMemoryResponse,
    errors: &mut Vec<ImportLineError>,
) -> Result<(), ApiError> {
    let mut transaction = pool.begin().await?;
    let now = Utc::now().timestamp_millis();
    for parsed in records {
        let record = parsed.record;
        if record.status != "active" {
            response.skipped += 1;
            errors.push(ImportLineError {
                line: parsed.line,
                message:
                    "pending_review import only accepts active records; use trusted mode to restore disabled or deleted history"
                        .to_string(),
            });
            continue;
        }
        if duplicate_memory(&mut transaction, &record).await?
            || duplicate_candidate(&mut transaction, &record).await?
        {
            response.skipped += 1;
            continue;
        }
        let id = format!("cand_{}", Uuid::new_v4());
        let entities_json = serde_json::to_string(&record.entities)
            .map_err(|error| ApiError::Anyhow(error.into()))?;
        sqlx::query(
            "insert into memory_candidates
             (id, user_id, workspace_id, repo_id, agent_id, session_id,
              source_turn_id, source, kind, scope, text, reason, confidence,
              pinned, entities_json, instruction_scopes_json, status, created_at)
             values (?, ?, ?, ?, ?, ?, ?, 'import', ?, ?, ?, ?, ?, ?, ?, '[\"import\"]', 'pending', ?)",
        )
        .bind(&id)
        .bind(&record.scope_data.user_id)
        .bind(&record.scope_data.workspace_id)
        .bind(&record.scope_data.repo_id)
        .bind(&record.scope_data.agent_id)
        .bind(&record.scope_data.session_id)
        .bind(record.source_turn_id.as_deref())
        .bind(kind_to_wire(record.kind))
        .bind(&record.scope)
        .bind(redactor::redact(record.text.trim()))
        .bind("Imported from JSONL backup; review before activation.")
        .bind(record.confidence.unwrap_or(1.0))
        .bind(if record.pinned { 1_i64 } else { 0_i64 })
        .bind(entities_json)
        .bind(now)
        .execute(&mut *transaction)
        .await?;
        write_import_audit(
            &mut transaction,
            "candidate.create",
            None,
            Some(&id),
            parsed.line,
            record.original_id.as_deref(),
            record.source.as_deref(),
        )
        .await?;
        response.pending_review += 1;
    }
    transaction.commit().await?;
    Ok(())
}

async fn import_trusted(
    pool: &SqlitePool,
    records: Vec<ParsedRecord>,
    response: &mut ImportMemoryResponse,
    _errors: &mut Vec<ImportLineError>,
) -> Result<(), ApiError> {
    let mut transaction = pool.begin().await?;
    let mut id_map = HashMap::new();
    let mut prepared = Vec::with_capacity(records.len());

    for parsed in records {
        let duplicate_id = duplicate_memory_id(&mut transaction, &parsed.record).await?;
        let duplicate = duplicate_id.is_some();
        let id = duplicate_id.unwrap_or_else(|| format!("mem_{}", Uuid::new_v4()));
        if let Some(original_id) = parsed.record.original_id.as_deref() {
            id_map.insert(original_id.to_string(), id.clone());
        }
        if duplicate {
            response.skipped += 1;
        }
        prepared.push(TrustedRecord {
            line: parsed.line,
            id,
            duplicate,
            record: parsed.record,
        });
    }

    for prepared_record in prepared {
        if prepared_record.duplicate {
            continue;
        }
        let record = prepared_record.record;
        let now = Utc::now().timestamp_millis();
        let created_at = record.created_at.unwrap_or(now).max(0);
        let updated_at = record.updated_at.unwrap_or(created_at).max(created_at);
        let supersedes_memory_id = record
            .supersedes_original_id
            .as_ref()
            .and_then(|original_id| id_map.get(original_id))
            .cloned();
        let pinned = record.pinned && record.status == "active";
        sqlx::query(
            "insert into memory_items
             (id, user_id, workspace_id, repo_id, agent_id, session_id, source,
              kind, scope, text, source_session_id, source_turn_id, observed_at,
              valid_from, valid_until, supersedes_memory_id, pinned, confidence,
              status, created_at, updated_at, deleted_at)
             values (?, ?, ?, ?, ?, ?, 'import', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        )
        .bind(&prepared_record.id)
        .bind(&record.scope_data.user_id)
        .bind(&record.scope_data.workspace_id)
        .bind(&record.scope_data.repo_id)
        .bind(&record.scope_data.agent_id)
        .bind(&record.scope_data.session_id)
        .bind(kind_to_wire(record.kind))
        .bind(&record.scope)
        .bind(redactor::redact(record.text.trim()))
        .bind(record.source_session_id.as_deref())
        .bind(record.source_turn_id.as_deref())
        .bind(record.observed_at)
        .bind(record.valid_from)
        .bind(record.valid_until)
        .bind(supersedes_memory_id.as_deref())
        .bind(if pinned { 1_i64 } else { 0_i64 })
        .bind(record.confidence)
        .bind(&record.status)
        .bind(created_at)
        .bind(updated_at)
        .bind((record.status == "deleted").then_some(updated_at))
        .execute(&mut *transaction)
        .await?;
        insert_entities(
            &mut transaction,
            &prepared_record.id,
            &record.entities,
            created_at,
        )
        .await?;
        write_import_audit(
            &mut transaction,
            "memory.import",
            Some(&prepared_record.id),
            None,
            prepared_record.line,
            record.original_id.as_deref(),
            record.source.as_deref(),
        )
        .await?;
        response.imported += 1;
    }
    transaction.commit().await?;
    Ok(())
}

fn parse_records(jsonl: &str) -> Result<(Vec<ParsedRecord>, Vec<ImportLineError>), ApiError> {
    let mut records = Vec::new();
    let mut errors = Vec::new();
    for (index, raw_line) in jsonl.lines().enumerate() {
        let line = index + 1;
        let trimmed = raw_line.trim();
        if trimmed.is_empty() {
            continue;
        }
        if records.len() >= MAX_IMPORT_RECORDS {
            return Err(ApiError::BadRequest(format!(
                "JSONL import exceeds the {} record limit",
                MAX_IMPORT_RECORDS
            )));
        }
        match serde_json::from_str::<MemoryTransferRecord>(trimmed) {
            Ok(record) => match validate_record(&record) {
                Ok(()) => records.push(ParsedRecord { line, record }),
                Err(message) => errors.push(ImportLineError { line, message }),
            },
            Err(error) => errors.push(ImportLineError {
                line,
                message: format!("invalid JSONL memory record: {error}"),
            }),
        }
    }
    if records.is_empty() && errors.is_empty() {
        return Err(ApiError::BadRequest(
            "JSONL import contains no memory records".to_string(),
        ));
    }
    Ok((records, errors))
}

fn validate_record(record: &MemoryTransferRecord) -> Result<(), String> {
    if record.version != TRANSFER_VERSION {
        return Err(format!(
            "unsupported memory transfer version: {}",
            record.version
        ));
    }
    if record.record_type != memory_record_type() {
        return Err(format!(
            "unsupported JSONL record type: {}",
            record.record_type
        ));
    }
    if !valid_scope(&record.scope) {
        return Err(format!("unsupported memory scope: {}", record.scope));
    }
    if !valid_status(&record.status) {
        return Err(format!("unsupported memory status: {}", record.status));
    }
    let text = record.text.trim();
    if text.len() < 8 || text.chars().count() > 1_000 {
        return Err("memory text must contain 8 to 1000 characters".to_string());
    }
    if redactor::contains_secret(text) {
        return Err("memory text looks like it contains a secret".to_string());
    }
    if record.scope_data.user_id.trim().is_empty() {
        return Err("scopeData.userId is required".to_string());
    }
    Ok(())
}

async fn duplicate_memory(
    transaction: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    record: &MemoryTransferRecord,
) -> Result<bool, ApiError> {
    Ok(duplicate_memory_id(transaction, record).await?.is_some())
}

async fn duplicate_memory_id(
    transaction: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    record: &MemoryTransferRecord,
) -> Result<Option<String>, ApiError> {
    Ok(sqlx::query_scalar::<_, String>(
        "select id from memory_items
         where user_id = ?
           and kind = ?
           and scope = ?
           and trim(text) = trim(?)
           and (
               scope = 'global'
               or (
                   scope = 'workspace'
                   and workspace_id is ?
               )
               or (
                   scope = 'repo'
                   and workspace_id is ?
                   and repo_id is ?
               )
               or (
                   scope = 'session'
                   and workspace_id is ?
                   and repo_id is ?
                   and agent_id is ?
                   and session_id is ?
               )
           )
         limit 1",
    )
    .bind(&record.scope_data.user_id)
    .bind(kind_to_wire(record.kind))
    .bind(&record.scope)
    .bind(&record.text)
    .bind(record.scope_data.workspace_id.as_deref())
    .bind(record.scope_data.workspace_id.as_deref())
    .bind(record.scope_data.repo_id.as_deref())
    .bind(record.scope_data.workspace_id.as_deref())
    .bind(record.scope_data.repo_id.as_deref())
    .bind(record.scope_data.agent_id.as_deref())
    .bind(record.scope_data.session_id.as_deref())
    .fetch_optional(&mut **transaction)
    .await?)
}

async fn duplicate_candidate(
    transaction: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    record: &MemoryTransferRecord,
) -> Result<bool, ApiError> {
    let count = sqlx::query_scalar::<_, i64>(
        "select count(*) from memory_candidates
         where status = 'pending'
           and user_id = ?
           and kind = ?
           and scope = ?
           and trim(text) = trim(?)
           and (
               scope = 'global'
               or (
                   scope = 'workspace'
                   and workspace_id is ?
               )
               or (
                   scope = 'repo'
                   and workspace_id is ?
                   and repo_id is ?
               )
               or (
                   scope = 'session'
                   and workspace_id is ?
                   and repo_id is ?
                   and agent_id is ?
                   and session_id is ?
               )
           )",
    )
    .bind(&record.scope_data.user_id)
    .bind(kind_to_wire(record.kind))
    .bind(&record.scope)
    .bind(&record.text)
    .bind(record.scope_data.workspace_id.as_deref())
    .bind(record.scope_data.workspace_id.as_deref())
    .bind(record.scope_data.repo_id.as_deref())
    .bind(record.scope_data.workspace_id.as_deref())
    .bind(record.scope_data.repo_id.as_deref())
    .bind(record.scope_data.agent_id.as_deref())
    .bind(record.scope_data.session_id.as_deref())
    .fetch_one(&mut **transaction)
    .await?;
    Ok(count > 0)
}

async fn load_entities(
    pool: &SqlitePool,
    memory_id: &str,
) -> Result<Vec<MemoryEntityInput>, ApiError> {
    let rows = sqlx::query(
        "select entity_text, entity_type
         from memory_entities
         where memory_id = ?
         order by created_at asc, id asc",
    )
    .bind(memory_id)
    .fetch_all(pool)
    .await?;
    Ok(rows
        .into_iter()
        .map(|row| MemoryEntityInput {
            text: row.get("entity_text"),
            entity_type: Some(row.get("entity_type")),
        })
        .collect())
}

async fn insert_entities(
    transaction: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    memory_id: &str,
    entities: &[MemoryEntityInput],
    created_at: i64,
) -> Result<(), ApiError> {
    let mut seen = HashSet::new();
    for entity in entities {
        let text = entity.text.trim();
        let normalized_text = normalize_entity(text);
        if normalized_text.is_empty() || !seen.insert(normalized_text.clone()) {
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
        .bind(normalized_text)
        .bind(created_at)
        .execute(&mut **transaction)
        .await?;
    }
    Ok(())
}

async fn write_import_audit(
    transaction: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    action: &str,
    memory_id: Option<&str>,
    candidate_id: Option<&str>,
    line: usize,
    original_id: Option<&str>,
    original_source: Option<&str>,
) -> Result<(), ApiError> {
    sqlx::query(
        "insert into memory_audit_log
         (id, actor, action, memory_id, candidate_id, change_request_id, payload_json, created_at)
         values (?, 'import', ?, ?, ?, null, ?, ?)",
    )
    .bind(format!("audit_{}", Uuid::new_v4()))
    .bind(action)
    .bind(memory_id)
    .bind(candidate_id)
    .bind(
        serde_json::json!({
            "line": line,
            "originalId": original_id,
            "originalSource": original_source,
        })
        .to_string(),
    )
    .bind(Utc::now().timestamp_millis())
    .execute(&mut **transaction)
    .await?;
    Ok(())
}

fn normalize_import_mode(value: &str) -> Result<ImportMode, ApiError> {
    match value
        .trim()
        .to_ascii_lowercase()
        .replace([' ', '-'], "_")
        .as_str()
    {
        "pending" | "pending_review" => Ok(ImportMode::PendingReview),
        "trusted" | "trusted_import" => Ok(ImportMode::Trusted),
        _ => Err(ApiError::BadRequest(format!(
            "unsupported memory import mode: {value}"
        ))),
    }
}

fn validate_optional_filter(
    name: &str,
    value: Option<&str>,
    validator: fn(&str) -> bool,
) -> Result<(), ApiError> {
    if let Some(value) = value {
        if !validator(value) {
            return Err(ApiError::BadRequest(format!(
                "unsupported memory {name}: {value}"
            )));
        }
    }
    Ok(())
}

fn valid_scope(value: &str) -> bool {
    matches!(value, "global" | "workspace" | "repo" | "session")
}

fn valid_status(value: &str) -> bool {
    matches!(value, "active" | "disabled" | "deleted")
}

fn kind_to_wire(kind: MemoryKind) -> &'static str {
    match kind {
        MemoryKind::UserPreference => "user_preference",
        MemoryKind::ProjectRule => "project_rule",
        MemoryKind::ArchitectureDecision => "architecture_decision",
        MemoryKind::SessionSummary => "session_summary",
    }
}

fn normalize_entity(value: &str) -> String {
    value
        .chars()
        .filter(|character| character.is_alphanumeric())
        .flat_map(char::to_lowercase)
        .collect()
}

fn transfer_version() -> u32 {
    TRANSFER_VERSION
}

fn memory_record_type() -> String {
    "memory".to_string()
}

fn active_status() -> String {
    "active".to_string()
}

enum ImportMode {
    PendingReview,
    Trusted,
}
