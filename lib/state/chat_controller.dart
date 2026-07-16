import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:dart_acp/dart_acp.dart' as acp;
import 'package:flutter/foundation.dart';

import '../acp/acp_agent_capabilities.dart';
import '../acp/acp_agent_client.dart';
import '../acp/acp_permission_request.dart';
import '../acp/acp_permission_reviewer.dart';
import '../acp/acp_session_catalog.dart';
import '../acp/acp_session_settings.dart';
import '../acp/acp_session_usage.dart';
import '../acp/agent_event.dart';
import '../acp/agent_session.dart';
import '../acp/prompt_attachment.dart';
import 'connection_state.dart';
import '../tasks/egress_policy.dart';

enum ChatMessageRole { user, assistant, tool, error, status }

enum ChatPermissionEventType { requested, resolved }

enum ChatPromptSubmissionResult {
  submitted,
  empty,
  busy,
  sessionUnavailable,
  failed,
}

typedef ChatAgentEventObserver =
    FutureOr<void> Function(AgentSession? session, AgentEvent event);

typedef ChatPermissionEventObserver =
    FutureOr<void> Function(ChatPermissionEvent event);

const List<String> _toolCallIdMetadataKeys = [
  'toolCallId',
  'tool_call_id',
  'id',
  'callId',
  'call_id',
];
const int _sessionReplayBatchSize = 32;
// Conservative carrier accounting: every typed model includes at least a
// 64-byte model node plus 32 bytes per field and space for fixed labels. Real
// List/Map containers and their references are added separately below.
const int _chatMessageHostRetainedBytes = 512;
const int _sessionSnapshotHostRetainedBytes = 2048;
const int _retainedListHostBytes = 64;
const int _retainedListItemHostBytes = 32;
const int _agentEventHostRetainedBytes = 320;
const int _typedConfigMetadataHostRetainedBytes = 192;
const int _sessionModeHostRetainedBytes = 160;
const int _configOptionHostRetainedBytes = 448;
const int _configChoiceHostRetainedBytes = 224;
const int _inputOmissionHostRetainedBytes = 320;
const int _sessionUsageHostRetainedBytes = 224;
const int _sessionSettingsStateHostRetainedBytes = 512;
const int _sessionInfoStateHostRetainedBytes = 320;
const int _contentBlockMetadataHostRetainedBytes = 256;
const int _contentBlockHostRetainedBytes = 320;
const int _thoughtMetadataHostRetainedBytes = 128;
const int _maxSafeRetainedBytes = 0x1fffffffffffff;
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

final class _GuardedChatMetadata {
  const _GuardedChatMetadata({
    required this.metadata,
    this.omission,
    this.localOmissions = const <acp.AcpInputOmission>[],
  });

  final Map<String, Object?> metadata;
  final acp.AcpInputOmission? omission;
  final List<acp.AcpInputOmission> localOmissions;
}

class ChatMessage {
  factory ChatMessage({
    required ChatMessageRole role,
    required String text,
    DateTime? timestamp,
    Map<String, Object?> metadata = const <String, Object?>{},
    List<acp.AcpInputOmission> omissions = const <acp.AcpInputOmission>[],
    acp.AcpInputBudget inputBudget = const acp.AcpInputBudget(),
  }) {
    inputBudget.validate();
    final guarded = _guardChatMessageMetadata(metadata, inputBudget);
    var boundedOmissions = _boundedChatMessageOmissions(
      omissions,
      guarded.omission,
      inputBudget.maxCollectionItems,
    );
    for (final omission in guarded.localOmissions) {
      boundedOmissions = _boundedChatMessageOmissions(
        boundedOmissions,
        omission,
        inputBudget.maxCollectionItems,
      );
    }
    return ChatMessage._(
      role: role,
      text: text,
      timestamp: timestamp ?? DateTime.now(),
      metadata: guarded.metadata,
      omissions: boundedOmissions,
      maxOmissions: inputBudget.maxCollectionItems,
      inputBudget: inputBudget,
      frozen: false,
    );
  }

  factory ChatMessage._guarded({
    required ChatMessageRole role,
    required String text,
    DateTime? timestamp,
    required Map<String, Object?> metadata,
    required List<acp.AcpInputOmission> omissions,
    required acp.AcpInputBudget inputBudget,
  }) {
    inputBudget.validate();
    return ChatMessage._(
      role: role,
      text: text,
      timestamp: timestamp ?? DateTime.now(),
      metadata: metadata,
      omissions: List<acp.AcpInputOmission>.unmodifiable(omissions),
      maxOmissions: inputBudget.maxCollectionItems,
      inputBudget: inputBudget,
      frozen: false,
    );
  }

  ChatMessage._({
    required this.role,
    required String text,
    required this.timestamp,
    required this.metadata,
    required this._omissions,
    required this._maxOmissions,
    required this._inputBudget,
    required this._frozen,
    this._revision = 0,
    int? acceptedUtf8Bytes,
    this._retainedBytes,
    int? turnId,
  }) : _textBuffer = StringBuffer(text),
       _materializedText = text,
       _acceptedUtf8Bytes = acceptedUtf8Bytes ?? utf8.encode(text).length,
       // The private named constructor keeps a readable `turnId` argument.
       // ignore: prefer_initializing_formals
       _turnId = turnId;

  final ChatMessageRole role;
  StringBuffer _textBuffer;
  String? _materializedText;
  int _revision;
  int _materializationCount = 0;
  int _acceptedUtf8Bytes;
  final bool _frozen;
  final acp.AcpInputBudget _inputBudget;
  int? _retainedBytes;
  int? _turnId;
  Object? _ownerToken;

  int? get turnId => _turnId;

  void _claimOwnership(Object ownerToken, int turnId) {
    if (_frozen || _ownerToken != null || _turnId != null) {
      throw StateError('Chat message is already owned.');
    }
    _ownerToken = ownerToken;
    _turnId = turnId;
  }

  void _requireOwner(Object ownerToken) {
    if (!identical(_ownerToken, ownerToken)) {
      throw StateError('Chat message is not owned by this controller.');
    }
  }

  String get text {
    final cached = _materializedText;
    if (cached != null) return cached;
    final materialized = _textBuffer.toString();
    _materializedText = materialized;
    _materializationCount += 1;
    return materialized;
  }

  set text(String value) {
    _requireActive();
    _setText(value);
  }

  void _setTextForOwner(Object ownerToken, String value) {
    _requireOwner(ownerToken);
    _setText(value);
  }

  void _setText(String value) {
    _textBuffer = StringBuffer(value);
    _materializedText = value;
    _acceptedUtf8Bytes = utf8.encode(value).length;
    _revision += 1;
    _retainedBytes = null;
  }

  int get revision => _revision;

  int get acceptedUtf8Bytes => _acceptedUtf8Bytes;

  int get retainedBytes {
    final cached = _retainedBytes;
    if (cached != null) return cached;
    final retained = _estimateChatMessageRetainedBytes(
      metadata: metadata,
      omissions: _omissions,
      acceptedUtf8Bytes: _acceptedUtf8Bytes,
      inputBudget: _inputBudget,
    );
    _retainedBytes = retained;
    return retained;
  }

  @visibleForTesting
  int get materializationCount => _materializationCount;

  void appendAcceptedText(String value, {required int acceptedUtf8Bytes}) {
    _requireActive();
    _appendAcceptedText(value, acceptedUtf8Bytes: acceptedUtf8Bytes);
  }

  void _appendAcceptedTextForOwner(
    Object ownerToken,
    String value, {
    required int acceptedUtf8Bytes,
  }) {
    _requireOwner(ownerToken);
    _appendAcceptedText(value, acceptedUtf8Bytes: acceptedUtf8Bytes);
  }

  void _appendAcceptedText(String value, {required int acceptedUtf8Bytes}) {
    if (acceptedUtf8Bytes < 0) {
      throw ArgumentError.value(
        acceptedUtf8Bytes,
        'acceptedUtf8Bytes',
        'must not be negative',
      );
    }
    final actualUtf8Bytes = utf8.encode(value).length;
    if (acceptedUtf8Bytes != actualUtf8Bytes) {
      throw ArgumentError.value(
        acceptedUtf8Bytes,
        'acceptedUtf8Bytes',
        'must match the accepted text UTF-8 length',
      );
    }
    if (value.isEmpty) return;
    _textBuffer.write(value);
    _materializedText = null;
    _acceptedUtf8Bytes += acceptedUtf8Bytes;
    _revision += 1;
    _retainedBytes = null;
  }

  final DateTime timestamp;
  final Map<String, Object?> metadata;
  List<acp.AcpInputOmission> _omissions;
  final int _maxOmissions;

  List<acp.AcpInputOmission> get omissions => _omissions;

  bool addOmission(acp.AcpInputOmission omission) {
    _requireActive();
    return _addOmission(omission);
  }

  bool _addOmissionForOwner(Object ownerToken, acp.AcpInputOmission omission) {
    _requireOwner(ownerToken);
    return _addOmission(omission);
  }

  bool _addOmission(acp.AcpInputOmission omission) {
    if (_omissions.length >= _maxOmissions ||
        _omissions.any(
          (existing) =>
              existing.resource == omission.resource &&
              existing.reason == omission.reason,
        )) {
      return false;
    }
    _omissions = List<acp.AcpInputOmission>.unmodifiable([
      ..._omissions,
      omission,
    ]);
    _revision += 1;
    _retainedBytes = null;
    return true;
  }

  ChatMessage freeze() => _copyWithFrozenState(frozen: true);

  ChatMessage thaw() => _copyWithFrozenState(frozen: false);

  ChatMessage _copyForBudget(
    acp.AcpInputBudget inputBudget, {
    required bool frozen,
    bool preserveTurnId = true,
  }) {
    inputBudget.validate();
    final materializedText = text;
    final isThought =
        role == ChatMessageRole.status && metadata['kind'] == 'thought';
    final counter = acp.AcpUtf8LineBudgetCounter(
      maxBytes: isThought
          ? inputBudget.maxThoughtTextBytes
          : inputBudget.maxMessageTextBytes,
      maxLines: inputBudget.maxMessageTextLines,
      resource: isThought ? 'thought text' : 'message text',
    );
    final appended = counter.append(materializedText);
    final finished = counter.finish();
    final copiedText = '${appended.safePrefix}${finished.safePrefix}';
    final copiedAcceptedUtf8Bytes =
        appended.acceptedBytes + finished.acceptedBytes;
    final textOmission = appended.omission ?? finished.omission;
    final guarded = _guardOwnedChatMessageMetadata(metadata, inputBudget);
    var copiedBoundedOmissions = _boundedChatMessageOmissions(
      _omissions,
      textOmission,
      inputBudget.maxCollectionItems,
    );
    copiedBoundedOmissions = _boundedChatMessageOmissions(
      copiedBoundedOmissions,
      guarded.omission,
      inputBudget.maxCollectionItems,
    );
    for (final omission in guarded.localOmissions) {
      copiedBoundedOmissions = _boundedChatMessageOmissions(
        copiedBoundedOmissions,
        omission,
        inputBudget.maxCollectionItems,
      );
    }
    final copiedOmissions = List<acp.AcpInputOmission>.unmodifiable(
      copiedBoundedOmissions.map(_copyInputOmission),
    );
    return ChatMessage._(
      role: role,
      text: copiedText,
      timestamp: timestamp,
      metadata: guarded.metadata,
      omissions: copiedOmissions,
      maxOmissions: inputBudget.maxCollectionItems,
      inputBudget: inputBudget,
      frozen: frozen,
      revision: _revision,
      acceptedUtf8Bytes: copiedAcceptedUtf8Bytes,
      turnId: preserveTurnId ? _turnId : null,
    );
  }

  ChatMessage _copyWithFrozenState({required bool frozen}) {
    final copiedMetadata = _guardOwnedChatMessageMetadata(
      metadata,
      _inputBudget,
    ).metadata;
    final copiedOmissions = List<acp.AcpInputOmission>.unmodifiable(
      _omissions.map(_copyInputOmission),
    );
    return ChatMessage._(
      role: role,
      text: text,
      timestamp: timestamp,
      metadata: copiedMetadata,
      omissions: copiedOmissions,
      maxOmissions: _maxOmissions,
      inputBudget: _inputBudget,
      frozen: frozen,
      revision: _revision,
      acceptedUtf8Bytes: _acceptedUtf8Bytes,
      retainedBytes: retainedBytes,
      turnId: _turnId,
    );
  }

  void _requireActive() {
    if (_frozen) {
      throw StateError('Frozen chat message is immutable.');
    }
    if (_ownerToken != null) {
      throw StateError('Controller-owned chat message is immutable.');
    }
  }
}

acp.AcpInputOmission _copyInputOmission(acp.AcpInputOmission omission) {
  return acp.AcpInputOmission(
    reason: omission.reason,
    resource: omission.resource,
    truncated: omission.truncated,
    limit: omission.limit,
    observedAtLeast: omission.observedAtLeast,
  );
}

int _estimateChatMessageRetainedBytes({
  required Map<String, Object?> metadata,
  required List<acp.AcpInputOmission> omissions,
  required int acceptedUtf8Bytes,
  required acp.AcpInputBudget inputBudget,
}) {
  final estimator = acp.AcpRetainedSizeEstimator(budget: inputBudget);
  var retained = _checkedRetainedAdd(
    _chatMessageHostRetainedBytes,
    acceptedUtf8Bytes,
  );
  retained = _checkedRetainedAdd(
    retained,
    _estimateChatMetadataRetainedBytes(estimator, metadata),
  );
  return _addInputOmissionsRetainedBytes(retained, estimator, omissions);
}

int _estimateChatMetadataRetainedBytes(
  acp.AcpRetainedSizeEstimator estimator,
  Map<String, Object?> metadata,
) {
  final kind = metadata['kind'];
  if (metadata.length == 1 && kind is String && kind == 'thought') {
    return _thoughtMetadataHostRetainedBytes;
  }
  final contentBlocks = metadata['contentBlocks'];
  if (contentBlocks is List) {
    return _estimateContentBlockMetadataRetainedBytes(
      estimator,
      metadata,
      contentBlocks,
    );
  }
  final options = metadata['configOptions'];
  if (kind is! String || kind != 'config_option_update' || options is! List) {
    return estimator.estimate(metadata);
  }
  final typedOptions = options.whereType<AcpConfigOption>().toList(
    growable: false,
  );
  var retained = _typedConfigMetadataHostRetainedBytes;
  return _addConfigOptionsRetainedBytes(retained, estimator, typedOptions);
}

int _estimateContentBlockMetadataRetainedBytes(
  acp.AcpRetainedSizeEstimator estimator,
  Map<String, Object?> metadata,
  List contentBlocks,
) {
  var retained = _addRetainedListHostBytes(
    _contentBlockMetadataHostRetainedBytes,
    contentBlocks.length,
  );
  for (final entry in metadata.entries) {
    if (entry.key == 'contentBlocks' ||
        (entry.key == 'kind' &&
            entry.value is String &&
            entry.value == 'thought')) {
      continue;
    }
    retained = _addDynamicRetainedEntry(
      retained,
      estimator,
      entry.key,
      entry.value,
    );
  }
  for (final rawBlock in contentBlocks) {
    if (rawBlock is! Map<String, Object?>) {
      throw const FormatException('Invalid retained content block.');
    }
    final rawType = rawBlock['type'];
    if (rawType is! String) {
      throw const FormatException('Invalid retained content block type.');
    }
    final type = rawType;
    if (type != 'image' &&
        type != 'audio' &&
        type != 'resource' &&
        type != 'omitted') {
      retained = _addEstimatedRetainedBytes(retained, estimator, rawBlock);
      continue;
    }
    retained = _checkedRetainedAdd(retained, _contentBlockHostRetainedBytes);
    if (type == 'image' || type == 'audio') {
      final mimeType = rawBlock['mimeType'];
      if (mimeType != null) {
        retained = _addEstimatedRetainedBytes(retained, estimator, mimeType);
      }
      final data = rawBlock['data'];
      if (data is String) {
        // ACP Base64 is ASCII, so encoded code units equal retained UTF-8 bytes.
        retained = _checkedRetainedAdd(retained, data.length);
      }
      final uri = rawBlock['uri'];
      if (uri != null) {
        retained = _addEstimatedRetainedBytes(retained, estimator, uri);
      }
      continue;
    }
    if (type == 'resource') {
      final resource = rawBlock['resource'];
      if (resource is! Map<String, Object?>) {
        throw const FormatException('Invalid retained resource block.');
      }
      retained = _checkedRetainedAdd(retained, _contentBlockHostRetainedBytes);
      for (final entry in resource.entries) {
        retained = _checkedRetainedAdd(retained, _retainedListItemHostBytes);
        retained = _addEstimatedRetainedBytes(retained, estimator, entry.key);
        if (entry.key == 'blob' && entry.value is String) {
          retained = _checkedRetainedAdd(
            retained,
            (entry.value! as String).length,
          );
        } else {
          retained = _addEstimatedRetainedBytes(
            retained,
            estimator,
            entry.value,
          );
        }
      }
      continue;
    }
    if (type == 'omitted') {
      final resource = rawBlock['resource'];
      if (resource is String) {
        retained = _checkedRetainedAdd(retained, utf8.encode(resource).length);
      }
      for (final key in const <String>['limit', 'observedAtLeast']) {
        if (rawBlock[key] != null) {
          retained = _addEstimatedRetainedBytes(
            retained,
            estimator,
            rawBlock[key],
          );
        }
      }
      continue;
    }
    for (final entry in rawBlock.entries) {
      if (entry.key == 'type') continue;
      retained = _addEstimatedRetainedBytes(retained, estimator, entry.value);
    }
  }
  return retained;
}

int _addDynamicRetainedEntry(
  int retained,
  acp.AcpRetainedSizeEstimator estimator,
  String key,
  Object? value,
) {
  retained = _checkedRetainedAdd(retained, _retainedListItemHostBytes);
  retained = _addEstimatedRetainedBytes(retained, estimator, key);
  return _addEstimatedRetainedBytes(retained, estimator, value);
}

int _checkedRetainedAdd(int current, int increment) {
  if (current < 0 ||
      increment < 0 ||
      current > _maxSafeRetainedBytes - increment) {
    throw acp.AcpInputLimitExceeded(
      resource: 'chat retained state bytes',
      limit: _maxSafeRetainedBytes,
      observedAtLeast: _maxSafeRetainedBytes + 1,
    );
  }
  return current + increment;
}

int _addEstimatedRetainedBytes(
  int retained,
  acp.AcpRetainedSizeEstimator estimator,
  Object? value,
) {
  return _checkedRetainedAdd(retained, estimator.estimate(value));
}

int _addRetainedListHostBytes(int retained, int length) {
  if (length < 0 ||
      length > _maxSafeRetainedBytes ~/ _retainedListItemHostBytes) {
    throw acp.AcpInputLimitExceeded(
      resource: 'chat retained state bytes',
      limit: _maxSafeRetainedBytes,
      observedAtLeast: _maxSafeRetainedBytes + 1,
    );
  }
  retained = _checkedRetainedAdd(retained, _retainedListHostBytes);
  return _checkedRetainedAdd(retained, length * _retainedListItemHostBytes);
}

int _addInputOmissionsRetainedBytes(
  int retained,
  acp.AcpRetainedSizeEstimator estimator,
  List<acp.AcpInputOmission> omissions,
) {
  retained = _addRetainedListHostBytes(retained, omissions.length);
  for (final omission in omissions) {
    retained = _checkedRetainedAdd(retained, _inputOmissionHostRetainedBytes);
    // Omission resources are typed host labels. Their actual retained UTF-8
    // bytes count, but host-fixed labels must not consume the untrusted
    // maxStructuredStringBytes budget.
    retained = _checkedRetainedAdd(
      retained,
      utf8.encode(omission.resource).length,
    );
    if (omission.reason == acp.AcpInputOmissionReason.inputLimit) {
      retained = _addEstimatedRetainedBytes(
        retained,
        estimator,
        omission.limit,
      );
      retained = _addEstimatedRetainedBytes(
        retained,
        estimator,
        omission.observedAtLeast,
      );
    }
  }
  return retained;
}

int _addConfigOptionsRetainedBytes(
  int retained,
  acp.AcpRetainedSizeEstimator estimator,
  List<AcpConfigOption> options,
) {
  retained = _addRetainedListHostBytes(retained, options.length);
  for (final option in options) {
    retained = _checkedRetainedAdd(retained, _configOptionHostRetainedBytes);
    for (final value in <Object?>[
      option.id,
      option.name,
      option.type,
      option.currentValue,
      if (option.description != null) option.description,
      if (option.category != null) option.category,
      if (option.group != null) option.group,
    ]) {
      retained = _addEstimatedRetainedBytes(retained, estimator, value);
    }
    retained = _addRetainedListHostBytes(retained, option.options.length);
    for (final choice in option.options) {
      retained = _checkedRetainedAdd(retained, _configChoiceHostRetainedBytes);
      retained = _addEstimatedRetainedBytes(retained, estimator, choice.value);
      retained = _addEstimatedRetainedBytes(retained, estimator, choice.name);
      if (choice.description != null) {
        retained = _addEstimatedRetainedBytes(
          retained,
          estimator,
          choice.description,
        );
      }
    }
  }
  return retained;
}

_GuardedChatMetadata _guardChatMessageMetadata(
  Map<String, Object?> metadata,
  acp.AcpInputBudget budget,
) => _guardChatMessageMetadataImpl(metadata, budget);

_GuardedChatMetadata _guardOwnedChatMessageMetadata(
  Map<String, Object?> metadata,
  acp.AcpInputBudget budget,
) => _guardChatMessageMetadataImpl(
  metadata,
  budget,
  preserveOwnedOmittedProjections: true,
);

_GuardedChatMetadata _guardChatMessageMetadataImpl(
  Map<String, Object?> metadata,
  acp.AcpInputBudget budget, {
  bool preserveOwnedOmittedProjections = false,
}) {
  final snapshot = _snapshotChatMessageMetadata(metadata, budget);
  final stableMetadata = snapshot.metadata;
  if (stableMetadata == null) return _invalidChatMessageMetadata();
  if (stableMetadata['contentBlocks'] is List) {
    if (snapshot.limit case final limit?) {
      return _limitedChatMessageMetadata(limit);
    }
    try {
      return _copyContentBlockMetadata(
        stableMetadata,
        budget,
        preserveOwnedOmittedProjections: preserveOwnedOmittedProjections,
      );
    } on acp.AcpInputLimitExceeded catch (error) {
      return _limitedChatMessageMetadata(error);
    } on Object {
      return _invalidChatMessageMetadata();
    }
  }
  final typed = _guardRecognizedTypedConfigUpdateMetadata(
    stableMetadata,
    budget,
  );
  if (typed != null) {
    final topLevelLimit = snapshot.limit;
    if (topLevelLimit == null) return typed;
    return _failedTypedConfigUpdateMetadata(
      acp.AcpInputOmission(
        reason: acp.AcpInputOmissionReason.inputLimit,
        resource: 'chat message metadata',
        truncated: false,
        limit: topLevelLimit.limit,
        observedAtLeast: topLevelLimit.observedAtLeast,
      ),
    );
  }
  if (snapshot.limit case final limit?) {
    return _limitedChatMessageMetadata(limit);
  }
  try {
    final guarded = acp.AcpStructuredUpdateGuard(
      budget: budget,
      resource: 'chat message metadata',
    ).copyMetadata(stableMetadata, field: 'metadata');
    return _GuardedChatMetadata(metadata: guarded);
  } on acp.AcpInputLimitExceeded catch (error) {
    return _limitedChatMessageMetadata(error);
  } on Object {
    return _invalidChatMessageMetadata();
  }
}

_GuardedChatMetadata _copyContentBlockMetadata(
  Map<String, Object?> metadata,
  acp.AcpInputBudget budget, {
  bool preserveOwnedOmittedProjections = false,
}) {
  final rawBlocks = metadata['contentBlocks'];
  if (rawBlocks is! List) {
    throw const FormatException('Invalid content blocks.');
  }
  final guard = acp.AcpStructuredUpdateGuard(
    budget: budget,
    resource: 'chat content blocks',
  );
  guard.consumeContainerNode(field: 'metadata');
  final copiedMetadata = <String, Object?>{};
  for (final entry in metadata.entries) {
    if (entry.key == 'contentBlocks') continue;
    guard.consumeEntry(field: 'metadata entry');
    if (entry.key == 'kind' &&
        entry.value is String &&
        entry.value == 'thought') {
      copiedMetadata['kind'] = 'thought';
      continue;
    }
    guard.copyString(entry.key, field: 'metadata key');
    copiedMetadata[entry.key] = guard.copyJsonValue(
      entry.value,
      field: 'metadata value',
    );
  }
  final blockCount = guard.checkCollection(rawBlocks, field: 'content blocks');
  guard.consumeContainerNode(field: 'content blocks');
  final copiedBlocks = <Map<String, Object?>>[];
  final localOmissions = <acp.AcpInputOmission>[];
  void addLocalOmission(acp.AcpInputOmission omission) {
    if (localOmissions.any(
      (existing) =>
          existing.resource == omission.resource &&
          existing.reason == omission.reason,
    )) {
      return;
    }
    localOmissions.add(omission);
  }

  for (var index = 0; index < blockCount; index += 1) {
    final rawBlock = rawBlocks[index];
    if (rawBlock is! Map<String, Object?>) {
      throw const FormatException('Invalid content block.');
    }
    guard.consumeEntry(field: 'content block');
    final rawType = rawBlock['type'];
    if (rawType is! String) {
      throw const FormatException('Invalid content block type.');
    }
    final type = rawType;
    if (type == 'image' || type == 'audio') {
      final copied = <String, Object?>{'type': type};
      final mimeType = rawBlock['mimeType'];
      if (mimeType != null) {
        copied['mimeType'] = guard.copyString(
          mimeType,
          field: 'media mime type',
        );
      }
      final data = rawBlock['data'];
      if (data != null) {
        if (data is! String) {
          final blockOmission = acp.AcpInputOmission(
            reason: acp.AcpInputOmissionReason.invalidStructure,
            resource: type == 'image' ? 'image_data' : 'audio_data',
            truncated: false,
          );
          addLocalOmission(blockOmission);
          copiedBlocks.add(_mediaOmissionProjection(blockOmission));
          continue;
        }
        try {
          acp.scanAcpBase64(
            data,
            maxDecodedBytes: budget.maxEmbeddedMediaBytes,
            resource: type == 'image' ? 'image_data' : 'audio_data',
          );
          copied['data'] = data;
        } on acp.AcpInputLimitExceeded catch (error) {
          final blockOmission = acp.AcpInputOmission(
            reason: acp.AcpInputOmissionReason.inputLimit,
            resource: type == 'image' ? 'image_data' : 'audio_data',
            truncated: false,
            limit: error.limit,
            observedAtLeast: error.observedAtLeast,
          );
          addLocalOmission(blockOmission);
          copiedBlocks.add(_mediaOmissionProjection(blockOmission));
          continue;
        } on FormatException {
          final blockOmission = acp.AcpInputOmission(
            reason: acp.AcpInputOmissionReason.invalidEncoding,
            resource: type == 'image' ? 'image_data' : 'audio_data',
            truncated: false,
          );
          addLocalOmission(blockOmission);
          copiedBlocks.add(_mediaOmissionProjection(blockOmission));
          continue;
        }
      }
      final uri = rawBlock['uri'];
      if (uri != null) {
        copied['uri'] = guard.copyString(uri, field: 'audio uri');
      }
      copiedBlocks.add(Map<String, Object?>.unmodifiable(copied));
      continue;
    }
    if (type == 'resource') {
      final rawResource = rawBlock['resource'];
      if (rawResource is! Map<String, Object?>) {
        throw const FormatException('Invalid resource content block.');
      }
      final snapshot = _snapshotChatMessageMetadata(rawResource, budget);
      final stableResource = snapshot.metadata;
      if (stableResource == null) {
        throw const FormatException('Invalid resource content block map.');
      }
      if (snapshot.limit case final limit?) throw limit;
      guard.consumeContainerNode(field: 'resource');
      final resource = <String, Object?>{};
      acp.AcpInputOmission? blockOmission;
      for (final entry in stableResource.entries) {
        guard.consumeEntry(field: 'resource field');
        final copiedKey = guard.copyString(entry.key, field: 'resource key');
        if (copiedKey == 'blob' && entry.value != null) {
          final blob = entry.value;
          if (blob is! String) {
            blockOmission = acp.AcpInputOmission(
              reason: acp.AcpInputOmissionReason.invalidStructure,
              resource: 'resource_blob',
              truncated: false,
            );
            break;
          }
          try {
            acp.scanAcpBase64(
              blob,
              maxDecodedBytes: budget.maxEmbeddedMediaBytes,
              resource: 'resource_blob',
            );
            resource[copiedKey] = blob;
          } on acp.AcpInputLimitExceeded catch (error) {
            blockOmission = acp.AcpInputOmission(
              reason: acp.AcpInputOmissionReason.inputLimit,
              resource: 'resource_blob',
              truncated: false,
              limit: error.limit,
              observedAtLeast: error.observedAtLeast,
            );
            break;
          } on FormatException {
            blockOmission = acp.AcpInputOmission(
              reason: acp.AcpInputOmissionReason.invalidEncoding,
              resource: 'resource_blob',
              truncated: false,
            );
            break;
          }
        } else if (entry.value is String) {
          resource[copiedKey] = guard.copyString(
            entry.value,
            field: 'resource string',
          );
        } else {
          resource[copiedKey] = guard.copyScalar(
            entry.value,
            field: 'resource scalar',
          );
        }
      }
      if (blockOmission != null) {
        addLocalOmission(blockOmission);
        copiedBlocks.add(_mediaOmissionProjection(blockOmission));
      } else {
        copiedBlocks.add(
          Map<String, Object?>.unmodifiable(<String, Object?>{
            'type': 'resource',
            'resource': Map<String, Object?>.unmodifiable(resource),
          }),
        );
      }
      continue;
    }
    if (type == 'omitted') {
      copiedBlocks.add(
        preserveOwnedOmittedProjections
            ? _copyOwnedOmittedProjection(rawBlock)
            : _externalOmittedProjection(),
      );
      continue;
    }
    copiedBlocks.add(
      guard.copyJsonValue(rawBlock, field: 'content block')!
          as Map<String, Object?>,
    );
  }
  if (rawBlocks.length != blockCount) {
    throw const FormatException('Invalid content block count.');
  }
  copiedMetadata['contentBlocks'] = List<Map<String, Object?>>.unmodifiable(
    copiedBlocks,
  );
  return _GuardedChatMetadata(
    metadata: Map<String, Object?>.unmodifiable(copiedMetadata),
    localOmissions: List<acp.AcpInputOmission>.unmodifiable(localOmissions),
  );
}

Map<String, Object?> _externalOmittedProjection() {
  return Map<String, Object?>.unmodifiable(<String, Object?>{
    'type': 'omitted',
    'reason': 'invalid_structure',
    'resource': 'external_omitted',
    'truncated': false,
  });
}

Map<String, Object?> _copyOwnedOmittedProjection(
  Map<String, Object?> rawBlock,
) {
  final resource = rawBlock['resource'];
  final reason = rawBlock['reason'];
  final truncated = rawBlock['truncated'];
  final limit = rawBlock['limit'];
  final observedAtLeast = rawBlock['observedAtLeast'];
  final knownResource =
      resource == 'image_data' ||
      resource == 'audio_data' ||
      resource == 'resource_blob' ||
      resource == 'turn_media' ||
      resource == 'external_omitted';
  final knownReason =
      reason == 'input_limit' ||
      reason == 'invalid_encoding' ||
      reason == 'invalid_image' ||
      reason == 'invalid_structure';
  final validCapacity = reason == 'input_limit'
      ? limit is int && observedAtLeast is int
      : limit == null && observedAtLeast == null;
  if (!knownResource || !knownReason || truncated is! bool || !validCapacity) {
    return _externalOmittedProjection();
  }
  return Map<String, Object?>.unmodifiable(<String, Object?>{
    'type': 'omitted',
    'reason': reason,
    'resource': resource,
    'truncated': truncated,
    'limit': ?limit,
    'observedAtLeast': ?observedAtLeast,
  });
}

Map<String, Object?> _mediaOmissionProjection(acp.AcpInputOmission omission) {
  return Map<String, Object?>.unmodifiable(<String, Object?>{
    'type': 'omitted',
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
  });
}

int _validatedAcpBase64DecodedBytes(String encoded) {
  if (encoded.isEmpty) return 0;
  var padding = 0;
  if (encoded.codeUnitAt(encoded.length - 1) == 0x3d) padding += 1;
  if (encoded.length > 1 && encoded.codeUnitAt(encoded.length - 2) == 0x3d) {
    padding += 1;
  }
  return encoded.length ~/ 4 * 3 - padding;
}

({Map<String, Object?>? metadata, acp.AcpInputLimitExceeded? limit})
_snapshotChatMessageMetadata(
  Map<String, Object?> raw,
  acp.AcpInputBudget budget,
) {
  final int reportedLength;
  try {
    reportedLength = raw.length;
  } on Object {
    return (metadata: null, limit: null);
  }
  if (reportedLength < 0) return (metadata: null, limit: null);
  final entryLimit = budget.maxCollectionItems < budget.maxMetadataEntries
      ? budget.maxCollectionItems
      : budget.maxMetadataEntries;
  final hasLimit = reportedLength > entryLimit;
  final snapshotLength = hasLimit ? entryLimit + 1 : reportedLength;
  final Iterator<MapEntry<String, Object?>> iterator;
  try {
    iterator = raw.entries.iterator;
  } on Object {
    return (metadata: null, limit: null);
  }
  final snapshot = <String, Object?>{};
  for (var index = 0; index < snapshotLength; index += 1) {
    final bool hasNext;
    try {
      hasNext = iterator.moveNext();
    } on Object {
      return (metadata: null, limit: null);
    }
    if (!hasNext) return (metadata: null, limit: null);
    final MapEntry<String, Object?> entry;
    try {
      entry = iterator.current;
    } on Object {
      return (metadata: null, limit: null);
    }
    if (snapshot.containsKey(entry.key)) {
      return (metadata: null, limit: null);
    }
    snapshot[entry.key] = entry.value;
  }
  if (!hasLimit) {
    final bool hasUnexpectedEntry;
    try {
      hasUnexpectedEntry = iterator.moveNext();
    } on Object {
      return (metadata: null, limit: null);
    }
    if (hasUnexpectedEntry) return (metadata: null, limit: null);
  }
  return (
    metadata: Map<String, Object?>.unmodifiable(snapshot),
    limit: hasLimit
        ? acp.AcpInputLimitExceeded(
            resource: 'chat message metadata entries',
            limit: entryLimit,
            observedAtLeast: reportedLength,
          )
        : null,
  );
}

_GuardedChatMetadata _limitedChatMessageMetadata(
  acp.AcpInputLimitExceeded error,
) => _GuardedChatMetadata(
  metadata: const <String, Object?>{},
  omission: acp.AcpInputOmission(
    reason: acp.AcpInputOmissionReason.inputLimit,
    resource: 'chat message metadata',
    truncated: false,
    limit: error.limit,
    observedAtLeast: error.observedAtLeast,
  ),
);

_GuardedChatMetadata _invalidChatMessageMetadata() => _GuardedChatMetadata(
  metadata: const <String, Object?>{},
  omission: acp.AcpInputOmission(
    reason: acp.AcpInputOmissionReason.invalidStructure,
    resource: 'chat message metadata',
    truncated: false,
  ),
);

_GuardedChatMetadata? _guardRecognizedTypedConfigUpdateMetadata(
  Map<String, Object?> metadata,
  acp.AcpInputBudget budget,
) {
  if (!_isRecognizedTypedConfigUpdateMetadata(metadata)) return null;
  try {
    final copied = _copyTypedConfigUpdateMetadata(metadata, budget);
    if (copied == null) return null;
    return _GuardedChatMetadata(metadata: copied);
  } on acp.AcpInputLimitExceeded catch (error) {
    return _failedTypedConfigUpdateMetadata(
      acp.AcpInputOmission(
        reason: acp.AcpInputOmissionReason.inputLimit,
        resource: 'chat message metadata',
        truncated: false,
        limit: error.limit,
        observedAtLeast: error.observedAtLeast,
      ),
    );
  } on Object {
    return _failedTypedConfigUpdateMetadata(
      acp.AcpInputOmission(
        reason: acp.AcpInputOmissionReason.invalidStructure,
        resource: 'chat message metadata',
        truncated: false,
      ),
    );
  }
}

bool _isRecognizedTypedConfigUpdateMetadata(Map<String, Object?> metadata) {
  try {
    if (metadata.length != 2) return false;
    Object? kind;
    Object? options;
    var count = 0;
    for (final entry in metadata.entries) {
      count += 1;
      if (count > 2) return false;
      if (entry.key == 'kind') {
        kind = entry.value;
      } else if (entry.key == 'configOptions') {
        options = entry.value;
      } else {
        return false;
      }
    }
    return count == 2 &&
        kind is String &&
        kind == 'config_option_update' &&
        options is List;
  } on Object {
    return false;
  }
}

_GuardedChatMetadata _failedTypedConfigUpdateMetadata(
  acp.AcpInputOmission omission,
) => _GuardedChatMetadata(
  metadata: const <String, Object?>{
    'kind': 'config_option_update',
    'configOptions': <AcpConfigOption>[],
  },
  omission: omission,
);

Map<String, Object?>? _copyTypedConfigUpdateMetadata(
  Map<String, Object?> metadata,
  acp.AcpInputBudget budget, {
  acp.AcpStructuredUpdateGuard? structuredGuard,
}) {
  final entryLimit = budget.maxMetadataEntries;
  final int metadataLength;
  try {
    metadataLength = metadata.length;
  } on Object {
    throw const FormatException(
      'Invalid chat message metadata collection access.',
    );
  }
  if (metadataLength > entryLimit) {
    throw acp.AcpInputLimitExceeded(
      resource: 'chat message metadata entries',
      limit: entryLimit,
      observedAtLeast: metadataLength,
    );
  }
  if (metadataLength != 2) return null;

  Object? rawKind;
  Object? rawOptions;
  var observedEntries = 0;
  try {
    for (final entry in metadata.entries) {
      observedEntries += 1;
      if (observedEntries > metadataLength) {
        throw const FormatException(
          'Invalid chat message metadata entry count.',
        );
      }
      if (entry.key == 'kind') {
        rawKind = entry.value;
      } else if (entry.key == 'configOptions') {
        rawOptions = entry.value;
      } else {
        return null;
      }
    }
  } on acp.AcpInputLimitExceeded {
    rethrow;
  } on Object {
    throw const FormatException(
      'Invalid chat message metadata collection access.',
    );
  }
  if (observedEntries != metadataLength ||
      rawKind is! String ||
      rawKind != 'config_option_update' ||
      rawOptions is! List) {
    return null;
  }

  final guard =
      structuredGuard ??
      acp.AcpStructuredUpdateGuard(
        budget: budget,
        resource: 'chat message metadata',
      );
  guard.consumeContainerNode(field: 'metadata');
  final copiedOptions = _copyConfigOptionsWithGuard(
    rawOptions,
    guard,
    field: 'config options',
  );
  return Map<String, Object?>.unmodifiable(<String, Object?>{
    'kind': 'config_option_update',
    'configOptions': copiedOptions,
  });
}

List<AcpConfigOption> _copyConfigOptionsWithGuard(
  Object? rawOptions,
  acp.AcpStructuredUpdateGuard guard, {
  required String field,
}) {
  if (rawOptions is! List) {
    throw const FormatException('Invalid config options collection.');
  }
  final optionCount = guard.checkCollection(rawOptions, field: field);
  guard.consumeContainerNode(field: field);
  final copiedOptions = <AcpConfigOption>[];
  for (var optionIndex = 0; optionIndex < optionCount; optionIndex += 1) {
    final Object? rawOption;
    try {
      rawOption = rawOptions[optionIndex];
    } on Object {
      throw const FormatException('Invalid chat message config option access.');
    }
    if (rawOption is! AcpConfigOption) {
      throw const FormatException('Invalid chat message config option.');
    }
    guard.consumeEntry(field: 'config option');
    final rawChoices = rawOption.options;
    final choiceCount = guard.checkCollection(
      rawChoices,
      field: 'config option choices',
    );
    guard.consumeContainerNode(field: 'config option choices');
    final copiedChoices = <AcpConfigOptionChoice>[];
    for (var choiceIndex = 0; choiceIndex < choiceCount; choiceIndex += 1) {
      final choice = rawChoices[choiceIndex];
      guard.consumeEntry(field: 'config option choice');
      copiedChoices.add(
        AcpConfigOptionChoice(
          value: guard.copyString(
            choice.value,
            field: 'config option choice value',
          ),
          name: guard.copyString(
            choice.name,
            field: 'config option choice name',
          ),
          description: choice.description == null
              ? null
              : guard.copyString(
                  choice.description,
                  field: 'config option choice description',
                ),
        ),
      );
    }
    if (rawChoices.length != choiceCount) {
      throw const FormatException('Invalid config option choice count.');
    }
    copiedOptions.add(
      AcpConfigOption(
        id: guard.copyString(rawOption.id, field: 'config option id'),
        name: guard.copyString(rawOption.name, field: 'config option name'),
        type: guard.copyString(rawOption.type, field: 'config option type'),
        currentValue: guard.copyString(
          rawOption.currentValue,
          field: 'config option current value',
        ),
        options: List<AcpConfigOptionChoice>.unmodifiable(copiedChoices),
        description: rawOption.description == null
            ? null
            : guard.copyString(
                rawOption.description,
                field: 'config option description',
              ),
        category: rawOption.category == null
            ? null
            : guard.copyString(
                rawOption.category,
                field: 'config option category',
              ),
        group: rawOption.group == null
            ? null
            : guard.copyString(rawOption.group, field: 'config option group'),
      ),
    );
  }
  if (rawOptions.length != optionCount) {
    throw const FormatException('Invalid config option count.');
  }
  return List<AcpConfigOption>.unmodifiable(copiedOptions);
}

Map<String, Object?> _copyChatMessageMetadataWithGuard(
  Map<String, Object?> metadata,
  acp.AcpInputBudget budget,
  acp.AcpStructuredUpdateGuard guard,
) {
  final snapshot = _snapshotChatMessageMetadata(metadata, budget);
  final stableMetadata = snapshot.metadata;
  if (stableMetadata == null) {
    throw const FormatException('Invalid session event metadata.');
  }
  if (snapshot.limit case final limit?) throw limit;
  if (_isRecognizedTypedConfigUpdateMetadata(stableMetadata)) {
    final typed = _copyTypedConfigUpdateMetadata(
      stableMetadata,
      budget,
      structuredGuard: guard,
    );
    if (typed == null) {
      throw const FormatException('Invalid typed session event metadata.');
    }
    return typed;
  }
  return guard.copyMetadata(stableMetadata, field: 'event metadata');
}

List<acp.AcpInputOmission> _boundedChatMessageOmissions(
  List<acp.AcpInputOmission> trusted,
  acp.AcpInputOmission? local,
  int limit,
) {
  final bounded = <acp.AcpInputOmission>[];
  for (final omission in trusted) {
    if (bounded.length >= limit) break;
    final duplicate = bounded.any(
      (existing) =>
          existing.resource == omission.resource &&
          existing.reason == omission.reason,
    );
    if (!duplicate) bounded.add(omission);
  }
  if (local != null && bounded.length < limit) {
    final duplicate = bounded.any(
      (existing) =>
          existing.resource == local.resource &&
          existing.reason == local.reason,
    );
    if (!duplicate) bounded.add(local);
  }
  return List<acp.AcpInputOmission>.unmodifiable(bounded);
}

class ChatPermissionEvent {
  const ChatPermissionEvent.requested(this.request)
    : type = ChatPermissionEventType.requested,
      decision = null,
      decisionSource = null,
      status = AcpPermissionAuditStatus.pending;

  const ChatPermissionEvent.resolved(
    this.request, {
    required this.decision,
    required this.decisionSource,
    required this.status,
  }) : type = ChatPermissionEventType.resolved;

  final ChatPermissionEventType type;
  final AcpPermissionRequest request;
  final AcpPermissionDecision? decision;
  final AcpPermissionDecisionSource? decisionSource;
  final AcpPermissionAuditStatus status;
}

class ArchivedSessionSnapshot {
  ArchivedSessionSnapshot({
    required AgentSession session,
    required bool wasCurrent,
    required List<ChatMessage> messages,
    required List<Map<String, Object?>> availableCommands,
    required Duration? lastLatency,
    required String? lastError,
    required AcpSessionSettings sessionSettings,
    required AcpSessionUsage? sessionUsage,
    required bool sessionSettingsLoading,
    required ConnectionStatus status,
    required int? activeSessionSettingsLoadId,
    acp.AcpInputBudget inputBudget = const acp.AcpInputBudget(),
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
  final AcpSessionSettings sessionSettings;
  final AcpSessionUsage? sessionUsage;
  final bool sessionSettingsLoading;
  final ConnectionStatus status;
  final int? activeSessionSettingsLoadId;
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
    required this.retainedBytes,
  });

  final AgentSession session;
  final bool wasCurrent;
  final List<ChatMessage> messages;
  final List<Map<String, Object?>> availableCommands;
  final Duration? lastLatency;
  final String? lastError;
  final AcpSessionSettings sessionSettings;
  final AcpSessionUsage? sessionUsage;
  final bool sessionSettingsLoading;
  final ConnectionStatus status;
  final int? activeSessionSettingsLoadId;
  final int retainedBytes;
}

_PreparedArchivedSessionSnapshot _prepareArchivedSessionSnapshot({
  required AgentSession session,
  required bool wasCurrent,
  required List<ChatMessage> messages,
  required List<Map<String, Object?>> availableCommands,
  required Duration? lastLatency,
  required String? lastError,
  required AcpSessionSettings sessionSettings,
  required AcpSessionUsage? sessionUsage,
  required bool sessionSettingsLoading,
  required ConnectionStatus status,
  required int? activeSessionSettingsLoadId,
  required acp.AcpInputBudget inputBudget,
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
    required AcpSessionSettings sessionSettings,
    required AcpSessionUsage? sessionUsage,
    required bool sessionSettingsLoading,
    required ConnectionStatus status,
    required int? activeSessionSettingsLoadId,
    required acp.AcpInputBudget inputBudget,
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
    required this.retainedBytes,
  });

  final AgentSession session;
  final List<ChatMessage> messages;
  final List<Map<String, Object?>> availableCommands;
  final Duration? lastLatency;
  final String? lastError;
  final AcpSessionSettings sessionSettings;
  final AcpSessionUsage? sessionUsage;
  final bool sessionSettingsLoading;
  final ConnectionStatus status;
  final int? activeSessionSettingsLoadId;
  final int retainedBytes;
}

List<ChatMessage> _freezeSnapshotMessages(
  List<ChatMessage> source,
  acp.AcpInputBudget inputBudget,
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
        (message) => message._copyForBudget(inputBudget, frozen: true),
      ),
    );
  } on Object {
    return const <ChatMessage>[];
  }
}

AgentSession _copyAgentSession(
  AgentSession session,
  acp.AcpInputBudget inputBudget,
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
      pinned: session.pinned,
      archived: session.archived,
      unread: session.unread,
    );
  }
}

AgentSession _copyAgentSessionStrict(
  AgentSession session,
  acp.AcpInputBudget inputBudget,
) {
  final guard = acp.AcpStructuredUpdateGuard(
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
  final eventsGuard = acp.AcpStructuredUpdateGuard(
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
    initialEvents: events,
    pinned: session.pinned,
    archived: session.archived,
    unread: session.unread,
  );
  _addAgentSessionRetainedBytes(
    0,
    acp.AcpRetainedSizeEstimator(
      budget: _retainedAccountingBudget(inputBudget),
    ),
    copied,
  );
  return copied;
}

List<AgentEvent> _copyInitialEvents(
  List<AgentEvent> source,
  acp.AcpInputBudget inputBudget,
  acp.AcpStructuredUpdateGuard guard,
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
    final metadata = _copyChatMessageMetadataWithGuard(
      eventMetadata,
      inputBudget,
      guard,
    );
    final omissionCount = guard.checkCollection(
      rawOmissions,
      field: 'event omissions',
    );
    guard.consumeContainerNode(field: 'event omissions');
    final omissions = <acp.AcpInputOmission>[];
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
        acp.AcpInputOmission(
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
        omissions: List<acp.AcpInputOmission>.unmodifiable(omissions),
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
  acp.AcpInputBudget inputBudget,
) {
  try {
    final copied = acp.AcpStructuredUpdateGuard(
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

AcpSessionSettings _copySessionSettings(
  AcpSessionSettings settings,
  acp.AcpInputBudget inputBudget,
) {
  try {
    final guard = acp.AcpStructuredUpdateGuard(
      budget: inputBudget,
      resource: 'session settings snapshot',
    );
    guard.consumeContainerNode(field: 'settings');
    final modesInfo = settings.modes;
    final rawModes = modesInfo.availableModes;
    final modeCount = guard.checkCollection(rawModes, field: 'modes');
    guard.consumeContainerNode(field: 'modes');
    final modes = <AcpSessionMode>[];
    for (var index = 0; index < modeCount; index += 1) {
      final mode = rawModes[index];
      guard.consumeEntry(field: 'mode');
      modes.add(
        AcpSessionMode(
          id: guard.copyString(mode.id, field: 'mode id'),
          name: guard.copyString(mode.name, field: 'mode name'),
        ),
      );
    }
    if (rawModes.length != modeCount) {
      throw const FormatException('Invalid session mode count.');
    }

    final copiedOptions = _copyConfigOptionsWithGuard(
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
    final omissions = <acp.AcpInputOmission>[];
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
        acp.AcpInputOmission(
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
    return AcpSessionSettings(
      modes: AcpSessionModeInfo(
        currentModeId: currentModeId == null
            ? null
            : guard.copyString(currentModeId, field: 'current mode id'),
        availableModes: List<AcpSessionMode>.unmodifiable(modes),
      ),
      configOptions: copiedOptions,
      omissions: List<acp.AcpInputOmission>.unmodifiable(omissions),
      truncated: truncated,
    );
  } on Object {
    return const AcpSessionSettings();
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
  var retained = _addRetainedListHostBytes(0, messages.length);
  if (precomputedMessageRetainedBytes case final messageBytes?) {
    return _checkedRetainedAdd(retained, messageBytes);
  }
  for (final message in messages) {
    retained = _checkedRetainedAdd(retained, message.retainedBytes);
  }
  return retained;
}

int _estimateSessionViewRetainedBytes({
  required List<ChatMessage> messages,
  required List<Map<String, Object?>> availableCommands,
  required AcpSessionSettings sessionSettings,
  required AcpSessionUsage? sessionUsage,
  required AgentSession session,
  required Duration? lastLatency,
  required String? lastError,
  required int? activeSessionSettingsLoadId,
  required acp.AcpInputBudget inputBudget,
  int? precomputedTimelineRetainedBytes,
}) {
  final estimator = acp.AcpRetainedSizeEstimator(
    budget: _retainedAccountingBudget(inputBudget),
  );
  var retained = _checkedRetainedAdd(
    _sessionSnapshotHostRetainedBytes,
    precomputedTimelineRetainedBytes ??
        _estimateTimelineRetainedBytes(messages),
  );
  retained = _addAgentSessionRetainedBytes(retained, estimator, session);
  retained = _addEstimatedRetainedBytes(retained, estimator, availableCommands);
  if (lastLatency != null) {
    retained = _addEstimatedRetainedBytes(
      retained,
      estimator,
      lastLatency.inMicroseconds,
    );
  }
  if (lastError != null) {
    retained = _addEstimatedRetainedBytes(retained, estimator, lastError);
  }
  retained = _addSessionSettingsRetainedBytes(
    retained,
    estimator,
    sessionSettings,
  );
  retained = _addSessionUsageRetainedBytes(retained, estimator, sessionUsage);
  if (activeSessionSettingsLoadId != null) {
    retained = _addEstimatedRetainedBytes(
      retained,
      estimator,
      activeSessionSettingsLoadId,
    );
  }
  return retained;
}

acp.AcpInputBudget _retainedAccountingBudget(acp.AcpInputBudget inputBudget) {
  const defaults = acp.AcpInputBudget();
  int atLeastDefault(int value, int fallback) {
    return value < fallback ? fallback : value;
  }

  return acp.AcpInputBudget(
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
  acp.AcpRetainedSizeEstimator estimator,
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
  ]) {
    retained = _addEstimatedRetainedBytes(retained, estimator, value);
  }
  retained = _addRetainedListHostBytes(retained, session.initialEvents.length);
  for (final event in session.initialEvents) {
    retained = _checkedRetainedAdd(retained, _agentEventHostRetainedBytes);
    retained = _addEstimatedRetainedBytes(retained, estimator, event.text);
    if (event.timestamp != null) {
      retained = _addEstimatedRetainedBytes(
        retained,
        estimator,
        event.timestamp!.microsecondsSinceEpoch,
      );
    }
    retained = _checkedRetainedAdd(
      retained,
      _estimateChatMetadataRetainedBytes(estimator, event.metadata),
    );
    retained = _addInputOmissionsRetainedBytes(
      retained,
      estimator,
      event.omissions,
    );
  }
  return retained;
}

int _addSessionSettingsRetainedBytes(
  int retained,
  acp.AcpRetainedSizeEstimator estimator,
  AcpSessionSettings settings,
) {
  if (settings.modes.currentModeId != null) {
    retained = _addEstimatedRetainedBytes(
      retained,
      estimator,
      settings.modes.currentModeId,
    );
  }
  retained = _addRetainedListHostBytes(
    retained,
    settings.modes.availableModes.length,
  );
  for (final mode in settings.modes.availableModes) {
    retained = _checkedRetainedAdd(retained, _sessionModeHostRetainedBytes);
    retained = _addEstimatedRetainedBytes(retained, estimator, mode.id);
    retained = _addEstimatedRetainedBytes(retained, estimator, mode.name);
  }
  retained = _addConfigOptionsRetainedBytes(
    retained,
    estimator,
    settings.configOptions,
  );
  retained = _addInputOmissionsRetainedBytes(
    retained,
    estimator,
    settings.omissions,
  );
  return retained;
}

int _addSessionUsageRetainedBytes(
  int retained,
  acp.AcpRetainedSizeEstimator estimator,
  AcpSessionUsage? usage,
) {
  if (usage == null) return retained;
  retained = _checkedRetainedAdd(retained, _sessionUsageHostRetainedBytes);
  retained = _addEstimatedRetainedBytes(retained, estimator, usage.used);
  retained = _addEstimatedRetainedBytes(retained, estimator, usage.size);
  final cost = usage.cost;
  if (cost == null) return retained;
  retained = _checkedRetainedAdd(retained, _sessionUsageHostRetainedBytes);
  retained = _addEstimatedRetainedBytes(retained, estimator, cost.amount);
  return _addEstimatedRetainedBytes(retained, estimator, cost.currency);
}

class _TurnBudgetState {
  _TurnBudgetState(acp.AcpInputBudget budget)
    : maxItems = budget.maxTurnItems,
      maxRetainedBytes = budget.maxTurnRetainedBytes,
      normalItemLimit = budget.maxTurnItems > 1 ? budget.maxTurnItems - 1 : 0,
      normalRetainedByteLimit = budget.maxTurnRetainedBytes > 1024
          ? budget.maxTurnRetainedBytes - 1024
          : 0,
      text = acp.AcpUtf8LineBudgetCounter(
        maxBytes: budget.maxMessageTextBytes,
        maxLines: budget.maxMessageTextLines,
        resource: 'message text',
      ),
      thought = acp.AcpUtf8LineBudgetCounter(
        maxBytes: budget.maxThoughtTextBytes,
        maxLines: budget.maxMessageTextLines,
        resource: 'thought text',
      );

  final int maxItems;
  final int maxRetainedBytes;
  final int normalItemLimit;
  final int normalRetainedByteLimit;
  final acp.AcpUtf8LineBudgetCounter text;
  final acp.AcpUtf8LineBudgetCounter thought;
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

class _TurnTextAppend {
  const _TurnTextAppend({
    required this.target,
    required this.text,
    required this.acceptedUtf8Bytes,
  });

  final ChatMessage target;
  final String text;
  final int acceptedUtf8Bytes;
}

class _TurnMessageProjection {
  _TurnMessageProjection({
    required this.message,
    required this.previousRetained,
  }) : acceptedUtf8Bytes = message.acceptedUtf8Bytes,
       omissions = <acp.AcpInputOmission>[...message.omissions];

  final ChatMessage message;
  final int previousRetained;
  int acceptedUtf8Bytes;
  final List<acp.AcpInputOmission> omissions;
}

class ChatController extends ChangeNotifier {
  ChatController({
    required this.client,
    required this.cwd,
    this.additionalDirectories = const <String>[],
    this.agentName = 'Codex',
    this.permissionHistoryLimit = defaultPermissionHistoryLimit,
    this.permissionReviewResultEncodedByteLimit =
        defaultPermissionReviewResultEncodedByteLimit,
    this.permissionHistoryEncodedByteLimit =
        defaultPermissionHistoryEncodedByteLimit,
    this.inputBudget = const acp.AcpInputBudget(),
    List<AcpPermissionTrustRule> permissionTrustRules =
        const <AcpPermissionTrustRule>[],
    this.permissionReviewer,
  }) : permissionTrustRules = List.unmodifiable(permissionTrustRules) {
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
  }

  static const int defaultPermissionHistoryLimit = 500;
  static const Duration defaultCleanupTimeout = Duration(seconds: 2);

  final AcpAgentClient client;
  final String cwd;
  final List<String> additionalDirectories;
  final String agentName;
  final int permissionHistoryLimit;
  final int permissionReviewResultEncodedByteLimit;
  final int permissionHistoryEncodedByteLimit;
  final acp.AcpInputBudget inputBudget;
  final List<AcpPermissionTrustRule> permissionTrustRules;
  final AcpPermissionReviewer? permissionReviewer;

  ConnectionStatus status = ConnectionStatus.disconnected;
  AgentSession? _currentSession;
  AgentSession? get currentSession => _currentSession;
  set currentSession(AgentSession? value) {
    _currentSession = value;
    _requestActiveUiStateRefresh();
  }

  final List<AgentSession> sessions = <AgentSession>[];
  final Object _messageOwnerToken = Object();
  final List<ChatMessage> _messages = <ChatMessage>[];
  late final UnmodifiableListView<ChatMessage> _messagesView =
      UnmodifiableListView<ChatMessage>(_messages);
  UnmodifiableListView<ChatMessage> get messages => _messagesView;
  int messagesRevision = 0;
  int _nextTurnId = 0;
  int? _activeTurnId;
  int _activeTimelineRetainedBytes = _retainedListHostBytes;
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
  AcpSessionSettings _sessionSettings = const AcpSessionSettings();
  AcpSessionSettings get sessionSettings => _sessionSettings;
  set sessionSettings(AcpSessionSettings value) {
    _tryReplaceSessionSettings(value);
  }

  AcpSessionUsage? _sessionUsage;
  AcpSessionUsage? get sessionUsage => _sessionUsage;
  set sessionUsage(AcpSessionUsage? value) {
    _tryReplaceSessionUsage(value);
  }

  AcpPermissionRequest? pendingPermissionRequest;
  AcpToolCallExecutionPolicy toolCallExecutionPolicy =
      AcpToolCallExecutionPolicy.defaultPermissions;
  final List<AcpPermissionAuditEntry> _permissionHistory =
      <AcpPermissionAuditEntry>[];
  final List<int> _permissionHistoryEntryEncodedBytes = <int>[];
  int _permissionHistoryEncodedBytes = 0;
  final Set<String> _resolvingPermissionRequestIds = <String>{};
  final Set<String> _reviewingPermissionRequestIds = <String>{};
  final Set<String> _retiredSessionIds = <String>{};
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
  bool sessionSettingsLoading = false;
  bool isSessionOperationRunning = false;
  bool isSessionReplayLoading = false;
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
  List<acp.AcpInputOmission> _eventAcceptedOmissions =
      const <acp.AcpInputOmission>[];
  acp.AcpInputOmission? _eventAcceptedTextOmission;
  acp.AcpInputOmission? _eventRootOmission;

  bool get supportsSessionClose => capabilities?.session.close == true;

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
  int get debugUiStateRetainedBytes => _checkedRetainedAdd(
    _checkedRetainedAdd(
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
    return currentSession != null &&
        supportsSessionClose &&
        !isStreaming &&
        !isSessionOperationRunning;
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

  bool get canLogout {
    return supportsAuthLogout && !isStreaming && !isSessionOperationRunning;
  }

  bool get canSendExtensionRequest {
    return capabilities != null && !isStreaming && !isSessionOperationRunning;
  }

  List<AcpPermissionAuditEntry> get permissionHistory {
    return List.unmodifiable(_permissionHistory);
  }

  int get permissionHistoryEncodedBytes => _permissionHistoryEncodedBytes;

  StreamSubscription<AgentEvent>? _promptSubscription;
  late final StreamSubscription<AcpPermissionRequest> _permissionSubscription;
  late final StreamSubscription<AcpPermissionInvalidation>
  _permissionInvalidationSubscription;
  DateTime? _lastPromptStartedAt;
  Duration? _lastLatency;
  Duration? get lastLatency => _lastLatency;
  set lastLatency(Duration? value) {
    _lastLatency = value;
    _requestActiveUiStateRefresh();
  }

  int _sessionSettingsLoadSerial = 0;
  int _sessionOperationGeneration = 0;
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

  Future<bool> newSession({String? cwd}) async {
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
          await _connectWithStatus(ConnectionStatus.connecting);
          if (!_isCurrentSessionOperationGeneration(operationGeneration)) {
            return;
          }
          if (status == ConnectionStatus.error) return;
        }
        final remoteSession = await client.createSession(
          cwd: workspaceCwd,
          additionalDirectories: additionalDirectories,
        );
        if (!_isCurrentSessionOperationGeneration(operationGeneration)) return;
        final createdSession = _copyAgentSessionStrict(
          remoteSession.copyWith(agentName: agentName),
          inputBudget,
        );
        final initialEvents = createdSession.initialEvents;
        final session = createdSession.copyWith(
          initialEvents: const <AgentEvent>[],
        );
        await _runUiStateTransaction(() {
          _snapshotCurrentSession();
          _retiredSessionIds.remove(session.id);
          currentSession = session;
          _upsertSession(session);
          _clearMessages();
          availableCommands = const <Map<String, Object?>>[];
          lastLatency = null;
          lastError = null;
          sessionSettings = const AcpSessionSettings();
          sessionUsage = null;
          sessionSettingsLoading = false;
          _activeSessionSettingsLoadId = null;
          for (final event in initialEvents) {
            _handleAgentEvent(event, notify: false);
          }
          _finishTurnBudget();
        });
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
        _notifyListeners();
      } catch (error) {
        if (!_isCurrentSessionOperationGeneration(operationGeneration)) return;
        _setError(error);
      }
    });
    return created;
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
          _clearMessages();
          availableCommands = const <Map<String, Object?>>[];
          lastLatency = null;
          sessionSettings = const AcpSessionSettings();
          sessionUsage = null;
          sessionSettingsLoading = false;
          _activeSessionSettingsLoadId = null;
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

        final replay = await client.resumeSession(
          sessionId: trimmedSessionId,
          cwd: workspaceCwd,
          additionalDirectories: workspaceAdditionalDirectories,
        );
        if (!_isCurrentSessionOperationGeneration(operationGeneration)) return;
        _removeLocalUnstartedSessionId(trimmedSessionId);
        await _replaySessionEvents(replay);
        if (!_isCurrentSessionOperationGeneration(operationGeneration)) return;
        await _loadSessionSettings(trimmedSessionId, notify: false);
        if (!_isCurrentSessionOperationGeneration(operationGeneration)) return;
        isSessionReplayLoading = false;
        if (status != ConnectionStatus.error) {
          status = ConnectionStatus.sessionReady;
        }
        _notifyListeners();
      } catch (error) {
        if (!_isCurrentSessionOperationGeneration(operationGeneration)) return;
        await _runUiStateTransaction(() {
          _sessionViewSnapshots
            ..clear()
            ..addAll(previousSessionViewSnapshots);
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
        });
        _setError(error);
      }
    });
  }

  Future<void> _replaySessionEvents(List<AgentEvent> replay) async {
    _finishTurnBudget();
    var pendingText = StringBuffer();
    Map<String, Object?> pendingTextMetadata = const <String, Object?>{};

    void flushPendingText() {
      if (pendingText.isEmpty) return;
      _handleAgentEvent(
        AgentEvent(
          type: AgentEventType.agentTextDelta,
          text: pendingText.toString(),
          metadata: pendingTextMetadata,
        ),
        notify: false,
      );
      pendingText = StringBuffer();
      pendingTextMetadata = const <String, Object?>{};
    }

    for (var index = 0; index < replay.length; index += 1) {
      final event = replay[index];
      if (event.type == AgentEventType.agentTextDelta &&
          event.metadata.isEmpty &&
          event.omissions.isEmpty) {
        pendingText.write(event.text);
      } else {
        flushPendingText();
        _handleAgentEvent(event, notify: false);
      }
      final shouldYield =
          (index + 1) % _sessionReplayBatchSize == 0 &&
          index + 1 < replay.length;
      if (shouldYield) {
        await Future<void>.delayed(Duration.zero);
      }
    }
    flushPendingText();
    _finishTurnBudget();
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

  Future<List<AcpProjectSessions>> loadSessionCatalog() async {
    final projects = await listSessions();
    _mergeSessionCatalog(projects);
    return projects;
  }

  void mergeSessionIndex(Iterable<AgentSession> indexedSessions) {
    var didChange = false;
    for (final session in indexedSessions) {
      if (session.id.trim().isEmpty || session.cwd.trim().isEmpty) continue;
      if (_retiredSessionIds.contains(session.id)) continue;

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
    final trimmedTitle = title.trim();
    if (trimmedTitle.isEmpty) return;
    _updateSessionMetadata(sessionId, (session) {
      if (session.titleOverride == trimmedTitle) return session;
      return session.copyWith(titleOverride: trimmedTitle);
    });
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
          : inactiveSnapshot?.sessionSettings ?? const AcpSessionSettings(),
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
        _clearMessages();
        availableCommands = const <Map<String, Object?>>[];
        lastLatency = null;
        lastError = null;
        sessionSettings = const AcpSessionSettings();
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
      inputBudget: inputBudget,
    );
    _runSynchronousUiStateTransaction(() {
      if (hasIssuedLease && !_consumeArchiveLease(snapshot, leaseId!)) return;
      _upsertSession(prepared.session);
      if (wasCurrent && currentSession == null) {
        currentSession = prepared.session;
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
    _archivedLeaseRetainedBytes = _checkedRetainedAdd(
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

  void _storeSessionViewSnapshot(
    String sessionId,
    _SessionViewSnapshot snapshot,
  ) {
    final normalizedSessionId = sessionId.trim();
    final previousKey = _sessionViewSnapshotKeyWithId(normalizedSessionId);
    final previous = previousKey == null
        ? null
        : _sessionViewSnapshots.remove(previousKey);
    if (previous != null) {
      _inactiveSnapshotRetainedBytes -= previous.retainedBytes;
    }
    _sessionViewSnapshots[normalizedSessionId] = snapshot;
    _inactiveSnapshotRetainedBytes = _checkedRetainedAdd(
      _inactiveSnapshotRetainedBytes,
      snapshot.retainedBytes,
    );
    if (_uiStateTransactionDepth > 0) {
      _uiStateRefreshPending = true;
    } else {
      _enforceUiStateBudget();
    }
  }

  _SessionViewSnapshot? _takeSessionViewSnapshot(String sessionId) {
    final key = _sessionViewSnapshotKeyWithId(sessionId);
    final snapshot = key == null ? null : _sessionViewSnapshots.remove(key);
    if (snapshot != null) {
      _inactiveSnapshotRetainedBytes -= snapshot.retainedBytes;
    }
    return snapshot;
  }

  void _removeSessionViewSnapshot(String sessionId) {
    _takeSessionViewSnapshot(sessionId);
  }

  _SessionViewSnapshot? _touchSessionViewSnapshot(String sessionId) {
    final snapshot = _takeSessionViewSnapshot(sessionId);
    if (snapshot == null) return null;
    _sessionViewSnapshots[sessionId.trim()] = snapshot;
    _inactiveSnapshotRetainedBytes = _checkedRetainedAdd(
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

  bool _tryReplaceSessionSettings(AcpSessionSettings settings) {
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
        _takeSessionViewSnapshot(_sessionViewSnapshots.keys.first);
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
        _recomputeActiveUiStateRetainedBytes();
      }
      if (removedHistory && !_messages.any(_isHistoryMarker)) {
        final marker = _prepareOwnedMessage(
          ChatMessage(
            role: ChatMessageRole.status,
            text: '',
            omissions: <acp.AcpInputOmission>[
              acp.AcpInputOmission(
                reason: acp.AcpInputOmissionReason.inputLimit,
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
    _clearMessages();
    availableCommands = const <Map<String, Object?>>[];
    lastLatency = null;
    lastError = null;
    sessionSettings = const AcpSessionSettings();
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
      final created = await newSession();
      if (!created || status == ConnectionStatus.error) {
        return ChatPromptSubmissionResult.sessionUnavailable;
      }
    }

    final session = currentSession;
    if (session == null) return ChatPromptSubmissionResult.sessionUnavailable;
    _removeLocalUnstartedSessionId(session.id);
    _finishTurnBudget();
    _startLocalTurn();
    _turnBudget = _TurnBudgetState(inputBudget);

    final contentBlocks = attachments
        .map((attachment) => attachment.toResourceLink())
        .toList();
    _addTurnMessage(
      ChatMessage(
        role: ChatMessageRole.user,
        text: prompt,
        inputBudget: inputBudget,
        metadata: contentBlocks.isEmpty
            ? const <String, Object?>{}
            : <String, Object?>{'contentBlocks': contentBlocks},
      ),
    );
    isStreaming = true;
    status = ConnectionStatus.streaming;
    lastError = null;
    _lastPromptStartedAt = DateTime.now();
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
            _handleAgentEvent,
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
    try {
      final permissionError = await _cancelPendingPermissionRequest(
        reportErrors: false,
      ).timeout(cancellationTimeout);
      cancelError = permissionError;
    } on Object catch (error) {
      cancelError = error;
    }
    try {
      await client.cancel().timeout(cancellationTimeout);
    } on Object catch (error) {
      cancelError ??= error;
    } finally {
      try {
        final promptSubscription = _promptSubscription;
        if (promptSubscription != null) {
          await promptSubscription.cancel().timeout(cancellationTimeout);
        }
      } on Object catch (error) {
        cancelError ??= error;
      }
      _promptSubscription = null;
      _finishStreaming();
    }
    if (cancelError != null) {
      _setActionError(cancelError);
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
      currentSession = null;
      sessions.clear();
      _localUnstartedSessionIds.clear();
      _clearSessionViewSnapshots();
      _clearMessages();
      availableCommands = const <Map<String, Object?>>[];
      sessionSettings = const AcpSessionSettings();
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
        !sessionSettings.shouldUseLegacyModes ||
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

  void setToolCallExecutionPolicy(AcpToolCallExecutionPolicy policy) {
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
        final remoteFork = await client.forkSession(
          sessionId: session.id,
          cwd: session.cwd,
          additionalDirectories: session.additionalDirectories,
        );
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
            initialEvents: const <AgentEvent>[],
          ),
          inputBudget,
        );
        _retiredSessionIds.remove(updatedSession.id);
        currentSession = updatedSession;
        _upsertSession(updatedSession);
        _clearMessages();
        availableCommands = const <Map<String, Object?>>[];
        lastLatency = null;
        lastError = null;
        sessionSettings = const AcpSessionSettings();
        sessionUsage = null;
        sessionSettingsLoading = false;
        _activeSessionSettingsLoadId = null;
        for (final event in initialEvents) {
          _handleAgentEvent(event, notify: false);
        }
        _finishTurnBudget();
        await _loadSessionSettings(updatedSession.id, notify: false);
        if (!_isCurrentSessionOperationGeneration(operationGeneration)) return;
        if (status != ConnectionStatus.error) {
          status = ConnectionStatus.sessionReady;
        }
        _notifyListeners();
      } catch (error) {
        if (!_isCurrentSessionOperationGeneration(operationGeneration)) return;
        _setActionError(error);
      }
    });
  }

  Future<void> closeCurrentSession() async {
    final session = currentSession;
    if (session == null || !supportsSessionClose) return;
    if (isStreaming || isSessionOperationRunning) return;
    _finishTurnBudget();

    final operationGeneration = _beginSessionOperationGeneration();
    await _runSessionOperation(() async {
      try {
        await _promptSubscription?.cancel();
        if (!_isCurrentSessionOperationGeneration(operationGeneration)) return;
        _promptSubscription = null;
      } catch (error) {
        if (!_isCurrentSessionOperationGeneration(operationGeneration)) return;
        _setActionError(error);
        return;
      }

      Object? closeError;
      try {
        await client.closeSession(sessionId: session.id);
      } catch (error) {
        closeError = error;
      }
      if (!_isCurrentSessionOperationGeneration(operationGeneration)) return;

      _retiredSessionIds.add(session.id);
      _removeLocalUnstartedSessionId(session.id);
      _removeSessionViewSnapshot(session.id);
      currentSession = null;
      sessions.removeWhere((item) => _sessionIdsMatch(item.id, session.id));
      _clearMessages();
      availableCommands = const <Map<String, Object?>>[];
      lastLatency = null;
      lastError = null;
      sessionSettings = const AcpSessionSettings();
      sessionUsage = null;
      sessionSettingsLoading = false;
      _activeSessionSettingsLoadId = null;
      await _cancelPendingPermissionRequest(reportErrors: false);
      if (!_isCurrentSessionOperationGeneration(operationGeneration)) return;
      status = ConnectionStatus.connected;
      if (closeError != null) {
        _setActionError(closeError);
      } else {
        _notifyListeners();
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
        if (currentSession case final session?) {
          _retiredSessionIds.add(session.id);
        }
        _retiredSessionIds.addAll(sessions.map((session) => session.id));
        _localUnstartedSessionIds.clear();
        _clearSessionViewSnapshots();
        currentSession = null;
        sessions.clear();
        _clearMessages();
        availableCommands = const <Map<String, Object?>>[];
        lastLatency = null;
        lastError = null;
        sessionSettings = const AcpSessionSettings();
        sessionUsage = null;
        sessionSettingsLoading = false;
        await _cancelPendingPermissionRequest(reportErrors: false);
        status = ConnectionStatus.connected;
        _notifyListeners();
      } catch (error) {
        _setActionError(error);
      }
    });
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

  Future<Map<String, Object?>> sendExtensionRequest({
    required String method,
    required Map<String, Object?> params,
  }) async {
    if (lastError != null) {
      lastError = null;
      _notifyListeners();
    }
    try {
      final trimmedMethod = method.trim();
      if (trimmedMethod.isEmpty) {
        throw StateError('Extension method is required.');
      }
      if (!trimmedMethod.startsWith('_')) {
        throw StateError('Extension method must start with underscore (_).');
      }
      if (!canSendExtensionRequest) {
        throw StateError('Connect to an ACP agent before sending extensions.');
      }
      final result = await client.sendExtensionRequest(
        method: trimmedMethod,
        params: params,
      );
      lastError = null;
      _notifyListeners();
      return result;
    } catch (error) {
      _setActionError(error, preserveConnectionStatus: true);
      rethrow;
    }
  }

  Future<void> resolvePermissionRequest(AcpPermissionDecision decision) async {
    final request = pendingPermissionRequest;
    if (request == null) return;
    await _resolvePermissionRequest(
      request,
      decision,
      source: AcpPermissionDecisionSource.manual,
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
      source: AcpPermissionDecisionSource.manual,
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
    isSessionOperationRunning = true;
    _notifyListeners();
    try {
      await action();
    } finally {
      if (!_isDisposed) {
        isSessionOperationRunning = false;
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
    isSessionOperationRunning = true;
    _notifyListeners();
    try {
      return await action();
    } finally {
      if (!_isDisposed) {
        isSessionOperationRunning = false;
        _notifyListeners();
      }
    }
  }

  AgentEvent _safeAgentEvent(AgentEvent event) {
    final snapshot = _snapshotChatMessageMetadata(event.metadata, inputBudget);
    final stableMetadata = snapshot.metadata;
    final guarded = stableMetadata == null
        ? _invalidChatMessageMetadata()
        : _guardChatMessageMetadata(stableMetadata, inputBudget);
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
    var guardedOmissions = _boundedChatMessageOmissions(
      event.omissions,
      _dedupeTurnMediaOmission(guarded.omission),
      inputBudget.maxCollectionItems,
    );
    for (final omission in guarded.localOmissions) {
      guardedOmissions = _boundedChatMessageOmissions(
        guardedOmissions,
        _dedupeTurnMediaOmission(omission),
        inputBudget.maxCollectionItems,
      );
    }
    guardedOmissions = _boundedChatMessageOmissions(
      guardedOmissions,
      displayText.omission,
      inputBudget.maxCollectionItems,
    );
    return AgentEvent(
      type: event.type,
      text: behaviorRejected || behaviorRejectedAll ? '' : displayText.text,
      timestamp: event.timestamp,
      metadata: safeMetadata,
      omissions: _boundedChatMessageOmissions(
        guardedOmissions,
        media.omission,
        inputBudget.maxCollectionItems,
      ),
    );
  }

  acp.AcpInputOmission? _dedupeTurnMediaOmission(
    acp.AcpInputOmission? omission,
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

  ({Map<String, Object?> metadata, acp.AcpInputOmission? omission})
  _sanitizeEventMedia(Map<String, Object?> metadata) {
    final rawBlocks = metadata['contentBlocks'];
    if (rawBlocks is! List) return (metadata: metadata, omission: null);
    final turnBudget = _ensureTurnBudget();
    final blocks = <Object?>[];
    acp.AcpInputOmission? omission;
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
        final drainedOmission = acp.AcpInputOmission(
          reason: acp.AcpInputOmissionReason.inputLimit,
          resource: 'turn_media',
          truncated: false,
          limit: inputBudget.maxEmbeddedMediaBytes,
          observedAtLeast: inputBudget.maxEmbeddedMediaBytes + 1,
        );
        blocks.add(_mediaOmissionProjection(drainedOmission));
        omission ??= acp.AcpInputOmission(
          reason: acp.AcpInputOmissionReason.inputLimit,
          resource: 'turn_media',
          truncated: false,
          limit: inputBudget.maxEmbeddedMediaBytes,
          observedAtLeast: inputBudget.maxEmbeddedMediaBytes + 1,
        );
        continue;
      }
      if (encoded is! String) {
        changed = true;
        final invalid = acp.AcpInputOmission(
          reason: acp.AcpInputOmissionReason.invalidStructure,
          resource: resource,
          truncated: false,
        );
        blocks.add(_mediaOmissionProjection(invalid));
        omission ??= invalid;
        continue;
      }
      // The content-block guard immediately before this phase already scanned
      // and detached this Base64 string. Count the validated encoding in O(1)
      // here so aggregate admission does not scan the same payload again.
      final decodedBytes = _validatedAcpBase64DecodedBytes(encoded);
      if (decodedBytes >
          inputBudget.maxEmbeddedMediaBytes - turnBudget.mediaBytes) {
        turnBudget.mediaRootDrained = true;
        changed = true;
        final aggregate = acp.AcpInputOmission(
          reason: acp.AcpInputOmissionReason.inputLimit,
          resource: 'turn_media',
          truncated: false,
          limit: inputBudget.maxEmbeddedMediaBytes,
          observedAtLeast: inputBudget.maxEmbeddedMediaBytes + 1,
        );
        blocks.add(_mediaOmissionProjection(aggregate));
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
            omissions: _boundedChatMessageOmissions(
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
    _eventAcceptedOmissions = const <acp.AcpInputOmission>[];
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
      omissions: _boundedChatMessageOmissions(
        _boundedChatMessageOmissions(
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
    List<acp.AcpInputOmission> omissions = const <acp.AcpInputOmission>[],
  }) {
    if (!_trackingAgentEvent || _suppressAgentEventProjection) return;
    _eventPayloadAccepted = true;
    _eventHasMessageProjection = true;
    _eventAcceptedText = text;
    _eventAcceptedMetadata = Map<String, Object?>.unmodifiable(metadata);
    _eventAcceptedOmissions = List<acp.AcpInputOmission>.unmodifiable(
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

    for (var index = messages.length - 1; index >= 0; index -= 1) {
      final message = messages[index];
      if (message.role == ChatMessageRole.user) break;
      if (message.role != ChatMessageRole.tool) continue;
      if (_toolCallIdFromMetadata(message.metadata) != toolCallId) {
        continue;
      }

      _replaceTurnMessage(
        index,
        ChatMessage(
          role: ChatMessageRole.tool,
          text: event.text.trim().isEmpty ? message.text : event.text,
          timestamp: message.timestamp,
          metadata: _mergeMetadata(message.metadata, event.metadata),
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

  Map<String, Object?> _mergeMetadata(
    Map<String, Object?> existing,
    Map<String, Object?> update,
  ) {
    final merged = Map<String, Object?>.from(existing);
    for (final entry in update.entries) {
      if (entry.value == null) continue;
      merged[entry.key] = entry.value;
    }
    return Map.unmodifiable(merged);
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

  void _handlePermissionRequest(AcpPermissionRequest incomingRequest) {
    final request = incomingRequest.withGeneration(
      ++_nextPermissionRequestGeneration,
    );

    if (!_isPermissionRequestForActiveSession(request)) {
      _recordPermissionRequest(request);
      _recordPermissionDecision(
        request,
        AcpPermissionDecision.cancel,
        source: AcpPermissionDecisionSource.system,
      );
      unawaited(
        _sendPermissionDecision(
          id: request.id,
          decision: AcpPermissionDecision.cancel,
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
        AcpPermissionDecision.cancel,
        source: AcpPermissionDecisionSource.system,
      );
      if (previous.id != request.id) {
        unawaited(
          _sendPermissionDecision(
            id: previous.id,
            decision: AcpPermissionDecision.cancel,
            reportErrors: false,
          ),
        );
      }
    }
    pendingPermissionRequest = request;
    _recordPermissionRequest(request);
    _notifyPermissionEventObservers(
      ChatPermissionEvent.requested(_permissionRequestForAudit(request)),
    );
    _resolvePendingPermissionForPolicy(request);
    _notifyListeners();
  }

  bool _isCurrentPermissionRequest(AcpPermissionRequest request) {
    return pendingPermissionRequest?.bindingKey == request.bindingKey;
  }

  bool _isPermissionRequestForActiveSession(AcpPermissionRequest request) {
    final requestSessionId = request.sessionId.trim();
    if (requestSessionId.isEmpty) return false;
    if (_retiredSessionIds.contains(requestSessionId)) return false;
    final session = currentSession;
    if (session == null) return true;
    return requestSessionId == session.id;
  }

  void _handlePermissionRequestsDone() {
    if (_isDisposed) return;
    final request = pendingPermissionRequest;
    if (request == null) return;
    pendingPermissionRequest = null;
    _recordPermissionDecision(
      request,
      AcpPermissionDecision.cancel,
      source: AcpPermissionDecisionSource.system,
    );
    _notifyListeners();
  }

  void _handlePermissionInvalidation(AcpPermissionInvalidation event) {
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
    _resolvingPermissionRequestIds.remove(bindingKey);
    _reviewingPermissionRequestIds.remove(bindingKey);
    _recordPermissionDecision(
      request,
      AcpPermissionDecision.cancel,
      source: AcpPermissionDecisionSource.system,
    );
    _notifyListeners();
  }

  AcpPermissionDecision? _trustedDecisionFor(AcpPermissionRequest request) {
    for (final rule in permissionTrustRules) {
      if (rule.matches(request)) return rule.decision;
    }
    return null;
  }

  void _resolvePendingPermissionForPolicy(AcpPermissionRequest request) {
    if (_holdEgressSensitivePermissionForManualReview(request)) return;

    switch (toolCallExecutionPolicy) {
      case AcpToolCallExecutionPolicy.defaultPermissions:
        return;
      case AcpToolCallExecutionPolicy.autoReview:
        final trustedDecision = _trustedDecisionFor(request);
        if (trustedDecision != null) {
          unawaited(
            _resolvePermissionRequest(
              request,
              trustedDecision,
              source: AcpPermissionDecisionSource.trustRule,
            ),
          );
          return;
        }
        _startPermissionReview(request);
        return;
      case AcpToolCallExecutionPolicy.fullAccess:
        unawaited(
          _resolvePermissionRequest(
            request,
            AcpPermissionDecision.allow,
            source: AcpPermissionDecisionSource.policy,
          ),
        );
        return;
    }
  }

  bool _holdEgressSensitivePermissionForManualReview(
    AcpPermissionRequest request,
  ) {
    final match = egressPolicyMatchForPermission(request);
    if (match == null) return false;

    _recordPermissionReview(
      request,
      AcpPermissionReviewResult(
        risk: 'egress',
        rationale: 'Export-sensitive command requires manual approval.',
        reviewer: 'egress-policy',
        details: <String, Object?>{
          'egressSensitive': true,
          'egressReason': match.reason,
          'commandLine': match.commandLine,
        },
      ),
    );
    return true;
  }

  Future<void> _resolvePermissionRequest(
    AcpPermissionRequest request,
    AcpPermissionDecision decision, {
    required AcpPermissionDecisionSource source,
    AcpPermissionReviewResult? reviewResult,
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
      if (decision != AcpPermissionDecision.cancel &&
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
    }
  }

  void _startPermissionReview(AcpPermissionRequest request) {
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
        final reviewAdditionalDirectories =
            reviewSession?.additionalDirectories.isNotEmpty == true
            ? reviewSession!.additionalDirectories
            : additionalDirectories;
        final result = await reviewer.review(
          request,
          workspaceRoot: reviewWorkspaceRoot,
          additionalDirectories: reviewAdditionalDirectories,
          model: currentModelValue,
        );
        if (_isDisposed) return;
        if (result == null) return;
        final boundedResult = sanitizeAcpPermissionReviewResult(
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
        if (decision == AcpPermissionDecision.allow &&
            (!reviewer.canAutoApprove ||
                boundedResult.risk.trim().toLowerCase() != 'low')) {
          _notifyListeners();
          return;
        }
        if (!_isCurrentPermissionRequest(request)) return;
        await _resolvePermissionRequest(
          request,
          decision,
          source: AcpPermissionDecisionSource.reviewAgent,
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
    required AcpPermissionDecision decision,
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
      AcpPermissionDecision.cancel,
      source: AcpPermissionDecisionSource.system,
    );
    try {
      await client.respondToPermissionRequest(
        id: request.id,
        decision: AcpPermissionDecision.cancel,
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
      AcpPermissionDecision.cancel,
      source: AcpPermissionDecisionSource.system,
    );
    unawaited(
      _sendPermissionDecision(
        id: request.id,
        decision: AcpPermissionDecision.cancel,
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
      AcpPermissionDecision.cancel,
      source: AcpPermissionDecisionSource.system,
    );
    unawaited(
      _sendPermissionDecision(
        id: request.id,
        decision: AcpPermissionDecision.cancel,
        reportErrors: false,
      ),
    );
  }

  void _recordPermissionRequest(AcpPermissionRequest request) {
    final entry = AcpPermissionAuditEntry(
      request: _permissionRequestForAudit(request),
      status: AcpPermissionAuditStatus.pending,
      recordedAt: request.requestedAt,
    );
    _permissionHistory.insert(0, entry);
    final encodedBytes = acpPermissionAuditEntryEncodedBytes(entry);
    _permissionHistoryEntryEncodedBytes.insert(0, encodedBytes);
    _permissionHistoryEncodedBytes += encodedBytes;
    _trimPermissionHistory();
  }

  AcpPermissionRequest _permissionRequestForAudit(
    AcpPermissionRequest request,
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
      _permissionHistory.removeLast();
      _permissionHistoryEncodedBytes -= _permissionHistoryEntryEncodedBytes
          .removeLast();
    }
  }

  void _replacePermissionHistoryEntry(
    int index,
    AcpPermissionAuditEntry replacement,
  ) {
    final replacementBytes = acpPermissionAuditEntryEncodedBytes(replacement);
    final previousBytes = _permissionHistoryEntryEncodedBytes[index];
    _permissionHistory[index] = replacement;
    _permissionHistoryEntryEncodedBytes[index] = replacementBytes;
    _permissionHistoryEncodedBytes += replacementBytes - previousBytes;
    _trimPermissionHistory();
  }

  void _recordPermissionDecision(
    AcpPermissionRequest request,
    AcpPermissionDecision decision, {
    AcpPermissionDecisionSource source = AcpPermissionDecisionSource.manual,
    AcpPermissionReviewResult? reviewResult,
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
        : sanitizeAcpPermissionReviewResult(
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
    AcpPermissionRequest request,
    AcpPermissionReviewResult reviewResult,
  ) {
    final index = _permissionHistory.indexWhere(
      (entry) => entry.request.bindingKey == request.bindingKey,
    );
    if (index == -1) return;
    final boundedReviewResult = sanitizeAcpPermissionReviewResult(
      reviewResult,
      inputBudget: inputBudget,
      maxEncodedBytes: permissionReviewResultEncodedByteLimit,
    );
    _replacePermissionHistoryEntry(
      index,
      _permissionHistory[index].copyWith(reviewResult: boundedReviewResult),
    );
  }

  AcpPermissionAuditStatus _permissionAuditStatus(
    AcpPermissionDecision decision,
  ) {
    return switch (decision) {
      AcpPermissionDecision.allow => AcpPermissionAuditStatus.allowed,
      AcpPermissionDecision.deny => AcpPermissionAuditStatus.denied,
      AcpPermissionDecision.cancel => AcpPermissionAuditStatus.cancelled,
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
    _messages[index]._setTextForOwner(_messageOwnerToken, text);
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
  void addOmissionForTesting(acp.AcpInputOmission omission) {
    if (_messages.isEmpty) {
      throw StateError('A message is required before adding an omission.');
    }
    final target = _messages.last;
    final applied = _applyTurnTextMutation(
      _ensureTurnBudget(),
      parts: const <_TurnTextAppend>[],
      omissionTarget: target,
      omission: omission,
    );
    if (!applied) throw StateError('The omission did not fit the turn budget.');
  }

  ChatMessage _prepareOwnedMessage(ChatMessage message, {required int turnId}) {
    if (message._ownerToken != null || message.turnId != null) {
      throw StateError('Cannot admit an already-owned chat message.');
    }
    final owned = message._copyForBudget(
      inputBudget,
      frozen: false,
      preserveTurnId: false,
    );
    owned._claimOwnership(_messageOwnerToken, turnId);
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
    message._requireOwner(_messageOwnerToken);
    if (!_canFitActiveMessageRetainedDelta(
      message.retainedBytes + _retainedListItemHostBytes,
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
    var projected = _checkedRetainedAdd(
      _checkedRetainedAdd(
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
      projected -= message.retainedBytes + _retainedListItemHostBytes;
      if (projected <= inputBudget.maxUiStateBytes) return true;
    }
    final historyMarker = _messages.where(_isHistoryMarker).firstOrNull;
    if (historyMarker != null) {
      projected -= historyMarker.retainedBytes + _retainedListItemHostBytes;
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
      projected -= message.retainedBytes + _retainedListItemHostBytes;
      if (projected <= inputBudget.maxUiStateBytes) return true;
    }
    final historyMarker = _messages.where(_isHistoryMarker).firstOrNull;
    if (historyMarker != null) {
      projected -= historyMarker.retainedBytes + _retainedListItemHostBytes;
    }
    return projected <= inputBudget.maxUiStateBytes;
  }

  bool _replaceTimelineMessage(
    int index,
    ChatMessage replacement, {
    required int turnId,
  }) {
    replacement._requireOwner(_messageOwnerToken);
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
      final owned = message._copyForBudget(
        inputBudget,
        frozen: false,
        preserveTurnId: false,
      );
      owned._claimOwnership(_messageOwnerToken, turnId);
      copied.add(owned);
    }
    _mutateMessages(() {
      _messages
        ..clear()
        ..addAll(copied);
    });
  }

  void _clearMessages() {
    if (_messages.isEmpty) return;
    _mutateMessages(_messages.clear);
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
      }
      if (removedHistory && !_messages.any(_isHistoryMarker)) {
        final marker = _prepareOwnedMessage(
          ChatMessage(
            role: ChatMessageRole.status,
            text: '',
            omissions: <acp.AcpInputOmission>[
              acp.AcpInputOmission(
                reason: acp.AcpInputOmissionReason.inputLimit,
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
        : acp.AcpRetainedSizeEstimator(budget: inputBudget).estimate(copied);
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
    AcpSessionSettings settings, {
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
            acp.AcpRetainedSizeEstimator(budget: inputBudget),
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
        _tryReplaceSessionSettings(const AcpSessionSettings());
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
    sessionSettings = const AcpSessionSettings();
    _resetAgentEventAcceptedProjection();
  }

  void _resetAgentEventAcceptedProjection() {
    if (!_trackingAgentEvent) return;
    _eventPayloadAccepted = false;
    _eventAcceptedText = '';
    _eventHasMessageProjection = false;
    _eventAcceptedMetadata = const <String, Object?>{};
    _eventAcceptedOmissions = const <acp.AcpInputOmission>[];
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
      acp.AcpRetainedSizeEstimator(budget: inputBudget),
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
    final title = rawTitle is String && rawTitle.trim().isNotEmpty
        ? rawTitle.trim()
        : null;
    final updatedAtRaw = metadata['updatedAt'];
    final updatedAt = updatedAtRaw is String
        ? DateTime.tryParse(updatedAtRaw)?.toLocal()
        : null;
    final updated = session.copyWith(title: title, updatedAt: updatedAt);
    final estimator = acp.AcpRetainedSizeEstimator(budget: inputBudget);
    var retained = _sessionInfoStateHostRetainedBytes;
    if (updated.title != null) {
      retained = _addEstimatedRetainedBytes(retained, estimator, updated.title);
    }
    if (updated.updatedAt != null) {
      retained = _addEstimatedRetainedBytes(
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
    final omission = acp.AcpInputOmission(
      reason: acp.AcpInputOmissionReason.inputLimit,
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
      final nextRetained = _estimateChatMessageRetainedBytes(
        metadata: target.metadata,
        omissions: <acp.AcpInputOmission>[...target.omissions, omission],
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
          target._addOmissionForOwner(_messageOwnerToken, omission)) {
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
      omissions: <acp.AcpInputOmission>[omission],
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
    final parts = <_TurnTextAppend>[];
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
        _TurnTextAppend(
          target: pending.target,
          text: resolvedPrefix,
          acceptedUtf8Bytes: resolvedBytes,
        ),
      );
      parts.add(
        _TurnTextAppend(
          target: target,
          text: accepted.safePrefix.substring(resolvedCodeUnits),
          acceptedUtf8Bytes: accepted.acceptedBytes - resolvedBytes,
        ),
      );
    } else {
      parts.add(
        _TurnTextAppend(
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
    required List<_TurnTextAppend> parts,
    ChatMessage? omissionTarget,
    acp.AcpInputOmission? omission,
  }) {
    final projections = HashMap<ChatMessage, _TurnMessageProjection>.identity();
    _TurnMessageProjection projectionFor(ChatMessage message) {
      return projections.putIfAbsent(message, () {
        final retained = turnBudget.messageRetainedBytes[message];
        if (retained == null) {
          throw StateError('Turn message is not owned by the active ledger.');
        }
        return _TurnMessageProjection(
          message: message,
          previousRetained: retained,
        );
      });
    }

    try {
      for (final part in parts) {
        projectionFor(part.target).acceptedUtf8Bytes += part.acceptedUtf8Bytes;
      }
      if (omissionTarget != null && omission != null) {
        final projection = projectionFor(omissionTarget);
        final duplicate = projection.omissions.any(
          (existing) =>
              existing.resource == omission.resource &&
              existing.reason == omission.reason,
        );
        if (!duplicate &&
            projection.omissions.length < inputBudget.maxCollectionItems) {
          projection.omissions.add(omission);
        }
      }
      var totalDelta = 0;
      final nextRetained = HashMap<ChatMessage, int>.identity();
      for (final projection in projections.values) {
        final retained = _estimateChatMessageRetainedBytes(
          metadata: projection.message.metadata,
          omissions: projection.omissions,
          acceptedUtf8Bytes: projection.acceptedUtf8Bytes,
          inputBudget: inputBudget,
        );
        final delta = retained - projection.previousRetained;
        if (delta < 0) return false;
        totalDelta = _checkedRetainedAdd(totalDelta, delta);
        nextRetained[projection.message] = retained;
      }
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
      for (final part in parts) {
        final revision = part.target.revision;
        part.target._appendAcceptedTextForOwner(
          _messageOwnerToken,
          part.text,
          acceptedUtf8Bytes: part.acceptedUtf8Bytes,
        );
        if (part.target.revision != revision) {
          turnBudget.materializationTargets.add(part.target);
        }
      }
      if (omissionTarget != null && omission != null) {
        if (omissionTarget._addOmissionForOwner(_messageOwnerToken, omission)) {
          turnBudget.materializationTargets.add(omissionTarget);
        }
      }
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
    acp.AcpTextBudgetChunk finished,
  ) {
    if (target == null) return;
    final applied = _applyTurnTextMutation(
      turnBudget,
      parts: <_TurnTextAppend>[
        _TurnTextAppend(
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
    List<acp.AcpInputOmission> omissions = const <acp.AcpInputOmission>[],
  }) {
    final lastMessage = messages.isNotEmpty ? messages.last : null;
    final ChatMessage target;
    if (metadata.isEmpty && lastMessage != null && lastMessage.role == role) {
      target = lastMessage;
      final turnBudget = _ensureTurnBudget();
      for (final omission in omissions) {
        final applied = _applyTurnTextMutation(
          turnBudget,
          parts: const <_TurnTextAppend>[],
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
      final candidate = ChatMessage._guarded(
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
      _replaceTurnSettings(const AcpSessionSettings(), markAccepted: false);
      _resetAgentEventAcceptedProjection();
      _appendBehaviorFailureMarker(event.omissions);
      return;
    }
    if (kind == 'mode') {
      if (behaviorRejected) {
        _replaceTurnSettings(const AcpSessionSettings(), markAccepted: false);
        _resetAgentEventAcceptedProjection();
        _appendBehaviorFailureMarker(event.omissions);
        return;
      }
      final mode = event.metadata['mode'];
      if (mode is! String || mode.isEmpty) {
        _replaceTurnSettings(const AcpSessionSettings(), markAccepted: false);
        _resetAgentEventAcceptedProjection();
        _appendBehaviorFailureMarker(<acp.AcpInputOmission>[
          ...event.omissions,
          acp.AcpInputOmission(
            reason: acp.AcpInputOmissionReason.invalidStructure,
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
        _replaceTurnSettings(const AcpSessionSettings(), markAccepted: false);
        _resetAgentEventAcceptedProjection();
        _appendBehaviorFailureMarker(event.omissions);
        return;
      }
      final options = event.metadata['configOptions'];
      if (options is! List<AcpConfigOption>) {
        _replaceTurnSettings(const AcpSessionSettings(), markAccepted: false);
        _resetAgentEventAcceptedProjection();
        _appendBehaviorFailureMarker(<acp.AcpInputOmission>[
          ...event.omissions,
          acp.AcpInputOmission(
            reason: acp.AcpInputOmissionReason.invalidStructure,
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
          _appendBehaviorFailureMarker(<acp.AcpInputOmission>[
            ...event.omissions,
            acp.AcpInputOmission(
              reason: acp.AcpInputOmissionReason.invalidStructure,
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
        _appendBehaviorFailureMarker(<acp.AcpInputOmission>[
          ...event.omissions,
          acp.AcpInputOmission(
            reason: acp.AcpInputOmissionReason.invalidStructure,
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
          _appendBehaviorFailureMarker(<acp.AcpInputOmission>[
            ...event.omissions,
            acp.AcpInputOmission(
              reason: acp.AcpInputOmissionReason.invalidStructure,
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
          parts: const <_TurnTextAppend>[],
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
      final message = ChatMessage._guarded(
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

  void _appendBehaviorFailureMarker(List<acp.AcpInputOmission> omissions) {
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

  String _toolCallIdFromMetadata(Map<String, Object?> metadata) {
    for (final key in _toolCallIdMetadataKeys) {
      final value = _stringFromMap(metadata, key);
      if (value.isNotEmpty) return value;
    }
    final nested = metadata['toolCall'];
    if (nested is Map) {
      final nestedMetadata = nested.map(
        (key, value) => MapEntry(key.toString(), value),
      );
      for (final key in _toolCallIdMetadataKeys) {
        final value = _stringFromMap(nestedMetadata, key);
        if (value.isNotEmpty) return value;
      }
    }
    return '';
  }

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

  void _mergeSessionCatalog(List<AcpProjectSessions> projects) {
    final now = DateTime.now();
    for (final project in projects) {
      for (final entry in project.sessions) {
        final sessionId = entry.id.trim();
        if (sessionId.isEmpty) continue;

        final boundSession = _boundSessionWithId(sessionId);
        final existing = _sessionWithId(sessionId);
        final workspaceCwd = entry.cwd.trim().isEmpty ? project.cwd : entry.cwd;
        final boundAgentName = boundSession?.agentName?.trim();
        final catalogAgentName = _agentNameFromSessionCatalog(entry);
        final session = AgentSession(
          id: sessionId,
          cwd:
              boundSession?.cwd ??
              (workspaceCwd.trim().isEmpty ? cwd : workspaceCwd),
          createdAt:
              boundSession?.createdAt ??
              existing?.createdAt ??
              entry.updatedAt ??
              now,
          additionalDirectories:
              boundSession?.additionalDirectories ??
              entry.additionalDirectories,
          title: entry.title,
          titleOverride: existing?.titleOverride,
          updatedAt: entry.updatedAt ?? existing?.updatedAt,
          agentName: boundAgentName != null && boundAgentName.isNotEmpty
              ? boundSession!.agentName
              : catalogAgentName ?? existing?.agentName,
          initialEvents: existing?.initialEvents ?? const <AgentEvent>[],
          pinned: existing?.pinned ?? false,
          archived: existing?.archived ?? false,
          unread: existing?.unread ?? false,
        );
        _retiredSessionIds.remove(session.id);
        if (boundSession == null) {
          _removeLocalUnstartedSessionId(session.id);
        }
        if (currentSession?.id.trim() == sessionId) currentSession = session;
        _upsertSession(session);
      }
    }
    _notifyListeners();
  }

  AgentSession? _sessionWithId(String id) {
    for (final session in sessions) {
      if (_sessionIdsMatch(session.id, id)) return session;
    }
    return null;
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
    }
  }

  void _removeLocalUnstartedSessionId(String sessionId) {
    _localUnstartedSessionIds.removeWhere(
      (localId) => _sessionIdsMatch(localId, sessionId),
    );
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
      initialEvents: existing.initialEvents,
      pinned: indexed.pinned,
      archived: isCurrent ? false : indexed.archived,
      unread: isCurrent ? false : indexed.unread,
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

  String? _agentNameFromSessionCatalog(AcpSessionEntry entry) {
    final raw =
        entry.meta['agentName'] ??
        entry.meta['agent_name'] ??
        entry.meta['agent'];
    if (raw is! String) return null;
    final trimmed = raw.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  bool _sameSessionIndex(AgentSession a, AgentSession b) {
    return a.id == b.id &&
        a.cwd == b.cwd &&
        a.createdAt == b.createdAt &&
        a.updatedAt == b.updatedAt &&
        a.title == b.title &&
        a.titleOverride == b.titleOverride &&
        a.agentName == b.agentName &&
        a.pinned == b.pinned &&
        a.archived == b.archived &&
        a.unread == b.unread &&
        _sameStringList(a.additionalDirectories, b.additionalDirectories);
  }

  bool _sameStringList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var index = 0; index < a.length; index++) {
      if (a[index] != b[index]) return false;
    }
    return true;
  }

  List<AcpConfigOption> _configOptionsWithOverride(
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
        omissions: _boundedChatMessageOmissions(
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

  void _finishStreaming({bool notify = true, bool suppressProjection = false}) {
    final previousProjectionSuppression = _suppressAgentEventProjection;
    if (suppressProjection) _suppressAgentEventProjection = true;
    try {
      _finishTurnBudget();
    } finally {
      _suppressAgentEventProjection = previousProjectionSuppression;
    }
    if (!isStreaming) return;
    isStreaming = false;
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
    if (notify) _notifyListeners();
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

  ({String text, acp.AcpInputOmission? omission}) _boundedLocalErrorText(
    String raw,
  ) => _boundedLocalDisplayText(raw, resource: 'error text');

  ({String text, acp.AcpInputOmission? omission}) _boundedLocalDisplayText(
    String raw, {
    required String resource,
  }) {
    final counter = acp.AcpUtf8LineBudgetCounter(
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
        sessionSettings = const AcpSessionSettings();
      }
    } finally {
      if (notify && !_isDisposed && _activeSessionSettingsLoadId == loadId) {
        _activeSessionSettingsLoadId = null;
        sessionSettingsLoading = false;
        if (notify) _notifyListeners();
      }
    }
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
    _sessionOperationGeneration += 1;
    _sessionSettingsLoadSerial += 1;
    _finishTurnBudget();
    for (final snapshot in _archiveLeasesById.values.toList(growable: false)) {
      snapshot.discard();
    }
    _streamingNotificationPending = false;
    _isDisposed = true;
    final promptSubscription = _promptSubscription;
    _promptSubscription = null;
    _disposalFuture = _disposeResources(promptSubscription);
    unawaited(_disposalFuture);
    _resolvingPermissionRequestIds.clear();
    _reviewingPermissionRequestIds.clear();
    if (_notificationDepth == 0) _disposeChangeNotifier();
  }

  Future<void> _disposeResources(
    StreamSubscription<AgentEvent>? promptSubscription,
  ) async {
    await _ignoreCleanup(() => promptSubscription?.cancel());
    await _ignoreCleanup(_permissionSubscription.cancel);
    await _ignoreCleanup(_permissionInvalidationSubscription.cancel);
    await _ignoreCleanup(client.dispose);
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

bool _isChatHighSurrogate(int codeUnit) =>
    codeUnit >= 0xd800 && codeUnit <= 0xdbff;

bool _isChatLowSurrogate(int codeUnit) =>
    codeUnit >= 0xdc00 && codeUnit <= 0xdfff;
