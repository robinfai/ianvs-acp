import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/rust/ianvs_workflow_native.dart';
import 'package:ianvs_acp/tasks/task_record.dart';

void main() {
  test('projects typed workflow operations and snapshots', () {
    final native = _FakeWorkflowNative();
    final workflow = IanvsRustWorkflow(native: native);
    addTearDown(workflow.dispose);

    final opened = workflow.open('/tmp/workflow.sqlite3');
    expect(opened.revision, 0);
    expect(opened.recoveredFailedTaskIds, isEmpty);

    final projection = workflow.apply(
      IanvsWorkflowCommand.createTask(
        taskId: 'task-1',
        workspacePath: '/tmp/workspace',
        agentName: 'fixture',
      ),
    );
    expect(native.lastCommand, <String, Object?>{
      'operation': 'create_task',
      'taskId': 'task-1',
      'workspacePath': '/tmp/workspace',
      'agentName': 'fixture',
    });
    expect(projection.revision, 1);
    expect(projection.tasks.single.id, 'task-1');
    expect(projection.tasks.single.status, IanvsWorkflowTaskStatus.inbox);
  });

  test('rejects unknown projection schema fail closed', () {
    final native = _FakeWorkflowNative(schemaVersion: 2);
    final workflow = IanvsRustWorkflow(native: native);
    addTearDown(workflow.dispose);
    expect(() => workflow.open('/tmp/workflow.sqlite3'), throwsFormatException);
  });

  test('surfaces Rust transition errors without changing projection', () {
    final native = _FakeWorkflowNative();
    final workflow = IanvsRustWorkflow(native: native);
    addTearDown(workflow.dispose);
    workflow.open('/tmp/workflow.sqlite3');
    native.failNext = 'unknown run: missing';

    expect(
      () => workflow.apply(IanvsWorkflowCommand.startRun('missing')),
      throwsA(
        isA<StateError>().having(
          (error) => error.toString(),
          'message',
          contains('unknown run: missing'),
        ),
      ),
    );
    expect(workflow.snapshot().revision, 0);
  });

  test('encodes definition edit and delete as typed product operations', () {
    expect(
      IanvsWorkflowCommand.updateTaskDefinition(
        taskId: 'task-1',
        workspacePath: '/tmp/edited',
        agentName: 'agent-b',
      ).toJson(),
      <String, Object?>{
        'operation': 'update_task_definition',
        'taskId': 'task-1',
        'workspacePath': '/tmp/edited',
        'agentName': 'agent-b',
      },
    );
    expect(
      IanvsWorkflowCommand.deleteTask('task-1').toJson(),
      <String, Object?>{'operation': 'delete_task', 'taskId': 'task-1'},
    );

    final now = DateTime.utc(2026, 7, 17, 10);
    final task = TaskRecord(
      id: 'task-1',
      title: 'Edited',
      description: 'Definition',
      workspacePath: '/tmp/edited',
      agentName: 'agent-b',
      status: TaskStatus.inbox,
      priority: TaskPriority.high,
      createdAt: now,
      updatedAt: now,
    );
    expect(
      IanvsTaskInboxCommand.updateTaskDefinition(
        task: task,
        updatedAt: now,
      ).toJson(),
      <String, Object?>{
        'operation': 'update_task_definition',
        'task': task.toJson(),
        'updatedAt': now.toIso8601String(),
      },
    );
    expect(
      IanvsTaskInboxCommand.deleteTask(
        taskId: 'task-1',
        updatedAt: now,
      ).toJson(),
      <String, Object?>{
        'operation': 'delete_task',
        'taskId': 'task-1',
        'updatedAt': now.toIso8601String(),
      },
    );
    final queued = task.copyWith(status: TaskStatus.queued);
    expect(
      IanvsTaskInboxCommand.queueTaskProjection(
        task: queued,
        updatedAt: now,
      ).toJson(),
      <String, Object?>{
        'operation': 'queue_task_projection',
        'task': queued.toJson(),
        'updatedAt': now.toIso8601String(),
      },
    );
    final run = TaskRunRecord(
      id: 'run-1',
      taskId: task.id,
      attempt: 1,
      status: TaskStatus.running,
      startedAt: now,
    );
    final running = queued.copyWith(
      status: TaskStatus.running,
      currentRunId: run.id,
    );
    expect(
      IanvsTaskInboxCommand.transitionRunProjection(
        task: running,
        run: run,
        transition: IanvsTaskInboxRunTransition.start,
        updatedAt: now,
      ).toJson()['operation'],
      'transition_run_projection',
    );
    expect(
      IanvsTaskInboxCommand.cancelTaskProjection(
        task: running.copyWith(status: TaskStatus.cancelled),
        run: run.copyWith(status: TaskStatus.cancelled),
        updatedAt: now,
      ).toJson()['operation'],
      'cancel_task_projection',
    );
  });

  test('projects typed Rust scheduler registry and no-op claim', () {
    final native = _FakeWorkflowNative();
    final workflow = IanvsRustWorkflow(native: native);
    addTearDown(workflow.dispose);
    workflow.open('/tmp/workflow.sqlite3');
    workflow.configureScheduler(maxConcurrentTasks: 2);
    expect(native.lastSchedulerConfig, <String, Object?>{
      'maxConcurrentTasks': 2,
    });
    final observedAt = DateTime.utc(2026, 7, 17, 11);
    workflow.setSchedulerRuntimeStatus(
      IanvsSchedulerRuntimeStatus(
        agentName: 'fixture',
        availability: IanvsSchedulerRuntimeAvailability.available,
        observedAt: observedAt,
        supportsPermissions: true,
        maxConcurrentTasks: 1,
      ),
    );
    expect(native.lastRuntimeStatus, <String, Object?>{
      'agentName': 'fixture',
      'availability': 'available',
      'observedAt': observedAt.toIso8601String(),
      'supportsSessionResume': false,
      'supportsPermissions': true,
      'maxConcurrentTasks': 1,
    });
    final claim = workflow.schedulerClaimNext(
      runId: 'run-1',
      dispatchEventId: 'event-1',
      now: observedAt,
      excludedTaskIds: const <String>['task-deferred'],
    );
    expect(claim.claim, isNull);
    expect(claim.nextWakeAt, observedAt.add(const Duration(minutes: 5)));
    expect(claim.workflow.revision, 0);
    expect(native.lastClaimRequest, <String, Object?>{
      'runId': 'run-1',
      'dispatchEventId': 'event-1',
      'now': observedAt.toIso8601String(),
      'excludedTaskIds': <String>['task-deferred'],
    });
  });
}

final class _FakeWorkflowNative implements IanvsWorkflowNativeApi {
  _FakeWorkflowNative({this.schemaVersion = 1});

  final int schemaVersion;
  final Object handle = Object();
  Map<String, Object?>? lastCommand;
  Map<String, Object?>? lastTaskInboxCommand;
  Map<String, Object?>? lastSchedulerConfig;
  Map<String, Object?>? lastRuntimeStatus;
  Map<String, Object?>? lastClaimRequest;
  String? failNext;
  bool freed = false;
  int _revision = 0;
  List<Map<String, Object?>> _tasks = const <Map<String, Object?>>[];
  Map<String, Object?>? _taskInboxSource;
  Map<String, Object?>? _taskInboxCurrent;
  String? _sourceChecksum;
  String _migrationPhase = 'native';

  @override
  int get ffiVersion => 5;

  @override
  Object createWorkflow() => handle;

  @override
  String? openWorkflow(Object workflow, String databasePath) {
    return _projection(recovery: true);
  }

  @override
  String? applyWorkflow(Object workflow, Map<String, Object?> command) {
    lastCommand = Map<String, Object?>.from(command);
    if (failNext != null) return null;
    _revision += 1;
    if (command['operation'] == 'create_task') {
      _tasks = <Map<String, Object?>>[
        <String, Object?>{
          'id': command['taskId'],
          'workspacePath': command['workspacePath'],
          'agentName': command['agentName'],
          'status': 'inbox',
          'attempt': 0,
          'currentRunId': null,
        },
      ];
    }
    return _projection();
  }

  @override
  String? snapshotWorkflow(Object workflow) => _projection();

  @override
  String? stageTaskInbox(
    Object workflow,
    Map<String, Object?> snapshot,
    String sourceChecksum,
  ) {
    _taskInboxSource = Map<String, Object?>.from(snapshot);
    _sourceChecksum = sourceChecksum;
    _migrationPhase = 'staged';
    _revision += 1;
    return _projection(
      migrationPhase: 'staged',
      normalizedHistoricalTaskIds: const <String>[],
    );
  }

  @override
  String? taskInboxSource(Object workflow) {
    return jsonEncode(<String, Object?>{
      'schemaVersion': 1,
      'taskInboxSchema': 'ianvs-acp.task-inbox.v1',
      'source': _taskInboxSource,
    });
  }

  @override
  String? materializeTaskInbox(Object workflow) {
    _taskInboxCurrent = _taskInboxSource;
    _migrationPhase = 'ready';
    _revision += 1;
    return jsonEncode(<String, Object?>{
      ...jsonDecode(_projection(migrationPhase: 'ready'))
          as Map<String, Object?>,
      'taskInbox': _taskInboxSource,
    });
  }

  @override
  String? activateTaskInbox(Object workflow) {
    _migrationPhase = 'active';
    _revision += 1;
    return jsonEncode(<String, Object?>{
      ...jsonDecode(_projection()) as Map<String, Object?>,
      'taskInbox': _taskInboxCurrent,
    });
  }

  @override
  String? applyTaskInbox(Object workflow, Map<String, Object?> command) {
    lastTaskInboxCommand = Map<String, Object?>.from(command);
    if (failNext != null) return null;
    _revision += 1;
    return jsonEncode(<String, Object?>{
      ...jsonDecode(_projection()) as Map<String, Object?>,
      'taskInbox': _taskInboxCurrent,
    });
  }

  @override
  String? configureScheduler(Object workflow, Map<String, Object?> config) {
    lastSchedulerConfig = Map<String, Object?>.from(config);
    return _projection();
  }

  @override
  String? setSchedulerRuntimeStatus(
    Object workflow,
    Map<String, Object?> status,
  ) {
    lastRuntimeStatus = Map<String, Object?>.from(status);
    return _projection();
  }

  @override
  String? schedulerClaimNext(Object workflow, Map<String, Object?> request) {
    lastClaimRequest = Map<String, Object?>.from(request);
    return jsonEncode(<String, Object?>{
      ...jsonDecode(_projection()) as Map<String, Object?>,
      'taskInbox': _taskInboxCurrent ?? _emptyTaskInbox(),
      'claim': null,
      'nextWakeAt': DateTime.utc(2026, 7, 17, 11, 5).toIso8601String(),
    });
  }

  @override
  String? currentTaskInbox(Object workflow) {
    return jsonEncode(<String, Object?>{
      'schemaVersion': 1,
      'taskInboxSchema': 'ianvs-acp.task-inbox.v1',
      'current': _taskInboxCurrent,
    });
  }

  @override
  String? lastError(Object workflow) => failNext;

  @override
  void freeWorkflow(Object workflow) {
    freed = true;
  }

  String _projection({
    bool recovery = false,
    String? migrationPhase,
    List<String>? normalizedHistoricalTaskIds,
  }) {
    return jsonEncode(<String, Object?>{
      'schemaVersion': schemaVersion,
      'revision': _revision,
      'migration': <String, Object?>{
        'phase': migrationPhase ?? _migrationPhase,
        'sourceChecksum': ?_sourceChecksum,
      },
      'snapshot': <String, Object?>{'tasks': _tasks, 'runs': const <Object?>[]},
      if (recovery)
        'recovery': const <String, Object?>{'failedTaskIds': <String>[]},
      'normalizedHistoricalTaskIds': ?normalizedHistoricalTaskIds,
    });
  }

  Map<String, Object?> _emptyTaskInbox() => <String, Object?>{
    'schema': 'ianvs-acp.task-inbox.v1',
    'updated_at': '2026-07-17T00:00:00.000Z',
    'tasks': const <Object?>[],
    'runs': const <Object?>[],
    'events': const <Object?>[],
    'artifacts': const <Object?>[],
    'approvals': const <Object?>[],
    'resources': const <Object?>[],
  };
}
