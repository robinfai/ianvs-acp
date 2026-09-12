use ianvs_acp_core::{
    FilesystemConfig, FilesystemError, FilesystemManager, FilesystemOperationKind,
    FilesystemOperationResult, WorkspaceScope,
};
use std::os::unix::fs::{PermissionsExt, symlink};

#[test]
fn filesystem_read_and_write_use_pending_permission_operations() {
    let workspace = unique_temp_dir("filesystem-core");
    let input = workspace.join("input.txt");
    std::fs::write(&input, "first\nsecond\nthird\n").unwrap();
    let manager = FilesystemManager::new(FilesystemConfig {
        read_text_file: true,
        write_text_file: true,
        allow_read_outside_workspace: false,
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
        allow_read_outside_workspace: false,
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

#[test]
fn filesystem_write_pins_the_approved_parent_directory_against_symlink_replacement() {
    let workspace = unique_temp_dir("filesystem-parent-swap");
    let outside = unique_temp_dir("filesystem-parent-swap-outside");
    let approved_parent = workspace.join("approved");
    let moved_parent = workspace.join("approved-before-swap");
    std::fs::create_dir(&approved_parent).unwrap();
    let manager = FilesystemManager::new(FilesystemConfig {
        read_text_file: false,
        write_text_file: true,
        allow_read_outside_workspace: false,
    });
    manager
        .register_session(
            "session-1",
            WorkspaceScope::new(&workspace, std::iter::empty::<&std::path::Path>()).unwrap(),
        )
        .unwrap();

    let approval = manager
        .request_write(
            "session-1",
            &approved_parent.join("output.txt"),
            "safe".into(),
        )
        .unwrap();
    std::fs::rename(&approved_parent, &moved_parent).unwrap();
    symlink(&outside, &approved_parent).unwrap();

    assert!(matches!(
        manager.approve(&approval.approval_id),
        Err(FilesystemError::OperationChanged)
    ));
    assert!(!outside.join("output.txt").exists());
    assert!(!moved_parent.join("output.txt").exists());
    std::fs::remove_dir_all(workspace).unwrap();
    std::fs::remove_dir_all(outside).unwrap();
}

#[test]
fn filesystem_atomic_write_preserves_existing_permissions_and_honors_umask_for_new_files() {
    let workspace = unique_temp_dir("filesystem-write-mode");
    let existing = workspace.join("executable.sh");
    let created = workspace.join("created.txt");
    let mode_probe = workspace.join("mode-probe.txt");
    std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&mode_probe)
        .unwrap();
    let expected_new_mode = std::fs::metadata(&mode_probe).unwrap().permissions().mode() & 0o777;
    std::fs::remove_file(mode_probe).unwrap();
    std::fs::write(&existing, "old").unwrap();
    std::fs::set_permissions(&existing, std::fs::Permissions::from_mode(0o751)).unwrap();
    let manager = FilesystemManager::new(FilesystemConfig {
        read_text_file: false,
        write_text_file: true,
        allow_read_outside_workspace: false,
    });
    manager
        .register_session(
            "session-1",
            WorkspaceScope::new(&workspace, std::iter::empty::<&std::path::Path>()).unwrap(),
        )
        .unwrap();

    for (path, content) in [(&existing, "replacement"), (&created, "new")] {
        let approval = manager
            .request_write("session-1", path, content.to_string())
            .unwrap();
        assert_eq!(
            manager.approve(&approval.approval_id).unwrap(),
            FilesystemOperationResult::Written
        );
    }

    assert_eq!(std::fs::read_to_string(&existing).unwrap(), "replacement");
    assert_eq!(
        std::fs::metadata(&existing).unwrap().permissions().mode() & 0o777,
        0o751
    );
    assert_eq!(std::fs::read_to_string(&created).unwrap(), "new");
    assert_eq!(
        std::fs::metadata(&created).unwrap().permissions().mode() & 0o777,
        expected_new_mode
    );
    std::fs::remove_dir_all(workspace).unwrap();
}

#[test]
fn outside_reads_require_explicit_policy_and_keep_write_roots_unchanged() {
    let root = unique_temp_dir("filesystem-read-policy");
    let workspace = root.join("workspace");
    std::fs::create_dir(&workspace).unwrap();
    let outside = root.join("outside.txt");
    std::fs::write(&outside, "first\nsecond\n").unwrap();
    symlink(&outside, workspace.join("linked.txt")).unwrap();
    let scope = WorkspaceScope::new(&workspace, std::iter::empty::<&std::path::Path>()).unwrap();

    for allow in [false, true] {
        let manager = FilesystemManager::new(FilesystemConfig {
            read_text_file: true,
            write_text_file: true,
            allow_read_outside_workspace: allow,
        });
        manager.register_session("session", scope.clone()).unwrap();
        for path in [
            outside.clone(),
            "../outside.txt".into(),
            "linked.txt".into(),
        ] {
            let result = manager.request_read("session", &path, Some(2), Some(1));
            if allow {
                let request = result.unwrap();
                assert_eq!(
                    request.path,
                    outside.canonicalize().unwrap().display().to_string()
                );
                assert_eq!(request.content_preview, None);
                assert_eq!(
                    manager.approve(&request.approval_id).unwrap(),
                    FilesystemOperationResult::Read("second\n".to_string())
                );
            } else {
                assert!(matches!(result, Err(FilesystemError::Workspace(_))));
            }
            assert!(matches!(
                manager.request_write("session", &path, "no".into()),
                Err(FilesystemError::Workspace(_))
            ));
        }
        if allow {
            let denied = manager
                .request_read("session", &outside, None, None)
                .unwrap();
            manager.deny(&denied.approval_id).unwrap();
            assert!(matches!(
                manager.approve(&denied.approval_id),
                Err(FilesystemError::UnknownApproval(_))
            ));
        }
    }
    // Read access never mutates the roots used by other workspace operations.
    assert!(scope.resolve_existing(&outside).is_err());
    assert_eq!(
        std::fs::read_to_string(&outside).unwrap(),
        "first\nsecond\n"
    );
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn outside_policy_does_not_enable_a_disabled_reader_or_skip_session_admission() {
    let root = unique_temp_dir("filesystem-read-disabled");
    let file = root.join("input.txt");
    std::fs::write(&file, "text").unwrap();
    for read_text_file in [false, true] {
        let manager = FilesystemManager::new(FilesystemConfig {
            read_text_file,
            write_text_file: false,
            allow_read_outside_workspace: true,
        });
        let result = manager.request_read("unknown", &file, None, None);
        if read_text_file {
            assert!(matches!(result, Err(FilesystemError::UnknownSession(_))));
        } else {
            assert!(matches!(result, Err(FilesystemError::ReadDisabled)));
        }
    }
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn outside_reads_retain_limits_and_revalidate_the_approved_file() {
    let root = unique_temp_dir("filesystem-read-outside-identity");
    let workspace = root.join("workspace");
    std::fs::create_dir(&workspace).unwrap();
    let file = root.join("input.txt");
    let manager = FilesystemManager::new(FilesystemConfig {
        read_text_file: true,
        write_text_file: false,
        allow_read_outside_workspace: true,
    });
    manager
        .register_session(
            "session",
            WorkspaceScope::new(&workspace, std::iter::empty::<&std::path::Path>()).unwrap(),
        )
        .unwrap();
    assert!(matches!(
        manager.request_read("session", &root, None, None),
        Err(FilesystemError::NotRegularFile(_))
    ));
    std::fs::write(&file, [0xff]).unwrap();
    let invalid = manager.request_read("session", &file, None, None).unwrap();
    assert!(matches!(
        manager.approve(&invalid.approval_id),
        Err(FilesystemError::InvalidUtf8)
    ));
    std::fs::File::create(&file)
        .unwrap()
        .set_len(8 * 1024 * 1024 + 1)
        .unwrap();
    assert!(matches!(
        manager.request_read("session", &file, None, None),
        Err(FilesystemError::ReadLimit)
    ));

    std::fs::write(&file, "before").unwrap();
    let replaced = manager.request_read("session", &file, None, None).unwrap();
    std::fs::rename(&file, root.join("original.txt")).unwrap();
    std::fs::write(&file, "secret").unwrap();
    assert!(matches!(
        manager.approve(&replaced.approval_id),
        Err(FilesystemError::OperationChanged)
    ));
    let redirected = manager.request_read("session", &file, None, None).unwrap();
    std::fs::remove_file(&file).unwrap();
    symlink(root.join("original.txt"), &file).unwrap();
    assert!(matches!(
        manager.approve(&redirected.approval_id),
        Err(FilesystemError::OperationChanged)
    ));
    std::fs::remove_dir_all(root).unwrap();
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
