import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/acp_session_settings.dart';
import 'package:ianvs_acp/acp/agent_session.dart';
import 'package:ianvs_acp/acp/fake_agent_client.dart';
import 'package:ianvs_acp/config/acp_client_config.dart';
import 'package:ianvs_acp/config/assistant_agent_config.dart';
import 'package:ianvs_acp/state/chat_controller.dart';
import 'package:ianvs_acp/state/connection_state.dart' as app_state;
import 'package:ianvs_acp/ui/components/agent_config_dialog.dart';
import 'package:ianvs_acp/ui/components/agent_toolbar.dart';
import 'package:ianvs_acp/ui/components/chat_timeline.dart';
import 'package:ianvs_acp/ui/components/prompt_input.dart';
import 'package:ianvs_acp/ui/theme/app_design_tokens.dart';

void main() {
  setUpAll(() async {
    final bytes = await File(
      '/System/Library/Fonts/Supplemental/Arial Unicode.ttf',
    ).readAsBytes();
    final loader = FontLoader('GoldenQA')
      ..addFont(
        Future<ByteData>.value(ByteData.sublistView(Uint8List.fromList(bytes))),
      );
    final iconBytes = await File(
      '/Users/robinfai/development/flutter/bin/cache/artifacts/'
      'material_fonts/MaterialIcons-Regular.otf',
    ).readAsBytes();
    final iconLoader = FontLoader('MaterialIcons')
      ..addFont(
        Future<ByteData>.value(
          ByteData.sublistView(Uint8List.fromList(iconBytes)),
        ),
      );
    final monoBytes = await File(
      '/System/Library/Fonts/SFNSMono.ttf',
    ).readAsBytes();
    final monoLoader = FontLoader('monospace')
      ..addFont(
        Future<ByteData>.value(
          ByteData.sublistView(Uint8List.fromList(monoBytes)),
        ),
      );
    await Future.wait([loader.load(), iconLoader.load(), monoLoader.load()]);
  });

  testWidgets('selected task menu visual', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1180, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final session = AgentSession(
      id: 'session-menu-preview',
      cwd: '/Users/example/projects/ianvs-acp',
      createdAt: DateTime(2026, 7, 31, 10),
      title: '完善助手 Agent 与消息队列',
      agentName: 'Codex',
    );

    await tester.pumpWidget(
      _frame(
        Align(
          alignment: Alignment.topCenter,
          child: AgentToolbar(
            title: session.displayTitle,
            agentName: 'Codex',
            status: app_state.ConnectionStatus.sessionReady,
            onNewSession: () {},
            onResumeSession: () {},
            onReconnect: null,
            currentSession: session,
            canForkSession: true,
            supportsGitWorktrees: true,
            onSessionMenuAction: (_) {},
            forceFullActions: true,
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('toolbar-session-actions')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue in...'));
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/selected-task-menu.png'),
    );
  });

  testWidgets('selected queue and guide visual', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1180, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _frame(
        Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: SizedBox(
              width: 920,
              child: PromptInput(
                isSending: true,
                onSend: (_, _) {},
                onStop: () {},
                queuedPrompts: [
                  ChatQueuedPrompt(
                    id: 1,
                    text: '补充非 Git workspace 的条件展示测试',
                    attachments: const [],
                    createdAt: DateTime(2026, 7, 31, 10),
                    guide: true,
                  ),
                  ChatQueuedPrompt(
                    id: 2,
                    text: '整理工具调用与文件对比的展示',
                    attachments: const [],
                    createdAt: DateTime(2026, 7, 31, 10, 1),
                  ),
                  ChatQueuedPrompt(
                    id: 3,
                    text: '运行完整 UI 回归测试',
                    attachments: const [],
                    createdAt: DateTime(2026, 7, 31, 10, 2),
                  ),
                ],
                onGuideQueuedPrompt: (_) {},
                onRemoveQueuedPrompt: (_) {},
                onClearQueuedPrompts: () {},
                onReorderQueuedPrompt: (_, _) {},
                configOptions: const [
                  AcpConfigOption(
                    id: 'model',
                    name: 'Model',
                    type: 'select',
                    currentValue: 'gpt-5.6-sol',
                    options: [
                      AcpConfigOptionChoice(
                        value: 'gpt-5.6-sol',
                        name: '5.6 Sol',
                      ),
                    ],
                  ),
                  AcpConfigOption(
                    id: 'reasoning_effort',
                    name: 'Reasoning Effort',
                    type: 'select',
                    currentValue: 'high',
                    options: [
                      AcpConfigOptionChoice(value: 'medium', name: 'Medium'),
                      AcpConfigOptionChoice(value: 'high', name: 'High'),
                    ],
                  ),
                ],
                onConfigOptionSelected: (_, _) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/selected-queue-guide.png'),
    );
  });

  testWidgets('selected assistant summary visual', (tester) async {
    await tester.binding.setSurfaceSize(const Size(980, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);
    controller.addMessageForTesting(
      ChatMessage(
        role: ChatMessageRole.user,
        text: '实现助手 Agent 配置，并让任务过程默认收起。',
        timestamp: DateTime(2026, 7, 31, 10),
      ),
      startsNewTurn: true,
    );
    controller.addMessageForTesting(
      ChatMessage(
        role: ChatMessageRole.assistant,
        text: '正在检查配置、会话标题和时间线渲染。',
        timestamp: DateTime(2026, 7, 31, 10, 1),
      ),
    );
    controller.addMessageForTesting(
      ChatMessage(
        role: ChatMessageRole.status,
        text: '已完成助手 Agent 配置、智能标题和任务摘要；执行过程默认收起，失败时仍保留原始内容。',
        timestamp: DateTime(2026, 7, 31, 10, 1, 10),
        metadata: const {
          'kind': 'assistant_summary',
          'sourceTurnId': 1,
          'collapseProcess': true,
        },
      ),
    );

    await tester.pumpWidget(
      _frame(
        ChatTimeline(
          messages: controller.messages,
          messageListRevision: controller.messagesRevision,
          hasActiveSession: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/selected-assistant-summary.png'),
    );
  });

  testWidgets('selected turn navigation preview visual', (tester) async {
    await tester.binding.setSurfaceSize(const Size(980, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);
    controller.addMessageForTesting(
      ChatMessage(
        role: ChatMessageRole.user,
        text: '应用启动之后会自动清理，还是需要手动清理？',
        timestamp: DateTime(2026, 7, 31, 10),
      ),
      startsNewTurn: true,
    );
    controller.addMessageForTesting(
      ChatMessage(
        role: ChatMessageRole.assistant,
        text: '会自动清理，不需要日常手动操作；启动和定时维护都会执行。',
        timestamp: DateTime(2026, 7, 31, 10, 1),
      ),
    );
    controller.addMessageForTesting(
      ChatMessage(
        role: ChatMessageRole.status,
        text: '应用会在启动和维护周期自动清理过期数据，用户仍可在设置中调整容量与保留期限。',
        timestamp: DateTime(2026, 7, 31, 10, 1, 10),
        metadata: const {
          'kind': 'assistant_summary',
          'sourceTurnId': 1,
          'collapseProcess': true,
        },
      ),
    );

    await tester.pumpWidget(
      _frame(
        ChatTimeline(
          messages: controller.messages,
          messageListRevision: controller.messagesRevision,
          hasActiveSession: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    tester
        .state<TooltipState>(find.byType(Tooltip).first)
        .ensureTooltipVisible();
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/selected-turn-navigation.png'),
    );
  });

  testWidgets('selected tool aggregation and diff visual', (tester) async {
    await tester.binding.setSurfaceSize(const Size(980, 780));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _frame(
        ChatTimeline(
          hasActiveSession: true,
          messages: [
            ChatMessage(
              role: ChatMessageRole.tool,
              text: 'read_file',
              metadata: const {
                'toolCallId': 'call-1',
                'title': 'read_file',
                'status': 'completed',
                'rawInput': {'path': 'lib/ui/components/prompt_input.dart'},
              },
            ),
            ChatMessage(
              role: ChatMessageRole.tool,
              text: 'exec_command',
              metadata: const {
                'toolCallId': 'call-2',
                'title': 'exec_command',
                'status': 'completed',
                'rawInput': {'cmd': 'flutter test --no-pub test/ui'},
              },
            ),
            ChatMessage(
              role: ChatMessageRole.tool,
              text: 'exec_command',
              metadata: const {
                'toolCallId': 'call-3',
                'title': 'exec_command',
                'status': 'completed',
                'rawInput': {'cmd': 'git diff --check'},
              },
            ),
            ChatMessage(
              role: ChatMessageRole.status,
              text: 'file:///workspace/lib/ui/components/prompt_input.dart',
              metadata: const {
                'kind': 'diff',
                'uri': 'file:///workspace/lib/ui/components/prompt_input.dart',
                'status': 'completed',
                'changes': [
                  {
                    'type': 'modification',
                    'line': 422,
                    'oldContent': 'onPressed: isSending ? null : sendPrompt,',
                    'newContent': 'onPressed: queueOrSendPrompt,',
                  },
                  {
                    'type': 'addition',
                    'line': 423,
                    'newContent': 'tooltip: isSending ? "Queue" : "Send",',
                  },
                ],
              },
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('3 tool calls'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Changed lines'));
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/selected-tools-diff.png'),
    );
  });

  testWidgets('selected Assistant Agent settings visual', (tester) async {
    await tester.binding.setSurfaceSize(const Size(980, 980));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _frame(
        AgentConfigDialog(
          configPath: '/Users/example/.config/ianvs-acp/settings.json',
          activeAgentName: 'Codex',
          defaultAgentName: 'Codex',
          assistantAgent: const AssistantAgentConfig(
            enabled: true,
            agentName: 'Pi',
            model: 'deepseek-v3',
            fallbackTitleCharacters: 24,
          ),
          agentServers: const [
            AgentServerConfig(
              name: 'Codex',
              type: 'custom',
              command: '/usr/local/bin/codex',
            ),
            AgentServerConfig(
              name: 'Pi',
              type: 'custom',
              command: '/usr/local/bin/pi',
            ),
          ],
          onSaveConfig: (config) async => config,
        ),
      ),
    );
    await tester.ensureVisible(
      find.byKey(const Key('assistant-agent-enabled-switch')),
    );
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/selected-assistant-settings.png'),
    );
  });
}

Widget _frame(Widget child) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: _theme(),
    home: Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(child: child),
    ),
  );
}

ThemeData _theme() {
  return ThemeData(
    colorScheme: const ColorScheme.light(
      primary: AppColors.textPrimary,
      onPrimary: Colors.white,
      secondary: AppColors.textSecondary,
      onSecondary: Colors.white,
      surface: AppColors.surface,
      onSurface: AppColors.textPrimary,
      error: AppColors.danger,
      onError: Colors.white,
      outline: AppColors.border,
      outlineVariant: AppColors.borderSoft,
    ),
    scaffoldBackgroundColor: AppColors.bg,
    useMaterial3: true,
    visualDensity: VisualDensity.compact,
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    fontFamily: 'GoldenQA',
    dividerTheme: const DividerThemeData(
      color: AppColors.border,
      thickness: 1,
      space: 1,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surface,
      hoverColor: AppColors.surfaceMuted,
      isDense: true,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        borderSide: const BorderSide(color: AppColors.textSecondary),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: AppColors.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        side: const BorderSide(color: AppColors.border),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: AppColors.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.xl),
        side: const BorderSide(color: AppColors.border),
      ),
    ),
  );
}
