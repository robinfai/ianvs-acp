use std::fs;

use ianvs_acp_core::{
    InboxTaskStatus, RunStatus, TaskInboxCommand, TaskInboxError, TaskInboxSnapshot, TaskStatus,
    WorkflowStateMachine,
};
use serde_json::{Value, json};

#[test]
fn canonical_task_inbox_round_trips_and_projects_all_record_kinds() {
    let workspace = unique_temp_dir("task-inbox-round-trip");
    let value = fixture(&workspace);
    let snapshot: TaskInboxSnapshot = serde_json::from_value(value.clone()).unwrap();
    snapshot.validate().unwrap();
    assert_eq!(serde_json::to_value(&snapshot).unwrap(), value);

    let imported = snapshot.workflow_import().unwrap();
    assert_eq!(imported.normalized_historical_task_ids, ["task-1"]);
    assert_eq!(
        imported.snapshot.tasks[0].status,
        TaskStatus::NeedsHumanReview
    );
    assert_eq!(
        imported.snapshot.runs[0].status,
        RunStatus::NeedsHumanReview
    );
    let synchronized = snapshot
        .synchronized_with_workflow(&imported.snapshot)
        .unwrap();
    assert_eq!(
        synchronized.tasks[0].status,
        ianvs_acp_core::InboxTaskStatus::NeedsHumanReview
    );
    assert_eq!(
        synchronized.runs[0].status,
        ianvs_acp_core::InboxTaskStatus::NeedsHumanReview
    );
    assert_eq!(
        snapshot.tasks[0].status,
        ianvs_acp_core::InboxTaskStatus::ApprovedForExport
    );
    let restored = WorkflowStateMachine::restore(imported.snapshot).unwrap();
    assert_eq!(restored.task("task-1").unwrap().attempt, 1);
    assert_eq!(
        restored.workspace_owner(workspace.canonicalize().unwrap()),
        Some("task-1".to_string())
    );
    fs::remove_dir_all(workspace).unwrap();
}

#[test]
fn task_inbox_rejects_cross_record_and_global_id_corruption() {
    let workspace = unique_temp_dir("task-inbox-reference");
    let mut invalid_artifact = fixture(&workspace);
    invalid_artifact["approvals"][0]["artifact_ids"] = json!(["missing"]);
    let snapshot: TaskInboxSnapshot = serde_json::from_value(invalid_artifact).unwrap();
    assert!(matches!(
        snapshot.validate(),
        Err(TaskInboxError::InvalidArtifact {
            approval_id,
            artifact_id
        }) if approval_id == "approval-1" && artifact_id == "missing"
    ));

    let mut duplicate = fixture(&workspace);
    duplicate["events"][0]["id"] = json!("artifact-1");
    let snapshot: TaskInboxSnapshot = serde_json::from_value(duplicate).unwrap();
    assert!(matches!(
        snapshot.validate(),
        Err(TaskInboxError::DuplicateId(id)) if id == "artifact-1"
    ));
    fs::remove_dir_all(workspace).unwrap();
}

#[test]
fn task_inbox_rejects_lossy_fields_and_non_run_statuses() {
    let workspace = unique_temp_dir("task-inbox-strict");
    let mut unknown = fixture(&workspace);
    unknown["tasks"][0]["future_field"] = json!(true);
    assert!(serde_json::from_value::<TaskInboxSnapshot>(unknown).is_err());

    let mut queued_run = fixture(&workspace);
    queued_run["runs"][0]["status"] = json!("queued");
    let snapshot: TaskInboxSnapshot = serde_json::from_value(queued_run).unwrap();
    assert!(matches!(
        snapshot.workflow_import(),
        Err(TaskInboxError::InvalidRunStatus { run_id, .. }) if run_id == "run-1"
    ));
    fs::remove_dir_all(workspace).unwrap();
}

#[test]
fn failed_run_and_retry_queue_are_applied_as_one_projection_change() {
    let workspace = unique_temp_dir("task-inbox-atomic-retry");
    let mut value = fixture(&workspace);
    value["tasks"][0]["status"] = json!("running");
    value["runs"][0]["status"] = json!("running");
    let mut snapshot: TaskInboxSnapshot = serde_json::from_value(value).unwrap();
    let imported = snapshot.workflow_import().unwrap();
    let mut workflow = WorkflowStateMachine::restore(imported.snapshot).unwrap();
    let mut task = snapshot.tasks[0].clone();
    task.status = InboxTaskStatus::Queued;
    task.current_run_id = None;
    task.summary = Some("Runtime unavailable. Retrying shortly.".to_string());
    task.error = None;
    task.metadata.insert(
        "next_retry_at".to_string(),
        json!("2026-07-17T08:01:00.000Z"),
    );
    let mut run = snapshot.runs[0].clone();
    run.status = InboxTaskStatus::Failed;
    run.ended_at = Some("2026-07-17T08:00:00.000Z".to_string());
    run.error = Some("runtime unavailable".to_string());

    snapshot
        .apply_command(
            &mut workflow,
            TaskInboxCommand::FailRunAndQueueRetryProjection {
                task,
                run,
                updated_at: "2026-07-17T08:00:00.000Z".to_string(),
            },
        )
        .unwrap();

    assert_eq!(snapshot.tasks[0].status, InboxTaskStatus::Queued);
    assert!(snapshot.tasks[0].current_run_id.is_none());
    assert_eq!(snapshot.runs[0].status, InboxTaskStatus::Failed);
    assert_eq!(workflow.task("task-1").unwrap().status, TaskStatus::Queued);
    assert_eq!(workflow.run("run-1").unwrap().status, RunStatus::Failed);
    fs::remove_dir_all(workspace).unwrap();
}

fn fixture(workspace: &std::path::Path) -> Value {
    json!({
        "schema": "ianvs-acp.task-inbox.v1",
        "updated_at": "2026-07-17T08:00:00.000Z",
        "tasks": [{
            "id": "task-1",
            "title": "Review migration",
            "description": "Preserve every UI projection record.",
            "workspace_path": workspace,
            "agent_name": "fixture",
            "status": "approved_for_export",
            "priority": "high",
            "created_at": "2026-07-17T07:00:00.000Z",
            "updated_at": "2026-07-17T08:00:00.000Z",
            "session_id": "session-1",
            "current_run_id": "run-1",
            "summary": "Awaiting review",
            "resource_id": "resource-1",
            "skill_ids": ["skill-1"],
            "metadata": {"source": "dart"}
        }],
        "runs": [{
            "id": "run-1",
            "task_id": "task-1",
            "attempt": 1,
            "status": "approved_for_export",
            "started_at": "2026-07-17T07:30:00.000Z",
            "session_id": "session-1",
            "prompt_snapshot": "do the work",
            "model": "fixture-model"
        }],
        "events": [{
            "id": "event-1",
            "task_id": "task-1",
            "run_id": "run-1",
            "kind": "assistant",
            "text": "Finished",
            "created_at": "2026-07-17T07:50:00.000Z",
            "session_id": "session-1",
            "metadata": {"sequence": 1}
        }],
        "artifacts": [{
            "id": "artifact-1",
            "task_id": "task-1",
            "run_id": "run-1",
            "kind": "git_diff",
            "status": "candidate",
            "title": "Git diff",
            "created_at": "2026-07-17T07:55:00.000Z",
            "path": "changes.diff",
            "content_preview": "diff --git",
            "sha256": "abc123",
            "size_bytes": 10,
            "metadata": {"truncated": false}
        }],
        "approvals": [{
            "id": "approval-1",
            "task_id": "task-1",
            "run_id": "run-1",
            "kind": "export",
            "status": "pending",
            "created_at": "2026-07-17T07:56:00.000Z",
            "target": "git_push",
            "destination": "origin/main",
            "risk_summary": "External side effect",
            "rationale": "Human must decide",
            "artifact_ids": ["artifact-1"],
            "metadata": {"hard_gate": true}
        }],
        "resources": [{
            "id": "resource-1",
            "type": "git_repo",
            "label": "Workspace",
            "ref": {"path": workspace},
            "serial": true
        }]
    })
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
