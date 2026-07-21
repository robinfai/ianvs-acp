use std::collections::BTreeMap;
use std::fs;

use ianvs_acp_core::{
    DurableWorkflow, ExecutionError, ExecutorCommandContext, ExecutorLeaseCommand,
    ExecutorLeaseOperation, ExecutorTaskInboxCommand, InboxEventKind, InboxEventRecord,
    MAX_RUNTIME_EVENT_APPEND_BATCH, MAX_RUNTIME_EVENT_QUERY_LIMIT, SchedulerCapacityReservation,
    SchedulerClaimRequest, SchedulerRuntimeAvailability, SchedulerRuntimeStatus, TaskInboxCommand,
    TaskInboxRunTransition, TaskInboxSnapshot, WORKFLOW_SNAPSHOT_RETENTION, WorkflowStoreError,
};
use rusqlite::Connection;

#[test]
#[allow(clippy::too_many_lines)]
fn events_append_without_rewriting_checkpoint_and_reconnect_by_sequence() {
    let directory = unique_temp_dir("event-store");
    let workspace = directory.join("workspace");
    fs::create_dir(&workspace).unwrap();
    let database = directory.join("workflow.sqlite3");
    let source: TaskInboxSnapshot = serde_json::from_value(serde_json::json!({
        "schema": "ianvs-acp.task-inbox.v1",
        "updated_at": "2026-07-21T10:00:00.000Z",
        "tasks": [{
            "id": "task-1",
            "title": "Event store",
            "description": "append-only fixture",
            "workspace_path": workspace,
            "agent_name": "agent-a",
            "status": "queued",
            "priority": "normal",
            "created_at": "2026-07-21T09:00:00.000Z",
            "updated_at": "2026-07-21T10:00:00.000Z",
            "metadata": {}
        }],
        "runs": [],
        "events": [],
        "artifacts": [],
        "approvals": [],
        "resources": []
    }))
    .unwrap();
    let mut workflow = DurableWorkflow::open(&database).unwrap();
    workflow
        .stage_task_inbox_import(&source, "sha256:event-store")
        .unwrap();
    workflow.materialize_task_inbox().unwrap();
    workflow.activate_task_inbox().unwrap();
    workflow
        .set_scheduler_runtime_status(SchedulerRuntimeStatus {
            agent_name: "agent-a".to_string(),
            availability: SchedulerRuntimeAvailability::Available,
            observed_at: "2026-07-21T10:00:00.000Z".to_string(),
            unavailable_reason: None,
            supports_session_resume: true,
            supports_permissions: true,
            max_concurrent_tasks: 1,
        })
        .unwrap();
    workflow.scheduler_claim_next(claim_request()).unwrap();
    workflow
        .apply_executor_lease_command(&ExecutorLeaseCommand {
            context: context("command-ack", "2026-07-21T10:00:01.000Z"),
            operation: ExecutorLeaseOperation::AcknowledgeStart,
            next_expires_at: Some("2026-07-21T11:00:00.000Z".to_string()),
        })
        .unwrap();
    workflow
        .apply_task_inbox_as_executor(ExecutorTaskInboxCommand {
            context: context("command-start", "2026-07-21T10:00:02.000Z"),
            command: TaskInboxCommand::TransitionRun {
                run_id: "run-1".to_string(),
                transition: TaskInboxRunTransition::Start,
                updated_at: "2026-07-21T10:00:02.000Z".to_string(),
                ended_at: None,
                error: None,
            },
        })
        .unwrap();

    let checkpoint_before = checkpoint_payload(&database);
    let append = ExecutorTaskInboxCommand {
        context: context("command-events", "2026-07-21T10:00:03.000Z"),
        command: TaskInboxCommand::AppendEvents {
            events: vec![
                event("event-assistant", InboxEventKind::Assistant, "hello", 3),
                event("event-tool", InboxEventKind::Tool, "tool boundary", 4),
                event(
                    "event-permission",
                    InboxEventKind::Permission,
                    "permission boundary",
                    5,
                ),
            ],
            updated_at: "2026-07-21T10:00:05.000Z".to_string(),
        },
    };
    let appended = workflow
        .apply_task_inbox_as_executor(append.clone())
        .unwrap();
    assert_eq!(checkpoint_payload(&database), checkpoint_before);
    let revision = appended.revision;
    assert_eq!(
        workflow
            .apply_task_inbox_as_executor(append.clone())
            .unwrap()
            .revision,
        revision
    );
    assert_eq!(workflow.projection().revision, revision);

    let first = workflow.runtime_events("run-1", 0, 2).unwrap();
    assert_eq!(first.events.len(), 2);
    assert!(first.has_more);
    assert_eq!(first.events[0].event.id, "event-dispatch");
    assert_eq!(first.events[1].event.id, "event-assistant");
    let second = workflow
        .runtime_events("run-1", first.next_sequence, 2)
        .unwrap();
    assert_eq!(
        second
            .events
            .iter()
            .map(|event| event.event.kind)
            .collect::<Vec<_>>(),
        [InboxEventKind::Tool, InboxEventKind::Permission]
    );
    assert!(!second.has_more);
    for event in first.events.iter().chain(&second.events).skip(1) {
        assert_eq!(event.executor_lease_id.as_deref(), Some("lease-1"));
        assert_eq!(event.executor_generation, Some(1));
        assert_eq!(event.command_id.as_deref(), Some("command-events"));
    }

    let mut conflict = append;
    if let TaskInboxCommand::AppendEvents { events, .. } = &mut conflict.command {
        events[0].text = "different payload".to_string();
    }
    assert!(matches!(
        workflow.apply_task_inbox_as_executor(conflict).unwrap_err(),
        ianvs_acp_core::DurableWorkflowError::Store(WorkflowStoreError::Execution(
            ExecutionError::IdempotencyConflict
        )) | ianvs_acp_core::DurableWorkflowError::Execution(ExecutionError::IdempotencyConflict)
    ));
    assert!(
        workflow
            .runtime_events("run-1", 0, MAX_RUNTIME_EVENT_QUERY_LIMIT + 1)
            .is_err()
    );
    let oversized = (0..=MAX_RUNTIME_EVENT_APPEND_BATCH)
        .map(|index| {
            event(
                &format!("oversized-{index}"),
                InboxEventKind::Assistant,
                "bounded",
                6,
            )
        })
        .collect();
    assert!(matches!(
        workflow
            .apply_task_inbox_as_executor(ExecutorTaskInboxCommand {
                context: context("command-oversized", "2026-07-21T10:00:06.000Z"),
                command: TaskInboxCommand::AppendEvents {
                    events: oversized,
                    updated_at: "2026-07-21T10:00:06.000Z".to_string(),
                },
            })
            .unwrap_err(),
        ianvs_acp_core::DurableWorkflowError::Store(WorkflowStoreError::RuntimeEventBatchTooLarge)
    ));
    for batch in 0_u32..2 {
        let events = (0..MAX_RUNTIME_EVENT_APPEND_BATCH)
            .map(|index| {
                event(
                    &format!("bulk-{batch}-{index}"),
                    InboxEventKind::Assistant,
                    "coalesced assistant text",
                    7 + batch,
                )
            })
            .collect();
        workflow
            .apply_task_inbox_as_executor(ExecutorTaskInboxCommand {
                context: context(
                    &format!("command-bulk-{batch}"),
                    &format!("2026-07-21T10:00:0{}.000Z", 7 + batch),
                ),
                command: TaskInboxCommand::AppendEvents {
                    events,
                    updated_at: format!("2026-07-21T10:00:0{}.000Z", 7 + batch),
                },
            })
            .unwrap();
    }
    for index in 0..10 {
        let command = serde_json::from_value(serde_json::json!({
            "operation": "upsert_resource",
            "resource": {
                "id": format!("resource-{index}"),
                "type": "local_directory",
                "label": format!("Resource {index}"),
                "ref": {"path": workspace},
                "serial": false
            },
            "updatedAt": format!("2026-07-21T10:01:{index:02}.000Z")
        }))
        .unwrap();
        workflow.apply_task_inbox(command).unwrap();
    }

    drop(workflow);
    let store = ianvs_acp_core::SqliteWorkflowStore::open(&database).unwrap();
    let rebuilt = store.load_current_task_inbox().unwrap().unwrap();
    assert_eq!(rebuilt.events.len(), 1_004);
    assert_eq!(rebuilt.events[0].id, "event-dispatch");
    assert_eq!(rebuilt.events[3].id, "event-permission");
    assert_eq!(
        store.latest_checkpoint_sequence().unwrap(),
        store.latest_runtime_event_sequence().unwrap()
    );
    let snapshot_count = Connection::open(&database)
        .unwrap()
        .query_row("SELECT COUNT(*) FROM workflow_snapshots", [], |row| {
            row.get::<_, i64>(0)
        })
        .unwrap();
    assert_eq!(
        usize::try_from(snapshot_count).unwrap(),
        WORKFLOW_SNAPSHOT_RETENTION
    );
    drop(store);
    fs::remove_dir_all(directory).unwrap();
}

#[test]
fn event_append_batch_is_explicitly_bounded() {
    assert_eq!(MAX_RUNTIME_EVENT_APPEND_BATCH, 500);
    assert_eq!(MAX_RUNTIME_EVENT_QUERY_LIMIT, 500);
}

fn checkpoint_payload(database: &std::path::Path) -> String {
    Connection::open(database)
        .unwrap()
        .query_row(
            "SELECT payload_json FROM task_inbox_current WHERE singleton = 1",
            [],
            |row| row.get(0),
        )
        .unwrap()
}

fn event(id: &str, kind: InboxEventKind, text: &str, second: u32) -> InboxEventRecord {
    InboxEventRecord {
        id: id.to_string(),
        task_id: "task-1".to_string(),
        run_id: "run-1".to_string(),
        kind,
        text: text.to_string(),
        created_at: format!("2026-07-21T10:00:{second:02}.000Z"),
        session_id: Some("session-1".to_string()),
        metadata: BTreeMap::default(),
    }
}

fn context(command_id: &str, now: &str) -> ExecutorCommandContext {
    ExecutorCommandContext {
        run_id: "run-1".to_string(),
        executor_lease_id: "lease-1".to_string(),
        generation: 1,
        command_id: command_id.to_string(),
        now: now.to_string(),
    }
}

fn claim_request() -> SchedulerClaimRequest {
    SchedulerClaimRequest {
        run_id: "run-1".to_string(),
        dispatch_event_id: "event-dispatch".to_string(),
        executor_lease_id: "lease-1".to_string(),
        executor_id: "executor-1".to_string(),
        command_id: "command-claim".to_string(),
        now: "2026-07-21T10:00:00.000Z".to_string(),
        lease_expires_at: "2026-07-21T10:30:00.000Z".to_string(),
        excluded_task_ids: Vec::new(),
        capacity_reservations: vec![SchedulerCapacityReservation {
            reservation_id: "reservation-1".to_string(),
            agent_name: "agent-a".to_string(),
            host_instance_id: "executor-1".to_string(),
            created_at: "2026-07-21T09:59:59.000Z".to_string(),
            expires_at: "2026-07-21T10:00:05.000Z".to_string(),
        }],
    }
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
