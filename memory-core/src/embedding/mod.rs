pub mod embedder;
pub mod fastembed_local;
pub mod mock_embedder;
pub mod openai_compatible;

use crate::config::EmbeddingConfig;
use embedder::Embedder;
use std::sync::Arc;

pub fn from_config(config: &EmbeddingConfig) -> anyhow::Result<Arc<dyn Embedder>> {
    match config.provider.as_str() {
        "fastembed-local" => Ok(Arc::new(
            fastembed_local::FastEmbedLocal::multilingual_e5_small()?,
        )),
        "openai-compatible" => {
            let api_key_env = std::env::var("MEMORY_EMBEDDING_API_KEY_ENV")
                .unwrap_or_else(|_| "OPENAI_API_KEY".to_string());
            let api_key = std::env::var(api_key_env).ok();
            Ok(Arc::new(openai_compatible::OpenAiCompatibleEmbedder {
                base_url: std::env::var("MEMORY_EMBEDDING_BASE_URL")
                    .unwrap_or_else(|_| "http://127.0.0.1:11434/v1".to_string()),
                model: config.model.clone(),
                api_key,
                http: reqwest::Client::new(),
            }))
        }
        "mock" => Ok(Arc::new(mock_embedder::MockEmbedder)),
        provider => Err(anyhow::anyhow!(
            "unsupported embedding provider: {provider}"
        )),
    }
}
