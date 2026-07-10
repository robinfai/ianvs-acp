import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'task_inbox_snapshot.dart';
import 'task_inbox_sqlite_store.dart';
import 'task_inbox_state_store.dart';
import 'task_repository.dart';

enum TaskMigrationStatus { notNeeded, migrated, awaitingBackupFinalization }

class TaskMigrationResult {
  const TaskMigrationResult({
    required this.status,
    this.backupPath,
    this.checksum,
  });

  final TaskMigrationStatus status;
  final String? backupPath;
  final String? checksum;
}

typedef TaskBackupFinalizer =
    Future<String> Function(File source, String checksum, DateTime timestamp);

class TaskInboxMigrator {
  TaskInboxMigrator({
    required this.source,
    required this.repository,
    TaskBackupFinalizer? finalizeBackup,
    DateTime Function()? clock,
  }) : _finalizeBackup = finalizeBackup ?? _defaultFinalizeBackup,
       _clock = clock ?? DateTime.now;

  final TaskInboxStateStore source;
  final TaskInboxSqliteStore repository;
  final TaskBackupFinalizer _finalizeBackup;
  final DateTime Function() _clock;

  Future<TaskMigrationResult> migrateIfNeeded() async {
    await repository.initialize();
    final sourceFile = source.file;
    final metadata = await repository.migrationMetadata();
    if (sourceFile == null) {
      return _resumeWithoutSource(sourceFile, metadata);
    }
    final sourceType = await FileSystemEntity.type(
      sourceFile.path,
      followLinks: false,
    );
    if (sourceType == FileSystemEntityType.notFound) {
      return _resumeWithoutSource(sourceFile, metadata);
    }
    if (sourceType != FileSystemEntityType.file) {
      throw FileSystemException(
        'Legacy task state must be a regular file.',
        sourceFile.path,
      );
    }
    if (metadata.phase == TaskMigrationPhase.active) {
      return const TaskMigrationResult(status: TaskMigrationStatus.notNeeded);
    }

    final sourceBytes = await sourceFile.readAsBytes();
    final checksum = sha256.convert(sourceBytes).toString();
    final snapshot = TaskInboxSnapshot.fromJsonStrict(
      jsonDecode(utf8.decode(sourceBytes)),
    );

    final disposition = await repository.importSnapshot(
      snapshot,
      checksum: checksum,
    );
    if (disposition == TaskImportDisposition.alreadyActive) {
      return const TaskMigrationResult(status: TaskMigrationStatus.notNeeded);
    }
    if (!await _matchesImportedSnapshot(snapshot)) {
      await repository.rollbackImport(checksum);
      throw StateError('Task migration verification failed.');
    }
    late final File recoveryFile;
    try {
      recoveryFile = await _stageRecoveryFile(
        sourceFile,
        sourceBytes,
        checksum,
      );
    } on Object catch (error, stackTrace) {
      if (await _matchesRegularFile(sourceFile, checksum)) {
        await repository.rollbackImport(checksum);
      }
      Error.throwWithStackTrace(error, stackTrace);
    }

    String? backupPath;
    var backupVerified = false;
    try {
      backupPath = await _finalizeBackup(
        sourceFile,
        checksum,
        _clock().toUtc(),
      );
      if (await sourceFile.exists()) {
        throw FileSystemException(
          'Legacy task state was not moved to the backup.',
          sourceFile.path,
        );
      }
      final backup = File(backupPath);
      await _verifyRegularFile(backup, checksum);
      await _makeReadOnly(backup);
      await _verifyReadOnly(backup);
      backupVerified = true;
      await repository.activateVerifiedSnapshot(snapshot, checksum: checksum);
      await _deleteRecoveryFiles(sourceFile, checksum);
      return TaskMigrationResult(
        status: TaskMigrationStatus.migrated,
        backupPath: backupPath,
        checksum: checksum,
      );
    } on Object catch (error, stackTrace) {
      if (await _matchesRegularFile(sourceFile, checksum)) {
        await repository.rollbackImport(checksum);
        await _deleteRecoveryFile(recoveryFile);
        Error.throwWithStackTrace(error, stackTrace);
      }
      final sourceType = await FileSystemEntity.type(
        sourceFile.path,
        followLinks: false,
      );
      if (sourceType != FileSystemEntityType.notFound) {
        throw FileSystemException(
          'Legacy task state changed while recovery was in progress; '
          'the imported records were preserved for manual recovery.',
          sourceFile.path,
        );
      }
      if (backupVerified) {
        final result = await _resumeWithoutSource(
          sourceFile,
          await repository.migrationMetadata(),
        );
        await _deleteRecoveryFiles(sourceFile, checksum);
        return result;
      }

      final currentMetadata = await repository.migrationMetadata();
      if (currentMetadata.phase != TaskMigrationPhase.inactive) {
        final concurrentRecovery = await _resumeWithoutSource(
          sourceFile,
          currentMetadata,
          recoverTemporary: false,
        );
        if (concurrentRecovery.status !=
            TaskMigrationStatus.awaitingBackupFinalization) {
          await _deleteRecoveryFiles(sourceFile, checksum);
          return concurrentRecovery;
        }
      }

      try {
        await _publishRecoveryFile(recoveryFile, sourceFile, checksum);
      } on Object catch (restoreError, restoreStackTrace) {
        if (!await _matchesRegularFile(sourceFile, checksum)) {
          Error.throwWithStackTrace(restoreError, restoreStackTrace);
        }
      }
      await repository.rollbackImport(checksum);
      await _deleteRecoveryFile(recoveryFile);
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<TaskMigrationResult> _resumeWithoutSource(
    File? sourceFile,
    TaskMigrationMetadata metadata, {
    bool recoverTemporary = true,
  }) async {
    if (metadata.phase == TaskMigrationPhase.active) {
      final checksum = metadata.sourceChecksum;
      if (sourceFile != null && checksum != null) {
        await _deleteRecoveryFiles(sourceFile, checksum);
      }
      return const TaskMigrationResult(status: TaskMigrationStatus.notNeeded);
    }
    if (metadata.phase == TaskMigrationPhase.importing ||
        (metadata.phase == TaskMigrationPhase.inactive &&
            metadata.sourceChecksum != null)) {
      final checksum = metadata.sourceChecksum;
      if (sourceFile == null || checksum == null) {
        return TaskMigrationResult(
          status: TaskMigrationStatus.awaitingBackupFinalization,
          checksum: checksum,
        );
      }
      final backup = await _findVerifiedBackup(sourceFile, checksum);
      if (backup != null) {
        final snapshot = await _readVerifiedSnapshot(backup, checksum);
        await _makeReadOnly(backup);
        await _verifyReadOnly(backup);
        await repository.activateVerifiedSnapshot(snapshot, checksum: checksum);
        await _deleteRecoveryFiles(sourceFile, checksum);
        return TaskMigrationResult(
          status: TaskMigrationStatus.migrated,
          backupPath: backup.path,
          checksum: checksum,
        );
      }
      if (recoverTemporary) {
        final recovery = await _findVerifiedRecoveryFile(sourceFile, checksum);
        if (recovery != null) {
          await _publishRecoveryFile(recovery, sourceFile, checksum);
          await repository.rollbackImport(checksum);
          return migrateIfNeeded();
        }
      }
      return TaskMigrationResult(
        status: TaskMigrationStatus.awaitingBackupFinalization,
        checksum: checksum,
      );
    }

    final empty = TaskInboxSnapshot.empty(updatedAt: _clock().toUtc());
    final checksum = sha256.convert(utf8.encode(canonicalJson(empty.toJson())));
    try {
      await repository.activateVerifiedSnapshot(
        empty,
        checksum: checksum.toString(),
      );
    } on StateError {
      if (!await repository.isActive()) rethrow;
    }
    return TaskMigrationResult(
      status: TaskMigrationStatus.notNeeded,
      checksum: checksum.toString(),
    );
  }

  Future<bool> _matchesImportedSnapshot(
    TaskInboxSnapshot sourceSnapshot,
  ) async {
    final imported = await repository.load();
    final sourceDigest = sha256.convert(
      utf8.encode(canonicalJson(sourceSnapshot.toJson())),
    );
    final importedDigest = sha256.convert(
      utf8.encode(canonicalJson(imported.toJson())),
    );
    return sourceDigest == importedDigest;
  }

  Future<File?> _findVerifiedBackup(File sourceFile, String checksum) async {
    final sourceName = _basename(sourceFile.path);
    final extensionIndex = sourceName.lastIndexOf('.');
    final stem = extensionIndex < 1
        ? sourceName
        : sourceName.substring(0, extensionIndex);
    await for (final entity in sourceFile.parent.list()) {
      if (entity is! File) continue;
      final name = _basename(entity.path);
      if (!name.startsWith('$stem.migrated.') || !name.contains(checksum)) {
        continue;
      }
      try {
        await _verifyRegularFile(entity, checksum);
        return entity;
      } on FileSystemException {
        continue;
      }
    }
    return null;
  }

  Future<File?> _findVerifiedRecoveryFile(
    File sourceFile,
    String checksum,
  ) async {
    final prefix = '${_basename(sourceFile.path)}.restore.$checksum.';
    await for (final entity in sourceFile.parent.list()) {
      if (entity is! File) continue;
      final name = _basename(entity.path);
      if (!name.startsWith(prefix) || !name.endsWith('.tmp')) continue;
      try {
        await _verifyRegularFile(entity, checksum);
        return entity;
      } on FileSystemException {
        continue;
      }
    }
    return null;
  }

  Future<void> _deleteRecoveryFiles(File sourceFile, String checksum) async {
    final prefix = '${_basename(sourceFile.path)}.restore.$checksum.';
    await for (final entity in sourceFile.parent.list()) {
      if (entity is! File) continue;
      final name = _basename(entity.path);
      if (!name.startsWith(prefix) || !name.endsWith('.tmp')) continue;
      try {
        final type = await FileSystemEntity.type(
          entity.path,
          followLinks: false,
        );
        if (type != FileSystemEntityType.file) continue;
        await entity.delete();
      } on FileSystemException {
        continue;
      }
    }
  }
}

String canonicalJson(Object? value) => jsonEncode(_canonicalize(value));

Object? _canonicalize(Object? value) {
  if (value is Map) {
    final keys = value.keys.whereType<String>().toList()..sort();
    return <String, Object?>{
      for (final key in keys) key: _canonicalize(value[key]),
    };
  }
  if (value is List) {
    return value.map(_canonicalize).toList(growable: false);
  }
  return value;
}

Future<String> _defaultFinalizeBackup(
  File source,
  String checksum,
  DateTime timestamp,
) async {
  final currentChecksum = sha256.convert(source.readAsBytesSync()).toString();
  if (currentChecksum != checksum) {
    throw FileSystemException(
      'Task state changed while migration was in progress.',
      source.path,
    );
  }
  final sourceName = _basename(source.path);
  final extensionIndex = sourceName.lastIndexOf('.');
  final stem = extensionIndex < 1
      ? sourceName
      : sourceName.substring(0, extensionIndex);
  final extension = extensionIndex < 1
      ? ''
      : sourceName.substring(extensionIndex);
  final timestampToken = timestamp.toIso8601String().replaceAll(':', '-');
  final backup = File(
    '${source.parent.path}${Platform.pathSeparator}'
    '$stem.migrated.$timestampToken.$checksum$extension.bak',
  );
  if (await backup.exists()) {
    throw FileSystemException('Task backup already exists.', backup.path);
  }

  final renamed = await source.rename(backup.path);
  await _verifyRegularFile(renamed, checksum);
  await _makeReadOnly(renamed);
  return renamed.path;
}

Future<void> _makeReadOnly(File file) async {
  final result = Platform.isWindows
      ? Process.runSync('attrib', ['+R', file.path])
      : Process.runSync('chmod', ['0400', file.path]);
  if (result.exitCode != 0) {
    throw FileSystemException(
      'Could not make task backup read-only: ${result.stderr}',
      file.path,
    );
  }
}

Future<void> _verifyRegularFile(File file, String checksum) async {
  final type = await FileSystemEntity.type(file.path, followLinks: false);
  if (type != FileSystemEntityType.file) {
    throw FileSystemException('Task backup is not a regular file.', file.path);
  }
  final digest = sha256.convert(await file.readAsBytes()).toString();
  if (digest != checksum) {
    throw FileSystemException(
      'Task backup checksum verification failed.',
      file.path,
    );
  }
}

Future<TaskInboxSnapshot> _readVerifiedSnapshot(
  File file,
  String checksum,
) async {
  final type = await FileSystemEntity.type(file.path, followLinks: false);
  if (type != FileSystemEntityType.file) {
    throw FileSystemException('Task backup is not a regular file.', file.path);
  }
  final bytes = await file.readAsBytes();
  if (sha256.convert(bytes).toString() != checksum) {
    throw FileSystemException(
      'Task backup checksum verification failed.',
      file.path,
    );
  }
  return TaskInboxSnapshot.fromJsonStrict(jsonDecode(utf8.decode(bytes)));
}

Future<void> _verifyReadOnly(File file) async {
  if (Platform.isWindows) return;
  final permissions = (await file.stat()).mode & 0x1ff;
  if (permissions != 0x100) {
    throw FileSystemException('Task backup is not read-only.', file.path);
  }
}

Future<File> _stageRecoveryFile(
  File source,
  List<int> sourceBytes,
  String checksum,
) async {
  await source.parent.create(recursive: true);
  final temporary = File(
    '${source.path}.restore.$checksum.$pid.'
    '${DateTime.now().microsecondsSinceEpoch}.tmp',
  );
  try {
    await temporary.create(exclusive: true);
    if (!Platform.isWindows) {
      final chmod = Process.runSync('chmod', ['0600', temporary.path]);
      if (chmod.exitCode != 0) {
        throw FileSystemException(
          'Could not secure task recovery file: ${chmod.stderr}',
          temporary.path,
        );
      }
    }
    await temporary.writeAsBytes(sourceBytes, flush: true);
    await _verifyRegularFile(temporary, checksum);
    return temporary;
  } on Object {
    if (await temporary.exists()) await temporary.delete();
    rethrow;
  }
}

Future<void> _publishRecoveryFile(
  File recovery,
  File source,
  String checksum,
) async {
  await _verifyRegularFile(recovery, checksum);
  final existingType = await FileSystemEntity.type(
    source.path,
    followLinks: false,
  );
  if (existingType != FileSystemEntityType.notFound) {
    if (await _matchesRegularFile(source, checksum)) {
      await recovery.delete();
      return;
    }
    throw FileSystemException(
      'Could not restore legacy task state without overwriting a new file.',
      source.path,
    );
  }

  if (Platform.isWindows) {
    await recovery.rename(source.path);
  } else {
    final link = Process.runSync('ln', [recovery.path, source.path]);
    if (link.exitCode != 0) {
      throw FileSystemException(
        'Could not restore legacy task state without overwriting a new file: '
        '${link.stderr}',
        source.path,
      );
    }
    await recovery.delete();
  }
  await _verifyRegularFile(source, checksum);
}

Future<bool> _matchesRegularFile(File file, String checksum) async {
  try {
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type != FileSystemEntityType.file) return false;
    return sha256.convert(await file.readAsBytes()).toString() == checksum;
  } on FileSystemException {
    return false;
  }
}

Future<void> _deleteRecoveryFile(File file) async {
  try {
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.file) await file.delete();
  } on FileSystemException {
    // A concurrent successful migration may already have removed the file.
  }
}

String _basename(String path) {
  final normalized = path.replaceAll('\\', '/');
  return normalized.substring(normalized.lastIndexOf('/') + 1);
}
