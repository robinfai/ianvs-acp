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
            http: reqwest::Client::new(),
        }
    }
}
