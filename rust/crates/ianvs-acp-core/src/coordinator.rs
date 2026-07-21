use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};
use serde_json::Value;
use thiserror::Error;

use crate::{BudgetPolicy, PlanVersion, StepDefinition, StepKind, StepRun, StepRunStatus};

pub const MAX_CAPABILITY_PROFILES: usize = 256;
pub const MAX_LEDGER_ENTRIES: usize = 100_000;
pub const MAX_PROGRESS_METADATA_BYTES: usize = 64 * 1024;

#[derive(Debug, Error, Clone, PartialEq, Eq)]
pub enum CoordinatorError {
    #[error("coordinator field {0} must be canonical bounded text")]
    InvalidText(&'static str),
    #[error("semantic capability profile is invalid")]
    InvalidCapabilityProfile,
    #[error("duplicate semantic capability profile: {0}")]
    DuplicateCapabilityProfile(String),
    #[error("Agent Step references missing capability profile: {0}")]
    MissingCapabilityProfile(String),
    #[error("plan proposal does not target the active Plan version")]
    StalePlanProposal,
    #[error("plan proposal exceeds maxReplans")]
    ReplanBudgetExhausted,
    #[error("plan proposal was not found")]
    ProposalNotFound,
    #[error("plan proposal is no longer pending")]
    ProposalSettled,
    #[error("replanning cannot delete or rewrite a started Step")]
    StartedStepMutation,
    #[error("Task or Progress Ledger reached its bounded retention limit")]
    LedgerLimit,
    #[error("usage would exceed a hard Workflow budget")]
    UsageBudgetExceeded,
    #[error(transparent)]
    WorkflowIr(#[from] crate::WorkflowIrError),
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SemanticCapabilityProfile {
    pub profile_id: String,
    pub summary: String,
    pub capabilities: BTreeSet<String>,
    pub max_parallelism: u32,
}

impl SemanticCapabilityProfile {
    pub fn validate(&self) -> Result<(), CoordinatorError> {
        validate_text(&self.profile_id, "profileId", 4096)?;
        validate_text(&self.summary, "summary", 16 * 1024)?;
        if self.capabilities.is_empty()
            || self.capabilities.len() > 256
            || self.max_parallelism == 0
            || self
                .capabilities
                .iter()
                .any(|capability| validate_text(capability, "capability", 4096).is_err())
        {
            return Err(CoordinatorError::InvalidCapabilityProfile);
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CapabilityRequirement {
    #[serde(default)]
    pub all_of: BTreeSet<String>,
    #[serde(default)]
    pub any_of: BTreeSet<String>,
    #[serde(default)]
    pub none_of: BTreeSet<String>,
}

impl CapabilityRequirement {
    #[must_use]
    pub fn matches(&self, profile: &SemanticCapabilityProfile) -> bool {
        self.all_of.is_subset(&profile.capabilities)
            && (self.any_of.is_empty() || !self.any_of.is_disjoint(&profile.capabilities))
            && self.none_of.is_disjoint(&profile.capabilities)
    }
}

#[derive(Debug, Clone, Default)]
pub struct CapabilityRegistry {
    profiles: BTreeMap<String, SemanticCapabilityProfile>,
}

impl CapabilityRegistry {
    pub fn from_profiles(profiles: &[SemanticCapabilityProfile]) -> Result<Self, CoordinatorError> {
        if profiles.len() > MAX_CAPABILITY_PROFILES {
            return Err(CoordinatorError::InvalidCapabilityProfile);
        }
        let mut registry = Self::default();
        for profile in profiles {
            profile.validate()?;
            if registry
                .profiles
                .insert(profile.profile_id.clone(), profile.clone())
                .is_some()
            {
                return Err(CoordinatorError::DuplicateCapabilityProfile(
                    profile.profile_id.clone(),
                ));
            }
        }
        Ok(registry)
    }

    #[must_use]
    pub fn profile(&self, profile_id: &str) -> Option<&SemanticCapabilityProfile> {
        self.profiles.get(profile_id)
    }

    #[must_use]
    pub fn matching_profiles(
        &self,
        requirement: &CapabilityRequirement,
    ) -> Vec<&SemanticCapabilityProfile> {
        self.profiles
            .values()
            .filter(|profile| requirement.matches(profile))
            .collect()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskLedgerStatus {
    Planned,
    Ready,
    Assigned,
    Running,
    Waiting,
    Succeeded,
    Failed,
    Cancelled,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TaskLedgerEntry {
    pub entry_id: String,
    pub plan_version: u32,
    pub step_id: String,
    pub capability_profile: Option<String>,
    pub status: TaskLedgerStatus,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProgressLedgerKind {
    PlanProposed,
    PlanActivated,
    StepReady,
    StepStarted,
    StepCompleted,
    StepFailed,
    BudgetUpdated,
    HumanReview,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ProgressLedgerEntry {
    pub sequence: u64,
    pub plan_version: u32,
    pub step_id: Option<String>,
    pub kind: ProgressLedgerKind,
    pub message: String,
    #[serde(default)]
    pub metadata: BTreeMap<String, Value>,
    pub created_at: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PlanProposalStatus {
    Proposed,
    Activated,
    Rejected,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PlanProposal {
    pub proposal_id: String,
    pub base_plan_version: u32,
    pub proposed_plan_version: u32,
    pub reason: String,
    pub provenance: String,
    pub created_at: String,
    pub steps: Vec<StepDefinition>,
    pub status: PlanProposalStatus,
    pub rejection_reason: Option<String>,
}

impl PlanProposal {
    pub fn validate_identity(&self) -> Result<(), CoordinatorError> {
        validate_text(&self.proposal_id, "proposalId", 4096)?;
        validate_text(&self.reason, "reason", 16 * 1024)?;
        validate_text(&self.provenance, "provenance", 16 * 1024)?;
        validate_text(&self.created_at, "createdAt", 4096)?;
        if self.status != PlanProposalStatus::Proposed || self.rejection_reason.is_some() {
            return Err(CoordinatorError::ProposalSettled);
        }
        Ok(())
    }

    #[must_use]
    pub fn as_plan(&self) -> PlanVersion {
        PlanVersion {
            version: self.proposed_plan_version,
            reason: self.reason.clone(),
            provenance: self.provenance.clone(),
            created_at: self.created_at.clone(),
            steps: self.steps.clone(),
        }
    }
}

pub fn validate_capability_profiles(
    profiles: &[SemanticCapabilityProfile],
    steps: &[StepDefinition],
) -> Result<(), CoordinatorError> {
    let registry = CapabilityRegistry::from_profiles(profiles)?;
    for step in steps {
        if let StepKind::Agent {
            capability_profile, ..
        } = &step.kind
            && registry.profile(capability_profile).is_none()
        {
            return Err(CoordinatorError::MissingCapabilityProfile(
                capability_profile.clone(),
            ));
        }
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
pub fn validate_plan_proposal(
    proposal: &PlanProposal,
    active_plan_version: u32,
    plans_len: usize,
    budget: &BudgetPolicy,
    schemas: &BTreeSet<&str>,
    profiles: &[SemanticCapabilityProfile],
    current_plan: &PlanVersion,
    step_runs: &[StepRun],
) -> Result<PlanVersion, CoordinatorError> {
    proposal.validate_identity()?;
    if proposal.base_plan_version != active_plan_version
        || proposal.proposed_plan_version != active_plan_version.saturating_add(1)
    {
        return Err(CoordinatorError::StalePlanProposal);
    }
    if plans_len.saturating_sub(1) >= usize::try_from(budget.max_replans).unwrap_or(usize::MAX) {
        return Err(CoordinatorError::ReplanBudgetExhausted);
    }
    let plan = proposal.as_plan();
    plan.validate(budget, schemas)?;
    validate_capability_profiles(profiles, &plan.steps)?;
    let proposed: BTreeMap<_, _> = plan
        .steps
        .iter()
        .map(|step| (step.step_id.as_str(), step))
        .collect();
    let current: BTreeMap<_, _> = current_plan
        .steps
        .iter()
        .map(|step| (step.step_id.as_str(), step))
        .collect();
    for run in step_runs
        .iter()
        .filter(|run| !matches!(run.status, StepRunStatus::Pending | StepRunStatus::Ready))
    {
        if proposed.get(run.step_id.as_str()) != current.get(run.step_id.as_str()) {
            return Err(CoordinatorError::StartedStepMutation);
        }
    }
    Ok(plan)
}

#[must_use]
pub fn next_step_runs_for_plan(plan: &PlanVersion, previous: &[StepRun]) -> Vec<StepRun> {
    let previous: BTreeMap<_, _> = previous
        .iter()
        .map(|run| (run.step_id.as_str(), run))
        .collect();
    let succeeded: BTreeSet<_> = previous
        .values()
        .filter(|run| run.status == StepRunStatus::Succeeded)
        .map(|run| run.step_id.as_str())
        .collect();
    plan.steps
        .iter()
        .map(|step| {
            previous.get(step.step_id.as_str()).map_or_else(
                || StepRun {
                    step_id: step.step_id.clone(),
                    plan_version: plan.version,
                    status: if step
                        .depends_on
                        .iter()
                        .all(|id| succeeded.contains(id.as_str()))
                    {
                        StepRunStatus::Ready
                    } else {
                        StepRunStatus::Pending
                    },
                    attempt: 0,
                    started_at: None,
                    ended_at: None,
                    input: None,
                    output: None,
                    structured_result: None,
                    artifacts: Vec::new(),
                    error: None,
                },
                |existing| {
                    let mut retained = (*existing).clone();
                    if matches!(
                        retained.status,
                        StepRunStatus::Pending | StepRunStatus::Ready
                    ) {
                        retained.plan_version = plan.version;
                        retained.status = if step
                            .depends_on
                            .iter()
                            .all(|id| succeeded.contains(id.as_str()))
                        {
                            StepRunStatus::Ready
                        } else {
                            StepRunStatus::Pending
                        };
                    }
                    retained
                },
            )
        })
        .collect()
}

fn validate_text(value: &str, field: &'static str, limit: usize) -> Result<(), CoordinatorError> {
    if value.is_empty()
        || value.trim() != value
        || value.len() > limit
        || value.as_bytes().contains(&0)
    {
        return Err(CoordinatorError::InvalidText(field));
    }
    Ok(())
}
