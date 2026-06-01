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
    switch (_normalizedToken(value)) {
      case 'started':
      case 'start':
      case 'pending':
      case 'in_progress':
      case 'running':
        return DiffStatus.started;
      case 'applied':
      case 'accepted':
      case 'complete':
      case 'completed':
      case 'done':
        return DiffStatus.applied;
      case 'rejected':
      case 'reject':
      case 'declined':
        return DiffStatus.rejected;
      case 'error':
      case 'failed':
      case 'failure':
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
    type: _changeTypeFromRaw(json['type']),
    line: _lineFromRaw(
      json['line'] ?? json['lineNumber'] ?? json['line_number'],
    ),
    content: _optionalString(json['content'] ?? json['text']),
    oldContent: _optionalString(json['oldContent'] ?? json['old']),
    newContent: _optionalString(json['newContent'] ?? json['new']),
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
    final uri =
        _optionalString(json['uri']) ??
        _optionalString(json['path']) ??
        _optionalString(json['filePath']) ??
        _optionalString(json['file']);
    final changesList = _diffChangesFromRaw(json['changes'] ?? json['diff']);

    return Diff(
      id: _optionalString(json['id']) ?? uri ?? '',
      status: DiffStatus.fromWire(_optionalString(json['status'])),
      uri: uri,
      changes: changesList,
      description: _optionalString(json['description'] ?? json['title']),
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

String? _optionalString(Object? value) => value is String ? value : null;

String? _normalizedToken(String? value) {
  if (value == null) return null;
  final cleaned = value.trim();
  if (cleaned.isEmpty) return null;
  return cleaned
      .replaceAllMapped(
        RegExp(r'([a-z0-9])([A-Z])'),
        (match) => '${match.group(1)}_${match.group(2)}',
      )
      .replaceAll(RegExp(r'[\s-]+'), '_')
      .toLowerCase();
}

String _changeTypeFromRaw(Object? raw) {
  final type = _normalizedToken(_optionalString(raw));
  return switch (type) {
    'addition' ||
    'add' ||
    'added' ||
    'insert' ||
    'inserted' ||
    '+' => 'addition',
    'deletion' ||
    'delete' ||
    'deleted' ||
    'remove' ||
    'removed' ||
    '-' => 'deletion',
    'modification' ||
    'modify' ||
    'modified' ||
    'change' ||
    'changed' ||
    '~' => 'modification',
    _ => type ?? 'change',
  };
}

int? _lineFromRaw(Object? raw) {
  if (raw is num) return raw.toInt();
  if (raw is String) return int.tryParse(raw.trim());
  return null;
}

List<DiffChange> _diffChangesFromRaw(Object? raw) {
  if (raw is String) {
    return _diffChangesFromString(raw);
  }
  if (raw is! List) return const <DiffChange>[];
  return raw
      .expand((item) {
        final change = _diffChangeFromRaw(item);
        return change == null ? const <DiffChange>[] : <DiffChange>[change];
      })
      .toList(growable: false);
}

List<DiffChange> _diffChangesFromString(String raw) {
  final lines = raw.split('\n').where((line) => line.trim().isNotEmpty);
  return lines
      .map((line) {
        if (line.startsWith('+') && !line.startsWith('+++')) {
          return DiffChange(type: 'addition', content: line.substring(1));
        }
        if (line.startsWith('-') && !line.startsWith('---')) {
          return DiffChange(type: 'deletion', content: line.substring(1));
        }
        return DiffChange(type: 'change', content: line);
      })
      .toList(growable: false);
}

DiffChange? _diffChangeFromRaw(Object? raw) {
  if (raw is String) {
    final text = raw.trimRight();
    if (text.trim().isEmpty) return null;
    if (text.startsWith('+')) {
      return DiffChange(type: 'addition', content: text.substring(1));
    }
    if (text.startsWith('-')) {
      return DiffChange(type: 'deletion', content: text.substring(1));
    }
    return DiffChange(type: 'change', content: text);
  }
  if (raw is! Map) return null;
  return DiffChange.fromJson(
    raw.map((key, value) => MapEntry(key.toString(), value)),
  );
}
