import 'dart:async';

import 'package:dart_acp/dart_acp.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/ui/image_decode_budget.dart';

void main() {
  group('AcpImageDecodeCancellationSource', () {
    test(
      'notifies each current listener once and is safe after cancellation',
      () {
        final source = AcpImageDecodeCancellationSource();
        var retainedCalls = 0;
        var removedCalls = 0;
        void retained() => retainedCalls += 1;
        void removed() => removedCalls += 1;

        source.addListener(retained);
        source.addListener(removed);
        source.removeListener(removed);
        source.cancel();
        source.cancel();

        expect(source.isCancelled, isTrue);
        expect(retainedCalls, 1);
        expect(removedCalls, 0);

        var lateCalls = 0;
        void late() => lateCalls += 1;
        source.addListener(late);
        source.removeListener(late);
        expect(lateCalls, 1);
      },
    );

    test('reports a throwing listener but still notifies and clears all', () {
      final source = AcpImageDecodeCancellationSource();
      final listenerError = StateError('listener failed');
      final reported = <Object>[];
      var laterCalls = 0;
      source.addListener(() => throw listenerError);
      source.addListener(() => laterCalls += 1);
      final reportingZone = _reportingZone(reported);

      expect(() => reportingZone.run(source.cancel), returnsNormally);
      source.cancel();

      expect(source.isCancelled, isTrue);
      expect(laterCalls, 1);
      expect(reported, [same(listenerError)]);
    });

    test('a throwing Zone reporter cannot interrupt cancellation cleanup', () {
      final source = AcpImageDecodeCancellationSource();
      var laterCalls = 0;
      var reportCalls = 0;
      final reporterError = StateError('reporter failed');
      final outerReports = <Object>[];
      source.addListener(() => throw StateError('listener failed'));
      source.addListener(() => laterCalls += 1);
      final outerReportingZone = Zone.current.fork(
        specification: ZoneSpecification(
          handleUncaughtError: (_, _, _, error, _) => outerReports.add(error),
        ),
      );

      outerReportingZone.run(() {
        final throwingReportingZone = Zone.current.fork(
          specification: ZoneSpecification(
            handleUncaughtError: (_, _, _, _, _) {
              reportCalls += 1;
              throw reporterError;
            },
          ),
        );
        expect(() => throwingReportingZone.run(source.cancel), returnsNormally);
      });
      expect(source.isCancelled, isTrue);
      expect(laterCalls, 1);
      expect(reportCalls, 1);
      expect(outerReports, [same(reporterError)]);
    });
  });

  group('AcpImageDecodeBudgetLedger', () {
    test(
      'accepts exact global pixels and rejects the first pixel overage',
      () async {
        final exactLedger = AcpImageDecodeBudgetLedger(
          budget: _budget(
            maxConcurrentImageDecodes: 3,
            maxImagePreviewPixelsGlobal: 20,
            maxImageDecodeBytesGlobal: 200,
          ),
        );
        final exactFirst = await exactLedger.acquire(
          decodedBytes: 1,
          cancellation: AcpImageDecodeCancellationSource(),
        );
        exactFirst.shrinkInstalledReservation(
          previewPixels: 0,
          reservedBytes: 1,
        );
        final exactSecond = await exactLedger.acquire(
          decodedBytes: 1,
          cancellation: AcpImageDecodeCancellationSource(),
        );
        final exactThird = await exactLedger.acquire(
          decodedBytes: 1,
          cancellation: AcpImageDecodeCancellationSource(),
        );

        final overLedger = AcpImageDecodeBudgetLedger(
          budget: _budget(
            maxConcurrentImageDecodes: 3,
            maxImagePreviewPixelsGlobal: 20,
            maxImageDecodeBytesGlobal: 200,
          ),
        );
        final overFirst = await overLedger.acquire(
          decodedBytes: 1,
          cancellation: AcpImageDecodeCancellationSource(),
        );
        overFirst.shrinkInstalledReservation(
          previewPixels: 1,
          reservedBytes: 5,
        );
        final overSecond = await overLedger.acquire(
          decodedBytes: 1,
          cancellation: AcpImageDecodeCancellationSource(),
        );

        await expectLater(
          overLedger.acquire(
            decodedBytes: 1,
            cancellation: AcpImageDecodeCancellationSource(),
          ),
          throwsA(
            isA<AcpInputLimitExceeded>()
                .having(
                  (error) => error.resource,
                  'resource',
                  'ACP image preview pixels',
                )
                .having((error) => error.limit, 'limit', 20)
                .having(
                  (error) => error.observedAtLeast,
                  'observedAtLeast',
                  21,
                ),
          ),
        );

        _close(exactFirst);
        _close(exactSecond);
        _close(exactThird);
        _close(overFirst);
        _close(overSecond);
      },
    );

    test(
      'accepts exact global bytes and rejects the first byte overage',
      () async {
        final exactLedger = AcpImageDecodeBudgetLedger(
          budget: _budget(
            maxConcurrentImageDecodes: 2,
            maxImagePreviewPixelsGlobal: 30,
            maxImageDecodeBytesGlobal: 60,
          ),
        );
        final exactFirst = await exactLedger.acquire(
          decodedBytes: 1,
          cancellation: AcpImageDecodeCancellationSource(),
        );
        exactFirst.shrinkInstalledReservation(
          previewPixels: 1,
          reservedBytes: 10,
        );
        final exactSecond = await exactLedger.acquire(
          decodedBytes: 10,
          cancellation: AcpImageDecodeCancellationSource(),
        );

        final overLedger = AcpImageDecodeBudgetLedger(
          budget: _budget(
            maxConcurrentImageDecodes: 2,
            maxImagePreviewPixelsGlobal: 30,
            maxImageDecodeBytesGlobal: 60,
          ),
        );
        final overFirst = await overLedger.acquire(
          decodedBytes: 1,
          cancellation: AcpImageDecodeCancellationSource(),
        );
        overFirst.shrinkInstalledReservation(
          previewPixels: 1,
          reservedBytes: 11,
        );

        await expectLater(
          overLedger.acquire(
            decodedBytes: 10,
            cancellation: AcpImageDecodeCancellationSource(),
          ),
          throwsA(
            isA<AcpInputLimitExceeded>()
                .having(
                  (error) => error.resource,
                  'resource',
                  'ACP image decode bytes',
                )
                .having((error) => error.limit, 'limit', 60)
                .having(
                  (error) => error.observedAtLeast,
                  'observedAtLeast',
                  61,
                ),
          ),
        );

        _close(exactFirst);
        _close(exactSecond);
        _close(overFirst);
      },
    );

    test(
      'capacity failure is immediate instead of joining the decode queue',
      () async {
        final ledger = AcpImageDecodeBudgetLedger(
          budget: _budget(
            maxConcurrentImageDecodes: 1,
            maxImagePreviewPixelsGlobal: 20,
            maxImageDecodeBytesGlobal: 60,
          ),
        );
        final first = await ledger.acquire(
          decodedBytes: 1,
          cancellation: AcpImageDecodeCancellationSource(),
        );
        first.shrinkInstalledReservation(previewPixels: 1, reservedBytes: 11);

        await expectLater(
          ledger.acquire(
            decodedBytes: 10,
            cancellation: AcpImageDecodeCancellationSource(),
          ),
          throwsA(isA<AcpInputLimitExceeded>()),
        );

        _close(first);
      },
    );

    test('grants two decodes and then serves waiters in FIFO order', () async {
      final ledger = AcpImageDecodeBudgetLedger(
        budget: _budget(
          maxConcurrentImageDecodes: 2,
          maxImagePreviewPixelsGlobal: 40,
          maxImageDecodeBytesGlobal: 200,
        ),
      );
      final first = await ledger.acquire(
        decodedBytes: 1,
        cancellation: AcpImageDecodeCancellationSource(),
      );
      final second = await ledger.acquire(
        decodedBytes: 1,
        cancellation: AcpImageDecodeCancellationSource(),
      );
      final order = <int>[];
      final thirdCancellation = _CountingCancellation();
      final thirdFuture = ledger
          .acquire(decodedBytes: 1, cancellation: thirdCancellation)
          .then((reservation) {
            order.add(3);
            return reservation;
          });
      final fourthFuture = ledger
          .acquire(
            decodedBytes: 1,
            cancellation: AcpImageDecodeCancellationSource(),
          )
          .then((reservation) {
            order.add(4);
            return reservation;
          });

      await _flushAsync();
      expect(order, isEmpty);

      second.finishDecode();
      final third = await thirdFuture;
      expect(order, [3]);
      expect(thirdCancellation.addListenerCalls, 1);
      expect(thirdCancellation.removeListenerCalls, 1);

      first.finishDecode();
      final fourth = await fourthFuture;
      expect(order, [3, 4]);

      first.releaseInstalledMemory();
      second.releaseInstalledMemory();
      _close(third);
      _close(fourth);
    });

    test('cancelling a waiter releases its provisional reservation', () async {
      final ledger = AcpImageDecodeBudgetLedger(
        budget: _budget(
          maxConcurrentImageDecodes: 1,
          maxImagePreviewPixelsGlobal: 20,
          maxImageDecodeBytesGlobal: 100,
        ),
      );
      final first = await ledger.acquire(
        decodedBytes: 1,
        cancellation: AcpImageDecodeCancellationSource(),
      );
      final cancelledSource = _CountingCancellation();
      final cancelledFuture = ledger.acquire(
        decodedBytes: 1,
        cancellation: cancelledSource,
      );
      final cancelledExpectation = expectLater(
        cancelledFuture,
        throwsA(isA<AcpImageDecodeCancelled>()),
      );

      cancelledSource.cancel();
      cancelledSource.cancel();
      await cancelledExpectation;
      expect(cancelledSource.addListenerCalls, 1);
      expect(cancelledSource.removeListenerCalls, 1);

      final replacementFuture = ledger.acquire(
        decodedBytes: 1,
        cancellation: AcpImageDecodeCancellationSource(),
      );
      var replacementGranted = false;
      replacementFuture.then((_) => replacementGranted = true);
      await _flushAsync();
      expect(replacementGranted, isFalse);

      first.finishDecode();
      final replacement = await replacementFuture;
      first.releaseInstalledMemory();
      _close(replacement);
    });

    test(
      'addListener failure rolls back and is delivered only by Future',
      () async {
        final ledger = AcpImageDecodeBudgetLedger(
          budget: _budget(
            maxConcurrentImageDecodes: 1,
            maxImagePreviewPixelsGlobal: 20,
            maxImageDecodeBytesGlobal: 100,
          ),
        );
        final first = await ledger.acquire(
          decodedBytes: 1,
          cancellation: AcpImageDecodeCancellationSource(),
        );
        final addError = StateError('addListener failed');
        final hostile = _HostileCancellation(addError: addError);
        late Future<AcpImageDecodeReservation> failed;

        expect(
          () => failed = ledger.acquire(decodedBytes: 1, cancellation: hostile),
          returnsNormally,
        );
        await expectLater(failed, throwsA(same(addError)));
        expect(hostile.addListenerCalls, 1);
        expect(hostile.removeListenerCalls, 1);

        final replacementFuture = ledger.acquire(
          decodedBytes: 1,
          cancellation: AcpImageDecodeCancellationSource(),
        );
        first.finishDecode();
        final replacement = await replacementFuture;
        first.releaseInstalledMemory();
        _close(replacement);
      },
    );

    test(
      'synchronous cancellation followed by add failure has one owned error',
      () async {
        final ledger = AcpImageDecodeBudgetLedger(
          budget: _budget(
            maxConcurrentImageDecodes: 1,
            maxImagePreviewPixelsGlobal: 20,
            maxImageDecodeBytesGlobal: 100,
          ),
        );
        final first = await ledger.acquire(
          decodedBytes: 1,
          cancellation: AcpImageDecodeCancellationSource(),
        );
        final addError = StateError('addListener failed after cancellation');
        final hostile = _HostileCancellation(
          cancelDuringAdd: true,
          addError: addError,
        );
        late Future<AcpImageDecodeReservation> failed;

        expect(
          () => failed = ledger.acquire(decodedBytes: 1, cancellation: hostile),
          returnsNormally,
        );
        await expectLater(failed, throwsA(same(addError)));
        expect(hostile.addListenerCalls, 1);
        expect(hostile.removeListenerCalls, 1);

        final replacementFuture = ledger.acquire(
          decodedBytes: 1,
          cancellation: AcpImageDecodeCancellationSource(),
        );
        first.finishDecode();
        final replacement = await replacementFuture;
        first.releaseInstalledMemory();
        _close(replacement);
      },
    );

    test('removeListener failure cannot block waiter cancellation', () async {
      final ledger = AcpImageDecodeBudgetLedger(
        budget: _budget(
          maxConcurrentImageDecodes: 1,
          maxImagePreviewPixelsGlobal: 20,
          maxImageDecodeBytesGlobal: 100,
        ),
      );
      final first = await ledger.acquire(
        decodedBytes: 1,
        cancellation: AcpImageDecodeCancellationSource(),
      );
      final removeError = StateError('removeListener failed on cancel');
      final hostile = _HostileCancellation(removeError: removeError);
      final reported = <Object>[];
      final reportingZone = _reportingZone(reported);
      final cancelledFuture = ledger.acquire(
        decodedBytes: 1,
        cancellation: hostile,
      );
      final cancelledExpectation = expectLater(
        cancelledFuture,
        throwsA(isA<AcpImageDecodeCancelled>()),
      );

      expect(() => reportingZone.run(hostile.cancel), returnsNormally);
      await cancelledExpectation;

      final replacementFuture = ledger.acquire(
        decodedBytes: 1,
        cancellation: AcpImageDecodeCancellationSource(),
      );
      first.finishDecode();
      final replacement = await replacementFuture;
      first.releaseInstalledMemory();
      _close(replacement);

      expect(reported, [same(removeError)]);
      expect(hostile.removeListenerCalls, 1);
    });

    test('removeListener failure cannot block FIFO grant', () async {
      final ledger = AcpImageDecodeBudgetLedger(
        budget: _budget(
          maxConcurrentImageDecodes: 1,
          maxImagePreviewPixelsGlobal: 20,
          maxImageDecodeBytesGlobal: 100,
        ),
      );
      final first = await ledger.acquire(
        decodedBytes: 1,
        cancellation: AcpImageDecodeCancellationSource(),
      );
      final removeError = StateError('removeListener failed on grant');
      final hostile = _HostileCancellation(removeError: removeError);
      final reported = <Object>[];
      final reportingZone = _reportingZone(reported);
      final waiterFuture = ledger.acquire(
        decodedBytes: 1,
        cancellation: hostile,
      );

      expect(() => reportingZone.run(first.finishDecode), returnsNormally);
      final waiter = await waiterFuture;
      first.releaseInstalledMemory();
      _close(waiter);

      expect(reported, [same(removeError)]);
      expect(hostile.removeListenerCalls, 1);
    });

    test(
      'an already cancelled request neither queues nor consumes capacity',
      () async {
        final ledger = AcpImageDecodeBudgetLedger(
          budget: _budget(
            maxConcurrentImageDecodes: 1,
            maxImagePreviewPixelsGlobal: 10,
            maxImageDecodeBytesGlobal: 50,
          ),
        );
        final cancelled = AcpImageDecodeCancellationSource()..cancel();

        await expectLater(
          ledger.acquire(decodedBytes: 1, cancellation: cancelled),
          throwsA(isA<AcpImageDecodeCancelled>()),
        );

        final reservation = await ledger.acquire(
          decodedBytes: 10,
          cancellation: AcpImageDecodeCancellationSource(),
        );
        _close(reservation);
      },
    );

    test(
      'installed reservation can only shrink and failed changes are atomic',
      () async {
        final ledger = AcpImageDecodeBudgetLedger(
          budget: _budget(
            maxConcurrentImageDecodes: 2,
            maxImagePreviewPixelsGlobal: 14,
            maxImageDecodeBytesGlobal: 80,
          ),
        );
        final first = await ledger.acquire(
          decodedBytes: 10,
          cancellation: AcpImageDecodeCancellationSource(),
        );

        first.shrinkInstalledReservation(previewPixels: 4, reservedBytes: 30);
        expect(
          () => first.shrinkInstalledReservation(
            previewPixels: 5,
            reservedBytes: 30,
          ),
          throwsArgumentError,
        );
        expect(
          () => first.shrinkInstalledReservation(
            previewPixels: 4,
            reservedBytes: 31,
          ),
          throwsArgumentError,
        );
        expect(
          () => first.shrinkInstalledReservation(
            previewPixels: 4,
            reservedBytes: 25,
          ),
          throwsArgumentError,
        );

        final second = await ledger.acquire(
          decodedBytes: 10,
          cancellation: AcpImageDecodeCancellationSource(),
        );
        await expectLater(
          ledger.acquire(
            decodedBytes: 1,
            cancellation: AcpImageDecodeCancellationSource(),
          ),
          throwsA(
            isA<AcpInputLimitExceeded>().having(
              (error) => error.observedAtLeast,
              'observedAtLeast',
              15,
            ),
          ),
        );

        _close(first);
        _close(second);
      },
    );

    test(
      'invalid decoded byte counts do not consume ledger capacity',
      () async {
        final ledger = AcpImageDecodeBudgetLedger(
          budget: _budget(
            maxConcurrentImageDecodes: 1,
            maxImagePreviewPixelsGlobal: 10,
            maxImageDecodeBytesGlobal: 50,
          ),
        );

        await expectLater(
          ledger.acquire(
            decodedBytes: -1,
            cancellation: AcpImageDecodeCancellationSource(),
          ),
          throwsRangeError,
        );
        await expectLater(
          ledger.acquire(
            decodedBytes: 11,
            cancellation: AcpImageDecodeCancellationSource(),
          ),
          throwsA(
            isA<AcpInputLimitExceeded>()
                .having(
                  (error) => error.resource,
                  'resource',
                  'ACP image decoded bytes',
                )
                .having((error) => error.limit, 'limit', 10)
                .having(
                  (error) => error.observedAtLeast,
                  'observedAtLeast',
                  11,
                ),
          ),
        );

        final exact = await ledger.acquire(
          decodedBytes: 10,
          cancellation: AcpImageDecodeCancellationSource(),
        );
        _close(exact);
      },
    );

    test(
      'finish releases only concurrency and memory stays installed',
      () async {
        final ledger = AcpImageDecodeBudgetLedger(
          budget: _budget(
            maxConcurrentImageDecodes: 1,
            maxImagePreviewPixelsGlobal: 20,
            maxImageDecodeBytesGlobal: 100,
          ),
        );
        final first = await ledger.acquire(
          decodedBytes: 1,
          cancellation: AcpImageDecodeCancellationSource(),
        );
        final secondFuture = ledger.acquire(
          decodedBytes: 1,
          cancellation: AcpImageDecodeCancellationSource(),
        );

        first.finishDecode();
        final second = await secondFuture;
        expect(first.decodeFinished, isTrue);
        expect(first.installedMemoryReleased, isFalse);
        await expectLater(
          ledger.acquire(
            decodedBytes: 1,
            cancellation: AcpImageDecodeCancellationSource(),
          ),
          throwsA(isA<AcpInputLimitExceeded>()),
        );

        first.releaseInstalledMemory();
        final thirdFuture = ledger.acquire(
          decodedBytes: 1,
          cancellation: AcpImageDecodeCancellationSource(),
        );
        second.finishDecode();
        final third = await thirdFuture;

        second.releaseInstalledMemory();
        _close(third);
      },
    );

    test(
      'memory release does not release the decode concurrency slot',
      () async {
        final ledger = AcpImageDecodeBudgetLedger(
          budget: _budget(
            maxConcurrentImageDecodes: 1,
            maxImagePreviewPixelsGlobal: 20,
            maxImageDecodeBytesGlobal: 100,
          ),
        );
        final first = await ledger.acquire(
          decodedBytes: 1,
          cancellation: AcpImageDecodeCancellationSource(),
        );
        first.releaseInstalledMemory();
        final secondFuture = ledger.acquire(
          decodedBytes: 1,
          cancellation: AcpImageDecodeCancellationSource(),
        );
        var secondGranted = false;
        secondFuture.then((_) => secondGranted = true);

        await _flushAsync();
        expect(secondGranted, isFalse);

        first.finishDecode();
        final second = await secondFuture;
        _close(second);
      },
    );

    test(
      'double terminal release is idempotent and never makes capacity negative',
      () async {
        final ledger = AcpImageDecodeBudgetLedger(
          budget: _budget(
            maxConcurrentImageDecodes: 1,
            maxImagePreviewPixelsGlobal: 20,
            maxImageDecodeBytesGlobal: 100,
          ),
        );
        final first = await ledger.acquire(
          decodedBytes: 1,
          cancellation: AcpImageDecodeCancellationSource(),
        );

        first.finishDecode();
        first.finishDecode();
        first.releaseInstalledMemory();
        first.releaseInstalledMemory();

        final second = await ledger.acquire(
          decodedBytes: 1,
          cancellation: AcpImageDecodeCancellationSource(),
        );
        final thirdFuture = ledger.acquire(
          decodedBytes: 1,
          cancellation: AcpImageDecodeCancellationSource(),
        );
        var thirdGranted = false;
        thirdFuture.then((_) => thirdGranted = true);
        await _flushAsync();
        expect(thirdGranted, isFalse);

        second.finishDecode();
        final third = await thirdFuture;
        await expectLater(
          ledger.acquire(
            decodedBytes: 1,
            cancellation: AcpImageDecodeCancellationSource(),
          ),
          throwsA(isA<AcpInputLimitExceeded>()),
        );

        second.releaseInstalledMemory();
        _close(third);
      },
    );
  });
}

AcpInputBudget _budget({
  required int maxConcurrentImageDecodes,
  required int maxImagePreviewPixelsGlobal,
  required int maxImageDecodeBytesGlobal,
}) => AcpInputBudget(
  maxEmbeddedMediaBytes: 10,
  maxImagePixels: 100,
  maxImagePreviewPixels: 10,
  maxConcurrentImageDecodes: maxConcurrentImageDecodes,
  maxImagePreviewPixelsGlobal: maxImagePreviewPixelsGlobal,
  maxImageDecodeBytesGlobal: maxImageDecodeBytesGlobal,
);

Future<void> _flushAsync() => Future<void>.delayed(Duration.zero);

Zone _reportingZone(List<Object> reported) => Zone.current.fork(
  specification: ZoneSpecification(
    handleUncaughtError: (_, _, _, error, _) => reported.add(error),
  ),
);

void _close(AcpImageDecodeReservation reservation) {
  reservation.finishDecode();
  reservation.releaseInstalledMemory();
}

final class _CountingCancellation implements AcpImageDecodeCancellation {
  final Set<void Function()> _listeners = <void Function()>{};
  var _cancelled = false;
  var addListenerCalls = 0;
  var removeListenerCalls = 0;

  @override
  bool get isCancelled => _cancelled;

  @override
  void addListener(void Function() listener) {
    addListenerCalls += 1;
    if (_cancelled) {
      listener();
    } else {
      _listeners.add(listener);
    }
  }

  @override
  void removeListener(void Function() listener) {
    removeListenerCalls += 1;
    _listeners.remove(listener);
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final listener in List<void Function()>.of(_listeners)) {
      listener();
    }
    _listeners.clear();
  }
}

final class _HostileCancellation implements AcpImageDecodeCancellation {
  _HostileCancellation({
    this.cancelDuringAdd = false,
    this.addError,
    this.removeError,
  });

  final bool cancelDuringAdd;
  final Object? addError;
  final Object? removeError;
  void Function()? _listener;
  var _cancelled = false;
  var addListenerCalls = 0;
  var removeListenerCalls = 0;

  @override
  bool get isCancelled => _cancelled;

  @override
  void addListener(void Function() listener) {
    addListenerCalls += 1;
    _listener = listener;
    if (cancelDuringAdd) {
      _cancelled = true;
      listener();
    }
    final error = addError;
    if (error != null) throw error;
  }

  @override
  void removeListener(void Function() listener) {
    removeListenerCalls += 1;
    final error = removeError;
    if (error != null) throw error;
    if (identical(_listener, listener)) _listener = null;
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _listener?.call();
  }
}
