# ACP Client

A Flutter Linux and macOS desktop client for local Agent Client Protocol
agents.

The app launches local stdio ACP agents through its Rust runtime, creates and
restores sessions, streams prompt turns, renders plans and tool calls, switches
advertised model/session options, and handles authentication, permissions,
filesystem callbacks, and terminal callbacks. Prompt attachments can be
selected or dropped onto the composer; file, image, and audio content follows
the negotiated prompt capabilities, with resource-link fallback where needed.

Task Inbox uses the same Rust Core for durable Task/Run state, automatic
scheduling, retry admission, runtime quotas, and workspace leases. Human-input
and approval waits pause the run and surface the decision context in Inbox.

See [Product capabilities](docs/product_capabilities.md),
[ACP runtime coverage](docs/acp_runtime_coverage.md), and
[Runtime architecture](docs/runtime_architecture.md). Open decisions and manual
release checks are tracked in [Manual follow-ups](docs/manual_followups.md).

Starting a new session prompts for the session working directory and offers
local directory path completions while typing.

## Configuration

Use `Agents` -> `Agent Configuration` to manage the saved configuration:
agent servers, the default agent, MCP servers, additional directories,
filesystem/terminal provider switches, permission trust rules, and the review
agent. The app persists those GUI choices to:

```text
~/.config/ianvs-acp/settings.json
```

Agent and MCP `env`/`headers` values entered in Agent Configuration are stored
in the platform credential service: login Keychain on macOS and Secret Service
through `secret-tool` on Linux. The JSON file stores only opaque
`env_refs`/`header_refs`; do not edit or copy those references between config
files. Existing plaintext values are migrated before the JSON is atomically
replaced. If a referenced credential is missing, startup reports the exact
field and keeps configuration editing disabled until the credential is
restored or re-entered. Linux users need a running Secret Service provider
(for example GNOME Keyring or KWallet) and the `secret-tool` command.

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
  }
}
```

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

Linux development additionally needs a C++ toolchain, CMake, Ninja, pkg-config,
GTK 3 development headers, and `secret-tool`. On Debian/Ubuntu:

```sh
sudo apt-get install clang cmake ninja-build pkg-config libgtk-3-dev \
  libsecret-tools liblzma-dev
flutter run -d linux
flutter build linux --release
```

The Linux CMake build compiles the Rust FFI library and `ianvs-acpd`, then
places `libianvs_acp_ffi.so` under the bundle `lib/` directory and the daemon
beside the app executable.

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

ACP and Workflow have one production authority: a pure Rust Core behind typed
FFI and daemon hosts. Rust owns the local stdio/session/prompt/permission path,
stable session lifecycle and configuration, workspace-scoped attachments,
configured filesystem and terminal reverse requests, process recovery,
Task/Run state, and scheduler admission. Flutter owns product projections and
human interaction.

Stable stdio/HTTP/SSE MCP server configuration is projected by Rust into session
new/load/resume. Filesystem and terminal reverse requests use the ordinary
permission flow and follow the selected client policy. The ACP client does not
classify commands or destinations as external egress; external side effects are
owned by the agent and its tools:

```sh
flutter run -d linux # or: flutter run -d macos
./tool/verify_rust_runtime.sh
```

The same native library exposes a typed, revisioned, transactionally durable
Task/Run Workflow authority. Imported TaskInbox v1 snapshots follow an explicit
`staged -> ready -> active` migration with an immutable source archive. Once
active, typed host operations atomically update
Rust-owned Task/Run state, events, artifacts, approvals, resources, and the
revisioned UI projection; generic state overwrites remain unavailable. Rust
also owns atomic scheduler claims with priority, retry-readiness, runtime quota,
workspace-lease, and per-agent availability admission. Flutter consumes the
Core-selected claim and retry wake-up without recomputing those decisions.

Workflow IR runs are reconciled into Task Inbox by the daemon. Ready Agent steps
are atomically bound to durable Tasks, completed Task Runs advance dependent
steps, and retry ownership stays at one layer: Workflow Step policy for bound
tasks and daemon retry policy for ordinary tasks. Local Condition, Checkpoint,
Parallel, Approval, and Wait steps execute without creating ACP sessions.
Long-lived Tasks restore their previous ACP session when supported, permission
requests remain in a durable wait state until answered, and completed runs
capture bounded agent-summary and Git status/diff artifacts. Invalid structured
results are automatically re-prompted in the same Task/session up to the Core
correction limit before human review.

Remote ACP transports and unstable MCP-over-ACP are explicitly unavailable
until their Rust transports are implemented; the production app never opens a
parallel compatibility connection. The legacy TaskInbox database is read only
as a migration source before Rust activation. The ownership contract,
implemented scope, and remaining transport and runtime work are tracked in
[Runtime architecture](docs/runtime_architecture.md).
