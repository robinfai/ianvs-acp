import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_acp/dart_acp.dart' as acp;
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/agent_event.dart';
import 'package:ianvs_acp/acp/dart_acp_agent_client.dart';

final class _LogicalTimeoutHttpHarness {
  _LogicalTimeoutHttpHarness._(this.server, this.subscription)
    : endpoint = Uri.parse('http://127.0.0.1:${server.port}/acp');

  final HttpServer server;
  final StreamSubscription<HttpRequest> subscription;
  final Uri endpoint;
  final List<HttpResponse> sse = <HttpResponse>[];
  final StreamController<Map<String, dynamic>> prompts =
      StreamController<Map<String, dynamic>>.broadcast(sync: true);
  final StreamController<void> cancels = StreamController<void>.broadcast(
    sync: true,
  );
  final StreamController<void> deletes = StreamController<void>.broadcast(
    sync: true,
  );
  final StreamController<int> heartbeatFlushes =
      StreamController<int>.broadcast(sync: true);
  Timer? heartbeat;
  int heartbeatFlushCount = 0;
  int initializeCount = 0;
  int cancelCount = 0;
  int deleteCount = 0;
  int promptCount = 0;
  int nextSession = 0;

  static Future<_LogicalTimeoutHttpHarness> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    late _LogicalTimeoutHttpHarness harness;
    final subscription = server.listen((request) => harness.handle(request));
    harness = _LogicalTimeoutHttpHarness._(server, subscription);
    harness.heartbeat = Timer.periodic(
      const Duration(milliseconds: 15),
      (_) => harness.writeHeartbeats(),
    );
    return harness;
  }

  Future<void> handle(HttpRequest request) async {
    if (request.method == 'DELETE') {
      deleteCount += 1;
      deletes.add(null);
      for (final response in List<HttpResponse>.of(sse)) {
        try {
          await response.close();
        } on Object {
          // The client may already have closed this SSE response.
        }
      }
      sse.clear();
      request.response.statusCode = HttpStatus.accepted;
      await request.response.close();
      return;
    }
    if (request.method == 'GET') {
      request.response.bufferOutput = false;
      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
        charset: 'utf-8',
      );
      request.response.write(': connected\n\n');
      await request.response.flush();
      sse.add(request.response);
      return;
    }
    final message =
        jsonDecode(await utf8.decoder.bind(request).join())
            as Map<String, dynamic>;
    final method = message['method'];
    request.response.headers.contentType = ContentType.json;
    if (method == 'initialize') {
      initializeCount += 1;
      request.response
        ..headers.set('Acp-Connection-Id', 'connection-$initializeCount')
        ..write(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': message['id'],
            'result': <String, dynamic>{
              'connectionId': 'connection-$initializeCount',
              'protocolVersion': 1,
              'agentCapabilities': <String, dynamic>{},
              'authMethods': <Map<String, dynamic>>[],
            },
          }),
        );
    } else if (method == 'session/new') {
      request.response.write(
        jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': message['id'],
          'result': <String, dynamic>{'sessionId': 'session-${++nextSession}'},
        }),
      );
    } else if (method == 'session/prompt') {
      promptCount += 1;
      prompts.add(message);
      request.response.statusCode = HttpStatus.accepted;
    } else if (method == 'session/cancel') {
      cancelCount += 1;
      cancels.add(null);
      request.response.statusCode = HttpStatus.accepted;
    }
    await request.response.close();
  }

  void writeHeartbeats() {
    for (final response in List<HttpResponse>.of(sse)) {
      try {
        response.write(': heartbeat\n\n');
        unawaited(
          response.flush().then<void>(
            (_) {
              heartbeatFlushCount += 1;
              if (!heartbeatFlushes.isClosed) {
                heartbeatFlushes.add(heartbeatFlushCount);
              }
            },
            onError: (Object _) {
              sse.remove(response);
            },
          ),
        );
      } on Object {
        sse.remove(response);
      }
    }
  }

  Future<void> completePrompt(Object? id) async {
    final data = jsonEncode(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': id,
      'result': <String, dynamic>{'stopReason': 'end_turn'},
    });
    for (final response in sse) {
      response.write('event: message\ndata: $data\n\n');
      await response.flush();
    }
  }

  Future<void> dispose() async {
    heartbeat?.cancel();
    await heartbeatFlushes.close();
    await prompts.close();
    await cancels.close();
    await deletes.close();
    for (final response in List<HttpResponse>.of(sse)) {
      try {
        await response.close();
      } on Object {
        // Teardown is idempotent when the client closed the SSE response.
      }
    }
    await subscription.cancel();
    await server.close(force: true);
  }
}

void main() {
  test('heartbeat does not extend raw prompt logical deadline', () async {
    final harness = await _LogicalTimeoutHttpHarness.start();
    final client = DartAcpAgentClient(
      agentHttpUrl: harness.endpoint,
      timeouts: const acp.AcpTimeouts(
        initialize: Duration(seconds: 1),
        request: Duration(seconds: 1),
        prompt: Duration(milliseconds: 75),
        permission: Duration(seconds: 1),
        promptCancelGrace: Duration(milliseconds: 75),
      ),
    );
    const canary = 'prompt-tool-token-path-payload-stack-canary';
    try {
      await client.connect();
      final session = await client.createSession(cwd: '/workspace');
      final promptSeen = harness.prompts.stream.first;
      final streamDone = client
          .sendPrompt(sessionId: session.id, prompt: canary)
          .toList();
      await promptSeen.timeout(const Duration(seconds: 2));
      final heartbeatBaseline = harness.heartbeatFlushCount;
      final heartbeatAfterPrompt = await harness.heartbeatFlushes.stream
          .firstWhere((count) => count > heartbeatBaseline)
          .timeout(const Duration(seconds: 2));
      expect(heartbeatAfterPrompt, greaterThan(heartbeatBaseline));
      final events = await streamDone.timeout(const Duration(seconds: 2));
      final errors = events
          .where((event) => event.type == AgentEventType.error)
          .toList(growable: false);
      expect(errors, hasLength(1));
      expect(errors.single.text, 'ACP prompt timed out.');
      expect(jsonEncode(errors.single.metadata), isNot(contains(canary)));
      expect(
        events.where((event) => event.type == AgentEventType.error),
        hasLength(1),
      );
      expect(harness.cancelCount, 1);
    } finally {
      try {
        await client.dispose();
      } finally {
        await harness.dispose();
      }
    }
  });

  test('prompt response inside grace keeps the HTTP peer reusable', () async {
    final harness = await _LogicalTimeoutHttpHarness.start();
    final client = DartAcpAgentClient(
      agentHttpUrl: harness.endpoint,
      timeouts: const acp.AcpTimeouts(
        initialize: Duration(seconds: 1),
        request: Duration(seconds: 1),
        prompt: Duration(milliseconds: 75),
        permission: Duration(seconds: 1),
        promptCancelGrace: Duration(milliseconds: 200),
      ),
    );
    try {
      await client.connect();
      final session = await client.createSession(cwd: '/workspace');

      final firstPromptSeen = harness.prompts.stream.first;
      final firstCancelSeen = harness.cancels.stream.first;
      final firstDone = client
          .sendPrompt(sessionId: session.id, prompt: 'first')
          .toList();
      final firstRequest = await firstPromptSeen.timeout(
        const Duration(seconds: 2),
      );
      await firstCancelSeen.timeout(const Duration(seconds: 2));
      await harness.completePrompt(firstRequest['id']);
      final firstEvents = await firstDone.timeout(const Duration(seconds: 2));
      final firstErrors = firstEvents
          .where((event) => event.type == AgentEventType.error)
          .toList(growable: false);
      expect(firstErrors, hasLength(1));
      expect(firstErrors.single.text, 'ACP prompt timed out.');
      expect(harness.deleteCount, 0);

      final secondPromptSeen = harness.prompts.stream.first;
      final secondDone = client
          .sendPrompt(sessionId: session.id, prompt: 'second')
          .toList();
      final secondRequest = await secondPromptSeen.timeout(
        const Duration(seconds: 2),
      );
      await harness.completePrompt(secondRequest['id']);
      final secondEvents = await secondDone.timeout(const Duration(seconds: 2));
      expect(
        secondEvents.where((event) => event.type == AgentEventType.error),
        isEmpty,
      );
      expect(secondEvents.last.metadata['stopReason'], 'endTurn');
      expect(harness.cancelCount, 1);
      expect(harness.promptCount, 2);
      expect(harness.initializeCount, 1);
    } finally {
      try {
        await client.dispose();
      } finally {
        await harness.dispose();
      }
    }
  });

  test('prompt missing past grace requires explicit HTTP reconnect', () async {
    final harness = await _LogicalTimeoutHttpHarness.start();
    final oldClient = DartAcpAgentClient(
      agentHttpUrl: harness.endpoint,
      timeouts: const acp.AcpTimeouts(
        initialize: Duration(seconds: 1),
        request: Duration(seconds: 1),
        prompt: Duration(milliseconds: 75),
        permission: Duration(seconds: 1),
        promptCancelGrace: Duration(milliseconds: 75),
      ),
    );
    DartAcpAgentClient? replacementClient;
    var oldClientDisposed = false;
    try {
      await oldClient.connect();
      final oldSession = await oldClient.createSession(cwd: '/workspace');
      final firstPromptSeen = harness.prompts.stream.first;
      final firstDone = oldClient
          .sendPrompt(sessionId: oldSession.id, prompt: 'missing-response')
          .toList();
      await firstPromptSeen.timeout(const Duration(seconds: 2));
      expect(harness.promptCount, 1);

      final firstEvents = await firstDone.timeout(const Duration(seconds: 2));
      final firstErrors = firstEvents
          .where((event) => event.type == AgentEventType.error)
          .toList(growable: false);
      expect(firstErrors, hasLength(1));
      expect(firstErrors.single.text, 'ACP prompt timed out.');

      final oldPromptCount = harness.promptCount;
      final oldRetryEvents = await oldClient
          .sendPrompt(sessionId: oldSession.id, prompt: 'must-not-reach-http')
          .toList()
          .timeout(const Duration(seconds: 2));
      final oldRetryErrors = oldRetryEvents
          .where((event) => event.type == AgentEventType.error)
          .toList(growable: false);
      expect(oldRetryErrors, hasLength(1));
      expect(oldRetryErrors.single.text, 'ACP connection closed.');
      expect(
        harness.promptCount,
        oldPromptCount,
        reason: 'an unavailable old client must not send another prompt',
      );
      expect(
        harness.deleteCount,
        0,
        reason: 'fatal logical timeout must not dispose HTTP transport',
      );

      final deleteSeen = harness.deletes.stream.first;
      await oldClient.dispose();
      await deleteSeen.timeout(const Duration(seconds: 2));
      oldClientDisposed = true;
      expect(harness.deleteCount, 1);
      final replacement = DartAcpAgentClient(
        agentHttpUrl: harness.endpoint,
        timeouts: const acp.AcpTimeouts(
          initialize: Duration(seconds: 1),
          request: Duration(seconds: 1),
          prompt: Duration(milliseconds: 75),
          permission: Duration(seconds: 1),
          promptCancelGrace: Duration(milliseconds: 75),
        ),
      );
      replacementClient = replacement;
      await replacement.connect();
      final replacementSession = await replacement.createSession(
        cwd: '/workspace',
      );
      final replacementPromptSeen = harness.prompts.stream.first;
      final replacementDone = replacement
          .sendPrompt(
            sessionId: replacementSession.id,
            prompt: 'replacement-success',
          )
          .toList();
      final replacementRequest = await replacementPromptSeen.timeout(
        const Duration(seconds: 2),
      );
      await harness.completePrompt(replacementRequest['id']);
      final replacementEvents = await replacementDone.timeout(
        const Duration(seconds: 2),
      );
      expect(
        replacementEvents.where((event) => event.type == AgentEventType.error),
        isEmpty,
      );
      expect(replacementEvents.last.metadata['stopReason'], 'endTurn');
      expect(harness.promptCount, 2);
      expect(harness.initializeCount, 2);
    } finally {
      try {
        final currentReplacement = replacementClient;
        if (currentReplacement != null) {
          await currentReplacement.dispose();
        }
      } finally {
        try {
          if (!oldClientDisposed) await oldClient.dispose();
        } finally {
          await harness.dispose();
        }
      }
    }
  });
}
