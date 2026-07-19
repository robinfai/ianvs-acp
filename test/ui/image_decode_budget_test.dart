import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ianvs_acp/acp/acp_input_budget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/ui/components/bounded_image_preview.dart';
import 'package:ianvs_acp/ui/image_decode_budget.dart';

void main() {
  group('BoundedImagePreview', () {
    testWidgets(
      'rejects invalid and oversized Base64 before decoder or ledger',
      (tester) async {
        const budget = AcpInputBudget(
          maxEmbeddedMediaBytes: 1,
          maxImageDimension: 2,
          maxImagePixels: 4,
          maxImagePreviewPixels: 4,
          maxImagePreviewPixelsGlobal: 4,
          maxImageDecodeBytesGlobal: 17,
        );
        final decoder = _FakeBoundedImageDecoder();
        var acquireCalls = 0;

        Future<AcpImageDecodeReservation> acquire({
          required int decodedBytes,
          required AcpImageDecodeCancellation cancellation,
        }) {
          acquireCalls += 1;
          throw StateError('ledger must not be called');
        }

        for (final data in const <String>['not-base64', 'YWE=']) {
          await tester.pumpWidget(
            MaterialApp(
              home: BoundedImagePreview(
                data: data,
                inputBudget: budget,
                decoder: decoder,
                reservationAcquirer: acquire,
              ),
            ),
          );
          await tester.pump();

          expect(find.text('Image preview unavailable.'), findsOneWidget);
        }

        expect(decoder.createBufferCalls, 0);
        expect(acquireCalls, 0);
      },
    );

    testWidgets(
      'downsamples proportionally, takes one frame, and releases exactly once',
      (tester) async {
        const budget = AcpInputBudget(
          maxEmbeddedMediaBytes: 1,
          maxImageDimension: 4,
          maxImagePixels: 8,
          maxImagePreviewPixels: 4,
          maxImagePreviewPixelsGlobal: 4,
          maxImageDecodeBytesGlobal: 17,
        );
        final image = await _testImage(2, 1);
        final decoder = _FakeBoundedImageDecoder(
          width: 4,
          height: 2,
          frameImage: image,
        );
        final reservation = _CountingImageReservation();
        var acquireCalls = 0;
        Future<AcpImageDecodeReservation> acquire({
          required int decodedBytes,
          required AcpImageDecodeCancellation cancellation,
        }) async {
          acquireCalls += 1;
          expect(decodedBytes, 1);
          return reservation;
        }

        Widget preview() => MaterialApp(
          home: BoundedImagePreview(
            data: 'YQ==',
            inputBudget: budget,
            decoder: decoder,
            reservationAcquirer: acquire,
          ),
        );

        await tester.pumpWidget(preview());
        await tester.pumpAndSettle();

        expect(find.byKey(const ValueKey('bounded-image-preview')), findsOne);
        expect(decoder.createBufferCalls, 1);
        expect(decoder.createDescriptorCalls, 1);
        expect(decoder.createCodecCalls, 1);
        expect(decoder.getFirstFrameCalls, 1);
        expect(decoder.targets, const [(width: 2, height: 1)]);
        expect(decoder.buffers.single.disposeCalls, 1);
        expect(decoder.descriptors.single.disposeCalls, 1);
        expect(decoder.codecs.single.disposeCalls, 1);
        expect(decoder.frames.single.takeImageCalls, 1);
        expect(decoder.frames.single.disposeCalls, 1);
        expect(reservation.shrinks, const [(pixels: 2, bytes: 9)]);
        expect(reservation.finishCalls, 1);
        expect(reservation.releaseCalls, 0);
        expect(image.debugDisposed, isFalse);

        await tester.pumpWidget(preview());
        await tester.pumpAndSettle();
        expect(acquireCalls, 1, reason: 'same content must not decode again');

        await tester.pumpWidget(const SizedBox.shrink());
        expect(image.debugDisposed, isTrue);
        expect(reservation.finishCalls, 1);
        expect(reservation.releaseCalls, 1);
      },
    );

    testWidgets('handles an extreme aspect ratio without iterative fallback', (
      tester,
    ) async {
      const sourceWidth = 1000000000000;
      const budget = AcpInputBudget(
        maxEmbeddedMediaBytes: 1,
        maxImageDimension: sourceWidth,
        maxImagePixels: sourceWidth,
        maxImagePreviewPixels: 1,
        maxImagePreviewPixelsGlobal: 1,
        maxImageDecodeBytesGlobal: 5,
      );
      final image = await _testImage(1, 1);
      final decoder = _FakeBoundedImageDecoder(
        width: sourceWidth,
        height: 1,
        frameImage: image,
      );
      final reservation = _CountingImageReservation();

      await tester.pumpWidget(
        MaterialApp(
          home: BoundedImagePreview(
            data: 'YQ==',
            inputBudget: budget,
            decoder: decoder,
            reservationAcquirer:
                ({
                  required int decodedBytes,
                  required AcpImageDecodeCancellation cancellation,
                }) async => reservation,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(decoder.targets, const [(width: 1, height: 1)]);
      expect(reservation.shrinks, const [(pixels: 1, bytes: 5)]);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('production decoder smoke releases every native handle', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final source = await _testImage(1, 1);
        final png = await source.toByteData(format: ui.ImageByteFormat.png);
        source.dispose();
        final bytes = base64Decode(base64Encode(png!.buffer.asUint8List()));
        const decoder = DartUiBoundedImageDecoder();
        BoundedImageBuffer? buffer;
        BoundedImageDescriptor? descriptor;
        BoundedImageCodec? codec;
        BoundedImageFrame? frame;
        ui.Image? image;
        try {
          buffer = await decoder.createBuffer(bytes);
          descriptor = await decoder.createDescriptor(buffer);
          expect(descriptor.width, 1);
          expect(descriptor.height, 1);
          codec = await decoder.createCodec(
            descriptor,
            targetWidth: 1,
            targetHeight: 1,
          );
          frame = await decoder.getFirstFrame(codec);
          image = frame.takeImage();
          expect(image.width, 1);
          expect(image.height, 1);
        } finally {
          image?.dispose();
          frame?.dispose();
          codec?.dispose();
          descriptor?.dispose();
          buffer?.dispose();
        }
      });
    });

    for (final testCase in const <({String name, int width, int height})>[
      (name: 'zero width', width: 0, height: 1),
      (name: 'zero height', width: 1, height: 0),
      (name: 'dimension +1', width: 5, height: 1),
      (name: 'pixels +1', width: 3, height: 3),
    ]) {
      testWidgets('rejects ${testCase.name} before codec creation', (
        tester,
      ) async {
        const budget = AcpInputBudget(
          maxEmbeddedMediaBytes: 1,
          maxImageDimension: 4,
          maxImagePixels: 8,
          maxImagePreviewPixels: 8,
          maxImagePreviewPixelsGlobal: 8,
          maxImageDecodeBytesGlobal: 33,
        );
        final decoder = _FakeBoundedImageDecoder(
          width: testCase.width,
          height: testCase.height,
        );
        final reservation = _CountingImageReservation();

        await tester.pumpWidget(
          MaterialApp(
            home: BoundedImagePreview(
              data: 'YQ==',
              inputBudget: budget,
              decoder: decoder,
              reservationAcquirer:
                  ({
                    required int decodedBytes,
                    required AcpImageDecodeCancellation cancellation,
                  }) async => reservation,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Image preview unavailable.'), findsOneWidget);
        expect(decoder.createCodecCalls, 0);
        expect(decoder.buffers.single.disposeCalls, 1);
        expect(decoder.descriptors.single.disposeCalls, 1);
        expect(reservation.finishCalls, 1);
        expect(reservation.releaseCalls, 1);
      });
    }

    for (final stage in _DecodeStage.values) {
      testWidgets(
        'stale generation at ${stage.name} releases every owner once',
        (tester) async {
          final image = await _testImage(1, 1);
          addTearDown(() {
            if (!image.debugDisposed) image.dispose();
          });
          final gate = Completer<void>();
          final decoder = _FakeBoundedImageDecoder(
            width: 1,
            height: 1,
            frameImage: image,
          )..gate(stage, gate);
          final reservation = _CountingImageReservation();
          AcpImageDecodeCancellation? observedCancellation;

          await tester.pumpWidget(
            MaterialApp(
              home: BoundedImagePreview(
                data: 'YQ==',
                decoder: decoder,
                reservationAcquirer:
                    ({
                      required int decodedBytes,
                      required AcpImageDecodeCancellation cancellation,
                    }) async {
                      observedCancellation = cancellation;
                      return reservation;
                    },
              ),
            ),
          );
          await tester.pump();
          await tester.pumpWidget(const SizedBox.shrink());
          expect(observedCancellation!.isCancelled, isTrue);

          gate.complete();
          await tester.pump();
          await tester.pump();

          expect(reservation.finishCalls, 1);
          expect(reservation.releaseCalls, 1);
          for (final handle in decoder.buffers) {
            expect(handle.disposeCalls, 1);
          }
          for (final handle in decoder.descriptors) {
            expect(handle.disposeCalls, 1);
          }
          for (final handle in decoder.codecs) {
            expect(handle.disposeCalls, 1);
          }
          for (final handle in decoder.frames) {
            expect(handle.disposeCalls, 1);
          }
          if (stage == _DecodeStage.frame) expect(image.debugDisposed, isTrue);
        },
      );
    }

    for (final stage in _DecodeStage.values) {
      testWidgets('failure at ${stage.name} disposes prior handles once', (
        tester,
      ) async {
        final error = StateError('IMAGE_FAILURE_CANARY_${stage.name}');
        final decoder = _FakeBoundedImageDecoder(
          width: 1,
          height: 1,
          failStage: stage,
          stageError: error,
        );
        final reservation = _CountingImageReservation();

        await tester.pumpWidget(
          MaterialApp(
            home: BoundedImagePreview(
              data: 'YQ==',
              decoder: decoder,
              reservationAcquirer:
                  ({
                    required int decodedBytes,
                    required AcpImageDecodeCancellation cancellation,
                  }) async => reservation,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Image preview unavailable.'), findsOneWidget);
        expect(find.textContaining('IMAGE_FAILURE_CANARY'), findsNothing);
        expect(find.textContaining('YQ=='), findsNothing);
        for (final handle in decoder.buffers) {
          expect(handle.disposeCalls, 1);
        }
        for (final handle in decoder.descriptors) {
          expect(handle.disposeCalls, 1);
        }
        for (final handle in decoder.codecs) {
          expect(handle.disposeCalls, 1);
        }
        expect(reservation.finishCalls, 1);
        expect(reservation.releaseCalls, 1);
      });
    }

    testWidgets('replacing an installed image releases the previous owners', (
      tester,
    ) async {
      final firstImage = await _testImage(1, 1);
      final secondImage = await _testImage(1, 1);
      final firstDecoder = _FakeBoundedImageDecoder(
        width: 1,
        height: 1,
        frameImage: firstImage,
      );
      final secondDecoder = _FakeBoundedImageDecoder(
        width: 1,
        height: 1,
        frameImage: secondImage,
      );
      final firstReservation = _CountingImageReservation();
      final secondReservation = _CountingImageReservation();

      Widget preview({
        required String data,
        required BoundedImageDecoder decoder,
        required AcpImageDecodeReservation reservation,
      }) => MaterialApp(
        home: BoundedImagePreview(
          data: data,
          decoder: decoder,
          reservationAcquirer:
              ({
                required int decodedBytes,
                required AcpImageDecodeCancellation cancellation,
              }) async => reservation,
        ),
      );

      await tester.pumpWidget(
        preview(
          data: 'YQ==',
          decoder: firstDecoder,
          reservation: firstReservation,
        ),
      );
      await tester.pumpAndSettle();
      expect(firstImage.debugDisposed, isFalse);

      await tester.pumpWidget(
        preview(
          data: 'Yg==',
          decoder: secondDecoder,
          reservation: secondReservation,
        ),
      );
      expect(firstImage.debugDisposed, isTrue);
      expect(firstReservation.releaseCalls, 1);
      await tester.pumpAndSettle();
      expect(secondImage.debugDisposed, isFalse);

      await tester.pumpWidget(const SizedBox.shrink());
      expect(secondImage.debugDisposed, isTrue);
      expect(secondReservation.releaseCalls, 1);
    });

    testWidgets('hostile cleanup cannot block later owners or lease release', (
      tester,
    ) async {
      final image = await _testImage(1, 1);
      final decoder = _FakeBoundedImageDecoder(
        width: 1,
        height: 1,
        frameImage: image,
        throwOnDispose: true,
      );
      final reservation = _CountingImageReservation(
        throwOnFinish: true,
        throwOnRelease: true,
      );
      final reported = <Object>[];
      final reportingZone = _reportingZone(reported);

      await reportingZone.run(() async {
        await tester.pumpWidget(
          MaterialApp(
            home: BoundedImagePreview(
              data: 'YQ==',
              decoder: decoder,
              reservationAcquirer:
                  ({
                    required int decodedBytes,
                    required AcpImageDecodeCancellation cancellation,
                  }) async => reservation,
            ),
          ),
        );
        for (var index = 0; index < 6; index += 1) {
          await tester.pump();
        }
        expect(find.byKey(const ValueKey('bounded-image-preview')), findsOne);
        await tester.pumpWidget(const SizedBox.shrink());
      });

      expect(decoder.buffers.single.disposeCalls, 1);
      expect(decoder.descriptors.single.disposeCalls, 1);
      expect(decoder.codecs.single.disposeCalls, 1);
      expect(decoder.frames.single.disposeCalls, 1);
      expect(reservation.finishCalls, 1);
      expect(reservation.releaseCalls, 1);
      expect(image.debugDisposed, isTrue);
      expect(reported, hasLength(6));
    });

    testWidgets('cancels a queued waiter and closes a late reservation once', (
      tester,
    ) async {
      final reservationCompleter = Completer<AcpImageDecodeReservation>();
      final reservation = _CountingImageReservation();
      AcpImageDecodeCancellation? observedCancellation;
      final decoder = _FakeBoundedImageDecoder(width: 1, height: 1);

      await tester.pumpWidget(
        MaterialApp(
          home: BoundedImagePreview(
            data: 'YQ==',
            decoder: decoder,
            reservationAcquirer:
                ({
                  required int decodedBytes,
                  required AcpImageDecodeCancellation cancellation,
                }) {
                  observedCancellation = cancellation;
                  return reservationCompleter.future;
                },
          ),
        ),
      );
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      expect(observedCancellation!.isCancelled, isTrue);

      reservationCompleter.complete(reservation);
      await tester.pump();
      await tester.pump();

      expect(decoder.createBufferCalls, 0);
      expect(reservation.finishCalls, 1);
      expect(reservation.releaseCalls, 1);
    });
  });

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

enum _DecodeStage { buffer, descriptor, codec, frame }

final class _FakeBoundedImageDecoder implements BoundedImageDecoder {
  _FakeBoundedImageDecoder({
    this.width = 1,
    this.height = 1,
    this.frameImage,
    this.failStage,
    this.stageError,
    this.throwOnDispose = false,
  });

  final int width;
  final int height;
  final ui.Image? frameImage;
  final _DecodeStage? failStage;
  final Object? stageError;
  final bool throwOnDispose;
  final Map<_DecodeStage, Completer<void>> _gates =
      <_DecodeStage, Completer<void>>{};
  final List<_FakeImageBuffer> buffers = <_FakeImageBuffer>[];
  final List<_FakeImageDescriptor> descriptors = <_FakeImageDescriptor>[];
  final List<_FakeImageCodec> codecs = <_FakeImageCodec>[];
  final List<_FakeImageFrame> frames = <_FakeImageFrame>[];
  final List<({int width, int height})> targets = <({int width, int height})>[];
  var createBufferCalls = 0;
  var createDescriptorCalls = 0;
  var createCodecCalls = 0;
  var getFirstFrameCalls = 0;

  void gate(_DecodeStage stage, Completer<void> gate) {
    _gates[stage] = gate;
  }

  Future<void> _wait(_DecodeStage stage) async {
    final gate = _gates[stage];
    if (gate != null) await gate.future;
    if (failStage == stage) {
      throw stageError ?? StateError('decode stage failed');
    }
  }

  @override
  Future<BoundedImageBuffer> createBuffer(Uint8List bytes) async {
    createBufferCalls += 1;
    await _wait(_DecodeStage.buffer);
    final buffer = _FakeImageBuffer(throwOnDispose: throwOnDispose);
    buffers.add(buffer);
    return buffer;
  }

  @override
  Future<BoundedImageDescriptor> createDescriptor(
    BoundedImageBuffer buffer,
  ) async {
    createDescriptorCalls += 1;
    await _wait(_DecodeStage.descriptor);
    final descriptor = _FakeImageDescriptor(
      width,
      height,
      throwOnDispose: throwOnDispose,
    );
    descriptors.add(descriptor);
    return descriptor;
  }

  @override
  Future<BoundedImageCodec> createCodec(
    BoundedImageDescriptor descriptor, {
    required int targetWidth,
    required int targetHeight,
  }) async {
    createCodecCalls += 1;
    targets.add((width: targetWidth, height: targetHeight));
    await _wait(_DecodeStage.codec);
    final codec = _FakeImageCodec(throwOnDispose: throwOnDispose);
    codecs.add(codec);
    return codec;
  }

  @override
  Future<BoundedImageFrame> getFirstFrame(BoundedImageCodec codec) async {
    getFirstFrameCalls += 1;
    await _wait(_DecodeStage.frame);
    final image = frameImage;
    if (image == null) throw StateError('frame unavailable');
    final frame = _FakeImageFrame(image, throwOnDispose: throwOnDispose);
    frames.add(frame);
    return frame;
  }
}

final class _FakeImageBuffer implements BoundedImageBuffer {
  _FakeImageBuffer({this.throwOnDispose = false});

  final bool throwOnDispose;
  var disposeCalls = 0;

  @override
  void dispose() {
    disposeCalls += 1;
    if (throwOnDispose) throw StateError('buffer dispose failed');
  }
}

final class _FakeImageDescriptor implements BoundedImageDescriptor {
  _FakeImageDescriptor(this.width, this.height, {this.throwOnDispose = false});

  @override
  final int width;
  @override
  final int height;
  final bool throwOnDispose;
  var disposeCalls = 0;

  @override
  void dispose() {
    disposeCalls += 1;
    if (throwOnDispose) throw StateError('descriptor dispose failed');
  }
}

final class _FakeImageCodec implements BoundedImageCodec {
  _FakeImageCodec({this.throwOnDispose = false});

  final bool throwOnDispose;
  var disposeCalls = 0;

  @override
  void dispose() {
    disposeCalls += 1;
    if (throwOnDispose) throw StateError('codec dispose failed');
  }
}

final class _FakeImageFrame implements BoundedImageFrame {
  _FakeImageFrame(this._image, {this.throwOnDispose = false});

  ui.Image? _image;
  final bool throwOnDispose;
  var takeImageCalls = 0;
  var disposeCalls = 0;

  @override
  ui.Image takeImage() {
    takeImageCalls += 1;
    return _image!;
  }

  @override
  void dispose() {
    disposeCalls += 1;
    _image = null;
    if (throwOnDispose) throw StateError('frame dispose failed');
  }
}

final class _CountingImageReservation implements AcpImageDecodeReservation {
  _CountingImageReservation({
    this.throwOnFinish = false,
    this.throwOnRelease = false,
  });

  final bool throwOnFinish;
  final bool throwOnRelease;
  final List<({int pixels, int bytes})> shrinks = <({int pixels, int bytes})>[];
  var finishCalls = 0;
  var releaseCalls = 0;

  @override
  bool get decodeFinished => finishCalls > 0;

  @override
  bool get installedMemoryReleased => releaseCalls > 0;

  @override
  void shrinkInstalledReservation({
    required int previewPixels,
    required int reservedBytes,
  }) {
    shrinks.add((pixels: previewPixels, bytes: reservedBytes));
  }

  @override
  void finishDecode() {
    finishCalls += 1;
    if (throwOnFinish) throw StateError('finish failed');
  }

  @override
  void releaseInstalledMemory() {
    releaseCalls += 1;
    if (throwOnRelease) throw StateError('release failed');
  }
}

Future<ui.Image> _testImage(int width, int height) {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = const ui.Color(0xff000000),
  );
  return recorder.endRecording().toImage(width, height);
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
