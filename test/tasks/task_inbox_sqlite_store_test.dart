import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/tasks/task_inbox_snapshot.dart';
import 'package:ianvs_acp/tasks/task_inbox_sqlite_store.dart';
import 'package:ianvs_acp/tasks/task_record.dart';
import 'package:ianvs_acp/tasks/task_repository.dart';
import 'package:ianvs_acp/tasks/workspace_resource.dart';
import 'package:sqlite3/sqlite3.dart';

import '../support/memory_task_repository.dart';

void main() {
  test('creates normalized task tables with required pragmas', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'ianvs-acp-task-schema-',
    );
    addTearDown(() async => tempDir.delete(recursive: true));
    final db = File('${tempDir.path}/task-inbox.sqlite3');
    final store = TaskInboxSqliteStore(path: db.path);
    addTearDown(store.close);

    await store.initialize();

    expect(await store.journalMode(), 'wal');
    expect(await store.foreignKeysEnabled(), isTrue);
    expect(
      await store.tableNames(),
      containsAll(<String>{
        'schema_migrations',
        'store_meta',
        'workspace_resources',
        'tasks',
        'task_runs',
        'task_events',
        'artifacts',
        'approval_requests',
      }),
    );
  });

  test('TaskInboxSqliteStore resolves default path near config', () {
    final path = TaskInboxSqliteStore.defaultPath(
      configPath: '/tmp/ianvs-acp/settings.json',
      environment: const {'HOME': '/Users/example'},
    );

    expect(path, '/tmp/ianvs-acp/task_inbox_state.sqlite3');
  });

  test('initialization is single-flight and can reopen after close', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'ianvs-acp-task-sqlite-',
    );
    addTearDown(() async => tempDir.delete(recursive: true));
    final store = TaskInboxSqliteStore(
      path: '${tempDir.path}/task_inbox_state.sqlite3',
    );
    addTearDown(store.close);

    final first = store.initialize();
    final second = store.initialize();
    expect(identical(first, second), isTrue);
    await Future.wait([first, second]);
    await store.close();
    await store.initialize();

    expect(await store.tableNames(), contains('tasks'));
  });

  test('rejects a repository schema newer than this client', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'ianvs-acp-task-sqlite-',
    );
    addTearDown(() async => tempDir.delete(recursive: true));
    final path = '${tempDir.path}/task_inbox_state.sqlite3';
    final database = sqlite3.open(path);
    database.execute(
      'CREATE TABLE schema_migrations '
      '(version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL);',
    );
    database.execute(
      'INSERT INTO schema_migrations (version, applied_at) VALUES (2, ?);',
      [DateTime.utc(2030).toIso8601String()],
    );
    database.close();
    final store = TaskInboxSqliteStore(path: path);
    addTearDown(store.close);

    await expectLater(store.initialize(), throwsStateError);
  });

  test('rejects non-canonical task values without changing revision', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'ianvs-acp-task-sqlite-',
    );
    addTearDown(() async => tempDir.delete(recursive: true));
    final store = TaskInboxSqliteStore(
      path: '${tempDir.path}/task_inbox_state.sqlite3',
    );
    addTearDown(store.close);
    final createdAt = DateTime.utc(2026, 7, 10, 10);
    await store.initialize();
    final revision = await store.revision();

    await expectLater(
      store.insertTask(
        TaskRecord(
          id: ' task-1 ',
          title: ' Invalid ',
          description: '',
          workspacePath: '/workspace/app',
          agentName: 'Codex',
          status: TaskStatus.inbox,
          priority: TaskPriority.normal,
          createdAt: createdAt,
          updatedAt: createdAt,
        ),
      ),
      throwsArgumentError,
    );

    expect(await store.revision(), revision);
    expect((await store.loadRepository()).snapshot.tasks, isEmpty);
  });

  test(
    'preserves artifact content preview bytes across replace and load',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'ianvs-acp-task-sqlite-',
      );
      addTearDown(() async => tempDir.delete(recursive: true));
      final store = TaskInboxSqliteStore(
        path: '${tempDir.path}/task_inbox_state.sqlite3',
      );
      addTearDown(store.close);
      final createdAt = DateTime.utc(2026, 7, 10, 10);
      const description = ' task description\n';
      final task = TaskRecord(
        id: 'task-1',
        title: 'Artifact preview',
        description: description,
        workspacePath: '/workspace/app',
        agentName: 'Codex',
        status: TaskStatus.queued,
        priority: TaskPriority.normal,
        createdAt: createdAt,
        updatedAt: createdAt,
      );
      await store.insertTask(task);
      final run = TaskRunRecord(
        id: 'run-1',
        taskId: task.id,
        attempt: 1,
        status: TaskStatus.running,
        startedAt: createdAt,
      );
      await store.createRun(
        expectedTask: task,
        task: task.copyWith(status: TaskStatus.running, currentRunId: run.id),
        run: run,
      );
      const eventText = 'artifact collection started\n';
      await store.appendEvents([
        TaskEventRecord(
          id: 'event-1',
          taskId: task.id,
          runId: run.id,
          kind: TaskEventKind.tool,
          text: eventText,
          createdAt: createdAt,
        ),
      ], updatedAt: createdAt);
      const preview = ' export candidate\n';
      final artifact = ArtifactRecord(
        id: 'artifact-1',
        taskId: task.id,
        runId: run.id,
        kind: ArtifactKind.outboxFile,
        title: 'Export candidate',
        createdAt: createdAt,
        contentPreview: preview,
      );

      await store.replaceArtifactsForRun(
        taskId: task.id,
        runId: run.id,
        expectedArtifacts: const <ArtifactRecord>[],
        artifacts: [artifact],
        updatedAt: createdAt,
      );

      final loaded = (await store.loadRepository()).snapshot;
      expect(loaded.tasks.single.description, description);
      expect(loaded.tasks.single.description.codeUnits, description.codeUnits);
      expect(loaded.events.single.text, eventText);
      expect(loaded.events.single.text.codeUnits, eventText.codeUnits);
      expect(loaded.artifacts.single.contentPreview, preview);
      expect(
        loaded.artifacts.single.contentPreview!.codeUnits,
        preview.codeUnits,
      );
    },
  );

  test(
    'repositories reject workspace resources without canonical paths',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'ianvs-acp-task-sqlite-',
      );
      addTearDown(() async => tempDir.delete(recursive: true));
      final sqlite = TaskInboxSqliteStore(
        path: '${tempDir.path}/task_inbox_state.sqlite3',
      );
      final memory = MemoryTaskRepository();
      addTearDown(sqlite.close);
      addTearDown(memory.close);
      final repositories = <TaskRepository>[sqlite, memory];

      for (final repository in repositories) {
        final revision = await repository.revision();
        for (final type in ResourceType.values) {
          await expectLater(
            repository.upsertResource(
              WorkspaceResource(
                id: 'resource-${type.name}',
                type: type,
                label: 'Workspace',
                ref: const <String, Object?>{'path': '  '},
              ),
              updatedAt: DateTime.utc(2026, 7, 10, 10),
            ),
            throwsArgumentError,
          );
        }
        expect(await repository.revision(), revision);
        expect((await repository.loadRepository()).snapshot.resources, isEmpty);

        for (final type in ResourceType.values) {
          await repository.upsertResource(
            WorkspaceResource(
              id: 'resource-${type.name}',
              type: type,
              label: type.name,
              ref: <String, Object?>{'path': '/workspace/${type.name}'},
            ),
            updatedAt: DateTime.utc(2026, 7, 10, 10),
          );
        }
        final resources =
            (await repository.loadRepository()).snapshot.resources;
        expect(resources.map((resource) => resource.type).toSet(), {
          ...ResourceType.values,
        });
        expect(
          resources.map((resource) => resource.ref['path']),
          everyElement(
            isA<String>().having((path) => path, 'path', isNotEmpty),
          ),
        );
      }
    },
  );

  test('two connections keep independent row inserts', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'ianvs-acp-task-sqlite-',
    );
    addTearDown(() async => tempDir.delete(recursive: true));
    final path = '${tempDir.path}/task_inbox_state.sqlite3';
    final first = TaskInboxSqliteStore(path: path);
    final second = TaskInboxSqliteStore(path: path);
    addTearDown(first.close);
    addTearDown(second.close);
    final createdAt = DateTime.utc(2026, 7, 10, 10);
    TaskRecord task(String id) => TaskRecord(
      id: id,
      title: id,
      description: '',
      workspacePath: '/workspace/app',
      agentName: 'Codex',
      status: TaskStatus.inbox,
      priority: TaskPriority.normal,
      createdAt: createdAt,
      updatedAt: createdAt,
    );

    await first.insertTask(task('task-a'));
    await second.insertTask(task('task-b'));

    expect(
      (await first.loadRepository()).snapshot.tasks.map((task) => task.id),
      containsAll(<String>['task-a', 'task-b']),
    );
    expect(
      (await second.loadRepository()).snapshot.tasks.map((task) => task.id),
      containsAll(<String>['task-a', 'task-b']),
    );
  });

  test('two connections atomically claim one queued task', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'ianvs-acp-task-sqlite-',
    );
    addTearDown(() async => tempDir.delete(recursive: true));
    final path = '${tempDir.path}/task_inbox_state.sqlite3';
    final first = TaskInboxSqliteStore(path: path);
    final second = TaskInboxSqliteStore(path: path);
    addTearDown(first.close);
    addTearDown(second.close);
    final createdAt = DateTime.utc(2026, 7, 10, 10);
    final task = TaskRecord(
      id: 'task-1',
      title: 'Claim once',
      description: '',
      workspacePath: '/workspace/app',
      agentName: 'Codex',
      status: TaskStatus.queued,
      priority: TaskPriority.normal,
      createdAt: createdAt,
      updatedAt: createdAt,
    );
    await first.insertTask(task);
    final beforeClaim = await first.loadRepository();
    final revisionBeforeClaim = beforeClaim.revision;

    final claims = await Future.wait([
      first.claimTask(
        task,
        TaskRunRecord(
          id: 'run-a',
          taskId: task.id,
          attempt: 1,
          status: TaskStatus.dispatched,
          startedAt: createdAt.add(const Duration(minutes: 1)),
        ),
        dispatchEvent: TaskEventRecord(
          id: 'event-a',
          taskId: task.id,
          runId: 'run-a',
          kind: TaskEventKind.system,
          text: 'Task dispatched.',
          createdAt: createdAt.add(const Duration(minutes: 1)),
        ),
      ),
      second.claimTask(
        task,
        TaskRunRecord(
          id: 'run-b',
          taskId: task.id,
          attempt: 1,
          status: TaskStatus.dispatched,
          startedAt: createdAt.add(const Duration(minutes: 1)),
        ),
        dispatchEvent: TaskEventRecord(
          id: 'event-b',
          taskId: task.id,
          runId: 'run-b',
          kind: TaskEventKind.system,
          text: 'Task dispatched.',
          createdAt: createdAt.add(const Duration(minutes: 1)),
        ),
      ),
    ]);

    final successful = claims.whereType<TaskClaim>().single;
    final snapshot = (await first.loadRepository()).snapshot;
    expect(snapshot.runs, hasLength(1));
    expect(snapshot.runs.single.id, successful.run.id);
    expect(snapshot.events, hasLength(1));
    expect(snapshot.events.single.id, successful.dispatchEvent.id);
    expect(snapshot.events.single.runId, successful.run.id);
    expect(snapshot.tasks.single.status, TaskStatus.dispatched);
    expect(snapshot.tasks.single.currentRunId, successful.run.id);
    expect(await first.revision(), revisionBeforeClaim + 1);
    final claimTime = createdAt.add(const Duration(minutes: 1));
    expect(
      snapshot.updatedAt,
      beforeClaim.snapshot.updatedAt.isAfter(claimTime)
          ? beforeClaim.snapshot.updatedAt
          : claimTime,
    );
  });

  test('two isolates atomically claim one queued task', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'ianvs-acp-task-sqlite-',
    );
    addTearDown(() async => tempDir.delete(recursive: true));
    final path = '${tempDir.path}/task_inbox_state.sqlite3';
    final store = TaskInboxSqliteStore(path: path);
    addTearDown(store.close);
    final createdAt = DateTime.utc(2026, 7, 10, 10);
    await store.insertTask(
      TaskRecord(
        id: 'task-1',
        title: 'Claim across isolates',
        description: '',
        workspacePath: '/workspace/app',
        agentName: 'Codex',
        status: TaskStatus.queued,
        priority: TaskPriority.normal,
        createdAt: createdAt,
        updatedAt: createdAt,
      ),
    );
    final revisionBeforeClaim = await store.revision();
    final messages = ReceivePort();
    final exits = ReceivePort();
    final isolates = <Isolate>[];
    final readyPorts = <SendPort>[];
    final results = <String?>[];
    final ready = Completer<void>();
    final finished = Completer<void>();
    var exitCount = 0;
    void failCurrentPhase(Object error) {
      if (!ready.isCompleted) {
        ready.completeError(error);
      } else if (!finished.isCompleted) {
        finished.completeError(error);
      }
    }

    final subscription = messages.listen((message) {
      if (message is! Map) {
        failCurrentPhase(StateError('Isolate failed: $message'));
        return;
      }
      if (message['type'] == 'ready') {
        readyPorts.add(message['port']! as SendPort);
        if (readyPorts.length == 2 && !ready.isCompleted) ready.complete();
        return;
      }
      if (message['type'] == 'result') {
        results.add(message['run_id'] as String?);
        if (results.length == 2 && !finished.isCompleted) finished.complete();
        return;
      }
      if (message['type'] == 'error') {
        failCurrentPhase(StateError('${message['error']}'));
      }
    });
    final exitSubscription = exits.listen((_) => exitCount += 1);
    addTearDown(() async {
      await subscription.cancel();
      await exitSubscription.cancel();
      messages.close();
      exits.close();
    });
    addTearDown(() {
      for (final isolate in isolates) {
        isolate.kill(priority: Isolate.immediate);
      }
    });

    isolates.add(
      await Isolate.spawn(
        _claimTaskInIsolate,
        <Object?>[path, 'run-a', 'event-a', messages.sendPort],
        onError: messages.sendPort,
        onExit: exits.sendPort,
      ),
    );
    isolates.add(
      await Isolate.spawn(
        _claimTaskInIsolate,
        <Object?>[path, 'run-b', 'event-b', messages.sendPort],
        onError: messages.sendPort,
        onExit: exits.sendPort,
      ),
    );
    await ready.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => throw TimeoutException(
        'Timed out waiting for isolate readiness ($exitCount exited).',
      ),
    );
    for (final port in readyPorts) {
      port.send(true);
    }
    await finished.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => throw TimeoutException(
        'Timed out waiting for isolate claims ($exitCount exited).',
      ),
    );

    expect(results.whereType<String>(), hasLength(1));
    final snapshot = (await store.loadRepository()).snapshot;
    expect(snapshot.runs, hasLength(1));
    expect(snapshot.events, hasLength(1));
    expect(snapshot.events.single.runId, snapshot.runs.single.id);
    expect(snapshot.tasks.single.currentRunId, snapshot.runs.single.id);
    expect(await store.revision(), revisionBeforeClaim + 1);
  });

  test('claim conflicts roll back task run event and revision', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'ianvs-acp-task-sqlite-',
    );
    addTearDown(() async => tempDir.delete(recursive: true));
    final store = TaskInboxSqliteStore(
      path: '${tempDir.path}/task_inbox_state.sqlite3',
    );
    addTearDown(store.close);
    final createdAt = DateTime.utc(2026, 7, 10, 10);
    final historyTask = TaskRecord(
      id: 'task-history',
      title: 'History',
      description: '',
      workspacePath: '/workspace/app',
      agentName: 'Codex',
      status: TaskStatus.done,
      priority: TaskPriority.normal,
      createdAt: createdAt,
      updatedAt: createdAt,
      currentRunId: 'run-shared',
    );
    final queuedTask = TaskRecord(
      id: 'task-queued',
      title: 'Queued',
      description: '',
      workspacePath: '/workspace/other',
      agentName: 'Codex',
      status: TaskStatus.queued,
      priority: TaskPriority.normal,
      createdAt: createdAt,
      updatedAt: createdAt,
    );
    final historyRun = TaskRunRecord(
      id: 'run-shared',
      taskId: historyTask.id,
      attempt: 1,
      status: TaskStatus.done,
      startedAt: createdAt,
      endedAt: createdAt,
    );
    final historyEvent = TaskEventRecord(
      id: 'event-shared',
      taskId: historyTask.id,
      runId: historyRun.id,
      kind: TaskEventKind.system,
      text: 'Done.',
      createdAt: createdAt,
    );
    await store.activateVerifiedSnapshot(
      TaskInboxSnapshot(
        updatedAt: createdAt,
        tasks: [historyTask, queuedTask],
        runs: [historyRun],
        events: [historyEvent],
      ),
      checksum: 'claim-conflicts',
    );
    final before = await store.loadRepository();
    final startedAt = createdAt.add(const Duration(minutes: 1));

    await expectLater(
      store.claimTask(
        queuedTask,
        TaskRunRecord(
          id: historyRun.id,
          taskId: queuedTask.id,
          attempt: 1,
          status: TaskStatus.dispatched,
          startedAt: startedAt,
        ),
        dispatchEvent: TaskEventRecord(
          id: 'event-new',
          taskId: queuedTask.id,
          runId: historyRun.id,
          kind: TaskEventKind.system,
          text: 'Task dispatched.',
          createdAt: startedAt,
        ),
      ),
      throwsA(isA<TaskRepositoryConflict>()),
    );
    expect(
      (await store.loadRepository()).snapshot.toJson(),
      before.snapshot.toJson(),
    );
    expect(await store.revision(), before.revision);

    await expectLater(
      store.claimTask(
        queuedTask,
        TaskRunRecord(
          id: 'run-new',
          taskId: queuedTask.id,
          attempt: 1,
          status: TaskStatus.dispatched,
          startedAt: startedAt,
        ),
        dispatchEvent: TaskEventRecord(
          id: historyEvent.id,
          taskId: queuedTask.id,
          runId: 'run-new',
          kind: TaskEventKind.system,
          text: 'Task dispatched.',
          createdAt: startedAt,
        ),
      ),
      throwsA(isA<TaskRepositoryConflict>()),
    );
    expect(
      (await store.loadRepository()).snapshot.toJson(),
      before.snapshot.toJson(),
    );
    expect(await store.revision(), before.revision);
  });

  test(
    'repositories validate claim status and calculate the next attempt',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'ianvs-acp-task-sqlite-',
      );
      addTearDown(() async => tempDir.delete(recursive: true));
      final createdAt = DateTime.utc(2026, 7, 10, 10);
      final taskUpdatedAt = createdAt.add(const Duration(minutes: 5));
      final task = TaskRecord(
        id: 'task-1',
        title: 'Retry generation',
        description: '',
        workspacePath: '/workspace/app',
        agentName: 'Codex',
        status: TaskStatus.queued,
        priority: TaskPriority.normal,
        createdAt: createdAt,
        updatedAt: taskUpdatedAt,
      );
      final snapshot = TaskInboxSnapshot(
        updatedAt: taskUpdatedAt,
        tasks: [task],
        runs: [
          TaskRunRecord(
            id: 'run-1',
            taskId: task.id,
            attempt: 1,
            status: TaskStatus.failed,
            startedAt: createdAt,
            endedAt: createdAt,
          ),
          TaskRunRecord(
            id: 'run-3',
            taskId: task.id,
            attempt: 3,
            status: TaskStatus.failed,
            startedAt: createdAt,
            endedAt: createdAt,
          ),
        ],
      );
      final sqlite = TaskInboxSqliteStore(
        path: '${tempDir.path}/task_inbox_state.sqlite3',
      );
      await sqlite.activateVerifiedSnapshot(snapshot, checksum: 'attempts');
      final memory = MemoryTaskRepository(snapshot);
      addTearDown(sqlite.close);
      addTearDown(memory.close);

      for (final repository in <TaskRepository>[sqlite, memory]) {
        final revision = await repository.revision();
        await expectLater(
          repository.claimTask(
            task,
            TaskRunRecord(
              id: 'run-invalid',
              taskId: task.id,
              attempt: 1,
              status: TaskStatus.running,
              startedAt: createdAt,
            ),
            dispatchEvent: TaskEventRecord(
              id: 'event-invalid',
              taskId: task.id,
              runId: 'run-invalid',
              kind: TaskEventKind.system,
              text: 'Task dispatched.',
              createdAt: createdAt,
            ),
          ),
          throwsArgumentError,
        );
        expect(await repository.revision(), revision);

        final claim = await repository.claimTask(
          task,
          TaskRunRecord(
            id: 'run-next',
            taskId: task.id,
            attempt: 1,
            status: TaskStatus.dispatched,
            startedAt: createdAt.add(const Duration(minutes: 1)),
          ),
          dispatchEvent: TaskEventRecord(
            id: 'event-next',
            taskId: task.id,
            runId: 'run-next',
            kind: TaskEventKind.system,
            text: 'Task dispatched.',
            createdAt: createdAt.add(const Duration(minutes: 2)),
          ),
        );
        expect(claim!.run.attempt, 4);
        expect(claim.task.updatedAt, taskUpdatedAt);
        expect(claim.run.startedAt, taskUpdatedAt);
        expect(claim.dispatchEvent.createdAt, taskUpdatedAt);
        expect(
          (await repository.loadRepository()).snapshot.events,
          hasLength(1),
        );
      }
    },
  );

  test('repositories reject stale task and resource claim routes', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'ianvs-acp-task-sqlite-',
    );
    addTearDown(() async => tempDir.delete(recursive: true));
    final createdAt = DateTime.utc(2026, 7, 10, 10);
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
    TaskRecord task(String id, {String? resourceId}) => TaskRecord(
      id: id,
      title: id,
      description: '',
      workspacePath: '/workspace/app',
      agentName: 'OldAgent',
      status: TaskStatus.queued,
      priority: TaskPriority.normal,
      createdAt: createdAt,
      updatedAt: createdAt,
      resourceId: resourceId,
    );
    final staleTask = task('task-stale');
    final resourceTask = task('task-resource', resourceId: oldResource.id);
    final initial = TaskInboxSnapshot(
      updatedAt: createdAt,
      tasks: [staleTask, resourceTask],
      resources: const [oldResource],
    );
    final sqlite = TaskInboxSqliteStore(
      path: '${tempDir.path}/task_inbox_state.sqlite3',
    );
    await sqlite.activateVerifiedSnapshot(initial, checksum: 'claim-routes');
    final memory = MemoryTaskRepository(initial);
    addTearDown(sqlite.close);
    addTearDown(memory.close);

    for (final repository in <TaskRepository>[sqlite, memory]) {
      await repository.updateTask(
        staleTask.copyWith(
          agentName: 'NewAgent',
          updatedAt: createdAt.add(const Duration(minutes: 1)),
        ),
        expected: staleTask,
      );
      var revision = await repository.revision();
      final staleTaskClaim = await repository.claimTask(
        staleTask,
        TaskRunRecord(
          id: 'run-stale',
          taskId: staleTask.id,
          attempt: 1,
          status: TaskStatus.dispatched,
          startedAt: createdAt.add(const Duration(minutes: 2)),
        ),
        dispatchEvent: TaskEventRecord(
          id: 'event-stale',
          taskId: staleTask.id,
          runId: 'run-stale',
          kind: TaskEventKind.system,
          text: 'Task dispatched.',
          createdAt: createdAt.add(const Duration(minutes: 2)),
        ),
      );
      expect(staleTaskClaim, isNull);
      expect(await repository.revision(), revision);

      await repository.upsertResource(
        newResource,
        expected: oldResource,
        updatedAt: createdAt.add(const Duration(minutes: 1)),
      );
      revision = await repository.revision();
      final staleResourceClaim = await repository.claimTask(
        resourceTask,
        TaskRunRecord(
          id: 'run-resource',
          taskId: resourceTask.id,
          attempt: 1,
          status: TaskStatus.dispatched,
          startedAt: createdAt.add(const Duration(minutes: 2)),
        ),
        dispatchEvent: TaskEventRecord(
          id: 'event-resource',
          taskId: resourceTask.id,
          runId: 'run-resource',
          kind: TaskEventKind.system,
          text: 'Task dispatched.',
          createdAt: createdAt.add(const Duration(minutes: 2)),
        ),
        expectedResource: oldResource,
      );
      expect(staleResourceClaim, isNull);
      expect(await repository.revision(), revision);
      expect((await repository.loadRepository()).snapshot.runs, isEmpty);
      expect((await repository.loadRepository()).snapshot.events, isEmpty);
    }
  });

  test('repositories use the same claim failure priority', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'ianvs-acp-task-sqlite-',
    );
    addTearDown(() async => tempDir.delete(recursive: true));
    final createdAt = DateTime.utc(2026, 7, 10, 10);
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
    TaskRecord queuedTask(String id, {String? resourceId}) => TaskRecord(
      id: id,
      title: id,
      description: '',
      workspacePath: '/workspace/app',
      agentName: 'OldAgent',
      status: TaskStatus.queued,
      priority: TaskPriority.normal,
      createdAt: createdAt,
      updatedAt: createdAt,
      resourceId: resourceId,
    );
    final historyTask = TaskRecord(
      id: 'task-history',
      title: 'History',
      description: '',
      workspacePath: '/workspace/history',
      agentName: 'Codex',
      status: TaskStatus.done,
      priority: TaskPriority.normal,
      createdAt: createdAt,
      updatedAt: createdAt,
      currentRunId: 'run-existing',
    );
    final staleTask = queuedTask('task-stale');
    final resourceTask = queuedTask(
      'task-resource',
      resourceId: oldResource.id,
    );
    final existingRun = TaskRunRecord(
      id: 'run-existing',
      taskId: historyTask.id,
      attempt: 1,
      status: TaskStatus.done,
      startedAt: createdAt,
      endedAt: createdAt,
    );
    final existingEvent = TaskEventRecord(
      id: 'event-existing',
      taskId: historyTask.id,
      runId: existingRun.id,
      kind: TaskEventKind.system,
      text: 'Done.',
      createdAt: createdAt,
    );
    final initial = TaskInboxSnapshot(
      updatedAt: createdAt,
      tasks: [historyTask, staleTask, resourceTask],
      runs: [existingRun],
      events: [existingEvent],
      resources: const [oldResource],
    );
    final sqlite = TaskInboxSqliteStore(
      path: '${tempDir.path}/task_inbox_state.sqlite3',
    );
    await sqlite.activateVerifiedSnapshot(initial, checksum: 'claim-priority');
    final memory = MemoryTaskRepository(initial);
    addTearDown(sqlite.close);
    addTearDown(memory.close);

    for (final repository in <TaskRepository>[sqlite, memory]) {
      await repository.updateTask(
        staleTask.copyWith(
          agentName: 'NewAgent',
          updatedAt: createdAt.add(const Duration(minutes: 1)),
        ),
        expected: staleTask,
      );
      await repository.upsertResource(
        newResource,
        expected: oldResource,
        updatedAt: createdAt.add(const Duration(minutes: 1)),
      );

      Future<void> expectUnchanged(
        Future<TaskClaim?> Function() operation,
        Object matcher,
      ) async {
        final before = await repository.loadRepository();
        await expectLater(operation(), matcher);
        final after = await repository.loadRepository();
        expect(after.revision, before.revision);
        expect(after.snapshot.toJson(), before.snapshot.toJson());
      }

      await expectUnchanged(
        () => repository.claimTask(
          staleTask,
          TaskRunRecord(
            id: existingRun.id,
            taskId: staleTask.id,
            attempt: 1,
            status: TaskStatus.dispatched,
            startedAt: createdAt,
          ),
          dispatchEvent: TaskEventRecord(
            id: 'event-stale',
            taskId: staleTask.id,
            runId: existingRun.id,
            kind: TaskEventKind.system,
            text: 'Task dispatched.',
            createdAt: createdAt,
          ),
        ),
        completion(isNull),
      );

      await expectUnchanged(
        () => repository.claimTask(
          resourceTask,
          TaskRunRecord(
            id: 'run-wrong-owner',
            taskId: historyTask.id,
            attempt: 1,
            status: TaskStatus.dispatched,
            startedAt: createdAt,
          ),
          dispatchEvent: TaskEventRecord(
            id: 'event-wrong-owner',
            taskId: resourceTask.id,
            runId: 'run-wrong-owner',
            kind: TaskEventKind.system,
            text: 'Task dispatched.',
            createdAt: createdAt,
          ),
          expectedResource: oldResource,
        ),
        throwsArgumentError,
      );

      await expectUnchanged(
        () => repository.claimTask(
          resourceTask,
          TaskRunRecord(
            id: existingRun.id,
            taskId: historyTask.id,
            attempt: 1,
            status: TaskStatus.dispatched,
            startedAt: createdAt,
          ),
          dispatchEvent: TaskEventRecord(
            id: 'event-collision-and-wrong-owner',
            taskId: resourceTask.id,
            runId: existingRun.id,
            kind: TaskEventKind.system,
            text: 'Task dispatched.',
            createdAt: createdAt,
          ),
          expectedResource: newResource,
        ),
        throwsArgumentError,
      );
    }
  });

  test('row writes do not move repository updatedAt backwards', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'ianvs-acp-task-sqlite-',
    );
    addTearDown(() async => tempDir.delete(recursive: true));
    final store = TaskInboxSqliteStore(
      path: '${tempDir.path}/task_inbox_state.sqlite3',
    );
    addTearDown(store.close);
    final latest = DateTime.utc(2030, 1, 1, 12);
    final older = latest.subtract(const Duration(hours: 1));
    await store.activateVerifiedSnapshot(
      TaskInboxSnapshot.empty(updatedAt: latest),
      checksum: 'empty',
    );

    await store.insertTask(
      TaskRecord(
        id: 'task-1',
        title: 'Older clock',
        description: '',
        workspacePath: '/workspace/app',
        agentName: 'Codex',
        status: TaskStatus.inbox,
        priority: TaskPriority.normal,
        createdAt: older,
        updatedAt: older,
      ),
    );

    expect((await store.loadRepository()).snapshot.updatedAt, latest);
  });

  test('strict task writes reject duplicate and stale records', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'ianvs-acp-task-sqlite-',
    );
    addTearDown(() async => tempDir.delete(recursive: true));
    final path = '${tempDir.path}/task_inbox_state.sqlite3';
    final first = TaskInboxSqliteStore(path: path);
    final second = TaskInboxSqliteStore(path: path);
    addTearDown(first.close);
    addTearDown(second.close);
    final createdAt = DateTime.utc(2026, 7, 10, 10);
    final original = TaskRecord(
      id: 'task-1',
      title: 'Original',
      description: '',
      workspacePath: '/workspace/app',
      agentName: 'Codex',
      status: TaskStatus.inbox,
      priority: TaskPriority.normal,
      createdAt: createdAt,
      updatedAt: createdAt,
    );
    await first.insertTask(original);
    final revisionAfterInsert = await first.revision();

    await expectLater(
      second.insertTask(original.copyWith(title: 'Duplicate')),
      throwsA(isA<TaskRepositoryConflict>()),
    );
    expect(await first.revision(), revisionAfterInsert);

    final priorityUpdate = original.copyWith(
      priority: TaskPriority.high,
      updatedAt: createdAt.add(const Duration(minutes: 1)),
    );
    await first.updateTask(priorityUpdate, expected: original);
    await expectLater(
      second.updateTask(
        original.copyWith(
          title: 'Stale rename',
          updatedAt: createdAt.add(const Duration(minutes: 2)),
        ),
        expected: original,
      ),
      throwsA(isA<TaskRepositoryConflict>()),
    );

    final loaded = (await second.loadRepository()).snapshot.tasks.single;
    expect(loaded.title, 'Original');
    expect(loaded.priority, TaskPriority.high);
  });

  test('stale task deletion cannot remove a concurrent update', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'ianvs-acp-task-sqlite-',
    );
    addTearDown(() async => tempDir.delete(recursive: true));
    final path = '${tempDir.path}/task_inbox_state.sqlite3';
    final first = TaskInboxSqliteStore(path: path);
    final second = TaskInboxSqliteStore(path: path);
    addTearDown(first.close);
    addTearDown(second.close);
    final createdAt = DateTime.utc(2026, 7, 10, 10);
    final original = TaskRecord(
      id: 'task-1',
      title: 'Original',
      description: '',
      workspacePath: '/workspace/app',
      agentName: 'Codex',
      status: TaskStatus.inbox,
      priority: TaskPriority.normal,
      createdAt: createdAt,
      updatedAt: createdAt,
    );
    await first.insertTask(original);
    final updated = original.copyWith(
      title: 'Concurrent update',
      updatedAt: createdAt.add(const Duration(minutes: 1)),
    );
    await second.updateTask(updated, expected: original);

    await expectLater(
      first.deleteTask(
        TaskDeleteExpectation(task: original),
        updatedAt: createdAt.add(const Duration(minutes: 2)),
      ),
      throwsA(isA<TaskRepositoryConflict>()),
    );

    expect(
      (await first.loadRepository()).snapshot.tasks.single.title,
      'Concurrent update',
    );
  });

  test('task deletion detects concurrently added child records', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'ianvs-acp-task-sqlite-',
    );
    addTearDown(() async => tempDir.delete(recursive: true));
    final path = '${tempDir.path}/task_inbox_state.sqlite3';
    final first = TaskInboxSqliteStore(path: path);
    final second = TaskInboxSqliteStore(path: path);
    addTearDown(first.close);
    addTearDown(second.close);
    final createdAt = DateTime.utc(2026, 7, 10, 10);
    final task = TaskRecord(
      id: 'task-1',
      title: 'Keep concurrent child',
      description: '',
      workspacePath: '/workspace/app',
      agentName: 'Codex',
      status: TaskStatus.queued,
      priority: TaskPriority.normal,
      createdAt: createdAt,
      updatedAt: createdAt,
    );
    await first.insertTask(task);
    final run = TaskRunRecord(
      id: 'run-1',
      taskId: task.id,
      attempt: 1,
      status: TaskStatus.running,
      startedAt: createdAt,
    );
    await first.createRun(
      expectedTask: task,
      task: task.copyWith(status: TaskStatus.running, currentRunId: run.id),
      run: run,
    );
    final expected = TaskDeleteExpectation.fromSnapshot(
      (await first.loadRepository()).snapshot,
      task.id,
    );
    await second.appendEvents([
      TaskEventRecord(
        id: 'event-concurrent',
        taskId: task.id,
        runId: run.id,
        kind: TaskEventKind.system,
        text: 'Added after delete screen loaded',
        createdAt: createdAt,
      ),
    ], updatedAt: createdAt);

    await expectLater(
      first.deleteTask(expected, updatedAt: createdAt),
      throwsA(isA<TaskRepositoryConflict>()),
    );

    final loaded = (await first.loadRepository()).snapshot;
    expect(loaded.tasks, hasLength(1));
    expect(loaded.events.single.id, 'event-concurrent');
  });

  test('row writes reject cross-task run references', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'ianvs-acp-task-sqlite-',
    );
    addTearDown(() async => tempDir.delete(recursive: true));
    final store = TaskInboxSqliteStore(
      path: '${tempDir.path}/task_inbox_state.sqlite3',
    );
    addTearDown(store.close);
    final createdAt = DateTime.utc(2026, 7, 10, 10);
    TaskRecord task(String id) => TaskRecord(
      id: id,
      title: id,
      description: '',
      workspacePath: '/workspace/app',
      agentName: 'Codex',
      status: TaskStatus.queued,
      priority: TaskPriority.normal,
      createdAt: createdAt,
      updatedAt: createdAt,
    );
    final taskA = task('task-a');
    final taskB = task('task-b');
    await store.insertTask(taskA);
    await store.insertTask(taskB);
    final runB = TaskRunRecord(
      id: 'run-b',
      taskId: taskB.id,
      attempt: 1,
      status: TaskStatus.running,
      startedAt: createdAt,
    );
    await store.createRun(
      expectedTask: taskB,
      task: taskB.copyWith(status: TaskStatus.running, currentRunId: runB.id),
      run: runB,
    );
    final revisionBeforeFailures = await store.revision();

    await expectLater(
      store.appendEvents([
        TaskEventRecord(
          id: 'event-invalid',
          taskId: taskA.id,
          runId: runB.id,
          kind: TaskEventKind.system,
          text: 'invalid',
          createdAt: createdAt,
        ),
      ], updatedAt: createdAt),
      throwsStateError,
    );
    await expectLater(
      store.updateTask(taskA.copyWith(currentRunId: runB.id), expected: taskA),
      throwsStateError,
    );
    await expectLater(
      store.replaceArtifactsForRun(
        taskId: taskA.id,
        runId: runB.id,
        expectedArtifacts: const <ArtifactRecord>[],
        artifacts: [
          ArtifactRecord(
            id: 'artifact-invalid',
            taskId: taskA.id,
            runId: runB.id,
            kind: ArtifactKind.file,
            title: 'invalid',
            createdAt: createdAt,
          ),
        ],
        updatedAt: createdAt,
      ),
      throwsStateError,
    );
    await expectLater(
      store.upsertApproval(
        ApprovalRequestRecord(
          id: 'approval-invalid',
          taskId: taskA.id,
          runId: runB.id,
          kind: ApprovalKind.toolPermission,
          status: ApprovalStatus.pending,
          createdAt: createdAt,
        ),
        updatedAt: createdAt,
      ),
      throwsStateError,
    );

    expect(await store.revision(), revisionBeforeFailures);
    final loaded = (await store.loadRepository()).snapshot;
    expect(loaded.events, isEmpty);
    expect(loaded.artifacts, isEmpty);
    expect(loaded.approvals, isEmpty);

    final event = TaskEventRecord(
      id: 'event-1',
      taskId: taskB.id,
      runId: runB.id,
      kind: TaskEventKind.system,
      text: 'valid',
      createdAt: createdAt,
    );
    await store.appendEvents([event], updatedAt: createdAt);
    final revisionAfterEvent = await store.revision();
    await expectLater(
      store.appendEvents([event], updatedAt: createdAt),
      throwsA(isA<TaskRepositoryConflict>()),
    );
    expect(await store.revision(), revisionAfterEvent);
  });

  test('run creation rolls back when the run id already exists', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'ianvs-acp-task-sqlite-',
    );
    addTearDown(() async => tempDir.delete(recursive: true));
    final store = TaskInboxSqliteStore(
      path: '${tempDir.path}/task_inbox_state.sqlite3',
    );
    addTearDown(store.close);
    final createdAt = DateTime.utc(2026, 7, 10, 10);
    TaskRecord task(String id) => TaskRecord(
      id: id,
      title: id,
      description: '',
      workspacePath: '/workspace/app',
      agentName: 'Codex',
      status: TaskStatus.queued,
      priority: TaskPriority.normal,
      createdAt: createdAt,
      updatedAt: createdAt,
    );
    final firstTask = task('task-a');
    final secondTask = task('task-b');
    await store.insertTask(firstTask);
    await store.insertTask(secondTask);
    final firstRun = TaskRunRecord(
      id: 'run-1',
      taskId: firstTask.id,
      attempt: 1,
      status: TaskStatus.running,
      startedAt: createdAt,
    );
    await store.createRun(
      expectedTask: firstTask,
      task: firstTask.copyWith(
        status: TaskStatus.running,
        currentRunId: firstRun.id,
      ),
      run: firstRun,
    );
    await expectLater(
      store.updateRun(
        firstRun.copyWith(attempt: 2),
        expected: firstRun,
        updatedAt: createdAt,
      ),
      throwsArgumentError,
    );
    final revisionBeforeConflict = await store.revision();
    final conflictingRun = TaskRunRecord(
      id: firstRun.id,
      taskId: secondTask.id,
      attempt: 1,
      status: TaskStatus.running,
      startedAt: createdAt,
    );

    await expectLater(
      store.createRun(
        expectedTask: secondTask,
        task: secondTask.copyWith(
          status: TaskStatus.running,
          currentRunId: conflictingRun.id,
        ),
        run: conflictingRun,
      ),
      throwsA(isA<TaskRepositoryConflict>()),
    );

    final loaded = (await store.loadRepository()).snapshot;
    final unchanged = loaded.tasks.singleWhere((task) => task.id == 'task-b');
    expect(unchanged.status, TaskStatus.queued);
    expect(unchanged.currentRunId, isNull);
    expect(loaded.runs, hasLength(1));
    expect(loaded.runs.single.taskId, 'task-a');
    expect(await store.revision(), revisionBeforeConflict);
  });

  test('deleting a task cascades every owned record', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'ianvs-acp-task-sqlite-',
    );
    addTearDown(() async => tempDir.delete(recursive: true));
    final store = TaskInboxSqliteStore(
      path: '${tempDir.path}/task_inbox_state.sqlite3',
    );
    addTearDown(store.close);
    final createdAt = DateTime.utc(2026, 7, 10, 10);
    final task = TaskRecord(
      id: 'task-1',
      title: 'Delete me',
      description: '',
      workspacePath: '/workspace/app',
      agentName: 'Codex',
      status: TaskStatus.queued,
      priority: TaskPriority.normal,
      createdAt: createdAt,
      updatedAt: createdAt,
    );
    await store.insertTask(task);
    final run = TaskRunRecord(
      id: 'run-1',
      taskId: task.id,
      attempt: 1,
      status: TaskStatus.running,
      startedAt: createdAt,
    );
    await store.createRun(
      expectedTask: task,
      task: task.copyWith(status: TaskStatus.running, currentRunId: run.id),
      run: run,
    );
    await store.appendEvents([
      TaskEventRecord(
        id: 'event-1',
        taskId: task.id,
        runId: run.id,
        kind: TaskEventKind.system,
        text: 'Created',
        createdAt: createdAt,
      ),
    ], updatedAt: createdAt);
    final artifact = ArtifactRecord(
      id: 'artifact-1',
      taskId: task.id,
      runId: run.id,
      kind: ArtifactKind.file,
      title: 'Output',
      createdAt: createdAt,
    );
    await store.replaceArtifactsForRun(
      taskId: task.id,
      runId: run.id,
      expectedArtifacts: const <ArtifactRecord>[],
      artifacts: [artifact],
      updatedAt: createdAt,
    );
    await store.upsertApproval(
      ApprovalRequestRecord(
        id: 'approval-1',
        taskId: task.id,
        runId: run.id,
        kind: ApprovalKind.toolPermission,
        status: ApprovalStatus.pending,
        createdAt: createdAt,
        artifactIds: [artifact.id],
      ),
      updatedAt: createdAt,
    );
    final revisionBeforeReferencedDelete = await store.revision();
    await expectLater(
      store.replaceArtifactsForRun(
        taskId: task.id,
        runId: run.id,
        expectedArtifacts: [artifact],
        artifacts: const <ArtifactRecord>[],
        updatedAt: createdAt,
      ),
      throwsA(isA<TaskRepositoryConflict>()),
    );
    expect(await store.revision(), revisionBeforeReferencedDelete);

    final current = (await store.loadRepository()).snapshot;
    await store.deleteTask(
      TaskDeleteExpectation.fromSnapshot(current, task.id),
      updatedAt: createdAt,
    );

    final loaded = (await store.loadRepository()).snapshot;
    expect(loaded.tasks, isEmpty);
    expect(loaded.runs, isEmpty);
    expect(loaded.events, isEmpty);
    expect(loaded.artifacts, isEmpty);
    expect(loaded.approvals, isEmpty);
  });

  test('TaskInboxSqliteStore loads an activated normalized snapshot', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'ianvs-acp-task-sqlite-',
    );
    addTearDown(() async => tempDir.delete(recursive: true));
    final db = File('${tempDir.path}/nested/task_inbox_state.sqlite3');
    final store = TaskInboxSqliteStore(path: db.path);
    addTearDown(store.close);
    final snapshot = TaskInboxSnapshot(
      updatedAt: DateTime(2026, 7, 9, 8),
      tasks: [
        TaskRecord(
          id: 'task-1',
          title: 'SQLite task',
          description: 'Persist me locally.',
          workspacePath: '/workspace/app',
          agentName: 'Codex',
          status: TaskStatus.queued,
          priority: TaskPriority.high,
          createdAt: DateTime(2026, 7, 9, 7),
          updatedAt: DateTime(2026, 7, 9, 8),
        ),
      ],
      runs: [
        TaskRunRecord(
          id: 'run-1',
          taskId: 'task-1',
          attempt: 1,
          status: TaskStatus.running,
          startedAt: DateTime(2026, 7, 9, 8),
        ),
      ],
      artifacts: [
        ArtifactRecord(
          id: 'artifact-1',
          taskId: 'task-1',
          runId: 'run-1',
          kind: ArtifactKind.gitDiff,
          status: ArtifactStatus.approved,
          title: 'Git diff',
          createdAt: DateTime(2026, 7, 9, 8, 10),
        ),
      ],
    );

    expect((await store.loadRepository()).snapshot.tasks, isEmpty);

    await store.activateVerifiedSnapshot(snapshot, checksum: 'fixture');
    final loaded = (await store.loadRepository()).snapshot;

    expect(loaded.tasks.single.title, 'SQLite task');
    expect(loaded.tasks.single.priority, TaskPriority.high);
    expect(loaded.runs.single.id, 'run-1');
    expect(loaded.artifacts.single.status, ArtifactStatus.approved);
    expect(loaded.updatedAt, DateTime(2026, 7, 9, 8));
    expect(await store.revision(), 1);
  });

  test('TaskInboxSqliteStore reports malformed normalized payload', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'ianvs-acp-task-sqlite-',
    );
    addTearDown(() async => tempDir.delete(recursive: true));
    final db = File('${tempDir.path}/task_inbox_state.sqlite3');
    final store = TaskInboxSqliteStore(path: db.path);
    await store.initialize();
    await store.close();
    final database = sqlite3.open(db.path);
    database.execute(
      'INSERT INTO tasks '
      '(id, title, description, workspace_path, agent_name, status, priority, '
      'created_at, updated_at, skill_ids_json, metadata_json, payload_json) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
      [
        'task-broken',
        'Broken',
        '',
        '/workspace',
        'Codex',
        'queued',
        'normal',
        '2026-07-09T08:00:00Z',
        '2026-07-09T08:00:00Z',
        '[]',
        '{}',
        '{bad json',
      ],
    );
    database.close();
    final reopened = TaskInboxSqliteStore(path: db.path);
    addTearDown(reopened.close);

    await expectLater(reopened.loadRepository(), throwsFormatException);
  });

  test('TaskInboxSqliteStore rejects incomplete normalized records', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'ianvs-acp-task-sqlite-',
    );
    addTearDown(() async => tempDir.delete(recursive: true));
    final db = File('${tempDir.path}/task_inbox_state.sqlite3');
    final store = TaskInboxSqliteStore(path: db.path);
    await store.initialize();
    await store.close();
    final database = sqlite3.open(db.path);
    database.execute(
      'INSERT INTO tasks '
      '(id, title, description, workspace_path, agent_name, status, priority, '
      'created_at, updated_at, skill_ids_json, metadata_json, payload_json) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
      [
        'task-incomplete',
        'Incomplete',
        '',
        '/workspace',
        'Codex',
        'queued',
        'normal',
        '2026-07-09T08:00:00Z',
        '2026-07-09T08:00:00Z',
        '[]',
        '{}',
        '{}',
      ],
    );
    database.close();
    final reopened = TaskInboxSqliteStore(path: db.path);
    addTearDown(reopened.close);

    await expectLater(reopened.loadRepository(), throwsFormatException);
  });

  test(
    'TaskInboxSqliteStore rejects column and payload disagreement',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'ianvs-acp-task-sqlite-',
      );
      addTearDown(() async => tempDir.delete(recursive: true));
      final path = '${tempDir.path}/task_inbox_state.sqlite3';
      final store = TaskInboxSqliteStore(path: path);
      final createdAt = DateTime.utc(2026, 7, 10, 10);
      await store.insertTask(
        TaskRecord(
          id: 'task-1',
          title: 'Consistent',
          description: '',
          workspacePath: '/workspace/app',
          agentName: 'Codex',
          status: TaskStatus.inbox,
          priority: TaskPriority.normal,
          createdAt: createdAt,
          updatedAt: createdAt,
        ),
      );
      await store.close();
      final database = sqlite3.open(path);
      database.execute("UPDATE tasks SET status = 'done' WHERE id = 'task-1';");
      database.close();
      final reopened = TaskInboxSqliteStore(path: path);
      addTearDown(reopened.close);

      await expectLater(reopened.loadRepository(), throwsFormatException);
    },
  );

  test('competing import cannot overwrite an active repository', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'ianvs-acp-task-sqlite-',
    );
    addTearDown(() async => tempDir.delete(recursive: true));
    final path = '${tempDir.path}/task_inbox_state.sqlite3';
    final first = TaskInboxSqliteStore(path: path);
    final second = TaskInboxSqliteStore(path: path);
    addTearDown(first.close);
    addTearDown(second.close);
    final createdAt = DateTime.utc(2026, 7, 10, 10);
    TaskInboxSnapshot snapshot(String title) => TaskInboxSnapshot(
      updatedAt: createdAt,
      tasks: [
        TaskRecord(
          id: 'task-1',
          title: title,
          description: '',
          workspacePath: '/workspace/app',
          agentName: 'Codex',
          status: TaskStatus.inbox,
          priority: TaskPriority.normal,
          createdAt: createdAt,
          updatedAt: createdAt,
        ),
      ],
    );

    await first.importSnapshot(snapshot('first'), checksum: 'first-checksum');
    await first.activateImport('first-checksum');
    await second.importSnapshot(
      snapshot('second'),
      checksum: 'second-checksum',
    );

    expect(
      (await second.loadRepository()).snapshot.tasks.single.title,
      'first',
    );
    expect(await second.isActive(), isTrue);
  });

  test('competing import cannot overwrite a recoverable repository', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'ianvs-acp-task-sqlite-',
    );
    addTearDown(() async => tempDir.delete(recursive: true));
    final path = '${tempDir.path}/task_inbox_state.sqlite3';
    final first = TaskInboxSqliteStore(path: path);
    final second = TaskInboxSqliteStore(path: path);
    addTearDown(first.close);
    addTearDown(second.close);
    final createdAt = DateTime.utc(2026, 7, 10, 10);
    TaskInboxSnapshot snapshot(String title) => TaskInboxSnapshot(
      updatedAt: createdAt,
      tasks: [
        TaskRecord(
          id: 'task-1',
          title: title,
          description: '',
          workspacePath: '/workspace/app',
          agentName: 'Codex',
          status: TaskStatus.inbox,
          priority: TaskPriority.normal,
          createdAt: createdAt,
          updatedAt: createdAt,
        ),
      ],
    );

    await first.importSnapshot(snapshot('first'), checksum: 'first-checksum');
    await first.rollbackImport('first-checksum');

    await expectLater(
      second.importSnapshot(snapshot('second'), checksum: 'second-checksum'),
      throwsStateError,
    );
    expect(
      (await second.loadRepository()).snapshot.tasks.single.title,
      'first',
    );
    final metadata = await second.migrationMetadata();
    expect(metadata.phase, TaskMigrationPhase.inactive);
    expect(metadata.sourceChecksum, 'first-checksum');
  });
}

Future<void> _claimTaskInIsolate(List<Object?> arguments) async {
  final path = arguments[0]! as String;
  final runId = arguments[1]! as String;
  final eventId = arguments[2]! as String;
  final resultPort = arguments[3]! as SendPort;
  final start = ReceivePort();
  final store = TaskInboxSqliteStore(path: path);
  try {
    final expectedTask = (await store.loadRepository()).snapshot.tasks.single;
    resultPort.send(<String, Object?>{'type': 'ready', 'port': start.sendPort});
    await start.first;
    final startedAt = DateTime.utc(2026, 7, 10, 10, 1);
    final claim = await store.claimTask(
      expectedTask,
      TaskRunRecord(
        id: runId,
        taskId: 'task-1',
        attempt: 1,
        status: TaskStatus.dispatched,
        startedAt: startedAt,
      ),
      dispatchEvent: TaskEventRecord(
        id: eventId,
        taskId: 'task-1',
        runId: runId,
        kind: TaskEventKind.system,
        text: 'Task dispatched.',
        createdAt: startedAt,
      ),
    );
    resultPort.send(<String, Object?>{
      'type': 'result',
      'run_id': claim?.run.id,
    });
  } on Object catch (error, stackTrace) {
    resultPort.send(<String, Object?>{
      'type': 'error',
      'error': '$error\n$stackTrace',
    });
  } finally {
    start.close();
    await store.close();
  }
}
