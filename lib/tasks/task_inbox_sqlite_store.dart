import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../platform/secure_atomic_file.dart';
import 'task_data_sanitizer.dart';
import 'task_inbox_snapshot.dart';
import 'task_record.dart';
import 'task_repository.dart';
import 'workspace_resource.dart';

class TaskInboxSqliteStore
    implements
        TaskRepository,
        TaskMigrationRepository,
        AtomicTaskClaimMetadataRepository,
        RawPayloadMaintenanceRepository {
  TaskInboxSqliteStore({required this.path});

  static const String fileName = 'task_inbox_state.sqlite3';

  final String? path;
  Database? _database;
  Future<void>? _initializeFuture;

  static String? defaultPath({
    String? configPath,
    Map<String, String>? environment,
  }) {
    final config = configPath?.trim();
    if (config != null && config.isNotEmpty) {
      final configDirectory = File(config).parent;
      final stateDirectory = _isAppOwnedStateDirectory(configDirectory)
          ? configDirectory.path
          : _joinPath(configDirectory.path, '.ianvs-acp');
      return _joinPath(stateDirectory, fileName);
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
  Future<void> initialize() {
    if (_database != null) return Future<void>.value();
    return _initializeFuture ??= _initializeOnce();
  }

  Future<void> _initializeOnce() async {
    if (_database != null) return;
    final targetPath = path?.trim();
    try {
      if (targetPath == null || targetPath.isEmpty) {
        _database = sqlite3.openInMemory();
      } else {
        final requestedFile = File(targetPath);
        final requestedType = await FileSystemEntity.type(
          requestedFile.path,
          followLinks: false,
        );
        if (requestedType == FileSystemEntityType.link) {
          throw FileSystemException(
            'Task repository database must not be a symbolic link.',
            requestedFile.path,
          );
        }
        final parentExisted = await requestedFile.parent.exists();
        await requestedFile.parent.create(recursive: true);
        final resolvedParent = Directory(
          await requestedFile.parent.resolveSymbolicLinks(),
        );
        if (!parentExisted || _isAppOwnedStateDirectory(resolvedParent)) {
          await SecureAtomicFile.protectPrivateDirectory(resolvedParent);
        }
        final databaseFile = File(
          _joinPath(resolvedParent.path, requestedFile.uri.pathSegments.last),
        );
        await _protectSqliteFiles(databaseFile, createDatabase: true);
        _database = sqlite3.open(databaseFile.path);
      }
      final database = _database!;
      database.execute('PRAGMA busy_timeout = 5000;');
      database.execute('PRAGMA journal_mode = WAL;');
      database.execute('PRAGMA synchronous = FULL;');
      database.execute('PRAGMA foreign_keys = ON;');
      database.execute('PRAGMA secure_delete = ON;');
      _rejectUnsupportedSchema(database);
      database.execute(_schemaSql);
      _applySchemaMigrations(database);
      database.execute(
        'INSERT OR IGNORE INTO store_meta '
        '(id, revision, migration_state, source_checksum, updated_at, '
        'last_raw_payload_purge_at) '
        "VALUES (1, 0, 'inactive', NULL, ?, NULL);",
        [DateTime.now().toUtc().toIso8601String()],
      );
      if (targetPath != null && targetPath.isNotEmpty) {
        final requestedFile = File(targetPath);
        final resolvedParent = Directory(
          await requestedFile.parent.resolveSymbolicLinks(),
        );
        await _protectSqliteFiles(
          File(
            _joinPath(resolvedParent.path, requestedFile.uri.pathSegments.last),
          ),
        );
      }
    } on Object {
      final database = _database;
      _database = null;
      database?.close();
      _initializeFuture = null;
      rethrow;
    }
  }

  static Future<void> _protectSqliteFiles(
    File databaseFile, {
    bool createDatabase = false,
  }) async {
    await SecureAtomicFile.protectPrivateFile(
      databaseFile,
      create: createDatabase,
    );
    await SecureAtomicFile.protectPrivateFile(
      File('${databaseFile.path}-wal'),
      create: false,
    );
    await SecureAtomicFile.protectPrivateFile(
      File('${databaseFile.path}-shm'),
      create: false,
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

  static TaskInboxSnapshot _loadSnapshot(Database database) {
    final meta = database.select(
      'SELECT updated_at FROM store_meta WHERE id = 1;',
    );
    final updatedAt = meta.isEmpty
        ? DateTime.now()
        : DateTime.tryParse(meta.first['updated_at'].toString()) ??
              DateTime.now();
    final snapshot = TaskInboxSnapshot(
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
    snapshot.validateReferences();
    return snapshot;
  }

  @override
  Future<TaskRepositorySnapshot> loadRepository() async {
    await initialize();
    final database = _database!;
    database.execute('BEGIN;');
    try {
      final rows = database.select(
        'SELECT revision FROM store_meta WHERE id = 1;',
      );
      final loaded = TaskRepositorySnapshot(
        revision: rows.isEmpty ? 0 : rows.first['revision'] as int,
        snapshot: _loadSnapshot(database),
      );
      database.execute('COMMIT;');
      return loaded;
    } on Object {
      database.execute('ROLLBACK;');
      rethrow;
    }
  }

  @override
  Future<TaskRecord> insertTask(TaskRecord task) async {
    await initialize();
    _writeTransaction<void>((database) {
      if (_recordExists(database, 'tasks', task.id)) {
        throw TaskRepositoryConflict('Task already exists: ${task.id}');
      }
      _validateTaskLinks(database, task);
      _upsertTask(database, task);
    }, updatedAt: task.updatedAt);
    return task;
  }

  @override
  Future<TaskRecord> updateTask(
    TaskRecord task, {
    required TaskRecord expected,
    TaskExecutorCommandContext? executorContext,
  }) async {
    if (task.id != expected.id || task.createdAt != expected.createdAt) {
      throw ArgumentError('Updated task must keep its identity.');
    }
    await initialize();
    _writeTransaction<void>((database) {
      _expectPayload(
        database,
        table: 'tasks',
        id: task.id,
        expected: expected.toJson(),
        recordLabel: 'Task',
      );
      _validateTaskLinks(database, task);
      _upsertTask(database, task);
    }, updatedAt: task.updatedAt);
    return task;
  }

  @override
  Future<void> deleteTask(
    TaskDeleteExpectation expected, {
    required DateTime updatedAt,
  }) async {
    await initialize();
    _writeTransaction<void>((database) {
      _expectPayload(
        database,
        table: 'tasks',
        id: expected.task.id,
        expected: expected.task.toJson(),
        recordLabel: 'Task',
      );
      _expectOwnedRecordSet(
        database,
        table: 'task_runs',
        taskId: expected.task.id,
        expected: expected.runs,
      );
      _expectOwnedRecordSet(
        database,
        table: 'task_events',
        taskId: expected.task.id,
        expected: expected.events,
      );
      _expectOwnedRecordSet(
        database,
        table: 'artifacts',
        taskId: expected.task.id,
        expected: expected.artifacts,
      );
      _expectOwnedRecordSet(
        database,
        table: 'approval_requests',
        taskId: expected.task.id,
        expected: expected.approvals,
      );
      database.execute('DELETE FROM tasks WHERE id = ?;', [expected.task.id]);
    }, updatedAt: updatedAt);
  }

  @override
  Future<TaskRunCreation> createRun({
    required TaskRecord expectedTask,
    required TaskRecord task,
    required TaskRunRecord run,
  }) async {
    if (task.id != expectedTask.id ||
        task.createdAt != expectedTask.createdAt ||
        run.taskId != task.id) {
      throw ArgumentError('Task run must belong to the updated task.');
    }
    if (task.currentRunId != run.id) {
      throw ArgumentError('Updated task must reference the new run.');
    }
    await initialize();
    _writeTransaction<void>((database) {
      _expectPayload(
        database,
        table: 'tasks',
        id: task.id,
        expected: expectedTask.toJson(),
        recordLabel: 'Task',
      );
      if (_recordExists(database, 'task_runs', run.id)) {
        throw TaskRepositoryConflict('Task run already exists: ${run.id}');
      }
      _upsertRun(database, run);
      _validateTaskLinks(database, task);
      _upsertTask(database, task);
    }, updatedAt: task.updatedAt);
    return TaskRunCreation(task: task, run: run);
  }

  @override
  Future<TaskClaim?> claimTask(
    TaskRecord expectedTask,
    TaskRunRecord run, {
    required TaskEventRecord dispatchEvent,
    WorkspaceResource? expectedResource,
  }) {
    return _claimTask(
      expectedTask,
      run,
      dispatchEvent: dispatchEvent,
      expectedResource: expectedResource,
    );
  }

  @override
  Future<TaskClaim?> claimTaskWithMetadata(
    TaskRecord expectedTask,
    TaskRunRecord run, {
    required TaskEventRecord dispatchEvent,
    WorkspaceResource? expectedResource,
    required Map<String, Object?> claimedMetadata,
  }) {
    return _claimTask(
      expectedTask,
      run,
      dispatchEvent: dispatchEvent,
      expectedResource: expectedResource,
      claimedMetadata: claimedMetadata,
    );
  }

  Future<TaskClaim?> _claimTask(
    TaskRecord expectedTask,
    TaskRunRecord run, {
    required TaskEventRecord dispatchEvent,
    WorkspaceResource? expectedResource,
    Map<String, Object?>? claimedMetadata,
  }) async {
    if (run.status != TaskStatus.dispatched || run.endedAt != null) {
      throw ArgumentError('Claimed task runs must start dispatched.');
    }
    await initialize();
    final database = _database!;
    database.execute('BEGIN IMMEDIATE;');
    try {
      final rows = database.select(
        'SELECT payload_json FROM tasks WHERE id = ? AND status = ?;',
        [expectedTask.id, TaskStatus.queued.jsonValue],
      );
      if (rows.isEmpty) {
        database.execute('ROLLBACK;');
        return null;
      }
      final task = TaskRecord.fromJson(_decodePayload(rows.first));
      if (task == null) {
        throw const FormatException('Invalid queued task payload.');
      }
      if (!_sameRecord(task, expectedTask)) {
        database.execute('ROLLBACK;');
        return null;
      }
      if (run.taskId != task.id ||
          dispatchEvent.taskId != task.id ||
          dispatchEvent.runId != run.id) {
        throw ArgumentError('Claim records must belong to the queued task.');
      }
      if (!_resourceMatchesExpectation(database, task, expectedResource)) {
        database.execute('ROLLBACK;');
        return null;
      }
      if (_recordExists(database, 'task_runs', run.id)) {
        throw TaskRepositoryConflict('Task run already exists: ${run.id}');
      }
      if (_recordExists(database, 'task_events', dispatchEvent.id)) {
        throw TaskRepositoryConflict(
          'Task event already exists: ${dispatchEvent.id}',
        );
      }
      final attemptRows = database.select(
        'SELECT COALESCE(MAX(attempt), 0) + 1 AS next_attempt '
        'FROM task_runs WHERE task_id = ?;',
        [task.id],
      );
      final nextAttempt = attemptRows.single['next_attempt'];
      if (nextAttempt is! int || nextAttempt < 1) {
        throw StateError('Could not calculate the next task run attempt.');
      }
      final claimAt = _latestTimestamp(
        task.updatedAt,
        run.startedAt,
        dispatchEvent.createdAt,
      );
      final actualRun = run.copyWith(attempt: nextAttempt, startedAt: claimAt);
      final actualEvent = dispatchEvent.copyWith(createdAt: claimAt);
      final claimedTask = task.copyWith(
        status: TaskStatus.dispatched,
        currentRunId: actualRun.id,
        updatedAt: claimAt,
        metadata: claimedMetadata ?? task.metadata,
      );
      _upsertRun(database, actualRun);
      _validateTaskLinks(database, claimedTask);
      _updateQueuedTask(database, claimedTask, expectedTask);
      if (database.updatedRows != 1) {
        database.execute('ROLLBACK;');
        return null;
      }
      _insertEvent(database, actualEvent);
      database.execute(
        'UPDATE store_meta SET revision = revision + 1, updated_at = ? '
        'WHERE id = 1;',
        [_monotonicUpdatedAt(database, claimAt)],
      );
      database.execute('COMMIT;');
      return TaskClaim(
        task: claimedTask,
        run: actualRun,
        dispatchEvent: actualEvent,
      );
    } on SqliteException catch (error) {
      database.execute('ROLLBACK;');
      if (error.resultCode == SqlError.SQLITE_CONSTRAINT) {
        throw TaskRepositoryConflict(error.message);
      }
      rethrow;
    } on Object {
      database.execute('ROLLBACK;');
      rethrow;
    }
  }

  @override
  Future<TaskRunRecord> updateRun(
    TaskRunRecord run, {
    required TaskRunRecord expected,
    required DateTime updatedAt,
    TaskExecutorCommandContext? executorContext,
  }) async {
    if (run.id != expected.id ||
        run.taskId != expected.taskId ||
        run.attempt != expected.attempt ||
        run.startedAt != expected.startedAt) {
      throw ArgumentError('Updated task run must keep its identity.');
    }
    await initialize();
    _writeTransaction<void>((database) {
      _expectPayload(
        database,
        table: 'task_runs',
        id: run.id,
        expected: expected.toJson(),
        recordLabel: 'Task run',
      );
      _upsertRun(database, run);
    }, updatedAt: updatedAt);
    return run;
  }

  @override
  Future<void> appendEvents(
    List<TaskEventRecord> events, {
    required DateTime updatedAt,
    TaskExecutorCommandContext? executorContext,
  }) async {
    if (events.isEmpty) return;
    await initialize();
    _writeTransaction<void>((database) {
      for (final event in events) {
        _requireOwnedRun(database, event.taskId, event.runId);
        _insertEvent(database, event);
      }
    }, updatedAt: updatedAt);
  }

  @override
  Future<void> replaceArtifactsForRun({
    required String taskId,
    required String runId,
    required List<ArtifactRecord> expectedArtifacts,
    required List<ArtifactRecord> artifacts,
    required DateTime updatedAt,
    TaskExecutorCommandContext? executorContext,
  }) async {
    await initialize();
    _writeTransaction<void>((database) {
      _requireOwnedRun(database, taskId, runId);
      _expectArtifactsForRun(
        database,
        taskId: taskId,
        runId: runId,
        expected: expectedArtifacts,
      );
      final replacementIds = artifacts.map((artifact) => artifact.id).toSet();
      final removedIds = expectedArtifacts
          .map((artifact) => artifact.id)
          .where((id) => !replacementIds.contains(id))
          .toSet();
      _ensureArtifactsNotReferenced(database, taskId, removedIds);
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
    }, updatedAt: updatedAt);
  }

  @override
  Future<void> updateArtifacts({
    required List<ArtifactRecord> expectedArtifacts,
    required List<ArtifactRecord> artifacts,
    required DateTime updatedAt,
    TaskExecutorCommandContext? executorContext,
  }) async {
    if (expectedArtifacts.isEmpty && artifacts.isEmpty) return;
    if (expectedArtifacts.length != artifacts.length) {
      throw ArgumentError('Artifact update must keep the same records.');
    }
    final expectedById = <String, ArtifactRecord>{
      for (final artifact in expectedArtifacts) artifact.id: artifact,
    };
    final artifactIds = artifacts.map((artifact) => artifact.id).toSet();
    if (expectedById.length != expectedArtifacts.length ||
        artifactIds.length != artifacts.length ||
        artifacts.any((artifact) => !expectedById.containsKey(artifact.id))) {
      throw ArgumentError('Artifact update must keep unique ids.');
    }
    await initialize();
    _writeTransaction<void>((database) {
      for (final artifact in artifacts) {
        final expected = expectedById[artifact.id]!;
        if (artifact.taskId != expected.taskId ||
            artifact.runId != expected.runId) {
          throw ArgumentError('Updated artifact must keep its owner.');
        }
        _requireOwnedRun(database, artifact.taskId, artifact.runId);
        _expectPayload(
          database,
          table: 'artifacts',
          id: artifact.id,
          expected: expected.toJson(),
          recordLabel: 'Artifact',
        );
      }
      for (final artifact in artifacts) {
        database.execute('DELETE FROM artifacts WHERE id = ?;', [artifact.id]);
        _insertArtifact(database, artifact);
      }
    }, updatedAt: updatedAt);
  }

  @override
  Future<void> upsertApproval(
    ApprovalRequestRecord approval, {
    ApprovalRequestRecord? expected,
    required DateTime updatedAt,
    TaskExecutorCommandContext? executorContext,
  }) async {
    await initialize();
    _writeTransaction<void>((database) {
      _validateApprovalLinks(database, approval);
      if (expected == null) {
        if (_recordExists(database, 'approval_requests', approval.id)) {
          throw TaskRepositoryConflict(
            'Approval request already exists: ${approval.id}',
          );
        }
      } else {
        if (approval.id != expected.id ||
            approval.taskId != expected.taskId ||
            approval.runId != expected.runId ||
            approval.kind != expected.kind ||
            approval.createdAt != expected.createdAt) {
          throw ArgumentError(
            'Updated approval request must keep its identity.',
          );
        }
        _expectPayload(
          database,
          table: 'approval_requests',
          id: approval.id,
          expected: expected.toJson(),
          recordLabel: 'Approval request',
        );
      }
      _upsertApproval(database, approval);
    }, updatedAt: updatedAt);
  }

  @override
  Future<void> upsertResource(
    WorkspaceResource resource, {
    WorkspaceResource? expected,
    required DateTime updatedAt,
  }) async {
    await initialize();
    _writeTransaction<void>((database) {
      if (expected == null) {
        if (_recordExists(database, 'workspace_resources', resource.id)) {
          throw TaskRepositoryConflict(
            'Workspace resource already exists: ${resource.id}',
          );
        }
      } else {
        if (resource.id != expected.id) {
          throw ArgumentError('Updated resource must keep its id.');
        }
        _expectPayload(
          database,
          table: 'workspace_resources',
          id: resource.id,
          expected: expected.toJson(),
          recordLabel: 'Workspace resource',
        );
      }
      _upsertResource(database, resource);
    }, updatedAt: updatedAt);
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
  Future<RawPayloadPurgeResult> purgeRawPayloads({
    required DateTime now,
    Duration retention = const Duration(days: 30),
    bool force = false,
  }) async {
    if (retention <= Duration.zero) {
      throw ArgumentError.value(retention, 'retention', 'Must be positive.');
    }
    await initialize();
    final database = _database!;
    final utcNow = now.toUtc();
    var transactionOpen = true;
    database.execute('BEGIN IMMEDIATE;');
    try {
      if (!force) {
        final rows = database.select(
          'SELECT last_raw_payload_purge_at FROM store_meta WHERE id = 1;',
        );
        final rawLastPurge = rows.isEmpty
            ? null
            : rows.single['last_raw_payload_purge_at'];
        final lastPurge = rawLastPurge is String
            ? DateTime.tryParse(rawLastPurge)?.toUtc()
            : null;
        if (lastPurge != null &&
            !lastPurge.isAfter(utcNow) &&
            utcNow.difference(lastPurge) < const Duration(days: 1)) {
          database.execute('COMMIT;');
          transactionOpen = false;
          _truncateWalAfterRawPayloadPurge(database);
          return const RawPayloadPurgeResult(skipped: true);
        }
      }

      final cutoff = utcNow.subtract(retention);
      final runsPurged = _purgeRunPrompts(
        database,
        cutoff: cutoff,
        force: force,
      );
      final eventsPurged = _purgeEventMetadata(
        database,
        cutoff: cutoff,
        force: force,
      );
      final artifactsPurged = _purgeArtifactPayloads(
        database,
        cutoff: cutoff,
        force: force,
      );
      final totalPurged = runsPurged + eventsPurged + artifactsPurged;
      if (totalPurged == 0) {
        database.execute(
          'UPDATE store_meta SET last_raw_payload_purge_at = ? WHERE id = 1;',
          <Object?>[utcNow.toIso8601String()],
        );
      } else {
        database.execute(
          'UPDATE store_meta SET last_raw_payload_purge_at = ?, '
          'revision = revision + 1, updated_at = ? WHERE id = 1;',
          <Object?>[
            utcNow.toIso8601String(),
            _monotonicUpdatedAt(database, utcNow),
          ],
        );
      }
      database.execute('COMMIT;');
      transactionOpen = false;
      _truncateWalAfterRawPayloadPurge(database);
      return RawPayloadPurgeResult(
        eventsPurged: eventsPurged,
        runsPurged: runsPurged,
        artifactsPurged: artifactsPurged,
      );
    } on Object {
      if (transactionOpen) database.execute('ROLLBACK;');
      rethrow;
    }
  }

  static void _truncateWalAfterRawPayloadPurge(Database database) {
    try {
      final rows = database.select('PRAGMA wal_checkpoint(TRUNCATE);');
      final busy = rows.isEmpty ? 0 : rows.single.values.first;
      if (busy is int && busy == 0) return;
      throw StateError('SQLite WAL checkpoint remained busy ($busy).');
    } on Object catch (error) {
      throw StateError(
        'Raw payload cleanup committed, but secure WAL truncation failed: '
        '$error',
      );
    }
  }

  @override
  Future<TaskMigrationMetadata> migrationMetadata() async {
    await initialize();
    final rows = _database!.select(
      'SELECT migration_state, source_checksum FROM store_meta WHERE id = 1;',
    );
    if (rows.isEmpty) {
      return const TaskMigrationMetadata(phase: TaskMigrationPhase.inactive);
    }
    final row = rows.first;
    final phase = switch (row['migration_state']) {
      'active' => TaskMigrationPhase.active,
      'importing' => TaskMigrationPhase.importing,
      'inactive' => TaskMigrationPhase.inactive,
      final state => throw StateError(
        'Unsupported task migration state: $state',
      ),
    };
    final checksum = row['source_checksum'];
    return TaskMigrationMetadata(
      phase: phase,
      sourceChecksum: checksum is String ? checksum : null,
    );
  }

  @override
  Future<bool> isActive() async {
    return (await migrationMetadata()).phase == TaskMigrationPhase.active;
  }

  @override
  Future<TaskImportDisposition> importSnapshot(
    TaskInboxSnapshot snapshot, {
    required String checksum,
  }) async {
    snapshot.validateReferences();
    await initialize();
    final database = _database!;
    database.execute('BEGIN IMMEDIATE;');
    try {
      final rows = database.select(
        'SELECT migration_state, source_checksum FROM store_meta WHERE id = 1;',
      );
      if (rows.isEmpty) {
        throw StateError('Task migration metadata is missing.');
      }
      final state = rows.first['migration_state'];
      final existingChecksum = rows.first['source_checksum'];
      if (state == 'active') {
        database.execute('COMMIT;');
        return TaskImportDisposition.alreadyActive;
      }
      if (state == 'importing') {
        if (existingChecksum != checksum) {
          throw StateError('Another task migration is already in progress.');
        }
        database.execute('COMMIT;');
        return TaskImportDisposition.alreadyImporting;
      }
      if (state != 'inactive') {
        throw StateError('Unsupported task migration state: $state');
      }
      if (existingChecksum != null && existingChecksum != checksum) {
        throw StateError('Another task migration is awaiting recovery.');
      }

      _replaceSnapshot(database, snapshot);
      database.execute(
        'UPDATE store_meta SET updated_at = ?, migration_state = ?, '
        'source_checksum = ?, revision = revision + 1 '
        'WHERE id = 1;',
        [snapshot.updatedAt.toIso8601String(), 'importing', checksum],
      );
      database.execute('COMMIT;');
      return TaskImportDisposition.imported;
    } on Object {
      database.execute('ROLLBACK;');
      rethrow;
    }
  }

  @override
  Future<void> rollbackImport(String checksum) async {
    await initialize();
    _writeTransaction<bool>((database) {
      final rows = database.select(
        'SELECT source_checksum, migration_state FROM store_meta '
        'WHERE id = 1;',
      );
      if (rows.isEmpty ||
          rows.first['source_checksum'] != checksum ||
          rows.first['migration_state'] != 'importing') {
        return false;
      }
      database.execute(
        'UPDATE store_meta SET migration_state = ? '
        'WHERE id = 1;',
        ['inactive'],
      );
      return true;
    }, changed: (rolledBack) => rolledBack);
  }

  @override
  Future<void> activateImport(String checksum) async {
    await initialize();
    final database = _database!;
    database.execute('BEGIN IMMEDIATE;');
    try {
      final rows = database.select(
        'SELECT source_checksum, migration_state FROM store_meta WHERE id = 1;',
      );
      if (rows.isEmpty || rows.first['source_checksum'] != checksum) {
        throw StateError('Task migration cannot be activated.');
      }
      if (rows.first['migration_state'] == 'active') {
        database.execute('COMMIT;');
        return;
      }
      if (rows.first['migration_state'] != 'importing') {
        throw StateError('Task migration cannot be activated.');
      }
      database.execute(
        'UPDATE store_meta SET migration_state = ?, revision = revision + 1 '
        'WHERE id = 1 AND source_checksum = ?;',
        ['active', checksum],
      );
      database.execute('COMMIT;');
    } on Object {
      database.execute('ROLLBACK;');
      rethrow;
    }
  }

  @override
  Future<void> activateVerifiedSnapshot(
    TaskInboxSnapshot snapshot, {
    required String checksum,
  }) async {
    snapshot.validateReferences();
    await initialize();
    final database = _database!;
    database.execute('BEGIN IMMEDIATE;');
    try {
      final rows = database.select(
        'SELECT source_checksum, migration_state FROM store_meta WHERE id = 1;',
      );
      if (rows.isEmpty) {
        throw StateError('Task migration metadata is missing.');
      }
      final state = rows.first['migration_state'];
      final existingChecksum = rows.first['source_checksum'];
      if (state == 'active') {
        if (existingChecksum != checksum) {
          throw StateError('Another task migration is already active.');
        }
        database.execute('COMMIT;');
        return;
      }
      if (state != 'inactive' && state != 'importing') {
        throw StateError('Unsupported task migration state: $state');
      }
      if (state == 'importing' && existingChecksum != checksum) {
        throw StateError('Another task migration is already in progress.');
      }
      if (state == 'inactive' &&
          existingChecksum != null &&
          existingChecksum != checksum) {
        throw StateError('Another task migration is awaiting recovery.');
      }

      _replaceSnapshot(database, snapshot);
      database.execute(
        'UPDATE store_meta SET updated_at = ?, migration_state = ?, '
        'source_checksum = ?, revision = revision + 1 WHERE id = 1;',
        [snapshot.updatedAt.toIso8601String(), 'active', checksum],
      );
      database.execute('COMMIT;');
    } on Object {
      database.execute('ROLLBACK;');
      rethrow;
    }
  }

  @override
  Future<void> close() async {
    final initializing = _initializeFuture;
    if (initializing != null) {
      try {
        await initializing;
      } on Object {
        // Initialization already released a partially opened database.
      }
    }
    final database = _database;
    _database = null;
    _initializeFuture = null;
    database?.close();
  }

  static int _purgeRunPrompts(
    Database database, {
    required DateTime cutoff,
    required bool force,
  }) {
    final rows = database.select(
      'SELECT payload_json FROM task_runs WHERE prompt_snapshot IS NOT NULL;',
    );
    var purgedCount = 0;
    for (final row in rows) {
      final run = TaskRunRecord.fromJson(_decodePayload(row));
      if (run == null) throw const FormatException('Invalid task run payload.');
      if (!force && !run.startedAt.toUtc().isBefore(cutoff)) continue;
      final purged = run.copyWith(promptSnapshot: null);
      database.execute(
        'UPDATE task_runs SET prompt_snapshot = NULL, payload_json = ? '
        'WHERE id = ?;',
        <Object?>[jsonEncode(purged.toJson()), run.id],
      );
      purgedCount += 1;
    }
    return purgedCount;
  }

  static int _purgeEventMetadata(
    Database database, {
    required DateTime cutoff,
    required bool force,
  }) {
    final rows = database.select(
      "SELECT payload_json FROM task_events WHERE metadata_json != '{}';",
    );
    var purgedCount = 0;
    for (final row in rows) {
      final event = TaskEventRecord.fromJson(_decodePayload(row));
      if (event == null) {
        throw const FormatException('Invalid task event payload.');
      }
      if (!force && !event.createdAt.toUtc().isBefore(cutoff)) continue;
      final purged = event.copyWith(metadata: const <String, Object?>{});
      database.execute(
        "UPDATE task_events SET metadata_json = '{}', payload_json = ? "
        'WHERE id = ?;',
        <Object?>[jsonEncode(purged.toJson()), event.id],
      );
      purgedCount += 1;
    }
    return purgedCount;
  }

  static int _purgeArtifactPayloads(
    Database database, {
    required DateTime cutoff,
    required bool force,
  }) {
    final rows = database.select('SELECT payload_json FROM artifacts;');
    var purgedCount = 0;
    for (final row in rows) {
      final artifact = ArtifactRecord.fromJson(_decodePayload(row));
      if (artifact == null) {
        throw const FormatException('Invalid artifact payload.');
      }
      if (artifact.metadata['raw_payload'] != true) continue;
      if (!force && !artifact.createdAt.toUtc().isBefore(cutoff)) continue;
      final purged = artifact.copyWith(
        contentPreview: null,
        metadata: const <String, Object?>{},
      );
      database.execute(
        "UPDATE artifacts SET content_preview = NULL, metadata_json = '{}', "
        'payload_json = ? WHERE id = ?;',
        <Object?>[jsonEncode(purged.toJson()), artifact.id],
      );
      purgedCount += 1;
    }
    return purgedCount;
  }

  T _writeTransaction<T>(
    T Function(Database database) action, {
    DateTime? updatedAt,
    bool Function(T result)? changed,
  }) {
    final database = _database!;
    database.execute('BEGIN IMMEDIATE;');
    try {
      final result = action(database);
      final didChange = changed?.call(result) ?? true;
      if (!didChange) {
        database.execute('COMMIT;');
        return result;
      }
      if (updatedAt == null) {
        database.execute(
          'UPDATE store_meta SET revision = revision + 1 WHERE id = 1;',
        );
      } else {
        database.execute(
          'UPDATE store_meta SET revision = revision + 1, updated_at = ? '
          'WHERE id = 1;',
          [_monotonicUpdatedAt(database, updatedAt)],
        );
      }
      database.execute('COMMIT;');
      return result;
    } on SqliteException catch (error) {
      database.execute('ROLLBACK;');
      if (error.resultCode == SqlError.SQLITE_CONSTRAINT) {
        throw TaskRepositoryConflict(error.message);
      }
      rethrow;
    } on Object {
      database.execute('ROLLBACK;');
      rethrow;
    }
  }

  static bool _recordExists(Database database, String table, String id) {
    final rows = database.select('SELECT 1 FROM $table WHERE id = ? LIMIT 1;', [
      id,
    ]);
    return rows.isNotEmpty;
  }

  static bool _sameRecord(Object left, Object right) {
    return jsonEncode(_recordToJson(left)) == jsonEncode(_recordToJson(right));
  }

  static bool _resourceMatchesExpectation(
    Database database,
    TaskRecord task,
    WorkspaceResource? expected,
  ) {
    final resourceId = task.resourceId;
    if (resourceId == null) return expected == null;
    if (expected == null || expected.id != resourceId) return false;
    final rows = database.select(
      'SELECT payload_json FROM workspace_resources WHERE id = ?;',
      [resourceId],
    );
    if (rows.isEmpty) return false;
    final current = WorkspaceResource.fromJson(_decodePayload(rows.first));
    return current != null && _sameRecord(current, expected);
  }

  static void _rejectUnsupportedSchema(Database database) {
    final tables = database.select(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' "
      "AND name = 'schema_migrations' LIMIT 1;",
    );
    if (tables.isEmpty) return;
    final rows = database.select(
      'SELECT MAX(version) AS version FROM schema_migrations;',
    );
    final version = rows.isEmpty ? null : rows.first['version'];
    if (version is int && version > 2) {
      throw StateError(
        'Task repository schema version $version is newer than supported 2.',
      );
    }
  }

  static void _applySchemaMigrations(Database database) {
    database.execute('BEGIN IMMEDIATE;');
    try {
      final versionRows = database.select(
        'SELECT MAX(version) AS version FROM schema_migrations;',
      );
      final version = versionRows.isEmpty
          ? null
          : versionRows.single['version'];
      final columns = database
          .select('PRAGMA table_info(store_meta);')
          .map((row) => row['name'])
          .whereType<String>()
          .toSet();
      final hasPurgeTimestamp = columns.contains('last_raw_payload_purge_at');
      if (version is int && version >= 2 && !hasPurgeTimestamp) {
        throw const FormatException(
          'Task repository schema v2 is missing raw payload maintenance state.',
        );
      }
      if (!hasPurgeTimestamp) {
        database.execute(
          'ALTER TABLE store_meta ADD COLUMN last_raw_payload_purge_at TEXT;',
        );
      }
      if (version == 1) {
        final sanitized = _sanitizePersistedSnapshot(_loadSnapshot(database));
        sanitized.validateReferences();
        _replaceSnapshot(database, sanitized);
      }
      final appliedAt = DateTime.now().toUtc().toIso8601String();
      database.execute(
        'INSERT OR IGNORE INTO schema_migrations (version, applied_at) '
        'VALUES (1, ?);',
        <Object?>[appliedAt],
      );
      database.execute(
        'INSERT OR IGNORE INTO schema_migrations (version, applied_at) '
        'VALUES (2, ?);',
        <Object?>[appliedAt],
      );
      database.execute('COMMIT;');
    } on Object {
      database.execute('ROLLBACK;');
      rethrow;
    }
  }

  static TaskInboxSnapshot _sanitizePersistedSnapshot(
    TaskInboxSnapshot snapshot,
  ) {
    const sanitizer = TaskDataSanitizer();
    String? safe(String? value) =>
        value == null ? null : sanitizer.sanitizeText(value);
    bool isFullDiffCommand(Object? value) {
      return value is List &&
          value.length == 2 &&
          value[0] == 'git' &&
          value[1] == 'diff';
    }

    return snapshot.copyWith(
      tasks: <TaskRecord>[
        for (final task in snapshot.tasks)
          task.copyWith(
            title: sanitizer.sanitizeText(task.title),
            description: sanitizer.sanitizeText(task.description),
            summary: safe(task.summary),
            error: safe(task.error),
            metadata: sanitizer.sanitize(task.metadata),
          ),
      ],
      runs: <TaskRunRecord>[
        for (final run in snapshot.runs)
          run.copyWith(
            promptSnapshot: safe(run.promptSnapshot),
            error: safe(run.error),
          ),
      ],
      events: <TaskEventRecord>[
        for (final event in snapshot.events)
          event.copyWith(
            text: sanitizer.sanitizeText(event.text),
            metadata: sanitizer.sanitize(event.metadata),
          ),
      ],
      artifacts: <ArtifactRecord>[
        for (final artifact in snapshot.artifacts)
          artifact.copyWith(
            title: sanitizer.sanitizeText(artifact.title),
            path: safe(artifact.path),
            contentPreview: safe(artifact.contentPreview),
            metadata: sanitizer.sanitize(<String, Object?>{
              ...artifact.metadata,
              if (artifact.metadata['raw_payload'] == true ||
                  artifact.kind == ArtifactKind.outboxFile ||
                  artifact.title == 'Git diff preview' ||
                  isFullDiffCommand(artifact.metadata['command']))
                'raw_payload': true,
            }),
          ),
      ],
      approvals: <ApprovalRequestRecord>[
        for (final approval in snapshot.approvals)
          approval.copyWith(
            destination: safe(approval.destination),
            riskSummary: safe(approval.riskSummary),
            rationale: safe(approval.rationale),
            metadata: sanitizer.sanitize(approval.metadata),
          ),
      ],
    );
  }

  static String _monotonicUpdatedAt(Database database, DateTime candidate) {
    final rows = database.select(
      'SELECT updated_at FROM store_meta WHERE id = 1;',
    );
    if (rows.isNotEmpty) {
      final raw = rows.first['updated_at'];
      final current = raw is String ? DateTime.tryParse(raw) : null;
      if (current != null && current.isAfter(candidate)) return raw as String;
    }
    return candidate.toIso8601String();
  }

  static DateTime _latestTimestamp(
    DateTime first,
    DateTime second,
    DateTime third,
  ) {
    var latest = first;
    if (second.isAfter(latest)) latest = second;
    if (third.isAfter(latest)) latest = third;
    return latest;
  }

  static void _validateTaskLinks(Database database, TaskRecord task) {
    final resourceId = task.resourceId;
    if (resourceId != null &&
        !_recordExists(database, 'workspace_resources', resourceId)) {
      throw StateError(
        'Task ${task.id} references missing resource $resourceId.',
      );
    }
    final runId = task.currentRunId;
    if (runId != null) _requireOwnedRun(database, task.id, runId);
  }

  static TaskRunRecord _requireOwnedRun(
    Database database,
    String taskId,
    String runId,
  ) {
    final rows = database.select(
      'SELECT payload_json FROM task_runs WHERE id = ?;',
      [runId],
    );
    if (rows.isEmpty) {
      throw StateError('Task run not found: $runId');
    }
    final run = TaskRunRecord.fromJson(_decodePayload(rows.first));
    if (run == null || run.taskId != taskId) {
      throw StateError('Task run $runId does not belong to task $taskId.');
    }
    return run;
  }

  static void _validateApprovalLinks(
    Database database,
    ApprovalRequestRecord approval,
  ) {
    if (!_recordExists(database, 'tasks', approval.taskId)) {
      throw StateError(
        'Approval ${approval.id} references missing task ${approval.taskId}.',
      );
    }
    final runId = approval.runId;
    if (runId != null) {
      _requireOwnedRun(database, approval.taskId, runId);
    }
    for (final artifactId in approval.artifactIds) {
      final rows = database.select(
        'SELECT payload_json FROM artifacts WHERE id = ?;',
        [artifactId],
      );
      if (rows.isEmpty) {
        throw StateError(
          'Approval ${approval.id} references missing artifact $artifactId.',
        );
      }
      final artifact = ArtifactRecord.fromJson(_decodePayload(rows.first));
      if (artifact == null ||
          artifact.taskId != approval.taskId ||
          (runId != null && artifact.runId != runId)) {
        throw StateError(
          'Approval ${approval.id} references invalid artifact $artifactId.',
        );
      }
    }
  }

  static void _ensureArtifactsNotReferenced(
    Database database,
    String taskId,
    Set<String> artifactIds,
  ) {
    if (artifactIds.isEmpty) return;
    final rows = database.select(
      'SELECT payload_json FROM approval_requests WHERE task_id = ?;',
      [taskId],
    );
    for (final row in rows) {
      final approval = ApprovalRequestRecord.fromJson(_decodePayload(row));
      if (approval == null) {
        throw const FormatException('Invalid approval request payload.');
      }
      final referenced = approval.artifactIds.toSet().intersection(artifactIds);
      if (referenced.isNotEmpty) {
        throw TaskRepositoryConflict(
          'Artifacts are still referenced by approval ${approval.id}: '
          '${referenced.join(', ')}',
        );
      }
    }
  }

  static void _expectPayload(
    Database database, {
    required String table,
    required String id,
    required Map<String, Object?> expected,
    required String recordLabel,
  }) {
    final rows = database.select(
      'SELECT payload_json FROM $table WHERE id = ?;',
      [id],
    );
    if (rows.isEmpty) {
      throw TaskRepositoryConflict('$recordLabel no longer exists: $id');
    }
    if (rows.first['payload_json'] != jsonEncode(expected)) {
      throw TaskRepositoryConflict('$recordLabel changed concurrently: $id');
    }
  }

  static void _expectOwnedRecordSet(
    Database database, {
    required String table,
    required String taskId,
    required List<Object> expected,
  }) {
    final rows = database.select(
      'SELECT payload_json FROM $table WHERE task_id = ? ORDER BY id;',
      [taskId],
    );
    final expectedPayloads =
        expected
            .map((record) => jsonEncode(_recordToJson(record)))
            .toList(growable: false)
          ..sort();
    final actualPayloads =
        rows
            .map((row) => jsonEncode(_decodePayload(row)))
            .toList(growable: false)
          ..sort();
    if (actualPayloads.length != expectedPayloads.length) {
      throw TaskRepositoryConflict(
        'Task-owned records changed concurrently in $table.',
      );
    }
    for (var index = 0; index < actualPayloads.length; index += 1) {
      if (actualPayloads[index] != expectedPayloads[index]) {
        throw TaskRepositoryConflict(
          'Task-owned records changed concurrently in $table.',
        );
      }
    }
  }

  static void _expectArtifactsForRun(
    Database database, {
    required String taskId,
    required String runId,
    required List<ArtifactRecord> expected,
  }) {
    final rows = database.select(
      'SELECT id, payload_json FROM artifacts '
      'WHERE task_id = ? AND run_id = ? ORDER BY id;',
      [taskId, runId],
    );
    final expectedRows = [...expected]
      ..sort((left, right) => left.id.compareTo(right.id));
    if (rows.length != expectedRows.length) {
      throw TaskRepositoryConflict(
        'Artifacts changed concurrently for task run: $runId',
      );
    }
    for (var index = 0; index < rows.length; index += 1) {
      final artifact = expectedRows[index];
      if (artifact.taskId != taskId ||
          artifact.runId != runId ||
          rows[index]['id'] != artifact.id ||
          rows[index]['payload_json'] != jsonEncode(artifact.toJson())) {
        throw TaskRepositoryConflict(
          'Artifacts changed concurrently for task run: $runId',
        );
      }
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

  static void _replaceSnapshot(Database database, TaskInboxSnapshot snapshot) {
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
  }

  static void _upsertTask(Database database, TaskRecord task) {
    _validateCanonicalRecord(task);
    _ensureGlobalIdAvailable(database, task.id, owningTable: 'tasks');
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

  static void _updateQueuedTask(
    Database database,
    TaskRecord task,
    TaskRecord expected,
  ) {
    _validateCanonicalRecord(task);
    database.execute(
      'UPDATE tasks SET title = ?, description = ?, workspace_path = ?, '
      'agent_name = ?, status = ?, priority = ?, created_at = ?, '
      'updated_at = ?, session_id = ?, current_run_id = ?, summary = ?, '
      'error = ?, resource_id = ?, skill_ids_json = ?, metadata_json = ?, '
      'payload_json = ? WHERE id = ? AND status = ? AND payload_json = ?;',
      [
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
        task.id,
        TaskStatus.queued.jsonValue,
        jsonEncode(expected.toJson()),
      ],
    );
  }

  static void _upsertRun(Database database, TaskRunRecord run) {
    _validateCanonicalRecord(run);
    _ensureGlobalIdAvailable(database, run.id, owningTable: 'task_runs');
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
    _validateCanonicalRecord(event);
    _ensureGlobalIdAvailable(database, event.id, owningTable: 'task_events');
    database.execute(
      'INSERT INTO task_events '
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
    _validateCanonicalRecord(artifact);
    _ensureGlobalIdAvailable(database, artifact.id, owningTable: 'artifacts');
    database.execute(
      'INSERT INTO artifacts '
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
    _validateCanonicalRecord(approval);
    _ensureGlobalIdAvailable(
      database,
      approval.id,
      owningTable: 'approval_requests',
    );
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
    _validateCanonicalRecord(resource);
    _ensureGlobalIdAvailable(
      database,
      resource.id,
      owningTable: 'workspace_resources',
    );
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
    final rows = database.select('SELECT * FROM $table ORDER BY rowid;');
    final records = <T>[];
    for (final row in rows) {
      final decoded = _decodePayload(row);
      final record = reader(decoded);
      if (record == null) {
        throw FormatException('Invalid normalized task record in $table.');
      }
      if (!taskRepositoryRecordHasCanonicalFields(record as Object)) {
        throw FormatException('Non-canonical task record in $table.');
      }
      if (jsonEncode(_recordToJson(record as Object)) != jsonEncode(decoded)) {
        throw FormatException('Non-canonical task record in $table.');
      }
      _validateNormalizedColumns(table, row, record);
      records.add(record);
    }
    return List<T>.unmodifiable(records);
  }

  static Object? _decodePayload(Row row) {
    final payload = row['payload_json'];
    if (payload is! String) {
      throw const FormatException('Normalized task payload must be text.');
    }
    return jsonDecode(payload);
  }

  static Map<String, Object?> _recordToJson(Object record) {
    return switch (record) {
      TaskRecord value => value.toJson(),
      TaskRunRecord value => value.toJson(),
      TaskEventRecord value => value.toJson(),
      ArtifactRecord value => value.toJson(),
      ApprovalRequestRecord value => value.toJson(),
      WorkspaceResource value => value.toJson(),
      _ => throw ArgumentError('Unsupported task record: $record'),
    };
  }

  static void _validateCanonicalRecord(Object record) {
    if (!taskRepositoryRecordHasCanonicalFields(record)) {
      throw ArgumentError('Task record must use canonical values: $record');
    }
    final json = _recordToJson(record);
    final restored = switch (record) {
      TaskRecord _ => TaskRecord.fromJson(json),
      TaskRunRecord _ => TaskRunRecord.fromJson(json),
      TaskEventRecord _ => TaskEventRecord.fromJson(json),
      ArtifactRecord _ => ArtifactRecord.fromJson(json),
      ApprovalRequestRecord _ => ApprovalRequestRecord.fromJson(json),
      WorkspaceResource _ => WorkspaceResource.fromJson(json),
      _ => null,
    };
    if (restored == null ||
        jsonEncode(_recordToJson(restored)) != jsonEncode(json)) {
      throw ArgumentError('Task record must use canonical values: $record');
    }
  }

  static void _ensureGlobalIdAvailable(
    Database database,
    String id, {
    required String owningTable,
  }) {
    for (final table in const <String>[
      'workspace_resources',
      'tasks',
      'task_runs',
      'task_events',
      'artifacts',
      'approval_requests',
    ]) {
      if (table == owningTable) continue;
      if (_recordExists(database, table, id)) {
        throw TaskRepositoryConflict(
          'Persisted id already exists in $table: $id',
        );
      }
    }
  }

  static void _validateNormalizedColumns(String table, Row row, Object record) {
    final valid = switch ((table, record)) {
      ('tasks', TaskRecord value) =>
        row['id'] == value.id &&
            row['title'] == value.title &&
            row['description'] == value.description &&
            row['workspace_path'] == value.workspacePath &&
            row['agent_name'] == value.agentName &&
            row['status'] == value.status.jsonValue &&
            row['priority'] == value.priority.jsonValue &&
            _sameDate(row['created_at'], value.createdAt) &&
            _sameDate(row['updated_at'], value.updatedAt) &&
            row['session_id'] == value.sessionId &&
            row['current_run_id'] == value.currentRunId &&
            row['summary'] == value.summary &&
            row['error'] == value.error &&
            row['resource_id'] == value.resourceId &&
            row['skill_ids_json'] == jsonEncode(value.skillIds) &&
            row['metadata_json'] == jsonEncode(value.metadata),
      ('task_runs', TaskRunRecord value) =>
        row['id'] == value.id &&
            row['task_id'] == value.taskId &&
            row['attempt'] == value.attempt &&
            row['status'] == value.status.jsonValue &&
            _sameDate(row['started_at'], value.startedAt) &&
            _sameNullableDate(row['ended_at'], value.endedAt) &&
            row['session_id'] == value.sessionId &&
            row['prompt_snapshot'] == value.promptSnapshot &&
            row['model'] == value.model &&
            row['error'] == value.error,
      ('task_events', TaskEventRecord value) =>
        row['id'] == value.id &&
            row['task_id'] == value.taskId &&
            row['run_id'] == value.runId &&
            row['kind'] == value.kind.jsonValue &&
            row['text'] == value.text &&
            _sameDate(row['created_at'], value.createdAt) &&
            row['session_id'] == value.sessionId &&
            row['metadata_json'] == jsonEncode(value.metadata),
      ('artifacts', ArtifactRecord value) =>
        row['id'] == value.id &&
            row['task_id'] == value.taskId &&
            row['run_id'] == value.runId &&
            row['kind'] == value.kind.jsonValue &&
            row['status'] == value.status.jsonValue &&
            row['title'] == value.title &&
            _sameDate(row['created_at'], value.createdAt) &&
            row['path'] == value.path &&
            row['content_preview'] == value.contentPreview &&
            row['sha256'] == value.sha256 &&
            row['size_bytes'] == value.sizeBytes &&
            row['metadata_json'] == jsonEncode(value.metadata),
      ('approval_requests', ApprovalRequestRecord value) =>
        row['id'] == value.id &&
            row['task_id'] == value.taskId &&
            row['run_id'] == value.runId &&
            row['kind'] == value.kind.jsonValue &&
            row['status'] == value.status.jsonValue &&
            _sameDate(row['created_at'], value.createdAt) &&
            _sameNullableDate(row['resolved_at'], value.resolvedAt) &&
            row['rationale'] == value.rationale &&
            row['metadata_json'] == jsonEncode(value.metadata),
      ('workspace_resources', WorkspaceResource value) =>
        row['id'] == value.id &&
            row['type'] == value.type.jsonValue &&
            row['label'] == value.label &&
            row['ref_json'] == jsonEncode(value.ref) &&
            row['serial'] == (value.serial ? 1 : 0),
      _ => false,
    };
    if (!valid) {
      throw FormatException(
        'Normalized columns disagree with payload in $table.',
      );
    }
  }

  static bool _sameDate(Object? raw, DateTime expected) {
    final parsed = raw is String ? DateTime.tryParse(raw) : null;
    return parsed != null && parsed.isAtSameMomentAs(expected);
  }

  static bool _sameNullableDate(Object? raw, DateTime? expected) {
    if (expected == null) return raw == null;
    return _sameDate(raw, expected);
  }

  static String _joinPath(String directory, String basename) {
    if (directory.endsWith(Platform.pathSeparator)) {
      return '$directory$basename';
    }
    return '$directory${Platform.pathSeparator}$basename';
  }

  static bool _isAppOwnedStateDirectory(Directory directory) {
    final segments = directory.uri.pathSegments
        .where((segment) => segment.isNotEmpty)
        .toList(growable: false);
    if (segments.isEmpty) return false;
    final name = segments.last.toLowerCase();
    return name == 'ianvs-acp' || name == '.ianvs-acp';
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
  updated_at TEXT NOT NULL,
  last_raw_payload_purge_at TEXT
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
