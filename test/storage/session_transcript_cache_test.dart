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
    'round trips a versioned transcript for the exact session revision',
    () async {
      final identity = _identity();
      await cache.save(
        SessionTranscriptSnapshot(
          identity: identity,
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
      expect(restored.messages.single['text'], 'cached answer');
      expect(
        (restored.messages.single['metadata'] as Map)['rawOutput'],
        <String, Object?>{'text': 'done'},
      );
    },
  );

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

SessionTranscriptIdentity _identity({DateTime? updatedAt}) {
  return SessionTranscriptIdentity(
    agentName: 'Codex',
    sessionId: 'session-1',
    cwd: '/workspace',
    additionalDirectories: const <String>['/workspace/shared'],
    updatedAt: updatedAt ?? DateTime.utc(2026, 8, 4, 12),
  );
}
