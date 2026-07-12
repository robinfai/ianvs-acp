// Tool call related types for ACP.

import '../input_budget.dart';

/// Tool call status per latest ACP specification.
enum ToolCallStatus {
  /// Tool call hasn't started running yet (input streaming or awaiting
  /// approval).
  pending,

  /// Tool call is currently running.
  inProgress,

  /// Tool call completed successfully.
  completed,

  /// Tool call failed with an error.
  failed,

  /// Tool call was cancelled.
  cancelled;

  /// Parse from wire format.
  static ToolCallStatus fromWire(String? value) {
    switch (value) {
      case 'pending':
        return ToolCallStatus.pending;
      case 'in_progress':
        return ToolCallStatus.inProgress;
      case 'completed':
        return ToolCallStatus.completed;
      case 'failed':
        return ToolCallStatus.failed;
      case 'cancelled':
        return ToolCallStatus.cancelled;
      // Legacy status mappings for backward compatibility
      case 'started':
        return ToolCallStatus.pending;
      case 'progress':
        return ToolCallStatus.inProgress;
      case 'error':
        return ToolCallStatus.failed;
      default:
        return ToolCallStatus.failed;
    }
  }

  /// Convert to wire format.
  String toWire() {
    switch (this) {
      case ToolCallStatus.inProgress:
        return 'in_progress';
      case ToolCallStatus.pending:
      case ToolCallStatus.completed:
      case ToolCallStatus.failed:
      case ToolCallStatus.cancelled:
        return name;
    }
  }
}

/// Tool kinds supported by ACP specification.
enum ToolKind {
  /// Reading files or data.
  read,

  /// Modifying files or content.
  edit,

  /// Removing files or data.
  delete,

  /// Moving or renaming files.
  move,

  /// Searching for information.
  search,

  /// Running commands or code.
  execute,

  /// Internal reasoning or planning.
  think,

  /// Retrieving external data.
  fetch,

  /// Other tool types (default).
  other;

  /// Parse from wire format.
  static ToolKind fromWire(String? value) {
    switch (value) {
      case 'read':
        return ToolKind.read;
      case 'edit':
        return ToolKind.edit;
      case 'delete':
        return ToolKind.delete;
      case 'move':
        return ToolKind.move;
      case 'search':
        return ToolKind.search;
      case 'execute':
        return ToolKind.execute;
      case 'think':
        return ToolKind.think;
      case 'fetch':
        return ToolKind.fetch;
      default:
        return ToolKind.other;
    }
  }

  /// Convert to wire format.
  String toWire() => name;
}

/// Location information for tool calls.
class ToolCallLocation {
  /// Creates a tool call location.
  const ToolCallLocation({required this.path, this.line});

  /// Create from JSON.
  factory ToolCallLocation.fromJson(
    Map<String, dynamic> json, {
    AcpInputBudget inputBudget = const AcpInputBudget(),
    AcpStructuredUpdateGuard? structuredGuard,
  }) {
    final guard =
        structuredGuard ??
        AcpStructuredUpdateGuard(
          budget: inputBudget,
          resource: 'tool_call_location',
        );
    guard.checkCollection(json, field: 'tool location');
    guard.consumeEntry(field: 'tool location');
    final path =
        _boundedOptionalToolString(
          json,
          const <String>['path'],
          guard,
          field: 'tool location path',
        ) ??
        '';
    if (path.isEmpty) {
      throw const FormatException('Invalid ACP tool location.');
    }
    final rawLine = _firstToolValue(json, const <String>['line']);
    int? line;
    if (!identical(rawLine, _absentToolField)) {
      final copied = guard.copyScalar(rawLine, field: 'tool location line');
      if (copied is int) {
        line = copied;
      } else if (copied is double) {
        line = copied.toInt();
      } else {
        throw const FormatException('Invalid ACP tool location line.');
      }
    }
    return ToolCallLocation(path: path, line: line);
  }

  /// The absolute file path being accessed or modified.
  final String path;

  /// Optional line number within the file.
  final int? line;

  /// Convert to JSON.
  Map<String, dynamic> toJson() => {
    'path': path,
    if (line != null) 'line': line,
  };
}

/// Tool call information per latest ACP specification.
class ToolCall {
  /// Creates a tool call.
  const ToolCall({
    required this.toolCallId,
    required this.status,
    this.title,
    this.kind,
    this.content,
    this.locations,
    this.rawInput,
    this.rawOutput,
    this.omission,
  });

  /// Create from JSON.
  factory ToolCall.fromJson(
    Map<String, dynamic> json, {
    AcpInputBudget inputBudget = const AcpInputBudget(),
    AcpStructuredUpdateGuard? structuredGuard,
  }) {
    final guard =
        structuredGuard ??
        AcpStructuredUpdateGuard(budget: inputBudget, resource: 'tool_call');
    guard.checkCollection(json, field: 'tool call');
    guard.consumeEntry(field: 'tool call');
    final toolCallId = _boundedToolCallId(json, guard);
    final status = ToolCallStatus.fromWire(
      _boundedOptionalToolString(
        json,
        const <String>['status'],
        guard,
        field: 'tool status',
      ),
    );
    final title = _boundedToolTitle(json, guard);
    final rawKind = _boundedOptionalToolString(
      json,
      const <String>['kind', 'toolKind', 'tool_kind'],
      guard,
      field: 'tool kind',
    );
    final kind = rawKind == null ? null : ToolKind.fromWire(rawKind.trim());

    try {
      final behavior = _boundedToolBehavior(json, inputBudget, guard);
      return ToolCall(
        toolCallId: toolCallId,
        status: status,
        title: title,
        kind: kind,
        content: behavior.content,
        locations: behavior.locations,
        rawInput: behavior.rawInput,
        rawOutput: behavior.rawOutput,
      );
    } on AcpInputLimitExceeded catch (error) {
      return ToolCall(
        toolCallId: toolCallId,
        status: status,
        title: title,
        kind: kind,
        omission: AcpInputOmission(
          reason: AcpInputOmissionReason.inputLimit,
          resource: 'tool_behavior',
          truncated: false,
          limit: error.limit,
          observedAtLeast: error.observedAtLeast,
        ),
      );
    } catch (_) {
      return ToolCall(
        toolCallId: toolCallId,
        status: status,
        title: title,
        kind: kind,
        omission: AcpInputOmission(
          reason: AcpInputOmissionReason.invalidStructure,
          resource: 'tool_behavior',
          truncated: false,
        ),
      );
    }
  }

  /// Unique identifier for this tool call within the session.
  final String toolCallId;

  /// Current status of the tool call.
  final ToolCallStatus status;

  /// Human‑readable title describing what the tool is doing.
  final String? title;

  /// Category of tool being invoked.
  final ToolKind? kind;

  /// Content produced by the tool call.
  final List<Object?>? content;

  /// File locations affected by this tool call.
  final List<ToolCallLocation>? locations;

  /// Raw input parameters sent to the tool.
  final dynamic rawInput;

  /// Raw output returned by the tool.
  final dynamic rawOutput;

  /// Host-owned reason why all behavior fields were rejected.
  final AcpInputOmission? omission;

  /// Convert to JSON.
  Map<String, dynamic> toJson() => {
    'toolCallId': toolCallId,
    'status': status.toWire(),
    if (title != null) 'title': title,
    if (kind != null) 'kind': kind!.toWire(),
    if (content != null) 'content': content,
    if (locations != null)
      'locations': locations!.map((l) => l.toJson()).toList(),
    if (rawInput != null) 'rawInput': rawInput,
    if (rawOutput != null) 'rawOutput': rawOutput,
  };

  /// Merge fields from an update into this tool call.
  /// Only non-null fields from the update will override existing values.
  ToolCall merge(
    Map<String, dynamic> update, {
    AcpInputBudget inputBudget = const AcpInputBudget(),
    AcpStructuredUpdateGuard? structuredGuard,
  }) {
    final guard =
        structuredGuard ??
        AcpStructuredUpdateGuard(
          budget: inputBudget,
          resource: 'tool_call_update',
        );
    guard.checkCollection(update, field: 'tool call update');
    guard.consumeEntry(field: 'tool call update');
    final rawStatus = _firstToolValue(update, const <String>['status']);
    final nextStatus = identical(rawStatus, _absentToolField)
        ? status
        : ToolCallStatus.fromWire(
            guard.copyString(rawStatus, field: 'tool status'),
          );
    final rawTitle = _firstToolValue(update, const <String>[
      'title',
      'name',
      'toolName',
      'tool_name',
    ]);
    final nextTitle = identical(rawTitle, _absentToolField)
        ? title
        : _trimmedOptionalToolString(
            guard.copyString(rawTitle, field: 'tool title'),
          );
    final rawKind = _firstToolValue(update, const <String>[
      'kind',
      'toolKind',
      'tool_kind',
    ]);
    final nextKind = identical(rawKind, _absentToolField)
        ? kind
        : ToolKind.fromWire(
            guard.copyString(rawKind, field: 'tool kind').trim(),
          );
    final hasBehaviorUpdate = _hasToolBehaviorUpdate(update);
    if (!hasBehaviorUpdate) {
      return ToolCall(
        toolCallId: toolCallId,
        status: nextStatus,
        title: nextTitle,
        kind: nextKind,
        content: content,
        locations: locations,
        rawInput: rawInput,
        rawOutput: rawOutput,
        omission: omission,
      );
    }
    try {
      final behavior = _boundedMergedToolBehavior(
        update,
        inputBudget,
        guard,
        existing: this,
      );
      return ToolCall(
        toolCallId: toolCallId,
        status: nextStatus,
        title: nextTitle,
        kind: nextKind,
        content: behavior.content,
        locations: behavior.locations,
        rawInput: behavior.rawInput,
        rawOutput: behavior.rawOutput,
      );
    } on AcpInputLimitExceeded catch (error) {
      return ToolCall(
        toolCallId: toolCallId,
        status: nextStatus,
        title: nextTitle,
        kind: nextKind,
        omission: AcpInputOmission(
          reason: AcpInputOmissionReason.inputLimit,
          resource: 'tool_behavior',
          truncated: false,
          limit: error.limit,
          observedAtLeast: error.observedAtLeast,
        ),
      );
    } catch (_) {
      return ToolCall(
        toolCallId: toolCallId,
        status: nextStatus,
        title: nextTitle,
        kind: nextKind,
        omission: AcpInputOmission(
          reason: AcpInputOmissionReason.invalidStructure,
          resource: 'tool_behavior',
          truncated: false,
        ),
      );
    }
  }
}

const Object _absentToolField = Object();

Object? _firstToolValue(Map source, List<String> fields) {
  for (final field in fields) {
    try {
      if (!source.containsKey(field)) continue;
      final value = source[field];
      if (value != null) return value;
    } catch (_) {
      throw const FormatException('Invalid ACP tool call structure.');
    }
  }
  return _absentToolField;
}

String? _boundedOptionalToolString(
  Map source,
  List<String> fields,
  AcpStructuredUpdateGuard guard, {
  required String field,
}) {
  final value = _firstToolValue(source, fields);
  if (identical(value, _absentToolField)) return null;
  return guard.copyString(value, field: field);
}

String _boundedToolCallId(
  Map<String, dynamic> json,
  AcpStructuredUpdateGuard guard,
) =>
    _boundedOptionalToolString(
      json,
      const <String>['toolCallId', 'tool_call_id', 'id', 'callId', 'call_id'],
      guard,
      field: 'tool call id',
    ) ??
    '';

String? _boundedToolTitle(
  Map<String, dynamic> json,
  AcpStructuredUpdateGuard guard,
) {
  final title = _boundedOptionalToolString(
    json,
    const <String>['title', 'name', 'toolName', 'tool_name'],
    guard,
    field: 'tool title',
  );
  return title == null ? null : _trimmedOptionalToolString(title);
}

String? _trimmedOptionalToolString(String value) {
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

({
  List<Object?>? content,
  List<ToolCallLocation>? locations,
  Object? rawInput,
  Object? rawOutput,
})
_boundedToolBehavior(
  Map<String, dynamic> json,
  AcpInputBudget inputBudget,
  AcpStructuredUpdateGuard guard,
) {
  final rawContent = _firstToolValue(json, const <String>['content']);
  final rawLocations = _firstToolValue(json, const <String>['locations']);
  final rawInput = _firstToolValue(json, const <String>[
    'rawInput',
    'raw_input',
  ]);
  final rawOutput = _firstToolValue(json, const <String>[
    'rawOutput',
    'raw_output',
  ]);
  return (
    content: identical(rawContent, _absentToolField)
        ? null
        : _boundedToolContent(rawContent, guard),
    locations: identical(rawLocations, _absentToolField)
        ? null
        : _boundedToolLocations(rawLocations, inputBudget, guard),
    rawInput: identical(rawInput, _absentToolField)
        ? null
        : _boundedToolJsonValue(rawInput, guard, field: 'tool raw input'),
    rawOutput: identical(rawOutput, _absentToolField)
        ? null
        : _boundedToolJsonValue(rawOutput, guard, field: 'tool raw output'),
  );
}

bool _hasToolBehaviorUpdate(Map<String, dynamic> update) {
  for (final fields in const <List<String>>[
    <String>['content'],
    <String>['locations'],
    <String>['rawInput', 'raw_input'],
    <String>['rawOutput', 'raw_output'],
  ]) {
    if (!identical(_firstToolValue(update, fields), _absentToolField)) {
      return true;
    }
  }
  return false;
}

({
  List<Object?>? content,
  List<ToolCallLocation>? locations,
  Object? rawInput,
  Object? rawOutput,
})
_boundedMergedToolBehavior(
  Map<String, dynamic> update,
  AcpInputBudget inputBudget,
  AcpStructuredUpdateGuard guard, {
  required ToolCall existing,
}) {
  final rawContent = _firstToolValue(update, const <String>['content']);
  final rawLocations = _firstToolValue(update, const <String>['locations']);
  final rawInput = _firstToolValue(update, const <String>[
    'rawInput',
    'raw_input',
  ]);
  final rawOutput = _firstToolValue(update, const <String>[
    'rawOutput',
    'raw_output',
  ]);
  return (
    content: identical(rawContent, _absentToolField)
        ? existing.content
        : _boundedToolContent(rawContent, guard),
    locations: identical(rawLocations, _absentToolField)
        ? existing.locations
        : _boundedToolLocations(rawLocations, inputBudget, guard),
    rawInput: identical(rawInput, _absentToolField)
        ? existing.rawInput
        : _boundedToolJsonValue(rawInput, guard, field: 'tool raw input'),
    rawOutput: identical(rawOutput, _absentToolField)
        ? existing.rawOutput
        : _boundedToolJsonValue(rawOutput, guard, field: 'tool raw output'),
  );
}

List<Object?> _boundedToolContent(Object? raw, AcpStructuredUpdateGuard guard) {
  if (raw is String) {
    final text = guard.copyString(raw, field: 'tool content text');
    return List<Object?>.unmodifiable(<Object?>[
      Map<String, Object?>.unmodifiable(<String, Object?>{
        'type': 'text',
        'text': text,
      }),
    ]);
  }
  if (raw is Map) {
    return List<Object?>.unmodifiable(<Object?>[
      Map<String, Object?>.unmodifiable(
        guard.copyMetadata(raw, field: 'tool content'),
      ),
    ]);
  }
  if (raw is! List) {
    throw const FormatException('Invalid ACP tool content.');
  }
  final copied = guard.copyJsonValue(raw, field: 'tool content');
  if (copied is! List<Object?>) {
    throw const FormatException('Invalid ACP tool content.');
  }
  return copied;
}

List<ToolCallLocation>? _boundedToolLocations(
  Object? raw,
  AcpInputBudget inputBudget,
  AcpStructuredUpdateGuard guard,
) {
  final List rawLocations;
  if (raw is List) {
    rawLocations = raw;
  } else if (raw is String || raw is Map) {
    rawLocations = <Object?>[raw];
  } else {
    throw const FormatException('Invalid ACP tool locations.');
  }
  final reportedLength = guard.checkCollection(
    rawLocations,
    field: 'tool locations',
  );
  guard.consumeContainerNode(field: 'tool locations');
  final locations = <ToolCallLocation>[];
  final Iterator<Object?> iterator;
  try {
    iterator = rawLocations.iterator;
  } catch (_) {
    throw const FormatException('Invalid ACP tool locations.');
  }
  var observedItems = 0;
  while (true) {
    final bool hasNext;
    try {
      hasNext = iterator.moveNext();
    } catch (_) {
      throw const FormatException('Invalid ACP tool locations.');
    }
    if (!hasNext) break;
    observedItems += 1;
    if (observedItems > inputBudget.maxCollectionItems) {
      throw AcpInputLimitExceeded(
        resource: 'tool locations',
        limit: inputBudget.maxCollectionItems,
        observedAtLeast: observedItems,
      );
    }
    if (observedItems > reportedLength) {
      throw const FormatException('Invalid ACP tool locations.');
    }
    final Object? item;
    try {
      item = iterator.current;
    } catch (_) {
      throw const FormatException('Invalid ACP tool locations.');
    }
    if (item is String) {
      guard.consumeEntry(field: 'tool location');
      final path = guard.copyString(item, field: 'tool location path').trim();
      if (path.isEmpty) {
        throw const FormatException('Invalid ACP tool location.');
      }
      locations.add(ToolCallLocation(path: path));
      continue;
    }
    if (item is! Map) {
      throw const FormatException('Invalid ACP tool location.');
    }
    guard.checkCollection(item, field: 'tool location');
    guard.consumeEntry(field: 'tool location');
    final path =
        _boundedOptionalToolString(
          item,
          const <String>['path'],
          guard,
          field: 'tool location path',
        ) ??
        '';
    if (path.isEmpty) {
      throw const FormatException('Invalid ACP tool location.');
    }
    final rawLine = _firstToolValue(item, const <String>['line']);
    int? line;
    if (!identical(rawLine, _absentToolField)) {
      final copied = guard.copyScalar(rawLine, field: 'tool location line');
      if (copied is int) {
        line = copied;
      } else if (copied is double) {
        line = copied.toInt();
      } else {
        throw const FormatException('Invalid ACP tool location line.');
      }
    }
    locations.add(ToolCallLocation(path: path, line: line));
  }
  if (observedItems != reportedLength) {
    throw const FormatException('Invalid ACP tool locations.');
  }
  return locations.isEmpty
      ? null
      : List<ToolCallLocation>.unmodifiable(locations);
}

Object? _boundedToolJsonValue(
  Object? raw,
  AcpStructuredUpdateGuard guard, {
  required String field,
}) {
  if (raw is Map) return guard.copyMetadata(raw, field: field);
  if (raw is List) return guard.copyJsonValue(raw, field: field);
  if (raw is String) return guard.copyString(raw, field: field);
  return guard.copyScalar(raw, field: field);
}
