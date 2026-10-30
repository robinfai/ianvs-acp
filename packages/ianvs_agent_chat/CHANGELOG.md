## 0.3.1

* Require `ianvs_markdown ^0.3.2` so consumers receive measured ordered-list markers and bounded, compact table columns with horizontal scrolling on narrow screens.
* Add real timeline consumer regressions for narrow table readability, horizontal gestures and ordered-list marker widths. Public chat APIs are unchanged.

## 0.3.0

* Extract pure Dart models and sessions into `ianvs_agent_core`; move native diagrams into optional `ianvs_mermaid`.
* Share message frames, literal code previews and presentation-only decision cards with mixed timelines. Tool cards support hidden default details, host footers and controlled expansion.
* Add `PromptInput.hosted` for host-owned editor/action subtrees without creating input controllers or sending/stopping actions. Keep editor composition, selection and focus through slot changes.
* Use the same frames and decision surfaces in the built-in conversation and permission UI, with consistent role padding and compact layouts.

* Preserve `ianvs_markdown`'s theme and typography for messages and summaries, and use its built-in code blocks and links. Keep host link handling, Mermaid rendering, blocked-image copying and render budgets.

## 0.2.0

* Add host-owned `ChatComposerController` and immutable draft submissions with explicit accepted, queued and rejected receipts. Preserve drafts on rejection or stale receipts and prevent concurrent submission.
* Keep legacy `ChatSession.send` completion timing; LLM and the example opt into admission. Add `CallbackSubmissionChatSession` and execution-policy/queue callbacks.
* Use local composer constraints, shared content width and compact margins. Keep all typed configuration options and advanced menus reachable.
* Pause streaming scroll follow while reading older messages and expose Jump to latest.
* Default to portable Flutter semantics. `ChatNativeTextFieldScope` enables the ACP native proxy only in hosts that register it.
* Render chat through `ianvs_markdown ^0.3.1` with the standard GFM preset and shared budget scanner. Retain chat code/diagram builders, safe images, block selection and host link handling.


* Adopt `ianvs_design` for shared controls, typography and light/dark themes.
* Resolve partial `ChatThemeData` color overrides against the ambient theme and expose the conversation reading font size.
* Switch code highlighting, Mermaid diagrams and permission feedback with the host appearance.
* Remove the application-specific `ui/theme/app_theme.dart` and `ui/theme/app_design_tokens.dart`; use the public Ianvs Design APIs instead.

## 0.1.0

* Extract the conversation timeline and composer from the Ianvs ACP desktop app.
* Add backend-neutral session state, actions, capability flags and typed message helpers.
* Include streaming Markdown, code, images, Mermaid, tool activity, plans, permissions and queued prompt presentation.
* Add per-conversation themes, primary composer labels, tool presentation rules and replaceable platform services.
* Include an optional OpenAI-compatible LLM adapter with bounded SSE parsing, independent conversation history, cancellation, tool execution and approval callbacks.
* Include a standalone macOS example and an in-memory demonstration backend.
