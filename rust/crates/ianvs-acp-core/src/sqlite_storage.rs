use rusqlite::Connection;

pub const DEFAULT_SQLITE_MAX_BYTES: u64 = 50 * 1024 * 1024 * 1024;
pub const DEFAULT_SQLITE_RETENTION_DAYS: u32 = 30;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SqliteStoragePolicy {
    max_bytes: u64,
    retention_days: u32,
}

impl Default for SqliteStoragePolicy {
    fn default() -> Self {
        Self {
            max_bytes: DEFAULT_SQLITE_MAX_BYTES,
            retention_days: DEFAULT_SQLITE_RETENTION_DAYS,
        }
    }
}

impl SqliteStoragePolicy {
    pub fn new(max_bytes: u64, retention_days: u32) -> Result<Self, &'static str> {
        if max_bytes < 1024 * 1024 {
            return Err("SQLite max bytes must be at least 1 MiB");
        }
        if retention_days == 0 {
            return Err("SQLite retention days must be positive");
        }
        Ok(Self {
            max_bytes,
            retention_days,
        })
    }

    #[must_use]
    pub const fn max_bytes(self) -> u64 {
        self.max_bytes
    }

    #[must_use]
    pub const fn retention_days(self) -> u32 {
        self.retention_days
    }

    #[must_use]
    pub fn retention_modifier(self) -> String {
        format!("-{} days", self.retention_days)
    }

    pub(crate) fn apply_page_limit(self, connection: &Connection) -> Result<(), rusqlite::Error> {
        let page_size = connection.query_row("PRAGMA page_size", [], |row| row.get::<_, i64>(0))?;
        let page_size = u64::try_from(page_size)
            .map_err(|_| rusqlite::Error::IntegralValueOutOfRange(0, page_size))?;
        let requested_pages = self.max_bytes.div_ceil(page_size).max(1);
        connection.query_row(
            &format!("PRAGMA max_page_count = {requested_pages}"),
            [],
            |_| Ok(()),
        )?;
        Ok(())
    }
}
