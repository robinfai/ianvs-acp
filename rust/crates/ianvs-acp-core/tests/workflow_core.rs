use std::fs;
use std::time::Duration;

use ianvs_acp_core::{
    DurableWorkflow, DurableWorkflowError, ExecutionGateError, RecoveryState, RetryPolicy,
    RunStatus, SqliteWorkflowStore, TaskFailureReason, TaskInboxCommand, TaskInboxMutationError,
    TaskInboxSnapshot, TaskStatus, WorkflowCommand, WorkflowMigrationPhase, WorkflowSnapshot,
    WorkflowStateError, WorkflowStateMachine, WorkflowStoreError,
};

#[test]
fn task_run_transitions_hold_and_release_workspace_lease() {
    let workspace = unique_temp_dir("workflow");
    let mut workflow = WorkflowStateMachine::new();
    workflow
        .create_task("task-1", &workspace, "fixture")
        .unwrap();
    workflow.queue_task("task-1").unwrap();
    workflow.dispatch_task("task-1", "run-1").unwrap();
    assert_eq!(
        workflow.workspace_owner(workspace.canonicalize().unwrap()),
        Some("task-1".to_string())
    );
    workflow.start_run("run-1").unwrap();
    workflow.wait_for_permission("run-1").unwrap();
    assert_eq!(
        workflow.task("task-1").unwrap().status,
        TaskStatus::BlockedOnPermission
    );
    workflow.resume_run("run-1").unwrap();
    workflow.collect_artifacts("run-1").unwrap();
    workflow.require_human_review("run-1").unwrap();
    workflow.complete_run("run-1").unwrap();
    assert_eq!(workflow.run("run-1").unwrap().status, RunStatus::Succeeded);
    assert_eq!(workflow.task("task-1").unwrap().status, TaskStatus::Done);
    assert!(
        workflow
            .workspace_owner(workspace.canonicalize().unwrap())
            .is_none()
    );
    fs::remove_dir_all(workspace).unwrap();
}

#[test]
fn workflow_serializes_mutation_by_canonical_workspace() {
    let workspace = unique_temp_dir("workflow-gate");
    let mut workflow = WorkflowStateMachine::new();
    workflow
        .create_task("task-1", &workspace, "fixture")
        .unwrap();
    workflow
        .create_task("task-2", &workspace, "fixture")
        .unwrap();
    workflow.queue_task("task-1").unwrap();
    workflow.queue_task("task-2").unwrap();
    workflow.dispatch_task("task-1", "run-1").unwrap();
    assert!(matches!(
        workflow.dispatch_task("task-2", "run-2"),
        Err(WorkflowStateError::Gate(ExecutionGateError::Busy { owner }))
            if owner == "task-1"
    ));
    workflow.cancel_task("task-1").unwrap();
    workflow.dispatch_task("task-2", "run-2").unwrap();
    assert_eq!(workflow.task("task-2").unwrap().attempt, 1);
    fs::remove_dir_all(workspace).unwrap();
}

#[test]
fn stale_or_illegal_run_transitions_are_rejected() {
    let workspace = unique_temp_dir("workflow-transition");
    let mut workflow = WorkflowStateMachine::new();
    workflow
        .create_task("task-1", &workspace, "fixture")
        .unwrap();
    workflow.queue_task("task-1").unwrap();
    workflow.dispatch_task("task-1", "run-1").unwrap();
    assert!(matches!(
        workflow.wait_for_permission("run-1"),
        Err(WorkflowStateError::RunTransition { .. })
    ));
    workflow.start_run("run-1").unwrap();
    workflow.fail_run("run-1").unwrap();
    workflow.queue_task("task-1").unwrap();
    workflow.dispatch_task("task-1", "run-2").unwrap();
    assert!(matches!(
        workflow.start_run("run-1"),
        Err(WorkflowStateError::StaleRun { .. })
    ));
    assert_eq!(workflow.task("task-1").unwrap().attempt, 2);
    fs::remove_dir_all(workspace).unwrap();
}

#[test]
fn retry_policy_matches_runtime_failure_categories() {
    let policy = RetryPolicy {
        base_delay: Duration::from_secs(2),
        ..RetryPolicy::default()
    };
    assert!(policy.should_retry(TaskFailureReason::RuntimeOffline, 2));
    assert!(!policy.should_retry(TaskFailureReason::RuntimeOffline, 3));
    assert!(policy.should_retry(TaskFailureReason::Timeout, 1));
    assert!(!policy.should_retry(TaskFailureReason::PermissionDenied, 1));
    assert_eq!(policy.delay_for_attempt(3), Duration::from_secs(8));
}

#[test]
fn sqlite_snapshot_round_trip_restores_authoritative_state() {
    let workspace = unique_temp_dir("workflow-sqlite-round-trip");
    let mut workflow = WorkflowStateMachine::new();
    workflow
        .create_task("task-1", &workspace, "fixture")
        .unwrap();
    workflow.queue_task("task-1").unwrap();
    workflow.dispatch_task("task-1", "run-1").unwrap();
    workflow.start_run("run-1").unwrap();

    let mut store = SqliteWorkflowStore::open_in_memory().unwrap();
    store.save_snapshot(&workflow.snapshot()).unwrap();
    let restored = WorkflowStateMachine::restore(store.load_snapshot().unwrap()).unwrap();
    assert_eq!(restored.task("task-1").unwrap().status, TaskStatus::Running);
    assert_eq!(restored.run("run-1").unwrap().status, RunStatus::Running);
    assert_eq!(
        restored.workspace_owner(workspace.canonicalize().unwrap()),
        Some("task-1".to_string())
    );
    fs::remove_dir_all(workspace).unwrap();
}

#[test]
fn sqlite_recovery_requeues_safe_unstarted_work_but_preserves_user_input() {
    let first_workspace = unique_temp_dir("workflow-sqlite-live");
    let second_workspace = unique_temp_dir("workflow-sqlite-user");
    let mut workflow = WorkflowStateMachine::new();
    workflow
        .create_task("live", &first_workspace, "fixture")
        .unwrap();
    workflow.queue_task("live").unwrap();
    workflow.dispatch_task("live", "run-live").unwrap();
    workflow.start_run("run-live").unwrap();
    workflow
        .create_task("user", &second_workspace, "fixture")
        .unwrap();
    workflow.queue_task("user").unwrap();
    workflow.dispatch_task("user", "run-user").unwrap();
    workflow.start_run("run-user").unwrap();
    workflow.wait_for_user_input("run-user").unwrap();

    let mut store = SqliteWorkflowStore::open_in_memory().unwrap();
    store.save_snapshot(&workflow.snapshot()).unwrap();
    let report = store.recover_interrupted().unwrap();
    assert_eq!(report.runs.len(), 1);
    assert_eq!(report.runs[0].task_id, "live");
    assert_eq!(report.runs[0].recovery_state, RecoveryState::Requeued);
    let snapshot = store.load_snapshot().unwrap();
    let live = snapshot
        .tasks
        .iter()
        .find(|task| task.id == "live")
        .unwrap();
    let user = snapshot
        .tasks
        .iter()
        .find(|task| task.id == "user")
        .unwrap();
    assert_eq!(live.status, TaskStatus::Queued);
    assert_eq!(user.status, TaskStatus::BlockedOnUserInput);
    assert_eq!(
        snapshot
            .runs
            .iter()
            .find(|run| run.id == "run-live")
            .unwrap()
            .status,
        RunStatus::Failed
    );
    fs::remove_dir_all(first_workspace).unwrap();
    fs::remove_dir_all(second_workspace).unwrap();
}

#[test]
fn durable_workflow_commits_commands_and_recovers_on_reopen() {
    let directory = unique_temp_dir("durable-workflow");
    let workspace = directory.join("workspace");
    fs::create_dir(&workspace).unwrap();
    let database = directory.join("workflow.sqlite3");
    {
        let mut workflow = DurableWorkflow::open(&database).unwrap();
        workflow
            .apply(WorkflowCommand::CreateTask {
                task_id: "task-1".to_string(),
                workspace_path: workspace.display().to_string(),
                agent_name: "fixture".to_string(),
            })
            .unwrap();
        workflow
            .apply(WorkflowCommand::QueueTask {
                task_id: "task-1".to_string(),
            })
            .unwrap();
        workflow
            .apply(WorkflowCommand::DispatchTask {
                task_id: "task-1".to_string(),
                run_id: "run-1".to_string(),
            })
            .unwrap();
        let projection = workflow
            .apply(WorkflowCommand::StartRun {
                run_id: "run-1".to_string(),
            })
            .unwrap();
        assert_eq!(projection.revision, 4);
        assert_eq!(projection.snapshot.tasks[0].status, TaskStatus::Running);
    }

    let reopened = DurableWorkflow::open(&database).unwrap();
    let projection = reopened.open_projection();
    assert_eq!(projection.recovery.runs.len(), 1);
    assert_eq!(
        projection.recovery.runs[0].recovery_state,
        RecoveryState::Requeued
    );
    assert_eq!(projection.revision, 5);
    assert_eq!(projection.snapshot.tasks[0].status, TaskStatus::Queued);
    assert_eq!(projection.snapshot.runs[0].status, RunStatus::Failed);
    fs::remove_dir_all(directory).unwrap();
}

#[test]
fn sqlite_revision_compare_and_swap_rejects_lost_updates() {
    let directory = unique_temp_dir("workflow-sqlite-cas");
    let database = directory.join("workflow.sqlite3");
    let mut first = SqliteWorkflowStore::open(&database).unwrap();
    let mut stale = SqliteWorkflowStore::open(&database).unwrap();
    first.save_snapshot(&WorkflowSnapshot::default()).unwrap();
    assert!(matches!(
        stale.save_snapshot_if_revision(&WorkflowSnapshot::default(), 0),
        Err(WorkflowStoreError::Conflict {
            expected: 0,
            actual: 1
        })
    ));
    fs::remove_dir_all(directory).unwrap();
}

#[test]
#[allow(clippy::too_many_lines)]
fn full_task_inbox_migrates_to_atomic_rust_owned_mutations_and_recovery() {
    let directory = unique_temp_dir("workflow-task-inbox-stage");
    let workspace = directory.join("workspace");
    fs::create_dir(&workspace).unwrap();
    let second_workspace = directory.join("workspace-2");
    fs::create_dir(&second_workspace).unwrap();
    let workspace = workspace.canonicalize().unwrap();
    let second_workspace = second_workspace.canonicalize().unwrap();
    let database = directory.join("workflow.sqlite3");
    let source: TaskInboxSnapshot = serde_json::from_value(serde_json::json!({
        "schema": "ianvs-acp.task-inbox.v1",
        "updated_at": "2026-07-17T08:00:00.000Z",
        "tasks": [{
            "id": "task-1",
            "title": "Imported task",
            "description": "Preserve this payload",
            "workspace_path": workspace,
            "agent_name": "fixture",
            "status": "approved_for_export",
            "priority": "normal",
            "created_at": "2026-07-17T07:00:00.000Z",
            "updated_at": "2026-07-17T08:00:00.000Z",
            "metadata": {"nested": {"value": true}}
        }],
        "runs": [],
        "events": [],
        "artifacts": [],
        "approvals": [],
        "resources": []
    }))
    .unwrap();

    {
        let mut workflow = DurableWorkflow::open(&database).unwrap();
        let staged = workflow
            .stage_task_inbox_import(&source, "sha256:fixture")
            .unwrap();
        assert_eq!(staged.revision, 1);
        assert_eq!(staged.migration.phase, WorkflowMigrationPhase::Staged);
        assert_eq!(
            staged.snapshot.tasks[0].status,
            TaskStatus::NeedsHumanReview
        );
        assert_eq!(workflow.task_inbox_source().unwrap(), Some(source.clone()));
        let materialized = workflow.materialize_task_inbox().unwrap();
        assert_eq!(materialized.revision, 2);
        assert_eq!(materialized.migration.phase, WorkflowMigrationPhase::Ready);
        assert_eq!(
            materialized.task_inbox.tasks[0].status,
            ianvs_acp_core::InboxTaskStatus::NeedsHumanReview
        );
        assert_eq!(workflow.task_inbox_source().unwrap(), Some(source.clone()));
        assert!(matches!(
            workflow.apply(WorkflowCommand::CancelTask {
                task_id: "task-1".to_string()
            }),
            Err(DurableWorkflowError::Store(
                WorkflowStoreError::MigrationReady
            ))
        ));
        assert_eq!(workflow.projection().revision, 2);
        assert_eq!(
            workflow.projection().snapshot.tasks[0].status,
            TaskStatus::NeedsHumanReview
        );
        let activated = workflow.activate_task_inbox().unwrap();
        assert_eq!(activated.revision, 3);
        assert_eq!(activated.migration.phase, WorkflowMigrationPhase::Active);
        assert!(matches!(
            workflow.apply(WorkflowCommand::CancelTask {
                task_id: "task-1".to_string()
            }),
            Err(DurableWorkflowError::Store(
                WorkflowStoreError::MigrationActive
            ))
        ));
        workflow
            .apply_task_inbox(task_inbox_command(serde_json::json!({
                "operation": "cancel_task_projection",
                "task": {
                    "id": "task-1",
                    "title": "Imported task",
                    "description": "Preserve this payload",
                    "workspace_path": workspace,
                    "agent_name": "fixture",
                    "status": "cancelled",
                    "priority": "normal",
                    "created_at": "2026-07-17T07:00:00.000Z",
                    "updated_at": "2026-07-17T08:01:00.000Z",
                    "metadata": {"nested": {"value": true}}
                },
                "updatedAt": "2026-07-17T08:01:00.000Z"
            })))
            .unwrap();
        workflow
            .apply_task_inbox(task_inbox_command(serde_json::json!({
                "operation": "create_task",
                "task": {
                    "id": "task-2",
                    "title": "Rust-owned task",
                    "description": "Exercise the complete projection transaction.",
                    "workspace_path": second_workspace,
                    "agent_name": "fixture",
                    "status": "inbox",
                    "priority": "high",
                    "created_at": "2026-07-17T08:02:00.000Z",
                    "updated_at": "2026-07-17T08:02:00.000Z",
                    "metadata": {"owner": "rust"}
                }
            })))
            .unwrap();
        workflow
            .apply_task_inbox(task_inbox_command(serde_json::json!({
                "operation": "queue_task",
                "taskId": "task-2",
                "updatedAt": "2026-07-17T08:03:00.000Z"
            })))
            .unwrap();
        workflow
            .apply_task_inbox(task_inbox_command(serde_json::json!({
                "operation": "dispatch_run",
                "run": {
                    "id": "run-2",
                    "task_id": "task-2",
                    "attempt": 1,
                    "status": "dispatched",
                    "started_at": "2026-07-17T08:04:00.000Z",
                    "model": "fixture-model"
                },
                "updatedAt": "2026-07-17T08:04:00.000Z"
            })))
            .unwrap();
        workflow
            .apply_task_inbox(task_inbox_command(serde_json::json!({
                "operation": "transition_run",
                "runId": "run-2",
                "transition": "start",
                "updatedAt": "2026-07-17T08:05:00.000Z"
            })))
            .unwrap();
        workflow
            .apply_task_inbox(task_inbox_command(serde_json::json!({
                "operation": "append_events",
                "events": [{
                    "id": "event-2",
                    "task_id": "task-2",
                    "run_id": "run-2",
                    "kind": "assistant",
                    "text": "Working",
                    "created_at": "2026-07-17T08:06:00.000Z"
                }],
                "updatedAt": "2026-07-17T08:06:00.000Z"
            })))
            .unwrap();
        workflow
            .apply_task_inbox(task_inbox_command(serde_json::json!({
                "operation": "replace_artifacts",
                "taskId": "task-2",
                "runId": "run-2",
                "artifacts": [{
                    "id": "artifact-2",
                    "task_id": "task-2",
                    "run_id": "run-2",
                    "kind": "test_log",
                    "status": "candidate",
                    "title": "Test log",
                    "created_at": "2026-07-17T08:07:00.000Z",
                    "content_preview": "ok"
                }],
                "updatedAt": "2026-07-17T08:07:00.000Z"
            })))
            .unwrap();
        workflow
            .apply_task_inbox(task_inbox_command(serde_json::json!({
                "operation": "upsert_approval",
                "approval": {
                    "id": "approval-2",
                    "task_id": "task-2",
                    "run_id": "run-2",
                    "kind": "tool_permission",
                    "status": "pending",
                    "created_at": "2026-07-17T08:08:00.000Z",
                    "artifact_ids": ["artifact-2"]
                },
                "updatedAt": "2026-07-17T08:08:00.000Z"
            })))
            .unwrap();
        let projected = workflow
            .apply_task_inbox(task_inbox_command(serde_json::json!({
                "operation": "upsert_resource",
                "resource": {
                    "id": "resource-2",
                    "type": "local_directory",
                    "label": "Second workspace",
                    "ref": {"path": second_workspace},
                    "serial": true
                },
                "updatedAt": "2026-07-17T08:09:00.000Z"
            })))
            .unwrap();
        assert_eq!(projected.revision, 12);
        assert_eq!(projected.task_inbox.events.len(), 1);
        assert_eq!(projected.task_inbox.artifacts.len(), 1);
        assert_eq!(projected.task_inbox.approvals.len(), 1);
        assert_eq!(projected.task_inbox.resources.len(), 1);
        let mut invalid_task = projected
            .task_inbox
            .tasks
            .iter()
            .find(|task| task.id == "task-2")
            .unwrap()
            .clone();
        invalid_task.status = ianvs_acp_core::InboxTaskStatus::Done;
        assert!(matches!(
            workflow.apply_task_inbox(TaskInboxCommand::UpdateTaskProjection {
                task: invalid_task,
                updated_at: "2026-07-17T08:10:00.000Z".to_string(),
            }),
            Err(DurableWorkflowError::TaskInboxMutation(
                TaskInboxMutationError::AuthorityFieldMismatch
            ))
        ));
        assert_eq!(workflow.projection().revision, 12);
    }

    let reopened = DurableWorkflow::open(&database).unwrap();
    assert_eq!(
        reopened.open_projection().migration.phase,
        WorkflowMigrationPhase::Active
    );
    assert_eq!(reopened.open_projection().revision, 13);
    assert_eq!(reopened.open_projection().recovery.runs.len(), 1);
    assert_eq!(
        reopened.open_projection().recovery.runs[0].recovery_state,
        RecoveryState::ReviewRequired
    );
    assert_eq!(reopened.task_inbox_source().unwrap(), Some(source));
    assert_eq!(
        reopened.current_task_inbox().unwrap().tasks[0].status,
        ianvs_acp_core::InboxTaskStatus::Cancelled
    );
    let current = reopened.current_task_inbox().unwrap();
    assert_eq!(
        current
            .tasks
            .iter()
            .find(|task| task.id == "task-2")
            .unwrap()
            .status,
        ianvs_acp_core::InboxTaskStatus::NeedsHumanReview
    );
    assert_eq!(
        current
            .runs
            .iter()
            .find(|run| run.id == "run-2")
            .unwrap()
            .status,
        ianvs_acp_core::InboxTaskStatus::NeedsHumanReview
    );
    assert_eq!(current.events[0].id, "event-2");
    assert_eq!(current.artifacts[0].id, "artifact-2");
    assert_eq!(current.approvals[0].id, "approval-2");
    assert_eq!(current.resources[0].id, "resource-2");
    drop(reopened);
    fs::remove_dir_all(directory).unwrap();
}

#[test]
#[allow(clippy::too_many_lines)]
fn active_task_inbox_definition_edit_and_delete_are_atomic() {
    let directory = unique_temp_dir("workflow-task-inbox-definition");
    let first_workspace = directory.join("workspace-first");
    let second_workspace = directory.join("workspace-second");
    fs::create_dir(&first_workspace).unwrap();
    fs::create_dir(&second_workspace).unwrap();
    let first_workspace = first_workspace.canonicalize().unwrap();
    let second_workspace = second_workspace.canonicalize().unwrap();
    let database = directory.join("workflow.sqlite3");
    let source: TaskInboxSnapshot = serde_json::from_value(serde_json::json!({
        "schema": "ianvs-acp.task-inbox.v1",
        "updated_at": "2026-07-17T09:00:00.000Z",
        "tasks": [],
        "runs": [],
        "events": [],
        "artifacts": [],
        "approvals": [],
        "resources": []
    }))
    .unwrap();

    {
        let mut workflow = DurableWorkflow::open(&database).unwrap();
        workflow
            .stage_task_inbox_import(&source, "sha256:empty")
            .unwrap();
        workflow.materialize_task_inbox().unwrap();
        workflow.activate_task_inbox().unwrap();
        workflow
            .apply_task_inbox(task_inbox_command(serde_json::json!({
                "operation": "create_task",
                "task": {
                    "id": "task-edit",
                    "title": "Original title",
                    "description": "Original description",
                    "workspace_path": first_workspace,
                    "agent_name": "agent-a",
                    "status": "inbox",
                    "priority": "normal",
                    "created_at": "2026-07-17T09:01:00.000Z",
                    "updated_at": "2026-07-17T09:01:00.000Z"
                }
            })))
            .unwrap();
        let edited = workflow
            .apply_task_inbox(task_inbox_command(serde_json::json!({
                "operation": "update_task_definition",
                "task": {
                    "id": "task-edit",
                    "title": "Edited title",
                    "description": "Edited description",
                    "workspace_path": second_workspace,
                    "agent_name": "agent-b",
                    "status": "inbox",
                    "priority": "high",
                    "created_at": "2026-07-17T09:01:00.000Z",
                    "updated_at": "2026-07-17T09:02:00.000Z"
                },
                "updatedAt": "2026-07-17T09:02:00.000Z"
            })))
            .unwrap();
        assert_eq!(edited.task_inbox.tasks[0].title, "Edited title");
        assert_eq!(edited.task_inbox.tasks[0].agent_name, "agent-b");
        assert_eq!(
            edited.task_inbox.tasks[0].workspace_path,
            second_workspace
                .canonicalize()
                .unwrap()
                .display()
                .to_string()
        );
        workflow
            .apply_task_inbox(task_inbox_command(serde_json::json!({
                "operation": "queue_task_projection",
                "task": {
                    "id": "task-edit",
                    "title": "Edited title",
                    "description": "Edited description",
                    "workspace_path": second_workspace,
                    "agent_name": "agent-b",
                    "status": "queued",
                    "priority": "high",
                    "created_at": "2026-07-17T09:01:00.000Z",
                    "updated_at": "2026-07-17T09:03:00.000Z",
                    "summary": "Queued atomically"
                },
                "updatedAt": "2026-07-17T09:03:00.000Z"
            })))
            .unwrap();
        workflow
            .apply_task_inbox(task_inbox_command(serde_json::json!({
                "operation": "dispatch_run",
                "run": {
                    "id": "run-edit",
                    "task_id": "task-edit",
                    "attempt": 1,
                    "status": "dispatched",
                    "started_at": "2026-07-17T09:04:00.000Z"
                },
                "updatedAt": "2026-07-17T09:04:00.000Z"
            })))
            .unwrap();
        workflow
            .apply_task_inbox(task_inbox_command(serde_json::json!({
                "operation": "append_events",
                "events": [{
                    "id": "event-edit",
                    "task_id": "task-edit",
                    "run_id": "run-edit",
                    "kind": "system",
                    "text": "Dispatched",
                    "created_at": "2026-07-17T09:04:00.000Z"
                }],
                "updatedAt": "2026-07-17T09:04:00.000Z"
            })))
            .unwrap();
        let before_delete = workflow.projection().revision;
        assert!(matches!(
            workflow.apply_task_inbox(task_inbox_command(serde_json::json!({
                "operation": "delete_task",
                "taskId": "task-edit",
                "updatedAt": "2026-07-17T09:05:00.000Z"
            }))),
            Err(DurableWorkflowError::TaskInboxMutation(
                TaskInboxMutationError::Workflow(WorkflowStateError::TaskTransition { .. })
            ))
        ));
        assert_eq!(workflow.projection().revision, before_delete);
        workflow
            .apply_task_inbox(task_inbox_command(serde_json::json!({
                "operation": "transition_run_projection",
                "task": {
                    "id": "task-edit",
                    "title": "Edited title",
                    "description": "Edited description",
                    "workspace_path": second_workspace,
                    "agent_name": "agent-b",
                    "status": "failed",
                    "priority": "high",
                    "created_at": "2026-07-17T09:01:00.000Z",
                    "updated_at": "2026-07-17T09:06:00.000Z",
                    "current_run_id": "run-edit",
                    "summary": "Failed atomically"
                },
                "run": {
                    "id": "run-edit",
                    "task_id": "task-edit",
                    "attempt": 1,
                    "status": "failed",
                    "started_at": "2026-07-17T09:04:00.000Z",
                    "ended_at": "2026-07-17T09:06:00.000Z",
                    "error": "fixture failure"
                },
                "transition": "fail",
                "updatedAt": "2026-07-17T09:06:00.000Z"
            })))
            .unwrap();
        let retried = workflow
            .apply_task_inbox(task_inbox_command(serde_json::json!({
                "operation": "queue_task_projection",
                "task": {
                    "id": "task-edit",
                    "title": "Edited title",
                    "description": "Edited description",
                    "workspace_path": second_workspace,
                    "agent_name": "agent-b",
                    "status": "queued",
                    "priority": "high",
                    "created_at": "2026-07-17T09:01:00.000Z",
                    "updated_at": "2026-07-17T09:06:30.000Z",
                    "summary": "Retry queued atomically"
                },
                "updatedAt": "2026-07-17T09:06:30.000Z"
            })))
            .unwrap();
        assert!(retried.task_inbox.tasks[0].current_run_id.is_none());
        let deleted = workflow
            .apply_task_inbox(task_inbox_command(serde_json::json!({
                "operation": "delete_task",
                "taskId": "task-edit",
                "updatedAt": "2026-07-17T09:07:00.000Z"
            })))
            .unwrap();
        assert!(deleted.task_inbox.tasks.is_empty());
        assert!(deleted.task_inbox.runs.is_empty());
        assert!(deleted.task_inbox.events.is_empty());
    }

    let reopened = DurableWorkflow::open(&database).unwrap();
    assert!(reopened.open_projection().snapshot.tasks.is_empty());
    assert!(reopened.open_projection().snapshot.runs.is_empty());
    assert!(reopened.current_task_inbox().unwrap().tasks.is_empty());
    drop(reopened);
    fs::remove_dir_all(directory).unwrap();
}

fn task_inbox_command(value: serde_json::Value) -> TaskInboxCommand {
    serde_json::from_value(value).unwrap()
}

#[test]
fn sqlite_v2_store_migrates_to_native_workflow_metadata() {
    let directory = unique_temp_dir("workflow-sqlite-v2-migration");
    let database = directory.join("workflow.sqlite3");
    {
        let connection = rusqlite::Connection::open(&database).unwrap();
        connection
            .execute_batch(
                "CREATE TABLE tasks (
                    id TEXT PRIMARY KEY NOT NULL,
                    workspace_path TEXT NOT NULL,
                    agent_name TEXT NOT NULL,
                    status TEXT NOT NULL,
                    attempt INTEGER NOT NULL,
                    current_run_id TEXT
                 ) STRICT;
                 CREATE TABLE runs (
                    id TEXT PRIMARY KEY NOT NULL,
                    task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
                    attempt INTEGER NOT NULL,
                    status TEXT NOT NULL
                 ) STRICT;
                 CREATE TABLE workflow_meta (
                    singleton INTEGER PRIMARY KEY NOT NULL,
                    revision INTEGER NOT NULL
                 ) STRICT;
                 INSERT INTO workflow_meta (singleton, revision) VALUES (1, 0);
                 PRAGMA user_version = 2;",
            )
            .unwrap();
    }
    let mut store = SqliteWorkflowStore::open(&database).unwrap();
    let metadata = store.migration_metadata().unwrap();
    assert_eq!(metadata.phase, WorkflowMigrationPhase::Native);
    assert_eq!(metadata.source_checksum, None);
    store.save_snapshot(&WorkflowSnapshot::default()).unwrap();
    assert_eq!(store.revision().unwrap(), 1);
    drop(store);
    fs::remove_dir_all(directory).unwrap();
}

#[test]
#[allow(clippy::too_many_lines)]
fn sqlite_v4_ready_store_migrates_to_v5_and_can_activate() {
    let directory = unique_temp_dir("workflow-sqlite-v4-migration");
    let workspace = directory.join("workspace");
    fs::create_dir(&workspace).unwrap();
    let database = directory.join("workflow.sqlite3");
    let current: TaskInboxSnapshot = serde_json::from_value(serde_json::json!({
        "schema": "ianvs-acp.task-inbox.v1",
        "updated_at": "2026-07-17T08:00:00.000Z",
        "tasks": [{
            "id": "task-1",
            "title": "Ready task",
            "description": "Preserve v4 materialization.",
            "workspace_path": workspace,
            "agent_name": "fixture",
            "status": "needs_human_review",
            "priority": "normal",
            "created_at": "2026-07-17T07:00:00.000Z",
            "updated_at": "2026-07-17T08:00:00.000Z"
        }],
        "runs": [],
        "events": [],
        "artifacts": [],
        "approvals": [],
        "resources": []
    }))
    .unwrap();
    let encoded = serde_json::to_string(&current).unwrap();
    {
        let connection = rusqlite::Connection::open(&database).unwrap();
        connection
            .execute_batch(
                "CREATE TABLE tasks (
                    id TEXT PRIMARY KEY NOT NULL,
                    workspace_path TEXT NOT NULL,
                    agent_name TEXT NOT NULL,
                    status TEXT NOT NULL,
                    attempt INTEGER NOT NULL CHECK (attempt >= 0),
                    current_run_id TEXT
                 ) STRICT;
                 CREATE TABLE runs (
                    id TEXT PRIMARY KEY NOT NULL,
                    task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
                    attempt INTEGER NOT NULL CHECK (attempt > 0),
                    status TEXT NOT NULL
                 ) STRICT;
                 CREATE TABLE workflow_meta (
                    singleton INTEGER PRIMARY KEY NOT NULL CHECK (singleton = 1),
                    revision INTEGER NOT NULL CHECK (revision >= 0),
                    migration_state TEXT NOT NULL
                        CHECK (migration_state IN ('native', 'staged', 'ready')),
                    source_checksum TEXT
                 ) STRICT;
                 CREATE TABLE task_inbox_source_archive (
                    singleton INTEGER PRIMARY KEY NOT NULL CHECK (singleton = 1),
                    payload_json TEXT NOT NULL
                 ) STRICT;
                 CREATE TABLE task_inbox_current (
                    singleton INTEGER PRIMARY KEY NOT NULL CHECK (singleton = 1),
                    payload_json TEXT NOT NULL
                 ) STRICT;
                 CREATE INDEX runs_task_id ON runs(task_id);
                 PRAGMA user_version = 4;",
            )
            .unwrap();
        connection
            .execute(
                "INSERT INTO tasks (
                    id, workspace_path, agent_name, status, attempt, current_run_id
                 ) VALUES ('task-1', ?1, 'fixture', 'needs_human_review', 0, NULL)",
                [workspace.display().to_string()],
            )
            .unwrap();
        connection
            .execute(
                "INSERT INTO workflow_meta (
                    singleton, revision, migration_state, source_checksum
                 ) VALUES (1, 2, 'ready', 'sha256:v4')",
                [],
            )
            .unwrap();
        connection
            .execute(
                "INSERT INTO task_inbox_source_archive (singleton, payload_json)
                 VALUES (1, ?1)",
                [&encoded],
            )
            .unwrap();
        connection
            .execute(
                "INSERT INTO task_inbox_current (singleton, payload_json)
                 VALUES (1, ?1)",
                [&encoded],
            )
            .unwrap();
    }
    let mut store = SqliteWorkflowStore::open(&database).unwrap();
    assert_eq!(
        store.migration_metadata().unwrap().phase,
        WorkflowMigrationPhase::Ready
    );
    assert_eq!(store.load_current_task_inbox().unwrap(), Some(current));
    assert_eq!(store.activate_task_inbox(2).unwrap(), 3);
    assert_eq!(
        store.migration_metadata().unwrap().phase,
        WorkflowMigrationPhase::Active
    );
    drop(store);
    fs::remove_dir_all(directory).unwrap();
}

#[cfg(unix)]
#[test]
fn sqlite_store_rejects_symlink_database_target() {
    use std::os::unix::fs::symlink;

    let directory = unique_temp_dir("workflow-sqlite-symlink");
    let victim = directory.join("victim.sqlite3");
    fs::write(&victim, b"not a database").unwrap();
    let link = directory.join("workflow.sqlite3");
    symlink(&victim, &link).unwrap();
    assert!(matches!(
        SqliteWorkflowStore::open(&link),
        Err(WorkflowStoreError::SymlinkPath(_))
    ));
    fs::remove_dir_all(directory).unwrap();
}

fn unique_temp_dir(label: &str) -> std::path::PathBuf {
    let path = std::env::temp_dir().join(format!(
        "ianvs-acp-{label}-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    fs::create_dir_all(&path).unwrap();
    path
}
