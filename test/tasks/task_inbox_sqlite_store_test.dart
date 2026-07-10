import 'dart:io';

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
