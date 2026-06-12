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
or the app exits. Flutter queries the daemon search API with the active
workspace, repo, and session scope. Session-scoped lookup is also tied to the
active agent, so same session ids from different agents do not mix. Returned
memories are added as background context before the normal ACP
`session/prompt`; the daemon does not proxy ACP traffic. Daemon search failures
or timeouts are non-fatal and leave the original prompt intact.

The daemon owns storage, hybrid vector/keyword search, audit history, local
embedding support, OpenAI-compatible embedding calls, and its stdio MCP bridge.
Memory writes and explicit rebuilds update the sqlite-vec index; search uses
vector hits when available and falls back to keyword matching if indexing is
unavailable. After prompt turns, Flutter can extract memory candidates through
either an ACP sidecar agent or an OpenAI-compatible LLM endpoint. The configured
rules fallback also captures conservative explicit remember requests such as
preferred names and project rules, and skips likely secrets. Exact duplicate
candidates are suppressed before review when the same normalized fact already
exists as active memory or as a pending candidate, and the daemon writes a
`candidate.skip_duplicate` audit event. Depending on the configured review
mode, new candidates can stay manual, auto-approve only when high confidence,
or auto-approve every candidate that passes the daemon's filtering policy. In
threshold-based automatic modes, candidates below the auto-approve threshold are
skipped with an audit event instead of becoming pending review noise; candidates
without confidence are treated as below threshold.
Auto-approved candidates and candidates approved through the daemon approval
endpoint trigger automatic maintenance: the daemon runs a high-confidence
low-cost pass, then Flutter calls the configured LLM/ACP maintenance extractor
with a broader current-scope memory batch, prioritizing likely related records
but no longer dropping unrelated records before the LLM review.
The current MCP bridge exposes callable `memory.search`, `memory.list`,
`memory.remember`, `memory.update`, and `memory.forget` tools. `memory.remember`
uses the same candidate-review API as the extractor and can auto-approve via
either an explicit `autoApproveThreshold` argument or a
`MEMORY_AUTO_APPROVE_THRESHOLD` process default. When Memory is enabled,
Flutter appends an app-owned `ianvs-memory` stdio MCP server to agent sessions
after the daemon exposes its dynamic local endpoint; user-defined MCP servers
with the same name are left untouched. Candidate creation and change requests
use separate MCP defaults: `MEMORY_AUTO_APPROVE_THRESHOLD` controls
`memory.remember`, while `MEMORY_CHANGE_REQUEST_AUTO_APPROVE_THRESHOLD`
controls `memory.update` and `memory.forget`. Without an automatic change
request threshold, `memory.update` and `memory.forget` keep the conservative
pending Change request path. When a tool call includes confidence and an
`autoApproveThreshold`, or the MCP process provides a change-request threshold,
`memory.update` runs through the same high-confidence maintenance policy:
high-confidence non-cleanup updates are applied automatically, while
lower-confidence or missing-confidence updates are skipped instead of becoming
review noise. `memory.forget` maps to delete, so high-confidence forget requests
stay pending for manual cleanup review and lower-confidence or missing-confidence
forget requests are skipped.
Review and explorer UI surfaces are present.
Extraction and maintenance prompts plus daemon candidate/maintenance policy reject AGENTS.md,
system/developer/agent operating constraints, and tool-use rules so local
instruction files do not become long-term memory.
`Change requests` lists real pending update/delete/merge proposals, supports
batch approval for non-cleanup maintenance suggestions, supports batch rejection
for pending suggestions, and keeps cleanup requests on per-item approval.
Pending candidate memories can be edited individually, approved in a batch, or
rejected in a batch.
`All memory` shows active and disabled records, excluding soft-deleted records,
and includes a manual `Organize` action. Organize sends a broader current-scope
active/disabled memory batch to the configured ACP sidecar or OpenAI-compatible
extractor, prioritizing nearby records without hiding the rest of the batch,
to propose maintenance change requests, including each record's active/disabled
status. After applying or skipping those suggestions, the daemon still runs its
built-in low-cost sweep so LLM output cannot hide disabled cleanup or directional
merge opportunities.
Auto-approved candidates and manually approved candidates trigger the same
automatic maintenance path with a broader current-scope batch, so users mostly
review the resulting audit and cleanup requests.
In `high_confidence_auto` maintenance mode, mid-confidence
suggestions are skipped instead of becoming review noise; high-confidence
non-cleanup suggestions can be approved automatically, while cleanup actions
such as delete, disable, and expire stay pending for review. Built-in maintenance merges
active memories, and active/disabled overlap that still carries useful
differences, toward broader scopes in the `session -> repo -> global` direction.
Same narrow-scope duplicates promote one step at a time, while merges involving
an already broader scope never downgrade it, so session plus global stays global.
It treats workspace scope as a legacy compatibility layer rather than a promotion
stop, and creates
cleanup requests for high-confidence disabled duplicates.
When a merge is approved or auto-applied, the merged active memory is created and
the old target memories are soft-deleted, so All memory does not keep showing
disabled duplicates after organization.
The `manual_only_actions` setting is additive for maintenance review policy:
`delete`, `disable`, and `expire` are always treated as cleanup review actions
even if an older settings file only listed `delete`.
`Audit log` shows real daemon events, including memory retrievals, approvals,
maintenance runs, and automatic approvals. Clear-data controls are still
guarded until their backend callback is connected.

MCP callers can use single-item memory inputs. For example, `memory.remember`
accepts `scope`, `kind`, `memoryScope`, `text`, optional `reason`, and optional
`confidence`; the bridge converts that into the daemon candidate-review format
and applies `autoApproveThreshold` when supplied. If the MCP process has
`MEMORY_AUTO_APPROVE_THRESHOLD` set to a value from `0` to `1`, that threshold is
used when the tool call omits one. `memory.update` accepts `scope`,
`targetMemoryId`, `proposedText`, optional `proposedKind` / `proposedScope`,
optional `confidence`, and optional `autoApproveThreshold`; `memory.forget`
accepts `scope`, `targetMemoryId`, optional `confidence`, and optional
`autoApproveThreshold`. For update/forget calls, the MCP process can also set
`MEMORY_CHANGE_REQUEST_AUTO_APPROVE_THRESHOLD`; this keeps maintenance
automation independent from candidate-review policy.

## Configuration

Use `Agents` -> `Agent Configuration` to manage the saved configuration:
agent servers, the default agent, MCP servers, additional directories,
filesystem/terminal provider switches, permission trust rules, the review
agent, and memory settings. The app persists those GUI choices to:

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
      "model": "gpt-5-mini"
    },
    "llm": {
      "provider": "openai-compatible",
      "base_url": "http://127.0.0.1:11434/v1",
      "model": "qwen2.5:7b",
      "api_key_env": "OLLAMA_API_KEY"
    },
    "review": {
      "mode": "high_confidence_auto",
      "high_confidence_threshold": 0.85
    },
    "maintenance": {
      "enabled": true,
      "mode": "high_confidence_auto",
      "cost_mode": "low_cost",
      "high_confidence_threshold": 0.9,
      "review_threshold": 0.75,
      "max_items_per_batch": 50,
      "manual_only_actions": ["delete", "disable", "expire"]
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
