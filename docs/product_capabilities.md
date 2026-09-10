# Product capabilities

Updated: 2026-09-10. Source baseline: `b9297f5`.

ianvs is a workspace and local ACP session client. This document is the
canonical list of capabilities exposed by the main application. Protocol and
process ownership are described in [Runtime architecture](runtime_architecture.md),
and the reusable chat package has its own
[package README](../packages/ianvs_agent_chat/README.md).

## Workspaces and sessions

- Add workspaces explicitly and retain their sidebar state without scanning all
  sessions to discover workspace roots.
- Create new sessions; manually list and restore existing sessions; and close or
  delete sessions when the negotiated local Agent supports those operations.
- Show connection, creation, configuration, and applicable template progress
  while creating a session. New empty sessions stay out of sidebar history
  until their first prompt.
- Rename, pin, archive, mark unread, copy, and open locally indexed sessions in
  another window. These are application projections and do not imply matching
  ACP protocol methods.
- Create a Git worktree from a workspace and start a new, empty ACP session in
  it. This is available independently of ACP session fork.
- Keep multiple conversations active in one app window, with independent
  timelines, permission handling, and session-targeted cancellation. Exact
  runtime recipes share one authoritative ACP runtime; recipes with different
  MCP or provider boundaries use isolated runtimes.
- Recover registered sessions after a recoverable local agent-process restart.

The production Rust client does not implement `session/fork`. The application
therefore does not present conversation fork as an available local ACP
operation, even if an Agent advertises it.

## Conversation and negotiated state

- Stream bounded user, assistant, thought, plan, tool-call, turn-completion,
  status, permission, error, and ACP-terminal projections.
- Send text and workspace-scoped file, image, and audio attachments according
  to the negotiated prompt capabilities, with resource-link fallback where
  required.
- Project available-command notifications into session state and use them for
  slash-command suggestions in the composer.
- Read bounded `SessionInfo` directory entries returned by `session/list`,
  including the session ID, working directory, additional directories, title,
  update time, and bounded metadata.
- Apply the modes and bounded select/boolean configuration options returned for
  a session.
- Load an exact-revision cached transcript atomically when its session identity
  and catalog `updatedAt` still match. See
  [Conversation loading architecture](conversation_loading_architecture.md).

Live ACP session-info updates and usage updates are not projected by the local
Rust runtime. A missing usage value remains absent; the application does not
display zero as a substitute.

## Activity and human decisions

`Activity & Diagnostics` opens from the active controller and groups three views:

- `Events` shows the chronological prompt/response, tool, status, permission,
  and error trajectory.
- `Permissions` shows and exports that controller/connection's bounded
  in-process permission history. It may include its other sessions; histories
  from other connections are not combined.
- `Runtime` shows the effective recipe, MCP and client providers, negotiated
  capabilities, compatibility degradations, and secret-safe inventory.

Permission requests remain pending in Rust until a response, timeout,
cancellation, session invalidation, connection loss, or disposal wins. The UI
offers the Agent-provided choices, allow/deny/cancel actions, trust rules, and
optional sidecar review. Filesystem access and ACP terminal creation follow the
same policy as other ACP tool calls.

## Providers, MCP, and terminals

- Filesystem read/write and ACP terminal providers are opt-in, Rust-owned, and
  scoped to the session workspace roots.
- The saved `filesystem.allow_read_outside_workspace` switch does not widen
  the Rust provider's roots; that field has no production runtime wiring. See
  [Configuration](configuration.md) for this limitation and effective controls.
- Stable stdio, HTTP, and SSE MCP server configuration can be sent through a
  local stdio ACP session when the Agent advertises the matching MCP capability.
- A configured MCP tool or isolated ACP sidecar can review a permission request.
  The sidecar HTTP client rejects redirects and bounds headers, bodies, SSE
  lines, and events.
- The bottom terminal panel is a user-opened local shell. Its tabs are created
  lazily for the active session working directory and disposed when that UI
  session changes or closes.

The user shell and Agent-requested ACP terminals have independent process
handles and lifecycles. Shell controls do not operate ACP terminals, and ACP
terminal release or exit events do not manage shell tabs.

## Reusable chat and independent LLM chat

The timeline, composer, rendering, and shared chat contracts live in the
standalone `ianvs_agent_chat` package. The main application adapts its ACP
controller through `AcpChatSession`.

The package also provides `LlmChatSession`, and the application exposes a
separate OpenAI-compatible LLM API chat page. That page owns an in-memory chat
session and is disposed when closed. It does not join the ACP workspace history,
session recovery, permission flow, runtime recipe, or Agent process lifecycle.

## Unavailable protocol paths

The production application keeps these operations unavailable and reports the
reason instead of opening a Flutter compatibility transport:

- WebSocket and HTTP/SSE ACP agent transports;
- ACP `session/fork`;
- MCP-over-ACP (`type: "acp"` MCP entries may be preserved while editing old
  configuration, but cannot start a production runtime);
- generic raw JSON-RPC, extension requests, and experimental protocol methods;
- live session-info and usage-update projection.

Stable HTTP/SSE MCP configuration is distinct from remote ACP agent transport.
It does not make any of the unavailable ACP paths available.

## Evidence

- Rust behavior: `rust/crates/ianvs-acp-core/tests` and
  `rust/crates/ianvs-acp-ffi/tests`.
- FFI and Flutter projection: `test/rust` and
  `test/acp/rust_acp_agent_client_test.dart`.
- Session/controller behavior: `test/state`.
- Navigation and UI behavior: `test/ui`.
