import 'dart:async';

import 'package:logging/logging.dart';

import '../capabilities.dart';
import '../config.dart';
import '../extensions.dart';
import '../models/session_types.dart';
import '../models/terminal_events.dart';
import '../models/tool_types.dart';
import '../models/types.dart';
import '../models/updates.dart';
import '../providers/fs_provider.dart';
import '../providers/permission_provider.dart';
import '../providers/terminal_provider.dart';
import '../rpc/peer.dart';
import '../security/workspace_jail.dart';

/// Alias for a JSON map used in requests/responses.
typedef Json = Map<String, dynamic>;

class _PermissionChoice {
  const _PermissionChoice({
    required this.optionId,
    required this.label,
    this.kind,
  });

  final String optionId;
  final String label;
  final String? kind;

  String get searchableText => '$kind $optionId $label';
}

List<_PermissionChoice> _permissionChoicesFromRaw(Object? raw) {
  if (raw is! List) return const <_PermissionChoice>[];
  final choices = <_PermissionChoice>[];
  for (final item in raw) {
    if (item is String) {
      final value = item.trim();
      if (value.isEmpty) continue;
      choices.add(_PermissionChoice(optionId: value, label: value));
      continue;
    }
    if (item is Map) {
      final map = Map<String, dynamic>.fromEntries(
        item.entries.map(
          (entry) => MapEntry(entry.key.toString(), entry.value),
        ),
      );
      final kind = _nonEmptyString(map['kind']);
      final optionId =
          _nonEmptyString(map['optionId']) ??
          _nonEmptyString(map['id']) ??
          _nonEmptyString(map['value']) ??
          _nonEmptyString(map['name']) ??
          kind;
      if (optionId == null) continue;
      choices.add(
        _PermissionChoice(
          optionId: optionId,
          label:
              _nonEmptyString(map['name']) ??
              _nonEmptyString(map['label']) ??
              optionId,
          kind: kind,
        ),
      );
    }
  }
  return choices;
}

String? _permissionOptionIdForOutcome(
  List<_PermissionChoice> choices,
  PermissionOutcome outcome,
) {
  if (outcome == PermissionOutcome.cancelled) return null;
  for (final choice in choices) {
    if (_permissionKindMatches(choice.kind, outcome)) return choice.optionId;
  }
  for (final choice in choices) {
    if (_permissionLabelMatches(choice, outcome)) return choice.optionId;
  }
  return choices.length == 1 ? choices.single.optionId : null;
}

bool _permissionKindMatches(String? kind, PermissionOutcome outcome) {
  final normalized = kind?.trim().toLowerCase();
  if (normalized == null || normalized.isEmpty) return false;
  return switch (outcome) {
    PermissionOutcome.allow =>
      normalized == 'allow' ||
          normalized == 'allow_once' ||
          normalized == 'allow_always',
    PermissionOutcome.deny =>
      normalized == 'deny' ||
          normalized == 'deny_once' ||
          normalized == 'deny_always' ||
          normalized == 'reject' ||
          normalized == 'reject_once' ||
          normalized == 'reject_always',
    PermissionOutcome.cancelled => false,
  };
}

bool _permissionLabelMatches(
  _PermissionChoice choice,
  PermissionOutcome outcome,
) {
  final text = choice.searchableText.toLowerCase();
  final words = text
      .split(RegExp(r'[^a-z0-9]+'))
      .where((word) => word.isNotEmpty)
      .toSet();
  final looksDenied =
      words.any(_denyPermissionWords.contains) ||
      text.contains("don't allow") ||
      text.contains('do not allow') ||
      text.contains('not allow');
  final looksAllowed = words.any(_allowPermissionWords.contains);
  return switch (outcome) {
    PermissionOutcome.allow => looksAllowed && !looksDenied,
    PermissionOutcome.deny => looksDenied,
    PermissionOutcome.cancelled => false,
  };
}

String? _nonEmptyString(Object? raw) {
  if (raw is! String) return null;
  final trimmed = raw.trim();
  return trimmed.isEmpty ? null : trimmed;
}

const Set<String> _allowPermissionWords = <String>{
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

const Set<String> _denyPermissionWords = <String>{
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

/// Result returned by initialize containing negotiated protocol and caps.
class InitializeResult {
  /// Create an [InitializeResult].
  InitializeResult({
    required this.protocolVersion,
    required this.agentCapabilities,
    required this.authMethods,
  });

  /// Negotiated protocol version.
  final int protocolVersion;

  /// Agent capabilities (if provided).
  final Map<String, dynamic>? agentCapabilities;

  /// Supported auth methods (if any).
  final List<Map<String, dynamic>>? authMethods;

  /// Get extension capabilities from the agent (`_meta` field).
  ///
  /// Returns parsed extension capabilities for checking vendor-specific
  /// features:
  /// ```dart
  /// final extCaps = init.extensionCapabilities;
  /// if (extCaps.supports('zed.dev', 'workspace')) {
  ///   // Safe to use _zed.dev/workspace/* methods
  /// }
  /// ```
  ExtensionCapabilities get extensionCapabilities {
    final meta = agentCapabilities?['_meta'];
    return ExtensionCapabilities.fromJson(
      meta is Map<String, dynamic> ? meta : null,
    );
  }

  /// Check if the agent supports session loading.
  bool get supportsLoadSession =>
      _capabilityAdvertised(agentCapabilities?['loadSession']);

  /// Get prompt capabilities from the agent.
  ({bool image, bool audio, bool embeddedContext}) get promptCapabilities {
    final caps = agentCapabilities?['promptCapabilities'];
    if (caps is! Map<String, dynamic>) {
      return (image: false, audio: false, embeddedContext: false);
    }
    return (
      image: caps['image'] == true,
      audio: caps['audio'] == true,
      embeddedContext: caps['embeddedContext'] == true,
    );
  }

  /// Get MCP capabilities from the agent.
  ({bool http, bool sse}) get mcpCapabilities {
    final caps = agentCapabilities?['mcpCapabilities'];
    if (caps is! Map<String, dynamic>) {
      return (http: false, sse: false);
    }
    return (http: caps['http'] == true, sse: caps['sse'] == true);
  }

  /// Get session capabilities from the agent.
  ///
  /// Returns parsed session capabilities for checking extension support:
  /// ```dart
  /// final sessionCaps = init.sessionCapabilities;
  /// if (sessionCaps.list) {
  ///   // Safe to use session/list
  /// }
  /// ```
  SessionCapabilities get sessionCapabilities =>
      SessionCapabilities.fromJson(agentCapabilities);

  /// Check if the agent supports session listing.
  bool get supportsListSessions => sessionCapabilities.list;

  /// Check if the agent supports session resuming (without history).
  bool get supportsResumeSession => sessionCapabilities.resume;

  /// Check if the agent supports session forking.
  bool get supportsForkSession => sessionCapabilities.fork;

  /// Check if the agent supports additional workspace roots.
  bool get supportsAdditionalDirectories =>
      sessionCapabilities.additionalDirectories;
}

bool _capabilityAdvertised(Object? value) => value == true || value is Map;

List<Json> _contentBlocksFromRaw(Object? content) {
  if (content is List) {
    return content
        .map(_contentBlockFromRaw)
        .whereType<Json>()
        .toList(growable: false);
  }
  final block = _contentBlockFromRaw(content);
  return block == null ? const <Json>[] : <Json>[block];
}

Json? _contentBlockFromRaw(Object? raw) {
  if (raw is String) {
    return <String, dynamic>{'type': 'text', 'text': raw};
  }
  if (raw is! Map) return null;
  final block = raw.map((key, value) => MapEntry(key.toString(), value));
  if (block['type'] == null && block['text'] is String) {
    block['type'] = 'text';
  }
  return block;
}

List<Json> _availableCommandsFromRaw(Object? raw) {
  if (raw is! List) return const <Json>[];
  return raw
      .map(_availableCommandFromRaw)
      .whereType<Json>()
      .toList(growable: false);
}

Json? _availableCommandFromRaw(Object? raw) {
  if (raw is String) {
    final name = raw.trim();
    if (name.isEmpty) return null;
    return <String, dynamic>{'name': name};
  }
  if (raw is! Map) return null;
  return raw.map((key, value) => MapEntry(key.toString(), value));
}

/// Orchestrates ACP lifecycle and routes updates/tool/terminal handlers.
class SessionManager {
  /// Create a [SessionManager] with [config] and [peer].
  SessionManager({required this.config, required this.peer})
    : _log = config.logger {
    // Wire client-side handlers
    peer.onReadTextFile = _onReadTextFile;
    peer.onWriteTextFile = _onWriteTextFile;
    peer.onRequestPermission = _onRequestPermission;
    peer.onTerminalCreate = _onTerminalCreate;
    peer.onTerminalOutput = _onTerminalOutput;
    peer.onTerminalWaitForExit = _onTerminalWaitForExit;
    peer.onTerminalKill = _onTerminalKill;
    peer.onTerminalRelease = _onTerminalRelease;

    peer.sessionUpdates.listen(_routeSessionUpdate);
  }

  /// Client configuration.
  final AcpConfig config;

  /// JSON-RPC peer used for requests and client callbacks.
  final JsonRpcPeer peer;
  final Logger _log;

  final Map<String, StreamController<AcpUpdate>> _sessionStreams = {};
  final Map<String, List<AcpUpdate>> _replayBuffers = {};
  final Set<String> _cancellingSessions = <String>{};
  final StreamController<TerminalEvent> _terminalEvents =
      StreamController<TerminalEvent>.broadcast();
  // Track tool calls by session and tool call ID for proper merging
  final Map<String, Map<String, ToolCall>> _toolCalls = {};
  // Track workspace roots per session for filesystem operations
  final Map<String, String> _sessionWorkspaceRoots = {};
  final Map<String, List<String>> _sessionAdditionalDirectories = {};

  /// Dispose all internal resources and close streams.
  Future<void> dispose() async {
    await _terminalEvents.close();
    for (final c in _sessionStreams.values) {
      await c.close();
    }
    _sessionStreams.clear();
    _replayBuffers.clear();
    _toolCalls.clear();
    _sessionWorkspaceRoots.clear();
    _sessionAdditionalDirectories.clear();
  }

  /// Send `initialize` with capabilities and return negotiated result.
  Future<InitializeResult> initialize({
    AcpCapabilities? capabilitiesOverride,
  }) async {
    final caps = capabilitiesOverride ?? config.capabilities;
    // Build client capabilities payload from standard caps,
    // and include non-standard terminal capability when supported.
    final clientCaps = Map<String, dynamic>.from(caps.toJson());
    if (config.terminalProvider != null) {
      clientCaps['terminal'] = true; // Non-standard: used by some adapters
    }
    final payload = {'protocolVersion': 1, 'clientCapabilities': clientCaps};
    final resp = await peer.initialize(payload);
    final negotiated = (resp['protocolVersion'] as num?)?.toInt() ?? 0;
    if (negotiated < AcpConfig.minimumProtocolVersion) {
      throw StateError(
        'Unsupported ACP protocol version: $negotiated. '
        'Minimum required: ${AcpConfig.minimumProtocolVersion}.',
      );
    }
    return InitializeResult(
      protocolVersion: (resp['protocolVersion'] as num?)?.toInt() ?? 1,
      agentCapabilities: resp['agentCapabilities'] as Map<String, dynamic>?,
      authMethods: (resp['authMethods'] as List?)?.cast<Map<String, dynamic>>(),
    );
  }

  /// Create a new session and return its id.
  Future<String> newSession({
    required String workspaceRoot,
    List<String> additionalDirectories = const <String>[],
  }) async {
    final resp = await peer.newSession(
      _sessionSetupParams({
        'cwd': workspaceRoot,
        'mcpServers': config.mcpServers,
      }, additionalDirectories),
    );
    final id = resp['sessionId'] as String;
    _sessionStreams.putIfAbsent(id, StreamController<AcpUpdate>.broadcast);
    _replayBuffers.putIfAbsent(id, () => <AcpUpdate>[]);
    _setSessionWorkspace(
      id,
      workspaceRoot,
      additionalDirectories: additionalDirectories,
    );
    // Capture any modes info from session/new
    final modes = resp['modes'];
    if (modes is Map<String, dynamic>) {
      final current = modes['currentModeId'] as String?;
      final avail =
          (modes['availableModes'] as List?)?.cast<Map<String, dynamic>>() ??
          const [];
      _sessionModes[id] = (
        currentModeId: current,
        availableModes: avail
            .map(
              (m) => (
                id: (m['id'] as String?) ?? '',
                name: (m['name'] as String?) ?? '',
              ),
            )
            .toList(),
      );
    }
    return id;
  }

  /// Load a previous session and replay updates to the client.
  Future<void> loadSession({
    required String sessionId,
    required String workspaceRoot,
    List<String> additionalDirectories = const <String>[],
  }) async {
    _sessionStreams.putIfAbsent(
      sessionId,
      StreamController<AcpUpdate>.broadcast,
    );
    _replayBuffers.putIfAbsent(sessionId, () => <AcpUpdate>[]);
    _setSessionWorkspace(
      sessionId,
      workspaceRoot,
      additionalDirectories: additionalDirectories,
    );
    await peer.loadSession(
      _sessionSetupParams({
        'sessionId': sessionId,
        'cwd': workspaceRoot,
        'mcpServers': config.mcpServers,
      }, additionalDirectories),
    );
  }

  // ===== Session Extension Methods =====

  /// List existing sessions (requires agent support for session/list).
  ///
  /// Filter by [cwd] to show sessions for a specific directory.
  /// Use [cursor] for pagination (from previous
  /// [SessionListResult.nextCursor]).
  Future<SessionListResult> listSessions({String? cwd, String? cursor}) async {
    final params = <String, dynamic>{};
    if (cwd != null) params['cwd'] = cwd;
    if (cursor != null) params['cursor'] = cursor;
    final resp = await peer.sendRaw('session/list', params);
    return SessionListResult.fromJson(resp);
  }

  /// Resume a session without loading history (simpler than loadSession).
  ///
  /// Requires agent support for session/resume capability.
  Future<SessionResult> resumeSession({
    required String sessionId,
    required String workspaceRoot,
    List<String> additionalDirectories = const <String>[],
  }) async {
    _sessionStreams.putIfAbsent(
      sessionId,
      StreamController<AcpUpdate>.broadcast,
    );
    _replayBuffers.putIfAbsent(sessionId, () => <AcpUpdate>[]);
    _setSessionWorkspace(
      sessionId,
      workspaceRoot,
      additionalDirectories: additionalDirectories,
    );
    final resp = await peer.sendRaw(
      'session/resume',
      _sessionSetupParams({
        'sessionId': sessionId,
        'cwd': workspaceRoot,
        'mcpServers': config.mcpServers,
      }, additionalDirectories),
    );
    return SessionResult.fromJson({...resp, 'sessionId': sessionId});
  }

  /// Fork an existing session to create a new independent session.
  ///
  /// Useful for generating summaries or PR descriptions without
  /// polluting the original session history.
  /// Requires agent support for session/fork capability.
  Future<SessionResult> forkSession({
    required String sessionId,
    String? workspaceRoot,
    List<String> additionalDirectories = const <String>[],
  }) async {
    final root = workspaceRoot ?? _sessionWorkspaceRoots[sessionId];
    final directories = additionalDirectories.isEmpty
        ? _sessionAdditionalDirectories[sessionId] ?? const <String>[]
        : additionalDirectories;
    final resp = await peer.sendRaw(
      'session/fork',
      _sessionSetupParams({
        'sessionId': sessionId,
        'cwd': ?root,
        'mcpServers': config.mcpServers,
      }, directories),
    );
    final newId = resp['sessionId'] as String;
    _sessionStreams.putIfAbsent(newId, StreamController<AcpUpdate>.broadcast);
    _replayBuffers.putIfAbsent(newId, () => <AcpUpdate>[]);
    if (root != null) {
      _setSessionWorkspace(newId, root, additionalDirectories: directories);
    }
    return SessionResult.fromJson(resp);
  }

  /// Set a configuration option for a session.
  ///
  /// Returns the updated list of all config options for the session.
  Future<List<ConfigOption>> setConfigOption({
    required String sessionId,
    required String configId,
    required String value,
  }) async {
    final resp = await peer.sendRaw('session/set_config_option', {
      'sessionId': sessionId,
      'configId': configId,
      'value': value,
    });
    final configList = resp['configOptions'] as List<dynamic>? ?? [];
    return configList
        .map((c) => ConfigOption.fromJson(c as Map<String, dynamic>))
        .toList();
  }

  /// Send a prompt and stream typed updates for this turn only.
  /// The returned stream automatically closes after [TurnEnded].
  Stream<AcpUpdate> prompt({
    required String sessionId,
    required List<Map<String, dynamic>> content,
  }) {
    if (!_sessionStreams.containsKey(sessionId)) {
      // Unknown session; throw error
      throw ArgumentError('Invalid session ID: $sessionId');
    }

    unawaited(() async {
      try {
        final resp = await peer.prompt({
          'sessionId': sessionId,
          'prompt': content,
        });
        final stop = stopReasonFromWire(
          (resp['stopReason'] as String?) ?? 'other',
        );
        final turnEnded = TurnEnded(stop);
        _replayBuffers[sessionId]?.add(turnEnded);
        _sessionStreams[sessionId]!.add(turnEnded);
        if (stop == StopReason.cancelled) {
          _cancellingSessions.remove(sessionId);
        }
      } on Object catch (e, st) {
        _log.warning('prompt error: $e');
        // Surface error to listeners so UIs can react
        _sessionStreams[sessionId]!.addError(e, st);
        // Send TurnEnded with 'other' stop reason to properly close the stream
        const turnEnded = TurnEnded(StopReason.other);
        _replayBuffers[sessionId]?.add(turnEnded);
        _sessionStreams[sessionId]!.add(turnEnded);
      } finally {}
    }());

    final base = _sessionStreams[sessionId]!.stream;
    return Stream<AcpUpdate>.multi((emitter) {
      late final StreamSubscription sub;
      sub = base.listen(
        (u) {
          emitter.add(u);
          if (u is TurnEnded) {
            unawaited(sub.cancel());
            scheduleMicrotask(emitter.close);
          }
        },
        onError: (e, st) => emitter.addError(e, st),
        onDone: () => scheduleMicrotask(emitter.close),
      );
    });
  }

  /// Cancel the current turn for a session.
  Future<void> cancel({required String sessionId}) async {
    _cancellingSessions.add(sessionId);
    await peer.cancel({'sessionId': sessionId});
  }

  /// Get the workspace root for a session.
  String getWorkspaceRoot(String sessionId) {
    final root = _sessionWorkspaceRoots[sessionId];
    if (root == null) {
      throw StateError(
        'Session $sessionId not found or workspace root not set',
      );
    }
    return root;
  }

  void _setSessionWorkspace(
    String sessionId,
    String workspaceRoot, {
    List<String> additionalDirectories = const <String>[],
  }) {
    _sessionWorkspaceRoots[sessionId] = workspaceRoot;
    _sessionAdditionalDirectories[sessionId] = _normalizedDirectories(
      additionalDirectories,
    );
  }

  Json _sessionSetupParams(Json params, List<String> additionalDirectories) {
    final directories = _normalizedDirectories(additionalDirectories);
    if (directories.isEmpty) return params;
    return <String, dynamic>{...params, 'additionalDirectories': directories};
  }

  List<String> _additionalDirectoriesForSession(String sessionId) {
    return _sessionAdditionalDirectories[sessionId] ?? const <String>[];
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

  /// Stream of terminal lifecycle events.
  Stream<TerminalEvent> get terminalEvents => _terminalEvents.stream;

  // Expose a persistent session updates stream (includes replay from
  // session/load and updates across multiple prompts)
  /// Persistent session update stream, including replay.
  Stream<AcpUpdate> sessionUpdates(String sessionId) async* {
    final buffer = List<AcpUpdate>.from(_replayBuffers[sessionId] ?? const []);
    for (final u in buffer) {
      yield u;
    }
    yield* _sessionStreams
        .putIfAbsent(sessionId, StreamController<AcpUpdate>.broadcast)
        .stream;
  }

  void _routeSessionUpdate(Json json) {
    final sessionId = json['sessionId'] as String?;
    final update = json['update'] as Map<String, dynamic>?;
    if (sessionId == null || update == null) return;
    // Ensure structures exist so we don't drop early updates (e.g., commands
    // emitted immediately after session/new).
    _sessionStreams.putIfAbsent(
      sessionId,
      StreamController<AcpUpdate>.broadcast,
    );
    _replayBuffers.putIfAbsent(sessionId, () => <AcpUpdate>[]);

    final kind = update['sessionUpdate'];
    if (kind == 'available_commands_update') {
      final cmds = _availableCommandsFromRaw(update['availableCommands']);
      final u = AvailableCommandsUpdate.fromRaw(cmds);
      _replayBuffers[sessionId]!.add(u);
      _sessionStreams[sessionId]!.add(u);
    } else if (kind == 'plan') {
      final u = PlanUpdate.fromJson(update);
      _replayBuffers[sessionId]!.add(u);
      _sessionStreams[sessionId]!.add(u);
    } else if (kind == 'tool_call' || kind == 'tool_call_update') {
      // Get tool call ID from the update
      final toolCallId =
          update['toolCallId'] as String? ?? update['id'] as String? ?? '';

      // Initialize tool calls map for session if needed
      _toolCalls.putIfAbsent(sessionId, () => {});

      final ToolCall toolCall;
      if (kind == 'tool_call') {
        // New tool call - create and store it
        toolCall = ToolCall.fromJson(update);
        _toolCalls[sessionId]![toolCallId] = toolCall;
      } else {
        // tool_call_update - merge with existing
        final existing = _toolCalls[sessionId]![toolCallId];
        if (existing != null) {
          // Merge update fields into existing tool call
          toolCall = existing.merge(update);
          _toolCalls[sessionId]![toolCallId] = toolCall;
        } else {
          // No existing tool call found, create new one from update
          toolCall = ToolCall.fromJson(update);
          _toolCalls[sessionId]![toolCallId] = toolCall;
        }
      }

      final u = ToolCallUpdate(toolCall);
      _replayBuffers[sessionId]!.add(u);
      _sessionStreams[sessionId]!.add(u);
    } else if (kind == 'user_message_chunk' ||
        kind == 'agent_message_chunk' ||
        kind == 'agent_thought_chunk') {
      final blocks = _contentBlocksFromRaw(update['content']);
      final role = kind == 'user_message_chunk' ? 'user' : 'assistant';
      final u = MessageDelta.fromRaw(
        role: role,
        rawContent: blocks,
        isThought: kind == 'agent_thought_chunk',
      );
      _replayBuffers[sessionId]!.add(u);
      _sessionStreams[sessionId]!.add(u);
    } else if (kind == 'diff') {
      final u = DiffUpdate.fromJson(update);
      _replayBuffers[sessionId]!.add(u);
      _sessionStreams[sessionId]!.add(u);
    } else if (kind == 'current_mode_update') {
      final currentModeId = update['currentModeId'] as String?;
      if (currentModeId != null) {
        final existing = _sessionModes[sessionId];
        if (existing != null) {
          _sessionModes[sessionId] = (
            currentModeId: currentModeId,
            availableModes: existing.availableModes,
          );
        } else {
          _sessionModes[sessionId] = (
            currentModeId: currentModeId,
            availableModes: const <({String id, String name})>[],
          );
        }
      }
      final u = ModeUpdate(currentModeId ?? '');
      _replayBuffers[sessionId]!.add(u);
      _sessionStreams[sessionId]!.add(u);
    } else {
      final u = UnknownUpdate(json);
      _replayBuffers[sessionId]!.add(u);
      _sessionStreams[sessionId]!.add(u);
    }
  }

  // ===== Modes support (extension) =====
  // Store current mode and available modes per session when provided.
  final Map<
    String,
    ({String? currentModeId, List<({String id, String name})> availableModes})
  >
  _sessionModes = {};

  /// Returns currently known modes info for the session, if any.
  ({String? currentModeId, List<({String id, String name})> availableModes})?
  sessionModes(String sessionId) => _sessionModes[sessionId];

  /// Set the session mode (extension). Returns true if RPC succeeds.
  Future<bool> setSessionMode({
    required String sessionId,
    required String modeId,
  }) async {
    try {
      await peer.setSessionMode({'sessionId': sessionId, 'modeId': modeId});
      return true;
    } on Exception catch (_) {
      return false;
    }
  }

  // ===== Agent -> Client handlers =====
  Future<Json> _onReadTextFile(Json req) async {
    if (config.fsProvider == null) {
      throw Exception('File system operations not supported');
    }
    final sessionId = req['sessionId'] as String?;
    final workspaceRoot = sessionId != null
        ? _sessionWorkspaceRoots[sessionId]
        : _sessionWorkspaceRoots.values.firstOrNull;
    if (workspaceRoot == null) {
      throw Exception('No workspace root available for filesystem operation');
    }

    // Create a session-specific provider honoring configured access policy
    final provider = DefaultFsProvider(
      workspaceRoot: workspaceRoot,
      additionalWorkspaceRoots: _additionalDirectoriesForSession(
        sessionId ?? '',
      ),
      allowReadOutsideWorkspace: config.allowReadOutsideWorkspace,
      // yolo does NOT allow writes outside workspace
    );

    // Enforce permission policy for reads when provided (non-interactive
    // policy mode). Agents may or may not request permission explicitly;
    // we gate here to ensure policy is always respected.
    try {
      final outcome = await config.permissionProvider.request(
        PermissionOptions(
          title: 'Read file',
          rationale: 'Agent requested to read a file',
          options: const ['allow', 'deny'],
          sessionId: sessionId ?? '',
          toolName: 'read_text_file',
          toolKind: 'read',
          metadata: <String, Object?>{
            'path': req['path'],
            'workspaceRoot': workspaceRoot,
          },
        ),
      );
      if (outcome != PermissionOutcome.allow) {
        throw Exception('Permission denied');
      }
    } catch (e) {
      _log.fine('fs/read_text_file -> denied by policy');
      rethrow;
    }

    final path = req['path'] as String;
    final line = (req['line'] as num?)?.toInt();
    final limit = (req['limit'] as num?)?.toInt();
    _log.fine('fs/read_text_file <- path=$path line=$line limit=$limit');
    try {
      final content = await provider.readTextFile(
        path,
        line: line,
        limit: limit,
      );
      _log.fine('fs/read_text_file -> ok path=$path bytes=${content.length}');
      return {'content': content};
    } catch (e) {
      _log.warning('fs/read_text_file -> error path=$path: $e');
      rethrow;
    }
  }

  Future<Json?> _onWriteTextFile(Json req) async {
    if (config.fsProvider == null) {
      throw Exception('File system operations not supported');
    }
    final sessionId = req['sessionId'] as String?;
    final workspaceRoot = sessionId != null
        ? _sessionWorkspaceRoots[sessionId]
        : _sessionWorkspaceRoots.values.firstOrNull;
    if (workspaceRoot == null) {
      throw Exception('No workspace root available for filesystem operation');
    }

    // Create a session-specific provider honoring configured access policy
    final provider = DefaultFsProvider(
      workspaceRoot: workspaceRoot,
      additionalWorkspaceRoots: _additionalDirectoriesForSession(
        sessionId ?? '',
      ),
      allowReadOutsideWorkspace: config.allowReadOutsideWorkspace,
      // yolo does NOT allow writes outside workspace
    );

    // Enforce permission policy for writes when provided.
    try {
      final outcome = await config.permissionProvider.request(
        PermissionOptions(
          title: 'Write file',
          rationale: 'Agent requested to write a file',
          options: const ['allow', 'deny'],
          sessionId: sessionId ?? '',
          toolName: 'write_text_file',
          toolKind: 'edit',
          metadata: <String, Object?>{
            'path': req['path'],
            'workspaceRoot': workspaceRoot,
          },
        ),
      );
      if (outcome != PermissionOutcome.allow) {
        throw Exception('Permission denied');
      }
    } catch (e) {
      _log.fine('fs/write_text_file -> denied by policy');
      rethrow;
    }

    final path = req['path'] as String;
    final content = req['content'] as String? ?? '';
    _log.fine('fs/write_text_file <- path=$path bytes=${content.length}');
    try {
      await provider.writeTextFile(path, content);
      _log.fine('fs/write_text_file -> ok path=$path');
      return null; // per schema null
    } catch (e) {
      _log.warning('fs/write_text_file -> error path=$path: $e');
      rethrow;
    }
  }

  Future<Json> _onRequestPermission(Json req) async {
    final reqSessionId = req['sessionId'] as String? ?? '';
    if (_cancellingSessions.contains(reqSessionId)) {
      return {
        'outcome': {'outcome': 'cancelled'},
      };
    }
    final options = _permissionChoicesFromRaw(req['options']);
    final toolCall = req['toolCall'] as Map<String, dynamic>?;
    final toolName = (toolCall?['title'] as String?) ?? 'operation';
    final toolKind = toolCall?['kind'] as String?;
    final metadata = <String, Object?>{};
    if (toolCall != null) metadata['toolCall'] = toolCall;
    final outcome = await config.permissionProvider.request(
      PermissionOptions(
        title: toolName,
        rationale: 'Requested by agent',
        options: options.map((choice) => choice.label).toList(),
        sessionId: req['sessionId'] as String? ?? '',
        toolName: toolName,
        toolKind: toolKind,
        metadata: metadata,
      ),
    );

    if (outcome == PermissionOutcome.cancelled) {
      return {
        'outcome': {'outcome': 'cancelled'},
      };
    }

    final optionId = _permissionOptionIdForOutcome(options, outcome);
    if (optionId == null) {
      return {
        'outcome': {'outcome': 'cancelled'},
      };
    }
    return {
      'outcome': {'outcome': 'selected', 'optionId': optionId},
    };
  }

  final Map<String, TerminalProcessHandle> _terminals = {};

  Future<Json> _onTerminalCreate(Json req) async {
    final provider = config.terminalProvider;
    if (provider == null) {
      throw Exception('Terminal not supported');
    }
    final sessionId = req['sessionId'] as String? ?? '';
    final cmd = req['command'] as String;
    final args = (req['args'] as List?)?.cast<String>() ?? const [];
    final requestedCwd = req['cwd'] as String?;
    final envList = (req['env'] as List?)?.cast<Map<String, dynamic>>();
    final env = <String, String>{
      if (envList != null)
        for (final e in envList) (e['name'] as String): (e['value'] as String),
    };
    final workspaceRoot = getWorkspaceRoot(sessionId);
    final permissionMetadata = <String, Object?>{
      'command': cmd,
      'args': args,
      'workspaceRoot': workspaceRoot,
    };
    if (requestedCwd != null) permissionMetadata['cwd'] = requestedCwd;
    if (env.isNotEmpty) {
      permissionMetadata['envKeys'] = env.keys.toList()..sort();
    }

    // Enforce permission for execute/terminal usage. If policy denies, reject
    // terminal creation so the agent cannot bypass FS jail via shell.
    final execOutcome = await config.permissionProvider.request(
      PermissionOptions(
        title: 'Create terminal',
        rationale: 'Agent requested to execute commands',
        options: const ['allow', 'deny'],
        sessionId: sessionId,
        toolName: 'terminal',
        toolKind: 'execute',
        metadata: permissionMetadata,
      ),
    );
    if (execOutcome != PermissionOutcome.allow) {
      throw Exception('Permission denied');
    }
    var cwd = requestedCwd;
    // Enforce workspace jail for terminal working directory unless yolo
    if (!config.allowReadOutsideWorkspace) {
      final jail = WorkspaceJail(
        workspaceRoot: workspaceRoot,
        additionalWorkspaceRoots: _additionalDirectoriesForSession(sessionId),
      );
      if (cwd != null) {
        try {
          final resolved = await jail.resolveForgiving(cwd);
          final within = await jail.isWithinWorkspace(resolved);
          if (!within) {
            cwd = workspaceRoot;
          }
        } on Exception catch (_) {
          cwd = workspaceRoot;
        }
      } else {
        cwd = workspaceRoot;
      }
    }

    final handle = await provider.create(
      sessionId: sessionId,
      command: cmd,
      args: args,
      cwd: cwd,
      env: env.isEmpty ? null : env,
    );
    _terminals[handle.terminalId] = handle;
    _terminalEvents.add(
      TerminalCreated(
        terminalId: handle.terminalId,
        sessionId: sessionId,
        command: cmd,
        args: args,
        cwd: cwd,
      ),
    );
    return {'terminalId': handle.terminalId};
  }

  Future<Json> _onTerminalOutput(Json req) async {
    final provider = config.terminalProvider;
    if (provider == null) {
      return {'outputmode': '', 'truncated': false, 'exitStatus': null};
    }
    final termId = req['terminalId'] as String;
    final handle = _terminals[termId];
    if (handle == null) {
      return {'outputmode': '', 'truncated': false, 'exitStatus': null};
    }
    final output = await provider.currentOutput(handle);
    int? exitCode;
    try {
      exitCode = await handle.process.exitCode.timeout(
        const Duration(milliseconds: 1),
      );
    } on TimeoutException {
      exitCode = null;
    }
    _terminalEvents.add(
      TerminalOutputEvent(
        terminalId: termId,
        output: output,
        truncated: false,
        exitCode: exitCode,
      ),
    );
    return {
      'outputmode': output,
      'truncated': false,
      'exitStatus': exitCode == null ? null : {'code': exitCode},
    };
  }

  Future<Json> _onTerminalWaitForExit(Json req) async {
    final provider = config.terminalProvider;
    if (provider == null) {
      return {
        'outputmode': '',
        'truncated': false,
        'exitStatus': {'code': 0},
      };
    }
    final termId = req['terminalId'] as String;
    final handle = _terminals[termId];
    if (handle == null) {
      return {
        'outputmode': '',
        'truncated': false,
        'exitStatus': {'code': 0},
      };
    }
    final code = await provider.waitForExit(handle);
    _terminalEvents.add(TerminalExited(terminalId: termId, code: code));
    return {
      'outputmode': handle.currentOutput(),
      'truncated': false,
      'exitStatus': {'code': code},
    };
  }

  Future<Json?> _onTerminalKill(Json req) async {
    final provider = config.terminalProvider;
    final termId = req['terminalId'] as String;
    final handle = _terminals[termId];
    if (provider != null && handle != null) {
      await provider.kill(handle);
    }
    return null;
  }

  Future<Json?> _onTerminalRelease(Json req) async {
    final provider = config.terminalProvider;
    final termId = req['terminalId'] as String;
    final handle = _terminals.remove(termId);
    if (provider != null && handle != null) {
      await provider.release(handle);
    }
    _terminalEvents.add(TerminalReleased(terminalId: termId));
    return null;
  }

  // UI helpers to interact with terminals
  /// Read buffered output for a managed terminal.
  Future<String> readTerminalOutput(String terminalId) async {
    final handle = _terminals[terminalId];
    if (handle == null) return '';
    return handle.currentOutput();
  }

  /// Kill a managed terminal process.
  Future<void> killTerminal(String terminalId) async {
    final provider = config.terminalProvider;
    final handle = _terminals[terminalId];
    if (provider != null && handle != null) {
      await provider.kill(handle);
    }
  }

  /// Wait for a terminal to exit and return its code, or null if unavailable.
  Future<int?> waitTerminal(String terminalId) async {
    final provider = config.terminalProvider;
    final handle = _terminals[terminalId];
    if (provider != null && handle != null) {
      final code = await provider.waitForExit(handle);
      return code;
    }
    return null;
  }

  /// Release resources for a managed terminal.
  Future<void> releaseTerminal(String terminalId) async {
    final provider = config.terminalProvider;
    final handle = _terminals.remove(terminalId);
    if (provider != null && handle != null) {
      await provider.release(handle);
    }
  }
}
