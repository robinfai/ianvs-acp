# ACP Client protocol feature audit

Date: 2026-06-05

This audit uses the official ACP documentation index as the feature list:
https://agentclientprotocol.com/llms.txt
The protocol reference links below use the current v1 documentation paths.

## Summary

The desktop client is now mostly protocol-shaped rather than Codex-specific. Resume discovery uses ACP `session/list`, the selected conversation is loaded through `session/load` or `session/resume`, session settings use ACP session configuration APIs, and timeline rendering is driven by generic ACP session updates.

The largest remaining transport gap is real-agent remote interoperability.
Filesystem and terminal providers are now available only behind explicit user
config and permission approval. WebSocket remote agents are supported, and the
draft Streamable HTTP/SSE path now has a client transport for the RFD's
connection/session SSE model, but HTTP/2 enforcement and live agent validation
still need a dedicated pass.

The GUI now includes a protocol review surface under `Agents` ->
`Protocol Coverage`. It maps each official ACP area to the local
implementation, visible configuration, runtime capability state, user
interaction entry points, and remaining gaps. This keeps the feature audit
available in-product instead of only in Markdown.
`Agents` -> `Agent Configuration` is also the GUI editor for every
user-level field persisted to `settings.json`: `default_agent_server`,
`agent_servers`, `mcp_servers`, `additional_directories`, and
`client_providers`.

The Local Memory Engine is implemented as a local extension around ACP rather
than an ACP transport proxy. When memory is enabled and a daemon endpoint/token
are configured, Flutter injects reviewed memory as background context before
`session/prompt` using the active workspace, repo, and session scope; session
lookups are also tied to the active agent. After prompt turns, Flutter can
extract pending memory candidates through either an ACP sidecar agent or an
OpenAI-compatible LLM endpoint. The Rust `memory-core` daemon owns local
storage, review state, hybrid vector/keyword search, audit history, embeddings,
and its stdio MCP bridge.

## Official Feature Index

| ACP area | Official reference | Current status | Implementation notes |
| --- | --- | --- | --- |
| Transport | https://agentclientprotocol.com/protocol/v1/transports | Partial: stdio, WebSocket, and draft Streamable HTTP/SSE | `dart_acp` launches configured agents through stdio. User config also supports `agent_servers` with `type: "websocket"` and a `ws`/`wss` URL, plus `type: "http"`/`"sse"` and an `http`/`https` URL for the draft Streamable HTTP/SSE profile. The HTTP transport handles `initialize` over POST, keeps `Acp-Connection-Id`/cookies across requests, adds `Acp-Protocol-Version` after initialization, opens connection- and session-scoped SSE streams including forked sessions, routes session POSTs and server-request responses with one-shot `Acp-Session-Id`, handles 202-delivered JSON-RPC responses, and sends best-effort `DELETE` teardown on dispose. HTTP/2 enforcement and real remote-agent interoperability remain hardening follow-ups while the RFD is draft. |
| Initialization / capabilities | https://agentclientprotocol.com/protocol/v1/initialization | Done for metadata/capability negotiation | The client initializes with `clientInfo`, parses protocol version, `agentCapabilities`, `agentInfo`, `authMethods`, prompt/MCP/session capabilities, and shows negotiated metadata in compatibility UI. |
| Authentication / logout | https://agentclientprotocol.com/protocol/v1/authentication | Done for agent-handled auth and stabilized logout | `authMethods` are counted/displayed, the Agent menu exposes `Authenticate` when the agent advertises methods, and the client calls ACP `authenticate` with the selected `methodId`. `auth_required` errors are surfaced as an Authenticate action hint. Confirmed logout remains available when the agent advertises `auth.logout`; successful logout clears cached session state and cancels any pending permission requests. The client does not persist credentials. |
| Session setup: `session/new`, `session/load`, `session/resume` | https://agentclientprotocol.com/protocol/v1/session-setup | Done | New sessions capture initial `session/new` response data such as modes and config options. Resume prefers `session/load` when available and falls back to `session/resume`; fallback `session/resume` also captures initial modes and config options. Configured `additional_directories` / `additionalDirectories` are forwarded only when the agent advertises `sessionCapabilities.additionalDirectories`; sessions returned by `session/list` can carry their own additional directories into resume. Empty resumed sessions now render as `Session ready` instead of a misleading new-session empty state. Initial state updates emitted immediately after `session/new` or `session/resume` are captured for settings and command suggestions. |
| Session close | https://agentclientprotocol.com/protocol/v1/session-setup | Done | Session settings exposes a confirmed `Close Session` action when `sessionCapabilities.close` is advertised. Closing clears the active local session, asks the agent to free resources without deleting persisted history, and cancels pending permission requests for that session. |
| Session fork | https://agentclientprotocol.com/protocol/v1/session-setup | Draft-compatible | Session settings exposes `Fork Session` when `sessionCapabilities.fork` is advertised. Forking now sends `sessionId`, current `cwd`, compatible `mcpServers`, and advertised additional directories when supported, then creates a new active independent session, keeps the original session in history, clears the local timeline for the fork, and captures initial fork response modes/config options plus immediate session updates. The upstream fork RFD is still draft, so live-agent validation remains useful. |
| Session list / metadata | https://agentclientprotocol.com/protocol/v1/session-list | Done | Resume dialog uses `session/list` with pagination, groups by project, supports text search at project and conversation levels, and preserves `additionalDirectories` from listed sessions. `session_info_update` now updates the active session title/time without adding noise to the chat timeline. |
| Prompt turn | https://agentclientprotocol.com/protocol/v1/prompt-turn | Done for text/resource-link/embedded file prompts | `session/prompt`, streaming, stop/cancel, turn-ended status, and user echo suppression are in place. Small text attachments are embedded as `resource.text` when the agent advertises `promptCapabilities.embeddedContext`; image and audio attachments are embedded as `image`/`audio` content when the agent advertises matching prompt capabilities; small generic binary attachments are embedded as `resource.blob` when embedded context is advertised. Prompt-side `@file` and URL mentions are preserved as `resource_link` content even when selected attachments force the raw prompt path, with sentence-ending punctuation kept out of link targets. Unsupported or oversized attachments fall back to `resource_link`. The prompt input marks selected files with capability-aware send modes: Image, Audio, Embed, or Link. |
| Local Memory Engine | Local extension around ACP | Partial: daemon APIs, callable MCP bridge, configured prompt search, and candidate extraction | Flutter carries `MemoryConfig`, Agent Configuration controls for daemon URL/token env, Memory Review/Explorer surfaces, prompt middleware, ACP sidecar extraction, and OpenAI-compatible LLM extraction. Memory defaults off; when `daemon_base_url` and a token env are configured, Flutter calls daemon search with active workspace/repo/session scope, ties session lookups to the active agent, injects returned items as background context before `session/prompt`, then posts extracted candidates after successful turns. Daemon search and extraction failures/timeouts are non-fatal. Rust `memory-core` owns SQLite/sqlite-vec storage, reviewed CRUD/candidates/change requests/audit, hybrid vector/keyword scope-filtered search/formatting, local and OpenAI-compatible embedding providers, daemon APIs, and MCP stdio `memory.search`/`memory.list`/`memory.remember` calls. `memory-core` never proxies ACP. Full daemon auto-start, live review action wiring, clear-data UX, and real extraction-quality validation remain follow-ups. |
| Content blocks | https://agentclientprotocol.com/protocol/v1/content | Mostly done | Text, image output preview, audio content metadata, resource/resource_link cards, and unknown content fallback render in timeline. Prompt-side text and generic binary attachments are gated by `embeddedContext`, image attachments by `image`, and audio attachments by `audio`, with the same mode classification reused by the prompt UI. File links remain available as fallback, but model/agent-specific support can still vary. |
| Tool calls / permissions | https://agentclientprotocol.com/protocol/v1/tool-calls | Done for per-request approval, explicit trust rules, prompt-side sidecar review, prompt-side execution policy, and exportable bounded in-process history | Tool calls render as compact cards. Consecutive tool calls are grouped by tool name/count and expand on click, with chunk coalescing across common call id aliases. `session/request_permission` now surfaces an in-app approval card inside the prompt composer with Allow Once, Deny, and Cancel actions, using agent-provided allow/deny labels when they are more specific. The prompt composer exposes tool-call execution policy modes: `默认权限` keeps all requests manual, `自动审查` applies configured trust rules first, then calls either a configured sidecar MCP review agent or a default sidecar session with the same active ACP agent/model, and asks for undecided requests; `完全访问权限` auto-allows requests. Requests are recorded in the Agents menu Permission History as pending, allowed, denied, or cancelled, keep the newest bounded in-process audit entries, can be exported as JSON, and include whether a resolved decision came from a manual action, trust rule, review agent, policy, or system cancellation. Explicit `client_providers.permissions.trust_rules` can auto-allow or auto-deny matching tool requests and are editable in Agent Configuration. `client_providers.permissions.review_agent` can point to a sidecar MCP server/tool and optional model; review opinions and decisions are stored with the audit entry. When no UI listener is active, requests are conservatively returned as `cancelled` instead of being auto-approved; when the permission stream closes or session teardown completes through close/logout, pending requests are cancelled. Long-term persisted audit retention remains a product/security follow-up. |
| File system provider | https://agentclientprotocol.com/protocol/v1/file-system | Done with GUI config when explicitly enabled | The client defaults to `fs/read_text_file=false` and `fs/write_text_file=false`. Agent Configuration can enable `client_providers.filesystem.read_text_file`, `write_text_file`, and `allow_read_outside_workspace`; requests are workspace-jailed to `cwd` plus advertised additional directories by default and still require permission approval unless matched by an explicit permission trust rule. `allow_read_outside_workspace` only relaxes reads, never writes. |
| Terminal provider | https://agentclientprotocol.com/protocol/v1/terminals | Done with GUI config when explicitly enabled | The client defaults to no terminal support. Agent Configuration can enable `client_providers.terminal.enabled`; terminal creation still requires permission approval unless matched by an explicit permission trust rule, cwd is workspace-jailed by default, and lifecycle/output snapshots render in the timeline. A persistent live terminal panel remains a product follow-up. |
| Agent plan | https://agentclientprotocol.com/protocol/v1/agent-plan | Done | Plan updates render as structured status cards. Updates now replace the previous plan snapshot, matching ACP's complete-plan replacement semantics. |
| Session modes | https://agentclientprotocol.com/protocol/v1/session-modes | Done, legacy-compatible | Current mode and available modes render in session settings and can be changed through `session/set_mode` only when the agent does not provide `configOptions`. ACP says config options supersede this API, so this remains fallback-compatible. |
| Session config options | https://agentclientprotocol.com/protocol/v1/session-config-options | Done | `session/set_config_option` is supported and config options render in the session settings dialog. `select` options render as dropdowns and `boolean` options render as switches using the ACP boolean wire format; unsupported raw option types are ignored. `config_option_update` is consumed as complete state, including updates emitted immediately after `session/new`. The local model understands official `category` as well as older `group`. Initial `configOptions` returned directly by `session/new` and fallback `session/resume` are captured from the raw session response. Legacy/unstable `models` state is promoted into a local model config option when stable `configOptions` are missing; changing that synthesized option calls `session/set_model`. When `configOptions` are available, the client ignores legacy `modes` for settings display, status bar state, runtime updates, and local mode changes, matching ACP's config-options-preferred guidance. |
| Slash commands | https://agentclientprotocol.com/protocol/v1/slash-commands | Done for advertised commands | `available_commands_update` renders available commands and details. The prompt input now suggests matching advertised commands while typing `/`, and selecting a command inserts the slash invocation. Command-list updates replace the previous command snapshot, including updates emitted immediately after `session/new` or `session/resume`. |
| Extensibility / `_meta` | https://agentclientprotocol.com/protocol/v1/extensibility | Mostly done for manual extension requests | Raw capability `_meta` and session list `_meta` are displayed. The Agents menu exposes an advanced Extension Request dialog that validates underscore-prefixed custom methods, accepts JSON object params, sends JSON-RPC requests, and renders raw results/errors. Vendor-specific workflows remain intentionally unopinionated. |
| MCP servers | https://agentclientprotocol.com/protocol/v1/session-setup | Done with GUI config | User config supports top-level `mcp_servers`, validates JSON-compatible entries, known transport types, transport-specific `command`/`url` requirements, and remote headers as either an object or name/value list. Agent Configuration can create, edit, and delete MCP servers, and compatible entries are forwarded through `dart_acp` for session creation/loading. Stdio entries are always allowed; HTTP, SSE, and ACP transport entries are only forwarded when advertised in `mcpCapabilities`. Unknown transport types are rejected from config and skipped if injected programmatically. |
| ACP Registry | https://agentclientprotocol.com/get-started/registry | Follow-up: official feature is stable; local Codex discovery exists | The official Registry is now stabilized and provides a standard way to discover, install, and configure compatible agents. This client does not yet browse/import/install registry entries, but startup discovery can add a missing local Codex ACP adapter entry to the saved user config, and Agent Configuration can edit that entry afterwards. The new Protocol Coverage GUI makes the remaining Registry gap visible in-product while Registry strategy remains a product follow-up. |

## UX Review With Computer Use

Reviewed the debug macOS app using Computer Use at a compact desktop window size around 800x630.

Observed:

- Initial empty state is clean and compact.
- Resume dialog successfully connected to Kimi Code Dev, listed ACP sessions through `session/list`, grouped by project, and offered project/conversation search.
- Loading a Kimi session that advertises `session/resume` without `session/load` produced no replayed messages. Before this change, the main area still said "Start a session", which was misleading.
- The sidebar header contained a no-op filter-looking icon. That is now a real Resume entry.
- Several custom `InkWell` icon controls were hard to identify in the accessibility tree. Toolbar actions, status icons, sidebar Resume, and attachment button now have explicit semantics labels.
- Compatibility and session settings dialogs are visually usable and dense enough, but capabilities can exceed the visible dialog height on small windows; scrolling handles this.

Fixes applied:

- Active empty timeline now shows `Session ready` and mentions that no replayed messages were returned.
- Resumed session titles from `session/list` and `session_info_update` are used in the sidebar instead of only short ids.
- Sidebar header action opens Resume instead of doing nothing.
- Plan and slash-command status snapshots replace previous snapshots instead of accumulating stale cards.
- `config_option_update` is handled as a state update rather than an unknown timeline message.
- Self-built icon controls received semantics labels for better desktop accessibility and easier automated testing.

## User Configuration

User-level config follows the requested Zed-inspired shape but does not reuse Zed's file directly. Users should change it through `Agents` -> `Agent Configuration`; `settings.json` is the persistence format.

Default path:

```text
~/.config/ianvs-acp/settings.json
```

Saved shape:

```json
{
  "default_agent_server": "Kimi Code Dev",
  "additional_directories": [
    "/Users/luobinghui/projects/shared"
  ],
  "agent_servers": {
    "Kimi Code Dev": {
      "type": "custom",
      "command": "/Users/luobinghui/projects/kimi/kimi-code/apps/kimi-code/dist/main.mjs",
      "args": ["acp"],
      "env": {
        "KIMI_API_KEY": "..."
      }
    },
    "Codex": {
      "type": "custom",
      "command": "/opt/homebrew/bin/npx",
      "args": ["@zed-industries/codex-acp"]
    },
    "Remote Agent": {
      "type": "websocket",
      "url": "wss://agent.example.com/acp",
      "headers": {
        "Authorization": "Bearer ..."
      }
    },
    "Remote HTTP Agent": {
      "type": "http",
      "url": "https://agent.example.com/acp",
      "headers": {
        "Authorization": "Bearer ..."
      }
    }
  },
  "mcp_servers": [
    {
      "name": "filesystem",
      "command": "/opt/homebrew/bin/npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/workspace"],
      "env": []
    }
  ],
  "client_providers": {
    "filesystem": {
      "read_text_file": true,
      "write_text_file": false,
      "allow_read_outside_workspace": false
    },
    "terminal": {
      "enabled": false
    },
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
      },
      "trust_rules": [
        {
          "tool_name": "read_text_file",
          "tool_kind": "read",
          "decision": "allow"
        }
      ]
    }
  }
}
```

The toolbar `Agents` menu opens Agent Configuration for creating, editing,
deleting, and selecting the default configured server. Stdio/custom agent
servers use `command`, `args`, and `env`; remote WebSocket and Streamable
HTTP/SSE agent servers use `url` plus optional `headers`.
`default_agent_server` is only the startup default; after launch, the selected
agent belongs to the current/new session and is shown on session rows rather
than being written back as global config. Creating a new session asks which
configured agent to use when more than one server is available.
Compatible top-level `mcp_servers` entries are forwarded to every ACP
`session/new` and `session/load` request for the selected agent. Supported MCP
transport types are `stdio`, `http`, `sse`, and `acp`; ACP transport entries
use a component-provided `id` instead of `command` or `url`. Agent Configuration
can create, edit, and delete these MCP server entries. Stdio entries are always
forwarded; HTTP, SSE, and ACP transport entries require matching agent
`mcpCapabilities`.
Agent Configuration lets users add or remove configured
`additional_directories` / `additionalDirectories`; paths must be absolute
local paths. They are forwarded only when the agent advertises
`sessionCapabilities.additionalDirectories`, and used by filesystem/terminal
jail checks as additional workspace roots for that session.
Agent Configuration controls `client_providers.filesystem`, which determines
whether the client advertises ACP file-system callbacks. Filesystem providers
are off by default; when enabled, read/write requests still go through
permission approval unless matched by an explicit trust rule, and writes remain
confined to the session workspace.
Agent Configuration controls `client_providers.terminal.enabled`, which
determines whether the client advertises ACP terminal callbacks. Terminal
support is off by default; when enabled, terminal creation still goes through
permission approval unless matched by an explicit trust rule, uses the session
workspace as the default cwd, and renders command lifecycle status/output in
the timeline.
Agent Configuration lets users add, edit, or remove
`client_providers.permissions.trust_rules`, which can auto-resolve matching
permission requests with an explicit `allow` or `deny` decision. Rules match by
`tool_name` and can optionally narrow by `tool_kind`; no rules are configured by
default. The prompt composer exposes the runtime tool-call execution policy.
Agent Configuration controls `client_providers.permissions.review_agent`, which
can call a sidecar MCP review tool during `自动审查`. When no review agent is
configured, `自动审查` uses a sidecar session with the same active ACP agent and
passes the current model; `agent_servers.<name>.review_agent.model` can override
the model for that agent's sidecar reviewer. The review payload is intentionally
limited to the permission request, command/cwd/workspace context when available,
local risk signals, and the selected review model. Returned allow/deny/cancel
decisions are applied automatically and recorded; undecided or failed reviews
leave the prompt composer approval card available for manual action.
When connected, the Agents menu exposes `Extension Request` for advanced
underscore-prefixed ACP extension methods advertised through `_meta` or otherwise
coordinated by a specific agent.

Session-level model switching prefers ACP `configOptions`: when an agent exposes
a model-like select option with choices, Session Settings promotes it into a
dedicated `Model` dropdown, the prompt composer mirrors it near the send
controls, and the status bar shows the current model. When stable
`configOptions` are missing but the session response includes legacy/unstable
`models` state (`currentModelId` plus `availableModels`), the client synthesizes
a local model config option from that state and sends model changes through
`session/set_model`. When no model choices are available, both model controls
are hidden rather than rendered as disabled placeholders. Other agent-specific
options remain under Config Options. If an agent sends both `configOptions` and
legacy `modes`, Session Settings uses the config options and hides the legacy
Mode control.

Environment overrides:

- `ACP_CONFIG_PATH`
- `IANVS_ACP_CONFIG`
- `ACP_WORKSPACE_CWD`
- `IANVS_ACP_WORKSPACE_CWD`
- `XDG_CONFIG_HOME`

## Manual Follow-Ups

These are not blockers for the current UI pass, but need product/security decisions:

Detailed tracking and automated acceptance evidence lives in
`docs/manual_followups.md`.

- Review filesystem and terminal providers policy: both are available behind Agent Configuration, prompt-side permission approval, prompt-side execution policy, explicit trust rules, and exportable bounded in-process permission history, but long-term persisted audit retention and richer terminal controls remain undecided.
- Finish remote transport hardening: WebSocket and draft Streamable HTTP/SSE work in automated local tests, while HTTP/2 enforcement and real remote-agent validation are still pending.
- Design vendor-specific extension workflows only when a real agent's `_meta` contract requires more than the generic Extension Request dialog.
- Confirm expected behavior for Spark attachments. ACP can represent file resource links, but a specific agent/model may still decline or ignore them.

## Follow-Up Desktop UX Pass

Date: 2026-05-30

Scope:

- Launched the debug macOS app from the built `.app` bundle to approximate a normal desktop user path.
- Computer Use could list running apps, but `get_app_state` returned `cgWindowNotFound` and coordinate clicks timed out across multiple apps. System window enumeration and window screenshots still worked, so this pass used screenshots for visual review.

Fixed:

- The macOS title bar and bundle name showed the engineering name `ianvs_acp`; the app now uses `ACP Client`.
- Launching the app through Finder/`open` made `Directory.current.path` resolve to `/`, so new ACP sessions defaulted to the filesystem root. The client now resolves the workspace from `ACP_WORKSPACE_CWD` / `IANVS_ACP_WORKSPACE_CWD`, then a useful current directory, then `PWD`, then `HOME`.
- The main empty timeline said to start a session but had no local action. It now exposes a primary `New Session` button alongside the sidebar action.
- The macOS window was freely resizable below the fixed desktop layout's usable width. The window now has a minimum size of 760 x 560.

Recorded non-blockers:

- At the default compact macOS size, top-right toolbar secondary actions collapse to icons only. Tooltips/semantics exist, and the main empty state now provides a visible primary action.
- The bottom status bar intentionally prioritizes current state controls on the right; long workspace paths may be truncated in compact windows.
- This environment still needs manual interaction validation once Computer Use accessibility/window capture works again, especially text-field focus, attachment picker, and real agent connection flows.
