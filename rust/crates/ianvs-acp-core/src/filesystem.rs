use std::collections::HashMap;
use std::ffi::CString;
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
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
const WRITE_PREVIEW_MAX_BYTES: usize = 16 * 1024;

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
    pub line: Option<u32>,
    pub limit: Option<u32>,
    pub write_bytes: Option<usize>,
    pub content_preview: Option<String>,
    pub content_truncated: Option<bool>,
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
        directory: File,
        directory_path: PathBuf,
        directory_device: u64,
        directory_inode: u64,
        file_name: CString,
        existing: Option<FileIdentity>,
        content: String,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct FileIdentity {
    device: libc::dev_t,
    inode: libc::ino_t,
    mode: libc::mode_t,
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
            line,
            limit,
            write_bytes: None,
            content_preview: None,
            content_truncated: None,
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
        let parent = path.parent().ok_or(FilesystemError::InvalidPath)?;
        let file_name = path.file_name().ok_or(FilesystemError::InvalidPath)?;
        let file_name =
            CString::new(file_name.as_bytes()).map_err(|_| FilesystemError::InvalidPath)?;
        let directory = open_verified_directory(parent)?;
        let directory_metadata = directory.metadata().map_err(|error| io_error(&error))?;
        let existing = file_identity_at(&directory, &file_name)?;
        if existing.is_some_and(|identity| !identity.is_regular()) {
            return Err(FilesystemError::NotRegularFile(path.display().to_string()));
        }
        let approval_id = Uuid::new_v4().to_string();
        let canonical_path = path.display().to_string();
        let content_preview = utf8_prefix(&content, WRITE_PREVIEW_MAX_BYTES).to_string();
        let content_truncated = content_preview.len() < content.len();
        let write_bytes = content.len();
        self.pending
            .lock()
            .expect("filesystem pending mutex poisoned")
            .insert(
                approval_id.clone(),
                PreparedFilesystemOperation::Write {
                    directory,
                    directory_path: parent.to_path_buf(),
                    directory_device: directory_metadata.dev(),
                    directory_inode: directory_metadata.ino(),
                    file_name,
                    existing,
                    content,
                },
            );
        Ok(FilesystemApproval {
            approval_id,
            session_id,
            kind: FilesystemOperationKind::Write,
            path: canonical_path,
            line: None,
            limit: None,
            write_bytes: Some(write_bytes),
            content_preview: Some(content_preview),
            content_truncated: Some(content_truncated),
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
            directory,
            directory_path,
            directory_device,
            directory_inode,
            file_name,
            existing,
            content,
        } => {
            write_text_atomic(
                &directory,
                &directory_path,
                directory_device,
                directory_inode,
                &file_name,
                existing,
                content.as_bytes(),
            )?;
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

fn utf8_prefix(value: &str, max_bytes: usize) -> &str {
    if value.len() <= max_bytes {
        return value;
    }
    let mut end = max_bytes;
    while !value.is_char_boundary(end) {
        end = end.saturating_sub(1);
    }
    &value[..end]
}

fn write_text_atomic(
    directory: &File,
    directory_path: &Path,
    directory_device: u64,
    directory_inode: u64,
    file_name: &CString,
    existing: Option<FileIdentity>,
    bytes: &[u8],
) -> Result<(), FilesystemError> {
    if bytes.len() > MAX_WRITE_BYTES {
        return Err(FilesystemError::WriteLimit);
    }
    let current_directory =
        fs::symlink_metadata(directory_path).map_err(|_| FilesystemError::OperationChanged)?;
    if !current_directory.is_dir()
        || current_directory.dev() != directory_device
        || current_directory.ino() != directory_inode
    {
        return Err(FilesystemError::OperationChanged);
    }
    if file_identity_at(directory, file_name)? != existing {
        return Err(FilesystemError::OperationChanged);
    }
    let temporary = CString::new(format!(".ianvs-acp-{}.tmp", Uuid::new_v4()))
        .expect("UUID temporary file name must not contain NUL");
    // Match OpenOptions::create_new for new files: 0666 filtered by the
    // process umask. Existing files get their approved permission/executable
    // bits restored explicitly after creating the replacement inode.
    let mode = existing.map_or(0o666, |identity| identity.mode & 0o777);
    let create_mode = u32::from(mode);
    let descriptor = unsafe {
        libc::openat(
            directory.as_raw_fd(),
            temporary.as_ptr(),
            libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_CLOEXEC | libc::O_NOFOLLOW,
            create_mode,
        )
    };
    if descriptor < 0 {
        return Err(io_error(&std::io::Error::last_os_error()));
    }
    let mut temporary_file = unsafe { File::from_raw_fd(descriptor) };
    (|| {
        if existing.is_some() && unsafe { libc::fchmod(temporary_file.as_raw_fd(), mode) } != 0 {
            return Err(io_error(&std::io::Error::last_os_error()));
        }
        temporary_file
            .write_all(bytes)
            .map_err(|error| io_error(&error))?;
        temporary_file
            .sync_all()
            .map_err(|error| io_error(&error))?;
        commit_temporary_file(directory, &temporary, file_name, existing)
    })()
}

fn commit_temporary_file(
    directory: &File,
    temporary: &CString,
    file_name: &CString,
    existing: Option<FileIdentity>,
) -> Result<(), FilesystemError> {
    let directory_fd = directory.as_raw_fd();
    if existing.is_none() {
        if unsafe {
            libc::linkat(
                directory_fd,
                temporary.as_ptr(),
                directory_fd,
                file_name.as_ptr(),
                0,
            )
        } != 0
        {
            let error = std::io::Error::last_os_error();
            unsafe {
                libc::unlinkat(directory_fd, temporary.as_ptr(), 0);
            }
            return if error.raw_os_error() == Some(libc::EEXIST) {
                Err(FilesystemError::OperationChanged)
            } else {
                Err(io_error(&error))
            };
        }
        if unsafe { libc::unlinkat(directory_fd, temporary.as_ptr(), 0) } != 0 {
            return Err(io_error(&std::io::Error::last_os_error()));
        }
        return sync_directory(directory);
    }

    if let Err(error) = exchange_at(directory_fd, temporary, file_name) {
        unsafe {
            libc::unlinkat(directory_fd, temporary.as_ptr(), 0);
        }
        return Err(error);
    }

    let expected = existing.expect("existing target checked above");
    let displaced = file_identity_at(directory, temporary);
    if displaced.as_ref().ok().copied().flatten() != Some(expected) {
        // The exchange moved the competing target out of the public name
        // without destroying it. Put it back atomically before reporting the
        // approval race; only then is it safe to remove our temporary inode.
        if let Err(rollback_error) = exchange_at(directory_fd, temporary, file_name) {
            return Err(FilesystemError::Io(format!(
                "filesystem target changed and atomic rollback failed: {rollback_error}"
            )));
        }
        unsafe {
            libc::unlinkat(directory_fd, temporary.as_ptr(), 0);
        }
        return match displaced {
            Ok(_) => Err(FilesystemError::OperationChanged),
            Err(error) => Err(error),
        };
    }

    if unsafe { libc::unlinkat(directory_fd, temporary.as_ptr(), 0) } != 0 {
        return Err(io_error(&std::io::Error::last_os_error()));
    }
    sync_directory(directory)
}

#[cfg(target_os = "linux")]
fn exchange_at(
    directory_fd: libc::c_int,
    left: &CString,
    right: &CString,
) -> Result<(), FilesystemError> {
    if unsafe {
        libc::renameat2(
            directory_fd,
            left.as_ptr(),
            directory_fd,
            right.as_ptr(),
            libc::RENAME_EXCHANGE,
        )
    } != 0
    {
        return Err(io_error(&std::io::Error::last_os_error()));
    }
    Ok(())
}

#[cfg(target_os = "macos")]
fn exchange_at(
    directory_fd: libc::c_int,
    left: &CString,
    right: &CString,
) -> Result<(), FilesystemError> {
    if unsafe {
        libc::renameatx_np(
            directory_fd,
            left.as_ptr(),
            directory_fd,
            right.as_ptr(),
            libc::RENAME_SWAP,
        )
    } != 0
    {
        return Err(io_error(&std::io::Error::last_os_error()));
    }
    Ok(())
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
fn exchange_at(
    _directory_fd: libc::c_int,
    _left: &CString,
    _right: &CString,
) -> Result<(), FilesystemError> {
    Err(FilesystemError::Io(
        "atomic exchange is unsupported on this platform".to_string(),
    ))
}

fn sync_directory(directory: &File) -> Result<(), FilesystemError> {
    if unsafe { libc::fsync(directory.as_raw_fd()) } != 0 {
        return Err(io_error(&std::io::Error::last_os_error()));
    }
    Ok(())
}

impl FileIdentity {
    fn is_regular(self) -> bool {
        self.mode & libc::S_IFMT == libc::S_IFREG
    }
}

fn open_verified_directory(path: &Path) -> Result<File, FilesystemError> {
    let expected = fs::symlink_metadata(path).map_err(|error| io_error(&error))?;
    if !expected.is_dir() {
        return Err(FilesystemError::OperationChanged);
    }
    let directory = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)
        .map_err(|error| io_error(&error))?;
    let opened = directory.metadata().map_err(|error| io_error(&error))?;
    if !opened.is_dir() || opened.dev() != expected.dev() || opened.ino() != expected.ino() {
        return Err(FilesystemError::OperationChanged);
    }
    Ok(directory)
}

fn file_identity_at(
    directory: &File,
    file_name: &CString,
) -> Result<Option<FileIdentity>, FilesystemError> {
    let mut metadata = std::mem::MaybeUninit::<libc::stat>::uninit();
    if unsafe {
        libc::fstatat(
            directory.as_raw_fd(),
            file_name.as_ptr(),
            metadata.as_mut_ptr(),
            libc::AT_SYMLINK_NOFOLLOW,
        )
    } != 0
    {
        let error = std::io::Error::last_os_error();
        if error.raw_os_error() == Some(libc::ENOENT) {
            return Ok(None);
        }
        return Err(io_error(&error));
    }
    let metadata = unsafe { metadata.assume_init() };
    Ok(Some(FileIdentity {
        device: metadata.st_dev,
        inode: metadata.st_ino,
        mode: metadata.st_mode,
    }))
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

#[cfg(test)]
mod tests {
    use super::{
        FilesystemError, commit_temporary_file, file_identity_at, open_verified_directory,
    };
    use std::ffi::CString;
    use std::fs;

    fn temporary_directory(label: &str) -> std::path::PathBuf {
        let path =
            std::env::temp_dir().join(format!("ianvs-filesystem-{label}-{}", uuid::Uuid::new_v4()));
        fs::create_dir(&path).unwrap();
        path
    }

    #[test]
    fn new_file_commit_never_replaces_a_racing_target() {
        let path = temporary_directory("new-race");
        fs::write(path.join("temporary"), "approved content").unwrap();
        fs::write(path.join("target"), "racing content").unwrap();
        let directory = open_verified_directory(&path).unwrap();
        let temporary = CString::new("temporary").unwrap();
        let target = CString::new("target").unwrap();

        assert!(matches!(
            commit_temporary_file(&directory, &temporary, &target, None),
            Err(FilesystemError::OperationChanged)
        ));
        assert_eq!(
            fs::read_to_string(path.join("target")).unwrap(),
            "racing content"
        );
        assert!(!path.join("temporary").exists());
        fs::remove_dir_all(path).unwrap();
    }

    #[test]
    fn existing_file_commit_rolls_back_a_racing_inode() {
        let path = temporary_directory("existing-race");
        fs::write(path.join("target"), "approved old content").unwrap();
        let directory = open_verified_directory(&path).unwrap();
        let target = CString::new("target").unwrap();
        let approved = file_identity_at(&directory, &target).unwrap().unwrap();
        fs::rename(path.join("target"), path.join("approved-backup")).unwrap();
        fs::write(path.join("target"), "racing content").unwrap();
        fs::write(path.join("temporary"), "approved new content").unwrap();
        let temporary = CString::new("temporary").unwrap();

        assert!(matches!(
            commit_temporary_file(&directory, &temporary, &target, Some(approved)),
            Err(FilesystemError::OperationChanged)
        ));
        assert_eq!(
            fs::read_to_string(path.join("target")).unwrap(),
            "racing content"
        );
        assert_eq!(
            fs::read_to_string(path.join("approved-backup")).unwrap(),
            "approved old content"
        );
        assert!(!path.join("temporary").exists());
        fs::remove_dir_all(path).unwrap();
    }
}
