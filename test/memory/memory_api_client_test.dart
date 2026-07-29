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
      pinnedProfileLimit: 2,
      turnId: 'turn-1',
      referenceTime: 2500,
    );
    expect(request.toJson()['scope'], {
      'userId': 'local-user',
      'workspaceId': 'workspace-1',
      'repoId': 'repo-1',
      'agentId': 'agent-1',
      'sessionId': 'session-1',
    });
    expect(request.toJson()['turnId'], 'turn-1');
    expect(request.toJson()['referenceTime'], 2500);
    expect(request.toJson()['pinnedProfileLimit'], 2);
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
                  'metadata': {
                    'diagnostics': {'lexicalScore': 1.0, 'feedbackScore': 0.65},
                  },
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
      expect(context, contains('<retrieved_memory>'));
      expect(
        context,
        contains('[project_rule/repo] Use curl for local service checks.'),
      );
    },
  );

  test('MemorySearchItem exposes retrieval metadata diagnostics', () {
    final item = MemorySearchItem.fromJson({
      'id': 'mem_1',
      'kind': 'project_rule',
      'scope': 'repo',
      'text': 'Use curl for local checks.',
      'score': 0.91,
      'metadata': {
        'diagnostics': {'lexicalScore': 1.0, 'feedbackScore': 0.65},
      },
    });

    expect(item.metadata?['diagnostics'], isA<Map>());
    expect((item.metadata!['diagnostics'] as Map)['feedbackScore'], 0.65);
  });

  test('MemoryCandidate parses instruction scope matches', () {
    final candidate = MemoryCandidate.fromJson({
      'id': 'cand_1',
      'kind': 'project_rule',
      'scope': 'repo',
      'text': 'Never use nc/netcat.',
      'confidence': 0.91,
      'reason': 'Matches repo memory policy.',
      'source': 'extractor',
      'instructionScopes': ['repo', 'workspace'],
      'status': 'pending',
    });

    expect(candidate.source, 'extractor');
    expect(candidate.instructionScopes, ['repo', 'workspace']);
  });

  test('MemoryApiClient posts memory feedback', () async {
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
        request.response.write(jsonEncode({'ok': true}));
        await request.response.close();
      }),
    );

    final client = MemoryApiClient(
      baseUrl: Uri.parse('http://127.0.0.1:${server.port}'),
      token: 'secret-token',
    );
    addTearDown(client.close);

    await client.submitFeedback(
      memoryId: 'mem_1',
      rating: 'not_relevant',
      turnId: 'turn-feedback',
      reason: 'Wrong memory for this turn.',
    );

    expect(received['path'], '/v1/memory/mem_1/feedback');
    expect(received['authorization'], 'Bearer secret-token');
    expect(received['body'], {
      'rating': 'not_relevant',
      'turnId': 'turn-feedback',
      'reason': 'Wrong memory for this turn.',
    });
  });

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
          jsonEncode({'candidates': [], 'autoAppliedChangeRequests': 2}),
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
      sourceTurnId: 'turn-extract-1',
      candidates: const [
        ExtractedMemoryCandidate(
          kind: 'project_rule',
          scope: 'repo',
          text: 'Never use nc/netcat.',
          confidence: 0.9,
          instructionScopes: ['repo'],
          entities: [
            ExtractedMemoryEntity(text: 'netcat', type: 'tool'),
            ExtractedMemoryEntity(text: 'repo-rule', type: 'tag'),
          ],
        ),
      ],
    );

    expect(received['path'], '/v1/memory/extract-candidates');
    expect(received['authorization'], 'Bearer secret-token');
    final body = received['body'] as Map;
    expect(body['scope'], containsPair('sessionId', 'session-1'));
    expect(body['sourceTurnId'], 'turn-extract-1');
    expect(body['preExtractedCandidates'], isA<List>());
    final candidate = (body['preExtractedCandidates'] as List).single as Map;
    expect(candidate['instructionScopes'], ['repo']);
    expect(candidate['entities'], [
      {'text': 'netcat', 'type': 'tool'},
      {'text': 'repo-rule', 'type': 'tag'},
    ]);
    expect(result.candidates, isEmpty);
    expect(result.autoAppliedChangeRequests, 2);
  });

  test(
    'MemoryApiClient lists memory with scope filters and pagination',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);

      Uri? receivedUri;
      unawaited(
        server.first.then((request) async {
          receivedUri = request.uri;
          expect(
            request.headers.value(HttpHeaders.authorizationHeader),
            'Bearer secret-token',
          );
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'items': [
                {
                  'id': 'mem_1',
                  'kind': 'project_rule',
                  'scope': 'repo',
                  'text': 'Use curl for local service checks.',
                  'pinned': true,
                  'profileBlock': {
                    'label': 'project_profile',
                    'description':
                        'Stable project rules and architecture decisions.',
                    'limit': 4,
                  },
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
        workspaceId: 'workspace-1',
        repoId: 'repo-1',
        agentId: 'agent-1',
        sessionId: 'session-1',
        kind: 'project_rule',
        status: 'active',
        limit: 20,
        offset: 5,
      );

      expect(
        receivedUri.toString(),
        '/v1/memory?userId=local-user&workspaceId=workspace-1&repoId=repo-1&agentId=agent-1&sessionId=session-1&kind=project_rule&status=active&limit=20&offset=5',
      );
      expect(records.single.text, 'Use curl for local service checks.');
      expect(records.single.pinned, isTrue);
      expect(records.single.profileBlock?['label'], 'project_profile');
    },
  );

  test('MemoryApiClient lists and reviews pending candidates', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);

    final paths = <String>[];
    final subscription = server.listen((request) async {
      paths.add(request.uri.toString());
      expect(
        request.headers.value(HttpHeaders.authorizationHeader),
        'Bearer secret-token',
      );
      request.response.headers.contentType = ContentType.json;
      if (request.method == 'GET') {
        request.response.write(
          jsonEncode({
            'candidates': [
              {
                'id': 'cand_1',
                'kind': 'project_rule',
                'scope': 'repo',
                'text': 'The passphrase is blue lighthouse.',
                'confidence': 0.93,
                'reason': 'User explicitly asked to remember it.',
                'status': 'pending',
              },
            ],
          }),
        );
      } else if (request.uri.path.endsWith('/approve')) {
        final body = jsonDecode(await utf8.decodeStream(request)) as Map;
        expect(body['kind'], 'project_rule');
        expect(body['scope'], 'repo');
        expect(body['text'], 'The passphrase is blue lighthouse.');
        request.response.write(
          jsonEncode({
            'id': 'mem_1',
            'kind': 'project_rule',
            'scope': 'repo',
            'text': body['text'],
            'userId': 'local-user',
            'source': 'manual',
            'status': 'active',
            'createdAt': 1,
            'updatedAt': 1,
          }),
        );
      } else {
        request.response.write(jsonEncode({'ok': true}));
      }
      await request.response.close();
    });
    addTearDown(subscription.cancel);

    final client = MemoryApiClient(
      baseUrl: Uri.parse('http://127.0.0.1:${server.port}'),
      token: 'secret-token',
    );
    addTearDown(client.close);

    final candidates = await client.listCandidates(
      userId: 'local-user',
      workspaceId: 'workspace-1',
      repoId: 'repo-1',
      agentId: 'agent-1',
      sessionId: 'session-1',
      status: 'pending',
      limit: 10,
    );
    await client.approveCandidate(candidates.single);
    await client.rejectCandidate('cand_2');

    expect(candidates.single.id, 'cand_1');
    expect(paths, [
      '/v1/memory/candidates?userId=local-user&workspaceId=workspace-1&repoId=repo-1&agentId=agent-1&sessionId=session-1&status=pending&limit=10',
      '/v1/memory/candidates/cand_1/approve',
      '/v1/memory/candidates/cand_2/reject',
    ]);
  });

  test('MemoryApiClient can list all candidate statuses', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);

    Uri? receivedUri;
    unawaited(
      server.first.then((request) async {
        receivedUri = request.uri;
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

    final candidates = await client.listCandidates(
      userId: 'local-user',
      workspaceId: 'workspace-1',
      repoId: 'repo-1',
      status: null,
    );

    expect(candidates, isEmpty);
    expect(receivedUri?.path, '/v1/memory/candidates');
    expect(receivedUri?.queryParameters, {
      'userId': 'local-user',
      'workspaceId': 'workspace-1',
      'repoId': 'repo-1',
    });
  });

  test('MemoryApiClient tags automatic candidate approval actor', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);

    Map? receivedBody;
    unawaited(
      server.first.then((request) async {
        receivedBody = jsonDecode(await utf8.decodeStream(request)) as Map;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'id': 'mem_1',
            'kind': 'user_preference',
            'scope': 'global',
            'text': receivedBody?['text'],
            'userId': 'local-user',
            'source': 'extractor',
            'status': 'active',
            'createdAt': 1,
            'updatedAt': 1,
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

    await client.approveCandidate(
      const MemoryCandidate(
        id: 'cand_1',
        kind: 'user_preference',
        scope: 'global',
        text: 'The user goes by Rodriguez.',
        status: 'pending',
      ),
      actor: 'extractor',
    );

    expect(receivedBody, {
      'kind': 'user_preference',
      'scope': 'global',
      'text': 'The user goes by Rodriguez.',
      'actor': 'extractor',
    });
  });

  test('MemoryApiClient lists audit events', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);

    Uri? receivedUri;
    unawaited(
      server.first.then((request) async {
        receivedUri = request.uri;
        expect(
          request.headers.value(HttpHeaders.authorizationHeader),
          'Bearer secret-token',
        );
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'items': [
              {
                'id': 'audit_1',
                'actor': 'system',
                'action': 'memory.retrieve',
                'memoryId': 'mem_1',
                'memoryText': 'The user goes by Rodriguez.',
                'payload': {'score': 0.9},
                'createdAt': 42,
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

    final events = await client.listAudit(
      userId: 'local-user',
      workspaceId: 'workspace-1',
      repoId: 'repo-1',
      agentId: 'agent-1',
      sessionId: 'session-1',
    );

    expect(
      receivedUri.toString(),
      '/v1/memory/audit?userId=local-user&workspaceId=workspace-1&repoId=repo-1&agentId=agent-1&sessionId=session-1',
    );
    expect(events.single.action, 'memory.retrieve');
    expect(events.single.memoryText, 'The user goes by Rodriguez.');
    expect(events.single.payload?['score'], 0.9);
  });

  test('MemoryApiClient can list all change request statuses', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);

    Uri? receivedUri;
    unawaited(
      server.first.then((request) async {
        receivedUri = request.uri;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'items': []}));
        await request.response.close();
      }),
    );

    final client = MemoryApiClient(
      baseUrl: Uri.parse('http://127.0.0.1:${server.port}'),
      token: 'secret-token',
    );
    addTearDown(client.close);

    final requests = await client.listChangeRequests(
      userId: 'local-user',
      repoId: 'repo-1',
      status: null,
    );

    expect(requests, isEmpty);
    expect(receivedUri?.path, '/v1/memory/change-requests');
    expect(receivedUri?.queryParameters, {
      'userId': 'local-user',
      'repoId': 'repo-1',
    });
  });

  test(
    'MemoryApiClient lists, reviews change requests, runs maintenance, and clears memory',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);

      final paths = <String>[];
      final bodies = <Map>[];
      final subscription = server.listen((request) async {
        paths.add(request.uri.toString());
        expect(
          request.headers.value(HttpHeaders.authorizationHeader),
          'Bearer secret-token',
        );
        request.response.headers.contentType = ContentType.json;
        if (request.method != 'GET') {
          bodies.add(jsonDecode(await utf8.decodeStream(request)) as Map);
        }
        if (request.method == 'GET') {
          request.response.write(
            jsonEncode({
              'items': [
                {
                  'id': 'cr_1',
                  'action': 'merge',
                  'source': 'maintenance',
                  'targetMemoryIds': ['mem_1', 'mem_2'],
                  'targetMemoryText': 'The user goes by Rod.',
                  'proposedKind': 'user_preference',
                  'proposedScope': 'global',
                  'proposedText': 'The user goes by Rodriguez.',
                  'reason': 'Duplicate user name memories.',
                  'confidence': 0.93,
                  'status': 'pending',
                  'createdAt': 1,
                },
              ],
            }),
          );
        } else if (request.uri.path.endsWith('/maintenance/run')) {
          request.response.write(
            jsonEncode({
              'autoApplied': 2,
              'needsReview': 3,
              'skipped': 5,
              'existingAutoApprovedChangeRequests': 1,
              'autoRejectedCandidates': 4,
              'autoRejectedChangeRequests': 1,
              'changeRequests': [],
            }),
          );
        } else if (request.uri.path.endsWith('/clear')) {
          request.response.write(
            jsonEncode({
              'clearedMemory': 1,
              'rejectedCandidates': 2,
              'rejectedChangeRequests': 3,
            }),
          );
        } else if (request.method == 'PATCH') {
          request.response.write(
            jsonEncode({
              'id': 'cr_1',
              'action': 'merge',
              'source': 'maintenance',
              'targetMemoryIds': ['mem_1', 'mem_2'],
              'proposedKind': bodies.last['proposedKind'],
              'proposedScope': bodies.last['proposedScope'],
              'proposedText': bodies.last['proposedText'],
              'status': 'pending',
              'createdAt': 1,
            }),
          );
        } else if (request.uri.path.endsWith('/approve')) {
          request.response.write(
            jsonEncode({
              'id': 'cr_1',
              'action': 'merge',
              'source': 'maintenance',
              'targetMemoryIds': ['mem_1', 'mem_2'],
              'proposedText': bodies.last['proposedText'],
              'status': 'approved',
              'createdAt': 1,
              'reviewedAt': 2,
            }),
          );
        } else {
          request.response.write(
            jsonEncode({
              'id': 'cr_2',
              'action': 'disable',
              'targetMemoryIds': ['mem_3'],
              'status': 'rejected',
              'createdAt': 1,
              'reviewedAt': 2,
            }),
          );
        }
        await request.response.close();
      });
      addTearDown(subscription.cancel);

      final client = MemoryApiClient(
        baseUrl: Uri.parse('http://127.0.0.1:${server.port}'),
        token: 'secret-token',
      );
      addTearDown(client.close);

      final requests = await client.listChangeRequests(
        userId: 'local-user',
        workspaceId: 'workspace-1',
        repoId: 'repo-1',
        agentId: 'agent-1',
        sessionId: 'session-1',
      );
      final updated = await client.updateChangeRequest(
        requests.single.copyWith(proposedText: 'Call the user Rodriguez.'),
      );
      final approved = await client.approveChangeRequest(updated);
      await client.rejectChangeRequest('cr_2');
      final result = await client.runMaintenance(
        scope: const MemoryScopeData(
          userId: 'local-user',
          workspaceId: 'workspace-1',
          repoId: 'repo-1',
        ),
        enabled: true,
        mode: 'manual_review',
        costMode: 'low_cost',
        highConfidenceThreshold: 0.9,
        reviewThreshold: 0.75,
        maxItemsPerBatch: 12,
        manualOnlyActions: const ['delete', 'expire'],
      );
      final clear = await client.clearMemory(
        scope: const MemoryScopeData(
          userId: 'local-user',
          workspaceId: 'workspace-1',
          repoId: 'repo-1',
        ),
        level: 'repo',
      );

      expect(requests.single.targetMemoryIds, ['mem_1', 'mem_2']);
      expect(requests.single.source, 'maintenance');
      expect(requests.single.confidence, 0.93);
      expect(updated.proposedText, 'Call the user Rodriguez.');
      expect(approved.status, 'approved');
      expect(result.autoApplied, 2);
      expect(result.needsReview, 3);
      expect(result.existingAutoApprovedChangeRequests, 1);
      expect(result.autoRejectedCandidates, 4);
      expect(result.autoRejectedChangeRequests, 1);
      expect(result.autoCleaned, 5);
      expect(clear.clearedMemory, 1);
      expect(clear.rejectedChangeRequests, 3);
      expect(paths, [
        '/v1/memory/change-requests?userId=local-user&workspaceId=workspace-1&repoId=repo-1&agentId=agent-1&sessionId=session-1&status=pending',
        '/v1/memory/change-requests/cr_1',
        '/v1/memory/change-requests/cr_1/approve',
        '/v1/memory/change-requests/cr_2/reject',
        '/v1/memory/maintenance/run',
        '/v1/memory/clear',
      ]);
      expect(bodies.first['proposedText'], 'Call the user Rodriguez.');
      expect(bodies[3]['enabled'], true);
      expect(bodies[3]['mode'], 'manual_review');
      expect(bodies[3]['costMode'], 'low_cost');
      expect(bodies[3]['maxItemsPerBatch'], 12);
      expect(bodies[3]['manualOnlyActions'], ['delete', 'expire']);
      expect(bodies.last['level'], 'repo');
    },
  );

  test(
    'MemoryApiClient updates, disables, and restores existing memory records',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);

      final paths = <String>[];
      final bodies = <Map>[];
      final subscription = server.listen((request) async {
        paths.add(request.uri.toString());
        expect(
          request.headers.value(HttpHeaders.authorizationHeader),
          'Bearer secret-token',
        );
        request.response.headers.contentType = ContentType.json;
        bodies.add(jsonDecode(await utf8.decodeStream(request)) as Map);
        if (bodies.last['status'] == 'disabled') {
          request.response.write(
            jsonEncode({
              'id': 'mem_1',
              'kind': 'project_rule',
              'scope': 'repo',
              'text': 'The verification phrase is blue lighthouse.',
              'userId': 'local-user',
              'source': 'extractor',
              'status': 'disabled',
              'createdAt': 1,
              'updatedAt': 3,
            }),
          );
        } else {
          request.response.write(
            jsonEncode({
              'id': 'mem_1',
              'kind': bodies.last['kind'],
              'scope': bodies.last['scope'],
              'text': bodies.last['text'],
              'userId': 'local-user',
              'source': 'extractor',
              'status': 'active',
              'createdAt': 1,
              'updatedAt': 2,
            }),
          );
        }
        await request.response.close();
      });
      addTearDown(subscription.cancel);

      final client = MemoryApiClient(
        baseUrl: Uri.parse('http://127.0.0.1:${server.port}'),
        token: 'secret-token',
      );
      addTearDown(client.close);

      final edited = await client.updateMemory(
        const MemoryRecord(
          id: 'mem_1',
          kind: 'project_rule',
          scope: 'repo',
          text: 'The verification phrase is blue lighthouse.',
          userId: 'local-user',
          source: 'extractor',
          status: 'active',
          createdAt: 1,
          updatedAt: 1,
        ),
      );
      final disabled = await client.disableMemory('mem_1');
      final restored = await client.restoreMemory('mem_1');

      expect(edited.text, 'The verification phrase is blue lighthouse.');
      expect(disabled.status, 'disabled');
      expect(restored.status, 'active');
      expect(paths, [
        '/v1/memory/mem_1',
        '/v1/memory/mem_1',
        '/v1/memory/mem_1',
      ]);
      expect(bodies[0], {
        'kind': 'project_rule',
        'scope': 'repo',
        'text': 'The verification phrase is blue lighthouse.',
      });
      expect(bodies[1], {'status': 'disabled'});
      expect(bodies[2], {'status': 'active'});
    },
  );

  test('MemoryApiClient exports and imports JSONL backups', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);

    final paths = <String>[];
    final bodies = <Map>[];
    final subscription = server.listen((request) async {
      paths.add(request.uri.path);
      expect(
        request.headers.value(HttpHeaders.authorizationHeader),
        'Bearer secret-token',
      );
      final body = jsonDecode(await utf8.decodeStream(request)) as Map;
      bodies.add(body);
      request.response.headers.contentType = ContentType.json;
      if (request.uri.path.endsWith('/export')) {
        request.response.write(
          jsonEncode({
            'jsonl': '{"version":1,"type":"memory","kind":"project_rule"}\n',
            'exported': 1,
            'truncated': false,
          }),
        );
      } else {
        request.response.write(
          jsonEncode({
            'imported': 0,
            'pendingReview': 1,
            'skipped': 2,
            'errors': [
              {'line': 3, 'message': 'disabled history requires trusted mode'},
            ],
          }),
        );
      }
      await request.response.close();
    });
    addTearDown(subscription.cancel);

    final client = MemoryApiClient(
      baseUrl: Uri.parse('http://127.0.0.1:${server.port}'),
      token: 'secret-token',
    );
    addTearDown(client.close);
    final exported = await client.exportMemory(
      scope: const MemoryScopeData(
        userId: 'local-user',
        workspaceId: 'workspace-1',
        repoId: 'repo-1',
      ),
      memoryScope: 'repo',
      kind: 'project_rule',
      status: 'active',
      createdFrom: 1,
      createdUntil: 2,
    );
    final imported = await client.importMemory(
      jsonl: exported.jsonl,
      mode: 'pending_review',
    );

    expect(paths, ['/v1/memory/export', '/v1/memory/import']);
    expect(bodies.first, {
      'scopeData': {
        'userId': 'local-user',
        'workspaceId': 'workspace-1',
        'repoId': 'repo-1',
      },
      'memoryScope': 'repo',
      'kind': 'project_rule',
      'status': 'active',
      'createdFrom': 1,
      'createdUntil': 2,
    });
    expect(bodies.last['mode'], 'pending_review');
    expect(bodies.last['jsonl'], exported.jsonl);
    expect(exported.exported, 1);
    expect(exported.truncated, isFalse);
    expect(imported.imported, 0);
    expect(imported.pendingReview, 1);
    expect(imported.skipped, 2);
    expect(imported.errors.single.line, 3);
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
