//! UI-independent ACP workspace and session runtime for ianvs.
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

mod filesystem;
mod model;
mod prompt;
mod runtime;
mod session_persistence;
mod sqlite_storage;
mod state;
mod terminal;
mod workspace;

pub use filesystem::{
    FilesystemApproval, FilesystemConfig, FilesystemError, FilesystemManager,
    FilesystemOperationKind, FilesystemOperationResult,
};
pub use model::{
    AgentLaunchConfig, AuthMethodProjection, CapabilityProjection, CommandKind,
    McpServerLaunchConfig, PermissionDecision, PermissionOptionProjection,
    PermissionRequestProjection, PromptAttachmentInput, RenderUpdate, RenderUpdateKind,
    RuntimeEvent, RuntimeEventEnvelope, RuntimeStatus, SessionCatalogEntryProjection,
    SessionConfigChoiceProjection, SessionConfigOptionProjection, SessionConfigValueProjection,
    SessionModeProjection, SessionModesProjection, SessionStatus, SessionUpdate, SessionUpdateKind,
};
pub use runtime::{RuntimeError, RuntimeHandle};
pub use session_persistence::{PersistedSession, SessionStoreError, SqliteSessionStore};
pub use sqlite_storage::{
    DEFAULT_SQLITE_MAX_BYTES, DEFAULT_SQLITE_RETENTION_DAYS, SqliteStoragePolicy,
};
pub use state::{RuntimeStateError, RuntimeStateMachine};
pub use terminal::{
    TerminalApproval, TerminalConfig, TerminalCreateSpec, TerminalEnvironmentVariable,
    TerminalError, TerminalExit, TerminalManager, TerminalOutputSnapshot, TerminalRuntimeEvent,
};
pub use workspace::{WorkspaceError, WorkspaceScope};
