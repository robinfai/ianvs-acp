# ACP Client

A Flutter macOS desktop client for local Agent Client Protocol agents.

The app launches local stdio ACP agents through its Rust runtime, creates and
restores sessions, streams prompt turns, renders plans and tool calls, switches
advertised model/session options, and handles authentication, permissions,
filesystem callbacks, and terminal callbacks. Prompt attachments can be
selected or dropped onto the composer; file, image, and audio content follows
the negotiated prompt capabilities, with resource-link fallback where needed.

Start with the [documentation index](docs/README.md) for current guides and
historical records. See [Product capabilities](docs/product_capabilities.md),
[Runtime architecture](docs/runtime_architecture.md), and
[Conversation loading architecture](docs/conversation_loading_architecture.md).
Open decisions and manual release checks are tracked in
[Manual follow-ups](docs/manual_followups.md).
Cleanup decisions and retained compatibility are tracked in
[Compatibility maintenance](docs/compatibility-maintenance.md).

## Reusable Agent Chat UI

The timeline and composer live in
[`ianvs_agent_chat`](packages/ianvs_agent_chat/README.md), a standalone Flutter
package. The app connects its ACP controller through `AcpChatSession`; hosts can
also use the included OpenAI-compatible `LlmChatSession`. Open
**Agents → 高级 → 独立 LLM 对话** to try an API connection without replacing the
current ACP session.
The package includes a runnable macOS example and documents native integration
requirements, theming, tools, approvals and lifecycle ownership.

## Workspaces and sessions

Starting a new session shows connection, creation, settings, and applicable
template progress. A newly created empty session appears in sidebar history
after its first prompt. Creating a session prompts for its working directory,
offers local directory path completions while typing, and can apply a versioned session
template that selects the agent runtime, MCP set, workspace roots, permission
policy, assistant enhancer, mode, model, and reasoning effort.

Multiple conversations can remain active in the same window. Switching or
starting another session does not interrupt an in-flight response; prompt
cancellation and permission requests remain scoped to their session. Controllers
with the same exact runtime recipe share one authoritative ACP runtime; templates
that intentionally change MCP or client-provider boundaries use isolated
runtimes so a broader recipe cannot leak capabilities into a restricted one.

Workspaces are added explicitly from the sidebar and retained in
`workspace_ui_state.json`. The app does not scan every Codex/ACP session to
discover workspaces. Existing sessions are queried only after the user opens
`Resume Session`; selecting one shows its workspace review before the app sends
`session/load` to replay history. An exact-revision transcript cache hit uses
`session/resume` when advertised; an Agent offering only resume can reconnect
without replay. The [loading guide](docs/conversation_loading_architecture.md)
describes those capability and cache decisions.
For Git repositories, the workspace menu can create a worktree and start a new,
empty ACP session there. This does not fork the source conversation: the local
Rust ACP client does not implement `session/fork`.

## Configuration

Open **设置** in the sidebar, **Agents → 管理 Agent…**, or press **⌘,**.
Settings manages a shared application draft and normally reloads connections
when saved. Active session operations block saving; a late operation can defer
application of an already committed configuration until the runtime is idle.

The default file is `~/.config/ianvs-acp/settings.json`. Agent/MCP secrets entered
in Settings are stored in macOS Keychain, with opaque references in JSON.
See [Configuration](docs/configuration.md) for path overrides, discovery,
examples, template inheritance, permission controls, and save behavior;
[Local recovery storage](docs/sqlite_storage.md) defines persistence and retention.

## Mermaid Rendering

Fenced Mermaid blocks render in assistant messages. The shared package owns
`MermaidView`, its native Merman renderer, SVG normalization, and cache. See the
[package rendering guide](packages/ianvs_agent_chat/README.md#mermaid-rendering)
for imports, integration, and macOS native requirements.

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

Rust Core owns the production local stdio ACP connection, session lifecycle,
permissions, workspace validation, reverse filesystem/terminal requests, and
process recovery. Flutter owns the UI and bounded session projections. There
is no parallel Flutter ACP transport. Stable HTTP/SSE MCP configuration is
separate from remote ACP agent transport.

The user-opened bottom shell and Agent-requested ACP terminals have independent
handles and lifecycles. Remote ACP, `session/fork`, MCP-over-ACP, generic
extensions, and live session-info/usage projection are unavailable in the local
production runtime. See [Runtime architecture](docs/runtime_architecture.md)
for ownership and [Product capabilities](docs/product_capabilities.md) for scope.
