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
      expect(result?.rationale, contains('303'));
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
  _ReviewFakeAgentClient({required this.reviewText, super.sessionSettings});

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
