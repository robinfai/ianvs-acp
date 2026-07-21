import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/ui/file_preview/file_preview_document.dart';

void main() {
  test(
    'resolves relative file links and line anchors inside workspace',
    () async {
      final workspace = await Directory.systemTemp.createTemp(
        'ianvs-preview-resolve-',
      );
      addTearDown(() => workspace.delete(recursive: true));
      final file = File('${workspace.path}/docs/example.dart');
      await file.parent.create(recursive: true);
      await file.writeAsString('void main() {}\n');

      final target = await resolveFilePreviewTarget(
        href: 'docs/example.dart#L12',
        workspacePath: workspace.path,
      );

      expect(target.path, await file.resolveSymbolicLinks());
      expect(target.line, 12);
      expect(target.displayPath, 'docs/example.dart');
    },
  );

  test('resolves line suffix and authorized additional directory', () async {
    final workspace = await Directory.systemTemp.createTemp(
      'ianvs-preview-workspace-',
    );
    final additional = await Directory.systemTemp.createTemp(
      'ianvs-preview-additional-',
    );
    addTearDown(() async {
      await workspace.delete(recursive: true);
      await additional.delete(recursive: true);
    });
    final file = File('${additional.path}/shared.yaml');
    await file.writeAsString('enabled: true\n');

    final target = await resolveFilePreviewTarget(
      href: '${file.path}:7:3',
      workspacePath: workspace.path,
      additionalDirectories: <String>[additional.path],
    );

    expect(target.path, await file.resolveSymbolicLinks());
    expect(target.line, 7);
  });

  test(
    'rejects traversal and symlink escapes outside authorized roots',
    () async {
      final parent = await Directory.systemTemp.createTemp(
        'ianvs-preview-root-',
      );
      final workspace = Directory('${parent.path}/workspace');
      final outside = File('${parent.path}/secret.txt');
      await workspace.create();
      await outside.writeAsString('secret');
      addTearDown(() => parent.delete(recursive: true));

      await expectLater(
        resolveFilePreviewTarget(
          href: '../secret.txt',
          workspacePath: workspace.path,
        ),
        throwsA(isA<FileSystemException>()),
      );

      if (!Platform.isWindows) {
        final link = Link('${workspace.path}/linked.txt');
        await link.create(outside.path);
        await expectLater(
          resolveFilePreviewTarget(
            href: 'linked.txt',
            workspacePath: workspace.path,
          ),
          throwsA(isA<FileSystemException>()),
        );
      }
    },
  );

  test('classifies common preview types', () {
    expect(
      classifyFilePreview('README.md', 'text/markdown'),
      FilePreviewKind.markdown,
    );
    expect(
      classifyFilePreview('lib/main.dart', 'text/x-dart'),
      FilePreviewKind.text,
    );
    expect(
      classifyFilePreview('screen.png', 'image/png'),
      FilePreviewKind.image,
    );
    expect(
      classifyFilePreview('report.pdf', 'application/pdf'),
      FilePreviewKind.quickLook,
    );
    expect(
      classifyFilePreview(
        'deck.pptx',
        'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      ),
      FilePreviewKind.quickLook,
    );
    expect(
      classifyFilePreview('archive.zip', 'application/zip'),
      FilePreviewKind.unsupported,
    );
  });

  test(
    'loads text safely and marks previews truncated at the byte limit',
    () async {
      final workspace = await Directory.systemTemp.createTemp(
        'ianvs-preview-text-',
      );
      addTearDown(() => workspace.delete(recursive: true));
      final file = File('${workspace.path}/large.log');
      await file.writeAsBytes(
        List<int>.filled(filePreviewTextByteLimit + 32, 0x61),
      );
      final target = await resolveFilePreviewTarget(
        href: 'large.log',
        workspacePath: workspace.path,
      );

      final document = await loadFilePreviewDocument(target);

      expect(document.kind, FilePreviewKind.text);
      expect(document.textTruncated, isTrue);
      expect(document.text, hasLength(filePreviewTextByteLimit));
    },
  );
}
