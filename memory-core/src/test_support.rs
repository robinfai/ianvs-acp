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
