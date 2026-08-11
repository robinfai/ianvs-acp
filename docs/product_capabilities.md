# Product capabilities

Updated: 2026-08-11

ianvs is a workspace and ACP session client. Runtime ownership and protocol
details live in [Runtime architecture](runtime_architecture.md) and
[ACP runtime coverage](acp_runtime_coverage.md).

## Workspaces and sessions

- Group local ACP sessions by canonical workspace.
- Create, list, restore, close, delete, fork, pin, rename, archive, and open
  sessions in another window.
- Stream text, plan, tool-call, status, usage, and terminal events into the
  conversation timeline.
- Keep multiple conversations active in one app window, with independent
  timelines, permission handling, and session-targeted cancellation while each
  configured agent retains one authoritative ACP runtime.
- Send text and workspace-scoped attachments using the negotiated prompt
  capabilities.
- Change advertised modes and select/boolean configuration options.
- Recover registered sessions after a recoverable agent-process restart.

## Human decisions

- Permission requests remain pending in Rust until a response, timeout,
  cancellation, or lifecycle invalidation wins.
- The UI offers agent-provided choices, allow/deny/cancel actions, trust rules,
  sidecar review, and a bounded audit view.
- Filesystem access and terminal creation follow the same permission policy as
  other ACP tool calls.

## Providers and MCP

- Filesystem read/write and terminal providers are opt-in and workspace scoped.
- Stable stdio, HTTP, and SSE MCP server configuration is supported for ACP
  session setup.
- A configured MCP tool can act as a sidecar permission reviewer.
- The sidecar HTTP client rejects redirects and bounds headers, bodies, SSE
  lines, and events.

## Intentionally unavailable

- Remote WebSocket or HTTP/SSE ACP agent connections.
- Unstable MCP-over-ACP.
- Generic raw JSON-RPC or vendor-extension requests from Flutter.
- A second ACP runtime or fallback connection in the Flutter process.

## Evidence

- Rust behavior: `rust/crates/ianvs-acp-core/tests` and
  `rust/crates/ianvs-acp-ffi/tests`.
- FFI and Flutter projection: `test/rust` and
  `test/acp/rust_acp_agent_client_test.dart`.
- UI/state behavior: `test/state` and `test/ui`.
