# ACP runtime coverage

Updated: 2026-07-21

This document records the ACP surface implemented by the production Rust
runtime. It is a coverage map, not a second protocol specification. The official
ACP schema consumed by `ianvs-acp-core` is the source of wire-level truth.

## Ownership and transport

- `rust/crates/ianvs-acp-core` owns the ACP client, process lifecycle, stdio
  transport, protocol negotiation, sessions, providers, and recovery.
- `rust/crates/ianvs-acp-ffi` exposes typed product commands and normalized
  events. Raw JSON-RPC envelopes do not cross the ABI.
- `lib/acp/rust_acp_agent_client.dart` is a Flutter projection adapter. It does
  not implement ACP framing or open a second connection.
- Local stdio agents are supported. Remote WebSocket and HTTP/SSE agent
  transports are intentionally unavailable until implemented in Rust.
- MCP sidecars are independent of the ACP agent transport. Stable stdio, HTTP,
  and SSE MCP configuration is converted to typed SDK values by Core.

## Stable session surface

| Capability | Runtime behavior |
| --- | --- |
| Initialize | Negotiates the protocol and projects bounded capabilities, agent info, authentication methods, and client provider support |
| Authentication | Validates advertised method ids; supports authenticate and advertised logout |
| Session lifecycle | Creates, lists, loads or resumes, closes, and deletes sessions with request-correlated completion |
| Prompt | Streams normalized timeline events, enforces one active prompt per session, supports cancel, and preserves stop/error state |
| Attachments | Accepts product metadata only; Core validates workspace identity and constructs image, audio, embedded-resource, or resource-link content according to capabilities and limits |
| Configuration | Projects modes and bounded select/boolean config options; validates ids, values, and concurrent mutations |
| Permissions | Keeps requests pending in Rust and settles allow/deny/cancel, timeout, prompt completion, session close, connection loss, and disposal with first-wins semantics |
| Session catalog | Bounds pagination, entries, cursors, metadata, and replay; rejects cursor cycles and invalid workspace scopes |

Fork and unstable MCP-over-ACP are not exposed. Unsupported operations fail
closed instead of switching runtimes.

## Reverse requests

Filesystem and terminal reverse requests are Rust-owned and disabled unless the
corresponding client provider is enabled.

- `fs/read_text_file` and `fs/write_text_file` are scoped to canonical workspace
  roots. Reads verify file identity; writes use a same-directory create-new
  temporary file and atomic rename.
- `terminal/create`, `terminal/output`, `terminal/wait_for_exit`,
  `terminal/kill`, and `terminal/release` use bounded session-owned PTY handles.
- Filesystem access and terminal creation use the ordinary permission path.
  Default permissions, trust rules, review agents, and full-access policy apply
  consistently; the ACP client does not classify outbound effects or provide a
  network-isolation boundary.

## Product projections

Core emits versioned `RuntimeEventEnvelope` values. Flutter receives normalized
session, timeline, plan, tool-call, permission, usage, configuration, stderr,
and terminal projections. The application-owned
`lib/acp/acp_input_budget.dart` applies retention and rendering bounds to these
projections; it is not a protocol client.

## Verification

Run the complete native/runtime verification chain:

```sh
./tool/verify_rust_runtime.sh
```

Run the Flutter projection and UI suite:

```sh
flutter analyze --no-pub
flutter test --no-pub
```

The native suite includes Core unit/integration tests, ABI tests, and a real
Dart → dylib → Rust fixture-agent path. Widget and state tests use
`FakeAgentClient`; they do not launch a compatibility ACP runtime.
