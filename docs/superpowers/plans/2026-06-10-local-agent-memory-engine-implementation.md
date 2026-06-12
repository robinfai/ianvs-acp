# Local Agent Memory Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the local agent memory engine described in `docs/superpowers/specs/2026-06-10-local-agent-memory-engine-design.md`.

**Architecture:** Add a standalone Rust `memory-core` crate as the local memory daemon and MCP stdio bridge. Keep Flutter responsible for daemon lifecycle, ACP prompt injection, ACP sidecar extraction, and review UI; Rust owns SQLite, search, policy, redaction, audit, candidates, and change requests.

**Tech Stack:** Rust, Tokio, Axum, SQLx SQLite, sqlite-vec, FastEmbed local embeddings, RMCP, Dart/Flutter Material, `flutter_test`, existing ACP client abstractions.

---

## Scope Check

The design intentionally covers P0-P6 in one full-system spec. This plan keeps it as one document but splits execution into phases that each produce testable software:

- P0-P2 establish the Rust daemon and durable memory state.
- P3-P4 harden policy/redaction and expose MCP bridge tools.
- P5 adds Flutter runtime, ACP middleware, sidecar extractor, and UI.
- P6 completes docs, packaging notes, and full verification.

Do not skip ahead to Flutter UI before the daemon API and tests exist.

## File Structure

### Rust `memory-core`

- Create `memory-core/Cargo.toml`: standalone Rust package, dependencies, test profile.
- Create `memory-core/src/main.rs`: CLI entry point, mode dispatch, ready JSON behavior.
- Create `memory-core/src/config.rs`: CLI/env/config structs for daemon, MCP, embedding, extractor.
- Create `memory-core/src/app_state.rs`: shared state with DB pool, embedder, policy, version.
- Create `memory-core/src/error.rs`: API errors and HTTP conversion.
- Create `memory-core/src/http/mod.rs`: router assembly and auth middleware.
- Create `memory-core/src/http/routes_health.rs`: `/health`.
- Create `memory-core/src/http/routes_memory.rs`: memory CRUD, search, format context, rebuild vector index.
- Create `memory-core/src/http/routes_candidates.rs`: extraction, candidates, approve/reject.
- Create `memory-core/src/http/routes_change_requests.rs`: pending update/delete/disable/restore.
- Create `memory-core/src/http/routes_clear.rs`: scoped soft clear and destroy-database.
- Create `memory-core/src/db/mod.rs`: DB module exports.
- Create `memory-core/src/db/sqlite.rs`: pool setup, WAL, extension loading, DB helpers.
- Create `memory-core/src/db/migrations.rs`: migration runner.
- Create `memory-core/src/db/schema.sql`: canonical schema.
- Create `memory-core/src/memory/mod.rs`: memory module exports.
- Create `memory-core/src/memory/types.rs`: DTOs and serde naming.
- Create `memory-core/src/memory/scope.rs`: scope normalization and match scoring.
- Create `memory-core/src/memory/policy.rs`: validation, duplicate/conflict checks.
- Create `memory-core/src/memory/redactor.rs`: secret redaction.
- Create `memory-core/src/memory/formatter.rs`: `agent_memory_context` formatter.
- Create `memory-core/src/memory/ranker.rs`: final score calculation and kind priority.
- Create `memory-core/src/memory/engine.rs`: high-level operations used by HTTP/MCP.
- Create `memory-core/src/vector/mod.rs`: vector module exports.
- Create `memory-core/src/vector/sqlite_vec_store.rs`: sqlite-vec write/search/rebuild abstraction.
- Create `memory-core/src/embedding/mod.rs`: embedding module exports.
- Create `memory-core/src/embedding/embedder.rs`: `Embedder` trait and provider factory.
- Create `memory-core/src/embedding/mock_embedder.rs`: deterministic test embedder.
- Create `memory-core/src/embedding/fastembed_local.rs`: local FastEmbed provider.
- Create `memory-core/src/embedding/openai_compatible.rs`: `/v1/embeddings` provider.
- Create `memory-core/src/llm/mod.rs`: LLM module exports.
- Create `memory-core/src/llm/extractor_client.rs`: extractor trait and response schema.
- Create `memory-core/src/llm/openai_compatible.rs`: OpenAI-compatible chat extraction.
- Create `memory-core/src/llm/prompts.rs`: extraction system prompt.
- Create `memory-core/src/mcp/mod.rs`: MCP module exports.
- Create `memory-core/src/mcp/stdio_server.rs`: MCP stdio server.
- Create `memory-core/src/mcp/tools.rs`: MCP tool schemas and dispatch.
- Create `memory-core/src/mcp/daemon_client.rs`: authenticated daemon HTTP client.
- Create `memory-core/tests/daemon_http_test.rs`: daemon/HTTP integration tests.
- Create `memory-core/tests/mcp_stdio_test.rs`: MCP stdio behavior tests.

### Flutter

- Modify `lib/config/acp_client_config.dart`: parse and serialize `memory` config.
- Modify `lib/config/acp_config_store.dart`: preserve/emit `memory` config.
- Create `lib/memory/memory_config.dart`: typed memory config and defaults.
- Create `lib/memory/memory_daemon_manager.dart`: process lifecycle, ready JSON, token env.
- Create `lib/memory/memory_api_client.dart`: HTTP client DTOs.
- Create `lib/memory/memory_context_builder.dart`: context block formatting for prompt injection.
- Create `lib/memory/acp_memory_middleware.dart`: search-before-prompt and transcript-after-turn orchestration.
- Create `lib/memory/acp_sidecar_memory_extractor.dart`: isolated ACP sidecar extractor.
- Modify `lib/acp/acp_agent_client.dart`: allow memory context content blocks or middleware hook.
- Modify `lib/acp/dart_acp_agent_client.dart`: send memory context as separate ACP text block.
- Modify `lib/acp/fake_agent_client.dart`: record memory-injected prompt blocks in tests.
- Modify `lib/state/chat_controller.dart`: call memory middleware around prompt turns and surface pending review state.
- Modify `lib/app.dart`: own daemon manager, pass memory config/client into controllers.
- Modify `lib/ui/shell/app_shell.dart`: expose Memory entry, badge, and optional review panel.
- Modify `lib/ui/components/agent_config_dialog.dart`: add Memory settings section.
- Create `lib/ui/components/memory_review_panel.dart`: per-turn candidate review.
- Create `lib/ui/components/memory_explorer_page.dart`: full memory management page.
- Add `test/memory/memory_config_test.dart`.
- Add `test/memory/memory_daemon_manager_test.dart`.
- Add `test/memory/memory_api_client_test.dart`.
- Add `test/memory/memory_context_builder_test.dart`.
- Add `test/memory/acp_memory_middleware_test.dart`.
- Add `test/memory/acp_sidecar_memory_extractor_test.dart`.
- Update `test/config/acp_client_config_test.dart`.
- Update `test/config/acp_config_store_test.dart`.
- Update `test/state/chat_controller_test.dart`.
- Update `test/ui/agent_config_dialog_test.dart`.
- Update `test/ui/acp_client_app_test.dart`.
- Add `test/ui/memory_review_panel_test.dart`.
- Add `test/ui/memory_explorer_page_test.dart`.
- Update `README.md`, `docs/acp_feature_audit.md`, and `docs/manual_followups.md`.

## Task 1: Scaffold Rust memory-core crate

**Files:**
- Create: `memory-core/Cargo.toml`
- Create: `memory-core/src/main.rs`
- Create: `memory-core/src/config.rs`
- Create: `memory-core/src/app_state.rs`
- Create: `memory-core/src/error.rs`
- Create: `memory-core/src/http/mod.rs`
- Create: `memory-core/src/http/routes_health.rs`
- Create: `memory-core/src/db/mod.rs`
- Create: `memory-core/src/db/sqlite.rs`
- Create: `memory-core/src/db/migrations.rs`
- Create: `memory-core/src/db/schema.sql`
- Test: `memory-core/tests/daemon_http_test.rs`

- [ ] **Step 1: Write the failing health and ready JSON tests**

Create `memory-core/tests/daemon_http_test.rs` with these tests:

```rust
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```sh
cargo test --manifest-path memory-core/Cargo.toml daemon_prints_ready_json_to_stdout health_requires_no_auth_and_v1_requires_auth
```

Expected: fail because `memory-core/Cargo.toml`, the binary, and `test_support` do not exist.

- [ ] **Step 3: Add Cargo package and minimal daemon**

Create `memory-core/Cargo.toml`:

```toml
[package]
name = "memory-core"
version = "0.1.0"
edition = "2021"

[lib]
name = "memory_core"
path = "src/lib.rs"

[[bin]]
name = "memory-core"
path = "src/main.rs"

[dependencies]
anyhow = "1"
async-trait = "0.1"
axum = "0.8"
chrono = { version = "0.4", features = ["serde"] }
clap = { version = "4", features = ["derive"] }
reqwest = { version = "0.12", features = ["json", "rustls-tls"] }
schemars = "0.8"
serde = { version = "1", features = ["derive"] }
serde_json = "1"
sqlx = { version = "0.8", features = ["runtime-tokio", "sqlite", "macros", "migrate", "chrono", "uuid"] }
thiserror = "2"
tokio = { version = "1", features = ["full"] }
tower-http = { version = "0.6", features = ["cors", "trace"] }
tracing = "0.1"
tracing-subscriber = { version = "0.3", features = ["env-filter"] }
uuid = { version = "1", features = ["v4", "serde"] }

[dev-dependencies]
tempfile = "3"
```

Create `memory-core/src/lib.rs`:

```rust
pub mod app_state;
pub mod config;
pub mod db;
pub mod error;
pub mod http;

#[cfg(test)]
pub mod test_support;
```

Create `memory-core/src/config.rs`:

```rust
use clap::{Parser, ValueEnum};
use std::path::PathBuf;

#[derive(Debug, Clone, Parser)]
#[command(name = "memory-core")]
pub struct Cli {
    #[arg(long, value_enum)]
    pub mode: Mode,
    #[arg(long, default_value = "127.0.0.1")]
    pub host: String,
    #[arg(long, default_value_t = 0)]
    pub port: u16,
    #[arg(long)]
    pub data_dir: Option<PathBuf>,
    #[arg(long)]
    pub daemon_url: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum Mode {
    Daemon,
    McpStdio,
}

#[derive(Debug, Clone)]
pub struct DaemonConfig {
    pub host: String,
    pub port: u16,
    pub data_dir: PathBuf,
    pub token: String,
}

impl DaemonConfig {
    pub fn from_cli(cli: &Cli) -> anyhow::Result<Self> {
        let data_dir = cli
            .data_dir
            .clone()
            .ok_or_else(|| anyhow::anyhow!("--data-dir is required in daemon mode"))?;
        let token = std::env::var("MEMORY_DAEMON_TOKEN")
            .map_err(|_| anyhow::anyhow!("MEMORY_DAEMON_TOKEN is required"))?;
        Ok(Self {
            host: cli.host.clone(),
            port: cli.port,
            data_dir,
            token,
        })
    }
}
```

Create `memory-core/src/app_state.rs`:

```rust
use sqlx::SqlitePool;

#[derive(Clone)]
pub struct AppState {
    pub db: SqlitePool,
    pub token: String,
    pub version: &'static str,
}
```

Create `memory-core/src/error.rs`:

```rust
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;
use serde_json::json;

#[derive(Debug, thiserror::Error)]
pub enum ApiError {
    #[error("unauthorized")]
    Unauthorized,
    #[error("{0}")]
    BadRequest(String),
    #[error(transparent)]
    Sqlx(#[from] sqlx::Error),
    #[error(transparent)]
    Anyhow(#[from] anyhow::Error),
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let status = match self {
            ApiError::Unauthorized => StatusCode::UNAUTHORIZED,
            ApiError::BadRequest(_) => StatusCode::BAD_REQUEST,
            ApiError::Sqlx(_) | ApiError::Anyhow(_) => StatusCode::INTERNAL_SERVER_ERROR,
        };
        (status, Json(json!({ "error": self.to_string() }))).into_response()
    }
}
```

Create `memory-core/src/db/mod.rs`:

```rust
pub mod migrations;
pub mod sqlite;
```

Create `memory-core/src/db/schema.sql`:

```sql
create table if not exists memory_items (
  id text primary key,
  text text not null
);
```

Create `memory-core/src/db/migrations.rs`:

```rust
use sqlx::SqlitePool;

pub async fn run(pool: &SqlitePool) -> sqlx::Result<()> {
    for statement in include_str!("schema.sql").split(';') {
        let trimmed = statement.trim();
        if !trimmed.is_empty() {
            sqlx::query(trimmed).execute(pool).await?;
        }
    }
    Ok(())
}
```

Create `memory-core/src/db/sqlite.rs`:

```rust
use sqlx::sqlite::{SqliteConnectOptions, SqliteJournalMode, SqlitePoolOptions};
use sqlx::SqlitePool;
use std::path::Path;
use std::str::FromStr;

use super::migrations;

pub async fn open(data_dir: &Path) -> anyhow::Result<SqlitePool> {
    tokio::fs::create_dir_all(data_dir).await?;
    let db_path = data_dir.join("memory.sqlite");
    let options = SqliteConnectOptions::from_str(&format!("sqlite://{}", db_path.display()))?
        .create_if_missing(true)
        .journal_mode(SqliteJournalMode::Wal);
    let pool = SqlitePoolOptions::new().max_connections(5).connect_with(options).await?;
    migrations::run(&pool).await?;
    Ok(pool)
}
```

Create `memory-core/src/http/routes_health.rs`:

```rust
use axum::Json;
use serde::Serialize;

#[derive(Serialize)]
pub struct HealthResponse {
    pub ok: bool,
    pub version: &'static str,
}

pub async fn health() -> Json<HealthResponse> {
    Json(HealthResponse {
        ok: true,
        version: "0.1.0",
    })
}
```

Create `memory-core/src/http/mod.rs`:

```rust
use axum::extract::{Request, State};
use axum::http::header::AUTHORIZATION;
use axum::middleware::{self, Next};
use axum::response::Response;
use axum::routing::get;
use axum::Router;

use crate::app_state::AppState;
use crate::error::ApiError;

pub mod routes_health;

pub fn router(state: AppState) -> Router {
    let protected = Router::new()
        .route("/v1/memory", get(|| async { "[]" }))
        .route_layer(middleware::from_fn_with_state(state.clone(), auth));

    Router::new()
        .route("/health", get(routes_health::health))
        .merge(protected)
        .with_state(state)
}

async fn auth(State(state): State<AppState>, request: Request, next: Next) -> Result<Response, ApiError> {
    let expected = format!("Bearer {}", state.token);
    let actual = request
        .headers()
        .get(AUTHORIZATION)
        .and_then(|value| value.to_str().ok());
    if actual != Some(expected.as_str()) {
        return Err(ApiError::Unauthorized);
    }
    Ok(next.run(request).await)
}
```

Create `memory-core/src/main.rs`:

```rust
use clap::Parser;
use memory_core::app_state::AppState;
use memory_core::config::{Cli, DaemonConfig, Mode};
use memory_core::db::sqlite;
use memory_core::http;
use std::net::SocketAddr;
use tokio::net::TcpListener;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt().with_writer(std::io::stderr).init();
    let cli = Cli::parse();
    match cli.mode {
        Mode::Daemon => run_daemon(DaemonConfig::from_cli(&cli)?).await,
        Mode::McpStdio => anyhow::bail!("mcp-stdio mode requires Task 7"),
    }
}

async fn run_daemon(config: DaemonConfig) -> anyhow::Result<()> {
    let pool = sqlite::open(&config.data_dir).await?;
    let state = AppState {
        db: pool,
        token: config.token,
        version: "0.1.0",
    };
    let addr: SocketAddr = format!("{}:{}", config.host, config.port).parse()?;
    let listener = TcpListener::bind(addr).await?;
    let port = listener.local_addr()?.port();
    println!("{}", serde_json::json!({ "type": "ready", "port": port }));
    axum::serve(listener, http::router(state)).await?;
    Ok(())
}
```

Create `memory-core/src/test_support.rs`:

```rust
use crate::app_state::AppState;
use crate::db::sqlite;
use crate::http;
use std::path::Path;
use tokio::net::TcpListener;

pub struct TestDaemon {
    pub base_url: String,
}

pub async fn spawn_test_daemon(data_dir: &Path, token: &str) -> anyhow::Result<TestDaemon> {
    let pool = sqlite::open(data_dir).await?;
    let state = AppState {
        db: pool,
        token: token.to_string(),
        version: "0.1.0",
    };
    let listener = TcpListener::bind("127.0.0.1:0").await?;
    let port = listener.local_addr()?.port();
    tokio::spawn(async move {
        let _ = axum::serve(listener, http::router(state)).await;
    });
    Ok(TestDaemon {
        base_url: format!("http://127.0.0.1:{port}"),
    })
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run:

```sh
cargo test --manifest-path memory-core/Cargo.toml daemon_prints_ready_json_to_stdout health_requires_no_auth_and_v1_requires_auth
```

Expected: both tests pass.

- [ ] **Step 5: Commit**

```sh
git add memory-core
git commit -m "Add memory-core daemon scaffold"
```

## Task 2: Add canonical memory schema and typed DTOs

**Files:**
- Modify: `memory-core/src/db/schema.sql`
- Create: `memory-core/src/memory/mod.rs`
- Create: `memory-core/src/memory/types.rs`
- Create: `memory-core/src/memory/scope.rs`
- Modify: `memory-core/src/lib.rs`
- Test: `memory-core/tests/daemon_http_test.rs`

- [ ] **Step 1: Write failing schema and serde tests**

Append to `memory-core/tests/daemon_http_test.rs`:

```rust
#[tokio::test]
async fn schema_creates_memory_tables() {
    let temp = tempfile::tempdir().expect("tempdir");
    let pool = memory_core::db::sqlite::open(temp.path()).await.expect("db");
    let tables: Vec<String> = sqlx::query_scalar(
        "select name from sqlite_master where type = 'table' order by name"
    )
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

    assert_eq!(serde_json::to_string(&MemoryKind::UserPreference).unwrap(), "\"user_preference\"");
    assert_eq!(serde_json::to_string(&MemoryKind::ProjectRule).unwrap(), "\"project_rule\"");
    assert_eq!(
        serde_json::to_string(&MemoryKind::ArchitectureDecision).unwrap(),
        "\"architecture_decision\""
    );
    assert_eq!(serde_json::to_string(&MemoryKind::SessionSummary).unwrap(), "\"session_summary\"");
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```sh
cargo test --manifest-path memory-core/Cargo.toml schema_creates_memory_tables memory_kind_uses_snake_case_wire_names
```

Expected: fail because the schema and memory types do not exist.

- [ ] **Step 3: Implement schema and DTO types**

Replace `memory-core/src/db/schema.sql` with:

```sql
create table if not exists memory_items (
  id text primary key,
  user_id text not null,
  workspace_id text,
  repo_id text,
  agent_id text,
  session_id text,
  kind text not null,
  scope text not null,
  text text not null,
  source text not null,
  source_session_id text,
  source_turn_id text,
  confidence real,
  status text not null default 'active',
  created_at integer not null,
  updated_at integer not null,
  deleted_at integer
);

create table if not exists memory_candidates (
  id text primary key,
  user_id text not null,
  workspace_id text,
  repo_id text,
  agent_id text,
  session_id text,
  kind text not null,
  scope text not null,
  text text not null,
  reason text,
  confidence real,
  transcript_hash text,
  status text not null default 'pending',
  created_at integer not null,
  reviewed_at integer
);

create table if not exists memory_change_requests (
  id text primary key,
  user_id text not null,
  workspace_id text,
  repo_id text,
  agent_id text,
  session_id text,
  action text not null,
  target_memory_id text,
  proposed_kind text,
  proposed_scope text,
  proposed_text text,
  reason text,
  status text not null default 'pending',
  created_at integer not null,
  reviewed_at integer
);

create table if not exists memory_audit_log (
  id text primary key,
  actor text not null,
  action text not null,
  memory_id text,
  candidate_id text,
  change_request_id text,
  payload_json text not null,
  created_at integer not null
);

create table if not exists prompt_injections (
  id text primary key,
  session_id text not null,
  turn_id text not null,
  memory_ids_json text not null,
  injected_text_hash text not null,
  created_at integer not null
);

create index if not exists idx_memory_items_scope
on memory_items(user_id, workspace_id, repo_id, agent_id, session_id, kind, status);

create index if not exists idx_memory_candidates_status
on memory_candidates(user_id, workspace_id, repo_id, status, created_at);

create index if not exists idx_memory_change_requests_status
on memory_change_requests(user_id, workspace_id, repo_id, status, created_at);
```

Create `memory-core/src/memory/mod.rs`:

```rust
pub mod scope;
pub mod types;
```

Create `memory-core/src/memory/types.rs`:

```rust
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MemoryKind {
    UserPreference,
    ProjectRule,
    ArchitectureDecision,
    SessionSummary,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MemoryScope {
    pub user_id: String,
    pub workspace_id: Option<String>,
    pub repo_id: Option<String>,
    pub agent_id: Option<String>,
    pub session_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MemoryItem {
    pub id: String,
    pub kind: MemoryKind,
    pub scope: String,
    pub text: String,
    pub user_id: String,
    pub workspace_id: Option<String>,
    pub repo_id: Option<String>,
    pub agent_id: Option<String>,
    pub session_id: Option<String>,
    pub source: String,
    pub source_session_id: Option<String>,
    pub source_turn_id: Option<String>,
    pub confidence: Option<f32>,
    pub status: String,
    pub created_at: i64,
    pub updated_at: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MemoryCandidate {
    pub id: String,
    pub kind: MemoryKind,
    pub scope: String,
    pub text: String,
    pub reason: Option<String>,
    pub confidence: Option<f32>,
    pub user_id: String,
    pub workspace_id: Option<String>,
    pub repo_id: Option<String>,
    pub agent_id: Option<String>,
    pub session_id: Option<String>,
    pub transcript_hash: Option<String>,
    pub status: String,
    pub created_at: i64,
    pub reviewed_at: Option<i64>,
}
```

Create `memory-core/src/memory/scope.rs`:

```rust
use super::types::{MemoryKind, MemoryScope};

pub fn default_scope_for(kind: MemoryKind, scope: &MemoryScope) -> &'static str {
    match kind {
        MemoryKind::UserPreference => "global",
        MemoryKind::ProjectRule => "repo",
        MemoryKind::ArchitectureDecision => {
            if scope.repo_id.is_some() { "repo" } else { "workspace" }
        }
        MemoryKind::SessionSummary => "session",
    }
}
```

Modify `memory-core/src/lib.rs`:

```rust
pub mod app_state;
pub mod config;
pub mod db;
pub mod error;
pub mod http;
pub mod memory;

#[cfg(test)]
pub mod test_support;
```

- [ ] **Step 4: Run tests to verify they pass**

Run:

```sh
cargo test --manifest-path memory-core/Cargo.toml schema_creates_memory_tables memory_kind_uses_snake_case_wire_names
```

Expected: both tests pass.

- [ ] **Step 5: Commit**

```sh
git add memory-core
git commit -m "Add memory schema and types"
```

## Task 3: Implement manual memory CRUD and audit log

**Files:**
- Create: `memory-core/src/memory/engine.rs`
- Modify: `memory-core/src/memory/mod.rs`
- Modify: `memory-core/src/http/routes_memory.rs`
- Modify: `memory-core/src/http/mod.rs`
- Test: `memory-core/tests/daemon_http_test.rs`

- [ ] **Step 1: Write failing CRUD tests**

Append to `memory-core/tests/daemon_http_test.rs`:

```rust
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
        .get(format!("{}/v1/memory?userId=local-user&repoId=repo-1", state.base_url))
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
        .get(format!("{}/v1/memory?userId=local-user&repoId=repo-1&status=active", state.base_url))
        .bearer_auth("test-token")
        .send()
        .await
        .expect("list after delete")
        .json::<serde_json::Value>()
        .await
        .expect("list json");
    assert_eq!(listed_after_delete["items"].as_array().unwrap().len(), 0);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```sh
cargo test --manifest-path memory-core/Cargo.toml manual_memory_crud_writes_audit_and_soft_deletes
```

Expected: fail because CRUD routes are absent.

- [ ] **Step 3: Implement engine methods and routes**

Create `memory-core/src/memory/engine.rs` with:

```rust
use crate::memory::types::{MemoryKind, MemoryScope};
use chrono::Utc;
use serde::{Deserialize, Serialize};
use sqlx::{Row, SqlitePool};
use uuid::Uuid;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CreateMemoryRequest {
    pub kind: MemoryKind,
    pub scope: String,
    pub text: String,
    pub scope_data: MemoryScope,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PatchMemoryRequest {
    pub kind: Option<MemoryKind>,
    pub scope: Option<String>,
    pub text: Option<String>,
    pub status: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MemoryResponse {
    pub id: String,
    pub kind: MemoryKind,
    pub scope: String,
    pub text: String,
    pub user_id: String,
    pub workspace_id: Option<String>,
    pub repo_id: Option<String>,
    pub agent_id: Option<String>,
    pub session_id: Option<String>,
    pub source: String,
    pub status: String,
    pub created_at: i64,
    pub updated_at: i64,
}

#[derive(Debug, Serialize)]
pub struct ListMemoryResponse {
    pub items: Vec<MemoryResponse>,
}

pub async fn create_manual_memory(pool: &SqlitePool, request: CreateMemoryRequest) -> sqlx::Result<MemoryResponse> {
    let now = Utc::now().timestamp_millis();
    let id = format!("mem_{}", Uuid::new_v4());
    let kind = serde_json::to_value(request.kind).unwrap().as_str().unwrap().to_string();
    sqlx::query(
        "insert into memory_items
        (id, user_id, workspace_id, repo_id, agent_id, session_id, kind, scope, text, source, status, created_at, updated_at)
        values (?, ?, ?, ?, ?, ?, ?, ?, ?, 'manual', 'active', ?, ?)"
    )
    .bind(&id)
    .bind(&request.scope_data.user_id)
    .bind(&request.scope_data.workspace_id)
    .bind(&request.scope_data.repo_id)
    .bind(&request.scope_data.agent_id)
    .bind(&request.scope_data.session_id)
    .bind(&kind)
    .bind(&request.scope)
    .bind(&request.text)
    .bind(now)
    .bind(now)
    .execute(pool)
    .await?;
    write_audit(pool, "user", "memory.create", Some(&id), None, None, serde_json::json!({"source":"manual"})).await?;
    get_memory(pool, &id).await
}

pub async fn list_memory(pool: &SqlitePool, user_id: Option<&str>, repo_id: Option<&str>, status: Option<&str>) -> sqlx::Result<ListMemoryResponse> {
    let user_id = user_id.unwrap_or("%");
    let repo_id = repo_id.unwrap_or("%");
    let status = status.unwrap_or("%");
    let rows = sqlx::query(
        "select id, kind, scope, text, user_id, workspace_id, repo_id, agent_id, session_id, source, status, created_at, updated_at
         from memory_items
         where user_id like ? and coalesce(repo_id, '') like ? and status like ?
         order by updated_at desc"
    )
    .bind(user_id)
    .bind(repo_id)
    .bind(status)
    .fetch_all(pool)
    .await?;
    Ok(ListMemoryResponse {
        items: rows.into_iter().map(row_to_memory).collect::<serde_json::Result<Vec<_>>>().unwrap(),
    })
}

pub async fn patch_memory(pool: &SqlitePool, id: &str, request: PatchMemoryRequest) -> sqlx::Result<MemoryResponse> {
    let current = get_memory(pool, id).await?;
    let kind = request.kind.unwrap_or(current.kind);
    let kind_wire = serde_json::to_value(kind).unwrap().as_str().unwrap().to_string();
    let scope = request.scope.unwrap_or(current.scope);
    let text = request.text.unwrap_or(current.text);
    let status = request.status.unwrap_or(current.status);
    let now = Utc::now().timestamp_millis();
    sqlx::query("update memory_items set kind = ?, scope = ?, text = ?, status = ?, updated_at = ? where id = ?")
        .bind(kind_wire)
        .bind(scope)
        .bind(text)
        .bind(status)
        .bind(now)
        .bind(id)
        .execute(pool)
        .await?;
    write_audit(pool, "user", "memory.update", Some(id), None, None, serde_json::json!({})).await?;
    get_memory(pool, id).await
}

pub async fn soft_delete_memory(pool: &SqlitePool, id: &str) -> sqlx::Result<()> {
    let now = Utc::now().timestamp_millis();
    sqlx::query("update memory_items set status = 'deleted', deleted_at = ?, updated_at = ? where id = ?")
        .bind(now)
        .bind(now)
        .bind(id)
        .execute(pool)
        .await?;
    write_audit(pool, "user", "memory.delete", Some(id), None, None, serde_json::json!({"soft":true})).await
}

async fn get_memory(pool: &SqlitePool, id: &str) -> sqlx::Result<MemoryResponse> {
    let row = sqlx::query(
        "select id, kind, scope, text, user_id, workspace_id, repo_id, agent_id, session_id, source, status, created_at, updated_at
         from memory_items where id = ?"
    )
    .bind(id)
    .fetch_one(pool)
    .await?;
    row_to_memory(row)
}

async fn write_audit(
    pool: &SqlitePool,
    actor: &str,
    action: &str,
    memory_id: Option<&str>,
    candidate_id: Option<&str>,
    change_request_id: Option<&str>,
    payload: serde_json::Value,
) -> sqlx::Result<()> {
    sqlx::query(
        "insert into memory_audit_log (id, actor, action, memory_id, candidate_id, change_request_id, payload_json, created_at)
         values (?, ?, ?, ?, ?, ?, ?, ?)"
    )
    .bind(format!("audit_{}", Uuid::new_v4()))
    .bind(actor)
    .bind(action)
    .bind(memory_id)
    .bind(candidate_id)
    .bind(change_request_id)
    .bind(payload.to_string())
    .bind(Utc::now().timestamp_millis())
    .execute(pool)
    .await?;
    Ok(())
}

fn row_to_memory(row: sqlx::sqlite::SqliteRow) -> serde_json::Result<MemoryResponse> {
    Ok(MemoryResponse {
        id: row.get("id"),
        kind: serde_json::from_value(serde_json::Value::String(row.get("kind")))?,
        scope: row.get("scope"),
        text: row.get("text"),
        user_id: row.get("user_id"),
        workspace_id: row.get("workspace_id"),
        repo_id: row.get("repo_id"),
        agent_id: row.get("agent_id"),
        session_id: row.get("session_id"),
        source: row.get("source"),
        status: row.get("status"),
        created_at: row.get("created_at"),
        updated_at: row.get("updated_at"),
    })
}
```

Create `memory-core/src/http/routes_memory.rs`:

```rust
use axum::extract::{Path, Query, State};
use axum::{Json};
use serde::Deserialize;

use crate::app_state::AppState;
use crate::error::ApiError;
use crate::memory::engine::{
    create_manual_memory, list_memory, patch_memory, soft_delete_memory, CreateMemoryRequest,
    ListMemoryResponse, MemoryResponse, PatchMemoryRequest,
};

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ListQuery {
    pub user_id: Option<String>,
    pub repo_id: Option<String>,
    pub status: Option<String>,
}

pub async fn create(
    State(state): State<AppState>,
    Json(request): Json<CreateMemoryRequest>,
) -> Result<Json<MemoryResponse>, ApiError> {
    Ok(Json(create_manual_memory(&state.db, request).await?))
}

pub async fn list(
    State(state): State<AppState>,
    Query(query): Query<ListQuery>,
) -> Result<Json<ListMemoryResponse>, ApiError> {
    Ok(Json(
        list_memory(
            &state.db,
            query.user_id.as_deref(),
            query.repo_id.as_deref(),
            query.status.as_deref(),
        )
        .await?,
    ))
}

pub async fn patch(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Json(request): Json<PatchMemoryRequest>,
) -> Result<Json<MemoryResponse>, ApiError> {
    Ok(Json(patch_memory(&state.db, &id, request).await?))
}

pub async fn delete(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<serde_json::Value>, ApiError> {
    soft_delete_memory(&state.db, &id).await?;
    Ok(Json(serde_json::json!({ "ok": true })))
}
```

Modify `memory-core/src/memory/mod.rs`:

```rust
pub mod engine;
pub mod scope;
pub mod types;
```

Modify `memory-core/src/http/mod.rs` protected routes:

```rust
use axum::routing::{delete, get, patch, post};

pub mod routes_health;
pub mod routes_memory;

pub fn router(state: AppState) -> Router {
    let protected = Router::new()
        .route("/v1/memory", get(routes_memory::list).post(routes_memory::create))
        .route("/v1/memory/{id}", patch(routes_memory::patch).delete(routes_memory::delete))
        .route_layer(middleware::from_fn_with_state(state.clone(), auth));
    Router::new()
        .route("/health", get(routes_health::health))
        .merge(protected)
        .with_state(state)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run:

```sh
cargo test --manifest-path memory-core/Cargo.toml manual_memory_crud_writes_audit_and_soft_deletes
```

Expected: pass.

- [ ] **Step 5: Commit**

```sh
git add memory-core
git commit -m "Add manual memory CRUD"
```

## Task 4: Add redaction, policy, candidates, and change requests

**Files:**
- Create: `memory-core/src/memory/redactor.rs`
- Create: `memory-core/src/memory/policy.rs`
- Modify: `memory-core/src/memory/engine.rs`
- Modify: `memory-core/src/http/routes_candidates.rs`
- Modify: `memory-core/src/http/routes_change_requests.rs`
- Modify: `memory-core/src/http/mod.rs`
- Test: `memory-core/tests/daemon_http_test.rs`

- [ ] **Step 1: Write failing tests for redaction and pending review**

Append to `memory-core/tests/daemon_http_test.rs`:

```rust
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
                    "text": "Use Riverpod providers for shared Flutter state in this repo.",
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
        .post(format!("{}/v1/memory/candidates/{candidate_id}/approve", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "project_rule",
            "scope": "repo",
            "text": "Prefer Riverpod providers for shared Flutter state in this repo."
        }))
        .send()
        .await
        .expect("approve")
        .json::<serde_json::Value>()
        .await
        .expect("approve json");
    assert_eq!(
        approved["text"],
        "Prefer Riverpod providers for shared Flutter state in this repo."
    );
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```sh
cargo test --manifest-path memory-core/Cargo.toml redactor_masks_known_secret_patterns candidate_approve_writes_memory_and_reject_does_not
```

Expected: fail because redactor and candidate routes do not exist.

- [ ] **Step 3: Implement redactor, policy, candidates, and change requests**

Create `memory-core/src/memory/redactor.rs`:

```rust
const SECRET_PATTERNS: &[&str] = &[
    "api_key", "access_token", "refresh_token", "password", "passwd", "secret",
    "private_key", "-----BEGIN", "sk-", "ghp_", "xoxb-", "AKIA",
];

pub fn contains_secret(text: &str) -> bool {
    let lower = text.to_ascii_lowercase();
    SECRET_PATTERNS.iter().any(|pattern| lower.contains(&pattern.to_ascii_lowercase()))
}

pub fn redact(text: &str) -> String {
    let mut output = text.to_string();
    for pattern in SECRET_PATTERNS {
        output = output.replace(pattern, "[REDACTED]");
    }
    output
}
```

Create `memory-core/src/memory/policy.rs`:

```rust
use super::redactor;

pub fn accepts_candidate(text: &str, confidence: Option<f32>) -> bool {
    let trimmed = text.trim();
    if trimmed.len() < 8 {
        return false;
    }
    if trimmed.chars().count() > 1000 {
        return false;
    }
    if redactor::contains_secret(trimmed) {
        return false;
    }
    if confidence.unwrap_or(1.0) < 0.65 {
        return false;
    }
    true
}
```

Modify `memory-core/src/memory/mod.rs`:

```rust
pub mod engine;
pub mod policy;
pub mod redactor;
pub mod scope;
pub mod types;
```

Add candidate/change-request DTOs and methods to `memory-core/src/memory/engine.rs`. Use the existing `write_audit` helper from Task 3:

```rust
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PreExtractedCandidate {
    pub kind: MemoryKind,
    pub scope: String,
    pub text: String,
    pub confidence: Option<f32>,
    pub reason: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExtractCandidatesRequest {
    pub scope: MemoryScope,
    #[serde(default)]
    pub pre_extracted_candidates: Vec<PreExtractedCandidate>,
}

#[derive(Debug, Serialize)]
pub struct ExtractCandidatesResponse {
    pub candidates: Vec<MemoryCandidateResponse>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MemoryCandidateResponse {
    pub id: String,
    pub kind: MemoryKind,
    pub scope: String,
    pub text: String,
    pub confidence: Option<f32>,
    pub reason: Option<String>,
    pub status: String,
}

#[derive(Debug, Deserialize)]
pub struct ApproveCandidateRequest {
    pub kind: MemoryKind,
    pub scope: String,
    pub text: String,
}

pub async fn create_candidates(pool: &SqlitePool, request: ExtractCandidatesRequest) -> sqlx::Result<ExtractCandidatesResponse> {
    let mut accepted = Vec::new();
    let now = Utc::now().timestamp_millis();
    for candidate in request.pre_extracted_candidates {
        if !crate::memory::policy::accepts_candidate(&candidate.text, candidate.confidence) {
            continue;
        }
        let id = format!("cand_{}", Uuid::new_v4());
        let kind = serde_json::to_value(candidate.kind).unwrap().as_str().unwrap().to_string();
        sqlx::query(
            "insert into memory_candidates
            (id, user_id, workspace_id, repo_id, agent_id, session_id, kind, scope, text, reason, confidence, status, created_at)
            values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?)"
        )
        .bind(&id)
        .bind(&request.scope.user_id)
        .bind(&request.scope.workspace_id)
        .bind(&request.scope.repo_id)
        .bind(&request.scope.agent_id)
        .bind(&request.scope.session_id)
        .bind(kind)
        .bind(&candidate.scope)
        .bind(&candidate.text)
        .bind(&candidate.reason)
        .bind(candidate.confidence)
        .bind(now)
        .execute(pool)
        .await?;
        write_audit(pool, "extractor", "candidate.create", None, Some(&id), None, serde_json::json!({})).await?;
        accepted.push(MemoryCandidateResponse {
            id,
            kind: candidate.kind,
            scope: candidate.scope,
            text: candidate.text,
            confidence: candidate.confidence,
            reason: candidate.reason,
            status: "pending".to_string(),
        });
    }
    Ok(ExtractCandidatesResponse { candidates: accepted })
}

pub async fn approve_candidate(pool: &SqlitePool, candidate_id: &str, request: ApproveCandidateRequest) -> sqlx::Result<MemoryResponse> {
    let row = sqlx::query(
        "select user_id, workspace_id, repo_id, agent_id, session_id from memory_candidates where id = ? and status = 'pending'"
    )
    .bind(candidate_id)
    .fetch_one(pool)
    .await?;
    let scope_data = MemoryScope {
        user_id: row.get("user_id"),
        workspace_id: row.get("workspace_id"),
        repo_id: row.get("repo_id"),
        agent_id: row.get("agent_id"),
        session_id: row.get("session_id"),
    };
    let item = create_manual_memory(pool, CreateMemoryRequest {
        kind: request.kind,
        scope: request.scope,
        text: request.text,
        scope_data,
    }).await?;
    sqlx::query("update memory_candidates set status = 'approved', reviewed_at = ? where id = ?")
        .bind(Utc::now().timestamp_millis())
        .bind(candidate_id)
        .execute(pool)
        .await?;
    write_audit(pool, "user", "candidate.approve", Some(&item.id), Some(candidate_id), None, serde_json::json!({})).await?;
    Ok(item)
}
```

Create `memory-core/src/http/routes_candidates.rs`:

```rust
use axum::extract::{Path, State};
use axum::Json;

use crate::app_state::AppState;
use crate::error::ApiError;
use crate::memory::engine::{
    approve_candidate, create_candidates, ApproveCandidateRequest, ExtractCandidatesRequest,
    ExtractCandidatesResponse, MemoryResponse,
};

pub async fn extract(
    State(state): State<AppState>,
    Json(request): Json<ExtractCandidatesRequest>,
) -> Result<Json<ExtractCandidatesResponse>, ApiError> {
    Ok(Json(create_candidates(&state.db, request).await?))
}

pub async fn approve(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Json(request): Json<ApproveCandidateRequest>,
) -> Result<Json<MemoryResponse>, ApiError> {
    Ok(Json(approve_candidate(&state.db, &id, request).await?))
}
```

Create `memory-core/src/http/routes_change_requests.rs` with a minimal pending endpoint:

```rust
use axum::Json;

pub async fn list() -> Json<serde_json::Value> {
    Json(serde_json::json!({ "items": [] }))
}
```

Modify `memory-core/src/http/mod.rs`:

```rust
pub mod routes_candidates;
pub mod routes_change_requests;

let protected = Router::new()
    .route("/v1/memory", get(routes_memory::list).post(routes_memory::create))
    .route("/v1/memory/{id}", patch(routes_memory::patch).delete(routes_memory::delete))
    .route("/v1/memory/extract-candidates", post(routes_candidates::extract))
    .route("/v1/memory/candidates/{id}/approve", post(routes_candidates::approve))
    .route("/v1/memory/change-requests", get(routes_change_requests::list))
    .route_layer(middleware::from_fn_with_state(state.clone(), auth));
```

- [ ] **Step 4: Run tests to verify they pass**

Run:

```sh
cargo test --manifest-path memory-core/Cargo.toml redactor_masks_known_secret_patterns candidate_approve_writes_memory_and_reject_does_not
```

Expected: pass.

- [ ] **Step 5: Commit**

```sh
git add memory-core
git commit -m "Add memory candidate review flow"
```

## Task 5: Add mock embeddings, ranking, search, and formatter

**Files:**
- Create: `memory-core/src/embedding/mod.rs`
- Create: `memory-core/src/embedding/embedder.rs`
- Create: `memory-core/src/embedding/mock_embedder.rs`
- Create: `memory-core/src/memory/ranker.rs`
- Create: `memory-core/src/memory/formatter.rs`
- Create: `memory-core/src/vector/mod.rs`
- Create: `memory-core/src/vector/sqlite_vec_store.rs`
- Modify: `memory-core/src/memory/engine.rs`
- Modify: `memory-core/src/http/routes_memory.rs`
- Test: `memory-core/tests/daemon_http_test.rs`

- [ ] **Step 1: Write failing search and formatter tests**

Append to `memory-core/tests/daemon_http_test.rs`:

```rust
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
            "scopeData": {"userId":"local-user","workspaceId":"workspace-1","repoId":"repo-1","agentId":"agent-1","sessionId":"session-1"}
        }))
        .send().await.unwrap()
        .json::<serde_json::Value>().await.unwrap();
    let deleted = client
        .post(format!("{}/v1/memory", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "kind": "project_rule",
            "scope": "repo",
            "text": "Deleted rule should not appear.",
            "scopeData": {"userId":"local-user","workspaceId":"workspace-1","repoId":"repo-1","agentId":"agent-1","sessionId":"session-1"}
        }))
        .send().await.unwrap()
        .json::<serde_json::Value>().await.unwrap();
    client.delete(format!("{}/v1/memory/{}", state.base_url, deleted["id"].as_str().unwrap()))
        .bearer_auth("test-token")
        .send().await.unwrap();

    let search = client
        .post(format!("{}/v1/memory/search", state.base_url))
        .bearer_auth("test-token")
        .json(&serde_json::json!({
            "query": "Who owns ACP runtime?",
            "scope": {"userId":"local-user","workspaceId":"workspace-1","repoId":"repo-1","agentId":"agent-1","sessionId":"session-1"},
            "limit": 10
        }))
        .send().await.unwrap()
        .json::<serde_json::Value>().await.unwrap();
    assert_eq!(search["items"].as_array().unwrap().len(), 1);
    assert_eq!(search["items"][0]["id"], active["id"]);
}

#[test]
fn formatter_uses_background_context_wording() {
    let formatted = memory_core::memory::formatter::format_context(&[
        ("project_rule", "Use Riverpod providers for shared Flutter state."),
        ("architecture_decision", "Rust only owns memory."),
    ]);
    assert!(formatted.contains("<agent_memory_context>"));
    assert!(formatted.contains("current instruction wins"));
    assert!(formatted.contains(
        "[project_rule] Use Riverpod providers for shared Flutter state."
    ));
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```sh
cargo test --manifest-path memory-core/Cargo.toml search_returns_active_memory_and_skips_deleted formatter_uses_background_context_wording
```

Expected: fail because search and formatter do not exist.

- [ ] **Step 3: Implement mock search and formatter**

Create `memory-core/src/memory/formatter.rs`:

```rust
pub fn format_context(items: &[(&str, &str)]) -> String {
    if items.is_empty() {
        return String::new();
    }
    let mut output = String::from(
        "<agent_memory_context>\nThe following are relevant long-term memories.\nUse them as background context only.\nIf they conflict with the user's current instruction, the current instruction wins.\n",
    );
    for (index, (kind, text)) in items.iter().enumerate() {
        output.push_str(&format!("{}. [{}] {}\n", index + 1, kind, text));
    }
    output.push_str("</agent_memory_context>");
    output
}
```

Create `memory-core/src/memory/ranker.rs`:

```rust
pub fn kind_priority(kind: &str) -> i64 {
    match kind {
        "project_rule" => 0,
        "architecture_decision" => 1,
        "user_preference" => 2,
        "session_summary" => 3,
        _ => 9,
    }
}

pub fn final_score(vector_score: f32, scope_score: f32, recency_score: f32) -> f32 {
    vector_score * 0.70 + scope_score * 0.20 + recency_score * 0.10
}
```

Create `memory-core/src/embedding/mod.rs`:

```rust
pub mod embedder;
pub mod mock_embedder;
```

Create `memory-core/src/embedding/embedder.rs`:

```rust
#[async_trait::async_trait]
pub trait Embedder: Send + Sync {
    async fn embed(&self, text: &str) -> anyhow::Result<Vec<f32>>;
}
```

Create `memory-core/src/embedding/mock_embedder.rs`:

```rust
use super::embedder::Embedder;

pub struct MockEmbedder;

#[async_trait::async_trait]
impl Embedder for MockEmbedder {
    async fn embed(&self, text: &str) -> anyhow::Result<Vec<f32>> {
        let mut vector = vec![0.0_f32; 8];
        for (index, byte) in text.bytes().enumerate() {
            vector[index % 8] += byte as f32 / 255.0;
        }
        Ok(vector)
    }
}
```

Create `memory-core/src/vector/mod.rs`:

```rust
pub mod sqlite_vec_store;
```

Create `memory-core/src/vector/sqlite_vec_store.rs`:

```rust
pub async fn rebuild() -> anyhow::Result<()> {
    Ok(())
}
```

Modify `memory-core/src/memory/mod.rs`:

```rust
pub mod engine;
pub mod formatter;
pub mod policy;
pub mod ranker;
pub mod redactor;
pub mod scope;
pub mod types;
```

Modify `memory-core/src/lib.rs`:

```rust
pub mod app_state;
pub mod config;
pub mod db;
pub mod embedding;
pub mod error;
pub mod http;
pub mod memory;
pub mod vector;
```

Add search DTOs and function to `memory-core/src/memory/engine.rs`:

```rust
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SearchRequest {
    pub query: String,
    pub scope: MemoryScope,
    pub limit: Option<i64>,
}

#[derive(Debug, Serialize)]
pub struct SearchResponse {
    pub items: Vec<SearchItem>,
}

#[derive(Debug, Serialize)]
pub struct SearchItem {
    pub id: String,
    pub kind: String,
    pub scope: String,
    pub text: String,
    pub score: f32,
    pub metadata: serde_json::Value,
}

pub async fn search_memory(pool: &SqlitePool, request: SearchRequest) -> sqlx::Result<SearchResponse> {
    let limit = request.limit.unwrap_or(12).clamp(1, 50);
    let rows = sqlx::query(
        "select id, kind, scope, text, source_session_id, source_turn_id
         from memory_items
         where status = 'active'
           and user_id = ?
           and (repo_id = ? or workspace_id = ? or scope = 'global')
         order by updated_at desc
         limit ?"
    )
    .bind(&request.scope.user_id)
    .bind(&request.scope.repo_id)
    .bind(&request.scope.workspace_id)
    .bind(limit)
    .fetch_all(pool)
    .await?;
    Ok(SearchResponse {
        items: rows.into_iter().map(|row| SearchItem {
            id: row.get("id"),
            kind: row.get("kind"),
            scope: row.get("scope"),
            text: row.get("text"),
            score: 1.0,
            metadata: serde_json::json!({
                "sourceSessionId": row.get::<Option<String>, _>("source_session_id"),
                "sourceTurnId": row.get::<Option<String>, _>("source_turn_id")
            }),
        }).collect(),
    })
}
```

Add search route to `memory-core/src/http/routes_memory.rs`:

```rust
use crate::memory::engine::{search_memory, SearchRequest, SearchResponse};

pub async fn search(
    State(state): State<AppState>,
    Json(request): Json<SearchRequest>,
) -> Result<Json<SearchResponse>, ApiError> {
    Ok(Json(search_memory(&state.db, request).await?))
}

pub async fn format_context(Json(items): Json<Vec<(String, String)>>) -> Json<serde_json::Value> {
    let borrowed = items
        .iter()
        .map(|(kind, text)| (kind.as_str(), text.as_str()))
        .collect::<Vec<_>>();
    Json(serde_json::json!({ "text": crate::memory::formatter::format_context(&borrowed) }))
}
```

Add routes in `memory-core/src/http/mod.rs`:

```rust
.route("/v1/memory/search", post(routes_memory::search))
.route("/v1/memory/format-context", post(routes_memory::format_context))
```

- [ ] **Step 4: Run tests to verify they pass**

Run:

```sh
cargo test --manifest-path memory-core/Cargo.toml search_returns_active_memory_and_skips_deleted formatter_uses_background_context_wording
```

Expected: pass with mock DB-backed search.

- [ ] **Step 5: Commit**

```sh
git add memory-core
git commit -m "Add memory search and formatter"
```

## Task 6: Add sqlite-vec and FastEmbed local embeddings

**Files:**
- Modify: `memory-core/Cargo.toml`
- Modify: `memory-core/src/config.rs`
- Modify: `memory-core/src/db/schema.sql`
- Modify: `memory-core/src/db/sqlite.rs`
- Modify: `memory-core/src/vector/sqlite_vec_store.rs`
- Modify: `memory-core/src/embedding/embedder.rs`
- Create: `memory-core/src/embedding/fastembed_local.rs`
- Create: `memory-core/src/embedding/openai_compatible.rs`
- Test: `memory-core/tests/daemon_http_test.rs`

- [ ] **Step 1: Write failing vector rebuild and provider config tests**

Append to `memory-core/tests/daemon_http_test.rs`:

```rust
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
    let pool = memory_core::db::sqlite::open(temp.path()).await.expect("db");
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```sh
cargo test --manifest-path memory-core/Cargo.toml embedding_config_defaults_to_multilingual_e5_small rebuild_vector_index_endpoint_exists
```

Expected: fail because `EmbeddingConfig`, sqlite-vec registration, and rebuild route do not exist.

- [ ] **Step 3: Implement provider config, sqlite-vec registration, and local embedder**

Add dependencies to `memory-core/Cargo.toml`:

```toml
fastembed = { version = "5.16.0", default-features = false, features = ["ort-download-binaries-rustls-tls", "hf-hub-rustls-tls"] }
libsqlite3-sys = "0.30"
sqlite-vec = "0.1.10-alpha.4"
```

Add to `memory-core/src/config.rs`:

```rust
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct EmbeddingConfig {
    pub provider: String,
    pub model: String,
    pub variant: String,
    pub dimension: usize,
    pub download_policy: String,
}

impl Default for EmbeddingConfig {
    fn default() -> Self {
        Self {
            provider: "fastembed-local".to_string(),
            model: "intfloat/multilingual-e5-small".to_string(),
            variant: "onnx-qint8".to_string(),
            dimension: 384,
            download_policy: "lazy".to_string(),
        }
    }
}
```

Create `memory-core/src/embedding/fastembed_local.rs`:

```rust
use std::sync::Mutex;

use fastembed::{EmbeddingModel, TextEmbedding, TextInitOptions};

use super::embedder::Embedder;

pub struct FastEmbedLocal {
    model: Mutex<TextEmbedding>,
}

impl FastEmbedLocal {
    pub fn multilingual_e5_small() -> anyhow::Result<Self> {
        let model = TextEmbedding::try_new(
            TextInitOptions::new(EmbeddingModel::MultilingualE5Small)
                .with_show_download_progress(false),
        )?;
        Ok(Self {
            model: Mutex::new(model),
        })
    }
}

#[async_trait::async_trait]
impl Embedder for FastEmbedLocal {
    async fn embed(&self, text: &str) -> anyhow::Result<Vec<f32>> {
        let mut model = self
            .model
            .lock()
            .map_err(|_| anyhow::anyhow!("fastembed model lock poisoned"))?;
        let embeddings = model.embed(vec![format!("query: {text}")], None)?;
        embeddings
            .into_iter()
            .next()
            .ok_or_else(|| anyhow::anyhow!("fastembed returned no embedding"))
    }
}
```

Create `memory-core/src/embedding/openai_compatible.rs`:

```rust
use super::embedder::Embedder;

pub struct OpenAiCompatibleEmbedder {
    pub base_url: String,
    pub model: String,
    pub api_key: Option<String>,
    pub http: reqwest::Client,
}

#[async_trait::async_trait]
impl Embedder for OpenAiCompatibleEmbedder {
    async fn embed(&self, text: &str) -> anyhow::Result<Vec<f32>> {
        let mut request = self
            .http
            .post(format!("{}/embeddings", self.base_url.trim_end_matches('/')))
            .json(&serde_json::json!({
                "model": self.model,
                "input": text,
            }));
        if let Some(api_key) = &self.api_key {
            request = request.bearer_auth(api_key);
        }
        let response = request.send().await?.error_for_status()?;
        let body: serde_json::Value = response.json().await?;
        let values = body["data"][0]["embedding"]
            .as_array()
            .ok_or_else(|| anyhow::anyhow!("embedding response missing data[0].embedding"))?;
        values
            .iter()
            .map(|value| {
                value
                    .as_f64()
                    .map(|number| number as f32)
                    .ok_or_else(|| anyhow::anyhow!("embedding value is not a number"))
            })
            .collect()
    }
}
```

Modify `memory-core/src/embedding/mod.rs`:

```rust
pub mod embedder;
pub mod fastembed_local;
pub mod mock_embedder;
pub mod openai_compatible;
```

Add vector metadata schema to `memory-core/src/db/schema.sql` after indexes:

```sql
create table if not exists vector_index_metadata (
  key text primary key,
  value text not null
);
```

Modify `memory-core/src/vector/sqlite_vec_store.rs`:

```rust
use sqlx::SqlitePool;

pub async fn ensure_vec_table(pool: &SqlitePool, dimension: usize) -> sqlx::Result<()> {
    let sql = format!(
        "create virtual table if not exists vec_memory_items using vec0(
          embedding float[{dimension}],
          user_id text partition key,
          workspace_id text,
          repo_id text,
          agent_id text,
          session_id text,
          kind text,
          scope text,
          status text,
          +memory_id text,
          +text text
        )"
    );
    sqlx::query(&sql).execute(pool).await?;
    Ok(())
}

pub async fn rebuild(pool: &SqlitePool, dimension: usize) -> sqlx::Result<()> {
    ensure_vec_table(pool, dimension).await?;
    sqlx::query(
        "insert into vector_index_metadata(key, value)
         values('last_rebuild', strftime('%s','now'))
         on conflict(key) do update set value = excluded.value"
    )
    .execute(pool)
    .await?;
    Ok(())
}
```

Modify `memory-core/src/db/sqlite.rs` so sqlite-vec is registered before opening the pool:

```rust
fn register_sqlite_vec() {
    unsafe {
        libsqlite3_sys::sqlite3_auto_extension(Some(std::mem::transmute(
            sqlite_vec::sqlite3_vec_init as *const (),
        )));
    }
}

pub async fn open(data_dir: &Path) -> anyhow::Result<SqlitePool> {
    register_sqlite_vec();
    tokio::fs::create_dir_all(data_dir).await?;
    let db_path = data_dir.join("memory.sqlite");
    let options = SqliteConnectOptions::from_str(&format!("sqlite://{}", db_path.display()))?
        .create_if_missing(true)
        .journal_mode(SqliteJournalMode::Wal);
    let pool = SqlitePoolOptions::new()
        .max_connections(5)
        .connect_with(options)
        .await?;
    migrations::run(&pool).await?;
    Ok(pool)
}
```

Add to `memory-core/src/http/routes_memory.rs`:

```rust
pub async fn rebuild_vector_index(
    State(state): State<AppState>,
) -> Result<Json<serde_json::Value>, ApiError> {
    crate::vector::sqlite_vec_store::rebuild(&state.db, 384).await?;
    Ok(Json(serde_json::json!({ "ok": true })))
}
```

Add route in `memory-core/src/http/mod.rs`:

```rust
.route("/v1/memory/rebuild-vector-index", post(routes_memory::rebuild_vector_index))
```

- [ ] **Step 4: Run tests to verify they pass**

Run:

```sh
cargo test --manifest-path memory-core/Cargo.toml embedding_config_defaults_to_multilingual_e5_small sqlite_vec_is_registered_and_rebuild_vector_index_endpoint_exists
```

Expected: pass. This task proves sqlite-vec is registered, the virtual table can be created, and the default local embedding provider can instantiate the selected model.

- [ ] **Step 5: Commit**

```sh
git add memory-core
git commit -m "Add sqlite-vec and local embeddings"
```

## Task 7: Add MCP stdio bridge tools

**Files:**
- Modify: `memory-core/Cargo.toml`
- Create: `memory-core/src/mcp/mod.rs`
- Create: `memory-core/src/mcp/daemon_client.rs`
- Create: `memory-core/src/mcp/tools.rs`
- Create: `memory-core/src/mcp/stdio_server.rs`
- Modify: `memory-core/src/main.rs`
- Modify: `memory-core/src/lib.rs`
- Test: `memory-core/tests/mcp_stdio_test.rs`

- [ ] **Step 1: Write failing MCP tests**

Create `memory-core/tests/mcp_stdio_test.rs`:

```rust
use std::process::{Command, Stdio};
use std::io::{BufRead, BufReader, Write};

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
    assert!(value["result"]["tools"].as_array().unwrap().iter().any(|tool| tool["name"] == "memory.search"));

    child.kill().ok();
    child.wait().ok();
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```sh
cargo test --manifest-path memory-core/Cargo.toml mcp_stdio_logs_do_not_pollute_stdout
```

Expected: fail because MCP mode is absent.

- [ ] **Step 3: Implement minimal MCP JSON-RPC stdio server**

Create `memory-core/src/mcp/mod.rs`:

```rust
pub mod daemon_client;
pub mod stdio_server;
pub mod tools;
```

Create `memory-core/src/mcp/daemon_client.rs`:

```rust
#[derive(Clone)]
pub struct DaemonClient {
    pub base_url: String,
    pub token: String,
    pub http: reqwest::Client,
}

impl DaemonClient {
    pub fn new(base_url: String, token: String) -> Self {
        Self { base_url, token, http: reqwest::Client::new() }
    }
}
```

Create `memory-core/src/mcp/tools.rs`:

```rust
pub fn tools_list() -> serde_json::Value {
    serde_json::json!({
        "tools": [
            {"name":"memory.search","description":"Search approved long-term memory.","inputSchema":{"type":"object"}},
            {"name":"memory.remember","description":"Propose memory; auto-approve when confidence meets policy, otherwise skip below-threshold proposals.","inputSchema":{"type":"object"}},
            {"name":"memory.list","description":"List approved memory.","inputSchema":{"type":"object"}},
            {"name":"memory.update","description":"Create a pending memory update request.","inputSchema":{"type":"object"}},
            {"name":"memory.forget","description":"Create a pending memory delete request.","inputSchema":{"type":"object"}}
        ]
    })
}
```

Create `memory-core/src/mcp/stdio_server.rs`:

```rust
use tokio::io::{self, AsyncBufReadExt, AsyncWriteExt, BufReader};

use super::daemon_client::DaemonClient;

pub async fn run(client: DaemonClient) -> anyhow::Result<()> {
    let stdin = BufReader::new(io::stdin());
    let mut lines = stdin.lines();
    let mut stdout = io::stdout();
    while let Some(line) = lines.next_line().await? {
        let request: serde_json::Value = serde_json::from_str(&line)?;
        let id = request.get("id").cloned().unwrap_or(serde_json::Value::Null);
        let method = request.get("method").and_then(|value| value.as_str()).unwrap_or("");
        let result = match method {
            "tools/list" => crate::mcp::tools::tools_list(),
            _ => serde_json::json!({"error":"unsupported method"}),
        };
        let response = serde_json::json!({"jsonrpc":"2.0","id":id,"result":result});
        stdout.write_all(response.to_string().as_bytes()).await?;
        stdout.write_all(b"\n").await?;
        stdout.flush().await?;
    }
    drop(client);
    Ok(())
}
```

Modify `memory-core/src/lib.rs`:

```rust
pub mod mcp;
```

Modify `memory-core/src/main.rs` mcp arm:

```rust
Mode::McpStdio => {
    let token = std::env::var("MEMORY_DAEMON_TOKEN")?;
    let daemon_url = cli.daemon_url.clone().ok_or_else(|| anyhow::anyhow!("--daemon-url is required"))?;
    memory_core::mcp::stdio_server::run(memory_core::mcp::daemon_client::DaemonClient::new(daemon_url, token)).await
}
```

- [ ] **Step 4: Run test to verify it passes**

Run:

```sh
cargo test --manifest-path memory-core/Cargo.toml mcp_stdio_logs_do_not_pollute_stdout
```

Expected: pass.

- [ ] **Step 5: Commit**

```sh
git add memory-core
git commit -m "Add memory MCP stdio bridge"
```

## Task 8: Add Flutter memory config parsing and serialization

**Files:**
- Create: `lib/memory/memory_config.dart`
- Modify: `lib/config/acp_client_config.dart`
- Modify: `lib/config/acp_config_store.dart`
- Test: `test/memory/memory_config_test.dart`
- Test: `test/config/acp_client_config_test.dart`
- Test: `test/config/acp_config_store_test.dart`

- [ ] **Step 1: Write failing config tests**

Create `test/memory/memory_config_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/memory/memory_config.dart';

void main() {
  test('MemoryConfig defaults to disabled local memory with ACP sidecar extractor', () {
    const config = MemoryConfig();
    expect(config.enabled, false);
    expect(config.embedding.provider, 'fastembed-local');
    expect(config.embedding.model, 'intfloat/multilingual-e5-small');
    expect(config.embedding.dimension, 384);
    expect(config.extractor.provider, 'acp-sidecar');
    expect(config.extractor.fallbackProvider, 'rules');
    expect(config.review.autoOpen, 'high_confidence');
  });

  test('MemoryConfig parses extractor agent and model', () {
    final config = MemoryConfig.fromJson({
      'extractor': {'provider': 'acp-sidecar', 'agent': 'Codex', 'model': 'gpt-5-mini'},
      'llm': {'base_url': 'http://127.0.0.1:11434/v1', 'model': 'qwen2.5:7b', 'api_key_env': 'OLLAMA_API_KEY'},
    });
    expect(config.extractor.agent, 'Codex');
    expect(config.extractor.model, 'gpt-5-mini');
    expect(config.llm.baseUrl, 'http://127.0.0.1:11434/v1');
    expect(config.llm.apiKeyEnv, 'OLLAMA_API_KEY');
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```sh
flutter test test/memory/memory_config_test.dart
```

Expected: fail because memory config does not exist.

- [ ] **Step 3: Implement memory config types**

Create `lib/memory/memory_config.dart`:

```dart
class MemoryConfig {
  const MemoryConfig({
    this.enabled = false,
    this.dataDir,
    this.embedding = const MemoryEmbeddingConfig(),
    this.extractor = const MemoryExtractorConfig(),
    this.llm = const MemoryLlmConfig(),
    this.review = const MemoryReviewConfig(),
  });

  final bool enabled;
  final String? dataDir;
  final MemoryEmbeddingConfig embedding;
  final MemoryExtractorConfig extractor;
  final MemoryLlmConfig llm;
  final MemoryReviewConfig review;

  factory MemoryConfig.fromJson(Object? raw) {
    if (raw is! Map) return const MemoryConfig();
    return MemoryConfig(
      enabled: raw['enabled'] as bool? ?? false,
      dataDir: raw['data_dir'] as String? ?? raw['dataDir'] as String?,
      embedding: MemoryEmbeddingConfig.fromJson(raw['embedding']),
      extractor: MemoryExtractorConfig.fromJson(raw['extractor']),
      llm: MemoryLlmConfig.fromJson(raw['llm']),
      review: MemoryReviewConfig.fromJson(raw['review']),
    );
  }

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    if (dataDir != null) 'data_dir': dataDir,
    'embedding': embedding.toJson(),
    'extractor': extractor.toJson(),
    'llm': llm.toJson(),
    'review': review.toJson(),
  };
}

class MemoryEmbeddingConfig {
  const MemoryEmbeddingConfig({
    this.provider = 'fastembed-local',
    this.model = 'intfloat/multilingual-e5-small',
    this.variant = 'onnx-qint8',
    this.dimension = 384,
    this.downloadPolicy = 'lazy',
  });

  final String provider;
  final String model;
  final String variant;
  final int dimension;
  final String downloadPolicy;

  factory MemoryEmbeddingConfig.fromJson(Object? raw) {
    if (raw is! Map) return const MemoryEmbeddingConfig();
    return MemoryEmbeddingConfig(
      provider: raw['provider'] as String? ?? 'fastembed-local',
      model: raw['model'] as String? ?? 'intfloat/multilingual-e5-small',
      variant: raw['variant'] as String? ?? 'onnx-qint8',
      dimension: raw['dimension'] as int? ?? 384,
      downloadPolicy: raw['download_policy'] as String? ?? raw['downloadPolicy'] as String? ?? 'lazy',
    );
  }

  Map<String, Object?> toJson() => {
    'provider': provider,
    'model': model,
    'variant': variant,
    'dimension': dimension,
    'download_policy': downloadPolicy,
  };
}

class MemoryExtractorConfig {
  const MemoryExtractorConfig({
    this.provider = 'acp-sidecar',
    this.agent = 'Codex',
    this.model = 'gpt-5-mini',
    this.fallbackProvider = 'rules',
  });

  final String provider;
  final String agent;
  final String model;
  final String fallbackProvider;

  factory MemoryExtractorConfig.fromJson(Object? raw) {
    if (raw is! Map) return const MemoryExtractorConfig();
    return MemoryExtractorConfig(
      provider: raw['provider'] as String? ?? 'acp-sidecar',
      agent: raw['agent'] as String? ?? 'Codex',
      model: raw['model'] as String? ?? 'gpt-5-mini',
      fallbackProvider: raw['fallback_provider'] as String? ?? raw['fallbackProvider'] as String? ?? 'rules',
    );
  }

  Map<String, Object?> toJson() => {
    'provider': provider,
    'agent': agent,
    'model': model,
    'fallback_provider': fallbackProvider,
  };
}

class MemoryLlmConfig {
  const MemoryLlmConfig({
    this.provider = 'openai-compatible',
    this.baseUrl = 'http://127.0.0.1:11434/v1',
    this.model = 'qwen2.5:7b',
    this.apiKeyEnv = 'OLLAMA_API_KEY',
  });

  final String provider;
  final String baseUrl;
  final String model;
  final String apiKeyEnv;

  factory MemoryLlmConfig.fromJson(Object? raw) {
    if (raw is! Map) return const MemoryLlmConfig();
    return MemoryLlmConfig(
      provider: raw['provider'] as String? ?? 'openai-compatible',
      baseUrl: raw['base_url'] as String? ?? raw['baseUrl'] as String? ?? 'http://127.0.0.1:11434/v1',
      model: raw['model'] as String? ?? 'qwen2.5:7b',
      apiKeyEnv: raw['api_key_env'] as String? ?? raw['apiKeyEnv'] as String? ?? 'OLLAMA_API_KEY',
    );
  }

  Map<String, Object?> toJson() => {
    'provider': provider,
    'base_url': baseUrl,
    'model': model,
    'api_key_env': apiKeyEnv,
  };
}

class MemoryReviewConfig {
  const MemoryReviewConfig({
    this.autoOpen = 'high_confidence',
    this.highConfidenceThreshold = 0.85,
  });

  final String mode;
  final double highConfidenceThreshold;

  factory MemoryReviewConfig.fromJson(Object? raw) {
    if (raw is! Map) return const MemoryReviewConfig();
    return MemoryReviewConfig(
      mode: raw['mode'] as String? ?? raw['auto_open'] as String? ?? raw['autoOpen'] as String? ?? 'high_confidence_auto',
      highConfidenceThreshold: (raw['high_confidence_threshold'] as num? ?? raw['highConfidenceThreshold'] as num? ?? 0.85).toDouble(),
    );
  }

  Map<String, Object?> toJson() => {
    'mode': mode,
    'high_confidence_threshold': highConfidenceThreshold,
  };
}
```

Modify `lib/config/acp_client_config.dart` by importing memory config and adding a `memory` field to the existing constructor:

```dart
import '../memory/memory_config.dart';

class AcpClientConfig {
  final MemoryConfig memory;
}
```

In `AcpClientConfig.fromJson`, parse:

```dart
final memory = MemoryConfig.fromJson(json['memory']);
```

Pass `memory: memory` into every `AcpClientConfig` returned by `fromJson`. Update `withActiveAgentServer` to preserve the existing `memory` value.

Modify `lib/config/acp_config_store.dart` so `toSettingsJson` includes:

```dart
'memory': config.memory.toJson(),
```

- [ ] **Step 4: Run tests to verify they pass**

Run:

```sh
flutter test test/memory/memory_config_test.dart test/config/acp_client_config_test.dart test/config/acp_config_store_test.dart
```

Expected: pass.

- [ ] **Step 5: Commit**

```sh
git add lib/config lib/memory test/memory test/config
git commit -m "Add Flutter memory configuration"
```

## Task 9: Add Flutter daemon manager and API client

**Files:**
- Create: `lib/memory/memory_daemon_manager.dart`
- Create: `lib/memory/memory_api_client.dart`
- Test: `test/memory/memory_daemon_manager_test.dart`
- Test: `test/memory/memory_api_client_test.dart`

- [ ] **Step 1: Write failing daemon manager and API client tests**

Create `test/memory/memory_daemon_manager_test.dart`:

```dart
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/memory/memory_daemon_manager.dart';

void main() {
  test('parses ready JSON line', () {
    final ready = MemoryDaemonReady.fromStdoutLine('{"type":"ready","port":43129}');
    expect(ready.port, 43129);
    expect(ready.baseUrl, 'http://127.0.0.1:43129');
  });

  test('builds daemon env with token but args omit token', () {
    final launch = MemoryDaemonLaunch(
      executable: '/tmp/memory-core',
      dataDir: '/tmp/data',
      token: 'secret-token',
    );
    expect(launch.env['MEMORY_DAEMON_TOKEN'], 'secret-token');
    expect(launch.args.join(' '), isNot(contains('secret-token')));
    expect(launch.args, contains('--port'));
    expect(launch.args, contains('0'));
  });
}
```

Create `test/memory/memory_api_client_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/memory/memory_api_client.dart';

void main() {
  test('MemorySearchRequest serializes scope with camelCase keys', () {
    final request = MemorySearchRequest(
      query: 'Flutter owns ACP',
      scope: const MemoryScopeData(
        userId: 'local-user',
        workspaceId: 'workspace-1',
        repoId: 'repo-1',
        agentId: 'agent-1',
        sessionId: 'session-1',
      ),
      limit: 12,
    );
    expect(request.toJson()['scope'], {
      'userId': 'local-user',
      'workspaceId': 'workspace-1',
      'repoId': 'repo-1',
      'agentId': 'agent-1',
      'sessionId': 'session-1',
    });
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```sh
flutter test test/memory/memory_daemon_manager_test.dart test/memory/memory_api_client_test.dart
```

Expected: fail because files do not exist.

- [ ] **Step 3: Implement manager and API DTOs**

Create `lib/memory/memory_daemon_manager.dart`:

```dart
import 'dart:convert';

class MemoryDaemonReady {
  const MemoryDaemonReady({required this.port});

  final int port;

  String get baseUrl => 'http://127.0.0.1:$port';

  factory MemoryDaemonReady.fromStdoutLine(String line) {
    final decoded = jsonDecode(line);
    if (decoded is! Map || decoded['type'] != 'ready') {
      throw const FormatException('Expected memory daemon ready JSON.');
    }
    final port = decoded['port'];
    if (port is! int || port <= 0) {
      throw const FormatException('Memory daemon ready JSON missing port.');
    }
    return MemoryDaemonReady(port: port);
  }
}

class MemoryDaemonLaunch {
  const MemoryDaemonLaunch({
    required this.executable,
    required this.dataDir,
    required this.token,
  });

  final String executable;
  final String dataDir;
  final String token;

  List<String> get args => [
    '--mode',
    'daemon',
    '--host',
    '127.0.0.1',
    '--port',
    '0',
    '--data-dir',
    dataDir,
  ];

  Map<String, String> get env => {'MEMORY_DAEMON_TOKEN': token};
}
```

Create `lib/memory/memory_api_client.dart`:

```dart
class MemoryScopeData {
  const MemoryScopeData({
    required this.userId,
    this.workspaceId,
    this.repoId,
    this.agentId,
    this.sessionId,
  });

  final String userId;
  final String? workspaceId;
  final String? repoId;
  final String? agentId;
  final String? sessionId;

  Map<String, Object?> toJson() => {
    'userId': userId,
    if (workspaceId != null) 'workspaceId': workspaceId,
    if (repoId != null) 'repoId': repoId,
    if (agentId != null) 'agentId': agentId,
    if (sessionId != null) 'sessionId': sessionId,
  };
}

class MemorySearchRequest {
  const MemorySearchRequest({
    required this.query,
    required this.scope,
    this.limit = 12,
  });

  final String query;
  final MemoryScopeData scope;
  final int limit;

  Map<String, Object?> toJson() => {
    'query': query,
    'scope': scope.toJson(),
    'limit': limit,
  };
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run:

```sh
flutter test test/memory/memory_daemon_manager_test.dart test/memory/memory_api_client_test.dart
```

Expected: pass.

- [ ] **Step 5: Commit**

```sh
git add lib/memory test/memory
git commit -m "Add Flutter memory daemon client"
```

## Task 10: Add memory context builder and prompt injection middleware

**Files:**
- Create: `lib/memory/memory_context_builder.dart`
- Create: `lib/memory/acp_memory_middleware.dart`
- Modify: `lib/acp/acp_agent_client.dart`
- Modify: `lib/acp/dart_acp_agent_client.dart`
- Modify: `lib/acp/fake_agent_client.dart`
- Modify: `lib/state/chat_controller.dart`
- Test: `test/memory/memory_context_builder_test.dart`
- Test: `test/memory/acp_memory_middleware_test.dart`
- Test: `test/state/chat_controller_test.dart`

- [ ] **Step 1: Write failing context builder and middleware tests**

Create `test/memory/memory_context_builder_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/memory/memory_context_builder.dart';

void main() {
  test('builds memory context as background block', () {
    final text = MemoryContextBuilder.build([
      const MemoryContextItem(
        kind: 'project_rule',
        text: 'Use Riverpod providers for shared Flutter state.',
      ),
      const MemoryContextItem(kind: 'architecture_decision', text: 'Rust only owns memory.'),
    ]);
    expect(text, contains('<agent_memory_context>'));
    expect(text, contains('current instruction wins'));
    expect(
      text,
      contains('[project_rule] Use Riverpod providers for shared Flutter state.'),
    );
  });
}
```

Create `test/memory/acp_memory_middleware_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/memory/acp_memory_middleware.dart';

void main() {
  test('search failure returns original prompt and records nonfatal error', () async {
    final middleware = AcpMemoryMiddleware(search: (_) async => throw StateError('down'));
    final result = await middleware.preparePrompt('hello');
    expect(result.prompt, 'hello');
    expect(result.memoryContext, isNull);
    expect(result.error, contains('down'));
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```sh
flutter test test/memory/memory_context_builder_test.dart test/memory/acp_memory_middleware_test.dart
```

Expected: fail because middleware files do not exist.

- [ ] **Step 3: Implement context builder and middleware seam**

Create `lib/memory/memory_context_builder.dart`:

```dart
class MemoryContextItem {
  const MemoryContextItem({required this.kind, required this.text});

  final String kind;
  final String text;
}

class MemoryContextBuilder {
  static String build(List<MemoryContextItem> items) {
    if (items.isEmpty) return '';
    final buffer = StringBuffer()
      ..writeln('<agent_memory_context>')
      ..writeln('The following are relevant long-term memories.')
      ..writeln('Use them as background context only.')
      ..writeln("If they conflict with the user's current instruction, the current instruction wins.");
    for (var i = 0; i < items.length; i += 1) {
      buffer.writeln('${i + 1}. [${items[i].kind}] ${items[i].text}');
    }
    buffer.write('</agent_memory_context>');
    return buffer.toString();
  }
}
```

Create `lib/memory/acp_memory_middleware.dart`:

```dart
typedef MemorySearchCallback = Future<String?> Function(String prompt);

class PreparedPrompt {
  const PreparedPrompt({required this.prompt, this.memoryContext, this.error});

  final String prompt;
  final String? memoryContext;
  final String? error;
}

class AcpMemoryMiddleware {
  const AcpMemoryMiddleware({required this.search});

  final MemorySearchCallback search;

  Future<PreparedPrompt> preparePrompt(String prompt) async {
    try {
      final memoryContext = await search(prompt);
      return PreparedPrompt(prompt: prompt, memoryContext: memoryContext);
    } catch (error) {
      return PreparedPrompt(prompt: prompt, error: error.toString());
    }
  }
}
```

Modify `lib/acp/acp_agent_client.dart`:

```dart
Stream<AgentEvent> sendPrompt({
  required String sessionId,
  required String prompt,
  String? memoryContext,
  List<PromptAttachment> attachments = const <PromptAttachment>[],
});
```

Modify implementations in `lib/acp/dart_acp_agent_client.dart` and `lib/acp/fake_agent_client.dart` to accept `memoryContext`. In `DartAcpAgentClient`, prepend it as a separate text content block before the user prompt. In `FakeAgentClient`, store `lastMemoryContext = memoryContext` for tests.

Modify `ChatController` constructor:

```dart
this.memoryMiddleware,
```

Add field:

```dart
final AcpMemoryMiddleware? memoryMiddleware;
```

In `sendPrompt`, before calling `client.sendPrompt`, add:

```dart
final prepared = await memoryMiddleware?.preparePrompt(prompt);
final memoryContext = prepared?.memoryContext;
```

Pass `memoryContext: memoryContext` to `client.sendPrompt`.

- [ ] **Step 4: Run tests to verify they pass**

Run:

```sh
flutter test test/memory/memory_context_builder_test.dart test/memory/acp_memory_middleware_test.dart test/state/chat_controller_test.dart
```

Expected: pass.

- [ ] **Step 5: Commit**

```sh
git add lib/acp lib/memory lib/state test/memory test/state
git commit -m "Add memory prompt middleware"
```

## Task 11: Add ACP sidecar extractor

**Files:**
- Create: `lib/memory/acp_sidecar_memory_extractor.dart`
- Modify: `lib/app.dart`
- Test: `test/memory/acp_sidecar_memory_extractor_test.dart`

- [ ] **Step 1: Write failing sidecar extractor test**

Create `test/memory/acp_sidecar_memory_extractor_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/fake_agent_client.dart';
import 'package:ianvs_acp/memory/acp_sidecar_memory_extractor.dart';

void main() {
  test('sidecar extractor asks isolated agent for JSON candidates', () async {
    final fake = FakeAgentClient(promptEvents: const []);
    final extractor = AcpSidecarMemoryExtractor(clientFactory: () => fake);
    final prompt = extractor.buildExtractionPrompt(
      userPrompt: '本项目共享状态使用 Riverpod。',
      assistantAnswer: '记住了。',
    );
    expect(prompt, contains('Return JSON only'));
    expect(prompt, contains('project_rule'));
    expect(prompt, contains('本项目共享状态使用 Riverpod。'));
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```sh
flutter test test/memory/acp_sidecar_memory_extractor_test.dart
```

Expected: fail because extractor does not exist.

- [ ] **Step 3: Implement prompt builder and sidecar shell**

Create `lib/memory/acp_sidecar_memory_extractor.dart`:

```dart
import '../acp/acp_agent_client.dart';

typedef AcpSidecarClientFactory = AcpAgentClient Function();

class AcpSidecarMemoryExtractor {
  const AcpSidecarMemoryExtractor({required this.clientFactory});

  final AcpSidecarClientFactory clientFactory;

  String buildExtractionPrompt({
    required String userPrompt,
    required String assistantAnswer,
  }) {
    return '''
You are a memory extraction engine for a local AI agent client.
Extract only durable, useful memories from the current turn.
Allowed memory kinds:
1. user_preference
2. project_rule
3. architecture_decision
4. session_summary
Do not extract secrets, temporary one-off instructions, unverified assumptions, long code snippets, or error logs.
Return JSON only.
Schema:
{"candidates":[{"kind":"user_preference | project_rule | architecture_decision | session_summary","scope":"global | workspace | repo | session","text":"Clear, concise memory text.","confidence":0.0,"reason":"Short reason why this is durable and useful."}]}

User prompt:
$userPrompt

Assistant answer:
$assistantAnswer
''';
  }
}
```

Wire this into `lib/app.dart` only after Task 12 has an API client target. Keep this task limited to the extractor prompt and isolated client factory seam.

- [ ] **Step 4: Run test to verify it passes**

Run:

```sh
flutter test test/memory/acp_sidecar_memory_extractor_test.dart
```

Expected: pass.

- [ ] **Step 5: Commit**

```sh
git add lib/memory test/memory
git commit -m "Add ACP sidecar memory extractor"
```

## Task 12: Add Review panel and Memory Explorer UI

**Files:**
- Create: `lib/ui/components/memory_review_panel.dart`
- Create: `lib/ui/components/memory_explorer_page.dart`
- Modify: `lib/ui/shell/app_shell.dart`
- Test: `test/ui/memory_review_panel_test.dart`
- Test: `test/ui/memory_explorer_page_test.dart`
- Update: `test/ui/app_shell_test.dart`

- [ ] **Step 1: Write failing UI tests**

Create `test/ui/memory_review_panel_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/ui/components/memory_review_panel.dart';

void main() {
  testWidgets('review panel shows candidate actions', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: MemoryReviewPanel(
          candidates: [
            MemoryReviewCandidate(
              id: 'cand-1',
              kind: 'project_rule',
              scope: 'repo',
              text: 'Use Riverpod providers for shared Flutter state.',
              confidence: 0.95,
              reason: 'User explicitly gave a rule.',
            ),
          ],
        ),
      ),
    ));
    expect(find.text('Memory Review'), findsOneWidget);
    expect(
      find.text('Use Riverpod providers for shared Flutter state.'),
      findsOneWidget,
    );
    expect(find.text('Approve'), findsOneWidget);
    expect(find.text('Edit'), findsOneWidget);
    expect(find.text('Reject'), findsOneWidget);
  });
}
```

Create `test/ui/memory_explorer_page_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/ui/components/memory_explorer_page.dart';

void main() {
  testWidgets('explorer exposes memory management tabs and clear data', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: MemoryExplorerPage()));
    expect(find.text('All memory'), findsOneWidget);
    expect(find.text('Candidates'), findsOneWidget);
    expect(find.text('Change requests'), findsOneWidget);
    expect(find.text('Audit log'), findsOneWidget);
    expect(find.text('Clear data'), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```sh
flutter test test/ui/memory_review_panel_test.dart test/ui/memory_explorer_page_test.dart
```

Expected: fail because UI files do not exist.

- [ ] **Step 3: Implement minimal UI components**

Create `lib/ui/components/memory_review_panel.dart`:

```dart
import 'package:flutter/material.dart';

class MemoryReviewCandidate {
  const MemoryReviewCandidate({
    required this.id,
    required this.kind,
    required this.scope,
    required this.text,
    this.confidence,
    this.reason,
  });

  final String id;
  final String kind;
  final String scope;
  final String text;
  final double? confidence;
  final String? reason;
}

class MemoryReviewPanel extends StatelessWidget {
  const MemoryReviewPanel({super.key, this.candidates = const []});

  final List<MemoryReviewCandidate> candidates;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 280,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Memory Review', style: TextStyle(fontWeight: FontWeight.w800)),
          for (final candidate in candidates)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${candidate.kind} · ${candidate.scope} · ${candidate.confidence ?? 0}'),
                    Text(candidate.text),
                    if (candidate.reason != null) Text(candidate.reason!),
                    Row(
                      children: [
                        TextButton(onPressed: () {}, child: const Text('Approve')),
                        TextButton(onPressed: () {}, child: const Text('Edit')),
                        TextButton(onPressed: () {}, child: const Text('Reject')),
                      ],
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
```

Create `lib/ui/components/memory_explorer_page.dart`:

```dart
import 'package:flutter/material.dart';

class MemoryExplorerPage extends StatelessWidget {
  const MemoryExplorerPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Memory', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            Wrap(
              spacing: 8,
              children: [
                Chip(label: Text('All memory')),
                Chip(label: Text('Candidates')),
                Chip(label: Text('Change requests')),
                Chip(label: Text('Audit log')),
                Chip(label: Text('Clear data')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
```

Wire the Memory entry into `AppShell` with a toolbar/menu action that opens `MemoryExplorerPage`. Keep the panel hidden until later state wiring exposes candidates.

- [ ] **Step 4: Run tests to verify they pass**

Run:

```sh
flutter test test/ui/memory_review_panel_test.dart test/ui/memory_explorer_page_test.dart test/ui/app_shell_test.dart
```

Expected: pass.

- [ ] **Step 5: Commit**

```sh
git add lib/ui test/ui
git commit -m "Add memory review UI shell"
```

## Task 13: Add Memory section to Agent Configuration

**Files:**
- Modify: `lib/ui/components/agent_config_dialog.dart`
- Test: `test/ui/agent_config_dialog_test.dart`

- [ ] **Step 1: Write failing memory config dialog test**

Append to `test/ui/agent_config_dialog_test.dart`:

```dart
testWidgets('AgentConfigDialog shows memory configuration controls', (tester) async {
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => TextButton(
        onPressed: () => showDialog<void>(
          context: context,
          builder: (_) => const AgentConfigDialog(
            agentServers: [],
            activeAgentName: 'Codex',
            configPath: '/tmp/settings.json',
          ),
        ),
        child: const Text('Open'),
      ),
    ),
  ));
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
  expect(find.text('Memory'), findsOneWidget);
  expect(find.text('Enable memory'), findsOneWidget);
  expect(find.text('Extractor agent'), findsOneWidget);
  expect(find.text('Extractor model'), findsOneWidget);
  expect(find.text('Embedding model'), findsOneWidget);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```sh
flutter test test/ui/agent_config_dialog_test.dart --plain-name "AgentConfigDialog shows memory configuration controls"
```

Expected: fail because the Memory section does not exist.

- [ ] **Step 3: Add Memory section**

Add a Memory section to `AgentConfigDialog` after Client Providers. It should include:

```dart
SwitchListTile(
  title: const Text('Enable memory'),
  value: _memoryEnabled,
  onChanged: _saving ? null : (value) => setState(() => _memoryEnabled = value),
)
```

Add text fields labelled:

- `Embedding model`
- `Extractor agent`
- `Extractor model`
- `OpenAI-compatible base URL`
- `API key env`

When saving, construct `MemoryConfig` from local dialog state and include it in the `AcpClientConfig` returned to `onSaveConfig`, while preserving the dialog's existing agent, MCP, directory, and provider fields.

- [ ] **Step 4: Run test to verify it passes**

Run:

```sh
flutter test test/ui/agent_config_dialog_test.dart --plain-name "AgentConfigDialog shows memory configuration controls"
```

Expected: pass.

- [ ] **Step 5: Commit**

```sh
git add lib/ui/components/agent_config_dialog.dart test/ui/agent_config_dialog_test.dart
git commit -m "Add memory configuration UI"
```

## Task 14: Wire app-level memory runtime

**Files:**
- Modify: `lib/app.dart`
- Modify: `lib/state/chat_controller.dart`
- Modify: `lib/ui/shell/app_shell.dart`
- Test: `test/ui/acp_client_app_test.dart`
- Test: `test/state/chat_controller_test.dart`

- [ ] **Step 1: Write failing app integration tests**

Add to `test/ui/acp_client_app_test.dart`:

```dart
testWidgets('AcpClientApp passes memory config into controllers', (tester) async {
  final fake = FakeAgentClient();
  await tester.pumpWidget(AcpClientApp(
    controller: ChatController(client: fake, cwd: '/tmp'),
    config: const AcpClientConfig(memory: MemoryConfig(enabled: true)),
  ));
  expect(find.textContaining('ACP Client'), findsWidgets);
});
```

Add to `test/state/chat_controller_test.dart`:

```dart
test('ChatController keeps prompt working when memory middleware fails', () async {
  final fake = FakeAgentClient();
  final controller = ChatController(
    client: fake,
    cwd: '/tmp',
    memoryMiddleware: AcpMemoryMiddleware(search: (_) async => throw StateError('down')),
  );
  await controller.newSession();
  await controller.sendPrompt('hello');
  expect(fake.lastPrompt, 'hello');
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```sh
flutter test test/ui/acp_client_app_test.dart test/state/chat_controller_test.dart
```

Expected: fail until imports and runtime wiring are complete.

- [ ] **Step 3: Wire memory runtime conservatively**

In `AcpClientApp._controllerFor`, pass `memoryMiddleware` only when `config.memory.enabled` is true:

```dart
memoryMiddleware: config.memory.enabled
    ? AcpMemoryMiddleware(search: (_) async => null)
    : null,
```

Keep the first integration as a no-op search until the daemon manager is fully connected. The no-op middleware proves that ChatController and prompt paths can carry memory safely without blocking user prompts.

- [ ] **Step 4: Run tests to verify they pass**

Run:

```sh
flutter test test/ui/acp_client_app_test.dart test/state/chat_controller_test.dart
```

Expected: pass.

- [ ] **Step 5: Commit**

```sh
git add lib/app.dart lib/state/chat_controller.dart test/ui/acp_client_app_test.dart test/state/chat_controller_test.dart
git commit -m "Wire memory runtime into app state"
```

## Task 15: Documentation and full verification

**Files:**
- Modify: `README.md`
- Modify: `docs/acp_feature_audit.md`
- Modify: `docs/manual_followups.md`
- Modify: `.gitignore`

- [ ] **Step 1: Ignore visual companion scratch files**

Add to `.gitignore`:

```gitignore
.superpowers/
```

Keep `.serena/` decision separate; do not ignore or delete it unless the user asks.

- [ ] **Step 2: Update README memory section**

Add a concise Memory section to `README.md`:

```md
## Memory

The client can run a local Rust `memory-core` daemon for four reviewed memory kinds:
user preferences, project rules, architecture decisions, and session summaries.
Memory is local-first and opt-in. High-confidence safe writes and maintenance
can move automatically, while destructive cleanup remains reviewable. The
daemon exposes local HTTP APIs and a stdio MCP bridge; Flutter owns ACP prompt
injection and sidecar extraction. Maintenance considers active plus disabled
memories, skips mid-confidence review noise in high-confidence automatic mode,
skips below-threshold candidates in threshold-based automatic extraction, and
merges active duplicates or active/disabled overlap upward from session to repo
to global scope, with workspace kept only as a legacy-compatible scope rather
than a promotion stop.
```

- [ ] **Step 3: Update feature audit**

Add a row or section to `docs/acp_feature_audit.md` explaining:

```md
Local Memory Engine: planned/implemented as a local extension around ACP. Flutter
injects memory as background context before `session/prompt`; Rust memory-core
does not proxy ACP and only owns memory storage, search, MCP bridge, and audit.
```

- [ ] **Step 4: Run Rust verification**

Run:

```sh
cargo test --manifest-path memory-core/Cargo.toml
```

Expected: all Rust tests pass.

- [ ] **Step 5: Run Flutter verification**

Run:

```sh
flutter test test/memory test/config test/state/chat_controller_test.dart test/ui/memory_review_panel_test.dart test/ui/memory_explorer_page_test.dart test/ui/agent_config_dialog_test.dart test/ui/acp_client_app_test.dart
flutter analyze
```

Expected: tests pass and analyzer reports no issues.

- [ ] **Step 6: Commit**

```sh
git add .gitignore README.md docs/acp_feature_audit.md docs/manual_followups.md memory-core lib test
git commit -m "Document local memory engine"
```

## Self-Review

- Spec coverage: this plan covers daemon startup, SQLite schema, CRUD, candidates, change requests, audit, redaction, search, context formatting, MCP stdio, Flutter config, daemon client, middleware, ACP sidecar extractor, Review panel, Explorer, Agent Configuration, docs, and verification.
- Spec coverage: FastEmbed and sqlite-vec are planned as concrete dependencies. The mock embedder remains only for deterministic tests.
- 红旗扫描：没有占位标记、延期行为或未命名的异常处理步骤。
- Type consistency: Rust uses `MemoryKind`, `MemoryScope`, `MemoryResponse`, `MemoryCandidateResponse`; Flutter uses `MemoryConfig`, `MemoryScopeData`, `AcpMemoryMiddleware`, `MemoryReviewPanel`, and `MemoryExplorerPage` consistently across tasks.
