use std::fs;

use ianvs_acp_core::{
    DurableWorkflow, ExecutionError, ExecutorCommandContext, ExecutorLeaseCommand,
    ExecutorLeaseOperation, ExecutorLeaseState, ExecutorTakeoverRequest, ExecutorTaskInboxCommand,
    SchedulerCapacityReservation, SchedulerClaimRequest, SchedulerRuntimeAvailability,
    SchedulerRuntimeStatus, TaskInboxCommand, TaskInboxRunTransition, TaskInboxSnapshot,
};

#[test]
#[allow(clippy::too_many_lines)]
fn executor_lease_is_durable_heartbeat_is_lightweight_and_stale_writers_fail_closed() {
    let directory = unique_temp_dir("executor-ownership");
    let workspace = directory.join("workspace");
    fs::create_dir(&workspace).unwrap();
    let database = directory.join("workflow.sqlite3");
    let source: TaskInboxSnapshot = serde_json::from_value(serde_json::json!({
        "schema": "ianvs-acp.task-inbox.v1",
        "updated_at": "2026-07-21T10:00:00.000Z",
        "tasks": [{
            "id": "task-1",
            "title": "Executor ownership",
            "description": "fencing fixture",
            "workspace_path": workspace,
            "agent_name": "agent-a",
            "status": "queued",
            "priority": "normal",
            "created_at": "2026-07-21T09:00:00.000Z",
            "updated_at": "2026-07-21T09:00:00.000Z",
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
        .stage_task_inbox_import(&source, "sha256:executor-ownership")
        .unwrap();
    workflow.materialize_task_inbox().unwrap();
    workflow.activate_task_inbox().unwrap();
    workflow
        .set_scheduler_runtime_status(SchedulerRuntimeStatus {
            agent_name: "agent-a".to_string(),
            availability: SchedulerRuntimeAvailability::Available,
            observed_at: "2026-07-21T10:00:00.000Z".to_string(),
            unavailable_reason: None,
            supports_session_resume: false,
            supports_permissions: true,
            max_concurrent_tasks: 1,
        })
        .unwrap();
    let claim_request = claim_request();
    let claim_projection = workflow
        .scheduler_claim_next(claim_request.clone())
        .unwrap();
    let claimed = claim_projection.claim.clone().unwrap();
    assert_eq!(
        workflow
            .scheduler_claim_next(claim_request.clone())
            .unwrap(),
        claim_projection
    );
    let mut conflicting_claim = claim_request;
    conflicting_claim.executor_id = "different-executor".to_string();
    assert_idempotency_conflict(workflow.scheduler_claim_next(conflicting_claim));
    assert_eq!(claimed.executor_lease.state, ExecutorLeaseState::Claimed);
    assert_eq!(
        workflow.executor_lease_for_run("run-1").unwrap().unwrap(),
        claimed.executor_lease
    );
    let claim_revision = workflow.projection().revision;

    let acknowledge_command = lease_command(
        "command-start",
        "2026-07-21T10:00:05.000Z",
        ExecutorLeaseOperation::AcknowledgeStart,
        Some("2026-07-21T10:00:35.000Z"),
        "lease-1",
        1,
    );
    let acknowledged = workflow
        .apply_executor_lease_command(&acknowledge_command)
        .unwrap();
    assert_eq!(
        workflow
            .apply_executor_lease_command(&acknowledge_command)
            .unwrap(),
        acknowledged
    );
    assert_eq!(acknowledged.state, ExecutorLeaseState::Active);
    assert_eq!(workflow.projection().revision, claim_revision);

    let unfenced = workflow.apply_task_inbox(TaskInboxCommand::TransitionRun {
        run_id: "run-1".to_string(),
        transition: TaskInboxRunTransition::Start,
        updated_at: "2026-07-21T10:00:06.000Z".to_string(),
        ended_at: None,
        error: None,
    });
    assert!(matches!(
        unfenced.unwrap_err(),
        ianvs_acp_core::DurableWorkflowError::Execution(ExecutionError::FencedMutationRequired)
    ));
    let start_command = ExecutorTaskInboxCommand {
        context: context(
            "command-transition-start",
            "2026-07-21T10:00:06.000Z",
            "lease-1",
            1,
        ),
        command: TaskInboxCommand::TransitionRun {
            run_id: "run-1".to_string(),
            transition: TaskInboxRunTransition::Start,
            updated_at: "2026-07-21T10:00:06.000Z".to_string(),
            ended_at: None,
            error: None,
        },
    };
    let started = workflow
        .apply_task_inbox_as_executor(start_command.clone())
        .unwrap();
    let started_revision = started.revision;
    assert_eq!(
        workflow
            .apply_task_inbox_as_executor(start_command)
            .unwrap(),
        started
    );
    assert_eq!(workflow.projection().revision, started_revision);
    let heartbeat = workflow
        .apply_executor_lease_command(&lease_command(
            "command-heartbeat",
            "2026-07-21T10:00:10.000Z",
            ExecutorLeaseOperation::Heartbeat,
            Some("2026-07-21T10:00:40.000Z"),
            "lease-1",
            1,
        ))
        .unwrap();
    assert_eq!(heartbeat.expires_at, "2026-07-21T10:00:40.000Z");
    let regressed = workflow.apply_executor_lease_command(&lease_command(
        "command-regressed-heartbeat",
        "2026-07-21T10:00:09.000Z",
        ExecutorLeaseOperation::Heartbeat,
        Some("2026-07-21T10:00:39.000Z"),
        "lease-1",
        1,
    ));
    assert!(matches!(
        regressed.unwrap_err(),
        ianvs_acp_core::DurableWorkflowError::Store(ianvs_acp_core::WorkflowStoreError::Execution(
            ExecutionError::LeaseClockRegression
        ))
    ));

    let early_takeover = workflow.takeover_executor_lease(&takeover(
        "2026-07-21T10:00:20.000Z",
        "2026-07-21T10:01:00.000Z",
    ));
    assert!(matches!(
        early_takeover.unwrap_err(),
        ianvs_acp_core::DurableWorkflowError::Store(ianvs_acp_core::WorkflowStoreError::Execution(
            ExecutionError::TakeoverBeforeExpiry
        ))
    ));
    let replacement = workflow
        .takeover_executor_lease(&takeover(
            "2026-07-21T10:00:41.000Z",
            "2026-07-21T10:01:11.000Z",
        ))
        .unwrap();
    assert_eq!(replacement.generation, 2);
    assert_eq!(
        workflow
            .takeover_executor_lease(&takeover(
                "2026-07-21T10:00:41.000Z",
                "2026-07-21T10:01:11.000Z",
            ))
            .unwrap(),
        replacement
    );

    let stale = workflow.apply_executor_lease_command(&lease_command(
        "command-stale",
        "2026-07-21T10:00:42.000Z",
        ExecutorLeaseOperation::Heartbeat,
        Some("2026-07-21T10:01:12.000Z"),
        "lease-2",
        1,
    ));
    assert!(matches!(
        stale.unwrap_err(),
        ianvs_acp_core::DurableWorkflowError::Store(ianvs_acp_core::WorkflowStoreError::Execution(
            ExecutionError::StaleGeneration
        ))
    ));

    workflow
        .apply_executor_lease_command(&lease_command(
            "command-replacement-start",
            "2026-07-21T10:00:42.000Z",
            ExecutorLeaseOperation::AcknowledgeStart,
            Some("2026-07-21T10:01:12.000Z"),
            "lease-2",
            2,
        ))
        .unwrap();
    for (index, transition) in [
        TaskInboxRunTransition::CollectArtifacts,
        TaskInboxRunTransition::RequireHumanReview,
    ]
    .into_iter()
    .enumerate()
    {
        let timestamp = format!("2026-07-21T10:00:4{}.000Z", index + 3);
        workflow
            .apply_task_inbox_as_executor(ExecutorTaskInboxCommand {
                context: context(
                    &format!("command-transition-{index}"),
                    &timestamp,
                    "lease-2",
                    2,
                ),
                command: TaskInboxCommand::TransitionRun {
                    run_id: "run-1".to_string(),
                    transition,
                    updated_at: timestamp,
                    ended_at: None,
                    error: None,
                },
            })
            .unwrap();
    }
    let after_review = workflow.apply_executor_lease_command(&lease_command(
        "command-late-heartbeat",
        "2026-07-21T10:00:46.000Z",
        ExecutorLeaseOperation::Heartbeat,
        Some("2026-07-21T10:01:16.000Z"),
        "lease-2",
        2,
    ));
    assert!(after_review.is_err());
    let release_command = lease_command(
        "command-release",
        "2026-07-21T10:00:46.000Z",
        ExecutorLeaseOperation::Release,
        None,
        "lease-2",
        2,
    );
    let released = workflow
        .apply_executor_lease_command(&release_command)
        .unwrap();
    assert_eq!(
        workflow
            .apply_executor_lease_command(&release_command)
            .unwrap(),
        released
    );

    drop(workflow);
    let reopened = DurableWorkflow::open(&database).unwrap();
    assert_eq!(
        reopened
            .executor_lease_for_run("run-1")
            .unwrap()
            .unwrap()
            .state,
        ExecutorLeaseState::Released
    );
    drop(reopened);
    fs::remove_dir_all(directory).unwrap();
}

fn assert_idempotency_conflict<T: std::fmt::Debug>(
    result: Result<T, ianvs_acp_core::DurableWorkflowError>,
) {
    assert!(matches!(
        result.unwrap_err(),
        ianvs_acp_core::DurableWorkflowError::Store(ianvs_acp_core::WorkflowStoreError::Execution(
            ExecutionError::IdempotencyConflict
        )) | ianvs_acp_core::DurableWorkflowError::Execution(ExecutionError::IdempotencyConflict)
    ));
}

fn claim_request() -> SchedulerClaimRequest {
    SchedulerClaimRequest {
        run_id: "run-1".to_string(),
        dispatch_event_id: "event-dispatch".to_string(),
        executor_lease_id: "lease-1".to_string(),
        executor_id: "executor-1".to_string(),
        command_id: "command-claim".to_string(),
        now: "2026-07-21T10:00:00.000Z".to_string(),
        lease_expires_at: "2026-07-21T10:00:30.000Z".to_string(),
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

fn context(
    command_id: &str,
    now: &str,
    executor_lease_id: &str,
    generation: u64,
) -> ExecutorCommandContext {
    ExecutorCommandContext {
        run_id: "run-1".to_string(),
        executor_lease_id: executor_lease_id.to_string(),
        generation,
        command_id: command_id.to_string(),
        now: now.to_string(),
    }
}

fn lease_command(
    command_id: &str,
    now: &str,
    operation: ExecutorLeaseOperation,
    next_expires_at: Option<&str>,
    executor_lease_id: &str,
    generation: u64,
) -> ExecutorLeaseCommand {
    ExecutorLeaseCommand {
        context: context(command_id, now, executor_lease_id, generation),
        operation,
        next_expires_at: next_expires_at.map(str::to_string),
    }
}

fn takeover(now: &str, expires_at: &str) -> ExecutorTakeoverRequest {
    ExecutorTakeoverRequest {
        run_id: "run-1".to_string(),
        previous_lease_id: "lease-1".to_string(),
        executor_lease_id: "lease-2".to_string(),
        executor_id: "executor-2".to_string(),
        reservation_id: "reservation-2".to_string(),
        command_id: "command-takeover".to_string(),
        now: now.to_string(),
        expires_at: expires_at.to_string(),
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
