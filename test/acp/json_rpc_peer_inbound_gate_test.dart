import 'dart:async';
import 'dart:convert';

import 'package:dart_acp/src/rpc/peer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stream_channel/stream_channel.dart';

void main() {
  test(
    'internal correlation restores duplicate and null wire ids exactly',
    () async {
      final channel = StreamChannelController<String>(sync: true);
      final outbound = StreamIterator<String>(channel.local.stream);
      final peer = JsonRpcPeer(channel.foreign);
      final allStarted = Completer<void>();
      var starts = 0;
      peer.onReadTextFile = (params) async {
        starts += 1;
        if (starts == 3) allStarted.complete();
        return <String, dynamic>{'marker': params['marker']};
      };
      try {
        channel.local.sink.add(
          jsonEncode(<Object?>[
            for (final entry in <(Object?, String)>[
              (7, 'a'),
              (7, 'b'),
              (null, 'c'),
            ])
              <String, dynamic>{
                'jsonrpc': '2.0',
                'id': entry.$1,
                'method': 'fs/read_text_file',
                'params': <String, dynamic>{'marker': entry.$2},
              },
          ]),
        );
        await allStarted.future.timeout(const Duration(seconds: 2));
        expect(await outbound.moveNext(), isTrue);
        final wire = outbound.current;
        final response = jsonDecode(wire) as List<dynamic>;
        expect(response.map((e) => (e as Map)['id']).toList(), <Object?>[
          7,
          7,
          null,
        ]);
        expect(
          response.map((e) => ((e as Map)['result'] as Map)['marker']).toList(),
          <String>['a', 'b', 'c'],
        );
        expect(wire, isNot(contains('_acp_internal_')));
        await pumpEventQueue();
        expect(peer.correlationPendingItemsForTesting, 0);
        expect(peer.correlationPendingBytesForTesting, 0);
      } finally {
        await peer.close();
        await outbound.cancel();
        await channel.local.sink.close();
      }
    },
  );

  test(
    'response commit retains correlation capacity behind a blocked batch sibling',
    () async {
      final channel = StreamChannelController<String>(sync: true);
      final peer = JsonRpcPeer(channel.foreign, maxPendingItems: 2);
      final quickFinished = Completer<void>();
      final blockedStarted = Completer<void>();
      final releaseBlocked = Completer<void>();
      peer.onReadTextFile = (params) async {
        quickFinished.complete();
        return <String, dynamic>{'content': 'ok'};
      };
      peer.onWriteTextFile = (params) async {
        blockedStarted.complete();
        await releaseBlocked.future;
        return null;
      };
      try {
        channel.local.sink.add(
          jsonEncode(<Object?>[
            <String, dynamic>{
              'jsonrpc': '2.0',
              'id': 1,
              'method': 'fs/read_text_file',
              'params': <String, dynamic>{},
            },
            <String, dynamic>{
              'jsonrpc': '2.0',
              'id': 2,
              'method': 'fs/write_text_file',
              'params': <String, dynamic>{},
            },
          ]),
        );
        await Future.wait<void>(<Future<void>>[
          quickFinished.future,
          blockedStarted.future,
        ]).timeout(const Duration(seconds: 2));
        await pumpEventQueue();
        expect(peer.inboundPendingItemsForTesting, 1);
        expect(peer.correlationPendingItemsForTesting, 2);
        await peer.close().timeout(const Duration(seconds: 2));
        expect(peer.correlationPendingItemsForTesting, 0);
        expect(peer.correlationPendingBytesForTesting, 0);
      } finally {
        if (!releaseBlocked.isCompleted) releaseBlocked.complete();
        await peer.close();
        await channel.local.sink.close();
      }
    },
  );

  test('correlation batch reservation rolls back gate atomically', () async {
    for (final byteLimited in <bool>[false, true]) {
      final quickRequest = <String, dynamic>{
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'fs/read_text_file',
        'params': <String, dynamic>{},
      };
      final blockedRequest = <String, dynamic>{
        'jsonrpc': '2.0',
        'id': 2,
        'method': 'fs/read_text_file',
        'params': <String, dynamic>{'blocked': true},
      };
      final firstBatchBytes =
          utf8.encode(jsonEncode(quickRequest)).length +
          utf8.encode(jsonEncode(blockedRequest)).length;
      final channel = StreamChannelController<String>(sync: true);
      final outbound = StreamIterator<String>(channel.local.stream);
      final peer = JsonRpcPeer(
        channel.foreign,
        maxPendingItems: byteLimited ? 128 : 2,
        maxPendingBytes: byteLimited ? firstBatchBytes : 32 * 1024 * 1024,
      );
      final quickFinished = Completer<void>();
      final blockedStarted = Completer<void>();
      final releaseBlocked = Completer<void>();
      peer.onReadTextFile = (params) async {
        if (params['blocked'] == true) {
          blockedStarted.complete();
          await releaseBlocked.future;
        } else {
          quickFinished.complete();
        }
        return <String, dynamic>{'content': 'ok'};
      };
      try {
        channel.local.sink.add(
          jsonEncode(<Object?>[quickRequest, blockedRequest]),
        );
        await Future.wait<void>(<Future<void>>[
          quickFinished.future,
          blockedStarted.future,
        ]).timeout(const Duration(seconds: 2));
        await pumpEventQueue();
        final maliciousId = peer.correlationIdsForTesting.first;
        final gateItemsBefore = peer.inboundPendingItemsForTesting;
        final trackerItemsBefore = peer.correlationPendingItemsForTesting;

        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            ...quickRequest,
            'id': byteLimited ? 3 : maliciousId,
          }),
        );
        expect(await outbound.moveNext(), isTrue);
        final rejection = jsonDecode(outbound.current) as Map<String, dynamic>;
        expect(rejection['id'], byteLimited ? 3 : maliciousId);
        expect((rejection['error'] as Map)['code'], -32000);
        expect(peer.inboundPendingItemsForTesting, gateItemsBefore);
        expect(peer.correlationPendingItemsForTesting, trackerItemsBefore);
      } finally {
        if (!releaseBlocked.isCompleted) releaseBlocked.complete();
        await peer.close();
        await outbound.cancel();
        await channel.local.sink.close();
      }
    }
  });

  test(
    'mixed batch routes response immediately and preserves request batch',
    () async {
      final channel = StreamChannelController<String>();
      final outbound = StreamIterator<String>(channel.local.stream);
      final peer = JsonRpcPeer(channel.foreign);
      final requestStarted = Completer<void>();
      final releaseRequest = Completer<void>();
      var notificationCount = 0;
      peer.onReadTextFile = (params) async {
        requestStarted.complete();
        await releaseRequest.future;
        return <String, dynamic>{'content': 'ok'};
      };
      peer.onWriteTextFile = (params) async {
        notificationCount += 1;
        return null;
      };

      try {
        final response = peer.sendRaw('agent/ping', <String, dynamic>{});
        expect(await outbound.moveNext(), isTrue);
        final sent = jsonDecode(outbound.current) as Map<String, dynamic>;

        channel.local.sink.add(
          jsonEncode(<Object?>[
            <String, dynamic>{
              'jsonrpc': '2.0',
              'id': sent['id'],
              'result': <String, dynamic>{'pong': true},
            },
            <String, dynamic>{
              'jsonrpc': '2.0',
              'id': 7,
              'method': 'fs/read_text_file',
              'params': <String, dynamic>{'path': '/tmp/file'},
            },
            <String, dynamic>{
              'jsonrpc': '2.0',
              'method': 'fs/write_text_file',
              'params': <String, dynamic>{
                'path': '/tmp/file',
                'content': 'notification',
              },
            },
            42,
          ]),
        );

        expect(
          await response.timeout(const Duration(seconds: 1)),
          <String, dynamic>{'pong': true},
        );
        await requestStarted.future.timeout(const Duration(seconds: 1));
        expect(notificationCount, 1);
        releaseRequest.complete();
        expect(await outbound.moveNext(), isTrue);
        final reply = jsonDecode(outbound.current);
        expect(reply, isA<List<dynamic>>());
        final replies = reply as List<dynamic>;
        expect(replies, hasLength(2));
        expect(replies.first, <String, dynamic>{
          'jsonrpc': '2.0',
          'id': 7,
          'result': <String, dynamic>{'content': 'ok'},
        });
        expect(
          (replies.last as Map<String, dynamic>)['error'],
          isA<Map>().having((error) => error['code'], 'code', -32600),
        );
        expect((replies.last as Map<String, dynamic>)['id'], isNull);
      } finally {
        if (!releaseRequest.isCompleted) releaseRequest.complete();
        await peer.close();
        await outbound.cancel();
        await channel.local.sink.close();
      }
    },
  );

  test('capacity rejection is atomic and does not echo payload', () async {
    const secret = 'TOP-SECRET-CAPACITY-PAYLOAD';
    final channel = StreamChannelController<String>();
    final outbound = StreamIterator<String>(channel.local.stream);
    final peer = JsonRpcPeer(channel.foreign, maxPendingItems: 1);
    final firstStarted = Completer<void>();
    final releaseFirst = Completer<void>();
    peer.onReadTextFile = (params) async {
      firstStarted.complete();
      await releaseFirst.future;
      return <String, dynamic>{'content': 'ok'};
    };

    try {
      channel.local.sink.add(
        jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'fs/read_text_file',
          'params': <String, dynamic>{'path': '/tmp/blocked'},
        }),
      );
      await firstStarted.future.timeout(const Duration(seconds: 1));

      channel.local.sink.add(
        jsonEncode(<Object?>[
          <String, dynamic>{
            'jsonrpc': '2.0',
            'id': 2,
            'method': 'fs/read_text_file',
            'params': <String, dynamic>{'path': secret},
          },
          <String, dynamic>{
            'jsonrpc': '2.0',
            'method': 'fs/read_text_file',
            'params': <String, dynamic>{'path': '$secret-notification'},
          },
        ]),
      );

      expect(await outbound.moveNext(), isTrue);
      final rejectionLine = outbound.current;
      expect(rejectionLine, isNot(contains(secret)));
      final rejection = jsonDecode(rejectionLine) as List<dynamic>;
      expect(rejection, hasLength(1));
      expect(rejection.single, <String, dynamic>{
        'jsonrpc': '2.0',
        'id': 2,
        'error': <String, dynamic>{
          'code': -32000,
          'message': 'Inbound request capacity exceeded.',
        },
      });
    } finally {
      if (!releaseFirst.isCompleted) releaseFirst.complete();
      await peer.close();
      await outbound.cancel();
      await channel.local.sink.close();
    }
  });

  test(
    'invalid same-method element cannot lend its byte reservation',
    () async {
      final invalid = <String, dynamic>{
        'jsonrpc': '1.0',
        'method': 'fs/read_text_file',
      };
      final blocked = <String, dynamic>{
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'fs/read_text_file',
        'params': <String, dynamic>{
          'path': List<String>.filled(512, 'x').join(),
        },
      };
      final third = <String, dynamic>{
        'jsonrpc': '2.0',
        'id': 2,
        'method': 'fs/read_text_file',
        'params': <String, dynamic>{},
      };
      final invalidBytes = utf8.encode(jsonEncode(invalid)).length;
      final blockedBytes = utf8.encode(jsonEncode(blocked)).length;
      expect(utf8.encode(jsonEncode(third)).length, greaterThan(invalidBytes));

      final channel = StreamChannelController<String>();
      final outbound = StreamIterator<String>(channel.local.stream);
      final peer = JsonRpcPeer(
        channel.foreign,
        maxPendingBytes: invalidBytes + blockedBytes,
      );
      final blockedStarted = Completer<void>();
      final releaseBlocked = Completer<void>();
      var handlerStarts = 0;
      peer.onReadTextFile = (params) async {
        handlerStarts += 1;
        if (handlerStarts == 1) {
          blockedStarted.complete();
          await releaseBlocked.future;
        }
        return <String, dynamic>{'content': 'ok'};
      };

      try {
        channel.local.sink.add(jsonEncode(<Object?>[invalid, blocked]));
        await blockedStarted.future.timeout(const Duration(seconds: 1));

        channel.local.sink.add(jsonEncode(third));
        expect(await outbound.moveNext(), isTrue);
        final firstReply = jsonDecode(outbound.current) as Map<String, dynamic>;
        expect(firstReply['id'], 2);
        expect(firstReply['error'], <String, dynamic>{
          'code': -32000,
          'message': 'Inbound request capacity exceeded.',
        });
        expect(handlerStarts, 1);
      } finally {
        if (!releaseBlocked.isCompleted) releaseBlocked.complete();
        await peer.close();
        await outbound.cancel();
        await channel.local.sink.close();
      }
    },
  );

  test('batch of twenty ordinary handlers peaks at fourteen', () async {
    final channel = StreamChannelController<String>();
    final outbound = StreamIterator<String>(channel.local.stream);
    final peer = JsonRpcPeer(channel.foreign);
    final fourteenStarted = Completer<void>();
    final releaseHandlers = Completer<void>();
    var started = 0;
    var active = 0;
    var peak = 0;
    peer.onReadTextFile = (params) async {
      started += 1;
      active += 1;
      if (active > peak) peak = active;
      if (started == 14) fourteenStarted.complete();
      await releaseHandlers.future;
      active -= 1;
      return <String, dynamic>{'content': params['index']};
    };

    try {
      channel.local.sink.add(
        jsonEncode(
          List<Object?>.generate(
            20,
            (index) => <String, dynamic>{
              'jsonrpc': '2.0',
              'id': index,
              'method': 'fs/read_text_file',
              'params': <String, dynamic>{'index': index},
            },
          ),
        ),
      );
      await fourteenStarted.future.timeout(const Duration(seconds: 1));
      await pumpEventQueue();
      expect(started, 14);
      expect(peak, 14);

      releaseHandlers.complete();
      expect(
        await outbound.moveNext().timeout(const Duration(seconds: 1)),
        isTrue,
      );
      final reply = jsonDecode(outbound.current) as List<dynamic>;
      expect(reply, hasLength(20));
      expect(started, 20);
      expect(peak, 14);
    } finally {
      if (!releaseHandlers.isCompleted) releaseHandlers.complete();
      await peer.close();
      await outbound.cancel();
      await channel.local.sink.close();
    }
  });

  test(
    'kill and release use reserved slots while fourteen waits block',
    () async {
      final channel = StreamChannelController<String>();
      final outbound = StreamIterator<String>(channel.local.stream);
      final peer = JsonRpcPeer(channel.foreign);
      final waitsStarted = Completer<void>();
      final releaseWaits = Completer<void>();
      final killStarted = Completer<void>();
      final releaseStarted = Completer<void>();
      var waitCount = 0;
      peer.onTerminalWaitForExit = (params) async {
        waitCount += 1;
        if (waitCount == 14) waitsStarted.complete();
        await releaseWaits.future;
        return <String, dynamic>{'exitCode': 0};
      };
      peer.onTerminalKill = (params) async {
        killStarted.complete();
        return null;
      };
      peer.onTerminalRelease = (params) async {
        releaseStarted.complete();
        return null;
      };

      try {
        final batch = <Object?>[
          ...List<Object?>.generate(
            14,
            (index) => <String, dynamic>{
              'jsonrpc': '2.0',
              'id': index,
              'method': 'terminal/wait_for_exit',
              'params': <String, dynamic>{'terminalId': '$index'},
            },
          ),
          <String, dynamic>{
            'jsonrpc': '2.0',
            'id': 100,
            'method': 'terminal/kill',
            'params': <String, dynamic>{'terminalId': 'kill'},
          },
          <String, dynamic>{
            'jsonrpc': '2.0',
            'id': 101,
            'method': 'terminal/release',
            'params': <String, dynamic>{'terminalId': 'release'},
          },
        ];
        channel.local.sink.add(jsonEncode(batch));

        await waitsStarted.future.timeout(const Duration(seconds: 1));
        await Future.wait<void>(<Future<void>>[
          killStarted.future,
          releaseStarted.future,
        ]).timeout(const Duration(seconds: 1));
        expect(waitCount, 14);

        releaseWaits.complete();
        expect(
          await outbound.moveNext().timeout(const Duration(seconds: 1)),
          isTrue,
        );
        expect(jsonDecode(outbound.current), hasLength(16));
      } finally {
        if (!releaseWaits.isCompleted) releaseWaits.complete();
        await peer.close();
        await outbound.cancel();
        await channel.local.sink.close();
      }
    },
  );

  test(
    'session updates stay synchronous and ordered behind blocked waits',
    () async {
      final channel = StreamChannelController<String>();
      final outbound = StreamIterator<String>(channel.local.stream);
      final peer = JsonRpcPeer(channel.foreign);
      final releaseWaits = Completer<void>();
      final waitsStarted = Completer<void>();
      final updates = <Object?>[];
      final updateSubscription = peer.sessionUpdates.listen(updates.add);
      var waitCount = 0;
      peer.onTerminalWaitForExit = (params) async {
        waitCount += 1;
        if (waitCount == 14) waitsStarted.complete();
        await releaseWaits.future;
        return <String, dynamic>{'exitCode': 0};
      };

      try {
        channel.local.sink.add(
          jsonEncode(<Object?>[
            ...List<Object?>.generate(
              14,
              (index) => <String, dynamic>{
                'jsonrpc': '2.0',
                'id': index,
                'method': 'terminal/wait_for_exit',
                'params': <String, dynamic>{'terminalId': '$index'},
              },
            ),
            <String, dynamic>{
              'jsonrpc': '2.0',
              'method': 'session/update',
              'params': <String, dynamic>{'sequence': 'U1'},
            },
            <String, dynamic>{
              'jsonrpc': '2.0',
              'method': 'session/update',
              'params': <String, dynamic>{'sequence': 'U2'},
            },
          ]),
        );

        await waitsStarted.future.timeout(const Duration(seconds: 1));
        expect(updates, <Object?>[
          <String, dynamic>{'sequence': 'U1'},
          <String, dynamic>{'sequence': 'U2'},
        ]);

        releaseWaits.complete();
        expect(
          await outbound.moveNext().timeout(const Duration(seconds: 1)),
          isTrue,
        );
        expect(jsonDecode(outbound.current), hasLength(14));
      } finally {
        if (!releaseWaits.isCompleted) releaseWaits.complete();
        await updateSubscription.cancel();
        await peer.close();
        await outbound.cancel();
        await channel.local.sink.close();
      }
    },
  );

  test('cancel Error cannot skip peer close cleanup', () async {
    final input = StreamController<String>(
      onCancel: () => Future<void>.error(_CancelError()),
    );
    final output = _RecordingSink();
    final peer = JsonRpcPeer(StreamChannel<String>(input.stream, output));
    final updatesDone = Completer<void>();
    final updateSubscription = peer.sessionUpdates.listen(
      (_) {},
      onDone: updatesDone.complete,
    );

    final firstClose = peer.close();
    final secondClose = peer.close();
    expect(identical(firstClose, secondClose), isTrue);
    await expectLater(firstClose, throwsA(isA<_CancelError>()));
    await updatesDone.future.timeout(const Duration(seconds: 1));
    expect(output.closeCount, 1);

    await updateSubscription.cancel();
    unawaited(input.close());
  });

  test('close completes without an outbound stream listener', () async {
    final channel = StreamChannelController<String>();
    final peer = JsonRpcPeer(channel.foreign);
    final firstClose = peer.close();
    final secondClose = peer.close();

    expect(identical(firstClose, secondClose), isTrue);
    try {
      await firstClose.timeout(const Duration(milliseconds: 250));
    } finally {
      unawaited(channel.local.stream.drain<void>());
      await firstClose;
      unawaited(channel.local.sink.close());
    }
  });

  test(
    'close stops RPC output before delayed inbound cancel completes',
    () async {
      final releaseCancel = Completer<void>();
      final input = StreamController<String>(
        sync: true,
        onCancel: () => releaseCancel.future,
      );
      final output = _RecordingSink();
      final peer = JsonRpcPeer(StreamChannel<String>(input.stream, output));
      final handlerStarted = Completer<void>();
      final releaseHandler = Completer<void>();
      peer.onReadTextFile = (params) async {
        handlerStarted.complete();
        await releaseHandler.future;
        return <String, dynamic>{'content': 'late'};
      };

      input.add(
        jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'fs/read_text_file',
          'params': <String, dynamic>{},
        }),
      );
      await handlerStarted.future.timeout(const Duration(seconds: 1));
      final closing = peer.close();
      var closeCompleted = false;
      unawaited(
        closing.then<void>(
          (_) => closeCompleted = true,
          onError: (Object _, StackTrace _) => closeCompleted = true,
        ),
      );

      try {
        await pumpEventQueue();
        expect(output.closeCount, 1);
        expect(closeCompleted, isFalse);

        releaseHandler.complete();
        await pumpEventQueue();
        expect(output.events, isEmpty);
        expect(closeCompleted, isFalse);

        releaseCancel.complete();
        await closing.timeout(const Duration(seconds: 1));
        expect(closeCompleted, isTrue);
      } finally {
        if (!releaseHandler.isCompleted) releaseHandler.complete();
        if (!releaseCancel.isCompleted) releaseCancel.complete();
        await closing;
        if (!input.isClosed) await input.close();
      }
    },
  );

  for (final firstKind in <String>['unknown', 'invalid']) {
    test('$firstKind retains capacity across the next event turn', () async {
      final channel = StreamChannelController<String>(sync: true);
      final lines = <String>[];
      final outputSubscription = channel.local.stream.listen(lines.add);
      final peer = JsonRpcPeer(channel.foreign, maxPendingItems: 1);
      var handlerStarts = 0;
      peer.onReadTextFile = (params) async {
        handlerStarts += 1;
        return <String, dynamic>{'content': 'ok'};
      };

      try {
        channel.local.sink.add(
          jsonEncode(
            firstKind == 'unknown'
                ? <String, dynamic>{
                    'jsonrpc': '2.0',
                    'id': 1,
                    'method': 'unknown/method',
                  }
                : 7,
          ),
        );
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': 2,
            'method': 'fs/read_text_file',
            'params': <String, dynamic>{},
          }),
        );

        expect(handlerStarts, 0);
        await pumpEventQueue();
        expect(
          lines.map(jsonDecode),
          contains(
            isA<Map<String, dynamic>>().having(
              (response) => response['error'],
              'capacity error',
              <String, dynamic>{
                'code': -32000,
                'message': 'Inbound request capacity exceeded.',
              },
            ),
          ),
        );

        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': 3,
            'method': 'fs/read_text_file',
            'params': <String, dynamic>{},
          }),
        );
        await pumpEventQueue();
        expect(handlerStarts, 1);
      } finally {
        await peer.close();
        await outputSubscription.cancel();
        await channel.local.sink.close();
      }
    });
  }

  test('sync and async handler failures restore peer capacity', () async {
    final channel = StreamChannelController<String>(sync: true);
    final outbound = StreamIterator<String>(channel.local.stream);
    final peer = JsonRpcPeer(channel.foreign, maxPendingItems: 1);
    peer.onReadTextFile = (params) {
      if (params['mode'] == 'sync') throw StateError('sync failure');
      if (params['mode'] == 'async') {
        return Future<dynamic>.error(StateError('async failure'));
      }
      return Future<dynamic>.value(<String, dynamic>{'content': 'ok'});
    };

    try {
      for (final entry in <({int id, String mode})>[
        (id: 1, mode: 'sync'),
        (id: 2, mode: 'async'),
        (id: 3, mode: 'success'),
      ]) {
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': entry.id,
            'method': 'fs/read_text_file',
            'params': <String, dynamic>{'mode': entry.mode},
          }),
        );
        expect(await outbound.moveNext(), isTrue);
        final response = jsonDecode(outbound.current) as Map<String, dynamic>;
        expect(response['id'], entry.id);
        if (entry.mode == 'success') {
          expect(response['result'], <String, dynamic>{'content': 'ok'});
        } else {
          expect(
            (response['error'] as Map<String, dynamic>)['message'],
            contains('${entry.mode} failure'),
          );
        }
      }
    } finally {
      await peer.close();
      await outbound.cancel();
      await channel.local.sink.close();
    }
  });

  test(
    'invalid batch item stays pending until blocked sibling completes',
    () async {
      final channel = StreamChannelController<String>(sync: true);
      final lines = <String>[];
      final outputSubscription = channel.local.stream.listen(lines.add);
      final peer = JsonRpcPeer(channel.foreign, maxPendingItems: 2);
      final blockedStarted = Completer<void>();
      final releaseBlocked = Completer<void>();
      var handlerStarts = 0;
      peer.onReadTextFile = (params) async {
        handlerStarts += 1;
        if (handlerStarts == 1) {
          blockedStarted.complete();
          await releaseBlocked.future;
        }
        return <String, dynamic>{'content': 'ok'};
      };

      try {
        channel.local.sink.add(
          jsonEncode(<Object?>[
            7,
            <String, dynamic>{
              'jsonrpc': '2.0',
              'id': 1,
              'method': 'fs/read_text_file',
              'params': <String, dynamic>{},
            },
          ]),
        );
        await blockedStarted.future.timeout(const Duration(seconds: 1));
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': 2,
            'method': 'fs/read_text_file',
            'params': <String, dynamic>{},
          }),
        );

        expect(handlerStarts, 1);
        expect(
          lines.map(jsonDecode),
          contains(
            isA<Map<String, dynamic>>().having(
              (response) => response['id'],
              'rejected id',
              2,
            ),
          ),
        );

        releaseBlocked.complete();
        await pumpEventQueue();
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': 3,
            'method': 'fs/read_text_file',
            'params': <String, dynamic>{},
          }),
        );
        await pumpEventQueue();
        expect(handlerStarts, 2);
      } finally {
        if (!releaseBlocked.isCompleted) releaseBlocked.complete();
        await peer.close();
        await outputSubscription.cancel();
        await channel.local.sink.close();
      }
    },
  );

  test(
    'mixed response bypasses a full gate before request rejection',
    () async {
      final channel = StreamChannelController<String>();
      final outbound = StreamIterator<String>(channel.local.stream);
      final peer = JsonRpcPeer(channel.foreign, maxPendingItems: 1);
      final blockedStarted = Completer<void>();
      final releaseBlocked = Completer<void>();
      peer.onReadTextFile = (params) async {
        blockedStarted.complete();
        await releaseBlocked.future;
        return <String, dynamic>{'content': 'blocked'};
      };

      try {
        final pendingResponse = peer.sendRaw('agent/ping', <String, dynamic>{});
        expect(await outbound.moveNext(), isTrue);
        final request = jsonDecode(outbound.current) as Map<String, dynamic>;
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': 10,
            'method': 'fs/read_text_file',
            'params': <String, dynamic>{},
          }),
        );
        await blockedStarted.future.timeout(const Duration(seconds: 1));

        channel.local.sink.add(
          jsonEncode(<Object?>[
            <String, dynamic>{
              'jsonrpc': '2.0',
              'id': request['id'],
              'result': <String, dynamic>{'pong': true},
            },
            <String, dynamic>{
              'jsonrpc': '2.0',
              'id': 11,
              'method': 'fs/read_text_file',
              'params': <String, dynamic>{},
            },
          ]),
        );

        expect(
          await pendingResponse.timeout(const Duration(seconds: 1)),
          <String, dynamic>{'pong': true},
        );
        expect(await outbound.moveNext(), isTrue);
        final rejection = jsonDecode(outbound.current) as List<dynamic>;
        expect(rejection, hasLength(1));
        expect((rejection.single as Map<String, dynamic>)['id'], 11);
        expect(
          (rejection.single as Map<String, dynamic>)['error'],
          <String, dynamic>{
            'code': -32000,
            'message': 'Inbound request capacity exceeded.',
          },
        );
      } finally {
        if (!releaseBlocked.isCompleted) releaseBlocked.complete();
        await peer.close();
        await outbound.cancel();
        await channel.local.sink.close();
      }
    },
  );

  test('canonical UTF-8 bytes admit exact size and reject plus one', () async {
    final request = <String, dynamic>{
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'fs/read_text_file',
      'params': <String, dynamic>{'path': '路径/😀'},
    };
    final canonicalBytes = utf8.encode(jsonEncode(request)).length;
    final prettyLine = const JsonEncoder.withIndent('  ').convert(request);
    expect(utf8.encode(prettyLine).length, greaterThan(canonicalBytes));

    final exactChannel = StreamChannelController<String>();
    final exactOutput = StreamIterator<String>(exactChannel.local.stream);
    final exactPeer = JsonRpcPeer(
      exactChannel.foreign,
      maxPendingBytes: canonicalBytes,
    );
    var exactStarts = 0;
    exactPeer.onReadTextFile = (params) async {
      exactStarts += 1;
      return <String, dynamic>{'content': 'ok'};
    };
    try {
      exactChannel.local.sink.add(prettyLine);
      expect(await exactOutput.moveNext(), isTrue);
      expect(exactStarts, 1);
      expect(
        (jsonDecode(exactOutput.current) as Map<String, dynamic>)['result'],
        <String, dynamic>{'content': 'ok'},
      );
    } finally {
      await exactPeer.close();
      await exactOutput.cancel();
      await exactChannel.local.sink.close();
    }

    final shortChannel = StreamChannelController<String>();
    final shortOutput = StreamIterator<String>(shortChannel.local.stream);
    final shortPeer = JsonRpcPeer(
      shortChannel.foreign,
      maxPendingBytes: canonicalBytes - 1,
    );
    var shortStarts = 0;
    shortPeer.onReadTextFile = (params) async {
      shortStarts += 1;
      return <String, dynamic>{'content': 'unexpected'};
    };
    try {
      shortChannel.local.sink.add(prettyLine);
      expect(await shortOutput.moveNext(), isTrue);
      expect(shortStarts, 0);
      expect(
        (jsonDecode(shortOutput.current) as Map<String, dynamic>)['error'],
        <String, dynamic>{
          'code': -32000,
          'message': 'Inbound request capacity exceeded.',
        },
      );
    } finally {
      await shortPeer.close();
      await shortOutput.cancel();
      await shortChannel.local.sink.close();
    }
  });

  test('parse error is fixed, payload-free, and recoverable', () async {
    const secret = 'PARSE-TOP-SECRET';
    final channel = StreamChannelController<String>();
    final outbound = StreamIterator<String>(channel.local.stream);
    final peer = JsonRpcPeer(channel.foreign);
    var handlerStarts = 0;
    peer.onReadTextFile = (params) async {
      handlerStarts += 1;
      return <String, dynamic>{'content': 'ok'};
    };

    try {
      channel.local.sink.add('{"secret":"$secret"');
      expect(await outbound.moveNext(), isTrue);
      expect(outbound.current, isNot(contains(secret)));
      expect(jsonDecode(outbound.current), <String, dynamic>{
        'jsonrpc': '2.0',
        'id': null,
        'error': <String, dynamic>{'code': -32700, 'message': 'Parse error.'},
      });

      channel.local.sink.add(
        jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'fs/read_text_file',
          'params': <String, dynamic>{},
        }),
      );
      expect(await outbound.moveNext(), isTrue);
      expect(handlerStarts, 1);
      expect(
        (jsonDecode(outbound.current) as Map<String, dynamic>)['result'],
        <String, dynamic>{'content': 'ok'},
      );
    } finally {
      await peer.close();
      await outbound.cancel();
      await channel.local.sink.close();
    }
  });

  test('reentrant update frame restores the outer batch context', () async {
    final input = _ManualInputStream();
    final output = _RecordingSink();
    final peer = JsonRpcPeer(StreamChannel<String>(input, output));
    final updates = <Object?>[];
    var handlerStarts = 0;
    peer.onReadTextFile = (params) async {
      handlerStarts += 1;
      return <String, dynamic>{'content': 'ok'};
    };
    final updateSubscription = peer.sessionUpdates.listen((update) {
      updates.add(update);
      if (update is Map && update['sequence'] == 'U1') {
        input.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'method': 'session/update',
            'params': <String, dynamic>{'sequence': 'U2'},
          }),
        );
      }
    });

    try {
      input.add(
        jsonEncode(<Object?>[
          <String, dynamic>{
            'jsonrpc': '2.0',
            'method': 'session/update',
            'params': <String, dynamic>{'sequence': 'U1'},
          },
          <String, dynamic>{
            'jsonrpc': '2.0',
            'id': 1,
            'method': 'fs/read_text_file',
            'params': <String, dynamic>{},
          },
        ]),
      );
      await pumpEventQueue();
      expect(updates, <Object?>[
        <String, dynamic>{'sequence': 'U1'},
        <String, dynamic>{'sequence': 'U2'},
      ]);
      expect(handlerStarts, 1);
      expect(output.events, hasLength(1));
      final reply = jsonDecode(output.events.single) as List<dynamic>;
      expect((reply.single as Map<String, dynamic>)['id'], 1);
    } finally {
      await updateSubscription.cancel();
      await peer.close();
    }
  });

  test('explicit close drops reentrant queued deliveries', () async {
    final input = _ManualInputStream();
    final output = _RecordingSink();
    final zoneErrors = <Object>[];
    Object? synchronousError;
    late JsonRpcPeer peer;
    late Future<void> closing;
    late Future<Object?> pendingSettled;
    late StreamSubscription<Object?> updateSubscription;
    var handlerStarts = 0;

    runZonedGuarded<void>(
      () {
        peer = JsonRpcPeer(StreamChannel<String>(input, output));
        peer.onReadTextFile = (params) async {
          handlerStarts += 1;
          return <String, dynamic>{'content': 'unexpected'};
        };
        final pendingResponse = peer.sendRaw('agent/ping', <String, dynamic>{});
        pendingSettled = pendingResponse.then<Object?>(
          (value) => value,
          onError: (Object error, StackTrace _) => error,
        );
        final outboundRequest =
            jsonDecode(output.events.single) as Map<String, dynamic>;
        updateSubscription = peer.sessionUpdates.listen((_) {
          input.add(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': outboundRequest['id'],
              'result': <String, dynamic>{'pong': true},
            }),
          );
          input.add(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': 2,
              'method': 'fs/read_text_file',
              'params': <String, dynamic>{},
            }),
          );
          input.addError(_InputError(), StackTrace.current);
          closing = peer.close();
        });

        try {
          input.add(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'method': 'session/update',
              'params': <String, dynamic>{'sequence': 'U1'},
            }),
          );
        } on Object catch (error) {
          synchronousError = error;
        }
      },
      (Object error, StackTrace _) {
        zoneErrors.add(error);
      },
    );

    try {
      expect(synchronousError, isNull);
      await closing.timeout(const Duration(seconds: 1));
      final pendingResult = await pendingSettled.timeout(
        const Duration(seconds: 1),
      );
      await pumpEventQueue();
      expect(zoneErrors, isEmpty);
      expect(handlerStarts, 0);
      expect(pendingResult, isNot(<String, dynamic>{'pong': true}));
    } finally {
      await updateSubscription.cancel();
      try {
        await peer.close();
      } on Object {
        // The assertions above report any unexpected close error.
      }
    }
  });

  for (final termination in <String>['done', 'error']) {
    test(
      'reentrant response completes before raw $termination termination',
      () async {
        final input = _ManualInputStream();
        final output = _RecordingSink();
        final peer = JsonRpcPeer(StreamChannel<String>(input, output));
        final pendingResponse = peer.sendRaw('agent/ping', <String, dynamic>{});
        unawaited(
          pendingResponse.catchError((Object _) => <String, dynamic>{}),
        );
        final outboundRequest =
            jsonDecode(output.events.single) as Map<String, dynamic>;
        final updateSubscription = peer.sessionUpdates.listen((_) {
          input.add(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': outboundRequest['id'],
              'result': <String, dynamic>{'pong': true},
            }),
          );
          if (termination == 'done') {
            input.close();
          } else {
            input.addError(_InputError(), StackTrace.current);
          }
        });

        try {
          input.add(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'method': 'session/update',
              'params': <String, dynamic>{'sequence': 'U1'},
            }),
          );
          expect(
            await pendingResponse.timeout(const Duration(seconds: 1)),
            <String, dynamic>{'pong': true},
          );
          if (termination == 'done') {
            await peer.close().timeout(const Duration(seconds: 1));
          } else {
            await expectLater(
              peer.close().timeout(const Duration(seconds: 1)),
              throwsA(isA<_InputError>()),
            );
          }
        } finally {
          await updateSubscription.cancel();
          try {
            await peer.close();
          } on Object {
            // The error termination is asserted above.
          }
        }
      },
    );
  }

  for (final termination in <String>['done', 'error']) {
    test(
      '$termination stops queued work and drops late active result',
      () async {
        final input = StreamController<String>(sync: true);
        final output = _RecordingSink();
        final peer = JsonRpcPeer(
          StreamChannel<String>(input.stream, output),
          maxPendingItems: 2,
          maxConcurrentHandlers: 3,
          maxOrdinaryConcurrentHandlers: 1,
        );
        final activeStarted = Completer<void>();
        final releaseActive = Completer<void>();
        var handlerStarts = 0;
        peer.onReadTextFile = (params) async {
          handlerStarts += 1;
          if (handlerStarts == 1) {
            activeStarted.complete();
            await releaseActive.future;
          }
          return <String, dynamic>{'content': 'late'};
        };

        try {
          input.add(
            jsonEncode(<Object?>[
              <String, dynamic>{
                'jsonrpc': '2.0',
                'id': 1,
                'method': 'fs/read_text_file',
                'params': <String, dynamic>{},
              },
              <String, dynamic>{
                'jsonrpc': '2.0',
                'id': 2,
                'method': 'fs/read_text_file',
                'params': <String, dynamic>{},
              },
            ]),
          );
          await activeStarted.future.timeout(const Duration(seconds: 1));
          if (termination == 'done') {
            await input.close();
            await peer.close().timeout(const Duration(seconds: 1));
          } else {
            input.addError(_InputError(), StackTrace.current);
            await expectLater(
              peer.close().timeout(const Duration(seconds: 1)),
              throwsA(isA<_InputError>()),
            );
          }
          expect(handlerStarts, 1);
          expect(output.events, isEmpty);

          releaseActive.complete();
          await pumpEventQueue();
          expect(handlerStarts, 1);
          expect(output.events, isEmpty);
        } finally {
          if (!releaseActive.isCompleted) releaseActive.complete();
          if (!input.isClosed) await input.close();
        }
      },
    );
  }
}

class _RecordingSink implements StreamSink<String> {
  final Completer<void> _done = Completer<void>();
  final List<String> events = <String>[];
  var closeCount = 0;

  @override
  Future<void> get done => _done.future;

  @override
  void add(String event) => events.add(event);

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<String> stream) async {
    await for (final event in stream) {
      add(event);
    }
  }

  @override
  Future<void> close() {
    closeCount += 1;
    if (!_done.isCompleted) _done.complete();
    return _done.future;
  }
}

class _CancelError extends Error {}

class _InputError extends Error {}

class _ManualInputStream extends Stream<String> {
  _ManualSubscription? _subscription;

  void add(String value) => _subscription!.add(value);

  void addError(Object error, StackTrace stackTrace) =>
      _subscription!.addError(error, stackTrace);

  void close() => _subscription!.close();

  @override
  StreamSubscription<String> listen(
    void Function(String event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    if (_subscription != null) {
      throw StateError('Manual input stream supports one listener.');
    }
    return _subscription = _ManualSubscription(onData, onError, onDone);
  }
}

class _ManualSubscription implements StreamSubscription<String> {
  _ManualSubscription(this._onData, this._onError, this._onDone);

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
