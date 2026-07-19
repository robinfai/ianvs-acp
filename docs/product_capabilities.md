# Product capabilities

Updated: 2026-07-19

This is the user-facing capability map. The product has one production authority
for ACP and Workflow state. Runtime ownership and protocol details live in
[Runtime architecture](runtime_architecture.md) and
[ACP runtime coverage](acp_runtime_coverage.md).

## Sessions and prompts

- Create, list, restore, close, and delete local stdio ACP sessions.
- Stream text, plan, tool-call, status, usage, and terminal events into the
  timeline.
- Send text and workspace-scoped file attachments. Images, audio, embedded
  resources, and resource links are selected from the negotiated capability
  intersection.
- Change advertised session modes and select/boolean configuration options.
- Authenticate with advertised methods and log out when supported.
- Recover registered sessions after a recoverable agent-process restart.

## Human decisions and automation

- Permission requests pause in Rust until a matching human response, timeout,
  cancellation, or lifecycle invalidation wins.
- The UI offers the agent-provided choices, explicit allow/deny/cancel actions,
  trust rules, automatic sidecar review, and an in-process bounded audit view.
- Filesystem access and terminal creation marked `requiresExplicitHuman` always
  wait for manual allow-once. Automatic policy cannot approve them.
- Task Inbox scheduling, priority, retries, runtime quota, and workspace leases
  are decided atomically by Rust. Flutter starts only the claimed worker and
  uses the Core-provided next wake time.
- Task approval/user-input waits remain visible in Inbox with their background
  context and resume only after a decision is submitted.

## Providers and MCP

- Filesystem read/write and terminal providers are opt-in and workspace scoped.
- Stable stdio, HTTP, and SSE MCP server configuration is supported for ACP
  session setup.
- A configured MCP tool can act as a sidecar permission reviewer.
- The sidecar HTTP client rejects redirects and bounds headers, bodies, SSE
  lines, and events.

## Intentionally unavailable

- Remote WebSocket or HTTP/SSE ACP agent connections.
- Unstable session fork and MCP-over-ACP.
- Generic raw JSON-RPC or vendor-extension requests from Flutter.
- A second ACP runtime or fallback connection in the Flutter process.

Configuration entries for unsupported agent transports are rejected at runtime
with a user-visible unavailable reason. They are not silently downgraded.

## Configuration

Use `Agents` → `Agent Configuration`. The default file is:

```text
~/.config/ianvs-acp/settings.json
```

The UI manages agent commands, arguments, environment variables, the default
agent, additional workspace directories, MCP servers, provider switches,
permission trust rules, and review-agent settings. Secrets use the configured
secret store instead of being included in exported task or permission context.

## Evidence

- Rust behavior: `rust/crates/ianvs-acp-core/tests` and
  `rust/crates/ianvs-acp-ffi/tests`.
- FFI contract and runtime projection: `test/rust` and
  `test/acp/rust_acp_agent_client_test.dart`.
- UI/state behavior: `test/state`, `test/tasks`, and `test/ui`.
- Remaining decisions and environment-dependent checks:
  [Manual follow-ups](manual_followups.md).
