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
  });

  static const int schemaVersion = 1;

  final String directoryPath;
  final int maxFileBytes;
  final int maxMessages;

  @override
  Future<SessionTranscriptSnapshot?> load(
    SessionTranscriptIdentity identity,
  ) async {
    final target = _file(identity);
    return SecureAtomicFile.synchronizedAcrossProcesses(target, (
      resolvedTarget,
    ) async {
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
    if (encodedResult.bytes > maxFileBytes) return;
    final target = _file(snapshot.identity);
    await SecureAtomicFile.synchronizedAcrossProcesses(target, (
      resolvedTarget,
    ) async {
      await SecureAtomicFile.writeString(
        resolvedTarget,
        encodedResult.value,
        protectExistingParent: true,
      );
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
