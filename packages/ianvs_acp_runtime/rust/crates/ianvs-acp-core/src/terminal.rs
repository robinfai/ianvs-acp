use std::collections::HashMap;
use std::io::Read;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread;

use portable_pty::{CommandBuilder, MasterPty, PtySize, native_pty_system};
use serde::{Deserialize, Serialize};
use thiserror::Error;
use tokio::sync::Notify;
use uuid::Uuid;

use crate::{WorkspaceError, WorkspaceScope};

const DEFAULT_OUTPUT_BYTE_LIMIT: usize = 1_048_576;
const MAX_OUTPUT_BYTE_LIMIT: usize = 8_388_608;
const TERMINAL_SESSION_ID_MAX_BYTES: usize = 8 * 1024;
const TERMINAL_COMMAND_MAX_BYTES: usize = 8 * 1024;
const TERMINAL_MAX_ARGUMENTS: usize = 128;
const TERMINAL_ARGUMENT_MAX_BYTES: usize = 8 * 1024;
const TERMINAL_MAX_ENVIRONMENT: usize = 128;
const TERMINAL_ENVIRONMENT_NAME_MAX_BYTES: usize = 1024;
const TERMINAL_ENVIRONMENT_VALUE_MAX_BYTES: usize = 8 * 1024;
const TERMINAL_CWD_MAX_BYTES: usize = 32 * 1024;
const TERMINAL_SPEC_MAX_BYTES: usize = 48 * 1024;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TerminalConfig {
    pub max_active_handles: usize,
    pub max_active_handles_per_session: usize,
    pub default_output_byte_limit: usize,
    pub max_output_byte_limit: usize,
}

impl Default for TerminalConfig {
    fn default() -> Self {
        Self {
            max_active_handles: 16,
            max_active_handles_per_session: 4,
            default_output_byte_limit: DEFAULT_OUTPUT_BYTE_LIMIT,
            max_output_byte_limit: MAX_OUTPUT_BYTE_LIMIT,
        }
    }
}

impl TerminalConfig {
    pub fn validate(&self) -> Result<(), TerminalError> {
        if self.max_active_handles == 0
            || self.max_active_handles_per_session == 0
            || self.max_active_handles_per_session > self.max_active_handles
        {
            return Err(TerminalError::InvalidHandleLimits);
        }
        if self.default_output_byte_limit == 0
            || self.max_output_byte_limit == 0
            || self.default_output_byte_limit > self.max_output_byte_limit
        {
            return Err(TerminalError::InvalidOutputLimits);
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TerminalEnvironmentVariable {
    pub name: String,
    pub value: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TerminalCreateSpec {
    pub session_id: String,
    pub command: String,
    #[serde(default)]
    pub args: Vec<String>,
    #[serde(default)]
    pub environment: Vec<TerminalEnvironmentVariable>,
    pub cwd: Option<PathBuf>,
    pub output_byte_limit: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TerminalApproval {
    pub approval_id: String,
    pub session_id: String,
    pub command: Vec<String>,
    pub environment: Vec<TerminalEnvironmentVariable>,
    pub cwd: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TerminalExit {
    pub exit_code: Option<u32>,
    pub signal: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TerminalOutputSnapshot {
    pub output: String,
    pub truncated: bool,
    pub exit: Option<TerminalExit>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TerminalRuntimeEvent {
    Attached {
        session_id: String,
        terminal_id: String,
        command: Vec<String>,
        cwd: String,
    },
    Output {
        session_id: String,
        terminal_id: String,
        data: String,
    },
    Exited {
        session_id: String,
        terminal_id: String,
        exit: TerminalExit,
    },
    Released {
        session_id: String,
        terminal_id: String,
    },
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum TerminalError {
    #[error("terminal handle limits are invalid")]
    InvalidHandleLimits,
    #[error("terminal output limits are invalid")]
    InvalidOutputLimits,
    #[error("terminal session id must be canonical non-empty text")]
    InvalidSessionId,
    #[error("terminal command must be canonical non-empty text without NUL bytes")]
    InvalidCommand,
    #[error("terminal argument contains a NUL byte")]
    InvalidArgument,
    #[error("terminal environment contains an invalid variable")]
    InvalidEnvironment,
    #[error("terminal create request exceeds the bounded policy")]
    SpecLimit,
    #[error("terminal session is not registered: {0}")]
    UnknownSession(String),
    #[error("terminal approval is not pending: {0}")]
    UnknownApproval(String),
    #[error("terminal is not active for this session: {0}")]
    UnknownTerminal(String),
    #[error("global terminal handle limit reached")]
    GlobalHandleLimit,
    #[error("terminal handle limit reached for session: {0}")]
    SessionHandleLimit(String),
    #[error("terminal working directory is not a directory: {0}")]
    InvalidWorkingDirectory(String),
    #[error("terminal process failed: {0}")]
    Process(String),
    #[error(transparent)]
    Workspace(#[from] WorkspaceError),
}

type TerminalListener = dyn Fn(TerminalRuntimeEvent) + Send + Sync + 'static;

pub struct TerminalManager {
    config: TerminalConfig,
    admission: Mutex<()>,
    scopes: Mutex<HashMap<String, WorkspaceScope>>,
    pending: Mutex<HashMap<String, PreparedTerminalCreate>>,
    terminals: Mutex<HashMap<String, ManagedTerminal>>,
    listener: Arc<TerminalListener>,
}

impl std::fmt::Debug for TerminalManager {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("TerminalManager")
            .field("config", &self.config)
            .finish_non_exhaustive()
    }
}

impl TerminalManager {
    pub fn new(
        config: TerminalConfig,
        listener: impl Fn(TerminalRuntimeEvent) + Send + Sync + 'static,
    ) -> Result<Self, TerminalError> {
        config.validate()?;
        Ok(Self {
            config,
            admission: Mutex::new(()),
            scopes: Mutex::new(HashMap::new()),
            pending: Mutex::new(HashMap::new()),
            terminals: Mutex::new(HashMap::new()),
            listener: Arc::new(listener),
        })
    }

    pub fn register_session(
        &self,
        session_id: &str,
        scope: WorkspaceScope,
    ) -> Result<(), TerminalError> {
        let session_id = canonical_session_id(session_id)?;
        self.scopes
            .lock()
            .expect("terminal scope mutex poisoned")
            .insert(session_id, scope);
        Ok(())
    }

    pub fn request_create(
        &self,
        spec: TerminalCreateSpec,
    ) -> Result<TerminalApproval, TerminalError> {
        let _admission = self
            .admission
            .lock()
            .expect("terminal admission mutex poisoned");
        validate_spec(&spec)?;
        self.require_capacity(&spec.session_id)?;
        let scope = self
            .scopes
            .lock()
            .expect("terminal scope mutex poisoned")
            .get(&spec.session_id)
            .cloned()
            .ok_or_else(|| TerminalError::UnknownSession(spec.session_id.clone()))?;
        let cwd = spec.cwd.as_ref().map_or_else(
            || Ok(scope.cwd().to_path_buf()),
            |cwd| scope.resolve_existing(cwd),
        )?;
        if !cwd.is_dir() {
            return Err(TerminalError::InvalidWorkingDirectory(
                cwd.display().to_string(),
            ));
        }
        let command = std::iter::once(spec.command.clone())
            .chain(spec.args.iter().cloned())
            .collect::<Vec<_>>();
        let session_id = spec.session_id.clone();
        let environment = spec.environment.clone();
        let cwd_display = cwd.display().to_string();
        let approval_id = Uuid::new_v4().to_string();
        self.pending
            .lock()
            .expect("terminal pending mutex poisoned")
            .insert(approval_id.clone(), PreparedTerminalCreate { spec, cwd });
        Ok(TerminalApproval {
            approval_id,
            session_id,
            command,
            environment,
            cwd: cwd_display,
        })
    }

    pub fn approve_create(&self, approval_id: &str) -> Result<String, TerminalError> {
        let _admission = self
            .admission
            .lock()
            .expect("terminal admission mutex poisoned");
        let prepared = self.take_pending(approval_id)?;
        self.spawn(prepared)
    }

    pub fn deny_create(&self, approval_id: &str) -> Result<(), TerminalError> {
        let _admission = self
            .admission
            .lock()
            .expect("terminal admission mutex poisoned");
        self.take_pending(approval_id)?;
        Ok(())
    }

    pub fn output(
        &self,
        session_id: &str,
        terminal_id: &str,
    ) -> Result<TerminalOutputSnapshot, TerminalError> {
        let terminals = self
            .terminals
            .lock()
            .expect("terminal registry mutex poisoned");
        let terminal = terminal_for_session(&terminals, session_id, terminal_id)?;
        Ok(terminal.snapshot())
    }

    pub async fn wait_for_exit(
        &self,
        session_id: &str,
        terminal_id: &str,
    ) -> Result<TerminalExit, TerminalError> {
        let (exit_state, output_state) = {
            let terminals = self
                .terminals
                .lock()
                .expect("terminal registry mutex poisoned");
            let terminal = terminal_for_session(&terminals, session_id, terminal_id)?;
            (Arc::clone(&terminal.exit), Arc::clone(&terminal.output))
        };
        loop {
            let notified = exit_state.notify.notified();
            let exit = {
                exit_state
                    .value
                    .lock()
                    .expect("terminal exit mutex poisoned")
                    .clone()
            };
            if let Some(exit) = exit {
                wait_for_output_done(&output_state).await;
                return Ok(exit);
            }
            notified.await;
        }
    }

    pub fn kill(&self, session_id: &str, terminal_id: &str) -> Result<(), TerminalError> {
        let terminals = self
            .terminals
            .lock()
            .expect("terminal registry mutex poisoned");
        let terminal = terminal_for_session(&terminals, session_id, terminal_id)?;
        terminal.kill_if_running()
    }

    pub fn release(&self, session_id: &str, terminal_id: &str) -> Result<(), TerminalError> {
        let _admission = self
            .admission
            .lock()
            .expect("terminal admission mutex poisoned");
        let terminal = {
            let mut terminals = self
                .terminals
                .lock()
                .expect("terminal registry mutex poisoned");
            let terminal = terminal_for_session(&terminals, session_id, terminal_id)?;
            terminal.released.store(true, Ordering::Release);
            terminals
                .remove(terminal_id)
                .ok_or_else(|| TerminalError::UnknownTerminal(terminal_id.to_string()))?
        };
        terminal.kill_if_running()?;
        (self.listener)(TerminalRuntimeEvent::Released {
            session_id: session_id.to_string(),
            terminal_id: terminal_id.to_string(),
        });
        Ok(())
    }

    /// Revoke a session scope and release every PTY owned by that session.
    pub fn close_session(&self, session_id: &str) -> Result<(), TerminalError> {
        let session_id = canonical_session_id(session_id)?;
        self.scopes
            .lock()
            .expect("terminal scope mutex poisoned")
            .remove(&session_id);
        let terminal_ids = self
            .terminals
            .lock()
            .expect("terminal registry mutex poisoned")
            .iter()
            .filter(|(_, terminal)| terminal.session_id == session_id)
            .map(|(terminal_id, _)| terminal_id.clone())
            .collect::<Vec<_>>();
        for terminal_id in terminal_ids {
            self.release(&session_id, &terminal_id)?;
        }
        Ok(())
    }

    fn take_pending(&self, approval_id: &str) -> Result<PreparedTerminalCreate, TerminalError> {
        self.pending
            .lock()
            .expect("terminal pending mutex poisoned")
            .remove(approval_id)
            .ok_or_else(|| TerminalError::UnknownApproval(approval_id.to_string()))
    }

    fn spawn(&self, prepared: PreparedTerminalCreate) -> Result<String, TerminalError> {
        let expected_command = std::iter::once(prepared.spec.command.clone())
            .chain(prepared.spec.args.iter().cloned())
            .collect::<Vec<_>>();
        self.require_capacity(&prepared.spec.session_id)?;
        let terminal_id = Uuid::new_v4().to_string();
        let limit = effective_output_limit(&self.config, prepared.spec.output_byte_limit);
        let pty = native_pty_system();
        let pair = pty
            .openpty(PtySize::default())
            .map_err(|error| TerminalError::Process(error.to_string()))?;
        disable_input_echo(pair.master.as_ref())?;
        let mut command = CommandBuilder::new(&prepared.spec.command);
        command.args(&prepared.spec.args);
        command.cwd(&prepared.cwd);
        for variable in &prepared.spec.environment {
            command.env(&variable.name, &variable.value);
        }
        let mut child = pair
            .slave
            .spawn_command(command)
            .map_err(|error| TerminalError::Process(error.to_string()))?;
        drop(pair.slave);
        let reader = pair
            .master
            .try_clone_reader()
            .map_err(|error| TerminalError::Process(error.to_string()))?;
        if cfg!(target_os = "macos") {
            thread::sleep(std::time::Duration::from_millis(20));
        }
        drop(
            pair.master
                .take_writer()
                .map_err(|error| TerminalError::Process(error.to_string()))?,
        );
        let output = Arc::new(OutputState::new(limit));
        let exit = Arc::new(ExitState::default());
        let released = Arc::new(AtomicBool::new(false));
        let listener_gate = Arc::new(ListenerGate::default());
        let killer = child.clone_killer();
        if let Err(error) = spawn_output_reader(
            reader,
            Arc::clone(&output),
            Arc::clone(&released),
            Arc::clone(&listener_gate),
            Arc::clone(&self.listener),
            prepared.spec.session_id.clone(),
            terminal_id.clone(),
        ) {
            released.store(true, Ordering::Release);
            listener_gate.open();
            let _ = child.kill();
            return Err(error);
        }
        if let Err(error) = spawn_child_waiter(
            child,
            Arc::clone(&exit),
            Arc::clone(&released),
            Arc::clone(&listener_gate),
            Arc::clone(&self.listener),
            prepared.spec.session_id.clone(),
            terminal_id.clone(),
        ) {
            released.store(true, Ordering::Release);
            listener_gate.open();
            return Err(error);
        }
        self.terminals
            .lock()
            .expect("terminal registry mutex poisoned")
            .insert(
                terminal_id.clone(),
                ManagedTerminal {
                    session_id: prepared.spec.session_id.clone(),
                    _master: pair.master,
                    killer: Mutex::new(killer),
                    output,
                    exit,
                    released,
                },
            );
        (self.listener)(TerminalRuntimeEvent::Attached {
            session_id: prepared.spec.session_id,
            terminal_id: terminal_id.clone(),
            command: expected_command,
            cwd: prepared.cwd.display().to_string(),
        });
        listener_gate.open();
        Ok(terminal_id)
    }

    fn require_capacity(&self, session_id: &str) -> Result<(), TerminalError> {
        let terminals = self
            .terminals
            .lock()
            .expect("terminal registry mutex poisoned");
        if terminals.len() >= self.config.max_active_handles {
            return Err(TerminalError::GlobalHandleLimit);
        }
        let session_count = terminals
            .values()
            .filter(|terminal| terminal.session_id == session_id)
            .count();
        let pending = self
            .pending
            .lock()
            .expect("terminal pending mutex poisoned");
        let pending_session_count = pending
            .values()
            .filter(|prepared| prepared.spec.session_id == session_id)
            .count();
        if terminals.len() + pending.len() >= self.config.max_active_handles {
            return Err(TerminalError::GlobalHandleLimit);
        }
        if session_count + pending_session_count >= self.config.max_active_handles_per_session {
            return Err(TerminalError::SessionHandleLimit(session_id.to_string()));
        }
        Ok(())
    }
}

struct PreparedTerminalCreate {
    spec: TerminalCreateSpec,
    cwd: PathBuf,
}

struct ManagedTerminal {
    session_id: String,
    _master: Box<dyn MasterPty + Send>,
    killer: Mutex<Box<dyn portable_pty::ChildKiller + Send + Sync>>,
    output: Arc<OutputState>,
    exit: Arc<ExitState>,
    released: Arc<AtomicBool>,
}

impl ManagedTerminal {
    fn snapshot(&self) -> TerminalOutputSnapshot {
        let (output, truncated) = self
            .output
            .buffer
            .lock()
            .expect("terminal output mutex poisoned")
            .snapshot();
        let exit = self
            .exit
            .value
            .lock()
            .expect("terminal exit mutex poisoned")
            .clone();
        TerminalOutputSnapshot {
            output,
            truncated,
            exit,
        }
    }

    fn kill(&self) -> Result<(), TerminalError> {
        self.killer
            .lock()
            .expect("terminal killer mutex poisoned")
            .kill()
            .map_err(|error| TerminalError::Process(error.to_string()))
    }

    fn kill_if_running(&self) -> Result<(), TerminalError> {
        if self
            .exit
            .value
            .lock()
            .expect("terminal exit mutex poisoned")
            .is_none()
        {
            self.kill()?;
        }
        Ok(())
    }
}

impl Drop for ManagedTerminal {
    fn drop(&mut self) {
        let _ = self.kill_if_running();
    }
}

#[derive(Default)]
struct ExitState {
    value: Mutex<Option<TerminalExit>>,
    notify: Notify,
}

struct OutputBuffer {
    bytes: Vec<u8>,
    byte_limit: usize,
    truncated: bool,
}

struct OutputState {
    buffer: Mutex<OutputBuffer>,
    done: AtomicBool,
    notify: Notify,
}

#[derive(Default)]
struct ListenerGate {
    open: Mutex<bool>,
    notify: Condvar,
}

impl ListenerGate {
    fn wait(&self) {
        let mut open = self.open.lock().expect("terminal listener gate poisoned");
        while !*open {
            open = self
                .notify
                .wait(open)
                .expect("terminal listener gate poisoned");
        }
    }

    fn open(&self) {
        *self.open.lock().expect("terminal listener gate poisoned") = true;
        self.notify.notify_all();
    }
}

impl OutputState {
    const fn new(byte_limit: usize) -> Self {
        Self {
            buffer: Mutex::new(OutputBuffer::new(byte_limit)),
            done: AtomicBool::new(false),
            notify: Notify::const_new(),
        }
    }
}

impl OutputBuffer {
    const fn new(byte_limit: usize) -> Self {
        Self {
            bytes: Vec::new(),
            byte_limit,
            truncated: false,
        }
    }

    fn append(&mut self, bytes: &[u8]) {
        self.bytes.extend_from_slice(bytes);
        if self.bytes.len() > self.byte_limit {
            let discarded = self.bytes.len() - self.byte_limit;
            self.bytes.drain(..discarded);
            self.truncated = true;
        }
    }

    fn snapshot(&self) -> (String, bool) {
        let mut output = String::from_utf8_lossy(&self.bytes).into_owned();
        let mut truncated = self.truncated;
        if output.len() > self.byte_limit {
            let mut start = output.len() - self.byte_limit;
            while !output.is_char_boundary(start) {
                start += 1;
            }
            output = output[start..].to_string();
            truncated = true;
        }
        (output, truncated)
    }
}

fn validate_spec(spec: &TerminalCreateSpec) -> Result<(), TerminalError> {
    canonical_session_id(&spec.session_id)?;
    if spec.command.is_empty()
        || spec.command.trim() != spec.command
        || spec.command.as_bytes().contains(&0)
    {
        return Err(TerminalError::InvalidCommand);
    }
    if spec.session_id.len() > TERMINAL_SESSION_ID_MAX_BYTES
        || spec.command.len() > TERMINAL_COMMAND_MAX_BYTES
        || spec.args.len() > TERMINAL_MAX_ARGUMENTS
        || spec.environment.len() > TERMINAL_MAX_ENVIRONMENT
        || spec
            .cwd
            .as_ref()
            .is_some_and(|cwd| cwd.as_os_str().as_encoded_bytes().len() > TERMINAL_CWD_MAX_BYTES)
    {
        return Err(TerminalError::SpecLimit);
    }
    if spec.args.iter().any(|argument| {
        argument.len() > TERMINAL_ARGUMENT_MAX_BYTES || argument.as_bytes().contains(&0)
    }) {
        return Err(TerminalError::InvalidArgument);
    }
    if spec.environment.iter().any(|variable| {
        variable.name.is_empty()
            || variable.name.contains('=')
            || variable.name.len() > TERMINAL_ENVIRONMENT_NAME_MAX_BYTES
            || variable.value.len() > TERMINAL_ENVIRONMENT_VALUE_MAX_BYTES
            || variable.name.as_bytes().contains(&0)
            || variable.value.as_bytes().contains(&0)
    }) {
        return Err(TerminalError::InvalidEnvironment);
    }
    let projected_bytes = spec
        .session_id
        .len()
        .saturating_add(spec.command.len())
        .saturating_add(spec.args.iter().map(String::len).sum::<usize>())
        .saturating_add(
            spec.environment
                .iter()
                .map(|variable| variable.name.len().saturating_add(variable.value.len()))
                .sum::<usize>(),
        )
        .saturating_add(
            spec.cwd
                .as_ref()
                .map_or(0, |cwd| cwd.as_os_str().as_encoded_bytes().len()),
        );
    if projected_bytes > TERMINAL_SPEC_MAX_BYTES {
        return Err(TerminalError::SpecLimit);
    }
    Ok(())
}

fn canonical_session_id(session_id: &str) -> Result<String, TerminalError> {
    if session_id.is_empty()
        || session_id.trim() != session_id
        || session_id.as_bytes().contains(&0)
    {
        Err(TerminalError::InvalidSessionId)
    } else {
        Ok(session_id.to_string())
    }
}

fn effective_output_limit(config: &TerminalConfig, requested: Option<u64>) -> usize {
    requested
        .and_then(|value| usize::try_from(value).ok())
        .unwrap_or(config.default_output_byte_limit)
        .min(config.max_output_byte_limit)
}

fn terminal_for_session<'a>(
    terminals: &'a HashMap<String, ManagedTerminal>,
    session_id: &str,
    terminal_id: &str,
) -> Result<&'a ManagedTerminal, TerminalError> {
    terminals
        .get(terminal_id)
        .filter(|terminal| terminal.session_id == session_id)
        .ok_or_else(|| TerminalError::UnknownTerminal(terminal_id.to_string()))
}

#[cfg(unix)]
fn disable_input_echo(master: &dyn MasterPty) -> Result<(), TerminalError> {
    use std::os::fd::BorrowedFd;

    use nix::sys::termios::{LocalFlags, SetArg, tcsetattr};

    let (Some(raw_fd), Some(mut settings)) = (master.as_raw_fd(), master.get_termios()) else {
        return Err(TerminalError::Process(
            "PTY does not expose terminal settings".to_string(),
        ));
    };
    settings.local_flags.remove(LocalFlags::ECHO);
    // SAFETY: `raw_fd` is borrowed only for this call while `master` owns and
    // keeps the underlying descriptor alive.
    let borrowed = unsafe { BorrowedFd::borrow_raw(raw_fd) };
    tcsetattr(borrowed, SetArg::TCSANOW, &settings)
        .map_err(|error| TerminalError::Process(error.to_string()))
}

#[cfg(not(unix))]
fn disable_input_echo(_master: &dyn MasterPty) -> Result<(), TerminalError> {
    Ok(())
}

fn spawn_output_reader(
    mut reader: Box<dyn Read + Send>,
    output: Arc<OutputState>,
    released: Arc<AtomicBool>,
    listener_gate: Arc<ListenerGate>,
    listener: Arc<TerminalListener>,
    session_id: String,
    terminal_id: String,
) -> Result<(), TerminalError> {
    thread::Builder::new()
        .name(format!("ianvs-terminal-output-{terminal_id}"))
        .spawn(move || {
            let mut chunk = [0_u8; 8_192];
            while let Ok(count) = reader.read(&mut chunk) {
                if count == 0 {
                    break;
                }
                output
                    .buffer
                    .lock()
                    .expect("terminal output mutex poisoned")
                    .append(&chunk[..count]);
                listener_gate.wait();
                if !released.load(Ordering::Acquire) {
                    listener(TerminalRuntimeEvent::Output {
                        session_id: session_id.clone(),
                        terminal_id: terminal_id.clone(),
                        data: String::from_utf8_lossy(&chunk[..count]).into_owned(),
                    });
                }
            }
            output.done.store(true, Ordering::Release);
            output.notify.notify_waiters();
        })
        .map(|_| ())
        .map_err(|error| TerminalError::Process(error.to_string()))
}

async fn wait_for_output_done(output: &OutputState) {
    loop {
        let notified = output.notify.notified();
        if output.done.load(Ordering::Acquire) {
            return;
        }
        notified.await;
    }
}

fn spawn_child_waiter(
    mut child: Box<dyn portable_pty::Child + Send + Sync>,
    exit_state: Arc<ExitState>,
    released: Arc<AtomicBool>,
    listener_gate: Arc<ListenerGate>,
    listener: Arc<TerminalListener>,
    session_id: String,
    terminal_id: String,
) -> Result<(), TerminalError> {
    thread::Builder::new()
        .name(format!("ianvs-terminal-wait-{terminal_id}"))
        .spawn(move || {
            let exit = match child.wait() {
                Ok(status) => TerminalExit {
                    exit_code: status.signal().is_none().then_some(status.exit_code()),
                    signal: status.signal().map(ToOwned::to_owned),
                },
                Err(error) => TerminalExit {
                    exit_code: None,
                    signal: Some(format!("wait failed: {error}")),
                },
            };
            listener_gate.wait();
            if !released.load(Ordering::Acquire) {
                listener(TerminalRuntimeEvent::Exited {
                    session_id,
                    terminal_id,
                    exit: exit.clone(),
                });
            }
            *exit_state
                .value
                .lock()
                .expect("terminal exit mutex poisoned") = Some(exit);
            exit_state.notify.notify_waiters();
        })
        .map(|_| ())
        .map_err(|error| TerminalError::Process(error.to_string()))
}
