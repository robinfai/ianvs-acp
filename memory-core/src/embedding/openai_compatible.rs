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
            .post(format!(
                "{}/embeddings",
                self.base_url.trim_end_matches('/')
            ))
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
