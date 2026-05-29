import 'dart:async';

import 'acp_agent_client.dart';
import 'acp_session_catalog.dart';
import 'agent_event.dart';
import 'agent_session.dart';

class FakeAgentClient implements AcpAgentClient {
  FakeAgentClient({
    this.connectError,
    this.promptError,
    this.chunkDelay = Duration.zero,
    List<AgentEvent>? resumeEvents,
  }) : resumeEvents =
           resumeEvents ??
           const [
             AgentEvent(
               type: AgentEventType.userMessage,
               text: 'Resume this Codex session and summarize the UI state.',
             ),
             AgentEvent(
               type: AgentEventType.agentTextDelta,
               text:
                   'The resumed Codex session contains a medium-sized transcript '
                   'with toolbar state, sidebar metadata, streamed assistant text, '
                   'tool/status rows, and a final response suitable for checking '
                   'timeline wrapping and scroll behavior.',
             ),
             AgentEvent(
               type: AgentEventType.toolCall,
               text: '[Tool: inspect project] completed',
             ),
             AgentEvent(
               type: AgentEventType.status,
               text: '[Session replayed]',
             ),
           ];

  final Object? connectError;
  final Object? promptError;
  final Duration chunkDelay;
  final List<AgentEvent> resumeEvents;

  bool connected = false;
  bool cancelled = false;
  int sessionCount = 0;
  String? lastResumeCwd;

  @override
  Future<void> connect() async {
    if (connectError != null) {
      throw connectError!;
    }
    connected = true;
  }

  @override
  Future<AgentSession> createSession({required String cwd}) async {
    if (!connected) {
      throw StateError('Fake client is not connected.');
    }
    sessionCount += 1;
    return AgentSession(
      id: 'fake-session-$sessionCount',
      cwd: cwd,
      createdAt: DateTime(2026, 5, 28, 12),
    );
  }

  @override
  Future<List<AgentEvent>> resumeSession({
    required String sessionId,
    required String cwd,
  }) async {
    if (!connected) {
      throw StateError('Fake client is not connected.');
    }
    lastResumeCwd = cwd;
    return resumeEvents;
  }

  @override
  Future<List<AcpProjectSessions>> listSessions() async {
    if (!connected) {
      throw StateError('Fake client is not connected.');
    }
    return [
      AcpProjectSessions(
        cwd: '/workspace/project-a',
        sessions: [
          AcpSessionEntry(
            id: 'session-a',
            cwd: '/workspace/project-a',
            title: 'Resume this project conversation',
            updatedAt: DateTime(2026, 5, 28, 12),
          ),
        ],
      ),
    ];
  }

  @override
  Stream<AgentEvent> sendPrompt({
    required String sessionId,
    required String prompt,
  }) async* {
    if (promptError != null) {
      throw promptError!;
    }
    for (final chunk in const ['Hello', ',', ' I am Codex', '.']) {
      if (cancelled) break;
      if (chunkDelay > Duration.zero) {
        await Future<void>.delayed(chunkDelay);
      }
      yield AgentEvent(
        type: AgentEventType.agentTextDelta,
        text: chunk,
        timestamp: DateTime(2026, 5, 28, 12),
      );
    }
    yield AgentEvent(
      type: AgentEventType.agentTextDone,
      text: '',
      timestamp: DateTime(2026, 5, 28, 12),
    );
  }

  @override
  Future<void> cancel() async {
    cancelled = true;
  }

  @override
  Future<void> dispose() async {
    connected = false;
  }
}
