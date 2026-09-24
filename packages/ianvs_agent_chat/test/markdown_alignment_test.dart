import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_agent_chat/ianvs_agent_chat.dart';
import 'package:ianvs_agent_chat/ui/markdown_render_budget.dart' as chat;
import 'package:ianvs_markdown/ianvs_markdown.dart' as markdown;

void main() {
  const source =
      '%%literal comment%%\n\nKeep ^block-id and [[wiki]] and \$price.\n\n'
      '| Left | Right |\n| --- | --- |\n| **bold** | `code` |\n\n'
      '```dart\nfinal answer = 42;\n```';

  testWidgets(
    'chat uses the public standard renderer without source normalization',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatTimeline(
              messages: [
                ChatMessageData(role: ChatMessageRole.assistant, text: source),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final renderer = tester.widget<markdown.IanvsMarkdown>(
        find.byType(markdown.IanvsMarkdown),
      );
      expect(
        renderer.syntaxPreset,
        markdown.IanvsMarkdownSyntaxPreset.standard,
      );
      expect(renderer.documentSelection, isFalse);
      expect(renderer.renderBudget, isNotNull);
      expect(renderer.theme, isNull);
      expect(renderer.styleSheet, isNull);
      expect(renderer.builders, isEmpty);
      expect(renderer.enableFileLinkChips, isTrue);
      expect(renderer.diagramBuilder, isNotNull);
      expect(
        tester.widget<MarkdownBody>(find.byType(MarkdownBody)).data,
        source,
      );
      final style = tester
          .widget<MarkdownBody>(find.byType(MarkdownBody))
          .styleSheet!;
      expect(style.p!.fontSize, 14.5);
      expect(
        style.strong!.color,
        markdown.IanvsMarkdownThemeData.light.strongForeground,
      );
      expect(
        style.em!.color,
        markdown.IanvsMarkdownThemeData.light.emphasisForeground,
      );
      expect(
        style.code!.color,
        markdown.IanvsMarkdownThemeData.light.inlineCodeForeground,
      );
    },
  );

  test(
    'chat and public standard scanner share exact boundaries and unicode fallback',
    () {
      const budget = ChatInputBudget(
        maxMarkdownSyntaxTokens: 32,
        maxMarkdownFallbackBytes: 9,
      );
      for (final input in [
        source,
        '*' * 32,
        '*' * 33,
        '\$' * 5000,
        '😀中' * 8 + '*' * 33,
      ]) {
        final outer = chat.scanMarkdownForRendering(input, budget: budget);
        final inner = markdown.scanMarkdownForRendering(
          input,
          syntaxPreset: markdown.IanvsMarkdownSyntaxPreset.standard,
          budget: const markdown.IanvsMarkdownRenderBudget(
            maxSyntaxTokens: 32,
            maxFallbackBytes: 9,
          ),
        );
        expect(
          (outer.text, outer.useMarkdown),
          (inner.text, inner.useMarkdown),
        );
        expect(outer.omission != null, !inner.useMarkdown);
      }
      expect(
        chat.scanMarkdownForRendering('\$' * 5000, budget: budget).useMarkdown,
        isTrue,
      );
    },
  );
}
