use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::pin::pin;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, SyncSender, TryRecvError};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use agent_client_protocol::schema::ProtocolVersion;
use agent_client_protocol::schema::v1::{
    AuthMethod, AuthenticateRequest, CancelNotification, ClientCapabilities, CloseSessionRequest,
    ContentBlock, CreateTerminalRequest, CreateTerminalResponse, DeleteSessionRequest, EnvVariable,
    FileSystemCapabilities, HttpHeader, InitializeRequest, KillTerminalRequest,
    KillTerminalResponse, ListSessionsRequest, LoadSessionRequest, LogoutRequest,
    McpServer as AcpMcpServer, McpServerHttp, McpServerSse, McpServerStdio, NewSessionRequest,
    NewSessionResponse, PermissionOptionKind, PromptRequest, ReadTextFileRequest,
    ReadTextFileResponse, ReleaseTerminalRequest, ReleaseTerminalResponse,
    RequestPermissionOutcome, RequestPermissionRequest, RequestPermissionResponse,
    ResumeSessionRequest, SelectedPermissionOutcome, SessionConfigKind, SessionConfigOption,
    SessionConfigOptionValue, SessionConfigSelectOptions, SessionInfo, SessionModeState,
    SessionNotification, SessionUpdate as AcpSessionUpdate, SetSessionConfigOptionRequest,
    SetSessionModeRequest, StopReason, TerminalExitStatus, TerminalOutputRequest,
    TerminalOutputResponse, WaitForTerminalExitRequest, WaitForTerminalExitResponse,
    WriteTextFileRequest, WriteTextFileResponse,
};
use agent_client_protocol::{Agent, ConnectTo, ConnectionTo, Error as AcpError, Lines, Responder};
use futures::io::BufReader;
use futures::{AsyncBufReadExt, AsyncWriteExt, StreamExt};
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
const DEFAULT_PERMISSION_TIMEOUT: Duration = Duration::from_secs(120);
const DEFAULT_MAX_RESTART_ATTEMPTS: u32 = 2;
const DEFAULT_RESTART_BASE_DELAY: Duration = Duration::from_millis(250);
const SESSION_LIST_MAX_PAGES: usize = 100;
const SESSION_LIST_MAX_ENTRIES: usize = 10_000;
const SESSION_LIST_MAX_CURSOR_BYTES: usize = 8 * 1024;
const SESSION_TITLE_MAX_CHARACTERS: usize = 256;
const SESSION_CONFIG_MAX_OPTIONS: usize = 256;
const SESSION_CONFIG_MAX_CHOICES: usize = 4_096;
// Keep replay projection work below a frame-sized slice once it crosses FFI.
// The Dart host cooperatively drains several chunks instead of projecting a
// whole restored transcript in one event-loop turn.
const RENDER_SNAPSHOT_CHUNK_TARGET_BYTES: usize = 64 * 1024;
const RENDER_SNAPSHOT_CHUNK_MAX_UPDATES: usize = 16;
const RENDER_COALESCED_TEXT_TARGET_BYTES: usize = RENDER_SNAPSHOT_CHUNK_TARGET_BYTES / 2;
const RENDER_TOOL_DETAIL_MAX_BYTES: usize = 128 * 1024;
const RENDER_TOOL_CONTENT_MAX_BYTES: usize = 512 * 1024;
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
    agent_name: String,
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
        let active = store
            .as_mut()
            .map(|store| store.load_active(&config.agent_name))
            .transpose()
            .map_err(|error| error.to_string())?
            .unwrap_or_default()
            .into_iter()
            .map(|session| (session.session_id.clone(), session))
            .collect();
        Ok(Self {
            agent_name: config.agent_name.clone(),
            active,
            store,
        })
    }

    fn activate(&mut self, session_id: &str, scope: &WorkspaceScope) -> Result<(), String> {
        let session =
            PersistedSession::from_scope(self.agent_name.clone(), session_id.to_string(), scope);
        if let Some(store) = self.store.as_mut() {
            store.upsert(&session).map_err(|error| error.to_string())?;
        }
        self.active.insert(session_id.to_string(), session);
        Ok(())
    }

    fn remove(&mut self, session_id: &str) -> Result<(), String> {
        if let Some(store) = self.store.as_mut() {
            store
                .remove(&self.agent_name, session_id)
                .map_err(|error| error.to_string())?;
        }
        self.active.remove(session_id);
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
}

#[derive(Clone)]
struct EventSink {
    sender: SyncSender<RuntimeEventEnvelope>,
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
        // A bounded, blocking send is intentional: protocol producers apply
        // backpressure instead of letting a stalled UI grow memory unbounded.
        // The sequence lock remains held through send so concurrent PTY,
        // stderr, and protocol producers cannot enqueue out of sequence.
        let _ = self.sender.send(RuntimeEventEnvelope::new(sequence, event));
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
            code: code.into(),
            message: message.into(),
            recoverable,
        });
    }
}

#[derive(Default)]
struct ReplayRenderProjection {
    request_id: String,
    updates: Vec<RenderUpdate>,
}

impl ReplayRenderProjection {
    fn push(&mut self, update: RenderUpdate) {
        if self.coalesce_adjacent_text(&update) || self.merge_tool_update(&update) {
            return;
        }
        self.updates.push(update);
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
}

impl RenderRouter {
    fn new(sink: EventSink) -> Self {
        Self {
            sink,
            replay: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    fn begin_replay(&self, session_id: String, request_id: String) {
        self.replay
            .lock()
            .expect("render replay mutex poisoned")
            .insert(
                session_id,
                ReplayRenderProjection {
                    request_id,
                    updates: Vec::new(),
                },
            );
    }

    fn route(&self, update: RenderUpdate) {
        let mut replay = self.replay.lock().expect("render replay mutex poisoned");
        if let Some(projection) = replay.get_mut(&update.session_id) {
            projection.push(update);
            return;
        }
        std::mem::drop(replay);
        self.sink.emit(RuntimeEvent::RenderUpdate { update });
    }

    fn finish_replay(&self, session_id: &str, request_id: &str) {
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
        self.emit_snapshot_chunks(request_id, session_id, projection.updates);
    }

    fn abort_replay(&self, request_id: &str) {
        self.replay
            .lock()
            .expect("render replay mutex poisoned")
            .retain(|_, projection| projection.request_id != request_id);
    }

    fn emit_snapshot_chunks(&self, request_id: &str, session_id: &str, updates: Vec<RenderUpdate>) {
        if updates.is_empty() {
            return;
        }
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
        let last_index = chunks.len().saturating_sub(1);
        for (index, updates) in chunks.into_iter().enumerate() {
            self.sink.emit(RuntimeEvent::RenderSnapshotChunk {
                request_id: request_id.to_string(),
                session_id: session_id.to_string(),
                chunk_index: u32::try_from(index).unwrap_or(u32::MAX),
                is_last: index == last_index,
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
    command_sender: tokio_mpsc::Sender<RuntimeCommand>,
    events: Receiver<RuntimeEventEnvelope>,
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
        let (event_sender, events) = mpsc::sync_channel(EVENT_CAPACITY);
        let sink = EventSink {
            sender: event_sender,
            next_sequence: Arc::new(Mutex::new(1)),
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
            command_sender,
            events,
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
        match self.events.try_recv() {
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
        match self.events.recv_timeout(timeout) {
            Ok(event) => Ok(Some(event)),
            Err(RecvTimeoutError::Timeout) => Ok(None),
            Err(RecvTimeoutError::Disconnected) => Err(RuntimeError::Closed),
        }
    }

    pub fn join(mut self) -> Result<(), RuntimeError> {
        let _ = self.dispose();
        if let Some(worker) = self.worker.take() {
            worker.join().map_err(|_| RuntimeError::WorkerPanicked)?;
        }
        Ok(())
    }

    fn send(&self, command: RuntimeCommand) -> Result<(), RuntimeError> {
        self.command_sender
            .try_send(command)
            .map_err(|error| match error {
                tokio_mpsc::error::TrySendError::Full(_) => RuntimeError::Backpressure,
                tokio_mpsc::error::TrySendError::Closed(_) => RuntimeError::Closed,
            })
    }
}

impl Drop for RuntimeHandle {
    fn drop(&mut self) {
        let _ = self.command_sender.try_send(RuntimeCommand::Dispose);
    }
}

fn checked_request_id(value: String) -> Result<String, RuntimeError> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        Err(RuntimeError::InvalidRequestId)
    } else if trimmed.len() == value.len() {
        Ok(value)
    } else {
        Ok(trimmed.to_string())
    }
}

fn checked_session_id(value: String) -> Result<String, RuntimeError> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
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
                    Ok(Some(ProjectedSessionNotification::Render(update))) => {
                        notification_render_router.route(update);
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
                let projection = project_permission_request(&request_id, &request);
                let session_id = request.session_id.to_string();
                permission_pending
                    .lock()
                    .expect("permission mutex poisoned")
                    .insert(
                        request_id.clone(),
                        PendingPermission::Acp {
                            session_id: session_id.clone(),
                            responder,
                        },
                    );
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
                let request_id = approval.approval_id.clone();
                let session_id = approval.session_id.clone();
                filesystem_pending
                    .lock()
                    .expect("permission mutex poisoned")
                    .insert(
                        request_id.clone(),
                        PendingPermission::FilesystemRead {
                            session_id: session_id.clone(),
                            approval_id: approval.approval_id.clone(),
                            manager,
                            responder,
                        },
                    );
                filesystem_permission_sink.emit(RuntimeEvent::PermissionRequest {
                    request: project_filesystem_permission(&approval),
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
                let request_id = approval.approval_id.clone();
                let session_id = approval.session_id.clone();
                filesystem_write_pending
                    .lock()
                    .expect("permission mutex poisoned")
                    .insert(
                        request_id.clone(),
                        PendingPermission::FilesystemWrite {
                            session_id: session_id.clone(),
                            approval_id: approval.approval_id.clone(),
                            manager,
                            responder,
                        },
                    );
                filesystem_write_permission_sink.emit(RuntimeEvent::PermissionRequest {
                    request: project_filesystem_permission(&approval),
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
                let request_id = approval.approval_id.clone();
                let session_id = approval.session_id.clone();
                terminal_pending
                    .lock()
                    .expect("permission mutex poisoned")
                    .insert(
                        request_id.clone(),
                        PendingPermission::Terminal {
                            session_id: session_id.clone(),
                            approval_id: approval.approval_id.clone(),
                            manager,
                            responder,
                        },
                    );
                terminal_permission_sink.emit(RuntimeEvent::PermissionRequest {
                    request: project_terminal_permission(&approval),
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
                if recover_sessions {
                    state
                        .reset_sessions_for_recovery()
                        .map_err(|error| AcpError::new(-32603, error.to_string()))?;
                }
                state
                    .agent_ready()
                    .map_err(|error| AcpError::new(-32603, error.to_string()))?;
                let session_support = session_support(&response.agent_capabilities);
                let prompt_support = PromptSupport::from_agent(&response.agent_capabilities);
                let mcp_servers = project_mcp_servers(
                    &config.mcp_servers,
                    &response.agent_capabilities.mcp_capabilities,
                )
                .map_err(|message| AcpError::new(-32603, message))?;
                let auth_methods = project_auth_methods(&response.auth_methods);
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
                let detail = response.agent_info.as_ref().map_or_else(
                    || format!("{} ready", config.agent_name),
                    |info| format!("{} {} ready", info.name, info.version),
                );
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
                    .await
                    .map_err(|message| AcpError::new(-32603, message))?;
                    if !recovered.scopes.is_empty() {
                        command_activity.store(true, Ordering::Release);
                    }
                    recovered
                } else {
                    RecoveredRuntimeSessions::default()
                };
                sink.emit(RuntimeEvent::StatusChanged {
                    status: RuntimeStatus::Ready,
                    detail: Some(detail),
                    capabilities: Some(capabilities),
                });

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
                    modes: response.modes.as_ref().map(project_session_modes),
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
                    modes: response.modes.as_ref().map(project_session_modes),
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
) -> Result<RecoveredRuntimeSessions, String> {
    let sessions = registry.sessions();
    if !sessions.is_empty() && !support.load && !support.resume {
        return Err(
            "agent cannot recover durable sessions because it supports neither session/load nor session/resume"
                .to_string(),
        );
    }
    let mut recovered = RecoveredRuntimeSessions::default();
    for session in sessions {
        let scope = session.scope().map_err(|error| error.to_string())?;
        let recovery_request_id = format!("recovery:{}", session.session_id);
        if support.load {
            render_router.begin_replay(session.session_id.clone(), recovery_request_id.clone());
        }
        let restored =
            match restore_wire_session(connection, &session, &scope, support, mcp_servers).await {
                Ok(restored) => restored,
                Err(error) => {
                    render_router.abort_replay(&recovery_request_id);
                    return Err(error);
                }
            };
        // Recovery re-establishes protocol state; the existing UI transcript
        // remains authoritative. Never transfer a replay with no foreground
        // restore consumer.
        render_router.abort_replay(&recovery_request_id);
        if let Some(manager) = terminal_manager {
            manager
                .register_session(&restored.session_id, scope.clone())
                .map_err(|error| error.to_string())?;
        }
        if let Some(manager) = filesystem_manager {
            manager
                .register_session(&restored.session_id, scope.clone())
                .map_err(|error| error.to_string())?;
        }
        state
            .session_created(restored.session_id.clone())
            .map_err(|error| error.to_string())?;
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
    Ok(recovered)
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
    let mut pending_config_notifications =
        HashMap::<String, Vec<SessionConfigOptionProjection>>::new();
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
                        let sent = connection.send_request(request);
                        let tx = internal_sender.clone();
                        let terminal_manager = terminal_manager.clone();
                        let terminal_scope = scope.clone();
                        let filesystem_manager = filesystem_manager.clone();
                        let filesystem_scope = scope.clone();
                        connection.spawn(async move {
                            let result = sent.block_task().await
                                .map_err(|error| error.to_string())
                                .and_then(|response| project_created_session(&response))
                                .and_then(|created| {
                                    if let Some(manager) = terminal_manager {
                                        manager
                                            .register_session(&created.session_id, terminal_scope)
                                            .map_err(|error| error.to_string())?;
                                    }
                                    if let Some(manager) = filesystem_manager {
                                        manager
                                            .register_session(
                                                &created.session_id,
                                                filesystem_scope,
                                            )
                                            .map_err(|error| error.to_string())?;
                                    }
                                    Ok(created)
                                });
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
                        let terminal_manager = terminal_manager.clone();
                        let filesystem_manager = filesystem_manager.clone();
                        let restore_mcp_servers = mcp_servers.clone();
                        let will_replay_history =
                            (replay_history && session_support.load) || !session_support.resume;
                        if will_replay_history {
                            render_router.begin_replay(session_id.clone(), request_id.clone());
                        }
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
                                        modes: response.modes.as_ref().map(project_session_modes),
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
                                        modes: response.modes.as_ref().map(project_session_modes),
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
                                        modes: response.modes.as_ref().map(project_session_modes),
                                        replayed_history: true,
                                        config_options: project_session_config_options(
                                            response.config_options.as_deref(),
                                        )?,
                                    }))
                            }
                            .and_then(|restored| {
                                if let Some(manager) = terminal_manager {
                                    manager
                                        .register_session(
                                            &restored.session_id,
                                            request_scope.clone(),
                                        )
                                        .map_err(|error| error.to_string())?;
                                }
                                if let Some(manager) = filesystem_manager {
                                    manager
                                        .register_session(&restored.session_id, request_scope)
                                        .map_err(|error| error.to_string())?;
                                }
                                Ok(restored)
                            });
                            let _ = tx.send(InternalEvent::SessionRestored {
                                request_id,
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
                    InternalEvent::SessionCreated { request_id, cwd, scope, result } => match result {
                        Ok(created) => {
                            let session_id = created.session_id;
                            if let Err(message) = session_registry.activate(&session_id, &scope) {
                                if let Some(manager) = terminal_manager.as_ref() {
                                    let _ = manager.close_session(&session_id);
                                }
                                if let Some(manager) = filesystem_manager.as_ref() {
                                    let _ = manager.close_session(&session_id);
                                }
                                sink.error(
                                    Some(request_id),
                                    "session_store_failed",
                                    message,
                                    false,
                                );
                                continue;
                            }
                            if let Err(error) = state.session_created(session_id.clone()) {
                                sink.error(Some(request_id), "invalid_session_state", error.to_string(), false);
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
                            if let Some(options) = pending_config_notifications.remove(&session_id) {
                                config_options_by_session.insert(session_id.clone(), options.clone());
                                emit_config_changed(&sink, session_id, None, &options);
                            }
                        }
                        Err(message) => sink.error(Some(request_id), "create_session_failed", message, true),
                    },
                    InternalEvent::SessionRestored { request_id, cwd, scope, result } => match result {
                        Ok(restored) => {
                            let session_id = restored.session_id;
                            if let Err(message) = session_registry.activate(&session_id, &scope) {
                                if let Some(manager) = terminal_manager.as_ref() {
                                    let _ = manager.close_session(&session_id);
                                }
                                if let Some(manager) = filesystem_manager.as_ref() {
                                    let _ = manager.close_session(&session_id);
                                }
                                sink.error(
                                    Some(request_id),
                                    "session_store_failed",
                                    message,
                                    false,
                                );
                                continue;
                            }
                            if let Err(error) = state.session_created(session_id.clone()) {
                                sink.error(Some(request_id), "invalid_session_state", error.to_string(), false);
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
                            if let Some(options) = pending_config_notifications.remove(&session_id) {
                                config_options_by_session.insert(session_id.clone(), options.clone());
                                emit_config_changed(&sink, session_id, None, &options);
                            }
                        }
                        Err(message) => {
                            render_router.abort_replay(&request_id);
                            sink.error(Some(request_id), "restore_session_failed", message, true);
                        }
                    },
                    InternalEvent::SessionCataloged { request_id, result } => match result {
                        Ok(sessions) => sink.emit(RuntimeEvent::SessionCatalog {
                            request_id,
                            sessions,
                        }),
                        Err(message) => sink.error(Some(request_id), "list_sessions_failed", message, true),
                    },
                    InternalEvent::SessionClosed { request_id, session_id, result } => match result {
                        Ok(()) => {
                            if let Err(message) = session_registry.remove(&session_id) {
                                sink.error(
                                    Some(request_id),
                                    "session_store_failed",
                                    message,
                                    false,
                                );
                                continue;
                            }
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
                            pending_config_notifications.remove(&session_id);
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
                        }
                        Err(message) => sink.error(Some(request_id), "close_session_failed", message, true),
                    },
                    InternalEvent::SessionDeleted { request_id, session_id, result } => match result {
                        Ok(()) => {
                            if let Err(message) = session_registry.remove(&session_id) {
                                sink.error(
                                    Some(request_id),
                                    "session_store_failed",
                                    message,
                                    false,
                                );
                                continue;
                            }
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
                            pending_config_notifications.remove(&session_id);
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
                            Ok(stop_reason) => render_router.route(RenderUpdate {
                                session_id,
                                kind: RenderUpdateKind::TurnCompleted,
                                text: String::new(),
                                metadata: Some(serde_json::json!({
                                    "stopReason": stop_reason,
                                    "requestId": request_id,
                                })),
                            }),
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
                        } else if pending_config_notifications.len() < SESSION_CONFIG_MAX_OPTIONS
                            || pending_config_notifications.contains_key(&session_id)
                        {
                            pending_config_notifications.insert(session_id, options);
                        } else {
                            sink.error(
                                None,
                                "invalid_session_notification",
                                "too many config notifications for unknown sessions",
                                false,
                            );
                        }
                    }
                }
            }
        }
    }
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

fn project_filesystem_permission(approval: &FilesystemApproval) -> PermissionRequestProjection {
    let (title, tool_kind) = match approval.kind {
        FilesystemOperationKind::Read => ("Read file", "read"),
        FilesystemOperationKind::Write => ("Write file", "edit"),
    };
    PermissionRequestProjection {
        request_id: approval.approval_id.clone(),
        session_id: approval.session_id.clone(),
        tool_call_id: format!("filesystem:{}", approval.approval_id),
        title: title.to_string(),
        tool_kind: tool_kind.to_string(),
        raw_input: Some(serde_json::json!({ "path": approval.path })),
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
    }
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

fn project_terminal_permission(approval: &crate::TerminalApproval) -> PermissionRequestProjection {
    let command = approval.command.first().cloned().unwrap_or_default();
    let args = approval.command.iter().skip(1).cloned().collect::<Vec<_>>();
    PermissionRequestProjection {
        request_id: approval.approval_id.clone(),
        session_id: approval.session_id.clone(),
        tool_call_id: format!("terminal:{}", approval.approval_id),
        title: "Run terminal command".to_string(),
        tool_kind: "execute".to_string(),
        raw_input: Some(serde_json::json!({
            "command": command,
            "args": args,
            "cwd": approval.cwd,
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
    }
}

async fn list_all_sessions(
    connection: &ConnectionTo<Agent>,
) -> Result<Vec<SessionCatalogEntryProjection>, String> {
    let mut sessions = Vec::new();
    let mut cursor: Option<String> = None;
    let mut seen_cursors = HashSet::new();
    let mut seen_sessions = HashSet::new();
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
    let session_id = session.session_id.to_string();
    if session_id.is_empty() || session_id.trim() != session_id {
        return Err("session catalog contains a non-canonical session id".to_string());
    }
    let cwd = normalize_workspace_identity(&session.cwd)
        .map_err(|error| error.to_string())?
        .display()
        .to_string();
    let additional_directories = session
        .additional_directories
        .iter()
        .map(|path| {
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
    Ok(SessionCatalogEntryProjection {
        session_id,
        cwd,
        additional_directories,
        title,
        updated_at: session.updated_at,
        meta,
    })
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

fn project_auth_methods(methods: &[AuthMethod]) -> Vec<AuthMethodProjection> {
    methods
        .iter()
        .filter_map(|method| {
            let id = method.id().to_string();
            let name = method.name().trim();
            if id.is_empty() || id.trim() != id || name.is_empty() {
                return None;
            }
            Some(AuthMethodProjection {
                id,
                name: name.to_string(),
                description: method
                    .description()
                    .map(str::trim)
                    .filter(|value| !value.is_empty())
                    .map(str::to_string),
            })
        })
        .collect()
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
        session_id: response.session_id.to_string(),
        modes: response.modes.as_ref().map(project_session_modes),
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
        let name = display_protocol_text(&option.name, &id);
        let description = optional_protocol_text(option.description.as_deref());
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
                        let group_name = display_protocol_text(&group.name, &group_id);
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
        name: display_protocol_text(&choice.name, &value),
        value,
        description: optional_protocol_text(choice.description.as_deref()),
        group_id,
        group_name,
    })
}

fn canonical_protocol_text(value: &str, label: &str) -> Result<String, String> {
    if value.is_empty() || value.trim() != value {
        Err(format!("{label} must be canonical non-empty text"))
    } else {
        Ok(value.to_string())
    }
}

fn display_protocol_text(value: &str, fallback: &str) -> String {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        fallback.to_string()
    } else {
        trimmed.to_string()
    }
}

fn optional_protocol_text(value: Option<&str>) -> Option<String> {
    value
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
}

fn project_session_modes(modes: &SessionModeState) -> SessionModesProjection {
    SessionModesProjection {
        current_mode_id: modes.current_mode_id.to_string(),
        available_modes: modes
            .available_modes
            .iter()
            .map(|mode| SessionModeProjection {
                id: mode.id.to_string(),
                label: if mode.name.trim().is_empty() {
                    mode.id.to_string()
                } else {
                    mode.name.clone()
                },
            })
            .collect(),
    }
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
) -> PermissionRequestProjection {
    PermissionRequestProjection {
        request_id: request_id.to_string(),
        session_id: request.session_id.to_string(),
        tool_call_id: request.tool_call.tool_call_id.to_string(),
        title: request
            .tool_call
            .fields
            .title
            .clone()
            .unwrap_or_else(|| "Agent action".to_string()),
        tool_kind: request.tool_call.fields.kind.map_or_else(
            || "other".to_string(),
            |kind| format!("{kind:?}").to_lowercase(),
        ),
        raw_input: request.tool_call.fields.raw_input.clone(),
        options: request
            .options
            .iter()
            .map(|option| PermissionOptionProjection {
                option_id: option.option_id.to_string(),
                label: option.name.clone(),
                kind: permission_option_kind(option.kind).to_string(),
            })
            .collect(),
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
    Render(RenderUpdate),
    Control(SessionUpdate),
    Config {
        session_id: String,
        options: Vec<SessionConfigOptionProjection>,
    },
}

fn project_session_notification(
    notification: SessionNotification,
) -> Result<Option<ProjectedSessionNotification>, String> {
    let session_id = notification.session_id.to_string();
    let projection = match notification.update {
        AcpSessionUpdate::UserMessageChunk(chunk) => {
            let (text, metadata) = render_content(&chunk.content);
            ProjectedSessionNotification::Render(RenderUpdate {
                session_id,
                kind: RenderUpdateKind::UserMessage,
                text,
                metadata,
            })
        }
        AcpSessionUpdate::AgentMessageChunk(chunk) => {
            let (text, metadata) = render_content(&chunk.content);
            ProjectedSessionNotification::Render(RenderUpdate {
                session_id,
                kind: RenderUpdateKind::AssistantText,
                text,
                metadata,
            })
        }
        AcpSessionUpdate::AgentThoughtChunk(chunk) => {
            let (text, _) = render_content(&chunk.content);
            ProjectedSessionNotification::Render(RenderUpdate {
                session_id,
                kind: RenderUpdateKind::Thought,
                text,
                metadata: None,
            })
        }
        AcpSessionUpdate::ToolCall(value) => {
            let title = value.title.clone();
            ProjectedSessionNotification::Render(RenderUpdate {
                session_id,
                kind: RenderUpdateKind::ToolCall,
                text: title,
                metadata: project_tool_render_metadata(value),
            })
        }
        AcpSessionUpdate::ToolCallUpdate(value) => {
            let title = value.fields.title.clone().unwrap_or_default();
            ProjectedSessionNotification::Render(RenderUpdate {
                session_id,
                kind: RenderUpdateKind::ToolCall,
                text: title,
                metadata: project_tool_render_metadata(value),
            })
        }
        AcpSessionUpdate::Plan(value) => {
            let mut metadata = serde_json::json!({ "entries": value.entries });
            strip_non_render_fields(&mut metadata);
            ProjectedSessionNotification::Render(RenderUpdate {
                session_id,
                kind: RenderUpdateKind::Plan,
                text: String::new(),
                metadata: Some(metadata),
            })
        }
        AcpSessionUpdate::CurrentModeUpdate(value) => {
            ProjectedSessionNotification::Control(SessionUpdate {
                session_id,
                kind: SessionUpdateKind::ModeChanged,
                text: None,
                request_id: None,
                payload: Some(serde_json::json!({
                    "modeId": value.current_mode_id,
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
        // Protocol notifications without a UI consumer never cross FFI.
        _ => return Ok(None),
    };
    Ok(Some(projection))
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
            block.map(|block| serde_json::json!({ "contentBlocks": [block] })),
        )
    }
}

fn project_tool_render_metadata<T: serde::Serialize>(value: T) -> Option<serde_json::Value> {
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
    let mut value = serde_json::to_value(value).ok()?;
    strip_non_render_fields(&mut value);
    let fields = value.as_object_mut()?;
    fields.retain(|key, _| TOOL_RENDER_FIELDS.contains(&key.as_str()));
    bound_render_field(fields, "rawInput", RENDER_TOOL_DETAIL_MAX_BYTES);
    bound_render_field(fields, "rawOutput", RENDER_TOOL_DETAIL_MAX_BYTES);
    bound_render_field(fields, "locations", RENDER_TOOL_DETAIL_MAX_BYTES);
    bound_render_field(fields, "content", RENDER_TOOL_CONTENT_MAX_BYTES);
    Some(value)
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
            let mut lines = BufReader::new(stderr).lines();
            while let Some(result) = lines.next().await {
                match result {
                    Ok(line) => stderr_sink.emit(RuntimeEvent::StderrLog { line }),
                    Err(error) => {
                        stderr_sink.error(None, "stderr_read_failed", error.to_string(), true);
                        break;
                    }
                }
            }
        };

        let incoming = Box::pin(BufReader::new(stdout).lines());
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
            futures::future::Either::Right(((), main)) => main.await,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{
        EventSink, RENDER_SNAPSHOT_CHUNK_MAX_UPDATES, RENDER_SNAPSHOT_CHUNK_TARGET_BYTES,
        RenderRouter, RenderUpdate, RenderUpdateKind, ReplayRenderProjection, RuntimeEvent,
        RuntimeEventEnvelope, SESSION_TITLE_MAX_CHARACTERS, normalize_session_title,
        strip_non_render_fields,
    };
    use std::sync::mpsc;
    use std::sync::{Arc, Mutex};

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
    fn replay_projection_coalesces_text_and_merges_tool_updates_in_rust() {
        let mut projection = ReplayRenderProjection {
            request_id: "restore-1".to_string(),
            updates: Vec::new(),
        };
        for text in ["hel", "lo"] {
            projection.push(RenderUpdate {
                session_id: "session-1".to_string(),
                kind: RenderUpdateKind::AssistantText,
                text: text.to_string(),
                metadata: None,
            });
        }
        projection.push(RenderUpdate {
            session_id: "session-1".to_string(),
            kind: RenderUpdateKind::ToolCall,
            text: "Read file".to_string(),
            metadata: Some(serde_json::json!({
                "toolCallId": "tool-1",
                "status": "in_progress"
            })),
        });
        projection.push(RenderUpdate {
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
    fn replay_snapshot_is_split_before_the_ffi_queue() {
        let (sender, receiver) = mpsc::sync_channel(16);
        let sink = EventSink {
            sender,
            next_sequence: Arc::new(Mutex::new(1)),
        };
        let router = RenderRouter::new(sink);
        let updates = (0..=(RENDER_SNAPSHOT_CHUNK_MAX_UPDATES * 2))
            .map(|index| RenderUpdate {
                session_id: "session-1".to_string(),
                kind: RenderUpdateKind::AssistantText,
                text: index.to_string(),
                metadata: None,
            })
            .collect();

        router.emit_snapshot_chunks("restore-1", "session-1", updates);

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
        let (sender, receiver) = mpsc::sync_channel(16);
        let sink = EventSink {
            sender,
            next_sequence: Arc::new(Mutex::new(1)),
        };
        let router = RenderRouter::new(sink);
        let updates = (0..4)
            .map(|_| RenderUpdate {
                session_id: "session-1".to_string(),
                kind: RenderUpdateKind::AssistantText,
                text: "x".repeat(RENDER_SNAPSHOT_CHUNK_TARGET_BYTES / 3),
                metadata: None,
            })
            .collect();

        router.emit_snapshot_chunks("restore-1", "session-1", updates);

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
