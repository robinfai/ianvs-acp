use std::io::{BufRead, BufReader, Write};
use std::process::{Command, Stdio};

#[test]
fn mcp_stdio_logs_do_not_pollute_stdout() {
    let exe = env!("CARGO_BIN_EXE_memory-core");
    let mut child = Command::new(exe)
        .args(["--mode", "mcp-stdio", "--daemon-url", "http://127.0.0.1:9"])
        .env("MEMORY_DAEMON_TOKEN", "test-token")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn mcp");

    let mut stdin = child.stdin.take().expect("stdin");
    writeln!(
        stdin,
        "{}",
        serde_json::json!({"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}})
    )
    .expect("write");

    let stdout = child.stdout.take().expect("stdout");
    let mut reader = BufReader::new(stdout);
    let mut line = String::new();
    reader.read_line(&mut line).expect("read line");
    let value: serde_json::Value = serde_json::from_str(line.trim()).expect("json rpc only");
    assert_eq!(value["jsonrpc"], "2.0");
    assert_eq!(value["id"], 1);
    assert!(value["result"]["tools"]
        .as_array()
        .unwrap()
        .iter()
        .any(|tool| tool["name"] == "memory.search"));
    assert!(value["result"]["tools"]
        .as_array()
        .unwrap()
        .iter()
        .any(|tool| tool["name"] == "memory.update"));
    assert!(value["result"]["tools"]
        .as_array()
        .unwrap()
        .iter()
        .any(|tool| tool["name"] == "memory.forget"));
    let tools = value["result"]["tools"].as_array().unwrap();
    let remember = tools
        .iter()
        .find(|tool| tool["name"] == "memory.remember")
        .expect("remember tool");
    let remember_description = remember["description"].as_str().unwrap_or_default();
    assert!(remember_description.contains("auto-approve"));
    assert!(remember_description.contains("skip"));
    assert_eq!(
        remember["inputSchema"]["required"],
        serde_json::json!(["scope", "kind", "memoryScope", "text"])
    );
    assert!(remember["inputSchema"]["properties"]["scope"]["required"]
        .as_array()
        .unwrap()
        .contains(&serde_json::json!("userId")));
    let update = tools
        .iter()
        .find(|tool| tool["name"] == "memory.update")
        .expect("update tool");
    assert_eq!(
        update["inputSchema"]["required"],
        serde_json::json!(["scope", "targetMemoryId", "proposedText"])
    );
    let forget = tools
        .iter()
        .find(|tool| tool["name"] == "memory.forget")
        .expect("forget tool");
    assert_eq!(
        forget["inputSchema"]["required"],
        serde_json::json!(["scope", "targetMemoryId"])
    );

    child.kill().ok();
    child.wait().ok();
}

#[tokio::test(flavor = "multi_thread")]
async fn mcp_stdio_search_calls_daemon() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let http = reqwest::Client::new();
    http.post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "project_rule",
            "scope": "repo",
            "text": "Use curl for local service health checks.",
            "scopeData": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1"
            }
        }))
        .send()
        .await
        .expect("create memory");

    let exe = env!("CARGO_BIN_EXE_memory-core");
    let mut child = Command::new(exe)
        .args(["--mode", "mcp-stdio", "--daemon-url", &state.base_url])
        .env("MEMORY_DAEMON_TOKEN", "test-token")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn mcp");

    let mut stdin = child.stdin.take().expect("stdin");
    writeln!(
        stdin,
        "{}",
        serde_json::json!({
            "jsonrpc": "2.0",
            "id": 7,
            "method": "tools/call",
            "params": {
                "name": "memory.search",
                "arguments": {
                    "query": "curl health checks",
                    "scope": {
                        "userId": "local-user",
                        "workspaceId": "workspace-1",
                        "repoId": "repo-1"
                    },
                    "limit": 5
                }
            }
        })
    )
    .expect("write");

    let stdout = child.stdout.take().expect("stdout");
    let mut reader = BufReader::new(stdout);
    let mut line = String::new();
    reader.read_line(&mut line).expect("read line");
    let value: serde_json::Value = serde_json::from_str(line.trim()).expect("json rpc only");
    assert_eq!(value["jsonrpc"], "2.0");
    assert_eq!(value["id"], 7);
    assert!(value["result"]["content"][0]["text"]
        .as_str()
        .unwrap()
        .contains("Use curl for local service health checks."));

    child.kill().ok();
    child.wait().ok();
}

#[tokio::test(flavor = "multi_thread")]
async fn mcp_stdio_remember_accepts_single_candidate_arguments() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");

    let exe = env!("CARGO_BIN_EXE_memory-core");
    let mut child = Command::new(exe)
        .args(["--mode", "mcp-stdio", "--daemon-url", &state.base_url])
        .env("MEMORY_DAEMON_TOKEN", "test-token")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn mcp");

    let mut stdin = child.stdin.take().expect("stdin");
    writeln!(
        stdin,
        "{}",
        serde_json::json!({
            "jsonrpc": "2.0",
            "id": 9,
            "method": "tools/call",
            "params": {
                "name": "memory.remember",
                "arguments": {
                    "scope": {
                        "userId": "local-user",
                        "workspaceId": "workspace-1",
                        "repoId": "repo-1"
                    },
                    "kind": "project_rule",
                    "memoryScope": "repo",
                    "text": "Prefer curl for local health checks.",
                    "reason": "User asked for curl-first health checks.",
                    "confidence": 0.84
                }
            }
        })
    )
    .expect("write");

    let stdout = child.stdout.take().expect("stdout");
    let mut reader = BufReader::new(stdout);
    let mut line = String::new();
    reader.read_line(&mut line).expect("read remember");
    let response: serde_json::Value = serde_json::from_str(line.trim()).expect("json rpc only");
    assert_eq!(response["id"], 9);
    assert!(response["result"]["content"][0]["text"]
        .as_str()
        .unwrap()
        .contains("Prefer curl for local health checks."));

    let pending = reqwest::Client::new()
        .get(format!(
            "{}/v1/memory/candidates?userId=local-user&repoId=repo-1&status=pending",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("list candidates")
        .json::<serde_json::Value>()
        .await
        .expect("pending json");
    assert_eq!(pending["items"].as_array().unwrap().len(), 1);
    assert_eq!(
        pending["items"][0]["text"],
        "Prefer curl for local health checks."
    );

    child.kill().ok();
    child.wait().ok();
}

#[tokio::test(flavor = "multi_thread")]
async fn mcp_stdio_remember_uses_default_auto_approve_threshold() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");

    let exe = env!("CARGO_BIN_EXE_memory-core");
    let mut child = Command::new(exe)
        .args(["--mode", "mcp-stdio", "--daemon-url", &state.base_url])
        .env("MEMORY_DAEMON_TOKEN", "test-token")
        .env("MEMORY_AUTO_APPROVE_THRESHOLD", "0.80")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn mcp");

    let mut stdin = child.stdin.take().expect("stdin");
    writeln!(
        stdin,
        "{}",
        serde_json::json!({
            "jsonrpc": "2.0",
            "id": 10,
            "method": "tools/call",
            "params": {
                "name": "memory.remember",
                "arguments": {
                    "scope": {
                        "userId": "local-user",
                        "workspaceId": "workspace-1",
                        "repoId": "repo-1"
                    },
                    "kind": "project_rule",
                    "memoryScope": "repo",
                    "text": "Prefer curl for local health checks.",
                    "reason": "User asked for curl-first health checks.",
                    "confidence": 0.84
                }
            }
        })
    )
    .expect("write");

    let stdout = child.stdout.take().expect("stdout");
    let mut reader = BufReader::new(stdout);
    let mut line = String::new();
    reader.read_line(&mut line).expect("read remember");
    let response: serde_json::Value = serde_json::from_str(line.trim()).expect("json rpc only");
    assert_eq!(response["id"], 10);
    assert!(response["result"]["content"][0]["text"]
        .as_str()
        .unwrap()
        .contains("\"approvedMemories\""));

    let active = reqwest::Client::new()
        .get(format!(
            "{}/v1/memory?userId=local-user&repoId=repo-1&status=active",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("list active memory")
        .json::<serde_json::Value>()
        .await
        .expect("active json");
    assert_eq!(active["items"].as_array().unwrap().len(), 1);
    assert_eq!(
        active["items"][0]["text"],
        "Prefer curl for local health checks."
    );

    let pending = reqwest::Client::new()
        .get(format!(
            "{}/v1/memory/candidates?userId=local-user&repoId=repo-1&status=pending",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("list candidates")
        .json::<serde_json::Value>()
        .await
        .expect("pending json");
    assert_eq!(pending["items"].as_array().unwrap().len(), 0);

    child.kill().ok();
    child.wait().ok();
}

#[tokio::test(flavor = "multi_thread")]
async fn mcp_stdio_list_uses_visible_scope_rules() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let http = reqwest::Client::new();

    let cases = [
        (
            "global",
            "Global memory from another repo.",
            "workspace-2",
            "repo-2",
            "agent-2",
            "session-2",
        ),
        (
            "workspace",
            "Workspace memory from another repo.",
            "workspace-1",
            "repo-2",
            "agent-2",
            "session-2",
        ),
        (
            "repo",
            "Repo memory for this repo.",
            "workspace-1",
            "repo-1",
            "agent-2",
            "session-2",
        ),
        (
            "session",
            "Session memory for this session.",
            "workspace-1",
            "repo-1",
            "agent-1",
            "session-1",
        ),
        (
            "session",
            "Session memory for another session.",
            "workspace-1",
            "repo-1",
            "agent-1",
            "session-2",
        ),
    ];

    for (scope, text, workspace_id, repo_id, agent_id, session_id) in cases {
        http.post(format!("{}/v1/memory", state.base_url))
            .bearer_auth("test-token")
            .json(&serde_json::json!({
                "kind": "project_rule",
                "scope": scope,
                "text": text,
                "scopeData": {
                    "userId": "local-user",
                    "workspaceId": workspace_id,
                    "repoId": repo_id,
                    "agentId": agent_id,
                    "sessionId": session_id
                }
            }))
            .send()
            .await
            .expect("create memory");
    }

    let exe = env!("CARGO_BIN_EXE_memory-core");
    let mut child = Command::new(exe)
        .args(["--mode", "mcp-stdio", "--daemon-url", &state.base_url])
        .env("MEMORY_DAEMON_TOKEN", "test-token")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn mcp");

    let mut stdin = child.stdin.take().expect("stdin");
    writeln!(
        stdin,
        "{}",
        serde_json::json!({
            "jsonrpc": "2.0",
            "id": 11,
            "method": "tools/call",
            "params": {
                "name": "memory.list",
                "arguments": {
                    "scope": {
                        "userId": "local-user",
                        "workspaceId": "workspace-1",
                        "repoId": "repo-1",
                        "agentId": "agent-1",
                        "sessionId": "session-1"
                    },
                    "status": "active"
                }
            }
        })
    )
    .expect("write list");

    let stdout = child.stdout.take().expect("stdout");
    let mut reader = BufReader::new(stdout);
    let mut line = String::new();
    reader.read_line(&mut line).expect("read list");
    let response: serde_json::Value = serde_json::from_str(line.trim()).expect("list json rpc");
    assert_eq!(response["id"], 11);
    let text = response["result"]["content"][0]["text"]
        .as_str()
        .expect("tool text");
    assert!(text.contains("Global memory from another repo."));
    assert!(text.contains("Workspace memory from another repo."));
    assert!(text.contains("Repo memory for this repo."));
    assert!(text.contains("Session memory for this session."));
    assert!(!text.contains("Session memory for another session."));

    child.kill().ok();
    child.wait().ok();
}

#[tokio::test(flavor = "multi_thread")]
async fn mcp_stdio_update_and_forget_create_change_requests() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let http = reqwest::Client::new();
    let memory = http
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "project_rule",
            "scope": "repo",
            "text": "Use curl for local service health checks.",
            "scopeData": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1"
            }
        }))
        .send()
        .await
        .expect("create memory")
        .json::<serde_json::Value>()
        .await
        .expect("memory json");
    let memory_id = memory["id"].as_str().expect("memory id");

    let exe = env!("CARGO_BIN_EXE_memory-core");
    let mut child = Command::new(exe)
        .args(["--mode", "mcp-stdio", "--daemon-url", &state.base_url])
        .env("MEMORY_DAEMON_TOKEN", "test-token")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn mcp");

    let mut stdin = child.stdin.take().expect("stdin");
    writeln!(
        stdin,
        "{}",
        serde_json::json!({
            "jsonrpc": "2.0",
            "id": 11,
            "method": "tools/call",
            "params": {
                "name": "memory.update",
                "arguments": {
                    "scope": {
                        "userId": "local-user",
                        "workspaceId": "workspace-1",
                        "repoId": "repo-1"
                    },
                    "targetMemoryId": memory_id,
                    "proposedKind": "project_rule",
                    "proposedScope": "repo",
                    "proposedText": "Use curl and lsof for local service health checks.",
                    "reason": "Adds the preferred port inspection tool.",
                    "confidence": 0.82
                }
            }
        })
    )
    .expect("write update");
    writeln!(
        stdin,
        "{}",
        serde_json::json!({
            "jsonrpc": "2.0",
            "id": 12,
            "method": "tools/call",
            "params": {
                "name": "memory.forget",
                "arguments": {
                    "scope": {
                        "userId": "local-user",
                        "workspaceId": "workspace-1",
                        "repoId": "repo-1"
                    },
                    "targetMemoryId": memory_id,
                    "reason": "The rule is obsolete."
                }
            }
        })
    )
    .expect("write forget");

    let stdout = child.stdout.take().expect("stdout");
    let mut reader = BufReader::new(stdout);
    let mut update_line = String::new();
    reader.read_line(&mut update_line).expect("read update");
    let update_response: serde_json::Value =
        serde_json::from_str(update_line.trim()).expect("update json rpc");
    assert_eq!(update_response["id"], 11);
    assert!(update_response["result"]["content"][0]["text"]
        .as_str()
        .unwrap()
        .contains("\"action\": \"update\""));

    let mut forget_line = String::new();
    reader.read_line(&mut forget_line).expect("read forget");
    let forget_response: serde_json::Value =
        serde_json::from_str(forget_line.trim()).expect("forget json rpc");
    assert_eq!(forget_response["id"], 12);
    assert!(forget_response["result"]["content"][0]["text"]
        .as_str()
        .unwrap()
        .contains("\"action\": \"delete\""));

    let pending = http
        .get(format!(
            "{}/v1/memory/change-requests?userId=local-user&repoId=repo-1&status=pending",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("list change requests")
        .json::<serde_json::Value>()
        .await
        .expect("pending json");
    let items = pending["items"].as_array().expect("items");
    assert_eq!(items.len(), 2);
    assert!(items
        .iter()
        .any(|item| item["action"] == "update" && item["source"] == "mcp"));
    assert!(items
        .iter()
        .any(|item| item["action"] == "delete" && item["source"] == "mcp"));

    child.kill().ok();
    child.wait().ok();
}

#[tokio::test(flavor = "multi_thread")]
async fn mcp_stdio_update_and_forget_without_confidence_skip_under_default_policy() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let http = reqwest::Client::new();
    let memory = http
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "project_rule",
            "scope": "repo",
            "text": "Use curl for local service health checks.",
            "scopeData": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1"
            }
        }))
        .send()
        .await
        .expect("create memory")
        .json::<serde_json::Value>()
        .await
        .expect("memory json");
    let memory_id = memory["id"].as_str().expect("memory id");

    let exe = env!("CARGO_BIN_EXE_memory-core");
    let mut child = Command::new(exe)
        .args(["--mode", "mcp-stdio", "--daemon-url", &state.base_url])
        .env("MEMORY_DAEMON_TOKEN", "test-token")
        .env("MEMORY_AUTO_APPROVE_THRESHOLD", "0.90")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn mcp");

    let mut stdin = child.stdin.take().expect("stdin");
    writeln!(
        stdin,
        "{}",
        serde_json::json!({
            "jsonrpc": "2.0",
            "id": 16,
            "method": "tools/call",
            "params": {
                "name": "memory.update",
                "arguments": {
                    "scope": {
                        "userId": "local-user",
                        "workspaceId": "workspace-1",
                        "repoId": "repo-1"
                    },
                    "targetMemoryId": memory_id,
                    "proposedText": "Use curl and lsof for local service health checks.",
                    "reason": "Missing confidence should not become review noise."
                }
            }
        })
    )
    .expect("write update");
    writeln!(
        stdin,
        "{}",
        serde_json::json!({
            "jsonrpc": "2.0",
            "id": 17,
            "method": "tools/call",
            "params": {
                "name": "memory.forget",
                "arguments": {
                    "scope": {
                        "userId": "local-user",
                        "workspaceId": "workspace-1",
                        "repoId": "repo-1"
                    },
                    "targetMemoryId": memory_id,
                    "reason": "Missing confidence should not create cleanup review."
                }
            }
        })
    )
    .expect("write forget");

    let stdout = child.stdout.take().expect("stdout");
    let mut reader = BufReader::new(stdout);
    let mut update_line = String::new();
    reader.read_line(&mut update_line).expect("read update");
    let update_response: serde_json::Value =
        serde_json::from_str(update_line.trim()).expect("update json rpc");
    assert_eq!(update_response["id"], 16);
    assert!(update_response["result"]["content"][0]["text"]
        .as_str()
        .unwrap()
        .contains("\"skipped\": 1"));

    let mut forget_line = String::new();
    reader.read_line(&mut forget_line).expect("read forget");
    let forget_response: serde_json::Value =
        serde_json::from_str(forget_line.trim()).expect("forget json rpc");
    assert_eq!(forget_response["id"], 17);
    assert!(forget_response["result"]["content"][0]["text"]
        .as_str()
        .unwrap()
        .contains("\"skipped\": 1"));

    let pending = http
        .get(format!(
            "{}/v1/memory/change-requests?userId=local-user&repoId=repo-1&status=pending",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("list change requests")
        .json::<serde_json::Value>()
        .await
        .expect("pending json");
    assert_eq!(pending["items"].as_array().expect("items").len(), 0);

    child.kill().ok();
    child.wait().ok();
}

#[tokio::test(flavor = "multi_thread")]
async fn mcp_stdio_update_auto_applies_when_confidence_meets_threshold() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let http = reqwest::Client::new();
    let memory = http
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "project_rule",
            "scope": "repo",
            "text": "Use curl for local service health checks.",
            "scopeData": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1"
            }
        }))
        .send()
        .await
        .expect("create memory")
        .json::<serde_json::Value>()
        .await
        .expect("memory json");
    let memory_id = memory["id"].as_str().expect("memory id");

    let exe = env!("CARGO_BIN_EXE_memory-core");
    let mut child = Command::new(exe)
        .args(["--mode", "mcp-stdio", "--daemon-url", &state.base_url])
        .env("MEMORY_DAEMON_TOKEN", "test-token")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn mcp");

    let mut stdin = child.stdin.take().expect("stdin");
    writeln!(
        stdin,
        "{}",
        serde_json::json!({
            "jsonrpc": "2.0",
            "id": 13,
            "method": "tools/call",
            "params": {
                "name": "memory.update",
                "arguments": {
                    "scope": {
                        "userId": "local-user",
                        "workspaceId": "workspace-1",
                        "repoId": "repo-1"
                    },
                    "targetMemoryId": memory_id,
                    "proposedKind": "project_rule",
                    "proposedScope": "repo",
                    "proposedText": "Use curl and lsof for local service health checks.",
                    "reason": "Adds the preferred port inspection tool.",
                    "confidence": 0.94,
                    "autoApproveThreshold": 0.90
                }
            }
        })
    )
    .expect("write update");

    let stdout = child.stdout.take().expect("stdout");
    let mut reader = BufReader::new(stdout);
    let mut update_line = String::new();
    reader.read_line(&mut update_line).expect("read update");
    let update_response: serde_json::Value =
        serde_json::from_str(update_line.trim()).expect("update json rpc");
    assert_eq!(update_response["id"], 13);
    let update_text = update_response["result"]["content"][0]["text"]
        .as_str()
        .unwrap();
    assert!(update_text.contains("\"autoApplied\": 1"));
    assert!(update_text.contains("\"status\": \"approved\""));

    let active = http
        .get(format!(
            "{}/v1/memory?userId=local-user&repoId=repo-1&status=active",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("list active memory")
        .json::<serde_json::Value>()
        .await
        .expect("active json");
    assert_eq!(
        active["items"][0]["text"],
        "Use curl and lsof for local service health checks."
    );

    let pending = http
        .get(format!(
            "{}/v1/memory/change-requests?userId=local-user&repoId=repo-1&status=pending",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("list change requests")
        .json::<serde_json::Value>()
        .await
        .expect("pending json");
    assert_eq!(pending["items"].as_array().expect("items").len(), 0);

    child.kill().ok();
    child.wait().ok();
}

#[tokio::test(flavor = "multi_thread")]
async fn mcp_stdio_update_uses_change_request_auto_threshold_env() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let http = reqwest::Client::new();
    let memory = http
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "project_rule",
            "scope": "repo",
            "text": "Use curl for local service health checks.",
            "scopeData": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1"
            }
        }))
        .send()
        .await
        .expect("create memory")
        .json::<serde_json::Value>()
        .await
        .expect("memory json");
    let memory_id = memory["id"].as_str().expect("memory id");

    let exe = env!("CARGO_BIN_EXE_memory-core");
    let mut child = Command::new(exe)
        .args(["--mode", "mcp-stdio", "--daemon-url", &state.base_url])
        .env("MEMORY_DAEMON_TOKEN", "test-token")
        .env("MEMORY_CHANGE_REQUEST_AUTO_APPROVE_THRESHOLD", "0.90")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn mcp");

    let mut stdin = child.stdin.take().expect("stdin");
    writeln!(
        stdin,
        "{}",
        serde_json::json!({
            "jsonrpc": "2.0",
            "id": 18,
            "method": "tools/call",
            "params": {
                "name": "memory.update",
                "arguments": {
                    "scope": {
                        "userId": "local-user",
                        "workspaceId": "workspace-1",
                        "repoId": "repo-1"
                    },
                    "targetMemoryId": memory_id,
                    "proposedKind": "project_rule",
                    "proposedScope": "repo",
                    "proposedText": "Use curl and lsof for local service health checks.",
                    "reason": "Adds the preferred port inspection tool.",
                    "confidence": 0.94
                }
            }
        })
    )
    .expect("write update");

    let stdout = child.stdout.take().expect("stdout");
    let mut reader = BufReader::new(stdout);
    let mut update_line = String::new();
    reader.read_line(&mut update_line).expect("read update");
    let update_response: serde_json::Value =
        serde_json::from_str(update_line.trim()).expect("update json rpc");
    assert_eq!(update_response["id"], 18);
    let update_text = update_response["result"]["content"][0]["text"]
        .as_str()
        .unwrap();
    assert!(update_text.contains("\"autoApplied\": 1"));
    assert!(update_text.contains("\"status\": \"approved\""));

    let active = http
        .get(format!(
            "{}/v1/memory?userId=local-user&repoId=repo-1&status=active",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("list active memory")
        .json::<serde_json::Value>()
        .await
        .expect("active json");
    assert_eq!(
        active["items"][0]["text"],
        "Use curl and lsof for local service health checks."
    );

    let pending = http
        .get(format!(
            "{}/v1/memory/change-requests?userId=local-user&repoId=repo-1&status=pending",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("list change requests")
        .json::<serde_json::Value>()
        .await
        .expect("pending json");
    assert_eq!(pending["items"].as_array().expect("items").len(), 0);

    child.kill().ok();
    child.wait().ok();
}

#[tokio::test(flavor = "multi_thread")]
async fn mcp_stdio_update_skips_when_confidence_is_below_threshold() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let http = reqwest::Client::new();
    let memory = http
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "project_rule",
            "scope": "repo",
            "text": "Use curl for local service health checks.",
            "scopeData": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1"
            }
        }))
        .send()
        .await
        .expect("create memory")
        .json::<serde_json::Value>()
        .await
        .expect("memory json");
    let memory_id = memory["id"].as_str().expect("memory id");

    let exe = env!("CARGO_BIN_EXE_memory-core");
    let mut child = Command::new(exe)
        .args(["--mode", "mcp-stdio", "--daemon-url", &state.base_url])
        .env("MEMORY_DAEMON_TOKEN", "test-token")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn mcp");

    let mut stdin = child.stdin.take().expect("stdin");
    writeln!(
        stdin,
        "{}",
        serde_json::json!({
            "jsonrpc": "2.0",
            "id": 14,
            "method": "tools/call",
            "params": {
                "name": "memory.update",
                "arguments": {
                    "scope": {
                        "userId": "local-user",
                        "workspaceId": "workspace-1",
                        "repoId": "repo-1"
                    },
                    "targetMemoryId": memory_id,
                    "proposedText": "Use curl, ss, and lsof for local service health checks.",
                    "reason": "Low confidence rewrite should not become review noise.",
                    "confidence": 0.61,
                    "autoApproveThreshold": 0.90
                }
            }
        })
    )
    .expect("write update");

    let stdout = child.stdout.take().expect("stdout");
    let mut reader = BufReader::new(stdout);
    let mut update_line = String::new();
    reader.read_line(&mut update_line).expect("read update");
    let update_response: serde_json::Value =
        serde_json::from_str(update_line.trim()).expect("update json rpc");
    assert_eq!(update_response["id"], 14);
    let update_text = update_response["result"]["content"][0]["text"]
        .as_str()
        .unwrap();
    assert!(update_text.contains("\"autoApplied\": 0"));
    assert!(update_text.contains("\"skipped\": 1"));

    let active = http
        .get(format!(
            "{}/v1/memory?userId=local-user&repoId=repo-1&status=active",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("list active memory")
        .json::<serde_json::Value>()
        .await
        .expect("active json");
    assert_eq!(
        active["items"][0]["text"],
        "Use curl for local service health checks."
    );

    let pending = http
        .get(format!(
            "{}/v1/memory/change-requests?userId=local-user&repoId=repo-1&status=pending",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("list change requests")
        .json::<serde_json::Value>()
        .await
        .expect("pending json");
    assert_eq!(pending["items"].as_array().expect("items").len(), 0);

    child.kill().ok();
    child.wait().ok();
}

#[tokio::test(flavor = "multi_thread")]
async fn mcp_stdio_forget_keeps_high_confidence_delete_pending() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let http = reqwest::Client::new();
    let memory = http
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "project_rule",
            "scope": "repo",
            "text": "Use curl for local service health checks.",
            "scopeData": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1"
            }
        }))
        .send()
        .await
        .expect("create memory")
        .json::<serde_json::Value>()
        .await
        .expect("memory json");
    let memory_id = memory["id"].as_str().expect("memory id");

    let exe = env!("CARGO_BIN_EXE_memory-core");
    let mut child = Command::new(exe)
        .args(["--mode", "mcp-stdio", "--daemon-url", &state.base_url])
        .env("MEMORY_DAEMON_TOKEN", "test-token")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn mcp");

    let mut stdin = child.stdin.take().expect("stdin");
    writeln!(
        stdin,
        "{}",
        serde_json::json!({
            "jsonrpc": "2.0",
            "id": 15,
            "method": "tools/call",
            "params": {
                "name": "memory.forget",
                "arguments": {
                    "scope": {
                        "userId": "local-user",
                        "workspaceId": "workspace-1",
                        "repoId": "repo-1"
                    },
                    "targetMemoryId": memory_id,
                    "reason": "The rule is obsolete.",
                    "confidence": 0.96,
                    "autoApproveThreshold": 0.90
                }
            }
        })
    )
    .expect("write forget");

    let stdout = child.stdout.take().expect("stdout");
    let mut reader = BufReader::new(stdout);
    let mut forget_line = String::new();
    reader.read_line(&mut forget_line).expect("read forget");
    let forget_response: serde_json::Value =
        serde_json::from_str(forget_line.trim()).expect("forget json rpc");
    assert_eq!(forget_response["id"], 15);
    let forget_text = forget_response["result"]["content"][0]["text"]
        .as_str()
        .unwrap();
    assert!(forget_text.contains("\"needsReview\": 1"));
    assert!(forget_text.contains("\"action\": \"delete\""));

    let pending = http
        .get(format!(
            "{}/v1/memory/change-requests?userId=local-user&repoId=repo-1&status=pending",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("list change requests")
        .json::<serde_json::Value>()
        .await
        .expect("pending json");
    let items = pending["items"].as_array().expect("items");
    assert_eq!(items.len(), 1);
    assert_eq!(items[0]["action"], "delete");
    assert_eq!(items[0]["source"], "mcp");

    child.kill().ok();
    child.wait().ok();
}

#[tokio::test(flavor = "multi_thread")]
async fn mcp_stdio_forget_skips_when_confidence_is_below_threshold() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let http = reqwest::Client::new();
    let memory = http
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "project_rule",
            "scope": "repo",
            "text": "Use curl for local service health checks.",
            "scopeData": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1"
            }
        }))
        .send()
        .await
        .expect("create memory")
        .json::<serde_json::Value>()
        .await
        .expect("memory json");
    let memory_id = memory["id"].as_str().expect("memory id");

    let exe = env!("CARGO_BIN_EXE_memory-core");
    let mut child = Command::new(exe)
        .args(["--mode", "mcp-stdio", "--daemon-url", &state.base_url])
        .env("MEMORY_DAEMON_TOKEN", "test-token")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn mcp");

    let mut stdin = child.stdin.take().expect("stdin");
    writeln!(
        stdin,
        "{}",
        serde_json::json!({
            "jsonrpc": "2.0",
            "id": 16,
            "method": "tools/call",
            "params": {
                "name": "memory.forget",
                "arguments": {
                    "scope": {
                        "userId": "local-user",
                        "workspaceId": "workspace-1",
                        "repoId": "repo-1"
                    },
                    "targetMemoryId": memory_id,
                    "reason": "Low confidence cleanup should not become review noise.",
                    "confidence": 0.61,
                    "autoApproveThreshold": 0.90
                }
            }
        })
    )
    .expect("write forget");

    let stdout = child.stdout.take().expect("stdout");
    let mut reader = BufReader::new(stdout);
    let mut forget_line = String::new();
    reader.read_line(&mut forget_line).expect("read forget");
    let forget_response: serde_json::Value =
        serde_json::from_str(forget_line.trim()).expect("forget json rpc");
    assert_eq!(forget_response["id"], 16);
    let forget_text = forget_response["result"]["content"][0]["text"]
        .as_str()
        .unwrap();
    assert!(forget_text.contains("\"autoApplied\": 0"));
    assert!(forget_text.contains("\"needsReview\": 0"));
    assert!(forget_text.contains("\"skipped\": 1"));

    let active = http
        .get(format!(
            "{}/v1/memory?userId=local-user&repoId=repo-1&status=active",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("list active memory")
        .json::<serde_json::Value>()
        .await
        .expect("active json");
    assert_eq!(active["items"][0]["id"], memory_id);

    let pending = http
        .get(format!(
            "{}/v1/memory/change-requests?userId=local-user&repoId=repo-1&status=pending",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("list change requests")
        .json::<serde_json::Value>()
        .await
        .expect("pending json");
    assert_eq!(pending["items"].as_array().expect("items").len(), 0);

    child.kill().ok();
    child.wait().ok();
}
