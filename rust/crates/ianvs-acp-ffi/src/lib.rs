//! C ABI host adapter for `ianvs-acp-core`.
//!
//! The ABI exposes product operations and versioned ianvs event envelopes. ACP
//! JSON-RPC frames never cross this boundary.

#![allow(clippy::missing_panics_doc)]

use std::ffi::{CStr, CString, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::ptr;
use std::sync::Mutex;
use std::time::Duration;

use ianvs_acp_core::{
    AgentLaunchConfig, DurableWorkflow, ExecutorLeaseCommand, ExecutorTakeoverRequest,
    ExecutorTaskInboxCommand, PermissionDecision, PromptAttachmentInput, RuntimeEventEnvelope,
    RuntimeHandle, SchedulerClaimRequest, SchedulerConfig, SchedulerRuntimeStatus,
    SessionConfigValueProjection, TASK_INBOX_SCHEMA, TaskInboxCommand, TaskInboxSnapshot,
    WorkflowCommand,
};

/// Opaque native runtime owned by the Dart host.
pub struct IanvsRuntime {
    runtime: Option<RuntimeHandle>,
    pending_event: Mutex<Option<RuntimeEventEnvelope>>,
    last_error: Mutex<Option<String>>,
}

impl IanvsRuntime {
    fn new() -> Self {
        Self {
            runtime: Some(RuntimeHandle::new()),
            pending_event: Mutex::new(None),
            last_error: Mutex::new(None),
        }
    }

    fn run(&self, operation: impl FnOnce(&RuntimeHandle) -> Result<(), String>) -> bool {
        let Some(runtime) = self.runtime.as_ref() else {
            *self.last_error.lock().expect("last error mutex poisoned") =
                Some("native runtime has been freed".to_string());
            return false;
        };
        match catch_unwind(AssertUnwindSafe(|| operation(runtime))) {
            Ok(Ok(())) => {
                *self.last_error.lock().expect("last error mutex poisoned") = None;
                true
            }
            Ok(Err(message)) => {
                *self.last_error.lock().expect("last error mutex poisoned") = Some(message);
                false
            }
            Err(_) => {
                *self.last_error.lock().expect("last error mutex poisoned") =
                    Some("native runtime panicked".to_string());
                false
            }
        }
    }
}

/// Opaque durable workflow authority owned by the Dart host.
pub struct IanvsWorkflow {
    workflow: Mutex<Option<DurableWorkflow>>,
    last_error: Mutex<Option<String>>,
}

impl IanvsWorkflow {
    fn new() -> Self {
        Self {
            workflow: Mutex::new(None),
            last_error: Mutex::new(None),
        }
    }

    fn run_string(
        &self,
        operation: impl FnOnce(&mut Option<DurableWorkflow>) -> Result<String, String>,
    ) -> *mut c_char {
        let result = catch_unwind(AssertUnwindSafe(|| {
            let mut workflow = self.workflow.lock().expect("workflow mutex poisoned");
            operation(&mut workflow)
        }));
        match result {
            Ok(Ok(value)) => {
                *self.last_error.lock().expect("last error mutex poisoned") = None;
                into_c_string(value)
            }
            Ok(Err(message)) => {
                *self.last_error.lock().expect("last error mutex poisoned") = Some(message);
                ptr::null_mut()
            }
            Err(_) => {
                *self.last_error.lock().expect("last error mutex poisoned") =
                    Some("native workflow host panicked".to_string());
                ptr::null_mut()
            }
        }
    }
}

/// ABI version for compatibility checks before any other call.
#[unsafe(no_mangle)]
pub extern "C" fn ianvs_acp_ffi_version() -> u32 {
    9
}

/// Allocate a new, stopped runtime.
#[unsafe(no_mangle)]
pub extern "C" fn ianvs_acp_runtime_new() -> *mut IanvsRuntime {
    catch_unwind(|| Box::into_raw(Box::new(IanvsRuntime::new()))).unwrap_or(ptr::null_mut())
}

/// Dispose and free a runtime.
///
/// # Safety
///
/// `runtime` must be null or a live pointer returned by
/// [`ianvs_acp_runtime_new`] that has not already been freed. No other ABI call
/// may use the pointer concurrently with this function.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ianvs_acp_runtime_free(runtime: *mut IanvsRuntime) {
    if runtime.is_null() {
        return;
    }
    // SAFETY: required by this function's contract.
    let mut runtime = unsafe { Box::from_raw(runtime) };
    if let Some(handle) = runtime.runtime.take() {
        let _ = handle.join();
    }
}

/// Start one local ACP agent. `config_json` is an `AgentLaunchConfig`, not ACP.
///
/// # Safety
///
/// `runtime` and `config_json` must be live pointers for this call. The string
/// must be valid, NUL-terminated UTF-8.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ianvs_acp_start_agent(
    runtime: *mut IanvsRuntime,
    config_json: *const c_char,
) -> bool {
    let Some(runtime) = (unsafe { runtime.as_ref() }) else {
        return false;
    };
    runtime.run(|handle| {
        let json = unsafe { read_string(config_json, "configJson") }?;
        let config: AgentLaunchConfig = serde_json::from_str(&json)
            .map_err(|error| format!("invalid agent config: {error}"))?;
        handle
            .start_agent(config)
            .map_err(|error| error.to_string())
    })
}

/// Request creation of a Rust-owned session.
///
/// # Safety
///
/// All pointer arguments must remain valid for this call and string pointers
/// must reference NUL-terminated UTF-8.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ianvs_acp_create_session(
    runtime: *mut IanvsRuntime,
    request_id: *const c_char,
    cwd: *const c_char,
    additional_directories_json: *const c_char,
) -> bool {
    let Some(runtime) = (unsafe { runtime.as_ref() }) else {
        return false;
    };
    runtime.run(|handle| {
        let request_id = unsafe { read_string(request_id, "requestId") }?;
        let cwd = unsafe { read_string(cwd, "cwd") }?;
        let directories_json =
            unsafe { read_string(additional_directories_json, "additionalDirectoriesJson") }?;
        let directories: Vec<String> = serde_json::from_str(&directories_json)
            .map_err(|error| format!("invalid additional directories: {error}"))?;
        handle
            .create_session(request_id, cwd, directories)
            .map_err(|error| error.to_string())
    })
}

/// Load or resume an existing session through the capability selected by Core.
///
/// # Safety
///
/// All pointer arguments must remain valid for this call and string pointers
/// must reference NUL-terminated UTF-8.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ianvs_acp_restore_session(
    runtime: *mut IanvsRuntime,
    request_id: *const c_char,
    session_id: *const c_char,
    cwd: *const c_char,
    additional_directories_json: *const c_char,
    replay_history: bool,
) -> bool {
    let Some(runtime) = (unsafe { runtime.as_ref() }) else {
        return false;
    };
    runtime.run(|handle| {
        let directories_json =
            unsafe { read_string(additional_directories_json, "additionalDirectoriesJson") }?;
        let directories: Vec<String> = serde_json::from_str(&directories_json)
            .map_err(|error| format!("invalid additional directories: {error}"))?;
        handle
            .restore_session(
                unsafe { read_string(request_id, "requestId") }?,
                unsafe { read_string(session_id, "sessionId") }?,
                unsafe { read_string(cwd, "cwd") }?,
                directories,
                replay_history,
            )
            .map_err(|error| error.to_string())
    })
}

/// Request the complete bounded session catalog.
///
/// # Safety
///
/// All pointer arguments must remain valid for this call and string pointers
/// must reference NUL-terminated UTF-8.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ianvs_acp_list_sessions(
    runtime: *mut IanvsRuntime,
    request_id: *const c_char,
) -> bool {
    let Some(runtime) = (unsafe { runtime.as_ref() }) else {
        return false;
    };
    runtime.run(|handle| {
        handle
            .list_sessions(unsafe { read_string(request_id, "requestId") }?)
            .map_err(|error| error.to_string())
    })
}

/// Close a Rust-owned active session.
///
/// # Safety
///
/// All pointer arguments must remain valid for this call and string pointers
/// must reference NUL-terminated UTF-8.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ianvs_acp_close_session(
    runtime: *mut IanvsRuntime,
    request_id: *const c_char,
    session_id: *const c_char,
) -> bool {
    let Some(runtime) = (unsafe { runtime.as_ref() }) else {
        return false;
    };
    runtime.run(|handle| {
        handle
            .close_session(unsafe { read_string(request_id, "requestId") }?, unsafe {
                read_string(session_id, "sessionId")
            }?)
            .map_err(|error| error.to_string())
    })
}

/// Delete a session from the agent-owned catalog.
///
/// # Safety
///
/// All pointer arguments must remain valid for this call and string pointers
/// must reference NUL-terminated UTF-8.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ianvs_acp_delete_session(
    runtime: *mut IanvsRuntime,
    request_id: *const c_char,
    session_id: *const c_char,
) -> bool {
    let Some(runtime) = (unsafe { runtime.as_ref() }) else {
        return false;
    };
    runtime.run(|handle| {
        handle
            .delete_session(unsafe { read_string(request_id, "requestId") }?, unsafe {
                read_string(session_id, "sessionId")
            }?)
            .map_err(|error| error.to_string())
    })
}

/// Authenticate using one method advertised by the initialized agent.
///
/// # Safety
///
/// All pointer arguments must remain valid for this call and string pointers
/// must reference NUL-terminated UTF-8.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ianvs_acp_authenticate(
    runtime: *mut IanvsRuntime,
    request_id: *const c_char,
    method_id: *const c_char,
) -> bool {
    let Some(runtime) = (unsafe { runtime.as_ref() }) else {
        return false;
    };
    runtime.run(|handle| {
        handle
            .authenticate(unsafe { read_string(request_id, "requestId") }?, unsafe {
                read_string(method_id, "methodId")
            }?)
            .map_err(|error| error.to_string())
    })
}

/// Log out through an agent that advertised the stable logout capability.
///
/// # Safety
///
/// All pointer arguments must remain valid for this call and string pointers
/// must reference NUL-terminated UTF-8.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ianvs_acp_logout(
    runtime: *mut IanvsRuntime,
    request_id: *const c_char,
) -> bool {
    let Some(runtime) = (unsafe { runtime.as_ref() }) else {
        return false;
    };
    runtime.run(|handle| {
        handle
            .logout(unsafe { read_string(request_id, "requestId") }?)
            .map_err(|error| error.to_string())
    })
}

/// Send a text prompt to an existing session.
///
/// # Safety
///
/// All pointer arguments must remain valid for this call and string pointers
/// must reference NUL-terminated UTF-8.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ianvs_acp_prompt(
    runtime: *mut IanvsRuntime,
    request_id: *const c_char,
    session_id: *const c_char,
    text: *const c_char,
) -> bool {
    let Some(runtime) = (unsafe { runtime.as_ref() }) else {
        return false;
    };
    runtime.run(|handle| {
        handle
            .prompt(
                unsafe { read_string(request_id, "requestId") }?,
                unsafe { read_string(session_id, "sessionId") }?,
                unsafe { read_string(text, "text") }?,
            )
            .map_err(|error| error.to_string())
    })
}

/// Send a prompt plus bounded user-selected local attachment metadata.
///
/// The JSON argument is an array of ianvs [`PromptAttachmentInput`] product
/// DTOs. Rust validates workspace paths and constructs typed ACP content.
///
/// # Safety
///
/// All pointer arguments must remain valid for this call and string pointers
/// must reference NUL-terminated UTF-8.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ianvs_acp_prompt_with_attachments(
    runtime: *mut IanvsRuntime,
    request_id: *const c_char,
    session_id: *const c_char,
    text: *const c_char,
    attachments_json: *const c_char,
) -> bool {
    let Some(runtime) = (unsafe { runtime.as_ref() }) else {
        return false;
    };
    runtime.run(|handle| {
        let attachments_json = unsafe { read_string(attachments_json, "attachmentsJson") }?;
        let attachments: Vec<PromptAttachmentInput> = serde_json::from_str(&attachments_json)
            .map_err(|error| format!("invalid prompt attachments: {error}"))?;
        handle
            .prompt_with_attachments(
                unsafe { read_string(request_id, "requestId") }?,
                unsafe { read_string(session_id, "sessionId") }?,
                unsafe { read_string(text, "text") }?,
                attachments,
            )
            .map_err(|error| error.to_string())
    })
}

/// Send a prompt with an independent reviewed-memory text block and bounded
/// user-selected local attachment metadata.
///
/// # Safety
///
/// All pointer arguments must remain valid for this call and string pointers
/// must reference NUL-terminated UTF-8.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ianvs_acp_prompt_with_context_and_attachments(
    runtime: *mut IanvsRuntime,
    request_id: *const c_char,
    session_id: *const c_char,
    text: *const c_char,
    memory_context: *const c_char,
    attachments_json: *const c_char,
) -> bool {
    let Some(runtime) = (unsafe { runtime.as_ref() }) else {
        return false;
    };
    runtime.run(|handle| {
        let attachments_json = unsafe { read_string(attachments_json, "attachmentsJson") }?;
        let attachments: Vec<PromptAttachmentInput> = serde_json::from_str(&attachments_json)
            .map_err(|error| format!("invalid prompt attachments: {error}"))?;
        handle
            .prompt_with_context_and_attachments(
                unsafe { read_string(request_id, "requestId") }?,
                unsafe { read_string(session_id, "sessionId") }?,
                unsafe { read_string(text, "text") }?,
                Some(unsafe { read_string(memory_context, "memoryContext") }?),
                attachments,
            )
            .map_err(|error| error.to_string())
    })
}

/// Cancel the active run for a session.
///
/// # Safety
///
/// All pointer arguments must remain valid for this call and string pointers
/// must reference NUL-terminated UTF-8.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ianvs_acp_cancel(
    runtime: *mut IanvsRuntime,
    request_id: *const c_char,
    session_id: *const c_char,
) -> bool {
    let Some(runtime) = (unsafe { runtime.as_ref() }) else {
        return false;
    };
    runtime.run(|handle| {
        handle
            .cancel(unsafe { read_string(request_id, "requestId") }?, unsafe {
                read_string(session_id, "sessionId")
            }?)
            .map_err(|error| error.to_string())
    })
}

/// Resolve a pending permission. `decision_json` is a `PermissionDecision`.
///
/// # Safety
///
/// All pointer arguments must remain valid for this call and string pointers
/// must reference NUL-terminated UTF-8.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ianvs_acp_respond_permission(
    runtime: *mut IanvsRuntime,
    request_id: *const c_char,
    decision_json: *const c_char,
) -> bool {
    let Some(runtime) = (unsafe { runtime.as_ref() }) else {
        return false;
    };
    runtime.run(|handle| {
        let decision_json = unsafe { read_string(decision_json, "decisionJson") }?;
        let decision: PermissionDecision = serde_json::from_str(&decision_json)
            .map_err(|error| format!("invalid permission decision: {error}"))?;
        handle
            .respond_permission(unsafe { read_string(request_id, "requestId") }?, decision)
            .map_err(|error| error.to_string())
    })
}

/// Change a session mode.
///
/// # Safety
///
/// All pointer arguments must remain valid for this call and string pointers
/// must reference NUL-terminated UTF-8.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ianvs_acp_set_mode(
    runtime: *mut IanvsRuntime,
    request_id: *const c_char,
    session_id: *const c_char,
    mode_id: *const c_char,
) -> bool {
    let Some(runtime) = (unsafe { runtime.as_ref() }) else {
        return false;
    };
    runtime.run(|handle| {
        handle
            .set_mode(
                unsafe { read_string(request_id, "requestId") }?,
                unsafe { read_string(session_id, "sessionId") }?,
                unsafe { read_string(mode_id, "modeId") }?,
            )
            .map_err(|error| error.to_string())
    })
}

/// Set one advertised session config option with a typed product value.
///
/// # Safety
///
/// All pointer arguments must remain valid for this call and string pointers
/// must reference NUL-terminated UTF-8.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ianvs_acp_set_config_option(
    runtime: *mut IanvsRuntime,
    request_id: *const c_char,
    session_id: *const c_char,
    config_id: *const c_char,
    value_json: *const c_char,
) -> bool {
    let Some(runtime) = (unsafe { runtime.as_ref() }) else {
        return false;
    };
    runtime.run(|handle| {
        let value_json = unsafe { read_string(value_json, "valueJson") }?;
        let value: SessionConfigValueProjection = serde_json::from_str(&value_json)
            .map_err(|error| format!("invalid session config value: {error}"))?;
        handle
            .set_config_option(
                unsafe { read_string(request_id, "requestId") }?,
                unsafe { read_string(session_id, "sessionId") }?,
                unsafe { read_string(config_id, "configId") }?,
                value,
            )
            .map_err(|error| error.to_string())
    })
}

/// Dispose runtime state and terminate the owned agent process.
///
/// # Safety
///
/// `runtime` must be a live pointer returned by [`ianvs_acp_runtime_new`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ianvs_acp_dispose(runtime: *mut IanvsRuntime) -> bool {
    let Some(runtime) = (unsafe { runtime.as_ref() }) else {
        return false;
    };
    runtime.run(|handle| handle.dispose().map_err(|error| error.to_string()))
}

/// Poll a bounded batch of versioned ianvs event envelopes.
///
/// The batch is pull-based: Rust retains ownership of an event that would
/// exceed `max_bytes` and returns it on the next call. The first event is
/// always returned even when it alone exceeds the byte target, so a valid
/// protocol event cannot deadlock the queue. Returns null on timeout/no event.
/// The returned string must be released with [`ianvs_acp_string_free`].
///
/// # Safety
///
/// `runtime` must be a live pointer returned by [`ianvs_acp_runtime_new`].
/// Calls must be single-consumer; do not poll a runtime concurrently.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ianvs_acp_poll_events(
    runtime: *mut IanvsRuntime,
    max_events: u32,
    max_bytes: u64,
    timeout_ms: u32,
) -> *mut c_char {
    const MAX_EVENTS: u32 = 4096;
    const MAX_BYTES: u64 = 64 * 1024 * 1024;
    let Some(runtime) = (unsafe { runtime.as_ref() }) else {
        return ptr::null_mut();
    };
    if max_events == 0 || max_events > MAX_EVENTS || max_bytes == 0 || max_bytes > MAX_BYTES {
        *runtime
            .last_error
            .lock()
            .expect("last error mutex poisoned") = Some(format!(
            "invalid event batch limits: maxEvents={max_events}, maxBytes={max_bytes}"
        ));
        return ptr::null_mut();
    }
    let Some(handle) = runtime.runtime.as_ref() else {
        return ptr::null_mut();
    };
    let mut pending = runtime
        .pending_event
        .lock()
        .expect("pending event mutex poisoned");
    let mut encoded_events = Vec::<String>::new();
    let mut encoded_bytes = 2_u64;
    let mut has_more = false;

    while encoded_events.len() < max_events as usize {
        let event = if let Some(event) = pending.take() {
            Ok(Some(event))
        } else if encoded_events.is_empty() && timeout_ms > 0 {
            handle.recv_event_timeout(Duration::from_millis(u64::from(timeout_ms.min(60_000))))
        } else {
            handle.try_recv_event()
        };
        let event = match event {
            Ok(Some(event)) => event,
            Ok(None) => break,
            Err(error) => {
                *runtime
                    .last_error
                    .lock()
                    .expect("last error mutex poisoned") = Some(error.to_string());
                break;
            }
        };
        let encoded = match serde_json::to_string(&event) {
            Ok(encoded) => encoded,
            Err(error) => {
                *runtime
                    .last_error
                    .lock()
                    .expect("last error mutex poisoned") =
                    Some(format!("failed to encode runtime event: {error}"));
                break;
            }
        };
        let delimiter_bytes = u64::from(!encoded_events.is_empty());
        let next_bytes = encoded_bytes
            .saturating_add(delimiter_bytes)
            .saturating_add(encoded.len() as u64);
        if !encoded_events.is_empty() && next_bytes > max_bytes {
            *pending = Some(event);
            has_more = true;
            break;
        }
        encoded_bytes = next_bytes;
        encoded_events.push(encoded);
    }
    if encoded_events.len() == max_events as usize {
        has_more = true;
    }
    if encoded_events.is_empty() {
        return ptr::null_mut();
    }

    let capacity = usize::try_from(encoded_bytes)
        .unwrap_or(usize::MAX)
        .saturating_add(32);
    let mut encoded = String::with_capacity(capacity);
    encoded.push_str(r#"{"events":["#);
    for (index, event) in encoded_events.into_iter().enumerate() {
        if index > 0 {
            encoded.push(',');
        }
        encoded.push_str(&event);
    }
    encoded.push_str(if has_more {
        r#"],"hasMore":true}"#
    } else {
        r#"],"hasMore":false}"#
    });
    *runtime
        .last_error
        .lock()
        .expect("last error mutex poisoned") = None;
    into_c_string(encoded)
}

/// Copy the last synchronous host-adapter error, or return null if none.
/// The returned string must be released with [`ianvs_acp_string_free`].
///
/// # Safety
///
/// `runtime` must be a live pointer returned by [`ianvs_acp_runtime_new`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ianvs_acp_last_error(runtime: *mut IanvsRuntime) -> *mut c_char {
    let Some(runtime) = (unsafe { runtime.as_ref() }) else {
        return ptr::null_mut();
    };
    runtime
        .last_error
        .lock()
        .expect("last error mutex poisoned")
        .clone()
        .map_or(ptr::null_mut(), into_c_string)
}

/// Allocate a closed durable workflow handle.
#[unsafe(no_mangle)]
pub extern "C" fn ianvs_workflow_new() -> *mut IanvsWorkflow {
    catch_unwind(|| Box::into_raw(Box::new(IanvsWorkflow::new()))).unwrap_or(ptr::null_mut())
}

/// Close and free a durable workflow handle.
///
/// # Safety
///
/// `workflow` must be null or a live pointer returned by
/// [`ianvs_workflow_new`] that has not already been freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ianvs_workflow_free(workflow: *mut IanvsWorkflow) {
    if !workflow.is_null() {
        // SAFETY: required by this function's contract.
        drop(unsafe { Box::from_raw(workflow) });
    }
}

/// Open the authoritative `SQLite` workflow store and recover interrupted runs.
/// Returns a versioned `WorkflowOpenProjection`, or null on failure.
///
/// # Safety
///
/// `workflow` and `path` must be live pointers for this call. `path` must be a
/// valid NUL-terminated UTF-8 string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ianvs_workflow_open(
    workflow: *mut IanvsWorkflow,
    path: *const c_char,
) -> *mut c_char {
    let Some(workflow) = (unsafe { workflow.as_ref() }) else {
        return ptr::null_mut();
    };
    let path = match unsafe { read_string(path, "path") } {
        Ok(path) => path,
        Err(error) => {
            *workflow
                .last_error
                .lock()
                .expect("last error mutex poisoned") = Some(error);
            return ptr::null_mut();
        }
    };
    workflow.run_string(|slot| {
        if slot.is_some() {
            return Err("workflow handle is already open".to_string());
        }
        let authority = DurableWorkflow::open(path).map_err(|error| error.to_string())?;
        let projection = serde_json::to_string(&authority.open_projection())
            .map_err(|error| format!("failed to encode workflow projection: {error}"))?;
        *slot = Some(authority);
        Ok(projection)
    })
}

/// Apply one versioned ianvs workflow operation transactionally.
/// Returns the committed projection, or null on validation/persistence error.
///
/// # Safety
///
/// `workflow` and `command_json` must be live pointers for this call. The
/// command must be valid NUL-terminated UTF-8.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ianvs_workflow_apply(
    workflow: *mut IanvsWorkflow,
    command_json: *const c_char,
) -> *mut c_char {
    let Some(workflow) = (unsafe { workflow.as_ref() }) else {
        return ptr::null_mut();
    };
    let command_json = match unsafe { read_string(command_json, "commandJson") } {
        Ok(command) => command,
        Err(error) => {
            *workflow
                .last_error
                .lock()
                .expect("last error mutex poisoned") = Some(error);
            return ptr::null_mut();
        }
    };
    workflow.run_string(|slot| {
        let command: WorkflowCommand = serde_json::from_str(&command_json)
            .map_err(|error| format!("invalid workflow command: {error}"))?;
        let authority = slot
            .as_mut()
            .ok_or_else(|| "workflow handle is not open".to_string())?;
        let projection = authority
            .apply(command)
            .map_err(|error| error.to_string())?;
        serde_json::to_string(&projection)
            .map_err(|error| format!("failed to encode workflow projection: {error}"))
    })
}

/// Validate and stage a complete Dart `TaskInbox` v1 source snapshot.
///
/// Staging is deliberately not activation: normal workflow mutations remain
/// disabled until the full production repository adapter owns every record
/// kind. The returned projection includes normalization disclosures.
///
/// # Safety
///
/// All pointers must be live for this call and strings must be valid,
/// NUL-terminated UTF-8.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ianvs_workflow_stage_task_inbox(
    workflow: *mut IanvsWorkflow,
    snapshot_json: *const c_char,
    source_checksum: *const c_char,
) -> *mut c_char {
    let Some(workflow) = (unsafe { workflow.as_ref() }) else {
        return ptr::null_mut();
    };
    let snapshot_json = match unsafe { read_string(snapshot_json, "snapshotJson") } {
        Ok(snapshot) => snapshot,
        Err(error) => return workflow_error(workflow, error),
    };
    let source_checksum = match unsafe { read_string(source_checksum, "sourceChecksum") } {
        Ok(checksum) => checksum,
        Err(error) => return workflow_error(workflow, error),
    };
    workflow.run_string(|slot| {
        let source: TaskInboxSnapshot = serde_json::from_str(&snapshot_json)
            .map_err(|error| format!("invalid TaskInbox source: {error}"))?;
        let authority = slot
            .as_mut()
            .ok_or_else(|| "workflow handle is not open".to_string())?;
        let projection = authority
            .stage_task_inbox_import(&source, &source_checksum)
            .map_err(|error| error.to_string())?;
        serde_json::to_string(&projection)
            .map_err(|error| format!("failed to encode staged TaskInbox projection: {error}"))
    })
}

/// Read the lossless source snapshot retained during staged migration.
///
/// # Safety
///
/// `workflow` must be a live pointer returned by [`ianvs_workflow_new`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ianvs_workflow_task_inbox_source(
    workflow: *mut IanvsWorkflow,
) -> *mut c_char {
    let Some(workflow) = (unsafe { workflow.as_ref() }) else {
        return ptr::null_mut();
    };
    workflow.run_string(|slot| {
        let authority = slot
            .as_ref()
            .ok_or_else(|| "workflow handle is not open".to_string())?;
        let source = authority
            .task_inbox_source()
            .map_err(|error| error.to_string())?;
        serde_json::to_string(&serde_json::json!({
            "schemaVersion": 1,
            "taskInboxSchema": TASK_INBOX_SCHEMA,
            "source": source,
        }))
        .map_err(|error| format!("failed to encode TaskInbox source: {error}"))
    })
}

/// Materialize the staged source as a normalized current UI projection.
/// This advances migration to `ready`, which remains non-dispatchable.
///
/// # Safety
///
/// `workflow` must be a live pointer returned by [`ianvs_workflow_new`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ianvs_workflow_materialize_task_inbox(
    workflow: *mut IanvsWorkflow,
) -> *mut c_char {
    let Some(workflow) = (unsafe { workflow.as_ref() }) else {
        return ptr::null_mut();
    };
    workflow.run_string(|slot| {
        let authority = slot
            .as_mut()
            .ok_or_else(|| "workflow handle is not open".to_string())?;
        let projection = authority
            .materialize_task_inbox()
            .map_err(|error| error.to_string())?;
        serde_json::to_string(&projection)
            .map_err(|error| format!("failed to encode materialized TaskInbox projection: {error}"))
    })
}

/// Activate a materialized `TaskInbox` so its complete projection and workflow
/// state can be mutated atomically by Rust-owned product operations.
///
/// # Safety
///
/// `workflow` must be a live pointer returned by [`ianvs_workflow_new`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ianvs_workflow_activate_task_inbox(
    workflow: *mut IanvsWorkflow,
) -> *mut c_char {
    let Some(workflow) = (unsafe { workflow.as_ref() }) else {
        return ptr::null_mut();
    };
    workflow.run_string(|slot| {
        let authority = slot
            .as_mut()
            .ok_or_else(|| "workflow handle is not open".to_string())?;
        let projection = authority
            .activate_task_inbox()
            .map_err(|error| error.to_string())?;
        serde_json::to_string(&projection)
            .map_err(|error| format!("failed to encode activated TaskInbox projection: {error}"))
    })
}

/// Apply one typed `TaskInbox` product operation transactionally. The payload is
/// an ianvs command, never an ACP JSON-RPC frame.
///
/// # Safety
///
/// `workflow` and `command_json` must be live pointers for this call. The
/// command must be valid NUL-terminated UTF-8.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ianvs_workflow_apply_task_inbox(
    workflow: *mut IanvsWorkflow,
    command_json: *const c_char,
) -> *mut c_char {
    let Some(workflow) = (unsafe { workflow.as_ref() }) else {
        return ptr::null_mut();
    };
    let command_json = match unsafe { read_string(command_json, "commandJson") } {
        Ok(command) => command,
        Err(error) => return workflow_error(workflow, error),
    };
    workflow.run_string(|slot| {
        let command: TaskInboxCommand = serde_json::from_str(&command_json)
            .map_err(|error| format!("invalid TaskInbox command: {error}"))?;
        let authority = slot
            .as_mut()
            .ok_or_else(|| "workflow handle is not open".to_string())?;
        let projection = authority
            .apply_task_inbox(command)
            .map_err(|error| error.to_string())?;
        serde_json::to_string(&projection)
            .map_err(|error| format!("failed to encode TaskInbox projection: {error}"))
    })
}

/// Apply a `TaskInbox` mutation from the current fenced executor generation.
///
/// # Safety
///
/// `workflow` and `request_json` must be live pointers for this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ianvs_workflow_apply_task_inbox_as_executor(
    workflow: *mut IanvsWorkflow,
    request_json: *const c_char,
) -> *mut c_char {
    let Some(workflow) = (unsafe { workflow.as_ref() }) else {
        return ptr::null_mut();
    };
    let request_json = match unsafe { read_string(request_json, "requestJson") } {
        Ok(request) => request,
        Err(error) => return workflow_error(workflow, error),
    };
    workflow.run_string(|slot| {
        let request: ExecutorTaskInboxCommand = serde_json::from_str(&request_json)
            .map_err(|error| format!("invalid executor TaskInbox command: {error}"))?;
        let authority = slot
            .as_mut()
            .ok_or_else(|| "workflow handle is not open".to_string())?;
        let projection = authority
            .apply_task_inbox_as_executor(request)
            .map_err(|error| error.to_string())?;
        serde_json::to_string(&projection)
            .map_err(|error| format!("failed to encode TaskInbox projection: {error}"))
    })
}

/// Configure Rust-owned global scheduler admission limits.
///
/// # Safety
///
/// `workflow` and `config_json` must be live pointers for this call. The
/// config must be valid NUL-terminated UTF-8.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ianvs_workflow_scheduler_configure(
    workflow: *mut IanvsWorkflow,
    config_json: *const c_char,
) -> *mut c_char {
    let Some(workflow) = (unsafe { workflow.as_ref() }) else {
        return ptr::null_mut();
    };
    let config_json = match unsafe { read_string(config_json, "configJson") } {
        Ok(config) => config,
        Err(error) => return workflow_error(workflow, error),
    };
    workflow.run_string(|slot| {
        let config: SchedulerConfig = serde_json::from_str(&config_json)
            .map_err(|error| format!("invalid scheduler config: {error}"))?;
        let authority = slot
            .as_mut()
            .ok_or_else(|| "workflow handle is not open".to_string())?;
        authority
            .configure_scheduler(config)
            .map_err(|error| error.to_string())?;
        serde_json::to_string(&authority.projection())
            .map_err(|error| format!("failed to encode workflow projection: {error}"))
    })
}

/// Update one Rust-owned scheduler runtime-registry entry.
///
/// # Safety
///
/// `workflow` and `status_json` must be live pointers for this call. The
/// status must be valid NUL-terminated UTF-8.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ianvs_workflow_scheduler_set_runtime_status(
    workflow: *mut IanvsWorkflow,
    status_json: *const c_char,
) -> *mut c_char {
    let Some(workflow) = (unsafe { workflow.as_ref() }) else {
        return ptr::null_mut();
    };
    let status_json = match unsafe { read_string(status_json, "statusJson") } {
        Ok(status) => status,
        Err(error) => return workflow_error(workflow, error),
    };
    workflow.run_string(|slot| {
        let status: SchedulerRuntimeStatus = serde_json::from_str(&status_json)
            .map_err(|error| format!("invalid scheduler runtime status: {error}"))?;
        let authority = slot
            .as_mut()
            .ok_or_else(|| "workflow handle is not open".to_string())?;
        authority
            .set_scheduler_runtime_status(status)
            .map_err(|error| error.to_string())?;
        serde_json::to_string(&authority.projection())
            .map_err(|error| format!("failed to encode workflow projection: {error}"))
    })
}

/// Atomically select and claim the next eligible queued task.
///
/// A no-op claim returns `claim: null` without advancing the `SQLite` revision.
///
/// # Safety
///
/// `workflow` and `request_json` must be live pointers for this call. The
/// request must be valid NUL-terminated UTF-8.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ianvs_workflow_scheduler_claim_next(
    workflow: *mut IanvsWorkflow,
    request_json: *const c_char,
) -> *mut c_char {
    let Some(workflow) = (unsafe { workflow.as_ref() }) else {
        return ptr::null_mut();
    };
    let request_json = match unsafe { read_string(request_json, "requestJson") } {
        Ok(request) => request,
        Err(error) => return workflow_error(workflow, error),
    };
    workflow.run_string(|slot| {
        let request: SchedulerClaimRequest = serde_json::from_str(&request_json)
            .map_err(|error| format!("invalid scheduler claim request: {error}"))?;
        let authority = slot
            .as_mut()
            .ok_or_else(|| "workflow handle is not open".to_string())?;
        let projection = authority
            .scheduler_claim_next(request)
            .map_err(|error| error.to_string())?;
        serde_json::to_string(&projection)
            .map_err(|error| format!("failed to encode scheduler claim: {error}"))
    })
}

/// Read the latest persisted executor lease for a Run.
///
/// # Safety
///
/// `workflow` and `run_id` must be live pointers for this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ianvs_workflow_executor_lease_for_run(
    workflow: *mut IanvsWorkflow,
    run_id: *const c_char,
) -> *mut c_char {
    let Some(workflow) = (unsafe { workflow.as_ref() }) else {
        return ptr::null_mut();
    };
    let run_id = match unsafe { read_string(run_id, "runId") } {
        Ok(run_id) => run_id,
        Err(error) => return workflow_error(workflow, error),
    };
    workflow.run_string(|slot| {
        let authority = slot
            .as_ref()
            .ok_or_else(|| "workflow handle is not open".to_string())?;
        let lease = authority
            .executor_lease_for_run(&run_id)
            .map_err(|error| error.to_string())?;
        serde_json::to_string(&serde_json::json!({"lease": lease}))
            .map_err(|error| format!("failed to encode executor lease: {error}"))
    })
}

/// Query append-only Task events for one Run after an exclusive sequence
/// cursor. The bounded page can be used by reconnecting Flutter clients.
///
/// # Safety
///
/// `workflow` and `run_id` must be live pointers and `run_id` must be valid,
/// NUL-terminated UTF-8.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ianvs_workflow_runtime_events(
    workflow: *mut IanvsWorkflow,
    run_id: *const c_char,
    after_sequence: u64,
    limit: u32,
) -> *mut c_char {
    let Some(workflow) = (unsafe { workflow.as_ref() }) else {
        return ptr::null_mut();
    };
    let run_id = match unsafe { read_string(run_id, "runId") } {
        Ok(run_id) => run_id,
        Err(error) => return workflow_error(workflow, error),
    };
    workflow.run_string(|slot| {
        let authority = slot
            .as_ref()
            .ok_or_else(|| "workflow handle is not open".to_string())?;
        let page = authority
            .runtime_events(&run_id, after_sequence, limit as usize)
            .map_err(|error| error.to_string())?;
        serde_json::to_string(&page)
            .map_err(|error| format!("failed to encode runtime event page: {error}"))
    })
}

/// Apply a typed executor ownership command.
///
/// # Safety
///
/// `workflow` and `command_json` must be live pointers for this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ianvs_workflow_executor_lease_command(
    workflow: *mut IanvsWorkflow,
    command_json: *const c_char,
) -> *mut c_char {
    let Some(workflow) = (unsafe { workflow.as_ref() }) else {
        return ptr::null_mut();
    };
    let command_json = match unsafe { read_string(command_json, "commandJson") } {
        Ok(command) => command,
        Err(error) => return workflow_error(workflow, error),
    };
    workflow.run_string(|slot| {
        let command: ExecutorLeaseCommand = serde_json::from_str(&command_json)
            .map_err(|error| format!("invalid executor lease command: {error}"))?;
        let authority = slot
            .as_mut()
            .ok_or_else(|| "workflow handle is not open".to_string())?;
        let lease = authority
            .apply_executor_lease_command(&command)
            .map_err(|error| error.to_string())?;
        serde_json::to_string(&lease)
            .map_err(|error| format!("failed to encode executor lease: {error}"))
    })
}

/// Replace an expired executor lease with the next fencing generation.
///
/// # Safety
///
/// `workflow` and `request_json` must be live pointers for this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ianvs_workflow_executor_takeover(
    workflow: *mut IanvsWorkflow,
    request_json: *const c_char,
) -> *mut c_char {
    let Some(workflow) = (unsafe { workflow.as_ref() }) else {
        return ptr::null_mut();
    };
    let request_json = match unsafe { read_string(request_json, "requestJson") } {
        Ok(request) => request,
        Err(error) => return workflow_error(workflow, error),
    };
    workflow.run_string(|slot| {
        let request: ExecutorTakeoverRequest = serde_json::from_str(&request_json)
            .map_err(|error| format!("invalid executor takeover request: {error}"))?;
        let authority = slot
            .as_mut()
            .ok_or_else(|| "workflow handle is not open".to_string())?;
        let lease = authority
            .takeover_executor_lease(&request)
            .map_err(|error| error.to_string())?;
        serde_json::to_string(&lease)
            .map_err(|error| format!("failed to encode executor lease: {error}"))
    })
}

/// Read the normalized current `TaskInbox` projection, if materialized.
///
/// # Safety
///
/// `workflow` must be a live pointer returned by [`ianvs_workflow_new`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ianvs_workflow_current_task_inbox(
    workflow: *mut IanvsWorkflow,
) -> *mut c_char {
    let Some(workflow) = (unsafe { workflow.as_ref() }) else {
        return ptr::null_mut();
    };
    workflow.run_string(|slot| {
        let authority = slot
            .as_ref()
            .ok_or_else(|| "workflow handle is not open".to_string())?;
        serde_json::to_string(&serde_json::json!({
            "schemaVersion": 1,
            "taskInboxSchema": TASK_INBOX_SCHEMA,
            "current": authority.current_task_inbox(),
        }))
        .map_err(|error| format!("failed to encode current TaskInbox: {error}"))
    })
}

/// Read the current committed workflow projection.
///
/// # Safety
///
/// `workflow` must be a live pointer returned by [`ianvs_workflow_new`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ianvs_workflow_snapshot(workflow: *mut IanvsWorkflow) -> *mut c_char {
    let Some(workflow) = (unsafe { workflow.as_ref() }) else {
        return ptr::null_mut();
    };
    workflow.run_string(|slot| {
        let authority = slot
            .as_ref()
            .ok_or_else(|| "workflow handle is not open".to_string())?;
        serde_json::to_string(&authority.projection())
            .map_err(|error| format!("failed to encode workflow projection: {error}"))
    })
}

/// Copy the last synchronous workflow adapter error, or return null.
///
/// # Safety
///
/// `workflow` must be a live pointer returned by [`ianvs_workflow_new`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ianvs_workflow_last_error(workflow: *mut IanvsWorkflow) -> *mut c_char {
    let Some(workflow) = (unsafe { workflow.as_ref() }) else {
        return ptr::null_mut();
    };
    workflow
        .last_error
        .lock()
        .expect("last error mutex poisoned")
        .clone()
        .map_or(ptr::null_mut(), into_c_string)
}

/// Release a string allocated by this library.
///
/// # Safety
///
/// `value` must be null or a pointer returned by this library that has not
/// already been released.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ianvs_acp_string_free(value: *mut c_char) {
    if !value.is_null() {
        // SAFETY: required by this function's contract.
        drop(unsafe { CString::from_raw(value) });
    }
}

unsafe fn read_string(pointer: *const c_char, name: &str) -> Result<String, String> {
    if pointer.is_null() {
        return Err(format!("{name} must not be null"));
    }
    // SAFETY: caller promises a live NUL-terminated string for this call.
    unsafe { CStr::from_ptr(pointer) }
        .to_str()
        .map(ToOwned::to_owned)
        .map_err(|_| format!("{name} must be UTF-8"))
}

fn into_c_string(value: String) -> *mut c_char {
    CString::new(value).map_or(ptr::null_mut(), CString::into_raw)
}

fn workflow_error(workflow: &IanvsWorkflow, error: String) -> *mut c_char {
    *workflow
        .last_error
        .lock()
        .expect("last error mutex poisoned") = Some(error);
    ptr::null_mut()
}
