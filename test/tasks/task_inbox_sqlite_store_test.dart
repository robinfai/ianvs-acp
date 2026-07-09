import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/tasks/task_inbox_snapshot.dart';
import 'package:ianvs_acp/tasks/task_inbox_sqlite_store.dart';
import 'package:ianvs_acp/tasks/task_record.dart';

void main() {
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

    final query = await Process.run('sqlite3', [
      db.path,
      'SELECT schema, updated_at FROM task_inbox_state WHERE id = 1;',
    ]);
    expect(query.exitCode, 0);
    expect(
      (query.stdout as String).trim(),
      'ianvs-acp.task-inbox.v1|2026-07-09T08:00:00.000',
    );
  });

  test('TaskInboxSqliteStore loads malformed payload as empty', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'ianvs-acp-task-sqlite-',
    );
    addTearDown(() async => tempDir.delete(recursive: true));
    final db = File('${tempDir.path}/task_inbox_state.sqlite3');
    await Process.run('sqlite3', [
      db.path,
      "CREATE TABLE task_inbox_state (id INTEGER PRIMARY KEY, schema TEXT, "
          "updated_at TEXT, payload TEXT);"
          "INSERT INTO task_inbox_state VALUES "
          "(1, 'ianvs-acp.task-inbox.v1', 'bad-date', '{bad json');",
    ]);
    final store = TaskInboxSqliteStore(path: db.path);

    final loaded = await store.load();

    expect(loaded.tasks, isEmpty);
    expect(loaded.runs, isEmpty);
  });
}
