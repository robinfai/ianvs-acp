use std::collections::HashMap;
use std::path::Path;

use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::workspace::normalize_workspace_identity;
use crate::{
    ExecutionGateError, WorkspaceError, WorkspaceExecutionGate, WorkspaceExecutionLease,
    WorkspaceScope,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskStatus {
    Inbox,
    Queued,
    Dispatched,
    Running,
    BlockedOnPermission,
    BlockedOnUserInput,
    CollectingArtifacts,
    NeedsHumanReview,
    NeedsChanges,
    Done,
    Failed,
    Cancelled,
    Rejected,
}

impl TaskStatus {
    #[must_use]
    pub const fn is_terminal(self) -> bool {
        matches!(
            self,
            Self::Done | Self::Failed | Self::Cancelled | Self::Rejected
        )
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RunStatus {
    Dispatched,
    Running,
    WaitingPermission,
    WaitingUserInput,
    CollectingArtifacts,
    NeedsHumanReview,
    NeedsChanges,
    Succeeded,
    Failed,
    Cancelled,
    Rejected,
}

impl RunStatus {
    #[must_use]
    pub const fn is_terminal(self) -> bool {
        matches!(
            self,
            Self::Succeeded | Self::Failed | Self::Cancelled | Self::Rejected
        )
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TaskState {
    pub id: String,
    pub workspace_path: String,
    pub agent_name: String,
    pub status: TaskStatus,
    pub attempt: u32,
    pub current_run_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RunState {
    pub id: String,
    pub task_id: String,
    pub attempt: u32,
    pub status: RunStatus,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkflowSnapshot {
    pub tasks: Vec<TaskState>,
    pub runs: Vec<RunState>,
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum WorkflowStateError {
    #[error("task id must not be empty")]
    InvalidTaskId,
    #[error("run id must not be empty")]
    InvalidRunId,
    #[error("agent name must not be empty")]
    InvalidAgentName,
    #[error("task already exists: {0}")]
    DuplicateTask(String),
    #[error("run already exists: {0}")]
    DuplicateRun(String),
    #[error("unknown task: {0}")]
    UnknownTask(String),
    #[error("unknown run: {0}")]
    UnknownRun(String),
    #[error("task {task_id} is {actual:?}; expected {expected}")]
    TaskTransition {
        task_id: String,
        actual: TaskStatus,
        expected: &'static str,
    },
    #[error("run {run_id} is {actual:?}; expected {expected}")]
    RunTransition {
        run_id: String,
        actual: RunStatus,
        expected: &'static str,
    },
    #[error("run {run_id} does not belong to the current task run")]
    StaleRun { run_id: String },
    #[error("invalid workflow snapshot: {0}")]
    InvalidSnapshot(String),
    #[error(transparent)]
    Workspace(#[from] WorkspaceError),
    #[error(transparent)]
    Gate(#[from] ExecutionGateError),
}

/// Authoritative Task/Run registry. A dispatched run retains the workspace
/// lease until it reaches a terminal or needs-changes state.
#[derive(Debug, Default)]
pub struct WorkflowStateMachine {
    tasks: HashMap<String, TaskState>,
    runs: HashMap<String, RunState>,
    workspace_gate: WorkspaceExecutionGate,
    leases: HashMap<String, WorkspaceExecutionLease>,
}

impl WorkflowStateMachine {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    pub fn restore(snapshot: WorkflowSnapshot) -> Result<Self, WorkflowStateError> {
        let mut workflow = Self::new();
        for mut task in snapshot.tasks {
            task.id = checked_id(task.id, WorkflowStateError::InvalidTaskId)?;
            task.agent_name = checked_id(task.agent_name, WorkflowStateError::InvalidAgentName)?;
            if workflow.tasks.contains_key(&task.id) {
                return Err(WorkflowStateError::DuplicateTask(task.id));
            }
            task.workspace_path = normalize_workspace_identity(Path::new(&task.workspace_path))?
                .display()
                .to_string();
            workflow.tasks.insert(task.id.clone(), task);
        }
        for run in snapshot.runs {
            let run_id = checked_id(run.id, WorkflowStateError::InvalidRunId)?;
            if workflow.runs.contains_key(&run_id) {
                return Err(WorkflowStateError::DuplicateRun(run_id));
            }
            if run.attempt == 0 {
                return Err(WorkflowStateError::InvalidSnapshot(format!(
                    "run {run_id} has attempt 0"
                )));
            }
            if !workflow.tasks.contains_key(&run.task_id) {
                return Err(WorkflowStateError::UnknownTask(run.task_id));
            }
            workflow
                .runs
                .insert(run_id.clone(), RunState { id: run_id, ..run });
        }
        let active = workflow
            .tasks
            .values()
            .filter_map(|task| {
                task.current_run_id
                    .as_ref()
                    .map(|run_id| (task.id.clone(), run_id.clone()))
            })
            .collect::<Vec<_>>();
        for (task_id, run_id) in active {
            let task = workflow.task(&task_id)?;
            let run = workflow.run(&run_id)?;
            if run.task_id != task.id || run.attempt != task.attempt {
                return Err(WorkflowStateError::StaleRun { run_id });
            }
            if run_requires_lease(run.status) {
                let lease = workflow
                    .workspace_gate
                    .try_acquire(&task.workspace_path, task.id.clone())?;
                workflow.leases.insert(run_id, lease);
            }
        }
        Ok(workflow)
    }

    #[must_use]
    pub fn snapshot(&self) -> WorkflowSnapshot {
        let mut tasks = self.tasks.values().cloned().collect::<Vec<_>>();
        let mut runs = self.runs.values().cloned().collect::<Vec<_>>();
        tasks.sort_by(|left, right| left.id.cmp(&right.id));
        runs.sort_by(|left, right| left.id.cmp(&right.id));
        WorkflowSnapshot { tasks, runs }
    }

    pub fn create_task(
        &mut self,
        task_id: impl Into<String>,
        workspace: impl AsRef<Path>,
        agent_name: impl Into<String>,
    ) -> Result<&TaskState, WorkflowStateError> {
        let task_id = checked_id(task_id.into(), WorkflowStateError::InvalidTaskId)?;
        if self.tasks.contains_key(&task_id) {
            return Err(WorkflowStateError::DuplicateTask(task_id));
        }
        let agent_name = checked_id(agent_name.into(), WorkflowStateError::InvalidAgentName)?;
        let workspace = normalize_workspace_identity(workspace.as_ref())?;
        let task = TaskState {
            id: task_id.clone(),
            workspace_path: workspace.display().to_string(),
            agent_name,
            status: TaskStatus::Inbox,
            attempt: 0,
            current_run_id: None,
        };
        self.tasks.insert(task_id.clone(), task);
        self.task(&task_id)
    }

    pub fn queue_task(&mut self, task_id: &str) -> Result<(), WorkflowStateError> {
        let task = self.task_mut(task_id)?;
        let clears_completed_run =
            matches!(task.status, TaskStatus::NeedsChanges | TaskStatus::Failed);
        transition_task(
            task,
            &[
                TaskStatus::Inbox,
                TaskStatus::NeedsChanges,
                TaskStatus::Failed,
            ],
            TaskStatus::Queued,
            "inbox, needs_changes, or failed",
        )?;
        if clears_completed_run {
            task.current_run_id = None;
        }
        Ok(())
    }

    pub fn queue_completed_task_for_correction(
        &mut self,
        task_id: &str,
    ) -> Result<(), WorkflowStateError> {
        let task = self.task_mut(task_id)?;
        require_task(task, &[TaskStatus::Done], "done")?;
        task.status = TaskStatus::Queued;
        task.current_run_id = None;
        Ok(())
    }

    pub fn update_task_definition(
        &mut self,
        task_id: &str,
        workspace: impl AsRef<Path>,
        agent_name: impl Into<String>,
    ) -> Result<(), WorkflowStateError> {
        let task = self.task(task_id)?;
        require_task(
            task,
            &[TaskStatus::Inbox, TaskStatus::Queued],
            "inbox or queued before first dispatch",
        )?;
        if task.attempt != 0 || task.current_run_id.is_some() {
            return Err(WorkflowStateError::TaskTransition {
                task_id: task.id.clone(),
                actual: task.status,
                expected: "a task before first dispatch",
            });
        }
        let workspace = normalize_workspace_identity(workspace.as_ref())?;
        let agent_name = checked_id(agent_name.into(), WorkflowStateError::InvalidAgentName)?;
        let task = self.task_mut(task_id)?;
        task.workspace_path = workspace.display().to_string();
        task.agent_name = agent_name;
        Ok(())
    }

    pub fn delete_task(&mut self, task_id: &str) -> Result<(), WorkflowStateError> {
        let task = self.task(task_id)?;
        if task
            .current_run_id
            .as_ref()
            .is_some_and(|run_id| self.leases.contains_key(run_id))
        {
            return Err(WorkflowStateError::TaskTransition {
                task_id: task.id.clone(),
                actual: task.status,
                expected: "a task without an active workspace lease",
            });
        }
        let run_ids = self
            .runs
            .values()
            .filter(|run| run.task_id == task_id)
            .map(|run| run.id.clone())
            .collect::<Vec<_>>();
        for run_id in run_ids {
            self.leases.remove(&run_id);
            self.runs.remove(&run_id);
        }
        self.tasks.remove(task_id);
        Ok(())
    }

    pub fn dispatch_task(
        &mut self,
        task_id: &str,
        run_id: impl Into<String>,
    ) -> Result<(), WorkflowStateError> {
        let run_id = checked_id(run_id.into(), WorkflowStateError::InvalidRunId)?;
        if self.runs.contains_key(&run_id) {
            return Err(WorkflowStateError::DuplicateRun(run_id));
        }
        let task = self.task(task_id)?;
        require_task(task, &[TaskStatus::Queued], "queued")?;
        let scope = WorkspaceScope::new(&task.workspace_path, std::iter::empty::<&Path>())?;
        if scope.cwd() != Path::new(&task.workspace_path) {
            return Err(WorkspaceError::IdentityChanged(task.workspace_path.clone()).into());
        }
        let lease = self
            .workspace_gate
            .try_acquire(&task.workspace_path, task_id.to_string())?;
        let attempt = task.attempt.saturating_add(1);
        self.runs.insert(
            run_id.clone(),
            RunState {
                id: run_id.clone(),
                task_id: task_id.to_string(),
                attempt,
                status: RunStatus::Dispatched,
            },
        );
        self.leases.insert(run_id.clone(), lease);
        let task = self.task_mut(task_id)?;
        task.status = TaskStatus::Dispatched;
        task.attempt = attempt;
        task.current_run_id = Some(run_id);
        Ok(())
    }

    pub fn start_run(&mut self, run_id: &str) -> Result<(), WorkflowStateError> {
        self.transition_run_and_task(
            run_id,
            &[RunStatus::Dispatched],
            RunStatus::Running,
            &[TaskStatus::Dispatched],
            TaskStatus::Running,
            "dispatched",
        )
    }

    pub fn wait_for_permission(&mut self, run_id: &str) -> Result<(), WorkflowStateError> {
        self.transition_run_and_task(
            run_id,
            &[RunStatus::Running],
            RunStatus::WaitingPermission,
            &[TaskStatus::Running],
            TaskStatus::BlockedOnPermission,
            "running",
        )
    }

    pub fn wait_for_user_input(&mut self, run_id: &str) -> Result<(), WorkflowStateError> {
        self.transition_run_and_task(
            run_id,
            &[RunStatus::Running],
            RunStatus::WaitingUserInput,
            &[TaskStatus::Running],
            TaskStatus::BlockedOnUserInput,
            "running",
        )
    }

    pub fn resume_run(&mut self, run_id: &str) -> Result<(), WorkflowStateError> {
        self.transition_run_and_task(
            run_id,
            &[RunStatus::WaitingPermission, RunStatus::WaitingUserInput],
            RunStatus::Running,
            &[
                TaskStatus::BlockedOnPermission,
                TaskStatus::BlockedOnUserInput,
            ],
            TaskStatus::Running,
            "waiting_permission or waiting_user_input",
        )
    }

    pub fn collect_artifacts(&mut self, run_id: &str) -> Result<(), WorkflowStateError> {
        self.transition_run_and_task(
            run_id,
            &[RunStatus::Running],
            RunStatus::CollectingArtifacts,
            &[TaskStatus::Running],
            TaskStatus::CollectingArtifacts,
            "running",
        )
    }

    pub fn require_human_review(&mut self, run_id: &str) -> Result<(), WorkflowStateError> {
        self.transition_run_and_task(
            run_id,
            &[RunStatus::CollectingArtifacts],
            RunStatus::NeedsHumanReview,
            &[TaskStatus::CollectingArtifacts],
            TaskStatus::NeedsHumanReview,
            "collecting_artifacts",
        )
    }

    pub fn request_changes(&mut self, run_id: &str) -> Result<(), WorkflowStateError> {
        self.transition_run_and_task(
            run_id,
            &[RunStatus::NeedsHumanReview],
            RunStatus::NeedsChanges,
            &[TaskStatus::NeedsHumanReview],
            TaskStatus::NeedsChanges,
            "needs_human_review",
        )?;
        self.release_run(run_id);
        Ok(())
    }

    pub fn complete_run(&mut self, run_id: &str) -> Result<(), WorkflowStateError> {
        self.transition_run_and_task(
            run_id,
            &[RunStatus::CollectingArtifacts, RunStatus::NeedsHumanReview],
            RunStatus::Succeeded,
            &[
                TaskStatus::CollectingArtifacts,
                TaskStatus::NeedsHumanReview,
            ],
            TaskStatus::Done,
            "collecting_artifacts or needs_human_review",
        )?;
        self.release_run(run_id);
        Ok(())
    }

    pub fn fail_run(&mut self, run_id: &str) -> Result<(), WorkflowStateError> {
        self.finish_run(run_id, RunStatus::Failed, TaskStatus::Failed)
    }

    pub fn reject_run(&mut self, run_id: &str) -> Result<(), WorkflowStateError> {
        self.finish_run(run_id, RunStatus::Rejected, TaskStatus::Rejected)
    }

    pub fn cancel_task(&mut self, task_id: &str) -> Result<(), WorkflowStateError> {
        let current_run_id = self.task(task_id)?.current_run_id.clone();
        if let Some(run_id) = current_run_id
            && !self.run(&run_id)?.status.is_terminal()
        {
            self.run_mut(&run_id)?.status = RunStatus::Cancelled;
            self.release_run(&run_id);
        }
        let task = self.task_mut(task_id)?;
        if task.status.is_terminal() {
            return Err(WorkflowStateError::TaskTransition {
                task_id: task.id.clone(),
                actual: task.status,
                expected: "a non-terminal task",
            });
        }
        task.status = TaskStatus::Cancelled;
        Ok(())
    }

    pub fn task(&self, task_id: &str) -> Result<&TaskState, WorkflowStateError> {
        self.tasks
            .get(task_id)
            .ok_or_else(|| WorkflowStateError::UnknownTask(task_id.to_string()))
    }

    pub fn run(&self, run_id: &str) -> Result<&RunState, WorkflowStateError> {
        self.runs
            .get(run_id)
            .ok_or_else(|| WorkflowStateError::UnknownRun(run_id.to_string()))
    }

    #[must_use]
    pub fn workspace_owner(&self, workspace: impl AsRef<Path>) -> Option<String> {
        self.workspace_gate.owner(workspace)
    }

    #[must_use]
    pub fn active_run_count(&self) -> usize {
        self.leases.len()
    }

    /// Count Runs that still consume executor capacity. Workspace mutation
    /// leases intentionally outlive executor capacity while a Run waits for
    /// human review.
    #[must_use]
    pub fn active_execution_count(&self) -> usize {
        self.runs
            .values()
            .filter(|run| run_consumes_execution_capacity(run.status))
            .count()
    }

    #[must_use]
    pub fn active_run_count_for_agent(&self, agent_name: &str) -> usize {
        self.leases
            .keys()
            .filter_map(|run_id| self.runs.get(run_id))
            .filter_map(|run| self.tasks.get(&run.task_id))
            .filter(|task| task.agent_name == agent_name)
            .count()
    }

    #[must_use]
    pub fn active_execution_count_for_agent(&self, agent_name: &str) -> usize {
        self.runs
            .values()
            .filter(|run| run_consumes_execution_capacity(run.status))
            .filter_map(|run| self.tasks.get(&run.task_id))
            .filter(|task| task.agent_name == agent_name)
            .count()
    }

    fn finish_run(
        &mut self,
        run_id: &str,
        next_run: RunStatus,
        next_task: TaskStatus,
    ) -> Result<(), WorkflowStateError> {
        let run = self.run(run_id)?;
        if run.status.is_terminal() {
            return Err(WorkflowStateError::RunTransition {
                run_id: run.id.clone(),
                actual: run.status,
                expected: "a non-terminal run",
            });
        }
        let task_id = self.current_task_id_for_run(run_id)?;
        self.run_mut(run_id)?.status = next_run;
        self.task_mut(&task_id)?.status = next_task;
        self.release_run(run_id);
        Ok(())
    }

    #[allow(clippy::too_many_arguments)]
    fn transition_run_and_task(
        &mut self,
        run_id: &str,
        allowed_run: &[RunStatus],
        next_run: RunStatus,
        allowed_task: &[TaskStatus],
        next_task: TaskStatus,
        expected: &'static str,
    ) -> Result<(), WorkflowStateError> {
        let task_id = self.current_task_id_for_run(run_id)?;
        require_run(self.run(run_id)?, allowed_run, expected)?;
        require_task(self.task(&task_id)?, allowed_task, expected)?;
        self.run_mut(run_id)?.status = next_run;
        self.task_mut(&task_id)?.status = next_task;
        Ok(())
    }

    fn current_task_id_for_run(&self, run_id: &str) -> Result<String, WorkflowStateError> {
        let run = self.run(run_id)?;
        let task = self.task(&run.task_id)?;
        if task.current_run_id.as_deref() != Some(run_id) {
            return Err(WorkflowStateError::StaleRun {
                run_id: run_id.to_string(),
            });
        }
        Ok(run.task_id.clone())
    }

    fn task_mut(&mut self, task_id: &str) -> Result<&mut TaskState, WorkflowStateError> {
        self.tasks
            .get_mut(task_id)
            .ok_or_else(|| WorkflowStateError::UnknownTask(task_id.to_string()))
    }

    fn run_mut(&mut self, run_id: &str) -> Result<&mut RunState, WorkflowStateError> {
        self.runs
            .get_mut(run_id)
            .ok_or_else(|| WorkflowStateError::UnknownRun(run_id.to_string()))
    }

    fn release_run(&mut self, run_id: &str) {
        self.leases.remove(run_id);
    }
}

const fn run_requires_lease(status: RunStatus) -> bool {
    matches!(
        status,
        RunStatus::Dispatched
            | RunStatus::Running
            | RunStatus::WaitingPermission
            | RunStatus::WaitingUserInput
            | RunStatus::CollectingArtifacts
            | RunStatus::NeedsHumanReview
    )
}

const fn run_consumes_execution_capacity(status: RunStatus) -> bool {
    matches!(
        status,
        RunStatus::Dispatched
            | RunStatus::Running
            | RunStatus::WaitingPermission
            | RunStatus::CollectingArtifacts
    )
}

fn checked_id(value: String, error: WorkflowStateError) -> Result<String, WorkflowStateError> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        Err(error)
    } else if trimmed.len() == value.len() {
        Ok(value)
    } else {
        Ok(trimmed.to_string())
    }
}

fn require_task(
    task: &TaskState,
    allowed: &[TaskStatus],
    expected: &'static str,
) -> Result<(), WorkflowStateError> {
    if allowed.contains(&task.status) {
        Ok(())
    } else {
        Err(WorkflowStateError::TaskTransition {
            task_id: task.id.clone(),
            actual: task.status,
            expected,
        })
    }
}

fn transition_task(
    task: &mut TaskState,
    allowed: &[TaskStatus],
    next: TaskStatus,
    expected: &'static str,
) -> Result<(), WorkflowStateError> {
    require_task(task, allowed, expected)?;
    task.status = next;
    Ok(())
}

fn require_run(
    run: &RunState,
    allowed: &[RunStatus],
    expected: &'static str,
) -> Result<(), WorkflowStateError> {
    if allowed.contains(&run.status) {
        Ok(())
    } else {
        Err(WorkflowStateError::RunTransition {
            run_id: run.id.clone(),
            actual: run.status,
            expected,
        })
    }
}
