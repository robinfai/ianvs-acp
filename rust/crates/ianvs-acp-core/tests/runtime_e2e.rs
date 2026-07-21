use std::collections::BTreeMap;
use std::time::{Duration, Instant};

use ianvs_acp_core::{
    AgentLaunchConfig, McpServerLaunchConfig, PermissionDecision, PromptAttachmentInput,
    RuntimeEvent, RuntimeEventEnvelope, RuntimeHandle, RuntimeStatus, SessionConfigValueProjection,
    SessionUpdateKind,
};

#[test]
#[allow(clippy::too_many_lines)]
fn subprocess_handshake_prompt_permission_and_projection_are_rust_owned() {
    let runtime = RuntimeHandle::new();
    runtime
        .start_agent(AgentLaunchConfig {
            agent_name: "fixture".to_string(),
            command: env!("CARGO_BIN_EXE_ianvs-acp-fixture-agent").to_string(),
            args: vec![],
            environment: BTreeMap::from([
                (
                    "IANVS_FIXTURE_CONFIG_UPDATE_AFTER_NEW".to_string(),
                    "1".to_string(),
                ),
                ("IANVS_FIXTURE_MCP".to_string(), "1".to_string()),
            ]),
            process_cwd: None,
            permission_timeout_ms: None,
            max_restart_attempts: None,
            restart_base_delay_ms: None,
            session_store_path: None,
            additional_directories: vec![],
            mcp_servers: vec![
                McpServerLaunchConfig::Stdio {
                    name: "local-mcp".to_string(),
                    command: "mcp-command".to_string(),
                    args: vec!["--flag".to_string()],
                    environment: BTreeMap::from([("MCP_TOKEN".to_string(), "secret".to_string())]),
                },
                McpServerLaunchConfig::Http {
                    name: "http-mcp".to_string(),
                    url: "https://example.test/mcp".to_string(),
                    headers: BTreeMap::from([(
                        "Authorization".to_string(),
                        "Bearer secret".to_string(),
                    )]),
                },
                McpServerLaunchConfig::Sse {
                    name: "sse-mcp".to_string(),
                    url: "https://example.test/sse".to_string(),
                    headers: BTreeMap::new(),
                },
            ],
            enable_terminal_provider: false,
            enable_filesystem_read_text_file: false,
            enable_filesystem_write_text_file: false,
            max_terminal_handles: None,
            max_terminal_handles_per_session: None,
            terminal_default_output_byte_limit: None,
            terminal_max_output_byte_limit: None,
        })
        .unwrap();

    let ready = wait_for(&runtime, |event| {
        matches!(
            event,
            RuntimeEvent::StatusChanged {
                status: RuntimeStatus::Ready,
                ..
            }
        )
    });
    match ready.event {
        RuntimeEvent::StatusChanged {
            capabilities: Some(capabilities),
            ..
        } => {
            assert_eq!(capabilities.protocol_version, 1);
            assert!(!capabilities.filesystem_read_text_file);
            assert!(!capabilities.filesystem_write_text_file);
            assert!(capabilities.mcp_http);
            assert!(capabilities.mcp_sse);
        }
        other => panic!("unexpected ready event: {other:?}"),
    }

    runtime
        .create_session(
            "create-1",
            std::env::temp_dir().display().to_string(),
            vec![],
        )
        .unwrap();
    wait_for(&runtime, |event| {
        matches!(
            event,
            RuntimeEvent::SessionUpdate { update }
                if update.kind == SessionUpdateKind::SessionCreated
                    && update.session_id == "fixture-session"
                    && update.request_id.as_deref() == Some("create-1")
        )
    });
    let config_update = wait_for(&runtime, |event| {
        matches!(
            event,
            RuntimeEvent::SessionUpdate { update }
                if update.kind == SessionUpdateKind::ConfigChanged
                    && update.session_id == "fixture-session"
                    && update.request_id.is_none()
        )
    });
    match config_update.event {
        RuntimeEvent::SessionUpdate { update } => assert_eq!(
            update
                .payload
                .as_ref()
                .and_then(|value| value["configOptions"][0]["currentValue"].as_str()),
            Some("quality")
        ),
        other => panic!("unexpected config notification: {other:?}"),
    }

    runtime
        .prompt("prompt-1", "fixture-session", "hello")
        .unwrap();
    let permission = wait_for(&runtime, |event| {
        matches!(event, RuntimeEvent::PermissionRequest { .. })
    });
    let permission_id = match permission.event {
        RuntimeEvent::PermissionRequest { request } => {
            assert_eq!(request.session_id, "fixture-session");
            assert_eq!(request.tool_call_id, "fixture-tool");
            assert_eq!(request.options.len(), 2);
            request.request_id
        }
        other => panic!("unexpected permission event: {other:?}"),
    };
    runtime
        .respond_permission(
            permission_id,
            PermissionDecision::Selected {
                option_id: "allow-once".to_string(),
            },
        )
        .unwrap();

    let message = wait_for(&runtime, |event| {
        matches!(
            event,
            RuntimeEvent::SessionUpdate { update }
                if update.kind == SessionUpdateKind::AgentMessageDelta
        )
    });
    match message.event {
        RuntimeEvent::SessionUpdate { update } => {
            assert_eq!(update.text.as_deref(), Some("permission:allow-once"));
        }
        other => panic!("unexpected message event: {other:?}"),
    }
    wait_for(&runtime, |event| {
        matches!(
            event,
            RuntimeEvent::SessionUpdate { update }
                if update.kind == SessionUpdateKind::PromptCompleted
                    && update.request_id.as_deref() == Some("prompt-1")
        )
    });

    runtime.dispose().unwrap();
    wait_for(&runtime, |event| {
        matches!(
            event,
            RuntimeEvent::StatusChanged {
                status: RuntimeStatus::Disposed,
                ..
            }
        )
    });
}

#[test]
#[allow(clippy::too_many_lines)]
fn prompt_attachments_are_bounded_workspace_scoped_and_typed_by_rust() {
    let cwd = unique_temp_dir("prompt-attachments");
    let outside = unique_temp_dir("prompt-attachments-outside");
    let image = cwd.join("image.png");
    let audio = cwd.join("audio.wav");
    let text = cwd.join("note.txt");
    let binary = cwd.join("data.bin");
    let large = cwd.join("large.bin");
    let escaped = outside.join("escaped.txt");
    std::fs::write(&image, [1_u8, 2, 3]).unwrap();
    std::fs::write(&audio, [4_u8, 5, 6]).unwrap();
    std::fs::write(&text, "hello fixture").unwrap();
    std::fs::write(&binary, [7_u8, 8, 9]).unwrap();
    std::fs::File::create(&large)
        .unwrap()
        .set_len(1024 * 1024 + 1)
        .unwrap();
    std::fs::write(&escaped, "outside").unwrap();

    let runtime = RuntimeHandle::new();
    runtime
        .start_agent(AgentLaunchConfig {
            agent_name: "attachment-fixture".to_string(),
            command: env!("CARGO_BIN_EXE_ianvs-acp-fixture-agent").to_string(),
            args: vec![],
            environment: BTreeMap::from([(
                "IANVS_FIXTURE_PROMPT_ATTACHMENTS".to_string(),
                "1".to_string(),
            )]),
            process_cwd: None,
            permission_timeout_ms: None,
            max_restart_attempts: None,
            restart_base_delay_ms: None,
            session_store_path: None,
            additional_directories: vec![],
            mcp_servers: vec![],
            enable_terminal_provider: false,
            enable_filesystem_read_text_file: false,
            enable_filesystem_write_text_file: false,
            max_terminal_handles: None,
            max_terminal_handles_per_session: None,
            terminal_default_output_byte_limit: None,
            terminal_max_output_byte_limit: None,
        })
        .unwrap();
    let ready = wait_for(&runtime, |event| {
        matches!(
            event,
            RuntimeEvent::StatusChanged {
                status: RuntimeStatus::Ready,
                ..
            }
        )
    });
    match ready.event {
        RuntimeEvent::StatusChanged {
            capabilities: Some(capabilities),
            ..
        } => {
            assert!(capabilities.prompt_image);
            assert!(capabilities.prompt_audio);
            assert!(capabilities.embedded_context);
        }
        other => panic!("unexpected ready event: {other:?}"),
    }
    runtime
        .create_session("attachment-create", cwd.display().to_string(), vec![])
        .unwrap();
    wait_for(&runtime, |event| {
        matches!(
            event,
            RuntimeEvent::SessionUpdate { update }
                if update.kind == SessionUpdateKind::SessionCreated
        )
    });

    let attachment = |path: &std::path::Path, name: &str, mime_type: &str| PromptAttachmentInput {
        path: path.display().to_string(),
        name: name.to_string(),
        mime_type: Some(mime_type.to_string()),
        size: Some(std::fs::metadata(path).unwrap().len()),
    };
    runtime
        .prompt_with_attachments(
            "attachment-prompt",
            "fixture-session",
            "inspect",
            vec![
                attachment(&image, "image.png", "image/png"),
                attachment(&audio, "audio.wav", "audio/wav"),
                attachment(&text, "note.txt", "text/plain"),
                attachment(&binary, "data.bin", "application/octet-stream"),
                attachment(&large, "large.bin", "application/octet-stream"),
            ],
        )
        .unwrap();
    let message = wait_for(&runtime, |event| {
        matches!(
            event,
            RuntimeEvent::SessionUpdate { update }
                if update.kind == SessionUpdateKind::AgentMessageDelta
        )
    });
    match message.event {
        RuntimeEvent::SessionUpdate { update } => assert_eq!(
            update.text.as_deref(),
            Some("content:text,image,audio,resource,resource,resource_link")
        ),
        other => panic!("unexpected attachment response: {other:?}"),
    }
    wait_for(&runtime, |event| {
        matches!(
            event,
            RuntimeEvent::SessionUpdate { update }
                if update.kind == SessionUpdateKind::PromptCompleted
        )
    });

    runtime
        .prompt_with_attachments(
            "attachment-escape",
            "fixture-session",
            "escape",
            vec![attachment(&escaped, "escaped.txt", "text/plain")],
        )
        .unwrap();
    wait_for(&runtime, |event| {
        matches!(
            event,
            RuntimeEvent::RuntimeError {
                request_id: Some(request_id),
                code,
                ..
            } if request_id == "attachment-escape" && code == "invalid_prompt_attachment"
        )
    });
    runtime.dispose().unwrap();
    std::fs::remove_dir_all(&cwd).unwrap();
    std::fs::remove_dir_all(&outside).unwrap();
}

#[test]
#[allow(clippy::too_many_lines)]
fn filesystem_reverse_requests_use_permissions_and_core_scope() {
    let workspace = unique_temp_dir("filesystem-runtime");
    std::fs::write(workspace.join("input.txt"), "first\nsecond\nthird\n").unwrap();
    let output = workspace.join("output.txt");
    let runtime = RuntimeHandle::new();
    runtime
        .start_agent(AgentLaunchConfig {
            agent_name: "filesystem-fixture".to_string(),
            command: env!("CARGO_BIN_EXE_ianvs-acp-fixture-agent").to_string(),
            args: vec![],
            environment: BTreeMap::from([(
                "IANVS_FIXTURE_USE_FILESYSTEM".to_string(),
                "1".to_string(),
            )]),
            process_cwd: None,
            permission_timeout_ms: None,
            max_restart_attempts: None,
            restart_base_delay_ms: None,
            session_store_path: None,
            additional_directories: vec![],
            mcp_servers: vec![],
            enable_terminal_provider: false,
            enable_filesystem_read_text_file: true,
            enable_filesystem_write_text_file: true,
            max_terminal_handles: None,
            max_terminal_handles_per_session: None,
            terminal_default_output_byte_limit: None,
            terminal_max_output_byte_limit: None,
        })
        .unwrap();
    let ready = wait_for(&runtime, |event| {
        matches!(
            event,
            RuntimeEvent::StatusChanged {
                status: RuntimeStatus::Ready,
                ..
            }
        )
    });
    match ready.event {
        RuntimeEvent::StatusChanged {
            capabilities: Some(capabilities),
            ..
        } => {
            assert!(capabilities.filesystem_read_text_file);
            assert!(capabilities.filesystem_write_text_file);
        }
        other => panic!("unexpected ready event: {other:?}"),
    }
    runtime
        .create_session("filesystem-create", workspace.display().to_string(), vec![])
        .unwrap();
    wait_for(&runtime, |event| {
        matches!(
            event,
            RuntimeEvent::SessionUpdate { update }
                if update.kind == SessionUpdateKind::SessionCreated
        )
    });
    runtime
        .prompt("filesystem-prompt", "fixture-session", "use filesystem")
        .unwrap();

    let read_permission = wait_for(&runtime, |event| {
        matches!(event, RuntimeEvent::PermissionRequest { request }
            if request.tool_kind == "read")
    });
    let read_request_id = match read_permission.event {
        RuntimeEvent::PermissionRequest { request } => {
            assert_eq!(request.title, "Read file");
            assert_eq!(request.options[0].kind, "allow_once");
            request.request_id
        }
        other => panic!("unexpected read permission: {other:?}"),
    };
    assert!(!output.exists());
    runtime
        .respond_permission(
            read_request_id,
            PermissionDecision::Selected {
                option_id: "ianvs_filesystem_allow_once".to_string(),
            },
        )
        .unwrap();

    let write_permission = wait_for(&runtime, |event| {
        matches!(event, RuntimeEvent::PermissionRequest { request }
            if request.tool_kind == "edit")
    });
    let write_request_id = match write_permission.event {
        RuntimeEvent::PermissionRequest { request } => {
            assert_eq!(request.title, "Write file");
            request.request_id
        }
        other => panic!("unexpected write permission: {other:?}"),
    };
    assert!(!output.exists());
    runtime
        .respond_permission(
            write_request_id,
            PermissionDecision::Selected {
                option_id: "ianvs_filesystem_allow_once".to_string(),
            },
        )
        .unwrap();
    let message = wait_for(&runtime, |event| {
        matches!(
            event,
            RuntimeEvent::SessionUpdate { update }
                if update.kind == SessionUpdateKind::AgentMessageDelta
        )
    });
    match message.event {
        RuntimeEvent::SessionUpdate { update } => {
            assert_eq!(update.text.as_deref(), Some("filesystem:second"));
        }
        other => panic!("unexpected filesystem response: {other:?}"),
    }
    wait_for(&runtime, |event| {
        matches!(
            event,
            RuntimeEvent::SessionUpdate { update }
                if update.kind == SessionUpdateKind::PromptCompleted
        )
    });
    assert_eq!(std::fs::read_to_string(&output).unwrap(), "copy:second\n");
    runtime.dispose().unwrap();
    std::fs::remove_dir_all(workspace).unwrap();
}

#[test]
fn permission_timeout_is_resolved_and_projected_by_rust() {
    let runtime = RuntimeHandle::new();
    runtime
        .start_agent(AgentLaunchConfig {
            agent_name: "fixture".to_string(),
            command: env!("CARGO_BIN_EXE_ianvs-acp-fixture-agent").to_string(),
            args: vec![],
            environment: BTreeMap::default(),
            process_cwd: None,
            permission_timeout_ms: Some(50),
            max_restart_attempts: None,
            restart_base_delay_ms: None,
            session_store_path: None,
            additional_directories: vec![],
            mcp_servers: vec![],
            enable_terminal_provider: false,
            enable_filesystem_read_text_file: false,
            enable_filesystem_write_text_file: false,
            max_terminal_handles: None,
            max_terminal_handles_per_session: None,
            terminal_default_output_byte_limit: None,
            terminal_max_output_byte_limit: None,
        })
        .unwrap();
    wait_for(&runtime, |event| {
        matches!(
            event,
            RuntimeEvent::StatusChanged {
                status: RuntimeStatus::Ready,
                ..
            }
        )
    });
    runtime
        .create_session(
            "create-timeout",
            std::env::temp_dir().display().to_string(),
            vec![],
        )
        .unwrap();
    wait_for(&runtime, |event| {
        matches!(
            event,
            RuntimeEvent::SessionUpdate { update }
                if update.kind == SessionUpdateKind::SessionCreated
        )
    });
    runtime
        .prompt("prompt-timeout", "fixture-session", "hello")
        .unwrap();
    let permission = wait_for(&runtime, |event| {
        matches!(event, RuntimeEvent::PermissionRequest { .. })
    });
    let permission_id = match permission.event {
        RuntimeEvent::PermissionRequest { request } => request.request_id,
        other => panic!("unexpected permission event: {other:?}"),
    };
    let invalidated = wait_for(&runtime, |event| {
        matches!(
            event,
            RuntimeEvent::SessionUpdate { update }
                if update.kind == SessionUpdateKind::PermissionInvalidated
                    && update.request_id.as_deref() == Some(permission_id.as_str())
        )
    });
    match invalidated.event {
        RuntimeEvent::SessionUpdate { update } => {
            assert_eq!(
                update.payload,
                Some(serde_json::json!({ "reason": "timed_out" }))
            );
        }
        other => panic!("unexpected invalidation event: {other:?}"),
    }
    wait_for(&runtime, |event| {
        matches!(
            event,
            RuntimeEvent::SessionUpdate { update }
                if update.kind == SessionUpdateKind::PromptCompleted
                    && update.payload == Some(serde_json::json!({ "stopReason": "end_turn" }))
        )
    });
    runtime.dispose().unwrap();
}

#[test]
fn idle_agent_process_is_restarted_before_session_activity() {
    let directory = unique_temp_dir("restart");
    let marker = directory.join("failed-once");
    let runtime = RuntimeHandle::new();
    runtime
        .start_agent(AgentLaunchConfig {
            agent_name: "flaky-fixture".to_string(),
            command: env!("CARGO_BIN_EXE_ianvs-acp-fixture-agent").to_string(),
            args: vec![],
            environment: BTreeMap::from([(
                "IANVS_FIXTURE_FAIL_ONCE_FILE".to_string(),
                marker.display().to_string(),
            )]),
            process_cwd: None,
            permission_timeout_ms: None,
            max_restart_attempts: Some(2),
            restart_base_delay_ms: Some(10),
            session_store_path: None,
            additional_directories: vec![],
            mcp_servers: vec![],
            enable_terminal_provider: false,
            enable_filesystem_read_text_file: false,
            enable_filesystem_write_text_file: false,
            max_terminal_handles: None,
            max_terminal_handles_per_session: None,
            terminal_default_output_byte_limit: None,
            terminal_max_output_byte_limit: None,
        })
        .unwrap();
    wait_for(&runtime, |event| {
        matches!(
            event,
            RuntimeEvent::StatusChanged {
                status: RuntimeStatus::Recovering,
                ..
            }
        )
    });
    wait_for(&runtime, |event| {
        matches!(
            event,
            RuntimeEvent::StatusChanged {
                status: RuntimeStatus::Ready,
                ..
            }
        )
    });
    assert!(marker.exists());
    runtime.dispose().unwrap();
    std::fs::remove_dir_all(directory).unwrap();
}

#[test]
fn process_loss_after_session_activity_restores_durable_session() {
    let directory = unique_temp_dir("session-recovery");
    let database = directory.join("sessions.sqlite3");
    let runtime = RuntimeHandle::new();
    runtime
        .start_agent(AgentLaunchConfig {
            agent_name: "session-fixture".to_string(),
            command: env!("CARGO_BIN_EXE_ianvs-acp-fixture-agent").to_string(),
            args: vec![],
            environment: BTreeMap::from([(
                "IANVS_FIXTURE_EXIT_AFTER_NEW_SESSION".to_string(),
                "1".to_string(),
            )]),
            process_cwd: None,
            permission_timeout_ms: None,
            max_restart_attempts: Some(2),
            restart_base_delay_ms: Some(10),
            session_store_path: Some(database.display().to_string()),
            additional_directories: vec![],
            mcp_servers: vec![],
            enable_terminal_provider: false,
            enable_filesystem_read_text_file: false,
            enable_filesystem_write_text_file: false,
            max_terminal_handles: None,
            max_terminal_handles_per_session: None,
            terminal_default_output_byte_limit: None,
            terminal_max_output_byte_limit: None,
        })
        .unwrap();
    wait_for(&runtime, |event| {
        matches!(
            event,
            RuntimeEvent::StatusChanged {
                status: RuntimeStatus::Ready,
                ..
            }
        )
    });
    runtime
        .create_session(
            "create-before-exit",
            std::env::temp_dir().display().to_string(),
            vec![],
        )
        .unwrap();
    wait_for(&runtime, |event| {
        matches!(
            event,
            RuntimeEvent::SessionUpdate { update }
                if update.kind == SessionUpdateKind::SessionCreated
        )
    });
    wait_for(&runtime, |event| {
        matches!(
            event,
            RuntimeEvent::StatusChanged {
                status: RuntimeStatus::Recovering,
                ..
            }
        )
    });
    let restored = wait_for(&runtime, |event| {
        matches!(
            event,
            RuntimeEvent::SessionUpdate { update }
                if update.kind == SessionUpdateKind::SessionRestored
                    && update.session_id == "fixture-session"
                    && update.request_id.is_none()
        )
    });
    match restored.event {
        RuntimeEvent::SessionUpdate { update } => assert_eq!(
            update
                .payload
                .as_ref()
                .and_then(|payload| payload["recoveredAfterRestart"].as_bool()),
            Some(true)
        ),
        other => panic!("unexpected recovery event: {other:?}"),
    }
    wait_for(&runtime, |event| {
        matches!(
            event,
            RuntimeEvent::StatusChanged {
                status: RuntimeStatus::Ready,
                ..
            }
        )
    });
    runtime
        .prompt("prompt-after-recovery", "fixture-session", "hello again")
        .unwrap();
    wait_for(&runtime, |event| {
        matches!(event, RuntimeEvent::PermissionRequest { .. })
    });
    runtime.dispose().unwrap();
    let store = ianvs_acp_core::SqliteSessionStore::open(&database).unwrap();
    assert_eq!(store.load_active("session-fixture").unwrap().len(), 1);
    std::fs::remove_dir_all(directory).unwrap();
}

#[test]
fn durable_session_registry_survives_runtime_handle_recreation() {
    let directory = unique_temp_dir("session-recovery-reopen");
    let database = directory.join("sessions.sqlite3");
    let config = AgentLaunchConfig {
        agent_name: "durable-session-fixture".to_string(),
        command: env!("CARGO_BIN_EXE_ianvs-acp-fixture-agent").to_string(),
        args: vec![],
        environment: BTreeMap::new(),
        process_cwd: None,
        permission_timeout_ms: None,
        max_restart_attempts: Some(2),
        restart_base_delay_ms: Some(10),
        session_store_path: Some(database.display().to_string()),
        additional_directories: vec![],
        mcp_servers: vec![],
        enable_terminal_provider: false,
        enable_filesystem_read_text_file: false,
        enable_filesystem_write_text_file: false,
        max_terminal_handles: None,
        max_terminal_handles_per_session: None,
        terminal_default_output_byte_limit: None,
        terminal_max_output_byte_limit: None,
    };
    let first = RuntimeHandle::new();
    first.start_agent(config.clone()).unwrap();
    wait_for(&first, |event| {
        matches!(
            event,
            RuntimeEvent::StatusChanged {
                status: RuntimeStatus::Ready,
                ..
            }
        )
    });
    first
        .create_session(
            "create-durable",
            std::env::temp_dir().display().to_string(),
            vec![],
        )
        .unwrap();
    wait_for(&first, |event| {
        matches!(
            event,
            RuntimeEvent::SessionUpdate { update }
                if update.kind == SessionUpdateKind::SessionCreated
        )
    });
    first.dispose().unwrap();

    let marker = directory.join("fail-once-after-reopen");
    let mut restart_config = config;
    restart_config.environment.insert(
        "IANVS_FIXTURE_FAIL_ONCE_FILE".to_string(),
        marker.display().to_string(),
    );
    let second = RuntimeHandle::new();
    second.start_agent(restart_config).unwrap();
    wait_for(&second, |event| {
        matches!(
            event,
            RuntimeEvent::StatusChanged {
                status: RuntimeStatus::Recovering,
                ..
            }
        )
    });
    wait_for(&second, |event| {
        matches!(
            event,
            RuntimeEvent::SessionUpdate { update }
                if update.kind == SessionUpdateKind::SessionRestored
                    && update.session_id == "fixture-session"
                    && update.request_id.is_none()
        )
    });
    wait_for(&second, |event| {
        matches!(
            event,
            RuntimeEvent::StatusChanged {
                status: RuntimeStatus::Ready,
                ..
            }
        )
    });
    second.dispose().unwrap();
    std::fs::remove_dir_all(directory).unwrap();
}

#[test]
#[allow(clippy::too_many_lines)]
fn session_catalog_restore_close_and_delete_are_rust_owned() {
    let runtime = RuntimeHandle::new();
    runtime
        .start_agent(AgentLaunchConfig {
            agent_name: "session-lifecycle-fixture".to_string(),
            command: env!("CARGO_BIN_EXE_ianvs-acp-fixture-agent").to_string(),
            args: vec![],
            environment: BTreeMap::default(),
            process_cwd: None,
            permission_timeout_ms: None,
            max_restart_attempts: None,
            restart_base_delay_ms: None,
            session_store_path: None,
            additional_directories: vec![],
            mcp_servers: vec![],
            enable_terminal_provider: false,
            enable_filesystem_read_text_file: false,
            enable_filesystem_write_text_file: false,
            max_terminal_handles: None,
            max_terminal_handles_per_session: None,
            terminal_default_output_byte_limit: None,
            terminal_max_output_byte_limit: None,
        })
        .unwrap();
    let ready = wait_for(&runtime, |event| {
        matches!(
            event,
            RuntimeEvent::StatusChanged {
                status: RuntimeStatus::Ready,
                ..
            }
        )
    });
    match ready.event {
        RuntimeEvent::StatusChanged {
            capabilities: Some(capabilities),
            ..
        } => {
            assert!(capabilities.load_session);
            assert!(capabilities.list_sessions);
            assert!(capabilities.resume_session);
            assert!(capabilities.close_session);
            assert!(capabilities.delete_session);
            assert!(capabilities.logout);
            assert_eq!(capabilities.auth_methods[0].id, "fixture-auth");
        }
        other => panic!("unexpected ready event: {other:?}"),
    }

    runtime.list_sessions("list-1").unwrap();
    let catalog = wait_for(&runtime, |event| {
        matches!(
            event,
            RuntimeEvent::SessionCatalog { request_id, .. }
                if request_id == "list-1"
        )
    });
    match catalog.event {
        RuntimeEvent::SessionCatalog { sessions, .. } => {
            assert_eq!(sessions.len(), 1);
            assert_eq!(sessions[0].session_id, "fixture-session");
            assert_eq!(sessions[0].title.as_deref(), Some("Fixture session"));
            assert!(std::path::Path::new(&sessions[0].cwd).is_absolute());
        }
        other => panic!("unexpected catalog event: {other:?}"),
    }

    runtime.authenticate("auth-1", "fixture-auth").unwrap();
    wait_for(&runtime, |event| {
        matches!(
            event,
            RuntimeEvent::AuthenticationChanged {
                request_id,
                authenticated: true,
                method_id: Some(method_id),
            } if request_id == "auth-1" && method_id == "fixture-auth"
        )
    });
    runtime.logout("logout-1").unwrap();
    wait_for(&runtime, |event| {
        matches!(
            event,
            RuntimeEvent::AuthenticationChanged {
                request_id,
                authenticated: false,
                method_id: None,
            } if request_id == "logout-1"
        )
    });

    let cwd = std::env::temp_dir().canonicalize().unwrap();
    runtime
        .restore_session(
            "restore-1",
            "fixture-session",
            cwd.display().to_string(),
            vec![],
        )
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut history = false;
    let mut restored = false;
    while Instant::now() < deadline && !(history && restored) {
        let Some(event) = runtime
            .recv_event_timeout(Duration::from_millis(250))
            .unwrap()
        else {
            continue;
        };
        if let RuntimeEvent::SessionUpdate { update } = event.event {
            if update.kind == SessionUpdateKind::AgentMessageDelta {
                assert_eq!(update.text.as_deref(), Some("loaded fixture history"));
                history = true;
            } else if update.kind == SessionUpdateKind::SessionRestored {
                assert_eq!(update.request_id.as_deref(), Some("restore-1"));
                assert_eq!(
                    update
                        .payload
                        .as_ref()
                        .and_then(|value| value["replayedHistory"].as_bool()),
                    Some(true)
                );
                assert_eq!(
                    update
                        .payload
                        .as_ref()
                        .and_then(|value| value["configOptions"][0]["currentValue"].as_str()),
                    Some("fast")
                );
                restored = true;
            }
        }
    }
    assert!(history && restored);

    runtime
        .set_config_option(
            "config-invalid",
            "fixture-session",
            "model",
            SessionConfigValueProjection::ValueId {
                value: "not-advertised".to_string(),
            },
        )
        .unwrap();
    wait_for(&runtime, |event| {
        matches!(
            event,
            RuntimeEvent::RuntimeError {
                request_id: Some(request_id),
                code,
                recoverable: true,
                ..
            } if request_id == "config-invalid" && code == "invalid_config_value"
        )
    });

    runtime
        .set_config_option(
            "config-1",
            "fixture-session",
            "model",
            SessionConfigValueProjection::ValueId {
                value: "quality".to_string(),
            },
        )
        .unwrap();
    let config_changed = wait_for(&runtime, |event| {
        matches!(
            event,
            RuntimeEvent::SessionUpdate { update }
                if update.kind == SessionUpdateKind::ConfigChanged
                    && update.request_id.as_deref() == Some("config-1")
        )
    });
    match config_changed.event {
        RuntimeEvent::SessionUpdate { update } => assert_eq!(
            update
                .payload
                .as_ref()
                .and_then(|value| value["configOptions"][0]["currentValue"].as_str()),
            Some("quality")
        ),
        other => panic!("unexpected config event: {other:?}"),
    }

    runtime.close_session("close-1", "fixture-session").unwrap();
    wait_for(&runtime, |event| {
        matches!(
            event,
            RuntimeEvent::SessionUpdate { update }
                if update.kind == SessionUpdateKind::SessionClosed
                    && update.request_id.as_deref() == Some("close-1")
        )
    });
    runtime
        .delete_session("delete-1", "fixture-session")
        .unwrap();
    wait_for(&runtime, |event| {
        matches!(
            event,
            RuntimeEvent::SessionUpdate { update }
                if update.kind == SessionUpdateKind::SessionDeleted
                    && update.request_id.as_deref() == Some("delete-1")
        )
    });
    runtime.dispose().unwrap();
}

#[test]
#[allow(clippy::too_many_lines)]
fn terminal_reverse_requests_use_real_pty_and_generic_permissions() {
    let runtime = RuntimeHandle::new();
    runtime
        .start_agent(AgentLaunchConfig {
            agent_name: "terminal-fixture".to_string(),
            command: env!("CARGO_BIN_EXE_ianvs-acp-fixture-agent").to_string(),
            args: vec![],
            environment: BTreeMap::from([(
                "IANVS_FIXTURE_USE_TERMINAL".to_string(),
                "1".to_string(),
            )]),
            process_cwd: None,
            permission_timeout_ms: None,
            max_restart_attempts: None,
            restart_base_delay_ms: None,
            session_store_path: None,
            additional_directories: vec![],
            mcp_servers: vec![],
            enable_terminal_provider: true,
            enable_filesystem_read_text_file: false,
            enable_filesystem_write_text_file: false,
            max_terminal_handles: Some(2),
            max_terminal_handles_per_session: Some(1),
            terminal_default_output_byte_limit: Some(64),
            terminal_max_output_byte_limit: Some(128),
        })
        .unwrap();

    let ready = wait_for(&runtime, |event| {
        matches!(
            event,
            RuntimeEvent::StatusChanged {
                status: RuntimeStatus::Ready,
                ..
            }
        )
    });
    match ready.event {
        RuntimeEvent::StatusChanged {
            capabilities: Some(capabilities),
            ..
        } => assert!(capabilities.terminal),
        other => panic!("unexpected ready event: {other:?}"),
    }

    let cwd = std::env::temp_dir().canonicalize().unwrap();
    runtime
        .create_session("create-terminal", cwd.display().to_string(), vec![])
        .unwrap();
    wait_for(&runtime, |event| {
        matches!(
            event,
            RuntimeEvent::SessionUpdate { update }
                if update.kind == SessionUpdateKind::SessionCreated
        )
    });
    runtime
        .prompt("prompt-terminal", "fixture-session", "use terminal")
        .unwrap();
    let permission = wait_for(&runtime, |event| {
        matches!(event, RuntimeEvent::PermissionRequest { .. })
    });
    let permission_id = match permission.event {
        RuntimeEvent::PermissionRequest { request } => {
            assert_eq!(request.tool_kind, "execute");
            assert!(request.tool_call_id.starts_with("terminal:"));
            assert_eq!(request.options[0].option_id, "ianvs_terminal_allow_once");
            assert_eq!(
                request.raw_input,
                Some(serde_json::json!({
                    "command": "/bin/echo",
                    "args": ["fixture-terminal"],
                    "cwd": cwd.display().to_string(),
                }))
            );
            request.request_id
        }
        other => panic!("unexpected permission event: {other:?}"),
    };
    runtime
        .respond_permission(
            permission_id,
            PermissionDecision::Selected {
                option_id: "ianvs_terminal_allow_once".to_string(),
            },
        )
        .unwrap();

    let deadline = Instant::now() + Duration::from_secs(10);
    let mut attached = false;
    let mut output = false;
    let mut exited = false;
    let mut released = false;
    let mut message = false;
    let mut completed = false;
    let mut observed = Vec::new();
    while Instant::now() < deadline
        && !(attached && output && exited && released && message && completed)
    {
        let Some(event) = runtime
            .recv_event_timeout(Duration::from_millis(250))
            .unwrap()
        else {
            continue;
        };
        match &event.event {
            RuntimeEvent::TerminalAttached {
                session_id,
                command,
                cwd: terminal_cwd,
                ..
            } => {
                assert_eq!(session_id, "fixture-session");
                assert_eq!(command, &["/bin/echo", "fixture-terminal"]);
                assert_eq!(terminal_cwd, &cwd.display().to_string());
                attached = true;
            }
            RuntimeEvent::TerminalOutput { data, .. } => {
                output |= data.contains("fixture-terminal");
            }
            RuntimeEvent::TerminalExited { exit, .. } => {
                assert_eq!(exit.exit_code, Some(0));
                exited = true;
            }
            RuntimeEvent::TerminalReleased { .. } => released = true,
            RuntimeEvent::SessionUpdate { update }
                if update.kind == SessionUpdateKind::AgentMessageDelta =>
            {
                assert_eq!(
                    update.text.as_deref(),
                    Some("terminal:fixture-terminal:0:false")
                );
                message = true;
            }
            RuntimeEvent::SessionUpdate { update }
                if update.kind == SessionUpdateKind::PromptCompleted =>
            {
                completed = true;
            }
            _ => observed.push(event),
        }
    }
    assert!(
        attached && output && exited && released && message && completed,
        "missing terminal lifecycle event; observed: {observed:#?}"
    );
    runtime.dispose().unwrap();
}

fn wait_for(
    runtime: &RuntimeHandle,
    predicate: impl Fn(&RuntimeEvent) -> bool,
) -> RuntimeEventEnvelope {
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut observed = Vec::new();
    while Instant::now() < deadline {
        match runtime
            .recv_event_timeout(Duration::from_millis(250))
            .unwrap()
        {
            Some(event) if predicate(&event.event) => return event,
            Some(event) => observed.push(event),
            None => {}
        }
    }
    panic!("timed out waiting for runtime event; observed: {observed:#?}");
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
