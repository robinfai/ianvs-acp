import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import 'task_inbox_snapshot.dart';
import 'task_record.dart';
import 'task_repository.dart';
import 'task_store.dart';
import 'workspace_resource.dart';

class TaskInboxSqliteStore
    implements TaskStore, TaskRepository, TaskMigrationRepository {
  TaskInboxSqliteStore({required this.path});

  static const String fileName = 'task_inbox_state.sqlite3';

  final String? path;
  Database? _database;

  static String? defaultPath({
    String? configPath,
    Map<String, String>? environment,
  }) {
    final config = configPath?.trim();
    if (config != null && config.isNotEmpty) {
      return _joinPath(File(config).parent.path, fileName);
    }

    final env = environment ?? Platform.environment;
    final xdgConfigHome = env['XDG_CONFIG_HOME']?.trim();
    if (xdgConfigHome != null && xdgConfigHome.isNotEmpty) {
      return _joinPath(_joinPath(xdgConfigHome, 'ianvs-acp'), fileName);
    }

    final home = env['HOME']?.trim();
    if (home == null || home.isEmpty) return null;
    return _joinPath(
      _joinPath(_joinPath(home, '.config'), 'ianvs-acp'),
      fileName,
    );
  }

  @override
  Future<void> initialize() async {
    if (_database != null) return;
    final targetPath = path?.trim();
    if (targetPath == null || targetPath.isEmpty) {
      _database = sqlite3.openInMemory();
    } else {
      await File(targetPath).parent.create(recursive: true);
      _database = sqlite3.open(targetPath);
    }
    final database = _database!;
    database.execute('PRAGMA journal_mode = WAL;');
    database.execute('PRAGMA synchronous = FULL;');
    database.execute('PRAGMA foreign_keys = ON;');
    database.execute('PRAGMA busy_timeout = 5000;');
    database.execute(_schemaSql);
    database.execute(
      'INSERT OR IGNORE INTO schema_migrations (version, applied_at) '
      'VALUES (1, ?);',
      [DateTime.now().toUtc().toIso8601String()],
    );
    database.execute(
      'INSERT OR IGNORE INTO store_meta '
      '(id, revision, migration_state, source_checksum, updated_at) '
      "VALUES (1, 0, 'active', NULL, ?);",
      [DateTime.now().toUtc().toIso8601String()],
    );
  }

  Future<String> journalMode() async {
    await initialize();
    final row = _database!.select('PRAGMA journal_mode;').first;
    return row.values.first.toString().toLowerCase();
  }

  Future<bool> foreignKeysEnabled() async {
    await initialize();
    final row = _database!.select('PRAGMA foreign_keys;').first;
    return row.values.first == 1;
  }

  Future<Set<String>> tableNames() async {
    await initialize();
    final rows = _database!.select(
      "SELECT name FROM sqlite_master WHERE type = 'table';",
    );
    return rows.map((row) => row['name'].toString()).toSet();
  }

  @override
  Future<TaskInboxSnapshot> load() async {
    await initialize();
    final database = _database!;
    final meta = database.select(
      'SELECT updated_at FROM store_meta WHERE id = 1;',
    );
    final updatedAt = meta.isEmpty
        ? DateTime.now()
        : DateTime.tryParse(meta.first['updated_at'].toString())?.toLocal() ??
              DateTime.now();
    return TaskInboxSnapshot(
      updatedAt: updatedAt,
      tasks: _readRecords(database, 'tasks', TaskRecord.fromJson),
      runs: _readRecords(database, 'task_runs', TaskRunRecord.fromJson),
      events: _readRecords(database, 'task_events', TaskEventRecord.fromJson),
      artifacts: _readRecords(database, 'artifacts', ArtifactRecord.fromJson),
      approvals: _readRecords(
        database,
        'approval_requests',
        ApprovalRequestRecord.fromJson,
      ),
      resources: _readRecords(
        database,
        'workspace_resources',
        WorkspaceResource.fromJson,
      ),
    );
  }

  @override
  Future<TaskRepositorySnapshot> loadRepository() async {
    final snapshot = await load();
    return TaskRepositorySnapshot(
      revision: await revision(),
      snapshot: snapshot,
    );
  }

  @override
  Future<void> save(TaskInboxSnapshot snapshot) async {
    await initialize();
    _writeTransaction<void>((database) {
      _clearRecords(database);
      for (final resource in snapshot.resources) {
        _upsertResource(database, resource);
      }
      for (final task in snapshot.tasks) {
        _upsertTask(database, task);
      }
      for (final run in snapshot.runs) {
        _upsertRun(database, run);
      }
      for (final event in snapshot.events) {
        _insertEvent(database, event);
      }
      for (final artifact in snapshot.artifacts) {
        _insertArtifact(database, artifact);
      }
      for (final approval in snapshot.approvals) {
        _upsertApproval(database, approval);
      }
      database.execute(
        'UPDATE store_meta SET updated_at = ?, migration_state = ? '
        'WHERE id = 1;',
        [snapshot.updatedAt.toUtc().toIso8601String(), 'active'],
      );
    });
  }

  @override
  Future<TaskRecord> insertTask(TaskRecord task) async {
    await initialize();
    _writeTransaction<void>((database) => _upsertTask(database, task));
    return task;
  }

  @override
  Future<TaskRecord> updateTask(TaskRecord task) => insertTask(task);

  @override
  Future<TaskClaim?> claimTask(String taskId, TaskRunRecord run) async {
    await initialize();
    final database = _database!;
    database.execute('BEGIN IMMEDIATE;');
    try {
      final rows = database.select(
        'SELECT payload_json FROM tasks WHERE id = ? AND status = ?;',
        [taskId.trim(), TaskStatus.queued.jsonValue],
      );
      if (rows.isEmpty) {
        database.execute('ROLLBACK;');
        return null;
      }
      final task = TaskRecord.fromJson(_decodePayload(rows.first));
      if (task == null || run.taskId != task.id) {
        database.execute('ROLLBACK;');
        return null;
      }
      final claimedTask = task.copyWith(
        status: TaskStatus.dispatched,
        currentRunId: run.id,
        updatedAt: run.startedAt,
      );
      _upsertTask(database, claimedTask);
      _upsertRun(database, run);
      database.execute(
        'UPDATE store_meta SET revision = revision + 1 WHERE id = 1;',
      );
      database.execute('COMMIT;');
      return TaskClaim(task: claimedTask, run: run);
    } on Object {
      database.execute('ROLLBACK;');
      rethrow;
    }
  }

  @override
  Future<TaskRunRecord> updateRun(TaskRunRecord run) async {
    await initialize();
    _writeTransaction<void>((database) => _upsertRun(database, run));
    return run;
  }

  @override
  Future<void> appendEvents(List<TaskEventRecord> events) async {
    if (events.isEmpty) return;
    await initialize();
    _writeTransaction<void>((database) {
      for (final event in events) {
        _insertEvent(database, event);
      }
    });
  }

  @override
  Future<void> replaceArtifactsForRun({
    required String taskId,
    required String runId,
    required List<ArtifactRecord> artifacts,
  }) async {
    await initialize();
    _writeTransaction<void>((database) {
      database.execute(
        'DELETE FROM artifacts WHERE task_id = ? AND run_id = ?;',
        [taskId, runId],
      );
      for (final artifact in artifacts) {
        if (artifact.taskId != taskId || artifact.runId != runId) {
          throw StateError('Artifacts must belong to one task run.');
        }
        _insertArtifact(database, artifact);
      }
    });
  }

  @override
  Future<void> upsertApproval(ApprovalRequestRecord approval) async {
    await initialize();
    _writeTransaction<void>((database) => _upsertApproval(database, approval));
  }

  @override
  Future<void> upsertResource(WorkspaceResource resource) async {
    await initialize();
    _writeTransaction<void>((database) => _upsertResource(database, resource));
  }

  @override
  Future<int> revision() async {
    await initialize();
    final rows = _database!.select(
      'SELECT revision FROM store_meta WHERE id = 1;',
    );
    return rows.isEmpty ? 0 : rows.first['revision'] as int;
  }

  @override
  Future<bool> isActive() async {
    await initialize();
    final rows = _database!.select(
      'SELECT migration_state FROM store_meta WHERE id = 1;',
    );
    return rows.isNotEmpty && rows.first['migration_state'] == 'active';
  }

  @override
  Future<void> importSnapshot(
    TaskInboxSnapshot snapshot, {
    required String checksum,
  }) async {
    await save(snapshot);
    _writeTransaction<void>((database) {
      database.execute(
        'UPDATE store_meta SET migration_state = ?, source_checksum = ? '
        'WHERE id = 1;',
        ['importing', checksum],
      );
    });
  }

  @override
  Future<void> rollbackImport(String checksum) async {
    await initialize();
    _writeTransaction<void>((database) {
      final rows = database.select(
        'SELECT source_checksum FROM store_meta WHERE id = 1;',
      );
      if (rows.isEmpty || rows.first['source_checksum'] != checksum) return;
      _clearRecords(database);
      database.execute(
        'UPDATE store_meta SET migration_state = ?, source_checksum = NULL '
        'WHERE id = 1;',
        ['inactive'],
      );
    });
  }

  @override
  Future<void> activateImport(String checksum) async {
    await initialize();
    _writeTransaction<void>((database) {
      database.execute(
        'UPDATE store_meta SET migration_state = ? '
        'WHERE id = 1 AND source_checksum = ?;',
        ['active', checksum],
      );
    });
  }

  @override
  Future<void> close() async {
    final database = _database;
    _database = null;
    database?.close();
  }

  T _writeTransaction<T>(T Function(Database database) action) {
    final database = _database!;
    database.execute('BEGIN IMMEDIATE;');
    try {
      final result = action(database);
      database.execute(
        'UPDATE store_meta SET revision = revision + 1 WHERE id = 1;',
      );
      database.execute('COMMIT;');
      return result;
    } on Object {
      database.execute('ROLLBACK;');
      rethrow;
    }
  }

  static void _clearRecords(Database database) {
    database.execute('DELETE FROM approval_requests;');
    database.execute('DELETE FROM artifacts;');
    database.execute('DELETE FROM task_events;');
    database.execute('DELETE FROM task_runs;');
    database.execute('DELETE FROM tasks;');
    database.execute('DELETE FROM workspace_resources;');
  }

  static void _upsertTask(Database database, TaskRecord task) {
    database.execute(
      'INSERT INTO tasks '
      '(id, title, description, workspace_path, agent_name, status, priority, '
      'created_at, updated_at, session_id, current_run_id, summary, error, '
      'resource_id, skill_ids_json, metadata_json, payload_json) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(id) DO UPDATE SET '
      'title=excluded.title, description=excluded.description, '
      'workspace_path=excluded.workspace_path, agent_name=excluded.agent_name, '
      'status=excluded.status, priority=excluded.priority, '
      'created_at=excluded.created_at, updated_at=excluded.updated_at, '
      'session_id=excluded.session_id, current_run_id=excluded.current_run_id, '
      'summary=excluded.summary, error=excluded.error, '
      'resource_id=excluded.resource_id, skill_ids_json=excluded.skill_ids_json, '
      'metadata_json=excluded.metadata_json, payload_json=excluded.payload_json;',
      [
        task.id,
        task.title,
        task.description,
        task.workspacePath,
        task.agentName,
        task.status.jsonValue,
        task.priority.jsonValue,
        task.createdAt.toUtc().toIso8601String(),
        task.updatedAt.toUtc().toIso8601String(),
        task.sessionId,
        task.currentRunId,
        task.summary,
        task.error,
        task.resourceId,
        jsonEncode(task.skillIds),
        jsonEncode(task.metadata),
        jsonEncode(task.toJson()),
      ],
    );
  }

  static void _upsertRun(Database database, TaskRunRecord run) {
    database.execute(
      'INSERT INTO task_runs '
      '(id, task_id, attempt, status, started_at, ended_at, session_id, '
      'prompt_snapshot, model, error, payload_json) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(id) DO UPDATE SET status=excluded.status, '
      'ended_at=excluded.ended_at, session_id=excluded.session_id, '
      'prompt_snapshot=excluded.prompt_snapshot, model=excluded.model, '
      'error=excluded.error, payload_json=excluded.payload_json;',
      [
        run.id,
        run.taskId,
        run.attempt,
        run.status.jsonValue,
        run.startedAt.toUtc().toIso8601String(),
        run.endedAt?.toUtc().toIso8601String(),
        run.sessionId,
        run.promptSnapshot,
        run.model,
        run.error,
        jsonEncode(run.toJson()),
      ],
    );
  }

  static void _insertEvent(Database database, TaskEventRecord event) {
    database.execute(
      'INSERT OR REPLACE INTO task_events '
      '(id, task_id, run_id, kind, text, created_at, session_id, '
      'metadata_json, payload_json) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);',
      [
        event.id,
        event.taskId,
        event.runId,
        event.kind.jsonValue,
        event.text,
        event.createdAt.toUtc().toIso8601String(),
        event.sessionId,
        jsonEncode(event.metadata),
        jsonEncode(event.toJson()),
      ],
    );
  }

  static void _insertArtifact(Database database, ArtifactRecord artifact) {
    database.execute(
      'INSERT OR REPLACE INTO artifacts '
      '(id, task_id, run_id, kind, status, title, created_at, path, '
      'content_preview, sha256, size_bytes, metadata_json, payload_json) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
      [
        artifact.id,
        artifact.taskId,
        artifact.runId,
        artifact.kind.jsonValue,
        artifact.status.jsonValue,
        artifact.title,
        artifact.createdAt.toUtc().toIso8601String(),
        artifact.path,
        artifact.contentPreview,
        artifact.sha256,
        artifact.sizeBytes,
        jsonEncode(artifact.metadata),
        jsonEncode(artifact.toJson()),
      ],
    );
  }

  static void _upsertApproval(
    Database database,
    ApprovalRequestRecord approval,
  ) {
    database.execute(
      'INSERT INTO approval_requests '
      '(id, task_id, run_id, kind, status, created_at, resolved_at, rationale, '
      'metadata_json, payload_json) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(id) DO UPDATE SET status=excluded.status, '
      'resolved_at=excluded.resolved_at, rationale=excluded.rationale, '
      'metadata_json=excluded.metadata_json, payload_json=excluded.payload_json;',
      [
        approval.id,
        approval.taskId,
        approval.runId,
        approval.kind.jsonValue,
        approval.status.jsonValue,
        approval.createdAt.toUtc().toIso8601String(),
        approval.resolvedAt?.toUtc().toIso8601String(),
        approval.rationale,
        jsonEncode(approval.metadata),
        jsonEncode(approval.toJson()),
      ],
    );
  }

  static void _upsertResource(Database database, WorkspaceResource resource) {
    database.execute(
      'INSERT INTO workspace_resources '
      '(id, type, label, ref_json, serial, payload_json) '
      'VALUES (?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(id) DO UPDATE SET type=excluded.type, '
      'label=excluded.label, ref_json=excluded.ref_json, '
      'serial=excluded.serial, payload_json=excluded.payload_json;',
      [
        resource.id,
        resource.type.jsonValue,
        resource.label,
        jsonEncode(resource.ref),
        resource.serial ? 1 : 0,
        jsonEncode(resource.toJson()),
      ],
    );
  }

  static List<T> _readRecords<T>(
    Database database,
    String table,
    T? Function(Object? raw) reader,
  ) {
    final rows = database.select(
      'SELECT payload_json FROM $table ORDER BY rowid;',
    );
    return List<T>.unmodifiable(
      rows.map(_decodePayload).map(reader).whereType<T>(),
    );
  }

  static Object? _decodePayload(Row row) {
    final payload = row['payload_json'];
    return payload is String ? jsonDecode(payload) : null;
  }

  static String _joinPath(String directory, String basename) {
    if (directory.endsWith(Platform.pathSeparator)) {
      return '$directory$basename';
    }
    return '$directory${Platform.pathSeparator}$basename';
  }
}

const String _schemaSql = '''
CREATE TABLE IF NOT EXISTS schema_migrations (
  version INTEGER PRIMARY KEY,
  applied_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS store_meta (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  revision INTEGER NOT NULL,
  migration_state TEXT NOT NULL,
  source_checksum TEXT,
  updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS workspace_resources (
  id TEXT PRIMARY KEY,
  type TEXT NOT NULL,
  label TEXT NOT NULL,
  ref_json TEXT NOT NULL,
  serial INTEGER NOT NULL,
  payload_json TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS tasks (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  description TEXT NOT NULL,
  workspace_path TEXT NOT NULL,
  agent_name TEXT NOT NULL,
  status TEXT NOT NULL,
  priority TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  session_id TEXT,
  current_run_id TEXT,
  summary TEXT,
  error TEXT,
  resource_id TEXT,
  skill_ids_json TEXT NOT NULL,
  metadata_json TEXT NOT NULL,
  payload_json TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS task_runs (
  id TEXT PRIMARY KEY,
  task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  attempt INTEGER NOT NULL,
  status TEXT NOT NULL,
  started_at TEXT NOT NULL,
  ended_at TEXT,
  session_id TEXT,
  prompt_snapshot TEXT,
  model TEXT,
  error TEXT,
  payload_json TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS task_events (
  id TEXT PRIMARY KEY,
  task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  run_id TEXT NOT NULL REFERENCES task_runs(id) ON DELETE CASCADE,
  kind TEXT NOT NULL,
  text TEXT NOT NULL,
  created_at TEXT NOT NULL,
  session_id TEXT,
  metadata_json TEXT NOT NULL,
  payload_json TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS artifacts (
  id TEXT PRIMARY KEY,
  task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  run_id TEXT NOT NULL REFERENCES task_runs(id) ON DELETE CASCADE,
  kind TEXT NOT NULL,
  status TEXT NOT NULL,
  title TEXT NOT NULL,
  created_at TEXT NOT NULL,
  path TEXT,
  content_preview TEXT,
  sha256 TEXT,
  size_bytes INTEGER,
  metadata_json TEXT NOT NULL,
  payload_json TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS approval_requests (
  id TEXT PRIMARY KEY,
  task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  run_id TEXT REFERENCES task_runs(id) ON DELETE CASCADE,
  kind TEXT NOT NULL,
  status TEXT NOT NULL,
  created_at TEXT NOT NULL,
  resolved_at TEXT,
  rationale TEXT,
  metadata_json TEXT NOT NULL,
  payload_json TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);
CREATE INDEX IF NOT EXISTS idx_task_runs_task ON task_runs(task_id);
CREATE INDEX IF NOT EXISTS idx_task_events_run ON task_events(run_id);
CREATE INDEX IF NOT EXISTS idx_artifacts_run ON artifacts(run_id);
''';
