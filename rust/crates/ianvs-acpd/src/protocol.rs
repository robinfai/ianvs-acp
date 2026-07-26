use ianvs_acp_core::{
    AgentLaunchConfig, ArtifactReference, ExecutorLease, ExecutorLeaseCommand,
    ExecutorTakeoverRequest, ExecutorTaskInboxCommand, PermissionDecision, PlanProposal,
    RuntimeEventPage, SchedulerClaimProjection, SchedulerClaimRequest, SchedulerConfig,
    SchedulerRuntimeStatus, TaskInboxCommand, TaskInboxMaterializedProjection, TaskInboxSnapshot,
    TaskInboxStageProjection, WorkflowDefinition, WorkflowOpenProjection, WorkflowProjection,
    WorkflowRun, WorkflowStepTaskBinding, WorkflowTaskReconciliation,
};
use serde::{Deserialize, Serialize};

pub const DAEMON_PROTOCOL_VERSION: u16 = 1;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DaemonRequest {
    pub schema_version: u16,
    pub request_id: String,
    pub command: DaemonCommand,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "operation", rename_all = "snake_case", deny_unknown_fields)]
pub enum DaemonCommand {
    Ping,
    OpenProjection {
        #[serde(rename = "databasePath")]
        database_path: String,
    },
    StageTaskInbox {
        source: TaskInboxSnapshot,
        #[serde(rename = "sourceChecksum")]
        source_checksum: String,
    },
    TaskInboxSource,
    MaterializeTaskInbox,
    ActivateTaskInbox,
    ApplyTaskInbox {
        command: TaskInboxCommand,
    },
    ApplyTaskInboxAsExecutor {
        request: ExecutorTaskInboxCommand,
    },
    CurrentTaskInbox,
    CurrentTaskInboxProjection,
    ConfigureScheduler {
        config: SchedulerConfig,
    },
    SetSchedulerRuntimeStatus {
        status: SchedulerRuntimeStatus,
    },
    SchedulerClaimNext {
        request: SchedulerClaimRequest,
    },
    ExecutorLeaseForRun {
        #[serde(rename = "runId")]
        run_id: String,
    },
    ExecutorLeaseCommand {
        command: ExecutorLeaseCommand,
    },
    ExecutorTakeover {
        request: ExecutorTakeoverRequest,
    },
    RuntimeEvents {
        #[serde(rename = "runId")]
        run_id: String,
        #[serde(rename = "afterSequence")]
        after_sequence: u64,
        limit: usize,
    },
    ConfigureAgents {
        agents: Vec<AgentLaunchConfig>,
    },
    RegisterWorkflowDefinition {
        definition: WorkflowDefinition,
    },
    WorkflowDefinition {
        #[serde(rename = "definitionId")]
        definition_id: String,
        version: u32,
    },
    CreateWorkflowRun {
        run: WorkflowRun,
    },
    WorkflowRun {
        #[serde(rename = "runId")]
        run_id: String,
    },
    StartWorkflowStep {
        #[serde(rename = "runId")]
        run_id: String,
        #[serde(rename = "stepId")]
        step_id: String,
        input: serde_json::Value,
        now: String,
    },
    CompleteWorkflowStep {
        #[serde(rename = "runId")]
        run_id: String,
        #[serde(rename = "stepId")]
        step_id: String,
        output: serde_json::Value,
        artifacts: Vec<ArtifactReference>,
        now: String,
    },
    SubmitWorkflowStepResult {
        #[serde(rename = "runId")]
        run_id: String,
        #[serde(rename = "stepId")]
        step_id: String,
        raw: String,
        artifacts: Vec<ArtifactReference>,
        now: String,
    },
    ProposeWorkflowPlan {
        #[serde(rename = "runId")]
        run_id: String,
        proposal: PlanProposal,
    },
    ActivateWorkflowPlan {
        #[serde(rename = "runId")]
        run_id: String,
        #[serde(rename = "proposalId")]
        proposal_id: String,
        now: String,
    },
    RecordWorkflowUsage {
        #[serde(rename = "runId")]
        run_id: String,
        #[serde(rename = "inputTokens")]
        input_tokens: u64,
        #[serde(rename = "outputTokens")]
        output_tokens: u64,
        #[serde(rename = "costMicros")]
        cost_micros: u64,
        now: String,
    },
    ReconcileWorkflowTasks {
        now: String,
    },
    WorkflowStepTaskBindings {
        #[serde(rename = "runId")]
        run_id: String,
    },
    ResolveWorkflowApprovalStep {
        #[serde(rename = "runId")]
        run_id: String,
        #[serde(rename = "stepId")]
        step_id: String,
        approved: bool,
        now: String,
    },
    SignalWorkflowWaitStep {
        #[serde(rename = "runId")]
        run_id: String,
        #[serde(rename = "stepId")]
        step_id: String,
        #[serde(rename = "signalName")]
        signal_name: String,
        payload: serde_json::Value,
        now: String,
    },
    RespondTaskPermission {
        #[serde(rename = "runId")]
        run_id: String,
        #[serde(rename = "requestId")]
        permission_request_id: String,
        decision: PermissionDecision,
        now: String,
    },
    Shutdown,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DaemonResponse {
    pub schema_version: u16,
    pub request_id: String,
    pub result: DaemonResult,
}

impl DaemonResponse {
    #[must_use]
    pub fn success(request_id: String, result: DaemonResult) -> Self {
        Self {
            schema_version: DAEMON_PROTOCOL_VERSION,
            request_id,
            result,
        }
    }

    pub fn error(request_id: String, code: impl Into<String>, message: impl Into<String>) -> Self {
        Self::success(
            request_id,
            DaemonResult::Error {
                code: code.into(),
                message: message.into(),
            },
        )
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[allow(clippy::large_enum_variant)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
pub enum DaemonResult {
    Pong {
        #[serde(rename = "hostInstanceId")]
        host_instance_id: String,
    },
    OpenProjection {
        projection: WorkflowOpenProjection,
    },
    WorkflowProjection {
        projection: WorkflowProjection,
    },
    TaskInboxStage {
        projection: TaskInboxStageProjection,
    },
    TaskInboxProjection {
        projection: TaskInboxMaterializedProjection,
    },
    TaskInboxSnapshot {
        snapshot: Option<TaskInboxSnapshot>,
    },
    CurrentTaskInboxProjection {
        projection: Option<TaskInboxMaterializedProjection>,
    },
    SchedulerClaim {
        projection: SchedulerClaimProjection,
    },
    ExecutorLease {
        lease: Option<ExecutorLease>,
    },
    RuntimeEvents {
        page: RuntimeEventPage,
    },
    AgentsConfigured {
        #[serde(rename = "agentNames")]
        agent_names: Vec<String>,
    },
    WorkflowDefinition {
        definition: Option<WorkflowDefinition>,
    },
    WorkflowRun {
        run: Option<WorkflowRun>,
    },
    WorkflowStepTaskBindings {
        bindings: Vec<WorkflowStepTaskBinding>,
    },
    WorkflowTasksReconciled {
        reconciliation: WorkflowTaskReconciliation,
    },
    Ack,
    Error {
        code: String,
        message: String,
    },
}
