import 'dart:collection';

import 'package:dart_acp/dart_acp.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AcpInputOmission', () {
    test('serializes every reason with its exact wire fields', () {
      final omissions = <AcpInputOmission>[
        AcpInputOmission(
          reason: AcpInputOmissionReason.inputLimit,
          resource: 'message_text',
          truncated: true,
          limit: 0,
          observedAtLeast: 1,
        ),
        AcpInputOmission(
          reason: AcpInputOmissionReason.invalidEncoding,
          resource: 'message_text',
          truncated: false,
        ),
        AcpInputOmission(
          reason: AcpInputOmissionReason.invalidImage,
          resource: 'embedded_image',
          truncated: false,
        ),
        AcpInputOmission(
          reason: AcpInputOmissionReason.invalidStructure,
          resource: 'structured_update',
          truncated: true,
        ),
      ];

      expect(omissions.map((omission) => omission.toJson()).toList(), [
        <String, Object?>{
          'reason': 'input_limit',
          'resource': 'message_text',
          'limit': 0,
          'observedAtLeast': 1,
          'truncated': true,
        },
        <String, Object?>{
          'reason': 'invalid_encoding',
          'resource': 'message_text',
          'truncated': false,
        },
        <String, Object?>{
          'reason': 'invalid_image',
          'resource': 'embedded_image',
          'truncated': false,
        },
        <String, Object?>{
          'reason': 'invalid_structure',
          'resource': 'structured_update',
          'truncated': true,
        },
      ]);
    });

    test('input limit requires both capacity fields', () {
      for (final capacity in const <({int? limit, int? observedAtLeast})>[
        (limit: null, observedAtLeast: null),
        (limit: 10, observedAtLeast: null),
        (limit: null, observedAtLeast: 11),
      ]) {
        expect(
          () => AcpInputOmission(
            reason: AcpInputOmissionReason.inputLimit,
            resource: 'message_text',
            truncated: true,
            limit: capacity.limit,
            observedAtLeast: capacity.observedAtLeast,
          ),
          throwsArgumentError,
        );
      }
    });

    test('non-capacity reasons reject every capacity field shape', () {
      for (final reason in const <AcpInputOmissionReason>[
        AcpInputOmissionReason.invalidEncoding,
        AcpInputOmissionReason.invalidImage,
        AcpInputOmissionReason.invalidStructure,
      ]) {
        for (final capacity in const <({int? limit, int? observedAtLeast})>[
          (limit: 10, observedAtLeast: 11),
          (limit: 10, observedAtLeast: null),
          (limit: null, observedAtLeast: 11),
        ]) {
          expect(
            () => AcpInputOmission(
              reason: reason,
              resource: 'untrusted_input',
              truncated: false,
              limit: capacity.limit,
              observedAtLeast: capacity.observedAtLeast,
            ),
            throwsArgumentError,
          );
        }
      }
    });

    test('exposes immutable fields and formats only the fixed key set', () {
      const canary = 'PAYLOAD_CANARY_MUST_NOT_APPEAR';
      final inputLimit = AcpInputOmission(
        reason: AcpInputOmissionReason.inputLimit,
        resource: 'message_text',
        truncated: true,
        limit: 0,
        observedAtLeast: 1,
      );
      final invalidImage = AcpInputOmission(
        reason: AcpInputOmissionReason.invalidImage,
        resource: 'embedded_image',
        truncated: false,
      );

      expect(inputLimit.reason, AcpInputOmissionReason.inputLimit);
      expect(inputLimit.resource, 'message_text');
      expect(inputLimit.truncated, isTrue);
      expect(inputLimit.limit, 0);
      expect(inputLimit.observedAtLeast, 1);
      expect(inputLimit.toJson().keys.toList(), [
        'reason',
        'resource',
        'limit',
        'observedAtLeast',
        'truncated',
      ]);
      expect(invalidImage.toJson().keys.toList(), [
        'reason',
        'resource',
        'truncated',
      ]);
      expect(
        inputLimit.toString(),
        'AcpInputOmission(reason: input_limit, resource: message_text, '
        'limit: 0, observedAtLeast: 1, truncated: true)',
      );
      expect(
        invalidImage.toString(),
        'AcpInputOmission(reason: invalid_image, resource: embedded_image, '
        'truncated: false)',
      );
      expect(inputLimit.toJson().toString(), isNot(contains(canary)));
      expect(inputLimit.toString(), isNot(contains(canary)));
    });
  });

  group('AcpInputBudget', () {
    final newBudgetLimits =
        <({String field, AcpInputBudget Function(int value) create})>[
          (
            field: 'maxCollectionItems',
            create: (value) => AcpInputBudget(maxCollectionItems: value),
          ),
          (
            field: 'maxStructuredUpdateNodes',
            create: (value) => AcpInputBudget(maxStructuredUpdateNodes: value),
          ),
          (
            field: 'maxStructuredUpdateBytes',
            create: (value) => AcpInputBudget(maxStructuredUpdateBytes: value),
          ),
          (
            field: 'maxStructuredStringBytes',
            create: (value) => AcpInputBudget(maxStructuredStringBytes: value),
          ),
          (
            field: 'maxMessageTextBytes',
            create: (value) => AcpInputBudget(maxMessageTextBytes: value),
          ),
          (
            field: 'maxMessageTextLines',
            create: (value) => AcpInputBudget(maxMessageTextLines: value),
          ),
          (
            field: 'maxMarkdownSyntaxTokens',
            create: (value) => AcpInputBudget(maxMarkdownSyntaxTokens: value),
          ),
          (
            field: 'maxMarkdownFallbackBytes',
            create: (value) => AcpInputBudget(maxMarkdownFallbackBytes: value),
          ),
          (
            field: 'maxThoughtTextBytes',
            create: (value) => AcpInputBudget(maxThoughtTextBytes: value),
          ),
          (
            field: 'maxEmbeddedMediaBytes',
            create: (value) => AcpInputBudget(maxEmbeddedMediaBytes: value),
          ),
          (
            field: 'maxImageDimension',
            create: (value) => AcpInputBudget(maxImageDimension: value),
          ),
          (
            field: 'maxImagePixels',
            create: (value) => AcpInputBudget(maxImagePixels: value),
          ),
          (
            field: 'maxImagePreviewPixels',
            create: (value) => AcpInputBudget(maxImagePreviewPixels: value),
          ),
          (
            field: 'maxConcurrentImageDecodes',
            create: (value) => AcpInputBudget(maxConcurrentImageDecodes: value),
          ),
          (
            field: 'maxImagePreviewPixelsGlobal',
            create: (value) =>
                AcpInputBudget(maxImagePreviewPixelsGlobal: value),
          ),
          (
            field: 'maxImageDecodeBytesGlobal',
            create: (value) => AcpInputBudget(maxImageDecodeBytesGlobal: value),
          ),
          (
            field: 'maxTurnItems',
            create: (value) => AcpInputBudget(maxTurnItems: value),
          ),
          (
            field: 'maxTurnRetainedBytes',
            create: (value) => AcpInputBudget(maxTurnRetainedBytes: value),
          ),
          (
            field: 'maxTimelineItems',
            create: (value) => AcpInputBudget(maxTimelineItems: value),
          ),
          (
            field: 'maxTimelineBytes',
            create: (value) => AcpInputBudget(maxTimelineBytes: value),
          ),
          (
            field: 'maxUiStateBytes',
            create: (value) => AcpInputBudget(maxUiStateBytes: value),
          ),
          (
            field: 'maxMetadataPreviewBytes',
            create: (value) => AcpInputBudget(maxMetadataPreviewBytes: value),
          ),
          (
            field: 'maxMetadataPreviewChars',
            create: (value) => AcpInputBudget(maxMetadataPreviewChars: value),
          ),
        ];

    final allBudgetLimits =
        <({String field, AcpInputBudget Function(int value) create})>[
          (
            field: 'maxJsonDepth',
            create: (value) => AcpInputBudget(maxJsonDepth: value),
          ),
          (
            field: 'maxCapabilityDepth',
            create: (value) => AcpInputBudget(maxCapabilityDepth: value),
          ),
          (
            field: 'maxCapabilityNodes',
            create: (value) => AcpInputBudget(maxCapabilityNodes: value),
          ),
          (
            field: 'maxCapabilityBytes',
            create: (value) => AcpInputBudget(maxCapabilityBytes: value),
          ),
          (
            field: 'maxAuthMethods',
            create: (value) => AcpInputBudget(maxAuthMethods: value),
          ),
          (
            field: 'maxMetadataDepth',
            create: (value) => AcpInputBudget(maxMetadataDepth: value),
          ),
          (
            field: 'maxMetadataNodes',
            create: (value) => AcpInputBudget(maxMetadataNodes: value),
          ),
          (
            field: 'maxMetadataEntries',
            create: (value) => AcpInputBudget(maxMetadataEntries: value),
          ),
          (
            field: 'maxMetadataBytes',
            create: (value) => AcpInputBudget(maxMetadataBytes: value),
          ),
          ...newBudgetLimits,
        ];

    for (final invalidLimit in newBudgetLimits) {
      for (final value in const <int>[0, -1]) {
        test('${invalidLimit.field} rejects $value at runtime', () {
          expect(
            invalidLimit.create(value).validate,
            throwsA(
              isA<ArgumentError>().having(
                (error) => error.name,
                'field',
                invalidLimit.field,
              ),
            ),
          );
        });
      }
    }

    for (final budgetLimit in allBudgetLimits) {
      test('${budgetLimit.field} rejects unsafe integers first', () {
        expect(
          budgetLimit.create(0x1fffffffffffff + 1).validate,
          throwsA(
            isA<ArgumentError>().having(
              (error) => error.name,
              'field',
              budgetLimit.field,
            ),
          ),
        );
      });
    }

    test('approved small turn limits remain valid', () {
      expect(
        const AcpInputBudget(
          maxTurnItems: 1,
          maxTurnRetainedBytes: 1024,
        ).validate,
        returnsNormally,
      );
    });

    test('image preview pixels accept the image pixel boundary', () {
      expect(
        const AcpInputBudget(
          maxImagePixels: 10,
          maxImagePreviewPixels: 10,
        ).validate,
        returnsNormally,
      );
    });

    test('image preview pixels reject one beyond image pixels', () {
      expect(
        const AcpInputBudget(
          maxImagePixels: 10,
          maxImagePreviewPixels: 11,
        ).validate,
        throwsA(
          isA<AcpInputLimitExceeded>()
              .having((error) => error.limit, 'limit', 10)
              .having((error) => error.observedAtLeast, 'observedAtLeast', 11),
        ),
      );
    });

    test('image preview pixels accept the global preview boundary', () {
      expect(
        const AcpInputBudget(
          maxImagePreviewPixels: 10,
          maxImagePreviewPixelsGlobal: 10,
        ).validate,
        returnsNormally,
      );
    });

    test('image preview pixels reject one beyond the global budget', () {
      expect(
        const AcpInputBudget(
          maxImagePreviewPixels: 11,
          maxImagePreviewPixelsGlobal: 10,
        ).validate,
        throwsA(
          isA<AcpInputLimitExceeded>()
              .having((error) => error.limit, 'limit', 10)
              .having((error) => error.observedAtLeast, 'observedAtLeast', 11),
        ),
      );
    });

    test('embedded media plus preview bytes accepts the exact boundary', () {
      expect(
        const AcpInputBudget(
          maxEmbeddedMediaBytes: 8,
          maxImagePreviewPixels: 3,
          maxImageDecodeBytesGlobal: 20,
        ).validate,
        returnsNormally,
      );
    });

    test('embedded media plus preview bytes rejects one beyond boundary', () {
      expect(
        const AcpInputBudget(
          maxEmbeddedMediaBytes: 9,
          maxImagePreviewPixels: 3,
          maxImageDecodeBytesGlobal: 20,
        ).validate,
        throwsA(
          isA<AcpInputLimitExceeded>()
              .having(
                (error) => error.resource,
                'resource',
                'maxEmbeddedMediaBytes after image preview reservation',
              )
              .having((error) => error.limit, 'limit', 8)
              .having((error) => error.observedAtLeast, 'observedAtLeast', 9),
        ),
      );
    });

    test('markdown fallback bytes accept the message text boundary', () {
      expect(
        const AcpInputBudget(
          maxMessageTextBytes: 10,
          maxMarkdownFallbackBytes: 10,
        ).validate,
        returnsNormally,
      );
    });

    test('markdown fallback bytes reject one beyond message text bytes', () {
      expect(
        const AcpInputBudget(
          maxMessageTextBytes: 10,
          maxMarkdownFallbackBytes: 11,
        ).validate,
        throwsA(
          isA<AcpInputLimitExceeded>()
              .having((error) => error.limit, 'limit', 10)
              .having((error) => error.observedAtLeast, 'observedAtLeast', 11),
        ),
      );
    });

    test('turn, timeline, and UI bytes accept equal boundaries', () {
      expect(
        const AcpInputBudget(
          maxTurnRetainedBytes: 1024,
          maxTimelineBytes: 1024,
          maxUiStateBytes: 1024,
        ).validate,
        returnsNormally,
      );
    });

    test('turn retained bytes reject one beyond timeline bytes', () {
      expect(
        const AcpInputBudget(
          maxTurnRetainedBytes: 1025,
          maxTimelineBytes: 1024,
          maxUiStateBytes: 1024,
        ).validate,
        throwsA(
          isA<AcpInputLimitExceeded>()
              .having((error) => error.limit, 'limit', 1024)
              .having(
                (error) => error.observedAtLeast,
                'observedAtLeast',
                1025,
              ),
        ),
      );
    });

    test('timeline bytes reject one beyond UI state bytes', () {
      expect(
        const AcpInputBudget(
          maxTurnRetainedBytes: 1024,
          maxTimelineBytes: 1025,
          maxUiStateBytes: 1024,
        ).validate,
        throwsA(
          isA<AcpInputLimitExceeded>()
              .having((error) => error.limit, 'limit', 1024)
              .having(
                (error) => error.observedAtLeast,
                'observedAtLeast',
                1025,
              ),
        ),
      );
    });

    test('preview pixels reject unsafe integers before relationships', () {
      const maxSafeBudgetInteger = 0x1fffffffffffff;
      const unsafePreviewPixels = maxSafeBudgetInteger ~/ 4 + 1;

      expect(
        const AcpInputBudget(
          maxImagePreviewPixels: unsafePreviewPixels,
        ).validate,
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.name,
            'field',
            'maxImagePreviewPixels',
          ),
        ),
      );
    });

    test('image decode global bytes reject an unsafe integer', () {
      const maxSafeBudgetInteger = 0x1fffffffffffff;

      expect(
        const AcpInputBudget(
          maxImageDecodeBytesGlobal: maxSafeBudgetInteger + 1,
        ).validate,
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.name,
            'field',
            'maxImageDecodeBytesGlobal',
          ),
        ),
      );
    });

    test('preview byte reservation avoids overflowing addition', () {
      const maxSafeBudgetInteger = 0x1fffffffffffff;
      const maxSafeDecodedBytes = 6755399441055741;
      const previewPixels = 562949953421313;

      expect(
        const AcpInputBudget(
          maxEmbeddedMediaBytes: maxSafeDecodedBytes,
          maxImagePixels: previewPixels,
          maxImagePreviewPixels: previewPixels,
          maxImagePreviewPixelsGlobal: previewPixels,
          maxImageDecodeBytesGlobal: maxSafeBudgetInteger,
        ).validate,
        throwsA(
          isA<AcpInputLimitExceeded>()
              .having((error) => error.limit, 'limit', maxSafeDecodedBytes - 2)
              .having(
                (error) => error.observedAtLeast,
                'observedAtLeast',
                maxSafeDecodedBytes,
              ),
        ),
      );
    });

    test(
      'preview bytes beyond global decode bytes report non-negative limit',
      () {
        expect(
          const AcpInputBudget(
            maxEmbeddedMediaBytes: 1,
            maxImagePreviewPixels: 2,
            maxImageDecodeBytesGlobal: 7,
          ).validate,
          throwsA(
            isA<AcpInputLimitExceeded>()
                .having(
                  (error) => error.resource,
                  'resource',
                  'maxImagePreviewPixels bytes relative to '
                      'maxImageDecodeBytesGlobal',
                )
                .having((error) => error.limit, 'limit', 7)
                .having((error) => error.observedAtLeast, 'observedAtLeast', 8),
          ),
        );
      },
    );

    test('preview bytes may consume global decode bytes exactly', () {
      expect(
        const AcpInputBudget(
          maxEmbeddedMediaBytes: 1,
          maxImagePreviewPixels: 2,
          maxImageDecodeBytesGlobal: 8,
        ).validate,
        throwsA(
          isA<AcpInputLimitExceeded>()
              .having(
                (error) => error.resource,
                'resource',
                'maxEmbeddedMediaBytes after image preview reservation',
              )
              .having((error) => error.limit, 'limit', 0)
              .having((error) => error.observedAtLeast, 'observedAtLeast', 1),
        ),
      );
    });
  });

  group('AcpUtf8LineBudgetCounter', () {
    AcpUtf8LineBudgetCounter counter({
      int maxBytes = 100,
      int maxLines = 100,
    }) => AcpUtf8LineBudgetCounter(
      maxBytes: maxBytes,
      maxLines: maxLines,
      resource: 'message_text',
    );

    test('accepts exact ASCII and multi-byte UTF-8 boundaries', () {
      for (final value in <({String text, int bytes})>[
        (text: 'a', bytes: 1),
        (text: '\u00e9', bytes: 2),
        (text: '\u20ac', bytes: 3),
        (text: '\u{1f600}', bytes: 4),
      ]) {
        final exact = counter(maxBytes: value.bytes);
        final accepted = exact.append(value.text);
        expect(accepted.safePrefix, value.text);
        expect(accepted.acceptedBytes, value.bytes);
        expect(accepted.totalBytes, value.bytes);
        expect(accepted.totalLines, 1);
        expect(accepted.omission, isNull);

        final plusOne = counter(maxBytes: value.bytes);
        final truncated = plusOne.append('${value.text}a');
        expect(truncated.safePrefix, value.text);
        expect(truncated.acceptedBytes, value.bytes);
        expect(truncated.totalBytes, value.bytes);
        expect(
          truncated.omission,
          isA<AcpInputOmission>()
              .having(
                (value) => value.reason,
                'reason',
                AcpInputOmissionReason.inputLimit,
              )
              .having((value) => value.resource, 'resource', 'message_text')
              .having((value) => value.limit, 'limit', value.bytes)
              .having(
                (value) => value.observedAtLeast,
                'observedAtLeast',
                value.bytes + 1,
              )
              .having((value) => value.truncated, 'truncated', isTrue),
        );
      }
    });

    test('does not split a code point at a byte boundary', () {
      final result = counter(maxBytes: 2).append('a\u20ac');

      expect(result.safePrefix, 'a');
      expect(result.acceptedBytes, 1);
      expect(result.totalBytes, 1);
      expect(result.omission?.limit, 2);
      expect(result.omission?.observedAtLeast, 4);
    });

    test('accepts surrogate pairs in one chunk and across chunks', () {
      final high = String.fromCharCode(0xd83d);
      final low = String.fromCharCode(0xde00);
      final sameChunk = counter(maxBytes: 4).append('$high$low');
      expect(sameChunk.safePrefix, '$high$low');
      expect(sameChunk.acceptedBytes, 4);

      final split = counter(maxBytes: 4);
      final first = split.append(high);
      final second = split.append(low);
      expect(first.safePrefix, isEmpty);
      expect(first.acceptedBytes, 0);
      expect(first.totalBytes, 0);
      expect(second.safePrefix, '$high$low');
      expect(second.acceptedBytes, 4);
      expect(second.totalBytes, 4);
    });

    test(
      'replaces isolated high and low surrogates with three UTF-8 bytes',
      () {
        final high = String.fromCharCode(0xd800);
        final low = String.fromCharCode(0xdc00);
        final highThenAscii = counter(maxBytes: 4);

        expect(highThenAscii.append(high).safePrefix, isEmpty);
        final resolved = highThenAscii.append('a');
        expect(resolved.safePrefix, '${high}a');
        expect(resolved.acceptedBytes, 4);
        expect(resolved.totalBytes, 4);

        final isolatedLow = counter(maxBytes: 3).append(low);
        expect(isolatedLow.safePrefix, low);
        expect(isolatedLow.acceptedBytes, 3);
        expect(isolatedLow.totalBytes, 3);

        final finishHigh = counter(maxBytes: 3);
        finishHigh.append(high);
        final finished = finishHigh.finish();
        expect(finished.safePrefix, high);
        expect(finished.acceptedBytes, 3);
        expect(finished.totalBytes, 3);
      },
    );

    final high = String.fromCharCode(0xd800);
    final low = String.fromCharCode(0xdc00);
    final surrogatePairCases =
        <
          ({
            String name,
            AcpTextBudgetChunk Function(AcpUtf8LineBudgetCounter counter) run,
          })
        >[
          (name: 'same chunk', run: (value) => value.append('$high$low')),
          (
            name: 'across chunks',
            run: (value) {
              final pending = value.append(high);
              expect(pending.safePrefix, isEmpty);
              expect(pending.acceptedBytes, 0);
              expect(pending.totalBytes, 0);
              return value.append(low);
            },
          ),
        ];

    for (final testCase in surrogatePairCases) {
      test('surrogate pair ${testCase.name} accepts exact four bytes', () {
        final value = counter(maxBytes: 4);
        final result = testCase.run(value);

        expect(result.safePrefix, '$high$low');
        expect(result.acceptedBytes, 4);
        expect(result.totalBytes, 4);
        expect(result.omission, isNull);
      });

      test('surrogate pair ${testCase.name} rejects a three-byte limit', () {
        final value = counter(maxBytes: 3);
        final result = testCase.run(value);

        expect(result.safePrefix, isEmpty);
        expect(result.acceptedBytes, 0);
        expect(result.totalBytes, 0);
        expect(result.omission?.limit, 3);
        expect(result.omission?.observedAtLeast, 4);

        final drained = value.append('PAYLOAD_CANARY_MUST_NOT_APPEAR');
        expect(drained.safePrefix, isEmpty);
        expect(drained.acceptedBytes, 0);
        expect(drained.totalBytes, 0);
        expect(drained.omission, isNull);
      });
    }

    test('isolated high confirmed by a non-low accepts exact three bytes', () {
      final value = counter(maxBytes: 3);
      expect(value.append(high).safePrefix, isEmpty);

      // A second high is a non-low code unit and remains pending itself, so
      // this return isolates the first high without consuming another byte.
      final result = value.append(high);
      expect(result.safePrefix, high);
      expect(result.acceptedBytes, 3);
      expect(result.totalBytes, 3);
      expect(result.omission, isNull);
    });

    test('isolated high confirmed by a non-low rejects a two-byte limit', () {
      final value = counter(maxBytes: 2);
      expect(value.append(high).safePrefix, isEmpty);

      final result = value.append(high);
      expect(result.safePrefix, isEmpty);
      expect(result.acceptedBytes, 0);
      expect(result.totalBytes, 0);
      expect(result.omission?.limit, 2);
      expect(result.omission?.observedAtLeast, 3);

      final drained = value.append('PAYLOAD_CANARY_MUST_NOT_APPEAR');
      expect(drained.safePrefix, isEmpty);
      expect(drained.acceptedBytes, 0);
      expect(drained.totalBytes, 0);
      expect(drained.omission, isNull);
    });

    for (final maxBytes in const <int>[3, 2]) {
      test('isolated high at finish with maxBytes $maxBytes', () {
        final value = counter(maxBytes: maxBytes);
        expect(value.append(high).safePrefix, isEmpty);

        final result = value.finish();
        final accepted = maxBytes == 3;
        expect(result.safePrefix, accepted ? high : isEmpty);
        expect(result.acceptedBytes, accepted ? 3 : 0);
        expect(result.totalBytes, accepted ? 3 : 0);
        if (accepted) {
          expect(result.omission, isNull);
        } else {
          expect(result.omission?.limit, 2);
          expect(result.omission?.observedAtLeast, 3);
        }

        final repeated = value.finish();
        expect(repeated.safePrefix, isEmpty);
        expect(repeated.acceptedBytes, 0);
        expect(repeated.totalBytes, accepted ? 3 : 0);
        expect(repeated.omission, isNull);
      });
    }

    for (final maxBytes in const <int>[3, 2]) {
      test('isolated low with maxBytes $maxBytes', () {
        final value = counter(maxBytes: maxBytes);
        final result = value.append(low);
        final accepted = maxBytes == 3;

        expect(result.safePrefix, accepted ? low : isEmpty);
        expect(result.acceptedBytes, accepted ? 3 : 0);
        expect(result.totalBytes, accepted ? 3 : 0);
        if (accepted) {
          expect(result.omission, isNull);
        } else {
          expect(result.omission?.limit, 2);
          expect(result.omission?.observedAtLeast, 3);
          final drained = value.append('PAYLOAD_CANARY_MUST_NOT_APPEAR');
          expect(drained.safePrefix, isEmpty);
          expect(drained.acceptedBytes, 0);
          expect(drained.totalBytes, 0);
          expect(drained.omission, isNull);
        }
      });
    }

    test('counts empty, ordinary, CR, LF, and CRLF text lines', () {
      expect(counter().finish().totalLines, 0);
      expect(counter().append('abc').totalLines, 1);
      expect(counter().append('a\rb').totalLines, 2);
      expect(counter().append('a\nb').totalLines, 2);
      expect(counter().append('a\r\nb').totalLines, 2);

      final splitCrLf = counter();
      expect(splitCrLf.append('a\r').totalLines, 2);
      expect(splitCrLf.append('\nb').totalLines, 2);
    });

    final newlineCases =
        <({String name, List<String> chunks, List<String> exactPrefixes})>[
          (
            name: 'CR',
            chunks: <String>['a\rb'],
            exactPrefixes: <String>['a\rb'],
          ),
          (
            name: 'LF',
            chunks: <String>['a\nb'],
            exactPrefixes: <String>['a\nb'],
          ),
          (
            name: 'same-chunk CRLF',
            chunks: <String>['a\r\nb'],
            exactPrefixes: <String>['a\r\nb'],
          ),
          (
            name: 'cross-chunk CRLF',
            chunks: <String>['a\r', '\nb'],
            exactPrefixes: <String>['a\r', '\nb'],
          ),
        ];

    for (final testCase in newlineCases) {
      test('${testCase.name} accepts the exact two-line boundary', () {
        final value = counter(maxLines: 2);
        final results = <AcpTextBudgetChunk>[];
        for (final chunk in testCase.chunks) {
          results.add(value.append(chunk));
        }

        expect(
          results.map((result) => result.safePrefix).toList(),
          testCase.exactPrefixes,
        );
        expect(results.last.totalLines, 2);
        expect(results.every((result) => result.omission == null), isTrue);
      });

      test(
        '${testCase.name} rejects the first line beyond a one-line limit',
        () {
          final value = counter(maxLines: 1);
          final results = <AcpTextBudgetChunk>[];
          for (final chunk in testCase.chunks) {
            results.add(value.append(chunk));
          }

          expect(results.first.safePrefix, 'a');
          expect(results.first.totalLines, 1);
          expect(results.first.omission?.limit, 1);
          expect(results.first.omission?.observedAtLeast, 2);
          for (final drained in results.skip(1)) {
            expect(drained.safePrefix, isEmpty);
            expect(drained.totalLines, 1);
            expect(drained.omission, isNull);
          }

          final drained = value.append('PAYLOAD_CANARY_MUST_NOT_APPEAR');
          expect(drained.safePrefix, isEmpty);
          expect(drained.acceptedBytes, 0);
          expect(drained.totalLines, 1);
          expect(drained.omission, isNull);
        },
      );
    }

    test('enforces leading and trailing newline line boundaries', () {
      final exact = counter(maxLines: 3).append('\na\n');
      expect(exact.safePrefix, '\na\n');
      expect(exact.totalLines, 3);
      expect(exact.omission, isNull);

      final plusOne = counter(maxLines: 2).append('\na\n');
      expect(plusOne.safePrefix, '\na');
      expect(plusOne.acceptedBytes, 2);
      expect(plusOne.totalLines, 2);
      expect(plusOne.omission?.limit, 2);
      expect(plusOne.omission?.observedAtLeast, 3);
    });

    test('returns the input-limit marker only once while draining', () {
      final value = counter(maxBytes: 1);

      final first = value.append('ab');
      final second = value.append('PAYLOAD_CANARY_MUST_NOT_APPEAR');
      final finished = value.finish();

      expect(first.safePrefix, 'a');
      expect(first.omission, isNotNull);
      expect(second.safePrefix, isEmpty);
      expect(second.acceptedBytes, 0);
      expect(second.totalBytes, 1);
      expect(second.omission, isNull);
      expect(finished.omission, isNull);
      expect(first.omission.toString(), isNot(contains('PAYLOAD_CANARY')));
    });

    test('finish is terminal and idempotent', () {
      final value = counter();
      value.append('a');

      final first = value.finish();
      final second = value.finish();

      expect(first.safePrefix, isEmpty);
      expect(first.acceptedBytes, 0);
      expect(first.totalBytes, 1);
      expect(first.totalLines, 1);
      expect(first.omission, isNull);
      expect(second.safePrefix, isEmpty);
      expect(second.acceptedBytes, 0);
      expect(second.totalBytes, 1);
      expect(second.totalLines, 1);
      expect(second.omission, isNull);
      expect(
        () => value.append('PAYLOAD_CANARY_MUST_NOT_APPEAR'),
        throwsA(
          isA<StateError>().having(
            (error) => error.toString(),
            'message',
            isNot(contains('PAYLOAD_CANARY')),
          ),
        ),
      );
    });

    test('validates byte and line limits as positive safe integers', () {
      const unsafe = 0x1fffffffffffff + 1;
      for (final value in const <int>[0, -1, unsafe]) {
        expect(
          () => AcpUtf8LineBudgetCounter(
            maxBytes: value,
            maxLines: 1,
            resource: 'message_text',
          ),
          throwsA(
            isA<ArgumentError>().having(
              (error) => error.name,
              'field',
              'maxBytes',
            ),
          ),
        );
        expect(
          () => AcpUtf8LineBudgetCounter(
            maxBytes: 1,
            maxLines: value,
            resource: 'message_text',
          ),
          throwsA(
            isA<ArgumentError>().having(
              (error) => error.name,
              'field',
              'maxLines',
            ),
          ),
        );
      }
    });
  });

  group('scanAcpBase64', () {
    test('accepts the standard alphabet, empty input, and padding', () {
      const alphabet =
          'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

      expect(
        scanAcpBase64('', maxDecodedBytes: 1, resource: 'media'),
        isA<AcpBase64ScanResult>()
            .having((value) => value.encodedLength, 'encodedLength', 0)
            .having((value) => value.decodedBytes, 'decodedBytes', 0),
      );
      expect(
        scanAcpBase64(
          alphabet,
          maxDecodedBytes: 48,
          resource: 'media',
        ).decodedBytes,
        48,
      );
      expect(
        scanAcpBase64(
          'TQ==',
          maxDecodedBytes: 1,
          resource: 'media',
        ).decodedBytes,
        1,
      );
      expect(
        scanAcpBase64(
          'TWE=',
          maxDecodedBytes: 2,
          resource: 'media',
        ).decodedBytes,
        2,
      );
      expect(
        scanAcpBase64('TWFu', maxDecodedBytes: 3, resource: 'media'),
        isA<AcpBase64ScanResult>()
            .having((value) => value.encodedLength, 'encodedLength', 4)
            .having((value) => value.decodedBytes, 'decodedBytes', 3),
      );
    });

    test('rejects invalid lengths and padding shapes', () {
      for (final encoded in const <String>[
        'T',
        'TQ',
        'TWE',
        'TWE==',
        'T=WE',
        'TQ=A',
        'TQ==AAAA',
        'T===',
      ]) {
        expect(
          () => scanAcpBase64(encoded, maxDecodedBytes: 100, resource: 'media'),
          throwsA(isA<FormatException>()),
          reason: encoded,
        );
      }
    });

    test('rejects non-canonical Base64 padding bits', () {
      for (final encoded in const <String>['TR==', 'TWF=']) {
        expect(
          () => scanAcpBase64(encoded, maxDecodedBytes: 2, resource: 'media'),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              'Invalid ACP Base64 encoding.',
            ),
          ),
          reason: encoded,
        );
      }

      expect(
        scanAcpBase64(
          'TQ==',
          maxDecodedBytes: 1,
          resource: 'media',
        ).decodedBytes,
        1,
      );
      expect(
        scanAcpBase64(
          'TWE=',
          maxDecodedBytes: 2,
          resource: 'media',
        ).decodedBytes,
        2,
      );
    });

    test('rejects whitespace, URL-safe alphabet, and other characters', () {
      for (final encoded in const <String>[
        'TW E',
        'TW\nE',
        '____',
        '----',
        'TW!E',
      ]) {
        expect(
          () => scanAcpBase64(encoded, maxDecodedBytes: 100, resource: 'media'),
          throwsA(isA<FormatException>()),
          reason: encoded,
        );
      }
    });

    test('accepts decoded boundary and stops at the first byte beyond it', () {
      expect(
        scanAcpBase64(
          'TWFu',
          maxDecodedBytes: 3,
          resource: 'embedded_media',
        ).decodedBytes,
        3,
      );
      expect(
        () => scanAcpBase64(
          'TWFu',
          maxDecodedBytes: 2,
          resource: 'embedded_media',
        ),
        throwsA(
          isA<AcpInputLimitExceeded>()
              .having((error) => error.resource, 'resource', 'embedded_media')
              .having((error) => error.limit, 'limit', 2)
              .having((error) => error.observedAtLeast, 'observedAtLeast', 3),
        ),
      );
    });

    test('calls a decoder only after a successful scan', () {
      var decoderCalled = false;

      void decodeAfterScan(String encoded, int maxDecodedBytes) {
        scanAcpBase64(
          encoded,
          maxDecodedBytes: maxDecodedBytes,
          resource: 'embedded_media',
        );
        decoderCalled = true;
      }

      expect(() => decodeAfterScan('TW!E', 100), throwsFormatException);
      expect(decoderCalled, isFalse);
      expect(
        () => decodeAfterScan('TWFu', 2),
        throwsA(isA<AcpInputLimitExceeded>()),
      );
      expect(decoderCalled, isFalse);
      decodeAfterScan('TWFu', 3);
      expect(decoderCalled, isTrue);
    });

    test(
      'validates capacity and keeps rejected payloads out of exceptions',
      () {
        const unsafe = 0x1fffffffffffff + 1;
        for (final value in const <int>[0, -1, unsafe]) {
          expect(
            () => scanAcpBase64(
              '',
              maxDecodedBytes: value,
              resource: 'embedded_media',
            ),
            throwsA(
              isA<ArgumentError>().having(
                (error) => error.name,
                'field',
                'maxDecodedBytes',
              ),
            ),
          );
        }

        expect(
          () => scanAcpBase64(
            'PAYLOAD_CANARY_MUST_NOT_APPEAR!',
            maxDecodedBytes: 100,
            resource: 'embedded_media',
          ),
          throwsA(
            isA<FormatException>().having(
              (error) => error.toString(),
              'message',
              isNot(contains('PAYLOAD_CANARY')),
            ),
          ),
        );
        expect(
          () => scanAcpBase64(
            'UEFZTE9BRF9DQU5BUlk=',
            maxDecodedBytes: 1,
            resource: 'embedded_media',
          ),
          throwsA(
            isA<AcpInputLimitExceeded>().having(
              (error) => error.toString(),
              'message',
              isNot(contains('PAYLOAD_CANARY')),
            ),
          ),
        );
      },
    );
  });

  group('AcpRetainedSizeEstimator', () {
    AcpRetainedSizeEstimator estimator({
      int maxDepth = 16,
      int maxNodes = 8192,
      int maxEntries = 1024,
      int maxItems = 1024,
      int maxStringBytes = 64 * 1024,
    }) => AcpRetainedSizeEstimator(
      budget: AcpInputBudget(
        maxMetadataDepth: maxDepth,
        maxMetadataNodes: maxNodes,
        maxMetadataEntries: maxEntries,
        maxCollectionItems: maxItems,
        maxStructuredStringBytes: maxStringBytes,
      ),
    );

    test('estimates JSON scalars by their wire text bytes', () {
      final value = estimator();

      expect(value.estimate(null), 4);
      expect(value.estimate(true), 4);
      expect(value.estimate(false), 5);
      expect(value.estimate(0), 1);
      expect(value.estimate(-12), 3);
      expect(value.estimate(1.0), 3);
      expect(value.estimate(1.5), 3);
      expect(value.estimate(-0.0), 4);
    });

    test('estimates real UTF-8 bytes including isolated surrogates', () {
      final value = estimator();

      expect(value.estimate('a'), 1);
      expect(value.estimate('\u00e9'), 2);
      expect(value.estimate('\u20ac'), 3);
      expect(value.estimate('\u{1f600}'), 4);
      expect(value.estimate(String.fromCharCode(0xd800)), 3);
      expect(value.estimate(String.fromCharCode(0xdc00)), 3);
    });

    test('adds container and item or entry overhead exactly', () {
      final value = estimator();

      expect(value.estimate(<Object?>[]), 64);
      expect(value.estimate(<Object?>[true, '\u00e9']), 134);
      expect(
        value.estimate(<String, Object?>{
          '\u00e9': <Object?>[null],
        }),
        198,
      );
      expect(value.estimate('TWFu'), 4);
    });

    test('estimates three-field and five-field omission models', () {
      final value = estimator();
      final invalidImage = AcpInputOmission(
        reason: AcpInputOmissionReason.invalidImage,
        resource: 'media',
        truncated: false,
      );
      final inputLimit = AcpInputOmission(
        reason: AcpInputOmissionReason.inputLimit,
        resource: 'message_text',
        truncated: true,
        limit: 10,
        observedAtLeast: 11,
      );

      expect(value.estimate(invalidImage), 183);
      expect(value.estimate(inputLimit), 255);
    });

    test('rejects cycles but counts shared non-cyclic aliases twice', () {
      final value = estimator();
      final cycle = <Object?>[];
      cycle.add(cycle);
      expect(
        () => value.estimate(cycle),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            startsWith('Invalid ACP retained state'),
          ),
        ),
      );

      final shared = <Object?>[null];
      expect(value.estimate(<Object?>[shared, shared]), 328);
    });

    test('enforces container depth and node limits with fixed resources', () {
      expect(
        () => estimator(maxDepth: 2).estimate(<Object?>[
          <Object?>[
            <Object?>[null],
          ],
        ]),
        throwsA(
          isA<AcpInputLimitExceeded>()
              .having(
                (error) => error.resource,
                'resource',
                'ACP retained state depth',
              )
              .having((error) => error.limit, 'limit', 2)
              .having((error) => error.observedAtLeast, 'observedAtLeast', 3),
        ),
      );

      expect(estimator(maxNodes: 2).estimate(<Object?>[null]), 100);
      expect(
        () => estimator(maxNodes: 2).estimate(<Object?>[
          <Object?>[null],
        ]),
        throwsA(
          isA<AcpInputLimitExceeded>()
              .having(
                (error) => error.resource,
                'resource',
                'ACP retained state nodes',
              )
              .having((error) => error.limit, 'limit', 2)
              .having((error) => error.observedAtLeast, 'observedAtLeast', 3),
        ),
      );
    });

    test('enforces list and map entry limits before traversal', () {
      expect(estimator(maxItems: 2).estimate(<Object?>[null, null]), 136);
      expect(
        () => estimator(maxItems: 2).estimate(<Object?>[null, null, null]),
        throwsA(
          isA<AcpInputLimitExceeded>()
              .having(
                (error) => error.resource,
                'resource',
                'ACP retained state collection items',
              )
              .having((error) => error.limit, 'limit', 2)
              .having((error) => error.observedAtLeast, 'observedAtLeast', 3),
        ),
      );

      expect(
        estimator(
          maxItems: 3,
          maxEntries: 2,
        ).estimate(<String, Object?>{'a': null, 'b': null}),
        138,
      );
      expect(
        () => estimator(
          maxItems: 3,
          maxEntries: 2,
        ).estimate(<String, Object?>{'a': null, 'b': null, 'c': null}),
        throwsA(
          isA<AcpInputLimitExceeded>()
              .having(
                (error) => error.resource,
                'resource',
                'ACP retained state map entries',
              )
              .having((error) => error.limit, 'limit', 2)
              .having((error) => error.observedAtLeast, 'observedAtLeast', 3),
        ),
      );
    });

    test('enforces UTF-8 limits for strings and map keys', () {
      final value = estimator(maxStringBytes: 3);
      expect(value.estimate('\u20ac'), 3);
      expect(
        () => value.estimate('\u20aca'),
        throwsA(
          isA<AcpInputLimitExceeded>()
              .having(
                (error) => error.resource,
                'resource',
                'ACP retained state string bytes',
              )
              .having((error) => error.limit, 'limit', 3)
              .having((error) => error.observedAtLeast, 'observedAtLeast', 4),
        ),
      );
      expect(value.estimate(<String, Object?>{'\u20ac': null}), 103);
      expect(
        () => value.estimate(<String, Object?>{'\u20aca': null}),
        throwsA(
          isA<AcpInputLimitExceeded>().having(
            (error) => error.resource,
            'resource',
            'ACP retained state string bytes',
          ),
        ),
      );
    });

    test('map node capacity fails before scanning a long key', () {
      expect(
        () => estimator(
          maxNodes: 1,
          maxStringBytes: 3,
        ).estimate(<String, Object?>{'long': null}),
        throwsA(
          isA<AcpInputLimitExceeded>()
              .having(
                (error) => error.resource,
                'resource',
                'ACP retained state nodes',
              )
              .having((error) => error.limit, 'limit', 1)
              .having((error) => error.observedAtLeast, 'observedAtLeast', 2),
        ),
      );
    });

    test('underreported map checks node capacity before each long key', () {
      final source = _UnderreportedRetainedMap(
        reportedLength: 0,
        backingValues: <String, Object?>{'long': null},
      );

      expect(
        () => estimator(maxNodes: 1, maxStringBytes: 3).estimate(source),
        throwsA(
          isA<AcpInputLimitExceeded>()
              .having(
                (error) => error.resource,
                'resource',
                'ACP retained state nodes',
              )
              .having((error) => error.limit, 'limit', 1)
              .having((error) => error.observedAtLeast, 'observedAtLeast', 2),
        ),
      );
      expect(source.entriesVisited, 1);
    });

    test('rejects non-JSON values without invoking payload methods', () {
      final value = estimator();
      final canary = _RetainedValueCanary();

      for (final invalid in <Object?>[
        <Object?, Object?>{1: null},
        double.nan,
        double.infinity,
        double.negativeInfinity,
        canary,
      ]) {
        expect(
          () => value.estimate(invalid),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              startsWith('Invalid ACP retained state'),
            ),
          ),
        );
      }

      expect(canary.toStringCalls, 0);
      expect(canary.toJsonCalls, 0);
    });

    test('uses an explicit stack for very deep valid input', () {
      const depth = 3000;
      Object? value;
      for (var index = 0; index < depth; index += 1) {
        value = <Object?>[value];
      }

      expect(
        estimator(
          maxDepth: depth,
          maxNodes: depth + 1,
          maxItems: 1,
        ).estimate(value),
        depth * 96 + 4,
      );
    });

    test('fails safely when retained overhead exceeds the safe integer', () {
      const maxSafe = 0x1fffffffffffff;
      final huge = _ReportedLengthList(maxSafe ~/ 32);

      expect(
        () => estimator(maxNodes: maxSafe, maxItems: maxSafe).estimate(huge),
        throwsA(
          isA<AcpInputLimitExceeded>()
              .having(
                (error) => error.resource,
                'resource',
                'ACP retained state bytes',
              )
              .having((error) => error.limit, 'limit', maxSafe)
              .having(
                (error) => error.observedAtLeast,
                'observedAtLeast',
                maxSafe + 1,
              ),
        ),
      );
      expect(huge.indexReads, 0);
    });
  });

  group('acpMaxBase64EncodedLength', () {
    test('derives the default embedded media encoded limit', () {
      expect(acpMaxBase64EncodedLength(8 * 1024 * 1024), 11184812);
    });

    test('accepts the exact cross-platform safe boundary', () {
      expect(acpMaxBase64EncodedLength(6755399441055741), 9007199254740988);
    });

    test('rejects one decoded byte beyond the safe boundary', () {
      expect(
        () => acpMaxBase64EncodedLength(6755399441055742),
        throwsA(isA<ArgumentError>()),
      );
    });

    for (final value in const <int>[0, -1]) {
      test('rejects non-positive decoded byte limit $value', () {
        expect(
          () => acpMaxBase64EncodedLength(value),
          throwsA(
            isA<ArgumentError>().having(
              (error) => error.name,
              'field',
              'decodedByteLimit',
            ),
          ),
        );
      });
    }
  });
}

final class _RetainedValueCanary {
  var toStringCalls = 0;
  var toJsonCalls = 0;

  Object? toJson() {
    toJsonCalls += 1;
    return null;
  }

  @override
  String toString() {
    toStringCalls += 1;
    return 'PAYLOAD_CANARY_MUST_NOT_APPEAR';
  }
}

final class _ReportedLengthList extends ListBase<Object?> {
  _ReportedLengthList(this._length);

  final int _length;
  var indexReads = 0;

  @override
  int get length => _length;

  @override
  set length(int value) => throw UnsupportedError('read only');

  @override
  Object? operator [](int index) {
    indexReads += 1;
    return null;
  }

  @override
  void operator []=(int index, Object? value) =>
      throw UnsupportedError('read only');
}

final class _UnderreportedRetainedMap extends MapBase<String, Object?> {
  _UnderreportedRetainedMap({
    required this.reportedLength,
    required this.backingValues,
  });

  final int reportedLength;
  final Map<String, Object?> backingValues;
  var entriesVisited = 0;

  @override
  Iterable<MapEntry<String, Object?>> get entries sync* {
    for (final entry in backingValues.entries) {
      entriesVisited += 1;
      yield entry;
    }
  }

  @override
  Iterable<String> get keys => backingValues.keys;

  @override
  int get length => reportedLength;

  @override
  Object? operator [](Object? key) => backingValues[key];

  @override
  void operator []=(String key, Object? value) => backingValues[key] = value;

  @override
  void clear() => backingValues.clear();

  @override
  Object? remove(Object? key) => backingValues.remove(key);
}
