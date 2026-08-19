import 'acp_agent_capabilities.dart';
import 'acp_available_commands.dart';
import 'acp_permission_request.dart';
import 'acp_session_catalog.dart';
import 'acp_session_settings.dart';
import 'agent_event.dart';
import 'agent_session.dart';
import 'prompt_attachment.dart';

typedef AcpSessionRestoreEventObserver = void Function(AgentEvent event);

enum AcpAgentLifecycleEvent { loggedOut }

/// Optional notifications for clients that share one agent-level lifecycle
/// across multiple independently owned session views.
abstract interface class AcpAgentLifecycleEventSource {
  Stream<AcpAgentLifecycleEvent> get lifecycleEvents;
}

/// Optional ownership hooks for clients that isolate multiple local session
/// views over one shared agent connection.
abstract interface class AcpLocalSessionViewOwnership {
  void retainLocalSessionView(String sessionId);

  void releaseLocalSessionView(String sessionId);

  /// Drops an active local view without asking the remote Agent to close it.
  /// Shared clients use this as a generation boundary so late events from the
  /// abandoned view cannot be attached to a later reconnect.
  void abandonLocalSessionView(String sessionId);
}

final class AcpSessionRestoreSummary {
  const AcpSessionRestoreSummary({
    required this.eventCount,
    required this.replayedHistory,
  });

  final int eventCount;
  final bool? replayedHistory;
}

abstract class AcpAgentClient {
  AcpAgentCapabilities? get capabilities;

  /// Whether this client can keep prompts active in multiple sessions and
  /// cancel each prompt independently with [cancelSession].
  bool get supportsConcurrentPrompts => false;

  Stream<AcpPermissionRequest> get permissionRequests;

  Stream<AcpPermissionInvalidation> get permissionInvalidations;

  Stream<AcpAvailableCommandsUpdate> get availableCommandsUpdates;

  Future<AcpAvailableCommandsUpdate?> sessionAvailableCommands(
    String sessionId,
  );

  Future<void> connect();

  Future<AgentSession> createSession({
    required String cwd,
    List<String> additionalDirectories = const <String>[],
  });

  /// Restores a session while allowing consumers to project events without
  /// retaining a second complete replay list. Implementations must honor
  /// `replayHistory: false` whenever `session.resume` is advertised.
  Future<AcpSessionRestoreSummary> restoreSession({
    required String sessionId,
    required String cwd,
    List<String> additionalDirectories = const <String>[],
    bool replayHistory = true,
    required AcpSessionRestoreEventObserver onEvent,
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

  Future<AgentSession> forkSession({
    required String sessionId,
    required String cwd,
    List<String> additionalDirectories = const <String>[],
  });

  Future<void> closeSession({required String sessionId});

  Future<void> deleteSession({required String sessionId});

  Future<void> authenticate({required String methodId});

  Future<void> logout();

  Stream<AgentEvent> sendPrompt({
    required String sessionId,
    required String prompt,
    List<PromptAttachment> attachments = const <PromptAttachment>[],
  });

  Future<void> cancel();

  /// Cancels the active prompt for [sessionId]. Clients advertising
  /// [supportsConcurrentPrompts] must not affect any other session.
  Future<void> cancelSession({required String sessionId}) => cancel();

  Future<void> respondToPermissionRequest({
    required String id,
    required AcpPermissionDecision decision,
    String? selectedOptionId,
  });

  Future<void> dispose();
}
