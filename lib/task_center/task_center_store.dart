import 'dart:convert';
import 'dart:io';

import 'task_center_models.dart';

typedef TaskCenterClock = DateTime Function();
typedef TaskCenterIdGenerator = String Function();

class TaskCenterStore {
  TaskCenterStore({
    String? path,
    TaskCenterClock? now,
    TaskCenterIdGenerator? idGenerator,
    Map<String, String>? environment,
  }) : path = path ?? resolveDefaultPath(environment: environment),
       _now = now ?? DateTime.now,
       _idGenerator = idGenerator ?? _defaultId;

  final String path;
  final TaskCenterClock _now;
  final TaskCenterIdGenerator _idGenerator;

  static String resolveDefaultPath({Map<String, String>? environment}) {
    final env = environment ?? Platform.environment;
    final explicit = env['IANVS_ACP_TASK_CENTER_PATH'];
    if (explicit != null && explicit.trim().isNotEmpty) return explicit.trim();

    final legacyExplicit = env['ACP_TASK_CENTER_PATH'];
    if (legacyExplicit != null && legacyExplicit.trim().isNotEmpty) {
      return legacyExplicit.trim();
    }

    final xdgDataHome = env['XDG_DATA_HOME'];
    if (xdgDataHome != null && xdgDataHome.trim().isNotEmpty) {
      return '${xdgDataHome.trim()}/ianvs-acp/task_center.json';
    }

    final home = env['HOME'];
    if (home == null || home.trim().isEmpty) {
      return 'task_center.json';
    }
    return '${home.trim()}/.local/share/ianvs-acp/task_center.json';
  }

  Future<TaskCenterSnapshot> load() async {
    final file = File(path);
    if (!await file.exists()) return const TaskCenterSnapshot();
    final raw = await file.readAsString();
    if (raw.trim().isEmpty) return const TaskCenterSnapshot();
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('task center root must be a JSON object.');
    }
    return TaskCenterSnapshot.fromJson(decoded);
  }

  Future<TaskWorkspace> createWorkspace({
    required String title,
    String description = '',
  }) async {
    final cleanTitle = _requiredText(title, 'title');
    final snapshot = await load();
    final now = _now().toUtc();
    final workspace = TaskWorkspace(
      id: _idGenerator(),
      title: cleanTitle,
      description: description.trim(),
      createdAt: now,
      updatedAt: now,
    );
    await _write(
      snapshot.copyWith(workspaces: [...snapshot.workspaces, workspace]),
    );
    return workspace;
  }

  Future<TaskCenterTask> createTask({
    required String workspaceId,
    required String title,
    String description = '',
    TaskCenterStatus status = TaskCenterStatus.todo,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) async {
    final cleanTitle = _requiredText(title, 'title');
    final snapshot = await load();
    final workspace = _workspaceById(snapshot, workspaceId);
    final sortOrder = workspace.tasks
        .where((task) => task.status == status)
        .length;
    final now = _now().toUtc();
    final task = TaskCenterTask(
      id: _idGenerator(),
      workspaceId: workspace.id,
      title: cleanTitle,
      description: description.trim(),
      status: status,
      sortOrder: sortOrder,
      createdAt: now,
      updatedAt: now,
      metadata: Map<String, Object?>.unmodifiable(metadata),
    );
    final nextWorkspace = workspace.copyWith(
      updatedAt: now,
      tasks: _normalizeOrders([...workspace.tasks, task]),
    );
    await _write(_replaceWorkspace(snapshot, nextWorkspace));
    return task;
  }

  Future<TaskCenterTask> updateTask({
    required String workspaceId,
    required String taskId,
    String? title,
    String? description,
    TaskCenterStatus? status,
    Map<String, Object?>? metadata,
  }) async {
    final snapshot = await load();
    final workspace = _workspaceById(snapshot, workspaceId);
    final task = _taskById(workspace, taskId);
    final now = _now().toUtc();
    var updated = task.copyWith(
      title: title == null ? null : _requiredText(title, 'title'),
      description: description?.trim(),
      status: status,
      updatedAt: now,
      metadata: metadata == null
          ? null
          : Map<String, Object?>.unmodifiable(metadata),
    );
    if (status != null && status != task.status) {
      final targetIndex = workspace.tasks
          .where((candidate) => candidate.status == status)
          .length;
      updated = updated.copyWith(sortOrder: targetIndex);
    }
    final tasks = workspace.tasks
        .map((candidate) => candidate.id == taskId ? updated : candidate)
        .toList();
    final nextWorkspace = workspace.copyWith(
      updatedAt: now,
      tasks: _normalizeOrders(tasks),
    );
    await _write(_replaceWorkspace(snapshot, nextWorkspace));
    return nextWorkspace.tasks.firstWhere(
      (candidate) => candidate.id == taskId,
    );
  }

  Future<TaskCenterTask> moveTask({
    required String workspaceId,
    required String taskId,
    required TaskCenterStatus status,
    required int index,
  }) async {
    final snapshot = await load();
    final workspace = _workspaceById(snapshot, workspaceId);
    final task = _taskById(workspace, taskId);
    final now = _now().toUtc();
    final targetTasks =
        workspace.tasks
            .where(
              (candidate) =>
                  candidate.status == status && candidate.id != taskId,
            )
            .toList()
          ..sort(_compareTaskOrder);
    final clampedIndex = index.clamp(0, targetTasks.length).toInt();
    final moved = task.copyWith(
      status: status,
      sortOrder: clampedIndex,
      updatedAt: now,
    );
    targetTasks.insert(clampedIndex, moved);

    final remaining = workspace.tasks
        .where(
          (candidate) => candidate.status != status && candidate.id != taskId,
        )
        .toList();
    final nextWorkspace = workspace.copyWith(
      updatedAt: now,
      tasks: _normalizeOrders([...remaining, ...targetTasks]),
    );
    await _write(_replaceWorkspace(snapshot, nextWorkspace));
    return nextWorkspace.tasks.firstWhere(
      (candidate) => candidate.id == taskId,
    );
  }

  Future<bool> deleteTask({
    required String workspaceId,
    required String taskId,
  }) async {
    final snapshot = await load();
    final workspace = _workspaceById(snapshot, workspaceId);
    final tasks = workspace.tasks
        .where((candidate) => candidate.id != taskId)
        .toList();
    if (tasks.length == workspace.tasks.length) return false;
    final nextWorkspace = workspace.copyWith(
      updatedAt: _now().toUtc(),
      tasks: _normalizeOrders(tasks),
    );
    await _write(_replaceWorkspace(snapshot, nextWorkspace));
    return true;
  }

  Future<void> _write(TaskCenterSnapshot snapshot) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    const encoder = JsonEncoder.withIndent('  ');
    await file.writeAsString('${encoder.convert(snapshot.toJson())}\n');
  }

  TaskWorkspace _workspaceById(
    TaskCenterSnapshot snapshot,
    String workspaceId,
  ) {
    final cleanId = _requiredText(workspaceId, 'workspace_id');
    for (final workspace in snapshot.workspaces) {
      if (workspace.id == cleanId) return workspace;
    }
    throw FormatException('Unknown workspace "$workspaceId".');
  }

  TaskCenterTask _taskById(TaskWorkspace workspace, String taskId) {
    final cleanId = _requiredText(taskId, 'task_id');
    for (final task in workspace.tasks) {
      if (task.id == cleanId) return task;
    }
    throw FormatException('Unknown task "$taskId".');
  }

  TaskCenterSnapshot _replaceWorkspace(
    TaskCenterSnapshot snapshot,
    TaskWorkspace workspace,
  ) {
    return snapshot.copyWith(
      workspaces: snapshot.workspaces
          .map(
            (candidate) => candidate.id == workspace.id ? workspace : candidate,
          )
          .toList(growable: false),
    );
  }
}

List<TaskCenterTask> _normalizeOrders(List<TaskCenterTask> tasks) {
  final result = <TaskCenterTask>[];
  for (final status in TaskCenterStatus.values) {
    final group = tasks.where((task) => task.status == status).toList()
      ..sort(_compareTaskOrder);
    for (var index = 0; index < group.length; index++) {
      result.add(group[index].copyWith(sortOrder: index));
    }
  }
  return result;
}

int _compareTaskOrder(TaskCenterTask a, TaskCenterTask b) {
  final order = a.sortOrder.compareTo(b.sortOrder);
  if (order != 0) return order;
  return a.createdAt.compareTo(b.createdAt);
}

String _requiredText(String value, String fieldName) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) throw FormatException('$fieldName is required.');
  return trimmed;
}

String _defaultId() {
  return DateTime.now().toUtc().microsecondsSinceEpoch.toRadixString(36);
}
