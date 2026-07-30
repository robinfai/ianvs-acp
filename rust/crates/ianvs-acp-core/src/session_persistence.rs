use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

use rusqlite::{Connection, OpenFlags, params};
use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::{SqliteStoragePolicy, WorkspaceScope};

const SCHEMA_VERSION: i64 = 1;
const MAX_ACTIVE_SESSIONS_PER_AGENT: usize = 512;
const MAX_AGENT_NAME_BYTES: usize = 256;
const MAX_SESSION_ID_BYTES: usize = 8 * 1024;
const MAX_ROOTS: usize = 128;
const MAX_PATH_BYTES: usize = 32 * 1024;

#[derive(Debug, Error)]
pub enum SessionStoreError {
    #[error("session database path must be absolute")]
    RelativePath,
    #[error("session database path must not be a symlink: {0}")]
    SymlinkPath(String),
    #[error("session database path has no parent or file name")]
    InvalidPath,
    #[error("unsupported session database schema version: {0}")]
    UnsupportedSchema(i64),
    #[error("invalid persisted session value: {0}")]
    InvalidValue(String),
    #[error(transparent)]
    Io(#[from] std::io::Error),
    #[error(transparent)]
    Sqlite(#[from] rusqlite::Error),
}

/// Durable, agent-scoped description of an ACP session that may be loaded or
/// resumed after the owned subprocess exits.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PersistedSession {
    pub agent_name: String,
    pub session_id: String,
    pub cwd: String,
    #[serde(default)]
    pub additional_directories: Vec<String>,
}

impl PersistedSession {
    pub(crate) fn from_scope(
        agent_name: impl Into<String>,
        session_id: impl Into<String>,
        scope: &WorkspaceScope,
    ) -> Self {
        Self {
            agent_name: agent_name.into(),
            session_id: session_id.into(),
            cwd: scope.cwd().display().to_string(),
            additional_directories: scope.roots()[1..]
                .iter()
                .map(|path| path.display().to_string())
                .collect(),
        }
    }

    pub(crate) fn scope(&self) -> Result<WorkspaceScope, SessionStoreError> {
        validate_text(&self.agent_name, "agent name", MAX_AGENT_NAME_BYTES)?;
        validate_text(&self.session_id, "session id", MAX_SESSION_ID_BYTES)?;
        validate_path(&self.cwd, "cwd")?;
        if self.additional_directories.len() > MAX_ROOTS.saturating_sub(1) {
            return Err(SessionStoreError::InvalidValue(
                "too many additional directories".to_string(),
            ));
        }
        for path in &self.additional_directories {
            validate_path(path, "additional directory")?;
        }
        WorkspaceScope::new(&self.cwd, &self.additional_directories).map_err(|error| {
            SessionStoreError::InvalidValue(format!("invalid persisted workspace: {error}"))
        })
    }
}

/// Dedicated `SQLite` store for ACP session recovery metadata. It intentionally
/// does not share a schema with `TaskInbox` so either authority can evolve and
/// be opened independently.
pub struct SqliteSessionStore {
    connection: Connection,
    path: Option<PathBuf>,
    storage_policy: SqliteStoragePolicy,
}

impl std::fmt::Debug for SqliteSessionStore {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("SqliteSessionStore")
            .field("path", &self.path)
            .finish_non_exhaustive()
    }
}

impl SqliteSessionStore {
    pub fn open(path: impl AsRef<Path>) -> Result<Self, SessionStoreError> {
        Self::open_with_policy(path, SqliteStoragePolicy::default())
    }

    pub fn open_with_policy(
        path: impl AsRef<Path>,
        storage_policy: SqliteStoragePolicy,
    ) -> Result<Self, SessionStoreError> {
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
            storage_policy,
        };
        store.initialize()?;
        Ok(store)
    }

    pub fn open_in_memory() -> Result<Self, SessionStoreError> {
        let connection = Connection::open_in_memory()?;
        let mut store = Self {
            connection,
            path: None,
            storage_policy: SqliteStoragePolicy::default(),
        };
        store.initialize()?;
        Ok(store)
    }

    #[must_use]
    pub fn path(&self) -> Option<&Path> {
        self.path.as_deref()
    }

    pub fn upsert(&mut self, session: &PersistedSession) -> Result<(), SessionStoreError> {
        let scope = session.scope()?;
        let normalized = PersistedSession::from_scope(
            session.agent_name.clone(),
            session.session_id.clone(),
            &scope,
        );
        let directories =
            serde_json::to_string(&normalized.additional_directories).map_err(|error| {
                SessionStoreError::InvalidValue(format!(
                    "failed to encode additional directories: {error}"
                ))
            })?;
        let transaction = self.connection.transaction()?;
        delete_expired_sessions(&transaction, self.storage_policy)?;
        let active_count = transaction.query_row(
            "SELECT COUNT(*) FROM active_sessions WHERE agent_name = ?1",
            [&normalized.agent_name],
            |row| row.get::<_, i64>(0),
        )?;
        let exists = transaction.query_row(
            "SELECT EXISTS(
                SELECT 1 FROM active_sessions
                WHERE agent_name = ?1 AND session_id = ?2
             )",
            params![normalized.agent_name, normalized.session_id],
            |row| row.get::<_, bool>(0),
        )?;
        if !exists
            && usize::try_from(active_count).unwrap_or(usize::MAX) >= MAX_ACTIVE_SESSIONS_PER_AGENT
        {
            return Err(SessionStoreError::InvalidValue(format!(
                "agent has more than {MAX_ACTIVE_SESSIONS_PER_AGENT} active sessions"
            )));
        }
        transaction.execute(
            "INSERT INTO active_sessions (
                agent_name, session_id, cwd, additional_directories_json, updated_at
             ) VALUES (?1, ?2, ?3, ?4, unixepoch())
             ON CONFLICT(agent_name, session_id) DO UPDATE SET
                cwd = excluded.cwd,
                additional_directories_json = excluded.additional_directories_json,
                updated_at = unixepoch()",
            params![
                normalized.agent_name,
                normalized.session_id,
                normalized.cwd,
                directories
            ],
        )?;
        transaction.commit()?;
        Ok(())
    }

    pub fn remove(&mut self, agent_name: &str, session_id: &str) -> Result<(), SessionStoreError> {
        validate_text(agent_name, "agent name", MAX_AGENT_NAME_BYTES)?;
        validate_text(session_id, "session id", MAX_SESSION_ID_BYTES)?;
        self.connection.execute(
            "DELETE FROM active_sessions WHERE agent_name = ?1 AND session_id = ?2",
            params![agent_name, session_id],
        )?;
        Ok(())
    }

    pub fn load_active(
        &self,
        agent_name: &str,
    ) -> Result<Vec<PersistedSession>, SessionStoreError> {
        validate_text(agent_name, "agent name", MAX_AGENT_NAME_BYTES)?;
        let mut statement = self.connection.prepare(
            "SELECT session_id, cwd, additional_directories_json
             FROM active_sessions
             WHERE agent_name = ?1
             ORDER BY updated_at, session_id
             LIMIT ?2",
        )?;
        let rows = statement
            .query_map(
                params![
                    agent_name,
                    i64::try_from(MAX_ACTIVE_SESSIONS_PER_AGENT + 1).unwrap()
                ],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, String>(2)?,
                    ))
                },
            )?
            .collect::<Result<Vec<_>, _>>()?;
        if rows.len() > MAX_ACTIVE_SESSIONS_PER_AGENT {
            return Err(SessionStoreError::InvalidValue(format!(
                "agent has more than {MAX_ACTIVE_SESSIONS_PER_AGENT} active sessions"
            )));
        }
        rows.into_iter()
            .map(|(session_id, cwd, encoded_directories)| {
                let additional_directories =
                    serde_json::from_str::<Vec<String>>(&encoded_directories).map_err(|error| {
                        SessionStoreError::InvalidValue(format!(
                            "invalid additional directories JSON: {error}"
                        ))
                    })?;
                let session = PersistedSession {
                    agent_name: agent_name.to_string(),
                    session_id,
                    cwd,
                    additional_directories,
                };
                session.scope()?;
                Ok(session)
            })
            .collect()
    }

    fn initialize(&mut self) -> Result<(), SessionStoreError> {
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
            return Err(SessionStoreError::UnsupportedSchema(version));
        }
        if version == 0 {
            self.connection.execute_batch(
                "BEGIN IMMEDIATE;
                 CREATE TABLE active_sessions (
                    agent_name TEXT NOT NULL,
                    session_id TEXT NOT NULL,
                    cwd TEXT NOT NULL,
                    additional_directories_json TEXT NOT NULL,
                    updated_at INTEGER NOT NULL,
                    PRIMARY KEY (agent_name, session_id)
                 ) STRICT;
                 CREATE INDEX active_sessions_agent_updated
                    ON active_sessions(agent_name, updated_at, session_id);
                 PRAGMA user_version = 1;
                 COMMIT;",
            )?;
        }
        self.storage_policy.apply_page_limit(&self.connection)?;
        let transaction = self.connection.transaction()?;
        delete_expired_sessions(&transaction, self.storage_policy)?;
        transaction.commit()?;
        self.connection
            .execute_batch("PRAGMA wal_checkpoint(TRUNCATE);")?;
        Ok(())
    }
}

fn delete_expired_sessions(
    transaction: &rusqlite::Transaction<'_>,
    storage_policy: SqliteStoragePolicy,
) -> Result<(), SessionStoreError> {
    transaction.execute(
        "DELETE FROM active_sessions
         WHERE updated_at < unixepoch('now', ?1)",
        [storage_policy.retention_modifier()],
    )?;
    Ok(())
}

fn validate_text(value: &str, label: &str, max_bytes: usize) -> Result<(), SessionStoreError> {
    if value.trim().is_empty() || value.trim().len() != value.len() {
        return Err(SessionStoreError::InvalidValue(format!(
            "{label} must be canonical non-empty text"
        )));
    }
    if value.len() > max_bytes || value.as_bytes().contains(&0) {
        return Err(SessionStoreError::InvalidValue(format!(
            "{label} exceeds its boundary"
        )));
    }
    Ok(())
}

fn validate_path(value: &str, label: &str) -> Result<(), SessionStoreError> {
    validate_text(value, label, MAX_PATH_BYTES)
}

fn safe_database_path(path: &Path) -> Result<PathBuf, SessionStoreError> {
    if !path.is_absolute() {
        return Err(SessionStoreError::RelativePath);
    }
    if path.file_name().is_none() {
        return Err(SessionStoreError::InvalidPath);
    }
    if let Ok(metadata) = fs::symlink_metadata(path)
        && metadata.file_type().is_symlink()
    {
        return Err(SessionStoreError::SymlinkPath(path.display().to_string()));
    }
    let parent = path.parent().ok_or(SessionStoreError::InvalidPath)?;
    fs::create_dir_all(parent)?;
    let parent = parent.canonicalize()?;
    Ok(parent.join(path.file_name().ok_or(SessionStoreError::InvalidPath)?))
}

#[cfg(test)]
mod storage_tests {
    use super::*;

    #[test]
    fn expired_session_recovery_rows_are_removed() {
        let mut store = SqliteSessionStore::open_in_memory().unwrap();
        store
            .connection
            .execute(
                "INSERT INTO active_sessions (
                    agent_name, session_id, cwd, additional_directories_json, updated_at
                 ) VALUES ('agent', 'expired', '/tmp', '[]', 1)",
                [],
            )
            .unwrap();
        store
            .connection
            .execute(
                "INSERT INTO active_sessions (
                    agent_name, session_id, cwd, additional_directories_json, updated_at
                 ) VALUES ('agent', 'active', '/tmp', '[]', unixepoch())",
                [],
            )
            .unwrap();

        let transaction = store.connection.transaction().unwrap();
        delete_expired_sessions(
            &transaction,
            SqliteStoragePolicy::new(1024 * 1024, 30).unwrap(),
        )
        .unwrap();
        transaction.commit().unwrap();

        let sessions = store.load_active("agent").unwrap();
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].session_id, "active");
    }
}
