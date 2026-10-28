# Shared agent contract

Implemented on 2026-10-28 for the ACP and Terminal hosts. Packages are maintained
under `ianvs-acp/packages`; both repositories use sibling path dependencies during
development. Breaking changes update all consumers; no legacy model aliases or
application native re-export wrappers remain.

## Dependency and state ownership

| Package | Responsibility | Consumers |
| --- | --- | --- |
| `ianvs_agent_core` | Pure Dart models, stream session contract, owner-controlled buffered messages, typed content events/reducer and replay staging | Runtime adapter, both hosts and chat |
| `ianvs_acp_runtime` | Rust ACP v1, process/connection lifecycle, protocol request correlation, permission validity, cancellation/recovery and Dart FFI | Both hosts |
| `ianvs_agent_chat` | Flutter stream binding, body/tool/plan/permission presentation, optional timeline/composer and LLM library | Both hosts |
| `ianvs_mermaid` | Optional native renderer, cache and SVG presentation | Explicit desktop host injection |

Core never imports Flutter or the runtime. Runtime depends on core. Chat depends
on core, `ianvs_markdown` and `ianvs_design`, but not runtime or Mermaid.
ACP, LLM tool approval and Trail approval are distinct authorization domains.
The LLM adapter remains `ianvs_agent_chat/llm.dart`; it uses the core stream
contract and invokes only host-registered executors. Widgets do not execute tools.

Runtime recovery storage retains its protocol mechanism. Hosts choose storage
location/retention and own business data. Core is a reconstructible content view;
application transcript caches are derived projections, not a second wire authority.

## Core and product integration

Import `package:ianvs_agent_core/ianvs_agent_core.dart`. `ChatSession.state` is the
current snapshot; `Stream<ChatSessionState> get changes` publishes updates.
Subscribe before reading state. Changed buffered messages increment revision;
list changes increment `messagesRevision`. UI unmount only cancels subscriptions.

`ChatContentIdentity` includes connection generation and session ID.
`ChatContentUpdate` carries turn identity and typed content kind. Tools merge by
turn/call ID; null partial fields preserve prior values, explicit empty collections
replace them. Replay uses `beginRestore`, `commitRestore`, and `discardRestore`;
only a matching backend success commits staged content.

The ACP application consumes `ChatMessage`, `ChatTextMutation`,
`findChatToolMessage` and `mergeChatToolMetadata` directly. Its former atomic text
mutation calculation and partial-tool merge implementation were removed from
`lib/state/chat_controller.dart`. `ChatContentProjection` uses the same primitives.
The app retains queueing, overall UI/cache admission policy and business notices;
it does not run a second copy of these content mutation algorithms.

`package:ianvs_acp_runtime/acp_chat_session.dart` exposes `AcpRuntimeChatSession`
for an already-created native session, with core projection and replay staging.
It owns its subscription, not the runtime. The host creates sessions and retains
launch, capability and configuration policy. This small adapter does not advertise
attachments/config/queue features that it does not implement; richer hosts may
consume native commands/events and shared core primitives directly.

## Native control contract

- C ABI **12**, event schema **5**, ACP wire **v1**. Build matching native and Dart
  sources. SDK package major versions do not imply a wire upgrade.
- `startAgent` requires `AcpEnvironmentPolicy.replace` or `inheritAndOverride`.
  Replace clears inherited environment before applying the supplied map.
- `maxRestartAttempts` defaults to **0**. Terminal explicitly uses replace and
  zero retries; reconnection must not replay its business writes.
- MCP servers are fixed per runtime launch. HTTP header maps, including
  Authorization, are retained for new/load/recovery. Model settings use existing
  config-option commands/events. No speculative per-session MCP API was added.
- Ready event `data['capabilities']['agentInfo']` retains initialize agentInfo,
  including name/version, within the initialize projection byte budget.
- `turn_completed.metadata` includes the original `requestId`, `stopReason`, and
  `resultMeta`: prompt `_meta` as an object or null, limited to **16384 serialized
  bytes**. Overflow emits correlated `prompt_failed`, never silent truncation.
- Permission control events preserve request/session/tool-call IDs, `rawInput`
  and offered choices. BridgePermissions uses these fields, not display metadata.
- Normal cancellation waits for the original prompt result. Disconnect/stream
  closure fails pending operations; it is not normal completion.
- Dispose uses an out-of-band shutdown signal, interrupting initialize and setup
  waits before the command loop is available. Child ownership remains native.

Use separate consumer Cargo targets when building both hosts concurrently.

## Embedded Flutter content

Import widgets from `package:ianvs_agent_chat/ianvs_agent_chat.dart` and models
from core. `ChatMessageBody` accepts text, user styling, input budget,
`ChatResourcePolicy`, link callback, optional diagram builder, `documentSelection`,
`softLineBreak` and `clipboardWriter`. It owns no conversation scroll container;
standard Markdown code/table content may use internal scrolling where needed.

Resources are blocked by default. Only an explicit host image callback authorizes
loading. Links go to the host. Without `diagramBuilder`, diagrams display source.
`ChatToolCard`, `ChatPlanCard` and `ChatPermissionCard` expose separate presentation.

Terminal passes `documentSelection: true` and `softLineBreak: true`. Clipboard
writing defaults to `writeIanvsMarkdownClipboard`; a supplied
`IanvsMarkdownClipboardWriter` receives the standard payload. No second Markdown
parser is maintained. Literal terminal commands/evidence remain host content.

The ACP host injects `ianvs_mermaid` through `ChatRenderingScope`. The base chat
package has no `merman` dependency. Mobile scope is basic content presentation;
local ACP and native Mermaid mobile execution are not claimed.

## Development and verification

The ACP app consumes `../ianvs-terminal/packages/ianvs_terminal_core`, whose
maintained source disables stripping that produces malformed Mach-O libraries on
the current linker. No temporary dependency override remains. CI checks out both
repositories as siblings; `tool/flutter_workspace.sh` includes core and Mermaid.

See [verification.md](verification.md) for commands, results and validation limits.
