// ignore_for_file: invalid_use_of_internal_member

import 'dart:collection';

import 'package:ianvs_acp/acp/acp_input_budget.dart';
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

    test('checkpoint rollback restores every streaming state once', () {
      final crlf = counter(maxLines: 2);
      crlf.append('a\r');
      final crlfCheckpoint = crlf.checkpoint();
      crlf.append('\n');
      crlf.rollback(crlfCheckpoint);
      expect(crlf.append('\n').totalLines, 2);

      final high = String.fromCharCode(0xd83d);
      final low = String.fromCharCode(0xde00);
      final surrogate = counter(maxBytes: 4);
      final surrogateCheckpoint = surrogate.checkpoint();
      surrogate.append(high);
      surrogate.rollback(surrogateCheckpoint);
      final isolatedLow = surrogate.append(low);
      expect(isolatedLow.acceptedBytes, 3);
      expect(isolatedLow.totalBytes, 3);

      final omitted = counter(maxBytes: 1);
      final omittedCheckpoint = omitted.checkpoint();
      expect(omitted.append('ab').omission, isNotNull);
      omitted.rollback(omittedCheckpoint);
      expect(omitted.append('a').safePrefix, 'a');

      final finished = counter();
      final finishedCheckpoint = finished.checkpoint();
      finished.finish();
      finished.rollback(finishedCheckpoint);
      expect(finished.append('a').safePrefix, 'a');
    });

    test('checkpoint rejects cross-counter and repeated completion', () {
      final owner = counter();
      final other = counter();
      final checkpoint = owner.checkpoint();
      expect(
        () => other.rollback(checkpoint),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'ACP text budget checkpoint is not current for this counter.',
          ),
        ),
      );
      expect(other.append('a').safePrefix, 'a');

      owner.rollback(checkpoint);
      for (final complete in <void Function()>[
        () => owner.rollback(checkpoint),
        () => owner.commit(checkpoint),
      ]) {
        expect(
          complete,
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              'ACP text budget checkpoint is not current for this counter.',
            ),
          ),
        );
      }

      final committed = owner.checkpoint();
      owner.append('a');
      owner.commit(committed);
      expect(() => owner.commit(committed), throwsStateError);
      expect(() => owner.rollback(committed), throwsStateError);
    });

    test('nested checkpoints restore their respective snapshots', () {
      final value = counter(maxBytes: 2);
      final outer = value.checkpoint();
      value.append('a');
      final inner = value.checkpoint();
      value.append('b');
      value.rollback(inner);
      expect(value.append('b').totalBytes, 2);
      value.rollback(outer);

      final restored = value.append('ab');
      expect(restored.safePrefix, 'ab');
      expect(restored.totalBytes, 2);
    });

    test('nested checkpoints enforce LIFO without consuming outer tokens', () {
      for (final commitOuter in <bool>[false, true]) {
        final value = counter(maxBytes: 2);
        final outer = value.checkpoint();
        value.append('a');
        final inner = value.checkpoint();
        value.append('b');

        void finishOuter() {
          if (commitOuter) {
            value.commit(outer);
          } else {
            value.rollback(outer);
          }
        }

        expect(
          finishOuter,
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              'ACP text budget checkpoint is not current for this counter.',
            ),
          ),
        );
        value.rollback(inner);
        finishOuter();
      }
    });

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

  group('AcpStructuredUpdateGuard typed values', () {
    AcpStructuredUpdateGuard guard({
      int maxNodes = 100,
      int maxBytes = 100,
      int maxStringBytes = 100,
      int maxItems = 100,
    }) => AcpStructuredUpdateGuard(
      budget: AcpInputBudget(
        maxStructuredUpdateNodes: maxNodes,
        maxStructuredUpdateBytes: maxBytes,
        maxStructuredStringBytes: maxStringBytes,
        maxCollectionItems: maxItems,
      ),
      resource: 'ACP test update',
    );

    test('copyString accepts exact UTF-8 and rejects one byte beyond', () {
      final isolatedSurrogate = String.fromCharCode(0xd800);
      expect(
        guard(
          maxBytes: 3,
          maxStringBytes: 3,
        ).copyString(isolatedSurrogate, field: 'title'),
        same(isolatedSurrogate),
      );

      expect(
        () => guard(
          maxBytes: 3,
          maxStringBytes: 3,
        ).copyString('${isolatedSurrogate}a', field: 'title'),
        throwsA(
          isA<AcpInputLimitExceeded>()
              .having((error) => error.limit, 'limit', 3)
              .having((error) => error.observedAtLeast, 'observedAtLeast', 4),
        ),
      );
    });

    test('copyString checks its per-string limit before the root limit', () {
      expect(
        () => guard(
          maxBytes: 1,
          maxStringBytes: 1,
        ).copyString('ab', field: 'title'),
        throwsA(
          isA<AcpInputLimitExceeded>()
              .having((error) => error.resource, 'resource', contains('title'))
              .having((error) => error.limit, 'limit', 1)
              .having((error) => error.observedAtLeast, 'observedAtLeast', 2),
        ),
      );
    });

    test('copyScalar accepts exact JSON scalar byte boundaries', () {
      expect(guard(maxBytes: 4).copyScalar(null, field: 'value'), isNull);
      expect(guard(maxBytes: 4).copyScalar(true, field: 'value'), isTrue);
      expect(guard(maxBytes: 5).copyScalar(false, field: 'value'), isFalse);
      expect(guard(maxBytes: 4).copyScalar(1234, field: 'value'), 1234);
      expect(guard(maxBytes: 4).copyScalar(1.25, field: 'value'), 1.25);

      expect(
        () => guard(maxBytes: 3).copyScalar(true, field: 'value'),
        throwsA(
          isA<AcpInputLimitExceeded>()
              .having((error) => error.limit, 'limit', 3)
              .having((error) => error.observedAtLeast, 'observedAtLeast', 4),
        ),
      );
    });

    test('copyScalar handles native integer width at exact boundaries', () {
      for (final testCase in const <({int input, int bytes})>[
        (input: 0x7fffffffffffffff, bytes: 19),
        (input: -0x8000000000000000, bytes: 20),
      ]) {
        expect(
          guard(
            maxBytes: testCase.bytes,
          ).copyScalar(testCase.input, field: 'exact'),
          testCase.input,
        );
        expect(
          () => guard(
            maxBytes: testCase.bytes - 1,
          ).copyScalar(testCase.input, field: 'beyond'),
          throwsA(
            isA<AcpInputLimitExceeded>()
                .having(
                  (error) => error.resource,
                  'resource',
                  'ACP test update beyond bytes',
                )
                .having(
                  (error) => error.observedAtLeast,
                  'observedAtLeast',
                  testCase.bytes,
                ),
          ),
        );
      }
    });

    test(
      'copy methods reject invalid types without invoking payload methods',
      () {
        final canary = _RetainedValueCanary();
        for (final invalid in <Object?>[
          double.nan,
          double.infinity,
          double.negativeInfinity,
          canary,
          'string',
        ]) {
          expect(
            () => guard().copyScalar(invalid, field: 'value'),
            throwsA(
              isA<FormatException>().having(
                (error) => error.toString(),
                'message',
                isNot(contains('PAYLOAD_CANARY')),
              ),
            ),
          );
        }
        expect(
          () => guard().copyString(canary, field: 'title'),
          throwsA(isA<FormatException>()),
        );
        expect(canary.toStringCalls, 0);
        expect(canary.toJsonCalls, 0);
      },
    );

    test('one guard shares root nodes and bytes across typed fields', () {
      final shared = guard(maxNodes: 2, maxBytes: 3);
      expect(shared.copyString('ab', field: 'first'), 'ab');
      expect(
        () => shared.copyScalar(true, field: 'second'),
        throwsA(isA<AcpInputLimitExceeded>()),
      );

      final nodes = guard(maxNodes: 2);
      expect(nodes.copyScalar(null, field: 'first'), isNull);
      expect(nodes.copyScalar(null, field: 'second'), isNull);
      expect(
        () => nodes.copyScalar(null, field: 'third'),
        throwsA(isA<AcpInputLimitExceeded>()),
      );

      expect(guard(maxNodes: 1).copyScalar(null, field: 'a'), isNull);
      expect(guard(maxNodes: 1).copyScalar(null, field: 'b'), isNull);
    });

    test('failed typed call is atomic and a smaller value can continue', () {
      final value = guard(maxNodes: 1, maxBytes: 2, maxStringBytes: 3);
      expect(
        () => value.copyString('abc', field: 'large'),
        throwsA(isA<AcpInputLimitExceeded>()),
      );
      expect(value.copyString('ok', field: 'small'), 'ok');
    });

    test('checkCollection enforces reported length before element access', () {
      final exact = _ReportedLengthList(2);
      expect(guard(maxItems: 2).checkCollection(exact, field: 'items'), 2);
      expect(exact.indexReads, 0);

      final beyond = _ReportedLengthList(3);
      expect(
        () => guard(maxItems: 2).checkCollection(beyond, field: 'items'),
        throwsA(isA<AcpInputLimitExceeded>()),
      );
      expect(beyond.indexReads, 0);
      expect(
        guard(maxItems: 2).checkCollection(<String, Object?>{}, field: 'map'),
        0,
      );
      expect(
        () => guard(maxItems: 1).checkCollection(<String, Object?>{
          'a': null,
          'b': null,
        }, field: 'map'),
        throwsA(isA<AcpInputLimitExceeded>()),
      );
      expect(
        () => guard().checkCollection('not a collection', field: 'items'),
        throwsA(isA<FormatException>()),
      );
    });

    test(
      'checkCollection rejects negative reported lengths without iteration',
      () {
        final list = _NegativeLengthMetadataList();
        final map = _NegativeLengthMetadataMap();
        final value = guard();

        for (final collection in <Object?>[list, map]) {
          expect(
            () => value.checkCollection(collection, field: 'items'),
            throwsA(
              isA<FormatException>().having(
                (error) => error.toString(),
                'message',
                isNot(contains('PAYLOAD_CANARY')),
              ),
            ),
          );
        }
        expect(list.iterationReads, 0);
        expect(map.iterationReads, 0);
        expect(value.copyScalar(null, field: 'afterFailure'), isNull);
      },
    );

    test('container and entry calls model nested root node ownership', () {
      final strings = guard(maxNodes: 3, maxBytes: 2);
      strings.consumeContainerNode(field: 'strings');
      expect(strings.copyString('a', field: 'strings[]'), 'a');
      expect(strings.copyString('b', field: 'strings[]'), 'b');
      expect(
        () => strings.consumeEntry(field: 'extra'),
        throwsA(isA<AcpInputLimitExceeded>()),
      );

      final models = guard(maxNodes: 5, maxBytes: 2);
      models.consumeContainerNode(field: 'models');
      for (final value in const <String>['a', 'b']) {
        models.consumeEntry(field: 'models[]');
        models.copyString(value, field: 'models[].name');
      }
      expect(
        () => models.consumeContainerNode(field: 'nested'),
        throwsA(isA<AcpInputLimitExceeded>()),
      );
    });
  });

  group('AcpStructuredUpdateGuard metadata', () {
    AcpStructuredUpdateGuard guard({
      int maxDepth = 100,
      int maxNodes = 100,
      int maxEntries = 100,
      int maxMetadataBytes = 100,
      int maxRootNodes = 100,
      int maxRootBytes = 100,
      int maxStringBytes = 100,
      int maxItems = 100,
    }) => AcpStructuredUpdateGuard(
      budget: AcpInputBudget(
        maxJsonDepth: maxDepth,
        maxMetadataDepth: maxDepth,
        maxMetadataNodes: maxNodes,
        maxMetadataEntries: maxEntries,
        maxMetadataBytes: maxMetadataBytes,
        maxStructuredUpdateNodes: maxRootNodes,
        maxStructuredUpdateBytes: maxRootBytes,
        maxStructuredStringBytes: maxStringBytes,
        maxCollectionItems: maxItems,
      ),
      resource: 'ACP test update',
    );

    final reentrantCalls =
        <({String name, void Function(AcpStructuredUpdateGuard guard) call})>[
          (
            name: 'copyString',
            call: (value) => value.copyString('a', field: 'reentrant'),
          ),
          (
            name: 'copyScalar',
            call: (value) => value.copyScalar(null, field: 'reentrant'),
          ),
          (
            name: 'checkCollection',
            call: (value) =>
                value.checkCollection(<Object?>[], field: 'reentrant'),
          ),
          (
            name: 'copyMetadata null',
            call: (value) => value.copyMetadata(null, field: 'reentrant'),
          ),
          (
            name: 'copyMetadata map',
            call: (value) =>
                value.copyMetadata(<String, Object?>{}, field: 'reentrant'),
          ),
          (
            name: 'copyJsonValue',
            call: (value) =>
                value.copyJsonValue(<Object?>[], field: 'reentrant'),
          ),
          (
            name: 'consumeContainerNode',
            call: (value) => value.consumeContainerNode(field: 'reentrant'),
          ),
          (
            name: 'consumeEntry',
            call: (value) => value.consumeEntry(field: 'reentrant'),
          ),
        ];

    for (final testCase in reentrantCalls) {
      test('root length rejects reentrant ${testCase.name}', () {
        late AcpStructuredUpdateGuard value;
        final source = _ReentrantMetadataMap(
          stage: _MetadataReentryStage.length,
          onReenter: () => testCase.call(value),
        );
        value = guard(maxRootNodes: 1, maxRootBytes: 4);
        Map<String, Object?>? partial;

        expect(
          () => partial = value.copyMetadata(source, field: 'metadata'),
          throwsA(
            isA<FormatException>().having(
              (error) => error.toString(),
              'message',
              isNot(contains('PAYLOAD_CANARY')),
            ),
          ),
        );
        expect(partial, isNull);
        expect(value.copyScalar(null, field: 'afterFailure'), isNull);
      });
    }

    test('returns a detached deeply immutable metadata copy', () {
      final nestedList = <Object?>[
        <String, Object?>{'value': 1},
      ];
      final source = <String, Object?>{'nested': nestedList};
      final copy = guard().copyMetadata(source, field: 'metadata');

      nestedList.add(2);
      (nestedList.first as Map<String, Object?>)['value'] = 3;
      source['later'] = true;

      expect(copy, <String, Object?>{
        'nested': <Object?>[
          <String, Object?>{'value': 1},
        ],
      });
      expect(() => copy['x'] = null, throwsUnsupportedError);
      final copiedList = copy['nested'] as List<Object?>;
      expect(() => copiedList.add(null), throwsUnsupportedError);
      expect(
        () => (copiedList.first as Map<String, Object?>)['value'] = 2,
        throwsUnsupportedError,
      );

      final absent = guard(
        maxNodes: 1,
        maxMetadataBytes: 1,
        maxRootNodes: 1,
        maxRootBytes: 1,
      );
      final empty = absent.copyMetadata(null, field: 'metadata');
      expect(empty, isEmpty);
      expect(() => empty['x'] = null, throwsUnsupportedError);
      expect(absent.copyString('a', field: 'title'), 'a');
    });

    test('copies any JSON value without injecting wrapper budget', () {
      final source = <Object?>[
        'é',
        <String, Object?>{'x': null},
      ];
      final value = guard(
        maxNodes: 4,
        maxMetadataBytes: 7,
        maxRootNodes: 4,
        maxRootBytes: 7,
      );
      final copy = value.copyJsonValue(source, field: 'json value');

      expect(copy, <Object?>[
        'é',
        <String, Object?>{'x': null},
      ]);
      final copiedList = copy as List<Object?>;
      expect(() => copiedList.add(null), throwsUnsupportedError);
      expect(
        () => (copiedList[1] as Map<String, Object?>)['y'] = true,
        throwsUnsupportedError,
      );
      expect(
        () => value.consumeEntry(field: 'beyond exact root'),
        throwsA(isA<AcpInputLimitExceeded>()),
      );

      final failed = guard(
        maxNodes: 3,
        maxMetadataBytes: 7,
        maxRootNodes: 3,
        maxRootBytes: 7,
      );
      expect(
        () => failed.copyJsonValue(source, field: 'json value'),
        throwsA(isA<AcpInputLimitExceeded>()),
      );
      expect(failed.copyScalar(null, field: 'after failure'), isNull);
    });

    test('copyJsonValue rejects malformed roots transactionally', () {
      final cycle = <Object?>[];
      cycle.add(cycle);
      final invalid = <Object?>[
        cycle,
        <Object?, Object?>{1: null},
        double.nan,
        double.infinity,
        _RetainedValueCanary(),
        _NegativeLengthMetadataList(),
        _NegativeLengthMetadataMap(),
      ];
      for (final input in invalid) {
        final value = guard(maxRootNodes: 1, maxRootBytes: 4);
        expect(
          () => value.copyJsonValue(input, field: 'json value'),
          throwsA(
            predicate<Object>(
              (error) => !error.toString().contains('PAYLOAD_CANARY'),
              'payload-free',
            ),
          ),
        );
        expect(value.copyScalar(null, field: 'after failure'), isNull);
      }
    });

    test('metadata nodes accept exact local and root boundaries', () {
      final input = <String, Object?>{'a': 'b'};
      expect(
        guard(
          maxNodes: 2,
          maxRootNodes: 2,
        ).copyMetadata(input, field: 'metadata'),
        input,
      );
      final localNodes = guard(maxNodes: 1, maxRootNodes: 1);
      expect(
        () => localNodes.copyMetadata(input, field: 'metadata'),
        throwsA(
          isA<AcpInputLimitExceeded>()
              .having((error) => error.limit, 'limit', 1)
              .having((error) => error.observedAtLeast, 'observedAtLeast', 2),
        ),
      );
      expect(
        localNodes.copyMetadata(<String, Object?>{}, field: 'afterFailure'),
        isEmpty,
      );

      final rootNodes = guard(maxRootNodes: 1);
      expect(
        () => rootNodes.copyMetadata(input, field: 'metadata'),
        throwsA(isA<AcpInputLimitExceeded>()),
      );
      expect(
        rootNodes.copyMetadata(<String, Object?>{}, field: 'afterFailure'),
        isEmpty,
      );
    });

    test('metadata depth accepts exact boundary and rejects one beyond', () {
      final input = <String, Object?>{
        'a': <Object?>[null],
      };
      expect(guard(maxDepth: 3).copyMetadata(input, field: 'metadata'), input);
      expect(
        () => guard(maxDepth: 2).copyMetadata(input, field: 'metadata'),
        throwsA(
          isA<AcpInputLimitExceeded>()
              .having((error) => error.limit, 'limit', 2)
              .having((error) => error.observedAtLeast, 'observedAtLeast', 3),
        ),
      );
    });

    test('metadata map entries and list lengths share the tighter cap', () {
      final map = <String, Object?>{'a': null, 'b': null};
      expect(
        guard(maxEntries: 2, maxItems: 2).copyMetadata(map, field: 'metadata'),
        map,
      );
      expect(
        () => guard(maxEntries: 1).copyMetadata(map, field: 'metadata'),
        throwsA(isA<AcpInputLimitExceeded>()),
      );
      expect(
        () => guard(maxEntries: 1).copyMetadata(<String, Object?>{
          'list': <Object?>[null, null],
        }, field: 'metadata'),
        throwsA(isA<AcpInputLimitExceeded>()),
      );
    });

    test('metadata bytes and individual strings have exact boundaries', () {
      final input = <String, Object?>{'é': '€'};
      expect(
        guard(
          maxMetadataBytes: 5,
          maxRootBytes: 5,
          maxStringBytes: 3,
        ).copyMetadata(input, field: 'metadata'),
        input,
      );
      final localBytes = guard(maxMetadataBytes: 4, maxRootBytes: 4);
      expect(
        () => localBytes.copyMetadata(input, field: 'metadata'),
        throwsA(isA<AcpInputLimitExceeded>()),
      );
      expect(
        localBytes.copyMetadata(<String, Object?>{'': null}, field: 'exact'),
        <String, Object?>{'': null},
      );

      final rootBytes = guard(maxRootBytes: 4);
      expect(
        () => rootBytes.copyMetadata(input, field: 'metadata'),
        throwsA(isA<AcpInputLimitExceeded>()),
      );
      expect(
        rootBytes.copyMetadata(<String, Object?>{'': null}, field: 'exact'),
        <String, Object?>{'': null},
      );
      expect(
        () => guard(maxStringBytes: 2).copyMetadata(input, field: 'metadata'),
        throwsA(
          isA<AcpInputLimitExceeded>()
              .having((error) => error.limit, 'limit', 2)
              .having((error) => error.observedAtLeast, 'observedAtLeast', 3),
        ),
      );
    });

    test('metadata handles native integer width at exact boundaries', () {
      for (final testCase in const <({int input, int bytes})>[
        (input: 0x7fffffffffffffff, bytes: 19),
        (input: -0x8000000000000000, bytes: 20),
      ]) {
        expect(
          guard(
            maxMetadataBytes: testCase.bytes,
            maxRootBytes: testCase.bytes,
          ).copyMetadata(<String, Object?>{
            '': testCase.input,
          }, field: 'metadata'),
          <String, Object?>{'': testCase.input},
        );
        expect(
          () =>
              guard(
                maxMetadataBytes: testCase.bytes - 1,
                maxRootBytes: testCase.bytes - 1,
              ).copyMetadata(<String, Object?>{
                '': testCase.input,
              }, field: 'metadata'),
          throwsA(
            isA<AcpInputLimitExceeded>()
                .having(
                  (error) => error.resource,
                  'resource',
                  'ACP test update metadata metadata bytes',
                )
                .having(
                  (error) => error.observedAtLeast,
                  'observedAtLeast',
                  testCase.bytes,
                ),
          ),
        );
      }
    });

    test('typed fields and metadata share one root budget', () {
      final exact = guard(maxRootNodes: 3, maxRootBytes: 6);
      exact.copyString('a', field: 'title');
      expect(
        exact.copyMetadata(<String, Object?>{'b': null}, field: 'metadata'),
        <String, Object?>{'b': null},
      );

      final nodes = guard(maxRootNodes: 2);
      nodes.copyString('a', field: 'title');
      expect(
        () =>
            nodes.copyMetadata(<String, Object?>{'b': null}, field: 'metadata'),
        throwsA(isA<AcpInputLimitExceeded>()),
      );
      expect(nodes.copyScalar(null, field: 'afterFailure'), isNull);

      final bytes = guard(maxRootBytes: 4);
      bytes.copyString('a', field: 'title');
      expect(
        () =>
            bytes.copyMetadata(<String, Object?>{'b': null}, field: 'metadata'),
        throwsA(isA<AcpInputLimitExceeded>()),
      );
      expect(bytes.copyString('bbb', field: 'afterFailure'), 'bbb');
    });

    test('rejects cycles but copies shared non-cyclic aliases twice', () {
      final cycle = <String, Object?>{};
      cycle['self'] = cycle;
      final cycleGuard = guard(
        maxNodes: 2,
        maxMetadataBytes: 4,
        maxRootNodes: 2,
        maxRootBytes: 4,
      );
      Map<String, Object?>? partial;
      expect(
        () => partial = cycleGuard.copyMetadata(cycle, field: 'metadata'),
        throwsA(isA<FormatException>()),
      );
      expect(partial, isNull);
      expect(
        cycleGuard.copyMetadata(<String, Object?>{'': null}, field: 'exact'),
        <String, Object?>{'': null},
      );

      final shared = <Object?>[1];
      final copy = guard().copyMetadata(<String, Object?>{
        'first': shared,
        'second': shared,
      }, field: 'metadata');
      expect(copy['first'], <Object?>[1]);
      expect(copy['second'], <Object?>[1]);
      expect(identical(copy['first'], copy['second']), isFalse);
    });

    test('rejects non-JSON metadata without invoking payload methods', () {
      final canary = _RetainedValueCanary();
      for (final invalid in <Object?>[
        <Object?, Object?>{1: null},
        <String, Object?>{'value': double.nan},
        <String, Object?>{'value': double.infinity},
        <String, Object?>{'value': canary},
        <Object?>[],
      ]) {
        final value = guard();
        expect(
          () => value.copyMetadata(invalid, field: 'metadata'),
          throwsA(
            isA<FormatException>().having(
              (error) => error.toString(),
              'message',
              isNot(contains('PAYLOAD_CANARY')),
            ),
          ),
        );
        expect(
          value.copyMetadata(<String, Object?>{}, field: 'afterFailure'),
          isEmpty,
        );
      }
      expect(canary.toStringCalls, 0);
      expect(canary.toJsonCalls, 0);
    });

    test(
      'sanitizes malicious collection failures and bounds underreporting',
      () {
        for (final input in <Map<Object?, Object?>>[
          _ThrowingMetadataMap(throwFromLength: true),
          _ThrowingMetadataMap(throwFromLength: false),
          <String, Object?>{'list': _ThrowingMetadataList()},
        ]) {
          final value = guard();
          expect(
            () => value.copyMetadata(input, field: 'metadata'),
            throwsA(
              isA<FormatException>().having(
                (error) => error.toString(),
                'message',
                isNot(contains('PAYLOAD_CANARY')),
              ),
            ),
          );
          expect(value.copyString('a', field: 'afterFailure'), 'a');
        }

        final underreported = _UnderreportedRetainedMap(
          reportedLength: 0,
          backingValues: <String, Object?>{
            'a': null,
            'b': null,
            'c': null,
            'd': null,
          },
        );
        expect(
          () => guard(
            maxEntries: 2,
          ).copyMetadata(underreported, field: 'metadata'),
          throwsA(isA<AcpInputLimitExceeded>()),
        );
        expect(underreported.entriesVisited, 3);
      },
    );

    test('reported collection length fails before nested traversal', () {
      final huge = _ReportedLengthList(3);
      expect(
        () => guard(
          maxEntries: 2,
          maxItems: 2,
        ).copyMetadata(<String, Object?>{'huge': huge}, field: 'metadata'),
        throwsA(isA<AcpInputLimitExceeded>()),
      );
      expect(huge.indexReads, 0);
    });

    test(
      'metadata rejects negative lengths transactionally without iteration',
      () {
        final rootMap = _NegativeLengthMetadataMap();
        final rootGuard = guard(maxRootNodes: 1);
        expect(
          () => rootGuard.copyMetadata(rootMap, field: 'metadata'),
          throwsA(
            isA<FormatException>().having(
              (error) => error.toString(),
              'message',
              isNot(contains('PAYLOAD_CANARY')),
            ),
          ),
        );
        expect(rootMap.iterationReads, 0);
        expect(
          rootGuard.copyMetadata(<String, Object?>{}, field: 'afterFailure'),
          isEmpty,
        );

        final nestedList = _NegativeLengthMetadataList();
        final nestedGuard = guard(
          maxNodes: 2,
          maxMetadataBytes: 4,
          maxRootNodes: 2,
          maxRootBytes: 4,
        );
        expect(
          () => nestedGuard.copyMetadata(<String, Object?>{
            'list': nestedList,
          }, field: 'metadata'),
          throwsA(
            isA<FormatException>().having(
              (error) => error.toString(),
              'message',
              isNot(contains('PAYLOAD_CANARY')),
            ),
          ),
        );
        expect(nestedList.iterationReads, 0);
        expect(
          nestedGuard.copyMetadata(<String, Object?>{'': null}, field: 'exact'),
          <String, Object?>{'': null},
        );
      },
    );

    test('underreported list prechecks actual nodes before current', () {
      final list = _UnderreportedCurrentTrapList();
      final value = guard(
        maxNodes: 2,
        maxMetadataBytes: 4,
        maxRootNodes: 2,
        maxRootBytes: 4,
      );
      Object? failure;

      try {
        value.copyMetadata(<String, Object?>{'list': list}, field: 'metadata');
      } catch (error) {
        failure = error;
      }

      expect(
        failure,
        isA<AcpInputLimitExceeded>()
            .having(
              (error) => error.resource,
              'resource',
              'ACP test update metadata metadata nodes',
            )
            .having((error) => error.limit, 'limit', 2)
            .having((error) => error.observedAtLeast, 'observedAtLeast', 3)
            .having(
              (error) => error.toString(),
              'message',
              isNot(contains('PAYLOAD_CANARY')),
            ),
      );
      expect(list.currentReads, 0);
      expect(
        value.copyMetadata(<String, Object?>{'': null}, field: 'exact'),
        <String, Object?>{'': null},
      );
    });

    test('underreported map prechecks actual nodes before current or key', () {
      final source = _UnderreportedCurrentTrapMap();
      final value = guard(maxNodes: 1, maxRootNodes: 1);
      Object? failure;

      try {
        value.copyMetadata(source, field: 'metadata');
      } catch (error) {
        failure = error;
      }

      expect(
        failure,
        isA<AcpInputLimitExceeded>()
            .having(
              (error) => error.resource,
              'resource',
              'ACP test update metadata metadata nodes',
            )
            .having((error) => error.limit, 'limit', 1)
            .having((error) => error.observedAtLeast, 'observedAtLeast', 2)
            .having(
              (error) => error.toString(),
              'message',
              isNot(contains('PAYLOAD_CANARY')),
            ),
      );
      expect(source.currentOrKeyReads, 0);
      expect(
        value.copyMetadata(<String, Object?>{}, field: 'afterFailure'),
        isEmpty,
      );
    });

    test('metadata failure rolls back before every subsequent API', () {
      final value = guard(maxRootNodes: 4, maxRootBytes: 5);
      Map<String, Object?>? partial;
      expect(
        () => partial = value.copyMetadata(<String, Object?>{
          'bad': double.nan,
        }, field: 'metadata'),
        throwsA(isA<FormatException>()),
      );
      expect(partial, isNull);
      expect(value.copyString('a', field: 'title'), 'a');
      expect(value.checkCollection(<Object?>[], field: 'items'), 0);
      value.consumeContainerNode(field: 'container');
      value.consumeEntry(field: 'entry');
      expect(value.copyScalar(null, field: 'value'), isNull);
      expect(value.copyMetadata(null, field: 'metadata'), isEmpty);
    });

    test('rejects reentrancy from root entries before mutation', () {
      late AcpStructuredUpdateGuard value;
      final source = _ReentrantMetadataMap(
        stage: _MetadataReentryStage.entries,
        onReenter: () => value.copyString('a', field: 'PAYLOAD_CANARY'),
      );
      value = guard(maxRootNodes: 1, maxRootBytes: 4);
      Map<String, Object?>? partial;

      expect(
        () => partial = value.copyMetadata(source, field: 'metadata'),
        throwsA(
          isA<FormatException>().having(
            (error) => error.toString(),
            'message',
            isNot(contains('PAYLOAD_CANARY')),
          ),
        ),
      );
      expect(partial, isNull);
      expect(value.copyScalar(null, field: 'afterFailure'), isNull);
    });

    test('rejects reentrancy from root iterator current before mutation', () {
      late AcpStructuredUpdateGuard value;
      final source = _ReentrantMetadataMap(
        stage: _MetadataReentryStage.current,
        onReenter: () => value.consumeEntry(field: 'PAYLOAD_CANARY'),
      );
      value = guard(
        maxNodes: 2,
        maxMetadataBytes: 4,
        maxRootNodes: 2,
        maxRootBytes: 4,
      );
      Map<String, Object?>? partial;

      expect(
        () => partial = value.copyMetadata(source, field: 'metadata'),
        throwsA(
          isA<FormatException>().having(
            (error) => error.toString(),
            'message',
            isNot(contains('PAYLOAD_CANARY')),
          ),
        ),
      );
      expect(partial, isNull);
      expect(
        value.copyMetadata(<String, Object?>{'': null}, field: 'exact'),
        <String, Object?>{'': null},
      );
    });

    test('rejects reentrancy from nested list iterator before mutation', () {
      late AcpStructuredUpdateGuard value;
      final list = _ReentrantMetadataList(
        onReenter: () => value.copyScalar(null, field: 'PAYLOAD_CANARY'),
      );
      value = guard(
        maxNodes: 2,
        maxMetadataBytes: 4,
        maxRootNodes: 2,
        maxRootBytes: 4,
      );
      Map<String, Object?>? partial;

      expect(
        () => partial = value.copyMetadata(<String, Object?>{
          'list': list,
        }, field: 'metadata'),
        throwsA(
          isA<FormatException>().having(
            (error) => error.toString(),
            'message',
            isNot(contains('PAYLOAD_CANARY')),
          ),
        ),
      );
      expect(partial, isNull);
      expect(
        value.copyMetadata(<String, Object?>{'': null}, field: 'exact'),
        <String, Object?>{'': null},
      );
    });

    test('caught reentrant failure consumes no hidden root budget', () {
      late AcpStructuredUpdateGuard value;
      StateError? innerFailure;
      final source = _ReentrantMetadataMap(
        stage: _MetadataReentryStage.length,
        onReenter: () {
          try {
            value.copyString('a', field: 'PAYLOAD_CANARY');
          } on StateError catch (error) {
            innerFailure = error;
          }
        },
      );
      value = guard(maxRootNodes: 2, maxRootBytes: 1);

      expect(value.copyMetadata(source, field: 'metadata'), isEmpty);
      expect(
        innerFailure.toString(),
        allOf(isNot(contains('PAYLOAD_CANARY')), contains('metadata copy')),
      );
      expect(value.copyString('a', field: 'afterMetadata'), 'a');
      expect(
        () => value.consumeEntry(field: 'beyond'),
        throwsA(isA<AcpInputLimitExceeded>()),
      );
    });

    test('uses an explicit stack for 3000 nested containers', () {
      const containerDepth = 3000;
      Object? nested;
      for (var index = 0; index < containerDepth; index += 1) {
        nested = <Object?>[nested];
      }
      final input = <String, Object?>{'value': nested};

      final copy = guard(
        maxDepth: containerDepth + 2,
        maxNodes: containerDepth + 2,
        maxEntries: 1,
        maxRootNodes: containerDepth + 2,
        maxItems: 1,
      ).copyMetadata(input, field: 'metadata');
      Object? cursor = copy['value'];
      for (var index = 0; index < containerDepth; index += 1) {
        expect(cursor, isA<List<Object?>>());
        final list = cursor! as List<Object?>;
        expect(list, hasLength(1));
        cursor = list.first;
      }
      expect(cursor, isNull);
    });
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

final class _ThrowingMetadataMap extends MapBase<Object?, Object?> {
  _ThrowingMetadataMap({required this.throwFromLength});

  final bool throwFromLength;

  @override
  int get length {
    if (throwFromLength) throw StateError('PAYLOAD_CANARY length');
    return 1;
  }

  @override
  Iterable<MapEntry<Object?, Object?>> get entries sync* {
    throw StateError('PAYLOAD_CANARY iterator');
  }

  @override
  Iterable<Object?> get keys => const <Object?>[];

  @override
  Object? operator [](Object? key) => null;

  @override
  void operator []=(Object? key, Object? value) =>
      throw UnsupportedError('read only');

  @override
  void clear() => throw UnsupportedError('read only');

  @override
  Object? remove(Object? key) => throw UnsupportedError('read only');
}

final class _ThrowingMetadataList extends ListBase<Object?> {
  @override
  int get length => 1;

  @override
  set length(int value) => throw UnsupportedError('read only');

  @override
  Object? operator [](int index) => throw StateError('PAYLOAD_CANARY element');

  @override
  void operator []=(int index, Object? value) =>
      throw UnsupportedError('read only');
}

final class _UnderreportedCurrentTrapList extends ListBase<Object?> {
  var currentReads = 0;

  @override
  int get length => 0;

  @override
  set length(int value) => throw UnsupportedError('read only');

  @override
  Iterator<Object?> get iterator => _CurrentTrapIterator<Object?>(() {
    currentReads += 1;
    throw StateError('PAYLOAD_CANARY list current');
  });

  @override
  Object? operator [](int index) => null;

  @override
  void operator []=(int index, Object? value) =>
      throw UnsupportedError('read only');
}

final class _UnderreportedCurrentTrapMap extends MapBase<Object?, Object?> {
  var currentOrKeyReads = 0;

  @override
  int get length => 0;

  @override
  Iterable<MapEntry<Object?, Object?>> get entries =>
      _CurrentTrapIterable<MapEntry<Object?, Object?>>(() {
        currentOrKeyReads += 1;
        throw StateError('PAYLOAD_CANARY map current or key');
      });

  @override
  Iterable<Object?> get keys => const <Object?>[];

  @override
  Object? operator [](Object? key) => null;

  @override
  void operator []=(Object? key, Object? value) =>
      throw UnsupportedError('read only');

  @override
  void clear() => throw UnsupportedError('read only');

  @override
  Object? remove(Object? key) => throw UnsupportedError('read only');
}

final class _CurrentTrapIterable<T> extends Iterable<T> {
  _CurrentTrapIterable(this._readCurrent);

  final T Function() _readCurrent;

  @override
  Iterator<T> get iterator => _CurrentTrapIterator<T>(_readCurrent);
}

final class _CurrentTrapIterator<T> implements Iterator<T> {
  _CurrentTrapIterator(this._readCurrent);

  final T Function() _readCurrent;
  var _moved = false;

  @override
  T get current => _readCurrent();

  @override
  bool moveNext() {
    if (_moved) return false;
    _moved = true;
    return true;
  }
}

final class _NegativeLengthMetadataList extends ListBase<Object?> {
  var iterationReads = 0;

  @override
  int get length => -1;

  @override
  set length(int value) => throw UnsupportedError('read only');

  @override
  Iterator<Object?> get iterator {
    iterationReads += 1;
    throw StateError('PAYLOAD_CANARY negative list iterator');
  }

  @override
  Object? operator [](int index) => null;

  @override
  void operator []=(int index, Object? value) =>
      throw UnsupportedError('read only');
}

final class _NegativeLengthMetadataMap extends MapBase<Object?, Object?> {
  var iterationReads = 0;

  @override
  int get length => -1;

  @override
  Iterable<MapEntry<Object?, Object?>> get entries {
    iterationReads += 1;
    throw StateError('PAYLOAD_CANARY negative map iterator');
  }

  @override
  Iterable<Object?> get keys => const <Object?>[];

  @override
  Object? operator [](Object? key) => null;

  @override
  void operator []=(Object? key, Object? value) =>
      throw UnsupportedError('read only');

  @override
  void clear() => throw UnsupportedError('read only');

  @override
  Object? remove(Object? key) => throw UnsupportedError('read only');
}

enum _MetadataReentryStage { length, entries, current }

final class _ReentrantMetadataMap extends MapBase<Object?, Object?> {
  _ReentrantMetadataMap({required this.stage, required this.onReenter});

  final _MetadataReentryStage stage;
  final void Function() onReenter;

  @override
  int get length {
    if (stage == _MetadataReentryStage.length) onReenter();
    return 0;
  }

  @override
  Iterable<MapEntry<Object?, Object?>> get entries {
    if (stage == _MetadataReentryStage.entries) {
      onReenter();
      return const <MapEntry<Object?, Object?>>[];
    }
    if (stage == _MetadataReentryStage.current) {
      return _CurrentTrapIterable<MapEntry<Object?, Object?>>(() {
        onReenter();
        return const MapEntry<Object?, Object?>('', null);
      });
    }
    return const <MapEntry<Object?, Object?>>[];
  }

  @override
  Iterable<Object?> get keys => const <Object?>[];

  @override
  Object? operator [](Object? key) => null;

  @override
  void operator []=(Object? key, Object? value) =>
      throw UnsupportedError('read only');

  @override
  void clear() => throw UnsupportedError('read only');

  @override
  Object? remove(Object? key) => throw UnsupportedError('read only');
}

final class _ReentrantMetadataList extends ListBase<Object?> {
  _ReentrantMetadataList({required this.onReenter});

  final void Function() onReenter;

  @override
  int get length => 0;

  @override
  set length(int value) => throw UnsupportedError('read only');

  @override
  Iterator<Object?> get iterator {
    onReenter();
    return const <Object?>[].iterator;
  }

  @override
  Object? operator [](int index) => null;

  @override
  void operator []=(int index, Object? value) =>
      throw UnsupportedError('read only');
}
