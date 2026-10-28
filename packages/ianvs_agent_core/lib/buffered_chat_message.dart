import 'dart:convert';
import 'models/chat_message.dart';
import 'models/chat_session_settings.dart';
import 'models/chat_input_budget.dart' as acp;

const int _chatMessageHostRetainedBytes = 512;
const int projectionRetainedListHostBytes = 64;
const int projectionRetainedListItemHostBytes = 32;
const int _typedConfigMetadataHostRetainedBytes = 192;
const int _configOptionHostRetainedBytes = 448;
const int _configChoiceHostRetainedBytes = 224;
const int _inputOmissionHostRetainedBytes = 320;
const int _contentBlockMetadataHostRetainedBytes = 256;
const int _contentBlockHostRetainedBytes = 320;
const int _thoughtMetadataHostRetainedBytes = 128;
const int _maxSafeRetainedBytes = 0x1fffffffffffff;

final class GuardedChatMetadata {
  const GuardedChatMetadata({
    required this.metadata,
    this.omission,
    this.localOmissions = const <acp.ChatInputOmission>[],
  });

  final Map<String, Object?> metadata;
  final acp.ChatInputOmission? omission;
  final List<acp.ChatInputOmission> localOmissions;
}

class ChatMessage implements ChatMessageView {
  factory ChatMessage({
    required ChatMessageRole role,
    required String text,
    DateTime? timestamp,
    Map<String, Object?> metadata = const <String, Object?>{},
    List<acp.ChatInputOmission> omissions = const <acp.ChatInputOmission>[],
    acp.ChatInputBudget inputBudget = const acp.ChatInputBudget(),
  }) {
    inputBudget.validate();
    final guarded = projectionGuardChatMessageMetadata(metadata, inputBudget);
    var boundedOmissions = projectionBoundedChatMessageOmissions(
      omissions,
      guarded.omission,
      inputBudget.maxCollectionItems,
    );
    for (final omission in guarded.localOmissions) {
      boundedOmissions = projectionBoundedChatMessageOmissions(
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

  factory ChatMessage.projectionGuarded({
    required ChatMessageRole role,
    required String text,
    DateTime? timestamp,
    required Map<String, Object?> metadata,
    required List<acp.ChatInputOmission> omissions,
    required acp.ChatInputBudget inputBudget,
  }) {
    inputBudget.validate();
    return ChatMessage._(
      role: role,
      text: text,
      timestamp: timestamp ?? DateTime.now(),
      metadata: metadata,
      omissions: List<acp.ChatInputOmission>.unmodifiable(omissions),
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
       projectionTurnId = turnId {
    final preview = _boundedChatMessagePreview(text);
    _previewText = preview.text;
    _previewTextTruncated = preview.truncated;
  }

  @override
  final ChatMessageRole role;
  StringBuffer _textBuffer;
  String? _materializedText;
  late String _previewText;
  late bool _previewTextTruncated;
  int _revision;
  int _materializationCount = 0;
  int _acceptedUtf8Bytes;
  final bool _frozen;
  final acp.ChatInputBudget _inputBudget;
  int? _retainedBytes;
  int? projectionTurnId;
  Object? projectionOwnerToken;

  @override
  int? get turnId => projectionTurnId;

  void projectionClaimOwnership(Object ownerToken, int turnId) {
    if (_frozen || projectionOwnerToken != null || projectionTurnId != null) {
      throw StateError('Chat message is already owned.');
    }
    projectionOwnerToken = ownerToken;
    projectionTurnId = turnId;
  }

  void projectionRequireOwner(Object ownerToken) {
    if (!identical(projectionOwnerToken, ownerToken)) {
      throw StateError('Chat message is not owned by this controller.');
    }
  }

  @override
  String get text {
    final cached = _materializedText;
    if (cached != null) return cached;
    final materialized = _textBuffer.toString();
    _materializedText = materialized;
    _materializationCount += 1;
    return materialized;
  }

  /// A stable bounded prefix for compact UI projections that must not
  /// materialize a multi-megabyte streaming response on every text delta.
  @override
  String get previewText =>
      _previewTextTruncated ? '$_previewText…' : _previewText;

  set text(String value) {
    _requireActive();
    _setText(value);
  }

  void projectionSetTextForOwner(Object ownerToken, String value) {
    projectionRequireOwner(ownerToken);
    _setText(value);
  }

  void _setText(String value) {
    _textBuffer = StringBuffer(value);
    _materializedText = value;
    final preview = _boundedChatMessagePreview(value);
    _previewText = preview.text;
    _previewTextTruncated = preview.truncated;
    _acceptedUtf8Bytes = utf8.encode(value).length;
    _revision += 1;
    _retainedBytes = null;
  }

  @override
  int get revision => _revision;

  int get acceptedUtf8Bytes => _acceptedUtf8Bytes;

  int get retainedBytes {
    final cached = _retainedBytes;
    if (cached != null) return cached;
    final retained = projectionEstimateChatMessageRetainedBytes(
      metadata: metadata,
      omissions: _omissions,
      acceptedUtf8Bytes: _acceptedUtf8Bytes,
      inputBudget: _inputBudget,
    );
    _retainedBytes = retained;
    return retained;
  }

  int get materializationCount => _materializationCount;

  void appendAcceptedText(String value, {required int acceptedUtf8Bytes}) {
    _requireActive();
    _appendAcceptedText(value, acceptedUtf8Bytes: acceptedUtf8Bytes);
  }

  void projectionAppendAcceptedTextForOwner(
    Object ownerToken,
    String value, {
    required int acceptedUtf8Bytes,
  }) {
    projectionRequireOwner(ownerToken);
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
    if (!_previewTextTruncated) {
      final remaining = _chatMessagePreviewCodeUnits - _previewText.length;
      if (remaining <= 0) {
        _previewTextTruncated = true;
      } else {
        final appended = _boundedChatMessagePreview(value, limit: remaining);
        _previewText += appended.text;
        _previewTextTruncated = appended.truncated;
      }
    }
    _acceptedUtf8Bytes += acceptedUtf8Bytes;
    _revision += 1;
    _retainedBytes = null;
  }

  @override
  final DateTime timestamp;
  @override
  final Map<String, Object?> metadata;
  List<acp.ChatInputOmission> _omissions;
  final int _maxOmissions;

  @override
  List<acp.ChatInputOmission> get omissions => _omissions;

  bool addOmission(acp.ChatInputOmission omission) {
    _requireActive();
    return _addOmission(omission);
  }

  bool projectionAddOmissionForOwner(
    Object ownerToken,
    acp.ChatInputOmission omission,
  ) {
    projectionRequireOwner(ownerToken);
    return _addOmission(omission);
  }

  bool _addOmission(acp.ChatInputOmission omission) {
    if (_omissions.length >= _maxOmissions ||
        _omissions.any(
          (existing) =>
              existing.resource == omission.resource &&
              existing.reason == omission.reason,
        )) {
      return false;
    }
    _omissions = List<acp.ChatInputOmission>.unmodifiable([
      ..._omissions,
      omission,
    ]);
    _revision += 1;
    _retainedBytes = null;
    return true;
  }

  ChatMessage freeze() => _copyWithFrozenState(frozen: true);

  ChatMessage thaw() => _copyWithFrozenState(frozen: false);

  ChatMessage projectionCopyForBudget(
    acp.ChatInputBudget inputBudget, {
    required bool frozen,
    bool preserveTurnId = true,
  }) {
    inputBudget.validate();
    final materializedText = text;
    final isThought =
        role == ChatMessageRole.status && metadata['kind'] == 'thought';
    final counter = acp.ChatUtf8LineBudgetCounter(
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
    var copiedBoundedOmissions = projectionBoundedChatMessageOmissions(
      _omissions,
      textOmission,
      inputBudget.maxCollectionItems,
    );
    copiedBoundedOmissions = projectionBoundedChatMessageOmissions(
      copiedBoundedOmissions,
      guarded.omission,
      inputBudget.maxCollectionItems,
    );
    for (final omission in guarded.localOmissions) {
      copiedBoundedOmissions = projectionBoundedChatMessageOmissions(
        copiedBoundedOmissions,
        omission,
        inputBudget.maxCollectionItems,
      );
    }
    final copiedOmissions = List<acp.ChatInputOmission>.unmodifiable(
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
      turnId: preserveTurnId ? projectionTurnId : null,
    );
  }

  ChatMessage _copyWithFrozenState({required bool frozen}) {
    final copiedMetadata = _guardOwnedChatMessageMetadata(
      metadata,
      _inputBudget,
    ).metadata;
    final copiedOmissions = List<acp.ChatInputOmission>.unmodifiable(
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
      turnId: projectionTurnId,
    );
  }

  void _requireActive() {
    if (_frozen) {
      throw StateError('Frozen chat message is immutable.');
    }
    if (projectionOwnerToken != null) {
      throw StateError('Controller-owned chat message is immutable.');
    }
  }
}

const int _chatMessagePreviewCodeUnits = 4096;

({String text, bool truncated}) _boundedChatMessagePreview(
  String value, {
  int limit = _chatMessagePreviewCodeUnits,
}) {
  if (value.length <= limit) return (text: value, truncated: false);
  var end = limit;
  if (end > 0) {
    final last = value.codeUnitAt(end - 1);
    if (last >= 0xD800 && last <= 0xDBFF) end -= 1;
  }
  return (text: value.substring(0, end), truncated: true);
}

acp.ChatInputOmission _copyInputOmission(acp.ChatInputOmission omission) {
  return acp.ChatInputOmission(
    reason: omission.reason,
    resource: omission.resource,
    truncated: omission.truncated,
    limit: omission.limit,
    observedAtLeast: omission.observedAtLeast,
  );
}

int projectionEstimateChatMessageRetainedBytes({
  required Map<String, Object?> metadata,
  required List<acp.ChatInputOmission> omissions,
  required int acceptedUtf8Bytes,
  required acp.ChatInputBudget inputBudget,
}) {
  final estimator = acp.ChatRetainedSizeEstimator(budget: inputBudget);
  var retained = projectionCheckedRetainedAdd(
    _chatMessageHostRetainedBytes,
    acceptedUtf8Bytes,
  );
  retained = projectionCheckedRetainedAdd(
    retained,
    projectionEstimateChatMetadataRetainedBytes(estimator, metadata),
  );
  return projectionAddInputOmissionsRetainedBytes(
    retained,
    estimator,
    omissions,
  );
}

int projectionEstimateChatMetadataRetainedBytes(
  acp.ChatRetainedSizeEstimator estimator,
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
  final typedOptions = options.whereType<ChatConfigOption>().toList(
    growable: false,
  );
  var retained = _typedConfigMetadataHostRetainedBytes;
  return projectionAddConfigOptionsRetainedBytes(
    retained,
    estimator,
    typedOptions,
  );
}

int _estimateContentBlockMetadataRetainedBytes(
  acp.ChatRetainedSizeEstimator estimator,
  Map<String, Object?> metadata,
  List contentBlocks,
) {
  var retained = projectionAddRetainedListHostBytes(
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
      retained = projectionAddEstimatedRetainedBytes(
        retained,
        estimator,
        rawBlock,
      );
      continue;
    }
    retained = projectionCheckedRetainedAdd(
      retained,
      _contentBlockHostRetainedBytes,
    );
    if (type == 'image' || type == 'audio') {
      final mimeType = rawBlock['mimeType'];
      if (mimeType != null) {
        retained = projectionAddEstimatedRetainedBytes(
          retained,
          estimator,
          mimeType,
        );
      }
      final data = rawBlock['data'];
      if (data is String) {
        // ACP Base64 is ASCII, so encoded code units equal retained UTF-8 bytes.
        retained = projectionCheckedRetainedAdd(retained, data.length);
      }
      final uri = rawBlock['uri'];
      if (uri != null) {
        retained = projectionAddEstimatedRetainedBytes(
          retained,
          estimator,
          uri,
        );
      }
      continue;
    }
    if (type == 'resource') {
      final resource = rawBlock['resource'];
      if (resource is! Map<String, Object?>) {
        throw const FormatException('Invalid retained resource block.');
      }
      retained = projectionCheckedRetainedAdd(
        retained,
        _contentBlockHostRetainedBytes,
      );
      for (final entry in resource.entries) {
        retained = projectionCheckedRetainedAdd(
          retained,
          projectionRetainedListItemHostBytes,
        );
        retained = projectionAddEstimatedRetainedBytes(
          retained,
          estimator,
          entry.key,
        );
        if (entry.key == 'blob' && entry.value is String) {
          retained = projectionCheckedRetainedAdd(
            retained,
            (entry.value! as String).length,
          );
        } else {
          retained = projectionAddEstimatedRetainedBytes(
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
        retained = projectionCheckedRetainedAdd(
          retained,
          utf8.encode(resource).length,
        );
      }
      for (final key in const <String>['limit', 'observedAtLeast']) {
        if (rawBlock[key] != null) {
          retained = projectionAddEstimatedRetainedBytes(
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
      retained = projectionAddEstimatedRetainedBytes(
        retained,
        estimator,
        entry.value,
      );
    }
  }
  return retained;
}

int _addDynamicRetainedEntry(
  int retained,
  acp.ChatRetainedSizeEstimator estimator,
  String key,
  Object? value,
) {
  retained = projectionCheckedRetainedAdd(
    retained,
    projectionRetainedListItemHostBytes,
  );
  retained = projectionAddEstimatedRetainedBytes(retained, estimator, key);
  return projectionAddEstimatedRetainedBytes(retained, estimator, value);
}

int projectionCheckedRetainedAdd(int current, int increment) {
  if (current < 0 ||
      increment < 0 ||
      current > _maxSafeRetainedBytes - increment) {
    throw acp.ChatInputLimitExceeded(
      resource: 'chat retained state bytes',
      limit: _maxSafeRetainedBytes,
      observedAtLeast: _maxSafeRetainedBytes + 1,
    );
  }
  return current + increment;
}

int projectionAddEstimatedRetainedBytes(
  int retained,
  acp.ChatRetainedSizeEstimator estimator,
  Object? value,
) {
  return projectionCheckedRetainedAdd(retained, estimator.estimate(value));
}

int projectionAddRetainedListHostBytes(int retained, int length) {
  if (length < 0 ||
      length > _maxSafeRetainedBytes ~/ projectionRetainedListItemHostBytes) {
    throw acp.ChatInputLimitExceeded(
      resource: 'chat retained state bytes',
      limit: _maxSafeRetainedBytes,
      observedAtLeast: _maxSafeRetainedBytes + 1,
    );
  }
  retained = projectionCheckedRetainedAdd(
    retained,
    projectionRetainedListHostBytes,
  );
  return projectionCheckedRetainedAdd(
    retained,
    length * projectionRetainedListItemHostBytes,
  );
}

int projectionAddInputOmissionsRetainedBytes(
  int retained,
  acp.ChatRetainedSizeEstimator estimator,
  List<acp.ChatInputOmission> omissions,
) {
  retained = projectionAddRetainedListHostBytes(retained, omissions.length);
  for (final omission in omissions) {
    retained = projectionCheckedRetainedAdd(
      retained,
      _inputOmissionHostRetainedBytes,
    );
    // Omission resources are typed host labels. Their actual retained UTF-8
    // bytes count, but host-fixed labels must not consume the untrusted
    // maxStructuredStringBytes budget.
    retained = projectionCheckedRetainedAdd(
      retained,
      utf8.encode(omission.resource).length,
    );
    if (omission.reason == acp.ChatInputOmissionReason.inputLimit) {
      retained = projectionAddEstimatedRetainedBytes(
        retained,
        estimator,
        omission.limit,
      );
      retained = projectionAddEstimatedRetainedBytes(
        retained,
        estimator,
        omission.observedAtLeast,
      );
    }
  }
  return retained;
}

int projectionAddConfigOptionsRetainedBytes(
  int retained,
  acp.ChatRetainedSizeEstimator estimator,
  List<ChatConfigOption> options,
) {
  retained = projectionAddRetainedListHostBytes(retained, options.length);
  for (final option in options) {
    retained = projectionCheckedRetainedAdd(
      retained,
      _configOptionHostRetainedBytes,
    );
    for (final value in <Object?>[
      option.id,
      option.name,
      option.type,
      option.currentValue,
      if (option.description != null) option.description,
      if (option.category != null) option.category,
      if (option.group != null) option.group,
    ]) {
      retained = projectionAddEstimatedRetainedBytes(
        retained,
        estimator,
        value,
      );
    }
    retained = projectionAddRetainedListHostBytes(
      retained,
      option.options.length,
    );
    for (final choice in option.options) {
      retained = projectionCheckedRetainedAdd(
        retained,
        _configChoiceHostRetainedBytes,
      );
      retained = projectionAddEstimatedRetainedBytes(
        retained,
        estimator,
        choice.value,
      );
      retained = projectionAddEstimatedRetainedBytes(
        retained,
        estimator,
        choice.name,
      );
      if (choice.description != null) {
        retained = projectionAddEstimatedRetainedBytes(
          retained,
          estimator,
          choice.description,
        );
      }
    }
  }
  return retained;
}

GuardedChatMetadata projectionGuardChatMessageMetadata(
  Map<String, Object?> metadata,
  acp.ChatInputBudget budget,
) => _guardChatMessageMetadataImpl(metadata, budget);

GuardedChatMetadata _guardOwnedChatMessageMetadata(
  Map<String, Object?> metadata,
  acp.ChatInputBudget budget,
) => _guardChatMessageMetadataImpl(
  metadata,
  budget,
  preserveOwnedOmittedProjections: true,
);

GuardedChatMetadata _guardChatMessageMetadataImpl(
  Map<String, Object?> metadata,
  acp.ChatInputBudget budget, {
  bool preserveOwnedOmittedProjections = false,
}) {
  final snapshot = projectionSnapshotChatMessageMetadata(metadata, budget);
  final stableMetadata = snapshot.metadata;
  if (stableMetadata == null) return projectionInvalidChatMessageMetadata();
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
    } on acp.ChatInputLimitExceeded catch (error) {
      return _limitedChatMessageMetadata(error);
    } on Object {
      return projectionInvalidChatMessageMetadata();
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
      acp.ChatInputOmission(
        reason: acp.ChatInputOmissionReason.inputLimit,
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
    final guarded = acp.ChatStructuredUpdateGuard(
      budget: budget,
      resource: 'chat message metadata',
    ).copyMetadata(stableMetadata, field: 'metadata');
    return GuardedChatMetadata(metadata: guarded);
  } on acp.ChatInputLimitExceeded catch (error) {
    return _limitedChatMessageMetadata(error);
  } on Object {
    return projectionInvalidChatMessageMetadata();
  }
}

GuardedChatMetadata _copyContentBlockMetadata(
  Map<String, Object?> metadata,
  acp.ChatInputBudget budget, {
  bool preserveOwnedOmittedProjections = false,
}) {
  final rawBlocks = metadata['contentBlocks'];
  if (rawBlocks is! List) {
    throw const FormatException('Invalid content blocks.');
  }
  final guard = acp.ChatStructuredUpdateGuard(
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
  final localOmissions = <acp.ChatInputOmission>[];
  void addLocalOmission(acp.ChatInputOmission omission) {
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
          final blockOmission = acp.ChatInputOmission(
            reason: acp.ChatInputOmissionReason.invalidStructure,
            resource: type == 'image' ? 'image_data' : 'audio_data',
            truncated: false,
          );
          addLocalOmission(blockOmission);
          copiedBlocks.add(projectionMediaOmissionProjection(blockOmission));
          continue;
        }
        try {
          acp.scanChatBase64(
            data,
            maxDecodedBytes: budget.maxEmbeddedMediaBytes,
            resource: type == 'image' ? 'image_data' : 'audio_data',
          );
          copied['data'] = data;
        } on acp.ChatInputLimitExceeded catch (error) {
          final blockOmission = acp.ChatInputOmission(
            reason: acp.ChatInputOmissionReason.inputLimit,
            resource: type == 'image' ? 'image_data' : 'audio_data',
            truncated: false,
            limit: error.limit,
            observedAtLeast: error.observedAtLeast,
          );
          addLocalOmission(blockOmission);
          copiedBlocks.add(projectionMediaOmissionProjection(blockOmission));
          continue;
        } on FormatException {
          final blockOmission = acp.ChatInputOmission(
            reason: acp.ChatInputOmissionReason.invalidEncoding,
            resource: type == 'image' ? 'image_data' : 'audio_data',
            truncated: false,
          );
          addLocalOmission(blockOmission);
          copiedBlocks.add(projectionMediaOmissionProjection(blockOmission));
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
      final snapshot = projectionSnapshotChatMessageMetadata(
        rawResource,
        budget,
      );
      final stableResource = snapshot.metadata;
      if (stableResource == null) {
        throw const FormatException('Invalid resource content block map.');
      }
      if (snapshot.limit case final limit?) throw limit;
      guard.consumeContainerNode(field: 'resource');
      final resource = <String, Object?>{};
      acp.ChatInputOmission? blockOmission;
      for (final entry in stableResource.entries) {
        guard.consumeEntry(field: 'resource field');
        final copiedKey = guard.copyString(entry.key, field: 'resource key');
        if (copiedKey == 'blob' && entry.value != null) {
          final blob = entry.value;
          if (blob is! String) {
            blockOmission = acp.ChatInputOmission(
              reason: acp.ChatInputOmissionReason.invalidStructure,
              resource: 'resource_blob',
              truncated: false,
            );
            break;
          }
          try {
            acp.scanChatBase64(
              blob,
              maxDecodedBytes: budget.maxEmbeddedMediaBytes,
              resource: 'resource_blob',
            );
            resource[copiedKey] = blob;
          } on acp.ChatInputLimitExceeded catch (error) {
            blockOmission = acp.ChatInputOmission(
              reason: acp.ChatInputOmissionReason.inputLimit,
              resource: 'resource_blob',
              truncated: false,
              limit: error.limit,
              observedAtLeast: error.observedAtLeast,
            );
            break;
          } on FormatException {
            blockOmission = acp.ChatInputOmission(
              reason: acp.ChatInputOmissionReason.invalidEncoding,
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
        copiedBlocks.add(projectionMediaOmissionProjection(blockOmission));
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
  return GuardedChatMetadata(
    metadata: Map<String, Object?>.unmodifiable(copiedMetadata),
    localOmissions: List<acp.ChatInputOmission>.unmodifiable(localOmissions),
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

Map<String, Object?> projectionMediaOmissionProjection(
  acp.ChatInputOmission omission,
) {
  return Map<String, Object?>.unmodifiable(<String, Object?>{
    'type': 'omitted',
    'reason': switch (omission.reason) {
      acp.ChatInputOmissionReason.inputLimit => 'input_limit',
      acp.ChatInputOmissionReason.invalidEncoding => 'invalid_encoding',
      acp.ChatInputOmissionReason.invalidImage => 'invalid_image',
      acp.ChatInputOmissionReason.invalidStructure => 'invalid_structure',
    },
    'resource': omission.resource,
    'truncated': omission.truncated,
    if (omission.limit != null) 'limit': omission.limit,
    if (omission.observedAtLeast != null)
      'observedAtLeast': omission.observedAtLeast,
  });
}

int projectionValidatedAcpBase64DecodedBytes(String encoded) {
  if (encoded.isEmpty) return 0;
  var padding = 0;
  if (encoded.codeUnitAt(encoded.length - 1) == 0x3d) padding += 1;
  if (encoded.length > 1 && encoded.codeUnitAt(encoded.length - 2) == 0x3d) {
    padding += 1;
  }
  return encoded.length ~/ 4 * 3 - padding;
}

({Map<String, Object?>? metadata, acp.ChatInputLimitExceeded? limit})
projectionSnapshotChatMessageMetadata(
  Map<String, Object?> raw,
  acp.ChatInputBudget budget,
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
        ? acp.ChatInputLimitExceeded(
            resource: 'chat message metadata entries',
            limit: entryLimit,
            observedAtLeast: reportedLength,
          )
        : null,
  );
}

GuardedChatMetadata _limitedChatMessageMetadata(
  acp.ChatInputLimitExceeded error,
) => GuardedChatMetadata(
  metadata: const <String, Object?>{},
  omission: acp.ChatInputOmission(
    reason: acp.ChatInputOmissionReason.inputLimit,
    resource: 'chat message metadata',
    truncated: false,
    limit: error.limit,
    observedAtLeast: error.observedAtLeast,
  ),
);

GuardedChatMetadata projectionInvalidChatMessageMetadata() =>
    GuardedChatMetadata(
      metadata: const <String, Object?>{},
      omission: acp.ChatInputOmission(
        reason: acp.ChatInputOmissionReason.invalidStructure,
        resource: 'chat message metadata',
        truncated: false,
      ),
    );

GuardedChatMetadata? _guardRecognizedTypedConfigUpdateMetadata(
  Map<String, Object?> metadata,
  acp.ChatInputBudget budget,
) {
  if (!_isRecognizedTypedConfigUpdateMetadata(metadata)) return null;
  try {
    final copied = _copyTypedConfigUpdateMetadata(metadata, budget);
    if (copied == null) return null;
    return GuardedChatMetadata(metadata: copied);
  } on acp.ChatInputLimitExceeded catch (error) {
    return _failedTypedConfigUpdateMetadata(
      acp.ChatInputOmission(
        reason: acp.ChatInputOmissionReason.inputLimit,
        resource: 'chat message metadata',
        truncated: false,
        limit: error.limit,
        observedAtLeast: error.observedAtLeast,
      ),
    );
  } on Object {
    return _failedTypedConfigUpdateMetadata(
      acp.ChatInputOmission(
        reason: acp.ChatInputOmissionReason.invalidStructure,
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

GuardedChatMetadata _failedTypedConfigUpdateMetadata(
  acp.ChatInputOmission omission,
) => GuardedChatMetadata(
  metadata: const <String, Object?>{
    'kind': 'config_option_update',
    'configOptions': <ChatConfigOption>[],
  },
  omission: omission,
);

Map<String, Object?>? _copyTypedConfigUpdateMetadata(
  Map<String, Object?> metadata,
  acp.ChatInputBudget budget, {
  acp.ChatStructuredUpdateGuard? structuredGuard,
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
    throw acp.ChatInputLimitExceeded(
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
  } on acp.ChatInputLimitExceeded {
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
      acp.ChatStructuredUpdateGuard(
        budget: budget,
        resource: 'chat message metadata',
      );
  guard.consumeContainerNode(field: 'metadata');
  final copiedOptions = projectionCopyConfigOptionsWithGuard(
    rawOptions,
    guard,
    field: 'config options',
  );
  return Map<String, Object?>.unmodifiable(<String, Object?>{
    'kind': 'config_option_update',
    'configOptions': copiedOptions,
  });
}

List<ChatConfigOption> projectionCopyConfigOptionsWithGuard(
  Object? rawOptions,
  acp.ChatStructuredUpdateGuard guard, {
  required String field,
}) {
  if (rawOptions is! List) {
    throw const FormatException('Invalid config options collection.');
  }
  final optionCount = guard.checkCollection(rawOptions, field: field);
  guard.consumeContainerNode(field: field);
  final copiedOptions = <ChatConfigOption>[];
  for (var optionIndex = 0; optionIndex < optionCount; optionIndex += 1) {
    final Object? rawOption;
    try {
      rawOption = rawOptions[optionIndex];
    } on Object {
      throw const FormatException('Invalid chat message config option access.');
    }
    if (rawOption is! ChatConfigOption) {
      throw const FormatException('Invalid chat message config option.');
    }
    guard.consumeEntry(field: 'config option');
    final rawChoices = rawOption.options;
    final choiceCount = guard.checkCollection(
      rawChoices,
      field: 'config option choices',
    );
    guard.consumeContainerNode(field: 'config option choices');
    final copiedChoices = <ChatConfigOptionChoice>[];
    for (var choiceIndex = 0; choiceIndex < choiceCount; choiceIndex += 1) {
      final choice = rawChoices[choiceIndex];
      guard.consumeEntry(field: 'config option choice');
      copiedChoices.add(
        ChatConfigOptionChoice(
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
      ChatConfigOption(
        id: guard.copyString(rawOption.id, field: 'config option id'),
        name: guard.copyString(rawOption.name, field: 'config option name'),
        type: guard.copyString(rawOption.type, field: 'config option type'),
        currentValue: guard.copyString(
          rawOption.currentValue,
          field: 'config option current value',
        ),
        options: List<ChatConfigOptionChoice>.unmodifiable(copiedChoices),
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
  return List<ChatConfigOption>.unmodifiable(copiedOptions);
}

Map<String, Object?> projectionCopyChatMessageMetadataWithGuard(
  Map<String, Object?> metadata,
  acp.ChatInputBudget budget,
  acp.ChatStructuredUpdateGuard guard,
) {
  final snapshot = projectionSnapshotChatMessageMetadata(metadata, budget);
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

List<acp.ChatInputOmission> projectionBoundedChatMessageOmissions(
  List<acp.ChatInputOmission> trusted,
  acp.ChatInputOmission? local,
  int limit,
) {
  final bounded = <acp.ChatInputOmission>[];
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
  return List<acp.ChatInputOmission>.unmodifiable(bounded);
}
