use std::collections::{BTreeMap, HashMap, HashSet};

use serde::{Deserialize, Serialize};
use serde_json::Value;
use thiserror::Error;

use crate::{
    RunState, RunStatus, TaskState, TaskStatus, WorkflowSnapshot, WorkflowStateError,
    WorkflowStateMachine,
};

pub const TASK_INBOX_SCHEMA: &str = "ianvs-acp.task-inbox.v1";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum InboxTaskStatus {
    Inbox,
    Queued,
    Dispatched,
    Running,
    BlockedOnPermission,
    BlockedOnUserInput,
    CollectingArtifacts,
    NeedsHumanReview,
    ApprovedForExport,
    Exporting,
    Done,
    Failed,
    Cancelled,
    Rejected,
    NeedsChanges,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum InboxTaskPriority {
    Low,
    Normal,
    High,
    Urgent,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum InboxEventKind {
    User,
    Assistant,
    Tool,
    Status,
    Permission,
    Review,
    Artifact,
    Export,
    Error,
    System,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum InboxArtifactKind {
    GitDiff,
    GitStatus,
    File,
    OutboxFile,
    TestLog,
    AgentSummary,
    Patch,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum InboxArtifactStatus {
    Candidate,
    Reviewed,
    Approved,
    Rejected,
    Exported,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum InboxApprovalKind {
    ToolPermission,
    Export,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum InboxApprovalStatus {
    Pending,
    Approved,
    Denied,
    Cancelled,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum InboxExportTarget {
    Simulated,
    GitCommit,
    GitPush,
    PullRequest,
    CopyToExternalDirectory,
    UploadHttp,
    SendWebhook,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum InboxResourceType {
    LocalDirectory,
    GitRepo,
    DocsDirectory,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct InboxTaskRecord {
    pub id: String,
    pub title: String,
    pub description: String,
    pub workspace_path: String,
    pub agent_name: String,
    pub status: InboxTaskStatus,
    pub priority: InboxTaskPriority,
    pub created_at: String,
    pub updated_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub current_run_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resource_id: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub skill_ids: Vec<String>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub metadata: BTreeMap<String, Value>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct InboxRunRecord {
    pub id: String,
    pub task_id: String,
    pub attempt: u32,
    pub status: InboxTaskStatus,
    pub started_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ended_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub prompt_snapshot: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct InboxEventRecord {
    pub id: String,
    pub task_id: String,
    pub run_id: String,
    pub kind: InboxEventKind,
    pub text: String,
    pub created_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub metadata: BTreeMap<String, Value>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct InboxArtifactRecord {
    pub id: String,
    pub task_id: String,
    pub run_id: String,
    pub kind: InboxArtifactKind,
    pub status: InboxArtifactStatus,
    pub title: String,
    pub created_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub content_preview: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sha256: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub size_bytes: Option<u64>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub metadata: BTreeMap<String, Value>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct InboxApprovalRecord {
    pub id: String,
    pub task_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub run_id: Option<String>,
    pub kind: InboxApprovalKind,
    pub status: InboxApprovalStatus,
    pub created_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resolved_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub target: Option<InboxExportTarget>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub destination: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub risk_summary: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rationale: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub artifact_ids: Vec<String>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub metadata: BTreeMap<String, Value>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct InboxResourceRecord {
    pub id: String,
    #[serde(rename = "type")]
    pub kind: InboxResourceType,
    pub label: String,
    pub r#ref: BTreeMap<String, Value>,
    pub serial: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TaskInboxSnapshot {
    pub schema: String,
    pub updated_at: String,
    pub tasks: Vec<InboxTaskRecord>,
    pub runs: Vec<InboxRunRecord>,
    pub events: Vec<InboxEventRecord>,
    pub artifacts: Vec<InboxArtifactRecord>,
    pub approvals: Vec<InboxApprovalRecord>,
    pub resources: Vec<InboxResourceRecord>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TaskInboxWorkflowImport {
    pub snapshot: WorkflowSnapshot,
    pub normalized_historical_task_ids: Vec<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskInboxRunTransition {
    Start,
    WaitForPermission,
    WaitForUserInput,
    Resume,
    CollectArtifacts,
    RequireHumanReview,
    RequestChanges,
    Complete,
    Fail,
    Reject,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(
    tag = "operation",
    rename_all = "snake_case",
    rename_all_fields = "camelCase"
)]
pub enum TaskInboxCommand {
    CreateTask {
        task: InboxTaskRecord,
    },
    QueueTask {
        task_id: String,
        updated_at: String,
    },
    QueueTaskProjection {
        task: InboxTaskRecord,
        updated_at: String,
    },
    UpdateTaskDefinition {
        task: InboxTaskRecord,
        updated_at: String,
    },
    DispatchRun {
        run: InboxRunRecord,
        updated_at: String,
    },
    DispatchRunProjection {
        task: InboxTaskRecord,
        run: InboxRunRecord,
        updated_at: String,
    },
    TransitionRun {
        run_id: String,
        transition: TaskInboxRunTransition,
        updated_at: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        ended_at: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        error: Option<String>,
    },
    TransitionRunProjection {
        task: InboxTaskRecord,
        run: InboxRunRecord,
        transition: TaskInboxRunTransition,
        updated_at: String,
    },
    CancelTask {
        task_id: String,
        updated_at: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        ended_at: Option<String>,
    },
    CancelTaskProjection {
        task: InboxTaskRecord,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        run: Option<InboxRunRecord>,
        updated_at: String,
    },
    DeleteTask {
        task_id: String,
        updated_at: String,
    },
    UpdateTaskProjection {
        task: InboxTaskRecord,
        updated_at: String,
    },
    UpdateRunProjection {
        run: InboxRunRecord,
        updated_at: String,
    },
    AppendEvents {
        events: Vec<InboxEventRecord>,
        updated_at: String,
    },
    ReplaceArtifacts {
        task_id: String,
        run_id: String,
        artifacts: Vec<InboxArtifactRecord>,
        updated_at: String,
    },
    ReplaceArtifactSet {
        artifacts: Vec<InboxArtifactRecord>,
        updated_at: String,
    },
    UpsertApproval {
        approval: InboxApprovalRecord,
        updated_at: String,
    },
    UpsertResource {
        resource: InboxResourceRecord,
        updated_at: String,
    },
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum TaskInboxError {
    #[error("unsupported task inbox schema: {0}")]
    UnsupportedSchema(String),
    #[error("{record_type} field {field} must be canonical non-empty text")]
    InvalidText {
        record_type: &'static str,
        field: &'static str,
    },
    #[error("duplicate persisted id: {0}")]
    DuplicateId(String),
    #[error("task {task_id} references invalid current run {run_id}")]
    InvalidCurrentRun { task_id: String, run_id: String },
    #[error("task {task_id} references missing resource {resource_id}")]
    MissingResource {
        task_id: String,
        resource_id: String,
    },
    #[error("{record_type} {record_id} references missing task {task_id}")]
    MissingTask {
        record_type: &'static str,
        record_id: String,
        task_id: String,
    },
    #[error("{record_type} {record_id} references invalid run {run_id}")]
    InvalidRun {
        record_type: &'static str,
        record_id: String,
        run_id: String,
    },
    #[error("approval {approval_id} references invalid artifact {artifact_id}")]
    InvalidArtifact {
        approval_id: String,
        artifact_id: String,
    },
    #[error("resource {resource_id} has no canonical path")]
    InvalidResourcePath { resource_id: String },
    #[error("run {run_id} has invalid status {status:?}")]
    InvalidRunStatus {
        run_id: String,
        status: InboxTaskStatus,
    },
    #[error("workflow task {0} has no TaskInbox projection record")]
    MissingTaskProjection(String),
    #[error("workflow run {0} has no TaskInbox projection record")]
    MissingRunProjection(String),
    #[error("TaskInbox run {run_id} does not match workflow task {task_id}")]
    MismatchedRunProjection { run_id: String, task_id: String },
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum TaskInboxMutationError {
    #[error(transparent)]
    Inbox(#[from] TaskInboxError),
    #[error(transparent)]
    Workflow(#[from] WorkflowStateError),
    #[error("unknown TaskInbox task: {0}")]
    UnknownTask(String),
    #[error("unknown TaskInbox run: {0}")]
    UnknownRun(String),
    #[error("task record must start in inbox without a current run")]
    InvalidNewTask,
    #[error("run record must start dispatched with the next workflow attempt")]
    InvalidNewRun,
    #[error("projection update attempted to change Rust-owned workflow fields")]
    AuthorityFieldMismatch,
    #[error("artifact replacement contains a different task or run")]
    ArtifactScopeMismatch,
}

impl TaskInboxSnapshot {
    pub fn validate(&self) -> Result<(), TaskInboxError> {
        if self.schema != TASK_INBOX_SCHEMA {
            return Err(TaskInboxError::UnsupportedSchema(self.schema.clone()));
        }
        canonical("snapshot", "updated_at", &self.updated_at)?;
        let index = index_records(self)?;
        validate_references(self, &index)
    }

    pub fn workflow_import(&self) -> Result<TaskInboxWorkflowImport, TaskInboxError> {
        self.validate()?;
        let mut attempts = HashMap::<&str, u32>::new();
        let mut runs = Vec::with_capacity(self.runs.len());
        for run in &self.runs {
            attempts
                .entry(run.task_id.as_str())
                .and_modify(|attempt| *attempt = (*attempt).max(run.attempt))
                .or_insert(run.attempt);
            runs.push(RunState {
                id: run.id.clone(),
                task_id: run.task_id.clone(),
                attempt: run.attempt,
                status: run_status(run)?,
            });
        }
        let mut normalized_historical_task_ids = Vec::new();
        let tasks = self
            .tasks
            .iter()
            .map(|task| {
                let status = match task.status {
                    InboxTaskStatus::ApprovedForExport | InboxTaskStatus::Exporting => {
                        normalized_historical_task_ids.push(task.id.clone());
                        TaskStatus::NeedsHumanReview
                    }
                    status => task_status(status),
                };
                TaskState {
                    id: task.id.clone(),
                    workspace_path: task.workspace_path.clone(),
                    agent_name: task.agent_name.clone(),
                    status,
                    attempt: attempts.get(task.id.as_str()).copied().unwrap_or(0),
                    current_run_id: task.current_run_id.clone(),
                }
            })
            .collect();
        normalized_historical_task_ids.sort();
        Ok(TaskInboxWorkflowImport {
            snapshot: WorkflowSnapshot { tasks, runs },
            normalized_historical_task_ids,
        })
    }

    pub fn synchronized_with_workflow(
        &self,
        workflow: &WorkflowSnapshot,
    ) -> Result<Self, TaskInboxError> {
        self.validate()?;
        let task_states = workflow
            .tasks
            .iter()
            .map(|task| (task.id.as_str(), task))
            .collect::<HashMap<_, _>>();
        let run_states = workflow
            .runs
            .iter()
            .map(|run| (run.id.as_str(), run))
            .collect::<HashMap<_, _>>();
        for task_id in task_states.keys() {
            if !self.tasks.iter().any(|task| task.id == *task_id) {
                return Err(TaskInboxError::MissingTaskProjection(
                    (*task_id).to_string(),
                ));
            }
        }
        for run_id in run_states.keys() {
            if !self.runs.iter().any(|run| run.id == *run_id) {
                return Err(TaskInboxError::MissingRunProjection((*run_id).to_string()));
            }
        }
        let mut synchronized = self.clone();
        for task in &mut synchronized.tasks {
            let state = task_states
                .get(task.id.as_str())
                .ok_or_else(|| TaskInboxError::MissingTaskProjection(task.id.clone()))?;
            task.workspace_path.clone_from(&state.workspace_path);
            task.agent_name.clone_from(&state.agent_name);
            task.status = inbox_task_status(state.status);
            task.current_run_id.clone_from(&state.current_run_id);
        }
        for run in &mut synchronized.runs {
            let state = run_states
                .get(run.id.as_str())
                .ok_or_else(|| TaskInboxError::MissingRunProjection(run.id.clone()))?;
            if run.task_id != state.task_id {
                return Err(TaskInboxError::MismatchedRunProjection {
                    run_id: run.id.clone(),
                    task_id: state.task_id.clone(),
                });
            }
            run.attempt = state.attempt;
            run.status = inbox_run_status(state.status);
        }
        synchronized.validate()?;
        Ok(synchronized)
    }

    pub fn apply_command(
        &mut self,
        workflow: &mut WorkflowStateMachine,
        command: TaskInboxCommand,
    ) -> Result<(), TaskInboxMutationError> {
        let mut candidate_snapshot = self.clone();
        let mut candidate_workflow = WorkflowStateMachine::restore(workflow.snapshot())?;
        let updated_at =
            apply_task_inbox_command(&mut candidate_snapshot, &mut candidate_workflow, command)?;
        let mut synchronized =
            candidate_snapshot.synchronized_with_workflow(&candidate_workflow.snapshot())?;
        synchronized.updated_at = updated_at;
        synchronized.validate()?;
        *self = synchronized;
        *workflow = candidate_workflow;
        Ok(())
    }
}

fn apply_task_inbox_command(
    snapshot: &mut TaskInboxSnapshot,
    workflow: &mut WorkflowStateMachine,
    command: TaskInboxCommand,
) -> Result<String, TaskInboxMutationError> {
    match command {
        TaskInboxCommand::CreateTask { task } => create_task(snapshot, workflow, task),
        TaskInboxCommand::QueueTask {
            task_id,
            updated_at,
        } => {
            canonical("command", "updated_at", &updated_at)?;
            workflow.queue_task(&task_id)?;
            touch_task(snapshot, &task_id, &updated_at)?;
            Ok(updated_at)
        }
        TaskInboxCommand::QueueTaskProjection { task, updated_at } => {
            workflow.queue_task(&task.id)?;
            update_task_projection(snapshot, workflow, task, updated_at)
        }
        TaskInboxCommand::UpdateTaskDefinition { task, updated_at } => {
            update_task_definition(snapshot, workflow, task, updated_at)
        }
        TaskInboxCommand::DispatchRun { run, updated_at } => {
            dispatch_run(snapshot, workflow, run, updated_at)
        }
        TaskInboxCommand::DispatchRunProjection {
            task,
            run,
            updated_at,
        } => dispatch_run_projection(snapshot, workflow, task, run, updated_at),
        TaskInboxCommand::TransitionRun {
            run_id,
            transition,
            updated_at,
            ended_at,
            error,
        } => transition_run(
            snapshot, workflow, &run_id, transition, updated_at, ended_at, error,
        ),
        TaskInboxCommand::TransitionRunProjection {
            task,
            run,
            transition,
            updated_at,
        } => transition_run_projection(snapshot, workflow, task, run, transition, updated_at),
        TaskInboxCommand::CancelTask {
            task_id,
            updated_at,
            ended_at,
        } => cancel_task(snapshot, workflow, &task_id, updated_at, ended_at),
        TaskInboxCommand::CancelTaskProjection {
            task,
            run,
            updated_at,
        } => cancel_task_projection(snapshot, workflow, task, run, updated_at),
        TaskInboxCommand::DeleteTask {
            task_id,
            updated_at,
        } => delete_task(snapshot, workflow, &task_id, updated_at),
        TaskInboxCommand::UpdateTaskProjection { task, updated_at } => {
            update_task_projection(snapshot, workflow, task, updated_at)
        }
        TaskInboxCommand::UpdateRunProjection { run, updated_at } => {
            update_run_projection(snapshot, workflow, run, updated_at)
        }
        TaskInboxCommand::AppendEvents { events, updated_at } => {
            canonical("command", "updated_at", &updated_at)?;
            for event in &events {
                validate_event(event)?;
            }
            snapshot.events.extend(events);
            Ok(updated_at)
        }
        TaskInboxCommand::ReplaceArtifacts {
            task_id,
            run_id,
            artifacts,
            updated_at,
        } => replace_artifacts(snapshot, &task_id, &run_id, artifacts, updated_at),
        TaskInboxCommand::ReplaceArtifactSet {
            artifacts,
            updated_at,
        } => replace_artifact_set(snapshot, artifacts, updated_at),
        TaskInboxCommand::UpsertApproval {
            approval,
            updated_at,
        } => {
            canonical("command", "updated_at", &updated_at)?;
            validate_approval(&approval)?;
            upsert_by_id(&mut snapshot.approvals, approval, |record| &record.id);
            Ok(updated_at)
        }
        TaskInboxCommand::UpsertResource {
            resource,
            updated_at,
        } => {
            canonical("command", "updated_at", &updated_at)?;
            validate_resource(&resource)?;
            upsert_by_id(&mut snapshot.resources, resource, |record| &record.id);
            Ok(updated_at)
        }
    }
}

fn create_task(
    snapshot: &mut TaskInboxSnapshot,
    workflow: &mut WorkflowStateMachine,
    task: InboxTaskRecord,
) -> Result<String, TaskInboxMutationError> {
    validate_task(&task)?;
    if task.status != InboxTaskStatus::Inbox || task.current_run_id.is_some() {
        return Err(TaskInboxMutationError::InvalidNewTask);
    }
    let updated_at = task.updated_at.clone();
    workflow.create_task(
        task.id.clone(),
        &task.workspace_path,
        task.agent_name.clone(),
    )?;
    snapshot.tasks.push(task);
    Ok(updated_at)
}

fn update_task_definition(
    snapshot: &mut TaskInboxSnapshot,
    workflow: &mut WorkflowStateMachine,
    mut replacement: InboxTaskRecord,
    updated_at: String,
) -> Result<String, TaskInboxMutationError> {
    canonical("command", "updated_at", &updated_at)?;
    validate_task(&replacement)?;
    let state = workflow.task(&replacement.id)?;
    if replacement.status != inbox_task_status(state.status)
        || replacement.current_run_id != state.current_run_id
    {
        return Err(TaskInboxMutationError::AuthorityFieldMismatch);
    }
    workflow.update_task_definition(
        &replacement.id,
        &replacement.workspace_path,
        replacement.agent_name.clone(),
    )?;
    replacement.updated_at.clone_from(&updated_at);
    replace_existing_by_id(
        &mut snapshot.tasks,
        replacement,
        |record| &record.id,
        TaskInboxMutationError::UnknownTask,
    )?;
    Ok(updated_at)
}

fn dispatch_run(
    snapshot: &mut TaskInboxSnapshot,
    workflow: &mut WorkflowStateMachine,
    run: InboxRunRecord,
    updated_at: String,
) -> Result<String, TaskInboxMutationError> {
    canonical("command", "updated_at", &updated_at)?;
    validate_run(&run)?;
    let next_attempt = workflow
        .task(&run.task_id)?
        .attempt
        .checked_add(1)
        .ok_or(TaskInboxMutationError::InvalidNewRun)?;
    if run.status != InboxTaskStatus::Dispatched
        || run.attempt != next_attempt
        || run.ended_at.is_some()
    {
        return Err(TaskInboxMutationError::InvalidNewRun);
    }
    workflow.dispatch_task(&run.task_id, run.id.clone())?;
    touch_task(snapshot, &run.task_id, &updated_at)?;
    snapshot.runs.push(run);
    Ok(updated_at)
}

fn dispatch_run_projection(
    snapshot: &mut TaskInboxSnapshot,
    workflow: &mut WorkflowStateMachine,
    task: InboxTaskRecord,
    run: InboxRunRecord,
    updated_at: String,
) -> Result<String, TaskInboxMutationError> {
    if task.id != run.task_id || task.current_run_id.as_deref() != Some(run.id.as_str()) {
        return Err(TaskInboxMutationError::AuthorityFieldMismatch);
    }
    dispatch_run(snapshot, workflow, run, updated_at.clone())?;
    update_task_projection(snapshot, workflow, task, updated_at)
}

#[allow(clippy::too_many_arguments)]
fn transition_run(
    snapshot: &mut TaskInboxSnapshot,
    workflow: &mut WorkflowStateMachine,
    run_id: &str,
    transition: TaskInboxRunTransition,
    updated_at: String,
    ended_at: Option<String>,
    error: Option<String>,
) -> Result<String, TaskInboxMutationError> {
    canonical("command", "updated_at", &updated_at)?;
    optional_canonical("command", "ended_at", ended_at.as_deref())?;
    optional_canonical("command", "error", error.as_deref())?;
    apply_run_transition(workflow, run_id, transition)?;
    let run = snapshot
        .runs
        .iter_mut()
        .find(|run| run.id == run_id)
        .ok_or_else(|| TaskInboxMutationError::UnknownRun(run_id.to_string()))?;
    if ended_at.is_some() {
        run.ended_at = ended_at;
    }
    if error.is_some() {
        run.error = error;
    }
    let task_id = run.task_id.clone();
    touch_task(snapshot, &task_id, &updated_at)?;
    Ok(updated_at)
}

fn apply_run_transition(
    workflow: &mut WorkflowStateMachine,
    run_id: &str,
    transition: TaskInboxRunTransition,
) -> Result<(), WorkflowStateError> {
    match transition {
        TaskInboxRunTransition::Start => workflow.start_run(run_id),
        TaskInboxRunTransition::WaitForPermission => workflow.wait_for_permission(run_id),
        TaskInboxRunTransition::WaitForUserInput => workflow.wait_for_user_input(run_id),
        TaskInboxRunTransition::Resume => workflow.resume_run(run_id),
        TaskInboxRunTransition::CollectArtifacts => workflow.collect_artifacts(run_id),
        TaskInboxRunTransition::RequireHumanReview => workflow.require_human_review(run_id),
        TaskInboxRunTransition::RequestChanges => workflow.request_changes(run_id),
        TaskInboxRunTransition::Complete => workflow.complete_run(run_id),
        TaskInboxRunTransition::Fail => workflow.fail_run(run_id),
        TaskInboxRunTransition::Reject => workflow.reject_run(run_id),
    }
}

fn transition_run_projection(
    snapshot: &mut TaskInboxSnapshot,
    workflow: &mut WorkflowStateMachine,
    task: InboxTaskRecord,
    run: InboxRunRecord,
    transition: TaskInboxRunTransition,
    updated_at: String,
) -> Result<String, TaskInboxMutationError> {
    if task.id != run.task_id || task.current_run_id.as_deref() != Some(run.id.as_str()) {
        return Err(TaskInboxMutationError::AuthorityFieldMismatch);
    }
    apply_run_transition(workflow, &run.id, transition)?;
    update_run_projection(snapshot, workflow, run, updated_at.clone())?;
    update_task_projection(snapshot, workflow, task, updated_at)
}

fn cancel_task(
    snapshot: &mut TaskInboxSnapshot,
    workflow: &mut WorkflowStateMachine,
    task_id: &str,
    updated_at: String,
    ended_at: Option<String>,
) -> Result<String, TaskInboxMutationError> {
    canonical("command", "updated_at", &updated_at)?;
    optional_canonical("command", "ended_at", ended_at.as_deref())?;
    let run_id = workflow.task(task_id)?.current_run_id.clone();
    workflow.cancel_task(task_id)?;
    touch_task(snapshot, task_id, &updated_at)?;
    if let Some(run_id) = run_id
        && let Some(ended_at) = ended_at
    {
        snapshot
            .runs
            .iter_mut()
            .find(|run| run.id == run_id)
            .ok_or(TaskInboxMutationError::UnknownRun(run_id))?
            .ended_at = Some(ended_at);
    }
    Ok(updated_at)
}

fn cancel_task_projection(
    snapshot: &mut TaskInboxSnapshot,
    workflow: &mut WorkflowStateMachine,
    task: InboxTaskRecord,
    run: Option<InboxRunRecord>,
    updated_at: String,
) -> Result<String, TaskInboxMutationError> {
    let current_run_id = workflow.task(&task.id)?.current_run_id.clone();
    if current_run_id.as_deref() != run.as_ref().map(|record| record.id.as_str()) {
        return Err(TaskInboxMutationError::AuthorityFieldMismatch);
    }
    workflow.cancel_task(&task.id)?;
    if let Some(run) = run {
        update_run_projection(snapshot, workflow, run, updated_at.clone())?;
    }
    update_task_projection(snapshot, workflow, task, updated_at)
}

fn delete_task(
    snapshot: &mut TaskInboxSnapshot,
    workflow: &mut WorkflowStateMachine,
    task_id: &str,
    updated_at: String,
) -> Result<String, TaskInboxMutationError> {
    canonical("command", "updated_at", &updated_at)?;
    workflow.delete_task(task_id)?;
    snapshot.tasks.retain(|task| task.id != task_id);
    snapshot.runs.retain(|run| run.task_id != task_id);
    snapshot.events.retain(|event| event.task_id != task_id);
    snapshot
        .artifacts
        .retain(|artifact| artifact.task_id != task_id);
    snapshot
        .approvals
        .retain(|approval| approval.task_id != task_id);
    Ok(updated_at)
}

fn touch_task(
    snapshot: &mut TaskInboxSnapshot,
    task_id: &str,
    updated_at: &str,
) -> Result<(), TaskInboxMutationError> {
    snapshot
        .tasks
        .iter_mut()
        .find(|task| task.id == task_id)
        .ok_or_else(|| TaskInboxMutationError::UnknownTask(task_id.to_string()))?
        .updated_at = updated_at.to_string();
    Ok(())
}

fn update_task_projection(
    snapshot: &mut TaskInboxSnapshot,
    workflow: &WorkflowStateMachine,
    mut replacement: InboxTaskRecord,
    updated_at: String,
) -> Result<String, TaskInboxMutationError> {
    canonical("command", "updated_at", &updated_at)?;
    validate_task(&replacement)?;
    let state = workflow.task(&replacement.id)?;
    if replacement.workspace_path != state.workspace_path
        || replacement.agent_name != state.agent_name
        || replacement.status != inbox_task_status(state.status)
        || replacement.current_run_id != state.current_run_id
    {
        return Err(TaskInboxMutationError::AuthorityFieldMismatch);
    }
    replacement.updated_at.clone_from(&updated_at);
    replace_existing_by_id(
        &mut snapshot.tasks,
        replacement,
        |record| &record.id,
        TaskInboxMutationError::UnknownTask,
    )?;
    Ok(updated_at)
}

fn update_run_projection(
    snapshot: &mut TaskInboxSnapshot,
    workflow: &WorkflowStateMachine,
    replacement: InboxRunRecord,
    updated_at: String,
) -> Result<String, TaskInboxMutationError> {
    canonical("command", "updated_at", &updated_at)?;
    validate_run(&replacement)?;
    let state = workflow.run(&replacement.id)?;
    if replacement.task_id != state.task_id
        || replacement.attempt != state.attempt
        || replacement.status != inbox_run_status(state.status)
    {
        return Err(TaskInboxMutationError::AuthorityFieldMismatch);
    }
    replace_existing_by_id(
        &mut snapshot.runs,
        replacement,
        |record| &record.id,
        TaskInboxMutationError::UnknownRun,
    )?;
    Ok(updated_at)
}

fn replace_artifacts(
    snapshot: &mut TaskInboxSnapshot,
    task_id: &str,
    run_id: &str,
    artifacts: Vec<InboxArtifactRecord>,
    updated_at: String,
) -> Result<String, TaskInboxMutationError> {
    canonical("command", "updated_at", &updated_at)?;
    if artifacts
        .iter()
        .any(|artifact| artifact.task_id != task_id || artifact.run_id != run_id)
    {
        return Err(TaskInboxMutationError::ArtifactScopeMismatch);
    }
    for artifact in &artifacts {
        validate_artifact(artifact)?;
    }
    snapshot
        .artifacts
        .retain(|artifact| artifact.task_id != task_id || artifact.run_id != run_id);
    snapshot.artifacts.extend(artifacts);
    Ok(updated_at)
}

fn replace_artifact_set(
    snapshot: &mut TaskInboxSnapshot,
    artifacts: Vec<InboxArtifactRecord>,
    updated_at: String,
) -> Result<String, TaskInboxMutationError> {
    canonical("command", "updated_at", &updated_at)?;
    for artifact in &artifacts {
        validate_artifact(artifact)?;
    }
    snapshot.artifacts = artifacts;
    Ok(updated_at)
}

fn upsert_by_id<T>(records: &mut Vec<T>, replacement: T, id: impl Fn(&T) -> &String) {
    if let Some(position) = records
        .iter()
        .position(|record| id(record) == id(&replacement))
    {
        records[position] = replacement;
    } else {
        records.push(replacement);
    }
}

fn replace_existing_by_id<T>(
    records: &mut [T],
    replacement: T,
    id: impl Fn(&T) -> &String,
    missing: impl FnOnce(String) -> TaskInboxMutationError,
) -> Result<(), TaskInboxMutationError> {
    let position = records
        .iter()
        .position(|record| id(record) == id(&replacement))
        .ok_or_else(|| missing(id(&replacement).clone()))?;
    records[position] = replacement;
    Ok(())
}

struct InboxIndex<'a> {
    task_ids: HashSet<&'a str>,
    runs: HashMap<&'a str, &'a InboxRunRecord>,
    artifacts: HashMap<&'a str, &'a InboxArtifactRecord>,
    resource_ids: HashSet<&'a str>,
}

fn index_records(snapshot: &TaskInboxSnapshot) -> Result<InboxIndex<'_>, TaskInboxError> {
    let mut persisted_ids = HashSet::new();
    let mut index = InboxIndex {
        task_ids: HashSet::new(),
        runs: HashMap::new(),
        artifacts: HashMap::new(),
        resource_ids: HashSet::new(),
    };
    for resource in &snapshot.resources {
        validate_resource(resource)?;
        insert_id(&mut persisted_ids, &resource.id)?;
        index.resource_ids.insert(resource.id.as_str());
    }
    for task in &snapshot.tasks {
        validate_task(task)?;
        insert_id(&mut persisted_ids, &task.id)?;
        index.task_ids.insert(task.id.as_str());
    }
    for run in &snapshot.runs {
        validate_run(run)?;
        insert_id(&mut persisted_ids, &run.id)?;
        index.runs.insert(run.id.as_str(), run);
    }
    for event in &snapshot.events {
        validate_event(event)?;
        insert_id(&mut persisted_ids, &event.id)?;
    }
    for artifact in &snapshot.artifacts {
        validate_artifact(artifact)?;
        insert_id(&mut persisted_ids, &artifact.id)?;
        index.artifacts.insert(artifact.id.as_str(), artifact);
    }
    for approval in &snapshot.approvals {
        validate_approval(approval)?;
        insert_id(&mut persisted_ids, &approval.id)?;
    }
    Ok(index)
}

fn validate_references(
    snapshot: &TaskInboxSnapshot,
    index: &InboxIndex<'_>,
) -> Result<(), TaskInboxError> {
    for task in &snapshot.tasks {
        if let Some(run_id) = task.current_run_id.as_deref()
            && index
                .runs
                .get(run_id)
                .is_none_or(|run| run.task_id != task.id)
        {
            return Err(TaskInboxError::InvalidCurrentRun {
                task_id: task.id.clone(),
                run_id: run_id.to_string(),
            });
        }
        if let Some(resource_id) = task.resource_id.as_deref()
            && !index.resource_ids.contains(resource_id)
        {
            return Err(TaskInboxError::MissingResource {
                task_id: task.id.clone(),
                resource_id: resource_id.to_string(),
            });
        }
    }
    for run in &snapshot.runs {
        require_task("run", &run.id, &run.task_id, &index.task_ids)?;
    }
    for event in &snapshot.events {
        require_task_run(
            "event",
            &event.id,
            &event.task_id,
            &event.run_id,
            &index.task_ids,
            &index.runs,
        )?;
    }
    for artifact in &snapshot.artifacts {
        require_task_run(
            "artifact",
            &artifact.id,
            &artifact.task_id,
            &artifact.run_id,
            &index.task_ids,
            &index.runs,
        )?;
    }
    for approval in &snapshot.approvals {
        validate_approval_references(approval, index)?;
    }
    Ok(())
}

fn validate_approval_references(
    approval: &InboxApprovalRecord,
    index: &InboxIndex<'_>,
) -> Result<(), TaskInboxError> {
    require_task("approval", &approval.id, &approval.task_id, &index.task_ids)?;
    if let Some(run_id) = approval.run_id.as_deref()
        && index
            .runs
            .get(run_id)
            .is_none_or(|run| run.task_id != approval.task_id)
    {
        return Err(TaskInboxError::InvalidRun {
            record_type: "approval",
            record_id: approval.id.clone(),
            run_id: run_id.to_string(),
        });
    }
    for artifact_id in &approval.artifact_ids {
        let valid = index
            .artifacts
            .get(artifact_id.as_str())
            .is_some_and(|artifact| {
                artifact.task_id == approval.task_id
                    && approval
                        .run_id
                        .as_ref()
                        .is_none_or(|run_id| artifact.run_id == *run_id)
            });
        if !valid {
            return Err(TaskInboxError::InvalidArtifact {
                approval_id: approval.id.clone(),
                artifact_id: artifact_id.clone(),
            });
        }
    }
    Ok(())
}

fn validate_task(task: &InboxTaskRecord) -> Result<(), TaskInboxError> {
    canonical("task", "id", &task.id)?;
    canonical("task", "title", &task.title)?;
    canonical("task", "workspace_path", &task.workspace_path)?;
    canonical("task", "agent_name", &task.agent_name)?;
    canonical("task", "created_at", &task.created_at)?;
    canonical("task", "updated_at", &task.updated_at)?;
    optional_canonical("task", "session_id", task.session_id.as_deref())?;
    optional_canonical("task", "current_run_id", task.current_run_id.as_deref())?;
    optional_canonical("task", "summary", task.summary.as_deref())?;
    optional_canonical("task", "error", task.error.as_deref())?;
    optional_canonical("task", "resource_id", task.resource_id.as_deref())?;
    for skill_id in &task.skill_ids {
        canonical("task", "skill_ids", skill_id)?;
    }
    Ok(())
}

fn validate_resource(resource: &InboxResourceRecord) -> Result<(), TaskInboxError> {
    canonical("resource", "id", &resource.id)?;
    canonical("resource", "label", &resource.label)?;
    let path = resource.r#ref.get("path").and_then(Value::as_str);
    if path.is_none_or(|path| path.is_empty() || path.trim() != path) {
        return Err(TaskInboxError::InvalidResourcePath {
            resource_id: resource.id.clone(),
        });
    }
    Ok(())
}

fn validate_run(run: &InboxRunRecord) -> Result<(), TaskInboxError> {
    canonical("run", "id", &run.id)?;
    canonical("run", "task_id", &run.task_id)?;
    canonical("run", "started_at", &run.started_at)?;
    if run.attempt == 0 {
        return Err(TaskInboxError::InvalidText {
            record_type: "run",
            field: "attempt",
        });
    }
    optional_canonical("run", "ended_at", run.ended_at.as_deref())?;
    optional_canonical("run", "session_id", run.session_id.as_deref())?;
    optional_canonical("run", "prompt_snapshot", run.prompt_snapshot.as_deref())?;
    optional_canonical("run", "model", run.model.as_deref())?;
    optional_canonical("run", "error", run.error.as_deref())
}

fn validate_event(event: &InboxEventRecord) -> Result<(), TaskInboxError> {
    canonical("event", "id", &event.id)?;
    canonical("event", "task_id", &event.task_id)?;
    canonical("event", "run_id", &event.run_id)?;
    canonical("event", "created_at", &event.created_at)?;
    optional_canonical("event", "session_id", event.session_id.as_deref())
}

fn validate_artifact(artifact: &InboxArtifactRecord) -> Result<(), TaskInboxError> {
    canonical("artifact", "id", &artifact.id)?;
    canonical("artifact", "task_id", &artifact.task_id)?;
    canonical("artifact", "run_id", &artifact.run_id)?;
    canonical("artifact", "title", &artifact.title)?;
    canonical("artifact", "created_at", &artifact.created_at)?;
    optional_canonical("artifact", "path", artifact.path.as_deref())?;
    if artifact.content_preview.as_deref() == Some("") {
        return Err(TaskInboxError::InvalidText {
            record_type: "artifact",
            field: "content_preview",
        });
    }
    optional_canonical("artifact", "sha256", artifact.sha256.as_deref())
}

fn validate_approval(approval: &InboxApprovalRecord) -> Result<(), TaskInboxError> {
    canonical("approval", "id", &approval.id)?;
    canonical("approval", "task_id", &approval.task_id)?;
    canonical("approval", "created_at", &approval.created_at)?;
    optional_canonical("approval", "run_id", approval.run_id.as_deref())?;
    optional_canonical("approval", "resolved_at", approval.resolved_at.as_deref())?;
    optional_canonical("approval", "destination", approval.destination.as_deref())?;
    optional_canonical("approval", "risk_summary", approval.risk_summary.as_deref())?;
    optional_canonical("approval", "rationale", approval.rationale.as_deref())?;
    for artifact_id in &approval.artifact_ids {
        canonical("approval", "artifact_ids", artifact_id)?;
    }
    Ok(())
}

fn canonical(
    record_type: &'static str,
    field: &'static str,
    value: &str,
) -> Result<(), TaskInboxError> {
    if value.is_empty() || value.trim() != value {
        Err(TaskInboxError::InvalidText { record_type, field })
    } else {
        Ok(())
    }
}

fn optional_canonical(
    record_type: &'static str,
    field: &'static str,
    value: Option<&str>,
) -> Result<(), TaskInboxError> {
    value.map_or(Ok(()), |value| canonical(record_type, field, value))
}

fn insert_id<'a>(ids: &mut HashSet<&'a str>, id: &'a str) -> Result<(), TaskInboxError> {
    if ids.insert(id) {
        Ok(())
    } else {
        Err(TaskInboxError::DuplicateId(id.to_string()))
    }
}

fn require_task(
    record_type: &'static str,
    record_id: &str,
    task_id: &str,
    task_ids: &HashSet<&str>,
) -> Result<(), TaskInboxError> {
    if task_ids.contains(task_id) {
        Ok(())
    } else {
        Err(TaskInboxError::MissingTask {
            record_type,
            record_id: record_id.to_string(),
            task_id: task_id.to_string(),
        })
    }
}

fn require_task_run(
    record_type: &'static str,
    record_id: &str,
    task_id: &str,
    run_id: &str,
    task_ids: &HashSet<&str>,
    runs: &HashMap<&str, &InboxRunRecord>,
) -> Result<(), TaskInboxError> {
    require_task(record_type, record_id, task_id, task_ids)?;
    if runs.get(run_id).is_some_and(|run| run.task_id == task_id) {
        Ok(())
    } else {
        Err(TaskInboxError::InvalidRun {
            record_type,
            record_id: record_id.to_string(),
            run_id: run_id.to_string(),
        })
    }
}

const fn task_status(status: InboxTaskStatus) -> TaskStatus {
    match status {
        InboxTaskStatus::Inbox => TaskStatus::Inbox,
        InboxTaskStatus::Queued => TaskStatus::Queued,
        InboxTaskStatus::Dispatched => TaskStatus::Dispatched,
        InboxTaskStatus::Running => TaskStatus::Running,
        InboxTaskStatus::BlockedOnPermission => TaskStatus::BlockedOnPermission,
        InboxTaskStatus::BlockedOnUserInput => TaskStatus::BlockedOnUserInput,
        InboxTaskStatus::CollectingArtifacts => TaskStatus::CollectingArtifacts,
        InboxTaskStatus::NeedsHumanReview
        | InboxTaskStatus::ApprovedForExport
        | InboxTaskStatus::Exporting => TaskStatus::NeedsHumanReview,
        InboxTaskStatus::Done => TaskStatus::Done,
        InboxTaskStatus::Failed => TaskStatus::Failed,
        InboxTaskStatus::Cancelled => TaskStatus::Cancelled,
        InboxTaskStatus::Rejected => TaskStatus::Rejected,
        InboxTaskStatus::NeedsChanges => TaskStatus::NeedsChanges,
    }
}

fn run_status(run: &InboxRunRecord) -> Result<RunStatus, TaskInboxError> {
    match run.status {
        InboxTaskStatus::Inbox | InboxTaskStatus::Queued => Err(TaskInboxError::InvalidRunStatus {
            run_id: run.id.clone(),
            status: run.status,
        }),
        InboxTaskStatus::Dispatched => Ok(RunStatus::Dispatched),
        InboxTaskStatus::Running => Ok(RunStatus::Running),
        InboxTaskStatus::BlockedOnPermission => Ok(RunStatus::WaitingPermission),
        InboxTaskStatus::BlockedOnUserInput => Ok(RunStatus::WaitingUserInput),
        InboxTaskStatus::CollectingArtifacts => Ok(RunStatus::CollectingArtifacts),
        InboxTaskStatus::NeedsHumanReview
        | InboxTaskStatus::ApprovedForExport
        | InboxTaskStatus::Exporting => Ok(RunStatus::NeedsHumanReview),
        InboxTaskStatus::NeedsChanges => Ok(RunStatus::NeedsChanges),
        InboxTaskStatus::Done => Ok(RunStatus::Succeeded),
        InboxTaskStatus::Failed => Ok(RunStatus::Failed),
        InboxTaskStatus::Cancelled => Ok(RunStatus::Cancelled),
        InboxTaskStatus::Rejected => Ok(RunStatus::Rejected),
    }
}

const fn inbox_task_status(status: TaskStatus) -> InboxTaskStatus {
    match status {
        TaskStatus::Inbox => InboxTaskStatus::Inbox,
        TaskStatus::Queued => InboxTaskStatus::Queued,
        TaskStatus::Dispatched => InboxTaskStatus::Dispatched,
        TaskStatus::Running => InboxTaskStatus::Running,
        TaskStatus::BlockedOnPermission => InboxTaskStatus::BlockedOnPermission,
        TaskStatus::BlockedOnUserInput => InboxTaskStatus::BlockedOnUserInput,
        TaskStatus::CollectingArtifacts => InboxTaskStatus::CollectingArtifacts,
        TaskStatus::NeedsHumanReview => InboxTaskStatus::NeedsHumanReview,
        TaskStatus::NeedsChanges => InboxTaskStatus::NeedsChanges,
        TaskStatus::Done => InboxTaskStatus::Done,
        TaskStatus::Failed => InboxTaskStatus::Failed,
        TaskStatus::Cancelled => InboxTaskStatus::Cancelled,
        TaskStatus::Rejected => InboxTaskStatus::Rejected,
    }
}

const fn inbox_run_status(status: RunStatus) -> InboxTaskStatus {
    match status {
        RunStatus::Dispatched => InboxTaskStatus::Dispatched,
        RunStatus::Running => InboxTaskStatus::Running,
        RunStatus::WaitingPermission => InboxTaskStatus::BlockedOnPermission,
        RunStatus::WaitingUserInput => InboxTaskStatus::BlockedOnUserInput,
        RunStatus::CollectingArtifacts => InboxTaskStatus::CollectingArtifacts,
        RunStatus::NeedsHumanReview => InboxTaskStatus::NeedsHumanReview,
        RunStatus::NeedsChanges => InboxTaskStatus::NeedsChanges,
        RunStatus::Succeeded => InboxTaskStatus::Done,
        RunStatus::Failed => InboxTaskStatus::Failed,
        RunStatus::Cancelled => InboxTaskStatus::Cancelled,
        RunStatus::Rejected => InboxTaskStatus::Rejected,
    }
}
