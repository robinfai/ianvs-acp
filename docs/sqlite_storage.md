# SQLite storage

Updated: 2026-08-09

The application keeps one local SQLite database:

| Store | Default file | Purpose |
| --- | --- | --- |
| ACP session registry | `acp_sessions.sqlite3` | Agent-scoped workspace and session metadata used for recovery |

The configured `storage.max_size_gb` value applies directly to this database.
The default is 50 GB. `storage.retention_days` bounds stale recovery metadata;
the registry applies this policy when it initializes and when sessions are
updated.

The session registry stores only identifiers and canonical workspace roots
needed to restore active sessions. Prompt content and background automation
state are not stored by the client.

SQLite paths must be absolute, must not be symlinks, and are opened with
defensive flags. Writes use transactions and the database applies its page
limit before accepting new records.
