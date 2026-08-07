# SQLite storage policy

ianvs uses three independent SQLite files. The application setting
`storage.max_size_gb` is a shared budget, not a per-file limit. It defaults to
50 GB and is allocated as follows:

| Store | File | Budget | Retained data |
| --- | --- | ---: | --- |
| Workflow authority | `task_inbox_workflow.sqlite3` | 95% | Tasks, runs, current TaskInbox projection, runtime events, workflow definitions/runs, leases, recovery and idempotency records |
| Legacy TaskInbox migration store | `task_inbox_state.sqlite3` | 4% | Normalized legacy tasks/runs/events/artifacts/approvals used during migration |
| ACP session recovery | `acp_sessions.sqlite3` | 1% | Agent/session/workspace metadata needed to resume active ACP sessions |

The percentages always sum to the configured total. SQLite
`max_page_count` enforces each physical allocation for new databases. If an
existing database is already larger than its allocation, SQLite cannot reduce
the file in place; the current page count becomes the temporary ceiling and
deleted pages are reused.

## Retention and automatic cleanup

`storage.retention_days` defaults to 30 days.
`storage.cleanup_interval_hours` defaults to 24 hours.

- Workflow writes remove expired and excess idempotency results in bounded
  batches before inserting a new result. Resolved recovery records and terminal
  leases also expire. Cleanup is deliberately batched so a very large existing
  database cannot create an equally large WAL file during one startup.
- The legacy TaskInbox store sanitizes old prompt, event metadata, and artifact
  previews using the configured retention window. Active task identity and
  status rows remain.
- ACP session recovery metadata expires by `updated_at`; active use refreshes
  the timestamp.

WAL files are checkpointed after maintenance. Logical cleanup frees pages for
reuse, but shrinking an oversized database file requires a separate offline
compaction because SQLite cannot safely rewrite an open database file.

## Configuration

```json
{
  "storage": {
    "max_size_gb": 50,
    "retention_days": 30,
    "cleanup_interval_hours": 24
  }
}
```

The same values are editable under **Agent Configuration → SQLite Storage**.

## Growth-risk note

Idempotency records contain serialized command results so retries can return
the original projection. A result can include the full TaskInbox projection,
which makes an unbounded record table grow much faster than its row count
suggests. The workflow store therefore limits this table by age and by a
quota-derived record count, while preserving a bounded retry window.
