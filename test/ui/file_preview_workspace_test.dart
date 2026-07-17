import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/state/chat_controller.dart';
import 'package:ianvs_acp/ui/components/chat_timeline.dart';
import 'package:ianvs_acp/ui/components/file_preview_workspace.dart';

void main() {
  Future<void> openMarkdownLink(
    WidgetTester tester, {
    required String text,
    required String href,
  }) async {
    final markdown = tester.widget<MarkdownBody>(
      find.byType(MarkdownBody).first,
    );
    await tester.runAsync(() async {
      markdown.onTapLink!(text, href, '');
      await Future<void>.delayed(const Duration(milliseconds: 60));
    });
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump(const Duration(milliseconds: 80));
  }

  Directory createWorkspace() {
    final workspace = Directory.systemTemp.createTempSync(
      'ianvs-preview-widget-',
    );
    addTearDown(() => workspace.deleteSync(recursive: true));
    return workspace;
  }

  Widget previewApp({
    required String workspacePath,
    required String markdown,
    Size size = const Size(1200, 800),
  }) {
    return MaterialApp(
      home: Scaffold(
        body: FilePreviewWorkspace(
          workspacePath: workspacePath,
          additionalDirectories: const <String>[],
          showInspector: true,
          inspector: const ColoredBox(
            key: ValueKey('test-inspector'),
            color: Colors.white,
          ),
          conversationBuilder: (context, onTapLink) => ChatTimeline(
            messages: <ChatMessage>[
              ChatMessage(role: ChatMessageRole.assistant, text: markdown),
            ],
            onTapLink: onTapLink,
          ),
        ),
      ),
    );
  }

  testWidgets(
    'opens Markdown links in a split preview and closes back to chat',
    (tester) async {
      final workspace = createWorkspace();
      final file = File('${workspace.path}/notes.md');
      file.writeAsStringSync(
        '# Preview title\n\nReadable paragraph.\n\n## Details\nMore text.',
      );
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        previewApp(
          workspacePath: workspace.path,
          markdown: '[Open notes](notes.md)',
        ),
      );
      expect(find.byKey(const ValueKey('test-inspector')), findsOneWidget);

      await openMarkdownLink(tester, text: 'Open notes', href: 'notes.md');

      expect(find.byKey(const ValueKey('file-preview-pane')), findsOneWidget);
      expect(find.text('Preview title'), findsWidgets);
      expect(find.textContaining('Markdown ·'), findsOneWidget);
      expect(find.textContaining('只读 · 当前工作区'), findsOneWidget);
      expect(find.byKey(const ValueKey('test-inspector')), findsNothing);

      await tester.tap(find.byTooltip('关闭预览'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('file-preview-pane')), findsNothing);
      expect(find.byKey(const ValueKey('test-inspector')), findsOneWidget);
    },
  );

  testWidgets(
    'reuses one tab for the same file and updates the selected line',
    (tester) async {
      final workspace = createWorkspace();
      final file = File('${workspace.path}/main.dart');
      file.writeAsStringSync(
        List<String>.generate(
          20,
          (index) => 'final value$index = $index;',
        ).join('\n'),
      );
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        previewApp(
          workspacePath: workspace.path,
          markdown: '[Line 3](main.dart#L3) and [Line 12](main.dart#L12)',
        ),
      );
      await openMarkdownLink(tester, text: 'Line 3', href: 'main.dart#L3');
      expect(find.text('第 3 行'), findsOneWidget);

      await openMarkdownLink(tester, text: 'Line 12', href: 'main.dart#L12');

      expect(find.text('第 12 行'), findsOneWidget);
      expect(find.byTooltip('关闭 main.dart'), findsOneWidget);
    },
  );

  testWidgets('shows a safe error instead of previewing traversal links', (
    tester,
  ) async {
    final parent = Directory.systemTemp.createTempSync('ianvs-preview-safe-');
    final workspace = Directory('${parent.path}/workspace');
    workspace.createSync();
    File('${parent.path}/secret.txt').writeAsStringSync('secret');
    addTearDown(() => parent.deleteSync(recursive: true));
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      previewApp(
        workspacePath: workspace.path,
        markdown: '[Outside](../secret.txt)',
      ),
    );
    await openMarkdownLink(tester, text: 'Outside', href: '../secret.txt');

    expect(find.text('文件不在当前工作区或已授权目录中'), findsOneWidget);
    expect(find.byKey(const ValueKey('file-preview-pane')), findsNothing);
  });
}
