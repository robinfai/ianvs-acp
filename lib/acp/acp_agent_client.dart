import 'acp_session_catalog.dart';
import 'agent_event.dart';
import 'agent_session.dart';

abstract class AcpAgentClient {
  Future<void> connect();

  Future<AgentSession> createSession({required String cwd});

  Future<List<AgentEvent>> resumeSession({
    required String sessionId,
    required String cwd,
  });

  Future<List<AcpProjectSessions>> listSessions();

  Stream<AgentEvent> sendPrompt({
    required String sessionId,
    required String prompt,
  });

  Future<void> cancel();

  Future<void> dispose();
}
