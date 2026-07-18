use std::time::Duration;

use serde::{Deserialize, Serialize};

/// Stable failure categories used by the workflow scheduler.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskFailureReason {
    RuntimeOffline,
    Timeout,
    AuthRequired,
    TransientRuntimeError,
    AgentError,
    PermissionDenied,
    ArtifactCollectionFailed,
    HumanRejected,
}

/// Retry policy owned by the background runtime rather than a UI controller.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RetryPolicy {
    pub base_delay: Duration,
    pub runtime_offline_retries: u32,
    pub timeout_retries: u32,
    pub transient_runtime_error_retries: u32,
}

impl Default for RetryPolicy {
    fn default() -> Self {
        Self {
            base_delay: Duration::from_secs(30),
            runtime_offline_retries: 2,
            timeout_retries: 1,
            transient_runtime_error_retries: 2,
        }
    }
}

impl RetryPolicy {
    #[must_use]
    pub fn should_retry(self, reason: TaskFailureReason, attempt: u32) -> bool {
        attempt > 0 && attempt <= self.retry_limit(reason)
    }

    #[must_use]
    pub fn delay_for_attempt(self, attempt: u32) -> Duration {
        if attempt <= 1 || self.base_delay.is_zero() {
            return self.base_delay;
        }
        let exponent = attempt.saturating_sub(1).min(31);
        self.base_delay.saturating_mul(1_u32 << exponent)
    }

    const fn retry_limit(self, reason: TaskFailureReason) -> u32 {
        match reason {
            TaskFailureReason::RuntimeOffline => self.runtime_offline_retries,
            TaskFailureReason::Timeout => self.timeout_retries,
            TaskFailureReason::TransientRuntimeError => self.transient_runtime_error_retries,
            TaskFailureReason::AuthRequired
            | TaskFailureReason::AgentError
            | TaskFailureReason::PermissionDenied
            | TaskFailureReason::ArtifactCollectionFailed
            | TaskFailureReason::HumanRejected => 0,
        }
    }
}
