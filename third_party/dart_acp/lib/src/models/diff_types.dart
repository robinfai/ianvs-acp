// Diff-related types for ACP.

import '../input_budget.dart';

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
  factory DiffChange.fromJson(
    Map<String, dynamic> json, {
    AcpInputBudget inputBudget = const AcpInputBudget(),
    AcpStructuredUpdateGuard? structuredGuard,
  }) {
    final guard =
        structuredGuard ??
        AcpStructuredUpdateGuard(budget: inputBudget, resource: 'diff_change');
    return _diffChangeFromRaw(json, guard)!;
  }

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
    this.truncated = false,
    this.omission,
  });

  /// Create from JSON.
  factory Diff.fromJson(
    Map<String, dynamic> json, {
    AcpInputBudget inputBudget = const AcpInputBudget(),
    AcpStructuredUpdateGuard? structuredGuard,
  }) {
    final guard =
        structuredGuard ??
        AcpStructuredUpdateGuard(budget: inputBudget, resource: 'diff');
    guard.checkCollection(json, field: 'diff');
    guard.consumeEntry(field: 'diff');

    final uri = _copyOptionalAliasedString(
      json,
      const <String>['uri', 'path', 'filePath', 'file'],
      guard,
      field: 'uri',
    );
    final id =
        _copyOptionalAliasedString(
          json,
          const <String>['id'],
          guard,
          field: 'id',
        ) ??
        uri ??
        '';
    final statusValue = _copyOptionalAliasedString(
      json,
      const <String>['status'],
      guard,
      field: 'status',
    );
    final description = _copyOptionalAliasedString(
      json,
      const <String>['description', 'title'],
      guard,
      field: 'description',
    );
    final rawChanges = _firstNonNull(json, const <String>['changes', 'diff']);
    var changesList = const <DiffChange>[];
    var truncated = false;
    AcpInputOmission? omission;
    if (!identical(rawChanges, _absentDiffField)) {
      try {
        changesList = _diffChangesFromRaw(
          rawChanges,
          inputBudget: inputBudget,
          guard: guard,
        );
      } on AcpInputLimitExceeded catch (error) {
        truncated = true;
        omission = AcpInputOmission(
          reason: AcpInputOmissionReason.inputLimit,
          resource: _diffChangesResource,
          truncated: false,
          limit: error.limit,
          observedAtLeast: error.observedAtLeast,
        );
      } catch (_) {
        truncated = true;
        omission = AcpInputOmission(
          reason: AcpInputOmissionReason.invalidStructure,
          resource: _diffChangesResource,
          truncated: false,
        );
      }
    }

    return Diff(
      id: id,
      status: DiffStatus.fromWire(statusValue),
      uri: uri,
      changes: List<DiffChange>.unmodifiable(changesList),
      description: description,
      truncated: truncated,
      omission: omission,
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

  /// Whether the diff details were rejected as incomplete or unsafe.
  final bool truncated;

  /// Host-owned reason why diff details were omitted.
  final AcpInputOmission? omission;

  /// Convert to JSON.
  Map<String, dynamic> toJson() => {
    'id': id,
    'status': status.toWire(),
    if (uri != null) 'uri': uri,
    if (changes.isNotEmpty) 'changes': changes.map((c) => c.toJson()).toList(),
    if (description != null) 'description': description,
  };
}

const Object _absentDiffField = Object();
const String _diffChangesResource = 'diff_changes';

Object? _firstNonNull(Map<String, dynamic> json, List<String> fields) {
  for (final field in fields) {
    try {
      if (!json.containsKey(field)) continue;
      final value = json[field];
      if (value != null) return value;
    } catch (_) {
      throw const FormatException('Invalid ACP diff structure.');
    }
  }
  return _absentDiffField;
}

String? _copyOptionalAliasedString(
  Map<String, dynamic> json,
  List<String> fields,
  AcpStructuredUpdateGuard guard, {
  required String field,
}) {
  final value = _firstNonNull(json, fields);
  if (identical(value, _absentDiffField)) return null;
  return guard.copyString(value, field: field);
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

List<DiffChange> _diffChangesFromRaw(
  Object? raw, {
  required AcpInputBudget inputBudget,
  required AcpStructuredUpdateGuard guard,
}) {
  if (raw is String) {
    return _diffChangesFromString(raw, inputBudget: inputBudget, guard: guard);
  }
  if (raw is! List) {
    throw const FormatException('Invalid ACP diff changes structure.');
  }
  final reportedLength = guard.checkCollection(raw, field: 'changes');
  guard.consumeContainerNode(field: 'changes');
  final changes = <DiffChange>[];
  final Iterator<Object?> iterator;
  try {
    iterator = raw.iterator;
  } catch (_) {
    throw const FormatException('Invalid ACP diff changes structure.');
  }
  var observedItems = 0;
  while (true) {
    final bool hasNext;
    try {
      hasNext = iterator.moveNext();
    } catch (_) {
      throw const FormatException('Invalid ACP diff changes structure.');
    }
    if (!hasNext) break;
    observedItems += 1;
    if (observedItems > inputBudget.maxCollectionItems) {
      throw AcpInputLimitExceeded(
        resource: _diffChangesResource,
        limit: inputBudget.maxCollectionItems,
        observedAtLeast: observedItems,
      );
    }
    if (observedItems > reportedLength) {
      throw const FormatException('Invalid ACP diff changes structure.');
    }
    final Object? item;
    try {
      item = iterator.current;
    } catch (_) {
      throw const FormatException('Invalid ACP diff changes structure.');
    }
    final change = _diffChangeFromRaw(item, guard);
    if (change != null) changes.add(change);
  }
  if (observedItems != reportedLength) {
    throw const FormatException('Invalid ACP diff changes structure.');
  }
  return List<DiffChange>.unmodifiable(changes);
}

List<DiffChange> _diffChangesFromString(
  String raw, {
  required AcpInputBudget inputBudget,
  required AcpStructuredUpdateGuard guard,
}) {
  final scanner = AcpUtf8LineBudgetCounter(
    maxBytes: inputBudget.maxMetadataBytes,
    maxLines: inputBudget.maxCollectionItems,
    resource: _diffChangesResource,
  );
  final appended = scanner.append(raw);
  final finished = scanner.finish();
  final omission = appended.omission ?? finished.omission;
  if (omission != null) {
    throw AcpInputLimitExceeded(
      resource: _diffChangesResource,
      limit: omission.limit!,
      observedAtLeast: omission.observedAtLeast!,
    );
  }

  guard.consumeContainerNode(field: 'changes');
  final changes = <DiffChange>[];
  var start = 0;
  var index = 0;
  while (index < raw.length) {
    final codeUnit = raw.codeUnitAt(index);
    if (codeUnit != 0x0a && codeUnit != 0x0d) {
      index += 1;
      continue;
    }
    final line = raw.substring(start, index);
    if (codeUnit == 0x0d &&
        index + 1 < raw.length &&
        raw.codeUnitAt(index + 1) == 0x0a) {
      index += 1;
    }
    index += 1;
    start = index;
    if (line.trim().isEmpty) continue;
    final change = _diffChangeFromRaw(line, guard);
    if (change != null) changes.add(change);
  }
  final finalLine = raw.substring(start);
  if (finalLine.trim().isNotEmpty) {
    final change = _diffChangeFromRaw(finalLine, guard);
    if (change != null) changes.add(change);
  }
  return List<DiffChange>.unmodifiable(changes);
}

DiffChange? _diffChangeFromRaw(Object? raw, AcpStructuredUpdateGuard guard) {
  if (raw is String) {
    guard.consumeEntry(field: 'change');
    final bounded = guard.copyString(raw, field: 'change text');
    final text = bounded.trimRight();
    if (text.trim().isEmpty) return null;
    if (text.startsWith('+')) {
      return DiffChange(type: 'addition', content: text.substring(1));
    }
    if (text.startsWith('-')) {
      return DiffChange(type: 'deletion', content: text.substring(1));
    }
    return DiffChange(type: 'change', content: text);
  }
  if (raw is! Map) {
    throw const FormatException('Invalid ACP diff change structure.');
  }
  guard.checkCollection(raw, field: 'change');
  guard.consumeEntry(field: 'change');
  final type = _copyRequiredMapString(
    raw,
    const <String>['type'],
    guard,
    field: 'change type',
    defaultValue: 'change',
  );
  final lineRaw = _firstMapNonNull(raw, const <String>[
    'line',
    'lineNumber',
    'line_number',
  ]);
  int? line;
  if (!identical(lineRaw, _absentDiffField)) {
    if (lineRaw is int) {
      guard.copyScalar(lineRaw, field: 'change line');
      line = lineRaw;
    } else if (lineRaw is double) {
      guard.copyScalar(lineRaw, field: 'change line');
      line = lineRaw.toInt();
    } else if (lineRaw is String) {
      final bounded = guard.copyString(lineRaw, field: 'change line');
      line = int.tryParse(bounded.trim());
      if (line == null) {
        throw const FormatException('Invalid ACP diff change structure.');
      }
    } else {
      throw const FormatException('Invalid ACP diff change structure.');
    }
  }
  final content = _copyOptionalMapString(
    raw,
    const <String>['content', 'text'],
    guard,
    field: 'change content',
  );
  final oldContent = _copyOptionalMapString(
    raw,
    const <String>['oldContent', 'old'],
    guard,
    field: 'change old content',
  );
  final newContent = _copyOptionalMapString(
    raw,
    const <String>['newContent', 'new'],
    guard,
    field: 'change new content',
  );
  final metadata = _firstMapNonNull(raw, const <String>[
    '_meta',
    'metadata',
    'meta',
  ]);
  if (!identical(metadata, _absentDiffField)) {
    guard.copyMetadata(metadata, field: 'change metadata');
  }
  return DiffChange(
    type: _changeTypeFromRaw(type),
    line: line,
    content: content,
    oldContent: oldContent,
    newContent: newContent,
  );
}

Object? _firstMapNonNull(Map source, List<String> fields) {
  for (final field in fields) {
    try {
      if (!source.containsKey(field)) continue;
      final value = source[field];
      if (value != null) return value;
    } catch (_) {
      throw const FormatException('Invalid ACP diff change structure.');
    }
  }
  return _absentDiffField;
}

String? _copyOptionalMapString(
  Map source,
  List<String> fields,
  AcpStructuredUpdateGuard guard, {
  required String field,
}) {
  final value = _firstMapNonNull(source, fields);
  if (identical(value, _absentDiffField)) return null;
  return guard.copyString(value, field: field);
}

String _copyRequiredMapString(
  Map source,
  List<String> fields,
  AcpStructuredUpdateGuard guard, {
  required String field,
  required String defaultValue,
}) =>
    _copyOptionalMapString(source, fields, guard, field: field) ?? defaultValue;
