# Non-Blocking Manual Follow-Ups

Date: 2026-05-31

This document keeps product, security, and environment-dependent work visible
without treating those items as release blockers for the current ACP client
implementation. Each item records the strongest automated acceptance that exists
today, plus the manual decision or validation still needed before implementation.

## Acceptance Policy

- Every item must explain why it is non-blocking.
- Every item must list automated acceptance evidence, or explicitly say why no
  useful automation exists before a product/security decision is made.
- Referenced source, test, and documentation paths must exist.
- When an item becomes implementation-ready, add or update automated tests before
  removing it from this list.

## Checklist

### remote-transports

Status: Streamable HTTP/SSE implementation needed.

Non-blocking because: local stdio remains supported and WebSocket remote agents
can now be configured with `agent_servers[].type = "websocket"` plus a `ws` or
`wss` URL. Full Streamable HTTP/SSE is still a draft transport profile that
requires long-lived GET streams, POST/202 response routing, HTTP/2 validation,
connection/session headers, and real-agent interoperability testing.

Automated acceptance:

- `test/config/acp_client_config_test.dart` verifies WebSocket agent server
  config parsing and invalid WebSocket config rejection.
- `test/acp/dart_acp_agent_client_test.dart` verifies the client connects to a
  local WebSocket ACP agent, forwards custom headers, initializes, creates a
  session, receives session updates, and completes a prompt turn.
- `lib/acp/web_socket_acp_transport.dart` implements the JSON-RPC
  `StreamChannel` adapter used by `dart_acp`.

Manual decision:

- Decide when to implement the Streamable HTTP/SSE profile from the draft RFD,
  including HTTP/2 requirements, cookie/header handling, and whether WebSocket
  fallback should be preferred or user-selectable.
- Validate against a real remote ACP agent that implements the draft endpoint.

### fs-terminal-providers

Status: policy refinement needed.

Non-blocking because: filesystem and terminal providers are now available only
when explicitly enabled through `client_providers`, remain off by default, and
still use per-request permission approval. Terminal support emits lifecycle and
output snapshots into the timeline, but deliberately does not yet provide a
persistent live terminal panel or saved trust rules.

Automated acceptance:

- `test/ui/capabilities_dialog_test.dart` verifies filesystem and terminal
  capability visibility.
- `test/config/acp_client_config_test.dart` verifies filesystem and terminal
  provider config parsing and invalid config rejection.
- `test/acp/dart_acp_agent_client_test.dart` verifies configured filesystem
  capabilities are advertised and that approved read requests are served from a
  workspace-jailed provider. It also verifies configured terminal capabilities
  are advertised and that approved terminal requests emit created/exited/output
  lifecycle events.
- `test/state/chat_controller_test.dart` verifies terminal lifecycle updates for
  the same terminal id merge into one timeline status row.
- `test/ui/chat_timeline_test.dart` verifies terminal status output renders in
  the timeline.
- `test/ui/agent_config_dialog_test.dart` verifies filesystem and terminal
  provider config is visible in Agent Configuration.
- `lib/acp/dart_acp_agent_client.dart` still defaults ACP filesystem and
  terminal capabilities to disabled unless the user opts in.

Manual decision:

- Decide whether filesystem and terminal providers should remain config-only or
  gain a first-run UI, audit history, persistent trust rules, or broader policy
  controls.
- Decide whether terminal support should grow beyond timeline snapshots into a
  live terminal panel with kill/release controls and richer cwd/environment
  visibility.

### spark-attachments

Status: manual integration validation needed.

Non-blocking because: small text attachments are embedded when the agent
advertises embedded context support, image attachments are embedded when the
agent advertises image prompt support, audio attachments are embedded when the
agent advertises audio prompt support, generic binary attachments are embedded
when embedded context is advertised, and unsupported or oversized attachments
are still forwarded as ACP resource links. A specific agent/model can still
decline, ignore, or reinterpret attachment context.

Automated acceptance:

- `test/ui/prompt_input_test.dart` verifies file attachments can be selected,
  removed, and sent without text.
- `test/state/chat_controller_test.dart` verifies attachments are forwarded as
  resource link content metadata.
- `test/acp/dart_acp_agent_client_test.dart` verifies text attachments become
  embedded resources when `embeddedContext` is advertised, image attachments
  become image content when `image` is advertised, audio attachments become
  audio content when `audio` is advertised, generic binary attachments become
  embedded resource blobs when `embeddedContext` is advertised, prompt-side
  `@file` mentions remain resource links when attachments are present, and all
  attachments fall back to resource links otherwise.
- `test/ui/chat_timeline_test.dart` verifies non-text/resource-link content
  renders in the timeline.

Manual validation:

- Run a real Spark-backed session and confirm whether embedded
  text/image/audio/binary attachments and file resource links are accepted,
  ignored, or rejected.
- Record any agent-specific limitations in user-facing docs if Spark behavior is
  intentionally narrower than ACP's representation.

### tool-permission-ui

Status: policy refinement needed.

Non-blocking because: tool calls are visible and grouped, and permission
requests now surface an in-app per-request approval banner with Allow Once,
Deny, and Cancel. Requests still fall back to `cancelled` when no UI listener is
active, and persistent allow/deny rules remain deliberately undefined.

Automated acceptance:

- `test/ui/chat_timeline_test.dart` verifies tool calls render as compact,
  expandable cards and grouped cards.
- `test/acp/dart_acp_agent_client_test.dart` verifies agent permission requests
  receive a `cancelled` outcome when no interactive UI is listening and receive
  a selected allow option when approved through the interactive response path.
- `test/ui/acp_client_app_test.dart` verifies the permission banner resolves an
  approval back to the agent client.

Manual decision:

- Decide whether to add persistent allow/deny rules, request grouping, audit
  history, or stronger streaming interruption behavior beyond the current
  per-request Allow Once/Deny/Cancel model.

### vendor-extension-workflows

Status: agent-specific product decision needed.

Non-blocking because: raw `_meta` capability data is visible and the Agents menu
now includes a generic Extension Request dialog for underscore-prefixed custom
JSON-RPC requests. A polished workflow for any single vendor extension should
wait until a real agent contract is known.

Automated acceptance:

- `test/acp/dart_acp_agent_client_test.dart` verifies custom extension requests
  are sent over the ACP client and return raw JSON results.
- `test/ui/extension_request_dialog_test.dart` verifies the dialog sends
  extension method/params JSON and rejects non-object params JSON.
- `test/ui/acp_client_app_test.dart` verifies the app opens the Extension
  Request dialog from the Agents menu.
- `test/ui/app_shell_test.dart` verifies the Agents menu exposes Extension
  Request when available.

Manual decision:

- Decide which advertised `_meta` contracts deserve first-class controls,
  labels, result rendering, or notification flows beyond the generic JSON
  request dialog.

### prompt-content-gates

Status: product decision needed.

Non-blocking because: text, file resource-link prompts, embedded text-file
prompts, image prompts, audio prompts, and generic binary embedded resource
prompts work. Future generated or non-file prompt content should still be gated
by advertised agent capabilities and picker support.

Automated acceptance:

- `test/ui/prompt_input_test.dart` covers the current file attachment UX.
- `test/state/chat_controller_test.dart` verifies prompt attachment forwarding.
- `test/acp/dart_acp_agent_client_test.dart` verifies embedded text, image,
  audio, and generic binary attachment capability gating.
- `test/ui/chat_timeline_test.dart` verifies output content block rendering.

Manual decision:

- Decide whether to add generated/non-file prompt content sources beyond the
  current file attachment picker, and how to disable or explain unavailable
  types when the agent does not advertise support.

### desktop-manual-qa

Status: environment validation needed.

Non-blocking because: automated widget tests and release builds pass; direct
desktop interaction validation was limited by local accessibility/window capture
failures.

Automated acceptance:

- `flutter analyze`
- `flutter test`
- `flutter build macos --release`

Manual validation:

- Once local window capture works, verify text-field focus, attachment picker,
  real agent connection, resume selection, logout, and close-session flows in
  the built macOS app.
