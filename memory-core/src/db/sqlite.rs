use sqlx::sqlite::{SqliteConnectOptions, SqliteJournalMode, SqlitePoolOptions};
use sqlx::SqlitePool;
use std::path::Path;
use std::sync::Once;

use super::migrations;

static REGISTER_SQLITE_VEC: Once = Once::new();

fn register_sqlite_vec() {
    REGISTER_SQLITE_VEC.call_once(|| unsafe {
        libsqlite3_sys::sqlite3_auto_extension(Some(std::mem::transmute(
            sqlite_vec::sqlite3_vec_init as *const (),
        )));
    });
}

pub async fn open(data_dir: &Path) -> anyhow::Result<SqlitePool> {
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
    Ok(pool)
}
