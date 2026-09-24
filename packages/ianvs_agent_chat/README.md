# ianvs_agent_chat

Reusable Flutter **Agent Chat UI** for ACP-powered agents and OpenAI-compatible LLM APIs. The timeline and composer are shared; your host retains ownership of connections, workspaces, persistence and tool execution.

## Features

- Streaming messages, Markdown, highlighted code, Mermaid and bounded image previews.
- Tool activity groups, execution details, plans, permission choices and conversation navigation.
- A common `ChatSession` interface, capability-driven controls and independent session lifetimes.
- Optional OpenAI-compatible Chat Completions adapter with history, cancellation and approved host tools.
- Theme, tool presentation and platform extension points.
- A runnable macOS example with offline demo and real API connection screens.

## Install

```yaml
dependencies:
  ianvs_agent_chat: ^0.2.0
```

Requires Dart 3.12 or later and Flutter. The desktop integration is validated on macOS. Other platforms require testing their file, drag/drop, clipboard and Mermaid integrations; this release does not claim full platform parity.

## Use an LLM API

```dart
import 'package:ianvs_agent_chat/ianvs_agent_chat.dart';
import 'package:ianvs_agent_chat/llm.dart';

final session = LlmChatSession(
  client: OpenAiChatClient(
    endpoint: Uri.parse('https://your-provider.example/v1/chat/completions'),
    model: modelName,
    apiKey: apiKeyFromYourHost,
  ),
);

// Put this widget inside a bounded layout, e.g. Scaffold.body or Expanded.
AgentChatView(session: session);

// The host owns this lifetime. Removing AgentChatView does not dispose it.
session.dispose();
```

`endpoint` is the full Chat Completions URL. Headers and provider extensions can be supplied using `headers` and `extraBody`; reserved request fields cannot be overridden. For DeepSeek, use its completion endpoint and model name; an optional extension is `extraBody: {'thinking': {'type': 'disabled'}}`. Streamed `reasoning_content` is retained for tool round trips when supplied by a compatible provider.

For an optional connection form that keeps credentials in memory:

```dart
import 'package:ianvs_agent_chat/llm_chat_panel.dart';

const LlmChatPanel();
```

The panel owns and disposes its session. It does not persist API keys. For public web clients, supply an authenticated backend proxy instead of embedding a provider secret.

### Tools and approval

Register only the tools your host wants the model to access. Validate business arguments inside each executor. Executors receive a cancellation token and should honor it; stopping a conversation cannot reverse a tool's completed side effects.

```dart
final tools = [
  ChatTool(
    name: 'add_integers',
    description: 'Add two integers.',
    parameters: {
      'type': 'object',
      'properties': {
        'a': {'type': 'integer'},
        'b': {'type': 'integer'},
      },
      'required': ['a', 'b'],
    },
    execute: (arguments, cancellation) async {
      cancellation.check();
      return '${(arguments['a'] as int) + (arguments['b'] as int)}';
    },
  ),
];
```

Approval is required by default. `AgentChatView` renders the pending request and routes the user's choice back to the session. Denied, invalid and failed tools become tool results without silently executing. Set `requiresApproval: false` only when your host has authorized that tool.

The adapter supports text and explicitly enabled inline image inputs. Audio, arbitrary file uploads, server-side session restore and automatic model discovery are not implemented. It retains completed turns in memory and trims whole turns to configured context limits. Failed or cancelled turns remain visible but are excluded from subsequent model context.

## Connect an ACP client

The package does **not** bundle an ACP transport, process runner or the Ianvs application controller. Adapt your existing client using `ChatSession` or `CallbackChatSession`:

```dart
final session = CallbackChatSession(
  changes: yourController,
  readState: () => ChatSessionState(
    identity: yourSessionId,
    agentName: 'My ACP Agent',
    messages: projectedMessages,
    messagesRevision: transcriptRevision,
    isSending: isStreaming,
    isLoading: isRestoring,
    capabilities: const ChatCapabilities(tools: true, permissions: true),
    permission: projectedPermission,
  ),
  onSend: (text, attachments) => sendToAgent(text, attachments),
  onStop: cancelAgentPrompt,
  onResolvePermission: resolveAgentPermission,
);
```

Project protocol data into the public models. `ChatToolMessage`, `ChatPlanMessage` and `ChatThoughtMessage` supply typed construction helpers. An existing buffered message model can implement `ChatMessageView` to avoid copying a long transcript on every token. Increment message revisions and `messagesRevision` for in-place updates, and change session `identity` when switching conversations. Keep restore staging invisible until your complete snapshot is ready.

The originating Ianvs app uses this boundary in `lib/chat/acp_chat_session.dart`, preserving its ACP replay, storage, permission and queue logic.

## Drafts and submission admission

For quick prompts or host context actions, retain a `ChatComposerController`,
pass it to `AgentChatView(composerController: draft)`, then call
`draft.replaceText(...)`, `draft.insertText(...)` or `draft.requestFocus()`.
It exposes `text`, `selection` and `revision`. `clear()` also clears mounted
attachments. The host disposes its controller after unmounting the view.
A different `state.identity` clears a reused controller. Keep identity stable
through first-send backend initialization, configuration and saved-result version
changes. Separate controllers can retain separate text drafts across mounts.

Implement `ChatSubmissionSession` alongside `ChatSession` for reliable admission:

```dart
final receipts = ChatSubmissionLedger();

Future<ChatSubmitResult> submit(ChatSubmission draft) => receipts.submit(
  draft,
  () async {
    if (draft.sessionIdentity != state.identity) {
      return const ChatSubmitResult.rejected('The conversation changed.');
    }
    // Validate the final payload and take ownership/start generation here.
    // Return before waiting for generation to finish.
    await admitPrompt(draft.text, draft.attachments);
    return const ChatSubmitResult.accepted();
  },
);
```

`ChatSubmission` freezes `id`, `sessionIdentity`, `draftRevision`, `text` and
`attachments`. Accepted or queued results clear only the matching draft revision;
rejections and thrown admission errors preserve the draft and show a reason.
Editing while admission is pending is allowed; repeated submits are disabled.
The ledger deduplicates pending and completed IDs. An intentional retry needs a
new ID. Preserve one ledger for the adapter's lifetime, including across view
rebuilds. Validate the captured conversation again after any asynchronous setup
before admitting it. Failures after acceptance belong in the transcript/error.

`CallbackSubmissionChatSession` provides the same contract through `onSubmit`;
`CallbackChatSession` and legacy `onSend` callers retain immediate clearing.
Existing `send` completion timing is unchanged. LLM `submit` returns admission,
while LLM `send` still waits for generation. Do not call both for one request.

Wrap the default child with `composerBuilder` to show a quote or business action.
Capture host context and its revision synchronously on submission and clear it
only after matching acceptance. Keep article fields and save/copy actions in the
host. Project models, modes and booleans into `configOptions`; all selectable
options are reachable. Advertise capabilities only for implemented operations.

## Customize

The app and this package use `ianvs_design` for Material 3 controls, light/dark
surfaces, spacing and monospaced typography. Configure the host with
`IanvsTheme.light()`, `IanvsTheme.dark()` and `ThemeMode.system`. Standalone
`ChatTimeline` and `PromptInput` also derive their palette from the ambient
Ianvs theme. A plain Material host receives Ianvs defaults matching its brightness.

```dart
ChatTheme(
  data: const ChatThemeData(
    colors: {'userMessageSurface': Color(0xffeef4ff)},
    contentMaxWidth: 900,
  ),
  child: AgentChatView(session: session),
);
```

- Use `ChatTheme` for conversation surfaces, semantic status colors and content width. Unspecified colors continue to follow the host theme, including after a light/dark switch. Markdown typography and colors belong to `ianvs_markdown`; the legacy `bodyFontSize` field no longer overrides message rendering. Mermaid rendering follows host brightness.
- Use `ChatStrings` to override primary composer labels. Full localization is not included in this release.
- Supply `ToolPresentationRegistry` rules for tool families.
- Supply `timelineBuilder` or `composerBuilder` to wrap or replace either region.
- Use `ChatPlatformScope` to override file picking, image loading, path resolution and working-directory display.
- Supply `readClipboardImage` to enable your host's image clipboard. No application-specific native channel is required.
- Use `ChatTimeline` and `PromptInput` independently when your host owns layout.

### Mermaid rendering

Assistant messages render fenced `mermaid` blocks through the shared timeline.
For an independent diagram, import the package's Mermaid entry point:

```dart
import 'package:ianvs_agent_chat/mermaid/mermaid.dart';

MermaidView(source: 'flowchart TD\nA --> B');
```

The default renderer uses native `package:merman` through Dart FFI and displays
SVG with `flutter_svg`. `MermaidRenderOptions.flutterSvgDefault` selects the
`resvg-safe` SVG profile. CSS normalization inlines supported Mermaid style
rules before display so unsupported SVG style blocks do not cause black fills.
The in-memory LRU cache is keyed by source, options JSON, and engine version.

Use `NativeMermanRenderer` to reuse an engine instance, `MermaidController` for
live render state, and the renderer's `layoutJson()` for node/edge geometry.
Apply the macOS integration below before relying on native rendering.

### macOS native rendering

The bundled Mermaid renderer currently uses Merman's CocoaPods library on macOS. The example disables Swift Package Manager to avoid Merman 0.7.0's missing SPM artifact. Set this in a macOS host's pubspec before building:

```yaml
flutter:
  config:
    enable-swift-package-manager: false
```

Merman 0.7.0 also contains an absolute dylib install name. The example includes
`macos/scripts/normalize_merman.sh` and a final Runner build phase to normalize
the bundled library references and sign the modified library. Existing macOS
hosts should copy that script and add a **Run Script** phase after **Embed Pods
Frameworks**, using `"${SRCROOT}/scripts/normalize_merman.sh"`. Set the macOS
deployment target to 12.0 or later. The example also raises older CocoaPods
deployment targets to 12.0 for current Xcode. Without this workaround, compilation can
succeed but launching the app can fail. The example is a complete reference
for these native settings.

The shared input defaults to Flutter semantics, including on macOS. Only a host
that registers `com.ianvs.acp/accessible-text-field` should wrap its application
in `ChatNativeTextFieldScope`. The standalone example and ordinary consumers do
not need that platform view. A supplied composer controller focuses the actual
editable field.

Markdown uses `ianvs_markdown`'s standard GFM preset, built-in typography, colors,
code blocks and file-link chips. The renderer resolves its own light/dark palette
or an ambient `IanvsMarkdownThemeData` extension; `ChatTheme` does not override
Markdown styling. Chat retains blocked resource images with link copying and
connects Mermaid through `diagramBuilder`. It keeps
block-level selection (`documentSelection: false`); full document copy remains a
host action. Obsidian comment/block-ID normalization and HTML form controls are
not enabled. Both preflight and rendering use the same syntax/fallback limits.
The Markdown dependency also brings `super_native_extensions`; validate the
complete native dependency graph in the consuming application.

The standard file picker requires the appropriate user-selected file entitlement; API calls require the network-client entitlement. The example includes both.

## Example and validation

```sh
cd example
flutter pub get
flutter run -d macos
```

The offline demo exercises tool approval and streaming. The **LLM API** tab accepts your endpoint, model and API key. Its optional `current_time` tool reads the local clock after approval.

```sh
flutter analyze
flutter test
```

Implementation references: [OpenAI Chat Completions](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create), [DeepSeek Chat Completions](https://api-docs.deepseek.com/api/create-chat-completion/).

## License

Apache-2.0.
