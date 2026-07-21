import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/ui/components/chat_markdown_copy_parser.dart';

void main() {
  test('copies selected text across paragraphs as markdown', () {
    const parser = ChatMarkdownCopyParser('First paragraph.\n\nSecond one.');

    expect(parser.markdownForVisibleSelection('paragraph.\n\nSecond'), '''
paragraph.

Second''');
  });

  test('copies selected list items with markdown markers', () {
    const parser = ChatMarkdownCopyParser('- Alpha item\n- Beta item\n- Gamma');

    expect(parser.markdownForVisibleSelection('Alpha item\nBeta item'), '''
- Alpha item
- Beta item''');
  });

  test('copies fenced code block selection as valid markdown', () {
    const parser = ChatMarkdownCopyParser(
      '```dart\nfinal a = 1;\nprint(a);\n```',
    );

    expect(parser.markdownForVisibleSelection('final a = 1;\nprint(a);'), '''
```dart
final a = 1;
print(a);
```''');
  });

  test('copies partial strong text as valid markdown', () {
    const parser = ChatMarkdownCopyParser('Use **hello world** today.');

    expect(parser.markdownForVisibleSelection('hello'), '**hello**');
  });

  test('copies partial emphasis text as valid markdown', () {
    const parser = ChatMarkdownCopyParser('Use _gentle words_ today.');

    expect(parser.markdownForVisibleSelection('gentle'), '_gentle_');
  });

  test('copies partial inline code as valid markdown', () {
    const parser = ChatMarkdownCopyParser('Run `flutter test` now.');

    expect(parser.markdownForVisibleSelection('flutter'), '`flutter`');
  });

  test('copies partial link text as valid markdown', () {
    const parser = ChatMarkdownCopyParser(
      'Open [Flutter docs](https://flutter.dev).',
    );

    expect(
      parser.markdownForVisibleSelection('Flutter'),
      '[Flutter](https://flutter.dev)',
    );
  });

  test('falls back to selected text when selection cannot be matched', () {
    const parser = ChatMarkdownCopyParser('Known text only.');

    expect(parser.markdownForVisibleSelection('missing text'), 'missing text');
  });
}
