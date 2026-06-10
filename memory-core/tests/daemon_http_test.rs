use std::process::{Command, Stdio};
use std::time::{Duration, Instant};
use std::{env, io::Read};

#[test]
fn daemon_prints_ready_json_to_stdout() {
    let temp = tempfile::tempdir().expect("tempdir");
    let exe = env!("CARGO_BIN_EXE_memory-core");
    let mut child = Command::new(exe)
        .args([
            "--mode",
            "daemon",
            "--host",
            "127.0.0.1",
            "--port",
            "0",
            "--data-dir",
            temp.path().to_str().expect("utf8 path"),
        ])
        .env("MEMORY_DAEMON_TOKEN", "test-token")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn daemon");

    let started = Instant::now();
    let mut stdout = child.stdout.take().expect("stdout");
    let mut buf = Vec::new();
    while started.elapsed() < Duration::from_secs(5) {
        let mut byte = [0_u8; 1];
        if stdout.read(&mut byte).expect("read stdout") == 1 {
            buf.push(byte[0]);
            if byte[0] == b'\n' {
                break;
            }
        }
    }

    let line = String::from_utf8(buf).expect("utf8 ready");
    let ready: serde_json::Value = serde_json::from_str(line.trim()).expect("ready json");
    assert_eq!(ready["type"], "ready");
    assert!(ready["port"].as_u64().expect("port") > 0);

    child.kill().ok();
    child.wait().ok();
}

#[tokio::test]
async fn health_requires_no_auth_and_v1_requires_auth() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");

    let health = reqwest::get(format!("{}/health", state.base_url))
        .await
        .expect("health response")
        .json::<serde_json::Value>()
        .await
        .expect("health json");
    assert_eq!(health["ok"], true);

    let unauth = reqwest::Client::new()
        .get(format!("{}/v1/memory", state.base_url))
        .send()
        .await
        .expect("unauth response");
    assert_eq!(unauth.status(), reqwest::StatusCode::UNAUTHORIZED);
}
