import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/tasks/retry_policy.dart';
import 'package:ianvs_acp/tasks/runtime_registry.dart';
import 'package:ianvs_acp/tasks/task_inbox_controller.dart';
import 'package:ianvs_acp/tasks/task_inbox_snapshot.dart';
import 'package:ianvs_acp/tasks/task_record.dart';
import 'package:ianvs_acp/tasks/task_repository.dart';
import 'package:ianvs_acp/tasks/task_scheduler.dart';
import 'package:ianvs_acp/tasks/workspace_execution_gate.dart';
import 'package:ianvs_acp/tasks/workspace_resource.dart';

import '../support/memory_task_repository.dart';

void main() {
  test(
    'TaskScheduler retries a transient repository refresh failure',
    () async {
      final createdAt = DateTime(2026, 7, 8, 9);
      final store = _MemoryTaskStore(
        TaskInboxSnapshot(
          updatedAt: createdAt,
          tasks: [_task(id: 'task-1', createdAt: createdAt)],
        ),
      );
      var failRevisionOnce = true;
      store.beforeOperation = (operation) async {
        if (operation == 'revision' && failRevisionOnce) {
          failRevisionOnce = false;
          throw StateError('temporary read failure');
        }
      };
      final controller = TaskInboxController(
        repository: store,
        idGenerator: _DeterministicIds().next,
      );
      addTearDown(controller.dispose);
      final worker = _RecordingTaskWorker(controller);
      final scheduler = TaskScheduler(
        taskController: controller,
        worker: worker,
      );
      addTearDown(scheduler.shutdown);

      await scheduler.start();
      await _waitUntil(() => worker.startedTaskIds.contains('task-1'));

      expect(failRevisionOnce, isFalse);
      worker.complete('task-1');
      await _waitUntil(() => scheduler.activeCount == 0);
    },
  );

  test('TaskScheduler enqueues an inbox task without starting work', () async {
    final store = _MemoryTaskStore();
    final controller = TaskInboxController(
      repository: store,
      clock: () => DateTime(2026, 7, 8, 9),
      idGenerator: (_) => 'task-1',
    );
    addTearDown(controller.dispose);
    await controller.load();
    final task = await controller.createTask(
      title: 'Queue me',
      description: '',
      workspacePath: '/workspace/app',
      agentName: 'Codex',
    );
    final worker = _RecordingTaskWorker(controller);
    final scheduler = TaskScheduler(taskController: controller, worker: worker);
    addTearDown(scheduler.dispose);

    final queued = await scheduler.enqueueTask(task.id);

    expect(queued.status, TaskStatus.queued);
    expect(store.savedSnapshots.last.tasks.single.status, TaskStatus.queued);
    expect(worker.startedTaskIds, isEmpty);
  });

  test('TaskScheduler runs queued tasks by priority', () async {
    final controller = TaskInboxController(
      repository: _MemoryTaskStore(
        TaskInboxSnapshot(
          updatedAt: DateTime(2026, 7, 8, 9),
          tasks: [
            _task(
              id: 'task-normal',
              priority: TaskPriority.normal,
              createdAt: DateTime(2026, 7, 8, 9),
            ),
            _task(
              id: 'task-urgent',
              priority: TaskPriority.urgent,
              createdAt: DateTime(2026, 7, 8, 9, 1),
            ),
            _task(
              id: 'task-high',
              priority: TaskPriority.high,
              createdAt: DateTime(2026, 7, 8, 9, 2),
            ),
          ],
        ),
      ),
    );
    addTearDown(controller.dispose);
    await controller.load();
    final worker = _RecordingTaskWorker(controller);
    final scheduler = TaskScheduler(
      taskController: controller,
      worker: worker,
      maxConcurrentTasks: 1,
    );
    addTearDown(scheduler.dispose);

    await scheduler.start();
    await _waitUntil(() => worker.startedTaskIds.length == 1);
    expect(worker.startedTaskIds, ['task-urgent']);

    worker.complete('task-urgent');
    await _waitUntil(() => worker.startedTaskIds.length == 2);
    expect(worker.startedTaskIds, ['task-urgent', 'task-high']);

    worker.complete('task-high');
    await _waitUntil(() => worker.startedTaskIds.length == 3);
    expect(worker.startedTaskIds, ['task-urgent', 'task-high', 'task-normal']);
  });

  test('TaskScheduler stop prevents queued task scans', () async {
    final controller = TaskInboxController(
      repository: _MemoryTaskStore(
        TaskInboxSnapshot(
          updatedAt: DateTime(2026, 7, 8, 9),
          tasks: [_task(id: 'task-1', createdAt: DateTime(2026, 7, 8, 9))],
        ),
      ),
    );
    addTearDown(controller.dispose);
    await controller.load();
    final worker = _RecordingTaskWorker(controller);
    final scheduler = TaskScheduler(taskController: controller, worker: worker);
    addTearDown(scheduler.dispose);

    await scheduler.start();
    scheduler.stop();
    await Future<void>.delayed(const Duration(milliseconds: 25));

    expect(scheduler.isStarted, isFalse);
    expect(worker.startedTaskIds, isEmpty);
    expect(controller.runs, isEmpty);
  });

  test('TaskScheduler dispatches a run before starting work', () async {
    final ids = _DeterministicIds();
    final operations = <String>[];
    final store = _MemoryTaskStore(
      TaskInboxSnapshot(
        updatedAt: DateTime(2026, 7, 8, 9),
        tasks: [_task(id: 'task-1', createdAt: DateTime(2026, 7, 8, 9))],
      ),
    )..beforeOperation = (operation) async => operations.add(operation);
    final controller = TaskInboxController(
      repository: store,
      clock: () => DateTime(2026, 7, 8, 9, 30),
      idGenerator: ids.next,
    );
    addTearDown(controller.dispose);
    await controller.load();
    final worker = _RecordingTaskWorker(controller);
    final scheduler = TaskScheduler(taskController: controller, worker: worker);
    addTearDown(scheduler.dispose);

    await scheduler.start();
    await _waitUntil(() => worker.startedTaskIds.length == 1);

    expect(controller.runs.single.status, TaskStatus.dispatched);
    expect(controller.runs.single.taskId, 'task-1');
    expect(controller.tasks.single.currentRunId, 'run-1');
    expect(controller.events.single.text, 'Task dispatched.');
    expect(controller.events.single.metadata['task_status'], 'dispatched');
    expect(operations, contains('claimTask'));
    expect(operations, isNot(contains('createRun')));
  });

  test(
    'TaskScheduler runs different workspaces up to max concurrency',
    () async {
      final controller = TaskInboxController(
        repository: _MemoryTaskStore(
          TaskInboxSnapshot(
            updatedAt: DateTime(2026, 7, 8, 9),
            tasks: [
              _task(
                id: 'task-1',
                workspacePath: '/workspace/app',
                createdAt: DateTime(2026, 7, 8, 9),
              ),
              _task(
                id: 'task-2',
                workspacePath: '/workspace/other',
                createdAt: DateTime(2026, 7, 8, 9, 1),
              ),
              _task(
                id: 'task-3',
                workspacePath: '/workspace/third',
                createdAt: DateTime(2026, 7, 8, 9, 2),
              ),
            ],
          ),
        ),
      );
      addTearDown(controller.dispose);
      await controller.load();
      final worker = _RecordingTaskWorker(controller);
      final scheduler = TaskScheduler(
        taskController: controller,
        worker: worker,
        maxConcurrentTasks: 2,
      );
      addTearDown(scheduler.dispose);

      await scheduler.start();
      await _waitUntil(() => worker.startedTaskIds.length == 2);
      expect(worker.startedTaskIds, ['task-1', 'task-2']);
      expect(scheduler.activeCount, 2);

      await Future<void>.delayed(const Duration(milliseconds: 25));
      expect(worker.startedTaskIds, ['task-1', 'task-2']);

      worker.complete('task-1');
      await _waitUntil(() => worker.startedTaskIds.length == 3);
      expect(worker.startedTaskIds, ['task-1', 'task-2', 'task-3']);
    },
  );

  test('TaskScheduler serializes tasks with the same workspace path', () async {
    final controller = TaskInboxController(
      repository: _MemoryTaskStore(
        TaskInboxSnapshot(
          updatedAt: DateTime(2026, 7, 8, 9),
          tasks: [
            _task(
              id: 'task-1',
              workspacePath: '/workspace/app',
              createdAt: DateTime(2026, 7, 8, 9),
            ),
            _task(
              id: 'task-2',
              workspacePath: '/workspace/app/',
              createdAt: DateTime(2026, 7, 8, 9, 1),
            ),
            _task(
              id: 'task-3',
              workspacePath: '/workspace/other',
              createdAt: DateTime(2026, 7, 8, 9, 2),
            ),
          ],
        ),
      ),
    );
    addTearDown(controller.dispose);
    await controller.load();
    final worker = _RecordingTaskWorker(controller);
    final scheduler = TaskScheduler(
      taskController: controller,
      worker: worker,
      maxConcurrentTasks: 3,
    );
    addTearDown(scheduler.dispose);

    await scheduler.start();
    await _waitUntil(() => worker.startedTaskIds.length == 2);
    expect(worker.startedTaskIds, ['task-1', 'task-3']);

    await Future<void>.delayed(const Duration(milliseconds: 25));
    expect(worker.startedTaskIds, ['task-1', 'task-3']);

    worker.complete('task-1');
    await _waitUntil(() => worker.startedTaskIds.length == 3);
    expect(worker.startedTaskIds, ['task-1', 'task-3', 'task-2']);
  });

  test('TaskScheduler skips the workspace gate for serial false', () async {
    const resource = WorkspaceResource(
      id: 'resource-1',
      type: ResourceType.localDirectory,
      label: 'Parallel workspace',
      ref: <String, Object?>{'path': '/workspace/app'},
      serial: false,
    );
    final controller = TaskInboxController(
      repository: _MemoryTaskStore(
        TaskInboxSnapshot(
          updatedAt: DateTime(2026, 7, 8, 9),
          tasks: [
            _task(
              id: 'task-1',
              createdAt: DateTime(2026, 7, 8, 9),
              resourceId: resource.id,
            ),
            _task(
              id: 'task-2',
              createdAt: DateTime(2026, 7, 8, 9, 1),
              resourceId: resource.id,
            ),
          ],
          resources: const [resource],
        ),
      ),
      idGenerator: _DeterministicIds().next,
    );
    addTearDown(controller.dispose);
    final worker = _RecordingTaskWorker(controller);
    final scheduler = TaskScheduler(
      taskController: controller,
      worker: worker,
      maxConcurrentTasks: 2,
    );
    addTearDown(scheduler.shutdown);
    addTearDown(() => worker.complete('task-1'));

    await scheduler.start();
    await _waitUntil(() => worker.startedTaskIds.length == 2);

    expect(worker.startedTaskIds, ['task-1', 'task-2']);
    worker.complete('task-1');
    worker.complete('task-2');
  });

  test('TaskScheduler re-probes when a queued task route changes', () async {
    final now = DateTime(2026, 7, 8, 9);
    final store = _MemoryTaskStore(
      TaskInboxSnapshot(
        updatedAt: now,
        tasks: [
          _task(
            id: 'task-1',
            createdAt: now,
            agentName: 'OldAgent',
            workspacePath: '/workspace/old',
          ),
        ],
      ),
    );
    final controller = TaskInboxController(
      repository: store,
      clock: () => now,
      idGenerator: _DeterministicIds().next,
    );
    addTearDown(controller.dispose);
    await controller.load();
    final probeStarted = Completer<void>();
    final releaseProbe = Completer<void>();
    final probedAgents = <String>[];
    final registry = LocalRuntimeRegistry(
      clock: () => now,
      probe: (agentName) async {
        probedAgents.add(agentName);
        if (agentName == 'OldAgent' && !probeStarted.isCompleted) {
          probeStarted.complete();
          await releaseProbe.future;
        }
        return LocalRuntimeStatus.available(
          agentName: agentName,
          checkedAt: now,
        );
      },
    );
    final gate = WorkspaceExecutionGate();
    final worker = _RecordingTaskWorker(controller);
    final scheduler = TaskScheduler(
      taskController: controller,
      worker: worker,
      runtimeRegistry: registry,
      workspaceGate: gate,
    );
    addTearDown(scheduler.shutdown);
    addTearDown(() => worker.complete('task-1'));

    await scheduler.start();
    await probeStarted.future;
    await controller.updateTask(
      'task-1',
      agentName: 'NewAgent',
      workspacePath: '/workspace/new',
    );
    releaseProbe.complete();
    await _waitUntil(() => worker.startedTaskIds.isNotEmpty);

    expect(probedAgents.first, 'OldAgent');
    expect(probedAgents, contains('NewAgent'));
    expect(controller.tasks.single.agentName, 'NewAgent');
    expect(gate.ownerFor('/workspace/old'), isNull);
    expect(gate.ownerFor('/workspace/new'), 'task-1');

    worker.complete('task-1');
    await _waitUntil(() => scheduler.activeCount == 0);
    expect(gate.ownerFor('/workspace/new'), isNull);
  });

  test('TaskScheduler re-probes when a queued resource changes', () async {
    final now = DateTime(2026, 7, 8, 9);
    const oldResource = WorkspaceResource(
      id: 'resource-1',
      type: ResourceType.localDirectory,
      label: 'Workspace',
      ref: <String, Object?>{'path': '/workspace/old'},
    );
    const newResource = WorkspaceResource(
      id: 'resource-1',
      type: ResourceType.localDirectory,
      label: 'Workspace',
      ref: <String, Object?>{'path': '/workspace/new'},
    );
    final store = _MemoryTaskStore(
      TaskInboxSnapshot(
        updatedAt: now,
        tasks: [
          _task(id: 'task-1', createdAt: now, resourceId: oldResource.id),
        ],
        resources: const [oldResource],
      ),
    );
    final controller = TaskInboxController(
      repository: store,
      clock: () => now,
      idGenerator: _DeterministicIds().next,
    );
    addTearDown(controller.dispose);
    await controller.load();
    final firstProbeStarted = Completer<void>();
    final releaseFirstProbe = Completer<void>();
    var probeCount = 0;
    final registry = LocalRuntimeRegistry(
      clock: () => now,
      probe: (agentName) async {
        probeCount += 1;
        if (probeCount == 1) {
          firstProbeStarted.complete();
          await releaseFirstProbe.future;
        }
        return LocalRuntimeStatus.available(
          agentName: agentName,
          checkedAt: now,
        );
      },
    );
    final gate = WorkspaceExecutionGate();
    final worker = _RecordingTaskWorker(controller);
    final scheduler = TaskScheduler(
      taskController: controller,
      worker: worker,
      runtimeRegistry: registry,
      workspaceGate: gate,
    );
    addTearDown(scheduler.shutdown);
    addTearDown(() => worker.complete('task-1'));

    await scheduler.start();
    await firstProbeStarted.future;
    await store.upsertResource(
      newResource,
      expected: oldResource,
      updatedAt: now.add(const Duration(minutes: 1)),
    );
    await controller.refreshIfChanged();
    releaseFirstProbe.complete();
    await _waitUntil(() => worker.startedTaskIds.isNotEmpty);

    expect(probeCount, greaterThanOrEqualTo(2));
    expect(gate.ownerFor('/workspace/old'), isNull);
    expect(gate.ownerFor('/workspace/new'), 'task-1');
    worker.complete('task-1');
  });

  test(
    'TaskScheduler releases the gate key acquired before resource refresh',
    () async {
      final now = DateTime(2026, 7, 8, 9);
      const oldResource = WorkspaceResource(
        id: 'resource-1',
        type: ResourceType.localDirectory,
        label: 'Workspace',
        ref: <String, Object?>{'path': '/workspace/old'},
      );
      const newResource = WorkspaceResource(
        id: 'resource-1',
        type: ResourceType.localDirectory,
        label: 'Workspace',
        ref: <String, Object?>{'path': '/workspace/new'},
      );
      final store = _MemoryTaskStore(
        TaskInboxSnapshot(
          updatedAt: now,
          tasks: [
            _task(id: 'task-1', createdAt: now, resourceId: oldResource.id),
          ],
          resources: const [oldResource],
        ),
      );
      final controller = TaskInboxController(
        repository: store,
        clock: () => now,
        idGenerator: _DeterministicIds().next,
      );
      addTearDown(controller.dispose);
      final gate = WorkspaceExecutionGate();
      final worker = _RecordingTaskWorker(controller);
      final scheduler = TaskScheduler(
        taskController: controller,
        worker: worker,
        workspaceGate: gate,
      );
      addTearDown(scheduler.shutdown);
      addTearDown(() => worker.complete('task-1'));

      await scheduler.start();
      await _waitUntil(
        () => controller.tasks.single.status == TaskStatus.running,
      );
      expect(gate.ownerFor('/workspace/old'), 'task-1');

      await store.upsertResource(
        newResource,
        expected: oldResource,
        updatedAt: now.add(const Duration(minutes: 1)),
      );
      await controller.refreshIfChanged();
      worker.complete('task-1');
      await _waitUntil(() => scheduler.activeCount == 0);

      expect(gate.ownerFor('/workspace/old'), isNull);
      expect(gate.ownerFor('/workspace/new'), isNull);
    },
  );

  test(
    'TaskScheduler leaves busy runtime tasks queued without a run',
    () async {
      final now = DateTime(2026, 7, 8, 9);
      final controller = TaskInboxController(
        repository: _MemoryTaskStore(
          TaskInboxSnapshot(
            updatedAt: now,
            tasks: [_task(id: 'task-1', createdAt: now)],
          ),
        ),
        clock: () => now,
        idGenerator: _DeterministicIds().next,
      );
      addTearDown(controller.dispose);
      final runtimeRegistry = LocalRuntimeRegistry(clock: () => now)
        ..setStatus(
          LocalRuntimeStatus.busy(
            agentName: 'Codex',
            checkedAt: now,
            reason: 'The background agent is already in use.',
          ),
        );
      final worker = _RecordingTaskWorker(controller);
      final scheduler = TaskScheduler(
        taskController: controller,
        worker: worker,
        runtimeRegistry: runtimeRegistry,
      );
      addTearDown(scheduler.shutdown);

      await scheduler.start();
      await Future<void>.delayed(const Duration(milliseconds: 350));

      expect(worker.startedTaskIds, isEmpty);
      expect(controller.tasks.single.status, TaskStatus.queued);
      expect(controller.runs, isEmpty);

      runtimeRegistry.setStatus(
        LocalRuntimeStatus.available(agentName: 'Codex', checkedAt: now),
      );
      await _waitUntil(() => worker.startedTaskIds.isNotEmpty);
      expect(controller.runs, hasLength(1));
      worker.complete('task-1');
    },
  );

  test('TaskScheduler stop cancels busy runtime wake-ups', () async {
    final now = DateTime(2026, 7, 8, 9);
    final controller = TaskInboxController(
      repository: _MemoryTaskStore(
        TaskInboxSnapshot(
          updatedAt: now,
          tasks: [_task(id: 'task-1', createdAt: now)],
        ),
      ),
      clock: () => now,
      idGenerator: _DeterministicIds().next,
    );
    addTearDown(controller.dispose);
    var probeCount = 0;
    final registry = LocalRuntimeRegistry(
      clock: () => now,
      probe: (agentName) {
        probeCount += 1;
        return LocalRuntimeStatus.busy(agentName: agentName, checkedAt: now);
      },
    );
    final worker = _RecordingTaskWorker(controller);
    final scheduler = TaskScheduler(
      taskController: controller,
      worker: worker,
      runtimeRegistry: registry,
    );
    addTearDown(scheduler.shutdown);

    await scheduler.start();
    await _waitUntil(() => probeCount > 0);
    scheduler.stop();
    final countAtStop = probeCount;
    await Future<void>.delayed(const Duration(milliseconds: 350));

    expect(probeCount, countAtStop);
    expect(worker.startedTaskIds, isEmpty);
    expect(controller.tasks.single.status, TaskStatus.queued);
    expect(controller.runs, isEmpty);
  });

  test('TaskScheduler stop prevents a pending probe from claiming', () async {
    final now = DateTime(2026, 7, 8, 9);
    final controller = TaskInboxController(
      repository: _MemoryTaskStore(
        TaskInboxSnapshot(
          updatedAt: now,
          tasks: [_task(id: 'task-1', createdAt: now)],
        ),
      ),
      clock: () => now,
      idGenerator: _DeterministicIds().next,
    );
    addTearDown(controller.dispose);
    final probeStarted = Completer<void>();
    final releaseProbe = Completer<void>();
    final registry = LocalRuntimeRegistry(
      clock: () => now,
      probe: (agentName) async {
        probeStarted.complete();
        await releaseProbe.future;
        return LocalRuntimeStatus.available(
          agentName: agentName,
          checkedAt: now,
        );
      },
    );
    final worker = _RecordingTaskWorker(controller);
    final scheduler = TaskScheduler(
      taskController: controller,
      worker: worker,
      runtimeRegistry: registry,
    );

    await scheduler.start();
    await probeStarted.future;
    scheduler.stop();
    releaseProbe.complete();
    await scheduler.shutdown();

    expect(worker.startedTaskIds, isEmpty);
    expect(controller.tasks.single.status, TaskStatus.queued);
    expect(controller.runs, isEmpty);
    expect(controller.events, isEmpty);
  });

  test('TaskScheduler lets available agents pass a busy task', () async {
    final now = DateTime(2026, 7, 8, 9);
    final controller = TaskInboxController(
      repository: _MemoryTaskStore(
        TaskInboxSnapshot(
          updatedAt: now,
          tasks: [
            _task(
              id: 'task-busy',
              createdAt: now,
              priority: TaskPriority.urgent,
              agentName: 'BusyAgent',
            ),
            _task(
              id: 'task-ready',
              createdAt: now.add(const Duration(minutes: 1)),
              agentName: 'ReadyAgent',
            ),
          ],
        ),
      ),
      clock: () => now,
      idGenerator: _DeterministicIds().next,
    );
    addTearDown(controller.dispose);
    final registry = LocalRuntimeRegistry(
      clock: () => now,
      probe: (agentName) => agentName == 'BusyAgent'
          ? LocalRuntimeStatus.busy(agentName: agentName, checkedAt: now)
          : LocalRuntimeStatus.available(agentName: agentName, checkedAt: now),
    );
    final worker = _RecordingTaskWorker(controller);
    final scheduler = TaskScheduler(
      taskController: controller,
      worker: worker,
      runtimeRegistry: registry,
      maxConcurrentTasks: 1,
    );
    addTearDown(scheduler.shutdown);

    await scheduler.start();
    await _waitUntil(() => worker.startedTaskIds.isNotEmpty);

    expect(worker.startedTaskIds, ['task-ready']);
    expect(controller.taskById('task-busy')!.status, TaskStatus.queued);
    expect(controller.runs.where((run) => run.taskId == 'task-busy'), isEmpty);
    worker.complete('task-ready');
  });

  test(
    'TaskScheduler retries a claim id conflict without failing task',
    () async {
      final now = DateTime(2026, 7, 8, 9);
      final store = _ConflictOnceClaimStore(
        TaskInboxSnapshot(
          updatedAt: now,
          tasks: [
            _task(
              id: 'task-queued',
              createdAt: now.add(const Duration(minutes: 1)),
            ),
          ],
        ),
      );
      final controller = TaskInboxController(
        repository: store,
        clock: () => now,
        idGenerator: _DeterministicIds().next,
      );
      addTearDown(controller.dispose);
      final worker = _RecordingTaskWorker(controller);
      final scheduler = TaskScheduler(
        taskController: controller,
        worker: worker,
      );
      addTearDown(scheduler.shutdown);

      await scheduler.start();
      await _waitUntil(() => worker.startedTaskIds.isNotEmpty);

      expect(worker.startedTaskIds, ['task-queued']);
      expect(store.claimCalls, 2);
      expect(controller.taskById('task-queued')!.status, TaskStatus.running);
      expect(
        controller.runs.singleWhere((run) => run.taskId == 'task-queued').id,
        'run-2',
      );
      worker.complete('task-queued');
    },
  );

  test(
    'TaskScheduler retries refresh after another scheduler wins the claim',
    () async {
      final now = DateTime(2026, 7, 8, 9);
      final store = _LoseFirstClaimStore(
        TaskInboxSnapshot(
          updatedAt: now,
          tasks: [_task(id: 'task-1', createdAt: now)],
        ),
      );
      final controller = TaskInboxController(
        repository: store,
        clock: () => now,
        idGenerator: _DeterministicIds().next,
      );
      addTearDown(controller.dispose);
      final worker = _RecordingTaskWorker(controller);
      final scheduler = TaskScheduler(
        taskController: controller,
        worker: worker,
      );
      addTearDown(scheduler.shutdown);

      await scheduler.start();
      await _waitUntil(
        () => controller.taskById('task-1')?.currentRunId == 'run-external',
      );
      await Future<void>.delayed(const Duration(milliseconds: 25));

      expect(store.claimCalls, 1);
      expect(store.remainingLoadFailures, 0);
      expect(worker.startedTaskIds, isEmpty);
      expect(controller.tasks.single.status, TaskStatus.dispatched);
      expect(controller.runs.single.id, 'run-external');
      expect(controller.events.single.id, 'event-external');
    },
  );

  test(
    'TaskScheduler keeps runtime offline tasks queued with an event',
    () async {
      final now = DateTime(2026, 7, 8, 9);
      final controller = TaskInboxController(
        repository: _MemoryTaskStore(
          TaskInboxSnapshot(
            updatedAt: now,
            tasks: [_task(id: 'task-1', createdAt: now)],
          ),
        ),
        clock: () => now,
        idGenerator: _DeterministicIds().next,
      );
      addTearDown(controller.dispose);
      await controller.load();
      final runtimeRegistry = LocalRuntimeRegistry(clock: () => now)
        ..setStatus(
          LocalRuntimeStatus.unavailable(
            agentName: 'Codex',
            checkedAt: now,
            reason: 'Agent process is offline.',
          ),
        );
      final worker = _RecordingTaskWorker(controller);
      final scheduler = TaskScheduler(
        taskController: controller,
        worker: worker,
        runtimeRegistry: runtimeRegistry,
        retryPolicy: const RetryPolicy(baseDelay: Duration(hours: 1)),
      );
      addTearDown(scheduler.dispose);

      await scheduler.start();
      await _waitUntil(() => controller.events.isNotEmpty);

      expect(worker.startedTaskIds, isEmpty);
      expect(controller.tasks.single.status, TaskStatus.queued);
      expect(controller.tasks.single.summary, contains('Runtime unavailable'));
      expect(
        controller.tasks.single.metadata['failure_reason'],
        'runtimeOffline',
      );
      expect(controller.tasks.single.metadata['next_retry_at'], isNotNull);
      expect(controller.runs.single.status, TaskStatus.failed);
      expect(
        controller.events.map((event) => event.text),
        contains(contains('Runtime unavailable')),
      );
    },
  );

  test('TaskScheduler blocks auth-required runtime without retrying', () async {
    final now = DateTime(2026, 7, 8, 9);
    final controller = TaskInboxController(
      repository: _MemoryTaskStore(
        TaskInboxSnapshot(
          updatedAt: now,
          tasks: [_task(id: 'task-1', createdAt: now)],
        ),
      ),
      clock: () => now,
      idGenerator: _DeterministicIds().next,
    );
    addTearDown(controller.dispose);
    await controller.load();
    final runtimeRegistry = LocalRuntimeRegistry(clock: () => now)
      ..setStatus(
        LocalRuntimeStatus.authRequired(
          agentName: 'Codex',
          checkedAt: now,
          reason: 'Run authentication first.',
        ),
      );
    final worker = _RecordingTaskWorker(controller);
    final scheduler = TaskScheduler(
      taskController: controller,
      worker: worker,
      runtimeRegistry: runtimeRegistry,
    );
    addTearDown(scheduler.dispose);

    await scheduler.start();
    await _waitUntil(
      () => controller.tasks.single.status == TaskStatus.blockedOnUserInput,
    );

    expect(worker.startedTaskIds, isEmpty);
    expect(controller.tasks.single.status, TaskStatus.blockedOnUserInput);
    expect(
      controller.tasks.single.summary,
      contains('Authentication required'),
    );
    expect(controller.tasks.single.metadata['failure_reason'], 'authRequired');
    expect(controller.runs.single.status, TaskStatus.failed);
    expect(
      controller.events.map((event) => event.text),
      contains(contains('Authentication required')),
    );

    runtimeRegistry.setStatus(
      LocalRuntimeStatus.available(agentName: 'Codex', checkedAt: now),
    );
    await _waitUntil(() => worker.startedTaskIds.isNotEmpty);

    expect(worker.startedTaskIds, ['task-1']);
    expect(controller.runs, hasLength(2));
    expect(controller.tasks.single.metadata['failure_reason'], isNull);
    expect(controller.tasks.single.metadata['runtime_availability'], isNull);
    worker.complete('task-1');
  });

  test('TaskScheduler only requeues the authenticated agent tasks', () async {
    final now = DateTime(2026, 7, 8, 9);
    final controller = TaskInboxController(
      repository: _MemoryTaskStore(
        TaskInboxSnapshot(
          updatedAt: now,
          tasks: [
            _task(
              id: 'task-ready-auth',
              createdAt: now,
              status: TaskStatus.blockedOnUserInput,
              currentRunId: 'run-ready-auth',
              agentName: 'ReadyAgent',
              metadata: const <String, Object?>{
                'failure_reason': 'authRequired',
                'runtime_availability': 'authRequired',
              },
            ),
            _task(
              id: 'task-waiting-auth',
              createdAt: now.add(const Duration(minutes: 1)),
              status: TaskStatus.blockedOnUserInput,
              currentRunId: 'run-waiting-auth',
              agentName: 'WaitingAgent',
              metadata: const <String, Object?>{
                'failure_reason': 'authRequired',
                'runtime_availability': 'authRequired',
              },
            ),
            _task(
              id: 'task-human-blocked',
              createdAt: now.add(const Duration(minutes: 2)),
              status: TaskStatus.blockedOnUserInput,
              agentName: 'ReadyAgent',
              metadata: const <String, Object?>{
                'failure_reason': 'permissionDenied',
              },
            ),
          ],
          runs: [
            TaskRunRecord(
              id: 'run-ready-auth',
              taskId: 'task-ready-auth',
              attempt: 1,
              status: TaskStatus.failed,
              startedAt: now,
              endedAt: now,
            ),
            TaskRunRecord(
              id: 'run-waiting-auth',
              taskId: 'task-waiting-auth',
              attempt: 1,
              status: TaskStatus.failed,
              startedAt: now,
              endedAt: now,
            ),
          ],
        ),
      ),
      clock: () => now,
      idGenerator: _DeterministicIds().next,
    );
    addTearDown(controller.dispose);
    final registry = LocalRuntimeRegistry(
      clock: () => now,
      probe: (agentName) => agentName == 'ReadyAgent'
          ? LocalRuntimeStatus.available(agentName: agentName, checkedAt: now)
          : LocalRuntimeStatus.authRequired(
              agentName: agentName,
              checkedAt: now,
            ),
    );
    final worker = _RecordingTaskWorker(controller);
    final scheduler = TaskScheduler(
      taskController: controller,
      worker: worker,
      runtimeRegistry: registry,
    );
    addTearDown(scheduler.shutdown);
    addTearDown(() => worker.complete('task-ready-auth'));

    await scheduler.start();
    await _waitUntil(() => worker.startedTaskIds.isNotEmpty);

    expect(worker.startedTaskIds, ['task-ready-auth']);
    expect(
      controller.taskById('task-ready-auth')!.metadata['failure_reason'],
      isNull,
    );
    expect(
      controller.taskById('task-waiting-auth')!.status,
      TaskStatus.blockedOnUserInput,
    );
    expect(
      controller.taskById('task-waiting-auth')!.metadata['failure_reason'],
      'authRequired',
    );
    expect(
      controller.taskById('task-human-blocked')!.status,
      TaskStatus.blockedOnUserInput,
    );
    expect(
      controller.taskById('task-human-blocked')!.metadata['failure_reason'],
      'permissionDenied',
    );
    worker.complete('task-ready-auth');
  });

  test('TaskScheduler retries retryable failures with a new run', () async {
    final ids = _DeterministicIds();
    final controller = TaskInboxController(
      repository: _MemoryTaskStore(
        TaskInboxSnapshot(
          updatedAt: DateTime(2026, 7, 8, 9),
          tasks: [_task(id: 'task-1', createdAt: DateTime(2026, 7, 8, 9))],
        ),
      ),
      clock: () => DateTime(2026, 7, 8, 10),
      idGenerator: ids.next,
    );
    addTearDown(controller.dispose);
    await controller.load();
    final worker = _FailOnceTaskWorker(controller);
    final scheduler = TaskScheduler(
      taskController: controller,
      worker: worker,
      retryPolicy: const RetryPolicy(baseDelay: Duration.zero),
    );
    addTearDown(scheduler.dispose);

    await scheduler.start();
    await _waitUntil(() => worker.startedTaskIds.length == 2);
    worker.complete('task-1');
    await _waitUntil(
      () => controller.tasks.single.status == TaskStatus.needsHumanReview,
    );

    expect(worker.startedTaskIds, ['task-1', 'task-1']);
    expect(controller.runs.map((run) => run.attempt), [1, 2]);
    expect(controller.runs.map((run) => run.id), ['run-1', 'run-2']);
    expect(
      controller.events.map((event) => event.text),
      contains('Task retry queued.'),
    );
  });

  test(
    'TaskScheduler moves retry wake earlier for newly queued task',
    () async {
      final now = DateTime.now();
      final controller = TaskInboxController(
        repository: _MemoryTaskStore(
          TaskInboxSnapshot(
            updatedAt: now,
            tasks: [
              _task(
                id: 'task-late',
                createdAt: now,
                metadata: <String, Object?>{
                  'next_retry_at': now
                      .add(const Duration(milliseconds: 350))
                      .toIso8601String(),
                },
              ),
              _task(
                id: 'task-early',
                createdAt: now.add(const Duration(milliseconds: 1)),
                metadata: <String, Object?>{
                  'next_retry_at': now
                      .add(const Duration(milliseconds: 50))
                      .toIso8601String(),
                },
              ),
            ],
          ),
        ),
        idGenerator: _DeterministicIds().next,
      );
      addTearDown(controller.dispose);
      await controller.load();
      final worker = _RecordingTaskWorker(controller);
      final scheduler = TaskScheduler(
        taskController: controller,
        worker: worker,
        maxConcurrentTasks: 1,
      );
      addTearDown(scheduler.dispose);

      await scheduler.start();
      await _waitUntil(
        () => worker.startedTaskIds.contains('task-early'),
        attempts: 20,
      );

      expect(worker.startedTaskIds, ['task-early']);
    },
  );

  test('TaskScheduler does not retry non-retryable failures', () async {
    final ids = _DeterministicIds();
    final controller = TaskInboxController(
      repository: _MemoryTaskStore(
        TaskInboxSnapshot(
          updatedAt: DateTime(2026, 7, 8, 9),
          tasks: [_task(id: 'task-1', createdAt: DateTime(2026, 7, 8, 9))],
        ),
      ),
      clock: () => DateTime(2026, 7, 8, 10),
      idGenerator: ids.next,
    );
    addTearDown(controller.dispose);
    await controller.load();
    final worker = _NonRetryableFailureTaskWorker(controller);
    final scheduler = TaskScheduler(
      taskController: controller,
      worker: worker,
      retryPolicy: const RetryPolicy(baseDelay: Duration.zero),
    );
    addTearDown(scheduler.dispose);

    await scheduler.start();
    await _waitUntil(() => worker.startedTaskIds.length == 1);
    await Future<void>.delayed(const Duration(milliseconds: 25));

    expect(worker.startedTaskIds, ['task-1']);
    expect(controller.runs, hasLength(1));
    expect(controller.tasks.single.status, TaskStatus.failed);
    expect(controller.tasks.single.error, contains('permissionDenied'));
  });

  test(
    'TaskScheduler recovers interrupted runs before draining queue',
    () async {
      final controller = TaskInboxController(
        repository: _MemoryTaskStore(
          TaskInboxSnapshot(
            updatedAt: DateTime(2026, 7, 8, 9),
            tasks: [
              _task(
                id: 'task-interrupted',
                createdAt: DateTime(2026, 7, 8, 9),
                status: TaskStatus.running,
                currentRunId: 'run-1',
              ),
              _task(id: 'task-queued', createdAt: DateTime(2026, 7, 8, 9, 1)),
            ],
            runs: [
              TaskRunRecord(
                id: 'run-1',
                taskId: 'task-interrupted',
                attempt: 1,
                status: TaskStatus.running,
                startedAt: DateTime(2026, 7, 8, 9),
              ),
            ],
          ),
        ),
        clock: () => DateTime(2026, 7, 8, 10),
        idGenerator: _DeterministicIds().next,
      );
      addTearDown(controller.dispose);
      await controller.load();
      final worker = _RecordingTaskWorker(controller);
      final scheduler = TaskScheduler(
        taskController: controller,
        worker: worker,
        maxConcurrentTasks: 1,
      );
      addTearDown(scheduler.dispose);

      await scheduler.start();
      await _waitUntil(() => worker.startedTaskIds.length == 1);

      expect(worker.startedTaskIds, ['task-queued']);
      expect(
        controller.taskById('task-interrupted')!.status,
        TaskStatus.failed,
      );
      final recoveredRun = controller.runs.singleWhere(
        (run) => run.id == 'run-1',
      );
      expect(recoveredRun.status, TaskStatus.failed);
      expect(recoveredRun.endedAt, DateTime(2026, 7, 8, 10));
    },
  );

  test(
    'TaskScheduler preserves non-active and auth-blocked tasks on recovery',
    () async {
      final createdAt = DateTime(2026, 7, 8, 9);
      final controller = TaskInboxController(
        repository: _MemoryTaskStore(
          TaskInboxSnapshot(
            updatedAt: createdAt,
            tasks: [
              _task(
                id: 'task-auth',
                createdAt: createdAt,
                status: TaskStatus.blockedOnUserInput,
                currentRunId: 'run-auth',
                metadata: const <String, Object?>{
                  'failure_reason': 'authRequired',
                },
              ),
              _task(
                id: 'task-complete-run',
                createdAt: createdAt,
                status: TaskStatus.running,
                currentRunId: 'run-complete',
              ),
            ],
            runs: [
              TaskRunRecord(
                id: 'run-auth',
                taskId: 'task-auth',
                attempt: 1,
                status: TaskStatus.failed,
                startedAt: createdAt,
                endedAt: createdAt,
              ),
              TaskRunRecord(
                id: 'run-complete',
                taskId: 'task-complete-run',
                attempt: 1,
                status: TaskStatus.done,
                startedAt: createdAt,
                endedAt: createdAt,
              ),
            ],
          ),
        ),
        clock: () => createdAt.add(const Duration(hours: 1)),
      );
      addTearDown(controller.dispose);
      final scheduler = TaskScheduler(
        taskController: controller,
        worker: _RecordingTaskWorker(controller),
      );
      addTearDown(scheduler.shutdown);

      await scheduler.start(dispatchQueuedTasks: false);

      expect(
        controller.taskById('task-auth')!.status,
        TaskStatus.blockedOnUserInput,
      );
      expect(
        controller.taskById('task-auth')!.metadata['failure_reason'],
        'authRequired',
      );
      expect(
        controller.taskById('task-complete-run')!.status,
        TaskStatus.running,
      );
      expect(controller.events, isEmpty);
    },
  );

  test(
    'TaskScheduler recovers active permission and artifact phases',
    () async {
      final createdAt = DateTime(2026, 7, 8, 9);
      final controller = TaskInboxController(
        repository: _MemoryTaskStore(
          TaskInboxSnapshot(
            updatedAt: createdAt,
            tasks: [
              _task(
                id: 'task-permission',
                createdAt: createdAt,
                status: TaskStatus.blockedOnPermission,
                currentRunId: 'run-permission',
              ),
              _task(
                id: 'task-artifacts',
                createdAt: createdAt,
                status: TaskStatus.collectingArtifacts,
                currentRunId: 'run-artifacts',
              ),
            ],
            runs: [
              TaskRunRecord(
                id: 'run-permission',
                taskId: 'task-permission',
                attempt: 1,
                status: TaskStatus.running,
                startedAt: createdAt,
              ),
              TaskRunRecord(
                id: 'run-artifacts',
                taskId: 'task-artifacts',
                attempt: 1,
                status: TaskStatus.running,
                startedAt: createdAt,
              ),
            ],
          ),
        ),
        clock: () => createdAt.add(const Duration(hours: 1)),
      );
      addTearDown(controller.dispose);
      final scheduler = TaskScheduler(
        taskController: controller,
        worker: _RecordingTaskWorker(controller),
      );
      addTearDown(scheduler.shutdown);

      await scheduler.start(dispatchQueuedTasks: false);

      expect(
        controller.tasks.map((task) => task.status),
        everyElement(TaskStatus.failed),
      );
      expect(
        controller.runs.map((run) => run.status),
        everyElement(TaskStatus.failed),
      );
      expect(controller.events, hasLength(2));
      expect(
        controller.events.map((event) => event.metadata['recovered']),
        everyElement(isTrue),
      );
    },
  );

  test('TaskScheduler shutdown cancels and waits for active work', () async {
    final controller = TaskInboxController(
      repository: _MemoryTaskStore(
        TaskInboxSnapshot(
          updatedAt: DateTime(2026, 7, 8, 9),
          tasks: [_task(id: 'task-1', createdAt: DateTime(2026, 7, 8, 9))],
        ),
      ),
      idGenerator: _DeterministicIds().next,
    );
    addTearDown(controller.dispose);
    await controller.load();
    final worker = _CancellableTaskWorker(controller);
    final scheduler = TaskScheduler(taskController: controller, worker: worker);

    await scheduler.start();
    await _waitUntil(() => worker.startedTaskIds.isNotEmpty);
    var shutdownFinished = false;
    final shutdown = scheduler.shutdown().then((_) => shutdownFinished = true);
    await Future<void>.delayed(Duration.zero);

    expect(worker.cancelCalls, 1);
    expect(shutdownFinished, isFalse);
    worker.complete();
    await shutdown;
    expect(shutdownFinished, isTrue);
    expect(scheduler.activeCount, 0);
  });

  test('TaskScheduler shutdown waits for dispatch persistence', () async {
    final store = _BlockingSaveTaskStore(
      TaskInboxSnapshot(
        updatedAt: DateTime(2026, 7, 8, 9),
        tasks: [_task(id: 'task-1', createdAt: DateTime(2026, 7, 8, 9))],
      ),
    );
    final controller = TaskInboxController(
      repository: store,
      idGenerator: _DeterministicIds().next,
    );
    addTearDown(controller.dispose);
    final scheduler = TaskScheduler(
      taskController: controller,
      worker: _RecordingTaskWorker(controller),
    );

    await scheduler.start();
    await store.saveStarted.future;
    var shutdownFinished = false;
    final shutdown = scheduler.shutdown().then((_) => shutdownFinished = true);
    await Future<void>.delayed(Duration.zero);

    expect(shutdownFinished, isFalse);
    store.releaseSave();
    await shutdown;
    expect(shutdownFinished, isTrue);
    expect(scheduler.activeCount, 0);
  });

  test('TaskScheduler can recover without dispatching queued work', () async {
    final controller = TaskInboxController(
      repository: _MemoryTaskStore(
        TaskInboxSnapshot(
          updatedAt: DateTime(2026, 7, 8, 9),
          tasks: [_task(id: 'task-1', createdAt: DateTime(2026, 7, 8, 9))],
        ),
      ),
      idGenerator: _DeterministicIds().next,
    );
    addTearDown(controller.dispose);
    final worker = _RecordingTaskWorker(controller);
    final scheduler = TaskScheduler(taskController: controller, worker: worker);
    addTearDown(scheduler.dispose);

    await scheduler.start(dispatchQueuedTasks: false);
    await controller.updateTask('task-1', summary: 'Updated before publish.');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(worker.startedTaskIds, isEmpty);

    scheduler.startDispatching();
    await _waitUntil(() => worker.startedTaskIds.isNotEmpty);
    expect(worker.startedTaskIds, ['task-1']);
  });
}

TaskRecord _task({
  required String id,
  TaskPriority priority = TaskPriority.normal,
  required DateTime createdAt,
  TaskStatus status = TaskStatus.queued,
  String workspacePath = '/workspace/app',
  String agentName = 'Codex',
  String? currentRunId,
  String? resourceId,
  Map<String, Object?> metadata = const <String, Object?>{},
}) {
  return TaskRecord(
    id: id,
    title: id,
    description: '',
    workspacePath: workspacePath,
    agentName: agentName,
    status: status,
    priority: priority,
    createdAt: createdAt,
    updatedAt: createdAt,
    currentRunId: currentRunId,
    resourceId: resourceId,
    metadata: metadata,
  );
}

class _RecordingTaskWorker implements TaskWorker {
  _RecordingTaskWorker(this.controller);

  final TaskInboxController controller;
  final List<String> startedTaskIds = <String>[];
  final Map<String, Completer<void>> _completions = <String, Completer<void>>{};

  @override
  Future<TaskRecord> run(TaskRecord task) async {
    startedTaskIds.add(task.id);
    final completion = Completer<void>();
    _completions[task.id] = completion;
    await controller.updateTaskStatus(task.id, TaskStatus.running);
    await completion.future;
    return controller.updateTaskStatus(task.id, TaskStatus.needsHumanReview);
  }

  void complete(String taskId) {
    final completion = _completions[taskId];
    if (completion == null || completion.isCompleted) return;
    completion.complete();
  }
}

class _FailOnceTaskWorker implements TaskWorker {
  _FailOnceTaskWorker(this.controller);

  final TaskInboxController controller;
  final List<String> startedTaskIds = <String>[];
  final Map<String, Completer<void>> _completions = <String, Completer<void>>{};

  @override
  Future<TaskRecord> run(TaskRecord task) async {
    startedTaskIds.add(task.id);
    final runId = task.currentRunId!;
    if (startedTaskIds.length == 1) {
      await controller.updateRun(
        runId,
        status: TaskStatus.failed,
        endedAt: DateTime(2026, 7, 8, 10),
        error: 'runtimeOffline: agent disconnected',
      );
      return controller.updateTask(
        task.id,
        status: TaskStatus.failed,
        error: 'runtimeOffline: agent disconnected',
      );
    }

    final completion = Completer<void>();
    _completions[task.id] = completion;
    await controller.updateRun(runId, status: TaskStatus.running);
    await controller.updateTaskStatus(task.id, TaskStatus.running);
    await completion.future;
    await controller.updateRun(
      runId,
      status: TaskStatus.needsHumanReview,
      endedAt: DateTime(2026, 7, 8, 10, 1),
    );
    return controller.updateTaskStatus(task.id, TaskStatus.needsHumanReview);
  }

  void complete(String taskId) {
    final completion = _completions[taskId];
    if (completion == null || completion.isCompleted) return;
    completion.complete();
  }
}

class _NonRetryableFailureTaskWorker implements TaskWorker {
  _NonRetryableFailureTaskWorker(this.controller);

  final TaskInboxController controller;
  final List<String> startedTaskIds = <String>[];

  @override
  Future<TaskRecord> run(TaskRecord task) async {
    startedTaskIds.add(task.id);
    final runId = task.currentRunId!;
    await controller.updateRun(
      runId,
      status: TaskStatus.failed,
      endedAt: DateTime(2026, 7, 8, 10),
      error: 'permissionDenied: user denied tool access',
    );
    return controller.updateTask(
      task.id,
      status: TaskStatus.failed,
      error: 'permissionDenied: user denied tool access',
    );
  }
}

class _CancellableTaskWorker implements CancellableTaskWorker {
  _CancellableTaskWorker(this.controller);

  final TaskInboxController controller;
  final Completer<void> _completion = Completer<void>();
  final List<String> startedTaskIds = <String>[];
  int cancelCalls = 0;

  @override
  Future<void> cancelActive() async {
    cancelCalls += 1;
  }

  @override
  Future<TaskRecord> run(TaskRecord task) async {
    startedTaskIds.add(task.id);
    await controller.updateTaskStatus(task.id, TaskStatus.running);
    await _completion.future;
    return controller.updateTaskStatus(task.id, TaskStatus.cancelled);
  }

  void complete() {
    if (!_completion.isCompleted) _completion.complete();
  }
}

class _MemoryTaskStore extends MemoryTaskRepository {
  _MemoryTaskStore([super.snapshot]);
}

class _BlockingSaveTaskStore extends MemoryTaskRepository {
  _BlockingSaveTaskStore(super.snapshot) {
    beforeOperation = (operation) async {
      if (operation != 'claimTask') return;
      if (!saveStarted.isCompleted) saveStarted.complete();
      await _saveRelease.future;
    };
  }

  final Completer<void> saveStarted = Completer<void>();
  final Completer<void> _saveRelease = Completer<void>();

  void releaseSave() {
    if (!_saveRelease.isCompleted) _saveRelease.complete();
  }
}

class _LoseFirstClaimStore extends MemoryTaskRepository {
  _LoseFirstClaimStore(super.snapshot);

  int claimCalls = 0;
  int remainingLoadFailures = 1;
  bool _externalClaimed = false;

  @override
  Future<TaskRepositorySnapshot> loadRepository() {
    if (_externalClaimed && remainingLoadFailures > 0) {
      remainingLoadFailures -= 1;
      throw StateError('simulated reload failure');
    }
    return super.loadRepository();
  }

  @override
  Future<TaskClaim?> claimTask(
    TaskRecord expectedTask,
    TaskRunRecord run, {
    required TaskEventRecord dispatchEvent,
    WorkspaceResource? expectedResource,
  }) async {
    claimCalls += 1;
    if (claimCalls != 1) {
      return super.claimTask(
        expectedTask,
        run,
        dispatchEvent: dispatchEvent,
        expectedResource: expectedResource,
      );
    }
    final startedAt = run.startedAt;
    await super.claimTask(
      expectedTask,
      TaskRunRecord(
        id: 'run-external',
        taskId: expectedTask.id,
        attempt: run.attempt,
        status: TaskStatus.dispatched,
        startedAt: startedAt,
      ),
      dispatchEvent: TaskEventRecord(
        id: 'event-external',
        taskId: expectedTask.id,
        runId: 'run-external',
        kind: TaskEventKind.system,
        text: 'Task dispatched.',
        createdAt: startedAt,
      ),
      expectedResource: expectedResource,
    );
    _externalClaimed = true;
    return null;
  }
}

class _ConflictOnceClaimStore extends MemoryTaskRepository {
  _ConflictOnceClaimStore(super.snapshot);

  int claimCalls = 0;

  @override
  Future<TaskClaim?> claimTask(
    TaskRecord expectedTask,
    TaskRunRecord run, {
    required TaskEventRecord dispatchEvent,
    WorkspaceResource? expectedResource,
  }) {
    claimCalls += 1;
    if (claimCalls == 1) {
      throw const TaskRepositoryConflict('simulated run id collision');
    }
    return super.claimTask(
      expectedTask,
      run,
      dispatchEvent: dispatchEvent,
      expectedResource: expectedResource,
    );
  }
}

class _DeterministicIds {
  final Map<String, int> _counts = <String, int>{};

  String next(String prefix) {
    final count = (_counts[prefix] ?? 0) + 1;
    _counts[prefix] = count;
    return '$prefix-$count';
  }
}

Future<void> _waitUntil(bool Function() condition, {int attempts = 40}) async {
  for (var attempt = 0; attempt < attempts; attempt += 1) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Condition was not met before timeout.');
}
