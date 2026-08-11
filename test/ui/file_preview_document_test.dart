import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/ui/file_preview/file_preview_document.dart';
import 'package:path/path.dart' as p;

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
    'resolves Markdown images from relative, encoded, file, absolute, and workspace-root paths',
    () async {
      final workspace = await Directory.systemTemp.createTemp(
        'ianvs-markdown-images-',
      );
      final additional = await Directory.systemTemp.createTemp(
        'ianvs-markdown-images-extra-',
      );
      addTearDown(() async {
        await workspace.delete(recursive: true);
        await additional.delete(recursive: true);
      });
      final docs = Directory('${workspace.path}/docs');
      final relativeImage = File('${docs.path}/images/diagram one.png');
      final rootImage = File('${workspace.path}/assets/root.png');
      final additionalImage = File('${additional.path}/shared.png');
      await relativeImage.parent.create(recursive: true);
      await rootImage.parent.create(recursive: true);
      await relativeImage.writeAsBytes(<int>[1]);
      await rootImage.writeAsBytes(<int>[2]);
      await additionalImage.writeAsBytes(<int>[3]);

      final relative = await resolveMarkdownImageTarget(
        source: 'images/diagram%20one.png',
        workspacePath: workspace.path,
        baseDirectory: docs.path,
      );
      final absolute = await resolveMarkdownImageTarget(
        source: rootImage.path,
        workspacePath: workspace.path,
        baseDirectory: docs.path,
      );
      final workspaceRoot = await resolveMarkdownImageTarget(
        source: '/assets/root.png',
        workspacePath: workspace.path,
        baseDirectory: docs.path,
      );
      final fileUri = await resolveMarkdownImageTarget(
        source: Uri.file(additionalImage.path).toString(),
        workspacePath: workspace.path,
        baseDirectory: docs.path,
        additionalDirectories: <String>[additional.path],
      );

      expect(relative.path, await relativeImage.resolveSymbolicLinks());
      expect(absolute.path, await rootImage.resolveSymbolicLinks());
      expect(workspaceRoot.path, await rootImage.resolveSymbolicLinks());
      expect(fileUri.path, await additionalImage.resolveSymbolicLinks());
    },
  );

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

  test('maps Quick Look stdin content types explicitly', () {
    expect(quickLookContentTypeForPath('notes.txt'), 'public.plain-text');
    expect(quickLookContentTypeForPath('report.PDF'), 'com.adobe.pdf');
    expect(
      quickLookContentTypeForPath('deck.pptx'),
      'org.openxmlformats.presentationml.presentation',
    );
    expect(quickLookContentTypeForPath('movie.mp4'), 'public.mpeg-4');
    expect(quickLookContentTypeForPath('archive.zip'), isNull);
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

  test('loads image previews from a bounded in-memory snapshot', () async {
    final workspace = await Directory.systemTemp.createTemp(
      'ianvs-preview-image-bytes-',
    );
    addTearDown(() => workspace.delete(recursive: true));
    final file = File('${workspace.path}/snapshot.png');
    await file.writeAsBytes(<int>[0x89, 0x50, 0x4e, 0x47, 1, 2, 3]);
    final target = await resolveFilePreviewTarget(
      href: 'snapshot.png',
      workspacePath: workspace.path,
    );

    final document = await loadFilePreviewDocument(
      target,
      imageDimensionInspector: (_) async => (width: 1, height: 1),
    );

    expect(document.kind, FilePreviewKind.image);
    expect(document.previewBytes, <int>[0x89, 0x50, 0x4e, 0x47, 1, 2, 3]);
    expect(document.previewError, isNull);
  });

  test('rejects a small encoded image with hostile pixel dimensions', () async {
    final workspace = await Directory.systemTemp.createTemp(
      'ianvs-preview-image-pixels-',
    );
    addTearDown(() => workspace.delete(recursive: true));
    final file = File('${workspace.path}/pixel-bomb.png');
    await file.writeAsBytes(<int>[0x89, 0x50, 0x4e, 0x47]);
    final target = await resolveFilePreviewTarget(
      href: 'pixel-bomb.png',
      workspacePath: workspace.path,
    );

    final document = await loadFilePreviewDocument(
      target,
      imageDimensionInspector: (_) async => (width: 8192, height: 8192),
    );

    expect(document.kind, FilePreviewKind.image);
    expect(document.previewBytes, isNull);
    expect(document.previewError, contains('尺寸超过安全预览限制'));
  });

  test('rejects actual image bytes above the snapshot limit', () async {
    final workspace = await Directory.systemTemp.createTemp(
      'ianvs-preview-image-limit-',
    );
    addTearDown(() => workspace.delete(recursive: true));
    final file = File('${workspace.path}/oversized.png');
    final handle = await file.open(mode: FileMode.write);
    await handle.truncate(filePreviewImageByteLimit + 1);
    await handle.close();
    final target = await resolveFilePreviewTarget(
      href: 'oversized.png',
      workspacePath: workspace.path,
    );

    final document = await loadFilePreviewDocument(target);

    expect(document.kind, FilePreviewKind.image);
    expect(document.previewBytes, isNull);
    expect(document.previewError, contains('超过 16 MB 限制'));
  });

  test(
    'fails closed when an authorized file becomes an outside symlink',
    () async {
      if (Platform.isWindows) return;
      final parent = await Directory.systemTemp.createTemp(
        'ianvs-preview-swap-',
      );
      final workspace = Directory('${parent.path}/workspace')..createSync();
      final inside = File('${workspace.path}/notes.txt')
        ..writeAsStringSync('safe');
      final outside = File('${parent.path}/secret.txt')
        ..writeAsStringSync('SECRET_CANARY');
      addTearDown(() => parent.deleteSync(recursive: true));
      final target = await resolveFilePreviewTarget(
        href: inside.path,
        workspacePath: workspace.path,
      );

      await expectLater(
        loadFilePreviewDocument(
          target,
          beforeSecureRead: () async {
            await inside.delete();
            await Link(inside.path).create(outside.path);
          },
        ),
        throwsA(isA<FileSystemException>()),
      );
    },
  );

  test(
    'fails closed when an authorized-root ancestor becomes a symlink',
    () async {
      if (!Platform.isMacOS && !Platform.isLinux) return;
      final sandbox = await Directory.systemTemp.createTemp(
        'ianvs-preview-ancestor-swap-',
      );
      addTearDown(() => sandbox.delete(recursive: true));
      final authorizedParent = Directory('${sandbox.path}/authorized-parent');
      final workspace = Directory('${authorizedParent.path}/workspace');
      await workspace.create(recursive: true);
      await File('${workspace.path}/notes.txt').writeAsString('safe');
      final target = await resolveFilePreviewTarget(
        href: 'notes.txt',
        workspacePath: workspace.path,
      );

      final attackerParent = Directory('${sandbox.path}/attacker-parent');
      await Directory(
        '${attackerParent.path}/workspace',
      ).create(recursive: true);
      await File(
        '${attackerParent.path}/workspace/notes.txt',
      ).writeAsString('OUTSIDE_CANARY');
      await authorizedParent.rename('${sandbox.path}/authorized-parent-old');
      await Link(authorizedParent.path).create(attackerParent.path);

      await expectLater(
        loadFilePreviewDocument(target),
        throwsA(isA<FileSystemException>()),
      );
    },
  );

  test(
    'rejects oversized Quick Look input before starting a process',
    () async {
      final workspace = await Directory.systemTemp.createTemp(
        'ianvs-preview-quick-look-input-',
      );
      addTearDown(() => workspace.deleteSync(recursive: true));
      final file = File('${workspace.path}/oversized.pdf');
      final handle = await file.open(mode: FileMode.write);
      await handle.truncate(filePreviewQuickLookInputByteLimit + 1);
      await handle.close();
      final target = await resolveFilePreviewTarget(
        href: file.path,
        workspacePath: workspace.path,
      );
      var starts = 0;

      final document = await loadFilePreviewDocument(
        target,
        processStarter: (executable, arguments) async {
          starts += 1;
          throw StateError('must not start');
        },
      );

      expect(document.previewBytes, isNull);
      expect(document.previewError, contains('64 MB'));
      expect(starts, 0);
    },
  );

  test(
    'rejects Quick Look growth before allocating its transfer copy',
    () async {
      final workspace = await Directory.systemTemp.createTemp(
        'ianvs-preview-quick-look-growth-',
      );
      addTearDown(() => workspace.deleteSync(recursive: true));
      final file = File('${workspace.path}/document.pdf')
        ..writeAsStringSync('%PDF-safe');
      final target = await resolveFilePreviewTarget(
        href: file.path,
        workspacePath: workspace.path,
      );
      final coordinator = FilePreviewQuickLookCoordinator();
      addTearDown(coordinator.dispose);
      var starts = 0;

      final document = await loadFilePreviewDocument(
        target,
        quickLookCoordinator: coordinator,
        beforeQuickLookSnapshotRead: () async {
          await file.writeAsString('%PDF-safe-and-now-larger');
        },
        processStarter: (executable, arguments) async {
          starts += 1;
          throw StateError('must not start');
        },
      );

      expect(document.previewBytes, isNull);
      expect(document.previewError, contains('发生变化'));
      expect(starts, 0);
      expect(coordinator.hasActiveJob, isFalse);
      expect(coordinator.reservedInputBytes, 0);
    },
  );

  test(
    'Quick Look receives the authorized snapshot only through stdin',
    () async {
      final workspace = await Directory.systemTemp.createTemp(
        'ianvs-preview-quick-look-snapshot-',
      );
      addTearDown(() => workspace.deleteSync(recursive: true));
      final file = File('${workspace.path}/document.pdf')
        ..writeAsStringSync('%PDF-safe');
      final target = await resolveFilePreviewTarget(
        href: file.path,
        workspacePath: workspace.path,
      );
      List<int>? receivedInput;
      String? outputDirectory;
      _HangingProcess? fixtureProcess;
      final coordinator = FilePreviewQuickLookCoordinator();
      addTearDown(coordinator.dispose);

      final document = await loadFilePreviewDocument(
        target,
        quickLookCoordinator: coordinator,
        processStarter: (executable, arguments) async {
          expect(coordinator.reservedInputBytes, file.lengthSync() * 2);
          fixtureProcess = _quickLookFixtureProcess(arguments, (
            inputBytes,
          ) async {
            receivedInput = inputBytes;
            expect(arguments.last, '/dev/fd/0');
            expect(arguments, isNot(contains(file.path)));
            expect(arguments[arguments.indexOf('-c') + 1], 'com.adobe.pdf');
            outputDirectory = arguments[arguments.indexOf('-o') + 1];
            final tempStat = await Directory(outputDirectory!).stat();
            expect((tempStat.mode & 0x1ff).toRadixString(8), '700');
            await _quickLookOutputFile(arguments).writeAsBytes(<int>[1, 2, 3]);
          });
          return fixtureProcess!;
        },
        imageDimensionInspector: (_) async => (width: 1, height: 1),
      );

      expect(String.fromCharCodes(receivedInput!), '%PDF-safe');
      expect(document.previewError, isNull);
      expect(document.previewBytes, <int>[1, 2, 3]);
      expect(fixtureProcess?.stdinCloseCalls, 1);
      expect(Directory(outputDirectory!).existsSync(), isFalse);
      expect(coordinator.reservedInputBytes, 0);
    },
    skip: !Platform.isMacOS,
  );

  test(
    'Quick Look production process renders a real PDF from stdin',
    () async {
      if (!File('/usr/sbin/cupsfilter').existsSync() ||
          !File('/usr/bin/qlmanage').existsSync()) {
        return;
      }
      final workspace = await Directory.systemTemp.createTemp(
        'ianvs-preview-quick-look-real-stdin-',
      );
      addTearDown(() => workspace.deleteSync(recursive: true));
      final source = File('${workspace.path}/source.txt');
      await source.writeAsString('IANVS Quick Look stdin fixture\n');
      final converted = await Process.run('/usr/sbin/cupsfilter', <String>[
        '-m',
        'application/pdf',
        source.path,
      ], stdoutEncoding: null);
      expect(converted.exitCode, 0, reason: converted.stderr.toString());
      final pdf = File('${workspace.path}/fixture.pdf');
      await pdf.writeAsBytes(converted.stdout! as List<int>);
      final target = await resolveFilePreviewTarget(
        href: pdf.path,
        workspacePath: workspace.path,
      );

      final document = await loadFilePreviewDocument(
        target,
        quickLookTimeout: const Duration(seconds: 10),
        imageDimensionInspector: (_) async => (width: 1200, height: 1600),
      );

      expect(document.previewError, isNull);
      expect(document.previewBytes, isNotNull);
      expect(document.previewBytes!.take(4), <int>[0x89, 0x50, 0x4e, 0x47]);
    },
    skip: !Platform.isMacOS,
  );

  test('Quick Look native path honors one absolute deadline', () async {
    final workspace = await Directory.systemTemp.createTemp(
      'ianvs-preview-native-deadline-',
    );
    addTearDown(() => workspace.deleteSync(recursive: true));
    final file = File('${workspace.path}/document.pdf')
      ..writeAsStringSync('%PDF-safe');
    final target = await resolveFilePreviewTarget(
      href: file.path,
      workspacePath: workspace.path,
    );
    final coordinator = FilePreviewQuickLookCoordinator();
    addTearDown(coordinator.dispose);

    final stopwatch = Stopwatch()..start();
    final document = await loadFilePreviewDocument(
      target,
      quickLookCoordinator: coordinator,
      quickLookTimeout: Duration.zero,
    );
    stopwatch.stop();

    expect(document.previewBytes, isNull);
    expect(document.previewError, contains('超时'));
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
    expect(coordinator.hasActiveJob, isFalse);
    expect(coordinator.reservedInputBytes, 0);
  }, skip: !Platform.isMacOS);

  test(
    'Quick Look native cancellation releases process-group lease',
    () async {
      if (!File('/usr/sbin/cupsfilter').existsSync() ||
          !File('/usr/bin/qlmanage').existsSync()) {
        return;
      }
      final workspace = await Directory.systemTemp.createTemp(
        'ianvs-preview-native-cancel-',
      );
      addTearDown(() => workspace.deleteSync(recursive: true));
      final source = File('${workspace.path}/source.txt');
      await source.writeAsString(
        List<String>.filled(2000, 'IANVS cancellation fixture').join('\n'),
      );
      final converted = await Process.run('/usr/sbin/cupsfilter', <String>[
        '-m',
        'application/pdf',
        source.path,
      ], stdoutEncoding: null);
      expect(converted.exitCode, 0, reason: converted.stderr.toString());
      final pdf = File('${workspace.path}/fixture.pdf');
      await pdf.writeAsBytes(converted.stdout! as List<int>);
      final target = await resolveFilePreviewTarget(
        href: pdf.path,
        workspacePath: workspace.path,
      );
      final coordinator = FilePreviewQuickLookCoordinator();
      final cancellation = FilePreviewLoadCancellationSource();
      addTearDown(coordinator.dispose);

      final stopwatch = Stopwatch()..start();
      final load = loadFilePreviewDocument(
        target,
        quickLookCoordinator: coordinator,
        cancellation: cancellation,
        quickLookTimeout: const Duration(seconds: 10),
      );
      await _waitUntil(() => coordinator.hasActiveJob);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      cancellation.cancel();

      await expectLater(load, throwsA(isA<FilePreviewLoadCancelled>()));
      stopwatch.stop();
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
      expect(coordinator.hasActiveJob, isFalse);
      expect(coordinator.reservedInputBytes, 0);
    },
    skip: !Platform.isMacOS,
  );

  test(
    'Quick Look stdin is unaffected by later source-path replacement',
    () async {
      final workspace = await Directory.systemTemp.createTemp(
        'ianvs-preview-quick-look-input-postvalidate-',
      );
      addTearDown(() => workspace.deleteSync(recursive: true));
      final file = File('${workspace.path}/document.pdf')
        ..writeAsStringSync('%PDF-safe');
      final target = await resolveFilePreviewTarget(
        href: file.path,
        workspacePath: workspace.path,
      );
      List<int>? receivedInput;
      final document = await loadFilePreviewDocument(
        target,
        processStarter: (executable, arguments) async {
          await file.rename('${file.path}.old');
          await File(file.path).writeAsString('%PDF-evil');
          return _quickLookFixtureProcess(arguments, (inputBytes) async {
            receivedInput = inputBytes;
            await _quickLookOutputFile(
              arguments,
            ).writeAsBytes(const <int>[1, 2, 3]);
          });
        },
        imageDimensionInspector: (_) async => (width: 1, height: 1),
      );

      expect(String.fromCharCodes(receivedInput!), '%PDF-safe');
      expect(document.previewBytes, const <int>[1, 2, 3]);
      expect(document.previewError, isNull);
    },
    skip: !Platform.isMacOS,
  );

  test(
    'Quick Look cleanup deadline releases its coordinator lease',
    () async {
      final workspace = await Directory.systemTemp.createTemp(
        'ianvs-preview-quick-look-cleanup-',
      );
      addTearDown(() => workspace.deleteSync(recursive: true));
      final file = File('${workspace.path}/document.pdf')
        ..writeAsStringSync('%PDF-safe');
      final target = await resolveFilePreviewTarget(
        href: file.path,
        workspacePath: workspace.path,
      );
      final coordinator = FilePreviewQuickLookCoordinator();
      final cleanupStarted = Completer<Directory>();
      final releaseCleanup = Completer<void>();
      Directory? quarantined;
      addTearDown(() async {
        if (!releaseCleanup.isCompleted) releaseCleanup.complete();
        await Future<void>.delayed(Duration.zero);
        if (quarantined != null && quarantined!.existsSync()) {
          await quarantined!.delete(recursive: true);
        }
        coordinator.dispose();
      });

      final stopwatch = Stopwatch()..start();
      final document = await loadFilePreviewDocument(
        target,
        quickLookCoordinator: coordinator,
        quickLookTimeout: const Duration(milliseconds: 250),
        processStarter: _quickLookFixtureStarter((arguments, inputBytes) async {
          await _quickLookOutputFile(
            arguments,
          ).writeAsBytes(const <int>[1, 2, 3]);
          await File(
            '${_quickLookOutputFile(arguments).parent.path}/extra.tmp',
          ).writeAsBytes(const <int>[4]);
        }),
        temporaryDirectoryCleaner: (directory) {
          quarantined = directory;
          cleanupStarted.complete(directory);
          return releaseCleanup.future;
        },
        imageDimensionInspector: (_) async => (width: 1, height: 1),
      );
      stopwatch.stop();

      expect(document.previewBytes, const <int>[1, 2, 3]);
      expect(await cleanupStarted.future, same(quarantined));
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
      expect(coordinator.hasActiveJob, isFalse);
      expect(coordinator.queuedJobs, 0);
      expect(coordinator.reservedInputBytes, 0);
      final next = await coordinator.acquire(
        inputBytes: 1,
        cancellation: FilePreviewLoadCancellationSource(),
      );
      next.release();
      releaseCleanup.completeError(StateError('late cleanup failure'));
      await Future<void>.delayed(Duration.zero);
    },
    skip: !Platform.isMacOS,
  );

  test(
    'Quick Look quarantines abnormal fixed output before releasing its lease',
    () async {
      final workspace = await Directory.systemTemp.createTemp(
        'ianvs-preview-abnormal-cleanup-',
      );
      addTearDown(() => workspace.deleteSync(recursive: true));
      final file = File('${workspace.path}/document.pdf')
        ..writeAsStringSync('%PDF-safe');
      final target = await resolveFilePreviewTarget(
        href: file.path,
        workspacePath: workspace.path,
      );
      final coordinator = FilePreviewQuickLookCoordinator();
      addTearDown(coordinator.dispose);
      String? outputDirectory;

      final document = await loadFilePreviewDocument(
        target,
        quickLookCoordinator: coordinator,
        processStarter: _quickLookFixtureStarter((arguments, inputBytes) async {
          final output = _quickLookOutputFile(arguments);
          outputDirectory = output.parent.path;
          await Directory(output.path).create();
          await File('${output.path}/nested.bin').writeAsBytes(<int>[1, 2, 3]);
        }),
      );

      expect(document.previewBytes, isNull);
      expect(document.previewError, contains('不是安全的普通文件'));
      expect(coordinator.hasActiveJob, isFalse);
      expect(coordinator.reservedInputBytes, 0);
      expect(outputDirectory, isNotNull);
      expect(Directory(outputDirectory!).existsSync(), isFalse);
    },
    skip: !Platform.isMacOS,
  );

  test(
    'Quick Look coordinator serializes, bounds, and cancels queued jobs',
    () async {
      final coordinator = FilePreviewQuickLookCoordinator(
        maximumQueuedJobs: 1,
        maximumInFlightInputBytes: 10,
      );
      final first = await coordinator.acquire(
        inputBytes: 4,
        cancellation: FilePreviewLoadCancellationSource(),
      );
      final queuedCancellation = FilePreviewLoadCancellationSource();
      final queued = coordinator.acquire(
        inputBytes: 5,
        cancellation: queuedCancellation,
      );
      expect(coordinator.hasActiveJob, isTrue);
      expect(coordinator.queuedJobs, 1);
      expect(coordinator.reservedInputBytes, 9);
      await expectLater(
        coordinator.acquire(
          inputBytes: 1,
          cancellation: FilePreviewLoadCancellationSource(),
        ),
        throwsA(isA<StateError>()),
      );

      queuedCancellation.cancel();
      await expectLater(queued, throwsA(isA<FilePreviewLoadCancelled>()));
      expect(coordinator.queuedJobs, 0);
      expect(coordinator.reservedInputBytes, 4);
      first.release();
      expect(coordinator.hasActiveJob, isFalse);
      expect(coordinator.reservedInputBytes, 0);
      coordinator.dispose();
    },
  );

  test('Quick Look timeout kills the actual process handle', () async {
    final workspace = await Directory.systemTemp.createTemp(
      'ianvs-preview-quick-look-timeout-',
    );
    addTearDown(() => workspace.deleteSync(recursive: true));
    final file = File('${workspace.path}/document.pdf')
      ..writeAsStringSync('%PDF-safe');
    final target = await resolveFilePreviewTarget(
      href: file.path,
      workspacePath: workspace.path,
    );
    final process = _HangingProcess(completeOnKill: false);

    final document = await loadFilePreviewDocument(
      target,
      processStarter: (executable, arguments) async => process,
      quickLookTimeout: const Duration(milliseconds: 20),
    );

    expect(document.previewBytes, isNull);
    expect(document.previewError, contains('超时'));
    expect(
      process.killSignals,
      containsAll(<ProcessSignal>[
        ProcessSignal.sigterm,
        ProcessSignal.sigkill,
      ]),
    );
  }, skip: !Platform.isMacOS);

  test('Quick Look fails closed when stdin is unavailable', () async {
    final workspace = await Directory.systemTemp.createTemp(
      'ianvs-preview-quick-look-stdin-error-',
    );
    addTearDown(() => workspace.deleteSync(recursive: true));
    final file = File('${workspace.path}/document.pdf')
      ..writeAsStringSync('%PDF-safe');
    final target = await resolveFilePreviewTarget(
      href: file.path,
      workspacePath: workspace.path,
    );
    final process = _HangingProcess(throwOnStdinAccess: true);

    final document = await loadFilePreviewDocument(
      target,
      processStarter: (executable, arguments) async => process,
    );

    expect(document.previewBytes, isNull);
    expect(document.previewError, contains('安全传输'));
    expect(process.killSignals, contains(ProcessSignal.sigterm));
    await process._stdinController.close();
  }, skip: !Platform.isMacOS);

  test(
    'Quick Look cancellation bounds a stuck stdin and guards late errors',
    () async {
      final workspace = await Directory.systemTemp.createTemp(
        'ianvs-preview-quick-look-stdin-cancel-',
      );
      addTearDown(() => workspace.deleteSync(recursive: true));
      final file = File('${workspace.path}/document.pdf')
        ..writeAsStringSync('%PDF-safe');
      final target = await resolveFilePreviewTarget(
        href: file.path,
        workspacePath: workspace.path,
      );
      final consumer = _HangingStreamConsumer();
      final process = _HangingProcess(stdin: IOSink(consumer));
      final cancellation = FilePreviewLoadCancellationSource();
      final started = Completer<void>();

      final load = loadFilePreviewDocument(
        target,
        cancellation: cancellation,
        processStarter: (executable, arguments) async {
          started.complete();
          return process;
        },
        quickLookTimeout: const Duration(seconds: 2),
      );
      await started.future;
      await Future<void>.delayed(Duration.zero);
      cancellation.cancel();

      await expectLater(load, throwsA(isA<FilePreviewLoadCancelled>()));
      expect(process.killSignals, contains(ProcessSignal.sigterm));
      consumer.completion.completeError(StateError('late stdin failure'));
      await Future<void>.delayed(Duration.zero);
    },
    skip: !Platform.isMacOS,
  );

  test(
    'Quick Look deadline covers stalled and late process start',
    () async {
      final workspace = await Directory.systemTemp.createTemp(
        'ianvs-preview-quick-look-late-start-',
      );
      addTearDown(() => workspace.deleteSync(recursive: true));
      final file = File('${workspace.path}/document.pdf')
        ..writeAsStringSync('%PDF-safe');
      final target = await resolveFilePreviewTarget(
        href: file.path,
        workspacePath: workspace.path,
      );
      final starter = Completer<Process>();
      final lateProcess = _HangingProcess();
      String? outputPath;

      final document = await loadFilePreviewDocument(
        target,
        processStarter: (executable, arguments) {
          outputPath = arguments[arguments.indexOf('-o') + 1];
          return starter.future;
        },
        quickLookTimeout: const Duration(milliseconds: 20),
      );
      expect(document.previewError, contains('超时'));
      expect(outputPath, isNotNull);
      await _waitUntil(() => !Directory(outputPath!).existsSync());
      expect(Directory(outputPath!).existsSync(), isFalse);

      starter.complete(lateProcess);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(lateProcess.killSignals, contains(ProcessSignal.sigterm));
    },
    skip: !Platform.isMacOS,
  );

  test('Quick Look late-start pipe errors are fully guarded', () async {
    final workspace = await Directory.systemTemp.createTemp(
      'ianvs-preview-quick-look-late-pipe-error-',
    );
    addTearDown(() => workspace.deleteSync(recursive: true));
    final file = File('${workspace.path}/document.pdf')
      ..writeAsStringSync('%PDF-safe');
    final target = await resolveFilePreviewTarget(
      href: file.path,
      workspacePath: workspace.path,
    );
    final starter = Completer<Process>();
    final stdout = StreamController<List<int>>();
    final stderr = StreamController<List<int>>();
    addTearDown(() async {
      await stdout.close();
      await stderr.close();
    });
    final lateProcess = _HangingProcess(
      stdout: stdout.stream,
      stderr: stderr.stream,
      completeOnKill: false,
    );

    final document = await loadFilePreviewDocument(
      target,
      processStarter: (executable, arguments) => starter.future,
      quickLookTimeout: const Duration(milliseconds: 20),
    );
    expect(document.previewError, contains('超时'));

    starter.complete(lateProcess);
    await Future<void>.delayed(Duration.zero);
    stdout.addError(StateError('late stdout failure'));
    stderr.addError(StateError('late stderr failure'));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(lateProcess.killSignals, contains(ProcessSignal.sigterm));
  }, skip: !Platform.isMacOS);

  test(
    'Quick Look deadline detaches a descendant-held output pipe',
    () async {
      final workspace = await Directory.systemTemp.createTemp(
        'ianvs-preview-quick-look-held-pipe-',
      );
      addTearDown(() => workspace.deleteSync(recursive: true));
      final file = File('${workspace.path}/document.pdf')
        ..writeAsStringSync('%PDF-safe');
      final target = await resolveFilePreviewTarget(
        href: file.path,
        workspacePath: workspace.path,
      );
      final heldPipe = StreamController<List<int>>();
      addTearDown(heldPipe.close);
      final process = _HangingProcess(
        stdout: heldPipe.stream,
        initialExitCode: 0,
      );

      final stopwatch = Stopwatch()..start();
      final document = await loadFilePreviewDocument(
        target,
        processStarter: (executable, arguments) async => process,
        quickLookTimeout: const Duration(milliseconds: 30),
      );
      stopwatch.stop();
      expect(document.previewError, contains('超时'));
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
    },
    skip: !Platform.isMacOS,
  );

  test(
    'Quick Look output overflow kills the process without buffering it',
    () async {
      final workspace = await Directory.systemTemp.createTemp(
        'ianvs-preview-quick-look-output-',
      );
      addTearDown(() => workspace.deleteSync(recursive: true));
      final file = File('${workspace.path}/document.pdf')
        ..writeAsStringSync('%PDF-safe');
      final target = await resolveFilePreviewTarget(
        href: file.path,
        workspacePath: workspace.path,
      );
      final process = _HangingProcess(
        stdout: Stream<List<int>>.value(
          List<int>.filled(
            filePreviewQuickLookProcessOutputByteLimit ~/ 2 + 1,
            0x61,
          ),
        ),
        stderr: Stream<List<int>>.value(
          List<int>.filled(
            filePreviewQuickLookProcessOutputByteLimit ~/ 2,
            0x62,
          ),
        ),
      );

      final document = await loadFilePreviewDocument(
        target,
        processStarter: (executable, arguments) async => process,
      );

      expect(document.previewBytes, isNull);
      expect(document.previewError, contains('输出超过安全限制'));
      expect(process.killCalls, 1);
    },
    skip: !Platform.isMacOS,
  );

  test(
    'Quick Look ignores unrelated output entry floods and reads the fixed result',
    () async {
      final workspace = await Directory.systemTemp.createTemp(
        'ianvs-preview-quick-look-entry-flood-',
      );
      addTearDown(() => workspace.deleteSync(recursive: true));
      final file = File('${workspace.path}/document.pdf')
        ..writeAsStringSync('%PDF-safe');
      final target = await resolveFilePreviewTarget(
        href: file.path,
        workspacePath: workspace.path,
      );
      final document = await loadFilePreviewDocument(
        target,
        processStarter: _quickLookFixtureStarter((arguments, inputBytes) async {
          final output = Directory(arguments[arguments.indexOf('-o') + 1]);
          for (
            var index = 0;
            index < filePreviewQuickLookOutputEntryLimit + 1;
            index += 1
          ) {
            await File(
              '${output.path}/$index.png',
            ).writeAsBytes(const <int>[1]);
          }
          await _quickLookOutputFile(arguments).writeAsBytes(const <int>[7]);
        }),
        imageDimensionInspector: (_) async => (width: 1, height: 1),
      );
      expect(document.previewBytes, const <int>[7]);
      expect(document.previewError, isNull);
    },
    skip: !Platform.isMacOS,
  );

  test(
    'Quick Look ignores unrelated aggregate output name floods',
    () async {
      final workspace = await Directory.systemTemp.createTemp(
        'ianvs-preview-quick-look-name-flood-',
      );
      addTearDown(() => workspace.deleteSync(recursive: true));
      final file = File('${workspace.path}/document.pdf')
        ..writeAsStringSync('%PDF-safe');
      final target = await resolveFilePreviewTarget(
        href: file.path,
        workspacePath: workspace.path,
      );
      final document = await loadFilePreviewDocument(
        target,
        processStarter: _quickLookFixtureStarter((arguments, inputBytes) async {
          final output = Directory(arguments[arguments.indexOf('-o') + 1]);
          for (var index = 0; index < 17; index += 1) {
            final prefix = index.toString().padLeft(2, '0');
            final name = '$prefix-${'a' * 246}.png';
            await File('${output.path}/$name').writeAsBytes(const <int>[1]);
          }
          await _quickLookOutputFile(arguments).writeAsBytes(const <int>[8]);
        }),
        imageDimensionInspector: (_) async => (width: 1, height: 1),
      );
      expect(document.previewBytes, const <int>[8]);
      expect(document.previewError, isNull);
    },
    skip: !Platform.isMacOS,
  );

  test(
    'Quick Look rejects output root replacement before file capture',
    () async {
      final workspace = await Directory.systemTemp.createTemp(
        'ianvs-preview-quick-look-output-root-swap-',
      );
      addTearDown(() => workspace.deleteSync(recursive: true));
      final file = File('${workspace.path}/document.pdf')
        ..writeAsStringSync('%PDF-safe');
      final target = await resolveFilePreviewTarget(
        href: file.path,
        workspacePath: workspace.path,
      );
      var inspectorCalls = 0;
      String? swappedOutputPath;
      addTearDown(() async {
        for (final path in <String?>[
          swappedOutputPath,
          if (swappedOutputPath != null) '$swappedOutputPath-old',
        ]) {
          if (path != null && Directory(path).existsSync()) {
            await Directory(path).delete(recursive: true);
          }
        }
      });

      final document = await loadFilePreviewDocument(
        target,
        processStarter: _quickLookFixtureStarter((arguments, inputBytes) async {
          final output = Directory(arguments[arguments.indexOf('-o') + 1]);
          swappedOutputPath = output.path;
          await output.rename('${output.path}-old');
          await output.create();
          await _quickLookOutputFile(
            arguments,
          ).writeAsBytes(const <int>[9, 9, 9]);
        }),
        imageDimensionInspector: (_) async {
          inspectorCalls += 1;
          return (width: 1, height: 1);
        },
      );

      expect(document.previewBytes, isNull);
      expect(document.previewError, contains('不是安全的普通文件'));
      expect(inspectorCalls, 0);
    },
    skip: !Platform.isMacOS,
  );

  test('Quick Look rejects hard-linked fixed output', () async {
    final workspace = await Directory.systemTemp.createTemp(
      'ianvs-preview-quick-look-output-hardlink-',
    );
    addTearDown(() => workspace.deleteSync(recursive: true));
    final file = File('${workspace.path}/document.pdf')
      ..writeAsStringSync('%PDF-safe');
    final outside = File('${workspace.path}/outside.png')
      ..writeAsBytesSync(const <int>[9, 9, 9]);
    final target = await resolveFilePreviewTarget(
      href: file.path,
      workspacePath: workspace.path,
    );

    final document = await loadFilePreviewDocument(
      target,
      processStarter: _quickLookFixtureStarter((arguments, inputBytes) async {
        final linked = await Process.run('ln', <String>[
          outside.path,
          _quickLookOutputFile(arguments).path,
        ]);
        expect(linked.exitCode, 0, reason: linked.stderr.toString());
      }),
    );

    expect(document.previewBytes, isNull);
    expect(document.previewError, contains('不是安全的普通文件'));
  }, skip: !Platform.isMacOS);

  test(
    'Quick Look refuses symlink and replaced output files',
    () async {
      final workspace = await Directory.systemTemp.createTemp(
        'ianvs-preview-quick-look-output-swap-',
      );
      final outside = File('${workspace.path}/outside.png')
        ..writeAsBytesSync(const <int>[9, 9, 9]);
      addTearDown(() => workspace.deleteSync(recursive: true));
      final file = File('${workspace.path}/document.pdf')
        ..writeAsStringSync('%PDF-safe');
      final target = await resolveFilePreviewTarget(
        href: file.path,
        workspacePath: workspace.path,
      );

      final symlinkDocument = await loadFilePreviewDocument(
        target,
        processStarter: _quickLookFixtureStarter((arguments, inputBytes) async {
          await Link(_quickLookOutputFile(arguments).path).create(outside.path);
        }),
      );
      expect(symlinkDocument.previewBytes, isNull);

      String? outputPath;
      final swappedDocument = await loadFilePreviewDocument(
        target,
        processStarter: _quickLookFixtureStarter((arguments, inputBytes) async {
          outputPath = _quickLookOutputFile(arguments).path;
          await File(outputPath!).writeAsBytes(const <int>[1, 2, 3]);
        }),
        beforeQuickLookOutputRead: () async {
          await File(outputPath!).rename('$outputPath.old');
          await File(outputPath!).writeAsBytes(const <int>[9, 9, 9]);
        },
      );
      expect(swappedDocument.previewBytes, isNull);
      expect(swappedDocument.previewError, contains('发生了变化'));
    },
    skip: !Platform.isMacOS,
  );

  test(
    'rejects oversized Quick Look output before loading it into memory',
    () async {
      final workspace = await Directory.systemTemp.createTemp(
        'ianvs-preview-quick-look-limit-',
      );
      addTearDown(() => workspace.delete(recursive: true));
      final file = File('${workspace.path}/document.pdf');
      await file.writeAsString('%PDF-1.7');
      final target = await resolveFilePreviewTarget(
        href: 'document.pdf',
        workspacePath: workspace.path,
      );

      Future<void> oversizedThumbnail(
        List<String> arguments,
        List<int> inputBytes,
      ) async {
        final thumbnail = _quickLookOutputFile(arguments);
        final handle = await thumbnail.open(mode: FileMode.write);
        await handle.truncate(filePreviewImageByteLimit + 1);
        await handle.close();
      }

      final document = await loadFilePreviewDocument(
        target,
        processStarter: _quickLookFixtureStarter(oversizedThumbnail),
      );

      expect(document.kind, FilePreviewKind.quickLook);
      expect(document.previewBytes, isNull);
      expect(document.previewError, contains('超过 16 MB 限制'));
    },
    skip: !Platform.isMacOS,
  );

  test(
    'rejects high-pixel small Quick Look output before decoding',
    () async {
      final workspace = await Directory.systemTemp.createTemp(
        'ianvs-preview-quick-look-pixels-',
      );
      addTearDown(() => workspace.delete(recursive: true));
      final file = File('${workspace.path}/document.pdf');
      await file.writeAsString('%PDF-1.7');
      final target = await resolveFilePreviewTarget(
        href: 'document.pdf',
        workspacePath: workspace.path,
      );

      Future<void> hostileThumbnail(
        List<String> arguments,
        List<int> inputBytes,
      ) async {
        await _quickLookOutputFile(
          arguments,
        ).writeAsBytes(<int>[0x89, 0x50, 0x4e, 0x47]);
      }

      final document = await loadFilePreviewDocument(
        target,
        processStarter: _quickLookFixtureStarter(hostileThumbnail),
        imageDimensionInspector: (_) async => (width: 8192, height: 8192),
      );

      expect(document.kind, FilePreviewKind.quickLook);
      expect(document.previewBytes, isNull);
      expect(document.previewError, contains('尺寸超过安全限制'));
    },
    skip: !Platform.isMacOS,
  );
}

File _quickLookOutputFile(List<String> arguments) {
  final outputDirectory = arguments[arguments.indexOf('-o') + 1];
  return File(p.join(outputDirectory, '${p.basename(arguments.last)}.png'));
}

Future<void> _waitUntil(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 1));
  while (!predicate() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

FilePreviewProcessStarter _quickLookFixtureStarter(
  Future<void> Function(List<String> arguments, List<int> inputBytes) render,
) =>
    (executable, arguments) async => _quickLookFixtureProcess(
      arguments,
      (inputBytes) => render(arguments, inputBytes),
    );

_HangingProcess _quickLookFixtureProcess(
  List<String> arguments,
  Future<void> Function(List<int> inputBytes) render,
) => _HangingProcess(
  onStdinClosed: (inputBytes) async {
    await render(inputBytes);
    return 0;
  },
);

final class _HangingProcess implements Process {
  _HangingProcess({
    Stream<List<int>>? stdout,
    Stream<List<int>>? stderr,
    IOSink? stdin,
    int? initialExitCode,
    FutureOr<int> Function(List<int> bytes)? onStdinClosed,
    this.throwOnStdinAccess = false,
    this.completeOnKill = true,
  }) : _stdout = stdout ?? const Stream<List<int>>.empty(),
       _stderr = stderr ?? const Stream<List<int>>.empty() {
    if (stdin == null) {
      final input = BytesBuilder(copy: true);
      _stdinController.stream.listen(
        input.add,
        onError: (Object error, StackTrace stackTrace) {
          if (!_exitCode.isCompleted) {
            _exitCode.completeError(error, stackTrace);
          }
        },
        onDone: () {
          stdinCloseCalls += 1;
          receivedStdin = input.takeBytes();
          if (onStdinClosed == null) return;
          unawaited(
            Future<int>.sync(() => onStdinClosed(receivedStdin)).then(
              (code) {
                if (!_exitCode.isCompleted) _exitCode.complete(code);
              },
              onError: (Object error, StackTrace stackTrace) {
                if (!_exitCode.isCompleted) {
                  _exitCode.completeError(error, stackTrace);
                }
              },
            ),
          );
        },
        cancelOnError: false,
      );
      _stdin = IOSink(_stdinController.sink);
    } else {
      _stdin = stdin;
    }
    if (initialExitCode != null) _exitCode.complete(initialExitCode);
  }

  final Completer<int> _exitCode = Completer<int>();
  final StreamController<List<int>> _stdinController =
      StreamController<List<int>>();
  final Stream<List<int>> _stdout;
  final Stream<List<int>> _stderr;
  late final IOSink _stdin;
  final bool completeOnKill;
  final bool throwOnStdinAccess;
  List<int> receivedStdin = const <int>[];
  int stdinCloseCalls = 0;
  int killCalls = 0;
  final List<ProcessSignal> killSignals = <ProcessSignal>[];

  @override
  Future<int> get exitCode => _exitCode.future;

  @override
  int get pid => 4242;

  @override
  Stream<List<int>> get stderr => _stderr;

  @override
  IOSink get stdin {
    if (throwOnStdinAccess) throw StateError('stdin unavailable');
    return _stdin;
  }

  @override
  Stream<List<int>> get stdout => _stdout;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killCalls += 1;
    killSignals.add(signal);
    if (completeOnKill && !_exitCode.isCompleted) {
      _exitCode.complete(-signal.signalNumber);
    }
    return true;
  }
}

final class _HangingStreamConsumer implements StreamConsumer<List<int>> {
  final Completer<void> completion = Completer<void>();

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final _ in stream) {}
    return completion.future;
  }

  @override
  Future<void> close() => completion.future;
}
