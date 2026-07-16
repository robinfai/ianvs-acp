// Tool call related types for ACP.

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

  /// Switching the agent's operating mode.
  switchMode,

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
      case 'switch_mode':
        return ToolKind.switchMode;
      default:
        return ToolKind.other;
    }
  }

  /// Convert to wire format.
  String toWire() => this == ToolKind.switchMode ? 'switch_mode' : name;
}

/// Location information for tool calls.
class ToolCallLocation {
  /// Creates a tool call location.
  const ToolCallLocation({required this.path, this.line, this.meta});

  /// Create from JSON.
  factory ToolCallLocation.fromJson(Map<String, dynamic> json) =>
      ToolCallLocation(
        path: _optionalString(json['path']) ?? '',
        line: (json['line'] as num?)?.toInt(),
        meta: _optionalMap(json['_meta']),
      );

  /// The absolute file path being accessed or modified.
  final String path;

  /// Optional line number within the file.
  final int? line;

  /// ACP extension metadata.
  final Map<String, dynamic>? meta;

  /// Convert to JSON.
  Map<String, dynamic> toJson() => {
    'path': path,
    if (line != null) 'line': line,
    if (meta != null) '_meta': meta,
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
    this.meta,
  });

  /// Create from JSON.
  factory ToolCall.fromJson(Map<String, dynamic> json) => ToolCall(
    toolCallId: _toolCallIdFromJson(json),
    status: ToolCallStatus.fromWire(_optionalString(json['status'])),
    title: _toolTitleFromJson(json),
    kind: _toolKindFromJson(json) != null
        ? ToolKind.fromWire(_toolKindFromJson(json))
        : null,
    content: _toolContentFromRaw(json['content']),
    locations: _toolLocationsFromRaw(json['locations']),
    rawInput: json['rawInput'] ?? json['raw_input'],
    rawOutput: json['rawOutput'] ?? json['raw_output'],
    meta: _optionalMap(json['_meta']),
  );

  /// Unique identifier for this tool call within the session.
  final String toolCallId;

  /// Current status of the tool call.
  final ToolCallStatus status;

  /// Human‑readable title describing what the tool is doing.
  final String? title;

  /// Category of tool being invoked.
  final ToolKind? kind;

  /// Content produced by the tool call.
  final List? content;

  /// File locations affected by this tool call.
  final List<ToolCallLocation>? locations;

  /// Raw input parameters sent to the tool.
  final dynamic rawInput;

  /// Raw output returned by the tool.
  final dynamic rawOutput;

  /// ACP extension metadata.
  final Map<String, dynamic>? meta;

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
    if (meta != null) '_meta': meta,
  };

  /// Merge fields from an update into this tool call.
  /// Only non-null fields from the update will override existing values.
  ToolCall merge(Map<String, dynamic> update) => ToolCall(
    toolCallId: toolCallId, // ID never changes
    status: update['status'] != null
        ? ToolCallStatus.fromWire(_optionalString(update['status']))
        : status,
    title: _toolTitleFromJson(update) ?? title,
    kind: _toolKindFromJson(update) != null
        ? ToolKind.fromWire(_toolKindFromJson(update))
        : kind,
    content: update['content'] != null
        ? _toolContentFromRaw(update['content']) ?? content
        : content,
    locations: update['locations'] != null
        ? _toolLocationsFromRaw(update['locations']) ?? locations
        : locations,
    rawInput: update['rawInput'] ?? update['raw_input'] ?? rawInput,
    rawOutput: update['rawOutput'] ?? update['raw_output'] ?? rawOutput,
    meta: _optionalMap(update['_meta']) ?? meta,
  );
}

String? _optionalString(Object? value) => value is String ? value : null;

Map<String, dynamic>? _optionalMap(Object? value) {
  if (value is! Map) return null;
  return value.map((key, item) => MapEntry(key.toString(), item));
}

String? _toolTitleFromJson(Map<String, dynamic> json) {
  for (final key in const ['title', 'name', 'toolName', 'tool_name']) {
    final value = _optionalString(json[key]);
    if (value != null && value.trim().isNotEmpty) return value.trim();
  }
  return null;
}

String? _toolKindFromJson(Map<String, dynamic> json) {
  for (final key in const ['kind', 'toolKind', 'tool_kind']) {
    final value = _optionalString(json[key]);
    if (value != null && value.trim().isNotEmpty) return value.trim();
  }
  return null;
}

String _toolCallIdFromJson(Map<String, dynamic> json) {
  for (final key in const [
    'toolCallId',
    'tool_call_id',
    'id',
    'callId',
    'call_id',
  ]) {
    final value = _optionalString(json[key]);
    if (value != null && value.isNotEmpty) return value;
  }
  return '';
}

List? _toolContentFromRaw(Object? raw) {
  if (raw == null) return null;
  if (raw is List) return raw;
  if (raw is String) {
    return <Map<String, dynamic>>[
      <String, dynamic>{'type': 'text', 'text': raw},
    ];
  }
  if (raw is Map) {
    return <Map<String, dynamic>>[
      raw.map((key, value) => MapEntry(key.toString(), value)),
    ];
  }
  return null;
}

List<ToolCallLocation>? _toolLocationsFromRaw(Object? raw) {
  if (raw == null) return null;
  final rawLocations = raw is List ? raw : <Object?>[raw];
  final locations = rawLocations
      .map(_toolLocationFromRaw)
      .whereType<ToolCallLocation>()
      .toList(growable: false);
  return locations.isEmpty ? null : locations;
}

ToolCallLocation? _toolLocationFromRaw(Object? raw) {
  if (raw is String) {
    final path = raw.trim();
    return path.isEmpty ? null : ToolCallLocation(path: path);
  }
  if (raw is! Map) return null;
  return ToolCallLocation.fromJson(
    raw.map((key, value) => MapEntry(key.toString(), value)),
  );
}
