import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/tasks/task_inbox_migrator.dart';
import 'package:ianvs_acp/tasks/task_inbox_snapshot.dart';
import 'package:ianvs_acp/tasks/task_inbox_sqlite_store.dart';
import 'package:ianvs_acp/tasks/task_inbox_state_store.dart';
import 'package:ianvs_acp/tasks/task_record.dart';
import 'package:ianvs_acp/tasks/task_repository.dart';
import 'package:ianvs_acp/tasks/workspace_resource.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('imports every record and preserves a sanitized backup', () async {
    final temp = await Directory.systemTemp.createTemp('task-migrator-');
    addTearDown(() => temp.delete(recursive: true));
    final sourceFile = File('${temp.path}/task_inbox_state.json');
    final source = TaskInboxStateStore(path: sourceFile.path);
    final repository = TaskInboxSqliteStore(
      path: '${temp.path}/task_inbox_state.sqlite3',
    );
    addTearDown(repository.close);
    final fixture = _fixtureSnapshot();
    await sourceFile.writeAsString(jsonEncode(fixture.toJson()));
    final migrator = TaskInboxMigrator(
      source: source,
      repository: repository,
      clock: () => DateTime.utc(2026, 7, 10, 8),
    );

    final result = await migrator.migrateIfNeeded();

    expect(result.status, TaskMigrationStatus.migrated);
    expect(
      (await repository.loadRepository()).snapshot.toJson(),
      fixture.toJson(),
    );
    expect(result.backupPath, contains('task_inbox_state.migrated.'));
    final backup = File(result.backupPath!);
    expect(await backup.exists(), isTrue);
    expect((await backup.stat()).mode & 0x1ff, 0x100);
    expect(await sourceFile.exists(), isFalse);
    expect(await repository.isActive(), isTrue);
    expect(
      temp.listSync().where(
        (entity) => entity.path.contains('.restore.${result.checksum}.'),
      ),
      isEmpty,
    );
  });

  test(
    'sanitizes retained legacy task data before database activation',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'task-migrator-secret-',
      );
      addTearDown(() => temp.delete(recursive: true));
      final sourceFile = File('${temp.path}/task_inbox_state.json');
      final source = _fixtureSnapshot();
      final sensitive = source.copyWith(
        tasks: <TaskRecord>[
          source.tasks.single.copyWith(
            title: 'Authorization:Bearer title-secret',
            description: '--header=Authorization:Bearer description-secret',
            metadata: const <String, Object?>{
              'Authorization': 'Bearer task-secret',
            },
          ),
        ],
        runs: <TaskRunRecord>[
          source.runs.single.copyWith(promptSnapshot: 'Bearer prompt-secret'),
        ],
        events: <TaskEventRecord>[
          source.events.single.copyWith(
            text: 'Bearer event-secret',
            metadata: const <String, Object?>{
              'rawInput': '{"password":"legacy-secret","safe":"kept"}',
            },
          ),
        ],
        artifacts: <ArtifactRecord>[
          source.artifacts.single.copyWith(
            title: 'Git diff preview',
            path: 'Authorization:Bearer artifact-path-secret',
            contentPreview: 'sk-artifact-secret',
            metadata: const <String, Object?>{
              'command': <String>['git', 'diff'],
            },
          ),
        ],
        approvals: <ApprovalRequestRecord>[
          source.approvals.single.copyWith(
            destination: 'Authorization:Bearer destination-secret',
            riskSummary: 'Bearer risk-secret',
            rationale: 'Bearer rationale-secret',
            metadata: const <String, Object?>{
              'access_token': 'approval-secret',
            },
          ),
        ],
      );
      await sourceFile.writeAsString(jsonEncode(sensitive.toJson()));
      final repository = TaskInboxSqliteStore(
        path: '${temp.path}/task_inbox_state.sqlite3',
      );
      addTearDown(repository.close);

      await TaskInboxMigrator(
        source: TaskInboxStateStore(path: sourceFile.path),
        repository: repository,
        clock: () => DateTime.utc(2026, 7, 10, 8),
      ).migrateIfNeeded();

      final imported = (await repository.loadRepository()).snapshot;
      final retained = jsonEncode(imported.toJson());
      expect(retained, isNot(contains('task-secret')));
      expect(retained, isNot(contains('title-secret')));
      expect(retained, isNot(contains('description-secret')));
      expect(retained, isNot(contains('prompt-secret')));
      expect(retained, isNot(contains('event-secret')));
      expect(retained, isNot(contains('legacy-secret')));
      expect(retained, isNot(contains('artifact-secret')));
      expect(retained, isNot(contains('artifact-path-secret')));
      expect(retained, isNot(contains('approval-secret')));
      expect(retained, isNot(contains('destination-secret')));
      expect(retained, isNot(contains('risk-secret')));
      expect(retained, isNot(contains('rationale-secret')));
      expect(imported.tasks.single.title, '<redacted>');
      expect(imported.tasks.single.description, '<redacted>');
      expect(imported.events.single.text, '<redacted>');
      expect(imported.artifacts.single.contentPreview, '<redacted>');
      expect(imported.artifacts.single.path, '<redacted>');
      expect(imported.artifacts.single.metadata['raw_payload'], isTrue);
      expect(
        jsonDecode(imported.events.single.metadata['rawInput']! as String),
        {'password': '<redacted>', 'safe': 'kept'},
      );
      final migration = await repository.migrationMetadata();
      final backups = temp
          .listSync()
          .whereType<File>()
          .where((file) => file.path.contains('.migrated.'))
          .toList(growable: false);
      expect(backups, hasLength(1));
      final backupContents = await backups.single.readAsString();
      expect(backupContents, isNot(contains('title-secret')));
      expect(backupContents, isNot(contains('description-secret')));
      expect(backupContents, isNot(contains('prompt-secret')));
      expect(backupContents, isNot(contains('event-secret')));
      expect(backupContents, isNot(contains('artifact-secret')));
      expect(backupContents, isNot(contains('artifact-path-secret')));
      expect(backupContents, isNot(contains('approval-secret')));
      final backupSnapshot = TaskInboxSnapshot.fromJsonStrict(
        jsonDecode(backupContents),
      );
      expect(backupSnapshot.runs.single.promptSnapshot, isNull);
      expect(backupSnapshot.events.single.metadata, isEmpty);
      expect(backupSnapshot.artifacts.single.contentPreview, isNull);
      expect(backupSnapshot.artifacts.single.metadata, isEmpty);
      expect((await backups.single.stat()).mode & 0x1ff, 0x100);
      expect(migration.phase, TaskMigrationPhase.active);
    },
  );

  test(
    'malformed JSON leaves source untouched and repository inactive',
    () async {
      final temp = await Directory.systemTemp.createTemp('task-migrator-');
      addTearDown(() => temp.delete(recursive: true));
      final sourceFile = File('${temp.path}/task_inbox_state.json');
      await sourceFile.writeAsString('{broken');
      final repository = TaskInboxSqliteStore(
        path: '${temp.path}/task_inbox_state.sqlite3',
      );
      addTearDown(repository.close);
      final migrator = TaskInboxMigrator(
        source: TaskInboxStateStore(path: sourceFile.path),
        repository: repository,
      );

      await expectLater(migrator.migrateIfNeeded(), throwsFormatException);

      expect(await sourceFile.readAsString(), '{broken');
      expect(await repository.isActive(), isFalse);
    },
  );

  test('backup failure keeps source and repository inactive', () async {
    final temp = await Directory.systemTemp.createTemp('task-migrator-');
    addTearDown(() => temp.delete(recursive: true));
    final sourceFile = File('${temp.path}/task_inbox_state.json');
    final fixture = _fixtureSnapshot();
    await sourceFile.writeAsString(jsonEncode(fixture.toJson()));
    final repository = TaskInboxSqliteStore(
      path: '${temp.path}/task_inbox_state.sqlite3',
    );
    addTearDown(repository.close);
    final migrator = TaskInboxMigrator(
      source: TaskInboxStateStore(path: sourceFile.path),
      repository: repository,
      finalizeBackup: (source, checksum, timestamp) async {
        throw const FileSystemException('backup failed');
      },
    );

    await expectLater(
      migrator.migrateIfNeeded(),
      throwsA(isA<FileSystemException>()),
    );

    expect(await sourceFile.exists(), isTrue);
    expect(await repository.isActive(), isFalse);
    final metadata = await repository.migrationMetadata();
    expect(metadata.phase, TaskMigrationPhase.inactive);
    expect(metadata.sourceChecksum, isNotNull);
    expect(
      (await repository.loadRepository()).snapshot.toJson(),
      fixture.toJson(),
    );
  });

  test('stages recovery data with owner-only permissions', () async {
    final temp = await Directory.systemTemp.createTemp('task-migrator-');
    addTearDown(() => temp.delete(recursive: true));
    final sourceFile = File('${temp.path}/task_inbox_state.json');
    await sourceFile.writeAsString(jsonEncode(_fixtureSnapshot().toJson()));
    final repository = TaskInboxSqliteStore(
      path: '${temp.path}/task_inbox_state.sqlite3',
    );
    addTearDown(repository.close);
    int? recoveryMode;
    final migrator = TaskInboxMigrator(
      source: TaskInboxStateStore(path: sourceFile.path),
      repository: repository,
      finalizeBackup: (source, checksum, timestamp) async {
        final recovery = source.parent.listSync().whereType<File>().singleWhere(
          (file) => file.path.contains('.restore.$checksum.'),
        );
        recoveryMode = (await recovery.stat()).mode & 0x1ff;
        throw const FileSystemException('backup failed');
      },
    );

    await expectLater(
      migrator.migrateIfNeeded(),
      throwsA(isA<FileSystemException>()),
    );

    if (!Platform.isWindows) expect(recoveryMode, 0x180);
    expect(await sourceFile.exists(), isTrue);
    expect(await repository.isActive(), isFalse);
  });

  test('preserves importing data when a different source appears', () async {
    final temp = await Directory.systemTemp.createTemp('task-migrator-');
    addTearDown(() => temp.delete(recursive: true));
    final sourceFile = File('${temp.path}/task_inbox_state.json');
    final fixture = _fixtureSnapshot();
    final originalBytes = utf8.encode(jsonEncode(fixture.toJson()));
    await sourceFile.writeAsBytes(originalBytes);
    final replacement = fixture.copyWith(
      tasks: [fixture.tasks.single.copyWith(title: 'Concurrent replacement')],
    );
    final replacementBytes = utf8.encode(jsonEncode(replacement.toJson()));
    final checksum = sha256.convert(originalBytes).toString();
    final repository = TaskInboxSqliteStore(
      path: '${temp.path}/task_inbox_state.sqlite3',
    );
    addTearDown(repository.close);
    final migrator = TaskInboxMigrator(
      source: TaskInboxStateStore(path: sourceFile.path),
      repository: repository,
      finalizeBackup: (source, checksum, timestamp) async {
        await source.rename('${source.path}.unexpected-backup');
        await source.writeAsBytes(replacementBytes, flush: true);
        throw const FileSystemException('backup finalization failed');
      },
    );

    await expectLater(
      migrator.migrateIfNeeded(),
      throwsA(isA<FileSystemException>()),
    );

    expect(await sourceFile.readAsBytes(), replacementBytes);
    final metadata = await repository.migrationMetadata();
    expect(metadata.phase, TaskMigrationPhase.importing);
    expect(metadata.sourceChecksum, checksum);
    expect(
      (await repository.loadRepository()).snapshot.toJson(),
      fixture.toJson(),
    );
    final recoveries = temp.listSync().whereType<File>().where(
      (file) => file.path.contains('.restore.$checksum.'),
    );
    expect(recoveries, hasLength(1));
    expect(
      sha256.convert(await recoveries.single.readAsBytes()).toString(),
      checksum,
    );
  });

  test('verified backup reimports after a concurrent rollback', () async {
    final temp = await Directory.systemTemp.createTemp('task-migrator-');
    addTearDown(() => temp.delete(recursive: true));
    final sourceFile = File('${temp.path}/task_inbox_state.json');
    final fixture = _fixtureSnapshot();
    await sourceFile.writeAsString(jsonEncode(fixture.toJson()));
    final databasePath = '${temp.path}/task_inbox_state.sqlite3';
    final repositoryA = TaskInboxSqliteStore(path: databasePath);
    final repositoryB = TaskInboxSqliteStore(path: databasePath);
    addTearDown(repositoryA.close);
    addTearDown(repositoryB.close);
    final firstFinalizerStarted = Completer<void>();
    final secondFinalizerStarted = Completer<void>();
    final releaseSecondFinalizer = Completer<void>();
    final migratorA = TaskInboxMigrator(
      source: TaskInboxStateStore(path: sourceFile.path),
      repository: repositoryA,
      finalizeBackup: (source, checksum, timestamp) async {
        firstFinalizerStarted.complete();
        await secondFinalizerStarted.future;
        throw const FileSystemException('first finalizer failed');
      },
    );
    final migratorB = TaskInboxMigrator(
      source: TaskInboxStateStore(path: sourceFile.path),
      repository: repositoryB,
      finalizeBackup: (source, checksum, timestamp) async {
        secondFinalizerStarted.complete();
        await releaseSecondFinalizer.future;
        return (await source.rename(
          '${temp.path}/task_inbox_state.migrated.concurrent.'
          '$checksum.json.bak',
        )).path;
      },
    );

    final migrationA = migratorA.migrateIfNeeded();
    final migrationAExpectation = expectLater(
      migrationA,
      throwsA(isA<FileSystemException>()),
    );
    await firstFinalizerStarted.future;
    final migrationB = migratorB.migrateIfNeeded();
    await secondFinalizerStarted.future;
    await migrationAExpectation;
    releaseSecondFinalizer.complete();
    final result = await migrationB;

    expect(result.status, TaskMigrationStatus.migrated);
    expect(await repositoryB.isActive(), isTrue);
    expect(
      (await repositoryB.loadRepository()).snapshot.toJson(),
      fixture.toJson(),
    );
  });

  test('activates an empty repository when no legacy file exists', () async {
    final temp = await Directory.systemTemp.createTemp('task-migrator-');
    addTearDown(() => temp.delete(recursive: true));
    final repository = TaskInboxSqliteStore(
      path: '${temp.path}/task_inbox_state.sqlite3',
    );
    addTearDown(repository.close);
    final migrator = TaskInboxMigrator(
      source: TaskInboxStateStore(path: '${temp.path}/task_inbox_state.json'),
      repository: repository,
    );

    final result = await migrator.migrateIfNeeded();

    expect(result.status, TaskMigrationStatus.notNeeded);
    expect(await repository.isActive(), isTrue);
    expect((await repository.loadRepository()).snapshot.tasks, isEmpty);
  });

  test('resumes activation after backup rename interrupted startup', () async {
    final temp = await Directory.systemTemp.createTemp('task-migrator-');
    addTearDown(() => temp.delete(recursive: true));
    final sourceFile = File('${temp.path}/task_inbox_state.json');
    final fixture = _fixtureSnapshot();
    final bytes = utf8.encode(jsonEncode(fixture.toJson()));
    final checksum = sha256.convert(bytes).toString();
    await sourceFile.writeAsBytes(bytes);
    final repository = TaskInboxSqliteStore(
      path: '${temp.path}/task_inbox_state.sqlite3',
    );
    addTearDown(repository.close);
    await repository.importSnapshot(fixture, checksum: checksum);
    final backup = await sourceFile.rename(
      '${temp.path}/task_inbox_state.migrated.crash.$checksum.json.bak',
    );
    final migrator = TaskInboxMigrator(
      source: TaskInboxStateStore(path: sourceFile.path),
      repository: repository,
    );

    final result = await migrator.migrateIfNeeded();

    expect(result.status, TaskMigrationStatus.migrated);
    expect(result.backupPath, startsWith('${backup.path}.sanitized.'));
    expect(await backup.exists(), isFalse);
    expect(await repository.isActive(), isTrue);
    expect((await File(result.backupPath!).stat()).mode & 0x1ff, 0x100);
  });

  test('recovers an inactive staged import from its verified backup', () async {
    final temp = await Directory.systemTemp.createTemp('task-migrator-');
    addTearDown(() => temp.delete(recursive: true));
    final sourceFile = File('${temp.path}/task_inbox_state.json');
    final fixture = _fixtureSnapshot();
    final bytes = utf8.encode(jsonEncode(fixture.toJson()));
    final checksum = sha256.convert(bytes).toString();
    final repository = TaskInboxSqliteStore(
      path: '${temp.path}/task_inbox_state.sqlite3',
    );
    addTearDown(repository.close);
    await repository.importSnapshot(fixture, checksum: checksum);
    await repository.rollbackImport(checksum);
    final backup = File(
      '${temp.path}/task_inbox_state.migrated.crash.$checksum.json.bak',
    );
    await backup.writeAsBytes(bytes, flush: true);

    final result = await TaskInboxMigrator(
      source: TaskInboxStateStore(path: sourceFile.path),
      repository: repository,
    ).migrateIfNeeded();

    expect(result.status, TaskMigrationStatus.migrated);
    expect(await repository.isActive(), isTrue);
    expect(
      (await repository.loadRepository()).snapshot.toJson(),
      fixture.toJson(),
    );
  });

  test(
    'resumes from a verified recovery file after an interrupted restore',
    () async {
      final temp = await Directory.systemTemp.createTemp('task-migrator-');
      addTearDown(() => temp.delete(recursive: true));
      final sourceFile = File('${temp.path}/task_inbox_state.json');
      final fixture = _fixtureSnapshot();
      final bytes = utf8.encode(jsonEncode(fixture.toJson()));
      final checksum = sha256.convert(bytes).toString();
      final repository = TaskInboxSqliteStore(
        path: '${temp.path}/task_inbox_state.sqlite3',
      );
      addTearDown(repository.close);
      await repository.importSnapshot(fixture, checksum: checksum);
      final recovery = File('${sourceFile.path}.restore.$checksum.crashed.tmp');
      await recovery.create();
      if (!Platform.isWindows) {
        final chmod = await Process.run('chmod', ['0600', recovery.path]);
        expect(chmod.exitCode, 0);
      }
      await recovery.writeAsBytes(bytes, flush: true);

      final result = await TaskInboxMigrator(
        source: TaskInboxStateStore(path: sourceFile.path),
        repository: repository,
      ).migrateIfNeeded();

      expect(result.status, TaskMigrationStatus.migrated);
      expect(await sourceFile.exists(), isFalse);
      expect(await recovery.exists(), isFalse);
      expect(await repository.isActive(), isTrue);
      expect(
        (await repository.loadRepository()).snapshot.toJson(),
        fixture.toJson(),
      );
    },
  );

  test('active migration cleans partial recovery files', () async {
    final temp = await Directory.systemTemp.createTemp('task-migrator-');
    addTearDown(() => temp.delete(recursive: true));
    final sourceFile = File('${temp.path}/task_inbox_state.json');
    final fixture = _fixtureSnapshot();
    final bytes = utf8.encode(jsonEncode(fixture.toJson()));
    final checksum = sha256.convert(bytes).toString();
    final repository = TaskInboxSqliteStore(
      path: '${temp.path}/task_inbox_state.sqlite3',
    );
    addTearDown(repository.close);
    await repository.importSnapshot(fixture, checksum: checksum);
    await repository.activateImport(checksum);
    final partial = File('${sourceFile.path}.restore.$checksum.crashed.tmp');
    await partial.writeAsString('partial sensitive data', flush: true);

    final result = await TaskInboxMigrator(
      source: TaskInboxStateStore(path: sourceFile.path),
      repository: repository,
    ).migrateIfNeeded();

    expect(result.status, TaskMigrationStatus.notNeeded);
    expect(await partial.exists(), isFalse);
    expect(await repository.isActive(), isTrue);
  });

  test('active migration replaces a raw crash backup', () async {
    final temp = await Directory.systemTemp.createTemp('task-migrator-');
    addTearDown(() => temp.delete(recursive: true));
    final sourceFile = File('${temp.path}/task_inbox_state.json');
    final fixture = _fixtureSnapshot();
    final rawSnapshot = fixture.copyWith(
      tasks: <TaskRecord>[
        fixture.tasks.single.copyWith(
          metadata: const <String, Object?>{
            'Authorization': 'Bearer crash-backup-secret',
          },
        ),
      ],
    );
    final rawBytes = utf8.encode(jsonEncode(rawSnapshot.toJson()));
    final checksum = sha256.convert(rawBytes).toString();
    final sanitizedSnapshot = fixture.copyWith(
      tasks: <TaskRecord>[
        fixture.tasks.single.copyWith(
          metadata: const <String, Object?>{'Authorization': '<redacted>'},
        ),
      ],
    );
    final repository = TaskInboxSqliteStore(
      path: '${temp.path}/task_inbox_state.sqlite3',
    );
    addTearDown(repository.close);
    await repository.activateVerifiedSnapshot(
      sanitizedSnapshot,
      checksum: checksum,
    );
    final rawBackup = File(
      '${temp.path}/task_inbox_state.migrated.crash.$checksum.json.bak',
    );
    await rawBackup.writeAsBytes(rawBytes, flush: true);

    final result = await TaskInboxMigrator(
      source: TaskInboxStateStore(path: sourceFile.path),
      repository: repository,
    ).migrateIfNeeded();

    expect(result.status, TaskMigrationStatus.notNeeded);
    expect(await rawBackup.exists(), isFalse);
    final backups = temp
        .listSync()
        .whereType<File>()
        .where((file) => file.path.contains('.migrated.'))
        .toList(growable: false);
    expect(backups, hasLength(1));
    expect(
      await backups.single.readAsString(),
      isNot(contains('backup-secret')),
    );
    expect((await backups.single.stat()).mode & 0x1ff, 0x100);
  });

  test('rejects dangling task references without touching source', () async {
    final temp = await Directory.systemTemp.createTemp('task-migrator-');
    addTearDown(() => temp.delete(recursive: true));
    final sourceFile = File('${temp.path}/task_inbox_state.json');
    final fixture = _fixtureSnapshot();
    final invalid = fixture.copyWith(
      tasks: [fixture.tasks.single.copyWith(currentRunId: 'missing-run')],
    );
    await sourceFile.writeAsString(jsonEncode(invalid.toJson()));
    final repository = TaskInboxSqliteStore(
      path: '${temp.path}/task_inbox_state.sqlite3',
    );
    addTearDown(repository.close);
    final migrator = TaskInboxMigrator(
      source: TaskInboxStateStore(path: sourceFile.path),
      repository: repository,
    );

    await expectLater(migrator.migrateIfNeeded(), throwsFormatException);

    expect(await sourceFile.exists(), isTrue);
    expect(await repository.isActive(), isFalse);
  });

  test('rejects duplicate record ids without touching source', () async {
    final temp = await Directory.systemTemp.createTemp('task-migrator-');
    addTearDown(() => temp.delete(recursive: true));
    final sourceFile = File('${temp.path}/task_inbox_state.json');
    final fixture = _fixtureSnapshot();
    final invalid = fixture.copyWith(
      tasks: [fixture.tasks.single, fixture.tasks.single],
    );
    await sourceFile.writeAsString(jsonEncode(invalid.toJson()));
    final repository = TaskInboxSqliteStore(
      path: '${temp.path}/task_inbox_state.sqlite3',
    );
    addTearDown(repository.close);
    final migrator = TaskInboxMigrator(
      source: TaskInboxStateStore(path: sourceFile.path),
      repository: repository,
    );

    await expectLater(migrator.migrateIfNeeded(), throwsFormatException);

    expect(await sourceFile.exists(), isTrue);
    expect(await repository.isActive(), isFalse);
  });

  test('rejects lossy record values without touching source', () async {
    final temp = await Directory.systemTemp.createTemp('task-migrator-');
    addTearDown(() => temp.delete(recursive: true));
    final sourceFile = File('${temp.path}/task_inbox_state.json');
    final json = _fixtureSnapshot().toJson();
    final task = Map<String, Object?>.from(
      (json['tasks']! as List<Object?>).single! as Map,
    );
    task['status'] = 'unknown-status';
    json['tasks'] = <Object?>[task];
    await sourceFile.writeAsString(jsonEncode(json));
    final repository = TaskInboxSqliteStore(
      path: '${temp.path}/task_inbox_state.sqlite3',
    );
    addTearDown(repository.close);
    final migrator = TaskInboxMigrator(
      source: TaskInboxStateStore(path: sourceFile.path),
      repository: repository,
    );

    await expectLater(migrator.migrateIfNeeded(), throwsFormatException);

    expect(await sourceFile.exists(), isTrue);
    expect(await repository.isActive(), isFalse);
  });

  test('rejects a legacy file changed while import is in progress', () async {
    final temp = await Directory.systemTemp.createTemp('task-migrator-');
    addTearDown(() => temp.delete(recursive: true));
    final sourceFile = File('${temp.path}/task_inbox_state.json');
    final fixture = _fixtureSnapshot();
    final sourceBytes = utf8.encode(jsonEncode(fixture.toJson()));
    final checksum = sha256.convert(sourceBytes).toString();
    await sourceFile.writeAsBytes(sourceBytes);
    final repository = _MutatingImportStore(
      path: '${temp.path}/task_inbox_state.sqlite3',
      source: sourceFile,
    );
    addTearDown(repository.close);
    final migrator = TaskInboxMigrator(
      source: TaskInboxStateStore(path: sourceFile.path),
      repository: repository,
    );

    await expectLater(
      migrator.migrateIfNeeded(),
      throwsA(isA<FileSystemException>()),
    );

    expect(await sourceFile.exists(), isTrue);
    expect(await repository.isActive(), isFalse);
    final metadata = await repository.migrationMetadata();
    expect(metadata.phase, TaskMigrationPhase.importing);
    expect(metadata.sourceChecksum, checksum);
    expect(
      (await repository.loadRepository()).snapshot.toJson(),
      fixture.toJson(),
    );
  });

  test('rejects a snapshot with a missing record collection', () async {
    final temp = await Directory.systemTemp.createTemp('task-migrator-');
    addTearDown(() => temp.delete(recursive: true));
    final sourceFile = File('${temp.path}/task_inbox_state.json');
    final json = _fixtureSnapshot().toJson()..remove('approvals');
    await sourceFile.writeAsString(jsonEncode(json));
    final repository = TaskInboxSqliteStore(
      path: '${temp.path}/task_inbox_state.sqlite3',
    );
    addTearDown(repository.close);
    final migrator = TaskInboxMigrator(
      source: TaskInboxStateStore(path: sourceFile.path),
      repository: repository,
    );

    await expectLater(migrator.migrateIfNeeded(), throwsFormatException);

    expect(await sourceFile.exists(), isTrue);
    expect(await repository.isActive(), isFalse);
  });

  test('accepts early v1 snapshots without workspace resources', () async {
    final temp = await Directory.systemTemp.createTemp('task-migrator-');
    addTearDown(() => temp.delete(recursive: true));
    final sourceFile = File('${temp.path}/task_inbox_state.json');
    final fixture = _fixtureSnapshot();
    final compatible = fixture.copyWith(
      tasks: [fixture.tasks.single.copyWith(resourceId: null)],
      resources: const <WorkspaceResource>[],
    );
    final json = compatible.toJson()..remove('resources');
    final artifact = Map<String, Object?>.from(
      (json['artifacts']! as List<Object?>).single! as Map,
    )..remove('status');
    json['artifacts'] = <Object?>[artifact];
    await sourceFile.writeAsString(jsonEncode(json));
    final repository = TaskInboxSqliteStore(
      path: '${temp.path}/task_inbox_state.sqlite3',
    );
    addTearDown(repository.close);
    final migrator = TaskInboxMigrator(
      source: TaskInboxStateStore(path: sourceFile.path),
      repository: repository,
    );

    final result = await migrator.migrateIfNeeded();

    expect(result.status, TaskMigrationStatus.migrated);
    expect(
      (await repository.loadRepository()).snapshot.toJson(),
      compatible.toJson(),
    );
  });

  test('preserves historical export records without enabling export', () async {
    final temp = await Directory.systemTemp.createTemp('task-migrator-');
    addTearDown(() => temp.delete(recursive: true));
    final sourceFile = File('${temp.path}/task_inbox_state.json');
    final json = _fixtureSnapshot().toJson();
    final task = Map<String, Object?>.from(
      (json['tasks']! as List<Object?>).single! as Map,
    )..['status'] = 'approved_for_export';
    final run = Map<String, Object?>.from(
      (json['runs']! as List<Object?>).single! as Map,
    )..['status'] = 'exporting';
    final event = Map<String, Object?>.from(
      (json['events']! as List<Object?>).single! as Map,
    )..['kind'] = 'export';
    final artifact = Map<String, Object?>.from(
      (json['artifacts']! as List<Object?>).single! as Map,
    )..['status'] = 'exported';
    final approval =
        Map<String, Object?>.from(
            (json['approvals']! as List<Object?>).single! as Map,
          )
          ..['kind'] = 'export'
          ..['target'] = 'git_push'
          ..['destination'] = 'origin/main'
          ..['risk_summary'] = 'Writes to a remote repository.'
          ..['artifact_ids'] = <String>['artifact-1'];
    json
      ..['tasks'] = <Object?>[task]
      ..['runs'] = <Object?>[run]
      ..['events'] = <Object?>[event]
      ..['artifacts'] = <Object?>[artifact]
      ..['approvals'] = <Object?>[approval];
    await sourceFile.writeAsString(jsonEncode(json));
    final repository = TaskInboxSqliteStore(
      path: '${temp.path}/task_inbox_state.sqlite3',
    );
    addTearDown(repository.close);

    final result = await TaskInboxMigrator(
      source: TaskInboxStateStore(path: sourceFile.path),
      repository: repository,
    ).migrateIfNeeded();

    expect(result.status, TaskMigrationStatus.migrated);
    expect((await repository.loadRepository()).snapshot.toJson(), json);
  });

  test('rejects unknown top-level fields without touching source', () async {
    final temp = await Directory.systemTemp.createTemp('task-migrator-');
    addTearDown(() => temp.delete(recursive: true));
    final sourceFile = File('${temp.path}/task_inbox_state.json');
    final json = _fixtureSnapshot().toJson()..['future_records'] = <Object?>[];
    await sourceFile.writeAsString(jsonEncode(json));
    final repository = TaskInboxSqliteStore(
      path: '${temp.path}/task_inbox_state.sqlite3',
    );
    addTearDown(repository.close);

    await expectLater(
      TaskInboxMigrator(
        source: TaskInboxStateStore(path: sourceFile.path),
        repository: repository,
      ).migrateIfNeeded(),
      throwsFormatException,
    );

    expect(await sourceFile.exists(), isTrue);
    expect(await repository.isActive(), isFalse);
  });

  test('rejects explicit null resources without touching source', () async {
    final temp = await Directory.systemTemp.createTemp('task-migrator-');
    addTearDown(() => temp.delete(recursive: true));
    final sourceFile = File('${temp.path}/task_inbox_state.json');
    final json = _fixtureSnapshot().toJson()..['resources'] = null;
    await sourceFile.writeAsString(jsonEncode(json));
    final repository = TaskInboxSqliteStore(
      path: '${temp.path}/task_inbox_state.sqlite3',
    );
    addTearDown(repository.close);

    await expectLater(
      TaskInboxMigrator(
        source: TaskInboxStateStore(path: sourceFile.path),
        repository: repository,
      ).migrateIfNeeded(),
      throwsFormatException,
    );

    expect(await sourceFile.exists(), isTrue);
    expect(await repository.isActive(), isFalse);
  });

  test('rejects non-canonical updated_at without touching source', () async {
    final temp = await Directory.systemTemp.createTemp('task-migrator-');
    addTearDown(() => temp.delete(recursive: true));
    final sourceFile = File('${temp.path}/task_inbox_state.json');
    final json = _fixtureSnapshot().toJson()
      ..['updated_at'] = '2026-07-08 09:00:00.000';
    await sourceFile.writeAsString(jsonEncode(json));
    final repository = TaskInboxSqliteStore(
      path: '${temp.path}/task_inbox_state.sqlite3',
    );
    addTearDown(repository.close);

    await expectLater(
      TaskInboxMigrator(
        source: TaskInboxStateStore(path: sourceFile.path),
        repository: repository,
      ).migrateIfNeeded(),
      throwsFormatException,
    );

    expect(await sourceFile.exists(), isTrue);
    expect(await repository.isActive(), isFalse);
  });

  test('restores source bytes when finalized backup is invalid', () async {
    final temp = await Directory.systemTemp.createTemp('task-migrator-');
    addTearDown(() => temp.delete(recursive: true));
    final sourceFile = File('${temp.path}/task_inbox_state.json');
    final sourceBytes = utf8.encode(jsonEncode(_fixtureSnapshot().toJson()));
    await sourceFile.writeAsBytes(sourceBytes);
    final repository = TaskInboxSqliteStore(
      path: '${temp.path}/task_inbox_state.sqlite3',
    );
    addTearDown(repository.close);
    final migrator = TaskInboxMigrator(
      source: TaskInboxStateStore(path: sourceFile.path),
      repository: repository,
      finalizeBackup: (source, checksum, timestamp) async {
        final backup = await source.rename('${source.path}.invalid-backup');
        await backup.writeAsString('corrupted after rename');
        return backup.path;
      },
    );

    await expectLater(
      migrator.migrateIfNeeded(),
      throwsA(isA<FileSystemException>()),
    );

    expect(await sourceFile.readAsBytes(), sourceBytes);
    expect(await repository.isActive(), isFalse);
  });

  test('rejects a legacy state symlink', () async {
    final temp = await Directory.systemTemp.createTemp('task-migrator-');
    addTearDown(() => temp.delete(recursive: true));
    final target = File('${temp.path}/real-task-state.json');
    await target.writeAsString(jsonEncode(_fixtureSnapshot().toJson()));
    final sourcePath = '${temp.path}/task_inbox_state.json';
    await Link(sourcePath).create(target.path);
    final repository = TaskInboxSqliteStore(
      path: '${temp.path}/task_inbox_state.sqlite3',
    );
    addTearDown(repository.close);
    final migrator = TaskInboxMigrator(
      source: TaskInboxStateStore(path: sourcePath),
      repository: repository,
    );

    await expectLater(
      migrator.migrateIfNeeded(),
      throwsA(isA<FileSystemException>()),
    );

    expect(await Link(sourcePath).exists(), isTrue);
    expect(await target.exists(), isTrue);
    expect(await repository.isActive(), isFalse);
  });

  test('unknown migration state fails without clearing records', () async {
    final temp = await Directory.systemTemp.createTemp('task-migrator-');
    addTearDown(() => temp.delete(recursive: true));
    final databasePath = '${temp.path}/task_inbox_state.sqlite3';
    final fixture = _fixtureSnapshot();
    final initial = TaskInboxSqliteStore(path: databasePath);
    await initial.activateVerifiedSnapshot(fixture, checksum: 'fixture');
    await initial.close();
    final database = sqlite3.open(databasePath);
    database.execute(
      "UPDATE store_meta SET migration_state = 'future-version' WHERE id = 1;",
    );
    database.close();
    final repository = TaskInboxSqliteStore(path: databasePath);
    addTearDown(repository.close);
    final migrator = TaskInboxMigrator(
      source: TaskInboxStateStore(path: '${temp.path}/task_inbox_state.json'),
      repository: repository,
    );

    await expectLater(migrator.migrateIfNeeded(), throwsStateError);

    expect(
      (await repository.loadRepository()).snapshot.toJson(),
      fixture.toJson(),
    );
  });
}

TaskInboxSnapshot _fixtureSnapshot() {
  final createdAt = DateTime.utc(2026, 7, 10, 7);
  const resource = WorkspaceResource(
    id: 'resource-1',
    type: ResourceType.localDirectory,
    label: 'App',
    ref: <String, Object?>{'path': '/workspace/app'},
  );
  const gitResource = WorkspaceResource(
    id: 'resource-2',
    type: ResourceType.gitRepo,
    label: 'Git app',
    ref: <String, Object?>{'path': '/workspace/git-app'},
  );
  const docsResource = WorkspaceResource(
    id: 'resource-3',
    type: ResourceType.docsDirectory,
    label: 'Docs',
    ref: <String, Object?>{'path': '/workspace/docs'},
  );
  final task = TaskRecord(
    id: 'task-1',
    title: 'Migrate me',
    description: ' Preserve all task state.\n',
    workspacePath: '/workspace/app',
    agentName: 'Codex',
    status: TaskStatus.needsHumanReview,
    priority: TaskPriority.high,
    createdAt: createdAt,
    updatedAt: createdAt.add(const Duration(minutes: 5)),
    sessionId: 'session-1',
    currentRunId: 'run-1',
    resourceId: resource.id,
    skillIds: const ['review'],
    metadata: const <String, Object?>{'source': 'legacy'},
  );
  final run = TaskRunRecord(
    id: 'run-1',
    taskId: task.id,
    attempt: 1,
    status: TaskStatus.needsHumanReview,
    startedAt: createdAt,
    endedAt: createdAt.add(const Duration(minutes: 5)),
    sessionId: 'session-1',
  );
  return TaskInboxSnapshot(
    updatedAt: createdAt.add(const Duration(minutes: 6)),
    tasks: [task],
    runs: [run],
    events: [
      TaskEventRecord(
        id: 'event-1',
        taskId: task.id,
        runId: run.id,
        kind: TaskEventKind.assistant,
        text: 'done\n',
        createdAt: createdAt.add(const Duration(minutes: 4)),
      ),
    ],
    artifacts: [
      ArtifactRecord(
        id: 'artifact-1',
        taskId: task.id,
        runId: run.id,
        kind: ArtifactKind.gitDiff,
        title: 'Diff',
        createdAt: createdAt.add(const Duration(minutes: 4)),
        contentPreview: 'diff --git a/file b/file\n',
      ),
    ],
    approvals: [
      ApprovalRequestRecord(
        id: 'approval-1',
        taskId: task.id,
        runId: run.id,
        kind: ApprovalKind.toolPermission,
        status: ApprovalStatus.approved,
        createdAt: createdAt.add(const Duration(minutes: 2)),
      ),
    ],
    resources: const [resource, gitResource, docsResource],
  );
}

class _MutatingImportStore extends TaskInboxSqliteStore {
  _MutatingImportStore({required super.path, required this.source});

  final File source;

  @override
  Future<TaskImportDisposition> importSnapshot(
    TaskInboxSnapshot snapshot, {
    required String checksum,
  }) async {
    final disposition = await super.importSnapshot(
      snapshot,
      checksum: checksum,
    );
    await source.writeAsString('${await source.readAsString()}\n');
    return disposition;
  }
}
