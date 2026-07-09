class ChatMarkdownCopyParser {
  const ChatMarkdownCopyParser(this.markdown);

  final String markdown;

  String markdownForVisibleSelection(String selectedText) {
    final normalizedSelection = selectedText.trim();
    if (normalizedSelection.isEmpty) return selectedText;

    for (final inline in _inlineMarkdownSelections(normalizedSelection)) {
      if (markdown.contains(inline.source)) return inline.markdown;
    }

    final blocks = _markdownBlocks(markdown);
    final selectedLines = normalizedSelection.split('\n');
    final selectedLineSet = selectedLines.map((line) => line.trim()).toSet();
    final selectedParts = <String>[];

    for (final block in blocks) {
      final rendered = block.visibleText.trim();
      if (rendered.isEmpty) continue;
      if (!normalizedSelection.contains(rendered) &&
          !rendered.contains(normalizedSelection) &&
          !_lineSetsOverlap(block.visibleText, selectedLineSet)) {
        continue;
      }

      final selectedBlock = block.markdownForSelection(normalizedSelection);
      if (selectedBlock.trim().isNotEmpty) selectedParts.add(selectedBlock);
    }

    if (selectedParts.isEmpty) return selectedText;
    return selectedParts.join('\n\n').trim();
  }
}

bool _lineSetsOverlap(String visibleText, Set<String> selectedLineSet) {
  return visibleText
      .split('\n')
      .map((line) => line.trim())
      .any(selectedLineSet.contains);
}

List<_InlineSelection> _inlineMarkdownSelections(String selectedText) {
  return <_InlineSelection>[
    _InlineSelection(
      source: '**$selectedText**',
      markdown: '**$selectedText**',
    ),
    _InlineSelection(source: '*$selectedText*', markdown: '*$selectedText*'),
    _InlineSelection(
      source: '_${selectedText}_',
      markdown: '_${selectedText}_',
    ),
    _InlineSelection(source: '`$selectedText`', markdown: '`$selectedText`'),
    ..._linkSelections(selectedText),
  ];
}

List<_InlineSelection> _linkSelections(String selectedText) {
  final result = <_InlineSelection>[];
  final pattern = RegExp(r'\[([^\]]+)\]\(([^)]+)\)');
  for (final match in pattern.allMatches(selectedText)) {
    result.add(
      _InlineSelection(source: match.group(0)!, markdown: match.group(0)!),
    );
  }
  return result;
}

List<_MarkdownBlock> _markdownBlocks(String markdown) {
  final lines = markdown.split('\n');
  final blocks = <_MarkdownBlock>[];
  var index = 0;

  while (index < lines.length) {
    if (lines[index].trim().isEmpty) {
      index += 1;
      continue;
    }

    final fence = RegExp(r'^(```+|~~~+)(.*)$').firstMatch(lines[index]);
    if (fence != null) {
      final marker = fence.group(1)!;
      final start = index;
      index += 1;
      while (index < lines.length && !lines[index].startsWith(marker)) {
        index += 1;
      }
      if (index < lines.length) index += 1;
      blocks.add(_CodeBlock(lines.sublist(start, index)));
      continue;
    }

    final listMatch = _listLinePattern.firstMatch(lines[index]);
    if (listMatch != null) {
      final start = index;
      index += 1;
      while (index < lines.length &&
          (lines[index].trim().isEmpty ||
              _listLinePattern.hasMatch(lines[index]))) {
        index += 1;
      }
      blocks.add(_ListBlock(lines.sublist(start, index)));
      continue;
    }

    final start = index;
    index += 1;
    while (index < lines.length && lines[index].trim().isNotEmpty) {
      index += 1;
    }
    blocks.add(_ParagraphBlock(lines.sublist(start, index)));
  }

  return blocks;
}

final _listLinePattern = RegExp(r'^\s*(?:[-*+]\s+|\d+[.)]\s+)');

abstract class _MarkdownBlock {
  String get visibleText;

  String markdownForSelection(String selectedText);
}

class _ParagraphBlock implements _MarkdownBlock {
  const _ParagraphBlock(this.lines);

  final List<String> lines;

  String get source => lines.join('\n');

  @override
  String get visibleText => _visibleInlineText(source);

  @override
  String markdownForSelection(String selectedText) {
    final trimmed = selectedText.trim();
    if (visibleText.trim() == trimmed) return source.trim();
    if (visibleText.contains(trimmed)) return _inlineMarkdown(source, trimmed);
    return '';
  }
}

class _ListBlock implements _MarkdownBlock {
  const _ListBlock(this.lines);

  final List<String> lines;

  @override
  String get visibleText {
    return lines
        .where((line) => line.trim().isNotEmpty)
        .map(
          (line) => _visibleInlineText(line.replaceFirst(_listLinePattern, '')),
        )
        .join('\n');
  }

  @override
  String markdownForSelection(String selectedText) {
    final selectedLines = selectedText
        .trim()
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toSet();
    return lines
        .where((line) {
          final visible = _visibleInlineText(
            line.replaceFirst(_listLinePattern, ''),
          ).trim();
          return selectedLines.contains(visible) ||
              selectedText.contains(visible);
        })
        .join('\n');
  }
}

class _CodeBlock implements _MarkdownBlock {
  const _CodeBlock(this.lines);

  final List<String> lines;

  @override
  String get visibleText {
    if (lines.length <= 2) return '';
    return lines.sublist(1, lines.length - 1).join('\n');
  }

  @override
  String markdownForSelection(String selectedText) {
    final body = visibleText;
    final trimmed = selectedText.trim();
    if (!body.contains(trimmed)) return '';
    return '${lines.first}\n$trimmed\n${lines.last}'.trim();
  }
}

String _inlineMarkdown(String source, String selectedText) {
  for (final builder in <String? Function()>[
    () => _wrappedInline(source, selectedText, '**', '**'),
    () => _wrappedInline(source, selectedText, '*', '*'),
    () => _wrappedInline(source, selectedText, '_', '_'),
    () => _wrappedInline(source, selectedText, '`', '`'),
    () => _linkedInline(source, selectedText),
  ]) {
    final result = builder();
    if (result != null) return result;
  }
  return selectedText;
}

String _visibleInlineText(String source) {
  return source
      .replaceAllMapped(
        RegExp(r'\[([^\]]+)\]\(([^)]+)\)'),
        (match) => match.group(1)!,
      )
      .replaceAllMapped(RegExp(r'(\*\*|__)(.*?)\1'), (match) => match.group(2)!)
      .replaceAllMapped(RegExp(r'(\*|_)(.*?)\1'), (match) => match.group(2)!)
      .replaceAllMapped(RegExp(r'`([^`]+)`'), (match) => match.group(1)!);
}

String? _wrappedInline(
  String source,
  String selectedText,
  String open,
  String close,
) {
  final pattern = RegExp('${RegExp.escape(open)}(.+?)${RegExp.escape(close)}');
  for (final match in pattern.allMatches(source)) {
    final text = match.group(1)!;
    if (text.contains(selectedText)) return '$open$selectedText$close';
  }
  return null;
}

String? _linkedInline(String source, String selectedText) {
  final pattern = RegExp(r'\[([^\]]+)\]\(([^)]+)\)');
  for (final match in pattern.allMatches(source)) {
    final label = match.group(1)!;
    final url = match.group(2)!;
    if (label.contains(selectedText)) return '[$selectedText]($url)';
  }
  return null;
}

class _InlineSelection {
  const _InlineSelection({required this.source, required this.markdown});

  final String source;
  final String markdown;
}
