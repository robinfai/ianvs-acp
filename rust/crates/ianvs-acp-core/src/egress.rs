use std::collections::HashMap;

use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::{WorkspaceError, WorkspaceScope};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EgressKind {
    FileWrite,
    CommandExecution,
    GitPush,
    PullRequest,
    ExternalCopy,
    HttpUpload,
    Webhook,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EgressIntent {
    pub id: String,
    pub task_id: Option<String>,
    pub session_id: Option<String>,
    pub kind: EgressKind,
    pub summary: String,
    pub workspace_path: String,
    pub target: Option<String>,
    #[serde(default)]
    pub command: Vec<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum HumanEgressDecision {
    AllowOnce,
    Deny,
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum EgressError {
    #[error("egress intent id must not be empty")]
    InvalidIntentId,
    #[error("egress summary must not be empty")]
    InvalidSummary,
    #[error("egress intent requires a target")]
    MissingTarget,
    #[error("command execution intent requires argv")]
    MissingCommand,
    #[error("egress intent already exists: {0}")]
    DuplicateIntent(String),
    #[error("egress intent is not pending: {0}")]
    UnknownIntent(String),
    #[error(transparent)]
    Workspace(#[from] WorkspaceError),
}

/// A one-shot authorization token. Its fields and constructor are private, so
/// side-effecting Core code can require this type instead of trusting a bool
/// supplied by Flutter.
#[derive(Debug)]
pub struct EgressPermit {
    intent: EgressIntent,
}

impl EgressPermit {
    #[must_use]
    pub fn intent(&self) -> &EgressIntent {
        &self.intent
    }

    #[must_use]
    pub fn consume(self) -> EgressIntent {
        self.intent
    }
}

/// Rust-owned first-wins admission gate for externally visible side effects.
/// It intentionally has no policy-based allow-all operation.
#[derive(Debug, Default)]
pub struct HumanEgressGate {
    pending: HashMap<String, EgressIntent>,
}

impl HumanEgressGate {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    pub fn request(
        &mut self,
        mut intent: EgressIntent,
        workspace: &WorkspaceScope,
    ) -> Result<&EgressIntent, EgressError> {
        intent.id = checked_text(intent.id, EgressError::InvalidIntentId)?;
        intent.summary = checked_text(intent.summary, EgressError::InvalidSummary)?;
        if self.pending.contains_key(&intent.id) {
            return Err(EgressError::DuplicateIntent(intent.id));
        }
        if intent.workspace_path != workspace.cwd().display().to_string() {
            return Err(EgressError::Workspace(WorkspaceError::OutsideWorkspace(
                intent.workspace_path,
            )));
        }
        match intent.kind {
            EgressKind::FileWrite => {
                let target = intent.target.as_deref().ok_or(EgressError::MissingTarget)?;
                intent.target = Some(
                    workspace
                        .resolve_for_creation(target)?
                        .display()
                        .to_string(),
                );
            }
            EgressKind::CommandExecution | EgressKind::GitPush | EgressKind::PullRequest => {
                if intent.command.is_empty()
                    || intent
                        .command
                        .iter()
                        .any(|part| part.as_bytes().contains(&0))
                {
                    return Err(EgressError::MissingCommand);
                }
            }
            EgressKind::ExternalCopy | EgressKind::HttpUpload | EgressKind::Webhook => {
                if intent.target.as_deref().is_none_or(str::is_empty) {
                    return Err(EgressError::MissingTarget);
                }
            }
        }
        let intent_id = intent.id.clone();
        self.pending.insert(intent_id.clone(), intent);
        self.pending
            .get(&intent_id)
            .ok_or(EgressError::UnknownIntent(intent_id))
    }

    pub fn decide(
        &mut self,
        intent_id: &str,
        decision: HumanEgressDecision,
    ) -> Result<Option<EgressPermit>, EgressError> {
        let intent = self
            .pending
            .remove(intent_id)
            .ok_or_else(|| EgressError::UnknownIntent(intent_id.to_string()))?;
        Ok(match decision {
            HumanEgressDecision::AllowOnce => Some(EgressPermit { intent }),
            HumanEgressDecision::Deny => None,
        })
    }

    pub fn cancel(&mut self, intent_id: &str) -> Result<EgressIntent, EgressError> {
        self.pending
            .remove(intent_id)
            .ok_or_else(|| EgressError::UnknownIntent(intent_id.to_string()))
    }

    #[must_use]
    pub fn pending(&self, intent_id: &str) -> Option<&EgressIntent> {
        self.pending.get(intent_id)
    }
}

fn checked_text(value: String, error: EgressError) -> Result<String, EgressError> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        Err(error)
    } else if trimmed.len() == value.len() {
        Ok(value)
    } else {
        Ok(trimmed.to_string())
    }
}
