use std::collections::{HashMap, HashSet};
use std::fmt::Write as _;
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::pin::pin;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, SyncSender, TryRecvError};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use agent_client_protocol::schema::ProtocolVersion;
use agent_client_protocol::schema::v1::{
    AuthMethod, AuthenticateRequest, AvailableCommand, AvailableCommandInput, CancelNotification,
    ClientCapabilities, CloseSessionRequest, ContentBlock, CreateTerminalRequest,
    CreateTerminalResponse, DeleteSessionRequest, EnvVariable, FileSystemCapabilities, HttpHeader,
    InitializeRequest, KillTerminalRequest, KillTerminalResponse, ListSessionsRequest,
    LoadSessionRequest, LogoutRequest, McpServer as AcpMcpServer, McpServerHttp, McpServerSse,
    McpServerStdio, NewSessionRequest, NewSessionResponse, PermissionOptionKind, PromptRequest,
    ReadTextFileRequest, ReadTextFileResponse, ReleaseTerminalRequest, ReleaseTerminalResponse,
    RequestPermissionOutcome, RequestPermissionRequest, RequestPermissionResponse,
    ResumeSessionRequest, SelectedPermissionOutcome, SessionConfigKind, SessionConfigOption,
    SessionConfigOptionValue, SessionConfigSelectOptions, SessionInfo, SessionModeState,
    SessionNotification, SessionUpdate as AcpSessionUpdate, SetSessionConfigOptionRequest,
    SetSessionModeRequest, StopReason, TerminalExitStatus, TerminalOutputRequest,
    TerminalOutputResponse, WaitForTerminalExitRequest, WaitForTerminalExitResponse,
    WriteTextFileRequest, WriteTextFileResponse,
};
use agent_client_protocol::{Agent, ConnectTo, ConnectionTo, Error as AcpError, Lines, Responder};
use futures::io::{AsyncBufRead, BufReader};
use futures::{AsyncBufReadExt, AsyncWriteExt};
use thiserror::Error;
use tokio::sync::mpsc as tokio_mpsc;
use uuid::Uuid;

use crate::prompt::{PromptSupport, project_prompt_content};
use crate::workspace::normalize_workspace_identity;
use crate::{
    AgentLaunchConfig, AuthMethodProjection, CapabilityProjection, FilesystemApproval,
    FilesystemConfig, FilesystemManager, FilesystemOperationKind, FilesystemOperationResult,
    McpServerLaunchConfig, PermissionDecision, PermissionOptionProjection,
    PermissionRequestProjection, PersistedSession, PromptAttachmentInput, RenderUpdate,
    RenderUpdateKind, RuntimeEvent, RuntimeEventEnvelope, RuntimeStateMachine, RuntimeStatus,
    SessionCatalogEntryProjection, SessionConfigChoiceProjection, SessionConfigOptionProjection,
    SessionConfigValueProjection, SessionModeProjection, SessionModesProjection, SessionUpdate,
    SessionUpdateKind, SqliteSessionStore, TerminalCreateSpec, TerminalEnvironmentVariable,
    TerminalExit, TerminalManager, TerminalRuntimeEvent, WorkspaceScope,
};

const COMMAND_CAPACITY: usize = 256;
const EVENT_CAPACITY: usize = 2_048;
const EVENT_RETAINED_BYTES_MAX: usize = 32 * 1024 * 1024;
const EVENT_SINGLE_BYTES_MAX: usize = 2 * 1024 * 1024;
const HOST_REQUEST_ID_MAX_BYTES: usize = 8 * 1024;
const EVENT_ERROR_CODE_MAX_BYTES: usize = 1024;
const EVENT_ERROR_MESSAGE_MAX_BYTES: usize = 64 * 1024;
const DEFAULT_PERMISSION_TIMEOUT: Duration = Duration::from_secs(120);
const MAX_PENDING_PERMISSIONS: usize = 64;
const MAX_PENDING_PERMISSIONS_PER_SESSION: usize = 8;
const PERMISSION_MAX_OPTIONS: usize = 16;
const PERMISSION_MAX_TEXT_BYTES: usize = 8 * 1024;
const PERMISSION_MAX_RAW_INPUT_BYTES: usize = 48 * 1024;
const PERMISSION_MAX_PROJECTION_BYTES: usize = 64 * 1024;
const DEFAULT_MAX_RESTART_ATTEMPTS: u32 = 2;
const DEFAULT_RESTART_BASE_DELAY: Duration = Duration::from_millis(250);
const SESSION_LIST_MAX_PAGES: usize = 100;
const SESSION_LIST_MAX_ENTRIES: usize = 10_000;
const SESSION_LIST_MAX_CURSOR_BYTES: usize = 8 * 1024;
const SESSION_CATALOG_MAX_ADDITIONAL_DIRECTORIES: usize = 128;
const SESSION_CATALOG_PATH_MAX_BYTES: usize = 32 * 1024;
const SESSION_CATALOG_METADATA_MAX_BYTES: usize = 64 * 1024;
const SESSION_CATALOG_ENTRY_MAX_BYTES: usize = 128 * 1024;
const SESSION_CATALOG_MAX_PROJECTION_BYTES: usize = 1024 * 1024;
const SESSION_ID_MAX_BYTES: usize = 8 * 1024;
const SESSION_TITLE_MAX_CHARACTERS: usize = 256;
const SESSION_CONFIG_MAX_OPTIONS: usize = 256;
const SESSION_CONFIG_MAX_CHOICES: usize = 4_096;
const SESSION_CONFIG_MAX_TEXT_BYTES: usize = 8 * 1024;
const SESSION_CONFIG_MAX_PROJECTION_BYTES: usize = 256 * 1024;
const STAGED_CONFIG_MAX_ENTRIES: usize = 4;
const STAGED_CONFIG_MAX_BYTES: usize = 512 * 1024;
const SESSION_MODES_MAX_ENTRIES: usize = 256;
const SESSION_MODE_TEXT_MAX_BYTES: usize = 8 * 1024;
const SESSION_MODES_MAX_PROJECTION_BYTES: usize = 256 * 1024;
const AVAILABLE_COMMANDS_MAX_ENTRIES: usize = 1_024;
const AVAILABLE_COMMAND_NAME_MAX_BYTES: usize = 1_024;
const AVAILABLE_COMMAND_DESCRIPTION_MAX_BYTES: usize = 8 * 1_024;
const AVAILABLE_COMMAND_HINT_MAX_BYTES: usize = 8 * 1_024;
const AVAILABLE_COMMANDS_MAX_PROJECTION_BYTES: usize = 512 * 1024;
const AUTH_METHODS_MAX_ENTRIES: usize = 32;
const AUTH_METHOD_ID_MAX_BYTES: usize = 1024;
const AUTH_METHOD_NAME_MAX_BYTES: usize = 4 * 1024;
const AUTH_METHOD_DESCRIPTION_MAX_BYTES: usize = 8 * 1024;
const AUTH_METHODS_MAX_PROJECTION_BYTES: usize = 64 * 1024;
const INITIALIZE_DETAIL_MAX_BYTES: usize = 16 * 1024;
const INITIALIZE_MAX_PROJECTION_BYTES: usize = 512 * 1024;
const ACP_PROTOCOL_LINE_MAX_BYTES: usize = 16 * 1024 * 1024;
const AGENT_STDERR_LINE_MAX_BYTES: usize = 256 * 1024;
// Keep replay projection work below a frame-sized slice once it crosses FFI.
// The Dart host cooperatively drains several chunks instead of projecting a
// whole restored transcript in one event-loop turn.
const RENDER_SNAPSHOT_CHUNK_TARGET_BYTES: usize = 64 * 1024;
const RENDER_SNAPSHOT_CHUNK_MAX_UPDATES: usize = 16;
const RENDER_COALESCED_TEXT_TARGET_BYTES: usize = RENDER_SNAPSHOT_CHUNK_TARGET_BYTES / 2;
const RENDER_TOOL_DETAIL_MAX_BYTES: usize = 128 * 1024;
const RENDER_TOOL_CONTENT_MAX_BYTES: usize = 512 * 1024;
const RENDER_TEXT_CHUNK_MAX_BYTES: usize = 256 * 1024;
const RENDER_METADATA_MAX_BYTES: usize = 1024 * 1024;
const RENDER_TITLE_MAX_BYTES: usize = 128 * 1024;
const TERMINAL_ALLOW_ONCE_OPTION_ID: &str = "ianvs_terminal_allow_once";
const TERMINAL_REJECT_ONCE_OPTION_ID: &str = "ianvs_terminal_reject_once";
const FILESYSTEM_ALLOW_ONCE_OPTION_ID: &str = "ianvs_filesystem_allow_once";
const FILESYSTEM_REJECT_ONCE_OPTION_ID: &str = "ianvs_filesystem_reject_once";

/// Errors returned synchronously by the host-facing runtime handle.
#[derive(Debug, Error, PartialEq, Eq)]
pub enum RuntimeError {
    #[error("runtime command queue is closed")]
    Closed,
    #[error("runtime command queue is full")]
    Backpressure,
    #[error("request id must not be empty")]
    InvalidRequestId,
    #[error("session id must not be empty")]
    InvalidSessionId,
    #[error("authentication method id must not be empty")]
    InvalidAuthMethodId,
    #[error("session config id must not be empty")]
    InvalidConfigId,
    #[error("runtime worker thread panicked")]
    WorkerPanicked,
}

#[derive(Debug)]
enum RuntimeCommand {
    StartAgent(Box<AgentLaunchConfig>),
    CreateSession {
        request_id: String,
        cwd: String,
        additional_directories: Vec<String>,
    },
    RestoreSession {
        request_id: String,
        session_id: String,
        cwd: String,
        additional_directories: Vec<String>,
        replay_history: bool,
    },
    ListSessions {
        request_id: String,
    },
    CloseSession {
        request_id: String,
        session_id: String,
    },
    DeleteSession {
        request_id: String,
        session_id: String,
    },
    Authenticate {
        request_id: String,
        method_id: String,
    },
    Logout {
        request_id: String,
    },
    Prompt {
        request_id: String,
        session_id: String,
        text: String,
        attachments: Vec<PromptAttachmentInput>,
    },
    Cancel {
        request_id: String,
        session_id: String,
    },
    RespondPermission {
        request_id: String,
        decision: PermissionDecision,
    },
    SetMode {
        request_id: String,
        session_id: String,
        mode_id: String,
    },
    SetConfigOption {
        request_id: String,
        session_id: String,
        config_id: String,
        value: SessionConfigValueProjection,
    },
    Dispose,
}

#[derive(Debug)]
enum InternalEvent {
    SessionCreated {
        request_id: String,
        cwd: String,
        scope: WorkspaceScope,
        result: Result<CreatedSession, String>,
    },
    SessionRestored {
        request_id: String,
        requested_session_id: String,
        cwd: String,
        scope: WorkspaceScope,
        result: Result<RestoredSession, String>,
    },
    SessionCataloged {
        request_id: String,
        result: Result<Vec<SessionCatalogEntryProjection>, String>,
    },
    SessionClosed {
        request_id: String,
        session_id: String,
        result: Result<(), String>,
    },
    SessionDeleted {
        request_id: String,
        session_id: String,
        result: Result<(), String>,
    },
    AuthenticationChanged {
        request_id: String,
        authenticated: bool,
        method_id: Option<String>,
        result: Result<(), String>,
    },
    PromptFinished {
        request_id: String,
        session_id: String,
        result: Result<String, String>,
    },
    PermissionWaiting {
        request_id: String,
        session_id: String,
    },
    PermissionTimedOut {
        request_id: String,
    },
    ModeSet {
        request_id: String,
        session_id: String,
        mode_id: String,
        result: Result<(), String>,
    },
    ConfigSet {
        request_id: String,
        session_id: String,
        result: Result<Vec<SessionConfigOptionProjection>, String>,
    },
    ConfigNotified {
        session_id: String,
        options: Vec<SessionConfigOptionProjection>,
    },
}

enum PendingPermission {
    Acp {
        session_id: String,
        responder: Responder<RequestPermissionResponse>,
    },
    Terminal {
        session_id: String,
        approval_id: String,
        manager: Arc<TerminalManager>,
        responder: Responder<CreateTerminalResponse>,
    },
    FilesystemRead {
        session_id: String,
        approval_id: String,
        manager: Arc<FilesystemManager>,
        responder: Responder<ReadTextFileResponse>,
    },
    FilesystemWrite {
        session_id: String,
        approval_id: String,
        manager: Arc<FilesystemManager>,
        responder: Responder<WriteTextFileResponse>,
    },
}

impl PendingPermission {
    fn session_id(&self) -> &str {
        match self {
            Self::Acp { session_id, .. }
            | Self::Terminal { session_id, .. }
            | Self::FilesystemRead { session_id, .. }
            | Self::FilesystemWrite { session_id, .. } => session_id,
        }
    }
}

struct PermissionAdmissionError {
    pending: PendingPermission,
    message: &'static str,
}

fn admit_pending_permission(
    pending: &Mutex<HashMap<String, PendingPermission>>,
    request_id: String,
    permission: PendingPermission,
) -> Result<(), Box<PermissionAdmissionError>> {
    let session_id = permission.session_id();
    let mut pending = pending.lock().expect("permission mutex poisoned");
    let message = if pending.len() >= MAX_PENDING_PERMISSIONS {
        Some("global pending permission capacity reached")
    } else if pending
        .values()
        .filter(|value| value.session_id() == session_id)
        .count()
        >= MAX_PENDING_PERMISSIONS_PER_SESSION
    {
        Some("session pending permission capacity reached")
    } else if pending.contains_key(&request_id) {
        Some("duplicate pending permission request id")
    } else {
        None
    };
    if let Some(message) = message {
        return Err(Box::new(PermissionAdmissionError {
            pending: permission,
            message,
        }));
    }
    pending.insert(request_id, permission);
    Ok(())
}

fn reject_unadmitted_permission(error: PermissionAdmissionError) -> Result<(), AcpError> {
    let PermissionAdmissionError { pending, message } = error;
    let response_error = || AcpError::new(-32000, message);
    match pending {
        PendingPermission::Acp { responder, .. } => responder.respond_with_error(response_error()),
        PendingPermission::Terminal {
            approval_id,
            manager,
            responder,
            ..
        } => {
            let _ = manager.deny_create(&approval_id);
            responder.respond_with_error(response_error())
        }
        PendingPermission::FilesystemRead {
            approval_id,
            manager,
            responder,
            ..
        } => {
            let _ = manager.deny(&approval_id);
            responder.respond_with_error(response_error())
        }
        PendingPermission::FilesystemWrite {
            approval_id,
            manager,
            responder,
            ..
        } => {
            let _ = manager.deny(&approval_id);
            responder.respond_with_error(response_error())
        }
    }
}

#[derive(Debug)]
struct CreatedSession {
    session_id: String,
    modes: Option<SessionModesProjection>,
    config_options: Vec<SessionConfigOptionProjection>,
}

#[derive(Debug)]
struct RestoredSession {
    session_id: String,
    modes: Option<SessionModesProjection>,
    replayed_history: bool,
    config_options: Vec<SessionConfigOptionProjection>,
}

#[derive(Debug, Clone, Copy)]
struct SessionSupport {
    load: bool,
    list: bool,
    resume: bool,
    close: bool,
    delete: bool,
}

struct AgentRunOutcome {
    result: Result<(), String>,
    session_activity: bool,
}

struct SessionRecoveryRegistry {
    persistence_identity: String,
    active: HashMap<String, PersistedSession>,
    store: Option<SqliteSessionStore>,
}

impl SessionRecoveryRegistry {
    fn open(config: &AgentLaunchConfig) -> Result<Self, String> {
        let mut store = config
            .session_store_path
            .as_deref()
            .map(|path| {
                let defaults = crate::SqliteStoragePolicy::default();
                let policy = crate::SqliteStoragePolicy::new(
                    config
                        .session_store_max_bytes
                        .unwrap_or(defaults.max_bytes()),
                    config
                        .session_store_retention_days
                        .unwrap_or(defaults.retention_days()),
                )
                .map_err(std::string::ToString::to_string)?;
                SqliteSessionStore::open_with_policy(path, policy)
                    .map_err(|error| error.to_string())
            })
            .transpose()?;
        let persistence_identity = config
            .persistence_identity
            .clone()
            .unwrap_or_else(|| config.agent_name.clone());
        if let Some(store) = store.as_mut() {
            let mut migrated_names = HashSet::new();
            for prior_name in
                std::iter::once(&config.agent_name).chain(config.persistence_aliases.iter())
            {
                if migrated_names.insert(prior_name.as_str()) {
                    store
                        .migrate_agent_identity(prior_name, &persistence_identity)
                        .map_err(|error| error.to_string())?;
                }
            }
        }
        let active = store
            .as_mut()
            .map(|store| store.load_active(&persistence_identity))
            .transpose()
            .map_err(|error| error.to_string())?
            .unwrap_or_default()
            .into_iter()
            .map(|session| (session.session_id.clone(), session))
            .collect();
        Ok(Self {
            persistence_identity,
            active,
            store,
        })
    }

    fn activate(&mut self, session_id: &str, scope: &WorkspaceScope) -> Result<(), String> {
        let session = PersistedSession::from_scope(
            self.persistence_identity.clone(),
            session_id.to_string(),
            scope,
        );
        if let Some(store) = self.store.as_mut() {
            store.upsert(&session).map_err(|error| error.to_string())?;
        }
        self.active.insert(session_id.to_string(), session);
        Ok(())
    }

    fn remove(&mut self, session_id: &str) -> Result<(), String> {
        let store_result = if let Some(store) = self.store.as_mut() {
            store
                .remove(&self.persistence_identity, session_id)
                .map_err(|error| error.to_string())
        } else {
            Ok(())
        };
        self.active.remove(session_id);
        store_result
    }

    fn touch(&mut self, session_id: &str) -> Result<(), String> {
        if let Some(store) = self.store.as_mut() {
            store
                .touch(&self.persistence_identity, session_id)
                .map_err(|error| error.to_string())?;
        }
        Ok(())
    }

    fn sessions(&self) -> Vec<PersistedSession> {
        let mut sessions = self.active.values().cloned().collect::<Vec<_>>();
        sessions.sort_by(|left, right| left.session_id.cmp(&right.session_id));
        sessions
    }
}

#[derive(Default)]
struct RecoveredRuntimeSessions {
    scopes: HashMap<String, WorkspaceScope>,
    config_options: HashMap<String, Vec<SessionConfigOptionProjection>>,
    failures: Vec<(String, String)>,
}

#[derive(Clone)]
struct EventSink {
    sender: SyncSender<QueuedRuntimeEvent>,
    budget: Arc<EventQueueBudget>,
    next_sequence: Arc<Mutex<u64>>,
}

impl EventSink {
    fn emit(&self, event: RuntimeEvent) {
        let mut next_sequence = self
            .next_sequence
            .lock()
            .expect("event sequence mutex poisoned");
        let sequence = *next_sequence;
        *next_sequence = next_sequence.saturating_add(1);
        let (envelope, retained_bytes) = bounded_event_envelope(sequence, event);
        // Count and retained-byte blocking are both intentional. The sequence
        // lock remains held so concurrent PTY, stderr, and protocol producers
        // cannot enqueue out of order while one producer waits for budget.
        if !self.budget.reserve(retained_bytes) {
            return;
        }
        let _ = self.sender.send(QueuedRuntimeEvent {
            envelope: Some(envelope),
            retained_bytes,
            budget: Arc::clone(&self.budget),
        });
    }

    fn error(
        &self,
        request_id: Option<String>,
        code: impl Into<String>,
        message: impl Into<String>,
        recoverable: bool,
    ) {
        self.emit(RuntimeEvent::RuntimeError {
            request_id,
            code: truncate_utf8(code.into(), EVENT_ERROR_CODE_MAX_BYTES),
            message: truncate_utf8(message.into(), EVENT_ERROR_MESSAGE_MAX_BYTES),
            recoverable,
        });
    }
}

struct EventQueueBudget {
    max_bytes: usize,
    state: Mutex<EventQueueBudgetState>,
    available: Condvar,
}

#[derive(Default)]
struct EventQueueBudgetState {
    retained_bytes: usize,
    closed: bool,
}

impl EventQueueBudget {
    fn new(max_bytes: usize) -> Self {
        Self {
            max_bytes,
            state: Mutex::new(EventQueueBudgetState::default()),
            available: Condvar::new(),
        }
    }

    fn reserve(&self, bytes: usize) -> bool {
        let mut state = self.state.lock().expect("event budget mutex poisoned");
        while !state.closed && bytes > self.max_bytes.saturating_sub(state.retained_bytes) {
            state = self
                .available
                .wait(state)
                .expect("event budget mutex poisoned");
        }
        if state.closed {
            return false;
        }
        state.retained_bytes = state.retained_bytes.saturating_add(bytes);
        true
    }

    fn release(&self, bytes: usize) {
        let mut state = self.state.lock().expect("event budget mutex poisoned");
        state.retained_bytes = state.retained_bytes.saturating_sub(bytes);
        self.available.notify_all();
    }

    fn close(&self) {
        let mut state = self.state.lock().expect("event budget mutex poisoned");
        state.closed = true;
        self.available.notify_all();
    }
}

struct QueuedRuntimeEvent {
    envelope: Option<RuntimeEventEnvelope>,
    retained_bytes: usize,
    budget: Arc<EventQueueBudget>,
}

impl QueuedRuntimeEvent {
    fn into_envelope(mut self) -> RuntimeEventEnvelope {
        self.envelope
            .take()
            .expect("queued event must have an envelope")
    }
}

impl Drop for QueuedRuntimeEvent {
    fn drop(&mut self) {
        self.budget.release(self.retained_bytes);
    }
}

struct EventReceiver {
    receiver: Receiver<QueuedRuntimeEvent>,
    budget: Arc<EventQueueBudget>,
}

impl EventReceiver {
    fn try_recv(&self) -> Result<RuntimeEventEnvelope, TryRecvError> {
        self.receiver
            .try_recv()
            .map(QueuedRuntimeEvent::into_envelope)
    }

    fn recv_timeout(&self, timeout: Duration) -> Result<RuntimeEventEnvelope, RecvTimeoutError> {
        self.receiver
            .recv_timeout(timeout)
            .map(QueuedRuntimeEvent::into_envelope)
    }

    #[cfg(test)]
    fn try_iter(&self) -> impl Iterator<Item = RuntimeEventEnvelope> + '_ {
        std::iter::from_fn(|| self.try_recv().ok())
    }
}

impl Drop for EventReceiver {
    fn drop(&mut self) {
        self.budget.close();
    }
}

fn bounded_event_envelope(sequence: u64, event: RuntimeEvent) -> (RuntimeEventEnvelope, usize) {
    let request_id = runtime_event_request_id(&event);
    let mut envelope = RuntimeEventEnvelope::new(sequence, event);
    let encoded = serde_json::to_vec(&envelope);
    let should_replace = match encoded.as_ref() {
        Ok(encoded) => encoded.len() > EVENT_SINGLE_BYTES_MAX,
        Err(_) => true,
    };
    if should_replace {
        let observed_bytes = encoded.as_ref().map_or(0, Vec::len);
        envelope = RuntimeEventEnvelope::new(
            sequence,
            RuntimeEvent::RuntimeError {
                request_id,
                code: "event_projection_too_large".to_string(),
                message: format!(
                    "runtime event exceeded the {EVENT_SINGLE_BYTES_MAX}-byte queue policy (observed {observed_bytes} bytes)"
                ),
                recoverable: false,
            },
        );
    }
    let retained_bytes = serde_json::to_vec(&envelope)
        .map_or(EVENT_SINGLE_BYTES_MAX, |encoded| encoded.len())
        .max(1);
    (envelope, retained_bytes)
}

fn runtime_event_request_id(event: &RuntimeEvent) -> Option<String> {
    match event {
        RuntimeEvent::SessionUpdate { update } => update.request_id.clone(),
        RuntimeEvent::RenderSnapshotChunk { request_id, .. }
        | RuntimeEvent::SessionCatalog { request_id, .. }
        | RuntimeEvent::AuthenticationChanged { request_id, .. } => Some(request_id.clone()),
        RuntimeEvent::PermissionRequest { request } => Some(request.request_id.clone()),
        RuntimeEvent::RuntimeError { request_id, .. } => request_id.clone(),
        _ => None,
    }
}

fn truncate_utf8(mut value: String, max_bytes: usize) -> String {
    if value.len() <= max_bytes {
        return value;
    }
    let mut boundary = max_bytes;
    while !value.is_char_boundary(boundary) {
        boundary = boundary.saturating_sub(1);
    }
    value.truncate(boundary);
    value
}

#[derive(Default)]
struct ReplayRenderProjection {
    request_id: String,
    ready_updates: Vec<RenderUpdate>,
    updates: Vec<RenderUpdate>,
    emit_incrementally: bool,
    next_chunk_index: u32,
}

impl ReplayRenderProjection {
    fn push(&mut self, update: RenderUpdate) -> Option<Vec<RenderUpdate>> {
        // A new user update closes every preceding replay turn. Once that
        // boundary is observed, later ACP notifications cannot merge into the
        // completed prefix because tool updates never cross a user message.
        // Transfer that immutable prefix while the adapter is still replaying
        // the remainder, but keep adjacent chunks of one user message local so
        // the existing coalescing semantics remain unchanged.
        let completed = (self.emit_incrementally
            && update.kind == RenderUpdateKind::UserMessage
            && self
                .updates
                .last()
                .is_some_and(|previous| previous.kind != RenderUpdateKind::UserMessage))
        .then(|| std::mem::take(&mut self.updates));
        if self.coalesce_adjacent_text(&update) || self.merge_tool_update(&update) {
            return completed;
        }
        self.updates.push(update);
        completed
    }

    fn coalesce_adjacent_text(&mut self, update: &RenderUpdate) -> bool {
        let Some(previous) = self.updates.last_mut() else {
            return false;
        };
        if previous.kind != update.kind
            || !matches!(
                update.kind,
                RenderUpdateKind::UserMessage
                    | RenderUpdateKind::AssistantText
                    | RenderUpdateKind::Thought
            )
        {
            return false;
        }
        let text_target = if update.kind == RenderUpdateKind::UserMessage {
            RENDER_TOOL_DETAIL_MAX_BYTES * 2
        } else {
            RENDER_COALESCED_TEXT_TARGET_BYTES
        };
        if previous.text.len().saturating_add(update.text.len()) > text_target {
            return false;
        }
        if update.kind == RenderUpdateKind::UserMessage
            && render_metadata_bytes(previous.metadata.as_ref())
                .saturating_add(render_metadata_bytes(update.metadata.as_ref()))
                > RENDER_METADATA_MAX_BYTES
        {
            return false;
        }
        previous.text.push_str(&update.text);
        if update.kind == RenderUpdateKind::UserMessage {
            merge_content_block_metadata(&mut previous.metadata, update.metadata.as_ref());
        }
        true
    }

    fn merge_tool_update(&mut self, update: &RenderUpdate) -> bool {
        if update.kind != RenderUpdateKind::ToolCall {
            return false;
        }
        let Some(tool_call_id) = render_tool_call_id(update) else {
            return false;
        };
        for previous in self.updates.iter_mut().rev() {
            if previous.kind == RenderUpdateKind::UserMessage {
                break;
            }
            if previous.kind != RenderUpdateKind::ToolCall
                || render_tool_call_id(previous) != Some(tool_call_id)
            {
                continue;
            }
            if !update.text.trim().is_empty() {
                previous.text.clone_from(&update.text);
            }
            merge_render_metadata(&mut previous.metadata, update.metadata.as_ref());
            return true;
        }
        false
    }
}

#[derive(Clone)]
struct RenderRouter {
    sink: EventSink,
    replay: Arc<Mutex<HashMap<String, ReplayRenderProjection>>>,
    emission: Arc<Mutex<()>>,
}

impl RenderRouter {
    fn new(sink: EventSink) -> Self {
        Self {
            sink,
            replay: Arc::new(Mutex::new(HashMap::new())),
            emission: Arc::new(Mutex::new(())),
        }
    }

    fn begin_replay(&self, session_id: String, request_id: String) {
        self.begin_replay_with_transfer(session_id, request_id, true);
    }

    fn begin_recovery_replay(&self, session_id: String, request_id: String) {
        self.begin_replay_with_transfer(session_id, request_id, false);
    }

    fn begin_replay_with_transfer(
        &self,
        session_id: String,
        request_id: String,
        emit_incrementally: bool,
    ) {
        self.replay
            .lock()
            .expect("render replay mutex poisoned")
            .insert(
                session_id,
                ReplayRenderProjection {
                    request_id,
                    ready_updates: Vec::new(),
                    updates: Vec::new(),
                    emit_incrementally,
                    next_chunk_index: 0,
                },
            );
    }

    fn route(&self, update: RenderUpdate) {
        let _emission = self
            .emission
            .lock()
            .expect("render emission mutex poisoned");
        let session_id = update.session_id.clone();
        let mut replay = self.replay.lock().expect("render replay mutex poisoned");
        if let Some(projection) = replay.get_mut(&session_id) {
            let completed = projection.push(update).map(|updates| {
                projection.ready_updates.extend(updates);
                let chunks = Self::take_complete_snapshot_chunks(&mut projection.ready_updates);
                let chunk_index = projection.next_chunk_index;
                projection.next_chunk_index = projection
                    .next_chunk_index
                    .saturating_add(u32::try_from(chunks.len()).unwrap_or(u32::MAX));
                (projection.request_id.clone(), chunk_index, chunks)
            });
            std::mem::drop(replay);
            if let Some((request_id, chunk_index, chunks)) = completed {
                self.emit_snapshot_chunk_batch(
                    &request_id,
                    &session_id,
                    chunk_index,
                    false,
                    chunks,
                );
            }
            return;
        }
        std::mem::drop(replay);
        self.sink.emit(RuntimeEvent::RenderUpdate { update });
    }

    fn finish_replay(&self, session_id: &str, request_id: &str) {
        let _emission = self
            .emission
            .lock()
            .expect("render emission mutex poisoned");
        let projection = self
            .replay
            .lock()
            .expect("render replay mutex poisoned")
            .remove(session_id);
        let Some(projection) = projection else {
            return;
        };
        if projection.request_id != request_id {
            return;
        }
        let mut updates = projection.ready_updates;
        updates.extend(projection.updates);
        self.emit_snapshot_chunks(
            request_id,
            session_id,
            projection.next_chunk_index,
            true,
            updates,
        );
    }

    fn abort_replay(&self, request_id: &str) {
        let _emission = self
            .emission
            .lock()
            .expect("render emission mutex poisoned");
        self.replay
            .lock()
            .expect("render replay mutex poisoned")
            .retain(|_, projection| projection.request_id != request_id);
    }

    fn split_snapshot_updates(updates: Vec<RenderUpdate>) -> Vec<Vec<RenderUpdate>> {
        let mut chunks = Vec::<Vec<RenderUpdate>>::new();
        let mut chunk = Vec::<RenderUpdate>::new();
        let mut chunk_bytes = 0_usize;
        for update in updates {
            let update_bytes = serde_json::to_vec(&update).map_or(0, |encoded| encoded.len());
            if !chunk.is_empty()
                && (chunk.len() >= RENDER_SNAPSHOT_CHUNK_MAX_UPDATES
                    || chunk_bytes.saturating_add(update_bytes)
                        > RENDER_SNAPSHOT_CHUNK_TARGET_BYTES)
            {
                chunks.push(std::mem::take(&mut chunk));
                chunk_bytes = 0;
            }
            chunk_bytes = chunk_bytes.saturating_add(update_bytes);
            chunk.push(update);
        }
        if !chunk.is_empty() {
            chunks.push(chunk);
        }
        chunks
    }

    fn take_complete_snapshot_chunks(
        ready_updates: &mut Vec<RenderUpdate>,
    ) -> Vec<Vec<RenderUpdate>> {
        let mut chunks = Vec::<Vec<RenderUpdate>>::new();
        let mut chunk = Vec::<RenderUpdate>::new();
        let mut chunk_bytes = 0_usize;
        for update in std::mem::take(ready_updates) {
            let update_bytes = serde_json::to_vec(&update).map_or(0, |encoded| encoded.len());
            if !chunk.is_empty()
                && (chunk.len() >= RENDER_SNAPSHOT_CHUNK_MAX_UPDATES
                    || chunk_bytes.saturating_add(update_bytes)
                        > RENDER_SNAPSHOT_CHUNK_TARGET_BYTES)
            {
                chunks.push(std::mem::take(&mut chunk));
                chunk_bytes = 0;
            }
            chunk_bytes = chunk_bytes.saturating_add(update_bytes);
            chunk.push(update);
            if chunk.len() >= RENDER_SNAPSHOT_CHUNK_MAX_UPDATES
                || (chunk.len() == 1 && chunk_bytes > RENDER_SNAPSHOT_CHUNK_TARGET_BYTES)
            {
                chunks.push(std::mem::take(&mut chunk));
                chunk_bytes = 0;
            }
        }
        *ready_updates = chunk;
        chunks
    }

    fn emit_snapshot_chunks(
        &self,
        request_id: &str,
        session_id: &str,
        first_chunk_index: u32,
        mark_last: bool,
        updates: Vec<RenderUpdate>,
    ) {
        let chunks = Self::split_snapshot_updates(updates);
        self.emit_snapshot_chunk_batch(
            request_id,
            session_id,
            first_chunk_index,
            mark_last,
            chunks,
        );
    }

    fn emit_snapshot_chunk_batch(
        &self,
        request_id: &str,
        session_id: &str,
        first_chunk_index: u32,
        mark_last: bool,
        chunks: Vec<Vec<RenderUpdate>>,
    ) {
        let last_index = chunks.len().saturating_sub(1);
        for (offset, updates) in chunks.into_iter().enumerate() {
            self.sink.emit(RuntimeEvent::RenderSnapshotChunk {
                request_id: request_id.to_string(),
                session_id: session_id.to_string(),
                chunk_index: first_chunk_index
                    .saturating_add(u32::try_from(offset).unwrap_or(u32::MAX)),
                is_last: mark_last && offset == last_index,
                updates,
            });
        }
    }
}

fn render_tool_call_id(update: &RenderUpdate) -> Option<&str> {
    update.metadata.as_ref()?.get("toolCallId")?.as_str()
}

fn merge_render_metadata(
    existing: &mut Option<serde_json::Value>,
    update: Option<&serde_json::Value>,
) {
    let Some(update) = update.and_then(serde_json::Value::as_object) else {
        return;
    };
    let existing = existing.get_or_insert_with(|| serde_json::json!({}));
    let Some(existing) = existing.as_object_mut() else {
        return;
    };
    for (key, value) in update {
        if !value.is_null() {
            existing.insert(key.clone(), value.clone());
        }
    }
}

fn merge_content_block_metadata(
    existing: &mut Option<serde_json::Value>,
    update: Option<&serde_json::Value>,
) {
    let Some(update_blocks) = update
        .and_then(|value| value.get("contentBlocks"))
        .and_then(serde_json::Value::as_array)
    else {
        return;
    };
    let existing = existing.get_or_insert_with(|| serde_json::json!({"contentBlocks": []}));
    let Some(existing) = existing.as_object_mut() else {
        return;
    };
    let blocks = existing
        .entry("contentBlocks")
        .or_insert_with(|| serde_json::Value::Array(Vec::new()));
    if let Some(blocks) = blocks.as_array_mut() {
        blocks.extend(update_blocks.iter().cloned());
    }
}

/// Thread-safe command handle plus a single-consumer event queue.
///
/// The worker owns a current-thread Tokio runtime and the ACP subprocess. No
/// Flutter lifecycle object owns protocol or session state.
pub struct RuntimeHandle {
    command_sender: Option<tokio_mpsc::Sender<RuntimeCommand>>,
    events: Option<EventReceiver>,
    worker: Option<JoinHandle<()>>,
}

impl std::fmt::Debug for RuntimeHandle {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("RuntimeHandle")
            .finish_non_exhaustive()
    }
}

impl Default for RuntimeHandle {
    fn default() -> Self {
        Self::new()
    }
}

impl RuntimeHandle {
    #[must_use]
    pub fn new() -> Self {
        let (command_sender, command_receiver) = tokio_mpsc::channel(COMMAND_CAPACITY);
        let (event_sender, event_receiver) = mpsc::sync_channel(EVENT_CAPACITY);
        let event_budget = Arc::new(EventQueueBudget::new(EVENT_RETAINED_BYTES_MAX));
        let sink = EventSink {
            sender: event_sender,
            budget: Arc::clone(&event_budget),
            next_sequence: Arc::new(Mutex::new(1)),
        };
        let events = EventReceiver {
            receiver: event_receiver,
            budget: event_budget,
        };
        let worker = thread::Builder::new()
            .name("ianvs-acp-runtime".to_string())
            .spawn(move || {
                let runtime = tokio::runtime::Builder::new_current_thread()
                    .enable_all()
                    .build();
                match runtime {
                    Ok(runtime) => runtime.block_on(runtime_main(command_receiver, sink)),
                    Err(error) => {
                        // No receiver-independent recovery exists when the async
                        // runtime itself cannot be constructed.
                        eprintln!("failed to construct ianvs ACP runtime: {error}");
                    }
                }
            })
            .expect("failed to spawn ianvs ACP runtime worker");
        Self {
            command_sender: Some(command_sender),
            events: Some(events),
            worker: Some(worker),
        }
    }

    pub fn start_agent(&self, config: AgentLaunchConfig) -> Result<(), RuntimeError> {
        self.send(RuntimeCommand::StartAgent(Box::new(config)))
    }

    pub fn create_session(
        &self,
        request_id: impl Into<String>,
        cwd: impl Into<String>,
        additional_directories: Vec<String>,
    ) -> Result<(), RuntimeError> {
        let request_id = checked_request_id(request_id.into())?;
        self.send(RuntimeCommand::CreateSession {
            request_id,
            cwd: cwd.into(),
            additional_directories,
        })
    }

    pub fn restore_session(
        &self,
        request_id: impl Into<String>,
        session_id: impl Into<String>,
        cwd: impl Into<String>,
        additional_directories: Vec<String>,
        replay_history: bool,
    ) -> Result<(), RuntimeError> {
        self.send(RuntimeCommand::RestoreSession {
            request_id: checked_request_id(request_id.into())?,
            session_id: checked_session_id(session_id.into())?,
            cwd: cwd.into(),
            additional_directories,
            replay_history,
        })
    }

    pub fn list_sessions(&self, request_id: impl Into<String>) -> Result<(), RuntimeError> {
        self.send(RuntimeCommand::ListSessions {
            request_id: checked_request_id(request_id.into())?,
        })
    }

    pub fn close_session(
        &self,
        request_id: impl Into<String>,
        session_id: impl Into<String>,
    ) -> Result<(), RuntimeError> {
        self.send(RuntimeCommand::CloseSession {
            request_id: checked_request_id(request_id.into())?,
            session_id: checked_session_id(session_id.into())?,
        })
    }

    pub fn delete_session(
        &self,
        request_id: impl Into<String>,
        session_id: impl Into<String>,
    ) -> Result<(), RuntimeError> {
        self.send(RuntimeCommand::DeleteSession {
            request_id: checked_request_id(request_id.into())?,
            session_id: checked_session_id(session_id.into())?,
        })
    }

    pub fn authenticate(
        &self,
        request_id: impl Into<String>,
        method_id: impl Into<String>,
    ) -> Result<(), RuntimeError> {
        self.send(RuntimeCommand::Authenticate {
            request_id: checked_request_id(request_id.into())?,
            method_id: checked_auth_method_id(method_id.into())?,
        })
    }

    pub fn logout(&self, request_id: impl Into<String>) -> Result<(), RuntimeError> {
        self.send(RuntimeCommand::Logout {
            request_id: checked_request_id(request_id.into())?,
        })
    }

    pub fn prompt(
        &self,
        request_id: impl Into<String>,
        session_id: impl Into<String>,
        text: impl Into<String>,
    ) -> Result<(), RuntimeError> {
        self.prompt_with_attachments(request_id, session_id, text, Vec::new())
    }

    pub fn prompt_with_attachments(
        &self,
        request_id: impl Into<String>,
        session_id: impl Into<String>,
        text: impl Into<String>,
        attachments: Vec<PromptAttachmentInput>,
    ) -> Result<(), RuntimeError> {
        let request_id = checked_request_id(request_id.into())?;
        let session_id = checked_session_id(session_id.into())?;
        self.send(RuntimeCommand::Prompt {
            request_id,
            session_id,
            text: text.into(),
            attachments,
        })
    }

    pub fn cancel(
        &self,
        request_id: impl Into<String>,
        session_id: impl Into<String>,
    ) -> Result<(), RuntimeError> {
        let request_id = checked_request_id(request_id.into())?;
        let session_id = checked_session_id(session_id.into())?;
        self.send(RuntimeCommand::Cancel {
            request_id,
            session_id,
        })
    }

    pub fn respond_permission(
        &self,
        request_id: impl Into<String>,
        decision: PermissionDecision,
    ) -> Result<(), RuntimeError> {
        let request_id = checked_request_id(request_id.into())?;
        self.send(RuntimeCommand::RespondPermission {
            request_id,
            decision,
        })
    }

    pub fn set_mode(
        &self,
        request_id: impl Into<String>,
        session_id: impl Into<String>,
        mode_id: impl Into<String>,
    ) -> Result<(), RuntimeError> {
        let request_id = checked_request_id(request_id.into())?;
        let session_id = checked_session_id(session_id.into())?;
        self.send(RuntimeCommand::SetMode {
            request_id,
            session_id,
            mode_id: mode_id.into(),
        })
    }

    pub fn set_config_option(
        &self,
        request_id: impl Into<String>,
        session_id: impl Into<String>,
        config_id: impl Into<String>,
        value: SessionConfigValueProjection,
    ) -> Result<(), RuntimeError> {
        self.send(RuntimeCommand::SetConfigOption {
            request_id: checked_request_id(request_id.into())?,
            session_id: checked_session_id(session_id.into())?,
            config_id: checked_config_id(config_id.into())?,
            value,
        })
    }

    pub fn dispose(&self) -> Result<(), RuntimeError> {
        self.send(RuntimeCommand::Dispose)
    }

    /// Non-blocking event receive for UI frame polling.
    pub fn try_recv_event(&self) -> Result<Option<RuntimeEventEnvelope>, RuntimeError> {
        let Some(events) = self.events.as_ref() else {
            return Err(RuntimeError::Closed);
        };
        match events.try_recv() {
            Ok(event) => Ok(Some(event)),
            Err(TryRecvError::Empty) => Ok(None),
            Err(TryRecvError::Disconnected) => Err(RuntimeError::Closed),
        }
    }

    /// Bounded blocking receive for native hosts and integration tests.
    pub fn recv_event_timeout(
        &self,
        timeout: Duration,
    ) -> Result<Option<RuntimeEventEnvelope>, RuntimeError> {
        let Some(events) = self.events.as_ref() else {
            return Err(RuntimeError::Closed);
        };
        match events.recv_timeout(timeout) {
            Ok(event) => Ok(Some(event)),
            Err(RecvTimeoutError::Timeout) => Ok(None),
            Err(RecvTimeoutError::Disconnected) => Err(RuntimeError::Closed),
        }
    }

    pub fn join(mut self) -> Result<(), RuntimeError> {
        let _ = self.dispose();
        // Event producers intentionally use a blocking bounded queue for
        // backpressure. Disconnect the consumer before waiting for the worker
        // so a producer blocked on a full queue can observe shutdown and exit.
        self.events.take();
        // Closing the command channel is the fallback when the bounded queue
        // was too full to accept the explicit Dispose command.
        self.command_sender.take();
        if let Some(worker) = self.worker.take() {
            worker.join().map_err(|_| RuntimeError::WorkerPanicked)?;
        }
        Ok(())
    }

    fn send(&self, command: RuntimeCommand) -> Result<(), RuntimeError> {
        self.command_sender
            .as_ref()
            .ok_or(RuntimeError::Closed)?
            .try_send(command)
            .map_err(|error| match error {
                tokio_mpsc::error::TrySendError::Full(_) => RuntimeError::Backpressure,
                tokio_mpsc::error::TrySendError::Closed(_) => RuntimeError::Closed,
            })
    }
}

impl Drop for RuntimeHandle {
    fn drop(&mut self) {
        if let Some(command_sender) = self.command_sender.as_ref() {
            let _ = command_sender.try_send(RuntimeCommand::Dispose);
        }
    }
}

fn checked_request_id(value: String) -> Result<String, RuntimeError> {
    let trimmed = value.trim();
    if trimmed.is_empty()
        || trimmed.len() > HOST_REQUEST_ID_MAX_BYTES
        || trimmed.as_bytes().contains(&0)
    {
        Err(RuntimeError::InvalidRequestId)
    } else if trimmed.len() == value.len() {
        Ok(value)
    } else {
        Ok(trimmed.to_string())
    }
}

fn checked_session_id(value: String) -> Result<String, RuntimeError> {
    let trimmed = value.trim();
    if trimmed.is_empty() || trimmed.len() > SESSION_ID_MAX_BYTES || trimmed.as_bytes().contains(&0)
    {
        Err(RuntimeError::InvalidSessionId)
    } else if trimmed.len() == value.len() {
        Ok(value)
    } else {
        Ok(trimmed.to_string())
    }
}

fn checked_auth_method_id(value: String) -> Result<String, RuntimeError> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        Err(RuntimeError::InvalidAuthMethodId)
    } else if trimmed.len() == value.len() {
        Ok(value)
    } else {
        Ok(trimmed.to_string())
    }
}

fn checked_config_id(value: String) -> Result<String, RuntimeError> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        Err(RuntimeError::InvalidConfigId)
    } else if trimmed.len() == value.len() {
        Ok(value)
    } else {
        Ok(trimmed.to_string())
    }
}

#[allow(clippy::too_many_lines)]
async fn runtime_main(mut commands: tokio_mpsc::Receiver<RuntimeCommand>, sink: EventSink) {
    let mut state = RuntimeStateMachine::new();
    while let Some(command) = commands.recv().await {
        match command {
            RuntimeCommand::StartAgent(config) => {
                if let Err(error) = state.start_agent() {
                    sink.error(None, "invalid_runtime_state", error.to_string(), true);
                    continue;
                }
                if let Err(message) = config.validate() {
                    state.agent_failed();
                    sink.error(None, "invalid_agent_config", message, true);
                    continue;
                }
                sink.emit(RuntimeEvent::StatusChanged {
                    status: RuntimeStatus::Starting,
                    detail: Some(format!("Starting {}", config.agent_name)),
                    capabilities: None,
                });
                let mut session_registry = match SessionRecoveryRegistry::open(&config) {
                    Ok(registry) => registry,
                    Err(message) => {
                        state.agent_failed();
                        sink.emit(RuntimeEvent::StatusChanged {
                            status: RuntimeStatus::Failed,
                            detail: Some(message.clone()),
                            capabilities: None,
                        });
                        sink.error(None, "session_store_failed", message, false);
                        continue;
                    }
                };
                let max_restarts = config
                    .max_restart_attempts
                    .unwrap_or(DEFAULT_MAX_RESTART_ATTEMPTS);
                let restart_base_delay = config
                    .restart_base_delay_ms
                    .map_or(DEFAULT_RESTART_BASE_DELAY, Duration::from_millis);
                let mut restart_attempt = 0_u32;
                let mut recover_sessions = false;
                loop {
                    let outcome = run_agent(
                        &config,
                        &mut commands,
                        sink.clone(),
                        &mut state,
                        &mut session_registry,
                        recover_sessions,
                    )
                    .await;
                    let Err(message) = outcome.result else {
                        return;
                    };
                    state.agent_failed();
                    let can_restart = restart_attempt < max_restarts;
                    if !can_restart {
                        sink.emit(RuntimeEvent::StatusChanged {
                            status: RuntimeStatus::Failed,
                            detail: Some(message.clone()),
                            capabilities: None,
                        });
                        sink.error(None, "agent_runtime_failed", message, false);
                        return;
                    }
                    restart_attempt = restart_attempt.saturating_add(1);
                    if let Err(error) = state.begin_recovery() {
                        sink.error(None, "invalid_runtime_state", error.to_string(), false);
                        return;
                    }
                    recover_sessions = true;
                    let delay = restart_delay(restart_base_delay, restart_attempt);
                    let phase = if outcome.session_activity {
                        "after session activity; durable sessions will be restored"
                    } else {
                        "before session activity"
                    };
                    sink.emit(RuntimeEvent::StatusChanged {
                        status: RuntimeStatus::Recovering,
                        detail: Some(format!(
                            "Agent exited {phase}; restart {restart_attempt}/{max_restarts} in {} ms: {message}",
                            delay.as_millis()
                        )),
                        capabilities: None,
                    });
                    if !wait_for_restart(&mut commands, &sink, &mut state, delay).await {
                        return;
                    }
                }
            }
            RuntimeCommand::Dispose => {
                state.dispose();
                sink.emit(RuntimeEvent::StatusChanged {
                    status: RuntimeStatus::Disposed,
                    detail: None,
                    capabilities: None,
                });
                return;
            }
            _ => sink.error(
                None,
                "runtime_not_started",
                "startAgent must be called before runtime commands",
                true,
            ),
        }
    }
}

async fn wait_for_restart(
    commands: &mut tokio_mpsc::Receiver<RuntimeCommand>,
    sink: &EventSink,
    state: &mut RuntimeStateMachine,
    delay: Duration,
) -> bool {
    let sleep = tokio::time::sleep(delay);
    tokio::pin!(sleep);
    loop {
        tokio::select! {
            () = &mut sleep => return true,
            command = commands.recv() => match command {
                None | Some(RuntimeCommand::Dispose) => {
                    state.dispose();
                    sink.emit(RuntimeEvent::StatusChanged {
                        status: RuntimeStatus::Disposed,
                        detail: None,
                        capabilities: None,
                    });
                    return false;
                }
                Some(command) => sink.error(
                    command_request_id(&command),
                    "runtime_recovering",
                    "agent process is restarting; retry the operation after ready",
                    true,
                ),
            }
        }
    }
}

fn command_request_id(command: &RuntimeCommand) -> Option<String> {
    match command {
        RuntimeCommand::CreateSession { request_id, .. }
        | RuntimeCommand::RestoreSession { request_id, .. }
        | RuntimeCommand::ListSessions { request_id }
        | RuntimeCommand::CloseSession { request_id, .. }
        | RuntimeCommand::DeleteSession { request_id, .. }
        | RuntimeCommand::Authenticate { request_id, .. }
        | RuntimeCommand::Logout { request_id }
        | RuntimeCommand::Prompt { request_id, .. }
        | RuntimeCommand::Cancel { request_id, .. }
        | RuntimeCommand::RespondPermission { request_id, .. }
        | RuntimeCommand::SetMode { request_id, .. }
        | RuntimeCommand::SetConfigOption { request_id, .. } => Some(request_id.clone()),
        RuntimeCommand::StartAgent(_) | RuntimeCommand::Dispose => None,
    }
}

fn restart_delay(base: Duration, attempt: u32) -> Duration {
    let exponent = attempt.saturating_sub(1).min(31);
    base.saturating_mul(1_u32 << exponent)
}

#[allow(clippy::too_many_lines)]
async fn run_agent(
    config: &AgentLaunchConfig,
    commands: &mut tokio_mpsc::Receiver<RuntimeCommand>,
    sink: EventSink,
    state: &mut RuntimeStateMachine,
    session_registry: &mut SessionRecoveryRegistry,
    recover_sessions: bool,
) -> AgentRunOutcome {
    let pending_permissions: Arc<Mutex<HashMap<String, PendingPermission>>> =
        Arc::new(Mutex::new(HashMap::new()));
    let (internal_sender, internal_receiver) = tokio_mpsc::unbounded_channel();

    let terminal_manager = if config.enable_terminal_provider {
        let terminal_sink = sink.clone();
        match TerminalManager::new(config.terminal_config(), move |event| {
            terminal_sink.emit(project_terminal_runtime_event(event));
        }) {
            Ok(manager) => Some(Arc::new(manager)),
            Err(error) => {
                return AgentRunOutcome {
                    result: Err(error.to_string()),
                    session_activity: false,
                };
            }
        }
    } else {
        None
    };
    let filesystem_manager = (config.enable_filesystem_read_text_file
        || config.enable_filesystem_write_text_file)
        .then(|| {
            Arc::new(FilesystemManager::new(FilesystemConfig {
                read_text_file: config.enable_filesystem_read_text_file,
                write_text_file: config.enable_filesystem_write_text_file,
            }))
        });

    let permission_sink = sink.clone();
    let permission_pending = Arc::clone(&pending_permissions);
    let permission_internal = internal_sender.clone();
    let permission_timeout = config
        .permission_timeout_ms
        .map_or(DEFAULT_PERMISSION_TIMEOUT, Duration::from_millis);
    let notification_sink = sink.clone();
    let render_router = RenderRouter::new(sink.clone());
    let notification_render_router = render_router.clone();
    let notification_internal = internal_sender.clone();
    let cleanup_pending = Arc::clone(&pending_permissions);
    let cleanup_sink = sink.clone();
    let session_activity = Arc::new(AtomicBool::new(false));
    let command_activity = Arc::clone(&session_activity);
    let create_terminal_manager = terminal_manager.clone();
    let output_terminal_manager = terminal_manager.clone();
    let release_terminal_manager = terminal_manager.clone();
    let kill_terminal_manager = terminal_manager.clone();
    let wait_terminal_manager = terminal_manager.clone();
    let terminal_pending = Arc::clone(&pending_permissions);
    let terminal_permission_sink = sink.clone();
    let terminal_internal = internal_sender.clone();
    let read_filesystem_manager = filesystem_manager.clone();
    let write_filesystem_manager = filesystem_manager.clone();
    let filesystem_pending = Arc::clone(&pending_permissions);
    let filesystem_write_pending = Arc::clone(&pending_permissions);
    let filesystem_permission_sink = sink.clone();
    let filesystem_write_permission_sink = sink.clone();
    let filesystem_internal = internal_sender.clone();
    let filesystem_write_internal = internal_sender.clone();

    let transport = LocalAgentTransport {
        config: config.clone(),
        sink: sink.clone(),
    };

    let result = agent_client_protocol::Client
        .builder()
        .name("ianvs-acp-core")
        .on_receive_notification(
            async move |notification: SessionNotification, _connection| {
                match project_session_notification(notification) {
                    Ok(Some(ProjectedSessionNotification::Render(updates))) => {
                        for update in updates {
                            notification_render_router.route(update);
                        }
                    }
                    Ok(Some(ProjectedSessionNotification::Control(update))) => {
                        notification_sink.emit(RuntimeEvent::SessionUpdate { update });
                    }
                    Ok(Some(ProjectedSessionNotification::Config {
                        session_id,
                        options,
                    })) => {
                        let _ = notification_internal.send(InternalEvent::ConfigNotified {
                            session_id,
                            options,
                        });
                    }
                    Ok(None) => {}
                    Err(message) => notification_sink.error(
                        None,
                        "invalid_session_notification",
                        message,
                        false,
                    ),
                }
                Ok(())
            },
            agent_client_protocol::on_receive_notification!(),
        )
        .on_receive_request(
            async move |request: RequestPermissionRequest,
                        responder: Responder<RequestPermissionResponse>,
                        _connection| {
                let request_id = Uuid::new_v4().to_string();
                let projection = match project_permission_request(&request_id, &request) {
                    Ok(projection) => projection,
                    Err(message) => {
                        return responder
                            .respond_with_error(AcpError::invalid_params().data(message));
                    }
                };
                let session_id = request.session_id.to_string();
                if let Err(error) = admit_pending_permission(
                    &permission_pending,
                    request_id.clone(),
                    PendingPermission::Acp {
                        session_id: session_id.clone(),
                        responder,
                    },
                ) {
                    return reject_unadmitted_permission(*error);
                }
                permission_sink.emit(RuntimeEvent::PermissionRequest {
                    request: projection,
                });
                let _ = permission_internal.send(InternalEvent::PermissionWaiting {
                    request_id: request_id.clone(),
                    session_id,
                });
                let timeout_sender = permission_internal.clone();
                std::mem::drop(tokio::spawn(async move {
                    tokio::time::sleep(permission_timeout).await;
                    let _ = timeout_sender.send(InternalEvent::PermissionTimedOut { request_id });
                }));
                Ok(())
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async move |request: ReadTextFileRequest,
                        responder: Responder<ReadTextFileResponse>,
                        _connection| {
                let Some(manager) = read_filesystem_manager.clone() else {
                    return responder.respond_with_error(filesystem_unavailable_error());
                };
                let approval = match manager.request_read(
                    &request.session_id.to_string(),
                    &request.path,
                    request.line,
                    request.limit,
                ) {
                    Ok(approval) => approval,
                    Err(error) => {
                        return responder.respond_with_error(filesystem_operation_error(&error));
                    }
                };
                let permission_projection = match project_filesystem_permission(&approval) {
                    Ok(projection) => projection,
                    Err(message) => {
                        let _ = manager.deny(&approval.approval_id);
                        return responder.respond_with_error(
                            AcpError::invalid_params().data(message),
                        );
                    }
                };
                let request_id = approval.approval_id.clone();
                let session_id = approval.session_id.clone();
                if let Err(error) = admit_pending_permission(
                    &filesystem_pending,
                    request_id.clone(),
                    PendingPermission::FilesystemRead {
                        session_id: session_id.clone(),
                        approval_id: approval.approval_id.clone(),
                        manager,
                        responder,
                    },
                ) {
                    return reject_unadmitted_permission(*error);
                }
                filesystem_permission_sink.emit(RuntimeEvent::PermissionRequest {
                    request: permission_projection,
                });
                let _ = filesystem_internal.send(InternalEvent::PermissionWaiting {
                    request_id: request_id.clone(),
                    session_id,
                });
                let timeout_sender = filesystem_internal.clone();
                std::mem::drop(tokio::spawn(async move {
                    tokio::time::sleep(permission_timeout).await;
                    let _ = timeout_sender.send(InternalEvent::PermissionTimedOut { request_id });
                }));
                Ok(())
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async move |request: WriteTextFileRequest,
                        responder: Responder<WriteTextFileResponse>,
                        _connection| {
                let Some(manager) = write_filesystem_manager.clone() else {
                    return responder.respond_with_error(filesystem_unavailable_error());
                };
                let approval = match manager.request_write(
                    &request.session_id.to_string(),
                    &request.path,
                    request.content,
                ) {
                    Ok(approval) => approval,
                    Err(error) => {
                        return responder.respond_with_error(filesystem_operation_error(&error));
                    }
                };
                let permission_projection = match project_filesystem_permission(&approval) {
                    Ok(projection) => projection,
                    Err(message) => {
                        let _ = manager.deny(&approval.approval_id);
                        return responder.respond_with_error(
                            AcpError::invalid_params().data(message),
                        );
                    }
                };
                let request_id = approval.approval_id.clone();
                let session_id = approval.session_id.clone();
                if let Err(error) = admit_pending_permission(
                    &filesystem_write_pending,
                    request_id.clone(),
                    PendingPermission::FilesystemWrite {
                        session_id: session_id.clone(),
                        approval_id: approval.approval_id.clone(),
                        manager,
                        responder,
                    },
                ) {
                    return reject_unadmitted_permission(*error);
                }
                filesystem_write_permission_sink.emit(RuntimeEvent::PermissionRequest {
                    request: permission_projection,
                });
                let _ = filesystem_write_internal.send(InternalEvent::PermissionWaiting {
                    request_id: request_id.clone(),
                    session_id,
                });
                let timeout_sender = filesystem_write_internal.clone();
                std::mem::drop(tokio::spawn(async move {
                    tokio::time::sleep(permission_timeout).await;
                    let _ = timeout_sender.send(InternalEvent::PermissionTimedOut { request_id });
                }));
                Ok(())
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async move |request: CreateTerminalRequest,
                        responder: Responder<CreateTerminalResponse>,
                        _connection| {
                let Some(manager) = create_terminal_manager.clone() else {
                    return responder.respond_with_error(terminal_unavailable_error());
                };
                let spec = TerminalCreateSpec {
                    session_id: request.session_id.to_string(),
                    command: request.command,
                    args: request.args,
                    environment: request
                        .env
                        .into_iter()
                        .map(|variable| TerminalEnvironmentVariable {
                            name: variable.name,
                            value: variable.value,
                        })
                        .collect(),
                    cwd: request.cwd,
                    output_byte_limit: request.output_byte_limit,
                };
                let approval = match manager.request_create(spec) {
                    Ok(approval) => approval,
                    Err(error) => {
                        return responder.respond_with_error(terminal_operation_error(&error));
                    }
                };
                let permission_projection = match project_terminal_permission(&approval) {
                    Ok(projection) => projection,
                    Err(message) => {
                        let _ = manager.deny_create(&approval.approval_id);
                        return responder.respond_with_error(
                            AcpError::invalid_params().data(message),
                        );
                    }
                };
                let request_id = approval.approval_id.clone();
                let session_id = approval.session_id.clone();
                if let Err(error) = admit_pending_permission(
                    &terminal_pending,
                    request_id.clone(),
                    PendingPermission::Terminal {
                        session_id: session_id.clone(),
                        approval_id: approval.approval_id.clone(),
                        manager,
                        responder,
                    },
                ) {
                    return reject_unadmitted_permission(*error);
                }
                terminal_permission_sink.emit(RuntimeEvent::PermissionRequest {
                    request: permission_projection,
                });
                let _ = terminal_internal.send(InternalEvent::PermissionWaiting {
                    request_id: request_id.clone(),
                    session_id,
                });
                let timeout_sender = terminal_internal.clone();
                std::mem::drop(tokio::spawn(async move {
                    tokio::time::sleep(permission_timeout).await;
                    let _ = timeout_sender.send(InternalEvent::PermissionTimedOut { request_id });
                }));
                Ok(())
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async move |request: TerminalOutputRequest,
                        responder: Responder<TerminalOutputResponse>,
                        _connection| {
                let Some(manager) = output_terminal_manager.as_ref() else {
                    return responder.respond_with_error(terminal_unavailable_error());
                };
                match manager.output(
                    &request.session_id.to_string(),
                    &request.terminal_id.to_string(),
                ) {
                    Ok(snapshot) => responder.respond(
                        TerminalOutputResponse::new(snapshot.output, snapshot.truncated)
                            .exit_status(snapshot.exit.map(terminal_exit_status)),
                    ),
                    Err(error) => responder.respond_with_error(terminal_operation_error(&error)),
                }
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async move |request: ReleaseTerminalRequest,
                        responder: Responder<ReleaseTerminalResponse>,
                        _connection| {
                let Some(manager) = release_terminal_manager.as_ref() else {
                    return responder.respond_with_error(terminal_unavailable_error());
                };
                match manager.release(
                    &request.session_id.to_string(),
                    &request.terminal_id.to_string(),
                ) {
                    Ok(()) => responder.respond(ReleaseTerminalResponse::new()),
                    Err(error) => responder.respond_with_error(terminal_operation_error(&error)),
                }
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async move |request: KillTerminalRequest,
                        responder: Responder<KillTerminalResponse>,
                        _connection| {
                let Some(manager) = kill_terminal_manager.as_ref() else {
                    return responder.respond_with_error(terminal_unavailable_error());
                };
                match manager.kill(
                    &request.session_id.to_string(),
                    &request.terminal_id.to_string(),
                ) {
                    Ok(()) => responder.respond(KillTerminalResponse::new()),
                    Err(error) => responder.respond_with_error(terminal_operation_error(&error)),
                }
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async move |request: WaitForTerminalExitRequest,
                        responder: Responder<WaitForTerminalExitResponse>,
                        connection| {
                let Some(manager) = wait_terminal_manager.clone() else {
                    return responder.respond_with_error(terminal_unavailable_error());
                };
                let session_id = request.session_id.to_string();
                let terminal_id = request.terminal_id.to_string();
                connection.spawn(async move {
                    match manager.wait_for_exit(&session_id, &terminal_id).await {
                        Ok(exit) => responder
                            .respond(WaitForTerminalExitResponse::new(terminal_exit_status(exit))),
                        Err(error) => {
                            responder.respond_with_error(terminal_operation_error(&error))
                        }
                    }
                })?;
                Ok(())
            },
            agent_client_protocol::on_receive_request!(),
        )
        .connect_with(
            transport,
            move |connection: ConnectionTo<Agent>| async move {
                let initialize = InitializeRequest::new(ProtocolVersion::V1)
                    .client_capabilities(
                        ClientCapabilities::new()
                            .fs(FileSystemCapabilities::new()
                                .read_text_file(config.enable_filesystem_read_text_file)
                                .write_text_file(config.enable_filesystem_write_text_file))
                            .terminal(config.enable_terminal_provider),
                    )
                    .client_info(agent_client_protocol::schema::v1::Implementation::new(
                        "ianvs-acp-core",
                        env!("CARGO_PKG_VERSION"),
                    ));
                let response = connection.send_request(initialize).block_task().await?;
                if response.protocol_version != ProtocolVersion::V1 {
                    return Err(AcpError::new(
                        -32603,
                        format!(
                            "agent selected unsupported ACP protocol version {:?}",
                            response.protocol_version
                        ),
                    ));
                }
                let session_support = session_support(&response.agent_capabilities);
                let prompt_support = PromptSupport::from_agent(&response.agent_capabilities);
                let mcp_servers = project_mcp_servers(
                    &config.mcp_servers,
                    &response.agent_capabilities.mcp_capabilities,
                )
                .map_err(|message| AcpError::new(-32603, message))?;
                let auth_methods = project_auth_methods(&response.auth_methods)
                    .map_err(|message| AcpError::new(-32603, message))?;
                let auth_method_ids = auth_methods
                    .iter()
                    .map(|method| method.id.clone())
                    .collect::<HashSet<_>>();
                let logout_supported = response.agent_capabilities.auth.logout.is_some();
                let capabilities = capability_projection(
                    &response.agent_capabilities,
                    session_support,
                    auth_methods,
                    config.enable_filesystem_read_text_file,
                    config.enable_filesystem_write_text_file,
                    config.enable_terminal_provider,
                );
                let mut detail = response.agent_info.as_ref().map_or_else(
                    || format!("{} ready", config.agent_name),
                    |info| format!("{} {} ready", info.name, info.version),
                );
                detail = bounded_protocol_text(
                    &detail,
                    "agent ready detail",
                    INITIALIZE_DETAIL_MAX_BYTES,
                    false,
                )
                .map_err(|message| AcpError::new(-32603, message))?;
                let ready_projection = RuntimeEvent::StatusChanged {
                    status: RuntimeStatus::Ready,
                    detail: Some(detail.clone()),
                    capabilities: Some(capabilities.clone()),
                };
                let ready_projection_bytes = serde_json::to_vec(&ready_projection)
                    .map_err(|error| AcpError::new(-32603, error.to_string()))?
                    .len();
                if ready_projection_bytes > INITIALIZE_MAX_PROJECTION_BYTES {
                    return Err(AcpError::new(
                        -32603,
                        format!(
                            "agent initialize projection exceeds {INITIALIZE_MAX_PROJECTION_BYTES} bytes"
                        ),
                    ));
                }
                if recover_sessions {
                    state
                        .reset_sessions_for_recovery()
                        .map_err(|error| AcpError::new(-32603, error.to_string()))?;
                }
                state
                    .agent_ready()
                    .map_err(|error| AcpError::new(-32603, error.to_string()))?;
                let recovered = if recover_sessions {
                    let recovered = recover_registered_sessions(
                        &connection,
                        session_registry,
                        session_support,
                        terminal_manager.as_ref(),
                        filesystem_manager.as_ref(),
                        &sink,
                        state,
                        &mcp_servers,
                        &render_router,
                    )
                    .await;
                    if !recovered.scopes.is_empty() {
                        command_activity.store(true, Ordering::Release);
                    }
                    recovered
                } else {
                    RecoveredRuntimeSessions::default()
                };
                if !recovered.failures.is_empty() {
                    let _ = write!(
                        detail,
                        "; {} persisted session(s) could not be recovered",
                        recovered.failures.len()
                    );
                }
                sink.emit(RuntimeEvent::StatusChanged {
                    status: RuntimeStatus::Ready,
                    detail: Some(detail),
                    capabilities: Some(capabilities),
                });
                for (session_id, message) in &recovered.failures {
                    sink.error(
                        Some(format!("recovery:{session_id}")),
                        "session_recovery_failed",
                        message.clone(),
                        true,
                    );
                }

                command_loop(
                    connection,
                    commands,
                    internal_receiver,
                    internal_sender,
                    pending_permissions,
                    sink,
                    state,
                    command_activity,
                    terminal_manager,
                    filesystem_manager,
                    session_support,
                    prompt_support,
                    auth_method_ids,
                    logout_supported,
                    session_registry,
                    recovered,
                    mcp_servers,
                    render_router,
                )
                .await
                .map_err(|message| AcpError::new(-32603, message))
            },
        )
        .await
        .map_err(|error| error.to_string());
    cancel_all_permissions(
        &cleanup_pending,
        &cleanup_sink,
        PermissionInvalidationReason::ConnectionClosed,
    );
    AgentRunOutcome {
        result,
        session_activity: session_activity.load(Ordering::Acquire),
    }
}

async fn restore_wire_session(
    connection: &ConnectionTo<Agent>,
    session: &PersistedSession,
    scope: &WorkspaceScope,
    support: SessionSupport,
    mcp_servers: &[AcpMcpServer],
) -> Result<RestoredSession, String> {
    if support.load {
        connection
            .send_request(
                LoadSessionRequest::new(session.session_id.clone(), scope.cwd().to_path_buf())
                    .additional_directories(scope.roots()[1..].to_vec())
                    .mcp_servers(mcp_servers.to_vec()),
            )
            .block_task()
            .await
            .map_err(|error| error.to_string())
            .and_then(|response| {
                Ok(RestoredSession {
                    session_id: session.session_id.clone(),
                    modes: response
                        .modes
                        .as_ref()
                        .map(project_session_modes)
                        .transpose()?,
                    replayed_history: true,
                    config_options: project_session_config_options(
                        response.config_options.as_deref(),
                    )?,
                })
            })
    } else if support.resume {
        connection
            .send_request(
                ResumeSessionRequest::new(session.session_id.clone(), scope.cwd().to_path_buf())
                    .additional_directories(scope.roots()[1..].to_vec())
                    .mcp_servers(mcp_servers.to_vec()),
            )
            .block_task()
            .await
            .map_err(|error| error.to_string())
            .and_then(|response| {
                Ok(RestoredSession {
                    session_id: session.session_id.clone(),
                    modes: response
                        .modes
                        .as_ref()
                        .map(project_session_modes)
                        .transpose()?,
                    replayed_history: false,
                    config_options: project_session_config_options(
                        response.config_options.as_deref(),
                    )?,
                })
            })
    } else {
        Err("agent supports neither session/load nor session/resume".to_string())
    }
}

#[allow(clippy::too_many_arguments)]
async fn recover_registered_sessions(
    connection: &ConnectionTo<Agent>,
    registry: &SessionRecoveryRegistry,
    support: SessionSupport,
    terminal_manager: Option<&Arc<TerminalManager>>,
    filesystem_manager: Option<&Arc<FilesystemManager>>,
    sink: &EventSink,
    state: &mut RuntimeStateMachine,
    mcp_servers: &[AcpMcpServer],
    render_router: &RenderRouter,
) -> RecoveredRuntimeSessions {
    let sessions = registry.sessions();
    let mut recovered = RecoveredRuntimeSessions::default();
    for session in sessions {
        let scope = match session.scope() {
            Ok(scope) => scope,
            Err(error) => {
                recovered
                    .failures
                    .push((session.session_id.clone(), error.to_string()));
                continue;
            }
        };
        let recovery_request_id = format!("recovery:{}", session.session_id);
        if support.load {
            render_router
                .begin_recovery_replay(session.session_id.clone(), recovery_request_id.clone());
        }
        let restored =
            match restore_wire_session(connection, &session, &scope, support, mcp_servers).await {
                Ok(restored) => restored,
                Err(error) => {
                    render_router.abort_replay(&recovery_request_id);
                    recovered.failures.push((session.session_id.clone(), error));
                    continue;
                }
            };
        // Recovery re-establishes protocol state; the existing UI transcript
        // remains authoritative. Never transfer a replay with no foreground
        // restore consumer.
        render_router.abort_replay(&recovery_request_id);
        if let Err(error) = state.session_created(restored.session_id.clone()) {
            recovered
                .failures
                .push((session.session_id.clone(), error.to_string()));
            continue;
        }
        if let Err(error) = register_session_managers(
            terminal_manager,
            filesystem_manager,
            &restored.session_id,
            &scope,
        ) {
            state.forget_session(&restored.session_id);
            recovered.failures.push((session.session_id.clone(), error));
            continue;
        }
        recovered
            .scopes
            .insert(restored.session_id.clone(), scope.clone());
        recovered
            .config_options
            .insert(restored.session_id.clone(), restored.config_options.clone());
        sink.emit(RuntimeEvent::SessionUpdate {
            update: SessionUpdate {
                session_id: restored.session_id,
                kind: SessionUpdateKind::SessionRestored,
                text: None,
                request_id: None,
                payload: Some(serde_json::json!({
                    "cwd": scope.cwd().display().to_string(),
                    "additionalDirectories": scope.roots()[1..]
                        .iter()
                        .map(|path| path.display().to_string())
                        .collect::<Vec<_>>(),
                    "modes": restored.modes,
                    "replayedHistory": restored.replayed_history,
                    "configOptions": restored.config_options,
                    "recoveredAfterRestart": true,
                })),
            },
        });
    }
    recovered
}

fn register_session_managers(
    terminal_manager: Option<&Arc<TerminalManager>>,
    filesystem_manager: Option<&Arc<FilesystemManager>>,
    session_id: &str,
    scope: &WorkspaceScope,
) -> Result<(), String> {
    if let Some(manager) = terminal_manager {
        manager
            .register_session(session_id, scope.clone())
            .map_err(|error| error.to_string())?;
    }
    if let Some(manager) = filesystem_manager
        && let Err(error) = manager.register_session(session_id, scope.clone())
    {
        if let Some(terminal) = terminal_manager {
            let _ = terminal.close_session(session_id);
        }
        return Err(error.to_string());
    }
    Ok(())
}

#[allow(clippy::too_many_arguments, clippy::too_many_lines)]
async fn command_loop(
    connection: ConnectionTo<Agent>,
    commands: &mut tokio_mpsc::Receiver<RuntimeCommand>,
    mut internal_events: tokio_mpsc::UnboundedReceiver<InternalEvent>,
    internal_sender: tokio_mpsc::UnboundedSender<InternalEvent>,
    pending_permissions: Arc<Mutex<HashMap<String, PendingPermission>>>,
    sink: EventSink,
    state: &mut RuntimeStateMachine,
    session_activity: Arc<AtomicBool>,
    terminal_manager: Option<Arc<TerminalManager>>,
    filesystem_manager: Option<Arc<FilesystemManager>>,
    session_support: SessionSupport,
    prompt_support: PromptSupport,
    auth_method_ids: HashSet<String>,
    logout_supported: bool,
    session_registry: &mut SessionRecoveryRegistry,
    recovered: RecoveredRuntimeSessions,
    mcp_servers: Vec<AcpMcpServer>,
    render_router: RenderRouter,
) -> Result<(), String> {
    let mut scopes = recovered.scopes;
    let mut config_options_by_session = recovered.config_options;
    let mut config_mutations = HashSet::<String>::new();
    let mut pending_session_creates = 0_usize;
    let mut pending_session_restores = HashMap::<String, usize>::new();
    let mut staged_config_notifications =
        HashMap::<String, (Vec<SessionConfigOptionProjection>, usize)>::new();
    let mut staged_config_bytes = 0_usize;
    loop {
        tokio::select! {
            command = commands.recv() => {
                let Some(command) = command else {
                    cancel_all_permissions(
                        &pending_permissions,
                        &sink,
                        PermissionInvalidationReason::Disposed,
                    );
                    state.dispose();
                    return Ok(());
                };
                match command {
                    RuntimeCommand::StartAgent(_) => sink.error(
                        None,
                        "runtime_already_started",
                        "this runtime handle already owns an agent process",
                        true,
                    ),
                    RuntimeCommand::CreateSession { request_id, cwd, additional_directories } => {
                        session_activity.store(true, Ordering::Release);
                        if let Err(error) = state.begin_session() {
                            sink.error(Some(request_id), "invalid_runtime_state", error.to_string(), true);
                            continue;
                        }
                        let scope = match WorkspaceScope::new(&cwd, &additional_directories) {
                            Ok(scope) => scope,
                            Err(error) => {
                                sink.error(Some(request_id), "invalid_workspace", error.to_string(), true);
                                continue;
                            }
                        };
                        let request = NewSessionRequest::new(scope.cwd().to_path_buf())
                            .additional_directories(scope.roots()[1..].to_vec())
                            .mcp_servers(mcp_servers.clone());
                        pending_session_creates = pending_session_creates.saturating_add(1);
                        let sent = connection.send_request(request);
                        let tx = internal_sender.clone();
                        connection.spawn(async move {
                            let result = sent.block_task().await
                                .map_err(|error| error.to_string())
                                .and_then(|response| project_created_session(&response));
                            let _ = tx.send(InternalEvent::SessionCreated {
                                request_id,
                                cwd,
                                scope,
                                result,
                            });
                            Ok(())
                        }).map_err(|error| error.to_string())?;
                    }
                    RuntimeCommand::RestoreSession {
                        request_id,
                        session_id,
                        cwd,
                        additional_directories,
                        replay_history,
                    } => {
                        if !session_support.load && !session_support.resume {
                            sink.error(
                                Some(request_id),
                                "unsupported_session_restore",
                                "agent supports neither session/load nor session/resume",
                                true,
                            );
                            continue;
                        }
                        session_activity.store(true, Ordering::Release);
                        if let Err(error) = state.begin_session() {
                            sink.error(Some(request_id), "invalid_runtime_state", error.to_string(), true);
                            continue;
                        }
                        if state.session_status(&session_id).is_some() {
                            sink.error(
                                Some(request_id),
                                "duplicate_session",
                                format!("session already exists: {session_id}"),
                                true,
                            );
                            continue;
                        }
                        let scope = match WorkspaceScope::new(&cwd, &additional_directories) {
                            Ok(scope) => scope,
                            Err(error) => {
                                sink.error(Some(request_id), "invalid_workspace", error.to_string(), true);
                                continue;
                            }
                        };
                        let tx = internal_sender.clone();
                        let agent = connection.clone();
                        let requested_session_id = session_id.clone();
                        let request_scope = scope.clone();
                        let restore_mcp_servers = mcp_servers.clone();
                        let will_replay_history =
                            (replay_history && session_support.load) || !session_support.resume;
                        if will_replay_history {
                            render_router.begin_replay(session_id.clone(), request_id.clone());
                        }
                        *pending_session_restores.entry(session_id.clone()).or_default() += 1;
                        connection.spawn(async move {
                            let result = if replay_history && session_support.load {
                                agent
                                    .send_request(
                                        LoadSessionRequest::new(
                                            requested_session_id.clone(),
                                            request_scope.cwd().to_path_buf(),
                                        )
                                        .additional_directories(request_scope.roots()[1..].to_vec())
                                        .mcp_servers(restore_mcp_servers.clone()),
                                    )
                                    .block_task()
                                    .await
                                    .map_err(|error| error.to_string())
                                    .and_then(|response| Ok(RestoredSession {
                                        session_id: requested_session_id.clone(),
                                        modes: response
                                            .modes
                                            .as_ref()
                                            .map(project_session_modes)
                                            .transpose()?,
                                        replayed_history: true,
                                        config_options: project_session_config_options(
                                            response.config_options.as_deref(),
                                        )?,
                                    }))
                            } else if session_support.resume {
                                agent
                                    .send_request(
                                        ResumeSessionRequest::new(
                                            requested_session_id.clone(),
                                            request_scope.cwd().to_path_buf(),
                                        )
                                        .additional_directories(request_scope.roots()[1..].to_vec())
                                        .mcp_servers(restore_mcp_servers),
                                    )
                                    .block_task()
                                    .await
                                    .map_err(|error| error.to_string())
                                    .and_then(|response| Ok(RestoredSession {
                                        session_id: requested_session_id.clone(),
                                        modes: response
                                            .modes
                                            .as_ref()
                                            .map(project_session_modes)
                                            .transpose()?,
                                        replayed_history: false,
                                        config_options: project_session_config_options(
                                            response.config_options.as_deref(),
                                        )?,
                                    }))
                            } else {
                                agent
                                    .send_request(
                                        LoadSessionRequest::new(
                                            requested_session_id.clone(),
                                            request_scope.cwd().to_path_buf(),
                                        )
                                        .additional_directories(request_scope.roots()[1..].to_vec())
                                        .mcp_servers(restore_mcp_servers),
                                    )
                                    .block_task()
                                    .await
                                    .map_err(|error| error.to_string())
                                    .and_then(|response| Ok(RestoredSession {
                                        session_id: requested_session_id.clone(),
                                        modes: response
                                            .modes
                                            .as_ref()
                                            .map(project_session_modes)
                                            .transpose()?,
                                        replayed_history: true,
                                        config_options: project_session_config_options(
                                            response.config_options.as_deref(),
                                        )?,
                                    }))
                            };
                            let _ = tx.send(InternalEvent::SessionRestored {
                                request_id,
                                requested_session_id,
                                cwd,
                                scope,
                                result,
                            });
                            Ok(())
                        }).map_err(|error| error.to_string())?;
                    }
                    RuntimeCommand::ListSessions { request_id } => {
                        if !session_support.list {
                            sink.error(
                                Some(request_id),
                                "unsupported_session_list",
                                "agent does not support session/list",
                                true,
                            );
                            continue;
                        }
                        let tx = internal_sender.clone();
                        let agent = connection.clone();
                        connection.spawn(async move {
                            let result = list_all_sessions(&agent).await;
                            let _ = tx.send(InternalEvent::SessionCataloged { request_id, result });
                            Ok(())
                        }).map_err(|error| error.to_string())?;
                    }
                    RuntimeCommand::CloseSession { request_id, session_id } => {
                        if !session_support.close {
                            sink.error(
                                Some(request_id),
                                "unsupported_session_close",
                                "agent does not support session/close",
                                true,
                            );
                            continue;
                        }
                        if state.session_status(&session_id).is_none() {
                            sink.error(
                                Some(request_id),
                                "unknown_session",
                                format!("unknown session: {session_id}"),
                                true,
                            );
                            continue;
                        }
                        let sent = connection.send_request(CloseSessionRequest::new(session_id.clone()));
                        let tx = internal_sender.clone();
                        connection.spawn(async move {
                            let result = sent.block_task().await
                                .map(|_| ())
                                .map_err(|error| error.to_string());
                            let _ = tx.send(InternalEvent::SessionClosed {
                                request_id,
                                session_id,
                                result,
                            });
                            Ok(())
                        }).map_err(|error| error.to_string())?;
                    }
                    RuntimeCommand::DeleteSession { request_id, session_id } => {
                        if !session_support.delete {
                            sink.error(
                                Some(request_id),
                                "unsupported_session_delete",
                                "agent does not support session/delete",
                                true,
                            );
                            continue;
                        }
                        let sent = connection.send_request(DeleteSessionRequest::new(session_id.clone()));
                        let tx = internal_sender.clone();
                        connection.spawn(async move {
                            let result = sent.block_task().await
                                .map(|_| ())
                                .map_err(|error| error.to_string());
                            let _ = tx.send(InternalEvent::SessionDeleted {
                                request_id,
                                session_id,
                                result,
                            });
                            Ok(())
                        }).map_err(|error| error.to_string())?;
                    }
                    RuntimeCommand::Authenticate { request_id, method_id } => {
                        if !auth_method_ids.contains(&method_id) {
                            sink.error(
                                Some(request_id),
                                "unknown_auth_method",
                                format!("agent did not advertise authentication method {method_id}"),
                                true,
                            );
                            continue;
                        }
                        let sent = connection.send_request(AuthenticateRequest::new(method_id.clone()));
                        let tx = internal_sender.clone();
                        connection.spawn(async move {
                            let result = sent.block_task().await
                                .map(|_| ())
                                .map_err(|error| error.to_string());
                            let _ = tx.send(InternalEvent::AuthenticationChanged {
                                request_id,
                                authenticated: true,
                                method_id: Some(method_id),
                                result,
                            });
                            Ok(())
                        }).map_err(|error| error.to_string())?;
                    }
                    RuntimeCommand::Logout { request_id } => {
                        if !logout_supported {
                            sink.error(
                                Some(request_id),
                                "unsupported_logout",
                                "agent does not support logout",
                                true,
                            );
                            continue;
                        }
                        let sent = connection.send_request(LogoutRequest::new());
                        let tx = internal_sender.clone();
                        connection.spawn(async move {
                            let result = sent.block_task().await
                                .map(|_| ())
                                .map_err(|error| error.to_string());
                            let _ = tx.send(InternalEvent::AuthenticationChanged {
                                request_id,
                                authenticated: false,
                                method_id: None,
                                result,
                            });
                            Ok(())
                        }).map_err(|error| error.to_string())?;
                    }
                    RuntimeCommand::Prompt {
                        request_id,
                        session_id,
                        text,
                        attachments,
                    } => {
                        let Some(scope) = scopes.get(&session_id) else {
                            sink.error(Some(request_id), "unknown_session", format!("unknown session: {session_id}"), true);
                            continue;
                        };
                        let content = match project_prompt_content(
                            &text,
                            &attachments,
                            scope,
                            prompt_support,
                        ) {
                            Ok(content) => content,
                            Err(message) => {
                                sink.error(
                                    Some(request_id),
                                    "invalid_prompt_attachment",
                                    message,
                                    true,
                                );
                                continue;
                            }
                        };
                        if let Err(error) = state.prompt_started(&session_id) {
                            sink.error(Some(request_id), "invalid_session_state", error.to_string(), true);
                            continue;
                        }
                        let request = PromptRequest::new(session_id.clone(), content);
                        let sent = connection.send_request(request);
                        let tx = internal_sender.clone();
                        connection.spawn(async move {
                            let result = sent.block_task().await
                                .map(|response| stop_reason_name(response.stop_reason).to_string())
                                .map_err(|error| error.to_string());
                            let _ = tx.send(InternalEvent::PromptFinished {
                                request_id,
                                session_id,
                                result,
                            });
                            Ok(())
                        }).map_err(|error| error.to_string())?;
                    }
                    RuntimeCommand::Cancel { request_id, session_id } => {
                        if let Err(error) = state.cancel_started(&session_id) {
                            sink.error(Some(request_id), "invalid_session_state", error.to_string(), true);
                            continue;
                        }
                        cancel_session_permissions(
                            &pending_permissions,
                            &sink,
                            &session_id,
                            PermissionInvalidationReason::PromptCancelled,
                        );
                        if let Err(error) = connection.send_notification(CancelNotification::new(session_id.clone())) {
                            sink.error(Some(request_id), "cancel_failed", error.to_string(), true);
                        }
                    }
                    RuntimeCommand::RespondPermission { request_id, decision } => {
                        let pending = pending_permissions
                            .lock()
                            .expect("permission mutex poisoned")
                            .remove(&request_id);
                        let Some(pending) = pending else {
                            sink.error(Some(request_id), "unknown_permission", "permission request is no longer pending", true);
                            continue;
                        };
                        let session_id = pending.session_id().to_string();
                        match pending {
                            PendingPermission::Acp { responder, .. } => {
                                let response = match decision {
                                    PermissionDecision::Selected { option_id } => RequestPermissionResponse::new(
                                        RequestPermissionOutcome::Selected(SelectedPermissionOutcome::new(option_id)),
                                    ),
                                    PermissionDecision::Cancelled => RequestPermissionResponse::new(
                                        RequestPermissionOutcome::Cancelled,
                                    ),
                                };
                                if let Err(error) = responder.respond(response) {
                                    sink.error(Some(request_id.clone()), "permission_response_failed", error.to_string(), true);
                                }
                            }
                            PendingPermission::Terminal {
                                approval_id,
                                manager,
                                responder,
                                ..
                            } => {
                                let allowed = matches!(
                                    &decision,
                                    PermissionDecision::Selected { option_id }
                                        if option_id == TERMINAL_ALLOW_ONCE_OPTION_ID
                                );
                                if allowed {
                                    match manager.approve_create(&approval_id) {
                                        Ok(terminal_id) => {
                                            if let Err(error) = responder.respond(CreateTerminalResponse::new(terminal_id)) {
                                                sink.error(Some(request_id.clone()), "permission_response_failed", error.to_string(), true);
                                            }
                                        }
                                        Err(error) => {
                                            let message = error.to_string();
                                            if let Err(response_error) = responder.respond_with_error(
                                                terminal_operation_error(&error),
                                            ) {
                                                sink.error(Some(request_id.clone()), "permission_response_failed", response_error.to_string(), true);
                                            }
                                            sink.error(Some(request_id.clone()), "terminal_create_failed", message, true);
                                        }
                                    }
                                } else {
                                    if let Err(error) = manager.deny_create(&approval_id) {
                                        sink.error(Some(request_id.clone()), "terminal_deny_failed", error.to_string(), true);
                                    }
                                    if let Err(error) = responder.respond_with_error(terminal_denied_error()) {
                                        sink.error(Some(request_id.clone()), "permission_response_failed", error.to_string(), true);
                                    }
                                }
                            }
                            PendingPermission::FilesystemRead {
                                approval_id,
                                manager,
                                responder,
                                ..
                            } => {
                                let allowed = matches!(
                                    &decision,
                                    PermissionDecision::Selected { option_id }
                                        if option_id == FILESYSTEM_ALLOW_ONCE_OPTION_ID
                                );
                                if allowed {
                                    match manager.approve(&approval_id) {
                                        Ok(FilesystemOperationResult::Read(content)) => {
                                            if let Err(error) = responder.respond(
                                                ReadTextFileResponse::new(content),
                                            ) {
                                                sink.error(Some(request_id.clone()), "permission_response_failed", error.to_string(), true);
                                            }
                                        }
                                        Ok(FilesystemOperationResult::Written) => {
                                            let error = "filesystem read approval returned a write result";
                                            let _ = responder.respond_with_error(filesystem_operation_error(&error));
                                            sink.error(Some(request_id.clone()), "filesystem_read_failed", error, true);
                                        }
                                        Err(error) => {
                                            let message = error.to_string();
                                            let _ = responder.respond_with_error(filesystem_operation_error(&error));
                                            sink.error(Some(request_id.clone()), "filesystem_read_failed", message, true);
                                        }
                                    }
                                } else {
                                    if let Err(error) = manager.deny(&approval_id) {
                                        sink.error(Some(request_id.clone()), "filesystem_deny_failed", error.to_string(), true);
                                    }
                                    if let Err(error) = responder.respond_with_error(filesystem_denied_error()) {
                                        sink.error(Some(request_id.clone()), "permission_response_failed", error.to_string(), true);
                                    }
                                }
                            }
                            PendingPermission::FilesystemWrite {
                                approval_id,
                                manager,
                                responder,
                                ..
                            } => {
                                let allowed = matches!(
                                    &decision,
                                    PermissionDecision::Selected { option_id }
                                        if option_id == FILESYSTEM_ALLOW_ONCE_OPTION_ID
                                );
                                if allowed {
                                    match manager.approve(&approval_id) {
                                        Ok(FilesystemOperationResult::Written) => {
                                            if let Err(error) = responder.respond(
                                                WriteTextFileResponse::new(),
                                            ) {
                                                sink.error(Some(request_id.clone()), "permission_response_failed", error.to_string(), true);
                                            }
                                        }
                                        Ok(FilesystemOperationResult::Read(_)) => {
                                            let error = "filesystem write approval returned a read result";
                                            let _ = responder.respond_with_error(filesystem_operation_error(&error));
                                            sink.error(Some(request_id.clone()), "filesystem_write_failed", error, true);
                                        }
                                        Err(error) => {
                                            let message = error.to_string();
                                            let _ = responder.respond_with_error(filesystem_operation_error(&error));
                                            sink.error(Some(request_id.clone()), "filesystem_write_failed", message, true);
                                        }
                                    }
                                } else {
                                    if let Err(error) = manager.deny(&approval_id) {
                                        sink.error(Some(request_id.clone()), "filesystem_deny_failed", error.to_string(), true);
                                    }
                                    if let Err(error) = responder.respond_with_error(filesystem_denied_error()) {
                                        sink.error(Some(request_id.clone()), "permission_response_failed", error.to_string(), true);
                                    }
                                }
                            }
                        }
                        if !has_pending_permission_for_session(&pending_permissions, &session_id)
                            && let Err(error) = state.permission_resolved(&session_id)
                        {
                            sink.error(None, "invalid_session_state", error.to_string(), true);
                        }
                    }
                    RuntimeCommand::SetMode { request_id, session_id, mode_id } => {
                        if state.session_status(&session_id).is_none() {
                            sink.error(Some(request_id), "unknown_session", format!("unknown session: {session_id}"), true);
                            continue;
                        }
                        let sent = connection.send_request(SetSessionModeRequest::new(
                            session_id.clone(),
                            mode_id.clone(),
                        ));
                        let tx = internal_sender.clone();
                        connection.spawn(async move {
                            let result = sent.block_task().await
                                .map(|_| ())
                                .map_err(|error| error.to_string());
                            let _ = tx.send(InternalEvent::ModeSet {
                                request_id,
                                session_id,
                                mode_id,
                                result,
                            });
                            Ok(())
                        }).map_err(|error| error.to_string())?;
                    }
                    RuntimeCommand::SetConfigOption {
                        request_id,
                        session_id,
                        config_id,
                        value,
                    } => {
                        if state.session_status(&session_id).is_none() {
                            sink.error(Some(request_id), "unknown_session", format!("unknown session: {session_id}"), true);
                            continue;
                        }
                        let Some(options) = config_options_by_session.get(&session_id) else {
                            sink.error(Some(request_id), "unknown_config_option", format!("session {session_id} has no config options"), true);
                            continue;
                        };
                        let Some(option) = options.iter().find(|option| option.id == config_id) else {
                            sink.error(Some(request_id), "unknown_config_option", format!("unknown session config option: {config_id}"), true);
                            continue;
                        };
                        let wire_value = match (option.option_type.as_str(), value) {
                            ("boolean", SessionConfigValueProjection::Boolean { value }) => {
                                SessionConfigOptionValue::boolean(value)
                            }
                            ("select", SessionConfigValueProjection::ValueId { value }) => {
                                let value = match canonical_protocol_text(&value, "session config value") {
                                    Ok(value) => value,
                                    Err(message) => {
                                        sink.error(Some(request_id), "invalid_config_value", message, true);
                                        continue;
                                    }
                                };
                                if !option.options.iter().any(|choice| choice.value == value) {
                                    sink.error(Some(request_id), "invalid_config_value", format!("session config {config_id} did not advertise value {value}"), true);
                                    continue;
                                }
                                SessionConfigOptionValue::value_id(value)
                            }
                            _ => {
                                sink.error(Some(request_id), "invalid_config_value", format!("value type does not match session config {config_id}"), true);
                                continue;
                            }
                        };
                        if !config_mutations.insert(session_id.clone()) {
                            sink.error(Some(request_id), "config_mutation_busy", format!("session {session_id} already has a config mutation in flight"), true);
                            continue;
                        }
                        let sent = connection.send_request(SetSessionConfigOptionRequest::new(
                            session_id.clone(),
                            config_id,
                            wire_value,
                        ));
                        let tx = internal_sender.clone();
                        connection.spawn(async move {
                            let result = sent.block_task().await
                                .map_err(|error| error.to_string())
                                .and_then(|response| {
                                    project_session_config_options(Some(&response.config_options))
                                });
                            let _ = tx.send(InternalEvent::ConfigSet {
                                request_id,
                                session_id,
                                result,
                            });
                            Ok(())
                        }).map_err(|error| error.to_string())?;
                    }
                    RuntimeCommand::Dispose => {
                        cancel_all_permissions(
                            &pending_permissions,
                            &sink,
                            PermissionInvalidationReason::Disposed,
                        );
                        state.dispose();
                        sink.emit(RuntimeEvent::StatusChanged {
                            status: RuntimeStatus::Disposed,
                            detail: None,
                            capabilities: None,
                        });
                        return Ok(());
                    }
                }
            }
            internal = internal_events.recv() => {
                let Some(internal) = internal else {
                    return Err("runtime internal event queue closed".to_string());
                };
                match internal {
                    InternalEvent::SessionCreated { request_id, cwd, scope, result } => {
                        pending_session_creates = pending_session_creates.saturating_sub(1);
                        match result {
                        Ok(created) => {
                            let session_id = created.session_id;
                            if let Err(error) = state.session_created(session_id.clone()) {
                                sink.error(Some(request_id), "invalid_session_state", error.to_string(), false);
                                drop_staged_config_notification(
                                    &mut staged_config_notifications,
                                    &mut staged_config_bytes,
                                    &session_id,
                                );
                                purge_orphaned_config_notifications(
                                    &mut staged_config_notifications,
                                    &mut staged_config_bytes,
                                    pending_session_creates,
                                    &pending_session_restores,
                                );
                                continue;
                            }
                            if let Err(message) = session_registry.activate(&session_id, &scope) {
                                state.forget_session(&session_id);
                                drop_staged_config_notification(
                                    &mut staged_config_notifications,
                                    &mut staged_config_bytes,
                                    &session_id,
                                );
                                sink.error(
                                    Some(request_id),
                                    "session_store_failed",
                                    message,
                                    false,
                                );
                                purge_orphaned_config_notifications(
                                    &mut staged_config_notifications,
                                    &mut staged_config_bytes,
                                    pending_session_creates,
                                    &pending_session_restores,
                                );
                                continue;
                            }
                            if let Err(message) = register_session_managers(
                                terminal_manager.as_ref(),
                                filesystem_manager.as_ref(),
                                &session_id,
                                &scope,
                            ) {
                                state.forget_session(&session_id);
                                drop_staged_config_notification(
                                    &mut staged_config_notifications,
                                    &mut staged_config_bytes,
                                    &session_id,
                                );
                                if let Err(cleanup) = session_registry.remove(&session_id) {
                                    sink.error(None, "session_store_failed", cleanup, false);
                                }
                                sink.error(
                                    Some(request_id),
                                    "session_registration_failed",
                                    message,
                                    false,
                                );
                                purge_orphaned_config_notifications(
                                    &mut staged_config_notifications,
                                    &mut staged_config_bytes,
                                    pending_session_creates,
                                    &pending_session_restores,
                                );
                                continue;
                            }
                            scopes.insert(session_id.clone(), scope);
                            config_options_by_session.insert(
                                session_id.clone(),
                                created.config_options.clone(),
                            );
                            sink.emit(RuntimeEvent::SessionUpdate {
                                update: SessionUpdate {
                                    session_id: session_id.clone(),
                                    kind: SessionUpdateKind::SessionCreated,
                                    text: None,
                                    request_id: Some(request_id),
                                    payload: Some(serde_json::json!({
                                        "cwd": cwd,
                                        "modes": created.modes,
                                        "configOptions": created.config_options,
                                    })),
                                },
                            });
                            if let Some((options, bytes)) =
                                staged_config_notifications.remove(&session_id)
                            {
                                staged_config_bytes = staged_config_bytes.saturating_sub(bytes);
                                config_options_by_session
                                    .insert(session_id.clone(), options.clone());
                                emit_config_changed(&sink, session_id, None, &options);
                            }
                        }
                        Err(message) => sink.error(Some(request_id), "create_session_failed", message, true),
                        }
                        purge_orphaned_config_notifications(
                            &mut staged_config_notifications,
                            &mut staged_config_bytes,
                            pending_session_creates,
                            &pending_session_restores,
                        );
                    }
                    InternalEvent::SessionRestored {
                        request_id,
                        requested_session_id,
                        cwd,
                        scope,
                        result,
                    } => {
                        decrement_pending_session_restore(
                            &mut pending_session_restores,
                            &requested_session_id,
                        );
                        match result {
                        Ok(restored) => {
                            let session_id = restored.session_id;
                            if let Err(error) = state.session_created(session_id.clone()) {
                                render_router.abort_replay(&request_id);
                                sink.error(Some(request_id), "invalid_session_state", error.to_string(), false);
                                drop_staged_config_notification(
                                    &mut staged_config_notifications,
                                    &mut staged_config_bytes,
                                    &session_id,
                                );
                                purge_orphaned_config_notifications(
                                    &mut staged_config_notifications,
                                    &mut staged_config_bytes,
                                    pending_session_creates,
                                    &pending_session_restores,
                                );
                                continue;
                            }
                            if let Err(message) = session_registry.activate(&session_id, &scope) {
                                state.forget_session(&session_id);
                                render_router.abort_replay(&request_id);
                                drop_staged_config_notification(
                                    &mut staged_config_notifications,
                                    &mut staged_config_bytes,
                                    &session_id,
                                );
                                sink.error(
                                    Some(request_id),
                                    "session_store_failed",
                                    message,
                                    false,
                                );
                                purge_orphaned_config_notifications(
                                    &mut staged_config_notifications,
                                    &mut staged_config_bytes,
                                    pending_session_creates,
                                    &pending_session_restores,
                                );
                                continue;
                            }
                            if let Err(message) = register_session_managers(
                                terminal_manager.as_ref(),
                                filesystem_manager.as_ref(),
                                &session_id,
                                &scope,
                            ) {
                                state.forget_session(&session_id);
                                render_router.abort_replay(&request_id);
                                drop_staged_config_notification(
                                    &mut staged_config_notifications,
                                    &mut staged_config_bytes,
                                    &session_id,
                                );
                                if let Err(cleanup) = session_registry.remove(&session_id) {
                                    sink.error(None, "session_store_failed", cleanup, false);
                                }
                                sink.error(
                                    Some(request_id),
                                    "session_registration_failed",
                                    message,
                                    false,
                                );
                                purge_orphaned_config_notifications(
                                    &mut staged_config_notifications,
                                    &mut staged_config_bytes,
                                    pending_session_creates,
                                    &pending_session_restores,
                                );
                                continue;
                            }
                            scopes.insert(session_id.clone(), scope);
                            config_options_by_session.insert(
                                session_id.clone(),
                                restored.config_options.clone(),
                            );
                            if restored.replayed_history {
                                render_router.finish_replay(&session_id, &request_id);
                            } else {
                                render_router.abort_replay(&request_id);
                            }
                            sink.emit(RuntimeEvent::SessionUpdate {
                                update: SessionUpdate {
                                    session_id: session_id.clone(),
                                    kind: SessionUpdateKind::SessionRestored,
                                    text: None,
                                    request_id: Some(request_id),
                                    payload: Some(serde_json::json!({
                                        "cwd": cwd,
                                        "modes": restored.modes,
                                        "replayedHistory": restored.replayed_history,
                                        "configOptions": restored.config_options,
                                    })),
                                },
                            });
                            if let Some((options, bytes)) =
                                staged_config_notifications.remove(&session_id)
                            {
                                staged_config_bytes = staged_config_bytes.saturating_sub(bytes);
                                config_options_by_session
                                    .insert(session_id.clone(), options.clone());
                                emit_config_changed(&sink, session_id, None, &options);
                            }
                        }
                        Err(message) => {
                            render_router.abort_replay(&request_id);
                            drop_staged_config_notification(
                                &mut staged_config_notifications,
                                &mut staged_config_bytes,
                                &requested_session_id,
                            );
                            sink.error(Some(request_id), "restore_session_failed", message, true);
                        }
                        }
                        purge_orphaned_config_notifications(
                            &mut staged_config_notifications,
                            &mut staged_config_bytes,
                            pending_session_creates,
                            &pending_session_restores,
                        );
                    }
                    InternalEvent::SessionCataloged { request_id, result } => match result {
                        Ok(sessions) => sink.emit(RuntimeEvent::SessionCatalog {
                            request_id,
                            sessions,
                        }),
                        Err(message) => sink.error(Some(request_id), "list_sessions_failed", message, true),
                    },
                    InternalEvent::SessionClosed { request_id, session_id, result } => match result {
                        Ok(()) => {
                            let persistence_error = session_registry.remove(&session_id).err();
                            cancel_session_permissions(
                                &pending_permissions,
                                &sink,
                                &session_id,
                                PermissionInvalidationReason::SessionClosed,
                            );
                            if let Some(manager) = terminal_manager.as_ref()
                                && let Err(error) = manager.close_session(&session_id)
                            {
                                sink.error(None, "terminal_session_close_failed", error.to_string(), false);
                            }
                            if let Some(manager) = filesystem_manager.as_ref()
                                && let Err(error) = manager.close_session(&session_id)
                            {
                                sink.error(None, "filesystem_session_close_failed", error.to_string(), false);
                            }
                            scopes.remove(&session_id);
                            config_options_by_session.remove(&session_id);
                            config_mutations.remove(&session_id);
                            if let Err(error) = state.close_session(&session_id) {
                                sink.error(Some(request_id), "invalid_session_state", error.to_string(), false);
                                continue;
                            }
                            sink.emit(RuntimeEvent::SessionUpdate {
                                update: SessionUpdate {
                                    session_id,
                                    kind: SessionUpdateKind::SessionClosed,
                                    text: None,
                                    request_id: Some(request_id),
                                    payload: None,
                                },
                            });
                            if let Some(message) = persistence_error {
                                sink.error(None, "session_store_failed", message, false);
                            }
                        }
                        Err(message) => sink.error(Some(request_id), "close_session_failed", message, true),
                    },
                    InternalEvent::SessionDeleted { request_id, session_id, result } => match result {
                        Ok(()) => {
                            let persistence_error = session_registry.remove(&session_id).err();
                            cancel_session_permissions(
                                &pending_permissions,
                                &sink,
                                &session_id,
                                PermissionInvalidationReason::SessionClosed,
                            );
                            if let Some(manager) = terminal_manager.as_ref()
                                && let Err(error) = manager.close_session(&session_id)
                            {
                                sink.error(None, "terminal_session_close_failed", error.to_string(), false);
                            }
                            if let Some(manager) = filesystem_manager.as_ref()
                                && let Err(error) = manager.close_session(&session_id)
                            {
                                sink.error(None, "filesystem_session_close_failed", error.to_string(), false);
                            }
                            scopes.remove(&session_id);
                            config_options_by_session.remove(&session_id);
                            config_mutations.remove(&session_id);
                            state.forget_session(&session_id);
                            sink.emit(RuntimeEvent::SessionUpdate {
                                update: SessionUpdate {
                                    session_id,
                                    kind: SessionUpdateKind::SessionDeleted,
                                    text: None,
                                    request_id: Some(request_id),
                                    payload: None,
                                },
                            });
                            if let Some(message) = persistence_error {
                                sink.error(None, "session_store_failed", message, false);
                            }
                        }
                        Err(message) => sink.error(Some(request_id), "delete_session_failed", message, true),
                    },
                    InternalEvent::AuthenticationChanged {
                        request_id,
                        authenticated,
                        method_id,
                        result,
                    } => match result {
                        Ok(()) => sink.emit(RuntimeEvent::AuthenticationChanged {
                            request_id,
                            authenticated,
                            method_id,
                        }),
                        Err(message) => sink.error(
                            Some(request_id),
                            if authenticated { "authenticate_failed" } else { "logout_failed" },
                            message,
                            true,
                        ),
                    },
                    InternalEvent::PromptFinished { request_id, session_id, result } => {
                        cancel_session_permissions(
                            &pending_permissions,
                            &sink,
                            &session_id,
                            PermissionInvalidationReason::PromptEnded,
                        );
                        if let Err(error) = state.prompt_finished(&session_id) {
                            sink.error(Some(request_id.clone()), "invalid_session_state", error.to_string(), false);
                        }
                        match result {
                            Ok(stop_reason) => {
                                if let Err(message) = session_registry.touch(&session_id) {
                                    sink.error(
                                        Some(request_id.clone()),
                                        "session_store_failed",
                                        message,
                                        false,
                                    );
                                }
                                render_router.route(RenderUpdate {
                                    session_id,
                                    kind: RenderUpdateKind::TurnCompleted,
                                    text: String::new(),
                                    metadata: Some(serde_json::json!({
                                        "stopReason": stop_reason,
                                        "requestId": request_id,
                                    })),
                                });
                            }
                            Err(message) => sink.error(Some(request_id), "prompt_failed", message, true),
                        }
                    }
                    InternalEvent::PermissionWaiting { request_id, session_id } => {
                        if !has_pending_permission(&pending_permissions, &request_id) {
                            continue;
                        }
                        if let Err(error) = state.permission_requested(&session_id) {
                            sink.error(None, "invalid_session_state", error.to_string(), false);
                            cancel_session_permissions(
                                &pending_permissions,
                                &sink,
                                &session_id,
                                PermissionInvalidationReason::PromptEnded,
                            );
                        }
                    }
                    InternalEvent::PermissionTimedOut { request_id } => {
                        let session_id = invalidate_permission(
                            &pending_permissions,
                            &sink,
                            &request_id,
                            PermissionInvalidationReason::TimedOut,
                        );
                        if let Some(session_id) = session_id
                            && !has_pending_permission_for_session(&pending_permissions, &session_id)
                            && let Err(error) = state.permission_resolved(&session_id)
                        {
                            sink.error(None, "invalid_session_state", error.to_string(), false);
                        }
                    }
                    InternalEvent::ModeSet { request_id, session_id, mode_id, result } => match result {
                        Ok(()) => sink.emit(RuntimeEvent::SessionUpdate {
                            update: SessionUpdate {
                                session_id,
                                kind: SessionUpdateKind::ModeChanged,
                                text: None,
                                request_id: Some(request_id),
                                payload: Some(serde_json::json!({ "modeId": mode_id })),
                            },
                        }),
                        Err(message) => sink.error(Some(request_id), "set_mode_failed", message, true),
                    },
                    InternalEvent::ConfigSet { request_id, session_id, result } => {
                        config_mutations.remove(&session_id);
                        match result {
                            Ok(options) => {
                                config_options_by_session.insert(session_id.clone(), options.clone());
                                emit_config_changed(
                                    &sink,
                                    session_id,
                                    Some(request_id),
                                    &options,
                                );
                            }
                            Err(message) => sink.error(Some(request_id), "set_config_failed", message, true),
                        }
                    }
                    InternalEvent::ConfigNotified { session_id, options } => {
                        if state.session_status(&session_id).is_some() {
                            config_options_by_session.insert(session_id.clone(), options.clone());
                            emit_config_changed(&sink, session_id, None, &options);
                        } else if pending_session_creates > 0
                            || pending_session_restores.contains_key(&session_id)
                        {
                            let notification_bytes = serde_json::to_vec(&options)
                                .map_or(STAGED_CONFIG_MAX_BYTES.saturating_add(1), |value| value.len());
                            let previous_bytes = staged_config_notifications
                                .get(&session_id)
                                .map_or(0, |(_, bytes)| *bytes);
                            let projected_bytes = staged_config_bytes
                                .saturating_sub(previous_bytes)
                                .saturating_add(notification_bytes);
                            let projected_entries = staged_config_notifications.len()
                                + usize::from(!staged_config_notifications.contains_key(&session_id));
                            if notification_bytes > SESSION_CONFIG_MAX_PROJECTION_BYTES
                                || projected_entries > STAGED_CONFIG_MAX_ENTRIES
                                || projected_bytes > STAGED_CONFIG_MAX_BYTES
                            {
                                sink.error(
                                    None,
                                    "invalid_session_notification",
                                    format!(
                                        "config notification staging exceeds its bounded policy for session {session_id}"
                                    ),
                                    false,
                                );
                                continue;
                            }
                            staged_config_bytes = projected_bytes;
                            staged_config_notifications
                                .insert(session_id, (options, notification_bytes));
                        } else {
                            sink.error(
                                None,
                                "invalid_session_notification",
                                format!(
                                    "config notification references unknown session {session_id}"
                                ),
                                false,
                            );
                        }
                    }
                }
            }
        }
    }
}

fn decrement_pending_session_restore(pending: &mut HashMap<String, usize>, session_id: &str) {
    let Some(count) = pending.get_mut(session_id) else {
        return;
    };
    *count = count.saturating_sub(1);
    if *count == 0 {
        pending.remove(session_id);
    }
}

fn drop_staged_config_notification(
    staged: &mut HashMap<String, (Vec<SessionConfigOptionProjection>, usize)>,
    staged_bytes: &mut usize,
    session_id: &str,
) {
    if let Some((_, bytes)) = staged.remove(session_id) {
        *staged_bytes = staged_bytes.saturating_sub(bytes);
    }
}

fn purge_orphaned_config_notifications(
    staged: &mut HashMap<String, (Vec<SessionConfigOptionProjection>, usize)>,
    staged_bytes: &mut usize,
    pending_creates: usize,
    pending_restores: &HashMap<String, usize>,
) {
    if pending_creates > 0 {
        return;
    }
    staged.retain(|session_id, (_, bytes)| {
        let retain = pending_restores.contains_key(session_id);
        if !retain {
            *staged_bytes = staged_bytes.saturating_sub(*bytes);
        }
        retain
    });
}

#[derive(Debug, Clone, Copy)]
enum PermissionInvalidationReason {
    TimedOut,
    PromptEnded,
    PromptCancelled,
    SessionClosed,
    ConnectionClosed,
    Disposed,
}

impl PermissionInvalidationReason {
    const fn as_str(self) -> &'static str {
        match self {
            Self::TimedOut => "timed_out",
            Self::PromptEnded => "prompt_ended",
            Self::PromptCancelled => "prompt_cancelled",
            Self::SessionClosed => "session_closed",
            Self::ConnectionClosed => "connection_closed",
            Self::Disposed => "disposed",
        }
    }
}

fn cancel_all_permissions(
    pending: &Mutex<HashMap<String, PendingPermission>>,
    sink: &EventSink,
    reason: PermissionInvalidationReason,
) {
    let pending_requests = {
        let mut pending = pending.lock().expect("permission mutex poisoned");
        pending.drain().collect::<Vec<_>>()
    };
    for (request_id, pending) in pending_requests {
        invalidate_removed_permission(sink, request_id, pending, reason);
    }
}

fn cancel_session_permissions(
    pending: &Mutex<HashMap<String, PendingPermission>>,
    sink: &EventSink,
    session_id: &str,
    reason: PermissionInvalidationReason,
) {
    let pending_requests = {
        let mut pending = pending.lock().expect("permission mutex poisoned");
        let ids = pending
            .iter()
            .filter_map(|(id, value)| (value.session_id() == session_id).then_some(id.clone()))
            .collect::<Vec<_>>();
        ids.into_iter()
            .filter_map(|id| pending.remove(&id).map(|value| (id, value)))
            .collect::<Vec<_>>()
    };
    for (request_id, pending) in pending_requests {
        invalidate_removed_permission(sink, request_id, pending, reason);
    }
}

fn invalidate_permission(
    pending: &Mutex<HashMap<String, PendingPermission>>,
    sink: &EventSink,
    request_id: &str,
    reason: PermissionInvalidationReason,
) -> Option<String> {
    let pending = pending
        .lock()
        .expect("permission mutex poisoned")
        .remove(request_id)?;
    let session_id = pending.session_id().to_string();
    invalidate_removed_permission(sink, request_id.to_string(), pending, reason);
    Some(session_id)
}

fn invalidate_removed_permission(
    sink: &EventSink,
    request_id: String,
    pending: PendingPermission,
    reason: PermissionInvalidationReason,
) {
    let session_id = pending.session_id().to_string();
    match pending {
        PendingPermission::Acp { responder, .. } => {
            let _ = responder.respond(RequestPermissionResponse::new(
                RequestPermissionOutcome::Cancelled,
            ));
        }
        PendingPermission::Terminal {
            approval_id,
            manager,
            responder,
            ..
        } => {
            let _ = manager.deny_create(&approval_id);
            let _ = responder.respond_with_error(terminal_denied_error());
        }
        PendingPermission::FilesystemRead {
            approval_id,
            manager,
            responder,
            ..
        } => {
            let _ = manager.deny(&approval_id);
            let _ = responder.respond_with_error(filesystem_denied_error());
        }
        PendingPermission::FilesystemWrite {
            approval_id,
            manager,
            responder,
            ..
        } => {
            let _ = manager.deny(&approval_id);
            let _ = responder.respond_with_error(filesystem_denied_error());
        }
    }
    sink.emit(RuntimeEvent::SessionUpdate {
        update: SessionUpdate {
            session_id,
            kind: SessionUpdateKind::PermissionInvalidated,
            text: None,
            request_id: Some(request_id),
            payload: Some(serde_json::json!({ "reason": reason.as_str() })),
        },
    });
}

fn has_pending_permission(
    pending: &Mutex<HashMap<String, PendingPermission>>,
    request_id: &str,
) -> bool {
    pending
        .lock()
        .expect("permission mutex poisoned")
        .contains_key(request_id)
}

fn has_pending_permission_for_session(
    pending: &Mutex<HashMap<String, PendingPermission>>,
    session_id: &str,
) -> bool {
    pending
        .lock()
        .expect("permission mutex poisoned")
        .values()
        .any(|value| value.session_id() == session_id)
}

fn terminal_unavailable_error() -> AcpError {
    AcpError::method_not_found().data("Rust terminal provider is disabled")
}

fn terminal_operation_error(error: &impl ToString) -> AcpError {
    AcpError::invalid_params().data(error.to_string())
}

fn terminal_denied_error() -> AcpError {
    AcpError::request_cancelled().data("terminal execution denied by user")
}

fn filesystem_unavailable_error() -> AcpError {
    AcpError::method_not_found().data("Rust filesystem provider is disabled")
}

fn filesystem_operation_error(error: &impl ToString) -> AcpError {
    AcpError::invalid_params().data(error.to_string())
}

fn filesystem_denied_error() -> AcpError {
    AcpError::request_cancelled().data("filesystem operation denied by user")
}

fn project_filesystem_permission(
    approval: &FilesystemApproval,
) -> Result<PermissionRequestProjection, String> {
    let (title, tool_kind) = match approval.kind {
        FilesystemOperationKind::Read => ("Read file", "read"),
        FilesystemOperationKind::Write => ("Write file", "edit"),
    };
    let raw_input = match approval.kind {
        FilesystemOperationKind::Read => serde_json::json!({
            "path": approval.path,
            "line": approval.line,
            "limit": approval.limit,
        }),
        FilesystemOperationKind::Write => serde_json::json!({
            "path": approval.path,
            "writeBytes": approval.write_bytes,
            "contentPreview": approval.content_preview,
            "contentTruncated": approval.content_truncated,
        }),
    };
    let projection = PermissionRequestProjection {
        request_id: approval.approval_id.clone(),
        session_id: approval.session_id.clone(),
        tool_call_id: format!("filesystem:{}", approval.approval_id),
        title: title.to_string(),
        tool_kind: tool_kind.to_string(),
        raw_input: Some(raw_input),
        options: vec![
            PermissionOptionProjection {
                option_id: FILESYSTEM_ALLOW_ONCE_OPTION_ID.to_string(),
                label: "Allow once".to_string(),
                kind: "allow_once".to_string(),
            },
            PermissionOptionProjection {
                option_id: FILESYSTEM_REJECT_ONCE_OPTION_ID.to_string(),
                label: "Reject".to_string(),
                kind: "reject_once".to_string(),
            },
        ],
    };
    validate_permission_projection(&projection)?;
    Ok(projection)
}

fn terminal_exit_status(exit: TerminalExit) -> TerminalExitStatus {
    TerminalExitStatus::new()
        .exit_code(exit.exit_code)
        .signal(exit.signal)
}

fn project_terminal_runtime_event(event: TerminalRuntimeEvent) -> RuntimeEvent {
    match event {
        TerminalRuntimeEvent::Attached {
            session_id,
            terminal_id,
            command,
            cwd,
        } => RuntimeEvent::TerminalAttached {
            session_id,
            terminal_id,
            command,
            cwd,
        },
        TerminalRuntimeEvent::Output {
            session_id,
            terminal_id,
            data,
        } => RuntimeEvent::TerminalOutput {
            session_id,
            terminal_id,
            data,
        },
        TerminalRuntimeEvent::Exited {
            session_id,
            terminal_id,
            exit,
        } => RuntimeEvent::TerminalExited {
            session_id,
            terminal_id,
            exit,
        },
        TerminalRuntimeEvent::Released {
            session_id,
            terminal_id,
        } => RuntimeEvent::TerminalReleased {
            session_id,
            terminal_id,
        },
    }
}

fn project_terminal_permission(
    approval: &crate::TerminalApproval,
) -> Result<PermissionRequestProjection, String> {
    let command = approval.command.first().cloned().unwrap_or_default();
    let args = approval.command.iter().skip(1).cloned().collect::<Vec<_>>();
    let projection = PermissionRequestProjection {
        request_id: approval.approval_id.clone(),
        session_id: approval.session_id.clone(),
        tool_call_id: format!("terminal:{}", approval.approval_id),
        title: "Run terminal command".to_string(),
        tool_kind: "execute".to_string(),
        raw_input: Some(serde_json::json!({
            "command": command,
            "args": args,
            "cwd": approval.cwd,
            "environment": approval.environment,
        })),
        options: vec![
            PermissionOptionProjection {
                option_id: TERMINAL_ALLOW_ONCE_OPTION_ID.to_string(),
                label: "Allow once".to_string(),
                kind: "allow_once".to_string(),
            },
            PermissionOptionProjection {
                option_id: TERMINAL_REJECT_ONCE_OPTION_ID.to_string(),
                label: "Reject".to_string(),
                kind: "reject_once".to_string(),
            },
        ],
    };
    validate_permission_projection(&projection)?;
    Ok(projection)
}

async fn list_all_sessions(
    connection: &ConnectionTo<Agent>,
) -> Result<Vec<SessionCatalogEntryProjection>, String> {
    let mut sessions = Vec::new();
    let mut cursor: Option<String> = None;
    let mut seen_cursors = HashSet::new();
    let mut seen_sessions = HashSet::new();
    let mut projected_bytes = 2_usize;
    for _ in 0..SESSION_LIST_MAX_PAGES {
        let response = connection
            .send_request(ListSessionsRequest::new().cursor(cursor.clone()))
            .block_task()
            .await
            .map_err(|error| error.to_string())?;
        for session in response.sessions {
            if sessions.len() >= SESSION_LIST_MAX_ENTRIES {
                return Err(format!(
                    "session catalog exceeds {SESSION_LIST_MAX_ENTRIES} entries"
                ));
            }
            let projected = project_session_info(session)?;
            if !seen_sessions.insert(projected.session_id.clone()) {
                return Err(format!(
                    "session catalog repeats id {}",
                    projected.session_id
                ));
            }
            let entry_bytes = serde_json::to_vec(&projected)
                .map_err(|error| format!("failed to encode session catalog entry: {error}"))?
                .len();
            projected_bytes = projected_bytes
                .saturating_add(entry_bytes)
                .saturating_add(usize::from(!sessions.is_empty()));
            if projected_bytes > SESSION_CATALOG_MAX_PROJECTION_BYTES {
                return Err(format!(
                    "session catalog projection exceeds {SESSION_CATALOG_MAX_PROJECTION_BYTES} bytes"
                ));
            }
            sessions.push(projected);
        }
        let Some(next) = response.next_cursor else {
            return Ok(sessions);
        };
        if next.is_empty() || next.trim() != next {
            return Err("session catalog returned a non-canonical cursor".to_string());
        }
        if next.len() > SESSION_LIST_MAX_CURSOR_BYTES {
            return Err(format!(
                "session catalog cursor exceeds {SESSION_LIST_MAX_CURSOR_BYTES} bytes"
            ));
        }
        if !seen_cursors.insert(next.clone()) {
            return Err("session catalog cursor cycle detected".to_string());
        }
        cursor = Some(next);
    }
    Err(format!(
        "session catalog exceeds {SESSION_LIST_MAX_PAGES} pages"
    ))
}

fn project_session_info(session: SessionInfo) -> Result<SessionCatalogEntryProjection, String> {
    let session_id = bounded_protocol_text(
        &session.session_id.to_string(),
        "session catalog id",
        SESSION_ID_MAX_BYTES,
        false,
    )?;
    if session.cwd.as_os_str().as_bytes().len() > SESSION_CATALOG_PATH_MAX_BYTES {
        return Err("session catalog cwd exceeds the bounded path policy".to_string());
    }
    let cwd = normalize_workspace_identity(&session.cwd)
        .map_err(|error| error.to_string())?
        .display()
        .to_string();
    if session.additional_directories.len() > SESSION_CATALOG_MAX_ADDITIONAL_DIRECTORIES {
        return Err(format!(
            "session catalog entry exceeds {SESSION_CATALOG_MAX_ADDITIONAL_DIRECTORIES} additional directories"
        ));
    }
    let additional_directories = session
        .additional_directories
        .iter()
        .map(|path| {
            if path.as_os_str().as_bytes().len() > SESSION_CATALOG_PATH_MAX_BYTES {
                return Err("session catalog directory exceeds the bounded path policy".to_string());
            }
            normalize_workspace_identity(Path::new(path))
                .map(|normalized| normalized.display().to_string())
                .map_err(|error| error.to_string())
        })
        .collect::<Result<Vec<_>, _>>()?;
    let title = session.title.as_deref().and_then(normalize_session_title);
    let meta = session
        .meta
        .map(serde_json::to_value)
        .transpose()
        .map_err(|error| format!("invalid session catalog metadata: {error}"))?;
    if let Some(meta) = meta.as_ref()
        && serde_json::to_vec(meta)
            .map_err(|error| format!("invalid session catalog metadata: {error}"))?
            .len()
            > SESSION_CATALOG_METADATA_MAX_BYTES
    {
        return Err(format!(
            "session catalog metadata exceeds {SESSION_CATALOG_METADATA_MAX_BYTES} bytes"
        ));
    }
    let updated_at = session
        .updated_at
        .map(|value| {
            bounded_protocol_text(
                &value,
                "session catalog updated_at",
                SESSION_LIST_MAX_CURSOR_BYTES,
                true,
            )
        })
        .transpose()?;
    let projection = SessionCatalogEntryProjection {
        session_id,
        cwd,
        additional_directories,
        title,
        updated_at,
        meta,
    };
    let encoded_bytes = serde_json::to_vec(&projection)
        .map_err(|error| format!("failed to encode session catalog entry: {error}"))?
        .len();
    if encoded_bytes > SESSION_CATALOG_ENTRY_MAX_BYTES {
        return Err(format!(
            "session catalog entry exceeds {SESSION_CATALOG_ENTRY_MAX_BYTES} bytes"
        ));
    }
    Ok(projection)
}

fn normalize_session_title(value: &str) -> Option<String> {
    let mut normalized = String::with_capacity(SESSION_TITLE_MAX_CHARACTERS);
    let mut character_count = 0_usize;
    let mut pending_space = false;
    let mut truncated = false;

    for character in value.chars() {
        if character.is_whitespace() || character.is_control() {
            if character_count > 0 {
                pending_space = true;
            }
            continue;
        }

        let required_characters = if pending_space { 2 } else { 1 };
        if character_count + required_characters > SESSION_TITLE_MAX_CHARACTERS {
            truncated = true;
            break;
        }
        if pending_space {
            normalized.push(' ');
            character_count += 1;
        }
        normalized.push(character);
        character_count += 1;
        pending_space = false;
    }

    if normalized.is_empty() {
        return None;
    }
    if truncated {
        if character_count == SESSION_TITLE_MAX_CHARACTERS {
            normalized.pop();
        }
        normalized.push('…');
    }
    Some(normalized)
}

fn capability_projection(
    capabilities: &agent_client_protocol::schema::v1::AgentCapabilities,
    session_support: SessionSupport,
    auth_methods: Vec<AuthMethodProjection>,
    filesystem_read_text_file: bool,
    filesystem_write_text_file: bool,
    terminal: bool,
) -> CapabilityProjection {
    CapabilityProjection {
        protocol_version: 1,
        // Host-facing capabilities are the intersection of the peer and core.
        load_session: session_support.load,
        list_sessions: session_support.list,
        resume_session: session_support.resume,
        close_session: session_support.close,
        delete_session: session_support.delete,
        logout: capabilities.auth.logout.is_some(),
        auth_methods,
        session_modes: false,
        session_config: false,
        prompt_image: capabilities.prompt_capabilities.image,
        prompt_audio: capabilities.prompt_capabilities.audio,
        embedded_context: capabilities.prompt_capabilities.embedded_context,
        mcp_capabilities: capabilities.mcp_capabilities.http || capabilities.mcp_capabilities.sse,
        mcp_http: capabilities.mcp_capabilities.http,
        mcp_sse: capabilities.mcp_capabilities.sse,
        additional_directories: capabilities
            .session_capabilities
            .additional_directories
            .is_some(),
        filesystem_read_text_file,
        filesystem_write_text_file,
        terminal,
    }
}

fn project_mcp_servers(
    configured: &[McpServerLaunchConfig],
    capabilities: &agent_client_protocol::schema::v1::McpCapabilities,
) -> Result<Vec<AcpMcpServer>, String> {
    configured
        .iter()
        .map(|server| match server {
            McpServerLaunchConfig::Stdio {
                name,
                command,
                args,
                environment,
            } => Ok(AcpMcpServer::Stdio(
                McpServerStdio::new(name.clone(), command.clone())
                    .args(args.clone())
                    .env(
                        environment
                            .iter()
                            .map(|(name, value)| EnvVariable::new(name.clone(), value.clone()))
                            .collect(),
                    ),
            )),
            McpServerLaunchConfig::Http { name, url, headers } => {
                if !capabilities.http {
                    return Err(format!(
                        "agent does not support configured HTTP MCP server {name}"
                    ));
                }
                Ok(AcpMcpServer::Http(
                    McpServerHttp::new(name.clone(), url.clone()).headers(
                        headers
                            .iter()
                            .map(|(name, value)| HttpHeader::new(name.clone(), value.clone()))
                            .collect(),
                    ),
                ))
            }
            McpServerLaunchConfig::Sse { name, url, headers } => {
                if !capabilities.sse {
                    return Err(format!(
                        "agent does not support configured SSE MCP server {name}"
                    ));
                }
                Ok(AcpMcpServer::Sse(
                    McpServerSse::new(name.clone(), url.clone()).headers(
                        headers
                            .iter()
                            .map(|(name, value)| HttpHeader::new(name.clone(), value.clone()))
                            .collect(),
                    ),
                ))
            }
        })
        .collect()
}

fn project_auth_methods(methods: &[AuthMethod]) -> Result<Vec<AuthMethodProjection>, String> {
    if methods.len() > AUTH_METHODS_MAX_ENTRIES {
        return Err(format!(
            "agent initialize exceeds {AUTH_METHODS_MAX_ENTRIES} authentication methods"
        ));
    }
    let mut projected = Vec::with_capacity(methods.len());
    let mut ids = HashSet::with_capacity(methods.len());
    for method in methods {
        let id = bounded_protocol_text(
            &method.id().to_string(),
            "authentication method id",
            AUTH_METHOD_ID_MAX_BYTES,
            false,
        )?;
        if id.trim() != id {
            return Err(
                "authentication method id must not have surrounding whitespace".to_string(),
            );
        }
        if !ids.insert(id.clone()) {
            return Err(format!("duplicate authentication method id: {id}"));
        }
        let name = bounded_protocol_text(
            method.name().trim(),
            "authentication method name",
            AUTH_METHOD_NAME_MAX_BYTES,
            false,
        )?;
        let description = method
            .description()
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(|value| {
                bounded_protocol_text(
                    value,
                    "authentication method description",
                    AUTH_METHOD_DESCRIPTION_MAX_BYTES,
                    false,
                )
            })
            .transpose()?;
        projected.push(AuthMethodProjection {
            id,
            name,
            description,
        });
        let projection_bytes = serde_json::to_vec(&projected)
            .map_err(|error| format!("authentication methods could not be serialized: {error}"))?
            .len();
        if projection_bytes > AUTH_METHODS_MAX_PROJECTION_BYTES {
            return Err(format!(
                "authentication methods exceed {AUTH_METHODS_MAX_PROJECTION_BYTES} projected bytes"
            ));
        }
    }
    Ok(projected)
}

fn session_support(
    capabilities: &agent_client_protocol::schema::v1::AgentCapabilities,
) -> SessionSupport {
    SessionSupport {
        load: capabilities.load_session,
        list: capabilities.session_capabilities.list.is_some(),
        resume: capabilities.session_capabilities.resume.is_some(),
        close: capabilities.session_capabilities.close.is_some(),
        delete: capabilities.session_capabilities.delete.is_some(),
    }
}

fn project_created_session(response: &NewSessionResponse) -> Result<CreatedSession, String> {
    Ok(CreatedSession {
        session_id: bounded_protocol_text(
            &response.session_id.to_string(),
            "session id",
            SESSION_ID_MAX_BYTES,
            false,
        )?,
        modes: response
            .modes
            .as_ref()
            .map(project_session_modes)
            .transpose()?,
        config_options: project_session_config_options(response.config_options.as_deref())?,
    })
}

fn project_session_config_options(
    options: Option<&[SessionConfigOption]>,
) -> Result<Vec<SessionConfigOptionProjection>, String> {
    let options = options.unwrap_or_default();
    if options.len() > SESSION_CONFIG_MAX_OPTIONS {
        return Err(format!(
            "session config exceeds {SESSION_CONFIG_MAX_OPTIONS} options"
        ));
    }
    let mut projected = Vec::with_capacity(options.len());
    let mut option_ids = HashSet::new();
    let mut choice_count = 0_usize;
    for option in options {
        let id = canonical_protocol_text(&option.id.to_string(), "session config id")?;
        if !option_ids.insert(id.clone()) {
            return Err(format!("duplicate session config id: {id}"));
        }
        let name = display_protocol_text(&option.name, &id, "session config name")?;
        let description =
            optional_protocol_text(option.description.as_deref(), "session config description")?;
        let category = option
            .category
            .as_ref()
            .and_then(|category| serde_json::to_value(category).ok())
            .and_then(|value| value.as_str().map(str::to_string));
        let kind = project_session_config_kind(&id, &option.kind)?;
        choice_count = choice_count.saturating_add(kind.choices.len());
        if choice_count > SESSION_CONFIG_MAX_CHOICES {
            return Err(format!(
                "session config exceeds {SESSION_CONFIG_MAX_CHOICES} choices"
            ));
        }
        projected.push(SessionConfigOptionProjection {
            id,
            name,
            option_type: kind.option_type.to_string(),
            current_value: kind.current_value,
            options: kind.choices,
            description,
            category,
        });
    }
    let encoded_bytes = serde_json::to_vec(&projected)
        .map_err(|error| format!("failed to encode session config projection: {error}"))?
        .len();
    if encoded_bytes > SESSION_CONFIG_MAX_PROJECTION_BYTES {
        return Err(format!(
            "session config projection exceeds {SESSION_CONFIG_MAX_PROJECTION_BYTES} bytes"
        ));
    }
    Ok(projected)
}

struct ProjectedSessionConfigKind {
    option_type: &'static str,
    current_value: serde_json::Value,
    choices: Vec<SessionConfigChoiceProjection>,
}

fn project_session_config_kind(
    id: &str,
    kind: &SessionConfigKind,
) -> Result<ProjectedSessionConfigKind, String> {
    match kind {
        SessionConfigKind::Boolean(value) => Ok(ProjectedSessionConfigKind {
            option_type: "boolean",
            current_value: serde_json::Value::Bool(value.current_value),
            choices: Vec::new(),
        }),
        SessionConfigKind::Select(value) => {
            let current = canonical_protocol_text(
                &value.current_value.to_string(),
                "session config current value",
            )?;
            let mut choices = Vec::new();
            match &value.options {
                SessionConfigSelectOptions::Ungrouped(values) => {
                    for choice in values {
                        choices.push(project_config_choice(choice, None, None)?);
                    }
                }
                SessionConfigSelectOptions::Grouped(groups) => {
                    for group in groups {
                        let group_id = canonical_protocol_text(
                            &group.group.to_string(),
                            "session config group id",
                        )?;
                        let group_name = display_protocol_text(
                            &group.name,
                            &group_id,
                            "session config group name",
                        )?;
                        for choice in &group.options {
                            choices.push(project_config_choice(
                                choice,
                                Some(group_id.clone()),
                                Some(group_name.clone()),
                            )?);
                        }
                    }
                }
                _ => {
                    return Err(format!(
                        "session config {id} uses an unsupported choice layout"
                    ));
                }
            }
            let choice_ids = choices
                .iter()
                .map(|choice| choice.value.as_str())
                .collect::<HashSet<_>>();
            if choice_ids.len() != choices.len() {
                return Err(format!("session config {id} repeats a choice value"));
            }
            if !choice_ids.contains(current.as_str()) {
                return Err(format!(
                    "session config {id} current value is not an advertised choice"
                ));
            }
            Ok(ProjectedSessionConfigKind {
                option_type: "select",
                current_value: serde_json::Value::String(current),
                choices,
            })
        }
        _ => Err(format!(
            "session config {id} uses an unsupported option type"
        )),
    }
}

fn project_config_choice(
    choice: &agent_client_protocol::schema::v1::SessionConfigSelectOption,
    group_id: Option<String>,
    group_name: Option<String>,
) -> Result<SessionConfigChoiceProjection, String> {
    let value = canonical_protocol_text(&choice.value.to_string(), "session config choice")?;
    Ok(SessionConfigChoiceProjection {
        name: display_protocol_text(&choice.name, &value, "session config choice name")?,
        value,
        description: optional_protocol_text(
            choice.description.as_deref(),
            "session config choice description",
        )?,
        group_id,
        group_name,
    })
}

fn canonical_protocol_text(value: &str, label: &str) -> Result<String, String> {
    if value.is_empty()
        || value.trim() != value
        || value.len() > SESSION_CONFIG_MAX_TEXT_BYTES
        || value.as_bytes().contains(&0)
    {
        Err(format!("{label} must be canonical non-empty text"))
    } else {
        Ok(value.to_string())
    }
}

fn display_protocol_text(value: &str, fallback: &str, label: &str) -> Result<String, String> {
    let trimmed = value.trim();
    if trimmed.len() > SESSION_CONFIG_MAX_TEXT_BYTES || trimmed.as_bytes().contains(&0) {
        Err(format!("{label} exceeds the bounded session config policy"))
    } else if trimmed.is_empty() {
        Ok(fallback.to_string())
    } else {
        Ok(trimmed.to_string())
    }
}

fn optional_protocol_text(value: Option<&str>, label: &str) -> Result<Option<String>, String> {
    let Some(value) = value.map(str::trim).filter(|value| !value.is_empty()) else {
        return Ok(None);
    };
    if value.len() > SESSION_CONFIG_MAX_TEXT_BYTES || value.as_bytes().contains(&0) {
        return Err(format!("{label} exceeds the bounded session config policy"));
    }
    Ok(Some(value.to_string()))
}

fn project_session_modes(modes: &SessionModeState) -> Result<SessionModesProjection, String> {
    if modes.available_modes.len() > SESSION_MODES_MAX_ENTRIES {
        return Err(format!(
            "session modes exceed {SESSION_MODES_MAX_ENTRIES} entries"
        ));
    }
    let current_mode_id = bounded_protocol_text(
        &modes.current_mode_id.to_string(),
        "current session mode id",
        SESSION_MODE_TEXT_MAX_BYTES,
        false,
    )?;
    let mut mode_ids = HashSet::new();
    let available_modes = modes
        .available_modes
        .iter()
        .map(|mode| {
            let id = bounded_protocol_text(
                &mode.id.to_string(),
                "session mode id",
                SESSION_MODE_TEXT_MAX_BYTES,
                false,
            )?;
            if !mode_ids.insert(id.clone()) {
                return Err(format!("duplicate session mode id: {id}"));
            }
            let name = mode.name.trim();
            let label = if name.is_empty() { &id } else { name };
            let label = bounded_protocol_text(
                label,
                "session mode label",
                SESSION_MODE_TEXT_MAX_BYTES,
                true,
            )?;
            Ok(SessionModeProjection { id, label })
        })
        .collect::<Result<Vec<_>, String>>()?;
    if !mode_ids.contains(&current_mode_id) {
        return Err("current session mode is not advertised".to_string());
    }
    let projection = SessionModesProjection {
        current_mode_id,
        available_modes,
    };
    let encoded_bytes = serde_json::to_vec(&projection)
        .map_err(|error| format!("failed to encode session modes projection: {error}"))?
        .len();
    if encoded_bytes > SESSION_MODES_MAX_PROJECTION_BYTES {
        return Err(format!(
            "session modes projection exceeds {SESSION_MODES_MAX_PROJECTION_BYTES} bytes"
        ));
    }
    Ok(projection)
}

fn stop_reason_name(reason: StopReason) -> &'static str {
    match reason {
        StopReason::EndTurn => "end_turn",
        StopReason::MaxTokens => "max_tokens",
        StopReason::MaxTurnRequests => "max_turn_requests",
        StopReason::Refusal => "refusal",
        StopReason::Cancelled => "cancelled",
        _ => "other",
    }
}

fn project_permission_request(
    request_id: &str,
    request: &RequestPermissionRequest,
) -> Result<PermissionRequestProjection, String> {
    if request.options.len() > PERMISSION_MAX_OPTIONS {
        return Err(format!(
            "permission request exceeds {PERMISSION_MAX_OPTIONS} options"
        ));
    }
    let session_id = permission_projection_text(&request.session_id.to_string(), "session id")?;
    let tool_call_id =
        permission_projection_text(&request.tool_call.tool_call_id.to_string(), "tool call id")?;
    let title = permission_projection_text(
        request
            .tool_call
            .fields
            .title
            .as_deref()
            .unwrap_or("Agent action"),
        "permission title",
    )?;
    let raw_input = request.tool_call.fields.raw_input.as_ref();
    if let Some(raw_input) = raw_input {
        let encoded = serde_json::to_vec(raw_input)
            .map_err(|error| format!("invalid permission raw input: {error}"))?;
        if encoded.len() > PERMISSION_MAX_RAW_INPUT_BYTES {
            return Err(format!(
                "permission raw input exceeds {PERMISSION_MAX_RAW_INPUT_BYTES} bytes"
            ));
        }
    }
    let options = request
        .options
        .iter()
        .map(|option| {
            Ok(PermissionOptionProjection {
                option_id: permission_projection_text(
                    &option.option_id.to_string(),
                    "permission option id",
                )?,
                label: permission_projection_text(&option.name, "permission option label")?,
                kind: permission_option_kind(option.kind).to_string(),
            })
        })
        .collect::<Result<Vec<_>, String>>()?;
    let projection = PermissionRequestProjection {
        request_id: permission_projection_text(request_id, "permission request id")?,
        session_id,
        tool_call_id,
        title,
        tool_kind: request.tool_call.fields.kind.map_or_else(
            || "other".to_string(),
            |kind| format!("{kind:?}").to_lowercase(),
        ),
        raw_input: raw_input.cloned(),
        options,
    };
    validate_permission_projection(&projection)?;
    Ok(projection)
}

fn validate_permission_projection(projection: &PermissionRequestProjection) -> Result<(), String> {
    if let Some(raw_input) = projection.raw_input.as_ref() {
        let raw_input_bytes = serde_json::to_vec(raw_input)
            .map_err(|error| format!("failed to encode permission raw input: {error}"))?
            .len();
        if raw_input_bytes > PERMISSION_MAX_RAW_INPUT_BYTES {
            return Err(format!(
                "permission raw input exceeds {PERMISSION_MAX_RAW_INPUT_BYTES} bytes"
            ));
        }
    }
    let encoded_bytes = serde_json::to_vec(projection)
        .map_err(|error| format!("failed to encode permission projection: {error}"))?
        .len();
    if encoded_bytes > PERMISSION_MAX_PROJECTION_BYTES {
        return Err(format!(
            "permission projection exceeds {PERMISSION_MAX_PROJECTION_BYTES} bytes"
        ));
    }
    Ok(())
}

fn permission_projection_text(value: &str, label: &str) -> Result<String, String> {
    if value.len() > PERMISSION_MAX_TEXT_BYTES || value.as_bytes().contains(&0) {
        Err(format!(
            "{label} exceeds the bounded permission projection policy"
        ))
    } else {
        Ok(value.to_string())
    }
}

fn permission_option_kind(kind: PermissionOptionKind) -> &'static str {
    match kind {
        PermissionOptionKind::AllowOnce => "allow_once",
        PermissionOptionKind::AllowAlways => "allow_always",
        PermissionOptionKind::RejectOnce => "reject_once",
        PermissionOptionKind::RejectAlways => "reject_always",
        _ => "unknown",
    }
}

enum ProjectedSessionNotification {
    Render(Vec<RenderUpdate>),
    Control(SessionUpdate),
    Config {
        session_id: String,
        options: Vec<SessionConfigOptionProjection>,
    },
}

#[allow(clippy::too_many_lines)]
fn project_session_notification(
    notification: SessionNotification,
) -> Result<Option<ProjectedSessionNotification>, String> {
    let session_id = bounded_protocol_text(
        &notification.session_id.to_string(),
        "session notification id",
        SESSION_ID_MAX_BYTES,
        false,
    )?;
    let projection = match notification.update {
        AcpSessionUpdate::UserMessageChunk(chunk) => {
            let (text, metadata) = render_content(&chunk.content);
            ProjectedSessionNotification::Render(project_render_updates(
                session_id,
                RenderUpdateKind::UserMessage,
                text,
                metadata,
            ))
        }
        AcpSessionUpdate::AgentMessageChunk(chunk) => {
            let (text, metadata) = render_content(&chunk.content);
            ProjectedSessionNotification::Render(project_render_updates(
                session_id,
                RenderUpdateKind::AssistantText,
                text,
                metadata,
            ))
        }
        AcpSessionUpdate::AgentThoughtChunk(chunk) => {
            let (text, _) = render_content(&chunk.content);
            ProjectedSessionNotification::Render(project_render_updates(
                session_id,
                RenderUpdateKind::Thought,
                text,
                None,
            ))
        }
        AcpSessionUpdate::ToolCall(value) => {
            let title = bounded_protocol_text(
                &value.title,
                "tool call title",
                RENDER_TITLE_MAX_BYTES,
                true,
            )?;
            ProjectedSessionNotification::Render(vec![RenderUpdate {
                session_id,
                kind: RenderUpdateKind::ToolCall,
                text: title,
                metadata: project_tool_render_metadata(value)?,
            }])
        }
        AcpSessionUpdate::ToolCallUpdate(value) => {
            let title = bounded_protocol_text(
                value.fields.title.as_deref().unwrap_or_default(),
                "tool call update title",
                RENDER_TITLE_MAX_BYTES,
                true,
            )?;
            ProjectedSessionNotification::Render(vec![RenderUpdate {
                session_id,
                kind: RenderUpdateKind::ToolCall,
                text: title,
                metadata: project_tool_render_metadata(value)?,
            }])
        }
        AcpSessionUpdate::Plan(value) => {
            let mut metadata = serde_json::json!({ "entries": value.entries });
            strip_non_render_fields(&mut metadata);
            ProjectedSessionNotification::Render(vec![RenderUpdate {
                session_id,
                kind: RenderUpdateKind::Plan,
                text: String::new(),
                metadata: Some(bound_render_metadata(metadata, "plan")),
            }])
        }
        AcpSessionUpdate::CurrentModeUpdate(value) => {
            let mode_id = bounded_protocol_text(
                &value.current_mode_id.to_string(),
                "current session mode id",
                SESSION_MODE_TEXT_MAX_BYTES,
                false,
            )?;
            ProjectedSessionNotification::Control(SessionUpdate {
                session_id,
                kind: SessionUpdateKind::ModeChanged,
                text: None,
                request_id: None,
                payload: Some(serde_json::json!({
                    "modeId": mode_id,
                })),
            })
        }
        AcpSessionUpdate::ConfigOptionUpdate(value) => {
            let options = project_session_config_options(Some(&value.config_options))?;
            return Ok(Some(ProjectedSessionNotification::Config {
                session_id,
                options,
            }));
        }
        AcpSessionUpdate::AvailableCommandsUpdate(value) => {
            let commands = project_available_commands(&value.available_commands)?;
            ProjectedSessionNotification::Control(SessionUpdate {
                session_id,
                kind: SessionUpdateKind::CommandsChanged,
                text: None,
                request_id: None,
                payload: Some(serde_json::json!({
                    "availableCommands": commands,
                })),
            })
        }
        // Protocol notifications without a UI consumer never cross FFI.
        _ => return Ok(None),
    };
    Ok(Some(projection))
}

fn project_available_commands(
    commands: &[AvailableCommand],
) -> Result<Vec<serde_json::Value>, String> {
    if commands.len() > AVAILABLE_COMMANDS_MAX_ENTRIES {
        return Err(format!(
            "available commands exceed {AVAILABLE_COMMANDS_MAX_ENTRIES} entries"
        ));
    }
    let mut names = HashSet::with_capacity(commands.len());
    let mut projected = Vec::with_capacity(commands.len());
    let mut projected_bytes = 2_usize;
    for command in commands {
        let name = bounded_protocol_text(
            &command.name,
            "available command name",
            AVAILABLE_COMMAND_NAME_MAX_BYTES,
            false,
        )?;
        if !names.insert(name.clone()) {
            return Err(format!("duplicate available command name: {name}"));
        }
        let description = bounded_protocol_text(
            &command.description,
            "available command description",
            AVAILABLE_COMMAND_DESCRIPTION_MAX_BYTES,
            true,
        )?;
        let input = match command.input.as_ref() {
            Some(AvailableCommandInput::Unstructured(input)) => Some(serde_json::json!({
                "hint": bounded_protocol_text(
                    &input.hint,
                    "available command input hint",
                    AVAILABLE_COMMAND_HINT_MAX_BYTES,
                    true,
                )?,
            })),
            // Future ACP input variants are intentionally omitted until the UI
            // has a bounded, typed projection for them.
            Some(_) | None => None,
        };
        let projection = serde_json::json!({
            "name": name,
            "description": description,
            "input": input,
        });
        let entry_bytes = serde_json::to_vec(&projection)
            .map_err(|error| format!("failed to encode available commands: {error}"))?
            .len();
        projected_bytes = projected_bytes
            .saturating_add(entry_bytes)
            .saturating_add(usize::from(!projected.is_empty()));
        if projected_bytes > AVAILABLE_COMMANDS_MAX_PROJECTION_BYTES {
            return Err(format!(
                "available commands projection exceeds {AVAILABLE_COMMANDS_MAX_PROJECTION_BYTES} bytes"
            ));
        }
        projected.push(projection);
    }
    Ok(projected)
}

fn bounded_protocol_text(
    value: &str,
    label: &str,
    max_bytes: usize,
    allow_empty: bool,
) -> Result<String, String> {
    let trimmed = value.trim();
    if !allow_empty && (trimmed.is_empty() || trimmed != value) {
        return Err(format!("{label} must be canonical text"));
    }
    if trimmed.len() > max_bytes || trimmed.as_bytes().contains(&0) {
        return Err(format!("{label} exceeds {max_bytes} UTF-8 bytes"));
    }
    Ok(trimmed.to_string())
}

fn emit_config_changed(
    sink: &EventSink,
    session_id: String,
    request_id: Option<String>,
    options: &[SessionConfigOptionProjection],
) {
    sink.emit(RuntimeEvent::SessionUpdate {
        update: SessionUpdate {
            session_id,
            kind: SessionUpdateKind::ConfigChanged,
            text: None,
            request_id,
            payload: Some(serde_json::json!({ "configOptions": options })),
        },
    });
}

fn render_content(content: &ContentBlock) -> (String, Option<serde_json::Value>) {
    if let ContentBlock::Text(text) = content {
        (text.text.clone(), None)
    } else {
        let mut block = serde_json::to_value(content).ok();
        if let Some(block) = block.as_mut() {
            strip_non_render_fields(block);
        }
        (
            String::new(),
            block.map(|block| {
                bound_render_metadata(
                    serde_json::json!({ "contentBlocks": [block] }),
                    "content_block",
                )
            }),
        )
    }
}

fn project_render_updates(
    session_id: String,
    kind: RenderUpdateKind,
    text: String,
    metadata: Option<serde_json::Value>,
) -> Vec<RenderUpdate> {
    if text.len() <= RENDER_TEXT_CHUNK_MAX_BYTES {
        return vec![RenderUpdate {
            session_id,
            kind,
            text,
            metadata,
        }];
    }
    let mut updates = Vec::new();
    let mut offset = 0_usize;
    while offset < text.len() {
        let mut end = offset
            .saturating_add(RENDER_TEXT_CHUNK_MAX_BYTES)
            .min(text.len());
        while !text.is_char_boundary(end) {
            end = end.saturating_sub(1);
        }
        updates.push(RenderUpdate {
            session_id: session_id.clone(),
            kind,
            text: text[offset..end].to_string(),
            metadata: if offset == 0 { metadata.clone() } else { None },
        });
        offset = end;
    }
    updates
}

fn render_metadata_bytes(metadata: Option<&serde_json::Value>) -> usize {
    metadata
        .and_then(|value| serde_json::to_vec(value).ok())
        .map_or(0, |value| value.len())
}

fn bound_render_metadata(value: serde_json::Value, resource: &str) -> serde_json::Value {
    let encoded_bytes = serde_json::to_vec(&value).map_or(usize::MAX, |encoded| encoded.len());
    if encoded_bytes <= RENDER_METADATA_MAX_BYTES {
        value
    } else {
        serde_json::json!({
            "type": "omitted",
            "reason": "input_limit",
            "resource": resource,
            "limit": RENDER_METADATA_MAX_BYTES,
            "observedAtLeast": encoded_bytes,
        })
    }
}

fn project_tool_render_metadata<T: serde::Serialize>(
    value: T,
) -> Result<Option<serde_json::Value>, String> {
    const TOOL_RENDER_FIELDS: [&str; 8] = [
        "toolCallId",
        "title",
        "kind",
        "status",
        "content",
        "locations",
        "rawInput",
        "rawOutput",
    ];
    let mut value = serde_json::to_value(value)
        .map_err(|error| format!("tool call metadata could not be serialized: {error}"))?;
    strip_non_render_fields(&mut value);
    let Some(fields) = value.as_object_mut() else {
        return Ok(None);
    };
    fields.retain(|key, _| TOOL_RENDER_FIELDS.contains(&key.as_str()));
    if let Some(tool_call_id) = fields.get("toolCallId").and_then(serde_json::Value::as_str) {
        let tool_call_id =
            bounded_protocol_text(tool_call_id, "tool call id", SESSION_ID_MAX_BYTES, false)?;
        fields.insert(
            "toolCallId".to_string(),
            serde_json::Value::String(tool_call_id),
        );
    }
    bound_render_field(fields, "title", RENDER_TITLE_MAX_BYTES);
    bound_render_field(fields, "rawInput", RENDER_TOOL_DETAIL_MAX_BYTES);
    bound_render_field(fields, "rawOutput", RENDER_TOOL_DETAIL_MAX_BYTES);
    bound_render_field(fields, "locations", RENDER_TOOL_DETAIL_MAX_BYTES);
    bound_render_field(fields, "content", RENDER_TOOL_CONTENT_MAX_BYTES);
    for field in ["rawOutput", "content", "rawInput", "locations"] {
        if serde_json::to_vec(&value).map_or(usize::MAX, |encoded| encoded.len())
            <= RENDER_METADATA_MAX_BYTES
        {
            break;
        }
        let Some(fields) = value.as_object_mut() else {
            break;
        };
        if fields.contains_key(field) {
            fields.insert(
                field.to_string(),
                serde_json::json!({
                    "type": "omitted",
                    "reason": "aggregate_input_limit",
                    "resource": format!("tool_{field}"),
                    "limit": RENDER_METADATA_MAX_BYTES,
                }),
            );
        }
    }
    if serde_json::to_vec(&value).map_or(usize::MAX, |encoded| encoded.len())
        > RENDER_METADATA_MAX_BYTES
    {
        return Err(format!(
            "tool call identity metadata exceeds {RENDER_METADATA_MAX_BYTES} bytes"
        ));
    }
    Ok(Some(value))
}

fn bound_render_field(
    fields: &mut serde_json::Map<String, serde_json::Value>,
    field: &str,
    limit: usize,
) {
    let Some(value) = fields.get(field) else {
        return;
    };
    let encoded_bytes = serde_json::to_vec(value).map_or(usize::MAX, |encoded| encoded.len());
    if encoded_bytes <= limit {
        return;
    }
    fields.insert(
        field.to_string(),
        serde_json::json!({
            "type": "omitted",
            "reason": "input_limit",
            "resource": format!("tool_{field}"),
            "limit": limit,
            "observedAtLeast": encoded_bytes,
        }),
    );
}

fn strip_non_render_fields(value: &mut serde_json::Value) {
    match value {
        serde_json::Value::Object(fields) => {
            fields.remove("_meta");
            fields.remove("annotations");
            for value in fields.values_mut() {
                strip_non_render_fields(value);
            }
        }
        serde_json::Value::Array(values) => {
            for value in values {
                strip_non_render_fields(value);
            }
        }
        _ => {}
    }
}

async fn read_bounded_utf8_line<R>(
    reader: &mut R,
    max_bytes: usize,
) -> std::io::Result<Option<String>>
where
    R: AsyncBufRead + Unpin,
{
    let mut bytes = Vec::with_capacity(max_bytes.min(8 * 1024));
    loop {
        let available = reader.fill_buf().await?;
        if available.is_empty() {
            if bytes.is_empty() {
                return Ok(None);
            }
            break;
        }
        let newline = available.iter().position(|byte| *byte == b'\n');
        let content_bytes = newline.unwrap_or(available.len());
        if content_bytes > max_bytes.saturating_sub(bytes.len()) {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                format!("line exceeds {max_bytes} UTF-8 bytes"),
            ));
        }
        bytes.extend_from_slice(&available[..content_bytes]);
        let consumed = newline.map_or(content_bytes, |index| index + 1);
        reader.consume_unpin(consumed);
        if newline.is_some() {
            break;
        }
    }
    if bytes.last() == Some(&b'\r') {
        bytes.pop();
    }
    String::from_utf8(bytes)
        .map(Some)
        .map_err(|_| std::io::Error::new(std::io::ErrorKind::InvalidData, "line is not UTF-8"))
}

struct LocalAgentTransport {
    config: AgentLaunchConfig,
    sink: EventSink,
}

impl ConnectTo<agent_client_protocol::Client> for LocalAgentTransport {
    async fn connect_to(self, client: impl ConnectTo<Agent>) -> Result<(), AcpError> {
        let mut command = async_process::Command::new(&self.config.command);
        command.args(&self.config.args);
        command.envs(&self.config.environment);
        if let Some(cwd) = self.config.process_cwd.as_deref() {
            let cwd = PathBuf::from(cwd)
                .canonicalize()
                .map_err(AcpError::into_internal_error)?;
            command.current_dir(cwd);
        }
        command
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .kill_on_drop(true);
        let mut child = command.spawn().map_err(AcpError::into_internal_error)?;
        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| AcpError::new(-32603, "failed to open ACP agent stdin"))?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| AcpError::new(-32603, "failed to open ACP agent stdout"))?;
        let stderr = child
            .stderr
            .take()
            .ok_or_else(|| AcpError::new(-32603, "failed to open ACP agent stderr"))?;

        let stderr_sink = self.sink.clone();
        let stderr_future = async move {
            let mut reader = BufReader::new(stderr);
            loop {
                match read_bounded_utf8_line(&mut reader, AGENT_STDERR_LINE_MAX_BYTES).await {
                    Ok(Some(line)) => stderr_sink.emit(RuntimeEvent::StderrLog { line }),
                    Ok(None) => return Ok::<(), AcpError>(()),
                    Err(error) => {
                        stderr_sink.error(None, "stderr_read_failed", error.to_string(), false);
                        return Err(AcpError::into_internal_error(error));
                    }
                }
            }
        };

        let incoming = Box::pin(futures::stream::unfold(
            (BufReader::new(stdout), false),
            async move |(mut reader, finished)| {
                if finished {
                    return None;
                }
                match read_bounded_utf8_line(&mut reader, ACP_PROTOCOL_LINE_MAX_BYTES).await {
                    Ok(Some(line)) => Some((Ok(line), (reader, false))),
                    Ok(None) => None,
                    Err(error) => Some((Err(error), (reader, true))),
                }
            },
        ));
        let outgoing = Box::pin(futures::sink::unfold(
            stdin,
            async move |mut writer, line: String| {
                let mut bytes = line.into_bytes();
                bytes.push(b'\n');
                writer.write_all(&bytes).await?;
                Ok::<_, std::io::Error>(writer)
            },
        ));
        let protocol = ConnectTo::<agent_client_protocol::Client>::connect_to(
            Lines::new(outgoing, incoming),
            client,
        );
        let child_monitor = async move {
            let status = child
                .status()
                .await
                .map_err(AcpError::into_internal_error)?;
            Err::<(), AcpError>(AcpError::new(
                -32603,
                format!("ACP agent process exited with {status}"),
            ))
        };

        let protocol = pin!(protocol);
        let child_monitor = pin!(child_monitor);
        let main = async move {
            match futures::future::select(protocol, child_monitor).await {
                futures::future::Either::Left((result, _))
                | futures::future::Either::Right((result, _)) => result,
            }
        };
        let main = pin!(main);
        let stderr_future = pin!(stderr_future);
        match futures::future::select(main, stderr_future).await {
            futures::future::Either::Left((result, _)) => result,
            futures::future::Either::Right((Ok(()), main)) => main.await,
            futures::future::Either::Right((Err(error), _)) => Err(error),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{
        EVENT_RETAINED_BYTES_MAX, EVENT_SINGLE_BYTES_MAX, EventQueueBudget, EventReceiver,
        EventSink, ProjectedSessionNotification, RENDER_SNAPSHOT_CHUNK_MAX_UPDATES,
        RENDER_SNAPSHOT_CHUNK_TARGET_BYTES, RenderRouter, RenderUpdate, RenderUpdateKind,
        ReplayRenderProjection, RuntimeEvent, RuntimeEventEnvelope, RuntimeHandle,
        SESSION_TITLE_MAX_CHARACTERS, bounded_event_envelope, drop_staged_config_notification,
        normalize_session_title, project_available_commands, project_filesystem_permission,
        project_permission_request, project_render_updates, project_session_config_options,
        project_session_modes, project_session_notification, project_terminal_permission,
        project_tool_render_metadata, read_bounded_utf8_line, strip_non_render_fields,
    };
    use crate::SessionUpdateKind;
    use agent_client_protocol::schema::v1::{
        AvailableCommand, AvailableCommandInput, AvailableCommandsUpdate, PermissionOption,
        PermissionOptionKind, RequestPermissionRequest, SessionConfigOption, SessionMode,
        SessionModeState, SessionNotification, SessionUpdate as AcpSessionUpdate, ToolCallUpdate,
        ToolCallUpdateFields, UnstructuredCommandInput,
    };
    use std::sync::mpsc;
    use std::sync::{Arc, Mutex};
    use std::time::Duration;

    fn test_event_queue(count_capacity: usize, byte_capacity: usize) -> (EventSink, EventReceiver) {
        let (sender, receiver) = mpsc::sync_channel(count_capacity);
        let budget = Arc::new(EventQueueBudget::new(byte_capacity));
        (
            EventSink {
                sender,
                budget: Arc::clone(&budget),
                next_sequence: Arc::new(Mutex::new(1)),
            },
            EventReceiver { receiver, budget },
        )
    }

    #[test]
    fn runtime_join_disconnects_a_full_event_queue_before_waiting() {
        let (command_sender, command_receiver) = tokio::sync::mpsc::channel(1);
        let (sink, event_receiver) = test_event_queue(1, EVENT_RETAINED_BYTES_MAX);
        let (blocked_sender, blocked_receiver) = mpsc::sync_channel(0);
        let worker = std::thread::spawn(move || {
            let _command_receiver = command_receiver;
            sink.emit(RuntimeEvent::StderrLog {
                line: "first".to_string(),
            });
            blocked_sender.send(()).unwrap();
            sink.emit(RuntimeEvent::StderrLog {
                line: "second".to_string(),
            });
        });
        blocked_receiver
            .recv_timeout(Duration::from_secs(1))
            .unwrap();
        let runtime = RuntimeHandle {
            command_sender: Some(command_sender),
            events: Some(event_receiver),
            worker: Some(worker),
        };
        let (finished_sender, finished_receiver) = mpsc::sync_channel(0);
        std::thread::spawn(move || {
            let result = runtime.join();
            finished_sender.send(result).unwrap();
        });
        finished_receiver
            .recv_timeout(Duration::from_secs(1))
            .expect("runtime join must release blocked event producers")
            .unwrap();
    }

    #[test]
    fn event_byte_budget_blocks_until_the_receiver_releases_retained_bytes() {
        let event = RuntimeEvent::StderrLog {
            line: "x".repeat(512),
        };
        let retained_bytes = bounded_event_envelope(1, event.clone()).1;
        let (sink, receiver) = test_event_queue(8, retained_bytes + retained_bytes / 2);
        let (first_sent, first_received) = mpsc::sync_channel(0);
        let (finished_sender, finished_receiver) = mpsc::sync_channel(0);
        std::thread::spawn(move || {
            sink.emit(event.clone());
            first_sent.send(()).unwrap();
            sink.emit(event);
            finished_sender.send(()).unwrap();
        });
        first_received.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(
            finished_receiver
                .recv_timeout(Duration::from_millis(50))
                .is_err(),
            "the second event must wait for retained-byte budget"
        );

        assert!(matches!(
            receiver.recv_timeout(Duration::from_secs(1)).unwrap().event,
            RuntimeEvent::StderrLog { .. }
        ));
        finished_receiver
            .recv_timeout(Duration::from_secs(1))
            .expect("dequeue must release retained-byte budget");
        assert!(matches!(
            receiver.recv_timeout(Duration::from_secs(1)).unwrap().event,
            RuntimeEvent::StderrLog { .. }
        ));
    }

    #[test]
    fn runtime_join_wakes_a_producer_waiting_for_event_byte_budget() {
        let event = RuntimeEvent::StderrLog {
            line: "x".repeat(512),
        };
        let retained_bytes = bounded_event_envelope(1, event.clone()).1;
        let (sink, event_receiver) = test_event_queue(8, retained_bytes + retained_bytes / 2);
        let (command_sender, command_receiver) = tokio::sync::mpsc::channel(1);
        let (first_sent, first_received) = mpsc::sync_channel(0);
        let worker = std::thread::spawn(move || {
            let _command_receiver = command_receiver;
            sink.emit(event.clone());
            first_sent.send(()).unwrap();
            sink.emit(event);
        });
        first_received.recv_timeout(Duration::from_secs(1)).unwrap();
        let runtime = RuntimeHandle {
            command_sender: Some(command_sender),
            events: Some(event_receiver),
            worker: Some(worker),
        };
        let (finished_sender, finished_receiver) = mpsc::sync_channel(0);
        std::thread::spawn(move || {
            finished_sender.send(runtime.join()).unwrap();
        });
        finished_receiver
            .recv_timeout(Duration::from_secs(1))
            .expect("runtime join must wake byte-budget producers")
            .unwrap();
    }

    #[test]
    fn oversized_single_event_is_replaced_before_queueing() {
        let (envelope, retained_bytes) = bounded_event_envelope(
            1,
            RuntimeEvent::StderrLog {
                line: "x".repeat(EVENT_SINGLE_BYTES_MAX + 1),
            },
        );
        assert!(retained_bytes < EVENT_SINGLE_BYTES_MAX);
        assert!(matches!(
            envelope.event,
            RuntimeEvent::RuntimeError { ref code, .. }
                if code == "event_projection_too_large"
        ));
    }

    #[test]
    fn oversized_success_replacement_preserves_request_id() {
        let (envelope, retained_bytes) = bounded_event_envelope(
            1,
            RuntimeEvent::SessionUpdate {
                update: crate::SessionUpdate {
                    session_id: "fixture-session".to_string(),
                    kind: SessionUpdateKind::SessionCreated,
                    text: None,
                    request_id: Some("create-oversized".to_string()),
                    payload: Some(serde_json::json!({
                        "value": "x".repeat(EVENT_SINGLE_BYTES_MAX + 1),
                    })),
                },
            },
        );
        assert!(retained_bytes < EVENT_SINGLE_BYTES_MAX);
        assert!(matches!(
            envelope.event,
            RuntimeEvent::RuntimeError {
                request_id: Some(ref request_id),
                ref code,
                ..
            } if request_id == "create-oversized" && code == "event_projection_too_large"
        ));
    }

    #[test]
    fn oversized_runtime_error_is_truncated_without_losing_request_id() {
        let (sink, receiver) = test_event_queue(1, EVENT_RETAINED_BYTES_MAX);
        sink.error(
            Some("list-oversized".to_string()),
            "c".repeat(EVENT_SINGLE_BYTES_MAX),
            "界".repeat(EVENT_SINGLE_BYTES_MAX),
            true,
        );
        let envelope = receiver.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(serde_json::to_vec(&envelope).unwrap().len() < EVENT_SINGLE_BYTES_MAX);
        assert!(matches!(
            envelope.event,
            RuntimeEvent::RuntimeError {
                request_id: Some(ref request_id),
                ref code,
                ref message,
                ..
            } if request_id == "list-oversized"
                && code.len() <= super::EVENT_ERROR_CODE_MAX_BYTES
                && message.len() <= super::EVENT_ERROR_MESSAGE_MAX_BYTES
                && message.is_char_boundary(message.len())
        ));
    }

    #[test]
    fn bounded_line_reader_rejects_before_growing_past_the_limit() {
        futures::executor::block_on(async {
            let mut reader =
                futures::io::BufReader::new(futures::io::Cursor::new(b"12345\nnext\r\n".to_vec()));
            let error = read_bounded_utf8_line(&mut reader, 4)
                .await
                .expect_err("oversized line");
            assert_eq!(error.kind(), std::io::ErrorKind::InvalidData);

            let mut reader =
                futures::io::BufReader::new(futures::io::Cursor::new(b"1234\r\nnext\n".to_vec()));
            assert_eq!(
                read_bounded_utf8_line(&mut reader, 5).await.unwrap(),
                Some("1234".to_string())
            );
            assert_eq!(
                read_bounded_utf8_line(&mut reader, 5).await.unwrap(),
                Some("next".to_string())
            );
        });
    }

    #[test]
    fn permission_projection_rejects_oversized_raw_input_and_option_floods() {
        let oversized_raw_input = RequestPermissionRequest::new(
            "session-1",
            ToolCallUpdate::new(
                "tool-1",
                ToolCallUpdateFields::new().raw_input(serde_json::json!({
                    "payload": "x".repeat(super::PERMISSION_MAX_RAW_INPUT_BYTES),
                })),
            ),
            vec![PermissionOption::new(
                "allow",
                "Allow",
                PermissionOptionKind::AllowOnce,
            )],
        );
        assert!(project_permission_request("request-1", &oversized_raw_input).is_err());

        let option_flood = RequestPermissionRequest::new(
            "session-1",
            ToolCallUpdate::new("tool-1", ToolCallUpdateFields::new()),
            (0..=super::PERMISSION_MAX_OPTIONS)
                .map(|index| {
                    PermissionOption::new(
                        format!("option-{index}"),
                        format!("Option {index}"),
                        PermissionOptionKind::AllowOnce,
                    )
                })
                .collect(),
        );
        assert!(project_permission_request("request-2", &option_flood).is_err());
    }

    #[test]
    fn terminal_permission_projection_discloses_bounded_environment() {
        let approval = crate::TerminalApproval {
            approval_id: "approval-1".to_string(),
            session_id: "session-1".to_string(),
            command: vec!["git".to_string(), "status".to_string()],
            environment: vec![crate::TerminalEnvironmentVariable {
                name: "LD_PRELOAD".to_string(),
                value: "/workspace/injected.so".to_string(),
            }],
            cwd: "/workspace".to_string(),
        };
        let projection = project_terminal_permission(&approval).unwrap();
        assert_eq!(
            projection.raw_input.as_ref().unwrap()["environment"][0]["name"],
            "LD_PRELOAD"
        );
        assert_eq!(
            projection.raw_input.as_ref().unwrap()["environment"][0]["value"],
            "/workspace/injected.so"
        );
    }

    #[test]
    fn filesystem_permission_projection_discloses_write_preview_and_read_range() {
        let write = crate::FilesystemApproval {
            approval_id: "write-1".to_string(),
            session_id: "session-1".to_string(),
            kind: crate::FilesystemOperationKind::Write,
            path: "/workspace/main.rs".to_string(),
            line: None,
            limit: None,
            write_bytes: Some(12),
            content_preview: Some("fn main() {}".to_string()),
            content_truncated: Some(false),
        };
        let projection = project_filesystem_permission(&write).unwrap();
        let input = projection.raw_input.unwrap();
        assert_eq!(input["writeBytes"], 12);
        assert_eq!(input["contentPreview"], "fn main() {}");
        assert_eq!(input["contentTruncated"], false);

        let read = crate::FilesystemApproval {
            approval_id: "read-1".to_string(),
            session_id: "session-1".to_string(),
            kind: crate::FilesystemOperationKind::Read,
            path: "/workspace/main.rs".to_string(),
            line: Some(20),
            limit: Some(5),
            write_bytes: None,
            content_preview: None,
            content_truncated: None,
        };
        let input = project_filesystem_permission(&read)
            .unwrap()
            .raw_input
            .unwrap();
        assert_eq!(input["line"], 20);
        assert_eq!(input["limit"], 5);
    }

    #[test]
    fn session_config_projection_rejects_oversized_strings_and_total_bytes() {
        let oversized_name = SessionConfigOption::boolean(
            "bounded",
            "x".repeat(super::SESSION_CONFIG_MAX_TEXT_BYTES + 1),
            false,
        );
        assert!(project_session_config_options(Some(&[oversized_name])).is_err());

        let options = (0..40)
            .map(|index| {
                SessionConfigOption::boolean(format!("option-{index}"), "Option", false)
                    .description("x".repeat(super::SESSION_CONFIG_MAX_TEXT_BYTES))
            })
            .collect::<Vec<_>>();
        assert!(project_session_config_options(Some(&options)).is_err());
    }

    #[test]
    fn failed_session_completion_drops_its_staged_config_before_retry() {
        let mut staged = std::collections::HashMap::from([(
            "retry-session".to_string(),
            (Vec::new(), 42_usize),
        )]);
        let mut bytes = 42_usize;
        drop_staged_config_notification(&mut staged, &mut bytes, "retry-session");
        assert!(staged.is_empty());
        assert_eq!(bytes, 0);
    }

    #[test]
    fn modes_and_commands_reject_aggregate_projection_over_budget() {
        let modes = SessionModeState::new(
            "mode-0",
            (0..40)
                .map(|index| {
                    SessionMode::new(
                        format!("mode-{index}"),
                        format!(
                            "{index}-{}",
                            "x".repeat(super::SESSION_MODE_TEXT_MAX_BYTES - 8)
                        ),
                    )
                })
                .collect(),
        );
        assert!(project_session_modes(&modes).is_err());

        let commands = (0..80)
            .map(|index| {
                AvailableCommand::new(
                    format!("command-{index}"),
                    "x".repeat(super::AVAILABLE_COMMAND_DESCRIPTION_MAX_BYTES),
                )
            })
            .collect::<Vec<_>>();
        assert!(project_available_commands(&commands).is_err());
    }

    #[test]
    fn session_titles_are_normalized_and_bounded() {
        let long_title = format!(
            "  {}\nignored  ",
            "会".repeat(SESSION_TITLE_MAX_CHARACTERS + 44)
        );

        let normalized = normalize_session_title(&long_title).expect("title");

        assert_eq!(normalized.chars().count(), SESSION_TITLE_MAX_CHARACTERS);
        assert!(normalized.ends_with('…'));
        assert_eq!(
            normalize_session_title("  Slow\n\nstartup\t diagnosis  ").as_deref(),
            Some("Slow startup diagnosis")
        );
        assert_eq!(normalize_session_title(" \n\t "), None);
    }

    #[test]
    fn render_projection_removes_protocol_only_fields_recursively() {
        let mut value = serde_json::json!({
            "toolCallId": "tool-1",
            "_meta": {"huge": "invisible"},
            "content": [{
                "type": "content",
                "annotations": {"audience": ["assistant"]},
                "content": {
                    "type": "image",
                    "data": "AA==",
                    "mimeType": "image/png",
                    "_meta": {"private": true}
                }
            }]
        });

        strip_non_render_fields(&mut value);

        let encoded = serde_json::to_string(&value).unwrap();
        assert!(!encoded.contains("_meta"));
        assert!(!encoded.contains("annotations"));
        assert_eq!(value["toolCallId"], "tool-1");
        assert_eq!(value["content"][0]["content"]["data"], "AA==");
    }

    #[test]
    fn aggregate_tool_metadata_omission_preserves_identity_and_status() {
        let metadata = project_tool_render_metadata(serde_json::json!({
            "toolCallId": "tool-1",
            "status": "completed",
            "kind": "edit",
            "title": "x".repeat(super::RENDER_TITLE_MAX_BYTES - 2),
            "rawInput": "x".repeat(super::RENDER_TOOL_DETAIL_MAX_BYTES - 2),
            "rawOutput": "x".repeat(super::RENDER_TOOL_DETAIL_MAX_BYTES - 2),
            "locations": "x".repeat(super::RENDER_TOOL_DETAIL_MAX_BYTES - 2),
            "content": "x".repeat(super::RENDER_TOOL_CONTENT_MAX_BYTES - 2),
        }))
        .unwrap()
        .unwrap();
        assert_eq!(metadata["toolCallId"], "tool-1");
        assert_eq!(metadata["status"], "completed");
        assert!(serde_json::to_vec(&metadata).unwrap().len() <= super::RENDER_METADATA_MAX_BYTES);
        assert!(
            ["rawOutput", "content", "rawInput", "locations"]
                .iter()
                .any(|field| metadata[*field]["type"] == "omitted")
        );
    }

    #[test]
    fn oversized_live_text_is_utf8_safely_split_before_event_queueing() {
        let text = "界".repeat(super::RENDER_TEXT_CHUNK_MAX_BYTES);
        let updates = project_render_updates(
            "session-1".to_string(),
            RenderUpdateKind::AssistantText,
            text.clone(),
            None,
        );
        assert!(updates.len() > 1);
        assert_eq!(
            updates
                .iter()
                .map(|update| update.text.as_str())
                .collect::<String>(),
            text
        );
        for update in updates {
            let (envelope, retained_bytes) =
                bounded_event_envelope(1, RuntimeEvent::RenderUpdate { update });
            assert!(retained_bytes < EVENT_SINGLE_BYTES_MAX);
            assert!(matches!(envelope.event, RuntimeEvent::RenderUpdate { .. }));
        }
    }

    #[test]
    fn replay_does_not_coalesce_content_metadata_past_its_budget() {
        let mut projection = ReplayRenderProjection::default();
        for suffix in ["a", "b"] {
            let _ = projection.push(RenderUpdate {
                session_id: "session-1".to_string(),
                kind: RenderUpdateKind::UserMessage,
                text: suffix.to_string(),
                metadata: Some(serde_json::json!({
                    "contentBlocks": [{"data": "x".repeat(600 * 1024)}],
                })),
            });
        }
        assert_eq!(projection.updates.len(), 2);
        for update in projection.updates {
            assert!(serde_json::to_vec(&update).unwrap().len() < EVENT_SINGLE_BYTES_MAX);
        }
    }

    #[test]
    fn available_commands_project_to_bounded_session_state() {
        let notification = SessionNotification::new(
            "session-1",
            AcpSessionUpdate::AvailableCommandsUpdate(AvailableCommandsUpdate::new(vec![
                AvailableCommand::new("review", "Review the current change.").input(
                    AvailableCommandInput::Unstructured(UnstructuredCommandInput::new("[focus]")),
                ),
            ])),
        );

        let projected = project_session_notification(notification)
            .expect("valid command update")
            .expect("projected command update");
        let ProjectedSessionNotification::Control(update) = projected else {
            panic!("expected control update");
        };

        assert_eq!(update.kind, SessionUpdateKind::CommandsChanged);
        let commands = update.payload.unwrap()["availableCommands"]
            .as_array()
            .unwrap()
            .clone();
        assert_eq!(commands.len(), 1);
        assert_eq!(commands[0]["name"], "review");
        assert_eq!(commands[0]["description"], "Review the current change.");
        assert_eq!(commands[0]["input"]["hint"], "[focus]");
        assert!(!commands[0].to_string().contains("_meta"));
    }

    #[test]
    fn replay_projection_coalesces_text_and_merges_tool_updates_in_rust() {
        let mut projection = ReplayRenderProjection {
            request_id: "restore-1".to_string(),
            updates: Vec::new(),
            ..ReplayRenderProjection::default()
        };
        for text in ["hel", "lo"] {
            let _ = projection.push(RenderUpdate {
                session_id: "session-1".to_string(),
                kind: RenderUpdateKind::AssistantText,
                text: text.to_string(),
                metadata: None,
            });
        }
        let _ = projection.push(RenderUpdate {
            session_id: "session-1".to_string(),
            kind: RenderUpdateKind::ToolCall,
            text: "Read file".to_string(),
            metadata: Some(serde_json::json!({
                "toolCallId": "tool-1",
                "status": "in_progress"
            })),
        });
        let _ = projection.push(RenderUpdate {
            session_id: "session-1".to_string(),
            kind: RenderUpdateKind::ToolCall,
            text: String::new(),
            metadata: Some(serde_json::json!({
                "toolCallId": "tool-1",
                "status": "completed",
                "rawOutput": "done"
            })),
        });

        assert_eq!(projection.updates.len(), 2);
        assert_eq!(projection.updates[0].text, "hello");
        assert_eq!(projection.updates[1].text, "Read file");
        assert_eq!(
            projection.updates[1].metadata.as_ref().unwrap()["status"],
            "completed"
        );
        assert_eq!(
            projection.updates[1].metadata.as_ref().unwrap()["rawOutput"],
            "done"
        );
    }

    #[test]
    fn foreground_replay_transfers_completed_turn_before_finish() {
        let (sink, receiver) = test_event_queue(16, EVENT_RETAINED_BYTES_MAX);
        let router = RenderRouter::new(sink);
        router.begin_replay("session-1".to_string(), "restore-1".to_string());

        for turn in 0..8 {
            for (kind, text) in [
                (RenderUpdateKind::UserMessage, format!("question {turn}")),
                (RenderUpdateKind::AssistantText, format!("answer {turn}")),
            ] {
                router.route(RenderUpdate {
                    session_id: "session-1".to_string(),
                    kind,
                    text,
                    metadata: None,
                });
            }
        }
        assert!(receiver.try_recv().is_err());

        router.route(RenderUpdate {
            session_id: "session-1".to_string(),
            kind: RenderUpdateKind::UserMessage,
            text: "final question".to_string(),
            metadata: None,
        });
        let first = receiver.try_recv().expect("completed replay turn");
        let RuntimeEvent::RenderSnapshotChunk {
            chunk_index,
            is_last,
            updates,
            ..
        } = first.event
        else {
            panic!("unexpected runtime event");
        };
        assert_eq!(chunk_index, 0);
        assert!(!is_last);
        assert_eq!(updates.len(), RENDER_SNAPSHOT_CHUNK_MAX_UPDATES);
        assert_eq!(updates[0].text, "question 0");
        assert_eq!(updates[15].text, "answer 7");

        router.route(RenderUpdate {
            session_id: "session-1".to_string(),
            kind: RenderUpdateKind::AssistantText,
            text: "final answer".to_string(),
            metadata: None,
        });
        router.finish_replay("session-1", "restore-1");

        let final_chunk = receiver.try_recv().expect("final replay turn");
        let RuntimeEvent::RenderSnapshotChunk {
            chunk_index,
            is_last,
            updates,
            ..
        } = final_chunk.event
        else {
            panic!("unexpected runtime event");
        };
        assert_eq!(chunk_index, 1);
        assert!(is_last);
        assert_eq!(updates.len(), 2);
        assert_eq!(updates[0].text, "final question");
        assert_eq!(updates[1].text, "final answer");
        assert!(receiver.try_recv().is_err());
    }

    #[test]
    fn background_recovery_replay_never_crosses_the_event_queue() {
        let (sink, receiver) = test_event_queue(16, EVENT_RETAINED_BYTES_MAX);
        let router = RenderRouter::new(sink);
        router.begin_recovery_replay("session-1".to_string(), "recovery:1".to_string());

        for (kind, text) in [
            (RenderUpdateKind::UserMessage, "first question"),
            (RenderUpdateKind::AssistantText, "first answer"),
            (RenderUpdateKind::UserMessage, "second question"),
        ] {
            router.route(RenderUpdate {
                session_id: "session-1".to_string(),
                kind,
                text: text.to_string(),
                metadata: None,
            });
        }
        assert!(receiver.try_recv().is_err());

        router.abort_replay("recovery:1");
        assert!(receiver.try_recv().is_err());
    }

    #[test]
    fn replay_snapshot_is_split_before_the_ffi_queue() {
        let (sink, receiver) = test_event_queue(16, EVENT_RETAINED_BYTES_MAX);
        let router = RenderRouter::new(sink);
        let updates = (0..=(RENDER_SNAPSHOT_CHUNK_MAX_UPDATES * 2))
            .map(|index| RenderUpdate {
                session_id: "session-1".to_string(),
                kind: RenderUpdateKind::AssistantText,
                text: index.to_string(),
                metadata: None,
            })
            .collect();

        router.emit_snapshot_chunks("restore-1", "session-1", 0, true, updates);

        let envelopes = receiver.try_iter().collect::<Vec<RuntimeEventEnvelope>>();
        assert_eq!(envelopes.len(), 3);
        for (index, envelope) in envelopes.iter().enumerate() {
            let RuntimeEvent::RenderSnapshotChunk {
                chunk_index,
                is_last,
                updates,
                ..
            } = &envelope.event
            else {
                panic!("unexpected event: {:?}", envelope.event);
            };
            assert_eq!(*chunk_index as usize, index);
            assert_eq!(*is_last, index == 2);
            assert!(updates.len() <= RENDER_SNAPSHOT_CHUNK_MAX_UPDATES);
            let encoded_bytes = serde_json::to_vec(updates).unwrap().len();
            assert!(encoded_bytes <= RENDER_SNAPSHOT_CHUNK_TARGET_BYTES);
        }
    }

    #[test]
    fn replay_snapshot_is_split_by_render_byte_budget() {
        let (sink, receiver) = test_event_queue(16, EVENT_RETAINED_BYTES_MAX);
        let router = RenderRouter::new(sink);
        let updates = (0..4)
            .map(|_| RenderUpdate {
                session_id: "session-1".to_string(),
                kind: RenderUpdateKind::AssistantText,
                text: "x".repeat(RENDER_SNAPSHOT_CHUNK_TARGET_BYTES / 3),
                metadata: None,
            })
            .collect();

        router.emit_snapshot_chunks("restore-1", "session-1", 0, true, updates);

        let envelopes = receiver.try_iter().collect::<Vec<RuntimeEventEnvelope>>();
        assert_eq!(envelopes.len(), 2);
        for envelope in envelopes {
            let RuntimeEvent::RenderSnapshotChunk { updates, .. } = envelope.event else {
                panic!("unexpected runtime event");
            };
            assert_eq!(updates.len(), 2);
            assert!(
                serde_json::to_vec(&updates).unwrap().len() <= RENDER_SNAPSHOT_CHUNK_TARGET_BYTES
            );
        }
    }
}
