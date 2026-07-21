use std::fs;

use ianvs_acp_core::{
    DurableWorkflow, InboxTaskStatus, PromptSubmissionState, RecoveryState,
    SuggestedRecoveryAction, TaskInboxSnapshot, WorkspaceMutationPossibility,
};

#[test]
fn restart_classifies_each_run_without_replaying_uncertain_work() {
    let directory = unique_temp_dir("recovery-classification");
    let database = directory.join("workflow.sqlite3");
    let workspace_safe = create_workspace(&directory, "safe");
    let workspace_session = create_workspace(&directory, "session");
    let workspace_tool = create_workspace(&directory, "tool");
    let workspace_permission = create_workspace(&directory, "permission");
    let workspace_user = create_workspace(&directory, "user");
    let source: TaskInboxSnapshot = serde_json::from_value(serde_json::json!({
        "schema": "ianvs-acp.task-inbox.v1",
        "updated_at": "2026-07-21T10:00:00.000Z",
        "tasks": [
            task("safe", &workspace_safe, "dispatched", "run-safe"),
            task("session", &workspace_session, "running", "run-session"),
            task("tool", &workspace_tool, "running", "run-tool"),
            task("permission", &workspace_permission, "blocked_on_permission", "run-permission"),
            task("user", &workspace_user, "blocked_on_user_input", "run-user")
        ],
        "runs": [
            run("run-safe", "safe", "dispatched", None, None),
            run("run-session", "session", "running", Some("session-1"), None),
            run("run-tool", "tool", "running", Some("session-2"), Some("submitted prompt")),
            run("run-permission", "permission", "blocked_on_permission", Some("session-3"), Some("submitted prompt")),
            run("run-user", "user", "blocked_on_user_input", Some("session-4"), Some("submitted prompt"))
        ],
        "events": [{
            "id": "event-tool",
            "task_id": "tool",
            "run_id": "run-tool",
            "kind": "tool",
            "text": "workspace tool started",
            "created_at": "2026-07-21T10:00:01.000Z"
        }],
        "artifacts": [],
        "approvals": [],
        "resources": []
    }))
    .unwrap();

    {
        let mut workflow = DurableWorkflow::open(&database).unwrap();
        workflow
            .stage_task_inbox_import(&source, "sha256:recovery-classification")
            .unwrap();
        workflow.materialize_task_inbox().unwrap();
        workflow.activate_task_inbox().unwrap();
    }

    let workflow = DurableWorkflow::open(&database).unwrap();
    let report = &workflow.open_projection().recovery;
    assert_eq!(report.runs.len(), 4);
    let safe = recovery(report, "run-safe");
    assert_eq!(safe.recovery_state, RecoveryState::Requeued);
    assert_eq!(
        safe.prompt_submission_state,
        PromptSubmissionState::NotSubmitted
    );
    assert_eq!(
        safe.workspace_mutation_possibility,
        WorkspaceMutationPossibility::None
    );
    assert_eq!(safe.suggested_action, SuggestedRecoveryAction::Requeue);
    let session = recovery(report, "run-session");
    assert_eq!(session.recovery_state, RecoveryState::Orphaned);
    assert_eq!(
        session.suggested_action,
        SuggestedRecoveryAction::ResumeSession
    );
    let tool = recovery(report, "run-tool");
    assert_eq!(tool.recovery_state, RecoveryState::ReviewRequired);
    assert_eq!(tool.suggested_action, SuggestedRecoveryAction::HumanReview);
    assert_eq!(
        tool.workspace_mutation_possibility,
        WorkspaceMutationPossibility::Possible
    );
    let permission = recovery(report, "run-permission");
    assert_eq!(permission.recovery_state, RecoveryState::ReviewRequired);

    let current = workflow.current_task_inbox().unwrap();
    assert_eq!(task_status(current, "safe"), InboxTaskStatus::Queued);
    assert_eq!(
        task_status(current, "session"),
        InboxTaskStatus::NeedsHumanReview
    );
    assert_eq!(
        task_status(current, "tool"),
        InboxTaskStatus::NeedsHumanReview
    );
    assert_eq!(
        task_status(current, "permission"),
        InboxTaskStatus::NeedsHumanReview
    );
    assert_eq!(
        task_status(current, "user"),
        InboxTaskStatus::BlockedOnUserInput
    );
    drop(workflow);

    let second = DurableWorkflow::open(&database).unwrap();
    assert!(second.open_projection().recovery.runs.is_empty());
    drop(second);
    fs::remove_dir_all(directory).unwrap();
}

fn task(id: &str, workspace: &std::path::Path, status: &str, run_id: &str) -> serde_json::Value {
    serde_json::json!({
        "id": id,
        "title": id,
        "description": "recovery fixture",
        "workspace_path": workspace,
        "agent_name": "fixture",
        "status": status,
        "priority": "normal",
        "created_at": "2026-07-21T09:00:00.000Z",
        "updated_at": "2026-07-21T10:00:00.000Z",
        "current_run_id": run_id,
        "metadata": {}
    })
}

fn run(
    id: &str,
    task_id: &str,
    status: &str,
    session_id: Option<&str>,
    prompt_snapshot: Option<&str>,
) -> serde_json::Value {
    serde_json::json!({
        "id": id,
        "task_id": task_id,
        "attempt": 1,
        "status": status,
        "started_at": "2026-07-21T10:00:00.000Z",
        "session_id": session_id,
        "prompt_snapshot": prompt_snapshot
    })
}

fn recovery<'a>(
    report: &'a ianvs_acp_core::ClassifiedRecoveryReport,
    run_id: &str,
) -> &'a ianvs_acp_core::RunRecoveryRecord {
    report
        .runs
        .iter()
        .find(|record| record.run_id == run_id)
        .unwrap()
}

fn task_status(snapshot: &TaskInboxSnapshot, task_id: &str) -> InboxTaskStatus {
    snapshot
        .tasks
        .iter()
        .find(|task| task.id == task_id)
        .unwrap()
        .status
}

fn create_workspace(root: &std::path::Path, name: &str) -> std::path::PathBuf {
    let path = root.join(name);
    fs::create_dir(&path).unwrap();
    path
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
