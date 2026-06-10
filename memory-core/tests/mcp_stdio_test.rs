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
    assert!(!value["result"]["tools"]
        .as_array()
        .unwrap()
        .iter()
        .any(|tool| tool["name"] == "memory.update"));

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
