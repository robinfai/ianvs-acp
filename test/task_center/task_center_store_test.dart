import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/task_center/task_center_models.dart';
import 'package:ianvs_acp/task_center/task_center_store.dart';

void main() {
  test('creates workspaces and tasks then reloads them from disk', () async {
    final temp = await Directory.systemTemp.createTemp('ianvs_task_center');
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/task_center.json');
    final ids = _IdSequence();
    final store = TaskCenterStore(
      path: file.path,
      now: () => DateTime.utc(2026, 6, 16, 9, 30),
      idGenerator: ids.next,
    );

    final workspace = await store.createWorkspace(
      title: 'Local launch',
      description: 'Coordinate the local task center build.',
    );
    final task = await store.createTask(
      workspaceId: workspace.id,
      title: 'Wire the kanban board',
      description: 'Use boardview for status columns.',
      status: TaskCenterStatus.todo,
    );

    expect(await file.exists(), isTrue);
    final decoded =
        jsonDecode(await file.readAsString()) as Map<String, Object?>;
    expect(decoded['version'], 1);
    expect(workspace.id, 'id-1');
    expect(task.id, 'id-2');

    final reloaded = TaskCenterStore(path: file.path);
    final snapshot = await reloaded.load();

    expect(snapshot.workspaces, hasLength(1));
    expect(snapshot.workspaces.single.title, 'Local launch');
    expect(
      snapshot.workspaces.single.tasks.single.title,
      'Wire the kanban board',
    );
    expect(
      snapshot.workspaces.single.tasks.single.status,
      TaskCenterStatus.todo,
    );
  });

  test(
    'moves tasks between status columns and keeps explicit ordering',
    () async {
      final temp = await Directory.systemTemp.createTemp('ianvs_task_center');
      addTearDown(() => temp.delete(recursive: true));
      final ids = _IdSequence();
      final store = TaskCenterStore(
        path: '${temp.path}/task_center.json',
        now: () => DateTime.utc(2026, 6, 16, 10),
        idGenerator: ids.next,
      );

      final workspace = await store.createWorkspace(title: 'Agent workspace');
      final first = await store.createTask(
        workspaceId: workspace.id,
        title: 'Create workspace API',
        status: TaskCenterStatus.todo,
      );
      final second = await store.createTask(
        workspaceId: workspace.id,
        title: 'Persist status changes',
        status: TaskCenterStatus.inProgress,
      );

      final moved = await store.moveTask(
        workspaceId: workspace.id,
        taskId: first.id,
        status: TaskCenterStatus.inProgress,
        index: 0,
      );

      expect(moved.status, TaskCenterStatus.inProgress);
      final snapshot = await store.load();
      final inProgress = snapshot.workspaces.single.tasks
          .where((task) => task.status == TaskCenterStatus.inProgress)
          .toList();

      expect(inProgress.map((task) => task.id), [first.id, second.id]);
      expect(inProgress.map((task) => task.sortOrder), [0, 1]);
    },
  );

  test('resolves default local persistence path from XDG_DATA_HOME', () {
    final path = TaskCenterStore.resolveDefaultPath(
      environment: {'XDG_DATA_HOME': '/Users/example/.local/state'},
    );

    expect(path, '/Users/example/.local/state/ianvs-acp/task_center.json');
  });
}

class _IdSequence {
  int _next = 1;

  String next() => 'id-${_next++}';
}
