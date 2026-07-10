import 'dart:async';

import 'acp_agent_capabilities.dart';
import 'acp_agent_client.dart';
import 'acp_permission_request.dart';
import 'acp_session_catalog.dart';
import 'acp_session_settings.dart';
import 'agent_event.dart';
import 'agent_session.dart';
import 'prompt_attachment.dart';

class FakeAgentClient implements AcpAgentClient {
  FakeAgentClient({
    this.connectError,
    this.createSessionError,
    this.promptError,
    this.cancelError,
    this.forkError,
    this.closeError,
    this.authenticateError,
    this.logoutError,
    this.extensionError,
    this.permissionResponseError,
    this.extensionResponse = const <String, Object?>{'ok': true},
    this.supportsFork = true,
    this.supportsListSessions = true,
    this.supportsLoadSession = true,
    this.supportsResumeSession = false,
    this.supportsLogout = true,
    this.chunkDelay = Duration.zero,
    this.connectDelay = Duration.zero,
    this.createSessionDelay = Duration.zero,
    this.listSessionsDelay = Duration.zero,
    this.resumeDelay = Duration.zero,
    this.authMethods = const <Map<String, Object?>>[],
    this.createSessionEvents = const <AgentEvent>[],
    this.forkSessionEvents = const <AgentEvent>[],
    this.promptEvents,
    List<AgentEvent>? resumeEvents,
    AcpSessionSettings? sessionSettings,
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
           ],
       _settings = sessionSettings ?? _defaultSessionSettings;

  final Object? connectError;
  final Object? createSessionError;
  final Object? promptError;
  final Object? cancelError;
  final Object? forkError;
  final Object? closeError;
  final Object? authenticateError;
  final Object? logoutError;
  final Object? extensionError;
  final Object? permissionResponseError;
  final Map<String, Object?> extensionResponse;
  final bool supportsFork;
  final bool supportsListSessions;
  final bool supportsLoadSession;
  final bool supportsResumeSession;
  final bool supportsLogout;
  final Duration chunkDelay;
  final Duration connectDelay;
  final Duration createSessionDelay;
  final Duration listSessionsDelay;
  final Duration resumeDelay;
  final List<Map<String, Object?>> authMethods;
  final List<AgentEvent> createSessionEvents;
  final List<AgentEvent> forkSessionEvents;
  final List<AgentEvent>? promptEvents;
  final List<AgentEvent> resumeEvents;
  AcpSessionSettings _settings;

  bool connected = false;
  bool cancelled = false;
  bool loggedOut = false;
  int sessionCount = 0;
  String? lastResumeCwd;
  String? lastSetModeId;
  String? lastConfigId;
  Object? lastConfigValue;
  String? lastPermissionRequestId;
  AcpPermissionDecision? lastPermissionDecision;
  String? lastPermissionOptionId;
  String? lastForkedSessionId;
  String? lastClosedSessionId;
  String? lastAuthenticatedMethodId;
  String? lastExtensionMethod;
  Map<String, Object?>? lastExtensionParams;
  String? lastPrompt;
  List<PromptAttachment> lastAttachments = const <PromptAttachment>[];

  final StreamController<AcpPermissionRequest> _permissionRequests =
      StreamController<AcpPermissionRequest>.broadcast();
  bool _permissionRequestsClosed = false;

  @override
  AcpAgentCapabilities? get capabilities => connected
      ? AcpAgentCapabilities(
          protocolVersion: 1,
          loadSession: supportsLoadSession,
          prompt: const AcpPromptCapabilities(
            image: true,
            audio: false,
            embeddedContext: true,
          ),
          mcp: const AcpMcpCapabilities(http: true, sse: false, acp: false),
          session: AcpSessionCapabilities(
            list: supportsListSessions,
            resume: supportsResumeSession,
            fork: supportsFork,
            configOptions: true,
            additionalDirectories: true,
            close: true,
            rawKeys: [
              'additionalDirectories',
              'close',
              'configOptions',
              if (supportsFork) 'fork',
              if (supportsListSessions) 'list',
              if (supportsResumeSession) 'resume',
            ],
          ),
          auth: AcpAuthCapabilities(logout: supportsLogout),
          client: const AcpClientCapabilities(
            fsReadTextFile: false,
            fsWriteTextFile: false,
            terminal: false,
            hasFsProvider: false,
            hasTerminalProvider: false,
            allowReadOutsideWorkspace: false,
          ),
          rawAgentCapabilities: <String, Object?>{
            if (supportsLogout) 'auth': <String, Object?>{'logout': true},
          },
          authMethods: authMethods,
        )
      : null;

  @override
  Stream<AcpPermissionRequest> get permissionRequests =>
      _permissionRequests.stream;

  static const AcpSessionSettings _defaultSessionSettings = AcpSessionSettings(
    modes: AcpSessionModeInfo(
      currentModeId: 'ask',
      availableModes: [
        AcpSessionMode(id: 'ask', name: 'Ask'),
        AcpSessionMode(id: 'edit', name: 'Edit'),
      ],
    ),
    configOptions: [
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

  @override
  Future<void> connect() async {
    if (connectDelay > Duration.zero) {
      await Future<void>.delayed(connectDelay);
    }
    if (connectError != null) {
      throw connectError!;
    }
    connected = true;
  }

  @override
  Future<AgentSession> createSession({
    required String cwd,
    List<String> additionalDirectories = const <String>[],
  }) async {
    if (!connected) {
      throw StateError('Fake client is not connected.');
    }
    if (createSessionDelay > Duration.zero) {
      await Future<void>.delayed(createSessionDelay);
    }
    if (createSessionError != null) {
      throw createSessionError!;
    }
    sessionCount += 1;
    return AgentSession(
      id: 'fake-session-$sessionCount',
      cwd: cwd,
      createdAt: DateTime(2026, 5, 28, 12),
      additionalDirectories: additionalDirectories,
      initialEvents: createSessionEvents,
    );
  }

  @override
  Future<List<AgentEvent>> resumeSession({
    required String sessionId,
    required String cwd,
    List<String> additionalDirectories = const <String>[],
  }) async {
    if (!connected) {
      throw StateError('Fake client is not connected.');
    }
    if (!supportsLoadSession && !supportsResumeSession) {
      throw StateError('Fake client does not support session load or resume.');
    }
    if (resumeDelay > Duration.zero) {
      await Future<void>.delayed(resumeDelay);
    }
    lastResumeCwd = cwd;
    return resumeEvents;
  }

  @override
  Future<List<AcpProjectSessions>> listSessions() async {
    if (!connected) {
      throw StateError('Fake client is not connected.');
    }
    if (!supportsListSessions) {
      throw StateError('Fake client does not support session/list.');
    }
    if (listSessionsDelay > Duration.zero) {
      await Future<void>.delayed(listSessionsDelay);
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
  Future<AcpSessionSettings> sessionSettings(String sessionId) async {
    if (!connected) {
      throw StateError('Fake client is not connected.');
    }
    return _settings;
  }

  @override
  Future<bool> setSessionMode({
    required String sessionId,
    required String modeId,
  }) async {
    if (!connected) {
      throw StateError('Fake client is not connected.');
    }
    lastSetModeId = modeId;
    _settings = _settings.withCurrentMode(modeId);
    return true;
  }

  @override
  Future<List<AcpConfigOption>> setConfigOption({
    required String sessionId,
    required String configId,
    required Object value,
  }) async {
    if (!connected) {
      throw StateError('Fake client is not connected.');
    }
    lastConfigId = configId;
    lastConfigValue = value;
    final options = _settings.configOptions.map((option) {
      return option.id == configId
          ? option.copyWith(currentValue: value)
          : option;
    }).toList();
    _settings = _settings.copyWith(configOptions: options);
    return options;
  }

  @override
  Future<AgentSession> forkSession({
    required String sessionId,
    required String cwd,
    List<String> additionalDirectories = const <String>[],
  }) async {
    if (!connected) {
      throw StateError('Fake client is not connected.');
    }
    if (!supportsFork) {
      throw StateError('Fake client does not support fork.');
    }
    if (forkError != null) {
      throw forkError!;
    }
    lastForkedSessionId = sessionId;
    sessionCount += 1;
    return AgentSession(
      id: 'fake-fork-$sessionCount',
      cwd: cwd,
      createdAt: DateTime(2026, 5, 28, 12),
      additionalDirectories: additionalDirectories,
      initialEvents: forkSessionEvents,
    );
  }

  @override
  Future<void> closeSession({required String sessionId}) async {
    if (!connected) {
      throw StateError('Fake client is not connected.');
    }
    if (closeError != null) {
      throw closeError!;
    }
    lastClosedSessionId = sessionId;
  }

  @override
  Future<void> authenticate({required String methodId}) async {
    if (!connected) {
      throw StateError('Fake client is not connected.');
    }
    if (!authMethods.any((method) {
      final id = method['id'];
      return id is String && id.trim() == methodId;
    })) {
      throw StateError('Fake client does not support auth method "$methodId".');
    }
    if (authenticateError != null) {
      throw authenticateError!;
    }
    lastAuthenticatedMethodId = methodId;
  }

  @override
  Future<void> logout() async {
    if (!connected) {
      throw StateError('Fake client is not connected.');
    }
    if (!supportsLogout) {
      throw StateError('Fake client does not support logout.');
    }
    if (logoutError != null) {
      throw logoutError!;
    }
    loggedOut = true;
  }

  @override
  Future<Map<String, Object?>> sendExtensionRequest({
    required String method,
    required Map<String, Object?> params,
  }) async {
    if (!connected) {
      throw StateError('Fake client is not connected.');
    }
    if (!method.startsWith('_')) {
      throw ArgumentError.value(
        method,
        'method',
        'Extension methods must start with underscore (_).',
      );
    }
    if (extensionError != null) {
      throw extensionError!;
    }
    lastExtensionMethod = method;
    lastExtensionParams = params;
    return extensionResponse;
  }

  @override
  Stream<AgentEvent> sendPrompt({
    required String sessionId,
    required String prompt,
    List<PromptAttachment> attachments = const <PromptAttachment>[],
  }) async* {
    lastPrompt = prompt;
    lastAttachments = attachments;
    if (promptError != null) {
      throw promptError!;
    }
    final customEvents = promptEvents;
    if (customEvents != null) {
      for (final event in customEvents) {
        if (cancelled) break;
        if (chunkDelay > Duration.zero) {
          await Future<void>.delayed(chunkDelay);
        }
        yield event;
      }
      return;
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
    if (cancelError != null) {
      throw cancelError!;
    }
    cancelled = true;
  }

  void emitPermissionRequest(AcpPermissionRequest request) {
    _permissionRequests.add(request);
  }

  Future<void> closePermissionRequests() async {
    if (_permissionRequestsClosed) return;
    _permissionRequestsClosed = true;
    await _permissionRequests.close();
  }

  @override
  Future<void> respondToPermissionRequest({
    required String id,
    required AcpPermissionDecision decision,
    String? selectedOptionId,
  }) async {
    lastPermissionRequestId = id;
    lastPermissionDecision = decision;
    lastPermissionOptionId = selectedOptionId;
    if (permissionResponseError != null) {
      throw permissionResponseError!;
    }
  }

  @override
  Future<void> dispose() async {
    connected = false;
    await closePermissionRequests();
  }
}
