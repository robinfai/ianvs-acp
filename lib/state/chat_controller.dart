import 'dart:async';
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
const int _maxSafeRetainedBytes = 0x1fffffffffffff;

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
    final boundedOmissions = _boundedChatMessageOmissions(
      omissions,
      guarded.omission,
      inputBudget.maxCollectionItems,
    );
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
  }) : _textBuffer = StringBuffer(text),
       _materializedText = text,
       _acceptedUtf8Bytes = acceptedUtf8Bytes ?? utf8.encode(text).length;

  final ChatMessageRole role;
  StringBuffer _textBuffer;
  String? _materializedText;
  int _revision;
  int _materializationCount = 0;
  int _acceptedUtf8Bytes;
  final bool _frozen;
  final acp.AcpInputBudget _inputBudget;
  int? _retainedBytes;

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
    final guarded = _guardChatMessageMetadata(metadata, inputBudget);
    final textBoundedOmissions = _boundedChatMessageOmissions(
      _omissions,
      textOmission,
      inputBudget.maxCollectionItems,
    );
    final copiedOmissions = List<acp.AcpInputOmission>.unmodifiable(
      _boundedChatMessageOmissions(
        textBoundedOmissions,
        guarded.omission,
        inputBudget.maxCollectionItems,
      ).map(_copyInputOmission),
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
    );
  }

  ChatMessage _copyWithFrozenState({required bool frozen}) {
    final copiedMetadata = _guardChatMessageMetadata(
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
    );
  }

  void _requireActive() {
    if (_frozen) {
      throw StateError('Frozen chat message is immutable.');
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
  final options = metadata['configOptions'];
  if (metadata['kind'] != 'config_option_update' || options is! List) {
    return estimator.estimate(metadata);
  }
  final typedOptions = options.whereType<AcpConfigOption>().toList(
    growable: false,
  );
  var retained = _typedConfigMetadataHostRetainedBytes;
  return _addConfigOptionsRetainedBytes(retained, estimator, typedOptions);
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
    retained = _addEstimatedRetainedBytes(
      retained,
      estimator,
      omission.resource,
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

({Map<String, Object?> metadata, acp.AcpInputOmission? omission})
_guardChatMessageMetadata(
  Map<String, Object?> metadata,
  acp.AcpInputBudget budget,
) {
  final snapshot = _snapshotChatMessageMetadata(metadata, budget);
  final stableMetadata = snapshot.metadata;
  if (stableMetadata == null) return _invalidChatMessageMetadata();
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
    return (metadata: guarded, omission: null);
  } on acp.AcpInputLimitExceeded catch (error) {
    return _limitedChatMessageMetadata(error);
  } on Object {
    return _invalidChatMessageMetadata();
  }
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

({Map<String, Object?> metadata, acp.AcpInputOmission? omission})
_limitedChatMessageMetadata(acp.AcpInputLimitExceeded error) => (
  metadata: const <String, Object?>{},
  omission: acp.AcpInputOmission(
    reason: acp.AcpInputOmissionReason.inputLimit,
    resource: 'chat message metadata',
    truncated: false,
    limit: error.limit,
    observedAtLeast: error.observedAtLeast,
  ),
);

({Map<String, Object?> metadata, acp.AcpInputOmission? omission})
_invalidChatMessageMetadata() => (
  metadata: const <String, Object?>{},
  omission: acp.AcpInputOmission(
    reason: acp.AcpInputOmissionReason.invalidStructure,
    resource: 'chat message metadata',
    truncated: false,
  ),
);

({Map<String, Object?> metadata, acp.AcpInputOmission? omission})?
_guardRecognizedTypedConfigUpdateMetadata(
  Map<String, Object?> metadata,
  acp.AcpInputBudget budget,
) {
  if (!_isRecognizedTypedConfigUpdateMetadata(metadata)) return null;
  try {
    final copied = _copyTypedConfigUpdateMetadata(metadata, budget);
    if (copied == null) return null;
    return (metadata: copied, omission: null);
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
    return count == 2 && kind == 'config_option_update' && options is List;
  } on Object {
    return false;
  }
}

({Map<String, Object?> metadata, acp.AcpInputOmission? omission})
_failedTypedConfigUpdateMetadata(acp.AcpInputOmission omission) => (
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
      retainedBytes: _estimateSessionSnapshotRetainedBytes(
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
  final guard = acp.AcpStructuredUpdateGuard(
    budget: inputBudget,
    resource: 'session snapshot',
  );
  guard.consumeContainerNode(field: 'session');
  List<String> directories = const <String>[];
  List<AgentEvent> events = const <AgentEvent>[];
  try {
    final copiedDirectories = guard.copyJsonValue(
      session.additionalDirectories,
      field: 'additional directories',
    );
    if (copiedDirectories is! List ||
        copiedDirectories.any((directory) => directory is! String)) {
      throw const FormatException('Invalid session directories.');
    }
    directories = List<String>.unmodifiable(copiedDirectories.cast<String>());
    events = _copyInitialEvents(session.initialEvents, inputBudget, guard);
  } on Object {
    directories = const <String>[];
    events = const <AgentEvent>[];
  }
  return AgentSession(
    id: session.id,
    cwd: session.cwd,
    createdAt: session.createdAt,
    additionalDirectories: directories,
    title: session.title,
    titleOverride: session.titleOverride,
    updatedAt: session.updatedAt,
    agentName: session.agentName,
    initialEvents: events,
    pinned: session.pinned,
    archived: session.archived,
    unread: session.unread,
  );
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

int _estimateSessionSnapshotRetainedBytes({
  required List<ChatMessage> messages,
  required List<Map<String, Object?>> availableCommands,
  required AcpSessionSettings sessionSettings,
  required AcpSessionUsage? sessionUsage,
  required AgentSession session,
  required Duration? lastLatency,
  required String? lastError,
  required int? activeSessionSettingsLoadId,
  required acp.AcpInputBudget inputBudget,
}) {
  final estimator = acp.AcpRetainedSizeEstimator(budget: inputBudget);
  var retained = _addRetainedListHostBytes(
    _sessionSnapshotHostRetainedBytes,
    messages.length,
  );
  for (final message in messages) {
    retained = _checkedRetainedAdd(retained, message.retainedBytes);
  }
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
    : text = acp.AcpUtf8LineBudgetCounter(
        maxBytes: budget.maxMessageTextBytes,
        maxLines: budget.maxMessageTextLines,
        resource: 'message text',
      ),
      thought = acp.AcpUtf8LineBudgetCounter(
        maxBytes: budget.maxThoughtTextBytes,
        maxLines: budget.maxMessageTextLines,
        resource: 'thought text',
      );

  final acp.AcpUtf8LineBudgetCounter text;
  final acp.AcpUtf8LineBudgetCounter thought;
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
    this.permissionHistoryLimit = defaultPermissionHistoryLimit,
    this.inputBudget = const acp.AcpInputBudget(),
    List<AcpPermissionTrustRule> permissionTrustRules =
        const <AcpPermissionTrustRule>[],
    this.permissionReviewer,
  }) : assert(permissionHistoryLimit > 0),
       permissionTrustRules = List.unmodifiable(permissionTrustRules) {
    inputBudget.validate();
    _permissionSubscription = client.permissionRequests.listen(
      _handlePermissionRequest,
      onError: (Object error, StackTrace stackTrace) => _setActionError(error),
      onDone: _handlePermissionRequestsDone,
    );
  }

  static const int defaultPermissionHistoryLimit = 500;
  static const Duration defaultCleanupTimeout = Duration(seconds: 2);

  final AcpAgentClient client;
  final String cwd;
  final List<String> additionalDirectories;
  final String agentName;
  final int permissionHistoryLimit;
  final acp.AcpInputBudget inputBudget;
  final List<AcpPermissionTrustRule> permissionTrustRules;
  final AcpPermissionReviewer? permissionReviewer;

  ConnectionStatus status = ConnectionStatus.disconnected;
  AgentSession? currentSession;
  final List<AgentSession> sessions = <AgentSession>[];
  final List<ChatMessage> messages = <ChatMessage>[];
  List<Map<String, Object?>> availableCommands = const <Map<String, Object?>>[];
  AcpAgentCapabilities? capabilities;
  AcpSessionSettings sessionSettings = const AcpSessionSettings();
  AcpSessionUsage? sessionUsage;
  AcpPermissionRequest? pendingPermissionRequest;
  AcpToolCallExecutionPolicy toolCallExecutionPolicy =
      AcpToolCallExecutionPolicy.defaultPermissions;
  final List<AcpPermissionAuditEntry> _permissionHistory =
      <AcpPermissionAuditEntry>[];
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
  String? lastError;
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

  bool get supportsSessionClose => capabilities?.session.close == true;

  bool get supportsSessionFork => capabilities?.session.fork == true;

  bool get supportsSessionList => capabilities?.session.list == true;

  bool get supportsSessionResume {
    return capabilities?.loadSession == true ||
        capabilities?.session.resume == true;
  }

  bool get supportsAuthLogout => capabilities?.auth.logout == true;

  bool get hasPermissionReviewer => permissionReviewer != null;

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

  StreamSubscription<AgentEvent>? _promptSubscription;
  late final StreamSubscription<AcpPermissionRequest> _permissionSubscription;
  DateTime? _lastPromptStartedAt;
  Duration? lastLatency;
  int _sessionSettingsLoadSerial = 0;
  int? _activeSessionSettingsLoadId;

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
    await _runSessionOperation(() async {
      try {
        if (status == ConnectionStatus.disconnected ||
            status == ConnectionStatus.error) {
          await _connectWithStatus(ConnectionStatus.connecting);
          if (status == ConnectionStatus.error) return;
        }
        final session = (await client.createSession(
          cwd: workspaceCwd,
          additionalDirectories: additionalDirectories,
        )).copyWith(agentName: agentName);
        _snapshotCurrentSession();
        _retiredSessionIds.remove(session.id);
        currentSession = session;
        _upsertSession(session);
        messages.clear();
        availableCommands = const <Map<String, Object?>>[];
        lastLatency = null;
        lastError = null;
        sessionSettings = const AcpSessionSettings();
        sessionUsage = null;
        for (final event in session.initialEvents) {
          _handleAgentEvent(event, notify: false);
        }
        _finishTurnBudget();
        if (messages.isEmpty) {
          _localUnstartedSessionIds.add(session.id);
        } else {
          _localUnstartedSessionIds.remove(session.id);
        }
        await _loadSessionSettings(session.id, notify: false);
        if (status != ConnectionStatus.error) {
          status = ConnectionStatus.sessionReady;
          created = currentSession?.id == session.id;
        }
        _notifyListeners();
      } catch (error) {
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
    final activeSession = currentSession;
    if (activeSession != null && activeSession.id.trim() == trimmedSessionId) {
      final requestedCwd = explicitCwd == null || explicitCwd.isEmpty
          ? activeSession.cwd
          : explicitCwd;
      final requestedDirectories =
          additionalDirectories ?? activeSession.additionalDirectories;
      if (sessionWorkspaceIdentityMatches(
        activeSession,
        sessionId: trimmedSessionId,
        cwd: requestedCwd,
        additionalDirectories: requestedDirectories,
      )) {
        return;
      }
      _setError(StateError(sessionWorkspaceConflictMessage(trimmedSessionId)));
      return;
    }
    final workspaceCwd = explicitCwd == null || explicitCwd.isEmpty
        ? this.cwd
        : explicitCwd;
    final workspaceAdditionalDirectories =
        additionalDirectories ?? this.additionalDirectories;
    _finishTurnBudget();

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
      try {
        await _promptSubscription?.cancel();
        _promptSubscription = null;
        if (status == ConnectionStatus.disconnected ||
            status == ConnectionStatus.error) {
          await _connectWithStatus(ConnectionStatus.connecting);
          if (status == ConnectionStatus.error) return;
        }

        final existingSession = _sessionWithId(trimmedSessionId);
        _snapshotCurrentSession();
        final snapshot = _sessionViewSnapshots[trimmedSessionId];
        if (snapshot != null) {
          await _activateSessionViewSnapshot(
            snapshot,
            cwd: explicitCwd == null || explicitCwd.isEmpty
                ? null
                : explicitCwd,
            additionalDirectories: additionalDirectories,
            title: title,
            updatedAt: updatedAt,
          );
          return;
        }
        if (existingSession != null &&
            _localUnstartedSessionIds.contains(trimmedSessionId)) {
          await _activateLocalUnstartedSession(
            existingSession,
            cwd: explicitCwd == null || explicitCwd.isEmpty
                ? null
                : explicitCwd,
            additionalDirectories: additionalDirectories,
            title: title,
            updatedAt: updatedAt,
          );
          return;
        }
        status = ConnectionStatus.reconnecting;
        isStreaming = false;
        lastError = null;
        messages.clear();
        availableCommands = const <Map<String, Object?>>[];
        lastLatency = null;
        sessionSettings = const AcpSessionSettings();
        sessionUsage = null;
        final session = AgentSession(
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
        );
        _retiredSessionIds.remove(session.id);
        currentSession = session;
        _upsertSession(session);
        _cancelPendingPermissionOutsideSession(session.id);
        isSessionReplayLoading = true;
        _notifyListeners();
        await Future<void>.delayed(Duration.zero);

        final replay = await client.resumeSession(
          sessionId: trimmedSessionId,
          cwd: workspaceCwd,
          additionalDirectories: workspaceAdditionalDirectories,
        );
        _localUnstartedSessionIds.remove(trimmedSessionId);
        await _replaySessionEvents(replay);
        await _loadSessionSettings(trimmedSessionId, notify: false);
        isSessionReplayLoading = false;
        if (status != ConnectionStatus.error) {
          status = ConnectionStatus.sessionReady;
        }
        _notifyListeners();
      } catch (error) {
        currentSession = previousSession;
        _cancelPendingPermissionOutsideSession(previousSession?.id);
        sessions
          ..clear()
          ..addAll(previousSessions);
        messages
          ..clear()
          ..addAll(previousMessages);
        availableCommands = previousAvailableCommands;
        lastLatency = previousLastLatency;
        sessionSettings = previousSessionSettings;
        sessionUsage = previousSessionUsage;
        sessionSettingsLoading = previousSessionSettingsLoading;
        _activeSessionSettingsLoadId = previousSettingsLoadId;
        isSessionReplayLoading = previousSessionReplayLoading;
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

      if (currentSession?.id == nextSession.id) currentSession = nextSession;
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
    final wasCurrent = currentSession?.id == sessionId;
    if (wasCurrent) _finishTurnBudget();
    final inactiveSnapshot = wasCurrent
        ? null
        : _sessionViewSnapshots[sessionId];
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

    _upsertSession(session.copyWith(archived: true, unread: false));
    _sessionViewSnapshots.remove(sessionId);
    if (wasCurrent) {
      currentSession = null;
      messages.clear();
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
    _notifyListeners();
    return snapshot;
  }

  void restoreArchivedSessionLocally(ArchivedSessionSnapshot snapshot) {
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
    _upsertSession(prepared.session);
    if (wasCurrent && currentSession == null) {
      currentSession = prepared.session;
      messages
        ..clear()
        ..addAll(prepared.messages.map((message) => message.thaw()));
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
      _sessionViewSnapshots[prepared.session.id] = prepared;
    }
    _notifyListeners();
  }

  void setSessionUnread(String sessionId, bool unread) {
    _updateSessionMetadata(sessionId, (session) {
      if (session.unread == unread) return session;
      return session.copyWith(unread: unread);
    });
  }

  void _snapshotCurrentSession() {
    final session = currentSession;
    if (session == null) return;
    _finishTurnBudget();
    _sessionViewSnapshots[session.id] = _SessionViewSnapshot(
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
    );
  }

  Future<void> _activateSessionViewSnapshot(
    _SessionViewSnapshot snapshot, {
    String? cwd,
    List<String>? additionalDirectories,
    String? title,
    DateTime? updatedAt,
  }) async {
    final existingSession = _sessionWithId(snapshot.session.id);
    final sidebarSession = existingSession ?? snapshot.session;
    final session = sidebarSession.copyWith(
      cwd: cwd ?? sidebarSession.cwd,
      additionalDirectories:
          additionalDirectories ?? sidebarSession.additionalDirectories,
      title: title ?? sidebarSession.title,
      updatedAt: updatedAt ?? sidebarSession.updatedAt,
      archived: false,
      unread: false,
    );
    _retiredSessionIds.remove(session.id);
    currentSession = session;
    _upsertSession(session);
    _cancelPendingPermissionOutsideSession(session.id);
    messages
      ..clear()
      ..addAll(snapshot.messages.map((message) => message.thaw()));
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
    _sessionViewSnapshots[session.id] = _SessionViewSnapshot(
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
    );
    _notifyListeners();
  }

  Future<void> _activateLocalUnstartedSession(
    AgentSession existingSession, {
    String? cwd,
    List<String>? additionalDirectories,
    String? title,
    DateTime? updatedAt,
  }) async {
    final session = existingSession.copyWith(
      cwd: cwd ?? existingSession.cwd,
      additionalDirectories:
          additionalDirectories ?? existingSession.additionalDirectories,
      title: title ?? existingSession.title,
      updatedAt: updatedAt ?? existingSession.updatedAt,
      archived: false,
      unread: false,
    );
    _retiredSessionIds.remove(session.id);
    currentSession = session;
    _upsertSession(session);
    _cancelPendingPermissionOutsideSession(session.id);
    messages.clear();
    availableCommands = const <Map<String, Object?>>[];
    lastLatency = null;
    lastError = null;
    sessionSettings = const AcpSessionSettings();
    sessionUsage = null;
    sessionSettingsLoading = false;
    status = ConnectionStatus.reconnecting;
    _notifyListeners();

    await _loadSessionSettings(session.id, notify: false);
    if (status != ConnectionStatus.error) {
      status = ConnectionStatus.sessionReady;
    }
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
    _localUnstartedSessionIds.remove(session.id);
    _finishTurnBudget();
    _turnBudget = _TurnBudgetState(inputBudget);

    final contentBlocks = attachments
        .map((attachment) => attachment.toResourceLink())
        .toList();
    messages.add(
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
      _sessionViewSnapshots.clear();
      availableCommands = const <Map<String, Object?>>[];
      sessionSettings = const AcpSessionSettings();
      sessionSettingsLoading = false;
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

    await _runSessionOperation(() async {
      try {
        await _promptSubscription?.cancel();
        _promptSubscription = null;
        if (status == ConnectionStatus.disconnected ||
            status == ConnectionStatus.error) {
          await _connectWithStatus(ConnectionStatus.connecting);
          if (status == ConnectionStatus.error) return;
        }
        final forked = await client.forkSession(
          sessionId: session.id,
          cwd: session.cwd,
          additionalDirectories: session.additionalDirectories,
        );
        final forkedTitle = forked.title?.trim().isNotEmpty == true
            ? forked.title
            : 'Fork of ${session.displayTitle}';
        final updatedSession = forked.copyWith(
          title: forkedTitle,
          agentName: agentName,
        );
        _retiredSessionIds.remove(updatedSession.id);
        currentSession = updatedSession;
        _upsertSession(updatedSession);
        messages.clear();
        availableCommands = const <Map<String, Object?>>[];
        lastLatency = null;
        lastError = null;
        sessionSettings = const AcpSessionSettings();
        sessionUsage = null;
        for (final event in updatedSession.initialEvents) {
          _handleAgentEvent(event, notify: false);
        }
        _finishTurnBudget();
        await _loadSessionSettings(updatedSession.id, notify: false);
        if (status != ConnectionStatus.error) {
          status = ConnectionStatus.sessionReady;
        }
        _notifyListeners();
      } catch (error) {
        _setActionError(error);
      }
    });
  }

  Future<void> closeCurrentSession() async {
    final session = currentSession;
    if (session == null || !supportsSessionClose) return;
    if (isStreaming || isSessionOperationRunning) return;
    _finishTurnBudget();

    await _runSessionOperation(() async {
      try {
        await _promptSubscription?.cancel();
        _promptSubscription = null;
        await client.closeSession(sessionId: session.id);
        _retiredSessionIds.add(session.id);
        _localUnstartedSessionIds.remove(session.id);
        _sessionViewSnapshots.remove(session.id);
        currentSession = null;
        sessions.removeWhere((item) => item.id == session.id);
        messages.clear();
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
        _sessionViewSnapshots.clear();
        currentSession = null;
        sessions.clear();
        messages.clear();
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

    try {
      final result = await client.sendExtensionRequest(
        method: trimmedMethod,
        params: params,
      );
      lastError = null;
      _notifyListeners();
      return result;
    } catch (error) {
      _setActionError(error);
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
    isSessionOperationRunning = true;
    _notifyListeners();
    try {
      await action();
    } finally {
      isSessionOperationRunning = false;
      _notifyListeners();
    }
  }

  Future<T> _runSessionOperationWithResult<T>(
    Future<T> Function() action,
  ) async {
    isSessionOperationRunning = true;
    _notifyListeners();
    try {
      return await action();
    } finally {
      isSessionOperationRunning = false;
      _notifyListeners();
    }
  }

  AgentEvent _safeAgentEvent(AgentEvent event) {
    final guarded = _guardChatMessageMetadata(event.metadata, inputBudget);
    return AgentEvent(
      type: event.type,
      text: event.text,
      timestamp: event.timestamp,
      metadata: guarded.metadata,
      omissions: _boundedChatMessageOmissions(
        event.omissions,
        guarded.omission,
        inputBudget.maxCollectionItems,
      ),
    );
  }

  void _handleAgentEvent(AgentEvent event, {bool notify = true}) {
    if (_isDisposed) return;
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
    if (notify && !coalescesNotification) {
      _materializeTurnTargets();
      _flushStreamingNotification();
      if (_isDisposed) return;
    }
    if (event.type == AgentEventType.userMessage) {
      _finishTurnBudget();
    }
    _notifyAgentEventObservers(event);
    switch (event.type) {
      case AgentEventType.userMessage:
        messages.add(
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
        _finishStreaming(notify: false);
      case AgentEventType.toolCall:
        _appendToolCall(event);
      case AgentEventType.error:
        final message = _messageForAgentError(event);
        lastError = message;
        messages.add(
          ChatMessage(
            role: ChatMessageRole.error,
            text: message,
            omissions: event.omissions,
            inputBudget: inputBudget,
          ),
        );
        status = ConnectionStatus.error;
        _finishStreaming(notify: false);
      case AgentEventType.status:
        _appendStatus(event);
    }
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

  void _appendToolCall(AgentEvent event) {
    final toolCallId = _toolCallIdFromMetadata(event.metadata);
    if (toolCallId.isEmpty) {
      messages.add(
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

      messages[index] = ChatMessage(
        role: ChatMessageRole.tool,
        text: event.text.trim().isEmpty ? message.text : event.text,
        timestamp: message.timestamp,
        metadata: _mergeMetadata(message.metadata, event.metadata),
        omissions: [...message.omissions, ...event.omissions],
        inputBudget: inputBudget,
      );
      return;
    }

    messages.add(
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
        _recordPermissionReview(request, result);
        final decision = result.decision;
        if (decision == null) {
          _notifyListeners();
          return;
        }
        if (decision == AcpPermissionDecision.allow &&
            (!reviewer.canAutoApprove ||
                result.risk.trim().toLowerCase() != 'low')) {
          _notifyListeners();
          return;
        }
        if (!_isCurrentPermissionRequest(request)) return;
        await _resolvePermissionRequest(
          request,
          decision,
          source: AcpPermissionDecisionSource.reviewAgent,
          reviewResult: result,
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
    if (_permissionHistory.length <= permissionHistoryLimit) return;
    _permissionHistory.removeRange(
      permissionHistoryLimit,
      _permissionHistory.length,
    );
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
    _permissionHistory[index] = _permissionHistory[index].copyWith(
      status: _permissionAuditStatus(decision),
      resolvedAt: DateTime.now(),
      decisionSource: source,
      reviewResult: reviewResult,
      selectedOptionId: selectedOptionId,
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
    _permissionHistory[index] = _permissionHistory[index].copyWith(
      reviewResult: reviewResult,
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
    return _turnBudget ??= _TurnBudgetState(inputBudget);
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
    final pending = thought
        ? turnBudget.thoughtPendingHigh
        : turnBudget.textPendingHigh;
    if (thought) {
      turnBudget.thoughtTarget = target;
    } else {
      turnBudget.textTarget = target;
    }

    final accepted = counter.append(chunk);
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
      _appendAcceptedToTarget(
        turnBudget,
        pending.target,
        resolvedPrefix,
        resolvedBytes,
      );
      _appendAcceptedToTarget(
        turnBudget,
        target,
        accepted.safePrefix.substring(resolvedCodeUnits),
        accepted.acceptedBytes - resolvedBytes,
      );
    } else {
      _appendAcceptedToTarget(
        turnBudget,
        target,
        accepted.safePrefix,
        accepted.acceptedBytes,
      );
    }

    if (accepted.omission case final omission?) {
      final omissionTarget = pending != null && accepted.safePrefix.isEmpty
          ? pending.target
          : target;
      if (omissionTarget.addOmission(omission)) {
        turnBudget.materializationTargets.add(omissionTarget);
      }
    }

    final _PendingHighSurrogate? nextPending;
    if (accepted.omission != null) {
      nextPending = null;
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

  void _appendAcceptedToTarget(
    _TurnBudgetState turnBudget,
    ChatMessage target,
    String text,
    int acceptedUtf8Bytes,
  ) {
    final revision = target.revision;
    target.appendAcceptedText(text, acceptedUtf8Bytes: acceptedUtf8Bytes);
    if (target.revision != revision) {
      turnBudget.materializationTargets.add(target);
    }
  }

  void _finishTurnBudget() {
    _streamingNotificationPending = false;
    final turnBudget = _turnBudget;
    if (turnBudget == null) return;
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
  }

  void _appendFinishedText(
    _TurnBudgetState turnBudget,
    ChatMessage? target,
    acp.AcpTextBudgetChunk finished,
  ) {
    if (target == null) return;
    _appendAcceptedToTarget(
      turnBudget,
      target,
      finished.safePrefix,
      finished.acceptedBytes,
    );
    if (finished.omission case final omission?) {
      if (target.addOmission(omission)) {
        turnBudget.materializationTargets.add(target);
      }
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
      for (final omission in omissions) {
        target.addOmission(omission);
      }
    } else {
      target = ChatMessage(
        role: role,
        text: '',
        metadata: metadata,
        omissions: omissions,
        inputBudget: inputBudget,
      );
      messages.add(target);
    }
    _appendTextToMessage(target, text);
  }

  void _appendStatus(AgentEvent event) {
    final kind = event.metadata['kind'];
    if (kind == 'mode') {
      final mode = event.metadata['mode'];
      if (mode is String && mode.isNotEmpty) {
        sessionSettings = sessionSettings.withCurrentMode(mode);
      }
    }
    if (kind == 'config_option_update') {
      final options = event.metadata['configOptions'];
      if (options is List<AcpConfigOption>) {
        sessionSettings = sessionSettings.withPreferredConfigOptions(options);
      }
      return;
    }
    if (kind == 'session_info_update') {
      _applySessionInfoUpdate(event.metadata);
      return;
    }
    if (kind == 'usage_update') {
      _applyUsageUpdate(event.metadata);
      return;
    }
    if (kind == 'terminal') {
      _upsertTerminalStatusMessage(event);
      return;
    }
    if (kind == 'plan' || kind == 'commands') {
      if (kind == 'commands') {
        availableCommands = _commandsFromMetadata(event.metadata['commands']);
      }
      _replaceStatusMessage(event);
      return;
    }
    final lastMessage = messages.isNotEmpty ? messages.last : null;
    if (kind == 'thought' &&
        lastMessage != null &&
        lastMessage.role == ChatMessageRole.status &&
        lastMessage.metadata['kind'] == 'thought') {
      for (final omission in event.omissions) {
        lastMessage.addOmission(omission);
      }
      _appendThoughtToMessage(lastMessage, event.text);
      return;
    }
    if (kind == 'thought') {
      final message = ChatMessage(
        role: ChatMessageRole.status,
        text: '',
        metadata: event.metadata,
        omissions: event.omissions,
        inputBudget: inputBudget,
      );
      messages.add(message);
      _appendThoughtToMessage(message, event.text);
      return;
    }
    messages.add(
      ChatMessage(
        role: ChatMessageRole.status,
        text: event.text,
        metadata: event.metadata,
        omissions: event.omissions,
        inputBudget: inputBudget,
      ),
    );
  }

  void _upsertTerminalStatusMessage(AgentEvent event) {
    final terminalId = event.metadata['terminalId'];
    if (terminalId is! String || terminalId.trim().isEmpty) {
      messages.add(
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
      messages.add(
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
    messages[index] = ChatMessage(
      role: ChatMessageRole.status,
      text: _terminalStatusText(event.text, previous.text),
      metadata: metadata,
      omissions: [...previous.omissions, ...event.omissions],
      inputBudget: inputBudget,
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

  void _replaceStatusMessage(AgentEvent event) {
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
      messages.add(message);
    } else {
      messages[index] = message;
    }
  }

  List<Map<String, Object?>> _commandsFromMetadata(Object? raw) {
    if (raw is! List) return const <Map<String, Object?>>[];
    return raw
        .whereType<Map>()
        .map(
          (item) => item.map((key, value) => MapEntry(key.toString(), value)),
        )
        .toList(growable: false);
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

  void _applyUsageUpdate(Map<String, Object?> metadata) {
    final used = _intFromObject(metadata['used']);
    final size = _intFromObject(metadata['size']);
    if (used == null || size == null || used < 0 || size <= 0) return;
    sessionUsage = AcpSessionUsage(
      used: used,
      size: size,
      cost: _usageCostFromObject(metadata['cost']),
    );
  }

  AcpSessionUsageCost? _usageCostFromObject(Object? raw) {
    if (raw is! Map) return null;
    final mapped = raw.map((key, value) => MapEntry(key.toString(), value));
    final amount = _numFromObject(mapped['amount']);
    final currency = mapped['currency']?.toString().trim() ?? '';
    if (amount == null || currency.isEmpty) return null;
    return AcpSessionUsageCost(amount: amount, currency: currency);
  }

  int? _intFromObject(Object? raw) {
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw.trim());
    return null;
  }

  num? _numFromObject(Object? raw) {
    if (raw is num) return raw;
    if (raw is String) return num.tryParse(raw.trim());
    return null;
  }

  void _applySessionInfoUpdate(Map<String, Object?> metadata) {
    final session = currentSession;
    if (session == null) return;
    final sessionId = metadata['sessionId'];
    if (sessionId is String &&
        sessionId.isNotEmpty &&
        sessionId != session.id) {
      return;
    }

    final rawTitle = metadata['title'];
    final title = rawTitle is String && rawTitle.trim().isNotEmpty
        ? rawTitle.trim()
        : null;
    final updatedAtRaw = metadata['updatedAt'];
    final updatedAt = updatedAtRaw is String
        ? DateTime.tryParse(updatedAtRaw)?.toLocal()
        : null;
    final updatedSession = session.copyWith(title: title, updatedAt: updatedAt);
    currentSession = updatedSession;
    _upsertSession(updatedSession);
  }

  void _upsertSession(AgentSession session) {
    final index = sessions.indexWhere((item) => item.id == session.id);
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

        final existing = _sessionWithId(sessionId);
        final workspaceCwd = entry.cwd.trim().isEmpty ? project.cwd : entry.cwd;
        final session = AgentSession(
          id: sessionId,
          cwd: workspaceCwd.trim().isEmpty ? cwd : workspaceCwd,
          createdAt: existing?.createdAt ?? entry.updatedAt ?? now,
          additionalDirectories: entry.additionalDirectories,
          title: entry.title,
          titleOverride: existing?.titleOverride,
          updatedAt: entry.updatedAt,
          agentName: _agentNameFromSessionCatalog(entry) ?? existing?.agentName,
          initialEvents: existing?.initialEvents ?? const <AgentEvent>[],
          pinned: existing?.pinned ?? false,
          archived: existing?.archived ?? false,
          unread: existing?.unread ?? false,
        );
        _retiredSessionIds.remove(session.id);
        _localUnstartedSessionIds.remove(session.id);
        if (currentSession?.id == session.id) currentSession = session;
        _upsertSession(session);
      }
    }
    _notifyListeners();
  }

  AgentSession? _sessionWithId(String id) {
    for (final session in sessions) {
      if (session.id == id) return session;
    }
    return null;
  }

  AgentSession _mergeSessionIndexMetadata(
    AgentSession existing,
    AgentSession indexed,
  ) {
    final existingAgentName = existing.agentName?.trim();
    final indexedAgentName = indexed.agentName?.trim();
    final isCurrent = currentSession?.id == existing.id;
    final titleOverride = indexed.titleOverride?.trim().isNotEmpty == true
        ? indexed.titleOverride
        : existing.titleOverride;
    return AgentSession(
      id: existing.id,
      cwd: existing.cwd.trim().isEmpty ? indexed.cwd : existing.cwd,
      createdAt: existing.createdAt,
      additionalDirectories: existing.additionalDirectories.isEmpty
          ? indexed.additionalDirectories
          : existing.additionalDirectories,
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
    if (currentSession?.id == sessionId) currentSession = updated;
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
    messages.add(
      ChatMessage(
        role: ChatMessageRole.status,
        text: _stopReasonLabel(stopReason),
        metadata: <String, Object?>{'kind': 'turn', 'stopReason': stopReason},
        omissions: event.omissions,
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
      _ => 'Turn ended: $stopReason',
    };
  }

  void _finishStreaming({bool notify = true}) {
    _finishTurnBudget();
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
    lastError = _messageForError(error);
    status = ConnectionStatus.error;
    isStreaming = false;
    _notifyListeners();
  }

  void _setActionError(Object error) {
    lastError = _messageForError(error);
    if (status == ConnectionStatus.error) {
      status = currentSession == null
          ? ConnectionStatus.connected
          : ConnectionStatus.sessionReady;
    }
    _notifyListeners();
  }

  String _messageForAgentError(AgentEvent event) {
    if (_containsAuthRequired(event.text) ||
        _containsAuthRequired(event.metadata)) {
      return _authRequiredMessage();
    }
    return event.text;
  }

  String _messageForError(Object error) {
    if (_containsAuthRequired(error.toString()) ||
        _containsAuthRequired(_dynamicField(error, 'message')) ||
        _containsAuthRequired(_dynamicField(error, 'code')) ||
        _containsAuthRequired(_dynamicField(error, 'data'))) {
      return _authRequiredMessage();
    }
    return error.toString();
  }

  String _authRequiredMessage() {
    if (authMethods.isNotEmpty) {
      return 'Authentication required. Open the Agents menu and choose Authenticate, then try again.';
    }
    return 'Authentication required, but this agent did not advertise an authentication method.';
  }

  bool _containsAuthRequired(Object? value) {
    if (value == null) return false;
    if (value is String) return value.toLowerCase().contains('auth_required');
    if (value is Map) {
      return value.entries.any((entry) {
        return _containsAuthRequired(entry.key.toString()) ||
            _containsAuthRequired(entry.value);
      });
    }
    if (value is Iterable) return value.any(_containsAuthRequired);
    return false;
  }

  Object? _dynamicField(Object object, String fieldName) {
    try {
      final dynamic value = object;
      return switch (fieldName) {
        'code' => value.code,
        'data' => value.data,
        'message' => value.message,
        _ => null,
      };
    } catch (_) {
      return null;
    }
  }

  Future<void> _loadSessionSettings(
    String sessionId, {
    bool notify = true,
  }) async {
    final loadId = ++_sessionSettingsLoadSerial;
    _activeSessionSettingsLoadId = loadId;
    sessionSettingsLoading = true;
    if (notify) _notifyListeners();

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
      if (_activeSessionSettingsLoadId == loadId) {
        _activeSessionSettingsLoadId = null;
        sessionSettingsLoading = false;
        if (notify) _notifyListeners();
      }
    }
  }

  bool _isCurrentSessionSettingsLoad(int loadId, String sessionId) {
    return !_isDisposed &&
        _activeSessionSettingsLoadId == loadId &&
        _isActiveSession(sessionId);
  }

  bool _isActiveSession(String sessionId) {
    return !_isDisposed && currentSession?.id == sessionId;
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
    _finishTurnBudget();
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
