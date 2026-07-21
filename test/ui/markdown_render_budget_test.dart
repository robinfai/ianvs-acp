import 'package:ianvs_acp/acp/acp_input_budget.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/ui/bounded_metadata_preview.dart';
import 'package:ianvs_acp/ui/markdown_render_budget.dart';

void main() {
  group('scanMarkdownForRendering', () {
    test('counts each supported syntax marker at exact and plus one', () {
      const cases = <({String source, int tokens})>[
        (source: '# heading\n# again', tokens: 2),
        (source: '> quote\n> again', tokens: 2),
        (source: '1. first\n2. second', tokens: 2),
        (source: '1) first\n2) second', tokens: 2),
        (source: 'title\n===\nnext\n===', tokens: 2),
        (source: '*emphasis*', tokens: 2),
        (source: '[link](target)', tokens: 4),
        (source: '![image](target)', tokens: 5),
        (source: 'a | b | c', tokens: 2),
        (source: '<span><em>', tokens: 2),
        (source: '\\\n\\\n', tokens: 2),
        (source: '\\\r\\\r', tokens: 2),
        (source: '\\\r\n\\\r\n', tokens: 2),
        (source: r'\\', tokens: 2),
      ];

      for (final testCase in cases) {
        final source = testCase.source;
        final exactTokenCount = testCase.tokens;
        final exact = scanMarkdownForRendering(
          source,
          budget: AcpInputBudget(maxMarkdownSyntaxTokens: exactTokenCount),
        );
        final plusOne = scanMarkdownForRendering(
          source,
          budget: AcpInputBudget(maxMarkdownSyntaxTokens: exactTokenCount - 1),
        );

        expect(exact.useMarkdown, isTrue, reason: source);
        expect(exact.text, source, reason: source);
        expect(exact.omission, isNull, reason: source);
        expect(plusOne.useMarkdown, isFalse, reason: source);
        expect(plusOne.omission?.reason, AcpInputOmissionReason.inputLimit);
        expect(plusOne.omission?.observedAtLeast, exactTokenCount);
      }
    });

    test('falls back on a UTF-8 boundary within the byte budget', () {
      const source = '**😀😀😀**';
      const budget = AcpInputBudget(
        maxMarkdownSyntaxTokens: 1,
        maxMarkdownFallbackBytes: 9,
      );

      final decision = scanMarkdownForRendering(source, budget: budget);

      expect(decision.useMarkdown, isFalse);
      expect(decision.text, '**😀');
      expect(decision.text.runes.last, 0x1f600);
      expect(decision.omission?.resource, 'markdown syntax tokens');
      expect(decision.omission?.truncated, isTrue);
    });

    test('replaces an unpaired surrogate in the plain fallback', () {
      const source = '**\uD800tail';
      final decision = scanMarkdownForRendering(
        source,
        budget: const AcpInputBudget(
          maxMarkdownSyntaxTokens: 1,
          maxMarkdownFallbackBytes: 5,
        ),
      );

      expect(decision.useMarkdown, isFalse);
      expect(decision.text, '**\uFFFD');
    });
  });

  group('writeBoundedMetadataPreview', () {
    test('honors Unicode scalar and UTF-8 byte exact boundaries', () {
      final charExact = writeBoundedMetadataPreview(
        'é',
        budget: const AcpInputBudget(
          maxMetadataPreviewChars: 3,
          maxMetadataPreviewBytes: 16,
        ),
      );
      final charPlusOne = writeBoundedMetadataPreview(
        'éé',
        budget: const AcpInputBudget(
          maxMetadataPreviewChars: 3,
          maxMetadataPreviewBytes: 16,
        ),
      );
      final byteExact = writeBoundedMetadataPreview(
        'éé',
        budget: const AcpInputBudget(
          maxMetadataPreviewChars: 16,
          maxMetadataPreviewBytes: 6,
        ),
      );
      final bytePlusOne = writeBoundedMetadataPreview(
        'ééa',
        budget: const AcpInputBudget(
          maxMetadataPreviewChars: 16,
          maxMetadataPreviewBytes: 6,
        ),
      );

      expect(charExact.text, '"é"');
      expect(charExact.omission, isNull);
      expect(charPlusOne.omission?.reason, AcpInputOmissionReason.inputLimit);
      expect(byteExact.text, '"éé"');
      expect(byteExact.omission, isNull);
      expect(bytePlusOne.omission?.reason, AcpInputOmissionReason.inputLimit);
    });

    test('writes nested JSON with an explicit iterative traversal', () {
      final preview = writeBoundedMetadataPreview(<String, Object?>{
        'a': <Object?>[1, true, null],
        'b': <String, Object?>{'c': 'd'},
      }, budget: const AcpInputBudget());

      expect(preview.text, '{"a":[1,true,null],"b":{"c":"d"}}');
      expect(preview.omission, isNull);
    });

    test('rejects cycles and non-string keys without leaking values', () {
      final cycle = <String, Object?>{};
      cycle['secret'] = cycle;

      for (final value in <Object?>[
        cycle,
        <Object?, Object?>{1: 'non-string-key-secret'},
      ]) {
        final preview = writeBoundedMetadataPreview(
          value,
          budget: const AcpInputBudget(),
        );

        expect(preview.text, isEmpty);
        expect(
          preview.omission?.reason,
          AcpInputOmissionReason.invalidStructure,
        );
        expect(preview.text, isNot(contains('secret')));
      }
    });

    test('rejects non-finite and unknown objects without calling toString', () {
      final hostile = _HostileToString();
      for (final value in <Object?>[double.nan, double.infinity, hostile]) {
        final preview = writeBoundedMetadataPreview(
          value,
          budget: const AcpInputBudget(),
        );

        expect(preview.text, isEmpty);
        expect(
          preview.omission?.reason,
          AcpInputOmissionReason.invalidStructure,
        );
      }
      expect(hostile.calls, 0);
    });
  });
}

final class _HostileToString {
  var calls = 0;

  @override
  String toString() {
    calls += 1;
    throw StateError('hostile secret');
  }
}
