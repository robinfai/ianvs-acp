import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/tasks/task_data_sanitizer.dart';
import 'package:ianvs_acp/tasks/task_inbox_controller.dart';
import 'package:ianvs_acp/tasks/task_inbox_snapshot.dart';
import 'package:ianvs_acp/tasks/task_record.dart';
import 'package:ianvs_acp/tasks/task_repository.dart';

import '../support/memory_task_repository.dart';

void main() {
  test('TaskInboxController coalesces concurrent loads', () async {
    final store = _MemoryTaskStore();
    final controller = TaskInboxController(repository: store);
    addTearDown(controller.dispose);

    final first = controller.load();
    final second = controller.load();

    expect(identical(first, second), isTrue);
    await Future.wait([first, second]);
    expect(store.loadCount, 1);
  });

  test(
    'force raw payload purge is serialized and reloads the snapshot',
    () async {
      final createdAt = DateTime.utc(2030, 1, 2);
      final store = _MemoryTaskStore(
        TaskInboxSnapshot(
          updatedAt: createdAt,
          tasks: <TaskRecord>[
            TaskRecord(
              id: 'task-1',
              title: 'Keep task',
              description: '',
              workspacePath: '/workspace/app',
              agentName: 'Codex',
              status: TaskStatus.running,
              priority: TaskPriority.normal,
              createdAt: createdAt,
              updatedAt: createdAt,
              currentRunId: 'run-1',
              summary: 'Keep summary',
              metadata: const <String, Object?>{'keep': true},
            ),
          ],
          runs: <TaskRunRecord>[
            TaskRunRecord(
              id: 'run-1',
              taskId: 'task-1',
              attempt: 1,
              status: TaskStatus.running,
              startedAt: createdAt,
              promptSnapshot: 'raw prompt',
            ),
          ],
          events: <TaskEventRecord>[
            TaskEventRecord(
              id: 'event-1',
              taskId: 'task-1',
              runId: 'run-1',
              kind: TaskEventKind.tool,
              text: 'Keep event text',
              createdAt: createdAt,
              metadata: const <String, Object?>{'raw': 'secret'},
            ),
          ],
          artifacts: <ArtifactRecord>[
            ArtifactRecord(
              id: 'artifact-1',
              taskId: 'task-1',
              runId: 'run-1',
              kind: ArtifactKind.gitDiff,
              title: 'src/main.dart',
              createdAt: createdAt,
              path: 'src/main.dart',
              contentPreview: 'raw diff',
              metadata: const <String, Object?>{'raw_payload': true},
            ),
          ],
        ),
      );
      final controller = TaskInboxController(
        repository: store,
        clock: () => DateTime.utc(2026, 7, 11),
      );
      addTearDown(controller.dispose);
      await controller.load();

      final result = await controller.purgeRawPayloads(force: true);

      expect(result.totalPurged, 3);
      expect(store.rawPayloadPurgeCount, 1);
      expect(controller.tasks.single.summary, 'Keep summary');
      expect(controller.tasks.single.metadata, {'keep': true});
      expect(controller.runs.single.promptSnapshot, isNull);
      expect(controller.events.single.text, 'Keep event text');
      expect(controller.events.single.metadata, isEmpty);
      expect(controller.artifacts.single.title, 'src/main.dart');
      expect(controller.artifacts.single.path, 'src/main.dart');
      expect(controller.artifacts.single.contentPreview, isNull);
      expect(controller.artifacts.single.metadata, isEmpty);
    },
  );

  test('failed repository write does not mutate the local snapshot', () async {
    final store = _MemoryTaskStore();
    final controller = TaskInboxController(
      repository: store,
      clock: () => DateTime(2026, 7, 7, 8),
      idGenerator: (_) => 'task-1',
    );
    addTearDown(controller.dispose);
    var notifications = 0;
    controller.addListener(() => notifications += 1);
    await controller.load();
    store.beforeOperation = (operation) async {
      if (operation == 'insertTask') throw StateError('disk full');
    };

    await expectLater(
      controller.createTask(
        title: 'Must not leak',
        description: '',
        workspacePath: '/workspace/app',
        agentName: 'Codex',
      ),
      throwsStateError,
    );

    expect(controller.tasks, isEmpty);
    expect(store.currentSnapshot.tasks, isEmpty);
    expect(notifications, 1);
  });

  test(
    'refresh sees another controller write and stale updates conflict',
    () async {
      final createdAt = DateTime(2026, 7, 7, 8);
      final store = _MemoryTaskStore(
        TaskInboxSnapshot(
          updatedAt: createdAt,
          tasks: [
            TaskRecord(
              id: 'task-1',
              title: 'Initial',
              description: '',
              workspacePath: '/workspace/app',
              agentName: 'Codex',
              status: TaskStatus.inbox,
              priority: TaskPriority.normal,
              createdAt: createdAt,
              updatedAt: createdAt,
            ),
          ],
        ),
      );
      final first = TaskInboxController(
        repository: store,
        clock: () => DateTime(2026, 7, 7, 9),
      );
      final second = TaskInboxController(
        repository: store,
        clock: () => DateTime(2026, 7, 7, 10),
      );
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      await Future.wait([first.load(), second.load()]);

      await first.updateTask('task-1', priority: TaskPriority.high);
      await expectLater(
        second.updateTask('task-1', title: 'Renamed'),
        throwsA(isA<TaskRepositoryConflict>()),
      );
      expect(second.taskById('task-1')?.title, 'Initial');

      expect(await second.refreshIfChanged(), isTrue);
      final updated = await second.updateTask('task-1', title: 'Renamed');
      expect(updated.title, 'Renamed');
      expect(updated.priority, TaskPriority.high);
    },
  );

  test('one controller composes concurrent writes in call order', () async {
    final createdAt = DateTime(2026, 7, 7, 8);
    final store = _MemoryTaskStore(
      TaskInboxSnapshot(
        updatedAt: createdAt,
        tasks: [
          TaskRecord(
            id: 'task-1',
            title: 'Initial',
            description: '',
            workspacePath: '/workspace/app',
            agentName: 'Codex',
            status: TaskStatus.inbox,
            priority: TaskPriority.normal,
            createdAt: createdAt,
            updatedAt: createdAt,
          ),
        ],
      ),
    );
    var now = DateTime(2026, 7, 7, 9);
    final controller = TaskInboxController(repository: store, clock: () => now);
    addTearDown(controller.dispose);
    await controller.load();

    final rename = controller.updateTask('task-1', title: 'Renamed');
    now = DateTime(2026, 7, 7, 10);
    final describe = controller.updateTask(
      'task-1',
      description: 'Composed change',
    );
    await Future.wait([rename, describe]);

    final task = controller.taskById('task-1')!;
    expect(task.title, 'Renamed');
    expect(task.description, 'Composed change');
  });

  test(
    'listener-scheduled writes remain queued and settle tracks them',
    () async {
      final createdAt = DateTime(2026, 7, 7, 8);
      final store = _MemoryTaskStore(
        TaskInboxSnapshot(
          updatedAt: createdAt,
          tasks: [
            TaskRecord(
              id: 'task-1',
              title: 'Initial',
              description: '',
              workspacePath: '/workspace/app',
              agentName: 'Codex',
              status: TaskStatus.inbox,
              priority: TaskPriority.normal,
              createdAt: createdAt,
              updatedAt: createdAt,
            ),
          ],
        ),
      );
      final controller = TaskInboxController(repository: store);
      addTearDown(controller.dispose);
      await controller.load();
      final listenerWriteStarted = Completer<void>();
      final releaseListenerWrite = Completer<void>();
      var updateCount = 0;
      store.beforeOperation = (operation) async {
        if (operation != 'updateTask') return;
        updateCount += 1;
        if (updateCount != 3) return;
        listenerWriteStarted.complete();
        await releaseListenerWrite.future;
      };
      final listenerWrite = Completer<void>();
      var scheduled = false;
      controller.addListener(() {
        if (scheduled || controller.taskById('task-1')?.title != 'Renamed') {
          return;
        }
        scheduled = true;
        scheduleMicrotask(() async {
          try {
            await controller.updateTask(
              'task-1',
              description: 'Listener update',
            );
            listenerWrite.complete();
          } on Object catch (error, stackTrace) {
            listenerWrite.completeError(error, stackTrace);
          }
        });
      });

      final rename = controller.updateTask('task-1', title: 'Renamed');
      final reprioritize = controller.updateTask(
        'task-1',
        priority: TaskPriority.high,
      );
      await Future.wait([rename, reprioritize]);
      await listenerWriteStarted.future;
      var settled = false;
      final settling = controller.settle().then((_) => settled = true);
      await Future<void>.delayed(Duration.zero);
      expect(settled, isFalse);

      releaseListenerWrite.complete();
      await Future.wait([listenerWrite.future, settling]);
      expect(settled, isTrue);

      final task = controller.taskById('task-1')!;
      expect(task.title, 'Renamed');
      expect(task.description, 'Listener update');
      expect(task.priority, TaskPriority.high);
    },
  );

  test('settle waits for an in-flight repository write', () async {
    final createdAt = DateTime(2026, 7, 7, 8);
    final writeStarted = Completer<void>();
    final releaseWrite = Completer<void>();
    final store = _MemoryTaskStore(
      TaskInboxSnapshot(
        updatedAt: createdAt,
        tasks: [
          TaskRecord(
            id: 'task-1',
            title: 'Initial',
            description: '',
            workspacePath: '/workspace/app',
            agentName: 'Codex',
            status: TaskStatus.inbox,
            priority: TaskPriority.normal,
            createdAt: createdAt,
            updatedAt: createdAt,
          ),
        ],
      ),
    );
    final controller = TaskInboxController(repository: store);
    addTearDown(controller.dispose);
    await controller.load();
    store.beforeOperation = (operation) async {
      if (operation != 'updateTask') return;
      if (!writeStarted.isCompleted) writeStarted.complete();
      await releaseWrite.future;
    };

    final update = controller.updateTask('task-1', title: 'Updated');
    await writeStarted.future;
    var settled = false;
    final settling = controller.settle().then((_) => settled = true);
    await Future<void>.delayed(Duration.zero);
    expect(settled, isFalse);

    releaseWrite.complete();
    await Future.wait([update, settling]);
    expect(settled, isTrue);
  });

  test(
    'stalled write quarantines controller and never starts queued writes',
    () async {
      final createdAt = DateTime(2026, 7, 7, 8);
      final store = _MemoryTaskStore(
        TaskInboxSnapshot(
          updatedAt: createdAt,
          tasks: [
            TaskRecord(
              id: 'task-1',
              title: 'Initial',
              description: '',
              workspacePath: '/workspace/app',
              agentName: 'Codex',
              status: TaskStatus.inbox,
              priority: TaskPriority.normal,
              createdAt: createdAt,
              updatedAt: createdAt,
            ),
          ],
        ),
      );
      final writeStarted = Completer<void>();
      final releaseWrite = Completer<void>();
      var updateCalls = 0;
      store.beforeOperation = (operation) async {
        if (operation != 'updateTask') return;
        updateCalls += 1;
        if (!writeStarted.isCompleted) writeStarted.complete();
        await releaseWrite.future;
      };
      final controller = TaskInboxController(
        repository: store,
        clock: () => DateTime(2026, 7, 7, 9),
        persistenceWatchdog: const Duration(milliseconds: 20),
      );
      addTearDown(controller.dispose);
      await controller.load();
      var notifications = 0;
      controller.addListener(() => notifications += 1);

      final first = controller.updateTask('task-1', title: 'Late commit');
      await writeStarted.future;
      final second = controller.updateTask(
        'task-1',
        description: 'Must never start',
      );
      final firstExpectation = expectLater(
        first,
        throwsA(isA<TaskPersistenceStalledException>()),
      );
      final secondExpectation = expectLater(
        second,
        throwsA(isA<TaskPersistenceStalledException>()),
      );
      await Future.wait([firstExpectation, secondExpectation]);
      expect(controller.isPersistenceFaulted, isTrue);
      expect(controller.isPersistenceQuiesced, isFalse);
      expect(controller.persistenceFault?.operation, 'updateTask');
      expect(controller.persistenceFault?.generation, 1);
      expect(updateCalls, 1);
      expect(controller.taskById('task-1')?.title, 'Initial');
      expect(controller.taskById('task-1')?.description, isEmpty);
      expect(notifications, 0);

      await expectLater(
        controller.updateTask('task-1', priority: TaskPriority.high),
        throwsA(isA<TaskPersistenceStalledException>()),
      );
      await expectLater(
        controller.settle(),
        throwsA(isA<TaskPersistenceStalledException>()),
      );
      expect(updateCalls, 1);

      releaseWrite.complete();
      await controller.whenPersistenceQuiesced;
      expect(controller.isPersistenceQuiesced, isTrue);
      expect(controller.taskById('task-1')?.title, 'Initial');
      expect(notifications, 0);

      final recovered = TaskInboxController(repository: store);
      addTearDown(recovered.dispose);
      await recovered.load();
      expect(recovered.taskById('task-1')?.title, 'Late commit');
      expect(recovered.taskById('task-1')?.description, isEmpty);
    },
  );

  test(
    'stalled initial load faults without starting a replacement load',
    () async {
      final store = _MemoryTaskStore();
      final loadStarted = Completer<void>();
      final releaseLoad = Completer<void>();
      store.beforeOperation = (operation) async {
        if (operation != 'load') return;
        if (!loadStarted.isCompleted) loadStarted.complete();
        await releaseLoad.future;
      };
      final controller = TaskInboxController(
        repository: store,
        persistenceWatchdog: const Duration(milliseconds: 20),
      );
      addTearDown(controller.dispose);

      final first = controller.load();
      await loadStarted.future;
      await expectLater(first, throwsA(isA<TaskPersistenceStalledException>()));
      await expectLater(
        controller.load(),
        throwsA(isA<TaskPersistenceStalledException>()),
      );
      expect(store.loadCount, 1);
      expect(controller.isPersistenceQuiesced, isFalse);

      releaseLoad.complete();
      await controller.whenPersistenceQuiesced;
      expect(controller.isPersistenceQuiesced, isTrue);
    },
  );

  test('failed atomic run creation leaves task and runs unchanged', () async {
    final createdAt = DateTime(2026, 7, 7, 8);
    final store = _MemoryTaskStore(
      TaskInboxSnapshot(
        updatedAt: createdAt,
        tasks: [
          TaskRecord(
            id: 'task-1',
            title: 'Queued',
            description: '',
            workspacePath: '/workspace/app',
            agentName: 'Codex',
            status: TaskStatus.queued,
            priority: TaskPriority.normal,
            createdAt: createdAt,
            updatedAt: createdAt,
          ),
        ],
      ),
    );
    final controller = TaskInboxController(
      repository: store,
      clock: () => DateTime(2026, 7, 7, 9),
      idGenerator: (_) => 'run-1',
    );
    addTearDown(controller.dispose);
    await controller.load();
    store.beforeOperation = (operation) async {
      if (operation == 'createRun') throw StateError('write failed');
    };

    await expectLater(controller.createRun(taskId: 'task-1'), throwsStateError);

    expect(controller.taskById('task-1')?.status, TaskStatus.queued);
    expect(controller.taskById('task-1')?.currentRunId, isNull);
    expect(controller.runs, isEmpty);
  });

  test('TaskInboxController creates inbox task and persists it', () async {
    var now = DateTime(2026, 7, 7, 8);
    final store = _MemoryTaskStore();
    final controller = TaskInboxController(
      repository: store,
      clock: () => now,
      idGenerator: (_) => 'task-1',
    );
    addTearDown(controller.dispose);

    await controller.load();
    final task = await controller.createTask(
      title: '  Add inbox  ',
      description: '  Create local task store  ',
      workspacePath: '/workspace/app/',
      agentName: '  Codex  ',
      priority: TaskPriority.high,
    );

    expect(task.id, 'task-1');
    expect(task.title, 'Add inbox');
    expect(task.description, 'Create local task store');
    expect(task.workspacePath, '/workspace/app');
    expect(task.agentName, 'Codex');
    expect(task.status, TaskStatus.inbox);
    expect(task.priority, TaskPriority.high);
    expect(store.savedSnapshots, hasLength(1));
    expect(store.savedSnapshots.single.tasks.single.id, 'task-1');

    now = DateTime(2026, 7, 7, 9);
    final updated = await controller.updateTaskStatus(
      task.id,
      TaskStatus.running,
      summary: 'Started',
    );

    expect(updated.status, TaskStatus.running);
    expect(updated.summary, 'Started');
    expect(updated.updatedAt, now);
    expect(store.savedSnapshots, hasLength(2));
    expect(store.savedSnapshots.last.tasks.single.status, TaskStatus.running);
  });

  test(
    'TaskInboxController sanitizes persisted metadata and preserves assistant text',
    () async {
      final store = _MemoryTaskStore();
      final ids = _DeterministicIds();
      final controller = TaskInboxController(
        repository: store,
        idGenerator: ids.next,
        dataSanitizer: const TaskDataSanitizer(maxMetadataBytes: 32),
      );
      addTearDown(controller.dispose);
      await controller.load();

      final created = await controller.createTask(
        title: 'Metadata task',
        description: '',
        workspacePath: '/workspace/app',
        agentName: 'Codex',
        metadata: const <String, Object?>{'small': true},
      );
      expect(created.metadata, const <String, Object?>{'small': true});

      final updated = await controller.updateTask(
        created.id,
        metadata: <String, Object?>{'large': 'x' * 100},
      );
      expect(updated.metadata['truncated'], isTrue);
      expect(updated.metadata['original_bytes'], greaterThan(32));
      expect(updated.metadata['sha256'], hasLength(64));

      final run = await controller.createRun(taskId: created.id);
      final assistant = await controller.appendEvent(
        taskId: created.id,
        runId: run.id,
        kind: TaskEventKind.assistant,
        text: '  preserved  ',
        metadata: <String, Object?>{'large': 'y' * 100},
      );
      expect(assistant.text, '  preserved  ');
      expect(assistant.metadata['truncated'], isTrue);
      expect(assistant.metadata['sha256'], hasLength(64));

      final system = await controller.appendEvent(
        taskId: created.id,
        runId: run.id,
        kind: TaskEventKind.system,
        text: '  normalized  ',
        metadata: const <String, Object?>{'small': true},
      );
      expect(system.text, 'normalized');
      expect(system.metadata, const <String, Object?>{'small': true});

      final externalMetadata = <String, Object?>{'large': 'z' * 100};
      final artifacts = await controller.replaceArtifactsForRun(
        taskId: created.id,
        runId: run.id,
        artifacts: <ArtifactRecord>[
          ArtifactRecord(
            id: 'artifact-external',
            taskId: created.id,
            runId: run.id,
            kind: ArtifactKind.file,
            title: 'Authorization:Bearer artifact-title-secret',
            path: 'Authorization:Bearer artifact-path-secret',
            createdAt: DateTime(2026, 7, 11, 8),
            metadata: externalMetadata,
          ),
        ],
      );
      expect(artifacts.single.metadata, isNot(same(externalMetadata)));
      expect(artifacts.single.title, taskDataRedactedValue);
      expect(artifacts.single.path, taskDataRedactedValue);
      expect(artifacts.single.metadata['truncated'], isTrue);
      expect(artifacts.single.metadata['sha256'], hasLength(64));
      expect(
        store.currentSnapshot.artifacts.single.metadata,
        artifacts.single.metadata,
      );
      expect(controller.artifacts.single.metadata, artifacts.single.metadata);
    },
  );

  test('TaskInboxController sanitizes all persisted free text', () async {
    final store = _MemoryTaskStore();
    final controller = TaskInboxController(
      repository: store,
      idGenerator: (_) => 'task-1',
    );
    addTearDown(controller.dispose);
    await controller.load();

    final created = await controller.createTask(
      title: 'Authorization:Bearer title-secret',
      description: '--header=Authorization:Bearer description-secret',
      workspacePath: '/workspace/app',
      agentName: 'Codex',
    );
    expect(created.title, taskDataRedactedValue);
    expect(created.description, taskDataRedactedValue);

    final updated = await controller.updateTask(
      created.id,
      title: 'Bearer updated-title-secret',
      description: 'Authorization:Bearer updated-description-secret',
    );
    expect(updated.title, taskDataRedactedValue);
    expect(updated.description, taskDataRedactedValue);

    final review = _reviewSnapshot().copyWith(
      approvals: <ApprovalRequestRecord>[
        ApprovalRequestRecord(
          id: 'approval-1',
          taskId: 'task-1',
          runId: 'run-1',
          kind: ApprovalKind.export,
          status: ApprovalStatus.pending,
          createdAt: DateTime(2026, 7, 7, 8),
          destination: 'Authorization:Bearer destination-secret',
          riskSummary: 'Bearer risk-secret',
          rationale: 'Bearer old-rationale-secret',
        ),
      ],
    );
    final approvalStore = _MemoryTaskStore(review);
    final approvalController = TaskInboxController(repository: approvalStore);
    addTearDown(approvalController.dispose);
    await approvalController.load();

    final resolved = await approvalController.resolveApproval(
      'approval-1',
      ApprovalStatus.approved,
      rationale: 'Authorization:Bearer new-rationale-secret',
    );
    expect(resolved.destination, taskDataRedactedValue);
    expect(resolved.riskSummary, taskDataRedactedValue);
    expect(resolved.rationale, taskDataRedactedValue);

    final persisted = jsonEncode(approvalStore.currentSnapshot.toJson());
    expect(persisted, isNot(contains('destination-secret')));
    expect(persisted, isNot(contains('risk-secret')));
    expect(persisted, isNot(contains('rationale-secret')));
  });

  test('claimTask caps metadata loaded from an older repository', () async {
    final createdAt = DateTime.utc(2026, 7, 11, 8);
    final store = _MemoryTaskStore(
      TaskInboxSnapshot(
        updatedAt: createdAt,
        tasks: <TaskRecord>[
          TaskRecord(
            id: 'legacy-task',
            title: 'Legacy metadata',
            description: '',
            workspacePath: '/workspace/app',
            agentName: 'Codex',
            status: TaskStatus.queued,
            priority: TaskPriority.normal,
            createdAt: createdAt,
            updatedAt: createdAt,
            metadata: <String, Object?>{'large': 'x' * 100},
          ),
        ],
      ),
    );
    final controller = TaskInboxController(
      repository: store,
      dataSanitizer: const TaskDataSanitizer(maxMetadataBytes: 32),
      idGenerator: (prefix) => '$prefix-1',
    );
    addTearDown(controller.dispose);
    await controller.load();

    final claim = await controller.claimTask(controller.tasks.single);

    expect(claim, isNotNull);
    expect(claim!.task.metadata['truncated'], isTrue);
    expect(claim.task.metadata['original_bytes'], greaterThan(32));
    expect(claim.task.metadata['sha256'], hasLength(64));
    expect(store.currentSnapshot.tasks.single.metadata, claim.task.metadata);
  });

  test(
    'TaskInboxController filters by status and normalized workspace',
    () async {
      final store = _MemoryTaskStore(
        TaskInboxSnapshot(
          updatedAt: DateTime(2026, 7, 7, 8),
          tasks: [
            TaskRecord(
              id: 'task-1',
              title: 'A',
              description: '',
              workspacePath: '/workspace/app',
              agentName: 'Codex',
              status: TaskStatus.inbox,
              priority: TaskPriority.normal,
              createdAt: DateTime(2026, 7, 7, 8),
              updatedAt: DateTime(2026, 7, 7, 8),
            ),
            TaskRecord(
              id: 'task-2',
              title: 'B',
              description: '',
              workspacePath: '/workspace/other',
              agentName: 'Codex',
              status: TaskStatus.done,
              priority: TaskPriority.normal,
              createdAt: DateTime(2026, 7, 7, 8),
              updatedAt: DateTime(2026, 7, 7, 8),
            ),
          ],
        ),
      );
      final controller = TaskInboxController(repository: store);
      addTearDown(controller.dispose);

      await controller.load();

      expect(
        controller.tasksForStatus(TaskStatus.inbox).map((task) => task.id),
        ['task-1'],
      );
      expect(
        controller.tasksForWorkspace('/workspace/app/').map((task) => task.id),
        ['task-1'],
      );
    },
  );

  test('TaskInboxController notifies listeners on load and changes', () async {
    final store = _MemoryTaskStore();
    final controller = TaskInboxController(
      repository: store,
      clock: () => DateTime(2026, 7, 7, 8),
      idGenerator: (_) => 'task-1',
    );
    addTearDown(controller.dispose);
    var notifications = 0;
    controller.addListener(() {
      notifications += 1;
    });

    await controller.load();
    expect(notifications, 1);

    await controller.createTask(
      title: 'Add inbox',
      description: '',
      workspacePath: '/workspace/app',
      agentName: 'Codex',
    );
    expect(notifications, 2);
  });

  test('TaskInboxController rejects duplicate generated ids', () async {
    final store = _MemoryTaskStore(
      TaskInboxSnapshot(
        updatedAt: DateTime(2026, 7, 7, 8),
        tasks: [
          TaskRecord(
            id: 'task-1',
            title: 'Existing',
            description: '',
            workspacePath: '/workspace/app',
            agentName: 'Codex',
            status: TaskStatus.inbox,
            priority: TaskPriority.normal,
            createdAt: DateTime(2026, 7, 7, 8),
            updatedAt: DateTime(2026, 7, 7, 8),
          ),
        ],
      ),
    );
    final controller = TaskInboxController(
      repository: store,
      idGenerator: (_) => 'task-1',
    );
    addTearDown(controller.dispose);

    await expectLater(
      controller.createTask(
        title: 'New',
        description: '',
        workspacePath: '/workspace/app',
        agentName: 'Codex',
      ),
      throwsStateError,
    );
  });

  test('TaskInboxController can clear nullable task fields', () async {
    final store = _MemoryTaskStore(
      TaskInboxSnapshot(
        updatedAt: DateTime(2026, 7, 7, 8),
        tasks: [
          TaskRecord(
            id: 'task-1',
            title: 'Existing',
            description: '',
            workspacePath: '/workspace/app',
            agentName: 'Codex',
            status: TaskStatus.running,
            priority: TaskPriority.normal,
            createdAt: DateTime(2026, 7, 7, 8),
            updatedAt: DateTime(2026, 7, 7, 8),
            sessionId: 'session-1',
            currentRunId: 'run-1',
            summary: 'Summary',
            error: 'Error',
          ),
        ],
      ),
    );
    final controller = TaskInboxController(
      repository: store,
      clock: () => DateTime(2026, 7, 7, 9),
    );
    addTearDown(controller.dispose);
    await controller.load();

    final task = await controller.updateTask(
      'task-1',
      status: TaskStatus.failed,
      sessionId: null,
      currentRunId: null,
      summary: null,
      error: null,
    );

    expect(task.status, TaskStatus.failed);
    expect(task.sessionId, isNull);
    expect(task.currentRunId, isNull);
    expect(task.summary, isNull);
    expect(task.error, isNull);
  });

  test('TaskInboxController replaces artifacts for a task run', () async {
    final snapshot = TaskInboxSnapshot(
      updatedAt: DateTime(2026, 7, 7, 8),
      tasks: [
        TaskRecord(
          id: 'task-1',
          title: 'Existing',
          description: '',
          workspacePath: '/workspace/app',
          agentName: 'Codex',
          status: TaskStatus.collectingArtifacts,
          priority: TaskPriority.normal,
          createdAt: DateTime(2026, 7, 7, 8),
          updatedAt: DateTime(2026, 7, 7, 8),
          currentRunId: 'run-1',
        ),
      ],
      runs: [
        TaskRunRecord(
          id: 'run-1',
          taskId: 'task-1',
          attempt: 1,
          status: TaskStatus.running,
          startedAt: DateTime(2026, 7, 7, 8),
        ),
      ],
      artifacts: [
        ArtifactRecord(
          id: 'old-artifact',
          taskId: 'task-1',
          runId: 'run-1',
          kind: ArtifactKind.gitStatus,
          title: 'Old status',
          createdAt: DateTime(2026, 7, 7, 8),
        ),
      ],
    );
    final store = _MemoryTaskStore(snapshot);
    final controller = TaskInboxController(
      repository: store,
      clock: () => DateTime(2026, 7, 7, 9),
    );
    addTearDown(controller.dispose);
    await controller.load();

    final artifacts = await controller.replaceArtifactsForRun(
      taskId: 'task-1',
      runId: 'run-1',
      artifacts: [
        ArtifactRecord(
          id: 'artifact-1',
          taskId: 'task-1',
          runId: 'run-1',
          kind: ArtifactKind.gitDiff,
          title: 'Git diff preview',
          createdAt: DateTime(2026, 7, 7, 9),
          contentPreview: '+after',
        ),
      ],
    );

    expect(artifacts.single.id, 'artifact-1');
    expect(controller.artifacts.map((artifact) => artifact.id), ['artifact-1']);
    expect(
      store.savedSnapshots.last.artifacts.single.title,
      'Git diff preview',
    );
    expect(store.savedSnapshots.last.updatedAt, DateTime(2026, 7, 7, 9));
  });

  test('TaskInboxController marks review task done locally', () async {
    final store = _MemoryTaskStore(_reviewSnapshot());
    final controller = TaskInboxController(
      repository: store,
      clock: () => DateTime(2026, 7, 7, 9),
    );
    addTearDown(controller.dispose);
    await controller.load();

    final task = await controller.markTaskDoneLocally('task-1');

    expect(task.status, TaskStatus.done);
    expect(controller.approvals, isEmpty);
    expect(controller.events.last.kind, TaskEventKind.review);
    expect(controller.events.last.text, 'Marked done locally.');
  });

  test(
    'TaskInboxController request changes and reject update review status',
    () async {
      final store = _MemoryTaskStore(_reviewSnapshot());
      final controller = TaskInboxController(
        repository: store,
        clock: () => DateTime(2026, 7, 7, 9),
      );
      addTearDown(controller.dispose);
      await controller.load();

      final changes = await controller.requestTaskChanges(
        'task-1',
        rationale: 'Tighten tests.',
      );
      expect(changes.status, TaskStatus.needsChanges);
      expect(changes.summary, 'Tighten tests.');

      await controller.updateTaskStatus('task-1', TaskStatus.needsHumanReview);
      final rejected = await controller.rejectTask('task-1');

      expect(rejected.status, TaskStatus.rejected);
      expect(rejected.summary, 'Task rejected.');
      expect(
        controller.events.where((event) => event.kind == TaskEventKind.review),
        hasLength(2),
      );
    },
  );

  test(
    'TaskInboxController reviews artifacts without creating export approval',
    () async {
      final store = _MemoryTaskStore(
        TaskInboxSnapshot(
          updatedAt: DateTime(2026, 7, 7, 8),
          tasks: [
            TaskRecord(
              id: 'task-1',
              title: 'Review artifacts',
              description: '',
              workspacePath: '/workspace/app',
              agentName: 'Codex',
              status: TaskStatus.needsHumanReview,
              priority: TaskPriority.normal,
              createdAt: DateTime(2026, 7, 7, 8),
              updatedAt: DateTime(2026, 7, 7, 8),
              currentRunId: 'run-1',
              sessionId: 'session-1',
            ),
          ],
          runs: [
            TaskRunRecord(
              id: 'run-1',
              taskId: 'task-1',
              attempt: 1,
              status: TaskStatus.needsHumanReview,
              startedAt: DateTime(2026, 7, 7, 8),
            ),
          ],
          artifacts: [
            ArtifactRecord(
              id: 'artifact-1',
              taskId: 'task-1',
              runId: 'run-1',
              kind: ArtifactKind.gitDiff,
              title: 'Safe diff',
              createdAt: DateTime(2026, 7, 7, 8),
            ),
            ArtifactRecord(
              id: 'artifact-2',
              taskId: 'task-1',
              runId: 'run-1',
              kind: ArtifactKind.outboxFile,
              title: 'Unsafe file',
              createdAt: DateTime(2026, 7, 7, 8),
            ),
            ArtifactRecord(
              id: 'artifact-3',
              taskId: 'task-1',
              runId: 'run-1',
              kind: ArtifactKind.testLog,
              title: 'Evidence log',
              createdAt: DateTime(2026, 7, 7, 8),
            ),
          ],
        ),
      );
      final controller = TaskInboxController(
        repository: store,
        clock: () => DateTime(2026, 7, 7, 9),
      );
      addTearDown(controller.dispose);
      await controller.load();

      final reviewed = await controller.reviewArtifactsForRun(
        taskId: 'task-1',
        runId: 'run-1',
        approvedArtifactIds: const ['artifact-1'],
        rejectedArtifactIds: const ['artifact-2'],
        rationale: 'Only the diff should leave the machine.',
      );

      expect(reviewed.map((artifact) => artifact.status), [
        ArtifactStatus.approved,
        ArtifactStatus.rejected,
        ArtifactStatus.reviewed,
      ]);
      expect(controller.events.single.kind, TaskEventKind.review);
      expect(controller.events.single.text, 'Artifact review completed.');
      expect(controller.events.single.metadata['approved_artifact_ids'], [
        'artifact-1',
      ]);
      expect(controller.events.single.metadata['rejected_artifact_ids'], [
        'artifact-2',
      ]);
      expect(controller.approvals, isEmpty);
      expect(controller.tasks.single.status, TaskStatus.needsHumanReview);
      expect(controller.artifacts.map((artifact) => artifact.status), [
        ArtifactStatus.approved,
        ArtifactStatus.rejected,
        ArtifactStatus.reviewed,
      ]);
    },
  );

  test('TaskInboxController queues retry and preserves run history', () async {
    final ids = _DeterministicIds();
    final store = _MemoryTaskStore(
      TaskInboxSnapshot(
        updatedAt: DateTime(2026, 7, 8, 8),
        tasks: [
          TaskRecord(
            id: 'task-1',
            title: 'Retry me',
            description: '',
            workspacePath: '/workspace/app',
            agentName: 'Codex',
            status: TaskStatus.failed,
            priority: TaskPriority.normal,
            createdAt: DateTime(2026, 7, 8, 8),
            updatedAt: DateTime(2026, 7, 8, 8),
            currentRunId: 'run-1',
            sessionId: 'session-1',
            error: 'boom',
          ),
        ],
        runs: [
          TaskRunRecord(
            id: 'run-1',
            taskId: 'task-1',
            attempt: 1,
            status: TaskStatus.failed,
            startedAt: DateTime(2026, 7, 8, 8),
            endedAt: DateTime(2026, 7, 8, 8, 5),
            sessionId: 'session-1',
            error: 'boom',
          ),
        ],
      ),
    );
    final controller = TaskInboxController(
      repository: store,
      clock: () => DateTime(2026, 7, 8, 9),
      idGenerator: ids.next,
    );
    addTearDown(controller.dispose);
    await controller.load();

    final queued = await controller.retryTask(
      'task-1',
      rationale: 'Try again with a smaller change.',
    );

    expect(queued.status, TaskStatus.queued);
    expect(queued.summary, 'Try again with a smaller change.');
    expect(queued.error, isNull);
    expect(queued.sessionId, isNull);
    expect(queued.currentRunId, isNull);
    expect(controller.runs.single.id, 'run-1');
    expect(controller.runs.single.status, TaskStatus.failed);
    expect(controller.events.single.kind, TaskEventKind.system);
    expect(controller.events.single.runId, 'run-1');
    expect(controller.events.single.text, 'Task retry queued.');

    final secondRun = await controller.createRun(taskId: 'task-1');

    expect(secondRun.id, 'run-2');
    expect(secondRun.attempt, 2);
    expect(controller.tasks.single.currentRunId, 'run-2');
  });

  test('TaskInboxController recovers interrupted runs as failed', () async {
    final ids = _DeterministicIds();
    final store = _MemoryTaskStore(
      TaskInboxSnapshot(
        updatedAt: DateTime(2026, 7, 8, 8),
        tasks: [
          TaskRecord(
            id: 'task-1',
            title: 'Interrupted',
            description: '',
            workspacePath: '/workspace/app',
            agentName: 'Codex',
            status: TaskStatus.running,
            priority: TaskPriority.normal,
            createdAt: DateTime(2026, 7, 8, 8),
            updatedAt: DateTime(2026, 7, 8, 8),
            currentRunId: 'run-1',
            sessionId: 'session-1',
          ),
        ],
        runs: [
          TaskRunRecord(
            id: 'run-1',
            taskId: 'task-1',
            attempt: 1,
            status: TaskStatus.running,
            startedAt: DateTime(2026, 7, 8, 8),
            sessionId: 'session-1',
          ),
        ],
      ),
    );
    final controller = TaskInboxController(
      repository: store,
      clock: () => DateTime(2026, 7, 8, 9),
      idGenerator: ids.next,
    );
    addTearDown(controller.dispose);
    await controller.load();

    final recovered = await controller.recoverInterruptedRuns();

    expect(recovered.map((task) => task.id), ['task-1']);
    expect(controller.tasks.single.status, TaskStatus.failed);
    expect(
      controller.tasks.single.error,
      'Task run interrupted before completion.',
    );
    expect(controller.tasks.single.currentRunId, 'run-1');
    expect(controller.runs.single.status, TaskStatus.failed);
    expect(controller.runs.single.endedAt, DateTime(2026, 7, 8, 9));
    expect(
      controller.runs.single.error,
      'Task run interrupted before completion.',
    );
    expect(controller.events.single.kind, TaskEventKind.system);
    expect(
      controller.events.single.text,
      'Task run recovered as failed: Task run interrupted before completion.',
    );
  });
}

class _MemoryTaskStore extends MemoryTaskRepository {
  _MemoryTaskStore([super.snapshot]);
}

TaskInboxSnapshot _reviewSnapshot() {
  return TaskInboxSnapshot(
    updatedAt: DateTime(2026, 7, 7, 8),
    tasks: [
      TaskRecord(
        id: 'task-1',
        title: 'Review me',
        description: '',
        workspacePath: '/workspace/app',
        agentName: 'Codex',
        status: TaskStatus.needsHumanReview,
        priority: TaskPriority.normal,
        createdAt: DateTime(2026, 7, 7, 8),
        updatedAt: DateTime(2026, 7, 7, 8),
        currentRunId: 'run-1',
        sessionId: 'session-1',
      ),
    ],
    runs: [
      TaskRunRecord(
        id: 'run-1',
        taskId: 'task-1',
        attempt: 1,
        status: TaskStatus.needsHumanReview,
        startedAt: DateTime(2026, 7, 7, 8),
      ),
    ],
    artifacts: [
      ArtifactRecord(
        id: 'artifact-1',
        taskId: 'task-1',
        runId: 'run-1',
        kind: ArtifactKind.gitDiff,
        title: 'Git diff preview',
        createdAt: DateTime(2026, 7, 7, 8),
        contentPreview: '+after',
      ),
    ],
  );
}

class _DeterministicIds {
  final Map<String, int> _counts = <String, int>{};

  String next(String prefix) {
    final count = (_counts[prefix] ?? 0) + 1;
    _counts[prefix] = count;
    return '$prefix-$count';
  }
}
