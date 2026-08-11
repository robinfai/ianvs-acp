# ACP runtime coverage

Updated: 2026-08-11

This document records the ACP surface implemented by the production Rust
runtime. The official ACP schema consumed by `ianvs-acp-core` remains the
wire-level source of truth.

## Ownership and transport

- `ianvs-acp-core` owns the ACP client, subprocess lifecycle, stdio transport,
  protocol negotiation, sessions, providers, workspace validation, and
  recovery.
- `ianvs-acp-ffi` exposes typed operations and normalized events. Raw JSON-RPC
  envelopes do not cross the ABI.
- `lib/acp/rust_acp_agent_client.dart` projects the native runtime into
  Flutter. Session-scoped Flutter leases share that client and do not open a
  second connection.
- Local stdio agents are supported. Remote agent transports are intentionally
  unavailable.
- Stable stdio, HTTP, and SSE MCP configuration is converted to typed SDK values
  by Core.

## Stable session surface

| Capability | Runtime behavior |
| --- | --- |
| Initialize | Negotiates protocol capabilities, agent info, authentication methods, and client-provider support |
| Authentication | Validates advertised method identifiers and supports authenticate/logout |
| Session lifecycle | Creates, lists, restores, closes, and deletes workspace sessions |
| Prompt | Streams normalized events for concurrent sessions, enforces one active prompt per session, and cancels by session ID |
| Attachments | Validates workspace identity and constructs supported prompt content |
| Configuration | Projects and validates modes and bounded select/boolean options |
| Permissions | Settles allow, deny, cancel, timeout, session close, connection loss, and disposal with first-wins semantics |
| Session catalog | Bounds pagination, entries, cursors, metadata, and workspace scopes |

## Reverse requests

Filesystem and terminal requests are Rust-owned and disabled unless their
providers are enabled. Filesystem paths are restricted to canonical workspace
roots. Terminal handles are bounded and session-owned. Both use the ordinary
permission flow.

## Verification

Run:

```sh
./tool/verify_rust_runtime.sh
flutter analyze --no-pub
flutter test --no-pub
```

The native suite covers Core, the ABI, and Dart-to-dylib integration. Widget and
state tests use `FakeAgentClient`.
