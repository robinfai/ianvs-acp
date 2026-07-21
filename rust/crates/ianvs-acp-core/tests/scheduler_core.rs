use std::fs;

use ianvs_acp_core::{
    DurableWorkflow, InboxTaskStatus, RecoveryState, SchedulerAdmissionReason,
    SchedulerCapacityReservation, SchedulerClaimRequest, SchedulerConfig, SchedulerCore,
    SchedulerRuntimeAvailability, SchedulerRuntimeStatus, TaskInboxCommand, TaskInboxRunTransition,
    TaskInboxSnapshot, WorkflowStateMachine,
};

#[test]
fn scheduler_claim_owns_priority_retry_runtime_quota_and_workspace_admission() {
    let directory = unique_temp_dir("scheduler-admission");
    let shared = directory.join("shared");
    let separate = directory.join("separate");
    fs::create_dir(&shared).unwrap();
    fs::create_dir(&separate).unwrap();
    let mut snapshot: TaskInboxSnapshot = serde_json::from_value(serde_json::json!({
        "schema": "ianvs-acp.task-inbox.v1",
        "updated_at": "2026-07-17T10:00:00.000Z",
        "tasks": [
            task_json("future-urgent", "urgent", &separate, "agent-a", "2026-07-17T09:00:00.000Z", Some("2026-07-17T12:00:00.000Z")),
            task_json("ready-high", "high", &shared, "agent-a", "2026-07-17T09:01:00.000Z", None),
            task_json("shared-normal", "normal", &shared, "agent-b", "2026-07-17T09:02:00.000Z", None),
            task_json("agent-quota", "normal", &separate, "agent-a", "2026-07-17T09:03:00.000Z", None)
        ],
        "runs": [],
        "events": [],
        "artifacts": [],
        "approvals": [],
        "resources": []
    }))
    .unwrap();
    let imported = snapshot.workflow_import().unwrap();
    let mut workflow = WorkflowStateMachine::restore(imported.snapshot).unwrap();
    let mut scheduler = SchedulerCore::new();
    scheduler
        .configure(SchedulerConfig {
            max_concurrent_tasks: 2,
            runtime_status_freshness_seconds: 86_400,
        })
        .unwrap();
    scheduler
        .set_runtime_status(runtime(
            "agent-a",
            SchedulerRuntimeAvailability::Available,
            1,
        ))
        .unwrap();
    scheduler
        .set_runtime_status(runtime(
            "agent-b",
            SchedulerRuntimeAvailability::Available,
            1,
        ))
        .unwrap();

    let first = scheduler
        .claim_next(
            &mut snapshot,
            &mut workflow,
            claim("run-1", "event-1", "2026-07-17T10:00:00.000Z"),
        )
        .unwrap()
        .claim
        .unwrap();
    assert_eq!(first.task_id, "ready-high");
    assert_eq!(first.attempt, 1);
    assert_eq!(snapshot.events[0].id, "event-1");
    assert_eq!(
        workflow.workspace_owner(shared.canonicalize().unwrap()),
        Some("ready-high".to_string())
    );

    let second = scheduler
        .claim_next(
            &mut snapshot,
            &mut workflow,
            claim("run-2", "event-2", "2026-07-17T10:00:00.000Z"),
        )
        .unwrap();
    assert!(second.claim.is_none());
    assert_eq!(
        second.next_wake_at.as_deref(),
        Some("2026-07-17T12:00:00.000Z")
    );
    assert_eq!(snapshot.runs.len(), 1);

    snapshot
        .apply_command(
            &mut workflow,
            TaskInboxCommand::TransitionRun {
                run_id: "run-1".to_string(),
                transition: TaskInboxRunTransition::Fail,
                updated_at: "2026-07-17T10:01:00.000Z".to_string(),
                ended_at: Some("2026-07-17T10:01:00.000Z".to_string()),
                error: Some("fixture".to_string()),
            },
        )
        .unwrap();
    let third = scheduler
        .claim_next(
            &mut snapshot,
            &mut workflow,
            claim("run-3", "event-3", "2026-07-17T13:00:00.000Z"),
        )
        .unwrap()
        .claim
        .unwrap();
    assert_eq!(third.task_id, "future-urgent");
    fs::remove_dir_all(directory).unwrap();
}

#[test]
fn scheduler_poll_returns_earliest_core_retry_wake_without_mutation() {
    let directory = unique_temp_dir("scheduler-retry-wake");
    let workspace = directory.join("workspace");
    fs::create_dir(&workspace).unwrap();
    let mut snapshot: TaskInboxSnapshot = serde_json::from_value(serde_json::json!({
        "schema": "ianvs-acp.task-inbox.v1",
        "updated_at": "2026-07-17T10:00:00.000",
        "tasks": [
            task_json("later", "urgent", &workspace, "agent-a", "2026-07-17T09:00:00.000", Some("2026-07-17T12:00:00.000")),
            task_json("earlier", "normal", &workspace, "agent-a", "2026-07-17T09:01:00.000", Some("2026-07-17T11:00:00.000"))
        ],
        "runs": [],
        "events": [],
        "artifacts": [],
        "approvals": [],
        "resources": []
    }))
    .unwrap();
    let imported = snapshot.workflow_import().unwrap();
    let mut workflow = WorkflowStateMachine::restore(imported.snapshot).unwrap();
    let mut scheduler = SchedulerCore::new();
    scheduler
        .set_runtime_status(runtime(
            "agent-a",
            SchedulerRuntimeAvailability::Available,
            1,
        ))
        .unwrap();

    let poll = scheduler
        .claim_next(
            &mut snapshot,
            &mut workflow,
            SchedulerClaimRequest {
                capacity_reservations: vec![reservation_local("agent-a")],
                ..claim_without_reservations(
                    "run-unused",
                    "event-unused",
                    "2026-07-17T10:00:00.000",
                )
            },
        )
        .unwrap();
    assert!(poll.claim.is_none());
    assert_eq!(
        poll.next_wake_at.as_deref(),
        Some("2026-07-17T11:00:00.000")
    );
    assert!(snapshot.runs.is_empty());
    assert!(workflow.workspace_owner(&workspace).is_none());
    fs::remove_dir_all(directory).unwrap();
}

#[test]
fn durable_scheduler_noop_does_not_advance_revision_and_claim_is_atomic() {
    let directory = unique_temp_dir("scheduler-durable");
    let workspace = directory.join("workspace");
    fs::create_dir(&workspace).unwrap();
    let database = directory.join("workflow.sqlite3");
    let source: TaskInboxSnapshot = serde_json::from_value(serde_json::json!({
        "schema": "ianvs-acp.task-inbox.v1",
        "updated_at": "2026-07-17T10:00:00.000Z",
        "tasks": [task_json("task-1", "normal", &workspace, "agent-a", "2026-07-17T09:00:00.000Z", None)],
        "runs": [],
        "events": [],
        "artifacts": [],
        "approvals": [],
        "resources": []
    }))
    .unwrap();
    {
        let mut durable = DurableWorkflow::open(&database).unwrap();
        durable
            .stage_task_inbox_import(&source, "sha256:scheduler")
            .unwrap();
        durable.materialize_task_inbox().unwrap();
        durable.activate_task_inbox().unwrap();
        assert_eq!(durable.projection().revision, 3);
        let no_runtime = durable
            .scheduler_claim_next(claim(
                "run-unused",
                "event-unused",
                "2026-07-17T10:00:00.000Z",
            ))
            .unwrap();
        assert!(no_runtime.claim.is_none());
        assert_eq!(no_runtime.revision, 3);
        durable
            .set_scheduler_runtime_status(runtime(
                "agent-a",
                SchedulerRuntimeAvailability::Available,
                1,
            ))
            .unwrap();
        let no_capacity = durable
            .scheduler_claim_next(claim_without_reservations(
                "run-no-capacity",
                "event-no-capacity",
                "2026-07-17T10:00:00.000Z",
            ))
            .unwrap();
        assert!(no_capacity.claim.is_none());
        assert_eq!(
            no_capacity.admission.reason,
            SchedulerAdmissionReason::NoExecutorCapacity
        );
        assert_eq!(no_capacity.revision, 3);
        let claimed = durable
            .scheduler_claim_next(claim("run-1", "event-1", "2026-07-17T10:00:00.000Z"))
            .unwrap();
        assert_eq!(claimed.revision, 4);
        assert_eq!(claimed.claim.unwrap().task_id, "task-1");
        assert_eq!(
            claimed.task_inbox.tasks[0].status,
            InboxTaskStatus::Dispatched
        );
        assert_eq!(claimed.task_inbox.runs[0].id, "run-1");
        assert_eq!(claimed.task_inbox.events[0].id, "event-1");
    }

    let reopened = DurableWorkflow::open(&database).unwrap();
    assert_eq!(reopened.open_projection().revision, 5);
    assert_eq!(reopened.open_projection().recovery.runs.len(), 1);
    assert_eq!(
        reopened.open_projection().recovery.runs[0].recovery_state,
        RecoveryState::Requeued
    );
    let current = reopened.current_task_inbox().unwrap();
    assert_eq!(current.tasks[0].status, InboxTaskStatus::Queued);
    assert_eq!(current.runs[0].status, InboxTaskStatus::Failed);
    assert_eq!(current.events[0].id, "event-1");
    drop(reopened);
    fs::remove_dir_all(directory).unwrap();
}

#[test]
fn reservations_are_agent_bound_expiring_and_runtime_freshness_is_core_owned() {
    let directory = unique_temp_dir("scheduler-reservations");
    let workspace = directory.join("workspace");
    fs::create_dir(&workspace).unwrap();
    let source: TaskInboxSnapshot = serde_json::from_value(serde_json::json!({
        "schema": "ianvs-acp.task-inbox.v1",
        "updated_at": "2026-07-17T10:00:00.000Z",
        "tasks": [task_json("task-a", "normal", &workspace, "agent-a", "2026-07-17T09:00:00.000Z", None)],
        "runs": [],
        "events": [],
        "artifacts": [],
        "approvals": [],
        "resources": []
    }))
    .unwrap();
    let imported = source.workflow_import().unwrap();
    let mut snapshot = source;
    let mut workflow = WorkflowStateMachine::restore(imported.snapshot).unwrap();
    let before_snapshot = snapshot.clone();
    let before_workflow = workflow.snapshot();
    let mut scheduler = SchedulerCore::new();
    scheduler
        .set_runtime_status(runtime(
            "agent-a",
            SchedulerRuntimeAvailability::Available,
            1,
        ))
        .unwrap();

    let mismatched = scheduler
        .claim_next(
            &mut snapshot,
            &mut workflow,
            SchedulerClaimRequest {
                capacity_reservations: vec![reservation("agent-b")],
                ..claim_without_reservations(
                    "run-mismatch",
                    "event-mismatch",
                    "2026-07-17T10:00:00.000Z",
                )
            },
        )
        .unwrap();
    assert_eq!(
        mismatched.admission.reason,
        SchedulerAdmissionReason::NoExecutorCapacity
    );
    assert_eq!(snapshot, before_snapshot);
    assert_eq!(workflow.snapshot(), before_workflow);

    let expired = scheduler
        .claim_next(
            &mut snapshot,
            &mut workflow,
            SchedulerClaimRequest {
                capacity_reservations: vec![SchedulerCapacityReservation {
                    expires_at: "2026-07-17T09:59:59.999Z".to_string(),
                    created_at: "2026-07-17T09:00:00.000Z".to_string(),
                    ..reservation("agent-a")
                }],
                ..claim_without_reservations(
                    "run-expired",
                    "event-expired",
                    "2026-07-17T10:00:00.000Z",
                )
            },
        )
        .unwrap();
    assert_eq!(
        expired.admission.reason,
        SchedulerAdmissionReason::NoExecutorCapacity
    );
    assert_eq!(snapshot, before_snapshot);

    let stale = scheduler
        .claim_next(
            &mut snapshot,
            &mut workflow,
            claim("run-stale", "event-stale", "2026-07-17T10:01:00.000Z"),
        )
        .unwrap();
    assert_eq!(
        stale.admission.reason,
        SchedulerAdmissionReason::RuntimeStatusStale
    );
    assert_eq!(snapshot, before_snapshot);
    fs::remove_dir_all(directory).unwrap();
}

#[test]
fn human_review_releases_execution_capacity_but_keeps_workspace_lease() {
    let directory = unique_temp_dir("scheduler-review-capacity");
    let first_workspace = directory.join("first");
    let second_workspace = directory.join("second");
    fs::create_dir(&first_workspace).unwrap();
    fs::create_dir(&second_workspace).unwrap();
    let mut snapshot: TaskInboxSnapshot = serde_json::from_value(serde_json::json!({
        "schema": "ianvs-acp.task-inbox.v1",
        "updated_at": "2026-07-17T10:00:00.000Z",
        "tasks": [
            task_json("first", "high", &first_workspace, "agent-a", "2026-07-17T09:00:00.000Z", None),
            task_json("second", "normal", &second_workspace, "agent-b", "2026-07-17T09:01:00.000Z", None)
        ],
        "runs": [],
        "events": [],
        "artifacts": [],
        "approvals": [],
        "resources": []
    }))
    .unwrap();
    let imported = snapshot.workflow_import().unwrap();
    let mut workflow = WorkflowStateMachine::restore(imported.snapshot).unwrap();
    let mut scheduler = SchedulerCore::new();
    scheduler
        .configure(SchedulerConfig {
            max_concurrent_tasks: 1,
            runtime_status_freshness_seconds: 3_600,
        })
        .unwrap();
    for agent in ["agent-a", "agent-b"] {
        scheduler
            .set_runtime_status(runtime(agent, SchedulerRuntimeAvailability::Available, 1))
            .unwrap();
    }
    let first = scheduler
        .claim_next(
            &mut snapshot,
            &mut workflow,
            claim("run-first", "event-first", "2026-07-17T10:00:00.000Z"),
        )
        .unwrap()
        .claim
        .unwrap();
    for transition in [
        TaskInboxRunTransition::Start,
        TaskInboxRunTransition::CollectArtifacts,
        TaskInboxRunTransition::RequireHumanReview,
    ] {
        snapshot
            .apply_command(
                &mut workflow,
                TaskInboxCommand::TransitionRun {
                    run_id: first.run_id.clone(),
                    transition,
                    updated_at: "2026-07-17T10:01:00.000Z".to_string(),
                    ended_at: None,
                    error: None,
                },
            )
            .unwrap();
    }
    assert_eq!(workflow.active_execution_count(), 0);
    assert_eq!(workflow.active_run_count(), 1);
    let second = scheduler
        .claim_next(
            &mut snapshot,
            &mut workflow,
            claim("run-second", "event-second", "2026-07-17T10:02:00.000Z"),
        )
        .unwrap()
        .claim
        .unwrap();
    assert_eq!(second.task_id, "second");
    fs::remove_dir_all(directory).unwrap();
}

fn task_json(
    id: &str,
    priority: &str,
    workspace: &std::path::Path,
    agent_name: &str,
    created_at: &str,
    next_retry_at: Option<&str>,
) -> serde_json::Value {
    serde_json::json!({
        "id": id,
        "title": id,
        "description": "scheduler fixture",
        "workspace_path": workspace,
        "agent_name": agent_name,
        "status": "queued",
        "priority": priority,
        "created_at": created_at,
        "updated_at": created_at,
        "metadata": next_retry_at.map_or_else(
            || serde_json::json!({}),
            |value| serde_json::json!({"next_retry_at": value}),
        )
    })
}

fn runtime(
    agent_name: &str,
    availability: SchedulerRuntimeAvailability,
    max_concurrent_tasks: usize,
) -> SchedulerRuntimeStatus {
    SchedulerRuntimeStatus {
        agent_name: agent_name.to_string(),
        availability,
        observed_at: "2026-07-17T10:00:00.000Z".to_string(),
        unavailable_reason: None,
        supports_session_resume: false,
        supports_permissions: true,
        max_concurrent_tasks,
    }
}

fn claim(run_id: &str, event_id: &str, now: &str) -> SchedulerClaimRequest {
    SchedulerClaimRequest {
        run_id: run_id.to_string(),
        dispatch_event_id: event_id.to_string(),
        executor_lease_id: format!("lease-{run_id}"),
        executor_id: "test-executor".to_string(),
        command_id: format!("command-{run_id}"),
        now: now.to_string(),
        lease_expires_at: if now.ends_with('Z') {
            "2026-07-18T00:00:00.000Z".to_string()
        } else {
            "2026-07-18T00:00:00.000".to_string()
        },
        excluded_task_ids: Vec::new(),
        capacity_reservations: vec![reservation("agent-a"), reservation("agent-b")],
    }
}

fn claim_without_reservations(run_id: &str, event_id: &str, now: &str) -> SchedulerClaimRequest {
    SchedulerClaimRequest {
        run_id: run_id.to_string(),
        dispatch_event_id: event_id.to_string(),
        executor_lease_id: format!("lease-{run_id}"),
        executor_id: "test-executor".to_string(),
        command_id: format!("command-{run_id}"),
        now: now.to_string(),
        lease_expires_at: if now.ends_with('Z') {
            "2026-07-18T00:00:00.000Z".to_string()
        } else {
            "2026-07-18T00:00:00.000".to_string()
        },
        excluded_task_ids: Vec::new(),
        capacity_reservations: Vec::new(),
    }
}

fn reservation(agent_name: &str) -> SchedulerCapacityReservation {
    SchedulerCapacityReservation {
        reservation_id: format!("reservation-{agent_name}"),
        agent_name: agent_name.to_string(),
        host_instance_id: "test-host".to_string(),
        created_at: "2026-07-17T09:59:59.000Z".to_string(),
        expires_at: "2026-07-18T00:00:00.000Z".to_string(),
    }
}

fn reservation_local(agent_name: &str) -> SchedulerCapacityReservation {
    SchedulerCapacityReservation {
        reservation_id: format!("reservation-local-{agent_name}"),
        agent_name: agent_name.to_string(),
        host_instance_id: "test-host".to_string(),
        created_at: "2026-07-17T09:59:59.000".to_string(),
        expires_at: "2026-07-18T00:00:00.000".to_string(),
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
