import 'dart:async';
import 'dart:convert';

import 'package:logging/logging.dart';

import '../capabilities.dart';
import '../config.dart';
import '../extensions.dart';
import '../input_budget.dart';
import '../models/content_types.dart';
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

/// Smallest replay byte budget that can retain the truncation marker.
const int minimumSessionReplayBytes = 64;

class SessionToolStateLimitException implements Exception {
  const SessionToolStateLimitException({
    required this.maxItems,
    required this.maxBytes,
  });

  final int maxItems;
  final int maxBytes;

  @override
  String toString() =>
      'Session tool state limit exceeded; manual intervention required '
      '(maxItems: $maxItems, maxBytes: $maxBytes)';
}

class SessionCloseCleanupException implements Exception {
  const SessionCloseCleanupException(this.failedStages);

  final List<String> failedStages;

  @override
  String toString() =>
      'Session close cleanup failed in ${failedStages.length} stage(s): '
      '${failedStages.join(', ')}';
}

class _ReplayBuffer {
  _ReplayBuffer({required this.maxItems, required this.maxBytes});

  final int maxItems;
  final int maxBytes;
  final List<AcpUpdate> _updates = <AcpUpdate>[];
  final List<int> _sizes = <int>[];
  var _bytes = 0;

  static const _markerSize = minimumSessionReplayBytes;
  static const _marker = UnknownUpdate(<String, dynamic>{
    'sessionUpdate': 'replay_truncated',
    'truncated': true,
  });

  List<AcpUpdate> get updates => List<AcpUpdate>.unmodifiable(_updates);

  void add(AcpUpdate update, {int? sizeBytes}) {
    final size = sizeBytes ?? utf8.encode(update.text).length + 32;
    _updates.add(update);
    _sizes.add(size);
    _bytes += size;
    var truncated = false;
    while (_updates.length > maxItems || _bytes > maxBytes) {
      final index = _updates.isNotEmpty && identical(_updates.first, _marker)
          ? 1
          : 0;
      if (index >= _updates.length) break;
      _bytes -= _sizes.removeAt(index);
      _updates.removeAt(index);
      truncated = true;
    }
    if (truncated &&
        (_updates.isEmpty || !identical(_updates.first, _marker))) {
      _updates.insert(0, _marker);
      _sizes.insert(0, _markerSize);
      _bytes += _markerSize;
    }
    while (_updates.length > maxItems || _bytes > maxBytes) {
      if (_updates.length <= 1) break;
      _bytes -= _sizes.removeAt(1);
      _updates.removeAt(1);
    }
  }
}

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
    if (!_permissionChoiceIsPersistent(choice) &&
        _permissionKindMatches(choice.kind, outcome)) {
      return choice.optionId;
    }
  }
  for (final choice in choices) {
    if (!_permissionChoiceIsPersistent(choice) &&
        _permissionLabelMatches(choice, outcome)) {
      return choice.optionId;
    }
  }
  return null;
}

bool _permissionChoiceIsPersistent(_PermissionChoice choice) {
  final normalizedKind = choice.kind?.trim().toLowerCase() ?? '';
  if (normalizedKind.endsWith('_always')) return true;
  final words = choice.searchableText
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9]+'))
      .where((word) => word.isNotEmpty)
      .toSet();
  const persistentWords = <String>{
    'always',
    'forever',
    'permanent',
    'persist',
    'remember',
    'session',
    'project',
  };
  return words.any(persistentWords.contains);
}

String? _permissionOptionIdForDecision(
  List<_PermissionChoice> choices,
  PermissionDecision decision,
) {
  final selectedOptionId = decision.optionId?.trim();
  if (selectedOptionId != null && selectedOptionId.isNotEmpty) {
    for (final choice in choices) {
      if (choice.optionId != selectedOptionId) continue;
      if (_permissionKindMatches(choice.kind, decision.outcome) ||
          _permissionLabelMatches(choice, decision.outcome)) {
        return choice.optionId;
      }
      return null;
    }
    return null;
  }
  return _permissionOptionIdForOutcome(choices, decision.outcome);
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

Map<String, dynamic>? _jsonMapFromRaw(Object? raw) {
  if (raw is! Map) return null;
  return raw.map((key, value) => MapEntry(key.toString(), value));
}

String _permissionToolName(Map<String, dynamic>? toolCall) {
  return _firstNonEmptyString(toolCall, const [
        'title',
        'name',
        'toolName',
        'tool_name',
      ]) ??
      'operation';
}

String? _permissionToolKind(Map<String, dynamic>? toolCall) {
  return _firstNonEmptyString(toolCall, const [
    'kind',
    'toolKind',
    'tool_kind',
  ]);
}

String? _firstNonEmptyString(Map<String, dynamic>? map, List<String> keys) {
  if (map == null) return null;
  for (final key in keys) {
    final value = _nonEmptyString(map[key]);
    if (value != null) return value;
  }
  return null;
}

String? _sessionIdFromMap(Map<String, dynamic>? map) {
  return _firstNonEmptyString(map, const ['sessionId', 'session_id']);
}

String _requireSessionResultId(SessionResult result, {required String method}) {
  final sessionId = result.sessionId.trim();
  if (sessionId.isEmpty) {
    throw FormatException('$method response did not include a session id.');
  }
  return sessionId;
}

SessionResult _withExpectedSessionId(SessionResult result, String sessionId) {
  final received = result.sessionId.trim();
  if (received.isNotEmpty && received != sessionId) {
    throw const FormatException('ACP session response id did not match.');
  }
  return SessionResult(
    sessionId: sessionId,
    configOptions: result.configOptions,
    meta: result.meta,
    modes: result.modes,
    omissions: result.omissions,
  );
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
    this.agentInfo = const <String, dynamic>{},
  });

  /// Negotiated protocol version.
  final int protocolVersion;

  /// Agent capabilities (if provided).
  final Map<String, dynamic>? agentCapabilities;

  /// Supported auth methods (if any).
  final List<Map<String, dynamic>>? authMethods;

  final Map<String, dynamic> agentInfo;

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

/// Opaque identity for one session input-budget phase.
final class AcpSessionInputBudgetOwner {
  const AcpSessionInputBudgetOwner._(this.sessionId, this.generation);

  final String sessionId;
  final int generation;
}

final class _SessionInputBudgetPhase {
  _SessionInputBudgetPhase({
    required this.owner,
    required this.structuredGuard,
    required this.text,
    required this.thought,
  });

  final AcpSessionInputBudgetOwner owner;
  final AcpStructuredUpdateGuard structuredGuard;
  final AcpUtf8LineBudgetCounter text;
  final AcpUtf8LineBudgetCounter thought;
  int mediaBytes = 0;
  int items = 0;
  int retainedBytes = 0;
  bool invalidated = false;
}

final class _RequestInputBudgetPhase {
  _RequestInputBudgetPhase({
    required this.structuredGuard,
    this.sourceSessionId,
    this.sourceWasRegistered = false,
  });

  final AcpStructuredUpdateGuard structuredGuard;
  final String? sourceSessionId;
  final bool sourceWasRegistered;
  bool invalidated = false;
}

final class _GeneratedSessionRegistration {
  const _GeneratedSessionRegistration(this.sessionId, this.identity);

  final String sessionId;
  final Object identity;
}

/// Orchestrates ACP lifecycle and routes updates/tool/terminal handlers.
class SessionManager {
  /// Create a [SessionManager] with [config] and [peer].
  SessionManager({
    required this.config,
    required this.peer,
    this.maxReplayItems = 2048,
    this.maxReplayBytes = 16 * 1024 * 1024,
    this.maxToolCallItems = 512,
    this.maxToolCallBytes = 8 * 1024 * 1024,
    this.inputBudget = const AcpInputBudget(),
  }) : assert(maxReplayItems > 0),
       assert(maxReplayBytes > 0),
       assert(maxToolCallItems > 0),
       assert(maxToolCallBytes > 0),
       _log = config.logger {
    inputBudget.validate();
    if (maxReplayBytes < minimumSessionReplayBytes) {
      throw ArgumentError.value(
        maxReplayBytes,
        'maxReplayBytes',
        'must be at least $minimumSessionReplayBytes bytes',
      );
    }
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
  final int maxReplayItems;
  final int maxReplayBytes;
  final int maxToolCallItems;
  final int maxToolCallBytes;
  final AcpInputBudget inputBudget;

  final Map<String, StreamController<AcpUpdate>> _sessionStreams = {};
  final Map<String, _ReplayBuffer> _replayBuffers = {};
  final Map<String, _SessionInputBudgetPhase> _inputBudgetPhases =
      <String, _SessionInputBudgetPhase>{};
  final Set<_RequestInputBudgetPhase> _requestInputBudgetPhases =
      <_RequestInputBudgetPhase>{};
  final Map<String, Object> _generatedSessionRegistrationOwners =
      <String, Object>{};
  final Map<String, AcpSessionInputBudgetOwner> _cancelledPromptOwners =
      <String, AcpSessionInputBudgetOwner>{};
  final StreamController<TerminalEvent> _terminalEvents =
      StreamController<TerminalEvent>.broadcast();
  // Track tool calls by session and tool call ID for proper merging
  final Map<String, Map<String, ToolCall>> _toolCalls = {};
  final Map<String, Map<String, int>> _toolCallSizes = {};
  var _toolCallItemCount = 0;
  var _toolCallByteCount = 0;
  // Track workspace roots per session for filesystem operations
  final Map<String, String> _sessionWorkspaceRoots = {};
  final Map<String, List<String>> _sessionAdditionalDirectories = {};
  final Map<String, Future<void>> _sessionSetupTails = {};
  final Map<String, Set<Object>> _sessionClosingOwners =
      <String, Set<Object>>{};
  var _nextInputBudgetGeneration = 0;
  var _disposed = false;

  _ReplayBuffer _newReplayBuffer() =>
      _ReplayBuffer(maxItems: maxReplayItems, maxBytes: maxReplayBytes);

  void _closeControllerWithoutWaiting<T>(StreamController<T>? controller) {
    if (controller == null) return;
    try {
      unawaited(controller.close().catchError((Object _) {}));
    } on Object {
      // Closing is best-effort and must not depend on listeners consuming done.
    }
  }

  /// Dispose all internal resources and close streams.
  Future<void> dispose() async {
    _disposed = true;
    _invalidateAllInputBudgetPhases();
    _invalidateAllRequestInputBudgetPhases();
    final terminalProvider = config.terminalProvider;
    final terminals = _terminals.values.toList(growable: false);
    _terminals.clear();
    _terminalSessions.clear();
    var terminalReleaseFailures = 0;
    if (terminalProvider != null) {
      await Future.wait<void>(
        terminals.map((handle) async {
          try {
            await terminalProvider.release(handle);
          } on Object {
            terminalReleaseFailures += 1;
          }
        }),
      );
    }
    if (terminalReleaseFailures > 0) {
      _log.warning(
        'session dispose cleanup stage terminals failed '
        '(count: $terminalReleaseFailures)',
      );
    }
    _closeControllerWithoutWaiting(_terminalEvents);
    final sessionStreams = _sessionStreams.values.toList(growable: false);
    _sessionStreams.clear();
    for (final controller in sessionStreams) {
      _closeControllerWithoutWaiting(controller);
    }
    _replayBuffers.clear();
    _toolCalls.clear();
    _toolCallSizes.clear();
    _toolCallItemCount = 0;
    _toolCallByteCount = 0;
    _cancelledPromptOwners.clear();
    _sessionWorkspaceRoots.clear();
    _sessionAdditionalDirectories.clear();
    _sessionModes.clear();
    _sessionSetupTails.clear();
    _sessionClosingOwners.clear();
    _generatedSessionRegistrationOwners.clear();
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
    final copied = copyBoundedInitializeInput(
      agentCapabilities: resp['agentCapabilities'],
      authMethods: resp['authMethods'],
      agentInfo: resp['agentInfo'],
      budget: inputBudget,
    );
    final negotiated = (resp['protocolVersion'] as num?)?.toInt() ?? 0;
    if (negotiated < AcpConfig.minimumProtocolVersion) {
      throw StateError(
        'Unsupported ACP protocol version: $negotiated. '
        'Minimum required: ${AcpConfig.minimumProtocolVersion}.',
      );
    }
    return InitializeResult(
      protocolVersion: (resp['protocolVersion'] as num?)?.toInt() ?? 1,
      agentCapabilities: resp['agentCapabilities'] == null
          ? null
          : copied.agentCapabilities,
      authMethods: resp['authMethods'] == null ? null : copied.authMethods,
      agentInfo: copied.agentInfo,
    );
  }

  /// Create a new session and return its id.
  Future<String> newSession({
    required String workspaceRoot,
    List<String> additionalDirectories = const <String>[],
  }) async {
    final requestPhase = _beginRequestInputBudgetPhase(
      resource: 'session new response',
    );
    try {
      final resp = await peer.newSession(
        _sessionSetupParams({
          'cwd': workspaceRoot,
          'mcpServers': config.mcpServers,
        }, additionalDirectories),
      );
      _requireRequestInputBudgetPhase(requestPhase);
      final result = SessionResult.fromJson(
        resp,
        inputBudget: inputBudget,
        structuredGuard: requestPhase.structuredGuard,
      );
      final id = _requireSessionResultId(result, method: 'session/new');
      final registration = await _registerGeneratedSession(
        sessionId: id,
        workspaceRoot: workspaceRoot,
        additionalDirectories: additionalDirectories,
        modes: result.modes,
        requestPhase: requestPhase,
      );
      try {
        await _drainGeneratedSessionUpdates(id);
        _requireRequestInputBudgetPhase(requestPhase);
        _commitGeneratedSessionRegistration(registration);
      } on Object {
        await _rollbackGeneratedSession(registration);
        rethrow;
      }
      return id;
    } finally {
      _endRequestInputBudgetPhase(requestPhase);
    }
  }

  /// Load a previous session and replay updates to the client.
  Future<void> loadSession({
    required String sessionId,
    required String workspaceRoot,
    List<String> additionalDirectories = const <String>[],
  }) async {
    await _runSessionSetup<SessionResult>(
      sessionId: sessionId,
      workspaceRoot: workspaceRoot,
      additionalDirectories: additionalDirectories,
      action: (phase) async {
        final resp = await peer.sendRaw(
          'session/load',
          _sessionSetupParams({
            'sessionId': sessionId,
            'cwd': workspaceRoot,
            'mcpServers': config.mcpServers,
          }, additionalDirectories),
        );
        final parsed = SessionResult.fromJson(
          resp,
          inputBudget: inputBudget,
          structuredGuard: phase.structuredGuard,
        );
        final result = _withExpectedSessionId(parsed, sessionId);
        _requireInputBudgetPhase(phase.owner);
        _consumePhaseSessionResult(phase, result);
        await Future<void>.delayed(Duration.zero);
        return result;
      },
      commit: (result) => _commitSessionResultModes(sessionId, result),
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

  /// Close a remote session, then release all state owned by that session.
  Future<void> closeSession({required String sessionId}) async {
    final closingOwner = _beginSessionClose(sessionId);
    try {
      await peer.sendRaw('session/close', <String, dynamic>{
        'sessionId': sessionId,
      });
      await _runSerializedSessionMutation(sessionId, () async {
        final failedStages = <String>[];

        Future<void> cleanup(
          String stage,
          FutureOr<void> Function() action,
        ) async {
          try {
            await action();
          } on Object {
            failedStages.add(stage);
            _log.warning('session close cleanup stage $stage failed');
          }
        }

        await cleanup('stream', () {
          _closeControllerWithoutWaiting(_sessionStreams.remove(sessionId));
        });
        await cleanup('replay', () => _replayBuffers.remove(sessionId));
        await cleanup(
          'workspace',
          () => _sessionWorkspaceRoots.remove(sessionId),
        );
        await cleanup(
          'additionalDirectories',
          () => _sessionAdditionalDirectories.remove(sessionId),
        );
        await cleanup('modes', () => _sessionModes.remove(sessionId));
        await cleanup(
          'registration',
          () => _generatedSessionRegistrationOwners.remove(sessionId),
        );
        await cleanup('toolCalls', () => _removeToolCalls(sessionId));
        await cleanup('prompt', () {
          _invalidateInputBudgetPhase(sessionId);
          _cancelledPromptOwners.remove(sessionId);
        });
        await cleanup('terminals', () => _releaseSessionTerminals(sessionId));

        if (failedStages.isNotEmpty) {
          throw SessionCloseCleanupException(
            List<String>.unmodifiable(failedStages),
          );
        }
      });
    } finally {
      _endSessionClose(sessionId, closingOwner);
    }
  }

  Object _beginSessionClose(String sessionId) {
    _invalidateInputBudgetPhase(sessionId);
    _invalidateRequestInputBudgetPhasesForSource(sessionId);
    _cancelledPromptOwners.remove(sessionId);
    final owner = Object();
    _sessionClosingOwners.putIfAbsent(sessionId, () => <Object>{}).add(owner);
    return owner;
  }

  void _endSessionClose(String sessionId, Object owner) {
    final owners = _sessionClosingOwners[sessionId];
    if (owners == null) return;
    owners.remove(owner);
    if (owners.isEmpty) _sessionClosingOwners.remove(sessionId);
  }

  bool _isSessionClosing(String sessionId) =>
      _sessionClosingOwners[sessionId]?.isNotEmpty ?? false;

  /// Resume a session without loading history (simpler than loadSession).
  ///
  /// Requires agent support for session/resume capability.
  Future<SessionResult> resumeSession({
    required String sessionId,
    required String workspaceRoot,
    List<String> additionalDirectories = const <String>[],
  }) async {
    return _runSessionSetup<SessionResult>(
      sessionId: sessionId,
      workspaceRoot: workspaceRoot,
      additionalDirectories: additionalDirectories,
      action: (phase) async {
        final resp = await peer.sendRaw(
          'session/resume',
          _sessionSetupParams({
            'sessionId': sessionId,
            'cwd': workspaceRoot,
            'mcpServers': config.mcpServers,
          }, additionalDirectories),
        );
        final parsed = SessionResult.fromJson(
          resp,
          inputBudget: inputBudget,
          structuredGuard: phase.structuredGuard,
        );
        final result = _withExpectedSessionId(parsed, sessionId);
        _requireInputBudgetPhase(phase.owner);
        _consumePhaseSessionResult(phase, result);
        await Future<void>.delayed(Duration.zero);
        return result;
      },
      commit: (result) => _commitSessionResultModes(sessionId, result),
    );
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
    if (root == null) {
      throw StateError(
        'Cannot fork session $sessionId without a workspace binding',
      );
    }
    final directories = additionalDirectories.isEmpty
        ? _sessionAdditionalDirectories[sessionId] ?? const <String>[]
        : additionalDirectories;
    final requestPhase = _beginRequestInputBudgetPhase(
      resource: 'session fork response',
      sourceSessionId: sessionId,
      sourceWasRegistered: _sessionWorkspaceRoots.containsKey(sessionId),
    );
    try {
      final resp = await peer.sendRaw(
        'session/fork',
        _sessionSetupParams({
          'sessionId': sessionId,
          'cwd': root,
          'mcpServers': config.mcpServers,
        }, directories),
      );
      _requireRequestInputBudgetPhase(requestPhase);
      final result = SessionResult.fromJson(
        resp,
        inputBudget: inputBudget,
        structuredGuard: requestPhase.structuredGuard,
      );
      final newId = _requireSessionResultId(result, method: 'session/fork');
      final registration = await _registerGeneratedSession(
        sessionId: newId,
        workspaceRoot: root,
        additionalDirectories: directories,
        modes: result.modes,
        requestPhase: requestPhase,
      );
      try {
        await _drainGeneratedSessionUpdates(newId);
        _requireRequestInputBudgetPhase(requestPhase);
        _commitGeneratedSessionRegistration(registration);
      } on Object {
        await _rollbackGeneratedSession(registration);
        rethrow;
      }
      return result;
    } finally {
      _endRequestInputBudgetPhase(requestPhase);
    }
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
    if (!_sessionWorkspaceRoots.containsKey(sessionId)) {
      throw StateError('Session $sessionId has no workspace binding');
    }

    final base = _sessionStreams[sessionId]!.stream;
    late final StreamController<AcpUpdate> controller;
    StreamSubscription<AcpUpdate>? subscription;
    AcpSessionInputBudgetOwner? promptOwner;
    var requestFinished = false;
    controller = StreamController<AcpUpdate>(
      onListen: () {
        subscription = base.listen(
          (u) {
            if (!controller.isClosed) controller.add(u);
            if (u is TurnEnded) {
              unawaited(subscription?.cancel());
              _closeControllerWithoutWaiting(controller);
            }
          },
          onError: (e, st) {
            if (!controller.isClosed) controller.addError(e, st);
          },
          onDone: () {
            if (!controller.isClosed) {
              _closeControllerWithoutWaiting(controller);
            }
          },
        );

        unawaited(() async {
          try {
            promptOwner = beginPromptTurn(sessionId);
          } on Object catch (error, stackTrace) {
            await subscription?.cancel();
            if (!controller.isClosed) {
              controller.addError(error, stackTrace);
              _closeControllerWithoutWaiting(controller);
            }
            return;
          }
          try {
            final resp = await peer.prompt({
              'sessionId': sessionId,
              'prompt': content,
            });
            final owner = promptOwner;
            if (owner == null || !_ownsInputBudgetPhase(owner)) {
              requestFinished = true;
              return;
            }
            final stop = stopReasonFromWire(
              (resp['stopReason'] as String?) ?? 'other',
            );
            final turnEnded = TurnEnded(stop);
            requestFinished = true;
            _replayBuffers[sessionId]?.add(turnEnded);
            _sessionStreams[sessionId]?.add(turnEnded);
          } on Object catch (e, st) {
            final owner = promptOwner;
            if (owner == null || !_ownsInputBudgetPhase(owner)) {
              requestFinished = true;
              return;
            }
            _log.warning('prompt error: $e');
            requestFinished = true;
            final sessionController = _sessionStreams[sessionId];
            sessionController?.addError(e, st);
            const turnEnded = TurnEnded(StopReason.other);
            _replayBuffers[sessionId]?.add(turnEnded);
            sessionController?.add(turnEnded);
          } finally {
            final owner = promptOwner;
            if (owner != null) endPromptTurn(owner);
          }
        }());
      },
      onCancel: () async {
        await subscription?.cancel();
        final owner = promptOwner;
        if (owner != null && !requestFinished) {
          try {
            await cancelPromptTurn(owner);
          } on StateError {
            // The exact phase already ended or was invalidated by close/dispose.
          }
        }
      },
    );
    return controller.stream;
  }

  /// Mark [sessionId] as having an active prompt turn.
  AcpSessionInputBudgetOwner beginPromptTurn(String sessionId) {
    if (_disposed) throw StateError('Session manager is disposed.');
    if (_isSessionClosing(sessionId)) {
      throw StateError('Session is closing or closed.');
    }
    if (_sessionSetupTails.containsKey(sessionId)) {
      throw StateError('Session setup is already active.');
    }
    return _beginInputBudgetPhase(sessionId);
  }

  /// Clear turn-local state only when [owner] still owns the phase.
  void endPromptTurn(AcpSessionInputBudgetOwner owner) {
    final phase = _inputBudgetPhases[owner.sessionId];
    if (phase == null || !identical(phase.owner, owner)) return;
    phase.invalidated = true;
    _inputBudgetPhases.remove(owner.sessionId);
  }

  /// Cancel the phase owned by [owner], rejecting stale owners locally.
  Future<void> cancelPromptTurn(AcpSessionInputBudgetOwner owner) {
    final phase = _inputBudgetPhases[owner.sessionId];
    if (phase == null || !identical(phase.owner, owner)) {
      return Future<void>.error(
        StateError('ACP prompt phase owner is no longer active.'),
      );
    }
    phase.invalidated = true;
    _inputBudgetPhases.remove(owner.sessionId);
    _cancelledPromptOwners[owner.sessionId] = owner;
    return peer.cancel({'sessionId': owner.sessionId});
  }

  AcpSessionInputBudgetOwner _beginInputBudgetPhase(String sessionId) {
    if (_disposed) throw StateError('Session manager is disposed.');
    if (_inputBudgetPhases.containsKey(sessionId)) {
      throw StateError('Session input phase is already active.');
    }
    final owner = AcpSessionInputBudgetOwner._(
      sessionId,
      ++_nextInputBudgetGeneration,
    );
    _inputBudgetPhases[sessionId] = _SessionInputBudgetPhase(
      owner: owner,
      structuredGuard: AcpStructuredUpdateGuard(
        budget: inputBudget,
        resource: 'session input phase',
      ),
      text: AcpUtf8LineBudgetCounter(
        maxBytes: inputBudget.maxMessageTextBytes,
        maxLines: inputBudget.maxMessageTextLines,
        resource: 'message text',
      ),
      thought: AcpUtf8LineBudgetCounter(
        maxBytes: inputBudget.maxThoughtTextBytes,
        maxLines: inputBudget.maxMessageTextLines,
        resource: 'thought text',
      ),
    );
    _cancelledPromptOwners.remove(sessionId);
    return owner;
  }

  void _invalidateInputBudgetPhase(String sessionId) {
    final phase = _inputBudgetPhases.remove(sessionId);
    if (phase != null) phase.invalidated = true;
  }

  void _invalidateAllInputBudgetPhases() {
    for (final phase in _inputBudgetPhases.values) {
      phase.invalidated = true;
    }
    _inputBudgetPhases.clear();
  }

  _RequestInputBudgetPhase _beginRequestInputBudgetPhase({
    required String resource,
    String? sourceSessionId,
    bool sourceWasRegistered = false,
  }) {
    if (_disposed) throw StateError('Session manager is disposed.');
    if (sourceSessionId != null && _isSessionClosing(sourceSessionId)) {
      throw StateError('Session is closing or closed.');
    }
    final phase = _RequestInputBudgetPhase(
      structuredGuard: AcpStructuredUpdateGuard(
        budget: inputBudget,
        resource: resource,
      ),
      sourceSessionId: sourceSessionId,
      sourceWasRegistered: sourceWasRegistered,
    );
    _requestInputBudgetPhases.add(phase);
    return phase;
  }

  void _requireRequestInputBudgetPhase(_RequestInputBudgetPhase phase) {
    if (_disposed ||
        phase.invalidated ||
        !_requestInputBudgetPhases.contains(phase)) {
      throw StateError('ACP request input phase is no longer active.');
    }
    final sourceSessionId = phase.sourceSessionId;
    if (sourceSessionId != null &&
        (_isSessionClosing(sourceSessionId) ||
            (phase.sourceWasRegistered &&
                !_sessionWorkspaceRoots.containsKey(sourceSessionId)))) {
      throw StateError('ACP request source session is no longer active.');
    }
  }

  void _endRequestInputBudgetPhase(_RequestInputBudgetPhase phase) {
    phase.invalidated = true;
    _requestInputBudgetPhases.remove(phase);
  }

  void _invalidateRequestInputBudgetPhasesForSource(String sessionId) {
    for (final phase in _requestInputBudgetPhases) {
      if (phase.sourceSessionId == sessionId) phase.invalidated = true;
    }
  }

  void _invalidateAllRequestInputBudgetPhases() {
    for (final phase in _requestInputBudgetPhases) {
      phase.invalidated = true;
    }
    _requestInputBudgetPhases.clear();
  }

  bool _ownsInputBudgetPhase(AcpSessionInputBudgetOwner owner) {
    if (_disposed || _isSessionClosing(owner.sessionId)) return false;
    final phase = _inputBudgetPhases[owner.sessionId];
    return phase != null && !phase.invalidated && identical(phase.owner, owner);
  }

  void _requireInputBudgetPhase(AcpSessionInputBudgetOwner owner) {
    if (!_ownsInputBudgetPhase(owner)) {
      throw StateError('ACP session input phase is no longer active.');
    }
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
    final normalizedRoot = workspaceRoot.trim();
    final normalizedDirectories = _normalizedDirectories(additionalDirectories);
    final existingRoot = _sessionWorkspaceRoots[sessionId];
    final existingDirectories = _sessionAdditionalDirectories[sessionId];
    if (existingRoot != null) {
      if (existingRoot != normalizedRoot ||
          !_sameDirectories(existingDirectories, normalizedDirectories)) {
        throw StateError(
          'Session $sessionId is already bound to a different workspace',
        );
      }
      return;
    }
    _sessionWorkspaceRoots[sessionId] = normalizedRoot;
    _sessionAdditionalDirectories[sessionId] = normalizedDirectories;
  }

  bool _sameDirectories(List<String>? left, List<String> right) {
    if (left == null || left.length != right.length) return false;
    return left.toSet().containsAll(right);
  }

  Future<T> _runSessionSetup<T>({
    required String sessionId,
    required String workspaceRoot,
    required List<String> additionalDirectories,
    required Future<T> Function(_SessionInputBudgetPhase phase) action,
    void Function(T result)? commit,
  }) {
    if (_isSessionClosing(sessionId)) {
      return Future<T>.error(StateError('Session is closing or closed.'));
    }
    return _runSerializedSessionMutation(sessionId, () async {
      if (_isSessionClosing(sessionId)) {
        throw StateError('Session is closing or closed.');
      }
      final phaseOwner = _beginInputBudgetPhase(sessionId);
      final hadStream = _sessionStreams.containsKey(sessionId);
      final hadReplay = _replayBuffers.containsKey(sessionId);
      final hadBinding = _sessionWorkspaceRoots.containsKey(sessionId);
      final hadModes = _sessionModes.containsKey(sessionId);
      final hadToolCalls = _toolCalls.containsKey(sessionId);
      _sessionStreams.putIfAbsent(
        sessionId,
        StreamController<AcpUpdate>.broadcast,
      );
      _replayBuffers.putIfAbsent(sessionId, _newReplayBuffer);
      try {
        _setSessionWorkspace(
          sessionId,
          workspaceRoot,
          additionalDirectories: additionalDirectories,
        );
        final phase = _inputBudgetPhases[sessionId];
        if (phase == null || !identical(phase.owner, phaseOwner)) {
          throw StateError('ACP session input phase is no longer active.');
        }
        final result = await action(phase);
        _requireInputBudgetPhase(phaseOwner);
        commit?.call(result);
        return result;
      } catch (_) {
        if (!hadBinding) {
          _sessionWorkspaceRoots.remove(sessionId);
          _sessionAdditionalDirectories.remove(sessionId);
          if (!hadReplay) {
            _replayBuffers.remove(sessionId);
          }
          if (!hadModes) {
            _sessionModes.remove(sessionId);
          }
          if (!hadToolCalls) {
            _removeToolCalls(sessionId);
          }
          if (!hadStream) {
            _closeControllerWithoutWaiting(_sessionStreams.remove(sessionId));
          }
        }
        rethrow;
      } finally {
        endPromptTurn(phaseOwner);
      }
    });
  }

  Future<_GeneratedSessionRegistration> _registerGeneratedSession({
    required String sessionId,
    required String workspaceRoot,
    required List<String> additionalDirectories,
    ({String? currentModeId, List<({String id, String name})> availableModes})?
    modes,
    _RequestInputBudgetPhase? requestPhase,
  }) {
    if (_disposed) {
      return Future<_GeneratedSessionRegistration>.error(
        StateError('Session manager is disposed.'),
      );
    }
    return _runSerializedSessionMutation(sessionId, () async {
      if (_disposed) throw StateError('Session manager is disposed.');
      if (requestPhase != null) {
        _requireRequestInputBudgetPhase(requestPhase);
      }
      if (_isSessionClosing(sessionId)) {
        throw StateError('Session is closing or closed.');
      }
      if (_hasAnySessionState(sessionId)) {
        throw StateError('Generated session id is already registered.');
      }
      final identity = Object();
      _sessionStreams[sessionId] = StreamController<AcpUpdate>.broadcast();
      _replayBuffers[sessionId] = _newReplayBuffer();
      _setSessionWorkspace(
        sessionId,
        workspaceRoot,
        additionalDirectories: additionalDirectories,
      );
      if (modes != null) _sessionModes[sessionId] = modes;
      _generatedSessionRegistrationOwners[sessionId] = identity;
      return _GeneratedSessionRegistration(sessionId, identity);
    });
  }

  void _commitGeneratedSessionRegistration(
    _GeneratedSessionRegistration registration,
  ) {
    if (identical(
      _generatedSessionRegistrationOwners[registration.sessionId],
      registration.identity,
    )) {
      _generatedSessionRegistrationOwners.remove(registration.sessionId);
    }
  }

  bool _hasAnySessionState(String sessionId) =>
      _sessionStreams.containsKey(sessionId) ||
      _replayBuffers.containsKey(sessionId) ||
      _sessionWorkspaceRoots.containsKey(sessionId) ||
      _sessionAdditionalDirectories.containsKey(sessionId) ||
      _sessionModes.containsKey(sessionId) ||
      _toolCalls.containsKey(sessionId) ||
      _toolCallSizes.containsKey(sessionId) ||
      _inputBudgetPhases.containsKey(sessionId) ||
      _cancelledPromptOwners.containsKey(sessionId) ||
      _sessionClosingOwners.containsKey(sessionId) ||
      _terminalSessions.containsValue(sessionId) ||
      _generatedSessionRegistrationOwners.containsKey(sessionId);

  void _commitSessionResultModes(String sessionId, SessionResult result) {
    final modes = result.modes;
    if (modes != null) _sessionModes[sessionId] = modes;
  }

  Future<void> _drainGeneratedSessionUpdates(String sessionId) async {
    final owner = _beginInputBudgetPhase(sessionId);
    try {
      await Future<void>.delayed(Duration.zero);
      _requireInputBudgetPhase(owner);
    } finally {
      endPromptTurn(owner);
    }
  }

  Future<void> _rollbackGeneratedSession(
    _GeneratedSessionRegistration registration,
  ) async {
    final sessionId = registration.sessionId;
    if (!identical(
      _generatedSessionRegistrationOwners[sessionId],
      registration.identity,
    )) {
      return;
    }
    _generatedSessionRegistrationOwners.remove(sessionId);
    _invalidateInputBudgetPhase(sessionId);
    _cancelledPromptOwners.remove(sessionId);
    _closeControllerWithoutWaiting(_sessionStreams.remove(sessionId));
    _replayBuffers.remove(sessionId);
    _sessionWorkspaceRoots.remove(sessionId);
    _sessionAdditionalDirectories.remove(sessionId);
    _sessionModes.remove(sessionId);
    _removeToolCalls(sessionId);
    await _releaseSessionTerminals(sessionId);
  }

  Future<T> _runSerializedSessionMutation<T>(
    String sessionId,
    Future<T> Function() action,
  ) async {
    final previousSetup = _sessionSetupTails[sessionId];
    final completion = Completer<void>();
    final tail = completion.future;
    _sessionSetupTails[sessionId] = tail;
    if (previousSetup != null) await previousSetup;

    try {
      return await action();
    } finally {
      completion.complete();
      if (identical(_sessionSetupTails[sessionId], tail)) {
        _sessionSetupTails.remove(sessionId);
      }
    }
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
    final buffer = _replayBuffers[sessionId]?.updates ?? const <AcpUpdate>[];
    for (final u in buffer) {
      yield u;
    }
    yield* _sessionStreams
        .putIfAbsent(sessionId, StreamController<AcpUpdate>.broadcast)
        .stream;
  }

  void _recordReplay(
    String sessionId,
    AcpUpdate update, {
    required int sizeBytes,
  }) {
    _replayBuffers[sessionId]?.add(update, sizeBytes: sizeBytes);
  }

  bool _storeToolCall(String sessionId, String toolCallId, ToolCall toolCall) {
    final size = AcpRetainedSizeEstimator(
      budget: inputBudget,
    ).estimate(_toolCallRetainedProjection(toolCall));
    final existingCalls = _toolCalls[sessionId];
    final existingSizes = _toolCallSizes[sessionId];
    final previous = existingCalls?[toolCallId];
    final previousSize = existingSizes?[toolCallId] ?? 0;
    var nextItemCount = _toolCallItemCount - (previous == null ? 0 : 1) + 1;
    var nextByteCount = _toolCallByteCount - previousSize + size;
    final evictions = <({String sessionId, String toolCallId, int size})>[];
    if (nextItemCount > maxToolCallItems || nextByteCount > maxToolCallBytes) {
      for (final sessionEntry in _toolCalls.entries) {
        for (final callEntry in sessionEntry.value.entries) {
          if (sessionEntry.key == sessionId && callEntry.key == toolCallId) {
            continue;
          }
          if (callEntry.value.status != ToolCallStatus.completed) continue;
          final completedSize =
              _toolCallSizes[sessionEntry.key]?[callEntry.key] ?? 0;
          evictions.add((
            sessionId: sessionEntry.key,
            toolCallId: callEntry.key,
            size: completedSize,
          ));
          nextItemCount -= 1;
          nextByteCount -= completedSize;
          if (nextItemCount <= maxToolCallItems &&
              nextByteCount <= maxToolCallBytes) {
            break;
          }
        }
        if (nextItemCount <= maxToolCallItems &&
            nextByteCount <= maxToolCallBytes) {
          break;
        }
      }
    }

    if (nextItemCount > maxToolCallItems || nextByteCount > maxToolCallBytes) {
      if (toolCall.status != ToolCallStatus.completed) return false;
      if (previous != null) {
        existingCalls?.remove(toolCallId);
        existingSizes?.remove(toolCallId);
        _toolCallItemCount -= 1;
        _toolCallByteCount -= previousSize;
      }
      return true;
    }

    for (final eviction in evictions) {
      _toolCalls[eviction.sessionId]?.remove(eviction.toolCallId);
      _toolCallSizes[eviction.sessionId]?.remove(eviction.toolCallId);
    }
    final calls = _toolCalls.putIfAbsent(sessionId, () => {});
    final sizes = _toolCallSizes.putIfAbsent(sessionId, () => {});
    calls[toolCallId] = toolCall;
    sizes[toolCallId] = size;
    _toolCallItemCount = nextItemCount;
    _toolCallByteCount = nextByteCount;
    return true;
  }

  void _removeToolCalls(String sessionId) {
    final calls = _toolCalls.remove(sessionId);
    final sizes = _toolCallSizes.remove(sessionId);
    if (calls == null) return;
    _toolCallItemCount -= calls.length;
    if (sizes != null) {
      _toolCallByteCount -= sizes.values.fold<int>(
        0,
        (sum, size) => sum + size,
      );
    }
  }

  void _routeSessionUpdate(Object? envelope) {
    try {
      _routeSessionUpdateIsolated(envelope);
    } on Object {
      // A synchronous listener or hostile envelope must not escape the route.
    }
  }

  void _routeSessionUpdateIsolated(Object? envelope) {
    if (envelope is! Map) return;
    final json = envelope;
    final String sessionId;
    try {
      final rawSessionId = json['sessionId'] ?? json['session_id'];
      if (rawSessionId is! String) return;
      sessionId = rawSessionId.trim();
    } on Object {
      return;
    }
    if (sessionId.isEmpty ||
        _disposed ||
        _isSessionClosing(sessionId) ||
        !_sessionWorkspaceRoots.containsKey(sessionId)) {
      return;
    }
    final phase = _inputBudgetPhases[sessionId];
    if (phase == null || phase.invalidated) return;
    final stream = _sessionStreams[sessionId];
    final replay = _replayBuffers[sessionId];
    if (stream == null || replay == null) return;

    try {
      final rawUpdate = json['update'];
      if (rawUpdate is! Map<String, dynamic>) return;
      final update = _parseSessionUpdate(
        sessionId: sessionId,
        raw: rawUpdate,
        phase: phase,
      );
      if (!_ownsInputBudgetPhase(phase.owner)) return;
      final consumed = _consumePhaseUpdate(sessionId, phase, update);
      final bounded = consumed.update;
      if (!_ownsInputBudgetPhase(phase.owner)) return;
      if (bounded is ModeUpdate && bounded.omission == null) {
        final existing = _sessionModes[sessionId];
        _sessionModes[sessionId] = (
          currentModeId: bounded.currentModeId,
          availableModes:
              existing?.availableModes ?? const <({String id, String name})>[],
        );
      }
      _recordReplay(sessionId, bounded, sizeBytes: consumed.retainedBytes);
      stream.add(bounded);
    } on AcpInputLimitExceeded catch (error) {
      if (!_ownsInputBudgetPhase(phase.owner)) return;
      _log.warning('session update rejected');
      final normalized = _normalizedSessionUpdateLimit(error);
      if (normalized != null) {
        stream.addError(normalized);
      } else {
        stream.addError(const FormatException('Invalid ACP session update.'));
      }
    } on SessionToolStateLimitException {
      if (!_ownsInputBudgetPhase(phase.owner)) return;
      _log.warning('session update rejected');
      stream.addError(
        SessionToolStateLimitException(
          maxItems: maxToolCallItems,
          maxBytes: maxToolCallBytes,
        ),
      );
    } on Object {
      if (!_ownsInputBudgetPhase(phase.owner)) return;
      _log.warning('session update rejected');
      stream.addError(const FormatException('Invalid ACP session update.'));
    }
  }

  AcpInputLimitExceeded? _normalizedSessionUpdateLimit(
    AcpInputLimitExceeded error,
  ) {
    final resource = error.resource;
    final String normalizedResource;
    final int normalizedLimit;
    if (resource == 'turn items') {
      normalizedResource = 'turn items';
      normalizedLimit = inputBudget.maxTurnItems;
    } else if (resource == 'turn retained bytes') {
      normalizedResource = 'turn retained bytes';
      normalizedLimit = inputBudget.maxTurnRetainedBytes;
    } else if (resource == 'image_data' ||
        resource == 'audio_data' ||
        resource == 'resource_blob' ||
        resource == 'turn_media') {
      normalizedResource = 'session media input';
      normalizedLimit = inputBudget.maxEmbeddedMediaBytes;
    } else if (resource.startsWith('session input phase ')) {
      normalizedResource = 'session structured input';
      normalizedLimit = inputBudget.maxStructuredUpdateNodes;
    } else if (resource.startsWith('ACP retained state ')) {
      normalizedResource = 'session retained state';
      normalizedLimit = inputBudget.maxMetadataNodes;
    } else {
      return null;
    }
    return AcpInputLimitExceeded(
      resource: normalizedResource,
      limit: normalizedLimit,
      observedAtLeast: normalizedLimit + 1,
    );
  }

  AcpUpdate _parseSessionUpdate({
    required String sessionId,
    required Map<String, dynamic> raw,
    required _SessionInputBudgetPhase phase,
  }) {
    final rawKind = raw['sessionUpdate'];
    final kind = phase.structuredGuard.copyString(
      rawKind,
      field: 'session update kind',
    );
    if (kind == 'available_commands_update') {
      final rawCommands = raw['availableCommands'];
      final List<Object?> commands = rawCommands is List
          ? rawCommands
          : <Object?>[rawCommands];
      return AvailableCommandsUpdate.fromRaw(
        commands,
        inputBudget: inputBudget,
        structuredGuard: phase.structuredGuard,
      );
    }
    if (kind == 'plan') {
      return PlanUpdate.fromJson(
        raw,
        inputBudget: inputBudget,
        structuredGuard: phase.structuredGuard,
      );
    }
    if (kind == 'tool_call' || kind == 'tool_call_update') {
      return ToolCallUpdate(
        ToolCall.fromUpdateJson(
          raw,
          lookupExisting: (toolCallId) => _toolCalls[sessionId]?[toolCallId],
          inputBudget: inputBudget,
          structuredGuard: phase.structuredGuard,
        ),
      );
    }
    if (kind == 'user_message_chunk' ||
        kind == 'agent_message_chunk' ||
        kind == 'agent_thought_chunk') {
      final rawContent = raw['content'];
      final List<Object?> blocks = rawContent is List
          ? rawContent
          : <Object?>[rawContent];
      return MessageDelta.fromRaw(
        role: kind == 'user_message_chunk' ? 'user' : 'assistant',
        rawContent: blocks,
        isThought: kind == 'agent_thought_chunk',
        inputBudget: inputBudget,
        structuredGuard: phase.structuredGuard,
      );
    }
    if (kind == 'diff') {
      return DiffUpdate.fromJson(
        raw,
        inputBudget: inputBudget,
        structuredGuard: phase.structuredGuard,
      );
    }
    if (kind == 'current_mode_update') {
      return ModeUpdate.fromJson(
        raw,
        inputBudget: inputBudget,
        structuredGuard: phase.structuredGuard,
      );
    }
    if (kind == 'usage_update') {
      return UsageUpdate.fromJson(
        raw,
        inputBudget: inputBudget,
        structuredGuard: phase.structuredGuard,
      );
    }
    final parsed = UnknownUpdate.fromJson(
      raw,
      inputBudget: inputBudget,
      structuredGuard: phase.structuredGuard,
    );
    return UnknownUpdate(
      Map<String, dynamic>.unmodifiable(<String, dynamic>{
        'sessionId': sessionId,
        'update': parsed.raw,
      }),
      omission: parsed.omission,
    );
  }

  ({AcpUpdate update, int retainedBytes}) _consumePhaseUpdate(
    String sessionId,
    _SessionInputBudgetPhase phase,
    AcpUpdate update,
  ) {
    final textCheckpoint = phase.text.checkpoint();
    final thoughtCheckpoint = phase.thought.checkpoint();
    final mediaBytes = phase.mediaBytes;
    late ({AcpUpdate update, int retainedBytes}) consumed;
    try {
      if (phase.items >= inputBudget.maxTurnItems) {
        throw AcpInputLimitExceeded(
          resource: 'turn items',
          limit: inputBudget.maxTurnItems,
          observedAtLeast: inputBudget.maxTurnItems + 1,
        );
      }
      final bounded = update is MessageDelta
          ? _applyMessagePhaseBudgets(phase, update)
          : update;
      final retainedBytes = _retainedUpdateSize(bounded);
      if (retainedBytes >
          inputBudget.maxTurnRetainedBytes - phase.retainedBytes) {
        throw AcpInputLimitExceeded(
          resource: 'turn retained bytes',
          limit: inputBudget.maxTurnRetainedBytes,
          observedAtLeast: inputBudget.maxTurnRetainedBytes + 1,
        );
      }
      if (bounded is ToolCallUpdate &&
          !_storeToolCall(
            sessionId,
            bounded.toolCall.toolCallId,
            bounded.toolCall,
          )) {
        throw SessionToolStateLimitException(
          maxItems: maxToolCallItems,
          maxBytes: maxToolCallBytes,
        );
      }
      phase.items += 1;
      phase.retainedBytes += retainedBytes;
      consumed = (update: bounded, retainedBytes: retainedBytes);
    } catch (_) {
      phase.text.rollback(textCheckpoint);
      phase.thought.rollback(thoughtCheckpoint);
      phase.mediaBytes = mediaBytes;
      rethrow;
    }
    phase.text.commit(textCheckpoint);
    phase.thought.commit(thoughtCheckpoint);
    return consumed;
  }

  void _consumePhaseSessionResult(
    _SessionInputBudgetPhase phase,
    SessionResult result,
  ) {
    if (result.configOptions == null &&
        result.meta == null &&
        result.modes == null &&
        result.omissions.isEmpty) {
      return;
    }
    if (phase.items >= inputBudget.maxTurnItems) {
      throw AcpInputLimitExceeded(
        resource: 'turn items',
        limit: inputBudget.maxTurnItems,
        observedAtLeast: inputBudget.maxTurnItems + 1,
      );
    }
    final modes = result.modes;
    final projection = <String, Object?>{
      if (result.configOptions != null)
        'configOptions': result.configOptions!
            .map((option) => option.toJson())
            .toList(),
      if (result.meta != null) 'meta': result.meta,
      if (modes != null)
        'modes': <String, Object?>{
          if (modes.currentModeId != null) 'currentModeId': modes.currentModeId,
          'availableModes': modes.availableModes
              .map(
                (mode) => <String, Object?>{'id': mode.id, 'name': mode.name},
              )
              .toList(),
        },
      if (result.omissions.isNotEmpty) 'omissions': result.omissions,
    };
    final retainedBytes = AcpRetainedSizeEstimator(
      budget: inputBudget,
    ).estimate(projection);
    if (retainedBytes >
        inputBudget.maxTurnRetainedBytes - phase.retainedBytes) {
      throw AcpInputLimitExceeded(
        resource: 'turn retained bytes',
        limit: inputBudget.maxTurnRetainedBytes,
        observedAtLeast: inputBudget.maxTurnRetainedBytes + 1,
      );
    }
    phase.items += 1;
    phase.retainedBytes += retainedBytes;
  }

  MessageDelta _applyMessagePhaseBudgets(
    _SessionInputBudgetPhase phase,
    MessageDelta update,
  ) {
    final blocks = <ContentBlock>[];
    final omissions = <AcpInputOmission>[...update.omissions];
    final seen = <String>{
      for (final omission in omissions)
        '${omission.reason.name}\u0000${omission.resource}',
    };

    void addOmission(AcpInputOmission? omission) {
      if (omission == null) return;
      final key = '${omission.reason.name}\u0000${omission.resource}';
      if (seen.add(key)) omissions.add(omission);
    }

    for (final block in update.content) {
      if (block is TextContent) {
        final counter = update.isThought ? phase.thought : phase.text;
        final chunk = counter.append(block.text);
        final omission = chunk.omission ?? block.omission;
        blocks.add(TextContent(text: chunk.safePrefix, omission: omission));
        addOmission(omission);
        continue;
      }
      if (block is ResourceContent && block.text != null) {
        final counter = update.isThought ? phase.thought : phase.text;
        final chunk = counter.append(block.text!);
        final omission = chunk.omission ?? block.omission;
        final media = _consumeEmbeddedMedia(
          phase,
          block.blob,
          resource: 'resource_blob',
        );
        if (media != null) {
          blocks.add(media);
          addOmission(media.omission);
          continue;
        }
        blocks.add(
          ResourceContent(
            uri: block.uri,
            title: block.title,
            mimeType: block.mimeType,
            text: chunk.safePrefix,
            blob: block.blob,
            size: block.size,
            embedded: block.embedded,
            omission: omission,
          ),
        );
        addOmission(omission);
        continue;
      }
      if (block is ImageContent) {
        final omitted = _consumeEmbeddedMedia(
          phase,
          block.data,
          resource: 'image_data',
        );
        blocks.add(omitted ?? block);
        addOmission(omitted?.omission);
        continue;
      }
      if (block is AudioContent && block.data != null) {
        final omitted = _consumeEmbeddedMedia(
          phase,
          block.data,
          resource: 'audio_data',
        );
        blocks.add(omitted ?? block);
        addOmission(omitted?.omission);
        continue;
      }
      if (block is ResourceContent && block.blob != null) {
        final omitted = _consumeEmbeddedMedia(
          phase,
          block.blob,
          resource: 'resource_blob',
        );
        blocks.add(omitted ?? block);
        addOmission(omitted?.omission);
        continue;
      }
      blocks.add(block);
    }
    return MessageDelta(
      role: update.role,
      content: List<ContentBlock>.unmodifiable(blocks),
      isThought: update.isThought,
      omissions: List<AcpInputOmission>.unmodifiable(omissions),
    );
  }

  UnknownContent? _consumeEmbeddedMedia(
    _SessionInputBudgetPhase phase,
    String? encoded, {
    required String resource,
  }) {
    if (encoded == null) return null;
    final scan = scanAcpBase64(
      encoded,
      maxDecodedBytes: inputBudget.maxEmbeddedMediaBytes,
      resource: resource,
    );
    if (scan.decodedBytes >
        inputBudget.maxEmbeddedMediaBytes - phase.mediaBytes) {
      return UnknownContent.omitted(
        AcpInputOmission(
          reason: AcpInputOmissionReason.inputLimit,
          resource: 'turn_media',
          truncated: false,
          limit: inputBudget.maxEmbeddedMediaBytes,
          observedAtLeast: inputBudget.maxEmbeddedMediaBytes + 1,
        ),
      );
    }
    phase.mediaBytes += scan.decodedBytes;
    return null;
  }

  int _retainedUpdateSize(AcpUpdate update) {
    final projection = _retainedUpdateProjection(update);
    return AcpRetainedSizeEstimator(
          budget: inputBudget,
        ).estimate(projection.value) +
        projection.detachedBytes;
  }

  ({Object? value, int detachedBytes}) _retainedUpdateProjection(
    AcpUpdate update,
  ) {
    if (update is MessageDelta) {
      var detachedBytes = _trustedUtf8Length(update.role);
      final contents = <Object?>[];
      for (final block in update.content) {
        if (block is TextContent) {
          detachedBytes += _trustedUtf8Length(block.text);
          contents.add(<String, Object?>{
            'type': 'text',
            'text': '',
            if (block.omission != null) 'omission': block.omission,
          });
        } else if (block is ImageContent) {
          detachedBytes += block.data.length;
          contents.add(<String, Object?>{
            'type': 'image',
            'mimeType': block.mimeType,
            'data': '',
          });
        } else if (block is AudioContent) {
          detachedBytes += block.data?.length ?? 0;
          contents.add(<String, Object?>{
            'type': 'audio',
            'mimeType': block.mimeType,
            if (block.data != null) 'data': '',
            if (block.uri != null) 'uri': block.uri,
          });
        } else if (block is ResourceContent) {
          detachedBytes += _trustedUtf8Length(block.text ?? '');
          detachedBytes += block.blob?.length ?? 0;
          contents.add(<String, Object?>{
            'type': block.embedded ? 'resource' : 'resource_link',
            'uri': block.uri,
            if (block.title != null) 'title': block.title,
            if (block.mimeType != null) 'mimeType': block.mimeType,
            if (block.text != null) 'text': '',
            if (block.blob != null) 'blob': '',
            if (block.size != null) 'size': block.size,
            if (block.omission != null) 'omission': block.omission,
          });
        } else if (block is UnknownContent) {
          contents.add(<String, Object?>{
            'data': block.data,
            if (block.omission != null) 'omission': block.omission,
          });
        }
      }
      return (
        value: <String, Object?>{
          'role': '',
          'content': contents,
          'isThought': update.isThought,
          'omissions': update.omissions,
        },
        detachedBytes: detachedBytes,
      );
    }
    final Object? value;
    if (update is PlanUpdate) {
      value = update.plan.toJson();
    } else if (update is ToolCallUpdate) {
      value = _toolCallRetainedProjection(update.toolCall);
    } else if (update is DiffUpdate) {
      value = update.diff.toJson();
    } else if (update is AvailableCommandsUpdate) {
      value = <String, Object?>{
        'commands': update.commands.map((command) => command.toJson()).toList(),
        if (update.omission != null) 'omission': update.omission,
      };
    } else if (update is ModeUpdate) {
      value = <String, Object?>{
        'currentModeId': update.currentModeId,
        if (update.omission != null) 'omission': update.omission,
      };
    } else if (update is UsageUpdate) {
      value = update.toJson();
    } else if (update is UnknownUpdate) {
      value = <String, Object?>{
        'raw': update.raw,
        if (update.omission != null) 'omission': update.omission,
      };
    } else if (update is TurnEnded) {
      value = <String, Object?>{'stopReason': update.stopReason.name};
    } else {
      value = <String, Object?>{'text': update.text};
    }
    return (value: value, detachedBytes: 0);
  }

  Map<String, Object?> _toolCallRetainedProjection(ToolCall toolCall) =>
      <String, Object?>{
        'toolCallId': toolCall.toolCallId,
        'status': toolCall.status.toWire(),
        if (toolCall.title != null) 'title': toolCall.title,
        if (toolCall.kind != null) 'kind': toolCall.kind!.toWire(),
        if (toolCall.content != null) 'content': toolCall.content,
        if (toolCall.locations != null)
          'locations': toolCall.locations!
              .map((location) => location.toJson())
              .toList(),
        if (toolCall.rawInput != null) 'rawInput': toolCall.rawInput,
        if (toolCall.rawOutput != null) 'rawOutput': toolCall.rawOutput,
        if (toolCall.omission != null) 'omission': toolCall.omission!.toJson(),
      };

  int _trustedUtf8Length(String value) {
    var bytes = 0;
    for (var index = 0; index < value.length; index += 1) {
      final codeUnit = value.codeUnitAt(index);
      if (codeUnit <= 0x7f) {
        bytes += 1;
      } else if (codeUnit <= 0x7ff) {
        bytes += 2;
      } else if (codeUnit >= 0xd800 &&
          codeUnit <= 0xdbff &&
          index + 1 < value.length) {
        final low = value.codeUnitAt(index + 1);
        if (low >= 0xdc00 && low <= 0xdfff) {
          bytes += 4;
          index += 1;
        } else {
          bytes += 3;
        }
      } else {
        bytes += 3;
      }
    }
    return bytes;
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
    final sessionId = _requireKnownSessionId(req);
    final workspaceRoot = _sessionWorkspaceRoots[sessionId]!;

    // Create a session-specific provider honoring configured access policy
    final provider = DefaultFsProvider(
      workspaceRoot: workspaceRoot,
      additionalWorkspaceRoots: _additionalDirectoriesForSession(sessionId),
      allowReadOutsideWorkspace: config.allowReadOutsideWorkspace,
      // yolo does NOT allow writes outside workspace
    );

    // Enforce permission policy for reads when provided (non-interactive
    // policy mode). Agents may or may not request permission explicitly;
    // we gate here to ensure policy is always respected.
    try {
      final additionalDirectories = _additionalDirectoriesForSession(sessionId);
      final outcome = await config.permissionProvider.request(
        PermissionOptions(
          title: 'Read file',
          rationale: 'Agent requested to read a file',
          options: const ['allow', 'deny'],
          sessionId: sessionId,
          toolName: 'read_text_file',
          toolKind: 'read',
          metadata: <String, Object?>{
            'path': req['path'],
            'workspaceRoot': workspaceRoot,
            if (additionalDirectories.isNotEmpty)
              'additionalDirectories': additionalDirectories,
          },
        ),
      );
      if (outcome.outcome != PermissionOutcome.allow) {
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
    final sessionId = _requireKnownSessionId(req);
    final workspaceRoot = _sessionWorkspaceRoots[sessionId]!;

    // Create a session-specific provider honoring configured access policy
    final provider = DefaultFsProvider(
      workspaceRoot: workspaceRoot,
      additionalWorkspaceRoots: _additionalDirectoriesForSession(sessionId),
      allowReadOutsideWorkspace: config.allowReadOutsideWorkspace,
      // yolo does NOT allow writes outside workspace
    );

    // Enforce permission policy for writes when provided.
    try {
      final additionalDirectories = _additionalDirectoriesForSession(sessionId);
      final outcome = await config.permissionProvider.request(
        PermissionOptions(
          title: 'Write file',
          rationale: 'Agent requested to write a file',
          options: const ['allow', 'deny'],
          sessionId: sessionId,
          toolName: 'write_text_file',
          toolKind: 'edit',
          metadata: <String, Object?>{
            'path': req['path'],
            'workspaceRoot': workspaceRoot,
            if (additionalDirectories.isNotEmpty)
              'additionalDirectories': additionalDirectories,
          },
        ),
      );
      if (outcome.outcome != PermissionOutcome.allow) {
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
    final reqSessionId = _requireKnownSessionId(req);
    if (_cancelledPromptOwners.containsKey(reqSessionId)) {
      return {
        'outcome': {'outcome': 'cancelled'},
      };
    }
    final options = _permissionChoicesFromRaw(req['options']);
    final toolCall = _jsonMapFromRaw(req['toolCall']);
    final toolName = _permissionToolName(toolCall);
    final toolKind = _permissionToolKind(toolCall);
    final metadata = <String, Object?>{};
    if (toolCall != null) metadata['toolCall'] = toolCall;
    final outcome = await config.permissionProvider.request(
      PermissionOptions(
        title: toolName,
        rationale: 'Requested by agent',
        options: options.map((choice) => choice.label).toList(),
        choices: options
            .map(
              (choice) => PermissionChoice(
                optionId: choice.optionId,
                name: choice.label,
                kind: choice.kind,
              ),
            )
            .toList(growable: false),
        sessionId: reqSessionId,
        toolName: toolName,
        toolKind: toolKind,
        metadata: metadata,
      ),
    );

    if (outcome.outcome == PermissionOutcome.cancelled) {
      return {
        'outcome': {'outcome': 'cancelled'},
      };
    }

    final optionId = _permissionOptionIdForDecision(options, outcome);
    if (optionId == null) {
      return {
        'outcome': {'outcome': 'cancelled'},
      };
    }
    return {
      'outcome': {'outcome': 'selected', 'optionId': optionId},
    };
  }

  String _requireKnownSessionId(Json req) {
    final sessionId = _sessionIdFromMap(req);
    if (sessionId == null) {
      throw StateError('A non-empty sessionId is required');
    }
    if (_isSessionClosing(sessionId) ||
        !_sessionWorkspaceRoots.containsKey(sessionId)) {
      throw StateError('Unknown or closed session: $sessionId');
    }
    return sessionId;
  }

  final Map<String, TerminalProcessHandle> _terminals = {};
  final Map<String, String> _terminalSessions = {};

  Future<Json> _onTerminalCreate(Json req) async {
    final provider = config.terminalProvider;
    if (provider == null) {
      throw Exception('Terminal not supported');
    }
    final sessionId = _requireKnownSessionId(req);
    final cmd = req['command'] as String;
    final args = (req['args'] as List?)?.cast<String>() ?? const [];
    final requestedCwd = req['cwd'] as String?;
    final envList = (req['env'] as List?)?.cast<Map<String, dynamic>>();
    final env = <String, String>{
      if (envList != null)
        for (final e in envList) (e['name'] as String): (e['value'] as String),
    };
    final requestedOutputByteLimit = req['outputByteLimit'];
    final requestedPositiveOutputByteLimit =
        requestedOutputByteLimit is num &&
            requestedOutputByteLimit.isFinite &&
            requestedOutputByteLimit >= 1
        ? requestedOutputByteLimit.toInt()
        : DefaultTerminalProvider.defaultOutputByteLimit;
    final outputByteLimit = requestedPositiveOutputByteLimit.clamp(
      1,
      DefaultTerminalProvider.defaultOutputByteLimit,
    );
    final workspaceRoot = getWorkspaceRoot(sessionId);
    final additionalDirectories = _additionalDirectoriesForSession(sessionId);
    final permissionMetadata = <String, Object?>{
      'command': cmd,
      'args': args,
      'workspaceRoot': workspaceRoot,
      if (additionalDirectories.isNotEmpty)
        'additionalDirectories': additionalDirectories,
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
        transientPolicyContext: <String, Object?>{
          if (env.isNotEmpty)
            'environment': Map<String, String>.unmodifiable(env),
        },
      ),
    );
    if (execOutcome.outcome != PermissionOutcome.allow) {
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
      outputByteLimit: outputByteLimit,
    );
    return _runSerializedSessionMutation(sessionId, () async {
      if (_isSessionClosing(sessionId) ||
          !_sessionWorkspaceRoots.containsKey(sessionId)) {
        try {
          await provider.release(handle);
        } on Object {
          // Rejected handles must never become managed terminal state.
        }
        throw StateError('Terminal session is closing or closed.');
      }
      _terminals[handle.terminalId] = handle;
      _terminalSessions[handle.terminalId] = sessionId;
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
    });
  }

  Future<Json> _onTerminalOutput(Json req) async {
    final provider = config.terminalProvider;
    if (provider == null) {
      return {'output': '', 'truncated': false, 'exitStatus': null};
    }
    final termId = req['terminalId'] as String;
    final handle = _terminals[termId];
    if (handle == null) {
      return {'output': '', 'truncated': false, 'exitStatus': null};
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
        truncated: handle.truncated,
        exitCode: exitCode,
      ),
    );
    return {
      'output': output,
      'truncated': handle.truncated,
      'exitStatus': exitCode == null ? null : {'exitCode': exitCode},
    };
  }

  Future<Json> _onTerminalWaitForExit(Json req) async {
    final provider = config.terminalProvider;
    if (provider == null) {
      return {
        'output': '',
        'truncated': false,
        'exitStatus': {'exitCode': 0},
      };
    }
    final termId = req['terminalId'] as String;
    final handle = _terminals[termId];
    if (handle == null) {
      return {
        'output': '',
        'truncated': false,
        'exitStatus': {'exitCode': 0},
      };
    }
    final code = await provider.waitForExit(handle);
    _terminalEvents.add(TerminalExited(terminalId: termId, code: code));
    return {
      'output': handle.currentOutput(),
      'truncated': handle.truncated,
      'exitStatus': {'exitCode': code},
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
    _terminalSessions.remove(termId);
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
    _terminalSessions.remove(terminalId);
    if (provider != null && handle != null) {
      await provider.release(handle);
    }
  }

  Future<void> _releaseSessionTerminals(String sessionId) async {
    final terminalIds = _terminalSessions.entries
        .where((entry) => entry.value == sessionId)
        .map((entry) => entry.key)
        .toList(growable: false);
    final provider = config.terminalProvider;
    final failures = <Object>[];
    for (final terminalId in terminalIds) {
      final handle = _terminals.remove(terminalId);
      _terminalSessions.remove(terminalId);
      if (provider == null || handle == null) continue;
      try {
        await provider.release(handle);
      } on Object catch (error) {
        failures.add(error);
      }
    }
    if (failures.isNotEmpty) {
      throw StateError('${failures.length} terminal release(s) failed');
    }
  }
}
