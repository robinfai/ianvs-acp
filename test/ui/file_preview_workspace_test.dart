import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/acp_input_budget.dart';
import 'package:ianvs_acp/state/chat_controller.dart';
import 'package:ianvs_acp/ui/components/bounded_image_preview.dart';
import 'package:ianvs_acp/ui/components/chat_timeline.dart';
import 'package:ianvs_acp/ui/components/file_preview_workspace.dart';
import 'package:ianvs_acp/ui/components/markdown_code_block.dart';
import 'package:ianvs_acp/ui/components/markdown_front_matter_card.dart';
import 'package:ianvs_acp/ui/components/markdown_preview_image.dart';
import 'package:ianvs_acp/ui/file_preview/file_preview_document.dart';
import 'package:ianvs_acp/ui/image_decode_budget.dart';
import 'package:ianvs_acp/ui/theme/app_design_tokens.dart';

void main() {
  Future<void> pumpAsyncUntil(WidgetTester tester, bool Function() done) async {
    for (var attempt = 0; attempt < 50 && !done(); attempt += 1) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
  }

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
    List<String> additionalDirectories = const <String>[],
    FilePreviewTargetResolver resolveTarget = resolveFilePreviewTarget,
    FilePreviewImageDimensionInspector imageDimensionInspector =
        inspectFilePreviewImageDimensions,
    AcpInputBudget inputBudget = const AcpInputBudget(),
    AcpImageDecodeBudgetLedger? imageDecodeLedger,
    BoundedImageDecoder boundedImageDecoder = const DartUiBoundedImageDecoder(),
    MarkdownImageLoadBudgetLedger? markdownImageLoadBudgetLedger,
    MarkdownLocalImageReader? markdownLocalImageReader,
    FilePreviewProcessRunner? processRunner,
    FilePreviewProcessStarter? quickLookProcessStarter,
    Duration quickLookTimeout = filePreviewQuickLookTimeout,
    FilePreviewQuickLookCoordinator? quickLookCoordinator,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: FilePreviewWorkspace(
          workspacePath: workspacePath,
          additionalDirectories: additionalDirectories,
          showInspector: true,
          resolveTarget: resolveTarget,
          imageDimensionInspector: imageDimensionInspector,
          inputBudget: inputBudget,
          imageDecodeLedger: imageDecodeLedger,
          boundedImageDecoder: boundedImageDecoder,
          markdownImageLoadBudgetLedger: markdownImageLoadBudgetLedger,
          markdownLocalImageReader: markdownLocalImageReader,
          processRunner: processRunner,
          quickLookProcessStarter: quickLookProcessStarter,
          quickLookTimeout: quickLookTimeout,
          quickLookCoordinator: quickLookCoordinator,
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
    'inspector is a full-height pane beside the conversation canvas',
    (tester) async {
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
      expect(surfaceRect.top, workspaceRect.top);
      expect(surfaceRect.right, workspaceRect.right);
      expect(surfaceRect.width, 320);
      expect(surfaceRect.height, workspaceRect.height);
      expect(surfaceRect.bottom, workspaceRect.bottom);

      final surface = tester.widget<Container>(
        find.byKey(const Key('workspace-inspector-surface')),
      );
      expect(surface.color, AppColors.surface);
      expect(surface.decoration, isNull);
      expect(surface.foregroundDecoration, isNull);

      final canvasRect = tester.getRect(
        find.byKey(const Key('conversation-canvas-surface')),
      );
      expect(canvasRect.top, workspaceRect.top);
      expect(canvasRect.bottom, workspaceRect.bottom);
      expect(canvasRect.right, surfaceRect.left);

      final canvas = tester.widget<Container>(
        find.byKey(const Key('conversation-canvas-surface')),
      );
      final canvasDecoration = canvas.decoration! as BoxDecoration;
      expect(canvasDecoration.border, isNull);
      expect(canvasDecoration.boxShadow, isNull);
    },
  );

  testWidgets('external file actions preserve an unchanged preview target', (
    tester,
  ) async {
    final workspace = createWorkspace();
    final file = File('${workspace.path}/notes.txt')..writeAsStringSync('safe');
    final expectedPath = file.resolveSymbolicLinksSync();
    final invocations = <({String executable, List<String> arguments})>[];

    await tester.pumpWidget(
      previewApp(
        workspacePath: workspace.path,
        markdown: '[Open notes](notes.txt)',
        processRunner: (executable, arguments) async {
          invocations.add((
            executable: executable,
            arguments: List<String>.of(arguments),
          ));
          return ProcessResult(1, 0, '', '');
        },
      ),
    );
    await openMarkdownLink(tester, text: 'Open notes', href: 'notes.txt');

    await tester.tap(find.byTooltip('在 Finder 中显示'));
    await pumpAsyncUntil(tester, () => invocations.length == 1);
    await tester.tap(find.text('用其他应用打开'));
    await pumpAsyncUntil(tester, () => invocations.length == 2);

    expect(invocations, hasLength(2));
    expect(
      invocations.every((entry) => entry.arguments.contains(expectedPath)),
      isTrue,
    );
  });

  testWidgets('external file actions reject a replaced preview target', (
    tester,
  ) async {
    if (Platform.isWindows) return;
    final workspace = createWorkspace();
    final target = File('${workspace.path}/notes.txt');
    target.writeAsStringSync('safe');
    final outside = File('${workspace.parent.path}/outside-preview-target.txt')
      ..writeAsStringSync('outside');
    addTearDown(() {
      if (outside.existsSync()) outside.deleteSync();
    });
    var processStarts = 0;

    await tester.pumpWidget(
      previewApp(
        workspacePath: workspace.path,
        markdown: '[Open notes](notes.txt)',
        processRunner: (executable, arguments) async {
          processStarts += 1;
          return ProcessResult(1, 0, '', '');
        },
      ),
    );
    await openMarkdownLink(tester, text: 'Open notes', href: 'notes.txt');
    target.renameSync('${workspace.path}/notes-old.txt');
    Link(target.path).createSync(outside.path);

    await tester.tap(find.byTooltip('在 Finder 中显示'));
    await pumpAsyncUntil(
      tester,
      () => find.textContaining('文件自预览后已更改').evaluate().isNotEmpty,
    );
    expect(find.textContaining('文件自预览后已更改'), findsOneWidget);
    expect(processStarts, 0);

    await tester.tap(find.text('用其他应用打开'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    expect(find.textContaining('文件自预览后已更改'), findsOneWidget);
    expect(processStarts, 0);
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

  testWidgets('preview layout is safe across the 820 to 840 boundary', (
    tester,
  ) async {
    final workspace = createWorkspace();
    File('${workspace.path}/notes.md').writeAsStringSync('# Boundary preview');
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.physicalSize = const Size(1200, 800);

    await tester.pumpWidget(
      previewApp(
        workspacePath: workspace.path,
        markdown: '[Open notes](notes.md)',
      ),
    );
    await openMarkdownLink(tester, text: 'Open notes', href: 'notes.md');

    for (final width in <double>[819, 820, 839, 840]) {
      tester.view.physicalSize = Size(width, 800);
      await tester.pump();
      expect(tester.takeException(), isNull, reason: 'width $width');
      expect(find.byKey(const ValueKey('file-preview-pane')), findsOneWidget);
    }
  });

  testWidgets('oversized file preview images stay out of the image decoder', (
    tester,
  ) async {
    final workspace = createWorkspace();
    final image = File('${workspace.path}/oversized.png');
    final handle = image.openSync(mode: FileMode.write);
    handle.truncateSync(16 * 1024 * 1024 + 1);
    handle.closeSync();

    await tester.pumpWidget(
      previewApp(
        workspacePath: workspace.path,
        markdown: '[Open oversized image](oversized.png)',
      ),
    );
    await openMarkdownLink(
      tester,
      text: 'Open oversized image',
      href: 'oversized.png',
    );

    expect(find.text('图片过大，未内嵌预览'), findsOneWidget);
    expect(find.textContaining('超过 16 MB 限制'), findsOneWidget);
    expect(find.text('用其他应用打开'), findsWidgets);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('high-pixel small file previews stay out of the image decoder', (
    tester,
  ) async {
    final workspace = createWorkspace();
    File(
      '${workspace.path}/pixel-bomb.png',
    ).writeAsBytesSync(<int>[0x89, 0x50, 0x4e, 0x47]);

    await tester.pumpWidget(
      previewApp(
        workspacePath: workspace.path,
        markdown: '[Open hostile image](pixel-bomb.png)',
        imageDimensionInspector: (_) async => (width: 8192, height: 8192),
      ),
    );
    await openMarkdownLink(
      tester,
      text: 'Open hostile image',
      href: 'pixel-bomb.png',
    );

    expect(find.text('图片尺寸过大，未内嵌预览'), findsOneWidget);
    expect(find.textContaining('尺寸超过安全预览限制'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('ignores a pending file resolution after workspace changes', (
    tester,
  ) async {
    final firstWorkspace = createWorkspace();
    final secondWorkspace = createWorkspace();
    final oldFile = File('${firstWorkspace.path}/old.md')
      ..writeAsStringSync('# Old workspace');
    final pending = Completer<FilePreviewTarget>();
    Future<FilePreviewTarget> delayedResolver({
      required String href,
      required String workspacePath,
      required List<String> additionalDirectories,
      required String baseDirectory,
    }) => pending.future;

    await tester.pumpWidget(
      previewApp(
        workspacePath: firstWorkspace.path,
        markdown: '[Open old](old.md)',
        resolveTarget: delayedResolver,
      ),
    );
    await openMarkdownLink(tester, text: 'Open old', href: 'old.md');

    await tester.pumpWidget(
      previewApp(
        workspacePath: secondWorkspace.path,
        markdown: 'Second workspace',
        resolveTarget: delayedResolver,
      ),
    );
    pending.complete(
      FilePreviewTarget(path: oldFile.path, workspacePath: firstWorkspace.path),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('file-preview-pane')), findsNothing);
    expect(find.text('Second workspace'), findsOneWidget);
  });

  testWidgets(
    'Quick Look jobs cancel on close, eviction, workspace change, and dispose',
    (tester) async {
      if (!Platform.isMacOS) return;
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final firstWorkspace = createWorkspace();
      final secondWorkspace = createWorkspace();
      for (var index = 0; index < 7; index += 1) {
        File(
          '${firstWorkspace.path}/$index.pdf',
        ).writeAsStringSync('%PDF-$index');
      }
      final secondFile = File('${secondWorkspace.path}/next.pdf')
        ..writeAsStringSync('%PDF-next');
      final coordinator = FilePreviewQuickLookCoordinator();
      addTearDown(coordinator.dispose);
      final processes = <_WorkspaceHangingProcess>[];
      Future<Process> starter(String executable, List<String> arguments) async {
        final process = _WorkspaceHangingProcess();
        processes.add(process);
        return process;
      }

      final links = List<String>.generate(
        7,
        (index) => '[Open $index]($index.pdf)',
      ).join('\n\n');

      await tester.pumpWidget(
        previewApp(
          workspacePath: firstWorkspace.path,
          markdown: links,
          quickLookProcessStarter: starter,
          quickLookCoordinator: coordinator,
          quickLookTimeout: const Duration(seconds: 5),
        ),
      );
      await openMarkdownLink(tester, text: 'Open 0', href: '0.pdf');
      await pumpAsyncUntil(tester, () => processes.isNotEmpty);
      final closedProcess = processes.single;
      await tester.tap(find.byTooltip('关闭 0.pdf'));
      await pumpAsyncUntil(
        tester,
        () => closedProcess.killCalls > 0 && !coordinator.hasActiveJob,
      );
      expect(closedProcess.killCalls, greaterThan(0));
      expect(coordinator.reservedInputBytes, 0);

      await openMarkdownLink(tester, text: 'Open 0', href: '0.pdf');
      await pumpAsyncUntil(tester, () => processes.length >= 2);
      final evictedProcess = processes.last;
      for (var index = 1; index < 7; index += 1) {
        await openMarkdownLink(tester, text: 'Open $index', href: '$index.pdf');
      }
      await pumpAsyncUntil(tester, () => evictedProcess.killCalls > 0);
      expect(evictedProcess.killCalls, greaterThan(0));
      expect(find.byKey(const ValueKey('file-preview-pane')), findsOneWidget);
      expect(coordinator.queuedJobs, lessThanOrEqualTo(5));

      await tester.pumpWidget(
        previewApp(
          workspacePath: secondWorkspace.path,
          markdown: '[Open next](next.pdf)',
          quickLookProcessStarter: starter,
          quickLookCoordinator: coordinator,
          quickLookTimeout: const Duration(seconds: 5),
        ),
      );
      await pumpAsyncUntil(
        tester,
        () => !coordinator.hasActiveJob && coordinator.queuedJobs == 0,
      );
      expect(coordinator.reservedInputBytes, 0);

      await openMarkdownLink(tester, text: 'Open next', href: secondFile.path);
      await pumpAsyncUntil(tester, () => coordinator.hasActiveJob);
      final disposedProcess = processes.last;
      await tester.pumpWidget(const SizedBox.shrink());
      await pumpAsyncUntil(
        tester,
        () => disposedProcess.killCalls > 0 && !coordinator.hasActiveJob,
      );
      expect(disposedProcess.killCalls, greaterThan(0));
      expect(coordinator.queuedJobs, 0);
      expect(coordinator.reservedInputBytes, 0);
      expect(tester.takeException(), isNull);
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
    expect(find.textContaining('图片未自动加载'), findsOneWidget);
    expect(
      find.byKey(const Key('markdown-remote-image-blocked')),
      findsOneWidget,
    );
  });

  testWidgets('Markdown remote images do not request the network by default', (
    tester,
  ) async {
    final client = _CountingHttpClient();

    await HttpOverrides.runZoned(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MarkdownPreviewImage(
              uri: Uri.parse(
                'https://never-auto-load.example/unique-preview.png',
              ),
              workspacePath: Directory.systemTemp.path,
              baseDirectory: Directory.systemTemp.path,
              additionalDirectories: const <String>[],
              alt: 'Remote diagram',
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      expect(client.requestCount, 0);
      expect(find.byType(Image), findsNothing);
      expect(find.byType(SvgPicture), findsNothing);
      expect(find.text('never-auto-load.example'), findsOneWidget);
      expect(find.text('在浏览器中打开'), findsOneWidget);
      expect(find.text('加载图片'), findsNothing);
    }, createHttpClient: (_) => client);
  });

  testWidgets('Markdown remote images can open externally without loading', (
    tester,
  ) async {
    Uri? opened;
    final uri = Uri.parse('https://images.example.com/diagram.png');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MarkdownPreviewImage(
            uri: uri,
            workspacePath: Directory.systemTemp.path,
            baseDirectory: Directory.systemTemp.path,
            additionalDirectories: const <String>[],
            alt: 'Remote diagram',
            openExternalUri: (value) async => opened = value,
          ),
        ),
      ),
    );

    await tester.tap(
      find.byKey(const Key('markdown-remote-image-open-external')),
    );
    await tester.pump();

    expect(opened, uri);
    expect(
      find.byKey(const Key('markdown-remote-image-blocked')),
      findsOneWidget,
    );
    expect(find.byType(Image), findsNothing);
    expect(find.byType(SvgPicture), findsNothing);
  });

  testWidgets(
    'Markdown local images enforce actual byte limits despite stale metadata',
    (tester) async {
      final workspace = createWorkspace();
      final raster = File('${workspace.path}/oversized.png');
      var handle = raster.openSync(mode: FileMode.write);
      handle.truncateSync(16 * 1024 * 1024 + 1);
      handle.closeSync();
      final svg = File('${workspace.path}/oversized.svg');
      handle = svg.openSync(mode: FileMode.write);
      handle.truncateSync(2 * 1024 * 1024 + 1);
      handle.closeSync();

      Future<void> pumpLocalImage(String name) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: MarkdownPreviewImage(
                key: ValueKey(name),
                uri: Uri(path: name),
                workspacePath: workspace.path,
                baseDirectory: workspace.path,
                additionalDirectories: const <String>[],
                // A stale/forged SVG size must not let the path-backed image
                // bypass the bounded snapshot read used by the decoder.
                readLocalImageSize: (path) async =>
                    path.endsWith('.svg') ? 1 : File(path).lengthSync(),
              ),
            ),
          ),
        );
        for (var attempt = 0; attempt < 50; attempt += 1) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
          if (find.byType(CircularProgressIndicator).evaluate().isEmpty) {
            break;
          }
        }
      }

      await pumpLocalImage(raster.uri.pathSegments.last);
      expect(find.textContaining('图片文件超过 16 MB 限制'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
      expect(find.byType(SvgPicture), findsNothing);

      await pumpLocalImage(svg.uri.pathSegments.last);
      expect(find.textContaining('SVG 图片超过 2 MB 限制'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
      expect(find.byType(SvgPicture), findsNothing);
    },
  );

  testWidgets('Markdown data SVG uses the stricter 2 MB limit', (tester) async {
    final uri = Uri.dataFromBytes(
      List<int>.filled(2 * 1024 * 1024 + 1, 0x61),
      mimeType: 'image/svg+xml',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MarkdownPreviewImage(
            uri: uri,
            workspacePath: Directory.systemTemp.path,
            baseDirectory: Directory.systemTemp.path,
            additionalDirectories: const <String>[],
          ),
        ),
      ),
    );

    expect(find.textContaining('内嵌 SVG 超过 2 MB 限制'), findsOneWidget);
    expect(find.byType(SvgPicture), findsNothing);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('Markdown raster rejects hostile pixel dimensions', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MarkdownPreviewImage(
            uri: Uri.parse('data:image/png;base64,iVBORw0KGgo='),
            workspacePath: Directory.systemTemp.path,
            baseDirectory: Directory.systemTemp.path,
            additionalDirectories: const <String>[],
            inspectImageDimensions: (_) async => (width: 8192, height: 8192),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.textContaining('图片尺寸超过安全预览限制'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
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

  testWidgets('Markdown local image rejects an authorized-root ancestor swap', (
    tester,
  ) async {
    if (!Platform.isMacOS && !Platform.isLinux) return;
    final sandbox = Directory.systemTemp.createTempSync(
      'ianvs-markdown-image-ancestor-',
    );
    final authorizedParent = Directory('${sandbox.path}/authorized-parent');
    final workspace = Directory('${authorizedParent.path}/workspace')
      ..createSync(recursive: true);
    final inside = File('${workspace.path}/diagram.svg')
      ..writeAsStringSync(
        '<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"/>',
      );
    final attackerParent = Directory('${sandbox.path}/attacker-parent');
    final attackerWorkspace = Directory('${attackerParent.path}/workspace')
      ..createSync(recursive: true);
    File('${attackerWorkspace.path}/diagram.svg').writeAsStringSync(
      '<svg xmlns="http://www.w3.org/2000/svg"><text>SECRET_CANARY</text></svg>',
    );
    addTearDown(() => sandbox.deleteSync(recursive: true));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MarkdownPreviewImage(
            uri: Uri(path: inside.path),
            workspacePath: workspace.path,
            baseDirectory: workspace.path,
            additionalDirectories: const <String>[],
            beforeLocalImageRead: () {
              authorizedParent.renameSync(
                '${sandbox.path}/authorized-parent-old',
              );
              Link(authorizedParent.path).createSync(attackerParent.path);
            },
          ),
        ),
      ),
    );
    for (var attempt = 0; attempt < 50; attempt += 1) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
      if (find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
    }

    expect(find.byType(SvgPicture), findsNothing);
    expect(find.textContaining('SECRET_CANARY'), findsNothing);
    expect(find.textContaining('图片加载失败'), findsOneWidget);
  });

  testWidgets(
    'repeated local raster references stop at the document count and byte budget',
    (tester) async {
      final ledger = MarkdownImageLoadBudgetLedger(
        maxImages: 3,
        maxEncodedBytes: 12,
      );
      final decoder = _RejectingBoundedImageDecoder();
      final decodeLedger = AcpImageDecodeBudgetLedger(
        budget: const AcpInputBudget(),
      );
      var reads = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: SingleChildScrollView(
            child: Column(
              children: List<Widget>.generate(
                24,
                (index) => MarkdownPreviewImage(
                  uri: Uri(path: 'duplicate.png'),
                  workspacePath: Directory.systemTemp.path,
                  baseDirectory: Directory.systemTemp.path,
                  additionalDirectories: const <String>[],
                  loadBudgetLedger: ledger,
                  imageDecodeLedger: decodeLedger,
                  boundedImageDecoder: decoder,
                  resolveLocalImage:
                      ({
                        required source,
                        required workspacePath,
                        required baseDirectory,
                        required additionalDirectories,
                      }) async => FilePreviewTarget(
                        path: '${Directory.systemTemp.path}/duplicate.png',
                        workspacePath: Directory.systemTemp.path,
                      ),
                  readLocalImageSize: (_) async => 4,
                  readLocalImage:
                      (
                        _, {
                        required maximumBytes,
                        required cancellation,
                      }) async {
                        reads += 1;
                        expect(maximumBytes, greaterThanOrEqualTo(4));
                        return Uint8List.fromList(const <int>[1, 2, 3, 4]);
                      },
                  inspectImageDimensions: (_) async => (width: 1, height: 1),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(reads, 3);
      expect(
        decoder.createBufferCalls,
        2,
        reason: 'the shared global pixel ledger permits only two decodes',
      );
      expect(ledger.claimedImages, 3);
      expect(ledger.reservedBytes, 12);
      expect(ledger.waitingLoads, 0);
      expect(find.textContaining('此文档包含过多图片'), findsNWidgets(21));

      await tester.pumpWidget(const SizedBox.shrink());
      expect(ledger.claimedImages, 0);
      expect(ledger.reservedBytes, 0);
    },
  );

  testWidgets(
    'repeated data raster references decode only snapshots within the document budget',
    (tester) async {
      final ledger = MarkdownImageLoadBudgetLedger(
        maxImages: 3,
        maxEncodedBytes: 12,
      );
      final decoder = _RejectingBoundedImageDecoder();
      final decodeLedger = AcpImageDecodeBudgetLedger(
        budget: const AcpInputBudget(),
      );
      final uri = Uri.parse('data:image/png;base64,AQIDBA==');

      await tester.pumpWidget(
        MaterialApp(
          home: SingleChildScrollView(
            child: Column(
              children: List<Widget>.generate(
                24,
                (index) => MarkdownPreviewImage(
                  uri: uri,
                  workspacePath: Directory.systemTemp.path,
                  baseDirectory: Directory.systemTemp.path,
                  additionalDirectories: const <String>[],
                  loadBudgetLedger: ledger,
                  imageDecodeLedger: decodeLedger,
                  boundedImageDecoder: decoder,
                  inspectImageDimensions: (_) async => (width: 1, height: 1),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        decoder.createBufferCalls,
        2,
        reason: 'the shared global pixel ledger permits only two decodes',
      );
      expect(ledger.claimedImages, 3);
      expect(ledger.reservedBytes, 12);
      expect(ledger.waitingLoads, 0);
      expect(find.textContaining('此文档包含过多图片'), findsNWidgets(21));

      await tester.pumpWidget(const SizedBox.shrink());
      expect(ledger.claimedImages, 0);
      expect(ledger.reservedBytes, 0);
    },
  );

  testWidgets('exhausted document bytes fail queued images without a spinner', (
    tester,
  ) async {
    final ledger = MarkdownImageLoadBudgetLedger(
      maxImages: 3,
      maxEncodedBytes: 4,
    );
    final decoder = _RejectingBoundedImageDecoder();
    final decodeLedger = AcpImageDecodeBudgetLedger(
      budget: const AcpInputBudget(),
    );
    final uri = Uri.parse('data:image/png;base64,AQIDBA==');

    await tester.pumpWidget(
      MaterialApp(
        home: Column(
          children: List<Widget>.generate(
            3,
            (index) => MarkdownPreviewImage(
              uri: uri,
              workspacePath: Directory.systemTemp.path,
              baseDirectory: Directory.systemTemp.path,
              additionalDirectories: const <String>[],
              loadBudgetLedger: ledger,
              imageDecodeLedger: decodeLedger,
              boundedImageDecoder: decoder,
              inspectImageDimensions: (_) async => (width: 1, height: 1),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(decoder.createBufferCalls, 1);
    expect(find.textContaining('此文档的图片总大小超过安全预览限制'), findsNWidgets(2));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(ledger.waitingLoads, 0);
  });

  testWidgets('duplicate SVG references also consume document-wide capacity', (
    tester,
  ) async {
    const svg =
        '<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1">'
        '<rect width="1" height="1"/></svg>';
    final uri = Uri.dataFromString(svg, mimeType: 'image/svg+xml');
    final encodedBytes = uri.data!.contentAsBytes().length;
    final ledger = MarkdownImageLoadBudgetLedger(
      maxImages: 2,
      maxEncodedBytes: encodedBytes * 2,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SingleChildScrollView(
          child: Column(
            children: List<Widget>.generate(
              12,
              (index) => MarkdownPreviewImage(
                uri: uri,
                workspacePath: Directory.systemTemp.path,
                baseDirectory: Directory.systemTemp.path,
                additionalDirectories: const <String>[],
                loadBudgetLedger: ledger,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(SvgPicture), findsNWidgets(2));
    expect(ledger.claimedImages, 2);
    expect(ledger.reservedBytes, encodedBytes * 2);
    expect(find.textContaining('此文档包含过多图片'), findsNWidgets(10));

    await tester.pumpWidget(const SizedBox.shrink());
    expect(ledger.claimedImages, 0);
    expect(ledger.reservedBytes, 0);
  });

  testWidgets('switching file tabs cancels and releases an active image read', (
    tester,
  ) async {
    final workspace = createWorkspace();
    final markdown = File('${workspace.path}/preview.md')
      ..writeAsStringSync('![slow](slow.png)');
    final text = File('${workspace.path}/notes.txt')..writeAsStringSync('done');
    File('${workspace.path}/slow.png').writeAsBytesSync(const <int>[1, 2, 3]);
    final ledger = MarkdownImageLoadBudgetLedger(
      maxImages: 4,
      maxEncodedBytes: 32,
    );
    final decoder = _RejectingBoundedImageDecoder();

    Future<Uint8List> slowReader(
      File _, {
      required int maximumBytes,
      required AcpImageDecodeCancellation cancellation,
    }) {
      final completer = Completer<Uint8List>();
      void cancel() {
        if (!completer.isCompleted) {
          completer.completeError(const AcpImageDecodeCancelled());
        }
      }

      cancellation.addListener(cancel);
      return completer.future.whenComplete(
        () => cancellation.removeListener(cancel),
      );
    }

    await tester.pumpWidget(
      previewApp(
        workspacePath: workspace.path,
        markdown:
            '[Open preview](${markdown.path})\n\n[Open text](${text.path})',
        markdownImageLoadBudgetLedger: ledger,
        markdownLocalImageReader: slowReader,
        boundedImageDecoder: decoder,
      ),
    );
    await openMarkdownLink(tester, text: 'Open preview', href: markdown.path);
    for (var attempt = 0; attempt < 20 && !ledger.loadActive; attempt += 1) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(ledger.loadActive, isTrue);
    expect(ledger.claimedImages, 1);

    await openMarkdownLink(tester, text: 'Open text', href: text.path);
    await tester.pumpAndSettle();

    expect(find.text('done'), findsOneWidget);
    expect(find.byType(MarkdownPreviewImage), findsNothing);
    expect(ledger.loadActive, isFalse);
    expect(ledger.claimedImages, 0);
    expect(ledger.reservedBytes, 0);
    expect(ledger.waitingLoads, 0);
    expect(decoder.createBufferCalls, 0);
  });

  testWidgets('full file image previews use the shared bounded decoder', (
    tester,
  ) async {
    final workspace = createWorkspace();
    final image = File('${workspace.path}/preview.png')
      ..writeAsBytesSync(const <int>[1, 2, 3, 4]);
    final decoder = _RejectingBoundedImageDecoder();

    await tester.pumpWidget(
      previewApp(
        workspacePath: workspace.path,
        markdown: '[Open image](${image.path})',
        boundedImageDecoder: decoder,
        imageDimensionInspector: (_) async => (width: 1, height: 1),
      ),
    );
    await openMarkdownLink(tester, text: 'Open image', href: image.path);
    await tester.pumpAndSettle();

    expect(decoder.createBufferCalls, 1);
    expect(find.byKey(const ValueKey('bounded-image-placeholder')), findsOne);
    expect(find.byType(Image), findsNothing);
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

class _CountingHttpClient implements HttpClient {
  int requestCount = 0;

  @override
  Future<HttpClientRequest> getUrl(Uri url) {
    requestCount += 1;
    return Future<HttpClientRequest>.error(
      HttpException('Blocked by the widget test', uri: url),
    );
  }

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _RejectingBoundedImageDecoder implements BoundedImageDecoder {
  int createBufferCalls = 0;

  @override
  Future<BoundedImageBuffer> createBuffer(Uint8List bytes) async {
    createBufferCalls += 1;
    throw const FormatException('test decoder rejected bytes');
  }

  @override
  Future<BoundedImageDescriptor> createDescriptor(BoundedImageBuffer buffer) =>
      throw UnimplementedError();

  @override
  Future<BoundedImageCodec> createCodec(
    BoundedImageDescriptor descriptor, {
    required int targetWidth,
    required int targetHeight,
  }) => throw UnimplementedError();

  @override
  Future<BoundedImageFrame> getFirstFrame(BoundedImageCodec codec) =>
      throw UnimplementedError();
}

final class _WorkspaceHangingProcess implements Process {
  final Completer<int> _exitCode = Completer<int>();
  final StreamController<List<int>> _stdinController =
      StreamController<List<int>>();
  int killCalls = 0;

  @override
  Future<int> get exitCode => _exitCode.future;

  @override
  int get pid => 5252;

  @override
  Stream<List<int>> get stderr => const Stream<List<int>>.empty();

  @override
  IOSink get stdin => IOSink(_stdinController.sink);

  @override
  Stream<List<int>> get stdout => const Stream<List<int>>.empty();

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killCalls += 1;
    if (!_exitCode.isCompleted) _exitCode.complete(-signal.signalNumber);
    return true;
  }
}
