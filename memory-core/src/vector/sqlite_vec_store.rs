use crate::embedding::embedder::Embedder;
use sqlx::Row;
use sqlx::SqlitePool;

pub struct IndexedMemory {
    pub id: String,
    pub user_id: String,
    pub workspace_id: Option<String>,
    pub repo_id: Option<String>,
    pub agent_id: Option<String>,
    pub session_id: Option<String>,
    pub kind: String,
    pub scope: String,
    pub status: String,
    pub text: String,
}

pub struct VectorHit {
    pub memory_id: String,
    pub distance: f32,
}

pub async fn ensure_vec_table(pool: &SqlitePool, dimension: usize) -> sqlx::Result<()> {
    let sql = format!(
        "create virtual table if not exists vec_memory_items using vec0(
          embedding float[{dimension}],
          +memory_id text,
          +user_id text,
          +workspace_id text,
          +repo_id text,
          +agent_id text,
          +session_id text,
          +kind text,
          +scope text,
          +status text,
          +text text
        )"
    );
    sqlx::query(&sql).execute(pool).await?;
    Ok(())
}

pub async fn rebuild(
    pool: &SqlitePool,
    embedder: &dyn Embedder,
    dimension: usize,
) -> anyhow::Result<usize> {
    ensure_vec_table(pool, dimension).await?;
    sqlx::query("delete from vec_memory_items")
        .execute(pool)
        .await?;
    let rows = sqlx::query(
        "select id, user_id, workspace_id, repo_id, agent_id, session_id, kind, scope, text, status
         from memory_items
         where status = 'active'",
    )
    .fetch_all(pool)
    .await?;
    let mut indexed = 0;
    for row in rows {
        upsert(
            pool,
            embedder,
            dimension,
            &IndexedMemory {
                id: row.get("id"),
                user_id: row.get("user_id"),
                workspace_id: row.get("workspace_id"),
                repo_id: row.get("repo_id"),
                agent_id: row.get("agent_id"),
                session_id: row.get("session_id"),
                kind: row.get("kind"),
                scope: row.get("scope"),
                status: row.get("status"),
                text: row.get("text"),
            },
        )
        .await?;
        indexed += 1;
    }
    sqlx::query(
        "insert into vector_index_metadata(key, value)
         values('last_rebuild', strftime('%s','now'))
         on conflict(key) do update set value = excluded.value",
    )
    .execute(pool)
    .await?;
    Ok(indexed)
}

pub async fn upsert(
    pool: &SqlitePool,
    embedder: &dyn Embedder,
    dimension: usize,
    memory: &IndexedMemory,
) -> anyhow::Result<()> {
    ensure_vec_table(pool, dimension).await?;
    delete(pool, &memory.id).await?;
    if memory.status != "active" {
        return Ok(());
    }
    let embedding = embedder.embed(&memory.text).await?;
    validate_dimension(&embedding, dimension)?;
    sqlx::query(
        "insert into vec_memory_items
         (embedding, memory_id, user_id, workspace_id, repo_id, agent_id, session_id, kind, scope, status, text)
         values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
    )
    .bind(vector_json(&embedding)?)
    .bind(&memory.id)
    .bind(&memory.user_id)
    .bind(&memory.workspace_id)
    .bind(&memory.repo_id)
    .bind(&memory.agent_id)
    .bind(&memory.session_id)
    .bind(&memory.kind)
    .bind(&memory.scope)
    .bind(&memory.status)
    .bind(&memory.text)
    .execute(pool)
    .await?;
    Ok(())
}

pub async fn delete(pool: &SqlitePool, memory_id: &str) -> sqlx::Result<()> {
    sqlx::query("delete from vec_memory_items where memory_id = ?")
        .bind(memory_id)
        .execute(pool)
        .await?;
    Ok(())
}

pub async fn search(
    pool: &SqlitePool,
    query_embedding: &[f32],
    limit: i64,
) -> sqlx::Result<Vec<VectorHit>> {
    let rows = sqlx::query(
        "select memory_id, distance
         from vec_memory_items
         where embedding match ? and k = ?
         order by distance",
    )
    .bind(vector_json(query_embedding).map_err(|error| sqlx::Error::Decode(error.into()))?)
    .bind(limit)
    .fetch_all(pool)
    .await?;
    Ok(rows
        .into_iter()
        .map(|row| VectorHit {
            memory_id: row.get("memory_id"),
            distance: row.get::<f64, _>("distance") as f32,
        })
        .collect())
}

fn validate_dimension(vector: &[f32], dimension: usize) -> anyhow::Result<()> {
    if vector.len() != dimension {
        return Err(anyhow::anyhow!(
            "embedding dimension mismatch: got {}, expected {dimension}",
            vector.len()
        ));
    }
    Ok(())
}

fn vector_json(vector: &[f32]) -> anyhow::Result<String> {
    Ok(serde_json::to_string(vector)?)
}
