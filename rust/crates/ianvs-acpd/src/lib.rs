mod executor;
pub mod protocol;

use std::collections::{BTreeMap, BTreeSet};
use std::fs::{self, File, OpenOptions};
use std::io::{BufReader, Read, Write};
use std::os::unix::fs::{FileTypeExt, OpenOptionsExt, PermissionsExt};
use std::os::unix::io::AsRawFd;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use ianvs_acp_core::{AgentLaunchConfig, DurableWorkflow, SqliteStoragePolicy};
use protocol::{
    DAEMON_PROTOCOL_VERSION, DaemonCommand, DaemonRequest, DaemonResponse, DaemonResult,
};
use uuid::Uuid;

const MAX_REQUEST_BYTES: usize = 16 * 1024 * 1024;
const MAX_RESPONSE_BYTES: usize = 32 * 1024 * 1024;
const MAX_AGENTS: usize = 64;
const MAX_CLIENTS: usize = 16;

#[derive(Debug)]
pub enum DaemonError {
    Io(std::io::Error),
    Workflow(String),
    InvalidSocket(String),
    AlreadyRunning,
}

impl std::fmt::Display for DaemonError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Io(error) => write!(formatter, "{error}"),
            Self::Workflow(error) | Self::InvalidSocket(error) => formatter.write_str(error),
            Self::AlreadyRunning => formatter.write_str("ianvs-acpd is already running"),
        }
    }
}

impl std::error::Error for DaemonError {}

impl From<std::io::Error> for DaemonError {
    fn from(error: std::io::Error) -> Self {
        Self::Io(error)
    }
}

pub struct DaemonHost {
    socket_path: PathBuf,
    listener: UnixListener,
    _database_lock: File,
    state: Arc<Mutex<DaemonState>>,
    shutdown: Arc<AtomicBool>,
    active_clients: Arc<AtomicUsize>,
    allow_shutdown: bool,
}

struct DaemonState {
    database_path: PathBuf,
    host_instance_id: String,
    workflow: DurableWorkflow,
    agents: BTreeMap<String, AgentLaunchConfig>,
    busy_agents: BTreeSet<String>,
}

impl DaemonHost {
    /// Bind the single workflow owner to a local Unix socket.
    ///
    /// # Errors
    ///
    /// Returns an error for unsafe paths, an already-owned database, socket
    /// setup failures, or an invalid durable workflow.
    pub fn bind(
        database_path: impl AsRef<Path>,
        socket_path: impl AsRef<Path>,
        allow_shutdown: bool,
    ) -> Result<Self, DaemonError> {
        Self::bind_with_storage_policy(
            database_path,
            socket_path,
            allow_shutdown,
            SqliteStoragePolicy::default(),
        )
    }

    /// Binds the daemon with an explicit durable storage policy.
    ///
    /// # Errors
    ///
    /// Returns an error for unsafe paths, an already-owned database, socket
    /// setup failures, storage initialization failures, or invalid workflow
    /// state.
    pub fn bind_with_storage_policy(
        database_path: impl AsRef<Path>,
        socket_path: impl AsRef<Path>,
        allow_shutdown: bool,
        storage_policy: SqliteStoragePolicy,
    ) -> Result<Self, DaemonError> {
        let database_path = database_path.as_ref().to_path_buf();
        let socket_path = socket_path.as_ref().to_path_buf();
        prepare_socket_path(&socket_path)?;
        let database_lock = lock_database(&database_path)?;
        let workflow = DurableWorkflow::open_with_storage_policy(&database_path, storage_policy)
            .map_err(|error| DaemonError::Workflow(error.to_string()))?;
        let listener = UnixListener::bind(&socket_path)?;
        fs::set_permissions(&socket_path, fs::Permissions::from_mode(0o600))?;
        listener.set_nonblocking(true)?;
        Ok(Self {
            socket_path,
            listener,
            _database_lock: database_lock,
            state: Arc::new(Mutex::new(DaemonState {
                database_path,
                host_instance_id: format!("daemon-{}", Uuid::new_v4()),
                workflow,
                agents: BTreeMap::new(),
                busy_agents: BTreeSet::new(),
            })),
            shutdown: Arc::new(AtomicBool::new(false)),
            active_clients: Arc::new(AtomicUsize::new(0)),
            allow_shutdown,
        })
    }

    /// Serve bounded IPC clients until the host is shut down.
    ///
    /// # Errors
    ///
    /// Returns an error when accepting a client or spawning its handler fails.
    pub fn serve(self) -> Result<(), DaemonError> {
        let dispatcher =
            executor::spawn_dispatcher(Arc::clone(&self.state), Arc::clone(&self.shutdown))?;
        while !self.shutdown.load(Ordering::Acquire) {
            match self.listener.accept() {
                Ok((stream, _)) => {
                    stream.set_nonblocking(false)?;
                    if self.active_clients.fetch_add(1, Ordering::AcqRel) >= MAX_CLIENTS {
                        self.active_clients.fetch_sub(1, Ordering::AcqRel);
                        drop(stream);
                        continue;
                    }
                    let state = Arc::clone(&self.state);
                    let shutdown = Arc::clone(&self.shutdown);
                    let active_clients = Arc::clone(&self.active_clients);
                    let allow_shutdown = self.allow_shutdown;
                    let spawned = thread::Builder::new()
                        .name("ianvs-acpd-client".to_string())
                        .spawn(move || {
                            let _guard = ClientGuard(active_clients);
                            handle_client(stream, &state, &shutdown, allow_shutdown);
                        });
                    if let Err(error) = spawned {
                        self.active_clients.fetch_sub(1, Ordering::AcqRel);
                        return Err(error.into());
                    }
                }
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    thread::sleep(Duration::from_millis(25));
                }
                Err(error) => return Err(error.into()),
            }
        }
        let _ = dispatcher.join();
        Ok(())
    }

    #[must_use]
    pub fn socket_path(&self) -> &Path {
        &self.socket_path
    }
}

struct ClientGuard(Arc<AtomicUsize>);

impl Drop for ClientGuard {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::AcqRel);
    }
}

fn lock_database(database_path: &Path) -> Result<File, DaemonError> {
    let mut lock_name = database_path.as_os_str().to_os_string();
    lock_name.push(".ianvs-acpd.lock");
    let lock_path = PathBuf::from(lock_name);
    let lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .mode(0o600)
        .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
        .open(lock_path)?;
    lock.set_permissions(fs::Permissions::from_mode(0o600))?;
    // SAFETY: `lock` owns a live file descriptor for the duration of the host.
    let result = unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
    if result == 0 {
        return Ok(lock);
    }
    let error = std::io::Error::last_os_error();
    if error
        .raw_os_error()
        .is_some_and(|code| code == libc::EWOULDBLOCK || code == libc::EAGAIN)
    {
        return Err(DaemonError::AlreadyRunning);
    }
    Err(error.into())
}

impl Drop for DaemonHost {
    fn drop(&mut self) {
        self.shutdown.store(true, Ordering::Release);
        let _ = fs::remove_file(&self.socket_path);
    }
}

fn handle_client(
    mut stream: UnixStream,
    state: &Arc<Mutex<DaemonState>>,
    shutdown: &Arc<AtomicBool>,
    allow_shutdown: bool,
) {
    let Ok(reader_stream) = stream.try_clone() else {
        return;
    };
    let mut reader = BufReader::new(reader_stream);
    loop {
        let Ok(Some(encoded)) = read_bounded_line(&mut reader) else {
            return;
        };
        let response = match serde_json::from_slice::<DaemonRequest>(&encoded) {
            Ok(request) => execute_request(request, state, shutdown, allow_shutdown),
            Err(error) => DaemonResponse::error(
                "invalid-request".to_string(),
                "invalid_request",
                format!("invalid daemon request: {error}"),
            ),
        };
        let mut encoded = match serde_json::to_vec(&response) {
            Ok(encoded) if encoded.len() <= MAX_RESPONSE_BYTES => encoded,
            _ => serde_json::to_vec(&DaemonResponse::error(
                response.request_id,
                "response_too_large",
                "daemon response exceeded its bounded size",
            ))
            .unwrap_or_default(),
        };
        encoded.push(b'\n');
        if stream.write_all(&encoded).is_err() || stream.flush().is_err() {
            return;
        }
    }
}

fn execute_request(
    request: DaemonRequest,
    state: &Arc<Mutex<DaemonState>>,
    shutdown: &Arc<AtomicBool>,
    allow_shutdown: bool,
) -> DaemonResponse {
    let request_id = request.request_id;
    if request.schema_version != DAEMON_PROTOCOL_VERSION {
        return DaemonResponse::error(
            request_id,
            "unsupported_schema",
            "unsupported daemon protocol schema",
        );
    }
    if request_id.is_empty() || request_id.trim() != request_id || request_id.len() > 256 {
        return DaemonResponse::error(
            "invalid-request".to_string(),
            "invalid_request_id",
            "requestId must be canonical bounded text",
        );
    }
    let result = execute_command(request.command, state, shutdown, allow_shutdown);
    match result {
        Ok(result) => DaemonResponse::success(request_id, result),
        Err(error) => DaemonResponse::error(request_id, "command_failed", error),
    }
}

#[allow(clippy::too_many_lines)]
fn execute_command(
    command: DaemonCommand,
    state: &Arc<Mutex<DaemonState>>,
    shutdown: &Arc<AtomicBool>,
    allow_shutdown: bool,
) -> Result<DaemonResult, String> {
    let mut state = state
        .lock()
        .map_err(|_| "daemon state lock is poisoned".to_string())?;
    match command {
        DaemonCommand::Ping => Ok(DaemonResult::Pong {
            host_instance_id: state.host_instance_id.clone(),
        }),
        DaemonCommand::OpenProjection { database_path } => {
            if Path::new(&database_path) != state.database_path {
                return Err(
                    "daemon database path does not match the requested authority".to_string(),
                );
            }
            Ok(DaemonResult::OpenProjection {
                projection: state.workflow.open_projection(),
            })
        }
        DaemonCommand::StageTaskInbox {
            source,
            source_checksum,
        } => Ok(DaemonResult::TaskInboxStage {
            projection: state
                .workflow
                .stage_task_inbox_import(&source, &source_checksum)
                .map_err(|error| error.to_string())?,
        }),
        DaemonCommand::TaskInboxSource => Ok(DaemonResult::TaskInboxSnapshot {
            snapshot: state
                .workflow
                .task_inbox_source()
                .map_err(|error| error.to_string())?,
        }),
        DaemonCommand::MaterializeTaskInbox => Ok(DaemonResult::TaskInboxProjection {
            projection: state
                .workflow
                .materialize_task_inbox()
                .map_err(|error| error.to_string())?,
        }),
        DaemonCommand::ActivateTaskInbox => Ok(DaemonResult::TaskInboxProjection {
            projection: state
                .workflow
                .activate_task_inbox()
                .map_err(|error| error.to_string())?,
        }),
        DaemonCommand::ApplyTaskInbox { command } => Ok(DaemonResult::TaskInboxProjection {
            projection: state
                .workflow
                .apply_task_inbox(command)
                .map_err(|error| error.to_string())?,
        }),
        DaemonCommand::ApplyTaskInboxAsExecutor { request } => {
            Ok(DaemonResult::TaskInboxProjection {
                projection: state
                    .workflow
                    .apply_task_inbox_as_executor(request)
                    .map_err(|error| error.to_string())?,
            })
        }
        DaemonCommand::CurrentTaskInbox => Ok(DaemonResult::TaskInboxSnapshot {
            snapshot: state.workflow.current_task_inbox().cloned(),
        }),
        DaemonCommand::CurrentTaskInboxProjection => Ok(DaemonResult::CurrentTaskInboxProjection {
            projection: state.workflow.current_task_inbox_projection(),
        }),
        DaemonCommand::ConfigureScheduler { config } => {
            state
                .workflow
                .configure_scheduler(config)
                .map_err(|error| error.to_string())?;
            Ok(DaemonResult::WorkflowProjection {
                projection: state.workflow.projection(),
            })
        }
        DaemonCommand::SetSchedulerRuntimeStatus { status } => {
            state
                .workflow
                .set_scheduler_runtime_status(status)
                .map_err(|error| error.to_string())?;
            Ok(DaemonResult::WorkflowProjection {
                projection: state.workflow.projection(),
            })
        }
        DaemonCommand::SchedulerClaimNext { request } => Ok(DaemonResult::SchedulerClaim {
            projection: state
                .workflow
                .scheduler_claim_next(request)
                .map_err(|error| error.to_string())?,
        }),
        DaemonCommand::ExecutorLeaseForRun { run_id } => Ok(DaemonResult::ExecutorLease {
            lease: state
                .workflow
                .executor_lease_for_run(&run_id)
                .map_err(|error| error.to_string())?,
        }),
        DaemonCommand::ExecutorLeaseCommand { command } => Ok(DaemonResult::ExecutorLease {
            lease: Some(
                state
                    .workflow
                    .apply_executor_lease_command(&command)
                    .map_err(|error| error.to_string())?,
            ),
        }),
        DaemonCommand::ExecutorTakeover { request } => Ok(DaemonResult::ExecutorLease {
            lease: Some(
                state
                    .workflow
                    .takeover_executor_lease(&request)
                    .map_err(|error| error.to_string())?,
            ),
        }),
        DaemonCommand::RuntimeEvents {
            run_id,
            after_sequence,
            limit,
        } => Ok(DaemonResult::RuntimeEvents {
            page: state
                .workflow
                .runtime_events(&run_id, after_sequence, limit)
                .map_err(|error| error.to_string())?,
        }),
        DaemonCommand::ConfigureStorage {
            max_database_bytes,
            retention_days,
        } => {
            let policy = SqliteStoragePolicy::new(max_database_bytes, retention_days)
                .map_err(str::to_string)?;
            state
                .workflow
                .configure_storage_policy(policy)
                .map_err(|error| error.to_string())?;
            Ok(DaemonResult::Ack)
        }
        DaemonCommand::ConfigureAgents { agents } => {
            if agents.len() > MAX_AGENTS {
                return Err(format!("agent configuration exceeds {MAX_AGENTS} entries"));
            }
            let mut configured = BTreeMap::new();
            for agent in agents {
                agent.validate().map_err(str::to_string)?;
                if configured.insert(agent.agent_name.clone(), agent).is_some() {
                    return Err("agent configuration contains duplicate names".to_string());
                }
            }
            let agent_names = configured.keys().cloned().collect();
            state.agents = configured;
            Ok(DaemonResult::AgentsConfigured { agent_names })
        }
        DaemonCommand::RegisterWorkflowDefinition { definition } => {
            state
                .workflow
                .register_workflow_definition(&definition)
                .map_err(|error| error.to_string())?;
            Ok(DaemonResult::Ack)
        }
        DaemonCommand::WorkflowDefinition {
            definition_id,
            version,
        } => Ok(DaemonResult::WorkflowDefinition {
            definition: state
                .workflow
                .workflow_definition(&definition_id, version)
                .map_err(|error| error.to_string())?,
        }),
        DaemonCommand::CreateWorkflowRun { run } => Ok(DaemonResult::WorkflowRun {
            run: Some(
                state
                    .workflow
                    .create_workflow_run(&run)
                    .map_err(|error| error.to_string())?,
            ),
        }),
        DaemonCommand::WorkflowRun { run_id } => Ok(DaemonResult::WorkflowRun {
            run: state
                .workflow
                .workflow_run(&run_id)
                .map_err(|error| error.to_string())?,
        }),
        DaemonCommand::StartWorkflowStep {
            run_id,
            step_id,
            input,
            now,
        } => Ok(DaemonResult::WorkflowRun {
            run: Some(
                state
                    .workflow
                    .start_workflow_step(&run_id, &step_id, input, &now)
                    .map_err(|error| error.to_string())?,
            ),
        }),
        DaemonCommand::CompleteWorkflowStep {
            run_id,
            step_id,
            output,
            artifacts,
            now,
        } => Ok(DaemonResult::WorkflowRun {
            run: Some(
                state
                    .workflow
                    .complete_workflow_step(&run_id, &step_id, output, artifacts, &now)
                    .map_err(|error| error.to_string())?,
            ),
        }),
        DaemonCommand::SubmitWorkflowStepResult {
            run_id,
            step_id,
            raw,
            artifacts,
            now,
        } => Ok(DaemonResult::WorkflowRun {
            run: Some(
                state
                    .workflow
                    .submit_workflow_step_result(&run_id, &step_id, &raw, artifacts, &now)
                    .map_err(|error| error.to_string())?,
            ),
        }),
        DaemonCommand::ProposeWorkflowPlan { run_id, proposal } => Ok(DaemonResult::WorkflowRun {
            run: Some(
                state
                    .workflow
                    .propose_workflow_plan(&run_id, proposal)
                    .map_err(|error| error.to_string())?,
            ),
        }),
        DaemonCommand::ActivateWorkflowPlan {
            run_id,
            proposal_id,
            now,
        } => Ok(DaemonResult::WorkflowRun {
            run: Some(
                state
                    .workflow
                    .activate_workflow_plan(&run_id, &proposal_id, &now)
                    .map_err(|error| error.to_string())?,
            ),
        }),
        DaemonCommand::RecordWorkflowUsage {
            run_id,
            input_tokens,
            output_tokens,
            cost_micros,
            now,
        } => Ok(DaemonResult::WorkflowRun {
            run: Some(
                state
                    .workflow
                    .record_workflow_usage(&run_id, input_tokens, output_tokens, cost_micros, &now)
                    .map_err(|error| error.to_string())?,
            ),
        }),
        DaemonCommand::Shutdown => {
            if !allow_shutdown {
                return Err("daemon shutdown is disabled for this host".to_string());
            }
            shutdown.store(true, Ordering::Release);
            Ok(DaemonResult::Ack)
        }
    }
}

fn read_bounded_line(
    reader: &mut BufReader<UnixStream>,
) -> Result<Option<Vec<u8>>, std::io::Error> {
    let mut encoded = Vec::new();
    let mut byte = [0_u8; 1];
    loop {
        match reader.read(&mut byte)? {
            0 if encoded.is_empty() => return Ok(None),
            0 => {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::UnexpectedEof,
                    "daemon request ended without a newline",
                ));
            }
            _ if byte[0] == b'\n' => return Ok(Some(encoded)),
            _ => {
                if encoded.len() >= MAX_REQUEST_BYTES {
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::InvalidData,
                        "daemon request exceeded its bounded size",
                    ));
                }
                encoded.push(byte[0]);
            }
        }
    }
}

fn prepare_socket_path(path: &Path) -> Result<(), DaemonError> {
    if !path.is_absolute() {
        return Err(DaemonError::InvalidSocket(
            "daemon socket path must be absolute".to_string(),
        ));
    }
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error.into()),
    };
    if !metadata.file_type().is_socket() {
        return Err(DaemonError::InvalidSocket(
            "daemon socket target exists and is not a Unix socket".to_string(),
        ));
    }
    if UnixStream::connect(path).is_ok() {
        return Err(DaemonError::AlreadyRunning);
    }
    fs::remove_file(path)?;
    Ok(())
}
