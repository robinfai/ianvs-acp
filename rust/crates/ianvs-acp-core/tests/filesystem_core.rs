use ianvs_acp_core::{
    FilesystemConfig, FilesystemError, FilesystemManager, FilesystemOperationKind,
    FilesystemOperationResult, WorkspaceScope,
};

#[test]
fn filesystem_read_and_write_use_pending_permission_operations() {
    let workspace = unique_temp_dir("filesystem-core");
    let input = workspace.join("input.txt");
    std::fs::write(&input, "first\nsecond\nthird\n").unwrap();
    let manager = FilesystemManager::new(FilesystemConfig {
        read_text_file: true,
        write_text_file: true,
    });
    manager
        .register_session(
            "session-1",
            WorkspaceScope::new(&workspace, std::iter::empty::<&std::path::Path>()).unwrap(),
        )
        .unwrap();

    let read = manager
        .request_read("session-1", &input, Some(2), Some(1))
        .unwrap();
    assert_eq!(read.kind, FilesystemOperationKind::Read);
    assert_eq!(
        manager.approve(&read.approval_id).unwrap(),
        FilesystemOperationResult::Read("second\n".to_string())
    );
    assert!(matches!(
        manager.approve(&read.approval_id),
        Err(FilesystemError::UnknownApproval(_))
    ));

    let output = workspace.join("output.txt");
    let denied = manager
        .request_write("session-1", &output, "denied".to_string())
        .unwrap();
    manager.deny(&denied.approval_id).unwrap();
    assert!(!output.exists());
    let write = manager
        .request_write("session-1", &output, "approved".to_string())
        .unwrap();
    assert_eq!(write.kind, FilesystemOperationKind::Write);
    assert_eq!(
        manager.approve(&write.approval_id).unwrap(),
        FilesystemOperationResult::Written
    );
    assert_eq!(std::fs::read_to_string(output).unwrap(), "approved");
    std::fs::remove_dir_all(workspace).unwrap();
}

#[test]
fn filesystem_scope_and_selected_file_identity_fail_closed() {
    let workspace = unique_temp_dir("filesystem-scope");
    let outside = unique_temp_dir("filesystem-outside");
    let inside = workspace.join("inside.txt");
    let escaped = outside.join("escaped.txt");
    std::fs::write(&inside, "before").unwrap();
    std::fs::write(&escaped, "secret").unwrap();
    let manager = FilesystemManager::new(FilesystemConfig {
        read_text_file: true,
        write_text_file: true,
    });
    manager
        .register_session(
            "session-1",
            WorkspaceScope::new(&workspace, std::iter::empty::<&std::path::Path>()).unwrap(),
        )
        .unwrap();

    assert!(matches!(
        manager.request_read("session-1", &escaped, None, None),
        Err(FilesystemError::Workspace(_))
    ));
    assert!(matches!(
        manager.request_write("session-1", &escaped, "no".to_string()),
        Err(FilesystemError::Workspace(_))
    ));
    let read = manager
        .request_read("session-1", &inside, None, None)
        .unwrap();
    std::fs::write(&inside, "after and different").unwrap();
    assert!(matches!(
        manager.approve(&read.approval_id),
        Err(FilesystemError::OperationChanged)
    ));
    std::fs::remove_dir_all(workspace).unwrap();
    std::fs::remove_dir_all(outside).unwrap();
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
    std::fs::create_dir_all(&path).unwrap();
    path
}
