import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/storage/session_transcript_cache.dart';

void main() {
  late Directory directory;
  late FileSessionTranscriptCache cache;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'ianvs-session-transcript-cache-',
    );
    cache = FileSessionTranscriptCache(directoryPath: directory.path);
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test(
    'custom config cache is isolated from a user-owned sibling directory',
    () async {
      final customDirectory = Directory('${directory.path}/custom');
      final unrelatedDirectory = Directory(
        '${customDirectory.path}/session_transcripts',
      );
      await unrelatedDirectory.create(recursive: true);
      final chmod = await Process.run('/bin/chmod', <String>[
        '0755',
        unrelatedDirectory.path,
      ]);
      expect(chmod.exitCode, 0, reason: chmod.stderr.toString());
      final originalMode = (await unrelatedDirectory.stat()).mode & 0x1ff;
      final sentinel = File('${unrelatedDirectory.path}/user-data.txt');
      await sentinel.writeAsString('keep');
      final resolvedPath = resolveSessionTranscriptCacheDirectoryPath(
        '${customDirectory.path}/settings.json',
      );

      expect(
        resolvedPath,
        '${customDirectory.path}${Platform.pathSeparator}.ianvs-acp'
        '${Platform.pathSeparator}session_transcripts',
      );
      final isolatedCache = FileSessionTranscriptCache(
        directoryPath: resolvedPath!,
      );
      await isolatedCache.save(_snapshot(_identity(), 'isolated'));

      expect(await sentinel.readAsString(), 'keep');
      expect((await unrelatedDirectory.stat()).mode & 0x1ff, originalMode);
      expect(await _transcriptFiles(unrelatedDirectory), isEmpty);
      expect(await _transcriptFiles(Directory(resolvedPath)), hasLength(1));
    },
  );

  test('rejects a symlinked app-owned state directory', () async {
    if (!Platform.isMacOS && !Platform.isLinux) return;
    final customDirectory = Directory('${directory.path}/custom')..createSync();
    final externalDirectory = Directory('${directory.path}/external')
      ..createSync();
    final chmod = await Process.run('/bin/chmod', <String>[
      '0755',
      externalDirectory.path,
    ]);
    expect(chmod.exitCode, 0, reason: chmod.stderr.toString());
    final originalMode = (await externalDirectory.stat()).mode & 0x1ff;
    final sentinel = File('${externalDirectory.path}/user-data.txt');
    await sentinel.writeAsString('keep');
    await Link(
      '${customDirectory.path}/.ianvs-acp',
    ).create(externalDirectory.path);
    final resolvedPath = resolveSessionTranscriptCacheDirectoryPath(
      '${customDirectory.path}/settings.json',
    );
    final isolatedCache = FileSessionTranscriptCache(
      directoryPath: resolvedPath!,
    );

    await expectLater(
      isolatedCache.save(_snapshot(_identity(), 'must not escape')),
      throwsA(isA<FileSystemException>()),
    );

    expect(await sentinel.readAsString(), 'keep');
    expect((await externalDirectory.stat()).mode & 0x1ff, originalMode);
    final externalEntries = await externalDirectory
        .list(followLinks: false)
        .toList();
    expect(externalEntries, hasLength(1));
    expect(externalEntries.single.path, sentinel.path);
  });

  test(
    'round trips a versioned transcript for the exact session revision',
    () async {
      final identity = _identity();
      await cache.save(
        SessionTranscriptSnapshot(
          identity: identity,
          timelineHistoryWasTruncated: true,
          messages: <Map<String, Object?>>[
            <String, Object?>{
              'role': 'assistant',
              'text': 'cached answer',
              'timestamp': '2026-08-04T12:00:00.000Z',
              'metadata': <String, Object?>{
                'kind': 'tool',
                'rawOutput': <String, Object?>{'text': 'done'},
              },
              'omissions': <Object?>[],
              'turnId': 7,
            },
          ],
        ),
      );

      final restored = await cache.load(identity);

      expect(restored, isNotNull);
      expect(restored!.identity.matches(identity), isTrue);
      expect(restored.timelineHistoryWasTruncated, isTrue);
      expect(restored.messages.single['text'], 'cached answer');
      expect(
        (restored.messages.single['metadata'] as Map)['rawOutput'],
        <String, Object?>{'text': 'done'},
      );
    },
  );

  test('load rejects a snapshot beyond the instance byte limit', () async {
    final identity = _identity(sessionId: 'session-oversized');
    final limitedCache = FileSessionTranscriptCache(
      directoryPath: directory.path,
      maxFileBytes: 1024,
    );
    await limitedCache.save(_snapshot(identity, 'seed'));
    final file = (await _transcriptFiles(directory)).single;
    await file.writeAsBytes(List<int>.filled(1025, 0x20));

    expect(await limitedCache.load(identity), isNull);
  });

  test(
    'does not reuse a transcript after the catalog revision changes',
    () async {
      await cache.save(
        SessionTranscriptSnapshot(
          identity: _identity(),
          messages: <Map<String, Object?>>[
            <String, Object?>{
              'role': 'assistant',
              'text': 'stale',
              'timestamp': '2026-08-04T12:00:00.000Z',
              'metadata': <String, Object?>{},
              'omissions': <Object?>[],
            },
          ],
        ),
      );

      expect(
        await cache.load(_identity(updatedAt: DateTime.utc(2026, 8, 4, 13))),
        isNull,
      );
    },
  );

  test('a new revision atomically replaces the prior session file', () async {
    final first = _identity();
    final second = _identity(updatedAt: DateTime.utc(2026, 8, 4, 13));
    await cache.save(_snapshot(first, 'old revision'));
    await cache.save(_snapshot(second, 'new revision'));

    final transcriptFiles = await directory
        .list()
        .where((entry) => entry.path.endsWith('.transcript.json'))
        .toList();
    expect(transcriptFiles, hasLength(1));
    expect(await cache.load(first), isNull);
    expect((await cache.load(second))?.messages.single['text'], 'new revision');
  });

  test(
    'maintenance removes expired transcripts but not unrelated files',
    () async {
      final identity = _identity();
      await cache.save(_snapshot(identity, 'expired transcript'));
      final transcript = (await _transcriptFiles(directory)).single;
      await transcript.setLastModified(DateTime.utc(2026, 6, 1));
      final unrelated = File('${directory.path}/notes.json');
      await unrelated.writeAsString('keep');
      final maintainedCache = FileSessionTranscriptCache(
        directoryPath: directory.path,
        retention: const Duration(days: 30),
        now: () => DateTime.utc(2026, 8, 9),
      );

      await maintainedCache.maintain();

      expect(await transcript.exists(), isFalse);
      expect(await unrelated.readAsString(), 'keep');
    },
  );

  test(
    'maintenance evicts the oldest transcripts to meet its total cap',
    () async {
      final first = _identity(sessionId: 'session-oldest');
      final second = _identity(sessionId: 'session-newest');
      await cache.save(_snapshot(first, 'oldest transcript'));
      final firstFile = (await _transcriptFiles(directory)).single;
      await firstFile.setLastModified(DateTime.utc(2026, 8, 7));
      await cache.save(_snapshot(second, 'newest transcript'));
      final files = await _transcriptFiles(directory);
      final secondFile = files.singleWhere(
        (file) => file.path != firstFile.path,
      );
      await secondFile.setLastModified(DateTime.utc(2026, 8, 8));
      final totalBytes = await files.fold<Future<int>>(
        Future<int>.value(0),
        (total, file) async => await total + await file.length(),
      );
      final unrelated = File('${directory.path}/large-unrelated.bin');
      await unrelated.writeAsBytes(List<int>.filled(totalBytes * 2, 1));
      final limitedCache = FileSessionTranscriptCache(
        directoryPath: directory.path,
        maxDirectoryBytes: totalBytes - 1,
        retention: const Duration(days: 30),
        now: () => DateTime.utc(2026, 8, 9),
      );

      await limitedCache.maintain();

      expect(await limitedCache.load(first), isNull);
      expect(
        (await limitedCache.load(second))?.messages.single['text'],
        'newest transcript',
      );
      expect(await unrelated.exists(), isTrue);
      expect(
        await _transcriptFiles(directory).then(
          (remaining) => remaining.fold<Future<int>>(
            Future<int>.value(0),
            (total, file) async => await total + await file.length(),
          ),
        ),
        lessThanOrEqualTo(totalBytes - 1),
      );
    },
  );

  test('saving automatically maintains the directory capacity', () async {
    final first = _identity(sessionId: 'session-old');
    final second = _identity(sessionId: 'session-new');
    await cache.save(_snapshot(first, 'same-sized transcript'));
    final firstFile = (await _transcriptFiles(directory)).single;
    final fileBytes = await firstFile.length();
    await firstFile.setLastModified(DateTime.utc(2026, 8, 8));
    final limitedCache = FileSessionTranscriptCache(
      directoryPath: directory.path,
      maxDirectoryBytes: fileBytes,
      retention: const Duration(days: 30),
      now: () => DateTime.utc(2026, 8, 9),
    );

    await limitedCache.save(_snapshot(second, 'same-sized transcript'));

    expect(await limitedCache.load(first), isNull);
    expect(
      (await limitedCache.load(second))?.messages.single['text'],
      'same-sized transcript',
    );
    expect(await _transcriptFiles(directory), hasLength(1));
  });

  test('cache misses reuse a fixed set of lock shards', () async {
    for (var index = 0; index < 512; index += 1) {
      expect(
        await cache.load(
          _identity(sessionId: 'missing-${index.toString().padLeft(4, '0')}'),
        ),
        isNull,
      );
    }

    final entries = await _directoryEntries(directory);
    expect(entries, hasLength(lessThanOrEqualTo(64)));
    expect(
      entries,
      everyElement(
        predicate<FileSystemEntity>(
          (entry) => RegExp(
            r'^\.session-transcript-cache-shard-[0-9a-f]{2}\.lock$',
          ).hasMatch(entry.uri.pathSegments.last),
        ),
      ),
    );
  });

  test('retention cleanup leaves only a bounded lock set', () async {
    for (var index = 0; index < 96; index += 1) {
      await cache.save(
        _snapshot(
          _identity(sessionId: 'expired-${index.toString().padLeft(3, '0')}'),
          'expired transcript',
        ),
      );
    }
    for (final transcript in await _transcriptFiles(directory)) {
      await transcript.setLastModified(DateTime.utc(2026, 6, 1));
    }

    final maintainedCache = FileSessionTranscriptCache(
      directoryPath: directory.path,
      retention: const Duration(days: 30),
      now: () => DateTime.utc(2026, 8, 9),
    );
    await maintainedCache.maintain();

    expect(await _transcriptFiles(directory), isEmpty);
    final entries = await _directoryEntries(directory);
    expect(entries, hasLength(lessThanOrEqualTo(65)));
    expect(
      entries,
      everyElement(
        predicate<FileSystemEntity>((entry) => entry.path.endsWith('.lock')),
      ),
    );
  });

  test('capacity eviction keeps total directory entries bounded', () async {
    final firstIdentity = _identity(sessionId: 'capped-000');
    await cache.save(_snapshot(firstIdentity, 'same-sized transcript'));
    final fileBytes = await (await _transcriptFiles(directory)).single.length();
    final limitedCache = FileSessionTranscriptCache(
      directoryPath: directory.path,
      maxDirectoryBytes: fileBytes,
    );

    for (var index = 1; index < 96; index += 1) {
      await limitedCache.save(
        _snapshot(
          _identity(sessionId: 'capped-${index.toString().padLeft(3, '0')}'),
          'same-sized transcript',
        ),
      );
    }

    expect(await _transcriptFiles(directory), hasLength(1));
    expect(
      await _directoryEntries(directory),
      hasLength(lessThanOrEqualTo(66)),
    );
  });
}

Future<List<File>> _transcriptFiles(Directory directory) {
  return directory
      .list(followLinks: false)
      .where((entry) => entry.path.endsWith('.transcript.json'))
      .map((entry) => File(entry.path))
      .toList();
}

Future<List<FileSystemEntity>> _directoryEntries(Directory directory) {
  return directory.list(followLinks: false).toList();
}

SessionTranscriptSnapshot _snapshot(
  SessionTranscriptIdentity identity,
  String text,
) {
  return SessionTranscriptSnapshot(
    identity: identity,
    messages: <Map<String, Object?>>[
      <String, Object?>{
        'role': 'assistant',
        'text': text,
        'timestamp': '2026-08-04T12:00:00.000Z',
        'metadata': <String, Object?>{},
        'omissions': <Object?>[],
      },
    ],
  );
}

SessionTranscriptIdentity _identity({
  DateTime? updatedAt,
  String sessionId = 'session-1',
}) {
  return SessionTranscriptIdentity(
    agentName: 'Codex',
    sessionId: sessionId,
    cwd: '/workspace',
    additionalDirectories: const <String>['/workspace/shared'],
    updatedAt: updatedAt ?? DateTime.utc(2026, 8, 4, 12),
  );
}
