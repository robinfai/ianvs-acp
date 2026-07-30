use sqlx::sqlite::{SqliteConnectOptions, SqliteJournalMode, SqlitePoolOptions};
use sqlx::SqlitePool;
use std::path::Path;
use std::sync::Once;
use std::time::Duration;

use super::migrations;

static REGISTER_SQLITE_VEC: Once = Once::new();

fn register_sqlite_vec() {
    REGISTER_SQLITE_VEC.call_once(|| unsafe {
        libsqlite3_sys::sqlite3_auto_extension(Some(std::mem::transmute::<
            *const (),
            unsafe extern "C" fn(
                *mut libsqlite3_sys::sqlite3,
                *mut *mut std::ffi::c_char,
                *const libsqlite3_sys::sqlite3_api_routines,
            ) -> std::ffi::c_int,
        >(
            sqlite_vec::sqlite3_vec_init as *const ()
        )));
    });
}

pub async fn open(data_dir: &Path) -> anyhow::Result<SqlitePool> {
    open_with_policy(data_dir, StoragePolicy::default()).await
}

#[derive(Debug, Clone, Copy)]
pub struct StoragePolicy {
    pub max_bytes: u64,
    pub retention_days: u32,
    pub cleanup_interval_hours: u32,
}

impl Default for StoragePolicy {
    fn default() -> Self {
        Self {
            max_bytes: 50 * 1024 * 1024 * 1024,
            retention_days: 30,
            cleanup_interval_hours: 24,
        }
    }
}

impl StoragePolicy {
    pub fn from_env() -> anyhow::Result<Self> {
        let defaults = Self::default();
        Ok(Self {
            max_bytes: positive_env("MEMORY_SQLITE_MAX_BYTES", defaults.max_bytes)?,
            retention_days: positive_env("MEMORY_SQLITE_RETENTION_DAYS", defaults.retention_days)?,
            cleanup_interval_hours: positive_env(
                "MEMORY_SQLITE_CLEANUP_INTERVAL_HOURS",
                defaults.cleanup_interval_hours,
            )?,
        })
    }

    pub fn cleanup_interval(self) -> Duration {
        Duration::from_secs(u64::from(self.cleanup_interval_hours) * 60 * 60)
    }
}

pub async fn open_with_policy(
    data_dir: &Path,
    policy: StoragePolicy,
) -> anyhow::Result<SqlitePool> {
    register_sqlite_vec();
    tokio::fs::create_dir_all(data_dir).await?;
    let db_path = data_dir.join("memory.sqlite");
    let options = SqliteConnectOptions::new()
        .filename(db_path)
        .create_if_missing(true)
        .journal_mode(SqliteJournalMode::Wal);
    let pool = SqlitePoolOptions::new()
        .max_connections(5)
        .connect_with(options)
        .await?;
    migrations::run(&pool).await?;
    apply_page_limit(&pool, policy.max_bytes).await?;
    maintain(&pool, policy).await?;
    Ok(pool)
}

pub async fn maintain(pool: &SqlitePool, policy: StoragePolicy) -> anyhow::Result<()> {
    let retention_millis = i64::from(policy.retention_days) * 24 * 60 * 60 * 1_000;
    let cutoff = chrono::Utc::now().timestamp_millis() - retention_millis;
    let mut transaction = pool.begin().await?;
    sqlx::query(
        "delete from memory_candidates
         where status != 'pending' and coalesce(reviewed_at, created_at) < ?",
    )
    .bind(cutoff)
    .execute(&mut *transaction)
    .await?;
    sqlx::query(
        "delete from memory_change_requests
         where status != 'pending' and coalesce(reviewed_at, created_at) < ?",
    )
    .bind(cutoff)
    .execute(&mut *transaction)
    .await?;
    for statement in [
        "delete from memory_audit_log where created_at < ?",
        "delete from prompt_injections where created_at < ?",
        "delete from memory_accesses where accessed_at < ?",
        "delete from memory_feedback where created_at < ?",
    ] {
        sqlx::query(statement)
            .bind(cutoff)
            .execute(&mut *transaction)
            .await?;
    }
    transaction.commit().await?;
    sqlx::query("pragma wal_checkpoint(truncate)")
        .execute(pool)
        .await?;
    Ok(())
}

async fn apply_page_limit(pool: &SqlitePool, max_bytes: u64) -> anyhow::Result<()> {
    if max_bytes < 1024 * 1024 {
        anyhow::bail!("MEMORY_SQLITE_MAX_BYTES must be at least 1 MiB");
    }
    let page_size = sqlx::query_scalar::<_, i64>("pragma page_size")
        .fetch_one(pool)
        .await?;
    let page_size = u64::try_from(page_size)?;
    let max_pages = max_bytes.div_ceil(page_size).max(1);
    sqlx::query(&format!("pragma max_page_count = {max_pages}"))
        .execute(pool)
        .await?;
    Ok(())
}

fn positive_env<T>(name: &str, fallback: T) -> anyhow::Result<T>
where
    T: std::str::FromStr + PartialOrd + From<u8> + Copy,
    T::Err: std::fmt::Display,
{
    let Ok(raw) = std::env::var(name) else {
        return Ok(fallback);
    };
    let value = raw
        .parse::<T>()
        .map_err(|error| anyhow::anyhow!("{name} is invalid: {error}"))?;
    if value <= T::from(0) {
        anyhow::bail!("{name} must be positive");
    }
    Ok(value)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn maintenance_expires_operational_history_but_keeps_pending_rows() {
        let directory = tempfile::tempdir().unwrap();
        let pool = open(directory.path()).await.unwrap();
        sqlx::query(
            "insert into memory_candidates (
                id, user_id, source, kind, scope, text, status, created_at, reviewed_at
             ) values
                ('old-reviewed', 'user', 'test', 'fact', 'user', 'old', 'approved', 1, 1),
                ('old-pending', 'user', 'test', 'fact', 'user', 'pending', 'pending', 1, null)",
        )
        .execute(&pool)
        .await
        .unwrap();

        maintain(
            &pool,
            StoragePolicy {
                retention_days: 1,
                ..StoragePolicy::default()
            },
        )
        .await
        .unwrap();

        let reviewed = sqlx::query_scalar::<_, i64>(
            "select count(*) from memory_candidates where id = 'old-reviewed'",
        )
        .fetch_one(&pool)
        .await
        .unwrap();
        let pending = sqlx::query_scalar::<_, i64>(
            "select count(*) from memory_candidates where id = 'old-pending'",
        )
        .fetch_one(&pool)
        .await
        .unwrap();
        assert_eq!(reviewed, 0);
        assert_eq!(pending, 1);
    }
}
