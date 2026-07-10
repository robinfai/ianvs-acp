import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/tasks/task_inbox_snapshot.dart';
import 'package:ianvs_acp/tasks/task_inbox_sqlite_store.dart';
import 'package:ianvs_acp/tasks/task_record.dart';
import 'package:sqlite3/sqlite3.dart';

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

  test('TaskInboxSqliteStore saves and loads snapshot from SQLite', () async {
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

    expect((await store.load()).tasks, isEmpty);

    await store.save(snapshot);
    final loaded = await store.load();

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

    await expectLater(reopened.load(), throwsFormatException);
  });
}
