import 'acp_agent_capabilities.dart';
import 'acp_session_catalog.dart';
import 'acp_session_settings.dart';
import 'agent_event.dart';
import 'agent_session.dart';
import 'prompt_attachment.dart';

abstract class AcpAgentClient {
  AcpAgentCapabilities? get capabilities;

  Future<void> connect();

  Future<AgentSession> createSession({required String cwd});

  Future<List<AgentEvent>> resumeSession({
    required String sessionId,
    required String cwd,
  });

  Future<List<AcpProjectSessions>> listSessions();

  Future<AcpSessionSettings> sessionSettings(String sessionId);

  Future<bool> setSessionMode({
    required String sessionId,
    required String modeId,
  });

  Future<List<AcpConfigOption>> setConfigOption({
    required String sessionId,
    required String configId,
    required Object value,
  });

  Future<void> closeSession({required String sessionId});

  Future<void> logout();

  Stream<AgentEvent> sendPrompt({
    required String sessionId,
    required String prompt,
    List<PromptAttachment> attachments = const <PromptAttachment>[],
  });

  Future<void> cancel();

  Future<void> dispose();
}
