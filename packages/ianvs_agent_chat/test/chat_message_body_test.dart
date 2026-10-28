import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_agent_chat/ianvs_agent_chat.dart';
import 'package:ianvs_markdown/ianvs_markdown.dart';

void main() {
  testWidgets(
    'body preserves host selection and does not fetch image resources',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ChatMessageBody(
              text:
                  'First\n\nSecond\n\n![external](https://example.invalid/private.png)',
              documentSelection: true,
              softLineBreak: true,
            ),
          ),
        ),
      );
      final markdown = tester.widget<IanvsMarkdown>(find.byType(IanvsMarkdown));
      expect(markdown.documentSelection, isTrue);
      expect(markdown.softLineBreak, isTrue);
      expect(find.byType(Image), findsNothing);
    },
  );
  testWidgets('diagram engine is only invoked when explicitly injected', (
    tester,
  ) async {
    const source = '```mermaid\ngraph TD; A-->B\n```';
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: ChatMessageBody(text: source)),
      ),
    );
    expect(find.text('native diagram'), findsNothing);
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatMessageBody(
            text: source,
            diagramBuilder: (_, text) {
              calls++;
              return const Text('native diagram');
            },
          ),
        ),
      ),
    );
    expect(calls, greaterThan(0));
    expect(find.text('native diagram'), findsOneWidget);
  });
}
