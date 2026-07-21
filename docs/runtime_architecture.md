# Runtime architecture

Updated: 2026-07-21

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
  scheduling + fenced execution + idempotency + classified recovery
  append-only events + typed Workflow IR + structured results + coordinator
  terminal provider + PTY + SQLite recovery/checkpoints
      │ stable product commands and versioned projections
      ▼
ianvs-acpd (single Task/Workflow execution host)
      │ bounded versioned JSON-line IPC over a mode-0600 Unix socket
      ▼
Flutter/Dart
  sequence-cursor projections / Timeline / Plan / Workspace / Pane UI
  permission dialogs and human choices
  Terminal viewport

ianvs-acp-ffi remains the typed adapter for foreground interactive ACP
sessions and native integration tests. It is not a second Task dispatcher.
```

The core crate has no Flutter, Dart, C ABI, or widget-lifecycle dependency.
Both host adapters consume its same typed command/event model. Production
Task execution belongs to `ianvs-acpd`; Flutter never creates a parallel
`TaskScheduler` for an app-owned Rust TaskInbox.

## Ownership rules

| Rust owns | Flutter/Dart owns |
| --- | --- |
| ACP frames, version negotiation, and the capability intersection exposed by ianvs | Rendering negotiated capabilities and hiding unavailable actions |
| Agent process lifetime, stderr capture, failure detection, and recovery policy | Agent configuration forms and user-facing failure presentation |
| Session, Task, and Run transitions | Timeline, plan, tool-call, workspace, session, and pane projections |
| Command admission, concurrency, cancellation, timeouts, and bounded queues | Asking the user for a permission choice |
| Workspace canonicalization, mutation leases, and filesystem/terminal execution boundaries | Rendering permission choices and applying the selected client policy |
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
executorLeaseCommand / executorTakeover / runtimeEvents(afterSequence, limit)

Flutter -> ianvs-acpd
TaskInbox commands and current revisioned projection
runtime event cursor queries
Workflow Definition / Workflow Run / Step commands
structured Agent result submission
plan proposal / activation / usage accounting

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
concurrency observations. Expiring host reservations are supplied before a
claim. Its typed `claim_next` operation atomically chooses a
queued task by priority and creation order, enforces retry readiness, global and
per-agent quotas, runtime availability, exclusions, and canonical workspace
leases, then commits the dispatched Run, dispatch event, complete TaskInbox
projection, executor lease/generation, selected reservation, and SQLite revision
together. No capacity creates no Run, attempt, event, lease, or revision. A
no-op poll returns a structured admission reason and the earliest eligible
Core-selected `nextWakeAt` deadline.

Every executor mutation is fenced by lease id and generation. Start
acknowledgement, heartbeat, takeover, release, and command idempotency are
durable. Recovery distinguishes work that was never started from uncertainty
after session creation, prompt submission, tools, permissions, or possible
workspace mutation; uncertain work is never silently replayed.

High-volume runtime events are append-only rows with per-Run monotonic sequence
cursors. Event append is bounded and attributed to lease/generation/command.
Periodic TaskInbox checkpoints are retained in a bounded window; heartbeat does
not rewrite the complete projection. Flutter reconnects by revision and event
sequence.

`ianvs-acpd` owns the database advisory lock, scheduler, capacity reservations,
Agent processes, executor heartbeats, and background continuity. Its Unix socket
is deterministic per database, mode 0600, request/response sizes and concurrent
clients are bounded, and a second daemon cannot own the same database even via a
different socket. A permission request that cannot be settled headlessly is
cancelled fail-closed, projected as an ordered permission event, and leaves the
Run in durable human review without retaining execution capacity. The app
packages and signs the daemon beside its executable.

## Typed Workflow and coordinator

Workflow Definition versions are immutable. Workflow Runs and Step Runs have
independent CAS revisions and survive daemon restart. The v1 IR includes
`agent`, `parallel`, `map`, `reduce`, `condition`, `approval`, `wait`, and
`checkpoint`; dependencies must be acyclic and fit static node, depth, and
fan-out limits. Inputs are typed bindings or artifact references. Conditions
are typed predicates—arbitrary JavaScript never receives runtime authority.

Agent Step results use a bounded JSON Schema subset. Core extracts exactly one
JSON value, validates type/property/required/item and scalar constraints,
stores hashes and validation issues, allows at most two correction attempts,
and persists only a validated typed output. The ordinary completion command
cannot bypass a Step result schema. Exhaustion becomes explicit human review in
both Step state and the durable ledgers.

The coordinator uses semantic capability profiles rather than vendor names.
Every proposal records reason, provenance, and base/new PlanVersion; Rust
revalidates the entire graph and refuses to remove or rewrite a started Step.
Task and Progress Ledgers are durable and bounded. `maxPlanNodes`, `maxFanOut`,
`maxDepth`, `maxReplans`, `maxInvocations`, `maxConcurrentAgents`, token budget,
and cost budget are mandatory hard limits. Global Agent concurrency and each
semantic profile's parallelism are checked before a Step starts and again when a
Run is restored. Handoff/help/abstain and decentralized swarm behavior remain
unavailable experiments.

Persisted absolute workspace identities may outlive a deleted checkout, so
startup and legacy migration retain them after canonicalizing the nearest
existing ancestor. Dispatch remains fail-closed: Core must resolve the final
directory and prove that its canonical identity still matches before granting a
workspace lease.

Permission requests remain pending in Rust. Timeout, prompt completion,
explicit cancel, connection loss, and disposal use a first-wins settlement and
emit `permission_invalidated` with a stable reason. Flutter clears a permission
card only when request id, lifecycle id, and session id still match.

Configured filesystem reverse requests use the same generic permission
lifecycle as other ACP tool calls. Reads and writes become Rust-owned pending
operations while Core bounds pending content, validates the session
`WorkspaceScope`, verifies read file identity, and performs allowed writes
through a same-directory create-new temporary file plus atomic rename. Flutter
never receives file contents or an executable write command. Terminal creation
is likewise projected as an ordinary permission request; default permissions,
trust rules, auto-review, and full access apply without a hidden exception.

Neither Rust nor Flutter classifies arbitrary commands, URLs, or destinations as
"egress", and the ACP client does not claim to provide network isolation. The
agent and its tool runtime own whether an action has external side effects.

## Repository status

| Area | Status | Evidence / remaining work |
| --- | --- | --- |
| Crate separation | Implemented | `ianvs-acp-core`, typed `ianvs-acp-ffi`, and single-owner `ianvs-acpd` |
| Typed ACP v1 stdio path | Implemented for the stable session slice | Initialize, capability projection, authentication/logout, new/list/load-or-resume/close/delete session, typed MCP configuration, text/media prompt, cancel, permission response, mode/config change, notifications, stderr, and process recovery use the official Rust SDK |
| Stable host projection | Implemented | ABI v7 covers foreground ACP plus typed Task authority; daemon protocol v1 covers Task/Workflow execution and cursor projections. Strict camelCase decoders and real Dart → daemon/dylib → Rust tests are present |
| Session state | Implemented for the slice | Rust rejects illegal parallel prompts and owns permission/cancel transitions |
| Permission lifetime / timeout | Implemented | Configurable timeout, bounded pending map, first-wins invalidation, and late-choice rejection |
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
| ACP filesystem provider | Implemented on the Rust default path | Configured typed `fs/read_text_file` and `fs/write_text_file` reverse requests are session-scoped, bounded, and use the generic permission flow. Reads verify device/inode/size; writes use create-new temporary files and atomic replacement inside canonical roots |
| MCP session setup | Implemented for stable transports | Product DTOs for stdio, HTTP, and SSE are bounded and converted to typed SDK values for session new/load/resume; peer HTTP/SSE support is validated. Unstable MCP-over-ACP remains unavailable |
| Session fork | Pending in Rust | Fork remains feature-gated unstable in the official Rust schema and is not exposed by the production client |
| Scheduler / executor ownership | Implemented in daemon | Reservation-before-claim, structured admission, persisted executor generation, ack/heartbeat/takeover, idempotency, and stale-write fencing are Rust-owned |
| Event store | Implemented | Append-only per-Run events, sequence cursors, bounded replay, periodic checkpoints, and bounded retention |
| SQLite persistence and crash recovery | Durable Workflow and ACP session recovery | Workflow schema v9 uses WAL/FULL, revision CAS, classified recovery, event/checkpoint tables, immutable Workflow Definitions, and revisioned Workflow Runs. A separate `NOFOLLOW` session registry persists canonical scopes |
| Headless execution host | Implemented | `ianvs-acpd` retains background execution across Flutter disconnect; database lock and socket E2E prove a single owner and cursor reconnect |
| Typed Workflow IR | Implemented v1 | Eight initial node kinds, DAG/depth/fan-out validation, durable Plan/Step state, typed inputs, artifacts, retry/permission fields, and budgets |
| Structured Agent results | Implemented | Bounded exact-one-JSON extraction, strict schema subset, durable validation attempts, at most two corrections, non-bypassable typed output, and explicit review exhaustion |
| Bounded coordinator | Implemented, opt-in | Semantic profiles, policy-validated proposals, immutable started Steps and provenance, Task/Progress Ledgers, and hard graph/replan/invocation/concurrency/token/cost limits |
| ACP terminal provider + real PTY | Implemented on the Rust default path | All five typed ACP `terminal/*` reverse requests use bounded, session-owned `portable-pty` handles. Create validates the workspace/cwd, counts live plus approval-pending quotas, and projects attach/output/exit/release events without exposing ACP envelopes |
| Generic reverse-request admission | Implemented for terminal and filesystem operations | `terminal/create`, filesystem reads, and filesystem writes remain pending until the selected permission policy settles them. Rust retains workspace, quota, operation-identity, timeout, cancellation, and connection-loss checks; outbound classification and network isolation are intentionally outside the ACP client |
| Automatic agent restart/session recovery | Implemented for recoverable sessions | Rust retries bounded failures with exponential delay, invalidates in-flight work/permissions, reinitializes the process, and load/resumes SQLite-registered sessions before Ready. Recovery fails closed when the peer cannot restore sessions |

## Activation and verification

Run a macOS development build against the default Rust stdio client:

```sh
flutter run -d macos
```

Xcode builds `ianvs-acp-ffi` and `ianvs-acpd`, embeds the dylib in Frameworks,
and places the signed daemon beside the app executable. For the Rust tests,
native ABI tests, and real FFI fixture chain:

```sh
./tool/verify_rust_runtime.sh
```

The environment variable `IANVS_ACP_RUST_LIBRARY` may point tests or local
development at an explicit dylib. It is not a protocol escape hatch.

## Planned evolution

The task-dispatch and background-execution contract is specified in
[Task dispatch and Autopilot design](superpowers/specs/2026-07-21-task-dispatch-autopilot-design.md).
Its product-facing state language, information architecture, and staged user
experience are specified in
[Task dispatch product experience](superpowers/specs/2026-07-21-task-dispatch-product-experience.md).
Its P0/P1 correctness and recovery gates are implemented in the Rust-owned
background host. Automatic trigger volume remains gated on operational evidence
from that path rather than introducing another execution authority.

1. Keep git push, pull-request creation, and uploads in the agent/tool layer;
   surface their progress and results through ordinary task and permission events.
2. Implement Rust remote ACP transports while keeping unsupported configurations
   fail-closed.
3. Evaluate unstable fork and MCP-over-ACP separately without exposing raw ACP
   payloads through FFI.
4. Benchmark opt-in bounded replanning against the static Workflow baseline with
   model/token/cost normalization before enabling any dynamic organization by
   default.

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
