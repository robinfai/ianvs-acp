use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;
use std::time::SystemTime;

use chrono::{DateTime, SecondsFormat, Utc};
use rusqlite::{
    Connection, OpenFlags, OptionalExtension, Transaction, TransactionBehavior, params,
};
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use thiserror::Error;
use uuid::Uuid;

use crate::{
    ClassifiedRecoveryReport, ExecutionError, ExecutorCommandContext, ExecutorLease,
    ExecutorLeaseCommand, ExecutorLeaseOperation, ExecutorLeaseState, ExecutorTakeoverRequest,
    IdempotencyKey, IdempotencyRecord, InboxEventRecord, MAX_IDEMPOTENCY_RESULT_BYTES,
    MAX_RUNTIME_EVENT_APPEND_BATCH, MAX_RUNTIME_EVENT_QUERY_LIMIT, MAX_RUNTIME_EVENT_REPLAY,
    MAX_RUNTIME_EVENTS_PER_RUN, PromptSubmissionState, RUNTIME_EVENT_CHECKPOINT_INTERVAL,
    RecoveryState, RunRecoveryRecord, RunState, RunStatus, RuntimeEventAppendReceipt,
    RuntimeEventPage, StoredRuntimeEvent, SuggestedRecoveryAction, TaskInboxError,
    TaskInboxSnapshot, TaskState, TaskStatus, WORKFLOW_SNAPSHOT_RETENTION, WorkflowDefinition,
    WorkflowIrError, WorkflowRun, WorkflowSnapshot, WorkspaceMutationPossibility,
};

const SCHEMA_VERSION: i64 = 9;
const MAX_WORKFLOW_IR_DOCUMENT_BYTES: usize = 8 * 1024 * 1024;

#[derive(Debug, Error)]
pub enum WorkflowStoreError {
    #[error("workflow database path must be absolute")]
    RelativePath,
    #[error("workflow database path must not be a symlink: {0}")]
    SymlinkPath(String),
    #[error("workflow database path has no parent or file name")]
    InvalidPath,
    #[error("unsupported workflow database schema version: {0}")]
    UnsupportedSchema(i64),
    #[error("invalid persisted workflow value: {0}")]
    InvalidValue(String),
    #[error("workflow revision conflict: expected {expected}, found {actual}")]
    Conflict { expected: u64, actual: u64 },
    #[error("workflow migration is staged and cannot dispatch yet")]
    MigrationStaged,
    #[error("workflow migration is materialized but not active")]
    MigrationReady,
    #[error("workflow migration is active; use the TaskInbox transaction API")]
    MigrationActive,
    #[error("task inbox materialization requires a staged migration")]
    MaterializeRequiresStagedMigration,
    #[error("task inbox activation requires a ready migration")]
    ActivateRequiresReadyMigration,
    #[error("TaskInbox mutations require an active migration")]
    TaskInboxNotActive,
    #[error("task inbox import requires an empty revision-zero workflow")]
    ImportRequiresEmptyWorkflow,
    #[error("task inbox source checksum must be canonical non-empty text")]
    InvalidSourceChecksum,
    #[error("runtime event append batch exceeds the bounded limit")]
    RuntimeEventBatchTooLarge,
    #[error("runtime event query limit must be between 1 and {0}")]
    InvalidRuntimeEventQueryLimit(usize),
    #[error("runtime event replay exceeds the bounded limit of {0}")]
    RuntimeEventReplayLimit(usize),
    #[error("runtime event retention limit reached for Run {0}")]
    RuntimeEventRetentionLimit(String),
    #[error("runtime event id already exists: {0}")]
    DuplicateRuntimeEvent(String),
    #[error(transparent)]
    WorkflowIr(#[from] WorkflowIrError),
    #[error(transparent)]
    TaskInbox(#[from] TaskInboxError),
    #[error(transparent)]
    Execution(#[from] ExecutionError),
    #[error(transparent)]
    Io(#[from] std::io::Error),
    #[error(transparent)]
    Sqlite(#[from] rusqlite::Error),
}

pub type RecoveryReport = ClassifiedRecoveryReport;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VersionedWorkflowSnapshot {
    pub revision: u64,
    pub snapshot: WorkflowSnapshot,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WorkflowMigrationPhase {
    Native,
    Staged,
    Ready,
    Active,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkflowMigrationMetadata {
    pub phase: WorkflowMigrationPhase,
    pub source_checksum: Option<String>,
}

/// Transactional Task/Run store. It is deliberately UI-independent and keeps
/// recovery policy explicit rather than dispatching work while opening.
pub struct SqliteWorkflowStore {
    connection: Connection,
    path: Option<PathBuf>,
}

impl std::fmt::Debug for SqliteWorkflowStore {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("SqliteWorkflowStore")
            .field("path", &self.path)
            .finish_non_exhaustive()
    }
}

impl SqliteWorkflowStore {
    pub fn open(path: impl AsRef<Path>) -> Result<Self, WorkflowStoreError> {
        let path = safe_database_path(path.as_ref())?;
        let connection = Connection::open_with_flags(
            &path,
            OpenFlags::SQLITE_OPEN_READ_WRITE
                | OpenFlags::SQLITE_OPEN_CREATE
                | OpenFlags::SQLITE_OPEN_NO_MUTEX
                | OpenFlags::SQLITE_OPEN_NOFOLLOW
                | OpenFlags::SQLITE_OPEN_EXRESCODE,
        )?;
        let mut store = Self {
            connection,
            path: Some(path),
        };
        store.initialize()?;
        Ok(store)
    }

    pub fn open_in_memory() -> Result<Self, WorkflowStoreError> {
        let connection = Connection::open_in_memory()?;
        let mut store = Self {
            connection,
            path: None,
        };
        store.initialize()?;
        Ok(store)
    }

    #[must_use]
    pub fn path(&self) -> Option<&Path> {
        self.path.as_deref()
    }

    pub fn save_snapshot(&mut self, snapshot: &WorkflowSnapshot) -> Result<(), WorkflowStoreError> {
        let revision = self.revision()?;
        self.save_snapshot_if_revision(snapshot, revision)?;
        Ok(())
    }

    pub fn save_snapshot_if_revision(
        &mut self,
        snapshot: &WorkflowSnapshot,
        expected_revision: u64,
    ) -> Result<u64, WorkflowStoreError> {
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let actual_revision = query_revision(&transaction)?;
        if actual_revision != expected_revision {
            return Err(WorkflowStoreError::Conflict {
                expected: expected_revision,
                actual: actual_revision,
            });
        }
        match query_migration_metadata(&transaction)?.phase {
            WorkflowMigrationPhase::Native => {}
            WorkflowMigrationPhase::Staged => return Err(WorkflowStoreError::MigrationStaged),
            WorkflowMigrationPhase::Ready => return Err(WorkflowStoreError::MigrationReady),
            WorkflowMigrationPhase::Active => return Err(WorkflowStoreError::MigrationActive),
        }
        transaction.execute("DELETE FROM runs", [])?;
        transaction.execute("DELETE FROM tasks", [])?;
        insert_snapshot_rows(&transaction, snapshot)?;
        let next_revision = expected_revision.checked_add(1).ok_or_else(|| {
            WorkflowStoreError::InvalidValue("workflow revision overflow".to_string())
        })?;
        transaction.execute(
            "UPDATE workflow_meta SET revision = ?1 WHERE singleton = 1",
            [checked_revision_for_sql(next_revision)?],
        )?;
        transaction.commit()?;
        Ok(next_revision)
    }

    pub fn stage_task_inbox_import(
        &mut self,
        source: &TaskInboxSnapshot,
        workflow: &WorkflowSnapshot,
        source_checksum: &str,
        expected_revision: u64,
    ) -> Result<u64, WorkflowStoreError> {
        source.validate()?;
        let canonical_checksum = source_checksum.trim();
        if canonical_checksum.is_empty() || canonical_checksum.len() != source_checksum.len() {
            return Err(WorkflowStoreError::InvalidSourceChecksum);
        }
        let encoded = serde_json::to_string(source).map_err(|error| {
            WorkflowStoreError::InvalidValue(format!("failed to encode task inbox source: {error}"))
        })?;
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let actual_revision = query_revision(&transaction)?;
        let record_count = transaction.query_row(
            "SELECT (SELECT COUNT(*) FROM tasks) + (SELECT COUNT(*) FROM runs)",
            [],
            |row| row.get::<_, i64>(0),
        )?;
        let archive_count = transaction.query_row(
            "SELECT COUNT(*) FROM task_inbox_source_archive",
            [],
            |row| row.get::<_, i64>(0),
        )?;
        if actual_revision != expected_revision {
            return Err(WorkflowStoreError::Conflict {
                expected: expected_revision,
                actual: actual_revision,
            });
        }
        if expected_revision != 0 || record_count != 0 || archive_count != 0 {
            return Err(WorkflowStoreError::ImportRequiresEmptyWorkflow);
        }
        insert_snapshot_rows(&transaction, workflow)?;
        transaction.execute(
            "INSERT INTO task_inbox_source_archive (singleton, payload_json)
             VALUES (1, ?1)",
            [encoded],
        )?;
        transaction.execute(
            "UPDATE workflow_meta
             SET revision = 1, migration_state = 'staged', source_checksum = ?1
             WHERE singleton = 1",
            [canonical_checksum],
        )?;
        transaction.commit()?;
        Ok(1)
    }

    pub fn load_task_inbox_source(&self) -> Result<Option<TaskInboxSnapshot>, WorkflowStoreError> {
        load_task_inbox_document(&self.connection, "task_inbox_source_archive")
    }

    pub fn register_workflow_definition(
        &mut self,
        definition: &WorkflowDefinition,
    ) -> Result<(), WorkflowStoreError> {
        definition.validate()?;
        let encoded = encode_workflow_ir(definition)?;
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let existing = transaction
            .query_row(
                "SELECT payload_json FROM workflow_definitions
                 WHERE definition_id = ?1 AND version = ?2",
                params![definition.definition_id, i64::from(definition.version)],
                |row| row.get::<_, String>(0),
            )
            .optional()?;
        if let Some(existing) = existing {
            if existing != encoded {
                return Err(WorkflowStoreError::InvalidValue(
                    "Workflow Definition version is immutable".to_string(),
                ));
            }
            return Ok(());
        }
        transaction.execute(
            "INSERT INTO workflow_definitions (
                definition_id, version, payload_json, created_at
             ) VALUES (?1, ?2, ?3, ?4)",
            params![
                definition.definition_id,
                i64::from(definition.version),
                encoded,
                definition.created_at,
            ],
        )?;
        transaction.commit()?;
        Ok(())
    }

    pub fn load_workflow_definition(
        &self,
        definition_id: &str,
        version: u32,
    ) -> Result<Option<WorkflowDefinition>, WorkflowStoreError> {
        let encoded = self
            .connection
            .query_row(
                "SELECT payload_json FROM workflow_definitions
                 WHERE definition_id = ?1 AND version = ?2",
                params![definition_id, i64::from(version)],
                |row| row.get::<_, String>(0),
            )
            .optional()?;
        encoded
            .map(|encoded| decode_workflow_ir(&encoded, "Workflow Definition"))
            .transpose()
    }

    pub fn create_workflow_run(
        &mut self,
        run: &WorkflowRun,
    ) -> Result<WorkflowRun, WorkflowStoreError> {
        if run.revision != 0 {
            return Err(WorkflowStoreError::InvalidValue(
                "new Workflow Run revision must be zero".to_string(),
            ));
        }
        let definition = self
            .load_workflow_definition(&run.definition_id, run.definition_version)?
            .ok_or_else(|| {
                WorkflowStoreError::InvalidValue(
                    "Workflow Run references a missing Definition".to_string(),
                )
            })?;
        let canonical = WorkflowRun::new(run.run_id.clone(), &definition, run.created_at.clone())?;
        if run != &canonical {
            return Err(WorkflowStoreError::InvalidValue(
                "new Workflow Run must match the canonical Definition projection".to_string(),
            ));
        }
        let encoded = encode_workflow_ir(run)?;
        self.connection.execute(
            "INSERT INTO workflow_runs (
                run_id, definition_id, definition_version, revision,
                payload_json, created_at, updated_at
             ) VALUES (?1, ?2, ?3, 0, ?4, ?5, ?6)",
            params![
                run.run_id,
                run.definition_id,
                i64::from(run.definition_version),
                encoded,
                run.created_at,
                run.updated_at,
            ],
        )?;
        Ok(run.clone())
    }

    pub fn load_workflow_run(
        &self,
        run_id: &str,
    ) -> Result<Option<WorkflowRun>, WorkflowStoreError> {
        let encoded = self
            .connection
            .query_row(
                "SELECT payload_json FROM workflow_runs WHERE run_id = ?1",
                [run_id],
                |row| row.get::<_, String>(0),
            )
            .optional()?;
        let Some(encoded) = encoded else {
            return Ok(None);
        };
        let run: WorkflowRun = decode_workflow_ir(&encoded, "Workflow Run")?;
        let definition = self
            .load_workflow_definition(&run.definition_id, run.definition_version)?
            .ok_or_else(|| {
                WorkflowStoreError::InvalidValue(
                    "Workflow Run references a missing Definition".to_string(),
                )
            })?;
        run.validate(&definition)?;
        Ok(Some(run))
    }

    pub fn save_workflow_run(
        &mut self,
        run: &WorkflowRun,
        expected_revision: u64,
    ) -> Result<WorkflowRun, WorkflowStoreError> {
        if run.revision != expected_revision {
            return Err(WorkflowStoreError::Conflict {
                expected: expected_revision,
                actual: run.revision,
            });
        }
        let definition = self
            .load_workflow_definition(&run.definition_id, run.definition_version)?
            .ok_or_else(|| {
                WorkflowStoreError::InvalidValue(
                    "Workflow Run references a missing Definition".to_string(),
                )
            })?;
        run.validate(&definition)?;
        let mut committed = run.clone();
        committed.revision = expected_revision.checked_add(1).ok_or_else(|| {
            WorkflowStoreError::InvalidValue("Workflow Run revision overflow".to_string())
        })?;
        let encoded = encode_workflow_ir(&committed)?;
        let changed = self.connection.execute(
            "UPDATE workflow_runs
             SET revision = ?1, payload_json = ?2, updated_at = ?3
             WHERE run_id = ?4 AND revision = ?5",
            params![
                checked_revision_for_sql(committed.revision)?,
                encoded,
                committed.updated_at,
                committed.run_id,
                checked_revision_for_sql(expected_revision)?,
            ],
        )?;
        if changed != 1 {
            let actual = self
                .connection
                .query_row(
                    "SELECT revision FROM workflow_runs WHERE run_id = ?1",
                    [&committed.run_id],
                    |row| row.get::<_, i64>(0),
                )
                .optional()?
                .and_then(|value| u64::try_from(value).ok())
                .unwrap_or(0);
            return Err(WorkflowStoreError::Conflict {
                expected: expected_revision,
                actual,
            });
        }
        Ok(committed)
    }

    pub fn materialize_task_inbox(
        &mut self,
        current: &TaskInboxSnapshot,
        expected_revision: u64,
    ) -> Result<u64, WorkflowStoreError> {
        current.validate()?;
        let encoded = encode_current_task_inbox(current)?;
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let actual_revision = query_revision(&transaction)?;
        if actual_revision != expected_revision {
            return Err(WorkflowStoreError::Conflict {
                expected: expected_revision,
                actual: actual_revision,
            });
        }
        if query_migration_metadata(&transaction)?.phase != WorkflowMigrationPhase::Staged {
            return Err(WorkflowStoreError::MaterializeRequiresStagedMigration);
        }
        let current_count =
            transaction.query_row("SELECT COUNT(*) FROM task_inbox_current", [], |row| {
                row.get::<_, i64>(0)
            })?;
        if current_count != 0 {
            return Err(WorkflowStoreError::MaterializeRequiresStagedMigration);
        }
        let next_revision = expected_revision.checked_add(1).ok_or_else(|| {
            WorkflowStoreError::InvalidValue("workflow revision overflow".to_string())
        })?;
        transaction.execute(
            "INSERT INTO task_inbox_current (singleton, payload_json) VALUES (1, ?1)",
            [&encoded],
        )?;
        transaction.execute(
            "UPDATE workflow_meta SET revision = ?1, migration_state = 'ready'
             WHERE singleton = 1",
            [checked_revision_for_sql(next_revision)?],
        )?;
        sync_runtime_events(&transaction, current, None, None, None)?;
        insert_workflow_checkpoint(
            &transaction,
            next_revision,
            latest_runtime_event_sequence(&transaction)?,
            &encoded,
            &current.updated_at,
        )?;
        transaction.commit()?;
        Ok(next_revision)
    }

    pub fn load_current_task_inbox(&self) -> Result<Option<TaskInboxSnapshot>, WorkflowStoreError> {
        load_rebuilt_task_inbox(&self.connection)
    }

    pub fn activate_task_inbox(
        &mut self,
        expected_revision: u64,
    ) -> Result<u64, WorkflowStoreError> {
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        require_revision(&transaction, expected_revision)?;
        if query_migration_metadata(&transaction)?.phase != WorkflowMigrationPhase::Ready {
            return Err(WorkflowStoreError::ActivateRequiresReadyMigration);
        }
        let current_count =
            transaction.query_row("SELECT COUNT(*) FROM task_inbox_current", [], |row| {
                row.get::<_, i64>(0)
            })?;
        if current_count != 1 {
            return Err(WorkflowStoreError::ActivateRequiresReadyMigration);
        }
        let next_revision = next_revision(expected_revision)?;
        transaction.execute(
            "UPDATE workflow_meta SET revision = ?1, migration_state = 'active'
             WHERE singleton = 1",
            [checked_revision_for_sql(next_revision)?],
        )?;
        transaction.commit()?;
        Ok(next_revision)
    }

    pub fn save_active_task_inbox(
        &mut self,
        workflow: &WorkflowSnapshot,
        current: &TaskInboxSnapshot,
        expected_revision: u64,
    ) -> Result<u64, WorkflowStoreError> {
        let synchronized = current.synchronized_with_workflow(workflow)?;
        if synchronized != *current {
            return Err(WorkflowStoreError::InvalidValue(
                "TaskInbox projection disagrees with workflow authority".to_string(),
            ));
        }
        let encoded = encode_current_task_inbox(current)?;
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        require_revision(&transaction, expected_revision)?;
        if query_migration_metadata(&transaction)?.phase != WorkflowMigrationPhase::Active {
            return Err(WorkflowStoreError::TaskInboxNotActive);
        }
        transaction.execute("DELETE FROM runs", [])?;
        transaction.execute("DELETE FROM tasks", [])?;
        insert_snapshot_rows(&transaction, workflow)?;
        if transaction.execute(
            "UPDATE task_inbox_current SET payload_json = ?1 WHERE singleton = 1",
            [&encoded],
        )? != 1
        {
            return Err(WorkflowStoreError::InvalidValue(
                "active TaskInbox projection is missing".to_string(),
            ));
        }
        let next_revision = next_revision(expected_revision)?;
        transaction.execute(
            "UPDATE workflow_meta SET revision = ?1 WHERE singleton = 1",
            [checked_revision_for_sql(next_revision)?],
        )?;
        sync_runtime_events(&transaction, current, None, None, None)?;
        insert_workflow_checkpoint(
            &transaction,
            next_revision,
            latest_runtime_event_sequence(&transaction)?,
            &encoded,
            &current.updated_at,
        )?;
        transaction.commit()?;
        Ok(next_revision)
    }

    pub fn save_active_task_inbox_with_executor_lease(
        &mut self,
        workflow: &WorkflowSnapshot,
        current: &TaskInboxSnapshot,
        lease: &ExecutorLease,
        expected_revision: u64,
        idempotency_key: &IdempotencyKey,
        result_json: &str,
    ) -> Result<u64, WorkflowStoreError> {
        lease.validate()?;
        if !workflow.runs.iter().any(|run| run.id == lease.run_id) {
            return Err(WorkflowStoreError::InvalidValue(
                "executor lease references a missing Run".to_string(),
            ));
        }
        let synchronized = current.synchronized_with_workflow(workflow)?;
        if synchronized != *current {
            return Err(WorkflowStoreError::InvalidValue(
                "TaskInbox projection disagrees with workflow authority".to_string(),
            ));
        }
        let encoded = encode_current_task_inbox(current)?;
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        require_revision(&transaction, expected_revision)?;
        if query_migration_metadata(&transaction)?.phase != WorkflowMigrationPhase::Active {
            return Err(WorkflowStoreError::TaskInboxNotActive);
        }
        transaction.execute("DELETE FROM runs", [])?;
        transaction.execute("DELETE FROM tasks", [])?;
        insert_snapshot_rows(&transaction, workflow)?;
        if transaction.execute(
            "UPDATE task_inbox_current SET payload_json = ?1 WHERE singleton = 1",
            [&encoded],
        )? != 1
        {
            return Err(WorkflowStoreError::InvalidValue(
                "active TaskInbox projection is missing".to_string(),
            ));
        }
        insert_executor_lease(&transaction, lease)?;
        let next_revision = next_revision(expected_revision)?;
        transaction.execute(
            "UPDATE workflow_meta SET revision = ?1 WHERE singleton = 1",
            [checked_revision_for_sql(next_revision)?],
        )?;
        insert_idempotency_record(&transaction, idempotency_key, next_revision, result_json)?;
        sync_runtime_events(
            &transaction,
            current,
            Some(&lease.lease_id),
            Some(lease.generation),
            Some(&idempotency_key.command_id),
        )?;
        insert_workflow_checkpoint(
            &transaction,
            next_revision,
            latest_runtime_event_sequence(&transaction)?,
            &encoded,
            &current.updated_at,
        )?;
        transaction.commit()?;
        Ok(next_revision)
    }

    pub fn save_active_task_inbox_as_executor(
        &mut self,
        workflow: &WorkflowSnapshot,
        current: &TaskInboxSnapshot,
        context: &ExecutorCommandContext,
        expected_revision: u64,
        idempotency_key: &IdempotencyKey,
        result_json: &str,
    ) -> Result<u64, WorkflowStoreError> {
        context.validate()?;
        let synchronized = current.synchronized_with_workflow(workflow)?;
        if synchronized != *current {
            return Err(WorkflowStoreError::InvalidValue(
                "TaskInbox projection disagrees with workflow authority".to_string(),
            ));
        }
        let encoded = encode_current_task_inbox(current)?;
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        require_revision(&transaction, expected_revision)?;
        if query_migration_metadata(&transaction)?.phase != WorkflowMigrationPhase::Active {
            return Err(WorkflowStoreError::TaskInboxNotActive);
        }
        load_and_match_executor_context(&transaction, context, true)?;
        transaction.execute("DELETE FROM runs", [])?;
        transaction.execute("DELETE FROM tasks", [])?;
        insert_snapshot_rows(&transaction, workflow)?;
        if transaction.execute(
            "UPDATE task_inbox_current SET payload_json = ?1 WHERE singleton = 1",
            [&encoded],
        )? != 1
        {
            return Err(WorkflowStoreError::InvalidValue(
                "active TaskInbox projection is missing".to_string(),
            ));
        }
        let next_revision = next_revision(expected_revision)?;
        transaction.execute(
            "UPDATE workflow_meta SET revision = ?1 WHERE singleton = 1",
            [checked_revision_for_sql(next_revision)?],
        )?;
        insert_idempotency_record(&transaction, idempotency_key, next_revision, result_json)?;
        sync_runtime_events(
            &transaction,
            current,
            Some(&context.executor_lease_id),
            Some(context.generation),
            Some(&context.command_id),
        )?;
        insert_workflow_checkpoint(
            &transaction,
            next_revision,
            latest_runtime_event_sequence(&transaction)?,
            &encoded,
            &current.updated_at,
        )?;
        transaction.commit()?;
        Ok(next_revision)
    }

    pub fn append_runtime_events_as_executor(
        &mut self,
        current: &TaskInboxSnapshot,
        events: &[InboxEventRecord],
        projection_updated_at: &str,
        context: &ExecutorCommandContext,
        expected_revision: u64,
        idempotency_key: &IdempotencyKey,
    ) -> Result<RuntimeEventAppendReceipt, WorkflowStoreError> {
        context.validate()?;
        validate_runtime_event_batch(events)?;
        if events.iter().any(|event| event.run_id != context.run_id) {
            return Err(ExecutionError::LeaseRunMismatch.into());
        }
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        require_revision(&transaction, expected_revision)?;
        if query_migration_metadata(&transaction)?.phase != WorkflowMigrationPhase::Active {
            return Err(WorkflowStoreError::TaskInboxNotActive);
        }
        load_and_match_executor_context(&transaction, context, true)?;
        let receipt = append_runtime_event_rows(
            &transaction,
            events,
            projection_updated_at,
            Some(&context.executor_lease_id),
            Some(context.generation),
            Some(&context.command_id),
            expected_revision,
        )?;
        transaction.execute(
            "UPDATE workflow_meta SET revision = ?1 WHERE singleton = 1",
            [checked_revision_for_sql(receipt.revision)?],
        )?;
        maybe_checkpoint_runtime_events(&transaction, current, &receipt)?;
        let result_json = encode_idempotency_result(&receipt)?;
        insert_idempotency_record(
            &transaction,
            idempotency_key,
            receipt.revision,
            &result_json,
        )?;
        transaction.commit()?;
        Ok(receipt)
    }

    pub fn append_runtime_events(
        &mut self,
        current: &TaskInboxSnapshot,
        events: &[InboxEventRecord],
        projection_updated_at: &str,
        expected_revision: u64,
    ) -> Result<RuntimeEventAppendReceipt, WorkflowStoreError> {
        validate_runtime_event_batch(events)?;
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        require_revision(&transaction, expected_revision)?;
        if query_migration_metadata(&transaction)?.phase != WorkflowMigrationPhase::Active {
            return Err(WorkflowStoreError::TaskInboxNotActive);
        }
        let receipt = append_runtime_event_rows(
            &transaction,
            events,
            projection_updated_at,
            None,
            None,
            None,
            expected_revision,
        )?;
        transaction.execute(
            "UPDATE workflow_meta SET revision = ?1 WHERE singleton = 1",
            [checked_revision_for_sql(receipt.revision)?],
        )?;
        maybe_checkpoint_runtime_events(&transaction, current, &receipt)?;
        transaction.commit()?;
        Ok(receipt)
    }

    pub fn runtime_events(
        &self,
        run_id: &str,
        after_sequence: u64,
        limit: usize,
    ) -> Result<RuntimeEventPage, WorkflowStoreError> {
        if run_id.is_empty() || run_id.trim() != run_id {
            return Err(WorkflowStoreError::InvalidValue(
                "runtime event runId must be canonical non-empty text".to_string(),
            ));
        }
        if limit == 0 || limit > MAX_RUNTIME_EVENT_QUERY_LIMIT {
            return Err(WorkflowStoreError::InvalidRuntimeEventQueryLimit(
                MAX_RUNTIME_EVENT_QUERY_LIMIT,
            ));
        }
        query_runtime_event_page(&self.connection, run_id, after_sequence, limit)
    }

    pub fn latest_runtime_event_sequence(&self) -> Result<u64, WorkflowStoreError> {
        latest_runtime_event_sequence(&self.connection)
    }

    pub fn latest_checkpoint_sequence(&self) -> Result<u64, WorkflowStoreError> {
        latest_checkpoint_sequence(&self.connection)
    }

    pub fn idempotency_record(
        &self,
        key: &IdempotencyKey,
    ) -> Result<Option<IdempotencyRecord>, WorkflowStoreError> {
        load_idempotency_record(&self.connection, key)
    }

    pub fn record_idempotency_result(
        &mut self,
        key: &IdempotencyKey,
        result_revision: u64,
        result_json: &str,
    ) -> Result<(), WorkflowStoreError> {
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        if load_idempotency_record(&transaction, key)?.is_none() {
            insert_idempotency_record(&transaction, key, result_revision, result_json)?;
        }
        transaction.commit()?;
        Ok(())
    }

    pub fn executor_lease_for_run(
        &self,
        run_id: &str,
    ) -> Result<Option<ExecutorLease>, WorkflowStoreError> {
        load_executor_lease_for_run(&self.connection, run_id)
    }

    pub fn validate_executor_context(
        &self,
        context: &ExecutorCommandContext,
    ) -> Result<ExecutorLease, WorkflowStoreError> {
        context.validate()?;
        validate_executor_context_on(&self.connection, context)
    }

    pub fn apply_executor_lease_command(
        &mut self,
        command: &ExecutorLeaseCommand,
    ) -> Result<ExecutorLease, WorkflowStoreError> {
        command.validate()?;
        let command_type = match command.operation {
            ExecutorLeaseOperation::AcknowledgeStart => "executor.acknowledge_start",
            ExecutorLeaseOperation::Heartbeat => "executor.heartbeat",
            ExecutorLeaseOperation::Release => "executor.release",
            ExecutorLeaseOperation::Cancel => "executor.cancel",
            ExecutorLeaseOperation::MarkOrphaned => "executor.mark_orphaned",
        };
        let key = IdempotencyKey::for_payload(
            &command.context.command_id,
            command_type,
            &command.context.now,
            command,
        )?;
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        if let Some(record) = load_idempotency_record(&transaction, &key)? {
            return decode_idempotency_result(&record);
        }
        let mut lease = load_and_match_executor_context(
            &transaction,
            &command.context,
            command.operation != ExecutorLeaseOperation::MarkOrphaned,
        )?;
        if matches!(
            command.operation,
            ExecutorLeaseOperation::AcknowledgeStart | ExecutorLeaseOperation::Heartbeat
        ) && !run_accepts_executor_commands(&transaction, &command.context.run_id)?
        {
            return Err(ExecutionError::LeaseInactive.into());
        }
        match command.operation {
            ExecutorLeaseOperation::AcknowledgeStart => {
                if !matches!(
                    lease.state,
                    ExecutorLeaseState::Claimed | ExecutorLeaseState::Starting
                ) || lease.start_acknowledged_at.is_some()
                {
                    return Err(ExecutionError::LeaseInactive.into());
                }
                require_monotonic_lease_window(
                    &lease,
                    &command.context.now,
                    command.next_expires_at.as_deref(),
                )?;
                lease.start_acknowledged_at = Some(command.context.now.clone());
                lease.last_heartbeat_at.clone_from(&command.context.now);
                lease.expires_at =
                    command
                        .next_expires_at
                        .clone()
                        .ok_or(WorkflowStoreError::Execution(
                            ExecutionError::MissingLeaseExpiry,
                        ))?;
                lease.state = ExecutorLeaseState::Active;
            }
            ExecutorLeaseOperation::Heartbeat => {
                if lease.state != ExecutorLeaseState::Active {
                    return Err(ExecutionError::LeaseInactive.into());
                }
                require_monotonic_lease_window(
                    &lease,
                    &command.context.now,
                    command.next_expires_at.as_deref(),
                )?;
                lease.last_heartbeat_at.clone_from(&command.context.now);
                lease.expires_at =
                    command
                        .next_expires_at
                        .clone()
                        .ok_or(WorkflowStoreError::Execution(
                            ExecutionError::MissingLeaseExpiry,
                        ))?;
            }
            ExecutorLeaseOperation::Release | ExecutorLeaseOperation::Cancel => {
                lease.released_at = Some(command.context.now.clone());
                lease.state = ExecutorLeaseState::Released;
            }
            ExecutorLeaseOperation::MarkOrphaned => {
                if !lease.is_expired_at(&command.context.now)? {
                    return Err(ExecutionError::LeaseInactive.into());
                }
                lease.released_at = Some(command.context.now.clone());
                lease.state = ExecutorLeaseState::Expired;
            }
        }
        update_executor_lease(&transaction, &lease)?;
        let result_json = encode_idempotency_result(&lease)?;
        insert_idempotency_record(
            &transaction,
            &key,
            query_revision(&transaction)?,
            &result_json,
        )?;
        transaction.commit()?;
        Ok(lease)
    }

    pub fn takeover_executor_lease(
        &mut self,
        request: &ExecutorTakeoverRequest,
    ) -> Result<ExecutorLease, WorkflowStoreError> {
        request.validate()?;
        let key = IdempotencyKey::for_payload(
            &request.command_id,
            "executor.takeover",
            &request.now,
            request,
        )?;
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        if let Some(record) = load_idempotency_record(&transaction, &key)? {
            return decode_idempotency_result(&record);
        }
        let mut previous = load_executor_lease_for_run(&transaction, &request.run_id)?
            .ok_or(ExecutionError::UnknownLease)?;
        if previous.lease_id != request.previous_lease_id {
            return Err(ExecutionError::UnknownLease.into());
        }
        if !previous.is_expired_at(&request.now)? {
            return Err(ExecutionError::TakeoverBeforeExpiry.into());
        }
        previous.state = ExecutorLeaseState::Superseded;
        previous.released_at = Some(request.now.clone());
        update_executor_lease(&transaction, &previous)?;
        let generation = previous.generation.checked_add(1).ok_or_else(|| {
            WorkflowStoreError::InvalidValue("executor lease generation overflow".to_string())
        })?;
        let lease = ExecutorLease {
            lease_id: request.executor_lease_id.clone(),
            run_id: request.run_id.clone(),
            executor_id: request.executor_id.clone(),
            generation,
            reservation_id: request.reservation_id.clone(),
            acquired_at: request.now.clone(),
            expires_at: request.expires_at.clone(),
            last_heartbeat_at: request.now.clone(),
            start_acknowledged_at: None,
            released_at: None,
            state: ExecutorLeaseState::Claimed,
        };
        lease.validate()?;
        insert_executor_lease(&transaction, &lease)?;
        let result_json = encode_idempotency_result(&lease)?;
        insert_idempotency_record(
            &transaction,
            &key,
            query_revision(&transaction)?,
            &result_json,
        )?;
        transaction.commit()?;
        Ok(lease)
    }

    pub fn migration_metadata(&self) -> Result<WorkflowMigrationMetadata, WorkflowStoreError> {
        query_migration_metadata(&self.connection)
    }

    pub fn load_snapshot(&self) -> Result<WorkflowSnapshot, WorkflowStoreError> {
        load_snapshot_from(&self.connection)
    }

    pub fn load_versioned_snapshot(
        &mut self,
    ) -> Result<VersionedWorkflowSnapshot, WorkflowStoreError> {
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Deferred)?;
        let revision = query_revision(&transaction)?;
        let snapshot = load_snapshot_from(&transaction)?;
        transaction.commit()?;
        Ok(VersionedWorkflowSnapshot { revision, snapshot })
    }

    pub fn revision(&self) -> Result<u64, WorkflowStoreError> {
        query_revision(&self.connection)
    }

    /// Classify runs that depended on the previous process authority.
    /// User-input and human-review waits remain durable UI work and are not
    /// treated as interrupted execution.
    #[allow(clippy::too_many_lines)]
    pub fn recover_interrupted(&mut self) -> Result<RecoveryReport, WorkflowStoreError> {
        let detected_at =
            DateTime::<Utc>::from(SystemTime::now()).to_rfc3339_opts(SecondsFormat::Millis, true);
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let revision = query_revision(&transaction)?;
        let mut statement = transaction.prepare(
            "SELECT t.id, r.id, r.status
             FROM tasks t
             JOIN runs r ON r.id = t.current_run_id AND r.task_id = t.id
             WHERE t.status IN (
                 'dispatched', 'running', 'blocked_on_permission', 'collecting_artifacts'
             ) AND r.status IN (
                 'dispatched', 'running', 'waiting_permission', 'collecting_artifacts'
             )
             ORDER BY t.id, r.id",
        )?;
        let interrupted = statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        drop(statement);
        let current = load_rebuilt_task_inbox(&transaction)?;
        let mut runs = Vec::with_capacity(interrupted.len());
        for (task_id, run_id, previous_state) in interrupted {
            let lease = load_executor_lease_for_run(&transaction, &run_id)?;
            let run_projection = current
                .as_ref()
                .and_then(|snapshot| snapshot.runs.iter().find(|run| run.id == run_id));
            let has_execution_evidence = current.as_ref().is_some_and(|snapshot| {
                snapshot.events.iter().any(|event| {
                    event.run_id == run_id && event.kind != crate::InboxEventKind::System
                }) || snapshot
                    .artifacts
                    .iter()
                    .any(|artifact| artifact.run_id == run_id)
            });
            let decision = classify_interrupted_run(
                &previous_state,
                lease.as_ref(),
                run_projection.and_then(|run| run.session_id.as_deref()),
                run_projection.is_some_and(|run| run.prompt_snapshot.is_some()),
                has_execution_evidence,
            );
            match decision.product_state {
                RecoveryProductState::Requeue => {
                    transaction
                        .execute("UPDATE runs SET status = 'failed' WHERE id = ?1", [&run_id])?;
                    transaction.execute(
                        "UPDATE tasks
                         SET status = 'queued', current_run_id = NULL
                         WHERE id = ?1 AND current_run_id = ?2",
                        params![task_id, run_id],
                    )?;
                }
                RecoveryProductState::HumanReview => {
                    transaction.execute(
                        "UPDATE runs SET status = 'needs_human_review' WHERE id = ?1",
                        [&run_id],
                    )?;
                    transaction.execute(
                        "UPDATE tasks SET status = 'needs_human_review'
                         WHERE id = ?1 AND current_run_id = ?2",
                        params![task_id, run_id],
                    )?;
                }
            }
            if let Some(lease) = &lease
                && lease.state.accepts_mutation()
            {
                transaction.execute(
                    "UPDATE executor_leases
                     SET state = 'expired', released_at = ?1
                     WHERE lease_id = ?2 AND generation = ?3",
                    params![
                        detected_at,
                        lease.lease_id,
                        checked_revision_for_sql(lease.generation)?,
                    ],
                )?;
            }
            let record = RunRecoveryRecord {
                task_id: task_id.clone(),
                run_id: run_id.clone(),
                previous_state,
                recovery_state: decision.recovery_state,
                reason: decision.reason.to_string(),
                prompt_submission_state: decision.prompt_submission_state,
                workspace_mutation_possibility: decision.workspace_mutation_possibility,
                suggested_action: decision.suggested_action,
                executor_lease_id: lease.as_ref().map(|lease| lease.lease_id.clone()),
            };
            insert_recovery_record(
                &transaction,
                &format!("recovery-{}", Uuid::new_v4()),
                &record,
                &detected_at,
            )?;
            runs.push(record);
        }
        if !runs.is_empty() {
            let migration = query_migration_metadata(&transaction)?;
            if matches!(
                migration.phase,
                WorkflowMigrationPhase::Ready | WorkflowMigrationPhase::Active
            ) {
                let workflow = load_snapshot_from(&transaction)?;
                let current = load_rebuilt_task_inbox(&transaction)?.ok_or_else(|| {
                    WorkflowStoreError::InvalidValue(
                        "materialized TaskInbox projection is missing".to_string(),
                    )
                })?;
                let synchronized = current.synchronized_with_workflow(&workflow)?;
                let encoded = encode_current_task_inbox(&synchronized)?;
                transaction.execute(
                    "UPDATE task_inbox_current SET payload_json = ?1 WHERE singleton = 1",
                    [&encoded],
                )?;
                sync_runtime_events(&transaction, &synchronized, None, None, None)?;
                insert_workflow_checkpoint(
                    &transaction,
                    next_revision(revision)?,
                    latest_runtime_event_sequence(&transaction)?,
                    &encoded,
                    &synchronized.updated_at,
                )?;
            }
            let next_revision = revision.checked_add(1).ok_or_else(|| {
                WorkflowStoreError::InvalidValue("workflow revision overflow".to_string())
            })?;
            transaction.execute(
                "UPDATE workflow_meta SET revision = ?1 WHERE singleton = 1",
                [checked_revision_for_sql(next_revision)?],
            )?;
        }
        transaction.commit()?;
        Ok(RecoveryReport { detected_at, runs })
    }

    fn initialize(&mut self) -> Result<(), WorkflowStoreError> {
        self.connection.busy_timeout(Duration::from_secs(5))?;
        self.connection.execute_batch(
            "PRAGMA foreign_keys = ON;
             PRAGMA trusted_schema = OFF;
             PRAGMA secure_delete = ON;
             PRAGMA journal_mode = WAL;
             PRAGMA synchronous = FULL;",
        )?;
        let version = self
            .connection
            .query_row("PRAGMA user_version", [], |row| row.get::<_, i64>(0))?;
        if version > SCHEMA_VERSION {
            return Err(WorkflowStoreError::UnsupportedSchema(version));
        }
        match version {
            0 => {
                create_schema_v5(&mut self.connection)?;
                migrate_v5_to_v6(&mut self.connection)?;
                migrate_v6_to_v7(&mut self.connection)?;
                migrate_v7_to_v8(&mut self.connection)?;
            }
            1 => {
                migrate_v1_to_v5(&mut self.connection)?;
                migrate_v5_to_v6(&mut self.connection)?;
                migrate_v6_to_v7(&mut self.connection)?;
                migrate_v7_to_v8(&mut self.connection)?;
            }
            2 => {
                migrate_v2_to_v5(&mut self.connection)?;
                migrate_v5_to_v6(&mut self.connection)?;
                migrate_v6_to_v7(&mut self.connection)?;
                migrate_v7_to_v8(&mut self.connection)?;
            }
            3 => {
                migrate_v3_to_v5(&mut self.connection)?;
                migrate_v5_to_v6(&mut self.connection)?;
                migrate_v6_to_v7(&mut self.connection)?;
                migrate_v7_to_v8(&mut self.connection)?;
            }
            4 => {
                migrate_v4_to_v5(&mut self.connection)?;
                migrate_v5_to_v6(&mut self.connection)?;
                migrate_v6_to_v7(&mut self.connection)?;
                migrate_v7_to_v8(&mut self.connection)?;
            }
            5 => {
                migrate_v5_to_v6(&mut self.connection)?;
                migrate_v6_to_v7(&mut self.connection)?;
                migrate_v7_to_v8(&mut self.connection)?;
            }
            6 => {
                migrate_v6_to_v7(&mut self.connection)?;
                migrate_v7_to_v8(&mut self.connection)?;
            }
            7 => migrate_v7_to_v8(&mut self.connection)?,
            _ => {}
        }
        if version < 9 {
            migrate_v8_to_v9(&mut self.connection)?;
        }
        Ok(())
    }
}

const WORKFLOW_META_V5_SQL: &str = "CREATE TABLE workflow_meta (
        singleton INTEGER PRIMARY KEY NOT NULL CHECK (singleton = 1),
        revision INTEGER NOT NULL CHECK (revision >= 0),
        migration_state TEXT NOT NULL
            CHECK (migration_state IN ('native', 'staged', 'ready', 'active')),
        source_checksum TEXT
     ) STRICT;
     INSERT INTO workflow_meta (
        singleton, revision, migration_state, source_checksum
     ) VALUES (1, 0, 'native', NULL);
     CREATE TABLE task_inbox_source_archive (
        singleton INTEGER PRIMARY KEY NOT NULL CHECK (singleton = 1),
        payload_json TEXT NOT NULL
     ) STRICT;
     CREATE TABLE task_inbox_current (
        singleton INTEGER PRIMARY KEY NOT NULL CHECK (singleton = 1),
        payload_json TEXT NOT NULL
     ) STRICT;
     PRAGMA user_version = 5;";

fn create_schema_v5(connection: &mut Connection) -> Result<(), WorkflowStoreError> {
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    transaction.execute_batch(
        "CREATE TABLE tasks (
            id TEXT PRIMARY KEY NOT NULL,
            workspace_path TEXT NOT NULL,
            agent_name TEXT NOT NULL,
            status TEXT NOT NULL,
            attempt INTEGER NOT NULL CHECK (attempt >= 0),
            current_run_id TEXT
         ) STRICT;
         CREATE TABLE runs (
            id TEXT PRIMARY KEY NOT NULL,
            task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
            attempt INTEGER NOT NULL CHECK (attempt > 0),
            status TEXT NOT NULL
         ) STRICT;
         CREATE INDEX runs_task_id ON runs(task_id);",
    )?;
    transaction.execute_batch(WORKFLOW_META_V5_SQL)?;
    transaction.commit()?;
    Ok(())
}

fn migrate_v1_to_v5(connection: &mut Connection) -> Result<(), WorkflowStoreError> {
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    transaction.execute_batch(WORKFLOW_META_V5_SQL)?;
    transaction.commit()?;
    Ok(())
}

fn migrate_v2_to_v5(connection: &mut Connection) -> Result<(), WorkflowStoreError> {
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    transaction.execute_batch(
        "ALTER TABLE workflow_meta ADD COLUMN migration_state TEXT NOT NULL
            DEFAULT 'native'
            CHECK (migration_state IN ('native', 'staged', 'ready', 'active'));
         ALTER TABLE workflow_meta ADD COLUMN source_checksum TEXT;
         CREATE TABLE task_inbox_source_archive (
            singleton INTEGER PRIMARY KEY NOT NULL CHECK (singleton = 1),
            payload_json TEXT NOT NULL
         ) STRICT;
         CREATE TABLE task_inbox_current (
            singleton INTEGER PRIMARY KEY NOT NULL CHECK (singleton = 1),
            payload_json TEXT NOT NULL
         ) STRICT;
         PRAGMA user_version = 5;",
    )?;
    transaction.commit()?;
    Ok(())
}

fn migrate_v3_to_v5(connection: &mut Connection) -> Result<(), WorkflowStoreError> {
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    transaction.execute_batch(
        "ALTER TABLE workflow_meta RENAME TO workflow_meta_v3;
         CREATE TABLE workflow_meta (
            singleton INTEGER PRIMARY KEY NOT NULL CHECK (singleton = 1),
            revision INTEGER NOT NULL CHECK (revision >= 0),
            migration_state TEXT NOT NULL
                CHECK (migration_state IN ('native', 'staged', 'ready', 'active')),
            source_checksum TEXT
         ) STRICT;
         INSERT INTO workflow_meta (
            singleton, revision, migration_state, source_checksum
         ) SELECT singleton, revision, migration_state, source_checksum
           FROM workflow_meta_v3;
         DROP TABLE workflow_meta_v3;
         CREATE TABLE task_inbox_current (
            singleton INTEGER PRIMARY KEY NOT NULL CHECK (singleton = 1),
            payload_json TEXT NOT NULL
         ) STRICT;
         PRAGMA user_version = 5;",
    )?;
    transaction.commit()?;
    Ok(())
}

fn migrate_v4_to_v5(connection: &mut Connection) -> Result<(), WorkflowStoreError> {
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    transaction.execute_batch(
        "ALTER TABLE workflow_meta RENAME TO workflow_meta_v4;
         CREATE TABLE workflow_meta (
            singleton INTEGER PRIMARY KEY NOT NULL CHECK (singleton = 1),
            revision INTEGER NOT NULL CHECK (revision >= 0),
            migration_state TEXT NOT NULL
                CHECK (migration_state IN ('native', 'staged', 'ready', 'active')),
            source_checksum TEXT
         ) STRICT;
         INSERT INTO workflow_meta (
            singleton, revision, migration_state, source_checksum
         ) SELECT singleton, revision, migration_state, source_checksum
           FROM workflow_meta_v4;
         DROP TABLE workflow_meta_v4;
         PRAGMA user_version = 5;",
    )?;
    transaction.commit()?;
    Ok(())
}

fn migrate_v5_to_v6(connection: &mut Connection) -> Result<(), WorkflowStoreError> {
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    transaction.execute_batch(
        "CREATE TABLE executor_leases (
            lease_id TEXT PRIMARY KEY NOT NULL,
            run_id TEXT NOT NULL,
            executor_id TEXT NOT NULL,
            generation INTEGER NOT NULL CHECK (generation > 0),
            reservation_id TEXT NOT NULL,
            acquired_at TEXT NOT NULL,
            expires_at TEXT NOT NULL,
            last_heartbeat_at TEXT NOT NULL,
            start_acknowledged_at TEXT,
            released_at TEXT,
            state TEXT NOT NULL CHECK (
                state IN ('claimed', 'starting', 'active', 'expired', 'released', 'superseded')
            )
         ) STRICT;
         CREATE UNIQUE INDEX executor_leases_active_run_generation
             ON executor_leases(run_id, generation);
         CREATE INDEX executor_leases_run ON executor_leases(run_id, generation DESC);
         PRAGMA user_version = 6;",
    )?;
    transaction.commit()?;
    Ok(())
}

fn migrate_v6_to_v7(connection: &mut Connection) -> Result<(), WorkflowStoreError> {
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    transaction.execute_batch(
        "CREATE TABLE idempotency_records (
            command_id TEXT PRIMARY KEY NOT NULL,
            command_type TEXT NOT NULL,
            payload_hash TEXT NOT NULL,
            result_revision INTEGER NOT NULL CHECK (result_revision >= 0),
            result_json TEXT NOT NULL,
            created_at TEXT NOT NULL
         ) STRICT;
         CREATE INDEX idempotency_records_created_at
             ON idempotency_records(created_at, command_id);
         CREATE TABLE recovery_records (
            recovery_id TEXT PRIMARY KEY NOT NULL,
            task_id TEXT NOT NULL,
            run_id TEXT NOT NULL,
            previous_state TEXT NOT NULL,
            recovery_state TEXT NOT NULL CHECK (
                recovery_state IN ('requeued', 'orphaned', 'waiting', 'review_required', 'terminal')
            ),
            reason TEXT NOT NULL,
            prompt_submission_state TEXT NOT NULL CHECK (
                prompt_submission_state IN ('not_submitted', 'submitted', 'unknown', 'not_applicable')
            ),
            workspace_mutation_possibility TEXT NOT NULL CHECK (
                workspace_mutation_possibility IN ('none', 'read_only', 'possible', 'confirmed', 'unknown')
            ),
            suggested_action TEXT NOT NULL CHECK (
                suggested_action IN ('requeue', 'resume_session', 'retry_read_only', 'human_review', 'keep_waiting', 'terminal')
            ),
            executor_lease_id TEXT,
            detected_at TEXT NOT NULL,
            resolved_at TEXT
         ) STRICT;
         CREATE UNIQUE INDEX recovery_records_unresolved_run
             ON recovery_records(run_id) WHERE resolved_at IS NULL;
         PRAGMA user_version = 7;",
    )?;
    transaction.commit()?;
    Ok(())
}

fn migrate_v7_to_v8(connection: &mut Connection) -> Result<(), WorkflowStoreError> {
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    transaction.execute_batch(
        "CREATE TABLE runtime_events (
            sequence INTEGER PRIMARY KEY AUTOINCREMENT,
            event_id TEXT NOT NULL UNIQUE,
            task_id TEXT NOT NULL,
            run_id TEXT NOT NULL,
            executor_lease_id TEXT,
            executor_generation INTEGER CHECK (executor_generation > 0),
            command_id TEXT,
            event_type TEXT NOT NULL,
            payload_json TEXT NOT NULL,
            created_at TEXT NOT NULL,
            projection_updated_at TEXT NOT NULL
         ) STRICT;
         CREATE INDEX runtime_events_run_sequence
             ON runtime_events(run_id, sequence);
         CREATE INDEX runtime_events_task_sequence
             ON runtime_events(task_id, sequence);
         CREATE TABLE workflow_snapshots (
            snapshot_id INTEGER PRIMARY KEY AUTOINCREMENT,
            workflow_revision INTEGER NOT NULL CHECK (workflow_revision >= 0),
            covered_event_sequence INTEGER NOT NULL CHECK (covered_event_sequence >= 0),
            task_inbox_json TEXT NOT NULL,
            created_at TEXT NOT NULL
         ) STRICT;
         CREATE INDEX workflow_snapshots_revision
             ON workflow_snapshots(workflow_revision DESC, snapshot_id DESC);",
    )?;
    if let Some(current) = load_task_inbox_document(&transaction, "task_inbox_current")? {
        for event in &current.events {
            insert_runtime_event_row(
                &transaction,
                event,
                &current.updated_at,
                None,
                None,
                None,
                false,
            )?;
        }
        let covered_sequence = latest_runtime_event_sequence(&transaction)?;
        let revision = query_revision(&transaction)?;
        let encoded = encode_current_task_inbox(&current)?;
        insert_workflow_checkpoint(
            &transaction,
            revision,
            covered_sequence,
            &encoded,
            &current.updated_at,
        )?;
    }
    transaction.execute_batch("PRAGMA user_version = 8;")?;
    transaction.commit()?;
    Ok(())
}

fn migrate_v8_to_v9(connection: &mut Connection) -> Result<(), WorkflowStoreError> {
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    transaction.execute_batch(
        "CREATE TABLE workflow_definitions (
            definition_id TEXT NOT NULL,
            version INTEGER NOT NULL CHECK (version > 0),
            payload_json TEXT NOT NULL,
            created_at TEXT NOT NULL,
            PRIMARY KEY (definition_id, version)
         ) STRICT;
         CREATE TABLE workflow_runs (
            run_id TEXT PRIMARY KEY NOT NULL,
            definition_id TEXT NOT NULL,
            definition_version INTEGER NOT NULL CHECK (definition_version > 0),
            revision INTEGER NOT NULL CHECK (revision >= 0),
            payload_json TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            FOREIGN KEY (definition_id, definition_version)
                REFERENCES workflow_definitions(definition_id, version)
         ) STRICT;
         CREATE INDEX workflow_runs_definition
             ON workflow_runs(definition_id, definition_version, updated_at);
         PRAGMA user_version = 9;",
    )?;
    transaction.commit()?;
    Ok(())
}

fn insert_snapshot_rows(
    transaction: &Transaction<'_>,
    snapshot: &WorkflowSnapshot,
) -> Result<(), WorkflowStoreError> {
    for task in &snapshot.tasks {
        transaction.execute(
            "INSERT INTO tasks (
                id, workspace_path, agent_name, status, attempt, current_run_id
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![
                task.id,
                task.workspace_path,
                task.agent_name,
                task_status_name(task.status),
                i64::from(task.attempt),
                task.current_run_id,
            ],
        )?;
    }
    for run in &snapshot.runs {
        transaction.execute(
            "INSERT INTO runs (id, task_id, attempt, status)
             VALUES (?1, ?2, ?3, ?4)",
            params![
                run.id,
                run.task_id,
                i64::from(run.attempt),
                run_status_name(run.status),
            ],
        )?;
    }
    Ok(())
}

fn load_idempotency_record(
    connection: &Connection,
    key: &IdempotencyKey,
) -> Result<Option<IdempotencyRecord>, WorkflowStoreError> {
    let record = connection
        .query_row(
            "SELECT command_id, command_type, payload_hash, result_revision,
                    result_json, created_at
             FROM idempotency_records WHERE command_id = ?1",
            [&key.command_id],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, i64>(3)?,
                    row.get::<_, String>(4)?,
                    row.get::<_, String>(5)?,
                ))
            },
        )
        .optional()?;
    let Some((
        command_id,
        command_type,
        payload_hash,
        result_revision,
        result_projection,
        created_at,
    )) = record
    else {
        return Ok(None);
    };
    if command_type != key.command_type || payload_hash != key.payload_hash {
        return Err(ExecutionError::IdempotencyConflict.into());
    }
    let result_revision = u64::try_from(result_revision).map_err(|_| {
        WorkflowStoreError::InvalidValue(
            "idempotency result revision is outside u64 range".to_string(),
        )
    })?;
    Ok(Some(IdempotencyRecord {
        command_id,
        command_type,
        payload_hash,
        result_revision,
        result_projection,
        created_at,
    }))
}

fn validate_runtime_event_batch(events: &[InboxEventRecord]) -> Result<(), WorkflowStoreError> {
    if events.is_empty() || events.len() > MAX_RUNTIME_EVENT_APPEND_BATCH {
        return Err(WorkflowStoreError::RuntimeEventBatchTooLarge);
    }
    Ok(())
}

fn append_runtime_event_rows(
    transaction: &Transaction<'_>,
    events: &[InboxEventRecord],
    projection_updated_at: &str,
    executor_lease_id: Option<&str>,
    executor_generation: Option<u64>,
    command_id: Option<&str>,
    expected_revision: u64,
) -> Result<RuntimeEventAppendReceipt, WorkflowStoreError> {
    let mut sequences = Vec::with_capacity(events.len());
    for event in events {
        sequences.push(insert_runtime_event_row(
            transaction,
            event,
            projection_updated_at,
            executor_lease_id,
            executor_generation,
            command_id,
            false,
        )?);
    }
    Ok(RuntimeEventAppendReceipt {
        revision: next_revision(expected_revision)?,
        first_sequence: *sequences
            .first()
            .ok_or(WorkflowStoreError::RuntimeEventBatchTooLarge)?,
        last_sequence: *sequences
            .last()
            .ok_or(WorkflowStoreError::RuntimeEventBatchTooLarge)?,
        event_ids: events.iter().map(|event| event.id.clone()).collect(),
    })
}

fn sync_runtime_events(
    transaction: &Transaction<'_>,
    current: &TaskInboxSnapshot,
    executor_lease_id: Option<&str>,
    executor_generation: Option<u64>,
    command_id: Option<&str>,
) -> Result<(), WorkflowStoreError> {
    for event in &current.events {
        insert_runtime_event_row(
            transaction,
            event,
            &current.updated_at,
            executor_lease_id,
            executor_generation,
            command_id,
            true,
        )?;
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn insert_runtime_event_row(
    transaction: &Transaction<'_>,
    event: &InboxEventRecord,
    projection_updated_at: &str,
    executor_lease_id: Option<&str>,
    executor_generation: Option<u64>,
    command_id: Option<&str>,
    allow_existing: bool,
) -> Result<u64, WorkflowStoreError> {
    let payload_json = serde_json::to_string(event).map_err(|error| {
        WorkflowStoreError::InvalidValue(format!("failed to encode runtime event: {error}"))
    })?;
    if let Some((sequence, existing_payload)) = transaction
        .query_row(
            "SELECT sequence, payload_json FROM runtime_events WHERE event_id = ?1",
            [&event.id],
            |row| Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?)),
        )
        .optional()?
    {
        if allow_existing && existing_payload == payload_json {
            return checked_u64(sequence, "runtime event sequence");
        }
        return Err(WorkflowStoreError::DuplicateRuntimeEvent(event.id.clone()));
    }
    let count = transaction.query_row(
        "SELECT COUNT(*) FROM runtime_events WHERE run_id = ?1",
        [&event.run_id],
        |row| row.get::<_, i64>(0),
    )?;
    if usize::try_from(count).map_or(true, |count| count >= MAX_RUNTIME_EVENTS_PER_RUN) {
        return Err(WorkflowStoreError::RuntimeEventRetentionLimit(
            event.run_id.clone(),
        ));
    }
    let executor_generation = executor_generation
        .map(checked_revision_for_sql)
        .transpose()?;
    transaction.execute(
        "INSERT INTO runtime_events (
            event_id, task_id, run_id, executor_lease_id, executor_generation,
            command_id, event_type, payload_json, created_at, projection_updated_at
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
        params![
            event.id,
            event.task_id,
            event.run_id,
            executor_lease_id,
            executor_generation,
            command_id,
            inbox_event_kind_name(event.kind),
            payload_json,
            event.created_at,
            projection_updated_at,
        ],
    )?;
    checked_u64(transaction.last_insert_rowid(), "runtime event sequence")
}

fn latest_runtime_event_sequence(connection: &Connection) -> Result<u64, WorkflowStoreError> {
    let sequence = connection.query_row(
        "SELECT COALESCE(MAX(sequence), 0) FROM runtime_events",
        [],
        |row| row.get::<_, i64>(0),
    )?;
    checked_u64(sequence, "runtime event sequence")
}

fn latest_checkpoint_sequence(connection: &Connection) -> Result<u64, WorkflowStoreError> {
    let sequence = connection.query_row(
        "SELECT COALESCE(MAX(covered_event_sequence), 0) FROM workflow_snapshots",
        [],
        |row| row.get::<_, i64>(0),
    )?;
    checked_u64(sequence, "workflow checkpoint sequence")
}

fn insert_workflow_checkpoint(
    transaction: &Transaction<'_>,
    workflow_revision: u64,
    covered_event_sequence: u64,
    task_inbox_json: &str,
    created_at: &str,
) -> Result<(), WorkflowStoreError> {
    transaction.execute(
        "INSERT INTO workflow_snapshots (
            workflow_revision, covered_event_sequence, task_inbox_json, created_at
         ) VALUES (?1, ?2, ?3, ?4)",
        params![
            checked_revision_for_sql(workflow_revision)?,
            checked_revision_for_sql(covered_event_sequence)?,
            task_inbox_json,
            created_at,
        ],
    )?;
    transaction.execute(
        "DELETE FROM workflow_snapshots
         WHERE snapshot_id NOT IN (
            SELECT snapshot_id FROM workflow_snapshots
            ORDER BY snapshot_id DESC LIMIT ?1
         )",
        [i64::try_from(WORKFLOW_SNAPSHOT_RETENTION).map_err(|_| {
            WorkflowStoreError::InvalidValue("snapshot retention is outside i64 range".to_string())
        })?],
    )?;
    Ok(())
}

fn maybe_checkpoint_runtime_events(
    transaction: &Transaction<'_>,
    current: &TaskInboxSnapshot,
    receipt: &RuntimeEventAppendReceipt,
) -> Result<(), WorkflowStoreError> {
    let covered = latest_checkpoint_sequence(transaction)?;
    if receipt.last_sequence.saturating_sub(covered) < RUNTIME_EVENT_CHECKPOINT_INTERVAL {
        return Ok(());
    }
    let encoded = encode_current_task_inbox(current)?;
    if transaction.execute(
        "UPDATE task_inbox_current SET payload_json = ?1 WHERE singleton = 1",
        [&encoded],
    )? != 1
    {
        return Err(WorkflowStoreError::InvalidValue(
            "active TaskInbox projection is missing".to_string(),
        ));
    }
    insert_workflow_checkpoint(
        transaction,
        receipt.revision,
        receipt.last_sequence,
        &encoded,
        &current.updated_at,
    )
}

fn query_runtime_event_page(
    connection: &Connection,
    run_id: &str,
    after_sequence: u64,
    limit: usize,
) -> Result<RuntimeEventPage, WorkflowStoreError> {
    let sql_after = checked_revision_for_sql(after_sequence)?;
    let sql_limit = i64::try_from(limit + 1).map_err(|_| {
        WorkflowStoreError::InvalidRuntimeEventQueryLimit(MAX_RUNTIME_EVENT_QUERY_LIMIT)
    })?;
    let mut statement = connection.prepare(
        "SELECT sequence, payload_json, executor_lease_id, executor_generation, command_id
         FROM runtime_events
         WHERE run_id = ?1 AND sequence > ?2
         ORDER BY sequence ASC LIMIT ?3",
    )?;
    let rows = statement
        .query_map(
            params![run_id, sql_after, sql_limit],
            stored_runtime_event_from_row,
        )?
        .collect::<Result<Vec<_>, _>>()?;
    let has_more = rows.len() > limit;
    let events = rows.into_iter().take(limit).collect::<Vec<_>>();
    let next_sequence = events.last().map_or(after_sequence, |event| event.sequence);
    Ok(RuntimeEventPage {
        run_id: run_id.to_string(),
        after_sequence,
        events,
        next_sequence,
        has_more,
    })
}

fn stored_runtime_event_from_row(
    row: &rusqlite::Row<'_>,
) -> Result<StoredRuntimeEvent, rusqlite::Error> {
    let sequence = row.get::<_, i64>(0)?;
    let payload_json = row.get::<_, String>(1)?;
    let event = serde_json::from_str(&payload_json).map_err(|error| {
        rusqlite::Error::FromSqlConversionFailure(
            payload_json.len(),
            rusqlite::types::Type::Text,
            Box::new(error),
        )
    })?;
    let executor_generation = row
        .get::<_, Option<i64>>(3)?
        .map(|value| {
            u64::try_from(value).map_err(|_| rusqlite::Error::IntegralValueOutOfRange(3, value))
        })
        .transpose()?;
    let sequence = u64::try_from(sequence)
        .map_err(|_| rusqlite::Error::IntegralValueOutOfRange(0, sequence))?;
    Ok(StoredRuntimeEvent {
        sequence,
        event,
        executor_lease_id: row.get(2)?,
        executor_generation,
        command_id: row.get(4)?,
    })
}

fn load_rebuilt_task_inbox(
    connection: &Connection,
) -> Result<Option<TaskInboxSnapshot>, WorkflowStoreError> {
    let checkpoint = connection
        .query_row(
            "SELECT task_inbox_json, covered_event_sequence
             FROM workflow_snapshots ORDER BY snapshot_id DESC LIMIT 1",
            [],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)),
        )
        .optional()?;
    let (mut current, covered_sequence) = if let Some((encoded, sequence)) = checkpoint {
        let current = serde_json::from_str::<TaskInboxSnapshot>(&encoded).map_err(|error| {
            WorkflowStoreError::InvalidValue(format!(
                "invalid workflow checkpoint TaskInbox: {error}"
            ))
        })?;
        (
            current,
            checked_u64(sequence, "workflow checkpoint sequence")?,
        )
    } else {
        let Some(current) = load_task_inbox_document(connection, "task_inbox_current")? else {
            return Ok(None);
        };
        (current, 0)
    };
    let sql_covered = checked_revision_for_sql(covered_sequence)?;
    let sql_limit = i64::try_from(MAX_RUNTIME_EVENT_REPLAY + 1)
        .map_err(|_| WorkflowStoreError::RuntimeEventReplayLimit(MAX_RUNTIME_EVENT_REPLAY))?;
    let mut statement = connection.prepare(
        "SELECT payload_json, projection_updated_at
         FROM runtime_events WHERE sequence > ?1 ORDER BY sequence ASC LIMIT ?2",
    )?;
    let later = statement
        .query_map(params![sql_covered, sql_limit], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    if later.len() > MAX_RUNTIME_EVENT_REPLAY {
        return Err(WorkflowStoreError::RuntimeEventReplayLimit(
            MAX_RUNTIME_EVENT_REPLAY,
        ));
    }
    for (encoded, projection_updated_at) in later {
        let event = serde_json::from_str::<InboxEventRecord>(&encoded).map_err(|error| {
            WorkflowStoreError::InvalidValue(format!("invalid persisted runtime event: {error}"))
        })?;
        if current
            .events
            .iter()
            .any(|existing| existing.id == event.id)
        {
            return Err(WorkflowStoreError::DuplicateRuntimeEvent(event.id));
        }
        current.events.push(event);
        current.updated_at = projection_updated_at;
    }
    current.validate()?;
    Ok(Some(current))
}

fn checked_u64(value: i64, field: &str) -> Result<u64, WorkflowStoreError> {
    u64::try_from(value)
        .map_err(|_| WorkflowStoreError::InvalidValue(format!("{field} is outside u64 range")))
}

const fn inbox_event_kind_name(kind: crate::InboxEventKind) -> &'static str {
    match kind {
        crate::InboxEventKind::User => "user",
        crate::InboxEventKind::Assistant => "assistant",
        crate::InboxEventKind::Tool => "tool",
        crate::InboxEventKind::Status => "status",
        crate::InboxEventKind::Permission => "permission",
        crate::InboxEventKind::Review => "review",
        crate::InboxEventKind::Artifact => "artifact",
        crate::InboxEventKind::Export => "export",
        crate::InboxEventKind::Error => "error",
        crate::InboxEventKind::System => "system",
    }
}

fn insert_idempotency_record(
    transaction: &Transaction<'_>,
    key: &IdempotencyKey,
    result_revision: u64,
    result_json: &str,
) -> Result<(), WorkflowStoreError> {
    if result_json.len() > MAX_IDEMPOTENCY_RESULT_BYTES {
        return Err(ExecutionError::IdempotencyResultTooLarge.into());
    }
    if let Some(existing) = load_idempotency_record(transaction, key)? {
        if existing.result_revision == result_revision && existing.result_projection == result_json
        {
            return Ok(());
        }
        return Err(ExecutionError::IdempotencyConflict.into());
    }
    transaction.execute(
        "INSERT INTO idempotency_records (
            command_id, command_type, payload_hash, result_revision, result_json, created_at
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        params![
            key.command_id,
            key.command_type,
            key.payload_hash,
            checked_revision_for_sql(result_revision)?,
            result_json,
            key.created_at,
        ],
    )?;
    Ok(())
}

fn encode_idempotency_result<T: Serialize>(value: &T) -> Result<String, WorkflowStoreError> {
    let encoded = serde_json::to_string(value).map_err(|_| ExecutionError::IdempotencyEncoding)?;
    if encoded.len() > MAX_IDEMPOTENCY_RESULT_BYTES {
        return Err(ExecutionError::IdempotencyResultTooLarge.into());
    }
    Ok(encoded)
}

fn decode_idempotency_result<T: DeserializeOwned>(
    record: &IdempotencyRecord,
) -> Result<T, WorkflowStoreError> {
    serde_json::from_str(&record.result_projection).map_err(|error| {
        WorkflowStoreError::InvalidValue(format!(
            "invalid persisted idempotency result for {}: {error}",
            record.command_id
        ))
    })
}

fn encode_workflow_ir<T: Serialize>(value: &T) -> Result<String, WorkflowStoreError> {
    let encoded = serde_json::to_string(value).map_err(|error| {
        WorkflowStoreError::InvalidValue(format!("failed to encode Workflow IR: {error}"))
    })?;
    if encoded.len() > MAX_WORKFLOW_IR_DOCUMENT_BYTES {
        return Err(WorkflowStoreError::InvalidValue(
            "Workflow IR document exceeds its bounded size".to_string(),
        ));
    }
    Ok(encoded)
}

fn decode_workflow_ir<T: DeserializeOwned>(
    encoded: &str,
    kind: &str,
) -> Result<T, WorkflowStoreError> {
    if encoded.len() > MAX_WORKFLOW_IR_DOCUMENT_BYTES {
        return Err(WorkflowStoreError::InvalidValue(format!(
            "persisted {kind} exceeds its bounded size"
        )));
    }
    serde_json::from_str(encoded).map_err(|error| {
        WorkflowStoreError::InvalidValue(format!("persisted {kind} is invalid: {error}"))
    })
}

fn insert_executor_lease(
    transaction: &Transaction<'_>,
    lease: &ExecutorLease,
) -> Result<(), WorkflowStoreError> {
    transaction.execute(
        "INSERT INTO executor_leases (
            lease_id, run_id, executor_id, generation, reservation_id,
            acquired_at, expires_at, last_heartbeat_at,
            start_acknowledged_at, released_at, state
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
        params![
            lease.lease_id,
            lease.run_id,
            lease.executor_id,
            checked_revision_for_sql(lease.generation)?,
            lease.reservation_id,
            lease.acquired_at,
            lease.expires_at,
            lease.last_heartbeat_at,
            lease.start_acknowledged_at,
            lease.released_at,
            executor_lease_state_name(lease.state),
        ],
    )?;
    Ok(())
}

fn update_executor_lease(
    transaction: &Transaction<'_>,
    lease: &ExecutorLease,
) -> Result<(), WorkflowStoreError> {
    if transaction.execute(
        "UPDATE executor_leases SET
            expires_at = ?1,
            last_heartbeat_at = ?2,
            start_acknowledged_at = ?3,
            released_at = ?4,
            state = ?5
         WHERE lease_id = ?6 AND run_id = ?7 AND generation = ?8",
        params![
            lease.expires_at,
            lease.last_heartbeat_at,
            lease.start_acknowledged_at,
            lease.released_at,
            executor_lease_state_name(lease.state),
            lease.lease_id,
            lease.run_id,
            checked_revision_for_sql(lease.generation)?,
        ],
    )? != 1
    {
        return Err(ExecutionError::UnknownLease.into());
    }
    Ok(())
}

fn require_monotonic_lease_window(
    lease: &ExecutorLease,
    now: &str,
    next_expires_at: Option<&str>,
) -> Result<(), WorkflowStoreError> {
    let next_expires_at = next_expires_at.ok_or(ExecutionError::MissingLeaseExpiry)?;
    let now =
        DateTime::parse_from_rfc3339(now).map_err(|_| ExecutionError::InvalidTimestamp("now"))?;
    let last_heartbeat_at = DateTime::parse_from_rfc3339(&lease.last_heartbeat_at)
        .map_err(|_| ExecutionError::InvalidTimestamp("lastHeartbeatAt"))?;
    let next_expires_at = DateTime::parse_from_rfc3339(next_expires_at)
        .map_err(|_| ExecutionError::InvalidTimestamp("nextExpiresAt"))?;
    let current_expires_at = DateTime::parse_from_rfc3339(&lease.expires_at)
        .map_err(|_| ExecutionError::InvalidTimestamp("expiresAt"))?;
    if now < last_heartbeat_at || next_expires_at < current_expires_at {
        return Err(ExecutionError::LeaseClockRegression.into());
    }
    Ok(())
}

fn load_executor_lease_for_run(
    connection: &Connection,
    run_id: &str,
) -> Result<Option<ExecutorLease>, WorkflowStoreError> {
    let mut statement = connection.prepare(
        "SELECT lease_id, run_id, executor_id, generation, reservation_id,
                acquired_at, expires_at, last_heartbeat_at,
                start_acknowledged_at, released_at, state
         FROM executor_leases
         WHERE run_id = ?1
         ORDER BY generation DESC
         LIMIT 1",
    )?;
    let mut rows = statement.query([run_id])?;
    let Some(row) = rows.next()? else {
        return Ok(None);
    };
    let generation = row.get::<_, i64>(3)?;
    let generation = u64::try_from(generation).map_err(|_| {
        WorkflowStoreError::InvalidValue(
            "executor lease generation is outside u64 range".to_string(),
        )
    })?;
    let state = parse_executor_lease_state(&row.get::<_, String>(10)?)?;
    let lease = ExecutorLease {
        lease_id: row.get(0)?,
        run_id: row.get(1)?,
        executor_id: row.get(2)?,
        generation,
        reservation_id: row.get(4)?,
        acquired_at: row.get(5)?,
        expires_at: row.get(6)?,
        last_heartbeat_at: row.get(7)?,
        start_acknowledged_at: row.get(8)?,
        released_at: row.get(9)?,
        state,
    };
    lease.validate()?;
    Ok(Some(lease))
}

fn validate_executor_context_on(
    connection: &Connection,
    context: &ExecutorCommandContext,
) -> Result<ExecutorLease, WorkflowStoreError> {
    load_and_match_executor_context(connection, context, true)
}

fn load_and_match_executor_context(
    connection: &Connection,
    context: &ExecutorCommandContext,
    require_active: bool,
) -> Result<ExecutorLease, WorkflowStoreError> {
    context.validate()?;
    let lease = load_executor_lease_for_run(connection, &context.run_id)?
        .ok_or(ExecutionError::UnknownLease)?;
    if lease.lease_id != context.executor_lease_id {
        return Err(ExecutionError::UnknownLease.into());
    }
    if lease.run_id != context.run_id {
        return Err(ExecutionError::LeaseRunMismatch.into());
    }
    if lease.generation != context.generation {
        return Err(ExecutionError::StaleGeneration.into());
    }
    if require_active && (!lease.state.accepts_mutation() || lease.is_expired_at(&context.now)?) {
        return Err(ExecutionError::LeaseInactive.into());
    }
    Ok(lease)
}

const fn executor_lease_state_name(state: ExecutorLeaseState) -> &'static str {
    match state {
        ExecutorLeaseState::Claimed => "claimed",
        ExecutorLeaseState::Starting => "starting",
        ExecutorLeaseState::Active => "active",
        ExecutorLeaseState::Expired => "expired",
        ExecutorLeaseState::Released => "released",
        ExecutorLeaseState::Superseded => "superseded",
    }
}

fn parse_executor_lease_state(value: &str) -> Result<ExecutorLeaseState, WorkflowStoreError> {
    match value {
        "claimed" => Ok(ExecutorLeaseState::Claimed),
        "starting" => Ok(ExecutorLeaseState::Starting),
        "active" => Ok(ExecutorLeaseState::Active),
        "expired" => Ok(ExecutorLeaseState::Expired),
        "released" => Ok(ExecutorLeaseState::Released),
        "superseded" => Ok(ExecutorLeaseState::Superseded),
        other => Err(WorkflowStoreError::InvalidValue(format!(
            "unknown executor lease state: {other}"
        ))),
    }
}

fn run_accepts_executor_commands(
    connection: &Connection,
    run_id: &str,
) -> Result<bool, WorkflowStoreError> {
    let status = connection
        .query_row("SELECT status FROM runs WHERE id = ?1", [run_id], |row| {
            row.get::<_, String>(0)
        })
        .optional()?;
    Ok(status.is_some_and(|status| {
        matches!(
            status.as_str(),
            "dispatched"
                | "running"
                | "waiting_permission"
                | "waiting_user_input"
                | "collecting_artifacts"
        )
    }))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum RecoveryProductState {
    Requeue,
    HumanReview,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct RecoveryDecision {
    product_state: RecoveryProductState,
    recovery_state: RecoveryState,
    reason: &'static str,
    prompt_submission_state: PromptSubmissionState,
    workspace_mutation_possibility: WorkspaceMutationPossibility,
    suggested_action: SuggestedRecoveryAction,
}

fn classify_interrupted_run(
    previous_state: &str,
    lease: Option<&ExecutorLease>,
    session_id: Option<&str>,
    has_prompt_snapshot: bool,
    has_execution_evidence: bool,
) -> RecoveryDecision {
    let start_acknowledged = lease.is_some_and(|lease| lease.start_acknowledged_at.is_some());
    if previous_state == "dispatched"
        || (previous_state == "running"
            && !start_acknowledged
            && session_id.is_none()
            && !has_prompt_snapshot
            && !has_execution_evidence)
    {
        return RecoveryDecision {
            product_state: RecoveryProductState::Requeue,
            recovery_state: RecoveryState::Requeued,
            reason: "interrupted_before_start_ack",
            prompt_submission_state: PromptSubmissionState::NotSubmitted,
            workspace_mutation_possibility: WorkspaceMutationPossibility::None,
            suggested_action: SuggestedRecoveryAction::Requeue,
        };
    }
    if previous_state == "running"
        && session_id.is_some()
        && !has_prompt_snapshot
        && !has_execution_evidence
    {
        return RecoveryDecision {
            product_state: RecoveryProductState::HumanReview,
            recovery_state: RecoveryState::Orphaned,
            reason: "session_created_before_prompt_record",
            prompt_submission_state: PromptSubmissionState::NotSubmitted,
            workspace_mutation_possibility: WorkspaceMutationPossibility::None,
            suggested_action: SuggestedRecoveryAction::ResumeSession,
        };
    }
    if previous_state == "waiting_permission" {
        return RecoveryDecision {
            product_state: RecoveryProductState::HumanReview,
            recovery_state: RecoveryState::ReviewRequired,
            reason: "permission_wait_interrupted",
            prompt_submission_state: PromptSubmissionState::Submitted,
            workspace_mutation_possibility: WorkspaceMutationPossibility::Possible,
            suggested_action: SuggestedRecoveryAction::HumanReview,
        };
    }
    if previous_state == "collecting_artifacts" {
        return RecoveryDecision {
            product_state: RecoveryProductState::HumanReview,
            recovery_state: RecoveryState::ReviewRequired,
            reason: "artifact_collection_interrupted_after_execution",
            prompt_submission_state: PromptSubmissionState::Submitted,
            workspace_mutation_possibility: WorkspaceMutationPossibility::Possible,
            suggested_action: SuggestedRecoveryAction::HumanReview,
        };
    }
    RecoveryDecision {
        product_state: RecoveryProductState::HumanReview,
        recovery_state: RecoveryState::ReviewRequired,
        reason: "execution_outcome_uncertain",
        prompt_submission_state: if has_prompt_snapshot {
            PromptSubmissionState::Submitted
        } else {
            PromptSubmissionState::Unknown
        },
        workspace_mutation_possibility: WorkspaceMutationPossibility::Possible,
        suggested_action: SuggestedRecoveryAction::HumanReview,
    }
}

fn insert_recovery_record(
    transaction: &Transaction<'_>,
    recovery_id: &str,
    record: &RunRecoveryRecord,
    detected_at: &str,
) -> Result<(), WorkflowStoreError> {
    transaction.execute(
        "INSERT INTO recovery_records (
            recovery_id, task_id, run_id, previous_state, recovery_state, reason,
            prompt_submission_state, workspace_mutation_possibility, suggested_action,
            executor_lease_id, detected_at, resolved_at
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, NULL)",
        params![
            recovery_id,
            record.task_id,
            record.run_id,
            record.previous_state,
            recovery_state_name(record.recovery_state),
            record.reason,
            prompt_submission_state_name(record.prompt_submission_state),
            workspace_mutation_possibility_name(record.workspace_mutation_possibility),
            suggested_recovery_action_name(record.suggested_action),
            record.executor_lease_id,
            detected_at,
        ],
    )?;
    Ok(())
}

const fn recovery_state_name(state: RecoveryState) -> &'static str {
    match state {
        RecoveryState::Requeued => "requeued",
        RecoveryState::Orphaned => "orphaned",
        RecoveryState::Waiting => "waiting",
        RecoveryState::ReviewRequired => "review_required",
        RecoveryState::Terminal => "terminal",
    }
}

const fn prompt_submission_state_name(state: PromptSubmissionState) -> &'static str {
    match state {
        PromptSubmissionState::NotSubmitted => "not_submitted",
        PromptSubmissionState::Submitted => "submitted",
        PromptSubmissionState::Unknown => "unknown",
        PromptSubmissionState::NotApplicable => "not_applicable",
    }
}

const fn workspace_mutation_possibility_name(state: WorkspaceMutationPossibility) -> &'static str {
    match state {
        WorkspaceMutationPossibility::None => "none",
        WorkspaceMutationPossibility::ReadOnly => "read_only",
        WorkspaceMutationPossibility::Possible => "possible",
        WorkspaceMutationPossibility::Confirmed => "confirmed",
        WorkspaceMutationPossibility::Unknown => "unknown",
    }
}

const fn suggested_recovery_action_name(action: SuggestedRecoveryAction) -> &'static str {
    match action {
        SuggestedRecoveryAction::Requeue => "requeue",
        SuggestedRecoveryAction::ResumeSession => "resume_session",
        SuggestedRecoveryAction::RetryReadOnly => "retry_read_only",
        SuggestedRecoveryAction::HumanReview => "human_review",
        SuggestedRecoveryAction::KeepWaiting => "keep_waiting",
        SuggestedRecoveryAction::Terminal => "terminal",
    }
}

fn load_task_inbox_document(
    connection: &Connection,
    table: &str,
) -> Result<Option<TaskInboxSnapshot>, WorkflowStoreError> {
    let query = match table {
        "task_inbox_source_archive" => {
            "SELECT payload_json FROM task_inbox_source_archive WHERE singleton = 1"
        }
        "task_inbox_current" => "SELECT payload_json FROM task_inbox_current WHERE singleton = 1",
        _ => {
            return Err(WorkflowStoreError::InvalidValue(format!(
                "unknown TaskInbox document table: {table}"
            )));
        }
    };
    let mut statement = connection.prepare(query)?;
    let mut rows = statement.query([])?;
    let Some(row) = rows.next()? else {
        return Ok(None);
    };
    let encoded = row.get::<_, String>(0)?;
    let snapshot: TaskInboxSnapshot = serde_json::from_str(&encoded).map_err(|error| {
        WorkflowStoreError::InvalidValue(format!("invalid persisted TaskInbox: {error}"))
    })?;
    snapshot.validate()?;
    Ok(Some(snapshot))
}

fn encode_current_task_inbox(current: &TaskInboxSnapshot) -> Result<String, WorkflowStoreError> {
    serde_json::to_string(current).map_err(|error| {
        WorkflowStoreError::InvalidValue(format!("failed to encode current task inbox: {error}"))
    })
}

fn load_snapshot_from(connection: &Connection) -> Result<WorkflowSnapshot, WorkflowStoreError> {
    let mut task_statement = connection.prepare(
        "SELECT id, workspace_path, agent_name, status, attempt, current_run_id
         FROM tasks ORDER BY id",
    )?;
    let tasks = task_statement
        .query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, String>(3)?,
                row.get::<_, i64>(4)?,
                row.get::<_, Option<String>>(5)?,
            ))
        })?
        .map(|row| {
            let (id, workspace_path, agent_name, status, attempt, current_run_id) = row?;
            Ok(TaskState {
                id,
                workspace_path,
                agent_name,
                status: parse_task_status(&status)?,
                attempt: checked_attempt(attempt)?,
                current_run_id,
            })
        })
        .collect::<Result<Vec<_>, WorkflowStoreError>>()?;
    let mut run_statement =
        connection.prepare("SELECT id, task_id, attempt, status FROM runs ORDER BY id")?;
    let runs = run_statement
        .query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, i64>(2)?,
                row.get::<_, String>(3)?,
            ))
        })?
        .map(|row| {
            let (id, task_id, attempt, status) = row?;
            Ok(RunState {
                id,
                task_id,
                attempt: checked_attempt(attempt)?,
                status: parse_run_status(&status)?,
            })
        })
        .collect::<Result<Vec<_>, WorkflowStoreError>>()?;
    Ok(WorkflowSnapshot { tasks, runs })
}

fn query_revision(connection: &Connection) -> Result<u64, WorkflowStoreError> {
    let value = connection.query_row(
        "SELECT revision FROM workflow_meta WHERE singleton = 1",
        [],
        |row| row.get::<_, i64>(0),
    )?;
    u64::try_from(value).map_err(|_| {
        WorkflowStoreError::InvalidValue(format!("workflow revision is outside u64 range: {value}"))
    })
}

fn require_revision(
    connection: &Connection,
    expected_revision: u64,
) -> Result<(), WorkflowStoreError> {
    let actual_revision = query_revision(connection)?;
    if actual_revision == expected_revision {
        Ok(())
    } else {
        Err(WorkflowStoreError::Conflict {
            expected: expected_revision,
            actual: actual_revision,
        })
    }
}

fn next_revision(revision: u64) -> Result<u64, WorkflowStoreError> {
    revision
        .checked_add(1)
        .ok_or_else(|| WorkflowStoreError::InvalidValue("workflow revision overflow".to_string()))
}

fn query_migration_metadata(
    connection: &Connection,
) -> Result<WorkflowMigrationMetadata, WorkflowStoreError> {
    let (phase, source_checksum) = connection.query_row(
        "SELECT migration_state, source_checksum FROM workflow_meta WHERE singleton = 1",
        [],
        |row| Ok((row.get::<_, String>(0)?, row.get::<_, Option<String>>(1)?)),
    )?;
    let phase = match phase.as_str() {
        "native" => WorkflowMigrationPhase::Native,
        "staged" => WorkflowMigrationPhase::Staged,
        "ready" => WorkflowMigrationPhase::Ready,
        "active" => WorkflowMigrationPhase::Active,
        other => {
            return Err(WorkflowStoreError::InvalidValue(format!(
                "unknown workflow migration state: {other}"
            )));
        }
    };
    Ok(WorkflowMigrationMetadata {
        phase,
        source_checksum,
    })
}

fn checked_revision_for_sql(value: u64) -> Result<i64, WorkflowStoreError> {
    i64::try_from(value).map_err(|_| {
        WorkflowStoreError::InvalidValue(format!(
            "workflow revision is outside SQLite integer range: {value}"
        ))
    })
}

fn safe_database_path(path: &Path) -> Result<PathBuf, WorkflowStoreError> {
    if !path.is_absolute() {
        return Err(WorkflowStoreError::RelativePath);
    }
    if path.file_name().is_none() {
        return Err(WorkflowStoreError::InvalidPath);
    }
    if let Ok(metadata) = fs::symlink_metadata(path)
        && metadata.file_type().is_symlink()
    {
        return Err(WorkflowStoreError::SymlinkPath(path.display().to_string()));
    }
    let parent = path.parent().ok_or(WorkflowStoreError::InvalidPath)?;
    fs::create_dir_all(parent)?;
    let parent = parent.canonicalize()?;
    Ok(parent.join(path.file_name().ok_or(WorkflowStoreError::InvalidPath)?))
}

fn checked_attempt(value: i64) -> Result<u32, WorkflowStoreError> {
    u32::try_from(value).map_err(|_| {
        WorkflowStoreError::InvalidValue(format!("attempt is outside u32 range: {value}"))
    })
}

const fn task_status_name(status: TaskStatus) -> &'static str {
    match status {
        TaskStatus::Inbox => "inbox",
        TaskStatus::Queued => "queued",
        TaskStatus::Dispatched => "dispatched",
        TaskStatus::Running => "running",
        TaskStatus::BlockedOnPermission => "blocked_on_permission",
        TaskStatus::BlockedOnUserInput => "blocked_on_user_input",
        TaskStatus::CollectingArtifacts => "collecting_artifacts",
        TaskStatus::NeedsHumanReview => "needs_human_review",
        TaskStatus::NeedsChanges => "needs_changes",
        TaskStatus::Done => "done",
        TaskStatus::Failed => "failed",
        TaskStatus::Cancelled => "cancelled",
        TaskStatus::Rejected => "rejected",
    }
}

fn parse_task_status(value: &str) -> Result<TaskStatus, WorkflowStoreError> {
    match value {
        "inbox" => Ok(TaskStatus::Inbox),
        "queued" => Ok(TaskStatus::Queued),
        "dispatched" => Ok(TaskStatus::Dispatched),
        "running" => Ok(TaskStatus::Running),
        "blocked_on_permission" => Ok(TaskStatus::BlockedOnPermission),
        "blocked_on_user_input" => Ok(TaskStatus::BlockedOnUserInput),
        "collecting_artifacts" => Ok(TaskStatus::CollectingArtifacts),
        "needs_human_review" => Ok(TaskStatus::NeedsHumanReview),
        "needs_changes" => Ok(TaskStatus::NeedsChanges),
        "done" => Ok(TaskStatus::Done),
        "failed" => Ok(TaskStatus::Failed),
        "cancelled" => Ok(TaskStatus::Cancelled),
        "rejected" => Ok(TaskStatus::Rejected),
        other => Err(WorkflowStoreError::InvalidValue(format!(
            "unknown task status: {other}"
        ))),
    }
}

const fn run_status_name(status: RunStatus) -> &'static str {
    match status {
        RunStatus::Dispatched => "dispatched",
        RunStatus::Running => "running",
        RunStatus::WaitingPermission => "waiting_permission",
        RunStatus::WaitingUserInput => "waiting_user_input",
        RunStatus::CollectingArtifacts => "collecting_artifacts",
        RunStatus::NeedsHumanReview => "needs_human_review",
        RunStatus::NeedsChanges => "needs_changes",
        RunStatus::Succeeded => "succeeded",
        RunStatus::Failed => "failed",
        RunStatus::Cancelled => "cancelled",
        RunStatus::Rejected => "rejected",
    }
}

fn parse_run_status(value: &str) -> Result<RunStatus, WorkflowStoreError> {
    match value {
        "dispatched" => Ok(RunStatus::Dispatched),
        "running" => Ok(RunStatus::Running),
        "waiting_permission" => Ok(RunStatus::WaitingPermission),
        "waiting_user_input" => Ok(RunStatus::WaitingUserInput),
        "collecting_artifacts" => Ok(RunStatus::CollectingArtifacts),
        "needs_human_review" => Ok(RunStatus::NeedsHumanReview),
        "needs_changes" => Ok(RunStatus::NeedsChanges),
        "succeeded" => Ok(RunStatus::Succeeded),
        "failed" => Ok(RunStatus::Failed),
        "cancelled" => Ok(RunStatus::Cancelled),
        "rejected" => Ok(RunStatus::Rejected),
        other => Err(WorkflowStoreError::InvalidValue(format!(
            "unknown run status: {other}"
        ))),
    }
}
