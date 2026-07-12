import 'package:dart_acp/dart_acp.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
