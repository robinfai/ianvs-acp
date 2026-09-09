# Runtime architecture

Updated: 2026-09-09

ianvs is a workspace-oriented ACP desktop client. The production ACP path has
one protocol authority: Flutter presents workspaces and sessions, while Rust
owns the local ACP process, protocol state, workspace validation, and ACP
session persistence.

```text
Flutter workspace UI
        |
        | typed session operations and bounded product events
        v
ianvs-acp-ffi
        |
        v
ianvs-acp-core
  - local stdio ACP transport
  - session lifecycle and prompt streaming
  - authentication and permissions
  - workspace-scoped attachments
  - filesystem and ACP terminal providers
  - process recovery and ACP session registry
```

## Ownership and runtime boundaries

Flutter owns navigation, workspace/session projections, configuration screens,
the local user-shell panel, and human interaction. It does not frame ACP
JSON-RPC or open a compatibility transport.

`ianvs-acp-core` owns protocol negotiation, the Agent subprocess lifetime,
session state, request correlation, prompt cancellation, permission settlement,
workspace boundaries, filesystem callbacks, ACP terminal callbacks, and
recovery. `ianvs-acp-ffi` exposes typed operations and versioned runtime events.
Raw protocol frames never cross the ABI.

The standalone `ianvs_agent_chat` package owns reusable timeline, composer, and
chat-session contracts. The main application connects the ACP controller through
`AcpChatSession`. Its separate `LlmChatSession` path is an in-memory,
OpenAI-compatible chat owned by its page; it has no ACP Agent process, workspace
recovery, permission, or session-registry ownership.

## Workspace and session model

Every ACP session has one canonical working directory and an optional bounded
list of additional directories. Core validates these roots before creating or
restoring a session and uses the same scope for attachments and reverse
filesystem/terminal requests.

The Flutter sidebar shows workspaces users add explicitly and groups locally
known sessions inside them. It does not scan Agent catalogs to derive the
workspace list. `session/list` runs only from the explicit resume flow.

The local Rust client creates, lists, loads/resumes, closes, and deletes sessions
according to its own support and the negotiated Agent capability. It does not
implement `session/fork`; Flutter must not infer support from the Agent alone.
For Git workspaces, the application can create a worktree and then create a new,
empty session in that directory. That application workflow neither copies nor
forks conversation history.

Each simultaneously active conversation has an isolated Flutter controller.
Controllers with the same exact runtime recipe hold session-scoped leases on one
shared ACP client, so timelines, permissions, and cancellation remain scoped to
their sessions while Rust stays the protocol and process authority. A recipe
includes its Agent transport, MCP set, client providers, workspace defaults,
recovery-store path and retention policy, and secret generation. Recipes that
differ at those execution boundaries intentionally use isolated Rust runtimes.
Permission-review and Assistant Agent sidecars are separate, short-lived helper
runtimes and never become the authoritative owner of a user conversation.

## ACP projection boundary

Rust projects only bounded state that has a production Flutter consumer:

| Source | Host projection |
| --- | --- |
| Session lifecycle, current mode/config, permission invalidation | typed `SessionUpdate` control events |
| `available_commands_update` | `CommandsChanged` with bounded command name, description, and unstructured input hint |
| User/assistant/thought/tool/plan/turn-complete updates | typed `RenderUpdate` timeline events |
| `session/list` `SessionInfo` entries | bounded session catalog entries with directories, title, `updatedAt`, and metadata |
| ACP terminal attach/output/exit/release | session-scoped terminal runtime events |

Available commands are retained per session by the Dart adapter and passed
through `AcpChatSession` to the shared composer. They are the source for
slash-command suggestions.

The directory `SessionInfo` returned by `session/list` is distinct from a live
session-info notification. Live session-info and usage updates have no local
Rust-to-Flutter projection. Other wire metadata, generic extension requests,
and experimental notification variants without a product consumer also stop in
Rust. Missing usage stays absent rather than being synthesized as zero.

## Transport and MCP

The Agent transport is local stdio. Saved WebSocket and HTTP/SSE Agent entries
can be parsed for configuration compatibility, but selecting one yields an
explicit unavailable client because Rust does not own those transports.

MCP is a separate boundary. Rust can project stable stdio, HTTP, and SSE MCP
server configuration into local ACP session setup when the Agent advertises the
matching capability. MCP-over-ACP remains unavailable; a preserved `type: "acp"`
entry cannot start the production runtime. Flutter never opens a fallback ACP or
MCP-over-ACP connection.

## Activity and diagnostics

The application groups runtime inspection under `Activity & Diagnostics`:

- `Events` reads the current controller's chronological activity projection.
- `Permissions` reads and exports that controller's bounded in-process audit.
- `Runtime` combines the effective recipe, runtime inventory, negotiated
  compatibility, and degradation reasons without exposing credential values.

The three views retain their existing data sources and session scope. The
container does not create another activity database or change permission
settlement and retention semantics.

## User shell and ACP terminals

The bottom panel lazily creates a local shell runtime in the selected session's
working directory. Changing or closing that UI session disposes its shell tabs.

ACP terminal requests enter through the Rust ACP connection, use the normal
permission flow, and are owned by the ACP session. The user shell and ACP
terminals have independent process handles and lifecycles. Toggling or closing
the shell cannot release or kill an ACP terminal, and an ACP terminal exit does
not close a shell tab.

## Persistence

`acp_sessions.sqlite3` stores the minimal Agent-scoped session registry needed
for process recovery. It uses the application-wide size and retention policy.
The exact-revision transcript cache stores a bounded private copy of locally
projected messages and tool metadata to avoid replaying unchanged sessions.

`workspace_ui_state.json` separately stores explicitly added Workspace/sidebar
preferences and the local index of sessions the app has created or resumed.
Concurrent app windows merge independent record-field updates and expanded
Workspace set changes. This state file is outside the payload-store size and
retention policy. The ACP Agent remains the canonical owner of conversation
events.

## Packaging and verification

The macOS build compiles `ianvs-acp-core` into
`libianvs_acp_ffi.dylib` and embeds that library in the app bundle. There is no
separate background ACP execution host.

Run `./tool/verify_rust_runtime.sh` to test the Rust workspace, ABI, and Dart
integration boundary. Desktop release checks remain in
[Manual follow-ups](manual_followups.md).
