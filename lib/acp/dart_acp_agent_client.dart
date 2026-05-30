import 'dart:async';
import 'dart:io';

import 'package:dart_acp/dart_acp.dart' as acp;

import 'acp_agent_capabilities.dart';
import 'acp_agent_client.dart';
import 'acp_session_catalog.dart';
import 'acp_session_settings.dart';
import 'agent_event.dart';
import 'agent_session.dart';
import 'prompt_attachment.dart';

class DartAcpAgentClient implements AcpAgentClient {
  DartAcpAgentClient({
    String? agentCommand,
    List<String>? agentArgs,
    Map<String, String>? envOverrides,
    List<Map<String, dynamic>>? mcpServers,
  }) : agentCommand = agentCommand ?? _defaultAgentCommand(),
       agentArgs = agentArgs ?? const ['@zed-industries/codex-acp'],
       envOverrides = envOverrides ?? const <String, String>{},
       mcpServers = mcpServers == null
           ? const <Map<String, dynamic>>[]
           : List.unmodifiable(mcpServers.map(Map<String, dynamic>.from));

  final String agentCommand;
  final List<String> agentArgs;
  final Map<String, String> envOverrides;
  final List<Map<String, dynamic>> mcpServers;

  acp.AcpClient? _client;
  AcpAgentCapabilities? _capabilities;
  bool _supportsLoadSession = false;
  bool _supportsListSessions = false;
  bool _supportsResumeSession = false;
  String? _activeSessionId;
  final Map<String, String> _modeOverridesBySession = <String, String>{};
  final Map<String, List<AcpConfigOption>> _configOptionsBySession =
      <String, List<AcpConfigOption>>{};

  @override
  AcpAgentCapabilities? get capabilities => _capabilities;

  @override
  Future<void> connect() async {
    await dispose();
    final config = acp.AcpConfig(
      agentCommand: agentCommand,
      agentArgs: agentArgs,
      envOverrides: envOverrides,
      mcpServers: mcpServers.map(Map<String, dynamic>.from).toList(),
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
      _supportsResumeSession = initializeResult.supportsResumeSession;
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
    if (!_supportsLoadSession && !_supportsResumeSession) {
      throw StateError(
        'ACP agent does not support session/load or session/resume.',
      );
    }

    final events = <AgentEvent>[];
    if (!_supportsLoadSession) {
      final result = await client.resumeSession(
        sessionId: sessionId,
        workspaceRoot: cwd,
      );
      _activeSessionId = sessionId;
      _cacheConfigOptions(sessionId, result.configOptions);
      return events;
    }

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
  Future<AcpSessionSettings> sessionSettings(String sessionId) async {
    final client = _requireClient();
    final modes = client.sessionModes(sessionId);
    final currentModeId =
        _modeOverridesBySession[sessionId] ?? modes?.currentModeId;
    final availableModes =
        modes?.availableModes
            .map((mode) => AcpSessionMode(id: mode.id, name: mode.name))
            .where((mode) => mode.id.isNotEmpty)
            .toList() ??
        const <AcpSessionMode>[];

    return AcpSessionSettings(
      modes: AcpSessionModeInfo(
        currentModeId: currentModeId,
        availableModes: availableModes,
      ),
      configOptions:
          _configOptionsBySession[sessionId] ?? const <AcpConfigOption>[],
    );
  }

  @override
  Future<bool> setSessionMode({
    required String sessionId,
    required String modeId,
  }) async {
    final client = _requireClient();
    final didSet = await client.setMode(sessionId: sessionId, modeId: modeId);
    if (didSet) {
      _modeOverridesBySession[sessionId] = modeId;
    }
    return didSet;
  }

  @override
  Future<List<AcpConfigOption>> setConfigOption({
    required String sessionId,
    required String configId,
    required Object value,
  }) async {
    final client = _requireClient();
    final params = <String, dynamic>{
      'sessionId': sessionId,
      'configId': configId,
    };
    if (value is bool) {
      params['type'] = 'boolean';
      params['value'] = value;
    } else {
      params['value'] = value.toString();
    }
    final response = await client.sendRaw('session/set_config_option', params);
    final configOptions = response['configOptions'];
    if (configOptions is List) {
      return _cacheRawConfigOptions(sessionId, configOptions);
    }
    return _applyConfigOptionOverride(sessionId, configId, value);
  }

  @override
  Future<AgentSession> forkSession({
    required String sessionId,
    required String cwd,
  }) async {
    final client = _requireClient();
    if (_capabilities?.session.fork != true) {
      throw StateError('ACP agent does not support session/fork.');
    }
    final result = await client.forkSession(sessionId: sessionId);
    _activeSessionId = result.sessionId;
    final configOptions = result.configOptions;
    if (configOptions != null) {
      _cacheConfigOptions(result.sessionId, configOptions);
    }
    return AgentSession(
      id: result.sessionId,
      cwd: cwd,
      createdAt: DateTime.now(),
    );
  }

  @override
  Future<void> closeSession({required String sessionId}) async {
    final client = _requireClient();
    if (_capabilities?.session.close != true) {
      throw StateError('ACP agent does not support session/close.');
    }
    await client.sendRaw('session/close', <String, dynamic>{
      'sessionId': sessionId,
    });
    if (_activeSessionId == sessionId) {
      _activeSessionId = null;
    }
    _modeOverridesBySession.remove(sessionId);
    _configOptionsBySession.remove(sessionId);
  }

  @override
  Future<void> logout() async {
    final client = _requireClient();
    if (_capabilities?.auth.logout != true) {
      throw StateError('ACP agent does not support logout.');
    }
    await client.sendRaw('logout', const <String, dynamic>{});
    _activeSessionId = null;
    _modeOverridesBySession.clear();
    _configOptionsBySession.clear();
  }

  @override
  Stream<AgentEvent> sendPrompt({
    required String sessionId,
    required String prompt,
    List<PromptAttachment> attachments = const <PromptAttachment>[],
  }) async* {
    final client = _requireClient();
    _activeSessionId = sessionId;
    final content = _promptWithAttachments(prompt, attachments);
    try {
      await for (final update in client.prompt(
        sessionId: sessionId,
        content: content,
      )) {
        final event = _eventFromAcpUpdate(update, includeUserMessages: false);
        if (event != null) {
          yield event;
        }
      }
    } catch (error) {
      final details = _agentErrorDetails(error);
      yield AgentEvent(
        type: AgentEventType.error,
        text: details.text,
        metadata: details.metadata,
        timestamp: DateTime.now(),
      );
    }
  }

  AgentEventType acpRoleToEventType(String role) {
    return role == 'user'
        ? AgentEventType.userMessage
        : AgentEventType.agentTextDelta;
  }

  AgentEvent? _eventFromAcpUpdate(
    acp.AcpUpdate update, {
    bool includeUserMessages = true,
  }) {
    switch (update) {
      case acp.MessageDelta():
        if (update.role == 'user' && !includeUserMessages) return null;
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
        if (update.currentModeId.isNotEmpty && _activeSessionId != null) {
          _modeOverridesBySession[_activeSessionId!] = update.currentModeId;
        }
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
        final mapped = _eventFromUnknownUpdate(update);
        if (mapped != null) return mapped;
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

  AgentEvent? _eventFromUnknownUpdate(acp.UnknownUpdate update) {
    final raw = update.raw;
    final sessionId = raw['sessionId'];
    final body = raw['update'];
    if (body is! Map<String, dynamic>) return null;

    final kind = body['sessionUpdate'];
    if (kind == 'config_option_update') {
      final options = _configOptionsFromRaw(body['configOptions']);
      if (sessionId is String && sessionId.isNotEmpty) {
        _configOptionsBySession[sessionId] = options;
      }
      return AgentEvent(
        type: AgentEventType.status,
        text: 'Session config options updated.',
        metadata: <String, Object?>{
          'kind': 'config_option_update',
          'configOptions': options,
        },
        timestamp: DateTime.now(),
      );
    }

    if (kind == 'session_info_update') {
      final title = body['title'];
      final updatedAt = body['updatedAt'];
      final meta = body['_meta'];
      return AgentEvent(
        type: AgentEventType.status,
        text: title is String && title.trim().isNotEmpty
            ? title.trim()
            : 'Session info updated.',
        metadata: <String, Object?>{
          'kind': 'session_info_update',
          if (sessionId is String) 'sessionId': sessionId,
          if (title is String) 'title': title,
          if (updatedAt is String) 'updatedAt': updatedAt,
          if (meta is Map) 'meta': _metadataMap(meta),
        },
        timestamp: DateTime.now(),
      );
    }

    return null;
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

  String _promptWithAttachments(
    String prompt,
    List<PromptAttachment> attachments,
  ) {
    if (attachments.isEmpty) return prompt;
    final mentions = attachments
        .map((item) => item.toPromptMention())
        .join('\n');
    if (prompt.trim().isEmpty) return mentions;
    return '$prompt\n\n$mentions';
  }

  ({String text, Map<String, Object?> metadata}) _agentErrorDetails(
    Object error,
  ) {
    final data = _dynamicField(error, 'data');
    if (data is Map) {
      final message = data['message'];
      final errorInfo = data['codex_error_info'];
      return (
        text: message is String && message.trim().isNotEmpty
            ? message
            : error.toString(),
        metadata: <String, Object?>{
          'rawError': error.toString(),
          if (errorInfo is String && errorInfo.isNotEmpty)
            'codexErrorInfo': errorInfo,
        },
      );
    }
    return (text: error.toString(), metadata: const <String, Object?>{});
  }

  Object? _dynamicField(Object object, String fieldName) {
    try {
      final dynamic value = object;
      return switch (fieldName) {
        'data' => value.data,
        _ => null,
      };
    } catch (_) {
      return null;
    }
  }

  Map<String, Object?> _metadataMap(Map? raw) {
    if (raw == null) return const <String, Object?>{};
    return raw.map((key, value) => MapEntry(key.toString(), value as Object?));
  }

  AcpConfigOption _configOptionFromAcp(acp.ConfigOption option) {
    return AcpConfigOption(
      id: option.id,
      name: option.name,
      type: option.type,
      currentValue: option.currentValue,
      options: option.options
          .map(
            (choice) => AcpConfigOptionChoice(
              value: choice.value,
              name: choice.name,
              description: choice.description,
            ),
          )
          .toList(),
      description: option.description,
      group: option.group,
    );
  }

  List<AcpConfigOption> _configOptionsFromRaw(Object? raw) {
    if (raw is! List) return const <AcpConfigOption>[];
    return raw
        .whereType<Map>()
        .map((item) => _configOptionFromRawMap(_metadataMap(item)))
        .whereType<AcpConfigOption>()
        .toList();
  }

  AcpConfigOption? _configOptionFromRawMap(Map<String, Object?> raw) {
    final id = raw['id'];
    final name = raw['name'];
    final type = raw['type'];
    final currentValue = _configValueFromRaw(raw['currentValue']);
    if (id is! String ||
        name is! String ||
        type is! String ||
        currentValue == null) {
      return null;
    }

    final choices = raw['options'] is List
        ? (raw['options'] as List)
              .whereType<Map>()
              .map((item) => _configChoiceFromRawMap(_metadataMap(item)))
              .whereType<AcpConfigOptionChoice>()
              .toList()
        : const <AcpConfigOptionChoice>[];

    return AcpConfigOption(
      id: id,
      name: name,
      type: type,
      currentValue: currentValue,
      options: choices,
      description: raw['description'] is String
          ? raw['description'] as String
          : null,
      category: raw['category'] is String ? raw['category'] as String : null,
      group: raw['group'] is String ? raw['group'] as String : null,
    );
  }

  String? _configValueFromRaw(Object? raw) {
    if (raw is String) return raw;
    if (raw is bool) return raw.toString();
    return null;
  }

  AcpConfigOptionChoice? _configChoiceFromRawMap(Map<String, Object?> raw) {
    final value = raw['value'];
    final name = raw['name'];
    if (value is! String || name is! String) return null;
    return AcpConfigOptionChoice(
      value: value,
      name: name,
      description: raw['description'] is String
          ? raw['description'] as String
          : null,
    );
  }

  List<AcpConfigOption> _cacheConfigOptions(
    String sessionId,
    List<acp.ConfigOption>? options,
  ) {
    final mapped =
        options?.map(_configOptionFromAcp).toList() ??
        const <AcpConfigOption>[];
    _configOptionsBySession[sessionId] = mapped;
    return mapped;
  }

  List<AcpConfigOption> _cacheRawConfigOptions(String sessionId, Object? raw) {
    final mapped = _configOptionsFromRaw(raw);
    _configOptionsBySession[sessionId] = mapped;
    return mapped;
  }

  List<AcpConfigOption> _applyConfigOptionOverride(
    String sessionId,
    String configId,
    Object value,
  ) {
    final current =
        _configOptionsBySession[sessionId] ?? const <AcpConfigOption>[];
    final mapped = current.map((option) {
      return option.id == configId
          ? option.copyWith(currentValue: value)
          : option;
    }).toList();
    _configOptionsBySession[sessionId] = mapped;
    return mapped;
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
    _supportsResumeSession = false;
    _activeSessionId = null;
    _modeOverridesBySession.clear();
    _configOptionsBySession.clear();
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
