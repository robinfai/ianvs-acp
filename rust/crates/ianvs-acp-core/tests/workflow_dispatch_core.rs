use std::collections::{BTreeMap, BTreeSet};
use std::fs;

use ianvs_acp_core::{
    BudgetPolicy, DurableWorkflow, InboxRunRecord, InputBinding, PlanVersion, ResultSchema,
    SemanticCapabilityProfile, StepDefinition, StepKind, StepRunStatus, TASK_INBOX_SCHEMA,
    TaskInboxCommand, TaskInboxRunTransition, TaskInboxSnapshot, WORKFLOW_IR_SCHEMA_VERSION,
    WorkflowDefinition, WorkflowRun, WorkflowRunStatus,
};
use serde_json::json;

#[test]
#[allow(clippy::too_many_lines)]
fn ready_agent_step_is_atomically_enqueued_and_terminal_task_advances_dag() {
    let directory = unique_temp_dir("workflow-dispatch");
    let workspace = directory.join("workspace");
    fs::create_dir(&workspace).unwrap();
    let database = directory.join("workflow.sqlite3");
    let mut authority = active_authority(&database);
    let definition = definition(
        &workspace,
        vec![
            local_step("checkpoint", StepKind::Checkpoint, vec![]),
            agent_step("write", vec!["checkpoint"], 0),
            local_step("finish", StepKind::Checkpoint, vec!["write"]),
        ],
    );
    authority.register_workflow_definition(&definition).unwrap();
    authority
        .create_workflow_run(
            &WorkflowRun::new("workflow-run".to_string(), &definition, timestamp(0)).unwrap(),
        )
        .unwrap();

    let reconciled = authority
        .reconcile_workflow_tasks(&agent_names(), &timestamp(1))
        .unwrap();
    assert_eq!(reconciled.completed_steps, 1);
    assert_eq!(reconciled.enqueued_tasks, 1);
    let snapshot = authority.current_task_inbox().unwrap().clone();
    let task = snapshot.tasks.single();
    assert_eq!(task.status, ianvs_acp_core::InboxTaskStatus::Queued);
    assert_eq!(task.metadata["workflow_run_id"], json!("workflow-run"));
    let binding = authority
        .workflow_step_task_bindings("workflow-run")
        .unwrap()
        .into_iter()
        .next()
        .unwrap();
    assert_eq!(binding.task_id, task.id);
    assert!(binding.task_run_id.is_none());
    let run = authority.workflow_run("workflow-run").unwrap().unwrap();
    assert_eq!(run.step_runs[0].status, StepRunStatus::Succeeded);
    assert_eq!(run.step_runs[1].status, StepRunStatus::Running);

    let run_id = "task-run-1";
    authority
        .apply_task_inbox(TaskInboxCommand::DispatchRun {
            run: InboxRunRecord {
                id: run_id.to_string(),
                task_id: task.id.clone(),
                attempt: 1,
                status: ianvs_acp_core::InboxTaskStatus::Dispatched,
                started_at: timestamp(2),
                ended_at: None,
                session_id: None,
                prompt_snapshot: None,
                model: None,
                error: None,
            },
            updated_at: timestamp(2),
        })
        .unwrap();
    authority
        .apply_task_inbox(TaskInboxCommand::TransitionRun {
            run_id: run_id.to_string(),
            transition: TaskInboxRunTransition::Start,
            updated_at: timestamp(3),
            ended_at: None,
            error: None,
        })
        .unwrap();
    let mut task = authority.current_task_inbox().unwrap().tasks[0].clone();
    task.summary = Some(r#"{"summary":"done"}"#.to_string());
    authority
        .apply_task_inbox(TaskInboxCommand::UpdateTaskProjection {
            task,
            updated_at: timestamp(4),
        })
        .unwrap();
    authority
        .apply_task_inbox(TaskInboxCommand::TransitionRun {
            run_id: run_id.to_string(),
            transition: TaskInboxRunTransition::CollectArtifacts,
            updated_at: timestamp(5),
            ended_at: None,
            error: None,
        })
        .unwrap();
    authority
        .apply_task_inbox(TaskInboxCommand::TransitionRun {
            run_id: run_id.to_string(),
            transition: TaskInboxRunTransition::Complete,
            updated_at: timestamp(6),
            ended_at: Some(timestamp(6)),
            error: None,
        })
        .unwrap();

    let reconciled = authority
        .reconcile_workflow_tasks(&agent_names(), &timestamp(7))
        .unwrap();
    assert_eq!(reconciled.completed_steps, 2);
    let completed = authority.workflow_run("workflow-run").unwrap().unwrap();
    assert_eq!(completed.status, WorkflowRunStatus::Succeeded);
    assert!(
        completed
            .step_runs
            .iter()
            .all(|step| step.status == StepRunStatus::Succeeded)
    );
    let binding = authority
        .workflow_step_task_bindings("workflow-run")
        .unwrap()
        .into_iter()
        .next()
        .unwrap();
    assert_eq!(binding.task_run_id.as_deref(), Some(run_id));

    drop(authority);
    let reopened = DurableWorkflow::open(&database).unwrap();
    assert_eq!(
        reopened
            .workflow_run("workflow-run")
            .unwrap()
            .unwrap()
            .status,
        WorkflowRunStatus::Succeeded
    );
    let reopened_binding = reopened
        .workflow_step_task_bindings("workflow-run")
        .unwrap()
        .into_iter()
        .next()
        .unwrap();
    assert_eq!(reopened_binding.task_run_id.as_deref(), Some(run_id));
    fs::remove_dir_all(directory).unwrap();
}

#[test]
fn failed_bound_task_retries_once_then_fails_the_workflow() {
    let directory = unique_temp_dir("workflow-dispatch-retry");
    let workspace = directory.join("workspace");
    fs::create_dir(&workspace).unwrap();
    let database = directory.join("workflow.sqlite3");
    let mut authority = active_authority(&database);
    let definition = definition(&workspace, vec![agent_step("retry", vec![], 1)]);
    authority.register_workflow_definition(&definition).unwrap();
    authority
        .create_workflow_run(
            &WorkflowRun::new("retry-run".to_string(), &definition, timestamp(0)).unwrap(),
        )
        .unwrap();
    authority
        .reconcile_workflow_tasks(&agent_names(), &timestamp(1))
        .unwrap();
    let task_id = authority.current_task_inbox().unwrap().tasks[0].id.clone();

    fail_task(&mut authority, &task_id, "task-attempt-1", 1, 2);
    let retried = authority
        .reconcile_workflow_tasks(&agent_names(), &timestamp(5))
        .unwrap();
    assert_eq!(retried.retried_tasks, 1);
    let run = authority.workflow_run("retry-run").unwrap().unwrap();
    assert_eq!(run.step_runs[0].status, StepRunStatus::Running);
    assert_eq!(run.step_runs[0].attempt, 2);
    assert!(run.step_runs[0].ended_at.is_none());
    assert!(run.step_runs[0].error.is_none());
    assert_eq!(
        authority.current_task_inbox().unwrap().tasks[0].status,
        ianvs_acp_core::InboxTaskStatus::Queued
    );

    fail_task(&mut authority, &task_id, "task-attempt-2", 2, 6);
    let exhausted = authority
        .reconcile_workflow_tasks(&agent_names(), &timestamp(9))
        .unwrap();
    assert_eq!(exhausted.failed_steps, 1);
    assert_eq!(exhausted.retried_tasks, 0);
    let run = authority.workflow_run("retry-run").unwrap().unwrap();
    assert_eq!(run.status, WorkflowRunStatus::Failed);
    assert_eq!(run.step_runs[0].status, StepRunStatus::Failed);
    fs::remove_dir_all(directory).unwrap();
}

#[test]
fn invalid_structured_result_automatically_reuses_session_for_correction() {
    let directory = unique_temp_dir("workflow-structured-correction");
    let workspace = directory.join("workspace");
    fs::create_dir(&workspace).unwrap();
    let database = directory.join("workflow.sqlite3");
    let mut authority = active_authority(&database);
    let mut step = agent_step("structured", vec![], 0);
    step.result_schema_id = Some("result".to_string());
    let mut definition = definition(&workspace, vec![step]);
    definition.result_schemas.push(ResultSchema {
        schema_id: "result".to_string(),
        schema: json!({
            "type": "object",
            "properties": {"summary": {"type": "string"}},
            "required": ["summary"],
            "additionalProperties": false
        }),
    });
    authority.register_workflow_definition(&definition).unwrap();
    authority
        .create_workflow_run(
            &WorkflowRun::new("structured-run".to_string(), &definition, timestamp(0)).unwrap(),
        )
        .unwrap();
    authority
        .reconcile_workflow_tasks(&agent_names(), &timestamp(1))
        .unwrap();
    let first_task_id = authority.current_task_inbox().unwrap().tasks[0].id.clone();
    finish_task(
        &mut authority,
        &first_task_id,
        "structured-task-1",
        "not valid JSON",
        "session-structured",
        2,
    );

    let correction = authority
        .reconcile_workflow_tasks(&agent_names(), &timestamp(6))
        .unwrap();
    assert_eq!(correction.retried_tasks, 1);
    let binding = authority
        .workflow_step_task_bindings("structured-run")
        .unwrap()
        .into_iter()
        .next()
        .unwrap();
    assert_eq!(binding.task_id, first_task_id);
    assert!(binding.task_run_id.is_none());
    let correction_task = authority
        .current_task_inbox()
        .unwrap()
        .tasks
        .iter()
        .find(|task| task.id == binding.task_id)
        .unwrap();
    assert_eq!(
        correction_task.status,
        ianvs_acp_core::InboxTaskStatus::Queued
    );
    assert_eq!(
        correction_task.session_id.as_deref(),
        Some("session-structured")
    );
    assert!(
        correction_task
            .description
            .contains("did not satisfy the required schema")
    );
    let correction_task_id = correction_task.id.clone();
    finish_task(
        &mut authority,
        &correction_task_id,
        "structured-task-2",
        r#"{"summary":"corrected"}"#,
        "session-structured",
        7,
    );

    authority
        .reconcile_workflow_tasks(&agent_names(), &timestamp(11))
        .unwrap();
    let completed = authority.workflow_run("structured-run").unwrap().unwrap();
    assert_eq!(completed.status, WorkflowRunStatus::Succeeded);
    assert_eq!(completed.usage.invocations, 2);
    assert_eq!(
        completed.step_runs[0]
            .structured_result
            .as_ref()
            .unwrap()
            .attempts
            .len(),
        2
    );
    assert_eq!(
        completed.step_runs[0].output,
        Some(json!({"summary": "corrected"}))
    );
    fs::remove_dir_all(directory).unwrap();
}

#[test]
fn wait_and_approval_steps_are_resolved_without_agent_tasks() {
    let directory = unique_temp_dir("workflow-local-steps");
    let workspace = directory.join("workspace");
    fs::create_dir(&workspace).unwrap();
    let database = directory.join("workflow.sqlite3");
    let mut authority = active_authority(&database);
    let wait_definition = definition(
        &workspace,
        vec![
            local_step(
                "wait",
                StepKind::Wait {
                    timeout_seconds: 10,
                    signal_name: Some("continue".to_string()),
                },
                vec![],
            ),
            local_step("after", StepKind::Checkpoint, vec!["wait"]),
        ],
    );
    authority
        .register_workflow_definition(&wait_definition)
        .unwrap();
    authority
        .create_workflow_run(
            &WorkflowRun::new("wait-run".to_string(), &wait_definition, timestamp(0)).unwrap(),
        )
        .unwrap();
    authority
        .reconcile_workflow_tasks(&BTreeSet::new(), &timestamp(1))
        .unwrap();
    assert_eq!(
        authority.workflow_run("wait-run").unwrap().unwrap().status,
        WorkflowRunStatus::Waiting
    );
    authority
        .signal_workflow_wait_step(
            "wait-run",
            "wait",
            "continue",
            json!({"source": "test"}),
            &timestamp(2),
        )
        .unwrap();
    authority
        .reconcile_workflow_tasks(&BTreeSet::new(), &timestamp(3))
        .unwrap();
    assert_eq!(
        authority.workflow_run("wait-run").unwrap().unwrap().status,
        WorkflowRunStatus::Succeeded
    );

    let approval_definition = definition(
        &workspace,
        vec![local_step(
            "approve",
            StepKind::Approval {
                approval_profile: "human".to_string(),
            },
            vec![],
        )],
    );
    authority
        .register_workflow_definition(&approval_definition)
        .unwrap();
    authority
        .create_workflow_run(
            &WorkflowRun::new(
                "approval-run".to_string(),
                &approval_definition,
                timestamp(4),
            )
            .unwrap(),
        )
        .unwrap();
    authority
        .reconcile_workflow_tasks(&BTreeSet::new(), &timestamp(5))
        .unwrap();
    assert_eq!(
        authority
            .workflow_run("approval-run")
            .unwrap()
            .unwrap()
            .status,
        WorkflowRunStatus::NeedsHumanReview
    );
    let approved = authority
        .resolve_workflow_approval_step("approval-run", "approve", true, &timestamp(6))
        .unwrap();
    assert_eq!(approved.status, WorkflowRunStatus::Succeeded);
    assert!(authority.current_task_inbox().unwrap().tasks.is_empty());
    fs::remove_dir_all(directory).unwrap();
}

fn active_authority(path: &std::path::Path) -> DurableWorkflow {
    let mut authority = DurableWorkflow::open(path).unwrap();
    authority
        .stage_task_inbox_import(
            &TaskInboxSnapshot {
                schema: TASK_INBOX_SCHEMA.to_string(),
                updated_at: timestamp(0),
                tasks: Vec::new(),
                runs: Vec::new(),
                events: Vec::new(),
                artifacts: Vec::new(),
                approvals: Vec::new(),
                resources: Vec::new(),
            },
            "sha256:workflow-dispatch-test",
        )
        .unwrap();
    authority.materialize_task_inbox().unwrap();
    authority.activate_task_inbox().unwrap();
    authority
}

fn definition(workspace: &std::path::Path, mut steps: Vec<StepDefinition>) -> WorkflowDefinition {
    for step in &mut steps {
        if matches!(step.kind, StepKind::Agent { .. }) {
            step.inputs.insert(
                "workspacePath".to_string(),
                InputBinding::Literal {
                    value: json!(workspace),
                },
            );
        }
    }
    WorkflowDefinition {
        schema_version: WORKFLOW_IR_SCHEMA_VERSION,
        definition_id: format!(
            "definition-{}",
            steps.first().map_or("empty", |step| step.step_id.as_str())
        ),
        version: 1,
        name: "Dispatch test".to_string(),
        created_at: timestamp(0),
        provenance: "test".to_string(),
        budget_policy: BudgetPolicy {
            max_plan_nodes: 16,
            max_fan_out: 4,
            max_depth: 8,
            max_replans: 1,
            max_invocations: 16,
            max_concurrent_agents: 2,
            token_budget: 100_000,
            cost_budget_micros: 1_000_000,
        },
        capability_profiles: vec![SemanticCapabilityProfile {
            profile_id: "fixture".to_string(),
            summary: "Fixture agent".to_string(),
            capabilities: ["write".to_string()].into_iter().collect(),
            max_parallelism: 1,
        }],
        result_schemas: Vec::new(),
        initial_plan: PlanVersion {
            version: 1,
            reason: "initial".to_string(),
            provenance: "test".to_string(),
            created_at: timestamp(0),
            steps,
        },
    }
}

fn agent_step(id: &str, dependencies: Vec<&str>, retry_limit: u32) -> StepDefinition {
    StepDefinition {
        step_id: id.to_string(),
        kind: StepKind::Agent {
            capability_profile: "fixture".to_string(),
            prompt_template: "Complete the workflow Step.".to_string(),
        },
        depends_on: dependencies.into_iter().map(str::to_string).collect(),
        inputs: BTreeMap::new(),
        result_schema_id: None,
        retry_limit,
        permission_profile: None,
    }
}

fn local_step(id: &str, kind: StepKind, dependencies: Vec<&str>) -> StepDefinition {
    StepDefinition {
        step_id: id.to_string(),
        kind,
        depends_on: dependencies.into_iter().map(str::to_string).collect(),
        inputs: BTreeMap::new(),
        result_schema_id: None,
        retry_limit: 0,
        permission_profile: None,
    }
}

fn fail_task(
    authority: &mut DurableWorkflow,
    task_id: &str,
    task_run_id: &str,
    attempt: u32,
    second: u32,
) {
    authority
        .apply_task_inbox(TaskInboxCommand::DispatchRun {
            run: InboxRunRecord {
                id: task_run_id.to_string(),
                task_id: task_id.to_string(),
                attempt,
                status: ianvs_acp_core::InboxTaskStatus::Dispatched,
                started_at: timestamp(second),
                ended_at: None,
                session_id: None,
                prompt_snapshot: None,
                model: None,
                error: None,
            },
            updated_at: timestamp(second),
        })
        .unwrap();
    authority
        .apply_task_inbox(TaskInboxCommand::TransitionRun {
            run_id: task_run_id.to_string(),
            transition: TaskInboxRunTransition::Start,
            updated_at: timestamp(second + 1),
            ended_at: None,
            error: None,
        })
        .unwrap();
    authority
        .apply_task_inbox(TaskInboxCommand::TransitionRun {
            run_id: task_run_id.to_string(),
            transition: TaskInboxRunTransition::Fail,
            updated_at: timestamp(second + 2),
            ended_at: Some(timestamp(second + 2)),
            error: Some("fixture failure".to_string()),
        })
        .unwrap();
}

fn finish_task(
    authority: &mut DurableWorkflow,
    task_id: &str,
    task_run_id: &str,
    summary: &str,
    session_id: &str,
    second: u32,
) {
    let attempt = authority
        .current_task_inbox()
        .unwrap()
        .runs
        .iter()
        .filter(|run| run.task_id == task_id)
        .map(|run| run.attempt)
        .max()
        .unwrap_or(0)
        .saturating_add(1);
    authority
        .apply_task_inbox(TaskInboxCommand::DispatchRun {
            run: InboxRunRecord {
                id: task_run_id.to_string(),
                task_id: task_id.to_string(),
                attempt,
                status: ianvs_acp_core::InboxTaskStatus::Dispatched,
                started_at: timestamp(second),
                ended_at: None,
                session_id: None,
                prompt_snapshot: None,
                model: None,
                error: None,
            },
            updated_at: timestamp(second),
        })
        .unwrap();
    authority
        .apply_task_inbox(TaskInboxCommand::TransitionRun {
            run_id: task_run_id.to_string(),
            transition: TaskInboxRunTransition::Start,
            updated_at: timestamp(second + 1),
            ended_at: None,
            error: None,
        })
        .unwrap();
    let mut task = authority
        .current_task_inbox()
        .unwrap()
        .tasks
        .iter()
        .find(|task| task.id == task_id)
        .unwrap()
        .clone();
    task.session_id = Some(session_id.to_string());
    task.summary = Some(summary.to_string());
    authority
        .apply_task_inbox(TaskInboxCommand::UpdateTaskProjection {
            task,
            updated_at: timestamp(second + 2),
        })
        .unwrap();
    authority
        .apply_task_inbox(TaskInboxCommand::TransitionRun {
            run_id: task_run_id.to_string(),
            transition: TaskInboxRunTransition::CollectArtifacts,
            updated_at: timestamp(second + 3),
            ended_at: None,
            error: None,
        })
        .unwrap();
    authority
        .apply_task_inbox(TaskInboxCommand::TransitionRun {
            run_id: task_run_id.to_string(),
            transition: TaskInboxRunTransition::Complete,
            updated_at: timestamp(second + 4),
            ended_at: Some(timestamp(second + 4)),
            error: None,
        })
        .unwrap();
}

fn agent_names() -> BTreeSet<String> {
    ["fixture".to_string()].into_iter().collect()
}

fn timestamp(second: u32) -> String {
    format!("2026-07-22T10:00:{second:02}.000Z")
}

trait Single<T> {
    fn single(&self) -> &T;
}

impl<T> Single<T> for [T] {
    fn single(&self) -> &T {
        assert_eq!(self.len(), 1);
        &self[0]
    }
}

fn unique_temp_dir(label: &str) -> std::path::PathBuf {
    let path = std::env::temp_dir().join(format!(
        "ianvs-{label}-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    fs::create_dir(&path).unwrap();
    path
}
