import 'task_center_models.dart';
import 'task_center_store.dart';

class TaskCenterAgentApi {
  TaskCenterAgentApi({required this.store});

  final TaskCenterStore store;

  static const List<String> _toolNames = <String>[
    'task_center_create_workspace',
    'task_center_list_workspaces',
    'task_center_create_task',
    'task_center_update_task',
    'task_center_move_task',
    'task_center_list_tasks',
    'task_center_delete_task',
  ];

  List<String> get toolNames => _toolNames;

  Future<Map<String, Object?>> call(
    String toolName,
    Map<String, Object?> arguments,
  ) async {
    return switch (toolName) {
      'task_center_create_workspace' => _createWorkspace(arguments),
      'task_center_list_workspaces' => _listWorkspaces(),
      'task_center_create_task' => _createTask(arguments),
      'task_center_update_task' => _updateTask(arguments),
      'task_center_move_task' => _moveTask(arguments),
      'task_center_list_tasks' => _listTasks(arguments),
      'task_center_delete_task' => _deleteTask(arguments),
      _ => throw FormatException('Unknown task center tool "$toolName".'),
    };
  }

  Future<Map<String, Object?>> _createWorkspace(
    Map<String, Object?> arguments,
  ) async {
    final workspace = await store.createWorkspace(
      title: _requiredString(arguments, 'title'),
      description: _optionalString(arguments, 'description') ?? '',
    );
    return <String, Object?>{'workspace': workspace.toAgentJson()};
  }

  Future<Map<String, Object?>> _listWorkspaces() async {
    final snapshot = await store.load();
    return <String, Object?>{
      'workspaces': snapshot.workspaces
          .map((workspace) => workspace.toAgentJson())
          .toList(growable: false),
    };
  }

  Future<Map<String, Object?>> _createTask(
    Map<String, Object?> arguments,
  ) async {
    final task = await store.createTask(
      workspaceId: _requiredString(arguments, 'workspace_id'),
      title: _requiredString(arguments, 'title'),
      description: _optionalString(arguments, 'description') ?? '',
      status: _optionalStatus(arguments, 'status') ?? TaskCenterStatus.todo,
      metadata: _metadata(arguments['metadata']),
    );
    return <String, Object?>{'task': task.toAgentJson()};
  }

  Future<Map<String, Object?>> _updateTask(
    Map<String, Object?> arguments,
  ) async {
    final task = await store.updateTask(
      workspaceId: _requiredString(arguments, 'workspace_id'),
      taskId: _requiredString(arguments, 'task_id'),
      title: _optionalString(arguments, 'title'),
      description: _optionalString(arguments, 'description'),
      status: _optionalStatus(arguments, 'status'),
      metadata: arguments.containsKey('metadata')
          ? _metadata(arguments['metadata'])
          : null,
    );
    return <String, Object?>{'task': task.toAgentJson()};
  }

  Future<Map<String, Object?>> _moveTask(Map<String, Object?> arguments) async {
    final task = await store.moveTask(
      workspaceId: _requiredString(arguments, 'workspace_id'),
      taskId: _requiredString(arguments, 'task_id'),
      status: _requiredStatus(arguments, 'status'),
      index: _optionalInt(arguments, 'index') ?? 0,
    );
    return <String, Object?>{'task': task.toAgentJson()};
  }

  Future<Map<String, Object?>> _listTasks(
    Map<String, Object?> arguments,
  ) async {
    final workspaceId = _requiredString(arguments, 'workspace_id');
    final status = _optionalStatus(arguments, 'status');
    final snapshot = await store.load();
    final workspace = snapshot.workspaces.firstWhere(
      (candidate) => candidate.id == workspaceId,
      orElse: () => throw FormatException('Unknown workspace "$workspaceId".'),
    );
    final tasks =
        workspace.tasks
            .where((task) => status == null || task.status == status)
            .toList()
          ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    return <String, Object?>{
      'workspace': workspace.toAgentJson(),
      'tasks': tasks.map((task) => task.toAgentJson()).toList(growable: false),
    };
  }

  Future<Map<String, Object?>> _deleteTask(
    Map<String, Object?> arguments,
  ) async {
    final deleted = await store.deleteTask(
      workspaceId: _requiredString(arguments, 'workspace_id'),
      taskId: _requiredString(arguments, 'task_id'),
    );
    return <String, Object?>{'deleted': deleted};
  }
}

String _requiredString(Map<String, Object?> arguments, String key) {
  final value = arguments[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('$key is required.');
  }
  return value.trim();
}

String? _optionalString(Map<String, Object?> arguments, String key) {
  final value = arguments[key];
  if (value == null) return null;
  if (value is! String) throw FormatException('$key must be a string.');
  return value.trim();
}

int? _optionalInt(Map<String, Object?> arguments, String key) {
  final value = arguments[key];
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  throw FormatException('$key must be a number.');
}

TaskCenterStatus _requiredStatus(Map<String, Object?> arguments, String key) {
  final value = _requiredString(arguments, key);
  return TaskCenterStatus.fromId(value);
}

TaskCenterStatus? _optionalStatus(Map<String, Object?> arguments, String key) {
  final value = arguments[key];
  if (value == null) return null;
  if (value is! String) throw FormatException('$key must be a string.');
  return TaskCenterStatus.fromId(value);
}

Map<String, Object?> _metadata(Object? raw) {
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
