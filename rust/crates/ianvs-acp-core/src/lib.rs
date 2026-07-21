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

mod durable_workflow;
mod execution_gate;
mod filesystem;
mod model;
mod persistence;
mod prompt;
mod retry;
mod runtime;
mod scheduler;
mod session_persistence;
mod state;
mod task_inbox;
mod terminal;
mod workflow;
mod workspace;

pub use durable_workflow::{
    DurableWorkflow, DurableWorkflowError, SchedulerClaimProjection,
    TaskInboxMaterializedProjection, TaskInboxStageProjection, WORKFLOW_SCHEMA_VERSION,
    WorkflowCommand, WorkflowOpenProjection, WorkflowProjection,
};
pub use execution_gate::{ExecutionGateError, WorkspaceExecutionGate, WorkspaceExecutionLease};
pub use filesystem::{
    FilesystemApproval, FilesystemConfig, FilesystemError, FilesystemManager,
    FilesystemOperationKind, FilesystemOperationResult,
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
    SchedulerClaim, SchedulerClaimRequest, SchedulerConfig, SchedulerCore, SchedulerError,
    SchedulerPoll, SchedulerRuntimeAvailability, SchedulerRuntimeStatus,
};
pub use session_persistence::{PersistedSession, SessionStoreError, SqliteSessionStore};
pub use state::{RuntimeStateError, RuntimeStateMachine};
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
pub use workspace::{WorkspaceError, WorkspaceScope};
