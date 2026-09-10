import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_design/ianvs_design.dart';
import 'package:ianvs_agent_chat/chat_theme.dart';
import 'package:ianvs_agent_chat/ui/components/markdown_code_block.dart';
import 'package:ianvs_agent_chat/ui/components/prompt_input.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('composer action remains legible in ${brightness.name}', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: IanvsTheme.build(brightness: brightness),
          home: Scaffold(
            body: PromptInput(
              isSending: true,
              onSend: (_, _) {},
              onStop: () {},
            ),
          ),
        ),
      );
      final button = tester.widget<FilledButton>(
        find.byKey(const Key('prompt-action-button')),
      );
      final foreground = button.style!.foregroundColor!.resolve({})!;
      final background = button.style!.backgroundColor!.resolve({})!;
      final first = foreground.computeLuminance();
      final second = background.computeLuminance();
      final ratio =
          ((first > second ? first : second) + .05) /
          ((first < second ? first : second) + .05);
      expect(ratio, greaterThanOrEqualTo(4.5));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'conversation overrides preserve inherited light and dark roles',
    (tester) async {
      final brightness = ValueNotifier(ThemeMode.light);
      addTearDown(brightness.dispose);
      late ChatThemeData resolved;
      await tester.pumpWidget(
        ValueListenableBuilder(
          valueListenable: brightness,
          builder: (context, mode, _) => MaterialApp(
            theme: IanvsTheme.light(),
            darkTheme: IanvsTheme.dark(),
            themeMode: mode,
            home: ChatTheme(
              data: const ChatThemeData(
                colors: {'userMessageSurface': Colors.purple},
                contentMaxWidth: 920,
              ),
              child: Builder(
                builder: (context) {
                  resolved = ChatTheme.of(context);
                  return ColoredBox(
                    color: resolved.surface,
                    child: Text(
                      'Conversation',
                      style: TextStyle(color: resolved.textPrimary),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );
      expect(resolved.surface, IanvsTokens.light.canvas);
      expect(resolved.bodyFontSize, 15);
      expect(resolved.userMessageSurface, Colors.purple);
      brightness.value = ThemeMode.dark;
      await tester.pumpAndSettle();
      expect(resolved.surface, IanvsTokens.dark.canvas);
      expect(resolved.textPrimary, IanvsTokens.dark.text);
      expect(resolved.warning, IanvsTokens.dark.warning);
      expect(resolved.userMessageSurface, Colors.purple);
      expect(resolved.contentMaxWidth, 920);
    },
  );

  testWidgets(
    'chat resolves the shared dark theme without a ChatTheme wrapper',
    (tester) async {
      late ChatThemeData resolved;
      await tester.pumpWidget(
        MaterialApp(
          theme: IanvsTheme.dark(),
          home: Builder(
            builder: (context) {
              resolved = ChatTheme.of(context);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(resolved.textPrimary, IanvsTokens.dark.text);
      expect(resolved.surface, IanvsTokens.dark.canvas);
      expect(resolved.border, IanvsTokens.dark.border);
    },
  );

  testWidgets('cached highlighted code repaints with the current palette', (
    tester,
  ) async {
    Widget view(Brightness brightness) => MaterialApp(
      theme: IanvsTheme.build(brightness: brightness),
      home: const Scaffold(
        body: MarkdownCodeBlock(
          source: 'final answer = 42;',
          language: 'dart',
          user: false,
        ),
      ),
    );
    await tester.pumpWidget(view(Brightness.light));
    await tester.pumpAndSettle();
    final light = tester
        .widget<SelectableText>(find.byType(SelectableText))
        .textSpan!;
    await tester.pumpWidget(view(Brightness.dark));
    await tester.pumpAndSettle();
    final dark = tester
        .widget<SelectableText>(find.byType(SelectableText))
        .textSpan!;
    expect(dark.toPlainText(), light.toPlainText());
    expect(dark.style?.color, isNot(light.style?.color));
    final surface = tester.widget<Container>(
      find.byKey(const ValueKey('markdown-code-block-surface')),
    );
    expect(
      (surface.decoration as BoxDecoration).color,
      IanvsTokens.dark.raised,
    );
    expect(tester.takeException(), isNull);
  });
}
