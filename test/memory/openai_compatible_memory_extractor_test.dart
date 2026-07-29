import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/memory/openai_compatible_memory_extractor.dart';

void main() {
  test('OpenAI-compatible extractor posts model and API key', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);

    final received = <String, Object?>{};
    unawaited(
      server.first.then((request) async {
        received['path'] = request.uri.path;
        received['authorization'] = request.headers.value(
          HttpHeaders.authorizationHeader,
        );
        received['body'] = jsonDecode(await utf8.decodeStream(request));
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'content':
                      '{"candidates":[{"kind":"session_summary","scope":"session","text":"User confirmed local memory extraction wiring.","confidence":0.88}]}',
                },
              },
            ],
          }),
        );
        await request.response.close();
      }),
    );

    final extractor = OpenAiCompatibleMemoryExtractor(
      baseUrl: 'http://127.0.0.1:${server.port}/v1',
      model: 'qwen2.5:7b',
      apiKey: 'test-key',
      globalInstructions: 'Only remember durable user preferences.',
      workspaceInstructions: 'Ignore workspace scratch notes.',
      repoInstructions: 'Prioritize repo rules.',
    );
    final candidates = await extractor.extract(
      userPrompt: '确认',
      assistantAnswer: '已接线。',
    );

    expect(received['path'], '/v1/chat/completions');
    expect(received['authorization'], 'Bearer test-key');
    expect((received['body'] as Map)['model'], 'qwen2.5:7b');
    final messages = (received['body'] as Map)['messages'] as List;
    final prompt = (messages.single as Map)['content'] as String;
    expect(
      prompt,
      contains('[global] Only remember durable user preferences.'),
    );
    expect(prompt, contains('[workspace] Ignore workspace scratch notes.'));
    expect(prompt, contains('[repo] Prioritize repo rules.'));
    expect(candidates, hasLength(1));
    expect(candidates.single.kind, 'session_summary');
    expect(candidates.single.scope, 'session');
  });
}
