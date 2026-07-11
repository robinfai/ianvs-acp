import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/tasks/retry_policy.dart';
import 'package:ianvs_acp/tasks/runtime_registry.dart';
import 'package:ianvs_acp/tasks/task_inbox_controller.dart';
import 'package:ianvs_acp/tasks/task_inbox_snapshot.dart';
import 'package:ianvs_acp/tasks/task_record.dart';
import 'package:ianvs_acp/tasks/task_repository.dart';
import 'package:ianvs_acp/tasks/task_scheduler.dart';
import 'package:ianvs_acp/tasks/task_wake_timer.dart';
import 'package:ianvs_acp/tasks/workspace_execution_gate.dart';
import 'package:ianvs_acp/tasks/workspace_resource.dart';

import '../support/memory_task_repository.dart';

const _testPersistenceWatchdog = Duration(seconds: 1);

void main() {
  test('fake wake timers pump microtasks between equal deadlines', () async {
    final clock = _MutableClock(DateTime(2026, 7, 8, 9));
    final timers = _FakeTaskWakeTimerFactory(clock);
    final callbacks = <String>[];
    late TaskWakeTimer second;
    timers.call(const Duration(minutes: 1), () {
      callbacks.add('first');
      scheduleMicrotask(second.cancel);
    });
    second = timers.call(const Duration(minutes: 1), () {
      callbacks.add('second');
    });

    await timers.elapse(const Duration(minutes: 1));

    expect(callbacks, ['first']);
    expect(second.isActive, isFalse);
  });

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
      final clock = _MutableClock(createdAt);
      final timers = _FakeTaskWakeTimerFactory(clock);
      final scheduler = TaskScheduler(
        taskController: controller,
        worker: worker,
        clock: clock.now,
        wakeTimerFactory: timers.call,
      );
      addTearDown(scheduler.shutdown);

      await scheduler.start();
      await _pumpEventQueue();
      expect(worker.startedTaskIds, isEmpty);

      await timers.elapse(const Duration(milliseconds: 250));
      await _pumpEventQueue();

      expect(failRevisionOnce, isFalse);
      expect(worker.startedTaskIds, ['task-1']);
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
    addTearDown(scheduler.shutdown);

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
    await _pumpEventQueue();

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

      await _pumpEventQueue();
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

    await _pumpEventQueue();
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
    final clock = _MutableClock(now);
    final timers = _FakeTaskWakeTimerFactory(clock);
    final scheduler = TaskScheduler(
      taskController: controller,
      worker: worker,
      runtimeRegistry: registry,
      workspaceGate: gate,
      clock: clock.now,
      wakeTimerFactory: timers.call,
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
    await _pumpEventQueue();
    await timers.elapse(const Duration(milliseconds: 250));
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
    final clock = _MutableClock(now);
    final timers = _FakeTaskWakeTimerFactory(clock);
    final scheduler = TaskScheduler(
      taskController: controller,
      worker: worker,
      runtimeRegistry: registry,
      workspaceGate: gate,
      clock: clock.now,
      wakeTimerFactory: timers.call,
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
    await _pumpEventQueue();
    await timers.elapse(const Duration(milliseconds: 250));
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
      final clock = _MutableClock(now);
      final timers = _FakeTaskWakeTimerFactory(clock);
      final scheduler = TaskScheduler(
        taskController: controller,
        worker: worker,
        runtimeRegistry: runtimeRegistry,
        clock: clock.now,
        wakeTimerFactory: timers.call,
      );
      addTearDown(scheduler.shutdown);

      await scheduler.start();
      await _pumpEventQueue();
      await timers.elapse(const Duration(milliseconds: 250));
      await _pumpEventQueue();

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
    final clock = _MutableClock(now);
    final timers = _FakeTaskWakeTimerFactory(clock);
    final scheduler = TaskScheduler(
      taskController: controller,
      worker: worker,
      runtimeRegistry: registry,
      clock: clock.now,
      wakeTimerFactory: timers.call,
    );
    addTearDown(scheduler.shutdown);

    await scheduler.start();
    await _pumpEventQueue();
    expect(probeCount, greaterThan(0));
    scheduler.stop();
    final countAtStop = probeCount;
    await timers.elapse(const Duration(milliseconds: 250));
    await _pumpEventQueue();

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

  test(
    'TaskScheduler acquires a worker lease before claiming a task',
    () async {
      final now = DateTime(2026, 7, 8, 9);
      final store = _MemoryTaskStore(
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
      final probeStarted = Completer<void>();
      final releaseProbe = Completer<void>();
      final registry = LocalRuntimeRegistry(
        clock: () => now,
        probe: (agentName) async {
          if (!probeStarted.isCompleted) {
            probeStarted.complete();
            await releaseProbe.future;
          }
          return LocalRuntimeStatus.available(
            agentName: agentName,
            checkedAt: now,
          );
        },
      );
      final worker = _ReservableRecordingTaskWorker(controller);
      final scheduler = TaskScheduler(
        taskController: controller,
        worker: worker,
        runtimeRegistry: registry,
      );
      addTearDown(scheduler.shutdown);
      addTearDown(() => worker.complete('task-1'));
      final revisionBeforeStart = await store.revision();

      await scheduler.start();
      await probeStarted.future;
      worker.acceptingLeases = false;
      releaseProbe.complete();
      await _waitUntil(() => worker.acquireCalls > 0);

      expect(controller.tasks.single.status, TaskStatus.queued);
      expect(controller.runs, isEmpty);
      expect(controller.events, isEmpty);
      expect(worker.startedTaskIds, isEmpty);
      expect(await store.revision(), revisionBeforeStart);

      worker.acceptingLeases = true;
      registry.setStatus(
        LocalRuntimeStatus.available(agentName: 'Codex', checkedAt: now),
      );
      await _waitUntil(() => worker.startedTaskIds.isNotEmpty);

      expect(controller.runs, hasLength(1));
      expect(worker.startedTaskIds, ['task-1']);
      expect(worker.acquireCalls, 2);
      worker.complete('task-1');
    },
  );

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
      final worker = _ReservableRecordingTaskWorker(controller);
      final clock = _MutableClock(now);
      final timers = _FakeTaskWakeTimerFactory(clock);
      final scheduler = TaskScheduler(
        taskController: controller,
        worker: worker,
        clock: clock.now,
        wakeTimerFactory: timers.call,
      );
      addTearDown(scheduler.shutdown);

      await scheduler.start();
      await _pumpEventQueue();
      await timers.elapse(const Duration(milliseconds: 250));
      await _waitUntil(() => worker.startedTaskIds.isNotEmpty);

      expect(worker.startedTaskIds, ['task-queued']);
      expect(store.claimCalls, 2);
      expect(worker.acquireCalls, 2);
      expect(worker.releaseCalls, 1);
      expect(controller.taskById('task-queued')!.status, TaskStatus.running);
      expect(
        controller.runs.singleWhere((run) => run.taskId == 'task-queued').id,
        'run-2',
      );
      worker.complete('task-queued');
      await _waitUntil(() => worker.releaseCalls == 2);
    },
  );

  test('TaskScheduler releases a worker lease after worker failure', () async {
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
    final worker = _ReservableRecordingTaskWorker(controller)
      ..runError = StateError('reserved worker failed');
    final scheduler = TaskScheduler(taskController: controller, worker: worker);
    addTearDown(scheduler.shutdown);

    await scheduler.start();
    await _waitUntil(() => controller.tasks.single.status == TaskStatus.failed);

    expect(controller.runs.single.status, TaskStatus.failed);
    expect(controller.tasks.single.error, contains('reserved worker failed'));
    expect(worker.acquireCalls, 1);
    expect(worker.releaseCalls, 1);
    expect(scheduler.activeCount, 0);
  });

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
      final worker = _ReservableRecordingTaskWorker(controller);
      final clock = _MutableClock(now);
      final timers = _FakeTaskWakeTimerFactory(clock);
      final scheduler = TaskScheduler(
        taskController: controller,
        worker: worker,
        clock: clock.now,
        wakeTimerFactory: timers.call,
      );
      addTearDown(scheduler.shutdown);

      await scheduler.start();
      await _pumpEventQueue();
      await timers.elapse(const Duration(milliseconds: 250));
      await _waitUntil(
        () => controller.taskById('task-1')?.currentRunId == 'run-external',
      );
      await _pumpEventQueue();

      expect(store.claimCalls, 1);
      expect(store.remainingLoadFailures, 0);
      expect(worker.startedTaskIds, isEmpty);
      expect(worker.acquireCalls, 1);
      expect(worker.releaseCalls, 1);
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
    final worker = _ReservableRecordingTaskWorker(controller);
    final scheduler = TaskScheduler(
      taskController: controller,
      worker: worker,
      runtimeRegistry: runtimeRegistry,
    );
    addTearDown(scheduler.shutdown);

    await scheduler.start();
    await _waitUntil(
      () => controller.tasks.single.status == TaskStatus.blockedOnUserInput,
    );

    expect(worker.startedTaskIds, isEmpty);
    expect(worker.acquireCalls, 0);
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
    expect(worker.acquireCalls, 1);
    expect(controller.runs, hasLength(2));
    expect(controller.tasks.single.metadata['failure_reason'], isNull);
    expect(controller.tasks.single.metadata['runtime_availability'], isNull);
    worker.complete('task-1');
  });

  test(
    'TaskScheduler resets an auth-blocked agent on explicit enqueue',
    () async {
      final now = DateTime(2026, 7, 8, 9);
      final controller = TaskInboxController(
        repository: _MemoryTaskStore(
          TaskInboxSnapshot(
            updatedAt: now,
            tasks: [
              _task(
                id: 'task-1',
                createdAt: now,
                status: TaskStatus.blockedOnUserInput,
                metadata: const <String, Object?>{
                  'failure_reason': 'authRequired',
                  'runtime_availability': 'authRequired',
                  'unavailable_reason': 'Sign in first.',
                  'last_failure_message': 'Authentication required.',
                  'next_retry_at': '2026-07-08T09:05:00.000',
                  'keep': 'value',
                },
              ),
            ],
          ),
        ),
        clock: () => now,
        idGenerator: _DeterministicIds().next,
      );
      addTearDown(controller.dispose);
      final registry = LocalRuntimeRegistry(
        probe: (agentName) => LocalRuntimeStatus.authRequired(
          agentName: agentName,
          checkedAt: now,
        ),
      );
      final worker = _ReservableRecordingTaskWorker(controller);
      final scheduler = TaskScheduler(
        taskController: controller,
        worker: worker,
        runtimeRegistry: registry,
      );
      addTearDown(scheduler.shutdown);

      await scheduler.start();
      scheduler.stop();
      await scheduler.enqueueTask('task-1');

      expect(worker.resetAgentNames, ['Codex']);
      expect(controller.tasks.single.status, TaskStatus.queued);
      expect(controller.tasks.single.metadata['failure_reason'], isNull);
      expect(controller.tasks.single.metadata['runtime_availability'], isNull);
      expect(controller.tasks.single.metadata['unavailable_reason'], isNull);
      expect(controller.tasks.single.metadata['last_failure_message'], isNull);
      expect(controller.tasks.single.metadata['next_retry_at'], isNull);
      expect(controller.tasks.single.metadata['keep'], 'value');
    },
  );

  test(
    'TaskScheduler recovers authentication discovered by the worker',
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
      var authenticationRequired = false;
      final registry = LocalRuntimeRegistry(
        clock: () => now,
        probe: (agentName) => authenticationRequired
            ? LocalRuntimeStatus.authRequired(
                agentName: agentName,
                checkedAt: now,
              )
            : LocalRuntimeStatus.available(
                agentName: agentName,
                checkedAt: now,
              ),
      );
      final worker = _AuthFailOnceTaskWorker(
        controller,
        onAuthenticationRequired: () => authenticationRequired = true,
      );
      final scheduler = TaskScheduler(
        taskController: controller,
        worker: worker,
        runtimeRegistry: registry,
      );
      addTearDown(scheduler.shutdown);
      addTearDown(() => worker.complete('task-1'));

      await scheduler.start();
      await _waitUntil(
        () => controller.tasks.single.status == TaskStatus.blockedOnUserInput,
      );

      expect(controller.runs, hasLength(1));
      expect(controller.runs.single.status, TaskStatus.failed);
      expect(
        controller.tasks.single.metadata['failure_reason'],
        'authRequired',
      );

      authenticationRequired = false;
      registry.setStatus(
        LocalRuntimeStatus.available(agentName: 'Codex', checkedAt: now),
      );
      await _waitUntil(() => worker.startedTaskIds.length == 2);

      expect(controller.runs, hasLength(2));
      expect(controller.tasks.single.metadata['failure_reason'], isNull);
      worker.complete('task-1');
    },
  );

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
      final clock = _MutableClock(DateTime(2026, 7, 8, 9));
      final timers = _FakeTaskWakeTimerFactory(clock);
      final now = clock.now();
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
        clock: clock.now,
        wakeTimerFactory: timers.call,
      );
      addTearDown(scheduler.dispose);

      await scheduler.start();
      await _pumpEventQueue();
      expect(worker.startedTaskIds, isEmpty);
      expect(timers.activeCount, 1);
      expect(timers.cancelledCount, 1);

      await timers.elapse(const Duration(milliseconds: 50));
      await _pumpEventQueue();

      expect(worker.startedTaskIds, ['task-early']);
      expect(timers.callbackCount, 1);
    },
  );

  test(
    'TaskScheduler dispatches an immediately due retry without a timer',
    () async {
      final now = DateTime(2026, 7, 8, 9);
      final clock = _MutableClock(now);
      final timers = _FakeTaskWakeTimerFactory(clock);
      final controller = TaskInboxController(
        repository: _MemoryTaskStore(
          TaskInboxSnapshot(
            updatedAt: now,
            tasks: [
              _task(
                id: 'task-due',
                createdAt: now,
                metadata: <String, Object?>{
                  'next_retry_at': now.toIso8601String(),
                },
              ),
            ],
          ),
        ),
        idGenerator: _DeterministicIds().next,
      );
      addTearDown(controller.dispose);
      final worker = _RecordingTaskWorker(controller);
      final scheduler = TaskScheduler(
        taskController: controller,
        worker: worker,
        clock: clock.now,
        wakeTimerFactory: timers.call,
      );
      addTearDown(scheduler.shutdown);
      addTearDown(() => worker.complete('task-due'));

      await scheduler.start();
      await _pumpEventQueue();

      expect(worker.startedTaskIds, ['task-due']);
      expect(timers.createdCount, 0);
      worker.complete('task-due');
    },
  );

  test('TaskScheduler dispose cancels retry wake without a callback', () async {
    final now = DateTime(2026, 7, 8, 9);
    final clock = _MutableClock(now);
    final timers = _FakeTaskWakeTimerFactory(clock);
    final controller = TaskInboxController(
      repository: _MemoryTaskStore(
        TaskInboxSnapshot(
          updatedAt: now,
          tasks: [
            _task(
              id: 'task-later',
              createdAt: now,
              metadata: <String, Object?>{
                'next_retry_at': now
                    .add(const Duration(minutes: 1))
                    .toIso8601String(),
              },
            ),
          ],
        ),
      ),
      idGenerator: _DeterministicIds().next,
    );
    addTearDown(controller.dispose);
    final worker = _RecordingTaskWorker(controller);
    final scheduler = TaskScheduler(
      taskController: controller,
      worker: worker,
      clock: clock.now,
      wakeTimerFactory: timers.call,
    );

    await scheduler.start();
    await _pumpEventQueue();
    expect(timers.activeCount, 1);

    scheduler.dispose();
    await _pumpEventQueue();
    await timers.elapse(const Duration(minutes: 1));
    await _pumpEventQueue();

    expect(timers.activeCount, 0);
    expect(timers.cancelledCount, 1);
    expect(timers.callbackCount, 0);
    expect(worker.startedTaskIds, isEmpty);
    await scheduler.shutdown();
  });

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
    await _waitUntil(() => controller.tasks.single.status == TaskStatus.failed);

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
    final worker = _ReservableRecordingTaskWorker(controller);
    final scheduler = TaskScheduler(taskController: controller, worker: worker);

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
    expect(worker.lifecycle, ['release', 'dispose']);
  });

  testWidgets(
    'TaskScheduler stops dispatch and shuts down after stalled revision',
    (tester) async {
      final store = _MemoryTaskStore(
        TaskInboxSnapshot(
          updatedAt: DateTime(2026, 7, 8, 9),
          tasks: [
            _task(
              id: 'task-1',
              createdAt: DateTime(2026, 7, 8, 9),
              status: TaskStatus.blockedOnUserInput,
              metadata: const <String, Object?>{
                'failure_reason': 'authRequired',
              },
            ),
          ],
        ),
      );
      final controller = TaskInboxController(
        repository: store,
        idGenerator: _DeterministicIds().next,
        persistenceWatchdog: _testPersistenceWatchdog,
      );
      addTearDown(controller.dispose);
      await controller.load();
      final revisionStarted = Completer<void>();
      final releaseRevision = Completer<void>();
      var revisionCalls = 0;
      store.beforeOperation = (operation) async {
        if (operation != 'revision') return;
        revisionCalls += 1;
        if (!revisionStarted.isCompleted) revisionStarted.complete();
        await releaseRevision.future;
      };
      final worker = _ReservableRecordingTaskWorker(controller);
      final scheduler = TaskScheduler(
        taskController: controller,
        worker: worker,
      );

      await scheduler.start();
      await _pumpWidgetUntil(tester, () => revisionStarted.isCompleted);
      await tester.pump(_testPersistenceWatchdog);
      await _pumpWidgetUntil(tester, () => scheduler.persistenceFault != null);

      expect(scheduler.isStarted, isFalse);
      await expectLater(
        scheduler.enqueueTask('task-1'),
        throwsA(isA<TaskPersistenceStalledException>()),
      );
      await expectLater(
        scheduler.authenticateAgent('Codex', 'login'),
        throwsA(isA<TaskPersistenceStalledException>()),
      );
      expect(worker.resetAgentNames, isEmpty);
      expect(worker.authenticateCalls, 0);
      await scheduler.shutdown();

      expect(
        scheduler.persistenceFault,
        isA<TaskPersistenceStalledException>(),
      );
      expect(scheduler.activeCount, 0);
      expect(worker.acquireCalls, 0);
      expect(revisionCalls, 1);

      releaseRevision.complete();
      await tester.pump();
      await controller.whenPersistenceQuiesced;
      await tester.pump();
      expect(revisionCalls, 1);
    },
  );

  testWidgets(
    'TaskScheduler releases lease and workspace gate after stalled claim',
    (tester) async {
      final store = _MemoryTaskStore(
        TaskInboxSnapshot(
          updatedAt: DateTime(2026, 7, 8, 9),
          tasks: [_task(id: 'task-1', createdAt: DateTime(2026, 7, 8, 9))],
        ),
      );
      final controller = TaskInboxController(
        repository: store,
        idGenerator: _DeterministicIds().next,
        persistenceWatchdog: _testPersistenceWatchdog,
      );
      addTearDown(controller.dispose);
      await controller.load();
      final claimStarted = Completer<void>();
      final releaseClaim = Completer<void>();
      var claimCalls = 0;
      store.beforeOperation = (operation) async {
        if (operation != 'claimTask') return;
        claimCalls += 1;
        if (!claimStarted.isCompleted) claimStarted.complete();
        await releaseClaim.future;
      };
      final gate = WorkspaceExecutionGate();
      final worker = _ReservableRecordingTaskWorker(controller);
      final scheduler = TaskScheduler(
        taskController: controller,
        worker: worker,
        workspaceGate: gate,
      );

      await scheduler.start();
      await _pumpWidgetUntil(tester, () => claimStarted.isCompleted);
      expect(gate.ownerFor('/workspace/app'), 'task-1');
      await tester.pump(_testPersistenceWatchdog);
      await _pumpWidgetUntil(
        tester,
        () =>
            scheduler.activeCount == 0 &&
            worker.releaseCalls == 1 &&
            !gate.isLocked('/workspace/app'),
      );

      expect(
        scheduler.persistenceFault,
        isA<TaskPersistenceStalledException>(),
      );
      expect(scheduler.activeCount, 0);
      expect(gate.isLocked('/workspace/app'), isFalse);
      expect(worker.acquireCalls, 1);
      expect(worker.releaseCalls, 1);
      expect(worker.lifecycle, ['release']);
      expect(claimCalls, 1);
      await scheduler.shutdown();
      expect(worker.lifecycle, ['release', 'dispose']);

      releaseClaim.complete();
      await tester.pump();
      await controller.whenPersistenceQuiesced;
      expect(controller.runs, isEmpty);
      expect(controller.taskById('task-1')?.status, TaskStatus.queued);
    },
  );

  testWidgets(
    'persistence fault cancels other active runs and releases all capacity',
    (tester) async {
      final now = DateTime(2026, 7, 8, 9);
      final store = _StallTaskAUpdateStore(
        TaskInboxSnapshot(
          updatedAt: now,
          tasks: [
            _task(id: 'task-a', createdAt: now, workspacePath: '/workspace/a'),
            _task(id: 'task-b', createdAt: now, workspacePath: '/workspace/b'),
          ],
        ),
      );
      final controller = TaskInboxController(
        repository: store,
        idGenerator: _DeterministicIds().next,
        persistenceWatchdog: _testPersistenceWatchdog,
      );
      addTearDown(controller.dispose);
      final worker = _ConcurrentFaultWorker(controller);
      final gate = WorkspaceExecutionGate();
      final faults = <TaskPersistenceStalledException>[];
      final scheduler = TaskScheduler(
        taskController: controller,
        worker: worker,
        workspaceGate: gate,
        maxConcurrentTasks: 2,
        onPersistenceFault: faults.add,
      );

      await scheduler.start();
      await _pumpWidgetUntil(tester, () => worker.bothRunsStarted.isCompleted);
      await _pumpWidgetUntil(tester, () => store.updateStarted.isCompleted);
      await tester.pump(_testPersistenceWatchdog);
      await _pumpWidgetUntil(
        tester,
        () =>
            scheduler.activeCount == 0 &&
            worker.releaseCalls == 2 &&
            !gate.isLocked('/workspace/a') &&
            !gate.isLocked('/workspace/b'),
      );

      expect(faults, hasLength(1));
      expect(worker.cancelCalls, 1);
      expect(worker.releaseCalls, 2);
      expect(scheduler.activeCount, 0);
      expect(gate.isLocked('/workspace/a'), isFalse);
      expect(gate.isLocked('/workspace/b'), isFalse);
      await scheduler.shutdown();

      store.releaseUpdate();
      await tester.pump();
      await controller.whenPersistenceQuiesced;
    },
  );

  testWidgets(
    'externally observed refresh fault cancels an active scheduler run',
    (tester) async {
      final now = DateTime(2026, 7, 8, 9);
      final store = _MemoryTaskStore(
        TaskInboxSnapshot(
          updatedAt: now,
          tasks: [
            _task(id: 'task-b', createdAt: now, workspacePath: '/workspace/b'),
          ],
        ),
      );
      final controller = TaskInboxController(
        repository: store,
        idGenerator: _DeterministicIds().next,
        persistenceWatchdog: _testPersistenceWatchdog,
      );
      addTearDown(controller.dispose);
      final worker = _ConcurrentFaultWorker(controller);
      final scheduler = TaskScheduler(
        taskController: controller,
        worker: worker,
      );
      await scheduler.start();
      await _pumpWidgetUntil(tester, () => worker.firstRunStarted.isCompleted);
      final revisionStarted = Completer<void>();
      final releaseRevision = Completer<void>();
      store.beforeOperation = (operation) async {
        if (operation != 'revision') return;
        if (!revisionStarted.isCompleted) revisionStarted.complete();
        await releaseRevision.future;
      };

      final refreshResult = controller.refreshIfChanged().then<Object?>(
        (_) => null,
        onError: (Object error, StackTrace _) => error,
      );
      await _pumpWidgetUntil(tester, () => revisionStarted.isCompleted);
      await tester.pump(_testPersistenceWatchdog);
      await tester.pump();
      final refreshError = await refreshResult;
      expect(refreshError, isA<TaskPersistenceStalledException>());
      scheduler.handlePersistenceFault(
        refreshError! as TaskPersistenceStalledException,
      );
      await _pumpWidgetUntil(
        tester,
        () => scheduler.activeCount == 0 && worker.releaseCalls == 1,
      );

      expect(worker.cancelCalls, 1);
      expect(scheduler.persistenceFault, isNotNull);
      await scheduler.shutdown();
      releaseRevision.complete();
      await tester.pump();
      await controller.whenPersistenceQuiesced;
    },
  );

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
    await _pumpEventQueue();
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

class _ReservableRecordingTaskWorker
    implements
        ReservableTaskWorker,
        CancellableTaskWorker,
        DisposableTaskWorker,
        ResettableTaskWorker,
        AuthenticatableTaskWorker {
  _ReservableRecordingTaskWorker(this.controller);

  final TaskInboxController controller;
  final List<String> startedTaskIds = <String>[];
  final Map<String, Completer<void>> _completions = <String, Completer<void>>{};
  final List<String> lifecycle = <String>[];
  final List<String> resetAgentNames = <String>[];
  bool acceptingLeases = true;
  bool _leased = false;
  Object? runError;
  int acquireCalls = 0;
  int releaseCalls = 0;
  int authenticateCalls = 0;

  @override
  Future<void> cancelActive() async {}

  @override
  Future<void> dispose() async {
    lifecycle.add('dispose');
  }

  @override
  Future<void> resetAgent(String agentName) async {
    resetAgentNames.add(agentName);
  }

  @override
  Future<bool> authenticateAgent(String agentName, String methodId) async {
    authenticateCalls += 1;
    return true;
  }

  @override
  Future<TaskWorkerLease?> tryAcquire(TaskRecord task) async {
    acquireCalls += 1;
    if (!acceptingLeases || _leased) return null;
    _leased = true;
    return _RecordingWorkerLease(this);
  }

  @override
  Future<TaskRecord> run(TaskRecord task) {
    throw StateError('Scheduler must use the reserved worker lease.');
  }

  Future<TaskRecord> runLeased(TaskRecord task) async {
    startedTaskIds.add(task.id);
    final error = runError;
    if (error != null) throw error;
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

  void release() {
    _leased = false;
    releaseCalls += 1;
    lifecycle.add('release');
  }
}

class _RecordingWorkerLease implements TaskWorkerLease {
  _RecordingWorkerLease(this.worker);

  final _ReservableRecordingTaskWorker worker;
  bool _released = false;

  @override
  Future<TaskRecord> run(TaskRecord task) => worker.runLeased(task);

  @override
  Future<void> release() async {
    if (_released) return;
    _released = true;
    worker.release();
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

class _AuthFailOnceTaskWorker implements TaskWorker {
  _AuthFailOnceTaskWorker(
    this.controller, {
    required this.onAuthenticationRequired,
  });

  final TaskInboxController controller;
  final void Function() onAuthenticationRequired;
  final List<String> startedTaskIds = <String>[];
  final Map<String, Completer<void>> _completions = <String, Completer<void>>{};

  @override
  Future<TaskRecord> run(TaskRecord task) async {
    startedTaskIds.add(task.id);
    final runId = task.currentRunId!;
    if (startedTaskIds.length == 1) {
      onAuthenticationRequired();
      await controller.updateRun(
        runId,
        status: TaskStatus.failed,
        endedAt: DateTime(2026, 7, 8, 10),
        error: 'authRequired: login required',
      );
      return controller.updateTask(
        task.id,
        status: TaskStatus.failed,
        error: 'authRequired: login required',
      );
    }

    final completion = Completer<void>();
    _completions[task.id] = completion;
    await controller.updateRun(runId, status: TaskStatus.running);
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

class _StallTaskAUpdateStore extends MemoryTaskRepository {
  _StallTaskAUpdateStore(super.snapshot);

  final Completer<void> updateStarted = Completer<void>();
  final Completer<void> _updateRelease = Completer<void>();

  @override
  Future<TaskRecord> updateTask(
    TaskRecord task, {
    required TaskRecord expected,
  }) async {
    if (task.id == 'task-a' && task.status == TaskStatus.running) {
      if (!updateStarted.isCompleted) updateStarted.complete();
      await _updateRelease.future;
    }
    return super.updateTask(task, expected: expected);
  }

  void releaseUpdate() {
    if (!_updateRelease.isCompleted) _updateRelease.complete();
  }
}

class _ConcurrentFaultWorker
    implements
        ReservableTaskWorker,
        CancellableTaskWorker,
        DisposableTaskWorker {
  _ConcurrentFaultWorker(this.controller);

  final TaskInboxController controller;
  final Completer<void> firstRunStarted = Completer<void>();
  final Completer<void> bothRunsStarted = Completer<void>();
  final Completer<void> _cancelled = Completer<void>();
  final Set<String> _leasedTaskIds = <String>{};
  final Set<String> _startedTaskIds = <String>{};
  int cancelCalls = 0;
  int releaseCalls = 0;

  @override
  Future<void> cancelActive() async {
    cancelCalls += 1;
    if (!_cancelled.isCompleted) _cancelled.complete();
  }

  @override
  Future<void> dispose() async {}

  @override
  Future<TaskWorkerLease?> tryAcquire(TaskRecord task) async {
    if (!_leasedTaskIds.add(task.id)) return null;
    return _ConcurrentFaultLease(this, task.id);
  }

  @override
  Future<TaskRecord> run(TaskRecord task) {
    throw StateError('Scheduler must use the reserved worker lease.');
  }

  Future<TaskRecord> runLeased(TaskRecord task) async {
    _startedTaskIds.add(task.id);
    if (!firstRunStarted.isCompleted) firstRunStarted.complete();
    if (_startedTaskIds.length == 2 && !bothRunsStarted.isCompleted) {
      bothRunsStarted.complete();
    }
    if (task.id == 'task-a') {
      await bothRunsStarted.future;
      return controller.updateTaskStatus(task.id, TaskStatus.running);
    }
    await _cancelled.future;
    throw StateError('Concurrent task cancelled after persistence fault.');
  }

  void release(String taskId) {
    if (!_leasedTaskIds.remove(taskId)) return;
    releaseCalls += 1;
  }
}

class _ConcurrentFaultLease implements TaskWorkerLease {
  _ConcurrentFaultLease(this.worker, this.taskId);

  final _ConcurrentFaultWorker worker;
  final String taskId;
  bool _released = false;

  @override
  Future<TaskRecord> run(TaskRecord task) => worker.runLeased(task);

  @override
  Future<void> release() async {
    if (_released) return;
    _released = true;
    worker.release(taskId);
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
  Future<TaskClaim?> claimTaskWithMetadata(
    TaskRecord expectedTask,
    TaskRunRecord run, {
    required TaskEventRecord dispatchEvent,
    WorkspaceResource? expectedResource,
    required Map<String, Object?> claimedMetadata,
  }) async {
    claimCalls += 1;
    if (claimCalls != 1) {
      return super.claimTaskWithMetadata(
        expectedTask,
        run,
        dispatchEvent: dispatchEvent,
        expectedResource: expectedResource,
        claimedMetadata: claimedMetadata,
      );
    }
    final startedAt = run.startedAt;
    await super.claimTaskWithMetadata(
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
      claimedMetadata: claimedMetadata,
    );
    _externalClaimed = true;
    return null;
  }
}

class _ConflictOnceClaimStore extends MemoryTaskRepository {
  _ConflictOnceClaimStore(super.snapshot);

  int claimCalls = 0;

  @override
  Future<TaskClaim?> claimTaskWithMetadata(
    TaskRecord expectedTask,
    TaskRunRecord run, {
    required TaskEventRecord dispatchEvent,
    WorkspaceResource? expectedResource,
    required Map<String, Object?> claimedMetadata,
  }) {
    claimCalls += 1;
    if (claimCalls == 1) {
      throw const TaskRepositoryConflict('simulated run id collision');
    }
    return super.claimTaskWithMetadata(
      expectedTask,
      run,
      dispatchEvent: dispatchEvent,
      expectedResource: expectedResource,
      claimedMetadata: claimedMetadata,
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

class _MutableClock {
  _MutableClock(this.current);

  DateTime current;

  DateTime now() => current;
}

class _FakeTaskWakeTimerFactory {
  _FakeTaskWakeTimerFactory(this.clock);

  final _MutableClock clock;
  final List<_FakeTaskWakeTimer> _timers = <_FakeTaskWakeTimer>[];
  int callbackCount = 0;
  int _nextSequence = 0;

  int get createdCount => _timers.length;
  int get activeCount => _timers.where((timer) => timer.isActive).length;
  int get cancelledCount => _timers.where((timer) => timer.wasCancelled).length;

  _FakeTaskWakeTimer call(Duration delay, void Function() callback) {
    final timer = _FakeTaskWakeTimer(
      deadline: clock.current.add(delay),
      sequence: _nextSequence++,
      callback: () {
        callbackCount += 1;
        callback();
      },
    );
    _timers.add(timer);
    return timer;
  }

  Future<void> elapse(Duration duration) async {
    final target = clock.current.add(duration);
    while (true) {
      final due =
          _timers
              .where(
                (timer) => timer.isActive && !timer.deadline.isAfter(target),
              )
              .toList(growable: false)
            ..sort((left, right) {
              final deadline = left.deadline.compareTo(right.deadline);
              return deadline != 0
                  ? deadline
                  : left.sequence.compareTo(right.sequence);
            });
      if (due.isEmpty) break;
      final next = due.first;
      if (next.deadline.isAfter(clock.current)) {
        clock.current = next.deadline;
      }
      next.fire();
      await _pumpEventQueue();
    }
    clock.current = target;
  }
}

class _FakeTaskWakeTimer implements TaskWakeTimer {
  _FakeTaskWakeTimer({
    required this.deadline,
    required this.sequence,
    required this.callback,
  });

  final DateTime deadline;
  final int sequence;
  final void Function() callback;
  bool _active = true;
  bool wasCancelled = false;

  @override
  bool get isActive => _active;

  @override
  void cancel() {
    if (!_active) return;
    _active = false;
    wasCancelled = true;
  }

  void fire() {
    if (!_active) return;
    _active = false;
    callback();
  }
}

Future<void> _pumpEventQueue() async {
  for (var index = 0; index < 20; index += 1) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<void> _pumpWidgetUntil(
  WidgetTester tester,
  bool Function() condition, {
  int attempts = 200,
}) async {
  for (var attempt = 0; attempt < attempts; attempt += 1) {
    if (condition()) return;
    await tester.pump();
  }
  fail('Widget condition was not met before timeout.');
}

Future<void> _waitUntil(bool Function() condition, {int attempts = 400}) async {
  for (var attempt = 0; attempt < attempts; attempt += 1) {
    if (condition()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('Condition was not met before timeout.');
}
