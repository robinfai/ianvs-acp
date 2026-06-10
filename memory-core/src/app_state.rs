use crate::embedding::embedder::Embedder;
use sqlx::SqlitePool;
use std::sync::Arc;

#[derive(Clone)]
pub struct AppState {
    pub db: SqlitePool,
    pub embedder: Arc<dyn Embedder>,
    pub embedding_dimension: usize,
    pub token: String,
    pub version: &'static str,
}
