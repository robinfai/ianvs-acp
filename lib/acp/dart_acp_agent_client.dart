import 'dart:async';
import 'dart:io';

import 'package:dart_acp/dart_acp.dart' as acp;

import 'acp_agent_client.dart';
import 'acp_session_catalog.dart';
import 'agent_event.dart';
import 'agent_session.dart';

class DartAcpAgentClient implements AcpAgentClient {
  DartAcpAgentClient({String? agentCommand, List<String>? agentArgs})
    : agentCommand = agentCommand ?? _defaultAgentCommand(),
      agentArgs = agentArgs ?? const ['@zed-industries/codex-acp'];

  final String agentCommand;
  final List<String> agentArgs;

  acp.AcpClient? _client;
  bool _supportsLoadSession = false;
  bool _supportsListSessions = false;
  String? _activeSessionId;

  @override
  Future<void> connect() async {
    await dispose();
    final client = await acp.AcpClient.start(
      config: acp.AcpConfig(agentCommand: agentCommand, agentArgs: agentArgs),
    );
    try {
      final initializeResult = await client.initialize();
      _supportsLoadSession = initializeResult.supportsLoadSession;
      _supportsListSessions = initializeResult.supportsListSessions;
    } catch (_) {
      await client.dispose();
      rethrow;
    }
    _client = client;
  }

  @override
  Future<AgentSession> createSession({required String cwd}) async {
    final client = _requireClient();
    final sessionId = await client.newSession(cwd);
    _activeSessionId = sessionId;
    return AgentSession(id: sessionId, cwd: cwd, createdAt: DateTime.now());
  }

  @override
  Future<List<AgentEvent>> resumeSession({
    required String sessionId,
    required String cwd,
  }) async {
    final client = _requireClient();
    if (!_supportsLoadSession) {
      throw StateError('Codex ACP agent does not support session/load.');
    }

    final events = <AgentEvent>[];
    final subscription = client.sessionUpdates(sessionId).listen((update) {
      final event = _eventFromAcpUpdate(update);
      if (event != null) {
        events.add(event);
      }
    });
    try {
      await client.loadSession(sessionId: sessionId, workspaceRoot: cwd);
      await Future<void>.delayed(Duration.zero);
      _activeSessionId = sessionId;
      return events;
    } finally {
      await subscription.cancel();
    }
  }

  @override
  Future<List<AcpProjectSessions>> listSessions() async {
    final client = _requireClient();
    if (!_supportsListSessions) {
      throw StateError('ACP agent does not support session/list.');
    }

    final sessions = <AcpSessionEntry>[];
    final seenCursors = <String>{};
    String? cursor;
    do {
      final result = await client.listSessions(cursor: cursor);
      sessions.addAll(
        result.sessions.map((session) {
          return AcpSessionEntry(
            id: session.sessionId,
            cwd: session.cwd,
            title: session.title?.trim().isNotEmpty == true
                ? session.title!.trim()
                : session.sessionId,
            updatedAt: session.updatedAt?.toLocal(),
          );
        }),
      );

      final nextCursor = result.nextCursor;
      if (nextCursor == null || !seenCursors.add(nextCursor)) break;
      cursor = nextCursor;
    } while (true);

    return groupAcpSessionsByProject(sessions);
  }

  @override
  Stream<AgentEvent> sendPrompt({
    required String sessionId,
    required String prompt,
  }) async* {
    final client = _requireClient();
    _activeSessionId = sessionId;
    try {
      await for (final update in client.prompt(
        sessionId: sessionId,
        content: prompt,
      )) {
        final event = _eventFromAcpUpdate(update);
        if (event != null) {
          yield event;
        }
      }
    } catch (error) {
      yield AgentEvent(
        type: AgentEventType.error,
        text: error.toString(),
        timestamp: DateTime.now(),
      );
    }
  }

  AgentEventType acpRoleToEventType(String role) {
    return role == 'user'
        ? AgentEventType.userMessage
        : AgentEventType.agentTextDelta;
  }

  AgentEvent? _eventFromAcpUpdate(acp.AcpUpdate update) {
    switch (update) {
      case acp.MessageDelta():
        final text = update.text;
        if (text.isEmpty) return null;
        return AgentEvent(
          type: acpRoleToEventType(update.role),
          text: text,
          timestamp: DateTime.now(),
        );
      case acp.ToolCallUpdate():
        final toolCall = update.toolCall;
        return AgentEvent(
          type: AgentEventType.toolCall,
          text: toolCall.title ?? toolCall.toolCallId,
          metadata: <String, Object?>{'kind': 'tool', ...toolCall.toJson()},
          timestamp: DateTime.now(),
        );
      case acp.TurnEnded():
        return AgentEvent(
          type: AgentEventType.agentTextDone,
          text: '',
          timestamp: DateTime.now(),
        );
      case acp.PlanUpdate():
        final plan = update.plan;
        final text = plan.title ?? 'Plan update';
        return AgentEvent(
          type: AgentEventType.status,
          text: text,
          metadata: <String, Object?>{
            'kind': 'plan',
            'title': plan.title,
            'description': plan.description,
            'entries': plan.entries.map((entry) => entry.toJson()).toList(),
          },
          timestamp: DateTime.now(),
        );
      case acp.DiffUpdate():
        final diff = update.diff;
        return AgentEvent(
          type: AgentEventType.status,
          text: diff.uri ?? diff.id,
          metadata: <String, Object?>{'kind': 'diff', ...diff.toJson()},
          timestamp: DateTime.now(),
        );
      case acp.AvailableCommandsUpdate():
        final commands = update.commands;
        return AgentEvent(
          type: AgentEventType.status,
          text: commands.isEmpty
              ? 'No available commands'
              : commands.map((command) => command.name).join(', '),
          metadata: <String, Object?>{
            'kind': 'commands',
            'commands': commands.map((command) => command.toJson()).toList(),
          },
          timestamp: DateTime.now(),
        );
      case acp.ModeUpdate():
        return AgentEvent(
          type: AgentEventType.status,
          text: update.currentModeId,
          metadata: <String, Object?>{
            'kind': 'mode',
            'mode': update.currentModeId,
          },
          timestamp: DateTime.now(),
        );
      case acp.UnknownUpdate():
        final text = update.text;
        if (text.isEmpty) return null;
        return AgentEvent(
          type: AgentEventType.status,
          text: text,
          metadata: <String, Object?>{'kind': 'unknown'},
          timestamp: DateTime.now(),
        );
    }
  }

  @override
  Future<void> cancel() async {
    final sessionId = _activeSessionId;
    final client = _client;
    if (client == null || sessionId == null) return;
    await client.cancel(sessionId: sessionId);
  }

  @override
  Future<void> dispose() async {
    final client = _client;
    _client = null;
    _supportsLoadSession = false;
    _supportsListSessions = false;
    _activeSessionId = null;
    await client?.dispose();
  }

  acp.AcpClient _requireClient() {
    final client = _client;
    if (client == null) {
      throw StateError('Codex ACP client is not connected.');
    }
    return client;
  }

  static String _defaultAgentCommand() {
    for (final path in const ['/opt/homebrew/bin/npx', '/usr/local/bin/npx']) {
      if (File(path).existsSync()) {
        return path;
      }
    }
    return 'npx';
  }
}
