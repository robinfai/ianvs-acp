import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/state/chat_controller.dart';
import 'package:ianvs_acp/ui/components/chat_timeline.dart';
import 'package:ianvs_acp/ui/components/file_preview_workspace.dart';
import 'package:ianvs_acp/ui/components/markdown_code_block.dart';
import 'package:ianvs_acp/ui/components/markdown_front_matter_card.dart';
import 'package:ianvs_acp/ui/components/markdown_preview_image.dart';

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

  testWidgets('inspector is a floating card in a reserved right region', (
    tester,
  ) async {
    final workspace = createWorkspace();
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      previewApp(workspacePath: workspace.path, markdown: 'Ready.'),
    );

    final surfaceRect = tester.getRect(
      find.byKey(const Key('workspace-inspector-surface')),
    );
    final workspaceRect = tester.getRect(find.byType(FilePreviewWorkspace));
    expect(surfaceRect.top, 12);
    expect(surfaceRect.right, workspaceRect.right - 18);
    expect(surfaceRect.width, 318);
    expect(surfaceRect.height, 520);
    expect(surfaceRect.bottom, lessThan(800));

    final surface = tester.widget<Container>(
      find.byKey(const Key('workspace-inspector-surface')),
    );
    final decoration = surface.decoration! as BoxDecoration;
    expect(decoration.borderRadius, BorderRadius.circular(18));
    expect(decoration.boxShadow, isNotEmpty);
  });

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

  testWidgets('Markdown outline collapses and scrolls to selected heading', (
    tester,
  ) async {
    final workspace = createWorkspace();
    final markdown = File('${workspace.path}/outline.md')
      ..writeAsStringSync(
        [
          'Document start',
          '==============',
          '',
          ...List<String>.generate(
            45,
            (index) => 'Paragraph $index with enough content for scrolling.',
          ).expand((line) => <String>[line, '']),
          '## Target section',
          '',
          'Target body.',
          '',
          '### Final section',
        ].join('\n'),
      );
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      previewApp(
        workspacePath: workspace.path,
        markdown: '[Open outline](${markdown.path})',
      ),
    );
    await openMarkdownLink(tester, text: 'Open outline', href: markdown.path);

    expect(find.byTooltip('收起文档大纲'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('markdown-outline-heading-1')),
      findsOneWidget,
    );

    await tester.tap(find.byTooltip('收起文档大纲'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('展开文档大纲'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('markdown-outline-heading-1')),
      findsNothing,
    );

    await tester.tap(find.byTooltip('展开文档大纲'));
    await tester.pumpAndSettle();
    final scroll = tester.widget<SingleChildScrollView>(
      find.byKey(const ValueKey('markdown-preview-scroll')),
    );
    expect(scroll.controller?.offset, 0);

    await tester.tap(find.byKey(const ValueKey('markdown-outline-heading-1')));
    await tester.pumpAndSettle();

    expect(scroll.controller?.offset, greaterThan(0));
  });

  testWidgets('Markdown front matter renders as expandable document metadata', (
    tester,
  ) async {
    final workspace = createWorkspace();
    final markdown = File('${workspace.path}/metadata.md')
      ..writeAsStringSync('''
---
title: SSH Internals
author: Robin
date: 2026-07-29
tags: [ssh, security]
status: published
version: 2
license: MIT
---
# Body heading

Readable body.
''');
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      previewApp(
        workspacePath: workspace.path,
        markdown: '[Open metadata](${markdown.path})',
      ),
    );
    await openMarkdownLink(tester, text: 'Open metadata', href: markdown.path);

    expect(find.byType(MarkdownFrontMatterCard), findsOneWidget);
    expect(find.text('文档信息'), findsOneWidget);
    expect(find.text('YAML'), findsOneWidget);
    expect(find.text('SSH Internals'), findsOneWidget);
    expect(find.text('ssh'), findsOneWidget);
    expect(find.text('security'), findsOneWidget);
    expect(find.textContaining('title:'), findsNothing);
    expect(
      find.byKey(const ValueKey('markdown-outline-heading-0')),
      findsOneWidget,
    );
    expect(find.text('MIT'), findsNothing);

    await tester.tap(find.byTooltip('展开全部元数据'));
    await tester.pump();

    expect(find.text('MIT'), findsOneWidget);
    expect(find.byTooltip('收起元数据'), findsOneWidget);
  });

  testWidgets('Markdown file preview uses the shared fenced code block', (
    tester,
  ) async {
    final workspace = createWorkspace();
    final markdown = File('${workspace.path}/commands.md')
      ..writeAsStringSync('# Commands\n\n```sh\nprintf "ready\\\\n"\n```\n');

    await tester.pumpWidget(
      previewApp(
        workspacePath: workspace.path,
        markdown: '[Open commands](${markdown.path})',
      ),
    );
    await openMarkdownLink(tester, text: 'Open commands', href: markdown.path);

    expect(find.byType(MarkdownCodeBlock), findsOneWidget);
    expect(find.text('SHELL'), findsOneWidget);
    expect(find.byTooltip('复制代码'), findsOneWidget);
  });

  testWidgets('Markdown preview routes supported image path forms', (
    tester,
  ) async {
    final workspace = createWorkspace();
    final docs = Directory('${workspace.path}/docs')..createSync();
    final image = File('${docs.path}/diagram one.png')
      ..writeAsBytesSync(<int>[0]);
    final markdown = File('${docs.path}/preview.md')
      ..writeAsStringSync(
        [
          '![relative](diagram%20one.png)',
          '![absolute](${Uri(path: image.path)})',
          '![file-uri](${Uri.file(image.path)})',
          '![remote](https://images.example.com/diagram.png)',
          '![inline](data:image/png;base64,iVBORw0KGgo=)',
        ].join('\n\n'),
      );

    await tester.pumpWidget(
      previewApp(
        workspacePath: workspace.path,
        markdown: '[Open preview](${markdown.path})',
      ),
    );
    await openMarkdownLink(tester, text: 'Open preview', href: markdown.path);

    final imageWidgets = tester
        .widgetList<MarkdownPreviewImage>(find.byType(MarkdownPreviewImage))
        .toList(growable: false);
    expect(imageWidgets, hasLength(5));
    expect(imageWidgets.map((widget) => widget.uri.scheme), <String>[
      '',
      '',
      'file',
      'https',
      'data',
    ]);
    expect(find.textContaining('图片未自动加载'), findsNothing);
  });

  testWidgets('Markdown image frame hugs image height', (tester) async {
    final svgUri = Uri.dataFromString(
      '<svg xmlns="http://www.w3.org/2000/svg" width="800" height="400">'
      '<rect width="800" height="400" fill="#6688aa"/>'
      '</svg>',
      mimeType: 'image/svg+xml',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: MarkdownPreviewImage(
              uri: svgUri,
              workspacePath: Directory.systemTemp.path,
              baseDirectory: Directory.systemTemp.path,
              additionalDirectories: const <String>[],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final frameSize = tester.getSize(find.byType(MarkdownPreviewImage));
    final imageSize = tester.getSize(find.byType(SvgPicture));
    expect(frameSize.height, lessThanOrEqualTo(imageSize.height + 16));
  });

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
