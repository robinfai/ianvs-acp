import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/ui/components/markdown_code_block.dart';

void main() {
  Widget app(Widget child) {
    return MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: 820, child: child),
          ),
        ),
      ),
    );
  }

  testWidgets('fenced code renders language, highlighting, copy, and wrap', (
    tester,
  ) async {
    String? clipboardText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          final arguments = call.arguments as Map<Object?, Object?>;
          clipboardText = arguments['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });
    const source = 'package main\n\nfunc main() {\n\tprintln("hello")\n}';

    await tester.pumpWidget(
      app(
        MarkdownBody(
          data: '```go\n$source\n```',
          builders: <String, MarkdownElementBuilder>{
            'pre': MarkdownCodeBlockBuilder(user: false),
          },
        ),
      ),
    );

    expect(find.byType(MarkdownCodeBlock), findsOneWidget);
    expect(find.text('GO'), findsOneWidget);
    final selectable = tester.widget<SelectableText>(
      find.byType(SelectableText),
    );
    expect(selectable.textSpan?.toPlainText(), source);
    expect(selectable.textSpan?.children, isNotEmpty);

    await tester.tap(find.byTooltip('复制代码'));
    await tester.pump();
    expect(clipboardText, source);
    expect(find.byTooltip('已复制'), findsOneWidget);

    await tester.tap(find.byTooltip('自动换行'));
    await tester.pump();
    expect(find.byTooltip('关闭自动换行'), findsOneWidget);
  });

  testWidgets('long code blocks collapse and expand', (tester) async {
    final source = List<String>.generate(
      32,
      (index) => 'final value$index = $index;',
    ).join('\n');

    await tester.pumpWidget(
      app(MarkdownCodeBlock(source: source, language: 'dart', user: false)),
    );

    expect(find.text('展开'), findsOneWidget);
    final region = find.byKey(const ValueKey('code-block-scroll-region'));
    expect(region, findsOneWidget);
    expect(tester.getSize(region).height, lessThanOrEqualTo(320));
    final fades = find.descendant(
      of: region,
      matching: find.byType(AnimatedOpacity),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<AnimatedOpacity>(fades.first).opacity, 0);
    expect(tester.widget<AnimatedOpacity>(fades.last).opacity, 1);

    await tester.tap(find.text('展开'));
    await tester.pump();
    expect(find.text('收起'), findsOneWidget);
    await tester.tap(find.text('收起'));
    await tester.pump();
    expect(find.text('展开'), findsOneWidget);
  });

  test('normalizes language aliases and labels', () {
    expect(normalizeMarkdownCodeLanguage('sh'), 'bash');
    expect(normalizeMarkdownCodeLanguage('TSX'), 'typescript');
    expect(normalizeMarkdownCodeLanguage('c++'), 'cpp');
    expect(markdownCodeLanguageLabel('sh'), 'SHELL');
    expect(markdownCodeLanguageLabel('csharp'), 'C#');
    expect(markdownCodeLanguageLabel(null), 'TEXT');
  });

  test('large code blocks skip syntax highlighting', () {
    expect(
      markdownCodeCanHighlight(
        List<String>.filled(
          markdownCodeHighlightCharacterLimit + 1,
          'x',
        ).join(),
      ),
      isFalse,
    );
    expect(
      markdownCodeCanHighlight(
        List<String>.filled(
          markdownCodeHighlightLineLimit + 1,
          'line',
        ).join('\n'),
      ),
      isFalse,
    );
    expect(markdownCodeCanHighlight('final value = 1;'), isTrue);
  });
}
