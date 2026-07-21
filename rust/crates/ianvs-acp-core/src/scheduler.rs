use std::cmp::Ordering;
use std::collections::{BTreeMap, HashMap, HashSet};

use chrono::{DateTime, FixedOffset, NaiveDateTime};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use thiserror::Error;

use crate::{
    ExecutorLease, ExecutorLeaseState, InboxEventKind, InboxEventRecord, InboxRunRecord,
    InboxTaskPriority, InboxTaskStatus, TaskInboxCommand, TaskInboxMutationError,
    TaskInboxSnapshot, WorkflowStateMachine,
};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SchedulerConfig {
    pub max_concurrent_tasks: usize,
    #[serde(default = "default_runtime_status_freshness_seconds")]
    pub runtime_status_freshness_seconds: u64,
}

impl Default for SchedulerConfig {
    fn default() -> Self {
        Self {
            max_concurrent_tasks: 1,
            runtime_status_freshness_seconds: default_runtime_status_freshness_seconds(),
        }
    }
}

impl SchedulerConfig {
    pub fn validate(&self) -> Result<(), SchedulerError> {
        if self.max_concurrent_tasks == 0 {
            return Err(SchedulerError::InvalidConcurrency);
        }
        if self.runtime_status_freshness_seconds == 0 {
            return Err(SchedulerError::InvalidRuntimeFreshness);
        }
        Ok(())
    }
}

const fn default_runtime_status_freshness_seconds() -> u64 {
    30
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SchedulerRuntimeAvailability {
    Unknown,
    Available,
    Busy,
    Unavailable,
    AuthRequired,
    Misconfigured,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SchedulerRuntimeStatus {
    pub agent_name: String,
    pub availability: SchedulerRuntimeAvailability,
    pub observed_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub unavailable_reason: Option<String>,
    #[serde(default)]
    pub supports_session_resume: bool,
    #[serde(default)]
    pub supports_permissions: bool,
    pub max_concurrent_tasks: usize,
}

impl SchedulerRuntimeStatus {
    fn validate(&self) -> Result<(), SchedulerError> {
        canonical(&self.agent_name, "agentName")?;
        canonical(&self.observed_at, "observedAt")?;
        if self
            .unavailable_reason
            .as_deref()
            .is_some_and(|reason| reason.is_empty() || reason.trim() != reason)
        {
            return Err(SchedulerError::InvalidText("unavailableReason"));
        }
        if self.max_concurrent_tasks == 0 {
            return Err(SchedulerError::InvalidRuntimeConcurrency);
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SchedulerClaimRequest {
    pub run_id: String,
    pub dispatch_event_id: String,
    pub executor_lease_id: String,
    pub executor_id: String,
    pub command_id: String,
    pub now: String,
    pub lease_expires_at: String,
    #[serde(default)]
    pub excluded_task_ids: Vec<String>,
    #[serde(default)]
    pub capacity_reservations: Vec<SchedulerCapacityReservation>,
}

impl SchedulerClaimRequest {
    fn validate(&self) -> Result<(), SchedulerError> {
        canonical(&self.run_id, "runId")?;
        canonical(&self.dispatch_event_id, "dispatchEventId")?;
        canonical(&self.executor_lease_id, "executorLeaseId")?;
        canonical(&self.executor_id, "executorId")?;
        canonical(&self.command_id, "commandId")?;
        canonical(&self.now, "now")?;
        canonical(&self.lease_expires_at, "leaseExpiresAt")?;
        let now = ParsedTimestamp::parse(&self.now, "now")?;
        let lease_expires_at = ParsedTimestamp::parse(&self.lease_expires_at, "leaseExpiresAt")?;
        if !lease_expires_at.compare(&now)?.is_gt() {
            return Err(SchedulerError::InvalidReservationWindow);
        }
        for task_id in &self.excluded_task_ids {
            canonical(task_id, "excludedTaskIds")?;
        }
        if self.capacity_reservations.len() > 256 {
            return Err(SchedulerError::TooManyReservations);
        }
        let mut reservation_ids = HashSet::new();
        for reservation in &self.capacity_reservations {
            reservation.validate()?;
            if !reservation_ids.insert(reservation.reservation_id.as_str()) {
                return Err(SchedulerError::DuplicateReservation);
            }
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SchedulerCapacityReservation {
    pub reservation_id: String,
    pub agent_name: String,
    pub host_instance_id: String,
    pub created_at: String,
    pub expires_at: String,
}

impl SchedulerCapacityReservation {
    fn validate(&self) -> Result<(), SchedulerError> {
        canonical(&self.reservation_id, "reservationId")?;
        canonical(&self.agent_name, "agentName")?;
        canonical(&self.host_instance_id, "hostInstanceId")?;
        let created_at = ParsedTimestamp::parse(&self.created_at, "createdAt")?;
        let expires_at = ParsedTimestamp::parse(&self.expires_at, "expiresAt")?;
        if !created_at.compare(&expires_at)?.is_lt() {
            return Err(SchedulerError::InvalidReservationWindow);
        }
        Ok(())
    }

    fn is_active_at(&self, now: &ParsedTimestamp) -> Result<bool, SchedulerError> {
        let created_at = ParsedTimestamp::parse(&self.created_at, "createdAt")?;
        let expires_at = ParsedTimestamp::parse(&self.expires_at, "expiresAt")?;
        Ok(!created_at.compare(now)?.is_gt() && expires_at.compare(now)?.is_gt())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SchedulerClaim {
    pub task_id: String,
    pub run_id: String,
    pub dispatch_event_id: String,
    pub agent_name: String,
    pub workspace_path: String,
    pub attempt: u32,
    pub reservation_id: String,
    pub executor_lease: ExecutorLease,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SchedulerAdmissionReason {
    Claimed,
    QueueEmpty,
    GlobalCapacity,
    NoExecutorCapacity,
    AgentCapacity,
    RuntimeUnavailable,
    RuntimeStatusStale,
    WorkspaceBusy,
    RetryNotReady,
    NoMatchingRuntime,
    Excluded,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SchedulerAdmission {
    pub reason: SchedulerAdmissionReason,
    pub retryable: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub next_wake_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub selected_reservation_id: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub blocked_task_ids: Vec<String>,
}

impl SchedulerAdmission {
    fn no_claim(
        reason: SchedulerAdmissionReason,
        next_wake_at: Option<String>,
        blocked_task_ids: Vec<String>,
    ) -> Self {
        Self {
            reason,
            retryable: !matches!(
                reason,
                SchedulerAdmissionReason::QueueEmpty | SchedulerAdmissionReason::Excluded
            ),
            next_wake_at,
            selected_reservation_id: None,
            blocked_task_ids,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SchedulerPoll {
    pub claim: Option<SchedulerClaim>,
    pub next_wake_at: Option<String>,
    pub admission: SchedulerAdmission,
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum SchedulerError {
    #[error("scheduler maxConcurrentTasks must be positive")]
    InvalidConcurrency,
    #[error("scheduler runtimeStatusFreshnessSeconds must be positive")]
    InvalidRuntimeFreshness,
    #[error("runtime maxConcurrentTasks must be positive")]
    InvalidRuntimeConcurrency,
    #[error("scheduler field {0} must be canonical non-empty text")]
    InvalidText(&'static str),
    #[error("scheduler field {0} must be a comparable ISO-8601 timestamp")]
    InvalidTimestamp(&'static str),
    #[error("scheduler capacity reservation window must have createdAt before expiresAt")]
    InvalidReservationWindow,
    #[error("scheduler claim has too many capacity reservations")]
    TooManyReservations,
    #[error("scheduler capacity reservation ids must be unique")]
    DuplicateReservation,
    #[error(transparent)]
    Mutation(#[from] TaskInboxMutationError),
}

#[derive(Debug, Default)]
pub struct SchedulerCore {
    config: SchedulerConfig,
    runtimes: HashMap<String, SchedulerRuntimeStatus>,
}

impl SchedulerCore {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    pub fn configure(&mut self, config: SchedulerConfig) -> Result<(), SchedulerError> {
        config.validate()?;
        self.config = config;
        Ok(())
    }

    pub fn set_runtime_status(
        &mut self,
        status: SchedulerRuntimeStatus,
    ) -> Result<(), SchedulerError> {
        status.validate()?;
        self.runtimes.insert(status.agent_name.clone(), status);
        Ok(())
    }

    #[must_use]
    pub fn runtime_status(&self, agent_name: &str) -> Option<&SchedulerRuntimeStatus> {
        self.runtimes.get(agent_name)
    }

    fn candidates_and_admission(
        &self,
        snapshot: &TaskInboxSnapshot,
        workflow: &WorkflowStateMachine,
        request: &SchedulerClaimRequest,
        now: &ParsedTimestamp,
    ) -> Result<
        (
            Vec<(crate::InboxTaskRecord, SchedulerCapacityReservation)>,
            SchedulerAdmission,
        ),
        SchedulerError,
    > {
        let excluded = request
            .excluded_task_ids
            .iter()
            .map(String::as_str)
            .collect::<HashSet<_>>();
        let mut reservations_by_agent = HashMap::new();
        for reservation in &request.capacity_reservations {
            if reservation.is_active_at(now)? {
                reservations_by_agent
                    .entry(reservation.agent_name.as_str())
                    .or_insert_with(|| reservation.clone());
            }
        }
        let mut candidates = Vec::new();
        let mut next_wake: Option<(ParsedTimestamp, String)> = None;
        let mut blockers = Vec::new();
        for task in &snapshot.tasks {
            if task.status != InboxTaskStatus::Queued {
                continue;
            }
            if excluded.contains(task.id.as_str()) {
                blockers.push((task.id.clone(), SchedulerAdmissionReason::Excluded));
                continue;
            }
            match retry_state(task, now)? {
                RetryState::Ready => {}
                RetryState::Future { deadline, raw } => {
                    let replace = match next_wake.as_ref() {
                        None => true,
                        Some((earliest, _)) => deadline.compare(earliest)?.is_lt(),
                    };
                    if replace {
                        next_wake = Some((deadline, raw.to_string()));
                    }
                    blockers.push((task.id.clone(), SchedulerAdmissionReason::RetryNotReady));
                    continue;
                }
            }
            let Some(runtime) = self.runtimes.get(&task.agent_name) else {
                blockers.push((task.id.clone(), SchedulerAdmissionReason::NoMatchingRuntime));
                continue;
            };
            if runtime.is_stale_at(now, self.config.runtime_status_freshness_seconds)? {
                blockers.push((
                    task.id.clone(),
                    SchedulerAdmissionReason::RuntimeStatusStale,
                ));
                continue;
            }
            match runtime.availability {
                SchedulerRuntimeAvailability::Available => {}
                SchedulerRuntimeAvailability::Busy => {
                    blockers.push((task.id.clone(), SchedulerAdmissionReason::AgentCapacity));
                    continue;
                }
                SchedulerRuntimeAvailability::Unknown
                | SchedulerRuntimeAvailability::Unavailable
                | SchedulerRuntimeAvailability::AuthRequired
                | SchedulerRuntimeAvailability::Misconfigured => {
                    blockers.push((
                        task.id.clone(),
                        SchedulerAdmissionReason::RuntimeUnavailable,
                    ));
                    continue;
                }
            }
            if workflow.active_execution_count_for_agent(&task.agent_name)
                >= runtime.max_concurrent_tasks
            {
                blockers.push((task.id.clone(), SchedulerAdmissionReason::AgentCapacity));
                continue;
            }
            if workflow.workspace_owner(&task.workspace_path).is_some() {
                blockers.push((task.id.clone(), SchedulerAdmissionReason::WorkspaceBusy));
                continue;
            }
            let Some(reservation) = reservations_by_agent.get(task.agent_name.as_str()) else {
                blockers.push((
                    task.id.clone(),
                    SchedulerAdmissionReason::NoExecutorCapacity,
                ));
                continue;
            };
            candidates.push((task.clone(), reservation.clone()));
        }
        let next_wake_at = next_wake.map(|(_, raw)| raw);
        let reason = preferred_blocker(&blockers);
        let blocked_task_ids = blockers
            .iter()
            .map(|(task_id, _)| task_id.clone())
            .take(256)
            .collect();
        Ok((
            candidates,
            SchedulerAdmission::no_claim(reason, next_wake_at, blocked_task_ids),
        ))
    }

    #[allow(clippy::too_many_lines)]
    pub fn claim_next(
        &self,
        snapshot: &mut TaskInboxSnapshot,
        workflow: &mut WorkflowStateMachine,
        request: SchedulerClaimRequest,
    ) -> Result<SchedulerPoll, SchedulerError> {
        request.validate()?;
        let now = ParsedTimestamp::parse(&request.now, "now")?;
        if workflow.active_execution_count() >= self.config.max_concurrent_tasks {
            return Ok(SchedulerPoll {
                claim: None,
                next_wake_at: None,
                admission: SchedulerAdmission::no_claim(
                    SchedulerAdmissionReason::GlobalCapacity,
                    None,
                    Vec::new(),
                ),
            });
        }
        let (mut candidates, admission) =
            self.candidates_and_admission(snapshot, workflow, &request, &now)?;
        candidates.sort_by(|(left, _), (right, _)| compare_tasks(left, right));
        let Some((task, reservation)) = candidates.into_iter().next() else {
            return Ok(SchedulerPoll {
                claim: None,
                next_wake_at: admission.next_wake_at.clone(),
                admission,
            });
        };
        let attempt = workflow
            .task(&task.id)
            .map_err(TaskInboxMutationError::from)?
            .attempt
            .checked_add(1)
            .ok_or(TaskInboxMutationError::InvalidNewRun)?;
        let run = InboxRunRecord {
            id: request.run_id.clone(),
            task_id: task.id.clone(),
            attempt,
            status: InboxTaskStatus::Dispatched,
            started_at: request.now.clone(),
            ended_at: None,
            session_id: None,
            prompt_snapshot: None,
            model: None,
            error: None,
        };
        let event = InboxEventRecord {
            id: request.dispatch_event_id.clone(),
            task_id: task.id.clone(),
            run_id: request.run_id.clone(),
            kind: InboxEventKind::System,
            text: "Task dispatched.".to_string(),
            created_at: request.now.clone(),
            session_id: None,
            metadata: BTreeMap::from([(
                "task_status".to_string(),
                Value::String("dispatched".to_string()),
            )]),
        };

        let mut candidate_snapshot = snapshot.clone();
        let mut candidate_workflow = WorkflowStateMachine::restore(workflow.snapshot())
            .map_err(TaskInboxMutationError::from)?;
        candidate_snapshot.apply_command(
            &mut candidate_workflow,
            TaskInboxCommand::DispatchRun {
                run,
                updated_at: request.now.clone(),
            },
        )?;
        candidate_snapshot.apply_command(
            &mut candidate_workflow,
            TaskInboxCommand::AppendEvents {
                events: vec![event],
                updated_at: request.now.clone(),
            },
        )?;
        *snapshot = candidate_snapshot;
        *workflow = candidate_workflow;
        let executor_lease = ExecutorLease {
            lease_id: request.executor_lease_id,
            run_id: request.run_id.clone(),
            executor_id: request.executor_id,
            generation: 1,
            reservation_id: reservation.reservation_id.clone(),
            acquired_at: request.now.clone(),
            expires_at: request.lease_expires_at,
            last_heartbeat_at: request.now,
            start_acknowledged_at: None,
            released_at: None,
            state: ExecutorLeaseState::Claimed,
        };
        let claim = SchedulerClaim {
            task_id: task.id,
            run_id: request.run_id,
            dispatch_event_id: request.dispatch_event_id,
            agent_name: task.agent_name,
            workspace_path: task.workspace_path,
            attempt,
            reservation_id: reservation.reservation_id.clone(),
            executor_lease,
        };
        Ok(SchedulerPoll {
            claim: Some(claim),
            next_wake_at: None,
            admission: SchedulerAdmission {
                reason: SchedulerAdmissionReason::Claimed,
                retryable: false,
                next_wake_at: None,
                selected_reservation_id: Some(reservation.reservation_id),
                blocked_task_ids: Vec::new(),
            },
        })
    }
}

impl SchedulerRuntimeStatus {
    fn is_stale_at(
        &self,
        now: &ParsedTimestamp,
        freshness_seconds: u64,
    ) -> Result<bool, SchedulerError> {
        let observed_at = ParsedTimestamp::parse(&self.observed_at, "observedAt")?;
        if observed_at.compare(now)?.is_gt() {
            return Ok(true);
        }
        let freshness_seconds = i64::try_from(freshness_seconds)
            .map_err(|_| SchedulerError::InvalidRuntimeFreshness)?;
        let expires_at = observed_at.add_seconds(freshness_seconds)?;
        Ok(!expires_at.compare(now)?.is_gt())
    }
}

fn preferred_blocker(blockers: &[(String, SchedulerAdmissionReason)]) -> SchedulerAdmissionReason {
    const PRECEDENCE: [SchedulerAdmissionReason; 9] = [
        SchedulerAdmissionReason::RuntimeStatusStale,
        SchedulerAdmissionReason::RuntimeUnavailable,
        SchedulerAdmissionReason::RetryNotReady,
        SchedulerAdmissionReason::WorkspaceBusy,
        SchedulerAdmissionReason::AgentCapacity,
        SchedulerAdmissionReason::NoExecutorCapacity,
        SchedulerAdmissionReason::NoMatchingRuntime,
        SchedulerAdmissionReason::Excluded,
        SchedulerAdmissionReason::QueueEmpty,
    ];
    PRECEDENCE
        .into_iter()
        .find(|reason| blockers.iter().any(|(_, candidate)| candidate == reason))
        .unwrap_or(SchedulerAdmissionReason::QueueEmpty)
}

fn compare_tasks(left: &crate::InboxTaskRecord, right: &crate::InboxTaskRecord) -> Ordering {
    priority_rank(right.priority)
        .cmp(&priority_rank(left.priority))
        .then_with(|| left.created_at.cmp(&right.created_at))
        .then_with(|| left.id.cmp(&right.id))
}

const fn priority_rank(priority: InboxTaskPriority) -> u8 {
    match priority {
        InboxTaskPriority::Low => 0,
        InboxTaskPriority::Normal => 1,
        InboxTaskPriority::High => 2,
        InboxTaskPriority::Urgent => 3,
    }
}

enum RetryState<'a> {
    Ready,
    Future {
        deadline: ParsedTimestamp,
        raw: &'a str,
    },
}

fn retry_state<'a>(
    task: &'a crate::InboxTaskRecord,
    now: &ParsedTimestamp,
) -> Result<RetryState<'a>, SchedulerError> {
    let Some(value) = task.metadata.get("next_retry_at") else {
        return Ok(RetryState::Ready);
    };
    let raw = value
        .as_str()
        .ok_or(SchedulerError::InvalidTimestamp("nextRetryAt"))?;
    let deadline = ParsedTimestamp::parse(raw, "nextRetryAt")?;
    if deadline.compare(now)?.is_le() {
        Ok(RetryState::Ready)
    } else {
        Ok(RetryState::Future { deadline, raw })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum ParsedTimestamp {
    Absolute(DateTime<FixedOffset>),
    Local(NaiveDateTime),
}

impl ParsedTimestamp {
    fn parse(value: &str, field: &'static str) -> Result<Self, SchedulerError> {
        DateTime::parse_from_rfc3339(value)
            .map(Self::Absolute)
            .or_else(|_| {
                NaiveDateTime::parse_from_str(value, "%Y-%m-%dT%H:%M:%S%.f").map(Self::Local)
            })
            .map_err(|_| SchedulerError::InvalidTimestamp(field))
    }

    fn compare(&self, other: &Self) -> Result<Ordering, SchedulerError> {
        match (self, other) {
            (Self::Absolute(left), Self::Absolute(right)) => Ok(left.cmp(right)),
            (Self::Local(left), Self::Local(right)) => Ok(left.cmp(right)),
            _ => Err(SchedulerError::InvalidTimestamp("nextRetryAt")),
        }
    }

    fn add_seconds(&self, seconds: i64) -> Result<Self, SchedulerError> {
        match self {
            Self::Absolute(value) => value
                .checked_add_signed(chrono::Duration::seconds(seconds))
                .map(Self::Absolute),
            Self::Local(value) => value
                .checked_add_signed(chrono::Duration::seconds(seconds))
                .map(Self::Local),
        }
        .ok_or(SchedulerError::InvalidTimestamp("observedAt"))
    }
}

fn canonical(value: &str, field: &'static str) -> Result<(), SchedulerError> {
    if value.is_empty() || value.trim() != value {
        Err(SchedulerError::InvalidText(field))
    } else {
        Ok(())
    }
}
