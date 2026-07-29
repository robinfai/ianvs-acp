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

    child.kill().ok();
    child.wait().ok();
}

#[tokio::test(flavor = "multi_thread")]
async fn mcp_stdio_update_and_forget_create_pending_change_requests() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let http = reqwest::Client::new();
    let created = http
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "user_preference",
            "scope": "global",
            "text": "The user goes by Rod.",
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
        .expect("create memory json");
    let memory_id = created["id"].as_str().expect("memory id");

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
                    "proposedKind": "user_preference",
                    "proposedScope": "global",
                    "proposedText": "The user goes by Rodriguez.",
                    "reason": "Clarify preferred name."
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
                    "reason": "User requested forgetting."
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
        serde_json::from_str(update_line.trim()).expect("update json");
    assert_eq!(update_response["id"], 11);
    assert!(update_response["result"]["content"][0]["text"]
        .as_str()
        .unwrap()
        .contains("\"action\": \"update\""));

    let mut forget_line = String::new();
    reader.read_line(&mut forget_line).expect("read forget");
    let forget_response: serde_json::Value =
        serde_json::from_str(forget_line.trim()).expect("forget json");
    assert_eq!(forget_response["id"], 12);
    assert!(forget_response["result"]["content"][0]["text"]
        .as_str()
        .unwrap()
        .contains("\"action\": \"delete\""));

    let requests = http
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
        .expect("list change requests json");
    let actions = requests["items"]
        .as_array()
        .expect("items")
        .iter()
        .map(|item| item["action"].as_str().unwrap())
        .collect::<Vec<_>>();
    assert!(actions.contains(&"update"));
    assert!(actions.contains(&"delete"));

    let active = http
        .get(format!(
            "{}/v1/memory?userId=local-user&repoId=repo-1&status=active",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("list memory")
        .json::<serde_json::Value>()
        .await
        .expect("list memory json");
    assert_eq!(active["items"].as_array().expect("active items").len(), 1);

    child.kill().ok();
    child.wait().ok();
}

#[tokio::test(flavor = "multi_thread")]
async fn mcp_stdio_update_auto_approves_high_confidence_non_destructive_requests() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let http = reqwest::Client::new();
    let created = http
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "user_preference",
            "scope": "global",
            "text": "The user goes by Rod.",
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
        .expect("create memory json");
    let memory_id = created["id"].as_str().expect("memory id");

    let exe = env!("CARGO_BIN_EXE_memory-core");
    let mut child = Command::new(exe)
        .args(["--mode", "mcp-stdio", "--daemon-url", &state.base_url])
        .env("MEMORY_DAEMON_TOKEN", "test-token")
        .env("MEMORY_REVIEW_APPROVAL_MODE", " Auto-High-Confidence ")
        .env("MEMORY_REVIEW_HIGH_CONFIDENCE_THRESHOLD", "0.85")
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
            "id": 31,
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
                    "proposedKind": "user_preference",
                    "proposedScope": "global",
                    "proposedText": "The user goes by Rodriguez.",
                    "reason": "User clarified preferred name.",
                    "confidence": 0.96
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
            "id": 32,
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
                    "reason": "User requested forgetting.",
                    "confidence": 0.99
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
        serde_json::from_str(update_line.trim()).expect("update json");
    assert_eq!(update_response["id"], 31);
    let update_text = update_response["result"]["content"][0]["text"]
        .as_str()
        .expect("update text");
    assert!(update_text.contains("\"approvedChangeRequest\""));
    assert!(update_text.contains("\"status\": \"approved\""));
    assert!(update_text.contains("\"maintenanceResult\""));

    let mut forget_line = String::new();
    reader.read_line(&mut forget_line).expect("read forget");
    let forget_response: serde_json::Value =
        serde_json::from_str(forget_line.trim()).expect("forget json");
    assert_eq!(forget_response["id"], 32);
    let forget_text = forget_response["result"]["content"][0]["text"]
        .as_str()
        .expect("forget text");
    assert!(forget_text.contains("\"action\": \"delete\""));
    assert!(forget_text.contains("\"status\": \"pending\""));

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
        .expect("active memory json");
    let active_items = active["items"].as_array().expect("active items");
    assert_eq!(active_items.len(), 1);
    assert_eq!(active_items[0]["text"], "The user goes by Rodriguez.");
    assert_eq!(active_items[0]["source"], "mcp");

    let pending = http
        .get(format!(
            "{}/v1/memory/change-requests?userId=local-user&repoId=repo-1&status=pending",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("list pending change requests")
        .json::<serde_json::Value>()
        .await
        .expect("pending change requests json");
    let pending_items = pending["items"].as_array().expect("pending items");
    assert_eq!(pending_items.len(), 1);
    assert_eq!(pending_items[0]["action"], "delete");

    let audit = http
        .get(format!(
            "{}/v1/memory/audit?userId=local-user&repoId=repo-1",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("list audit")
        .json::<serde_json::Value>()
        .await
        .expect("audit json");
    let approve_actor = audit["items"]
        .as_array()
        .expect("audit items")
        .iter()
        .find(|item| item["action"] == "change_request.approve")
        .and_then(|item| item["actor"].as_str())
        .expect("change request approve actor");
    assert_eq!(approve_actor, "mcp");
    let update_actor = audit["items"]
        .as_array()
        .expect("audit items")
        .iter()
        .find(|item| item["action"] == "memory.update")
        .and_then(|item| item["actor"].as_str())
        .expect("memory update actor");
    assert_eq!(update_actor, "mcp");

    child.kill().ok();
    child.wait().ok();
}

#[tokio::test(flavor = "multi_thread")]
async fn mcp_stdio_remember_auto_approves_high_confidence_candidates() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let http = reqwest::Client::new();

    let exe = env!("CARGO_BIN_EXE_memory-core");
    let mut child = Command::new(exe)
        .args(["--mode", "mcp-stdio", "--daemon-url", &state.base_url])
        .env("MEMORY_DAEMON_TOKEN", "test-token")
        .env("MEMORY_REVIEW_APPROVAL_MODE", " Auto-High-Confidence ")
        .env("MEMORY_REVIEW_HIGH_CONFIDENCE_THRESHOLD", "0.85")
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
            "id": 21,
            "method": "tools/call",
            "params": {
                "name": "memory.remember",
                "arguments": {
                    "scope": {
                        "userId": "local-user",
                        "workspaceId": "workspace-1",
                        "repoId": "repo-1",
                        "agentId": "agent-1",
                        "sessionId": "session-1"
                    },
                    "preExtractedCandidates": [
                        {
                            "kind": "user_preference",
                            "scope": "global",
                            "text": "The user goes by Rodriguez.",
                            "confidence": 0.96,
                            "reason": "User explicitly asked the agent to remember this."
                        },
                        {
                            "kind": "project_rule",
                            "scope": "repo",
                            "text": "The project passphrase may be blue lighthouse.",
                            "confidence": 0.72,
                            "reason": "Uncertain wording."
                        }
                    ]
                }
            }
        })
    )
    .expect("write remember");

    let stdout = child.stdout.take().expect("stdout");
    let mut reader = BufReader::new(stdout);
    let mut remember_line = String::new();
    reader.read_line(&mut remember_line).expect("read remember");
    let remember_response: serde_json::Value =
        serde_json::from_str(remember_line.trim()).expect("remember json");
    assert_eq!(remember_response["id"], 21);
    let remember_text = remember_response["result"]["content"][0]["text"]
        .as_str()
        .expect("remember text");
    assert!(remember_text.contains("\"approvedMemories\""));
    assert!(remember_text.contains("The user goes by Rodriguez."));
    assert!(remember_text.contains("\"maintenanceResult\""));

    let active = http
        .get(format!(
            "{}/v1/memory?userId=local-user&repoId=repo-1&status=active",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("list memory")
        .json::<serde_json::Value>()
        .await
        .expect("list memory json");
    let active_items = active["items"].as_array().expect("active items");
    assert_eq!(active_items.len(), 1);
    assert_eq!(active_items[0]["text"], "The user goes by Rodriguez.");

    let pending = http
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
        .expect("list candidates json");
    let pending_candidates = pending["candidates"]
        .as_array()
        .expect("pending candidates");
    assert_eq!(pending_candidates.len(), 1);
    assert_eq!(
        pending_candidates[0]["text"],
        "The project passphrase may be blue lighthouse."
    );
    assert_eq!(pending_candidates[0]["source"], "mcp");

    let audit = http
        .get(format!(
            "{}/v1/memory/audit?userId=local-user&repoId=repo-1",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("list audit")
        .json::<serde_json::Value>()
        .await
        .expect("audit json");
    let approve_actor = audit["items"]
        .as_array()
        .expect("audit items")
        .iter()
        .find(|item| item["action"] == "candidate.approve")
        .and_then(|item| item["actor"].as_str())
        .expect("candidate approve actor");
    assert_eq!(approve_actor, "mcp");
    assert!(audit["items"]
        .as_array()
        .expect("audit items")
        .iter()
        .any(|item| item["action"] == "maintenance.run"));

    child.kill().ok();
    child.wait().ok();
}

#[tokio::test(flavor = "multi_thread")]
async fn mcp_stdio_remember_defaults_to_auto_high_confidence_policy() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let http = reqwest::Client::new();

    let exe = env!("CARGO_BIN_EXE_memory-core");
    let mut child = Command::new(exe)
        .args(["--mode", "mcp-stdio", "--daemon-url", &state.base_url])
        .env("MEMORY_DAEMON_TOKEN", "test-token")
        .env_remove("MEMORY_REVIEW_APPROVAL_MODE")
        .env_remove("MEMORY_REVIEW_HIGH_CONFIDENCE_THRESHOLD")
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
            "id": 31,
            "method": "tools/call",
            "params": {
                "name": "memory.remember",
                "arguments": {
                    "scope": {
                        "userId": "local-user",
                        "workspaceId": "workspace-1",
                        "repoId": "repo-1",
                        "agentId": "agent-1",
                        "sessionId": "session-1"
                    },
                    "preExtractedCandidates": [
                        {
                            "kind": "user_preference",
                            "scope": "global",
                            "text": "The user goes by Rodriguez.",
                            "confidence": 0.96,
                            "reason": "User explicitly asked the agent to remember this."
                        }
                    ]
                }
            }
        })
    )
    .expect("write remember");

    let stdout = child.stdout.take().expect("stdout");
    let mut reader = BufReader::new(stdout);
    let mut remember_line = String::new();
    reader.read_line(&mut remember_line).expect("read remember");
    let remember_response: serde_json::Value =
        serde_json::from_str(remember_line.trim()).expect("remember json");
    assert_eq!(remember_response["id"], 31);
    let remember_text = remember_response["result"]["content"][0]["text"]
        .as_str()
        .expect("remember text");
    assert!(remember_text.contains("\"approvedMemories\""));

    let active = http
        .get(format!(
            "{}/v1/memory?userId=local-user&repoId=repo-1&status=active",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("list memory")
        .json::<serde_json::Value>()
        .await
        .expect("list memory json");
    let active_items = active["items"].as_array().expect("active items");
    assert_eq!(active_items.len(), 1);
    assert_eq!(active_items[0]["text"], "The user goes by Rodriguez.");
    assert_eq!(active_items[0]["source"], "mcp");

    child.kill().ok();
    child.wait().ok();
}

#[tokio::test(flavor = "multi_thread")]
async fn mcp_stdio_remember_auto_approves_review_band_stable_memory() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let http = reqwest::Client::new();

    let exe = env!("CARGO_BIN_EXE_memory-core");
    let mut child = Command::new(exe)
        .args(["--mode", "mcp-stdio", "--daemon-url", &state.base_url])
        .env("MEMORY_DAEMON_TOKEN", "test-token")
        .env("MEMORY_REVIEW_APPROVAL_MODE", "auto_high_confidence")
        .env("MEMORY_REVIEW_HIGH_CONFIDENCE_THRESHOLD", "0.90")
        .env("MEMORY_MAINTENANCE_REVIEW_THRESHOLD", "0.75")
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
            "id": 41,
            "method": "tools/call",
            "params": {
                "name": "memory.remember",
                "arguments": {
                    "scope": {
                        "userId": "local-user",
                        "workspaceId": "workspace-1",
                        "repoId": "repo-1",
                        "agentId": "agent-1",
                        "sessionId": "session-1"
                    },
                    "preExtractedCandidates": [
                        {
                            "kind": "session_summary",
                            "scope": "session",
                            "text": "本轮确认 MCP 记忆会话摘要自动批准策略。",
                            "confidence": 0.78,
                            "reason": "Useful current-session summary."
                        },
                        {
                            "kind": "project_rule",
                            "scope": "repo",
                            "text": "项目规则是每次都打开详细日志。",
                            "confidence": 0.78,
                            "reason": "Review-band stable repo rule."
                        }
                    ]
                }
            }
        })
    )
    .expect("write remember");

    let stdout = child.stdout.take().expect("stdout");
    let mut reader = BufReader::new(stdout);
    let mut remember_line = String::new();
    reader.read_line(&mut remember_line).expect("read remember");
    let remember_response: serde_json::Value =
        serde_json::from_str(remember_line.trim()).expect("remember json");
    assert_eq!(remember_response["id"], 41);
    let remember_text = remember_response["result"]["content"][0]["text"]
        .as_str()
        .expect("remember text");
    assert!(remember_text.contains("\"approvedMemories\""));
    assert!(remember_text.contains("本轮确认 MCP 记忆会话摘要自动批准策略。"));
    assert!(remember_text.contains("项目规则是每次都打开详细日志。"));

    let active = http
        .get(format!(
            "{}/v1/memory?userId=local-user&repoId=repo-1&status=active",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("list memory")
        .json::<serde_json::Value>()
        .await
        .expect("list memory json");
    let active_items = active["items"].as_array().expect("active items");
    assert_eq!(active_items.len(), 2);
    assert!(active_items
        .iter()
        .any(|item| item["kind"] == "session_summary"));
    let repo_rule = active_items
        .iter()
        .find(|item| item["kind"] == "project_rule")
        .expect("review-band repo rule active");
    assert_eq!(repo_rule["text"], "项目规则是每次都打开详细日志。");
    assert_eq!(repo_rule["pinned"], true);

    let pending = http
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
        .expect("list candidates json");
    let pending_candidates = pending["candidates"]
        .as_array()
        .expect("pending candidates");
    assert_eq!(pending_candidates.len(), 0);

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
async fn mcp_stdio_list_forwards_full_scope_filters() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let http = reqwest::Client::new();

    for (text, session_id) in [
        ("Current session summary.", "session-1"),
        ("Other session summary.", "session-2"),
    ] {
        http.post(format!("{}/v1/memory", state.base_url))
            .bearer_auth("test-token")
            .json(&serde_json::json!({
                "kind": "session_summary",
                "scope": "session",
                "text": text,
                "scopeData": {
                    "userId": "local-user",
                    "workspaceId": "workspace-1",
                    "repoId": "repo-1",
                    "agentId": "agent-1",
                    "sessionId": session_id
                }
            }))
            .send()
            .await
            .expect("create session memory");
    }
    http.post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "project_rule",
            "scope": "repo",
            "text": "Repo rule should be filtered out by kind.",
            "scopeData": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1",
                "agentId": "agent-1",
                "sessionId": "session-1"
            }
        }))
        .send()
        .await
        .expect("create repo memory");

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
            "id": 8,
            "method": "tools/call",
            "params": {
                "name": "memory.list",
                "arguments": {
                    "userId": "local-user",
                    "workspaceId": "workspace-1",
                    "repoId": "repo-1",
                    "agentId": "agent-1",
                    "sessionId": "session-1",
                    "kind": "session_summary",
                    "status": "active",
                    "limit": 10
                }
            }
        })
    )
    .expect("write list");

    let stdout = child.stdout.take().expect("stdout");
    let mut reader = BufReader::new(stdout);
    let mut list_line = String::new();
    reader.read_line(&mut list_line).expect("read list");
    let list_response: serde_json::Value =
        serde_json::from_str(list_line.trim()).expect("list json");
    assert_eq!(list_response["id"], 8);
    let list_text = list_response["result"]["content"][0]["text"]
        .as_str()
        .expect("list text");
    assert!(list_text.contains("Current session summary."));
    assert!(!list_text.contains("Other session summary."));
    assert!(!list_text.contains("Repo rule should be filtered out by kind."));

    child.kill().ok();
    child.wait().ok();
}
