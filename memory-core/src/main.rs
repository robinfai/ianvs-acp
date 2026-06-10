use clap::Parser;
use memory_core::app_state::AppState;
use memory_core::config::{Cli, DaemonConfig, Mode};
use memory_core::db::sqlite;
use memory_core::http;
use std::io::Write;
use std::net::SocketAddr;
use tokio::net::TcpListener;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .init();
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
    std::io::stdout().flush()?;
    axum::serve(listener, http::router(state)).await?;
    Ok(())
}
