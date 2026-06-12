import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/memory/memory_api_client.dart';
import 'package:ianvs_acp/memory/memory_extraction.dart';
import 'package:ianvs_acp/memory/memory_maintenance_extraction.dart';

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
        request.response.write(
          jsonEncode({
            'candidates': [],
            'approvedMemories': [
              {
                'id': 'mem_auto',
                'kind': 'project_rule',
                'scope': 'repo',
                'text': 'The project uses Riverpod.',
                'status': 'active',
                'createdAt': 1,
                'updatedAt': 1,
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

    final result = await client.createCandidates(
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
          text: 'The project uses Riverpod.',
          confidence: 0.9,
        ),
      ],
      autoApproveThreshold: 0.85,
    );

    expect(received['path'], '/v1/memory/extract-candidates');
    expect(received['authorization'], 'Bearer secret-token');
    final body = received['body'] as Map;
    expect(body['scope'], containsPair('sessionId', 'session-1'));
    expect(body['autoApproveThreshold'], 0.85);
    expect(body['preExtractedCandidates'], isA<List>());
    expect(result.approvedMemories.single.id, 'mem_auto');
  });

  test('MemoryApiClient lists and reviews candidates', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);

    final paths = <String>[];
    final bodies = <Object?>[];
    unawaited(
      (() async {
        await for (final request in server) {
          paths.add('${request.method} ${request.uri.path}');
          final body = await utf8.decodeStream(request);
          if (body.trim().isNotEmpty) bodies.add(jsonDecode(body));
          request.response.headers.contentType = ContentType.json;
          if (request.method == 'GET') {
            request.response.write(
              jsonEncode({
                'items': [
                  {
                    'id': 'cand_1',
                    'kind': 'project_rule',
                    'scope': 'repo',
                    'text': 'Use curl for service checks.',
                    'confidence': 0.82,
                    'reason': 'Durable project rule.',
                    'status': 'pending',
                    'createdAt': 1,
                  },
                ],
              }),
            );
          } else if (request.uri.path.endsWith('/approve')) {
            request.response.write(
              jsonEncode({
                'id': 'mem_1',
                'kind': 'project_rule',
                'scope': 'repo',
                'text': 'Use curl for service checks.',
                'status': 'active',
                'createdAt': 2,
                'updatedAt': 2,
              }),
            );
          } else {
            request.response.write(
              jsonEncode({
                'id': 'cand_1',
                'kind': 'project_rule',
                'scope': 'repo',
                'text': 'Use curl for service checks.',
                'status': 'rejected',
                'createdAt': 1,
                'reviewedAt': 3,
              }),
            );
          }
          await request.response.close();
          if (paths.length == 3) break;
        }
      })(),
    );

    final client = MemoryApiClient(
      baseUrl: Uri.parse('http://127.0.0.1:${server.port}'),
      token: 'secret-token',
    );
    addTearDown(client.close);

    final candidates = await client.listCandidates(
      userId: 'local-user',
      repoId: 'repo-1',
      status: 'pending',
    );
    final approved = await client.approveCandidate(candidates.single);
    final rejected = await client.rejectCandidate('cand_1');

    expect(candidates.single.id, 'cand_1');
    expect(approved.id, 'mem_1');
    expect(rejected.status, 'rejected');
    expect(paths, [
      'GET /v1/memory/candidates',
      'POST /v1/memory/candidates/cand_1/approve',
      'POST /v1/memory/candidates/cand_1/reject',
    ]);
    expect((bodies.first as Map)['text'], 'Use curl for service checks.');
  });

  test('MemoryApiClient lists visible candidates with current scope', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);

    Uri? requestedUri;
    unawaited(
      (() async {
        await for (final request in server) {
          requestedUri = request.uri;
          request.response.write(jsonEncode({'items': []}));
          await request.response.close();
          break;
        }
      })(),
    );

    final client = MemoryApiClient(
      baseUrl: Uri.parse('http://127.0.0.1:${server.port}'),
      token: 'secret-token',
    );
    addTearDown(client.close);

    await client.listCandidates(
      visibleScope: const MemoryScopeData(
        userId: 'local-user',
        workspaceId: 'workspace-1',
        repoId: 'repo-1',
        agentId: 'agent-1',
        sessionId: 'session-1',
      ),
      status: 'pending',
    );

    expect(requestedUri?.path, '/v1/memory/candidates');
    expect(requestedUri?.queryParameters['visible'], 'true');
    expect(requestedUri?.queryParameters['userId'], 'local-user');
    expect(requestedUri?.queryParameters['workspaceId'], 'workspace-1');
    expect(requestedUri?.queryParameters['repoId'], 'repo-1');
    expect(requestedUri?.queryParameters['agentId'], 'agent-1');
    expect(requestedUri?.queryParameters['sessionId'], 'session-1');
    expect(requestedUri?.queryParameters['status'], 'pending');
  });

  test('MemoryApiClient lists and reviews change requests', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);

    final paths = <String>[];
    final bodies = <Object?>[];
    unawaited(
      (() async {
        await for (final request in server) {
          paths.add('${request.method} ${request.uri.path}');
          expect(
            request.headers.value(HttpHeaders.authorizationHeader),
            'Bearer secret-token',
          );
          final body = await utf8.decodeStream(request);
          if (body.trim().isNotEmpty) {
            bodies.add(jsonDecode(body));
          }
          request.response.headers.contentType = ContentType.json;
          if (request.method == 'GET') {
            request.response.write(
              jsonEncode({
                'items': [
                  {
                    'id': 'cr_1',
                    'action': 'update',
                    'source': 'maintenance',
                    'targetMemoryIds': ['mem_1'],
                    'targetMemoryText': 'The user goes by Rod.',
                    'proposedKind': 'user_preference',
                    'proposedScope': 'global',
                    'proposedText': 'The user goes by Rodriguez.',
                    'reason': 'Clarify preferred name.',
                    'confidence': 0.82,
                    'status': 'pending',
                    'createdAt': 1,
                  },
                ],
              }),
            );
          } else if (request.uri.path.endsWith('/approve')) {
            request.response.write(
              jsonEncode({
                'id': 'cr_1',
                'action': 'update',
                'source': 'maintenance',
                'targetMemoryIds': ['mem_1'],
                'proposedText': 'Call the user Rodriguez.',
                'status': 'approved',
                'createdAt': 1,
                'reviewedAt': 2,
              }),
            );
          } else {
            request.response.write(
              jsonEncode({
                'id': 'cr_1',
                'action': 'update',
                'source': 'maintenance',
                'targetMemoryIds': ['mem_1'],
                'status': 'rejected',
                'createdAt': 1,
                'reviewedAt': 3,
              }),
            );
          }
          await request.response.close();
          if (paths.length == 3) break;
        }
      })(),
    );

    final client = MemoryApiClient(
      baseUrl: Uri.parse('http://127.0.0.1:${server.port}'),
      token: 'secret-token',
    );
    addTearDown(client.close);

    final requests = await client.listChangeRequests(
      userId: 'local-user',
      repoId: 'repo-1',
      status: 'pending',
    );
    expect(requests.single.id, 'cr_1');
    expect(requests.single.targetMemoryText, 'The user goes by Rod.');

    final approved = await client.approveChangeRequest(
      requests.single.copyWith(proposedText: 'Call the user Rodriguez.'),
    );
    final rejected = await client.rejectChangeRequest('cr_1');

    expect(approved.status, 'approved');
    expect(rejected.status, 'rejected');
    expect(paths, [
      'GET /v1/memory/change-requests',
      'POST /v1/memory/change-requests/cr_1/approve',
      'POST /v1/memory/change-requests/cr_1/reject',
    ]);
    expect((bodies.first as Map)['proposedText'], 'Call the user Rodriguez.');
  });

  test(
    'MemoryApiClient lists visible change requests with current scope',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);

      Uri? requestedUri;
      unawaited(
        (() async {
          await for (final request in server) {
            requestedUri = request.uri;
            request.response.write(jsonEncode({'items': []}));
            await request.response.close();
            break;
          }
        })(),
      );

      final client = MemoryApiClient(
        baseUrl: Uri.parse('http://127.0.0.1:${server.port}'),
        token: 'secret-token',
      );
      addTearDown(client.close);

      await client.listChangeRequests(
        visibleScope: const MemoryScopeData(
          userId: 'local-user',
          workspaceId: 'workspace-1',
          repoId: 'repo-1',
          agentId: 'agent-1',
          sessionId: 'session-1',
        ),
        status: 'pending',
      );

      expect(requestedUri?.path, '/v1/memory/change-requests');
      expect(requestedUri?.queryParameters['visible'], 'true');
      expect(requestedUri?.queryParameters['userId'], 'local-user');
      expect(requestedUri?.queryParameters['workspaceId'], 'workspace-1');
      expect(requestedUri?.queryParameters['repoId'], 'repo-1');
      expect(requestedUri?.queryParameters['agentId'], 'agent-1');
      expect(requestedUri?.queryParameters['sessionId'], 'session-1');
      expect(requestedUri?.queryParameters['status'], 'pending');
    },
  );

  test('MemoryApiClient lists active memory records', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);

    final received = <String, Object?>{};
    unawaited(
      server.first.then((request) async {
        received['path'] = request.uri.path;
        received['query'] = request.uri.queryParameters;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'items': [
              {
                'id': 'mem_1',
                'kind': 'user_preference',
                'scope': 'global',
                'text': 'The user goes by Rodriguez.',
                'status': 'active',
                'createdAt': 1,
                'updatedAt': 2,
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

    final records = await client.listMemory(
      userId: 'local-user',
      repoId: 'repo-1',
      status: 'active',
    );

    expect(received['path'], '/v1/memory');
    expect(received['query'], {
      'userId': 'local-user',
      'repoId': 'repo-1',
      'status': 'active',
    });
    expect(records.single.id, 'mem_1');
    expect(records.single.text, 'The user goes by Rodriguez.');
  });

  test('MemoryApiClient lists visible active and disabled memory', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);

    final queries = <Map<String, String>>[];
    var requestCount = 0;
    unawaited(
      (() async {
        await for (final request in server) {
          queries.add(Map<String, String>.from(request.uri.queryParameters));
          request.response.headers.contentType = ContentType.json;
          final status = request.uri.queryParameters['status'];
          request.response.write(
            jsonEncode({
              'items': [
                {
                  'id': 'mem_$status',
                  'kind': 'project_rule',
                  'scope': 'repo',
                  'text': 'A $status memory.',
                  'status': status,
                  'createdAt': 1,
                  'updatedAt': status == 'active' ? 3 : 2,
                },
              ],
            }),
          );
          await request.response.close();
          requestCount += 1;
          if (requestCount == 2) break;
        }
      })(),
    );

    final client = MemoryApiClient(
      baseUrl: Uri.parse('http://127.0.0.1:${server.port}'),
      token: 'secret-token',
    );
    addTearDown(client.close);

    final records = await client.listVisibleMemory(
      scope: const MemoryScopeData(
        userId: 'local-user',
        workspaceId: 'workspace-1',
        repoId: 'repo-1',
        agentId: 'agent-1',
        sessionId: 'session-1',
      ),
    );

    expect(queries, [
      {
        'visible': 'true',
        'userId': 'local-user',
        'workspaceId': 'workspace-1',
        'repoId': 'repo-1',
        'agentId': 'agent-1',
        'sessionId': 'session-1',
        'status': 'active',
      },
      {
        'visible': 'true',
        'userId': 'local-user',
        'workspaceId': 'workspace-1',
        'repoId': 'repo-1',
        'agentId': 'agent-1',
        'sessionId': 'session-1',
        'status': 'disabled',
      },
    ]);
    expect(records.map((record) => record.id), ['mem_active', 'mem_disabled']);
  });

  test('MemoryRecord maintenance item keeps status for cleanup extraction', () {
    const record = MemoryRecord(
      id: 'mem_disabled',
      kind: 'project_rule',
      scope: 'repo',
      text: 'Use curl for local health checks.',
      status: 'disabled',
      createdAt: 1,
      updatedAt: 2,
    );

    expect(
      record.toMaintenanceItem().toJson(),
      containsPair('status', 'disabled'),
    );
  });

  test('MemoryApiClient updates and deletes memory records', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);

    final paths = <String>[];
    final bodies = <Object?>[];
    unawaited(
      (() async {
        await for (final request in server) {
          paths.add('${request.method} ${request.uri.path}');
          expect(
            request.headers.value(HttpHeaders.authorizationHeader),
            'Bearer secret-token',
          );
          final body = await utf8.decodeStream(request);
          if (body.trim().isNotEmpty) {
            bodies.add(jsonDecode(body));
          }
          request.response.headers.contentType = ContentType.json;
          if (request.method == 'PATCH') {
            request.response.write(
              jsonEncode({
                'id': 'mem_1',
                'kind': 'user_preference',
                'scope': 'global',
                'text': 'The user goes by Rodriguez.',
                'status': 'active',
                'createdAt': 1,
                'updatedAt': 3,
              }),
            );
          } else {
            request.response.write(jsonEncode({'ok': true}));
          }
          await request.response.close();
          if (paths.length == 2) break;
        }
      })(),
    );

    final client = MemoryApiClient(
      baseUrl: Uri.parse('http://127.0.0.1:${server.port}'),
      token: 'secret-token',
    );
    addTearDown(client.close);

    final updated = await client.updateMemory(
      const MemoryRecord(
        id: 'mem_1',
        kind: 'user_preference',
        scope: 'global',
        text: 'The user goes by Rodriguez.',
        status: 'active',
        createdAt: 1,
        updatedAt: 2,
      ),
    );
    await client.deleteMemory('mem_1');

    expect(updated.updatedAt, 3);
    expect(paths, ['PATCH /v1/memory/mem_1', 'DELETE /v1/memory/mem_1']);
    expect((bodies.single as Map), {
      'kind': 'user_preference',
      'scope': 'global',
      'text': 'The user goes by Rodriguez.',
      'status': 'active',
    });
  });

  test('MemoryApiClient lists audit log entries', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);

    final received = <String, Object?>{};
    unawaited(
      server.first.then((request) async {
        received['path'] = request.uri.path;
        received['query'] = request.uri.queryParameters;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'items': [
              {
                'id': 'audit_1',
                'actor': 'system',
                'action': 'memory.search',
                'memoryId': 'mem_1',
                'payload': {
                  'resultCount': 1,
                  'memoryIds': ['mem_1'],
                },
                'createdAt': 3,
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

    final entries = await client.listAudit(limit: 20);

    expect(received['path'], '/v1/memory/audit');
    expect(received['query'], {'limit': '20'});
    expect(entries.single.action, 'memory.search');
    expect(entries.single.memoryId, 'mem_1');
    expect(entries.single.payload['resultCount'], 1);
  });

  test('MemoryApiClient lists visible audit log with current scope', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);

    Uri? requestedUri;
    unawaited(
      (() async {
        await for (final request in server) {
          requestedUri = request.uri;
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({'items': []}));
          await request.response.close();
          break;
        }
      })(),
    );

    final client = MemoryApiClient(
      baseUrl: Uri.parse('http://127.0.0.1:${server.port}'),
      token: 'secret-token',
    );
    addTearDown(client.close);

    await client.listAudit(
      limit: 20,
      visibleScope: const MemoryScopeData(
        userId: 'local-user',
        workspaceId: 'workspace-1',
        repoId: 'repo-1',
        agentId: 'agent-1',
        sessionId: 'session-1',
      ),
    );

    expect(requestedUri?.path, '/v1/memory/audit');
    expect(requestedUri?.queryParameters['visible'], 'true');
    expect(requestedUri?.queryParameters['userId'], 'local-user');
    expect(requestedUri?.queryParameters['workspaceId'], 'workspace-1');
    expect(requestedUri?.queryParameters['repoId'], 'repo-1');
    expect(requestedUri?.queryParameters['agentId'], 'agent-1');
    expect(requestedUri?.queryParameters['sessionId'], 'session-1');
    expect(requestedUri?.queryParameters['limit'], '20');
  });

  test(
    'MemoryApiClient runs memory maintenance with scope and thresholds',
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
          received['body'] = jsonDecode(await utf8.decodeStream(request));
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'autoApplied': 0,
              'needsReview': 1,
              'skipped': 2,
              'changeRequests': [
                {
                  'id': 'cr_merge',
                  'action': 'merge',
                  'source': 'maintenance',
                  'targetMemoryIds': ['mem_1', 'mem_2'],
                  'proposedText': 'The user goes by Rodriguez.',
                  'confidence': 0.82,
                  'status': 'pending',
                  'createdAt': 1,
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

      final result = await client.runMaintenance(
        scope: const MemoryScopeData(
          userId: 'local-user',
          workspaceId: 'workspace-1',
          repoId: 'repo-1',
          agentId: 'agent-1',
          sessionId: 'session-1',
        ),
        mode: 'manual_review',
        highConfidenceThreshold: 0.9,
        reviewThreshold: 0.75,
        maxItemsPerBatch: 12,
        preExtractedChangeRequests: const [
          MaintenanceChangeRequestSuggestion(
            action: 'merge',
            targetMemoryIds: ['mem_1', 'mem_2'],
            proposedText: 'The user goes by Rodriguez.',
            confidence: 0.93,
            reason: 'Duplicate preferred name memories.',
          ),
        ],
      );

      expect(received['path'], '/v1/memory/maintenance/run');
      expect(received['authorization'], 'Bearer secret-token');
      final body = received['body'] as Map;
      expect(body['scope'], containsPair('repoId', 'repo-1'));
      expect(body['scope'], containsPair('sessionId', 'session-1'));
      expect(body['mode'], 'manual_review');
      expect(body['highConfidenceThreshold'], 0.9);
      expect(
        (body['preExtractedChangeRequests'] as List).single,
        containsPair('action', 'merge'),
      );
      expect(result.autoApplied, 0);
      expect(result.needsReview, 1);
      expect(result.skipped, 2);
      expect(result.changeRequests.single.action, 'merge');
    },
  );

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
