use std::cmp::Ordering;
use std::collections::{BTreeMap, HashMap, HashSet};

use chrono::{DateTime, FixedOffset, NaiveDateTime};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use thiserror::Error;

use crate::{
    InboxEventKind, InboxEventRecord, InboxRunRecord, InboxTaskPriority, InboxTaskStatus,
    TaskInboxCommand, TaskInboxMutationError, TaskInboxSnapshot, WorkflowStateMachine,
};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SchedulerConfig {
    pub max_concurrent_tasks: usize,
}

impl Default for SchedulerConfig {
    fn default() -> Self {
        Self {
            max_concurrent_tasks: 1,
        }
    }
}

impl SchedulerConfig {
    pub fn validate(&self) -> Result<(), SchedulerError> {
        if self.max_concurrent_tasks == 0 {
            Err(SchedulerError::InvalidConcurrency)
        } else {
            Ok(())
        }
    }
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
    pub now: String,
    #[serde(default)]
    pub excluded_task_ids: Vec<String>,
}

impl SchedulerClaimRequest {
    fn validate(&self) -> Result<(), SchedulerError> {
        canonical(&self.run_id, "runId")?;
        canonical(&self.dispatch_event_id, "dispatchEventId")?;
        canonical(&self.now, "now")?;
        for task_id in &self.excluded_task_ids {
            canonical(task_id, "excludedTaskIds")?;
        }
        Ok(())
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
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SchedulerPoll {
    pub claim: Option<SchedulerClaim>,
    pub next_wake_at: Option<String>,
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum SchedulerError {
    #[error("scheduler maxConcurrentTasks must be positive")]
    InvalidConcurrency,
    #[error("runtime maxConcurrentTasks must be positive")]
    InvalidRuntimeConcurrency,
    #[error("scheduler field {0} must be canonical non-empty text")]
    InvalidText(&'static str),
    #[error("scheduler field {0} must be a comparable ISO-8601 timestamp")]
    InvalidTimestamp(&'static str),
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

    fn candidates_and_next_wake(
        &self,
        snapshot: &TaskInboxSnapshot,
        workflow: &WorkflowStateMachine,
        request: &SchedulerClaimRequest,
        now: &ParsedTimestamp,
    ) -> Result<(Vec<crate::InboxTaskRecord>, Option<String>), SchedulerError> {
        let excluded = request
            .excluded_task_ids
            .iter()
            .map(String::as_str)
            .collect::<HashSet<_>>();
        let mut candidates = Vec::new();
        let mut next_wake: Option<(ParsedTimestamp, String)> = None;
        for task in &snapshot.tasks {
            if task.status != InboxTaskStatus::Queued
                || excluded.contains(task.id.as_str())
                || !self.runtimes.get(&task.agent_name).is_some_and(|runtime| {
                    runtime.availability == SchedulerRuntimeAvailability::Available
                        && workflow.active_run_count_for_agent(&task.agent_name)
                            < runtime.max_concurrent_tasks
                })
                || workflow.workspace_owner(&task.workspace_path).is_some()
            {
                continue;
            }
            match retry_state(task, now)? {
                RetryState::Ready => candidates.push(task.clone()),
                RetryState::Future { deadline, raw } => {
                    let replace = match next_wake.as_ref() {
                        None => true,
                        Some((earliest, _)) => deadline.compare(earliest)?.is_lt(),
                    };
                    if replace {
                        next_wake = Some((deadline, raw.to_string()));
                    }
                }
            }
        }
        Ok((candidates, next_wake.map(|(_, raw)| raw)))
    }

    pub fn claim_next(
        &self,
        snapshot: &mut TaskInboxSnapshot,
        workflow: &mut WorkflowStateMachine,
        request: SchedulerClaimRequest,
    ) -> Result<SchedulerPoll, SchedulerError> {
        request.validate()?;
        let now = ParsedTimestamp::parse(&request.now, "now")?;
        if workflow.active_run_count() >= self.config.max_concurrent_tasks {
            return Ok(SchedulerPoll {
                claim: None,
                next_wake_at: None,
            });
        }
        let (mut candidates, next_wake_at) =
            self.candidates_and_next_wake(snapshot, workflow, &request, &now)?;
        candidates.sort_by(compare_tasks);
        let Some(task) = candidates.into_iter().next() else {
            return Ok(SchedulerPoll {
                claim: None,
                next_wake_at,
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
                updated_at: request.now,
            },
        )?;
        *snapshot = candidate_snapshot;
        *workflow = candidate_workflow;
        Ok(SchedulerPoll {
            claim: Some(SchedulerClaim {
                task_id: task.id,
                run_id: request.run_id,
                dispatch_event_id: request.dispatch_event_id,
                agent_name: task.agent_name,
                workspace_path: task.workspace_path,
                attempt,
            }),
            next_wake_at: None,
        })
    }
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
}

fn canonical(value: &str, field: &'static str) -> Result<(), SchedulerError> {
    if value.is_empty() || value.trim() != value {
        Err(SchedulerError::InvalidText(field))
    } else {
        Ok(())
    }
}
