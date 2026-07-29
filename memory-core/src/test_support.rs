use crate::app_state::AppState;
use crate::config::MaintenanceLlmConfig;
use crate::db::sqlite;
use crate::embedding::mock_embedder::MockEmbedder;
use crate::http;
use std::path::Path;
use std::sync::Arc;
use tokio::net::TcpListener;

pub struct TestDaemon {
    pub base_url: String,
}

pub async fn spawn_test_daemon(data_dir: &Path, token: &str) -> anyhow::Result<TestDaemon> {
    spawn_test_daemon_with_llm(data_dir, token, None).await
}

pub async fn spawn_test_daemon_with_llm(
    data_dir: &Path,
    token: &str,
    maintenance_llm: Option<MaintenanceLlmConfig>,
) -> anyhow::Result<TestDaemon> {
    let pool = sqlite::open(data_dir).await?;
    let state = AppState {
        db: pool,
        embedder: Arc::new(MockEmbedder),
        embedding_dimension: 8,
        maintenance_llm,
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
