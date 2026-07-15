import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_dart/mcp_dart.dart' as mcp;
import 'package:ianvs_acp/acp/acp_permission_request.dart';
import 'package:ianvs_acp/acp/acp_permission_reviewer.dart';
import 'package:ianvs_acp/acp/acp_session_settings.dart';
import 'package:ianvs_acp/acp/agent_event.dart';
import 'package:ianvs_acp/acp/agent_session.dart';
import 'package:ianvs_acp/acp/fake_agent_client.dart';
import 'package:ianvs_acp/acp/no_redirect_mcp_http_transport.dart';
import 'package:ianvs_acp/acp/prompt_attachment.dart';
import 'package:ianvs_acp/config/acp_client_config.dart';

void main() {
  test('no-redirect MCP transport validates its endpoint directly', () {
    expect(
      () => NoRedirectMcpHttpTransport(
        endpoint: Uri.parse('http://reviewer.example.com/mcp'),
      ),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => NoRedirectMcpHttpTransport(
        endpoint: Uri.parse('https://user:password@reviewer.example.com/mcp'),
      ),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => NoRedirectMcpHttpTransport(
        endpoint: Uri.parse('ftp://reviewer.example.com/mcp'),
      ),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => NoRedirectMcpHttpTransport(
        endpoint: Uri.parse('http://127.0.0.1:8080/mcp'),
      ),
      returnsNormally,
    );
  });

  test('no-redirect MCP transport bounds stalled session teardown', () async {
    final deleteStarted = Completer<void>();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final serverSubscription = server.listen((request) async {
      if (request.method == 'DELETE') {
        if (!deleteStarted.isCompleted) deleteStarted.complete();
        return;
      }
      await request.drain<void>();
      request.response
        ..statusCode = HttpStatus.accepted
        ..headers.set('Mcp-Session-Id', 'stalled-session');
      await request.response.close();
    });
    final transport = NoRedirectMcpHttpTransport(
      endpoint: Uri.parse('http://127.0.0.1:${server.port}/mcp'),
      teardownTimeout: const Duration(milliseconds: 50),
    );

    try {
      await transport.start();
      await transport.send(
        const mcp.JsonRpcNotification(method: 'test/session'),
      );
      final stopwatch = Stopwatch()..start();
      final closing = transport.close();
      await deleteStarted.future;
      await closing.timeout(const Duration(milliseconds: 500));

      expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 500)));
    } finally {
      await transport.close();
      await serverSubscription.cancel();
      await server.close(force: true);
    }
  });

  test('MCP reviewer timeout closes an in-flight initialization', () async {
    final initializeStarted = Completer<void>();
    final clientDisconnected = Completer<void>();
    final sockets = <Socket>[];
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final serverSubscription = server.listen((socket) {
      sockets.add(socket);
      socket.listen(
        (_) {
          if (!initializeStarted.isCompleted) initializeStarted.complete();
          // Deliberately never send an initialize response.
        },
        onError: (Object _, StackTrace _) {
          if (!clientDisconnected.isCompleted) {
            clientDisconnected.complete();
          }
        },
        onDone: () {
          if (!clientDisconnected.isCompleted) {
            clientDisconnected.complete();
          }
        },
      );
    });
    final reviewer = _localMcpReviewer(
      server.port,
      timeout: const Duration(milliseconds: 500),
    );

    try {
      final reviewing = reviewer.review(
        _reviewRequest('stalled-initialize'),
        workspaceRoot: '/workspace',
      );
      await initializeStarted.future.timeout(const Duration(seconds: 2));

      final result = await reviewing.timeout(const Duration(seconds: 3));
      expect(result?.risk, 'unknown');
      await clientDisconnected.future.timeout(const Duration(seconds: 3));
    } finally {
      await reviewer.dispose();
      await serverSubscription.cancel();
      await server.close();
      for (final socket in sockets) {
        socket.destroy();
      }
    }
  });

  test(
    'MCP reviewer dispose cancels initialization and prevents reconnect',
    () async {
      final initializeStarted = Completer<void>();
      final clientDisconnected = Completer<void>();
      final sockets = <Socket>[];
      var acceptedConnections = 0;
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final serverSubscription = server.listen((socket) {
        acceptedConnections += 1;
        sockets.add(socket);
        socket.listen(
          (_) {
            if (!initializeStarted.isCompleted) initializeStarted.complete();
          },
          onError: (Object _, StackTrace _) {
            if (!clientDisconnected.isCompleted) {
              clientDisconnected.complete();
            }
          },
          onDone: () {
            if (!clientDisconnected.isCompleted) {
              clientDisconnected.complete();
            }
          },
        );
      });
      final reviewer = _localMcpReviewer(
        server.port,
        timeout: const Duration(seconds: 5),
      );

      try {
        final reviewing = reviewer.review(
          _reviewRequest('dispose-initialize'),
          workspaceRoot: '/workspace',
        );
        await initializeStarted.future.timeout(const Duration(seconds: 2));

        await Future.wait<void>([
          reviewer.dispose(),
          reviewer.dispose(),
        ]).timeout(const Duration(seconds: 2));
        await clientDisconnected.future.timeout(const Duration(seconds: 2));
        final interrupted = await reviewing.timeout(const Duration(seconds: 2));
        expect(interrupted?.risk, 'unknown');
        expect(acceptedConnections, 1);

        final afterDispose = await reviewer
            .review(
              _reviewRequest('after-dispose'),
              workspaceRoot: '/workspace',
            )
            .timeout(const Duration(seconds: 2));
        expect(afterDispose?.risk, 'unknown');
        await _pumpTestEventQueue();
        expect(acceptedConnections, 1);
      } finally {
        await reviewer.dispose();
        await serverSubscription.cancel();
        await server.close();
        for (final socket in sockets) {
          socket.destroy();
        }
      }
    },
  );

  test('concurrent MCP reviews share one initialization', () async {
    final initializeStarted = Completer<void>();
    final releaseInitialize = Completer<void>();
    var initializeCalls = 0;
    var toolCalls = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final serverSubscription = server.listen((request) async {
      if (request.method == 'GET') {
        request.response.statusCode = HttpStatus.methodNotAllowed;
        await request.response.close();
        return;
      }
      if (request.method == 'DELETE') {
        request.response.statusCode = HttpStatus.ok;
        await request.response.close();
        return;
      }
      final body = await utf8.decoder.bind(request).join();
      final message = jsonDecode(body) as Map<String, dynamic>;
      final method = message['method'];
      if (method == 'initialize') {
        initializeCalls += 1;
        if (!initializeStarted.isCompleted) initializeStarted.complete();
        await releaseInitialize.future;
        request.response
          ..headers.contentType = ContentType.json
          ..headers.set('Mcp-Session-Id', 'shared-review-session')
          ..write(jsonEncode(_mcpInitializeResponse(message['id'])));
      } else if (method == 'notifications/initialized') {
        request.response.statusCode = HttpStatus.accepted;
      } else if (method == 'tools/call') {
        toolCalls += 1;
        request.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(_mcpToolResponse(message['id'])));
      }
      await request.response.close();
    });
    final reviewer = _localMcpReviewer(server.port);

    try {
      final first = reviewer.review(
        _reviewRequest('concurrent-1'),
        workspaceRoot: '/workspace',
      );
      final second = reviewer.review(
        _reviewRequest('concurrent-2'),
        workspaceRoot: '/workspace',
      );
      await initializeStarted.future.timeout(const Duration(seconds: 2));
      await _pumpTestEventQueue();

      expect(initializeCalls, 1);
      releaseInitialize.complete();
      final results = await Future.wait(<Future<AcpPermissionReviewResult?>>[
        first,
        second,
      ]).timeout(const Duration(seconds: 3));

      expect(
        results.map((result) => result?.decision),
        everyElement(AcpPermissionDecision.allow),
      );
      expect(initializeCalls, 1);
      expect(toolCalls, 2);
    } finally {
      if (!releaseInitialize.isCompleted) releaseInitialize.complete();
      await reviewer.dispose();
      await serverSubscription.cancel();
      await server.close(force: true);
    }
  });

  test('permission review payload includes command context and model', () {
    final payload = acpPermissionReviewPayload(
      AcpPermissionRequest(
        id: 'permission-1',
        title: 'Create terminal',
        rationale: 'Requested by agent',
        sessionId: 'session-1',
        toolName: 'terminal',
        toolKind: 'execute',
        options: const ['Allow', 'Deny'],
        requestedAt: DateTime.utc(2026, 5, 31, 12),
        metadata: const <String, Object?>{
          'command': 'git',
          'args': ['status'],
          'cwd': '/workspace',
          'workspaceRoot': '/workspace',
        },
      ),
      workspaceRoot: '/fallback',
      model: 'review-model',
    );

    expect(payload['schema'], 'ianvs-acp.permission-review.v1');
    expect(payload['model'], 'review-model');
    expect(payload['workspace'], {'root': '/workspace'});
    final command = payload['command'] as Map<String, Object?>;
    expect(command['line'], 'git status');
    expect(command['cwd'], '/workspace');
    final analysis = payload['analysis'] as Map<String, Object?>;
    expect(analysis['risk'], 'low');
    expect(analysis['suggestedDecision'], 'allow');
    expect(analysis['cwdWithinWorkspace'], isTrue);
  });

  test('permission review payload flags risky commands outside workspace', () {
    final payload = acpPermissionReviewPayload(
      AcpPermissionRequest(
        id: 'permission-1',
        title: 'Create terminal',
        rationale: 'Requested by agent',
        sessionId: 'session-1',
        toolName: 'terminal',
        toolKind: 'execute',
        options: const ['Allow', 'Deny'],
        requestedAt: DateTime.utc(2026, 5, 31, 12),
        metadata: const <String, Object?>{
          'command': 'rm -rf /tmp/build',
          'cwd': '/tmp',
          'workspaceRoot': '/workspace',
        },
      ),
      workspaceRoot: '/workspace',
    );

    final analysis = payload['analysis'] as Map<String, Object?>;
    expect(analysis['risk'], 'high');
    expect(analysis['suggestedDecision'], 'deny');
    expect(analysis['cwdWithinWorkspace'], isFalse);
    expect(analysis['signals'], contains('cwd_outside_workspace'));
    expect(analysis['signals'], contains('high_risk_command_pattern'));
  });

  test(
    'permission review payload treats additional directories as workspace',
    () {
      final payload = acpPermissionReviewPayload(
        AcpPermissionRequest(
          id: 'permission-1',
          title: 'Create terminal',
          rationale: 'Requested by agent',
          sessionId: 'session-1',
          toolName: 'terminal',
          toolKind: 'execute',
          options: const ['Allow', 'Deny'],
          requestedAt: DateTime.utc(2026, 5, 31, 12),
          metadata: const <String, Object?>{
            'command': 'ls',
            'cwd': '/shared/project',
            'workspaceRoot': '/workspace',
          },
        ),
        workspaceRoot: '/workspace',
        additionalDirectories: const ['/shared'],
      );

      expect(payload['workspace'], {
        'root': '/workspace',
        'additionalDirectories': ['/shared'],
      });
      final analysis = payload['analysis'] as Map<String, Object?>;
      expect(analysis['risk'], 'low');
      expect(analysis['suggestedDecision'], 'allow');
      expect(analysis['cwdWithinWorkspace'], isTrue);
      expect(analysis['signals'], isNot(contains('cwd_outside_workspace')));
      expect(analysis['workspaceRoots'], ['/workspace', '/shared']);
    },
  );

  test(
    'permission review payload extracts command from nested tool call input',
    () {
      final payload = acpPermissionReviewPayload(
        AcpPermissionRequest(
          id: 'permission-1',
          title: 'Bash',
          rationale: 'Requested by agent',
          sessionId: 'session-1',
          toolName: 'Bash',
          toolKind: 'execute',
          options: const ['Allow', 'Deny'],
          requestedAt: DateTime.utc(2026, 5, 31, 12),
          metadata: const <String, Object?>{
            'toolCall': {
              'title': 'Bash',
              'kind': 'execute',
              'rawInput': {'cmd': 'ls', 'cwd': '/workspace'},
            },
          },
        ),
        workspaceRoot: '/workspace',
      );

      final command = payload['command'] as Map<String, Object?>;
      expect(command['line'], 'ls');
      expect(command['cwd'], '/workspace');
      final analysis = payload['analysis'] as Map<String, Object?>;
      expect(analysis['risk'], 'low');
      expect(analysis['suggestedDecision'], 'allow');
      expect(analysis['signals'], contains('low_risk_command_pattern'));
      expect(analysis['signals'], isNot(contains('missing_command_context')));
    },
  );

  test('permission review payload extracts command from JSON raw input', () {
    final payload = acpPermissionReviewPayload(
      AcpPermissionRequest(
        id: 'permission-1',
        title: 'exec_command',
        rationale: 'Requested by agent',
        sessionId: 'session-1',
        toolName: 'exec_command',
        toolKind: 'execute',
        options: const ['Allow', 'Deny'],
        requestedAt: DateTime.utc(2026, 5, 31, 12),
        metadata: const <String, Object?>{
          'toolCall': {
            'title': 'exec_command',
            'kind': 'execute',
            'raw_input': '{"command":"ls -la","cwd":"/workspace"}',
          },
        },
      ),
      workspaceRoot: '/workspace',
    );

    final command = payload['command'] as Map<String, Object?>;
    expect(command['line'], 'ls -la');
    expect(command['cwd'], '/workspace');
    final analysis = payload['analysis'] as Map<String, Object?>;
    expect(analysis['risk'], 'low');
    expect(analysis['suggestedDecision'], 'allow');
  });

  test('permission review payload extracts command from permission title', () {
    final payload = acpPermissionReviewPayload(
      AcpPermissionRequest(
        id: 'permission-1',
        title: 'Running: ls -la',
        rationale: 'Requested by agent',
        sessionId: 'session-1',
        toolName: 'Bash',
        toolKind: 'execute',
        options: const ['Allow', 'Deny'],
        requestedAt: DateTime.utc(2026, 5, 31, 12),
      ),
      workspaceRoot: '/workspace',
    );

    final command = payload['command'] as Map<String, Object?>;
    expect(command['line'], 'ls -la');
    expect(command['cwd'], '/workspace');
    final analysis = payload['analysis'] as Map<String, Object?>;
    expect(analysis['risk'], 'low');
    expect(analysis['suggestedDecision'], 'allow');
    expect(analysis['signals'], contains('low_risk_command_pattern'));
  });

  test(
    'agent permission reviewer uses sidecar agent and model override',
    () async {
      final fake = _ReviewFakeAgentClient(
        reviewText:
            '{"decision":"allow","risk":"low","rationale":"Read-only list command."}',
        sessionSettings: const AcpSessionSettings(
          configOptions: [
            AcpConfigOption(
              id: 'model',
              name: 'Model',
              type: 'select',
              currentValue: 'primary-model',
              options: [
                AcpConfigOptionChoice(value: 'primary-model', name: 'Primary'),
                AcpConfigOptionChoice(value: 'review-model', name: 'Review'),
              ],
            ),
          ],
        ),
      );
      final reviewer = AcpAgentPermissionReviewer(
        agentName: 'Kimi Code Dev',
        modelOverride: 'review-model',
        clientFactory: () => fake,
      );
      addTearDown(reviewer.dispose);
      expect(reviewer.canAutoApprove, isFalse);

      final result = await reviewer.review(
        AcpPermissionRequest(
          id: 'permission-1',
          title: 'Running: ls -la',
          rationale: 'Requested by agent',
          sessionId: 'session-1',
          toolName: 'Bash',
          toolKind: 'execute',
          options: const ['Allow', 'Deny'],
          requestedAt: DateTime.utc(2026, 5, 31, 12),
        ),
        workspaceRoot: '/workspace',
        additionalDirectories: const ['/shared'],
        model: 'primary-model',
      );

      expect(result?.decision, AcpPermissionDecision.allow);
      expect(result?.risk, 'low');
      expect(result?.reviewer, 'Kimi Code Dev');
      expect(result?.model, 'review-model');
      expect(fake.connected, isTrue);
      expect(fake.sessionCount, 1);
      expect(fake.lastCreateAdditionalDirectories, ['/shared']);
      expect(fake.lastConfigId, 'model');
      expect(fake.lastConfigValue, 'review-model');
      expect(fake.lastPrompt, contains('"model": "review-model"'));
      expect(fake.lastPrompt, contains('"additionalDirectories"'));
      expect(fake.lastPrompt, contains('"line": "ls -la"'));
    },
  );

  test('agent reviewer limits and cleanup timeouts must be positive', () {
    expect(
      () => AcpAgentPermissionReviewer(
        agentName: 'Sidecar',
        clientFactory: FakeAgentClient.new,
        timeout: Duration.zero,
      ),
      throwsArgumentError,
    );
    expect(
      () => AcpAgentPermissionReviewer(
        agentName: 'Sidecar',
        clientFactory: FakeAgentClient.new,
        cleanupTimeout: Duration.zero,
      ),
      throwsArgumentError,
    );
    expect(
      () => AcpAgentPermissionReviewer(
        agentName: 'Sidecar',
        clientFactory: FakeAgentClient.new,
        maxPendingReviews: 0,
      ),
      throwsArgumentError,
    );
  });

  test(
    'agent reviewer bounds pending work and restores capacity after drain',
    () async {
      final client = _QueueReviewAgentClient();
      var factoryCalls = 0;
      final reviewer = AcpAgentPermissionReviewer(
        agentName: 'Sidecar',
        maxPendingReviews: 2,
        clientFactory: () {
          factoryCalls += 1;
          return client;
        },
      );
      addTearDown(reviewer.dispose);

      final first = reviewer.review(
        _reviewRequest('capacity-running'),
        workspaceRoot: '/same-root',
      );
      await client.firstPromptStarted.future;
      final second = reviewer.review(
        _reviewRequest('capacity-queued'),
        workspaceRoot: '/same-root',
      );
      final overflow = await reviewer
          .review(
            _reviewRequest('capacity-overflow'),
            workspaceRoot: '/other-root',
          )
          .timeout(const Duration(milliseconds: 100));

      expect(overflow?.risk, 'unknown');
      expect(overflow?.details, containsPair('failure', 'capacity'));
      expect(factoryCalls, 1);
      expect(client.promptCalls, 1);

      client.releaseFirstPrompt();
      final accepted = await Future.wait(<Future<AcpPermissionReviewResult?>>[
        first,
        second,
      ]).timeout(const Duration(seconds: 2));
      expect(
        accepted.map((result) => result?.decision),
        everyElement(AcpPermissionDecision.allow),
      );

      final recovered = await reviewer.review(
        _reviewRequest('capacity-recovered'),
        workspaceRoot: '/same-root',
      );
      expect(recovered?.decision, AcpPermissionDecision.allow);
      expect(factoryCalls, 1);
      expect(client.promptCalls, 3);
    },
  );

  test(
    'pending capacity stays occupied until cleanup actually finishes',
    () async {
      final firstClient = _DelayedCleanupReviewAgentClient();
      final secondClient = _ReviewFakeAgentClient(
        reviewText: '{"decision":"allow","risk":"low","rationale":"Safe."}',
      );
      var factoryCalls = 0;
      final reviewer = AcpAgentPermissionReviewer(
        agentName: 'Sidecar',
        maxPendingReviews: 1,
        clientFactory: () {
          factoryCalls += 1;
          return factoryCalls == 1 ? firstClient : secondClient;
        },
      );
      addTearDown(reviewer.dispose);

      final first = reviewer.review(
        _reviewRequest('cleanup-running'),
        workspaceRoot: '/root-a',
      );
      await firstClient.promptStarted.future;
      final whilePromptBlocked = await reviewer.review(
        _reviewRequest('cleanup-limit-running'),
        workspaceRoot: '/root-b',
      );
      firstClient.failPrompt();
      final firstResult = await first;
      await firstClient.disposeStarted.future;
      final whileCleanupBlocked = await reviewer.review(
        _reviewRequest('cleanup-limit-disposing'),
        workspaceRoot: '/root-b',
      );

      expect(firstResult?.risk, 'unknown');
      expect(whilePromptBlocked?.details, containsPair('failure', 'capacity'));
      expect(whileCleanupBlocked?.details, containsPair('failure', 'capacity'));
      expect(factoryCalls, 1);

      firstClient.finishDispose();
      await firstClient.disposeFinished.future;
      await _pumpTestEventQueue();
      final recovered = await reviewer.review(
        _reviewRequest('cleanup-recovered'),
        workspaceRoot: '/root-b',
      );

      expect(recovered?.decision, AcpPermissionDecision.allow);
      expect(factoryCalls, 2);
    },
  );

  test(
    'dispose promptly settles queued reviews without late client creation',
    () async {
      final client = _NonCooperativeReviewAgentClient();
      var factoryCalls = 0;
      final reviewer = AcpAgentPermissionReviewer(
        agentName: 'Sidecar',
        timeout: const Duration(milliseconds: 200),
        cleanupTimeout: const Duration(milliseconds: 20),
        maxPendingReviews: 2,
        clientFactory: () {
          factoryCalls += 1;
          return client;
        },
      );

      final first = reviewer.review(
        _reviewRequest('dispose-running'),
        workspaceRoot: '/root-a',
      );
      await client.promptStarted.future;
      final queued = reviewer.review(
        _reviewRequest('dispose-queued'),
        workspaceRoot: '/root-b',
      );

      final disposing = reviewer.dispose();
      final queuedResult = await queued.timeout(
        const Duration(milliseconds: 100),
      );
      await disposing.timeout(const Duration(milliseconds: 150));
      final firstResult = await first.timeout(
        const Duration(milliseconds: 400),
      );
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(queuedResult?.risk, 'unknown');
      expect(firstResult?.risk, 'unknown');
      expect(factoryCalls, 1);
      expect(client.disposeCalls, 1);
    },
  );

  test(
    'concurrent agent reviews serialize different workspace bindings',
    () async {
      final clients = <_ReviewFakeAgentClient>[];
      final reviewer = AcpAgentPermissionReviewer(
        agentName: 'Sidecar',
        clientFactory: () {
          final client = _ReviewFakeAgentClient(
            reviewText: '{"decision":"allow","risk":"low","rationale":"Safe."}',
            connectDelay: const Duration(milliseconds: 20),
          );
          clients.add(client);
          return client;
        },
      );
      addTearDown(reviewer.dispose);

      final results = await Future.wait(<Future<AcpPermissionReviewResult?>>[
        reviewer.review(_reviewRequest('root-a'), workspaceRoot: '/root-a'),
        reviewer.review(_reviewRequest('root-b'), workspaceRoot: '/root-b'),
      ]);

      expect(
        results.map((result) => result?.decision),
        everyElement(AcpPermissionDecision.allow),
      );
      expect(clients, hasLength(2));
      expect(clients.map((client) => client.sessionCount), everyElement(1));
      expect(clients.first.connected, isFalse);
      expect(clients.last.connected, isTrue);
    },
  );

  test('agent reviewer reuses one context for the same workspace', () async {
    final fake = _ReviewFakeAgentClient(
      reviewText: '{"decision":"allow","risk":"low","rationale":"Safe."}',
    );
    var factoryCalls = 0;
    final reviewer = AcpAgentPermissionReviewer(
      agentName: 'Sidecar',
      clientFactory: () {
        factoryCalls += 1;
        return fake;
      },
    );
    addTearDown(reviewer.dispose);

    await reviewer.review(_reviewRequest('same-a'), workspaceRoot: '/same');
    await reviewer.review(_reviewRequest('same-b'), workspaceRoot: '/same');

    expect(factoryCalls, 1);
    expect(fake.sessionCount, 1);
  });

  test(
    'agent reviewer replaces the client before switching workspace binding',
    () async {
      final records = <String>[];
      final clients = <_BindingReviewAgentClient>[];
      final reviewer = AcpAgentPermissionReviewer(
        agentName: 'Sidecar',
        clientFactory: () {
          final client = _BindingReviewAgentClient(
            name: clients.isEmpty ? 'A' : 'B',
            records: records,
          );
          clients.add(client);
          return client;
        },
      );
      addTearDown(reviewer.dispose);

      final first = await reviewer.review(
        _reviewRequest('binding-a'),
        workspaceRoot: '/root-a',
      );
      final second = await reviewer.review(
        _reviewRequest('binding-b'),
        workspaceRoot: '/root-b',
      );

      expect(first?.decision, AcpPermissionDecision.allow);
      expect(second?.decision, AcpPermissionDecision.allow);
      expect(clients, hasLength(2));
      expect(
        records,
        containsAllInOrder(<String>[
          'A:create:/root-a:same-session',
          'A:prompt:/root-a:same-session',
          'A:dispose',
          'B:create:/root-b:same-session',
          'B:prompt:/root-b:same-session',
        ]),
      );
      expect(records, isNot(contains('A:create:/root-b:same-session')));
    },
  );

  test(
    'dispose failure quarantines workspace switching without a new client',
    () async {
      final client = _ThrowingDisposeReviewAgentClient();
      var factoryCalls = 0;
      final reviewer = AcpAgentPermissionReviewer(
        agentName: 'Sidecar',
        cleanupTimeout: const Duration(milliseconds: 30),
        clientFactory: () {
          factoryCalls += 1;
          return client;
        },
      );

      final first = await reviewer.review(
        _reviewRequest('throwing-dispose-a'),
        workspaceRoot: '/root-a',
      );
      final switching = await reviewer.review(
        _reviewRequest('throwing-dispose-b'),
        workspaceRoot: '/root-b',
      );
      final afterFailure = await reviewer.review(
        _reviewRequest('throwing-dispose-c'),
        workspaceRoot: '/root-c',
      );
      await reviewer.dispose().timeout(const Duration(milliseconds: 100));

      expect(first?.decision, AcpPermissionDecision.allow);
      expect(switching?.risk, 'unknown');
      expect(afterFailure?.risk, 'unknown');
      expect(client.stillActive, isTrue);
      expect(client.disposeCalls, 1);
      expect(factoryCalls, 1);
    },
  );

  test(
    'failed agent review cannot dispose the next queued review context',
    () async {
      final firstClient = _ControllableReviewAgentClient(
        firstPromptFails: true,
        hangSubsequentPromptsUntilDispose: true,
      );
      final secondClient = _ControllableReviewAgentClient();
      final clients = <_ControllableReviewAgentClient>[];
      final reviewer = AcpAgentPermissionReviewer(
        agentName: 'Sidecar',
        clientFactory: () {
          final client = clients.isEmpty ? firstClient : secondClient;
          clients.add(client);
          return client;
        },
      );
      addTearDown(reviewer.dispose);

      final first = reviewer.review(
        _reviewRequest('failure-a'),
        workspaceRoot: '/root-a',
      );
      await firstClient.firstPromptStarted.future;
      final second = reviewer.review(
        _reviewRequest('failure-b'),
        workspaceRoot: '/root-b',
      );
      await _pumpTestEventQueue();
      firstClient.releaseFirstPrompt();

      final results = await Future.wait(<Future<AcpPermissionReviewResult?>>[
        first,
        second,
      ]).timeout(const Duration(seconds: 2));

      expect(results.first?.risk, 'unknown');
      expect(results.last?.decision, AcpPermissionDecision.allow);
      expect(clients, hasLength(2));
      expect(firstClient.disposed, isTrue);
      expect(secondClient.disposed, isFalse);
    },
  );

  test(
    'timed out agent review settles cleanup before the next review starts',
    () async {
      final events = <String>[];
      final firstClient = _ControllableReviewAgentClient(
        hangFirstPromptUntilDispose: true,
        hangSubsequentPromptsUntilDispose: true,
        events: events,
        name: 'first',
      );
      final secondClient = _ControllableReviewAgentClient(
        events: events,
        name: 'second',
      );
      var factoryCalls = 0;
      final reviewer = AcpAgentPermissionReviewer(
        agentName: 'Sidecar',
        timeout: const Duration(milliseconds: 30),
        clientFactory: () {
          factoryCalls += 1;
          return factoryCalls == 1 ? firstClient : secondClient;
        },
      );
      addTearDown(reviewer.dispose);

      final first = reviewer.review(
        _reviewRequest('timeout-a'),
        workspaceRoot: '/root-a',
      );
      await firstClient.firstPromptStarted.future;
      final second = reviewer.review(
        _reviewRequest('timeout-b'),
        workspaceRoot: '/root-b',
      );
      final results = await Future.wait(<Future<AcpPermissionReviewResult?>>[
        first,
        second,
      ]).timeout(const Duration(seconds: 2));

      expect(results.first?.risk, 'unknown');
      expect(results.last?.decision, AcpPermissionDecision.allow);
      expect(
        events.indexOf('first:dispose'),
        lessThan(events.indexOf('second:connect')),
      );
    },
  );

  test(
    'non-cooperative timeout quarantines reviewer without blocking cleanup',
    () async {
      final client = _NonCooperativeReviewAgentClient();
      var factoryCalls = 0;
      final reviewer = AcpAgentPermissionReviewer(
        agentName: 'Sidecar',
        timeout: const Duration(milliseconds: 30),
        cleanupTimeout: const Duration(milliseconds: 30),
        clientFactory: () {
          factoryCalls += 1;
          return client;
        },
      );

      final first = reviewer.review(
        _reviewRequest('non-cooperative-a'),
        workspaceRoot: '/root-a',
      );
      await client.promptStarted.future;
      final firstResult = await first.timeout(
        const Duration(milliseconds: 200),
      );
      final secondResult = await reviewer
          .review(_reviewRequest('non-cooperative-b'), workspaceRoot: '/root-b')
          .timeout(const Duration(milliseconds: 250));
      await reviewer.dispose().timeout(const Duration(milliseconds: 200));

      expect(firstResult?.risk, 'unknown');
      expect(secondResult?.risk, 'unknown');
      expect(factoryCalls, 1);
      expect(client.disposeCalls, 1);
    },
  );

  test('disposing an in-flight agent reviewer prevents reconnect', () async {
    final client = _ControllableReviewAgentClient(
      hangFirstPromptUntilDispose: true,
    );
    var factoryCalls = 0;
    final reviewer = AcpAgentPermissionReviewer(
      agentName: 'Sidecar',
      timeout: const Duration(seconds: 1),
      clientFactory: () {
        factoryCalls += 1;
        return client;
      },
    );

    final reviewing = reviewer.review(
      _reviewRequest('dispose-a'),
      workspaceRoot: '/root-a',
    );
    await client.firstPromptStarted.future;
    final disposing = reviewer.dispose();
    final result = await reviewing.timeout(const Duration(seconds: 2));
    await disposing.timeout(const Duration(seconds: 2));
    final afterDispose = await reviewer.review(
      _reviewRequest('dispose-b'),
      workspaceRoot: '/root-b',
    );

    expect(result?.risk, 'unknown');
    expect(afterDispose?.risk, 'unknown');
    expect(factoryCalls, 1);
  });

  test('configured MCP reviewer can auto approve', () {
    final reviewer = McpPermissionReviewAgent(
      config: const AcpPermissionReviewAgentConfig(enabled: true),
      mcpServer: const McpServerConfig(
        raw: <String, dynamic>{
          'name': 'permission-reviewer',
          'command': 'permission-reviewer',
        },
      ),
    );
    addTearDown(reviewer.dispose);

    expect(reviewer.canAutoApprove, isTrue);
  });

  test('MCP permission reviewer refuses remote plaintext endpoints', () {
    expect(
      () => McpPermissionReviewAgent(
        config: const AcpPermissionReviewAgentConfig(enabled: true),
        mcpServer: const McpServerConfig(
          raw: <String, dynamic>{
            'name': 'permission-reviewer',
            'type': 'http',
            'url': 'http://reviewer.example.com/mcp',
          },
        ),
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('MCP permission reviewer allows loopback plaintext endpoints', () {
    final reviewer = McpPermissionReviewAgent(
      config: const AcpPermissionReviewAgentConfig(enabled: true),
      mcpServer: const McpServerConfig(
        raw: <String, dynamic>{
          'name': 'permission-reviewer',
          'type': 'http',
          'url': 'http://[::1]:8080/mcp',
        },
      ),
    );
    addTearDown(reviewer.dispose);

    expect(reviewer.canAutoApprove, isTrue);
  });

  test(
    'MCP error data is replaced by a fixed low-sensitivity failure',
    () async {
      const tokenCanary = 'token-canary-should-not-survive';
      const pathCanary = '/private/reviewer/secret.json';
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final serverSubscription = server.listen((request) async {
        if (request.method == 'GET') {
          request.response.statusCode = HttpStatus.methodNotAllowed;
          await request.response.close();
          return;
        }
        if (request.method == 'DELETE') {
          request.response.statusCode = HttpStatus.ok;
          await request.response.close();
          return;
        }
        final body = await utf8.decoder.bind(request).join();
        final message = jsonDecode(body) as Map<String, dynamic>;
        final method = message['method'];
        if (method == 'notifications/initialized') {
          request.response.statusCode = HttpStatus.accepted;
        } else if (method == 'initialize') {
          request.response
            ..headers.contentType = ContentType.json
            ..write(jsonEncode(_mcpInitializeResponse(message['id'])));
        } else {
          request.response
            ..headers.contentType = ContentType.json
            ..write(
              jsonEncode(<String, Object?>{
                'jsonrpc': '2.0',
                'id': message['id'],
                'error': <String, Object?>{
                  'code': -32603,
                  'message': 'remote failure $tokenCanary',
                  'data': <String, Object?>{
                    'token': tokenCanary,
                    'path': pathCanary,
                    'stack': 'at reviewer ($pathCanary:1)',
                  },
                },
              }),
            );
        }
        await request.response.close();
      });
      final reviewer = _localMcpReviewer(server.port);

      try {
        final result = await reviewer.review(
          _reviewRequest('mcp-error-data'),
          workspaceRoot: '/workspace',
        );
        final encoded = jsonEncode(result?.toJson());

        expect(result?.risk, 'unknown');
        expect(result?.rationale, 'Permission review service failed.');
        expect(result?.details, const <String, Object?>{
          'failure': 'mcp_error',
        });
        expect(encoded, isNot(contains(tokenCanary)));
        expect(encoded, isNot(contains(pathCanary)));
        final history =
            acpPermissionAuditEntriesToJson(<AcpPermissionAuditEntry>[
              AcpPermissionAuditEntry(
                request: _reviewRequest('mcp-error-history'),
                status: AcpPermissionAuditStatus.pending,
                recordedAt: DateTime.utc(2026, 7, 15),
                reviewResult: result,
              ),
            ]);
        expect(history, isNot(contains(tokenCanary)));
        expect(history, isNot(contains(pathCanary)));
      } finally {
        await reviewer.dispose();
        await serverSubscription.cancel();
        await server.close(force: true);
      }
    },
  );

  test('MCP tool result channels retain only fixed bounded outcomes', () async {
    const canary = 'mcp-result-canary-should-not-survive';
    final huge = '$canary${List<String>.filled(70 * 1024, 'x').join()}';
    final toolResults = <Map<String, Object?>>[
      <String, Object?>{
        'content': <Object?>[
          <String, Object?>{'type': 'text', 'text': huge},
        ],
        'isError': true,
        'structuredContent': <String, Object?>{'raw': huge},
        'unknownExtra': <String, Object?>{'raw': huge},
      },
      <String, Object?>{
        'content': const <Object?>[],
        'structuredContent': <String, Object?>{'rationale': huge},
      },
      <String, Object?>{
        'content': const <Object?>[],
        'unknownExtra': <String, Object?>{'rationale': huge},
      },
      <String, Object?>{
        'content': <Object?>[
          <String, Object?>{'type': 'text', 'text': huge},
        ],
      },
    ];
    var toolCallIndex = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final serverSubscription = server.listen((request) async {
      if (request.method == 'GET') {
        request.response.statusCode = HttpStatus.methodNotAllowed;
        await request.response.close();
        return;
      }
      if (request.method == 'DELETE') {
        request.response.statusCode = HttpStatus.ok;
        await request.response.close();
        return;
      }
      final body = await utf8.decoder.bind(request).join();
      final message = jsonDecode(body) as Map<String, dynamic>;
      final method = message['method'];
      if (method == 'notifications/initialized') {
        request.response.statusCode = HttpStatus.accepted;
      } else if (method == 'initialize') {
        request.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(_mcpInitializeResponse(message['id'])));
      } else {
        request.response
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode(<String, Object?>{
              'jsonrpc': '2.0',
              'id': message['id'],
              'result': toolResults[toolCallIndex++],
            }),
          );
      }
      await request.response.close();
    });
    final reviewer = _localMcpReviewer(server.port);

    try {
      final results = <AcpPermissionReviewResult?>[];
      for (var index = 0; index < toolResults.length; index += 1) {
        results.add(
          await reviewer.review(
            _reviewRequest('bounded-channel-$index'),
            workspaceRoot: '/workspace',
          ),
        );
      }

      expect(results.first?.details, containsPair('failure', 'tool_error'));
      for (final result in results.skip(1)) {
        expect(result?.details, containsPair('omission', 'size_limit'));
      }
      for (final result in results) {
        expect(jsonEncode(result?.toJson()), isNot(contains(canary)));
      }
    } finally {
      await reviewer.dispose();
      await serverSubscription.cancel();
      await server.close(force: true);
    }
  });

  test('MCP permission reviewer refuses endpoint credentials', () {
    expect(
      () => McpPermissionReviewAgent(
        config: const AcpPermissionReviewAgentConfig(enabled: true),
        mcpServer: const McpServerConfig(
          raw: <String, dynamic>{
            'name': 'permission-reviewer',
            'type': 'http',
            'url': 'https://embedded:canary-secret@reviewer.example.com/mcp',
          },
        ),
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.toString(),
          'message',
          isNot(contains('canary-secret')),
        ),
      ),
    );
  });

  test('MCP permission reviewer does not follow HTTP redirects', () async {
    final redirectTarget = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    var targetRequests = 0;
    final targetSubscription = redirectTarget.listen((request) async {
      targetRequests += 1;
      request.response
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': -1,
            'result': <String, dynamic>{
              'protocolVersion': '2025-11-25',
              'capabilities': <String, dynamic>{'tools': <String, dynamic>{}},
              'serverInfo': <String, dynamic>{
                'name': 'redirect-target',
                'version': '1.0.0',
              },
            },
          }),
        );
      await request.response.close();
    });
    final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var originRequests = 0;
    final originSubscription = origin.listen((request) async {
      originRequests += 1;
      await request.drain<void>();
      request.response
        ..statusCode = HttpStatus.seeOther
        ..headers.set(
          HttpHeaders.locationHeader,
          'http://127.0.0.1:${redirectTarget.port}/redirected',
        );
      await request.response.close();
    });
    final reviewer = McpPermissionReviewAgent(
      config: const AcpPermissionReviewAgentConfig(
        enabled: true,
        timeout: Duration(seconds: 1),
      ),
      mcpServer: McpServerConfig(
        raw: <String, dynamic>{
          'name': 'permission-reviewer',
          'type': 'http',
          'url': 'http://127.0.0.1:${origin.port}/mcp',
        },
      ),
    );

    try {
      final result = await reviewer.review(
        AcpPermissionRequest(
          id: 'permission-redirect',
          title: 'Read status',
          rationale: 'Requested by agent',
          sessionId: 'session-1',
          toolName: 'terminal',
          toolKind: 'execute',
          options: const <String>['Allow', 'Deny'],
          requestedAt: DateTime.utc(2026, 7, 11),
          metadata: const <String, Object?>{
            'command': 'git status',
            'cwd': '/workspace',
          },
        ),
        workspaceRoot: '/workspace',
      );

      expect(originRequests, 1);
      expect(targetRequests, 0);
      expect(result?.risk, 'unknown');
      expect(result?.details, containsPair('failure', 'mcp_error'));
    } finally {
      await reviewer.dispose();
      await originSubscription.cancel();
      await origin.close(force: true);
      await targetSubscription.cancel();
      await redirectTarget.close(force: true);
    }
  });

  test(
    'MCP reviewer supports JSON sessions without GET or DELETE redirects',
    () async {
      final redirectTarget = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final targetMethods = <String>[];
      final targetSubscription = redirectTarget.listen((request) async {
        targetMethods.add(request.method);
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      });
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final sessionHeaders = <String, String?>{};
      final methods = <String>[];
      final serverSubscription = server.listen((request) async {
        if (request.method == 'GET') {
          sessionHeaders['GET'] = request.headers.value('Mcp-Session-Id');
          request.response
            ..statusCode = HttpStatus.temporaryRedirect
            ..headers.set(
              HttpHeaders.locationHeader,
              'http://127.0.0.1:${redirectTarget.port}/redirected',
            );
          await request.response.close();
          return;
        }
        if (request.method == 'DELETE') {
          sessionHeaders['DELETE'] = request.headers.value('Mcp-Session-Id');
          request.response
            ..statusCode = HttpStatus.temporaryRedirect
            ..headers.set(
              HttpHeaders.locationHeader,
              'http://127.0.0.1:${redirectTarget.port}/redirected',
            );
          await request.response.close();
          return;
        }
        final body = await utf8.decoder.bind(request).join();
        final message = jsonDecode(body) as Map<String, dynamic>;
        final method = message['method'] as String;
        methods.add(method);
        sessionHeaders[method] = request.headers.value('Mcp-Session-Id');
        if (method == 'initialize') {
          request.response
            ..headers.contentType = ContentType.json
            ..headers.set('Mcp-Session-Id', 'review-session')
            ..write(jsonEncode(_mcpInitializeResponse(message['id'])));
        } else if (method == 'notifications/initialized') {
          request.response.statusCode = HttpStatus.accepted;
        } else if (method == 'tools/call') {
          request.response
            ..headers.contentType = ContentType.json
            ..write(jsonEncode(_mcpToolResponse(message['id'])));
        }
        await request.response.close();
      });
      final reviewer = _localMcpReviewer(server.port);

      try {
        final result = await reviewer.review(
          _reviewRequest('json'),
          workspaceRoot: '/workspace',
        );

        expect(result?.decision, AcpPermissionDecision.allow);
        expect(result?.risk, 'low');
        expect(
          methods,
          containsAllInOrder(<String>[
            'initialize',
            'notifications/initialized',
            'tools/call',
          ]),
        );
        expect(sessionHeaders['initialize'], isNull);
        expect(sessionHeaders['notifications/initialized'], 'review-session');
        expect(sessionHeaders['tools/call'], 'review-session');
        await _waitForTest(() => sessionHeaders.containsKey('GET'));
        expect(targetMethods, isEmpty);

        await reviewer.dispose();
        expect(sessionHeaders['DELETE'], 'review-session');
        expect(targetMethods, isEmpty);
      } finally {
        await reviewer.dispose();
        await serverSubscription.cancel();
        await server.close(force: true);
        await targetSubscription.cancel();
        await redirectTarget.close(force: true);
      }
    },
  );

  test('MCP permission reviewer supports SSE responses', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final serverSubscription = server.listen((request) async {
      if (request.method == 'GET') {
        request.response.statusCode = HttpStatus.methodNotAllowed;
        await request.response.close();
        return;
      }
      if (request.method == 'DELETE') {
        request.response.statusCode = HttpStatus.ok;
        await request.response.close();
        return;
      }
      final body = await utf8.decoder.bind(request).join();
      final message = jsonDecode(body) as Map<String, dynamic>;
      final method = message['method'];
      if (method == 'notifications/initialized') {
        request.response.statusCode = HttpStatus.accepted;
        await request.response.close();
        return;
      }
      final response = method == 'initialize'
          ? _mcpInitializeResponse(message['id'])
          : _mcpToolResponse(message['id']);
      request.response
        ..headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        )
        ..headers.set('Mcp-Session-Id', 'sse-review-session')
        ..write('event: message\n')
        ..write('data: ${jsonEncode(response)}\n\n');
      await request.response.close();
    });
    final reviewer = _localMcpReviewer(server.port);

    try {
      final result = await reviewer.review(
        _reviewRequest('sse'),
        workspaceRoot: '/workspace',
      );

      expect(result?.decision, AcpPermissionDecision.allow);
      expect(result?.risk, 'low');
    } finally {
      await reviewer.dispose();
      await serverSubscription.cancel();
      await server.close(force: true);
    }
  });
}

McpPermissionReviewAgent _localMcpReviewer(
  int port, {
  Duration timeout = const Duration(seconds: 2),
}) {
  return McpPermissionReviewAgent(
    config: AcpPermissionReviewAgentConfig(enabled: true, timeout: timeout),
    mcpServer: McpServerConfig(
      raw: <String, dynamic>{
        'name': 'permission-reviewer',
        'type': 'http',
        'url': 'http://127.0.0.1:$port/mcp',
      },
    ),
  );
}

AcpPermissionRequest _reviewRequest(String id) {
  return AcpPermissionRequest(
    id: 'permission-$id',
    title: 'Read status',
    rationale: 'Requested by agent',
    sessionId: 'session-1',
    toolName: 'terminal',
    toolKind: 'execute',
    options: const <String>['Allow', 'Deny'],
    requestedAt: DateTime.utc(2026, 7, 11),
    metadata: const <String, Object?>{
      'command': 'git status',
      'cwd': '/workspace',
    },
  );
}

Map<String, dynamic> _mcpInitializeResponse(Object? id) {
  return <String, dynamic>{
    'jsonrpc': '2.0',
    'id': id,
    'result': <String, dynamic>{
      'protocolVersion': '2025-11-25',
      'capabilities': <String, dynamic>{'tools': <String, dynamic>{}},
      'serverInfo': <String, dynamic>{
        'name': 'local-reviewer',
        'version': '1.0.0',
      },
    },
  };
}

Map<String, dynamic> _mcpToolResponse(Object? id) {
  return <String, dynamic>{
    'jsonrpc': '2.0',
    'id': id,
    'result': <String, dynamic>{
      'content': <Map<String, dynamic>>[
        <String, dynamic>{
          'type': 'text',
          'text': jsonEncode(<String, dynamic>{
            'decision': 'allow',
            'risk': 'low',
            'rationale': 'Read-only command.',
          }),
        },
      ],
      'isError': false,
    },
  };
}

Future<void> _waitForTest(bool Function() predicate) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Timed out waiting for condition.');
}

Future<void> _pumpTestEventQueue() async {
  for (var index = 0; index < 20; index += 1) {
    await Future<void>.delayed(Duration.zero);
  }
}

class _ReviewFakeAgentClient extends FakeAgentClient {
  _ReviewFakeAgentClient({
    required this.reviewText,
    super.sessionSettings,
    super.connectDelay,
  });

  final String reviewText;
  List<String> lastCreateAdditionalDirectories = const <String>[];

  @override
  Future<AgentSession> createSession({
    required String cwd,
    List<String> additionalDirectories = const <String>[],
  }) {
    lastCreateAdditionalDirectories = additionalDirectories;
    return super.createSession(
      cwd: cwd,
      additionalDirectories: additionalDirectories,
    );
  }

  @override
  Stream<AgentEvent> sendPrompt({
    required String sessionId,
    required String prompt,
    List<PromptAttachment> attachments = const <PromptAttachment>[],
  }) async* {
    lastPrompt = prompt;
    yield AgentEvent(
      type: AgentEventType.agentTextDelta,
      text: reviewText,
      timestamp: DateTime(2026, 5, 31, 12),
    );
    yield AgentEvent(
      type: AgentEventType.agentTextDone,
      text: '',
      timestamp: DateTime(2026, 5, 31, 12),
    );
  }
}

class _ControllableReviewAgentClient extends FakeAgentClient {
  _ControllableReviewAgentClient({
    this.firstPromptFails = false,
    this.hangFirstPromptUntilDispose = false,
    this.hangSubsequentPromptsUntilDispose = false,
    this.events,
    this.name = 'client',
  });

  final bool firstPromptFails;
  final bool hangFirstPromptUntilDispose;
  final bool hangSubsequentPromptsUntilDispose;
  final List<String>? events;
  final String name;
  final Completer<void> firstPromptStarted = Completer<void>();
  final Completer<void> _releaseFirstPrompt = Completer<void>();
  final Completer<void> _disposedSignal = Completer<void>();
  var _promptCalls = 0;
  bool disposed = false;

  @override
  Future<void> connect() async {
    events?.add('$name:connect');
    await super.connect();
  }

  void releaseFirstPrompt() {
    if (!_releaseFirstPrompt.isCompleted) {
      _releaseFirstPrompt.complete();
    }
  }

  @override
  Stream<AgentEvent> sendPrompt({
    required String sessionId,
    required String prompt,
    List<PromptAttachment> attachments = const <PromptAttachment>[],
  }) async* {
    _promptCalls += 1;
    if (_promptCalls == 1) {
      if (!firstPromptStarted.isCompleted) firstPromptStarted.complete();
      if (hangFirstPromptUntilDispose) {
        await _disposedSignal.future;
      } else if (firstPromptFails) {
        await _releaseFirstPrompt.future;
      }
      if (disposed || firstPromptFails) {
        throw StateError('controlled prompt failure');
      }
    } else if (hangSubsequentPromptsUntilDispose) {
      await _disposedSignal.future;
    }
    if (disposed) throw StateError('client disposed');
    yield AgentEvent(
      type: AgentEventType.agentTextDelta,
      text: '{"decision":"allow","risk":"low","rationale":"Safe."}',
      timestamp: DateTime.utc(2026, 7, 13),
    );
    yield AgentEvent(
      type: AgentEventType.agentTextDone,
      text: '',
      timestamp: DateTime.utc(2026, 7, 13),
    );
  }

  @override
  Future<void> dispose() async {
    events?.add('$name:dispose');
    disposed = true;
    if (!_disposedSignal.isCompleted) _disposedSignal.complete();
    if (!_releaseFirstPrompt.isCompleted) _releaseFirstPrompt.complete();
    await super.dispose();
  }
}

class _NonCooperativeReviewAgentClient extends FakeAgentClient {
  final Completer<void> promptStarted = Completer<void>();
  final Completer<void> _neverPrompt = Completer<void>();
  final Completer<void> _neverDispose = Completer<void>();
  var disposeCalls = 0;

  @override
  Stream<AgentEvent> sendPrompt({
    required String sessionId,
    required String prompt,
    List<PromptAttachment> attachments = const <PromptAttachment>[],
  }) async* {
    if (!promptStarted.isCompleted) promptStarted.complete();
    await _neverPrompt.future;
  }

  @override
  Future<void> dispose() {
    disposeCalls += 1;
    return _neverDispose.future;
  }
}

class _QueueReviewAgentClient extends _ReviewFakeAgentClient {
  _QueueReviewAgentClient()
    : super(
        reviewText: '{"decision":"allow","risk":"low","rationale":"Safe."}',
      );

  final Completer<void> firstPromptStarted = Completer<void>();
  final Completer<void> _releaseFirstPrompt = Completer<void>();
  var promptCalls = 0;

  void releaseFirstPrompt() {
    if (!_releaseFirstPrompt.isCompleted) _releaseFirstPrompt.complete();
  }

  @override
  Stream<AgentEvent> sendPrompt({
    required String sessionId,
    required String prompt,
    List<PromptAttachment> attachments = const <PromptAttachment>[],
  }) async* {
    promptCalls += 1;
    if (promptCalls == 1) {
      if (!firstPromptStarted.isCompleted) firstPromptStarted.complete();
      await _releaseFirstPrompt.future;
    }
    yield* super.sendPrompt(
      sessionId: sessionId,
      prompt: prompt,
      attachments: attachments,
    );
  }

  @override
  Future<void> dispose() async {
    releaseFirstPrompt();
    await super.dispose();
  }
}

class _DelayedCleanupReviewAgentClient extends FakeAgentClient {
  final Completer<void> promptStarted = Completer<void>();
  final Completer<void> _failPrompt = Completer<void>();
  final Completer<void> disposeStarted = Completer<void>();
  final Completer<void> _finishDispose = Completer<void>();
  final Completer<void> disposeFinished = Completer<void>();

  void failPrompt() {
    if (!_failPrompt.isCompleted) _failPrompt.complete();
  }

  void finishDispose() {
    if (!_finishDispose.isCompleted) _finishDispose.complete();
  }

  @override
  Stream<AgentEvent> sendPrompt({
    required String sessionId,
    required String prompt,
    List<PromptAttachment> attachments = const <PromptAttachment>[],
  }) async* {
    if (!promptStarted.isCompleted) promptStarted.complete();
    await _failPrompt.future;
    throw StateError('controlled prompt failure');
  }

  @override
  Future<void> dispose() async {
    if (!disposeStarted.isCompleted) disposeStarted.complete();
    await _finishDispose.future;
    await super.dispose();
    if (!disposeFinished.isCompleted) disposeFinished.complete();
  }
}

class _ThrowingDisposeReviewAgentClient extends _ReviewFakeAgentClient {
  _ThrowingDisposeReviewAgentClient()
    : super(
        reviewText: '{"decision":"allow","risk":"low","rationale":"Safe."}',
      );

  var stillActive = true;
  var disposeCalls = 0;

  @override
  Future<void> dispose() async {
    disposeCalls += 1;
    throw StateError('dispose failed while client remains active');
  }
}

class _BindingReviewAgentClient extends FakeAgentClient {
  _BindingReviewAgentClient({required this.name, required this.records});

  final String name;
  final List<String> records;
  String? _workspaceRoot;

  @override
  Future<AgentSession> createSession({
    required String cwd,
    List<String> additionalDirectories = const <String>[],
  }) async {
    _workspaceRoot = cwd;
    records.add('$name:create:$cwd:same-session');
    return AgentSession(
      id: 'same-session',
      cwd: cwd,
      createdAt: DateTime.utc(2026, 7, 13),
      additionalDirectories: additionalDirectories,
    );
  }

  @override
  Future<void> closeSession({required String sessionId}) async {
    records.add('$name:close:$sessionId');
    throw StateError('close failed');
  }

  @override
  Stream<AgentEvent> sendPrompt({
    required String sessionId,
    required String prompt,
    List<PromptAttachment> attachments = const <PromptAttachment>[],
  }) async* {
    records.add('$name:prompt:${_workspaceRoot!}:$sessionId');
    yield AgentEvent(
      type: AgentEventType.agentTextDelta,
      text: '{"decision":"allow","risk":"low","rationale":"Safe."}',
      timestamp: DateTime.utc(2026, 7, 13),
    );
    yield AgentEvent(
      type: AgentEventType.agentTextDone,
      text: '',
      timestamp: DateTime.utc(2026, 7, 13),
    );
  }

  @override
  Future<void> dispose() async {
    records.add('$name:dispose');
    await super.dispose();
  }
}
