import 'acp_agent_capabilities.dart';
import 'acp_agent_client.dart';
import 'acp_permission_request.dart';
import 'acp_session_catalog.dart';
import 'acp_session_settings.dart';
import 'agent_event.dart';
import 'agent_session.dart';
import 'prompt_attachment.dart';

class UnavailableAcpAgentClient implements AcpAgentClient {
  const UnavailableAcpAgentClient({required this.message});

  final String message;

  StateError get _error => StateError(message);

  Future<T> _failure<T>() => Future<T>.error(_error);

  @override
  AcpAgentCapabilities? get capabilities => null;

  @override
  Stream<AcpPermissionRequest> get permissionRequests =>
      const Stream<AcpPermissionRequest>.empty();

  @override
  Future<void> authenticate({required String methodId}) => _failure<void>();

  @override
  Future<void> cancel() async {}

  @override
  Future<void> closeSession({required String sessionId}) => _failure<void>();

  @override
  Future<void> deleteSession({required String sessionId}) => _failure<void>();

  @override
  Future<void> connect() => _failure<void>();

  @override
  Future<AgentSession> createSession({
    required String cwd,
    List<String> additionalDirectories = const <String>[],
  }) => _failure<AgentSession>();

  @override
  Future<void> dispose() async {}

  @override
  Future<AgentSession> forkSession({
    required String sessionId,
    required String cwd,
    List<String> additionalDirectories = const <String>[],
  }) => _failure<AgentSession>();

  @override
  Future<List<AcpProjectSessions>> listSessions() =>
      _failure<List<AcpProjectSessions>>();

  @override
  Future<void> logout() => _failure<void>();

  @override
  Future<void> respondToPermissionRequest({
    required String id,
    required AcpPermissionDecision decision,
  }) => _failure<void>();

  @override
  Future<List<AgentEvent>> resumeSession({
    required String sessionId,
    required String cwd,
    List<String> additionalDirectories = const <String>[],
  }) => _failure<List<AgentEvent>>();

  @override
  Stream<AgentEvent> sendPrompt({
    required String sessionId,
    required String prompt,
    List<PromptAttachment> attachments = const <PromptAttachment>[],
  }) => Stream<AgentEvent>.error(_error);

  @override
  Future<Map<String, Object?>> sendExtensionRequest({
    required String method,
    required Map<String, Object?> params,
  }) => _failure<Map<String, Object?>>();

  @override
  Future<List<AcpConfigOption>> setConfigOption({
    required String sessionId,
    required String configId,
    required Object value,
  }) => _failure<List<AcpConfigOption>>();

  @override
  Future<bool> setSessionMode({
    required String sessionId,
    required String modeId,
  }) => _failure<bool>();

  @override
  Future<AcpSessionSettings> sessionSettings(String sessionId) =>
      _failure<AcpSessionSettings>();
}
