import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/acp_session_settings.dart';
import 'package:ianvs_acp/acp/agent_event.dart';
import 'package:ianvs_acp/acp/fake_agent_client.dart';
import 'package:ianvs_acp/acp/prompt_attachment.dart';
import 'package:ianvs_acp/state/chat_controller.dart';
import 'package:ianvs_acp/state/connection_state.dart' as app_state;

void main() {
  test('connect success sets connected status', () async {
    final controller = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    await controller.connect();

    expect(controller.status, app_state.ConnectionStatus.connected);
    expect(controller.lastError, isNull);
  });

  test('connect failure sets error status', () async {
    final controller = ChatController(
      client: FakeAgentClient(connectError: Exception('codex missing')),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    await controller.connect();

    expect(controller.status, app_state.ConnectionStatus.error);
    expect(controller.lastError, contains('codex missing'));
  });

  test('create session success sets current session', () async {
    final controller = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    await controller.newSession();

    expect(controller.status, app_state.ConnectionStatus.sessionReady);
    expect(controller.currentSession?.id, 'fake-session-1');
    expect(controller.currentSession?.agentName, 'Codex');
    expect(controller.sessions, hasLength(1));
    expect(controller.sessionSettings.modes.currentModeId, 'ask');
  });

  test('created sessions keep selected agent name', () async {
    final controller = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace',
      agentName: 'Kimi Code Dev',
    );
    addTearDown(controller.dispose);

    await controller.newSession();

    expect(controller.currentSession?.agentName, 'Kimi Code Dev');
    expect(controller.sessions.single.agentName, 'Kimi Code Dev');
  });

  test('new sessions append to sidebar history', () async {
    final controller = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    await controller.newSession();
    await controller.newSession();

    expect(controller.currentSession?.id, 'fake-session-2');
    expect(controller.sessions.map((session) => session.id), [
      'fake-session-2',
      'fake-session-1',
    ]);
  });

  test(
    'concurrent new session requests are ignored while one is running',
    () async {
      final fake = FakeAgentClient(
        createSessionDelay: const Duration(milliseconds: 20),
      );
      final controller = ChatController(client: fake, cwd: '/workspace');
      addTearDown(controller.dispose);

      final first = controller.newSession();
      final second = controller.newSession();
      await Future.wait([first, second]);

      expect(fake.sessionCount, 1);
      expect(controller.sessions, hasLength(1));
      expect(controller.isSessionOperationRunning, isFalse);
    },
  );

  test('list sessions keeps session operation lock while loading', () async {
    final fake = FakeAgentClient(
      listSessionsDelay: const Duration(milliseconds: 20),
    );
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    await controller.connect();
    final loading = controller.listSessions();
    await pumpEventQueue();

    expect(controller.isSessionOperationRunning, isTrue);

    final projects = await loading;

    expect(projects.single.cwd, '/workspace/project-a');
    expect(controller.isSessionOperationRunning, isFalse);
  });

  test('resume session replays history into timeline', () async {
    final controller = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    await controller.resumeSession('resumed-session-1');

    expect(controller.status, app_state.ConnectionStatus.sessionReady);
    expect(controller.currentSession?.id, 'resumed-session-1');
    expect(controller.currentSession?.agentName, 'Codex');
    expect(controller.sessions, hasLength(1));
    expect(controller.messages.map((message) => message.role), [
      ChatMessageRole.user,
      ChatMessageRole.assistant,
      ChatMessageRole.tool,
      ChatMessageRole.status,
    ]);
    expect(controller.messages[1].text, contains('medium-sized transcript'));
  });

  test('resume session preserves consecutive user messages', () async {
    final controller = ChatController(
      client: FakeAgentClient(
        resumeEvents: const [
          AgentEvent(type: AgentEventType.userMessage, text: 'First request'),
          AgentEvent(type: AgentEventType.userMessage, text: 'Second request'),
        ],
      ),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    await controller.resumeSession('resumed-session-users');

    expect(controller.messages, hasLength(2));
    expect(controller.messages.map((message) => message.role), [
      ChatMessageRole.user,
      ChatMessageRole.user,
    ]);
    expect(controller.messages.map((message) => message.text), [
      'First request',
      'Second request',
    ]);
  });

  test('resume session uses selected project cwd', () async {
    final fake = FakeAgentClient();
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    await controller.resumeSession('resumed-session-2', cwd: '/other/project');

    expect(controller.currentSession?.cwd, '/other/project');
    expect(fake.lastResumeCwd, '/other/project');
    expect(controller.sessionSettings.configOptions.single.id, 'approval');
  });

  test('resume session keeps ACP session title metadata', () async {
    final controller = ChatController(
      client: FakeAgentClient(
        resumeEvents: const [
          AgentEvent(
            type: AgentEventType.status,
            text: 'Updated session title',
            metadata: {
              'kind': 'session_info_update',
              'sessionId': 'resumed-session-title',
              'title': 'Updated session title',
              'updatedAt': '2026-05-30T04:12:00Z',
            },
          ),
        ],
      ),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    await controller.resumeSession(
      'resumed-session-title',
      title: 'Original session title',
    );

    expect(controller.messages, isEmpty);
    expect(controller.currentSession?.displayTitle, 'Updated session title');
    expect(controller.sessions.single.displayTitle, 'Updated session title');
  });

  test('plan status updates replace previous plan snapshot', () async {
    final controller = ChatController(
      client: FakeAgentClient(
        resumeEvents: const [
          AgentEvent(
            type: AgentEventType.status,
            text: 'Initial plan',
            metadata: {
              'kind': 'plan',
              'title': 'Initial plan',
              'entries': [
                {'content': 'Inspect', 'priority': 'high', 'status': 'pending'},
              ],
            },
          ),
          AgentEvent(
            type: AgentEventType.status,
            text: 'Updated plan',
            metadata: {
              'kind': 'plan',
              'title': 'Updated plan',
              'entries': [
                {
                  'content': 'Inspect',
                  'priority': 'high',
                  'status': 'completed',
                },
              ],
            },
          ),
        ],
      ),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    await controller.resumeSession('resumed-session-plan');

    expect(controller.messages, hasLength(1));
    expect(controller.messages.single.text, 'Updated plan');
  });

  test('set session mode updates ACP session settings', () async {
    final fake = FakeAgentClient();
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    await controller.newSession();
    await controller.setSessionMode('edit');

    expect(fake.lastSetModeId, 'edit');
    expect(controller.sessionSettings.modes.currentModeId, 'edit');
    expect(controller.lastError, isNull);
  });

  test('set config option updates ACP session settings', () async {
    final fake = FakeAgentClient();
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    await controller.newSession();
    await controller.setConfigOption('approval', 'auto');

    expect(fake.lastConfigId, 'approval');
    expect(fake.lastConfigValue, 'auto');
    expect(
      controller.sessionSettings.configOptions.single.currentValue,
      'auto',
    );
    expect(controller.lastError, isNull);
  });

  test(
    'set config option preserves local options when response omits list',
    () async {
      final fake = _OmittingConfigOptionsAgentClient();
      final controller = ChatController(client: fake, cwd: '/workspace');
      addTearDown(controller.dispose);

      await controller.newSession();
      await controller.setConfigOption('approval', 'auto');

      expect(fake.lastConfigId, 'approval');
      expect(fake.lastConfigValue, 'auto');
      expect(controller.sessionSettings.configOptions, hasLength(1));
      expect(
        controller.sessionSettings.configOptions.single.currentValue,
        'auto',
      );
      expect(controller.lastError, isNull);
    },
  );

  test('set session model updates model config option', () async {
    final fake = FakeAgentClient(
      sessionSettings: const AcpSessionSettings(
        configOptions: [
          AcpConfigOption(
            id: 'model',
            name: 'Model',
            type: 'select',
            currentValue: 'gpt-5',
            options: [
              AcpConfigOptionChoice(value: 'gpt-5', name: 'GPT-5'),
              AcpConfigOptionChoice(
                value: 'claude-sonnet-4',
                name: 'Claude Sonnet 4',
              ),
            ],
          ),
        ],
      ),
    );
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    await controller.newSession();
    await controller.setSessionModel('claude-sonnet-4');

    expect(fake.lastConfigId, 'model');
    expect(fake.lastConfigValue, 'claude-sonnet-4');
    expect(controller.sessionSettings.currentModelLabel, 'Claude Sonnet 4');
    expect(controller.lastError, isNull);
  });

  test('close current session clears active state', () async {
    final fake = FakeAgentClient();
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    await controller.newSession();
    await controller.sendPrompt('Hi');
    await pumpEventQueue(times: 12);
    expect(controller.currentSession?.id, 'fake-session-1');
    expect(controller.messages, isNotEmpty);

    await controller.closeCurrentSession();

    expect(fake.lastClosedSessionId, 'fake-session-1');
    expect(controller.currentSession, isNull);
    expect(controller.sessions, isEmpty);
    expect(controller.messages, isEmpty);
    expect(controller.status, app_state.ConnectionStatus.connected);
  });

  test('logout clears local session state', () async {
    final fake = FakeAgentClient();
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    await controller.newSession();
    await controller.sendPrompt('Hi');
    await pumpEventQueue(times: 12);
    expect(controller.canLogout, isTrue);

    await controller.logout();

    expect(fake.loggedOut, isTrue);
    expect(controller.currentSession, isNull);
    expect(controller.sessions, isEmpty);
    expect(controller.messages, isEmpty);
    expect(controller.status, app_state.ConnectionStatus.connected);
  });

  test('agentTextDone stop reason is rendered as a turn status', () async {
    final controller = ChatController(
      client: FakeAgentClient(
        resumeEvents: const [
          AgentEvent(
            type: AgentEventType.agentTextDone,
            text: '',
            metadata: {'stopReason': 'maxTokens', 'kind': 'turn'},
          ),
        ],
      ),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    await controller.resumeSession('resumed-session-3');

    expect(controller.messages, hasLength(1));
    expect(controller.messages.single.role, ChatMessageRole.status);
    expect(controller.messages.single.text, contains('token limit'));
    expect(controller.messages.single.metadata['stopReason'], 'maxTokens');
  });

  test('send prompt returns stream chunks appended to one message', () async {
    final controller = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    await controller.newSession();
    await controller.sendPrompt('Hi');
    await pumpEventQueue(times: 12);

    expect(controller.status, app_state.ConnectionStatus.sessionReady);
    expect(controller.isStreaming, isFalse);
    expect(controller.messages, hasLength(2));
    expect(controller.messages.first.role, ChatMessageRole.user);
    expect(controller.messages.first.text, 'Hi');
    expect(controller.messages.last.role, ChatMessageRole.assistant);
    expect(controller.messages.last.text, 'Hello, I am Codex.');
  });

  test(
    'send prompt forwards attachments and renders resource metadata',
    () async {
      final fake = FakeAgentClient();
      final controller = ChatController(client: fake, cwd: '/workspace');
      addTearDown(controller.dispose);
      const attachment = PromptAttachment(
        path: '/workspace/readme.md',
        name: 'readme.md',
        mimeType: 'text/markdown',
        size: 2048,
      );

      await controller.newSession();
      await controller.sendPrompt(
        'Review this file',
        attachments: [attachment],
      );
      await pumpEventQueue(times: 12);

      expect(fake.lastPrompt, 'Review this file');
      expect(fake.lastAttachments, [attachment]);
      expect(controller.messages.first.role, ChatMessageRole.user);
      expect(controller.messages.first.text, 'Review this file');
      expect(controller.messages.first.metadata['contentBlocks'], [
        attachment.toResourceLink(),
      ]);
    },
  );

  test('send prompt error is rendered as error message', () async {
    final controller = ChatController(
      client: FakeAgentClient(promptError: Exception('prompt failed')),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    await controller.newSession();
    await controller.sendPrompt('Hi');
    await pumpEventQueue(times: 4);

    expect(controller.status, app_state.ConnectionStatus.error);
    expect(controller.lastError, contains('prompt failed'));
    expect(controller.messages.last.role, ChatMessageRole.error);
  });

  test('stop cancels streaming', () async {
    final fake = FakeAgentClient(chunkDelay: const Duration(milliseconds: 50));
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    await controller.newSession();
    await controller.sendPrompt('Hi');
    expect(controller.isStreaming, isTrue);

    await controller.stop();

    expect(fake.cancelled, isTrue);
    expect(controller.isStreaming, isFalse);
    expect(controller.status, app_state.ConnectionStatus.sessionReady);
  });

  test('stop still finishes streaming when cancel fails', () async {
    final fake = FakeAgentClient(
      chunkDelay: const Duration(milliseconds: 50),
      cancelError: Exception('cancel failed'),
    );
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    await controller.newSession();
    await controller.sendPrompt('Hi');
    expect(controller.isStreaming, isTrue);

    await controller.stop();

    expect(controller.isStreaming, isFalse);
    expect(controller.status, app_state.ConnectionStatus.sessionReady);
    expect(controller.lastError, contains('cancel failed'));
  });
}

class _OmittingConfigOptionsAgentClient extends FakeAgentClient {
  @override
  Future<List<AcpConfigOption>> setConfigOption({
    required String sessionId,
    required String configId,
    required Object value,
  }) async {
    await super.setConfigOption(
      sessionId: sessionId,
      configId: configId,
      value: value,
    );
    return const <AcpConfigOption>[];
  }
}
