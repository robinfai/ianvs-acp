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
