# Runtime architecture

Updated: 2026-08-09

ianvs is a workspace-oriented ACP desktop client. The production runtime has
one path: Flutter presents workspaces and sessions, while Rust owns the local
ACP process, protocol state, workspace validation, and session persistence.

```text
Flutter workspace UI
        |
        | typed session operations and normalized events
        v
ianvs-acp-ffi
        |
        v
ianvs-acp-core
  - local stdio ACP transport
  - session lifecycle and prompt streaming
  - authentication and permissions
  - workspace-scoped attachments
  - filesystem and terminal providers
  - process recovery
  - ACP session registry
```

## Ownership

Flutter owns navigation, workspace/session projections, configuration screens,
and human interaction. It does not frame ACP JSON-RPC or open a compatibility
transport.

`ianvs-acp-core` owns protocol negotiation, agent subprocess lifetime,
session state, request correlation, prompt cancellation, permission settlement,
workspace boundaries, filesystem callbacks, terminal callbacks, and recovery.

`ianvs-acp-ffi` exposes typed product operations and versioned runtime events.
Raw protocol frames never cross the ABI.

## Workspace and session model

Every session has one canonical working directory and an optional bounded list
of additional directories. Core validates these roots before creating or
restoring a session and uses the same scope for attachments and reverse
filesystem/terminal requests.

The Flutter sidebar groups sessions by workspace. Users can create, restore,
fork, rename, pin, archive, copy, and open sessions without introducing a
second execution model.

## Persistence

`acp_sessions.sqlite3` stores the minimal agent-scoped session registry needed
for process recovery. It uses the application-wide size and retention policy.
Conversation events remain owned by the ACP agent/session projection.

## Packaging

The macOS build compiles `ianvs-acp-core` into
`libianvs_acp_ffi.dylib` and embeds that library in the app bundle. There is
no separate background execution host.

Run `./tool/verify_rust_runtime.sh` to test the Rust workspace, ABI, and Dart
integration boundary.
