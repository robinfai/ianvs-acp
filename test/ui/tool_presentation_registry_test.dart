import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/state/chat_controller.dart';
import 'package:ianvs_acp/ui/tool_presentation/tool_presentation_registry.dart';

void main() {
  group('ToolPresentationSource', () {
    test('normalizes legacy title, status, id, kind, and locations', () {
      final source = ToolPresentationSource.fromMessage(
        ChatMessage(
          role: ChatMessageRole.tool,
          text: '[Tool: exec_command] ToolCallStatus.in_progress',
          metadata: const {
            'call_id': 'call-7',
            'kind': 'terminal',
            'rawInput': {'cmd': 'dart test'},
            'rawOutput': 'running',
            'locations': [
              {'path': '/workspace/lib/main.dart', 'line': 12},
            ],
          },
        ),
      );

      expect(source.title, 'exec_command');
      expect(source.status, 'in_progress');
      expect(source.id, 'call-7');
      expect(source.kind, 'terminal');
      expect(source.input, {'cmd': 'dart test'});
      expect(source.output, 'running');
      expect(source.locations, ['/workspace/lib/main.dart:12']);
    });
  });

  group('ToolPresentationRegistry', () {
    final registry = ToolPresentationRegistry.defaults;

    test('recognizes built-in tool families without renderer conditionals', () {
      expect(
        registry.resolve(_source('read_file', input: {'path': '/a/foo.dart'})),
        isA<ToolActivityPresentation>()
            .having((value) => value.kind, 'kind', ToolActivityKind.read)
            .having((value) => value.action, 'action', 'Read')
            .having((value) => value.subject, 'subject', 'foo.dart')
            .having((value) => value.linkSubject, 'linkSubject', isTrue),
      );
      expect(
        registry.resolve(_source('exec_command', input: {'cmd': 'dart test'})),
        isA<ToolActivityPresentation>()
            .having((value) => value.kind, 'kind', ToolActivityKind.run)
            .having((value) => value.action, 'action', 'Ran')
            .having((value) => value.subject, 'subject', 'dart test'),
      );
      expect(
        registry.resolve(_source('computer-use.click')).kind,
        ToolActivityKind.interact,
      );
      expect(registry.resolve(_source('wait')).kind, ToolActivityKind.wait);
      expect(
        registry.resolve(_source('context compact')).kind,
        ToolActivityKind.context,
      );
      expect(
        registry.resolve(_source('search_query', input: {'query': 'ACP'})),
        isA<ToolActivityPresentation>()
            .having((value) => value.kind, 'kind', ToolActivityKind.search)
            .having((value) => value.subject, 'subject', 'ACP'),
      );
      expect(
        registry.resolve(_source('load_skill', input: {'skill': 'review'})),
        isA<ToolActivityPresentation>()
            .having((value) => value.kind, 'kind', ToolActivityKind.load)
            .having((value) => value.subject, 'subject', 'review'),
      );
      expect(
        registry.resolve(_source('write_stdin')).kind,
        ToolActivityKind.run,
      );
      expect(
        registry.resolve(_source('tool_search')).kind,
        ToolActivityKind.load,
      );
    });

    test('summarizes edits and preserves diff counts', () {
      final edit = registry.resolve(
        _source(
          'apply_patch',
          content: const [
            {
              'type': 'diff',
              'path': '/workspace/lib/app.dart',
              'oldText': 'same\nold\n',
              'newText': 'same\nnew\nextra\n',
            },
          ],
        ),
      );

      expect(edit.kind, ToolActivityKind.edit);
      expect(edit.subject, 'app.dart');
      expect(edit.suffix, '+2 -1');
      expect(
        registry.groupSummary([
          _source('apply_patch'),
          _source('read_file'),
          _source('exec_command'),
        ]),
        'Edited files, read files, and ran commands',
      );
      expect(registry.groupIcon([_source('apply_patch')]), Icons.edit_outlined);
    });

    test('allows agent-specific rules to take precedence', () {
      final customized = registry.prepend([
        ToolPresentationRule(
          id: 'deploy',
          resolve: (source) => source.title == 'deploy'
              ? const ToolActivityPresentation(
                  kind: ToolActivityKind.run,
                  icon: Icons.rocket_launch_outlined,
                  action: 'Deployed',
                  subject: 'preview',
                )
              : null,
        ),
      ]);

      expect(registry.resolve(_source('deploy')).action, 'Used');
      expect(customized.resolve(_source('deploy')).action, 'Deployed');
      expect(customized.rules.first.id, 'deploy');
    });
  });
}

ToolPresentationSource _source(String title, {Object? input, Object? content}) {
  return ToolPresentationSource(
    title: title,
    status: 'completed',
    id: 'call-$title',
    kind: '',
    content: content,
    input: input,
    output: null,
    locations: const [],
    previewRevision: 0,
  );
}
