import 'dart:async';
import 'dart:io';

import 'package:dart_acp/src/providers/secure_fs_writer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  if (!Platform.isMacOS && !Platform.isLinux) {
    test('secure writer fails closed on unsupported platforms', () async {
      await expectLater(
        writeSecureTextFile(
          canonicalRoot: '/',
          relativePath: 'never-created',
          content: 'x',
          maxWriteBytes: 1,
        ),
        throwsUnsupportedError,
      );
    });
    return;
  }

  group('secure POSIX writer', () {
    test('validates budgets before starting an isolate', () async {
      await expectLater(
        writeSecureTextFile(
          canonicalRoot: '/',
          relativePath: 'never-created',
          content: 'x',
          maxWriteBytes: 0,
        ),
        throwsArgumentError,
      );
      await expectLater(
        writeSecureTextFile(
          canonicalRoot: '/',
          relativePath: 'never-created',
          content: 'x',
          maxWriteBytes: -1,
        ),
        throwsArgumentError,
      );
    });

    test(
      'rejects non-canonical absolute roots before touching their parent',
      () async {
        final root = await _createCanonicalTemp('secure-root-canonical-');
        addTearDown(() => root.delete(recursive: true));
        final parentTarget = File('${root.parent.path}/must-not-write.txt');
        addTearDown(() async {
          if (await parentTarget.exists()) await parentTarget.delete();
        });

        for (final invalidRoot in <String>[
          '${root.path}/..',
          '${root.path}/.',
          '${root.path}/',
          '${root.path}//nested/..',
        ]) {
          await expectLater(
            writeSecureTextFile(
              canonicalRoot: invalidRoot,
              relativePath: 'must-not-write.txt',
              content: 'blocked',
              maxWriteBytes: 16,
            ),
            throwsA(isA<FileSystemException>()),
            reason: invalidRoot,
          );
        }
        expect(await parentTarget.exists(), isFalse);
      },
    );

    test(
      'writes, overwrites, empties, and creates nested directories',
      () async {
        final root = await _createCanonicalTemp('secure-write-');
        addTearDown(() => root.delete(recursive: true));
        const relative = 'one/two/value.txt';

        await writeSecureTextFile(
          canonicalRoot: root.path,
          relativePath: relative,
          content: 'first 🙂',
          maxWriteBytes: 64,
        );
        expect(await File('${root.path}/$relative').readAsString(), 'first 🙂');

        await writeSecureTextFile(
          canonicalRoot: root.path,
          relativePath: relative,
          content: 'x',
          maxWriteBytes: 64,
        );
        expect(await File('${root.path}/$relative').readAsString(), 'x');

        await writeSecureTextFile(
          canonicalRoot: root.path,
          relativePath: relative,
          content: '',
          maxWriteBytes: 64,
        );
        expect(await File('${root.path}/$relative').readAsBytes(), isEmpty);
      },
    );

    test('preserves the mode of an existing file', () async {
      final root = await _createCanonicalTemp('secure-mode-');
      addTearDown(() => root.delete(recursive: true));
      final file = File('${root.path}/value.txt');
      await file.writeAsString('before');
      final chmod = await Process.run('chmod', <String>['0600', file.path]);
      expect(chmod.exitCode, 0);

      await writeSecureTextFile(
        canonicalRoot: root.path,
        relativePath: 'value.txt',
        content: 'after',
        maxWriteBytes: 64,
      );

      final stat = await Process.run('stat', <String>[
        if (Platform.isMacOS) '-f' else '-c',
        if (Platform.isMacOS) '%Lp' else '%a',
        file.path,
      ]);
      expect(stat.exitCode, 0);
      expect((stat.stdout as String).trim(), '600');
    });

    test(
      'preserves macOS ACL and extended attributes without copying data',
      () async {
        final root = await _createCanonicalTemp('secure-metadata-');
        addTearDown(() => root.delete(recursive: true));
        final file = File('${root.path}/value.txt');
        const attributeName = 'com.dart-acp.metadata-canary';
        const attributeValue = 'metadata-secret-canary';
        await file.writeAsString('old-data-must-not-return');
        expect(
          (await Process.run('chmod', <String>['0666', file.path])).exitCode,
          0,
        );
        final addAttribute = await Process.run('xattr', <String>[
          '-w',
          attributeName,
          attributeValue,
          file.path,
        ]);
        expect(
          addAttribute.exitCode,
          0,
          reason: addAttribute.stderr.toString(),
        );
        final addAcl = await Process.run('chmod', <String>[
          '+a',
          'everyone deny read',
          file.path,
        ]);
        expect(addAcl.exitCode, 0, reason: addAcl.stderr.toString());

        await writeSecureTextFile(
          canonicalRoot: root.path,
          relativePath: 'value.txt',
          content: 'replacement',
          maxWriteBytes: 32,
        );

        final acl = await Process.run('ls', <String>['-le', file.path]);
        expect(acl.exitCode, 0, reason: acl.stderr.toString());
        expect(acl.stdout.toString(), contains('everyone deny read'));
        expect(
          (await Process.run('chmod', <String>['-N', file.path])).exitCode,
          0,
        );
        final attribute = await Process.run('xattr', <String>[
          '-p',
          attributeName,
          file.path,
        ]);
        expect(attribute.exitCode, 0, reason: attribute.stderr.toString());
        expect(attribute.stdout.toString().trim(), attributeValue);
        expect(await file.readAsString(), 'replacement');
      },
      skip: !Platform.isMacOS,
    );

    test(
      'fails before rename without exposing metadata when copying it fails',
      () async {
        final root = await _createCanonicalTemp('secure-metadata-fail-');
        addTearDown(() => root.delete(recursive: true));
        final file = File('${root.path}/value.txt');
        const attributeName = 'com.dart-acp.failure-canary';
        const attributeValue = 'metadata-value-must-not-leak';
        await file.writeAsString('original');
        final addAttribute = await Process.run('xattr', <String>[
          '-w',
          attributeName,
          attributeValue,
          file.path,
        ]);
        expect(
          addAttribute.exitCode,
          0,
          reason: addAttribute.stderr.toString(),
        );

        await expectLater(
          writeSecureTextFile(
            canonicalRoot: root.path,
            relativePath: 'value.txt',
            content: 'replacement',
            maxWriteBytes: 32,
            testHooks: const SecureFsWriteTestHooks(
              forceMetadataCopyFailure: true,
            ),
          ),
          throwsA(
            isA<FileSystemException>()
                .having(
                  (error) => error.message,
                  'message',
                  'Secure file write failed',
                )
                .having(
                  (error) => error.toString(),
                  'public text',
                  allOf(
                    isNot(contains(attributeName)),
                    isNot(contains(attributeValue)),
                  ),
                ),
          ),
        );
        expect(await file.readAsString(), 'original');
        expect(await _temporaryWriteEntries(root), isEmpty);
      },
      skip: !Platform.isMacOS,
    );

    test(
      'keeps an existing-target content temp at 0600 before writing',
      () async {
        final root = await _createCanonicalTemp('secure-temp-mode-old-');
        addTearDown(() => root.delete(recursive: true));
        final target = File('${root.path}/value.txt');
        final modeLog = File('${root.path}/mode.log');
        await target.writeAsString('original');
        expect(
          (await Process.run('chmod', <String>['0600', target.path])).exitCode,
          0,
        );

        await writeSecureTextFile(
          canonicalRoot: root.path,
          relativePath: 'value.txt',
          content: 'replacement',
          maxWriteBytes: 32,
          testHooks: SecureFsWriteTestHooks(
            onHook: (event) {
              if (event.phase == SecureFsWriteHookPhase.beforeNativeWrite) {
                modeLog.writeAsStringSync(_singleTemporaryMode(root));
              }
            },
          ),
        );

        expect(await modeLog.readAsString(), '600');
        expect(await _temporaryWriteEntries(root), isEmpty);
      },
    );

    test(
      'uses a 0600 content temp while preserving new-file umask mode',
      () async {
        final root = await _createCanonicalTemp('secure-temp-mode-new-');
        addTearDown(() => root.delete(recursive: true));
        final expectedModeProbe = File('${root.path}/expected-mode');
        await expectedModeProbe.create();
        final expectedMode =
            (await expectedModeProbe.stat()).mode & _permissionModeMask;
        await expectedModeProbe.delete();
        final modeLog = File('${root.path}/mode.log');

        await writeSecureTextFile(
          canonicalRoot: root.path,
          relativePath: 'value.txt',
          content: 'replacement',
          maxWriteBytes: 32,
          testHooks: SecureFsWriteTestHooks(
            onHook: (event) {
              if (event.phase == SecureFsWriteHookPhase.beforeNativeWrite) {
                modeLog.writeAsStringSync(_singleTemporaryMode(root));
              }
            },
          ),
        );

        expect(await modeLog.readAsString(), '600');
        expect(
          (await File('${root.path}/value.txt').stat()).mode &
              _permissionModeMask,
          expectedMode,
        );
        expect(await _temporaryWriteEntries(root), isEmpty);
      },
    );

    test(
      'replaces a workspace hard link without modifying the external inode',
      () async {
        final root = await _createCanonicalTemp('secure-hardlink-root-');
        final outside = await _createCanonicalTemp('secure-hardlink-outside-');
        addTearDown(() => root.delete(recursive: true));
        addTearDown(() => outside.delete(recursive: true));
        final outsideFile = File('${outside.path}/shared.txt');
        final workspaceFile = File('${root.path}/workspace.txt');
        final originalBytes = <int>[
          0x6f,
          0x72,
          0x69,
          0x67,
          0x69,
          0x6e,
          0x61,
          0x6c,
        ];
        await outsideFile.writeAsBytes(originalBytes);
        final link = await Process.run('ln', <String>[
          outsideFile.path,
          workspaceFile.path,
        ]);
        expect(link.exitCode, 0, reason: link.stderr.toString());

        await writeSecureTextFile(
          canonicalRoot: root.path,
          relativePath: 'workspace.txt',
          content: 'replacement',
          maxWriteBytes: 32,
        );

        expect(await outsideFile.readAsBytes(), originalBytes);
        expect(await workspaceFile.readAsString(), 'replacement');
      },
    );

    test(
      'does not modify a hard link created after final validation',
      () async {
        final root = await _createCanonicalTemp('secure-hardlink-race-root-');
        final outside = await _createCanonicalTemp('secure-hardlink-race-out-');
        addTearDown(() => root.delete(recursive: true));
        addTearDown(() => outside.delete(recursive: true));
        final target = File('${root.path}/value.txt');
        final externalLink = File('${outside.path}/late-link.txt');
        await target.writeAsString('original');
        var linked = false;

        await writeSecureTextFile(
          canonicalRoot: root.path,
          relativePath: 'value.txt',
          content: 'replacement',
          maxWriteBytes: 32,
          testHooks: SecureFsWriteTestHooks(
            onHook: (event) {
              if (!linked &&
                  event.phase == SecureFsWriteHookPhase.afterFinalValidation) {
                linked = true;
                final result = Process.runSync('ln', <String>[
                  event.canonicalTarget,
                  externalLink.path,
                ]);
                if (result.exitCode != 0) {
                  throw StateError(result.stderr.toString());
                }
              }
            },
          ),
        );

        expect(await externalLink.exists(), isTrue);
        expect(await externalLink.readAsString(), 'original');
        expect(await target.readAsString(), 'replacement');
      },
    );

    test(
      'accepts exact UTF-8 bytes and rejects max plus one without mutation',
      () async {
        final root = await _createCanonicalTemp('secure-limit-');
        addTearDown(() => root.delete(recursive: true));
        final exact = File('${root.path}/exact.txt');
        final unchanged = File('${root.path}/unchanged.txt');
        await unchanged.writeAsString('original');

        await writeSecureTextFile(
          canonicalRoot: root.path,
          relativePath: 'exact.txt',
          content: '🙂',
          maxWriteBytes: 4,
        );
        expect(await exact.readAsString(), '🙂');

        await expectLater(
          writeSecureTextFile(
            canonicalRoot: root.path,
            relativePath: 'unchanged.txt',
            content: '🙂x',
            maxWriteBytes: 4,
          ),
          throwsA(isA<SecureFsWriteLimitExceeded>()),
        );
        expect(await unchanged.readAsString(), 'original');
        expect(Directory('${root.path}/missing').existsSync(), isFalse);
        await expectLater(
          writeSecureTextFile(
            canonicalRoot: root.path,
            relativePath: 'missing/value.txt',
            content: '🙂x',
            maxWriteBytes: 4,
          ),
          throwsA(isA<SecureFsWriteLimitExceeded>()),
        );
        expect(Directory('${root.path}/missing').existsSync(), isFalse);
      },
    );

    test(
      'matches UTF-8 replacement handling for isolated surrogates',
      () async {
        final root = await _createCanonicalTemp('secure-surrogate-');
        addTearDown(() => root.delete(recursive: true));
        final content = String.fromCharCode(0xd800);

        await writeSecureTextFile(
          canonicalRoot: root.path,
          relativePath: 'value.txt',
          content: content,
          maxWriteBytes: 3,
        );
        expect(await File('${root.path}/value.txt').readAsBytes(), <int>[
          0xef,
          0xbf,
          0xbd,
        ]);
        await expectLater(
          writeSecureTextFile(
            canonicalRoot: root.path,
            relativePath: 'too-small.txt',
            content: content,
            maxWriteBytes: 2,
          ),
          throwsA(isA<SecureFsWriteLimitExceeded>()),
        );
      },
    );

    test('rejects directories and FIFOs as final targets', () async {
      final root = await _createCanonicalTemp('secure-special-');
      addTearDown(() => root.delete(recursive: true));
      await Directory('${root.path}/directory').create();
      await expectLater(
        writeSecureTextFile(
          canonicalRoot: root.path,
          relativePath: 'directory',
          content: 'x',
          maxWriteBytes: 8,
        ),
        throwsA(isA<FileSystemException>()),
      );

      final fifo = '${root.path}/pipe';
      final mkfifo = await Process.run('mkfifo', <String>[fifo]);
      expect(mkfifo.exitCode, 0);
      await expectLater(
        writeSecureTextFile(
          canonicalRoot: root.path,
          relativePath: 'pipe',
          content: 'x',
          maxWriteBytes: 8,
        ).timeout(const Duration(seconds: 2)),
        throwsA(isA<FileSystemException>()),
      );
    });

    test(
      'handles partial writes and EINTR, and treats zero writes as failure',
      () async {
        final root = await _createCanonicalTemp('secure-partial-');
        addTearDown(() => root.delete(recursive: true));

        await writeSecureTextFile(
          canonicalRoot: root.path,
          relativePath: 'partial.txt',
          content: 'abcdef',
          maxWriteBytes: 8,
          testHooks: const SecureFsWriteTestHooks(
            maxNativeWriteBytes: 2,
            writeEintrCount: 1,
          ),
        );
        expect(await File('${root.path}/partial.txt').readAsString(), 'abcdef');

        final zeroTarget = File('${root.path}/zero.txt');
        await zeroTarget.writeAsString('original');
        await expectLater(
          writeSecureTextFile(
            canonicalRoot: root.path,
            relativePath: 'zero.txt',
            content: 'abc',
            maxWriteBytes: 8,
            testHooks: const SecureFsWriteTestHooks(forceZeroWrite: true),
          ),
          throwsA(isA<FileSystemException>()),
        );
        expect(await zeroTarget.readAsString(), 'original');
        expect(await _temporaryWriteEntries(root), isEmpty);
      },
    );

    test(
      'caps native allocation at 64 KiB across partial multi-chunk writes',
      () async {
        final root = await _createCanonicalTemp('secure-chunked-');
        addTearDown(() => root.delete(recursive: true));
        final allocationLog = File('${root.path}/allocation.log');
        final content = 'a' * (secureFsWriteChunkSize + 17);

        await writeSecureTextFile(
          canonicalRoot: root.path,
          relativePath: 'value.txt',
          content: content,
          maxWriteBytes: 8 * 1024 * 1024,
          testHooks: SecureFsWriteTestHooks(
            maxNativeWriteBytes: 7,
            writeEintrCount: 2,
            onNativeAllocation: (bytes) {
              allocationLog.writeAsStringSync('$bytes');
            },
          ),
        );

        expect(int.parse(await allocationLog.readAsString()), 64 * 1024);
        expect(await File('${root.path}/value.txt').readAsString(), content);
      },
    );

    test(
      'reports close failure after a successful write and closes each fd once',
      () async {
        final root = await _createCanonicalTemp('secure-close-success-');
        addTearDown(() => root.delete(recursive: true));
        final closeLog = File('${root.path}/close.log');
        final target = File('${root.path}/value.txt');
        await target.writeAsString('original');

        await expectLater(
          writeSecureTextFile(
            canonicalRoot: root.path,
            relativePath: 'value.txt',
            content: 'written',
            maxWriteBytes: 16,
            testHooks: SecureFsWriteTestHooks(
              closeFailureCount: 1,
              onCloseAttempt: (descriptor) {
                closeLog.writeAsStringSync(
                  '$descriptor\n',
                  mode: FileMode.append,
                );
              },
            ),
          ),
          throwsA(
            isA<FileSystemException>()
                .having(
                  (error) => error.message,
                  'message',
                  'Secure file write failed',
                )
                .having(
                  (error) => error.toString(),
                  'public text',
                  isNot(contains('_SecureFsCloseFailure')),
                ),
          ),
        );
        expect(await target.readAsString(), 'original');
        expect(await _temporaryWriteEntries(root), isEmpty);
        final attempts = await closeLog.readAsLines();
        expect(attempts.length, greaterThan(1));
        expect(attempts.toSet().length, attempts.length);
      },
    );

    test(
      'does not let close failure replace an earlier write failure',
      () async {
        final root = await _createCanonicalTemp('secure-close-primary-');
        addTearDown(() => root.delete(recursive: true));
        final closeLog = File('${root.path}/close.log');
        final target = File('${root.path}/value.txt');
        await target.writeAsString('original');

        await expectLater(
          writeSecureTextFile(
            canonicalRoot: root.path,
            relativePath: 'value.txt',
            content: 'blocked',
            maxWriteBytes: 16,
            testHooks: SecureFsWriteTestHooks(
              forceNotRegularFile: true,
              closeFailureCount: 1,
              onCloseAttempt: (descriptor) {
                closeLog.writeAsStringSync(
                  '$descriptor\n',
                  mode: FileMode.append,
                );
              },
            ),
          ),
          throwsA(
            isA<FileSystemException>().having(
              (error) => error.message,
              'message',
              'Secure file is not a regular file',
            ),
          ),
        );
        final attempts = await closeLog.readAsLines();
        expect(attempts.length, greaterThan(1));
        expect(attempts.toSet().length, attempts.length);
        expect(await target.readAsString(), 'original');
        expect(await _temporaryWriteEntries(root), isEmpty);
      },
    );

    test(
      'reports a selected post-rename close failure without rollback',
      () async {
        final root = await _createCanonicalTemp('secure-close-after-rename-');
        addTearDown(() => root.delete(recursive: true));
        final target = File('${root.path}/value.txt');
        final closeLog = File('${root.path}/close.log');
        await target.writeAsString('original');
        var closeAttempt = 0;

        await expectLater(
          writeSecureTextFile(
            canonicalRoot: root.path,
            relativePath: 'value.txt',
            content: 'replacement',
            maxWriteBytes: 32,
            testHooks: SecureFsWriteTestHooks(
              closeFailureAtAttempt: 2,
              onCloseAttempt: (descriptor) {
                closeAttempt += 1;
                closeLog.writeAsStringSync(
                  '$closeAttempt|$descriptor|${target.readAsStringSync()}\n',
                  mode: FileMode.append,
                );
              },
            ),
          ),
          throwsA(
            isA<FileSystemException>().having(
              (error) => error.message,
              'message',
              'Secure file write failed',
            ),
          ),
        );

        expect(await target.readAsString(), 'replacement');
        expect(await _temporaryWriteEntries(root), isEmpty);
        final attempts = await closeLog.readAsLines();
        expect(attempts.length, greaterThan(2));
        expect(attempts.first, endsWith('|original'));
        expect(attempts[1], endsWith('|replacement'));
        final descriptors = attempts
            .map((entry) => entry.split('|')[1])
            .toList(growable: false);
        expect(descriptors.toSet().length, descriptors.length);
      },
    );

    test('selects the ABI-specific native type branch for this platform', () {
      expect(secureFsWriteNativeAbiIsSupportedForTesting, isTrue);
      expect(
        secureFsWriteNativeAbiForTesting,
        Platform.isMacOS
            ? SecureFsWriteNativeAbi.darwin
            : SecureFsWriteNativeAbi.linux,
      );
    });

    test('fails closed through the unsupported-platform test seam', () async {
      final root = await _createCanonicalTemp('secure-platform-');
      addTearDown(() => root.delete(recursive: true));
      await expectLater(
        writeSecureTextFile(
          canonicalRoot: root.path,
          relativePath: 'value.txt',
          content: 'x',
          maxWriteBytes: 1,
          testHooks: const SecureFsWriteTestHooks(platformSupported: false),
        ),
        throwsUnsupportedError,
      );
      expect(File('${root.path}/value.txt').existsSync(), isFalse);
    });

    test('hook phases expose the canonical target', () async {
      final root = await _createCanonicalTemp('secure-hooks-');
      addTearDown(() => root.delete(recursive: true));
      final log = File('${root.path}/events.log');

      await writeSecureTextFile(
        canonicalRoot: root.path,
        relativePath: 'nested/value.txt',
        content: 'x',
        maxWriteBytes: 8,
        testHooks: SecureFsWriteTestHooks(
          onHook: (event) {
            log.writeAsStringSync(
              '${event.phase.name}|${event.canonicalTarget}\n',
              mode: FileMode.append,
            );
          },
        ),
      );

      final events = await log.readAsLines();
      final phases = events
          .map((line) => line.substring(0, line.indexOf('|')))
          .toList();
      expect(
        phases,
        containsAll(<String>[
          SecureFsWriteHookPhase.beforeDirectoryOpen.name,
          SecureFsWriteHookPhase.afterDirectoryCreate.name,
          SecureFsWriteHookPhase.beforeFinalOpen.name,
          SecureFsWriteHookPhase.afterFinalOpen.name,
          SecureFsWriteHookPhase.beforeNativeWrite.name,
        ]),
      );
      expect(
        events.map((line) => line.substring(line.indexOf('|') + 1)),
        everyElement('${root.path}/nested/value.txt'),
      );
    });

    test(
      'rejects an intermediate directory swapped to an external symlink',
      () async {
        final root = await _createCanonicalTemp('secure-race-root-');
        final outside = await _createCanonicalTemp('secure-race-out-');
        addTearDown(() => root.delete(recursive: true));
        addTearDown(() => outside.delete(recursive: true));
        final directory = Directory('${root.path}/nested');
        await directory.create();
        var swapped = false;

        await expectLater(
          writeSecureTextFile(
            canonicalRoot: root.path,
            relativePath: 'nested/value.txt',
            content: 'blocked',
            maxWriteBytes: 16,
            testHooks: SecureFsWriteTestHooks(
              onHook: (event) {
                if (!swapped &&
                    event.phase == SecureFsWriteHookPhase.beforeDirectoryOpen &&
                    event.segment == 'nested') {
                  swapped = true;
                  directory.renameSync('${root.path}/original');
                  Link(directory.path).createSync(outside.path);
                }
              },
            ),
          ),
          throwsA(isA<FileSystemException>()),
        );
        expect(File('${outside.path}/value.txt').existsSync(), isFalse);
      },
    );

    test('rejects a newly-created directory swapped before reopen', () async {
      final root = await _createCanonicalTemp('secure-mkdir-root-');
      final outside = await _createCanonicalTemp('secure-mkdir-out-');
      addTearDown(() => root.delete(recursive: true));
      addTearDown(() => outside.delete(recursive: true));
      var swapped = false;

      await expectLater(
        writeSecureTextFile(
          canonicalRoot: root.path,
          relativePath: 'nested/value.txt',
          content: 'blocked',
          maxWriteBytes: 16,
          testHooks: SecureFsWriteTestHooks(
            onHook: (event) {
              if (!swapped &&
                  event.phase == SecureFsWriteHookPhase.afterDirectoryCreate &&
                  event.segment == 'nested') {
                swapped = true;
                Directory(
                  '${root.path}/nested',
                ).renameSync('${root.path}/original');
                Link('${root.path}/nested').createSync(outside.path);
              }
            },
          ),
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(File('${outside.path}/value.txt').existsSync(), isFalse);
    });

    test(
      'rejects a final target swapped to an external symlink before open',
      () async {
        final root = await _createCanonicalTemp('secure-final-root-');
        final outside = await _createCanonicalTemp('secure-final-out-');
        addTearDown(() => root.delete(recursive: true));
        addTearDown(() => outside.delete(recursive: true));
        final target = File('${root.path}/value.txt');
        final outsideFile = File('${outside.path}/outside.txt');
        await target.writeAsString('inside');
        await outsideFile.writeAsString('outside');
        var swapped = false;

        await expectLater(
          writeSecureTextFile(
            canonicalRoot: root.path,
            relativePath: 'value.txt',
            content: 'blocked',
            maxWriteBytes: 16,
            testHooks: SecureFsWriteTestHooks(
              onHook: (event) {
                if (!swapped &&
                    event.phase == SecureFsWriteHookPhase.beforeFinalOpen) {
                  swapped = true;
                  target.renameSync('${root.path}/original.txt');
                  Link(target.path).createSync(outsideFile.path);
                }
              },
            ),
          ),
          throwsA(isA<FileSystemException>()),
        );
        expect(await outsideFile.readAsString(), 'outside');
      },
    );

    test(
      'replaces the final name without writing the inode moved after open',
      () async {
        final root = await _createCanonicalTemp('secure-open-root-');
        final outside = await _createCanonicalTemp('secure-open-out-');
        addTearDown(() => root.delete(recursive: true));
        addTearDown(() => outside.delete(recursive: true));
        final target = File('${root.path}/value.txt');
        final outsideFile = File('${outside.path}/outside.txt');
        await target.writeAsString('inside');
        await outsideFile.writeAsString('outside');
        var swapped = false;

        await writeSecureTextFile(
          canonicalRoot: root.path,
          relativePath: 'value.txt',
          content: 'replacement',
          maxWriteBytes: 32,
          testHooks: SecureFsWriteTestHooks(
            onHook: (event) {
              if (!swapped &&
                  event.phase == SecureFsWriteHookPhase.afterFinalOpen) {
                swapped = true;
                target.renameSync('${root.path}/opened.txt');
                Link(target.path).createSync(outsideFile.path);
              }
            },
          ),
        );

        expect(await File('${root.path}/opened.txt').readAsString(), 'inside');
        expect(await target.readAsString(), 'replacement');
        expect(await outsideFile.readAsString(), 'outside');
      },
    );

    test('runs blocking native work outside the event-loop isolate', () async {
      final root = await _createCanonicalTemp('secure-isolate-');
      addTearDown(() => root.delete(recursive: true));
      var timerFired = false;
      final timer = Timer(const Duration(milliseconds: 10), () {
        timerFired = true;
      });
      addTearDown(timer.cancel);

      await writeSecureTextFile(
        canonicalRoot: root.path,
        relativePath: 'value.txt',
        content: 'x',
        maxWriteBytes: 8,
        testHooks: SecureFsWriteTestHooks(
          onHook: (event) {
            if (event.phase == SecureFsWriteHookPhase.beforeNativeWrite) {
              sleep(const Duration(milliseconds: 80));
            }
          },
        ),
      );

      expect(timerFired, isTrue);
    });
  });
}

Future<Directory> _createCanonicalTemp(String prefix) async {
  final created = await Directory.systemTemp.createTemp(prefix);
  return Directory(await created.resolveSymbolicLinks());
}

Future<List<FileSystemEntity>> _temporaryWriteEntries(Directory root) => root
    .list()
    .where(
      (entry) =>
          entry.uri.pathSegments.last.startsWith(secureFsWriteTempPrefix),
    )
    .toList();

const int _permissionModeMask = 0x1ff;

String _singleTemporaryMode(Directory root) {
  final entries = root
      .listSync()
      .where(
        (entry) =>
            entry.uri.pathSegments.last.startsWith(secureFsWriteTempPrefix),
      )
      .toList(growable: false);
  if (entries.length != 1) {
    throw StateError('Expected exactly one content temporary file.');
  }
  final mode = entries.single.statSync().mode & _permissionModeMask;
  return mode.toRadixString(8);
}
