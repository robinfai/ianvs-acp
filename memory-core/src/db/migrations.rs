use sqlx::SqlitePool;

pub async fn run(pool: &SqlitePool) -> sqlx::Result<()> {
    for statement in include_str!("schema.sql").split(';') {
        let trimmed = statement.trim();
        if !trimmed.is_empty() {
            sqlx::query(trimmed).execute(pool).await?;
        }
    }
    ensure_column(
        pool,
        "memory_change_requests",
        "source",
        "text not null default 'user'",
    )
    .await?;
    ensure_column(
        pool,
        "memory_change_requests",
        "target_memory_ids_json",
        "text",
    )
    .await?;
    ensure_column(pool, "memory_change_requests", "confidence", "real").await?;
    Ok(())
}

async fn ensure_column(
    pool: &SqlitePool,
    table: &str,
    column: &str,
    definition: &str,
) -> sqlx::Result<()> {
    let rows = sqlx::query(&format!("pragma table_info({table})"))
        .fetch_all(pool)
        .await?;
    let exists = rows
        .iter()
        .any(|row| sqlx::Row::get::<String, _>(row, "name") == column);
    if !exists {
        sqlx::query(&format!(
            "alter table {table} add column {column} {definition}"
        ))
        .execute(pool)
        .await?;
    }
    Ok(())
}
