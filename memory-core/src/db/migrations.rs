use sqlx::{Row, SqlitePool};

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
        "target_memory_ids_json",
        "target_memory_ids_json text",
    )
    .await?;
    ensure_column(
        pool,
        "memory_change_requests",
        "confidence",
        "confidence real",
    )
    .await?;
    ensure_column(
        pool,
        "memory_change_requests",
        "source",
        "source text not null default 'user'",
    )
    .await?;
    ensure_column(
        pool,
        "memory_candidates",
        "source",
        "source text not null default 'extractor'",
    )
    .await?;
    ensure_column(
        pool,
        "memory_candidates",
        "entities_json",
        "entities_json text",
    )
    .await?;
    ensure_column(
        pool,
        "memory_candidates",
        "instruction_scopes_json",
        "instruction_scopes_json text",
    )
    .await?;
    ensure_column(
        pool,
        "memory_candidates",
        "episode_json",
        "episode_json text",
    )
    .await?;
    ensure_column(
        pool,
        "memory_candidates",
        "source_turn_id",
        "source_turn_id text",
    )
    .await?;
    ensure_column(
        pool,
        "memory_items",
        "source_session_id",
        "source_session_id text",
    )
    .await?;
    ensure_column(
        pool,
        "memory_items",
        "source_turn_id",
        "source_turn_id text",
    )
    .await?;
    ensure_column(pool, "memory_items", "observed_at", "observed_at integer").await?;
    ensure_column(pool, "memory_items", "valid_from", "valid_from integer").await?;
    ensure_column(pool, "memory_items", "valid_until", "valid_until integer").await?;
    ensure_column(
        pool,
        "memory_items",
        "supersedes_memory_id",
        "supersedes_memory_id text",
    )
    .await?;
    ensure_column(
        pool,
        "memory_items",
        "pinned",
        "pinned integer not null default 0",
    )
    .await?;
    ensure_column(
        pool,
        "memory_candidates",
        "pinned",
        "pinned integer not null default 0",
    )
    .await?;
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
        .any(|row| row.get::<String, _>("name") == column);
    if !exists {
        sqlx::query(&format!("alter table {table} add column {definition}"))
            .execute(pool)
            .await?;
    }
    Ok(())
}
