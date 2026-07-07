import 'task_record.dart';

class TaskInboxSnapshot {
  const TaskInboxSnapshot({
    required this.updatedAt,
    this.tasks = const <TaskRecord>[],
    this.runs = const <TaskRunRecord>[],
    this.events = const <TaskEventRecord>[],
    this.artifacts = const <ArtifactRecord>[],
    this.approvals = const <ApprovalRequestRecord>[],
  });

  static const String schema = 'ianvs-acp.task-inbox.v1';

  final DateTime updatedAt;
  final List<TaskRecord> tasks;
  final List<TaskRunRecord> runs;
  final List<TaskEventRecord> events;
  final List<ArtifactRecord> artifacts;
  final List<ApprovalRequestRecord> approvals;

  factory TaskInboxSnapshot.empty({DateTime? updatedAt}) {
    return TaskInboxSnapshot(updatedAt: updatedAt ?? DateTime.now());
  }

  TaskInboxSnapshot copyWith({
    DateTime? updatedAt,
    List<TaskRecord>? tasks,
    List<TaskRunRecord>? runs,
    List<TaskEventRecord>? events,
    List<ArtifactRecord>? artifacts,
    List<ApprovalRequestRecord>? approvals,
  }) {
    return TaskInboxSnapshot(
      updatedAt: updatedAt ?? this.updatedAt,
      tasks: List.unmodifiable(tasks ?? this.tasks),
      runs: List.unmodifiable(runs ?? this.runs),
      events: List.unmodifiable(events ?? this.events),
      artifacts: List.unmodifiable(artifacts ?? this.artifacts),
      approvals: List.unmodifiable(approvals ?? this.approvals),
    );
  }

  static TaskInboxSnapshot fromJson(Object? raw) {
    final json = _jsonMap(raw);
    if (json == null) return TaskInboxSnapshot.empty();
    return TaskInboxSnapshot(
      updatedAt:
          _dateTimeFromJson(json['updated_at'] ?? json['updatedAt']) ??
          DateTime.now(),
      tasks: _dedupeById(_recordsFromJson(json['tasks'], TaskRecord.fromJson)),
      runs: _dedupeById(_recordsFromJson(json['runs'], TaskRunRecord.fromJson)),
      events: _dedupeById(
        _recordsFromJson(json['events'], TaskEventRecord.fromJson),
      ),
      artifacts: _dedupeById(
        _recordsFromJson(json['artifacts'], ArtifactRecord.fromJson),
      ),
      approvals: _dedupeById(
        _recordsFromJson(json['approvals'], ApprovalRequestRecord.fromJson),
      ),
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'schema': schema,
      'updated_at': updatedAt.toIso8601String(),
      'tasks': tasks.map((task) => task.toJson()).toList(growable: false),
      'runs': runs.map((run) => run.toJson()).toList(growable: false),
      'events': events.map((event) => event.toJson()).toList(growable: false),
      'artifacts': artifacts
          .map((artifact) => artifact.toJson())
          .toList(growable: false),
      'approvals': approvals
          .map((approval) => approval.toJson())
          .toList(growable: false),
    };
  }
}

typedef _RecordReader<T> = T? Function(Object? raw);

List<T> _recordsFromJson<T>(Object? raw, _RecordReader<T> read) {
  if (raw is! List) return <T>[];
  final records = <T>[];
  for (final item in raw) {
    final record = read(item);
    if (record != null) records.add(record);
  }
  return List.unmodifiable(records);
}

List<T> _dedupeById<T>(List<T> records) {
  final byId = <String, T>{};
  for (final record in records) {
    final id = _recordId(record);
    if (id == null || id.isEmpty) continue;
    byId[id] = record;
  }
  return List.unmodifiable(byId.values);
}

String? _recordId(Object? record) {
  return switch (record) {
    TaskRecord(:final id) => id,
    TaskRunRecord(:final id) => id,
    TaskEventRecord(:final id) => id,
    ArtifactRecord(:final id) => id,
    ApprovalRequestRecord(:final id) => id,
    _ => null,
  };
}

Map<String, Object?>? _jsonMap(Object? raw) {
  if (raw is! Map) return null;
  return <String, Object?>{
    for (final entry in raw.entries)
      if (entry.key is String) entry.key as String: entry.value,
  };
}

DateTime? _dateTimeFromJson(Object? raw) {
  if (raw is! String) return null;
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  return DateTime.tryParse(trimmed)?.toLocal();
}
