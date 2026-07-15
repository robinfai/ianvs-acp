import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_acp/dart_acp.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stream_channel/stream_channel.dart';

void main() {
  test('invalid terminal handle limits fail before transport start', () async {
    Future<void> expectRejected({
      required int maxTerminalHandles,
      required int maxTerminalHandlesPerSession,
    }) async {
      final transport = _TrackingLifecycleTransport();

      await expectLater(
        AcpClient.start(
          config: AcpConfig(),
          transport: transport,
          maxTerminalHandles: maxTerminalHandles,
          maxTerminalHandlesPerSession: maxTerminalHandlesPerSession,
        ),
        throwsArgumentError,
      );

      expect(transport.startCount, 0);
      expect(transport.stopCount, 0);
      unawaited(transport.closeInput());
    }

    await expectRejected(
      maxTerminalHandles: 0,
      maxTerminalHandlesPerSession: 1,
    );
    await expectRejected(
      maxTerminalHandles: 1,
      maxTerminalHandlesPerSession: 0,
    );
    await expectRejected(
      maxTerminalHandles: 1,
      maxTerminalHandlesPerSession: 2,
    );
  });

  test(
    'AcpClient terminal handle limits reach the live session manager',
    () async {
      final transport = _TrackingLifecycleTransport();
      final provider = _RecordingTerminalProvider(
        currentOutputValue: 'aé中-secret-must-be-truncated',
      );
      final responses = <String, Completer<Map<String, dynamic>>>{};
      final server = transport.outbound.listen((line) {
        final message = jsonDecode(line) as Map<String, dynamic>;
        if (message['method'] == 'session/resume') {
          transport.addInbound(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': message['id'],
              'result': <String, dynamic>{'sessionId': 'session-limit'},
            }),
          );
          return;
        }
        final id = message['id']?.toString();
        if (id != null) responses[id]?.complete(message);
      });
      final client = await AcpClient.start(
        config: AcpConfig(
          terminalProvider: provider,
          permissionProvider: DefaultPermissionProvider(
            onRequest: (_) async => const PermissionDecision.allow(),
          ),
        ),
        transport: transport,
        maxTerminalHandles: 1,
        maxTerminalHandlesPerSession: 1,
      );
      final terminalEvents = <TerminalEvent>[];
      final terminalEventsSubscription = client.terminalEvents.listen(
        terminalEvents.add,
      );

      Future<Map<String, dynamic>> terminalRequest({
        required String id,
        required String method,
        required Map<String, dynamic> params,
      }) async {
        final response = Completer<Map<String, dynamic>>();
        responses[id] = response;
        transport.addInbound(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': id,
            'method': method,
            'params': params,
          }),
        );
        return response.future.timeout(const Duration(seconds: 5));
      }

      try {
        await client.resumeSession(
          sessionId: 'session-limit',
          workspaceRoot: '/workspace',
        );
        final first = await terminalRequest(
          id: 'terminal-limit-first',
          method: 'terminal/create',
          params: <String, dynamic>{
            'sessionId': 'session-limit',
            'command': 'first-command',
            'args': <String>[],
            'outputByteLimit': 4,
            'env': <Map<String, String>>[
              <String, String>{
                'name': 'TERMINAL_LIMIT_CANARY',
                'value': 'terminal-limit-secret',
              },
            ],
          },
        );
        final terminalId =
            (first['result'] as Map<String, dynamic>)['terminalId'];
        final publicOutput = await client.terminalOutput(terminalId as String);
        final output = await terminalRequest(
          id: 'terminal-output',
          method: 'terminal/output',
          params: <String, dynamic>{'terminalId': terminalId},
        );
        final waited = await terminalRequest(
          id: 'terminal-wait',
          method: 'terminal/wait_for_exit',
          params: <String, dynamic>{'terminalId': terminalId},
        );
        final second = await terminalRequest(
          id: 'terminal-limit-second',
          method: 'terminal/create',
          params: <String, dynamic>{
            'sessionId': 'session-limit',
            'command': 'second-command-canary',
            'args': <String>[],
          },
        );

        expect(first, contains('result'));
        expect(publicOutput, 'aé');
        expect(publicOutput, isNot(contains('secret-must-be-truncated')));
        expect(output['result'], <String, dynamic>{
          'output': 'aé',
          'truncated': true,
          'exitStatus': null,
        });
        expect(waited['result'], <String, dynamic>{
          'output': 'aé',
          'truncated': true,
          'exitStatus': <String, dynamic>{'exitCode': 0},
        });
        final outputEvent = terminalEvents
            .whereType<TerminalOutputEvent>()
            .single;
        expect(outputEvent.output, 'aé');
        expect(outputEvent.truncated, isTrue);
        expect(second['error'], <String, dynamic>{
          'code': -32001,
          'message': 'Terminal handle limit exceeded.',
        });
        expect(second.toString(), isNot(contains('terminal-limit-secret')));
        expect(second.toString(), isNot(contains('second-command-canary')));
        expect(provider.createCalls, 1);
        expect(
          provider.createdHandles.single.outputByteLimit,
          defaultTerminalOutputByteLimit,
        );
      } finally {
        await terminalEventsSubscription.cancel();
        await client.dispose();
        await server.cancel();
        await transport.closeInput();
      }

      expect(transport.stopCount, 1);
      expect(provider.releaseAttempts, 1);
      expect(provider.createdHandles, hasLength(1));
      expect(
        provider.releasedHandles.single,
        same(provider.createdHandles.single),
      );
    },
  );
}

class _TrackingLifecycleTransport implements AcpTransport {
  final StreamChannelController<String> _controller =
      StreamChannelController<String>();
  var startCount = 0;
  var stopCount = 0;

  Stream<String> get outbound => _controller.local.stream;

  @override
  StreamChannel<String> get channel => _controller.foreign;

  @override
  Future<void> start() async {
    startCount += 1;
  }

  @override
  Future<void> stop() async {
    stopCount += 1;
  }

  void addInbound(String line) => _controller.local.sink.add(line);

  Future<void> closeInput() => _controller.local.sink.close();
}

class _RecordingTerminalProvider implements TerminalProvider {
  _RecordingTerminalProvider({this.currentOutputValue = ''});

  final String currentOutputValue;
  var createCalls = 0;
  var releaseAttempts = 0;
  final List<TerminalProcessHandle> createdHandles = <TerminalProcessHandle>[];
  final List<TerminalProcessHandle> releasedHandles = <TerminalProcessHandle>[];

  @override
  Future<TerminalProcessHandle> create({
    required String sessionId,
    required String command,
    List<String> args = const <String>[],
    String? cwd,
    Map<String, String>? env,
  }) async {
    createCalls += 1;
    final process = await Process.start('/bin/sh', const <String>[
      '-c',
      'sleep 30',
    ]);
    final handle = TerminalProcessHandle(
      terminalId: 'terminal-$createCalls',
      process: process,
    );
    createdHandles.add(handle);
    return handle;
  }

  @override
  Future<String> currentOutput(TerminalProcessHandle handle) async =>
      currentOutputValue;

  @override
  Future<void> kill(TerminalProcessHandle handle) => handle.kill();

  @override
  Future<void> release(TerminalProcessHandle handle) async {
    releaseAttempts += 1;
    releasedHandles.add(handle);
    await handle.release();
  }

  @override
  Future<int> waitForExit(TerminalProcessHandle handle) async => 0;
}
