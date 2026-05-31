// Diff-related types for ACP.

/// Status of a diff operation.
enum DiffStatus {
  /// Diff has been started.
  started,

  /// Diff has been applied.
  applied,

  /// Diff was rejected.
  rejected,

  /// Diff encountered an error.
  error;

  /// Parse from wire format.
  static DiffStatus fromWire(String? value) {
    switch (value) {
      case 'started':
        return DiffStatus.started;
      case 'applied':
        return DiffStatus.applied;
      case 'rejected':
        return DiffStatus.rejected;
      case 'error':
        return DiffStatus.error;
      default:
        return DiffStatus.started;
    }
  }

  /// Convert to wire format.
  String toWire() => name;
}

/// A single change in a diff.
class DiffChange {
  /// Creates a diff change.
  const DiffChange({
    required this.type,
    this.line,
    this.content,
    this.oldContent,
    this.newContent,
  });

  /// Create from JSON.
  factory DiffChange.fromJson(Map<String, dynamic> json) => DiffChange(
    type: json['type'] as String? ?? '',
    line: (json['line'] as num?)?.toInt(),
    content: json['content'] as String?,
    oldContent: json['oldContent'] as String?,
    newContent: json['newContent'] as String?,
  );

  /// Type of change (addition, deletion, modification).
  final String type;

  /// Line number where the change occurs.
  final int? line;

  /// Content of the change (for additions/deletions).
  final String? content;

  /// Old content (for modifications).
  final String? oldContent;

  /// New content (for modifications).
  final String? newContent;

  /// Convert to JSON.
  Map<String, dynamic> toJson() => {
    'type': type,
    if (line != null) 'line': line,
    if (content != null) 'content': content,
    if (oldContent != null) 'oldContent': oldContent,
    if (newContent != null) 'newContent': newContent,
  };
}

/// Diff information.
class Diff {
  /// Creates a diff.
  const Diff({
    required this.id,
    required this.status,
    this.uri,
    this.changes = const [],
    this.description,
  });

  /// Create from JSON.
  factory Diff.fromJson(Map<String, dynamic> json) {
    final changesList =
        (json['changes'] as List?)
            ?.map((c) => DiffChange.fromJson(c as Map<String, dynamic>))
            .toList() ??
        const [];

    return Diff(
      id: json['id'] as String? ?? '',
      status: DiffStatus.fromWire(json['status'] as String?),
      uri: json['uri'] as String?,
      changes: changesList,
      description: json['description'] as String?,
    );
  }

  /// Unique identifier for this diff.
  final String id;

  /// Current status of the diff.
  final DiffStatus status;

  /// URI of the file being diffed.
  final String? uri;

  /// List of changes in this diff.
  final List<DiffChange> changes;

  /// Description of the diff.
  final String? description;

  /// Convert to JSON.
  Map<String, dynamic> toJson() => {
    'id': id,
    'status': status.toWire(),
    if (uri != null) 'uri': uri,
    if (changes.isNotEmpty) 'changes': changes.map((c) => c.toJson()).toList(),
    if (description != null) 'description': description,
  };
}
