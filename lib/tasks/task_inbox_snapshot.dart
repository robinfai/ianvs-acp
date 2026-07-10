import 'task_record.dart';
import 'workspace_resource.dart';

class TaskInboxSnapshot {
  const TaskInboxSnapshot({
    required this.updatedAt,
    this.tasks = const <TaskRecord>[],
    this.runs = const <TaskRunRecord>[],
    this.events = const <TaskEventRecord>[],
    this.artifacts = const <ArtifactRecord>[],
    this.approvals = const <ApprovalRequestRecord>[],
    this.resources = const <WorkspaceResource>[],
  });

  static const String schema = 'ianvs-acp.task-inbox.v1';

  final DateTime updatedAt;
  final List<TaskRecord> tasks;
  final List<TaskRunRecord> runs;
  final List<TaskEventRecord> events;
  final List<ArtifactRecord> artifacts;
  final List<ApprovalRequestRecord> approvals;
  final List<WorkspaceResource> resources;

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
    List<WorkspaceResource>? resources,
  }) {
    return TaskInboxSnapshot(
      updatedAt: updatedAt ?? this.updatedAt,
      tasks: List.unmodifiable(tasks ?? this.tasks),
      runs: List.unmodifiable(runs ?? this.runs),
      events: List.unmodifiable(events ?? this.events),
      artifacts: List.unmodifiable(artifacts ?? this.artifacts),
      approvals: List.unmodifiable(approvals ?? this.approvals),
      resources: List.unmodifiable(resources ?? this.resources),
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
      resources: _dedupeById(
        _recordsFromJson(json['resources'], WorkspaceResource.fromJson),
      ),
    );
  }

  static TaskInboxSnapshot fromJsonStrict(Object? raw) {
    final json = _jsonMap(raw);
    if (json == null) {
      throw const FormatException('Task inbox snapshot must be an object.');
    }
    final schemaValue = json['schema'];
    if (schemaValue != schema) {
      throw FormatException('Unsupported task inbox schema: $schemaValue');
    }
    const supportedFields = <String>{
      'schema',
      'updated_at',
      'tasks',
      'runs',
      'events',
      'artifacts',
      'approvals',
      'resources',
    };
    final unknownFields = json.keys.where(
      (field) => !supportedFields.contains(field),
    );
    if (unknownFields.isNotEmpty) {
      throw FormatException(
        'Unsupported task inbox fields: ${unknownFields.join(', ')}',
      );
    }
    final updatedAt = _dateTimeFromJson(
      json['updated_at'] ?? json['updatedAt'],
    );
    if (updatedAt == null) {
      throw const FormatException('Task inbox updated_at is required.');
    }
    if (json['updated_at'] != updatedAt.toIso8601String()) {
      throw const FormatException(
        'Task inbox updated_at must use the canonical v1 format.',
      );
    }
    final snapshot = TaskInboxSnapshot(
      updatedAt: updatedAt,
      tasks: _recordsFromJsonStrict(
        json['tasks'],
        TaskRecord.fromJson,
        'tasks',
      ),
      runs: _recordsFromJsonStrict(
        json['runs'],
        TaskRunRecord.fromJson,
        'runs',
      ),
      events: _recordsFromJsonStrict(
        json['events'],
        TaskEventRecord.fromJson,
        'events',
      ),
      artifacts: _recordsFromJsonStrict(
        json['artifacts'],
        ArtifactRecord.fromJson,
        'artifacts',
      ),
      approvals: _recordsFromJsonStrict(
        json['approvals'],
        ApprovalRequestRecord.fromJson,
        'approvals',
      ),
      resources: _recordsFromJsonStrict(
        json['resources'],
        WorkspaceResource.fromJson,
        'resources',
        requiredField: json.containsKey('resources'),
      ),
    );
    snapshot.validateReferences();
    return snapshot;
  }

  void validateReferences() {
    final taskIds = _uniqueIds(tasks, 'task');
    _uniqueIds(runs, 'run');
    final resourceIds = _uniqueIds(resources, 'resource');
    _uniqueIds(events, 'event');
    _uniqueIds(artifacts, 'artifact');
    _uniqueIds(approvals, 'approval');

    final runsById = <String, TaskRunRecord>{
      for (final run in runs) run.id: run,
    };
    final artifactsById = <String, ArtifactRecord>{
      for (final artifact in artifacts) artifact.id: artifact,
    };
    for (final task in tasks) {
      final currentRunId = task.currentRunId;
      if (currentRunId != null) {
        final run = runsById[currentRunId];
        if (run == null || run.taskId != task.id) {
          throw FormatException(
            'Task ${task.id} references invalid current run $currentRunId.',
          );
        }
      }
      final resourceId = task.resourceId;
      if (resourceId != null && !resourceIds.contains(resourceId)) {
        throw FormatException(
          'Task ${task.id} references missing resource $resourceId.',
        );
      }
    }
    for (final run in runs) {
      if (!taskIds.contains(run.taskId)) {
        throw FormatException(
          'Run ${run.id} references missing task ${run.taskId}.',
        );
      }
    }
    for (final event in events) {
      _validateTaskRunReference(
        recordType: 'Event',
        recordId: event.id,
        taskId: event.taskId,
        runId: event.runId,
        taskIds: taskIds,
        runsById: runsById,
      );
    }
    for (final artifact in artifacts) {
      _validateTaskRunReference(
        recordType: 'Artifact',
        recordId: artifact.id,
        taskId: artifact.taskId,
        runId: artifact.runId,
        taskIds: taskIds,
        runsById: runsById,
      );
    }
    for (final approval in approvals) {
      if (!taskIds.contains(approval.taskId)) {
        throw FormatException(
          'Approval ${approval.id} references missing task '
          '${approval.taskId}.',
        );
      }
      final runId = approval.runId;
      if (runId != null) {
        final run = runsById[runId];
        if (run == null || run.taskId != approval.taskId) {
          throw FormatException(
            'Approval ${approval.id} references invalid run $runId.',
          );
        }
      }
      for (final artifactId in approval.artifactIds) {
        final artifact = artifactsById[artifactId];
        if (artifact == null ||
            artifact.taskId != approval.taskId ||
            (runId != null && artifact.runId != runId)) {
          throw FormatException(
            'Approval ${approval.id} references invalid artifact $artifactId.',
          );
        }
      }
    }
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
      'resources': resources
          .map((resource) => resource.toJson())
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

List<T> _recordsFromJsonStrict<T>(
  Object? raw,
  _RecordReader<T> read,
  String fieldName, {
  bool requiredField = true,
}) {
  if (raw == null) {
    if (!requiredField) return <T>[];
    throw FormatException('$fieldName is required.');
  }
  if (raw is! List) {
    throw FormatException('$fieldName must be a list.');
  }
  final records = <T>[];
  for (var index = 0; index < raw.length; index += 1) {
    final record = read(raw[index]);
    if (record == null) {
      throw FormatException('$fieldName[$index] is invalid.');
    }
    final rawJson = _jsonMap(raw[index]);
    final recordJson = _recordJson(record);
    final normalizedRawJson = rawJson == null
        ? null
        : _normalizeHistoricalRecord(rawJson, record);
    if (rawJson == null ||
        recordJson == null ||
        !_jsonValuesEqual(normalizedRawJson, recordJson)) {
      throw FormatException(
        '$fieldName[$index] contains unsupported or lossy values.',
      );
    }
    records.add(record);
  }
  return List.unmodifiable(records);
}

Map<String, Object?> _normalizeHistoricalRecord(
  Map<String, Object?> raw,
  Object record,
) {
  final normalized = Map<String, Object?>.of(raw);
  if (record is ArtifactRecord && !normalized.containsKey('status')) {
    normalized['status'] = ArtifactStatus.candidate.jsonValue;
  }
  return normalized;
}

Set<String> _uniqueIds(Iterable<Object?> records, String recordType) {
  final ids = <String>{};
  for (final record in records) {
    final id = _recordId(record);
    if (id == null || id.isEmpty) {
      throw FormatException('$recordType id is required.');
    }
    if (!ids.add(id)) {
      throw FormatException('Duplicate $recordType id: $id');
    }
  }
  return ids;
}

void _validateTaskRunReference({
  required String recordType,
  required String recordId,
  required String taskId,
  required String runId,
  required Set<String> taskIds,
  required Map<String, TaskRunRecord> runsById,
}) {
  if (!taskIds.contains(taskId)) {
    throw FormatException(
      '$recordType $recordId references missing task $taskId.',
    );
  }
  final run = runsById[runId];
  if (run == null || run.taskId != taskId) {
    throw FormatException(
      '$recordType $recordId references invalid run $runId.',
    );
  }
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
    WorkspaceResource(:final id) => id,
    _ => null,
  };
}

Map<String, Object?>? _recordJson(Object? record) {
  return switch (record) {
    TaskRecord value => value.toJson(),
    TaskRunRecord value => value.toJson(),
    TaskEventRecord value => value.toJson(),
    ArtifactRecord value => value.toJson(),
    ApprovalRequestRecord value => value.toJson(),
    WorkspaceResource value => value.toJson(),
    _ => null,
  };
}

bool _jsonValuesEqual(Object? left, Object? right) {
  if (left is Map && right is Map) {
    final leftJson = _jsonMap(left);
    final rightJson = _jsonMap(right);
    if (leftJson == null ||
        rightJson == null ||
        leftJson.length != rightJson.length ||
        !leftJson.keys.every(rightJson.containsKey)) {
      return false;
    }
    return leftJson.entries.every(
      (entry) => _jsonValuesEqual(entry.value, rightJson[entry.key]),
    );
  }
  if (left is List && right is List) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index += 1) {
      if (!_jsonValuesEqual(left[index], right[index])) return false;
    }
    return true;
  }
  return left == right;
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
  return DateTime.tryParse(trimmed);
}
