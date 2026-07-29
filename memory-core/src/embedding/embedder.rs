#[async_trait::async_trait]
pub trait Embedder: Send + Sync {
    async fn embed(&self, text: &str) -> anyhow::Result<Vec<f32>>;
}
