## Unreleased

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
