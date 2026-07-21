use std::collections::HashMap;
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use thiserror::Error;
use uuid::Uuid;

use crate::{WorkspaceError, WorkspaceScope};

const MAX_PENDING_OPERATIONS: usize = 64;
const MAX_PENDING_WRITE_BYTES: usize = 32 * 1024 * 1024;
const MAX_READ_FILE_BYTES: u64 = 8 * 1024 * 1024;
const MAX_READ_RETURNED_BYTES: usize = 2 * 1024 * 1024;
const MAX_WRITE_BYTES: usize = 8 * 1024 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FilesystemConfig {
    pub read_text_file: bool,
    pub write_text_file: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FilesystemOperationKind {
    Read,
    Write,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FilesystemApproval {
    pub approval_id: String,
    pub session_id: String,
    pub kind: FilesystemOperationKind,
    pub path: String,
}

#[derive(Debug, PartialEq, Eq)]
pub enum FilesystemOperationResult {
    Read(String),
    Written,
}

#[derive(Debug, Error)]
pub enum FilesystemError {
    #[error("filesystem read provider is disabled")]
    ReadDisabled,
    #[error("filesystem write provider is disabled")]
    WriteDisabled,
    #[error("filesystem session is not registered: {0}")]
    UnknownSession(String),
    #[error("filesystem approval is not pending: {0}")]
    UnknownApproval(String),
    #[error("filesystem pending-operation capacity reached")]
    Capacity,
    #[error("filesystem request path is invalid")]
    InvalidPath,
    #[error("filesystem line must be one-based")]
    InvalidLine,
    #[error("filesystem target is not a regular file: {0}")]
    NotRegularFile(String),
    #[error("filesystem read exceeds the bounded policy")]
    ReadLimit,
    #[error("filesystem write exceeds the bounded policy")]
    WriteLimit,
    #[error("filesystem content is not valid UTF-8")]
    InvalidUtf8,
    #[error("filesystem operation changed after approval")]
    OperationChanged,
    #[error("filesystem I/O failed: {0}")]
    Io(String),
    #[error(transparent)]
    Workspace(#[from] WorkspaceError),
}

#[derive(Debug)]
enum PreparedFilesystemOperation {
    Read {
        scope: WorkspaceScope,
        path: PathBuf,
        line: Option<u32>,
        limit: Option<u32>,
        device: u64,
        inode: u64,
        size: u64,
    },
    Write {
        scope: WorkspaceScope,
        path: PathBuf,
        content: String,
    },
}

impl PreparedFilesystemOperation {
    fn content_bytes(&self) -> usize {
        match self {
            Self::Read { .. } => 0,
            Self::Write { content, .. } => content.len(),
        }
    }
}

#[derive(Debug)]
pub struct FilesystemManager {
    config: FilesystemConfig,
    admission: Mutex<()>,
    scopes: Mutex<HashMap<String, WorkspaceScope>>,
    pending: Mutex<HashMap<String, PreparedFilesystemOperation>>,
}

impl FilesystemManager {
    #[must_use]
    pub fn new(config: FilesystemConfig) -> Self {
        Self {
            config,
            admission: Mutex::new(()),
            scopes: Mutex::new(HashMap::new()),
            pending: Mutex::new(HashMap::new()),
        }
    }

    pub fn register_session(
        &self,
        session_id: &str,
        scope: WorkspaceScope,
    ) -> Result<(), FilesystemError> {
        let session_id = canonical_session_id(session_id)?;
        self.scopes
            .lock()
            .expect("filesystem scope mutex poisoned")
            .insert(session_id, scope);
        Ok(())
    }

    pub fn request_read(
        &self,
        session_id: &str,
        path: &Path,
        line: Option<u32>,
        limit: Option<u32>,
    ) -> Result<FilesystemApproval, FilesystemError> {
        if !self.config.read_text_file {
            return Err(FilesystemError::ReadDisabled);
        }
        if line == Some(0) {
            return Err(FilesystemError::InvalidLine);
        }
        let _admission = self
            .admission
            .lock()
            .expect("filesystem admission mutex poisoned");
        self.require_capacity(0)?;
        let (session_id, scope) = self.scope(session_id)?;
        let path = scope.resolve_existing(path)?;
        let metadata = fs::metadata(&path).map_err(|error| io_error(&error))?;
        if !metadata.is_file() {
            return Err(FilesystemError::NotRegularFile(path.display().to_string()));
        }
        if metadata.len() > MAX_READ_FILE_BYTES {
            return Err(FilesystemError::ReadLimit);
        }
        let approval_id = Uuid::new_v4().to_string();
        let canonical_path = path.display().to_string();
        self.pending
            .lock()
            .expect("filesystem pending mutex poisoned")
            .insert(
                approval_id.clone(),
                PreparedFilesystemOperation::Read {
                    scope,
                    path,
                    line,
                    limit,
                    device: metadata.dev(),
                    inode: metadata.ino(),
                    size: metadata.len(),
                },
            );
        Ok(FilesystemApproval {
            approval_id,
            session_id,
            kind: FilesystemOperationKind::Read,
            path: canonical_path,
        })
    }

    pub fn request_write(
        &self,
        session_id: &str,
        path: &Path,
        content: String,
    ) -> Result<FilesystemApproval, FilesystemError> {
        if !self.config.write_text_file {
            return Err(FilesystemError::WriteDisabled);
        }
        if content.len() > MAX_WRITE_BYTES {
            return Err(FilesystemError::WriteLimit);
        }
        let _admission = self
            .admission
            .lock()
            .expect("filesystem admission mutex poisoned");
        self.require_capacity(content.len())?;
        let (session_id, scope) = self.scope(session_id)?;
        let path = scope.resolve_for_creation(path)?;
        if path.exists() && !path.is_file() {
            return Err(FilesystemError::NotRegularFile(path.display().to_string()));
        }
        let approval_id = Uuid::new_v4().to_string();
        let canonical_path = path.display().to_string();
        self.pending
            .lock()
            .expect("filesystem pending mutex poisoned")
            .insert(
                approval_id.clone(),
                PreparedFilesystemOperation::Write {
                    scope,
                    path,
                    content,
                },
            );
        Ok(FilesystemApproval {
            approval_id,
            session_id,
            kind: FilesystemOperationKind::Write,
            path: canonical_path,
        })
    }

    pub fn approve(&self, approval_id: &str) -> Result<FilesystemOperationResult, FilesystemError> {
        let _admission = self
            .admission
            .lock()
            .expect("filesystem admission mutex poisoned");
        let prepared = self.take_pending(approval_id)?;
        execute(prepared)
    }

    pub fn deny(&self, approval_id: &str) -> Result<(), FilesystemError> {
        let _admission = self
            .admission
            .lock()
            .expect("filesystem admission mutex poisoned");
        self.take_pending(approval_id)?;
        Ok(())
    }

    pub fn close_session(&self, session_id: &str) -> Result<(), FilesystemError> {
        let session_id = canonical_session_id(session_id)?;
        self.scopes
            .lock()
            .expect("filesystem scope mutex poisoned")
            .remove(&session_id);
        Ok(())
    }

    fn scope(&self, session_id: &str) -> Result<(String, WorkspaceScope), FilesystemError> {
        let session_id = canonical_session_id(session_id)?;
        let scope = self
            .scopes
            .lock()
            .expect("filesystem scope mutex poisoned")
            .get(&session_id)
            .cloned()
            .ok_or_else(|| FilesystemError::UnknownSession(session_id.clone()))?;
        Ok((session_id, scope))
    }

    fn require_capacity(&self, added_write_bytes: usize) -> Result<(), FilesystemError> {
        let pending = self
            .pending
            .lock()
            .expect("filesystem pending mutex poisoned");
        if pending.len() >= MAX_PENDING_OPERATIONS {
            return Err(FilesystemError::Capacity);
        }
        let pending_bytes = pending
            .values()
            .map(PreparedFilesystemOperation::content_bytes)
            .sum::<usize>();
        if added_write_bytes > MAX_PENDING_WRITE_BYTES.saturating_sub(pending_bytes) {
            return Err(FilesystemError::Capacity);
        }
        Ok(())
    }

    fn take_pending(
        &self,
        approval_id: &str,
    ) -> Result<PreparedFilesystemOperation, FilesystemError> {
        self.pending
            .lock()
            .expect("filesystem pending mutex poisoned")
            .remove(approval_id)
            .ok_or_else(|| FilesystemError::UnknownApproval(approval_id.to_string()))
    }
}

fn execute(
    prepared: PreparedFilesystemOperation,
) -> Result<FilesystemOperationResult, FilesystemError> {
    match prepared {
        PreparedFilesystemOperation::Read {
            scope,
            path,
            line,
            limit,
            device,
            inode,
            size,
        } => {
            scope.resolve_existing(&path)?;
            read_text(&path, line, limit, device, inode, size).map(FilesystemOperationResult::Read)
        }
        PreparedFilesystemOperation::Write {
            scope,
            path,
            content,
        } => {
            write_text_atomic(&scope, &path, content.as_bytes())?;
            Ok(FilesystemOperationResult::Written)
        }
    }
}

fn read_text(
    path: &Path,
    line: Option<u32>,
    limit: Option<u32>,
    device: u64,
    inode: u64,
    expected_size: u64,
) -> Result<String, FilesystemError> {
    let file = File::open(path).map_err(|error| io_error(&error))?;
    let metadata = file.metadata().map_err(|error| io_error(&error))?;
    if !metadata.is_file()
        || metadata.dev() != device
        || metadata.ino() != inode
        || metadata.len() != expected_size
    {
        return Err(FilesystemError::OperationChanged);
    }
    let mut bytes = Vec::with_capacity(usize::try_from(expected_size).unwrap_or(0));
    file.take(MAX_READ_FILE_BYTES.saturating_add(1))
        .read_to_end(&mut bytes)
        .map_err(|error| io_error(&error))?;
    if u64::try_from(bytes.len()).ok() != Some(expected_size) {
        return Err(FilesystemError::OperationChanged);
    }
    let content = String::from_utf8(bytes).map_err(|_| FilesystemError::InvalidUtf8)?;
    let selected = select_lines(&content, line, limit);
    if selected.len() > MAX_READ_RETURNED_BYTES {
        return Err(FilesystemError::ReadLimit);
    }
    Ok(selected)
}

fn select_lines(content: &str, line: Option<u32>, limit: Option<u32>) -> String {
    if line.is_none() && limit.is_none() {
        return content.to_string();
    }
    let start = line.unwrap_or(1).saturating_sub(1) as usize;
    let take = limit.map_or(usize::MAX, |value| value as usize);
    content
        .split_inclusive('\n')
        .skip(start)
        .take(take)
        .collect()
}

fn write_text_atomic(
    scope: &WorkspaceScope,
    path: &Path,
    bytes: &[u8],
) -> Result<(), FilesystemError> {
    if bytes.len() > MAX_WRITE_BYTES {
        return Err(FilesystemError::WriteLimit);
    }
    let resolved = scope.resolve_for_creation(path)?;
    if resolved != path {
        return Err(FilesystemError::OperationChanged);
    }
    let parent = path.parent().ok_or(FilesystemError::InvalidPath)?;
    let canonical_parent = scope.resolve_existing(parent)?;
    if !canonical_parent.is_dir() || canonical_parent != parent {
        return Err(FilesystemError::OperationChanged);
    }
    let temporary = canonical_parent.join(format!(".ianvs-acp-{}.tmp", Uuid::new_v4()));
    let result = (|| {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temporary)
            .map_err(|error| io_error(&error))?;
        file.write_all(bytes).map_err(|error| io_error(&error))?;
        file.sync_all().map_err(|error| io_error(&error))?;
        fs::rename(&temporary, path).map_err(|error| io_error(&error))?;
        File::open(&canonical_parent)
            .and_then(|directory| directory.sync_all())
            .map_err(|error| io_error(&error))?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

fn canonical_session_id(session_id: &str) -> Result<String, FilesystemError> {
    if session_id.is_empty() || session_id.trim() != session_id || session_id.contains('\0') {
        Err(FilesystemError::UnknownSession(session_id.to_string()))
    } else {
        Ok(session_id.to_string())
    }
}

fn io_error(error: &std::io::Error) -> FilesystemError {
    FilesystemError::Io(error.to_string())
}
