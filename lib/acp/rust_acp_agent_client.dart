import 'dart:async';

import '../rust/ianvs_acp_native.dart';
import '../rust/ianvs_runtime_event.dart';
import 'acp_agent_capabilities.dart';
import 'acp_agent_client.dart';
import 'acp_permission_request.dart';
import 'acp_session_catalog.dart';
import 'acp_session_settings.dart';
import 'agent_event.dart';
import 'agent_session.dart';
import 'prompt_attachment.dart';
import 'session_title.dart';

/// ACP client projection backed by the Rust runtime.
///
/// This exposes only operations already owned by `ianvs-acp-core`. Unsupported
/// capability projections remain hidden; methods never open a parallel
/// protocol connection because that would split authoritative session state.
final class RustAcpAgentClient implements AcpAgentClient {
  RustAcpAgentClient({
    required this.agentName,
    required this.agentCommand,
    this.agentArgs = const <String>[],
    this.agentCwd,
    this.sessionStorePath,
    this.mcpServers = const <Map<String, Object?>>[],
    this.envOverrides = const <String, String>{},
    this.additionalDirectories = const <String>[],
    IanvsRustRuntime? runtime,
    this.connectTimeout = const Duration(seconds: 30),
    this.permissionTimeout = const Duration(minutes: 2),
    this.enableFilesystemReadTextFile = false,
    this.enableFilesystemWriteTextFile = false,
    this.enableTerminalProvider = false,
    this.maxTerminalHandles,
    this.maxTerminalHandlesPerSession,
    this.terminalDefaultOutputByteLimit,
    this.terminalMaxOutputByteLimit,
  }) : _runtime = runtime {
    if (permissionTimeout.inMilliseconds < 1) {
      throw ArgumentError.value(
        permissionTimeout,
        'permissionTimeout',
        'must be positive',
      );
    }
    if (runtime != null) _subscribeToRuntime(runtime);
  }

  final String agentName;
  final String agentCommand;
  final List<String> agentArgs;
  final String? agentCwd;
  final String? sessionStorePath;
  final List<Map<String, Object?>> mcpServers;
  final Map<String, String> envOverrides;
  final List<String> additionalDirectories;
  final Duration connectTimeout;
  final Duration permissionTimeout;
  final bool enableFilesystemReadTextFile;
  final bool enableFilesystemWriteTextFile;
  final bool enableTerminalProvider;
  final int? maxTerminalHandles;
  final int? maxTerminalHandlesPerSession;
  final int? terminalDefaultOutputByteLimit;
  final int? terminalMaxOutputByteLimit;
  IanvsRustRuntime? _runtime;

  final StreamController<AcpPermissionRequest> _permissionRequests =
      StreamController<AcpPermissionRequest>.broadcast(sync: true);
  final StreamController<AcpPermissionInvalidation> _permissionInvalidations =
      StreamController<AcpPermissionInvalidation>.broadcast(sync: true);
  final Map<String, Completer<AgentSession>> _pendingCreates =
      <String, Completer<AgentSession>>{};
  final Map<String, ({String cwd, List<String> additionalDirectories})>
  _createContexts =
      <String, ({String cwd, List<String> additionalDirectories})>{};
  final Map<String, Completer<List<AgentEvent>>> _pendingRestores =
      <String, Completer<List<AgentEvent>>>{};
  final Map<
    String,
    ({String sessionId, String cwd, List<String> additionalDirectories})
  >
  _restoreContexts =
      <
        String,
        ({String sessionId, String cwd, List<String> additionalDirectories})
      >{};
  final Map<String, String> _restoreRequestBySession = <String, String>{};
  final Map<String, List<AgentEvent>> _restoreEvents =
      <String, List<AgentEvent>>{};
  final Map<String, Completer<List<AcpProjectSessions>>> _pendingCatalogs =
      <String, Completer<List<AcpProjectSessions>>>{};
  final Map<String, Completer<void>> _pendingSessionLifecycle =
      <String, Completer<void>>{};
  final Map<String, Completer<void>> _pendingAuthentication =
      <String, Completer<void>>{};
  final Map<String, Completer<bool>> _pendingModes =
      <String, Completer<bool>>{};
  final Map<String, Completer<List<AcpConfigOption>>> _pendingConfigs =
      <String, Completer<List<AcpConfigOption>>>{};
  final Map<String, String> _configRequestBySession = <String, String>{};
  final Map<String, StreamController<AgentEvent>> _promptStreams =
      <String, StreamController<AgentEvent>>{};
  final Map<String, String> _promptRequestIds = <String, String>{};
  final Map<String, AcpPermissionRequest> _pendingPermissions =
      <String, AcpPermissionRequest>{};
  final Map<String, AgentSession> _sessions = <String, AgentSession>{};
  final Map<String, AcpSessionSettings> _settings =
      <String, AcpSessionSettings>{};
  StreamSubscription<IanvsRuntimeEvent>? _eventSubscription;
  Completer<void>? _connecting;
  AcpAgentCapabilities? _capabilities;
  String? _activePromptSessionId;
  int _nextRequestId = 1;
  bool _connected = false;
  bool _disposed = false;

  IanvsRustRuntime get _runtimeInstance {
    final existing = _runtime;
    if (existing != null) return existing;
    final created = IanvsRustRuntime();
    _runtime = created;
    _subscribeToRuntime(created);
    return created;
  }

  void _subscribeToRuntime(IanvsRustRuntime runtime) {
    _eventSubscription = runtime.events.listen(
      _handleRuntimeEvent,
      onError: _handleRuntimeStreamError,
    );
  }

  @override
  AcpAgentCapabilities? get capabilities => _capabilities;

  @override
  Stream<AcpPermissionRequest> get permissionRequests =>
      _permissionRequests.stream;

  @override
  Stream<AcpPermissionInvalidation> get permissionInvalidations =>
      _permissionInvalidations.stream;

  @override
  Future<void> connect() async {
    _ensureOpen();
    if (_connected) return;
    final existing = _connecting;
    if (existing != null) return existing.future;
    final completer = Completer<void>();
    _connecting = completer;
    try {
      _runtimeInstance.startAgent(
        agentName: agentName,
        command: agentCommand,
        args: agentArgs,
        environment: envOverrides,
        processCwd: agentCwd,
        sessionStorePath: sessionStorePath,
        mcpServers: mcpServers,
        permissionTimeout: permissionTimeout,
        enableFilesystemReadTextFile: enableFilesystemReadTextFile,
        enableFilesystemWriteTextFile: enableFilesystemWriteTextFile,
        enableTerminalProvider: enableTerminalProvider,
        maxTerminalHandles: maxTerminalHandles,
        maxTerminalHandlesPerSession: maxTerminalHandlesPerSession,
        terminalDefaultOutputByteLimit: terminalDefaultOutputByteLimit,
        terminalMaxOutputByteLimit: terminalMaxOutputByteLimit,
      );
      await completer.future.timeout(connectTimeout);
    } finally {
      _connecting = null;
    }
  }

  @override
  Future<AgentSession> createSession({
    required String cwd,
    List<String> additionalDirectories = const <String>[],
  }) async {
    await connect();
    final directories = _additionalDirectoriesForRequest(additionalDirectories);
    final requestId = _requestId('create');
    final completer = Completer<AgentSession>();
    _pendingCreates[requestId] = completer;
    _createContexts[requestId] = (cwd: cwd, additionalDirectories: directories);
    try {
      _runtimeInstance.createSession(
        requestId: requestId,
        cwd: cwd,
        additionalDirectories: directories,
      );
    } on Object {
      _pendingCreates.remove(requestId);
      _createContexts.remove(requestId);
      rethrow;
    }
    return completer.future;
  }

  @override
  Stream<AgentEvent> sendPrompt({
    required String sessionId,
    required String prompt,
    List<PromptAttachment> attachments = const <PromptAttachment>[],
  }) {
    _ensureConnected();
    if (_promptStreams.containsKey(sessionId)) {
      return Stream<AgentEvent>.error(
        StateError('Session $sessionId already has an active prompt.'),
      );
    }
    final output = StreamController<AgentEvent>(sync: true);
    final requestId = _requestId('prompt');
    _promptStreams[sessionId] = output;
    _promptRequestIds[sessionId] = requestId;
    _activePromptSessionId = sessionId;
    try {
      _runtimeInstance.prompt(
        requestId: requestId,
        sessionId: sessionId,
        text: prompt,
        attachments: attachments
            .map(
              (attachment) => <String, Object?>{
                'path': attachment.path,
                'name': attachment.name,
                if (attachment.mimeType != null)
                  'mimeType': attachment.mimeType,
                if (attachment.size != null) 'size': attachment.size,
              },
            )
            .toList(growable: false),
      );
    } on Object catch (error, stackTrace) {
      _promptStreams.remove(sessionId);
      _promptRequestIds.remove(sessionId);
      _activePromptSessionId = null;
      output.addError(error, stackTrace);
      unawaited(output.close());
    }
    return output.stream;
  }

  @override
  Future<void> cancel() async {
    _ensureConnected();
    final sessionId = _activePromptSessionId;
    if (sessionId == null) return;
    _runtimeInstance.cancel(
      requestId: _requestId('cancel'),
      sessionId: sessionId,
    );
  }

  @override
  Future<void> respondToPermissionRequest({
    required String id,
    required AcpPermissionDecision decision,
    String? selectedOptionId,
  }) async {
    _ensureConnected();
    final request = _pendingPermissions[id];
    if (request == null) {
      throw StateError('Permission request $id is no longer pending.');
    }
    final selected =
        selectedOptionId ?? request.singleUseChoiceFor(decision)?.optionId;
    final projection = decision == AcpPermissionDecision.cancel
        ? const <String, Object?>{'decision': 'cancelled'}
        : selected == null
        ? throw StateError(
            'Permission request $id has no unambiguous option for '
            '${decision.name}.',
          )
        : <String, Object?>{'decision': 'selected', 'optionId': selected};
    _runtimeInstance.respondPermission(requestId: id, decision: projection);
    _pendingPermissions.remove(id);
  }

  @override
  Future<AcpSessionSettings> sessionSettings(String sessionId) async {
    _ensureConnected();
    return _settings[sessionId] ?? const AcpSessionSettings();
  }

  @override
  Future<bool> setSessionMode({
    required String sessionId,
    required String modeId,
  }) {
    _ensureConnected();
    final requestId = _requestId('mode');
    final completer = Completer<bool>();
    _pendingModes[requestId] = completer;
    try {
      _runtimeInstance.setMode(
        requestId: requestId,
        sessionId: sessionId,
        modeId: modeId,
      );
    } on Object {
      _pendingModes.remove(requestId);
      rethrow;
    }
    return completer.future;
  }

  @override
  Future<List<AcpProjectSessions>> listSessions() {
    _ensureConnected();
    if (_capabilities?.session.list != true) {
      return Future<List<AcpProjectSessions>>.error(
        StateError('ACP agent does not support session/list.'),
      );
    }
    final requestId = _requestId('list');
    final completer = Completer<List<AcpProjectSessions>>();
    _pendingCatalogs[requestId] = completer;
    try {
      _runtimeInstance.listSessions(requestId: requestId);
    } on Object {
      _pendingCatalogs.remove(requestId);
      rethrow;
    }
    return completer.future;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _invalidateAllPermissions(AcpPermissionInvalidationReason.disposed);
    _disposed = true;
    final error = StateError('Rust ACP client disposed.');
    _connecting?.completeError(error);
    for (final completer in _pendingCreates.values) {
      if (!completer.isCompleted) completer.completeError(error);
    }
    for (final completer in _pendingRestores.values) {
      if (!completer.isCompleted) completer.completeError(error);
    }
    for (final completer in _pendingCatalogs.values) {
      if (!completer.isCompleted) completer.completeError(error);
    }
    for (final completer in _pendingSessionLifecycle.values) {
      if (!completer.isCompleted) completer.completeError(error);
    }
    for (final completer in _pendingAuthentication.values) {
      if (!completer.isCompleted) completer.completeError(error);
    }
    for (final completer in _pendingModes.values) {
      if (!completer.isCompleted) completer.completeError(error);
    }
    for (final completer in _pendingConfigs.values) {
      if (!completer.isCompleted) completer.completeError(error);
    }
    for (final output in _promptStreams.values) {
      output.addError(error);
      await output.close();
    }
    _pendingCreates.clear();
    _pendingRestores.clear();
    _restoreContexts.clear();
    _restoreRequestBySession.clear();
    _restoreEvents.clear();
    _pendingCatalogs.clear();
    _pendingSessionLifecycle.clear();
    _pendingAuthentication.clear();
    _pendingModes.clear();
    _pendingConfigs.clear();
    _configRequestBySession.clear();
    _promptStreams.clear();
    await _eventSubscription?.cancel();
    final runtime = _runtime;
    if (runtime != null) await runtime.dispose();
    await _permissionRequests.close();
    await _permissionInvalidations.close();
  }

  @override
  Future<List<AgentEvent>> resumeSession({
    required String sessionId,
    required String cwd,
    List<String> additionalDirectories = const <String>[],
  }) {
    _ensureConnected();
    if (_capabilities?.loadSession != true &&
        _capabilities?.session.resume != true) {
      return Future<List<AgentEvent>>.error(
        StateError(
          'ACP agent does not support session/load or session/resume.',
        ),
      );
    }
    if (_restoreRequestBySession.containsKey(sessionId)) {
      return Future<List<AgentEvent>>.error(
        StateError('Session $sessionId is already being restored.'),
      );
    }
    final directories = _additionalDirectoriesForRequest(additionalDirectories);
    final requestId = _requestId('restore');
    final completer = Completer<List<AgentEvent>>();
    _pendingRestores[requestId] = completer;
    _restoreContexts[requestId] = (
      sessionId: sessionId,
      cwd: cwd,
      additionalDirectories: directories,
    );
    _restoreRequestBySession[sessionId] = requestId;
    _restoreEvents[requestId] = <AgentEvent>[];
    try {
      _runtimeInstance.restoreSession(
        requestId: requestId,
        sessionId: sessionId,
        cwd: cwd,
        additionalDirectories: directories,
      );
    } on Object {
      _clearPendingRestore(requestId);
      rethrow;
    }
    return completer.future;
  }

  @override
  Future<AgentSession> forkSession({
    required String sessionId,
    required String cwd,
    List<String> additionalDirectories = const <String>[],
  }) => _unsupported('forkSession');

  @override
  Future<List<AcpConfigOption>> setConfigOption({
    required String sessionId,
    required String configId,
    required Object value,
  }) {
    _ensureConnected();
    final settings = _settings[sessionId];
    AcpConfigOption? option;
    for (final candidate
        in settings?.configOptions ?? const <AcpConfigOption>[]) {
      if (candidate.id == configId) {
        option = candidate;
        break;
      }
    }
    if (option == null) {
      return Future<List<AcpConfigOption>>.error(
        StateError('Unknown session config option: $configId'),
      );
    }
    if (_configRequestBySession.containsKey(sessionId)) {
      return Future<List<AcpConfigOption>>.error(
        StateError('Session $sessionId already has a config update in flight.'),
      );
    }
    final projectedValue = switch ((option.isBooleanOption, value)) {
      (true, bool value) => <String, Object?>{
        'type': 'boolean',
        'value': value,
      },
      (false, String value) when value.trim().isNotEmpty => <String, Object?>{
        'type': 'value_id',
        'value': value.trim(),
      },
      _ => null,
    };
    if (projectedValue == null) {
      return Future<List<AcpConfigOption>>.error(
        ArgumentError.value(
          value,
          'value',
          'does not match config option type',
        ),
      );
    }
    final requestId = _requestId('config');
    final completer = Completer<List<AcpConfigOption>>();
    _pendingConfigs[requestId] = completer;
    _configRequestBySession[sessionId] = requestId;
    try {
      _runtimeInstance.setConfigOption(
        requestId: requestId,
        sessionId: sessionId,
        configId: configId,
        value: projectedValue,
      );
    } on Object {
      _pendingConfigs.remove(requestId);
      _configRequestBySession.remove(sessionId);
      rethrow;
    }
    return completer.future;
  }

  @override
  Future<void> closeSession({required String sessionId}) {
    _ensureConnected();
    if (_capabilities?.session.close != true) {
      return Future<void>.error(
        StateError('ACP agent does not support session/close.'),
      );
    }
    return _sessionLifecycleOperation(
      operation: 'close',
      sessionId: sessionId,
      send: (requestId) => _runtimeInstance.closeSession(
        requestId: requestId,
        sessionId: sessionId,
      ),
    );
  }

  @override
  Future<void> deleteSession({required String sessionId}) {
    _ensureConnected();
    if (_capabilities?.session.delete != true) {
      return Future<void>.error(
        StateError('ACP agent does not support session/delete.'),
      );
    }
    return _sessionLifecycleOperation(
      operation: 'delete',
      sessionId: sessionId,
      send: (requestId) => _runtimeInstance.deleteSession(
        requestId: requestId,
        sessionId: sessionId,
      ),
    );
  }

  @override
  Future<void> authenticate({required String methodId}) {
    _ensureConnected();
    final advertised = _capabilities?.authMethods.any(
      (method) => method['id'] == methodId,
    );
    if (advertised != true) {
      return Future<void>.error(
        StateError('ACP agent did not advertise auth method $methodId.'),
      );
    }
    return _authenticationOperation(
      operation: 'authenticate',
      send: (requestId) => _runtimeInstance.authenticate(
        requestId: requestId,
        methodId: methodId,
      ),
    );
  }

  @override
  Future<void> logout() {
    _ensureConnected();
    if (_capabilities?.auth.logout != true) {
      return Future<void>.error(
        StateError('ACP agent does not support logout.'),
      );
    }
    return _authenticationOperation(
      operation: 'logout',
      send: (requestId) => _runtimeInstance.logout(requestId: requestId),
    );
  }

  void _handleRuntimeEvent(IanvsRuntimeEvent event) {
    if (_disposed) return;
    switch (event.type) {
      case IanvsRuntimeEventType.statusChanged:
        _handleStatus(event);
      case IanvsRuntimeEventType.sessionUpdate:
        _handleSessionUpdate(event.update!);
      case IanvsRuntimeEventType.sessionCatalog:
        _handleSessionCatalog(event);
      case IanvsRuntimeEventType.authenticationChanged:
        final requestId = event.requestId;
        if (requestId != null) {
          _pendingAuthentication.remove(requestId)?.complete();
        }
      case IanvsRuntimeEventType.permissionRequest:
        _handlePermissionRequest(event.permissionRequest!);
      case IanvsRuntimeEventType.runtimeError:
        _handleRuntimeError(event);
      case IanvsRuntimeEventType.stderrLog:
        final output = _activeOutput;
        output?.add(
          AgentEvent(
            type: AgentEventType.status,
            text: event.data['line'] as String? ?? '',
            metadata: const <String, Object?>{'kind': 'stderr'},
            timestamp: DateTime.now(),
          ),
        );
      case IanvsRuntimeEventType.terminalAttached:
        final output = _promptStreams[event.data['sessionId'] as String?];
        output?.add(
          AgentEvent(
            type: AgentEventType.status,
            text: 'Terminal attached.',
            metadata: <String, Object?>{
              'kind': 'terminal',
              'terminalId': event.data['terminalId'],
              'command': event.data['command'],
              'cwd': event.data['cwd'],
            },
            timestamp: DateTime.now(),
          ),
        );
      case IanvsRuntimeEventType.terminalOutput:
        final output = _promptStreams[event.data['sessionId'] as String?];
        output?.add(
          AgentEvent(
            type: AgentEventType.status,
            text: event.data['data'] as String? ?? '',
            metadata: <String, Object?>{
              'kind': 'terminal_output',
              'terminalId': event.data['terminalId'],
            },
            timestamp: DateTime.now(),
          ),
        );
      case IanvsRuntimeEventType.terminalExited:
        final output = _promptStreams[event.data['sessionId'] as String?];
        final exit = _objectMap(event.data['exit']);
        output?.add(
          AgentEvent(
            type: AgentEventType.status,
            text: 'Terminal exited.',
            metadata: <String, Object?>{
              'kind': 'terminal_exited',
              'terminalId': event.data['terminalId'],
              ...?exit,
            },
            timestamp: DateTime.now(),
          ),
        );
      case IanvsRuntimeEventType.terminalReleased:
        final output = _promptStreams[event.data['sessionId'] as String?];
        output?.add(
          AgentEvent(
            type: AgentEventType.status,
            text: 'Terminal released.',
            metadata: <String, Object?>{
              'kind': 'terminal_released',
              'terminalId': event.data['terminalId'],
            },
            timestamp: DateTime.now(),
          ),
        );
    }
  }

  void _handleStatus(IanvsRuntimeEvent event) {
    switch (event.status) {
      case 'ready':
        _connected = true;
        _capabilities = _capabilitiesFromProjection(event.data['capabilities']);
        final completer = _connecting;
        if (completer != null && !completer.isCompleted) completer.complete();
      case 'failed':
        _connected = false;
        _invalidateAllPermissions(
          AcpPermissionInvalidationReason.connectionClosed,
        );
        final error = StateError(
          event.data['detail'] as String? ?? 'Rust ACP runtime failed.',
        );
        final completer = _connecting;
        if (completer != null && !completer.isCompleted) {
          completer.completeError(error);
        }
        _failPendingOperations(error);
      case 'disposed':
        _connected = false;
        _invalidateAllPermissions(AcpPermissionInvalidationReason.disposed);
      case 'recovering':
        _connected = false;
        _invalidateAllPermissions(
          AcpPermissionInvalidationReason.connectionClosed,
        );
        _failPendingOperations(
          StateError(
            event.data['detail'] as String? ??
                'Rust ACP runtime is recovering the agent process.',
          ),
        );
      case 'stopped' || 'starting' || null:
        break;
    }
  }

  void _handleSessionUpdate(Map<String, Object?> update) {
    final sessionId = update['sessionId'] as String? ?? '';
    final kind = update['kind'] as String? ?? '';
    final requestId = update['requestId'] as String?;
    if (kind == 'session_created' && requestId != null) {
      final completer = _pendingCreates.remove(requestId);
      final context = _createContexts.remove(requestId);
      if (completer == null || context == null) return;
      final now = DateTime.now();
      final session = AgentSession(
        id: sessionId,
        cwd: context.cwd,
        additionalDirectories: context.additionalDirectories,
        createdAt: now,
        updatedAt: now,
        agentName: agentName,
      );
      _sessions[sessionId] = session;
      _settings[sessionId] = _settingsFromSessionCreated(
        _objectMap(update['payload']),
      );
      completer.complete(session);
      return;
    }
    if (kind == 'session_restored' && requestId != null) {
      final completer = _pendingRestores.remove(requestId);
      final context = _restoreContexts.remove(requestId);
      final events = _restoreEvents.remove(requestId) ?? const <AgentEvent>[];
      if (context != null &&
          _restoreRequestBySession[context.sessionId] == requestId) {
        _restoreRequestBySession.remove(context.sessionId);
      }
      if (completer == null || context == null) return;
      if (context.sessionId != sessionId) {
        completer.completeError(
          StateError(
            'Rust restored session $sessionId for request bound to '
            '${context.sessionId}.',
          ),
        );
        return;
      }
      final now = DateTime.now();
      _sessions[sessionId] = AgentSession(
        id: sessionId,
        cwd: context.cwd,
        additionalDirectories: context.additionalDirectories,
        createdAt: now,
        updatedAt: now,
        agentName: agentName,
        initialEvents: events,
      );
      _settings[sessionId] = _settingsFromSessionCreated(
        _objectMap(update['payload']),
      );
      completer.complete(List<AgentEvent>.unmodifiable(events));
      return;
    }
    if (kind == 'session_restored' && requestId == null) {
      final payload = _objectMap(update['payload']);
      if (payload?['recoveredAfterRestart'] != true) return;
      final existing = _sessions[sessionId];
      final cwd = payload?['cwd'] as String? ?? existing?.cwd;
      if (cwd == null || cwd.isEmpty) return;
      final directories =
          (payload?['additionalDirectories'] as List? ??
                  existing?.additionalDirectories ??
                  const <Object?>[])
              .whereType<String>()
              .toList(growable: false);
      final now = DateTime.now();
      _sessions[sessionId] = AgentSession(
        id: sessionId,
        cwd: cwd,
        additionalDirectories: directories,
        createdAt: existing?.createdAt ?? now,
        updatedAt: now,
        agentName: agentName,
        initialEvents: existing?.initialEvents ?? const <AgentEvent>[],
      );
      _settings[sessionId] = _settingsFromSessionCreated(payload);
      return;
    }
    if ((kind == 'session_closed' || kind == 'session_deleted') &&
        requestId != null) {
      _pendingSessionLifecycle.remove(requestId)?.complete();
      _sessions.remove(sessionId);
      _settings.remove(sessionId);
      _finishPrompt(sessionId);
      _invalidatePermissionsForSession(
        sessionId,
        AcpPermissionInvalidationReason.sessionClosed,
      );
      return;
    }
    if (kind == 'mode_changed') {
      final payload = _objectMap(update['payload']);
      final modeId =
          payload?['modeId'] as String? ?? payload?['currentModeId'] as String?;
      if (modeId != null) {
        _settings[sessionId] =
            (_settings[sessionId] ?? const AcpSessionSettings())
                .withCurrentMode(modeId);
      }
      if (requestId != null) _pendingModes.remove(requestId)?.complete(true);
      return;
    }
    if (kind == 'config_changed') {
      final payload = _objectMap(update['payload']);
      final options = _configOptionsFromPayload(payload);
      _settings[sessionId] =
          (_settings[sessionId] ?? const AcpSessionSettings())
              .withPreferredConfigOptions(options);
      if (requestId != null) {
        _pendingConfigs.remove(requestId)?.complete(options);
        if (_configRequestBySession[sessionId] == requestId) {
          _configRequestBySession.remove(sessionId);
        }
      }
      return;
    }
    if (kind == 'permission_invalidated' && requestId != null) {
      final payload = _objectMap(update['payload']);
      final reason = _invalidationReason(payload?['reason']);
      if (reason != null) {
        _invalidatePermission(
          requestId: requestId,
          sessionId: sessionId,
          reason: reason,
        );
      }
      return;
    }
    final restoreRequestId = _restoreRequestBySession[sessionId];
    if (restoreRequestId != null) {
      final event = _agentEventFromUpdate(kind, update);
      if (event != null) _restoreEvents[restoreRequestId]?.add(event);
      return;
    }
    final output = _promptStreams[sessionId];
    if (output == null) return;
    final event = _agentEventFromUpdate(kind, update);
    if (event != null) output.add(event);
    if (kind == 'prompt_completed' || kind == 'cancelled' || kind == 'failed') {
      _finishPrompt(sessionId);
    }
  }

  void _handleSessionCatalog(IanvsRuntimeEvent event) {
    final requestId = event.requestId;
    if (requestId == null) return;
    final completer = _pendingCatalogs.remove(requestId);
    if (completer == null) return;
    try {
      final entries = event.sessions.map((raw) {
        final sessionId = raw['sessionId'];
        final cwd = raw['cwd'];
        if (sessionId is! String || sessionId.isEmpty) {
          throw const FormatException(
            'Rust session catalog entry has no sessionId.',
          );
        }
        if (cwd is! String || cwd.isEmpty) {
          throw const FormatException('Rust session catalog entry has no cwd.');
        }
        final updatedAtRaw = raw['updatedAt'];
        return AcpSessionEntry(
          id: sessionId,
          cwd: cwd,
          title: normalizeSessionTitle(raw['title'] as String?) ?? sessionId,
          additionalDirectories:
              (raw['additionalDirectories'] as List? ?? const <Object?>[])
                  .whereType<String>()
                  .toList(growable: false),
          updatedAt: updatedAtRaw is String
              ? DateTime.tryParse(updatedAtRaw)?.toLocal()
              : null,
          meta: _objectMap(raw['meta']) ?? const <String, Object?>{},
        );
      });
      completer.complete(groupAcpSessionsByProject(entries));
    } on Object catch (error, stackTrace) {
      completer.completeError(error, stackTrace);
    }
  }

  AgentEvent? _agentEventFromUpdate(String kind, Map<String, Object?> update) {
    final text = update['text'] as String? ?? '';
    final payload = _objectMap(update['payload']);
    return switch (kind) {
      'user_message' => AgentEvent(
        type: AgentEventType.userMessage,
        text: text,
        timestamp: DateTime.now(),
      ),
      'agent_message_delta' => AgentEvent(
        type: AgentEventType.agentTextDelta,
        text: text,
        metadata: payload ?? const <String, Object?>{},
        timestamp: DateTime.now(),
      ),
      'agent_thought_delta' => AgentEvent(
        type: AgentEventType.status,
        text: text,
        metadata: <String, Object?>{'kind': 'thought', ...?payload},
        timestamp: DateTime.now(),
      ),
      'tool_call' || 'tool_call_update' => AgentEvent(
        type: AgentEventType.toolCall,
        text: text.isEmpty ? 'Tool call' : text,
        metadata: payload ?? const <String, Object?>{},
        timestamp: DateTime.now(),
      ),
      'plan' => AgentEvent(
        type: AgentEventType.status,
        text: text.isEmpty ? 'Plan update' : text,
        metadata: <String, Object?>{'kind': 'plan', ...?payload},
        timestamp: DateTime.now(),
      ),
      'prompt_completed' || 'cancelled' => AgentEvent(
        type: AgentEventType.agentTextDone,
        text: '',
        metadata: <String, Object?>{
          'kind': 'turn',
          ..._normalizedTurnPayload(payload, kind: kind),
        },
        timestamp: DateTime.now(),
      ),
      _ => null,
    };
  }

  Map<String, Object?> _normalizedTurnPayload(
    Map<String, Object?>? payload, {
    required String kind,
  }) {
    final normalized = <String, Object?>{...?payload};
    final rawStopReason = normalized['stopReason'];
    final stopReason = rawStopReason is String
        ? switch (rawStopReason.trim()) {
            'end_turn' => 'endTurn',
            'max_tokens' => 'maxTokens',
            'max_turn_requests' => 'maxTurnRequests',
            final value => value,
          }
        : kind == 'cancelled'
        ? 'cancelled'
        : null;
    if (stopReason != null && stopReason.isNotEmpty) {
      normalized['stopReason'] = stopReason;
    }
    return normalized;
  }

  void _handlePermissionRequest(Map<String, Object?> value) {
    final choices = (value['options'] as List? ?? const <Object?>[])
        .whereType<Map>()
        .map(
          (raw) => AcpPermissionChoice(
            optionId: raw['optionId'] as String? ?? '',
            name: raw['label'] as String? ?? '',
            kind: raw['kind'] as String?,
          ),
        )
        .where((choice) => choice.optionId.isNotEmpty)
        .toList(growable: false);
    final request = AcpPermissionRequest(
      id: value['requestId']! as String,
      lifecycleId: value['requestId']! as String,
      title: value['title'] as String? ?? 'Permission requested',
      rationale: 'The Rust runtime blocked this action pending your choice.',
      sessionId: value['sessionId'] as String? ?? '',
      toolName: value['toolCallId'] as String? ?? 'agent_action',
      toolKind: value['toolKind'] as String?,
      options: choices.map((choice) => choice.name).toList(growable: false),
      choices: choices,
      requestedAt: DateTime.now(),
      metadata: <String, Object?>{
        if (value['rawInput'] != null) 'rawInput': value['rawInput'],
      },
    );
    _pendingPermissions[request.id] = request;
    _permissionRequests.add(request);
  }

  void _handleRuntimeError(IanvsRuntimeEvent event) {
    final error = StateError(
      '${event.errorCode ?? 'rust_runtime_error'}: '
      '${event.errorMessage ?? 'Unknown Rust runtime error'}',
    );
    final requestId = event.requestId;
    if (requestId != null) {
      _pendingCreates.remove(requestId)?.completeError(error);
      _createContexts.remove(requestId);
      final restore = _pendingRestores.remove(requestId);
      if (restore != null) {
        _clearPendingRestore(requestId, removeCompleter: false);
        restore.completeError(error);
      }
      _pendingCatalogs.remove(requestId)?.completeError(error);
      _pendingSessionLifecycle.remove(requestId)?.completeError(error);
      _pendingAuthentication.remove(requestId)?.completeError(error);
      _pendingModes.remove(requestId)?.completeError(error);
      final config = _pendingConfigs.remove(requestId);
      if (config != null) {
        _configRequestBySession.removeWhere((_, value) => value == requestId);
        config.completeError(error);
      }
      final session = _promptRequestIds.entries
          .where((entry) => entry.value == requestId)
          .map((entry) => entry.key)
          .firstOrNull;
      if (session != null) {
        _promptStreams[session]?.addError(error);
        _finishPrompt(session);
      }
    }
    if (!_connected) {
      final completer = _connecting;
      if (completer != null && !completer.isCompleted) {
        completer.completeError(error);
      }
    }
  }

  void _handleRuntimeStreamError(Object error, StackTrace stackTrace) {
    _connected = false;
    _invalidateAllPermissions(AcpPermissionInvalidationReason.connectionClosed);
    final completer = _connecting;
    if (completer != null && !completer.isCompleted) {
      completer.completeError(error, stackTrace);
    }
    _failPendingOperations(error, stackTrace);
  }

  void _failPendingOperations(Object error, [StackTrace? stackTrace]) {
    for (final completer in _pendingCreates.values) {
      if (!completer.isCompleted) completer.completeError(error, stackTrace);
    }
    for (final completer in _pendingRestores.values) {
      if (!completer.isCompleted) completer.completeError(error, stackTrace);
    }
    for (final completer in _pendingCatalogs.values) {
      if (!completer.isCompleted) completer.completeError(error, stackTrace);
    }
    for (final completer in _pendingSessionLifecycle.values) {
      if (!completer.isCompleted) completer.completeError(error, stackTrace);
    }
    for (final completer in _pendingAuthentication.values) {
      if (!completer.isCompleted) completer.completeError(error, stackTrace);
    }
    for (final completer in _pendingModes.values) {
      if (!completer.isCompleted) completer.completeError(error, stackTrace);
    }
    for (final completer in _pendingConfigs.values) {
      if (!completer.isCompleted) completer.completeError(error, stackTrace);
    }
    for (final output in _promptStreams.values) {
      output.addError(error, stackTrace);
      unawaited(output.close());
    }
    _pendingCreates.clear();
    _createContexts.clear();
    _pendingRestores.clear();
    _restoreContexts.clear();
    _restoreRequestBySession.clear();
    _restoreEvents.clear();
    _pendingCatalogs.clear();
    _pendingSessionLifecycle.clear();
    _pendingAuthentication.clear();
    _pendingModes.clear();
    _pendingConfigs.clear();
    _configRequestBySession.clear();
    _promptStreams.clear();
    _promptRequestIds.clear();
    _activePromptSessionId = null;
  }

  void _finishPrompt(String sessionId) {
    final output = _promptStreams.remove(sessionId);
    _promptRequestIds.remove(sessionId);
    if (_activePromptSessionId == sessionId) _activePromptSessionId = null;
    if (output != null) unawaited(output.close());
  }

  Future<void> _sessionLifecycleOperation({
    required String operation,
    required String sessionId,
    required void Function(String requestId) send,
  }) {
    final requestId = _requestId(operation);
    final completer = Completer<void>();
    _pendingSessionLifecycle[requestId] = completer;
    try {
      send(requestId);
    } on Object {
      _pendingSessionLifecycle.remove(requestId);
      rethrow;
    }
    return completer.future;
  }

  Future<void> _authenticationOperation({
    required String operation,
    required void Function(String requestId) send,
  }) {
    final requestId = _requestId(operation);
    final completer = Completer<void>();
    _pendingAuthentication[requestId] = completer;
    try {
      send(requestId);
    } on Object {
      _pendingAuthentication.remove(requestId);
      rethrow;
    }
    return completer.future;
  }

  void _clearPendingRestore(String requestId, {bool removeCompleter = true}) {
    if (removeCompleter) _pendingRestores.remove(requestId);
    final context = _restoreContexts.remove(requestId);
    if (context != null &&
        _restoreRequestBySession[context.sessionId] == requestId) {
      _restoreRequestBySession.remove(context.sessionId);
    }
    _restoreEvents.remove(requestId);
  }

  StreamController<AgentEvent>? get _activeOutput {
    final sessionId = _activePromptSessionId;
    return sessionId == null ? null : _promptStreams[sessionId];
  }

  AcpAgentCapabilities _capabilitiesFromProjection(Object? raw) {
    final projection = _objectMap(raw) ?? const <String, Object?>{};
    return AcpAgentCapabilities.fromInitialize(
      protocolVersion: projection['protocolVersion'] as int? ?? 1,
      agentCapabilities: <String, Object?>{
        'loadSession': projection['loadSession'] == true,
        'promptCapabilities': <String, Object?>{
          'image': projection['promptImage'] == true,
          'audio': projection['promptAudio'] == true,
          'embeddedContext': projection['embeddedContext'] == true,
        },
        'mcpCapabilities': <String, Object?>{
          'http': projection['mcpHttp'] == true,
          'sse': projection['mcpSse'] == true,
        },
        'auth': <String, Object?>{
          if (projection['logout'] == true) 'logout': const <String, Object?>{},
        },
        'sessionCapabilities': <String, Object?>{
          if (projection['listSessions'] == true)
            'list': const <String, Object?>{},
          if (projection['resumeSession'] == true)
            'resume': const <String, Object?>{},
          if (projection['closeSession'] == true)
            'close': const <String, Object?>{},
          if (projection['deleteSession'] == true)
            'delete': const <String, Object?>{},
          if (projection['additionalDirectories'] == true)
            'additionalDirectories': const <String, Object?>{},
        },
      },
      authMethods: projection['authMethods'] as List? ?? const <Object?>[],
      clientCapabilities: <String, dynamic>{
        'fs': <String, dynamic>{
          'readTextFile': projection['filesystemReadTextFile'] == true,
          'writeTextFile': projection['filesystemWriteTextFile'] == true,
        },
        'terminal': projection['terminal'] == true,
      },
      hasFsProvider:
          projection['filesystemReadTextFile'] == true ||
          projection['filesystemWriteTextFile'] == true,
      hasTerminalProvider: projection['terminal'] == true,
      allowReadOutsideWorkspace: false,
      agentInfo: <String, Object?>{'name': agentName},
      clientInfo: const <String, dynamic>{
        'name': 'ianvs-acp-core',
        'version': '0.1.0',
      },
    );
  }

  AcpSessionSettings _settingsFromSessionCreated(
    Map<String, Object?>? payload,
  ) {
    final configOptions = _configOptionsFromPayload(payload);
    final modes = _objectMap(payload?['modes']);
    var modeInfo = const AcpSessionModeInfo();
    if (modes != null) {
      final currentModeId = (modes['currentModeId'] as String? ?? '').trim();
      final rawModes = modes['availableModes'];
      if (currentModeId.isNotEmpty && rawModes is List) {
        final available = <AcpSessionMode>[];
        for (final raw in rawModes) {
          final mode = _objectMap(raw);
          final id = (mode?['id'] as String? ?? '').trim();
          if (id.isEmpty) {
            throw const FormatException('Rust session mode has no id.');
          }
          final label = (mode?['label'] as String? ?? '').trim();
          available.add(
            AcpSessionMode(id: id, name: label.isEmpty ? id : label),
          );
        }
        modeInfo = AcpSessionModeInfo(
          currentModeId: currentModeId,
          availableModes: List<AcpSessionMode>.unmodifiable(available),
        );
      }
    }
    return AcpSessionSettings(
      modes: modeInfo,
      configOptions: configOptions,
    ).withConfigOptionsPreference;
  }

  List<AcpConfigOption> _configOptionsFromPayload(
    Map<String, Object?>? payload,
  ) {
    final rawOptions = payload?['configOptions'];
    if (rawOptions == null) return const <AcpConfigOption>[];
    if (rawOptions is! List) {
      throw const FormatException(
        'Rust session config options must be a list.',
      );
    }
    final options = <AcpConfigOption>[];
    final ids = <String>{};
    for (final raw in rawOptions) {
      final option = _objectMap(raw);
      final id = (option?['id'] as String? ?? '').trim();
      final type = (option?['optionType'] as String? ?? '').trim();
      final current = option?['currentValue'];
      if (id.isEmpty ||
          !ids.add(id) ||
          (type != 'select' && type != 'boolean')) {
        throw const FormatException('Invalid Rust session config option.');
      }
      if ((type == 'select' && current is! String) ||
          (type == 'boolean' && current is! bool)) {
        throw const FormatException(
          'Invalid Rust session config current value.',
        );
      }
      final choices = <AcpConfigOptionChoice>[];
      final choiceValues = <String>{};
      for (final rawChoice
          in option?['options'] as List? ?? const <Object?>[]) {
        final choice = _objectMap(rawChoice);
        final value = (choice?['value'] as String? ?? '').trim();
        if (value.isEmpty || !choiceValues.add(value)) {
          throw const FormatException('Invalid Rust session config choice.');
        }
        final name = (choice?['name'] as String? ?? '').trim();
        choices.add(
          AcpConfigOptionChoice(
            value: value,
            name: name.isEmpty ? value : name,
            description: choice?['description'] as String?,
            groupId: choice?['groupId'] as String?,
            groupName: choice?['groupName'] as String?,
          ),
        );
      }
      if ((type == 'boolean' && choices.isNotEmpty) ||
          (type == 'select' && !choiceValues.contains(current))) {
        throw const FormatException('Invalid Rust session config choices.');
      }
      final name = (option?['name'] as String? ?? '').trim();
      options.add(
        AcpConfigOption(
          id: id,
          name: name.isEmpty ? id : name,
          type: type,
          currentValue: current.toString(),
          options: List<AcpConfigOptionChoice>.unmodifiable(choices),
          description: option?['description'] as String?,
          category: option?['category'] as String?,
        ),
      );
    }
    return List<AcpConfigOption>.unmodifiable(options);
  }

  String _requestId(String operation) => '$operation-${_nextRequestId++}';

  List<String> _additionalDirectoriesForRequest(List<String> override) {
    final selected = override.isEmpty ? additionalDirectories : override;
    if (_capabilities?.session.additionalDirectories != true) {
      return const <String>[];
    }
    final result = <String>[];
    final seen = <String>{};
    for (final directory in selected) {
      final trimmed = directory.trim();
      if (trimmed.isEmpty || !seen.add(trimmed)) continue;
      result.add(trimmed);
    }
    return List<String>.unmodifiable(result);
  }

  void _invalidatePermission({
    required String requestId,
    required String sessionId,
    required AcpPermissionInvalidationReason reason,
  }) {
    final pending = _pendingPermissions[requestId];
    if (pending == null ||
        pending.lifecycleId != requestId ||
        pending.sessionId != sessionId) {
      return;
    }
    _pendingPermissions.remove(requestId);
    _permissionInvalidations.add(
      AcpPermissionInvalidation(
        requestId: requestId,
        lifecycleId: pending.lifecycleId,
        sessionId: pending.sessionId,
        reason: reason,
        invalidatedAt: DateTime.now(),
      ),
    );
  }

  void _invalidateAllPermissions(AcpPermissionInvalidationReason reason) {
    for (final pending in _pendingPermissions.values.toList(growable: false)) {
      _invalidatePermission(
        requestId: pending.id,
        sessionId: pending.sessionId,
        reason: reason,
      );
    }
  }

  void _invalidatePermissionsForSession(
    String sessionId,
    AcpPermissionInvalidationReason reason,
  ) {
    final requests = _pendingPermissions.values
        .where((request) => request.sessionId == sessionId)
        .toList(growable: false);
    for (final pending in requests) {
      _invalidatePermission(
        requestId: pending.id,
        sessionId: pending.sessionId,
        reason: reason,
      );
    }
  }

  AcpPermissionInvalidationReason? _invalidationReason(Object? raw) {
    return switch (raw) {
      'timed_out' => AcpPermissionInvalidationReason.timedOut,
      'prompt_ended' => AcpPermissionInvalidationReason.promptEnded,
      'prompt_cancelled' => AcpPermissionInvalidationReason.promptCancelled,
      'session_closed' => AcpPermissionInvalidationReason.sessionClosed,
      'connection_closed' => AcpPermissionInvalidationReason.connectionClosed,
      'disposed' => AcpPermissionInvalidationReason.disposed,
      _ => null,
    };
  }

  void _ensureOpen() {
    if (_disposed) throw StateError('Rust ACP client is disposed.');
  }

  void _ensureConnected() {
    _ensureOpen();
    if (!_connected) throw StateError('Rust ACP client is not connected.');
  }

  Future<T> _unsupported<T>(String operation) {
    return Future<T>.error(
      UnsupportedError(
        '$operation is not yet owned by ianvs-acp-core and will not open a '
        'parallel protocol connection.',
      ),
    );
  }
}

Map<String, Object?>? _objectMap(Object? value) {
  if (value is! Map) return null;
  return value.map((key, value) => MapEntry(key.toString(), value));
}
