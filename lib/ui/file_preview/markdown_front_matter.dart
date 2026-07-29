import 'dart:convert';

import 'package:yaml/yaml.dart';

const int markdownFrontMatterByteLimit = 64 * 1024;
const int markdownFrontMatterLineLimit = 256;
const int markdownFrontMatterEntryLimit = 40;

final class MarkdownFrontMatterDocument {
  const MarkdownFrontMatterDocument({
    required this.body,
    required this.entries,
    required this.hasFrontMatter,
  });

  final String body;
  final List<MarkdownMetadataEntry> entries;
  final bool hasFrontMatter;
}

final class MarkdownMetadataEntry {
  const MarkdownMetadataEntry({
    required this.key,
    required this.label,
    required this.value,
    this.items = const <String>[],
  });

  final String key;
  final String label;
  final String value;
  final List<String> items;

  bool get isLong => value.length > 72 || value.contains('\n');
}

MarkdownFrontMatterDocument parseMarkdownFrontMatter(String source) {
  final start = source.startsWith('\ufeff') ? 1 : 0;
  final openingEnd = source.indexOf('\n', start);
  if (openingEnd < 0 ||
      source.substring(start, openingEnd).replaceFirst('\r', '').trim() !=
          '---') {
    return _withoutFrontMatter(source);
  }

  var lineStart = openingEnd + 1;
  var lineCount = 0;
  while (lineStart <= source.length &&
      lineCount < markdownFrontMatterLineLimit &&
      lineStart - openingEnd <= markdownFrontMatterByteLimit) {
    final newline = source.indexOf('\n', lineStart);
    final lineEnd = newline < 0 ? source.length : newline;
    final line = source.substring(lineStart, lineEnd).trim();
    if (line == '---' || line == '...') {
      final raw = source.substring(openingEnd + 1, lineStart);
      if (utf8.encode(raw).length > markdownFrontMatterByteLimit) {
        return _withoutFrontMatter(source);
      }
      final parsed = _parseMetadata(raw);
      if (parsed == null) return _withoutFrontMatter(source);
      final bodyStart = newline < 0 ? source.length : newline + 1;
      return MarkdownFrontMatterDocument(
        body: source.substring(bodyStart),
        entries: parsed,
        hasFrontMatter: true,
      );
    }
    if (newline < 0) break;
    lineStart = newline + 1;
    lineCount += 1;
  }
  return _withoutFrontMatter(source);
}

MarkdownFrontMatterDocument _withoutFrontMatter(String source) {
  return MarkdownFrontMatterDocument(
    body: source,
    entries: const <MarkdownMetadataEntry>[],
    hasFrontMatter: false,
  );
}

List<MarkdownMetadataEntry>? _parseMetadata(String raw) {
  final Object? value;
  try {
    value = loadYaml(raw);
  } on Object {
    return null;
  }
  if (value == null) return const <MarkdownMetadataEntry>[];
  if (value is! Map<Object?, Object?>) return null;

  final result = <MarkdownMetadataEntry>[];
  _flattenMetadata(value, result: result);
  return List<MarkdownMetadataEntry>.unmodifiable(
    _prioritizePrimaryMetadata(result),
  );
}

List<MarkdownMetadataEntry> _prioritizePrimaryMetadata(
  List<MarkdownMetadataEntry> entries,
) {
  final titles = <MarkdownMetadataEntry>[];
  final authors = <MarkdownMetadataEntry>[];
  final remaining = <MarkdownMetadataEntry>[];
  for (final entry in entries) {
    final key = entry.key.toLowerCase().replaceAll('-', '_');
    if (key == 'title') {
      titles.add(entry);
    } else if (key == 'author' || key == 'authors') {
      authors.add(entry);
    } else {
      remaining.add(entry);
    }
  }
  return <MarkdownMetadataEntry>[...titles, ...authors, ...remaining];
}

void _flattenMetadata(
  Map<Object?, Object?> values, {
  required List<MarkdownMetadataEntry> result,
  String prefix = '',
  int depth = 0,
}) {
  for (final entry in values.entries) {
    if (result.length >= markdownFrontMatterEntryLimit) return;
    final segment = _boundedText(entry.key, 80);
    if (segment.isEmpty) continue;
    final key = prefix.isEmpty ? segment : '$prefix.$segment';
    final value = entry.value;
    if (value is Map<Object?, Object?> && depth < 1) {
      _flattenMetadata(value, result: result, prefix: key, depth: depth + 1);
      continue;
    }

    final items = value is Iterable<Object?>
        ? value
              .take(16)
              .map((item) => _boundedText(item, 160))
              .where((item) => item.isNotEmpty)
              .toList(growable: false)
        : const <String>[];
    final displayValue = items.isNotEmpty
        ? items.join(' · ')
        : _boundedText(value, 1200);
    if (displayValue.isEmpty) continue;
    result.add(
      MarkdownMetadataEntry(
        key: key,
        label: _metadataLabel(key),
        value: displayValue,
        items: items,
      ),
    );
  }
}

String _boundedText(Object? value, int maximumCharacters) {
  final text = switch (value) {
    null => '',
    bool() => value ? '是' : '否',
    DateTime() => value.toIso8601String(),
    _ => value.toString().trim(),
  };
  if (text.length <= maximumCharacters) return text;
  return '${text.substring(0, maximumCharacters)}…';
}

String _metadataLabel(String key) {
  final normalized = key.toLowerCase().replaceAll('-', '_');
  return _metadataLabels[normalized] ?? key;
}

const Map<String, String> _metadataLabels = <String, String>{
  'title': '标题',
  'subtitle': '副标题',
  'description': '摘要',
  'summary': '摘要',
  'author': '作者',
  'authors': '作者',
  'date': '日期',
  'created': '创建时间',
  'updated': '更新时间',
  'last_modified': '更新时间',
  'tags': '标签',
  'tag': '标签',
  'categories': '分类',
  'category': '分类',
  'status': '状态',
  'draft': '草稿',
  'slug': '路径',
  'version': '版本',
  'lang': '语言',
  'language': '语言',
};
