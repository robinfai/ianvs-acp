# ACP Client

A Flutter macOS desktop client for local Agent Client Protocol agents.

The app can launch stdio ACP agents, create and resume sessions, stream prompt
turns, display tool calls, render ACP plan and command updates, switch exposed
session modes/models, close active sessions, and log out when the agent
advertises those capabilities. It can also pass configured additional
directories to agents that advertise ACP `additionalDirectories`, fork active
sessions when the agent supports `session/fork`, and suggest advertised slash
commands in the prompt input. When an agent advertises authentication methods,
the Agent menu can start the agent-handled ACP `authenticate` flow. The same
menu includes Protocol Coverage, which reviews implemented ACP areas against the
official docs and points each area to its visible configuration and interaction
surface.

Starting a new session prompts for the session working directory and offers
local directory path completions while typing.

## Memory

The repo includes a local Rust `memory-core` daemon for four reviewed memory
kinds: user preferences, project rules, architecture decisions, and session
summaries. Memory is local-first and defaults off in the Flutter app until a
user enables it.

To enable prompt injection, turn on Memory in Agent Configuration. The app
starts an app-owned `memory-core` daemon on a dynamic local port, generates an
internal bearer token, and shuts that child process down when Memory is disabled
or the app exits. The bottom status bar shows `memory off`, `memory starting`,
`memory on`, or `memory error` so the local runtime state is visible while using
the app. Flutter queries the daemon search API with the active workspace, repo,
and session scope. Session-scoped lookup is also tied to the active agent, so
same session ids from different agents do not mix. Returned memories are added
as background context before the normal ACP `session/prompt`; the daemon does
not proxy ACP traffic. Daemon search failures or timeouts are non-fatal and
leave the original prompt intact.

The daemon owns storage, hybrid vector/keyword search, audit history, local
embedding support, OpenAI-compatible embedding calls, and its stdio MCP bridge.
Memory writes and explicit rebuilds update the sqlite-vec index; search uses
vector hits when available and falls back to keyword matching if indexing is
unavailable. Search hits are recorded as `memory.retrieve` audit events without
storing the raw prompt text; prompt memory injection records keep only the
injected memory ids, the local turn id, and an injected-text hash. Search
responses include retrieval diagnostics for lexical/vector/entity/scope/
feedback/reinforcement scoring plus `semanticHit`, and the Audit log shows a
compact retrieval summary for debugging why a memory was used. The Audit log
also explains automatic layer changes such as access-based promotion,
feedback-based unpin, and stale expiry. Returned memories with a lexical,
entity, or vector hit are recorded in `memory_accesses`; pinned-only profile
injections are still audited as retrievals but do not reinforce access counts.
Explicit user feedback can be posted as `helpful`, `not_relevant`, or `stale`
and is stored in `memory_feedback` plus `memory.feedback` audit events.
Feedback and access counts apply a small
search-time ranking adjustment; one `not_relevant` feedback only demotes the
memory, while repeated `not_relevant` feedback with no helpful correction
automatically disables it from retrieval without physically deleting the record.
`helpful` feedback also
promotes stable global user preferences and repo rules/decisions into the
profile layer, and the same stable memories are promoted automatically after
three successful semantic retrievals if they have no `not_relevant` or `stale`
feedback.
`not_relevant` feedback removes pinned memories from that layer, and `stale`
feedback disables the outdated memory so it stops participating in retrieval.
These automatic adjustments write `memory.promote`, `memory.unpin`, and
`memory.expire` or `memory.disable` audit events.
Recently used memories get a small recency boost, while long-unused memories
receive a low-impact `decayScore` but remain searchable. The chat timeline also
shows a compact `Memory used · N` panel under a user turn
when retrieved memories were injected; each row includes kind, scope, score,
text, and direct `Helpful`, `Not relevant`, and `Stale` feedback actions that
post to the same feedback API. Active memory cards in Memory Explorer expose the
same feedback actions for post-run review, so useful, irrelevant, or stale
records can feed the automatic profile-layer and expiry logic without waiting
for that memory to be retrieved again. Memory records can also
carry optional temporal metadata (`observedAt`, `validFrom`, `validUntil`, and
`supersedesMemoryId`); search requests default to the current time, can pass an
explicit `referenceTime` for historical lookup, and expired or not-yet-valid
memories are demoted instead of being hidden. A reviewed
`supersede` change request creates a new active memory with `validFrom` and
`supersedesMemoryId`, then marks the old active memory with `validUntil` so
current searches prefer the new fact while historical searches can still see
the old fact. Memory records can
store lightweight entities and tags in `memory_entities`; search uses normalized
entity matching as another retrieval signal, so exact identifiers can be found
even when they are not repeated in the memory text. Extracted candidates can
carry entities, and approved candidates index those entities for later search.
Chinese question-style queries also get short CJK lexical tokens, so prompts
such as `本项目的验证暗号是什么？` can recall a stored project rule without relying
only on embedding similarity.
Memory items can also be marked `pinned` for the small profile/block layer:
pinned memories participate in search even without lexical, vector, or entity
overlap, retrieval diagnostics mark them with `pinnedLayer` and
`semanticHit=false` when they were only included by the profile layer, and search
metadata includes a derived `profileBlock` such as `user_profile` or
`project_profile` with a label, description, and small default limit. Search
balances pinned profile blocks before applying the response limit when one block
would otherwise repeat and crowd another block out. Prompt context places pinned
memories in a separate `<profile_memory>` section before ordinary
`<retrieved_memory>` results, labels each item with its derived block, and
balances the configured small profile budget across blocks before filling
remaining slots by rank. The profile section defaults to 4 items, can be set to
0 to disable the always-on layer, and stays intentionally small so durable
identity/preferences/project rules and architecture decisions stay visible
without one profile block crowding out the others. When Memory is enabled,
Flutter also prepends a small memory-capability notice even when no prior memory
matches the current turn, so the main agent does not tell the user that
cross-session memory is unavailable while automatic extraction/review is active.
High-confidence stable
candidates such as global user preferences plus workspace/repo project rules and
architecture decisions are auto-pinned when approved, so user identity and hard
project context do not depend on probabilistic retrieval alone; later feedback
can promote or unpin those records without deleting their underlying memory.
After prompt turns, Flutter can extract pending memory candidates through either
an ACP sidecar agent or an OpenAI-compatible LLM endpoint and post those
candidates to the daemon for review. If that extractor returns no candidates or
fails after the user explicitly says `记住`/`remember`, states a clear
preferred-name pattern such as `以后叫我 ...` / `call me ...`, introduces their
name with `我叫 ...` / `my name is ...` / `I'm ...`, or states a clear durable
preference such as `我偏好中文回复` / `请始终用中文回复` /
`I prefer concise answers` / `Please reply in Chinese from now on`, a clear
project directive such as `本项目禁止使用 nc` / `以后这个项目不要用 nc` /
`In this repo, never use netcat`, or a clear architecture decision such as
`架构决定...`, Flutter creates a local fallback
candidate, merges it with extractor output, and skips same preferred-name/name/
preference duplicates plus same-scope project rule or architecture-decision
duplicates that share a rule entity, while still skipping obvious secrets such
as API keys, tokens, passwords, and private keys. When a fallback candidate
duplicates extractor output, Flutter keeps one candidate but can carry over the
fallback's higher confidence and entities so clear user intent is not downgraded
by a cautious extractor score. Extractor output and fallback candidates are
normalized before review: one-off hints such as `for this answer` are ignored,
and `for this session` explicit remembers, name overrides, preference overrides,
or project directives become session-scoped summaries instead of global/repo
long-term memories. Local fallback also recognizes project passphrases and
verification phrases as repo-scoped project rules and extracts their short
identifiers for later search. Clear durable preferences, repo directives, and
architecture decisions from local fallback use high-confidence scores so
approved user intent and hard project context can enter the pinned profile layer
without waiting for feedback. High-confidence
candidates are approved automatically by default, and a successful
auto-approval, daemon auto-applied
change request, or turn that retrieved memory can trigger one low-cost
maintenance pass over the latest semantic-scoped batch so consolidation happens
without waiting for a manual review session. When Memory is enabled, the app
adds the app-owned daemon's stdio MCP bridge to main ACP sessions so the agent can call
`memory.search`, `memory.list`, `memory.remember`,
`memory.update`, and `memory.forget` tools. `memory.update` and
`memory.forget` both go through change requests instead of directly mutating
stored memory. `memory.update` follows the same review policy as candidate
creation, so high-confidence non-destructive updates can be approved
immediately; MCP auto-approved remembers and updates also trigger the same
best-effort low-cost maintenance pass as post-turn extraction. `memory.forget`
remains pending because delete is destructive.
`memory.remember` uses the same candidate review policy as post-turn extraction:
high-confidence candidates and review-band stable memories can be approved
immediately. Review-band approvals cover the short-term `session_summary` layer
plus stable user preferences, project rules, and architecture decisions; they do
not automatically enter the pinned profile layer unless they meet the stricter
pinning threshold. Below-threshold or unknown long-term candidates remain
pending for post-run review.
Candidate creation skips duplicates
that already exist as active memory or pending candidates in the same scope, and
writes `candidate.skip_duplicate` audit entries instead of creating more review
work. High-confidence stable candidates that clearly update an existing
same-topic memory are converted into an approved `supersede` change request:
the old memory receives `validUntil`, the new memory becomes active, and the
audit log records `candidate.auto_supersede`. Review and explorer UI surfaces
can list active and disabled memory, pending/approved/rejected candidates, pending and
reviewed change requests, and audit events, with daemon list APIs
supporting workspace/repo/agent/session/kind filters and pagination. The
daemon also reuses duplicate pending change requests with the same scoped action,
targets, and proposed change, writing `change_request.skip_duplicate` instead of
adding another review card. The
Explorer search box filters All memory, Candidates, Change requests, and Audit
log locally, so post-run review stays quick without another LLM or daemon call.
Audit log also has local category filters for retrieval, memory changes,
candidate events, change requests, maintenance, and clear events, so automatic
memory behavior can be reviewed without scanning the full event stream.
All memory and MCP `memory.list` use memory semantic scope: global memories are
visible for the user, workspace/repo memories remain reviewable across sessions
in scope, and session memories stay tied to the current agent/session.
Daemon search uses the same semantic scope, so broader workspace/repo memories
can still be retrieved from the active repo/session context.
Candidate loading uses candidate semantic scope: global candidates stay visible
for the same user, workspace/repo candidates remain reviewable across sessions
inside their scope, and session candidates only appear for the matching
agent/session.
Change request loading uses the current workspace/repo/agent/session scope while
still including broader workspace/repo suggestions, keeping the review queue
focused without hiding maintenance output.
Audit loading uses the same current scope and semantic matching, so global and
workspace memories retrieved inside the repo still appear in Audit log.
Pending candidates and pending change requests can be approved, edited before
approval, rejected, or bulk approved/rejected across the currently visible
filtered results. Change request edits are persisted through the daemon before
approval and audited as `change_request.update`, so reviewers can refresh or
switch tabs without losing proposed kind/scope/text adjustments; candidate and
change request cards show their source, such as `extractor`, `mcp`, or
`maintenance`, and approved/rejected candidates and change requests remain
visible as read-only history for post-run review.
Approved candidates keep that source, source session, and source turn on the
resulting active memory. Active memory cards show derived profile block labels
for pinned memories, so post-run review can distinguish user/workspace/project
profile layers without opening prompt diagnostics. Active memory cards can be
edited after
automatic approval, disabled so the record remains visible as read-only history
but stops participating in retrieval, or restored from disabled history; disables
write `memory.disable` audit events, and restores write `memory.restore` audit
events. All memory cards show their source, such as `manual`, `extractor`,
`mcp`, or `maintenance`, and include the source turn when available, so users can
tell how a memory was created during post-run review. Active memory cards can
also submit `helpful`, `not_relevant`, or
`stale` feedback, which writes feedback audit and lets the daemon automatically
promote, unpin, expire, or disable repeatedly irrelevant memory as appropriate.
Automatic approvals
preserve their source in audit: post-turn extraction uses `extractor`, MCP
`memory.remember` uses `mcp`, and maintenance auto-approval uses `maintenance`
on both the approval event and the resulting memory change events.
When new pending reviews appear, or a turn auto-applies memory changes, the app
refreshes the pending count after the turn and shows a bottom review prompt with
a direct Memory Explorer action;
`memory.review.auto_open = "never"` disables that prompt. All memory also
includes a manual `Organize` action for on-demand cleanup; both automatic and
manual maintenance run a low-cost pass over the
latest semantic-scoped batch for the current workspace/repo context, auto-apply
high-confidence changes unless the selected maintenance mode or manual-only
action list requires review, and leave lower-confidence or destructive changes
in Change requests for review. Manual Organize can clean session memories that
are visible in the current workspace/repo even when no active agent/session is
passed. Conservative idle maintenance is on by default; the app runs the same
low-cost maintenance pass after a configured number of quiet successful turns
only when no new candidate needs review and the pending review count is at or
below the configured limit; already approved or rejected candidate history does
not block the idle pass. Maintenance also auto-supersedes clear same-topic
profile conflicts, for example a newer preferred name replacing an older one,
by linking the newer active memory to the older record instead of merging both
facts into one ambiguous memory. Maintenance also auto-expires active memories
whose `validUntil` timestamp has already passed, using the same change request
and audit path instead of physical deletion. The
maintenance pass only calls the configured OpenAI-compatible LLM extractor after
local text-similarity or entity-overlap prefiltering finds nearby active
memories; it sends scoped memory candidates rather than full transcripts or
prompts, and LLM-proposed target ids must stay inside that prefiltered pair or
the daemon falls back to the local proposal. Memory-backed turns that have no
nearby candidates still skip the LLM.
`Clear data` soft-clears the
selected memory scope and rejects pending reviews in that scope; the daemon also
has a confirmation-protected advanced destroy route for wiping memory tables
during development or support.
Memory Explorer can export the currently visible semantic scope as a JSONL
backup and import a JSONL file in either `pending_review` or explicitly selected
`trusted` mode. Pending review creates normal review candidates and skips
disabled/deleted history; trusted import restores active, disabled, and deleted
records directly, including temporal metadata, pinned state, entities, and
supersede links. Import deduplicates existing records, rejects secret-like
content, writes auditable `candidate.create` or `memory.import` events, and
reports skipped records and per-line errors. The daemon export API additionally
supports exact memory scope, kind, status, and creation-date filters.
Candidate handling is controlled by `memory.review.approval_mode`.
`auto_high_confidence` is the default and approves candidates at or above the
configured confidence threshold. Review-band `session_summary`, stable
`user_preference`, `project_rule`, and `architecture_decision` candidates are
also approved once they meet `memory.maintenance.review_threshold`, so useful
memory can flow into retrieval before a manual review pass. Automatic approval
only processes `pending` candidates; approved or rejected history stays visible
for post-run review without being approved again. Review-band stable
memories stay out of the pinned profile layer unless they meet the stricter
pinning threshold. Below-threshold or unknown candidates remain available for
post-run review. `manual` leaves all candidates pending, and
`auto_approve` approves all extracted candidates. Hand-written mode values,
MCP review-policy environment variables, and maintenance API modes are trimmed,
lowercased, and accept spaces or dashes as underscores; unknown review or
maintenance modes fall back to the automatic defaults. The stdio MCP bridge
uses the same `auto_high_confidence` default even when started without explicit
review environment variables.

## Configuration

Use `Agents` -> `Agent Configuration` to manage the saved configuration:
agent servers, the default agent, MCP servers, additional directories,
filesystem/terminal provider switches, permission trust rules, the review
agent, memory extraction/review settings, and memory maintenance settings. The
app persists those GUI choices to:

```text
~/.config/ianvs-acp/settings.json
```

On startup, the app can detect missing local ACP agents and ask whether to add
them to `agent_servers`. The first built-in detector covers Codex through a
local `npx` command running `@zed-industries/codex-acp`.

Saved shape example for automation and debugging:

```json
{
  "default_agent_server": "Codex",
  "agent_servers": {
    "Codex": {
      "type": "custom",
      "command": "/opt/homebrew/bin/npx",
      "cwd": "/Users/example/project",
      "args": ["@zed-industries/codex-acp"]
    }
  },
  "additional_directories": [
    "/Users/example/related-project"
  ],
  "mcp_servers": [
    {
      "name": "filesystem",
      "command": "/opt/homebrew/bin/npx",
      "args": [
        "-y",
        "@modelcontextprotocol/server-filesystem",
        "/Users/example/project"
      ],
      "env": []
    }
  ],
  "client_providers": {
    "permissions": {
      "review_agent": {
        "mcp_server": {
          "name": "permission-reviewer",
          "command": "/opt/homebrew/bin/npx",
          "args": ["-y", "@example/permission-reviewer-mcp"],
          "env": []
        },
        "tool_name": "review_permission",
        "model": "gpt-5-mini"
      }
    }
  },
  "memory": {
    "enabled": true,
    "embedding": {
      "provider": "fastembed-local",
      "model": "intfloat/multilingual-e5-small"
    },
    "extractor": {
      "provider": "acp-sidecar",
      "agent": "Codex",
      "model": "gpt-5-mini",
      "global_instructions": "Remember durable user preferences only.",
      "workspace_instructions": "Ignore one-off workspace chatter.",
      "repo_instructions": "Prioritize project rules and architecture decisions."
    },
    "llm": {
      "provider": "openai-compatible",
      "base_url": "http://127.0.0.1:11434/v1",
      "model": "qwen2.5:7b",
      "api_key_env": "OLLAMA_API_KEY"
    },
    "review": {
      "approval_mode": "auto_high_confidence",
      "auto_open": "high_confidence",
      "high_confidence_threshold": 0.85
    },
    "profile": {
      "max_items": 4
    },
    "maintenance": {
      "enabled": true,
      "mode": "high_confidence_auto",
      "cost_mode": "low_cost",
      "run_after_extraction": true,
      "idle_enabled": true,
      "idle_after_turns": 6,
      "idle_max_pending_reviews": 0,
      "high_confidence_threshold": 0.9,
      "review_threshold": 0.75,
      "max_items_per_batch": 12,
      "manual_only_actions": ["delete"]
    }
  }
}
```

Remote MCP servers can use `type: "http"` or `"sse"` with `url` and optional
`headers`; headers may be either an object or a `name`/`value` list. ACP
transport MCP servers use `type: "acp"` with an `id` provided by the component
that owns the MCP server.

Stdio `agent_servers` can set `cwd` to choose the working directory used when
launching the agent process. The aliases `working_directory` and
`workingDirectory` are also accepted.

`additional_directories` may list extra absolute workspace roots. They are sent
only to agents that advertise `sessionCapabilities.additionalDirectories`, and
filesystem/terminal provider jail checks treat those roots as part of the
session workspace.

`client_providers.permissions.review_agent` can point at a sidecar MCP server
used by the prompt composer’s `自动审查` policy. If no review agent is configured,
`自动审查` starts a sidecar session with the same active ACP agent and passes the
current model. An individual `agent_servers.<name>.review_agent.model` can
override the sidecar review model for that agent. The app sends command
execution context, local workspace/risk analysis, and the selected review model
to the reviewer, records the review opinion, and auto-applies allow/deny
decisions returned by that sidecar. If the sidecar cannot decide or fails, the
request remains available for manual approval.

Supported environment overrides:

- `ACP_CONFIG_PATH`
- `IANVS_ACP_CONFIG`
- `ACP_WORKSPACE_CWD`
- `IANVS_ACP_WORKSPACE_CWD`
- `XDG_CONFIG_HOME`
- `IANVS_MEMORY_CORE_EXE`
- `MEMORY_EMBEDDING_PROVIDER`
- `MEMORY_EMBEDDING_MODEL`
- `MEMORY_EMBEDDING_VARIANT`
- `MEMORY_EMBEDDING_DIMENSION`
- `MEMORY_EMBEDDING_DOWNLOAD_POLICY`
- `MEMORY_EMBEDDING_BASE_URL`
- `MEMORY_EMBEDDING_API_KEY_ENV`

## Development

```sh
flutter analyze
flutter test
flutter build macos --release
```

The ACP integration is hidden behind `AcpAgentClient`, so widget and state tests
use `FakeAgentClient` instead of launching a real agent.
