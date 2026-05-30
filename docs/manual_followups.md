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

Status: remote interoperability and HTTP/2 hardening needed.

Non-blocking because: local stdio remains supported, WebSocket remote agents can
be configured with `agent_servers[].type = "websocket"` plus a `ws` or `wss`
URL, and draft Streamable HTTP/SSE agents can be configured with
`agent_servers[].type = "http"` or `"sse"` plus an `http` or `https` URL. The
new HTTP transport covers long-lived connection/session SSE streams, POST/202
response routing, `Acp-Connection-Id`, `Acp-Session-Id`, headers, and cookies,
plus best-effort `DELETE` teardown, but the draft profile still needs HTTP/2
enforcement and real-agent interoperability testing.

Automated acceptance:

- `test/config/acp_client_config_test.dart` verifies WebSocket and Streamable
  HTTP/SSE agent server config parsing plus invalid config rejection.
- `test/acp/dart_acp_agent_client_test.dart` verifies the client connects to a
  local WebSocket ACP agent, forwards custom headers, initializes, creates a
  session, receives session updates, and completes a prompt turn. It also
  verifies a local Streamable HTTP/SSE ACP agent path, including headers,
  cookies, connection/session stream routing, prompt completion, and best-effort
  `DELETE` teardown.
- `lib/acp/web_socket_acp_transport.dart` implements the JSON-RPC
  `StreamChannel` adapter used by `dart_acp`.
- `lib/acp/streamable_http_acp_transport.dart` implements the draft HTTP/SSE
  `StreamChannel` adapter used by `dart_acp`.

Manual decision:

- Decide whether to enforce HTTP/2 at connection time before the RFD stabilizes,
  and whether WebSocket fallback should be preferred or user-selectable.
- Validate WebSocket and Streamable HTTP/SSE against real remote ACP agents that
  implement the draft endpoint.

### fs-terminal-providers

Status: policy refinement needed.

Non-blocking because: filesystem and terminal providers are now available only
when explicitly enabled through `client_providers`, remain off by default, use
per-request permission approval, and record decisions in exportable bounded
in-process Permission History. Explicit permission trust rules can auto-allow or
auto-deny matching requests. Terminal support emits lifecycle and output
snapshots into the timeline, but deliberately does not yet provide a persistent
live terminal panel or broader policy controls.

Automated acceptance:

- `test/ui/capabilities_dialog_test.dart` verifies filesystem and terminal
  capability visibility.
- `test/config/acp_client_config_test.dart` verifies filesystem and terminal
  provider config parsing, permission trust rule parsing, and invalid config
  rejection.
- `test/acp/dart_acp_agent_client_test.dart` verifies configured filesystem
  capabilities are advertised and that approved read requests are served from a
  workspace-jailed provider. It also verifies configured terminal capabilities
  are advertised and that approved terminal requests emit created/exited/output
  lifecycle events.
- `test/state/chat_controller_test.dart` verifies terminal lifecycle updates for
  the same terminal id merge into one timeline status row, matching permission
  trust rules auto-resolve requests, and Permission History keeps a bounded
  in-process audit window.
- `test/ui/chat_timeline_test.dart` verifies terminal status output renders in
  the timeline.
- `test/ui/agent_config_dialog_test.dart` verifies filesystem, terminal, and
  permission trust rule config is visible in Agent Configuration.
- `lib/acp/dart_acp_agent_client.dart` still defaults ACP filesystem and
  terminal capabilities to disabled unless the user opts in.

Manual decision:

- Decide whether filesystem and terminal providers should remain config-only or
  gain a first-run UI, long-term audit retention, rule management UI, or broader
  policy controls.
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

Non-blocking because: tool calls are visible and grouped, permission requests
surface an in-app per-request approval banner with Allow Once, Deny, and Cancel,
and handled requests are visible in the Agents menu Permission History with JSON
export of the newest bounded in-process audit entries. Resolved entries record
whether the decision came from a manual action, trust rule, or system
cancellation. Explicit permission trust rules can auto-allow or auto-deny
matching requests. Requests still fall back to `cancelled` when no UI listener
is active, and broader trust policy remains deliberately narrow.

Automated acceptance:

- `test/ui/chat_timeline_test.dart` verifies tool calls render as compact,
  expandable cards and grouped cards.
- `test/acp/dart_acp_agent_client_test.dart` verifies agent permission requests
  receive a `cancelled` outcome when no interactive UI is listening and receive
  a selected allow option when approved through the interactive response path.
- `test/ui/acp_client_app_test.dart` verifies the permission banner resolves an
  approval back to the agent client and displays the completed request in
  Permission History.
- `test/ui/permission_history_dialog_test.dart` verifies Permission History
  exports a JSON audit file payload with decision source metadata and disables
  export when no entries exist.
- `test/state/chat_controller_test.dart` verifies permission requests are
  recorded as pending, resolved to the selected decision, cancelled when a newer
  pending request supersedes them, and trimmed to a bounded in-process audit
  window. It also verifies matching trust rules auto-resolve requests.
- `test/config/acp_client_config_test.dart` verifies permission trust rule
  parsing and invalid config rejection.
- `test/ui/app_shell_test.dart` verifies the Agents menu exposes Permission
  History when permission audit entries exist.

Manual decision:

- Decide whether to add request grouping, trust rule management UI, long-term
  persisted audit retention, or stronger streaming interruption behavior beyond
  the current per-request Allow Once/Deny/Cancel model.

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

Status: future content-source decision needed.

Non-blocking because: text, file resource-link prompts, embedded text-file
prompts, image prompts, audio prompts, and generic binary embedded resource
prompts work. The file attachment UI now marks selected files with the same
capability-aware send mode used by the ACP client: Image, Audio, Embed, or Link.
Future generated or non-file prompt content should still be gated by advertised
agent capabilities and picker support.

Automated acceptance:

- `test/acp/prompt_attachment_test.dart` verifies prompt attachment mode
  classification for media, embedded resources, and resource-link fallbacks.
- `test/ui/prompt_input_test.dart` covers the current file attachment UX and
  verifies attachment chips display capability-aware send modes.
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
