# Runtime architecture

Updated: 2026-08-11

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

Each simultaneously active conversation has an isolated Flutter controller.
Controllers for the same configured agent hold session-scoped leases on one
shared ACP client, so timelines, permissions, and cancellation remain scoped to
their sessions while Rust stays the single protocol and process authority.

## Persistence

`acp_sessions.sqlite3` stores the minimal agent-scoped session registry needed
for process recovery. It uses the application-wide size and retention policy.
The exact-revision transcript cache stores a bounded private copy of locally
projected messages and tool metadata to avoid replaying unchanged sessions.
`workspace_ui_state.json` separately stores Workspace/sidebar preferences and
the local session index. Concurrent app windows merge independent record-field
updates and expanded-Workspace set changes across processes. This state file is
not covered by the payload-store size and retention policy. The ACP agent
remains the canonical owner of conversation events.

## Packaging

The macOS build compiles `ianvs-acp-core` into
`libianvs_acp_ffi.dylib` and embeds that library in the app bundle. There is
no separate background execution host.

Run `./tool/verify_rust_runtime.sh` to test the Rust workspace, ABI, and Dart
integration boundary.
