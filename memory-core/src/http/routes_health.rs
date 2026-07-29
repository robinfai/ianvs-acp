use axum::Json;
use serde::Serialize;

#[derive(Serialize)]
pub struct HealthResponse {
    pub ok: bool,
    pub version: &'static str,
}

pub async fn health() -> Json<HealthResponse> {
    Json(HealthResponse {
        ok: true,
        version: "0.1.0",
    })
}
