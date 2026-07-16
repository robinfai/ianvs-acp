import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/tasks/task_inbox_snapshot.dart';
import 'package:ianvs_acp/tasks/task_record.dart';
import 'package:ianvs_acp/tasks/workspace_resource.dart';

void main() {
  for (final field in const <String>[
    'tasks',
    'runs',
    'events',
    'artifacts',
    'approvals',
    'resources',
  ]) {
    test('fromJsonStrict rejects duplicate ids within $field', () {
      final json = _snapshot().toJson();
      final records = List<Object?>.of(json[field]! as List<Object?>);
      records.add(
        Map<String, Object?>.of(records.single! as Map<String, Object?>),
      );
      json[field] = records;

      expect(
        () => TaskInboxSnapshot.fromJsonStrict(json),
        throwsA(isA<FormatException>()),
      );
    });
  }

  test('fromJsonStrict rejects a run id reused by an event', () {
    final json = _snapshot().toJson();
    _changeRecordField(json, 'events', 0, 'id', 'run-1');

    expect(
      () => TaskInboxSnapshot.fromJsonStrict(json),
      throwsA(
        isA<FormatException>().having(
          (error) => '$error',
          'message',
          contains('Duplicate persisted id: run-1'),
        ),
      ),
    );
  });

  test('fromJsonStrict independently rejects an orphan run task', () {
    final json = _referenceSnapshot().toJson();
    _changeRecordField(json, 'runs', 3, 'task_id', 'missing-task');

    expect(
      () => TaskInboxSnapshot.fromJsonStrict(json),
      throwsA(
        isA<FormatException>().having(
          (error) => '$error',
          'message',
          contains('Run run-orphan references missing task missing-task'),
        ),
      ),
    );
  });

  test(
    'fromJsonStrict independently rejects an approval artifact run mismatch',
    () {
      final json = _referenceSnapshot().toJson();
      _changeRecordField(json, 'approvals', 0, 'artifact_ids', <String>[
        'artifact-1b',
      ]);

      expect(
        () => TaskInboxSnapshot.fromJsonStrict(json),
        throwsA(
          isA<FormatException>().having(
            (error) => '$error',
            'message',
            contains(
              'Approval approval-1 references invalid artifact artifact-1b',
            ),
          ),
        ),
      );
    },
  );

  final invalidReferences = <String, void Function(Map<String, Object?>)>{
    'task current run is missing': (json) {
      _changeRecordField(json, 'tasks', 0, 'current_run_id', 'missing-run');
    },
    'task current run belongs to another task': (json) {
      _changeRecordField(json, 'tasks', 0, 'current_run_id', 'run-2');
    },
    'task resource is missing': (json) {
      _changeRecordField(json, 'tasks', 0, 'resource_id', 'missing-resource');
    },
    'event task is missing': (json) {
      _changeRecordField(json, 'events', 0, 'task_id', 'missing-task');
    },
    'event run is missing': (json) {
      _changeRecordField(json, 'events', 0, 'run_id', 'missing-run');
    },
    'event run belongs to another task': (json) {
      _changeRecordField(json, 'events', 0, 'run_id', 'run-2');
    },
    'event task does not own its run': (json) {
      _changeRecordField(json, 'events', 0, 'task_id', 'task-2');
    },
    'artifact task is missing': (json) {
      _changeRecordField(json, 'artifacts', 0, 'task_id', 'missing-task');
    },
    'artifact run is missing': (json) {
      _changeRecordField(json, 'artifacts', 0, 'run_id', 'missing-run');
    },
    'artifact run belongs to another task': (json) {
      _changeRecordField(json, 'artifacts', 0, 'run_id', 'run-2');
    },
    'artifact task does not own its run': (json) {
      _changeRecordField(json, 'artifacts', 0, 'task_id', 'task-2');
    },
    'approval task is missing': (json) {
      _changeRecordField(json, 'approvals', 0, 'task_id', 'missing-task');
    },
    'approval task does not own its run': (json) {
      _changeRecordField(json, 'approvals', 0, 'task_id', 'task-2');
    },
    'approval run is missing': (json) {
      _changeRecordField(json, 'approvals', 0, 'run_id', 'missing-run');
    },
    'approval run belongs to another task': (json) {
      _changeRecordField(json, 'approvals', 0, 'run_id', 'run-2');
    },
    'approval artifact is missing': (json) {
      _changeRecordField(json, 'approvals', 0, 'artifact_ids', <String>[
        'missing-artifact',
      ]);
    },
    'approval artifact belongs to another task': (json) {
      _changeRecordField(json, 'approvals', 0, 'artifact_ids', <String>[
        'artifact-2',
      ]);
    },
  };
  for (final entry in invalidReferences.entries) {
    test('fromJsonStrict rejects when ${entry.key}', () {
      final json = _referenceSnapshot().toJson();
      entry.value(json);

      expect(
        () => TaskInboxSnapshot.fromJsonStrict(json),
        throwsA(isA<FormatException>()),
      );
    });
  }

  test('fromJsonStrict accepts the reference validation fixture', () {
    final restored = TaskInboxSnapshot.fromJsonStrict(
      _referenceSnapshot().toJson(),
    );

    expect(restored.tasks, hasLength(2));
    expect(restored.runs, hasLength(4));
    expect(restored.artifacts, hasLength(3));
  });

  for (final field in const <String>[
    'runs',
    'events',
    'artifacts',
    'approvals',
    'resources',
  ]) {
    test('fromJsonStrict rejects a task id reused by $field', () {
      final json = _snapshot().toJson();
      final records = List<Object?>.of(json[field]! as List<Object?>);
      final record = Map<String, Object?>.of(
        records.single! as Map<String, Object?>,
      );
      record['id'] = 'task-1';
      records[0] = record;
      json[field] = records;

      expect(
        () => TaskInboxSnapshot.fromJsonStrict(json),
        throwsA(
          isA<FormatException>().having(
            (error) => '$error',
            'message',
            contains('Duplicate persisted id: task-1'),
          ),
        ),
      );
    });
  }

  test('fromJsonStrict accepts globally unique persisted ids', () {
    final restored = TaskInboxSnapshot.fromJsonStrict(_snapshot().toJson());

    expect(restored.tasks.single.id, 'task-1');
    expect(restored.runs.single.id, 'run-1');
    expect(restored.events.single.id, 'event-1');
    expect(restored.artifacts.single.id, 'artifact-1');
    expect(restored.approvals.single.id, 'approval-1');
    expect(restored.resources.single.id, 'resource-1');
  });
}

void _changeRecordField(
  Map<String, Object?> json,
  String collection,
  int index,
  String field,
  Object? value,
) {
  final records = List<Object?>.of(json[collection]! as List<Object?>);
  final record = Map<String, Object?>.of(
    records[index]! as Map<String, Object?>,
  );
  record[field] = value;
  records[index] = record;
  json[collection] = records;
}

TaskInboxSnapshot _snapshot() {
  final createdAt = DateTime.utc(2026, 7, 10, 8);
  return TaskInboxSnapshot(
    updatedAt: createdAt,
    tasks: <TaskRecord>[
      TaskRecord(
        id: 'task-1',
        title: 'Task',
        description: '',
        workspacePath: '/workspace/app',
        agentName: 'Codex',
        status: TaskStatus.running,
        priority: TaskPriority.normal,
        createdAt: createdAt,
        updatedAt: createdAt,
        currentRunId: 'run-1',
        resourceId: 'resource-1',
      ),
    ],
    runs: <TaskRunRecord>[
      TaskRunRecord(
        id: 'run-1',
        taskId: 'task-1',
        attempt: 1,
        status: TaskStatus.running,
        startedAt: createdAt,
      ),
    ],
    events: <TaskEventRecord>[
      TaskEventRecord(
        id: 'event-1',
        taskId: 'task-1',
        runId: 'run-1',
        kind: TaskEventKind.assistant,
        text: 'result',
        createdAt: createdAt,
      ),
    ],
    artifacts: <ArtifactRecord>[
      ArtifactRecord(
        id: 'artifact-1',
        taskId: 'task-1',
        runId: 'run-1',
        kind: ArtifactKind.file,
        title: 'report.md',
        createdAt: createdAt,
      ),
    ],
    approvals: <ApprovalRequestRecord>[
      ApprovalRequestRecord(
        id: 'approval-1',
        taskId: 'task-1',
        runId: 'run-1',
        kind: ApprovalKind.toolPermission,
        status: ApprovalStatus.pending,
        createdAt: createdAt,
        artifactIds: const <String>['artifact-1'],
      ),
    ],
    resources: <WorkspaceResource>[
      WorkspaceResource.localDirectory(
        id: 'resource-1',
        label: 'App',
        path: '/workspace/app',
      ),
    ],
  );
}

TaskInboxSnapshot _referenceSnapshot() {
  final createdAt = DateTime.utc(2026, 7, 10, 8);
  TaskRecord task(String id, String runId, String resourceId) {
    return TaskRecord(
      id: id,
      title: id,
      description: '',
      workspacePath: '/workspace/$id',
      agentName: 'Codex',
      status: TaskStatus.running,
      priority: TaskPriority.normal,
      createdAt: createdAt,
      updatedAt: createdAt,
      currentRunId: runId,
      resourceId: resourceId,
    );
  }

  TaskRunRecord run(String id, String taskId) {
    return TaskRunRecord(
      id: id,
      taskId: taskId,
      attempt: 1,
      status: TaskStatus.running,
      startedAt: createdAt,
    );
  }

  ArtifactRecord artifact(String id, String taskId, String runId) {
    return ArtifactRecord(
      id: id,
      taskId: taskId,
      runId: runId,
      kind: ArtifactKind.file,
      title: '$id.md',
      createdAt: createdAt,
    );
  }

  return TaskInboxSnapshot(
    updatedAt: createdAt,
    tasks: <TaskRecord>[
      task('task-1', 'run-1', 'resource-1'),
      task('task-2', 'run-2', 'resource-2'),
    ],
    runs: <TaskRunRecord>[
      run('run-1', 'task-1'),
      run('run-2', 'task-2'),
      run('run-1b', 'task-1'),
      run('run-orphan', 'task-1'),
    ],
    events: <TaskEventRecord>[
      TaskEventRecord(
        id: 'event-1',
        taskId: 'task-1',
        runId: 'run-1',
        kind: TaskEventKind.assistant,
        text: 'result',
        createdAt: createdAt,
      ),
    ],
    artifacts: <ArtifactRecord>[
      artifact('artifact-1', 'task-1', 'run-1'),
      artifact('artifact-2', 'task-2', 'run-2'),
      artifact('artifact-1b', 'task-1', 'run-1b'),
    ],
    approvals: <ApprovalRequestRecord>[
      ApprovalRequestRecord(
        id: 'approval-1',
        taskId: 'task-1',
        runId: 'run-1',
        kind: ApprovalKind.toolPermission,
        status: ApprovalStatus.pending,
        createdAt: createdAt,
        artifactIds: const <String>['artifact-1'],
      ),
    ],
    resources: <WorkspaceResource>[
      WorkspaceResource.localDirectory(
        id: 'resource-1',
        label: 'Task 1',
        path: '/workspace/task-1',
      ),
      WorkspaceResource.localDirectory(
        id: 'resource-2',
        label: 'Task 2',
        path: '/workspace/task-2',
      ),
    ],
  );
}
