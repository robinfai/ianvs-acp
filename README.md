# ACP Client

A Flutter macOS desktop client for local Agent Client Protocol agents.

The app launches local stdio ACP agents through its Rust runtime, creates and
restores sessions, streams prompt turns, renders plans and tool calls, switches
advertised model/session options, and handles authentication, permissions,
filesystem callbacks, and terminal callbacks. Prompt attachments can be
selected or dropped onto the composer; file, image, and audio content follows
the negotiated prompt capabilities, with resource-link fallback where needed.

See [Product capabilities](docs/product_capabilities.md),
[ACP runtime coverage](docs/acp_runtime_coverage.md), and
[Runtime architecture](docs/runtime_architecture.md). Open decisions and manual
release checks are tracked in [Manual follow-ups](docs/manual_followups.md).

Starting a new session prompts for the session working directory, offers local
directory path completions while typing, and can apply a versioned session
template that selects the agent runtime, MCP set, workspace roots, permission
policy, assistant enhancer, mode, model, and reasoning effort.

Multiple conversations can remain active in the same window. Switching or
starting another session does not interrupt an in-flight response; prompt
cancellation and permission requests remain scoped to their session. Controllers
with the same exact runtime recipe share one authoritative ACP runtime; templates
that intentionally change MCP or client-provider boundaries use isolated
runtimes so a broader recipe cannot leak capabilities into a restricted one.

## Configuration

Use `Agents` -> `Agent Configuration` to manage the saved configuration:
agent servers, the default agent, MCP servers, additional directories,
filesystem/terminal provider switches, permission trust rules, the review
agent, assistant-agent settings, and local recovery storage settings. The app
persists those GUI choices to:

```text
~/.config/ianvs-acp/settings.json
```

On macOS, Agent and MCP `env`/`headers` values entered in Agent Configuration
are stored in the login Keychain. The JSON file stores only opaque
`env_refs`/`header_refs`; do not edit or copy those references between config
files. Existing plaintext values are migrated to Keychain before the JSON is
atomically replaced. If a referenced Keychain item is missing, startup reports
the exact field and keeps configuration editing disabled until the credential
is restored or re-entered.

On startup, the app can detect missing local ACP agents and ask whether to add
them to `agent_servers`. The built-in detectors cover:

- Codex through a local `npx` command running
  `@agentclientprotocol/codex-acp`.
- Pi through the `pi-acp` adapter when both `npx` and the `pi` command are
  available.
- Cursor through its separately installed CLI (`agent acp`), including the
  `cursor-agent` executable alias. The official installer places `agent` in
  `~/.local/bin` by default.
- CodeBuddy through an installed `codebuddy --acp` command, with
  `npx -y @tencent-ai/codebuddy-code --acp` as a fallback.

Equivalent direct commands, aliases, and npx packages are treated as the same
agent so discovery does not add duplicate profiles. Provider credentials remain
user-managed through each CLI or the agent server `env` fields in Agent
Configuration. Install and authenticate the Cursor CLI before using its ACP
profile; installing the Cursor desktop editor alone does not guarantee that the
separate CLI is available.

Saved shape example for automation and debugging:

```json
{
  "default_agent_server": "Codex",
  "agent_servers": {
    "Codex": {
      "type": "custom",
      "command": "/opt/homebrew/bin/npx",
      "cwd": "/Users/example/project",
      "args": ["@agentclientprotocol/codex-acp"]
    },
    "Pi": {
      "type": "custom",
      "command": "/opt/homebrew/bin/npx",
      "cwd": "/Users/example/project",
      "args": ["-y", "pi-acp@0.0.31"]
    },
    "Cursor": {
      "type": "custom",
      "command": "/Users/example/.local/bin/agent",
      "cwd": "/Users/example/project",
      "args": ["acp"]
    },
    "CodeBuddy": {
      "type": "custom",
      "command": "/opt/homebrew/bin/codebuddy",
      "cwd": "/Users/example/project",
      "args": ["--acp"]
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
      ]
    }
  ],
  "client_providers": {
    "permissions": {
      "review_agent": {
        "agent_server_name": "Codex",
        "model": "review-model"
      }
    }
  },
  "default_session_template": "review",
  "session_templates": {
    "review": {
      "name": "Code review",
      "version": 1,
      "agent_server": "Codex",
      "mcp_servers": ["filesystem"],
      "additional_directories": ["/Users/example/related-project"],
      "mode": "plan",
      "model": "review-model",
      "reasoning_effort": "high"
    }
  },
  "storage": {
    "max_size_gb": 50,
    "retention_days": 30
  }
}
```

`session_templates` are declarative, versioned recipes shown in the New
Session dialog. Omitting `mcp_servers` inherits every configured MCP server;
an empty array selects none. Template permission settings replace the global
permission policy for that runtime, while omitted fields inherit the active
configuration. Templates are currently edited in `settings.json`; Agent
Configuration preserves them during unrelated GUI edits. The selected
template ID and version are retained in the local session index, so resumed
sessions can report missing definitions or version drift.

The `Agents` menu exposes `Session Activity`, a chronological prompt/response,
tool, status, permission, and error trajectory for the active session, plus
`Runtime Inventory`, which reports the exact template runtime, MCP/providers,
negotiated ACP capabilities, credential-reference counts, and degradations.
Credential values and URL credentials/query strings are never displayed.

`storage.max_size_gb` and `storage.retention_days` bound two recovery payload
stores: the ACP session registry and the exact-revision transcript cache. Each
store enforces the configured capacity independently, and expired payloads are
removed automatically.

The adjacent private `workspace_ui_state.json` file stores Workspace/sidebar
preferences and a recovery index containing session IDs, workspace roots,
display titles, agent association, and pin/archive/unread state. It is written
atomically, and concurrent app windows merge independent Workspace/session
record fields plus expanded-Workspace additions and removals. It is not
governed by `storage.max_size_gb` or `storage.retention_days`; those entries
remain until the corresponding UI state is changed or removed. See the
[local recovery storage policy](docs/sqlite_storage.md) for the data inventory
and maintenance behavior.

Remote MCP servers can use `type: "http"` or `"sse"` with `url` and optional
`headers`; enter secret header values through Agent Configuration so they are
stored in Keychain rather than plaintext JSON. ACP
transport MCP servers use `type: "acp"` with an `id` provided by the component
that owns the MCP server.

Stdio `agent_servers` can set `cwd` to choose the working directory used when
launching the agent process. The aliases `working_directory` and
`workingDirectory` are also accepted.

`additional_directories` may list extra absolute workspace roots. They are sent
only to agents that advertise `sessionCapabilities.additionalDirectories`, and
filesystem/terminal provider jail checks treat those roots as part of the
session workspace.

`client_providers.permissions.review_agent` can select a configured ACP agent
with `agent_server_name`, or point at a sidecar MCP server, for the prompt
composer's `自动审查` policy. ACP reviewers run in an isolated sidecar client and
session, so they can automatically approve a low-risk `allow` decision even
when they use the same agent or model as the main session. An individual
`agent_servers.<name>.review_agent.model` can override the review model for that
agent. High-risk or inconclusive results remain available for manual approval.

Supported environment overrides:

- `ACP_CONFIG_PATH`
- `IANVS_ACP_CONFIG`
- `ACP_WORKSPACE_CWD`
- `IANVS_ACP_WORKSPACE_CWD`
- `XDG_CONFIG_HOME`

## Mermaid Rendering

Assistant messages can render fenced Mermaid blocks directly:

````markdown
```mermaid
flowchart TD
  A --> B
```
````

The reusable Flutter surface is:

```dart
MermaidView(
  source: 'flowchart TD\nA --> B',
)
```

Default renderer: `package:merman` through Dart FFI on native platforms.

SVG display: `flutter_svg`.

SVG pipeline: `resvg-safe`.

SVG compatibility: Mermaid CSS rules are inlined before display so native SVG
rendering does not fall back to black default fills when `flutter_svg` ignores
`<style>` blocks.

Cache: in-memory LRU keyed by Mermaid source, options JSON, and merman engine
version.

Use `NativeMermanRenderer` when a screen needs to reuse one engine instance,
`MermaidController` when a live editor needs render state, and
`layoutJson()` when interaction overlays need node or edge geometry.

## Development

```sh
make help
make bootstrap
make verify
```

Run the app locally with `make run`. The default `make` target only prints the
available commands and does not build, test, clean, or publish anything.

Build and verify a local ad-hoc macOS release:

```sh
make build
make verify-macos
```

Install the verified local build into `/Applications` with `make install`.
Use `make install INSTALL_DIR=/absolute/directory` to install elsewhere. An
existing app is replaced only after the staged copy passes bundle verification;
the previous app is restored if installation or final verification fails.

Local ad-hoc builds are for development and verification only. They are not
external release artifacts.

Formal distribution requires `IANVS_DEVELOPER_ID` to identify a Developer ID
Application certificate and `IANVS_NOTARY_PROFILE` to name a configured
`notarytool` Keychain profile. After both are supplied by a protected release
environment, run:

```sh
make package-macos
```

The release script fails when either credential is missing. It signs nested
code from the inside out, verifies the Developer ID signature and secure
timestamp, submits the archive for notarization, staples and validates the
ticket, runs Gatekeeper assessment, and produces `build/ACP-Client.zip`.

The ACP integration is hidden behind `AcpAgentClient`, so widget and state tests
use `FakeAgentClient` instead of launching a real agent.

## Runtime architecture

ACP has one production authority: a pure Rust Core behind a typed FFI host.
Rust owns the local stdio/session/prompt/permission path, stable session
lifecycle and configuration, workspace-scoped attachments, configured
filesystem and terminal reverse requests, and process recovery. Flutter owns
workspace/session projections and human interaction.

Stable stdio/HTTP/SSE MCP server configuration is projected by Rust into session
new/load/resume. Filesystem and terminal reverse requests use the ordinary
permission flow and follow the selected client policy. The ACP client does not
classify commands or destinations as external egress; external side effects are
owned by the agent and its tools:

```sh
make run
make test-rust
```

That verification script covers the Rust workspace and the Flutter/Rust
integration boundary used by the packaged macOS app.

Remote ACP transports and unstable MCP-over-ACP are explicitly unavailable
until their Rust transports are implemented; the production app never opens a
parallel compatibility connection. The ownership contract, implemented scope,
and remaining transport and runtime work are tracked in
[Runtime architecture](docs/runtime_architecture.md).
