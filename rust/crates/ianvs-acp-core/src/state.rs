use std::collections::HashMap;

use thiserror::Error;

use crate::{RuntimeStatus, SessionStatus};

/// Illegal runtime/session transition.
#[derive(Debug, Error, PartialEq, Eq)]
pub enum RuntimeStateError {
    #[error("runtime is {actual:?}; expected one of {expected}")]
    RuntimeState {
        actual: RuntimeStatus,
        expected: &'static str,
    },
    #[error("session already exists: {0}")]
    DuplicateSession(String),
    #[error("unknown session: {0}")]
    UnknownSession(String),
    #[error("session {session_id} is {actual:?}; expected {expected}")]
    SessionState {
        session_id: String,
        actual: SessionStatus,
        expected: &'static str,
    },
}

/// Authoritative lifecycle state machine. Flutter receives projections only.
#[derive(Debug)]
pub struct RuntimeStateMachine {
    runtime: RuntimeStatus,
    sessions: HashMap<String, SessionStatus>,
}

impl Default for RuntimeStateMachine {
    fn default() -> Self {
        Self {
            runtime: RuntimeStatus::Stopped,
            sessions: HashMap::new(),
        }
    }
}

impl RuntimeStateMachine {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    #[must_use]
    pub fn runtime_status(&self) -> RuntimeStatus {
        self.runtime
    }

    #[must_use]
    pub fn session_status(&self, session_id: &str) -> Option<SessionStatus> {
        self.sessions.get(session_id).copied()
    }

    pub fn start_agent(&mut self) -> Result<(), RuntimeStateError> {
        match self.runtime {
            RuntimeStatus::Stopped | RuntimeStatus::Failed => {
                self.runtime = RuntimeStatus::Starting;
                Ok(())
            }
            actual => Err(RuntimeStateError::RuntimeState {
                actual,
                expected: "stopped or failed",
            }),
        }
    }

    pub fn agent_ready(&mut self) -> Result<(), RuntimeStateError> {
        if self.runtime != RuntimeStatus::Starting && self.runtime != RuntimeStatus::Recovering {
            return Err(RuntimeStateError::RuntimeState {
                actual: self.runtime,
                expected: "starting or recovering",
            });
        }
        self.runtime = RuntimeStatus::Ready;
        Ok(())
    }

    pub fn begin_recovery(&mut self) -> Result<(), RuntimeStateError> {
        if self.runtime != RuntimeStatus::Failed {
            return Err(RuntimeStateError::RuntimeState {
                actual: self.runtime,
                expected: "failed",
            });
        }
        self.runtime = RuntimeStatus::Recovering;
        Ok(())
    }

    /// Drop process-generation session states before the next ACP connection
    /// rehydrates them from the recovery registry.
    pub fn reset_sessions_for_recovery(&mut self) -> Result<(), RuntimeStateError> {
        if self.runtime != RuntimeStatus::Recovering {
            return Err(RuntimeStateError::RuntimeState {
                actual: self.runtime,
                expected: "recovering",
            });
        }
        self.sessions.clear();
        Ok(())
    }

    #[must_use]
    pub fn session_count(&self) -> usize {
        self.sessions.len()
    }

    pub fn agent_failed(&mut self) {
        if self.runtime != RuntimeStatus::Disposed {
            self.runtime = RuntimeStatus::Failed;
        }
        for status in self.sessions.values_mut() {
            if !matches!(*status, SessionStatus::Closed) {
                *status = SessionStatus::Failed;
            }
        }
    }

    pub fn begin_session(&self) -> Result<(), RuntimeStateError> {
        self.require_runtime_ready()
    }

    pub fn session_created(
        &mut self,
        session_id: impl Into<String>,
    ) -> Result<(), RuntimeStateError> {
        self.require_runtime_ready()?;
        let session_id = session_id.into();
        if self.sessions.contains_key(&session_id) {
            return Err(RuntimeStateError::DuplicateSession(session_id));
        }
        self.sessions.insert(session_id, SessionStatus::Ready);
        Ok(())
    }

    pub fn prompt_started(&mut self, session_id: &str) -> Result<(), RuntimeStateError> {
        self.require_runtime_ready()?;
        self.transition_session(
            session_id,
            &[SessionStatus::Ready],
            SessionStatus::Running,
            "ready",
        )
    }

    pub fn permission_requested(&mut self, session_id: &str) -> Result<(), RuntimeStateError> {
        if let Some(SessionStatus::Ready | SessionStatus::WaitingPermission) =
            self.session_status(session_id)
        {
            return Ok(());
        }
        self.transition_session(
            session_id,
            &[SessionStatus::Running],
            SessionStatus::WaitingPermission,
            "running",
        )
    }

    pub fn permission_resolved(&mut self, session_id: &str) -> Result<(), RuntimeStateError> {
        if self.session_status(session_id) == Some(SessionStatus::Ready) {
            return Ok(());
        }
        self.transition_session(
            session_id,
            &[SessionStatus::WaitingPermission],
            SessionStatus::Running,
            "waiting_permission",
        )
    }

    pub fn cancel_started(&mut self, session_id: &str) -> Result<(), RuntimeStateError> {
        self.transition_session(
            session_id,
            &[SessionStatus::Running, SessionStatus::WaitingPermission],
            SessionStatus::Cancelling,
            "running or waiting_permission",
        )
    }

    pub fn prompt_finished(&mut self, session_id: &str) -> Result<(), RuntimeStateError> {
        self.transition_session(
            session_id,
            &[
                SessionStatus::Running,
                SessionStatus::WaitingPermission,
                SessionStatus::Cancelling,
            ],
            SessionStatus::Ready,
            "running, waiting_permission, or cancelling",
        )
    }

    pub fn close_session(&mut self, session_id: &str) -> Result<(), RuntimeStateError> {
        let status = self
            .sessions
            .get_mut(session_id)
            .ok_or_else(|| RuntimeStateError::UnknownSession(session_id.to_string()))?;
        *status = SessionStatus::Closed;
        Ok(())
    }

    pub fn forget_session(&mut self, session_id: &str) {
        self.sessions.remove(session_id);
    }

    pub fn dispose(&mut self) {
        self.runtime = RuntimeStatus::Disposed;
        for status in self.sessions.values_mut() {
            *status = SessionStatus::Closed;
        }
    }

    fn require_runtime_ready(&self) -> Result<(), RuntimeStateError> {
        if self.runtime == RuntimeStatus::Ready {
            Ok(())
        } else {
            Err(RuntimeStateError::RuntimeState {
                actual: self.runtime,
                expected: "ready",
            })
        }
    }

    fn transition_session(
        &mut self,
        session_id: &str,
        allowed: &[SessionStatus],
        next: SessionStatus,
        expected: &'static str,
    ) -> Result<(), RuntimeStateError> {
        let status = self
            .sessions
            .get_mut(session_id)
            .ok_or_else(|| RuntimeStateError::UnknownSession(session_id.to_string()))?;
        if !allowed.contains(status) {
            return Err(RuntimeStateError::SessionState {
                session_id: session_id.to_string(),
                actual: *status,
                expected,
            });
        }
        *status = next;
        Ok(())
    }
}
