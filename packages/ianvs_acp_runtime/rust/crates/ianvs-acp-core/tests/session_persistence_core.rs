use ianvs_acp_core::{PersistedSession, SqliteSessionStore, WorkspaceScope};

#[test]
fn durable_session_registry_round_trips_scoped_records() {
    let directory = unique_temp_dir("session-registry");
    let workspace = directory.join("workspace");
    let additional = directory.join("additional");
    std::fs::create_dir_all(&workspace).unwrap();
    std::fs::create_dir_all(&additional).unwrap();
    let database = directory.join("sessions.sqlite3");
    let scope = WorkspaceScope::new(
        workspace.display().to_string(),
        &[additional.display().to_string()],
    )
    .unwrap();
    let session = PersistedSession {
        agent_name: "fixture".to_string(),
        session_id: "session-1".to_string(),
        cwd: scope.cwd().display().to_string(),
        additional_directories: scope.roots()[1..]
            .iter()
            .map(|path| path.display().to_string())
            .collect(),
    };

    let mut store = SqliteSessionStore::open(&database).unwrap();
    store.upsert(&session).unwrap();
    drop(store);

    let mut reopened = SqliteSessionStore::open(&database).unwrap();
    assert_eq!(reopened.load_active("fixture").unwrap(), vec![session]);
    reopened.remove("fixture", "session-1").unwrap();
    assert!(reopened.load_active("fixture").unwrap().is_empty());

    std::fs::remove_dir_all(directory).unwrap();
}

#[cfg(unix)]
#[test]
fn session_registry_rejects_symlink_database_targets() {
    use std::os::unix::fs::symlink;

    let directory = unique_temp_dir("session-registry-symlink");
    let target = directory.join("target.sqlite3");
    let link = directory.join("link.sqlite3");
    std::fs::write(&target, []).unwrap();
    symlink(&target, &link).unwrap();

    assert!(SqliteSessionStore::open(&link).is_err());
    std::fs::remove_dir_all(directory).unwrap();
}

fn unique_temp_dir(label: &str) -> std::path::PathBuf {
    let path = std::env::temp_dir().join(format!("ianvs-{label}-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&path).unwrap();
    path
}
