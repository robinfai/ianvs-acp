import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/memory/memory_api_client.dart';
import 'package:ianvs_acp/memory/memory_extraction.dart';

void main() {
  test('MemorySearchRequest serializes scope with camelCase keys', () {
    final request = MemorySearchRequest(
      query: 'Flutter owns ACP',
      scope: const MemoryScopeData(
        userId: 'local-user',
        workspaceId: 'workspace-1',
        repoId: 'repo-1',
        agentId: 'agent-1',
        sessionId: 'session-1',
      ),
      limit: 12,
    );
    expect(request.toJson()['scope'], {
      'userId': 'local-user',
      'workspaceId': 'workspace-1',
      'repoId': 'repo-1',
      'agentId': 'agent-1',
      'sessionId': 'session-1',
    });
  });

  test(
    'MemoryApiClient searches with bearer auth and builds context',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);

      final received = <String, Object?>{};
      unawaited(
        server.first.then((request) async {
          received['path'] = request.uri.path;
          received['authorization'] = request.headers.value(
            HttpHeaders.authorizationHeader,
          );
          final body = await utf8.decodeStream(request);
          received['body'] = jsonDecode(body);
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'items': [
                {
                  'id': 'mem_1',
                  'kind': 'project_rule',
                  'scope': 'repo',
                  'text': 'Use curl for local service checks.',
                  'score': 0.9,
                  'metadata': {},
                },
              ],
            }),
          );
          await request.response.close();
        }),
      );

      final client = MemoryApiClient(
        baseUrl: Uri.parse('http://127.0.0.1:${server.port}'),
        token: 'secret-token',
      );
      addTearDown(client.close);

      final context = await client.searchContext(
        const MemorySearchRequest(
          query: 'service checks',
          scope: MemoryScopeData(
            userId: 'local-user',
            workspaceId: 'workspace-1',
            repoId: 'repo-1',
          ),
        ),
      );

      expect(received['path'], '/v1/memory/search');
      expect(received['authorization'], 'Bearer secret-token');
      expect((received['body'] as Map)['query'], 'service checks');
      expect(context, contains('<agent_memory_context>'));
      expect(
        context,
        contains('[project_rule] Use curl for local service checks.'),
      );
    },
  );

  test('MemoryApiClient posts extracted candidates with scope', () async {
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
        request.response.write(jsonEncode({'candidates': []}));
        await request.response.close();
      }),
    );

    final client = MemoryApiClient(
      baseUrl: Uri.parse('http://127.0.0.1:${server.port}'),
      token: 'secret-token',
    );
    addTearDown(client.close);

    await client.createCandidates(
      scope: const MemoryScopeData(
        userId: 'local-user',
        workspaceId: 'workspace-1',
        repoId: 'repo-1',
        agentId: 'agent-1',
        sessionId: 'session-1',
      ),
      candidates: const [
        ExtractedMemoryCandidate(
          kind: 'project_rule',
          scope: 'repo',
          text: 'Never use nc/netcat.',
          confidence: 0.9,
        ),
      ],
    );

    expect(received['path'], '/v1/memory/extract-candidates');
    expect(received['authorization'], 'Bearer secret-token');
    final body = received['body'] as Map;
    expect(body['scope'], containsPair('sessionId', 'session-1'));
    expect(body['preExtractedCandidates'], isA<List>());
  });

  test('MemoryApiClient times out stalled daemon search', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);

    unawaited(
      server.first.then((request) async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'items': []}));
        await request.response.close();
      }),
    );

    final client = MemoryApiClient(
      baseUrl: Uri.parse('http://127.0.0.1:${server.port}'),
      token: 'secret-token',
      timeout: const Duration(milliseconds: 20),
    );
    addTearDown(client.close);

    await expectLater(
      client.search(
        const MemorySearchRequest(
          query: 'slow daemon',
          scope: MemoryScopeData(userId: 'local-user'),
        ),
      ),
      throwsA(isA<TimeoutException>()),
    );
  });
}
