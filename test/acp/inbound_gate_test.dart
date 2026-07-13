import 'dart:async';

import 'package:dart_acp/src/rpc/inbound_gate.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('gate limits must be positive and preserve two reserved slots', () {
    expect(() => InboundGate(maxPendingItems: 0), throwsArgumentError);
    expect(() => InboundGate(maxPendingBytes: 0), throwsArgumentError);
    expect(() => InboundGate(maxConcurrentHandlers: 0), throwsArgumentError);
    expect(
      () => InboundGate(
        maxConcurrentHandlers: 3,
        maxOrdinaryConcurrentHandlers: 0,
      ),
      throwsArgumentError,
    );
    expect(
      () => InboundGate(
        maxConcurrentHandlers: 4,
        maxOrdinaryConcurrentHandlers: 3,
      ),
      throwsArgumentError,
    );
  });

  test('batch item admission is exact and atomic', () {
    final gate = InboundGate(maxPendingItems: 2);
    final accepted = gate.tryReserveBatch(const <InboundGateElement>[
      InboundGateElement(method: 'fs/read_text_file', byteLength: 1),
      InboundGateElement(method: 'terminal/kill', byteLength: 1),
    ]);

    expect(accepted, hasLength(2));
    expect(gate.pendingItems, 2);
    expect(
      gate.tryReserveBatch(const <InboundGateElement>[
        InboundGateElement(method: 'terminal/release', byteLength: 1),
      ]),
      isNull,
    );
    expect(gate.pendingItems, 2);

    for (final reservation in accepted!) {
      reservation.release();
    }
    expect(gate.pendingItems, 0);
  });

  test('batch byte admission is exact and atomic', () {
    final gate = InboundGate(maxPendingBytes: 5);
    final accepted = gate.tryReserveBatch(const <InboundGateElement>[
      InboundGateElement(method: 'fs/read_text_file', byteLength: 2),
      InboundGateElement(method: 'terminal/kill', byteLength: 3),
    ]);

    expect(accepted, hasLength(2));
    expect(gate.pendingBytes, 5);
    expect(
      gate.tryReserveBatch(const <InboundGateElement>[
        InboundGateElement(method: 'terminal/release', byteLength: 1),
      ]),
      isNull,
    );
    expect(gate.pendingBytes, 5);

    for (final reservation in accepted!) {
      reservation.release();
    }
    expect(gate.pendingBytes, 0);
  });

  test('invalid element bytes do not partially reserve a batch', () {
    final gate = InboundGate();

    expect(
      () => gate.tryReserveBatch(const <InboundGateElement>[
        InboundGateElement(method: 'fs/read_text_file', byteLength: 1),
        InboundGateElement(method: 'fs/write_text_file', byteLength: 0),
      ]),
      throwsArgumentError,
    );
    expect(gate.pendingItems, 0);
    expect(gate.pendingBytes, 0);
  });

  test('unused reservation release is idempotent', () {
    final gate = InboundGate();
    final reservation = gate.tryReserveBatch(const <InboundGateElement>[
      InboundGateElement(method: 'fs/read_text_file', byteLength: 3),
    ])!.single;

    reservation.release();
    reservation.release();

    expect(gate.pendingItems, 0);
    expect(gate.pendingBytes, 0);
  });

  test(
    'active handler retains its pending reservation until completion',
    () async {
      final gate = InboundGate(maxPendingItems: 1);
      final reservation = gate.tryReserveBatch(const <InboundGateElement>[
        InboundGateElement(method: 'fs/read_text_file', byteLength: 7),
      ])!.single;
      final releaseHandler = Completer<void>();
      final started = Completer<void>();

      final running = reservation.run(() async {
        started.complete();
        await releaseHandler.future;
        return 'done';
      });
      await started.future;

      expect(gate.pendingItems, 1);
      expect(gate.pendingBytes, 7);
      expect(gate.activeHandlers, 1);
      expect(
        gate.tryReserveBatch(const <InboundGateElement>[
          InboundGateElement(method: 'terminal/kill', byteLength: 1),
        ]),
        isNull,
      );

      releaseHandler.complete();
      expect(await running, 'done');
      expect(gate.pendingItems, 0);
      expect(gate.pendingBytes, 0);
      expect(gate.activeHandlers, 0);
    },
  );

  test('sync and async handler failures release their reservations', () async {
    final gate = InboundGate();
    final reservations = gate.tryReserveBatch(const <InboundGateElement>[
      InboundGateElement(method: 'fs/read_text_file', byteLength: 2),
      InboundGateElement(method: 'fs/write_text_file', byteLength: 3),
    ])!;

    await expectLater(
      reservations[0].run<void>(() => throw StateError('sync failure')),
      throwsStateError,
    );
    await expectLater(
      reservations[1].run<void>(() async {
        await Future<void>.delayed(Duration.zero);
        throw StateError('async failure');
      }),
      throwsStateError,
    );

    expect(gate.pendingItems, 0);
    expect(gate.pendingBytes, 0);
    expect(gate.activeHandlers, 0);
  });

  test('reserved controls bypass only an ineligible ordinary waiter', () async {
    final gate = InboundGate();
    final blockers = List<Completer<void>>.generate(
      14,
      (_) => Completer<void>(),
    );
    final ordinaryStarted = <int>[];
    final controlStarted = <String>[];
    final ordinaryReservations = gate.tryReserveBatch(
      List<InboundGateElement>.generate(
        15,
        (_) => const InboundGateElement(
          method: 'fs/read_text_file',
          byteLength: 1,
        ),
      ),
    )!;

    final running = <Future<void>>[];
    for (var index = 0; index < 14; index++) {
      running.add(
        ordinaryReservations[index].run(() async {
          ordinaryStarted.add(index);
          await blockers[index].future;
        }),
      );
    }
    final queuedOrdinary = ordinaryReservations.last.run(() {
      ordinaryStarted.add(14);
    });

    final controls = gate.tryReserveBatch(const <InboundGateElement>[
      InboundGateElement(method: 'terminal/kill', byteLength: 1),
      InboundGateElement(method: 'terminal/release', byteLength: 1),
    ])!;
    final kill = controls[0].run(() => controlStarted.add('kill'));
    final release = controls[1].run(() => controlStarted.add('release'));
    await _waitFor(() => controlStarted.length == 2);

    expect(ordinaryStarted, List<int>.generate(14, (index) => index));
    expect(controlStarted, <String>['kill', 'release']);
    expect(gate.activeHandlers, 14);

    blockers[0].complete();
    await queuedOrdinary;
    expect(ordinaryStarted.last, 14);

    for (var index = 1; index < blockers.length; index++) {
      blockers[index].complete();
    }
    await Future.wait<void>(<Future<void>>[...running, kill, release]);
  });

  test(
    'later reserved control does not steal an eligible ordinary slot',
    () async {
      final gate = InboundGate(
        maxConcurrentHandlers: 3,
        maxOrdinaryConcurrentHandlers: 1,
      );
      final reservations = gate.tryReserveBatch(const <InboundGateElement>[
        InboundGateElement(method: 'fs/read_text_file', byteLength: 1),
        InboundGateElement(method: 'terminal/kill', byteLength: 1),
        InboundGateElement(method: 'terminal/release', byteLength: 1),
        InboundGateElement(method: 'fs/write_text_file', byteLength: 1),
        InboundGateElement(method: 'terminal/kill', byteLength: 1),
      ])!;
      final releaseActiveOrdinary = Completer<void>();
      final releaseFirstControl = Completer<void>();
      final releaseSecondControl = Completer<void>();
      final starts = <String>[];

      final activeOrdinary = reservations[0].run(() async {
        starts.add('active-ordinary');
        await releaseActiveOrdinary.future;
      });
      final firstControl = reservations[1].run(() async {
        starts.add('first-control');
        await releaseFirstControl.future;
      });
      final secondControl = reservations[2].run(() async {
        starts.add('second-control');
        await releaseSecondControl.future;
      });
      final queuedOrdinary = reservations[3].run(() {
        starts.add('queued-ordinary');
      });
      final queuedControl = reservations[4].run(() {
        starts.add('queued-control');
      });
      await _waitFor(() => starts.length == 3);

      releaseActiveOrdinary.complete();
      await queuedOrdinary;
      expect(starts[3], 'queued-ordinary');
      expect(starts[4], 'queued-control');

      releaseFirstControl.complete();
      await queuedControl;
      releaseSecondControl.complete();
      await Future.wait<void>(<Future<void>>[
        activeOrdinary,
        firstControl,
        secondControl,
      ]);
    },
  );

  test('session update runs synchronously without a handler permit', () async {
    final gate = InboundGate(
      maxConcurrentHandlers: 3,
      maxOrdinaryConcurrentHandlers: 1,
    );
    final reservations = gate.tryReserveBatch(const <InboundGateElement>[
      InboundGateElement(method: 'fs/read_text_file', byteLength: 1),
      InboundGateElement(method: 'session/update', byteLength: 1),
    ])!;
    final releaseOrdinary = Completer<void>();
    final ordinaryStarted = Completer<void>();
    final ordinary = reservations[0].run(() async {
      ordinaryStarted.complete();
      await releaseOrdinary.future;
    });
    await ordinaryStarted.future;

    var updateRan = false;
    reservations[1].runSync(() {
      updateRan = true;
    });

    expect(updateRan, isTrue);
    expect(gate.activeHandlers, 1);
    expect(gate.pendingItems, 1);
    releaseOrdinary.complete();
    await ordinary;
    expect(gate.pendingItems, 0);
  });

  test(
    'close clears queued work without waiting for an active handler',
    () async {
      final gate = InboundGate(
        maxConcurrentHandlers: 3,
        maxOrdinaryConcurrentHandlers: 1,
      );
      final reservations = gate.tryReserveBatch(const <InboundGateElement>[
        InboundGateElement(method: 'fs/read_text_file', byteLength: 1),
        InboundGateElement(method: 'fs/write_text_file', byteLength: 1),
      ])!;
      final releaseActive = Completer<void>();
      final activeStarted = Completer<void>();
      var queuedStarted = false;
      final active = reservations[0].run(() async {
        activeStarted.complete();
        await releaseActive.future;
      });
      final queued = reservations[1].run(() {
        queuedStarted = true;
      });
      await activeStarted.future;

      final queuedFailure = expectLater(queued, throwsStateError);
      final firstClose = gate.close();
      final secondClose = gate.close();
      expect(identical(firstClose, secondClose), isTrue);
      await firstClose.timeout(const Duration(seconds: 1));
      expect(queuedStarted, isFalse);
      await queuedFailure;
      expect(gate.pendingItems, 1);
      expect(
        gate.tryReserveBatch(const <InboundGateElement>[
          InboundGateElement(method: 'terminal/kill', byteLength: 1),
        ]),
        isNull,
      );

      releaseActive.complete();
      await active;
      expect(gate.pendingItems, 0);
    },
  );
}

Future<void> _waitFor(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 1));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Condition not met before timeout.');
    }
    await Future<void>.delayed(Duration.zero);
  }
}
