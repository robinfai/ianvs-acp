import 'dart:async';
import 'dart:convert';

import 'package:dart_acp/dart_acp.dart' as acp;
import 'package:dart_acp/src/rpc/peer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/dart_acp_agent_client.dart';
import 'package:stream_channel/stream_channel.dart';

final class _RequestHarness {
  _RequestHarness(acp.AcpTimeouts timeouts) {
    sink = _CountingStringSink(outputController.sink);
    peer = JsonRpcPeer(
      StreamChannel<String>(input.stream, sink),
      timeouts: timeouts,
    );
    outbound = StreamIterator<String>(outputController.stream);
  }

  final StreamController<String> input = StreamController<String>(sync: true);
  final StreamController<String> outputController = StreamController<String>(
    sync: true,
  );
  late final _CountingStringSink sink;
  late final JsonRpcPeer peer;
  late final StreamIterator<String> outbound;

  Future<Map<String, dynamic>> takeRequest() async {
    expect(
      await outbound.moveNext().timeout(const Duration(seconds: 2)),
      isTrue,
    );
    return jsonDecode(outbound.current) as Map<String, dynamic>;
  }

  void respond(Object? id, Object? result) => input.add(
    jsonEncode(<String, dynamic>{'jsonrpc': '2.0', 'id': id, 'result': result}),
  );

  Future<void> dispose() async {
    await peer.close();
    await outbound.cancel();
    await input.close();
    await outputController.close();
  }
}

final class _CountingStringSink implements StreamSink<String> {
  _CountingStringSink(this.delegate);

  final StreamSink<String> delegate;
  final List<String> events = <String>[];
  var closeCount = 0;

  @override
  Future<void> get done => delegate.done;

  @override
  void add(String event) {
    events.add(event);
    delegate.add(event);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      delegate.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<String> stream) => delegate.addStream(stream);

  @override
  Future<void> close() {
    closeCount += 1;
    return delegate.close();
  }
}

final class _ReentrantInputStream extends Stream<String> {
  _ReentrantInputSubscription? _subscription;

  void add(String value) => _subscription!.add(value);

  void addError(Object error, StackTrace stackTrace) =>
      _subscription!.addError(error, stackTrace);

  void close() => _subscription?.close();

  @override
  StreamSubscription<String> listen(
    void Function(String event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    if (_subscription != null) {
      throw StateError('Reentrant input stream supports one listener.');
    }
    return _subscription = _ReentrantInputSubscription(onData, onError, onDone);
  }
}

final class _ReentrantInputSubscription implements StreamSubscription<String> {
  _ReentrantInputSubscription(this._onData, this._onError, this._onDone);

  void Function(String event)? _onData;
  Function? _onError;
  void Function()? _onDone;
  var _cancelled = false;
  var _paused = false;

  void add(String value) {
    if (!_cancelled && !_paused) _onData?.call(value);
  }

  void addError(Object error, StackTrace stackTrace) {
    if (_cancelled) return;
    final handler = _onError;
    if (handler is void Function(Object, StackTrace)) {
      handler(error, stackTrace);
    } else if (handler is void Function(Object)) {
      handler(error);
    }
  }

  void close() {
    if (_cancelled) return;
    _cancelled = true;
    _onDone?.call();
  }

  @override
  Future<void> cancel() async {
    _cancelled = true;
  }

  @override
  void onData(void Function(String data)? handleData) {
    _onData = handleData;
  }

  @override
  void onError(Function? handleError) {
    _onError = handleError;
  }

  @override
  void onDone(void Function()? handleDone) {
    _onDone = handleDone;
  }

  @override
  void pause([Future<void>? resumeSignal]) {
    _paused = true;
    resumeSignal?.whenComplete(resume);
  }

  @override
  void resume() {
    _paused = false;
  }

  @override
  bool get isPaused => _paused;

  @override
  Future<E> asFuture<E>([E? futureValue]) => Future<E>.value(futureValue as E);
}

final class _ReentrantTransportError extends Error {}

final class _TestPromptOwner implements JsonRpcPromptOwner {
  const _TestPromptOwner(this.sessionId, this.generation);

  @override
  final String sessionId;

  @override
  final int generation;
}

final class _StartCountingTransport implements acp.AcpTransport {
  final StreamController<String> _input = StreamController<String>(sync: true);
  final StreamController<String> _output = StreamController<String>(sync: true);
  var startCount = 0;
  var stopCount = 0;

  @override
  StreamChannel<String> get channel =>
      StreamChannel<String>(_input.stream, _output.sink);

  @override
  Future<void> start() async {
    startCount += 1;
  }

  @override
  Future<void> stop() async {
    stopCount += 1;
  }

  Future<void> dispose() async {
    final inputDone = _input.hasListener ? null : _input.stream.drain<void>();
    final outputDone = _output.hasListener
        ? null
        : _output.stream.drain<void>();
    await _input.close();
    await _output.close();
    await inputDone;
    await outputDone;
  }
}

final class _SecondValidationFailsTimeouts extends acp.AcpTimeouts {
  var validationCount = 0;

  @override
  void validate() {
    validationCount += 1;
    if (validationCount == 2) {
      throw ArgumentError('second validation');
    }
  }
}

final class _SecretToken {
  @override
  String toString() => 'TOKEN-CANARY';
}

void main() {
  test('request deadlines close and flush pending operations once', () async {
    for (final initializeFirst in <bool>[true, false]) {
      final harness = _RequestHarness(
        acp.AcpTimeouts(
          initialize: Duration(milliseconds: initializeFirst ? 60 : 1000),
          request: Duration(milliseconds: initializeFirst ? 1000 : 60),
        ),
      );
      final states = <AcpPeerUnavailableState>[];
      void listener(AcpPeerUnavailableState state) => states.add(state);
      harness.peer.addUnavailableListener(listener);
      try {
        final Future<Object?> first = initializeFirst
            ? harness.peer.initialize(<String, dynamic>{})
            : harness.peer.sendRaw('agent/first', <String, dynamic>{});
        final firstFailure = expectLater(
          first.timeout(const Duration(seconds: 2)),
          throwsA(
            isA<acp.AcpRequestTimeoutException>().having(
              (error) => error.toString(),
              'text',
              'ACP request timed out.',
            ),
          ),
        );
        await harness.takeRequest();
        final Future<Object?> sibling = initializeFirst
            ? harness.peer.sendRaw('agent/sibling', <String, dynamic>{})
            : harness.peer.initialize(<String, dynamic>{});
        final siblingFailure = expectLater(
          sibling.timeout(const Duration(seconds: 2)),
          throwsA(
            isA<acp.AcpConnectionClosedException>().having(
              (error) => error.toString(),
              'text',
              'ACP connection closed.',
            ),
          ),
        );
        await harness.takeRequest();
        await firstFailure;
        await siblingFailure;
        expect(states.map((state) => state.reason), <AcpPeerUnavailableReason>[
          AcpPeerUnavailableReason.fatalTimeout,
        ]);
        expect(harness.sink.closeCount, 1);
        await expectLater(
          harness.peer.sendRaw('CANARY-METHOD', <String, dynamic>{
            'p': 'CANARY',
          }),
          throwsA(
            isA<acp.AcpConnectionClosedException>().having(
              (error) => error.toString(),
              'text',
              'ACP connection closed.',
            ),
          ),
        );
      } finally {
        harness.peer.removeUnavailableListener(listener);
        await harness.dispose();
      }
    }
  });

  test(
    'request deadline races consume late responses without zone errors',
    () async {
      final zoneErrors = <Object>[];
      await runZonedGuarded(() async {
        final early = _RequestHarness(
          const acp.AcpTimeouts(request: Duration(milliseconds: 80)),
        );
        try {
          final result = early.peer.sendRaw('agent/early', <String, dynamic>{});
          final sent = await early.takeRequest();
          early.respond(sent['id'], <String, dynamic>{'ok': true});
          expect(await result, <String, dynamic>{'ok': true});
          await Future<void>.delayed(const Duration(milliseconds: 120));
          expect(early.peer.isAvailable, isTrue);
          expect(early.sink.closeCount, 0);
        } finally {
          await early.dispose();
        }

        final late = _RequestHarness(
          const acp.AcpTimeouts(request: Duration(milliseconds: 60)),
        );
        try {
          final result = late.peer.sendRaw('agent/late', <String, dynamic>{});
          final failure = expectLater(
            result,
            throwsA(isA<acp.AcpRequestTimeoutException>()),
          );
          final sent = await late.takeRequest();
          await failure;
          late.respond(sent['id'], <String, dynamic>{'late': 1});
          late.respond(sent['id'], <String, dynamic>{'late': 2});
          await pumpEventQueue();
          expect(late.sink.closeCount, 1);
        } finally {
          await late.dispose();
        }

        for (final reason in <AcpPeerUnavailableReason>[
          AcpPeerUnavailableReason.explicitClose,
          AcpPeerUnavailableReason.disposed,
        ]) {
          final closed = _RequestHarness(
            const acp.AcpTimeouts(request: Duration(milliseconds: 150)),
          );
          try {
            final result = closed.peer.sendRaw(
              'agent/close-race',
              <String, dynamic>{},
            );
            final failure = expectLater(
              result,
              throwsA(isA<acp.AcpConnectionClosedException>()),
            );
            await closed.takeRequest();
            await closed.peer.closeForTesting(reason);
            await failure;
            await Future<void>.delayed(const Duration(milliseconds: 180));
            expect(closed.sink.closeCount, 1);
          } finally {
            await closed.dispose();
          }
        }
      }, (Object error, StackTrace stackTrace) => zoneErrors.add(error));
      expect(zoneErrors, isEmpty);
    },
  );

  test(
    'reentrant transport close publishes state and blocks all writes',
    () async {
      const canary = 'REENTRANT-OUTPUT-CANARY';
      final input = _ReentrantInputStream();
      final outputController = StreamController<String>(sync: true);
      final outputSubscription = outputController.stream.listen((_) {});
      final sink = _CountingStringSink(outputController.sink);
      final peer = JsonRpcPeer(
        StreamChannel<String>(input, sink),
        timeouts: const acp.AcpTimeouts(),
      );
      final states = <AcpPeerUnavailableState>[];
      AcpPeerUnavailableState? replayed;
      var replayCalls = 0;
      late Future<Object?> closeSettled;
      var reusedCloseOwner = false;
      late Future<Object?> rawSettled;
      late Future<Object?> promptSettled;
      late Future<Object?> cancelSettled;
      late Future<Object?> notificationSettled;
      void replayListener(AcpPeerUnavailableState state) {
        replayCalls += 1;
        replayed = state;
      }

      final pendingSettled = peer
          .sendRaw('agent/pending', <String, dynamic>{})
          .then<Object?>((value) => value, onError: (Object error, _) => error);
      expect(sink.events, hasLength(1));
      final pendingRequest =
          jsonDecode(sink.events.single) as Map<String, dynamic>;
      final pendingId = pendingRequest['id'];
      sink.events.clear();
      void listener(AcpPeerUnavailableState state) {
        states.add(state);
        input.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': pendingId,
            'result': <String, dynamic>{'late': true},
          }),
        );
      }

      peer.addUnavailableListener(listener);
      final updates = peer.sessionUpdates.listen((_) {
        input.addError(_ReentrantTransportError(), StackTrace.current);
        expect(peer.isAvailable, isFalse);
        final closing = peer.close();
        reusedCloseOwner = identical(closing, peer.dispose());
        closeSettled = closing.then<Object?>(
          (_) => null,
          onError: (Object error, StackTrace _) => error,
        );
        peer.addUnavailableListener(replayListener);
        rawSettled = peer
            .sendRaw('CANARY-METHOD', <String, dynamic>{'value': canary})
            .then<Object?>(
              (value) => value,
              onError: (Object error, _) => error,
            );
        promptSettled = peer
            .prompt(<String, dynamic>{
              'sessionId': canary,
              'prompt': <Map<String, dynamic>>[
                <String, dynamic>{'type': 'text', 'text': canary},
              ],
            })
            .then<Object?>(
              (value) => value,
              onError: (Object error, _) => error,
            );
        cancelSettled = peer
            .cancel(<String, dynamic>{'sessionId': canary})
            .then<Object?>((_) => null, onError: (Object error, _) => error);
        notificationSettled = peer
            .sendNotificationRaw('CANARY-NOTIFICATION', <String, dynamic>{
              'value': canary,
            })
            .then<Object?>((_) => null, onError: (Object error, _) => error);
      });

      try {
        input.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'method': 'session/update',
            'params': <String, dynamic>{'sequence': 1},
          }),
        );
        expect(reusedCloseOwner, isTrue);
        expect(states, hasLength(1));
        expect(states.single.reason, AcpPeerUnavailableReason.transportClosed);
        expect(replayed, same(states.single));
        expect(replayCalls, 1);
        expect(sink.events, isEmpty);
        expect(await pendingSettled, isA<acp.AcpConnectionClosedException>());
        expect(await rawSettled, isA<acp.AcpConnectionClosedException>());
        expect(await promptSettled, isA<acp.AcpConnectionClosedException>());
        expect(await cancelSettled, isNull);
        expect(await notificationSettled, isNull);
        expect(
          await closeSettled.timeout(const Duration(seconds: 2)),
          isA<_ReentrantTransportError>(),
        );
        expect(sink.events.join(), isNot(contains(canary)));
        expect(sink.closeCount, 1);
      } finally {
        peer.removeUnavailableListener(listener);
        peer.removeUnavailableListener(replayListener);
        await updates.cancel();
        try {
          await peer.close();
        } on Object {
          // The transport error winner is asserted above.
        }
        input.close();
        await outputSubscription.cancel();
        await outputController.close();
      }
    },
  );

  test('prompt request derives session only from its owner', () async {
    final harness = _RequestHarness(const acp.AcpTimeouts());
    const owner = _TestPromptOwner('owner-session', 7);
    try {
      final result = harness.peer.sendPromptRequest(
        owner: owner,
        content: const <Map<String, dynamic>>[
          <String, dynamic>{'type': 'text', 'text': 'safe'},
        ],
      );
      final sent = await harness.takeRequest();
      expect(sent['method'], 'session/prompt');
      expect((sent['params'] as Map)['sessionId'], owner.sessionId);
      harness.respond(sent['id'], <String, dynamic>{'stopReason': 'end_turn'});
      expect(await result, <String, dynamic>{'stopReason': 'end_turn'});
    } finally {
      await harness.dispose();
    }
  });

  test('sendRaw session/prompt keeps its legacy ownerless path', () async {
    final harness = _RequestHarness(const acp.AcpTimeouts());
    try {
      final result = harness.peer.sendRaw('session/prompt', <String, dynamic>{
        'sessionId': 'legacy-session',
        'prompt': const <Map<String, dynamic>>[
          <String, dynamic>{'type': 'text', 'text': 'legacy'},
        ],
      });
      final sent = await harness.takeRequest();
      expect(sent['method'], 'session/prompt');
      harness.respond(sent['id'], <String, dynamic>{'stopReason': 'end_turn'});
      expect(await result, <String, dynamic>{'stopReason': 'end_turn'});
    } finally {
      await harness.dispose();
    }
  });

  test('ACP timeout defaults and validation are exact', () {
    const defaults = acp.AcpTimeouts();
    expect(defaults.initialize, const Duration(seconds: 15));
    expect(defaults.request, const Duration(seconds: 60));
    expect(defaults.prompt, const Duration(minutes: 30));
    expect(defaults.permission, const Duration(minutes: 5));
    expect(defaults.promptCancelGrace, const Duration(seconds: 2));

    final invalid = <acp.AcpTimeouts>[
      const acp.AcpTimeouts(initialize: Duration.zero),
      const acp.AcpTimeouts(initialize: Duration(microseconds: -1)),
      const acp.AcpTimeouts(request: Duration.zero),
      const acp.AcpTimeouts(request: Duration(microseconds: -1)),
      const acp.AcpTimeouts(prompt: Duration.zero),
      const acp.AcpTimeouts(prompt: Duration(microseconds: -1)),
      const acp.AcpTimeouts(permission: Duration.zero),
      const acp.AcpTimeouts(permission: Duration(microseconds: -1)),
      const acp.AcpTimeouts(promptCancelGrace: Duration.zero),
      const acp.AcpTimeouts(promptCancelGrace: Duration(microseconds: -1)),
    ];
    for (final timeouts in invalid) {
      expect(() => acp.AcpConfig(timeouts: timeouts), throwsArgumentError);
    }
  });

  test('invalid timeouts fail before transport construction', () async {
    final transport = _StartCountingTransport();
    final timeouts = _SecondValidationFailsTimeouts();
    final config = acp.AcpConfig(timeouts: timeouts);
    try {
      await expectLater(
        acp.AcpClient.start(config: config, transport: transport),
        throwsArgumentError,
      );
      expect(timeouts.validationCount, 2);
      expect(transport.startCount, 0);
      expect(transport.stopCount, 0);
      expect(
        () => DartAcpAgentClient(
          timeouts: const acp.AcpTimeouts(request: Duration.zero),
        ),
        throwsArgumentError,
      );
    } finally {
      await transport.dispose();
    }
  });

  test('timeout exceptions and cancellation tokens do not leak context', () {
    expect(
      const acp.AcpRequestTimeoutException().toString(),
      'ACP request timed out.',
    );
    expect(
      const acp.AcpPromptTimeoutException().toString(),
      'ACP prompt timed out.',
    );
    expect(
      const acp.AcpConnectionClosedException().toString(),
      'ACP connection closed.',
    );
    expect(
      const acp.PermissionRequestTimeoutException().toString(),
      'Permission request timed out.',
    );

    final token = _SecretToken();
    final options = acp.PermissionOptions(
      title: 'safe',
      rationale: 'safe',
      options: const <String>['allow'],
      sessionId: 'safe-session',
      toolName: 'safe-tool',
      cancellationToken: token,
      metadata: const <String, Object?>{'safe': true},
    );
    expect(options.cancellationToken, same(token));
    expect(options.metadata.values, isNot(contains(same(token))));
    expect(jsonEncode(options.metadata), isNot(contains('TOKEN-CANARY')));
    expect(options.toString(), isNot(contains('TOKEN-CANARY')));
  });
}
