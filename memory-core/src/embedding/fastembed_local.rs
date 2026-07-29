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
