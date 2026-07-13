import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_acp/dart_acp.dart' as acp;
import 'package:mime/mime.dart' as mime;

import 'acp_adapter_packages.dart';
import 'acp_agent_capabilities.dart';
import 'acp_agent_client.dart';
import 'acp_endpoint_validator.dart';
import 'acp_permission_request.dart';
import 'acp_session_catalog.dart';
import 'acp_session_settings.dart';
import 'agent_event.dart';
import 'agent_session.dart';
import 'prompt_attachment.dart';
import 'streamable_http_acp_transport.dart';
import 'web_socket_acp_transport.dart';

enum AcpSessionListBudgetReason {
  repeatedCursor,
  pageLimit,
  entryLimit,
  cursorByteLimit,
}

class AcpSessionListBudgetException implements Exception {
  const AcpSessionListBudgetException({
    required this.reason,
    required this.limit,
    required this.observed,
  });

  final AcpSessionListBudgetReason reason;
  final int limit;
  final int observed;

  @override
  String toString() =>
      'AcpSessionListBudgetException(reason: ${reason.name}, '
      'limit: $limit, observed: $observed)';
}

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
    this.sessionListMaxPages = 100,
    this.sessionListMaxEntries = 10000,
    this.sessionListMaxCursorBytes = 8 * 1024,
    this.maxSessionReplayItems = 2048,
    this.maxSessionReplayBytes = 16 * 1024 * 1024,
    this.maxSessionToolCallItems = 512,
    this.maxSessionToolCallBytes = 8 * 1024 * 1024,
    this.maxTerminalHandles = acp.defaultMaxTerminalHandles,
    this.maxTerminalHandlesPerSession = acp.defaultMaxTerminalHandlesPerSession,
    this.maxPromptAttachmentCount = 16,
    this.maxPromptAttachmentSourceBytes = 8 * 1024 * 1024,
    this.maxPromptAttachmentEncodedBytes = 12 * 1024 * 1024,
    this.beforeAttachmentSecureOpenForTesting,
    acp.AcpInputBudget inputBudget = const acp.AcpInputBudget(),
  }) : inputBudget = _validatedInputBudget(inputBudget),
       agentCommand = agentCommand ?? _defaultAgentCommand(),
       agentArgs = agentArgs ?? const [AcpAdapterPackages.codex],
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
             ) {
    acp.validateTerminalHandleLimits(
      maxTerminalHandles: maxTerminalHandles,
      maxTerminalHandlesPerSession: maxTerminalHandlesPerSession,
    );
    final webSocketEndpoint = agentWebSocketUrl;
    if (webSocketEndpoint != null) {
      validateAcpEndpoint(
        webSocketEndpoint,
        allowedSchemes: const <String>{'ws', 'wss'},
      );
    }
    final httpEndpoint = agentHttpUrl;
    if (httpEndpoint != null) {
      validateAcpEndpoint(
        httpEndpoint,
        allowedSchemes: const <String>{'http', 'https'},
      );
    }
    for (final server in this.mcpServers) {
      _validateMcpServerEndpoint(server);
    }
    if (sessionListMaxPages <= 0 ||
        sessionListMaxEntries <= 0 ||
        sessionListMaxCursorBytes <= 0) {
      throw ArgumentError('Session list budgets must be greater than zero.');
    }
    if (maxSessionReplayItems <= 0 ||
        maxSessionReplayBytes < acp.minimumSessionReplayBytes ||
        maxSessionToolCallItems <= 0 ||
        maxSessionToolCallBytes <= 0) {
      throw ArgumentError(
        'Session state budgets are invalid; maxSessionReplayBytes must be at '
        'least ${acp.minimumSessionReplayBytes}.',
      );
    }
    if (maxPromptAttachmentCount <= 0 ||
        maxPromptAttachmentSourceBytes <= 0 ||
        maxPromptAttachmentEncodedBytes < 2) {
      throw ArgumentError(
        'Prompt attachment count and source budgets must be positive; the '
        'encoded budget must fit the empty JSON array.',
      );
    }
  }

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
  final int sessionListMaxPages;
  final int sessionListMaxEntries;
  final int sessionListMaxCursorBytes;
  final int maxSessionReplayItems;
  final int maxSessionReplayBytes;
  final int maxSessionToolCallItems;
  final int maxSessionToolCallBytes;
  final int maxTerminalHandles;
  final int maxTerminalHandlesPerSession;
  final int maxPromptAttachmentCount;
  final int maxPromptAttachmentSourceBytes;
  final int maxPromptAttachmentEncodedBytes;
  final FutureOr<void> Function(String canonicalPath)?
  beforeAttachmentSecureOpenForTesting;
  final acp.AcpInputBudget inputBudget;

  acp.AcpClient? _client;
  acp.AcpTransport? _transport;
  acp.AcpClient? _connectingClient;
  acp.AcpTransport? _connectingTransport;
  acp.AcpBoundedObservationListener? _boundedObservationListener;
  acp.AcpBoundedObservationListener? _connectingBoundedObservationListener;
  AcpAgentCapabilities? _capabilities;
  final _AcpPermissionBridge _permissionBridge = _AcpPermissionBridge();
  bool _supportsLoadSession = false;
  bool _supportsListSessions = false;
  bool _supportsResumeSession = false;
  bool _connectInProgress = false;
  bool _disposed = false;
  Future<void>? _disposeFuture;
  String? _activeSessionId;
  final Map<String, _RawPromptOperation> _rawPromptOperationsBySession =
      <String, _RawPromptOperation>{};
  final Map<String, String> _modeOverridesBySession = <String, String>{};
  final Map<String, AcpSessionModeInfo> _modesBySession =
      <String, AcpSessionModeInfo>{};
  final Map<String, String> _cwdBySession = <String, String>{};
  final Map<String, List<String>> _additionalDirectoriesBySession =
      <String, List<String>>{};
  final Map<String, List<AcpConfigOption>> _configOptionsBySession =
      <String, List<AcpConfigOption>>{};
  final Map<String, List<acp.AcpInputOmission>> _settingsOmissionsBySession =
      <String, List<acp.AcpInputOmission>>{};
  final Map<String, acp.AcpInputOmission> _configUpdateOmissionsBySession =
      <String, acp.AcpInputOmission>{};
  final Set<String> _boundedModesBySession = <String>{};
  final Map<String, _ConfigOptionMutationQueue> _configMutationQueuesBySession =
      <String, _ConfigOptionMutationQueue>{};

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
    if (_disposed) {
      throw StateError('Codex ACP client has been disposed.');
    }
    if (_connectInProgress) {
      throw StateError('Codex ACP client connection is already in progress.');
    }
    _connectInProgress = true;
    try {
      await _disposeActiveClient(closePermissionStream: false);
      if (_disposed) {
        throw StateError('Codex ACP client has been disposed.');
      }
      for (final server in mcpServers) {
        _validateMcpServerEndpoint(server);
      }
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
            ? acp.DefaultTerminalProvider(
                maxActiveHandles: maxTerminalHandles,
                maxActiveHandlesPerSession: maxTerminalHandlesPerSession,
              )
            : null,
      );
      final transport = _transportForConfig(config);
      _connectingTransport = transport;
      late final acp.AcpClient client;
      try {
        client = await acp.AcpClient.start(
          config: config,
          transport: transport,
          maxReplayItems: maxSessionReplayItems,
          maxReplayBytes: maxSessionReplayBytes,
          maxToolCallItems: maxSessionToolCallItems,
          maxToolCallBytes: maxSessionToolCallBytes,
          maxTerminalHandles: maxTerminalHandles,
          maxTerminalHandlesPerSession: maxTerminalHandlesPerSession,
          inputBudget: inputBudget,
        );
      } on Object {
        if (identical(_connectingTransport, transport)) {
          _connectingTransport = null;
          await transport.stop();
        }
        rethrow;
      }
      if (_disposed || !identical(_connectingTransport, transport)) {
        await _disposeClient(client, transport);
        throw StateError('Codex ACP client has been disposed.');
      }
      _connectingClient = client;
      late final acp.AcpBoundedObservationListener observationListener;
      observationListener = (observation) {
        _handleBoundedObservation(client, observation);
      };
      _connectingBoundedObservationListener = observationListener;
      client.addBoundedObservationListener(observationListener);
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
        if (_disposed || !identical(_connectingClient, client)) {
          throw StateError('Codex ACP client has been disposed.');
        }
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
          agentCapabilities: initializeResult['agentCapabilities'],
          agentInfo: initializeResult['agentInfo'],
          authMethods: initializeResult['authMethods'],
          clientInfo: _clientInfo,
          clientCapabilities: clientCapabilities,
          hasFsProvider: config.fsProvider != null,
          hasTerminalProvider: config.terminalProvider != null,
          allowReadOutsideWorkspace: config.allowReadOutsideWorkspace,
          inputBudget: inputBudget,
        );
        final compatibleMcpServers = _mcpServersForCapabilities(
          configuredMcpServers,
          capabilities,
        );
        sessionMcpServers
          ..clear()
          ..addAll(compatibleMcpServers);
        _client = client;
        _transport = transport;
        _boundedObservationListener = observationListener;
        _connectingBoundedObservationListener = null;
        _connectingClient = null;
        _connectingTransport = null;
        _supportsLoadSession = capabilities.loadSession;
        _supportsListSessions = capabilities.session.list;
        _supportsResumeSession = capabilities.session.resume;
        _capabilities = capabilities;
      } catch (_) {
        if (identical(_connectingClient, client)) {
          client.removeBoundedObservationListener(observationListener);
          _connectingBoundedObservationListener = null;
          _connectingClient = null;
          _connectingTransport = null;
          await _disposeClient(client, transport);
        }
        rethrow;
      }
    } finally {
      _connectInProgress = false;
    }
  }

  acp.AcpTransport _transportForConfig(acp.AcpConfig config) {
    final webSocketUrl = agentWebSocketUrl;
    if (webSocketUrl != null) {
      return WebSocketAcpTransport(
        endpoint: webSocketUrl,
        headers: agentHeaders,
      );
    }
    final httpUrl = agentHttpUrl;
    if (httpUrl != null) {
      return StreamableHttpAcpTransport(
        endpoint: httpUrl,
        headers: agentHeaders,
      );
    }
    return acp.StdioTransport(
      command: agentCommand,
      args: agentArgs,
      cwd: agentCwd,
      envOverrides: envOverrides,
      logger: config.logger,
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
      await client.resumeSession(
        sessionId: sessionId,
        workspaceRoot: cwd,
        additionalDirectories: directories,
      );
      _requireActiveClientOperation(client);
      _activeSessionId = sessionId;
      _cwdBySession[sessionId] = cwd;
      _additionalDirectoriesBySession[sessionId] = directories;
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
      _requireActiveClientOperation(client);
      _activeSessionId = sessionId;
      _cwdBySession[sessionId] = cwd;
      _additionalDirectoriesBySession[sessionId] = directories;
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
    var pages = 0;
    do {
      if (pages >= sessionListMaxPages) {
        throw AcpSessionListBudgetException(
          reason: AcpSessionListBudgetReason.pageLimit,
          limit: sessionListMaxPages,
          observed: pages + 1,
        );
      }
      final result = await client.listSessions(cursor: cursor);
      pages += 1;
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
            meta: session.meta ?? const <String, Object?>{},
            metaOmission: session.metaOmission,
          );
        }),
      );
      if (sessions.length > sessionListMaxEntries) {
        throw AcpSessionListBudgetException(
          reason: AcpSessionListBudgetReason.entryLimit,
          limit: sessionListMaxEntries,
          observed: sessions.length,
        );
      }

      final nextCursor = result.nextCursor;
      if (nextCursor == null) break;
      final cursorBytes = utf8.encode(nextCursor).length;
      if (cursorBytes > sessionListMaxCursorBytes) {
        throw AcpSessionListBudgetException(
          reason: AcpSessionListBudgetReason.cursorByteLimit,
          limit: sessionListMaxCursorBytes,
          observed: cursorBytes,
        );
      }
      if (!seenCursors.add(nextCursor)) {
        throw AcpSessionListBudgetException(
          reason: AcpSessionListBudgetReason.repeatedCursor,
          limit: sessionListMaxPages,
          observed: pages,
        );
      }
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
      final omissions =
          _settingsOmissionsBySession[sessionId] ??
          const <acp.AcpInputOmission>[];
      return AcpSessionSettings(
        configOptions: configOptions,
        omissions: omissions,
        truncated: omissions.any((omission) => omission.truncated),
      );
    }

    final modes = _boundedModesBySession.contains(sessionId)
        ? null
        : client.sessionModes(sessionId);
    final cachedModes = _modesBySession[sessionId];
    final currentModeId =
        _modeOverridesBySession[sessionId] ??
        modes?.currentModeId ??
        cachedModes?.currentModeId;
    final packageModeProjection = <AcpSessionMode>[];
    if (modes != null) {
      for (final mode in modes.availableModes) {
        packageModeProjection.add(AcpSessionMode(id: mode.id, name: mode.name));
      }
    }
    final packageModes = List<AcpSessionMode>.unmodifiable(
      packageModeProjection,
    );
    final availableModes = cachedModes?.availableModes.isNotEmpty == true
        ? cachedModes!.availableModes
        : packageModes;
    return AcpSessionSettings(
      modes: AcpSessionModeInfo(
        currentModeId: currentModeId,
        availableModes: availableModes,
      ),
      configOptions: configOptions,
      omissions:
          _settingsOmissionsBySession[sessionId] ??
          const <acp.AcpInputOmission>[],
      truncated:
          _settingsOmissionsBySession[sessionId]?.any(
            (omission) => omission.truncated,
          ) ??
          false,
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
    return _runSerializedConfigMutation(sessionId, client, (queue) async {
      late final List<acp.ConfigOption> typed;
      try {
        typed = await client.setConfigOption(
          sessionId: sessionId,
          configId: configId,
          value: value.toString(),
        );
      } on acp.AcpInputLimitExceeded catch (error) {
        if (_isCurrentConfigMutation(sessionId, client, queue)) {
          _rejectConfigUpdate(
            sessionId,
            acp.AcpInputOmission(
              reason: acp.AcpInputOmissionReason.inputLimit,
              resource: 'config_options',
              truncated: false,
              limit: error.limit,
              observedAtLeast: error.observedAtLeast,
            ),
          );
        }
        rethrow;
      } on Object {
        if (_isCurrentConfigMutation(sessionId, client, queue)) {
          _rejectConfigUpdate(sessionId, _invalidOmission('config_options'));
        }
        rethrow;
      }
      _requireCurrentConfigMutation(sessionId, client, queue);
      final mapped = _configOptionsFromAcpAtomically(typed);
      if (mapped == null) {
        _rejectConfigUpdate(sessionId, _invalidOmission('config_options'));
        throw const FormatException('Invalid ACP config options.');
      }
      _configOptionsBySession[sessionId] = mapped;
      _configUpdateOmissionsBySession.remove(sessionId);
      _replaceSettingsOmission(
        sessionId,
        resource: 'config_options',
        omission: null,
      );
      if (mapped.isNotEmpty) _clearModes(sessionId);
      return mapped;
    });
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
    _invalidateConfigMutationQueue(sessionId);
    _invalidateRawPromptOperation(sessionId);
    try {
      await client.closeSession(sessionId: sessionId);
    } on acp.SessionCloseCleanupException {
      _clearSessionState(sessionId);
      rethrow;
    }
    _clearSessionState(sessionId);
  }

  void _clearSessionState(String sessionId) {
    _invalidateConfigMutationQueue(sessionId);
    if (_activeSessionId == sessionId) {
      _activeSessionId = null;
    }
    _modesBySession.remove(sessionId);
    _cwdBySession.remove(sessionId);
    _additionalDirectoriesBySession.remove(sessionId);
    _modeOverridesBySession.remove(sessionId);
    _configOptionsBySession.remove(sessionId);
    _configUpdateOmissionsBySession.remove(sessionId);
    _settingsOmissionsBySession.remove(sessionId);
    _boundedModesBySession.remove(sessionId);
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
    _invalidateAllConfigMutationQueues();
    await client.sendRaw('logout', const <String, dynamic>{});
    _activeSessionId = null;
    _modesBySession.clear();
    _cwdBySession.clear();
    _additionalDirectoriesBySession.clear();
    _modeOverridesBySession.clear();
    _configOptionsBySession.clear();
    _configUpdateOmissionsBySession.clear();
    _settingsOmissionsBySession.clear();
    _boundedModesBySession.clear();
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
    List<PromptAttachment> attachments = const <PromptAttachment>[],
  }) {
    late final StreamController<AgentEvent> controller;
    StreamSubscription<AgentEvent>? forwarding;
    acp.AcpClient? operationClient;
    _RawPromptOperation? operation;
    controller = StreamController<AgentEvent>(
      onListen: () {
        try {
          final client = _requireClient();
          operationClient = client;
          _activeSessionId = sessionId;
          final currentOperation = _RawPromptOperation(sessionId);
          operation = currentOperation;
          final accepted = !_rawPromptOperationsBySession.containsKey(
            sessionId,
          );
          if (accepted) {
            _rawPromptOperationsBySession[sessionId] = currentOperation;
          }
          forwarding =
              _runRawPromptOperation(
                client: client,
                operation: currentOperation,
                prompt: prompt,
                attachments: attachments,
                accepted: accepted,
              ).listen(
                controller.add,
                onError: controller.addError,
                onDone: controller.close,
              );
        } on Object catch (error, stackTrace) {
          controller.addError(error, stackTrace);
          unawaited(controller.close());
        }
      },
      onPause: () => forwarding?.pause(),
      onResume: () => forwarding?.resume(),
      onCancel: () async {
        final currentOperation = operation;
        final client = operationClient;
        final settlements = <Future<_VoidFutureSettlement>>[];
        if (currentOperation != null &&
            !currentOperation.finished &&
            !currentOperation.locallyInvalidated &&
            client != null) {
          currentOperation.cancelRequested = true;
          settlements.add(
            _settleVoidFuture(
              _cancelRawPromptOperation(client, currentOperation),
            ),
          );
          if (!currentOperation.streamCancellation.isCompleted) {
            currentOperation.streamCancellation.complete();
          }
        }
        Future<void> forwardingCleanup;
        try {
          forwardingCleanup = forwarding?.cancel() ?? Future<void>.value();
        } on Object catch (error, stackTrace) {
          forwardingCleanup = Future<void>.error(error, stackTrace);
        }
        settlements.add(_settleVoidFuture(forwardingCleanup));
        final outcomes = await Future.wait<_VoidFutureSettlement>(settlements);
        for (final outcome in outcomes) {
          outcome.throwIfFailed();
        }
      },
    );
    return controller.stream;
  }

  Stream<AgentEvent> _runRawPromptOperation({
    required acp.AcpClient client,
    required _RawPromptOperation operation,
    required String prompt,
    required List<PromptAttachment> attachments,
    required bool accepted,
  }) async* {
    try {
      if (!accepted) {
        throw StateError('An ACP prompt operation is already active.');
      }
      if (operation.locallyInvalidated) return;
      final content = await _promptContentBlocks(
        prompt,
        attachments,
        workspaceRoot: _cwdBySession[operation.sessionId],
      );
      if (operation.locallyInvalidated) return;
      if (operation.cancelRequested) {
        await _cancelRawPromptOperation(client, operation);
        return;
      }
      await for (final event in _sendRawPrompt(
        client: client,
        operation: operation,
        content: content,
      )) {
        if (operation.acceptsEvents) {
          yield event;
        }
      }
    } catch (error) {
      if (!operation.acceptsEvents) return;
      final details = _agentErrorDetails(error);
      yield AgentEvent(
        type: AgentEventType.error,
        text: details.text,
        metadata: details.metadata,
        timestamp: DateTime.now(),
      );
    } finally {
      operation.finished = true;
      final cancelCompletion = operation.cancelCompletion;
      if (operation.cancelRequested &&
          operation.owner == null &&
          cancelCompletion != null &&
          !cancelCompletion.isCompleted) {
        cancelCompletion.complete();
      }
      if (accepted &&
          identical(
            _rawPromptOperationsBySession[operation.sessionId],
            operation,
          )) {
        _rawPromptOperationsBySession.remove(operation.sessionId);
      }
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
            omissions: update.omissions,
            timestamp: DateTime.now(),
          );
        }
        return AgentEvent(
          type: acpRoleToEventType(update.role),
          text: text.isEmpty ? _contentBlocksLabel(contentBlocks) : text,
          metadata: hasNonTextContent
              ? <String, Object?>{'contentBlocks': contentBlocks}
              : const <String, Object?>{},
          omissions: update.omissions,
          timestamp: DateTime.now(),
        );
      case acp.ToolCallUpdate():
        final toolCall = update.toolCall;
        final metadata = _toolCallMetadata(toolCall);
        return AgentEvent(
          type: AgentEventType.toolCall,
          text: toolCall.title?.trim().isNotEmpty == true
              ? toolCall.title!
              : toolCall.toolCallId.trim().isNotEmpty
              ? toolCall.toolCallId
              : 'Tool call',
          metadata: metadata,
          omissions: _singleOmission(toolCall.omission),
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
            'entries': _planEntryProjection(plan.entries),
            if (plan.metadata != null) 'metadata': plan.metadata,
            'truncated': plan.truncated,
          },
          omissions: _singleOmission(plan.omission),
          timestamp: DateTime.now(),
        );
      case acp.DiffUpdate():
        final diff = update.diff;
        return AgentEvent(
          type: AgentEventType.status,
          text: diff.uri ?? diff.id,
          metadata: <String, Object?>{
            'kind': 'diff',
            'id': diff.id,
            'status': diff.status.name,
            if (diff.uri != null) 'uri': diff.uri,
            'changes': _diffChangeProjection(diff.changes),
            if (diff.description != null) 'description': diff.description,
            'truncated': diff.truncated,
          },
          omissions: _singleOmission(diff.omission),
          timestamp: DateTime.now(),
        );
      case acp.AvailableCommandsUpdate():
        final commands = update.omission == null
            ? _commandProjectionAtomically(update.commands)
            : null;
        final omission =
            update.omission ??
            (commands == null ? _invalidOmission('available_commands') : null);
        final safeCommands = commands ?? const <Map<String, Object?>>[];
        return AgentEvent(
          type: AgentEventType.status,
          text: _commandEventText(update.commands, rejected: omission != null),
          metadata: <String, Object?>{
            'kind': 'commands',
            'commands': safeCommands,
          },
          omissions: _singleOmission(omission),
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
        if (update.omission != null) {
          return AgentEvent(
            type: AgentEventType.status,
            text: '',
            metadata: const <String, Object?>{'kind': 'mode', 'mode': ''},
            omissions: _singleOmission(update.omission),
            timestamp: DateTime.now(),
          );
        }
        if (updateSessionId != null &&
            (_configOptionsBySession[updateSessionId]?.isNotEmpty ?? false)) {
          return null;
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
        final mapped = _eventFromUnknownUpdate(update, sessionId: sessionId);
        if (mapped != null) return mapped;
        if (kind == null) {
          final omission = update.omission;
          if (omission == null) return null;
          return AgentEvent(
            type: AgentEventType.status,
            text: 'Unknown update omitted.',
            metadata: const <String, Object?>{'kind': 'unknown'},
            omissions: _singleOmission(omission),
            timestamp: DateTime.now(),
          );
        }
        final text = '[Unknown update: $kind]';
        return AgentEvent(
          type: AgentEventType.status,
          text: text,
          metadata: <String, Object?>{'kind': 'unknown', 'sessionUpdate': kind},
          timestamp: DateTime.now(),
        );
    }
  }

  AgentEvent? _eventFromUnknownUpdate(
    acp.UnknownUpdate update, {
    required String? sessionId,
  }) {
    final raw = update.raw;
    final rawBody = raw['update'];
    final body = rawBody is Map<String, dynamic> ? rawBody : raw;

    final kind = update.boundedKind ?? body['sessionUpdate'];
    if (kind == 'config_option_update') {
      final options = sessionId == null
          ? const <AcpConfigOption>[]
          : _configOptionsBySession[sessionId] ?? const <AcpConfigOption>[];
      final omission =
          update.omission ??
          (sessionId == null
              ? _invalidOmission('config_options')
              : _configUpdateOmissionsBySession[sessionId]);
      return AgentEvent(
        type: AgentEventType.status,
        text: 'Session config options updated.',
        metadata: <String, Object?>{
          'kind': 'config_option_update',
          'configOptions': options,
        },
        omissions: _singleOmission(omission),
        timestamp: DateTime.now(),
      );
    }

    if (kind == 'session_info_update') {
      final title = body['title'];
      final updatedAt = body['updatedAt'];
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
        },
        omissions: _singleOmission(update.omission),
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
    final amount = _numFromRaw(raw['amount']);
    final rawCurrency = raw['currency'];
    final currency = rawCurrency is String ? rawCurrency.trim() : '';
    if (amount == null || currency.isEmpty) return null;
    return <String, Object?>{'amount': amount, 'currency': currency};
  }

  String? _unknownUpdateKind(acp.UnknownUpdate update) {
    final boundedKind = update.boundedKind;
    if (boundedKind != null) return boundedKind;
    final raw = update.raw;
    final direct = _nonEmptyString(raw['sessionUpdate']);
    if (direct != null) return direct;
    final body = raw['update'];
    if (body is Map) return _nonEmptyString(body['sessionUpdate']);
    return null;
  }

  List<Map<String, Object?>> _contentBlocksFromDelta(acp.MessageDelta update) {
    final projected = <Map<String, Object?>>[];
    for (final block in update.content) {
      projected.add(_contentBlockProjection(block));
    }
    return List<Map<String, Object?>>.unmodifiable(projected);
  }

  String _contentBlocksLabel(List<Map<String, Object?>> blocks) {
    var nonTextCount = 0;
    String? singleType;
    for (final block in blocks) {
      if (block['type'] == 'text') continue;
      nonTextCount += 1;
      singleType = block['type']?.toString();
    }
    if (nonTextCount == 0) return '';
    if (nonTextCount == 1) {
      final type = singleType ?? 'content';
      return 'Received $type content.';
    }
    return 'Received $nonTextCount content blocks.';
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
    final budget = _PromptAttachmentBudget(
      maxCount: maxPromptAttachmentCount,
      maxSourceBytes: maxPromptAttachmentSourceBytes,
      maxEncodedBytes: maxPromptAttachmentEncodedBytes,
    );
    for (final attachment in attachments) {
      if (!budget.tryStartAttachment()) break;
      final content = await _contentBlockForAttachment(attachment, budget);
      if (content != null && budget.tryCommitBlock(content)) {
        blocks.add(content);
        continue;
      }
      final link = _resourceLinkBlock(attachment, budget);
      if (link != null) blocks.add(link);
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

  Future<Map<String, dynamic>?> _contentBlockForAttachment(
    PromptAttachment attachment,
    _PromptAttachmentBudget budget,
  ) async {
    final image = await _imageContentBlock(attachment, budget);
    if (image != null) return image;
    final audio = await _audioContentBlock(attachment, budget);
    if (audio != null) return audio;
    final embedded = await _embeddedTextResourceBlock(attachment, budget);
    if (embedded != null) return embedded;
    return _embeddedBinaryResourceBlock(attachment, budget);
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
    _PromptAttachmentBudget budget,
  ) async {
    if (_capabilities?.prompt.image != true) return null;
    final mimeType = attachment.imageMimeType;
    if (mimeType == null) return null;
    if (!_attachmentMetadataMayFit(attachment, budget.remainingEncodedBytes)) {
      return null;
    }

    try {
      final read = await _readBoundedAttachmentBytes(
        attachment.path,
        maxBytes: budget.sourceLimit(_maxImageAttachmentBytes),
      );
      budget.recordSourceRead(read.sourceBytesRead);
      final bytes = read.bytes;
      if (bytes == null) return null;
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
    _PromptAttachmentBudget budget,
  ) async {
    if (_capabilities?.prompt.audio != true) return null;
    final mimeType = attachment.audioMimeType;
    if (mimeType == null) return null;
    if (!_stringMetadataMayFit(mimeType, budget.remainingEncodedBytes)) {
      return null;
    }

    try {
      final read = await _readBoundedAttachmentBytes(
        attachment.path,
        maxBytes: budget.sourceLimit(_maxAudioAttachmentBytes),
      );
      budget.recordSourceRead(read.sourceBytesRead);
      final bytes = read.bytes;
      if (bytes == null) return null;
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
    _PromptAttachmentBudget budget,
  ) async {
    if (_capabilities?.prompt.embeddedContext != true) return null;
    if (!attachment.isText) return null;
    if (!_attachmentMetadataMayFit(attachment, budget.remainingEncodedBytes)) {
      return null;
    }

    try {
      final read = await _readBoundedAttachmentBytes(
        attachment.path,
        maxBytes: budget.sourceLimit(_maxEmbeddedAttachmentBytes),
      );
      budget.recordSourceRead(read.sourceBytesRead);
      final bytes = read.bytes;
      if (bytes == null) return null;
      final text = utf8.decode(bytes, allowMalformed: false);
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
    _PromptAttachmentBudget budget,
  ) async {
    if (_capabilities?.prompt.embeddedContext != true) return null;
    if (attachment.isText) return null;
    if (attachment.isImage) return null;
    if (attachment.isAudio) return null;
    if (!_attachmentMetadataMayFit(attachment, budget.remainingEncodedBytes)) {
      return null;
    }

    try {
      final read = await _readBoundedAttachmentBytes(
        attachment.path,
        maxBytes: budget.sourceLimit(_maxEmbeddedBinaryAttachmentBytes),
      );
      budget.recordSourceRead(read.sourceBytesRead);
      final bytes = read.bytes;
      if (bytes == null) return null;
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

  Map<String, dynamic>? _resourceLinkBlock(
    PromptAttachment attachment,
    _PromptAttachmentBudget budget,
  ) {
    if (!_attachmentMetadataMayFit(attachment, budget.remainingEncodedBytes)) {
      return null;
    }
    final link = attachment.toResourceLink().map<String, dynamic>(
      (key, value) => MapEntry(key, value),
    );
    final declaredSize = link['size'];
    if (declaredSize is int && declaredSize < 0) link.remove('size');
    return budget.tryCommitBlock(link) ? link : null;
  }

  bool _attachmentMetadataMayFit(
    PromptAttachment attachment,
    int remainingEncodedBytes,
  ) {
    if (remainingEncodedBytes <= 0) return false;
    const metadataCodeUnitLimit = 64 * 1024;
    var remainingCodeUnits = remainingEncodedBytes < metadataCodeUnitLimit
        ? remainingEncodedBytes
        : metadataCodeUnitLimit;
    for (final value in <String>[
      attachment.path,
      attachment.name,
      ?attachment.mimeType,
    ]) {
      if (value.length > remainingCodeUnits) return false;
      remainingCodeUnits -= value.length;
    }
    return true;
  }

  bool _stringMetadataMayFit(String value, int remainingEncodedBytes) {
    if (remainingEncodedBytes <= 0) return false;
    const metadataCodeUnitLimit = 64 * 1024;
    final limit = remainingEncodedBytes < metadataCodeUnitLimit
        ? remainingEncodedBytes
        : metadataCodeUnitLimit;
    return value.length <= limit;
  }

  Future<_AttachmentReadResult> _readBoundedAttachmentBytes(
    String path, {
    required int maxBytes,
  }) async {
    if (maxBytes <= 0 ||
        (!Platform.isMacOS && !Platform.isLinux) ||
        !path.startsWith('/')) {
      return const _AttachmentReadResult.failure();
    }
    late final String canonicalPath;
    try {
      canonicalPath = await File(path).resolveSymbolicLinks();
    } on Object {
      return const _AttachmentReadResult.failure();
    }
    if (!canonicalPath.startsWith('/') || canonicalPath.length == 1) {
      return const _AttachmentReadResult.failure();
    }
    await beforeAttachmentSecureOpenForTesting?.call(canonicalPath);
    try {
      final bytes = await acp.readSecureFileBytes(
        canonicalRoot: '/',
        relativePath: canonicalPath.substring(1),
        maxReadBytes: maxBytes,
      );
      return _AttachmentReadResult.success(bytes);
    } on acp.SecureFsReadLimitExceeded {
      return _AttachmentReadResult.overflow(maxBytes + 1);
    } on Object {
      return const _AttachmentReadResult.failure();
    }
  }

  Stream<AgentEvent> _sendRawPrompt({
    required acp.AcpClient client,
    required _RawPromptOperation operation,
    required List<Map<String, dynamic>> content,
  }) async* {
    if (operation.locallyInvalidated) return;
    if (operation.cancelRequested) {
      await _cancelRawPromptOperation(client, operation);
      return;
    }
    final sessionId = operation.sessionId;
    final events = StreamController<AgentEvent>();
    var acceptingUpdates = false;
    final terminalSubscription = client.terminalEvents.listen(
      (update) {
        if (!acceptingUpdates || !operation.acceptsEvents || events.isClosed) {
          return;
        }
        final event = _eventFromTerminalEvent(update, sessionId);
        if (event != null) {
          events.add(event);
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (operation.acceptsEvents && !events.isClosed) {
          events.addError(error, stackTrace);
        }
      },
    );
    final subscription = client
        .sessionUpdates(sessionId)
        .listen(
          (update) {
            if (!acceptingUpdates ||
                !operation.acceptsEvents ||
                events.isClosed) {
              return;
            }
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
            if (operation.acceptsEvents && !events.isClosed) {
              events.addError(error, stackTrace);
            }
          },
        );
    try {
      await Future<void>.delayed(Duration.zero);
      if (operation.locallyInvalidated) return;
      if (operation.cancelRequested) {
        await _cancelRawPromptOperation(client, operation);
        return;
      }
      acceptingUpdates = true;
      unawaited(() async {
        acp.AcpSessionInputBudgetOwner? owner;
        try {
          if (operation.locallyInvalidated) return;
          owner = operation.owner;
          if (owner == null) {
            owner = client.beginPromptTurn(sessionId);
            operation.owner = owner;
          }
          if (operation.locallyInvalidated) return;
          if (operation.cancelRequested) {
            await _cancelRawPromptOperation(client, operation);
            return;
          }
          final request = client
              .sendRaw('session/prompt', <String, dynamic>{
                'sessionId': sessionId,
                'prompt': content,
              })
              .then<_RawPromptRpcOutcome>(
                _RawPromptRpcOutcome.response,
                onError: (Object error, StackTrace stackTrace) =>
                    _RawPromptRpcOutcome.error(error, stackTrace),
              );
          final outcome = await Future.any<_RawPromptRpcOutcome>(
            <Future<_RawPromptRpcOutcome>>[
              request,
              operation.streamCancellation.future.then(
                (_) => const _RawPromptRpcOutcome.cancelled(),
              ),
            ],
          );
          if (outcome.cancelled) return;
          final error = outcome.error;
          if (error != null) {
            Error.throwWithStackTrace(error, outcome.stackTrace!);
          }
          final response = outcome.response!;
          if (operation.acceptsEvents && !events.isClosed) {
            events.add(_eventFromPromptResponse(response));
          }
        } catch (error, stackTrace) {
          if (operation.acceptsEvents && !events.isClosed) {
            events.addError(error, stackTrace);
          }
        } finally {
          if (owner != null) {
            client.endPromptTurn(owner);
          }
          if (!events.isClosed) {
            await events.close();
          }
        }
      }());
      await for (final event in events.stream) {
        if (operation.acceptsEvents) {
          yield event;
        }
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

  void _handleBoundedObservation(
    acp.AcpClient source,
    acp.AcpBoundedObservation observation,
  ) {
    if (_disposed ||
        (!identical(_connectingClient, source) &&
            !identical(_client, source))) {
      return;
    }
    switch (observation) {
      case acp.AcpBoundedSessionResultObservation():
        _cacheBoundedSessionResult(observation.sessionId, observation.result);
      case acp.AcpBoundedUpdateObservation():
        _cacheBoundedUpdate(observation.sessionId, observation.update);
    }
  }

  void _cacheBoundedSessionResult(String sessionId, acp.SessionResult result) {
    final omissions = <acp.AcpInputOmission>[];
    for (final omission in result.omissions) {
      if (omission.resource == 'config_options' ||
          omission.resource == 'session_modes') {
        omissions.add(omission);
      }
    }
    final configRejected = _hasOmissionResource(
      result.omissions,
      'config_options',
    );
    final modesRejected = _hasOmissionResource(
      result.omissions,
      'session_modes',
    );

    if (configRejected) {
      _clearConfigOptions(sessionId);
    } else {
      final typedOptions = result.configOptions;
      if (typedOptions != null) {
        final mapped = _configOptionsFromAcpAtomically(typedOptions);
        if (mapped == null) {
          _clearConfigOptions(sessionId);
          omissions.add(_invalidOmission('config_options'));
        } else {
          _configOptionsBySession[sessionId] = mapped;
          _configUpdateOmissionsBySession.remove(sessionId);
        }
      }
    }

    if (modesRejected) {
      _clearModes(sessionId);
    } else {
      final typedModes = result.modes;
      if (typedModes != null) {
        _boundedModesBySession.add(sessionId);
        final mapped = _modeInfoFromAcpAtomically(typedModes);
        if (mapped == null) {
          _clearModes(sessionId);
          omissions.add(_invalidOmission('session_modes'));
        } else {
          _modesBySession[sessionId] = mapped;
          _modeOverridesBySession.remove(sessionId);
        }
      }
    }

    if (_configOptionsBySession[sessionId]?.isNotEmpty == true) {
      _clearModes(sessionId);
    }
    _replaceSettingsOmissions(sessionId, omissions);
  }

  void _cacheBoundedUpdate(String sessionId, acp.AcpUpdate update) {
    switch (update) {
      case acp.ModeUpdate():
        if (update.omission != null || update.currentModeId.trim().isEmpty) {
          _clearModes(sessionId);
          _replaceSettingsOmission(
            sessionId,
            resource: 'session_modes',
            omission: update.omission == null
                ? _invalidOmission('session_modes')
                : _omissionForResource(update.omission!, 'session_modes'),
          );
          return;
        }
        _boundedModesBySession.add(sessionId);
        final existing = _modesBySession[sessionId];
        _modesBySession[sessionId] = AcpSessionModeInfo(
          currentModeId: update.currentModeId,
          availableModes: existing?.availableModes ?? const <AcpSessionMode>[],
        );
        _modeOverridesBySession[sessionId] = update.currentModeId;
        _replaceSettingsOmission(
          sessionId,
          resource: 'session_modes',
          omission: null,
        );
        return;
      case acp.UnknownUpdate():
        if (update.boundedKind != 'config_option_update') return;
        final typedOmission = update.omission;
        if (typedOmission != null) {
          _rejectConfigUpdate(sessionId, typedOmission);
          return;
        }
        final body = _unknownUpdateBody(update);
        if (body == null) {
          _rejectConfigUpdate(sessionId, _invalidOmission('config_options'));
          return;
        }
        final rawOptions = body.containsKey('configOptions')
            ? body['configOptions']
            : body['config_options'];
        final mapped = _configOptionsFromOwnedUnknownAtomically(rawOptions);
        if (mapped == null) {
          _rejectConfigUpdate(sessionId, _invalidOmission('config_options'));
          return;
        }
        _configOptionsBySession[sessionId] = mapped;
        _configUpdateOmissionsBySession.remove(sessionId);
        _replaceSettingsOmission(
          sessionId,
          resource: 'config_options',
          omission: null,
        );
        if (mapped.isNotEmpty) _clearModes(sessionId);
        return;
      default:
        return;
    }
  }

  Map<String, dynamic>? _unknownUpdateBody(acp.UnknownUpdate update) {
    final rawBody = update.raw['update'];
    if (rawBody is Map<String, dynamic>) return rawBody;
    if (update.raw.containsKey('sessionUpdate')) return update.raw;
    return null;
  }

  List<AcpConfigOption>? _configOptionsFromOwnedUnknownAtomically(Object? raw) {
    if (raw is! List) return null;
    final mapped = <AcpConfigOption>[];
    for (final item in raw) {
      if (item is! Map) return null;
      final option = _configOptionFromOwnedUnknown(item);
      if (option == null) return null;
      mapped.add(option);
    }
    return List<AcpConfigOption>.unmodifiable(mapped);
  }

  AcpConfigOption? _configOptionFromOwnedUnknown(Map raw) {
    final id = _firstNonEmptyString(raw, const <String>[
      'id',
      'configId',
      'config_id',
      'key',
    ]);
    final type = _configOptionType(raw['type']);
    if (id == null || type == null) return null;
    final currentValue = _configValueFromRaw(
      raw['currentValue'] ??
          raw['current_value'] ??
          raw['value'] ??
          raw['selectedValue'] ??
          raw['selected'],
      type: type,
    );
    if (currentValue == null) return null;
    final rawChoices = raw['options'] ?? raw['choices'] ?? raw['values'];
    final choices = <AcpConfigOptionChoice>[];
    if (rawChoices != null) {
      if (rawChoices is! List) return null;
      for (final rawChoice in rawChoices) {
        final choice = _configChoiceFromOwnedUnknown(rawChoice);
        if (choice == null) return null;
        choices.add(choice);
      }
    }
    return AcpConfigOption(
      id: id,
      name:
          _firstNonEmptyString(raw, const <String>['name', 'label', 'title']) ??
          id,
      type: type,
      currentValue: currentValue,
      options: List<AcpConfigOptionChoice>.unmodifiable(choices),
      description: raw['description'] is String
          ? raw['description'] as String
          : null,
      category: raw['category'] is String ? raw['category'] as String : null,
      group: raw['group'] is String ? raw['group'] as String : null,
    );
  }

  AcpConfigOptionChoice? _configChoiceFromOwnedUnknown(Object? raw) {
    if (raw is String || raw is bool || raw is num) {
      final value = raw.toString();
      if (value.isEmpty) return null;
      return AcpConfigOptionChoice(value: value, name: value);
    }
    if (raw is! Map) return null;
    final value = _firstConfigChoiceValue(raw, const <String>[
      'value',
      'id',
      'key',
      'name',
    ]);
    if (value == null) return null;
    return AcpConfigOptionChoice(
      value: value,
      name:
          _firstNonEmptyString(raw, const <String>[
            'name',
            'label',
            'displayName',
          ]) ??
          value,
      description: raw['description'] is String
          ? raw['description'] as String
          : null,
    );
  }

  String? _firstNonEmptyString(Map raw, List<String> keys) {
    for (final key in keys) {
      final value = raw[key];
      if (value is String && value.trim().isNotEmpty) return value.trim();
    }
    return null;
  }

  String? _firstConfigChoiceValue(Map raw, List<String> keys) {
    for (final key in keys) {
      final value = _configChoiceValue(raw[key]);
      if (value != null) return value;
    }
    return null;
  }

  void _rejectConfigUpdate(
    String sessionId,
    acp.AcpInputOmission eventOmission,
  ) {
    _clearConfigOptions(sessionId);
    _configUpdateOmissionsBySession[sessionId] = eventOmission;
    _replaceSettingsOmission(
      sessionId,
      resource: 'config_options',
      omission: eventOmission.resource == 'config_options'
          ? eventOmission
          : _invalidOmission('config_options'),
    );
  }

  List<AcpConfigOption>? _configOptionsFromAcpAtomically(
    List<acp.ConfigOption> options,
  ) {
    final mapped = <AcpConfigOption>[];
    for (final option in options) {
      final id = option.id.trim();
      final type = _configOptionType(option.type);
      if (id.isEmpty || type == null) return null;
      final currentValue = _configValueFromRaw(option.currentValue, type: type);
      if (currentValue == null) return null;
      final choices = <AcpConfigOptionChoice>[];
      for (final choice in option.options) {
        final value = choice.value.trim();
        if (value.isEmpty) return null;
        choices.add(
          AcpConfigOptionChoice(
            value: value,
            name: choice.name.isEmpty ? value : choice.name,
            description: choice.description,
          ),
        );
      }
      mapped.add(
        AcpConfigOption(
          id: id,
          name: option.name.isEmpty ? id : option.name,
          type: type,
          currentValue: currentValue,
          options: List<AcpConfigOptionChoice>.unmodifiable(choices),
          description: option.description,
          category: option.category,
          group: option.group,
        ),
      );
    }
    return List<AcpConfigOption>.unmodifiable(mapped);
  }

  List<Map<String, Object?>>? _commandProjectionAtomically(
    List<acp.AvailableCommand> commands,
  ) {
    final projected = <Map<String, Object?>>[];
    for (final command in commands) {
      final name = command.name.trim();
      if (name.isEmpty) return null;
      Map<String, Object?>? input;
      final commandInput = command.input;
      if (commandInput != null) {
        input = Map<String, Object?>.unmodifiable(<String, Object?>{
          if (commandInput.hint != null) 'hint': commandInput.hint,
        });
      }
      projected.add(
        Map<String, Object?>.unmodifiable(<String, Object?>{
          'name': name,
          if (command.description != null) 'description': command.description,
          if (command.parameters != null) 'parameters': command.parameters,
          'input': ?input,
        }),
      );
    }
    return List<Map<String, Object?>>.unmodifiable(projected);
  }

  Map<String, Object?> _contentBlockProjection(acp.ContentBlock block) {
    switch (block) {
      case acp.TextContent():
        return Map<String, Object?>.unmodifiable(<String, Object?>{
          'type': 'text',
          'text': block.text,
        });
      case acp.ImageContent():
        return Map<String, Object?>.unmodifiable(<String, Object?>{
          'type': 'image',
          'mimeType': block.mimeType,
          'data': block.data,
        });
      case acp.AudioContent():
        return Map<String, Object?>.unmodifiable(<String, Object?>{
          'type': 'audio',
          'mimeType': block.mimeType,
          if (block.data != null) 'data': block.data,
          if (block.uri != null) 'uri': block.uri,
        });
      case acp.ResourceContent():
        final resource = <String, Object?>{
          'uri': block.uri,
          if (block.title != null) 'title': block.title,
          if (block.mimeType != null) 'mimeType': block.mimeType,
          if (block.size != null) 'size': block.size,
          if (block.text != null) 'text': block.text,
          if (block.blob != null) 'blob': block.blob,
        };
        if (block.embedded) {
          return Map<String, Object?>.unmodifiable(<String, Object?>{
            'type': 'resource',
            'resource': Map<String, Object?>.unmodifiable(resource),
          });
        }
        return Map<String, Object?>.unmodifiable(<String, Object?>{
          'type': 'resource_link',
          ...resource,
        });
      case acp.UnknownContent():
        final omission = block.omission;
        if (omission != null) {
          return Map<String, Object?>.unmodifiable(<String, Object?>{
            'type': 'omitted',
            ..._omissionProjection(omission),
          });
        }
        return block.data;
    }
  }

  List<Map<String, Object?>> _planEntryProjection(List<acp.PlanEntry> entries) {
    final projected = <Map<String, Object?>>[];
    for (final entry in entries) {
      projected.add(
        Map<String, Object?>.unmodifiable(<String, Object?>{
          'content': entry.content,
          'priority': entry.priority.name,
          'status': switch (entry.status) {
            acp.PlanEntryStatus.inProgress => 'in_progress',
            _ => entry.status.name,
          },
          if (entry.metadata != null) 'metadata': entry.metadata,
        }),
      );
    }
    return List<Map<String, Object?>>.unmodifiable(projected);
  }

  List<Map<String, Object?>> _diffChangeProjection(
    List<acp.DiffChange> changes,
  ) {
    final projected = <Map<String, Object?>>[];
    for (final change in changes) {
      projected.add(
        Map<String, Object?>.unmodifiable(<String, Object?>{
          'type': change.type,
          if (change.line != null) 'line': change.line,
          if (change.content != null) 'content': change.content,
          if (change.oldContent != null) 'oldContent': change.oldContent,
          if (change.newContent != null) 'newContent': change.newContent,
        }),
      );
    }
    return List<Map<String, Object?>>.unmodifiable(projected);
  }

  Map<String, Object?> _omissionProjection(acp.AcpInputOmission omission) {
    return <String, Object?>{
      'reason': switch (omission.reason) {
        acp.AcpInputOmissionReason.inputLimit => 'input_limit',
        acp.AcpInputOmissionReason.invalidEncoding => 'invalid_encoding',
        acp.AcpInputOmissionReason.invalidImage => 'invalid_image',
        acp.AcpInputOmissionReason.invalidStructure => 'invalid_structure',
      },
      'resource': omission.resource,
      'truncated': omission.truncated,
      if (omission.limit != null) 'limit': omission.limit,
      if (omission.observedAtLeast != null)
        'observedAtLeast': omission.observedAtLeast,
    };
  }

  Map<String, Object?> _toolCallMetadata(acp.ToolCall toolCall) {
    List<Map<String, Object?>>? locations;
    final typedLocations = toolCall.locations;
    if (typedLocations != null) {
      final projected = <Map<String, Object?>>[];
      for (final location in typedLocations) {
        projected.add(
          Map<String, Object?>.unmodifiable(<String, Object?>{
            'path': location.path,
            if (location.line != null) 'line': location.line,
          }),
        );
      }
      locations = List<Map<String, Object?>>.unmodifiable(projected);
    }
    return Map<String, Object?>.unmodifiable(<String, Object?>{
      'kind': 'tool',
      'toolCallId': toolCall.toolCallId,
      'status': switch (toolCall.status) {
        acp.ToolCallStatus.inProgress => 'in_progress',
        _ => toolCall.status.name,
      },
      if (toolCall.title != null) 'title': toolCall.title,
      if (toolCall.kind != null) 'toolKind': toolCall.kind!.name,
      if (toolCall.content != null) 'content': toolCall.content,
      'locations': ?locations,
      if (toolCall.rawInput != null) 'rawInput': toolCall.rawInput,
      if (toolCall.rawOutput != null) 'rawOutput': toolCall.rawOutput,
    });
  }

  String _commandEventText(
    List<acp.AvailableCommand> commands, {
    required bool rejected,
  }) {
    if (rejected || commands.isEmpty) return 'No available commands';
    final buffer = StringBuffer();
    for (var index = 0; index < commands.length; index += 1) {
      if (index > 0) buffer.write(', ');
      buffer.write(commands[index].name);
    }
    return buffer.toString();
  }

  List<acp.AcpInputOmission> _singleOmission(acp.AcpInputOmission? omission) {
    if (omission == null) return const <acp.AcpInputOmission>[];
    return List<acp.AcpInputOmission>.unmodifiable(<acp.AcpInputOmission>[
      omission,
    ]);
  }

  AcpSessionModeInfo? _modeInfoFromAcpAtomically(
    ({String? currentModeId, List<({String id, String name})> availableModes})
    modes,
  ) {
    final mapped = <AcpSessionMode>[];
    for (final mode in modes.availableModes) {
      final id = mode.id.trim();
      if (id.isEmpty) return null;
      mapped.add(
        AcpSessionMode(id: id, name: mode.name.isEmpty ? id : mode.name),
      );
    }
    final currentModeId = modes.currentModeId?.trim();
    return AcpSessionModeInfo(
      currentModeId: currentModeId?.isEmpty == true ? null : currentModeId,
      availableModes: List<AcpSessionMode>.unmodifiable(mapped),
    );
  }

  bool _hasOmissionResource(
    List<acp.AcpInputOmission> omissions,
    String resource,
  ) {
    for (final omission in omissions) {
      if (omission.resource == resource) return true;
    }
    return false;
  }

  acp.AcpInputOmission _invalidOmission(String resource) {
    return acp.AcpInputOmission(
      reason: acp.AcpInputOmissionReason.invalidStructure,
      resource: resource,
      truncated: false,
    );
  }

  acp.AcpInputOmission _omissionForResource(
    acp.AcpInputOmission omission,
    String resource,
  ) {
    return acp.AcpInputOmission(
      reason: omission.reason,
      resource: resource,
      truncated: omission.truncated,
      limit: omission.limit,
      observedAtLeast: omission.observedAtLeast,
    );
  }

  void _clearConfigOptions(String sessionId) {
    _configOptionsBySession[sessionId] = const <AcpConfigOption>[];
    _configUpdateOmissionsBySession.remove(sessionId);
  }

  void _clearModes(String sessionId) {
    _boundedModesBySession.add(sessionId);
    _modesBySession.remove(sessionId);
    _modeOverridesBySession.remove(sessionId);
  }

  Future<T> _runSerializedConfigMutation<T>(
    String sessionId,
    acp.AcpClient client,
    Future<T> Function(_ConfigOptionMutationQueue queue) operation,
  ) {
    final queue = _configMutationQueuesBySession.putIfAbsent(
      sessionId,
      _ConfigOptionMutationQueue.new,
    );
    final previous = queue.tail;
    final completion = Completer<void>();
    final tail = completion.future;
    queue.tail = tail;

    return (() async {
      try {
        await Future.any<void>(<Future<void>>[previous, queue.invalidated]);
        _requireCurrentConfigMutation(sessionId, client, queue);
        return await operation(queue);
      } finally {
        if (!completion.isCompleted) completion.complete();
        if (_isCurrentConfigMutation(sessionId, client, queue) &&
            identical(queue.tail, tail)) {
          _configMutationQueuesBySession.remove(sessionId);
        }
      }
    })();
  }

  bool _isCurrentConfigMutation(
    String sessionId,
    acp.AcpClient client,
    _ConfigOptionMutationQueue queue,
  ) {
    return !_disposed &&
        identical(_client, client) &&
        queue.valid &&
        identical(_configMutationQueuesBySession[sessionId], queue);
  }

  void _requireCurrentConfigMutation(
    String sessionId,
    acp.AcpClient client,
    _ConfigOptionMutationQueue queue,
  ) {
    if (!_isCurrentConfigMutation(sessionId, client, queue)) {
      throw StateError('ACP config option operation is no longer active.');
    }
  }

  void _invalidateConfigMutationQueue(String sessionId) {
    final queue = _configMutationQueuesBySession.remove(sessionId);
    queue?.invalidate();
  }

  void _invalidateAllConfigMutationQueues() {
    final queues = _configMutationQueuesBySession.values.toList(
      growable: false,
    );
    _configMutationQueuesBySession.clear();
    for (final queue in queues) {
      queue.invalidate();
    }
  }

  void _replaceSettingsOmissions(
    String sessionId,
    List<acp.AcpInputOmission> omissions,
  ) {
    if (omissions.isEmpty) {
      _settingsOmissionsBySession.remove(sessionId);
      return;
    }
    _settingsOmissionsBySession[sessionId] =
        List<acp.AcpInputOmission>.unmodifiable(omissions);
  }

  void _replaceSettingsOmission(
    String sessionId, {
    required String resource,
    required acp.AcpInputOmission? omission,
  }) {
    final next = <acp.AcpInputOmission>[];
    for (final existing
        in _settingsOmissionsBySession[sessionId] ??
            const <acp.AcpInputOmission>[]) {
      if (existing.resource != resource) next.add(existing);
    }
    if (omission != null) next.add(omission);
    _replaceSettingsOmissions(sessionId, next);
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

  String? _configChoiceValue(Object? raw) {
    if (raw is String && raw.isNotEmpty) return raw;
    if (raw is num || raw is bool) return raw.toString();
    return null;
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

  void _invalidateRawPromptOperation(String sessionId) {
    final operation = _rawPromptOperationsBySession[sessionId];
    if (operation == null) return;
    operation.locallyInvalidated = true;
    if (identical(_rawPromptOperationsBySession[sessionId], operation)) {
      _rawPromptOperationsBySession.remove(sessionId);
    }
    if (!operation.streamCancellation.isCompleted) {
      operation.streamCancellation.complete();
    }
  }

  void _invalidateAllRawPromptOperations() {
    final operations = _rawPromptOperationsBySession.values.toList(
      growable: false,
    );
    for (final operation in operations) {
      operation.locallyInvalidated = true;
      if (identical(
        _rawPromptOperationsBySession[operation.sessionId],
        operation,
      )) {
        _rawPromptOperationsBySession.remove(operation.sessionId);
      }
      if (!operation.streamCancellation.isCompleted) {
        operation.streamCancellation.complete();
      }
    }
  }

  @override
  Future<void> cancel() async {
    final sessionId = _activeSessionId;
    final client = _client;
    if (client == null || sessionId == null) return;
    _permissionBridge.cancelSession(sessionId);
    final operation = _rawPromptOperationsBySession[sessionId];
    if (operation == null) return;
    operation.cancelRequested = true;
    final cancellation = _settleVoidFuture(
      _cancelRawPromptOperation(client, operation),
    );
    if (!operation.streamCancellation.isCompleted) {
      operation.streamCancellation.complete();
    }
    try {
      (await cancellation).throwIfFailed();
    } finally {
      if (identical(_rawPromptOperationsBySession[sessionId], operation)) {
        _rawPromptOperationsBySession.remove(sessionId);
      }
    }
  }

  Future<void> _cancelRawPromptOperation(
    acp.AcpClient client,
    _RawPromptOperation operation,
  ) {
    final completion = operation.cancelCompletion ??= Completer<void>();
    var owner = operation.owner;
    if (owner == null) {
      if (operation.locallyInvalidated || operation.finished) {
        if (!completion.isCompleted) completion.complete();
        return completion.future;
      }
      try {
        owner = client.beginPromptTurn(operation.sessionId);
        operation.owner = owner;
      } on Object catch (error, stackTrace) {
        if (!completion.isCompleted) {
          completion.completeError(error, stackTrace);
        }
        return completion.future;
      }
    }
    if (operation.cancelSent) return completion.future;
    operation.cancelSent = true;
    try {
      unawaited(
        client
            .cancelPromptTurn(owner)
            .then<void>(
              (_) {
                if (!completion.isCompleted) completion.complete();
              },
              onError: (Object error, StackTrace stackTrace) {
                if (!completion.isCompleted) {
                  completion.completeError(error, stackTrace);
                }
              },
            ),
      );
    } on Object catch (error, stackTrace) {
      if (!completion.isCompleted) {
        completion.completeError(error, stackTrace);
      }
    }
    return completion.future;
  }

  @override
  Future<void> respondToPermissionRequest({
    required String id,
    required AcpPermissionDecision decision,
    String? selectedOptionId,
  }) async {
    _permissionBridge.respond(
      id: id,
      decision: decision,
      selectedOptionId: selectedOptionId,
    );
  }

  @override
  Future<void> dispose() {
    final existing = _disposeFuture;
    if (existing != null) return existing;
    _disposed = true;
    _invalidateAllConfigMutationQueues();
    final connectingClient = _connectingClient;
    final connectingTransport = _connectingTransport;
    final connectingListener = _connectingBoundedObservationListener;
    _connectingClient = null;
    _connectingTransport = null;
    _connectingBoundedObservationListener = null;
    return _disposeFuture = _disposeAll(
      connectingClient,
      connectingTransport,
      connectingListener,
    );
  }

  Future<void> _disposeAll(
    acp.AcpClient? connectingClient,
    acp.AcpTransport? connectingTransport,
    acp.AcpBoundedObservationListener? connectingListener,
  ) async {
    try {
      await _disposeClient(
        connectingClient,
        connectingTransport,
        connectingListener,
      );
    } finally {
      await _disposeActiveClient(closePermissionStream: true);
    }
  }

  Future<void> _disposeActiveClient({
    required bool closePermissionStream,
  }) async {
    _invalidateAllRawPromptOperations();
    _invalidateAllConfigMutationQueues();
    final client = _client;
    final transport = _transport;
    final observationListener = _boundedObservationListener;
    _client = null;
    _transport = null;
    _boundedObservationListener = null;
    _capabilities = null;
    _supportsLoadSession = false;
    _supportsListSessions = false;
    _supportsResumeSession = false;
    _activeSessionId = null;
    _rawPromptOperationsBySession.clear();
    _modesBySession.clear();
    _cwdBySession.clear();
    _additionalDirectoriesBySession.clear();
    _modeOverridesBySession.clear();
    _configOptionsBySession.clear();
    _configUpdateOmissionsBySession.clear();
    _settingsOmissionsBySession.clear();
    _boundedModesBySession.clear();
    if (closePermissionStream) {
      await _permissionBridge.dispose();
    } else {
      _permissionBridge.cancelAll();
    }
    await _disposeClient(client, transport, observationListener);
  }

  acp.AcpClient _requireClient() {
    final client = _client;
    if (client == null) {
      throw StateError('Codex ACP client is not connected.');
    }
    return client;
  }

  void _requireActiveClientOperation(acp.AcpClient client) {
    if (_disposed || !identical(_client, client)) {
      throw StateError('ACP client operation is no longer active.');
    }
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
    return Map<String, dynamic>.unmodifiable(copy);
  }

  static void _validateMcpServerEndpoint(Map<String, dynamic> server) {
    final transportType = _mcpServerTransportType(server);
    if (transportType != 'http' && transportType != 'sse') return;
    final url = server['url'];
    if (url is! String || url.trim().isEmpty) {
      throw const FormatException('Remote MCP server requires a URL.');
    }
    parseAndValidateAcpEndpoint(
      url,
      allowedSchemes: const <String>{'http', 'https'},
    );
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
    acp.AcpTransport? transport, [
    acp.AcpBoundedObservationListener? observationListener,
  ]) async {
    if (client != null && observationListener != null) {
      client.removeBoundedObservationListener(observationListener);
    }
    Object? firstError;
    StackTrace? firstStackTrace;
    try {
      await transport?.stop();
    } on Object catch (error, stackTrace) {
      firstError = error;
      firstStackTrace = stackTrace;
    }
    try {
      await client?.dispose().timeout(const Duration(milliseconds: 500));
    } on TimeoutException {
      // The underlying package can wait for a still-open JSON-RPC stream while
      // shutting down. The stdio process has already been stopped above.
    } on Object catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }
    final cleanupError = firstError;
    if (cleanupError != null) {
      Error.throwWithStackTrace(cleanupError, firstStackTrace!);
    }
  }
}

final class _ConfigOptionMutationQueue {
  Future<void> tail = Future<void>.value();
  bool valid = true;
  final Completer<void> _invalidation = Completer<void>();

  Future<void> get invalidated => _invalidation.future;

  void invalidate() {
    valid = false;
    if (!_invalidation.isCompleted) _invalidation.complete();
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
  Future<acp.PermissionDecision> request(acp.PermissionOptions options) async {
    if (options.toolName == 'read_text_file' && !allowFilesystemReadTextFile) {
      return const acp.PermissionDecision.deny();
    }
    if (options.toolName == 'write_text_file' &&
        !allowFilesystemWriteTextFile) {
      return const acp.PermissionDecision.deny();
    }
    return bridge.request(options);
  }
}

acp.AcpInputBudget _validatedInputBudget(acp.AcpInputBudget budget) {
  budget.validate();
  return budget;
}

final class _AttachmentReadResult {
  const _AttachmentReadResult.success(List<int> this.bytes)
    : sourceBytesRead = bytes.length;

  const _AttachmentReadResult.overflow(this.sourceBytesRead) : bytes = null;

  const _AttachmentReadResult.failure() : bytes = null, sourceBytesRead = 0;

  final List<int>? bytes;
  final int sourceBytesRead;
}

final class _PromptAttachmentBudget {
  _PromptAttachmentBudget({
    required this.maxCount,
    required this.maxSourceBytes,
    required this.maxEncodedBytes,
  });

  final int maxCount;
  final int maxSourceBytes;
  final int maxEncodedBytes;

  int _startedCount = 0;
  int _sourceBytes = 0;
  int _encodedBytes = 2;
  int _encodedBlockCount = 0;

  int get _remainingSourceBytes => maxSourceBytes - _sourceBytes;
  int get remainingEncodedBytes => maxEncodedBytes - _encodedBytes;

  bool tryStartAttachment() {
    if (_startedCount >= maxCount) return false;
    _startedCount += 1;
    return true;
  }

  int sourceLimit(int itemLimit) =>
      itemLimit < _remainingSourceBytes ? itemLimit : _remainingSourceBytes;

  void recordSourceRead(int observedBytes) {
    if (observedBytes <= 0) return;
    final remaining = _remainingSourceBytes;
    _sourceBytes += observedBytes < remaining ? observedBytes : remaining;
  }

  bool tryCommitBlock(Map<String, dynamic> block) {
    final blockBytes = utf8.encode(jsonEncode(block)).length;
    final additionalBytes = blockBytes + (_encodedBlockCount == 0 ? 0 : 1);
    if (additionalBytes > remainingEncodedBytes) return false;
    _encodedBytes += additionalBytes;
    _encodedBlockCount += 1;
    return true;
  }
}

final class _RawPromptOperation {
  _RawPromptOperation(this.sessionId);

  final String sessionId;
  acp.AcpSessionInputBudgetOwner? owner;
  bool cancelRequested = false;
  bool cancelSent = false;
  bool finished = false;
  bool locallyInvalidated = false;
  Completer<void>? cancelCompletion;
  final Completer<void> streamCancellation = Completer<void>();

  bool get acceptsEvents =>
      !locallyInvalidated && !cancelRequested && !finished;
}

final class _RawPromptRpcOutcome {
  const _RawPromptRpcOutcome.response(Map<String, dynamic> response)
    : this._(response: response);

  const _RawPromptRpcOutcome.error(Object error, StackTrace stackTrace)
    : this._(error: error, stackTrace: stackTrace);

  const _RawPromptRpcOutcome.cancelled() : this._(cancelled: true);

  const _RawPromptRpcOutcome._({
    this.response,
    this.error,
    this.stackTrace,
    this.cancelled = false,
  });

  final Map<String, dynamic>? response;
  final Object? error;
  final StackTrace? stackTrace;
  final bool cancelled;
}

Future<_VoidFutureSettlement> _settleVoidFuture(Future<void> future) {
  return future.then<_VoidFutureSettlement>(
    (_) => const _VoidFutureSettlement.success(),
    onError: (Object error, StackTrace stackTrace) =>
        _VoidFutureSettlement.failure(error, stackTrace),
  );
}

final class _VoidFutureSettlement {
  const _VoidFutureSettlement.success() : error = null, stackTrace = null;

  const _VoidFutureSettlement.failure(this.error, this.stackTrace);

  final Object? error;
  final StackTrace? stackTrace;

  void throwIfFailed() {
    final failure = error;
    if (failure != null) Error.throwWithStackTrace(failure, stackTrace!);
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

  Future<acp.PermissionDecision> request(acp.PermissionOptions options) async {
    if (_isClosed || !_requests.hasListener) {
      return const acp.PermissionDecision.cancelled();
    }

    final id = 'permission-${++_nextId}';
    final completer = Completer<acp.PermissionDecision>();
    _pending[id] = _PendingPermissionRequest(
      sessionId: options.sessionId,
      choices: List<acp.PermissionChoice>.unmodifiable(options.choices),
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
        choices: List<AcpPermissionChoice>.unmodifiable(
          options.choices.map(
            (choice) => AcpPermissionChoice(
              optionId: choice.optionId,
              name: choice.name,
              kind: choice.kind,
            ),
          ),
        ),
        requestedAt: DateTime.now(),
        metadata: Map<String, Object?>.unmodifiable(options.metadata),
        transientPolicyContext: Map<String, Object?>.unmodifiable(
          options.transientPolicyContext,
        ),
      ),
    );

    try {
      return await completer.future;
    } finally {
      _pending.remove(id);
    }
  }

  void respond({
    required String id,
    required AcpPermissionDecision decision,
    String? selectedOptionId,
  }) {
    final pending = _pending[id];
    if (pending == null || pending.completer.isCompleted) return;
    final optionId = selectedOptionId?.trim();
    if (optionId != null && optionId.isNotEmpty) {
      final choice = pending.choiceById(optionId);
      final choiceDecision = choice == null ? null : _decisionForChoice(choice);
      if (choiceDecision == null || choiceDecision != decision) {
        pending.completer.complete(const acp.PermissionDecision.cancelled());
        return;
      }
      pending.completer.complete(
        acp.PermissionDecision(
          _outcomeForDecision(decision),
          optionId: choice!.optionId,
        ),
      );
      return;
    }
    pending.completer.complete(
      acp.PermissionDecision(_outcomeForDecision(decision)),
    );
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

  AcpPermissionDecision? _decisionForChoice(acp.PermissionChoice choice) {
    final kind = choice.kind?.trim().toLowerCase() ?? '';
    if (kind == 'allow' || kind == 'allow_once' || kind == 'allow_always') {
      return AcpPermissionDecision.allow;
    }
    if (kind == 'deny' ||
        kind == 'deny_once' ||
        kind == 'deny_always' ||
        kind == 'reject' ||
        kind == 'reject_once' ||
        kind == 'reject_always') {
      return AcpPermissionDecision.deny;
    }
    final text = choice.name.trim().toLowerCase();
    final words = text
        .split(RegExp(r'[^a-z0-9]+'))
        .where((word) => word.isNotEmpty)
        .toSet();
    const deniedWords = <String>{
      'deny',
      'denied',
      'reject',
      'rejected',
      'decline',
      'declined',
      'block',
      'blocked',
      'disallow',
      'disallowed',
      'no',
    };
    if (words.any(deniedWords.contains) ||
        text.contains("don't allow") ||
        text.contains('do not allow')) {
      return AcpPermissionDecision.deny;
    }
    const allowedWords = <String>{
      'allow',
      'allowed',
      'approve',
      'approved',
      'accept',
      'accepted',
      'continue',
      'continued',
      'proceed',
      'proceeded',
      'yes',
    };
    if (words.any(allowedWords.contains)) {
      return AcpPermissionDecision.allow;
    }
    return null;
  }
}

class _PendingPermissionRequest {
  const _PendingPermissionRequest({
    required this.sessionId,
    required this.choices,
    required this.completer,
  });

  final String sessionId;
  final List<acp.PermissionChoice> choices;
  final Completer<acp.PermissionDecision> completer;

  acp.PermissionChoice? choiceById(String optionId) {
    for (final choice in choices) {
      if (choice.optionId == optionId) return choice;
    }
    return null;
  }
}
