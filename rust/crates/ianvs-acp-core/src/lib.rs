//! UI-independent ACP and workflow runtime for ianvs.
//!
//! This crate owns protocol negotiation, subprocess lifetime, session/run state,
//! cancellation, permissions, terminal execution, workspace validation, and
//! persistence-facing domain events. It intentionally has no Flutter or C ABI
//! dependency; hosts belong in sibling crates such as `ianvs-acp-ffi`.

#![allow(
    clippy::missing_errors_doc,
    clippy::missing_panics_doc,
    clippy::struct_excessive_bools
)]

mod coordinator;
mod durable_workflow;
mod event_store;
mod execution;
mod execution_gate;
mod filesystem;
mod idempotency;
mod model;
mod persistence;
mod prompt;
mod retry;
mod runtime;
mod scheduler;
mod session_persistence;
mod state;
mod structured_result;
mod task_inbox;
mod terminal;
mod workflow;
mod workflow_ir;
mod workspace;

pub use coordinator::{
    CapabilityRegistry, CapabilityRequirement, CoordinatorError, MAX_CAPABILITY_PROFILES,
    MAX_LEDGER_ENTRIES, MAX_PROGRESS_METADATA_BYTES, PlanProposal, PlanProposalStatus,
    ProgressLedgerEntry, ProgressLedgerKind, SemanticCapabilityProfile, TaskLedgerEntry,
    TaskLedgerStatus, next_step_runs_for_plan, validate_capability_profiles,
    validate_plan_proposal,
};
pub use durable_workflow::{
    DurableWorkflow, DurableWorkflowError, ExecutorTaskInboxCommand, SchedulerClaimProjection,
    TaskInboxMaterializedProjection, TaskInboxStageProjection, WORKFLOW_SCHEMA_VERSION,
    WorkflowCommand, WorkflowOpenProjection, WorkflowProjection,
};
pub use event_store::{
    MAX_RUNTIME_EVENT_APPEND_BATCH, MAX_RUNTIME_EVENT_QUERY_LIMIT, MAX_RUNTIME_EVENT_REPLAY,
    MAX_RUNTIME_EVENTS_PER_RUN, RUNTIME_EVENT_CHECKPOINT_INTERVAL, RuntimeEventAppendReceipt,
    RuntimeEventPage, StoredRuntimeEvent, WORKFLOW_SNAPSHOT_RETENTION,
};
pub use execution::{
    ClassifiedRecoveryReport, ExecutionError, ExecutorCommandContext, ExecutorLease,
    ExecutorLeaseCommand, ExecutorLeaseOperation, ExecutorLeaseState, ExecutorTakeoverRequest,
    PromptSubmissionState, RecoveryState, RunRecoveryRecord, SuggestedRecoveryAction,
    WorkspaceMutationPossibility,
};
pub use execution_gate::{ExecutionGateError, WorkspaceExecutionGate, WorkspaceExecutionLease};
pub use filesystem::{
    FilesystemApproval, FilesystemConfig, FilesystemError, FilesystemManager,
    FilesystemOperationKind, FilesystemOperationResult,
};
pub use idempotency::{
    IdempotencyKey, IdempotencyRecord, MAX_IDEMPOTENCY_PAYLOAD_BYTES, MAX_IDEMPOTENCY_RESULT_BYTES,
};
pub use model::{
    AgentLaunchConfig, AuthMethodProjection, CapabilityProjection, CommandKind,
    McpServerLaunchConfig, PermissionDecision, PermissionOptionProjection,
    PermissionRequestProjection, PromptAttachmentInput, RuntimeEvent, RuntimeEventEnvelope,
    RuntimeStatus, SessionCatalogEntryProjection, SessionConfigChoiceProjection,
    SessionConfigOptionProjection, SessionConfigValueProjection, SessionModeProjection,
    SessionModesProjection, SessionStatus, SessionUpdate, SessionUpdateKind,
};
pub use persistence::{
    RecoveryReport, SqliteWorkflowStore, VersionedWorkflowSnapshot, WorkflowMigrationMetadata,
    WorkflowMigrationPhase, WorkflowStoreError,
};
pub use retry::{RetryPolicy, TaskFailureReason};
pub use runtime::{RuntimeError, RuntimeHandle};
pub use scheduler::{
    SchedulerAdmission, SchedulerAdmissionReason, SchedulerCapacityReservation, SchedulerClaim,
    SchedulerClaimRequest, SchedulerConfig, SchedulerCore, SchedulerError, SchedulerPoll,
    SchedulerRuntimeAvailability, SchedulerRuntimeStatus,
};
pub use session_persistence::{PersistedSession, SessionStoreError, SqliteSessionStore};
pub use state::{RuntimeStateError, RuntimeStateMachine};
pub use structured_result::{
    MAX_AGENT_RESULT_BYTES, MAX_RESULT_CORRECTION_ATTEMPTS, MAX_RESULT_SCHEMA_DEPTH,
    MAX_RESULT_VALIDATION_ISSUES, ResultValidationIssue, StructuredResultAttempt,
    StructuredResultError, StructuredResultRecord, StructuredResultStatus, evaluate_agent_result,
    extract_json_value, validate_result_schema,
};
pub use task_inbox::{
    InboxApprovalKind, InboxApprovalRecord, InboxApprovalStatus, InboxArtifactKind,
    InboxArtifactRecord, InboxArtifactStatus, InboxEventKind, InboxEventRecord, InboxExportTarget,
    InboxResourceRecord, InboxResourceType, InboxRunRecord, InboxTaskPriority, InboxTaskRecord,
    InboxTaskStatus, TASK_INBOX_SCHEMA, TaskInboxCommand, TaskInboxError, TaskInboxMutationError,
    TaskInboxRunTransition, TaskInboxSnapshot, TaskInboxWorkflowImport,
};
pub use terminal::{
    TerminalApproval, TerminalConfig, TerminalCreateSpec, TerminalEnvironmentVariable,
    TerminalError, TerminalExit, TerminalManager, TerminalOutputSnapshot, TerminalRuntimeEvent,
};
pub use workflow::{
    RunState, RunStatus, TaskState, TaskStatus, WorkflowSnapshot, WorkflowStateError,
    WorkflowStateMachine,
};
pub use workflow_ir::{
    ArtifactReference, BudgetPolicy, ConditionPredicate, InputBinding, MAX_STEP_INPUT_BYTES,
    MAX_WORKFLOW_SCHEMA_BYTES, PlanVersion, ResultSchema, StepDefinition, StepKind, StepRun,
    StepRunStatus, WORKFLOW_IR_SCHEMA_VERSION, WorkflowDefinition, WorkflowIrError, WorkflowRun,
    WorkflowRunStatus, WorkflowUsage,
};
pub use workspace::{WorkspaceError, WorkspaceScope};
