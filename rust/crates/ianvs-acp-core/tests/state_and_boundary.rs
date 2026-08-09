use std::fs;

use ianvs_acp_core::{
    RuntimeStateError, RuntimeStateMachine, RuntimeStatus, SessionStatus, WorkspaceError,
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
