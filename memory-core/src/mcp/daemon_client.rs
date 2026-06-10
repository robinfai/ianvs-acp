#[derive(Clone)]
pub struct DaemonClient {
    pub base_url: String,
    pub token: String,
    pub http: reqwest::Client,
}

impl DaemonClient {
    pub fn new(base_url: String, token: String) -> Self {
        Self {
            base_url,
            token,
            http: reqwest::Client::builder()
                .timeout(std::time::Duration::from_secs(10))
                .build()
                .unwrap_or_else(|_| reqwest::Client::new()),
        }
    }

    pub async fn post_json(
        &self,
        path: &str,
        body: serde_json::Value,
    ) -> anyhow::Result<serde_json::Value> {
        let response = self
            .http
            .post(format!("{}{}", self.base_url.trim_end_matches('/'), path))
            .bearer_auth(&self.token)
            .json(&body)
            .send()
            .await?
            .error_for_status()?;
        Ok(response.json().await?)
    }

    pub async fn get_json(
        &self,
        path: &str,
        query: Vec<(&str, String)>,
    ) -> anyhow::Result<serde_json::Value> {
        let response = self
            .http
            .get(format!("{}{}", self.base_url.trim_end_matches('/'), path))
            .bearer_auth(&self.token)
            .query(&query)
            .send()
            .await?
            .error_for_status()?;
        Ok(response.json().await?)
    }
}
