use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};
use std::{env, io::Read};

use axum::routing::post;
use axum::{Json, Router};
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
    assert!(tables.contains(&"memory_episodes".to_string()));
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
    assert_eq!(
        serde_json::to_string(&MemoryKind::TaskEpisode).unwrap(),
        "\"task_episode\""
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

#[tokio::test]
async fn task_episode_requires_structure_and_search_limits_few_shot_examples() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();
    let scope = serde_json::json!({
        "userId": "local-user",
        "workspaceId": "workspace-1",
        "repoId": "repo-1",
        "agentId": "agent-1",
        "sessionId": "session-1"
    });

    let invalid = client
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "task_episode",
            "scope": "repo",
            "text": "Release validation succeeded with make verify.",
            "scopeData": scope
        }))
        .send()
        .await
        .expect("invalid episode");
    assert_eq!(invalid.status(), reqwest::StatusCode::BAD_REQUEST);

    for index in 1..=3 {
        client
            .post(format!("{}/v1/memory", state.base_url))
            .bearer_auth("test-token")
            .json(&serde_json::json!({
                "kind": "task_episode",
                "scope": "repo",
                "text": format!(
                    "Release validation episode {index} used make verify and cargo test."
                ),
                "scopeData": scope,
                "pinned": true,
                "episode": {
                    "goal": format!("Validate release candidate {index}"),
                    "constraints": ["Do not skip repository checks"],
                    "toolsUsed": ["make verify", "cargo test"],
                    "mistake": "Running only the narrow test missed integration failures.",
                    "successfulPattern": "Run focused tests, then make verify, then inspect the final diff."
                }
            }))
            .send()
            .await
            .expect("create episode")
            .error_for_status()
            .expect("create episode status");
    }
    client
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "project_rule",
            "scope": "repo",
            "text": "Release validation must run make verify and cargo test.",
            "scopeData": scope
        }))
        .send()
        .await
        .expect("create rule")
        .error_for_status()
        .expect("create rule status");

    let searched = client
        .post(format!("{}/v1/memory/search", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "query": "How should release validation run make verify and cargo test?",
            "scope": scope,
            "limit": 10,
            "turnId": "turn-episode"
        }))
        .send()
        .await
        .expect("search")
        .error_for_status()
        .expect("search status")
        .json::<serde_json::Value>()
        .await
        .expect("search json");
    let items = searched["items"].as_array().expect("items");
    let episodes = items
        .iter()
        .filter(|item| item["kind"] == "task_episode")
        .collect::<Vec<_>>();
    assert_eq!(episodes.len(), 2);
    assert!(items.iter().any(|item| item["kind"] == "project_rule"));
    assert!(episodes[0]["text"]
        .as_str()
        .expect("episode text")
        .contains("Successful pattern:"));
    assert_eq!(
        episodes[0]["metadata"]["episode"]["toolsUsed"][0],
        "make verify"
    );
    assert_eq!(episodes[0]["metadata"]["diagnostics"]["pinnedLayer"], false);

    let pool = memory_core::db::sqlite::open(temp.path())
        .await
        .expect("db");
    let episode_count: i64 = sqlx::query_scalar("select count(*) from memory_episodes")
        .fetch_one(&pool)
        .await
        .expect("episode count");
    assert_eq!(episode_count, 3);
    let pinned_count: i64 = sqlx::query_scalar(
        "select count(*) from memory_items where kind = 'task_episode' and pinned = 1",
    )
    .fetch_one(&pool)
    .await
    .expect("pinned count");
    assert_eq!(pinned_count, 0);
}

#[tokio::test]
async fn reviewed_task_episode_candidate_preserves_structured_experience() {
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
            "source": "extractor",
            "preExtractedCandidates": [{
                "kind": "task_episode",
                "scope": "repo",
                "text": "A reusable release validation sequence succeeded.",
                "confidence": 0.96,
                "pinned": true,
                "episode": {
                    "goal": "Validate a release candidate",
                    "constraints": ["Keep all repository checks enabled"],
                    "toolsUsed": ["cargo test", "make verify"],
                    "mistake": "A narrow test missed an integration failure.",
                    "successfulPattern": "Run focused tests, then the full verify target."
                }
            }]
        }))
        .send()
        .await
        .expect("extract")
        .error_for_status()
        .expect("extract status")
        .json::<serde_json::Value>()
        .await
        .expect("extract json");
    let candidate = &extracted["candidates"][0];
    assert_eq!(candidate["kind"], "task_episode");
    assert_eq!(
        candidate["episode"]["successfulPattern"],
        "Run focused tests, then the full verify target."
    );
    let candidate_id = candidate["id"].as_str().expect("candidate id");

    let approved = client
        .post(format!(
            "{}/v1/memory/candidates/{candidate_id}/approve",
            state.base_url
        ))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "task_episode",
            "scope": "repo",
            "text": "A reusable release validation sequence succeeded."
        }))
        .send()
        .await
        .expect("approve")
        .error_for_status()
        .expect("approve status")
        .json::<serde_json::Value>()
        .await
        .expect("approve json");
    assert_eq!(approved["kind"], "task_episode");
    assert_eq!(approved["pinned"], false);

    let pool = memory_core::db::sqlite::open(temp.path())
        .await
        .expect("db");
    let pattern: String =
        sqlx::query_scalar("select successful_pattern from memory_episodes where memory_id = ?")
            .bind(approved["id"].as_str().expect("memory id"))
            .fetch_one(&pool)
            .await
            .expect("episode pattern");
    assert_eq!(pattern, "Run focused tests, then the full verify target.");
}

#[tokio::test]
async fn memory_export_returns_filtered_jsonl_with_entities_and_temporal_metadata() {
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
            "text": "Run make verify before merging this repository.",
            "scopeData": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1"
            },
            "entities": [
                {"text": "make verify", "type": "command"}
            ],
            "observedAt": 1700000000000_i64,
            "validFrom": 1700000001000_i64,
            "pinned": true
        }))
        .send()
        .await
        .expect("create repo memory")
        .error_for_status()
        .expect("create repo status");
    client
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "user_preference",
            "scope": "global",
            "text": "Prefer concise answers.",
            "scopeData": {"userId": "local-user"}
        }))
        .send()
        .await
        .expect("create global memory")
        .error_for_status()
        .expect("create global status");

    let exported = client
        .post(format!("{}/v1/memory/export", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "scopeData": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1"
            },
            "memoryScope": "repo",
            "kind": "project_rule",
            "status": "active",
            "createdFrom": 0_i64,
            "createdUntil": i64::MAX
        }))
        .send()
        .await
        .expect("export")
        .error_for_status()
        .expect("export status")
        .json::<serde_json::Value>()
        .await
        .expect("export json");

    assert_eq!(exported["exported"], 1);
    assert_eq!(exported["truncated"], false);
    let lines = exported["jsonl"]
        .as_str()
        .expect("jsonl")
        .lines()
        .collect::<Vec<_>>();
    assert_eq!(lines.len(), 1);
    let record: serde_json::Value = serde_json::from_str(lines[0]).expect("record");
    assert_eq!(record["version"], 1);
    assert_eq!(record["type"], "memory");
    assert_eq!(record["kind"], "project_rule");
    assert_eq!(record["scope"], "repo");
    assert_eq!(record["scopeData"]["repoId"], "repo-1");
    assert_eq!(record["observedAt"], 1700000000000_i64);
    assert_eq!(record["validFrom"], 1700000001000_i64);
    assert_eq!(record["pinned"], true);
    assert_eq!(record["entities"][0]["text"], "make verify");
    assert_eq!(record["entities"][0]["type"], "command");
}

#[tokio::test]
async fn pending_jsonl_import_creates_review_candidates_and_skips_history() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();
    let active = serde_json::json!({
        "version": 1,
        "type": "memory",
        "originalId": "mem_backup_active",
        "kind": "project_rule",
        "scope": "repo",
        "text": "Use curl for service health checks in this repository.",
        "scopeData": {
            "userId": "local-user",
            "workspaceId": "workspace-1",
            "repoId": "repo-1"
        },
        "source": "manual",
        "entities": [{"text": "curl", "type": "tool"}],
        "status": "active"
    });
    let disabled = serde_json::json!({
        "version": 1,
        "type": "memory",
        "originalId": "mem_backup_disabled",
        "kind": "user_preference",
        "scope": "global",
        "text": "This old preference should remain disabled.",
        "scopeData": {"userId": "local-user"},
        "status": "disabled"
    });
    let jsonl = format!("{active}\n{disabled}\n");

    let imported = client
        .post(format!("{}/v1/memory/import", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "jsonl": jsonl,
            "mode": "pending_review"
        }))
        .send()
        .await
        .expect("import")
        .error_for_status()
        .expect("import status")
        .json::<serde_json::Value>()
        .await
        .expect("import json");
    assert_eq!(imported["imported"], 0);
    assert_eq!(imported["pendingReview"], 1);
    assert_eq!(imported["skipped"], 1);
    assert_eq!(imported["errors"].as_array().expect("errors").len(), 1);

    let candidates = client
        .get(format!(
            "{}/v1/memory/candidates?userId=local-user&repoId=repo-1&status=pending",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("candidate list")
        .error_for_status()
        .expect("candidate status")
        .json::<serde_json::Value>()
        .await
        .expect("candidate json");
    let candidates = candidates["candidates"].as_array().expect("candidates");
    assert_eq!(candidates.len(), 1);
    assert_eq!(candidates[0]["source"], "import");
    assert_eq!(candidates[0]["text"], active["text"]);

    let pool = memory_core::db::sqlite::open(temp.path())
        .await
        .expect("db");
    let entities_json: String =
        sqlx::query_scalar("select entities_json from memory_candidates limit 1")
            .fetch_one(&pool)
            .await
            .expect("entities json");
    assert!(entities_json.contains("curl"));
    let audit_count: i64 = sqlx::query_scalar(
        "select count(*) from memory_audit_log
         where actor = 'import' and action = 'candidate.create'",
    )
    .fetch_one(&pool)
    .await
    .expect("audit count");
    assert_eq!(audit_count, 1);
}

#[tokio::test]
async fn trusted_jsonl_import_restores_history_and_supersede_links_idempotently() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();
    let old = serde_json::json!({
        "version": 1,
        "type": "memory",
        "originalId": "mem_old",
        "kind": "project_rule",
        "scope": "repo",
        "text": "Run the legacy test command before release.",
        "scopeData": {
            "userId": "local-user",
            "workspaceId": "workspace-1",
            "repoId": "repo-1"
        },
        "source": "manual",
        "validUntil": 1700000002000_i64,
        "status": "disabled",
        "createdAt": 1700000000000_i64,
        "updatedAt": 1700000002000_i64
    });
    let current = serde_json::json!({
        "version": 1,
        "type": "memory",
        "originalId": "mem_current",
        "kind": "project_rule",
        "scope": "repo",
        "text": "Run make verify before release.",
        "scopeData": {
            "userId": "local-user",
            "workspaceId": "workspace-1",
            "repoId": "repo-1"
        },
        "source": "maintenance",
        "entities": [{"text": "make verify", "type": "command"}],
        "validFrom": 1700000002000_i64,
        "supersedesOriginalId": "mem_old",
        "pinned": true,
        "status": "active",
        "createdAt": 1700000002000_i64,
        "updatedAt": 1700000003000_i64
    });
    let episode = serde_json::json!({
        "version": 1,
        "type": "memory",
        "originalId": "mem_episode",
        "kind": "task_episode",
        "scope": "repo",
        "text": "Release validation succeeded with the full verification sequence.",
        "scopeData": {
            "userId": "local-user",
            "workspaceId": "workspace-1",
            "repoId": "repo-1"
        },
        "source": "extractor",
        "episode": {
            "goal": "Validate a release candidate",
            "constraints": ["Keep full checks enabled"],
            "toolsUsed": ["make verify"],
            "mistake": "The narrow test missed integration coverage.",
            "successfulPattern": "Run focused checks, then make verify."
        },
        "status": "active",
        "createdAt": 1700000003000_i64,
        "updatedAt": 1700000004000_i64
    });
    let jsonl = format!("{old}\n{current}\n{episode}\n");

    let import_once = client
        .post(format!("{}/v1/memory/import", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({"jsonl": jsonl, "mode": "trusted"}))
        .send()
        .await
        .expect("trusted import")
        .error_for_status()
        .expect("trusted import status")
        .json::<serde_json::Value>()
        .await
        .expect("trusted import json");
    assert_eq!(import_once["imported"], 3);
    assert_eq!(import_once["pendingReview"], 0);
    assert_eq!(import_once["skipped"], 0);

    let pool = memory_core::db::sqlite::open(temp.path())
        .await
        .expect("db");
    let old_row: (String, String, i64) =
        sqlx::query_as("select id, status, pinned from memory_items where text = ?")
            .bind("Run the legacy test command before release.")
            .fetch_one(&pool)
            .await
            .expect("old row");
    let current_row: (String, String, Option<String>, i64, String) = sqlx::query_as(
        "select id, status, supersedes_memory_id, pinned, source
         from memory_items where text = ?",
    )
    .bind("Run make verify before release.")
    .fetch_one(&pool)
    .await
    .expect("current row");
    assert_eq!(old_row.1, "disabled");
    assert_eq!(old_row.2, 0);
    assert_eq!(current_row.1, "active");
    assert_eq!(current_row.2.as_deref(), Some(old_row.0.as_str()));
    assert_eq!(current_row.3, 1);
    assert_eq!(current_row.4, "import");
    let entity_count: i64 =
        sqlx::query_scalar("select count(*) from memory_entities where memory_id = ?")
            .bind(&current_row.0)
            .fetch_one(&pool)
            .await
            .expect("entity count");
    assert_eq!(entity_count, 1);
    let episode_pattern: String = sqlx::query_scalar(
        "select successful_pattern from memory_episodes
         where memory_id = (
           select id from memory_items where kind = 'task_episode' limit 1
         )",
    )
    .fetch_one(&pool)
    .await
    .expect("episode pattern");
    assert_eq!(episode_pattern, "Run focused checks, then make verify.");
    let episode_export = client
        .post(format!("{}/v1/memory/export", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "scopeData": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1"
            },
            "kind": "task_episode"
        }))
        .send()
        .await
        .expect("episode export")
        .error_for_status()
        .expect("episode export status")
        .json::<serde_json::Value>()
        .await
        .expect("episode export json");
    let episode_line = episode_export["jsonl"]
        .as_str()
        .expect("episode jsonl")
        .lines()
        .next()
        .expect("episode line");
    let episode_record: serde_json::Value =
        serde_json::from_str(episode_line).expect("episode record");
    assert_eq!(
        episode_record["episode"]["successfulPattern"],
        "Run focused checks, then make verify."
    );

    let import_twice = client
        .post(format!("{}/v1/memory/import", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({"jsonl": jsonl, "mode": "trusted_import"}))
        .send()
        .await
        .expect("second trusted import")
        .error_for_status()
        .expect("second trusted import status")
        .json::<serde_json::Value>()
        .await
        .expect("second trusted import json");
    assert_eq!(import_twice["imported"], 0);
    assert_eq!(import_twice["skipped"], 3);
}

#[tokio::test]
async fn patch_memory_to_disabled_writes_disable_audit() {
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
            "text": "Use curl for local service checks.",
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
    let id = created["id"].as_str().expect("id");

    let disabled = client
        .patch(format!("{}/v1/memory/{id}", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({ "status": "disabled" }))
        .send()
        .await
        .expect("disable")
        .json::<serde_json::Value>()
        .await
        .expect("disable json");
    assert_eq!(disabled["status"], "disabled");

    let audit_pool = memory_core::db::sqlite::open(temp.path())
        .await
        .expect("audit db");
    let disable_audit_count: i64 = sqlx::query_scalar(
        "select count(*) from memory_audit_log
         where memory_id = ? and action = 'memory.disable'",
    )
    .bind(id)
    .fetch_one(&audit_pool)
    .await
    .expect("disable audit count");
    assert_eq!(disable_audit_count, 1);
}

#[tokio::test]
async fn patch_memory_from_disabled_to_active_writes_restore_audit() {
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
            "text": "Use curl for local service checks.",
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
    let id = created["id"].as_str().expect("id");

    client
        .patch(format!("{}/v1/memory/{id}", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({ "status": "disabled" }))
        .send()
        .await
        .expect("disable");

    let restored = client
        .patch(format!("{}/v1/memory/{id}", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({ "status": "active" }))
        .send()
        .await
        .expect("restore")
        .json::<serde_json::Value>()
        .await
        .expect("restore json");
    assert_eq!(restored["status"], "active");

    let audit_pool = memory_core::db::sqlite::open(temp.path())
        .await
        .expect("audit db");
    let restore_audit_count: i64 = sqlx::query_scalar(
        "select count(*) from memory_audit_log
         where memory_id = ? and action = 'memory.restore'",
    )
    .bind(id)
    .fetch_one(&audit_pool)
    .await
    .expect("restore audit count");
    assert_eq!(restore_audit_count, 1);
}

#[tokio::test]
async fn list_memory_filters_full_scope_kind_and_paginates() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    #[allow(clippy::too_many_arguments)]
    async fn create_memory(
        client: &reqwest::Client,
        base_url: &str,
        text: &str,
        kind: &str,
        scope: &str,
        workspace_id: &str,
        repo_id: &str,
        agent_id: &str,
        session_id: &str,
    ) {
        client
            .post(format!("{base_url}/v1/memory"))
            .bearer_auth("test-token")
            .json(&serde_json::json!({
                "kind": kind,
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
            .expect("create memory")
            .error_for_status()
            .expect("create status");
    }

    create_memory(
        &client,
        &state.base_url,
        "Older scoped project rule.",
        "project_rule",
        "repo",
        "workspace-a",
        "repo-a",
        "agent-a",
        "session-a",
    )
    .await;
    tokio::time::sleep(Duration::from_millis(2)).await;
    create_memory(
        &client,
        &state.base_url,
        "Newer scoped project rule.",
        "project_rule",
        "repo",
        "workspace-a",
        "repo-a",
        "agent-a",
        "session-a",
    )
    .await;
    create_memory(
        &client,
        &state.base_url,
        "Wrong kind preference.",
        "user_preference",
        "repo",
        "workspace-a",
        "repo-a",
        "agent-a",
        "session-a",
    )
    .await;
    create_memory(
        &client,
        &state.base_url,
        "Wrong workspace rule.",
        "project_rule",
        "repo",
        "workspace-b",
        "repo-a",
        "agent-a",
        "session-a",
    )
    .await;
    create_memory(
        &client,
        &state.base_url,
        "Wrong session rule.",
        "project_rule",
        "session",
        "workspace-a",
        "repo-a",
        "agent-a",
        "session-b",
    )
    .await;

    let first_page = client
        .get(format!(
            "{}/v1/memory?userId=local-user&workspaceId=workspace-a&repoId=repo-a&agentId=agent-a&sessionId=session-a&kind=project_rule&status=active&limit=1",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("list memory")
        .json::<serde_json::Value>()
        .await
        .expect("list json");
    let first_items = first_page["items"].as_array().expect("first items");
    assert_eq!(first_items.len(), 1);
    assert_eq!(first_items[0]["text"], "Newer scoped project rule.");
    assert_eq!(first_items[0]["pinned"], false);

    let second_page = client
        .get(format!(
            "{}/v1/memory?userId=local-user&workspaceId=workspace-a&repoId=repo-a&agentId=agent-a&sessionId=session-a&kind=project_rule&status=active&limit=1&offset=1",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("list memory page")
        .json::<serde_json::Value>()
        .await
        .expect("list page json");
    let second_items = second_page["items"].as_array().expect("second items");
    assert_eq!(second_items.len(), 1);
    assert_eq!(second_items[0]["text"], "Older scoped project rule.");
}

#[tokio::test]
async fn list_memory_includes_profile_block_for_pinned_memory() {
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
            "text": "The verification phrase is blue lighthouse.",
            "pinned": true,
            "scopeData": {
                "userId": "local-user",
                "workspaceId": "workspace-a",
                "repoId": "repo-a",
                "agentId": "agent-a",
                "sessionId": "session-a"
            }
        }))
        .send()
        .await
        .expect("create memory")
        .error_for_status()
        .expect("create status");

    let listed = client
        .get(format!(
            "{}/v1/memory?userId=local-user&workspaceId=workspace-a&repoId=repo-a&agentId=agent-a&sessionId=session-a&status=active",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("list memory")
        .json::<serde_json::Value>()
        .await
        .expect("list json");

    let item = &listed["items"].as_array().expect("items")[0];
    assert_eq!(item["pinned"], true);
    assert_eq!(item["profileBlock"]["label"], "project_profile");
    assert_eq!(
        item["profileBlock"]["description"],
        "Stable project rules and architecture decisions."
    );
    assert_eq!(item["profileBlock"]["limit"], 4);
}

#[tokio::test]
async fn list_memory_uses_memory_semantic_scope_for_current_context() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    #[allow(clippy::too_many_arguments)]
    async fn create_memory(
        client: &reqwest::Client,
        base_url: &str,
        text: &str,
        scope: &str,
        workspace_id: Option<&str>,
        repo_id: Option<&str>,
        agent_id: Option<&str>,
        session_id: Option<&str>,
    ) {
        client
            .post(format!("{base_url}/v1/memory"))
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
            .expect("create memory")
            .error_for_status()
            .expect("create status");
    }

    create_memory(
        &client,
        &state.base_url,
        "Global rule visible everywhere.",
        "global",
        None,
        None,
        None,
        None,
    )
    .await;
    create_memory(
        &client,
        &state.base_url,
        "Workspace rule visible in workspace.",
        "workspace",
        Some("workspace-a"),
        None,
        None,
        None,
    )
    .await;
    create_memory(
        &client,
        &state.base_url,
        "Repo rule visible across sessions.",
        "repo",
        Some("workspace-a"),
        Some("repo-a"),
        Some("agent-a"),
        Some("session-b"),
    )
    .await;
    create_memory(
        &client,
        &state.base_url,
        "Current session rule.",
        "session",
        Some("workspace-a"),
        Some("repo-a"),
        Some("agent-a"),
        Some("session-a"),
    )
    .await;
    create_memory(
        &client,
        &state.base_url,
        "Other session rule.",
        "session",
        Some("workspace-a"),
        Some("repo-a"),
        Some("agent-a"),
        Some("session-b"),
    )
    .await;
    create_memory(
        &client,
        &state.base_url,
        "Other workspace rule.",
        "workspace",
        Some("workspace-b"),
        None,
        None,
        None,
    )
    .await;

    let listed = client
        .get(format!(
            "{}/v1/memory?userId=local-user&workspaceId=workspace-a&repoId=repo-a&agentId=agent-a&sessionId=session-a&kind=project_rule&status=active",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("list memory")
        .json::<serde_json::Value>()
        .await
        .expect("list json");
    let texts = listed["items"]
        .as_array()
        .expect("items")
        .iter()
        .map(|item| item["text"].as_str().unwrap())
        .collect::<Vec<_>>();

    assert_eq!(texts.len(), 4);
    assert!(texts.contains(&"Global rule visible everywhere."));
    assert!(texts.contains(&"Workspace rule visible in workspace."));
    assert!(texts.contains(&"Repo rule visible across sessions."));
    assert!(texts.contains(&"Current session rule."));
    assert!(!texts.contains(&"Other session rule."));
    assert!(!texts.contains(&"Other workspace rule."));
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
            "source": "mcp",
            "sourceTurnId": "turn-candidate-1",
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
                    "kind": "user_preference",
                    "scope": "global",
                    "text": "User prefers concise Chinese replies.",
                    "confidence": 0.91,
                    "reason": "User directly stated a communication preference."
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
    assert_eq!(candidates["candidates"].as_array().unwrap().len(), 2);
    let candidate_id = candidates["candidates"][0]["id"].as_str().unwrap();
    let rejected_candidate_id = candidates["candidates"][1]["id"].as_str().unwrap();

    let listed = client
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
    assert_eq!(listed["candidates"].as_array().unwrap().len(), 2);

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
    assert_eq!(approved["source"], "mcp");
    assert_eq!(approved["sourceSessionId"], "session-1");
    assert_eq!(approved["sourceTurnId"], "turn-candidate-1");

    let search = client
        .post(format!("{}/v1/memory/search", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "query": "netcat repo rule",
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
    assert_eq!(
        search["items"][0]["metadata"]["sourceTurnId"],
        "turn-candidate-1"
    );

    let rejected = client
        .post(format!(
            "{}/v1/memory/candidates/{rejected_candidate_id}/reject",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("reject");
    assert_eq!(rejected.status(), reqwest::StatusCode::OK);

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
async fn candidate_auto_approval_records_requested_audit_actor() {
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
                    "kind": "user_preference",
                    "scope": "global",
                    "text": "The user goes by Rodriguez.",
                    "confidence": 0.96,
                    "reason": "User explicitly asked to remember this."
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

    client
        .post(format!(
            "{}/v1/memory/candidates/{candidate_id}/approve",
            state.base_url
        ))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "user_preference",
            "scope": "global",
            "text": "The user goes by Rodriguez.",
            "actor": "extractor"
        }))
        .send()
        .await
        .expect("approve")
        .error_for_status()
        .expect("approve status");

    let audit_pool = memory_core::db::sqlite::open(temp.path())
        .await
        .expect("audit db");
    let actor: String = sqlx::query_scalar(
        "select actor from memory_audit_log
         where candidate_id = ? and action = 'candidate.approve'",
    )
    .bind(candidate_id)
    .fetch_one(&audit_pool)
    .await
    .expect("candidate approve actor");
    assert_eq!(actor, "extractor");
}

#[tokio::test]
async fn candidate_extraction_skips_existing_and_in_batch_duplicates() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    client
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "user_preference",
            "scope": "global",
            "text": "User prefers concise Chinese replies.",
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
                    "kind": "user_preference",
                    "scope": "global",
                    "text": " user   prefers concise chinese replies ",
                    "confidence": 0.96,
                    "reason": "Extractor repeated an existing preference."
                },
                {
                    "kind": "project_rule",
                    "scope": "repo",
                    "text": "Use curl for service health checks.",
                    "confidence": 0.92,
                    "reason": "Durable repo rule."
                },
                {
                    "kind": "project_rule",
                    "scope": "repo",
                    "text": "Use curl for service health checks.",
                    "confidence": 0.91,
                    "reason": "Same rule extracted twice."
                }
            ]
        }))
        .send()
        .await
        .expect("extract")
        .json::<serde_json::Value>()
        .await
        .expect("extract json");

    let created = candidates["candidates"].as_array().expect("candidates");
    assert_eq!(created.len(), 1);
    assert_eq!(created[0]["text"], "Use curl for service health checks.");

    let listed = client
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
    assert_eq!(listed["candidates"].as_array().unwrap().len(), 1);

    let pool = memory_core::db::sqlite::open(temp.path())
        .await
        .expect("audit db");
    let skipped_count: i64 = sqlx::query_scalar(
        "select count(*) from memory_audit_log where action = 'candidate.skip_duplicate'",
    )
    .fetch_one(&pool)
    .await
    .expect("skip count");
    assert_eq!(skipped_count, 2);
}

#[tokio::test]
async fn candidate_extraction_skips_semantically_visible_duplicates() {
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
            "text": "Use curl for service health checks.",
            "scopeData": {
                "userId": "local-user"
            }
        }))
        .send()
        .await
        .expect("create broad repo memory")
        .error_for_status()
        .expect("create broad repo status");

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
                    "text": "Use curl for service health checks.",
                    "confidence": 0.92,
                    "reason": "Extractor repeated a visible repo rule."
                }
            ]
        }))
        .send()
        .await
        .expect("extract")
        .json::<serde_json::Value>()
        .await
        .expect("extract json");

    assert!(candidates["candidates"]
        .as_array()
        .expect("candidates")
        .is_empty());

    let pool = memory_core::db::sqlite::open(temp.path())
        .await
        .expect("audit db");
    let skipped_count: i64 = sqlx::query_scalar(
        "select count(*) from memory_audit_log where action = 'candidate.skip_duplicate'",
    )
    .fetch_one(&pool)
    .await
    .expect("skip count");
    assert_eq!(skipped_count, 1);
}

#[tokio::test]
async fn high_confidence_candidate_supersedes_conflicting_active_memory() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    let old = client
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "project_rule",
            "scope": "repo",
            "text": "The project verification phrase is red bridge.",
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
        .expect("create old memory")
        .json::<serde_json::Value>()
        .await
        .expect("old memory json");
    let old_id = old["id"].as_str().expect("old memory id");

    let extracted = client
        .post(format!("{}/v1/memory/extract-candidates", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "source": "mcp",
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
                    "text": "The project verification phrase is blue lighthouse.",
                    "confidence": 0.94,
                    "reason": "User corrected the durable project verification phrase."
                }
            ]
        }))
        .send()
        .await
        .expect("extract conflict")
        .json::<serde_json::Value>()
        .await
        .expect("extract json");
    assert_eq!(extracted["candidates"].as_array().unwrap().len(), 0);
    assert_eq!(extracted["autoAppliedChangeRequests"], 1);

    let search = client
        .post(format!("{}/v1/memory/search", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "query": "project verification phrase",
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1",
                "agentId": "agent-1",
                "sessionId": "session-1"
            },
            "limit": 2
        }))
        .send()
        .await
        .expect("search")
        .json::<serde_json::Value>()
        .await
        .expect("search json");
    assert_eq!(
        search["items"][0]["text"],
        "The project verification phrase is blue lighthouse."
    );
    assert_eq!(search["items"][1]["id"], old_id);
    assert!(
        search["items"][1]["metadata"]["diagnostics"]["temporalScore"]
            .as_f64()
            .unwrap()
            < 1.0
    );

    let pending_candidates = client
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
        .expect("candidate list json");
    assert_eq!(
        pending_candidates["candidates"].as_array().unwrap().len(),
        0
    );

    let pool = memory_core::db::sqlite::open(temp.path())
        .await
        .expect("db");
    let auto_supersede_count: i64 = sqlx::query_scalar(
        "select count(*) from memory_audit_log where action = 'candidate.auto_supersede'",
    )
    .fetch_one(&pool)
    .await
    .expect("auto supersede audit count");
    assert_eq!(auto_supersede_count, 1);
    let auto_supersede_actor: String = sqlx::query_scalar(
        "select actor from memory_audit_log
         where action = 'candidate.auto_supersede'
         order by created_at desc
         limit 1",
    )
    .fetch_one(&pool)
    .await
    .expect("auto supersede actor");
    assert_eq!(auto_supersede_actor, "mcp");
    let change_request_source: String = sqlx::query_scalar(
        "select source from memory_change_requests
         where action = 'supersede'
         order by created_at desc
         limit 1",
    )
    .fetch_one(&pool)
    .await
    .expect("change request source");
    assert_eq!(change_request_source, "mcp");
    let superseding_memory_source: String = sqlx::query_scalar(
        "select source from memory_items
         where text = 'The project verification phrase is blue lighthouse.'
         order by created_at desc
         limit 1",
    )
    .fetch_one(&pool)
    .await
    .expect("superseding memory source");
    assert_eq!(superseding_memory_source, "mcp");
}

#[tokio::test]
async fn high_confidence_candidates_chain_supersede_with_single_current_fact() {
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
            "text": "The project verification phrase is red bridge.",
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
        .expect("create old memory")
        .error_for_status()
        .expect("create old memory status");

    let extracted = client
        .post(format!("{}/v1/memory/extract-candidates", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "source": "extractor",
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
                    "text": "The project verification phrase is blue lighthouse.",
                    "confidence": 0.94,
                    "reason": "User corrected the durable project verification phrase."
                },
                {
                    "kind": "project_rule",
                    "scope": "repo",
                    "text": "The project verification phrase is green tower.",
                    "confidence": 0.95,
                    "reason": "User corrected the durable project verification phrase again."
                }
            ]
        }))
        .send()
        .await
        .expect("extract conflict chain")
        .json::<serde_json::Value>()
        .await
        .expect("extract json");
    assert_eq!(extracted["candidates"].as_array().unwrap().len(), 0);
    assert_eq!(extracted["autoAppliedChangeRequests"], 2);

    let pool = memory_core::db::sqlite::open(temp.path())
        .await
        .expect("db");
    let current_texts = sqlx::query_scalar::<_, String>(
        "select text from memory_items
         where status = 'active'
           and kind = 'project_rule'
           and scope = 'repo'
           and valid_until is null
         order by created_at asc",
    )
    .fetch_all(&pool)
    .await
    .expect("current memories");
    assert_eq!(
        current_texts,
        vec!["The project verification phrase is green tower.".to_string()]
    );
}

#[tokio::test]
async fn high_confidence_candidate_supersedes_newest_current_conflicting_memory() {
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
            "text": "The project verification phrase is red bridge.",
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
        .expect("create older current memory")
        .error_for_status()
        .expect("older current memory status");

    tokio::time::sleep(Duration::from_millis(2)).await;

    let newest = client
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "project_rule",
            "scope": "repo",
            "text": "The project verification phrase is blue lighthouse.",
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
        .expect("create newest current memory")
        .json::<serde_json::Value>()
        .await
        .expect("newest current memory json");
    let newest_id = newest["id"].as_str().expect("newest id");

    let extracted = client
        .post(format!("{}/v1/memory/extract-candidates", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "source": "extractor",
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
                    "text": "The project verification phrase is green tower.",
                    "confidence": 0.95,
                    "reason": "User corrected the durable project verification phrase again."
                }
            ]
        }))
        .send()
        .await
        .expect("extract conflict")
        .json::<serde_json::Value>()
        .await
        .expect("extract json");
    assert_eq!(extracted["autoAppliedChangeRequests"], 1);

    let pool = memory_core::db::sqlite::open(temp.path())
        .await
        .expect("db");
    let newest_valid_until: Option<i64> =
        sqlx::query_scalar("select valid_until from memory_items where id = ?")
            .bind(newest_id)
            .fetch_one(&pool)
            .await
            .expect("newest valid until");
    assert!(newest_valid_until.is_some());

    let current_supersedes: String = sqlx::query_scalar(
        "select supersedes_memory_id from memory_items
         where text = 'The project verification phrase is green tower.'
         order by created_at desc
         limit 1",
    )
    .fetch_one(&pool)
    .await
    .expect("current supersedes id");
    assert_eq!(current_supersedes, newest_id);
}

#[tokio::test]
async fn candidate_instruction_scopes_round_trip_through_storage() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    let created = client
        .post(format!("{}/v1/memory/extract-candidates", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "source": "mcp",
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
                    "text": "Never use nc/netcat in this repo.",
                    "confidence": 0.95,
                    "reason": "Matches configured memory rules.",
                    "instructionScopes": ["repo", "workspace"]
                }
            ]
        }))
        .send()
        .await
        .expect("extract")
        .json::<serde_json::Value>()
        .await
        .expect("extract json");

    let created_candidates = created["candidates"]
        .as_array()
        .expect("created candidates");
    assert_eq!(created_candidates.len(), 1);
    assert_eq!(
        created_candidates[0]["instructionScopes"],
        serde_json::json!(["repo", "workspace"])
    );
    assert_eq!(created_candidates[0]["source"], "mcp");

    let listed = client
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
    let listed_candidates = listed["candidates"].as_array().expect("listed candidates");
    assert_eq!(listed_candidates.len(), 1);
    assert_eq!(
        listed_candidates[0]["instructionScopes"],
        serde_json::json!(["repo", "workspace"])
    );
    assert_eq!(listed_candidates[0]["source"], "mcp");
}

#[tokio::test]
async fn list_candidates_filters_workspace_and_limits() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    #[allow(clippy::too_many_arguments)]
    async fn create_candidate(
        client: &reqwest::Client,
        base_url: &str,
        workspace_id: &str,
        repo_id: &str,
        text: &str,
    ) {
        client
            .post(format!("{base_url}/v1/memory/extract-candidates"))
            .bearer_auth("test-token")
            .json(&serde_json::json!({
                "scope": {
                    "userId": "local-user",
                    "workspaceId": workspace_id,
                    "repoId": repo_id,
                    "agentId": "agent-1",
                    "sessionId": "session-1"
                },
                "preExtractedCandidates": [
                    {
                        "kind": "project_rule",
                        "scope": "repo",
                        "text": text,
                        "confidence": 0.95,
                        "reason": "Durable repo rule."
                    }
                ]
            }))
            .send()
            .await
            .expect("create candidate")
            .error_for_status()
            .expect("candidate status");
    }

    create_candidate(
        &client,
        &state.base_url,
        "workspace-a",
        "repo-a",
        "Use curl for service checks.",
    )
    .await;
    create_candidate(
        &client,
        &state.base_url,
        "workspace-b",
        "repo-a",
        "Use lsof for local ports.",
    )
    .await;

    let listed = client
        .get(format!(
            "{}/v1/memory/candidates?userId=local-user&workspaceId=workspace-a&repoId=repo-a&status=pending&limit=1",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("list candidates")
        .json::<serde_json::Value>()
        .await
        .expect("list candidates json");
    let candidates = listed["candidates"].as_array().expect("candidates");
    assert_eq!(candidates.len(), 1);
    assert_eq!(candidates[0]["text"], "Use curl for service checks.");
}

#[tokio::test]
async fn list_candidates_filters_by_candidate_semantic_scope() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    #[allow(clippy::too_many_arguments)]
    async fn create_candidate(
        client: &reqwest::Client,
        base_url: &str,
        workspace_id: &str,
        repo_id: &str,
        agent_id: &str,
        session_id: &str,
        kind: &str,
        scope: &str,
        text: &str,
    ) {
        client
            .post(format!("{base_url}/v1/memory/extract-candidates"))
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
                        "kind": kind,
                        "scope": scope,
                        "text": text,
                        "confidence": 0.94,
                        "reason": "Scoped candidate for review filtering."
                    }
                ]
            }))
            .send()
            .await
            .expect("create candidate");
    }

    create_candidate(
        &client,
        &state.base_url,
        "workspace-b",
        "repo-b",
        "agent-b",
        "session-b",
        "user_preference",
        "global",
        "User prefers concise Chinese replies.",
    )
    .await;
    create_candidate(
        &client,
        &state.base_url,
        "workspace-b",
        "repo-1",
        "agent-a",
        "session-a",
        "project_rule",
        "workspace",
        "Workspace B requires verbose traces.",
    )
    .await;
    create_candidate(
        &client,
        &state.base_url,
        "workspace-a",
        "repo-1",
        "agent-a",
        "session-b",
        "project_rule",
        "repo",
        "Repo 1 requires structured logs.",
    )
    .await;
    create_candidate(
        &client,
        &state.base_url,
        "workspace-a",
        "repo-1",
        "agent-a",
        "session-a",
        "session_summary",
        "session",
        "Session A discussed memory review.",
    )
    .await;
    create_candidate(
        &client,
        &state.base_url,
        "workspace-a",
        "repo-1",
        "agent-a",
        "session-b",
        "session_summary",
        "session",
        "Session B discussed unrelated setup.",
    )
    .await;

    let listed = client
        .get(format!(
            "{}/v1/memory/candidates?userId=local-user&workspaceId=workspace-a&repoId=repo-1&agentId=agent-a&sessionId=session-a&status=pending",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("list candidates")
        .json::<serde_json::Value>()
        .await
        .expect("list candidates json");
    let texts = listed["candidates"]
        .as_array()
        .expect("candidates")
        .iter()
        .map(|candidate| candidate["text"].as_str().unwrap())
        .collect::<Vec<_>>();

    assert_eq!(texts.len(), 3);
    assert!(texts.contains(&"User prefers concise Chinese replies."));
    assert!(texts.contains(&"Repo 1 requires structured logs."));
    assert!(texts.contains(&"Session A discussed memory review."));
    assert!(!texts.contains(&"Workspace B requires verbose traces."));
    assert!(!texts.contains(&"Session B discussed unrelated setup."));
}

#[tokio::test]
async fn change_request_approve_update_and_reject_are_audited() {
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

    let request = client
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
            "proposedText": "The user goes by Rodriguez.",
            "reason": "Clarify the user's preferred name.",
            "confidence": 0.82
        }))
        .send()
        .await
        .expect("create change request")
        .json::<serde_json::Value>()
        .await
        .expect("create change request json");
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
        .expect("list change requests json");
    assert_eq!(listed["items"].as_array().unwrap().len(), 1);

    let patched = client
        .patch(format!(
            "{}/v1/memory/change-requests/{request_id}",
            state.base_url
        ))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "proposedText": "Call the user Rodriguez."
        }))
        .send()
        .await
        .expect("patch change request")
        .json::<serde_json::Value>()
        .await
        .expect("patch change request json");
    assert_eq!(patched["proposedText"], "Call the user Rodriguez.");

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
        .expect("approve change request json");
    assert_eq!(approved["status"], "approved");

    let memory = client
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
    assert_eq!(memory["items"][0]["text"], "Call the user Rodriguez.");

    let audit = client
        .get(format!(
            "{}/v1/memory/audit?userId=local-user&repoId=repo-1",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("audit list")
        .json::<serde_json::Value>()
        .await
        .expect("audit json");
    let audit_items = audit["items"].as_array().expect("audit items");
    assert!(audit_items
        .iter()
        .any(|item| item["action"] == "change_request.update"));
    assert!(audit_items
        .iter()
        .any(|item| item["action"] == "change_request.approve"));
}

#[tokio::test]
async fn maintenance_run_auto_approves_existing_high_confidence_change_request() {
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

    let request = client
        .post(format!("{}/v1/memory/change-requests", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1"
            },
            "action": "update",
            "source": "mcp",
            "targetMemoryIds": [memory_id],
            "proposedKind": "project_rule",
            "proposedScope": "repo",
            "proposedText": "Use curl for service health checks.",
            "reason": "Clarifies the existing service-check rule.",
            "confidence": 0.94
        }))
        .send()
        .await
        .expect("create change request")
        .json::<serde_json::Value>()
        .await
        .expect("change request json");
    let request_id = request["id"].as_str().expect("request id");

    let result = client
        .post(format!("{}/v1/memory/maintenance/run", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "mode": "high_confidence_auto",
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1"
            },
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
    assert_eq!(result["autoApplied"], 1);
    assert_eq!(result["existingAutoApprovedChangeRequests"], 1);

    let requests = client
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
    assert!(requests["items"].as_array().unwrap().is_empty());

    let memory = client
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
        memory["items"][0]["text"],
        "Use curl for service health checks."
    );

    let pool = memory_core::db::sqlite::open(temp.path())
        .await
        .expect("audit db");
    let actor: String = sqlx::query_scalar(
        "select actor from memory_audit_log
         where change_request_id = ? and action = 'change_request.approve'",
    )
    .bind(request_id)
    .fetch_one(&pool)
    .await
    .expect("change request approve audit");
    assert_eq!(actor, "maintenance");

    let run_payload_json: String = sqlx::query_scalar(
        "select payload_json from memory_audit_log
         where action = 'maintenance.run'
         order by created_at desc
         limit 1",
    )
    .fetch_one(&pool)
    .await
    .expect("maintenance run audit");
    let run_payload: serde_json::Value =
        serde_json::from_str(&run_payload_json).expect("maintenance payload json");
    assert_eq!(run_payload["existingAutoApprovedChangeRequests"], 1);
}

#[tokio::test]
async fn maintenance_run_auto_rejects_change_request_already_covered_by_active_memory() {
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
            "text": "Use curl for service health checks.",
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

    let request = client
        .post(format!("{}/v1/memory/change-requests", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1"
            },
            "action": "update",
            "source": "mcp",
            "targetMemoryIds": [memory_id],
            "proposedKind": "project_rule",
            "proposedScope": "repo",
            "proposedText": " use CURL for service health checks ",
            "reason": "Clarifies an already current rule.",
            "confidence": 0.94
        }))
        .send()
        .await
        .expect("create change request")
        .json::<serde_json::Value>()
        .await
        .expect("change request json");
    let request_id = request["id"].as_str().expect("request id");

    let result = client
        .post(format!("{}/v1/memory/maintenance/run", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "mode": "high_confidence_auto",
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1"
            },
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
    assert_eq!(result["autoApplied"], 0);
    assert_eq!(result["autoRejectedChangeRequests"], 1);

    let rejected = client
        .get(format!(
            "{}/v1/memory/change-requests?userId=local-user&repoId=repo-1&status=rejected",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("list rejected change requests")
        .json::<serde_json::Value>()
        .await
        .expect("rejected change requests json");
    assert_eq!(rejected["items"][0]["id"], request_id);

    let pool = memory_core::db::sqlite::open(temp.path())
        .await
        .expect("audit db");
    let audit: (String, String, String) = sqlx::query_as(
        "select actor, action, memory_id from memory_audit_log
         where change_request_id = ?
         order by created_at desc
         limit 1",
    )
    .bind(request_id)
    .fetch_one(&pool)
    .await
    .expect("auto reject audit");
    assert_eq!(audit.0, "maintenance");
    assert_eq!(audit.1, "change_request.auto_reject_duplicate");
    assert_eq!(audit.2, memory_id);
}

#[tokio::test]
async fn maintenance_run_auto_rejects_merge_request_already_covered_by_active_memory() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    let covered = client
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "user_preference",
            "scope": "repo",
            "text": "The user goes by Rodriguez.",
            "scopeData": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1"
            }
        }))
        .send()
        .await
        .expect("create covered memory")
        .json::<serde_json::Value>()
        .await
        .expect("covered memory json");
    let covered_id = covered["id"].as_str().expect("covered memory id");

    let target = client
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "project_rule",
            "scope": "repo",
            "text": "Temporary note for memory review cleanup.",
            "scopeData": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1"
            }
        }))
        .send()
        .await
        .expect("create target memory")
        .json::<serde_json::Value>()
        .await
        .expect("target memory json");
    let target_id = target["id"].as_str().expect("target memory id");

    let request = client
        .post(format!("{}/v1/memory/change-requests", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1"
            },
            "action": "merge",
            "source": "maintenance",
            "targetMemoryIds": [target_id],
            "proposedKind": "user_preference",
            "proposedScope": "repo",
            "proposedText": " the user goes by Rodriguez ",
            "reason": "Merge output is already represented by an active memory.",
            "confidence": 0.82
        }))
        .send()
        .await
        .expect("create change request")
        .json::<serde_json::Value>()
        .await
        .expect("change request json");
    let request_id = request["id"].as_str().expect("request id");

    let result = client
        .post(format!("{}/v1/memory/maintenance/run", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "mode": "high_confidence_auto",
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1"
            },
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
    assert_eq!(result["autoApplied"], 0);
    assert_eq!(result["autoRejectedChangeRequests"], 1);

    let rejected = client
        .get(format!(
            "{}/v1/memory/change-requests?userId=local-user&repoId=repo-1&status=rejected",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("list rejected change requests")
        .json::<serde_json::Value>()
        .await
        .expect("rejected change requests json");
    assert_eq!(rejected["items"][0]["id"], request_id);

    let pool = memory_core::db::sqlite::open(temp.path())
        .await
        .expect("audit db");
    let audit: (String, String, String) = sqlx::query_as(
        "select actor, action, memory_id from memory_audit_log
         where change_request_id = ?
         order by created_at desc
         limit 1",
    )
    .bind(request_id)
    .fetch_one(&pool)
    .await
    .expect("auto reject audit");
    assert_eq!(audit.0, "maintenance");
    assert_eq!(audit.1, "change_request.auto_reject_duplicate");
    assert_eq!(audit.2, covered_id);
}

#[tokio::test]
async fn maintenance_run_reuses_existing_memory_for_high_confidence_merge_request() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    let existing = client
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "user_preference",
            "scope": "global",
            "text": "The user goes by Rodriguez.",
            "scopeData": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1"
            }
        }))
        .send()
        .await
        .expect("create existing memory")
        .json::<serde_json::Value>()
        .await
        .expect("existing memory json");
    let existing_id = existing["id"].as_str().expect("existing memory id");

    let mut target_ids = Vec::new();
    for text in [
        "The user name is Rod.",
        "User prefers the short name Rodriguez.",
    ] {
        let target = client
            .post(format!("{}/v1/memory", state.base_url))
            .bearer_auth("test-token")
            .json(&serde_json::json!({
                "kind": "user_preference",
                "scope": "global",
                "text": text,
                "scopeData": {
                    "userId": "local-user",
                    "workspaceId": "workspace-1",
                    "repoId": "repo-1"
                }
            }))
            .send()
            .await
            .expect("create target memory")
            .json::<serde_json::Value>()
            .await
            .expect("target memory json");
        target_ids.push(target["id"].as_str().expect("target memory id").to_string());
    }

    let request = client
        .post(format!("{}/v1/memory/change-requests", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1"
            },
            "action": "merge",
            "source": "maintenance",
            "targetMemoryIds": target_ids,
            "proposedKind": "user_preference",
            "proposedScope": "global",
            "proposedText": " the user goes by Rodriguez ",
            "reason": "Merge output is already represented by an active memory.",
            "confidence": 0.94
        }))
        .send()
        .await
        .expect("create change request")
        .json::<serde_json::Value>()
        .await
        .expect("change request json");
    let request_id = request["id"].as_str().expect("request id");

    let result = client
        .post(format!("{}/v1/memory/maintenance/run", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "mode": "high_confidence_auto",
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1"
            },
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
    assert_eq!(result["autoApplied"], 1);
    assert_eq!(result["autoRejectedChangeRequests"], 0);
    assert_eq!(result["changeRequests"][0]["id"], request_id);
    assert_eq!(result["changeRequests"][0]["status"], "approved");

    let active = client
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
    let items = active["items"].as_array().expect("active items");
    assert_eq!(items.len(), 1);
    assert_eq!(items[0]["id"], existing_id);
}

#[tokio::test]
async fn maintenance_run_auto_rejects_change_request_for_deleted_target() {
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

    let request = client
        .post(format!("{}/v1/memory/change-requests", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1"
            },
            "action": "update",
            "source": "mcp",
            "targetMemoryIds": [memory_id],
            "proposedKind": "project_rule",
            "proposedScope": "repo",
            "proposedText": "Use curl for service health checks.",
            "reason": "Clarifies the existing service-check rule.",
            "confidence": 0.94
        }))
        .send()
        .await
        .expect("create change request")
        .json::<serde_json::Value>()
        .await
        .expect("change request json");
    let request_id = request["id"].as_str().expect("request id");

    client
        .delete(format!("{}/v1/memory/{memory_id}", state.base_url))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("delete memory")
        .error_for_status()
        .expect("delete memory status");

    let result = client
        .post(format!("{}/v1/memory/maintenance/run", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "mode": "high_confidence_auto",
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1"
            },
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
    assert_eq!(result["autoApplied"], 0);
    assert_eq!(result["autoRejectedCandidates"], 0);
    assert_eq!(result["autoRejectedChangeRequests"], 1);

    let active = client
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
    assert!(active["items"].as_array().unwrap().is_empty());

    let rejected = client
        .get(format!(
            "{}/v1/memory/change-requests?userId=local-user&repoId=repo-1&status=rejected",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("list rejected change requests")
        .json::<serde_json::Value>()
        .await
        .expect("rejected change requests json");
    assert_eq!(rejected["items"][0]["id"], request_id);

    let pool = memory_core::db::sqlite::open(temp.path())
        .await
        .expect("audit db");
    let audit: (String, String) = sqlx::query_as(
        "select actor, action from memory_audit_log
         where change_request_id = ?
         order by created_at desc
         limit 1",
    )
    .bind(request_id)
    .fetch_one(&pool)
    .await
    .expect("auto reject audit");
    assert_eq!(audit.0, "maintenance");
    assert_eq!(audit.1, "change_request.auto_reject_obsolete");
}

#[tokio::test]
async fn duplicate_pending_change_request_is_reused() {
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

    let body = serde_json::json!({
        "scope": {
            "userId": "local-user",
            "workspaceId": "workspace-1",
            "repoId": "repo-1"
        },
        "action": "update",
        "targetMemoryIds": [memory_id],
        "proposedKind": "user_preference",
        "proposedScope": "global",
        "proposedText": "The user goes by Rodriguez.",
        "reason": "Clarify the user's preferred name.",
        "confidence": 0.82
    });
    let first = client
        .post(format!("{}/v1/memory/change-requests", state.base_url))
        .bearer_auth("test-token")
        .json(&body)
        .send()
        .await
        .expect("create first change request")
        .json::<serde_json::Value>()
        .await
        .expect("first change request json");
    let second = client
        .post(format!("{}/v1/memory/change-requests", state.base_url))
        .bearer_auth("test-token")
        .json(&body)
        .send()
        .await
        .expect("create duplicate change request")
        .json::<serde_json::Value>()
        .await
        .expect("duplicate change request json");
    assert_eq!(second["id"], first["id"]);

    let listed = client
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
    assert_eq!(listed["items"].as_array().unwrap().len(), 1);

    let audit = client
        .get(format!(
            "{}/v1/memory/audit?userId=local-user&repoId=repo-1",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("audit list")
        .json::<serde_json::Value>()
        .await
        .expect("audit json");
    assert!(audit["items"]
        .as_array()
        .expect("audit items")
        .iter()
        .any(|item| item["action"] == "change_request.skip_duplicate"));
}

#[tokio::test]
async fn duplicate_pending_change_request_is_reused_across_semantic_scope() {
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
            "text": "Use curl for service health checks.",
            "scopeData": {
                "userId": "local-user"
            }
        }))
        .send()
        .await
        .expect("create memory")
        .json::<serde_json::Value>()
        .await
        .expect("create memory json");
    let memory_id = created["id"].as_str().expect("memory id");

    let broad = client
        .post(format!("{}/v1/memory/change-requests", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "scope": {
                "userId": "local-user"
            },
            "action": "update",
            "targetMemoryIds": [memory_id],
            "proposedKind": "project_rule",
            "proposedScope": "repo",
            "proposedText": "Use curl for service health checks and readiness probes.",
            "reason": "Clarify the durable repo rule.",
            "confidence": 0.82
        }))
        .send()
        .await
        .expect("create broad change request")
        .json::<serde_json::Value>()
        .await
        .expect("broad change request json");

    let scoped = client
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
            "proposedKind": "project_rule",
            "proposedScope": "repo",
            "proposedText": "Use curl for service health checks and readiness probes.",
            "reason": "Same request from a concrete session.",
            "confidence": 0.82
        }))
        .send()
        .await
        .expect("create scoped change request")
        .json::<serde_json::Value>()
        .await
        .expect("scoped change request json");

    assert_eq!(scoped["id"], broad["id"]);

    let listed = client
        .get(format!(
            "{}/v1/memory/change-requests?userId=local-user&workspaceId=workspace-1&repoId=repo-1&agentId=agent-1&sessionId=session-1&status=pending",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("list pending change requests")
        .json::<serde_json::Value>()
        .await
        .expect("pending change requests json");
    assert_eq!(listed["items"].as_array().unwrap().len(), 1);

    let pool = memory_core::db::sqlite::open(temp.path())
        .await
        .expect("audit db");
    let skipped_count: i64 = sqlx::query_scalar(
        "select count(*) from memory_audit_log where action = 'change_request.skip_duplicate'",
    )
    .fetch_one(&pool)
    .await
    .expect("skip duplicate count");
    assert_eq!(skipped_count, 1);
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
            "text": "Temporary rule to delete.",
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
            "reason": "User requested cleanup.",
            "confidence": 0.99
        }))
        .send()
        .await
        .expect("create delete request")
        .json::<serde_json::Value>()
        .await
        .expect("create delete request json");
    let request_id = request["id"].as_str().expect("request id");

    client
        .post(format!(
            "{}/v1/memory/change-requests/{request_id}/approve",
            state.base_url
        ))
        .bearer_auth("test-token")
        .json(&serde_json::json!({}))
        .send()
        .await
        .expect("approve delete request");

    let search = client
        .post(format!("{}/v1/memory/search", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "query": "Temporary rule",
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1"
            }
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
async fn list_change_requests_filters_workspace_agent_and_session() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    async fn create_memory(
        client: &reqwest::Client,
        base_url: &str,
        workspace_id: &str,
        agent_id: &str,
        session_id: &str,
        text: &str,
    ) -> String {
        let created = client
            .post(format!("{base_url}/v1/memory"))
            .bearer_auth("test-token")
            .json(&serde_json::json!({
                "kind": "project_rule",
                "scope": "repo",
                "text": text,
                "scopeData": {
                    "userId": "local-user",
                    "workspaceId": workspace_id,
                    "repoId": "repo-1",
                    "agentId": agent_id,
                    "sessionId": session_id
                }
            }))
            .send()
            .await
            .expect("create memory")
            .json::<serde_json::Value>()
            .await
            .expect("memory json");
        created["id"].as_str().expect("memory id").to_string()
    }

    async fn create_change_request(
        client: &reqwest::Client,
        base_url: &str,
        memory_id: &str,
        workspace_id: &str,
        agent_id: &str,
        session_id: &str,
        proposed_text: &str,
    ) {
        client
            .post(format!("{base_url}/v1/memory/change-requests"))
            .bearer_auth("test-token")
            .json(&serde_json::json!({
                "scope": {
                    "userId": "local-user",
                    "workspaceId": workspace_id,
                    "repoId": "repo-1",
                    "agentId": agent_id,
                    "sessionId": session_id
                },
                "action": "update",
                "targetMemoryIds": [memory_id],
                "proposedKind": "project_rule",
                "proposedScope": "repo",
                "proposedText": proposed_text,
                "confidence": 0.82
            }))
            .send()
            .await
            .expect("create change request");
    }

    let current_memory_id = create_memory(
        &client,
        &state.base_url,
        "workspace-a",
        "agent-a",
        "session-a",
        "The verification phrase is red bridge.",
    )
    .await;
    let other_workspace_memory_id = create_memory(
        &client,
        &state.base_url,
        "workspace-b",
        "agent-a",
        "session-a",
        "The verification phrase is orange bridge.",
    )
    .await;
    let other_agent_memory_id = create_memory(
        &client,
        &state.base_url,
        "workspace-a",
        "agent-b",
        "session-a",
        "The verification phrase is green bridge.",
    )
    .await;
    let other_session_memory_id = create_memory(
        &client,
        &state.base_url,
        "workspace-a",
        "agent-a",
        "session-b",
        "The verification phrase is yellow bridge.",
    )
    .await;

    create_change_request(
        &client,
        &state.base_url,
        &current_memory_id,
        "workspace-a",
        "agent-a",
        "session-a",
        "The verification phrase is blue lighthouse.",
    )
    .await;
    create_change_request(
        &client,
        &state.base_url,
        &other_workspace_memory_id,
        "workspace-b",
        "agent-a",
        "session-a",
        "The verification phrase is blue lighthouse for workspace B.",
    )
    .await;
    create_change_request(
        &client,
        &state.base_url,
        &other_agent_memory_id,
        "workspace-a",
        "agent-b",
        "session-a",
        "The verification phrase is blue lighthouse for agent B.",
    )
    .await;
    create_change_request(
        &client,
        &state.base_url,
        &other_session_memory_id,
        "workspace-a",
        "agent-a",
        "session-b",
        "The verification phrase is blue lighthouse for session B.",
    )
    .await;

    let listed = client
        .get(format!(
            "{}/v1/memory/change-requests?userId=local-user&workspaceId=workspace-a&repoId=repo-1&agentId=agent-a&sessionId=session-a&status=pending",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("list change requests")
        .json::<serde_json::Value>()
        .await
        .expect("list change requests json");

    let items = listed["items"].as_array().expect("items");
    assert_eq!(items.len(), 1);
    assert_eq!(
        items[0]["proposedText"],
        "The verification phrase is blue lighthouse."
    );
}

#[tokio::test]
async fn list_change_requests_includes_broader_scope_for_current_session() {
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
            "text": "The verification phrase is red bridge.",
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
    let memory_id = created["id"].as_str().expect("memory id");

    client
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
            "proposedKind": "project_rule",
            "proposedScope": "repo",
            "proposedText": "The verification phrase is blue lighthouse.",
            "confidence": 0.82
        }))
        .send()
        .await
        .expect("create change request");

    let listed = client
        .get(format!(
            "{}/v1/memory/change-requests?userId=local-user&workspaceId=workspace-1&repoId=repo-1&agentId=agent-1&sessionId=session-1&status=pending",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("list change requests")
        .json::<serde_json::Value>()
        .await
        .expect("list change requests json");

    let items = listed["items"].as_array().expect("items");
    assert_eq!(items.len(), 1);
    assert_eq!(
        items[0]["proposedText"],
        "The verification phrase is blue lighthouse."
    );
}

#[tokio::test]
async fn change_request_supersede_creates_temporal_chain_and_search_prefers_current_fact() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    let old = client
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "project_rule",
            "scope": "repo",
            "text": "The project verification phrase is red bridge.",
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
        .expect("create old memory")
        .json::<serde_json::Value>()
        .await
        .expect("old memory json");
    let old_id = old["id"].as_str().expect("old memory id");

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
            "action": "supersede",
            "targetMemoryIds": [old_id],
            "proposedKind": "project_rule",
            "proposedScope": "repo",
            "proposedText": "The project verification phrase is blue lighthouse.",
            "reason": "The verification phrase changed.",
            "confidence": 0.91
        }))
        .send()
        .await
        .expect("create supersede request")
        .json::<serde_json::Value>()
        .await
        .expect("supersede request json");
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
        .expect("approve supersede request");
    assert_eq!(approved.status(), reqwest::StatusCode::OK);

    let pool = memory_core::db::sqlite::open(temp.path())
        .await
        .expect("db");
    let old_valid_until: i64 =
        sqlx::query_scalar("select valid_until from memory_items where id = ?")
            .bind(old_id)
            .fetch_one(&pool)
            .await
            .expect("old valid until");
    let new_row = sqlx::query_as::<_, (String, i64, String)>(
        "select id, valid_from, supersedes_memory_id
         from memory_items
         where supersedes_memory_id = ? and status = 'active'",
    )
    .bind(old_id)
    .fetch_one(&pool)
    .await
    .expect("new superseding memory");
    assert!(new_row.1 >= old_valid_until);
    assert_eq!(new_row.2, old_id);

    let current_search = client
        .post(format!("{}/v1/memory/search", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "query": "project verification phrase",
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1",
                "agentId": "agent-1",
                "sessionId": "session-1"
            },
            "referenceTime": old_valid_until + 1,
            "limit": 2
        }))
        .send()
        .await
        .expect("current search")
        .json::<serde_json::Value>()
        .await
        .expect("current search json");
    assert_eq!(current_search["items"][0]["id"], new_row.0);
    assert_eq!(current_search["items"][1]["id"], old_id);
    assert!(
        current_search["items"][1]["metadata"]["diagnostics"]["temporalScore"]
            .as_f64()
            .unwrap()
            < 1.0
    );

    let audit_count: i64 = sqlx::query_scalar(
        "select count(*) from memory_audit_log where action = 'memory.supersede' and memory_id = ?",
    )
    .bind(&new_row.0)
    .fetch_one(&pool)
    .await
    .expect("supersede audit count");
    assert_eq!(audit_count, 1);
}

#[tokio::test]
async fn change_request_supersede_reuses_existing_active_memory_matching_proposed_text() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    let old = client
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
        .expect("create old memory")
        .json::<serde_json::Value>()
        .await
        .expect("old memory json");
    let old_id = old["id"].as_str().expect("old memory id");

    let existing_current = client
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "user_preference",
            "scope": "global",
            "text": "The user goes by Rodriguez.",
            "scopeData": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1"
            }
        }))
        .send()
        .await
        .expect("create current memory")
        .json::<serde_json::Value>()
        .await
        .expect("current memory json");
    let existing_current_id = existing_current["id"].as_str().expect("current memory id");

    let request = client
        .post(format!("{}/v1/memory/change-requests", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1"
            },
            "action": "supersede",
            "targetMemoryIds": [old_id],
            "proposedKind": "user_preference",
            "proposedScope": "global",
            "proposedText": " The user goes by Rodriguez. ",
            "reason": "The user corrected their preferred name.",
            "confidence": 0.91
        }))
        .send()
        .await
        .expect("create supersede request")
        .json::<serde_json::Value>()
        .await
        .expect("supersede request json");
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
        .expect("approve supersede request");
    assert_eq!(approved.status(), reqwest::StatusCode::OK);

    let pool = memory_core::db::sqlite::open(temp.path())
        .await
        .expect("db");
    let old_valid_until: Option<i64> =
        sqlx::query_scalar("select valid_until from memory_items where id = ?")
            .bind(old_id)
            .fetch_one(&pool)
            .await
            .expect("old valid until");
    assert!(old_valid_until.is_some());

    let current_supersedes: Option<String> =
        sqlx::query_scalar("select supersedes_memory_id from memory_items where id = ?")
            .bind(existing_current_id)
            .fetch_one(&pool)
            .await
            .expect("current supersedes");
    assert_eq!(current_supersedes.as_deref(), Some(old_id));

    let duplicate_current_count: i64 = sqlx::query_scalar(
        "select count(*) from memory_items
         where status = 'active'
           and user_id = 'local-user'
           and kind = 'user_preference'
           and scope = 'global'
           and text = 'The user goes by Rodriguez.'",
    )
    .fetch_one(&pool)
    .await
    .expect("duplicate current count");
    assert_eq!(duplicate_current_count, 1);

    let supersede_audit_count: i64 = sqlx::query_scalar(
        "select count(*) from memory_audit_log
         where action = 'memory.supersede' and memory_id = ?",
    )
    .bind(existing_current_id)
    .fetch_one(&pool)
    .await
    .expect("supersede audit count");
    assert_eq!(supersede_audit_count, 1);
}

#[tokio::test]
async fn clear_repo_soft_deletes_memory_and_pending_reviews() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    let repo_1 = client
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "project_rule",
            "scope": "repo",
            "text": "Repo one memory.",
            "scopeData": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1"
            }
        }))
        .send()
        .await
        .expect("create repo 1")
        .json::<serde_json::Value>()
        .await
        .expect("repo 1 json");
    let repo_1_id = repo_1["id"].as_str().expect("repo 1 id");
    client
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "project_rule",
            "scope": "repo",
            "text": "Repo two memory.",
            "scopeData": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-2"
            }
        }))
        .send()
        .await
        .expect("create repo 2");
    client
        .post(format!("{}/v1/memory/extract-candidates", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1"
            },
            "preExtractedCandidates": [{
                "kind": "project_rule",
                "scope": "repo",
                "text": "Pending repo one candidate.",
                "confidence": 0.9
            }]
        }))
        .send()
        .await
        .expect("create candidate");
    client
        .post(format!("{}/v1/memory/change-requests", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1"
            },
            "action": "update",
            "targetMemoryIds": [repo_1_id],
            "proposedText": "Updated repo one memory.",
            "reason": "Test pending review."
        }))
        .send()
        .await
        .expect("create change request");

    let clear = client
        .post(format!("{}/v1/memory/clear", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "level": "repo",
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1"
            }
        }))
        .send()
        .await
        .expect("clear")
        .json::<serde_json::Value>()
        .await
        .expect("clear json");
    assert_eq!(clear["clearedMemory"], 1);
    assert_eq!(clear["rejectedCandidates"], 1);
    assert_eq!(clear["rejectedChangeRequests"], 1);

    let repo_1_active = client
        .get(format!(
            "{}/v1/memory?userId=local-user&repoId=repo-1&status=active",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("repo 1 memory")
        .json::<serde_json::Value>()
        .await
        .expect("repo 1 memory json");
    assert!(repo_1_active["items"].as_array().unwrap().is_empty());

    let repo_2_active = client
        .get(format!(
            "{}/v1/memory?userId=local-user&repoId=repo-2&status=active",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("repo 2 memory")
        .json::<serde_json::Value>()
        .await
        .expect("repo 2 memory json");
    assert_eq!(repo_2_active["items"].as_array().unwrap().len(), 1);

    let audit = client
        .get(format!(
            "{}/v1/memory/audit?userId=local-user&repoId=repo-1",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("audit")
        .json::<serde_json::Value>()
        .await
        .expect("audit json");
    assert!(audit["items"]
        .as_array()
        .unwrap()
        .iter()
        .any(|item| item["action"] == "memory.clear"));
}

#[tokio::test]
async fn destroy_database_requires_confirmation_and_deletes_memory_data() {
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
            "text": "Data that will be destroyed.",
            "scopeData": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1"
            }
        }))
        .send()
        .await
        .expect("create memory");

    let rejected = client
        .post(format!("{}/v1/memory/destroy-database", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({"confirm": "no"}))
        .send()
        .await
        .expect("destroy without confirm");
    assert_eq!(rejected.status(), reqwest::StatusCode::BAD_REQUEST);

    let destroyed = client
        .post(format!("{}/v1/memory/destroy-database", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({"confirm": "DESTROY MEMORY DATABASE"}))
        .send()
        .await
        .expect("destroy")
        .json::<serde_json::Value>()
        .await
        .expect("destroy json");
    assert_eq!(destroyed["destroyedMemory"], 1);

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
    assert!(listed["items"].as_array().unwrap().is_empty());
}

#[tokio::test]
async fn maintenance_run_merges_duplicate_memory_without_auto_deleting() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    for text in [
        "The user goes by Rodriguez.",
        "User prefers to be called Rodriguez.",
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
                    "repoId": "repo-1"
                }
            }))
            .send()
            .await
            .expect("create memory");
    }

    let result = client
        .post(format!("{}/v1/memory/maintenance/run", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "mode": " High-Confidence-Auto ",
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1"
            },
            "highConfidenceThreshold": 0.90,
            "reviewThreshold": 0.75,
            "maxItemsPerBatch": 12
        }))
        .send()
        .await
        .expect("run maintenance")
        .json::<serde_json::Value>()
        .await
        .expect("run maintenance json");
    assert_eq!(result["autoApplied"], 1);
    assert_eq!(result["needsReview"], 0);

    let memory = client
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
    let items = memory["items"].as_array().expect("memory items");
    assert_eq!(items.len(), 1);
    assert!(items[0]["text"].as_str().unwrap().contains("Rodriguez"));
    assert_eq!(items[0]["pinned"], true);

    let search = client
        .post(format!("{}/v1/memory/search", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "query": "完全不相关的问题",
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1",
                "agentId": "agent-1",
                "sessionId": "session-1"
            },
            "limit": 4,
            "pinnedProfileLimit": 4
        }))
        .send()
        .await
        .expect("search merged profile memory")
        .json::<serde_json::Value>()
        .await
        .expect("search merged profile memory json");
    assert_eq!(search["items"][0]["id"], items[0]["id"]);
    assert_eq!(search["items"][0]["metadata"]["pinned"], true);
    assert_eq!(
        search["items"][0]["metadata"]["diagnostics"]["pinnedLayer"],
        true
    );

    let pool = memory_core::db::sqlite::open(temp.path())
        .await
        .expect("db");
    let approval_actor: String = sqlx::query_scalar(
        "select actor from memory_audit_log
         where action = 'change_request.approve'
         order by created_at desc
         limit 1",
    )
    .fetch_one(&pool)
    .await
    .expect("change request approve actor");
    assert_eq!(approval_actor, "maintenance");
}

#[tokio::test]
async fn maintenance_run_rejects_pending_candidates_covered_by_active_memory() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    let created = client
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
                    "text": "Use curl for service health checks.",
                    "confidence": 0.70,
                    "reason": "Needs review before promotion."
                }
            ]
        }))
        .send()
        .await
        .expect("create candidate")
        .json::<serde_json::Value>()
        .await
        .expect("candidate json");
    let candidate_id = created["candidates"][0]["id"]
        .as_str()
        .expect("candidate id");

    let active = client
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "project_rule",
            "scope": "repo",
            "text": " use curl for service health checks ",
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
        .expect("create active memory")
        .json::<serde_json::Value>()
        .await
        .expect("active memory json");

    let result = client
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
    assert_eq!(result["autoRejectedCandidates"], 1);
    assert_eq!(result["autoRejectedChangeRequests"], 0);

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
    assert!(pending["candidates"].as_array().unwrap().is_empty());

    let pool = memory_core::db::sqlite::open(temp.path())
        .await
        .expect("audit db");
    let audit: (String, String, String) = sqlx::query_as(
        "select actor, action, memory_id
         from memory_audit_log
         where candidate_id = ?
         order by created_at desc
         limit 1",
    )
    .bind(candidate_id)
    .fetch_one(&pool)
    .await
    .expect("auto reject audit");
    assert_eq!(audit.0, "maintenance");
    assert_eq!(audit.1, "candidate.auto_reject_duplicate");
    assert_eq!(audit.2, active["id"].as_str().unwrap());
}

#[tokio::test]
async fn maintenance_run_does_not_auto_merge_preferences_with_only_generic_overlap() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    for text in [
        "User prefers concise answers.",
        "User prefers detailed answers.",
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
                    "repoId": "repo-1"
                }
            }))
            .send()
            .await
            .expect("create memory");
    }

    let result = client
        .post(format!("{}/v1/memory/maintenance/run", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "mode": "high_confidence_auto",
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1"
            },
            "highConfidenceThreshold": 0.90,
            "reviewThreshold": 0.75,
            "maxItemsPerBatch": 12
        }))
        .send()
        .await
        .expect("run maintenance")
        .json::<serde_json::Value>()
        .await
        .expect("run maintenance json");
    assert_eq!(result["autoApplied"], 0);
    assert_eq!(result["needsReview"], 0);

    let memory = client
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
    let items = memory["items"].as_array().expect("memory items");
    assert_eq!(items.len(), 2);
}

#[tokio::test]
async fn maintenance_run_merges_visible_session_memory_when_scope_omits_session() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    for text in [
        "Session summary says Rodriguez prefers concise review prompts.",
        "Session note: Rodriguez prefers concise review prompts.",
    ] {
        client
            .post(format!("{}/v1/memory", state.base_url))
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
                    "sessionId": "session-1"
                }
            }))
            .send()
            .await
            .expect("create session memory");
    }

    client
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "session_summary",
            "scope": "session",
            "text": "Session note: Rodriguez prefers concise review prompts.",
            "scopeData": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-other",
                "agentId": "agent-1",
                "sessionId": "session-1"
            }
        }))
        .send()
        .await
        .expect("create other repo session memory");

    let result = client
        .post(format!("{}/v1/memory/maintenance/run", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "mode": "high_confidence_auto",
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1"
            },
            "highConfidenceThreshold": 0.90,
            "reviewThreshold": 0.75,
            "maxItemsPerBatch": 12
        }))
        .send()
        .await
        .expect("run maintenance")
        .json::<serde_json::Value>()
        .await
        .expect("run maintenance json");

    assert_eq!(result["autoApplied"], 1);
    assert_eq!(result["needsReview"], 0);
    assert_eq!(result["changeRequests"][0]["action"], "merge");
    assert_eq!(result["changeRequests"][0]["status"], "approved");

    let listed = client
        .get(format!(
            "{}/v1/memory?userId=local-user&workspaceId=workspace-1&repoId=repo-1&status=active",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("list memory")
        .json::<serde_json::Value>()
        .await
        .expect("list memory json");
    let items = listed["items"].as_array().expect("memory items");
    assert_eq!(items.len(), 1);
    assert!(items[0]["text"].as_str().unwrap().contains("Rodriguez"));
}

#[tokio::test]
async fn maintenance_run_supersedes_conflicting_profile_memory_with_newer_fact() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    let old = client
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "user_preference",
            "scope": "global",
            "text": "User preferred name is Alex.",
            "scopeData": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1"
            }
        }))
        .send()
        .await
        .expect("create old preference")
        .json::<serde_json::Value>()
        .await
        .expect("old preference json");
    let old_id = old["id"].as_str().expect("old id");

    tokio::time::sleep(Duration::from_millis(2)).await;

    let current = client
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "user_preference",
            "scope": "global",
            "text": "User preferred name is Rodriguez.",
            "scopeData": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1"
            }
        }))
        .send()
        .await
        .expect("create current preference")
        .json::<serde_json::Value>()
        .await
        .expect("current preference json");
    let current_id = current["id"].as_str().expect("current id");

    let result = client
        .post(format!("{}/v1/memory/maintenance/run", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1"
            },
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

    assert_eq!(result["autoApplied"], 1);
    assert_eq!(result["needsReview"], 0);
    assert_eq!(result["changeRequests"][0]["action"], "supersede");

    let pool = memory_core::db::sqlite::open(temp.path())
        .await
        .expect("db");
    let old_valid_until: Option<i64> =
        sqlx::query_scalar("select valid_until from memory_items where id = ?")
            .bind(old_id)
            .fetch_one(&pool)
            .await
            .expect("old valid until");
    assert!(old_valid_until.is_some());

    let current_supersedes: Option<String> =
        sqlx::query_scalar("select supersedes_memory_id from memory_items where id = ?")
            .bind(current_id)
            .fetch_one(&pool)
            .await
            .expect("current supersedes");
    assert_eq!(current_supersedes.as_deref(), Some(old_id));

    let current_pinned: i64 = sqlx::query_scalar("select pinned from memory_items where id = ?")
        .bind(current_id)
        .fetch_one(&pool)
        .await
        .expect("current pinned");
    assert_eq!(current_pinned, 1);

    let active_count: i64 =
        sqlx::query_scalar("select count(*) from memory_items where status = 'active'")
            .fetch_one(&pool)
            .await
            .expect("active count");
    assert_eq!(active_count, 2);

    let expire_actor: String = sqlx::query_scalar(
        "select actor from memory_audit_log
         where action = 'memory.expire' and memory_id = ?
         order by created_at desc
         limit 1",
    )
    .bind(old_id)
    .fetch_one(&pool)
    .await
    .expect("expire actor");
    assert_eq!(expire_actor, "maintenance");

    let supersede_actor: String = sqlx::query_scalar(
        "select actor from memory_audit_log
         where action = 'memory.supersede' and memory_id = ?
         order by created_at desc
         limit 1",
    )
    .bind(current_id)
    .fetch_one(&pool)
    .await
    .expect("supersede actor");
    assert_eq!(supersede_actor, "maintenance");
}

#[tokio::test]
async fn maintenance_run_auto_expires_memories_past_valid_until() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    let expired = client
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "project_rule",
            "scope": "repo",
            "text": "Temporary launch rule expired yesterday.",
            "validUntil": 1_000,
            "scopeData": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-expire",
                "agentId": "agent-1",
                "sessionId": "session-1"
            }
        }))
        .send()
        .await
        .expect("create expired memory")
        .json::<serde_json::Value>()
        .await
        .expect("expired memory json");

    let current = client
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "project_rule",
            "scope": "repo",
            "text": "Use dart format before Flutter verification.",
            "validUntil": 9_999_999_999_999_i64,
            "scopeData": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-expire",
                "agentId": "agent-1",
                "sessionId": "session-1"
            }
        }))
        .send()
        .await
        .expect("create current memory")
        .json::<serde_json::Value>()
        .await
        .expect("current memory json");

    let result = client
        .post(format!("{}/v1/memory/maintenance/run", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "enabled": true,
            "mode": "high_confidence_auto",
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-expire"
            },
            "highConfidenceThreshold": 0.90,
            "reviewThreshold": 0.75,
            "maxItemsPerBatch": 12
        }))
        .send()
        .await
        .expect("run maintenance")
        .json::<serde_json::Value>()
        .await
        .expect("run maintenance json");

    assert_eq!(result["autoApplied"], 1);
    assert_eq!(result["needsReview"], 0);
    assert_eq!(result["changeRequests"][0]["action"], "expire");
    assert_eq!(result["changeRequests"][0]["status"], "approved");

    let pool = memory_core::db::sqlite::open(temp.path())
        .await
        .expect("db");
    let expired_status: String = sqlx::query_scalar("select status from memory_items where id = ?")
        .bind(expired["id"].as_str().unwrap())
        .fetch_one(&pool)
        .await
        .expect("expired status");
    let current_status: String = sqlx::query_scalar("select status from memory_items where id = ?")
        .bind(current["id"].as_str().unwrap())
        .fetch_one(&pool)
        .await
        .expect("current status");
    assert_eq!(expired_status, "disabled");
    assert_eq!(current_status, "active");

    let expire_audit_count: i64 = sqlx::query_scalar(
        "select count(*) from memory_audit_log where action = 'memory.expire' and memory_id = ?",
    )
    .bind(expired["id"].as_str().unwrap())
    .fetch_one(&pool)
    .await
    .expect("expire audit count");
    assert_eq!(expire_audit_count, 1);
}

#[tokio::test]
async fn maintenance_run_expires_visible_session_memory_when_scope_omits_session() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    let expired = client
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "session_summary",
            "scope": "session",
            "text": "Temporary session note that should expire.",
            "validUntil": 1_000,
            "scopeData": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-expire",
                "agentId": "agent-1",
                "sessionId": "session-1"
            }
        }))
        .send()
        .await
        .expect("create expired session memory")
        .json::<serde_json::Value>()
        .await
        .expect("expired session memory json");

    let other_repo = client
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "session_summary",
            "scope": "session",
            "text": "Temporary session note in another repo.",
            "validUntil": 1_000,
            "scopeData": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-other",
                "agentId": "agent-1",
                "sessionId": "session-1"
            }
        }))
        .send()
        .await
        .expect("create other repo expired session memory")
        .json::<serde_json::Value>()
        .await
        .expect("other repo expired session memory json");

    let result = client
        .post(format!("{}/v1/memory/maintenance/run", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "enabled": true,
            "mode": "high_confidence_auto",
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-expire"
            },
            "highConfidenceThreshold": 0.90,
            "reviewThreshold": 0.75,
            "maxItemsPerBatch": 12
        }))
        .send()
        .await
        .expect("run maintenance")
        .json::<serde_json::Value>()
        .await
        .expect("run maintenance json");

    assert_eq!(result["autoApplied"], 1);
    assert_eq!(result["needsReview"], 0);
    assert_eq!(result["changeRequests"][0]["action"], "expire");
    assert_eq!(result["changeRequests"][0]["status"], "approved");

    let pool = memory_core::db::sqlite::open(temp.path())
        .await
        .expect("db");
    let expired_status: String = sqlx::query_scalar("select status from memory_items where id = ?")
        .bind(expired["id"].as_str().unwrap())
        .fetch_one(&pool)
        .await
        .expect("expired status");
    let other_repo_status: String =
        sqlx::query_scalar("select status from memory_items where id = ?")
            .bind(other_repo["id"].as_str().unwrap())
            .fetch_one(&pool)
            .await
            .expect("other repo status");
    assert_eq!(expired_status, "disabled");
    assert_eq!(other_repo_status, "active");
}

#[tokio::test]
async fn maintenance_run_respects_disabled_manual_review_and_manual_only_actions() {
    async fn seed_duplicate_memories(client: &reqwest::Client, base_url: &str, repo_id: &str) {
        for text in [
            "The user goes by Rodriguez.",
            "User prefers to be called Rodriguez.",
        ] {
            client
                .post(format!("{base_url}/v1/memory"))
                .bearer_auth("test-token")
                .json(&serde_json::json!({
                    "kind": "user_preference",
                    "scope": "repo",
                    "text": text,
                    "scopeData": {
                        "userId": "local-user",
                        "workspaceId": "workspace-1",
                        "repoId": repo_id
                    }
                }))
                .send()
                .await
                .expect("create memory");
        }
    }

    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    seed_duplicate_memories(&client, &state.base_url, "repo-disabled").await;
    let disabled = client
        .post(format!("{}/v1/memory/maintenance/run", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "enabled": false,
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-disabled"
            },
            "highConfidenceThreshold": 0.90,
            "reviewThreshold": 0.75,
            "maxItemsPerBatch": 12
        }))
        .send()
        .await
        .expect("run disabled maintenance")
        .json::<serde_json::Value>()
        .await
        .expect("disabled maintenance json");
    assert_eq!(disabled["autoApplied"], 0);
    assert_eq!(disabled["needsReview"], 0);

    seed_duplicate_memories(&client, &state.base_url, "repo-manual").await;
    let manual = client
        .post(format!("{}/v1/memory/maintenance/run", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "enabled": true,
            "mode": "manual_review",
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-manual"
            },
            "highConfidenceThreshold": 0.90,
            "reviewThreshold": 0.75,
            "maxItemsPerBatch": 12
        }))
        .send()
        .await
        .expect("run manual maintenance")
        .json::<serde_json::Value>()
        .await
        .expect("manual maintenance json");
    assert_eq!(manual["autoApplied"], 0);
    assert_eq!(manual["needsReview"], 1);

    seed_duplicate_memories(&client, &state.base_url, "repo-manual-action").await;
    let manual_action = client
        .post(format!("{}/v1/memory/maintenance/run", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "enabled": true,
            "mode": "high_confidence_auto",
            "manualOnlyActions": ["merge"],
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-manual-action"
            },
            "highConfidenceThreshold": 0.90,
            "reviewThreshold": 0.75,
            "maxItemsPerBatch": 12
        }))
        .send()
        .await
        .expect("run manual action maintenance")
        .json::<serde_json::Value>()
        .await
        .expect("manual action maintenance json");
    assert_eq!(manual_action["autoApplied"], 0);
    assert_eq!(manual_action["needsReview"], 1);
}

#[tokio::test]
async fn maintenance_run_uses_llm_extractor_after_prefilter() {
    let hits = Arc::new(AtomicUsize::new(0));
    let llm_listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("llm listener");
    let llm_port = llm_listener.local_addr().expect("llm addr").port();
    let llm_hits = hits.clone();
    let llm_router = Router::new().route(
        "/v1/chat/completions",
        post(move |Json(body): Json<serde_json::Value>| {
            let llm_hits = llm_hits.clone();
            async move {
                llm_hits.fetch_add(1, Ordering::SeqCst);
                let serialized = body.to_string();
                assert!(serialized.contains("The user goes by Rodriguez."));
                assert!(!serialized.contains("full transcript"));
                Json(serde_json::json!({
                    "choices": [
                        {
                            "message": {
                                "content": serde_json::json!({
                                    "changeRequests": [
                                        {
                                            "action": "summarize",
                                            "proposedText": "The user goes by Rodriguez.",
                                            "confidence": 0.82,
                                            "reason": "LLM condensed duplicate user-name memories."
                                        }
                                    ]
                                }).to_string()
                            }
                        }
                    ]
                }))
            }
        }),
    );
    tokio::spawn(async move {
        let _ = axum::serve(llm_listener, llm_router).await;
    });

    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon_with_llm(
        temp.path(),
        "test-token",
        Some(memory_core::config::MaintenanceLlmConfig {
            provider: "openai-compatible".to_string(),
            base_url: format!("http://127.0.0.1:{llm_port}/v1"),
            model: "fake-maintenance-model".to_string(),
            api_key: None,
        }),
    )
    .await
    .expect("daemon");
    let client = reqwest::Client::new();

    for text in [
        "The user goes by Rodriguez.",
        "User prefers to be called Rodriguez.",
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
                    "repoId": "repo-1"
                }
            }))
            .send()
            .await
            .expect("create memory");
    }

    let result = client
        .post(format!("{}/v1/memory/maintenance/run", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1"
            },
            "costMode": "quality",
            "highConfidenceThreshold": 0.90,
            "reviewThreshold": 0.75,
            "maxItemsPerBatch": 12
        }))
        .send()
        .await
        .expect("run maintenance")
        .json::<serde_json::Value>()
        .await
        .expect("run maintenance json");
    assert_eq!(result["autoApplied"], 0);
    assert_eq!(result["needsReview"], 1);
    assert_eq!(result["changeRequests"][0]["source"], "maintenance");
    assert_eq!(hits.load(Ordering::SeqCst), 1);

    let requests = client
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
    let item = &requests["items"].as_array().expect("request items")[0];
    assert_eq!(item["action"], "merge");
    assert_eq!(item["source"], "maintenance");
    assert_eq!(item["proposedText"], "The user goes by Rodriguez.");
    assert_eq!(item["targetMemoryIds"].as_array().unwrap().len(), 2);
}

#[tokio::test]
async fn maintenance_run_low_cost_skips_llm_for_high_confidence_rule_merge() {
    let hits = Arc::new(AtomicUsize::new(0));
    let llm_listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("llm listener");
    let llm_port = llm_listener.local_addr().expect("llm addr").port();
    let llm_hits = hits.clone();
    let llm_router = Router::new().route(
        "/v1/chat/completions",
        post(move |_body: Json<serde_json::Value>| {
            let llm_hits = llm_hits.clone();
            async move {
                llm_hits.fetch_add(1, Ordering::SeqCst);
                Json(serde_json::json!({
                    "choices": [
                        {
                            "message": {
                                "content": serde_json::json!({
                                    "changeRequests": []
                                }).to_string()
                            }
                        }
                    ]
                }))
            }
        }),
    );
    tokio::spawn(async move {
        let _ = axum::serve(llm_listener, llm_router).await;
    });

    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon_with_llm(
        temp.path(),
        "test-token",
        Some(memory_core::config::MaintenanceLlmConfig {
            provider: "openai-compatible".to_string(),
            base_url: format!("http://127.0.0.1:{llm_port}/v1"),
            model: "fake-maintenance-model".to_string(),
            api_key: None,
        }),
    )
    .await
    .expect("daemon");
    let client = reqwest::Client::new();

    for text in [
        "The user goes by Rodriguez.",
        "User prefers to be called Rodriguez.",
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
                    "repoId": "repo-1"
                }
            }))
            .send()
            .await
            .expect("create memory");
    }

    let result = client
        .post(format!("{}/v1/memory/maintenance/run", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1"
            },
            "costMode": "low_cost",
            "highConfidenceThreshold": 0.90,
            "reviewThreshold": 0.75,
            "maxItemsPerBatch": 12
        }))
        .send()
        .await
        .expect("run maintenance")
        .json::<serde_json::Value>()
        .await
        .expect("run maintenance json");

    assert_eq!(result["autoApplied"], 1);
    assert_eq!(result["needsReview"], 0);
    assert_eq!(hits.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn maintenance_run_low_cost_skips_llm_for_high_confidence_manual_only_action() {
    let hits = Arc::new(AtomicUsize::new(0));
    let llm_listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("llm listener");
    let llm_port = llm_listener.local_addr().expect("llm addr").port();
    let llm_hits = hits.clone();
    let llm_router = Router::new().route(
        "/v1/chat/completions",
        post(move |_body: Json<serde_json::Value>| {
            let llm_hits = llm_hits.clone();
            async move {
                llm_hits.fetch_add(1, Ordering::SeqCst);
                Json(serde_json::json!({
                    "choices": [
                        {
                            "message": {
                                "content": serde_json::json!({
                                    "changeRequests": []
                                }).to_string()
                            }
                        }
                    ]
                }))
            }
        }),
    );
    tokio::spawn(async move {
        let _ = axum::serve(llm_listener, llm_router).await;
    });

    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon_with_llm(
        temp.path(),
        "test-token",
        Some(memory_core::config::MaintenanceLlmConfig {
            provider: "openai-compatible".to_string(),
            base_url: format!("http://127.0.0.1:{llm_port}/v1"),
            model: "fake-maintenance-model".to_string(),
            api_key: None,
        }),
    )
    .await
    .expect("daemon");
    let client = reqwest::Client::new();

    for text in [
        "The user goes by Rodriguez.",
        "User prefers to be called Rodriguez.",
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
                    "repoId": "repo-1"
                }
            }))
            .send()
            .await
            .expect("create memory");
    }

    let result = client
        .post(format!("{}/v1/memory/maintenance/run", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1"
            },
            "costMode": "low_cost",
            "manualOnlyActions": ["merge"],
            "highConfidenceThreshold": 0.90,
            "reviewThreshold": 0.75,
            "maxItemsPerBatch": 12
        }))
        .send()
        .await
        .expect("run maintenance")
        .json::<serde_json::Value>()
        .await
        .expect("run maintenance json");

    assert_eq!(result["autoApplied"], 0);
    assert_eq!(result["needsReview"], 1);
    assert_eq!(result["changeRequests"][0]["status"], "pending");
    assert_eq!(hits.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn maintenance_run_treats_pair_summarize_as_merge() {
    let llm_listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("llm listener");
    let llm_port = llm_listener.local_addr().expect("llm addr").port();
    let llm_router = Router::new().route(
        "/v1/chat/completions",
        post(move |_body: Json<serde_json::Value>| async move {
            Json(serde_json::json!({
                "choices": [
                    {
                        "message": {
                            "content": serde_json::json!({
                                "changeRequests": [
                                    {
                                        "action": "summarize",
                                        "proposedText": "The user goes by Rodriguez.",
                                        "confidence": 0.93,
                                        "reason": "LLM condensed duplicate user-name memories."
                                    }
                                ]
                            }).to_string()
                        }
                    }
                ]
            }))
        }),
    );
    tokio::spawn(async move {
        let _ = axum::serve(llm_listener, llm_router).await;
    });

    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon_with_llm(
        temp.path(),
        "test-token",
        Some(memory_core::config::MaintenanceLlmConfig {
            provider: "openai-compatible".to_string(),
            base_url: format!("http://127.0.0.1:{llm_port}/v1"),
            model: "fake-maintenance-model".to_string(),
            api_key: None,
        }),
    )
    .await
    .expect("daemon");
    let client = reqwest::Client::new();

    for text in [
        "The user goes by Rodriguez.",
        "User prefers to be called Rodriguez.",
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
                    "repoId": "repo-1"
                }
            }))
            .send()
            .await
            .expect("create memory");
    }

    let result = client
        .post(format!("{}/v1/memory/maintenance/run", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1"
            },
            "mode": "high_confidence_auto",
            "costMode": "quality",
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

    assert_eq!(result["autoApplied"], 1, "{result}");
    assert_eq!(result["needsReview"], 0, "{result}");
    assert_eq!(result["changeRequests"][0]["action"], "merge");

    let memory = client
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
    let items = memory["items"].as_array().expect("memory items");
    assert_eq!(items.len(), 1);
    assert_eq!(items[0]["text"], "The user goes by Rodriguez.");
}

#[tokio::test]
async fn maintenance_run_accepts_explicit_pair_summarize_targets_as_merge() {
    let llm_listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("llm listener");
    let llm_port = llm_listener.local_addr().expect("llm addr").port();
    let llm_router = Router::new().route(
        "/v1/chat/completions",
        post(move |Json(body): Json<serde_json::Value>| async move {
            let content = body["messages"][1]["content"]
                .as_str()
                .expect("maintenance prompt content");
            let input_start = content.find("Input: ").expect("input marker") + "Input: ".len();
            let input: serde_json::Value =
                serde_json::from_str(&content[input_start..]).expect("maintenance input json");
            let ids = input["memories"]
                .as_array()
                .expect("memories")
                .iter()
                .map(|memory| memory["id"].as_str().expect("memory id"))
                .collect::<Vec<_>>();
            Json(serde_json::json!({
                "choices": [
                    {
                        "message": {
                            "content": serde_json::json!({
                                "changeRequests": [
                                    {
                                        "action": "summarize",
                                        "targetMemoryIds": ids,
                                        "proposedText": "User preferred name is Rodriguez.",
                                        "confidence": 0.93,
                                        "reason": "LLM condensed duplicate user-name memories."
                                    }
                                ]
                            }).to_string()
                        }
                    }
                ]
            }))
        }),
    );
    tokio::spawn(async move {
        let _ = axum::serve(llm_listener, llm_router).await;
    });

    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon_with_llm(
        temp.path(),
        "test-token",
        Some(memory_core::config::MaintenanceLlmConfig {
            provider: "openai-compatible".to_string(),
            base_url: format!("http://127.0.0.1:{llm_port}/v1"),
            model: "fake-maintenance-model".to_string(),
            api_key: None,
        }),
    )
    .await
    .expect("daemon");
    let client = reqwest::Client::new();

    for text in [
        "The user goes by Rodriguez in this workspace.",
        "User prefers to be called Rodriguez during reviews.",
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
                    "repoId": "repo-1"
                }
            }))
            .send()
            .await
            .expect("create memory");
    }

    let result = client
        .post(format!("{}/v1/memory/maintenance/run", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1"
            },
            "mode": "high_confidence_auto",
            "costMode": "quality",
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

    assert_eq!(result["autoApplied"], 1, "{result}");
    assert_eq!(result["needsReview"], 0, "{result}");
    assert_eq!(result["changeRequests"][0]["action"], "merge");
    assert_eq!(
        result["changeRequests"][0]["proposedText"],
        "User preferred name is Rodriguez."
    );
}

#[tokio::test]
async fn maintenance_run_keeps_unmodified_pair_member_available_after_single_target_llm_request() {
    let llm_listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("llm listener");
    let llm_port = llm_listener.local_addr().expect("llm addr").port();
    let llm_router = Router::new().route(
        "/v1/chat/completions",
        post(move |Json(body): Json<serde_json::Value>| async move {
            let content = body["messages"][1]["content"]
                .as_str()
                .expect("maintenance prompt content");
            let input_start = content.find("Input: ").expect("input marker") + "Input: ".len();
            let input: serde_json::Value =
                serde_json::from_str(&content[input_start..]).expect("maintenance input json");
            let first = &input["memories"][0];
            let first_id = first["id"].as_str().expect("first memory id");
            let first_text = first["text"].as_str().expect("first memory text");
            let change_requests = if first_text.contains("goes by Rodriguez") {
                serde_json::json!([
                    {
                        "action": "summarize",
                        "targetMemoryIds": [first_id],
                        "proposedText": "The user goes by Rodriguez.",
                        "confidence": 0.82,
                        "reason": "Only the first memory needs a shorter summary."
                    }
                ])
            } else {
                serde_json::json!([])
            };
            Json(serde_json::json!({
                "choices": [
                    {
                        "message": {
                            "content": serde_json::json!({
                                "changeRequests": change_requests
                            }).to_string()
                        }
                    }
                ]
            }))
        }),
    );
    tokio::spawn(async move {
        let _ = axum::serve(llm_listener, llm_router).await;
    });

    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon_with_llm(
        temp.path(),
        "test-token",
        Some(memory_core::config::MaintenanceLlmConfig {
            provider: "openai-compatible".to_string(),
            base_url: format!("http://127.0.0.1:{llm_port}/v1"),
            model: "fake-maintenance-model".to_string(),
            api_key: None,
        }),
    )
    .await
    .expect("daemon");
    let client = reqwest::Client::new();

    for text in [
        "User prefers to be called Rodriguez.",
        "User is called Rodriguez.",
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
                    "repoId": "repo-1"
                }
            }))
            .send()
            .await
            .expect("create memory");
    }

    tokio::time::sleep(Duration::from_millis(2)).await;

    client
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "user_preference",
            "scope": "global",
            "text": "The user goes by Rodriguez.",
            "scopeData": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1"
            }
        }))
        .send()
        .await
        .expect("create newest memory");

    let result = client
        .post(format!("{}/v1/memory/maintenance/run", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1"
            },
            "mode": "high_confidence_auto",
            "costMode": "quality",
            "highConfidenceThreshold": 0.90,
            "reviewThreshold": 0.75,
            "maxItemsPerBatch": 12
        }))
        .send()
        .await
        .expect("run maintenance")
        .json::<serde_json::Value>()
        .await
        .expect("run maintenance json");

    assert_eq!(result["autoApplied"], 1, "{result}");
    assert_eq!(result["needsReview"], 1, "{result}");
    let actions = result["changeRequests"]
        .as_array()
        .expect("change requests")
        .iter()
        .map(|item| item["action"].as_str().expect("action"))
        .collect::<Vec<_>>();
    assert!(actions.contains(&"summarize"));
    assert!(actions.contains(&"merge"));
}

#[tokio::test]
async fn maintenance_run_ignores_llm_targets_outside_prefilter_pair() {
    let captured_target = Arc::new(std::sync::Mutex::new(String::new()));
    let llm_listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("llm listener");
    let llm_port = llm_listener.local_addr().expect("llm addr").port();
    let llm_target = captured_target.clone();
    let llm_router = Router::new().route(
        "/v1/chat/completions",
        post(move |_body: Json<serde_json::Value>| {
            let llm_target = llm_target.clone();
            async move {
                let target = llm_target.lock().expect("target lock").clone();
                Json(serde_json::json!({
                    "choices": [
                        {
                            "message": {
                                "content": serde_json::json!({
                                    "changeRequests": [
                                        {
                                            "action": "merge",
                                            "targetMemoryIds": [target],
                                            "proposedText": "The user goes by Rodriguez.",
                                            "confidence": 0.97,
                                            "reason": "LLM should not be able to retarget maintenance outside the prefiltered pair."
                                        }
                                    ]
                                }).to_string()
                            }
                        }
                    ]
                }))
            }
        }),
    );
    tokio::spawn(async move {
        let _ = axum::serve(llm_listener, llm_router).await;
    });

    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon_with_llm(
        temp.path(),
        "test-token",
        Some(memory_core::config::MaintenanceLlmConfig {
            provider: "openai-compatible".to_string(),
            base_url: format!("http://127.0.0.1:{llm_port}/v1"),
            model: "fake-maintenance-model".to_string(),
            api_key: None,
        }),
    )
    .await
    .expect("daemon");
    let client = reqwest::Client::new();

    let unrelated = client
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "project_rule",
            "scope": "repo",
            "text": "Use emerald for CLI screenshots.",
            "scopeData": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1"
            }
        }))
        .send()
        .await
        .expect("create unrelated memory")
        .json::<serde_json::Value>()
        .await
        .expect("unrelated memory json");
    let unrelated_id = unrelated["id"].as_str().expect("unrelated id").to_string();
    *captured_target.lock().expect("target lock") = unrelated_id.clone();

    tokio::time::sleep(Duration::from_millis(2)).await;

    for text in [
        "The user goes by Rodriguez.",
        "User prefers to be called Rodriguez.",
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
                    "repoId": "repo-1"
                }
            }))
            .send()
            .await
            .expect("create duplicate memory");
    }

    let result = client
        .post(format!("{}/v1/memory/maintenance/run", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1"
            },
            "costMode": "quality",
            "highConfidenceThreshold": 0.90,
            "reviewThreshold": 0.75,
            "maxItemsPerBatch": 12
        }))
        .send()
        .await
        .expect("run maintenance")
        .json::<serde_json::Value>()
        .await
        .expect("run maintenance json");

    assert_eq!(result["autoApplied"], 1);
    let target_ids = result["changeRequests"][0]["targetMemoryIds"]
        .as_array()
        .expect("target ids");
    assert_eq!(target_ids.len(), 2);
    assert!(!target_ids
        .iter()
        .any(|id| id.as_str() == Some(unrelated_id.as_str())));

    let memories = client
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
    assert!(memories["items"].as_array().unwrap().iter().any(|item| {
        item["id"].as_str() == Some(unrelated_id.as_str())
            && item["status"].as_str() == Some("active")
    }));
}

#[tokio::test]
async fn maintenance_run_uses_entity_overlap_prefilter_without_text_overlap() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    for text in [
        "Greeting style should stay formal.",
        "Alias preference remains relaxed.",
    ] {
        client
            .post(format!("{}/v1/memory", state.base_url))
            .bearer_auth("test-token")
            .json(&serde_json::json!({
                "kind": "user_preference",
                "scope": "global",
                "text": text,
                "entities": [
                    {"text": "Rodriguez", "type": "person"}
                ],
                "scopeData": {
                    "userId": "local-user",
                    "workspaceId": "workspace-1",
                    "repoId": "repo-1"
                }
            }))
            .send()
            .await
            .expect("create entity memory");
    }

    let result = client
        .post(format!("{}/v1/memory/maintenance/run", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1"
            },
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

    assert_eq!(result["autoApplied"], 0);
    assert_eq!(result["needsReview"], 1);
    assert_eq!(result["changeRequests"][0]["action"], "merge");
    assert!(result["changeRequests"][0]["confidence"].as_f64().unwrap() >= 0.75);
    assert!(result["changeRequests"][0]["confidence"].as_f64().unwrap() < 0.90);
}

#[tokio::test]
async fn maintenance_run_auto_merges_same_project_verification_identifier() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    for text in [
        "The repo verification phrase is the blue lighthouse.",
        "验证暗号使用蓝色灯塔。",
    ] {
        client
            .post(format!("{}/v1/memory", state.base_url))
            .bearer_auth("test-token")
            .json(&serde_json::json!({
                "kind": "project_rule",
                "scope": "repo",
                "text": text,
                "entities": [
                    {"text": "blue-lighthouse-43130", "type": "identifier"}
                ],
                "scopeData": {
                    "userId": "local-user",
                    "workspaceId": "workspace-1",
                    "repoId": "repo-1"
                }
            }))
            .send()
            .await
            .expect("create verification memory");
    }

    let result = client
        .post(format!("{}/v1/memory/maintenance/run", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1"
            },
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

    assert_eq!(result["autoApplied"], 1);
    assert_eq!(result["needsReview"], 0);
    assert_eq!(result["changeRequests"][0]["action"], "merge");
    assert_eq!(result["changeRequests"][0]["status"], "approved");
    assert!(result["changeRequests"][0]["confidence"].as_f64().unwrap() >= 0.90);
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
async fn search_returns_semantically_visible_repo_memory() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    let broad_repo_memory = client
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "project_rule",
            "scope": "repo",
            "text": "The project verification passphrase is blue lighthouse 43130.",
            "scopeData": {
                "userId": "local-user"
            }
        }))
        .send()
        .await
        .expect("create memory")
        .json::<serde_json::Value>()
        .await
        .expect("memory json");

    let search = client
        .post(format!("{}/v1/memory/search", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "query": "project verification passphrase",
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
    assert_eq!(search["items"][0]["id"], broad_repo_memory["id"]);
}

#[tokio::test]
async fn search_returns_pinned_memory_without_query_overlap() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    let pinned = client
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "user_preference",
            "scope": "global",
            "text": "用户称呼是 Rodriguez。",
            "pinned": true,
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
        .expect("create pinned")
        .json::<serde_json::Value>()
        .await
        .expect("pinned json");
    client
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "user_preference",
            "scope": "global",
            "text": "Prefer quiet spacing in dense tables.",
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
        .expect("create ordinary");

    let search = client
        .post(format!("{}/v1/memory/search", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "query": "garden sandbox dashboard",
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

    let items = search["items"].as_array().expect("items");
    assert_eq!(items.len(), 1);
    assert_eq!(items[0]["id"], pinned["id"]);
    assert_eq!(items[0]["metadata"]["pinned"], true);
    assert_eq!(
        items[0]["metadata"]["profileBlock"]["label"],
        "user_profile"
    );
    assert_eq!(
        items[0]["metadata"]["profileBlock"]["description"],
        "Stable user preferences and identity facts."
    );
    assert_eq!(items[0]["metadata"]["profileBlock"]["limit"], 4);
    assert_eq!(items[0]["metadata"]["diagnostics"]["pinnedLayer"], true);
    assert_eq!(items[0]["metadata"]["diagnostics"]["lexicalScore"], 0.0);
    assert_eq!(items[0]["metadata"]["diagnostics"]["semanticHit"], false);

    let pool = memory_core::db::sqlite::open(temp.path())
        .await
        .expect("db");
    let access_count: i64 =
        sqlx::query_scalar("select count(*) from memory_accesses where memory_id = ?")
            .bind(pinned["id"].as_str().unwrap())
            .fetch_one(&pool)
            .await
            .expect("access count");
    assert_eq!(access_count, 0);
}

#[tokio::test]
async fn search_balances_pinned_profile_blocks_before_limit() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    for text in [
        "Project rule A should stay available.",
        "Project rule B should stay available.",
        "Project rule C should stay available.",
    ] {
        client
            .post(format!("{}/v1/memory", state.base_url))
            .bearer_auth("test-token")
            .json(&serde_json::json!({
                "kind": "project_rule",
                "scope": "repo",
                "text": text,
                "pinned": true,
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
            .expect("create project pinned");
    }
    client
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "user_preference",
            "scope": "global",
            "text": "User profile should survive project profile crowding.",
            "pinned": true,
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
        .expect("create user pinned");

    let search = client
        .post(format!("{}/v1/memory/search", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "query": "garden sandbox dashboard",
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1",
                "agentId": "agent-1",
                "sessionId": "session-1"
            },
            "limit": 2
        }))
        .send()
        .await
        .expect("search")
        .json::<serde_json::Value>()
        .await
        .expect("search json");

    let items = search["items"].as_array().expect("items");
    assert_eq!(items.len(), 2);
    assert!(items
        .iter()
        .any(|item| { item["metadata"]["profileBlock"]["label"] == "project_profile" }));
    assert!(items
        .iter()
        .any(|item| { item["metadata"]["profileBlock"]["label"] == "user_profile" }));
}

#[tokio::test]
async fn approved_high_confidence_stable_candidate_becomes_pinned() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    let created = client
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
                    "kind": "user_preference",
                    "scope": "global",
                    "text": "用户称呼是 Rodriguez。",
                    "confidence": 0.94,
                    "reason": "Explicit user identity preference."
                }
            ]
        }))
        .send()
        .await
        .expect("extract")
        .json::<serde_json::Value>()
        .await
        .expect("candidate json");
    let candidate = &created["candidates"][0];
    let approved = client
        .post(format!(
            "{}/v1/memory/candidates/{}/approve",
            state.base_url,
            candidate["id"].as_str().unwrap()
        ))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": candidate["kind"],
            "scope": candidate["scope"],
            "text": candidate["text"]
        }))
        .send()
        .await
        .expect("approve")
        .json::<serde_json::Value>()
        .await
        .expect("approved json");

    let search = client
        .post(format!("{}/v1/memory/search", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "query": "garden sandbox dashboard",
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

    let item = &search["items"][0];
    assert_eq!(item["id"], approved["id"]);
    assert_eq!(item["metadata"]["pinned"], true);
    assert_eq!(item["metadata"]["diagnostics"]["pinnedLayer"], true);
}

#[tokio::test]
async fn approved_review_band_stable_candidate_becomes_pinned() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    let created = client
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
                    "kind": "user_preference",
                    "scope": "global",
                    "text": "用户称呼是 Rodriguez。",
                    "confidence": 0.78,
                    "reason": "Stable identity memory in the automatic review band."
                }
            ]
        }))
        .send()
        .await
        .expect("extract")
        .json::<serde_json::Value>()
        .await
        .expect("candidate json");
    let candidate = &created["candidates"][0];

    let approved = client
        .post(format!(
            "{}/v1/memory/candidates/{}/approve",
            state.base_url,
            candidate["id"].as_str().unwrap()
        ))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": candidate["kind"],
            "scope": candidate["scope"],
            "text": candidate["text"],
            "actor": "automation"
        }))
        .send()
        .await
        .expect("approve")
        .json::<serde_json::Value>()
        .await
        .expect("approved json");

    assert_eq!(approved["pinned"], true);

    let search = client
        .post(format!("{}/v1/memory/search", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "query": "garden sandbox dashboard",
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

    let item = &search["items"][0];
    assert_eq!(item["id"], approved["id"]);
    assert_eq!(item["metadata"]["pinned"], true);
    assert_eq!(item["metadata"]["diagnostics"]["pinnedLayer"], true);
}

#[tokio::test]
async fn approved_workspace_project_rules_and_architecture_decisions_become_pinned() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    let created = client
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
                    "scope": "workspace",
                    "text": "All workspace services must use structured logs.",
                    "confidence": 0.94,
                    "reason": "Durable workspace rule."
                },
                {
                    "kind": "architecture_decision",
                    "scope": "workspace",
                    "text": "The workspace uses event sourcing for audit trails.",
                    "confidence": 0.94,
                    "reason": "Durable workspace architecture decision."
                }
            ]
        }))
        .send()
        .await
        .expect("extract")
        .json::<serde_json::Value>()
        .await
        .expect("candidate json");
    let candidates = created["candidates"].as_array().expect("candidates");
    assert_eq!(candidates.len(), 2);

    let mut approved_ids = Vec::new();
    for candidate in candidates {
        let approved = client
            .post(format!(
                "{}/v1/memory/candidates/{}/approve",
                state.base_url,
                candidate["id"].as_str().unwrap()
            ))
            .bearer_auth("test-token")
            .json(&serde_json::json!({
                "kind": candidate["kind"],
                "scope": candidate["scope"],
                "text": candidate["text"]
            }))
            .send()
            .await
            .expect("approve")
            .json::<serde_json::Value>()
            .await
            .expect("approved json");
        approved_ids.push(approved["id"].as_str().unwrap().to_string());
    }

    let search = client
        .post(format!("{}/v1/memory/search", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "query": "garden sandbox dashboard",
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
    let items = search["items"].as_array().expect("items");
    for approved_id in approved_ids {
        let item = items
            .iter()
            .find(|item| item["id"] == approved_id)
            .expect("pinned workspace memory returned");
        assert_eq!(item["metadata"]["pinned"], true);
        assert_eq!(item["metadata"]["diagnostics"]["pinnedLayer"], true);
    }
}

#[tokio::test]
async fn stale_feedback_expires_profile_memory() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    let pinned = client
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "user_preference",
            "scope": "global",
            "text": "用户称呼是 Rodriguez。",
            "pinned": true,
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
        .expect("create pinned")
        .json::<serde_json::Value>()
        .await
        .expect("pinned json");

    let before = client
        .post(format!("{}/v1/memory/search", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "query": "mobile release checklist",
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
        .expect("search before")
        .json::<serde_json::Value>()
        .await
        .expect("before json");
    assert_eq!(before["items"][0]["id"], pinned["id"]);
    assert_eq!(
        before["items"][0]["metadata"]["diagnostics"]["pinnedLayer"],
        true
    );

    let feedback = client
        .post(format!(
            "{}/v1/memory/{}/feedback",
            state.base_url,
            pinned["id"].as_str().unwrap()
        ))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "rating": "stale",
            "turnId": "turn-unpin",
            "reason": "The user corrected this remembered preference."
        }))
        .send()
        .await
        .expect("feedback");
    assert_eq!(feedback.status(), reqwest::StatusCode::OK);

    let after = client
        .post(format!("{}/v1/memory/search", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "query": "mobile release checklist",
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
        .expect("search after")
        .json::<serde_json::Value>()
        .await
        .expect("after json");
    assert_eq!(after["items"].as_array().unwrap().len(), 0);

    let lexical_after = client
        .post(format!("{}/v1/memory/search", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "query": "Rodriguez",
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
        .expect("lexical search after")
        .json::<serde_json::Value>()
        .await
        .expect("lexical after json");
    assert_eq!(lexical_after["items"].as_array().unwrap().len(), 0);

    let pool = memory_core::db::sqlite::open(temp.path())
        .await
        .expect("db");
    let (pinned_value, status, valid_until): (i64, String, Option<i64>) =
        sqlx::query_as("select pinned, status, valid_until from memory_items where id = ?")
            .bind(pinned["id"].as_str().unwrap())
            .fetch_one(&pool)
            .await
            .expect("memory status");
    assert_eq!(pinned_value, 0);
    assert_eq!(status, "disabled");
    assert!(valid_until.is_some());
    let unpin_audit_count: i64 = sqlx::query_scalar(
        "select count(*) from memory_audit_log where action = 'memory.unpin' and memory_id = ?",
    )
    .bind(pinned["id"].as_str().unwrap())
    .fetch_one(&pool)
    .await
    .expect("unpin audit count");
    assert_eq!(unpin_audit_count, 1);
    let expire_audit_count: i64 = sqlx::query_scalar(
        "select count(*) from memory_audit_log where action = 'memory.expire' and memory_id = ?",
    )
    .bind(pinned["id"].as_str().unwrap())
    .fetch_one(&pool)
    .await
    .expect("expire audit count");
    assert_eq!(expire_audit_count, 1);
}

#[tokio::test]
async fn helpful_feedback_promotes_stable_memory_to_profile_layer() {
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
            "text": "The verification phrase is blue lighthouse.",
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

    let before = client
        .post(format!("{}/v1/memory/search", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "query": "mobile release checklist",
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
        .expect("search before")
        .json::<serde_json::Value>()
        .await
        .expect("before json");
    assert_eq!(before["items"].as_array().unwrap().len(), 0);

    let feedback = client
        .post(format!(
            "{}/v1/memory/{}/feedback",
            state.base_url,
            memory["id"].as_str().unwrap()
        ))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "rating": "helpful",
            "turnId": "turn-promote",
            "reason": "This rule was useful for the answer."
        }))
        .send()
        .await
        .expect("feedback");
    assert_eq!(feedback.status(), reqwest::StatusCode::OK);

    let after = client
        .post(format!("{}/v1/memory/search", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "query": "mobile release checklist",
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
        .expect("search after")
        .json::<serde_json::Value>()
        .await
        .expect("after json");
    assert_eq!(after["items"][0]["id"], memory["id"]);
    assert_eq!(after["items"][0]["metadata"]["pinned"], true);
    assert_eq!(
        after["items"][0]["metadata"]["diagnostics"]["pinnedLayer"],
        true
    );

    let pool = memory_core::db::sqlite::open(temp.path())
        .await
        .expect("db");
    let promote_audit_count: i64 = sqlx::query_scalar(
        "select count(*) from memory_audit_log where action = 'memory.promote' and memory_id = ?",
    )
    .bind(memory["id"].as_str().unwrap())
    .fetch_one(&pool)
    .await
    .expect("promote audit count");
    assert_eq!(promote_audit_count, 1);
}

#[tokio::test]
async fn search_records_retrieved_memory_in_audit_log() {
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
            "text": "The user goes by Rodriguez.",
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
    let memory_id = created["id"].as_str().expect("memory id");

    let searched = client
        .post(format!("{}/v1/memory/search", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "query": "Rodriguez",
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1"
            }
        }))
        .send()
        .await
        .expect("search")
        .json::<serde_json::Value>()
        .await
        .expect("search json");
    assert_eq!(searched["items"].as_array().unwrap().len(), 1);

    let audit = client
        .get(format!(
            "{}/v1/memory/audit?userId=local-user&repoId=repo-1",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("audit list")
        .json::<serde_json::Value>()
        .await
        .expect("audit json");
    let items = audit["items"].as_array().expect("audit items");
    assert!(items.iter().any(|item| {
        item["action"] == "memory.retrieve"
            && item["memoryId"] == memory_id
            && item["memoryText"] == "The user goes by Rodriguez."
    }));
}

#[tokio::test]
async fn audit_log_includes_retrieved_global_memory_for_current_repo_scope() {
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
            "text": "The user goes by Rodriguez.",
            "scopeData": {
                "userId": "local-user"
            }
        }))
        .send()
        .await
        .expect("create global memory")
        .json::<serde_json::Value>()
        .await
        .expect("global memory json");
    let memory_id = created["id"].as_str().expect("memory id");

    let searched = client
        .post(format!("{}/v1/memory/search", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "query": "Rodriguez",
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1",
                "agentId": "agent-1",
                "sessionId": "session-1"
            }
        }))
        .send()
        .await
        .expect("search")
        .json::<serde_json::Value>()
        .await
        .expect("search json");
    assert_eq!(searched["items"].as_array().unwrap().len(), 1);

    let audit = client
        .get(format!(
            "{}/v1/memory/audit?userId=local-user&workspaceId=workspace-1&repoId=repo-1&agentId=agent-1&sessionId=session-1",
            state.base_url
        ))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("audit list")
        .json::<serde_json::Value>()
        .await
        .expect("audit json");
    let items = audit["items"].as_array().expect("audit items");
    assert!(items.iter().any(|item| {
        item["action"] == "memory.retrieve"
            && item["memoryId"] == memory_id
            && item["memoryText"] == "The user goes by Rodriguez."
    }));
}

#[tokio::test]
async fn search_records_prompt_injection_memory_ids_without_prompt_text() {
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
        .expect("create")
        .json::<serde_json::Value>()
        .await
        .expect("create json");
    let memory_id = created["id"].as_str().expect("memory id");

    let searched = client
        .post(format!("{}/v1/memory/search", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "query": "How do we check local service health?",
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1",
                "agentId": "agent-1",
                "sessionId": "session-1"
            },
            "turnId": "turn-42"
        }))
        .send()
        .await
        .expect("search")
        .json::<serde_json::Value>()
        .await
        .expect("search json");
    assert_eq!(searched["items"].as_array().unwrap().len(), 1);

    let audit_pool = memory_core::db::sqlite::open(temp.path())
        .await
        .expect("audit db");
    let injection = sqlx::query_as::<_, (String, String, String, String)>(
        "select session_id, turn_id, memory_ids_json, injected_text_hash from prompt_injections",
    )
    .fetch_one(&audit_pool)
    .await
    .expect("prompt injection");
    assert_eq!(injection.0, "session-1");
    assert_eq!(injection.1, "turn-42");
    assert!(injection.2.contains(memory_id));
    assert!(!injection
        .3
        .contains("How do we check local service health?"));
    assert!(!injection
        .3
        .contains("Use curl for local service health checks."));
}

#[tokio::test]
async fn search_records_prompt_injection_with_requested_profile_limit() {
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
            "text": "The user goes by Rodriguez.",
            "pinned": true,
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
        .expect("create pinned memory")
        .json::<serde_json::Value>()
        .await
        .expect("create pinned memory json");
    let memory_id = created["id"].as_str().expect("memory id");

    for (turn_id, pinned_profile_limit) in [("turn-profile-off", 0), ("turn-profile-on", 4)] {
        let searched = client
            .post(format!("{}/v1/memory/search", state.base_url))
            .bearer_auth("test-token")
            .json(&serde_json::json!({
                "query": "unrelated setup question",
                "scope": {
                    "userId": "local-user",
                    "workspaceId": "workspace-1",
                    "repoId": "repo-1",
                    "agentId": "agent-1",
                    "sessionId": "session-1"
                },
                "turnId": turn_id,
                "pinnedProfileLimit": pinned_profile_limit
            }))
            .send()
            .await
            .expect("search")
            .json::<serde_json::Value>()
            .await
            .expect("search json");
        assert_eq!(searched["items"][0]["id"], memory_id);
        assert_eq!(searched["items"][0]["metadata"]["pinned"], true);
    }

    let audit_pool = memory_core::db::sqlite::open(temp.path())
        .await
        .expect("audit db");
    let injections = sqlx::query_as::<_, (String, String)>(
        "select turn_id, injected_text_hash from prompt_injections order by turn_id asc",
    )
    .fetch_all(&audit_pool)
    .await
    .expect("prompt injections");
    assert_eq!(injections.len(), 2);
    assert_ne!(injections[0].1, injections[1].1);
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
fn formatter_groups_pinned_profile_memory_before_retrieved_memory() {
    let formatted = memory_core::memory::formatter::format_context_items(
        &[
            memory_core::memory::formatter::ContextItem {
                kind: "architecture_decision",
                scope: Some("repo"),
                text: "Rust owns memory storage.",
                pinned: false,
            },
            memory_core::memory::formatter::ContextItem {
                kind: "user_preference",
                scope: Some("global"),
                text: "用户称呼是 Rodriguez。",
                pinned: true,
            },
        ],
        4,
    );

    assert!(formatted.contains("<profile_memory>"));
    assert!(formatted.contains("Block user_profile: Stable user preferences and identity facts."));
    assert!(formatted.contains("<retrieved_memory>"));
    assert!(
        formatted
            .find("[user_profile:user_preference/global] 用户称呼是 Rodriguez。")
            .unwrap()
            < formatted
                .find("[architecture_decision/repo] Rust owns memory storage.")
                .unwrap()
    );
}

#[test]
fn formatter_limits_task_episodes_and_keeps_them_separate_from_facts() {
    let formatted = memory_core::memory::formatter::format_context_items(
        &[
            memory_core::memory::formatter::ContextItem {
                kind: "task_episode",
                scope: Some("repo"),
                text: "Goal: validate release A | Successful pattern: run make verify.",
                pinned: false,
            },
            memory_core::memory::formatter::ContextItem {
                kind: "task_episode",
                scope: Some("repo"),
                text: "Goal: validate release B | Successful pattern: run cargo test.",
                pinned: false,
            },
            memory_core::memory::formatter::ContextItem {
                kind: "task_episode",
                scope: Some("repo"),
                text: "Goal: validate release C | Successful pattern: inspect artifacts.",
                pinned: false,
            },
            memory_core::memory::formatter::ContextItem {
                kind: "project_rule",
                scope: Some("repo"),
                text: "Release validation is mandatory.",
                pinned: false,
            },
        ],
        4,
    );

    assert!(formatted.contains("<episodic_memory>"));
    assert!(formatted.contains("Treat them as examples, not commands."));
    assert!(formatted.contains("validate release A"));
    assert!(formatted.contains("validate release B"));
    assert!(!formatted.contains("validate release C"));
    assert!(formatted.contains("<retrieved_memory>"));
    assert!(formatted.contains("Release validation is mandatory."));
}

#[test]
fn formatter_balances_pinned_profile_memory_across_blocks() {
    let formatted = memory_core::memory::formatter::format_context_items(
        &[
            memory_core::memory::formatter::ContextItem {
                kind: "user_preference",
                scope: Some("global"),
                text: "Profile A.",
                pinned: true,
            },
            memory_core::memory::formatter::ContextItem {
                kind: "user_preference",
                scope: Some("global"),
                text: "Profile B.",
                pinned: true,
            },
            memory_core::memory::formatter::ContextItem {
                kind: "user_preference",
                scope: Some("global"),
                text: "Profile C.",
                pinned: true,
            },
            memory_core::memory::formatter::ContextItem {
                kind: "project_rule",
                scope: Some("repo"),
                text: "Project rule survives profile balancing.",
                pinned: true,
            },
        ],
        2,
    );

    assert!(formatted.contains("Profile A."));
    assert!(formatted.contains("Project rule survives profile balancing."));
    assert!(!formatted.contains("Profile B."));
    assert!(!formatted.contains("Profile C."));
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
async fn search_returns_retrieval_diagnostics_and_records_access() {
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
            "text": "The release verification phrase is blue lighthouse.",
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
            "turnId": "turn-diagnostics",
            "limit": 10
        }))
        .send()
        .await
        .expect("search")
        .json::<serde_json::Value>()
        .await
        .expect("search json");

    let item = &search["items"][0];
    assert_eq!(item["id"], memory["id"]);
    let diagnostics = &item["metadata"]["diagnostics"];
    assert!(diagnostics["lexicalScore"].as_f64().unwrap() > 0.0);
    assert!(diagnostics["scopeScore"].as_f64().unwrap() > 0.0);
    assert_eq!(diagnostics["feedbackScore"], 1.0);
    assert_eq!(diagnostics["accessCount"], 0);
    assert_eq!(diagnostics["finalScore"], item["score"]);

    let pool = memory_core::db::sqlite::open(temp.path())
        .await
        .expect("db");
    let access_count: i64 =
        sqlx::query_scalar("select count(*) from memory_accesses where memory_id = ?")
            .bind(memory["id"].as_str().unwrap())
            .fetch_one(&pool)
            .await
            .expect("access count");
    assert_eq!(access_count, 1);
}

#[tokio::test]
async fn repeated_access_promotes_stable_memory_to_profile_layer() {
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
            "text": "The release verification phrase is blue lighthouse.",
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

    for turn_index in 0..3 {
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
                "turnId": format!("turn-access-{turn_index}"),
                "limit": 10
            }))
            .send()
            .await
            .expect("search")
            .json::<serde_json::Value>()
            .await
            .expect("search json");
        assert_eq!(search["items"][0]["id"], memory["id"]);
    }

    let unrelated = client
        .post(format!("{}/v1/memory/search", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "query": "mobile release checklist",
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
        .expect("unrelated search")
        .json::<serde_json::Value>()
        .await
        .expect("unrelated json");
    assert_eq!(unrelated["items"][0]["id"], memory["id"]);
    assert_eq!(unrelated["items"][0]["metadata"]["pinned"], true);
    assert_eq!(
        unrelated["items"][0]["metadata"]["diagnostics"]["pinnedLayer"],
        true
    );

    let pool = memory_core::db::sqlite::open(temp.path())
        .await
        .expect("db");
    let pinned_value: i64 = sqlx::query_scalar("select pinned from memory_items where id = ?")
        .bind(memory["id"].as_str().unwrap())
        .fetch_one(&pool)
        .await
        .expect("pinned value");
    assert_eq!(pinned_value, 1);
    let promote_audit_count: i64 = sqlx::query_scalar(
        "select count(*) from memory_audit_log where action = 'memory.promote' and memory_id = ?",
    )
    .bind(memory["id"].as_str().unwrap())
    .fetch_one(&pool)
    .await
    .expect("promote audit count");
    assert_eq!(promote_audit_count, 1);
}

#[tokio::test]
async fn negative_feedback_blocks_access_based_profile_promotion() {
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
            "text": "The release verification phrase is blue lighthouse.",
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

    let feedback = client
        .post(format!(
            "{}/v1/memory/{}/feedback",
            state.base_url,
            memory["id"].as_str().unwrap()
        ))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "rating": "not_relevant",
            "turnId": "turn-negative",
            "reason": "This rule should not be treated as durable context."
        }))
        .send()
        .await
        .expect("feedback");
    assert_eq!(feedback.status(), reqwest::StatusCode::OK);

    for turn_index in 0..3 {
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
                "turnId": format!("turn-negative-access-{turn_index}"),
                "limit": 10
            }))
            .send()
            .await
            .expect("search")
            .json::<serde_json::Value>()
            .await
            .expect("search json");
        assert_eq!(search["items"][0]["id"], memory["id"]);
    }

    let unrelated = client
        .post(format!("{}/v1/memory/search", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "query": "mobile release checklist",
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
        .expect("unrelated search")
        .json::<serde_json::Value>()
        .await
        .expect("unrelated json");
    for item in unrelated["items"].as_array().unwrap() {
        assert_ne!(item["metadata"]["pinned"], true);
        assert_ne!(item["metadata"]["diagnostics"]["pinnedLayer"], true);
    }

    let pool = memory_core::db::sqlite::open(temp.path())
        .await
        .expect("db");
    let pinned_value: i64 = sqlx::query_scalar("select pinned from memory_items where id = ?")
        .bind(memory["id"].as_str().unwrap())
        .fetch_one(&pool)
        .await
        .expect("pinned value");
    assert_eq!(pinned_value, 0);
    let promote_audit_count: i64 = sqlx::query_scalar(
        "select count(*) from memory_audit_log where action = 'memory.promote' and memory_id = ?",
    )
    .bind(memory["id"].as_str().unwrap())
    .fetch_one(&pool)
    .await
    .expect("promote audit count");
    assert_eq!(promote_audit_count, 0);
}

#[tokio::test]
async fn search_decay_demotes_long_unused_memory_without_deleting_it() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    let recent = client
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "project_rule",
            "scope": "repo",
            "text": "The verification phrase is blue lighthouse.",
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
        .expect("create recent")
        .json::<serde_json::Value>()
        .await
        .expect("recent json");
    let stale = client
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "project_rule",
            "scope": "repo",
            "text": "The verification phrase is blue lighthouse.",
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
        .expect("create stale")
        .json::<serde_json::Value>()
        .await
        .expect("stale json");

    let pool = memory_core::db::sqlite::open(temp.path())
        .await
        .expect("db");
    sqlx::query("update memory_items set updated_at = 1 where id = ?")
        .bind(recent["id"].as_str().unwrap())
        .execute(&pool)
        .await
        .expect("age recent");
    sqlx::query("update memory_items set updated_at = 2 where id = ?")
        .bind(stale["id"].as_str().unwrap())
        .execute(&pool)
        .await
        .expect("freshen stale");

    const NOW: i64 = 1_700_000_000_000;
    const DAY_MS: i64 = 86_400_000;
    sqlx::query(
        "insert into memory_accesses (id, memory_id, session_id, turn_id, accessed_at)
         values (?, ?, ?, ?, ?)",
    )
    .bind("access_recent")
    .bind(recent["id"].as_str().unwrap())
    .bind("session-1")
    .bind("turn-recent")
    .bind(NOW - 2 * DAY_MS)
    .execute(&pool)
    .await
    .expect("insert recent access");
    sqlx::query(
        "insert into memory_accesses (id, memory_id, session_id, turn_id, accessed_at)
         values (?, ?, ?, ?, ?)",
    )
    .bind("access_stale")
    .bind(stale["id"].as_str().unwrap())
    .bind("session-1")
    .bind("turn-stale")
    .bind(NOW - 120 * DAY_MS)
    .execute(&pool)
    .await
    .expect("insert stale access");

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
            "referenceTime": NOW,
            "limit": 2
        }))
        .send()
        .await
        .expect("search")
        .json::<serde_json::Value>()
        .await
        .expect("search json");

    assert_eq!(search["items"].as_array().unwrap().len(), 2);
    assert_eq!(search["items"][0]["id"], recent["id"]);
    assert_eq!(search["items"][1]["id"], stale["id"]);
    let recent_diagnostics = &search["items"][0]["metadata"]["diagnostics"];
    let stale_diagnostics = &search["items"][1]["metadata"]["diagnostics"];
    assert!(
        recent_diagnostics["recencyScore"].as_f64().unwrap()
            > stale_diagnostics["recencyScore"].as_f64().unwrap()
    );
    assert!(
        stale_diagnostics["decayScore"].as_f64().unwrap() < 1.0,
        "stale memory remains searchable but receives a low-impact decay score"
    );
}

#[tokio::test]
async fn memory_feedback_demotes_not_relevant_search_results() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    let good = client
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "project_rule",
            "scope": "repo",
            "text": "The verification phrase is blue lighthouse.",
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
        .expect("create good")
        .json::<serde_json::Value>()
        .await
        .expect("good json");
    let bad = client
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "project_rule",
            "scope": "repo",
            "text": "The verification phrase is blue lighthouse.",
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
        .expect("create bad")
        .json::<serde_json::Value>()
        .await
        .expect("bad json");

    let pool = memory_core::db::sqlite::open(temp.path())
        .await
        .expect("db");
    sqlx::query("update memory_items set updated_at = 1 where id = ?")
        .bind(good["id"].as_str().unwrap())
        .execute(&pool)
        .await
        .expect("age good");
    sqlx::query("update memory_items set updated_at = 2 where id = ?")
        .bind(bad["id"].as_str().unwrap())
        .execute(&pool)
        .await
        .expect("freshen bad");

    let before = client
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
            "limit": 2
        }))
        .send()
        .await
        .expect("search before")
        .json::<serde_json::Value>()
        .await
        .expect("before json");
    assert_eq!(before["items"][0]["id"], bad["id"]);

    let feedback = client
        .post(format!(
            "{}/v1/memory/{}/feedback",
            state.base_url,
            bad["id"].as_str().unwrap()
        ))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "rating": "not_relevant",
            "turnId": "turn-feedback",
            "reason": "The duplicate was not useful in this answer."
        }))
        .send()
        .await
        .expect("feedback");
    assert_eq!(feedback.status(), reqwest::StatusCode::OK);

    let after = client
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
            "limit": 2
        }))
        .send()
        .await
        .expect("search after")
        .json::<serde_json::Value>()
        .await
        .expect("after json");
    assert_eq!(after["items"][0]["id"], good["id"]);
    assert!(
        after["items"][1]["metadata"]["diagnostics"]["feedbackScore"]
            .as_f64()
            .unwrap()
            < 1.0
    );

    let audit_count: i64 = sqlx::query_scalar(
        "select count(*) from memory_audit_log where action = 'memory.feedback' and memory_id = ?",
    )
    .bind(bad["id"].as_str().unwrap())
    .fetch_one(&pool)
    .await
    .expect("feedback audit count");
    assert_eq!(audit_count, 1);
}

#[tokio::test]
async fn repeated_not_relevant_feedback_disables_memory() {
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
            "text": "The verification phrase is blue lighthouse.",
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
    let memory_id = memory["id"].as_str().unwrap();

    for turn_id in ["turn-feedback-1", "turn-feedback-2"] {
        let feedback = client
            .post(format!("{}/v1/memory/{memory_id}/feedback", state.base_url))
            .bearer_auth("test-token")
            .json(&serde_json::json!({
                "rating": "not_relevant",
                "turnId": turn_id,
                "reason": "This memory was not useful for the answer."
            }))
            .send()
            .await
            .expect("feedback");
        assert_eq!(feedback.status(), reqwest::StatusCode::OK);
    }

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
            "limit": 10
        }))
        .send()
        .await
        .expect("search")
        .json::<serde_json::Value>()
        .await
        .expect("search json");
    assert_eq!(search["items"].as_array().unwrap().len(), 0);

    let pool = memory_core::db::sqlite::open(temp.path())
        .await
        .expect("db");
    let (status, pinned, valid_until): (String, i64, Option<i64>) =
        sqlx::query_as("select status, pinned, valid_until from memory_items where id = ?")
            .bind(memory_id)
            .fetch_one(&pool)
            .await
            .expect("stored memory");
    assert_eq!(status, "disabled");
    assert_eq!(pinned, 0);
    assert!(valid_until.is_some());

    let disable_payload_json: String = sqlx::query_scalar(
        "select payload_json from memory_audit_log
         where action = 'memory.disable' and memory_id = ?
         order by created_at desc
         limit 1",
    )
    .bind(memory_id)
    .fetch_one(&pool)
    .await
    .expect("disable audit payload");
    let disable_payload: serde_json::Value =
        serde_json::from_str(&disable_payload_json).expect("disable payload json");
    assert_eq!(disable_payload["reason"], "repeated_not_relevant_feedback");
    assert_eq!(disable_payload["notRelevantCount"], 2);
    assert_eq!(disable_payload["helpfulCount"], 0);
}

#[tokio::test]
async fn search_demotes_memories_that_expired_before_reference_time() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    let current = client
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "project_rule",
            "scope": "repo",
            "text": "The deployment target is blue lighthouse.",
            "validFrom": 2_000,
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
        .expect("create current")
        .json::<serde_json::Value>()
        .await
        .expect("current json");
    let expired = client
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "project_rule",
            "scope": "repo",
            "text": "The deployment target is blue lighthouse.",
            "validFrom": 1_000,
            "validUntil": 1_500,
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
        .expect("create expired")
        .json::<serde_json::Value>()
        .await
        .expect("expired json");

    let pool = memory_core::db::sqlite::open(temp.path())
        .await
        .expect("db");
    sqlx::query("update memory_items set updated_at = 1 where id = ?")
        .bind(current["id"].as_str().unwrap())
        .execute(&pool)
        .await
        .expect("age current");
    sqlx::query("update memory_items set updated_at = 2 where id = ?")
        .bind(expired["id"].as_str().unwrap())
        .execute(&pool)
        .await
        .expect("freshen expired");

    let search = client
        .post(format!("{}/v1/memory/search", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "query": "blue lighthouse deployment target",
            "scope": {
                "userId": "local-user",
                "workspaceId": "workspace-1",
                "repoId": "repo-1",
                "agentId": "agent-1",
                "sessionId": "session-1"
            },
            "referenceTime": 2_500,
            "limit": 2
        }))
        .send()
        .await
        .expect("search")
        .json::<serde_json::Value>()
        .await
        .expect("search json");

    assert_eq!(search["items"][0]["id"], current["id"]);
    assert_eq!(search["items"][1]["id"], expired["id"]);
    assert!(
        search["items"][1]["metadata"]["diagnostics"]["temporalScore"]
            .as_f64()
            .unwrap()
            < 1.0
    );
}

#[tokio::test]
async fn search_uses_explicit_entities_even_when_text_does_not_match() {
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
            "text": "Use the user's preferred display name in greetings.",
            "entities": [
                {"text": "Rodriguez", "type": "person"},
                {"text": "display-name", "type": "tag"}
            ],
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

    let search = client
        .post(format!("{}/v1/memory/search", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "query": "Rodriguez 是谁",
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
    let item = &search["items"][0];
    assert_eq!(item["id"], memory["id"]);
    assert_eq!(item["metadata"]["entities"][0]["text"], "Rodriguez");
    assert_eq!(item["metadata"]["entities"][1]["type"], "tag");
    assert!(
        item["metadata"]["diagnostics"]["entityScore"]
            .as_f64()
            .unwrap()
            > 0.0
    );
    assert_eq!(item["metadata"]["diagnostics"]["lexicalScore"], 0.0);
}

#[tokio::test]
async fn search_uses_cjk_ngrams_for_chinese_question_queries() {
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
            "text": "本项目的验证暗号是蓝色灯塔-43130。",
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

    let search = client
        .post(format!("{}/v1/memory/search", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "query": "本项目的验证暗号是什么？",
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
    assert!(
        search["items"][0]["metadata"]["diagnostics"]["lexicalScore"]
            .as_f64()
            .unwrap()
            > 0.0
    );
}

#[tokio::test]
async fn approved_candidate_entities_are_indexed_for_search() {
    let temp = tempfile::tempdir().expect("tempdir");
    let state = memory_core::test_support::spawn_test_daemon(temp.path(), "test-token")
        .await
        .expect("daemon");
    let client = reqwest::Client::new();

    let created = client
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
                    "kind": "user_preference",
                    "scope": "global",
                    "text": "Use the user's preferred display name in greetings.",
                    "confidence": 0.91,
                    "reason": "User supplied a durable display-name preference.",
                    "entities": [
                        {"text": "Rodriguez", "type": "person"}
                    ]
                }
            ]
        }))
        .send()
        .await
        .expect("extract candidates")
        .json::<serde_json::Value>()
        .await
        .expect("candidate json");
    let candidate_id = created["candidates"][0]["id"].as_str().unwrap();

    let approved = client
        .post(format!(
            "{}/v1/memory/candidates/{candidate_id}/approve",
            state.base_url
        ))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "user_preference",
            "scope": "global",
            "text": "Use the user's preferred display name in greetings."
        }))
        .send()
        .await
        .expect("approve candidate")
        .json::<serde_json::Value>()
        .await
        .expect("approved json");

    let search = client
        .post(format!("{}/v1/memory/search", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "query": "Rodriguez 是谁",
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
    assert_eq!(search["items"][0]["id"], approved["id"]);
    assert_eq!(
        search["items"][0]["metadata"]["entities"][0]["text"],
        "Rodriguez"
    );
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
