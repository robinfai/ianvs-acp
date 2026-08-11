use std::fs;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use ianvs_acp_core::{
    TerminalConfig, TerminalCreateSpec, TerminalEnvironmentVariable, TerminalError,
    TerminalManager, TerminalRuntimeEvent, WorkspaceScope,
};

#[tokio::test]
async fn real_pty_uses_pending_permission_and_bounds_output() {
    let workspace = unique_temp_dir("terminal-pty");
    let events = Arc::new(Mutex::new(Vec::new()));
    let captured = Arc::clone(&events);
    let manager = TerminalManager::new(
        TerminalConfig {
            default_output_byte_limit: 4,
            max_output_byte_limit: 16,
            ..TerminalConfig::default()
        },
        move |event| captured.lock().unwrap().push(event),
    )
    .unwrap();
    manager
        .register_session(
            "session-1",
            WorkspaceScope::new(&workspace, std::iter::empty::<&std::path::Path>()).unwrap(),
        )
        .unwrap();
    let approval = manager
        .request_create(TerminalCreateSpec {
            session_id: "session-1".to_string(),
            command: "/bin/sh".to_string(),
            args: vec!["-c".to_string(), "printf abcdef".to_string()],
            environment: Vec::new(),
            cwd: None,
            output_byte_limit: None,
        })
        .unwrap();
    assert_eq!(approval.command, ["/bin/sh", "-c", "printf abcdef"]);
    assert!(matches!(
        manager.output("session-1", "not-created"),
        Err(TerminalError::UnknownTerminal(_))
    ));

    let terminal_id = manager.approve_create(&approval.approval_id).unwrap();
    let exit = tokio::time::timeout(
        Duration::from_secs(5),
        manager.wait_for_exit("session-1", &terminal_id),
    )
    .await
    .unwrap()
    .unwrap();
    assert_eq!(exit.exit_code, Some(0));
    let output = manager.output("session-1", &terminal_id).unwrap();
    assert!(output.truncated);
    assert!(output.output.len() <= 4);
    assert!(
        "abcdef".ends_with(&output.output),
        "unexpected retained PTY output: {:?}",
        output.output
    );
    assert_eq!(output.exit, Some(exit));
    manager.release("session-1", &terminal_id).unwrap();
    let events = events.lock().unwrap();
    assert!(matches!(
        events.first(),
        Some(TerminalRuntimeEvent::Attached { terminal_id: id, .. }) if id == &terminal_id
    ));
    assert!(events.iter().any(|event| matches!(
        event,
        TerminalRuntimeEvent::Attached { terminal_id: id, .. } if id == &terminal_id
    )));
    assert!(events.iter().any(|event| matches!(
        event,
        TerminalRuntimeEvent::Exited { terminal_id: id, .. } if id == &terminal_id
    )));
    assert!(events.iter().any(|event| matches!(
        event,
        TerminalRuntimeEvent::Released { terminal_id: id, .. } if id == &terminal_id
    )));
    fs::remove_dir_all(workspace).unwrap();
}

#[test]
fn terminal_denial_and_workspace_escape_fail_closed() {
    let workspace = unique_temp_dir("terminal-denial");
    let outside = unique_temp_dir("terminal-outside");
    let manager = TerminalManager::new(TerminalConfig::default(), |_| {}).unwrap();
    manager
        .register_session(
            "session-1",
            WorkspaceScope::new(&workspace, std::iter::empty::<&std::path::Path>()).unwrap(),
        )
        .unwrap();
    let denied_file = workspace.join("must-not-exist");
    let approval = manager
        .request_create(TerminalCreateSpec {
            session_id: "session-1".to_string(),
            command: "/usr/bin/touch".to_string(),
            args: vec![denied_file.display().to_string()],
            environment: Vec::new(),
            cwd: None,
            output_byte_limit: None,
        })
        .unwrap();
    manager.deny_create(&approval.approval_id).unwrap();
    assert!(!denied_file.exists());
    assert!(matches!(
        manager.approve_create(&approval.approval_id),
        Err(TerminalError::UnknownApproval(_))
    ));
    assert!(matches!(
        manager.request_create(TerminalCreateSpec {
            session_id: "session-1".to_string(),
            command: "/bin/pwd".to_string(),
            args: Vec::new(),
            environment: Vec::new(),
            cwd: Some(outside.clone()),
            output_byte_limit: None,
        }),
        Err(TerminalError::Workspace(_))
    ));
    fs::remove_dir_all(workspace).unwrap();
    fs::remove_dir_all(outside).unwrap();
}

#[test]
fn terminal_handle_quota_counts_pending_approvals() {
    let workspace = unique_temp_dir("terminal-quota");
    let manager = TerminalManager::new(
        TerminalConfig {
            max_active_handles: 1,
            max_active_handles_per_session: 1,
            ..TerminalConfig::default()
        },
        |_| {},
    )
    .unwrap();
    manager
        .register_session(
            "session-1",
            WorkspaceScope::new(&workspace, std::iter::empty::<&std::path::Path>()).unwrap(),
        )
        .unwrap();
    let spec = TerminalCreateSpec {
        session_id: "session-1".to_string(),
        command: "/bin/echo".to_string(),
        args: vec!["ok".to_string()],
        environment: Vec::new(),
        cwd: None,
        output_byte_limit: None,
    };
    let first = manager.request_create(spec.clone()).unwrap();
    assert_eq!(
        manager.request_create(spec).unwrap_err(),
        TerminalError::GlobalHandleLimit
    );
    manager.deny_create(&first.approval_id).unwrap();
    fs::remove_dir_all(workspace).unwrap();
}

#[test]
fn terminal_spec_is_bounded_before_pending_and_approval_preserves_environment() {
    let workspace = unique_temp_dir("terminal-spec-bound");
    let manager = TerminalManager::new(
        TerminalConfig {
            max_active_handles: 1,
            max_active_handles_per_session: 1,
            ..TerminalConfig::default()
        },
        |_| {},
    )
    .unwrap();
    manager
        .register_session(
            "session-1",
            WorkspaceScope::new(&workspace, std::iter::empty::<&std::path::Path>()).unwrap(),
        )
        .unwrap();
    assert_eq!(
        manager
            .request_create(TerminalCreateSpec {
                session_id: "session-1".to_string(),
                command: "/bin/echo".to_string(),
                args: vec!["x".repeat(7 * 1024); 7],
                environment: Vec::new(),
                cwd: None,
                output_byte_limit: None,
            })
            .unwrap_err(),
        TerminalError::SpecLimit
    );

    let environment = vec![TerminalEnvironmentVariable {
        name: "PATH".to_string(),
        value: "/approved/bin".to_string(),
    }];
    let approval = manager
        .request_create(TerminalCreateSpec {
            session_id: "session-1".to_string(),
            command: "/bin/echo".to_string(),
            args: vec!["ok".to_string()],
            environment: environment.clone(),
            cwd: None,
            output_byte_limit: None,
        })
        .unwrap();
    assert_eq!(approval.environment, environment);
    manager.deny_create(&approval.approval_id).unwrap();
    fs::remove_dir_all(workspace).unwrap();
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
