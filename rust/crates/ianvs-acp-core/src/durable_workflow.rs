use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

use chrono::{DateTime, SecondsFormat};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use sha2::{Digest, Sha256};
use thiserror::Error;

use crate::{
    ExecutorCommandContext, ExecutorLease, ExecutorLeaseCommand, ExecutorTakeoverRequest,
    IdempotencyKey, RecoveryReport, RuntimeEventAppendReceipt, RuntimeEventPage,
    SchedulerAdmission, SchedulerClaim, SchedulerClaimRequest, SchedulerConfig, SchedulerCore,
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

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WorkflowStepTaskBinding {
    pub workflow_run_id: String,
    pub plan_version: u32,
    pub step_id: String,
    pub task_id: String,
    pub task_run_id: Option<String>,
    pub input_revision: u64,
    pub consumed_event_sequence: u64,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WorkflowTaskReconciliation {
    pub scanned_runs: usize,
    pub enqueued_tasks: usize,
    pub retried_tasks: usize,
    pub completed_steps: usize,
    pub failed_steps: usize,
    pub waiting_steps: usize,
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

    pub fn open_in_memory() -> Result<Self, DurableWorkflowError> {
        Self::from_store(SqliteWorkflowStore::open_in_memory()?)
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

    pub fn workflow_step_task_bindings(
        &self,
        run_id: &str,
    ) -> Result<Vec<WorkflowStepTaskBinding>, DurableWorkflowError> {
        Ok(self.store.workflow_step_task_bindings(run_id)?)
    }

    pub fn reconcile_workflow_tasks(
        &mut self,
        available_agents: &BTreeSet<String>,
        now: &str,
    ) -> Result<WorkflowTaskReconciliation, DurableWorkflowError> {
        if self.migration.phase != crate::WorkflowMigrationPhase::Active {
            return Err(WorkflowStoreError::TaskInboxNotActive.into());
        }
        DateTime::parse_from_rfc3339(now).map_err(|_| {
            WorkflowStoreError::InvalidValue(
                "workflow reconciliation now must be RFC-3339".to_string(),
            )
        })?;
        let mut result = WorkflowTaskReconciliation::default();
        for run_id in self.store.workflow_run_ids()? {
            result.scanned_runs = result.scanned_runs.saturating_add(1);
            let Some(run) = self.workflow_run(&run_id)? else {
                continue;
            };
            if matches!(
                run.status,
                crate::WorkflowRunStatus::Succeeded
                    | crate::WorkflowRunStatus::Failed
                    | crate::WorkflowRunStatus::Cancelled
            ) {
                continue;
            }
            let delta = self.reconcile_workflow_run(&run, available_agents, now)?;
            result.enqueued_tasks = result.enqueued_tasks.saturating_add(delta.enqueued_tasks);
            result.retried_tasks = result.retried_tasks.saturating_add(delta.retried_tasks);
            result.completed_steps = result.completed_steps.saturating_add(delta.completed_steps);
            result.failed_steps = result.failed_steps.saturating_add(delta.failed_steps);
            result.waiting_steps = result.waiting_steps.saturating_add(delta.waiting_steps);
        }
        Ok(result)
    }

    pub fn resolve_workflow_approval_step(
        &mut self,
        run_id: &str,
        step_id: &str,
        approved: bool,
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
        run.resolve_approval_step(&definition, step_id, approved, now)?;
        Ok(self.store.save_workflow_run(&run, run.revision)?)
    }

    pub fn signal_workflow_wait_step(
        &mut self,
        run_id: &str,
        step_id: &str,
        signal_name: &str,
        payload: Value,
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
        let step = active_step_definition(&run, step_id)?;
        let crate::StepKind::Wait {
            signal_name: expected,
            ..
        } = &step.kind
        else {
            return Err(crate::WorkflowIrError::InvalidStepState.into());
        };
        if expected.as_deref() != Some(signal_name)
            || signal_name.is_empty()
            || signal_name.trim() != signal_name
        {
            return Err(WorkflowStoreError::InvalidValue(
                "workflow wait signal does not match the Step definition".to_string(),
            )
            .into());
        }
        run.resume_step(step_id, now)?;
        let mut output = Map::new();
        output.insert("timedOut".to_string(), Value::Bool(false));
        output.insert("signal".to_string(), Value::String(signal_name.to_string()));
        output.insert("payload".to_string(), payload);
        run.complete_step(&definition, step_id, Value::Object(output), Vec::new(), now)?;
        Ok(self.store.save_workflow_run(&run, run.revision)?)
    }

    #[allow(clippy::too_many_lines)]
    fn reconcile_workflow_run(
        &mut self,
        original_run: &crate::WorkflowRun,
        available_agents: &BTreeSet<String>,
        now: &str,
    ) -> Result<WorkflowTaskReconciliation, DurableWorkflowError> {
        let definition = self
            .workflow_definition(&original_run.definition_id, original_run.definition_version)?
            .ok_or_else(|| {
                WorkflowStoreError::InvalidValue("Workflow Definition was not found".to_string())
            })?;
        let mut run = original_run.clone();
        let mut bindings = self
            .store
            .workflow_step_task_bindings(&original_run.run_id)?;
        let mut binding_indexes = bindings
            .iter()
            .enumerate()
            .map(|(index, binding)| ((binding.plan_version, binding.step_id.clone()), index))
            .collect::<BTreeMap<_, _>>();
        let mut inbox = self.task_inbox.clone().ok_or_else(|| {
            WorkflowStoreError::InvalidValue("active TaskInbox projection is missing".to_string())
        })?;
        let mut workflow = WorkflowStateMachine::restore(self.state.snapshot())?;
        let mut task_projection_changed = false;
        let mut run_changed = false;
        let mut changed_binding_indexes = BTreeSet::new();
        let mut delta = WorkflowTaskReconciliation::default();

        for (index, binding) in bindings.iter_mut().enumerate() {
            let task = inbox
                .tasks
                .iter()
                .find(|task| task.id == binding.task_id)
                .ok_or_else(|| {
                    WorkflowStoreError::InvalidValue(format!(
                        "workflow binding references missing Task {}",
                        binding.task_id
                    ))
                })?;
            if binding.task_run_id != task.current_run_id {
                binding.task_run_id.clone_from(&task.current_run_id);
                binding.updated_at = now.to_string();
                changed_binding_indexes.insert(index);
            }
        }

        let max_iterations = usize::try_from(definition.budget_policy.max_plan_nodes)
            .unwrap_or(usize::MAX)
            .saturating_mul(4)
            .saturating_add(4);
        for _ in 0..max_iterations {
            let mut progressed = false;

            let waiting_steps = run
                .step_runs
                .iter()
                .filter(|step| step.status == crate::StepRunStatus::Waiting)
                .map(|step| step.step_id.clone())
                .collect::<Vec<_>>();
            for step_id in waiting_steps {
                let step = active_step_definition(&run, &step_id)?.clone();
                if let crate::StepKind::Wait { .. } = step.kind
                    && wait_deadline_reached(&run, &step_id, now)?
                {
                    run.resume_step(&step_id, now)?;
                    run.complete_step(
                        &definition,
                        &step_id,
                        serde_json::json!({"timedOut": true, "signal": null}),
                        Vec::new(),
                        now,
                    )?;
                    run_changed = true;
                    progressed = true;
                    delta.completed_steps = delta.completed_steps.saturating_add(1);
                }
            }

            let bound_steps = bindings
                .iter()
                .enumerate()
                .map(|(index, binding)| (index, binding.clone()))
                .collect::<Vec<_>>();
            for (binding_index, binding) in bound_steps {
                let Some(step_run) = run.step_runs.iter().find(|step| {
                    step.step_id == binding.step_id && step.plan_version == binding.plan_version
                }) else {
                    continue;
                };
                if step_run.status != crate::StepRunStatus::Running {
                    continue;
                }
                let task = inbox
                    .tasks
                    .iter()
                    .find(|task| task.id == binding.task_id)
                    .cloned()
                    .ok_or_else(|| {
                        WorkflowStoreError::InvalidValue(format!(
                            "workflow binding references missing Task {}",
                            binding.task_id
                        ))
                    })?;
                match task.status {
                    crate::InboxTaskStatus::Done => {
                        let raw = workflow_task_result(&inbox, &task);
                        let step = active_step_definition(&run, &binding.step_id)?.clone();
                        let artifacts = workflow_artifact_references(
                            &inbox,
                            &binding.task_id,
                            task.current_run_id.as_deref(),
                        );
                        if step.result_schema_id.is_some() {
                            let schema_id = step.result_schema_id.as_deref().expect("checked");
                            let schema = definition
                                .result_schemas
                                .iter()
                                .find(|schema| schema.schema_id == schema_id)
                                .ok_or_else(|| {
                                    crate::WorkflowIrError::MissingResultSchema(
                                        schema_id.to_string(),
                                    )
                                })?;
                            let structured = run.submit_structured_result(
                                &binding.step_id,
                                schema,
                                &raw,
                                artifacts,
                                now,
                            )?;
                            if structured.status
                                == crate::StructuredResultStatus::CorrectionRequired
                            {
                                let correction_prompt = structured
                                    .correction_prompt
                                    .as_deref()
                                    .ok_or(crate::WorkflowIrError::InvalidStepState)?;
                                match run.start_structured_correction(
                                    &definition,
                                    &binding.step_id,
                                    now,
                                ) {
                                    Ok(()) => {
                                        let correction_attempt =
                                            u32::try_from(structured.attempts.len())
                                                .unwrap_or(u32::MAX);
                                        queue_workflow_structured_correction(
                                            &mut inbox,
                                            &mut workflow,
                                            &run,
                                            &task,
                                            &binding.step_id,
                                            correction_attempt,
                                            correction_prompt,
                                            now,
                                        )?;
                                        bindings[binding_index].task_run_id = None;
                                        bindings[binding_index].input_revision =
                                            original_run.revision.saturating_add(1);
                                        task_projection_changed = true;
                                        delta.retried_tasks = delta.retried_tasks.saturating_add(1);
                                    }
                                    Err(crate::WorkflowIrError::InvocationBudgetExhausted) => {
                                        run.wait_step(&binding.step_id, true, now)?;
                                        delta.waiting_steps = delta.waiting_steps.saturating_add(1);
                                    }
                                    Err(error) => return Err(error.into()),
                                }
                            } else if structured.status == crate::StructuredResultStatus::Valid {
                                delta.completed_steps = delta.completed_steps.saturating_add(1);
                            } else {
                                delta.waiting_steps = delta.waiting_steps.saturating_add(1);
                            }
                        } else {
                            let output = serde_json::from_str(&raw)
                                .unwrap_or_else(|_| serde_json::json!({"summary": raw}));
                            run.complete_step(
                                &definition,
                                &binding.step_id,
                                output,
                                artifacts,
                                now,
                            )?;
                            delta.completed_steps = delta.completed_steps.saturating_add(1);
                        }
                        if let Some(task_run_id) = task.current_run_id.as_deref() {
                            bindings[binding_index].consumed_event_sequence = self
                                .store
                                .latest_runtime_event_sequence_for_run(task_run_id)?;
                        }
                        bindings[binding_index].updated_at = now.to_string();
                        changed_binding_indexes.insert(binding_index);
                        run_changed = true;
                        progressed = true;
                    }
                    crate::InboxTaskStatus::Failed => {
                        let error = task
                            .error
                            .as_deref()
                            .or_else(|| {
                                task.current_run_id.as_deref().and_then(|run_id| {
                                    inbox
                                        .runs
                                        .iter()
                                        .find(|run| run.id == run_id)
                                        .and_then(|run| run.error.as_deref())
                                })
                            })
                            .unwrap_or("Task execution failed.")
                            .to_string();
                        let retried =
                            run.fail_step(&definition, &binding.step_id, &error, true, now)?;
                        delta.failed_steps = delta.failed_steps.saturating_add(1);
                        if retried {
                            queue_workflow_task_retry(
                                &mut inbox,
                                &mut workflow,
                                &mut run,
                                &definition,
                                &task,
                                &binding.step_id,
                                now,
                            )?;
                            bindings[binding_index].task_run_id = None;
                            bindings[binding_index].input_revision =
                                original_run.revision.saturating_add(1);
                            task_projection_changed = true;
                            delta.retried_tasks = delta.retried_tasks.saturating_add(1);
                        }
                        if let Some(task_run_id) = task.current_run_id.as_deref() {
                            bindings[binding_index].consumed_event_sequence = self
                                .store
                                .latest_runtime_event_sequence_for_run(task_run_id)?;
                        }
                        bindings[binding_index].updated_at = now.to_string();
                        changed_binding_indexes.insert(binding_index);
                        run_changed = true;
                        progressed = true;
                    }
                    crate::InboxTaskStatus::Cancelled | crate::InboxTaskStatus::Rejected => {
                        run.fail_step(
                            &definition,
                            &binding.step_id,
                            "Task execution was cancelled or rejected.",
                            false,
                            now,
                        )?;
                        bindings[binding_index].updated_at = now.to_string();
                        changed_binding_indexes.insert(binding_index);
                        run_changed = true;
                        progressed = true;
                        delta.failed_steps = delta.failed_steps.saturating_add(1);
                    }
                    _ => {}
                }
            }

            let ready_steps = run
                .step_runs
                .iter()
                .filter(|step| step.status == crate::StepRunStatus::Ready)
                .map(|step| (step.step_id.clone(), step.plan_version))
                .collect::<Vec<_>>();
            for (step_id, plan_version) in ready_steps {
                let step = active_step_definition(&run, &step_id)?.clone();
                let input = resolve_step_input(&run, &step)?;
                match &step.kind {
                    crate::StepKind::Agent {
                        capability_profile,
                        prompt_template,
                    } => {
                        if binding_indexes.contains_key(&(plan_version, step_id.clone()))
                            || !available_agents.contains(capability_profile)
                        {
                            continue;
                        }
                        let Some(workspace_path) = workflow_workspace_path(&input) else {
                            continue;
                        };
                        run.start_step(&step_id, input.clone(), now, &definition)?;
                        let task_id = workflow_task_id(&run.run_id, plan_version, &step_id);
                        let task = workflow_task_record(
                            &run,
                            &step,
                            &task_id,
                            workspace_path,
                            capability_profile,
                            prompt_template,
                            &input,
                            now,
                        )?;
                        inbox
                            .apply_command(&mut workflow, TaskInboxCommand::CreateTask { task })?;
                        inbox.apply_command(
                            &mut workflow,
                            TaskInboxCommand::QueueTask {
                                task_id: task_id.clone(),
                                updated_at: now.to_string(),
                            },
                        )?;
                        let binding = WorkflowStepTaskBinding {
                            workflow_run_id: run.run_id.clone(),
                            plan_version,
                            step_id: step_id.clone(),
                            task_id,
                            task_run_id: None,
                            input_revision: original_run.revision.saturating_add(1),
                            consumed_event_sequence: 0,
                            created_at: now.to_string(),
                            updated_at: now.to_string(),
                        };
                        let binding_index = bindings.len();
                        bindings.push(binding);
                        binding_indexes.insert((plan_version, step_id.clone()), binding_index);
                        changed_binding_indexes.insert(binding_index);
                        task_projection_changed = true;
                        run_changed = true;
                        progressed = true;
                        delta.enqueued_tasks = delta.enqueued_tasks.saturating_add(1);
                    }
                    crate::StepKind::Condition { predicate } => {
                        let matched = evaluate_condition(&run, predicate)?;
                        run.start_step(&step_id, input, now, &definition)?;
                        run.complete_step(
                            &definition,
                            &step_id,
                            serde_json::json!({"matched": matched}),
                            Vec::new(),
                            now,
                        )?;
                        run_changed = true;
                        progressed = true;
                        delta.completed_steps = delta.completed_steps.saturating_add(1);
                    }
                    crate::StepKind::Checkpoint | crate::StepKind::Parallel { .. } => {
                        run.start_step(&step_id, input, now, &definition)?;
                        run.complete_step(
                            &definition,
                            &step_id,
                            serde_json::json!({"completed": true}),
                            Vec::new(),
                            now,
                        )?;
                        run_changed = true;
                        progressed = true;
                        delta.completed_steps = delta.completed_steps.saturating_add(1);
                    }
                    crate::StepKind::Approval { .. } => {
                        run.start_step(&step_id, input, now, &definition)?;
                        run.wait_step(&step_id, true, now)?;
                        run_changed = true;
                        progressed = true;
                        delta.waiting_steps = delta.waiting_steps.saturating_add(1);
                    }
                    crate::StepKind::Wait {
                        timeout_seconds, ..
                    } => {
                        let mut input = input.as_object().cloned().unwrap_or_default();
                        let parsed = DateTime::parse_from_rfc3339(now).map_err(|_| {
                            WorkflowStoreError::InvalidValue(
                                "workflow reconciliation now must be RFC-3339".to_string(),
                            )
                        })?;
                        let seconds = i64::try_from(*timeout_seconds).map_err(|_| {
                            WorkflowStoreError::InvalidValue(
                                "workflow wait timeout is outside i64 range".to_string(),
                            )
                        })?;
                        let wake_at = parsed
                            .checked_add_signed(chrono::Duration::seconds(seconds))
                            .ok_or_else(|| {
                                WorkflowStoreError::InvalidValue(
                                    "workflow wait deadline overflow".to_string(),
                                )
                            })?
                            .to_rfc3339_opts(SecondsFormat::Millis, true);
                        input.insert("_ianvsWakeAt".to_string(), Value::String(wake_at));
                        run.start_step(&step_id, Value::Object(input), now, &definition)?;
                        run.wait_step(&step_id, false, now)?;
                        run_changed = true;
                        progressed = true;
                        delta.waiting_steps = delta.waiting_steps.saturating_add(1);
                    }
                    crate::StepKind::Map { .. } | crate::StepKind::Reduce { .. } => {}
                }
            }
            if !progressed {
                break;
            }
        }

        if run_changed {
            let changed_bindings = changed_binding_indexes
                .iter()
                .filter_map(|index| bindings.get(*index))
                .cloned()
                .collect::<Vec<_>>();
            let workflow_snapshot = task_projection_changed.then(|| workflow.snapshot());
            let (committed, revision) = self.store.save_workflow_reconciliation(
                &run,
                original_run.revision,
                workflow_snapshot.as_ref(),
                task_projection_changed.then_some(&inbox),
                self.revision,
                &changed_bindings,
            )?;
            let _ = committed;
            if task_projection_changed {
                self.state = workflow;
                self.task_inbox = Some(inbox);
                self.revision = revision;
            }
        } else {
            for binding_index in changed_binding_indexes {
                if let Some(binding) = bindings.get(binding_index) {
                    self.store.save_workflow_step_task_binding(binding)?;
                }
            }
        }
        Ok(delta)
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

fn active_step_definition<'a>(
    run: &'a crate::WorkflowRun,
    step_id: &str,
) -> Result<&'a crate::StepDefinition, crate::WorkflowIrError> {
    run.plans
        .last()
        .ok_or(crate::WorkflowIrError::InvalidPlanSequence)?
        .steps
        .iter()
        .find(|step| step.step_id == step_id)
        .ok_or_else(|| crate::WorkflowIrError::StepNotFound(step_id.to_string()))
}

fn resolve_step_input(
    run: &crate::WorkflowRun,
    step: &crate::StepDefinition,
) -> Result<Value, DurableWorkflowError> {
    let mut input = Map::new();
    for (name, binding) in &step.inputs {
        input.insert(name.clone(), resolve_input_binding(run, binding)?);
    }
    Ok(Value::Object(input))
}

fn resolve_input_binding(
    run: &crate::WorkflowRun,
    binding: &crate::InputBinding,
) -> Result<Value, DurableWorkflowError> {
    match binding {
        crate::InputBinding::Literal { value } => Ok(value.clone()),
        crate::InputBinding::StepOutput { step_id, pointer } => {
            let source = run
                .step_runs
                .iter()
                .find(|step| {
                    step.step_id == *step_id && step.status == crate::StepRunStatus::Succeeded
                })
                .and_then(|step| step.output.as_ref())
                .ok_or(crate::WorkflowIrError::InvalidStepState)?;
            source
                .pointer(pointer)
                .cloned()
                .ok_or_else(|| crate::WorkflowIrError::InvalidStepState.into())
        }
        crate::InputBinding::Artifact { artifact_id } => {
            let artifact = run
                .step_runs
                .iter()
                .flat_map(|step| &step.artifacts)
                .find(|artifact| artifact.artifact_id == *artifact_id)
                .ok_or(crate::WorkflowIrError::InvalidArtifacts)?;
            serde_json::to_value(artifact).map_err(|error| {
                WorkflowStoreError::InvalidValue(format!(
                    "failed to project workflow artifact input: {error}"
                ))
                .into()
            })
        }
    }
}

fn evaluate_condition(
    run: &crate::WorkflowRun,
    predicate: &crate::ConditionPredicate,
) -> Result<bool, DurableWorkflowError> {
    match predicate {
        crate::ConditionPredicate::Equals { input, value } => {
            Ok(resolve_input_binding(run, input)? == *value)
        }
        crate::ConditionPredicate::Exists { input } => {
            Ok(!resolve_input_binding(run, input)?.is_null())
        }
        crate::ConditionPredicate::Boolean { input } => {
            Ok(resolve_input_binding(run, input)?.as_bool() == Some(true))
        }
    }
}

fn workflow_workspace_path(input: &Value) -> Option<&str> {
    let object = input.as_object()?;
    object
        .get("workspacePath")
        .or_else(|| object.get("workspace_path"))
        .or_else(|| object.get("cwd"))
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty() && value.trim() == *value)
}

fn workflow_task_id(run_id: &str, plan_version: u32, step_id: &str) -> String {
    let mut digest = Sha256::new();
    digest.update(run_id.as_bytes());
    digest.update([0]);
    digest.update(plan_version.to_be_bytes());
    digest.update([0]);
    digest.update(step_id.as_bytes());
    let encoded = format!("{:x}", digest.finalize());
    format!("workflow-task-{}", &encoded[..32])
}

#[allow(clippy::too_many_arguments)]
fn workflow_task_record(
    run: &crate::WorkflowRun,
    step: &crate::StepDefinition,
    task_id: &str,
    workspace_path: &str,
    agent_name: &str,
    prompt_template: &str,
    input: &Value,
    now: &str,
) -> Result<crate::InboxTaskRecord, DurableWorkflowError> {
    let input_json = serde_json::to_string_pretty(input).map_err(|error| {
        WorkflowStoreError::InvalidValue(format!(
            "failed to encode resolved workflow Step input: {error}"
        ))
    })?;
    Ok(crate::InboxTaskRecord {
        id: task_id.to_string(),
        title: format!("Workflow {} · {}", run.run_id, step.step_id),
        description: format!("{prompt_template}\n\nResolved workflow input:\n{input_json}"),
        workspace_path: workspace_path.to_string(),
        agent_name: agent_name.to_string(),
        status: crate::InboxTaskStatus::Inbox,
        priority: crate::InboxTaskPriority::Normal,
        created_at: now.to_string(),
        updated_at: now.to_string(),
        session_id: None,
        current_run_id: None,
        summary: None,
        error: None,
        resource_id: None,
        skill_ids: Vec::new(),
        metadata: BTreeMap::from([
            (
                "workflow_run_id".to_string(),
                Value::String(run.run_id.clone()),
            ),
            (
                "workflow_plan_version".to_string(),
                Value::from(run.active_plan_version),
            ),
            (
                "workflow_step_id".to_string(),
                Value::String(step.step_id.clone()),
            ),
            (
                "workflow_input_revision".to_string(),
                Value::from(run.revision.saturating_add(1)),
            ),
            ("workflow_auto_complete".to_string(), Value::Bool(true)),
        ]),
    })
}

fn queue_workflow_task_retry(
    inbox: &mut TaskInboxSnapshot,
    workflow: &mut WorkflowStateMachine,
    run: &mut crate::WorkflowRun,
    definition: &crate::WorkflowDefinition,
    task: &crate::InboxTaskRecord,
    step_id: &str,
    now: &str,
) -> Result<(), DurableWorkflowError> {
    let step = active_step_definition(run, step_id)?.clone();
    let input = resolve_step_input(run, &step)?;
    let mut queued = task.clone();
    queued.status = crate::InboxTaskStatus::Queued;
    queued.current_run_id = None;
    queued.summary = None;
    queued.error = None;
    queued.updated_at = now.to_string();
    queued
        .metadata
        .insert("next_retry_at".to_string(), Value::String(now.to_string()));
    queued.metadata.insert(
        "workflow_input_revision".to_string(),
        Value::from(run.revision.saturating_add(1)),
    );
    inbox.apply_command(
        workflow,
        TaskInboxCommand::QueueTaskProjection {
            task: queued,
            updated_at: now.to_string(),
        },
    )?;
    run.start_step(step_id, input, now, definition)?;
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn queue_workflow_structured_correction(
    inbox: &mut TaskInboxSnapshot,
    workflow: &mut WorkflowStateMachine,
    run: &crate::WorkflowRun,
    previous_task: &crate::InboxTaskRecord,
    step_id: &str,
    correction_attempt: u32,
    correction_prompt: &str,
    now: &str,
) -> Result<(), DurableWorkflowError> {
    let session_id = previous_task.session_id.clone().or_else(|| {
        previous_task
            .current_run_id
            .as_deref()
            .and_then(|run_id| inbox.runs.iter().find(|run| run.id == run_id))
            .and_then(|run| run.session_id.clone())
    });
    let mut task = previous_task.clone();
    task.title = format!(
        "Workflow {} · {} · correction {}",
        run.run_id, step_id, correction_attempt
    );
    task.description = format!(
        "{}\n\nThe previous result did not satisfy the required schema. \
         Correct the result and return it again:\n{}",
        previous_task.description, correction_prompt
    );
    task.status = crate::InboxTaskStatus::Queued;
    task.updated_at = now.to_string();
    task.session_id = session_id;
    task.current_run_id = None;
    task.summary = None;
    task.error = None;
    task.metadata.insert(
        "workflow_input_revision".to_string(),
        Value::from(run.revision.saturating_add(1)),
    );
    task.metadata.insert(
        "workflow_correction_attempt".to_string(),
        Value::from(correction_attempt),
    );
    inbox.apply_command(
        workflow,
        TaskInboxCommand::QueueTaskCorrectionProjection {
            task,
            updated_at: now.to_string(),
        },
    )?;
    Ok(())
}

fn workflow_task_result(inbox: &TaskInboxSnapshot, task: &crate::InboxTaskRecord) -> String {
    if let Some(summary) = task.summary.as_deref()
        && !summary.trim().is_empty()
    {
        return summary.to_string();
    }
    task.current_run_id
        .as_deref()
        .and_then(|run_id| {
            inbox
                .events
                .iter()
                .rev()
                .find(|event| {
                    event.run_id == run_id && event.kind == crate::InboxEventKind::Assistant
                })
                .map(|event| event.text.clone())
        })
        .unwrap_or_else(|| "{}".to_string())
}

fn workflow_artifact_references(
    inbox: &TaskInboxSnapshot,
    task_id: &str,
    run_id: Option<&str>,
) -> Vec<crate::ArtifactReference> {
    let Some(run_id) = run_id else {
        return Vec::new();
    };
    inbox
        .artifacts
        .iter()
        .filter(|artifact| artifact.task_id == task_id && artifact.run_id == run_id)
        .filter_map(|artifact| {
            let raw_sha = artifact.sha256.as_deref()?;
            let sha256 = if raw_sha.starts_with("sha256:") {
                raw_sha.to_string()
            } else {
                format!("sha256:{raw_sha}")
            };
            let uri = artifact.path.as_deref().map_or_else(
                || format!("ianvs-task-artifact:{}", artifact.id),
                |path| {
                    if path.contains("://") {
                        path.to_string()
                    } else {
                        format!("file://{path}")
                    }
                },
            );
            let media_type = match artifact.kind {
                crate::InboxArtifactKind::GitDiff | crate::InboxArtifactKind::Patch => {
                    "text/x-diff"
                }
                crate::InboxArtifactKind::GitStatus
                | crate::InboxArtifactKind::TestLog
                | crate::InboxArtifactKind::AgentSummary => "text/plain",
                crate::InboxArtifactKind::File | crate::InboxArtifactKind::OutboxFile => {
                    "application/octet-stream"
                }
            };
            let reference = crate::ArtifactReference {
                artifact_id: artifact.id.clone(),
                media_type: media_type.to_string(),
                uri,
                sha256,
                byte_length: artifact.size_bytes.unwrap_or(0),
            };
            reference.validate().ok().map(|()| reference)
        })
        .collect()
}

fn wait_deadline_reached(
    run: &crate::WorkflowRun,
    step_id: &str,
    now: &str,
) -> Result<bool, DurableWorkflowError> {
    let wake_at = run
        .step_runs
        .iter()
        .find(|step| step.step_id == step_id)
        .and_then(|step| step.input.as_ref())
        .and_then(Value::as_object)
        .and_then(|input| input.get("_ianvsWakeAt"))
        .and_then(Value::as_str)
        .ok_or(crate::WorkflowIrError::InvalidStepState)?;
    let wake_at = DateTime::parse_from_rfc3339(wake_at)
        .map_err(|_| crate::WorkflowIrError::InvalidStepState)?;
    let now =
        DateTime::parse_from_rfc3339(now).map_err(|_| crate::WorkflowIrError::InvalidStepState)?;
    Ok(now >= wake_at)
}

fn task_inbox_command_run_id(
    command: &TaskInboxCommand,
) -> Result<Option<&str>, crate::ExecutionError> {
    let run_id = match command {
        TaskInboxCommand::TransitionRun { run_id, .. }
        | TaskInboxCommand::ReplaceArtifacts { run_id, .. } => Some(run_id.as_str()),
        TaskInboxCommand::TransitionRunProjection { run, .. }
        | TaskInboxCommand::FailRunAndQueueRetryProjection { run, .. }
        | TaskInboxCommand::UpdateRunProjection { run, .. } => Some(run.id.as_str()),
        TaskInboxCommand::CancelTaskProjection { run, .. } => {
            run.as_ref().map(|run| run.id.as_str())
        }
        TaskInboxCommand::UpdateTaskProjection { task, .. }
        | TaskInboxCommand::QueueTaskProjection { task, .. }
        | TaskInboxCommand::QueueTaskCorrectionProjection { task, .. } => {
            task.current_run_id.as_deref()
        }
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
        TaskInboxCommand::QueueTaskCorrectionProjection { .. } => {
            "task_inbox.queue_task_correction_projection"
        }
        TaskInboxCommand::DispatchRunProjection { .. } => "task_inbox.dispatch_run_projection",
        TaskInboxCommand::TransitionRunProjection { .. } => "task_inbox.transition_run_projection",
        TaskInboxCommand::FailRunAndQueueRetryProjection { .. } => {
            "task_inbox.fail_run_and_queue_retry_projection"
        }
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
