import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/agent_event.dart';
import 'package:ianvs_acp/acp/fake_agent_client.dart';
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
    expect(controller.sessions, hasLength(1));
    expect(controller.sessionSettings.modes.currentModeId, 'ask');
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
    expect(controller.sessions, hasLength(1));
    expect(controller.messages.map((message) => message.role), [
      ChatMessageRole.user,
      ChatMessageRole.assistant,
      ChatMessageRole.tool,
      ChatMessageRole.status,
    ]);
    expect(controller.messages[1].text, contains('medium-sized transcript'));
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
}
