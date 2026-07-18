use std::path::Path;

use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::{
    RecoveryReport, SchedulerClaim, SchedulerClaimRequest, SchedulerConfig, SchedulerCore,
    SchedulerError, SchedulerRuntimeStatus, SqliteWorkflowStore, TaskInboxCommand, TaskInboxError,
    TaskInboxMutationError, TaskInboxSnapshot, WorkflowMigrationMetadata, WorkflowSnapshot,
    WorkflowStateError, WorkflowStateMachine, WorkflowStoreError,
};

pub const WORKFLOW_SCHEMA_VERSION: u32 = 1;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "operation", rename_all = "snake_case")]
pub enum WorkflowCommand {
    CreateTask {
        #[serde(rename = "taskId")]
        task_id: String,
        #[serde(rename = "workspacePath")]
        workspace_path: String,
        #[serde(rename = "agentName")]
        agent_name: String,
    },
    QueueTask {
        #[serde(rename = "taskId")]
        task_id: String,
    },
    UpdateTaskDefinition {
        #[serde(rename = "taskId")]
        task_id: String,
        #[serde(rename = "workspacePath")]
        workspace_path: String,
        #[serde(rename = "agentName")]
        agent_name: String,
    },
    DeleteTask {
        #[serde(rename = "taskId")]
        task_id: String,
    },
    DispatchTask {
        #[serde(rename = "taskId")]
        task_id: String,
        #[serde(rename = "runId")]
        run_id: String,
    },
    StartRun {
        #[serde(rename = "runId")]
        run_id: String,
    },
    WaitForPermission {
        #[serde(rename = "runId")]
        run_id: String,
    },
    WaitForUserInput {
        #[serde(rename = "runId")]
        run_id: String,
    },
    ResumeRun {
        #[serde(rename = "runId")]
        run_id: String,
    },
    CollectArtifacts {
        #[serde(rename = "runId")]
        run_id: String,
    },
    RequireHumanReview {
        #[serde(rename = "runId")]
        run_id: String,
    },
    RequestChanges {
        #[serde(rename = "runId")]
        run_id: String,
    },
    CompleteRun {
        #[serde(rename = "runId")]
        run_id: String,
    },
    FailRun {
        #[serde(rename = "runId")]
        run_id: String,
    },
    RejectRun {
        #[serde(rename = "runId")]
        run_id: String,
    },
    CancelTask {
        #[serde(rename = "taskId")]
        task_id: String,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkflowProjection {
    pub schema_version: u32,
    pub revision: u64,
    pub migration: WorkflowMigrationMetadata,
    pub snapshot: WorkflowSnapshot,
}

impl WorkflowProjection {
    fn new(
        revision: u64,
        migration: WorkflowMigrationMetadata,
        snapshot: WorkflowSnapshot,
    ) -> Self {
        Self {
            schema_version: WORKFLOW_SCHEMA_VERSION,
            revision,
            migration,
            snapshot,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkflowOpenProjection {
    pub schema_version: u32,
    pub revision: u64,
    pub migration: WorkflowMigrationMetadata,
    pub snapshot: WorkflowSnapshot,
    pub recovery: RecoveryReport,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TaskInboxStageProjection {
    pub schema_version: u32,
    pub revision: u64,
    pub migration: WorkflowMigrationMetadata,
    pub snapshot: WorkflowSnapshot,
    pub normalized_historical_task_ids: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TaskInboxMaterializedProjection {
    pub schema_version: u32,
    pub revision: u64,
    pub migration: WorkflowMigrationMetadata,
    pub snapshot: WorkflowSnapshot,
    pub task_inbox: TaskInboxSnapshot,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SchedulerClaimProjection {
    pub schema_version: u32,
    pub revision: u64,
    pub migration: WorkflowMigrationMetadata,
    pub snapshot: WorkflowSnapshot,
    pub task_inbox: TaskInboxSnapshot,
    pub claim: Option<SchedulerClaim>,
    pub next_wake_at: Option<String>,
}

#[derive(Debug, Error)]
pub enum DurableWorkflowError {
    #[error(transparent)]
    State(#[from] WorkflowStateError),
    #[error(transparent)]
    Store(#[from] WorkflowStoreError),
    #[error(transparent)]
    TaskInbox(#[from] TaskInboxError),
    #[error(transparent)]
    TaskInboxMutation(#[from] TaskInboxMutationError),
    #[error(transparent)]
    Scheduler(#[from] SchedulerError),
}

/// Single-owner durable workflow authority.
///
/// Each command is first applied to a fresh candidate state machine, then
/// committed with a `SQLite` revision compare-and-swap. In-memory authority is
/// replaced only after the durable commit succeeds.
#[derive(Debug)]
pub struct DurableWorkflow {
    state: WorkflowStateMachine,
    store: SqliteWorkflowStore,
    revision: u64,
    migration: WorkflowMigrationMetadata,
    task_inbox: Option<TaskInboxSnapshot>,
    recovery: RecoveryReport,
    scheduler: SchedulerCore,
}

impl DurableWorkflow {
    pub fn open(path: impl AsRef<Path>) -> Result<Self, DurableWorkflowError> {
        Self::from_store(SqliteWorkflowStore::open(path)?)
    }

    pub fn open_in_memory() -> Result<Self, DurableWorkflowError> {
        Self::from_store(SqliteWorkflowStore::open_in_memory()?)
    }

    fn from_store(mut store: SqliteWorkflowStore) -> Result<Self, DurableWorkflowError> {
        let recovery = store.recover_interrupted()?;
        let persisted = store.load_versioned_snapshot()?;
        let migration = store.migration_metadata()?;
        let task_inbox = store.load_current_task_inbox()?;
        if matches!(
            migration.phase,
            crate::WorkflowMigrationPhase::Ready | crate::WorkflowMigrationPhase::Active
        ) != task_inbox.is_some()
        {
            return Err(WorkflowStoreError::InvalidValue(
                "workflow migration phase and current TaskInbox disagree".to_string(),
            )
            .into());
        }
        let state = WorkflowStateMachine::restore(persisted.snapshot)?;
        Ok(Self {
            state,
            store,
            revision: persisted.revision,
            migration,
            task_inbox,
            recovery,
            scheduler: SchedulerCore::new(),
        })
    }

    #[must_use]
    pub fn open_projection(&self) -> WorkflowOpenProjection {
        WorkflowOpenProjection {
            schema_version: WORKFLOW_SCHEMA_VERSION,
            revision: self.revision,
            migration: self.migration.clone(),
            snapshot: self.state.snapshot(),
            recovery: self.recovery.clone(),
        }
    }

    #[must_use]
    pub fn projection(&self) -> WorkflowProjection {
        WorkflowProjection::new(self.revision, self.migration.clone(), self.state.snapshot())
    }

    pub fn stage_task_inbox_import(
        &mut self,
        source: &TaskInboxSnapshot,
        source_checksum: &str,
    ) -> Result<TaskInboxStageProjection, DurableWorkflowError> {
        let imported = source.workflow_import()?;
        let candidate = WorkflowStateMachine::restore(imported.snapshot)?;
        let snapshot = candidate.snapshot();
        let revision = self.store.stage_task_inbox_import(
            source,
            &snapshot,
            source_checksum,
            self.revision,
        )?;
        self.state = candidate;
        self.revision = revision;
        self.migration = self.store.migration_metadata()?;
        Ok(TaskInboxStageProjection {
            schema_version: WORKFLOW_SCHEMA_VERSION,
            revision,
            migration: self.migration.clone(),
            snapshot,
            normalized_historical_task_ids: imported.normalized_historical_task_ids,
        })
    }

    pub fn materialize_task_inbox(
        &mut self,
    ) -> Result<TaskInboxMaterializedProjection, DurableWorkflowError> {
        let source = self.store.load_task_inbox_source()?.ok_or_else(|| {
            WorkflowStoreError::InvalidValue("staged TaskInbox source is missing".to_string())
        })?;
        let snapshot = self.state.snapshot();
        let task_inbox = source.synchronized_with_workflow(&snapshot)?;
        let revision = self
            .store
            .materialize_task_inbox(&task_inbox, self.revision)?;
        self.revision = revision;
        self.migration = self.store.migration_metadata()?;
        self.task_inbox = Some(task_inbox.clone());
        Ok(TaskInboxMaterializedProjection {
            schema_version: WORKFLOW_SCHEMA_VERSION,
            revision,
            migration: self.migration.clone(),
            snapshot,
            task_inbox,
        })
    }

    pub fn task_inbox_source(&self) -> Result<Option<TaskInboxSnapshot>, DurableWorkflowError> {
        self.store.load_task_inbox_source().map_err(Into::into)
    }

    #[must_use]
    pub fn current_task_inbox(&self) -> Option<&TaskInboxSnapshot> {
        self.task_inbox.as_ref()
    }

    pub fn activate_task_inbox(
        &mut self,
    ) -> Result<TaskInboxMaterializedProjection, DurableWorkflowError> {
        let task_inbox = self.task_inbox.clone().ok_or_else(|| {
            WorkflowStoreError::InvalidValue(
                "materialized TaskInbox projection is missing".to_string(),
            )
        })?;
        let revision = self.store.activate_task_inbox(self.revision)?;
        self.revision = revision;
        self.migration = self.store.migration_metadata()?;
        Ok(self.task_inbox_projection(task_inbox))
    }

    pub fn apply_task_inbox(
        &mut self,
        command: TaskInboxCommand,
    ) -> Result<TaskInboxMaterializedProjection, DurableWorkflowError> {
        if self.migration.phase != crate::WorkflowMigrationPhase::Active {
            return Err(WorkflowStoreError::TaskInboxNotActive.into());
        }
        let mut candidate = WorkflowStateMachine::restore(self.state.snapshot())?;
        let mut task_inbox = self.task_inbox.clone().ok_or_else(|| {
            WorkflowStoreError::InvalidValue("active TaskInbox projection is missing".to_string())
        })?;
        task_inbox.apply_command(&mut candidate, command)?;
        let snapshot = candidate.snapshot();
        let revision = self
            .store
            .save_active_task_inbox(&snapshot, &task_inbox, self.revision)?;
        self.state = candidate;
        self.task_inbox = Some(task_inbox.clone());
        self.revision = revision;
        Ok(self.task_inbox_projection(task_inbox))
    }

    pub fn configure_scheduler(
        &mut self,
        config: SchedulerConfig,
    ) -> Result<(), DurableWorkflowError> {
        self.scheduler.configure(config)?;
        Ok(())
    }

    pub fn set_scheduler_runtime_status(
        &mut self,
        status: SchedulerRuntimeStatus,
    ) -> Result<(), DurableWorkflowError> {
        self.scheduler.set_runtime_status(status)?;
        Ok(())
    }

    pub fn scheduler_claim_next(
        &mut self,
        request: SchedulerClaimRequest,
    ) -> Result<SchedulerClaimProjection, DurableWorkflowError> {
        if self.migration.phase != crate::WorkflowMigrationPhase::Active {
            return Err(WorkflowStoreError::TaskInboxNotActive.into());
        }
        let mut candidate = WorkflowStateMachine::restore(self.state.snapshot())?;
        let mut task_inbox = self.task_inbox.clone().ok_or_else(|| {
            WorkflowStoreError::InvalidValue("active TaskInbox projection is missing".to_string())
        })?;
        let poll = self
            .scheduler
            .claim_next(&mut task_inbox, &mut candidate, request)?;
        if poll.claim.is_some() {
            let snapshot = candidate.snapshot();
            let revision =
                self.store
                    .save_active_task_inbox(&snapshot, &task_inbox, self.revision)?;
            self.state = candidate;
            self.task_inbox = Some(task_inbox.clone());
            self.revision = revision;
        }
        Ok(SchedulerClaimProjection {
            schema_version: WORKFLOW_SCHEMA_VERSION,
            revision: self.revision,
            migration: self.migration.clone(),
            snapshot: self.state.snapshot(),
            task_inbox,
            claim: poll.claim,
            next_wake_at: poll.next_wake_at,
        })
    }

    pub fn apply(
        &mut self,
        command: WorkflowCommand,
    ) -> Result<WorkflowProjection, DurableWorkflowError> {
        self.transact(|candidate| apply_command(candidate, command))?;
        Ok(self.projection())
    }

    fn transact(
        &mut self,
        operation: impl FnOnce(&mut WorkflowStateMachine) -> Result<(), WorkflowStateError>,
    ) -> Result<(), DurableWorkflowError> {
        let mut candidate = WorkflowStateMachine::restore(self.state.snapshot())?;
        operation(&mut candidate)?;
        let snapshot = candidate.snapshot();
        let revision = self
            .store
            .save_snapshot_if_revision(&snapshot, self.revision)?;
        self.state = candidate;
        self.revision = revision;
        Ok(())
    }

    fn task_inbox_projection(
        &self,
        task_inbox: TaskInboxSnapshot,
    ) -> TaskInboxMaterializedProjection {
        TaskInboxMaterializedProjection {
            schema_version: WORKFLOW_SCHEMA_VERSION,
            revision: self.revision,
            migration: self.migration.clone(),
            snapshot: self.state.snapshot(),
            task_inbox,
        }
    }
}

fn apply_command(
    workflow: &mut WorkflowStateMachine,
    command: WorkflowCommand,
) -> Result<(), WorkflowStateError> {
    match command {
        WorkflowCommand::CreateTask {
            task_id,
            workspace_path,
            agent_name,
        } => {
            workflow.create_task(task_id, workspace_path, agent_name)?;
        }
        WorkflowCommand::QueueTask { task_id } => workflow.queue_task(&task_id)?,
        WorkflowCommand::UpdateTaskDefinition {
            task_id,
            workspace_path,
            agent_name,
        } => workflow.update_task_definition(&task_id, workspace_path, agent_name)?,
        WorkflowCommand::DeleteTask { task_id } => workflow.delete_task(&task_id)?,
        WorkflowCommand::DispatchTask { task_id, run_id } => {
            workflow.dispatch_task(&task_id, run_id)?;
        }
        WorkflowCommand::StartRun { run_id } => workflow.start_run(&run_id)?,
        WorkflowCommand::WaitForPermission { run_id } => {
            workflow.wait_for_permission(&run_id)?;
        }
        WorkflowCommand::WaitForUserInput { run_id } => {
            workflow.wait_for_user_input(&run_id)?;
        }
        WorkflowCommand::ResumeRun { run_id } => workflow.resume_run(&run_id)?,
        WorkflowCommand::CollectArtifacts { run_id } => workflow.collect_artifacts(&run_id)?,
        WorkflowCommand::RequireHumanReview { run_id } => {
            workflow.require_human_review(&run_id)?;
        }
        WorkflowCommand::RequestChanges { run_id } => workflow.request_changes(&run_id)?,
        WorkflowCommand::CompleteRun { run_id } => workflow.complete_run(&run_id)?,
        WorkflowCommand::FailRun { run_id } => workflow.fail_run(&run_id)?,
        WorkflowCommand::RejectRun { run_id } => workflow.reject_run(&run_id)?,
        WorkflowCommand::CancelTask { task_id } => workflow.cancel_task(&task_id)?,
    }
    Ok(())
}
