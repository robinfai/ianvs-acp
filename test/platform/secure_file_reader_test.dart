import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/platform/secure_file_reader.dart';

void main() {
  test('anonymous stdin spawn is seekable and waitpid reports exit', () async {
    if (!Platform.isMacOS) return;
    final result = await spawnProcessWithAnonymousStdin(
      executable: '/usr/bin/perl',
      arguments: const <String>[
        '-e',
        r'exit 3 unless seek(STDIN,0,0); my $v; read(STDIN,$v,5); exit($v eq "hello" ? 0 : 4);',
      ],
      inputData: TransferableTypedData.fromList(<Uint8List>[
        Uint8List.fromList('hello'.codeUnits),
      ]),
      resolvedTemporaryDirectoryPath: await Directory.systemTemp
          .resolveSymbolicLinks(),
      deadline: DateTime.now().add(const Duration(seconds: 5)),
    );
    expect(result.process, isNotNull, reason: result.failure);
    final spawned = result.process!;
    final exit = await waitForSecureSpawnedProcess(
      spawned.pid,
    ).timeout(const Duration(seconds: 5));
    expect(exit?.exitCode, 0);
    expect(exit?.signal, isNull);
  });

  test('anonymous stdin spawn fails closed for a missing executable', () async {
    if (!Platform.isMacOS) return;
    final parent = await Directory.systemTemp.createTemp(
      'ianvs-anonymous-spawn-failure-',
    );
    addTearDown(() async {
      if (parent.existsSync()) await parent.delete(recursive: true);
    });
    final result = await spawnProcessWithAnonymousStdin(
      executable: '/definitely/missing/ianvs-binary',
      arguments: const <String>[],
      inputData: TransferableTypedData.fromList(<Uint8List>[Uint8List(0)]),
      resolvedTemporaryDirectoryPath: await parent.resolveSymbolicLinks(),
      deadline: DateTime.now().add(const Duration(seconds: 5)),
    );
    expect(result.process, isNull);
    expect(result.failure, contains('posix_spawn'));
    expect(await parent.list().toList(), isEmpty);
  });

  test('anonymous stdin rejects a renamed original after unlink', () async {
    if (!Platform.isMacOS) return;
    final parent = await Directory.systemTemp.createTemp(
      'ianvs-anonymous-replacement-',
    );
    addTearDown(() async {
      if (parent.existsSync()) await parent.delete(recursive: true);
    });
    final result = await spawnProcessWithAnonymousStdin(
      executable: '/usr/bin/perl',
      arguments: const <String>['-e', 'exit 0'],
      inputData: TransferableTypedData.fromList(<Uint8List>[
        Uint8List.fromList('secret snapshot'.codeUnits),
      ]),
      resolvedTemporaryDirectoryPath: await parent.resolveSymbolicLinks(),
      deadline: DateTime.now().add(const Duration(seconds: 5)),
      testReplaceAnonymousFileBeforeUnlink: true,
    );
    expect(result.process, isNull);
    expect(result.failure, contains('anonymous file create'));
    expect(await parent.list().toList(), isEmpty);
  });

  test('anonymous stdin transfer is consumed by the spawn isolate', () async {
    if (!Platform.isMacOS) return;
    final input = TransferableTypedData.fromList(<Uint8List>[
      Uint8List.fromList('hello'.codeUnits),
    ]);
    final result = await spawnProcessWithAnonymousStdin(
      executable: '/usr/bin/perl',
      arguments: const <String>['-e', 'exit 0'],
      inputData: input,
      resolvedTemporaryDirectoryPath: await Directory.systemTemp
          .resolveSymbolicLinks(),
      deadline: DateTime.now().add(const Duration(seconds: 5)),
    );
    expect(result.process, isNotNull, reason: result.failure);
    expect(input.materialize, throwsArgumentError);
    expect(
      (await waitForSecureSpawnedProcess(result.process!.pid))?.exitCode,
      0,
    );
  });

  test('spawn uses a fixed environment without parent secrets', () async {
    if (!Platform.isMacOS) return;
    const canaryName = 'IANVS_QUICK_LOOK_SECRET_CANARY';
    const canaryValue = 'must-not-reach-child';
    final library = DynamicLibrary.process();
    final setEnvironment = library
        .lookupFunction<
          Int32 Function(Pointer<Char>, Pointer<Char>, Int32),
          int Function(Pointer<Char>, Pointer<Char>, int)
        >('setenv');
    final unsetEnvironment = library
        .lookupFunction<
          Int32 Function(Pointer<Char>),
          int Function(Pointer<Char>)
        >('unsetenv');
    final nativeName = canaryName.toNativeUtf8();
    final nativeValue = canaryValue.toNativeUtf8();
    expect(
      setEnvironment(nativeName.cast<Char>(), nativeValue.cast<Char>(), 1),
      0,
    );
    addTearDown(() {
      unsetEnvironment(nativeName.cast<Char>());
      calloc.free(nativeName);
      calloc.free(nativeValue);
    });

    final result = await spawnProcessWithAnonymousStdin(
      executable: '/usr/bin/perl',
      arguments: const <String>[
        '-e',
        r'exit 9 if exists $ENV{"IANVS_QUICK_LOOK_SECRET_CANARY"}; exit 8 unless $ENV{"PATH"} eq "/usr/bin:/bin:/usr/sbin:/sbin" && $ENV{"LANG"} eq "en_US.UTF-8" && $ENV{"LC_ALL"} eq "en_US.UTF-8"; exit 0;',
      ],
      inputData: TransferableTypedData.fromList(<Uint8List>[Uint8List(0)]),
      resolvedTemporaryDirectoryPath: await Directory.systemTemp
          .resolveSymbolicLinks(),
      deadline: DateTime.now().add(const Duration(seconds: 5)),
    );
    expect(result.process, isNotNull, reason: result.failure);
    expect(
      (await waitForSecureSpawnedProcess(result.process!.pid))?.exitCode,
      0,
    );
  });

  test('CLOEXEC default hides an inheritable parent descriptor', () async {
    if (!Platform.isMacOS) return;
    final canary = await File(
      '${Directory.systemTemp.path}/ianvs-cloexec-canary-${DateTime.now().microsecondsSinceEpoch}',
    ).create();
    addTearDown(() async {
      if (canary.existsSync()) await canary.delete();
    });
    final library = DynamicLibrary.process();
    final openFile = library
        .lookupFunction<
          Int32 Function(Pointer<Char>, Int32),
          int Function(Pointer<Char>, int)
        >('open');
    final fileControl = library
        .lookupFunction<
          Int32 Function(Int32, Int32, VarArgs<(Int32,)>),
          int Function(int, int, int)
        >('fcntl');
    final closeFile = library
        .lookupFunction<Int32 Function(Int32), int Function(int)>('close');
    final nativePath = canary.path.toNativeUtf8();
    final canaryDescriptor = openFile(nativePath.cast<Char>(), 0);
    calloc.free(nativePath);
    expect(canaryDescriptor, greaterThanOrEqualTo(3));
    expect(fileControl(canaryDescriptor, 2, 0), 0);
    addTearDown(() {
      closeFile(canaryDescriptor);
    });

    final result = await spawnProcessWithAnonymousStdin(
      executable: '/usr/bin/perl',
      arguments: <String>[
        '-e',
        r'my $fd=$ARGV[0]; exit(open(my $fh, "<&=$fd") ? 9 : 0);',
        canaryDescriptor.toString(),
      ],
      inputData: TransferableTypedData.fromList(<Uint8List>[Uint8List(0)]),
      resolvedTemporaryDirectoryPath: await Directory.systemTemp
          .resolveSymbolicLinks(),
      deadline: DateTime.now().add(const Duration(seconds: 5)),
    );
    expect(result.process, isNotNull, reason: result.failure);
    expect(
      (await waitForSecureSpawnedProcess(result.process!.pid))?.exitCode,
      0,
    );
  });

  test('anonymous stdin normalizes a low-descriptor code path', () async {
    if (!Platform.isMacOS) return;
    final result = await spawnProcessWithAnonymousStdin(
      executable: '/usr/bin/perl',
      arguments: const <String>[
        '-e',
        r'my $v; read(STDIN,$v,5); exit($v eq "hello" ? 0 : 4);',
      ],
      inputData: TransferableTypedData.fromList(<Uint8List>[
        Uint8List.fromList('hello'.codeUnits),
      ]),
      resolvedTemporaryDirectoryPath: await Directory.systemTemp
          .resolveSymbolicLinks(),
      deadline: DateTime.now().add(const Duration(seconds: 5)),
      testForceAnonymousDescriptorNormalization: true,
    );
    expect(result.process, isNotNull, reason: result.failure);
    expect(
      (await waitForSecureSpawnedProcess(result.process!.pid))?.exitCode,
      0,
    );
  });

  test('anonymous stdin spawn honors an expired absolute deadline', () async {
    if (!Platform.isMacOS) return;
    final parent = await Directory.systemTemp.createTemp(
      'ianvs-anonymous-deadline-',
    );
    addTearDown(() async {
      if (parent.existsSync()) await parent.delete(recursive: true);
    });
    final result = await spawnProcessWithAnonymousStdin(
      executable: '/usr/bin/perl',
      arguments: const <String>['-e', 'sleep 30'],
      inputData: TransferableTypedData.fromList(<Uint8List>[
        Uint8List.fromList('secret snapshot'.codeUnits),
      ]),
      resolvedTemporaryDirectoryPath: await parent.resolveSymbolicLinks(),
      deadline: DateTime.now().subtract(const Duration(milliseconds: 1)),
    );
    expect(result.process, isNull);
    expect(result.deadlineExceeded, isTrue);
    expect(await parent.list().toList(), isEmpty);
  });

  test('anonymous stdin process group can be terminated and reaped', () async {
    if (!Platform.isMacOS) return;
    final result = await spawnProcessWithAnonymousStdin(
      executable: '/bin/sh',
      arguments: const <String>['-c', 'sleep 30 & wait'],
      inputData: TransferableTypedData.fromList(<Uint8List>[Uint8List(0)]),
      resolvedTemporaryDirectoryPath: await Directory.systemTemp
          .resolveSymbolicLinks(),
      deadline: DateTime.now().add(const Duration(seconds: 5)),
    );
    expect(result.process, isNotNull, reason: result.failure);
    final spawned = result.process!;
    expect(await signalSecureSpawnedProcessGroup(spawned.pid, 15), isTrue);
    final exit = await waitForSecureSpawnedProcess(
      spawned.pid,
    ).timeout(const Duration(seconds: 5));
    expect(exit, isNotNull);
    expect(exit!.exitCode, isNot(0));
  });

  test(
    'anonymous stdin backing file is unlinked and stdio has no pipes',
    () async {
      if (!Platform.isMacOS) return;
      final parent = await Directory.systemTemp.createTemp(
        'ianvs-anonymous-stdin-',
      );
      addTearDown(() async {
        if (parent.existsSync()) await parent.delete(recursive: true);
      });
      final result = await spawnProcessWithAnonymousStdin(
        executable: '/usr/bin/perl',
        arguments: const <String>[
          '-e',
          r'print STDOUT "x" x (1024*1024); print STDERR "y" x (1024*1024); sleep 1; exit 0;',
        ],
        inputData: TransferableTypedData.fromList(<Uint8List>[
          Uint8List.fromList('secret snapshot'.codeUnits),
        ]),
        resolvedTemporaryDirectoryPath: await parent.resolveSymbolicLinks(),
        deadline: DateTime.now().add(const Duration(seconds: 5)),
      );
      expect(result.process, isNotNull, reason: result.failure);
      expect(await parent.list().toList(), isEmpty);
      final exit = await waitForSecureSpawnedProcess(
        result.process!.pid,
      ).timeout(const Duration(seconds: 5));
      expect(exit?.exitCode, 0);
      expect(await parent.list().toList(), isEmpty);
    },
  );

  test('secure temporary directory is atomically bound and cleaned', () async {
    if (!Platform.isMacOS && !Platform.isLinux) return;
    final parent = await Directory.systemTemp.createTemp(
      'ianvs-secure-temp-parent-',
    );
    addTearDown(() async {
      if (parent.existsSync()) await parent.delete(recursive: true);
    });
    final resolvedParent = await parent.resolveSymbolicLinks();

    final created = await createSecureTemporaryDirectory(
      resolvedParentPath: resolvedParent,
      namePrefix: 'preview-',
    );
    expect(created, isNotNull);
    expect(
      created!.path,
      startsWith('$resolvedParent${Platform.pathSeparator}'),
    );
    expect(File(created.path).isAbsolute, isTrue);
    expect(RegExp(r'preview-[0-9a-f]{32}$').hasMatch(created.path), isTrue);
    final stat = await Directory(created.path).stat();
    expect((stat.mode & 0x1ff).toRadixString(8), '700');
    expect(await Directory(created.path).list().toList(), isEmpty);
    final observed = await captureDirectoryCapabilitySecurely(
      resolvedDirectoryPath: created.path,
    );
    expect(observed?.device, created.capability.device);
    expect(observed?.inode, created.capability.inode);

    await File('${created.path}/0.png').writeAsBytes(const <int>[1, 2, 3]);
    final cleanup = await quarantineSecureTemporaryDirectoryForCleanup(
      temporary: created,
      fixedOutputName: '0.png',
    );
    expect(cleanup?.removed, isFalse);
    expect(cleanup?.quarantine, isNotNull);
    expect(
      await deleteQuarantinedTemporaryDirectorySecurely(
        quarantine: cleanup!.quarantine!,
      ),
      isTrue,
    );
    expect(Directory(created.path).existsSync(), isFalse);
  });

  test('secure temporary cleanup refuses a swapped path', () async {
    if (!Platform.isMacOS && !Platform.isLinux) return;
    final parent = await Directory.systemTemp.createTemp(
      'ianvs-secure-temp-swap-',
    );
    addTearDown(() async {
      if (parent.existsSync()) await parent.delete(recursive: true);
    });
    final resolvedParent = await parent.resolveSymbolicLinks();
    final created = await createSecureTemporaryDirectory(
      resolvedParentPath: resolvedParent,
    );
    expect(created, isNotNull);
    final original = Directory(created!.path);
    await File('${original.path}/0.png').writeAsString('thumbnail');
    final moved = await original.rename('${original.path}.moved');
    final replacement = Directory(original.path);
    await replacement.create();
    final canary = File('${replacement.path}/0.png');
    await canary.writeAsString('DO_NOT_DELETE');

    final cleanup = await quarantineSecureTemporaryDirectoryForCleanup(
      temporary: created,
      fixedOutputName: '0.png',
    );

    expect(cleanup?.quarantine, isNotNull);
    expect(cleanup?.quarantine?.path, isNull);
    expect(
      await deleteQuarantinedTemporaryDirectorySecurely(
        quarantine: cleanup!.quarantine!,
      ),
      isTrue,
    );
    expect(await canary.readAsString(), 'DO_NOT_DELETE');
    expect(File('${moved.path}/0.png').existsSync(), isFalse);
  });

  test('secure cleanup removes abnormal fixed output entries', () async {
    if (!Platform.isMacOS && !Platform.isLinux) return;
    final parent = await Directory.systemTemp.createTemp(
      'ianvs-secure-abnormal-output-',
    );
    final outside = File('${parent.path}-outside-canary')
      ..writeAsStringSync('KEEP');
    addTearDown(() async {
      if (parent.existsSync()) await parent.delete(recursive: true);
      if (outside.existsSync()) await outside.delete();
    });
    final created = await createSecureTemporaryDirectory(
      resolvedParentPath: await parent.resolveSymbolicLinks(),
    );
    expect(created, isNotNull);
    final fixedOutput = Directory('${created!.path}/0.png');
    await fixedOutput.create();
    await File('${fixedOutput.path}/nested.bin').writeAsBytes(<int>[1, 2, 3]);
    await Link('${fixedOutput.path}/outside-link').create(outside.path);
    await Process.run('/bin/chmod', <String>['000', fixedOutput.path]);

    final prepared = await quarantineSecureTemporaryDirectoryForCleanup(
      temporary: created,
      fixedOutputName: '0.png',
    );
    expect(prepared?.quarantine, isNotNull);
    final quarantinePath = prepared!.quarantine!.path;
    expect(quarantinePath, isNotNull);
    expect(
      await deleteQuarantinedTemporaryDirectorySecurely(
        quarantine: prepared.quarantine!,
      ),
      isTrue,
    );
    expect(await outside.readAsString(), 'KEEP');
    expect(Directory(quarantinePath!).existsSync(), isFalse);
  });

  test(
    'secure cleanup clears pinned tree after quarantine path swap',
    () async {
      if (!Platform.isMacOS && !Platform.isLinux) return;
      final parent = await Directory.systemTemp.createTemp(
        'ianvs-secure-quarantine-swap-',
      );
      addTearDown(() async {
        if (parent.existsSync()) await parent.delete(recursive: true);
      });
      final created = await createSecureTemporaryDirectory(
        resolvedParentPath: await parent.resolveSymbolicLinks(),
      );
      expect(created, isNotNull);
      await Directory('${created!.path}/0.png').create();
      await File(
        '${created.path}/0.png/nested.bin',
      ).writeAsBytes(<int>[1, 2, 3]);
      final prepared = await quarantineSecureTemporaryDirectoryForCleanup(
        temporary: created,
        fixedOutputName: '0.png',
      );
      final quarantine = prepared?.quarantine;
      expect(quarantine?.path, isNotNull);
      final moved = await Directory(
        quarantine!.path!,
      ).rename('${quarantine.path!}.moved');
      final replacement = Directory(quarantine.path!)..createSync();
      final canary = File('${replacement.path}/canary')
        ..writeAsStringSync('KEEP');

      expect(
        await deleteQuarantinedTemporaryDirectorySecurely(
          quarantine: quarantine,
        ),
        isFalse,
      );
      expect(await canary.readAsString(), 'KEEP');
      expect(await moved.list().toList(), isEmpty);
    },
  );

  test('invalid cleanup entry closes its consumed pinned descriptor', () async {
    if (!Platform.isMacOS && !Platform.isLinux) return;
    final parent = await Directory.systemTemp.createTemp(
      'ianvs-secure-invalid-cleanup-',
    );
    addTearDown(() async {
      if (parent.existsSync()) await parent.delete(recursive: true);
    });
    final before = secureOpenDescriptorCountForTesting();
    final created = await createSecureTemporaryDirectory(
      resolvedParentPath: await parent.resolveSymbolicLinks(),
    );
    expect(created, isNotNull);
    final whilePinned = secureOpenDescriptorCountForTesting();
    expect(whilePinned, greaterThan(before));

    expect(
      await quarantineSecureTemporaryDirectoryForCleanup(
        temporary: created!,
        fixedOutputName: '../invalid',
      ),
      isNull,
    );
    final after = secureOpenDescriptorCountForTesting();
    expect(after, lessThan(whilePinned));
  });

  test('secure recursive cleanup stops at its global entry budget', () async {
    if (!Platform.isMacOS && !Platform.isLinux) return;
    final parent = await Directory.systemTemp.createTemp(
      'ianvs-secure-cleanup-budget-',
    );
    addTearDown(() async {
      if (parent.existsSync()) await parent.delete(recursive: true);
    });
    final created = await createSecureTemporaryDirectory(
      resolvedParentPath: await parent.resolveSymbolicLinks(),
    );
    expect(created, isNotNull);
    await File('${created!.path}/first').writeAsString('1');
    await File('${created.path}/second').writeAsString('2');
    final prepared = await quarantineSecureTemporaryDirectoryForCleanup(
      temporary: created,
      fixedOutputName: '0.png',
    );
    expect(prepared?.quarantine?.path, isNotNull);

    expect(
      await deleteQuarantinedTemporaryDirectorySecurely(
        quarantine: prepared!.quarantine!,
        maximumEntries: 1,
      ),
      isFalse,
    );
    expect(Directory(prepared.quarantinePath!).existsSync(), isTrue);
  });

  test('exclusive private writer creates a no-follow 0600 snapshot', () async {
    if (!Platform.isMacOS && !Platform.isLinux) return;
    final directory = await Directory.systemTemp.createTemp(
      'ianvs-secure-writer-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final resolved = await directory.resolveSymbolicLinks();

    expect(
      await writePrivateFileExclusiveSecurely(
        resolvedDirectoryPath: resolved,
        fileName: 'snapshot.bin',
        bytes: Uint8List.fromList(const <int>[1, 2, 3]),
      ),
      isTrue,
    );
    final stat = await File('$resolved/snapshot.bin').stat();
    expect((stat.mode & 0x1ff).toRadixString(8), '600');
    expect(await File('$resolved/snapshot.bin').readAsBytes(), <int>[1, 2, 3]);
    expect(
      await writePrivateFileExclusiveSecurely(
        resolvedDirectoryPath: resolved,
        fileName: 'snapshot.bin',
        bytes: Uint8List(0),
      ),
      isFalse,
    );
    final outside = File('${directory.parent.path}/writer-outside.bin')
      ..writeAsBytesSync(const <int>[9]);
    addTearDown(() async {
      if (outside.existsSync()) await outside.delete();
    });
    await Link('$resolved/linked.bin').create(outside.path);
    expect(
      await writePrivateFileExclusiveSecurely(
        resolvedDirectoryPath: resolved,
        fileName: 'linked.bin',
        bytes: Uint8List.fromList(const <int>[1]),
      ),
      isFalse,
    );
    expect(await outside.readAsBytes(), const <int>[9]);
  });

  test('secure reader rejects a FIFO without blocking', () async {
    if (!Platform.isMacOS && !Platform.isLinux) return;
    final workspace = await Directory.systemTemp.createTemp(
      'ianvs-secure-reader-fifo-',
    );
    addTearDown(() => workspace.delete(recursive: true));
    final sessionCache = Directory(
      '${workspace.path}/.ianvs/session-cache/session-1',
    );
    await sessionCache.create(recursive: true);
    final fifoPath = '${sessionCache.path}/report';
    final result = await Process.run('mkfifo', <String>[fifoPath]);
    expect(result.exitCode, 0, reason: result.stderr.toString());

    final read = await readWorkspaceFileSecurely(
      resolvedWorkspacePath: await workspace.resolveSymbolicLinks(),
      relativePath: '.ianvs/session-cache/session-1/report',
      previewLimit: 64,
    ).timeout(const Duration(seconds: 1));

    expect(read, isNull);
  });

  test('capability rejects an authorized-root ancestor symlink swap', () async {
    if (!Platform.isMacOS && !Platform.isLinux) return;
    final sandbox = await Directory.systemTemp.createTemp(
      'ianvs-secure-reader-ancestor-',
    );
    addTearDown(() => sandbox.delete(recursive: true));
    final authorizedParent = Directory('${sandbox.path}/authorized-parent');
    final workspace = Directory('${authorizedParent.path}/workspace');
    await workspace.create(recursive: true);
    await File('${workspace.path}/notes.txt').writeAsString('safe');
    final resolvedWorkspace = await workspace.resolveSymbolicLinks();
    final capability = await captureWorkspaceFileCapabilitySecurely(
      resolvedWorkspacePath: resolvedWorkspace,
      relativePath: 'notes.txt',
    );
    expect(capability, isNotNull);

    final attackerParent = Directory('${sandbox.path}/attacker-parent');
    await Directory('${attackerParent.path}/workspace').create(recursive: true);
    await File(
      '${attackerParent.path}/workspace/notes.txt',
    ).writeAsString('outside');
    await authorizedParent.rename('${sandbox.path}/authorized-parent-old');
    await Link(authorizedParent.path).create(attackerParent.path);

    final snapshot = await readWorkspaceFileSnapshotSecurely(
      resolvedWorkspacePath: resolvedWorkspace,
      relativePath: 'notes.txt',
      maximumBytes: 64,
      expectedCapability: capability!,
    );
    expect(snapshot, isNull);
  });

  test(
    'bounded snapshot preserves multiple chunks and rejects post-stat growth',
    () async {
      if (!Platform.isMacOS && !Platform.isLinux) return;
      final workspace = await Directory.systemTemp.createTemp(
        'ianvs-secure-reader-growth-',
      );
      addTearDown(() => workspace.delete(recursive: true));
      final bytes = Uint8List.fromList(
        List<int>.generate(160000, (index) => (index * 31) & 0xff),
      );
      final file = File('${workspace.path}/snapshot.bin')
        ..writeAsBytesSync(bytes);
      final resolvedWorkspace = await workspace.resolveSymbolicLinks();
      final capability = await captureWorkspaceFileCapabilitySecurely(
        resolvedWorkspacePath: resolvedWorkspace,
        relativePath: 'snapshot.bin',
      );
      expect(capability, isNotNull);

      final snapshot = await readWorkspaceFileSnapshotSecurely(
        resolvedWorkspacePath: resolvedWorkspace,
        relativePath: 'snapshot.bin',
        maximumBytes: bytes.length,
        expectedCapability: capability!,
      );
      expect(snapshot?.sizeBytes, bytes.length);
      expect(snapshot?.exceededLimit, isFalse);
      expect(snapshot?.bytes, bytes);

      final grown = await readWorkspaceFileSnapshotSecurely(
        resolvedWorkspacePath: resolvedWorkspace,
        relativePath: 'snapshot.bin',
        maximumBytes: bytes.length + 1,
        expectedCapability: capability,
        testGrowFileAfterInitialStat: true,
      );
      expect(grown, isNull);
      expect(file.lengthSync(), bytes.length + 1);
    },
  );

  test(
    'legacy streaming reader rejects a root ancestor symlink swap',
    () async {
      if (!Platform.isMacOS && !Platform.isLinux) return;
      final sandbox = await Directory.systemTemp.createTemp(
        'ianvs-secure-reader-legacy-ancestor-',
      );
      addTearDown(() => sandbox.delete(recursive: true));
      final authorizedParent = Directory('${sandbox.path}/authorized-parent');
      final workspace = Directory('${authorizedParent.path}/workspace');
      await workspace.create(recursive: true);
      await File('${workspace.path}/notes.txt').writeAsString('safe');
      final resolvedWorkspace = await workspace.resolveSymbolicLinks();

      final attackerParent = Directory('${sandbox.path}/attacker-parent');
      await Directory(
        '${attackerParent.path}/workspace',
      ).create(recursive: true);
      await File(
        '${attackerParent.path}/workspace/notes.txt',
      ).writeAsString('OUTSIDE_CANARY');
      await authorizedParent.rename('${sandbox.path}/authorized-parent-old');
      await Link(authorizedParent.path).create(attackerParent.path);

      final read = await readWorkspaceFileSecurely(
        resolvedWorkspacePath: resolvedWorkspace,
        relativePath: 'notes.txt',
        previewLimit: 64,
        maximumBytes: 64,
      );
      expect(read, isNull);
    },
  );

  test('capability rejects ordinary authorized-root replacement', () async {
    if (!Platform.isMacOS && !Platform.isLinux) return;
    final sandbox = await Directory.systemTemp.createTemp(
      'ianvs-secure-reader-root-',
    );
    addTearDown(() => sandbox.delete(recursive: true));
    final workspace = Directory('${sandbox.path}/workspace');
    await workspace.create();
    await File('${workspace.path}/notes.txt').writeAsString('safe');
    final resolvedWorkspace = await workspace.resolveSymbolicLinks();
    final capability = await captureWorkspaceFileCapabilitySecurely(
      resolvedWorkspacePath: resolvedWorkspace,
      relativePath: 'notes.txt',
    );
    expect(capability, isNotNull);

    await workspace.rename('${sandbox.path}/workspace-old');
    await workspace.create();
    await File('${workspace.path}/notes.txt').writeAsString('replacement');

    expect(
      await validateWorkspaceFileCapabilitySecurely(
        resolvedWorkspacePath: resolvedWorkspace,
        relativePath: 'notes.txt',
        expectedCapability: capability!,
      ),
      isFalse,
    );
  });

  test('capability rejects final regular and hardlink replacements', () async {
    if (!Platform.isMacOS && !Platform.isLinux) return;
    final sandbox = await Directory.systemTemp.createTemp(
      'ianvs-secure-reader-final-',
    );
    addTearDown(() => sandbox.delete(recursive: true));
    final workspace = Directory('${sandbox.path}/workspace');
    await workspace.create();
    final target = File('${workspace.path}/notes.txt');
    await target.writeAsString('safe');
    final resolvedWorkspace = await workspace.resolveSymbolicLinks();
    final capability = await captureWorkspaceFileCapabilitySecurely(
      resolvedWorkspacePath: resolvedWorkspace,
      relativePath: 'notes.txt',
    );
    expect(capability, isNotNull);

    await target.rename('${workspace.path}/notes-old.txt');
    await target.writeAsString('regular replacement');
    expect(
      await validateWorkspaceFileCapabilitySecurely(
        resolvedWorkspacePath: resolvedWorkspace,
        relativePath: 'notes.txt',
        expectedCapability: capability!,
      ),
      isFalse,
    );

    await target.delete();
    final outside = File('${sandbox.path}/outside.txt');
    await outside.writeAsString('hardlink replacement');
    final linked = await Process.run('ln', <String>[outside.path, target.path]);
    expect(linked.exitCode, 0, reason: linked.stderr.toString());
    expect(
      await validateWorkspaceFileCapabilitySecurely(
        resolvedWorkspacePath: resolvedWorkspace,
        relativePath: 'notes.txt',
        expectedCapability: capability,
      ),
      isFalse,
    );
  });
}
