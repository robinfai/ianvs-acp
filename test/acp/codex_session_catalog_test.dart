import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/codex_session_catalog.dart';

void main() {
  test('loads sessions grouped by project cwd', () async {
    final home = await Directory.systemTemp.createTemp('codex_home_');
    addTearDown(() => home.delete(recursive: true));

    await File('${home.path}/session_index.jsonl').writeAsString(
      '${jsonEncode({'id': 'session-b', 'thread_name': 'Indexed conversation title', 'updated_at': '2026-05-29T10:00:00Z'})}\n',
    );
    await _writeSession(
      home: home,
      id: 'session-a',
      cwd: '/workspace/project-a',
      timestamp: '2026-05-28T12:00:00Z',
      userText: 'Fallback title from the first user message.',
      extraUserText: 'Second real prompt in the same conversation.',
      includeInternalUserMessage: true,
    );
    await _writeSession(
      home: home,
      id: 'session-b',
      cwd: '/workspace/project-b',
      timestamp: '2026-05-27T12:00:00Z',
      userText: 'This title should be replaced by the index.',
    );

    final projects = await CodexSessionCatalog(codexHome: home.path).load();

    expect(projects, hasLength(2));
    expect(projects.first.cwd, '/workspace/project-b');
    expect(projects.first.name, 'project-b');
    expect(
      projects.first.conversations.single.title,
      'Indexed conversation title',
    );
    expect(
      projects.last.conversations.single.title,
      'Fallback title from the first user message.',
    );
    expect(projects.last.conversations.single.turnCount, 2);
    expect(
      projects.last.conversations.single.dropdownLabel,
      contains('2 turns'),
    );
  });

  test('ignores malformed session files', () async {
    final home = await Directory.systemTemp.createTemp('codex_home_');
    addTearDown(() => home.delete(recursive: true));
    final sessions = Directory('${home.path}/sessions/2026/05/29');
    await sessions.create(recursive: true);
    await File('${sessions.path}/bad.jsonl').writeAsString('not json\n');
    await File('${sessions.path}/missing-cwd.jsonl').writeAsString(
      '${jsonEncode({
        'timestamp': '2026-05-29T10:00:00Z',
        'type': 'session_meta',
        'payload': {'id': 'session-c'},
      })}\n',
    );

    final projects = await CodexSessionCatalog(codexHome: home.path).load();

    expect(projects, isEmpty);
  });
}

Future<void> _writeSession({
  required Directory home,
  required String id,
  required String cwd,
  required String timestamp,
  required String userText,
  String? extraUserText,
  bool includeInternalUserMessage = false,
}) async {
  final sessions = Directory('${home.path}/sessions/2026/05/29');
  await sessions.create(recursive: true);
  final file = File('${sessions.path}/rollout-$id.jsonl');
  final lines = [
    jsonEncode({
      'timestamp': timestamp,
      'type': 'session_meta',
      'payload': {'id': id, 'timestamp': timestamp, 'cwd': cwd},
    }),
    jsonEncode({
      'timestamp': timestamp,
      'type': 'response_item',
      'payload': {
        'type': 'message',
        'role': 'user',
        'content': [
          {'type': 'input_text', 'text': userText},
        ],
      },
    }),
    if (includeInternalUserMessage)
      jsonEncode({
        'timestamp': timestamp,
        'type': 'response_item',
        'payload': {
          'type': 'message',
          'role': 'user',
          'content': [
            {
              'type': 'input_text',
              'text': '<environment_context>ignored</environment_context>',
            },
          ],
        },
      }),
    if (extraUserText != null)
      jsonEncode({
        'timestamp': timestamp,
        'type': 'response_item',
        'payload': {
          'type': 'message',
          'role': 'user',
          'content': [
            {'type': 'input_text', 'text': extraUserText},
          ],
        },
      }),
  ];
  await file.writeAsString('${lines.join('\n')}\n');
}
