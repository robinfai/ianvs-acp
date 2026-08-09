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
    AgentLaunchConfig, PermissionDecision, PromptAttachmentInput, RuntimeEventEnvelope,
    RuntimeHandle, SessionConfigValueProjection,
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

/// ABI version for compatibility checks before any other call.
#[unsafe(no_mangle)]
pub extern "C" fn ianvs_acp_ffi_version() -> u32 {
    10
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
