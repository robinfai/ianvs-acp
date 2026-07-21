use std::collections::BTreeMap;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant, SystemTime};

use chrono::{DateTime, SecondsFormat, Utc};
use ianvs_acp_core::{
    AgentLaunchConfig, ExecutorCommandContext, ExecutorLeaseCommand, ExecutorLeaseOperation,
    ExecutorTaskInboxCommand, InboxEventKind, InboxEventRecord, RuntimeEvent, RuntimeHandle,
    RuntimeStatus, SchedulerCapacityReservation, SchedulerClaim, SchedulerClaimRequest,
    SchedulerConfig, SchedulerRuntimeAvailability, SchedulerRuntimeStatus, SessionUpdate,
    SessionUpdateKind, TaskInboxCommand, TaskInboxRunTransition,
};
use serde_json::Value;
use uuid::Uuid;

use super::DaemonState;

const DISPATCH_INTERVAL: Duration = Duration::from_millis(250);
const AGENT_START_TIMEOUT: Duration = Duration::from_secs(15);
const SESSION_START_TIMEOUT: Duration = Duration::from_secs(30);
const RUN_TIMEOUT: Duration = Duration::from_secs(30 * 60);
const HEARTBEAT_INTERVAL: Duration = Duration::from_secs(10);
const LEASE_TTL_SECONDS: i64 = 30;
const MAX_ASSISTANT_BUFFER_BYTES: usize = 64 * 1024;

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
    let _ = append_event(
        state,
        claim,
        InboxEventKind::Error,
        &error,
        BTreeMap::from([("daemon_error".to_string(), Value::Bool(true))]),
    );
    let _ = transition(state, claim, TaskInboxRunTransition::Fail, Some(error));
    let _ = release(state, claim, false);
}

struct BusyAgentGuard {
    state: Arc<Mutex<DaemonState>>,
    agent_name: String,
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
            supports_permissions: false,
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
    let result = execute_claim_inner(state, config, claim, &runtime);
    if let Err(error) = result {
        let _ = append_event(
            state,
            claim,
            InboxEventKind::Error,
            &error,
            BTreeMap::from([("daemon_error".to_string(), Value::Bool(true))]),
        );
        let _ = transition(state, claim, TaskInboxRunTransition::Fail, Some(error));
    }
    let _ = release(state, claim, false);
    let _ = runtime.dispose();
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
    let create_request_id = id("create-session");
    runtime
        .create_session(
            &create_request_id,
            &claim.workspace_path,
            config.additional_directories.clone(),
        )
        .map_err(|error| error.to_string())?;
    let session_id = wait_for_session(runtime, &create_request_id)?;
    update_run_session(state, claim, &session_id, None)?;
    let prompt = task_prompt(state, claim)?;
    update_run_session(state, claim, &session_id, Some(&prompt))?;
    let prompt_request_id = id("prompt");
    runtime
        .prompt(&prompt_request_id, &session_id, &prompt)
        .map_err(|error| error.to_string())?;
    collect_prompt(state, claim, runtime, &prompt_request_id, &session_id)
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

fn wait_for_session(runtime: &RuntimeHandle, request_id: &str) -> Result<String, String> {
    let deadline = Instant::now() + SESSION_START_TIMEOUT;
    while Instant::now() < deadline {
        if let Some(event) = runtime
            .recv_event_timeout(Duration::from_millis(250))
            .map_err(|error| error.to_string())?
        {
            match event.event {
                RuntimeEvent::SessionUpdate { update }
                    if update.kind == SessionUpdateKind::SessionCreated
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
    while Instant::now() < deadline {
        if Instant::now() >= heartbeat_at {
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
                if handle_session_update(state, claim, prompt_request_id, update, &mut assistant)? {
                    return Ok(());
                }
            }
            RuntimeEvent::PermissionRequest { request } if request.session_id == session_id => {
                flush_assistant(state, claim, &mut assistant)?;
                append_event(
                    state,
                    claim,
                    InboxEventKind::Permission,
                    &format!("Permission requires foreground review: {}", request.title),
                    BTreeMap::from([
                        ("request_id".to_string(), Value::String(request.request_id)),
                        ("tool_kind".to_string(), Value::String(request.tool_kind)),
                    ]),
                )?;
                runtime
                    .cancel(id("cancel"), session_id)
                    .map_err(|error| error.to_string())?;
                transition(state, claim, TaskInboxRunTransition::CollectArtifacts, None)?;
                transition(
                    state,
                    claim,
                    TaskInboxRunTransition::RequireHumanReview,
                    None,
                )?;
                return Ok(());
            }
            RuntimeEvent::RuntimeError {
                request_id,
                message,
                ..
            } if request_id.as_deref() == Some(prompt_request_id) => return Err(message),
            RuntimeEvent::StatusChanged {
                status: RuntimeStatus::Failed,
                detail,
                ..
            } => return Err(detail.unwrap_or_else(|| "agent runtime failed".to_string())),
            _ => {}
        }
    }
    runtime
        .cancel(id("cancel"), session_id)
        .map_err(|error| error.to_string())?;
    Err("agent prompt timed out".to_string())
}

fn handle_session_update(
    state: &Arc<Mutex<DaemonState>>,
    claim: &SchedulerClaim,
    prompt_request_id: &str,
    update: SessionUpdate,
    assistant: &mut String,
) -> Result<bool, String> {
    match update.kind {
        SessionUpdateKind::AgentMessageDelta | SessionUpdateKind::AgentThoughtDelta => {
            if let Some(text) = update.text {
                assistant.push_str(&text);
            }
            if assistant.len() >= MAX_ASSISTANT_BUFFER_BYTES {
                flush_assistant(state, claim, assistant)?;
            }
        }
        SessionUpdateKind::ToolCall | SessionUpdateKind::ToolCallUpdate => {
            flush_assistant(state, claim, assistant)?;
            append_event(
                state,
                claim,
                InboxEventKind::Tool,
                update.text.as_deref().unwrap_or("Agent tool activity"),
                update
                    .payload
                    .map(|payload| BTreeMap::from([("payload".to_string(), payload)]))
                    .unwrap_or_default(),
            )?;
        }
        SessionUpdateKind::PromptCompleted
            if update.request_id.as_deref() == Some(prompt_request_id) =>
        {
            flush_assistant(state, claim, assistant)?;
            transition(state, claim, TaskInboxRunTransition::CollectArtifacts, None)?;
            transition(
                state,
                claim,
                TaskInboxRunTransition::RequireHumanReview,
                None,
            )?;
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

fn flush_assistant(
    state: &Arc<Mutex<DaemonState>>,
    claim: &SchedulerClaim,
    assistant: &mut String,
) -> Result<(), String> {
    if assistant.is_empty() {
        return Ok(());
    }
    let text = std::mem::take(assistant);
    append_event(
        state,
        claim,
        InboxEventKind::Assistant,
        &text,
        BTreeMap::new(),
    )
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
    let mut state = state.lock().map_err(|_| "daemon state lock poisoned")?;
    let timestamp = now();
    let context = context(&mut state, claim)?;
    state
        .workflow
        .apply_task_inbox_as_executor(ExecutorTaskInboxCommand {
            context,
            command: TaskInboxCommand::AppendEvents {
                events: vec![InboxEventRecord {
                    id: id("event"),
                    task_id: claim.task_id.clone(),
                    run_id: claim.run_id.clone(),
                    kind,
                    text: text.to_string(),
                    created_at: timestamp.clone(),
                    session_id: None,
                    metadata,
                }],
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
    let lease = state
        .workflow
        .executor_lease_for_run(&claim.run_id)
        .map_err(|error| error.to_string())?
        .ok_or_else(|| "executor lease is missing".to_string())?;
    Ok(ExecutorCommandContext {
        run_id: claim.run_id.clone(),
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

fn id(prefix: &str) -> String {
    format!("{prefix}-{}", Uuid::new_v4())
}
