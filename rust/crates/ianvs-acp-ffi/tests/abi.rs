use std::ffi::{CStr, CString};

use ianvs_acp_ffi::{
    ianvs_acp_ffi_version, ianvs_acp_last_error, ianvs_acp_runtime_free, ianvs_acp_runtime_new,
    ianvs_acp_start_agent, ianvs_acp_string_free,
};

#[test]
fn abi_rejects_invalid_host_dto_without_panicking() {
    assert_eq!(ianvs_acp_ffi_version(), 10);
    let runtime = ianvs_acp_runtime_new();
    assert!(!runtime.is_null());
    let invalid = CString::new(r#"{"agentName":"fixture"}"#).unwrap();
    // SAFETY: runtime and string are live for each ABI call.
    assert!(!unsafe { ianvs_acp_start_agent(runtime, invalid.as_ptr()) });
    // SAFETY: runtime is still live and the returned string is freed exactly once.
    let error = unsafe { ianvs_acp_last_error(runtime) };
    assert!(!error.is_null());
    // SAFETY: error is a live NUL-terminated string allocated by the library.
    let message = unsafe { CStr::from_ptr(error) }.to_str().unwrap();
    assert!(message.contains("invalid agent config"));
    // SAFETY: both pointers satisfy their respective API contracts.
    unsafe {
        ianvs_acp_string_free(error);
        ianvs_acp_runtime_free(runtime);
    }
}
