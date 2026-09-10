# Manual follow-ups

Updated: 2026-09-10. Source baseline: `b9297f5`.

This list contains only work that still requires a product decision, a real
external service, or desktop interaction. Implemented runtime work belongs in
[Product capabilities](product_capabilities.md) and
[Runtime architecture](runtime_architecture.md).

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

Evaluate session fork, MCP-over-ACP, generic extension requests, and other
experimental methods independently after their upstream contracts stabilize.
Each feature needs a bounded typed Core command/event shape and must preserve
one Rust authority for session state. The existing Git worktree plus new empty
session workflow does not depend on this decision and must not be relabeled as
conversation fork.

## Live session metadata and usage

Status: not projected by the local Rust runtime.

Decide which live session-info and usage fields have a product consumer and
define bounded typed projections before sending either notification across the
ABI. Keep `session/list` directory `SessionInfo` entries and available commands:
both already have production projections. Missing usage must remain absent
until the Agent and runtime provide it.

## Out-of-workspace read setting

Status: saved and editable, but not connected to the production Rust provider.

`client_providers.filesystem.allow_read_outside_workspace` is retained by the
config model and Settings, but the [runtime factory](../lib/app.dart) passes
only read/write enablement. Rust's
[FilesystemConfig and read path](../rust/crates/ianvs-acp-core/src/filesystem.rs)
keep all reads within `WorkspaceScope`.

Decide whether to retire/disable the ineffective switch while preserving saved
values, or define an explicit Rust-owned access policy before implementing it.
The current supported way to grant another root is `additional_directories`.
A future fix must verify both the UI's effective-state description and Rust
outside-root rejection/authorization; documentation correction alone does not
resolve the UI mismatch.

## Permission audit retention

Status: bounded in-process history per controller/connection; it may retain
multiple sessions from that connection and does not aggregate other connections.

Decide whether resolved permission decisions need durable encrypted retention,
export retention limits, or organization policy. Core request settlement already
fails closed; this item concerns product audit history, not authorization.

## Terminal experience

Status: two independent terminal lifecycles are implemented.

The bottom panel is a user-opened local shell whose tabs are disposed when the
selected UI session changes or closes. Agent-requested ACP terminals are
Rust-owned, permission-gated, and tied to the ACP session. Decide whether ACP
terminal output should gain a dedicated live viewport and recovered-handle
controls. Any shared presentation must keep shell and ACP process handles,
kill/release actions, and lifecycle disclosure separate.

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
- verify `Activity & Diagnostics` Events, Permissions, and Runtime pages keep
  the Events session scope, retained connection-level permission export,
  compatibility reasons, Escape, and focus return behavior;
- create a Git worktree with a new empty session and verify that no source
  conversation history is copied;
- open the user shell and an Agent-requested ACP terminal, then verify that
  closing either one does not terminate the other;
- verify compact-window keyboard focus, screen-reader labels, drag/drop, file
  pickers, and terminal presentation.

Automated baseline (app, chat package, and example):

```sh
make bootstrap
make verify
make build
make verify-macos
```

`make verify` includes the Rust/FFI checks and runs all three Flutter projects
with isolated test homes. Compatibility cleanup and its retirement criteria are
tracked in [Compatibility maintenance](compatibility-maintenance.md).
