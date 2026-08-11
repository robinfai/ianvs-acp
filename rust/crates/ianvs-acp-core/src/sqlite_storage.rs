use rusqlite::Connection;

pub const DEFAULT_SQLITE_MAX_BYTES: u64 = 50 * 1024 * 1024 * 1024;
pub const DEFAULT_SQLITE_RETENTION_DAYS: u32 = 30;
const SQLITE_MAX_PAGE_COUNT: u64 = 0xffff_fffe;

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
        let requested_pages = requested_page_limit(self.max_bytes, page_size)?;
        let applied_pages = connection.query_row(
            &format!("PRAGMA max_page_count = {requested_pages}"),
            [],
            |row| row.get::<_, i64>(0),
        )?;
        let applied_pages = positive_page_count(applied_pages)?;
        let readback_pages =
            connection.query_row("PRAGMA max_page_count", [], |row| row.get::<_, i64>(0))?;
        let readback_pages = positive_page_count(readback_pages)?;
        if applied_pages != requested_pages || readback_pages != requested_pages {
            return Err(rusqlite::Error::InvalidParameterName(format!(
                "SQLite max_page_count was clamped: requested {requested_pages}, applied {applied_pages}, read back {readback_pages}"
            )));
        }
        Ok(())
    }
}

fn requested_page_limit(max_bytes: u64, page_size: i64) -> Result<u64, rusqlite::Error> {
    let page_size = positive_page_count(page_size)?;
    let requested_pages = max_bytes.div_ceil(page_size).max(1);
    if requested_pages > SQLITE_MAX_PAGE_COUNT {
        return Err(rusqlite::Error::InvalidParameterName(format!(
            "SQLite max bytes requires {requested_pages} pages, exceeding the supported {SQLITE_MAX_PAGE_COUNT}"
        )));
    }
    Ok(requested_pages)
}

fn positive_page_count(value: i64) -> Result<u64, rusqlite::Error> {
    let value =
        u64::try_from(value).map_err(|_| rusqlite::Error::IntegralValueOutOfRange(0, value))?;
    if value == 0 {
        return Err(rusqlite::Error::IntegralValueOutOfRange(0, 0));
    }
    Ok(value)
}

#[cfg(test)]
mod tests {
    use super::{SQLITE_MAX_PAGE_COUNT, SqliteStoragePolicy, requested_page_limit};
    use rusqlite::Connection;

    #[test]
    fn sqlite_page_limit_rejects_zero_negative_and_unsupported_page_counts() {
        assert!(requested_page_limit(1024 * 1024, 0).is_err());
        assert!(requested_page_limit(1024 * 1024, -4096).is_err());
        assert!(requested_page_limit(SQLITE_MAX_PAGE_COUNT.saturating_add(1), 1).is_err());
    }

    #[test]
    fn sqlite_page_limit_is_applied_exactly_and_read_back() {
        let connection = Connection::open_in_memory().unwrap();
        let policy = SqliteStoragePolicy::new(1024 * 1024, 30).unwrap();
        policy.apply_page_limit(&connection).unwrap();

        let page_size = connection
            .query_row("PRAGMA page_size", [], |row| row.get::<_, i64>(0))
            .unwrap();
        let expected = requested_page_limit(policy.max_bytes(), page_size).unwrap();
        let applied = connection
            .query_row("PRAGMA max_page_count", [], |row| row.get::<_, i64>(0))
            .unwrap();
        assert_eq!(u64::try_from(applied).unwrap(), expected);
    }
}
