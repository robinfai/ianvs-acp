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
            "text": "Use Riverpod providers for shared Flutter state in this repo.",
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
        .json(&serde_json::json!({
            "text": "Prefer Riverpod providers for shared Flutter state in this repo."
        }))
        .send()
        .await
        .expect("patch")
        .json::<serde_json::Value>()
        .await
        .expect("patch json");
    assert_eq!(
        patched["text"],
        "Prefer Riverpod providers for shared Flutter state in this repo."
    );

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

#[tokio::test]
async fn search_hits_are_visible_in_audit_log() {
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
            "text": "Use curl for local service health checks.",
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
    let memory_id = created["id"].as_str().expect("memory id");

    let search = client
        .post(format!("{}/v1/memory/search", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "query": "health checks",
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
    assert_eq!(search["items"][0]["id"], memory_id);

    let audit = client
        .get(format!("{}/v1/memory/audit?limit=10", state.base_url))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("audit")
        .json::<serde_json::Value>()
        .await
        .expect("audit json");
    let items = audit["items"].as_array().expect("audit items");
    let search_audit = items
        .iter()
        .find(|item| item["action"] == "memory.search")
        .expect("search audit");
    assert_eq!(search_audit["memoryId"], memory_id);
    assert_eq!(search_audit["payload"]["resultCount"], 1);
    assert_eq!(search_audit["payload"]["memoryIds"][0], memory_id);
}

#[tokio::test]
async fn search_misses_are_visible_in_audit_log_without_query_text() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    let search = client
        .post(format!("{}/v1/memory/search", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "query": "remember my secret phrase blue tower",
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
    assert_eq!(search["items"].as_array().expect("items").len(), 0);

    let audit = client
        .get(format!("{}/v1/memory/audit?limit=10", state.base_url))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("audit")
        .json::<serde_json::Value>()
        .await
        .expect("audit json");
    let items = audit["items"].as_array().expect("audit items");
    let search_audit = items
        .iter()
        .find(|item| item["action"] == "memory.search")
        .expect("search audit");
    assert!(search_audit["memoryId"].is_null());
    assert_eq!(search_audit["payload"]["resultCount"], 0);
    assert_eq!(
        search_audit["payload"]["memoryIds"]
            .as_array()
            .expect("memory ids")
            .len(),
        0
    );
    assert!(search_audit["payload"]["queryHash"].as_str().is_some());
    assert!(!search_audit["payload"].to_string().contains("blue tower"));
}

#[tokio::test]
async fn audit_visible_uses_current_scope() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    client
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "project_rule",
            "scope": "global",
            "text": "Global audit entry should be visible.",
            "scopeData": {
                "userId": "local-user",
                "workspaceId": "workspace-2",
                "repoId": "repo-2",
                "agentId": "agent-2",
                "sessionId": "session-2"
            }
        }))
        .send()
        .await
        .expect("create global memory");
    client
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "project_rule",
            "scope": "session",
            "text": "Other session audit entry should be hidden.",
            "scopeData": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1",
                "agentId": "agent-1",
                "sessionId": "session-2"
            }
        }))
        .send()
        .await
        .expect("create other session memory");

    for session_id in ["session-1", "session-2"] {
        client
            .post(format!("{}/v1/memory/search", state.base_url))
            .bearer_auth("test-token")
            .json(&serde_json::json!({
                "query": format!("no matching item for {session_id}"),
                "scope": {
                    "userId": "local-user",
                    "workspaceId": "workspace-1",
                    "repoId": "repo-1",
                    "agentId": "agent-1",
                    "sessionId": session_id
                },
                "limit": 10
            }))
            .send()
            .await
            .expect("search miss");
    }

    let audit = client
        .get(format!(
            "{}/v1/memory/audit?visible=true&userId=local-user&workspaceId=workspace-1&repoId=repo-1&agentId=agent-1&sessionId=session-1&limit=20",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("visible audit")
        .json::<serde_json::Value>()
        .await
        .expect("visible audit json");

    let items = audit["items"].as_array().expect("items");
    let payload_texts = items
        .iter()
        .filter_map(|item| item["payload"]["text"].as_str())
        .collect::<Vec<_>>();
    assert!(payload_texts.contains(&"Global audit entry should be visible."));
    assert!(!payload_texts.contains(&"Other session audit entry should be hidden."));

    let search_scopes = items
        .iter()
        .filter(|item| item["action"] == "memory.search")
        .map(|item| {
            item["payload"]["scope"]["sessionId"]
                .as_str()
                .expect("search session")
        })
        .collect::<Vec<_>>();
    assert_eq!(search_scopes, vec!["session-1"]);
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
                    "text": "The project uses Riverpod for state management.",
                    "confidence": 0.95,
                    "reason": "User explicitly gave a repo convention."
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
            "text": "The project uses Riverpod for state management."
        }))
        .send()
        .await
        .expect("approve")
        .json::<serde_json::Value>()
        .await
        .expect("approve json");
    assert_eq!(
        approved["text"],
        "The project uses Riverpod for state management."
    );

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
async fn manual_candidate_approval_triggers_high_confidence_maintenance() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    client
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "project_rule",
            "scope": "repo",
            "text": "Prefer curl for local health checks.",
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
        .expect("create memory");

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
                    "text": "Prefer curl for local health checks in this repo.",
                    "confidence": 0.82,
                    "reason": "Manual review candidate overlaps an existing rule."
                }
            ]
        }))
        .send()
        .await
        .expect("extract")
        .json::<serde_json::Value>()
        .await
        .expect("extract json");
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
            "text": "Prefer curl for local health checks in this repo."
        }))
        .send()
        .await
        .expect("approve")
        .json::<serde_json::Value>()
        .await
        .expect("approve json");
    assert_eq!(
        approved["text"],
        "Prefer curl for local health checks in this repo."
    );

    let active = client
        .get(format!(
            "{}/v1/memory?userId=local-user&repoId=repo-1&status=active",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("list active")
        .json::<serde_json::Value>()
        .await
        .expect("active json");
    assert_eq!(active["items"].as_array().unwrap().len(), 1);

    let audit_pool = memory_core::db::sqlite::open(temp.path())
        .await
        .expect("audit db");
    let maintenance_auto_count: i64 = sqlx::query_scalar(
        "select count(*) from memory_audit_log where action = 'maintenance.auto_approve'",
    )
    .fetch_one(&audit_pool)
    .await
    .expect("audit count");
    assert_eq!(maintenance_auto_count, 1);
}

#[tokio::test]
async fn high_confidence_candidates_auto_approve_and_mid_confidence_are_skipped() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    let extracted = client
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
            "autoApproveThreshold": 0.90,
            "preExtractedCandidates": [
                {
                    "kind": "user_preference",
                    "scope": "global",
                    "text": "The user prefers concise answers.",
                    "confidence": 0.95,
                    "reason": "Explicit durable preference."
                },
                {
                    "kind": "project_rule",
                    "scope": "repo",
                    "text": "Use the amber migration checklist.",
                    "confidence": 0.82,
                    "reason": "Potential project rule."
                }
            ]
        }))
        .send()
        .await
        .expect("extract")
        .json::<serde_json::Value>()
        .await
        .expect("extract json");

    assert_eq!(extracted["approvedMemories"].as_array().unwrap().len(), 1);
    assert_eq!(
        extracted["approvedMemories"][0]["text"],
        "The user prefers concise answers."
    );
    assert_eq!(extracted["candidates"].as_array().unwrap().len(), 1);
    assert_eq!(extracted["candidates"][0]["status"], "approved");

    let pending = client
        .get(format!(
            "{}/v1/memory/candidates?userId=local-user&repoId=repo-1&status=pending",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("list pending")
        .json::<serde_json::Value>()
        .await
        .expect("pending json");
    assert_eq!(pending["items"].as_array().unwrap().len(), 0);

    let audit_pool = memory_core::db::sqlite::open(temp.path())
        .await
        .expect("audit db");
    let auto_approve_count: i64 = sqlx::query_scalar(
        "select count(*) from memory_audit_log where action = 'candidate.auto_approve'",
    )
    .fetch_one(&audit_pool)
    .await
    .expect("audit count");
    assert_eq!(auto_approve_count, 1);
    let skipped_count: i64 = sqlx::query_scalar(
        "select count(*) from memory_audit_log where action = 'candidate.skip_below_auto_threshold'",
    )
    .fetch_one(&audit_pool)
    .await
    .expect("skip audit count");
    assert_eq!(skipped_count, 1);
}

#[tokio::test]
async fn candidate_policy_rejects_agents_and_tool_use_constraints() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    let extracted = client
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
            "autoApproveThreshold": 0.90,
            "preExtractedCandidates": [
                {
                    "kind": "project_rule",
                    "scope": "repo",
                    "text": "AGENTS.md 约束：中文回复，严禁使用 nc 或 netcat。",
                    "confidence": 0.95,
                    "reason": "Agent operating instruction."
                },
                {
                    "kind": "project_rule",
                    "scope": "repo",
                    "text": "The project uses Riverpod for state management.",
                    "confidence": 0.95,
                    "reason": "Durable project convention."
                }
            ]
        }))
        .send()
        .await
        .expect("extract")
        .json::<serde_json::Value>()
        .await
        .expect("extract json");

    let approved = extracted["approvedMemories"].as_array().unwrap();
    assert_eq!(approved.len(), 1);
    assert_eq!(
        approved[0]["text"],
        "The project uses Riverpod for state management."
    );
    let candidates = extracted["candidates"].as_array().unwrap();
    assert_eq!(candidates.len(), 1);
    assert_eq!(candidates[0]["text"], approved[0]["text"]);
}

#[tokio::test]
async fn automatic_candidate_extraction_skips_missing_confidence() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    let extracted = client
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
            "autoApproveThreshold": 0.90,
            "preExtractedCandidates": [
                {
                    "kind": "user_preference",
                    "scope": "global",
                    "text": "The user prefers concise answers.",
                    "reason": "Explicit durable preference without confidence."
                }
            ]
        }))
        .send()
        .await
        .expect("extract")
        .json::<serde_json::Value>()
        .await
        .expect("extract json");

    assert_eq!(extracted["approvedMemories"].as_array().unwrap().len(), 0);
    assert_eq!(extracted["candidates"].as_array().unwrap().len(), 0);

    let active = client
        .get(format!(
            "{}/v1/memory?userId=local-user&repoId=repo-1&status=active",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("list active")
        .json::<serde_json::Value>()
        .await
        .expect("active json");
    assert_eq!(active["items"].as_array().unwrap().len(), 0);

    let pending = client
        .get(format!(
            "{}/v1/memory/candidates?userId=local-user&repoId=repo-1&status=pending",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("list pending")
        .json::<serde_json::Value>()
        .await
        .expect("pending json");
    assert_eq!(pending["items"].as_array().unwrap().len(), 0);

    let audit_pool = memory_core::db::sqlite::open(temp.path())
        .await
        .expect("audit db");
    let skipped_count: i64 = sqlx::query_scalar(
        "select count(*) from memory_audit_log where action = 'candidate.skip_below_auto_threshold'",
    )
    .fetch_one(&audit_pool)
    .await
    .expect("skip audit count");
    assert_eq!(skipped_count, 1);
}

#[tokio::test]
async fn automatic_candidate_extraction_requires_confidence_even_at_zero_threshold() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    let extracted = client
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
            "autoApproveThreshold": 0.0,
            "preExtractedCandidates": [
                {
                    "kind": "project_rule",
                    "scope": "repo",
                    "text": "Use curl for local service checks.",
                    "reason": "Rule extraction omitted confidence."
                }
            ]
        }))
        .send()
        .await
        .expect("extract")
        .json::<serde_json::Value>()
        .await
        .expect("extract json");

    assert_eq!(extracted["approvedMemories"].as_array().unwrap().len(), 0);
    assert_eq!(extracted["candidates"].as_array().unwrap().len(), 0);

    let active = client
        .get(format!(
            "{}/v1/memory?userId=local-user&repoId=repo-1&status=active",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("list active")
        .json::<serde_json::Value>()
        .await
        .expect("active json");
    assert_eq!(active["items"].as_array().unwrap().len(), 0);
}

#[tokio::test]
async fn duplicate_candidates_are_suppressed_before_review() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    let active = client
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "project_rule",
            "scope": "repo",
            "text": "Prefer curl for local health checks.",
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
    assert_eq!(active["status"], "active");

    let first_extract = client
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
                    "text": "Prefer curl for local health checks.",
                    "confidence": 0.86,
                    "reason": "Duplicate of an active rule."
                },
                {
                    "kind": "project_rule",
                    "scope": "repo",
                    "text": "Use the amber migration checklist.",
                    "confidence": 0.82,
                    "reason": "Potential project rule."
                }
            ]
        }))
        .send()
        .await
        .expect("extract")
        .json::<serde_json::Value>()
        .await
        .expect("extract json");
    let first_candidates = first_extract["candidates"].as_array().unwrap();
    assert_eq!(first_candidates.len(), 1);
    assert_eq!(
        first_candidates[0]["text"],
        "Use the amber migration checklist."
    );
    assert_eq!(first_candidates[0]["status"], "pending");

    let second_extract = client
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
                    "text": "Use the amber migration checklist.",
                    "confidence": 0.84,
                    "reason": "Repeated by the extractor."
                }
            ]
        }))
        .send()
        .await
        .expect("extract again")
        .json::<serde_json::Value>()
        .await
        .expect("extract again json");
    assert_eq!(second_extract["candidates"].as_array().unwrap().len(), 0);

    let pending = client
        .get(format!(
            "{}/v1/memory/candidates?userId=local-user&repoId=repo-1&status=pending",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("list pending")
        .json::<serde_json::Value>()
        .await
        .expect("pending json");
    assert_eq!(pending["items"].as_array().unwrap().len(), 1);
    assert_eq!(
        pending["items"][0]["text"],
        "Use the amber migration checklist."
    );

    let audit_pool = memory_core::db::sqlite::open(temp.path())
        .await
        .expect("audit db");
    let skipped_count: i64 = sqlx::query_scalar(
        "select count(*) from memory_audit_log where action = 'candidate.skip_duplicate'",
    )
    .fetch_one(&audit_pool)
    .await
    .expect("audit count");
    assert_eq!(skipped_count, 2);
}

#[tokio::test]
async fn auto_approved_candidates_trigger_high_confidence_maintenance() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    let extracted = client
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
            "autoApproveThreshold": 0.80,
            "preExtractedCandidates": [
                {
                    "kind": "project_rule",
                    "scope": "repo",
                    "text": "Prefer curl for local health checks.",
                    "confidence": 0.95,
                    "reason": "Explicit durable project rule."
                },
                {
                    "kind": "project_rule",
                    "scope": "repo",
                    "text": "Prefer curl for local health checks in this repo.",
                    "confidence": 0.94,
                    "reason": "Overlapping durable project rule repeated."
                }
            ]
        }))
        .send()
        .await
        .expect("extract")
        .json::<serde_json::Value>()
        .await
        .expect("extract json");

    assert_eq!(extracted["approvedMemories"].as_array().unwrap().len(), 2);

    let active = client
        .get(format!(
            "{}/v1/memory?userId=local-user&repoId=repo-1&status=active",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("list active")
        .json::<serde_json::Value>()
        .await
        .expect("active json");
    assert_eq!(active["items"].as_array().unwrap().len(), 1);
    assert_eq!(
        active["items"][0]["text"],
        "Prefer curl for local health checks."
    );

    let audit_pool = memory_core::db::sqlite::open(temp.path())
        .await
        .expect("audit db");
    let maintenance_auto_count: i64 = sqlx::query_scalar(
        "select count(*) from memory_audit_log where action = 'maintenance.auto_approve'",
    )
    .fetch_one(&audit_pool)
    .await
    .expect("audit count");
    assert_eq!(maintenance_auto_count, 1);
}

#[tokio::test]
async fn change_request_update_and_reject_are_audited() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    let created = client
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "user_preference",
            "scope": "global",
            "text": "The user goes by Rod.",
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
        .expect("create memory json");
    let memory_id = created["id"].as_str().expect("memory id");

    let request = client
        .post(format!("{}/v1/memory/change-requests", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1",
                "agentId": "agent-1",
                "sessionId": "session-1"
            },
            "action": "update",
            "targetMemoryIds": [memory_id],
            "proposedKind": "user_preference",
            "proposedScope": "global",
            "proposedText": "The user goes by Rodriguez.",
            "reason": "Clarify the preferred name.",
            "confidence": 0.82
        }))
        .send()
        .await
        .expect("create change request")
        .json::<serde_json::Value>()
        .await
        .expect("change request json");
    assert_eq!(request["status"], "pending");
    assert_eq!(request["targetMemoryIds"][0], memory_id);
    let request_id = request["id"].as_str().expect("request id");

    let listed = client
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
        .expect("list json");
    assert_eq!(listed["items"].as_array().unwrap().len(), 1);

    let approved = client
        .post(format!(
            "{}/v1/memory/change-requests/{request_id}/approve",
            state.base_url
        ))
        .bearer_auth("test-token")
        .json(&serde_json::json!({}))
        .send()
        .await
        .expect("approve change request")
        .json::<serde_json::Value>()
        .await
        .expect("approve json");
    assert_eq!(approved["status"], "approved");

    let listed_memory = client
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
        .expect("memory json");
    assert_eq!(
        listed_memory["items"][0]["text"],
        "The user goes by Rodriguez."
    );

    let rejected_request = client
        .post(format!("{}/v1/memory/change-requests", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1"
            },
            "action": "update",
            "targetMemoryIds": [memory_id],
            "proposedKind": "user_preference",
            "proposedScope": "global",
            "proposedText": "The user goes by R.",
            "reason": "Bad suggestion.",
            "confidence": 0.40
        }))
        .send()
        .await
        .expect("create rejected change request")
        .json::<serde_json::Value>()
        .await
        .expect("rejected change request json");
    let rejected_id = rejected_request["id"].as_str().expect("rejected id");
    let rejected = client
        .post(format!(
            "{}/v1/memory/change-requests/{rejected_id}/reject",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("reject change request")
        .json::<serde_json::Value>()
        .await
        .expect("reject json");
    assert_eq!(rejected["status"], "rejected");

    let audit_pool = memory_core::db::sqlite::open(temp.path())
        .await
        .expect("audit db");
    let approve_count: i64 = sqlx::query_scalar(
        "select count(*) from memory_audit_log
         where action in ('change_request.create', 'change_request.approve', 'change_request.reject')",
    )
    .fetch_one(&audit_pool)
    .await
    .expect("audit count");
    assert_eq!(approve_count, 4);
}

#[tokio::test]
async fn approving_update_change_request_triggers_followup_maintenance() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    let first = client
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "project_rule",
            "scope": "repo",
            "text": "Use curl for local service checks.",
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
        .expect("create first memory")
        .json::<serde_json::Value>()
        .await
        .expect("first memory json");
    let second = client
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "project_rule",
            "scope": "repo",
            "text": "Use curl and lsof for local service checks.",
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
        .expect("create second memory")
        .json::<serde_json::Value>()
        .await
        .expect("second memory json");

    let first_id = first["id"].as_str().expect("first memory id");
    let request = client
        .post(format!("{}/v1/memory/change-requests", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1",
                "agentId": "agent-1",
                "sessionId": "session-1"
            },
            "action": "update",
            "targetMemoryIds": [first_id],
            "proposedKind": "project_rule",
            "proposedScope": "repo",
            "proposedText": second["text"],
            "reason": "Refine the service check rule.",
            "confidence": 0.93
        }))
        .send()
        .await
        .expect("create update request")
        .json::<serde_json::Value>()
        .await
        .expect("update request json");
    let request_id = request["id"].as_str().expect("request id");

    let approved = client
        .post(format!(
            "{}/v1/memory/change-requests/{request_id}/approve",
            state.base_url
        ))
        .bearer_auth("test-token")
        .json(&serde_json::json!({}))
        .send()
        .await
        .expect("approve update request")
        .json::<serde_json::Value>()
        .await
        .expect("approve json");
    assert_eq!(approved["status"], "approved");

    let listed = client
        .get(format!(
            "{}/v1/memory?visible=true&userId=local-user&workspaceId=workspace-1&repoId=repo-1&agentId=agent-1&sessionId=session-1&status=active",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("list active memory")
        .json::<serde_json::Value>()
        .await
        .expect("active memory json");
    let items = listed["items"].as_array().expect("active items");
    assert_eq!(items.len(), 1);
    assert_eq!(items[0]["scope"], "global");
    assert_eq!(items[0]["text"], second["text"]);

    let audit_pool = memory_core::db::sqlite::open(temp.path())
        .await
        .expect("audit db");
    let maintenance_auto_count: i64 = sqlx::query_scalar(
        "select count(*) from memory_audit_log where action = 'maintenance.auto_approve'",
    )
    .fetch_one(&audit_pool)
    .await
    .expect("maintenance audit count");
    assert_eq!(maintenance_auto_count, 1);
}

#[tokio::test]
async fn change_request_create_normalizes_directional_scope_before_review() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    let session_memory = client
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "project_rule",
            "scope": "session",
            "text": "The project passphrase is blue lighthouse 43130.",
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
        .expect("create session memory")
        .json::<serde_json::Value>()
        .await
        .expect("session memory json");
    let global_memory = client
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "project_rule",
            "scope": "global",
            "text": "The project passphrase is blue lighthouse 43130.",
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
        .expect("create global memory")
        .json::<serde_json::Value>()
        .await
        .expect("global memory json");

    let session_memory_id = session_memory["id"].as_str().expect("session id");
    let global_memory_id = global_memory["id"].as_str().expect("global id");

    let merge_request = client
        .post(format!("{}/v1/memory/change-requests", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1",
                "agentId": "agent-1",
                "sessionId": "session-1"
            },
            "action": "merge",
            "targetMemoryIds": [session_memory_id, global_memory_id],
            "proposedKind": "project_rule",
            "proposedScope": "global",
            "proposedText": "The project passphrase is blue lighthouse 43130.",
            "reason": "Same fact appears in multiple scopes.",
            "confidence": 0.93
        }))
        .send()
        .await
        .expect("create merge request")
        .json::<serde_json::Value>()
        .await
        .expect("merge request json");
    assert_eq!(merge_request["proposedScope"], "global");

    let update_request = client
        .post(format!("{}/v1/memory/change-requests", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1",
                "agentId": "agent-1",
                "sessionId": "session-1"
            },
            "action": "update",
            "targetMemoryIds": [session_memory_id],
            "proposedKind": "project_rule",
            "proposedScope": "global",
            "proposedText": "The project passphrase is blue lighthouse 43130.",
            "reason": "Promote one layer only.",
            "confidence": 0.91
        }))
        .send()
        .await
        .expect("create update request")
        .json::<serde_json::Value>()
        .await
        .expect("update request json");
    assert_eq!(update_request["proposedScope"], "repo");
}

#[tokio::test]
async fn maintenance_run_creates_pending_merge_request_for_duplicate_memory() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    let mut memory_ids = Vec::new();
    for text in [
        "The user goes by Rodriguez.",
        "The user prefers to be called Rodriguez.",
    ] {
        let created = client
            .post(format!("{}/v1/memory", state.base_url))
            .bearer_auth("test-token")
            .json(&serde_json::json!({
                "kind": "user_preference",
                "scope": "global",
                "text": text,
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
        memory_ids.push(created["id"].as_str().expect("memory id").to_string());
    }

    let response = client
        .post(format!("{}/v1/memory/maintenance/run", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1",
                "agentId": "agent-1",
                "sessionId": "session-1"
            },
            "enabled": true,
            "mode": "manual_review",
            "maxItemsPerBatch": 12
        }))
        .send()
        .await
        .expect("run maintenance");
    assert_eq!(response.status(), reqwest::StatusCode::OK);
    let result = response
        .json::<serde_json::Value>()
        .await
        .expect("maintenance json");
    assert_eq!(result["autoApplied"], 0);
    assert_eq!(result["needsReview"], 1);
    assert_eq!(result["changeRequests"].as_array().unwrap().len(), 1);
    assert_eq!(result["changeRequests"][0]["action"], "merge");
    let mut target_ids = result["changeRequests"][0]["targetMemoryIds"]
        .as_array()
        .expect("target ids")
        .iter()
        .map(|value| value.as_str().expect("target id").to_string())
        .collect::<Vec<_>>();
    target_ids.sort();
    memory_ids.sort();
    assert_eq!(target_ids, memory_ids);
    assert_eq!(result["changeRequests"][0]["status"], "pending");

    let listed = client
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
        .expect("list json");
    assert_eq!(listed["items"].as_array().unwrap().len(), 1);

    let audit_pool = memory_core::db::sqlite::open(temp.path())
        .await
        .expect("audit db");
    let maintenance_count: i64 = sqlx::query_scalar(
        "select count(*) from memory_audit_log where action = 'maintenance.run'",
    )
    .fetch_one(&audit_pool)
    .await
    .expect("audit count");
    assert_eq!(maintenance_count, 1);
}

#[tokio::test]
async fn maintenance_run_auto_merges_chinese_synonym_preferences() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    for text in [
        "用户偏好使用中文交流。",
        "用户偏好以中文进行交流与回复。",
        "用户偏好中文回复。",
    ] {
        client
            .post(format!("{}/v1/memory", state.base_url))
            .bearer_auth("test-token")
            .json(&serde_json::json!({
                "kind": "user_preference",
                "scope": "global",
                "text": text,
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
            .expect("create memory");
    }

    let response = client
        .post(format!("{}/v1/memory/maintenance/run", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1",
                "agentId": "agent-1",
                "sessionId": "session-1"
            },
            "enabled": true,
            "mode": "high_confidence_auto",
            "highConfidenceThreshold": 0.90,
            "reviewThreshold": 0.75,
            "maxItemsPerBatch": 12
        }))
        .send()
        .await
        .expect("maintenance")
        .json::<serde_json::Value>()
        .await
        .expect("maintenance json");

    assert_eq!(response["autoApplied"], 1);
    assert_eq!(response["needsReview"], 0);

    let listed = client
        .get(format!(
            "{}/v1/memory?userId=local-user&repoId=repo-1&status=active",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("list")
        .json::<serde_json::Value>()
        .await
        .expect("list json");

    let active_items = listed["items"].as_array().expect("active items");
    assert_eq!(active_items.len(), 1);
    assert_eq!(active_items[0]["scope"], "global");
    assert_eq!(active_items[0]["text"], "用户偏好中文回复。");
}

#[tokio::test]
async fn maintenance_run_does_not_count_unmatched_pairs_as_skipped() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    for (kind, text) in [
        ("user_preference", "用户自称 Rodriguez。"),
        ("user_preference", "用户当前位于深圳。"),
        ("project_rule", "项目共享状态使用 Riverpod。"),
        (
            "architecture_decision",
            "Rust memory-core owns local persistence.",
        ),
    ] {
        client
            .post(format!("{}/v1/memory", state.base_url))
            .bearer_auth("test-token")
            .json(&serde_json::json!({
                "kind": kind,
                "scope": "global",
                "text": text,
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
            .expect("create memory");
    }

    let response = client
        .post(format!("{}/v1/memory/maintenance/run", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1",
                "agentId": "agent-1",
                "sessionId": "session-1"
            },
            "enabled": true,
            "mode": "high_confidence_auto"
        }))
        .send()
        .await
        .expect("maintenance")
        .json::<serde_json::Value>()
        .await
        .expect("maintenance json");

    assert_eq!(response["autoApplied"], 0);
    assert_eq!(response["needsReview"], 0);
    assert_eq!(response["skipped"], 0);
}

#[tokio::test]
async fn maintenance_run_cleans_disabled_duplicates() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    let mut memory_ids = Vec::new();
    for text in [
        "Prefer curl for local health checks.",
        "Prefer curl for local health checks.",
        "Prefer curl for local health checks.",
    ] {
        let created = client
            .post(format!("{}/v1/memory", state.base_url))
            .bearer_auth("test-token")
            .json(&serde_json::json!({
                "kind": "project_rule",
                "scope": "repo",
                "text": text,
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
        memory_ids.push(created["id"].as_str().expect("memory id").to_string());
    }

    let disabled_ids = vec![memory_ids[1].clone(), memory_ids[2].clone()];
    for disabled_id in &disabled_ids {
        let patched = client
            .patch(format!("{}/v1/memory/{disabled_id}", state.base_url))
            .bearer_auth("test-token")
            .json(&serde_json::json!({
                "status": "disabled"
            }))
            .send()
            .await
            .expect("disable memory")
            .json::<serde_json::Value>()
            .await
            .expect("disable json");
        assert_eq!(patched["status"], "disabled");
    }

    let response = client
        .post(format!("{}/v1/memory/maintenance/run", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1",
                "agentId": "agent-1",
                "sessionId": "session-1"
            },
            "enabled": true,
            "mode": "high_confidence_auto",
            "highConfidenceThreshold": 0.90,
            "reviewThreshold": 0.75,
            "manualOnlyActions": ["delete"],
            "maxItemsPerBatch": 12
        }))
        .send()
        .await
        .expect("run maintenance")
        .json::<serde_json::Value>()
        .await
        .expect("maintenance json");

    assert_eq!(response["autoApplied"], 0);
    assert_eq!(response["needsReview"], 2);
    let change_requests = response["changeRequests"]
        .as_array()
        .expect("change requests");
    let mut cleanup_ids = change_requests
        .iter()
        .map(|request| {
            assert_eq!(request["action"], "delete");
            assert_eq!(request["status"], "pending");
            request["targetMemoryIds"][0]
                .as_str()
                .expect("target id")
                .to_string()
        })
        .collect::<Vec<_>>();
    cleanup_ids.sort();
    let mut expected_ids = disabled_ids;
    expected_ids.sort();
    assert_eq!(cleanup_ids, expected_ids);

    let audit_pool = memory_core::db::sqlite::open(temp.path())
        .await
        .expect("audit db");
    let cleanup_count: i64 = sqlx::query_scalar(
        "select count(*) from memory_audit_log where action = 'change_request.create'",
    )
    .fetch_one(&audit_pool)
    .await
    .expect("audit count");
    assert_eq!(cleanup_count, 2);
}

#[tokio::test]
async fn maintenance_run_auto_applies_multiple_disjoint_merges_in_one_batch() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    for text in [
        "The user prefers Chinese replies.",
        "The user prefers Chinese replies.",
        "Prefer curl for local health checks.",
        "Prefer curl for local health checks.",
    ] {
        client
            .post(format!("{}/v1/memory", state.base_url))
            .bearer_auth("test-token")
            .json(&serde_json::json!({
                "kind": "project_rule",
                "scope": "session",
                "text": text,
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
            .expect("create memory");
    }

    let response = client
        .post(format!("{}/v1/memory/maintenance/run", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1",
                "agentId": "agent-1",
                "sessionId": "session-1"
            },
            "enabled": true,
            "mode": "high_confidence_auto",
            "highConfidenceThreshold": 0.90,
            "reviewThreshold": 0.75,
            "maxItemsPerBatch": 12
        }))
        .send()
        .await
        .expect("run maintenance")
        .json::<serde_json::Value>()
        .await
        .expect("maintenance json");

    assert_eq!(response["autoApplied"], 2);
    assert_eq!(response["needsReview"], 0);
    assert_eq!(response["changeRequests"].as_array().unwrap().len(), 2);
    assert!(response["changeRequests"]
        .as_array()
        .unwrap()
        .iter()
        .all(|request| request["action"] == "merge" && request["status"] == "approved"));

    let active = client
        .get(format!(
            "{}/v1/memory?visible=true&userId=local-user&workspaceId=workspace-1&repoId=repo-1&agentId=agent-1&sessionId=session-1&status=active",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("list active")
        .json::<serde_json::Value>()
        .await
        .expect("active json");
    let items = active["items"].as_array().expect("items");
    assert_eq!(items.len(), 2);
    assert!(items.iter().all(|item| item["scope"] == "repo"));
}

#[tokio::test]
async fn maintenance_run_auto_merge_removes_old_targets_from_visible_memory() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    for scope in ["session", "session"] {
        client
            .post(format!("{}/v1/memory", state.base_url))
            .bearer_auth("test-token")
            .json(&serde_json::json!({
                "kind": "user_preference",
                "scope": scope,
                "text": "用户偏好使用中文交流。",
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
            .expect("create memory");
    }

    let response = client
        .post(format!("{}/v1/memory/maintenance/run", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1",
                "agentId": "agent-1",
                "sessionId": "session-1"
            },
            "enabled": true,
            "mode": "high_confidence_auto",
            "highConfidenceThreshold": 0.90,
            "reviewThreshold": 0.75,
            "maxItemsPerBatch": 12
        }))
        .send()
        .await
        .expect("run maintenance")
        .json::<serde_json::Value>()
        .await
        .expect("maintenance json");

    assert_eq!(response["autoApplied"], 1);
    assert_eq!(response["needsReview"], 0);

    let active = client
        .get(format!(
            "{}/v1/memory?visible=true&userId=local-user&workspaceId=workspace-1&repoId=repo-1&agentId=agent-1&sessionId=session-1&status=active",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("list active")
        .json::<serde_json::Value>()
        .await
        .expect("active json");
    let active_items = active["items"].as_array().expect("active items");
    assert_eq!(active_items.len(), 1);
    assert_eq!(active_items[0]["scope"], "repo");
    assert_eq!(active_items[0]["text"], "用户偏好使用中文交流。");

    let disabled = client
        .get(format!(
            "{}/v1/memory?visible=true&userId=local-user&workspaceId=workspace-1&repoId=repo-1&agentId=agent-1&sessionId=session-1&status=disabled",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("list disabled")
        .json::<serde_json::Value>()
        .await
        .expect("disabled json");
    assert_eq!(
        disabled["items"].as_array().expect("disabled items").len(),
        0
    );
}

#[tokio::test]
async fn maintenance_run_does_not_duplicate_pending_merge_requests() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    for text in [
        "The user prefers Chinese replies.",
        "The user prefers Chinese replies.",
    ] {
        client
            .post(format!("{}/v1/memory", state.base_url))
            .bearer_auth("test-token")
            .json(&serde_json::json!({
                "kind": "user_preference",
                "scope": "global",
                "text": text,
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
            .expect("create memory");
    }

    for expected_needs_review in [1, 0] {
        let response = client
            .post(format!("{}/v1/memory/maintenance/run", state.base_url))
            .bearer_auth("test-token")
            .json(&serde_json::json!({
                "scope": {
                    "userId": "local-user",
                    "workspaceId": "workspace-1",
                    "repoId": "repo-1",
                    "agentId": "agent-1",
                    "sessionId": "session-1"
                },
                "enabled": true,
                "mode": "manual_review",
                "reviewThreshold": 0.75,
                "maxItemsPerBatch": 12
            }))
            .send()
            .await
            .expect("run maintenance")
            .json::<serde_json::Value>()
            .await
            .expect("maintenance json");
        assert_eq!(response["needsReview"], expected_needs_review);
    }

    let listed = client
        .get(format!(
            "{}/v1/memory/change-requests?userId=local-user&status=pending",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("list change requests")
        .json::<serde_json::Value>()
        .await
        .expect("list json");
    assert_eq!(listed["items"].as_array().unwrap().len(), 1);
    assert_eq!(listed["items"][0]["action"], "merge");
}

#[tokio::test]
async fn maintenance_run_still_cleans_disabled_duplicates_after_llm_suggestions() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    let mut project_rule_ids = Vec::new();
    for text in [
        "Prefer curl for local health checks.",
        "Prefer curl for local health checks.",
    ] {
        let created = client
            .post(format!("{}/v1/memory", state.base_url))
            .bearer_auth("test-token")
            .json(&serde_json::json!({
                "kind": "project_rule",
                "scope": "repo",
                "text": text,
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
            .expect("create project rule memory")
            .json::<serde_json::Value>()
            .await
            .expect("project rule memory json");
        project_rule_ids.push(created["id"].as_str().expect("memory id").to_string());
    }

    let disabled_project_rule_id = project_rule_ids[1].clone();
    client
        .patch(format!(
            "{}/v1/memory/{disabled_project_rule_id}",
            state.base_url
        ))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "status": "disabled"
        }))
        .send()
        .await
        .expect("disable project rule memory");

    let user_preference = client
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "user_preference",
            "scope": "global",
            "text": "The user goes by Rod.",
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
        .expect("create user preference memory")
        .json::<serde_json::Value>()
        .await
        .expect("user preference memory json");
    let user_preference_id = user_preference["id"].as_str().expect("memory id");

    let response = client
        .post(format!("{}/v1/memory/maintenance/run", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1",
                "agentId": "agent-1",
                "sessionId": "session-1"
            },
            "enabled": true,
            "mode": "high_confidence_auto",
            "highConfidenceThreshold": 0.90,
            "reviewThreshold": 0.75,
            "manualOnlyActions": ["delete"],
            "maxItemsPerBatch": 12,
            "preExtractedChangeRequests": [
                {
                    "action": "update",
                    "targetMemoryIds": [user_preference_id],
                    "proposedKind": "user_preference",
                    "proposedScope": "global",
                    "proposedText": "The user goes by Rodriguez.",
                    "confidence": 0.95,
                    "reason": "Normalize the preferred name memory."
                }
            ]
        }))
        .send()
        .await
        .expect("run maintenance")
        .json::<serde_json::Value>()
        .await
        .expect("maintenance json");

    assert_eq!(response["autoApplied"], 1);
    assert_eq!(response["needsReview"], 1);
    let change_requests = response["changeRequests"]
        .as_array()
        .expect("change requests");
    assert!(change_requests
        .iter()
        .any(|request| request["action"] == "update" && request["status"] == "approved"));
    assert!(change_requests.iter().any(|request| {
        request["action"] == "delete"
            && request["status"] == "pending"
            && request["targetMemoryIds"][0] == disabled_project_rule_id
    }));
}

#[tokio::test]
async fn maintenance_run_deduplicates_llm_and_builtin_cleanup_requests() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    let mut memory_ids = Vec::new();
    for text in [
        "Prefer curl for local health checks.",
        "Prefer curl for local health checks.",
    ] {
        let created = client
            .post(format!("{}/v1/memory", state.base_url))
            .bearer_auth("test-token")
            .json(&serde_json::json!({
                "kind": "project_rule",
                "scope": "repo",
                "text": text,
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
        memory_ids.push(created["id"].as_str().expect("memory id").to_string());
    }

    let disabled_id = memory_ids[1].clone();
    client
        .patch(format!("{}/v1/memory/{disabled_id}", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "status": "disabled"
        }))
        .send()
        .await
        .expect("disable memory");

    let response = client
        .post(format!("{}/v1/memory/maintenance/run", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1",
                "agentId": "agent-1",
                "sessionId": "session-1"
            },
            "enabled": true,
            "mode": "high_confidence_auto",
            "highConfidenceThreshold": 0.90,
            "reviewThreshold": 0.75,
            "manualOnlyActions": ["delete"],
            "maxItemsPerBatch": 12,
            "preExtractedChangeRequests": [
                {
                    "action": "delete",
                    "targetMemoryIds": [disabled_id],
                    "confidence": 0.97,
                    "reason": "Disabled memory duplicates the active memory."
                }
            ]
        }))
        .send()
        .await
        .expect("run maintenance")
        .json::<serde_json::Value>()
        .await
        .expect("maintenance json");

    assert_eq!(response["needsReview"], 1);
    let change_requests = response["changeRequests"]
        .as_array()
        .expect("change requests");
    let delete_requests = change_requests
        .iter()
        .filter(|request| request["action"] == "delete")
        .count();
    assert_eq!(delete_requests, 1);

    let listed = client
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
        .expect("list json");
    assert_eq!(listed["items"].as_array().expect("items").len(), 1);
}

#[tokio::test]
async fn maintenance_run_merges_disabled_memory_without_downgrading_global_scope() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    let disabled_session_memory = client
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "project_rule",
            "scope": "session",
            "text": "Prefer curl for local service checks.",
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
        .expect("create disabled session memory")
        .json::<serde_json::Value>()
        .await
        .expect("session memory json");
    let disabled_session_id = disabled_session_memory["id"]
        .as_str()
        .expect("memory id")
        .to_string();
    client
        .patch(format!(
            "{}/v1/memory/{disabled_session_id}",
            state.base_url
        ))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "status": "disabled"
        }))
        .send()
        .await
        .expect("disable session memory");

    let global_memory = client
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "project_rule",
            "scope": "global",
            "text": "Prefer curl for local health checks.",
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
        .expect("create global memory")
        .json::<serde_json::Value>()
        .await
        .expect("global memory json");
    let global_id = global_memory["id"].as_str().expect("memory id").to_string();

    let response = client
        .post(format!("{}/v1/memory/maintenance/run", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1",
                "agentId": "agent-1",
                "sessionId": "session-1"
            },
            "enabled": true,
            "mode": "manual_review",
            "reviewThreshold": 0.75,
            "maxItemsPerBatch": 12
        }))
        .send()
        .await
        .expect("run maintenance")
        .json::<serde_json::Value>()
        .await
        .expect("maintenance json");

    assert_eq!(response["needsReview"], 1);
    let change_request = &response["changeRequests"][0];
    assert_eq!(change_request["action"], "merge");
    assert_eq!(change_request["proposedScope"], "global");
    let mut target_ids = change_request["targetMemoryIds"]
        .as_array()
        .expect("target ids")
        .iter()
        .map(|value| value.as_str().expect("target id").to_string())
        .collect::<Vec<_>>();
    target_ids.sort();
    let mut expected_ids = vec![disabled_session_id, global_id];
    expected_ids.sort();
    assert_eq!(target_ids, expected_ids);
}

#[tokio::test]
async fn maintenance_run_merges_session_memory_toward_repo_scope() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    let session_memory = client
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "project_rule",
            "scope": "session",
            "text": "Prefer curl for local health checks.",
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
        .expect("create session memory")
        .json::<serde_json::Value>()
        .await
        .expect("session memory json");
    let repo_memory = client
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "project_rule",
            "scope": "repo",
            "text": "Prefer curl for local health checks in this repo.",
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
        .expect("create repo memory")
        .json::<serde_json::Value>()
        .await
        .expect("repo memory json");
    let mut memory_ids = vec![
        session_memory["id"].as_str().unwrap().to_string(),
        repo_memory["id"].as_str().unwrap().to_string(),
    ];
    memory_ids.sort();

    let response = client
        .post(format!("{}/v1/memory/maintenance/run", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1",
                "agentId": "agent-1",
                "sessionId": "session-1"
            },
            "enabled": true,
            "mode": "manual_review",
            "reviewThreshold": 0.75,
            "maxItemsPerBatch": 12
        }))
        .send()
        .await
        .expect("run maintenance")
        .json::<serde_json::Value>()
        .await
        .expect("maintenance json");

    assert_eq!(response["autoApplied"], 0);
    assert_eq!(response["needsReview"], 1);
    let change_request = &response["changeRequests"][0];
    assert_eq!(change_request["action"], "merge");
    assert_eq!(change_request["proposedScope"], "repo");
    let mut target_ids = change_request["targetMemoryIds"]
        .as_array()
        .expect("target ids")
        .iter()
        .map(|value| value.as_str().expect("target id").to_string())
        .collect::<Vec<_>>();
    target_ids.sort();
    assert_eq!(target_ids, memory_ids);
}

#[tokio::test]
async fn maintenance_run_merges_session_and_global_memory_toward_global_scope() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    let session_memory = client
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "project_rule",
            "scope": "session",
            "text": "Prefer curl for local health checks.",
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
        .expect("create session memory")
        .json::<serde_json::Value>()
        .await
        .expect("session memory json");
    let global_memory = client
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "project_rule",
            "scope": "global",
            "text": "Prefer curl for local health checks.",
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
        .expect("create global memory")
        .json::<serde_json::Value>()
        .await
        .expect("global memory json");
    let mut memory_ids = vec![
        session_memory["id"].as_str().unwrap().to_string(),
        global_memory["id"].as_str().unwrap().to_string(),
    ];
    memory_ids.sort();

    let response = client
        .post(format!("{}/v1/memory/maintenance/run", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1",
                "agentId": "agent-1",
                "sessionId": "session-1"
            },
            "enabled": true,
            "mode": "manual_review",
            "reviewThreshold": 0.75,
            "maxItemsPerBatch": 12
        }))
        .send()
        .await
        .expect("run maintenance")
        .json::<serde_json::Value>()
        .await
        .expect("maintenance json");

    assert_eq!(response["needsReview"], 1);
    let change_request = &response["changeRequests"][0];
    assert_eq!(change_request["action"], "merge");
    assert_eq!(change_request["proposedScope"], "global");
    let mut target_ids = change_request["targetMemoryIds"]
        .as_array()
        .expect("target ids")
        .iter()
        .map(|value| value.as_str().expect("target id").to_string())
        .collect::<Vec<_>>();
    target_ids.sort();
    assert_eq!(target_ids, memory_ids);
}

#[tokio::test]
async fn maintenance_run_promotes_repeated_session_memory_to_repo_scope() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    let mut memory_ids = Vec::new();
    for text in [
        "Prefer curl for local health checks.",
        "Prefer curl for local health checks in this repo.",
    ] {
        let created = client
            .post(format!("{}/v1/memory", state.base_url))
            .bearer_auth("test-token")
            .json(&serde_json::json!({
                "kind": "project_rule",
                "scope": "session",
                "text": text,
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
            .expect("create session memory")
            .json::<serde_json::Value>()
            .await
            .expect("session memory json");
        memory_ids.push(created["id"].as_str().unwrap().to_string());
    }
    memory_ids.sort();

    let response = client
        .post(format!("{}/v1/memory/maintenance/run", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1",
                "agentId": "agent-1",
                "sessionId": "session-1"
            },
            "enabled": true,
            "mode": "manual_review",
            "reviewThreshold": 0.75,
            "maxItemsPerBatch": 12
        }))
        .send()
        .await
        .expect("run maintenance")
        .json::<serde_json::Value>()
        .await
        .expect("maintenance json");

    assert_eq!(response["needsReview"], 1);
    let change_request = &response["changeRequests"][0];
    assert_eq!(change_request["action"], "merge");
    assert_eq!(change_request["proposedScope"], "repo");
    let mut target_ids = change_request["targetMemoryIds"]
        .as_array()
        .expect("target ids")
        .iter()
        .map(|value| value.as_str().expect("target id").to_string())
        .collect::<Vec<_>>();
    target_ids.sort();
    assert_eq!(target_ids, memory_ids);
}

#[tokio::test]
async fn maintenance_run_uses_session_repo_global_promotion_path() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    let repo_memory = client
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "project_rule",
            "scope": "repo",
            "text": "Prefer curl for local health checks.",
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
        .expect("create repo memory")
        .json::<serde_json::Value>()
        .await
        .expect("repo memory json");
    let workspace_memory = client
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "project_rule",
            "scope": "workspace",
            "text": "Prefer curl for local health checks.",
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
        .expect("create workspace memory")
        .json::<serde_json::Value>()
        .await
        .expect("workspace memory json");

    let mut memory_ids = vec![
        repo_memory["id"].as_str().unwrap().to_string(),
        workspace_memory["id"].as_str().unwrap().to_string(),
    ];
    memory_ids.sort();

    let response = client
        .post(format!("{}/v1/memory/maintenance/run", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1",
                "agentId": "agent-1",
                "sessionId": "session-1"
            },
            "enabled": true,
            "mode": "manual_review",
            "reviewThreshold": 0.75,
            "maxItemsPerBatch": 12
        }))
        .send()
        .await
        .expect("run maintenance")
        .json::<serde_json::Value>()
        .await
        .expect("maintenance json");

    assert_eq!(response["needsReview"], 1);
    let change_request = &response["changeRequests"][0];
    assert_eq!(change_request["action"], "merge");
    assert_eq!(change_request["proposedScope"], "global");
    let mut target_ids = change_request["targetMemoryIds"]
        .as_array()
        .expect("target ids")
        .iter()
        .map(|value| value.as_str().expect("target id").to_string())
        .collect::<Vec<_>>();
    target_ids.sort();
    assert_eq!(target_ids, memory_ids);
}

#[tokio::test]
async fn high_confidence_auto_skips_mid_confidence_maintenance_review_noise() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    let mut memory_ids = Vec::new();
    for text in [
        "The user goes by Rodriguez.",
        "The user prefers concise answers.",
    ] {
        let created = client
            .post(format!("{}/v1/memory", state.base_url))
            .bearer_auth("test-token")
            .json(&serde_json::json!({
                "kind": "user_preference",
                "scope": "global",
                "text": text,
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
        memory_ids.push(created["id"].as_str().expect("memory id").to_string());
    }

    let response = client
        .post(format!("{}/v1/memory/maintenance/run", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1",
                "agentId": "agent-1",
                "sessionId": "session-1"
            },
            "enabled": true,
            "mode": "high_confidence_auto",
            "highConfidenceThreshold": 0.90,
            "reviewThreshold": 0.75,
            "manualOnlyActions": ["delete"],
            "preExtractedChangeRequests": [
                {
                    "action": "merge",
                    "targetMemoryIds": [memory_ids[0], memory_ids[1]],
                    "proposedKind": "user_preference",
                    "proposedScope": "global",
                    "proposedText": "The user goes by Rodriguez and prefers concise answers.",
                    "confidence": 0.82,
                    "reason": "Medium-confidence consolidation should not burden review."
                }
            ]
        }))
        .send()
        .await
        .expect("run maintenance")
        .json::<serde_json::Value>()
        .await
        .expect("maintenance json");

    assert_eq!(response["autoApplied"], 0);
    assert_eq!(response["needsReview"], 0);
    assert_eq!(response["skipped"], 1);
    assert_eq!(response["changeRequests"].as_array().unwrap().len(), 0);
}

#[tokio::test]
async fn high_confidence_auto_keeps_cleanup_actions_pending_by_default() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    let mut memory_ids = Vec::new();
    for text in [
        "Temporary repo rule should be disabled.",
        "Stale repo rule should expire.",
    ] {
        let created = client
            .post(format!("{}/v1/memory", state.base_url))
            .bearer_auth("test-token")
            .json(&serde_json::json!({
                "kind": "project_rule",
                "scope": "repo",
                "text": text,
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
        memory_ids.push(created["id"].as_str().expect("memory id").to_string());
    }

    let response = client
        .post(format!("{}/v1/memory/maintenance/run", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1",
                "agentId": "agent-1",
                "sessionId": "session-1"
            },
            "enabled": true,
            "mode": "high_confidence_auto",
            "highConfidenceThreshold": 0.90,
            "reviewThreshold": 0.75,
            "preExtractedChangeRequests": [
                {
                    "action": "disable",
                    "targetMemoryIds": [memory_ids[0]],
                    "confidence": 0.95,
                    "reason": "Cleanup should require review."
                },
                {
                    "action": "expire",
                    "targetMemoryIds": [memory_ids[1]],
                    "confidence": 0.96,
                    "reason": "Cleanup should require review."
                }
            ]
        }))
        .send()
        .await
        .expect("run maintenance")
        .json::<serde_json::Value>()
        .await
        .expect("maintenance json");

    assert_eq!(response["autoApplied"], 0);
    assert_eq!(response["needsReview"], 2);
    let requests = response["changeRequests"]
        .as_array()
        .expect("change requests");
    assert!(requests
        .iter()
        .any(|request| request["action"] == "disable" && request["status"] == "pending"));
    assert!(requests
        .iter()
        .any(|request| request["action"] == "expire" && request["status"] == "pending"));

    let listed = client
        .get(format!(
            "{}/v1/memory?userId=local-user&repoId=repo-1&status=active",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("list active")
        .json::<serde_json::Value>()
        .await
        .expect("active json");
    assert_eq!(listed["items"].as_array().expect("items").len(), 2);
}

#[tokio::test]
async fn high_confidence_auto_keeps_cleanup_actions_pending_with_legacy_manual_actions() {
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
            "text": "Legacy cleanup rule should expire.",
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
    let memory_id = created["id"].as_str().expect("memory id");

    let response = client
        .post(format!("{}/v1/memory/maintenance/run", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1",
                "agentId": "agent-1",
                "sessionId": "session-1"
            },
            "enabled": true,
            "mode": "high_confidence_auto",
            "highConfidenceThreshold": 0.90,
            "reviewThreshold": 0.75,
            "manualOnlyActions": ["delete"],
            "preExtractedChangeRequests": [
                {
                    "action": "expire",
                    "targetMemoryIds": [memory_id],
                    "confidence": 0.96,
                    "reason": "Legacy manual actions must not make cleanup automatic."
                }
            ]
        }))
        .send()
        .await
        .expect("run maintenance")
        .json::<serde_json::Value>()
        .await
        .expect("maintenance json");

    assert_eq!(response["autoApplied"], 0);
    assert_eq!(response["needsReview"], 1);
    assert_eq!(response["changeRequests"][0]["action"], "expire");
    assert_eq!(response["changeRequests"][0]["status"], "pending");

    let listed = client
        .get(format!(
            "{}/v1/memory?userId=local-user&repoId=repo-1&status=active",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("list active")
        .json::<serde_json::Value>()
        .await
        .expect("active json");
    assert_eq!(listed["items"].as_array().expect("items").len(), 1);
}

#[tokio::test]
async fn maintenance_run_skips_missing_confidence_even_at_zero_threshold() {
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
            "text": "Use curl for service checks.",
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
    let memory_id = created["id"].as_str().expect("memory id");

    let response = client
        .post(format!("{}/v1/memory/maintenance/run", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1",
                "agentId": "agent-1",
                "sessionId": "session-1"
            },
            "enabled": true,
            "mode": "high_confidence_auto",
            "highConfidenceThreshold": 0.0,
            "reviewThreshold": 0.0,
            "manualOnlyActions": ["delete"],
            "preExtractedChangeRequests": [
                {
                    "action": "update",
                    "targetMemoryIds": [memory_id],
                    "proposedKind": "project_rule",
                    "proposedScope": "repo",
                    "proposedText": "Use curl for all service checks.",
                    "reason": "Missing confidence should not auto-apply."
                }
            ]
        }))
        .send()
        .await
        .expect("run maintenance")
        .json::<serde_json::Value>()
        .await
        .expect("maintenance json");

    assert_eq!(response["autoApplied"], 0);
    assert_eq!(response["needsReview"], 0);
    assert_eq!(response["changeRequests"].as_array().unwrap().len(), 0);

    let listed = client
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
        .expect("memory json");
    assert_eq!(listed["items"][0]["text"], "Use curl for service checks.");
}

#[tokio::test]
async fn maintenance_run_skips_agents_and_tool_use_proposed_text() {
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
            "text": "The project uses Riverpod.",
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
    let memory_id = created["id"].as_str().expect("memory id");

    let response = client
        .post(format!("{}/v1/memory/maintenance/run", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1",
                "agentId": "agent-1",
                "sessionId": "session-1"
            },
            "enabled": true,
            "mode": "high_confidence_auto",
            "highConfidenceThreshold": 0.90,
            "reviewThreshold": 0.75,
            "preExtractedChangeRequests": [
                {
                    "action": "update",
                    "targetMemoryIds": [memory_id],
                    "proposedKind": "project_rule",
                    "proposedScope": "repo",
                    "proposedText": "AGENTS.md 约束：中文回复，严禁使用 nc 或 netcat。",
                    "confidence": 0.96,
                    "reason": "Agent operating rule."
                }
            ]
        }))
        .send()
        .await
        .expect("run maintenance")
        .json::<serde_json::Value>()
        .await
        .expect("maintenance json");

    assert_eq!(response["autoApplied"], 0);
    assert_eq!(response["needsReview"], 0);
    assert_eq!(response["skipped"], 1);

    let listed = client
        .get(format!(
            "{}/v1/memory?userId=local-user&repoId=repo-1&status=active",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("list active")
        .json::<serde_json::Value>()
        .await
        .expect("active json");
    assert_eq!(listed["items"][0]["text"], "The project uses Riverpod.");
}

#[tokio::test]
async fn maintenance_run_applies_llm_suggestions_with_policy_thresholds() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    let mut memory_ids = Vec::new();
    for text in [
        "The user goes by Rod.",
        "The user prefers to be called Rodriguez.",
        "Temporary note about yesterday's blue lighthouse test.",
    ] {
        let created = client
            .post(format!("{}/v1/memory", state.base_url))
            .bearer_auth("test-token")
            .json(&serde_json::json!({
                "kind": "user_preference",
                "scope": "global",
                "text": text,
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
        memory_ids.push(created["id"].as_str().expect("memory id").to_string());
    }

    let response = client
        .post(format!("{}/v1/memory/maintenance/run", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1",
                "agentId": "agent-1",
                "sessionId": "session-1"
            },
            "enabled": true,
            "mode": "high_confidence_auto",
            "highConfidenceThreshold": 0.90,
            "reviewThreshold": 0.75,
            "manualOnlyActions": ["delete"],
            "preExtractedChangeRequests": [
                {
                    "action": "merge",
                    "targetMemoryIds": [memory_ids[0], memory_ids[1]],
                    "proposedKind": "user_preference",
                    "proposedScope": "global",
                    "proposedText": "The user goes by Rodriguez.",
                    "confidence": 0.95,
                    "reason": "The two memories describe the same preferred name."
                },
                {
                    "action": "delete",
                    "targetMemoryIds": [memory_ids[2]],
                    "confidence": 0.99,
                    "reason": "Temporary note is no longer useful."
                }
            ]
        }))
        .send()
        .await
        .expect("run maintenance")
        .json::<serde_json::Value>()
        .await
        .expect("maintenance json");
    assert_eq!(response["autoApplied"], 1);
    assert_eq!(response["needsReview"], 1);

    let listed = client
        .get(format!(
            "{}/v1/memory/change-requests?userId=local-user&repoId=repo-1",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("list change requests")
        .json::<serde_json::Value>()
        .await
        .expect("list json");
    let items = listed["items"].as_array().expect("items");
    assert!(items
        .iter()
        .any(|item| item["action"] == "merge" && item["status"] == "approved"));
    assert!(items
        .iter()
        .any(|item| item["action"] == "delete" && item["status"] == "pending"));
    assert_eq!(
        items
            .iter()
            .filter(|item| item["action"] == "delete" && item["status"] == "pending")
            .count(),
        1
    );

    let audit_pool = memory_core::db::sqlite::open(temp.path())
        .await
        .expect("audit db");
    let auto_approve_count: i64 = sqlx::query_scalar(
        "select count(*) from memory_audit_log where action = 'maintenance.auto_approve'",
    )
    .fetch_one(&audit_pool)
    .await
    .expect("audit count");
    assert_eq!(auto_approve_count, 1);
}

#[tokio::test]
async fn maintenance_run_deduplicates_repeated_llm_suggestions_in_same_batch() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    let mut memory_ids = Vec::new();
    for text in [
        "The user prefers Chinese replies.",
        "The user prefers Chinese replies.",
    ] {
        let created = client
            .post(format!("{}/v1/memory", state.base_url))
            .bearer_auth("test-token")
            .json(&serde_json::json!({
                "kind": "user_preference",
                "scope": "session",
                "text": text,
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
        memory_ids.push(created["id"].as_str().expect("memory id").to_string());
    }

    let duplicate_suggestion = serde_json::json!({
        "action": "merge",
        "targetMemoryIds": [memory_ids[0], memory_ids[1]],
        "proposedKind": "user_preference",
        "proposedScope": "repo",
        "proposedText": "The user prefers Chinese replies.",
        "confidence": 0.95,
        "reason": "The two memories describe the same preference."
    });

    let response = client
        .post(format!("{}/v1/memory/maintenance/run", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1",
                "agentId": "agent-1",
                "sessionId": "session-1"
            },
            "enabled": true,
            "mode": "high_confidence_auto",
            "highConfidenceThreshold": 0.90,
            "reviewThreshold": 0.75,
            "maxItemsPerBatch": 12,
            "preExtractedChangeRequests": [
                duplicate_suggestion,
                duplicate_suggestion
            ]
        }))
        .send()
        .await
        .expect("run maintenance")
        .json::<serde_json::Value>()
        .await
        .expect("maintenance json");

    assert_eq!(response["autoApplied"], 1);
    assert_eq!(response["needsReview"], 0);
    assert_eq!(response["skipped"], 1);
    assert_eq!(response["changeRequests"].as_array().unwrap().len(), 1);

    let active = client
        .get(format!(
            "{}/v1/memory?visible=true&userId=local-user&workspaceId=workspace-1&repoId=repo-1&agentId=agent-1&sessionId=session-1&status=active",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("list active")
        .json::<serde_json::Value>()
        .await
        .expect("active json");
    assert_eq!(active["items"].as_array().expect("items").len(), 1);
}

#[tokio::test]
async fn maintenance_run_enforces_directional_scope_for_llm_merge_suggestions() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    let session_memory = client
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "project_rule",
            "scope": "session",
            "text": "Prefer curl for local health checks.",
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
        .expect("create session memory")
        .json::<serde_json::Value>()
        .await
        .expect("session memory json");
    let global_memory = client
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "project_rule",
            "scope": "global",
            "text": "Prefer curl for local health checks.",
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
        .expect("create global memory")
        .json::<serde_json::Value>()
        .await
        .expect("global memory json");

    let response = client
        .post(format!("{}/v1/memory/maintenance/run", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1",
                "agentId": "agent-1",
                "sessionId": "session-1"
            },
            "enabled": true,
            "mode": "high_confidence_auto",
            "highConfidenceThreshold": 0.90,
            "reviewThreshold": 0.75,
            "preExtractedChangeRequests": [
                {
                    "action": "merge",
                    "targetMemoryIds": [
                        session_memory["id"].as_str().unwrap(),
                        global_memory["id"].as_str().unwrap()
                    ],
                    "proposedKind": "project_rule",
                    "proposedScope": "global",
                    "proposedText": "Prefer curl for local health checks.",
                    "confidence": 0.95,
                    "reason": "The memories describe the same project rule."
                }
            ]
        }))
        .send()
        .await
        .expect("run maintenance")
        .json::<serde_json::Value>()
        .await
        .expect("maintenance json");

    assert_eq!(response["autoApplied"], 1);
    assert_eq!(response["changeRequests"][0]["proposedScope"], "global");
    assert_eq!(response["changeRequests"][0]["status"], "approved");

    let listed = client
        .get(format!(
            "{}/v1/memory?visible=true&userId=local-user&workspaceId=workspace-1&repoId=repo-1&agentId=agent-1&sessionId=session-1&status=active",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("list memory")
        .json::<serde_json::Value>()
        .await
        .expect("memory json");
    let items = listed["items"].as_array().expect("items");
    assert_eq!(items.len(), 1);
    assert_eq!(items[0]["scope"], "global");
}

#[tokio::test]
async fn maintenance_run_enforces_directional_scope_for_update_suggestions() {
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
            "scope": "session",
            "text": "Prefer curl for local health checks.",
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
    let memory_id = memory["id"].as_str().expect("memory id");

    let response = client
        .post(format!("{}/v1/memory/maintenance/run", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1",
                "agentId": "agent-1",
                "sessionId": "session-1"
            },
            "enabled": true,
            "mode": "high_confidence_auto",
            "highConfidenceThreshold": 0.90,
            "reviewThreshold": 0.75,
            "preExtractedChangeRequests": [
                {
                    "action": "update",
                    "targetMemoryIds": [memory_id],
                    "proposedKind": "project_rule",
                    "proposedScope": "global",
                    "proposedText": "Prefer curl and lsof for local health checks.",
                    "confidence": 0.95,
                    "reason": "Refine the service check rule."
                }
            ]
        }))
        .send()
        .await
        .expect("run maintenance")
        .json::<serde_json::Value>()
        .await
        .expect("maintenance json");

    assert_eq!(response["autoApplied"], 1);
    assert_eq!(response["changeRequests"][0]["proposedScope"], "repo");
    assert_eq!(response["changeRequests"][0]["status"], "approved");

    let listed = client
        .get(format!(
            "{}/v1/memory?visible=true&userId=local-user&workspaceId=workspace-1&repoId=repo-1&agentId=agent-1&sessionId=session-1&status=active",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("list memory")
        .json::<serde_json::Value>()
        .await
        .expect("memory json");
    let items = listed["items"].as_array().expect("items");
    assert_eq!(items.len(), 1);
    assert_eq!(items[0]["scope"], "repo");
    assert_eq!(
        items[0]["text"],
        "Prefer curl and lsof for local health checks."
    );
}

#[tokio::test]
async fn maintenance_run_keeps_update_scope_from_downgrading() {
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
            "text": "Prefer curl for local health checks.",
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
    let memory_id = memory["id"].as_str().expect("memory id");

    let response = client
        .post(format!("{}/v1/memory/maintenance/run", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1",
                "agentId": "agent-1",
                "sessionId": "session-1"
            },
            "enabled": true,
            "mode": "high_confidence_auto",
            "highConfidenceThreshold": 0.90,
            "reviewThreshold": 0.75,
            "preExtractedChangeRequests": [
                {
                    "action": "update",
                    "targetMemoryIds": [memory_id],
                    "proposedKind": "project_rule",
                    "proposedScope": "session",
                    "proposedText": "Prefer curl and lsof for local health checks.",
                    "confidence": 0.95,
                    "reason": "Refine the service check rule."
                }
            ]
        }))
        .send()
        .await
        .expect("run maintenance")
        .json::<serde_json::Value>()
        .await
        .expect("maintenance json");

    assert_eq!(response["autoApplied"], 1);
    assert_eq!(response["changeRequests"][0]["proposedScope"], "repo");
    assert_eq!(response["changeRequests"][0]["status"], "approved");

    let listed = client
        .get(format!(
            "{}/v1/memory?visible=true&userId=local-user&workspaceId=workspace-1&repoId=repo-1&agentId=agent-1&sessionId=session-1&status=active",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("list memory")
        .json::<serde_json::Value>()
        .await
        .expect("memory json");
    let items = listed["items"].as_array().expect("items");
    assert_eq!(items.len(), 1);
    assert_eq!(items[0]["scope"], "repo");
    assert_eq!(
        items[0]["text"],
        "Prefer curl and lsof for local health checks."
    );
}

#[tokio::test]
async fn change_request_delete_soft_deletes_and_search_skips_memory() {
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
            "text": "Temporary rule for blue lighthouse checks.",
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
    let memory_id = created["id"].as_str().expect("memory id");

    let request = client
        .post(format!("{}/v1/memory/change-requests", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1"
            },
            "action": "delete",
            "targetMemoryIds": [memory_id],
            "reason": "No longer valid.",
            "confidence": 0.98
        }))
        .send()
        .await
        .expect("create delete request")
        .json::<serde_json::Value>()
        .await
        .expect("delete request json");
    let request_id = request["id"].as_str().expect("request id");

    let approved = client
        .post(format!(
            "{}/v1/memory/change-requests/{request_id}/approve",
            state.base_url
        ))
        .bearer_auth("test-token")
        .json(&serde_json::json!({}))
        .send()
        .await
        .expect("approve delete request")
        .json::<serde_json::Value>()
        .await
        .expect("approve json");
    assert_eq!(approved["status"], "approved");

    let listed_deleted = client
        .get(format!(
            "{}/v1/memory?userId=local-user&repoId=repo-1&status=deleted",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("list deleted")
        .json::<serde_json::Value>()
        .await
        .expect("deleted json");
    assert_eq!(listed_deleted["items"][0]["id"], memory_id);

    let search = client
        .post(format!("{}/v1/memory/search", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "query": "blue lighthouse",
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1",
                "agentId": "agent-1",
                "sessionId": "session-1"
            },
            "limit": 5
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
async fn list_memory_visible_uses_search_scope_rules() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

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
        client
            .post(format!("{}/v1/memory", state.base_url))
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

    let listed = client
        .get(format!(
            "{}/v1/memory?visible=true&userId=local-user&workspaceId=workspace-1&repoId=repo-1&agentId=agent-1&sessionId=session-1&status=active",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("list visible")
        .json::<serde_json::Value>()
        .await
        .expect("visible json");

    let mut texts = listed["items"]
        .as_array()
        .expect("items")
        .iter()
        .map(|item| item["text"].as_str().expect("text").to_string())
        .collect::<Vec<_>>();
    texts.sort();
    assert_eq!(
        texts,
        vec![
            "Global memory from another repo.",
            "Repo memory for this repo.",
            "Session memory for this session.",
            "Workspace memory from another repo.",
        ]
    );
}

#[tokio::test]
async fn change_request_approve_is_idempotent_for_already_approved_request() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    let memory = client
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "user_preference",
            "scope": "global",
            "text": "The user goes by Rod.",
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

    let change_request = client
        .post(format!("{}/v1/memory/change-requests", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1",
                "agentId": "agent-1",
                "sessionId": "session-1"
            },
            "action": "update",
            "targetMemoryIds": [memory["id"].as_str().unwrap()],
            "proposedKind": "user_preference",
            "proposedScope": "global",
            "proposedText": "The user goes by Rodriguez.",
            "confidence": 0.91
        }))
        .send()
        .await
        .expect("create change request")
        .json::<serde_json::Value>()
        .await
        .expect("change request json");
    let id = change_request["id"].as_str().expect("change request id");

    let first = client
        .post(format!(
            "{}/v1/memory/change-requests/{id}/approve",
            state.base_url
        ))
        .bearer_auth("test-token")
        .json(&serde_json::json!({}))
        .send()
        .await
        .expect("first approve")
        .json::<serde_json::Value>()
        .await
        .expect("first approve json");
    assert_eq!(first["status"], "approved");

    let second = client
        .post(format!(
            "{}/v1/memory/change-requests/{id}/approve",
            state.base_url
        ))
        .bearer_auth("test-token")
        .json(&serde_json::json!({}))
        .send()
        .await
        .expect("second approve");
    assert_eq!(second.status(), reqwest::StatusCode::OK);
    let second = second
        .json::<serde_json::Value>()
        .await
        .expect("second approve json");
    assert_eq!(second["status"], "approved");
}

#[tokio::test]
async fn list_candidates_visible_uses_search_scope_rules() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    let cases = [
        (
            "global",
            "Global candidate from another repo.",
            "workspace-2",
            "repo-2",
            "agent-2",
            "session-2",
        ),
        (
            "workspace",
            "Workspace candidate from another repo.",
            "workspace-1",
            "repo-2",
            "agent-2",
            "session-2",
        ),
        (
            "repo",
            "Repo candidate for this repo.",
            "workspace-1",
            "repo-1",
            "agent-2",
            "session-2",
        ),
        (
            "session",
            "Session candidate for this session.",
            "workspace-1",
            "repo-1",
            "agent-1",
            "session-1",
        ),
        (
            "session",
            "Session candidate for another session.",
            "workspace-1",
            "repo-1",
            "agent-1",
            "session-2",
        ),
    ];

    for (scope, text, workspace_id, repo_id, agent_id, session_id) in cases {
        let response = client
            .post(format!("{}/v1/memory/extract-candidates", state.base_url))
            .bearer_auth("test-token")
            .json(&serde_json::json!({
                "scope": {
                    "userId": "local-user",
                    "workspaceId": workspace_id,
                    "repoId": repo_id,
                    "agentId": agent_id,
                    "sessionId": session_id
                },
                "preExtractedCandidates": [
                    {
                        "kind": "project_rule",
                        "scope": scope,
                        "text": text,
                        "confidence": 0.80,
                        "reason": "Test candidate visibility."
                    }
                ]
            }))
            .send()
            .await
            .expect("create candidate");
        assert_eq!(response.status(), reqwest::StatusCode::OK);
    }

    let listed = client
        .get(format!(
            "{}/v1/memory/candidates?visible=true&userId=local-user&workspaceId=workspace-1&repoId=repo-1&agentId=agent-1&sessionId=session-1&status=pending",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("list visible candidates")
        .json::<serde_json::Value>()
        .await
        .expect("visible candidates json");

    let mut texts = listed["items"]
        .as_array()
        .expect("items")
        .iter()
        .map(|item| item["text"].as_str().expect("text").to_string())
        .collect::<Vec<_>>();
    texts.sort();
    assert_eq!(
        texts,
        vec![
            "Global candidate from another repo.",
            "Repo candidate for this repo.",
            "Session candidate for this session.",
            "Workspace candidate from another repo.",
        ]
    );
}

#[tokio::test]
async fn list_change_requests_visible_includes_visible_target_memory() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    let global_memory = client
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "project_rule",
            "scope": "global",
            "text": "Global rule visible from any repo.",
            "scopeData": {
                "userId": "local-user",
                "workspaceId": "workspace-2",
                "repoId": "repo-2",
                "agentId": "agent-2",
                "sessionId": "session-2"
            }
        }))
        .send()
        .await
        .expect("create global memory")
        .json::<serde_json::Value>()
        .await
        .expect("global memory json");
    let other_session_memory = client
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "project_rule",
            "scope": "session",
            "text": "Other session rule should not be visible.",
            "scopeData": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1",
                "agentId": "agent-1",
                "sessionId": "session-2"
            }
        }))
        .send()
        .await
        .expect("create other session memory")
        .json::<serde_json::Value>()
        .await
        .expect("other session memory json");

    client
        .post(format!("{}/v1/memory/change-requests", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-2",
                "repoId": "repo-2",
                "agentId": "agent-2",
                "sessionId": "session-2"
            },
            "action": "delete",
            "targetMemoryIds": [global_memory["id"].as_str().unwrap()],
            "reason": "Clean global memory.",
            "confidence": 0.95
        }))
        .send()
        .await
        .expect("create global delete request");
    client
        .post(format!("{}/v1/memory/change-requests", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1",
                "agentId": "agent-1",
                "sessionId": "session-2"
            },
            "action": "delete",
            "targetMemoryIds": [other_session_memory["id"].as_str().unwrap()],
            "reason": "Clean other session memory.",
            "confidence": 0.95
        }))
        .send()
        .await
        .expect("create other session delete request");

    let listed = client
        .get(format!(
            "{}/v1/memory/change-requests?visible=true&userId=local-user&workspaceId=workspace-1&repoId=repo-1&agentId=agent-1&sessionId=session-1&status=pending",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("list visible change requests")
        .json::<serde_json::Value>()
        .await
        .expect("visible change requests json");

    let items = listed["items"].as_array().expect("items");
    assert_eq!(items.len(), 1);
    assert_eq!(
        items[0]["targetMemoryText"],
        "Global rule visible from any repo."
    );
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
        (
            "project_rule",
            "Use Riverpod providers for shared Flutter state.",
        ),
        ("architecture_decision", "Rust only owns memory."),
    ]);
    assert!(formatted.contains("<agent_memory_context>"));
    assert!(formatted.contains("current instruction wins"));
    assert!(formatted.contains("[project_rule] Use Riverpod providers for shared Flutter state."));
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
