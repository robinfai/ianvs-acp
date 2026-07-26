use std::collections::{BTreeMap, BTreeSet};
use std::io::Read;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant, SystemTime};

use chrono::{DateTime, SecondsFormat, Utc};
use ianvs_acp_core::{
    AgentLaunchConfig, ExecutorCommandContext, ExecutorLeaseCommand, ExecutorLeaseOperation,
    ExecutorTaskInboxCommand, InboxApprovalKind, InboxApprovalRecord, InboxApprovalStatus,
    InboxArtifactKind, InboxArtifactRecord, InboxArtifactStatus, InboxEventKind, InboxEventRecord,
    InboxTaskStatus, PermissionDecision, RetryPolicy, RuntimeEvent, RuntimeHandle, RuntimeStatus,
    SchedulerCapacityReservation, SchedulerClaim, SchedulerClaimRequest, SchedulerConfig,
    SchedulerRuntimeAvailability, SchedulerRuntimeStatus, SessionUpdate, SessionUpdateKind,
    TaskFailureReason, TaskInboxCommand, TaskInboxRunTransition,
};
use serde_json::Value;
use sha2::{Digest, Sha256};
use uuid::Uuid;

use super::{DaemonState, PendingTaskPermission};

const DISPATCH_INTERVAL: Duration = Duration::from_millis(250);
const AGENT_START_TIMEOUT: Duration = Duration::from_secs(15);
const SESSION_START_TIMEOUT: Duration = Duration::from_secs(30);
const RUN_TIMEOUT: Duration = Duration::from_secs(30 * 60);
const HEARTBEAT_INTERVAL: Duration = Duration::from_secs(10);
const GIT_ARTIFACT_TIMEOUT: Duration = Duration::from_secs(30);
const LEASE_TTL_SECONDS: i64 = 30;
const MAX_ASSISTANT_BUFFER_BYTES: usize = 64 * 1024;
const MAX_ASSISTANT_TRANSCRIPT_BYTES: usize = 1024 * 1024;
const MAX_EVENT_BATCH_RECORDS: usize = 32;
const MAX_EVENT_BATCH_BYTES: usize = 64 * 1024;
const MAX_ARTIFACT_CAPTURE_BYTES: usize = 1024 * 1024;
const MAX_ARTIFACT_PREVIEW_BYTES: usize = 64 * 1024;

pub(super) fn spawn_dispatcher(
    state: Arc<Mutex<DaemonState>>,
    shutdown: Arc<AtomicBool>,
) -> Result<thread::JoinHandle<()>, std::io::Error> {
    thread::Builder::new()
        .name("ianvs-acpd-dispatcher".to_string())
        .spawn(move || dispatch_loop(&state, &shutdown))
}

fn dispatch_loop(state: &Arc<Mutex<DaemonState>>, shutdown: &Arc<AtomicBool>) {
    while !shutdown.load(Ordering::Acquire) {
        let available = match state.lock() {
            Ok(mut state) => {
                let max_concurrent_tasks = state.agents.len().max(1);
                let _ = state.workflow.configure_scheduler(SchedulerConfig {
                    max_concurrent_tasks,
                    runtime_status_freshness_seconds: 30,
                });
                let agent_names = state.agents.keys().cloned().collect();
                let _ = state
                    .workflow
                    .reconcile_workflow_tasks(&agent_names, &now());
                state
                    .agents
                    .iter()
                    .filter(|(name, _)| !state.busy_agents.contains(*name))
                    .map(|(name, config)| (name.clone(), config.clone()))
                    .collect::<Vec<_>>()
            }
            Err(_) => return,
        };
        for (agent_name, config) in available {
            if shutdown.load(Ordering::Acquire) {
                break;
            }
            let claim = claim_for_agent(state, &agent_name);
            let Some(claim) = claim else {
                continue;
            };
            if let Ok(mut authority) = state.lock() {
                authority.busy_agents.insert(agent_name.clone());
            } else {
                return;
            }
            let worker_state = Arc::clone(state);
            let worker_agent_name = agent_name.clone();
            let worker_claim = claim.clone();
            let spawned = thread::Builder::new()
                .name(format!("ianvs-acpd-worker-{agent_name}"))
                .spawn(move || {
                    let _busy_guard = BusyAgentGuard {
                        state: Arc::clone(&worker_state),
                        agent_name: worker_agent_name,
                    };
                    if catch_unwind(AssertUnwindSafe(|| {
                        execute_claim(&worker_state, &config, &worker_claim);
                    }))
                    .is_err()
                    {
                        fail_claim_for_host_error(
                            &worker_state,
                            &worker_claim,
                            "daemon worker panicked",
                        );
                    }
                });
            if spawned.is_err() {
                if let Ok(mut authority) = state.lock() {
                    authority.busy_agents.remove(&agent_name);
                }
                fail_claim_for_host_error(
                    state,
                    &claim,
                    "failed to start the daemon worker thread",
                );
            }
        }
        thread::sleep(DISPATCH_INTERVAL);
    }
}

fn fail_claim_for_host_error(
    state: &Arc<Mutex<DaemonState>>,
    claim: &SchedulerClaim,
    message: &str,
) {
    let error = message.to_string();
    let _ = cancel_pending_permissions(state, claim, "Task runtime ended before a decision.");
    let _ = append_event(
        state,
        claim,
        InboxEventKind::Error,
        &error,
        BTreeMap::from([("daemon_error".to_string(), Value::Bool(true))]),
    );
    if fail_or_queue_retry(state, claim, &error).is_err() {
        let _ = transition(state, claim, TaskInboxRunTransition::Fail, Some(error));
    }
    let _ = release(state, claim, false);
}

struct BusyAgentGuard {
    state: Arc<Mutex<DaemonState>>,
    agent_name: String,
}

#[derive(Default)]
struct PendingEventBatch {
    events: Vec<InboxEventRecord>,
    bytes: usize,
}

impl PendingEventBatch {
    fn push(
        &mut self,
        claim: &SchedulerClaim,
        kind: InboxEventKind,
        text: &str,
        metadata: BTreeMap<String, Value>,
    ) {
        let text = text.trim();
        if text.is_empty() {
            return;
        }
        self.bytes = self.bytes.saturating_add(text.len());
        self.events.push(InboxEventRecord {
            id: id("event"),
            task_id: claim.task_id.clone(),
            run_id: claim.run_id.clone(),
            kind,
            text: text.to_string(),
            created_at: now(),
            session_id: None,
            metadata,
        });
    }

    fn should_flush(&self) -> bool {
        self.events.len() >= MAX_EVENT_BATCH_RECORDS || self.bytes >= MAX_EVENT_BATCH_BYTES
    }
}

impl Drop for BusyAgentGuard {
    fn drop(&mut self) {
        if let Ok(mut state) = self.state.lock() {
            state.busy_agents.remove(&self.agent_name);
        }
    }
}

fn claim_for_agent(state: &Arc<Mutex<DaemonState>>, agent_name: &str) -> Option<SchedulerClaim> {
    let now = now();
    let reservation_id = id("reservation");
    let mut state = state.lock().ok()?;
    let executor_id = state.host_instance_id.clone();
    state
        .workflow
        .set_scheduler_runtime_status(SchedulerRuntimeStatus {
            agent_name: agent_name.to_string(),
            availability: SchedulerRuntimeAvailability::Available,
            observed_at: now.clone(),
            unavailable_reason: None,
            supports_session_resume: true,
            supports_permissions: true,
            max_concurrent_tasks: 1,
        })
        .ok()?;
    state
        .workflow
        .scheduler_claim_next(SchedulerClaimRequest {
            run_id: id("run"),
            dispatch_event_id: id("event"),
            executor_lease_id: id("executor-lease"),
            executor_id: executor_id.clone(),
            command_id: id("command"),
            now: now.clone(),
            lease_expires_at: after_seconds(LEASE_TTL_SECONDS),
            excluded_task_ids: Vec::new(),
            capacity_reservations: vec![SchedulerCapacityReservation {
                reservation_id,
                agent_name: agent_name.to_string(),
                host_instance_id: executor_id,
                created_at: now,
                expires_at: after_seconds(5),
            }],
        })
        .ok()?
        .claim
}

fn execute_claim(
    state: &Arc<Mutex<DaemonState>>,
    config: &AgentLaunchConfig,
    claim: &SchedulerClaim,
) {
    let runtime = RuntimeHandle::new();
    if let Ok(mut authority) = state.lock() {
        authority
            .live_runtimes
            .insert(claim.run_id.clone(), runtime.command_handle());
    }
    let _runtime_guard = LiveRuntimeGuard {
        state: Arc::clone(state),
        run_id: claim.run_id.clone(),
    };
    let result = execute_claim_inner(state, config, claim, &runtime);
    let _ = cancel_pending_permissions(state, claim, "Task runtime ended before a decision.");
    if let Err(error) = result {
        let error = normalized_error(&error);
        let _ = append_event(
            state,
            claim,
            InboxEventKind::Error,
            &error,
            BTreeMap::from([("daemon_error".to_string(), Value::Bool(true))]),
        );
        if fail_or_queue_retry(state, claim, &error).is_err() {
            let _ = transition(state, claim, TaskInboxRunTransition::Fail, Some(error));
        }
    }
    let _ = release(state, claim, false);
    let _ = runtime.dispose();
}

struct LiveRuntimeGuard {
    state: Arc<Mutex<DaemonState>>,
    run_id: String,
}

impl Drop for LiveRuntimeGuard {
    fn drop(&mut self) {
        if let Ok(mut state) = self.state.lock() {
            state.live_runtimes.remove(&self.run_id);
        }
    }
}

fn execute_claim_inner(
    state: &Arc<Mutex<DaemonState>>,
    config: &AgentLaunchConfig,
    claim: &SchedulerClaim,
    runtime: &RuntimeHandle,
) -> Result<(), String> {
    runtime
        .start_agent(config.clone())
        .map_err(|error| error.to_string())?;
    wait_for_ready(runtime)?;
    acknowledge_start(state, claim)?;
    transition(state, claim, TaskInboxRunTransition::Start, None)?;
    let session_id = restore_or_create_session(state, config, claim, runtime)?;
    update_run_session(state, claim, &session_id, None)?;
    let prompt = task_prompt(state, claim)?;
    update_run_session(state, claim, &session_id, Some(&prompt))?;
    let prompt_request_id = id("prompt");
    runtime
        .prompt(&prompt_request_id, &session_id, &prompt)
        .map_err(|error| error.to_string())?;
    collect_prompt(state, claim, runtime, &prompt_request_id, &session_id)
}

fn restore_or_create_session(
    state: &Arc<Mutex<DaemonState>>,
    config: &AgentLaunchConfig,
    claim: &SchedulerClaim,
    runtime: &RuntimeHandle,
) -> Result<String, String> {
    if let Some(session_id) = previous_session_id(state, claim)? {
        let restore_request_id = id("restore-session");
        runtime
            .restore_session(
                &restore_request_id,
                &session_id,
                &claim.workspace_path,
                config.additional_directories.clone(),
            )
            .map_err(|error| error.to_string())?;
        match wait_for_session(
            runtime,
            &restore_request_id,
            SessionUpdateKind::SessionRestored,
        ) {
            Ok(restored) => {
                append_event(
                    state,
                    claim,
                    InboxEventKind::System,
                    "Restored the previous ACP session for this Task.",
                    BTreeMap::from([(
                        "restored_session_id".to_string(),
                        Value::String(restored.clone()),
                    )]),
                )?;
                return Ok(restored);
            }
            Err(error) => {
                append_event(
                    state,
                    claim,
                    InboxEventKind::System,
                    "Previous ACP session could not be restored; creating a new session.",
                    BTreeMap::from([("restore_error".to_string(), Value::String(error))]),
                )?;
            }
        }
    }
    let create_request_id = id("create-session");
    runtime
        .create_session(
            &create_request_id,
            &claim.workspace_path,
            config.additional_directories.clone(),
        )
        .map_err(|error| error.to_string())?;
    wait_for_session(
        runtime,
        &create_request_id,
        SessionUpdateKind::SessionCreated,
    )
}

fn previous_session_id(
    state: &Arc<Mutex<DaemonState>>,
    claim: &SchedulerClaim,
) -> Result<Option<String>, String> {
    let state = state.lock().map_err(|_| "daemon state lock poisoned")?;
    let snapshot = state
        .workflow
        .current_task_inbox()
        .ok_or_else(|| "TaskInbox projection is missing".to_string())?;
    if let Some(session_id) = snapshot
        .tasks
        .iter()
        .find(|task| task.id == claim.task_id)
        .and_then(|task| task.session_id.clone())
    {
        return Ok(Some(session_id));
    }
    Ok(snapshot
        .runs
        .iter()
        .rev()
        .find(|run| {
            run.task_id == claim.task_id && run.id != claim.run_id && run.session_id.is_some()
        })
        .and_then(|run| run.session_id.clone()))
}

fn wait_for_ready(runtime: &RuntimeHandle) -> Result<(), String> {
    let deadline = Instant::now() + AGENT_START_TIMEOUT;
    while Instant::now() < deadline {
        if let Some(event) = runtime
            .recv_event_timeout(Duration::from_millis(250))
            .map_err(|error| error.to_string())?
        {
            match event.event {
                RuntimeEvent::StatusChanged {
                    status: RuntimeStatus::Ready,
                    ..
                } => return Ok(()),
                RuntimeEvent::StatusChanged {
                    status: RuntimeStatus::Failed,
                    detail,
                    ..
                } => return Err(detail.unwrap_or_else(|| "agent failed to start".to_string())),
                RuntimeEvent::RuntimeError { message, .. } => return Err(message),
                _ => {}
            }
        }
    }
    Err("agent startup timed out".to_string())
}

fn wait_for_session(
    runtime: &RuntimeHandle,
    request_id: &str,
    expected_kind: SessionUpdateKind,
) -> Result<String, String> {
    let deadline = Instant::now() + SESSION_START_TIMEOUT;
    while Instant::now() < deadline {
        if let Some(event) = runtime
            .recv_event_timeout(Duration::from_millis(250))
            .map_err(|error| error.to_string())?
        {
            match event.event {
                RuntimeEvent::SessionUpdate { update }
                    if update.kind == expected_kind
                        && update.request_id.as_deref() == Some(request_id) =>
                {
                    return Ok(update.session_id);
                }
                RuntimeEvent::RuntimeError {
                    request_id: failed_request,
                    message,
                    ..
                } if failed_request.as_deref() == Some(request_id) => return Err(message),
                _ => {}
            }
        }
    }
    Err("session creation timed out".to_string())
}

fn collect_prompt(
    state: &Arc<Mutex<DaemonState>>,
    claim: &SchedulerClaim,
    runtime: &RuntimeHandle,
    prompt_request_id: &str,
    session_id: &str,
) -> Result<(), String> {
    let deadline = Instant::now() + RUN_TIMEOUT;
    let mut heartbeat_at = Instant::now() + HEARTBEAT_INTERVAL;
    let mut assistant = String::new();
    let mut transcript = String::new();
    let mut pending_events = PendingEventBatch::default();
    while Instant::now() < deadline {
        if Instant::now() >= heartbeat_at {
            flush_event_batch(state, claim, &mut pending_events)?;
            heartbeat(state, claim)?;
            heartbeat_at = Instant::now() + HEARTBEAT_INTERVAL;
        }
        let Some(event) = runtime
            .recv_event_timeout(Duration::from_millis(250))
            .map_err(|error| error.to_string())?
        else {
            continue;
        };
        match event.event {
            RuntimeEvent::SessionUpdate { update } if update.session_id == session_id => {
                let completed = match handle_session_update(
                    claim,
                    prompt_request_id,
                    update,
                    &mut assistant,
                    &mut transcript,
                    &mut pending_events,
                ) {
                    Ok(completed) => completed,
                    Err(error) => {
                        flush_assistant(claim, &mut assistant, &mut pending_events);
                        let _ = flush_event_batch(state, claim, &mut pending_events);
                        return Err(error);
                    }
                };
                if pending_events.should_flush() {
                    flush_event_batch(state, claim, &mut pending_events)?;
                }
                if completed {
                    flush_event_batch(state, claim, &mut pending_events)?;
                    transition(state, claim, TaskInboxRunTransition::CollectArtifacts, None)?;
                    collect_artifacts(state, claim, &transcript)?;
                    update_task_summary(state, claim, &transcript, session_id)?;
                    if workflow_auto_complete(state, claim)? {
                        transition(state, claim, TaskInboxRunTransition::Complete, None)?;
                    } else {
                        transition(
                            state,
                            claim,
                            TaskInboxRunTransition::RequireHumanReview,
                            None,
                        )?;
                    }
                    return Ok(());
                }
            }
            RuntimeEvent::PermissionRequest { request } if request.session_id == session_id => {
                flush_assistant(claim, &mut assistant, &mut pending_events);
                flush_event_batch(state, claim, &mut pending_events)?;
                wait_for_task_permission(state, claim, &request)?;
            }
            RuntimeEvent::RuntimeError {
                request_id,
                message,
                ..
            } if request_id.as_deref() == Some(prompt_request_id) => {
                flush_assistant(claim, &mut assistant, &mut pending_events);
                let _ = flush_event_batch(state, claim, &mut pending_events);
                return Err(message);
            }
            RuntimeEvent::StatusChanged {
                status: RuntimeStatus::Failed,
                detail,
                ..
            } => {
                flush_assistant(claim, &mut assistant, &mut pending_events);
                let _ = flush_event_batch(state, claim, &mut pending_events);
                return Err(detail.unwrap_or_else(|| "agent runtime failed".to_string()));
            }
            _ => {}
        }
    }
    flush_assistant(claim, &mut assistant, &mut pending_events);
    let _ = flush_event_batch(state, claim, &mut pending_events);
    runtime
        .cancel(id("cancel"), session_id)
        .map_err(|error| error.to_string())?;
    Err("agent prompt timed out".to_string())
}

#[allow(clippy::too_many_lines)]
fn wait_for_task_permission(
    state: &Arc<Mutex<DaemonState>>,
    claim: &SchedulerClaim,
    request: &ianvs_acp_core::PermissionRequestProjection,
) -> Result<(), String> {
    let approval_id = format!("permission-{}", request.request_id);
    let option_ids = request
        .options
        .iter()
        .map(|option| option.option_id.clone())
        .collect::<BTreeSet<_>>();
    let denied_option_ids = request
        .options
        .iter()
        .filter(|option| option.kind.contains("reject") || option.kind.contains("deny"))
        .map(|option| option.option_id.clone())
        .collect::<BTreeSet<_>>();
    append_event(
        state,
        claim,
        InboxEventKind::Permission,
        &format!("Permission is waiting for review: {}", request.title),
        BTreeMap::from([
            (
                "request_id".to_string(),
                Value::String(request.request_id.clone()),
            ),
            (
                "tool_kind".to_string(),
                Value::String(request.tool_kind.clone()),
            ),
        ]),
    )?;
    let mut authority = state.lock().map_err(|_| "daemon state lock poisoned")?;
    let approval_context = context(&mut authority, claim)?;
    authority
        .workflow
        .apply_task_inbox_as_executor(ExecutorTaskInboxCommand {
            context: approval_context,
            command: TaskInboxCommand::UpsertApproval {
                approval: InboxApprovalRecord {
                    id: approval_id.clone(),
                    task_id: claim.task_id.clone(),
                    run_id: Some(claim.run_id.clone()),
                    kind: InboxApprovalKind::ToolPermission,
                    status: InboxApprovalStatus::Pending,
                    created_at: now(),
                    resolved_at: None,
                    target: None,
                    destination: None,
                    risk_summary: Some(request.title.clone()),
                    rationale: None,
                    artifact_ids: Vec::new(),
                    metadata: BTreeMap::from([
                        (
                            "permission_request_id".to_string(),
                            Value::String(request.request_id.clone()),
                        ),
                        (
                            "tool_call_id".to_string(),
                            Value::String(request.tool_call_id.clone()),
                        ),
                        (
                            "tool_kind".to_string(),
                            Value::String(request.tool_kind.clone()),
                        ),
                        (
                            "options".to_string(),
                            serde_json::to_value(&request.options)
                                .map_err(|error| error.to_string())?,
                        ),
                        (
                            "raw_input".to_string(),
                            request.raw_input.clone().unwrap_or(Value::Null),
                        ),
                    ]),
                },
                updated_at: now(),
            },
        })
        .map_err(|error| error.to_string())?;
    let transition_context = context(&mut authority, claim)?;
    authority
        .workflow
        .apply_task_inbox_as_executor(ExecutorTaskInboxCommand {
            context: transition_context,
            command: TaskInboxCommand::TransitionRun {
                run_id: claim.run_id.clone(),
                transition: TaskInboxRunTransition::WaitForPermission,
                updated_at: now(),
                ended_at: None,
                error: None,
            },
        })
        .map_err(|error| error.to_string())?;
    authority.pending_permissions.insert(
        request.request_id.clone(),
        PendingTaskPermission {
            task_id: claim.task_id.clone(),
            run_id: claim.run_id.clone(),
            approval_id,
            option_ids,
            denied_option_ids,
        },
    );
    Ok(())
}

pub(super) fn respond_task_permission(
    state: &mut DaemonState,
    run_id: &str,
    permission_request_id: &str,
    decision: PermissionDecision,
    resolved_at: &str,
) -> Result<(), String> {
    let pending = state
        .pending_permissions
        .get(permission_request_id)
        .cloned()
        .ok_or_else(|| "Task permission request is not pending".to_string())?;
    if pending.run_id != run_id {
        return Err("Task permission request belongs to another Run".to_string());
    }
    if let PermissionDecision::Selected { option_id } = &decision
        && !pending.option_ids.contains(option_id)
    {
        return Err("Task permission decision selected an unknown option".to_string());
    }
    let handle = state
        .live_runtimes
        .get(run_id)
        .cloned()
        .ok_or_else(|| "Task runtime is no longer live".to_string())?;
    let status = match &decision {
        PermissionDecision::Cancelled => InboxApprovalStatus::Cancelled,
        PermissionDecision::Selected { option_id }
            if pending.denied_option_ids.contains(option_id) =>
        {
            InboxApprovalStatus::Denied
        }
        PermissionDecision::Selected { .. } => InboxApprovalStatus::Approved,
    };
    handle
        .respond_permission(permission_request_id.to_string(), decision)
        .map_err(|error| error.to_string())?;
    let snapshot = state
        .workflow
        .current_task_inbox()
        .ok_or_else(|| "TaskInbox projection is missing".to_string())?;
    let mut approval = snapshot
        .approvals
        .iter()
        .find(|approval| approval.id == pending.approval_id)
        .cloned()
        .ok_or_else(|| "Task permission approval projection is missing".to_string())?;
    if approval.task_id != pending.task_id {
        return Err("Task permission approval belongs to another Task".to_string());
    }
    approval.status = status;
    approval.resolved_at = Some(resolved_at.to_string());
    approval.rationale = Some(match status {
        InboxApprovalStatus::Approved => "Permission approved.".to_string(),
        InboxApprovalStatus::Denied => "Permission denied.".to_string(),
        InboxApprovalStatus::Cancelled => "Permission cancelled.".to_string(),
        InboxApprovalStatus::Pending => unreachable!("resolved status selected above"),
    });
    let context = context_for_run(state, run_id)?;
    state
        .workflow
        .apply_task_inbox_as_executor(ExecutorTaskInboxCommand {
            context,
            command: TaskInboxCommand::UpsertApproval {
                approval,
                updated_at: resolved_at.to_string(),
            },
        })
        .map_err(|error| error.to_string())?;
    let context = context_for_run(state, run_id)?;
    state
        .workflow
        .apply_task_inbox_as_executor(ExecutorTaskInboxCommand {
            context,
            command: TaskInboxCommand::TransitionRun {
                run_id: run_id.to_string(),
                transition: TaskInboxRunTransition::Resume,
                updated_at: resolved_at.to_string(),
                ended_at: None,
                error: None,
            },
        })
        .map_err(|error| error.to_string())?;
    state.pending_permissions.remove(permission_request_id);
    Ok(())
}

fn cancel_pending_permissions(
    state: &Arc<Mutex<DaemonState>>,
    claim: &SchedulerClaim,
    rationale: &str,
) -> Result<(), String> {
    let mut authority = state.lock().map_err(|_| "daemon state lock poisoned")?;
    let pending = authority
        .pending_permissions
        .iter()
        .filter(|(_, permission)| permission.run_id == claim.run_id)
        .map(|(request_id, permission)| (request_id.clone(), permission.clone()))
        .collect::<Vec<_>>();
    let mut first_error = None;
    for (request_id, permission) in pending {
        let result = (|| {
            let snapshot = authority
                .workflow
                .current_task_inbox()
                .ok_or_else(|| "TaskInbox projection is missing".to_string())?;
            let Some(mut approval) = snapshot
                .approvals
                .iter()
                .find(|approval| approval.id == permission.approval_id)
                .cloned()
            else {
                return Ok(());
            };
            if approval.status != InboxApprovalStatus::Pending {
                return Ok(());
            }
            let timestamp = now();
            approval.status = InboxApprovalStatus::Cancelled;
            approval.resolved_at = Some(timestamp.clone());
            approval.rationale = Some(rationale.to_string());
            let context = context(&mut authority, claim)?;
            authority
                .workflow
                .apply_task_inbox_as_executor(ExecutorTaskInboxCommand {
                    context,
                    command: TaskInboxCommand::UpsertApproval {
                        approval,
                        updated_at: timestamp,
                    },
                })
                .map_err(|error| error.to_string())?;
            Ok(())
        })();
        authority.pending_permissions.remove(&request_id);
        if let Err(error) = result
            && first_error.is_none()
        {
            first_error = Some(error);
        }
    }
    first_error.map_or(Ok(()), Err)
}

fn handle_session_update(
    claim: &SchedulerClaim,
    prompt_request_id: &str,
    update: SessionUpdate,
    assistant: &mut String,
    transcript: &mut String,
    pending_events: &mut PendingEventBatch,
) -> Result<bool, String> {
    match update.kind {
        SessionUpdateKind::AgentMessageDelta | SessionUpdateKind::AgentThoughtDelta => {
            if let Some(text) = update.text {
                append_bounded(transcript, &text, MAX_ASSISTANT_TRANSCRIPT_BYTES);
                append_bounded(assistant, &text, MAX_ASSISTANT_BUFFER_BYTES);
            }
            if assistant.len() >= MAX_ASSISTANT_BUFFER_BYTES {
                flush_assistant(claim, assistant, pending_events);
            }
        }
        SessionUpdateKind::ToolCall | SessionUpdateKind::ToolCallUpdate => {
            flush_assistant(claim, assistant, pending_events);
            pending_events.push(
                claim,
                InboxEventKind::Tool,
                update.text.as_deref().unwrap_or("Agent tool activity"),
                update
                    .payload
                    .map(|payload| BTreeMap::from([("payload".to_string(), payload)]))
                    .unwrap_or_default(),
            );
        }
        SessionUpdateKind::PromptCompleted
            if update.request_id.as_deref() == Some(prompt_request_id) =>
        {
            flush_assistant(claim, assistant, pending_events);
            return Ok(true);
        }
        SessionUpdateKind::Failed if update.request_id.as_deref() == Some(prompt_request_id) => {
            return Err(update
                .text
                .unwrap_or_else(|| "agent prompt failed".to_string()));
        }
        SessionUpdateKind::Cancelled if update.request_id.as_deref() == Some(prompt_request_id) => {
            return Err("agent prompt was cancelled".to_string());
        }
        _ => {}
    }
    Ok(false)
}

fn append_bounded(target: &mut String, value: &str, limit: usize) {
    if target.len() >= limit {
        return;
    }
    let remaining = limit - target.len();
    if value.len() <= remaining {
        target.push_str(value);
        return;
    }
    let mut end = remaining;
    while end > 0 && !value.is_char_boundary(end) {
        end -= 1;
    }
    target.push_str(&value[..end]);
}

#[allow(clippy::too_many_lines)]
fn collect_artifacts(
    state: &Arc<Mutex<DaemonState>>,
    claim: &SchedulerClaim,
    transcript: &str,
) -> Result<(), String> {
    let timestamp = now();
    let mut artifacts = Vec::new();
    if !transcript.trim().is_empty() {
        artifacts.push(text_artifact(
            claim,
            InboxArtifactKind::AgentSummary,
            "Agent summary",
            transcript.as_bytes(),
            MAX_ARTIFACT_PREVIEW_BYTES,
            &timestamp,
            BTreeMap::from([(
                "source".to_string(),
                Value::String("assistant_transcript".to_string()),
            )]),
        ));
    }
    let mut git_artifacts = vec![
        (
            InboxArtifactKind::GitStatus,
            "Git status",
            vec!["status", "--porcelain"],
            MAX_ARTIFACT_PREVIEW_BYTES,
            false,
        ),
        (
            InboxArtifactKind::GitDiff,
            "Git diff stat",
            vec!["diff", "--no-ext-diff", "--stat"],
            MAX_ARTIFACT_PREVIEW_BYTES,
            false,
        ),
    ];
    if retain_full_diff(state, claim)? {
        git_artifacts.push((
            InboxArtifactKind::GitDiff,
            "Git diff preview",
            vec!["diff", "--no-ext-diff"],
            MAX_ARTIFACT_CAPTURE_BYTES,
            true,
        ));
    }
    for (kind, title, arguments, capture_limit, raw_payload) in git_artifacts {
        if let Some((captured, truncated)) =
            capture_git(&claim.workspace_path, &arguments, capture_limit)?
            && !captured.is_empty()
        {
            let mut metadata = BTreeMap::from([
                (
                    "command".to_string(),
                    Value::Array(
                        std::iter::once("git")
                            .chain(arguments.iter().copied())
                            .map(|value| Value::String(value.to_string()))
                            .collect(),
                    ),
                ),
                ("truncated".to_string(), Value::Bool(truncated)),
            ]);
            if raw_payload {
                metadata.insert("raw_payload".to_string(), Value::Bool(true));
            }
            artifacts.push(text_artifact(
                claim,
                kind,
                title,
                &captured,
                capture_limit,
                &timestamp,
                metadata,
            ));
        }
    }
    let artifact_events = artifacts
        .iter()
        .map(|artifact| InboxEventRecord {
            id: id("event"),
            task_id: claim.task_id.clone(),
            run_id: claim.run_id.clone(),
            kind: InboxEventKind::Artifact,
            text: format!("Collected artifact: {}", artifact.title),
            created_at: timestamp.clone(),
            session_id: None,
            metadata: BTreeMap::from([(
                "artifact_id".to_string(),
                Value::String(artifact.id.clone()),
            )]),
        })
        .collect::<Vec<_>>();
    let mut authority = state.lock().map_err(|_| "daemon state lock poisoned")?;
    let artifacts_context = context(&mut authority, claim)?;
    authority
        .workflow
        .apply_task_inbox_as_executor(ExecutorTaskInboxCommand {
            context: artifacts_context,
            command: TaskInboxCommand::ReplaceArtifacts {
                task_id: claim.task_id.clone(),
                run_id: claim.run_id.clone(),
                artifacts,
                updated_at: timestamp.clone(),
            },
        })
        .map_err(|error| error.to_string())?;
    if !artifact_events.is_empty() {
        let events_context = context(&mut authority, claim)?;
        authority
            .workflow
            .apply_task_inbox_as_executor(ExecutorTaskInboxCommand {
                context: events_context,
                command: TaskInboxCommand::AppendEvents {
                    events: artifact_events,
                    updated_at: timestamp,
                },
            })
            .map_err(|error| error.to_string())?;
    }
    Ok(())
}

fn capture_git(
    workspace: &str,
    arguments: &[&str],
    capture_limit: usize,
) -> Result<Option<(Vec<u8>, bool)>, String> {
    let mut child = match Command::new("git")
        .arg("-C")
        .arg(workspace)
        .args(arguments)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
    {
        Ok(child) => child,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(format!("failed to collect git artifact: {error}")),
    };
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| "git artifact stdout pipe is missing".to_string())?;
    let reader = thread::spawn(move || read_bounded(stdout, capture_limit));
    let deadline = Instant::now() + GIT_ARTIFACT_TIMEOUT;
    let status = loop {
        if let Some(status) = child
            .try_wait()
            .map_err(|error| format!("failed to wait for git artifact: {error}"))?
        {
            break status;
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            let _ = reader.join();
            return Err("git artifact collection timed out".to_string());
        }
        thread::sleep(Duration::from_millis(10));
    };
    let (captured, truncated) = reader
        .join()
        .map_err(|_| "git artifact reader panicked".to_string())?
        .map_err(|error| format!("failed to read git artifact: {error}"))?;
    if !status.success() {
        return Ok(None);
    }
    Ok(Some((captured, truncated)))
}

fn read_bounded(
    mut reader: impl Read,
    capture_limit: usize,
) -> Result<(Vec<u8>, bool), std::io::Error> {
    let mut captured = Vec::with_capacity(capture_limit.min(64 * 1024));
    let mut buffer = [0_u8; 16 * 1024];
    let mut truncated = false;
    loop {
        let read = reader.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        let remaining = capture_limit.saturating_sub(captured.len());
        let retained = read.min(remaining);
        captured.extend_from_slice(&buffer[..retained]);
        truncated |= retained < read;
    }
    Ok((captured, truncated))
}

fn text_artifact(
    claim: &SchedulerClaim,
    kind: InboxArtifactKind,
    title: &str,
    content: &[u8],
    preview_limit: usize,
    created_at: &str,
    metadata: BTreeMap<String, Value>,
) -> InboxArtifactRecord {
    let preview_length = content.len().min(preview_limit);
    let preview = String::from_utf8_lossy(&content[..preview_length]).to_string();
    let sha256 = format!("sha256:{:x}", Sha256::digest(content));
    InboxArtifactRecord {
        id: id("artifact"),
        task_id: claim.task_id.clone(),
        run_id: claim.run_id.clone(),
        kind,
        status: InboxArtifactStatus::Candidate,
        title: title.to_string(),
        created_at: created_at.to_string(),
        path: None,
        content_preview: (!preview.is_empty()).then_some(preview),
        sha256: Some(sha256),
        size_bytes: Some(u64::try_from(content.len()).unwrap_or(u64::MAX)),
        metadata,
    }
}

fn update_task_summary(
    state: &Arc<Mutex<DaemonState>>,
    claim: &SchedulerClaim,
    transcript: &str,
    session_id: &str,
) -> Result<(), String> {
    let mut authority = state.lock().map_err(|_| "daemon state lock poisoned")?;
    let snapshot = authority
        .workflow
        .current_task_inbox()
        .ok_or_else(|| "TaskInbox projection is missing".to_string())?;
    let mut task = snapshot
        .tasks
        .iter()
        .find(|task| task.id == claim.task_id)
        .cloned()
        .ok_or_else(|| "claimed Task is missing".to_string())?;
    task.session_id = Some(session_id.to_string());
    task.summary = Some(if transcript.trim().is_empty() {
        "Agent completed without a text response.".to_string()
    } else {
        transcript.trim().to_string()
    });
    let context = context(&mut authority, claim)?;
    authority
        .workflow
        .apply_task_inbox_as_executor(ExecutorTaskInboxCommand {
            context,
            command: TaskInboxCommand::UpdateTaskProjection {
                task,
                updated_at: now(),
            },
        })
        .map_err(|error| error.to_string())?;
    Ok(())
}

fn workflow_auto_complete(
    state: &Arc<Mutex<DaemonState>>,
    claim: &SchedulerClaim,
) -> Result<bool, String> {
    task_metadata_bool(state, claim, "workflow_auto_complete")
}

fn retain_full_diff(
    state: &Arc<Mutex<DaemonState>>,
    claim: &SchedulerClaim,
) -> Result<bool, String> {
    task_metadata_bool(state, claim, "retain_full_diff")
}

fn task_metadata_bool(
    state: &Arc<Mutex<DaemonState>>,
    claim: &SchedulerClaim,
    key: &str,
) -> Result<bool, String> {
    let authority = state.lock().map_err(|_| "daemon state lock poisoned")?;
    Ok(authority
        .workflow
        .current_task_inbox()
        .and_then(|snapshot| snapshot.tasks.iter().find(|task| task.id == claim.task_id))
        .and_then(|task| task.metadata.get(key))
        .and_then(Value::as_bool)
        .unwrap_or(false))
}

fn fail_or_queue_retry(
    state: &Arc<Mutex<DaemonState>>,
    claim: &SchedulerClaim,
    error: &str,
) -> Result<(), String> {
    let reason = classify_failure(error);
    let policy = RetryPolicy::default();
    let mut authority = state.lock().map_err(|_| "daemon state lock poisoned")?;
    let snapshot = authority
        .workflow
        .current_task_inbox()
        .ok_or_else(|| "TaskInbox projection is missing".to_string())?;
    let mut task = snapshot
        .tasks
        .iter()
        .find(|task| task.id == claim.task_id)
        .cloned()
        .ok_or_else(|| "claimed Task is missing".to_string())?;
    let workflow_owned = task
        .metadata
        .get("workflow_run_id")
        .and_then(Value::as_str)
        .is_some();
    if workflow_owned || !policy.should_retry(reason, claim.attempt) {
        drop(authority);
        return transition(
            state,
            claim,
            TaskInboxRunTransition::Fail,
            Some(error.to_string()),
        );
    }
    let mut run = snapshot
        .runs
        .iter()
        .find(|run| run.id == claim.run_id)
        .cloned()
        .ok_or_else(|| "claimed Run is missing".to_string())?;
    let timestamp = now();
    let next_retry_at = after_duration(policy.delay_for_attempt(claim.attempt));
    task.status = InboxTaskStatus::Queued;
    task.current_run_id = None;
    task.summary = Some(format!(
        "{} Retrying at {next_retry_at}.",
        failure_reason_label(reason)
    ));
    task.error = None;
    task.updated_at.clone_from(&timestamp);
    task.metadata.insert(
        "failure_reason".to_string(),
        Value::String(failure_reason_key(reason).to_string()),
    );
    task.metadata.insert(
        "last_failure_message".to_string(),
        Value::String(error.to_string()),
    );
    task.metadata.insert(
        "next_retry_at".to_string(),
        Value::String(next_retry_at.clone()),
    );
    run.status = InboxTaskStatus::Failed;
    run.ended_at = Some(timestamp.clone());
    run.error = Some(error.to_string());
    let command_context = context(&mut authority, claim)?;
    authority
        .workflow
        .apply_task_inbox_as_executor(ExecutorTaskInboxCommand {
            context: command_context,
            command: TaskInboxCommand::FailRunAndQueueRetryProjection {
                task,
                run,
                updated_at: timestamp,
            },
        })
        .map_err(|error| error.to_string())?;
    Ok(())
}

fn classify_failure(error: &str) -> TaskFailureReason {
    let normalized = error.to_ascii_lowercase();
    if normalized.contains("artifact") {
        TaskFailureReason::ArtifactCollectionFailed
    } else if normalized.contains("permission denied")
        || normalized.contains("permission was denied")
    {
        TaskFailureReason::PermissionDenied
    } else if normalized.contains("authentication")
        || normalized.contains("auth required")
        || normalized.contains("unauthorized")
    {
        TaskFailureReason::AuthRequired
    } else if normalized.contains("timed out") || normalized.contains("timeout") {
        TaskFailureReason::Timeout
    } else if normalized.contains("failed to start")
        || normalized.contains("failed to spawn")
        || normalized.contains("executable not found")
        || normalized.contains("agent process exited")
    {
        TaskFailureReason::RuntimeOffline
    } else if normalized.contains("connection")
        || normalized.contains("broken pipe")
        || normalized.contains("transport")
        || normalized.contains("channel closed")
        || normalized.contains("unexpected eof")
    {
        TaskFailureReason::TransientRuntimeError
    } else {
        TaskFailureReason::AgentError
    }
}

fn failure_reason_key(reason: TaskFailureReason) -> &'static str {
    match reason {
        TaskFailureReason::RuntimeOffline => "runtime_offline",
        TaskFailureReason::Timeout => "timeout",
        TaskFailureReason::AuthRequired => "auth_required",
        TaskFailureReason::TransientRuntimeError => "transient_runtime_error",
        TaskFailureReason::AgentError => "agent_error",
        TaskFailureReason::PermissionDenied => "permission_denied",
        TaskFailureReason::ArtifactCollectionFailed => "artifact_collection_failed",
        TaskFailureReason::HumanRejected => "human_rejected",
    }
}

fn failure_reason_label(reason: TaskFailureReason) -> &'static str {
    match reason {
        TaskFailureReason::RuntimeOffline => "Agent runtime was unavailable.",
        TaskFailureReason::Timeout => "Agent execution timed out.",
        TaskFailureReason::AuthRequired => "Agent authentication is required.",
        TaskFailureReason::TransientRuntimeError => "Agent transport failed temporarily.",
        TaskFailureReason::AgentError => "Agent execution failed.",
        TaskFailureReason::PermissionDenied => "Agent permission was denied.",
        TaskFailureReason::ArtifactCollectionFailed => "Artifact collection failed.",
        TaskFailureReason::HumanRejected => "The result was rejected.",
    }
}

fn normalized_error(error: &str) -> String {
    let trimmed = error.trim();
    if trimmed.is_empty() {
        "agent execution failed".to_string()
    } else {
        trimmed.to_string()
    }
}

fn flush_assistant(
    claim: &SchedulerClaim,
    assistant: &mut String,
    pending_events: &mut PendingEventBatch,
) {
    if assistant.is_empty() {
        return;
    }
    let text = std::mem::take(assistant);
    pending_events.push(claim, InboxEventKind::Assistant, &text, BTreeMap::new());
}

fn task_prompt(state: &Arc<Mutex<DaemonState>>, claim: &SchedulerClaim) -> Result<String, String> {
    let state = state.lock().map_err(|_| "daemon state lock poisoned")?;
    let snapshot = state
        .workflow
        .current_task_inbox()
        .ok_or_else(|| "TaskInbox projection is missing".to_string())?;
    let task = snapshot
        .tasks
        .iter()
        .find(|task| task.id == claim.task_id)
        .ok_or_else(|| "claimed Task is missing".to_string())?;
    Ok(if task.description.trim().is_empty() {
        task.title.clone()
    } else {
        format!("{}\n\n{}", task.title, task.description)
    })
}

fn update_run_session(
    state: &Arc<Mutex<DaemonState>>,
    claim: &SchedulerClaim,
    session_id: &str,
    prompt_snapshot: Option<&str>,
) -> Result<(), String> {
    let mut state = state.lock().map_err(|_| "daemon state lock poisoned")?;
    let snapshot = state
        .workflow
        .current_task_inbox()
        .ok_or_else(|| "TaskInbox projection is missing".to_string())?;
    let mut run = snapshot
        .runs
        .iter()
        .find(|run| run.id == claim.run_id)
        .cloned()
        .ok_or_else(|| "claimed Run is missing".to_string())?;
    run.session_id = Some(session_id.to_string());
    if let Some(prompt_snapshot) = prompt_snapshot {
        run.prompt_snapshot = Some(prompt_snapshot.to_string());
    }
    let context = context(&mut state, claim)?;
    state
        .workflow
        .apply_task_inbox_as_executor(ExecutorTaskInboxCommand {
            context,
            command: TaskInboxCommand::UpdateRunProjection {
                run,
                updated_at: now(),
            },
        })
        .map_err(|error| error.to_string())?;
    Ok(())
}

fn append_event(
    state: &Arc<Mutex<DaemonState>>,
    claim: &SchedulerClaim,
    kind: InboxEventKind,
    text: &str,
    metadata: BTreeMap<String, Value>,
) -> Result<(), String> {
    let mut pending = PendingEventBatch::default();
    pending.push(claim, kind, text, metadata);
    flush_event_batch(state, claim, &mut pending)
}

fn flush_event_batch(
    state: &Arc<Mutex<DaemonState>>,
    claim: &SchedulerClaim,
    pending: &mut PendingEventBatch,
) -> Result<(), String> {
    if pending.events.is_empty() {
        return Ok(());
    }
    let events = std::mem::take(&mut pending.events);
    pending.bytes = 0;
    let mut state = state.lock().map_err(|_| "daemon state lock poisoned")?;
    let timestamp = now();
    let context = context(&mut state, claim)?;
    state
        .workflow
        .apply_task_inbox_as_executor(ExecutorTaskInboxCommand {
            context,
            command: TaskInboxCommand::AppendEvents {
                events,
                updated_at: timestamp,
            },
        })
        .map_err(|error| error.to_string())?;
    Ok(())
}

fn transition(
    state: &Arc<Mutex<DaemonState>>,
    claim: &SchedulerClaim,
    transition: TaskInboxRunTransition,
    error: Option<String>,
) -> Result<(), String> {
    let mut state = state.lock().map_err(|_| "daemon state lock poisoned")?;
    let timestamp = now();
    let terminal = matches!(
        transition,
        TaskInboxRunTransition::Complete
            | TaskInboxRunTransition::Fail
            | TaskInboxRunTransition::Reject
    );
    let context = context(&mut state, claim)?;
    state
        .workflow
        .apply_task_inbox_as_executor(ExecutorTaskInboxCommand {
            context,
            command: TaskInboxCommand::TransitionRun {
                run_id: claim.run_id.clone(),
                transition,
                updated_at: timestamp.clone(),
                ended_at: terminal.then_some(timestamp),
                error,
            },
        })
        .map_err(|error| error.to_string())?;
    Ok(())
}

fn acknowledge_start(
    state: &Arc<Mutex<DaemonState>>,
    claim: &SchedulerClaim,
) -> Result<(), String> {
    lease_command(state, claim, ExecutorLeaseOperation::AcknowledgeStart)
}

fn heartbeat(state: &Arc<Mutex<DaemonState>>, claim: &SchedulerClaim) -> Result<(), String> {
    lease_command(state, claim, ExecutorLeaseOperation::Heartbeat)
}

fn release(
    state: &Arc<Mutex<DaemonState>>,
    claim: &SchedulerClaim,
    cancelled: bool,
) -> Result<(), String> {
    let mut state = state.lock().map_err(|_| "daemon state lock poisoned")?;
    let context = context(&mut state, claim)?;
    state
        .workflow
        .apply_executor_lease_command(&ExecutorLeaseCommand {
            context,
            operation: if cancelled {
                ExecutorLeaseOperation::Cancel
            } else {
                ExecutorLeaseOperation::Release
            },
            next_expires_at: None,
        })
        .map_err(|error| error.to_string())?;
    Ok(())
}

fn lease_command(
    state: &Arc<Mutex<DaemonState>>,
    claim: &SchedulerClaim,
    operation: ExecutorLeaseOperation,
) -> Result<(), String> {
    let mut state = state.lock().map_err(|_| "daemon state lock poisoned")?;
    let context = context(&mut state, claim)?;
    state
        .workflow
        .apply_executor_lease_command(&ExecutorLeaseCommand {
            context,
            operation,
            next_expires_at: Some(after_seconds(LEASE_TTL_SECONDS)),
        })
        .map_err(|error| error.to_string())?;
    Ok(())
}

fn context(
    state: &mut DaemonState,
    claim: &SchedulerClaim,
) -> Result<ExecutorCommandContext, String> {
    context_for_run(state, &claim.run_id)
}

fn context_for_run(
    state: &mut DaemonState,
    run_id: &str,
) -> Result<ExecutorCommandContext, String> {
    let lease = state
        .workflow
        .executor_lease_for_run(run_id)
        .map_err(|error| error.to_string())?
        .ok_or_else(|| "executor lease is missing".to_string())?;
    Ok(ExecutorCommandContext {
        run_id: run_id.to_string(),
        executor_lease_id: lease.lease_id,
        generation: lease.generation,
        command_id: id("command"),
        now: now(),
    })
}

fn now() -> String {
    DateTime::<Utc>::from(SystemTime::now()).to_rfc3339_opts(SecondsFormat::Millis, true)
}

fn after_seconds(seconds: i64) -> String {
    (DateTime::<Utc>::from(SystemTime::now()) + chrono::Duration::seconds(seconds))
        .to_rfc3339_opts(SecondsFormat::Millis, true)
}

fn after_duration(duration: Duration) -> String {
    let duration = chrono::Duration::from_std(duration).unwrap_or(chrono::Duration::MAX);
    (DateTime::<Utc>::from(SystemTime::now()) + duration)
        .to_rfc3339_opts(SecondsFormat::Millis, true)
}

fn id(prefix: &str) -> String {
    format!("{prefix}-{}", Uuid::new_v4())
}

#[cfg(test)]
mod tests {
    use std::io::Cursor;

    use super::{append_bounded, read_bounded};

    #[test]
    fn bounded_reads_drain_input_without_retaining_past_the_limit() {
        let source = vec![b'x'; 128 * 1024];
        let (captured, truncated) = read_bounded(Cursor::new(source), 1024).unwrap();
        assert_eq!(captured, vec![b'x'; 1024]);
        assert!(truncated);
    }

    #[test]
    fn bounded_text_stops_at_a_utf8_boundary() {
        let mut target = "a".to_string();
        append_bounded(&mut target, "好b", 4);
        assert_eq!(target, "a好");
    }
}
