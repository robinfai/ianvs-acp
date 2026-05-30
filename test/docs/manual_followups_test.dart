import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final manualDoc = File('docs/manual_followups.md').readAsStringSync();
  final auditDoc = File('docs/acp_feature_audit.md').readAsStringSync();

  test('manual follow-up document tracks audit checklist items', () {
    const trackedItems = <String, String>{
      'Streamable HTTP/SSE': 'remote-transports',
      'filesystem and terminal providers': 'fs-terminal-providers',
      'Spark attachments': 'spark-attachments',
      'Permission History': 'tool-permission-ui',
      'Extension Request dialog': 'vendor-extension-workflows',
    };

    for (final entry in trackedItems.entries) {
      expect(auditDoc, contains(entry.key));
      expect(manualDoc, contains('### ${entry.value}'));
    }
  });

  test('manual follow-up items include acceptance metadata', () {
    final itemBlocks = _manualFollowUpBlocks(manualDoc);

    expect(itemBlocks.keys, contains('desktop-manual-qa'));
    for (final entry in itemBlocks.entries) {
      final block = entry.value;
      expect(
        block,
        contains('Status:'),
        reason: '${entry.key} must record a status.',
      );
      expect(
        block,
        contains('Non-blocking because:'),
        reason: '${entry.key} must explain why it is not blocking.',
      );
      expect(
        block,
        contains('Automated acceptance:'),
        reason: '${entry.key} must record automated acceptance.',
      );
      expect(
        block.contains('Manual decision:') ||
            block.contains('Manual validation:'),
        isTrue,
        reason: '${entry.key} must record remaining manual work.',
      );
    }
  });

  test('manual follow-up evidence references existing repo paths', () {
    final pathPattern = RegExp(r'`((?:docs|lib|test|README\.md)/?[^`]+)`');
    final referencedPaths = pathPattern
        .allMatches(manualDoc)
        .map((match) => match.group(1)!)
        .where((path) => path.endsWith('.md') || path.endsWith('.dart'))
        .toSet();

    expect(referencedPaths, isNotEmpty);
    for (final path in referencedPaths) {
      expect(
        File(path).existsSync(),
        isTrue,
        reason: 'Referenced evidence path does not exist: $path',
      );
    }
  });
}

Map<String, String> _manualFollowUpBlocks(String markdown) {
  final headingPattern = RegExp(r'^### ([a-z0-9-]+)$', multiLine: true);
  final headings = headingPattern.allMatches(markdown).toList();
  return {
    for (var index = 0; index < headings.length; index++)
      headings[index].group(1)!: markdown.substring(
        headings[index].end,
        index + 1 == headings.length
            ? markdown.length
            : headings[index + 1].start,
      ),
  };
}
