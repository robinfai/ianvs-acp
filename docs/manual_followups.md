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
  embedded resource blobs when `embeddedContext` is advertised, and all fall
  back to resource links otherwise.
- `test/ui/chat_timeline_test.dart` verifies non-text/resource-link content
  renders in the timeline.

Manual validation:

- Run a real Spark-backed session and confirm whether embedded
  text/image/audio/binary attachments and file resource links are accepted,
  ignored, or rejected.
- Record any agent-specific limitations in user-facing docs if Spark behavior is
  intentionally narrower than ACP's representation.

### tool-permission-ui

Status: security/product decision needed.

Non-blocking because: tool calls are visible and grouped, and permission
requests are conservatively cancelled until an interactive approval model
exists. Interactive permission approval still requires a clear trust and
interruption model.

Automated acceptance:

- `test/ui/chat_timeline_test.dart` verifies tool calls render as compact,
  expandable cards and grouped cards.
- `test/acp/dart_acp_agent_client_test.dart` verifies agent permission requests
  receive a `cancelled` outcome while there is no interactive permission UI.

Manual decision:

- Define approval timing, allow/deny persistence, cancellation behavior, and
  how permission requests interact with streaming output.

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
