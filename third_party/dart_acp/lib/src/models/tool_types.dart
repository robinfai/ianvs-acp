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
  factory ToolCallLocation.fromJson(Map<String, dynamic> json) =>
      ToolCallLocation(
        path: json['path'] as String? ?? '',
        line: (json['line'] as num?)?.toInt(),
      );

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
  });

  /// Create from JSON.
  factory ToolCall.fromJson(Map<String, dynamic> json) => ToolCall(
    toolCallId: json['toolCallId'] as String? ?? json['id'] as String? ?? '',
    status: ToolCallStatus.fromWire(json['status'] as String?),
    title: json['title'] as String?,
    kind: json['kind'] != null
        ? ToolKind.fromWire(json['kind'] as String?)
        : null,
    content: json['content'] as List?,
    locations: (json['locations'] as List?)
        ?.map((e) => ToolCallLocation.fromJson(e as Map<String, dynamic>))
        .toList(),
    rawInput: json['rawInput'] ?? json['raw_input'],
    rawOutput: json['rawOutput'] ?? json['raw_output'],
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
  ToolCall merge(Map<String, dynamic> update) => ToolCall(
    toolCallId: toolCallId, // ID never changes
    status: update['status'] != null
        ? ToolCallStatus.fromWire(update['status'] as String?)
        : status,
    title: update['title'] as String? ?? title,
    kind: update['kind'] != null
        ? ToolKind.fromWire(update['kind'] as String?)
        : kind,
    content: update['content'] as List? ?? content,
    locations: update['locations'] != null
        ? (update['locations'] as List?)
              ?.map((e) => ToolCallLocation.fromJson(e as Map<String, dynamic>))
              .toList()
        : locations,
    rawInput: update['rawInput'] ?? update['raw_input'] ?? rawInput,
    rawOutput: update['rawOutput'] ?? update['raw_output'] ?? rawOutput,
  );
}
