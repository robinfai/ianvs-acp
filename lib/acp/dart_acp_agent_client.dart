import 'dart:async';
import 'dart:io';

import 'package:dart_acp/dart_acp.dart' as acp;

import 'acp_agent_capabilities.dart';
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
  AcpAgentCapabilities? _capabilities;
  bool _supportsLoadSession = false;
  bool _supportsListSessions = false;
  String? _activeSessionId;

  @override
  AcpAgentCapabilities? get capabilities => _capabilities;

  @override
  Future<void> connect() async {
    await dispose();
    final config = acp.AcpConfig(
      agentCommand: agentCommand,
      agentArgs: agentArgs,
      capabilities: const acp.AcpCapabilities(
        fs: acp.FsCapabilities(readTextFile: false, writeTextFile: false),
      ),
    );
    final client = await acp.AcpClient.start(config: config);
    try {
      final initializeResult = await client.initialize();
      final clientCapabilities = Map<String, dynamic>.from(
        config.capabilities.toJson(),
      );
      if (config.terminalProvider != null) {
        clientCapabilities['terminal'] = true;
      }
      _supportsLoadSession = initializeResult.supportsLoadSession;
      _supportsListSessions = initializeResult.supportsListSessions;
      _capabilities = AcpAgentCapabilities.fromInitialize(
        protocolVersion: initializeResult.protocolVersion,
        agentCapabilities: initializeResult.agentCapabilities,
        authMethods: initializeResult.authMethods,
        clientCapabilities: clientCapabilities,
        hasFsProvider: config.fsProvider != null,
        hasTerminalProvider: config.terminalProvider != null,
        allowReadOutsideWorkspace: config.allowReadOutsideWorkspace,
      );
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
            meta: _metadataMap(session.meta),
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
        final contentBlocks = _contentBlocksFromDelta(update);
        final hasNonTextContent = contentBlocks.any((block) {
          return block['type'] != 'text';
        });
        if (text.isEmpty && !hasNonTextContent) return null;
        if (update.isThought) {
          return AgentEvent(
            type: AgentEventType.status,
            text: text,
            metadata: <String, Object?>{
              'kind': 'thought',
              if (contentBlocks.isNotEmpty) 'contentBlocks': contentBlocks,
            },
            timestamp: DateTime.now(),
          );
        }
        return AgentEvent(
          type: acpRoleToEventType(update.role),
          text: text.isEmpty ? _contentBlocksLabel(contentBlocks) : text,
          metadata: hasNonTextContent
              ? <String, Object?>{'contentBlocks': contentBlocks}
              : const <String, Object?>{},
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
          metadata: <String, Object?>{
            'stopReason': update.stopReason.name,
            'kind': 'turn',
          },
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

  List<Map<String, Object?>> _contentBlocksFromDelta(acp.MessageDelta update) {
    return update.content.map((block) {
      return block.toJson().map(
        (key, value) => MapEntry(key.toString(), value as Object?),
      );
    }).toList();
  }

  String _contentBlocksLabel(List<Map<String, Object?>> blocks) {
    final nonText = blocks.where((block) => block['type'] != 'text').toList();
    if (nonText.isEmpty) return '';
    if (nonText.length == 1) {
      final type = nonText.single['type']?.toString() ?? 'content';
      return 'Received $type content.';
    }
    return 'Received ${nonText.length} content blocks.';
  }

  Map<String, Object?> _metadataMap(Map<String, dynamic>? raw) {
    if (raw == null) return const <String, Object?>{};
    return raw.map((key, value) => MapEntry(key, value as Object?));
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
    _capabilities = null;
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
