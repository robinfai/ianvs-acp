import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/tasks/task_record.dart';
import 'package:ianvs_acp/tasks/workspace_resource.dart';

void main() {
  test('WorkspaceResource normalizes local directory refs', () {
    final resource = WorkspaceResource.localDirectory(
      id: 'resource-1',
      label: 'App',
      path: '/workspace/app/',
    );

    expect(resource.type, ResourceType.localDirectory);
    expect(resource.ref['path'], '/workspace/app');
    expect(resource.serial, isTrue);
    expect(resource.serialGateKey, '/workspace/app');
    expect(resource.toJson(), {
      'id': 'resource-1',
      'type': 'local_directory',
      'label': 'App',
      'ref': {'path': '/workspace/app'},
      'serial': true,
    });
  });

  test('WorkspaceResource falls back from task workspacePath', () {
    final task = TaskRecord(
      id: 'task-1',
      title: 'Work',
      description: '',
      workspacePath: '/workspace/app/',
      agentName: 'Codex',
      status: TaskStatus.queued,
      priority: TaskPriority.normal,
      createdAt: DateTime(2026, 7, 9, 8),
      updatedAt: DateTime(2026, 7, 9, 8),
    );

    final inferred = workspaceResourceForTask(
      task,
      const <WorkspaceResource>[],
    );

    expect(inferred.id, 'local_directory:/workspace/app');
    expect(inferred.label, 'app');
    expect(inferred.ref['path'], '/workspace/app');
    expect(
      serialGateKeyForTask(task, const <WorkspaceResource>[]),
      '/workspace/app',
    );
  });

  test('serial gate key uses referenced serial resource path', () {
    final task = TaskRecord(
      id: 'task-1',
      title: 'Work',
      description: '',
      workspacePath: '/stale/path',
      agentName: 'Codex',
      status: TaskStatus.queued,
      priority: TaskPriority.normal,
      createdAt: DateTime(2026, 7, 9, 8),
      updatedAt: DateTime(2026, 7, 9, 8),
      resourceId: 'resource-1',
    );
    final resources = [
      WorkspaceResource.localDirectory(
        id: 'resource-1',
        label: 'App',
        path: '/workspace/app/',
      ),
    ];

    expect(serialGateKeyForTask(task, resources), '/workspace/app');
  });

  test('serial gate key is empty for referenced non-serial resource', () {
    final task = TaskRecord(
      id: 'task-1',
      title: 'Work',
      description: '',
      workspacePath: '/workspace/app',
      agentName: 'Codex',
      status: TaskStatus.queued,
      priority: TaskPriority.normal,
      createdAt: DateTime(2026, 7, 9, 8),
      updatedAt: DateTime(2026, 7, 9, 8),
      resourceId: 'resource-1',
    );
    final resources = [
      WorkspaceResource.localDirectory(
        id: 'resource-1',
        label: 'App',
        path: '/workspace/app',
        serial: false,
      ),
    ];

    expect(serialGateKeyForTask(task, resources), isEmpty);
  });
}
