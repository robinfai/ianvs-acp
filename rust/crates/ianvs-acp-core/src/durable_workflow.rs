use std::path::Path;

use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::{
    ExecutorCommandContext, ExecutorLease, ExecutorLeaseCommand, ExecutorTakeoverRequest,
    IdempotencyKey, RecoveryReport, RuntimeEventAppendReceipt, RuntimeEventPage,
    SchedulerAdmission, SchedulerClaim, SchedulerClaimRequest, SchedulerConfig, SchedulerCore,
    SchedulerError, SchedulerRuntimeStatus, SqliteStoragePolicy, SqliteWorkflowStore,
    TaskInboxCommand, TaskInboxError, TaskInboxMutationError, TaskInboxSnapshot,
    WorkflowMigrationMetadata, WorkflowSnapshot, WorkflowStateError, WorkflowStateMachine,
    WorkflowStoreError,
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

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
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

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkflowOpenProjection {
    pub schema_version: u32,
    pub revision: u64,
    pub migration: WorkflowMigrationMetadata,
    pub snapshot: WorkflowSnapshot,
    pub recovery: RecoveryReport,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TaskInboxStageProjection {
    pub schema_version: u32,
    pub revision: u64,
    pub migration: WorkflowMigrationMetadata,
    pub snapshot: WorkflowSnapshot,
    pub normalized_historical_task_ids: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TaskInboxMaterializedProjection {
    pub schema_version: u32,
    pub revision: u64,
    pub migration: WorkflowMigrationMetadata,
    pub snapshot: WorkflowSnapshot,
    pub task_inbox: TaskInboxSnapshot,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SchedulerClaimProjection {
    pub schema_version: u32,
    pub revision: u64,
    pub migration: WorkflowMigrationMetadata,
    pub snapshot: WorkflowSnapshot,
    pub task_inbox: TaskInboxSnapshot,
    pub claim: Option<SchedulerClaim>,
    pub next_wake_at: Option<String>,
    pub admission: SchedulerAdmission,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ExecutorTaskInboxCommand {
    pub context: ExecutorCommandContext,
    pub command: TaskInboxCommand,
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
    #[error(transparent)]
    Execution(#[from] crate::ExecutionError),
    #[error(transparent)]
    WorkflowIr(#[from] crate::WorkflowIrError),
    #[error(transparent)]
    StructuredResult(#[from] crate::StructuredResultError),
    #[error(transparent)]
    Coordinator(#[from] crate::CoordinatorError),
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

    pub fn open_with_storage_policy(
        path: impl AsRef<Path>,
        storage_policy: SqliteStoragePolicy,
    ) -> Result<Self, DurableWorkflowError> {
        Self::from_store(SqliteWorkflowStore::open_with_policy(path, storage_policy)?)
    }

    pub fn open_in_memory() -> Result<Self, DurableWorkflowError> {
        Self::from_store(SqliteWorkflowStore::open_in_memory()?)
    }

    pub fn configure_storage_policy(
        &mut self,
        storage_policy: SqliteStoragePolicy,
    ) -> Result<(), DurableWorkflowError> {
        self.store.configure_storage_policy(storage_policy)?;
        Ok(())
    }

    pub fn register_workflow_definition(
        &mut self,
        definition: &crate::WorkflowDefinition,
    ) -> Result<(), DurableWorkflowError> {
        self.store.register_workflow_definition(definition)?;
        Ok(())
    }

    pub fn workflow_definition(
        &self,
        definition_id: &str,
        version: u32,
    ) -> Result<Option<crate::WorkflowDefinition>, DurableWorkflowError> {
        Ok(self
            .store
            .load_workflow_definition(definition_id, version)?)
    }

    pub fn create_workflow_run(
        &mut self,
        run: &crate::WorkflowRun,
    ) -> Result<crate::WorkflowRun, DurableWorkflowError> {
        Ok(self.store.create_workflow_run(run)?)
    }

    pub fn workflow_run(
        &self,
        run_id: &str,
    ) -> Result<Option<crate::WorkflowRun>, DurableWorkflowError> {
        Ok(self.store.load_workflow_run(run_id)?)
    }

    pub fn start_workflow_step(
        &mut self,
        run_id: &str,
        step_id: &str,
        input: serde_json::Value,
        now: &str,
    ) -> Result<crate::WorkflowRun, DurableWorkflowError> {
        let mut run = self.workflow_run(run_id)?.ok_or_else(|| {
            WorkflowStoreError::InvalidValue("Workflow Run was not found".to_string())
        })?;
        let definition = self
            .workflow_definition(&run.definition_id, run.definition_version)?
            .ok_or_else(|| {
                WorkflowStoreError::InvalidValue("Workflow Definition was not found".to_string())
            })?;
        run.start_step(step_id, input, now, &definition)?;
        Ok(self.store.save_workflow_run(&run, run.revision)?)
    }

    pub fn complete_workflow_step(
        &mut self,
        run_id: &str,
        step_id: &str,
        output: serde_json::Value,
        artifacts: Vec<crate::ArtifactReference>,
        now: &str,
    ) -> Result<crate::WorkflowRun, DurableWorkflowError> {
        let mut run = self.workflow_run(run_id)?.ok_or_else(|| {
            WorkflowStoreError::InvalidValue("Workflow Run was not found".to_string())
        })?;
        let definition = self
            .workflow_definition(&run.definition_id, run.definition_version)?
            .ok_or_else(|| {
                WorkflowStoreError::InvalidValue("Workflow Definition was not found".to_string())
            })?;
        run.complete_step(&definition, step_id, output, artifacts, now)?;
        Ok(self.store.save_workflow_run(&run, run.revision)?)
    }

    pub fn submit_workflow_step_result(
        &mut self,
        run_id: &str,
        step_id: &str,
        raw: &str,
        artifacts: Vec<crate::ArtifactReference>,
        now: &str,
    ) -> Result<crate::WorkflowRun, DurableWorkflowError> {
        let mut run = self.workflow_run(run_id)?.ok_or_else(|| {
            WorkflowStoreError::InvalidValue("Workflow Run was not found".to_string())
        })?;
        let definition = self
            .workflow_definition(&run.definition_id, run.definition_version)?
            .ok_or_else(|| {
                WorkflowStoreError::InvalidValue("Workflow Definition was not found".to_string())
            })?;
        let plan = run
            .plans
            .last()
            .ok_or(crate::WorkflowIrError::InvalidPlanSequence)?;
        let step = plan
            .steps
            .iter()
            .find(|candidate| candidate.step_id == step_id)
            .ok_or_else(|| crate::WorkflowIrError::StepNotFound(step_id.to_string()))?;
        let schema_id = step
            .result_schema_id
            .as_deref()
            .ok_or_else(|| crate::WorkflowIrError::MissingResultSchema(step_id.to_string()))?;
        let schema = definition
            .result_schemas
            .iter()
            .find(|schema| schema.schema_id == schema_id)
            .ok_or_else(|| crate::WorkflowIrError::MissingResultSchema(schema_id.to_string()))?;
        run.submit_structured_result(step_id, schema, raw, artifacts, now)?;
        Ok(self.store.save_workflow_run(&run, run.revision)?)
    }

    pub fn propose_workflow_plan(
        &mut self,
        run_id: &str,
        proposal: crate::PlanProposal,
    ) -> Result<crate::WorkflowRun, DurableWorkflowError> {
        let mut run = self.workflow_run(run_id)?.ok_or_else(|| {
            WorkflowStoreError::InvalidValue("Workflow Run was not found".to_string())
        })?;
        let definition = self
            .workflow_definition(&run.definition_id, run.definition_version)?
            .ok_or_else(|| {
                WorkflowStoreError::InvalidValue("Workflow Definition was not found".to_string())
            })?;
        run.propose_plan(&definition, proposal)?;
        Ok(self.store.save_workflow_run(&run, run.revision)?)
    }

    pub fn activate_workflow_plan(
        &mut self,
        run_id: &str,
        proposal_id: &str,
        now: &str,
    ) -> Result<crate::WorkflowRun, DurableWorkflowError> {
        let mut run = self.workflow_run(run_id)?.ok_or_else(|| {
            WorkflowStoreError::InvalidValue("Workflow Run was not found".to_string())
        })?;
        let definition = self
            .workflow_definition(&run.definition_id, run.definition_version)?
            .ok_or_else(|| {
                WorkflowStoreError::InvalidValue("Workflow Definition was not found".to_string())
            })?;
        run.activate_plan(&definition, proposal_id, now)?;
        Ok(self.store.save_workflow_run(&run, run.revision)?)
    }

    pub fn record_workflow_usage(
        &mut self,
        run_id: &str,
        input_tokens: u64,
        output_tokens: u64,
        cost_micros: u64,
        now: &str,
    ) -> Result<crate::WorkflowRun, DurableWorkflowError> {
        let mut run = self.workflow_run(run_id)?.ok_or_else(|| {
            WorkflowStoreError::InvalidValue("Workflow Run was not found".to_string())
        })?;
        let definition = self
            .workflow_definition(&run.definition_id, run.definition_version)?
            .ok_or_else(|| {
                WorkflowStoreError::InvalidValue("Workflow Definition was not found".to_string())
            })?;
        run.record_usage(
            input_tokens,
            output_tokens,
            cost_micros,
            &definition.budget_policy,
            now,
        )?;
        Ok(self.store.save_workflow_run(&run, run.revision)?)
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

    #[must_use]
    pub fn current_task_inbox_projection(&self) -> Option<TaskInboxMaterializedProjection> {
        self.task_inbox
            .clone()
            .map(|task_inbox| self.task_inbox_projection(task_inbox))
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
        if let Some(run_id) = task_inbox_command_run_id(&command)?
            && self
                .store
                .executor_lease_for_run(run_id)?
                .is_some_and(|lease| lease.state.accepts_mutation())
        {
            return Err(crate::ExecutionError::FencedMutationRequired.into());
        }
        self.apply_task_inbox_unfenced(command)
    }

    fn apply_task_inbox_unfenced(
        &mut self,
        command: TaskInboxCommand,
    ) -> Result<TaskInboxMaterializedProjection, DurableWorkflowError> {
        if let TaskInboxCommand::AppendEvents { events, updated_at } = &command {
            return self.append_task_inbox_events_unfenced(command.clone(), events, updated_at);
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

    pub fn apply_task_inbox_as_executor(
        &mut self,
        request: ExecutorTaskInboxCommand,
    ) -> Result<TaskInboxMaterializedProjection, DurableWorkflowError> {
        if self.migration.phase != crate::WorkflowMigrationPhase::Active {
            return Err(WorkflowStoreError::TaskInboxNotActive.into());
        }
        request.context.validate()?;
        let command_type = task_inbox_command_type(&request.command);
        let idempotency_key = IdempotencyKey::for_payload(
            &request.context.command_id,
            command_type,
            &request.context.now,
            &request,
        )?;
        if let TaskInboxCommand::AppendEvents { events, updated_at } = &request.command {
            if let Some(record) = self.store.idempotency_record(&idempotency_key)? {
                let _: RuntimeEventAppendReceipt = decode_stored_result(&record.result_projection)?;
                return Ok(
                    self.task_inbox_projection(self.task_inbox.clone().ok_or_else(|| {
                        WorkflowStoreError::InvalidValue(
                            "active TaskInbox projection is missing".to_string(),
                        )
                    })?),
                );
            }
            let mut candidate = WorkflowStateMachine::restore(self.state.snapshot())?;
            let mut task_inbox = self.task_inbox.clone().ok_or_else(|| {
                WorkflowStoreError::InvalidValue(
                    "active TaskInbox projection is missing".to_string(),
                )
            })?;
            task_inbox.apply_command(&mut candidate, request.command.clone())?;
            let receipt = self.store.append_runtime_events_as_executor(
                &task_inbox,
                events,
                updated_at,
                &request.context,
                self.revision,
                &idempotency_key,
            )?;
            self.state = candidate;
            self.task_inbox = Some(task_inbox.clone());
            self.revision = receipt.revision;
            return Ok(self.task_inbox_projection(task_inbox));
        }
        if let Some(record) = self.store.idempotency_record(&idempotency_key)? {
            return decode_stored_result(&record.result_projection);
        }
        let command_run_id = task_inbox_command_run_id(&request.command)?
            .ok_or(crate::ExecutionError::LeaseRunMismatch)?;
        if command_run_id != request.context.run_id {
            return Err(crate::ExecutionError::LeaseRunMismatch.into());
        }
        let mut candidate = WorkflowStateMachine::restore(self.state.snapshot())?;
        let mut task_inbox = self.task_inbox.clone().ok_or_else(|| {
            WorkflowStoreError::InvalidValue("active TaskInbox projection is missing".to_string())
        })?;
        task_inbox.apply_command(&mut candidate, request.command)?;
        let snapshot = candidate.snapshot();
        let projected_revision = self.revision.checked_add(1).ok_or_else(|| {
            WorkflowStoreError::InvalidValue("workflow revision overflow".to_string())
        })?;
        let result = TaskInboxMaterializedProjection {
            schema_version: WORKFLOW_SCHEMA_VERSION,
            revision: projected_revision,
            migration: self.migration.clone(),
            snapshot: snapshot.clone(),
            task_inbox: task_inbox.clone(),
        };
        let result_json = encode_stored_result(&result)?;
        let revision = self.store.save_active_task_inbox_as_executor(
            &snapshot,
            &task_inbox,
            &request.context,
            self.revision,
            &idempotency_key,
            &result_json,
        )?;
        self.state = candidate;
        self.task_inbox = Some(task_inbox.clone());
        self.revision = revision;
        debug_assert_eq!(revision, result.revision);
        Ok(result)
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
        let idempotency_key = IdempotencyKey::for_payload(
            &request.command_id,
            "scheduler.claim",
            &request.now,
            &request,
        )?;
        if let Some(record) = self.store.idempotency_record(&idempotency_key)? {
            return decode_stored_result(&record.result_projection);
        }
        let mut candidate = WorkflowStateMachine::restore(self.state.snapshot())?;
        let mut task_inbox = self.task_inbox.clone().ok_or_else(|| {
            WorkflowStoreError::InvalidValue("active TaskInbox projection is missing".to_string())
        })?;
        let poll = self
            .scheduler
            .claim_next(&mut task_inbox, &mut candidate, request)?;
        let claimed = poll.claim.is_some();
        let projected_revision = if claimed {
            self.revision.checked_add(1).ok_or_else(|| {
                WorkflowStoreError::InvalidValue("workflow revision overflow".to_string())
            })?
        } else {
            self.revision
        };
        let result = SchedulerClaimProjection {
            schema_version: WORKFLOW_SCHEMA_VERSION,
            revision: projected_revision,
            migration: self.migration.clone(),
            snapshot: candidate.snapshot(),
            task_inbox: task_inbox.clone(),
            claim: poll.claim.clone(),
            next_wake_at: poll.next_wake_at.clone(),
            admission: poll.admission.clone(),
        };
        let result_json = encode_stored_result(&result)?;
        if claimed {
            let snapshot = candidate.snapshot();
            let lease = &poll
                .claim
                .as_ref()
                .expect("claim checked above")
                .executor_lease;
            let revision = self.store.save_active_task_inbox_with_executor_lease(
                &snapshot,
                &task_inbox,
                lease,
                self.revision,
                &idempotency_key,
                &result_json,
            )?;
            self.state = candidate;
            self.task_inbox = Some(task_inbox.clone());
            self.revision = revision;
        } else {
            self.store
                .record_idempotency_result(&idempotency_key, self.revision, &result_json)?;
        }
        debug_assert_eq!(self.revision, result.revision);
        Ok(result)
    }

    pub fn executor_lease_for_run(
        &self,
        run_id: &str,
    ) -> Result<Option<ExecutorLease>, DurableWorkflowError> {
        Ok(self.store.executor_lease_for_run(run_id)?)
    }

    pub fn runtime_events(
        &self,
        run_id: &str,
        after_sequence: u64,
        limit: usize,
    ) -> Result<RuntimeEventPage, DurableWorkflowError> {
        Ok(self.store.runtime_events(run_id, after_sequence, limit)?)
    }

    pub fn apply_executor_lease_command(
        &mut self,
        command: &ExecutorLeaseCommand,
    ) -> Result<ExecutorLease, DurableWorkflowError> {
        Ok(self.store.apply_executor_lease_command(command)?)
    }

    pub fn validate_executor_context(
        &self,
        context: &ExecutorCommandContext,
    ) -> Result<ExecutorLease, DurableWorkflowError> {
        Ok(self.store.validate_executor_context(context)?)
    }

    pub fn takeover_executor_lease(
        &mut self,
        request: &ExecutorTakeoverRequest,
    ) -> Result<ExecutorLease, DurableWorkflowError> {
        Ok(self.store.takeover_executor_lease(request)?)
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

    fn append_task_inbox_events_unfenced(
        &mut self,
        command: TaskInboxCommand,
        events: &[crate::InboxEventRecord],
        updated_at: &str,
    ) -> Result<TaskInboxMaterializedProjection, DurableWorkflowError> {
        let mut candidate = WorkflowStateMachine::restore(self.state.snapshot())?;
        let mut task_inbox = self.task_inbox.clone().ok_or_else(|| {
            WorkflowStoreError::InvalidValue("active TaskInbox projection is missing".to_string())
        })?;
        task_inbox.apply_command(&mut candidate, command)?;
        let receipt =
            self.store
                .append_runtime_events(&task_inbox, events, updated_at, self.revision)?;
        self.state = candidate;
        self.task_inbox = Some(task_inbox.clone());
        self.revision = receipt.revision;
        Ok(self.task_inbox_projection(task_inbox))
    }
}

fn task_inbox_command_run_id(
    command: &TaskInboxCommand,
) -> Result<Option<&str>, crate::ExecutionError> {
    let run_id = match command {
        TaskInboxCommand::TransitionRun { run_id, .. }
        | TaskInboxCommand::ReplaceArtifacts { run_id, .. } => Some(run_id.as_str()),
        TaskInboxCommand::TransitionRunProjection { run, .. }
        | TaskInboxCommand::UpdateRunProjection { run, .. } => Some(run.id.as_str()),
        TaskInboxCommand::CancelTaskProjection { run, .. } => {
            run.as_ref().map(|run| run.id.as_str())
        }
        TaskInboxCommand::UpdateTaskProjection { task, .. }
        | TaskInboxCommand::QueueTaskProjection { task, .. } => task.current_run_id.as_deref(),
        TaskInboxCommand::AppendEvents { events, .. } => {
            let Some(first) = events.first() else {
                return Ok(None);
            };
            if events.iter().any(|event| event.run_id != first.run_id) {
                return Err(crate::ExecutionError::LeaseRunMismatch);
            }
            Some(first.run_id.as_str())
        }
        TaskInboxCommand::ReplaceArtifactSet { artifacts, .. } => {
            let Some(first) = artifacts.first() else {
                return Ok(None);
            };
            if artifacts
                .iter()
                .any(|artifact| artifact.run_id != first.run_id)
            {
                return Err(crate::ExecutionError::LeaseRunMismatch);
            }
            Some(first.run_id.as_str())
        }
        TaskInboxCommand::UpsertApproval { approval, .. } => approval.run_id.as_deref(),
        TaskInboxCommand::CreateTask { .. }
        | TaskInboxCommand::QueueTask { .. }
        | TaskInboxCommand::UpdateTaskDefinition { .. }
        | TaskInboxCommand::DispatchRun { .. }
        | TaskInboxCommand::DispatchRunProjection { .. }
        | TaskInboxCommand::CancelTask { .. }
        | TaskInboxCommand::DeleteTask { .. }
        | TaskInboxCommand::UpsertResource { .. } => None,
    };
    Ok(run_id)
}

const fn task_inbox_command_type(command: &TaskInboxCommand) -> &'static str {
    match command {
        TaskInboxCommand::CreateTask { .. } => "task_inbox.create_task",
        TaskInboxCommand::QueueTask { .. } => "task_inbox.queue_task",
        TaskInboxCommand::UpdateTaskDefinition { .. } => "task_inbox.update_task_definition",
        TaskInboxCommand::DispatchRun { .. } => "task_inbox.dispatch_run",
        TaskInboxCommand::TransitionRun { .. } => "task_inbox.transition_run",
        TaskInboxCommand::CancelTask { .. } => "task_inbox.cancel_task",
        TaskInboxCommand::DeleteTask { .. } => "task_inbox.delete_task",
        TaskInboxCommand::UpdateTaskProjection { .. } => "task_inbox.update_task_projection",
        TaskInboxCommand::QueueTaskProjection { .. } => "task_inbox.queue_task_projection",
        TaskInboxCommand::DispatchRunProjection { .. } => "task_inbox.dispatch_run_projection",
        TaskInboxCommand::TransitionRunProjection { .. } => "task_inbox.transition_run_projection",
        TaskInboxCommand::UpdateRunProjection { .. } => "task_inbox.update_run_projection",
        TaskInboxCommand::CancelTaskProjection { .. } => "task_inbox.cancel_task_projection",
        TaskInboxCommand::AppendEvents { .. } => "task_inbox.append_events",
        TaskInboxCommand::ReplaceArtifacts { .. } => "task_inbox.replace_artifacts",
        TaskInboxCommand::ReplaceArtifactSet { .. } => "task_inbox.replace_artifact_set",
        TaskInboxCommand::UpsertApproval { .. } => "task_inbox.upsert_approval",
        TaskInboxCommand::UpsertResource { .. } => "task_inbox.upsert_resource",
    }
}

fn encode_stored_result<T: Serialize>(value: &T) -> Result<String, WorkflowStoreError> {
    serde_json::to_string(value).map_err(|error| {
        WorkflowStoreError::InvalidValue(format!("failed to encode idempotency result: {error}"))
    })
}

fn decode_stored_result<T: for<'de> Deserialize<'de>>(
    encoded: &str,
) -> Result<T, DurableWorkflowError> {
    serde_json::from_str(encoded)
        .map_err(|error| {
            WorkflowStoreError::InvalidValue(format!(
                "invalid persisted idempotency result: {error}"
            ))
        })
        .map_err(Into::into)
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
