use std::collections::{BTreeMap, BTreeSet, VecDeque};

use serde::{Deserialize, Serialize};
use serde_json::Value;
use thiserror::Error;

pub const WORKFLOW_IR_SCHEMA_VERSION: u16 = 1;
pub const MAX_WORKFLOW_SCHEMA_BYTES: usize = 256 * 1024;
pub const MAX_STEP_INPUT_BYTES: usize = 1024 * 1024;
pub const MAX_STEP_OUTPUT_BYTES: usize = 1024 * 1024;
pub const MAX_STEP_ARTIFACTS: usize = 1024;

#[derive(Debug, Error, Clone, PartialEq, Eq)]
pub enum WorkflowIrError {
    #[error("{0} must be canonical non-empty text")]
    InvalidText(&'static str),
    #[error("unsupported Workflow IR schema version: {0}")]
    UnsupportedSchema(u16),
    #[error("workflow plan must contain at least one Step")]
    EmptyPlan,
    #[error("workflow plan exceeds maxPlanNodes")]
    PlanNodeLimit,
    #[error("duplicate Step id: {0}")]
    DuplicateStep(String),
    #[error("Step {step_id} depends on missing Step {dependency_id}")]
    MissingDependency {
        step_id: String,
        dependency_id: String,
    },
    #[error("Step {step_id} input references undeclared dependency Step {dependency_id}")]
    InputDependency {
        step_id: String,
        dependency_id: String,
    },
    #[error("workflow plan contains a dependency cycle")]
    DependencyCycle,
    #[error("workflow plan exceeds maxDepth")]
    DepthLimit,
    #[error("workflow plan exceeds maxFanOut")]
    FanOutLimit,
    #[error("Step {0} references a missing result schema")]
    MissingResultSchema(String),
    #[error("workflow result schema is invalid or too large")]
    InvalidResultSchema,
    #[error("workflow Step input is too large")]
    InputTooLarge,
    #[error("workflow budget field {0} must be positive")]
    InvalidBudget(&'static str),
    #[error("workflow Run does not match its Definition")]
    DefinitionMismatch,
    #[error("workflow Run contains an invalid Plan version sequence")]
    InvalidPlanSequence,
    #[error("workflow Run contains an invalid Step state")]
    InvalidStepState,
    #[error("Step {0} was not found")]
    StepNotFound(String),
    #[error("Step {0} is not ready")]
    StepNotReady(String),
    #[error("workflow invocation budget is exhausted")]
    InvocationBudgetExhausted,
    #[error("workflow concurrent Agent budget is exhausted")]
    ConcurrentAgentBudgetExhausted,
    #[error("semantic capability profile parallelism is exhausted: {0}")]
    CapabilityParallelismExhausted(String),
    #[error("Step {0} requires structured result validation")]
    StructuredResultRequired(String),
    #[error("workflow Step output is too large")]
    OutputTooLarge,
    #[error("workflow Step artifacts are invalid or exceed their bounded count")]
    InvalidArtifacts,
    #[error("workflow capability profiles are invalid")]
    InvalidCapabilityProfiles,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct BudgetPolicy {
    pub max_plan_nodes: u32,
    pub max_fan_out: u32,
    pub max_depth: u32,
    pub max_replans: u32,
    pub max_invocations: u32,
    pub max_concurrent_agents: u32,
    pub token_budget: u64,
    pub cost_budget_micros: u64,
}

impl BudgetPolicy {
    pub fn validate(&self) -> Result<(), WorkflowIrError> {
        for (name, value) in [
            ("maxPlanNodes", self.max_plan_nodes),
            ("maxFanOut", self.max_fan_out),
            ("maxDepth", self.max_depth),
            ("maxInvocations", self.max_invocations),
            ("maxConcurrentAgents", self.max_concurrent_agents),
        ] {
            if value == 0 {
                return Err(WorkflowIrError::InvalidBudget(name));
            }
        }
        if self.token_budget == 0 {
            return Err(WorkflowIrError::InvalidBudget("tokenBudget"));
        }
        if self.cost_budget_micros == 0 {
            return Err(WorkflowIrError::InvalidBudget("costBudgetMicros"));
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ResultSchema {
    pub schema_id: String,
    pub schema: Value,
}

impl ResultSchema {
    pub fn validate(&self) -> Result<(), WorkflowIrError> {
        validate_text(&self.schema_id, "schemaId")?;
        let Value::Object(root) = &self.schema else {
            return Err(WorkflowIrError::InvalidResultSchema);
        };
        if root.get("type").and_then(Value::as_str) != Some("object")
            || serde_json::to_vec(&self.schema)
                .map_or(true, |encoded| encoded.len() > MAX_WORKFLOW_SCHEMA_BYTES)
        {
            return Err(WorkflowIrError::InvalidResultSchema);
        }
        crate::validate_result_schema(self).map_err(|_| WorkflowIrError::InvalidResultSchema)?;
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(
    tag = "source",
    rename_all = "snake_case",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
pub enum InputBinding {
    Literal { value: Value },
    StepOutput { step_id: String, pointer: String },
    Artifact { artifact_id: String },
}

impl InputBinding {
    fn validate(&self) -> Result<(), WorkflowIrError> {
        match self {
            Self::Literal { value } => {
                if serde_json::to_vec(value)
                    .map_or(true, |encoded| encoded.len() > MAX_STEP_INPUT_BYTES)
                {
                    return Err(WorkflowIrError::InputTooLarge);
                }
            }
            Self::StepOutput { step_id, pointer } => {
                validate_text(step_id, "stepId")?;
                if pointer.is_empty() || !pointer.starts_with('/') || pointer.len() > 4096 {
                    return Err(WorkflowIrError::InvalidText("pointer"));
                }
            }
            Self::Artifact { artifact_id } => validate_text(artifact_id, "artifactId")?,
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(
    tag = "predicate",
    rename_all = "snake_case",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
pub enum ConditionPredicate {
    Equals { input: InputBinding, value: Value },
    Exists { input: InputBinding },
    Boolean { input: InputBinding },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(
    tag = "type",
    rename_all = "snake_case",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
pub enum StepKind {
    Agent {
        capability_profile: String,
        prompt_template: String,
    },
    Parallel {
        max_fan_out: u32,
    },
    Map {
        collection_input: InputBinding,
        max_fan_out: u32,
    },
    Reduce {
        collection_input: InputBinding,
    },
    Condition {
        predicate: ConditionPredicate,
    },
    Approval {
        approval_profile: String,
    },
    Wait {
        timeout_seconds: u64,
        signal_name: Option<String>,
    },
    Checkpoint,
}

impl StepKind {
    fn validate(&self, budget: &BudgetPolicy) -> Result<(), WorkflowIrError> {
        match self {
            Self::Agent {
                capability_profile,
                prompt_template,
            } => {
                validate_text(capability_profile, "capabilityProfile")?;
                validate_bounded_text(prompt_template, "promptTemplate", 256 * 1024)?;
            }
            Self::Parallel { max_fan_out } => {
                validate_fan_out(*max_fan_out, budget)?;
            }
            Self::Map {
                collection_input,
                max_fan_out,
            } => {
                collection_input.validate()?;
                validate_fan_out(*max_fan_out, budget)?;
            }
            Self::Reduce { collection_input } => collection_input.validate()?,
            Self::Condition { predicate } => match predicate {
                ConditionPredicate::Equals { input, value } => {
                    input.validate()?;
                    if serde_json::to_vec(value)
                        .map_or(true, |encoded| encoded.len() > MAX_STEP_INPUT_BYTES)
                    {
                        return Err(WorkflowIrError::InputTooLarge);
                    }
                }
                ConditionPredicate::Exists { input } | ConditionPredicate::Boolean { input } => {
                    input.validate()?;
                }
            },
            Self::Approval { approval_profile } => {
                validate_text(approval_profile, "approvalProfile")?;
            }
            Self::Wait {
                timeout_seconds,
                signal_name,
            } => {
                if *timeout_seconds == 0 {
                    return Err(WorkflowIrError::InvalidBudget("timeoutSeconds"));
                }
                if let Some(signal_name) = signal_name {
                    validate_text(signal_name, "signalName")?;
                }
            }
            Self::Checkpoint => {}
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct StepDefinition {
    pub step_id: String,
    pub kind: StepKind,
    #[serde(default)]
    pub depends_on: Vec<String>,
    #[serde(default)]
    pub inputs: BTreeMap<String, InputBinding>,
    pub result_schema_id: Option<String>,
    #[serde(default)]
    pub retry_limit: u32,
    pub permission_profile: Option<String>,
}

impl StepDefinition {
    fn validate(&self, budget: &BudgetPolicy) -> Result<(), WorkflowIrError> {
        validate_text(&self.step_id, "stepId")?;
        self.kind.validate(budget)?;
        if self.depends_on.len() > usize::try_from(budget.max_plan_nodes).unwrap_or(usize::MAX) {
            return Err(WorkflowIrError::PlanNodeLimit);
        }
        for dependency in &self.depends_on {
            validate_text(dependency, "dependsOn")?;
        }
        for (name, binding) in &self.inputs {
            validate_text(name, "inputName")?;
            binding.validate()?;
        }
        if let Some(schema_id) = &self.result_schema_id {
            validate_text(schema_id, "resultSchemaId")?;
        }
        if let Some(profile) = &self.permission_profile {
            validate_text(profile, "permissionProfile")?;
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PlanVersion {
    pub version: u32,
    pub reason: String,
    pub provenance: String,
    pub created_at: String,
    pub steps: Vec<StepDefinition>,
}

impl PlanVersion {
    pub fn validate(
        &self,
        budget: &BudgetPolicy,
        schemas: &BTreeSet<&str>,
    ) -> Result<(), WorkflowIrError> {
        if self.version == 0 {
            return Err(WorkflowIrError::InvalidPlanSequence);
        }
        validate_bounded_text(&self.reason, "reason", 16 * 1024)?;
        validate_bounded_text(&self.provenance, "provenance", 16 * 1024)?;
        validate_text(&self.created_at, "createdAt")?;
        validate_plan(&self.steps, budget, schemas)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WorkflowDefinition {
    pub schema_version: u16,
    pub definition_id: String,
    pub version: u32,
    pub name: String,
    pub created_at: String,
    pub provenance: String,
    pub budget_policy: BudgetPolicy,
    #[serde(default)]
    pub capability_profiles: Vec<crate::SemanticCapabilityProfile>,
    #[serde(default)]
    pub result_schemas: Vec<ResultSchema>,
    pub initial_plan: PlanVersion,
}

impl WorkflowDefinition {
    pub fn validate(&self) -> Result<(), WorkflowIrError> {
        if self.schema_version != WORKFLOW_IR_SCHEMA_VERSION {
            return Err(WorkflowIrError::UnsupportedSchema(self.schema_version));
        }
        validate_text(&self.definition_id, "definitionId")?;
        if self.version == 0 {
            return Err(WorkflowIrError::InvalidPlanSequence);
        }
        validate_bounded_text(&self.name, "name", 4096)?;
        validate_text(&self.created_at, "createdAt")?;
        validate_bounded_text(&self.provenance, "provenance", 16 * 1024)?;
        self.budget_policy.validate()?;
        let mut schemas = BTreeSet::new();
        for schema in &self.result_schemas {
            schema.validate()?;
            if !schemas.insert(schema.schema_id.as_str()) {
                return Err(WorkflowIrError::InvalidResultSchema);
            }
        }
        if self.initial_plan.version != 1 {
            return Err(WorkflowIrError::InvalidPlanSequence);
        }
        self.initial_plan.validate(&self.budget_policy, &schemas)?;
        crate::validate_capability_profiles(&self.capability_profiles, &self.initial_plan.steps)
            .map_err(|_| WorkflowIrError::InvalidCapabilityProfiles)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ArtifactReference {
    pub artifact_id: String,
    pub media_type: String,
    pub uri: String,
    pub sha256: String,
    pub byte_length: u64,
}

impl ArtifactReference {
    pub fn validate(&self) -> Result<(), WorkflowIrError> {
        validate_text(&self.artifact_id, "artifactId")?;
        validate_text(&self.media_type, "mediaType")?;
        validate_bounded_text(&self.uri, "uri", 32 * 1024)?;
        if !self.sha256.starts_with("sha256:")
            || self.sha256.len() != 71
            || !self.sha256[7..]
                .bytes()
                .all(|byte| byte.is_ascii_hexdigit())
        {
            return Err(WorkflowIrError::InvalidText("sha256"));
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WorkflowRunStatus {
    Pending,
    Running,
    Waiting,
    NeedsHumanReview,
    Succeeded,
    Failed,
    Cancelled,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum StepRunStatus {
    Pending,
    Ready,
    Running,
    Waiting,
    NeedsHumanReview,
    Succeeded,
    Failed,
    Skipped,
    Cancelled,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct StepRun {
    pub step_id: String,
    pub plan_version: u32,
    pub status: StepRunStatus,
    pub attempt: u32,
    pub started_at: Option<String>,
    pub ended_at: Option<String>,
    pub input: Option<Value>,
    pub output: Option<Value>,
    pub structured_result: Option<crate::StructuredResultRecord>,
    #[serde(default)]
    pub artifacts: Vec<ArtifactReference>,
    pub error: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WorkflowUsage {
    pub invocations: u32,
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cost_micros: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WorkflowRun {
    pub schema_version: u16,
    pub run_id: String,
    pub definition_id: String,
    pub definition_version: u32,
    pub revision: u64,
    pub status: WorkflowRunStatus,
    pub active_plan_version: u32,
    pub plans: Vec<PlanVersion>,
    pub step_runs: Vec<StepRun>,
    pub usage: WorkflowUsage,
    #[serde(default)]
    pub task_ledger: Vec<crate::TaskLedgerEntry>,
    #[serde(default)]
    pub progress_ledger: Vec<crate::ProgressLedgerEntry>,
    #[serde(default)]
    pub plan_proposals: Vec<crate::PlanProposal>,
    pub created_at: String,
    pub updated_at: String,
}

impl WorkflowRun {
    pub fn new(
        run_id: String,
        definition: &WorkflowDefinition,
        created_at: String,
    ) -> Result<Self, WorkflowIrError> {
        definition.validate()?;
        validate_text(&run_id, "runId")?;
        validate_text(&created_at, "createdAt")?;
        let step_runs = definition
            .initial_plan
            .steps
            .iter()
            .map(|step| StepRun {
                step_id: step.step_id.clone(),
                plan_version: 1,
                status: if step.depends_on.is_empty() {
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
            })
            .collect();
        let task_ledger = definition
            .initial_plan
            .steps
            .iter()
            .map(|step| crate::TaskLedgerEntry {
                entry_id: format!("plan-1-step-{}", step.step_id),
                plan_version: 1,
                step_id: step.step_id.clone(),
                capability_profile: match &step.kind {
                    StepKind::Agent {
                        capability_profile, ..
                    } => Some(capability_profile.clone()),
                    _ => None,
                },
                status: if step.depends_on.is_empty() {
                    crate::TaskLedgerStatus::Ready
                } else {
                    crate::TaskLedgerStatus::Planned
                },
                created_at: created_at.clone(),
                updated_at: created_at.clone(),
            })
            .collect();
        Ok(Self {
            schema_version: WORKFLOW_IR_SCHEMA_VERSION,
            run_id,
            definition_id: definition.definition_id.clone(),
            definition_version: definition.version,
            revision: 0,
            status: WorkflowRunStatus::Pending,
            active_plan_version: 1,
            plans: vec![definition.initial_plan.clone()],
            step_runs,
            usage: WorkflowUsage::default(),
            task_ledger,
            progress_ledger: Vec::new(),
            plan_proposals: Vec::new(),
            created_at: created_at.clone(),
            updated_at: created_at,
        })
    }

    pub fn validate(&self, definition: &WorkflowDefinition) -> Result<(), WorkflowIrError> {
        if self.schema_version != WORKFLOW_IR_SCHEMA_VERSION {
            return Err(WorkflowIrError::UnsupportedSchema(self.schema_version));
        }
        if self.definition_id != definition.definition_id
            || self.definition_version != definition.version
        {
            return Err(WorkflowIrError::DefinitionMismatch);
        }
        if self.plans.is_empty()
            || self.plans.len()
                > usize::try_from(definition.budget_policy.max_replans)
                    .unwrap_or(usize::MAX)
                    .saturating_add(1)
            || self.active_plan_version != u32::try_from(self.plans.len()).unwrap_or(u32::MAX)
        {
            return Err(WorkflowIrError::InvalidPlanSequence);
        }
        let schemas = definition
            .result_schemas
            .iter()
            .map(|schema| schema.schema_id.as_str())
            .collect();
        for (index, plan) in self.plans.iter().enumerate() {
            if plan.version != u32::try_from(index + 1).unwrap_or(u32::MAX) {
                return Err(WorkflowIrError::InvalidPlanSequence);
            }
            plan.validate(&definition.budget_policy, &schemas)?;
        }
        if self.usage.invocations > definition.budget_policy.max_invocations
            || self
                .usage
                .input_tokens
                .checked_add(self.usage.output_tokens)
                .is_none_or(|total| total > definition.budget_policy.token_budget)
            || self.usage.cost_micros > definition.budget_policy.cost_budget_micros
        {
            return Err(WorkflowIrError::InvocationBudgetExhausted);
        }
        if self.task_ledger.len() > crate::MAX_LEDGER_ENTRIES
            || self.progress_ledger.len() > crate::MAX_LEDGER_ENTRIES
            || self.plan_proposals.len()
                > usize::try_from(definition.budget_policy.max_replans).unwrap_or(usize::MAX)
        {
            return Err(WorkflowIrError::InvalidStepState);
        }
        let active = &self.plans[self.plans.len() - 1];
        let expected: BTreeSet<_> = active
            .steps
            .iter()
            .map(|step| step.step_id.as_str())
            .collect();
        let actual: BTreeSet<_> = self
            .step_runs
            .iter()
            .map(|step| step.step_id.as_str())
            .collect();
        if expected != actual || actual.len() != self.step_runs.len() {
            return Err(WorkflowIrError::InvalidStepState);
        }
        self.validate_step_runs(definition, active)?;
        self.validate_ledgers()?;
        Ok(())
    }

    fn validate_step_runs(
        &self,
        definition: &WorkflowDefinition,
        active: &PlanVersion,
    ) -> Result<(), WorkflowIrError> {
        let mut running_agents = 0_usize;
        let mut running_by_profile = BTreeMap::<&str, usize>::new();
        for run in &self.step_runs {
            if run.plan_version == 0 || run.plan_version > self.active_plan_version {
                return Err(WorkflowIrError::InvalidStepState);
            }
            let plan = &self.plans[usize::try_from(run.plan_version - 1)
                .map_err(|_| WorkflowIrError::InvalidStepState)?];
            let historical = plan
                .steps
                .iter()
                .find(|step| step.step_id == run.step_id)
                .ok_or(WorkflowIrError::InvalidStepState)?;
            let current = active
                .steps
                .iter()
                .find(|step| step.step_id == run.step_id)
                .ok_or(WorkflowIrError::InvalidStepState)?;
            if !matches!(run.status, StepRunStatus::Pending | StepRunStatus::Ready)
                && historical != current
            {
                return Err(WorkflowIrError::InvalidStepState);
            }
            if matches!(run.status, StepRunStatus::Pending | StepRunStatus::Ready)
                && run.plan_version != self.active_plan_version
            {
                return Err(WorkflowIrError::InvalidStepState);
            }
            if run.input.as_ref().is_some_and(|value| {
                serde_json::to_vec(value)
                    .map_or(true, |encoded| encoded.len() > MAX_STEP_INPUT_BYTES)
            }) || run.output.as_ref().is_some_and(|value| {
                serde_json::to_vec(value)
                    .map_or(true, |encoded| encoded.len() > MAX_STEP_OUTPUT_BYTES)
            }) || run.artifacts.len() > MAX_STEP_ARTIFACTS
            {
                return Err(WorkflowIrError::InvalidStepState);
            }
            let mut artifact_ids = BTreeSet::new();
            for artifact in &run.artifacts {
                artifact.validate()?;
                if !artifact_ids.insert(artifact.artifact_id.as_str()) {
                    return Err(WorkflowIrError::InvalidArtifacts);
                }
            }
            if let Some(result) = &run.structured_result
                && (historical.result_schema_id.as_deref() != Some(result.schema_id.as_str())
                    || result.attempts.len()
                        > usize::try_from(crate::MAX_RESULT_CORRECTION_ATTEMPTS)
                            .unwrap_or(usize::MAX)
                            .saturating_add(1)
                    || result.attempts.iter().enumerate().any(|(index, attempt)| {
                        attempt.attempt != u32::try_from(index + 1).unwrap_or(u32::MAX)
                            || attempt.issues.len() > crate::MAX_RESULT_VALIDATION_ISSUES
                            || !attempt.raw_sha256.starts_with("sha256:")
                            || attempt.raw_sha256.len() != 71
                            || !attempt.raw_sha256[7..]
                                .bytes()
                                .all(|byte| byte.is_ascii_hexdigit())
                    })
                    || (result.status == crate::StructuredResultStatus::Valid)
                        != result.value.is_some())
            {
                return Err(WorkflowIrError::InvalidStepState);
            }
            if run.status == StepRunStatus::Running
                && let StepKind::Agent {
                    capability_profile, ..
                } = &current.kind
            {
                running_agents = running_agents.saturating_add(1);
                *running_by_profile
                    .entry(capability_profile.as_str())
                    .or_default() += 1;
            }
        }
        if running_agents
            > usize::try_from(definition.budget_policy.max_concurrent_agents).unwrap_or(usize::MAX)
        {
            return Err(WorkflowIrError::ConcurrentAgentBudgetExhausted);
        }
        for (profile_id, running) in running_by_profile {
            let profile = definition
                .capability_profiles
                .iter()
                .find(|profile| profile.profile_id == profile_id)
                .ok_or(WorkflowIrError::InvalidCapabilityProfiles)?;
            if running > usize::try_from(profile.max_parallelism).unwrap_or(usize::MAX) {
                return Err(WorkflowIrError::CapabilityParallelismExhausted(
                    profile_id.to_string(),
                ));
            }
        }
        Ok(())
    }

    fn validate_ledgers(&self) -> Result<(), WorkflowIrError> {
        let mut entry_ids = BTreeSet::new();
        for entry in &self.task_ledger {
            validate_text(&entry.entry_id, "taskLedger.entryId")?;
            validate_text(&entry.step_id, "taskLedger.stepId")?;
            validate_text(&entry.created_at, "taskLedger.createdAt")?;
            validate_text(&entry.updated_at, "taskLedger.updatedAt")?;
            if !entry_ids.insert(entry.entry_id.as_str())
                || entry.plan_version == 0
                || entry.plan_version > self.active_plan_version
            {
                return Err(WorkflowIrError::InvalidStepState);
            }
            let step = self.plans[usize::try_from(entry.plan_version - 1)
                .map_err(|_| WorkflowIrError::InvalidStepState)?]
            .steps
            .iter()
            .find(|step| step.step_id == entry.step_id)
            .ok_or(WorkflowIrError::InvalidStepState)?;
            let expected_profile = match &step.kind {
                StepKind::Agent {
                    capability_profile, ..
                } => Some(capability_profile),
                _ => None,
            };
            if entry.capability_profile.as_ref() != expected_profile {
                return Err(WorkflowIrError::InvalidStepState);
            }
        }
        for run in &self.step_runs {
            let entry = self
                .task_ledger
                .iter()
                .rev()
                .find(|entry| {
                    entry.step_id == run.step_id && entry.plan_version == run.plan_version
                })
                .ok_or(WorkflowIrError::InvalidStepState)?;
            let expected = match run.status {
                StepRunStatus::Pending => crate::TaskLedgerStatus::Planned,
                StepRunStatus::Ready => crate::TaskLedgerStatus::Ready,
                StepRunStatus::Running => crate::TaskLedgerStatus::Running,
                StepRunStatus::Waiting | StepRunStatus::NeedsHumanReview => {
                    crate::TaskLedgerStatus::Waiting
                }
                StepRunStatus::Succeeded => crate::TaskLedgerStatus::Succeeded,
                StepRunStatus::Failed => crate::TaskLedgerStatus::Failed,
                StepRunStatus::Cancelled => crate::TaskLedgerStatus::Cancelled,
                StepRunStatus::Skipped => continue,
            };
            if entry.status != expected {
                return Err(WorkflowIrError::InvalidStepState);
            }
        }
        for (index, entry) in self.progress_ledger.iter().enumerate() {
            if entry.sequence != u64::try_from(index + 1).unwrap_or(u64::MAX)
                || entry.plan_version == 0
                || entry.plan_version > self.active_plan_version
                || entry.message.is_empty()
                || entry.message.len() > 64 * 1024
                || serde_json::to_vec(&entry.metadata).map_or(true, |encoded| {
                    encoded.len() > crate::MAX_PROGRESS_METADATA_BYTES
                })
            {
                return Err(WorkflowIrError::InvalidStepState);
            }
            if let Some(step_id) = &entry.step_id {
                validate_text(step_id, "progressLedger.stepId")?;
                if !self
                    .plans
                    .iter()
                    .any(|plan| plan.steps.iter().any(|step| step.step_id == *step_id))
                {
                    return Err(WorkflowIrError::InvalidStepState);
                }
            }
        }
        Ok(())
    }

    pub fn start_step(
        &mut self,
        step_id: &str,
        input: Value,
        now: &str,
        definition: &WorkflowDefinition,
    ) -> Result<(), WorkflowIrError> {
        let budget = &definition.budget_policy;
        self.ensure_progress_capacity()
            .map_err(|_| WorkflowIrError::InvalidStepState)?;
        if self.usage.invocations >= budget.max_invocations {
            return Err(WorkflowIrError::InvocationBudgetExhausted);
        }
        let active_plan = self
            .plans
            .last()
            .ok_or(WorkflowIrError::InvalidPlanSequence)?;
        let definition_step = active_plan
            .steps
            .iter()
            .find(|step| step.step_id == step_id)
            .ok_or_else(|| WorkflowIrError::StepNotFound(step_id.to_string()))?;
        if let StepKind::Agent {
            capability_profile, ..
        } = &definition_step.kind
        {
            let running_agent_profiles = self
                .step_runs
                .iter()
                .filter(|run| run.status == StepRunStatus::Running)
                .filter_map(|run| {
                    active_plan
                        .steps
                        .iter()
                        .find(|step| step.step_id == run.step_id)
                })
                .filter_map(|step| match &step.kind {
                    StepKind::Agent {
                        capability_profile, ..
                    } => Some(capability_profile.as_str()),
                    _ => None,
                })
                .collect::<Vec<_>>();
            if running_agent_profiles.len()
                >= usize::try_from(budget.max_concurrent_agents).unwrap_or(usize::MAX)
            {
                return Err(WorkflowIrError::ConcurrentAgentBudgetExhausted);
            }
            let profile = definition
                .capability_profiles
                .iter()
                .find(|profile| profile.profile_id == *capability_profile)
                .ok_or(WorkflowIrError::InvalidCapabilityProfiles)?;
            if running_agent_profiles
                .iter()
                .filter(|running| **running == capability_profile)
                .count()
                >= usize::try_from(profile.max_parallelism).unwrap_or(usize::MAX)
            {
                return Err(WorkflowIrError::CapabilityParallelismExhausted(
                    capability_profile.clone(),
                ));
            }
        }
        let step = self.step_mut(step_id)?;
        if step.status != StepRunStatus::Ready {
            return Err(WorkflowIrError::StepNotReady(step_id.to_string()));
        }
        if serde_json::to_vec(&input).map_or(true, |encoded| encoded.len() > MAX_STEP_INPUT_BYTES) {
            return Err(WorkflowIrError::InputTooLarge);
        }
        step.status = StepRunStatus::Running;
        step.attempt = step.attempt.saturating_add(1);
        step.started_at = Some(now.to_string());
        step.ended_at = None;
        step.input = Some(input);
        step.output = None;
        step.artifacts.clear();
        step.error = None;
        step.structured_result = None;
        if let Some(entry) = self.task_ledger.iter_mut().rev().find(|entry| {
            entry.step_id == step_id && entry.plan_version == self.active_plan_version
        }) {
            entry.status = crate::TaskLedgerStatus::Running;
            entry.updated_at = now.to_string();
        }
        self.usage.invocations = self.usage.invocations.saturating_add(1);
        self.status = WorkflowRunStatus::Running;
        self.updated_at = now.to_string();
        self.append_progress(
            crate::ProgressLedgerKind::StepStarted,
            Some(step_id.to_string()),
            "Step execution started.",
            BTreeMap::new(),
            now,
        )
        .map_err(|_| WorkflowIrError::InvalidStepState)?;
        Ok(())
    }

    pub fn complete_step(
        &mut self,
        definition: &WorkflowDefinition,
        step_id: &str,
        output: Value,
        artifacts: Vec<ArtifactReference>,
        now: &str,
    ) -> Result<(), WorkflowIrError> {
        if self.definition_id != definition.definition_id
            || self.definition_version != definition.version
        {
            return Err(WorkflowIrError::DefinitionMismatch);
        }
        let definition_step = self
            .plans
            .last()
            .ok_or(WorkflowIrError::InvalidPlanSequence)?
            .steps
            .iter()
            .find(|step| step.step_id == step_id)
            .ok_or_else(|| WorkflowIrError::StepNotFound(step_id.to_string()))?;
        if definition_step.result_schema_id.is_some() {
            return Err(WorkflowIrError::StructuredResultRequired(
                step_id.to_string(),
            ));
        }
        self.complete_validated_step(step_id, output, artifacts, now)
    }

    pub fn wait_step(
        &mut self,
        step_id: &str,
        needs_human_review: bool,
        now: &str,
    ) -> Result<(), WorkflowIrError> {
        self.ensure_progress_capacity()
            .map_err(|_| WorkflowIrError::InvalidStepState)?;
        let step = self.step_mut(step_id)?;
        if step.status != StepRunStatus::Running {
            return Err(WorkflowIrError::StepNotReady(step_id.to_string()));
        }
        step.status = if needs_human_review {
            StepRunStatus::NeedsHumanReview
        } else {
            StepRunStatus::Waiting
        };
        let step_plan_version = step.plan_version;
        if let Some(entry) = self
            .task_ledger
            .iter_mut()
            .rev()
            .find(|entry| entry.step_id == step_id && entry.plan_version == step_plan_version)
        {
            entry.status = crate::TaskLedgerStatus::Waiting;
            entry.updated_at = now.to_string();
        }
        self.status = self.derived_status();
        self.updated_at = now.to_string();
        self.append_progress(
            if needs_human_review {
                crate::ProgressLedgerKind::HumanReview
            } else {
                crate::ProgressLedgerKind::StepWaiting
            },
            Some(step_id.to_string()),
            if needs_human_review {
                "Step is waiting for human approval."
            } else {
                "Step is waiting for a durable signal or deadline."
            },
            BTreeMap::new(),
            now,
        )
        .map_err(|_| WorkflowIrError::InvalidStepState)
    }

    pub fn resume_step(&mut self, step_id: &str, now: &str) -> Result<(), WorkflowIrError> {
        let step = self.step_mut(step_id)?;
        if !matches!(
            step.status,
            StepRunStatus::Waiting | StepRunStatus::NeedsHumanReview
        ) {
            return Err(WorkflowIrError::StepNotReady(step_id.to_string()));
        }
        step.status = StepRunStatus::Running;
        let step_plan_version = step.plan_version;
        if let Some(entry) = self
            .task_ledger
            .iter_mut()
            .rev()
            .find(|entry| entry.step_id == step_id && entry.plan_version == step_plan_version)
        {
            entry.status = crate::TaskLedgerStatus::Running;
            entry.updated_at = now.to_string();
        }
        self.status = WorkflowRunStatus::Running;
        self.updated_at = now.to_string();
        Ok(())
    }

    pub fn resolve_approval_step(
        &mut self,
        definition: &WorkflowDefinition,
        step_id: &str,
        approved: bool,
        now: &str,
    ) -> Result<(), WorkflowIrError> {
        let kind = self
            .plans
            .last()
            .ok_or(WorkflowIrError::InvalidPlanSequence)?
            .steps
            .iter()
            .find(|step| step.step_id == step_id)
            .ok_or_else(|| WorkflowIrError::StepNotFound(step_id.to_string()))?
            .kind
            .clone();
        if !matches!(kind, StepKind::Approval { .. }) {
            return Err(WorkflowIrError::InvalidStepState);
        }
        if approved {
            self.resume_step(step_id, now)?;
            self.complete_step(
                definition,
                step_id,
                serde_json::json!({"approved": true}),
                Vec::new(),
                now,
            )
        } else {
            self.fail_step(
                definition,
                step_id,
                "Workflow approval was denied.",
                false,
                now,
            )?;
            Ok(())
        }
    }

    pub fn fail_step(
        &mut self,
        definition: &WorkflowDefinition,
        step_id: &str,
        error: &str,
        retryable: bool,
        now: &str,
    ) -> Result<bool, WorkflowIrError> {
        if error.is_empty() || error.trim() != error {
            return Err(WorkflowIrError::InvalidText("stepError"));
        }
        self.ensure_progress_capacity()
            .map_err(|_| WorkflowIrError::InvalidStepState)?;
        let retry_limit = self
            .plans
            .last()
            .ok_or(WorkflowIrError::InvalidPlanSequence)?
            .steps
            .iter()
            .find(|step| step.step_id == step_id)
            .ok_or_else(|| WorkflowIrError::StepNotFound(step_id.to_string()))?
            .retry_limit;
        let step = self.step_mut(step_id)?;
        if !matches!(
            step.status,
            StepRunStatus::Running | StepRunStatus::Waiting | StepRunStatus::NeedsHumanReview
        ) {
            return Err(WorkflowIrError::StepNotReady(step_id.to_string()));
        }
        let will_retry = retryable && step.attempt <= retry_limit;
        step.status = if will_retry {
            StepRunStatus::Ready
        } else {
            StepRunStatus::Failed
        };
        step.error = Some(error.to_string());
        step.ended_at = Some(now.to_string());
        let step_plan_version = step.plan_version;
        if let Some(entry) = self
            .task_ledger
            .iter_mut()
            .rev()
            .find(|entry| entry.step_id == step_id && entry.plan_version == step_plan_version)
        {
            entry.status = if will_retry {
                crate::TaskLedgerStatus::Ready
            } else {
                crate::TaskLedgerStatus::Failed
            };
            entry.updated_at = now.to_string();
        }
        self.status = self.derived_status();
        self.updated_at = now.to_string();
        self.append_progress(
            crate::ProgressLedgerKind::StepFailed,
            Some(step_id.to_string()),
            if will_retry {
                "Step failed and was admitted for retry."
            } else {
                "Step failed without an available retry."
            },
            BTreeMap::from([
                ("error".to_string(), Value::String(error.to_string())),
                ("retrying".to_string(), Value::Bool(will_retry)),
            ]),
            now,
        )
        .map_err(|_| WorkflowIrError::InvalidStepState)?;
        self.validate(definition)?;
        Ok(will_retry)
    }

    fn complete_validated_step(
        &mut self,
        step_id: &str,
        output: Value,
        artifacts: Vec<ArtifactReference>,
        now: &str,
    ) -> Result<(), WorkflowIrError> {
        self.ensure_progress_capacity()
            .map_err(|_| WorkflowIrError::InvalidStepState)?;
        if serde_json::to_vec(&output).map_or(true, |encoded| encoded.len() > MAX_STEP_OUTPUT_BYTES)
            || artifacts.len() > MAX_STEP_ARTIFACTS
        {
            return Err(if artifacts.len() > MAX_STEP_ARTIFACTS {
                WorkflowIrError::InvalidArtifacts
            } else {
                WorkflowIrError::OutputTooLarge
            });
        }
        let mut artifact_ids = BTreeSet::new();
        for artifact in &artifacts {
            artifact.validate()?;
            if !artifact_ids.insert(artifact.artifact_id.as_str()) {
                return Err(WorkflowIrError::InvalidArtifacts);
            }
        }
        let step = self.step_mut(step_id)?;
        if step.status != StepRunStatus::Running {
            return Err(WorkflowIrError::StepNotReady(step_id.to_string()));
        }
        step.status = StepRunStatus::Succeeded;
        step.output = Some(output);
        step.artifacts = artifacts;
        step.ended_at = Some(now.to_string());
        let step_plan_version = step.plan_version;
        if let Some(entry) = self
            .task_ledger
            .iter_mut()
            .rev()
            .find(|entry| entry.step_id == step_id && entry.plan_version == step_plan_version)
        {
            entry.status = crate::TaskLedgerStatus::Succeeded;
            entry.updated_at = now.to_string();
        }
        self.refresh_ready_steps(now);
        self.status = self.derived_status();
        self.updated_at = now.to_string();
        self.append_progress(
            crate::ProgressLedgerKind::StepCompleted,
            Some(step_id.to_string()),
            "Step completed with a validated result.",
            BTreeMap::new(),
            now,
        )
        .map_err(|_| WorkflowIrError::InvalidStepState)?;
        Ok(())
    }

    pub fn submit_structured_result(
        &mut self,
        step_id: &str,
        schema: &ResultSchema,
        raw: &str,
        artifacts: Vec<ArtifactReference>,
        now: &str,
    ) -> Result<crate::StructuredResultRecord, WorkflowIrError> {
        let previous_attempts = {
            let step = self
                .step_runs
                .iter()
                .find(|step| step.step_id == step_id)
                .ok_or_else(|| WorkflowIrError::StepNotFound(step_id.to_string()))?;
            if step.status != StepRunStatus::Running {
                return Err(WorkflowIrError::StepNotReady(step_id.to_string()));
            }
            step.structured_result
                .as_ref()
                .map(|result| result.attempts.clone())
                .unwrap_or_default()
        };
        let result = crate::evaluate_agent_result(schema, raw, previous_attempts, now)
            .map_err(|_| WorkflowIrError::InvalidResultSchema)?;
        if result.status == crate::StructuredResultStatus::Exhausted {
            self.ensure_progress_capacity()
                .map_err(|_| WorkflowIrError::InvalidStepState)?;
        }
        if result.status == crate::StructuredResultStatus::Valid {
            self.complete_validated_step(
                step_id,
                result.value.clone().expect("valid result has a value"),
                artifacts,
                now,
            )?;
        }
        let step = self.step_mut(step_id)?;
        step.structured_result = Some(result.clone());
        if result.status == crate::StructuredResultStatus::Exhausted {
            step.status = StepRunStatus::NeedsHumanReview;
            step.ended_at = Some(now.to_string());
            let step_plan_version = step.plan_version;
            self.status = WorkflowRunStatus::NeedsHumanReview;
            if let Some(entry) =
                self.task_ledger.iter_mut().rev().find(|entry| {
                    entry.step_id == step_id && entry.plan_version == step_plan_version
                })
            {
                entry.status = crate::TaskLedgerStatus::Waiting;
                entry.updated_at = now.to_string();
            }
            self.append_progress(
                crate::ProgressLedgerKind::HumanReview,
                Some(step_id.to_string()),
                "Structured result correction budget was exhausted.",
                BTreeMap::new(),
                now,
            )
            .map_err(|_| WorkflowIrError::InvalidStepState)?;
        }
        self.updated_at = now.to_string();
        Ok(result)
    }

    pub fn start_structured_correction(
        &mut self,
        definition: &WorkflowDefinition,
        step_id: &str,
        now: &str,
    ) -> Result<(), WorkflowIrError> {
        if self.definition_id != definition.definition_id
            || self.definition_version != definition.version
        {
            return Err(WorkflowIrError::DefinitionMismatch);
        }
        self.ensure_progress_capacity()
            .map_err(|_| WorkflowIrError::InvalidStepState)?;
        if self.usage.invocations >= definition.budget_policy.max_invocations {
            return Err(WorkflowIrError::InvocationBudgetExhausted);
        }
        let correction_attempt = {
            let step = self
                .step_runs
                .iter()
                .find(|step| step.step_id == step_id)
                .ok_or_else(|| WorkflowIrError::StepNotFound(step_id.to_string()))?;
            let result = step
                .structured_result
                .as_ref()
                .ok_or(WorkflowIrError::InvalidStepState)?;
            if step.status != StepRunStatus::Running
                || result.status != crate::StructuredResultStatus::CorrectionRequired
            {
                return Err(WorkflowIrError::InvalidStepState);
            }
            u64::try_from(result.attempts.len()).unwrap_or(u64::MAX)
        };
        self.usage.invocations = self.usage.invocations.saturating_add(1);
        self.status = WorkflowRunStatus::Running;
        self.updated_at = now.to_string();
        self.append_progress(
            crate::ProgressLedgerKind::StepStarted,
            Some(step_id.to_string()),
            "Structured result correction was requested.",
            BTreeMap::from([(
                "correctionAttempt".to_string(),
                Value::from(correction_attempt),
            )]),
            now,
        )
        .map_err(|_| WorkflowIrError::InvalidStepState)?;
        self.validate(definition)
    }

    pub fn propose_plan(
        &mut self,
        definition: &WorkflowDefinition,
        proposal: crate::PlanProposal,
    ) -> Result<(), crate::CoordinatorError> {
        if self
            .plan_proposals
            .iter()
            .any(|existing| existing.proposal_id == proposal.proposal_id)
        {
            return Err(crate::CoordinatorError::ProposalSettled);
        }
        let schemas = definition
            .result_schemas
            .iter()
            .map(|schema| schema.schema_id.as_str())
            .collect();
        crate::validate_plan_proposal(
            &proposal,
            self.active_plan_version,
            self.plans.len(),
            &definition.budget_policy,
            &schemas,
            &definition.capability_profiles,
            self.plans
                .last()
                .ok_or(WorkflowIrError::InvalidPlanSequence)?,
            &self.step_runs,
        )?;
        self.ensure_progress_capacity()?;
        let proposal_id = proposal.proposal_id.clone();
        let created_at = proposal.created_at.clone();
        self.plan_proposals.push(proposal);
        self.append_progress(
            crate::ProgressLedgerKind::PlanProposed,
            None,
            &format!("Plan proposal {proposal_id} passed policy validation."),
            BTreeMap::new(),
            &created_at,
        )?;
        self.updated_at = created_at;
        Ok(())
    }

    pub fn activate_plan(
        &mut self,
        definition: &WorkflowDefinition,
        proposal_id: &str,
        now: &str,
    ) -> Result<(), crate::CoordinatorError> {
        let proposal_index = self
            .plan_proposals
            .iter()
            .position(|proposal| proposal.proposal_id == proposal_id)
            .ok_or(crate::CoordinatorError::ProposalNotFound)?;
        let proposal = self.plan_proposals[proposal_index].clone();
        let schemas = definition
            .result_schemas
            .iter()
            .map(|schema| schema.schema_id.as_str())
            .collect();
        let plan = crate::validate_plan_proposal(
            &proposal,
            self.active_plan_version,
            self.plans.len(),
            &definition.budget_policy,
            &schemas,
            &definition.capability_profiles,
            self.plans
                .last()
                .ok_or(WorkflowIrError::InvalidPlanSequence)?,
            &self.step_runs,
        )?;
        let next_runs = crate::next_step_runs_for_plan(&plan, &self.step_runs);
        let new_ledger_entries = next_runs
            .iter()
            .filter(|run| run.plan_version == plan.version)
            .count();
        if self
            .task_ledger
            .len()
            .checked_add(new_ledger_entries)
            .is_none_or(|count| count > crate::MAX_LEDGER_ENTRIES)
        {
            return Err(crate::CoordinatorError::LedgerLimit);
        }
        self.ensure_progress_capacity()?;
        for step in &plan.steps {
            let next_run = next_runs
                .iter()
                .find(|run| run.step_id == step.step_id)
                .expect("validated plan Step has a run");
            if next_run.plan_version != plan.version {
                continue;
            }
            self.task_ledger.push(crate::TaskLedgerEntry {
                entry_id: format!("plan-{}-step-{}", plan.version, step.step_id),
                plan_version: plan.version,
                step_id: step.step_id.clone(),
                capability_profile: match &step.kind {
                    StepKind::Agent {
                        capability_profile, ..
                    } => Some(capability_profile.clone()),
                    _ => None,
                },
                status: if next_run.status == StepRunStatus::Ready {
                    crate::TaskLedgerStatus::Ready
                } else {
                    crate::TaskLedgerStatus::Planned
                },
                created_at: now.to_string(),
                updated_at: now.to_string(),
            });
        }
        self.step_runs = next_runs;
        self.active_plan_version = plan.version;
        self.plans.push(plan);
        self.status = self.derived_status();
        self.plan_proposals[proposal_index].status = crate::PlanProposalStatus::Activated;
        self.updated_at = now.to_string();
        self.append_progress(
            crate::ProgressLedgerKind::PlanActivated,
            None,
            &format!("Plan proposal {proposal_id} activated."),
            BTreeMap::new(),
            now,
        )?;
        Ok(())
    }

    pub fn record_usage(
        &mut self,
        input_tokens: u64,
        output_tokens: u64,
        cost_micros: u64,
        budget: &BudgetPolicy,
        now: &str,
    ) -> Result<(), crate::CoordinatorError> {
        self.ensure_progress_capacity()?;
        let next_input = self
            .usage
            .input_tokens
            .checked_add(input_tokens)
            .ok_or(crate::CoordinatorError::UsageBudgetExceeded)?;
        let next_output = self
            .usage
            .output_tokens
            .checked_add(output_tokens)
            .ok_or(crate::CoordinatorError::UsageBudgetExceeded)?;
        let next_cost = self
            .usage
            .cost_micros
            .checked_add(cost_micros)
            .ok_or(crate::CoordinatorError::UsageBudgetExceeded)?;
        if next_input
            .checked_add(next_output)
            .is_none_or(|total| total > budget.token_budget)
            || next_cost > budget.cost_budget_micros
        {
            return Err(crate::CoordinatorError::UsageBudgetExceeded);
        }
        self.usage.input_tokens = next_input;
        self.usage.output_tokens = next_output;
        self.usage.cost_micros = next_cost;
        self.updated_at = now.to_string();
        self.append_progress(
            crate::ProgressLedgerKind::BudgetUpdated,
            None,
            "Workflow usage ledger updated.",
            BTreeMap::from([
                ("inputTokens".to_string(), Value::from(input_tokens)),
                ("outputTokens".to_string(), Value::from(output_tokens)),
                ("costMicros".to_string(), Value::from(cost_micros)),
            ]),
            now,
        )
    }

    fn append_progress(
        &mut self,
        kind: crate::ProgressLedgerKind,
        step_id: Option<String>,
        message: &str,
        metadata: BTreeMap<String, Value>,
        now: &str,
    ) -> Result<(), crate::CoordinatorError> {
        if self.progress_ledger.len() >= crate::MAX_LEDGER_ENTRIES
            || message.is_empty()
            || message.len() > 64 * 1024
            || serde_json::to_vec(&metadata).map_or(true, |encoded| {
                encoded.len() > crate::MAX_PROGRESS_METADATA_BYTES
            })
        {
            return Err(crate::CoordinatorError::LedgerLimit);
        }
        let sequence = self
            .progress_ledger
            .last()
            .map_or(1, |entry| entry.sequence.saturating_add(1));
        self.progress_ledger.push(crate::ProgressLedgerEntry {
            sequence,
            plan_version: self.active_plan_version,
            step_id,
            kind,
            message: message.to_string(),
            metadata,
            created_at: now.to_string(),
        });
        Ok(())
    }

    fn ensure_progress_capacity(&self) -> Result<(), crate::CoordinatorError> {
        if self.progress_ledger.len() >= crate::MAX_LEDGER_ENTRIES {
            Err(crate::CoordinatorError::LedgerLimit)
        } else {
            Ok(())
        }
    }

    fn derived_status(&self) -> WorkflowRunStatus {
        if self
            .step_runs
            .iter()
            .any(|run| run.status == StepRunStatus::Failed)
        {
            WorkflowRunStatus::Failed
        } else if self
            .step_runs
            .iter()
            .any(|run| run.status == StepRunStatus::NeedsHumanReview)
        {
            WorkflowRunStatus::NeedsHumanReview
        } else if self.step_runs.iter().all(|run| {
            matches!(
                run.status,
                StepRunStatus::Succeeded | StepRunStatus::Skipped
            )
        }) {
            WorkflowRunStatus::Succeeded
        } else if self
            .step_runs
            .iter()
            .any(|run| run.status == StepRunStatus::Waiting)
        {
            WorkflowRunStatus::Waiting
        } else {
            WorkflowRunStatus::Running
        }
    }

    fn step_mut(&mut self, step_id: &str) -> Result<&mut StepRun, WorkflowIrError> {
        self.step_runs
            .iter_mut()
            .find(|step| step.step_id == step_id)
            .ok_or_else(|| WorkflowIrError::StepNotFound(step_id.to_string()))
    }

    fn refresh_ready_steps(&mut self, now: &str) {
        let succeeded: BTreeSet<_> = self
            .step_runs
            .iter()
            .filter(|run| run.status == StepRunStatus::Succeeded)
            .map(|run| run.step_id.clone())
            .collect();
        let dependencies: BTreeMap<_, _> = self.plans[self.plans.len() - 1]
            .steps
            .iter()
            .map(|step| (step.step_id.clone(), step.depends_on.clone()))
            .collect();
        let mut became_ready = Vec::new();
        for run in &mut self.step_runs {
            if run.status == StepRunStatus::Pending
                && dependencies[&run.step_id]
                    .iter()
                    .all(|dependency| succeeded.contains(dependency))
            {
                run.status = StepRunStatus::Ready;
                became_ready.push((run.step_id.clone(), run.plan_version));
            }
        }
        for (step_id, plan_version) in became_ready {
            if let Some(entry) = self
                .task_ledger
                .iter_mut()
                .rev()
                .find(|entry| entry.step_id == step_id && entry.plan_version == plan_version)
            {
                entry.status = crate::TaskLedgerStatus::Ready;
                entry.updated_at = now.to_string();
            }
        }
    }
}

fn validate_plan(
    steps: &[StepDefinition],
    budget: &BudgetPolicy,
    schemas: &BTreeSet<&str>,
) -> Result<(), WorkflowIrError> {
    if steps.is_empty() {
        return Err(WorkflowIrError::EmptyPlan);
    }
    if steps.len() > usize::try_from(budget.max_plan_nodes).unwrap_or(usize::MAX) {
        return Err(WorkflowIrError::PlanNodeLimit);
    }
    let mut by_id = BTreeMap::new();
    for step in steps {
        step.validate(budget)?;
        if by_id.insert(step.step_id.as_str(), step).is_some() {
            return Err(WorkflowIrError::DuplicateStep(step.step_id.clone()));
        }
        if let Some(schema_id) = step.result_schema_id.as_deref()
            && !schemas.contains(schema_id)
        {
            return Err(WorkflowIrError::MissingResultSchema(schema_id.to_string()));
        }
    }
    let mut outgoing: BTreeMap<&str, Vec<&str>> = by_id
        .keys()
        .copied()
        .map(|step_id| (step_id, Vec::new()))
        .collect();
    let mut indegree: BTreeMap<&str, usize> =
        by_id.keys().copied().map(|step_id| (step_id, 0)).collect();
    for step in steps {
        let mut unique = BTreeSet::new();
        for dependency in &step.depends_on {
            if !unique.insert(dependency.as_str()) {
                return Err(WorkflowIrError::DuplicateStep(dependency.clone()));
            }
            if !by_id.contains_key(dependency.as_str()) {
                return Err(WorkflowIrError::MissingDependency {
                    step_id: step.step_id.clone(),
                    dependency_id: dependency.clone(),
                });
            }
            outgoing
                .get_mut(dependency.as_str())
                .expect("known Step")
                .push(&step.step_id);
            *indegree.get_mut(step.step_id.as_str()).expect("known Step") += 1;
        }
        for dependency in input_step_references(step) {
            if !by_id.contains_key(dependency)
                || !step
                    .depends_on
                    .iter()
                    .any(|declared| declared == dependency)
            {
                return Err(WorkflowIrError::InputDependency {
                    step_id: step.step_id.clone(),
                    dependency_id: dependency.to_string(),
                });
            }
        }
    }
    if outgoing
        .values()
        .any(|edges| edges.len() > usize::try_from(budget.max_fan_out).unwrap_or(usize::MAX))
    {
        return Err(WorkflowIrError::FanOutLimit);
    }
    for step in steps {
        if let StepKind::Parallel { max_fan_out } = step.kind
            && outgoing[step.step_id.as_str()].len()
                > usize::try_from(max_fan_out).unwrap_or(usize::MAX)
        {
            return Err(WorkflowIrError::FanOutLimit);
        }
    }
    let mut depth: BTreeMap<&str, u32> = by_id.keys().copied().map(|id| (id, 1)).collect();
    let mut queue: VecDeque<_> = indegree
        .iter()
        .filter_map(|(id, degree)| (*degree == 0).then_some(*id))
        .collect();
    let mut visited = 0_usize;
    while let Some(step_id) = queue.pop_front() {
        visited += 1;
        let parent_depth = depth[step_id];
        if parent_depth > budget.max_depth {
            return Err(WorkflowIrError::DepthLimit);
        }
        for child in &outgoing[step_id] {
            depth.insert(child, depth[*child].max(parent_depth.saturating_add(1)));
            let degree = indegree.get_mut(child).expect("known Step");
            *degree -= 1;
            if *degree == 0 {
                queue.push_back(child);
            }
        }
    }
    if visited != steps.len() {
        return Err(WorkflowIrError::DependencyCycle);
    }
    Ok(())
}

fn input_step_references(step: &StepDefinition) -> Vec<&str> {
    fn push_reference<'a>(references: &mut Vec<&'a str>, binding: &'a InputBinding) {
        if let InputBinding::StepOutput { step_id, .. } = binding {
            references.push(step_id);
        }
    }

    let mut references = Vec::new();
    for binding in step.inputs.values() {
        push_reference(&mut references, binding);
    }
    match &step.kind {
        StepKind::Map {
            collection_input, ..
        }
        | StepKind::Reduce { collection_input } => {
            push_reference(&mut references, collection_input);
        }
        StepKind::Condition { predicate } => match predicate {
            ConditionPredicate::Equals { input, .. }
            | ConditionPredicate::Exists { input }
            | ConditionPredicate::Boolean { input } => {
                push_reference(&mut references, input);
            }
        },
        _ => {}
    }
    references
}

fn validate_fan_out(value: u32, budget: &BudgetPolicy) -> Result<(), WorkflowIrError> {
    if value == 0 || value > budget.max_fan_out {
        return Err(WorkflowIrError::FanOutLimit);
    }
    Ok(())
}

fn validate_text(value: &str, field: &'static str) -> Result<(), WorkflowIrError> {
    validate_bounded_text(value, field, 4096)
}

fn validate_bounded_text(
    value: &str,
    field: &'static str,
    limit: usize,
) -> Result<(), WorkflowIrError> {
    if value.is_empty()
        || value.trim() != value
        || value.len() > limit
        || value.as_bytes().contains(&0)
    {
        return Err(WorkflowIrError::InvalidText(field));
    }
    Ok(())
}
