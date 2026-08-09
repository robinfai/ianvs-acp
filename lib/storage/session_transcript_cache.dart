import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';

import '../platform/secure_atomic_file.dart';

final class SessionTranscriptIdentity {
  const SessionTranscriptIdentity({
    required this.agentName,
    required this.sessionId,
    required this.cwd,
    required this.additionalDirectories,
    required this.updatedAt,
  });

  final String agentName;
  final String sessionId;
  final String cwd;
  final List<String> additionalDirectories;
  final DateTime updatedAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'agentName': agentName,
    'sessionId': sessionId,
    'cwd': cwd,
    'additionalDirectories': additionalDirectories,
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };

  bool matches(SessionTranscriptIdentity other) {
    if (agentName != other.agentName ||
        sessionId != other.sessionId ||
        cwd != other.cwd ||
        updatedAt.toUtc() != other.updatedAt.toUtc() ||
        additionalDirectories.length != other.additionalDirectories.length) {
      return false;
    }
    for (var index = 0; index < additionalDirectories.length; index += 1) {
      if (additionalDirectories[index] != other.additionalDirectories[index]) {
        return false;
      }
    }
    return true;
  }

  static SessionTranscriptIdentity? fromJson(Object? value) {
    if (value is! Map) return null;
    final agentName = value['agentName'];
    final sessionId = value['sessionId'];
    final cwd = value['cwd'];
    final updatedAt = value['updatedAt'];
    final directories = value['additionalDirectories'];
    if (agentName is! String ||
        agentName.isEmpty ||
        sessionId is! String ||
        sessionId.isEmpty ||
        cwd is! String ||
        cwd.isEmpty ||
        updatedAt is! String ||
        directories is! List ||
        directories.any((directory) => directory is! String)) {
      return null;
    }
    final parsedUpdatedAt = DateTime.tryParse(updatedAt);
    if (parsedUpdatedAt == null) return null;
    return SessionTranscriptIdentity(
      agentName: agentName,
      sessionId: sessionId,
      cwd: cwd,
      additionalDirectories: directories.cast<String>(),
      updatedAt: parsedUpdatedAt,
    );
  }
}

final class SessionTranscriptSnapshot {
  SessionTranscriptSnapshot({
    required this.identity,
    required List<Map<String, Object?>> messages,
  }) : messages = List<Map<String, Object?>>.unmodifiable(messages);

  final SessionTranscriptIdentity identity;
  final List<Map<String, Object?>> messages;
}

abstract interface class SessionTranscriptCache {
  Future<SessionTranscriptSnapshot?> load(SessionTranscriptIdentity identity);

  Future<void> save(SessionTranscriptSnapshot snapshot);
}

final class FileSessionTranscriptCache implements SessionTranscriptCache {
  const FileSessionTranscriptCache({
    required this.directoryPath,
    this.maxFileBytes = 48 * 1024 * 1024,
    this.maxMessages = 2000,
    this.maxDirectoryBytes = 50 * 1024 * 1024 * 1024,
    this.retention = const Duration(days: 30),
    this.now,
  }) : assert(maxFileBytes > 0),
       assert(maxMessages > 0),
       assert(maxDirectoryBytes > 0),
       assert(retention > Duration.zero);

  static const int schemaVersion = 1;
  static const int _lockShardCount = 64;

  final String directoryPath;
  final int maxFileBytes;
  final int maxMessages;
  final int maxDirectoryBytes;
  final Duration retention;
  final DateTime Function()? now;

  @override
  Future<SessionTranscriptSnapshot?> load(
    SessionTranscriptIdentity identity,
  ) async {
    final target = _file(identity);
    return _synchronizedTranscript(target, (resolvedTarget) async {
      final type = await FileSystemEntity.type(
        resolvedTarget.path,
        followLinks: false,
      );
      if (type == FileSystemEntityType.notFound) return null;
      if (type != FileSystemEntityType.file ||
          !await SecureAtomicFile.protectPrivateFile(
            resolvedTarget,
            create: false,
          )) {
        return null;
      }
      final stat = await resolvedTarget.stat();
      if (_isExpired(stat.modified)) {
        await resolvedTarget.delete();
        return null;
      }
      if (stat.size <= 0 || stat.size > maxFileBytes) return null;
      final source = await resolvedTarget.readAsString();
      final decoded = await Isolate.run(() => jsonDecode(source));
      if (decoded is! Map || decoded['schemaVersion'] != schemaVersion) {
        return null;
      }
      final storedIdentity = SessionTranscriptIdentity.fromJson(
        decoded['identity'],
      );
      if (storedIdentity == null || !storedIdentity.matches(identity)) {
        return null;
      }
      final rawMessages = decoded['messages'];
      if (rawMessages is! List || rawMessages.length > maxMessages) return null;
      final messages = <Map<String, Object?>>[];
      for (final rawMessage in rawMessages) {
        if (rawMessage is! Map) return null;
        final normalized = <String, Object?>{
          for (final entry in rawMessage.entries)
            if (entry.key is String) entry.key as String: entry.value,
        };
        if (normalized['role'] is! String ||
            normalized['text'] is! String ||
            normalized['timestamp'] is! String ||
            normalized['metadata'] is! Map ||
            normalized['omissions'] is! List) {
          return null;
        }
        messages.add(normalized);
      }
      return SessionTranscriptSnapshot(
        identity: storedIdentity,
        messages: messages,
      );
    });
  }

  @override
  Future<void> save(SessionTranscriptSnapshot snapshot) async {
    if (snapshot.messages.length > maxMessages) return;
    final payload = <String, Object?>{
      'schemaVersion': schemaVersion,
      'identity': snapshot.identity.toJson(),
      'messages': snapshot.messages,
    };
    final encodedResult = await Isolate.run(() {
      final encoded = jsonEncode(payload);
      return (value: encoded, bytes: utf8.encode(encoded).length);
    });
    if (encodedResult.bytes > maxFileBytes ||
        encodedResult.bytes > maxDirectoryBytes) {
      return;
    }
    final target = _file(snapshot.identity);
    await SecureAtomicFile.synchronizedAcrossProcesses(_maintenanceTarget, (
      _,
    ) async {
      await _synchronizedTranscript(target, (resolvedTarget) async {
        await SecureAtomicFile.writeString(
          resolvedTarget,
          encodedResult.value,
          protectExistingParent: true,
        );
      });
      await _maintainUnlocked(protectedPath: target.absolute.path);
    });
  }

  /// Removes expired transcripts and evicts the oldest remaining files until
  /// the cache directory is within [maxDirectoryBytes].
  Future<void> maintain() async {
    final directory = Directory(directoryPath);
    if (!await directory.exists()) return;
    await SecureAtomicFile.synchronizedAcrossProcesses(_maintenanceTarget, (
      _,
    ) async {
      await _maintainUnlocked();
    });
  }

  Future<void> _maintainUnlocked({String? protectedPath}) async {
    final cutoff = _currentTime().subtract(retention);
    final expired = (await _transcriptFiles())
        .where((entry) => entry.modified.isBefore(cutoff))
        .toList(growable: false);
    for (final entry in expired) {
      await _deleteIfUnchanged(entry);
    }

    final remaining = await _transcriptFiles();
    var totalBytes = remaining.fold<int>(
      0,
      (total, entry) => total + entry.size,
    );
    if (totalBytes <= maxDirectoryBytes) return;

    remaining.sort((left, right) {
      final modified = left.modified.compareTo(right.modified);
      return modified != 0
          ? modified
          : left.file.path.compareTo(right.file.path);
    });
    for (final entry in remaining) {
      if (totalBytes <= maxDirectoryBytes) return;
      if (entry.file.absolute.path == protectedPath) continue;
      if (await _deleteIfUnchanged(entry)) totalBytes -= entry.size;
    }
  }

  Future<List<_TranscriptFileEntry>> _transcriptFiles() async {
    final directory = Directory(directoryPath);
    if (!await directory.exists()) return <_TranscriptFileEntry>[];
    final entries = <_TranscriptFileEntry>[];
    await for (final entity in directory.list(followLinks: false)) {
      if (!entity.path.endsWith('.transcript.json')) continue;
      final type = await FileSystemEntity.type(entity.path, followLinks: false);
      if (type != FileSystemEntityType.file) continue;
      final file = File(entity.path);
      final stat = await file.stat();
      entries.add(
        _TranscriptFileEntry(
          file: file,
          size: stat.size,
          modified: stat.modified,
        ),
      );
    }
    return entries;
  }

  Future<bool> _deleteIfUnchanged(_TranscriptFileEntry entry) {
    return _synchronizedTranscript(entry.file, (resolvedTarget) async {
      final type = await FileSystemEntity.type(
        resolvedTarget.path,
        followLinks: false,
      );
      if (type != FileSystemEntityType.file) return false;
      final stat = await resolvedTarget.stat();
      if (stat.size != entry.size || stat.modified != entry.modified) {
        return false;
      }
      await resolvedTarget.delete();
      return true;
    });
  }

  bool _isExpired(DateTime modified) {
    return modified.isBefore(_currentTime().subtract(retention));
  }

  DateTime _currentTime() => now?.call() ?? DateTime.now();

  File get _maintenanceTarget =>
      File('$directoryPath${Platform.pathSeparator}.session-transcript-cache');

  Future<T> _synchronizedTranscript<T>(
    File target,
    Future<T> Function(File resolvedTarget) operation,
  ) {
    final basename = target.uri.pathSegments.last;
    final shard =
        sha256.convert(utf8.encode(basename)).bytes.first % _lockShardCount;
    final shardName = shard.toRadixString(16).padLeft(2, '0');
    final lockTarget = File(
      '$directoryPath${Platform.pathSeparator}'
      'session-transcript-cache-shard-$shardName',
    );
    return SecureAtomicFile.synchronizedAcrossProcesses(lockTarget, (
      resolvedLockTarget,
    ) {
      final resolvedTarget = File(
        '${resolvedLockTarget.parent.path}${Platform.pathSeparator}$basename',
      );
      return operation(resolvedTarget);
    });
  }

  File _file(SessionTranscriptIdentity identity) {
    final digest = sha256.convert(
      utf8.encode(
        jsonEncode(<String, Object?>{
          'agentName': identity.agentName,
          'sessionId': identity.sessionId,
          'cwd': identity.cwd,
          'additionalDirectories': identity.additionalDirectories,
        }),
      ),
    );
    return File(
      '$directoryPath${Platform.pathSeparator}$digest.transcript.json',
    );
  }
}

final class _TranscriptFileEntry {
  const _TranscriptFileEntry({
    required this.file,
    required this.size,
    required this.modified,
  });

  final File file;
  final int size;
  final DateTime modified;
}
