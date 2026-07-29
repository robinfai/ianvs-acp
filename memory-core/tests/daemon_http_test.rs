use std::process::{Command, Stdio};
use std::time::{Duration, Instant};
use std::{env, io::Read};

use memory_core::embedding::embedder::Embedder;

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
        .env("MEMORY_EMBEDDING_PROVIDER", "mock")
        .env("MEMORY_EMBEDDING_DIMENSION", "8")
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

#[tokio::test]
async fn search_does_not_return_other_session_memory() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    client
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "session_summary",
            "scope": "session",
            "text": "Investigated the release blocker in session alpha.",
            "scopeData": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1",
                "agentId": "agent-1",
                "sessionId": "session-alpha"
            }
        }))
        .send()
        .await
        .expect("create session memory");

    let search = client
        .post(format!("{}/v1/memory/search", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "query": "release blocker",
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1",
                "agentId": "agent-1",
                "sessionId": "session-beta"
            },
            "limit": 10
        }))
        .send()
        .await
        .expect("search")
        .json::<serde_json::Value>()
        .await
        .expect("search json");

    assert!(search["items"].as_array().unwrap().is_empty());
}

#[tokio::test]
async fn search_does_not_return_same_session_id_from_other_agent() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    client
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "session_summary",
            "scope": "session",
            "text": "Debugged the vector replay timeout in shared session id.",
            "scopeData": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1",
                "agentId": "agent-alpha",
                "sessionId": "session-shared"
            }
        }))
        .send()
        .await
        .expect("create session memory");

    let search = client
        .post(format!("{}/v1/memory/search", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "query": "vector replay timeout",
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1",
                "agentId": "agent-beta",
                "sessionId": "session-shared"
            },
            "limit": 10
        }))
        .send()
        .await
        .expect("search")
        .json::<serde_json::Value>()
        .await
        .expect("search json");

    assert!(search["items"].as_array().unwrap().is_empty());
}

#[tokio::test]
async fn search_finds_old_relevant_memory_beyond_recent_window() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    let relevant = client
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "project_rule",
            "scope": "repo",
            "text": "Use the basalt release checklist for cutover.",
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
        .expect("create relevant")
        .json::<serde_json::Value>()
        .await
        .expect("relevant json");

    for index in 0..201 {
        client
            .post(format!("{}/v1/memory", state.base_url))
            .bearer_auth("test-token")
            .json(&serde_json::json!({
                "kind": "user_preference",
                "scope": "repo",
                "text": format!("Irrelevant dense UI preference {index}."),
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
            .expect("create irrelevant");
    }

    let audit_pool = memory_core::db::sqlite::open(temp.path())
        .await
        .expect("audit db");
    sqlx::query("update memory_items set updated_at = 1 where id = ?")
        .bind(relevant["id"].as_str().unwrap())
        .execute(&audit_pool)
        .await
        .expect("age relevant");
    sqlx::query("update memory_items set updated_at = 2 where id != ?")
        .bind(relevant["id"].as_str().unwrap())
        .execute(&audit_pool)
        .await
        .expect("freshen irrelevant");

    let search = client
        .post(format!("{}/v1/memory/search", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "query": "basalt checklist",
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
        .expect("search")
        .json::<serde_json::Value>()
        .await
        .expect("search json");

    assert_eq!(search["items"].as_array().unwrap().len(), 1);
    assert_eq!(search["items"][0]["id"], relevant["id"]);
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
    let client = reqwest::Client::new();
    let memory = client
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "project_rule",
            "scope": "repo",
            "text": "Use semantic vector search for durable memory recall.",
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
        .expect("create memory")
        .json::<serde_json::Value>()
        .await
        .expect("memory json");

    let pool = memory_core::db::sqlite::open(temp.path())
        .await
        .expect("db");
    let vec_version: String = sqlx::query_scalar("select vec_version()")
        .fetch_one(&pool)
        .await
        .expect("sqlite vec version");
    assert!(vec_version.starts_with('v'));

    let response = client
        .post(format!("{}/v1/memory/rebuild-vector-index", state.base_url))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("rebuild");
    assert_eq!(response.status(), reqwest::StatusCode::OK);

    let indexed_memory_id: String =
        sqlx::query_scalar("select memory_id from vec_memory_items limit 1")
            .fetch_one(&pool)
            .await
            .expect("indexed memory id");
    assert_eq!(indexed_memory_id, memory["id"].as_str().unwrap());
}

#[tokio::test]
async fn search_uses_vector_index_when_lexical_query_does_not_match() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();
    let memory = client
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "architecture_decision",
            "scope": "repo",
            "text": "Basalt release gates live in the platform handbook.",
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
        .expect("create memory")
        .json::<serde_json::Value>()
        .await
        .expect("memory json");

    let pool = memory_core::db::sqlite::open(temp.path())
        .await
        .expect("db");
    memory_core::vector::sqlite_vec_store::ensure_vec_table(&pool, 8)
        .await
        .expect("vec table");
    let query = "needleabsent";
    let vector = memory_core::embedding::mock_embedder::MockEmbedder
        .embed(query)
        .await
        .expect("query embedding");
    sqlx::query(
        "insert into vec_memory_items
         (embedding, memory_id, user_id, workspace_id, repo_id, agent_id, session_id, kind, scope, status, text)
         values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
    )
    .bind(serde_json::to_string(&vector).expect("vector json"))
    .bind(memory["id"].as_str().unwrap())
    .bind("local-user")
    .bind("workspace-1")
    .bind("repo-1")
    .bind("agent-1")
    .bind("session-1")
    .bind("architecture_decision")
    .bind("repo")
    .bind("active")
    .bind(memory["text"].as_str().unwrap())
    .execute(&pool)
    .await
    .expect("insert vector");

    let search = client
        .post(format!("{}/v1/memory/search", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "query": query,
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
        .expect("search")
        .json::<serde_json::Value>()
        .await
        .expect("search json");

    assert_eq!(search["items"].as_array().unwrap().len(), 1);
    assert_eq!(search["items"][0]["id"], memory["id"]);
}
#[tokio::test]
async fn memory_eval_fixture_guards_retrieval_invariants() {
    #[derive(serde::Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct EvalFixture {
        cases: Vec<EvalCase>,
    }
    #[derive(serde::Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct EvalCase {
        name: String,
        setup: Vec<EvalMemory>,
        query: String,
        scope: EvalScope,
        #[serde(default)]
        reference_time: Option<i64>,
        #[serde(default)]
        maintenance: Option<EvalMaintenance>,
        #[serde(default)]
        expected_first_label: Option<String>,
        expected_labels: Vec<String>,
        forbidden_labels: Vec<String>,
        #[serde(default)]
        expected_text_contains: Vec<String>,
    }
    #[derive(serde::Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct EvalMaintenance {
        auto_applied: i64,
        needs_review: i64,
        active_count: usize,
    }
    #[derive(serde::Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct EvalMemory {
        label: String,
        kind: String,
        scope: String,
        text: String,
        workspace_id: String,
        repo_id: String,
        agent_id: String,
        session_id: String,
        #[serde(default)]
        entities: Vec<EvalEntity>,
        #[serde(default)]
        observed_at: Option<i64>,
        #[serde(default)]
        valid_from: Option<i64>,
        #[serde(default)]
        valid_until: Option<i64>,
        #[serde(default)]
        pinned: bool,
    }
    #[derive(serde::Deserialize, serde::Serialize)]
    #[serde(rename_all = "camelCase")]
    struct EvalEntity {
        text: String,
        #[serde(rename = "type")]
        entity_type: Option<String>,
    }
    #[derive(serde::Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct EvalScope {
        workspace_id: String,
        repo_id: String,
        agent_id: String,
        session_id: String,
    }

    let fixture: EvalFixture =
        serde_json::from_str(include_str!("fixtures/memory_eval_cases.json"))
            .expect("eval fixture");
    assert!(!fixture.cases.is_empty());

    for case in fixture.cases {
        let temp = tempfile::tempdir().expect("tempdir");
        let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
            .await
            .expect("daemon");
        let client = reqwest::Client::new();
        let mut label_to_id = std::collections::HashMap::new();

        for memory in case.setup {
            let mut payload = serde_json::json!({
                "kind": memory.kind,
                "scope": memory.scope,
                "text": memory.text,
                "pinned": memory.pinned,
                "scopeData": {
                    "userId": "local-user",
                    "workspaceId": memory.workspace_id,
                    "repoId": memory.repo_id,
                    "agentId": memory.agent_id,
                    "sessionId": memory.session_id
                }
            });
            if !memory.entities.is_empty() {
                payload["entities"] = serde_json::json!(memory.entities);
            }
            if let Some(observed_at) = memory.observed_at {
                payload["observedAt"] = serde_json::json!(observed_at);
            }
            if let Some(valid_from) = memory.valid_from {
                payload["validFrom"] = serde_json::json!(valid_from);
            }
            if let Some(valid_until) = memory.valid_until {
                payload["validUntil"] = serde_json::json!(valid_until);
            }
            let created = client
                .post(format!("{}/v1/memory", state.base_url))
                .bearer_auth("test-token")
                .json(&payload)
                .send()
                .await
                .unwrap_or_else(|error| panic!("{} create memory: {error}", case.name))
                .json::<serde_json::Value>()
                .await
                .unwrap_or_else(|error| panic!("{} memory json: {error}", case.name));
            label_to_id.insert(
                memory.label,
                created["id"].as_str().expect("id").to_string(),
            );
        }

        if let Some(maintenance) = &case.maintenance {
            let maintenance_result = client
                .post(format!("{}/v1/memory/maintenance/run", state.base_url))
                .bearer_auth("test-token")
                .json(&serde_json::json!({
                    "enabled": true,
                    "mode": "high_confidence_auto",
                    "scope": {
                        "userId": "local-user",
                        "workspaceId": case.scope.workspace_id,
                        "repoId": case.scope.repo_id,
                        "agentId": case.scope.agent_id,
                        "sessionId": case.scope.session_id
                    },
                    "highConfidenceThreshold": 0.90,
                    "reviewThreshold": 0.75,
                    "maxItemsPerBatch": 12
                }))
                .send()
                .await
                .unwrap_or_else(|error| panic!("{} maintenance: {error}", case.name))
                .json::<serde_json::Value>()
                .await
                .unwrap_or_else(|error| panic!("{} maintenance json: {error}", case.name));
            assert_eq!(
                maintenance_result["autoApplied"], maintenance.auto_applied,
                "{} maintenance autoApplied",
                case.name
            );
            assert_eq!(
                maintenance_result["needsReview"], maintenance.needs_review,
                "{} maintenance needsReview",
                case.name
            );

            let active_memory = client
                .get(format!(
                    "{}/v1/memory?userId=local-user&workspaceId={}&repoId={}&status=active",
                    state.base_url, case.scope.workspace_id, case.scope.repo_id
                ))
                .bearer_auth("test-token")
                .send()
                .await
                .unwrap_or_else(|error| panic!("{} list active memory: {error}", case.name))
                .json::<serde_json::Value>()
                .await
                .unwrap_or_else(|error| panic!("{} active memory json: {error}", case.name));
            assert_eq!(
                active_memory["items"]
                    .as_array()
                    .expect("active memory")
                    .len(),
                maintenance.active_count,
                "{} active memory count after maintenance",
                case.name
            );
        }

        let mut search_payload = serde_json::json!({
            "query": case.query,
            "scope": {
                "userId": "local-user",
                "workspaceId": case.scope.workspace_id,
                "repoId": case.scope.repo_id,
                "agentId": case.scope.agent_id,
                "sessionId": case.scope.session_id
            },
            "limit": 10
        });
        if let Some(reference_time) = case.reference_time {
            search_payload["referenceTime"] = serde_json::json!(reference_time);
        }
        let search = client
            .post(format!("{}/v1/memory/search", state.base_url))
            .bearer_auth("test-token")
            .json(&search_payload)
            .send()
            .await
            .unwrap_or_else(|error| panic!("{} search: {error}", case.name))
            .json::<serde_json::Value>()
            .await
            .unwrap_or_else(|error| panic!("{} search json: {error}", case.name));
        let items = search["items"].as_array().expect("items");
        let returned_ids = items
            .iter()
            .map(|item| item["id"].as_str().expect("id"))
            .collect::<std::collections::HashSet<_>>();

        if let Some(expected_first_label) = case.expected_first_label {
            let expected_id = label_to_id.get(&expected_first_label).unwrap_or_else(|| {
                panic!(
                    "{} missing expected first label {expected_first_label}",
                    case.name
                )
            });
            let first_id = items
                .first()
                .unwrap_or_else(|| panic!("{} should return at least one item", case.name))["id"]
                .as_str()
                .expect("first id");
            assert_eq!(
                first_id,
                expected_id.as_str(),
                "{} should rank {expected_first_label} first",
                case.name
            );
        }

        for expected in case.expected_labels {
            let expected_id = label_to_id
                .get(&expected)
                .unwrap_or_else(|| panic!("{} missing expected label {expected}", case.name));
            assert!(
                returned_ids.contains(expected_id.as_str()),
                "{} should return {expected}",
                case.name
            );
        }
        for needle in case.expected_text_contains {
            assert!(
                items.iter().any(|item| item["text"]
                    .as_str()
                    .is_some_and(|text| text.contains(&needle))),
                "{} should return text containing {needle}",
                case.name
            );
        }
        for forbidden in case.forbidden_labels {
            let forbidden_id = label_to_id
                .get(&forbidden)
                .unwrap_or_else(|| panic!("{} missing forbidden label {forbidden}", case.name));
            assert!(
                !returned_ids.contains(forbidden_id.as_str()),
                "{} should not return {forbidden}",
                case.name
            );
        }
    }
}
