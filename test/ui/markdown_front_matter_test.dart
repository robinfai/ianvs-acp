import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/ui/file_preview/markdown_front_matter.dart';

void main() {
  test('parses bounded YAML front matter and keeps the Markdown body', () {
    final document = parseMarkdownFrontMatter('''
---
title: SSH Internals
author: Robin
date: 2026-07-29
tags:
  - ssh
  - security
draft: false
repository:
  branch: main
---
# Document heading

Body text.
''');

    expect(document.hasFrontMatter, isTrue);
    expect(document.body, startsWith('# Document heading'));
    expect(
      document.entries.map((entry) => entry.label),
      containsAll(<String>['标题', '作者', '日期', '标签', '草稿']),
    );
    final tags = document.entries.singleWhere((entry) => entry.label == '标签');
    expect(tags.items, <String>['ssh', 'security']);
    expect(
      document.entries.singleWhere((entry) => entry.key == 'draft').value,
      '否',
    );
    expect(
      document.entries
          .singleWhere((entry) => entry.key == 'repository.branch')
          .value,
      'main',
    );
  });

  test('invalid or unclosed front matter falls back to original Markdown', () {
    const invalid = '''
---
title: [invalid
---
# Still visible
''';
    const unclosed = '''
---
title: Unclosed
# Still content
''';

    final invalidDocument = parseMarkdownFrontMatter(invalid);
    final unclosedDocument = parseMarkdownFrontMatter(unclosed);

    expect(invalidDocument.hasFrontMatter, isFalse);
    expect(invalidDocument.body, invalid);
    expect(unclosedDocument.hasFrontMatter, isFalse);
    expect(unclosedDocument.body, unclosed);
  });

  test('horizontal rules outside the document start are not front matter', () {
    const source = '# Heading\n\n---\n\nBody';
    final document = parseMarkdownFrontMatter(source);

    expect(document.hasFrontMatter, isFalse);
    expect(document.body, source);
    expect(document.entries, isEmpty);
  });

  test('places title and author first while preserving remaining order', () {
    final document = parseMarkdownFrontMatter('''
---
status: published
version: 2
author: Robin
title: SSH Internals
tags: [ssh]
---
Body
''');

    expect(document.entries.map((entry) => entry.key), <String>[
      'title',
      'author',
      'status',
      'version',
      'tags',
    ]);
  });
}
