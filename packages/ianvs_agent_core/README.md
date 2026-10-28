# ianvs_agent_core

Pure Dart contracts and reconstructible conversation content. No Flutter, process,
FFI, credential, filesystem, or ACP wire ownership.

Import `package:ianvs_agent_core/ianvs_agent_core.dart`. `ChatSession.state` is the
current snapshot; subscribe to `changes` before reading it. The session owner
calls `dispose`; views only cancel subscriptions. Content changes increment
`messagesRevision`, and changed buffered messages increment their own revision.

`ChatContentProjection` merges typed `ChatContentUpdate`s by connection generation,
session, turn, and tool ID. Replay is staged and committed only after a matching
backend success; failure discards staging without replacing visible history.
`ChatMessage` provides bounded buffered text and owner-token controlled mutation
for hosts with their own queue and projection policies.

Runtime adapters own backend request completion, cancellation and approval validity.
Core contains no second execution state machine. Host submission IDs are separate
from backend request IDs. No approval card or content event executes a tool.

Run `dart pub get`, `dart analyze`, and `dart test` in this directory.
