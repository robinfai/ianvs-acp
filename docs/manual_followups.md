# Manual follow-ups

Updated: 2026-08-11

This list contains only work that still requires a product decision, a real
external service, or desktop interaction. Implemented runtime work belongs in
the architecture and coverage documents, not here.

## Remote ACP agent transports

Status: unavailable by design.

Local stdio is the only production ACP agent transport. Decide whether remote
agents justify Rust WebSocket and/or HTTP/SSE transports, then implement and
validate them in Core before enabling their configuration. Do not add a Flutter
transport or compatibility fallback.

Acceptance when implemented:

- typed Core transport and process/session ownership;
- redirect, origin, TLS, authentication, byte, timeout, and reconnect policy;
- real-agent interoperability tests in addition to local fixtures;
- no raw ACP envelopes crossing FFI.

## Unstable protocol features

Status: hidden.

Evaluate session fork and MCP-over-ACP independently after their upstream
contracts stabilize. Each feature needs a typed product command/event shape and
must preserve one Rust authority for session state.

## Permission audit retention

Status: bounded in-process history only.

Decide whether resolved permission decisions need durable encrypted retention,
export retention limits, or organization policy. Core request settlement already
fails closed; this item concerns product audit history, not authorization.

## Terminal experience

Status: runtime complete, viewport intentionally limited.

Decide whether timeline snapshots are sufficient or whether the product needs a
persistent live terminal panel with explicit kill/release controls, resize,
scrollback, cwd/environment disclosure, and recovered-handle presentation.

## ACP Registry

Status: not integrated.

Decide whether Registry entries should be imported into explicit user config,
cached separately, or launched from discovered metadata. Installation and trust
UX must be designed before adding network-backed discovery.

## Desktop and real-agent validation

Run before a release candidate:

- connect to each supported local agent adapter and complete create, prompt,
  permission, cancel, restore, close, and recovery flows;
- validate file/image/audio attachment behavior for each advertised model;
- verify macOS keychain entitlements in the signed application;
- exercise session recovery after an agent-process restart;
- verify compact-window keyboard focus, screen-reader labels, drag/drop, file
  pickers, and terminal presentation.

Automated baseline:

```sh
./tool/verify_rust_runtime.sh
flutter analyze --no-pub
flutter test --no-pub
flutter build macos --release
```
