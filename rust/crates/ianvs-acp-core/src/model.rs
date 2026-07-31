use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

/// Configuration used to launch one local ACP agent process.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentLaunchConfig {
    /// Stable UI-facing name for this runtime.
    pub agent_name: String,
    /// Executable path or command name. No shell interpretation is performed.
    pub command: String,
    /// Arguments passed directly to the executable.
    #[serde(default)]
    pub args: Vec<String>,
    /// Explicit environment overrides. The parent environment remains inherited.
    #[serde(default)]
    pub environment: BTreeMap<String, String>,
    /// Optional working directory for the agent process.
    #[serde(default)]
    pub process_cwd: Option<String>,
    /// Maximum time a permission request may wait for a client decision.
    /// Hosts may omit this to use the core default.
    #[serde(default)]
    pub permission_timeout_ms: Option<u64>,
    /// Safe idle/startup process restarts before any session activity.
    #[serde(default)]
    pub max_restart_attempts: Option<u32>,
    /// Base delay for exponential process restart backoff.
    #[serde(default)]
    pub restart_base_delay_ms: Option<u64>,
    /// Optional dedicated `SQLite` file for durable ACP session recovery.
    #[serde(default)]
    pub session_store_path: Option<String>,
    /// Capacity limit for the dedicated ACP session-recovery SQLite file.
    #[serde(default)]
    pub session_store_max_bytes: Option<u64>,
    /// Inactive session recovery metadata retention in days.
    #[serde(default)]
    pub session_store_retention_days: Option<u32>,
    /// Additional workspace roots advertised when creating an ACP session.
    #[serde(default)]
    pub additional_directories: Vec<String>,
    /// Product-level MCP server inputs projected into typed ACP session setup.
    #[serde(default)]
    pub mcp_servers: Vec<McpServerLaunchConfig>,
    /// Advertise and enforce the Rust PTY-backed ACP terminal provider.
    #[serde(default)]
    pub enable_terminal_provider: bool,
    /// Advertise the Rust workspace-scoped, permission-gated text read provider.
    #[serde(default)]
    pub enable_filesystem_read_text_file: bool,
    /// Advertise the Rust workspace-scoped, permission-gated atomic text writer.
    #[serde(default)]
    pub enable_filesystem_write_text_file: bool,
    /// Global live plus approval-pending terminal quota.
    #[serde(default)]
    pub max_terminal_handles: Option<usize>,
    /// Per-session live plus approval-pending terminal quota.
    #[serde(default)]
    pub max_terminal_handles_per_session: Option<usize>,
    /// Default retained terminal output bytes when the agent omits a limit.
    #[serde(default)]
    pub terminal_default_output_byte_limit: Option<usize>,
    /// Hard upper bound for an agent-requested terminal output limit.
    #[serde(default)]
    pub terminal_max_output_byte_limit: Option<usize>,
}

impl AgentLaunchConfig {
    /// Validate fields that cross the host boundary before spawning a process.
    pub fn validate(&self) -> Result<(), &'static str> {
        if self.agent_name.trim().is_empty() {
            return Err("agentName must not be empty");
        }
        if self.command.trim().is_empty() {
            return Err("command must not be empty");
        }
        if self
            .environment
            .keys()
            .any(|key| key.is_empty() || key.contains('=') || key.as_bytes().contains(&0))
        {
            return Err("environment contains an invalid variable name");
        }
        if self
            .environment
            .values()
            .any(|value| value.as_bytes().contains(&0))
        {
            return Err("environment contains a NUL byte");
        }
        if self.permission_timeout_ms == Some(0) {
            return Err("permissionTimeoutMs must be positive");
        }
        if self
            .session_store_path
            .as_deref()
            .is_some_and(|path| path.trim().is_empty())
        {
            return Err("sessionStorePath must not be empty");
        }
        if self.session_store_max_bytes == Some(0) {
            return Err("sessionStoreMaxBytes must be positive");
        }
        if self.session_store_retention_days == Some(0) {
            return Err("sessionStoreRetentionDays must be positive");
        }
        if self.mcp_servers.len() > 64 {
            return Err("mcpServers exceeds 64 entries");
        }
        if self.additional_directories.len() > 256
            || self
                .additional_directories
                .iter()
                .any(|path| !canonical_bounded_text(path, 32 * 1024))
        {
            return Err("additionalDirectories is invalid");
        }
        let mut mcp_names = std::collections::HashSet::new();
        for server in &self.mcp_servers {
            server.validate()?;
            if !mcp_names.insert(server.name()) {
                return Err("mcpServers contains a duplicate name");
            }
        }
        let defaults = crate::TerminalConfig::default();
        let terminal = crate::TerminalConfig {
            max_active_handles: self
                .max_terminal_handles
                .unwrap_or(defaults.max_active_handles),
            max_active_handles_per_session: self
                .max_terminal_handles_per_session
                .unwrap_or(defaults.max_active_handles_per_session),
            default_output_byte_limit: self
                .terminal_default_output_byte_limit
                .unwrap_or(defaults.default_output_byte_limit),
            max_output_byte_limit: self
                .terminal_max_output_byte_limit
                .unwrap_or(defaults.max_output_byte_limit),
        };
        if terminal.validate().is_err() {
            return Err("terminal limits are invalid");
        }
        Ok(())
    }

    #[must_use]
    pub fn terminal_config(&self) -> crate::TerminalConfig {
        let defaults = crate::TerminalConfig::default();
        crate::TerminalConfig {
            max_active_handles: self
                .max_terminal_handles
                .unwrap_or(defaults.max_active_handles),
            max_active_handles_per_session: self
                .max_terminal_handles_per_session
                .unwrap_or(defaults.max_active_handles_per_session),
            default_output_byte_limit: self
                .terminal_default_output_byte_limit
                .unwrap_or(defaults.default_output_byte_limit),
            max_output_byte_limit: self
                .terminal_max_output_byte_limit
                .unwrap_or(defaults.max_output_byte_limit),
        }
    }
}

/// Stable product configuration for one MCP server. This is intentionally not
/// a raw ACP JSON object.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
pub enum McpServerLaunchConfig {
    Stdio {
        name: String,
        command: String,
        #[serde(default)]
        args: Vec<String>,
        #[serde(default)]
        environment: BTreeMap<String, String>,
    },
    Http {
        name: String,
        url: String,
        #[serde(default)]
        headers: BTreeMap<String, String>,
    },
    Sse {
        name: String,
        url: String,
        #[serde(default)]
        headers: BTreeMap<String, String>,
    },
}

impl McpServerLaunchConfig {
    #[must_use]
    pub fn name(&self) -> &str {
        match self {
            Self::Stdio { name, .. } | Self::Http { name, .. } | Self::Sse { name, .. } => name,
        }
    }

    fn validate(&self) -> Result<(), &'static str> {
        if !canonical_bounded_text(self.name(), 256) {
            return Err("MCP server name is invalid");
        }
        match self {
            Self::Stdio {
                command,
                args,
                environment,
                ..
            } => {
                if !canonical_bounded_text(command, 32 * 1024) {
                    return Err("MCP stdio command is invalid");
                }
                if args.len() > 512
                    || args
                        .iter()
                        .any(|value| value.len() > 32 * 1024 || value.as_bytes().contains(&0))
                {
                    return Err("MCP stdio arguments exceed their boundary");
                }
                if environment.len() > 512
                    || environment.iter().any(|(name, value)| {
                        name.is_empty()
                            || name.len() > 1024
                            || name.contains('=')
                            || name.as_bytes().contains(&0)
                            || value.len() > 1024 * 1024
                            || value.as_bytes().contains(&0)
                    })
                {
                    return Err("MCP stdio environment is invalid");
                }
            }
            Self::Http { url, headers, .. } | Self::Sse { url, headers, .. } => {
                if (!url.starts_with("http://") && !url.starts_with("https://"))
                    || !canonical_bounded_text(url, 32 * 1024)
                {
                    return Err("MCP remote URL must use http or https");
                }
                if headers.len() > 512
                    || headers.iter().any(|(name, value)| {
                        !canonical_bounded_text(name, 8 * 1024)
                            || name.contains([':', '\r', '\n'])
                            || value.len() > 1024 * 1024
                            || value.contains(['\r', '\n', '\0'])
                    })
                {
                    return Err("MCP remote headers are invalid");
                }
            }
        }
        Ok(())
    }
}

fn canonical_bounded_text(value: &str, max_bytes: usize) -> bool {
    !value.trim().is_empty()
        && value.trim().len() == value.len()
        && value.len() <= max_bytes
        && !value.as_bytes().contains(&0)
}

/// Coarse runtime lifecycle owned by Rust and projected into Flutter.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RuntimeStatus {
    Stopped,
    Starting,
    Ready,
    Recovering,
    Failed,
    Disposed,
}

/// Session lifecycle owned by Rust.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SessionStatus {
    Creating,
    Ready,
    Running,
    WaitingPermission,
    Cancelling,
    Closed,
    Failed,
}

/// Stable host commands. These are product operations, not ACP JSON-RPC methods.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CommandKind {
    StartAgent,
    CreateSession,
    RestoreSession,
    ListSessions,
    CloseSession,
    DeleteSession,
    Authenticate,
    Logout,
    Prompt,
    Cancel,
    RespondPermission,
    SetMode,
    SetConfigOption,
    Dispose,
}

/// A normalized, UI-facing capability projection.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CapabilityProjection {
    pub protocol_version: u16,
    pub load_session: bool,
    pub list_sessions: bool,
    pub resume_session: bool,
    pub close_session: bool,
    pub delete_session: bool,
    pub logout: bool,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub auth_methods: Vec<AuthMethodProjection>,
    pub session_modes: bool,
    pub session_config: bool,
    pub prompt_image: bool,
    pub prompt_audio: bool,
    pub embedded_context: bool,
    pub mcp_capabilities: bool,
    #[serde(default)]
    pub mcp_http: bool,
    #[serde(default)]
    pub mcp_sse: bool,
    pub additional_directories: bool,
    pub filesystem_read_text_file: bool,
    pub filesystem_write_text_file: bool,
    pub terminal: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AuthMethodProjection {
    pub id: String,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
}

/// Decision sent by the user-facing host to a Rust-owned pending permission.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "decision", rename_all = "snake_case")]
pub enum PermissionDecision {
    Selected {
        #[serde(rename = "optionId")]
        option_id: String,
    },
    Cancelled,
}

/// One UI choice for a permission request.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PermissionOptionProjection {
    pub option_id: String,
    pub label: String,
    pub kind: String,
}

/// Stable projection of an ACP permission request.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PermissionRequestProjection {
    pub request_id: String,
    pub session_id: String,
    pub tool_call_id: String,
    pub title: String,
    pub tool_kind: String,
    pub raw_input: Option<serde_json::Value>,
    pub options: Vec<PermissionOptionProjection>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionModeProjection {
    pub id: String,
    pub label: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionModesProjection {
    pub current_mode_id: String,
    pub available_modes: Vec<SessionModeProjection>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionConfigChoiceProjection {
    pub value: String,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub group_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub group_name: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionConfigOptionProjection {
    pub id: String,
    pub name: String,
    pub option_type: String,
    pub current_value: serde_json::Value,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub options: Vec<SessionConfigChoiceProjection>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub category: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum SessionConfigValueProjection {
    Boolean { value: bool },
    ValueId { value: String },
}

/// Host product input for a user-selected local prompt attachment.
///
/// Rust resolves `path` against the session workspace and decides which typed
/// ACP content block can be sent from the negotiated capability intersection.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PromptAttachmentInput {
    pub path: String,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mime_type: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub size: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub data: Option<String>,
    #[serde(default)]
    pub user_approved_outside_workspace: bool,
    #[serde(default)]
    pub force_resource_link: bool,
}

/// Normalized update types consumed by Timeline/Plan/Tool Call UI projections.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SessionUpdateKind {
    SessionCreated,
    SessionRestored,
    SessionClosed,
    SessionDeleted,
    UserMessage,
    AgentMessageDelta,
    AgentThoughtDelta,
    ToolCall,
    ToolCallUpdate,
    Plan,
    AvailableCommands,
    ModeChanged,
    ConfigChanged,
    SessionInfoChanged,
    UsageChanged,
    PermissionInvalidated,
    PromptCompleted,
    Cancelled,
    Failed,
}

/// Stable session event. `payload` follows ianvs projection schemas and never
/// contains a raw JSON-RPC envelope or method name.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionUpdate {
    pub session_id: String,
    pub kind: SessionUpdateKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub request_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub payload: Option<serde_json::Value>,
}

/// Bounded, normalized entry returned by the Rust-owned session catalog.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionCatalogEntryProjection {
    pub session_id: String,
    pub cwd: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub additional_directories: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub updated_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub meta: Option<serde_json::Value>,
}

/// Events emitted by the Rust runtime to either typed host adapter.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(
    tag = "type",
    rename_all = "snake_case",
    rename_all_fields = "camelCase"
)]
pub enum RuntimeEvent {
    SessionUpdate {
        update: SessionUpdate,
    },
    PermissionRequest {
        request: PermissionRequestProjection,
    },
    SessionCatalog {
        request_id: String,
        sessions: Vec<SessionCatalogEntryProjection>,
    },
    AuthenticationChanged {
        request_id: String,
        authenticated: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        method_id: Option<String>,
    },
    StatusChanged {
        status: RuntimeStatus,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        detail: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        capabilities: Option<CapabilityProjection>,
    },
    StderrLog {
        line: String,
    },
    TerminalAttached {
        session_id: String,
        terminal_id: String,
        command: Vec<String>,
        cwd: String,
    },
    TerminalOutput {
        session_id: String,
        terminal_id: String,
        data: String,
    },
    TerminalExited {
        session_id: String,
        terminal_id: String,
        exit: crate::TerminalExit,
    },
    TerminalReleased {
        session_id: String,
        terminal_id: String,
    },
    RuntimeError {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        request_id: Option<String>,
        code: String,
        message: String,
        recoverable: bool,
    },
}

/// Versioned event envelope used by host adapters.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RuntimeEventEnvelope {
    pub schema_version: u16,
    pub sequence: u64,
    #[serde(flatten)]
    pub event: RuntimeEvent,
}

impl RuntimeEventEnvelope {
    pub const SCHEMA_VERSION: u16 = 3;

    #[must_use]
    pub fn new(sequence: u64, event: RuntimeEvent) -> Self {
        Self {
            schema_version: Self::SCHEMA_VERSION,
            sequence,
            event,
        }
    }
}
