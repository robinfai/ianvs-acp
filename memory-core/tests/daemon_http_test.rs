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

#[tokio::test]
async fn schema_creates_memory_tables() {
    let temp = tempfile::tempdir().expect("tempdir");
    let pool = memory_core::db::sqlite::open(temp.path())
        .await
        .expect("db");
    let tables: Vec<String> =
        sqlx::query_scalar("select name from sqlite_master where type = 'table' order by name")
            .fetch_all(&pool)
            .await
            .expect("tables");
    assert!(tables.contains(&"memory_items".to_string()));
    assert!(tables.contains(&"memory_candidates".to_string()));
    assert!(tables.contains(&"memory_change_requests".to_string()));
    assert!(tables.contains(&"memory_audit_log".to_string()));
    assert!(tables.contains(&"prompt_injections".to_string()));
}

#[test]
fn memory_kind_uses_snake_case_wire_names() {
    use memory_core::memory::types::MemoryKind;

    assert_eq!(
        serde_json::to_string(&MemoryKind::UserPreference).unwrap(),
        "\"user_preference\""
    );
    assert_eq!(
        serde_json::to_string(&MemoryKind::ProjectRule).unwrap(),
        "\"project_rule\""
    );
    assert_eq!(
        serde_json::to_string(&MemoryKind::ArchitectureDecision).unwrap(),
        "\"architecture_decision\""
    );
    assert_eq!(
        serde_json::to_string(&MemoryKind::SessionSummary).unwrap(),
        "\"session_summary\""
    );
}

#[tokio::test]
async fn manual_memory_crud_writes_audit_and_soft_deletes() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    let created = client
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "project_rule",
            "scope": "repo",
            "text": "Do not use nc/netcat in this repo.",
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
        .expect("create")
        .json::<serde_json::Value>()
        .await
        .expect("create json");

    let id = created["id"].as_str().expect("id");
    assert_eq!(created["kind"], "project_rule");
    assert_eq!(created["status"], "active");

    let listed = client
        .get(format!(
            "{}/v1/memory?userId=local-user&repoId=repo-1",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("list")
        .json::<serde_json::Value>()
        .await
        .expect("list json");
    assert_eq!(listed["items"].as_array().unwrap().len(), 1);

    let patched = client
        .patch(format!("{}/v1/memory/{id}", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({ "text": "Never use nc/netcat in this repo." }))
        .send()
        .await
        .expect("patch")
        .json::<serde_json::Value>()
        .await
        .expect("patch json");
    assert_eq!(patched["text"], "Never use nc/netcat in this repo.");

    let deleted = client
        .delete(format!("{}/v1/memory/{id}", state.base_url))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("delete");
    assert_eq!(deleted.status(), reqwest::StatusCode::OK);

    let listed_after_delete = client
        .get(format!(
            "{}/v1/memory?userId=local-user&repoId=repo-1&status=active",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("list after delete")
        .json::<serde_json::Value>()
        .await
        .expect("list json");
    assert_eq!(listed_after_delete["items"].as_array().unwrap().len(), 0);

    let audit_pool = memory_core::db::sqlite::open(temp.path())
        .await
        .expect("audit db");
    let audit_count: i64 = sqlx::query_scalar(
        "select count(*) from memory_audit_log
         where memory_id = ? and action in ('memory.create', 'memory.update', 'memory.delete')",
    )
    .bind(id)
    .fetch_one(&audit_pool)
    .await
    .expect("audit count");
    assert_eq!(audit_count, 3);

    let stored_status: String = sqlx::query_scalar("select status from memory_items where id = ?")
        .bind(id)
        .fetch_one(&audit_pool)
        .await
        .expect("stored status");
    assert_eq!(stored_status, "deleted");
}

#[test]
fn redactor_masks_known_secret_patterns() {
    let text = "api_key=sk-test password=hunter2 ghp_abcdef";
    let redacted = memory_core::memory::redactor::redact(text);
    assert!(!redacted.contains("sk-test"));
    assert!(!redacted.contains("hunter2"));
    assert!(!redacted.contains("ghp_abcdef"));
    assert!(redacted.contains("[REDACTED]"));
}

#[tokio::test]
async fn manual_memory_redacts_secret_text_before_storage() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    let created = client
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "architecture_decision",
            "scope": "repo",
            "text": "Store this api_key=sk-test password=hunter2 nowhere.",
            "scopeData": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1"
            }
        }))
        .send()
        .await
        .expect("create")
        .json::<serde_json::Value>()
        .await
        .expect("create json");

    let stored = created["text"].as_str().expect("text");
    assert!(!stored.contains("sk-test"));
    assert!(!stored.contains("hunter2"));
    assert!(stored.contains("[REDACTED]"));

    let id = created["id"].as_str().expect("id");
    let patched = client
        .patch(format!("{}/v1/memory/{id}", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "text": "Patch should hide ghp_abcdef and secret=token."
        }))
        .send()
        .await
        .expect("patch")
        .json::<serde_json::Value>()
        .await
        .expect("patch json");
    let patched_text = patched["text"].as_str().expect("patched text");
    assert!(!patched_text.contains("ghp_abcdef"));
    assert!(!patched_text.contains("token"));
    assert!(patched_text.contains("[REDACTED]"));
}

#[tokio::test]
async fn candidate_approve_writes_memory_and_reject_does_not() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    let candidates = client
        .post(format!("{}/v1/memory/extract-candidates", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1",
                "agentId": "agent-1",
                "sessionId": "session-1"
            },
            "preExtractedCandidates": [
                {
                    "kind": "project_rule",
                    "scope": "repo",
                    "text": "Do not use nc/netcat in this repo.",
                    "confidence": 0.95,
                    "reason": "User explicitly gave a repo rule."
                },
                {
                    "kind": "session_summary",
                    "scope": "session",
                    "text": "x",
                    "confidence": 0.20,
                    "reason": "Too weak."
                }
            ]
        }))
        .send()
        .await
        .expect("extract")
        .json::<serde_json::Value>()
        .await
        .expect("extract json");
    assert_eq!(candidates["candidates"].as_array().unwrap().len(), 1);
    let candidate_id = candidates["candidates"][0]["id"].as_str().unwrap();

    let approved = client
        .post(format!(
            "{}/v1/memory/candidates/{candidate_id}/approve",
            state.base_url
        ))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "project_rule",
            "scope": "repo",
            "text": "Never use nc/netcat in this repo."
        }))
        .send()
        .await
        .expect("approve")
        .json::<serde_json::Value>()
        .await
        .expect("approve json");
    assert_eq!(approved["text"], "Never use nc/netcat in this repo.");

    let audit_pool = memory_core::db::sqlite::open(temp.path())
        .await
        .expect("audit db");
    let rejected_count: i64 = sqlx::query_scalar("select count(*) from memory_items")
        .fetch_one(&audit_pool)
        .await
        .expect("memory count");
    assert_eq!(rejected_count, 1);
}

#[tokio::test]
async fn search_returns_active_memory_and_skips_deleted() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    let active = client
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "architecture_decision",
            "scope": "repo",
            "text": "Flutter owns ACP runtime; Rust only owns memory.",
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
        .unwrap()
        .json::<serde_json::Value>()
        .await
        .unwrap();
    client
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "user_preference",
            "scope": "global",
            "text": "Prefer compact spacing in dense desktop UI.",
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
        .unwrap();
    let deleted = client
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "project_rule",
            "scope": "repo",
            "text": "Deleted rule should not appear.",
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
        .unwrap()
        .json::<serde_json::Value>()
        .await
        .unwrap();
    client
        .delete(format!(
            "{}/v1/memory/{}",
            state.base_url,
            deleted["id"].as_str().unwrap()
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .unwrap();

    let search = client
        .post(format!("{}/v1/memory/search", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "query": "Who owns ACP runtime?",
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1",
                "agentId": "agent-1",
                "sessionId": "session-1"
            },
            "limit": 10
        }))
        .send()
        .await
        .unwrap()
        .json::<serde_json::Value>()
        .await
        .unwrap();
    assert_eq!(search["items"].as_array().unwrap().len(), 1);
    assert_eq!(search["items"][0]["id"], active["id"]);
}

#[test]
fn formatter_uses_background_context_wording() {
    let formatted = memory_core::memory::formatter::format_context(&[
        ("project_rule", "Do not use nc/netcat."),
        ("architecture_decision", "Rust only owns memory."),
    ]);
    assert!(formatted.contains("<agent_memory_context>"));
    assert!(formatted.contains("current instruction wins"));
    assert!(formatted.contains("[project_rule] Do not use nc/netcat."));
}

#[test]
fn embedding_config_defaults_to_multilingual_e5_small() {
    let config = memory_core::config::EmbeddingConfig::default();
    assert_eq!(config.provider, "fastembed-local");
    assert_eq!(config.model, "intfloat/multilingual-e5-small");
    assert_eq!(config.variant, "onnx-qint8");
    assert_eq!(config.dimension, 384);
    assert_eq!(config.download_policy, "lazy");
}

#[tokio::test]
async fn sqlite_vec_is_registered_and_rebuild_vector_index_endpoint_exists() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let pool = memory_core::db::sqlite::open(temp.path())
        .await
        .expect("db");
    let vec_version: String = sqlx::query_scalar("select vec_version()")
        .fetch_one(&pool)
        .await
        .expect("sqlite vec version");
    assert!(vec_version.starts_with('v'));

    let response = reqwest::Client::new()
        .post(format!("{}/v1/memory/rebuild-vector-index", state.base_url))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("rebuild");
    assert_eq!(response.status(), reqwest::StatusCode::OK);
}
