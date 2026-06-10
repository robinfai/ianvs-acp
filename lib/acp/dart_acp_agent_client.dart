import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_acp/dart_acp.dart' as acp;
import 'package:mime/mime.dart' as mime;

import 'acp_agent_capabilities.dart';
import 'acp_agent_client.dart';
import 'acp_permission_request.dart';
import 'acp_session_catalog.dart';
import 'acp_session_settings.dart';
import 'agent_event.dart';
import 'agent_session.dart';
import 'prompt_attachment.dart';
import 'streamable_http_acp_transport.dart';
import 'web_socket_acp_transport.dart';

class DartAcpAgentClient implements AcpAgentClient {
  DartAcpAgentClient({
    String? agentCommand,
    List<String>? agentArgs,
    String? agentCwd,
    Map<String, String>? envOverrides,
    this.agentWebSocketUrl,
    this.agentHttpUrl,
    Map<String, String>? agentHeaders,
    List<Map<String, dynamic>>? mcpServers,
    List<String>? additionalDirectories,
    this.enableFilesystemReadTextFile = false,
    this.enableFilesystemWriteTextFile = false,
    this.allowFilesystemReadOutsideWorkspace = false,
    this.enableTerminalProvider = false,
  }) : agentCommand = agentCommand ?? _defaultAgentCommand(),
       agentArgs = agentArgs ?? const ['@zed-industries/codex-acp'],
       agentCwd = agentCwd?.trim().isEmpty == true ? null : agentCwd?.trim(),
       envOverrides = envOverrides ?? const <String, String>{},
       agentHeaders = agentHeaders ?? const <String, String>{},
       mcpServers = mcpServers == null
           ? const <Map<String, dynamic>>[]
           : List.unmodifiable(mcpServers.map(_copyMcpServerConfig)),
       additionalDirectories = additionalDirectories == null
           ? const <String>[]
           : List.unmodifiable(
               additionalDirectories.map((path) => path.trim()),
             );

  final String agentCommand;
  final List<String> agentArgs;
  final String? agentCwd;
  final Map<String, String> envOverrides;
  final Uri? agentWebSocketUrl;
  final Uri? agentHttpUrl;
  final Map<String, String> agentHeaders;
  final List<Map<String, dynamic>> mcpServers;
  final List<String> additionalDirectories;
  final bool enableFilesystemReadTextFile;
  final bool enableFilesystemWriteTextFile;
  final bool allowFilesystemReadOutsideWorkspace;
  final bool enableTerminalProvider;

  acp.AcpClient? _client;
  acp.AcpTransport? _transport;
  AcpAgentCapabilities? _capabilities;
  final _AcpPermissionBridge _permissionBridge = _AcpPermissionBridge();
  bool _supportsLoadSession = false;
  bool _supportsListSessions = false;
  bool _supportsResumeSession = false;
  String? _activeSessionId;
  final Map<String, String> _modeOverridesBySession = <String, String>{};
  final Map<String, AcpSessionModeInfo> _modesBySession =
      <String, AcpSessionModeInfo>{};
  final Map<String, String> _cwdBySession = <String, String>{};
  final Map<String, List<String>> _additionalDirectoriesBySession =
      <String, List<String>>{};
  final Map<String, List<AcpConfigOption>> _configOptionsBySession =
      <String, List<AcpConfigOption>>{};
  final Set<String> _modelConfigOptionsFromModelsBySession = <String>{};
  final Map<String, _RawProtocolRequest> _pendingRawProtocolRequests =
      <String, _RawProtocolRequest>{};
  final Map<String, Map<String, dynamic>> _rawSessionResultsBySession =
      <String, Map<String, dynamic>>{};
  final Map<String, List<Map<String, Object?>>> _rawToolCallEventsBySession =
      <String, List<Map<String, Object?>>>{};
  final Map<String, Map<String, Map<String, Object?>>>
  _rawToolCallStatesBySession = <String, Map<String, Map<String, Object?>>>{};

  static const int _maxEmbeddedAttachmentBytes = 256 * 1024;
  static const int _maxEmbeddedBinaryAttachmentBytes = 1024 * 1024;
  static const int _maxImageAttachmentBytes = 4 * 1024 * 1024;
  static const int _maxAudioAttachmentBytes = 8 * 1024 * 1024;
  static const int _maxRawToolCallEventIds = 200;
  static final RegExp _promptMentionPattern = RegExp(
    r'''@("([^"\\]|\\.)*"|'([^'\\]|\\.)*'|\S+)''',
  );

  static const Map<String, dynamic> _clientInfo = <String, dynamic>{
    'name': 'ACP Client',
    'version': String.fromEnvironment(
      'IANVS_ACP_VERSION',
      defaultValue: '1.0.0',
    ),
  };

  @override
  AcpAgentCapabilities? get capabilities => _capabilities;

  @override
  Stream<AcpPermissionRequest> get permissionRequests =>
      _permissionBridge.requests;

  @override
  Future<void> connect() async {
    await _disposeActiveClient(closePermissionStream: false);
    final configuredMcpServers = mcpServers
        .map(Map<String, dynamic>.from)
        .toList();
    final sessionMcpServers = configuredMcpServers
        .map(Map<String, dynamic>.from)
        .toList();
    final enableFilesystemProvider =
        enableFilesystemReadTextFile || enableFilesystemWriteTextFile;
    final config = acp.AcpConfig(
      agentCommand: agentCommand,
      agentArgs: agentArgs,
      envOverrides: envOverrides,
      mcpServers: sessionMcpServers,
      capabilities: acp.AcpCapabilities(
        fs: acp.FsCapabilities(
          readTextFile: enableFilesystemReadTextFile,
          writeTextFile: enableFilesystemWriteTextFile,
        ),
        terminal: enableTerminalProvider,
      ),
      fsProvider: enableFilesystemProvider
          ? acp.DefaultFsProvider(workspaceRoot: '/')
          : null,
      permissionProvider: _InteractivePermissionProvider(
        _permissionBridge,
        allowFilesystemReadTextFile: enableFilesystemReadTextFile,
        allowFilesystemWriteTextFile: enableFilesystemWriteTextFile,
      ),
      allowReadOutsideWorkspace: allowFilesystemReadOutsideWorkspace,
      terminalProvider: enableTerminalProvider
          ? acp.DefaultTerminalProvider()
          : null,
    );
    final transport = _transportForConfig(config);
    final client = await acp.AcpClient.start(
      config: config,
      transport: transport,
    );
    try {
      final clientCapabilities = Map<String, dynamic>.from(
        config.capabilities.toJson(),
      );
      if (config.terminalProvider != null) {
        clientCapabilities['terminal'] = true;
      }
      final initializeResult = await client
          .sendRaw('initialize', <String, dynamic>{
            'protocolVersion': 1,
            'clientCapabilities': clientCapabilities,
            'clientInfo': _clientInfo,
          });
      final protocolVersion =
          (initializeResult['protocolVersion'] as num?)?.toInt() ?? 0;
      if (protocolVersion < acp.AcpConfig.minimumProtocolVersion) {
        throw StateError(
          'Unsupported ACP protocol version: $protocolVersion. '
          'Minimum required: ${acp.AcpConfig.minimumProtocolVersion}.',
        );
      }
      final capabilities = AcpAgentCapabilities.fromInitialize(
        protocolVersion: protocolVersion,
        agentCapabilities: _dynamicMap(initializeResult['agentCapabilities']),
        agentInfo: _dynamicMap(initializeResult['agentInfo']),
        authMethods: _dynamicMapList(initializeResult['authMethods']),
        clientInfo: _clientInfo,
        clientCapabilities: clientCapabilities,
        hasFsProvider: config.fsProvider != null,
        hasTerminalProvider: config.terminalProvider != null,
        allowReadOutsideWorkspace: config.allowReadOutsideWorkspace,
      );
      _supportsLoadSession = capabilities.loadSession;
      _supportsListSessions = capabilities.session.list;
      _supportsResumeSession = capabilities.session.resume;
      _capabilities = capabilities;
      final compatibleMcpServers = _mcpServersForCapabilities(
        configuredMcpServers,
        capabilities,
      );
      sessionMcpServers
        ..clear()
        ..addAll(compatibleMcpServers);
    } catch (_) {
      await _disposeClient(client, transport);
      rethrow;
    }
    _client = client;
    _transport = transport;
  }

  acp.AcpTransport _transportForConfig(acp.AcpConfig config) {
    final webSocketUrl = agentWebSocketUrl;
    if (webSocketUrl != null) {
      return WebSocketAcpTransport(
        endpoint: webSocketUrl,
        headers: agentHeaders,
        onProtocolOut: _captureProtocolOut,
        onProtocolIn: _captureProtocolIn,
      );
    }
    final httpUrl = agentHttpUrl;
    if (httpUrl != null) {
      return StreamableHttpAcpTransport(
        endpoint: httpUrl,
        headers: agentHeaders,
        onProtocolOut: _captureProtocolOut,
        onProtocolIn: _captureProtocolIn,
      );
    }
    return acp.StdioTransport(
      command: agentCommand,
      args: agentArgs,
      cwd: agentCwd,
      envOverrides: envOverrides,
      logger: config.logger,
      onProtocolOut: _captureProtocolOut,
      onProtocolIn: _captureProtocolIn,
    );
  }

  @override
  Future<AgentSession> createSession({
    required String cwd,
    List<String> additionalDirectories = const <String>[],
  }) async {
    final client = _requireClient();
    final directories = _additionalDirectoriesForRequest(additionalDirectories);
    final sessionId = await client.newSession(
      cwd,
      additionalDirectories: directories,
    );
    _activeSessionId = sessionId;
    _cwdBySession[sessionId] = cwd;
    _additionalDirectoriesBySession[sessionId] = directories;
    final response = _takeRawSessionResult(sessionId);
    final configOptions = _cacheSessionResultConfigOptions(
      sessionId: sessionId,
      rawResponse: response,
    );
    if (configOptions.isEmpty) {
      _cacheRawModes(sessionId, response['modes']);
    } else {
      _modesBySession.remove(sessionId);
      _modeOverridesBySession.remove(sessionId);
    }
    final initialEvents = await _cacheImmediateSessionUpdates(
      client,
      sessionId,
    );
    return AgentSession(
      id: sessionId,
      cwd: cwd,
      createdAt: DateTime.now(),
      additionalDirectories: directories,
      initialEvents: initialEvents,
    );
  }

  @override
  Future<List<AgentEvent>> resumeSession({
    required String sessionId,
    required String cwd,
    List<String> additionalDirectories = const <String>[],
  }) async {
    final client = _requireClient();
    if (!_supportsLoadSession && !_supportsResumeSession) {
      throw StateError(
        'ACP agent does not support session/load or session/resume.',
      );
    }

    final events = <AgentEvent>[];
    final directories = _additionalDirectoriesForRequest(additionalDirectories);
    if (!_supportsLoadSession) {
      final result = await client.resumeSession(
        sessionId: sessionId,
        workspaceRoot: cwd,
        additionalDirectories: directories,
      );
      _activeSessionId = sessionId;
      _cwdBySession[sessionId] = cwd;
      _additionalDirectoriesBySession[sessionId] = directories;
      final response = _takeRawSessionResult(sessionId);
      _cacheSessionResult(
        sessionId: sessionId,
        rawResponse: response,
        typedConfigOptions: result.configOptions,
      );
      events.addAll(await _cacheImmediateSessionUpdates(client, sessionId));
      return events;
    }

    final subscription = client.sessionUpdates(sessionId).listen((update) {
      final event = _eventFromAcpUpdate(update, sessionId: sessionId);
      if (event != null) {
        events.add(event);
      }
    }, onError: (_) {});
    try {
      await client.loadSession(
        sessionId: sessionId,
        workspaceRoot: cwd,
        additionalDirectories: directories,
      );
      await Future<void>.delayed(Duration.zero);
      _activeSessionId = sessionId;
      _cwdBySession[sessionId] = cwd;
      _additionalDirectoriesBySession[sessionId] = directories;
      final response = _takeRawSessionResult(sessionId);
      if (response.isNotEmpty) {
        _cacheSessionResult(sessionId: sessionId, rawResponse: response);
      }
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
            additionalDirectories: session.additionalDirectories,
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
    final configOptions =
        _configOptionsBySession[sessionId] ?? const <AcpConfigOption>[];
    if (configOptions.isNotEmpty) {
      return AcpSessionSettings(configOptions: configOptions);
    }

    final modes = client.sessionModes(sessionId);
    final cachedModes = _modesBySession[sessionId];
    final currentModeId =
        _modeOverridesBySession[sessionId] ??
        modes?.currentModeId ??
        cachedModes?.currentModeId;
    final packageModes =
        modes?.availableModes
            .map((mode) => AcpSessionMode(id: mode.id, name: mode.name))
            .where((mode) => mode.id.isNotEmpty)
            .toList() ??
        const <AcpSessionMode>[];
    final availableModes = cachedModes?.availableModes.isNotEmpty == true
        ? cachedModes!.availableModes
        : packageModes;
    return AcpSessionSettings(
      modes: AcpSessionModeInfo(
        currentModeId: currentModeId,
        availableModes: availableModes,
      ),
      configOptions: configOptions,
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
    if (configId == 'model' &&
        _modelConfigOptionsFromModelsBySession.contains(sessionId)) {
      final response = await client.sendRaw('session/set_model', {
        'sessionId': sessionId,
        'modelId': value.toString(),
      });
      final rawConfigOptions = response.containsKey('configOptions')
          ? response['configOptions']
          : response['config_options'];
      if ((rawConfigOptions is List && rawConfigOptions.isNotEmpty) ||
          response.containsKey('models')) {
        final configOptions = _cacheSessionResultConfigOptions(
          sessionId: sessionId,
          rawResponse: response,
        );
        if (configOptions.isNotEmpty) return configOptions;
      }
      return _applyConfigOptionOverride(sessionId, configId, value);
    }
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
    List<String> additionalDirectories = const <String>[],
  }) async {
    final client = _requireClient();
    if (_capabilities?.session.fork != true) {
      throw StateError('ACP agent does not support session/fork.');
    }
    final directories = _additionalDirectoriesForRequest(
      additionalDirectories.isEmpty
          ? _additionalDirectoriesBySession[sessionId] ?? const <String>[]
          : additionalDirectories,
    );
    final result = await client.forkSession(
      sessionId: sessionId,
      workspaceRoot: cwd,
      additionalDirectories: directories,
    );
    final forkedSessionId = result.sessionId;
    _activeSessionId = forkedSessionId;
    _cwdBySession[forkedSessionId] = cwd;
    _additionalDirectoriesBySession[forkedSessionId] = directories;
    final response = _takeRawSessionResult(forkedSessionId);
    _cacheSessionResult(
      sessionId: forkedSessionId,
      rawResponse: response,
      typedConfigOptions: result.configOptions,
    );
    final initialEvents = await _cacheImmediateSessionUpdates(
      client,
      forkedSessionId,
    );
    return AgentSession(
      id: forkedSessionId,
      cwd: cwd,
      createdAt: DateTime.now(),
      additionalDirectories: directories,
      initialEvents: initialEvents,
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
    _modesBySession.remove(sessionId);
    _cwdBySession.remove(sessionId);
    _additionalDirectoriesBySession.remove(sessionId);
    _modeOverridesBySession.remove(sessionId);
    _configOptionsBySession.remove(sessionId);
    _modelConfigOptionsFromModelsBySession.remove(sessionId);
    _rawToolCallEventsBySession.remove(sessionId);
    _rawToolCallStatesBySession.remove(sessionId);
    _permissionBridge.cancelSession(sessionId);
  }

  @override
  Future<void> authenticate({required String methodId}) async {
    final client = _requireClient();
    final trimmedMethodId = methodId.trim();
    if (trimmedMethodId.isEmpty) {
      throw StateError('Authentication method id is required.');
    }
    final supportsMethod =
        _capabilities?.authMethods.any((method) {
          final id = method['id'];
          return id is String && id.trim() == trimmedMethodId;
        }) ??
        false;
    if (!supportsMethod) {
      throw StateError(
        'ACP agent did not advertise authentication method "$trimmedMethodId".',
      );
    }
    await client.sendRaw('authenticate', <String, dynamic>{
      'methodId': trimmedMethodId,
    });
  }

  @override
  Future<void> logout() async {
    final client = _requireClient();
    if (_capabilities?.auth.logout != true) {
      throw StateError('ACP agent does not support logout.');
    }
    await client.sendRaw('logout', const <String, dynamic>{});
    _activeSessionId = null;
    _modesBySession.clear();
    _cwdBySession.clear();
    _additionalDirectoriesBySession.clear();
    _modeOverridesBySession.clear();
    _configOptionsBySession.clear();
    _modelConfigOptionsFromModelsBySession.clear();
    _rawToolCallEventsBySession.clear();
    _rawToolCallStatesBySession.clear();
    _permissionBridge.cancelAll();
  }

  @override
  Future<Map<String, Object?>> sendExtensionRequest({
    required String method,
    required Map<String, Object?> params,
  }) async {
    if (!method.startsWith('_')) {
      throw ArgumentError.value(
        method,
        'method',
        'Extension methods must start with underscore (_).',
      );
    }
    final result = await _requireClient().sendRaw(
      method,
      _dynamicJsonMap(params),
    );
    return _metadataMap(result);
  }

  @override
  Stream<AgentEvent> sendPrompt({
    required String sessionId,
    required String prompt,
    String? memoryContext,
    List<PromptAttachment> attachments = const <PromptAttachment>[],
  }) async* {
    final client = _requireClient();
    _activeSessionId = sessionId;
    try {
      final content = await _promptContentBlocks(
        prompt,
        attachments,
        memoryContext: memoryContext,
        workspaceRoot: _cwdBySession[sessionId],
      );
      await for (final event in _sendRawPrompt(
        client: client,
        sessionId: sessionId,
        content: content,
      )) {
        yield event;
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
    String? sessionId,
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
        final rawToolCallState = sessionId == null
            ? null
            : _takeRawToolCallState(sessionId);
        final metadata = rawToolCallState == null
            ? <String, Object?>{'kind': 'tool', ...toolCall.toJson()}
            : <String, Object?>{
                'kind': 'tool',
                ..._normalizedRawToolCallMetadata(rawToolCallState),
              };
        final title = metadata['title'];
        final toolCallId = metadata['toolCallId'];
        return AgentEvent(
          type: AgentEventType.toolCall,
          text: title is String && title.trim().isNotEmpty
              ? title
              : toolCallId is String && toolCallId.trim().isNotEmpty
              ? toolCallId
              : 'Tool call',
          metadata: metadata,
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
      case acp.UsageUpdate():
        return _usageEventFromValues(
          used: update.used,
          size: update.size,
          cost: update.cost == null
              ? null
              : <String, Object?>{
                  'amount': update.cost!.amount,
                  'currency': update.cost!.currency,
                },
        );
      case acp.ModeUpdate():
        final updateSessionId = sessionId ?? _activeSessionId;
        if (updateSessionId != null &&
            (_configOptionsBySession[updateSessionId]?.isNotEmpty ?? false)) {
          return null;
        }
        if (update.currentModeId.isNotEmpty && updateSessionId != null) {
          _modeOverridesBySession[updateSessionId] = update.currentModeId;
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
        final kind = _unknownUpdateKind(update);
        if (kind == 'usage_update') return _usageEventFromUnknownUpdate(update);
        final mapped = _eventFromUnknownUpdate(update);
        if (mapped != null) return mapped;
        if (kind == null) return null;
        final text = '[Unknown update: $kind]';
        return AgentEvent(
          type: AgentEventType.status,
          text: text,
          metadata: <String, Object?>{'kind': 'unknown', 'sessionUpdate': kind},
          timestamp: DateTime.now(),
        );
    }
  }

  AgentEvent? _eventFromUnknownUpdate(acp.UnknownUpdate update) {
    final raw = update.raw;
    final sessionId = _sessionIdFromMap(raw);
    final rawBody = raw['update'];
    final body = rawBody is Map<String, dynamic> ? rawBody : raw;

    final kind = body['sessionUpdate'];
    if (kind == 'config_option_update') {
      final options = _configOptionsFromRaw(body['configOptions']);
      if (sessionId != null) {
        _configOptionsBySession[sessionId] = options;
        _modelConfigOptionsFromModelsBySession.remove(sessionId);
        if (options.isNotEmpty) {
          _modesBySession.remove(sessionId);
          _modeOverridesBySession.remove(sessionId);
        }
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

  AgentEvent? _usageEventFromUnknownUpdate(acp.UnknownUpdate update) {
    final raw = update.raw;
    final rawBody = raw['update'];
    final body = rawBody is Map ? rawBody : raw;
    return _usageEventFromRaw(body);
  }

  AgentEvent? _usageEventFromRaw(Map raw) {
    final used = _intFromRaw(raw['used']);
    final size = _intFromRaw(raw['size']);
    if (used == null || size == null) return null;
    return _usageEventFromValues(
      used: used,
      size: size,
      cost: _usageCostFromRaw(raw['cost']),
    );
  }

  AgentEvent? _usageEventFromValues({
    required int used,
    required int size,
    Map<String, Object?>? cost,
  }) {
    if (used < 0 || size <= 0) return null;
    final percent = used / size * 100;
    return AgentEvent(
      type: AgentEventType.status,
      text: 'Context ${percent.toStringAsFixed(0)}%',
      metadata: <String, Object?>{
        'kind': 'usage_update',
        'used': used,
        'size': size,
        'cost': ?cost,
      },
      timestamp: DateTime.now(),
    );
  }

  Map<String, Object?>? _usageCostFromRaw(Object? raw) {
    if (raw is! Map) return null;
    final cost = _metadataMap(raw);
    final amount = _numFromRaw(cost['amount']);
    final currency = cost['currency']?.toString().trim() ?? '';
    if (amount == null || currency.isEmpty) return null;
    return <String, Object?>{'amount': amount, 'currency': currency};
  }

  String? _unknownUpdateKind(acp.UnknownUpdate update) {
    final raw = update.raw;
    final direct = _nonEmptyString(raw['sessionUpdate']);
    if (direct != null) return direct;
    final body = raw['update'];
    if (body is Map) return _nonEmptyString(body['sessionUpdate']);
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

  Future<List<Map<String, dynamic>>> _promptContentBlocks(
    String prompt,
    List<PromptAttachment> attachments, {
    String? memoryContext,
    String? workspaceRoot,
  }) async {
    final blocks = <Map<String, dynamic>>[];
    final trimmedMemoryContext = memoryContext?.trim();
    if (trimmedMemoryContext != null && trimmedMemoryContext.isNotEmpty) {
      blocks.add(<String, dynamic>{
        'type': 'text',
        'text': trimmedMemoryContext,
      });
    }
    if (prompt.trim().isNotEmpty) {
      blocks.add(<String, dynamic>{'type': 'text', 'text': prompt});
    }
    blocks.addAll(
      _mentionResourceLinkBlocks(prompt, workspaceRoot: workspaceRoot),
    );
    for (final attachment in attachments) {
      blocks.add(await _contentBlockForAttachment(attachment));
    }
    return blocks;
  }

  List<Map<String, dynamic>> _mentionResourceLinkBlocks(
    String prompt, {
    String? workspaceRoot,
  }) {
    return _promptMentionPattern
        .allMatches(prompt)
        .where((match) => _isPromptMentionBoundary(prompt, match.start))
        .map(
          (match) =>
              _mentionTokenToResourceLink(match.group(1)!, workspaceRoot),
        )
        .whereType<Map<String, dynamic>>()
        .toList();
  }

  Map<String, dynamic>? _mentionTokenToResourceLink(
    String token,
    String? workspaceRoot,
  ) {
    final mention = _unquoteMentionToken(token);
    if (mention.trim().isEmpty) return null;
    final uri = _mentionTokenToUri(mention, workspaceRoot);
    if (uri == null) return null;
    final uriText = uri.toString();
    final mimeType =
        mime.lookupMimeType(uri.path) ?? mime.lookupMimeType(uriText);
    return <String, dynamic>{
      'type': 'resource_link',
      'name': _mentionDisplayName(uri),
      'uri': uriText,
      'mimeType': ?mimeType,
    };
  }

  bool _isPromptMentionBoundary(String prompt, int atIndex) {
    if (atIndex <= 0) return true;
    final previous = prompt.codeUnitAt(atIndex - 1);
    return !_isInlineMentionPrefix(previous);
  }

  bool _isInlineMentionPrefix(int codeUnit) {
    return (codeUnit >= 0x30 && codeUnit <= 0x39) || // 0-9
        (codeUnit >= 0x41 && codeUnit <= 0x5a) || // A-Z
        codeUnit == 0x2d || // -
        codeUnit == 0x2e || // .
        codeUnit == 0x5f || // _
        (codeUnit >= 0x61 && codeUnit <= 0x7a); // a-z
  }

  String _unquoteMentionToken(String token) {
    if (token.length < 2) return _trimUnquotedMentionToken(token);
    final quote = token[0];
    if ((quote != '"' && quote != "'") || token[token.length - 1] != quote) {
      return _trimUnquotedMentionToken(token);
    }
    return token
        .substring(1, token.length - 1)
        .replaceAll('\\$quote', quote)
        .replaceAll('\\\\', '\\');
  }

  String _trimUnquotedMentionToken(String token) {
    var end = token.length;
    while (end > 0 &&
        _isTrailingMentionPunctuation(token.codeUnitAt(end - 1))) {
      end--;
    }
    return token.substring(0, end);
  }

  bool _isTrailingMentionPunctuation(int codeUnit) {
    return codeUnit == 0x21 || // !
        codeUnit == 0x29 || // )
        codeUnit == 0x2c || // ,
        codeUnit == 0x2e || // .
        codeUnit == 0x3a || // :
        codeUnit == 0x3b || // ;
        codeUnit == 0x3f || // ?
        codeUnit == 0x5d || // ]
        codeUnit == 0x7d; // }
  }

  Uri? _mentionTokenToUri(String token, String? workspaceRoot) {
    if (token.startsWith('http://') || token.startsWith('https://')) {
      return Uri.tryParse(token);
    }

    var path = token;
    if (path == '~') {
      path = Platform.environment['HOME'] ?? path;
    } else if (path.startsWith('~/')) {
      final home = Platform.environment['HOME'];
      if (home != null && home.isNotEmpty) {
        path = '$home/${path.substring(2)}';
      }
    }

    if (!path.startsWith('/')) {
      final base = workspaceRoot;
      if (base != null && base.isNotEmpty) {
        path = '${base.replaceAll(RegExp(r'/+$'), '')}/$path';
      } else {
        path = File(path).absolute.path;
      }
    }
    return Uri.file(path);
  }

  String _mentionDisplayName(Uri uri) {
    if (uri.scheme == 'http' || uri.scheme == 'https') {
      return uri.pathSegments.isEmpty ? uri.host : uri.pathSegments.last;
    }
    final path = uri.toFilePath();
    return path.replaceAll('\\', '/').split('/').last;
  }

  Future<Map<String, dynamic>> _contentBlockForAttachment(
    PromptAttachment attachment,
  ) async {
    final image = await _imageContentBlock(attachment);
    if (image != null) return image;
    final audio = await _audioContentBlock(attachment);
    if (audio != null) return audio;
    final embedded = await _embeddedTextResourceBlock(attachment);
    if (embedded != null) return embedded;
    final binary = await _embeddedBinaryResourceBlock(attachment);
    return binary ?? _resourceLinkBlock(attachment);
  }

  List<String> _additionalDirectoriesForRequest(List<String> override) {
    final selected = override.isEmpty ? additionalDirectories : override;
    if (_capabilities?.session.additionalDirectories != true) {
      return const <String>[];
    }
    return _normalizedDirectories(selected);
  }

  List<String> _normalizedDirectories(Iterable<String> directories) {
    final result = <String>[];
    final seen = <String>{};
    for (final directory in directories) {
      final trimmed = directory.trim();
      if (trimmed.isEmpty || !seen.add(trimmed)) continue;
      result.add(trimmed);
    }
    return List.unmodifiable(result);
  }

  Future<Map<String, dynamic>?> _imageContentBlock(
    PromptAttachment attachment,
  ) async {
    if (_capabilities?.prompt.image != true) return null;
    final mimeType = attachment.imageMimeType;
    if (mimeType == null) return null;

    try {
      final file = File(attachment.path);
      final byteCount = attachment.size ?? await file.length();
      if (byteCount > _maxImageAttachmentBytes) return null;
      final bytes = await file.readAsBytes();
      return <String, dynamic>{
        'type': 'image',
        'mimeType': mimeType,
        'data': base64Encode(bytes),
        'uri': attachment.uri.toString(),
      };
    } on Object {
      return null;
    }
  }

  Future<Map<String, dynamic>?> _audioContentBlock(
    PromptAttachment attachment,
  ) async {
    if (_capabilities?.prompt.audio != true) return null;
    final mimeType = attachment.audioMimeType;
    if (mimeType == null) return null;

    try {
      final file = File(attachment.path);
      final byteCount = attachment.size ?? await file.length();
      if (byteCount > _maxAudioAttachmentBytes) return null;
      final bytes = await file.readAsBytes();
      return <String, dynamic>{
        'type': 'audio',
        'mimeType': mimeType,
        'data': base64Encode(bytes),
      };
    } on Object {
      return null;
    }
  }

  Future<Map<String, dynamic>?> _embeddedTextResourceBlock(
    PromptAttachment attachment,
  ) async {
    if (_capabilities?.prompt.embeddedContext != true) return null;
    if (!attachment.isText) return null;

    try {
      final file = File(attachment.path);
      final byteCount = attachment.size ?? await file.length();
      if (byteCount > _maxEmbeddedAttachmentBytes) return null;
      final text = await file.readAsString();
      return <String, dynamic>{
        'type': 'resource',
        'resource': <String, dynamic>{
          'uri': attachment.uri.toString(),
          if (attachment.mimeType?.isNotEmpty == true)
            'mimeType': attachment.mimeType,
          'text': text,
        },
      };
    } on Object {
      return null;
    }
  }

  Future<Map<String, dynamic>?> _embeddedBinaryResourceBlock(
    PromptAttachment attachment,
  ) async {
    if (_capabilities?.prompt.embeddedContext != true) return null;
    if (attachment.isText) return null;
    if (attachment.isImage) return null;
    if (attachment.isAudio) return null;

    try {
      final file = File(attachment.path);
      final byteCount = attachment.size ?? await file.length();
      if (byteCount > _maxEmbeddedBinaryAttachmentBytes) return null;
      final bytes = await file.readAsBytes();
      return <String, dynamic>{
        'type': 'resource',
        'resource': <String, dynamic>{
          'uri': attachment.uri.toString(),
          if (attachment.mimeType?.isNotEmpty == true)
            'mimeType': attachment.mimeType,
          'blob': base64Encode(bytes),
        },
      };
    } on Object {
      return null;
    }
  }

  Map<String, dynamic> _resourceLinkBlock(PromptAttachment attachment) {
    return attachment.toResourceLink().map<String, dynamic>(
      (key, value) => MapEntry(key, value),
    );
  }

  Stream<AgentEvent> _sendRawPrompt({
    required acp.AcpClient client,
    required String sessionId,
    required List<Map<String, dynamic>> content,
  }) async* {
    final events = StreamController<AgentEvent>();
    var acceptingUpdates = false;
    final terminalSubscription = client.terminalEvents.listen(
      (update) {
        if (!acceptingUpdates || events.isClosed) return;
        final event = _eventFromTerminalEvent(update, sessionId);
        if (event != null) {
          events.add(event);
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!events.isClosed) events.addError(error, stackTrace);
      },
    );
    final subscription = client
        .sessionUpdates(sessionId)
        .listen(
          (update) {
            if (!acceptingUpdates || events.isClosed) return;
            final event = _eventFromAcpUpdate(
              update,
              includeUserMessages: false,
              sessionId: sessionId,
            );
            if (event != null) {
              events.add(event);
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            if (!events.isClosed) events.addError(error, stackTrace);
          },
        );
    try {
      await Future<void>.delayed(Duration.zero);
      acceptingUpdates = true;
      unawaited(() async {
        try {
          final response = await client.sendRaw(
            'session/prompt',
            <String, dynamic>{'sessionId': sessionId, 'prompt': content},
          );
          if (!events.isClosed) {
            events.add(_eventFromPromptResponse(response));
          }
        } catch (error, stackTrace) {
          if (!events.isClosed) events.addError(error, stackTrace);
        } finally {
          if (!events.isClosed) {
            await events.close();
          }
        }
      }());
      await for (final event in events.stream) {
        yield event;
      }
    } finally {
      await terminalSubscription.cancel();
      await subscription.cancel();
      if (!events.isClosed) {
        await events.close();
      }
    }
  }

  AgentEvent? _eventFromTerminalEvent(
    acp.TerminalEvent update,
    String sessionId,
  ) {
    switch (update) {
      case acp.TerminalCreated():
        if (update.sessionId != sessionId) return null;
        final command = [
          update.command,
          ...update.args,
        ].where((part) => part.trim().isNotEmpty).join(' ');
        return AgentEvent(
          type: AgentEventType.status,
          text: command.isEmpty ? 'Terminal started.' : command,
          metadata: <String, Object?>{
            'kind': 'terminal',
            'terminalEvent': 'created',
            'terminalId': update.terminalId,
            'status': 'running',
            'command': update.command,
            'args': update.args,
            if (update.cwd?.trim().isNotEmpty == true) 'cwd': update.cwd,
          },
          timestamp: DateTime.now(),
        );
      case acp.TerminalOutputEvent():
        if (!update.terminalId.startsWith('$sessionId:')) return null;
        return AgentEvent(
          type: AgentEventType.status,
          text: 'Terminal output.',
          metadata: <String, Object?>{
            'kind': 'terminal',
            'terminalEvent': 'output',
            'terminalId': update.terminalId,
            'status': _terminalStatusFromExitCode(update.exitCode),
            'output': update.output,
            'truncated': update.truncated,
            if (update.exitCode != null) 'exitCode': update.exitCode,
          },
          timestamp: DateTime.now(),
        );
      case acp.TerminalExited():
        if (!update.terminalId.startsWith('$sessionId:')) return null;
        return AgentEvent(
          type: AgentEventType.status,
          text: 'Terminal exited.',
          metadata: <String, Object?>{
            'kind': 'terminal',
            'terminalEvent': 'exited',
            'terminalId': update.terminalId,
            'status': _terminalStatusFromExitCode(update.code),
            'exitCode': update.code,
          },
          timestamp: DateTime.now(),
        );
      case acp.TerminalReleased():
        if (!update.terminalId.startsWith('$sessionId:')) return null;
        return AgentEvent(
          type: AgentEventType.status,
          text: 'Terminal released.',
          metadata: <String, Object?>{
            'kind': 'terminal',
            'terminalEvent': 'released',
            'terminalId': update.terminalId,
            'status': 'released',
          },
          timestamp: DateTime.now(),
        );
    }
  }

  String _terminalStatusFromExitCode(int? exitCode) {
    if (exitCode == null) return 'running';
    return exitCode == 0 ? 'completed' : 'failed';
  }

  AgentEvent _eventFromPromptResponse(Map<String, dynamic> response) {
    final stopReason = response['stopReason'];
    return AgentEvent(
      type: AgentEventType.agentTextDone,
      text: '',
      metadata: <String, Object?>{
        'stopReason': stopReason is String
            ? acp.stopReasonFromWire(stopReason).name
            : acp.StopReason.other.name,
        'kind': 'turn',
      },
      timestamp: DateTime.now(),
    );
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

  int? _intFromRaw(Object? raw) {
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw.trim());
    return null;
  }

  num? _numFromRaw(Object? raw) {
    if (raw is num) return raw;
    if (raw is String) return num.tryParse(raw.trim());
    return null;
  }

  String? _nonEmptyString(Object? raw) {
    if (raw is! String) return null;
    final trimmed = raw.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  String? _sessionIdFromMap(Map? raw) {
    if (raw == null) return null;
    return _nonEmptyString(raw['sessionId']) ??
        _nonEmptyString(raw['session_id']);
  }

  Map<String, dynamic> _dynamicJsonMap(Map<String, Object?> raw) {
    return raw.map((key, value) => MapEntry(key, _dynamicJsonValue(value)));
  }

  Object? _dynamicJsonValue(Object? value) {
    if (value is Map<String, Object?>) return _dynamicJsonMap(value);
    if (value is Map) {
      return value.map(
        (key, item) => MapEntry(key.toString(), _dynamicJsonValue(item)),
      );
    }
    if (value is List) return value.map(_dynamicJsonValue).toList();
    return value;
  }

  Map<String, dynamic>? _dynamicMap(Object? raw) {
    if (raw is! Map) return null;
    return raw.map((key, value) => MapEntry(key.toString(), value));
  }

  List<Map<String, dynamic>>? _dynamicMapList(Object? raw) {
    if (raw is! List) return null;
    return raw
        .whereType<Map>()
        .map(
          (item) => item.map((key, value) => MapEntry(key.toString(), value)),
        )
        .toList();
  }

  AcpConfigOption? _configOptionFromAcp(acp.ConfigOption option) {
    final type = _configOptionType(option.type);
    if (type == null) return null;
    final currentValue = _configValueFromRaw(option.currentValue, type: type);
    if (currentValue == null) return null;
    return AcpConfigOption(
      id: option.id,
      name: option.name,
      type: type,
      currentValue: currentValue,
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
    final id =
        _nonEmptyString(raw['id']) ??
        _nonEmptyString(raw['configId']) ??
        _nonEmptyString(raw['config_id']) ??
        _nonEmptyString(raw['key']);
    final type = _configOptionType(raw['type']);
    if (id == null || type == null) {
      return null;
    }
    final currentValue = _configValueFromRaw(
      raw['currentValue'] ??
          raw['current_value'] ??
          raw['value'] ??
          raw['selectedValue'] ??
          raw['selected'],
      type: type,
    );
    if (currentValue == null) {
      return null;
    }

    final choices = _configChoicesFromRaw(
      raw['options'] ?? raw['choices'] ?? raw['values'],
    );

    return AcpConfigOption(
      id: id,
      name:
          _nonEmptyString(raw['name']) ??
          _nonEmptyString(raw['label']) ??
          _nonEmptyString(raw['title']) ??
          id,
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

  String? _configOptionType(Object? raw) {
    if (raw == null) return 'select';
    if (raw is! String) return null;
    final type = raw.trim().toLowerCase();
    if (type.isEmpty) return 'select';
    if (type != 'select' && type != 'boolean') return null;
    return type;
  }

  String? _configValueFromRaw(Object? raw, {required String type}) {
    if (raw is String) return raw;
    if (raw is num) return raw.toString();
    if (type == 'boolean' && raw is bool) return raw.toString();
    return null;
  }

  List<AcpConfigOptionChoice> _configChoicesFromRaw(Object? raw) {
    if (raw is! List) return const <AcpConfigOptionChoice>[];
    return raw
        .map(_configChoiceFromRaw)
        .whereType<AcpConfigOptionChoice>()
        .toList();
  }

  AcpConfigOptionChoice? _configChoiceFromRaw(Object? raw) {
    if (raw is String || raw is bool || raw is num) {
      final value = raw.toString();
      return value.isEmpty
          ? null
          : AcpConfigOptionChoice(value: value, name: value);
    }
    if (raw is! Map) return null;
    return _configChoiceFromRawMap(_metadataMap(raw));
  }

  AcpConfigOptionChoice? _configChoiceFromRawMap(Map<String, Object?> raw) {
    final value =
        _configChoiceValue(raw['value']) ??
        _configChoiceValue(raw['id']) ??
        _configChoiceValue(raw['key']) ??
        _configChoiceValue(raw['name']);
    if (value == null) return null;
    return AcpConfigOptionChoice(
      value: value,
      name:
          _nonEmptyString(raw['name']) ??
          _nonEmptyString(raw['label']) ??
          _nonEmptyString(raw['displayName']) ??
          value,
      description: raw['description'] is String
          ? raw['description'] as String
          : null,
    );
  }

  String? _configChoiceValue(Object? raw) {
    if (raw is String && raw.isNotEmpty) return raw;
    if (raw is num || raw is bool) return raw.toString();
    return null;
  }

  List<AcpConfigOption> _cacheRawConfigOptions(String sessionId, Object? raw) {
    final mapped = _configOptionsFromRaw(raw);
    _configOptionsBySession[sessionId] = mapped;
    _modelConfigOptionsFromModelsBySession.remove(sessionId);
    return mapped;
  }

  List<AcpConfigOption> _cacheConfigOptions(
    String sessionId,
    List<acp.ConfigOption>? options,
  ) {
    final mapped =
        options
            ?.map(_configOptionFromAcp)
            .whereType<AcpConfigOption>()
            .toList() ??
        const <AcpConfigOption>[];
    _configOptionsBySession[sessionId] = mapped;
    _modelConfigOptionsFromModelsBySession.remove(sessionId);
    return mapped;
  }

  void _cacheSessionResult({
    required String sessionId,
    required Map<String, dynamic> rawResponse,
    List<acp.ConfigOption>? typedConfigOptions,
  }) {
    final configOptions = _cacheSessionResultConfigOptions(
      sessionId: sessionId,
      rawResponse: rawResponse,
      typedConfigOptions: typedConfigOptions,
    );
    if (configOptions.isEmpty) {
      _cacheRawModes(sessionId, rawResponse['modes']);
    } else {
      _modesBySession.remove(sessionId);
      _modeOverridesBySession.remove(sessionId);
    }
  }

  List<AcpConfigOption> _cacheSessionResultConfigOptions({
    required String sessionId,
    required Map<String, dynamic> rawResponse,
    List<acp.ConfigOption>? typedConfigOptions,
  }) {
    final rawConfigOptions = rawResponse.containsKey('configOptions')
        ? rawResponse['configOptions']
        : rawResponse['config_options'];
    if (rawConfigOptions != null) {
      final configOptions = _cacheRawConfigOptions(sessionId, rawConfigOptions);
      if (configOptions.isNotEmpty) return configOptions;
    }
    if (typedConfigOptions != null) {
      final configOptions = _cacheConfigOptions(sessionId, typedConfigOptions);
      if (configOptions.isNotEmpty) return configOptions;
    }
    final modelOption = _configOptionFromRawModels(rawResponse['models']);
    if (modelOption != null) {
      final configOptions = <AcpConfigOption>[modelOption];
      _configOptionsBySession[sessionId] = configOptions;
      _modelConfigOptionsFromModelsBySession.add(sessionId);
      return configOptions;
    }
    return _configOptionsBySession[sessionId] ?? const <AcpConfigOption>[];
  }

  AcpConfigOption? _configOptionFromRawModels(Object? raw) {
    if (raw is! Map) return null;
    final map = _metadataMap(raw);
    final rawAvailableModels =
        map['availableModels'] ?? map['available_models'];
    final availableModels = rawAvailableModels is List
        ? rawAvailableModels
              .whereType<Map>()
              .map((item) => _configChoiceFromRawModelMap(_metadataMap(item)))
              .whereType<AcpConfigOptionChoice>()
              .toList()
        : const <AcpConfigOptionChoice>[];
    final currentModelId =
        _nonEmptyString(map['currentModelId']) ??
        _nonEmptyString(map['current_model_id']) ??
        _nonEmptyString(map['modelId']) ??
        _nonEmptyString(map['model']);
    final currentValue =
        currentModelId ??
        (availableModels.isEmpty ? null : availableModels.first.value);
    if (currentValue == null) return null;

    final options = <AcpConfigOptionChoice>[];
    final seen = <String>{};
    for (final choice in availableModels) {
      if (seen.add(choice.value)) options.add(choice);
    }
    if (!seen.contains(currentValue)) {
      options.add(
        AcpConfigOptionChoice(
          value: currentValue,
          name: currentValue,
          description: 'Current session model',
        ),
      );
    }

    return AcpConfigOption(
      id: 'model',
      name: 'Model',
      type: 'select',
      currentValue: currentValue,
      options: options,
      category: 'model',
    );
  }

  AcpConfigOptionChoice? _configChoiceFromRawModelMap(
    Map<String, Object?> raw,
  ) {
    final modelId =
        _nonEmptyString(raw['modelId']) ??
        _nonEmptyString(raw['model_id']) ??
        _nonEmptyString(raw['id']) ??
        _nonEmptyString(raw['value']) ??
        _nonEmptyString(raw['model']);
    if (modelId == null) return null;
    return AcpConfigOptionChoice(
      value: modelId,
      name:
          _nonEmptyString(raw['name']) ??
          _nonEmptyString(raw['displayName']) ??
          _nonEmptyString(raw['display_name']) ??
          _nonEmptyString(raw['label']) ??
          modelId,
      description: _nonEmptyString(raw['description']),
    );
  }

  Map<String, dynamic> _takeRawSessionResult(String sessionId) {
    return _rawSessionResultsBySession.remove(sessionId) ??
        const <String, dynamic>{};
  }

  void _cacheRawModes(String sessionId, Object? raw) {
    final modes = _modeInfoFromRaw(raw);
    if (modes != null) {
      _modesBySession[sessionId] = modes;
    }
  }

  AcpSessionModeInfo? _modeInfoFromRaw(Object? raw) {
    if (raw is! Map) return null;
    final map = _metadataMap(raw);
    final currentModeId = _modeIdFromMap(map);
    final availableModes = _availableModesFromRaw(
      map['availableModes'] ?? map['available_modes'],
    );
    if (currentModeId == null && availableModes.isEmpty) return null;
    return AcpSessionModeInfo(
      currentModeId: currentModeId,
      availableModes: availableModes,
    );
  }

  String? _modeIdFromMap(Map? raw) {
    if (raw == null) return null;
    return _nonEmptyString(raw['currentModeId']) ??
        _nonEmptyString(raw['current_mode_id']) ??
        _nonEmptyString(raw['modeId']) ??
        _nonEmptyString(raw['mode_id']);
  }

  List<AcpSessionMode> _availableModesFromRaw(Object? raw) {
    if (raw is! List) return const <AcpSessionMode>[];
    return raw
        .whereType<Map>()
        .map((item) {
          final mode = _metadataMap(item);
          final id =
              _nonEmptyString(mode['id']) ??
              _nonEmptyString(mode['modeId']) ??
              _nonEmptyString(mode['mode_id']) ??
              _nonEmptyString(mode['value']);
          if (id == null) return null;
          final name =
              _nonEmptyString(mode['name']) ??
              _nonEmptyString(mode['label']) ??
              _nonEmptyString(mode['displayName']) ??
              _nonEmptyString(mode['display_name']) ??
              id;
          return AcpSessionMode(id: id, name: name);
        })
        .whereType<AcpSessionMode>()
        .toList();
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

  Future<List<AgentEvent>> _cacheImmediateSessionUpdates(
    acp.AcpClient client,
    String sessionId,
  ) async {
    final events = <AgentEvent>[];
    final subscription = client.sessionUpdates(sessionId).listen((update) {
      final event = _eventFromAcpUpdate(update, sessionId: sessionId);
      if (event != null) {
        events.add(event);
      }
    }, onError: (_) {});
    try {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    } finally {
      await subscription.cancel();
    }
    return events;
  }

  void _captureProtocolOut(String line) {
    try {
      final message = jsonDecode(line);
      if (message is! Map) return;
      final id = _jsonRpcIdKey(message['id']);
      final method = message['method'];
      if (id == null || method is! String) return;
      _pendingRawProtocolRequests[id] = _RawProtocolRequest(
        method: method,
        params: _dynamicMap(message['params']) ?? const <String, dynamic>{},
      );
    } on Object {
      return;
    }
  }

  void _captureProtocolIn(String line) {
    try {
      final message = jsonDecode(line);
      if (message is! Map) return;
      _captureRawToolCallSessionUpdate(message);
      if (!message.containsKey('result') && !message.containsKey('error')) {
        return;
      }
      final id = _jsonRpcIdKey(message['id']);
      if (id == null) return;
      final request = _pendingRawProtocolRequests.remove(id);
      if (request == null || !_isSessionResultMethod(request.method)) return;
      final result = _dynamicMap(message['result']);
      if (result == null) return;
      final sessionId =
          _sessionIdFromMap(result) ??
          _sessionIdFromMap(request.params) ??
          _nonEmptyString(result['id']);
      if (sessionId == null) return;
      _rawSessionResultsBySession[sessionId] = result;
    } on Object {
      return;
    }
  }

  void _captureRawToolCallSessionUpdate(Map message) {
    if (message['method'] != 'session/update') return;
    final params = _dynamicMap(message['params']);
    if (params == null) return;
    final sessionId = _sessionIdFromMap(params);
    final update = _dynamicMap(params['update']);
    if (sessionId == null || update == null) return;
    final kind = update['sessionUpdate'];
    if (kind != 'tool_call' && kind != 'tool_call_update') return;
    final toolCallId = _toolCallIdFromRawMetadata(update);
    if (toolCallId == null) return;

    final states = _rawToolCallStatesBySession.putIfAbsent(
      sessionId,
      () => <String, Map<String, Object?>>{},
    );
    final rawMetadata = _metadataMap(update);
    final existing = kind == 'tool_call' ? null : states[toolCallId];
    states[toolCallId] = <String, Object?>{
      ...?existing,
      ...rawMetadata,
      'toolCallId': toolCallId,
    };

    final rawSnapshot = Map<String, Object?>.from(states[toolCallId]!);
    final events = _rawToolCallEventsBySession.putIfAbsent(
      sessionId,
      () => <Map<String, Object?>>[],
    );
    events.add(rawSnapshot);
    if (events.length > _maxRawToolCallEventIds) {
      events.removeRange(0, events.length - _maxRawToolCallEventIds);
    }
    if (_isTerminalRawToolCallStatus(rawSnapshot['status'])) {
      states.remove(toolCallId);
      if (states.isEmpty) {
        _rawToolCallStatesBySession.remove(sessionId);
      }
    }
  }

  Map<String, Object?>? _takeRawToolCallState(String sessionId) {
    final events = _rawToolCallEventsBySession[sessionId];
    if (events == null || events.isEmpty) return null;
    final raw = events.removeAt(0);
    if (events.isEmpty) {
      _rawToolCallEventsBySession.remove(sessionId);
    }
    return raw;
  }

  Map<String, Object?> _normalizedRawToolCallMetadata(
    Map<String, Object?> raw,
  ) {
    final metadata = <String, Object?>{};
    for (final entry in raw.entries) {
      if (entry.key == 'sessionUpdate') continue;
      metadata[entry.key] = entry.value;
    }
    final toolCallId = _toolCallIdFromRawMetadata(metadata);
    if (toolCallId != null) {
      metadata['toolCallId'] = toolCallId;
    }
    final rawInput = metadata['raw_input'];
    if (rawInput != null && metadata['rawInput'] == null) {
      metadata['rawInput'] = rawInput;
    }
    final rawOutput = metadata['raw_output'];
    if (rawOutput != null && metadata['rawOutput'] == null) {
      metadata['rawOutput'] = rawOutput;
    }
    return metadata;
  }

  String? _toolCallIdFromRawMetadata(Map raw) {
    for (final key in const [
      'toolCallId',
      'tool_call_id',
      'id',
      'callId',
      'call_id',
    ]) {
      final value = raw[key];
      if (value is String && value.trim().isNotEmpty) {
        return value.trim();
      }
    }
    return null;
  }

  bool _isTerminalRawToolCallStatus(Object? status) {
    if (status is! String) return false;
    final normalized = status.trim().toLowerCase();
    return normalized == 'completed' ||
        normalized == 'failed' ||
        normalized == 'cancelled' ||
        normalized == 'rejected' ||
        normalized == 'error' ||
        normalized == 'applied';
  }

  String? _jsonRpcIdKey(Object? id) {
    if (id == null) return null;
    return jsonEncode(id);
  }

  bool _isSessionResultMethod(String method) {
    return method == 'session/new' ||
        method == 'session/load' ||
        method == 'session/resume' ||
        method == 'session/fork';
  }

  @override
  Future<void> cancel() async {
    final sessionId = _activeSessionId;
    final client = _client;
    if (client == null || sessionId == null) return;
    _permissionBridge.cancelSession(sessionId);
    await client.cancel(sessionId: sessionId);
  }

  @override
  Future<void> respondToPermissionRequest({
    required String id,
    required AcpPermissionDecision decision,
  }) async {
    _permissionBridge.respond(id: id, decision: decision);
  }

  @override
  Future<void> dispose() async {
    await _disposeActiveClient(closePermissionStream: true);
  }

  Future<void> _disposeActiveClient({
    required bool closePermissionStream,
  }) async {
    final client = _client;
    final transport = _transport;
    _client = null;
    _transport = null;
    _capabilities = null;
    _supportsLoadSession = false;
    _supportsListSessions = false;
    _supportsResumeSession = false;
    _activeSessionId = null;
    _modesBySession.clear();
    _cwdBySession.clear();
    _additionalDirectoriesBySession.clear();
    _modeOverridesBySession.clear();
    _configOptionsBySession.clear();
    _modelConfigOptionsFromModelsBySession.clear();
    _pendingRawProtocolRequests.clear();
    _rawSessionResultsBySession.clear();
    _rawToolCallEventsBySession.clear();
    _rawToolCallStatesBySession.clear();
    if (closePermissionStream) {
      await _permissionBridge.dispose();
    } else {
      _permissionBridge.cancelAll();
    }
    await _disposeClient(client, transport);
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

  static List<Map<String, dynamic>> _mcpServersForCapabilities(
    List<Map<String, dynamic>> servers,
    AcpAgentCapabilities capabilities,
  ) {
    return servers
        .where((server) => _mcpServerSupportedByAgent(server, capabilities))
        .map(Map<String, dynamic>.from)
        .toList();
  }

  static Map<String, dynamic> _copyMcpServerConfig(
    Map<String, dynamic> server,
  ) {
    final copy = Map<String, dynamic>.from(server);
    final type = copy['type'];
    if (type is String && type.trim().isNotEmpty) {
      copy['type'] = type.trim().toLowerCase();
    }
    return copy;
  }

  static bool _mcpServerSupportedByAgent(
    Map<String, dynamic> server,
    AcpAgentCapabilities capabilities,
  ) {
    return switch (_mcpServerTransportType(server)) {
      'stdio' => true,
      'http' => capabilities.mcp.http,
      'sse' => capabilities.mcp.sse,
      'acp' => capabilities.mcp.acp,
      _ => false,
    };
  }

  static String _mcpServerTransportType(Map<String, dynamic> server) {
    final type = server['type'];
    if (type is String && type.trim().isNotEmpty) {
      return type.trim().toLowerCase();
    }
    final url = server['url'];
    if (url is String && url.trim().isNotEmpty) return 'http';
    return 'stdio';
  }

  Future<void> _disposeClient(
    acp.AcpClient? client,
    acp.AcpTransport? transport,
  ) async {
    await transport?.stop();
    try {
      await client?.dispose().timeout(const Duration(milliseconds: 500));
    } on TimeoutException {
      // The underlying package can wait for a still-open JSON-RPC stream while
      // shutting down. The stdio process has already been stopped above.
    }
  }
}

class _InteractivePermissionProvider implements acp.PermissionProvider {
  const _InteractivePermissionProvider(
    this.bridge, {
    required this.allowFilesystemReadTextFile,
    required this.allowFilesystemWriteTextFile,
  });

  final _AcpPermissionBridge bridge;
  final bool allowFilesystemReadTextFile;
  final bool allowFilesystemWriteTextFile;

  @override
  Future<acp.PermissionOutcome> request(acp.PermissionOptions options) async {
    if (options.toolName == 'read_text_file' && !allowFilesystemReadTextFile) {
      return acp.PermissionOutcome.deny;
    }
    if (options.toolName == 'write_text_file' &&
        !allowFilesystemWriteTextFile) {
      return acp.PermissionOutcome.deny;
    }
    return bridge.request(options);
  }
}

class _AcpPermissionBridge {
  final StreamController<AcpPermissionRequest> _requests =
      StreamController<AcpPermissionRequest>.broadcast(sync: true);
  final Map<String, _PendingPermissionRequest> _pending =
      <String, _PendingPermissionRequest>{};
  int _nextId = 0;
  bool _isClosed = false;

  Stream<AcpPermissionRequest> get requests => _requests.stream;

  Future<acp.PermissionOutcome> request(acp.PermissionOptions options) async {
    if (_isClosed || !_requests.hasListener) {
      return acp.PermissionOutcome.cancelled;
    }

    final id = 'permission-${++_nextId}';
    final completer = Completer<acp.PermissionOutcome>();
    _pending[id] = _PendingPermissionRequest(
      sessionId: options.sessionId,
      completer: completer,
    );
    _requests.add(
      AcpPermissionRequest(
        id: id,
        title: options.title,
        rationale: options.rationale,
        sessionId: options.sessionId,
        toolName: options.toolName,
        toolKind: options.toolKind,
        options: List<String>.unmodifiable(options.options),
        requestedAt: DateTime.now(),
        metadata: Map<String, Object?>.unmodifiable(options.metadata),
      ),
    );

    try {
      return await completer.future;
    } finally {
      _pending.remove(id);
    }
  }

  void respond({required String id, required AcpPermissionDecision decision}) {
    final pending = _pending[id];
    if (pending == null || pending.completer.isCompleted) return;
    pending.completer.complete(_outcomeForDecision(decision));
  }

  void cancelSession(String sessionId) {
    final ids = _pending.entries
        .where((entry) => entry.value.sessionId == sessionId)
        .map((entry) => entry.key)
        .toList();
    for (final id in ids) {
      respond(id: id, decision: AcpPermissionDecision.cancel);
    }
  }

  void cancelAll() {
    final ids = _pending.keys.toList();
    for (final id in ids) {
      respond(id: id, decision: AcpPermissionDecision.cancel);
    }
  }

  Future<void> dispose() async {
    if (_isClosed) return;
    _isClosed = true;
    cancelAll();
    await _requests.close();
  }

  acp.PermissionOutcome _outcomeForDecision(AcpPermissionDecision decision) {
    return switch (decision) {
      AcpPermissionDecision.allow => acp.PermissionOutcome.allow,
      AcpPermissionDecision.deny => acp.PermissionOutcome.deny,
      AcpPermissionDecision.cancel => acp.PermissionOutcome.cancelled,
    };
  }
}

class _PendingPermissionRequest {
  const _PendingPermissionRequest({
    required this.sessionId,
    required this.completer,
  });

  final String sessionId;
  final Completer<acp.PermissionOutcome> completer;
}

class _RawProtocolRequest {
  const _RawProtocolRequest({required this.method, required this.params});

  final String method;
  final Map<String, dynamic> params;
}
