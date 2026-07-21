use chrono::{DateTime, FixedOffset};
use serde::{Deserialize, Serialize};
use thiserror::Error;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ExecutorLeaseState {
    Claimed,
    Starting,
    Active,
    Expired,
    Released,
    Superseded,
}

impl ExecutorLeaseState {
    #[must_use]
    pub const fn accepts_mutation(self) -> bool {
        matches!(self, Self::Claimed | Self::Starting | Self::Active)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ExecutorLease {
    pub lease_id: String,
    pub run_id: String,
    pub executor_id: String,
    pub generation: u64,
    pub reservation_id: String,
    pub acquired_at: String,
    pub expires_at: String,
    pub last_heartbeat_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub start_acknowledged_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub released_at: Option<String>,
    pub state: ExecutorLeaseState,
}

impl ExecutorLease {
    pub fn validate(&self) -> Result<(), ExecutionError> {
        canonical(&self.lease_id, "leaseId")?;
        canonical(&self.run_id, "runId")?;
        canonical(&self.executor_id, "executorId")?;
        canonical(&self.reservation_id, "reservationId")?;
        if self.generation == 0 {
            return Err(ExecutionError::InvalidGeneration);
        }
        let acquired_at = timestamp(&self.acquired_at, "acquiredAt")?;
        let expires_at = timestamp(&self.expires_at, "expiresAt")?;
        let heartbeat_at = timestamp(&self.last_heartbeat_at, "lastHeartbeatAt")?;
        if acquired_at > heartbeat_at || heartbeat_at >= expires_at {
            return Err(ExecutionError::InvalidLeaseWindow);
        }
        if let Some(started_at) = &self.start_acknowledged_at {
            let started_at = timestamp(started_at, "startAcknowledgedAt")?;
            if started_at < acquired_at || started_at >= expires_at {
                return Err(ExecutionError::InvalidLeaseWindow);
            }
        }
        if let Some(released_at) = &self.released_at {
            timestamp(released_at, "releasedAt")?;
        }
        Ok(())
    }

    pub fn is_expired_at(&self, now: &str) -> Result<bool, ExecutionError> {
        Ok(timestamp(&self.expires_at, "expiresAt")? <= timestamp(now, "now")?)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ExecutorCommandContext {
    pub run_id: String,
    pub executor_lease_id: String,
    pub generation: u64,
    pub command_id: String,
    pub now: String,
}

impl ExecutorCommandContext {
    pub fn validate(&self) -> Result<(), ExecutionError> {
        canonical(&self.run_id, "runId")?;
        canonical(&self.executor_lease_id, "executorLeaseId")?;
        canonical(&self.command_id, "commandId")?;
        timestamp(&self.now, "now")?;
        if self.generation == 0 {
            return Err(ExecutionError::InvalidGeneration);
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ExecutorLeaseOperation {
    AcknowledgeStart,
    Heartbeat,
    Release,
    Cancel,
    MarkOrphaned,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ExecutorLeaseCommand {
    pub context: ExecutorCommandContext,
    pub operation: ExecutorLeaseOperation,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub next_expires_at: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ExecutorTakeoverRequest {
    pub run_id: String,
    pub previous_lease_id: String,
    pub executor_lease_id: String,
    pub executor_id: String,
    pub reservation_id: String,
    pub command_id: String,
    pub now: String,
    pub expires_at: String,
}

impl ExecutorTakeoverRequest {
    pub fn validate(&self) -> Result<(), ExecutionError> {
        canonical(&self.run_id, "runId")?;
        canonical(&self.previous_lease_id, "previousLeaseId")?;
        canonical(&self.executor_lease_id, "executorLeaseId")?;
        canonical(&self.executor_id, "executorId")?;
        canonical(&self.reservation_id, "reservationId")?;
        canonical(&self.command_id, "commandId")?;
        let now = timestamp(&self.now, "now")?;
        let expires_at = timestamp(&self.expires_at, "expiresAt")?;
        if expires_at <= now {
            return Err(ExecutionError::InvalidLeaseWindow);
        }
        Ok(())
    }
}

impl ExecutorLeaseCommand {
    pub fn validate(&self) -> Result<(), ExecutionError> {
        self.context.validate()?;
        if matches!(
            self.operation,
            ExecutorLeaseOperation::AcknowledgeStart | ExecutorLeaseOperation::Heartbeat
        ) {
            let expires_at = self
                .next_expires_at
                .as_deref()
                .ok_or(ExecutionError::MissingLeaseExpiry)?;
            if timestamp(expires_at, "nextExpiresAt")? <= timestamp(&self.context.now, "now")? {
                return Err(ExecutionError::InvalidLeaseWindow);
            }
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RecoveryState {
    Requeued,
    Orphaned,
    Waiting,
    ReviewRequired,
    Terminal,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PromptSubmissionState {
    NotSubmitted,
    Submitted,
    Unknown,
    NotApplicable,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WorkspaceMutationPossibility {
    None,
    ReadOnly,
    Possible,
    Confirmed,
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SuggestedRecoveryAction {
    Requeue,
    ResumeSession,
    RetryReadOnly,
    HumanReview,
    KeepWaiting,
    Terminal,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RunRecoveryRecord {
    pub task_id: String,
    pub run_id: String,
    pub previous_state: String,
    pub recovery_state: RecoveryState,
    pub reason: String,
    pub prompt_submission_state: PromptSubmissionState,
    pub workspace_mutation_possibility: WorkspaceMutationPossibility,
    pub suggested_action: SuggestedRecoveryAction,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub executor_lease_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ClassifiedRecoveryReport {
    pub detected_at: String,
    pub runs: Vec<RunRecoveryRecord>,
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum ExecutionError {
    #[error("execution field {0} must be canonical non-empty text")]
    InvalidText(&'static str),
    #[error("execution field {0} must be an RFC-3339 timestamp")]
    InvalidTimestamp(&'static str),
    #[error("executor generation must be positive")]
    InvalidGeneration,
    #[error("executor lease timestamps are not ordered")]
    InvalidLeaseWindow,
    #[error("executor lease command requires nextExpiresAt")]
    MissingLeaseExpiry,
    #[error("executor lease was not found")]
    UnknownLease,
    #[error("executor lease does not belong to the run")]
    LeaseRunMismatch,
    #[error("executor lease generation is stale")]
    StaleGeneration,
    #[error("executor lease is expired or no longer active")]
    LeaseInactive,
    #[error("executor lease heartbeat timestamps cannot move backwards")]
    LeaseClockRegression,
    #[error("active Run mutations require a fenced executor command context")]
    FencedMutationRequired,
    #[error("executor takeover requires the current lease to be expired")]
    TakeoverBeforeExpiry,
    #[error("command id was reused with a different payload")]
    IdempotencyConflict,
    #[error("idempotency payload or result could not be encoded")]
    IdempotencyEncoding,
    #[error("idempotency payload exceeds the bounded size limit")]
    IdempotencyPayloadTooLarge,
    #[error("idempotency result exceeds the bounded size limit")]
    IdempotencyResultTooLarge,
}

fn canonical(value: &str, field: &'static str) -> Result<(), ExecutionError> {
    if value.is_empty() || value.trim() != value {
        Err(ExecutionError::InvalidText(field))
    } else {
        Ok(())
    }
}

fn timestamp(value: &str, field: &'static str) -> Result<DateTime<FixedOffset>, ExecutionError> {
    DateTime::parse_from_rfc3339(value).map_err(|_| ExecutionError::InvalidTimestamp(field))
}
