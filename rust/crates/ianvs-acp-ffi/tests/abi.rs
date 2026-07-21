use std::ffi::{CStr, CString};
use std::fs;

use ianvs_acp_ffi::{
    ianvs_acp_ffi_version, ianvs_acp_last_error, ianvs_acp_runtime_free, ianvs_acp_runtime_new,
    ianvs_acp_start_agent, ianvs_acp_string_free, ianvs_workflow_apply, ianvs_workflow_free,
    ianvs_workflow_last_error, ianvs_workflow_new, ianvs_workflow_open,
};

#[test]
fn abi_rejects_invalid_host_dto_without_panicking() {
    assert_eq!(ianvs_acp_ffi_version(), 7);
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

#[test]
fn workflow_abi_commits_product_operations_and_reports_transition_errors() {
    let directory = unique_temp_dir("workflow-abi");
    let workspace = directory.join("workspace");
    fs::create_dir(&workspace).unwrap();
    let database = CString::new(
        directory
            .join("workflow.sqlite3")
            .to_str()
            .expect("temporary path must be UTF-8"),
    )
    .unwrap();
    let workflow = ianvs_workflow_new();
    assert!(!workflow.is_null());
    // SAFETY: workflow and database are live for this call.
    let opened = unsafe { ianvs_workflow_open(workflow, database.as_ptr()) };
    assert!(!opened.is_null());
    // SAFETY: opened is a live library string.
    let opened_json: serde_json::Value = unsafe { CStr::from_ptr(opened) }
        .to_str()
        .map(serde_json::from_str)
        .unwrap()
        .unwrap();
    assert_eq!(opened_json["schemaVersion"], 1);
    // SAFETY: opened was allocated by this library and is freed once.
    unsafe { ianvs_acp_string_free(opened) };

    let command = CString::new(
        serde_json::json!({
            "operation": "create_task",
            "taskId": "task-1",
            "workspacePath": workspace,
            "agentName": "fixture"
        })
        .to_string(),
    )
    .unwrap();
    // SAFETY: workflow and command are live for this call.
    let applied = unsafe { ianvs_workflow_apply(workflow, command.as_ptr()) };
    assert!(!applied.is_null());
    // SAFETY: applied is a live library string.
    let applied_json: serde_json::Value = unsafe { CStr::from_ptr(applied) }
        .to_str()
        .map(serde_json::from_str)
        .unwrap()
        .unwrap();
    assert_eq!(applied_json["revision"], 1);
    assert_eq!(applied_json["snapshot"]["tasks"][0]["status"], "inbox");
    // SAFETY: applied was allocated by this library and is freed once.
    unsafe { ianvs_acp_string_free(applied) };

    let invalid = CString::new(r#"{"operation":"start_run","runId":"missing"}"#).unwrap();
    // SAFETY: workflow and command are live for this call.
    assert!(unsafe { ianvs_workflow_apply(workflow, invalid.as_ptr()) }.is_null());
    // SAFETY: workflow is live and returned error is freed below.
    let error = unsafe { ianvs_workflow_last_error(workflow) };
    assert!(!error.is_null());
    // SAFETY: error is a live library string.
    assert!(
        unsafe { CStr::from_ptr(error) }
            .to_str()
            .unwrap()
            .contains("unknown run")
    );
    // SAFETY: pointers satisfy their API contracts.
    unsafe {
        ianvs_acp_string_free(error);
        ianvs_workflow_free(workflow);
    }
    fs::remove_dir_all(directory).unwrap();
}

fn unique_temp_dir(label: &str) -> std::path::PathBuf {
    let path = std::env::temp_dir().join(format!(
        "ianvs-acp-{label}-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    fs::create_dir_all(&path).unwrap();
    path
}
