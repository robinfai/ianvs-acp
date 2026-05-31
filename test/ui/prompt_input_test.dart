import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/acp_agent_capabilities.dart';
import 'package:ianvs_acp/acp/acp_permission_request.dart';
import 'package:ianvs_acp/acp/acp_session_settings.dart';
import 'package:ianvs_acp/acp/prompt_attachment.dart';
import 'package:ianvs_acp/ui/components/prompt_input.dart';

void main() {
  Widget input({
    required bool isSending,
    required PromptSendCallback onSend,
    bool enabled = true,
    VoidCallback? onStop,
    String agentName = 'Codex',
    List<Map<String, Object?>> availableCommands =
        const <Map<String, Object?>>[],
    AcpPromptCapabilities? promptCapabilities,
    AcpPermissionRequest? pendingPermissionRequest,
    VoidCallback? onAllowPermission,
    VoidCallback? onDenyPermission,
    VoidCallback? onCancelPermission,
    AcpToolCallExecutionPolicy toolCallExecutionPolicy =
        AcpToolCallExecutionPolicy.autoReview,
    bool hasPermissionReviewer = false,
    ValueChanged<AcpToolCallExecutionPolicy>? onToolCallExecutionPolicyChanged,
    AcpConfigOption? modelOption,
    ValueChanged<String>? onModelSelected,
    PromptAttachmentPicker? pickAttachments,
    double? width,
  }) {
    final promptInput = PromptInput(
      agentName: agentName,
      enabled: enabled,
      isSending: isSending,
      availableCommands: availableCommands,
      promptCapabilities: promptCapabilities,
      pendingPermissionRequest: pendingPermissionRequest,
      onAllowPermission: onAllowPermission,
      onDenyPermission: onDenyPermission,
      onCancelPermission: onCancelPermission,
      toolCallExecutionPolicy: toolCallExecutionPolicy,
      hasPermissionReviewer: hasPermissionReviewer,
      onToolCallExecutionPolicyChanged: onToolCallExecutionPolicyChanged,
      modelOption: modelOption,
      onModelSelected: onModelSelected,
      onSend: onSend,
      onStop: onStop ?? () {},
      pickAttachments: pickAttachments,
    );
    return MaterialApp(
      home: Scaffold(
        body: width == null
            ? promptInput
            : Align(
                alignment: Alignment.topLeft,
                child: SizedBox(width: width, child: promptInput),
              ),
      ),
    );
  }

  Finder sendIcon() => find.byIcon(Icons.arrow_upward_rounded);
  Finder stopIcon() => find.byIcon(Icons.stop_rounded);
  Finder primaryAction() => find.byKey(const Key('prompt-action-button'));
  Finder attachFinder() => find.byTooltip('Attach file');
  FilledButton actionButton(WidgetTester tester, Finder iconFinder) {
    return tester.widget<FilledButton>(
      find.ancestor(of: iconFinder, matching: find.byType(FilledButton)),
    );
  }

  testWidgets('PromptInput empty input cannot send', (tester) async {
    var sent = false;
    await tester.pumpWidget(
      input(isSending: false, onSend: (_, _) => sent = true),
    );

    final sendButton = actionButton(tester, sendIcon());
    expect(sendButton.onPressed, isNull);

    await tester.tap(sendIcon());
    await tester.pump();
    expect(sent, isFalse);
  });

  testWidgets('PromptInput renders custom agent name in placeholder', (
    tester,
  ) async {
    await tester.pumpWidget(
      input(agentName: 'Kimi Code Dev', isSending: false, onSend: (_, _) {}),
    );

    expect(find.text('Send a prompt to Kimi Code Dev...'), findsOneWidget);
  });

  testWidgets('PromptInput input after typing can send', (tester) async {
    String? sentText;
    await tester.pumpWidget(
      input(isSending: false, onSend: (text, _) => sentText = text),
    );

    await tester.enterText(find.byType(TextField), 'Hello Codex');
    await tester.pump();

    final sendButton = actionButton(tester, sendIcon());
    expect(sendButton.onPressed, isNotNull);

    await tester.tap(sendIcon());
    await tester.pump();
    expect(sentText, 'Hello Codex');
  });

  testWidgets('PromptInput preserves multiline prompts', (tester) async {
    String? sentText;
    await tester.pumpWidget(
      input(isSending: false, onSend: (text, _) => sentText = text),
    );

    await tester.enterText(find.byType(TextField), 'Line one\nLine two');
    await tester.pump();
    await tester.tap(sendIcon());
    await tester.pump();

    expect(sentText, 'Line one\nLine two');
  });

  testWidgets('PromptInput suggests and inserts slash commands', (
    tester,
  ) async {
    await tester.pumpWidget(
      input(
        isSending: false,
        onSend: (_, _) {},
        availableCommands: const [
          {'name': 'review', 'description': 'Review the current change.'},
          {'name': 'summarize', 'description': 'Summarize the session.'},
        ],
      ),
    );

    await tester.enterText(find.byType(TextField), '/rev');
    await tester.pump();

    expect(find.text('/review'), findsOneWidget);
    expect(find.text('Review the current change.'), findsOneWidget);
    expect(find.text('/summarize'), findsNothing);

    await tester.tap(find.text('/review'));
    await tester.pump();

    final textField = tester.widget<TextField>(find.byType(TextField));
    expect(textField.controller?.text, '/review ');
    expect(find.text('Review the current change.'), findsNothing);
  });

  testWidgets('PromptInput hides slash commands while sending', (tester) async {
    await tester.pumpWidget(
      input(
        isSending: true,
        onSend: (_, _) {},
        availableCommands: const [
          {'name': 'review', 'description': 'Review the current change.'},
        ],
      ),
    );

    expect(find.text('/review'), findsNothing);
  });

  testWidgets('PromptInput sending state switches action button to Stop', (
    tester,
  ) async {
    var stopped = false;
    await tester.pumpWidget(
      input(isSending: true, onSend: (_, _) {}, onStop: () => stopped = true),
    );

    expect(sendIcon(), findsNothing);
    expect(primaryAction(), findsOneWidget);
    final stopButton = actionButton(tester, stopIcon());
    expect(stopButton.onPressed, isNotNull);

    await tester.tap(stopIcon());
    await tester.pump();
    expect(stopped, isTrue);
  });

  testWidgets('PromptInput idle state shows one disabled Send action', (
    tester,
  ) async {
    await tester.pumpWidget(input(isSending: false, onSend: (_, _) {}));

    expect(stopIcon(), findsNothing);
    expect(primaryAction(), findsOneWidget);
    final sendButton = actionButton(tester, sendIcon());
    expect(sendButton.onPressed, isNull);
  });

  testWidgets('PromptInput disabled state preserves draft text', (
    tester,
  ) async {
    var sent = false;
    await tester.pumpWidget(
      input(isSending: false, onSend: (_, _) => sent = true),
    );

    await tester.enterText(find.byType(TextField), 'Keep this draft');
    await tester.pump();

    await tester.pumpWidget(
      input(enabled: false, isSending: false, onSend: (_, _) => sent = true),
    );

    final textField = tester.widget<TextField>(find.byType(TextField));
    final attachButton = tester.widget<IconButton>(
      find.ancestor(of: attachFinder(), matching: find.byType(IconButton)),
    );
    final sendButton = actionButton(tester, sendIcon());

    expect(textField.enabled, isFalse);
    expect(textField.controller?.text, 'Keep this draft');
    expect(sendButton.onPressed, isNull);
    expect(attachButton.onPressed, isNull);

    await tester.tap(sendIcon());
    await tester.pump();

    expect(sent, isFalse);
    expect(textField.controller?.text, 'Keep this draft');
  });

  testWidgets('PromptInput attaches files and sends without text', (
    tester,
  ) async {
    List<PromptAttachment>? sentAttachments;
    const attachment = PromptAttachment(
      path: '/workspace/readme.md',
      name: 'readme.md',
      mimeType: 'text/markdown',
      size: 2048,
    );

    await tester.pumpWidget(
      input(
        isSending: false,
        onSend: (_, attachments) => sentAttachments = attachments,
        pickAttachments: () async => const [attachment],
      ),
    );

    await tester.tap(attachFinder());
    await tester.pump();

    expect(find.text('readme.md'), findsOneWidget);
    expect(find.text('2.0 KB'), findsOneWidget);

    final sendButton = actionButton(tester, sendIcon());
    expect(sendButton.onPressed, isNotNull);

    await tester.tap(sendIcon());
    await tester.pump();

    expect(sentAttachments, [attachment]);
    expect(find.text('readme.md'), findsNothing);
  });

  testWidgets('PromptInput ignores picker results after sending starts', (
    tester,
  ) async {
    var sent = false;
    final pickerStarted = Completer<void>();
    final pickerResult = Completer<List<PromptAttachment>>();
    const attachment = PromptAttachment(
      path: '/workspace/readme.md',
      name: 'readme.md',
      mimeType: 'text/markdown',
      size: 2048,
    );

    Future<List<PromptAttachment>> pickAttachments() async {
      pickerStarted.complete();
      return pickerResult.future;
    }

    await tester.pumpWidget(
      input(
        isSending: false,
        onSend: (_, _) => sent = true,
        pickAttachments: pickAttachments,
      ),
    );

    await tester.tap(attachFinder());
    await tester.pump();
    expect(pickerStarted.isCompleted, isTrue);

    await tester.pumpWidget(
      input(
        isSending: true,
        onSend: (_, _) => sent = true,
        pickAttachments: pickAttachments,
      ),
    );
    pickerResult.complete(const [attachment]);
    await tester.pump();

    expect(find.text('readme.md'), findsNothing);
    expect(sendIcon(), findsNothing);
    final stopButton = actionButton(tester, stopIcon());
    expect(stopButton.onPressed, isNotNull);
    expect(sent, isFalse);
  });

  testWidgets('PromptInput marks attachments by prompt capability mode', (
    tester,
  ) async {
    const readme = PromptAttachment(
      path: '/workspace/readme.md',
      name: 'readme.md',
      mimeType: 'text/markdown',
    );
    const screenshot = PromptAttachment(
      path: '/workspace/screenshot.png',
      name: 'screenshot.png',
      mimeType: 'image/png',
    );

    await tester.pumpWidget(
      input(
        isSending: false,
        onSend: (_, _) {},
        promptCapabilities: const AcpPromptCapabilities(
          image: false,
          audio: false,
          embeddedContext: true,
        ),
        pickAttachments: () async => const [readme, screenshot],
      ),
    );

    await tester.tap(attachFinder());
    await tester.pump();

    expect(find.text('readme.md'), findsOneWidget);
    expect(find.text('screenshot.png'), findsOneWidget);
    expect(find.text('Embed'), findsOneWidget);
    expect(find.text('Link'), findsOneWidget);
  });

  testWidgets('PromptInput can remove an attachment before sending', (
    tester,
  ) async {
    var sent = false;
    const attachment = PromptAttachment(
      path: '/workspace/readme.md',
      name: 'readme.md',
    );

    await tester.pumpWidget(
      input(
        isSending: false,
        onSend: (_, _) => sent = true,
        pickAttachments: () async => const [attachment],
      ),
    );

    await tester.tap(attachFinder());
    await tester.pump();
    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pump();

    expect(find.text('readme.md'), findsNothing);
    await tester.tap(sendIcon());
    await tester.pump();
    expect(sent, isFalse);
  });

  testWidgets('PromptInput renders permission request inside composer', (
    tester,
  ) async {
    var allowed = false;
    await tester.pumpWidget(
      input(
        isSending: false,
        onSend: (_, _) {},
        pendingPermissionRequest: AcpPermissionRequest(
          id: 'permission-1',
          title: 'Read file',
          rationale: 'Requested by agent',
          sessionId: 'session-1',
          toolName: 'read_text_file',
          toolKind: 'read',
          options: const ['Allow', 'Deny'],
          requestedAt: DateTime(2026, 5, 31, 12),
        ),
        onAllowPermission: () => allowed = true,
      ),
    );

    expect(find.text('等待 Tool Call 权限确认'), findsOneWidget);
    expect(find.text('需要处理'), findsOneWidget);
    expect(find.text('Tool Call 待确认'), findsOneWidget);
    expect(find.text('Read file'), findsOneWidget);
    expect(find.text('Allow Once'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('prompt-input-surface')),
        matching: find.byKey(const Key('prompt-permission-card')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('prompt-input-surface')),
        matching: find.byKey(const Key('prompt-permission-service-chip')),
      ),
      findsOneWidget,
    );
    expect(
      tester.getTopLeft(find.byKey(const Key('prompt-permission-card'))).dy,
      lessThan(tester.getTopLeft(find.byType(TextField)).dy),
    );
    expect(
      tester
          .getTopLeft(find.byKey(const Key('prompt-permission-service-chip')))
          .dy,
      greaterThan(tester.getTopLeft(find.byType(TextField)).dy),
    );

    final surface = tester.widget<Container>(
      find.byKey(const Key('prompt-input-surface')),
    );
    final decoration = surface.decoration as BoxDecoration;
    final border = decoration.border as Border;
    expect(decoration.color, const Color(0xfffffbeb));
    expect(border.top.color, const Color(0xffea580c));
    expect(border.top.width, 2.4);

    await tester.tap(find.widgetWithText(FilledButton, 'Allow Once'));
    await tester.pump();
    expect(allowed, isTrue);
  });

  testWidgets('PromptInput keeps permission actions usable in narrow widths', (
    tester,
  ) async {
    var denied = false;
    await tester.pumpWidget(
      input(
        width: 320,
        isSending: false,
        onSend: (_, _) {},
        pendingPermissionRequest: AcpPermissionRequest(
          id: 'permission-1',
          title: 'Read workspace file',
          rationale: 'The agent needs a local file before continuing',
          sessionId: 'session-1',
          toolName: 'read_text_file',
          toolKind: 'read',
          options: const ['Allow', 'Deny'],
          requestedAt: DateTime(2026, 5, 31, 12),
        ),
        onDenyPermission: () => denied = true,
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('prompt-permission-card')), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Deny'), findsOneWidget);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Deny'));
    await tester.pump();
    expect(denied, isTrue);
  });

  testWidgets('PromptInput changes tool call execution policy', (tester) async {
    AcpToolCallExecutionPolicy? selected;
    await tester.pumpWidget(
      input(
        isSending: false,
        onSend: (_, _) {},
        onToolCallExecutionPolicyChanged: (policy) => selected = policy,
      ),
    );

    expect(find.text('自动审查'), findsOneWidget);
    await tester.tap(find.text('自动审查'));
    await tester.pumpAndSettle();
    expect(find.text('默认权限'), findsOneWidget);
    expect(find.text('完全访问权限'), findsOneWidget);
    expect(find.text('所有请求都由你确认'), findsOneWidget);
    expect(find.text('使用信任规则，未命中时再确认'), findsOneWidget);
    expect(find.text('自动允许所有 tool call'), findsOneWidget);

    await tester.tap(find.text('完全访问权限'));
    await tester.pumpAndSettle();

    expect(selected, AcpToolCallExecutionPolicy.fullAccess);
  });

  testWidgets('PromptInput describes sidecar reviewer when configured', (
    tester,
  ) async {
    await tester.pumpWidget(
      input(
        isSending: false,
        onSend: (_, _) {},
        hasPermissionReviewer: true,
        onToolCallExecutionPolicyChanged: (_) {},
      ),
    );

    await tester.tap(find.text('自动审查'));
    await tester.pumpAndSettle();

    expect(find.text('旁路 agent 审查，未决时再确认'), findsOneWidget);
  });

  testWidgets('PromptInput changes exposed model option', (tester) async {
    String? selectedModel;
    await tester.pumpWidget(
      input(
        isSending: false,
        onSend: (_, _) {},
        modelOption: const AcpConfigOption(
          id: 'model',
          name: 'Model',
          type: 'select',
          currentValue: 'gpt-5',
          options: [
            AcpConfigOptionChoice(value: 'gpt-5', name: 'GPT-5'),
            AcpConfigOptionChoice(value: 'mini', name: 'GPT-5 Mini'),
          ],
        ),
        onModelSelected: (value) => selectedModel = value,
      ),
    );

    expect(find.text('GPT-5'), findsOneWidget);
    await tester.tap(find.text('GPT-5'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('GPT-5 Mini'));
    await tester.pumpAndSettle();

    expect(selectedModel, 'mini');
  });

  testWidgets('PromptInput hides model selector without choices', (
    tester,
  ) async {
    await tester.pumpWidget(
      input(isSending: false, onSend: (_, _) {}, onModelSelected: (_) {}),
    );

    expect(find.text('Model'), findsNothing);

    await tester.pumpWidget(
      input(
        isSending: false,
        onSend: (_, _) {},
        modelOption: const AcpConfigOption(
          id: 'model',
          name: 'Model',
          type: 'select',
          currentValue: 'gpt-5',
          options: [],
        ),
        onModelSelected: (_) {},
      ),
    );

    expect(find.text('Model'), findsNothing);
  });

  testWidgets('PromptInput wraps composer controls in narrow widths', (
    tester,
  ) async {
    await tester.pumpWidget(
      input(
        width: 320,
        isSending: false,
        onSend: (_, _) {},
        toolCallExecutionPolicy: AcpToolCallExecutionPolicy.fullAccess,
        onToolCallExecutionPolicyChanged: (_) {},
        modelOption: const AcpConfigOption(
          id: 'model',
          name: 'Model',
          type: 'select',
          currentValue: 'long-model',
          options: [
            AcpConfigOptionChoice(
              value: 'long-model',
              name: 'GPT-5 Super Extended Reasoning',
            ),
          ],
        ),
        onModelSelected: (_) {},
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('完全访问权限'), findsOneWidget);
    expect(find.text('GPT-5 Super Extended Reasoning'), findsOneWidget);
    expect(sendIcon(), findsOneWidget);
  });
}
