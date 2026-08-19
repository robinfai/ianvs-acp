import 'dart:collection';

import 'package:flutter/material.dart';

import '../../state/chat_controller.dart';

const List<String> _toolCallIdMetadataKeys = [
  'toolCallId',
  'tool_call_id',
  'id',
  'callId',
  'call_id',
];

/// The normalized, renderer-independent projection of one ACP tool update.
final class ToolPresentationSource {
  const ToolPresentationSource({
    required this.title,
    required this.status,
    required this.id,
    required this.kind,
    required this.content,
    required this.input,
    required this.output,
    required this.locations,
    required this.previewRevision,
  });

  factory ToolPresentationSource.fromMessage(ChatMessage message) {
    final metadata = message.metadata;
    var title = _boundedToolDisplayString(
      _stringMetadata(metadata, 'title') ?? message.previewText,
    );
    var status = _boundedToolDisplayString(
      _stringMetadata(metadata, 'status') ?? '',
    );
    final embeddedToolTitle = RegExp(
      r'^\[Tool:\s*(.*?)\]\s*(.*)$',
    ).firstMatch(title);
    if (embeddedToolTitle != null) {
      title = embeddedToolTitle.group(1)?.trim() ?? title;
      status = status.isEmpty
          ? embeddedToolTitle.group(2)?.trim() ?? ''
          : status;
    }
    status = status.replaceFirst('ToolCallStatus.', '');
    if (status.isEmpty) status = 'completed';

    final locations = _mapList(metadata['locations'])
        .map((location) {
          final path = _stringMetadata(location, 'path') ?? '';
          final line = location['line'];
          return line == null ? path : '$path:$line';
        })
        .where((location) => location.isNotEmpty)
        .toList(growable: false);

    return ToolPresentationSource(
      title: title.isEmpty ? 'Tool call' : title,
      status: status,
      id: _boundedToolDisplayString(_toolCallIdMetadata(metadata) ?? ''),
      kind: _stringMetadata(metadata, 'kind') == 'tool'
          ? ''
          : _stringMetadata(metadata, 'kind') ?? '',
      content: metadata['content'],
      input: _firstMetadataValue(metadata, const ['rawInput', 'raw_input']),
      output: _firstMetadataValue(metadata, const ['rawOutput', 'raw_output']),
      locations: List<String>.unmodifiable(locations),
      previewRevision: message.revision,
    );
  }

  final String title;
  final String status;
  final String id;
  final String kind;
  final Object? content;
  final Object? input;
  final Object? output;
  final List<String> locations;
  final Object previewRevision;
}

/// Stable semantic categories used by compact tool rows and activity summaries.
enum ToolActivityKind {
  load,
  read,
  edit,
  run,
  search,
  interact,
  wait,
  context,
  generic,
}

/// Pure data consumed by the timeline's common tool-row renderer.
final class ToolActivityPresentation {
  const ToolActivityPresentation({
    required this.kind,
    required this.icon,
    required this.action,
    required this.subject,
    this.suffix = '',
    this.linkSubject = false,
  });

  final ToolActivityKind kind;
  final IconData icon;
  final String action;
  final String subject;
  final String suffix;
  final bool linkSubject;

  String get semanticLabel => [
    action,
    if (subject.isNotEmpty) subject,
    if (suffix.isNotEmpty) suffix,
  ].join(' ');
}

typedef ToolPresentationResolver =
    ToolActivityPresentation? Function(ToolPresentationSource source);

/// One ordered extension point for recognizing and presenting a tool family.
final class ToolPresentationRule {
  const ToolPresentationRule({required this.id, required this.resolve});

  final String id;
  final ToolPresentationResolver resolve;
}

/// Resolves tool updates through ordered rules and a generic fallback.
///
/// Callers may prepend product- or agent-specific rules while retaining the
/// built-in rules. A rule that does not own a source returns null so the next
/// rule can resolve it.
final class ToolPresentationRegistry {
  ToolPresentationRegistry(Iterable<ToolPresentationRule> rules)
    : rules = UnmodifiableListView<ToolPresentationRule>(rules.toList());

  static final ToolPresentationRegistry defaults = ToolPresentationRegistry([
    ToolPresentationRule(id: 'interaction', resolve: _resolveInteraction),
    ToolPresentationRule(id: 'wait', resolve: _resolveWait),
    ToolPresentationRule(id: 'context', resolve: _resolveContext),
    ToolPresentationRule(id: 'run', resolve: _resolveRun),
    ToolPresentationRule(id: 'edit', resolve: _resolveEdit),
    ToolPresentationRule(id: 'read', resolve: _resolveRead),
    ToolPresentationRule(id: 'load', resolve: _resolveLoad),
    ToolPresentationRule(id: 'search', resolve: _resolveSearch),
  ]);

  final UnmodifiableListView<ToolPresentationRule> rules;

  ToolActivityPresentation resolve(ToolPresentationSource source) {
    for (final rule in rules) {
      final presentation = rule.resolve(source);
      if (presentation != null) return presentation;
    }
    return ToolActivityPresentation(
      kind: ToolActivityKind.generic,
      icon: Icons.build_outlined,
      action: 'Used',
      subject: source.title,
    );
  }

  ToolPresentationRegistry prepend(Iterable<ToolPresentationRule> additions) {
    return ToolPresentationRegistry([...additions, ...rules]);
  }

  String groupSummary(Iterable<ToolPresentationSource> sources) {
    final tools = sources.toList(growable: false);
    final kinds = tools.map((tool) => resolve(tool).kind).toSet();
    final activities = <String>[
      if (kinds.contains(ToolActivityKind.load)) 'loaded tools',
      if (kinds.contains(ToolActivityKind.edit)) 'edited files',
      if (kinds.contains(ToolActivityKind.read)) 'read files',
      if (kinds.contains(ToolActivityKind.run)) 'ran commands',
      if (kinds.contains(ToolActivityKind.search)) 'searched',
      if (kinds.contains(ToolActivityKind.interact)) 'controlled the app',
      if (kinds.contains(ToolActivityKind.wait)) 'waited for background work',
      if (kinds.contains(ToolActivityKind.context)) 'compacted context',
    ];
    if (activities.isEmpty) {
      final titles = tools.map((tool) => tool.title).toSet();
      if (titles.length == 1) return 'Used ${titles.single}';
      return 'Used ${tools.length} tools';
    }
    final sentence = _naturalLanguageList(activities);
    return sentence[0].toUpperCase() + sentence.substring(1);
  }

  IconData groupIcon(Iterable<ToolPresentationSource> sources) {
    final edited = sources.any(
      (tool) => resolve(tool).kind == ToolActivityKind.edit,
    );
    return edited ? Icons.edit_outlined : Icons.build_outlined;
  }
}

/// Supplies a presentation registry to all tool rows under a timeline.
final class ToolPresentationScope extends InheritedWidget {
  const ToolPresentationScope({
    super.key,
    required this.registry,
    required super.child,
  });

  final ToolPresentationRegistry registry;

  static ToolPresentationRegistry of(BuildContext context) {
    return context
            .dependOnInheritedWidgetOfExactType<ToolPresentationScope>()
            ?.registry ??
        ToolPresentationRegistry.defaults;
  }

  @override
  bool updateShouldNotify(ToolPresentationScope oldWidget) =>
      !identical(registry, oldWidget.registry);
}

ToolActivityPresentation? _resolveInteraction(ToolPresentationSource source) {
  final title = source.title.toLowerCase();
  if (!title.contains('node_repl') &&
      !title.contains('computer_use') &&
      !title.contains('computer-use')) {
    return null;
  }
  return const ToolActivityPresentation(
    kind: ToolActivityKind.interact,
    icon: Icons.touch_app_outlined,
    action: 'Controlled',
    subject: 'the app',
  );
}

ToolActivityPresentation? _resolveWait(ToolPresentationSource source) {
  final title = source.title.toLowerCase();
  if (title != 'wait' && !title.endsWith('.wait')) return null;
  return const ToolActivityPresentation(
    kind: ToolActivityKind.wait,
    icon: Icons.schedule_rounded,
    action: 'Waited',
    subject: 'for background work',
  );
}

ToolActivityPresentation? _resolveContext(ToolPresentationSource source) {
  if (!source.title.toLowerCase().contains('context compact')) return null;
  return const ToolActivityPresentation(
    kind: ToolActivityKind.context,
    icon: Icons.compress_rounded,
    action: 'Compacted',
    subject: 'context',
  );
}

ToolActivityPresentation? _resolveEdit(ToolPresentationSource source) {
  final title = source.title.toLowerCase();
  if (!title.contains('edit') &&
      !title.contains('write') &&
      !title.contains('patch') &&
      !title.contains('create_file')) {
    return null;
  }
  final diffs = _toolDiffSummaries(source.content);
  final subject = _toolFilePath(source, diffs);
  final additions = diffs.fold<int>(0, (sum, diff) => sum + diff.additions);
  final deletions = diffs.fold<int>(0, (sum, diff) => sum + diff.deletions);
  return ToolActivityPresentation(
    kind: ToolActivityKind.edit,
    icon: Icons.edit_outlined,
    action: 'Edited',
    subject: subject,
    suffix: additions == 0 && deletions == 0 ? '' : '+$additions -$deletions',
    linkSubject: subject.isNotEmpty,
  );
}

ToolActivityPresentation? _resolveRead(ToolPresentationSource source) {
  final title = source.title.toLowerCase();
  if (title != 'read' &&
      !title.contains('read_file') &&
      !title.contains('view_file') &&
      !title.contains('open_file')) {
    return null;
  }
  final subject = _toolFilePath(source, const []);
  return ToolActivityPresentation(
    kind: ToolActivityKind.read,
    icon: Icons.menu_book_outlined,
    action: 'Read',
    subject: subject,
    linkSubject: subject.isNotEmpty,
  );
}

ToolActivityPresentation? _resolveRun(ToolPresentationSource source) {
  final title = source.title.toLowerCase();
  if (!title.contains('exec') &&
      !title.contains('command') &&
      !title.contains('shell') &&
      !title.contains('bash') &&
      !title.contains('terminal') &&
      !title.contains('write_stdin')) {
    return null;
  }
  final input = _objectMap(source.input);
  final command = _firstNonEmptyString(input, const ['cmd', 'command']);
  return ToolActivityPresentation(
    kind: ToolActivityKind.run,
    icon: Icons.terminal_rounded,
    action: 'Ran',
    subject: _boundedToolDisplayString(
      command.isEmpty ? source.title : command,
    ),
  );
}

ToolActivityPresentation? _resolveSearch(ToolPresentationSource source) {
  final title = source.title.toLowerCase();
  if (!title.contains('search') && title != 'find' && !title.contains('grep')) {
    return null;
  }
  return ToolActivityPresentation(
    kind: ToolActivityKind.search,
    icon: Icons.search_rounded,
    action: 'Searched',
    subject: _boundedToolDisplayString(
      _firstNonEmptyString(_objectMap(source.input), const [
        'q',
        'query',
        'pattern',
        'search_term',
      ]),
    ),
  );
}

ToolActivityPresentation? _resolveLoad(ToolPresentationSource source) {
  final title = source.title.toLowerCase();
  if (!title.contains('load') &&
      !title.contains('skill') &&
      !title.contains('tool_search')) {
    return null;
  }
  return ToolActivityPresentation(
    kind: ToolActivityKind.load,
    icon: Icons.extension_outlined,
    action: 'Loaded',
    subject: _boundedToolDisplayString(
      _firstNonEmptyString(_objectMap(source.input), const [
        'name',
        'skill',
        'tool',
        'path',
      ]),
    ),
  );
}

String _toolFilePath(
  ToolPresentationSource source,
  List<_ToolDiffSummary> diffs,
) {
  final direct = _firstNonEmptyString(_objectMap(source.input), const [
    'path',
    'file_path',
    'filePath',
    'filename',
    'file',
  ]);
  final candidate = direct.isNotEmpty
      ? direct
      : diffs.isNotEmpty
      ? diffs.first.path
      : source.locations.isNotEmpty
      ? source.locations.first.split(':').first
      : _patchFilePath(source.input);
  if (candidate.isEmpty) return '';
  final normalized = candidate.replaceAll('\\', '/');
  final parts = normalized.split('/').where((part) => part.isNotEmpty).toList();
  return _boundedToolDisplayString(parts.isEmpty ? candidate : parts.last);
}

String _patchFilePath(Object? input) {
  if (input is! String) return '';
  final match = RegExp(
    r'^\*\*\* (?:Update|Add|Delete) File:\s*(.+)$',
    multiLine: true,
  ).firstMatch(input);
  return match?.group(1)?.trim() ?? '';
}

String _firstNonEmptyString(Map<String, Object?> input, List<String> keys) {
  for (final key in keys) {
    final value = input[key];
    if (value is String && value.trim().isNotEmpty) return value.trim();
  }
  return '';
}

String _naturalLanguageList(List<String> items) {
  if (items.length == 1) return items.single;
  if (items.length == 2) return '${items.first} and ${items.last}';
  return '${items.take(items.length - 1).join(', ')}, and ${items.last}';
}

final class _ToolDiffSummary {
  const _ToolDiffSummary({
    required this.path,
    required this.additions,
    required this.deletions,
  });

  final String path;
  final int additions;
  final int deletions;
}

List<_ToolDiffSummary> _toolDiffSummaries(Object? content) {
  final diffs = <_ToolDiffSummary>[];
  for (final item in _mapList(content)) {
    if (_stringMetadata(item, 'type') != 'diff') continue;
    final path = _stringMetadata(item, 'path') ?? 'Edited file';
    final oldLines = _splitDiffText(item['oldText'] ?? item['old_text']);
    final newLines = _splitDiffText(item['newText'] ?? item['new_text']);
    var prefix = 0;
    while (prefix < oldLines.length &&
        prefix < newLines.length &&
        oldLines[prefix] == newLines[prefix]) {
      prefix += 1;
    }
    var suffix = 0;
    while (suffix < oldLines.length - prefix &&
        suffix < newLines.length - prefix &&
        oldLines[oldLines.length - suffix - 1] ==
            newLines[newLines.length - suffix - 1]) {
      suffix += 1;
    }
    diffs.add(
      _ToolDiffSummary(
        path: path,
        additions: newLines.length - prefix - suffix,
        deletions: oldLines.length - prefix - suffix,
      ),
    );
  }
  return diffs;
}

List<String> _splitDiffText(Object? value) {
  if (value is! String || value.isEmpty) return const [];
  final normalized = value.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final lines = normalized.split('\n');
  if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
  return lines;
}

String? _stringMetadata(Map<String, Object?> metadata, String key) {
  final value = metadata[key];
  if (value is String && value.trim().isNotEmpty) return value.trim();
  return null;
}

String _boundedToolDisplayString(String value) {
  const maxCodeUnits = 4096;
  if (value.length <= maxCodeUnits) return value;
  var end = maxCodeUnits;
  final last = value.codeUnitAt(end - 1);
  if (last >= 0xD800 && last <= 0xDBFF) end -= 1;
  return '${value.substring(0, end)}…';
}

String? _toolCallIdMetadata(Map<String, Object?> metadata) {
  for (final key in _toolCallIdMetadataKeys) {
    final value = _stringMetadata(metadata, key);
    if (value != null) return value;
  }
  final nested = metadata['toolCall'];
  if (nested is Map) {
    final nestedMetadata = nested.map(
      (key, value) => MapEntry(key.toString(), value),
    );
    for (final key in _toolCallIdMetadataKeys) {
      final value = _stringMetadata(nestedMetadata, key);
      if (value != null) return value;
    }
  }
  return null;
}

Object? _firstMetadataValue(Map<String, Object?> metadata, List<String> keys) {
  for (final key in keys) {
    final value = metadata[key];
    if (value != null) return value;
  }
  return null;
}

Map<String, Object?> _objectMap(Object? value) {
  if (value is! Map) return const <String, Object?>{};
  return value.map((key, value) => MapEntry(key.toString(), value));
}

List<Map<String, Object?>> _mapList(Object? value) {
  if (value is! List) return const [];
  return value
      .whereType<Map>()
      .map((entry) {
        if (entry is Map<String, Object?>) return entry;
        return entry.map((key, value) => MapEntry(key.toString(), value));
      })
      .toList(growable: false);
}
