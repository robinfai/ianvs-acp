use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

use rusqlite::{Connection, OpenFlags, Transaction, TransactionBehavior, params};
use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::{
    RunState, RunStatus, TaskInboxError, TaskInboxSnapshot, TaskState, TaskStatus, WorkflowSnapshot,
};

const SCHEMA_VERSION: i64 = 5;

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
    #[error(transparent)]
    TaskInbox(#[from] TaskInboxError),
    #[error(transparent)]
    Io(#[from] std::io::Error),
    #[error(transparent)]
    Sqlite(#[from] rusqlite::Error),
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RecoveryReport {
    pub failed_task_ids: Vec<String>,
}

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
            [encoded],
        )?;
        transaction.execute(
            "UPDATE workflow_meta SET revision = ?1, migration_state = 'ready'
             WHERE singleton = 1",
            [checked_revision_for_sql(next_revision)?],
        )?;
        transaction.commit()?;
        Ok(next_revision)
    }

    pub fn load_current_task_inbox(&self) -> Result<Option<TaskInboxSnapshot>, WorkflowStoreError> {
        load_task_inbox_document(&self.connection, "task_inbox_current")
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
            [encoded],
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
        transaction.commit()?;
        Ok(next_revision)
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

    /// Mark runs that depended on a live process as failed after a crash.
    /// Human-review and user-input states remain recoverable UI work.
    pub fn recover_interrupted(&mut self) -> Result<RecoveryReport, WorkflowStoreError> {
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let revision = query_revision(&transaction)?;
        let mut statement = transaction.prepare(
            "SELECT t.id
             FROM tasks t
             JOIN runs r ON r.id = t.current_run_id AND r.task_id = t.id
             WHERE t.status IN (
                 'dispatched', 'running', 'blocked_on_permission', 'collecting_artifacts'
             ) AND r.status IN (
                 'dispatched', 'running', 'waiting_permission', 'collecting_artifacts'
             )
             ORDER BY t.id",
        )?;
        let failed_task_ids = statement
            .query_map([], |row| row.get::<_, String>(0))?
            .collect::<Result<Vec<_>, _>>()?;
        drop(statement);
        for task_id in &failed_task_ids {
            transaction.execute(
                "UPDATE runs SET status = 'failed'
                 WHERE id = (SELECT current_run_id FROM tasks WHERE id = ?1)",
                [task_id],
            )?;
            transaction.execute(
                "UPDATE tasks SET status = 'failed' WHERE id = ?1",
                [task_id],
            )?;
        }
        if !failed_task_ids.is_empty() {
            let migration = query_migration_metadata(&transaction)?;
            if matches!(
                migration.phase,
                WorkflowMigrationPhase::Ready | WorkflowMigrationPhase::Active
            ) {
                let workflow = load_snapshot_from(&transaction)?;
                let current = load_task_inbox_document(&transaction, "task_inbox_current")?
                    .ok_or_else(|| {
                        WorkflowStoreError::InvalidValue(
                            "materialized TaskInbox projection is missing".to_string(),
                        )
                    })?;
                let synchronized = current.synchronized_with_workflow(&workflow)?;
                transaction.execute(
                    "UPDATE task_inbox_current SET payload_json = ?1 WHERE singleton = 1",
                    [encode_current_task_inbox(&synchronized)?],
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
        Ok(RecoveryReport { failed_task_ids })
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
            0 => create_schema_v5(&mut self.connection)?,
            1 => migrate_v1_to_v5(&mut self.connection)?,
            2 => migrate_v2_to_v5(&mut self.connection)?,
            3 => migrate_v3_to_v5(&mut self.connection)?,
            4 => migrate_v4_to_v5(&mut self.connection)?,
            _ => {}
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
