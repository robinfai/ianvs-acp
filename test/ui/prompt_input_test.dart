import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:ianvs_acp/acp/acp_input_budget.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/acp_agent_capabilities.dart';
import 'package:ianvs_acp/acp/acp_permission_request.dart';
import 'package:ianvs_acp/acp/acp_session_settings.dart';
import 'package:ianvs_acp/acp/prompt_attachment.dart';
import 'package:ianvs_acp/ui/components/prompt_input.dart';
import 'package:ianvs_acp/ui/theme/app_design_tokens.dart';

void main() {
  Widget input({
    required bool isSending,
    required PromptSendCallback onSend,
    bool enabled = true,
    VoidCallback? onStop,
    String agentName = 'Codex',
    List<Map<String, Object?>> availableCommands =
        const <Map<String, Object?>>[],
    int availableCommandsRevision = 0,
    AcpPromptCapabilities? promptCapabilities,
    AcpPermissionRequest? pendingPermissionRequest,
    VoidCallback? onAllowPermission,
    VoidCallback? onDenyPermission,
    VoidCallback? onCancelPermission,
    ValueChanged<String>? onSelectPermissionOption,
    AcpToolCallExecutionPolicy toolCallExecutionPolicy =
        AcpToolCallExecutionPolicy.autoReview,
    bool hasPermissionReviewer = false,
    ValueChanged<AcpToolCallExecutionPolicy>? onToolCallExecutionPolicyChanged,
    AcpConfigOption? modelOption,
    AcpConfigOption? reasoningEffortOption,
    ValueChanged<String>? onModelSelected,
    ValueChanged<String>? onReasoningEffortSelected,
    PromptAttachmentPicker? pickAttachments,
    PromptAttachmentKindPicker? pickAttachmentsForKind,
    double? width,
    AcpInputBudget inputBudget = const AcpInputBudget(),
  }) {
    final promptInput = PromptInput(
      agentName: agentName,
      enabled: enabled,
      isSending: isSending,
      availableCommands: availableCommands,
      availableCommandsRevision: availableCommandsRevision,
      promptCapabilities: promptCapabilities,
      pendingPermissionRequest: pendingPermissionRequest,
      onAllowPermission: onAllowPermission,
      onDenyPermission: onDenyPermission,
      onCancelPermission: onCancelPermission,
      onSelectPermissionOption: onSelectPermissionOption,
      toolCallExecutionPolicy: toolCallExecutionPolicy,
      hasPermissionReviewer: hasPermissionReviewer,
      onToolCallExecutionPolicyChanged: onToolCallExecutionPolicyChanged,
      modelOption: modelOption,
      reasoningEffortOption: reasoningEffortOption,
      onModelSelected: onModelSelected,
      onReasoningEffortSelected: onReasoningEffortSelected,
      onSend: onSend,
      onStop: onStop ?? () {},
      pickAttachments: pickAttachments,
      pickAttachmentsForKind: pickAttachmentsForKind,
      inputBudget: inputBudget,
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
  Finder attachFinder() => find.byKey(const Key('prompt-attachment-picker'));
  DropTarget dropTarget(WidgetTester tester) => tester.widget<DropTarget>(
    find.byKey(const Key('prompt-input-drop-target')),
  );
  DropEventDetails dragDetails() => DropEventDetails(
    localPosition: const Offset(12, 12),
    globalPosition: const Offset(12, 12),
  );
  DropDoneDetails dropDetails(List<DropItem> files) => DropDoneDetails(
    files: files,
    localPosition: const Offset(12, 12),
    globalPosition: const Offset(12, 12),
  );
  Future<void> sendNativeDropMethod(String method, Object? arguments) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          'desktop_drop',
          const StandardMethodCodec().encodeMethodCall(
            MethodCall(method, arguments),
          ),
          (_) {},
        );
  }

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

  testWidgets('PromptInput bounds command parameters with injected budget', (
    tester,
  ) async {
    const budget = AcpInputBudget(
      maxMetadataPreviewChars: 20,
      maxMetadataPreviewBytes: 12,
    );
    await tester.pumpWidget(
      input(
        isSending: false,
        onSend: (_, _) {},
        inputBudget: budget,
        availableCommands: const [
          {
            'name': 'review',
            'description': 'Review.',
            'parameters': {'secret': 'PARAMETER_CANARY'},
          },
        ],
      ),
    );

    await tester.enterText(find.byType(TextField), '/rev');
    await tester.pump();

    final preview = tester.widget<SelectableText>(
      find.byKey(const Key('command-parameters-preview')),
    );
    expect(utf8.encode(preview.data ?? '').length, lessThanOrEqualTo(12));
    expect(preview.data, isNot(contains('PARAMETER_CANARY')));
    expect(find.textContaining('metadata preview bytes'), findsOneWidget);
  });

  testWidgets(
    'PromptInput reuses command projections for the same list and revision',
    (tester) async {
      final parameters = _CountingCommandMap(<String, Object?>{
        'scope': 'working-tree',
      });
      final command = _CountingCommandMap(<String, Object?>{
        'name': 'Review',
        'description': 'Review the current change.',
        'parameters': parameters,
      });
      final commands = <Map<String, Object?>>[command];

      await tester.pumpWidget(
        input(
          isSending: false,
          onSend: (_, _) {},
          availableCommands: commands,
          availableCommandsRevision: 7,
        ),
      );
      expect(command.readsFor('name'), 1);
      expect(command.readsFor('description'), 1);
      expect(command.readsFor('parameters'), 0);
      expect(parameters.readsFor('scope'), 0);

      await tester.enterText(find.byType(TextField), '/r');
      await tester.pump();
      await tester.enterText(find.byType(TextField), '/re');
      await tester.pump();
      await tester.enterText(find.byType(TextField), '/rev');
      await tester.pump();

      expect(find.text('/Review'), findsOneWidget);
      expect(find.text('Review the current change.'), findsOneWidget);
      expect(command.readsFor('name'), 1);
      expect(command.readsFor('description'), 1);
      expect(command.readsFor('parameters'), 1);
      expect(parameters.readsFor('scope'), 1);

      await tester.pumpWidget(
        input(
          isSending: false,
          onSend: (_, _) {},
          availableCommands: commands,
          availableCommandsRevision: 7,
        ),
      );
      await tester.pump();

      expect(command.readsFor('name'), 1);
      expect(command.readsFor('description'), 1);
      expect(command.readsFor('parameters'), 1);
      expect(parameters.readsFor('scope'), 1);
    },
  );

  testWidgets(
    'PromptInput rebuilds command projections once when revision changes',
    (tester) async {
      final command = _CountingCommandMap(<String, Object?>{
        'name': 'Review',
        'description': 'First description.',
        'parameters': <String, Object?>{'scope': 'first'},
      });
      final commands = <Map<String, Object?>>[command];

      await tester.pumpWidget(
        input(
          isSending: false,
          onSend: (_, _) {},
          availableCommands: commands,
          availableCommandsRevision: 3,
        ),
      );
      expect(command.readsFor('name'), 1);
      expect(command.readsFor('description'), 1);
      expect(command.readsFor('parameters'), 0);

      command['description'] = 'Second description.';
      command['parameters'] = <String, Object?>{'scope': 'second'};
      await tester.pumpWidget(
        input(
          isSending: false,
          onSend: (_, _) {},
          availableCommands: commands,
          availableCommandsRevision: 4,
        ),
      );
      await tester.enterText(find.byType(TextField), '/rev');
      await tester.pump();

      expect(find.text('Second description.'), findsOneWidget);
      expect(command.readsFor('name'), 2);
      expect(command.readsFor('description'), 2);
      expect(command.readsFor('parameters'), 1);
    },
  );

  testWidgets('PromptInput retains at most five lazy parameter previews', (
    tester,
  ) async {
    final alphaParameters = <_CountingCommandMap>[];
    final betaParameters = <_CountingCommandMap>[];
    final commands = <Map<String, Object?>>[];
    for (var index = 0; index < 5; index += 1) {
      final parameters = _CountingCommandMap(<String, Object?>{
        'scope': 'alpha-$index',
      });
      alphaParameters.add(parameters);
      commands.add(<String, Object?>{
        'name': 'alpha$index',
        'description': 'Alpha $index',
        'parameters': parameters,
      });
    }
    for (var index = 0; index < 5; index += 1) {
      final parameters = _CountingCommandMap(<String, Object?>{
        'scope': 'beta-$index',
      });
      betaParameters.add(parameters);
      commands.add(<String, Object?>{
        'name': 'beta$index',
        'description': 'Beta $index',
        'parameters': parameters,
      });
    }

    await tester.pumpWidget(
      input(isSending: false, onSend: (_, _) {}, availableCommands: commands),
    );
    for (final parameters in [...alphaParameters, ...betaParameters]) {
      expect(parameters.readsFor('scope'), 0);
    }

    await tester.enterText(find.byType(TextField), '/alpha');
    await tester.pump();
    for (final parameters in alphaParameters) {
      expect(parameters.readsFor('scope'), 1);
    }
    for (final parameters in betaParameters) {
      expect(parameters.readsFor('scope'), 0);
    }

    await tester.enterText(find.byType(TextField), '/beta');
    await tester.pump();
    for (final parameters in betaParameters) {
      expect(parameters.readsFor('scope'), 1);
    }

    await tester.enterText(find.byType(TextField), '/alpha');
    await tester.pump();
    for (final parameters in alphaParameters) {
      expect(parameters.readsFor('scope'), 2);
    }

    await tester.enterText(find.byType(TextField), '/alpha0');
    await tester.pump();
    expect(alphaParameters.first.readsFor('scope'), 2);
  });

  testWidgets('PromptInput hides a hostile parameter preview payload', (
    tester,
  ) async {
    final command = _CountingCommandMap(
      <String, Object?>{
        'name': 'review',
        'description': 'Review safely.',
        'parameters': <String, Object?>{'secret': 'CANARY'},
      },
      throwingKeys: const <String>{'parameters'},
    );

    await tester.pumpWidget(
      input(
        isSending: false,
        onSend: (_, _) {},
        availableCommands: <Map<String, Object?>>[command],
      ),
    );
    expect(command.readsFor('parameters'), 0);

    await tester.enterText(find.byType(TextField), '/rev');
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('Review safely.'), findsOneWidget);
    expect(find.byKey(const Key('command-parameters-preview')), findsNothing);
    expect(find.textContaining('CANARY'), findsNothing);
    expect(command.readsFor('parameters'), 1);

    await tester.enterText(find.byType(TextField), '/revi');
    await tester.pump();
    expect(command.readsFor('parameters'), 1);
  });

  testWidgets('PromptInput snapshots a command list length exactly once', (
    tester,
  ) async {
    final commands = _CountingCommandList(<Map<String, Object?>>[
      <String, Object?>{'name': 'review', 'description': 'Review.'},
    ]);

    await tester.pumpWidget(
      input(isSending: false, onSend: (_, _) {}, availableCommands: commands),
    );
    await tester.enterText(find.byType(TextField), '/rev');
    await tester.pump();

    expect(commands.lengthReads, 1);
    expect(find.text('/review'), findsOneWidget);
  });

  testWidgets(
    'PromptInput clears old cache when a rebuilt command source is hostile',
    (tester) async {
      await tester.pumpWidget(
        input(
          isSending: false,
          onSend: (_, _) {},
          availableCommands: <Map<String, Object?>>[
            <String, Object?>{
              'name': 'safe',
              'description': 'Old safe command.',
            },
          ],
          availableCommandsRevision: 1,
        ),
      );
      await tester.enterText(find.byType(TextField), '/safe');
      await tester.pump();
      expect(find.text('Old safe command.'), findsOneWidget);

      final hostileSources = <List<Map<String, Object?>>>[
        _CountingCommandList(
          const <Map<String, Object?>>[],
          throwOnLength: true,
        ),
        _CountingCommandList(<Map<String, Object?>>[
          <String, Object?>{'name': 'unreachable'},
        ], throwOnIndex: true),
        <Map<String, Object?>>[
          _CountingCommandMap(
            <String, Object?>{'name': 'hidden'},
            throwingKeys: const <String>{'name'},
          ),
        ],
        <Map<String, Object?>>[
          _CountingCommandMap(
            <String, Object?>{
              'name': 'hidden',
              'description': 'never retained',
            },
            throwingKeys: const <String>{'description'},
          ),
        ],
      ];

      for (var index = 0; index < hostileSources.length; index += 1) {
        await tester.pumpWidget(
          input(
            isSending: false,
            onSend: (_, _) {},
            availableCommands: hostileSources[index],
            availableCommandsRevision: index + 2,
          ),
        );
        await tester.pump();

        expect(tester.takeException(), isNull);
        expect(find.text('Old safe command.'), findsNothing);
      }
    },
  );

  testWidgets('PromptInput scans at most 1024 commands and displays five', (
    tester,
  ) async {
    final counted = List<_CountingCommandMap>.generate(
      1025,
      (index) => _CountingCommandMap(<String, Object?>{
        'name': 'command-${index.toString().padLeft(4, '0')}',
        'description': 'Description $index',
      }),
    );
    final commands = counted.cast<Map<String, Object?>>();

    await tester.pumpWidget(
      input(isSending: false, onSend: (_, _) {}, availableCommands: commands),
    );
    await tester.enterText(find.byType(TextField), '/');
    await tester.pump();

    expect(find.text('/command-0000'), findsOneWidget);
    expect(find.text('/command-0005'), findsNothing);
    final panel = tester.widget<ListView>(find.byType(ListView));
    expect(
      (panel.childrenDelegate as SliverChildBuilderDelegate).childCount,
      9,
    );
    expect(counted[1023].readsFor('name'), 1);
    expect(counted[1024].readsFor('name'), 0);
    expect(counted[1024].readsFor('description'), 0);
    expect(counted[1024].readsFor('parameters'), 0);
    expect(counted[1023].readsFor('parameters'), 0);
  });

  testWidgets('PromptInput hides an unfinished query beyond 1024 code units', (
    tester,
  ) async {
    final commandName = ''.padLeft(1024, 'a');
    await tester.pumpWidget(
      input(
        isSending: false,
        onSend: (_, _) {},
        availableCommands: <Map<String, Object?>>[
          <String, Object?>{
            'name': commandName,
            'description': 'Boundary command.',
          },
        ],
      ),
    );

    await tester.enterText(find.byType(TextField), '/${''.padLeft(1023, 'a')}');
    await tester.pump();
    expect(find.text('Boundary command.'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '/${''.padLeft(1024, 'a')}');
    await tester.pump();
    expect(find.text('Boundary command.'), findsNothing);
  });

  testWidgets(
    'PromptInput bounds Unicode whitespace and multi-megabyte paste',
    (tester) async {
      await tester.pumpWidget(
        input(
          isSending: false,
          onSend: (_, _) {},
          availableCommands: const <Map<String, Object?>>[
            <String, Object?>{
              'name': 'review',
              'description': 'Unicode-safe command.',
            },
          ],
        ),
      );

      await tester.enterText(find.byType(TextField), '\u3000/rev');
      await tester.pump();
      expect(find.text('Unicode-safe command.'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '/rev\u00a0argument');
      await tester.pump();
      expect(find.text('Unicode-safe command.'), findsNothing);

      final pasted = '/${''.padLeft(4 * 1024 * 1024, 'r')}';
      final stopwatch = Stopwatch()..start();
      tester.widget<TextField>(find.byType(TextField)).onChanged!(pasted);
      stopwatch.stop();
      await tester.pump();

      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
      expect(tester.takeException(), isNull);
      expect(find.text('Unicode-safe command.'), findsNothing);
    },
  );

  testWidgets('PromptInput query cap honors the injected structured limit', (
    tester,
  ) async {
    const budget = AcpInputBudget(maxStructuredStringBytes: 8);
    await tester.pumpWidget(
      input(
        isSending: false,
        onSend: (_, _) {},
        inputBudget: budget,
        availableCommands: const <Map<String, Object?>>[
          <String, Object?>{
            'name': 'reviewxx',
            'description': 'Small-budget command.',
          },
        ],
      ),
    );

    await tester.enterText(find.byType(TextField), '/reviewx');
    await tester.pump();
    expect(find.text('Small-budget command.'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '/reviewxx');
    await tester.pump();
    expect(find.text('Small-budget command.'), findsNothing);
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

  testWidgets(
    'PromptInput attachment choices follow handshake prompt capabilities',
    (tester) async {
      const image = PromptAttachment(
        path: '/workspace/screenshot.png',
        name: 'screenshot.png',
        mimeType: 'image/png',
      );
      const audio = PromptAttachment(
        path: '/workspace/clip.wav',
        name: 'clip.wav',
        mimeType: 'audio/wav',
      );
      final pickedKinds = <PromptAttachmentKind>[];

      Future<List<PromptAttachment>> pick(PromptAttachmentKind kind) async {
        pickedKinds.add(kind);
        return switch (kind) {
          PromptAttachmentKind.image => const <PromptAttachment>[image],
          PromptAttachmentKind.audio => const <PromptAttachment>[audio],
          PromptAttachmentKind.file => const <PromptAttachment>[],
        };
      }

      await tester.pumpWidget(
        input(
          isSending: false,
          onSend: (_, _) {},
          promptCapabilities: const AcpPromptCapabilities(
            image: true,
            audio: false,
            embeddedContext: true,
          ),
          pickAttachmentsForKind: pick,
        ),
      );

      expect(find.byTooltip('Attach file or image'), findsOneWidget);
      await tester.tap(attachFinder());
      await tester.pumpAndSettle();

      expect(find.text('Add file'), findsOneWidget);
      expect(find.text('Add image'), findsOneWidget);
      expect(find.text('Add audio'), findsNothing);

      await tester.tap(find.text('Add image'));
      await tester.pumpAndSettle();

      expect(pickedKinds, <PromptAttachmentKind>[PromptAttachmentKind.image]);
      expect(find.text('screenshot.png'), findsOneWidget);
      expect(find.text('Image'), findsOneWidget);

      await tester.pumpWidget(
        input(
          isSending: false,
          onSend: (_, _) {},
          promptCapabilities: const AcpPromptCapabilities(
            image: false,
            audio: true,
            embeddedContext: false,
          ),
          pickAttachmentsForKind: pick,
        ),
      );
      await tester.pump();

      expect(find.byTooltip('Attach file or audio'), findsOneWidget);
      expect(find.text('Link'), findsOneWidget);
      expect(find.text('Image'), findsNothing);

      await tester.tap(attachFinder());
      await tester.pumpAndSettle();

      expect(find.text('Add file'), findsOneWidget);
      expect(find.text('Add image'), findsNothing);
      expect(find.text('Add audio'), findsOneWidget);

      await tester.tap(find.text('Add audio'));
      await tester.pumpAndSettle();

      expect(pickedKinds, <PromptAttachmentKind>[
        PromptAttachmentKind.image,
        PromptAttachmentKind.audio,
      ]);
      expect(find.text('clip.wav'), findsOneWidget);
      expect(find.text('Audio'), findsOneWidget);
    },
  );

  testWidgets('PromptInput drag and drop attaches files image and audio once', (
    tester,
  ) async {
    List<PromptAttachment>? sentAttachments;
    await tester.pumpWidget(
      input(
        isSending: false,
        onSend: (_, attachments) => sentAttachments = attachments,
        promptCapabilities: const AcpPromptCapabilities(
          image: true,
          audio: true,
          embeddedContext: true,
        ),
      ),
    );

    final target = dropTarget(tester);
    expect(target.enable, isTrue);
    target.onDragEntered!(dragDetails());
    await tester.pump();

    expect(
      find.byKey(const Key('prompt-attachment-drop-indicator')),
      findsOneWidget,
    );
    expect(find.text('Drop files, images or audio here'), findsOneWidget);

    target.onDragDone!(
      dropDetails(<DropItem>[
        DropItemFile(
          '/workspace/readme.md',
          name: 'readme.md',
          mimeType: 'text/markdown',
          length: 2048,
        ),
        DropItemFile(
          '/workspace/screenshot.png',
          name: 'screenshot.png',
          mimeType: 'image/png',
          length: 4096,
        ),
        DropItemFile(
          '/workspace/clip.wav',
          name: 'clip.wav',
          mimeType: 'audio/wav',
          length: 8192,
        ),
        DropItemFile(
          '/workspace/screenshot.png',
          name: 'duplicate.png',
          mimeType: 'image/png',
          length: 4096,
        ),
      ]),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('prompt-attachment-drop-indicator')),
      findsNothing,
    );
    expect(find.text('readme.md'), findsOneWidget);
    expect(find.text('screenshot.png'), findsOneWidget);
    expect(find.text('duplicate.png'), findsNothing);
    expect(find.text('clip.wav'), findsOneWidget);
    expect(find.text('Embed'), findsOneWidget);
    expect(find.text('Image'), findsOneWidget);
    expect(find.text('Audio'), findsOneWidget);

    await tester.tap(sendIcon());
    await tester.pump();

    expect(sentAttachments, hasLength(3));
    expect(sentAttachments!.map((attachment) => attachment.path), <String>[
      '/workspace/readme.md',
      '/workspace/screenshot.png',
      '/workspace/clip.wav',
    ]);
  });

  testWidgets('PromptInput accepts a native macOS drop channel event', (
    tester,
  ) async {
    await tester.pumpWidget(input(isSending: false, onSend: (_, _) {}));
    final dropPosition = tester.getCenter(
      find.byKey(const Key('prompt-input-surface')),
    );

    await sendNativeDropMethod('entered', <double>[
      dropPosition.dx,
      dropPosition.dy,
    ]);
    await tester.pump();
    expect(
      find.byKey(const Key('prompt-attachment-drop-indicator')),
      findsOneWidget,
    );

    await sendNativeDropMethod('performOperation_macos', <Object?>[
      <String, Object?>{
        'path': '/workspace/native-drop.md',
        'isDirectory': false,
        'fromPromise': false,
      },
    ]);
    await tester.pumpAndSettle();

    expect(find.text('native-drop.md'), findsOneWidget);
    expect(find.text('Link'), findsOneWidget);
    expect(
      find.byKey(const Key('prompt-attachment-drop-indicator')),
      findsNothing,
    );
  });

  testWidgets(
    'PromptInput dropped media follows unsupported capability fallback',
    (tester) async {
      await tester.pumpWidget(
        input(
          isSending: false,
          onSend: (_, _) {},
          promptCapabilities: const AcpPromptCapabilities(
            image: false,
            audio: false,
            embeddedContext: false,
          ),
        ),
      );

      final target = dropTarget(tester);
      target.onDragEntered!(dragDetails());
      await tester.pump();
      expect(find.text('Drop files here'), findsOneWidget);

      target.onDragDone!(
        dropDetails(<DropItem>[
          DropItemFile(
            '/workspace/screenshot.png',
            name: 'screenshot.png',
            mimeType: 'image/png',
            length: 4096,
          ),
        ]),
      );
      await tester.pumpAndSettle();

      expect(find.text('screenshot.png'), findsOneWidget);
      expect(find.text('Link'), findsOneWidget);
      expect(find.text('Image'), findsNothing);
    },
  );

  for (final state in <({bool enabled, bool isSending, String label})>[
    (enabled: false, isSending: false, label: 'disabled'),
    (enabled: true, isSending: true, label: 'sending'),
  ]) {
    testWidgets('PromptInput ignores drag and drop while ${state.label}', (
      tester,
    ) async {
      await tester.pumpWidget(
        input(
          enabled: state.enabled,
          isSending: state.isSending,
          onSend: (_, _) {},
        ),
      );

      final target = dropTarget(tester);
      expect(target.enable, isFalse);
      target.onDragEntered!(dragDetails());
      target.onDragDone!(
        dropDetails(<DropItem>[
          DropItemFile(
            '/workspace/ignored.md',
            name: 'ignored.md',
            mimeType: 'text/markdown',
            length: 32,
          ),
        ]),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('prompt-attachment-drop-indicator')),
        findsNothing,
      );
      expect(find.text('ignored.md'), findsNothing);
    });
  }

  testWidgets('PromptInput rejects dropped folders with guidance', (
    tester,
  ) async {
    await tester.pumpWidget(input(isSending: false, onSend: (_, _) {}));

    dropTarget(tester).onDragDone!(
      dropDetails(<DropItem>[
        DropItemDirectory('/workspace/folder', const <DropItem>[]),
      ]),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Folders cannot be attached. Drop individual files instead.'),
      findsOneWidget,
    );
    expect(actionButton(tester, sendIcon()).onPressed, isNull);
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

    final surface = tester.widget<AnimatedContainer>(
      find.byKey(const Key('prompt-input-surface')),
    );
    final decoration = surface.decoration as BoxDecoration;
    final border = decoration.border as Border;
    expect(decoration.color, AppColors.surface);
    expect(border.top.color, AppColors.border);
    expect(border.top.width, 1);

    await tester.tap(find.widgetWithText(FilledButton, 'Allow Once'));
    await tester.pump();
    expect(allowed, isTrue);
  });

  testWidgets('PromptInput shows complete permission operation context', (
    tester,
  ) async {
    await tester.pumpWidget(
      input(
        isSending: false,
        onSend: (_, _) {},
        pendingPermissionRequest: AcpPermissionRequest(
          id: 'permission-context',
          title: 'Run command',
          rationale: 'Requested by agent',
          sessionId: 'session-1',
          toolName: 'terminal',
          toolKind: 'execute',
          options: const ['Allow', 'Deny'],
          requestedAt: DateTime(2026, 7, 11, 12),
          metadata: const <String, Object?>{
            'command': 'git',
            'args': <String>['push', 'origin', 'main'],
            'cwd': '/workspace',
            'path': '/workspace/report.txt',
            'target': 'origin',
          },
        ),
      ),
    );

    expect(find.text('Command'), findsOneWidget);
    expect(find.text('["git","push","origin","main"]'), findsOneWidget);
    expect(find.text('Working directory'), findsOneWidget);
    expect(find.text('/workspace'), findsOneWidget);
    expect(find.text('Path'), findsOneWidget);
    expect(find.text('/workspace/report.txt'), findsOneWidget);
    expect(find.text('Target'), findsOneWidget);
    expect(find.text('origin'), findsOneWidget);
    expect(
      tester
          .widgetList<SelectableText>(
            find.descendant(
              of: find.byKey(const Key('prompt-permission-context')),
              matching: find.byType(SelectableText),
            ),
          )
          .map((widget) => widget.data),
      <String?>[
        '["git","push","origin","main"]',
        '/workspace',
        '/workspace/report.txt',
        'origin',
      ],
    );
    expect(
      find.byKey(const Key('prompt-permission-context-command')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('prompt-permission-context-cwd')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('prompt-permission-context-path')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('prompt-permission-context-target')),
      findsOneWidget,
    );
  });

  testWidgets('PromptInput renders only projected nested operation context', (
    tester,
  ) async {
    await tester.pumpWidget(
      input(
        isSending: false,
        onSend: (_, _) {},
        pendingPermissionRequest: AcpPermissionRequest(
          id: 'permission-nested-context',
          title: 'Run tests',
          rationale: 'Requested by agent',
          sessionId: 'session-1',
          toolName: 'terminal',
          toolKind: 'execute',
          options: const ['Allow', 'Deny'],
          requestedAt: DateTime(2026, 7, 11, 12),
          metadata: const <String, Object?>{
            'toolCall': <String, Object?>{
              'input': <String, Object?>{
                'command': 'flutter',
                'args': <String>['test', 'test/widget_test.dart'],
                'cwd': '/workspace/app',
                'path': 'test/widget_test.dart',
                'target': 'local',
                'unknownField': 'UNPROJECTED_CANARY',
              },
            },
          },
        ),
      ),
    );

    expect(
      find.text('["flutter","test","test/widget_test.dart"]'),
      findsOneWidget,
    );
    expect(find.text('/workspace/app'), findsOneWidget);
    expect(find.text('test/widget_test.dart'), findsOneWidget);
    expect(find.text('local'), findsOneWidget);
    expect(find.textContaining('toolCall'), findsNothing);
    expect(find.textContaining('unknownField'), findsNothing);
    expect(find.textContaining('UNPROJECTED_CANARY'), findsNothing);
  });

  testWidgets('PromptInput bounds and scrolls long permission context', (
    tester,
  ) async {
    final longSegment = List<String>.filled(18, 'very-long-segment').join('/');
    await tester.pumpWidget(
      input(
        isSending: false,
        onSend: (_, _) {},
        pendingPermissionRequest: AcpPermissionRequest(
          id: 'permission-long-context',
          title: 'Run long operation',
          rationale: 'Requested by agent',
          sessionId: 'session-1',
          toolName: 'terminal',
          toolKind: 'execute',
          options: const ['Allow', 'Deny'],
          requestedAt: DateTime(2026, 7, 11, 12),
          metadata: <String, Object?>{
            'command': 'tool',
            'args': <String>[longSegment],
            'cwd': '/cwd/$longSegment',
            'path': '/path/$longSegment',
            'target': 'final-target',
          },
        ),
      ),
    );

    final contextFinder = find.byKey(const Key('prompt-permission-context'));
    final scrollFinder = find.byKey(
      const Key('prompt-permission-context-scroll'),
    );
    expect(tester.getSize(contextFinder).height, lessThanOrEqualTo(180));
    expect(
      find.descendant(of: contextFinder, matching: find.byType(Scrollbar)),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: contextFinder,
        matching: find.byType(SingleChildScrollView),
      ),
      findsOneWidget,
    );
    expect(find.widgetWithText(OutlinedButton, 'Deny'), findsOneWidget);
    expect(
      tester.getBottomRight(find.text('final-target')).dy,
      greaterThan(tester.getBottomRight(contextFinder).dy),
    );

    await tester.drag(scrollFinder, const Offset(0, -1000));
    await tester.pump();

    expect(
      tester.getBottomRight(find.text('final-target')).dy,
      lessThanOrEqualTo(tester.getBottomRight(contextFinder).dy),
    );
  });

  testWidgets('PromptInput resets context scroll for a new request instance', (
    tester,
  ) async {
    final longSegment = List<String>.filled(
      18,
      'scroll-state-segment',
    ).join('/');
    AcpPermissionRequest request({
      required String id,
      required int generation,
      required String command,
    }) {
      return AcpPermissionRequest(
        id: id,
        title: 'Run operation',
        rationale: 'Requested by agent',
        sessionId: 'session-1',
        toolName: 'terminal',
        toolKind: 'execute',
        options: const ['Allow', 'Deny'],
        requestedAt: DateTime(2026, 7, 11, 12),
        generation: generation,
        metadata: <String, Object?>{
          'command': command,
          'cwd': '/cwd/$longSegment',
          'path': '/path/$longSegment',
          'target': 'final-target',
        },
      );
    }

    final firstRequest = request(
      id: 'permission-scroll-a',
      generation: 1,
      command: 'old-command-at-top',
    );
    final secondRequest = request(
      id: 'permission-scroll-b',
      generation: 2,
      command: 'new-command-at-top',
    );
    final scrollFinder = find.byKey(
      const Key('prompt-permission-context-scroll'),
    );

    ScrollPosition position() {
      final scrollView = tester.widget<SingleChildScrollView>(scrollFinder);
      return scrollView.controller!.position;
    }

    Widget prompt(AcpPermissionRequest pendingRequest) => input(
      isSending: false,
      onSend: (_, _) {},
      pendingPermissionRequest: pendingRequest,
    );

    await tester.pumpWidget(prompt(firstRequest));
    position().jumpTo(position().maxScrollExtent);
    await tester.pump();
    final scrolledPixels = position().pixels;
    expect(scrolledPixels, greaterThan(0));

    await tester.pumpWidget(prompt(firstRequest));
    await tester.pumpAndSettle();
    expect(position().pixels, closeTo(scrolledPixels, 0.01));

    await tester.pumpWidget(prompt(secondRequest));
    await tester.pumpAndSettle();

    expect(position().pixels, 0);
    final contextFinder = find.byKey(const Key('prompt-permission-context'));
    final commandFinder = find.text('["new-command-at-top"]');
    expect(
      tester.getTopLeft(commandFinder).dy,
      greaterThanOrEqualTo(tester.getTopLeft(contextFinder).dy),
    );
    expect(
      tester.getBottomRight(commandFinder).dy,
      lessThanOrEqualTo(tester.getBottomRight(contextFinder).dy),
    );
  });

  testWidgets('PromptInput avoids overflow with long context at 320 pixels', (
    tester,
  ) async {
    final longSegment = List<String>.filled(12, 'narrow-segment').join('/');
    await tester.pumpWidget(
      input(
        width: 320,
        isSending: false,
        onSend: (_, _) {},
        pendingPermissionRequest: AcpPermissionRequest(
          id: 'permission-narrow-context',
          title: 'Run long operation',
          rationale: 'Requested by agent',
          sessionId: 'session-1',
          toolName: 'terminal',
          toolKind: 'execute',
          options: const ['Allow', 'Deny'],
          requestedAt: DateTime(2026, 7, 11, 12),
          metadata: <String, Object?>{
            'command': 'tool',
            'args': <String>[longSegment],
            'cwd': '/cwd/$longSegment',
            'path': '/path/$longSegment',
            'target': 'final-target',
          },
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byKey(const Key('prompt-permission-context'))).height,
      lessThanOrEqualTo(180),
    );
    expect(find.widgetWithText(OutlinedButton, 'Deny'), findsOneWidget);
  });

  testWidgets('PromptInput fails closed for incomplete ordinary context', (
    tester,
  ) async {
    var allowed = false;
    var denied = false;
    var cancelled = false;
    await tester.pumpWidget(
      input(
        isSending: false,
        onSend: (_, _) {},
        pendingPermissionRequest: AcpPermissionRequest(
          id: 'permission-incomplete',
          title: 'Run command',
          rationale: 'Requested by agent',
          sessionId: 'session-1',
          toolName: 'terminal',
          toolKind: 'execute',
          options: const ['Allow', 'Deny'],
          requestedAt: DateTime(2026, 7, 11, 12),
          metadata: const <String, Object?>{
            'command': 'git status',
            'toolCall': <String, Object?>{'command': 'flutter test'},
            'cwd': '/workspace',
          },
        ),
        onAllowPermission: () => allowed = true,
        onDenyPermission: () => denied = true,
        onCancelPermission: () => cancelled = true,
      ),
    );

    expect(
      find.text('Some operation details could not be displayed safely.'),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('prompt-permission-context-warning')),
      findsOneWidget,
    );
    expect(find.text('Command'), findsNothing);
    expect(find.text('Working directory'), findsNothing);
    final allow = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Allow Once'),
    );
    expect(allow.onPressed, isNull);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Deny'));
    await tester.tap(find.byTooltip('Cancel permission request'));
    await tester.pump();

    expect(allowed, isFalse);
    expect(denied, isTrue);
    expect(cancelled, isTrue);
  });

  testWidgets(
    'PromptInput permits only explicit deny choices when incomplete',
    (tester) async {
      String? selectedOptionId;
      var cancelled = false;
      await tester.pumpWidget(
        input(
          isSending: false,
          onSend: (_, _) {},
          pendingPermissionRequest: AcpPermissionRequest(
            id: 'permission-structured-incomplete',
            title: 'Run command',
            rationale: 'Requested by agent',
            sessionId: 'session-1',
            toolName: 'terminal',
            toolKind: 'execute',
            options: const [
              'Allow once',
              'Deny once',
              'Reject',
              'Allow',
              'Mystery',
            ],
            choices: const <AcpPermissionChoice>[
              AcpPermissionChoice(
                optionId: 'allow-once',
                name: 'Allow once',
                kind: 'allow_once',
              ),
              AcpPermissionChoice(
                optionId: 'deny-once',
                name: 'Deny once',
                kind: 'deny_once',
              ),
              AcpPermissionChoice(optionId: 'legacy-reject', name: 'Reject'),
              AcpPermissionChoice(optionId: 'legacy-allow', name: 'Allow'),
              AcpPermissionChoice(
                optionId: 'unknown-kind',
                name: 'Mystery',
                kind: 'ask_later',
              ),
            ],
            requestedAt: DateTime(2026, 7, 11, 12),
            metadata: const <String, Object?>{
              'path': '/one',
              'input': <String, Object?>{'path': '/two'},
            },
          ),
          onSelectPermissionOption: (value) => selectedOptionId = value,
          onCancelPermission: () => cancelled = true,
        ),
      );

      ButtonStyleButton choice(String id) => tester.widget<ButtonStyleButton>(
        find.byKey(Key('prompt-permission-option-$id')),
      );

      expect(choice('allow-once').onPressed, isNull);
      expect(choice('deny-once').onPressed, isNotNull);
      expect(choice('legacy-reject').onPressed, isNull);
      expect(choice('legacy-allow').onPressed, isNull);
      expect(choice('unknown-kind').onPressed, isNull);

      await tester.tap(
        find.byKey(const Key('prompt-permission-option-deny-once')),
      );
      await tester.tap(find.byTooltip('Cancel permission request'));
      await tester.pump();

      expect(selectedOptionId, 'deny-once');
      expect(cancelled, isTrue);
    },
  );

  testWidgets('PromptInput keeps legacy empty context allow action enabled', (
    tester,
  ) async {
    var allowed = false;
    await tester.pumpWidget(
      input(
        isSending: false,
        onSend: (_, _) {},
        pendingPermissionRequest: AcpPermissionRequest(
          id: 'permission-legacy',
          title: 'Read file',
          rationale: 'Requested by agent',
          sessionId: 'session-1',
          toolName: 'read_text_file',
          options: const ['Allow', 'Deny'],
          requestedAt: DateTime(2026, 7, 11, 12),
        ),
        onAllowPermission: () => allowed = true,
      ),
    );

    expect(find.byKey(const Key('prompt-permission-context')), findsNothing);
    expect(
      find.byKey(const Key('prompt-permission-context-warning')),
      findsNothing,
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Allow Once'));
    await tester.pump();
    expect(allowed, isTrue);
  });

  testWidgets('PromptInput displays escaped permission values only', (
    tester,
  ) async {
    const rawPath = ' \n\u202eDANGEROUS ';
    await tester.pumpWidget(
      input(
        isSending: false,
        onSend: (_, _) {},
        pendingPermissionRequest: AcpPermissionRequest(
          id: 'permission-escaped',
          title: 'Read path',
          rationale: 'Requested by agent',
          sessionId: 'session-1',
          toolName: 'read_text_file',
          options: const ['Allow', 'Deny'],
          requestedAt: DateTime(2026, 7, 11, 12),
          metadata: const <String, Object?>{
            'path': rawPath,
            'unprojected': 'UNPROJECTED_CANARY',
          },
        ),
      ),
    );

    expect(
      find.text(r'\u{0020}\u{000A}\u{202E}DANGEROUS\u{0020}'),
      findsOneWidget,
    );
    expect(find.textContaining('\n'), findsNothing);
    expect(find.textContaining('\u202e'), findsNothing);
    expect(find.textContaining('UNPROJECTED_CANARY'), findsNothing);
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

  testWidgets('PromptInput returns the exact structured permission option', (
    tester,
  ) async {
    String? selectedOptionId;
    await tester.pumpWidget(
      input(
        isSending: false,
        onSend: (_, _) {},
        pendingPermissionRequest: AcpPermissionRequest(
          id: 'permission-1',
          title: 'Run command',
          rationale: 'Requested by agent',
          sessionId: 'session-1',
          toolName: 'terminal',
          options: const ['Allow once', 'Always allow', 'Reject'],
          choices: const [
            AcpPermissionChoice(
              optionId: 'allow-once',
              name: 'Allow once',
              kind: 'allow_once',
            ),
            AcpPermissionChoice(
              optionId: 'allow-always',
              name: 'Always allow',
              kind: 'allow_always',
            ),
            AcpPermissionChoice(
              optionId: 'reject-once',
              name: 'Reject',
              kind: 'reject_once',
            ),
          ],
          requestedAt: DateTime(2026, 5, 31, 12),
        ),
        onSelectPermissionOption: (optionId) => selectedOptionId = optionId,
      ),
    );

    expect(find.text('Allow once'), findsOneWidget);
    expect(find.text('Always allow'), findsOneWidget);
    expect(find.text('Reject'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Always allow'));
    await tester.pump();

    expect(selectedOptionId, 'allow-always');
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

  testWidgets('PromptInput keeps model and reasoning choices separate', (
    tester,
  ) async {
    String? selectedEffort;
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
        onModelSelected: (_) {},
        reasoningEffortOption: const AcpConfigOption(
          id: 'reasoning_effort',
          name: 'Reasoning Effort',
          type: 'select',
          currentValue: 'high',
          options: [
            AcpConfigOptionChoice(value: 'low', name: 'Low'),
            AcpConfigOptionChoice(value: 'high', name: 'High'),
          ],
        ),
        onReasoningEffortSelected: (value) => selectedEffort = value,
      ),
    );

    expect(find.text('High'), findsOneWidget);
    await tester.tap(find.byKey(const Key('prompt-reasoning-effort-selector')));
    await tester.pumpAndSettle();
    expect(find.text('GPT-5 Mini'), findsNothing);
    expect(find.text('Low'), findsOneWidget);
    await tester.tap(find.text('Low'));
    await tester.pumpAndSettle();

    expect(selectedEffort, 'low');

    await tester.tap(find.byKey(const Key('prompt-model-selector')));
    await tester.pumpAndSettle();
    expect(find.text('GPT-5 Mini'), findsOneWidget);
    expect(find.text('Low'), findsNothing);
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

final class _CountingCommandMap extends MapBase<String, Object?> {
  _CountingCommandMap(this._values, {this.throwingKeys = const <String>{}});

  final Map<String, Object?> _values;
  final Set<String> throwingKeys;
  final Map<String, int> _reads = <String, int>{};

  int readsFor(String key) => _reads[key] ?? 0;

  @override
  Object? operator [](Object? key) {
    if (key is String) _reads[key] = readsFor(key) + 1;
    if (throwingKeys.contains(key)) throw StateError('hostile command getter');
    return _values[key];
  }

  @override
  void operator []=(String key, Object? value) {
    _values[key] = value;
  }

  @override
  void clear() => _values.clear();

  @override
  Iterable<String> get keys => _values.keys;

  @override
  Object? remove(Object? key) => _values.remove(key);
}

final class _CountingCommandList extends ListBase<Map<String, Object?>> {
  _CountingCommandList(
    this._values, {
    this.throwOnLength = false,
    this.throwOnIndex = false,
  });

  final List<Map<String, Object?>> _values;
  final bool throwOnLength;
  final bool throwOnIndex;
  int lengthReads = 0;

  @override
  int get length {
    lengthReads += 1;
    if (throwOnLength) throw StateError('hostile command list length');
    return _values.length;
  }

  @override
  set length(int value) => throw UnsupportedError('immutable test list');

  @override
  Map<String, Object?> operator [](int index) {
    if (throwOnIndex) throw StateError('hostile command list index');
    return _values[index];
  }

  @override
  void operator []=(int index, Map<String, Object?> value) {
    throw UnsupportedError('immutable test list');
  }
}
