import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:ianvs_acp/acp/acp_permission_request.dart';
import 'package:ianvs_acp/acp/acp_session_settings.dart';
import 'package:ianvs_acp/acp/agent_event.dart';
import 'package:ianvs_acp/acp/fake_agent_client.dart';
import 'package:ianvs_acp/app.dart';
import 'package:ianvs_acp/config/acp_client_config.dart';
import 'package:ianvs_acp/state/chat_controller.dart';

class AuditFixture {
  const AuditFixture({required this.fake, required this.controller});

  final FakeAgentClient fake;
  final ChatController controller;

  Widget app({String? startupError}) {
    return AcpClientApp(
      controller: controller,
      config: auditSeedConfig,
      startupError: startupError,
      onRetryStartup: startupError == null ? null : () {},
    );
  }

  void dispose() => controller.dispose();
}

Future<AuditFixture> createAuditFixture(String scenario) async {
  final fake = FakeAgentClient(
    authMethods: const [
      {
        'id': 'browser',
        'name': 'Browser sign-in',
        'description': 'Open a browser session for this ACP agent.',
      },
    ],
    createSessionEvents: scenario == 'reference'
        ? referenceReplicaEvents
        : auditSeedEvents,
    sessionSettings: auditSeedSettings,
  );
  final controller = ChatController(
    client: fake,
    cwd: '/Users/robinfai/personal/ianvs/ianvs-acp',
    additionalDirectories: const ['/Users/robinfai/personal/ianvs'],
    agentName: 'Codex',
  );

  if (scenario != 'empty') {
    await controller.connect();
    await controller.newSession();
  }
  if (scenario == 'permission') {
    unawaited(
      Future<void>.delayed(const Duration(milliseconds: 350), () {
        fake.emitPermissionRequest(auditSeedPermissionRequest);
      }),
    );
  }
  if (scenario == 'streaming') {
    unawaited(
      Future<void>.delayed(const Duration(milliseconds: 350), () {
        unawaited(
          controller.sendPrompt(
            'Review the current ACP client layout and summarize the risks.',
          ),
        );
      }),
    );
  }

  return AuditFixture(fake: fake, controller: controller);
}

final AcpClientConfig auditSeedConfig = AcpClientConfig.fromJson({
  'default_agent_server': 'Codex',
  'agent_servers': {
    'Codex': {
      'type': 'custom',
      'command': '/usr/local/bin/npx',
      'args': ['@zed-industries/codex-acp'],
    },
    'Kimi Code Dev': {
      'type': 'custom',
      'command': '/usr/local/bin/kimi',
      'args': ['acp'],
    },
  },
  'mcp_servers': [
    {'name': 'review-tools', 'type': 'stdio', 'command': 'review-tools'},
  ],
  'additional_directories': ['/Users/robinfai/personal/ianvs'],
  'client_providers': {
    'filesystem': {'enabled': true},
    'terminal': {'enabled': true},
    'permissions': {
      'review_agent': {
        'enabled': true,
        'mcp_server': {
          'name': 'review-tools',
          'type': 'stdio',
          'command': 'review-tools',
        },
      },
    },
  },
}, configPath: '/Users/robinfai/.config/ianvs-acp/settings.json');

const AcpSessionSettings auditSeedSettings = AcpSessionSettings(
  modes: AcpSessionModeInfo(
    currentModeId: 'ask',
    availableModes: [
      AcpSessionMode(id: 'ask', name: 'Ask'),
      AcpSessionMode(id: 'edit', name: 'Edit'),
    ],
  ),
  configOptions: [
    AcpConfigOption(
      id: 'model',
      name: 'Model',
      type: 'select',
      currentValue: 'gpt-5-codex',
      description: 'Controls the active model for this session.',
      group: 'Model',
      options: [
        AcpConfigOptionChoice(value: 'gpt-5-codex', name: 'GPT-5 Codex'),
        AcpConfigOptionChoice(value: 'gpt-5', name: 'GPT-5'),
      ],
    ),
    AcpConfigOption(
      id: 'reasoning_effort',
      name: 'Reasoning effort',
      type: 'select',
      currentValue: 'medium',
      description: 'Controls how much reasoning the agent applies.',
      group: 'Model',
      options: [
        AcpConfigOptionChoice(value: 'low', name: 'Low'),
        AcpConfigOptionChoice(value: 'medium', name: 'Medium'),
        AcpConfigOptionChoice(value: 'high', name: 'High'),
      ],
    ),
    AcpConfigOption(
      id: 'approval',
      name: 'Approval mode',
      type: 'select',
      currentValue: 'suggest',
      description: 'Controls how the agent asks before changing files.',
      group: 'Safety',
      options: [
        AcpConfigOptionChoice(value: 'suggest', name: 'Suggest first'),
        AcpConfigOptionChoice(value: 'auto', name: 'Auto apply'),
      ],
    ),
  ],
);

const List<AgentEvent> auditSeedEvents = [
  AgentEvent(
    type: AgentEventType.userMessage,
    text: 'Review the ACP client implementation and identify UI gaps.',
  ),
  AgentEvent(
    type: AgentEventType.agentTextDelta,
    text:
        'I inspected the app shell, session controls, timeline grouping, permission banner, and configuration dialogs. The next useful step is tightening hierarchy so core actions stand apart from secondary inspection tools.',
  ),
  AgentEvent(
    type: AgentEventType.toolCall,
    text: 'flutter test test/ui/acp_client_app_test.dart',
    metadata: {
      'toolCallId': 'tool-1',
      'title': 'flutter test',
      'status': 'completed',
      'kind': 'execute',
      'rawInput': {'cmd': 'flutter test test/ui/acp_client_app_test.dart'},
      'rawOutput': '00:02 +12: All tests passed.',
    },
  ),
  AgentEvent(
    type: AgentEventType.status,
    text: 'Implementation plan',
    metadata: {
      'kind': 'plan',
      'title': 'Implementation plan',
      'entries': [
        {
          'content': 'Map the main navigation and session states',
          'priority': 'high',
          'status': 'completed',
        },
        {
          'content': 'Check prompt composer states and permission review',
          'priority': 'high',
          'status': 'in_progress',
        },
        {
          'content': 'Review capabilities and configuration dialogs',
          'priority': 'medium',
          'status': 'pending',
        },
      ],
    },
  ),
  AgentEvent(
    type: AgentEventType.status,
    text: 'Available commands',
    metadata: {
      'kind': 'commands',
      'commands': [
        {
          'name': 'review',
          'description': 'Review the current project and summarize findings.',
        },
        {'name': 'test', 'description': 'Run the focused Flutter test suite.'},
      ],
    },
  ),
];

final List<AgentEvent> referenceReplicaEvents = [
  AgentEvent(
    type: AgentEventType.userMessage,
    text: '本地干线合并并提交推送',
    timestamp: DateTime(2026, 8, 11, 9),
  ),
  AgentEvent(
    type: AgentEventType.toolCall,
    text: 'git status --short --branch',
    timestamp: DateTime(2026, 8, 11, 9, 0, 8),
    metadata: const {
      'toolCallId': 'git-status-1',
      'title': 'git status',
      'status': 'completed',
      'kind': 'execute',
      'rawInput': {'cmd': 'git status --short --branch'},
      'rawOutput': '## main\n',
    },
  ),
  AgentEvent(
    type: AgentEventType.agentTextDelta,
    timestamp: DateTime(2026, 8, 11, 9, 0, 22),
    text: '''当前已在本地 `main`，变更范围只有本次适配的 4 个文件，没有无关改动。

但 GitHub CLI 的 `robinfai` 登录令牌已失效。请先运行：

```bash
gh auth login -h github.com
```

认证完成后告诉我“继续”，我会直接提交到本地 `main` 并推送 `origin/main`。''',
  ),
  AgentEvent(
    type: AgentEventType.userMessage,
    text: 'git 命令操作试试',
    timestamp: DateTime(2026, 8, 11, 9, 1),
  ),
  AgentEvent(
    type: AgentEventType.toolCall,
    text: 'git push origin main',
    timestamp: DateTime(2026, 8, 11, 9, 1, 34),
    metadata: const {
      'toolCallId': 'git-push-2',
      'title': 'git push',
      'status': 'completed',
      'kind': 'execute',
      'rawInput': {'cmd': 'git push origin main'},
      'rawOutput': 'main -> main',
    },
  ),
  AgentEvent(
    type: AgentEventType.agentTextDelta,
    timestamp: DateTime(2026, 8, 11, 9, 1, 56),
    text: '''已直接提交并推送到本地主线及远端 `main`。

- 提交：`4a1f2b3 Add Cursor and CodeBuddy ACP support`
- 推送：`origin/main`
- 本地与远端完全同步，工作区干净
- 相关 95 项测试及静态检查已通过''',
  ),
  AgentEvent(
    type: AgentEventType.status,
    text: 'Turn completed',
    timestamp: DateTime(2026, 8, 11, 9, 1, 56),
    metadata: const {'kind': 'turn'},
  ),
];

final AcpPermissionRequest auditSeedPermissionRequest = AcpPermissionRequest(
  id: 'perm-1',
  title: 'Run shell command?',
  rationale:
      'Codex wants to run `flutter test` in the workspace to verify the UI behavior before continuing.',
  sessionId: 'fake-session-1',
  toolName: 'exec_command',
  toolKind: 'terminal',
  options: const ['Allow Once', 'Deny'],
  requestedAt: DateTime(2026, 6, 5, 10, 30),
  metadata: const {
    'command': 'flutter test test/ui/acp_client_app_test.dart',
    'cwd': '/Users/robinfai/personal/ianvs/ianvs-acp',
  },
);
