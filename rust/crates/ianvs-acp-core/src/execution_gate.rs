use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use thiserror::Error;

/// A workspace mutation could not be admitted.
#[derive(Debug, Error, PartialEq, Eq)]
pub enum ExecutionGateError {
    #[error("workspace must be an absolute canonical path")]
    InvalidWorkspace,
    #[error("task id must not be empty")]
    InvalidTaskId,
    #[error("workspace is already owned by task {owner}")]
    Busy { owner: String },
}

#[derive(Debug, Default)]
struct GateState {
    owners: HashMap<PathBuf, String>,
}

/// Process-wide workspace execution gate owned by the Rust runtime.
#[derive(Debug, Clone, Default)]
pub struct WorkspaceExecutionGate {
    state: Arc<Mutex<GateState>>,
}

impl WorkspaceExecutionGate {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Acquire exclusive mutation rights for one canonical workspace.
    pub fn try_acquire(
        &self,
        workspace: impl AsRef<Path>,
        task_id: impl Into<String>,
    ) -> Result<WorkspaceExecutionLease, ExecutionGateError> {
        let workspace = workspace.as_ref();
        if !workspace.is_absolute()
            || workspace
                .components()
                .any(|part| matches!(part, std::path::Component::ParentDir))
        {
            return Err(ExecutionGateError::InvalidWorkspace);
        }
        let task_id = task_id.into();
        let task_id = task_id.trim();
        if task_id.is_empty() {
            return Err(ExecutionGateError::InvalidTaskId);
        }
        let mut state = self.state.lock().expect("execution gate mutex poisoned");
        if let Some(owner) = state.owners.get(workspace) {
            return Err(ExecutionGateError::Busy {
                owner: owner.clone(),
            });
        }
        state
            .owners
            .insert(workspace.to_path_buf(), task_id.to_string());
        Ok(WorkspaceExecutionLease {
            state: Arc::clone(&self.state),
            workspace: workspace.to_path_buf(),
            task_id: task_id.to_string(),
            released: false,
        })
    }

    #[must_use]
    pub fn owner(&self, workspace: impl AsRef<Path>) -> Option<String> {
        self.state
            .lock()
            .expect("execution gate mutex poisoned")
            .owners
            .get(workspace.as_ref())
            .cloned()
    }
}

/// RAII lease so cancellation, panic, or early returns cannot strand a lock.
#[derive(Debug)]
pub struct WorkspaceExecutionLease {
    state: Arc<Mutex<GateState>>,
    workspace: PathBuf,
    task_id: String,
    released: bool,
}

impl WorkspaceExecutionLease {
    pub fn release(mut self) {
        self.release_inner();
    }

    fn release_inner(&mut self) {
        if self.released {
            return;
        }
        let mut state = self.state.lock().expect("execution gate mutex poisoned");
        if state.owners.get(&self.workspace) == Some(&self.task_id) {
            state.owners.remove(&self.workspace);
        }
        self.released = true;
    }
}

impl Drop for WorkspaceExecutionLease {
    fn drop(&mut self) {
        self.release_inner();
    }
}
