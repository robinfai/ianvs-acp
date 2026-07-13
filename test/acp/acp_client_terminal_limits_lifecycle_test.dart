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
      final provider = _RecordingTerminalProvider();
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

      Future<Map<String, dynamic>> createTerminal({
        required String id,
        required String command,
      }) async {
        final response = Completer<Map<String, dynamic>>();
        responses[id] = response;
        transport.addInbound(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': id,
            'method': 'terminal/create',
            'params': <String, dynamic>{
              'sessionId': 'session-limit',
              'command': command,
              'args': <String>[],
              'env': <Map<String, String>>[
                <String, String>{
                  'name': 'TERMINAL_LIMIT_CANARY',
                  'value': 'terminal-limit-secret',
                },
              ],
            },
          }),
        );
        return response.future.timeout(const Duration(seconds: 5));
      }

      try {
        await client.resumeSession(
          sessionId: 'session-limit',
          workspaceRoot: '/workspace',
        );
        final first = await createTerminal(
          id: 'terminal-limit-first',
          command: 'first-command',
        );
        final second = await createTerminal(
          id: 'terminal-limit-second',
          command: 'second-command-canary',
        );

        expect(first, contains('result'));
        expect(second['error'], <String, dynamic>{
          'code': -32001,
          'message': 'Terminal handle limit exceeded.',
        });
        expect(second.toString(), isNot(contains('terminal-limit-secret')));
        expect(second.toString(), isNot(contains('second-command-canary')));
        expect(provider.createCalls, 1);
      } finally {
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
    int outputByteLimit = defaultTerminalOutputByteLimit,
  }) async {
    createCalls += 1;
    final process = await Process.start('/bin/sh', const <String>[
      '-c',
      'sleep 30',
    ]);
    final handle = TerminalProcessHandle(
      terminalId: 'terminal-$createCalls',
      process: process,
      outputByteLimit: outputByteLimit,
    );
    createdHandles.add(handle);
    return handle;
  }

  @override
  Future<String> currentOutput(TerminalProcessHandle handle) async =>
      handle.currentOutput();

  @override
  Future<void> kill(TerminalProcessHandle handle) => handle.kill();

  @override
  Future<void> release(TerminalProcessHandle handle) async {
    releaseAttempts += 1;
    releasedHandles.add(handle);
    await handle.release();
  }

  @override
  Future<int> waitForExit(TerminalProcessHandle handle) => handle.waitForExit();
}
