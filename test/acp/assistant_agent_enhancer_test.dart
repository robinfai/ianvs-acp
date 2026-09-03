import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/acp_session_settings.dart';
import 'package:ianvs_acp/acp/agent_event.dart';
import 'package:ianvs_acp/acp/assistant_agent_enhancer.dart';
import 'package:ianvs_acp/acp/fake_agent_client.dart';
import 'package:ianvs_acp/acp/prompt_attachment.dart';
import 'package:ianvs_acp/config/assistant_agent_config.dart';

void main() {
  const config = AssistantAgentConfig(
    enabled: true,
    agentName: 'helper',
    timeout: Duration(seconds: 2),
  );

  test('discovers the helper model selector through an ACP session', () async {
    final client = FakeAgentClient(
      sessionSettings: const AcpSessionSettings(
        configOptions: [
          AcpConfigOption(
            id: 'model',
            name: 'Model',
            type: 'select',
            currentValue: 'model-a',
            options: [
              AcpConfigOptionChoice(value: 'model-a', name: 'Model A'),
              AcpConfigOptionChoice(value: 'model-b', name: 'Model B'),
            ],
          ),
        ],
      ),
    );
    final enhancer = AcpAssistantAgentEnhancer(
      client,
      '/workspace',
      config: config,
    );
    addTearDown(enhancer.dispose);

    final option = await enhancer.discoverModelOption();

    expect(option?.id, 'model');
    expect(option?.options.map((choice) => choice.value), [
      'model-a',
      'model-b',
    ]);
    expect(client.lastClosedSessionId, 'fake-session-1');
  });

  test('accepts a done-only helper response', () async {
    final client = _ScriptedAssistantClient(<List<AgentEvent>>[
      <AgentEvent>[_event(AgentEventType.agentTextDone, 'Done-only title')],
    ]);
    final enhancer = AcpAssistantAgentEnhancer(
      client,
      '/workspace',
      config: config,
    );
    addTearDown(enhancer.dispose);

    final result = await enhancer.generateSessionTitle(
      sessionId: 'primary-session',
      firstPrompt: 'Build it',
    );

    expect(result, 'Done-only title');
    expect(client.closedSessions, 1);
  });

  test(
    'closes an oversized multi-delta title and recovers next review',
    () async {
      final client = _ScriptedAssistantClient(<List<AgentEvent>>[
        <AgentEvent>[
          _event(
            AgentEventType.agentTextDelta,
            List<String>.filled(700, 'a').join(),
          ),
          _event(
            AgentEventType.agentTextDelta,
            List<String>.filled(400, 'b').join(),
          ),
        ],
        <AgentEvent>[_event(AgentEventType.agentTextDone, 'Recovered title')],
      ]);
      final enhancer = AcpAssistantAgentEnhancer(
        client,
        '/workspace',
        config: config,
      );
      addTearDown(enhancer.dispose);

      final oversized = await enhancer.generateSessionTitle(
        sessionId: 'primary-session',
        firstPrompt: 'Build it',
      );
      final recovered = await enhancer.generateSessionTitle(
        sessionId: 'primary-session',
        firstPrompt: 'Build it safely',
      );

      expect(oversized, isNull);
      expect(recovered, 'Recovered title');
      expect(client.closedSessions, 2);
    },
  );

  test('rejects an oversized single-delta summary', () async {
    final client = _ScriptedAssistantClient(<List<AgentEvent>>[
      <AgentEvent>[
        _event(
          AgentEventType.agentTextDelta,
          List<String>.filled(16 * 1024 + 1, 'x').join(),
        ),
      ],
    ]);
    final enhancer = AcpAssistantAgentEnhancer(
      client,
      '/workspace',
      config: config,
    );
    addTearDown(enhancer.dispose);

    final result = await enhancer.summarizeTurn(
      const AssistantTurnSummaryRequest(
        sessionId: 'primary-session',
        turnId: 1,
        userPrompt: 'Build it',
        completedTurn: 'Built it',
      ),
    );

    expect(result, isNull);
    expect(client.closedSessions, 1);
  });

  test('counts multibyte title deltas by UTF-8 bytes', () async {
    final exact = List<String>.filled(256, '😀').join();
    final client = _ScriptedAssistantClient(<List<AgentEvent>>[
      <AgentEvent>[
        _event(AgentEventType.agentTextDelta, exact.substring(0, 1)),
        _event(AgentEventType.agentTextDelta, exact.substring(1)),
        _event(AgentEventType.agentTextDone, exact),
      ],
      <AgentEvent>[
        _event(
          AgentEventType.agentTextDone,
          '${List<String>.filled(256, '😀').join()}x',
        ),
      ],
    ]);
    final enhancer = AcpAssistantAgentEnhancer(
      client,
      '/workspace',
      config: config,
    );
    addTearDown(enhancer.dispose);

    final atLimit = await enhancer.generateSessionTitle(
      sessionId: 'primary-session',
      firstPrompt: 'Build it',
    );
    final overLimit = await enhancer.generateSessionTitle(
      sessionId: 'primary-session',
      firstPrompt: 'Build it again',
    );

    expect(atLimit, exact);
    expect(overLimit, isNull);
    expect(client.closedSessions, 2);
  });
}

AgentEvent _event(AgentEventType type, String text) =>
    AgentEvent(type: type, text: text, timestamp: DateTime.utc(2026, 8, 11));

final class _ScriptedAssistantClient extends FakeAgentClient {
  _ScriptedAssistantClient(this.responses);

  final List<List<AgentEvent>> responses;
  var promptCalls = 0;
  var closedSessions = 0;

  @override
  Stream<AgentEvent> sendPrompt({
    required String sessionId,
    required String prompt,
    List<PromptAttachment> attachments = const <PromptAttachment>[],
  }) async* {
    final index = promptCalls;
    promptCalls += 1;
    for (final event in responses[index]) {
      yield event;
    }
  }

  @override
  Future<void> closeSession({required String sessionId}) async {
    await super.closeSession(sessionId: sessionId);
    closedSessions += 1;
  }
}
