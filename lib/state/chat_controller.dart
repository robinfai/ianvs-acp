import 'package:ianvs_agent_core/content_mutation.dart';
import 'package:ianvs_agent_core/buffered_chat_message.dart';
import 'package:ianvs_agent_core/models/chat_message.dart';
export 'package:ianvs_agent_core/models/chat_message.dart'
    show ChatMessageRole, ChatQueuedPrompt;
import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../acp/acp_agent_capabilities.dart';
import '../acp/acp_agent_client.dart';
import '../acp/acp_available_commands.dart';
import '../acp/assistant_agent_enhancer.dart';
import 'package:ianvs_agent_core/models/chat_input_budget.dart' as acp;
import 'package:ianvs_agent_core/models/chat_permission_request.dart';
import '../acp/acp_permission_reviewer.dart';
import '../acp/acp_session_catalog.dart';
import 'package:ianvs_agent_core/models/chat_session_settings.dart';
import '../acp/acp_session_usage.dart';
import '../acp/agent_event.dart';
import '../acp/agent_session.dart';
import 'package:ianvs_agent_core/models/prompt_attachment.dart';
import '../acp/session_title.dart';
import '../config/assistant_agent_config.dart';
import '../config/acp_client_config.dart' show SessionTemplateConfig;
import '../storage/session_transcript_cache.dart';
import 'connection_state.dart';
import 'package:ianvs_agent_core/models/permission_context.dart';

enum ChatPermissionEventType { requested, resolved }

enum ChatPromptSubmissionResult {
  submitted,
  queued,
  empty,
  busy,
  sessionUnavailable,
  failed,
}

final class SessionLoadMetrics {
  const SessionLoadMetrics({
    required this.cacheReadElapsed,
    required this.restoreElapsed,
    required this.projectionElapsed,
    required this.totalElapsed,
    required this.firstEventElapsed,
    required this.eventSpan,
    required this.cacheHit,
    required this.cacheMessageCount,
    required this.replayedHistory,
    required this.replayEventCount,
  });

  final Duration cacheReadElapsed;
  final Duration restoreElapsed;
  final Duration projectionElapsed;
  final Duration totalElapsed;
  final Duration? firstEventElapsed;
  final Duration? eventSpan;
  final bool cacheHit;
  final int cacheMessageCount;
  final bool? replayedHistory;
  final int replayEventCount;

  Map<String, Object?> toJson() => <String, Object?>{
    'cacheReadMs': cacheReadElapsed.inMicroseconds / 1000,
    'restoreMs': restoreElapsed.inMicroseconds / 1000,
    'projectionMs': projectionElapsed.inMicroseconds / 1000,
    'totalMs': totalElapsed.inMicroseconds / 1000,
    if (firstEventElapsed != null)
      'firstEventMs': firstEventElapsed!.inMicroseconds / 1000,
    if (eventSpan != null) 'eventSpanMs': eventSpan!.inMicroseconds / 1000,
    'cacheHit': cacheHit,
    'cacheMessages': cacheMessageCount,
    'replayedHistory': replayedHistory,
    'replayEvents': replayEventCount,
  };
}

typedef ChatAgentEventObserver =
    FutureOr<void> Function(AgentSession? session, AgentEvent event);

typedef ChatPermissionEventObserver =
    FutureOr<void> Function(ChatPermissionEvent event);

// Conservative carrier accounting: every typed model includes at least a
// 64-byte model node plus 32 bytes per field and space for fixed labels. Real
// List/Map containers and their references are added separately below.
const int _sessionSnapshotHostRetainedBytes = 2048;
const int _agentEventHostRetainedBytes = 320;
const int _sessionModeHostRetainedBytes = 160;
const int _sessionUsageHostRetainedBytes = 224;
const int _sessionSettingsStateHostRetainedBytes = 512;
const int _sessionInfoStateHostRetainedBytes = 320;
const String _genericErrorMessage = 'An unexpected error occurred.';
const int _maxAuthErrorTraversalDepth = 16;
const int _maxAuthErrorTraversalNodes = 256;
const int _maxAuthErrorStringCodeUnits = 64 * 1024;
const int _maxAuthErrorStringCodeUnitsPerValue = 4 * 1024;

final class _AuthValueWork {
  const _AuthValueWork({
    required this.value,
    required this.depth,
    this.knownText,
    this.textWasAlreadyRendered = false,
  });

  final Object? value;
  final int depth;
  final String? knownText;
  final bool textWasAlreadyRendered;
}

final class _AuthIteratorWork {
  const _AuthIteratorWork({
    required this.iterator,
    required this.childDepth,
    required this.yieldsMapEntries,
  });

  final Iterator<dynamic> iterator;
  final int childDepth;
  final bool yieldsMapEntries;
}

final class _AuthRequiredDetector {
  final Set<Object> _seen = HashSet<Object>.identity();
  final Queue<Object> _pending = Queue<Object>();
  int _visitedNodes = 0;
  int _inspectedStringCodeUnits = 0;

  bool contains(
    Object? value, {
    String? knownText,
    bool textWasAlreadyRendered = false,
  }) {
    if (_visitedNodes >= _maxAuthErrorTraversalNodes) return false;
    _pending.addLast(
      _AuthValueWork(
        value: value,
        depth: 0,
        knownText: knownText,
        textWasAlreadyRendered: textWasAlreadyRendered,
      ),
    );
    while (_pending.isNotEmpty && _visitedNodes < _maxAuthErrorTraversalNodes) {
      final work = _pending.removeFirst();
      if (work is _AuthValueWork) {
        _visitedNodes += 1;
        if (_visitValue(work)) {
          _pending.clear();
          return true;
        }
      } else if (work is _AuthIteratorWork) {
        _advanceIterator(work);
      }
    }
    if (_visitedNodes >= _maxAuthErrorTraversalNodes) _pending.clear();
    return false;
  }

  bool _visitValue(_AuthValueWork work) {
    final value = work.value;
    if (work.depth > _maxAuthErrorTraversalDepth || value == null) {
      return false;
    }
    if (!_seen.add(value)) return false;

    if (_containsToken(work.knownText)) return true;
    if (value is String) {
      if (work.textWasAlreadyRendered) return false;
      return _containsToken(value);
    }
    if (value is Map) {
      _enqueueMapIterator(value, work.depth + 1);
      return false;
    }
    if (value is Iterable) {
      _enqueueIterableIterator(value, work.depth + 1);
      return false;
    }

    if (!work.textWasAlreadyRendered && work.knownText == null) {
      if (_containsToken(_guardedToString(value))) return true;
    }
    for (final fieldName in const ['message', 'code', 'cause', 'data']) {
      _pending.addLast(
        _AuthValueWork(
          value: _dynamicField(value, fieldName),
          depth: work.depth + 1,
        ),
      );
    }
    return false;
  }

  void _enqueueMapIterator(Map<dynamic, dynamic> value, int childDepth) {
    try {
      _pending.addLast(
        _AuthIteratorWork(
          iterator: value.entries.iterator,
          childDepth: childDepth,
          yieldsMapEntries: true,
        ),
      );
    } on Object {
      return;
    }
  }

  void _enqueueIterableIterator(Iterable<dynamic> value, int childDepth) {
    try {
      _pending.addLast(
        _AuthIteratorWork(
          iterator: value.iterator,
          childDepth: childDepth,
          yieldsMapEntries: false,
        ),
      );
    } on Object {
      return;
    }
  }

  void _advanceIterator(_AuthIteratorWork work) {
    try {
      if (!work.iterator.moveNext()) return;
      final current = work.iterator.current;
      if (work.yieldsMapEntries) {
        final entry = current as MapEntry<dynamic, dynamic>;
        _pending.addLast(
          _AuthValueWork(value: entry.key, depth: work.childDepth),
        );
        _pending.addLast(
          _AuthValueWork(value: entry.value, depth: work.childDepth),
        );
      } else {
        _pending.addLast(
          _AuthValueWork(value: current, depth: work.childDepth),
        );
      }
      _pending.addLast(work);
    } on Object {
      return;
    }
  }

  bool _containsToken(String? value) {
    if (value == null ||
        _inspectedStringCodeUnits >= _maxAuthErrorStringCodeUnits) {
      return false;
    }
    final remaining = _maxAuthErrorStringCodeUnits - _inspectedStringCodeUnits;
    final perValueLength = value.length < _maxAuthErrorStringCodeUnitsPerValue
        ? value.length
        : _maxAuthErrorStringCodeUnitsPerValue;
    final inspectedLength = perValueLength < remaining
        ? perValueLength
        : remaining;
    _inspectedStringCodeUnits += inspectedLength;
    final inspected = inspectedLength == value.length
        ? value
        : value.substring(0, inspectedLength);
    return inspected.toLowerCase().contains('auth_required');
  }

  String? _guardedToString(Object value) {
    try {
      return value.toString();
    } on Object {
      return null;
    }
  }

  Object? _dynamicField(Object object, String fieldName) {
    try {
      final dynamic value = object;
      return switch (fieldName) {
        'cause' => value.cause,
        'code' => value.code,
        'data' => value.data,
        'message' => value.message,
        _ => null,
      };
    } on Object {
      return null;
    }
  }
}

class ChatPermissionEvent {
  const ChatPermissionEvent.requested(this.request)
    : type = ChatPermissionEventType.requested,
      decision = null,
      decisionSource = null,
      status = ChatPermissionAuditStatus.pending;

  const ChatPermissionEvent.resolved(
    this.request, {
    required this.decision,
    required this.decisionSource,
    required this.status,
  }) : type = ChatPermissionEventType.resolved;

  final ChatPermissionEventType type;
  final ChatPermissionRequest request;
  final ChatPermissionDecision? decision;
  final ChatPermissionDecisionSource? decisionSource;
  final ChatPermissionAuditStatus status;
}

class ArchivedSessionSnapshot {
  ArchivedSessionSnapshot({
    required AgentSession session,
    required bool wasCurrent,
    required List<ChatMessage> messages,
    required List<Map<String, Object?>> availableCommands,
    required Duration? lastLatency,
    required String? lastError,
    required ChatSessionSettings sessionSettings,
    required AcpSessionUsage? sessionUsage,
    required bool sessionSettingsLoading,
    required ConnectionStatus status,
    required int? activeSessionSettingsLoadId,
    bool timelineHistoryWasTruncated = false,
    acp.ChatInputBudget inputBudget = const acp.ChatInputBudget(),
  }) : this._prepared(
         _prepareArchivedSessionSnapshot(
           session: session,
           wasCurrent: wasCurrent,
           messages: messages,
           availableCommands: availableCommands,
           lastLatency: lastLatency,
           lastError: lastError,
           sessionSettings: sessionSettings,
           sessionUsage: sessionUsage,
           sessionSettingsLoading: sessionSettingsLoading,
           status: status,
           activeSessionSettingsLoadId: activeSessionSettingsLoadId,
           timelineHistoryWasTruncated: timelineHistoryWasTruncated,
           inputBudget: inputBudget,
         ),
       );

  ArchivedSessionSnapshot._prepared(_PreparedArchivedSessionSnapshot prepared)
    : session = prepared.session,
      wasCurrent = prepared.wasCurrent,
      messages = prepared.messages,
      availableCommands = prepared.availableCommands,
      lastLatency = prepared.lastLatency,
      lastError = prepared.lastError,
      sessionSettings = prepared.sessionSettings,
      sessionUsage = prepared.sessionUsage,
      sessionSettingsLoading = prepared.sessionSettingsLoading,
      status = prepared.status,
      activeSessionSettingsLoadId = prepared.activeSessionSettingsLoadId,
      timelineHistoryWasTruncated = prepared.timelineHistoryWasTruncated,
      retainedBytes = prepared.retainedBytes;

  bool _leaseIssued = false;
  Object? _leaseOwnerToken;
  int? _leaseId;
  VoidCallback? _releaseLease;

  final AgentSession session;
  final bool wasCurrent;
  final List<ChatMessage> messages;
  final List<Map<String, Object?>> availableCommands;
  final Duration? lastLatency;
  final String? lastError;
  final ChatSessionSettings sessionSettings;
  final AcpSessionUsage? sessionUsage;
  final bool sessionSettingsLoading;
  final ConnectionStatus status;
  final int? activeSessionSettingsLoadId;
  final bool timelineHistoryWasTruncated;
  final int retainedBytes;

  void _attachLease({
    required Object ownerToken,
    required int leaseId,
    required VoidCallback release,
  }) {
    if (_leaseIssued) {
      throw StateError('An archive snapshot lease can only be issued once.');
    }
    _leaseIssued = true;
    _leaseOwnerToken = ownerToken;
    _leaseId = leaseId;
    _releaseLease = release;
  }

  bool _hasActiveLease(Object ownerToken, int leaseId) {
    return _leaseIssued &&
        identical(_leaseOwnerToken, ownerToken) &&
        _leaseId == leaseId &&
        _releaseLease != null;
  }

  bool _consumeLease(Object ownerToken, int leaseId) {
    if (!_hasActiveLease(ownerToken, leaseId)) return false;
    _releaseOnce();
    return true;
  }

  void _releaseOnce() {
    final release = _releaseLease;
    if (release == null) return;
    _releaseLease = null;
    release();
  }

  /// Releases the controller-owned UI-state bytes when undo is no longer
  /// possible. Calling this more than once is harmless.
  void discard() {
    _releaseOnce();
  }
}

final class _PreparedArchivedSessionSnapshot {
  const _PreparedArchivedSessionSnapshot({
    required this.session,
    required this.wasCurrent,
    required this.messages,
    required this.availableCommands,
    required this.lastLatency,
    required this.lastError,
    required this.sessionSettings,
    required this.sessionUsage,
    required this.sessionSettingsLoading,
    required this.status,
    required this.activeSessionSettingsLoadId,
    required this.timelineHistoryWasTruncated,
    required this.retainedBytes,
  });

  final AgentSession session;
  final bool wasCurrent;
  final List<ChatMessage> messages;
  final List<Map<String, Object?>> availableCommands;
  final Duration? lastLatency;
  final String? lastError;
  final ChatSessionSettings sessionSettings;
  final AcpSessionUsage? sessionUsage;
  final bool sessionSettingsLoading;
  final ConnectionStatus status;
  final int? activeSessionSettingsLoadId;
  final bool timelineHistoryWasTruncated;
  final int retainedBytes;
}

_PreparedArchivedSessionSnapshot _prepareArchivedSessionSnapshot({
  required AgentSession session,
  required bool wasCurrent,
  required List<ChatMessage> messages,
  required List<Map<String, Object?>> availableCommands,
  required Duration? lastLatency,
  required String? lastError,
  required ChatSessionSettings sessionSettings,
  required AcpSessionUsage? sessionUsage,
  required bool sessionSettingsLoading,
  required ConnectionStatus status,
  required int? activeSessionSettingsLoadId,
  required bool timelineHistoryWasTruncated,
  required acp.ChatInputBudget inputBudget,
}) {
  inputBudget.validate();
  final prepared = _SessionViewSnapshot(
    session: session,
    messages: messages,
    availableCommands: availableCommands,
    lastLatency: lastLatency,
    lastError: lastError,
    sessionSettings: sessionSettings,
    sessionUsage: sessionUsage,
    sessionSettingsLoading: sessionSettingsLoading,
    status: status,
    activeSessionSettingsLoadId: activeSessionSettingsLoadId,
    timelineHistoryWasTruncated: timelineHistoryWasTruncated,
    inputBudget: inputBudget,
  );
  return _PreparedArchivedSessionSnapshot(
    session: prepared.session,
    wasCurrent: wasCurrent,
    messages: prepared.messages,
    availableCommands: prepared.availableCommands,
    lastLatency: prepared.lastLatency,
    lastError: prepared.lastError,
    sessionSettings: prepared.sessionSettings,
    sessionUsage: prepared.sessionUsage,
    sessionSettingsLoading: prepared.sessionSettingsLoading,
    status: prepared.status,
    activeSessionSettingsLoadId: prepared.activeSessionSettingsLoadId,
    timelineHistoryWasTruncated: prepared.timelineHistoryWasTruncated,
    retainedBytes: prepared.retainedBytes,
  );
}

class _SessionViewSnapshot {
  factory _SessionViewSnapshot({
    required AgentSession session,
    required List<ChatMessage> messages,
    required List<Map<String, Object?>> availableCommands,
    required Duration? lastLatency,
    required String? lastError,
    required ChatSessionSettings sessionSettings,
    required AcpSessionUsage? sessionUsage,
    required bool sessionSettingsLoading,
    required ConnectionStatus status,
    required int? activeSessionSettingsLoadId,
    bool timelineHistoryWasTruncated = false,
    required acp.ChatInputBudget inputBudget,
  }) {
    final frozenMessages = _freezeSnapshotMessages(messages, inputBudget);
    final copiedCommands = _copyAvailableCommands(
      availableCommands,
      inputBudget,
    );
    final copiedSettings = _copySessionSettings(sessionSettings, inputBudget);
    final copiedUsage = _copySessionUsage(sessionUsage);
    final copiedSession = _copyAgentSession(session, inputBudget);
    return _SessionViewSnapshot._(
      session: copiedSession,
      messages: frozenMessages,
      availableCommands: copiedCommands,
      lastLatency: lastLatency,
      lastError: lastError,
      sessionSettings: copiedSettings,
      sessionUsage: copiedUsage,
      sessionSettingsLoading: sessionSettingsLoading,
      status: status,
      activeSessionSettingsLoadId: activeSessionSettingsLoadId,
      timelineHistoryWasTruncated: timelineHistoryWasTruncated,
      retainedBytes: _estimateSessionViewRetainedBytes(
        messages: frozenMessages,
        availableCommands: copiedCommands,
        sessionSettings: copiedSettings,
        sessionUsage: copiedUsage,
        session: copiedSession,
        lastLatency: lastLatency,
        lastError: lastError,
        activeSessionSettingsLoadId: activeSessionSettingsLoadId,
        inputBudget: inputBudget,
      ),
    );
  }

  const _SessionViewSnapshot._({
    required this.session,
    required this.messages,
    required this.availableCommands,
    required this.lastLatency,
    required this.lastError,
    required this.sessionSettings,
    required this.sessionUsage,
    required this.sessionSettingsLoading,
    required this.status,
    required this.activeSessionSettingsLoadId,
    required this.timelineHistoryWasTruncated,
    required this.retainedBytes,
  });

  final AgentSession session;
  final List<ChatMessage> messages;
  final List<Map<String, Object?>> availableCommands;
  final Duration? lastLatency;
  final String? lastError;
  final ChatSessionSettings sessionSettings;
  final AcpSessionUsage? sessionUsage;
  final bool sessionSettingsLoading;
  final ConnectionStatus status;
  final int? activeSessionSettingsLoadId;
  final bool timelineHistoryWasTruncated;
  final int retainedBytes;
}

List<ChatMessage> _freezeSnapshotMessages(
  List<ChatMessage> source,
  acp.ChatInputBudget inputBudget,
) {
  try {
    final length = source.length;
    if (length < 0 || length > inputBudget.maxTimelineItems) {
      return const <ChatMessage>[];
    }
    final snapshot = <ChatMessage>[];
    for (var index = 0; index < length; index += 1) {
      snapshot.add(source[index]);
    }
    if (source.length != length) return const <ChatMessage>[];
    return List<ChatMessage>.unmodifiable(
      snapshot.map(
        (message) => message.projectionCopyForBudget(inputBudget, frozen: true),
      ),
    );
  } on Object {
    return const <ChatMessage>[];
  }
}

AgentSession _copyAgentSession(
  AgentSession session,
  acp.ChatInputBudget inputBudget,
) {
  try {
    return _copyAgentSessionStrict(session, inputBudget);
  } on Object {
    return AgentSession(
      id: session.id,
      cwd: session.cwd,
      createdAt: session.createdAt,
      title: session.title,
      titleOverride: session.titleOverride,
      updatedAt: session.updatedAt,
      agentName: session.agentName,
      sessionTemplateId: session.sessionTemplateId,
      sessionTemplateVersion: session.sessionTemplateVersion,
      pinned: session.pinned,
      archived: session.archived,
      unread: session.unread,
      localUnstarted: session.localUnstarted,
    );
  }
}

AgentSession _copyAgentSessionStrict(
  AgentSession session,
  acp.ChatInputBudget inputBudget,
) {
  final guard = acp.ChatStructuredUpdateGuard(
    budget: inputBudget,
    resource: 'session snapshot',
  );
  guard.consumeContainerNode(field: 'session');
  String? copyOptionalString(String? value, String field) {
    return value == null ? null : guard.copyString(value, field: field);
  }

  final id = guard.copyString(session.id, field: 'session id');
  final cwd = guard.copyString(session.cwd, field: 'session cwd');
  final rawDirectories = session.additionalDirectories;
  final directoryCount = guard.checkCollection(
    rawDirectories,
    field: 'additional directories',
  );
  guard.consumeContainerNode(field: 'additional directories');
  final directories = <String>[];
  for (var index = 0; index < directoryCount; index += 1) {
    guard.consumeEntry(field: 'additional directory');
    directories.add(
      guard.copyString(rawDirectories[index], field: 'additional directory'),
    );
  }
  if (rawDirectories.length != directoryCount) {
    throw const FormatException('Invalid session directory count.');
  }
  final eventsGuard = acp.ChatStructuredUpdateGuard(
    budget: inputBudget,
    resource: 'session initial events',
  )..consumeContainerNode(field: 'session');
  final events = _copyInitialEvents(
    session.initialEvents,
    inputBudget,
    eventsGuard,
  );
  final copied = AgentSession(
    id: id,
    cwd: cwd,
    createdAt: session.createdAt,
    additionalDirectories: List<String>.unmodifiable(directories),
    title: copyOptionalString(session.title, 'session title'),
    titleOverride: copyOptionalString(
      session.titleOverride,
      'session title override',
    ),
    updatedAt: session.updatedAt,
    agentName: copyOptionalString(session.agentName, 'session agent name'),
    sessionTemplateId: copyOptionalString(
      session.sessionTemplateId,
      'session template id',
    ),
    sessionTemplateVersion: session.sessionTemplateVersion,
    initialEvents: events,
    pinned: session.pinned,
    archived: session.archived,
    unread: session.unread,
    localUnstarted: session.localUnstarted,
  );
  _addAgentSessionRetainedBytes(
    0,
    acp.ChatRetainedSizeEstimator(
      budget: _retainedAccountingBudget(inputBudget),
    ),
    copied,
  );
  return copied;
}

List<AgentEvent> _copyInitialEvents(
  List<AgentEvent> source,
  acp.ChatInputBudget inputBudget,
  acp.ChatStructuredUpdateGuard guard,
) {
  final length = guard.checkCollection(source, field: 'initial events');
  guard.consumeContainerNode(field: 'initial events');
  final events = <AgentEvent>[];
  for (var index = 0; index < length; index += 1) {
    final event = source[index];
    final eventType = event.type;
    final eventText = event.text;
    final eventTimestamp = event.timestamp;
    final eventTimestampIsUtc = eventTimestamp?.isUtc ?? false;
    final eventMetadata = event.metadata;
    final rawOmissions = event.omissions;
    guard.consumeEntry(field: 'initial event');
    final text = guard.copyString(eventText, field: 'event text');
    final timestampMicros = eventTimestamp == null
        ? null
        : guard.copyScalar(
                eventTimestamp.microsecondsSinceEpoch,
                field: 'event timestamp',
              )
              as int;
    final timestamp = timestampMicros == null
        ? null
        : DateTime.fromMicrosecondsSinceEpoch(
            timestampMicros,
            isUtc: eventTimestampIsUtc,
          );
    final metadata = projectionCopyChatMessageMetadataWithGuard(
      eventMetadata,
      inputBudget,
      guard,
    );
    final omissionCount = guard.checkCollection(
      rawOmissions,
      field: 'event omissions',
    );
    guard.consumeContainerNode(field: 'event omissions');
    final omissions = <acp.ChatInputOmission>[];
    for (
      var omissionIndex = 0;
      omissionIndex < omissionCount;
      omissionIndex += 1
    ) {
      final omission = rawOmissions[omissionIndex];
      guard.consumeEntry(field: 'event omission');
      final resource = guard.copyString(
        omission.resource,
        field: 'omission resource',
      );
      final truncated =
          guard.copyScalar(omission.truncated, field: 'omission truncated')
              as bool;
      final limit = omission.limit == null
          ? null
          : guard.copyScalar(omission.limit, field: 'omission limit') as int;
      final observedAtLeast = omission.observedAtLeast == null
          ? null
          : guard.copyScalar(
                  omission.observedAtLeast,
                  field: 'omission observed at least',
                )
                as int;
      omissions.add(
        acp.ChatInputOmission(
          reason: omission.reason,
          resource: resource,
          truncated: truncated,
          limit: limit,
          observedAtLeast: observedAtLeast,
        ),
      );
    }
    if (rawOmissions.length != omissionCount) {
      throw const FormatException('Invalid event omission count.');
    }
    events.add(
      AgentEvent(
        type: eventType,
        text: text,
        timestamp: timestamp,
        metadata: metadata,
        omissions: List<acp.ChatInputOmission>.unmodifiable(omissions),
      ),
    );
  }
  if (source.length != length) {
    throw const FormatException('Invalid initial event count.');
  }
  return List<AgentEvent>.unmodifiable(events);
}

List<Map<String, Object?>> _copyAvailableCommands(
  List<Map<String, Object?>> commands,
  acp.ChatInputBudget inputBudget,
) {
  try {
    final copied = acp.ChatStructuredUpdateGuard(
      budget: inputBudget,
      resource: 'available commands snapshot',
    ).copyJsonValue(commands, field: 'commands');
    if (copied is! List) return const <Map<String, Object?>>[];
    final result = <Map<String, Object?>>[];
    for (final command in copied) {
      if (command is! Map<String, Object?>) {
        return const <Map<String, Object?>>[];
      }
      result.add(command);
    }
    return List<Map<String, Object?>>.unmodifiable(result);
  } on Object {
    return const <Map<String, Object?>>[];
  }
}

ChatSessionSettings _copySessionSettings(
  ChatSessionSettings settings,
  acp.ChatInputBudget inputBudget,
) {
  try {
    final guard = acp.ChatStructuredUpdateGuard(
      budget: inputBudget,
      resource: 'session settings snapshot',
    );
    guard.consumeContainerNode(field: 'settings');
    final modesInfo = settings.modes;
    final rawModes = modesInfo.availableModes;
    final modeCount = guard.checkCollection(rawModes, field: 'modes');
    guard.consumeContainerNode(field: 'modes');
    final modes = <ChatSessionMode>[];
    for (var index = 0; index < modeCount; index += 1) {
      final mode = rawModes[index];
      guard.consumeEntry(field: 'mode');
      modes.add(
        ChatSessionMode(
          id: guard.copyString(mode.id, field: 'mode id'),
          name: guard.copyString(mode.name, field: 'mode name'),
        ),
      );
    }
    if (rawModes.length != modeCount) {
      throw const FormatException('Invalid session mode count.');
    }

    final copiedOptions = projectionCopyConfigOptionsWithGuard(
      settings.configOptions,
      guard,
      field: 'config options',
    );

    final rawOmissions = settings.omissions;
    final omissionCount = guard.checkCollection(
      rawOmissions,
      field: 'omissions',
    );
    guard.consumeContainerNode(field: 'omissions');
    final omissions = <acp.ChatInputOmission>[];
    for (var index = 0; index < omissionCount; index += 1) {
      guard.consumeEntry(field: 'omission');
      final omission = rawOmissions[index];
      final truncated =
          guard.copyScalar(omission.truncated, field: 'omission truncated')
              as bool;
      final limit = omission.limit == null
          ? null
          : guard.copyScalar(omission.limit, field: 'omission limit') as int;
      final observedAtLeast = omission.observedAtLeast == null
          ? null
          : guard.copyScalar(
                  omission.observedAtLeast,
                  field: 'omission observed at least',
                )
                as int;
      omissions.add(
        acp.ChatInputOmission(
          reason: omission.reason,
          resource: guard.copyString(
            omission.resource,
            field: 'omission resource',
          ),
          truncated: truncated,
          limit: limit,
          observedAtLeast: observedAtLeast,
        ),
      );
    }
    if (rawOmissions.length != omissionCount) {
      throw const FormatException('Invalid session omission count.');
    }
    final currentModeId = modesInfo.currentModeId;
    final truncated =
        guard.copyScalar(settings.truncated, field: 'settings truncated')
            as bool;
    return ChatSessionSettings(
      modes: ChatSessionModeInfo(
        currentModeId: currentModeId == null
            ? null
            : guard.copyString(currentModeId, field: 'current mode id'),
        availableModes: List<ChatSessionMode>.unmodifiable(modes),
      ),
      configOptions: copiedOptions,
      omissions: List<acp.ChatInputOmission>.unmodifiable(omissions),
      truncated: truncated,
    );
  } on Object {
    return const ChatSessionSettings();
  }
}

AcpSessionUsage? _copySessionUsage(AcpSessionUsage? usage) {
  if (usage == null) return null;
  final cost = usage.cost;
  return AcpSessionUsage(
    used: usage.used,
    size: usage.size,
    cost: cost == null
        ? null
        : AcpSessionUsageCost(amount: cost.amount, currency: cost.currency),
  );
}

int _estimateTimelineRetainedBytes(
  List<ChatMessage> messages, {
  int? precomputedMessageRetainedBytes,
}) {
  var retained = projectionAddRetainedListHostBytes(0, messages.length);
  if (precomputedMessageRetainedBytes case final messageBytes?) {
    return projectionCheckedRetainedAdd(retained, messageBytes);
  }
  for (final message in messages) {
    retained = projectionCheckedRetainedAdd(retained, message.retainedBytes);
  }
  return retained;
}

int _estimateSessionViewRetainedBytes({
  required List<ChatMessage> messages,
  required List<Map<String, Object?>> availableCommands,
  required ChatSessionSettings sessionSettings,
  required AcpSessionUsage? sessionUsage,
  required AgentSession session,
  required Duration? lastLatency,
  required String? lastError,
  required int? activeSessionSettingsLoadId,
  required acp.ChatInputBudget inputBudget,
  int? precomputedTimelineRetainedBytes,
}) {
  final estimator = acp.ChatRetainedSizeEstimator(
    budget: _retainedAccountingBudget(inputBudget),
  );
  var retained = projectionCheckedRetainedAdd(
    _sessionSnapshotHostRetainedBytes,
    precomputedTimelineRetainedBytes ??
        _estimateTimelineRetainedBytes(messages),
  );
  retained = _addAgentSessionRetainedBytes(retained, estimator, session);
  retained = projectionAddEstimatedRetainedBytes(
    retained,
    estimator,
    availableCommands,
  );
  if (lastLatency != null) {
    retained = projectionAddEstimatedRetainedBytes(
      retained,
      estimator,
      lastLatency.inMicroseconds,
    );
  }
  if (lastError != null) {
    retained = projectionAddEstimatedRetainedBytes(
      retained,
      estimator,
      lastError,
    );
  }
  retained = _addSessionSettingsRetainedBytes(
    retained,
    estimator,
    sessionSettings,
  );
  retained = _addSessionUsageRetainedBytes(retained, estimator, sessionUsage);
  if (activeSessionSettingsLoadId != null) {
    retained = projectionAddEstimatedRetainedBytes(
      retained,
      estimator,
      activeSessionSettingsLoadId,
    );
  }
  return retained;
}

acp.ChatInputBudget _retainedAccountingBudget(acp.ChatInputBudget inputBudget) {
  const defaults = acp.ChatInputBudget();
  int atLeastDefault(int value, int fallback) {
    return value < fallback ? fallback : value;
  }

  return acp.ChatInputBudget(
    maxMetadataDepth: atLeastDefault(
      inputBudget.maxMetadataDepth,
      defaults.maxMetadataDepth,
    ),
    maxMetadataNodes: atLeastDefault(
      inputBudget.maxMetadataNodes,
      defaults.maxMetadataNodes,
    ),
    maxMetadataEntries: atLeastDefault(
      inputBudget.maxMetadataEntries,
      defaults.maxMetadataEntries,
    ),
    maxCollectionItems: atLeastDefault(
      inputBudget.maxCollectionItems,
      defaults.maxCollectionItems,
    ),
    maxStructuredStringBytes: atLeastDefault(
      inputBudget.maxStructuredStringBytes,
      defaults.maxStructuredStringBytes,
    ),
  );
}

int _addAgentSessionRetainedBytes(
  int retained,
  acp.ChatRetainedSizeEstimator estimator,
  AgentSession session,
) {
  for (final value in <Object?>[
    session.id,
    session.cwd,
    session.createdAt.microsecondsSinceEpoch,
    session.additionalDirectories,
    if (session.title != null) session.title,
    if (session.titleOverride != null) session.titleOverride,
    if (session.updatedAt != null) session.updatedAt!.microsecondsSinceEpoch,
    if (session.agentName != null) session.agentName,
    if (session.sessionTemplateId != null) session.sessionTemplateId,
    if (session.sessionTemplateVersion != null) session.sessionTemplateVersion,
  ]) {
    retained = projectionAddEstimatedRetainedBytes(retained, estimator, value);
  }
  retained = projectionAddRetainedListHostBytes(
    retained,
    session.initialEvents.length,
  );
  for (final event in session.initialEvents) {
    retained = projectionCheckedRetainedAdd(
      retained,
      _agentEventHostRetainedBytes,
    );
    retained = projectionAddEstimatedRetainedBytes(
      retained,
      estimator,
      event.text,
    );
    if (event.timestamp != null) {
      retained = projectionAddEstimatedRetainedBytes(
        retained,
        estimator,
        event.timestamp!.microsecondsSinceEpoch,
      );
    }
    retained = projectionCheckedRetainedAdd(
      retained,
      projectionEstimateChatMetadataRetainedBytes(estimator, event.metadata),
    );
    retained = projectionAddInputOmissionsRetainedBytes(
      retained,
      estimator,
      event.omissions,
    );
  }
  return retained;
}

int _addSessionSettingsRetainedBytes(
  int retained,
  acp.ChatRetainedSizeEstimator estimator,
  ChatSessionSettings settings,
) {
  if (settings.modes.currentModeId != null) {
    retained = projectionAddEstimatedRetainedBytes(
      retained,
      estimator,
      settings.modes.currentModeId,
    );
  }
  retained = projectionAddRetainedListHostBytes(
    retained,
    settings.modes.availableModes.length,
  );
  for (final mode in settings.modes.availableModes) {
    retained = projectionCheckedRetainedAdd(
      retained,
      _sessionModeHostRetainedBytes,
    );
    retained = projectionAddEstimatedRetainedBytes(
      retained,
      estimator,
      mode.id,
    );
    retained = projectionAddEstimatedRetainedBytes(
      retained,
      estimator,
      mode.name,
    );
  }
  retained = projectionAddConfigOptionsRetainedBytes(
    retained,
    estimator,
    settings.configOptions,
  );
  retained = projectionAddInputOmissionsRetainedBytes(
    retained,
    estimator,
    settings.omissions,
  );
  return retained;
}

int _addSessionUsageRetainedBytes(
  int retained,
  acp.ChatRetainedSizeEstimator estimator,
  AcpSessionUsage? usage,
) {
  if (usage == null) return retained;
  retained = projectionCheckedRetainedAdd(
    retained,
    _sessionUsageHostRetainedBytes,
  );
  retained = projectionAddEstimatedRetainedBytes(
    retained,
    estimator,
    usage.used,
  );
  retained = projectionAddEstimatedRetainedBytes(
    retained,
    estimator,
    usage.size,
  );
  final cost = usage.cost;
  if (cost == null) return retained;
  retained = projectionCheckedRetainedAdd(
    retained,
    _sessionUsageHostRetainedBytes,
  );
  retained = projectionAddEstimatedRetainedBytes(
    retained,
    estimator,
    cost.amount,
  );
  return projectionAddEstimatedRetainedBytes(
    retained,
    estimator,
    cost.currency,
  );
}

class _TurnBudgetState {
  _TurnBudgetState(acp.ChatInputBudget budget)
    : maxItems = budget.maxTurnItems,
      maxRetainedBytes = budget.maxTurnRetainedBytes,
      normalItemLimit = budget.maxTurnItems > 1 ? budget.maxTurnItems - 1 : 0,
      normalRetainedByteLimit = budget.maxTurnRetainedBytes > 1024
          ? budget.maxTurnRetainedBytes - 1024
          : 0,
      text = acp.ChatUtf8LineBudgetCounter(
        maxBytes: budget.maxMessageTextBytes,
        maxLines: budget.maxMessageTextLines,
        resource: 'message text',
      ),
      thought = acp.ChatUtf8LineBudgetCounter(
        maxBytes: budget.maxThoughtTextBytes,
        maxLines: budget.maxMessageTextLines,
        resource: 'thought text',
      );

  final int maxItems;
  final int maxRetainedBytes;
  final int normalItemLimit;
  final int normalRetainedByteLimit;
  final acp.ChatUtf8LineBudgetCounter text;
  final acp.ChatUtf8LineBudgetCounter thought;
  int items = 0;
  int retainedBytes = 0;
  bool overflowed = false;
  bool overflowMarkerPublished = false;
  bool textRootDrained = false;
  bool thoughtRootDrained = false;
  bool textCounterTouched = false;
  bool thoughtCounterTouched = false;
  bool mediaRootDrained = false;
  final Set<String> mediaOmissionKeys = <String>{};
  int mediaBytes = 0;
  int commandStateRetainedBytes = 0;
  int settingsStateRetainedBytes = 0;
  int sessionInfoStateRetainedBytes = 0;
  int usageStateRetainedBytes = 0;
  final Map<ChatMessage, int> messageRetainedBytes =
      HashMap<ChatMessage, int>.identity();
  ChatMessage? textTarget;
  ChatMessage? thoughtTarget;
  _PendingHighSurrogate? textPendingHigh;
  _PendingHighSurrogate? thoughtPendingHigh;
  final Set<ChatMessage> materializationTargets = <ChatMessage>{};
}

class _PendingHighSurrogate {
  const _PendingHighSurrogate({required this.target, required this.codeUnit});

  final ChatMessage target;
  final int codeUnit;
}

class ChatController extends ChangeNotifier {
  ChatController({
    required this.client,
    required this.cwd,
    this.additionalDirectories = const <String>[],
    this.agentName = 'Codex',
    String? sessionPersistenceIdentity,
    this.sessionCatalogSourceKey,
    this.permissionHistoryLimit = defaultPermissionHistoryLimit,
    this.permissionReviewResultEncodedByteLimit =
        defaultPermissionReviewResultEncodedByteLimit,
    this.permissionHistoryEncodedByteLimit =
        defaultPermissionHistoryEncodedByteLimit,
    this.inputBudget = const acp.ChatInputBudget(),
    List<ChatPermissionTrustRule> permissionTrustRules =
        const <ChatPermissionTrustRule>[],
    this.permissionReviewer,
    this.assistantAgentConfig = const AssistantAgentConfig(),
    this.assistantAgentEnhancer,
    this.enableAutomaticSessionTitles = false,
    this.promptIdleWarningDelay = defaultPromptIdleWarningDelay,
    this.sessionTranscriptCache,
  }) : sessionPersistenceIdentity = sessionPersistenceIdentity ?? agentName,
       permissionTrustRules = List.unmodifiable(permissionTrustRules) {
    if (permissionHistoryLimit <= 0) {
      throw ArgumentError.value(
        permissionHistoryLimit,
        'permissionHistoryLimit',
        'must be greater than zero',
      );
    }
    if (permissionReviewResultEncodedByteLimit <
        minimumPermissionReviewResultEncodedByteLimit) {
      throw ArgumentError.value(
        permissionReviewResultEncodedByteLimit,
        'permissionReviewResultEncodedByteLimit',
        'must be at least $minimumPermissionReviewResultEncodedByteLimit',
      );
    }
    if (permissionHistoryEncodedByteLimit <= 0) {
      throw ArgumentError.value(
        permissionHistoryEncodedByteLimit,
        'permissionHistoryEncodedByteLimit',
        'must be greater than zero',
      );
    }
    if (promptIdleWarningDelay <= Duration.zero) {
      throw ArgumentError.value(
        promptIdleWarningDelay,
        'promptIdleWarningDelay',
        'must be greater than zero',
      );
    }
    inputBudget.validate();
    _permissionSubscription = client.permissionRequests.listen(
      _handlePermissionRequest,
      onError: (Object error, StackTrace stackTrace) => _setActionError(error),
      onDone: _handlePermissionRequestsDone,
    );
    _permissionInvalidationSubscription = client.permissionInvalidations.listen(
      _handlePermissionInvalidation,
      onError: (Object error, StackTrace stackTrace) => _setActionError(error),
    );
    _availableCommandsSubscription = client.availableCommandsUpdates.listen(
      _handleAvailableCommandsUpdate,
      onError: (Object error, StackTrace stackTrace) => _setActionError(error),
    );
    if (client case final AcpAgentLifecycleEventSource lifecycleSource) {
      _agentLifecycleSubscription = lifecycleSource.lifecycleEvents.listen(
        _handleAgentLifecycleEvent,
        onError: (Object error, StackTrace stackTrace) =>
            _setActionError(error),
      );
    }
  }

  static const int defaultPermissionHistoryLimit = 500;
  static const Duration defaultCleanupTimeout = Duration(seconds: 2);
  static const Duration defaultPromptIdleWarningDelay = Duration(seconds: 90);

  final AcpAgentClient client;
  final String cwd;
  final List<String> additionalDirectories;
  final String agentName;
  final String sessionPersistenceIdentity;
  final String? sessionCatalogSourceKey;
  final int permissionHistoryLimit;
  final int permissionReviewResultEncodedByteLimit;
  final int permissionHistoryEncodedByteLimit;
  final acp.ChatInputBudget inputBudget;
  final List<ChatPermissionTrustRule> permissionTrustRules;
  final AcpPermissionReviewer? permissionReviewer;
  final AssistantAgentConfig assistantAgentConfig;
  final AssistantAgentEnhancer? assistantAgentEnhancer;
  final bool enableAutomaticSessionTitles;
  final Duration promptIdleWarningDelay;
  final SessionTranscriptCache? sessionTranscriptCache;

  ConnectionStatus status = ConnectionStatus.disconnected;
  AgentSession? _currentSession;
  Object _conversationIdentity = Object();
  Object get conversationIdentity => _conversationIdentity;
  AgentSession? get currentSession => _currentSession;
  set currentSession(AgentSession? value) => _setCurrentSession(value);

  void _setCurrentSession(AgentSession? value, {bool preserveDraft = false}) {
    final previousId = _currentSession?.id.trim();
    final nextId = value?.id.trim();
    if (previousId != nextId) {
      if (!preserveDraft) _conversationIdentity = Object();
      _sessionTemplateWarnings = const <String>[];
    }
    _currentSession = value;
    _requestActiveUiStateRefresh();
  }

  List<String> _sessionTemplateWarnings = const <String>[];
  List<String> get sessionTemplateWarnings => _sessionTemplateWarnings;

  final List<AgentSession> sessions = <AgentSession>[];
  final Object _messageOwnerToken = Object();
  final List<ChatMessage> _messages = <ChatMessage>[];
  late final UnmodifiableListView<ChatMessage> _messagesView =
      UnmodifiableListView<ChatMessage>(_messages);
  UnmodifiableListView<ChatMessage> get messages => _messagesView;
  List<ChatMessage> get visibleMessages =>
      isSessionReplayLoading && !_cachedSessionTranscriptVisible
      ? const <ChatMessage>[]
      : _messagesView;
  SessionLoadMetrics? lastSessionLoadMetrics;
  final List<ChatQueuedPrompt> _queuedPrompts = <ChatQueuedPrompt>[];
  late final UnmodifiableListView<ChatQueuedPrompt> _queuedPromptsView =
      UnmodifiableListView<ChatQueuedPrompt>(_queuedPrompts);
  UnmodifiableListView<ChatQueuedPrompt> get queuedPrompts =>
      _queuedPromptsView;
  int _nextQueuedPromptId = 0;
  bool _dispatchingQueuedPrompt = false;
  bool _guidanceInterruptionRunning = false;
  Completer<void>? _activePromptCompletion;
  int messagesRevision = 0;
  int _nextTurnId = 0;
  int? _activeTurnId;
  int? _pendingEnhancementTurnId;
  String? _pendingEnhancementPrompt;
  String? _pendingEnhancementSessionId;
  final Set<String> _titleEnhancementStartedSessionIds = <String>{};
  int _activeTimelineRetainedBytes = projectionRetainedListHostBytes;
  bool _enforcingTimelineBudget = false;
  List<Map<String, Object?>> _availableCommands =
      const <Map<String, Object?>>[];
  List<Map<String, Object?>> get availableCommands => _availableCommands;
  set availableCommands(List<Map<String, Object?>> commands) {
    _tryReplaceAvailableCommands(commands);
  }

  int _availableCommandsRevision = 0;
  int get availableCommandsRevision => _availableCommandsRevision;
  AcpAgentCapabilities? capabilities;
  ChatSessionSettings _sessionSettings = const ChatSessionSettings();
  ChatSessionSettings get sessionSettings => _sessionSettings;
  set sessionSettings(ChatSessionSettings value) {
    _tryReplaceSessionSettings(value);
  }

  AcpSessionUsage? _sessionUsage;
  AcpSessionUsage? get sessionUsage => _sessionUsage;
  set sessionUsage(AcpSessionUsage? value) {
    _tryReplaceSessionUsage(value);
  }

  ChatPermissionRequest? pendingPermissionRequest;
  ChatToolCallExecutionPolicy toolCallExecutionPolicy =
      ChatToolCallExecutionPolicy.defaultPermissions;
  final List<ChatPermissionAuditEntry> _permissionHistory =
      <ChatPermissionAuditEntry>[];
  final List<int> _permissionHistoryEntryEncodedBytes = <int>[];
  int _permissionHistoryEncodedBytes = 0;
  int _permissionHistoryRevision = 0;
  final LinkedHashSet<String> _permissionHistoryTruncatedSessionIds =
      LinkedHashSet<String>();
  bool _permissionHistoryProvenanceOverflow = false;
  final LinkedHashSet<String> _permissionHistoryOverflowExemptSessionIds =
      LinkedHashSet<String>();
  bool _timelineHistoryWasTruncated = false;
  final Set<String> _resolvingPermissionRequestIds = <String>{};
  final Set<String> _reviewingPermissionRequestIds = <String>{};
  bool _permissionRequestStreamDone = false;
  final LinkedHashSet<String> _retiredSessionIds = LinkedHashSet<String>();
  bool _retiredSessionIdsOverflow = false;
  final Set<String> _localUnstartedSessionIds = <String>{};
  final List<ChatAgentEventObserver> _agentEventObservers =
      <ChatAgentEventObserver>[];
  final List<ChatPermissionEventObserver> _permissionEventObservers =
      <ChatPermissionEventObserver>[];
  final Map<String, _SessionViewSnapshot> _sessionViewSnapshots =
      <String, _SessionViewSnapshot>{};
  int _inactiveSnapshotRetainedBytes = 0;
  final Object _archiveLeaseOwnerToken = Object();
  final Map<int, ArchivedSessionSnapshot> _archiveLeasesById =
      <int, ArchivedSessionSnapshot>{};
  int _nextArchiveLeaseId = 0;
  int _archivedLeaseRetainedBytes = 0;
  int _activeUiStateRetainedBytes = 0;
  int _uiStateTransactionDepth = 0;
  bool _uiStateRefreshPending = false;
  bool _uiStateNotificationPending = false;
  bool _enforcingUiStateBudget = false;
  String? _lastError;
  String? get lastError => _lastError;
  set lastError(String? value) {
    _lastError = value;
    _requestActiveUiStateRefresh();
  }

  bool isStreaming = false;
  bool _promptAppearsStalled = false;
  bool get promptAppearsStalled => _promptAppearsStalled;
  bool sessionSettingsLoading = false;
  bool isSessionOperationRunning = false;
  NewSessionStage? newSessionStage;

  void _setNewSessionStage(NewSessionStage? stage) {
    newSessionStage = stage;
    if (!_isDisposed) _notifyListeners();
  }

  Completer<void>? _sessionOperationIdleCompleter;
  bool isSessionReplayLoading = false;
  bool _cachedSessionTranscriptVisible = false;
  bool _isDisposed = false;
  bool _changeNotifierDisposed = false;
  int _notificationDepth = 0;
  Future<void>? _disposalFuture;
  int _nextPermissionRequestGeneration = 0;
  _TurnBudgetState? _turnBudget;
  bool _streamingNotificationPending = false;
  bool _trackingAgentEvent = false;
  bool _suppressAgentEventProjection = false;
  bool _eventPayloadAccepted = false;
  String _eventAcceptedText = '';
  bool _eventHasMessageProjection = false;
  Map<String, Object?> _eventAcceptedMetadata = const <String, Object?>{};
  List<acp.ChatInputOmission> _eventAcceptedOmissions =
      const <acp.ChatInputOmission>[];
  acp.ChatInputOmission? _eventAcceptedTextOmission;
  acp.ChatInputOmission? _eventRootOmission;

  bool get supportsSessionClose => capabilities?.session.close == true;

  bool get supportsSessionDelete => capabilities?.session.delete == true;

  bool get supportsSessionFork => capabilities?.session.fork == true;

  bool get supportsSessionList => capabilities?.session.list == true;

  bool get supportsSessionResume {
    return capabilities?.loadSession == true ||
        capabilities?.session.resume == true;
  }

  bool get supportsAuthLogout => capabilities?.auth.logout == true;

  bool get hasPermissionReviewer => permissionReviewer != null;

  @visibleForTesting
  int get debugCurrentTurnItems => _turnBudget?.items ?? 0;

  @visibleForTesting
  int get debugCurrentTurnRetainedBytes => _turnBudget?.retainedBytes ?? 0;

  @visibleForTesting
  bool get debugTurnOverflowed => _turnBudget?.overflowed ?? false;

  @visibleForTesting
  bool get debugTurnTextCounterTouched =>
      _turnBudget?.textCounterTouched ?? false;

  @visibleForTesting
  List<String> get debugInactiveSnapshotIds =>
      List<String>.unmodifiable(_sessionViewSnapshots.keys);

  @visibleForTesting
  int get debugUiStateRetainedBytes => projectionCheckedRetainedAdd(
    projectionCheckedRetainedAdd(
      _activeUiStateRetainedBytes,
      _inactiveSnapshotRetainedBytes,
    ),
    _archivedLeaseRetainedBytes,
  );

  @visibleForTesting
  int get debugActiveUiStateRetainedBytes => _activeUiStateRetainedBytes;

  @visibleForTesting
  int get debugActiveTimelineRetainedBytes => _activeTimelineRetainedBytes;

  @visibleForTesting
  void touchInactiveSnapshotForTesting(String sessionId) {
    _touchSessionViewSnapshot(sessionId);
  }

  String? get currentModelValue => sessionSettings.modelOption?.currentValue;

  String? get currentReasoningEffortValue {
    return sessionSettings.reasoningEffortOption?.currentValue;
  }

  List<Map<String, Object?>> get authMethods {
    return capabilities?.authMethods
            .where((method) => _stringFromMap(method, 'id').isNotEmpty)
            .toList(growable: false) ??
        const <Map<String, Object?>>[];
  }

  bool get canAuthenticate {
    return authMethods.isNotEmpty && !isStreaming && !isSessionOperationRunning;
  }

  bool get canForkCurrentSession {
    return currentSession != null &&
        supportsSessionFork &&
        !isStreaming &&
        !isSessionOperationRunning;
  }

  bool get canCloseCurrentSession {
    final session = currentSession;
    return session != null && canCloseSession(session);
  }

  bool get canDeleteCurrentSession {
    final session = currentSession;
    return session != null && canDeleteSession(session);
  }

  bool canCloseSession(AgentSession session) {
    return supportsSessionClose &&
        !isStreaming &&
        !isSessionOperationRunning &&
        _sessionForTargetedAction(session) != null;
  }

  bool canDeleteSession(AgentSession session) {
    return supportsSessionDelete &&
        !isStreaming &&
        !isSessionOperationRunning &&
        _sessionForTargetedAction(session) != null;
  }

  bool get canListSessions {
    return !isStreaming &&
        !isSessionOperationRunning &&
        (status == ConnectionStatus.disconnected ||
            status == ConnectionStatus.error ||
            supportsSessionList);
  }

  bool get canResumeSessions {
    return !isStreaming &&
        !isSessionOperationRunning &&
        (status == ConnectionStatus.disconnected ||
            status == ConnectionStatus.error ||
            (supportsSessionList && supportsSessionResume));
  }

  /// Whether [sessionId] can be activated from controller-owned state without
  /// asking the ACP agent to restore its transcript.
  bool canActivateSessionLocally(String sessionId) {
    final normalizedSessionId = sessionId.trim();
    if (normalizedSessionId.isEmpty ||
        isStreaming ||
        isSessionOperationRunning) {
      return false;
    }
    if (_sessionViewSnapshotWithId(normalizedSessionId) != null) return true;
    return _sessionWithId(normalizedSessionId) != null &&
        _isLocalUnstartedSessionId(normalizedSessionId);
  }

  bool get canLogout {
    return supportsAuthLogout && !isStreaming && !isSessionOperationRunning;
  }

  Future<void> waitForSessionOperationIdle() async {
    while (isSessionOperationRunning) {
      final idle = _sessionOperationIdleCompleter;
      if (idle == null) {
        await Future<void>.delayed(Duration.zero);
        continue;
      }
      await idle.future;
    }
  }

  List<ChatPermissionAuditEntry> get permissionHistory {
    return List.unmodifiable(_permissionHistory);
  }

  int get permissionHistoryRevision => _permissionHistoryRevision;

  bool get permissionHistoryWasTruncated {
    final sessionId = currentSession?.id.trim();
    return sessionId != null &&
        sessionId.isNotEmpty &&
        _permissionHistoryWasTruncatedForNormalizedSession(sessionId);
  }

  bool permissionHistoryWasTruncatedForSession(String sessionId) {
    final normalizedSessionId = sessionId.trim();
    return normalizedSessionId.isNotEmpty &&
        _permissionHistoryWasTruncatedForNormalizedSession(normalizedSessionId);
  }

  bool _permissionHistoryWasTruncatedForNormalizedSession(String sessionId) {
    return _permissionHistoryTruncatedSessionIds.contains(sessionId) ||
        (_permissionHistoryProvenanceOverflow &&
            !_permissionHistoryOverflowExemptSessionIds.contains(sessionId));
  }

  bool get timelineHistoryWasTruncated =>
      currentSession != null &&
      (_timelineHistoryWasTruncated || _messages.any(_isHistoryMarker));

  int get permissionHistoryEncodedBytes => _permissionHistoryEncodedBytes;

  StreamSubscription<AgentEvent>? _promptSubscription;
  Timer? _promptIdleWarningTimer;
  late final StreamSubscription<ChatPermissionRequest> _permissionSubscription;
  late final StreamSubscription<ChatPermissionInvalidation>
  _permissionInvalidationSubscription;
  late final StreamSubscription<AcpAvailableCommandsUpdate>
  _availableCommandsSubscription;
  StreamSubscription<AcpAgentLifecycleEvent>? _agentLifecycleSubscription;
  DateTime? _lastPromptStartedAt;
  Duration? _lastLatency;
  Duration? get lastLatency => _lastLatency;
  set lastLatency(Duration? value) {
    _lastLatency = value;
    _requestActiveUiStateRefresh();
  }

  int _sessionSettingsLoadSerial = 0;
  int _availableCommandsLoadSerial = 0;
  int _sessionOperationGeneration = 0;
  int? _pendingSessionSetupGeneration;
  int? __activeSessionSettingsLoadId;
  int? get _activeSessionSettingsLoadId => __activeSessionSettingsLoadId;
  set _activeSessionSettingsLoadId(int? value) {
    __activeSessionSettingsLoadId = value;
    _requestActiveUiStateRefresh();
  }

  int _beginSessionOperationGeneration() => ++_sessionOperationGeneration;

  bool _isCurrentSessionOperationGeneration(int generation) {
    return !_isDisposed && generation == _sessionOperationGeneration;
  }

  Future<void> connect() async {
    if (isSessionOperationRunning) return;
    await _runSessionOperation(() async {
      await _connectWithStatus(ConnectionStatus.connecting);
    });
  }

  VoidCallback addAgentEventObserver(ChatAgentEventObserver observer) {
    _agentEventObservers.add(observer);
    return () => _agentEventObservers.remove(observer);
  }

  VoidCallback addPermissionEventObserver(
    ChatPermissionEventObserver observer,
  ) {
    _permissionEventObservers.add(observer);
    return () => _permissionEventObservers.remove(observer);
  }

  Future<bool> newSession({
    String? cwd,
    SessionTemplateConfig? template,
    bool preserveDraft = false,
  }) async {
    if (isStreaming || isSessionOperationRunning) return false;
    _finishTurnBudget();
    final workspaceCwd = cwd == null || cwd.trim().isEmpty
        ? this.cwd
        : cwd.trim();
    var created = false;
    final operationGeneration = _beginSessionOperationGeneration();
    await _runSessionOperation(() async {
      try {
        if (status == ConnectionStatus.disconnected ||
            status == ConnectionStatus.error) {
          _setNewSessionStage(NewSessionStage.connecting);
          await _connectWithStatus(ConnectionStatus.connecting);
          if (!_isCurrentSessionOperationGeneration(operationGeneration)) {
            return;
          }
          if (status == ConnectionStatus.error) return;
        }
        _pendingSessionSetupGeneration = operationGeneration;
        _setNewSessionStage(NewSessionStage.creating);
        late final AgentSession remoteSession;
        try {
          remoteSession = await client.createSession(
            cwd: workspaceCwd,
            additionalDirectories: additionalDirectories,
          );
        } finally {
          if (_pendingSessionSetupGeneration == operationGeneration) {
            _pendingSessionSetupGeneration = null;
          }
        }
        _cancelPendingPermissionOutsideSession(remoteSession.id);
        if (!_isCurrentSessionOperationGeneration(operationGeneration)) return;
        final createdSession = _copyAgentSessionStrict(
          remoteSession.copyWith(
            agentName: agentName,
            localUnstarted: true,
            sessionTemplateId: template?.id,
            sessionTemplateVersion: template?.version,
          ),
          inputBudget,
        );
        final initialEvents = createdSession.initialEvents;
        final session = createdSession.copyWith(
          initialEvents: const <AgentEvent>[],
        );
        await _runUiStateTransaction(() {
          _snapshotCurrentSession();
          _retiredSessionIds.remove(session.id);
          _markPermissionHistoryCompleteForSession(session.id);
          _setCurrentSession(session, preserveDraft: preserveDraft);
          _timelineHistoryWasTruncated = false;
          _upsertSession(session);
          _clearMessages();
          availableCommands = const <Map<String, Object?>>[];
          lastLatency = null;
          lastError = null;
          sessionSettings = const ChatSessionSettings();
          sessionUsage = null;
          _sessionTemplateWarnings = const <String>[];
          sessionSettingsLoading = false;
          _activeSessionSettingsLoadId = null;
          for (final event in initialEvents) {
            _handleAgentEvent(event, notify: false);
          }
          if (messages.isEmpty) {
            _addLocalUnstartedSessionId(session.id);
          } else {
            _removeLocalUnstartedSessionId(session.id);
          }
          _finishTurnBudget();
        });
        if (!_isCurrentSessionOperationGeneration(operationGeneration)) return;
        _setNewSessionStage(NewSessionStage.configuring);
        await _loadAvailableCommands(session.id, notify: false);
        if (!_isCurrentSessionOperationGeneration(operationGeneration)) return;
        if (messages.isEmpty) {
          _addLocalUnstartedSessionId(session.id);
        } else {
          _removeLocalUnstartedSessionId(session.id);
        }
        if (status != ConnectionStatus.error) {
          status = ConnectionStatus.sessionReady;
          created = _sessionIdsMatch(currentSession?.id, session.id);
        }
        _notifyListeners();
        await _loadSessionSettings(session.id, notify: false);
        if (!_isCurrentSessionOperationGeneration(operationGeneration)) return;
        if (template != null) {
          _setNewSessionStage(NewSessionStage.applyingTemplate);
          _sessionTemplateWarnings = await _applySessionTemplateSettings(
            session.id,
            template,
          );
          if (!_isCurrentSessionOperationGeneration(operationGeneration)) {
            return;
          }
        }
        _notifyListeners();
      } catch (error) {
        if (!_isCurrentSessionOperationGeneration(operationGeneration)) return;
        _cancelPendingPermissionOutsideSession(currentSession?.id);
        _setError(error);
      } finally {
        _setNewSessionStage(null);
      }
    });
    return created;
  }

  Future<List<String>> _applySessionTemplateSettings(
    String sessionId,
    SessionTemplateConfig template,
  ) async {
    final warnings = <String>[];
    final requestedMode = template.mode?.trim();
    if (requestedMode != null && requestedMode.isNotEmpty) {
      if (!sessionSettings.shouldUseModeFallback) {
        warnings.add(
          'Mode "$requestedMode" was not applied because this agent uses config options.',
        );
      } else if (!sessionSettings.modes.availableModes.any(
        (mode) => mode.id == requestedMode,
      )) {
        warnings.add('Mode "$requestedMode" is not exposed by this session.');
      } else {
        try {
          final didSet = await client.setSessionMode(
            sessionId: sessionId,
            modeId: requestedMode,
          );
          if (didSet && _isActiveSession(sessionId)) {
            sessionSettings = sessionSettings.withCurrentMode(requestedMode);
          } else if (!didSet) {
            warnings.add('The agent rejected mode "$requestedMode".');
          }
        } catch (_) {
          warnings.add('Mode "$requestedMode" could not be applied.');
        }
      }
    }

    Future<void> applyOption({
      required String label,
      required String? requested,
      required ChatConfigOption? option,
    }) async {
      final value = requested?.trim();
      if (value == null || value.isEmpty) return;
      if (option == null) {
        warnings.add('$label "$value" is not exposed by this session.');
        return;
      }
      if (option.options.isNotEmpty &&
          !option.options.any((choice) => choice.value == value)) {
        warnings.add('$label "$value" is not offered by this session.');
        return;
      }
      try {
        final options = await client.setConfigOption(
          sessionId: sessionId,
          configId: option.id,
          value: value,
        );
        if (!_isActiveSession(sessionId)) return;
        final updatedOptions = options.isEmpty
            ? _configOptionsWithOverride(option.id, value)
            : options;
        sessionSettings = sessionSettings.withPreferredConfigOptions(
          updatedOptions,
        );
      } catch (_) {
        warnings.add('$label "$value" could not be applied.');
      }
    }

    await applyOption(
      label: 'Model',
      requested: template.model,
      option: sessionSettings.modelOption,
    );
    await applyOption(
      label: 'Reasoning effort',
      requested: template.reasoningEffort,
      option: sessionSettings.reasoningEffortOption,
    );
    return List<String>.unmodifiable(warnings);
  }

  Future<void> resumeSession(
    String sessionId, {
    String? cwd,
    List<String>? additionalDirectories,
    String? title,
    DateTime? updatedAt,
  }) async {
    final trimmedSessionId = sessionId.trim();
    if (trimmedSessionId.isEmpty || isStreaming || isSessionOperationRunning) {
      return;
    }
    final explicitCwd = cwd?.trim();
    final boundSession = _boundSessionWithId(trimmedSessionId);
    final workspaceCwd = explicitCwd == null || explicitCwd.isEmpty
        ? boundSession?.cwd ?? this.cwd
        : explicitCwd;
    final workspaceAdditionalDirectories =
        additionalDirectories ??
        boundSession?.additionalDirectories ??
        this.additionalDirectories;
    if (boundSession != null &&
        !sessionWorkspaceIdentityMatches(
          boundSession,
          sessionId: trimmedSessionId,
          cwd: workspaceCwd,
          additionalDirectories: workspaceAdditionalDirectories,
        )) {
      _setActionError(
        StateError(sessionWorkspaceConflictMessage(trimmedSessionId)),
        preserveConnectionStatus: true,
      );
      return;
    }
    final activeSession = currentSession;
    if (activeSession != null && activeSession.id.trim() == trimmedSessionId) {
      return;
    }
    _finishTurnBudget();
    final totalLoadTimer = Stopwatch()..start();
    final transcriptIdentity = updatedAt == null
        ? null
        : SessionTranscriptIdentity(
            agentName: sessionPersistenceIdentity,
            sessionId: trimmedSessionId,
            cwd: workspaceCwd,
            additionalDirectories: List<String>.unmodifiable(
              workspaceAdditionalDirectories,
            ),
            updatedAt: updatedAt,
          );
    final transcriptCacheFuture = _loadCachedSessionTranscript(
      transcriptIdentity,
    );

    final operationGeneration = _beginSessionOperationGeneration();
    await _runSessionOperation(() async {
      final previousSession = currentSession;
      final previousSessions = List<AgentSession>.from(sessions);
      final previousMessages = List<ChatMessage>.from(messages);
      final previousAvailableCommands = availableCommands;
      final previousLastLatency = lastLatency;
      final previousSessionSettings = sessionSettings;
      final previousSessionUsage = sessionUsage;
      final previousSessionSettingsLoading = sessionSettingsLoading;
      final previousSettingsLoadId = _activeSessionSettingsLoadId;
      final previousSessionReplayLoading = isSessionReplayLoading;
      final previousCachedSessionTranscriptVisible =
          _cachedSessionTranscriptVisible;
      final previousTimelineHistoryWasTruncated = _timelineHistoryWasTruncated;
      final previousSessionLoadMetrics = lastSessionLoadMetrics;
      final previousSessionViewSnapshots = Map<String, _SessionViewSnapshot>.of(
        _sessionViewSnapshots,
      );
      final previousInactiveSnapshotRetainedBytes =
          _inactiveSnapshotRetainedBytes;
      _SessionViewSnapshot? targetSnapshot;
      try {
        await _promptSubscription?.cancel();
        if (!_isCurrentSessionOperationGeneration(operationGeneration)) return;
        _promptSubscription = null;
        if (status == ConnectionStatus.disconnected ||
            status == ConnectionStatus.error) {
          await _connectWithStatus(ConnectionStatus.connecting);
          if (!_isCurrentSessionOperationGeneration(operationGeneration)) {
            return;
          }
          if (status == ConnectionStatus.error) return;
        }

        final existingSession = _sessionWithId(trimmedSessionId);
        targetSnapshot = _takeSessionViewSnapshot(trimmedSessionId);
        var activatedLocal = false;
        var loadLocalSettings = false;
        await _runUiStateTransaction(() {
          lastSessionLoadMetrics = null;
          _snapshotCurrentSession();
          if (targetSnapshot case final snapshot?) {
            _activateSessionViewSnapshot(
              snapshot,
              cwd: boundSession == null ? explicitCwd : null,
              additionalDirectories: boundSession == null
                  ? additionalDirectories
                  : null,
              title: title,
              updatedAt: updatedAt,
            );
            activatedLocal = true;
            return;
          }
          if (existingSession != null &&
              _isLocalUnstartedSessionId(trimmedSessionId)) {
            _activateLocalUnstartedSession(
              existingSession,
              cwd: boundSession == null ? explicitCwd : null,
              additionalDirectories: boundSession == null
                  ? additionalDirectories
                  : null,
              title: title,
              updatedAt: updatedAt,
            );
            activatedLocal = true;
            loadLocalSettings = true;
            return;
          }
          status = ConnectionStatus.reconnecting;
          isStreaming = false;
          lastError = null;
          _timelineHistoryWasTruncated = false;
          _clearMessages();
          availableCommands = const <Map<String, Object?>>[];
          lastLatency = null;
          sessionSettings = const ChatSessionSettings();
          sessionUsage = null;
          sessionSettingsLoading = false;
          _activeSessionSettingsLoadId = null;
          _cachedSessionTranscriptVisible = false;
          final session = _copyAgentSessionStrict(
            AgentSession(
              id: trimmedSessionId,
              cwd: workspaceCwd,
              createdAt: existingSession?.createdAt ?? DateTime.now(),
              additionalDirectories: workspaceAdditionalDirectories,
              title: title ?? existingSession?.title,
              titleOverride: existingSession?.titleOverride,
              updatedAt: updatedAt,
              agentName: agentName,
              sessionTemplateId:
                  boundSession?.sessionTemplateId ??
                  existingSession?.sessionTemplateId,
              sessionTemplateVersion:
                  boundSession?.sessionTemplateVersion ??
                  existingSession?.sessionTemplateVersion,
              pinned: existingSession?.pinned ?? false,
              archived: false,
              unread: false,
            ),
            inputBudget,
          );
          _retiredSessionIds.remove(session.id);
          currentSession = session;
          _upsertSession(session);
          _cancelPendingPermissionOutsideSession(session.id);
          isSessionReplayLoading = true;
        });
        if (!_isCurrentSessionOperationGeneration(operationGeneration)) return;
        if (activatedLocal) {
          await _loadAvailableCommands(
            trimmedSessionId,
            notify: !loadLocalSettings,
          );
          if (!_isCurrentSessionOperationGeneration(operationGeneration)) {
            return;
          }
          if (loadLocalSettings) {
            await _loadSessionSettings(trimmedSessionId, notify: false);
            if (!_isCurrentSessionOperationGeneration(operationGeneration)) {
              return;
            }
            if (status != ConnectionStatus.error) {
              status = ConnectionStatus.sessionReady;
            }
            _notifyListeners();
          }
          return;
        }
        _notifyListeners();
        await Future<void>.delayed(Duration.zero);
        if (!_isCurrentSessionOperationGeneration(operationGeneration)) return;

        final cacheResult = await transcriptCacheFuture;
        if (!_isCurrentSessionOperationGeneration(operationGeneration)) return;
        final cachedMessages = cacheResult.snapshot == null
            ? null
            : await _chatMessagesFromTranscript(
                cacheResult.snapshot!,
                operationGeneration: operationGeneration,
              );
        if (!_isCurrentSessionOperationGeneration(operationGeneration)) return;
        final cacheHit =
            cachedMessages != null &&
            cachedMessages.isNotEmpty &&
            client.capabilities?.session.resume == true;
        if (cacheHit) {
          _timelineHistoryWasTruncated =
              cacheResult.snapshot!.timelineHistoryWasTruncated;
          _replaceAllMessages(cachedMessages);
          _cachedSessionTranscriptVisible = true;
          // This is the complete transcript for the exact catalog revision,
          // not a recent-message preview. Make it visible atomically while
          // session/resume finishes reconnecting in the background.
          _notifyListeners();
        }

        final projectionTimer = Stopwatch();
        Duration? firstEventElapsed;
        Duration? lastEventElapsed;
        _finishTurnBudget();
        final restoreTimer = Stopwatch()..start();
        final restore = await client.restoreSession(
          sessionId: trimmedSessionId,
          cwd: workspaceCwd,
          additionalDirectories: workspaceAdditionalDirectories,
          replayHistory: !cacheHit,
          onEvent: (event) {
            if (!_isCurrentSessionOperationGeneration(operationGeneration)) {
              return;
            }
            firstEventElapsed ??= totalLoadTimer.elapsed;
            lastEventElapsed = totalLoadTimer.elapsed;
            projectionTimer.start();
            try {
              _handleAgentEvent(event, notify: false);
            } finally {
              projectionTimer.stop();
            }
          },
        );
        restoreTimer.stop();
        if (!_isCurrentSessionOperationGeneration(operationGeneration)) return;
        if (cacheHit && restore.replayedHistory != false) {
          throw StateError(
            'Session resume unexpectedly replayed history after a transcript '
            'cache hit.',
          );
        }
        _removeLocalUnstartedSessionId(trimmedSessionId);
        projectionTimer.start();
        try {
          _finishTurnBudget();
        } finally {
          projectionTimer.stop();
        }
        final replayedHistory = restore.replayedHistory;
        if (!_isCurrentSessionOperationGeneration(operationGeneration)) return;
        await _loadAvailableCommands(trimmedSessionId, notify: false);
        if (!_isCurrentSessionOperationGeneration(operationGeneration)) return;
        await _loadSessionSettings(trimmedSessionId, notify: false);
        if (!_isCurrentSessionOperationGeneration(operationGeneration)) return;
        isSessionReplayLoading = false;
        _cachedSessionTranscriptVisible = false;
        if (status != ConnectionStatus.error) {
          status = ConnectionStatus.sessionReady;
        }
        totalLoadTimer.stop();
        lastSessionLoadMetrics = SessionLoadMetrics(
          cacheReadElapsed: cacheResult.elapsed,
          restoreElapsed: restoreTimer.elapsed,
          projectionElapsed: projectionTimer.elapsed,
          totalElapsed: totalLoadTimer.elapsed,
          firstEventElapsed: firstEventElapsed,
          eventSpan: firstEventElapsed == null || lastEventElapsed == null
              ? null
              : lastEventElapsed! - firstEventElapsed!,
          cacheHit: cacheHit && replayedHistory == false,
          cacheMessageCount: cacheHit ? cachedMessages.length : 0,
          replayedHistory: replayedHistory,
          replayEventCount: restore.eventCount,
        );
        if (kDebugMode && totalLoadTimer.elapsedMilliseconds >= 100) {
          debugPrint('[session-load] ${lastSessionLoadMetrics!.toJson()}');
        }
        _notifyListeners();
        if (replayedHistory == true && transcriptIdentity != null) {
          unawaited(
            _saveCachedSessionTranscript(
              transcriptIdentity,
              List<ChatMessage>.of(_messages),
              timelineHistoryWasTruncated: _timelineHistoryWasTruncated,
            ),
          );
        }
      } catch (error) {
        if (!_isCurrentSessionOperationGeneration(operationGeneration)) return;
        await _runUiStateTransaction(() {
          for (final sessionId in _sessionViewSnapshots.keys) {
            _releaseLocalSessionView(sessionId);
          }
          _sessionViewSnapshots
            ..clear()
            ..addAll(previousSessionViewSnapshots);
          for (final sessionId in previousSessionViewSnapshots.keys) {
            _retainLocalSessionView(sessionId);
          }
          if (previousSession != null) {
            _retainLocalSessionView(previousSession.id);
          }
          _inactiveSnapshotRetainedBytes =
              previousInactiveSnapshotRetainedBytes;
          currentSession = previousSession;
          _cancelPendingPermissionOutsideSession(previousSession?.id);
          sessions
            ..clear()
            ..addAll(previousSessions);
          _replaceAllMessages(previousMessages);
          availableCommands = previousAvailableCommands;
          lastLatency = previousLastLatency;
          sessionSettings = previousSessionSettings;
          sessionUsage = previousSessionUsage;
          sessionSettingsLoading = previousSessionSettingsLoading;
          _activeSessionSettingsLoadId = previousSettingsLoadId;
          isSessionReplayLoading = previousSessionReplayLoading;
          _cachedSessionTranscriptVisible =
              previousCachedSessionTranscriptVisible;
          lastSessionLoadMetrics = previousSessionLoadMetrics;
          _timelineHistoryWasTruncated = previousTimelineHistoryWasTruncated;
        });
        _setError(error);
      }
    });
  }

  Future<({SessionTranscriptSnapshot? snapshot, Duration elapsed})>
  _loadCachedSessionTranscript(SessionTranscriptIdentity? identity) async {
    final cache = sessionTranscriptCache;
    if (identity == null || cache == null) {
      return (snapshot: null, elapsed: Duration.zero);
    }
    final timer = Stopwatch()..start();
    try {
      final loaded = await cache.load(identity);
      final snapshot = loaded != null && loaded.identity.matches(identity)
          ? loaded
          : null;
      timer.stop();
      return (snapshot: snapshot, elapsed: timer.elapsed);
    } on Object {
      timer.stop();
      return (snapshot: null, elapsed: timer.elapsed);
    }
  }

  Future<List<ChatMessage>?> _chatMessagesFromTranscript(
    SessionTranscriptSnapshot snapshot, {
    required int operationGeneration,
  }) async {
    try {
      final restored = <ChatMessage>[];
      final sliceTimer = Stopwatch()..start();
      for (final raw in snapshot.messages) {
        final role = switch (raw['role']) {
          'user' => ChatMessageRole.user,
          'assistant' => ChatMessageRole.assistant,
          'tool' => ChatMessageRole.tool,
          'error' => ChatMessageRole.error,
          'status' => ChatMessageRole.status,
          _ => throw const FormatException('Invalid cached message role.'),
        };
        final text = raw['text'];
        final timestamp = raw['timestamp'];
        final rawMetadata = raw['metadata'];
        final rawOmissions = raw['omissions'];
        if (text is! String ||
            timestamp is! String ||
            rawMetadata is! Map ||
            rawOmissions is! List) {
          return null;
        }
        final parsedTimestamp = DateTime.tryParse(timestamp);
        if (parsedTimestamp == null) return null;
        final omissions = <acp.ChatInputOmission>[];
        for (final rawOmission in rawOmissions) {
          if (rawOmission is! Map) return null;
          final reason = switch (rawOmission['reason']) {
            'input_limit' => acp.ChatInputOmissionReason.inputLimit,
            'invalid_encoding' => acp.ChatInputOmissionReason.invalidEncoding,
            'invalid_image' => acp.ChatInputOmissionReason.invalidImage,
            'invalid_structure' => acp.ChatInputOmissionReason.invalidStructure,
            _ => null,
          };
          final resource = rawOmission['resource'];
          final truncated = rawOmission['truncated'];
          if (reason == null || resource is! String || truncated is! bool) {
            return null;
          }
          omissions.add(
            acp.ChatInputOmission(
              reason: reason,
              resource: resource,
              truncated: truncated,
              limit: rawOmission['limit'] as int?,
              observedAtLeast: rawOmission['observedAtLeast'] as int?,
            ),
          );
        }
        final message = ChatMessage(
          role: role,
          text: text,
          timestamp: parsedTimestamp,
          metadata: <String, Object?>{
            for (final entry in rawMetadata.entries)
              if (entry.key is String) entry.key as String: entry.value,
          },
          omissions: omissions,
          inputBudget: inputBudget,
        );
        final turnId = raw['turnId'];
        if (turnId is int && turnId > 0) message.projectionTurnId = turnId;
        restored.add(message);
        if (sliceTimer.elapsed >= const Duration(milliseconds: 4)) {
          // Cache validation and metadata guarding can traverse tens of MiB.
          // Yield on a frame-sized budget so loading never becomes one long
          // synchronous UI-isolate task.
          await Future<void>.delayed(Duration.zero);
          if (!_isCurrentSessionOperationGeneration(operationGeneration)) {
            return null;
          }
          sliceTimer.reset();
        }
      }
      return restored;
    } on Object {
      return null;
    }
  }

  Future<void> _saveCachedSessionTranscript(
    SessionTranscriptIdentity identity,
    List<ChatMessage> sourceMessages, {
    required bool timelineHistoryWasTruncated,
  }) async {
    final cache = sessionTranscriptCache;
    if (cache == null || sourceMessages.isEmpty) return;
    await Future<void>.delayed(Duration.zero);
    try {
      final encodedMessages = <Map<String, Object?>>[];
      final sliceTimer = Stopwatch()..start();
      for (final message in sourceMessages) {
        encodedMessages.add(<String, Object?>{
          'role': message.role.name,
          'text': message.text,
          'timestamp': message.timestamp.toUtc().toIso8601String(),
          'metadata': message.metadata,
          'omissions': message.omissions
              .map((omission) => omission.toJson())
              .toList(growable: false),
          if (message.turnId != null) 'turnId': message.turnId,
        });
        if (sliceTimer.elapsed >= const Duration(milliseconds: 4)) {
          await Future<void>.delayed(Duration.zero);
          sliceTimer.reset();
        }
      }
      await cache.save(
        SessionTranscriptSnapshot(
          identity: identity,
          messages: encodedMessages,
          timelineHistoryWasTruncated: timelineHistoryWasTruncated,
        ),
      );
    } on Object {
      // A cache write is optional; ACP remains the canonical recovery path.
    }
  }

  Future<List<AcpProjectSessions>> listSessions() async {
    if (isSessionOperationRunning) {
      throw StateError('Another session operation is already in progress.');
    }
    return _runSessionOperationWithResult(() async {
      if (status == ConnectionStatus.disconnected ||
          status == ConnectionStatus.error) {
        await _connectWithStatus(ConnectionStatus.connecting);
        if (status == ConnectionStatus.error) {
          throw StateError(lastError ?? 'ACP agent connection failed.');
        }
      }
      return client.listSessions();
    });
  }

  void mergeSessionIndex(Iterable<AgentSession> indexedSessions) {
    var didChange = false;
    for (final session in indexedSessions) {
      if (session.id.trim().isEmpty || session.cwd.trim().isEmpty) continue;
      if (_retiredSessionIds.contains(session.id)) continue;

      if (session.localUnstarted) {
        _localUnstartedSessionIds.add(session.id.trim());
      }

      final existing = _sessionWithId(session.id);
      final nextSession = existing == null
          ? session
          : _mergeSessionIndexMetadata(existing, session);
      if (existing != null && _sameSessionIndex(existing, nextSession)) {
        continue;
      }

      if (_sessionIdsMatch(currentSession?.id, nextSession.id)) {
        currentSession = nextSession;
      }
      _upsertSession(nextSession);
      didChange = true;
    }
    if (didChange) _notifyListeners();
  }

  void setSessionPinned(String sessionId, bool pinned) {
    _updateSessionMetadata(sessionId, (session) {
      if (session.pinned == pinned) return session;
      return session.copyWith(pinned: pinned);
    });
  }

  void renameSession(String sessionId, String title) {
    final normalizedTitle = normalizeSessionTitle(title);
    if (normalizedTitle == null) return;
    _updateSessionMetadata(sessionId, (session) {
      if (session.titleOverride == normalizedTitle) return session;
      return session.copyWith(titleOverride: normalizedTitle);
    });
  }

  void _applyFallbackSessionTitle(String sessionId, String firstPrompt) {
    final fallback = _boundedSessionTitle(
      firstPrompt,
      assistantAgentConfig.fallbackTitleCharacters,
    );
    if (fallback == null) return;
    _updateSessionMetadata(sessionId, (session) {
      if (session.titleOverride?.trim().isNotEmpty == true) return session;
      if (session.title?.trim().isNotEmpty == true) return session;
      return session.copyWith(title: fallback, updatedAt: DateTime.now());
    });
  }

  void _scheduleAssistantSessionTitle(String sessionId, String firstPrompt) {
    final enhancer = assistantAgentEnhancer;
    if (enhancer == null ||
        !assistantAgentConfig.isConfigured ||
        !assistantAgentConfig.generateSessionTitles ||
        !_titleEnhancementStartedSessionIds.add(sessionId)) {
      return;
    }
    unawaited(() async {
      final generated = await enhancer.generateSessionTitle(
        sessionId: sessionId,
        firstPrompt: firstPrompt,
      );
      if (_isDisposed) return;
      final title = _boundedSessionTitle(generated, 64);
      if (title == null) return;
      _updateSessionMetadata(sessionId, (session) {
        if (session.titleOverride?.trim().isNotEmpty == true) return session;
        return session.copyWith(title: title, updatedAt: DateTime.now());
      });
    }());
  }

  void setSessionArchived(String sessionId, bool archived) {
    _updateSessionMetadata(sessionId, (session) {
      if (session.archived == archived) return session;
      return session.copyWith(archived: archived);
    });
  }

  ArchivedSessionSnapshot? archiveSessionLocally(String sessionId) {
    if (isStreaming || isSessionOperationRunning) return null;
    final session = _sessionWithId(sessionId);
    if (session == null || session.archived) return null;
    final wasCurrent = _sessionIdsMatch(currentSession?.id, sessionId);
    if (wasCurrent) _finishTurnBudget();
    _refreshActiveUiStateBudget();
    final inactiveSnapshot = wasCurrent
        ? null
        : _sessionViewSnapshotWithId(sessionId);
    final snapshot = ArchivedSessionSnapshot(
      session: session,
      wasCurrent: wasCurrent,
      messages: wasCurrent
          ? List<ChatMessage>.from(messages)
          : inactiveSnapshot?.messages ?? const <ChatMessage>[],
      availableCommands: wasCurrent
          ? availableCommands
          : inactiveSnapshot?.availableCommands ??
                const <Map<String, Object?>>[],
      lastLatency: wasCurrent ? lastLatency : inactiveSnapshot?.lastLatency,
      lastError: wasCurrent ? lastError : inactiveSnapshot?.lastError,
      sessionSettings: wasCurrent
          ? sessionSettings
          : inactiveSnapshot?.sessionSettings ?? const ChatSessionSettings(),
      sessionUsage: wasCurrent ? sessionUsage : inactiveSnapshot?.sessionUsage,
      sessionSettingsLoading: wasCurrent
          ? sessionSettingsLoading
          : inactiveSnapshot?.sessionSettingsLoading ?? false,
      status: wasCurrent
          ? status
          : inactiveSnapshot?.status ?? ConnectionStatus.sessionReady,
      activeSessionSettingsLoadId: wasCurrent
          ? _activeSessionSettingsLoadId
          : inactiveSnapshot?.activeSessionSettingsLoadId,
      timelineHistoryWasTruncated: wasCurrent
          ? _timelineHistoryWasTruncated
          : inactiveSnapshot?.timelineHistoryWasTruncated ?? false,
      inputBudget: inputBudget,
    );

    final sourceRetainedBytes = wasCurrent
        ? _activeUiStateRetainedBytes
        : inactiveSnapshot?.retainedBytes ?? 0;
    final totalRetainedBytes = debugUiStateRetainedBytes;
    if (sourceRetainedBytes > totalRetainedBytes) return null;
    final retainedWithoutSource = totalRetainedBytes - sourceRetainedBytes;
    if (retainedWithoutSource > inputBudget.maxUiStateBytes ||
        snapshot.retainedBytes >
            inputBudget.maxUiStateBytes - retainedWithoutSource) {
      return null;
    }

    return _runSynchronousUiStateTransaction(() {
      _upsertSession(session.copyWith(archived: true, unread: false));
      _removeSessionViewSnapshot(sessionId);
      if (wasCurrent) {
        currentSession = null;
        _timelineHistoryWasTruncated = false;
        _clearMessages();
        availableCommands = const <Map<String, Object?>>[];
        lastLatency = null;
        lastError = null;
        sessionSettings = const ChatSessionSettings();
        sessionUsage = null;
        sessionSettingsLoading = false;
        _activeSessionSettingsLoadId = null;
        if (status == ConnectionStatus.sessionReady) {
          status = ConnectionStatus.connected;
        }
      }
      _issueArchiveLease(snapshot);
      _notifyListeners();
      return snapshot;
    });
  }

  void restoreArchivedSessionLocally(ArchivedSessionSnapshot snapshot) {
    final leaseId = snapshot._leaseId;
    final hasIssuedLease = snapshot._leaseIssued;
    if (hasIssuedLease &&
        (leaseId == null || !_ownsActiveArchiveLease(snapshot, leaseId))) {
      return;
    }
    final wasCurrent = snapshot.wasCurrent;
    final prepared = _SessionViewSnapshot(
      session: snapshot.session,
      messages: snapshot.messages,
      availableCommands: snapshot.availableCommands,
      lastLatency: snapshot.lastLatency,
      lastError: snapshot.lastError,
      sessionSettings: snapshot.sessionSettings,
      sessionUsage: snapshot.sessionUsage,
      sessionSettingsLoading: snapshot.sessionSettingsLoading,
      status: snapshot.status,
      activeSessionSettingsLoadId: snapshot.activeSessionSettingsLoadId,
      timelineHistoryWasTruncated: snapshot.timelineHistoryWasTruncated,
      inputBudget: inputBudget,
    );
    _runSynchronousUiStateTransaction(() {
      if (hasIssuedLease && !_consumeArchiveLease(snapshot, leaseId!)) return;
      _upsertSession(prepared.session);
      if (wasCurrent && currentSession == null) {
        currentSession = prepared.session;
        _timelineHistoryWasTruncated = prepared.timelineHistoryWasTruncated;
        _replaceAllMessages(prepared.messages.map((message) => message.thaw()));
        availableCommands = _copyAvailableCommands(
          prepared.availableCommands,
          inputBudget,
        );
        lastLatency = prepared.lastLatency;
        lastError = prepared.lastError;
        sessionSettings = _copySessionSettings(
          prepared.sessionSettings,
          inputBudget,
        );
        sessionUsage = _copySessionUsage(prepared.sessionUsage);
        sessionSettingsLoading = prepared.sessionSettingsLoading;
        status = prepared.status;
        _activeSessionSettingsLoadId = prepared.activeSessionSettingsLoadId;
      } else {
        _storeSessionViewSnapshot(prepared.session.id, prepared);
      }
      _notifyListeners();
    });
  }

  void _issueArchiveLease(ArchivedSessionSnapshot snapshot) {
    final leaseId = ++_nextArchiveLeaseId;
    _archiveLeasesById[leaseId] = snapshot;
    _archivedLeaseRetainedBytes = projectionCheckedRetainedAdd(
      _archivedLeaseRetainedBytes,
      snapshot.retainedBytes,
    );
    snapshot._attachLease(
      ownerToken: _archiveLeaseOwnerToken,
      leaseId: leaseId,
      release: () => _releaseArchiveLease(leaseId),
    );
  }

  bool _ownsActiveArchiveLease(ArchivedSessionSnapshot snapshot, int leaseId) {
    return snapshot._hasActiveLease(_archiveLeaseOwnerToken, leaseId) &&
        identical(_archiveLeasesById[leaseId], snapshot);
  }

  bool _consumeArchiveLease(ArchivedSessionSnapshot snapshot, int leaseId) {
    if (!_ownsActiveArchiveLease(snapshot, leaseId)) return false;
    return snapshot._consumeLease(_archiveLeaseOwnerToken, leaseId);
  }

  void _releaseArchiveLease(int leaseId) {
    final snapshot = _archiveLeasesById.remove(leaseId);
    if (snapshot == null) return;
    _archivedLeaseRetainedBytes -= snapshot.retainedBytes;
  }

  void setSessionUnread(String sessionId, bool unread) {
    _updateSessionMetadata(sessionId, (session) {
      if (session.unread == unread) return session;
      return session.copyWith(unread: unread);
    });
  }

  void _retainLocalSessionView(String sessionId) {
    final ownership = client;
    if (ownership is AcpLocalSessionViewOwnership) {
      (ownership as AcpLocalSessionViewOwnership).retainLocalSessionView(
        sessionId,
      );
    }
  }

  void _releaseLocalSessionView(String sessionId) {
    final ownership = client;
    if (ownership is AcpLocalSessionViewOwnership) {
      (ownership as AcpLocalSessionViewOwnership).releaseLocalSessionView(
        sessionId,
      );
    }
  }

  void _storeSessionViewSnapshot(
    String sessionId,
    _SessionViewSnapshot snapshot,
  ) {
    final normalizedSessionId = sessionId.trim();
    _retainLocalSessionView(normalizedSessionId);
    final previousKey = _sessionViewSnapshotKeyWithId(normalizedSessionId);
    final previous = previousKey == null
        ? null
        : _sessionViewSnapshots.remove(previousKey);
    if (previous != null) {
      _inactiveSnapshotRetainedBytes -= previous.retainedBytes;
    }
    _sessionViewSnapshots[normalizedSessionId] = snapshot;
    _inactiveSnapshotRetainedBytes = projectionCheckedRetainedAdd(
      _inactiveSnapshotRetainedBytes,
      snapshot.retainedBytes,
    );
    if (_uiStateTransactionDepth > 0) {
      _uiStateRefreshPending = true;
    } else {
      _enforceUiStateBudget();
    }
  }

  _SessionViewSnapshot? _takeSessionViewSnapshot(
    String sessionId, {
    bool releaseOwnership = false,
  }) {
    final key = _sessionViewSnapshotKeyWithId(sessionId);
    final snapshot = key == null ? null : _sessionViewSnapshots.remove(key);
    if (snapshot != null) {
      _inactiveSnapshotRetainedBytes -= snapshot.retainedBytes;
      if (releaseOwnership) _releaseLocalSessionView(snapshot.session.id);
    }
    return snapshot;
  }

  void _removeSessionViewSnapshot(String sessionId) {
    _takeSessionViewSnapshot(sessionId, releaseOwnership: true);
  }

  _SessionViewSnapshot? _touchSessionViewSnapshot(String sessionId) {
    final snapshot = _takeSessionViewSnapshot(sessionId);
    if (snapshot == null) return null;
    _sessionViewSnapshots[sessionId.trim()] = snapshot;
    _inactiveSnapshotRetainedBytes = projectionCheckedRetainedAdd(
      _inactiveSnapshotRetainedBytes,
      snapshot.retainedBytes,
    );
    return snapshot;
  }

  _SessionViewSnapshot? _sessionViewSnapshotWithId(String sessionId) {
    final key = _sessionViewSnapshotKeyWithId(sessionId);
    return key == null ? null : _sessionViewSnapshots[key];
  }

  String? _sessionViewSnapshotKeyWithId(String sessionId) {
    final normalizedSessionId = sessionId.trim();
    for (final key in _sessionViewSnapshots.keys) {
      if (key.trim() == normalizedSessionId) return key;
    }
    return null;
  }

  void _clearSessionViewSnapshots() {
    for (final sessionId in _sessionViewSnapshots.keys) {
      _releaseLocalSessionView(sessionId);
    }
    _sessionViewSnapshots.clear();
    _inactiveSnapshotRetainedBytes = 0;
  }

  void _requestActiveUiStateRefresh() {
    if (_uiStateTransactionDepth > 0) {
      _uiStateRefreshPending = true;
      return;
    }
    _refreshActiveUiStateBudget();
  }

  bool _commitAuxiliaryUiStateMutation({
    required VoidCallback apply,
    required VoidCallback rollback,
  }) {
    apply();
    _recomputeActiveUiStateRetainedBytes();
    if (!_canFitActiveMessageRetainedDelta(0)) {
      rollback();
      _recomputeActiveUiStateRetainedBytes();
      return false;
    }
    if (_uiStateTransactionDepth > 0) {
      _uiStateRefreshPending = true;
      return true;
    }
    _enforceUiStateBudget();
    if (debugUiStateRetainedBytes <= inputBudget.maxUiStateBytes) return true;
    rollback();
    _recomputeActiveUiStateRetainedBytes();
    _enforceUiStateBudget();
    return false;
  }

  bool _tryReplaceAvailableCommands(List<Map<String, Object?>> commands) {
    final copied = _copyAvailableCommands(commands, inputBudget);
    final previous = _availableCommands;
    final accepted = _commitAuxiliaryUiStateMutation(
      apply: () => _availableCommands = copied,
      rollback: () => _availableCommands = previous,
    );
    if (accepted) _availableCommandsRevision += 1;
    return accepted;
  }

  bool _tryReplaceSessionSettings(ChatSessionSettings settings) {
    final previous = _sessionSettings;
    return _commitAuxiliaryUiStateMutation(
      apply: () => _sessionSettings = settings,
      rollback: () => _sessionSettings = previous,
    );
  }

  bool _tryReplaceSessionUsage(AcpSessionUsage? usage) {
    final previous = _sessionUsage;
    return _commitAuxiliaryUiStateMutation(
      apply: () => _sessionUsage = usage,
      rollback: () => _sessionUsage = previous,
    );
  }

  bool _tryReplaceCurrentSession(AgentSession session) {
    final previous = _currentSession;
    return _commitAuxiliaryUiStateMutation(
      apply: () => _currentSession = session,
      rollback: () => _currentSession = previous,
    );
  }

  bool _canAdmitAuxiliaryUiState({
    required VoidCallback apply,
    required VoidCallback rollback,
  }) {
    apply();
    _recomputeActiveUiStateRetainedBytes();
    final canAdmit = _canFitActiveMessageRetainedDelta(0);
    rollback();
    _recomputeActiveUiStateRetainedBytes();
    return canAdmit;
  }

  Future<T> _runUiStateTransaction<T>(FutureOr<T> Function() operation) async {
    _uiStateTransactionDepth += 1;
    try {
      return await operation();
    } finally {
      _finishUiStateTransaction();
    }
  }

  T _runSynchronousUiStateTransaction<T>(T Function() operation) {
    _uiStateTransactionDepth += 1;
    try {
      return operation();
    } finally {
      _finishUiStateTransaction();
    }
  }

  void _finishUiStateTransaction() {
    _uiStateTransactionDepth -= 1;
    if (_uiStateTransactionDepth == 0 && _uiStateRefreshPending) {
      _uiStateRefreshPending = false;
      _refreshActiveUiStateBudget();
    }
    if (_uiStateTransactionDepth == 0 && _uiStateNotificationPending) {
      _uiStateNotificationPending = false;
      _notifyListeners();
    }
  }

  void _refreshActiveUiStateBudget() {
    if (_uiStateTransactionDepth > 0) {
      _uiStateRefreshPending = true;
      return;
    }
    _recomputeActiveUiStateRetainedBytes();
    _enforceUiStateBudget();
  }

  void _recomputeActiveUiStateRetainedBytes() {
    final session = _currentSession;
    _activeUiStateRetainedBytes = session == null
        ? 0
        : _estimateSessionViewRetainedBytes(
            messages: _messages,
            availableCommands: _availableCommands,
            sessionSettings: _sessionSettings,
            sessionUsage: _sessionUsage,
            session: session,
            lastLatency: _lastLatency,
            lastError: _lastError,
            activeSessionSettingsLoadId: __activeSessionSettingsLoadId,
            inputBudget: inputBudget,
            precomputedTimelineRetainedBytes: _activeTimelineRetainedBytes,
          );
  }

  void _enforceUiStateBudget() {
    if (_enforcingUiStateBudget || _uiStateTransactionDepth > 0) return;
    _enforcingUiStateBudget = true;
    var removedHistory = false;
    try {
      while (debugUiStateRetainedBytes > inputBudget.maxUiStateBytes &&
          _sessionViewSnapshots.isNotEmpty) {
        _takeSessionViewSnapshot(
          _sessionViewSnapshots.keys.first,
          releaseOwnership: true,
        );
      }
      while (debugUiStateRetainedBytes > inputBudget.maxUiStateBytes) {
        int? oldestTurnId;
        for (final message in _messages) {
          if (_isHistoryMarker(message)) continue;
          final turnId = message.turnId;
          if (turnId == null || turnId == _activeTurnId) continue;
          oldestTurnId = turnId;
          break;
        }
        if (oldestTurnId == null) break;
        _mutateMessages(
          () => _messages.removeWhere(
            (message) => message.turnId == oldestTurnId,
          ),
          enforceBudget: false,
        );
        removedHistory = true;
        _timelineHistoryWasTruncated = true;
        _recomputeActiveUiStateRetainedBytes();
      }
      if (removedHistory && !_messages.any(_isHistoryMarker)) {
        final marker = _prepareOwnedMessage(
          ChatMessage(
            role: ChatMessageRole.status,
            text: '',
            omissions: <acp.ChatInputOmission>[
              acp.ChatInputOmission(
                reason: acp.ChatInputOmissionReason.inputLimit,
                resource: 'timeline history',
                truncated: true,
                limit: inputBudget.maxUiStateBytes,
                observedAtLeast: inputBudget.maxUiStateBytes + 1,
              ),
            ],
            inputBudget: inputBudget,
          ),
          turnId: ++_nextTurnId,
        );
        _mutateMessages(
          () => _messages.insert(0, marker),
          enforceBudget: false,
        );
        _recomputeActiveUiStateRetainedBytes();
        while (debugUiStateRetainedBytes > inputBudget.maxUiStateBytes) {
          int? oldestTurnId;
          for (final message in _messages) {
            if (_isHistoryMarker(message)) continue;
            final turnId = message.turnId;
            if (turnId == null || turnId == _activeTurnId) continue;
            oldestTurnId = turnId;
            break;
          }
          if (oldestTurnId == null) break;
          _mutateMessages(
            () => _messages.removeWhere(
              (message) => message.turnId == oldestTurnId,
            ),
            enforceBudget: false,
          );
          _recomputeActiveUiStateRetainedBytes();
        }
      }
      if (debugUiStateRetainedBytes > inputBudget.maxUiStateBytes) {
        final markerIndex = _messages.indexWhere(_isHistoryMarker);
        if (markerIndex >= 0) {
          _mutateMessages(
            () => _messages.removeAt(markerIndex),
            enforceBudget: false,
          );
          _recomputeActiveUiStateRetainedBytes();
        }
      }
    } finally {
      _enforcingUiStateBudget = false;
    }
  }

  void _snapshotCurrentSession() {
    final session = currentSession;
    if (session == null) return;
    _finishTurnBudget();
    _storeSessionViewSnapshot(
      session.id,
      _SessionViewSnapshot(
        session: session,
        messages: List<ChatMessage>.from(messages),
        availableCommands: availableCommands,
        lastLatency: lastLatency,
        lastError: lastError,
        sessionSettings: sessionSettings,
        sessionUsage: sessionUsage,
        sessionSettingsLoading: sessionSettingsLoading,
        status: status,
        activeSessionSettingsLoadId: _activeSessionSettingsLoadId,
        timelineHistoryWasTruncated: _timelineHistoryWasTruncated,
        inputBudget: inputBudget,
      ),
    );
  }

  void _activateSessionViewSnapshot(
    _SessionViewSnapshot snapshot, {
    String? cwd,
    List<String>? additionalDirectories,
    String? title,
    DateTime? updatedAt,
  }) {
    _retainLocalSessionView(snapshot.session.id);
    final existingSession = _sessionWithId(snapshot.session.id);
    final sidebarSession = existingSession ?? snapshot.session;
    final session = _copyAgentSessionStrict(
      sidebarSession.copyWith(
        cwd: cwd ?? sidebarSession.cwd,
        additionalDirectories:
            additionalDirectories ?? sidebarSession.additionalDirectories,
        title: title ?? sidebarSession.title,
        updatedAt: updatedAt ?? sidebarSession.updatedAt,
        archived: false,
        unread: false,
      ),
      inputBudget,
    );
    _retiredSessionIds.remove(session.id);
    currentSession = session;
    _upsertSession(session);
    _cancelPendingPermissionOutsideSession(session.id);
    _timelineHistoryWasTruncated = snapshot.timelineHistoryWasTruncated;
    _replaceAllMessages(snapshot.messages.map((message) => message.thaw()));
    availableCommands = _copyAvailableCommands(
      snapshot.availableCommands,
      inputBudget,
    );
    lastLatency = snapshot.lastLatency;
    lastError = snapshot.lastError;
    sessionSettings = _copySessionSettings(
      snapshot.sessionSettings,
      inputBudget,
    );
    sessionUsage = _copySessionUsage(snapshot.sessionUsage);
    sessionSettingsLoading = snapshot.sessionSettingsLoading;
    status = snapshot.status == ConnectionStatus.streaming
        ? ConnectionStatus.sessionReady
        : snapshot.status;
    _activeSessionSettingsLoadId = snapshot.activeSessionSettingsLoadId;
    _notifyListeners();
  }

  void _activateLocalUnstartedSession(
    AgentSession existingSession, {
    String? cwd,
    List<String>? additionalDirectories,
    String? title,
    DateTime? updatedAt,
  }) {
    _retainLocalSessionView(existingSession.id);
    final session = _copyAgentSessionStrict(
      existingSession.copyWith(
        cwd: cwd ?? existingSession.cwd,
        additionalDirectories:
            additionalDirectories ?? existingSession.additionalDirectories,
        title: title ?? existingSession.title,
        updatedAt: updatedAt ?? existingSession.updatedAt,
        archived: false,
        unread: false,
      ),
      inputBudget,
    );
    _retiredSessionIds.remove(session.id);
    currentSession = session;
    _upsertSession(session);
    _cancelPendingPermissionOutsideSession(session.id);
    _timelineHistoryWasTruncated = false;
    _clearMessages();
    availableCommands = const <Map<String, Object?>>[];
    lastLatency = null;
    lastError = null;
    sessionSettings = const ChatSessionSettings();
    sessionUsage = null;
    sessionSettingsLoading = false;
    status = ConnectionStatus.reconnecting;
    _notifyListeners();
  }

  Future<List<AcpProjectSessions>> listResumableSessions() async {
    final projects = await listSessions();
    if (!supportsSessionResume) {
      throw StateError(
        'ACP agent does not support session/load or session/resume.',
      );
    }
    return projects;
  }

  bool hasBoundSessionWorkspaceConflict(AgentSession candidate) {
    final boundSession = _boundSessionWithId(candidate.id);
    return boundSession != null &&
        !sameSessionWorkspaceIdentity(boundSession, candidate);
  }

  Future<ChatPromptSubmissionResult> submitOrQueuePrompt(
    String text, {
    List<PromptAttachment> attachments = const <PromptAttachment>[],
  }) {
    if (!isStreaming && !isSessionOperationRunning) {
      return sendPrompt(text, attachments: attachments);
    }
    return Future<ChatPromptSubmissionResult>.value(
      enqueuePrompt(text, attachments: attachments),
    );
  }

  ChatPromptSubmissionResult enqueuePrompt(
    String text, {
    List<PromptAttachment> attachments = const <PromptAttachment>[],
    bool guide = false,
  }) {
    final prompt = text.trim();
    if (prompt.isEmpty && attachments.isEmpty) {
      return ChatPromptSubmissionResult.empty;
    }
    final item = ChatQueuedPrompt(
      id: ++_nextQueuedPromptId,
      text: prompt,
      attachments: List<PromptAttachment>.unmodifiable(attachments),
      createdAt: DateTime.now(),
      guide: guide,
    );
    if (guide) {
      _queuedPrompts.insert(0, item);
    } else {
      _queuedPrompts.add(item);
    }
    _notifyListeners();
    return ChatPromptSubmissionResult.queued;
  }

  void guideQueuedPrompt(int id) {
    final index = _queuedPrompts.indexWhere((item) => item.id == id);
    if (index == -1) return;
    final selected = _queuedPrompts.removeAt(index).copyWith(guide: true);
    for (var cursor = 0; cursor < _queuedPrompts.length; cursor += 1) {
      final item = _queuedPrompts[cursor];
      if (item.guide) {
        _queuedPrompts[cursor] = item.copyWith(guide: false);
      }
    }
    _queuedPrompts.insert(0, selected);
    _notifyListeners();
    if (isStreaming && !_guidanceInterruptionRunning) {
      _guidanceInterruptionRunning = true;
      unawaited(_interruptCurrentTurnForGuidance());
    }
  }

  Future<void> _interruptCurrentTurnForGuidance() async {
    try {
      await stop();
      if (!isStreaming && status != ConnectionStatus.error) {
        _scheduleQueuedPromptDispatch();
      }
    } finally {
      _guidanceInterruptionRunning = false;
      if (!_isDisposed) _notifyListeners();
    }
  }

  void removeQueuedPrompt(int id) {
    final before = _queuedPrompts.length;
    _queuedPrompts.removeWhere((item) => item.id == id);
    if (_queuedPrompts.length != before) _notifyListeners();
  }

  void clearQueuedPrompts() {
    if (_queuedPrompts.isEmpty) return;
    _queuedPrompts.clear();
    _notifyListeners();
  }

  void reorderQueuedPrompt(int oldIndex, int newIndex) {
    if (oldIndex < 0 ||
        oldIndex >= _queuedPrompts.length ||
        newIndex < 0 ||
        newIndex >= _queuedPrompts.length) {
      return;
    }
    if (newIndex == oldIndex) return;
    final item = _queuedPrompts.removeAt(oldIndex);
    _queuedPrompts.insert(newIndex, item);
    _notifyListeners();
  }

  Future<ChatPromptSubmissionResult> sendPrompt(
    String text, {
    List<PromptAttachment> attachments = const <PromptAttachment>[],
  }) async {
    final prompt = text.trim();
    if (prompt.isEmpty && attachments.isEmpty) {
      return ChatPromptSubmissionResult.empty;
    }
    if (isStreaming || isSessionOperationRunning) {
      return ChatPromptSubmissionResult.busy;
    }

    if (currentSession == null) {
      final created = await newSession(preserveDraft: true);
      if (!created || status == ConnectionStatus.error) {
        return ChatPromptSubmissionResult.sessionUnavailable;
      }
    }

    final session = currentSession;
    if (session == null) return ChatPromptSubmissionResult.sessionUnavailable;
    _removeLocalUnstartedSessionId(session.id);
    final isFirstUserPrompt = _messages.isEmpty;
    final titleSeed = prompt.isNotEmpty
        ? prompt
        : attachments.map((attachment) => attachment.name).join(' ');

    _finishTurnBudget();
    _startLocalTurn();
    _turnBudget = _TurnBudgetState(inputBudget);
    _pendingEnhancementTurnId = _activeTurnId;
    _pendingEnhancementPrompt = prompt;
    _pendingEnhancementSessionId = session.id;

    final contentBlocks = attachments
        .map((attachment) => attachment.toResourceLink())
        .toList();
    final userMetadata = <String, Object?>{};
    if (contentBlocks.isNotEmpty) {
      userMetadata['contentBlocks'] = contentBlocks;
    }
    final provisionalUser = _addTurnMessage(
      ChatMessage(
        role: ChatMessageRole.user,
        text: prompt,
        inputBudget: inputBudget,
        metadata: userMetadata,
      ),
    );
    if (enableAutomaticSessionTitles &&
        isFirstUserPrompt &&
        titleSeed.trim().isNotEmpty) {
      _applyFallbackSessionTitle(session.id, titleSeed);
      _scheduleAssistantSessionTitle(session.id, titleSeed);
    }
    isStreaming = true;
    _activePromptCompletion = Completer<void>();
    status = ConnectionStatus.streaming;
    lastError = null;
    _lastPromptStartedAt = DateTime.now();
    _recordPromptActivity();
    _notifyListeners();

    try {
      await _promptSubscription?.cancel();
      _promptSubscription = client
          .sendPrompt(
            sessionId: session.id,
            prompt: prompt,
            attachments: attachments,
          )
          .listen(
            (event) {
              _recordPromptActivity();
              _handleAgentEvent(event);
            },
            onError: (Object error, StackTrace stackTrace) {
              _handleAgentEvent(
                AgentEvent(
                  type: AgentEventType.error,
                  text: _messageForError(error),
                ),
              );
              _finishStreaming();
            },
            onDone: _finishStreaming,
          );
      return ChatPromptSubmissionResult.submitted;
    } catch (error) {
      // The stream never admitted this request. Do not retain a duplicate user
      // turn when the preserved composer is retried.
      _mutateMessages(() => _messages.remove(provisionalUser));
      _handleAgentEvent(
        AgentEvent(type: AgentEventType.error, text: _messageForError(error)),
      );
      _finishStreaming();
      return ChatPromptSubmissionResult.failed;
    }
  }

  Future<void> stop({
    Duration cancellationTimeout = defaultCleanupTimeout,
  }) async {
    if (!isStreaming) return;
    Object? cancelError;
    var cancellationAcknowledged = false;
    final promptCompletion = _activePromptCompletion;
    try {
      final permissionError = await _cancelPendingPermissionRequest(
        reportErrors: false,
      ).timeout(cancellationTimeout);
      cancelError = permissionError;
    } on Object catch (error) {
      cancelError = error;
    }
    try {
      final sessionId = currentSession?.id;
      if (sessionId != null) {
        await client
            .cancelSession(sessionId: sessionId)
            .timeout(cancellationTimeout);
      }
    } on Object catch (error) {
      cancelError ??= error;
    }
    try {
      if (promptCompletion != null && !promptCompletion.isCompleted) {
        await promptCompletion.future.timeout(cancellationTimeout);
      }
      cancellationAcknowledged = true;
    } on Object catch (error) {
      cancelError ??= error;
    } finally {
      try {
        final promptSubscription = _promptSubscription;
        if (isStreaming && promptSubscription != null) {
          await promptSubscription.cancel().timeout(cancellationTimeout);
        }
      } on Object catch (error) {
        cancelError ??= error;
      }
      _promptSubscription = null;
      if (isStreaming) {
        _finishStreaming(dispatchQueuedPrompts: false);
      }
    }
    if (cancelError != null) {
      if (!cancellationAcknowledged) {
        status = ConnectionStatus.error;
      }
      _setActionError(
        cancelError,
        preserveConnectionStatus: !cancellationAcknowledged,
      );
    }
  }

  Future<void> reconnect() async {
    if (isSessionOperationRunning) return;
    _finishTurnBudget();
    await _runSessionOperation(() async {
      await _promptSubscription?.cancel();
      _promptSubscription = null;
      isStreaming = false;
      await _cancelPendingPermissionRequest(reportErrors: false);
      if (currentSession case final session?) {
        final ownership = client;
        if (ownership is AcpLocalSessionViewOwnership) {
          (ownership as AcpLocalSessionViewOwnership).abandonLocalSessionView(
            session.id,
          );
        }
      }
      currentSession = null;
      sessions.clear();
      _timelineHistoryWasTruncated = false;
      _localUnstartedSessionIds.clear();
      _clearSessionViewSnapshots();
      _clearMessages();
      availableCommands = const <Map<String, Object?>>[];
      sessionSettings = const ChatSessionSettings();
      sessionUsage = null;
      lastLatency = null;
      lastError = null;
      sessionSettingsLoading = false;
      _activeSessionSettingsLoadId = null;
      await _connectWithStatus(ConnectionStatus.reconnecting);
    });
  }

  Future<void> refreshSessionSettings() async {
    final sessionId = currentSession?.id;
    if (isStreaming || isSessionOperationRunning) return;
    if (sessionId == null) return;
    await _loadSessionSettings(sessionId);
  }

  Future<void> setSessionMode(String modeId) async {
    final sessionId = currentSession?.id;
    final trimmedModeId = modeId.trim();
    if (sessionId == null ||
        trimmedModeId.isEmpty ||
        !sessionSettings.shouldUseModeFallback ||
        isStreaming ||
        isSessionOperationRunning) {
      return;
    }

    try {
      final didSet = await client.setSessionMode(
        sessionId: sessionId,
        modeId: trimmedModeId,
      );
      if (!_isActiveSession(sessionId)) return;
      if (!didSet) {
        throw StateError('ACP agent rejected session mode "$trimmedModeId".');
      }
      sessionSettings = sessionSettings.withCurrentMode(trimmedModeId);
      lastError = null;
      _notifyListeners();
    } catch (error) {
      if (_isActiveSession(sessionId)) {
        _setActionError(error);
      }
    }
  }

  Future<void> setConfigOption(String configId, Object value) async {
    final sessionId = currentSession?.id;
    final trimmedConfigId = configId.trim();
    if (sessionId == null ||
        trimmedConfigId.isEmpty ||
        isStreaming ||
        isSessionOperationRunning) {
      return;
    }

    try {
      final options = await client.setConfigOption(
        sessionId: sessionId,
        configId: trimmedConfigId,
        value: value,
      );
      if (!_isActiveSession(sessionId)) return;
      final updatedOptions = options.isEmpty
          ? _configOptionsWithOverride(trimmedConfigId, value)
          : options;
      sessionSettings = sessionSettings.withPreferredConfigOptions(
        updatedOptions,
      );
      lastError = null;
      _notifyListeners();
    } catch (error) {
      if (_isActiveSession(sessionId)) {
        _setActionError(error);
      }
    }
  }

  Future<void> setSessionModel(String modelValue) async {
    final option = sessionSettings.modelOption;
    if (option == null) {
      _setActionError(StateError('No model option exposed by this session.'));
      return;
    }
    await setConfigOption(option.id, modelValue);
  }

  Future<void> setSessionReasoningEffort(String effortValue) async {
    final option = sessionSettings.reasoningEffortOption;
    if (option == null) {
      _setActionError(
        StateError('No reasoning effort option exposed by this session.'),
      );
      return;
    }
    await setConfigOption(option.id, effortValue);
  }

  void setToolCallExecutionPolicy(ChatToolCallExecutionPolicy policy) {
    if (toolCallExecutionPolicy == policy) return;
    toolCallExecutionPolicy = policy;
    final request = pendingPermissionRequest;
    if (request != null) {
      _resolvePendingPermissionForPolicy(request);
    }
    _notifyListeners();
  }

  Future<void> forkCurrentSession() async {
    final session = currentSession;
    if (session == null || !supportsSessionFork) return;
    if (isStreaming || isSessionOperationRunning) return;

    await forkSession(session);
  }

  Future<void> forkSession(AgentSession session) async {
    if (!supportsSessionFork) return;
    if (isStreaming || isSessionOperationRunning) return;
    _finishTurnBudget();

    final operationGeneration = _beginSessionOperationGeneration();
    await _runSessionOperation(() async {
      try {
        await _promptSubscription?.cancel();
        if (!_isCurrentSessionOperationGeneration(operationGeneration)) return;
        _promptSubscription = null;
        if (status == ConnectionStatus.disconnected ||
            status == ConnectionStatus.error) {
          await _connectWithStatus(ConnectionStatus.connecting);
          if (!_isCurrentSessionOperationGeneration(operationGeneration)) {
            return;
          }
          if (status == ConnectionStatus.error) return;
        }
        _pendingSessionSetupGeneration = operationGeneration;
        late final AgentSession remoteFork;
        try {
          remoteFork = await client.forkSession(
            sessionId: session.id,
            cwd: session.cwd,
            additionalDirectories: session.additionalDirectories,
          );
        } finally {
          if (_pendingSessionSetupGeneration == operationGeneration) {
            _pendingSessionSetupGeneration = null;
          }
        }
        _cancelPendingPermissionOutsideSession(remoteFork.id);
        if (!_isCurrentSessionOperationGeneration(operationGeneration)) return;
        final forked = _copyAgentSessionStrict(remoteFork, inputBudget);
        final forkedTitle = forked.title?.trim().isNotEmpty == true
            ? forked.title
            : 'Fork of ${session.displayTitle}';
        final initialEvents = forked.initialEvents;
        final updatedSession = _copyAgentSessionStrict(
          forked.copyWith(
            title: forkedTitle,
            agentName: agentName,
            sessionTemplateId: session.sessionTemplateId,
            sessionTemplateVersion: session.sessionTemplateVersion,
            initialEvents: const <AgentEvent>[],
          ),
          inputBudget,
        );
        _retiredSessionIds.remove(updatedSession.id);
        _markPermissionHistoryCompleteForSession(updatedSession.id);
        currentSession = updatedSession;
        _timelineHistoryWasTruncated = false;
        _upsertSession(updatedSession);
        _clearMessages();
        availableCommands = const <Map<String, Object?>>[];
        lastLatency = null;
        lastError = null;
        sessionSettings = const ChatSessionSettings();
        sessionUsage = null;
        sessionSettingsLoading = false;
        _activeSessionSettingsLoadId = null;
        for (final event in initialEvents) {
          _handleAgentEvent(event, notify: false);
        }
        _finishTurnBudget();
        await _loadAvailableCommands(updatedSession.id, notify: false);
        if (!_isCurrentSessionOperationGeneration(operationGeneration)) return;
        await _loadSessionSettings(updatedSession.id, notify: false);
        if (!_isCurrentSessionOperationGeneration(operationGeneration)) return;
        if (status != ConnectionStatus.error) {
          status = ConnectionStatus.sessionReady;
        }
        _notifyListeners();
      } catch (error) {
        if (!_isCurrentSessionOperationGeneration(operationGeneration)) return;
        _cancelPendingPermissionOutsideSession(currentSession?.id);
        _setActionError(error);
      }
    });
  }

  Future<void> closeCurrentSession() async {
    final session = currentSession;
    if (session == null) return;
    await closeSession(session);
  }

  Future<void> closeSession(AgentSession target) async {
    final session = _sessionForTargetedAction(target);
    if (session == null || !canCloseSession(session)) return;
    final wasCurrent = _sameTargetedSession(currentSession, session);
    if (wasCurrent) _finishTurnBudget();

    final operationGeneration = wasCurrent
        ? _beginSessionOperationGeneration()
        : null;
    bool operationIsCurrent() => operationGeneration == null
        ? !_isDisposed
        : _isCurrentSessionOperationGeneration(operationGeneration);
    await _runSessionOperation(() async {
      if (wasCurrent) {
        try {
          await _promptSubscription?.cancel();
          if (!operationIsCurrent()) return;
          _promptSubscription = null;
        } catch (error) {
          if (!operationIsCurrent()) return;
          _setActionError(error);
          return;
        }
      }

      Object? closeError;
      try {
        await client.closeSession(sessionId: session.id);
      } catch (error) {
        closeError = error;
      }
      if (!operationIsCurrent()) return;

      final ownership = client;
      if (ownership is AcpLocalSessionViewOwnership) {
        (ownership as AcpLocalSessionViewOwnership).abandonLocalSessionView(
          session.id,
        );
      }

      _retireSessionId(session.id);
      _removeLocalUnstartedSessionId(session.id);
      _removeSessionViewSnapshot(session.id);
      if (wasCurrent) {
        currentSession = null;
        _timelineHistoryWasTruncated = false;
        _clearMessages();
        availableCommands = const <Map<String, Object?>>[];
        lastLatency = null;
        lastError = null;
        sessionSettings = const ChatSessionSettings();
        sessionUsage = null;
        sessionSettingsLoading = false;
        _activeSessionSettingsLoadId = null;
        await _cancelPendingPermissionRequest(reportErrors: false);
        if (!operationIsCurrent()) return;
        _removePermissionHistoryForSession(session.id);
        status = ConnectionStatus.connected;
      }
      if (closeError != null) {
        _setActionError(closeError);
      } else {
        _notifyListeners();
      }
    });
  }

  Future<void> deleteCurrentSession() async {
    final session = currentSession;
    if (session == null) return;
    await deleteSession(session);
  }

  Future<void> deleteSession(AgentSession target) async {
    final session = _sessionForTargetedAction(target);
    if (session == null || !canDeleteSession(session)) return;
    final wasCurrent = _sameTargetedSession(currentSession, session);
    await _runSessionOperation(() async {
      try {
        if (wasCurrent) {
          await _promptSubscription?.cancel();
          _promptSubscription = null;
        }
        await client.deleteSession(sessionId: session.id);
        _retireSessionId(session.id);
        _localUnstartedSessionIds.remove(session.id);
        _removeSessionViewSnapshot(session.id);
        sessions.removeWhere((item) => _sameTargetedSession(item, session));
        if (wasCurrent) {
          currentSession = null;
          _timelineHistoryWasTruncated = false;
          _clearMessages();
          availableCommands = const <Map<String, Object?>>[];
          lastLatency = null;
          lastError = null;
          sessionSettings = const ChatSessionSettings();
          sessionUsage = null;
          sessionSettingsLoading = false;
          _activeSessionSettingsLoadId = null;
          await _cancelPendingPermissionRequest(reportErrors: false);
          status = ConnectionStatus.connected;
        }
        _removePermissionHistoryForSession(session.id);
        _notifyListeners();
      } catch (error) {
        _setActionError(error);
      }
    });
  }

  Future<void> logout() async {
    if (!supportsAuthLogout) return;
    if (isStreaming || isSessionOperationRunning) return;
    _finishTurnBudget();

    await _runSessionOperation(() async {
      try {
        await _promptSubscription?.cancel();
        _promptSubscription = null;
        await client.logout();
        _clearLocalStateAfterAgentLogout();
      } catch (error) {
        _setActionError(error);
      }
    });
  }

  void _handleAgentLifecycleEvent(AcpAgentLifecycleEvent event) {
    if (_isDisposed) return;
    switch (event) {
      case AcpAgentLifecycleEvent.loggedOut:
        _clearLocalStateAfterAgentLogout();
    }
  }

  void _clearLocalStateAfterAgentLogout() {
    _sessionOperationGeneration += 1;
    _sessionSettingsLoadSerial += 1;
    if (currentSession case final session?) {
      _retireSessionId(session.id);
    }
    for (final session in sessions) {
      _retireSessionId(session.id);
    }
    _localUnstartedSessionIds.clear();
    _clearSessionViewSnapshots();
    currentSession = null;
    sessions.clear();
    _timelineHistoryWasTruncated = false;
    _clearMessages();
    availableCommands = const <Map<String, Object?>>[];
    lastLatency = null;
    lastError = null;
    sessionSettings = const ChatSessionSettings();
    sessionUsage = null;
    _sessionTemplateWarnings = const <String>[];
    sessionSettingsLoading = false;
    _activeSessionSettingsLoadId = null;
    isSessionReplayLoading = false;
    _cachedSessionTranscriptVisible = false;
    lastSessionLoadMetrics = null;
    pendingPermissionRequest = null;
    _resolvingPermissionRequestIds.clear();
    _reviewingPermissionRequestIds.clear();
    _clearPermissionHistory();
    status = ConnectionStatus.connected;
    _notifyListeners();
  }

  Future<bool> authenticate(String methodId) async {
    final trimmedMethodId = methodId.trim();
    if (trimmedMethodId.isEmpty || !canAuthenticate) return false;

    var authenticated = false;
    await _runSessionOperation(() async {
      try {
        await client.authenticate(methodId: trimmedMethodId);
        lastError = null;
        status = currentSession == null
            ? ConnectionStatus.connected
            : ConnectionStatus.sessionReady;
        authenticated = true;
        _notifyListeners();
      } catch (error) {
        _setActionError(error);
      }
    });
    return authenticated;
  }

  Future<void> resolvePermissionRequest(ChatPermissionDecision decision) async {
    final request = pendingPermissionRequest;
    if (request == null) return;
    await _resolvePermissionRequest(
      request,
      decision,
      source: ChatPermissionDecisionSource.manual,
    );
  }

  Future<void> resolvePermissionOption(String optionId) async {
    final request = pendingPermissionRequest;
    if (request == null) return;
    final choice = request.choiceById(optionId);
    final decision = choice?.decision;
    if (choice == null || decision == null) {
      throw StateError('Unknown permission option: $optionId');
    }
    await _resolvePermissionRequest(
      request,
      decision,
      source: ChatPermissionDecisionSource.manual,
      selectedOptionId: choice.optionId,
    );
  }

  Future<void> _connectWithStatus(ConnectionStatus connectingStatus) async {
    status = connectingStatus;
    capabilities = null;
    lastError = null;
    _notifyListeners();
    try {
      await client.connect();
      if (_isDisposed) {
        await _ignoreCleanup(client.dispose);
        return;
      }
      _retiredSessionIds.clear();
      _retiredSessionIdsOverflow = false;
      capabilities = client.capabilities;
      status = ConnectionStatus.connected;
      _notifyListeners();
    } catch (error) {
      if (_isDisposed) return;
      _setError(error);
    }
  }

  Future<void> _runSessionOperation(Future<void> Function() action) async {
    if (_isDisposed) return;
    final idle = Completer<void>();
    _sessionOperationIdleCompleter = idle;
    isSessionOperationRunning = true;
    _notifyListeners();
    try {
      await action();
    } finally {
      isSessionOperationRunning = false;
      if (identical(_sessionOperationIdleCompleter, idle)) {
        _sessionOperationIdleCompleter = null;
      }
      if (!idle.isCompleted) idle.complete();
      if (!_isDisposed) {
        _notifyListeners();
      }
    }
  }

  Future<T> _runSessionOperationWithResult<T>(
    Future<T> Function() action,
  ) async {
    if (_isDisposed) {
      throw StateError('Chat controller is disposed.');
    }
    final idle = Completer<void>();
    _sessionOperationIdleCompleter = idle;
    isSessionOperationRunning = true;
    _notifyListeners();
    try {
      return await action();
    } finally {
      isSessionOperationRunning = false;
      if (identical(_sessionOperationIdleCompleter, idle)) {
        _sessionOperationIdleCompleter = null;
      }
      if (!idle.isCompleted) idle.complete();
      if (!_isDisposed) {
        _notifyListeners();
      }
    }
  }

  AgentEvent _safeAgentEvent(AgentEvent event) {
    if (event.trustedRenderProjection) return event;
    final snapshot = projectionSnapshotChatMessageMetadata(
      event.metadata,
      inputBudget,
    );
    final stableMetadata = snapshot.metadata;
    final guarded = stableMetadata == null
        ? projectionInvalidChatMessageMetadata()
        : projectionGuardChatMessageMetadata(stableMetadata, inputBudget);
    final rawKindValue = stableMetadata?['kind'];
    final rawKind = rawKindValue is String ? rawKindValue : null;
    final behaviorKind =
        rawKind == 'commands' ||
            rawKind == 'config_option_update' ||
            rawKind == 'mode' ||
            rawKind == 'usage_update' ||
            rawKind == 'session_info_update'
        ? rawKind as String
        : null;
    final behaviorRejected = behaviorKind != null && guarded.omission != null;
    final behaviorRejectedAll =
        event.type == AgentEventType.status &&
        guarded.omission != null &&
        behaviorKind == null &&
        rawKind == null;
    final thoughtMetadataRejected =
        event.type == AgentEventType.status &&
        rawKind == 'thought' &&
        guarded.omission != null;
    final invalidUsageCost =
        rawKind == 'usage_update' &&
        guarded.omission == null &&
        !_usageCostFromObject(guarded.metadata['cost']).valid;
    var safeMetadata = thoughtMetadataRejected
        ? const <String, Object?>{'kind': 'thought'}
        : behaviorRejected || behaviorRejectedAll
        ? Map<String, Object?>.unmodifiable(<String, Object?>{
            if (behaviorKind == 'config_option_update') ...guarded.metadata,
            if (behaviorKind != null && behaviorKind != 'config_option_update')
              'kind': behaviorKind,
            if (behaviorRejected) '_behaviorRejected': true,
            if (behaviorRejectedAll) '_behaviorRejectedAll': true,
          })
        : guarded.metadata;
    if (invalidUsageCost) {
      safeMetadata = Map<String, Object?>.unmodifiable(<String, Object?>{
        ...safeMetadata,
        '_invalidUsageCost': true,
      });
    }
    final media = _sanitizeEventMedia(safeMetadata);
    safeMetadata = media.metadata;
    final safeKind = safeMetadata['kind'];
    final guardsDisplayText =
        event.type == AgentEventType.userMessage ||
        event.type == AgentEventType.toolCall ||
        (event.type == AgentEventType.status &&
            safeKind != 'thought' &&
            safeKind != 'usage_update' &&
            safeKind != 'session_info_update');
    final displayText = guardsDisplayText
        ? _boundedLocalDisplayText(event.text, resource: 'display text')
        : (text: event.text, omission: null);
    var guardedOmissions = projectionBoundedChatMessageOmissions(
      event.omissions,
      _dedupeTurnMediaOmission(guarded.omission),
      inputBudget.maxCollectionItems,
    );
    for (final omission in guarded.localOmissions) {
      guardedOmissions = projectionBoundedChatMessageOmissions(
        guardedOmissions,
        _dedupeTurnMediaOmission(omission),
        inputBudget.maxCollectionItems,
      );
    }
    guardedOmissions = projectionBoundedChatMessageOmissions(
      guardedOmissions,
      displayText.omission,
      inputBudget.maxCollectionItems,
    );
    return AgentEvent(
      type: event.type,
      text: behaviorRejected || behaviorRejectedAll ? '' : displayText.text,
      timestamp: event.timestamp,
      metadata: safeMetadata,
      omissions: projectionBoundedChatMessageOmissions(
        guardedOmissions,
        media.omission,
        inputBudget.maxCollectionItems,
      ),
    );
  }

  acp.ChatInputOmission? _dedupeTurnMediaOmission(
    acp.ChatInputOmission? omission,
  ) {
    if (omission == null) return null;
    if (omission.resource != 'image_data' &&
        omission.resource != 'audio_data' &&
        omission.resource != 'resource_blob' &&
        omission.resource != 'turn_media') {
      return omission;
    }
    final turnBudget = _ensureTurnBudget();
    final key = '${omission.reason.name}\u0000${omission.resource}';
    return turnBudget.mediaOmissionKeys.add(key) ? omission : null;
  }

  ({Map<String, Object?> metadata, acp.ChatInputOmission? omission})
  _sanitizeEventMedia(Map<String, Object?> metadata) {
    final rawBlocks = metadata['contentBlocks'];
    if (rawBlocks is! List) return (metadata: metadata, omission: null);
    final turnBudget = _ensureTurnBudget();
    final blocks = <Object?>[];
    acp.ChatInputOmission? omission;
    var changed = false;
    for (final rawBlock in rawBlocks) {
      if (rawBlock is! Map<String, Object?>) {
        blocks.add(rawBlock);
        continue;
      }
      final type = rawBlock['type'];
      Object? encoded;
      String? resource;
      if (type == 'image') {
        encoded = rawBlock['data'];
        resource = 'image_data';
      } else if (type == 'audio' && rawBlock['data'] != null) {
        encoded = rawBlock['data'];
        resource = 'audio_data';
      } else if (type == 'resource') {
        final nested = rawBlock['resource'];
        if (nested is Map<String, Object?> && nested['blob'] != null) {
          encoded = nested['blob'];
          resource = 'resource_blob';
        }
      }
      if (resource == null) {
        blocks.add(rawBlock);
        continue;
      }
      if (turnBudget.mediaRootDrained) {
        changed = true;
        final drainedOmission = acp.ChatInputOmission(
          reason: acp.ChatInputOmissionReason.inputLimit,
          resource: 'turn_media',
          truncated: false,
          limit: inputBudget.maxEmbeddedMediaBytes,
          observedAtLeast: inputBudget.maxEmbeddedMediaBytes + 1,
        );
        blocks.add(projectionMediaOmissionProjection(drainedOmission));
        omission ??= acp.ChatInputOmission(
          reason: acp.ChatInputOmissionReason.inputLimit,
          resource: 'turn_media',
          truncated: false,
          limit: inputBudget.maxEmbeddedMediaBytes,
          observedAtLeast: inputBudget.maxEmbeddedMediaBytes + 1,
        );
        continue;
      }
      if (encoded is! String) {
        changed = true;
        final invalid = acp.ChatInputOmission(
          reason: acp.ChatInputOmissionReason.invalidStructure,
          resource: resource,
          truncated: false,
        );
        blocks.add(projectionMediaOmissionProjection(invalid));
        omission ??= invalid;
        continue;
      }
      // The content-block guard immediately before this phase already scanned
      // and detached this Base64 string. Count the validated encoding in O(1)
      // here so aggregate admission does not scan the same payload again.
      final decodedBytes = projectionValidatedAcpBase64DecodedBytes(encoded);
      if (decodedBytes >
          inputBudget.maxEmbeddedMediaBytes - turnBudget.mediaBytes) {
        turnBudget.mediaRootDrained = true;
        changed = true;
        final aggregate = acp.ChatInputOmission(
          reason: acp.ChatInputOmissionReason.inputLimit,
          resource: 'turn_media',
          truncated: false,
          limit: inputBudget.maxEmbeddedMediaBytes,
          observedAtLeast: inputBudget.maxEmbeddedMediaBytes + 1,
        );
        blocks.add(projectionMediaOmissionProjection(aggregate));
        omission ??= aggregate;
        continue;
      }
      turnBudget.mediaBytes += decodedBytes;
      blocks.add(rawBlock);
    }
    if (!changed) return (metadata: metadata, omission: null);
    omission = _dedupeTurnMediaOmission(omission);
    return (
      metadata: Map<String, Object?>.unmodifiable(<String, Object?>{
        ...metadata,
        'contentBlocks': List<Object?>.unmodifiable(blocks),
      }),
      omission: omission,
    );
  }

  void _handleAgentEvent(AgentEvent event, {bool notify = true}) {
    if (_isDisposed) return;
    final startsNewTurn = event.type == AgentEventType.userMessage;
    if (startsNewTurn) {
      if (notify) {
        _materializeTurnTargets();
        _flushStreamingNotification();
        if (_isDisposed) return;
      }
      // A replayed/live user message is the next turn. Release the previous
      // counters before inspecting any media carried by the new message.
      _finishTurnBudget();
      _startLocalTurn();
    }
    event = _safeAgentEvent(event);
    if (_isDisposed) return;
    final coalescesNotification =
        event.type == AgentEventType.agentTextDelta ||
        (event.type == AgentEventType.status &&
            event.metadata['kind'] == 'thought');
    final coalescedTargetBefore = event.type == AgentEventType.agentTextDelta
        ? _turnBudget?.textTarget
        : _turnBudget?.thoughtTarget;
    final coalescedRevisionBefore = coalescedTargetBefore?.revision;
    final messageCountBefore = messages.length;
    if (notify && !coalescesNotification && !startsNewTurn) {
      _materializeTurnTargets();
      _flushStreamingNotification();
      if (_isDisposed) return;
    }
    _beginAgentEventProjection();
    late final AgentEvent observedEvent;
    try {
      switch (event.type) {
        case AgentEventType.userMessage:
          _addTurnMessage(
            ChatMessage(
              role: ChatMessageRole.user,
              text: event.text,
              metadata: event.metadata,
              omissions: event.omissions,
              inputBudget: inputBudget,
            ),
          );
        case AgentEventType.agentTextDelta:
          _appendText(
            ChatMessageRole.assistant,
            event.text,
            metadata: event.metadata,
            omissions: event.omissions,
          );
        case AgentEventType.agentTextDone:
          _appendTurnStatus(event);
          _finishStreaming(notify: false, suppressProjection: true);
        case AgentEventType.toolCall:
          _appendToolCall(event);
        case AgentEventType.error:
          final boundedError = _boundedLocalErrorText(
            _messageForAgentError(event),
          );
          final errorMessage = ChatMessage(
            role: ChatMessageRole.error,
            text: boundedError.text,
            omissions: projectionBoundedChatMessageOmissions(
              event.omissions,
              boundedError.omission,
              inputBudget.maxCollectionItems,
            ),
            inputBudget: inputBudget,
          );
          final accepted = _addTurnMessage(errorMessage);
          lastError = accepted?.text;
          status = ConnectionStatus.error;
          _finishStreaming(notify: false, suppressProjection: true);
        case AgentEventType.status:
          _appendStatus(event);
      }
      observedEvent = _finishAgentEventProjection(event);
    } finally {
      _trackingAgentEvent = false;
    }
    _notifyAgentEventObservers(observedEvent);
    if (notify) {
      if (coalescesNotification) {
        final coalescedTargetAfter = event.type == AgentEventType.agentTextDelta
            ? _turnBudget?.textTarget
            : _turnBudget?.thoughtTarget;
        final didChange =
            messages.length != messageCountBefore ||
            !identical(coalescedTargetAfter, coalescedTargetBefore) ||
            coalescedTargetAfter?.revision != coalescedRevisionBefore;
        if (didChange) _scheduleStreamingNotification();
      } else {
        _notifyListeners();
      }
    }
  }

  void _beginAgentEventProjection() {
    _trackingAgentEvent = true;
    _eventPayloadAccepted = false;
    _eventAcceptedText = '';
    _eventHasMessageProjection = false;
    _eventAcceptedMetadata = const <String, Object?>{};
    _eventAcceptedOmissions = const <acp.ChatInputOmission>[];
    _eventAcceptedTextOmission = null;
    _eventRootOmission = null;
  }

  AgentEvent _finishAgentEventProjection(AgentEvent event) {
    final isTextEvent =
        event.type == AgentEventType.agentTextDelta ||
        (event.type == AgentEventType.status &&
            event.metadata['kind'] == 'thought');
    final acceptedMetadata = _eventPayloadAccepted
        ? Map<String, Object?>.unmodifiable(<String, Object?>{
            for (final entry in event.metadata.entries)
              if (!entry.key.startsWith('_behavior')) entry.key: entry.value,
          })
        : const <String, Object?>{};
    final behaviorProjection =
        event.metadata['_invalidUsageCost'] != true &&
        (event.metadata['_behaviorRejected'] == true ||
            event.metadata['_behaviorRejectedAll'] == true);
    final projectedText = isTextEvent
        ? _eventAcceptedText
        : !_eventPayloadAccepted || behaviorProjection
        ? ''
        : _eventHasMessageProjection
        ? _eventAcceptedText
        : event.text;
    final projectedMetadata = !_eventPayloadAccepted
        ? const <String, Object?>{}
        : behaviorProjection
        ? acceptedMetadata
        : _eventHasMessageProjection
        ? _eventAcceptedMetadata
        : acceptedMetadata;
    final acceptedOmissions = _eventHasMessageProjection
        ? _eventAcceptedOmissions
        : event.omissions;
    final projected = AgentEvent(
      type: event.type,
      text: projectedText,
      timestamp: event.timestamp,
      metadata: projectedMetadata,
      omissions: projectionBoundedChatMessageOmissions(
        projectionBoundedChatMessageOmissions(
          acceptedOmissions,
          _eventAcceptedTextOmission,
          inputBudget.maxCollectionItems,
        ),
        _eventRootOmission,
        inputBudget.maxCollectionItems,
      ),
    );
    _trackingAgentEvent = false;
    return projected;
  }

  void _markAgentEventAccepted({String text = ''}) {
    if (!_trackingAgentEvent || _suppressAgentEventProjection) return;
    _eventPayloadAccepted = true;
    if (text.isNotEmpty) _eventAcceptedText += text;
  }

  void _markAgentEventMessageAccepted(ChatMessage message) {
    if (!_trackingAgentEvent || _suppressAgentEventProjection) return;
    _eventPayloadAccepted = true;
    _eventHasMessageProjection = true;
    _eventAcceptedText = message.text;
    _eventAcceptedMetadata = message.metadata;
    _eventAcceptedOmissions = message.omissions;
  }

  void _markAgentEventProjectionAccepted({
    required String text,
    required Map<String, Object?> metadata,
    List<acp.ChatInputOmission> omissions = const <acp.ChatInputOmission>[],
  }) {
    if (!_trackingAgentEvent || _suppressAgentEventProjection) return;
    _eventPayloadAccepted = true;
    _eventHasMessageProjection = true;
    _eventAcceptedText = text;
    _eventAcceptedMetadata = Map<String, Object?>.unmodifiable(metadata);
    _eventAcceptedOmissions = List<acp.ChatInputOmission>.unmodifiable(
      omissions,
    );
  }

  void _appendToolCall(AgentEvent event) {
    final toolCallId = _toolCallIdFromMetadata(event.metadata);
    if (toolCallId.isEmpty) {
      _addTurnMessage(
        ChatMessage(
          role: ChatMessageRole.tool,
          text: event.text,
          metadata: event.metadata,
          omissions: event.omissions,
          inputBudget: inputBudget,
        ),
      );
      return;
    }

    final index = findChatToolMessage(messages, toolCallId);
    if (index >= 0) {
      final message = messages[index];
      _replaceTurnMessage(
        index,
        ChatMessage(
          role: ChatMessageRole.tool,
          text: event.text.trim().isEmpty ? message.text : event.text,
          timestamp: message.timestamp,
          metadata: mergeChatToolMetadata(message.metadata, event.metadata),
          omissions: [...message.omissions, ...event.omissions],
          inputBudget: inputBudget,
        ),
      );
      return;
    }

    _addTurnMessage(
      ChatMessage(
        role: ChatMessageRole.tool,
        text: event.text,
        metadata: event.metadata,
        omissions: event.omissions,
        inputBudget: inputBudget,
      ),
    );
  }

  void _notifyAgentEventObservers(AgentEvent event) {
    if (_agentEventObservers.isEmpty) return;
    final session = currentSession;
    for (final observer in List<ChatAgentEventObserver>.from(
      _agentEventObservers,
    )) {
      unawaited(
        Future<void>.sync(() => observer(session, event)).catchError((
          Object error,
          StackTrace stackTrace,
        ) {
          FlutterError.reportError(
            FlutterErrorDetails(
              exception: error,
              stack: stackTrace,
              library: 'ianvs_acp',
              context: ErrorDescription('while notifying an agent observer'),
            ),
          );
        }),
      );
    }
  }

  void _notifyPermissionEventObservers(ChatPermissionEvent event) {
    if (_permissionEventObservers.isEmpty) return;
    for (final observer in List<ChatPermissionEventObserver>.from(
      _permissionEventObservers,
    )) {
      unawaited(
        Future<void>.sync(() => observer(event)).catchError((
          Object error,
          StackTrace stackTrace,
        ) {
          FlutterError.reportError(
            FlutterErrorDetails(
              exception: error,
              stack: stackTrace,
              library: 'ianvs_acp',
              context: ErrorDescription(
                'while notifying a permission observer',
              ),
            ),
          );
        }),
      );
    }
  }

  void _handlePermissionRequest(ChatPermissionRequest incomingRequest) {
    final request = incomingRequest.withGeneration(
      ++_nextPermissionRequestGeneration,
    );
    final requestSessionId = request.sessionId.trim();

    if (requestSessionId.isNotEmpty &&
        _isRetiredPermissionSession(requestSessionId)) {
      unawaited(
        _sendPermissionDecision(
          id: request.id,
          decision: ChatPermissionDecision.cancel,
          reportErrors: false,
        ),
      );
      return;
    }

    if (!_isPermissionRequestForActiveSession(request)) {
      _recordPermissionRequest(request);
      _recordPermissionDecision(
        request,
        ChatPermissionDecision.cancel,
        source: ChatPermissionDecisionSource.system,
      );
      unawaited(
        _sendPermissionDecision(
          id: request.id,
          decision: ChatPermissionDecision.cancel,
          reportErrors: false,
        ),
      );
      _notifyListeners();
      return;
    }

    final previous = pendingPermissionRequest;
    if (previous != null) {
      _recordPermissionDecision(
        previous,
        ChatPermissionDecision.cancel,
        source: ChatPermissionDecisionSource.system,
      );
      if (previous.id != request.id) {
        unawaited(
          _sendPermissionDecision(
            id: previous.id,
            decision: ChatPermissionDecision.cancel,
            reportErrors: false,
          ),
        );
      }
    }
    pendingPermissionRequest = request;
    _recordPromptActivity();
    _recordPermissionRequest(request);
    _notifyPermissionEventObservers(
      ChatPermissionEvent.requested(_permissionRequestForAudit(request)),
    );
    _resolvePendingPermissionForPolicy(request);
    _notifyListeners();
  }

  bool _isCurrentPermissionRequest(ChatPermissionRequest request) {
    return pendingPermissionRequest?.bindingKey == request.bindingKey;
  }

  bool _isPermissionRequestForActiveSession(ChatPermissionRequest request) {
    final requestSessionId = request.sessionId.trim();
    if (requestSessionId.isEmpty) return false;
    final session = currentSession;
    if (_sessionIdsMatch(session?.id, requestSessionId)) return true;
    if (_isPendingSessionSetup) return true;
    if (_isRetiredPermissionSession(requestSessionId)) return false;
    if (session == null) return true;
    return false;
  }

  bool _isRetiredPermissionSession(String sessionId) {
    if (_sessionIdsMatch(currentSession?.id, sessionId)) return false;
    if (_isPendingSessionSetup) return false;
    return _retiredSessionIds.contains(sessionId) || _retiredSessionIdsOverflow;
  }

  bool get _isPendingSessionSetup {
    final generation = _pendingSessionSetupGeneration;
    return generation != null &&
        !_isDisposed &&
        generation == _sessionOperationGeneration;
  }

  void _retireSessionId(String sessionId) {
    final normalizedSessionId = sessionId.trim();
    if (normalizedSessionId.isEmpty) return;
    _retiredSessionIds.remove(normalizedSessionId);
    _retiredSessionIds.add(normalizedSessionId);
    while (_retiredSessionIds.length > permissionHistoryLimit) {
      _retiredSessionIds.remove(_retiredSessionIds.first);
      _retiredSessionIdsOverflow = true;
    }
  }

  void _handlePermissionRequestsDone() {
    if (_isDisposed) return;
    _permissionRequestStreamDone = true;
    _cancelPendingPermissionAfterRequestStreamDone();
  }

  void _cancelPendingPermissionAfterRequestStreamDone() {
    if (_isDisposed || !_permissionRequestStreamDone) return;
    final request = pendingPermissionRequest;
    if (request == null) return;
    if (_resolvingPermissionRequestIds.contains(request.bindingKey)) return;
    pendingPermissionRequest = null;
    _recordPromptActivity();
    _recordPermissionDecision(
      request,
      ChatPermissionDecision.cancel,
      source: ChatPermissionDecisionSource.system,
    );
    _notifyListeners();
  }

  void _handlePermissionInvalidation(ChatPermissionInvalidation event) {
    if (_isDisposed) return;
    final request = pendingPermissionRequest;
    if (request == null ||
        request.id != event.requestId ||
        request.lifecycleId != event.lifecycleId ||
        request.sessionId != event.sessionId) {
      return;
    }
    final bindingKey = request.bindingKey;
    pendingPermissionRequest = null;
    _recordPromptActivity();
    _resolvingPermissionRequestIds.remove(bindingKey);
    _reviewingPermissionRequestIds.remove(bindingKey);
    _recordPermissionDecision(
      request,
      ChatPermissionDecision.cancel,
      source: ChatPermissionDecisionSource.system,
    );
    _notifyListeners();
  }

  ChatPermissionDecision? _trustedDecisionFor(ChatPermissionRequest request) {
    for (final rule in permissionTrustRules) {
      if (rule.matches(request)) return rule.decision;
    }
    return null;
  }

  void _resolvePendingPermissionForPolicy(ChatPermissionRequest request) {
    switch (toolCallExecutionPolicy) {
      case ChatToolCallExecutionPolicy.defaultPermissions:
        return;
      case ChatToolCallExecutionPolicy.autoReview:
        final trustedDecision = _trustedDecisionFor(request);
        if (trustedDecision != null) {
          unawaited(
            _resolvePermissionRequest(
              request,
              trustedDecision,
              source: ChatPermissionDecisionSource.trustRule,
            ),
          );
          return;
        }
        _startPermissionReview(request);
        return;
      case ChatToolCallExecutionPolicy.fullAccess:
        unawaited(
          _resolvePermissionRequest(
            request,
            ChatPermissionDecision.allow,
            source: ChatPermissionDecisionSource.policy,
          ),
        );
        return;
    }
  }

  Future<void> _resolvePermissionRequest(
    ChatPermissionRequest request,
    ChatPermissionDecision decision, {
    required ChatPermissionDecisionSource source,
    ChatPermissionReviewResult? reviewResult,
    String? selectedOptionId,
  }) async {
    if (_isDisposed) return;
    if (!_isCurrentPermissionRequest(request)) return;
    if (!_isPermissionRequestForActiveSession(request)) return;
    final bindingKey = request.bindingKey;
    if (!_resolvingPermissionRequestIds.add(bindingKey)) return;
    try {
      final resolvedOptionId =
          selectedOptionId ?? request.singleUseChoiceFor(decision)?.optionId;
      if (decision != ChatPermissionDecision.cancel &&
          request.choices.isNotEmpty &&
          resolvedOptionId == null) {
        return;
      }
      if (!_isCurrentPermissionRequest(request)) return;
      if (!_isPermissionRequestForActiveSession(request)) return;
      final didSend = await _sendPermissionDecision(
        id: request.id,
        decision: decision,
        selectedOptionId: resolvedOptionId,
      );
      if (_isDisposed || !didSend) return;
      if (!_isCurrentPermissionRequest(request)) return;
      if (!_isPermissionRequestForActiveSession(request)) return;
      pendingPermissionRequest = null;
      _recordPromptActivity();
      _recordPermissionDecision(
        request,
        decision,
        source: source,
        reviewResult: reviewResult,
        selectedOptionId: resolvedOptionId,
      );
      _notifyListeners();
    } finally {
      _resolvingPermissionRequestIds.remove(bindingKey);
      _cancelPendingPermissionAfterRequestStreamDone();
    }
  }

  void _startPermissionReview(ChatPermissionRequest request) {
    if (_isDisposed) return;
    final reviewer = permissionReviewer;
    if (reviewer == null) return;
    final bindingKey = request.bindingKey;
    if (!_reviewingPermissionRequestIds.add(bindingKey)) return;
    unawaited(() async {
      try {
        final reviewSession = currentSession;
        final reviewWorkspaceRoot = reviewSession?.cwd.trim().isNotEmpty == true
            ? reviewSession!.cwd
            : cwd;
        final reviewAdditionalDirectories = reviewSession == null
            ? additionalDirectories
            : reviewSession.additionalDirectories;
        final result = await reviewer.review(
          request,
          workspaceRoot: reviewWorkspaceRoot,
          additionalDirectories: reviewAdditionalDirectories,
          model: currentModelValue,
        );
        if (_isDisposed) return;
        if (result == null) return;
        final boundedResult = sanitizeChatPermissionReviewResult(
          result,
          inputBudget: inputBudget,
          maxEncodedBytes: permissionReviewResultEncodedByteLimit,
        );
        _recordPermissionReview(request, boundedResult);
        final decision = boundedResult.decision;
        if (decision == null) {
          _notifyListeners();
          return;
        }
        if (decision == ChatPermissionDecision.allow &&
            (!reviewer.canAutoApprove ||
                boundedResult.risk.trim().toLowerCase() != 'low')) {
          _notifyListeners();
          return;
        }
        if (!_isCurrentPermissionRequest(request)) return;
        await _resolvePermissionRequest(
          request,
          decision,
          source: ChatPermissionDecisionSource.reviewAgent,
          reviewResult: boundedResult,
        );
      } catch (error) {
        if (!_isDisposed && _isCurrentPermissionRequest(request)) {
          _setActionError(error);
        }
      } finally {
        _reviewingPermissionRequestIds.remove(bindingKey);
      }
    }());
  }

  Future<bool> _sendPermissionDecision({
    required String id,
    required ChatPermissionDecision decision,
    String? selectedOptionId,
    bool reportErrors = true,
  }) async {
    try {
      await client.respondToPermissionRequest(
        id: id,
        decision: decision,
        selectedOptionId: selectedOptionId,
      );
      return true;
    } catch (error) {
      if (reportErrors) {
        _setActionError(error);
      }
      return false;
    }
  }

  Future<Object?> _cancelPendingPermissionRequest({
    bool reportErrors = true,
  }) async {
    final request = pendingPermissionRequest;
    if (request == null) return null;
    pendingPermissionRequest = null;
    _recordPermissionDecision(
      request,
      ChatPermissionDecision.cancel,
      source: ChatPermissionDecisionSource.system,
    );
    try {
      await client.respondToPermissionRequest(
        id: request.id,
        decision: ChatPermissionDecision.cancel,
      );
      return null;
    } catch (error) {
      if (reportErrors) _setActionError(error);
      return error;
    }
  }

  void _cancelPendingPermissionOutsideSession(String? sessionId) {
    final request = pendingPermissionRequest;
    if (request == null) return;
    final activeSessionId = sessionId?.trim();
    if (activeSessionId != null &&
        activeSessionId.isNotEmpty &&
        request.sessionId.trim() == activeSessionId) {
      return;
    }
    pendingPermissionRequest = null;
    _recordPermissionDecision(
      request,
      ChatPermissionDecision.cancel,
      source: ChatPermissionDecisionSource.system,
    );
    unawaited(
      _sendPermissionDecision(
        id: request.id,
        decision: ChatPermissionDecision.cancel,
        reportErrors: false,
      ),
    );
  }

  void _cancelPendingPermissionRequestAfterPromptEnd() {
    final request = pendingPermissionRequest;
    if (request == null) return;
    pendingPermissionRequest = null;
    _recordPermissionDecision(
      request,
      ChatPermissionDecision.cancel,
      source: ChatPermissionDecisionSource.system,
    );
    unawaited(
      _sendPermissionDecision(
        id: request.id,
        decision: ChatPermissionDecision.cancel,
        reportErrors: false,
      ),
    );
  }

  void _recordPermissionRequest(ChatPermissionRequest request) {
    final entry = ChatPermissionAuditEntry(
      request: _permissionRequestForAudit(request),
      status: ChatPermissionAuditStatus.pending,
      recordedAt: request.requestedAt,
    );
    _permissionHistory.insert(0, entry);
    final encodedBytes = chatPermissionAuditEntryEncodedBytes(entry);
    _permissionHistoryEntryEncodedBytes.insert(0, encodedBytes);
    _permissionHistoryEncodedBytes += encodedBytes;
    _trimPermissionHistory();
    _permissionHistoryRevision += 1;
  }

  ChatPermissionRequest _permissionRequestForAudit(
    ChatPermissionRequest request,
  ) {
    return request.forAudit(
      metadata: redactedPermissionMetadataForAudit(request),
      title: redactedPermissionTitleForAudit(request),
      rationale: redactedPermissionRationaleForAudit(request),
    );
  }

  void _trimPermissionHistory() {
    while (_permissionHistory.length > permissionHistoryLimit ||
        _permissionHistoryEncodedBytes > permissionHistoryEncodedByteLimit) {
      final evicted = _permissionHistory.removeLast();
      final sessionId = evicted.request.sessionId.trim();
      if (sessionId.isNotEmpty) {
        _permissionHistoryOverflowExemptSessionIds.remove(sessionId);
        _permissionHistoryTruncatedSessionIds.remove(sessionId);
        _permissionHistoryTruncatedSessionIds.add(sessionId);
      }
      _permissionHistoryEncodedBytes -= _permissionHistoryEntryEncodedBytes
          .removeLast();
    }
    final retainedSessionIds = _permissionHistory
        .map((entry) => entry.request.sessionId.trim())
        .where((sessionId) => sessionId.isNotEmpty)
        .toSet();
    final protectedSessionIds = <String>{...retainedSessionIds};
    final activeSessionId = currentSession?.id.trim();
    if (activeSessionId != null && activeSessionId.isNotEmpty) {
      protectedSessionIds.add(activeSessionId);
    }
    protectedSessionIds.addAll(
      sessions
          .map((session) => session.id.trim())
          .where((sessionId) => sessionId.isNotEmpty),
    );
    protectedSessionIds.addAll(
      _sessionViewSnapshots.values
          .map((snapshot) => snapshot.session.id.trim())
          .where((sessionId) => sessionId.isNotEmpty),
    );
    final excessMarkerIds =
        _permissionHistoryTruncatedSessionIds.length - permissionHistoryLimit;
    if (excessMarkerIds > 0 && !_permissionHistoryProvenanceOverflow) {
      _permissionHistoryProvenanceOverflow = true;
      for (final sessionId in protectedSessionIds) {
        if (!_permissionHistoryTruncatedSessionIds.contains(sessionId)) {
          _rememberPermissionHistoryOverflowExemption(sessionId);
        }
      }
    }
    final evictedMarkerIds = _permissionHistoryTruncatedSessionIds
        .take(excessMarkerIds < 0 ? 0 : excessMarkerIds)
        .toList(growable: false);
    for (final sessionId in evictedMarkerIds) {
      _permissionHistoryTruncatedSessionIds.remove(sessionId);
      _permissionHistoryOverflowExemptSessionIds.remove(sessionId);
    }
  }

  void _markPermissionHistoryCompleteForSession(String sessionId) {
    final normalizedSessionId = sessionId.trim();
    if (normalizedSessionId.isEmpty) return;
    _permissionHistoryTruncatedSessionIds.remove(normalizedSessionId);
    if (_permissionHistoryProvenanceOverflow) {
      _rememberPermissionHistoryOverflowExemption(normalizedSessionId);
    }
  }

  void _rememberPermissionHistoryOverflowExemption(String sessionId) {
    _permissionHistoryOverflowExemptSessionIds.remove(sessionId);
    _permissionHistoryOverflowExemptSessionIds.add(sessionId);
    while (_permissionHistoryOverflowExemptSessionIds.length >
        permissionHistoryLimit) {
      _permissionHistoryOverflowExemptSessionIds.remove(
        _permissionHistoryOverflowExemptSessionIds.first,
      );
    }
  }

  void _removePermissionHistoryForSession(String sessionId) {
    final normalizedSessionId = sessionId.trim();
    if (normalizedSessionId.isEmpty) return;
    var changed = false;
    for (var index = _permissionHistory.length - 1; index >= 0; index -= 1) {
      if (_permissionHistory[index].request.sessionId.trim() !=
          normalizedSessionId) {
        continue;
      }
      _permissionHistory.removeAt(index);
      _permissionHistoryEncodedBytes -= _permissionHistoryEntryEncodedBytes
          .removeAt(index);
      changed = true;
    }
    changed =
        _permissionHistoryTruncatedSessionIds.remove(normalizedSessionId) ||
        changed;
    if (_permissionHistoryProvenanceOverflow) {
      _rememberPermissionHistoryOverflowExemption(normalizedSessionId);
    }
    if (changed) _permissionHistoryRevision += 1;
  }

  void _clearPermissionHistory() {
    if (_permissionHistory.isEmpty &&
        _permissionHistoryTruncatedSessionIds.isEmpty &&
        !_permissionHistoryProvenanceOverflow) {
      return;
    }
    _permissionHistory.clear();
    _permissionHistoryEntryEncodedBytes.clear();
    _permissionHistoryEncodedBytes = 0;
    _permissionHistoryTruncatedSessionIds.clear();
    _permissionHistoryProvenanceOverflow = false;
    _permissionHistoryOverflowExemptSessionIds.clear();
    _permissionHistoryRevision += 1;
  }

  void _replacePermissionHistoryEntry(
    int index,
    ChatPermissionAuditEntry replacement,
  ) {
    final replacementBytes = chatPermissionAuditEntryEncodedBytes(replacement);
    final previousBytes = _permissionHistoryEntryEncodedBytes[index];
    _permissionHistory[index] = replacement;
    _permissionHistoryEntryEncodedBytes[index] = replacementBytes;
    _permissionHistoryEncodedBytes += replacementBytes - previousBytes;
    _trimPermissionHistory();
    _permissionHistoryRevision += 1;
  }

  void _recordPermissionDecision(
    ChatPermissionRequest request,
    ChatPermissionDecision decision, {
    ChatPermissionDecisionSource source = ChatPermissionDecisionSource.manual,
    ChatPermissionReviewResult? reviewResult,
    String? selectedOptionId,
  }) {
    final index = _permissionHistory.indexWhere(
      (entry) => entry.request.bindingKey == request.bindingKey,
    );
    if (index == -1) return;
    final recordedRequest = _permissionHistory[index].request;
    final status = _permissionAuditStatus(decision);
    final boundedReviewResult = reviewResult == null
        ? null
        : sanitizeChatPermissionReviewResult(
            reviewResult,
            inputBudget: inputBudget,
            maxEncodedBytes: permissionReviewResultEncodedByteLimit,
          );
    _replacePermissionHistoryEntry(
      index,
      _permissionHistory[index].copyWith(
        status: _permissionAuditStatus(decision),
        resolvedAt: DateTime.now(),
        decisionSource: source,
        reviewResult: boundedReviewResult,
        selectedOptionId: selectedOptionId,
      ),
    );
    _notifyPermissionEventObservers(
      ChatPermissionEvent.resolved(
        recordedRequest,
        decision: decision,
        decisionSource: source,
        status: status,
      ),
    );
  }

  void _recordPermissionReview(
    ChatPermissionRequest request,
    ChatPermissionReviewResult reviewResult,
  ) {
    final index = _permissionHistory.indexWhere(
      (entry) => entry.request.bindingKey == request.bindingKey,
    );
    if (index == -1) return;
    final boundedReviewResult = sanitizeChatPermissionReviewResult(
      reviewResult,
      inputBudget: inputBudget,
      maxEncodedBytes: permissionReviewResultEncodedByteLimit,
    );
    _replacePermissionHistoryEntry(
      index,
      _permissionHistory[index].copyWith(reviewResult: boundedReviewResult),
    );
  }

  ChatPermissionAuditStatus _permissionAuditStatus(
    ChatPermissionDecision decision,
  ) {
    return switch (decision) {
      ChatPermissionDecision.allow => ChatPermissionAuditStatus.allowed,
      ChatPermissionDecision.deny => ChatPermissionAuditStatus.denied,
      ChatPermissionDecision.cancel => ChatPermissionAuditStatus.cancelled,
    };
  }

  _TurnBudgetState _ensureTurnBudget() {
    _activeTurnId ??= ++_nextTurnId;
    return _turnBudget ??= _TurnBudgetState(inputBudget);
  }

  void _startLocalTurn() {
    _activeTurnId = ++_nextTurnId;
  }

  @visibleForTesting
  void addMessageForTesting(ChatMessage message, {bool startsNewTurn = false}) {
    if (startsNewTurn) {
      _finishTurnBudget();
      _startLocalTurn();
      _turnBudget = _TurnBudgetState(inputBudget);
    }
    if (_addTurnMessage(message) == null) {
      throw StateError('The test message did not fit the turn budget.');
    }
    final session = currentSession;
    if (session != null) _removeLocalUnstartedSessionId(session.id);
  }

  @visibleForTesting
  void appendTextForTesting(String chunk) {
    if (_messages.isEmpty) {
      throw StateError('A message is required before appending text.');
    }
    _appendTextToMessage(_messages.last, chunk);
  }

  @visibleForTesting
  void appendTextToMessageForTesting(int index, String chunk) {
    _appendTextToMessage(_messages[index], chunk);
  }

  @visibleForTesting
  void setLastMessageTextForTesting(String text) {
    if (_messages.isEmpty) {
      throw StateError('A message is required before setting text.');
    }
    setMessageTextForTesting(_messages.length - 1, text);
  }

  @visibleForTesting
  void setMessageTextForTesting(int index, String text) {
    _messages[index].projectionSetTextForOwner(_messageOwnerToken, text);
    _mutateMessages(() {});
  }

  @visibleForTesting
  bool replaceLastMessageForTesting(ChatMessage replacement) {
    if (_messages.isEmpty) {
      throw StateError('A message is required before replacing it.');
    }
    return _replaceTurnMessage(_messages.length - 1, replacement);
  }

  @visibleForTesting
  void addOmissionForTesting(acp.ChatInputOmission omission) {
    if (_messages.isEmpty) {
      throw StateError('A message is required before adding an omission.');
    }
    final target = _messages.last;
    final applied = _applyTurnTextMutation(
      _ensureTurnBudget(),
      parts: const <ChatTextAppend>[],
      omissionTarget: target,
      omission: omission,
    );
    if (!applied) throw StateError('The omission did not fit the turn budget.');
  }

  ChatMessage _prepareOwnedMessage(ChatMessage message, {required int turnId}) {
    if (message.projectionOwnerToken != null || message.turnId != null) {
      throw StateError('Cannot admit an already-owned chat message.');
    }
    final owned = message.projectionCopyForBudget(
      inputBudget,
      frozen: false,
      preserveTurnId: false,
    );
    owned.projectionClaimOwnership(_messageOwnerToken, turnId);
    return owned;
  }

  ChatMessage? _appendTimelineMessage(
    ChatMessage message, {
    bool allowCompleteTurnEviction = true,
  }) {
    final owned = _prepareOwnedMessage(
      message,
      turnId: _activeTurnId ?? ++_nextTurnId,
    );
    return _appendOwnedTimelineMessage(
          owned,
          allowCompleteTurnEviction: allowCompleteTurnEviction,
        )
        ? owned
        : null;
  }

  bool _appendOwnedTimelineMessage(
    ChatMessage message, {
    bool allowCompleteTurnEviction = true,
  }) {
    message.projectionRequireOwner(_messageOwnerToken);
    if (!_canFitActiveMessageRetainedDelta(
      message.retainedBytes + projectionRetainedListItemHostBytes,
      allowCompleteTurnEviction: allowCompleteTurnEviction,
    )) {
      return false;
    }
    _mutateMessages(() => _messages.add(message));
    return true;
  }

  bool _canFitActiveMessageRetainedDelta(
    int retainedDelta, {
    bool allowCompleteTurnEviction = true,
  }) {
    if (_currentSession == null) return true;
    if (_uiStateTransactionDepth > 0) {
      _recomputeActiveUiStateRetainedBytes();
    }
    var projected = projectionCheckedRetainedAdd(
      projectionCheckedRetainedAdd(
        _activeUiStateRetainedBytes,
        _archivedLeaseRetainedBytes,
      ),
      retainedDelta,
    );
    if (projected <= inputBudget.maxUiStateBytes) return true;
    if (!allowCompleteTurnEviction) return false;
    for (final message in _messages) {
      if (_isHistoryMarker(message)) continue;
      final turnId = message.turnId;
      if (turnId == null || turnId == _activeTurnId) continue;
      projected -= message.retainedBytes + projectionRetainedListItemHostBytes;
      if (projected <= inputBudget.maxUiStateBytes) return true;
    }
    final historyMarker = _messages.where(_isHistoryMarker).firstOrNull;
    if (historyMarker != null) {
      projected -=
          historyMarker.retainedBytes + projectionRetainedListItemHostBytes;
    }
    return projected <= inputBudget.maxUiStateBytes;
  }

  bool _canFitTimelineReplacement(
    int index,
    ChatMessage replacement, {
    required int turnId,
  }) {
    if (_currentSession == null) return true;
    if (_uiStateTransactionDepth > 0) {
      _recomputeActiveUiStateRetainedBytes();
    }
    final previous = _messages[index];
    var projected =
        _activeUiStateRetainedBytes +
        _archivedLeaseRetainedBytes -
        previous.retainedBytes +
        replacement.retainedBytes;
    if (projected <= inputBudget.maxUiStateBytes) return true;
    for (
      var messageIndex = 0;
      messageIndex < _messages.length;
      messageIndex++
    ) {
      if (messageIndex == index) continue;
      final message = _messages[messageIndex];
      if (_isHistoryMarker(message)) continue;
      final messageTurnId = message.turnId;
      if (messageTurnId == null || messageTurnId == turnId) continue;
      projected -= message.retainedBytes + projectionRetainedListItemHostBytes;
      if (projected <= inputBudget.maxUiStateBytes) return true;
    }
    final historyMarker = _messages.where(_isHistoryMarker).firstOrNull;
    if (historyMarker != null) {
      projected -=
          historyMarker.retainedBytes + projectionRetainedListItemHostBytes;
    }
    return projected <= inputBudget.maxUiStateBytes;
  }

  bool _replaceTimelineMessage(
    int index,
    ChatMessage replacement, {
    required int turnId,
  }) {
    replacement.projectionRequireOwner(_messageOwnerToken);
    if (!_canFitTimelineReplacement(index, replacement, turnId: turnId)) {
      return false;
    }
    _mutateMessages(() => _messages[index] = replacement);
    return true;
  }

  void _replaceAllMessages(Iterable<ChatMessage> replacements) {
    final copied = <ChatMessage>[];
    final copiedTurnIds = <int, int>{};
    for (final message in replacements) {
      final previousTurnId = message.turnId;
      final turnId = previousTurnId == null
          ? ++_nextTurnId
          : copiedTurnIds.putIfAbsent(previousTurnId, () => ++_nextTurnId);
      final owned = message.projectionCopyForBudget(
        inputBudget,
        frozen: false,
        preserveTurnId: false,
      );
      owned.projectionClaimOwnership(_messageOwnerToken, turnId);
      copied.add(owned);
    }
    _mutateMessages(() {
      _messages
        ..clear()
        ..addAll(copied);
    });
    if (_messages.any(_isHistoryMarker)) {
      _timelineHistoryWasTruncated = true;
    }
  }

  void _clearMessages() {
    if (_messages.isNotEmpty) _mutateMessages(_messages.clear);
    if (_queuedPrompts.isNotEmpty) {
      _queuedPrompts.clear();
      _dispatchingQueuedPrompt = false;
      _guidanceInterruptionRunning = false;
    }
  }

  void _mutateMessages(VoidCallback mutation, {bool enforceBudget = true}) {
    mutation();
    messagesRevision += 1;
    _activeTimelineRetainedBytes = _estimateTimelineRetainedBytes(_messages);
    if (enforceBudget) {
      _enforceTimelineBudget();
      _refreshActiveUiStateBudget();
    }
  }

  bool get _timelineIsOverBudget {
    return _messages.length > inputBudget.maxTimelineItems ||
        _activeTimelineRetainedBytes > inputBudget.maxTimelineBytes;
  }

  bool _isHistoryMarker(ChatMessage message) {
    return message.omissions.any(
      (omission) => omission.resource == 'timeline history',
    );
  }

  void _enforceTimelineBudget() {
    if (_enforcingTimelineBudget) return;
    _enforcingTimelineBudget = true;
    var removedHistory = false;
    try {
      while (_timelineIsOverBudget) {
        int? oldestTurnId;
        for (final message in _messages) {
          if (_isHistoryMarker(message)) continue;
          final turnId = message.turnId;
          if (turnId == null || turnId == _activeTurnId) continue;
          oldestTurnId = turnId;
          break;
        }
        if (oldestTurnId == null) break;
        _mutateMessages(
          () => _messages.removeWhere(
            (message) => message.turnId == oldestTurnId,
          ),
          enforceBudget: false,
        );
        removedHistory = true;
        _timelineHistoryWasTruncated = true;
      }
      if (removedHistory && !_messages.any(_isHistoryMarker)) {
        final marker = _prepareOwnedMessage(
          ChatMessage(
            role: ChatMessageRole.status,
            text: '',
            omissions: <acp.ChatInputOmission>[
              acp.ChatInputOmission(
                reason: acp.ChatInputOmissionReason.inputLimit,
                resource: 'timeline history',
                truncated: true,
                limit: _messages.length > inputBudget.maxTimelineItems
                    ? inputBudget.maxTimelineItems
                    : inputBudget.maxTimelineBytes,
                observedAtLeast: _messages.length > inputBudget.maxTimelineItems
                    ? inputBudget.maxTimelineItems + 1
                    : inputBudget.maxTimelineBytes + 1,
              ),
            ],
            inputBudget: inputBudget,
          ),
          turnId: ++_nextTurnId,
        );
        _mutateMessages(
          () => _messages.insert(0, marker),
          enforceBudget: false,
        );
      }
      while (_timelineIsOverBudget) {
        int? oldestTurnId;
        for (final message in _messages) {
          if (_isHistoryMarker(message)) continue;
          final turnId = message.turnId;
          if (turnId == null || turnId == _activeTurnId) continue;
          oldestTurnId = turnId;
          break;
        }
        if (oldestTurnId == null) break;
        _mutateMessages(
          () => _messages.removeWhere(
            (message) => message.turnId == oldestTurnId,
          ),
          enforceBudget: false,
        );
      }
      if (_timelineIsOverBudget) {
        final markerIndex = _messages.indexWhere(_isHistoryMarker);
        if (markerIndex >= 0) {
          _mutateMessages(
            () => _messages.removeAt(markerIndex),
            enforceBudget: false,
          );
        }
      }
    } finally {
      _enforcingTimelineBudget = false;
    }
  }

  ChatMessage? _addTurnMessage(ChatMessage message) {
    final turnBudget = _ensureTurnBudget();
    final owned = _prepareOwnedMessage(message, turnId: _activeTurnId!);
    final retainedBytes = owned.retainedBytes;
    if (turnBudget.items >= turnBudget.normalItemLimit) {
      _recordTurnOverflow(
        turnBudget,
        resource: 'turn items',
        limit: turnBudget.normalItemLimit,
        observedAtLeast: turnBudget.normalItemLimit + 1,
      );
      return null;
    }
    if (retainedBytes >
        turnBudget.normalRetainedByteLimit - turnBudget.retainedBytes) {
      _recordTurnOverflow(
        turnBudget,
        resource: 'turn retained bytes',
        limit: turnBudget.normalRetainedByteLimit,
        observedAtLeast: turnBudget.normalRetainedByteLimit + 1,
      );
      return null;
    }
    if (!_appendOwnedTimelineMessage(owned)) {
      _recordTurnOverflow(
        turnBudget,
        resource: 'UI state retained bytes',
        limit: inputBudget.maxUiStateBytes,
        observedAtLeast: inputBudget.maxUiStateBytes + 1,
      );
      return null;
    }
    turnBudget.items += 1;
    turnBudget.retainedBytes += retainedBytes;
    turnBudget.messageRetainedBytes[owned] = retainedBytes;
    _markAgentEventMessageAccepted(owned);
    return owned;
  }

  bool _replaceTurnMessage(int index, ChatMessage replacement) {
    final turnBudget = _ensureTurnBudget();
    final previous = messages[index];
    final previousRetained = turnBudget.messageRetainedBytes[previous];
    final ownedReplacement = _prepareOwnedMessage(
      replacement,
      turnId: _activeTurnId!,
    );
    final replacementRetained = ownedReplacement.retainedBytes;
    if (previousRetained == null) {
      if (turnBudget.items >= turnBudget.normalItemLimit) {
        _recordTurnOverflow(
          turnBudget,
          resource: 'turn items',
          limit: turnBudget.normalItemLimit,
          observedAtLeast: turnBudget.normalItemLimit + 1,
        );
        return false;
      }
      if (replacementRetained >
          turnBudget.normalRetainedByteLimit - turnBudget.retainedBytes) {
        _recordTurnOverflow(
          turnBudget,
          resource: 'turn retained bytes',
          limit: turnBudget.normalRetainedByteLimit,
          observedAtLeast: turnBudget.normalRetainedByteLimit + 1,
        );
        return false;
      }
      if (!_replaceTimelineMessage(
        index,
        ownedReplacement,
        turnId: _activeTurnId!,
      )) {
        _recordTurnOverflow(
          turnBudget,
          resource: 'UI state retained bytes',
          limit: inputBudget.maxUiStateBytes,
          observedAtLeast: inputBudget.maxUiStateBytes + 1,
        );
        return false;
      }
      turnBudget.items += 1;
      turnBudget.retainedBytes += replacementRetained;
      turnBudget.messageRetainedBytes[ownedReplacement] = replacementRetained;
      _markAgentEventMessageAccepted(ownedReplacement);
      return true;
    }
    final delta = replacementRetained - previousRetained;
    if (delta > 0 &&
        delta > turnBudget.normalRetainedByteLimit - turnBudget.retainedBytes) {
      _recordTurnOverflow(
        turnBudget,
        resource: 'turn retained bytes',
        limit: turnBudget.normalRetainedByteLimit,
        observedAtLeast: turnBudget.normalRetainedByteLimit + 1,
      );
      return false;
    }
    if (!_replaceTimelineMessage(
      index,
      ownedReplacement,
      turnId: _activeTurnId!,
    )) {
      _recordTurnOverflow(
        turnBudget,
        resource: 'UI state retained bytes',
        limit: inputBudget.maxUiStateBytes,
        observedAtLeast: inputBudget.maxUiStateBytes + 1,
      );
      return false;
    }
    turnBudget.messageRetainedBytes.remove(previous);
    turnBudget.messageRetainedBytes[ownedReplacement] = replacementRetained;
    turnBudget.retainedBytes += delta;
    _markAgentEventMessageAccepted(ownedReplacement);
    return true;
  }

  bool _replaceTurnCommands(
    List<Map<String, Object?>> commands, {
    bool markAccepted = true,
  }) {
    final copied = _copyAvailableCommands(commands, inputBudget);
    final nextRetained = copied.isEmpty
        ? 0
        : acp.ChatRetainedSizeEstimator(budget: inputBudget).estimate(copied);
    final turnBudget = _ensureTurnBudget();
    final previousCommands = _availableCommands;
    if (!_canAdmitAuxiliaryUiState(
      apply: () => _availableCommands = copied,
      rollback: () => _availableCommands = previousCommands,
    )) {
      _recordTurnOverflow(
        turnBudget,
        resource: 'UI state retained bytes',
        limit: inputBudget.maxUiStateBytes,
        observedAtLeast: inputBudget.maxUiStateBytes + 1,
      );
      return false;
    }
    return _replaceTurnState(
      turnBudget,
      previousRetained: turnBudget.commandStateRetainedBytes,
      nextRetained: nextRetained,
      commit: () {
        if (!_tryReplaceAvailableCommands(copied)) return false;
        turnBudget.commandStateRetainedBytes = nextRetained;
        return true;
      },
      clear: () {
        _tryReplaceAvailableCommands(const <Map<String, Object?>>[]);
        turnBudget.commandStateRetainedBytes = 0;
      },
      markAccepted: markAccepted,
    );
  }

  bool _replaceTurnSettings(
    ChatSessionSettings settings, {
    bool markAccepted = true,
  }) {
    final copied = _copySessionSettings(settings, inputBudget);
    final hasState =
        copied.modes.currentModeId != null ||
        copied.modes.availableModes.isNotEmpty ||
        copied.configOptions.isNotEmpty ||
        copied.omissions.isNotEmpty ||
        copied.truncated;
    final nextRetained = hasState
        ? _addSessionSettingsRetainedBytes(
            _sessionSettingsStateHostRetainedBytes,
            acp.ChatRetainedSizeEstimator(budget: inputBudget),
            copied,
          )
        : 0;
    final turnBudget = _ensureTurnBudget();
    final previousSettings = _sessionSettings;
    if (!_canAdmitAuxiliaryUiState(
      apply: () => _sessionSettings = copied,
      rollback: () => _sessionSettings = previousSettings,
    )) {
      _recordTurnOverflow(
        turnBudget,
        resource: 'UI state retained bytes',
        limit: inputBudget.maxUiStateBytes,
        observedAtLeast: inputBudget.maxUiStateBytes + 1,
      );
      return false;
    }
    return _replaceTurnState(
      turnBudget,
      previousRetained: turnBudget.settingsStateRetainedBytes,
      nextRetained: nextRetained,
      commit: () {
        if (!_tryReplaceSessionSettings(copied)) return false;
        turnBudget.settingsStateRetainedBytes = nextRetained;
        return true;
      },
      clear: () {
        _tryReplaceSessionSettings(const ChatSessionSettings());
        turnBudget.settingsStateRetainedBytes = 0;
      },
      markAccepted: markAccepted,
    );
  }

  bool _replaceTurnState(
    _TurnBudgetState turnBudget, {
    required int previousRetained,
    required int nextRetained,
    required bool Function() commit,
    required VoidCallback clear,
    bool clearOnFailure = true,
    bool markAccepted = true,
  }) {
    final previousItems = previousRetained == 0 ? 0 : 1;
    final nextItems = nextRetained == 0 ? 0 : 1;
    final retainedWithoutPrevious = turnBudget.retainedBytes - previousRetained;
    final itemsWithoutPrevious = turnBudget.items - previousItems;
    final itemOverflow =
        nextItems > turnBudget.normalItemLimit - itemsWithoutPrevious;
    final retainedOverflow =
        nextRetained >
        turnBudget.normalRetainedByteLimit - retainedWithoutPrevious;
    if (itemOverflow || retainedOverflow) {
      if (clearOnFailure) {
        turnBudget.items = itemsWithoutPrevious;
        turnBudget.retainedBytes = retainedWithoutPrevious;
        clear();
      }
      _recordTurnOverflow(
        turnBudget,
        resource: itemOverflow ? 'turn items' : 'turn retained bytes',
        limit: itemOverflow
            ? turnBudget.normalItemLimit
            : turnBudget.normalRetainedByteLimit,
        observedAtLeast:
            (itemOverflow
                ? turnBudget.normalItemLimit
                : turnBudget.normalRetainedByteLimit) +
            1,
      );
      return false;
    }
    if (!commit()) {
      _recordTurnOverflow(
        turnBudget,
        resource: 'UI state retained bytes',
        limit: inputBudget.maxUiStateBytes,
        observedAtLeast: inputBudget.maxUiStateBytes + 1,
      );
      return false;
    }
    turnBudget.items = itemsWithoutPrevious + nextItems;
    turnBudget.retainedBytes = retainedWithoutPrevious + nextRetained;
    if (markAccepted) _markAgentEventAccepted();
    return true;
  }

  void _clearTurnCommandState() {
    final turnBudget = _ensureTurnBudget();
    final retained = turnBudget.commandStateRetainedBytes;
    if (retained > 0) {
      turnBudget.commandStateRetainedBytes = 0;
      turnBudget.retainedBytes -= retained;
      turnBudget.items -= 1;
    }
    availableCommands = const <Map<String, Object?>>[];
    _resetAgentEventAcceptedProjection();
  }

  void _clearTurnSettingsState() {
    final turnBudget = _ensureTurnBudget();
    final retained = turnBudget.settingsStateRetainedBytes;
    if (retained > 0) {
      turnBudget.settingsStateRetainedBytes = 0;
      turnBudget.retainedBytes -= retained;
      turnBudget.items -= 1;
    }
    sessionSettings = const ChatSessionSettings();
    _resetAgentEventAcceptedProjection();
  }

  void _resetAgentEventAcceptedProjection() {
    if (!_trackingAgentEvent) return;
    _eventPayloadAccepted = false;
    _eventAcceptedText = '';
    _eventHasMessageProjection = false;
    _eventAcceptedMetadata = const <String, Object?>{};
    _eventAcceptedOmissions = const <acp.ChatInputOmission>[];
    _eventAcceptedTextOmission = null;
  }

  ({AcpSessionUsage? usage, String? invalidResource}) _replaceTurnUsage(
    Map<String, Object?> metadata,
  ) {
    final used = _intFromObject(metadata['used']);
    final size = _intFromObject(metadata['size']);
    if (used == null || size == null || used < 0 || size <= 0) {
      return (usage: null, invalidResource: 'usage values');
    }
    final costResult = _usageCostFromObject(metadata['cost']);
    if (!costResult.valid) {
      return (usage: null, invalidResource: 'usage cost');
    }
    final next = AcpSessionUsage(used: used, size: size, cost: costResult.cost);
    final retained = _addSessionUsageRetainedBytes(
      0,
      acp.ChatRetainedSizeEstimator(budget: inputBudget),
      next,
    );
    final turnBudget = _ensureTurnBudget();
    final previousUsage = _sessionUsage;
    if (!_canAdmitAuxiliaryUiState(
      apply: () => _sessionUsage = next,
      rollback: () => _sessionUsage = previousUsage,
    )) {
      _recordTurnOverflow(
        turnBudget,
        resource: 'UI state retained bytes',
        limit: inputBudget.maxUiStateBytes,
        observedAtLeast: inputBudget.maxUiStateBytes + 1,
      );
      return (usage: null, invalidResource: null);
    }
    final accepted = _replaceTurnState(
      turnBudget,
      previousRetained: turnBudget.usageStateRetainedBytes,
      nextRetained: retained,
      commit: () {
        if (!_tryReplaceSessionUsage(next)) return false;
        turnBudget.usageStateRetainedBytes = retained;
        return true;
      },
      clear: () {},
      clearOnFailure: false,
    );
    return (usage: accepted ? next : null, invalidResource: null);
  }

  AgentSession? _replaceTurnSessionInfo(Map<String, Object?> metadata) {
    final session = currentSession;
    if (session == null) return null;
    final sessionId = metadata['sessionId'];
    if (sessionId is String &&
        sessionId.isNotEmpty &&
        sessionId != session.id) {
      return null;
    }
    final rawTitle = metadata['title'];
    final title = rawTitle is String ? normalizeSessionTitle(rawTitle) : null;
    final updatedAtRaw = metadata['updatedAt'];
    final updatedAt = updatedAtRaw is String
        ? DateTime.tryParse(updatedAtRaw)?.toLocal()
        : null;
    final updated = session.copyWith(title: title, updatedAt: updatedAt);
    final estimator = acp.ChatRetainedSizeEstimator(budget: inputBudget);
    var retained = _sessionInfoStateHostRetainedBytes;
    if (updated.title != null) {
      retained = projectionAddEstimatedRetainedBytes(
        retained,
        estimator,
        updated.title,
      );
    }
    if (updated.updatedAt != null) {
      retained = projectionAddEstimatedRetainedBytes(
        retained,
        estimator,
        updated.updatedAt!.toIso8601String(),
      );
    }
    final turnBudget = _ensureTurnBudget();
    final previousSession = _currentSession;
    if (!_canAdmitAuxiliaryUiState(
      apply: () => _currentSession = updated,
      rollback: () => _currentSession = previousSession,
    )) {
      _recordTurnOverflow(
        turnBudget,
        resource: 'UI state retained bytes',
        limit: inputBudget.maxUiStateBytes,
        observedAtLeast: inputBudget.maxUiStateBytes + 1,
      );
      return null;
    }
    final accepted = _replaceTurnState(
      turnBudget,
      previousRetained: turnBudget.sessionInfoStateRetainedBytes,
      nextRetained: retained,
      commit: () {
        if (!_tryReplaceCurrentSession(updated)) return false;
        _upsertSession(updated);
        turnBudget.sessionInfoStateRetainedBytes = retained;
        return true;
      },
      clear: () {},
      clearOnFailure: false,
    );
    return accepted ? updated : null;
  }

  void _recordTurnOverflow(
    _TurnBudgetState turnBudget, {
    required String resource,
    required int limit,
    required int observedAtLeast,
  }) {
    turnBudget.overflowed = true;
    final omission = acp.ChatInputOmission(
      reason: acp.ChatInputOmissionReason.inputLimit,
      resource: resource,
      truncated: false,
      limit: limit,
      observedAtLeast: observedAtLeast,
    );
    if (_trackingAgentEvent && !_suppressAgentEventProjection) {
      _eventRootOmission ??= omission;
    }
    if (turnBudget.overflowMarkerPublished) return;
    ChatMessage? target;
    for (var index = messages.length - 1; index >= 0; index -= 1) {
      final candidate = messages[index];
      if (turnBudget.messageRetainedBytes.containsKey(candidate)) {
        target = candidate;
        break;
      }
    }
    if (target != null &&
        target.omissions.length < inputBudget.maxCollectionItems &&
        !target.omissions.any(
          (existing) =>
              existing.resource == omission.resource &&
              existing.reason == omission.reason,
        )) {
      final previousRetained = turnBudget.messageRetainedBytes[target]!;
      final nextRetained = projectionEstimateChatMessageRetainedBytes(
        metadata: target.metadata,
        omissions: <acp.ChatInputOmission>[...target.omissions, omission],
        acceptedUtf8Bytes: target.acceptedUtf8Bytes,
        inputBudget: inputBudget,
      );
      final delta = nextRetained - previousRetained;
      if (delta >= 0 &&
          delta <= turnBudget.maxRetainedBytes - turnBudget.retainedBytes &&
          _canFitActiveMessageRetainedDelta(
            delta,
            allowCompleteTurnEviction: false,
          ) &&
          target.projectionAddOmissionForOwner(_messageOwnerToken, omission)) {
        turnBudget.retainedBytes += delta;
        _activeTimelineRetainedBytes += delta;
        turnBudget.messageRetainedBytes[target] = nextRetained;
        turnBudget.materializationTargets.add(target);
        turnBudget.overflowMarkerPublished = true;
        _enforceTimelineBudget();
        _refreshActiveUiStateBudget();
        return;
      }
    }
    final marker = ChatMessage(
      role: ChatMessageRole.status,
      text: '',
      omissions: <acp.ChatInputOmission>[omission],
      inputBudget: inputBudget,
    );
    final markerRetained = marker.retainedBytes;
    if (turnBudget.items < turnBudget.maxItems &&
        markerRetained <=
            turnBudget.maxRetainedBytes - turnBudget.retainedBytes) {
      final ownedMarker = _appendTimelineMessage(
        marker,
        allowCompleteTurnEviction: false,
      );
      if (ownedMarker == null) {
        return;
      }
      turnBudget.items += 1;
      turnBudget.retainedBytes += markerRetained;
      turnBudget.messageRetainedBytes[ownedMarker] = markerRetained;
      turnBudget.overflowMarkerPublished = true;
    }
  }

  void _appendTextToMessage(ChatMessage target, String chunk) {
    final turnBudget = _ensureTurnBudget();
    _appendBudgetedChunk(
      turnBudget: turnBudget,
      target: target,
      chunk: chunk,
      thought: false,
    );
  }

  void _appendThoughtToMessage(ChatMessage target, String chunk) {
    final turnBudget = _ensureTurnBudget();
    _appendBudgetedChunk(
      turnBudget: turnBudget,
      target: target,
      chunk: chunk,
      thought: true,
    );
  }

  void _appendBudgetedChunk({
    required _TurnBudgetState turnBudget,
    required ChatMessage target,
    required String chunk,
    required bool thought,
  }) {
    final counter = thought ? turnBudget.thought : turnBudget.text;
    if (thought ? turnBudget.thoughtRootDrained : turnBudget.textRootDrained) {
      return;
    }
    if (thought) {
      turnBudget.thoughtCounterTouched = true;
    } else {
      turnBudget.textCounterTouched = true;
    }
    final pending = thought
        ? turnBudget.thoughtPendingHigh
        : turnBudget.textPendingHigh;
    if (thought) {
      turnBudget.thoughtTarget = target;
    } else {
      turnBudget.textTarget = target;
    }

    final accepted = counter.append(chunk);
    final parts = <ChatTextAppend>[];
    if (pending != null &&
        !identical(pending.target, target) &&
        accepted.safePrefix.isNotEmpty) {
      final pairsWithLow =
          chunk.isNotEmpty && _isChatLowSurrogate(chunk.codeUnitAt(0));
      final resolvedCodeUnits = pairsWithLow ? 2 : 1;
      final resolvedBytes = pairsWithLow ? 4 : 3;
      final resolvedPrefix = pairsWithLow
          ? String.fromCharCodes(<int>[pending.codeUnit, chunk.codeUnitAt(0)])
          : String.fromCharCode(pending.codeUnit);
      parts.add(
        ChatTextAppend(
          target: pending.target,
          text: resolvedPrefix,
          acceptedUtf8Bytes: resolvedBytes,
        ),
      );
      parts.add(
        ChatTextAppend(
          target: target,
          text: accepted.safePrefix.substring(resolvedCodeUnits),
          acceptedUtf8Bytes: accepted.acceptedBytes - resolvedBytes,
        ),
      );
    } else {
      parts.add(
        ChatTextAppend(
          target: target,
          text: accepted.safePrefix,
          acceptedUtf8Bytes: accepted.acceptedBytes,
        ),
      );
    }

    final omissionTarget = accepted.omission == null
        ? null
        : pending != null && accepted.safePrefix.isEmpty
        ? pending.target
        : target;
    if (!_applyTurnTextMutation(
      turnBudget,
      parts: parts,
      omissionTarget: omissionTarget,
      omission: accepted.omission,
    )) {
      if (thought) {
        turnBudget.thoughtRootDrained = true;
        turnBudget.thoughtPendingHigh = null;
      } else {
        turnBudget.textRootDrained = true;
        turnBudget.textPendingHigh = null;
      }
      _recordTurnOverflow(
        turnBudget,
        resource: 'turn retained bytes',
        limit: turnBudget.normalRetainedByteLimit,
        observedAtLeast: turnBudget.normalRetainedByteLimit + 1,
      );
      return;
    }

    final _PendingHighSurrogate? nextPending;
    if (accepted.omission != null) {
      nextPending = null;
      if (thought) {
        turnBudget.thoughtRootDrained = true;
      } else {
        turnBudget.textRootDrained = true;
      }
    } else if (chunk.isEmpty) {
      nextPending = pending;
    } else {
      final lastCodeUnit = chunk.codeUnitAt(chunk.length - 1);
      nextPending = _isChatHighSurrogate(lastCodeUnit)
          ? _PendingHighSurrogate(target: target, codeUnit: lastCodeUnit)
          : null;
    }
    if (thought) {
      turnBudget.thoughtPendingHigh = nextPending;
    } else {
      turnBudget.textPendingHigh = nextPending;
    }
  }

  bool _applyTurnTextMutation(
    _TurnBudgetState turnBudget, {
    required List<ChatTextAppend> parts,
    ChatMessage? omissionTarget,
    acp.ChatInputOmission? omission,
  }) {
    try {
      final mutation = ChatTextMutation.prepare(
        parts: parts,
        previousRetained: turnBudget.messageRetainedBytes,
        inputBudget: inputBudget,
        omissionTarget: omissionTarget,
        omission: omission,
      );
      final totalDelta = mutation.totalDelta;
      final nextRetained = mutation.nextRetained;
      if (totalDelta >
          turnBudget.normalRetainedByteLimit - turnBudget.retainedBytes) {
        return false;
      }
      if (!_canFitActiveMessageRetainedDelta(totalDelta)) {
        _recordTurnOverflow(
          turnBudget,
          resource: 'UI state retained bytes',
          limit: inputBudget.maxUiStateBytes,
          observedAtLeast: inputBudget.maxUiStateBytes + 1,
        );
        return false;
      }
      turnBudget.materializationTargets.addAll(
        mutation.apply(_messageOwnerToken),
      );
      turnBudget.retainedBytes += totalDelta;
      _activeTimelineRetainedBytes += totalDelta;
      for (final entry in nextRetained.entries) {
        turnBudget.messageRetainedBytes[entry.key] = entry.value;
      }
      _enforceTimelineBudget();
      _refreshActiveUiStateBudget();
      if (_trackingAgentEvent) {
        for (final part in parts) {
          _markAgentEventAccepted(text: part.text);
        }
        if (!_suppressAgentEventProjection) {
          _eventAcceptedTextOmission ??= omission;
        }
      }
      return true;
    } on Object {
      return false;
    }
  }

  void _finishTurnBudget() {
    _streamingNotificationPending = false;
    final turnBudget = _turnBudget;
    if (turnBudget == null) {
      _activeTurnId = null;
      return;
    }
    _turnBudget = null;
    final textFinishTarget =
        turnBudget.textPendingHigh?.target ?? turnBudget.textTarget;
    final thoughtFinishTarget =
        turnBudget.thoughtPendingHigh?.target ?? turnBudget.thoughtTarget;
    _appendFinishedText(turnBudget, textFinishTarget, turnBudget.text.finish());
    _appendFinishedText(
      turnBudget,
      thoughtFinishTarget,
      turnBudget.thought.finish(),
    );
    turnBudget.textPendingHigh = null;
    turnBudget.thoughtPendingHigh = null;
    _materializeBudgetTargets(turnBudget);
    _activeTurnId = null;
    _enforceTimelineBudget();
    _refreshActiveUiStateBudget();
  }

  void _appendFinishedText(
    _TurnBudgetState turnBudget,
    ChatMessage? target,
    acp.ChatTextBudgetChunk finished,
  ) {
    if (target == null) return;
    final applied = _applyTurnTextMutation(
      turnBudget,
      parts: <ChatTextAppend>[
        ChatTextAppend(
          target: target,
          text: finished.safePrefix,
          acceptedUtf8Bytes: finished.acceptedBytes,
        ),
      ],
      omissionTarget: finished.omission == null ? null : target,
      omission: finished.omission,
    );
    if (!applied) {
      _recordTurnOverflow(
        turnBudget,
        resource: 'turn retained bytes',
        limit: turnBudget.normalRetainedByteLimit,
        observedAtLeast: turnBudget.normalRetainedByteLimit + 1,
      );
    }
  }

  void _appendText(
    ChatMessageRole role,
    String text, {
    Map<String, Object?> metadata = const <String, Object?>{},
    List<acp.ChatInputOmission> omissions = const <acp.ChatInputOmission>[],
  }) {
    final lastMessage = messages.isNotEmpty ? messages.last : null;
    final ChatMessage target;
    if (metadata.isEmpty && lastMessage != null && lastMessage.role == role) {
      target = lastMessage;
      final turnBudget = _ensureTurnBudget();
      for (final omission in omissions) {
        final applied = _applyTurnTextMutation(
          turnBudget,
          parts: const <ChatTextAppend>[],
          omissionTarget: target,
          omission: omission,
        );
        if (!applied) {
          turnBudget.textRootDrained = true;
          _recordTurnOverflow(
            turnBudget,
            resource: 'turn retained bytes',
            limit: turnBudget.normalRetainedByteLimit,
            observedAtLeast: turnBudget.normalRetainedByteLimit + 1,
          );
          return;
        }
      }
    } else {
      final candidate = ChatMessage.projectionGuarded(
        role: role,
        text: '',
        metadata: metadata,
        omissions: omissions,
        inputBudget: inputBudget,
      );
      final admitted = _addTurnMessage(candidate);
      if (admitted == null) {
        final turnBudget = _ensureTurnBudget();
        turnBudget.textRootDrained = true;
        return;
      }
      target = admitted;
    }
    _appendTextToMessage(target, text);
  }

  void _appendStatus(AgentEvent event) {
    final kind = event.metadata['kind'];
    final behaviorRejected = event.metadata['_behaviorRejected'] == true;
    if (event.metadata['_behaviorRejectedAll'] == true) {
      _replaceTurnCommands(const <Map<String, Object?>>[], markAccepted: false);
      _replaceTurnSettings(const ChatSessionSettings(), markAccepted: false);
      _resetAgentEventAcceptedProjection();
      _appendBehaviorFailureMarker(event.omissions);
      return;
    }
    if (kind == 'mode') {
      if (behaviorRejected) {
        _replaceTurnSettings(const ChatSessionSettings(), markAccepted: false);
        _resetAgentEventAcceptedProjection();
        _appendBehaviorFailureMarker(event.omissions);
        return;
      }
      final mode = event.metadata['mode'];
      if (mode is! String || mode.isEmpty) {
        _replaceTurnSettings(const ChatSessionSettings(), markAccepted: false);
        _resetAgentEventAcceptedProjection();
        _appendBehaviorFailureMarker(<acp.ChatInputOmission>[
          ...event.omissions,
          acp.ChatInputOmission(
            reason: acp.ChatInputOmissionReason.invalidStructure,
            resource: 'session mode',
            truncated: false,
          ),
        ]);
        return;
      }
      final settingsAccepted = _replaceTurnSettings(
        sessionSettings.withCurrentMode(mode),
      );
      if (!settingsAccepted || !_replaceStatusMessage(event)) {
        _clearTurnSettingsState();
        _appendBehaviorFailureMarker(event.omissions);
      }
      return;
    }
    if (kind == 'config_option_update') {
      if (behaviorRejected) {
        _replaceTurnSettings(const ChatSessionSettings(), markAccepted: false);
        _resetAgentEventAcceptedProjection();
        _appendBehaviorFailureMarker(event.omissions);
        return;
      }
      final options = event.metadata['configOptions'];
      if (options is! List<ChatConfigOption>) {
        _replaceTurnSettings(const ChatSessionSettings(), markAccepted: false);
        _resetAgentEventAcceptedProjection();
        _appendBehaviorFailureMarker(<acp.ChatInputOmission>[
          ...event.omissions,
          acp.ChatInputOmission(
            reason: acp.ChatInputOmissionReason.invalidStructure,
            resource: 'config options',
            truncated: false,
          ),
        ]);
        return;
      }
      final settingsAccepted = _replaceTurnSettings(
        sessionSettings.withPreferredConfigOptions(options),
      );
      if (!settingsAccepted || !_replaceStatusMessage(event)) {
        _clearTurnSettingsState();
        _appendBehaviorFailureMarker(event.omissions);
      }
      return;
    }
    if (kind == 'session_info_update') {
      if (behaviorRejected) {
        _appendBehaviorFailureMarker(event.omissions);
        return;
      }
      final updated = _replaceTurnSessionInfo(event.metadata);
      if (updated != null) {
        _markAgentEventProjectionAccepted(
          text: '',
          metadata: <String, Object?>{
            'kind': 'session_info_update',
            'sessionId': updated.id,
            if (updated.title != null) 'title': updated.title,
            if (updated.updatedAt != null)
              'updatedAt': updated.updatedAt!.toIso8601String(),
          },
          omissions: event.omissions,
        );
      }
      return;
    }
    if (kind == 'usage_update') {
      if (behaviorRejected) {
        if (event.metadata['_invalidUsageCost'] == true) {
          _resetAgentEventAcceptedProjection();
          _appendBehaviorFailureMarker(<acp.ChatInputOmission>[
            ...event.omissions,
            acp.ChatInputOmission(
              reason: acp.ChatInputOmissionReason.invalidStructure,
              resource: 'usage cost',
              truncated: false,
            ),
          ]);
        } else {
          _appendBehaviorFailureMarker(event.omissions);
        }
        return;
      }
      final usageResult = _replaceTurnUsage(event.metadata);
      if (usageResult.invalidResource case final invalidResource?) {
        _resetAgentEventAcceptedProjection();
        _appendBehaviorFailureMarker(<acp.ChatInputOmission>[
          ...event.omissions,
          acp.ChatInputOmission(
            reason: acp.ChatInputOmissionReason.invalidStructure,
            resource: invalidResource,
            truncated: false,
          ),
        ]);
        return;
      }
      final usage = usageResult.usage;
      if (usage != null) {
        _markAgentEventProjectionAccepted(
          text: '',
          metadata: <String, Object?>{
            'kind': 'usage_update',
            'used': usage.used,
            'size': usage.size,
            if (usage.cost case final cost?)
              'cost': <String, Object?>{
                'amount': cost.amount,
                'currency': cost.currency,
              },
          },
          omissions: event.omissions,
        );
      }
      return;
    }
    if (kind == 'terminal') {
      _upsertTerminalStatusMessage(event);
      return;
    }
    if (kind == 'plan' || kind == 'commands') {
      if (kind == 'commands') {
        if (behaviorRejected) {
          _replaceTurnCommands(
            const <Map<String, Object?>>[],
            markAccepted: false,
          );
          _resetAgentEventAcceptedProjection();
          _appendBehaviorFailureMarker(event.omissions);
          return;
        }
        final commands = _commandsFromMetadata(event.metadata['commands']);
        if (commands == null) {
          _replaceTurnCommands(
            const <Map<String, Object?>>[],
            markAccepted: false,
          );
          _resetAgentEventAcceptedProjection();
          _appendBehaviorFailureMarker(<acp.ChatInputOmission>[
            ...event.omissions,
            acp.ChatInputOmission(
              reason: acp.ChatInputOmissionReason.invalidStructure,
              resource: 'commands',
              truncated: false,
            ),
          ]);
          return;
        }
        final commandsAccepted = _replaceTurnCommands(commands);
        if (!commandsAccepted || !_replaceStatusMessage(event)) {
          _clearTurnCommandState();
          _appendBehaviorFailureMarker(event.omissions);
        }
        return;
      }
      _replaceStatusMessage(event);
      return;
    }
    final lastMessage = messages.isNotEmpty ? messages.last : null;
    if (kind == 'thought' &&
        lastMessage != null &&
        lastMessage.role == ChatMessageRole.status &&
        lastMessage.metadata['kind'] == 'thought') {
      final turnBudget = _ensureTurnBudget();
      for (final omission in event.omissions) {
        final applied = _applyTurnTextMutation(
          turnBudget,
          parts: const <ChatTextAppend>[],
          omissionTarget: lastMessage,
          omission: omission,
        );
        if (!applied) {
          turnBudget.thoughtRootDrained = true;
          _recordTurnOverflow(
            turnBudget,
            resource: 'turn retained bytes',
            limit: turnBudget.normalRetainedByteLimit,
            observedAtLeast: turnBudget.normalRetainedByteLimit + 1,
          );
          return;
        }
      }
      _appendThoughtToMessage(lastMessage, event.text);
      return;
    }
    if (kind == 'thought') {
      final message = ChatMessage.projectionGuarded(
        role: ChatMessageRole.status,
        text: '',
        metadata: event.metadata,
        omissions: event.omissions,
        inputBudget: inputBudget,
      );
      final admitted = _addTurnMessage(message);
      if (admitted == null) {
        final turnBudget = _ensureTurnBudget();
        turnBudget.thoughtRootDrained = true;
        return;
      }
      _appendThoughtToMessage(admitted, event.text);
      return;
    }
    _addTurnMessage(
      ChatMessage(
        role: ChatMessageRole.status,
        text: event.text,
        metadata: event.metadata,
        omissions: event.omissions,
        inputBudget: inputBudget,
      ),
    );
  }

  void _appendBehaviorFailureMarker(List<acp.ChatInputOmission> omissions) {
    _addTurnMessage(
      ChatMessage(
        role: ChatMessageRole.status,
        text: '',
        omissions: omissions,
        inputBudget: inputBudget,
      ),
    );
  }

  void _upsertTerminalStatusMessage(AgentEvent event) {
    final terminalId = event.metadata['terminalId'];
    if (terminalId is! String || terminalId.trim().isEmpty) {
      _addTurnMessage(
        ChatMessage(
          role: ChatMessageRole.status,
          text: event.text,
          metadata: event.metadata,
          omissions: event.omissions,
          inputBudget: inputBudget,
        ),
      );
      return;
    }

    final index = messages.indexWhere((item) {
      return item.role == ChatMessageRole.status &&
          item.metadata['kind'] == 'terminal' &&
          item.metadata['terminalId'] == terminalId;
    });
    if (index == -1) {
      _addTurnMessage(
        ChatMessage(
          role: ChatMessageRole.status,
          text: event.text,
          metadata: event.metadata,
          omissions: event.omissions,
          inputBudget: inputBudget,
        ),
      );
      return;
    }

    final previous = messages[index];
    final metadata = <String, Object?>{...previous.metadata, ...event.metadata};
    if (event.metadata['status'] == 'released' &&
        (previous.metadata['status'] == 'completed' ||
            previous.metadata['status'] == 'failed')) {
      metadata['status'] = previous.metadata['status'];
    }
    _replaceTurnMessage(
      index,
      ChatMessage(
        role: ChatMessageRole.status,
        text: _terminalStatusText(event.text, previous.text),
        metadata: metadata,
        omissions: [...previous.omissions, ...event.omissions],
        inputBudget: inputBudget,
      ),
    );
  }

  String _terminalStatusText(String incoming, String fallback) {
    final text = incoming.trim();
    if (text.isEmpty ||
        text == 'Terminal output.' ||
        text == 'Terminal exited.' ||
        text == 'Terminal released.') {
      return fallback;
    }
    return text;
  }

  bool _replaceStatusMessage(AgentEvent event) {
    final kind = event.metadata['kind'];
    final message = ChatMessage(
      role: ChatMessageRole.status,
      text: event.text,
      metadata: event.metadata,
      omissions: event.omissions,
      inputBudget: inputBudget,
    );
    final index = messages.indexWhere((item) {
      return item.role == ChatMessageRole.status &&
          item.metadata['kind'] == kind;
    });
    if (index == -1) {
      return _addTurnMessage(message) != null;
    }
    return _replaceTurnMessage(index, message);
  }

  List<Map<String, Object?>>? _commandsFromMetadata(Object? raw) {
    if (raw is! List) return null;
    try {
      final commands = <Map<String, Object?>>[];
      final length = raw.length;
      if (length > inputBudget.maxCollectionItems) {
        return null;
      }
      for (var index = 0; index < length; index += 1) {
        final command = raw[index];
        if (command is! Map<String, Object?>) {
          return null;
        }
        commands.add(command);
      }
      if (raw.length != length) return null;
      return _copyAvailableCommands(commands, inputBudget);
    } on Object {
      return null;
    }
  }

  String _stringFromMap(Map<String, Object?> map, String key) {
    final value = map[key];
    return value is String ? value.trim() : '';
  }

  String _toolCallIdFromMetadata(Map<String, Object?> metadata) =>
      chatToolCallId(metadata);

  ({AcpSessionUsageCost? cost, bool valid}) _usageCostFromObject(Object? raw) {
    if (raw == null) return (cost: null, valid: true);
    if (raw is! Map<String, Object?>) return (cost: null, valid: false);
    final amount = _finiteNumFromObject(raw['amount']);
    final rawCurrency = raw['currency'];
    if (amount == null || rawCurrency is! String) {
      return (cost: null, valid: false);
    }
    final currency = rawCurrency.trim();
    if (currency.isEmpty) return (cost: null, valid: false);
    return (
      cost: AcpSessionUsageCost(amount: amount, currency: currency),
      valid: true,
    );
  }

  int? _intFromObject(Object? raw) {
    if (raw is num) return raw.isFinite ? raw.toInt() : null;
    if (raw is String) return int.tryParse(raw.trim());
    return null;
  }

  num? _finiteNumFromObject(Object? raw) {
    final num? parsed;
    if (raw is num) {
      parsed = raw;
    } else if (raw is String) {
      parsed = num.tryParse(raw.trim());
    } else {
      parsed = null;
    }
    return parsed?.isFinite == true ? parsed : null;
  }

  void _upsertSession(AgentSession session) {
    final index = sessions.indexWhere(
      (item) => _sessionIdsMatch(item.id, session.id),
    );
    if (index != -1) {
      sessions[index] = session;
      return;
    }
    sessions.insert(0, session);
  }

  AgentSession? _sessionWithId(String id) {
    for (final session in sessions) {
      if (_sessionIdsMatch(session.id, id)) return session;
    }
    return null;
  }

  AgentSession? _sessionForTargetedAction(AgentSession target) {
    final active = currentSession;
    if (_sameTargetedSession(active, target)) return active;
    for (final session in sessions) {
      if (_sameTargetedSession(session, target)) return session;
    }
    return null;
  }

  bool _sameTargetedSession(AgentSession? left, AgentSession right) {
    if (left == null || !sameSessionWorkspaceIdentity(left, right)) {
      return false;
    }
    return (left.agentName?.trim() ?? '') == (right.agentName?.trim() ?? '');
  }

  bool _sessionIdsMatch(String? left, String right) {
    if (left == null) return false;
    final normalizedLeft = left.trim();
    return normalizedLeft.isNotEmpty && normalizedLeft == right.trim();
  }

  bool _isLocalUnstartedSessionId(String sessionId) {
    return _localUnstartedSessionIds.any(
      (localId) => _sessionIdsMatch(localId, sessionId),
    );
  }

  void _addLocalUnstartedSessionId(String sessionId) {
    _removeLocalUnstartedSessionId(sessionId);
    final normalizedSessionId = sessionId.trim();
    if (normalizedSessionId.isNotEmpty) {
      _localUnstartedSessionIds.add(normalizedSessionId);
      _setLocalUnstartedSessionFlag(normalizedSessionId, true);
    }
  }

  void _removeLocalUnstartedSessionId(String sessionId) {
    _localUnstartedSessionIds.removeWhere(
      (localId) => _sessionIdsMatch(localId, sessionId),
    );
    _setLocalUnstartedSessionFlag(sessionId, false);
  }

  void _setLocalUnstartedSessionFlag(String sessionId, bool value) {
    final active = currentSession;
    if (active != null &&
        _sessionIdsMatch(active.id, sessionId) &&
        active.localUnstarted != value) {
      currentSession = active.copyWith(localUnstarted: value);
    }
    for (var index = 0; index < sessions.length; index += 1) {
      final session = sessions[index];
      if (_sessionIdsMatch(session.id, sessionId) &&
          session.localUnstarted != value) {
        sessions[index] = session.copyWith(localUnstarted: value);
      }
    }
  }

  AgentSession? _boundSessionWithId(String id) {
    final sessionId = id.trim();
    if (sessionId.isEmpty) return null;

    final activeSession = currentSession;
    if (activeSession != null && activeSession.id.trim() == sessionId) {
      return activeSession;
    }
    for (final snapshot in _sessionViewSnapshots.values) {
      if (snapshot.session.id.trim() == sessionId) return snapshot.session;
    }
    if (!_isLocalUnstartedSessionId(sessionId)) return null;
    for (final session in sessions) {
      if (session.id.trim() == sessionId) return session;
    }
    return null;
  }

  AgentSession _mergeSessionIndexMetadata(
    AgentSession existing,
    AgentSession indexed,
  ) {
    final existingAgentName = existing.agentName?.trim();
    final indexedAgentName = indexed.agentName?.trim();
    final isCurrent = _sessionIdsMatch(currentSession?.id, existing.id);
    final boundSession = _boundSessionWithId(existing.id);
    final titleOverride = indexed.titleOverride?.trim().isNotEmpty == true
        ? indexed.titleOverride
        : existing.titleOverride;
    return AgentSession(
      id: existing.id,
      cwd: existing.cwd.trim().isEmpty ? indexed.cwd : existing.cwd,
      createdAt: existing.createdAt,
      additionalDirectories:
          boundSession?.additionalDirectories ??
          (existing.additionalDirectories.isEmpty
              ? indexed.additionalDirectories
              : existing.additionalDirectories),
      title: existing.title ?? indexed.title,
      titleOverride: titleOverride,
      updatedAt: existing.updatedAt ?? indexed.updatedAt,
      agentName: existingAgentName != null && existingAgentName.isNotEmpty
          ? existing.agentName
          : indexedAgentName != null && indexedAgentName.isNotEmpty
          ? indexed.agentName
          : null,
      sessionTemplateId:
          existing.sessionTemplateId ?? indexed.sessionTemplateId,
      sessionTemplateVersion:
          existing.sessionTemplateVersion ?? indexed.sessionTemplateVersion,
      initialEvents: existing.initialEvents,
      pinned: indexed.pinned,
      archived: isCurrent ? false : indexed.archived,
      unread: isCurrent ? false : indexed.unread,
      localUnstarted: existing.localUnstarted || indexed.localUnstarted,
    );
  }

  void _updateSessionMetadata(
    String sessionId,
    AgentSession Function(AgentSession session) update,
  ) {
    final session = _sessionWithId(sessionId);
    if (session == null) return;
    final updated = update(session);
    if (identical(updated, session) || _sameSessionIndex(updated, session)) {
      return;
    }
    if (_sessionIdsMatch(currentSession?.id, sessionId)) {
      currentSession = updated;
    }
    _upsertSession(updated);
    _notifyListeners();
  }

  bool _sameSessionIndex(AgentSession a, AgentSession b) {
    return a.id == b.id &&
        a.cwd == b.cwd &&
        a.createdAt == b.createdAt &&
        a.updatedAt == b.updatedAt &&
        a.title == b.title &&
        a.titleOverride == b.titleOverride &&
        a.agentName == b.agentName &&
        a.sessionTemplateId == b.sessionTemplateId &&
        a.sessionTemplateVersion == b.sessionTemplateVersion &&
        a.pinned == b.pinned &&
        a.archived == b.archived &&
        a.unread == b.unread &&
        a.localUnstarted == b.localUnstarted &&
        _sameStringList(a.additionalDirectories, b.additionalDirectories);
  }

  bool _sameStringList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var index = 0; index < a.length; index++) {
      if (a[index] != b[index]) return false;
    }
    return true;
  }

  List<ChatConfigOption> _configOptionsWithOverride(
    String configId,
    Object value,
  ) {
    var didUpdate = false;
    final options = sessionSettings.configOptions.map((option) {
      if (option.id != configId) return option;
      didUpdate = true;
      return option.copyWith(currentValue: value);
    }).toList();
    return didUpdate ? options : sessionSettings.configOptions;
  }

  void _appendTurnStatus(AgentEvent event) {
    final stopReason = event.metadata['stopReason'];
    if (stopReason is! String || stopReason.isEmpty) return;
    final canonicalStopReason = switch (stopReason) {
      'endTurn' ||
      'maxTokens' ||
      'maxTurnRequests' ||
      'cancelled' ||
      'refusal' => stopReason,
      _ => 'unknown',
    };
    final display = _boundedLocalDisplayText(
      _stopReasonLabel(canonicalStopReason),
      resource: 'display text',
    );
    _addTurnMessage(
      ChatMessage(
        role: ChatMessageRole.status,
        text: display.text,
        metadata: <String, Object?>{
          'kind': 'turn',
          'stopReason': canonicalStopReason,
        },
        omissions: projectionBoundedChatMessageOmissions(
          event.omissions,
          display.omission,
          inputBudget.maxCollectionItems,
        ),
        inputBudget: inputBudget,
      ),
    );
  }

  String _stopReasonLabel(String stopReason) {
    return switch (stopReason) {
      'endTurn' => 'Turn ended normally.',
      'maxTokens' => 'Turn stopped after reaching the token limit.',
      'maxTurnRequests' => 'Turn stopped after too many model requests.',
      'cancelled' => 'Turn cancelled.',
      'refusal' => 'Agent refused to continue.',
      _ => 'Turn ended for an unrecognized reason.',
    };
  }

  void _finishStreaming({
    bool notify = true,
    bool suppressProjection = false,
    bool dispatchQueuedPrompts = true,
  }) {
    _clearPromptIdleWarning();
    final enhancementTurnId = isStreaming ? _pendingEnhancementTurnId : null;
    final enhancementPrompt = isStreaming ? _pendingEnhancementPrompt : null;
    final enhancementSessionId = isStreaming
        ? _pendingEnhancementSessionId
        : null;
    final previousProjectionSuppression = _suppressAgentEventProjection;
    if (suppressProjection) _suppressAgentEventProjection = true;
    try {
      _finishTurnBudget();
    } finally {
      _suppressAgentEventProjection = previousProjectionSuppression;
    }
    if (!isStreaming) {
      _completeActivePrompt();
      return;
    }
    isStreaming = false;
    _completeActivePrompt();
    _pendingEnhancementTurnId = null;
    _pendingEnhancementPrompt = null;
    _pendingEnhancementSessionId = null;
    _cancelPendingPermissionRequestAfterPromptEnd();
    if (status != ConnectionStatus.error) {
      status = currentSession == null
          ? ConnectionStatus.connected
          : ConnectionStatus.sessionReady;
    }
    final startedAt = _lastPromptStartedAt;
    if (startedAt != null) {
      lastLatency = DateTime.now().difference(startedAt);
    }
    if (enhancementTurnId != null &&
        enhancementPrompt != null &&
        enhancementSessionId != null) {
      _scheduleAssistantTurnSummary(
        sessionId: enhancementSessionId,
        turnId: enhancementTurnId,
        prompt: enhancementPrompt,
      );
    }
    if (notify) _notifyListeners();
    if (dispatchQueuedPrompts) _scheduleQueuedPromptDispatch();
  }

  void _completeActivePrompt() {
    final completion = _activePromptCompletion;
    _activePromptCompletion = null;
    if (completion != null && !completion.isCompleted) {
      completion.complete();
    }
  }

  void _recordPromptActivity() {
    _promptIdleWarningTimer?.cancel();
    _promptIdleWarningTimer = null;
    _promptAppearsStalled = false;
    if (_isDisposed || !isStreaming) return;
    _promptIdleWarningTimer = Timer(promptIdleWarningDelay, () {
      _promptIdleWarningTimer = null;
      if (_isDisposed || !isStreaming) return;
      if (pendingPermissionRequest != null) {
        _recordPromptActivity();
        return;
      }
      _promptAppearsStalled = true;
      _notifyListeners();
    });
  }

  void _clearPromptIdleWarning() {
    _promptIdleWarningTimer?.cancel();
    _promptIdleWarningTimer = null;
    _promptAppearsStalled = false;
  }

  void _scheduleQueuedPromptDispatch() {
    if (_isDisposed ||
        _dispatchingQueuedPrompt ||
        isStreaming ||
        isSessionOperationRunning ||
        status == ConnectionStatus.error ||
        _queuedPrompts.isEmpty) {
      return;
    }
    _dispatchingQueuedPrompt = true;
    scheduleMicrotask(() async {
      if (_isDisposed) return;
      ChatQueuedPrompt? item;
      var shouldContinueDispatch = false;
      try {
        final guideIndex = _queuedPrompts.indexWhere((queued) => queued.guide);
        final index = guideIndex == -1 ? 0 : guideIndex;
        item = _queuedPrompts.removeAt(index);
        _notifyListeners();
        final result = await sendPrompt(
          item.text,
          attachments: item.attachments,
        );
        shouldContinueDispatch =
            result == ChatPromptSubmissionResult.submitted ||
            result == ChatPromptSubmissionResult.empty;
        if (result != ChatPromptSubmissionResult.submitted &&
            result != ChatPromptSubmissionResult.empty) {
          _queuedPrompts.insert(0, item);
          _notifyListeners();
        }
      } on Object {
        if (item != null &&
            !_queuedPrompts.any((queued) => queued.id == item!.id)) {
          _queuedPrompts.insert(0, item);
          _notifyListeners();
        }
      } finally {
        _dispatchingQueuedPrompt = false;
        if (shouldContinueDispatch) _scheduleQueuedPromptDispatch();
      }
    });
  }

  void _scheduleAssistantTurnSummary({
    required String sessionId,
    required int turnId,
    required String prompt,
  }) {
    final enhancer = assistantAgentEnhancer;
    if (enhancer == null ||
        !assistantAgentConfig.isConfigured ||
        !assistantAgentConfig.summarizeTurns) {
      return;
    }
    final completedTurn = _completedTurnTranscript(turnId);
    if (completedTurn.trim().isEmpty) return;
    unawaited(() async {
      final summary = await enhancer.summarizeTurn(
        AssistantTurnSummaryRequest(
          sessionId: sessionId,
          turnId: turnId,
          userPrompt: prompt,
          completedTurn: completedTurn,
        ),
      );
      if (_isDisposed ||
          summary == null ||
          summary.trim().isEmpty ||
          !_sessionIdsMatch(currentSession?.id, sessionId)) {
        return;
      }
      _insertAssistantSummary(
        turnId: turnId,
        summary: summary.trim(),
        collapseProcess: assistantAgentConfig.collapseExecutionProcess,
      );
    }());
  }

  String _completedTurnTranscript(int turnId) {
    final buffer = StringBuffer();
    for (final message in _messages) {
      if (message.turnId != turnId ||
          message.metadata['kind'] == 'assistant_summary') {
        continue;
      }
      final role = switch (message.role) {
        ChatMessageRole.user => 'USER',
        ChatMessageRole.assistant => 'ASSISTANT',
        ChatMessageRole.tool => 'TOOL',
        ChatMessageRole.error => 'ERROR',
        ChatMessageRole.status => 'STATUS',
      };
      final text = message.text.trim();
      if (text.isNotEmpty) {
        buffer
          ..writeln('$role:')
          ..writeln(text);
      }
      final contentBlocks = message.metadata['contentBlocks'];
      if (contentBlocks is List && contentBlocks.isNotEmpty) {
        buffer.writeln('$role ATTACHMENTS: ${contentBlocks.length}');
      }
    }
    return buffer.toString().trim();
  }

  void _insertAssistantSummary({
    required int turnId,
    required String summary,
    required bool collapseProcess,
  }) {
    if (_messages.any(
      (message) =>
          message.metadata['kind'] == 'assistant_summary' &&
          message.metadata['sourceTurnId'] == turnId,
    )) {
      return;
    }
    final message = _prepareOwnedMessage(
      ChatMessage(
        role: ChatMessageRole.status,
        text: summary,
        metadata: <String, Object?>{
          'kind': 'assistant_summary',
          'sourceTurnId': turnId,
          'collapseProcess': collapseProcess,
          'assistantAgent': assistantAgentConfig.agentName,
        },
        inputBudget: inputBudget,
      ),
      turnId: turnId,
    );
    if (!_canFitActiveMessageRetainedDelta(
      message.retainedBytes + projectionRetainedListItemHostBytes,
    )) {
      return;
    }
    var insertionIndex = _messages.length;
    for (var index = _messages.length - 1; index >= 0; index -= 1) {
      if (_messages[index].turnId == turnId) {
        insertionIndex = index + 1;
        break;
      }
    }
    _mutateMessages(() => _messages.insert(insertionIndex, message));
    _notifyListeners();
  }

  void _setError(Object error) {
    _finishTurnBudget();
    lastError = _boundedLocalErrorText(_messageForError(error)).text;
    status = ConnectionStatus.error;
    isStreaming = false;
    _notifyListeners();
  }

  void _setActionError(Object error, {bool preserveConnectionStatus = false}) {
    lastError = _boundedLocalErrorText(_messageForError(error)).text;
    if (!preserveConnectionStatus && status == ConnectionStatus.error) {
      status = currentSession == null
          ? ConnectionStatus.connected
          : ConnectionStatus.sessionReady;
    }
    _notifyListeners();
  }

  String _messageForAgentError(AgentEvent event) {
    final detector = _AuthRequiredDetector();
    if (detector.contains(event.text) || detector.contains(event.metadata)) {
      return _authRequiredMessage();
    }
    return event.text;
  }

  ({String text, acp.ChatInputOmission? omission}) _boundedLocalErrorText(
    String raw,
  ) => _boundedLocalDisplayText(raw, resource: 'error text');

  ({String text, acp.ChatInputOmission? omission}) _boundedLocalDisplayText(
    String raw, {
    required String resource,
  }) {
    final counter = acp.ChatUtf8LineBudgetCounter(
      maxBytes: inputBudget.maxMessageTextBytes,
      maxLines: inputBudget.maxMessageTextLines,
      resource: resource,
    );
    final appended = counter.append(raw);
    final finished = counter.finish();
    return (
      text: '${appended.safePrefix}${finished.safePrefix}',
      omission: appended.omission ?? finished.omission,
    );
  }

  String _messageForError(Object error) {
    final errorText = _guardedErrorString(error);
    if (_AuthRequiredDetector().contains(
      error,
      knownText: errorText,
      textWasAlreadyRendered: true,
    )) {
      return _authRequiredMessage();
    }
    return errorText ?? _genericErrorMessage;
  }

  String _authRequiredMessage() {
    if (authMethods.isNotEmpty) {
      return 'Authentication required. Open the Agents menu and choose Authenticate, then try again.';
    }
    return 'Authentication required, but this agent did not advertise an authentication method.';
  }

  String? _guardedErrorString(Object error) {
    try {
      return error.toString();
    } on Object {
      return null;
    }
  }

  Future<void> _loadSessionSettings(
    String sessionId, {
    bool notify = true,
  }) async {
    if (_isDisposed) return;
    final loadId = ++_sessionSettingsLoadSerial;
    if (notify) {
      _activeSessionSettingsLoadId = loadId;
      sessionSettingsLoading = true;
      _notifyListeners();
    }

    try {
      final settings = await client.sessionSettings(sessionId);
      if (_isCurrentSessionSettingsLoad(loadId, sessionId)) {
        sessionSettings = settings.withConfigOptionsPreference;
      }
    } catch (_) {
      if (_isCurrentSessionSettingsLoad(loadId, sessionId)) {
        sessionSettings = const ChatSessionSettings();
      }
    } finally {
      if (notify && !_isDisposed && _activeSessionSettingsLoadId == loadId) {
        _activeSessionSettingsLoadId = null;
        sessionSettingsLoading = false;
        if (notify) _notifyListeners();
      }
    }
  }

  Future<void> _loadAvailableCommands(
    String sessionId, {
    bool notify = true,
  }) async {
    if (_isDisposed) return;
    final loadId = ++_availableCommandsLoadSerial;
    try {
      final update = await client.sessionAvailableCommands(sessionId);
      if (loadId != _availableCommandsLoadSerial ||
          !_isActiveSession(sessionId)) {
        return;
      }
      availableCommands = update?.commands ?? const <Map<String, Object?>>[];
      if (notify) _notifyListeners();
    } on Object {
      // Command discovery is optional session state. Keep the most recent
      // valid snapshot if the agent cannot provide one.
    }
  }

  void _handleAvailableCommandsUpdate(AcpAvailableCommandsUpdate update) {
    if (!_isActiveSession(update.sessionId)) return;
    _availableCommandsLoadSerial += 1;
    availableCommands = update.commands;
    _notifyListeners();
  }

  bool _isCurrentSessionSettingsLoad(int loadId, String sessionId) {
    return !_isDisposed &&
        _sessionSettingsLoadSerial == loadId &&
        _isActiveSession(sessionId);
  }

  bool _isActiveSession(String sessionId) {
    return !_isDisposed && _sessionIdsMatch(currentSession?.id, sessionId);
  }

  Future<void> shutdown({
    Duration cancellationTimeout = defaultCleanupTimeout,
  }) async {
    if (!_isDisposed) {
      try {
        await stop(cancellationTimeout: cancellationTimeout);
      } on Object {
        // Resource disposal still needs to run when cancellation fails.
      }
      dispose();
    }
    await disposalComplete;
  }

  Future<void> get disposalComplete => _disposalFuture ?? Future<void>.value();

  @override
  // ChangeNotifier forbids super.dispose during notifyListeners; the helper
  // invokes it exactly once after the local notification depth returns to 0.
  // ignore: must_call_super
  void dispose() {
    if (_isDisposed) return;
    final activePromptSessionId = isStreaming ? currentSession?.id : null;
    _sessionOperationGeneration += 1;
    _sessionSettingsLoadSerial += 1;
    _finishTurnBudget();
    _clearPromptIdleWarning();
    for (final snapshot in _archiveLeasesById.values.toList(growable: false)) {
      snapshot.discard();
    }
    _streamingNotificationPending = false;
    _isDisposed = true;
    final promptSubscription = _promptSubscription;
    _promptSubscription = null;
    _disposalFuture = _disposeResources(
      promptSubscription,
      activePromptSessionId,
    );
    unawaited(_disposalFuture);
    _resolvingPermissionRequestIds.clear();
    _reviewingPermissionRequestIds.clear();
    if (_notificationDepth == 0) _disposeChangeNotifier();
  }

  Future<void> _disposeResources(
    StreamSubscription<AgentEvent>? promptSubscription,
    String? activePromptSessionId,
  ) async {
    if (activePromptSessionId != null) {
      await _ignoreCleanup(
        () => client.cancelSession(sessionId: activePromptSessionId),
      );
    }
    await _ignoreCleanup(() => promptSubscription?.cancel());
    await _ignoreCleanup(_permissionSubscription.cancel);
    await _ignoreCleanup(_permissionInvalidationSubscription.cancel);
    await _ignoreCleanup(_availableCommandsSubscription.cancel);
    await _ignoreCleanup(() => _agentLifecycleSubscription?.cancel());
    await _ignoreCleanup(client.dispose);
    await _ignoreCleanup(() => assistantAgentEnhancer?.dispose());
    await _ignoreCleanup(() => permissionReviewer?.dispose());
  }

  Future<void> _ignoreCleanup(Future<void>? Function() action) async {
    try {
      final cleanup = action();
      if (cleanup == null) return;
      await cleanup.timeout(defaultCleanupTimeout);
    } on Object {
      // Cleanup remains best effort while disposalComplete still settles.
    }
  }

  void _notifyListeners() {
    if (_isDisposed) return;
    if (_uiStateTransactionDepth > 0) {
      _uiStateNotificationPending = true;
      return;
    }
    _refreshActiveUiStateBudget();
    _notificationDepth += 1;
    try {
      notifyListeners();
    } finally {
      _notificationDepth -= 1;
      if (_isDisposed && _notificationDepth == 0) {
        _disposeChangeNotifier();
      }
    }
  }

  void _disposeChangeNotifier() {
    if (_changeNotifierDisposed) return;
    _changeNotifierDisposed = true;
    super.dispose();
  }

  void _scheduleStreamingNotification() {
    if (_isDisposed || _streamingNotificationPending) return;
    _streamingNotificationPending = true;
    scheduleMicrotask(() {
      if (!_streamingNotificationPending) return;
      _streamingNotificationPending = false;
      _materializeTurnTargets();
      _notifyListeners();
    });
  }

  void _flushStreamingNotification() {
    if (!_streamingNotificationPending) return;
    _streamingNotificationPending = false;
    _materializeTurnTargets();
    _notifyListeners();
  }

  void _materializeTurnTargets() {
    final turnBudget = _turnBudget;
    if (turnBudget == null) return;
    _materializeBudgetTargets(turnBudget);
  }

  void _materializeBudgetTargets(_TurnBudgetState turnBudget) {
    for (final target in turnBudget.materializationTargets) {
      target.text;
    }
    turnBudget.materializationTargets.clear();
    turnBudget.textTarget?.text;
    if (!identical(turnBudget.thoughtTarget, turnBudget.textTarget)) {
      turnBudget.thoughtTarget?.text;
    }
  }
}

String? _boundedSessionTitle(String? value, int maximumCharacters) {
  final normalized = normalizeSessionTitle(value);
  if (normalized == null) return null;
  final runes = normalized.runes.toList(growable: false);
  if (runes.length <= maximumCharacters) return normalized;
  if (maximumCharacters <= 1) return '…';
  return '${String.fromCharCodes(runes.take(maximumCharacters - 1))}…';
}

bool _isChatHighSurrogate(int codeUnit) =>
    codeUnit >= 0xd800 && codeUnit <= 0xdbff;

bool _isChatLowSurrogate(int codeUnit) =>
    codeUnit >= 0xdc00 && codeUnit <= 0xdfff;
