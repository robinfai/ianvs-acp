# Local recovery storage

Updated: 2026-09-10. Source baseline: `b9297f5`.

The application keeps two bounded recovery payload stores and one Workspace UI
state file:

| Store | Default location | Purpose |
| --- | --- | --- |
| ACP session registry | `acp_sessions.sqlite3` | Agent-scoped workspace and session metadata used for recovery |
| Session transcript cache | `session_transcripts/*.transcript.json` | Exact-revision message snapshots that avoid replaying a session on resume |
| Workspace UI state | `workspace_ui_state.json` | Workspace/sidebar preferences plus the local session index |

The locations above are relative to the app-owned state directory, normally
`~/.config/ianvs-acp` (or `$XDG_CONFIG_HOME/ianvs-acp`). With an explicit config
path, an `ianvs-acp` or `.ianvs-acp` parent directory is used directly; any
other parent gets a `.ianvs-acp` child. For example, `/tmp/demo/settings.json`
uses `/tmp/demo/.ianvs-acp/` for state. See
[path resolution](../lib/storage/app_state_path.dart) and the
[configuration path guide](configuration.md).

The configured `storage.max_size_gb` and `storage.retention_days` values are
enforced independently by the database and transcript-cache directory. The
defaults are 50 in the GB-labelled setting and 30 days; the implementation
uses 1,024³ bytes per unit (50 GiB per payload store, not a shared 50 GiB total).
The registry applies its policy when it initializes and when sessions are
updated. The transcript cache removes an expired entry when it is read and performs directory-wide age and capacity
maintenance after writes. Each transcript file is additionally limited to
48 MiB and 2,000 messages.

`workspace_ui_state.json` is not governed by `storage.max_size_gb` or
`storage.retention_days`. It stores expanded, pinned, hidden and explicitly
added Workspace state together with metadata for sessions the app has created
or resumed: session IDs, canonical and additional workspace roots, display
titles, agent association, template ID/version, local-unstarted state, and
pin/archive/unread status. Newly created sessions remain hidden from the sidebar
until their first prompt; that UI filter does not imply absence from stored
recovery metadata. It is not populated by a startup-wide agent session scan. A
fallback display title can be derived from the beginning of a prompt, so this
file may contain a short prompt-derived string. Entries remain until the
corresponding UI state is updated or explicitly removed.

The session registry stores only identifiers and canonical workspace roots
needed to restore active sessions; it does not contain prompt content. The
separate transcript cache does contain locally reconstructed user and assistant
messages, tool metadata and available replay payloads. Cache files are private,
versioned JSON snapshots keyed by agent, session and workspace identity. A
snapshot is accepted only when its stored catalog revision exactly matches the
session being resumed.

SQLite paths must be absolute, must not be symlinks, and are opened with
defensive flags. Writes use transactions and the database applies its page
limit before accepting new records. Config and derived state paths are resolved
to absolute paths before use. Transcript writes are atomic, owner-only and
coordinated across processes; capacity eviction removes the oldest cache files
first and ignores unrelated files in the directory. Workspace UI state is also
owner-only, atomically replaced and coordinated across processes. Its
three-way merge preserves independent window updates at the Workspace/session
record-field level and applies expanded-Workspace additions and removals as set
deltas, but it does not apply the payload-store capacity or retention policy.

Evidence: [storage policy](../lib/storage/sqlite_storage_config.dart),
[transcript cache](../lib/storage/session_transcript_cache.dart),
[sidebar state store](../lib/workspace/workspace_sidebar_state_store.dart), and
[Rust registry](../rust/crates/ianvs-acp-core/src/session_persistence.rs).
