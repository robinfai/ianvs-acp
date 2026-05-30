# Non-Blocking Manual Follow-Ups

Date: 2026-05-30

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

### auth-authenticate

Status: product decision needed.

Non-blocking because: logout is implemented for agents that advertise
`auth.logout`; the missing authenticate flow needs UX decisions for entry point,
login state display, and credential lifetime.

Automated acceptance:

- `test/ui/capabilities_dialog_test.dart` verifies auth capability rendering.
- `test/state/chat_controller_test.dart` verifies logout clears local session
  state.
- `test/ui/app_shell_test.dart` verifies the toolbar exposes logout when
  supported.

Manual decision:

- Choose the authenticate entry point and logged-in/logged-out UI state.
- Decide how credentials or auth handoff state should be stored, refreshed, and
  cleared.

### session-fork

Status: product decision needed.

Non-blocking because: session creation, resume, close, and metadata updates are
working; fork changes session lineage and sidebar semantics.

Automated acceptance:

- `test/ui/capabilities_dialog_test.dart` verifies fork capability visibility.
- `test/ui/session_sidebar_test.dart` covers session list rendering behavior that
  forked sessions would extend.

Manual decision:

- Decide whether forked sessions appear as independent sidebar rows, nested
  children, or a filtered branch view.
- Decide whether fork should preserve current model/config state in the UI.

### fs-terminal-providers

Status: security decision needed.

Non-blocking because: the client deliberately advertises filesystem and terminal
support as unavailable until permission UX exists.

Automated acceptance:

- `test/ui/capabilities_dialog_test.dart` verifies filesystem and terminal
  capability visibility.
- `lib/acp/dart_acp_agent_client.dart` currently constructs ACP capabilities
  with `readTextFile: false` and `writeTextFile: false`.

Manual decision:

- Define read/write filesystem permission prompts, scope, audit logging, and
  denial behavior.
- Define terminal session lifecycle, cwd/environment handling, and command
  approval UX before advertising terminal support.

### slash-command-picker

Status: product decision needed.

Non-blocking because: command updates already render; invocation works manually
by typing slash commands, but no picker/autocomplete UX exists.

Automated acceptance:

- `test/ui/chat_timeline_test.dart` verifies available command details render.
- `test/state/chat_controller_test.dart` verifies command snapshots replace
  stale command status messages through generic status replacement behavior.

Manual decision:

- Decide whether command invocation belongs in prompt input autocomplete, a
  separate command palette, or both.
- Decide how command arguments should be collected and validated.

### mcp-server-config

Status: product/config decision needed.

Non-blocking because: agent server configuration is stable; exposing MCP server
configuration changes the user config schema and validation surface.

Automated acceptance:

- `test/config/acp_client_config_test.dart` verifies the current supported
  user-level `agent_servers` configuration.
- `test/ui/agent_config_dialog_test.dart` verifies configured agents render in
  the UI.

Manual decision:

- Decide whether MCP servers live beside `agent_servers`, inside each agent
  server, or in profiles.
- Decide how secrets, environment variables, and transport-specific MCP settings
  should be represented.

### spark-attachments

Status: manual integration validation needed.

Non-blocking because: ACP resource links are generated and forwarded, but a
specific agent/model can still decline, ignore, or reinterpret attachment
context.

Automated acceptance:

- `test/ui/prompt_input_test.dart` verifies file attachments can be selected,
  removed, and sent without text.
- `test/state/chat_controller_test.dart` verifies attachments are forwarded as
  resource link content metadata.
- `test/ui/chat_timeline_test.dart` verifies non-text/resource-link content
  renders in the timeline.

Manual validation:

- Run a real Spark-backed session and confirm whether attached file resource
  links are accepted, ignored, or rejected.
- Record any agent-specific limitations in user-facing docs if Spark behavior is
  intentionally narrower than ACP's representation.

### initialization-metadata

Status: product/API decision needed.

Non-blocking because: negotiated capabilities are visible; `clientInfo` and
`agentInfo` are useful compatibility metadata but are not required for the
current stdio session flow.

Automated acceptance:

- `test/ui/capabilities_dialog_test.dart` verifies capability rendering and raw
  capability data.
- `lib/acp/acp_agent_capabilities.dart` preserves raw agent capability metadata.

Manual decision:

- Decide which `clientInfo` values the app should advertise.
- Decide where `agentInfo` should appear in the UI, and whether it should affect
  agent selection or diagnostics.

### tool-permission-ui

Status: security/product decision needed.

Non-blocking because: tool calls are visible and grouped, but interactive
permission approval requires a clear trust and interruption model.

Automated acceptance:

- `test/ui/chat_timeline_test.dart` verifies tool calls render as compact,
  expandable cards and grouped cards.

Manual decision:

- Define approval timing, allow/deny persistence, cancellation behavior, and
  how permission requests interact with streaming output.

### prompt-content-gates

Status: product decision needed.

Non-blocking because: text and file resource-link prompts work; richer
prompt-side image/audio/embedded content should be gated by advertised agent
capabilities and picker support.

Automated acceptance:

- `test/ui/prompt_input_test.dart` covers the current file attachment UX.
- `test/state/chat_controller_test.dart` verifies prompt attachment forwarding.
- `test/ui/chat_timeline_test.dart` verifies output content block rendering.

Manual decision:

- Decide which prompt-side content types to expose first and how to disable or
  explain unavailable types when the agent does not advertise support.

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
