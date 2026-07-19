# Runtime architecture

Updated: 2026-07-19

This document is the authoritative ownership contract for the production
runtime. ACP protocol handling, agent processes, session authority, workflow
state, scheduling, persistence, filesystem operations, and terminal operations
belong to Rust. Flutter owns product projections and interaction UI only.

## Target boundary

```text
ACP agent process
      │ typed ACP v1 JSON-RPC over stdio
      ▼
ianvs-acp-core (pure Rust)
  protocol + process supervision + Session/Task/Run state
  scheduling + retry + workspace/egress enforcement
  terminal provider + PTY + SQLite recovery
      │ stable product commands and versioned projections
      ▼
ianvs-acp-ffi                    optional ianvs-acpd (later)
      │
      ▼
Flutter/Dart
  Timeline / Plan / Tool Call / Workspace / Pane UI
  permission dialogs and human choices
  Terminal viewport
```

The core crate has no Flutter, Dart, C ABI, or widget-lifecycle dependency. The
FFI crate is a replaceable host adapter. A future daemon must consume the same
Rust command/event model instead of creating a second runtime implementation.

## Ownership rules

| Rust owns | Flutter/Dart owns |
| --- | --- |
| ACP frames, version negotiation, and the capability intersection exposed by ianvs | Rendering negotiated capabilities and hiding unavailable actions |
| Agent process lifetime, stderr capture, failure detection, and recovery policy | Agent configuration forms and user-facing failure presentation |
| Session, Task, and Run transitions | Timeline, plan, tool-call, workspace, session, and pane projections |
| Command admission, concurrency, cancellation, timeouts, and bounded queues | Asking the user for a permission choice |
| Workspace canonicalization, mutation leases, and hard egress decisions | Returning the selected permission option to Rust |
| `terminal/*`, PTY/VT state, SQLite persistence, restart recovery, and retries | Terminal viewport and recovered-state presentation |

Flutter must never keep a second authoritative ACP connection for a
Rust-owned session. Unsupported operations remain unavailable until they are
implemented in Rust; they do not silently fall back to Dart.

## Stable host contract

The C ABI exposes product operations, not a generic `sendJsonRpc` escape hatch:

```text
Dart -> Rust
startAgent / createSession / prompt(product attachment metadata) / cancel
listSessions / restoreSession / closeSession / deleteSession
authenticate / logout / respondPermission / setMode / setConfigOption / dispose
workflowOpen / workflowApply(typed product command) / workflowSnapshot
workflowStageTaskInbox / workflowMaterializeTaskInbox / workflowActivateTaskInbox
workflowApplyTaskInbox(typed product command) / workflowTaskInboxSource
workflowSchedulerConfigure / workflowSchedulerSetRuntimeStatus
workflowSchedulerClaimNext

Rust -> Dart
sessionUpdate / sessionCatalog / authenticationChanged
permissionRequest / statusChanged
stderrLog / terminalAttached / terminalOutput / terminalExited / terminalReleased
runtimeError
```

Events use `RuntimeEventEnvelope` with `schemaVersion == 3` and a strictly
increasing sequence. `sessionUpdate` payloads are normalized ianvs projections;
top-level event fields are consistently camel-cased, and raw JSON-RPC envelopes
and ACP method names do not cross the ABI. FFI functions are individual typed
operations, and native strings have explicit ownership.

Session catalog pagination, duplicate/cursor-cycle limits, workspace identity
normalization, and load-versus-resume selection are Rust decisions. Flutter
receives a bounded normalized catalog and replayed Timeline events. Close and
delete settle through request-correlated Rust lifecycle events; close also
invalidates pending permissions and releases Rust PTY scopes and handles.
Authentication methods and logout support are projected from initialize, and
Rust rejects unadvertised methods. Session configuration is a bounded,
normalized complete-state projection: Rust validates ids, types, select values,
duplicate choices, and concurrent mutation, and safely orders config
notifications that arrive before session creation or restoration completes.
Prompt attachments cross the ABI only as ianvs path/name/MIME/size product
metadata. Core resolves every file inside the session `WorkspaceScope`, checks
selected size plus file device/inode before reading, applies count/source/wire
budgets, and chooses typed image/audio/embedded-resource/resource-link blocks
from the negotiated capability intersection.

Workflow commands are a separate, versioned ianvs product contract
(`create_task`, `dispatch_task`, `start_run`, permission/user waits, artifact
collection, review, completion, failure, cancellation). Each successful command
returns a strict Task/Run projection with a monotonic SQLite revision. The
command is applied to a candidate state machine and that candidate replaces the
in-memory authority only after the revision compare-and-swap commits.

The complete Dart `ianvs-acp.task-inbox.v1` shape now has a strict Rust model
covering tasks, runs, timeline events, artifacts, approvals, and workspace
resources. Migration first enters `staged`: Rust validates global ids and every
cross-record reference, retains the source JSON and checksum losslessly, and
projects Task/Run state, but rejects workflow mutation. This deliberately keeps
an unreviewed import from becoming a second dispatcher. `materialize` creates a
normalized, still non-dispatchable `ready` projection. Explicit activation then
moves it to `active`; from that point Rust accepts only typed TaskInbox product
operations and atomically commits the authoritative Task/Run rows, complete
current TaskInbox document, migration state, and revision in one SQLite
transaction. Historical export states are disclosed and normalized to human
review in the current projection while remaining unchanged in the immutable
source archive.

The active command surface covers task creation/queue/cancel/delete,
pre-dispatch task-definition edits, run dispatch and legal state transitions,
guarded task/run UI-projection updates, timeline event append, per-run artifact
replacement, and approval/resource upsert. Workflow fields owned by Rust
(`status`, `currentRun`, `attempt`, workspace, and agent) cannot be overwritten
through a projection update. Failed validation leaves both memory and SQLite
unchanged. Crash recovery rewrites normalized state and the complete current
TaskInbox projection in the same transaction.

The Core scheduler registry records per-agent availability, capability, and
concurrency observations. Its typed `claim_next` operation atomically chooses a
queued task by priority and creation order, enforces retry readiness, global and
per-agent quotas, runtime availability, exclusions, and canonical workspace
leases, then commits the dispatched Run, dispatch event, complete TaskInbox
projection, and SQLite revision together. A no-op poll does not advance the
revision and returns the earliest eligible Core-selected `nextWakeAt` retry
deadline. The host may implement the timer, but does not recompute retry policy.
On the default Workflow path, the production Flutter scheduler publishes runtime
observations, consumes this atomic claim and wake deadline, and starts only the
worker selected by Core. It does not retain a Dart workspace lease or a second
Task/Run authority.

Persisted absolute workspace identities may outlive a deleted checkout, so
startup and legacy migration retain them after canonicalizing the nearest
existing ancestor. Dispatch remains fail-closed: Core must resolve the final
directory and prove that its canonical identity still matches before granting a
workspace lease.

Permission requests remain pending in Rust. Timeout, prompt completion,
explicit cancel, connection loss, and disposal use a first-wins settlement and
emit `permission_invalidated` with a stable reason. Flutter clears a permission
card only when request id, lifecycle id, and session id still match.

Configured filesystem reverse requests use the same rule. Both reads (local
content leaving the workspace for the agent) and writes become Rust-owned
pending operations and require a fixed allow-once choice. Core bounds pending
content, validates the session `WorkspaceScope`, verifies read file identity,
and performs approved writes through a same-directory create-new temporary file
plus atomic rename. Flutter never receives file contents or an executable write
command. These Core-originated filesystem and terminal requests carry
`requiresExplicitHuman`; Flutter's trust rules, auto-review, and full-access
policy must leave them pending for a manual choice.

## Repository status

| Area | Status | Evidence / remaining work |
| --- | --- | --- |
| Crate separation | Implemented | `rust/crates/ianvs-acp-core` and `rust/crates/ianvs-acp-ffi`; daemon intentionally absent |
| Typed ACP v1 stdio path | Implemented for the stable session slice | Initialize, capability projection, authentication/logout, new/list/load-or-resume/close/delete session, typed MCP configuration, text/media prompt, cancel, permission response, mode/config change, notifications, stderr, and process recovery use the official Rust SDK |
| Stable FFI + Dart projection | Implemented for ACP, terminal, and Workflow slices | ABI v5 exposes individual ACP functions/events plus typed Workflow, complete TaskInbox, scheduler-registry, and atomic scheduler-claim commands/projections; schema v3 has strict sequence and camelCase field validation plus real Dart -> dylib -> Rust integration tests |
| Session state | Implemented for the slice | Rust rejects illegal parallel prompts and owns permission/cancel transitions |
| Permission lifetime / timeout | Implemented | Configurable human timeout, bounded pending map, first-wins invalidation, and late-choice rejection |
| Backpressure | Implemented at host queues | Bounded command and event queues; event production blocks instead of growing memory without limit |
| Workspace path boundary | Implemented as Core primitives | Canonical roots, lexical and symlink escape rejection; creation still requires an atomic/open-at write path to close TOCTOU |
| Task/Run state + mutation gate | Durable active Core authority path implemented | `staged -> ready -> active` is explicit. Legal typed FFI commands retain a Rust RAII workspace lease; Rust rejects projection attempts to rewrite authority fields and commits complete TaskInbox state before returning |
| Retry policy | Core admission and wake decision implemented | Failure categories, retry limits, exponential delay, retry-readiness admission, and the earliest eligible `nextWakeAt` decision are in Rust; the opt-in production host consumes that deadline, and idle agent startup uses bounded exponential restart |
| Agent subprocess shutdown | Implemented | Child is killed on transport drop, including protocol termination and host disposal |
| Capability surface | Conservative partial | Flutter sees the peer/core intersection. Stable session list/load/resume/close/delete, authentication/logout, session configuration, and prompt image/audio/embedded-context support are projected; unstable fork and other unmigrated features stay hidden |
| Production activation | Rust-only production authority | Local stdio ACP and Workflow use Rust unconditionally. Remote ACP transports and unstable MCP-over-ACP remain unavailable rather than opening a parallel compatibility connection |
| Session list/load/resume/close/delete | Implemented | Core bounds pagination/cursors/entries, selects load before resume when both are available, validates workspace scopes, registers recovered session/terminal state, and owns close/delete cleanup |
| Authentication/logout | Implemented | Core projects advertised auth methods/logout capability, validates method ids, sends typed SDK requests, and completes request-correlated stable events |
| Session configuration | Implemented | Initial and updated select/boolean options are bounded and normalized; invalid values and concurrent mutations fail closed, and immediate complete-state notifications are retained without exposing SDK payloads |
| Prompt attachments | Implemented | FFI accepts no ACP content JSON; Core validates bounded product metadata and workspace identity, verifies stable file metadata during reads, and constructs typed SDK content with resource-link fallback for unsupported or oversized media |
| ACP filesystem provider | Implemented on the Rust default path | Configured typed `fs/read_text_file` and `fs/write_text_file` reverse requests are session-scoped, bounded, and hard-gated by one-shot human approval. Reads verify device/inode/size; writes use create-new temporary files and atomic replacement inside canonical roots |
| MCP session setup | Implemented for stable transports | Product DTOs for stdio, HTTP, and SSE are bounded and converted to typed SDK values for session new/load/resume; peer HTTP/SSE support is validated. Unstable MCP-over-ACP remains unavailable |
| Session fork | Pending in Rust | Fork remains feature-gated unstable in the official Rust schema and is not exposed by the production client |
| Scheduler / worker / runtime registry | Default production cutover implemented | The Rust repository adapter supplies the authoritative projection; Flutter publishes runtime observations and delegates priority/retry/runtime-quota/workspace admission plus dispatch to the ABI v5 atomic claim, then runs the selected worker |
| SQLite persistence and crash recovery | Durable Workflow and ACP session recovery | Workflow uses WAL/FULL, strict v1→v5 migration, revision CAS and complete projection commits. A separate `NOFOLLOW` session registry persists canonical scopes; bounded process restart reinitializes ACP and load/resumes every registered session before returning Ready |
| ACP terminal provider + real PTY | Implemented on the Rust default path | All five typed ACP `terminal/*` reverse requests use bounded, session-owned `portable-pty` handles. Create validates the workspace/cwd, counts live plus approval-pending quotas, and projects attach/output/exit/release events without exposing ACP envelopes |
| Hard human-controlled egress | Implemented for terminal and filesystem operations | `terminal/create`, filesystem reads, and filesystem writes cannot execute until Flutter returns the fixed allow-once choice and Rust consumes its opaque one-shot `EgressPermit`; denial, timeout, cancellation, connection loss, and workspace escape fail closed. Git push/PR/upload executors remain to be wired |
| Automatic agent restart/session recovery | Implemented for recoverable sessions | Rust retries bounded failures with exponential delay, invalidates in-flight work/permissions, reinitializes the process, and load/resumes SQLite-registered sessions before Ready. Recovery fails closed when the peer cannot restore sessions |

## Activation and verification

Run a macOS development build against the default Rust stdio client:

```sh
flutter run -d macos
```

Xcode builds `ianvs-acp-ffi` and embeds
`libianvs_acp_ffi.dylib` in the app Frameworks directory. For the Rust tests,
native ABI tests, and real FFI fixture chain:

```sh
./tool/verify_rust_runtime.sh
```

The environment variable `IANVS_ACP_RUST_LIBRARY` may point tests or local
development at an explicit dylib. It is not a protocol escape hatch.

## Planned evolution

1. Connect remaining git push/PR/upload executors to Rust workspace and egress
   admission.
2. Implement Rust remote ACP transports while keeping unsupported configurations
   fail-closed.
3. Evaluate unstable fork and MCP-over-ACP separately without exposing raw ACP
   payloads through FFI.
4. Add `ianvs-acpd` only when headless/background continuity is required.

## Flutter boundary modules

Flutter-facing ACP code is deliberately limited to product projections and host
adapters:

- `lib/acp/rust_acp_agent_client.dart` maps typed FFI commands and events to the
  UI-facing `AcpAgentClient` interface.
- `lib/acp/acp_input_budget.dart` bounds retained text, metadata, collections,
  and media projections before they reach widgets.
- `lib/acp/transport_byte_budget.dart` bounds the independent MCP sidecar HTTP
  transport. It is not an ACP agent transport.
- `lib/acp/fake_agent_client.dart` is the widget/state-test seam and never owns
  a production agent process.

No generic JSON-RPC client, ACP transport, provider implementation, or vendored
ACP package exists in the Flutter layer.
