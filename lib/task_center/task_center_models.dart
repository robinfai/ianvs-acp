enum TaskCenterStatus {
  todo('todo', 'To Do'),
  inProgress('in_progress', 'In Progress'),
  review('review', 'Review'),
  done('done', 'Done');

  const TaskCenterStatus(this.id, this.label);

  final String id;
  final String label;

  static TaskCenterStatus fromId(String id) {
    final normalized = id.trim().toLowerCase();
    for (final status in values) {
      if (status.id == normalized) return status;
    }
    throw FormatException('Unknown task status "$id".');
  }
}

class TaskCenterSnapshot {
  const TaskCenterSnapshot({
    this.version = 1,
    this.workspaces = const <TaskWorkspace>[],
  });

  final int version;
  final List<TaskWorkspace> workspaces;

  TaskCenterSnapshot copyWith({List<TaskWorkspace>? workspaces}) {
    return TaskCenterSnapshot(
      version: version,
      workspaces: workspaces ?? this.workspaces,
    );
  }

  factory TaskCenterSnapshot.fromJson(Map<String, dynamic> json) {
    final workspacesRaw = json['workspaces'];
    if (workspacesRaw == null) return const TaskCenterSnapshot();
    if (workspacesRaw is! List) {
      throw const FormatException('task center workspaces must be a list.');
    }
    return TaskCenterSnapshot(
      version: _intValue(json['version']) ?? 1,
      workspaces: workspacesRaw
          .map<TaskWorkspace>((item) {
            if (item is! Map) {
              throw const FormatException('workspace entries must be objects.');
            }
            return TaskWorkspace.fromJson(_jsonMap(item));
          })
          .toList(growable: false),
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'version': version,
      'workspaces': workspaces.map((workspace) => workspace.toJson()).toList(),
    };
  }
}

class TaskWorkspace {
  const TaskWorkspace({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    this.description = '',
    this.tasks = const <TaskCenterTask>[],
  });

  final String id;
  final String title;
  final String description;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<TaskCenterTask> tasks;

  TaskWorkspace copyWith({
    String? title,
    String? description,
    DateTime? updatedAt,
    List<TaskCenterTask>? tasks,
  }) {
    return TaskWorkspace(
      id: id,
      title: title ?? this.title,
      description: description ?? this.description,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      tasks: tasks ?? this.tasks,
    );
  }

  factory TaskWorkspace.fromJson(Map<String, dynamic> json) {
    final tasksRaw = json['tasks'];
    if (tasksRaw != null && tasksRaw is! List) {
      throw const FormatException('workspace tasks must be a list.');
    }
    return TaskWorkspace(
      id: _requiredString(json['id'], 'workspace.id'),
      title: _requiredString(json['title'], 'workspace.title'),
      description: _stringValue(json['description']) ?? '',
      createdAt: _dateTimeValue(json['created_at'], 'workspace.created_at'),
      updatedAt: _dateTimeValue(json['updated_at'], 'workspace.updated_at'),
      tasks: (tasksRaw ?? const <Object?>[])
          .map<TaskCenterTask>((item) {
            if (item is! Map) {
              throw const FormatException('task entries must be objects.');
            }
            return TaskCenterTask.fromJson(_jsonMap(item));
          })
          .toList(growable: false),
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'title': title,
      if (description.isNotEmpty) 'description': description,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
      'tasks': tasks.map((task) => task.toJson()).toList(),
    };
  }

  Map<String, Object?> toAgentJson() {
    return <String, Object?>{
      'id': id,
      'title': title,
      'description': description,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
      'task_count': tasks.length,
    };
  }
}

class TaskCenterTask {
  const TaskCenterTask({
    required this.id,
    required this.workspaceId,
    required this.title,
    required this.status,
    required this.sortOrder,
    required this.createdAt,
    required this.updatedAt,
    this.description = '',
    this.metadata = const <String, Object?>{},
  });

  final String id;
  final String workspaceId;
  final String title;
  final String description;
  final TaskCenterStatus status;
  final int sortOrder;
  final DateTime createdAt;
  final DateTime updatedAt;
  final Map<String, Object?> metadata;

  TaskCenterTask copyWith({
    String? title,
    String? description,
    TaskCenterStatus? status,
    int? sortOrder,
    DateTime? updatedAt,
    Map<String, Object?>? metadata,
  }) {
    return TaskCenterTask(
      id: id,
      workspaceId: workspaceId,
      title: title ?? this.title,
      description: description ?? this.description,
      status: status ?? this.status,
      sortOrder: sortOrder ?? this.sortOrder,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      metadata: metadata ?? this.metadata,
    );
  }

  factory TaskCenterTask.fromJson(Map<String, dynamic> json) {
    return TaskCenterTask(
      id: _requiredString(json['id'], 'task.id'),
      workspaceId: _requiredString(json['workspace_id'], 'task.workspace_id'),
      title: _requiredString(json['title'], 'task.title'),
      description: _stringValue(json['description']) ?? '',
      status: TaskCenterStatus.fromId(
        _requiredString(json['status'], 'task.status'),
      ),
      sortOrder: _intValue(json['sort_order']) ?? 0,
      createdAt: _dateTimeValue(json['created_at'], 'task.created_at'),
      updatedAt: _dateTimeValue(json['updated_at'], 'task.updated_at'),
      metadata: _objectMap(json['metadata']),
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'workspace_id': workspaceId,
      'title': title,
      if (description.isNotEmpty) 'description': description,
      'status': status.id,
      'sort_order': sortOrder,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
      if (metadata.isNotEmpty) 'metadata': metadata,
    };
  }

  Map<String, Object?> toAgentJson() {
    return <String, Object?>{
      'id': id,
      'workspace_id': workspaceId,
      'title': title,
      'description': description,
      'status': status.id,
      'status_label': status.label,
      'sort_order': sortOrder,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
      'metadata': metadata,
    };
  }
}

String _requiredString(Object? value, String fieldName) {
  final result = _stringValue(value);
  if (result == null) throw FormatException('$fieldName is required.');
  return result;
}

String? _stringValue(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

int? _intValue(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return null;
}

DateTime _dateTimeValue(Object? value, String fieldName) {
  final raw = _requiredString(value, fieldName);
  final parsed = DateTime.tryParse(raw);
  if (parsed == null) throw FormatException('$fieldName must be a date.');
  return parsed;
}

Map<String, dynamic> _jsonMap(Map raw) {
  final result = <String, dynamic>{};
  for (final entry in raw.entries) {
    final key = entry.key;
    if (key is! String) {
      throw const FormatException('JSON object keys must be strings.');
    }
    result[key] = entry.value;
  }
  return result;
}

Map<String, Object?> _objectMap(Object? raw) {
  if (raw == null) return const <String, Object?>{};
  if (raw is! Map) throw const FormatException('metadata must be an object.');
  final result = <String, Object?>{};
  for (final entry in raw.entries) {
    final key = entry.key;
    if (key is! String) {
      throw const FormatException('metadata keys must be strings.');
    }
    result[key] = entry.value;
  }
  return result;
}
