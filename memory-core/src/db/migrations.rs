use sqlx::SqlitePool;

pub async fn run(pool: &SqlitePool) -> sqlx::Result<()> {
    for statement in include_str!("schema.sql").split(';') {
        let trimmed = statement.trim();
        if !trimmed.is_empty() {
            sqlx::query(trimmed).execute(pool).await?;
        }
    }
    Ok(())
}
