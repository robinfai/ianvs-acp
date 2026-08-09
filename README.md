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

Starting a new session prompts for the session working directory and offers
local directory path completions while typing.

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
them to `agent_servers`. The built-in detectors cover Codex through a local
`npx` command running `@agentclientprotocol/codex-acp`, and Pi through the
`pi-acp` adapter when both `npx` and the `pi` command are available. A direct
`pi-acp` command or wrapper and `npx -y pi-acp[@version]` are treated as the same
Pi agent, so discovery does not add a duplicate profile. Model provider
credentials for Pi remain user-managed through Pi itself or the agent server
`env` fields in Agent Configuration.

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
        "mcp_server": {
          "name": "permission-reviewer",
          "command": "/opt/homebrew/bin/npx",
          "args": ["-y", "@example/permission-reviewer-mcp"]
        },
        "tool_name": "review_permission",
        "model": "gpt-5-mini"
      }
    }
  },
  "storage": {
    "max_size_gb": 50,
    "retention_days": 30
  }
}
```

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
flutter analyze
./tool/flutter_test_isolated.sh
```

Build and verify a local ad-hoc macOS release:

```sh
flutter build macos --release
./tool/verify_macos_bundle.sh 'build/macos/Build/Products/Release/ACP Client.app'
```

Local ad-hoc builds are for development and verification only. They are not
external release artifacts.

Formal distribution requires `IANVS_DEVELOPER_ID` to identify a Developer ID
Application certificate and `IANVS_NOTARY_PROFILE` to name a configured
`notarytool` Keychain profile. After both are supplied by a protected release
environment, run:

```sh
./tool/package_macos_release.sh
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
flutter run -d macos
./tool/verify_rust_runtime.sh
```

That verification script covers the Rust workspace and the Flutter/Rust
integration boundary used by the packaged macOS app.

Remote ACP transports and unstable MCP-over-ACP are explicitly unavailable
until their Rust transports are implemented; the production app never opens a
parallel compatibility connection. The ownership contract, implemented scope,
and remaining transport and runtime work are tracked in
[Runtime architecture](docs/runtime_architecture.md).
