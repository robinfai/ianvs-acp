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
