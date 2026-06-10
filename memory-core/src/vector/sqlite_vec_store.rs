use sqlx::SqlitePool;

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

pub async fn rebuild(pool: &SqlitePool, dimension: usize) -> sqlx::Result<()> {
    ensure_vec_table(pool, dimension).await?;
    sqlx::query(
        "insert into vector_index_metadata(key, value)
         values('last_rebuild', strftime('%s','now'))
         on conflict(key) do update set value = excluded.value",
    )
    .execute(pool)
    .await?;
    Ok(())
}
