# ACP Client protocol feature audit

Date: 2026-05-31

This audit uses the official ACP documentation index as the feature list:
https://agentclientprotocol.com/llms.txt

## Summary

The desktop client is now mostly protocol-shaped rather than Codex-specific. Resume discovery uses ACP `session/list`, the selected conversation is loaded through `session/load` or `session/resume`, session settings use ACP session configuration APIs, and timeline rendering is driven by generic ACP session updates.

The largest remaining gaps are client-provided filesystem/terminal providers, authenticate/login UI, and richer prompt-content support. Those are protocol features, but they need product/security decisions rather than only visual work.

## Official Feature Index

| ACP area | Official reference | Current status | Implementation notes |
| --- | --- | --- | --- |
| Transport | https://agentclientprotocol.com/protocol/transports | Done for stdio | `dart_acp` launches the configured agent through stdio. User config supports Zed-style `agent_servers` in `~/.config/ianvs-acp/settings.json`. Streamable HTTP is not implemented. |
| Initialization / capabilities | https://agentclientprotocol.com/protocol/initialization | Partial | The client initializes, parses protocol version, `agentCapabilities`, `authMethods`, prompt/MCP/session capabilities, and shows them in compatibility UI. It does not yet send `clientInfo` or display `agentInfo`. |
| Authentication / logout | https://agentclientprotocol.com/protocol/authentication | Partial | `authMethods` are counted/displayed, and the toolbar exposes confirmed logout when the agent advertises `auth.logout`. There is no `authenticate` workflow yet. |
| Session setup: `session/new`, `session/load`, `session/resume` | https://agentclientprotocol.com/protocol/session-setup | Mostly done | New sessions work. Resume prefers `session/load` when available and falls back to `session/resume`. Empty resumed sessions now render as `Session ready` instead of a misleading new-session empty state. |
| Session close | https://agentclientprotocol.com/protocol/session-setup | Done | Session settings exposes a confirmed `Close Session` action when `sessionCapabilities.close` is advertised. Closing clears the active local session and asks the agent to free resources without deleting persisted history. |
| Session fork | https://agentclientprotocol.com/protocol/session-setup | Done | Session settings exposes `Fork Session` when `sessionCapabilities.fork` is advertised. Forking creates a new active independent session, keeps the original session in history, and clears the local timeline for the fork. |
| Session list / metadata | https://agentclientprotocol.com/protocol/session-list | Done | Resume dialog uses `session/list` with pagination, groups by project, and supports text search at project and conversation levels. `session_info_update` now updates the active session title/time without adding noise to the chat timeline. |
| Prompt turn | https://agentclientprotocol.com/protocol/prompt-turn | Done for text/resource-link prompts | `session/prompt`, streaming, stop/cancel, turn-ended status, and user echo suppression are in place. Attachments are sent as file resource links through `dart_acp` prompt mentions. |
| Content blocks | https://agentclientprotocol.com/protocol/content | Partial | Text, image output preview, resource/resource_link cards, and unknown content fallback render in timeline. Prompt-side image/audio/embedded resource content is not fully enforced by capability checks. File attachments use resource links, which are baseline ACP content, but model/agent-specific support can still vary; Spark may reject or ignore file context even though ACP can represent it. |
| Tool calls / permissions | https://agentclientprotocol.com/protocol/tool-calls | Partial | Tool calls render as compact cards. Consecutive tool calls are grouped by tool name/count and expand on click. Permission requests are answered by `dart_acp` default policy, but there is no interactive permission prompt UI. |
| File system provider | https://agentclientprotocol.com/protocol/file-system | Missing by design | The client currently advertises `fs/read_text_file=false` and `fs/write_text_file=false`; no provider is wired. |
| Terminal provider | https://agentclientprotocol.com/protocol/terminals | Missing by design | The client currently advertises no terminal support; no live terminal UI is wired. |
| Agent plan | https://agentclientprotocol.com/protocol/agent-plan | Done | Plan updates render as structured status cards. Updates now replace the previous plan snapshot, matching ACP's complete-plan replacement semantics. |
| Session modes | https://agentclientprotocol.com/protocol/session-modes | Done, legacy-compatible | Current mode and available modes render in session settings and can be changed through `session/set_mode`. ACP says config options supersede this API, so this remains fallback-compatible. |
| Session config options | https://agentclientprotocol.com/protocol/session-config-options | Partial to done | `session/set_config_option` is supported and config options render in the session settings dialog. `select` options render as dropdowns and `boolean` options render as switches using the ACP boolean wire format. `config_option_update` is now consumed as complete state. The local model understands official `category` as well as older `group`. Initial `configOptions` returned from `session/new` may still be limited by the current `dart_acp` API, which exposes `newSession` as only a session id. |
| Slash commands | https://agentclientprotocol.com/protocol/slash-commands | Display-only | `available_commands_update` renders available commands and details. Command invocation is still manual by typing `/command ...`; there is no command picker/autocomplete. Command-list updates now replace the previous command snapshot. |
| Extensibility / `_meta` | https://agentclientprotocol.com/protocol/extensibility | Partial | Raw capability `_meta` and session list `_meta` are displayed. No custom extension request UI is implemented. |
| MCP servers | https://agentclientprotocol.com/protocol/session-setup | Done for top-level config | User config supports top-level `mcp_servers`, validates JSON-compatible entries, shows configured MCP servers in Agent Configuration, and forwards them through `dart_acp` for session creation/loading. |

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

User-level config follows the requested Zed-inspired shape but does not reuse Zed's file directly.

Default path:

```text
~/.config/ianvs-acp/settings.json
```

Supported shape:

```json
{
  "default_agent_server": "Kimi Code Dev",
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
    }
  },
  "mcp_servers": [
    {
      "name": "filesystem",
      "command": "/opt/homebrew/bin/npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/workspace"]
    }
  ]
}
```

The toolbar `Agents` menu lists configured servers. `default_agent_server` is only the startup default; after launch, the selected agent belongs to the current/new session and is shown on session rows rather than being written back as global config. Creating a new session asks which configured agent to use when more than one server is available.
Top-level `mcp_servers` entries are forwarded to every ACP `session/new` and
`session/load` request for the selected agent.

Session-level model switching uses ACP `configOptions`: when an agent exposes a model-like select option, Session Settings promotes it into a dedicated `Model` dropdown and the status bar shows the current model. Other agent-specific options remain under Config Options.

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

- Decide whether to expose `authenticate`, including where login state should live in the UI.
- Decide whether to enable ACP client filesystem and terminal providers. These require clear permission UX before advertising capabilities.
- Decide whether to add a slash-command picker/autocomplete instead of only rendering advertised commands.
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
