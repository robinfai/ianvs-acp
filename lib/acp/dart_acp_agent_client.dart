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

class DartAcpAgentClient implements AcpAgentClient {
  DartAcpAgentClient({
    String? agentCommand,
    List<String>? agentArgs,
    Map<String, String>? envOverrides,
    List<Map<String, dynamic>>? mcpServers,
    this.enableFilesystemReadTextFile = false,
    this.enableFilesystemWriteTextFile = false,
    this.allowFilesystemReadOutsideWorkspace = false,
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
  final bool enableFilesystemReadTextFile;
  final bool enableFilesystemWriteTextFile;
  final bool allowFilesystemReadOutsideWorkspace;

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
  final Map<String, List<AcpConfigOption>> _configOptionsBySession =
      <String, List<AcpConfigOption>>{};
  final Map<String, _RawProtocolRequest> _pendingRawProtocolRequests =
      <String, _RawProtocolRequest>{};
  final Map<String, Map<String, dynamic>> _rawSessionResultsBySession =
      <String, Map<String, dynamic>>{};

  static const int _maxEmbeddedAttachmentBytes = 256 * 1024;
  static const int _maxEmbeddedBinaryAttachmentBytes = 1024 * 1024;
  static const int _maxImageAttachmentBytes = 4 * 1024 * 1024;
  static const int _maxAudioAttachmentBytes = 8 * 1024 * 1024;
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
    await dispose();
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
    );
    final transport = acp.StdioTransport(
      command: agentCommand,
      args: agentArgs,
      envOverrides: envOverrides,
      logger: config.logger,
      onProtocolOut: _captureProtocolOut,
      onProtocolIn: _captureProtocolIn,
    );
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

  @override
  Future<AgentSession> createSession({required String cwd}) async {
    final client = _requireClient();
    final sessionId = await client.newSession(cwd);
    _activeSessionId = sessionId;
    _cwdBySession[sessionId] = cwd;
    final response = _takeRawSessionResult(sessionId);
    _cacheRawConfigOptions(sessionId, response['configOptions']);
    _cacheRawModes(sessionId, response['modes']);
    final initialEvents = await _cacheImmediateSessionUpdates(
      client,
      sessionId,
    );
    return AgentSession(
      id: sessionId,
      cwd: cwd,
      createdAt: DateTime.now(),
      initialEvents: initialEvents,
    );
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
      _cwdBySession[sessionId] = cwd;
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
      final event = _eventFromAcpUpdate(update);
      if (event != null) {
        events.add(event);
      }
    });
    try {
      await client.loadSession(sessionId: sessionId, workspaceRoot: cwd);
      await Future<void>.delayed(Duration.zero);
      _activeSessionId = sessionId;
      _cwdBySession[sessionId] = cwd;
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
    final forkedSessionId = result.sessionId;
    _activeSessionId = forkedSessionId;
    _cwdBySession[forkedSessionId] = cwd;
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
    _modeOverridesBySession.remove(sessionId);
    _configOptionsBySession.remove(sessionId);
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
    try {
      final content = await _promptContentBlocks(
        prompt,
        attachments,
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

  Future<List<Map<String, dynamic>>> _promptContentBlocks(
    String prompt,
    List<PromptAttachment> attachments, {
    String? workspaceRoot,
  }) async {
    final blocks = <Map<String, dynamic>>[];
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
    final uri = _mentionTokenToUri(_unquoteMentionToken(token), workspaceRoot);
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

  String _unquoteMentionToken(String token) {
    if (token.length < 2) return token;
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

  Future<Map<String, dynamic>?> _imageContentBlock(
    PromptAttachment attachment,
  ) async {
    if (_capabilities?.prompt.image != true) return null;
    final mimeType = _imageMimeType(attachment);
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
    final mimeType = _audioMimeType(attachment);
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
    if (!_isTextAttachment(attachment)) return null;

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

  bool _isTextAttachment(PromptAttachment attachment) {
    final mimeType = attachment.mimeType?.toLowerCase();
    if (mimeType != null) {
      if (mimeType.startsWith('text/')) return true;
      if (const <String>{
        'application/json',
        'application/javascript',
        'application/toml',
        'application/xml',
        'application/x-yaml',
        'application/yaml',
      }.contains(mimeType)) {
        return true;
      }
    }

    final name = attachment.name.toLowerCase();
    return const <String>[
      '.c',
      '.cc',
      '.cpp',
      '.css',
      '.csv',
      '.dart',
      '.go',
      '.h',
      '.html',
      '.java',
      '.js',
      '.json',
      '.kt',
      '.log',
      '.md',
      '.php',
      '.py',
      '.rb',
      '.rs',
      '.sh',
      '.sql',
      '.swift',
      '.toml',
      '.ts',
      '.txt',
      '.xml',
      '.yaml',
      '.yml',
      '.zsh',
    ].any(name.endsWith);
  }

  Future<Map<String, dynamic>?> _embeddedBinaryResourceBlock(
    PromptAttachment attachment,
  ) async {
    if (_capabilities?.prompt.embeddedContext != true) return null;
    if (_isTextAttachment(attachment)) return null;
    if (_imageMimeType(attachment) != null) return null;
    if (_audioMimeType(attachment) != null) return null;

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

  String? _imageMimeType(PromptAttachment attachment) {
    final mimeType = attachment.mimeType?.toLowerCase();
    if (mimeType != null && mimeType.startsWith('image/')) {
      return mimeType;
    }

    final name = attachment.name.toLowerCase();
    if (name.endsWith('.png')) return 'image/png';
    if (name.endsWith('.jpg') || name.endsWith('.jpeg')) {
      return 'image/jpeg';
    }
    if (name.endsWith('.gif')) return 'image/gif';
    if (name.endsWith('.webp')) return 'image/webp';
    if (name.endsWith('.bmp')) return 'image/bmp';
    return null;
  }

  String? _audioMimeType(PromptAttachment attachment) {
    final mimeType = attachment.mimeType?.toLowerCase();
    if (mimeType != null && mimeType.startsWith('audio/')) {
      return mimeType;
    }

    final name = attachment.name.toLowerCase();
    if (name.endsWith('.wav') || name.endsWith('.wave')) return 'audio/wav';
    if (name.endsWith('.mp3')) return 'audio/mpeg';
    if (name.endsWith('.m4a')) return 'audio/mp4';
    if (name.endsWith('.aac')) return 'audio/aac';
    if (name.endsWith('.flac')) return 'audio/flac';
    if (name.endsWith('.ogg')) return 'audio/ogg';
    if (name.endsWith('.opus')) return 'audio/opus';
    if (name.endsWith('.webm')) return 'audio/webm';
    if (name.endsWith('.aiff') || name.endsWith('.aif')) {
      return 'audio/aiff';
    }
    return null;
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
    final subscription = client
        .sessionUpdates(sessionId)
        .listen(
          (update) {
            if (!acceptingUpdates || events.isClosed) return;
            final event = _eventFromAcpUpdate(
              update,
              includeUserMessages: false,
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
      await subscription.cancel();
      if (!events.isClosed) {
        await events.close();
      }
    }
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

  List<AcpConfigOption> _cacheRawConfigOptions(String sessionId, Object? raw) {
    final mapped = _configOptionsFromRaw(raw);
    _configOptionsBySession[sessionId] = mapped;
    return mapped;
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

  void _cacheSessionResult({
    required String sessionId,
    required Map<String, dynamic> rawResponse,
    List<acp.ConfigOption>? typedConfigOptions,
  }) {
    if (rawResponse.isNotEmpty || typedConfigOptions == null) {
      _cacheRawConfigOptions(sessionId, rawResponse['configOptions']);
    } else {
      _cacheConfigOptions(sessionId, typedConfigOptions);
    }
    _cacheRawModes(sessionId, rawResponse['modes']);
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
    final currentModeId = map['currentModeId'] is String
        ? map['currentModeId'] as String
        : null;
    final availableModes = map['availableModes'] is List
        ? (map['availableModes'] as List)
              .whereType<Map>()
              .map((item) {
                final mode = _metadataMap(item);
                final id = mode['id'];
                if (id is! String || id.isEmpty) return null;
                return AcpSessionMode(
                  id: id,
                  name: mode['name'] is String ? mode['name'] as String : id,
                );
              })
              .whereType<AcpSessionMode>()
              .toList()
        : const <AcpSessionMode>[];
    if (currentModeId == null && availableModes.isEmpty) return null;
    return AcpSessionModeInfo(
      currentModeId: currentModeId,
      availableModes: availableModes,
    );
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
      final event = _eventFromAcpUpdate(update);
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
      final id = message['id'];
      final method = message['method'];
      if (id == null || method is! String) return;
      _pendingRawProtocolRequests[id.toString()] = _RawProtocolRequest(
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
      final id = message['id'];
      if (id == null) return;
      final request = _pendingRawProtocolRequests.remove(id.toString());
      if (request == null || !_isSessionResultMethod(request.method)) return;
      final result = _dynamicMap(message['result']);
      if (result == null) return;
      final resultSessionId = result['sessionId'];
      final requestSessionId = request.params['sessionId'];
      final sessionId = resultSessionId is String
          ? resultSessionId
          : requestSessionId is String
          ? requestSessionId
          : null;
      if (sessionId == null || sessionId.isEmpty) return;
      _rawSessionResultsBySession[sessionId] = result;
    } on Object {
      return;
    }
  }

  bool _isSessionResultMethod(String method) {
    return method == 'session/new' ||
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
    _modeOverridesBySession.clear();
    _configOptionsBySession.clear();
    _pendingRawProtocolRequests.clear();
    _rawSessionResultsBySession.clear();
    _permissionBridge.cancelAll();
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

  Stream<AcpPermissionRequest> get requests => _requests.stream;

  Future<acp.PermissionOutcome> request(acp.PermissionOptions options) async {
    if (!_requests.hasListener) {
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
