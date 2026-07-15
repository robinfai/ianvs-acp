import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:isolate';

import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';

import '../capabilities.dart';
import '../config.dart';
import '../extensions.dart';
import '../input_budget.dart';
import '../models/bounded_observation.dart';
import '../models/content_types.dart';
import '../models/session_types.dart';
import '../models/terminal_events.dart';
import '../models/tool_types.dart';
import '../models/types.dart';
import '../models/updates.dart';
import '../providers/fs_provider.dart';
import '../providers/permission_provider.dart';
import '../providers/terminal_provider.dart';
import '../rpc/inbound_gate.dart';
import '../rpc/peer.dart';
import '../security/workspace_jail.dart';

/// Alias for a JSON map used in requests/responses.
typedef Json = Map<String, dynamic>;

final class _PayloadFreeRpcException extends rpc.RpcException {
  _PayloadFreeRpcException(super.code, super.message);

  @override
  Map<String, dynamic> serialize(Object? request) {
    final rawId = request is Map ? request['id'] : null;
    final id = rawId is String || rawId is num ? rawId : null;
    return <String, dynamic>{
      'jsonrpc': '2.0',
      'error': <String, dynamic>{'code': code, 'message': message},
      'id': id,
    };
  }
}

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
  SessionCloseCleanupException(List<String> failedStages)
    : failedStages = List<String>.unmodifiable(failedStages);

  final List<String> failedStages;

  @override
  String toString() =>
      'SessionCloseCleanupException(${failedStages.join(', ')})';
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
final class AcpSessionInputBudgetOwner implements JsonRpcPromptOwner {
  const AcpSessionInputBudgetOwner._(
    this.sessionId,
    this.generation,
    this.managerIdentity,
  );

  @override
  final String sessionId;
  @override
  final int generation;
  final Object managerIdentity;
}

/// Read-only prompt lifecycle state exposed to package tests.
@visibleForTesting
final class PromptLifecycleSnapshot {
  /// Creates a prompt lifecycle snapshot.
  const PromptLifecycleSnapshot({
    required this.winner,
    required this.cancellationWinner,
    required this.hasDeliveryRight,
    required this.cleanupDeadline,
    required this.cleanupIdentity,
    required this.cleanupStarted,
  });

  /// First neutral prompt terminal, when recorded.
  final JsonRpcPromptTerminalWinner? winner;

  /// First local cancellation reason, when recorded.
  final PermissionCancellationReason? cancellationWinner;

  /// Whether a typed terminal delivery right remains present.
  final bool hasDeliveryRight;

  /// Shared cleanup deadline, when cleanup started.
  final DateTime? cleanupDeadline;

  /// Owner-scoped cleanup identity, when cleanup started.
  final AcpPromptCleanupIdentity? cleanupIdentity;

  /// Whether prompt cleanup has started.
  final bool cleanupStarted;
}

enum _PromptLifecycleState { active, settling, terminalReady, removed }

enum _PromptDeliveryRightState { pending, claimed, revoked }

final class _PromptDeliveryRight {
  _PromptDeliveryRight(this.owner, this.winner);

  final AcpSessionInputBudgetOwner owner;
  final JsonRpcPromptTerminalWinner winner;
  _PromptDeliveryRightState state = _PromptDeliveryRightState.pending;

  bool tryClaim() {
    if (state != _PromptDeliveryRightState.pending) return false;
    state = _PromptDeliveryRightState.claimed;
    return true;
  }

  void revoke() {
    if (state == _PromptDeliveryRightState.pending) {
      state = _PromptDeliveryRightState.revoked;
    }
  }
}

final class _PromptLifecycle {
  _PromptLifecycle(this.owner, this.sessionGeneration);

  final AcpSessionInputBudgetOwner owner;
  final _SessionGeneration sessionGeneration;
  JsonRpcPromptTerminalWinner? winner;
  PermissionCancellationReason? cancellationWinner;
  _PromptDeliveryRight? deliveryRight;
  _OwnerCleanupWindow? cleanupWindow;
  Future<void>? promptReaped;
  Future<void>? cleanupFuture;
  Future<void>? cancelSubmitted;
  Future<Map<String, dynamic>>? promptResult;
  AcpPromptCleanupIdentity? cleanupIdentity;
  final Completer<void> winnerRecorded = Completer<void>.sync();
  final Completer<void> rightRecorded = Completer<void>.sync();
  final Completer<void> barrierReleased = Completer<void>.sync();
  final Completer<void> claimSeen = Completer<void>.sync();
  final Completer<void> graceStarted = Completer<void>.sync();
  AcpPromptDeliveryClaim? activeDeliveryClaim;
  Completer<void>? preclaimBarrierForTesting;
  final Completer<void> preclaimReachedForTesting = Completer<void>.sync();
  final Completer<void> _admissionsSettled = Completer<void>.sync();
  _PromptLifecycleState state = _PromptLifecycleState.active;
  bool callerEnded = false;
  bool admissionsSealed = false;
  bool cleanupDone = false;
  bool deliveryPreservedByCleanupFatal = false;

  bool get settling => state != _PromptLifecycleState.active;
  bool get removed => state == _PromptLifecycleState.removed;
  Future<void> get admissionsSettled => _admissionsSettled.future;
  bool get admissionsSettledNow => _admissionsSettled.isCompleted;

  void startSettling() {
    if (state == _PromptLifecycleState.active) {
      state = _PromptLifecycleState.settling;
    }
  }

  void sealAdmissions(Set<_InboundPermissionAdmission>? admissions) {
    admissionsSealed = true;
    if ((admissions == null || admissions.isEmpty) &&
        !_admissionsSettled.isCompleted) {
      _admissionsSettled.complete();
    }
  }

  void markAdmissionRemoving({required bool isLastForOwner}) {
    if (admissionsSealed && isLastForOwner && !_admissionsSettled.isCompleted) {
      _admissionsSettled.complete();
    }
  }
}

/// Opaque claim granting one owner-bound prompt terminal delivery.
final class AcpPromptDeliveryClaim {
  const AcpPromptDeliveryClaim._({
    required this.owner,
    required this.winner,
    required Object rightIdentity,
  }) : _rightIdentity = rightIdentity;

  /// Exact prompt owner that holds the claim.
  final AcpSessionInputBudgetOwner owner;

  /// Cached terminal winner protected by the claim.
  final JsonRpcPromptTerminalWinner winner;

  final Object _rightIdentity;
}

final class _TypedPromptTurn {
  _TypedPromptTurn(this.owner, this.controller, this.onUpdatesDetached);

  final AcpSessionInputBudgetOwner owner;
  final StreamController<AcpUpdate> controller;
  final void Function() onUpdatesDetached;
  StreamSubscription<AcpUpdate>? updates;
  Future<void>? updatesCancellationFuture;
  bool terminalOnly = false;
  bool closed = false;
  Future<void>? terminalOnlyFuture;
  Completer<void>? terminalOnlyBarrierForTesting;
  final Completer<void> terminalOnlyReachedForTesting = Completer<void>.sync();

  Future<void> enterTerminalOnly() =>
      terminalOnlyFuture ??= _enterTerminalOnly();

  Future<void> cancelUpdates() =>
      updatesCancellationFuture ??= _cancelUpdates();

  Future<void> _cancelUpdates() async {
    final current = updates;
    updates = null;
    try {
      await current?.cancel();
    } on Object {
      // A shared update subscription cannot block terminal delivery cleanup.
    } finally {
      if (current != null) onUpdatesDetached();
    }
  }

  Future<void> _enterTerminalOnly() async {
    terminalOnly = true;
    final barrier = terminalOnlyBarrierForTesting;
    if (barrier != null) {
      if (!terminalOnlyReachedForTesting.isCompleted) {
        terminalOnlyReachedForTesting.complete();
      }
      await barrier.future;
    }
    await cancelUpdates();
  }
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
  const _GeneratedSessionRegistration(
    this.sessionId,
    this.identity,
    this.phaseOwner,
  );

  final String sessionId;
  final Object identity;
  final AcpSessionInputBudgetOwner phaseOwner;
}

enum _TerminalLeaseState { reserved, creating, active, released }

final class _TerminalQuotaLease {
  _TerminalQuotaLease(this.owner, this.sessionId);

  final SessionManager owner;
  final String sessionId;
  var state = _TerminalLeaseState.reserved;
  var revoked = false;

  void markCreating() {
    if (state != _TerminalLeaseState.reserved || revoked) {
      throw StateError('Terminal session is closing or closed.');
    }
    state = _TerminalLeaseState.creating;
  }

  void markActive() {
    if (state != _TerminalLeaseState.creating || revoked) {
      throw StateError('Terminal session is closing or closed.');
    }
    state = _TerminalLeaseState.active;
    owner._pendingTerminalLeases.remove(this);
  }

  void revoke() {
    if (state == _TerminalLeaseState.released) return;
    revoked = true;
    if (state == _TerminalLeaseState.reserved) release();
  }

  void release() {
    if (state == _TerminalLeaseState.released) return;
    state = _TerminalLeaseState.released;
    owner._releaseTerminalLease(this);
  }
}

final class _ManagedTerminal {
  const _ManagedTerminal({
    required this.handle,
    required this.sessionId,
    required this.lease,
  });

  final TerminalProcessHandle handle;
  final String sessionId;
  final _TerminalQuotaLease lease;
}

final class _SessionGeneration {
  _SessionGeneration(this.sessionId, this.value);

  final String sessionId;
  final int value;
  bool active = true;
}

final class _PeerEpoch {
  bool active = true;
}

final class _OwnerCleanupWindow {
  _OwnerCleanupWindow({
    required this.identity,
    required this.fatalOwner,
    required this.deadline,
  });

  final Object identity;
  AcpSessionInputBudgetOwner? fatalOwner;
  final DateTime deadline;
  final Map<Object, Future<void>> blockers =
      HashMap<Object, Future<void>>.identity();
  final Completer<void> _expiry = Completer<void>.sync();
  final Completer<void> _reaped = Completer<void>.sync();
  Timer? timer;
  void Function()? expireForTesting;
  bool expirySignalled = false;
  bool fatalCloseStarted = false;
  bool finished = false;

  Future<void> get expiryFuture => _expiry.future;
  Future<void> get reaped => _reaped.future;
}

final class _PermissionProviderResult {
  const _PermissionProviderResult.value(this.value)
    : error = null,
      stackTrace = null;

  const _PermissionProviderResult.error(this.error, this.stackTrace)
    : value = null;

  final PermissionDecision? value;
  final Object? error;
  final StackTrace? stackTrace;
}

final class _UnregisteredTerminalRelease {
  Future<void>? operation;
}

final class _TerminalCreateResult {
  const _TerminalCreateResult.handle(this.handle)
    : error = null,
      stackTrace = null,
      cancellationReason = null;

  const _TerminalCreateResult.error(this.error, this.stackTrace)
    : handle = null,
      cancellationReason = null;

  const _TerminalCreateResult.cancelled(this.cancellationReason)
    : handle = null,
      error = null,
      stackTrace = null;

  final TerminalProcessHandle? handle;
  final Object? error;
  final StackTrace? stackTrace;
  final PermissionCancellationReason? cancellationReason;
}

final class _PermissionGateCancellation implements Exception {
  const _PermissionGateCancellation(this.reason);

  final PermissionCancellationReason reason;
}

/// Read-only and release-only probe for one real prompt admission.
@visibleForTesting
final class AcpPromptAdmissionProbeForTesting {
  AcpPromptAdmissionProbeForTesting._(this._state);

  final _ArmedPromptAdmissionProbeForTesting _state;

  /// Exact owner captured by the production admission path.
  AcpSessionInputBudgetOwner get owner => _state.owner;

  /// Completes after the real admission has bound the probe gates.
  Future<void> get admissionBarrierSeen => _state.admissionBarrierSeen.future;

  /// Completes immediately before the allowed provider side effect starts.
  Future<void> get sideEffectStarted => _state.sideEffectStarted.future;

  /// Completes when the real owner cleanup grace starts.
  Future<void> get graceStarted => _state.graceStarted.future;

  /// Completes after admission, reservation, and response all reap.
  Future<void> get reaped => _state.reaped.future;

  /// Releases only the real reservation-release completion gate.
  void releaseReservationOnly() => _state.releaseReservationOnly();

  /// Releases both real admission completion gates.
  void releaseCommit() => _state.releaseCommit();
}

final class _ArmedPromptAdmissionProbeForTesting {
  late final AcpSessionInputBudgetOwner owner;
  final Completer<void> admissionBarrierSeen = Completer<void>.sync();
  final Completer<void> sideEffectStarted = Completer<void>.sync();
  final Completer<void> graceStarted = Completer<void>.sync();
  final Completer<void> reservationGate = Completer<void>.sync();
  final Completer<void> responseCommitGate = Completer<void>.sync();
  final Completer<void> reaped = Completer<void>.sync();
  bool bound = false;

  void releaseReservationOnly() {
    if (!reservationGate.isCompleted) reservationGate.complete();
  }

  void releaseCommit() {
    releaseReservationOnly();
    if (!responseCommitGate.isCompleted) responseCommitGate.complete();
  }
}

final class _InboundPermissionAdmission implements InboundAdmission {
  _InboundPermissionAdmission({
    required this.manager,
    required this.method,
    required this.correlationIdentity,
    required this.sessionId,
    required this.sessionGeneration,
    required this.promptOwner,
    required this.promptLifecycle,
    required this.ownerAdmissionsSealedAtArrival,
    required this.peerEpoch,
  }) {
    unawaited(
      _localResult.future.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {},
      ),
    );
    deadlineTimer = Timer(manager.config.timeouts.permission, () {
      tryCancel(PermissionCancellationReason.timedOut);
    });
  }

  final SessionManager manager;
  final String method;
  final Object correlationIdentity;
  final String? sessionId;
  final _SessionGeneration? sessionGeneration;
  final AcpSessionInputBudgetOwner? promptOwner;
  final _PromptLifecycle? promptLifecycle;
  final bool ownerAdmissionsSealedAtArrival;
  final _PeerEpoch peerEpoch;
  final Object cancellationToken = Object();
  final Completer<InboundGateTerminal<dynamic>> _terminal =
      Completer<InboundGateTerminal<dynamic>>.sync();
  final Completer<PermissionCancellationReason> _cancellation =
      Completer<PermissionCancellationReason>.sync();
  final Completer<dynamic> _localResult = Completer<dynamic>.sync();
  final Completer<void> _settled = Completer<void>.sync();
  InboundGateTerminal<dynamic>? _claimedOutcome;
  StackTrace? _claimedStackTrace;
  PermissionCancellationReason? terminalReason;
  Timer? deadlineTimer;
  bool providerStarted = false;
  bool providerCancellationSent = false;
  bool localSettled = false;
  bool localPublished = false;
  bool reservationReleased = false;
  bool responseFinished = false;
  bool peerClosed = false;
  bool settledCompleted = false;
  Future<void> _reservationReleaseTestingGate = Future<void>.value();
  Future<void> _responseCommitTestingGate = Future<void>.value();
  final Completer<void> _reservationReleasedForTesting = Completer<void>.sync();
  final Completer<void> _responseCommittedForTesting = Completer<void>.sync();

  @override
  Future<InboundGateTerminal<dynamic>> get terminal => _terminal.future;

  @override
  Future<void> get settled => _settled.future;

  Future<void> get reservationReleasedForTesting =>
      _reservationReleasedForTesting.future;

  Future<void> get responseCommittedForTesting =>
      _responseCommittedForTesting.future;

  void installTestingGates({
    required Future<void> reservationRelease,
    required Future<void> responseCommit,
  }) {
    if (reservationReleased || responseFinished) {
      throw StateError(
        'Admission testing gates must be installed before release.',
      );
    }
    _reservationReleaseTestingGate = reservationRelease;
    _responseCommitTestingGate = responseCommit;
  }

  Future<void> waitForReservationReleaseForTesting(Future<void> released) =>
      released.then<void>(
        (_) => _reservationReleaseTestingGate,
        onError: (_, _) => _reservationReleaseTestingGate,
      );

  Future<void> waitForResponseCommitForTesting(Future<void> committed) =>
      committed.then<void>(
        (_) => _responseCommitTestingGate,
        onError: (_, _) => _responseCommitTestingGate,
      );

  void markReservationReleasedForTesting() {
    if (!_reservationReleasedForTesting.isCompleted) {
      _reservationReleasedForTesting.complete();
    }
  }

  void markResponseCommittedForTesting() {
    if (!_responseCommittedForTesting.isCompleted) {
      _responseCommittedForTesting.complete();
    }
  }

  Future<PermissionCancellationReason> get cancellation => _cancellation.future;

  bool tryCompleteLocal(
    InboundGateTerminal<dynamic> outcome, {
    StackTrace? stackTrace,
    PermissionCancellationReason? cancellationReason,
  }) {
    if (!tryClaimLocal(
      outcome,
      stackTrace: stackTrace,
      cancellationReason: cancellationReason,
    )) {
      return false;
    }
    publishClaimedLocal();
    return true;
  }

  bool tryClaimLocal(
    InboundGateTerminal<dynamic> outcome, {
    StackTrace? stackTrace,
    PermissionCancellationReason? cancellationReason,
  }) {
    if (localSettled) return false;
    localSettled = true;
    terminalReason = cancellationReason;
    deadlineTimer?.cancel();
    _claimedOutcome = outcome;
    _claimedStackTrace = stackTrace;
    return true;
  }

  bool publishClaimedLocal() {
    if (!localSettled || localPublished) return false;
    localPublished = true;
    final outcome = _claimedOutcome!;
    if (!_terminal.isCompleted) _terminal.complete(outcome);
    switch (outcome) {
      case InboundGateTerminalValue<dynamic>(:final value):
        _localResult.complete(value);
      case InboundGateTerminalError<dynamic>(
        :final error,
        stackTrace: final outcomeStackTrace,
      ):
        _localResult.completeError(
          error,
          _claimedStackTrace ?? outcomeStackTrace ?? StackTrace.current,
        );
    }
    if (terminalReason case final reason?) {
      if (!_cancellation.isCompleted) _cancellation.complete(reason);
      manager._notifyPermissionProviderCancellation(this, reason);
    }
    tryCompleteSettled();
    return true;
  }

  void publishClaimedLocalError(Object error, StackTrace stackTrace) {
    if (!localSettled || localPublished) return;
    terminalReason = null;
    _claimedOutcome = InboundGateTerminalError<dynamic>(error, stackTrace);
    _claimedStackTrace = stackTrace;
    publishClaimedLocal();
  }

  bool tryCancel(PermissionCancellationReason reason) => tryCompleteLocal(
    manager._permissionGateTerminal(method, reason),
    cancellationReason: reason,
  );

  @override
  Future<dynamic> runLocalOperation(FutureOr<dynamic> Function() operation) {
    Future<dynamic>.sync(operation).then<void>(
      (value) {
        tryCompleteLocal(InboundGateTerminalValue<dynamic>(value));
      },
      onError: (Object error, StackTrace stackTrace) {
        tryCompleteLocal(
          InboundGateTerminalError<dynamic>(error, stackTrace),
          stackTrace: stackTrace,
        );
      },
    );
    return _localResult.future;
  }

  @override
  void bindReservationReleased(Future<void> released) {
    void finish() {
      if (reservationReleased) return;
      reservationReleased = true;
      markReservationReleasedForTesting();
      manager._onAdmissionReservationReleased(this);
      tryCompleteSettled();
    }

    waitForReservationReleaseForTesting(
      released,
    ).then<void>((_) => finish(), onError: (_, _) => finish());
  }

  @override
  void bindResponseCommitted(Future<void> committed) {
    void finish() {
      if (responseFinished) return;
      responseFinished = true;
      markResponseCommittedForTesting();
      manager._onAdmissionResponseFinished(this);
      tryCompleteSettled();
    }

    waitForResponseCommitForTesting(
      committed,
    ).then<void>((_) => finish(), onError: (_, _) => finish());
  }

  @override
  void markPeerClosed() {
    if (peerClosed) return;
    peerClosed = true;
    responseFinished = true;
    markResponseCommittedForTesting();
    deadlineTimer?.cancel();
    tryCancel(PermissionCancellationReason.connectionClosed);
    manager._onAdmissionResponseFinished(this);
    tryCompleteSettled();
  }

  void tryCompleteSettled() {
    if (settledCompleted ||
        !localSettled ||
        !localPublished ||
        !reservationReleased ||
        !responseFinished) {
      return;
    }
    settledCompleted = true;
    deadlineTimer?.cancel();
    manager._removeInboundAdmission(this);
    _settled.complete();
  }
}

/// Orchestrates ACP lifecycle and routes updates/tool/terminal handlers.
class SessionManager implements AcpBoundedObservationSource {
  /// Create a [SessionManager] with [config] and [peer].
  SessionManager({
    required this.config,
    required this.peer,
    this.maxReplayItems = 2048,
    this.maxReplayBytes = 16 * 1024 * 1024,
    this.maxToolCallItems = 512,
    this.maxToolCallBytes = 8 * 1024 * 1024,
    this.inputBudget = const AcpInputBudget(),
    this.maxTerminalHandles = defaultMaxTerminalHandles,
    this.maxTerminalHandlesPerSession = defaultMaxTerminalHandlesPerSession,
  }) : assert(maxReplayItems > 0),
       assert(maxReplayBytes > 0),
       assert(maxToolCallItems > 0),
       assert(maxToolCallBytes > 0),
       _log = config.logger {
    validateTerminalHandleLimits(
      maxTerminalHandles: maxTerminalHandles,
      maxTerminalHandlesPerSession: maxTerminalHandlesPerSession,
    );
    inputBudget.validate();
    if (maxReplayBytes < minimumSessionReplayBytes) {
      throw ArgumentError.value(
        maxReplayBytes,
        'maxReplayBytes',
        'must be at least $minimumSessionReplayBytes bytes',
      );
    }
    _boundedObservationListeners = <AcpBoundedObservationListener>{};
    peer.onInboundAdmission = _admitInboundPermission;
    peer.addUnavailableListener(_handlePeerUnavailable);
    // Wire client-side handlers
    peer.onReadTextFile = _onReadTextFile;
    peer.onWriteTextFile = _onWriteTextFile;
    peer.onRequestPermission = _onRequestPermission;
    peer.onTerminalCreate = _onTerminalCreate;
    peer.onTerminalOutput = _onTerminalOutput;
    peer.onTerminalWaitForExit = _onTerminalWaitForExit;
    peer.onTerminalKill = _onTerminalKill;
    peer.onTerminalRelease = _onTerminalRelease;

    peer.sessionUpdates.listen(_onPeerSessionUpdate);
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
  final int maxTerminalHandles;
  final int maxTerminalHandlesPerSession;
  late final Set<AcpBoundedObservationListener> _boundedObservationListeners;

  final Map<String, StreamController<AcpUpdate>> _sessionStreams = {};
  final Map<String, _ReplayBuffer> _replayBuffers = {};
  final Map<String, _SessionInputBudgetPhase> _inputBudgetPhases =
      <String, _SessionInputBudgetPhase>{};
  final Map<String, _PromptLifecycle> _promptLifecycles =
      <String, _PromptLifecycle>{};
  final Map<AcpSessionInputBudgetOwner, _TypedPromptTurn> _activeTypedTurns =
      HashMap<AcpSessionInputBudgetOwner, _TypedPromptTurn>.identity();
  final Map<AcpSessionInputBudgetOwner, Completer<void>>
  _promptPreclaimBarriersForTesting =
      HashMap<AcpSessionInputBudgetOwner, Completer<void>>.identity();
  final Map<AcpSessionInputBudgetOwner, _TypedPromptTurn>
  _promptTerminalOnlyBarriersForTesting =
      HashMap<AcpSessionInputBudgetOwner, _TypedPromptTurn>.identity();
  ({AcpSessionInputBudgetOwner owner, PromptLifecycleSnapshot snapshot})?
  _lastReleasedPromptLifecycleSnapshot;
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
  final Map<String, FsProvider> _sessionFsProviders = <String, FsProvider>{};
  final Map<String, Future<void>> _sessionSetupTails = {};
  final Map<String, Set<Object>> _sessionClosingOwners =
      <String, Set<Object>>{};
  final Object _managerIdentity = Object();
  final _PeerEpoch _peerEpoch = _PeerEpoch();
  var _nextSessionGeneration = 0;
  final Map<String, _SessionGeneration> _sessionGenerations =
      <String, _SessionGeneration>{};
  final Set<_InboundPermissionAdmission> _inboundAdmissions =
      HashSet<_InboundPermissionAdmission>.identity();
  _ArmedPromptAdmissionProbeForTesting? _armedPromptAdmissionProbeForTesting;
  final Map<_InboundPermissionAdmission, _ArmedPromptAdmissionProbeForTesting>
  _promptAdmissionProbesForTesting =
      HashMap<
        _InboundPermissionAdmission,
        _ArmedPromptAdmissionProbeForTesting
      >.identity();
  final Map<Object, _OwnerCleanupWindow> _ownerCleanupWindows =
      HashMap<Object, _OwnerCleanupWindow>.identity();
  final Map<
    Object,
    ({String sessionId, Object key, AcpSessionInputBudgetOwner? promptOwner})
  >
  _sessionCloseCleanupSelections =
      HashMap<
        Object,
        ({
          String sessionId,
          Object key,
          AcpSessionInputBudgetOwner? promptOwner,
        })
      >.identity();
  final Map<String, ({Object closingOwner, Object key})>
  _frozenSessionCleanupWindowSelections =
      <String, ({Object closingOwner, Object key})>{};
  var _ownerCleanupWindowStartCount = 0;
  var _ownerCleanupExpiryCallbackCount = 0;
  var _activeTypedUpdateSubscriptionCount = 0;
  final Map<Map<String, dynamic>, _InboundPermissionAdmission>
  _admissionsByParams =
      HashMap<Map<String, dynamic>, _InboundPermissionAdmission>.identity();
  final Map<AcpSessionInputBudgetOwner, Set<_InboundPermissionAdmission>>
  _admissionsByOwner =
      HashMap<
        AcpSessionInputBudgetOwner,
        Set<_InboundPermissionAdmission>
      >.identity();
  final Map<String, AcpSessionInputBudgetOwner> _settlingPromptOwners =
      <String, AcpSessionInputBudgetOwner>{};
  final Map<AcpSessionInputBudgetOwner, PermissionCancellationReason>
  _settlingPromptReasons =
      HashMap<
        AcpSessionInputBudgetOwner,
        PermissionCancellationReason
      >.identity();
  final Set<_TerminalQuotaLease> _terminalLeases = <_TerminalQuotaLease>{};
  final Set<_TerminalQuotaLease> _pendingTerminalLeases =
      <_TerminalQuotaLease>{};
  final Map<String, int> _terminalLeaseCountBySession = <String, int>{};
  final Set<Future<void>> _terminalReleaseOperations = <Future<void>>{};
  var _nextInputBudgetGeneration = 0;
  var _disposed = false;
  ({Object error, StackTrace stackTrace})?
  _nextSessionClosePrepareFailureForTesting;
  ({Object error, StackTrace stackTrace})?
  _nextSessionCloseAdmissionReapFailureForTesting;
  ({Object error, StackTrace stackTrace})?
  _nextSessionClosePromptReapFailureForTesting;
  void Function()? _lastSessionSetupRollbackCallbackForTesting;
  Completer<void>? _generatedRegistrationDrainBarrierForTesting;
  Completer<String>? _generatedRegistrationSeenForTesting;

  _ReplayBuffer _newReplayBuffer() =>
      _ReplayBuffer(maxItems: maxReplayItems, maxBytes: maxReplayBytes);

  _SessionGeneration _replaceSessionGeneration(String sessionId) {
    final previous = _sessionGenerations[sessionId];
    final replacement = _SessionGeneration(sessionId, ++_nextSessionGeneration);
    _sessionGenerations[sessionId] = replacement;
    if (previous != null) {
      previous.active = false;
      for (final admission in _inboundAdmissions.toList(growable: false)) {
        if (identical(admission.sessionGeneration, previous)) {
          admission.tryCancel(PermissionCancellationReason.sessionClosed);
        }
      }
    }
    return replacement;
  }

  void _invalidateSessionGeneration(String sessionId) {
    final current = _sessionGenerations[sessionId];
    if (current != null) current.active = false;
  }

  /// Returns the current opaque generation identity for tests.
  Object? sessionGenerationForTesting(String sessionId) =>
      _sessionGenerations[sessionId];

  /// Returns the number of active admission cleanup windows for tests.
  int get admissionCleanupWindowCountForTesting => _ownerCleanupWindows.length;

  /// Returns the number of admission cleanup windows started for tests.
  int get admissionCleanupWindowStartCountForTesting =>
      _ownerCleanupWindowStartCount;

  /// Returns the number of current cleanup expiry callbacks for tests.
  int get ownerCleanupExpiryCallbackCountForTesting =>
      _ownerCleanupExpiryCallbackCount;

  /// Returns active cleanup timers retained by current owner windows.
  int get ownerCleanupActiveTimerCountForTesting => _ownerCleanupWindows.values
      .where((window) => window.timer?.isActive ?? false)
      .length;

  /// Returns admitted requests retained by the manager.
  int get inboundAdmissionCountForTesting => _inboundAdmissions.length;

  /// Returns owner admission buckets retained by the manager.
  int get ownerAdmissionBucketCountForTesting => _admissionsByOwner.length;

  /// Returns prompt lifecycle entries retained by session.
  int get promptLifecycleCountForTesting => _promptLifecycles.length;

  /// Returns call-specific typed prompt turns retained by owner identity.
  int get activeTypedPromptTurnCountForTesting => _activeTypedTurns.length;

  /// Returns typed prompt subscriptions still attached to shared updates.
  @visibleForTesting
  int get activeTypedUpdateSubscriptionCountForTesting =>
      _activeTypedUpdateSubscriptionCount;

  /// Returns armed typed preclaim test barriers retained by owner identity.
  @visibleForTesting
  int get promptPreclaimBarrierCountForTesting =>
      _promptPreclaimBarriersForTesting.length;

  /// Returns retained terminal-only pauses installed by package tests.
  @visibleForTesting
  int get promptTerminalOnlyBarrierCountForTesting =>
      _promptTerminalOnlyBarriersForTesting.length;

  /// Returns active admission cleanup window identities for tests.
  Set<Object> get admissionCleanupWindowIdentitiesForTesting =>
      Set<Object>.unmodifiable(
        _ownerCleanupWindows.values.map((window) => window.identity),
      );

  /// Returns the cleanup window identity containing [blockerIdentity].
  Object? admissionCleanupWindowIdentityForTesting(Object blockerIdentity) {
    for (final window in _ownerCleanupWindows.values) {
      if (window.blockers.containsKey(blockerIdentity)) {
        return window.identity;
      }
    }
    return null;
  }

  /// Returns the timer callback for an active cleanup window identity.
  void Function() admissionCleanupWindowTimerCallbackForTesting(
    Object identity,
  ) => _ownerCleanupWindows.values
      .singleWhere((window) => identical(window.identity, identity))
      .expireForTesting!;

  /// Returns a probe that observes whether the window timer remains active.
  bool Function() admissionCleanupWindowTimerActiveProbeForTesting(
    Object identity,
  ) {
    final window = _ownerCleanupWindows.values.singleWhere(
      (window) => identical(window.identity, identity),
    );
    return () => window.timer?.isActive ?? false;
  }

  /// Returns the real reap future for a cleanup window identity.
  Future<void> ownerCleanupWindowReapedForTesting(Object identity) =>
      _ownerCleanupWindows.values
          .singleWhere((window) => identical(window.identity, identity))
          .reaped;

  /// Returns the absolute deadline for a cleanup window identity.
  DateTime ownerCleanupWindowDeadlineForTesting(Object identity) =>
      _ownerCleanupWindows.values
          .singleWhere((window) => identical(window.identity, identity))
          .deadline;

  /// Returns the fatal owner bound to a cleanup window identity.
  AcpSessionInputBudgetOwner? ownerCleanupWindowFatalOwnerForTesting(
    Object identity,
  ) => _ownerCleanupWindows.values
      .singleWhere((window) => identical(window.identity, identity))
      .fatalOwner;

  /// Returns the blocker count for a cleanup window identity.
  int ownerCleanupWindowBlockerCountForTesting(Object identity) =>
      _ownerCleanupWindows.values
          .singleWhere((window) => identical(window.identity, identity))
          .blockers
          .length;

  /// Returns the current session input owner for lifecycle race tests.
  AcpSessionInputBudgetOwner? sessionInputOwnerForTesting(String sessionId) =>
      _inputBudgetPhases[sessionId]?.owner;

  /// Returns the active prompt owner observed by package tests.
  @visibleForTesting
  AcpSessionInputBudgetOwner activePromptOwnerForTesting(String sessionId) =>
      _promptLifecycles[sessionId]!.owner;

  _PromptLifecycle _promptLifecycleForOwnerForTesting(
    AcpSessionInputBudgetOwner owner,
  ) {
    final lifecycle = _promptLifecycles[owner.sessionId];
    if (lifecycle == null ||
        !_isCurrentPromptLifecycle(lifecycle) ||
        !identical(lifecycle.owner, owner)) {
      throw StateError('Prompt lifecycle is no longer current.');
    }
    return lifecycle;
  }

  PromptLifecycleSnapshot _snapshotPromptLifecycle(
    _PromptLifecycle lifecycle,
  ) => PromptLifecycleSnapshot(
    winner: lifecycle.winner,
    cancellationWinner: lifecycle.cancellationWinner,
    hasDeliveryRight:
        lifecycle.deliveryRight != null &&
        lifecycle.deliveryRight!.state != _PromptDeliveryRightState.revoked,
    cleanupDeadline: lifecycle.cleanupWindow?.deadline,
    cleanupIdentity: lifecycle.cleanupIdentity,
    cleanupStarted: lifecycle.cleanupFuture != null,
  );

  /// Returns the owner-bound prompt result observed by package tests.
  @visibleForTesting
  Future<Map<String, dynamic>> promptResultForTesting(
    AcpSessionInputBudgetOwner owner,
  ) => _promptLifecycleForOwnerForTesting(owner).promptResult!;

  /// Completes when a prompt terminal winner is recorded.
  @visibleForTesting
  Future<void> promptWinnerRecordedForTesting(
    AcpSessionInputBudgetOwner owner,
  ) => _promptLifecycleForOwnerForTesting(owner).winnerRecorded.future;

  /// Completes when a prompt delivery right is recorded.
  @visibleForTesting
  Future<void> promptRightRecordedForTesting(
    AcpSessionInputBudgetOwner owner,
  ) => _promptLifecycleForOwnerForTesting(owner).rightRecorded.future;

  /// Completes after the real cleanup barrier has released.
  @visibleForTesting
  Future<void> promptBarrierReleasedForTesting(
    AcpSessionInputBudgetOwner owner,
  ) => _promptLifecycleForOwnerForTesting(owner).barrierReleased.future;

  /// Completes immediately before the existing typed delivery path runs.
  @visibleForTesting
  Future<void> promptClaimSeenForTesting(AcpSessionInputBudgetOwner owner) =>
      _promptLifecycleForOwnerForTesting(owner).claimSeen.future;

  /// Completes when the real admission response grace starts for [owner].
  @visibleForTesting
  Future<void> promptGraceStartedForTesting(AcpSessionInputBudgetOwner owner) =>
      admissionResponseGraceStartedForTesting(owner);

  /// Completes when the real admission response grace starts for [owner].
  @visibleForTesting
  Future<void> admissionResponseGraceStartedForTesting(
    AcpSessionInputBudgetOwner owner,
  ) {
    final lifecycle = _promptLifecycles[owner.sessionId];
    if (lifecycle == null || !identical(lifecycle.owner, owner)) {
      return Future<void>.error(
        StateError('ACP prompt phase owner is no longer active.'),
      );
    }
    return lifecycle.graceStarted.future;
  }

  /// Fires the real active admission response grace timer for [owner].
  @visibleForTesting
  void expireOwnerAdmissionResponseGraceForTesting(
    AcpSessionInputBudgetOwner owner,
  ) {
    final lifecycle = _promptLifecycles[owner.sessionId];
    if (lifecycle == null || !identical(lifecycle.owner, owner)) {
      throw StateError('ACP prompt phase owner is no longer active.');
    }
    final window = _ownerCleanupWindows[owner];
    if (window == null || window.finished || window.blockers.isEmpty) {
      throw StateError('ACP admission response grace is not active.');
    }
    final expire =
        window.expireForTesting ??
        (throw StateError(
          'ACP admission response grace has no timer callback.',
        ));
    expire();
  }

  /// Arms a read-only/release-only probe for the next prompt admission.
  @visibleForTesting
  AcpPromptAdmissionProbeForTesting armNextPromptAdmissionForTesting() {
    if (_armedPromptAdmissionProbeForTesting != null) {
      throw StateError('A prompt admission probe is already armed.');
    }
    final state = _ArmedPromptAdmissionProbeForTesting();
    _armedPromptAdmissionProbeForTesting = state;
    return AcpPromptAdmissionProbeForTesting._(state);
  }

  bool hasPromptDeliveryRight(AcpSessionInputBudgetOwner owner) {
    final lifecycle = _promptLifecycles[owner.sessionId];
    return lifecycle != null &&
        identical(lifecycle.owner, owner) &&
        lifecycle.deliveryRight?.state == _PromptDeliveryRightState.pending;
  }

  bool hasActivePromptDeliveryClaim(AcpSessionInputBudgetOwner owner) {
    final lifecycle = _promptLifecycles[owner.sessionId];
    return lifecycle != null &&
        identical(lifecycle.owner, owner) &&
        lifecycle.activeDeliveryClaim != null &&
        lifecycle.deliveryRight?.state == _PromptDeliveryRightState.claimed;
  }

  Future<bool> waitForPromptDeliveryBarrier(
    AcpSessionInputBudgetOwner owner,
  ) async {
    final lifecycle = _promptLifecycles[owner.sessionId];
    if (lifecycle == null || !identical(lifecycle.owner, owner)) {
      return false;
    }
    final cleanup = lifecycle.cleanupFuture;
    if (lifecycle.winner == null ||
        lifecycle.deliveryRight == null ||
        cleanup == null) {
      return false;
    }
    try {
      await cleanup;
    } on Object {
      if (lifecycle.winner == null || lifecycle.deliveryRight == null) {
        rethrow;
      }
    }
    if (!lifecycle.barrierReleased.isCompleted) {
      lifecycle.barrierReleased.complete();
    }
    return true;
  }

  AcpPromptDeliveryClaim? tryClaimPromptDeliveryRight(
    AcpSessionInputBudgetOwner owner,
  ) {
    final lifecycle = _promptLifecycles[owner.sessionId];
    final right = lifecycle?.deliveryRight;
    if (lifecycle == null ||
        !identical(lifecycle.owner, owner) ||
        lifecycle.activeDeliveryClaim != null ||
        right == null ||
        !right.tryClaim()) {
      return null;
    }
    final claim = AcpPromptDeliveryClaim._(
      owner: owner,
      winner: right.winner,
      rightIdentity: right,
    );
    lifecycle.activeDeliveryClaim = claim;
    if (!lifecycle.claimSeen.isCompleted) lifecycle.claimSeen.complete();
    return claim;
  }

  void releasePromptDeliveryRight(AcpPromptDeliveryClaim claim) {
    final lifecycle = _promptLifecycles[claim.owner.sessionId];
    final right = lifecycle?.deliveryRight;
    if (lifecycle == null ||
        !identical(lifecycle.owner, claim.owner) ||
        !identical(lifecycle.activeDeliveryClaim, claim) ||
        !identical(right, claim._rightIdentity)) {
      return;
    }
    lifecycle.activeDeliveryClaim = null;
    _releaseClaimedPromptLifecycle(lifecycle);
  }

  void _releaseClaimedPromptLifecycle(_PromptLifecycle lifecycle) {
    final current = _promptLifecycles[lifecycle.owner.sessionId];
    final right = lifecycle.deliveryRight;
    if (!identical(current, lifecycle) ||
        lifecycle.removed ||
        lifecycle.activeDeliveryClaim != null ||
        right == null ||
        right.state != _PromptDeliveryRightState.claimed) {
      return;
    }
    right.state = _PromptDeliveryRightState.revoked;
    _releasePromptLifecycle(lifecycle);
  }

  /// Pauses the existing typed delivery path at its preclaim observation point.
  @visibleForTesting
  Future<void> holdPromptPreclaimForTesting(AcpSessionInputBudgetOwner owner) {
    final lifecycle = _promptLifecycleForOwnerForTesting(owner);
    lifecycle.preclaimBarrierForTesting ??= Completer<void>.sync();
    _promptPreclaimBarriersForTesting[owner] =
        lifecycle.preclaimBarrierForTesting!;
    return lifecycle.preclaimReachedForTesting.future;
  }

  /// Releases a preclaim pause installed by [holdPromptPreclaimForTesting].
  @visibleForTesting
  void releasePromptPreclaimForTesting(AcpSessionInputBudgetOwner owner) {
    final barrier = _promptPreclaimBarriersForTesting.remove(owner);
    if (barrier != null && !barrier.isCompleted) barrier.complete();
  }

  /// Pauses a claimed typed turn before its update subscription is cancelled.
  @visibleForTesting
  Future<void> holdPromptTerminalOnlyForTesting(
    AcpSessionInputBudgetOwner owner,
  ) {
    _promptLifecycleForOwnerForTesting(owner);
    final turn = _activeTypedTurns[owner];
    if (turn == null) {
      throw StateError('Typed prompt turn is no longer active.');
    }
    turn.terminalOnlyBarrierForTesting ??= Completer<void>.sync();
    _promptTerminalOnlyBarriersForTesting[owner] = turn;
    return turn.terminalOnlyReachedForTesting.future;
  }

  /// Releases a terminal-only pause installed for a claimed typed turn.
  @visibleForTesting
  void releasePromptTerminalOnlyForTesting(AcpSessionInputBudgetOwner owner) {
    final turn = _promptTerminalOnlyBarriersForTesting.remove(owner);
    final barrier = turn?.terminalOnlyBarrierForTesting;
    if (barrier != null && !barrier.isCompleted) barrier.complete();
  }

  /// Pauses the next real generated-session registration before commit.
  @visibleForTesting
  Future<String> holdNextGeneratedRegistrationDrainForTesting() {
    if (_generatedRegistrationDrainBarrierForTesting != null) {
      throw StateError('Generated registration drain is already paused.');
    }
    _generatedRegistrationDrainBarrierForTesting = Completer<void>.sync();
    _generatedRegistrationSeenForTesting = Completer<String>.sync();
    return _generatedRegistrationSeenForTesting!.future;
  }

  /// Releases a generated-session registration pause installed by tests.
  @visibleForTesting
  void releaseGeneratedRegistrationDrainForTesting() {
    final barrier = _generatedRegistrationDrainBarrierForTesting;
    if (barrier != null && !barrier.isCompleted) barrier.complete();
  }

  /// Arms the Task 10 synchronous prepare seam without consuming it yet.
  @visibleForTesting
  void failNextSessionClosePrepareSynchronouslyForTesting(
    Object error,
    StackTrace stackTrace,
  ) {
    if (_nextSessionClosePrepareFailureForTesting != null) {
      throw StateError('Session close prepare failure is already armed.');
    }
    _nextSessionClosePrepareFailureForTesting = (
      error: error,
      stackTrace: stackTrace,
    );
  }

  /// Arms the Task 10 admission-reap seam without consuming it yet.
  @visibleForTesting
  void failNextSessionCloseAdmissionReapForTesting(
    Object error,
    StackTrace stackTrace,
  ) {
    if (_nextSessionCloseAdmissionReapFailureForTesting != null) {
      throw StateError(
        'Session close admission reap failure is already armed.',
      );
    }
    _nextSessionCloseAdmissionReapFailureForTesting = (
      error: error,
      stackTrace: stackTrace,
    );
  }

  /// Arms the Task 10 prompt-reap seam without consuming it yet.
  @visibleForTesting
  void failNextSessionClosePromptReapForTesting(
    Object error,
    StackTrace stackTrace,
  ) {
    if (_nextSessionClosePromptReapFailureForTesting != null) {
      throw StateError('Session close prompt reap failure is already armed.');
    }
    _nextSessionClosePromptReapFailureForTesting = (
      error: error,
      stackTrace: stackTrace,
    );
  }

  /// Returns whether this session retains a frozen close selection.
  @visibleForTesting
  int sessionCloseSelectionCountForTesting(String sessionId) {
    final owners = HashSet<Object>.identity();
    for (final entry in _sessionCloseCleanupSelections.entries) {
      if (entry.value.sessionId == sessionId) owners.add(entry.key);
    }
    final frozen = _frozenSessionCleanupWindowSelections[sessionId];
    if (frozen != null) owners.add(frozen.closingOwner);
    return owners.length;
  }

  /// Returns all local state buckets still retained for [sessionId].
  @visibleForTesting
  Set<String> localSessionStateKeysForTesting(String sessionId) {
    final keys = <String>{};
    if (_sessionStreams.containsKey(sessionId)) keys.add('stream');
    if (_replayBuffers.containsKey(sessionId)) keys.add('replay');
    if (_sessionWorkspaceRoots.containsKey(sessionId)) keys.add('workspace');
    if (_sessionAdditionalDirectories.containsKey(sessionId)) {
      keys.add('additionalDirectories');
    }
    if (_sessionFsProviders.containsKey(sessionId)) keys.add('provider');
    if (_sessionModes.containsKey(sessionId)) keys.add('mode');
    if (_generatedSessionRegistrationOwners.containsKey(sessionId)) {
      keys.add('registration');
    }
    if (_toolCalls.containsKey(sessionId)) keys.add('tool');
    if (_inputBudgetPhases.containsKey(sessionId)) keys.add('input');
    if (_sessionGenerations.containsKey(sessionId)) keys.add('generation');
    if (_inboundAdmissions.any((item) => item.sessionId == sessionId)) {
      keys.add('permission');
    }
    if (_terminalLeaseCountBySession.containsKey(sessionId)) {
      keys.add('terminal');
    }
    if (_frozenSessionCleanupWindowSelections.containsKey(sessionId)) {
      keys.add('frozenSessionCloseCleanupSelection');
    }
    if (_sessionCloseCleanupSelections.values.any(
      (selection) => selection.sessionId == sessionId,
    )) {
      keys.add('sessionCloseCleanupSelection');
    }
    if (_sessionClosingOwners[sessionId]?.isNotEmpty ?? false) {
      keys.add('sessionClosingOwner');
    }
    return Set<String>.unmodifiable(keys);
  }

  /// Returns retained inbound admissions for [sessionId].
  @visibleForTesting
  int pendingPermissionCountForTesting(String sessionId) =>
      _inboundAdmissions.where((item) => item.sessionId == sessionId).length;

  /// Whether a retained admission captured a prompt owner when it arrived.
  @visibleForTesting
  bool admissionHasPromptOwnerForTesting(Object admissionIdentity) =>
      _inboundAdmissions
          .singleWhere((item) => identical(item, admissionIdentity))
          .promptOwner !=
      null;

  /// Returns the exact stale-owner cleanup callback captured by the last
  /// load/resume setup turn.
  @visibleForTesting
  void Function() captureSessionSetupRollbackCallbackForTesting() =>
      _lastSessionSetupRollbackCallbackForTesting ??
      (throw StateError('No session setup rollback callback was captured.'));

  /// Returns the current scaffold prompt lifecycle snapshot.
  @visibleForTesting
  PromptLifecycleSnapshot promptLifecycleSnapshotForTesting(
    AcpSessionInputBudgetOwner owner,
  ) {
    final lifecycle = _promptLifecycles[owner.sessionId];
    if (lifecycle != null && identical(lifecycle.owner, owner)) {
      return _snapshotPromptLifecycle(lifecycle);
    }
    final released = _lastReleasedPromptLifecycleSnapshot;
    if (released != null && identical(released.owner, owner)) {
      return released.snapshot;
    }
    throw StateError('Prompt lifecycle snapshot is unavailable.');
  }

  /// Returns the actual shared cleanup-window identity for [owner].
  @visibleForTesting
  Object? promptCleanupWindowIdentityForTesting(
    AcpSessionInputBudgetOwner owner,
  ) {
    final lifecycle = _promptLifecycleForOwnerForTesting(owner);
    return admissionCleanupWindowIdentityForTesting(lifecycle);
  }

  /// Returns the actual shared cleanup-window reap Future for [owner].
  @visibleForTesting
  Future<void>? promptCleanupReapedForTesting(
    AcpSessionInputBudgetOwner owner,
  ) => _promptLifecycleForOwnerForTesting(owner).cleanupFuture;

  /// Returns the exact lifecycle admission barrier for [owner].
  @visibleForTesting
  Future<void> promptAdmissionsSettledForTesting(
    AcpSessionInputBudgetOwner owner,
  ) => _promptLifecycleForOwnerForTesting(owner).admissionsSettled;

  /// Whether the owner currently has a terminal delivery right.
  @visibleForTesting
  bool promptHasDeliveryRightForTesting(AcpSessionInputBudgetOwner owner) {
    final lifecycle = _promptLifecycles[owner.sessionId];
    return lifecycle != null &&
        identical(lifecycle.owner, owner) &&
        _isCurrentPromptLifecycle(lifecycle) &&
        lifecycle.deliveryRight != null &&
        lifecycle.deliveryRight!.state != _PromptDeliveryRightState.revoked;
  }

  /// Whether the owner still holds the current input phase.
  @visibleForTesting
  bool promptLifecycleIsCurrentForTesting(AcpSessionInputBudgetOwner owner) {
    final lifecycle = _promptLifecycles[owner.sessionId];
    return lifecycle != null &&
        identical(lifecycle.owner, owner) &&
        _isCurrentPromptLifecycle(lifecycle);
  }

  /// Returns the total number of terminal quota leases for lifecycle tests.
  int get terminalLeaseCountForTesting => _terminalLeases.length;

  /// Returns terminal leases that have not become managed handles for tests.
  int get pendingTerminalLeaseCountForTesting => _pendingTerminalLeases.length;

  /// Returns terminal handles registered in manager state for tests.
  int get managedTerminalCountForTesting => _terminals.length;

  /// Returns the number of prompt owners with an active settling reason.
  int get settlingPromptReasonCountForTesting => _settlingPromptReasons.length;

  /// Returns the number of sessions retaining a settling prompt owner.
  int get settlingPromptOwnerCountForTesting => _settlingPromptOwners.length;

  /// Settles all permission admissions frozen to [owner].
  void settlePromptAdmissions({
    required AcpSessionInputBudgetOwner owner,
    required PermissionCancellationReason reason,
  }) {
    if (!identical(owner.managerIdentity, _managerIdentity)) return;
    final owned = _admissionsByOwner[owner];
    if (owned == null) return;
    final settlingReason = _settlingPromptReasons.putIfAbsent(
      owner,
      () => reason,
    );
    _settlingPromptOwners[owner.sessionId] = owner;
    for (final admission in owned.toList(growable: false)) {
      admission.tryCancel(settlingReason);
    }
  }

  void _settleSessionAdmissionsForClose(String sessionId) {
    final admissions = _inboundAdmissions
        .where((admission) => admission.sessionId == sessionId)
        .toList(growable: false);
    for (final admission in admissions) {
      admission.tryCancel(PermissionCancellationReason.sessionClosed);
    }
  }

  PermissionCancellationReason _permissionReasonForUnavailable(
    AcpPeerUnavailableState state,
  ) => state.reason == AcpPeerUnavailableReason.disposed
      ? PermissionCancellationReason.disposed
      : PermissionCancellationReason.connectionClosed;

  bool _isPromptDeliveryClaimed(_PromptLifecycle? lifecycle) =>
      lifecycle?.deliveryRight?.state == _PromptDeliveryRightState.claimed;

  void _handlePeerUnavailable(AcpPeerUnavailableState state) {
    _markOwnerCleanupWindowsPeerUnavailable();
    if (!_peerEpoch.active) return;
    _peerEpoch.active = false;
    final permissionReason = _permissionReasonForUnavailable(state);
    for (final generation in _sessionGenerations.values) {
      generation.active = false;
    }
    for (final admission in _inboundAdmissions.toList(growable: false)) {
      admission.tryCancel(permissionReason);
      admission.markPeerClosed();
    }

    for (final entry in _activeTypedTurns.entries.toList(growable: false)) {
      final owner = entry.key;
      final turn = entry.value;
      final lifecycle = _promptLifecycles[owner.sessionId];
      if (lifecycle == null || !identical(lifecycle.owner, owner)) {
        if (!turn.closed) {
          turn.controller.addError(const AcpConnectionClosedException());
          _closeTypedPromptTurn(turn);
        }
        continue;
      }
      lifecycle.cleanupIdentity = state.cleanupIdentity;
      final right = lifecycle.deliveryRight;
      if (_isPromptDeliveryClaimed(lifecycle)) continue;
      if (turn.closed) {
        _releasePromptLifecycle(lifecycle);
        continue;
      }
      final cleanup = state.cleanupIdentity;
      final preservesWinner =
          state.reason == AcpPeerUnavailableReason.fatalTimeout &&
          cleanup != null &&
          identical(cleanup.ownerToken, lifecycle.owner) &&
          cleanup.generation == lifecycle.owner.generation &&
          lifecycle.winner != null &&
          right != null;
      if (preservesWinner) {
        lifecycle.deliveryPreservedByCleanupFatal = true;
        unawaited(turn.enterTerminalOnly());
        continue;
      }
      lifecycle.cancellationWinner ??= permissionReason;
      right?.revoke();
      turn.controller.addError(const AcpConnectionClosedException());
      _closeTypedPromptTurn(turn);
      _releasePromptLifecycle(lifecycle);
    }

    for (final lifecycle in _promptLifecycles.values.toList(growable: false)) {
      if (!_isCurrentPromptLifecycle(lifecycle) ||
          _activeTypedTurns.containsKey(lifecycle.owner)) {
        continue;
      }
      if (_isPromptDeliveryClaimed(lifecycle)) continue;
      lifecycle.cleanupIdentity = state.cleanupIdentity;
      final cleanup = state.cleanupIdentity;
      final preservesRawWinner =
          state.reason == AcpPeerUnavailableReason.fatalTimeout &&
          cleanup != null &&
          identical(cleanup.ownerToken, lifecycle.owner) &&
          cleanup.generation == lifecycle.owner.generation &&
          lifecycle.winner != null &&
          lifecycle.deliveryRight != null &&
          lifecycle.cleanupFuture != null;
      if (preservesRawWinner) continue;
      lifecycle.cancellationWinner ??= permissionReason;
      lifecycle.deliveryRight?.revoke();
      _releasePromptLifecycle(lifecycle);
    }
  }

  void _onAdmissionReservationReleased(_InboundPermissionAdmission admission) {
    if (admission.responseFinished || admission.peerClosed) return;
    _startAdmissionResponseGrace(admission);
  }

  void _onAdmissionResponseFinished(_InboundPermissionAdmission admission) {
    final key = _ownerCleanupKeyForAdmission(admission);
    final window = _ownerCleanupWindows[key];
    if (window != null) {
      _releaseOwnerCleanupBlocker(key, window, admission);
    }
  }

  void _startAdmissionResponseGrace(_InboundPermissionAdmission admission) {
    if (_disposed ||
        !admission.reservationReleased ||
        admission.responseFinished ||
        admission.peerClosed) {
      return;
    }
    final key = _ownerCleanupKeyForAdmission(admission);
    _getOrJoinOwnerCleanupWindow(
      key: key,
      fatalOwner: admission.ownerAdmissionsSealedAtArrival
          ? null
          : admission.promptOwner,
      blockerIdentity: admission,
      blockerReaped: admission.settled,
      onStarted: () {
        final lifecycle = admission.promptLifecycle;
        if (lifecycle != null && !lifecycle.graceStarted.isCompleted) {
          lifecycle.graceStarted.complete();
        }
      },
    );
  }

  Object _ownerCleanupKeyForAdmission(_InboundPermissionAdmission admission) {
    final sessionId = admission.sessionId;
    final frozen = sessionId == null
        ? null
        : _frozenSessionCleanupWindowSelections[sessionId];
    if (frozen != null) return frozen.key;
    if (admission.ownerAdmissionsSealedAtArrival) return admission;
    return admission.promptOwner ?? admission;
  }

  bool _isOwnerlessCleanupWindowForSession(
    _OwnerCleanupWindow window,
    String sessionId,
  ) =>
      window.fatalOwner == null &&
      window.blockers.keys.whereType<_InboundPermissionAdmission>().any(
        (admission) => admission.sessionId == sessionId,
      );

  void _mergeSessionCleanupWindow({
    required Object selectedKey,
    required _OwnerCleanupWindow selected,
    required Object donorKey,
    required _OwnerCleanupWindow donor,
  }) {
    if (identical(selected, donor) || donor.finished) return;
    for (final blocker in donor.blockers.entries.toList(growable: false)) {
      _joinOwnerCleanupBlocker(
        selectedKey,
        selected,
        blocker.key,
        blocker.value,
      );
    }
    donor.timer?.cancel();
    if (identical(_ownerCleanupWindows[donorKey], donor)) {
      _ownerCleanupWindows.remove(donorKey);
    }
    donor.finished = true;
    donor.blockers.clear();
    if (donor.expirySignalled && !selected.expirySignalled) {
      selected.timer?.cancel();
      selected.expirySignalled = true;
      selected._expiry.complete();
    }
    selected.fatalCloseStarted =
        selected.fatalCloseStarted || donor.fatalCloseStarted;
    selected.expiryFuture.then<void>((_) {
      if (donor.expirySignalled) return;
      donor.expirySignalled = true;
      donor._expiry.complete();
    });
    selected.reaped.then<void>((_) {
      if (!donor._reaped.isCompleted) donor._reaped.complete();
    });
  }

  Object _selectSessionCloseCleanupKey({
    required String sessionId,
    required Object closingOwner,
    required AcpSessionInputBudgetOwner? promptOwner,
  }) {
    final candidates =
        _ownerCleanupWindows.entries
            .where(
              (entry) =>
                  !entry.value.finished &&
                  ((promptOwner != null && identical(entry.key, promptOwner)) ||
                      _isOwnerlessCleanupWindowForSession(
                        entry.value,
                        sessionId,
                      )),
            )
            .toList()
          ..sort(
            (left, right) =>
                left.value.deadline.compareTo(right.value.deadline),
          );
    if (candidates.isEmpty) return promptOwner ?? closingOwner;
    final earliest = candidates.first;
    if (promptOwner != null) {
      _bindOwnerCleanupFatalOwner(earliest.key, earliest.value, promptOwner);
    }
    for (final donor in candidates.skip(1)) {
      _mergeSessionCleanupWindow(
        selectedKey: earliest.key,
        selected: earliest.value,
        donorKey: donor.key,
        donor: donor.value,
      );
    }
    if (promptOwner != null) {
      final lifecycle = _promptLifecycles[sessionId];
      if (lifecycle != null &&
          identical(lifecycle.owner, promptOwner) &&
          candidates.any(
            (candidate) => identical(candidate.value, lifecycle.cleanupWindow),
          )) {
        lifecycle.cleanupWindow = earliest.value;
      }
    }
    return earliest.key;
  }

  _OwnerCleanupWindow _getOrJoinOwnerCleanupWindow({
    required Object key,
    required AcpSessionInputBudgetOwner? fatalOwner,
    required Object blockerIdentity,
    required Future<void> blockerReaped,
    void Function()? onStarted,
  }) {
    if (_disposed) {
      throw StateError('Cannot start ACP cleanup after manager disposal.');
    }
    final existing = _ownerCleanupWindows[key];
    if (existing != null && !existing.finished) {
      if (fatalOwner != null) {
        _bindOwnerCleanupFatalOwner(key, existing, fatalOwner);
      }
      _joinOwnerCleanupBlocker(key, existing, blockerIdentity, blockerReaped);
      onStarted?.call();
      return existing;
    }

    final identity = Object();
    final deadline = DateTime.now().add(config.timeouts.promptCancelGrace);
    final window = _OwnerCleanupWindow(
      identity: identity,
      fatalOwner: fatalOwner,
      deadline: deadline,
    );
    _ownerCleanupWindows[key] = window;
    _ownerCleanupWindowStartCount += 1;
    _joinOwnerCleanupBlocker(key, window, blockerIdentity, blockerReaped);
    onStarted?.call();
    void expire() => _expireOwnerCleanupWindow(key, identity);
    window.expireForTesting = expire;
    final remaining = deadline.difference(DateTime.now());
    window.timer = Timer(
      remaining.isNegative ? Duration.zero : remaining,
      expire,
    );
    return window;
  }

  void _bindOwnerCleanupFatalOwner(
    Object key,
    _OwnerCleanupWindow window,
    AcpSessionInputBudgetOwner fatalOwner,
  ) {
    if (!identical(_ownerCleanupWindows[key], window) || window.finished) {
      throw StateError('ACP cleanup window is no longer current.');
    }
    final existing = window.fatalOwner;
    if (existing == null) {
      window.fatalOwner = fatalOwner;
      return;
    }
    if (!identical(existing, fatalOwner) ||
        existing.generation != fatalOwner.generation) {
      throw StateError('ACP cleanup window owner mismatch.');
    }
  }

  void _joinOwnerCleanupBlocker(
    Object key,
    _OwnerCleanupWindow window,
    Object blockerIdentity,
    Future<void> blockerReaped,
  ) {
    final previous = window.blockers[blockerIdentity];
    if (previous != null) {
      if (!identical(previous, blockerReaped)) {
        throw StateError('ACP cleanup blocker identity was rebound.');
      }
      return;
    }
    window.blockers[blockerIdentity] = blockerReaped;
    blockerReaped.then<void>(
      (_) => _releaseOwnerCleanupBlocker(key, window, blockerIdentity),
      onError: (Object _, StackTrace _) =>
          _releaseOwnerCleanupBlocker(key, window, blockerIdentity),
    );
  }

  void _releaseOwnerCleanupBlocker(
    Object key,
    _OwnerCleanupWindow window,
    Object blockerIdentity,
  ) {
    if (!identical(_ownerCleanupWindows[key], window) || window.finished) {
      return;
    }
    window.blockers.remove(blockerIdentity);
    if (window.blockers.isNotEmpty) return;
    _finishOwnerCleanupWindow(key, window);
  }

  void _finishOwnerCleanupWindow(Object key, _OwnerCleanupWindow window) {
    if (window.finished) return;
    window.finished = true;
    window.timer?.cancel();
    if (identical(_ownerCleanupWindows[key], window)) {
      _ownerCleanupWindows.remove(key);
    }
    if (!window.expirySignalled) {
      window.expirySignalled = true;
      window._expiry.complete();
    }
    if (!window._reaped.isCompleted) window._reaped.complete();
  }

  void _expireOwnerCleanupWindow(Object key, Object identity) {
    final window = _ownerCleanupWindows[key];
    if (window == null ||
        window.finished ||
        window.expirySignalled ||
        !identical(window.identity, identity)) {
      return;
    }
    _ownerCleanupExpiryCallbackCount += 1;
    window.timer?.cancel();
    window.expirySignalled = true;
    window._expiry.complete();
    if (window.blockers.isEmpty) {
      _finishOwnerCleanupWindow(key, window);
      return;
    }
    if (window.fatalCloseStarted) return;
    window.fatalCloseStarted = true;
    final owner = window.fatalOwner;
    try {
      final closing = peer.closeForFatalTimeout(
        cleanupIdentity: owner == null
            ? null
            : AcpPromptCleanupIdentity(owner, owner.generation),
      );
      unawaited(
        closing.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      );
    } on Object {
      // A peer implementation cannot leak synchronous cleanup failures.
    }
  }

  void _markOwnerCleanupWindowsPeerUnavailable() {
    for (final entry in _ownerCleanupWindows.entries.toList(growable: false)) {
      final window = entry.value;
      window.timer?.cancel();
      if (!window.expirySignalled) {
        window.expirySignalled = true;
        window._expiry.complete();
      }
      if (window.blockers.isEmpty) {
        _finishOwnerCleanupWindow(entry.key, window);
      }
    }
  }

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
    _handlePeerUnavailable(
      const AcpPeerUnavailableState(AcpPeerUnavailableReason.disposed),
    );
    for (final barrier in _promptPreclaimBarriersForTesting.values) {
      if (!barrier.isCompleted) barrier.complete();
    }
    _promptPreclaimBarriersForTesting.clear();
    releaseGeneratedRegistrationDrainForTesting();
    final generationsAtDispose = Map<String, _SessionGeneration>.from(
      _sessionGenerations,
    );
    for (final sessionId in generationsAtDispose.keys) {
      _invalidateSessionGeneration(sessionId);
    }
    _disposePromptAdmissionProbesForTesting();
    for (final admission in _inboundAdmissions.toList(growable: false)) {
      admission.tryCancel(PermissionCancellationReason.disposed);
    }
    try {
      _revokeTerminalLeases();
      _boundedObservationListeners.clear();
      _invalidateAllInputBudgetPhases();
      _invalidateAllRequestInputBudgetPhases();
      final terminalIds = _terminals.keys.toList(growable: false);
      var terminalReleaseFailures = 0;
      await Future.wait<void>(
        terminalIds.map((terminalId) async {
          try {
            await _releaseManagedTerminal(terminalId);
          } on Object {
            terminalReleaseFailures += 1;
          }
        }),
      );
      await _waitForTerminalReleaseOperations();
      if (terminalReleaseFailures > 0) {
        _log.warning(
          'session dispose cleanup stage terminals failed '
          '(count: $terminalReleaseFailures)',
        );
      }
      _closeControllerWithoutWaiting(_terminalEvents);
      for (final entry in _activeTypedTurns.entries.toList(growable: false)) {
        final turn = entry.value;
        final lifecycle = _promptLifecycles[entry.key.sessionId];
        if (lifecycle != null &&
            identical(lifecycle.owner, entry.key) &&
            (_isPromptDeliveryClaimed(lifecycle) ||
                lifecycle.deliveryPreservedByCleanupFatal)) {
          continue;
        }
        if (!turn.closed) {
          turn.controller.addError(const AcpConnectionClosedException());
          _closeTypedPromptTurn(turn);
        }
      }
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
      _sessionFsProviders.clear();
      _sessionModes.clear();
      _sessionSetupTails.clear();
      _sessionClosingOwners.clear();
      _generatedSessionRegistrationOwners.clear();
    } finally {
      _sessionGenerations.removeWhere(
        (sessionId, current) =>
            identical(generationsAtDispose[sessionId], current),
      );
      peer.removeUnavailableListener(_handlePeerUnavailable);
    }
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
        await _drainGeneratedSessionUpdates(registration);
        _requireRequestInputBudgetPhase(requestPhase);
        _commitGeneratedSessionRegistration(registration);
        _replaceSessionGeneration(id);
      } on Object {
        await _rollbackGeneratedSession(registration);
        rethrow;
      }
      _publishSessionResultObservation(
        operation: AcpBoundedSessionOperation.newSession,
        sessionId: id,
        result: result,
      );
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
      commit: (result) {
        _commitSessionResultModes(sessionId, result);
        _publishSessionResultObservation(
          operation: AcpBoundedSessionOperation.loadSession,
          sessionId: sessionId,
          result: result,
        );
        _replaceSessionGeneration(sessionId);
      },
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
    return SessionListResult.fromJson(resp, inputBudget: inputBudget);
  }

  /// Close a remote session, then release all state owned by that session.
  Future<void> closeSession({required String sessionId}) =>
      _runSerializedSessionMutation(sessionId, () async {
        final closingOwner = Object();
        Object? primaryError;
        StackTrace? primaryStackTrace;
        Object? cleanupError;
        StackTrace? cleanupStackTrace;
        try {
          try {
            _beginSessionClose(sessionId, closingOwner);
            await _prepareSessionClose(sessionId, closingOwner);
            if (!peer.isAvailable) {
              throw const AcpConnectionClosedException();
            }
            await peer.sendRaw('session/close', <String, dynamic>{
              'sessionId': sessionId,
            });
          } on Object catch (error, stackTrace) {
            primaryError = error;
            primaryStackTrace = stackTrace;
          }
        } finally {
          try {
            await _cleanupSessionLocally(sessionId);
          } on Object catch (error, stackTrace) {
            cleanupError = error;
            cleanupStackTrace = stackTrace;
          } finally {
            _endSessionClose(sessionId, closingOwner);
          }
        }
        if (cleanupError != null) {
          Error.throwWithStackTrace(cleanupError, cleanupStackTrace!);
        }
        if (primaryError != null) {
          Error.throwWithStackTrace(primaryError, primaryStackTrace!);
        }
      });

  void _beginSessionClose(String sessionId, Object closingOwner) {
    _invalidateSessionGeneration(sessionId);
    _invalidateInputBudgetPhase(sessionId);
    _invalidateRequestInputBudgetPhasesForSource(sessionId);
    _cancelledPromptOwners.remove(sessionId);
    _sessionClosingOwners
        .putIfAbsent(sessionId, () => <Object>{})
        .add(closingOwner);
    _revokeTerminalLeases(sessionId: sessionId);
    final lifecycle = _promptLifecycles[sessionId];
    final promptOwner =
        lifecycle != null && _isCurrentPromptLifecycle(lifecycle)
        ? lifecycle.owner
        : null;
    final cleanupKey = _selectSessionCloseCleanupKey(
      sessionId: sessionId,
      closingOwner: closingOwner,
      promptOwner: promptOwner,
    );
    if (_frozenSessionCleanupWindowSelections.containsKey(sessionId)) {
      throw StateError('Session close cleanup selection is already frozen.');
    }
    _sessionCloseCleanupSelections[closingOwner] = (
      sessionId: sessionId,
      key: cleanupKey,
      promptOwner: promptOwner,
    );
    _frozenSessionCleanupWindowSelections[sessionId] = (
      closingOwner: closingOwner,
      key: cleanupKey,
    );
  }

  void _endSessionClose(String sessionId, Object owner) {
    _sessionCloseCleanupSelections.remove(owner);
    final frozen = _frozenSessionCleanupWindowSelections[sessionId];
    if (frozen != null && identical(frozen.closingOwner, owner)) {
      _frozenSessionCleanupWindowSelections.remove(sessionId);
    }
    final owners = _sessionClosingOwners[sessionId];
    if (owners == null) return;
    owners.remove(owner);
    if (owners.isEmpty) _sessionClosingOwners.remove(sessionId);
  }

  void _throwNextSessionClosePrepareFailureForTesting() {
    final injected = _nextSessionClosePrepareFailureForTesting;
    if (injected == null) return;
    _nextSessionClosePrepareFailureForTesting = null;
    Error.throwWithStackTrace(injected.error, injected.stackTrace);
  }

  Future<void> _sessionCloseAdmissionReaped(
    _InboundPermissionAdmission admission,
  ) {
    final injected = _nextSessionCloseAdmissionReapFailureForTesting;
    if (injected == null) return admission.settled;
    _nextSessionCloseAdmissionReapFailureForTesting = null;
    return admission.settled.then<void>((_) {
      Error.throwWithStackTrace(injected.error, injected.stackTrace);
    });
  }

  Future<void> _sessionClosePromptReaped(Future<void> promptReaped) {
    final injected = _nextSessionClosePromptReapFailureForTesting;
    if (injected == null) return promptReaped;
    _nextSessionClosePromptReapFailureForTesting = null;
    return promptReaped.then<void>((_) {
      Error.throwWithStackTrace(injected.error, injected.stackTrace);
    });
  }

  Future<void> _prepareSessionClose(String sessionId, Object closingOwner) {
    final owners = _sessionClosingOwners[sessionId];
    final selection = _sessionCloseCleanupSelections[closingOwner];
    if (owners == null ||
        !owners.contains(closingOwner) ||
        selection == null ||
        selection.sessionId != sessionId) {
      return Future<void>.error(
        StateError('Session close owner is no longer current.'),
      );
    }
    _throwNextSessionClosePrepareFailureForTesting();
    final lifecycle = _promptLifecycles[sessionId];
    final currentLifecycle =
        lifecycle != null && _isCurrentPromptLifecycle(lifecycle)
        ? lifecycle
        : null;
    final admissions = _inboundAdmissions
        .where((admission) => admission.sessionId == sessionId)
        .toList(growable: false);
    _settleSessionAdmissionsForClose(sessionId);
    Future<void>? promptReaped;
    if (currentLifecycle != null) {
      currentLifecycle.callerEnded = true;
      _settlePromptLifecycle(
        currentLifecycle,
        PermissionCancellationReason.sessionClosed,
        sendCancel: true,
      );
      final source = currentLifecycle.promptReaped;
      if (source != null) promptReaped = _sessionClosePromptReaped(source);
    }
    final localReaped = Future.wait<void>(<Future<void>>[
      for (final admission in admissions)
        _sessionCloseAdmissionReaped(admission),
      ?promptReaped,
    ], eagerError: false);
    Object? reapError;
    StackTrace? reapStackTrace;
    final observedLocalReaped = localReaped.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        reapError = error;
        reapStackTrace = stackTrace;
      },
    );
    final window = _getOrJoinOwnerCleanupWindow(
      key: selection.key,
      fatalOwner: selection.promptOwner,
      blockerIdentity: closingOwner,
      blockerReaped: observedLocalReaped,
    );
    return () async {
      await Future.any<void>(<Future<void>>[
        window.expiryFuture,
        window.reaped,
      ]);
      await window.reaped;
      if (reapError != null) {
        Error.throwWithStackTrace(reapError!, reapStackTrace!);
      }
    }();
  }

  Future<void> _cleanupSessionLocally(String sessionId) async {
    final failedStages = <String>[];
    Future<void> cleanup(String stage, FutureOr<void> Function() action) async {
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
    await cleanup('workspace', () => _sessionWorkspaceRoots.remove(sessionId));
    await cleanup(
      'additionalDirectories',
      () => _sessionAdditionalDirectories.remove(sessionId),
    );
    await cleanup(
      'filesystemProvider',
      () => _sessionFsProviders.remove(sessionId),
    );
    await cleanup('modes', () => _sessionModes.remove(sessionId));
    await cleanup(
      'registration',
      () => _generatedSessionRegistrationOwners.remove(sessionId),
    );
    await cleanup('toolCalls', () => _removeToolCalls(sessionId));
    await cleanup('inputPhase', () async {
      final lifecycle = _promptLifecycles[sessionId];
      if (lifecycle != null) {
        _closeTypedPromptWithoutWinner(lifecycle);
      }
      _invalidateInputBudgetPhase(sessionId);
      _invalidateRequestInputBudgetPhasesForSource(sessionId);
      _cancelledPromptOwners.remove(sessionId);
      if (lifecycle != null) _releasePromptLifecycle(lifecycle);
      final admissions = _inboundAdmissions
          .where((admission) => admission.sessionId == sessionId)
          .toList(growable: false);
      for (final admission in admissions) {
        admission.tryCancel(PermissionCancellationReason.sessionClosed);
      }
      await Future.wait<void>(
        admissions.map((admission) => admission.settled),
        eagerError: false,
      );
    });
    await cleanup('generation', () {
      final generation = _sessionGenerations[sessionId];
      if (generation == null) return;
      generation.active = false;
      if (identical(_sessionGenerations[sessionId], generation)) {
        _sessionGenerations.remove(sessionId);
      }
    });
    await cleanup('terminals', () => _releaseSessionTerminals(sessionId));
    if (failedStages.isNotEmpty) {
      throw SessionCloseCleanupException(failedStages);
    }
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
    final result = await _runSessionSetup<SessionResult>(
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
      commit: (result) {
        _commitSessionResultModes(sessionId, result);
        _publishSessionResultObservation(
          operation: AcpBoundedSessionOperation.resumeSession,
          sessionId: sessionId,
          result: result,
        );
        _replaceSessionGeneration(sessionId);
      },
    );
    return result;
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
        await _drainGeneratedSessionUpdates(registration);
        _requireRequestInputBudgetPhase(requestPhase);
        _commitGeneratedSessionRegistration(registration);
        _replaceSessionGeneration(newId);
      } on Object {
        await _rollbackGeneratedSession(registration);
        rethrow;
      }
      _publishSessionResultObservation(
        operation: AcpBoundedSessionOperation.forkSession,
        sessionId: newId,
        result: result,
      );
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
    final guard = AcpStructuredUpdateGuard(
      budget: inputBudget,
      resource: 'session set config option result',
    );
    final result = SessionResult.fromJson(
      resp,
      inputBudget: inputBudget,
      structuredGuard: guard,
    );
    for (final omission in result.omissions) {
      if (omission.resource != 'config_options') continue;
      if (omission.reason == AcpInputOmissionReason.inputLimit) {
        throw AcpInputLimitExceeded(
          resource: 'config_options',
          limit: omission.limit!,
          observedAtLeast: omission.observedAtLeast!,
        );
      }
      throw const FormatException('Invalid ACP config options.');
    }
    final configOptions = result.configOptions;
    if (configOptions == null) {
      throw const FormatException('Missing ACP config options.');
    }
    return configOptions;
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

    late final StreamController<AcpUpdate> controller;
    _TypedPromptTurn? turn;
    controller = StreamController<AcpUpdate>(
      onListen: () {
        late final AcpSessionInputBudgetOwner owner;
        try {
          owner = beginPromptTurn(sessionId);
        } on Object catch (error, stackTrace) {
          controller.addError(error, stackTrace);
          _closeControllerWithoutWaiting(controller);
          return;
        }
        final current = _TypedPromptTurn(owner, controller, () {
          _activeTypedUpdateSubscriptionCount -= 1;
        });
        turn = current;
        current.updates = _sessionStreams[sessionId]!.stream.listen(
          (update) {
            if (!current.closed && update is! TurnEnded) {
              controller.add(update);
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            if (!current.closed) {
              controller.addError(error, stackTrace);
            }
          },
        );
        _activeTypedUpdateSubscriptionCount += 1;
        _registerTypedPromptTurn(current);
        unawaited(_runTypedPrompt(current, content));
      },
      onCancel: () async {
        final current = turn;
        if (current == null) return;
        _closeTypedPromptTurn(current);
        await current.cancelUpdates();
        try {
          await cancelPromptTurn(current.owner);
        } on StateError {
          // The exact phase already ended or was invalidated by close/dispose.
        }
      },
    );
    return controller.stream;
  }

  void _registerTypedPromptTurn(_TypedPromptTurn turn) {
    final previous = _activeTypedTurns[turn.owner];
    if (previous != null && !identical(previous, turn)) {
      throw StateError('ACP typed prompt turn is already registered.');
    }
    _activeTypedTurns[turn.owner] = turn;
  }

  Future<void> _runTypedPrompt(
    _TypedPromptTurn turn,
    List<Map<String, dynamic>> content,
  ) async {
    final lifecycle = _requireDispatchablePrompt(turn.owner);
    Object? rpcFailure;
    StackTrace? rpcFailureStack;
    try {
      try {
        await sendPromptRequest(owner: turn.owner, content: content);
      } on Object catch (error, stackTrace) {
        rpcFailure = error;
        rpcFailureStack = stackTrace;
      }
      if (lifecycle.winner == null) {
        if (!turn.closed) {
          turn.controller.addError(
            rpcFailure ?? const AcpConnectionClosedException(),
            rpcFailureStack ?? StackTrace.empty,
          );
          _closeTypedPromptTurn(turn);
        }
        return;
      }
      try {
        await lifecycle.cleanupFuture;
      } on Object {
        // A recorded winner remains deliverable after cleanup makes the peer
        // unavailable for the same owner.
      }
      if (!lifecycle.barrierReleased.isCompleted) {
        lifecycle.barrierReleased.complete();
      }
      await _deliverTypedPromptWinner(lifecycle, turn);
    } finally {
      endPromptTurn(turn.owner);
    }
  }

  Future<void> _deliverTypedPromptWinner(
    _PromptLifecycle lifecycle,
    _TypedPromptTurn turn,
  ) async {
    final preclaim = lifecycle.preclaimBarrierForTesting;
    if (preclaim != null) {
      if (!lifecycle.preclaimReachedForTesting.isCompleted) {
        lifecycle.preclaimReachedForTesting.complete();
      }
      await preclaim.future;
    }
    final right = lifecycle.deliveryRight;
    if (turn.closed) {
      right?.revoke();
      _releasePromptLifecycle(lifecycle);
      return;
    }
    final claim = tryClaimPromptDeliveryRight(lifecycle.owner);
    if (claim == null) return;
    await turn.enterTerminalOnly();
    try {
      if (turn.closed) return;
      final winner = claim.winner;
      if (winner.kind == JsonRpcPromptTerminalKind.response) {
        final terminal = TurnEnded(
          stopReasonFromWire(
            (winner.response?['stopReason'] as String?) ?? 'other',
          ),
        );
        turn.controller.add(terminal);
        if (_isSameSessionGeneration(lifecycle)) {
          _replayBuffers[lifecycle.owner.sessionId]?.add(terminal);
        }
      } else {
        turn.controller.addError(
          winner.kind == JsonRpcPromptTerminalKind.timedOut
              ? const AcpPromptTimeoutException()
              : winner.error!,
          winner.stackTrace ?? StackTrace.empty,
        );
        const terminal = TurnEnded(StopReason.other);
        turn.controller.add(terminal);
        if (_isSameSessionGeneration(lifecycle)) {
          _replayBuffers[lifecycle.owner.sessionId]?.add(terminal);
        }
      }
    } finally {
      _closeTypedPromptTurn(turn);
      releasePromptDeliveryRight(claim);
    }
  }

  bool _isSameSessionGeneration(_PromptLifecycle lifecycle) {
    final current = _sessionGenerations[lifecycle.owner.sessionId];
    return current != null &&
        current.active &&
        identical(current, lifecycle.sessionGeneration);
  }

  void _closeTypedPromptTurn(_TypedPromptTurn turn) {
    if (turn.closed) return;
    turn.closed = true;
    unawaited(turn.cancelUpdates());
    if (identical(_activeTypedTurns[turn.owner], turn)) {
      _activeTypedTurns.remove(turn.owner);
    }
    _closeControllerWithoutWaiting(turn.controller);
  }

  /// Sends a prompt bound to the exact active input owner.
  Future<Map<String, dynamic>> sendPromptRequest({
    required AcpSessionInputBudgetOwner owner,
    required List<Map<String, dynamic>> content,
  }) {
    final lifecycle = _requireDispatchablePrompt(owner);
    final result = peer.sendPromptRequest(
      owner: owner,
      content: content,
      onTerminal: (terminalOwner, winner) {
        if (!identical(terminalOwner, owner) ||
            !_isCurrentPromptLifecycle(lifecycle) ||
            lifecycle.removed ||
            lifecycle.winner != null) {
          return JsonRpcPromptSettlement.rejected();
        }
        final cancellationWinner = lifecycle.cancellationWinner;
        if (cancellationWinner ==
                PermissionCancellationReason.promptCancelled ||
            cancellationWinner == PermissionCancellationReason.sessionClosed) {
          return JsonRpcPromptSettlement.rejected();
        }
        lifecycle.winner = winner;
        if (!lifecycle.winnerRecorded.isCompleted) {
          lifecycle.winnerRecorded.complete();
        }
        lifecycle.deliveryRight = _PromptDeliveryRight(owner, winner);
        if (!lifecycle.rightRecorded.isCompleted) {
          lifecycle.rightRecorded.complete();
        }
        lifecycle.state = _PromptLifecycleState.terminalReady;
        _settlePromptLifecycle(
          lifecycle,
          PermissionCancellationReason.promptEnded,
          sendCancel: winner.kind == JsonRpcPromptTerminalKind.timedOut,
        );
        return JsonRpcPromptSettlement(lifecycle.admissionsSettled);
      },
    );
    lifecycle.promptResult = result;
    return result;
  }

  _PromptLifecycle _requireDispatchablePrompt(
    AcpSessionInputBudgetOwner owner,
  ) {
    final lifecycle = _promptLifecycles[owner.sessionId];
    final generation = _sessionGenerations[owner.sessionId];
    if (_disposed ||
        !peer.isAvailable ||
        !identical(owner.managerIdentity, _managerIdentity) ||
        lifecycle == null ||
        !_isCurrentPromptLifecycle(lifecycle) ||
        !identical(lifecycle.owner, owner) ||
        lifecycle.settling ||
        generation == null ||
        !generation.active ||
        !identical(lifecycle.sessionGeneration, generation) ||
        _isSessionClosing(owner.sessionId)) {
      throw StateError('ACP prompt is already active or settling.');
    }
    return lifecycle;
  }

  bool _isCurrentPromptLifecycle(_PromptLifecycle lifecycle) =>
      !lifecycle.removed &&
      identical(_promptLifecycles[lifecycle.owner.sessionId], lifecycle);

  /// Mark [sessionId] as having an active prompt turn.
  AcpSessionInputBudgetOwner beginPromptTurn(String sessionId) {
    if (_disposed || !peer.isAvailable) {
      throw StateError('ACP connection is not available.');
    }
    if (_isSessionClosing(sessionId) ||
        _sessionSetupTails.containsKey(sessionId)) {
      throw StateError('Session is closing or setup is active.');
    }
    if (_promptLifecycles.containsKey(sessionId)) {
      throw StateError('ACP prompt is already active or settling.');
    }
    final generation = _sessionGenerations[sessionId];
    if (generation == null || !generation.active) {
      throw StateError('Unknown or closed session.');
    }
    final owner = _beginInputBudgetPhase(sessionId);
    _promptLifecycles[sessionId] = _PromptLifecycle(owner, generation);
    return owner;
  }

  /// Clear turn-local state only when [owner] still owns the phase.
  void endPromptTurn(AcpSessionInputBudgetOwner owner) {
    final lifecycle = _promptLifecycles[owner.sessionId];
    if (lifecycle == null) {
      final phase = _inputBudgetPhases[owner.sessionId];
      if (phase != null && identical(phase.owner, owner)) {
        phase.invalidated = true;
        _inputBudgetPhases.remove(owner.sessionId);
      }
      return;
    }
    if (!_isCurrentPromptLifecycle(lifecycle) ||
        !identical(lifecycle.owner, owner)) {
      return;
    }
    lifecycle.callerEnded = true;
    if (lifecycle.promptResult == null && lifecycle.cleanupFuture == null) {
      _releasePromptLifecycle(lifecycle);
      return;
    }
    final cleanup = lifecycle.cleanupFuture;
    if (cleanup != null && lifecycle.cleanupDone) {
      _releasePromptLifecycle(lifecycle);
    }
  }

  /// Cancel the phase owned by [owner], rejecting stale owners locally.
  Future<void> cancelPromptTurn(AcpSessionInputBudgetOwner owner) async {
    final lifecycle = _promptLifecycles[owner.sessionId];
    if (lifecycle == null ||
        !_isCurrentPromptLifecycle(lifecycle) ||
        !identical(lifecycle.owner, owner) ||
        !identical(owner.managerIdentity, _managerIdentity) ||
        lifecycle.settling) {
      throw StateError('ACP prompt phase owner is no longer active.');
    }
    lifecycle.callerEnded = true;
    final legacyRawCaller = lifecycle.promptResult == null;
    _cancelledPromptOwners[owner.sessionId] = owner;
    _settlePromptLifecycle(
      lifecycle,
      PermissionCancellationReason.promptCancelled,
      sendCancel: true,
    );
    await lifecycle.cancelSubmitted;
    if (legacyRawCaller && lifecycle.admissionsSettledNow) {
      _releasePromptLifecycle(lifecycle);
    }
  }

  Future<void> _settlePromptLifecycle(
    _PromptLifecycle lifecycle,
    PermissionCancellationReason reason, {
    bool sendCancel = false,
  }) {
    final existing = lifecycle.cleanupFuture;
    if (existing != null) return existing;
    lifecycle.startSettling();
    lifecycle.cancellationWinner ??= reason;
    settlePromptAdmissions(
      owner: lifecycle.owner,
      reason: lifecycle.cancellationWinner!,
    );
    lifecycle.sealAdmissions(_admissionsByOwner[lifecycle.owner]);
    final legacyRawCaller = lifecycle.promptResult == null;
    final JsonRpcPromptCleanup cleanup;
    if (legacyRawCaller) {
      final notification = sendCancel
          ? peer.cancel(<String, dynamic>{
              'sessionId': lifecycle.owner.sessionId,
            })
          : Future<void>.value();
      unawaited(notification.then<void>((_) {}, onError: (_, _) {}));
      // The pre-Task11 raw caller has no owner-bound peer operation. Preserve
      // its compatibility contract without pretending the raw request was
      // reaped: only the exact owner admissions participate in this window.
      cleanup = JsonRpcPromptCleanup(
        notificationSubmitted: notification,
        reaped: lifecycle.admissionsSettled,
      );
    } else {
      cleanup = peer.cancelPromptRequest(
        owner: lifecycle.owner,
        admissionsSettled: lifecycle.admissionsSettled,
        sendCancel: sendCancel,
      );
    }
    final cleanupKey =
        _frozenSessionCleanupWindowSelections[lifecycle.owner.sessionId]?.key ??
        lifecycle.owner;
    final window = _getOrJoinOwnerCleanupWindow(
      key: cleanupKey,
      fatalOwner: lifecycle.owner,
      blockerIdentity: lifecycle,
      blockerReaped: cleanup.reaped,
    );
    lifecycle.cancelSubmitted = cleanup.notificationSubmitted;
    lifecycle.promptReaped = cleanup.reaped;
    lifecycle.cleanupWindow = window;
    lifecycle.cleanupIdentity = AcpPromptCleanupIdentity(
      lifecycle.owner,
      lifecycle.owner.generation,
    );
    lifecycle.cleanupFuture = window.reaped;
    if (legacyRawCaller && lifecycle.admissionsSettledNow) {
      _releaseOwnerCleanupBlocker(cleanupKey, window, lifecycle);
    }
    unawaited(
      window.reaped.whenComplete(() {
        lifecycle.cleanupDone = true;
        if (lifecycle.callerEnded) _releasePromptLifecycle(lifecycle);
      }),
    );
    return window.reaped;
  }

  void _releasePromptLifecycle(_PromptLifecycle lifecycle) {
    if (!_isCurrentPromptLifecycle(lifecycle) ||
        lifecycle.activeDeliveryClaim != null ||
        _isPromptDeliveryClaimed(lifecycle)) {
      return;
    }
    _lastReleasedPromptLifecycleSnapshot = (
      owner: lifecycle.owner,
      snapshot: _snapshotPromptLifecycle(lifecycle),
    );
    lifecycle.state = _PromptLifecycleState.removed;
    _promptLifecycles.remove(lifecycle.owner.sessionId);
    final phase = _inputBudgetPhases[lifecycle.owner.sessionId];
    if (phase != null && identical(phase.owner, lifecycle.owner)) {
      phase.invalidated = true;
      _inputBudgetPhases.remove(lifecycle.owner.sessionId);
    }
  }

  void _closeTypedPromptWithoutWinner(_PromptLifecycle lifecycle) {
    if (lifecycle.winner != null || !_isCurrentPromptLifecycle(lifecycle)) {
      return;
    }
    final turn = _activeTypedTurns[lifecycle.owner];
    if (turn == null) return;
    unawaited(
      _settlePromptLifecycle(
        lifecycle,
        PermissionCancellationReason.sessionClosed,
        sendCancel: true,
      ),
    );
    lifecycle.deliveryRight?.revoke();
    if (!turn.closed) {
      turn.controller.addError(const AcpConnectionClosedException());
      _closeTypedPromptTurn(turn);
    }
  }

  AcpSessionInputBudgetOwner _beginInputBudgetPhase(String sessionId) {
    if (_disposed) throw StateError('Session manager is disposed.');
    if (_inputBudgetPhases.containsKey(sessionId)) {
      throw StateError('Session input phase is already active.');
    }
    final owner = AcpSessionInputBudgetOwner._(
      sessionId,
      ++_nextInputBudgetGeneration,
      _managerIdentity,
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
      _lastSessionSetupRollbackCallbackForTesting = () {
        settlePromptAdmissions(
          owner: phaseOwner,
          reason: PermissionCancellationReason.sessionClosed,
        );
        endPromptTurn(phaseOwner);
      };
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
        if (!hadBinding) _invalidateSessionGeneration(sessionId);
        if (!hadBinding) {
          _sessionWorkspaceRoots.remove(sessionId);
          _sessionAdditionalDirectories.remove(sessionId);
          _sessionFsProviders.remove(sessionId);
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
        settlePromptAdmissions(
          owner: phaseOwner,
          reason: PermissionCancellationReason.sessionClosed,
        );
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
      final phaseOwner = _beginInputBudgetPhase(sessionId);
      return _GeneratedSessionRegistration(sessionId, identity, phaseOwner);
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
      _sessionFsProviders.containsKey(sessionId) ||
      _sessionModes.containsKey(sessionId) ||
      _toolCalls.containsKey(sessionId) ||
      _toolCallSizes.containsKey(sessionId) ||
      _inputBudgetPhases.containsKey(sessionId) ||
      _cancelledPromptOwners.containsKey(sessionId) ||
      _sessionClosingOwners.containsKey(sessionId) ||
      _terminals.values.any((record) => record.sessionId == sessionId) ||
      _terminalLeases.any((lease) => lease.sessionId == sessionId) ||
      _sessionGenerations.containsKey(sessionId) ||
      _generatedSessionRegistrationOwners.containsKey(sessionId);

  void _commitSessionResultModes(String sessionId, SessionResult result) {
    final modes = result.modes;
    if (modes != null) _sessionModes[sessionId] = modes;
  }

  Future<void> _drainGeneratedSessionUpdates(
    _GeneratedSessionRegistration registration,
  ) async {
    final owner = registration.phaseOwner;
    try {
      final drainBarrier = _generatedRegistrationDrainBarrierForTesting;
      if (drainBarrier != null) {
        final seen = _generatedRegistrationSeenForTesting;
        if (seen != null && !seen.isCompleted) {
          seen.complete(registration.sessionId);
        }
        await drainBarrier.future;
        if (identical(
          _generatedRegistrationDrainBarrierForTesting,
          drainBarrier,
        )) {
          _generatedRegistrationDrainBarrierForTesting = null;
          _generatedRegistrationSeenForTesting = null;
        }
      }
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
    settlePromptAdmissions(
      owner: registration.phaseOwner,
      reason: PermissionCancellationReason.sessionClosed,
    );
    final invalidatedGeneration = _sessionGenerations[sessionId];
    _invalidateSessionGeneration(sessionId);
    _generatedSessionRegistrationOwners.remove(sessionId);
    _invalidateInputBudgetPhase(sessionId);
    _cancelledPromptOwners.remove(sessionId);
    _closeControllerWithoutWaiting(_sessionStreams.remove(sessionId));
    _replayBuffers.remove(sessionId);
    _sessionWorkspaceRoots.remove(sessionId);
    _sessionAdditionalDirectories.remove(sessionId);
    _sessionFsProviders.remove(sessionId);
    _sessionModes.remove(sessionId);
    _removeToolCalls(sessionId);
    try {
      await _releaseSessionTerminals(sessionId);
    } finally {
      if (identical(_sessionGenerations[sessionId], invalidatedGeneration)) {
        _sessionGenerations.remove(sessionId);
      }
    }
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

  /// Live session updates without replaying retained history.
  Stream<AcpUpdate> liveSessionUpdates(String sessionId) => _sessionStreams
      .putIfAbsent(sessionId, StreamController<AcpUpdate>.broadcast)
      .stream;

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

  void _onPeerSessionUpdate(Object? incoming) {
    final envelope = incoming is PausedSessionUpdateForTesting
        ? incoming.envelope
        : incoming;
    final String? sessionId;
    try {
      sessionId = envelope is Map
          ? _sessionIdFromMap(Map<String, dynamic>.from(envelope))
          : null;
    } on Object {
      return;
    }
    final generation = sessionId == null
        ? null
        : _sessionGenerations[sessionId];
    final phase = sessionId == null ? null : _inputBudgetPhases[sessionId];
    if (sessionId == null || (generation == null && phase == null)) return;
    if (incoming is PausedSessionUpdateForTesting) {
      unawaited(
        incoming.release.then<void>((_) {
          _routeSessionUpdateForOwner(sessionId!, generation, phase, envelope);
        }),
      );
      return;
    }
    _routeSessionUpdateForOwner(sessionId, generation, phase, envelope);
  }

  void _routeSessionUpdateForOwner(
    String sessionId,
    _SessionGeneration? generation,
    _SessionInputBudgetPhase? phase,
    Object? envelope,
  ) {
    final currentGeneration = _sessionGenerations[sessionId];
    final generationOwns =
        generation != null &&
        generation.active &&
        identical(currentGeneration, generation);
    final currentPhase = _inputBudgetPhases[sessionId];
    final phaseOwns =
        phase != null && !phase.invalidated && identical(currentPhase, phase);
    if (!generationOwns && !phaseOwns) {
      return;
    }
    _routeSessionUpdate(envelope);
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
      _publishUpdateObservation(sessionId: sessionId, update: bounded);
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

  @override
  void addBoundedObservationListener(AcpBoundedObservationListener listener) {
    if (_disposed) return;
    _boundedObservationListeners.add(listener);
  }

  @override
  void removeBoundedObservationListener(
    AcpBoundedObservationListener listener,
  ) {
    _boundedObservationListeners.remove(listener);
  }

  void _publishSessionResultObservation({
    required AcpBoundedSessionOperation operation,
    required String sessionId,
    required SessionResult result,
  }) {
    if (_boundedObservationListeners.isEmpty) return;
    _publishBoundedObservation(
      AcpBoundedSessionResultObservation(
        operation: operation,
        sessionId: sessionId,
        result: result,
      ),
    );
  }

  void _publishUpdateObservation({
    required String sessionId,
    required AcpUpdate update,
  }) {
    if (_boundedObservationListeners.isEmpty) return;
    _publishBoundedObservation(
      AcpBoundedUpdateObservation(sessionId: sessionId, update: update),
    );
  }

  void _publishBoundedObservation(AcpBoundedObservation observation) {
    final listeners = _boundedObservationListeners.toList(growable: false);
    for (final listener in listeners) {
      try {
        listener(observation);
      } on Object {
        _log.warning('bounded observation listener failed');
      }
    }
  }

  AcpInputLimitExceeded? _normalizedSessionUpdateLimit(
    AcpInputLimitExceeded error,
  ) {
    final resource = error.resource;
    if (resource.length > 256) return null;
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
    } else if (resource.startsWith('session input phase ') &&
        resource.endsWith(' string bytes')) {
      normalizedResource = 'session structured string bytes';
      normalizedLimit = inputBudget.maxStructuredStringBytes;
    } else if (resource.startsWith('session input phase ') &&
        resource.endsWith(' nodes')) {
      normalizedResource = 'session structured nodes';
      normalizedLimit = inputBudget.maxStructuredUpdateNodes;
    } else if (resource.startsWith('session input phase ') &&
        resource.endsWith(' bytes')) {
      normalizedResource = 'session structured bytes';
      normalizedLimit = inputBudget.maxStructuredUpdateBytes;
    } else if (resource == 'ACP retained state nodes') {
      normalizedResource = 'session retained nodes';
      normalizedLimit = inputBudget.maxMetadataNodes;
    } else if (resource == 'ACP retained state depth') {
      normalizedResource = 'session retained depth';
      normalizedLimit = inputBudget.maxMetadataDepth;
    } else if (resource == 'ACP retained state string bytes') {
      normalizedResource = 'session retained string bytes';
      normalizedLimit = inputBudget.maxStructuredStringBytes;
    } else if (resource == 'ACP retained state collection items') {
      normalizedResource = 'session retained collection items';
      normalizedLimit = inputBudget.maxCollectionItems;
    } else if (resource == 'ACP retained state map entries') {
      normalizedResource = 'session retained map entries';
      normalizedLimit =
          inputBudget.maxCollectionItems < inputBudget.maxMetadataEntries
          ? inputBudget.maxCollectionItems
          : inputBudget.maxMetadataEntries;
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
      boundedKind: kind,
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
  FsProvider _fileSystemProviderForSession(String sessionId) {
    final configured = config.fsProvider!;
    if (configured is! SessionScopedFsProvider) return configured;
    return _sessionFsProviders.putIfAbsent(
      sessionId,
      () => configured.bindToSession(
        workspaceRoot: _sessionWorkspaceRoots[sessionId]!,
        additionalWorkspaceRoots: _additionalDirectoriesForSession(sessionId),
        allowReadOutsideWorkspace: config.allowReadOutsideWorkspace,
      ),
    );
  }

  _InboundPermissionAdmission _admitInboundPermission(
    String method,
    Map<String, dynamic>? params,
    Object correlationIdentity,
  ) {
    final sessionId = _sessionIdFromMap(params);
    final generation = sessionId == null
        ? null
        : _sessionGenerations[sessionId];
    final owner = sessionId == null
        ? null
        : (_settlingPromptOwners[sessionId] ??
              _inputBudgetPhases[sessionId]?.owner);
    final currentLifecycle = sessionId == null
        ? null
        : _promptLifecycles[sessionId];
    final promptLifecycle =
        currentLifecycle != null &&
            owner != null &&
            identical(currentLifecycle.owner, owner)
        ? currentLifecycle
        : null;
    final ownerAdmissionsSealed = promptLifecycle?.admissionsSealed ?? false;
    final sealedCancellationReason = ownerAdmissionsSealed
        ? promptLifecycle!.cancellationWinner ??
              PermissionCancellationReason.promptEnded
        : null;
    final admission = _InboundPermissionAdmission(
      manager: this,
      method: method,
      correlationIdentity: correlationIdentity,
      sessionId: sessionId,
      sessionGeneration: generation,
      promptOwner: owner,
      promptLifecycle: ownerAdmissionsSealed ? null : promptLifecycle,
      ownerAdmissionsSealedAtArrival: ownerAdmissionsSealed,
      peerEpoch: _peerEpoch,
    );
    _inboundAdmissions.add(admission);
    if (params != null) _admissionsByParams[params] = admission;
    if (sealedCancellationReason != null) {
      admission.tryCancel(sealedCancellationReason);
    } else if (owner != null) {
      (_admissionsByOwner[owner] ??=
              HashSet<_InboundPermissionAdmission>.identity())
          .add(admission);
      if (promptLifecycle != null) {
        _attachPromptAdmissionProbeForTesting(promptLifecycle, admission);
      }
      final settlingReason = _settlingPromptReasons[owner];
      final lifecycleReason = promptLifecycle?.settling ?? false
          ? promptLifecycle!.cancellationWinner
          : null;
      final cancellationReason = settlingReason ?? lifecycleReason;
      if (cancellationReason != null) {
        admission.tryCancel(cancellationReason);
      }
    }
    if (sessionId != null && generation == null && owner == null) {
      admission.tryCompleteLocal(
        InboundGateTerminalError<dynamic>(
          _PayloadFreeRpcException(-32003, 'Permission request cancelled.'),
        ),
        cancellationReason: PermissionCancellationReason.sessionClosed,
      );
    }
    return admission;
  }

  Future<PermissionDecision> _permissionProviderDecision({
    required _InboundPermissionAdmission admission,
    required PermissionOptions options,
  }) async {
    if (admission.terminalReason case final reason?) {
      return _permissionDecisionForCancellation(reason);
    }
    if (!admission.peerEpoch.active) {
      admission.tryCancel(PermissionCancellationReason.connectionClosed);
      return _permissionDecisionForCancellation(
        PermissionCancellationReason.connectionClosed,
      );
    }
    final generation = admission.sessionGeneration;
    if (generation != null &&
        (!generation.active ||
            !identical(
              _sessionGenerations[generation.sessionId],
              generation,
            ))) {
      admission.tryCancel(PermissionCancellationReason.sessionClosed);
      return _permissionDecisionForCancellation(
        PermissionCancellationReason.sessionClosed,
      );
    }
    admission.providerStarted = true;
    final providerOptions = PermissionOptions(
      title: options.title,
      rationale: options.rationale,
      options: options.options,
      choices: options.choices,
      sessionId: options.sessionId,
      toolName: options.toolName,
      toolKind: options.toolKind,
      metadata: options.metadata,
      transientPolicyContext: options.transientPolicyContext,
      cancellationToken: admission.cancellationToken,
    );
    final providerResult = config.permissionProvider
        .request(providerOptions)
        .then<_PermissionProviderResult>(
          _PermissionProviderResult.value,
          onError: (Object error, StackTrace stackTrace) =>
              _PermissionProviderResult.error(error, stackTrace),
        );
    final cancelled = admission.cancellation.then<_PermissionProviderResult>(
      (reason) => _PermissionProviderResult.error(
        _PermissionGateCancellation(reason),
        StackTrace.empty,
      ),
    );
    final winner = await Future.any<_PermissionProviderResult>(
      <Future<_PermissionProviderResult>>[providerResult, cancelled],
    );
    final error = winner.error;
    if (error is _PermissionGateCancellation) {
      return _permissionDecisionForCancellation(error.reason);
    }
    if (error is PermissionRequestTimeoutException) {
      admission.tryCancel(PermissionCancellationReason.timedOut);
      return _permissionDecisionForCancellation(
        admission.terminalReason ?? PermissionCancellationReason.timedOut,
      );
    }
    if (error != null) Error.throwWithStackTrace(error, winner.stackTrace!);
    return winner.value!;
  }

  Future<T> _runPermissionHandler<T>({
    required _InboundPermissionAdmission admission,
    required PermissionOptions options,
    required Future<T> Function(PermissionDecision decision) operation,
  }) async {
    final initialCancellation = _inactivePermissionAdmissionReason(admission);
    if (initialCancellation != null) {
      return _permissionCancellationResult<T>(admission, initialCancellation);
    }
    final decision = await _permissionProviderDecision(
      admission: admission,
      options: options,
    );
    // Let a cancellation queued by the same permission resolution freeze the
    // admission before any allowed operation can begin.
    await Future<void>.value();
    final cancellationReason = _inactivePermissionAdmissionReason(admission);
    if (cancellationReason != null) {
      return _permissionCancellationResult<T>(admission, cancellationReason);
    }
    late final T value;
    try {
      value = await operation(decision);
    } on Object catch (error, stackTrace) {
      final operationCancellation = _inactivePermissionAdmissionReason(
        admission,
      );
      if (operationCancellation != null) {
        return _permissionCancellationResult<T>(
          admission,
          operationCancellation,
        );
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
    final operationCancellation = _inactivePermissionAdmissionReason(admission);
    if (operationCancellation != null) {
      return _permissionCancellationResult<T>(admission, operationCancellation);
    }
    return value;
  }

  PermissionCancellationReason? _inactivePermissionAdmissionReason(
    _InboundPermissionAdmission admission,
  ) {
    if (admission.terminalReason case final reason?) return reason;
    if (admission.localSettled) return null;
    if (_disposed) {
      admission.tryCancel(PermissionCancellationReason.disposed);
      return admission.terminalReason ?? PermissionCancellationReason.disposed;
    }
    if (!admission.peerEpoch.active) {
      admission.tryCancel(PermissionCancellationReason.connectionClosed);
      return admission.terminalReason ??
          PermissionCancellationReason.connectionClosed;
    }
    final sessionId = admission.sessionId;
    final generation = admission.sessionGeneration;
    if (sessionId != null &&
        generation == null &&
        admission.promptOwner == null) {
      admission.tryCancel(PermissionCancellationReason.sessionClosed);
      return admission.terminalReason ??
          PermissionCancellationReason.sessionClosed;
    }
    if (sessionId != null && _isSessionClosing(sessionId)) {
      admission.tryCancel(PermissionCancellationReason.sessionClosed);
      return admission.terminalReason ??
          PermissionCancellationReason.sessionClosed;
    }
    if (generation != null &&
        (!generation.active ||
            !identical(
              _sessionGenerations[generation.sessionId],
              generation,
            ))) {
      admission.tryCancel(PermissionCancellationReason.sessionClosed);
      return admission.terminalReason ??
          PermissionCancellationReason.sessionClosed;
    }
    return null;
  }

  T _permissionCancellationResult<T>(
    _InboundPermissionAdmission admission,
    PermissionCancellationReason reason,
  ) {
    final terminal = _permissionGateTerminal(admission.method, reason);
    switch (terminal) {
      case InboundGateTerminalValue<dynamic>(:final value):
        return value as T;
      case InboundGateTerminalError<dynamic>(
        :final error,
        stackTrace: final stackTrace,
      ):
        Error.throwWithStackTrace(error, stackTrace ?? StackTrace.current);
    }
  }

  PermissionDecision _permissionDecisionForCancellation(
    PermissionCancellationReason reason,
  ) {
    switch (reason) {
      case PermissionCancellationReason.timedOut:
        throw const PermissionRequestTimeoutException();
      case PermissionCancellationReason.promptEnded:
      case PermissionCancellationReason.promptCancelled:
      case PermissionCancellationReason.sessionClosed:
        return const PermissionDecision.cancelled();
      case PermissionCancellationReason.connectionClosed:
      case PermissionCancellationReason.disposed:
        throw const AcpConnectionClosedException();
    }
  }

  InboundGateTerminal<dynamic> _permissionGateTerminal(
    String method,
    PermissionCancellationReason reason,
  ) {
    if (method == 'session/request_permission') {
      return const InboundGateTerminalValue<dynamic>(<String, Object?>{
        'outcome': <String, Object?>{'outcome': 'cancelled'},
      });
    }
    if (reason == PermissionCancellationReason.timedOut) {
      return InboundGateTerminalError<dynamic>(
        _PayloadFreeRpcException(-32002, 'Permission request timed out.'),
      );
    }
    if (reason == PermissionCancellationReason.promptEnded ||
        reason == PermissionCancellationReason.promptCancelled ||
        reason == PermissionCancellationReason.sessionClosed) {
      return InboundGateTerminalError<dynamic>(
        _PayloadFreeRpcException(-32003, 'Permission request cancelled.'),
      );
    }
    return InboundGateTerminalError<dynamic>(
      _PayloadFreeRpcException(-32000, 'ACP connection closed.'),
    );
  }

  void _notifyPermissionProviderCancellation(
    _InboundPermissionAdmission admission,
    PermissionCancellationReason reason,
  ) {
    if (admission.providerCancellationSent) return;
    final provider = config.permissionProvider;
    if (provider is! CancellablePermissionProvider) return;
    admission.providerCancellationSent = true;
    try {
      provider.cancelPendingPermission(
        cancellationToken: admission.cancellationToken,
        reason: reason,
      );
    } on Object {
      _log.warning('ACP permission provider cancellation failed.');
    }
  }

  void _attachPromptAdmissionProbeForTesting(
    _PromptLifecycle lifecycle,
    _InboundPermissionAdmission admission,
  ) {
    final state = _armedPromptAdmissionProbeForTesting;
    if (state == null) return;
    _armedPromptAdmissionProbeForTesting = null;
    state.bound = true;
    state.owner = lifecycle.owner;
    _promptAdmissionProbesForTesting[admission] = state;
    admission.installTestingGates(
      reservationRelease: state.reservationGate.future,
      responseCommit: state.responseCommitGate.future,
    );
    if (!state.admissionBarrierSeen.isCompleted) {
      state.admissionBarrierSeen.complete();
    }
    lifecycle.graceStarted.future.then<void>((_) {
      if (!state.graceStarted.isCompleted) state.graceStarted.complete();
    });
    Future.wait<void>(<Future<void>>[
      admission.settled,
      admission.reservationReleasedForTesting,
      admission.responseCommittedForTesting,
    ]).then<void>((_) {
      _promptAdmissionProbesForTesting.remove(admission);
      if (!state.reaped.isCompleted) state.reaped.complete();
    });
  }

  void _markPromptAdmissionSideEffectStartedForTesting(
    _InboundPermissionAdmission admission,
  ) {
    final state = _promptAdmissionProbesForTesting[admission];
    if (state != null && !state.sideEffectStarted.isCompleted) {
      state.sideEffectStarted.complete();
    }
  }

  void _disposePromptAdmissionProbesForTesting() {
    final armed = _armedPromptAdmissionProbeForTesting;
    _armedPromptAdmissionProbeForTesting = null;
    if (armed != null) {
      armed.releaseCommit();
      if (!armed.reaped.isCompleted) armed.reaped.complete();
    }
    for (final state in _promptAdmissionProbesForTesting.values.toList(
      growable: false,
    )) {
      state.releaseCommit();
    }
  }

  void _removeInboundAdmission(_InboundPermissionAdmission admission) {
    _inboundAdmissions.remove(admission);
    _admissionsByParams.removeWhere(
      (_, current) => identical(current, admission),
    );
    final owner = admission.promptOwner;
    if (owner == null) return;
    final owned = _admissionsByOwner[owner];
    final isLastForOwner =
        owned != null && owned.contains(admission) && owned.length == 1;
    admission.promptLifecycle?.markAdmissionRemoving(
      isLastForOwner: isLastForOwner,
    );
    owned?.remove(admission);
    if (owned != null && owned.isEmpty) {
      _admissionsByOwner.remove(owner);
      _settlingPromptReasons.remove(owner);
      if (identical(_settlingPromptOwners[owner.sessionId], owner)) {
        _settlingPromptOwners.remove(owner.sessionId);
      }
    }
  }

  _InboundPermissionAdmission _permissionAdmissionForHandler(
    Json req,
    InboundAdmission rawAdmission,
  ) {
    final direct = rawAdmission is _InboundPermissionAdmission
        ? rawAdmission
        : null;
    final frozen = direct ?? _admissionsByParams[req];
    if (frozen == null) {
      throw StateError('Missing frozen inbound permission admission.');
    }
    return frozen;
  }

  Future<Json> _onReadTextFile(Json req, InboundAdmission rawAdmission) async {
    final admission = _permissionAdmissionForHandler(req, rawAdmission);
    if (config.fsProvider == null) {
      throw Exception('File system operations not supported');
    }
    final sessionId = _requireKnownSessionId(req);
    final workspaceRoot = _sessionWorkspaceRoots[sessionId]!;

    final provider = _fileSystemProviderForSession(sessionId);

    // Enforce permission policy for reads when provided (non-interactive
    // policy mode). Agents may or may not request permission explicitly;
    // we gate here to ensure policy is always respected.
    try {
      final additionalDirectories = _additionalDirectoriesForSession(sessionId);
      return await _runPermissionHandler<Json>(
        admission: admission,
        options: PermissionOptions(
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
        operation: (decision) async {
          if (decision.outcome != PermissionOutcome.allow) {
            throw Exception('Permission denied');
          }
          _markPromptAdmissionSideEffectStartedForTesting(admission);
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
            _log.fine(
              'fs/read_text_file -> ok path=$path bytes=${content.length}',
            );
            return {'content': content};
          } on FsReadRejectedException catch (error) {
            _log.warning('fs/read_text_file -> rejected by bounded policy');
            throw rpc.RpcException(
              -32001,
              'Filesystem read rejected.',
              data: error.reason.name,
            );
          } catch (e) {
            _log.warning('fs/read_text_file -> error path=$path: $e');
            rethrow;
          }
        },
      );
    } catch (e) {
      _log.fine('fs/read_text_file -> denied by policy');
      rethrow;
    }
  }

  Future<Json?> _onWriteTextFile(
    Json req,
    InboundAdmission rawAdmission,
  ) async {
    final admission = _permissionAdmissionForHandler(req, rawAdmission);
    try {
      if (config.fsProvider == null) {
        throw Exception('File system operations not supported');
      }
      final sessionId = _requireKnownSessionId(req);
      final workspaceRoot = _sessionWorkspaceRoots[sessionId]!;
      final provider = _fileSystemProviderForSession(sessionId);
      final additionalDirectories = _additionalDirectoriesForSession(sessionId);
      return await _runPermissionHandler<Json?>(
        admission: admission,
        options: PermissionOptions(
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
        operation: (decision) async {
          if (decision.outcome != PermissionOutcome.allow) {
            throw Exception('Permission denied');
          }
          _markPromptAdmissionSideEffectStartedForTesting(admission);
          final path = req['path'] as String;
          final content = req['content'] as String? ?? '';
          if (_log.isLoggable(Level.FINE)) {
            final contentBytes = await Isolate.run<int>(
              () => utf8.encode(content).length,
            );
            final cancellationReason = _inactivePermissionAdmissionReason(
              admission,
            );
            if (cancellationReason != null) {
              return _permissionCancellationResult<Json?>(
                admission,
                cancellationReason,
              );
            }
            _log.fine('fs/write_text_file <- bytes=$contentBytes');
          }
          final cancellationReason = _inactivePermissionAdmissionReason(
            admission,
          );
          if (cancellationReason != null) {
            return _permissionCancellationResult<Json?>(
              admission,
              cancellationReason,
            );
          }
          await provider.writeTextFile(path, content);
          _log.fine('fs/write_text_file -> ok');
          return null; // per schema null
        },
      );
    } on _PayloadFreeRpcException {
      rethrow;
    } on Object {
      _log.warning('fs/write_text_file -> error');
      throw _PayloadFreeRpcException(-32001, 'Filesystem write rejected.');
    }
  }

  Future<Json> _onRequestPermission(
    Json req,
    InboundAdmission rawAdmission,
  ) async {
    final admission = _permissionAdmissionForHandler(req, rawAdmission);
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
    return _runPermissionHandler<Json>(
      admission: admission,
      options: PermissionOptions(
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
      operation: (decision) async {
        if (decision.outcome == PermissionOutcome.cancelled) {
          return {
            'outcome': {'outcome': 'cancelled'},
          };
        }

        final optionId = _permissionOptionIdForDecision(options, decision);
        if (optionId == null) {
          return {
            'outcome': {'outcome': 'cancelled'},
          };
        }
        return {
          'outcome': {'outcome': 'selected', 'optionId': optionId},
        };
      },
    );
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

  _TerminalQuotaLease _reserveTerminalLease(String sessionId) {
    if (_terminalLeases.length >= maxTerminalHandles) {
      throw TerminalHandleLimitException(
        reason: TerminalHandleLimitReason.global,
        limit: maxTerminalHandles,
      );
    }
    final sessionCount = _terminalLeaseCountBySession[sessionId] ?? 0;
    if (sessionCount >= maxTerminalHandlesPerSession) {
      throw TerminalHandleLimitException(
        reason: TerminalHandleLimitReason.session,
        limit: maxTerminalHandlesPerSession,
      );
    }
    final lease = _TerminalQuotaLease(this, sessionId);
    _terminalLeases.add(lease);
    _pendingTerminalLeases.add(lease);
    _terminalLeaseCountBySession[sessionId] = sessionCount + 1;
    return lease;
  }

  void _releaseTerminalLease(_TerminalQuotaLease lease) {
    _pendingTerminalLeases.remove(lease);
    if (!_terminalLeases.remove(lease)) return;
    final sessionCount = _terminalLeaseCountBySession[lease.sessionId];
    if (sessionCount == null || sessionCount <= 1) {
      _terminalLeaseCountBySession.remove(lease.sessionId);
    } else {
      _terminalLeaseCountBySession[lease.sessionId] = sessionCount - 1;
    }
  }

  void _requireUsableTerminalLease(_TerminalQuotaLease lease) {
    if (_disposed ||
        lease.revoked ||
        lease.state == _TerminalLeaseState.released ||
        _isSessionClosing(lease.sessionId) ||
        !_sessionWorkspaceRoots.containsKey(lease.sessionId)) {
      throw StateError('Terminal session is closing or closed.');
    }
  }

  void _revokeTerminalLeases({String? sessionId}) {
    for (final lease in _pendingTerminalLeases.toList(growable: false)) {
      if (sessionId == null || lease.sessionId == sessionId) lease.revoke();
    }
  }

  final Map<String, _ManagedTerminal> _terminals = <String, _ManagedTerminal>{};

  Future<void> _releaseUnregisteredTerminalHandleOnce({
    required TerminalProvider provider,
    required TerminalProcessHandle handle,
    required _UnregisteredTerminalRelease guard,
  }) {
    final existing = guard.operation;
    if (existing != null) return existing;
    final owner = Completer<void>.sync();
    final operation = owner.future;
    guard.operation = operation;
    late final Future<void> releasing;
    try {
      releasing = provider.release(handle);
    } on Object {
      _log.warning('terminal unregistered handle release failed');
      owner.complete();
      return operation;
    }
    releasing.then<void>(
      (_) {
        if (!owner.isCompleted) owner.complete();
      },
      onError: (Object _, StackTrace _) {
        _log.warning('terminal unregistered handle release failed');
        if (!owner.isCompleted) owner.complete();
      },
    );
    return operation;
  }

  void _consumeRejectedTerminalCreate({
    required Future<_TerminalCreateResult> observed,
    required TerminalProvider provider,
    required _UnregisteredTerminalRelease release,
  }) {
    unawaited(
      observed
          .then<void>((late) async {
            final handle = late.handle;
            if (handle != null) {
              await _releaseUnregisteredTerminalHandleOnce(
                provider: provider,
                handle: handle,
                guard: release,
              );
            }
          })
          .then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
  }

  Future<_TerminalCreateResult> _createTerminalWithLateConsumer({
    required _InboundPermissionAdmission admission,
    required TerminalProvider provider,
    required Future<TerminalProcessHandle> createFuture,
    required _UnregisteredTerminalRelease release,
  }) async {
    final observed = createFuture.then<_TerminalCreateResult>(
      _TerminalCreateResult.handle,
      onError: (Object error, StackTrace stackTrace) =>
          _TerminalCreateResult.error(error, stackTrace),
    );
    final initialCancellation = _inactivePermissionAdmissionReason(admission);
    if (initialCancellation != null) {
      _consumeRejectedTerminalCreate(
        observed: observed,
        provider: provider,
        release: release,
      );
      return _TerminalCreateResult.cancelled(initialCancellation);
    }
    final invalidated = admission.cancellation.then<_TerminalCreateResult>(
      _TerminalCreateResult.cancelled,
    );
    final winner = await Future.any<_TerminalCreateResult>(
      <Future<_TerminalCreateResult>>[observed, invalidated],
    );
    if (winner.cancellationReason != null) {
      _consumeRejectedTerminalCreate(
        observed: observed,
        provider: provider,
        release: release,
      );
      return winner;
    }
    final cancellationReason = _inactivePermissionAdmissionReason(admission);
    if (cancellationReason != null) {
      _consumeRejectedTerminalCreate(
        observed: observed,
        provider: provider,
        release: release,
      );
      return _TerminalCreateResult.cancelled(cancellationReason);
    }
    if (winner.error case final error?) {
      Error.throwWithStackTrace(error, winner.stackTrace!);
    }
    return winner;
  }

  Future<Json> _onTerminalCreate(
    Json req,
    InboundAdmission rawAdmission,
  ) async {
    final admission = _permissionAdmissionForHandler(req, rawAdmission);
    final provider = config.terminalProvider;
    if (provider == null) {
      throw Exception('Terminal not supported');
    }
    if (_disposed) {
      throw StateError('Terminal session is closing or closed.');
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

    late final _TerminalQuotaLease lease;
    try {
      lease = _reserveTerminalLease(sessionId);
    } on TerminalHandleLimitException {
      throw _PayloadFreeRpcException(-32001, 'Terminal handle limit exceeded.');
    }
    var registered = false;
    try {
      return await _runPermissionHandler<Json>(
        admission: admission,
        options: PermissionOptions(
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
        operation: (decision) async {
          // Enforce permission for execute/terminal usage. If policy denies,
          // reject creation so the agent cannot bypass the FS jail via shell.
          if (decision.outcome != PermissionOutcome.allow) {
            throw Exception('Permission denied');
          }

          _markPromptAdmissionSideEffectStartedForTesting(admission);

          _requireUsableTerminalLease(lease);
          var cwd = requestedCwd;
          // Enforce workspace jail for terminal working directory unless yolo.
          if (!config.allowReadOutsideWorkspace) {
            final jail = WorkspaceJail(
              workspaceRoot: workspaceRoot,
              additionalWorkspaceRoots: _additionalDirectoriesForSession(
                sessionId,
              ),
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
          final preCreateCancellation = _inactivePermissionAdmissionReason(
            admission,
          );
          if (preCreateCancellation != null) {
            return _permissionCancellationResult<Json>(
              admission,
              preCreateCancellation,
            );
          }
          _requireUsableTerminalLease(lease);
          lease.markCreating();
          final release = _UnregisteredTerminalRelease();
          late final _TerminalCreateResult createResult;
          try {
            final createFuture = provider.create(
              sessionId: sessionId,
              command: cmd,
              args: args,
              cwd: cwd,
              env: env.isEmpty ? null : env,
              outputByteLimit: outputByteLimit,
            );
            createResult = await _createTerminalWithLateConsumer(
              admission: admission,
              provider: provider,
              createFuture: createFuture,
              release: release,
            );
          } on TerminalHandleLimitException {
            throw _PayloadFreeRpcException(
              -32001,
              'Terminal handle limit exceeded.',
            );
          }
          if (createResult.cancellationReason case final reason?) {
            return _permissionCancellationResult<Json>(admission, reason);
          }
          final handle = createResult.handle!;

          final postCreateCancellation = _inactivePermissionAdmissionReason(
            admission,
          );
          if (postCreateCancellation != null) {
            await _releaseUnregisteredTerminalHandleOnce(
              provider: provider,
              handle: handle,
              guard: release,
            );
            return _permissionCancellationResult<Json>(
              admission,
              postCreateCancellation,
            );
          }
          return await _runSerializedSessionMutation(sessionId, () async {
            final registrationCancellation = _inactivePermissionAdmissionReason(
              admission,
            );
            if (registrationCancellation != null) {
              await _releaseUnregisteredTerminalHandleOnce(
                provider: provider,
                handle: handle,
                guard: release,
              );
              return _permissionCancellationResult<Json>(
                admission,
                registrationCancellation,
              );
            }
            if (_disposed ||
                lease.revoked ||
                _isSessionClosing(sessionId) ||
                !_sessionWorkspaceRoots.containsKey(sessionId)) {
              await _releaseUnregisteredTerminalHandleOnce(
                provider: provider,
                handle: handle,
                guard: release,
              );
              throw StateError('Terminal session is closing or closed.');
            }
            if (_terminals.containsKey(handle.terminalId)) {
              await _releaseUnregisteredTerminalHandleOnce(
                provider: provider,
                handle: handle,
                guard: release,
              );
              throw StateError(
                'Terminal provider returned a duplicate terminalId.',
              );
            }
            final result = <String, dynamic>{'terminalId': handle.terminalId};
            if (!admission.tryClaimLocal(
              InboundGateTerminalValue<dynamic>(result),
            )) {
              await _releaseUnregisteredTerminalHandleOnce(
                provider: provider,
                handle: handle,
                guard: release,
              );
              final cancellationReason = admission.terminalReason;
              if (cancellationReason == null) {
                throw StateError(
                  'Terminal permission admission was already completed.',
                );
              }
              return _permissionCancellationResult<Json>(
                admission,
                cancellationReason,
              );
            }
            var inserted = false;
            try {
              lease.markActive();
              _terminals[handle.terminalId] = _ManagedTerminal(
                handle: handle,
                sessionId: sessionId,
                lease: lease,
              );
              inserted = true;
              registered = true;
            } on Object catch (error, stackTrace) {
              if (inserted) _terminals.remove(handle.terminalId);
              registered = false;
              await _releaseUnregisteredTerminalHandleOnce(
                provider: provider,
                handle: handle,
                guard: release,
              );
              admission.publishClaimedLocalError(error, stackTrace);
              Error.throwWithStackTrace(error, stackTrace);
            }
            admission.publishClaimedLocal();
            _terminalEvents.add(
              TerminalCreated(
                terminalId: handle.terminalId,
                sessionId: sessionId,
                command: cmd,
                args: args,
                cwd: cwd,
              ),
            );
            return result;
          });
        },
      );
    } finally {
      if (!registered) lease.release();
    }
  }

  Future<Json> _onTerminalOutput(Json req) async {
    final provider = config.terminalProvider;
    if (provider == null) {
      return {'output': '', 'truncated': false, 'exitStatus': null};
    }
    final termId = req['terminalId'] as String;
    final record = _terminals[termId];
    if (record == null) {
      return {'output': '', 'truncated': false, 'exitStatus': null};
    }
    final handle = record.handle;
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
    final record = _terminals[termId];
    if (record == null) {
      return {
        'output': '',
        'truncated': false,
        'exitStatus': {'exitCode': 0},
      };
    }
    final handle = record.handle;
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
    final record = _terminals[termId];
    if (provider != null && record != null) {
      await provider.kill(record.handle);
    }
    return null;
  }

  Future<Json?> _onTerminalRelease(Json req) async {
    final termId = req['terminalId'] as String;
    try {
      await _releaseManagedTerminal(termId, publishEvent: true);
    } on Object {
      throw _PayloadFreeRpcException(-32000, 'Terminal release failed.');
    }
    return null;
  }

  // UI helpers to interact with terminals
  /// Read buffered output for a managed terminal.
  Future<String> readTerminalOutput(String terminalId) async {
    final record = _terminals[terminalId];
    if (record == null) return '';
    return record.handle.currentOutput();
  }

  /// Kill a managed terminal process.
  Future<void> killTerminal(String terminalId) async {
    final provider = config.terminalProvider;
    final record = _terminals[terminalId];
    if (provider != null && record != null) {
      await provider.kill(record.handle);
    }
  }

  /// Wait for a terminal to exit and return its code, or null if unavailable.
  Future<int?> waitTerminal(String terminalId) async {
    final provider = config.terminalProvider;
    final record = _terminals[terminalId];
    if (provider != null && record != null) {
      final code = await provider.waitForExit(record.handle);
      return code;
    }
    return null;
  }

  /// Release resources for a managed terminal.
  Future<void> releaseTerminal(String terminalId) async {
    await _releaseManagedTerminal(terminalId);
  }

  Future<bool> _releaseManagedTerminal(
    String terminalId, {
    bool publishEvent = false,
  }) {
    final record = _terminals.remove(terminalId);
    if (record == null) return Future<bool>.value(false);
    final operation = _performManagedTerminalRelease(
      terminalId,
      record,
      publishEvent: publishEvent,
    );
    _trackTerminalRelease(operation);
    return operation.then((_) => true);
  }

  Future<void> _performManagedTerminalRelease(
    String terminalId,
    _ManagedTerminal record, {
    required bool publishEvent,
  }) async {
    try {
      final provider = config.terminalProvider;
      if (provider != null) {
        await provider.release(record.handle);
      }
    } finally {
      try {
        record.lease.release();
      } finally {
        if (publishEvent) {
          try {
            _terminalEvents.add(TerminalReleased(terminalId: terminalId));
          } on Object {
            // Event delivery must not replace the provider release result.
          }
        }
      }
    }
  }

  void _trackTerminalRelease(Future<void> operation) {
    _terminalReleaseOperations.add(operation);
    unawaited(
      operation.then<void>(
        (_) => _terminalReleaseOperations.remove(operation),
        onError: (Object _, StackTrace _) {
          _terminalReleaseOperations.remove(operation);
        },
      ),
    );
  }

  Future<void> _waitForTerminalReleaseOperations() async {
    while (_terminalReleaseOperations.isNotEmpty) {
      final operations = _terminalReleaseOperations.toList(growable: false);
      await Future.wait<void>(
        operations.map(
          (operation) => operation.then<void>(
            (_) {},
            onError: (Object _, StackTrace _) {},
          ),
        ),
      );
    }
  }

  Future<void> _releaseSessionTerminals(String sessionId) async {
    final terminalIds = _terminals.entries
        .where((entry) => entry.value.sessionId == sessionId)
        .map((entry) => entry.key)
        .toList(growable: false);
    var failures = 0;
    for (final terminalId in terminalIds) {
      try {
        await _releaseManagedTerminal(terminalId);
      } on Object {
        failures += 1;
      }
    }
    if (failures > 0) {
      throw StateError('$failures terminal release(s) failed');
    }
  }
}
