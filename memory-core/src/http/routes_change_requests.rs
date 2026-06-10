use axum::Json;

pub async fn list() -> Json<serde_json::Value> {
    Json(serde_json::json!({ "items": [] }))
}
