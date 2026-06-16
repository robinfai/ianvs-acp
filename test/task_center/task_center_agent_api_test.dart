import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/task_center/task_center_agent_api.dart';
import 'package:ianvs_acp/task_center/task_center_store.dart';

void main() {
  test('agent API creates workspace and maintains task status', () async {
    final temp = await Directory.systemTemp.createTemp('ianvs_task_center_api');
    addTearDown(() => temp.delete(recursive: true));
    final ids = _IdSequence();
    final store = TaskCenterStore(
      path: '${temp.path}/task_center.json',
      now: () => DateTime.utc(2026, 6, 16, 11),
      idGenerator: ids.next,
    );
    final api = TaskCenterAgentApi(store: store);

    final createdWorkspace = await api.call('task_center_create_workspace', {
      'title': 'Agent managed workspace',
    });
    final workspace = createdWorkspace['workspace'] as Map<String, Object?>;
    expect(workspace['id'], 'id-1');

    final createdTask = await api.call('task_center_create_task', {
      'workspace_id': 'id-1',
      'title': 'Move me',
      'description': 'Agent will update this status.',
      'status': 'todo',
    });
    final task = createdTask['task'] as Map<String, Object?>;
    expect(task['id'], 'id-2');
    expect(task['status'], 'todo');

    final movedTask = await api.call('task_center_move_task', {
      'workspace_id': 'id-1',
      'task_id': 'id-2',
      'status': 'done',
      'index': 0,
    });
    expect((movedTask['task'] as Map<String, Object?>)['status'], 'done');

    final listed = await api.call('task_center_list_tasks', {
      'workspace_id': 'id-1',
    });
    final tasks = listed['tasks'] as List<Object?>;
    expect(tasks, hasLength(1));
    expect((tasks.single as Map<String, Object?>)['status'], 'done');
  });

  test('agent API exposes a discoverable tool catalog', () {
    final api = TaskCenterAgentApi(store: TaskCenterStore(path: 'unused.json'));

    expect(api.toolNames, contains('task_center_create_workspace'));
    expect(api.toolNames, contains('task_center_create_task'));
    expect(api.toolNames, contains('task_center_update_task'));
    expect(api.toolNames, contains('task_center_move_task'));
    expect(api.toolNames, contains('task_center_list_workspaces'));
    expect(api.toolNames, contains('task_center_list_tasks'));
    expect(api.toolNames, contains('task_center_delete_task'));
  });
}

class _IdSequence {
  int _next = 1;

  String next() => 'id-${_next++}';
}
