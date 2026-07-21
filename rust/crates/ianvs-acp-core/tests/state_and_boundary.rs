use std::fs;

use ianvs_acp_core::{
    ExecutionGateError, RuntimeStateError, RuntimeStateMachine, RuntimeStatus, SessionStatus,
    WorkflowStateError, WorkflowStateMachine, WorkspaceError, WorkspaceExecutionGate,
    WorkspaceScope,
};

#[test]
fn rust_owns_runtime_session_and_permission_transitions() {
    let mut state = RuntimeStateMachine::new();
    assert_eq!(state.runtime_status(), RuntimeStatus::Stopped);
    state.start_agent().unwrap();
    state.agent_ready().unwrap();
    state.session_created("session-1").unwrap();
    // Reverse requests may independently wait for approval while the session
    // is otherwise idle; they must not fabricate a running prompt state.
    state.permission_requested("session-1").unwrap();
    assert_eq!(
        state.session_status("session-1"),
        Some(SessionStatus::Ready)
    );
    state.permission_resolved("session-1").unwrap();
    state.prompt_started("session-1").unwrap();
    state.permission_requested("session-1").unwrap();
    // Multiple in-flight permission requests keep the same authoritative state.
    state.permission_requested("session-1").unwrap();
    assert_eq!(
        state.session_status("session-1"),
        Some(SessionStatus::WaitingPermission)
    );
    state.permission_resolved("session-1").unwrap();
    state.cancel_started("session-1").unwrap();
    state.prompt_finished("session-1").unwrap();
    assert_eq!(
        state.session_status("session-1"),
        Some(SessionStatus::Ready)
    );
    state.dispose();
    assert_eq!(state.runtime_status(), RuntimeStatus::Disposed);
    assert_eq!(
        state.session_status("session-1"),
        Some(SessionStatus::Closed)
    );
}

#[test]
fn illegal_parallel_prompt_is_rejected_by_core() {
    let mut state = RuntimeStateMachine::new();
    state.start_agent().unwrap();
    state.agent_ready().unwrap();
    state.session_created("session-1").unwrap();
    state.prompt_started("session-1").unwrap();
    assert!(matches!(
        state.prompt_started("session-1"),
        Err(RuntimeStateError::SessionState { .. })
    ));
}

#[test]
fn execution_gate_is_exclusive_and_raii_released() {
    let root = std::env::temp_dir();
    let gate = WorkspaceExecutionGate::new();
    let lease = gate.try_acquire(&root, "task-a").unwrap();
    assert_eq!(gate.owner(&root).as_deref(), Some("task-a"));
    assert_eq!(
        gate.try_acquire(&root, "task-b").unwrap_err(),
        ExecutionGateError::Busy {
            owner: "task-a".to_string()
        }
    );
    drop(lease);
    assert!(gate.owner(&root).is_none());
    gate.try_acquire(&root, "task-b").unwrap().release();
}

#[test]
fn workspace_scope_rejects_lexical_escape() {
    let root = unique_temp_dir("scope");
    let scope = WorkspaceScope::new(&root, std::iter::empty::<&str>()).unwrap();
    assert!(matches!(
        scope.resolve_for_creation("../escape.txt"),
        Err(WorkspaceError::OutsideWorkspace(_))
    ));
    let resolved = scope.resolve_for_creation("nested/output.txt").unwrap();
    assert!(resolved.starts_with(root.canonicalize().unwrap()));
    fs::remove_dir_all(root).unwrap();
}

#[cfg(unix)]
#[test]
fn workspace_scope_rejects_existing_symlink_escape() {
    use std::os::unix::fs::symlink;

    let root = unique_temp_dir("symlink-scope");
    let outside = unique_temp_dir("symlink-outside");
    symlink(&outside, root.join("escape-link")).unwrap();
    let scope = WorkspaceScope::new(&root, std::iter::empty::<&str>()).unwrap();
    assert!(matches!(
        scope.resolve_for_creation("escape-link/output.txt"),
        Err(WorkspaceError::OutsideWorkspace(_))
    ));
    fs::remove_dir_all(root).unwrap();
    fs::remove_dir_all(outside).unwrap();
}

#[test]
fn workflow_definition_edits_are_pre_dispatch_and_delete_releases_history() {
    let first = unique_temp_dir("workflow-definition-first");
    let second = unique_temp_dir("workflow-definition-second");
    let mut workflow = WorkflowStateMachine::new();
    workflow.create_task("task-1", &first, "agent-a").unwrap();
    workflow.queue_task("task-1").unwrap();
    workflow
        .update_task_definition("task-1", &second, "agent-b")
        .unwrap();
    let task = workflow.task("task-1").unwrap();
    assert_eq!(task.agent_name, "agent-b");
    assert_eq!(
        task.workspace_path,
        second.canonicalize().unwrap().display().to_string()
    );

    workflow.dispatch_task("task-1", "run-1").unwrap();
    assert!(matches!(
        workflow.update_task_definition("task-1", &first, "agent-c"),
        Err(WorkflowStateError::TaskTransition { .. })
    ));
    assert!(matches!(
        workflow.delete_task("task-1"),
        Err(WorkflowStateError::TaskTransition { .. })
    ));
    workflow.fail_run("run-1").unwrap();
    workflow.delete_task("task-1").unwrap();
    assert!(matches!(
        workflow.task("task-1"),
        Err(WorkflowStateError::UnknownTask(_))
    ));
    assert!(matches!(
        workflow.run("run-1"),
        Err(WorkflowStateError::UnknownRun(_))
    ));
    assert!(workflow.workspace_owner(&second).is_none());
    fs::remove_dir_all(first).unwrap();
    fs::remove_dir_all(second).unwrap();
}

#[test]
fn workflow_restores_missing_workspace_identity_but_dispatch_requires_it_to_exist() {
    let root = unique_temp_dir("workflow-missing-workspace");
    let missing = root.join("workspace");
    let mut workflow = WorkflowStateMachine::new();
    workflow.create_task("task-1", &missing, "agent-a").unwrap();
    workflow.queue_task("task-1").unwrap();
    let normalized = root.canonicalize().unwrap().join("workspace");

    let restored = WorkflowStateMachine::restore(workflow.snapshot()).unwrap();
    assert_eq!(
        restored.task("task-1").unwrap().workspace_path,
        normalized.display().to_string()
    );
    assert!(matches!(
        workflow.dispatch_task("task-1", "run-1"),
        Err(WorkflowStateError::Workspace(
            WorkspaceError::CannotResolve { .. }
        ))
    ));

    fs::create_dir(&missing).unwrap();
    workflow.dispatch_task("task-1", "run-1").unwrap();
    assert_eq!(
        workflow.workspace_owner(&normalized),
        Some("task-1".to_string())
    );
    fs::remove_dir_all(root).unwrap();
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
