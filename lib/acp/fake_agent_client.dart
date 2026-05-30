import 'dart:async';

import 'acp_agent_capabilities.dart';
import 'acp_agent_client.dart';
import 'acp_session_catalog.dart';
import 'acp_session_settings.dart';
import 'agent_event.dart';
import 'agent_session.dart';
import 'prompt_attachment.dart';

class FakeAgentClient implements AcpAgentClient {
  FakeAgentClient({
    this.connectError,
    this.promptError,
    this.cancelError,
    this.closeError,
    this.logoutError,
    this.supportsLogout = true,
    this.chunkDelay = Duration.zero,
    this.connectDelay = Duration.zero,
    this.createSessionDelay = Duration.zero,
    this.resumeDelay = Duration.zero,
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
  final Object? promptError;
  final Object? cancelError;
  final Object? closeError;
  final Object? logoutError;
  final bool supportsLogout;
  final Duration chunkDelay;
  final Duration connectDelay;
  final Duration createSessionDelay;
  final Duration resumeDelay;
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
  String? lastClosedSessionId;
  String? lastPrompt;
  List<PromptAttachment> lastAttachments = const <PromptAttachment>[];

  @override
  AcpAgentCapabilities? get capabilities => connected
      ? AcpAgentCapabilities(
          protocolVersion: 1,
          loadSession: true,
          prompt: const AcpPromptCapabilities(
            image: true,
            audio: false,
            embeddedContext: true,
          ),
          mcp: const AcpMcpCapabilities(http: true, sse: false, acp: false),
          session: const AcpSessionCapabilities(
            list: true,
            resume: false,
            fork: false,
            configOptions: true,
            close: true,
            rawKeys: ['close', 'configOptions', 'list'],
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
          authMethods: const <Map<String, Object?>>[],
        )
      : null;

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
  Future<AgentSession> createSession({required String cwd}) async {
    if (!connected) {
      throw StateError('Fake client is not connected.');
    }
    if (createSessionDelay > Duration.zero) {
      await Future<void>.delayed(createSessionDelay);
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

  @override
  Future<void> dispose() async {
    connected = false;
  }
}
