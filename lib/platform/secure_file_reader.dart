import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

class SecureFileReadResult {
  const SecureFileReadResult({
    required this.sizeBytes,
    required this.previewBytes,
    required this.sha256,
  });

  final int sizeBytes;
  final List<int> previewBytes;
  final String sha256;
}

class SecureBoundedFileSnapshot {
  const SecureBoundedFileSnapshot({
    required this.sizeBytes,
    required this.bytes,
    required this.exceededLimit,
  });

  final int sizeBytes;
  final Uint8List bytes;
  final bool exceededLimit;
}

/// Binds an authorized workspace root and regular file to their POSIX objects.
///
/// Paths remain useful for display and traversal, but they are not authority:
/// every later read must re-open the canonical path without following symlinks
/// and compare these device/inode identities before consuming bytes.
final class SecureFileCapability {
  const SecureFileCapability({
    required this.rootDevice,
    required this.rootInode,
    required this.fileDevice,
    required this.fileInode,
  });

  final int rootDevice;
  final int rootInode;
  final int fileDevice;
  final int fileInode;
}

/// Pins a directory path to the POSIX object authorized at creation time.
///
/// Later file operations re-open every absolute path component with
/// `O_NOFOLLOW` and compare this identity before opening any child entry.
final class SecureDirectoryCapability {
  const SecureDirectoryCapability({required this.device, required this.inode});

  final int device;
  final int inode;
}

final class SecureTemporaryDirectory {
  SecureTemporaryDirectory._({
    required this.path,
    required this.capability,
    required this._directoryDescriptor,
  });

  final String path;
  final SecureDirectoryCapability capability;
  final int _directoryDescriptor;
  bool _cleanupStarted = false;

  int _takeDirectoryDescriptorForCleanup() {
    if (_cleanupStarted) return -1;
    _cleanupStarted = true;
    return _directoryDescriptor;
  }
}

final class SecureTemporaryDirectoryCleanup {
  const SecureTemporaryDirectoryCleanup({
    required this.removed,
    this.quarantine,
  });

  final bool removed;
  final SecureQuarantinedDirectory? quarantine;
  String? get quarantinePath => quarantine?.path;
}

final class SecureQuarantinedDirectory {
  SecureQuarantinedDirectory._({
    required this.path,
    required this.capability,
    required this._directoryDescriptor,
  });

  /// Null when the authorized directory was moved before quarantine. The
  /// pinned descriptor still authorizes clearing its contents without ever
  /// touching the replacement now visible at the old path.
  final String? path;
  final SecureDirectoryCapability capability;
  final int _directoryDescriptor;
  bool _cleanupStarted = false;

  int _takeDirectoryDescriptorForCleanup() {
    if (_cleanupStarted) return -1;
    _cleanupStarted = true;
    return _directoryDescriptor;
  }
}

final class SecureSpawnedProcess {
  const SecureSpawnedProcess({required this.pid});

  final int pid;
}

final class SecureProcessSpawnResult {
  const SecureProcessSpawnResult._({
    this.process,
    this.failure,
    this.deadlineExceeded = false,
  });

  const SecureProcessSpawnResult.started(SecureSpawnedProcess process)
    : this._(process: process);

  const SecureProcessSpawnResult.failed(
    String failure, {
    bool deadlineExceeded = false,
  }) : this._(failure: failure, deadlineExceeded: deadlineExceeded);

  final SecureSpawnedProcess? process;
  final String? failure;
  final bool deadlineExceeded;
}

final class SecureProcessExit {
  const SecureProcessExit({required this.exitCode, this.signal});

  final int exitCode;
  final int? signal;
}

Future<SecureProcessSpawnResult> spawnProcessWithAnonymousStdin({
  required String executable,
  required List<String> arguments,
  required TransferableTypedData inputData,
  required String resolvedTemporaryDirectoryPath,
  required DateTime deadline,
  bool testReplaceAnonymousFileBeforeUnlink = false,
  bool testForceAnonymousDescriptorNormalization = false,
}) {
  if (!Platform.isMacOS) {
    return Future<SecureProcessSpawnResult>.value(
      const SecureProcessSpawnResult.failed('unsupported platform'),
    );
  }
  return Isolate.run(() {
    final inputBytes = inputData.materialize().asUint8List();
    return _PosixSecureFileReader.spawnWithAnonymousStdin(
      executable: executable,
      arguments: arguments,
      inputBytes: inputBytes,
      resolvedTemporaryDirectoryPath: resolvedTemporaryDirectoryPath,
      deadlineMillisecondsSinceEpoch: deadline.millisecondsSinceEpoch,
      testReplaceAnonymousFileBeforeUnlink:
          testReplaceAnonymousFileBeforeUnlink,
      testForceAnonymousDescriptorNormalization:
          testForceAnonymousDescriptorNormalization,
    );
  });
}

Future<SecureProcessExit?> waitForSecureSpawnedProcess(int pid) {
  if (!Platform.isMacOS || pid <= 0) return Future<SecureProcessExit?>.value();
  return Isolate.run(() => _PosixSecureFileReader.waitForProcess(pid));
}

Future<bool> signalSecureSpawnedProcessGroup(int pid, int signal) {
  if (!Platform.isMacOS || pid <= 0 || signal <= 0) {
    return Future<bool>.value(false);
  }
  // killpg is non-blocking. Invoke it before returning the Future so a
  // deadline/cancellation path cannot leave a late isolate signal targeting a
  // subsequently reused process-group id.
  return Future<bool>.value(
    _PosixSecureFileReader.signalProcessGroup(pid, signal),
  );
}

/// Exposes the current process descriptor count only for leak regression tests.
int secureOpenDescriptorCountForTesting() =>
    _PosixSecureFileReader.openDescriptorCount();

Future<SecureTemporaryDirectory?> createSecureTemporaryDirectory({
  required String resolvedParentPath,
  String namePrefix = 'ianvs-acp-file-preview-',
}) {
  if (!Platform.isMacOS && !Platform.isLinux) {
    return Future<SecureTemporaryDirectory?>.value();
  }
  return Isolate.run(
    () => _PosixSecureFileReader.createTemporaryDirectory(
      resolvedParentPath: resolvedParentPath,
      namePrefix: namePrefix,
    ),
  );
}

Future<SecureTemporaryDirectoryCleanup?>
quarantineSecureTemporaryDirectoryForCleanup({
  required SecureTemporaryDirectory temporary,
  required String fixedOutputName,
}) {
  if (!Platform.isMacOS && !Platform.isLinux) {
    return Future<SecureTemporaryDirectoryCleanup?>.value();
  }
  final directoryDescriptor = temporary._takeDirectoryDescriptorForCleanup();
  if (directoryDescriptor < 0) {
    return Future<SecureTemporaryDirectoryCleanup?>.value();
  }
  return Isolate.run(
    () => _PosixSecureFileReader.quarantineTemporaryDirectoryForCleanup(
      resolvedDirectoryPath: temporary.path,
      expectedCapability: temporary.capability,
      pinnedDirectoryDescriptor: directoryDescriptor,
      fixedOutputName: fixedOutputName,
    ),
  );
}

Future<bool> deleteQuarantinedTemporaryDirectorySecurely({
  required SecureQuarantinedDirectory quarantine,
  int maximumEntries = 4096,
  int maximumDepth = 32,
}) {
  if ((!Platform.isMacOS && !Platform.isLinux) ||
      maximumEntries <= 0 ||
      maximumDepth <= 0) {
    return Future<bool>.value(false);
  }
  final directoryDescriptor = quarantine._takeDirectoryDescriptorForCleanup();
  if (directoryDescriptor < 0) return Future<bool>.value(false);
  return Isolate.run(
    () => _PosixSecureFileReader.deleteQuarantinedTemporaryDirectory(
      resolvedDirectoryPath: quarantine.path,
      expectedCapability: quarantine.capability,
      pinnedDirectoryDescriptor: directoryDescriptor,
      maximumEntries: maximumEntries,
      maximumDepth: maximumDepth,
    ),
  );
}

Future<SecureDirectoryCapability?> captureDirectoryCapabilitySecurely({
  required String resolvedDirectoryPath,
}) {
  if (!Platform.isMacOS && !Platform.isLinux) {
    return Future<SecureDirectoryCapability?>.value();
  }
  return Isolate.run(
    () => _PosixSecureFileReader.captureDirectoryCapability(
      resolvedDirectoryPath: resolvedDirectoryPath,
    ),
  );
}

Future<SecureFileCapability?> captureWorkspaceFileCapabilitySecurely({
  required String resolvedWorkspacePath,
  required String relativePath,
  SecureDirectoryCapability? expectedRootCapability,
  bool requireSingleLink = false,
}) {
  if (!Platform.isMacOS && !Platform.isLinux) {
    return Future<SecureFileCapability?>.value();
  }
  return Isolate.run(
    () => _PosixSecureFileReader.captureCapability(
      resolvedWorkspacePath: resolvedWorkspacePath,
      relativePath: relativePath,
      expectedRootCapability: expectedRootCapability,
      requireSingleLink: requireSingleLink,
    ),
  );
}

Future<bool> validateWorkspaceFileCapabilitySecurely({
  required String resolvedWorkspacePath,
  required String relativePath,
  required SecureFileCapability expectedCapability,
  bool requireSingleLink = false,
}) {
  if (!Platform.isMacOS && !Platform.isLinux) {
    return Future<bool>.value(false);
  }
  return Isolate.run(
    () => _PosixSecureFileReader.validateCapability(
      resolvedWorkspacePath: resolvedWorkspacePath,
      relativePath: relativePath,
      expectedCapability: expectedCapability,
      requireSingleLink: requireSingleLink,
    ),
  );
}

Future<SecureBoundedFileSnapshot?> readWorkspaceFileSnapshotSecurely({
  required String resolvedWorkspacePath,
  required String relativePath,
  required int maximumBytes,
  required SecureFileCapability expectedCapability,
  bool requireSingleLink = false,
  bool testGrowFileAfterInitialStat = false,
}) {
  if ((!Platform.isMacOS && !Platform.isLinux) || maximumBytes < 0) {
    return Future<SecureBoundedFileSnapshot?>.value();
  }
  return Isolate.run(
    () => _PosixSecureFileReader.readBounded(
      resolvedWorkspacePath: resolvedWorkspacePath,
      relativePath: relativePath,
      maximumBytes: maximumBytes,
      expectedCapability: expectedCapability,
      requireSingleLink: requireSingleLink,
      testGrowFileAfterInitialStat: testGrowFileAfterInitialStat,
    ),
  );
}

Future<bool> writePrivateFileExclusiveSecurely({
  required String resolvedDirectoryPath,
  required String fileName,
  required Uint8List bytes,
}) {
  if (!Platform.isMacOS && !Platform.isLinux) return Future<bool>.value(false);
  return Isolate.run(
    () => _PosixSecureFileReader.writePrivateFileExclusive(
      resolvedDirectoryPath: resolvedDirectoryPath,
      fileName: fileName,
      bytes: bytes,
    ),
  );
}

/// Opens every path component relative to an already resolved workspace root.
///
/// POSIX `openat` plus `O_NOFOLLOW` binds validation and reading to directory
/// and file descriptors, so a concurrent symlink replacement cannot redirect
/// the read outside the workspace.
Future<SecureFileReadResult?> readWorkspaceFileSecurely({
  required String resolvedWorkspacePath,
  required String relativePath,
  required int previewLimit,
  int? maximumBytes,
  SecureFileCapability? expectedCapability,
  bool requireSingleLink = false,
}) {
  if ((!Platform.isMacOS && !Platform.isLinux) ||
      previewLimit < 0 ||
      (maximumBytes != null && maximumBytes < 0)) {
    return Future<SecureFileReadResult?>.value();
  }
  return Isolate.run(
    () => _PosixSecureFileReader.read(
      resolvedWorkspacePath: resolvedWorkspacePath,
      relativePath: relativePath,
      previewLimit: previewLimit,
      maximumBytes: maximumBytes,
      expectedCapability: expectedCapability,
      requireSingleLink: requireSingleLink,
    ),
  );
}

class _PosixSecureFileReader {
  static final DynamicLibrary _libc = DynamicLibrary.process();

  static final int Function(Pointer<Char>, int) _open = _libc
      .lookupFunction<
        Int32 Function(Pointer<Char>, Int32),
        int Function(Pointer<Char>, int)
      >('open');
  static final int Function(int, Pointer<Char>, int) _openAt = _libc
      .lookupFunction<
        Int32 Function(Int32, Pointer<Char>, Int32),
        int Function(int, Pointer<Char>, int)
      >('openat');
  static final int Function(int, Pointer<Char>, int, int) _openAtMode = _libc
      .lookupFunction<
        Int32 Function(Int32, Pointer<Char>, Int32, VarArgs<(Int32,)>),
        int Function(int, Pointer<Char>, int, int)
      >('openat');
  static final int Function(int, Pointer<Char>, int) _mkdirAt = _libc
      .lookupFunction<
        Int32 Function(Int32, Pointer<Char>, Uint32),
        int Function(int, Pointer<Char>, int)
      >('mkdirat');
  static final int Function(int, Pointer<Char>, int, Pointer<Char>, int)
  _renameAtExclusive = Platform.isMacOS
      ? _libc.lookupFunction<
          Int32 Function(Int32, Pointer<Char>, Int32, Pointer<Char>, Uint32),
          int Function(int, Pointer<Char>, int, Pointer<Char>, int)
        >('renameatx_np')
      : _libc.lookupFunction<
          Int32 Function(Int32, Pointer<Char>, Int32, Pointer<Char>, Uint32),
          int Function(int, Pointer<Char>, int, Pointer<Char>, int)
        >('renameat2');
  static final int Function(int, Pointer<Char>, int) _unlinkAt = _libc
      .lookupFunction<
        Int32 Function(Int32, Pointer<Char>, Int32),
        int Function(int, Pointer<Char>, int)
      >('unlinkat');
  static final int Function(int, Pointer<Char>, int, int) _changeModeAt = _libc
      .lookupFunction<
        Int32 Function(Int32, Pointer<Char>, Uint32, Int32),
        int Function(int, Pointer<Char>, int, int)
      >('fchmodat');
  static final int Function(int, int, int) _fileControl = _libc
      .lookupFunction<
        Int32 Function(Int32, Int32, VarArgs<(Int32,)>),
        int Function(int, int, int)
      >('fcntl');
  static final int Function() _getDescriptorTableSize = _libc
      .lookupFunction<Int32 Function(), int Function()>('getdtablesize');
  static final Pointer<Void> Function(int) _fdOpenDirectory = _libc
      .lookupFunction<
        Pointer<Void> Function(Int32),
        Pointer<Void> Function(int)
      >('fdopendir');
  static final Pointer<Void> Function(Pointer<Void>) _readDirectoryEntry = _libc
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>),
        Pointer<Void> Function(Pointer<Void>)
      >('readdir');
  static final int Function(Pointer<Void>) _closeDirectory = _libc
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('closedir');
  static final int Function() _getUserId = _libc
      .lookupFunction<Uint32 Function(), int Function()>('getuid');
  static final Pointer<Int32> Function() _errnoLocation = Platform.isMacOS
      ? _libc.lookupFunction<
          Pointer<Int32> Function(),
          Pointer<Int32> Function()
        >('__error')
      : _libc.lookupFunction<
          Pointer<Int32> Function(),
          Pointer<Int32> Function()
        >('__errno_location');
  static final int Function(int, int) _truncateFile = _libc
      .lookupFunction<Int32 Function(Int32, Int64), int Function(int, int)>(
        'ftruncate',
      );
  static final int Function(int, int, int) _seekFile = _libc
      .lookupFunction<
        Int64 Function(Int32, Int64, Int32),
        int Function(int, int, int)
      >('lseek');
  static final int Function(Pointer<Void>) _spawnFileActionsInit = _libc
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('posix_spawn_file_actions_init');
  static final int Function(Pointer<Void>) _spawnFileActionsDestroy = _libc
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('posix_spawn_file_actions_destroy');
  static final int Function(Pointer<Void>, int, int) _spawnFileActionsAddDup2 =
      _libc.lookupFunction<
        Int32 Function(Pointer<Void>, Int32, Int32),
        int Function(Pointer<Void>, int, int)
      >('posix_spawn_file_actions_adddup2');
  static final int Function(Pointer<Void>, int, Pointer<Char>, int, int)
  _spawnFileActionsAddOpen = _libc
      .lookupFunction<
        Int32 Function(Pointer<Void>, Int32, Pointer<Char>, Int32, Uint32),
        int Function(Pointer<Void>, int, Pointer<Char>, int, int)
      >('posix_spawn_file_actions_addopen');
  static final int Function(Pointer<Void>) _spawnAttributesInit = _libc
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('posix_spawnattr_init');
  static final int Function(Pointer<Void>) _spawnAttributesDestroy = _libc
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('posix_spawnattr_destroy');
  static final int Function(Pointer<Void>, int) _spawnAttributesSetFlags = _libc
      .lookupFunction<
        Int32 Function(Pointer<Void>, Int16),
        int Function(Pointer<Void>, int)
      >('posix_spawnattr_setflags');
  static final int Function(Pointer<Void>, int)
  _spawnAttributesSetProcessGroup = _libc
      .lookupFunction<
        Int32 Function(Pointer<Void>, Int32),
        int Function(Pointer<Void>, int)
      >('posix_spawnattr_setpgroup');
  static final int Function(
    Pointer<Int32>,
    Pointer<Char>,
    Pointer<Void>,
    Pointer<Void>,
    Pointer<Pointer<Char>>,
    Pointer<Pointer<Char>>,
  )
  _spawnProcess = _libc
      .lookupFunction<
        Int32 Function(
          Pointer<Int32>,
          Pointer<Char>,
          Pointer<Void>,
          Pointer<Void>,
          Pointer<Pointer<Char>>,
          Pointer<Pointer<Char>>,
        ),
        int Function(
          Pointer<Int32>,
          Pointer<Char>,
          Pointer<Void>,
          Pointer<Void>,
          Pointer<Pointer<Char>>,
          Pointer<Pointer<Char>>,
        )
      >('posix_spawn');
  static final int Function(int, Pointer<Int32>, int) _waitForProcess = _libc
      .lookupFunction<
        Int32 Function(Int32, Pointer<Int32>, Int32),
        int Function(int, Pointer<Int32>, int)
      >('waitpid');
  static final int Function(int, int) _killProcessGroup = _libc
      .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
        'killpg',
      );
  static final int Function(int, Pointer<Void>, int) _read = _libc
      .lookupFunction<
        IntPtr Function(Int32, Pointer<Void>, IntPtr),
        int Function(int, Pointer<Void>, int)
      >('read');
  static final int Function(int, Pointer<Void>, int) _write = _libc
      .lookupFunction<
        IntPtr Function(Int32, Pointer<Void>, IntPtr),
        int Function(int, Pointer<Void>, int)
      >('write');
  static final int Function(int) _fsync = _libc
      .lookupFunction<Int32 Function(Int32), int Function(int)>('fsync');
  static final int Function(int, Pointer<Void>) _fstat = _libc
      .lookupFunction<
        Int32 Function(Int32, Pointer<Void>),
        int Function(int, Pointer<Void>)
      >('fstat');
  static final int Function(int) _close = _libc
      .lookupFunction<Int32 Function(Int32), int Function(int)>('close');
  static final Pointer<Void> Function(int) _malloc = _libc
      .lookupFunction<
        Pointer<Void> Function(IntPtr),
        Pointer<Void> Function(int)
      >('malloc');
  static final void Function(Pointer<Void>) _free = _libc
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('free');

  static const int _chunkSize = 64 * 1024;

  static SecureProcessSpawnResult spawnWithAnonymousStdin({
    required String executable,
    required List<String> arguments,
    required Uint8List inputBytes,
    required String resolvedTemporaryDirectoryPath,
    required int deadlineMillisecondsSinceEpoch,
    required bool testReplaceAnonymousFileBeforeUnlink,
    required bool testForceAnonymousDescriptorNormalization,
  }) {
    if (!Platform.isMacOS ||
        !File(executable).isAbsolute ||
        executable.contains('\u0000') ||
        arguments.any((argument) => argument.contains('\u0000'))) {
      return const SecureProcessSpawnResult.failed('invalid spawn request');
    }
    var inputDescriptor = -1;
    Pointer<Void>? writeBuffer;
    Pointer<Void>? actionsStorage;
    Pointer<Void>? attributesStorage;
    Pointer<Int32>? pidStorage;
    Pointer<Pointer<Char>>? argvStorage;
    Pointer<Pointer<Char>>? environmentStorage;
    final argvStrings = <Pointer<Void>>[];
    final environmentStrings = <Pointer<Void>>[];
    var actionsInitialized = false;
    var attributesInitialized = false;
    try {
      if (DateTime.now().millisecondsSinceEpoch >=
          deadlineMillisecondsSinceEpoch) {
        return const SecureProcessSpawnResult.failed(
          'anonymous stdin spawn exceeded deadline',
          deadlineExceeded: true,
        );
      }
      inputDescriptor = _createAnonymousRegularFile(
        resolvedDirectoryPath: resolvedTemporaryDirectoryPath,
        testReplaceBeforeUnlink: testReplaceAnonymousFileBeforeUnlink,
        testForceDescriptorNormalization:
            testForceAnonymousDescriptorNormalization,
      );
      if (inputDescriptor < 0 ||
          _truncateFile(inputDescriptor, inputBytes.length) != 0) {
        return SecureProcessSpawnResult.failed(
          'anonymous file create/ftruncate failed '
          '(errno ${_errnoLocation().value})',
        );
      }
      writeBuffer = _malloc(_chunkSize);
      if (writeBuffer.address == 0) {
        return const SecureProcessSpawnResult.failed(
          'write buffer allocation failed',
        );
      }
      final writeView = writeBuffer.cast<Uint8>().asTypedList(_chunkSize);
      var offset = 0;
      while (offset < inputBytes.length) {
        if (DateTime.now().millisecondsSinceEpoch >=
            deadlineMillisecondsSinceEpoch) {
          return const SecureProcessSpawnResult.failed(
            'anonymous stdin write exceeded deadline',
            deadlineExceeded: true,
          );
        }
        final count = inputBytes.length - offset < _chunkSize
            ? inputBytes.length - offset
            : _chunkSize;
        writeView.setRange(0, count, inputBytes, offset);
        var written = 0;
        while (written < count) {
          final result = _write(
            inputDescriptor,
            (writeBuffer.cast<Uint8>() + written).cast<Void>(),
            count - written,
          );
          if (result <= 0) {
            return SecureProcessSpawnResult.failed(
              'anonymous stdin write failed (errno ${_errnoLocation().value})',
            );
          }
          written += result;
        }
        offset += count;
      }
      if (_seekFile(inputDescriptor, 0, 0) != 0 ||
          DateTime.now().millisecondsSinceEpoch >=
              deadlineMillisecondsSinceEpoch) {
        return SecureProcessSpawnResult.failed(
          'anonymous stdin seek/deadline failed (errno ${_errnoLocation().value})',
          deadlineExceeded:
              DateTime.now().millisecondsSinceEpoch >=
              deadlineMillisecondsSinceEpoch,
        );
      }

      actionsStorage = _malloc(sizeOf<Pointer<Void>>());
      attributesStorage = _malloc(sizeOf<Pointer<Void>>());
      pidStorage = _malloc(sizeOf<Int32>()).cast<Int32>();
      if (actionsStorage.address == 0 ||
          attributesStorage.address == 0 ||
          pidStorage.address == 0) {
        return const SecureProcessSpawnResult.failed('spawn allocation failed');
      }
      actionsStorage
          .cast<Uint8>()
          .asTypedList(sizeOf<Pointer<Void>>())
          .fillRange(0, sizeOf<Pointer<Void>>(), 0);
      attributesStorage
          .cast<Uint8>()
          .asTypedList(sizeOf<Pointer<Void>>())
          .fillRange(0, sizeOf<Pointer<Void>>(), 0);
      final actionsInit = _spawnFileActionsInit(actionsStorage);
      if (actionsInit != 0) {
        return SecureProcessSpawnResult.failed(
          'file actions init failed ($actionsInit)',
        );
      }
      actionsInitialized = true;
      if (_spawnFileActionsAddDup2(actionsStorage, inputDescriptor, 0) != 0) {
        return const SecureProcessSpawnResult.failed(
          'stdin dup2 action failed',
        );
      }
      final initializedActions = actionsStorage;
      final nullRedirects = _withNativePath(
        '/dev/null',
        (path) =>
            _spawnFileActionsAddOpen(
                  initializedActions,
                  1,
                  path,
                  _writeOnly,
                  0,
                ) ==
                0 &&
            _spawnFileActionsAddOpen(
                  initializedActions,
                  2,
                  path,
                  _writeOnly,
                  0,
                ) ==
                0,
      );
      if (!nullRedirects) {
        return const SecureProcessSpawnResult.failed(
          'stdio null redirect failed',
        );
      }
      final attributesInit = _spawnAttributesInit(attributesStorage);
      if (attributesInit != 0) {
        return SecureProcessSpawnResult.failed(
          'spawn attributes init failed ($attributesInit)',
        );
      }
      attributesInitialized = true;
      if (_spawnAttributesSetProcessGroup(attributesStorage, 0) != 0 ||
          _spawnAttributesSetFlags(attributesStorage, 0x4002) != 0) {
        return const SecureProcessSpawnResult.failed(
          'spawn process-group attributes failed',
        );
      }

      final argv = <String>[executable, ...arguments];
      argvStorage = _malloc(
        (argv.length + 1) * sizeOf<Pointer<Char>>(),
      ).cast<Pointer<Char>>();
      if (argvStorage.address == 0) {
        return const SecureProcessSpawnResult.failed('argv allocation failed');
      }
      for (var index = 0; index < argv.length; index += 1) {
        final native = _allocateNativeString(argv[index]);
        argvStrings.add(native.cast<Void>());
        argvStorage[index] = native;
      }
      argvStorage[argv.length] = nullptr;
      const environment = <String>[
        'PATH=/usr/bin:/bin:/usr/sbin:/sbin',
        'LANG=en_US.UTF-8',
        'LC_ALL=en_US.UTF-8',
      ];
      environmentStorage = _malloc(
        (environment.length + 1) * sizeOf<Pointer<Char>>(),
      ).cast<Pointer<Char>>();
      if (environmentStorage.address == 0) {
        return const SecureProcessSpawnResult.failed(
          'environment allocation failed',
        );
      }
      for (var index = 0; index < environment.length; index += 1) {
        final native = _allocateNativeString(environment[index]);
        environmentStrings.add(native.cast<Void>());
        environmentStorage[index] = native;
      }
      environmentStorage[environment.length] = nullptr;
      final spawnResult = _withNativePath(
        executable,
        (path) => _spawnProcess(
          pidStorage!,
          path,
          actionsStorage!,
          attributesStorage!,
          argvStorage!,
          environmentStorage!,
        ),
      );
      if (spawnResult != 0 || pidStorage.value <= 0) {
        return SecureProcessSpawnResult.failed(
          'posix_spawn failed ($spawnResult)',
        );
      }
      return SecureProcessSpawnResult.started(
        SecureSpawnedProcess(pid: pidStorage.value),
      );
    } on Object catch (error) {
      return SecureProcessSpawnResult.failed('spawn exception: $error');
    } finally {
      if (attributesInitialized && attributesStorage != null) {
        _spawnAttributesDestroy(attributesStorage);
      }
      if (actionsInitialized && actionsStorage != null) {
        _spawnFileActionsDestroy(actionsStorage);
      }
      for (final string in argvStrings) {
        _free(string);
      }
      for (final string in environmentStrings) {
        _free(string);
      }
      if (argvStorage != null && argvStorage.address != 0) {
        _free(argvStorage.cast<Void>());
      }
      if (pidStorage != null && pidStorage.address != 0) {
        _free(pidStorage.cast<Void>());
      }
      if (environmentStorage != null && environmentStorage.address != 0) {
        _free(environmentStorage.cast<Void>());
      }
      if (attributesStorage != null && attributesStorage.address != 0) {
        _free(attributesStorage);
      }
      if (actionsStorage != null && actionsStorage.address != 0) {
        _free(actionsStorage);
      }
      if (writeBuffer != null && writeBuffer.address != 0) _free(writeBuffer);
      if (inputDescriptor >= 0) _close(inputDescriptor);
    }
  }

  static SecureProcessExit? waitForProcess(int pid) {
    final status = _malloc(sizeOf<Int32>()).cast<Int32>();
    if (status.address == 0) return null;
    try {
      int waited;
      do {
        waited = _waitForProcess(pid, status, 0);
      } while (waited < 0 && _errnoLocation().value == 4);
      if (waited != pid) return null;
      final raw = status.value;
      final signal = raw & 0x7f;
      if (signal == 0) {
        return SecureProcessExit(exitCode: (raw >> 8) & 0xff);
      }
      return SecureProcessExit(exitCode: 128 + signal, signal: signal);
    } finally {
      _free(status.cast<Void>());
    }
  }

  static bool signalProcessGroup(int pid, int signal) =>
      _killProcessGroup(pid, signal) == 0;

  static int openDescriptorCount() {
    var count = 0;
    final maximum = _getDescriptorTableSize();
    for (var descriptor = 0; descriptor < maximum; descriptor += 1) {
      if (_fileControl(descriptor, 1, 0) >= 0) count += 1;
    }
    return count;
  }

  static bool writePrivateFileExclusive({
    required String resolvedDirectoryPath,
    required String fileName,
    required Uint8List bytes,
  }) {
    if (fileName.isEmpty ||
        fileName.contains('\u0000') ||
        fileName == '.' ||
        fileName == '..' ||
        fileName.contains(Platform.pathSeparator)) {
      return false;
    }
    final directoryFlags = _readOnly | _directory | _noFollow | _closeOnExec;
    final fileFlags =
        _writeOnly | _create | _exclusive | _noFollow | _closeOnExec;
    final directoryDescriptors = <int>[];
    var directory = -1;
    var fileDescriptor = -1;
    Pointer<Void>? buffer;
    try {
      final segments = resolvedDirectoryPath
          .split(Platform.pathSeparator)
          .where((segment) => segment.isNotEmpty)
          .toList(growable: false);
      if (!File(resolvedDirectoryPath).isAbsolute ||
          resolvedDirectoryPath.contains('\u0000') ||
          segments.any((segment) => segment == '.' || segment == '..')) {
        return false;
      }
      directory = _withNativePath(
        Platform.pathSeparator,
        (path) => _open(path, directoryFlags),
      );
      if (directory < 0) return false;
      directoryDescriptors.add(directory);
      for (final segment in segments) {
        final next = _withNativePath(
          segment,
          (path) => _openAt(directory, path, directoryFlags),
        );
        if (next < 0) return false;
        directoryDescriptors.add(next);
        directory = next;
      }
      fileDescriptor = _withNativePath(
        fileName,
        (path) => _openAtMode(directory, path, fileFlags, 0x180),
      );
      if (fileDescriptor < 0 || !_isRegularFile(fileDescriptor)) return false;
      buffer = _malloc(_chunkSize);
      if (buffer.address == 0) return false;
      final view = buffer.cast<Uint8>().asTypedList(_chunkSize);
      var offset = 0;
      while (offset < bytes.length) {
        final count = bytes.length - offset < _chunkSize
            ? bytes.length - offset
            : _chunkSize;
        view.setRange(0, count, bytes, offset);
        var written = 0;
        while (written < count) {
          final result = _write(
            fileDescriptor,
            (buffer.cast<Uint8>() + written).cast<Void>(),
            count - written,
          );
          if (result <= 0) return false;
          written += result;
        }
        offset += count;
      }
      return _fsync(fileDescriptor) == 0;
    } on Object {
      return false;
    } finally {
      if (buffer != null && buffer.address != 0) _free(buffer);
      if (fileDescriptor >= 0) _close(fileDescriptor);
      for (final descriptor in directoryDescriptors.reversed) {
        _close(descriptor);
      }
    }
  }

  static SecureTemporaryDirectory? createTemporaryDirectory({
    required String resolvedParentPath,
    required String namePrefix,
  }) {
    if (!_isSafeSinglePathComponent(namePrefix, allowEmpty: true) ||
        namePrefix.length > 80) {
      return null;
    }
    return _withSecureDirectoryDescriptor(
      resolvedDirectoryPath: resolvedParentPath,
      action: (parentDescriptor, _) {
        final random = Random.secure();
        final candidateName = '$namePrefix${_randomHex128(random)}';
        final boundName = '$namePrefix${_randomHex128(random)}';
        var candidateCreated = false;
        var boundCreated = false;
        var keepBound = false;
        var candidateDescriptor = -1;
        var boundDescriptor = -1;
        try {
          final made = _withNativePath(
            candidateName,
            (name) => _mkdirAt(parentDescriptor, name, 0x1c0),
          );
          if (made != 0) return null;
          candidateCreated = true;
          candidateDescriptor = _withNativePath(
            candidateName,
            (name) => _openAt(parentDescriptor, name, _directoryOpenFlags),
          );
          if (candidateDescriptor < 0 ||
              !_isPrivateOwnedEmptyDirectory(candidateDescriptor)) {
            return null;
          }
          final candidateIdentity = _fileIdentity(candidateDescriptor);
          if (candidateIdentity == null) return null;
          final renamed = _withTwoNativePaths(
            candidateName,
            boundName,
            (oldName, newName) => _renameAtExclusive(
              parentDescriptor,
              oldName,
              parentDescriptor,
              newName,
              Platform.isMacOS ? 0x14 : 0x1,
            ),
          );
          if (renamed != 0) return null;
          candidateCreated = false;
          boundCreated = true;
          boundDescriptor = _withNativePath(
            boundName,
            (name) => _openAt(parentDescriptor, name, _directoryOpenFlags),
          );
          if (boundDescriptor < 0 ||
              !_isPrivateOwnedEmptyDirectory(boundDescriptor)) {
            return null;
          }
          final boundIdentity = _fileIdentity(boundDescriptor);
          if (boundIdentity == null ||
              boundIdentity.device != candidateIdentity.device ||
              boundIdentity.inode != candidateIdentity.inode) {
            return null;
          }
          keepBound = true;
          final retainedDescriptor = boundDescriptor;
          boundDescriptor = -1;
          return SecureTemporaryDirectory._(
            path: p.join(resolvedParentPath, boundName),
            capability: SecureDirectoryCapability(
              device: boundIdentity.device,
              inode: boundIdentity.inode,
            ),
            directoryDescriptor: retainedDescriptor,
          );
        } on Object {
          return null;
        } finally {
          if (boundDescriptor >= 0) _close(boundDescriptor);
          if (candidateDescriptor >= 0) _close(candidateDescriptor);
          if (candidateCreated) {
            _withNativePath(
              candidateName,
              (name) => _unlinkAt(parentDescriptor, name, _removeDirectory),
            );
          }
          if (boundCreated && !keepBound) {
            _withNativePath(
              boundName,
              (name) => _unlinkAt(parentDescriptor, name, _removeDirectory),
            );
          }
        }
      },
    );
  }

  static SecureTemporaryDirectoryCleanup?
  quarantineTemporaryDirectoryForCleanup({
    required String resolvedDirectoryPath,
    required SecureDirectoryCapability expectedCapability,
    required int pinnedDirectoryDescriptor,
    required String fixedOutputName,
  }) {
    var retainPinnedDescriptor = false;
    try {
      if (!_isSafeSinglePathComponent(fixedOutputName)) return null;
      final parentPath = p.dirname(resolvedDirectoryPath);
      final directoryName = p.basename(resolvedDirectoryPath);
      if (!_isSafeSinglePathComponent(directoryName)) return null;
      final pinnedIdentity = _fileIdentity(pinnedDirectoryDescriptor);
      if (pinnedIdentity == null ||
          !_matchesDirectoryIdentity(expectedCapability, pinnedIdentity)) {
        return null;
      }
      String? quarantinePath;
      var removed = false;
      final bound = _withSecureDirectoryDescriptor<bool>(
        resolvedDirectoryPath: parentPath,
        action: (parentDescriptor, _) {
          var directoryDescriptor = -1;
          var quarantineDescriptor = -1;
          try {
            directoryDescriptor = _withNativePath(
              directoryName,
              (name) => _openAt(parentDescriptor, name, _directoryOpenFlags),
            );
            if (directoryDescriptor < 0) return false;
            final identity = _fileIdentity(directoryDescriptor);
            if (identity == null ||
                !_matchesDirectoryIdentity(expectedCapability, identity)) {
              return false;
            }
            String? quarantineName;
            final random = Random.secure();
            for (var attempt = 0; attempt < 16; attempt += 1) {
              final candidate =
                  '.ianvs-acp-quarantine-${_randomHex128(random)}';
              final renamed = _withTwoNativePaths(
                directoryName,
                candidate,
                (oldName, newName) => _renameAtExclusive(
                  parentDescriptor,
                  oldName,
                  parentDescriptor,
                  newName,
                  Platform.isMacOS ? 0x14 : 0x1,
                ),
              );
              if (renamed == 0) {
                quarantineName = candidate;
                break;
              }
              if (_errnoLocation().value != 17) return false;
            }
            if (quarantineName == null) return false;
            quarantineDescriptor = _withNativePath(
              quarantineName,
              (name) => _openAt(parentDescriptor, name, _directoryOpenFlags),
            );
            if (quarantineDescriptor < 0) return false;
            final quarantineIdentity = _fileIdentity(quarantineDescriptor);
            if (quarantineIdentity == null ||
                !_matchesDirectoryIdentity(
                  expectedCapability,
                  quarantineIdentity,
                )) {
              return false;
            }
            quarantinePath = p.join(parentPath, quarantineName);
            if (_directoryIsEmpty(pinnedDirectoryDescriptor)) {
              final removeResult = _withNativePath(
                quarantineName,
                (name) => _unlinkAt(parentDescriptor, name, _removeDirectory),
              );
              if (removeResult == 0) removed = true;
            }
            return true;
          } finally {
            if (quarantineDescriptor >= 0) _close(quarantineDescriptor);
            if (directoryDescriptor >= 0) _close(directoryDescriptor);
          }
        },
      );
      if (removed) {
        return const SecureTemporaryDirectoryCleanup(removed: true);
      }
      retainPinnedDescriptor = true;
      return SecureTemporaryDirectoryCleanup(
        removed: false,
        quarantine: SecureQuarantinedDirectory._(
          path: bound == true ? quarantinePath : null,
          capability: expectedCapability,
          directoryDescriptor: pinnedDirectoryDescriptor,
        ),
      );
    } on Object {
      return null;
    } finally {
      if (!retainPinnedDescriptor) _close(pinnedDirectoryDescriptor);
    }
  }

  static bool deleteQuarantinedTemporaryDirectory({
    required String? resolvedDirectoryPath,
    required SecureDirectoryCapability expectedCapability,
    required int pinnedDirectoryDescriptor,
    required int maximumEntries,
    required int maximumDepth,
  }) {
    try {
      final pinnedIdentity = _fileIdentity(pinnedDirectoryDescriptor);
      if (pinnedIdentity == null ||
          !_matchesDirectoryIdentity(expectedCapability, pinnedIdentity)) {
        return false;
      }
      final budget = _SecureDirectoryRemovalBudget(maximumEntries);
      if (!_clearDirectoryContentsSecurely(
        pinnedDirectoryDescriptor,
        budget: budget,
        remainingDepth: maximumDepth,
      )) {
        return false;
      }
      if (resolvedDirectoryPath == null) return true;
      final parentPath = p.dirname(resolvedDirectoryPath);
      final directoryName = p.basename(resolvedDirectoryPath);
      if (!_isSafeSinglePathComponent(directoryName)) return false;
      return _withSecureDirectoryDescriptor<bool>(
            resolvedDirectoryPath: parentPath,
            action: (parentDescriptor, _) {
              var observedDescriptor = -1;
              try {
                observedDescriptor = _withNativePath(
                  directoryName,
                  (name) =>
                      _openAt(parentDescriptor, name, _directoryOpenFlags),
                );
                if (observedDescriptor < 0) return false;
                final observedIdentity = _fileIdentity(observedDescriptor);
                if (observedIdentity == null ||
                    !_matchesDirectoryIdentity(
                      expectedCapability,
                      observedIdentity,
                    ) ||
                    !_directoryIsEmpty(observedDescriptor)) {
                  return false;
                }
                _close(observedDescriptor);
                observedDescriptor = -1;
                return _withNativePath(
                      directoryName,
                      (name) =>
                          _unlinkAt(parentDescriptor, name, _removeDirectory),
                    ) ==
                    0;
              } finally {
                if (observedDescriptor >= 0) _close(observedDescriptor);
              }
            },
          ) ??
          false;
    } on Object {
      return false;
    } finally {
      _close(pinnedDirectoryDescriptor);
    }
  }

  static SecureDirectoryCapability? captureDirectoryCapability({
    required String resolvedDirectoryPath,
  }) {
    return _withSecureDirectoryDescriptor(
      resolvedDirectoryPath: resolvedDirectoryPath,
      action: (_, identity) => SecureDirectoryCapability(
        device: identity.device,
        inode: identity.inode,
      ),
    );
  }

  static SecureFileCapability? captureCapability({
    required String resolvedWorkspacePath,
    required String relativePath,
    SecureDirectoryCapability? expectedRootCapability,
    bool requireSingleLink = false,
  }) {
    return _withSecureFileDescriptor(
      resolvedWorkspacePath: resolvedWorkspacePath,
      relativePath: relativePath,
      expectedRootCapability: expectedRootCapability,
      requireSingleLink: requireSingleLink,
      action: (fileDescriptor, rootIdentity, fileIdentity) =>
          SecureFileCapability(
            rootDevice: rootIdentity.device,
            rootInode: rootIdentity.inode,
            fileDevice: fileIdentity.device,
            fileInode: fileIdentity.inode,
          ),
    );
  }

  static bool validateCapability({
    required String resolvedWorkspacePath,
    required String relativePath,
    required SecureFileCapability expectedCapability,
    bool requireSingleLink = false,
  }) {
    return _withSecureFileDescriptor(
          resolvedWorkspacePath: resolvedWorkspacePath,
          relativePath: relativePath,
          expectedCapability: expectedCapability,
          requireSingleLink: requireSingleLink,
          action: (_, _, _) => true,
        ) ??
        false;
  }

  static SecureBoundedFileSnapshot? readBounded({
    required String resolvedWorkspacePath,
    required String relativePath,
    required int maximumBytes,
    required SecureFileCapability expectedCapability,
    bool requireSingleLink = false,
    bool testGrowFileAfterInitialStat = false,
  }) {
    return _withSecureFileDescriptor(
      resolvedWorkspacePath: resolvedWorkspacePath,
      relativePath: relativePath,
      expectedCapability: expectedCapability,
      requireSingleLink: requireSingleLink,
      action: (fileDescriptor, _, _) {
        final initialSizeBytes = _regularFileSize(fileDescriptor);
        if (initialSizeBytes == null) return null;
        if (testGrowFileAfterInitialStat) {
          File(p.join(resolvedWorkspacePath, relativePath)).writeAsBytesSync(
            const <int>[0xa5],
            mode: FileMode.append,
            flush: true,
          );
        }
        Pointer<Void>? buffer;
        try {
          buffer = _malloc(_chunkSize);
          if (buffer.address == 0) return null;
          final view = buffer.cast<Uint8>().asTypedList(_chunkSize);
          final bytes = BytesBuilder(copy: false);
          while (bytes.length <= maximumBytes) {
            final remaining = maximumBytes + 1 - bytes.length;
            final count = _read(
              fileDescriptor,
              buffer,
              remaining < _chunkSize ? remaining : _chunkSize,
            );
            if (count < 0) return null;
            if (count == 0) break;
            // The native read buffer is reused, so each retained chunk must
            // own its bytes until takeBytes() combines them.
            bytes.add(
              Uint8List.fromList(Uint8List.sublistView(view, 0, count)),
            );
            if (bytes.length > maximumBytes) break;
          }
          final snapshot = bytes.takeBytes();
          final finalSizeBytes = _regularFileSize(fileDescriptor);
          if (finalSizeBytes == null || finalSizeBytes != initialSizeBytes) {
            return null;
          }
          final exceeded = finalSizeBytes > maximumBytes;
          final expectedReadBytes = exceeded
              ? maximumBytes + 1
              : finalSizeBytes;
          if (snapshot.length != expectedReadBytes) return null;
          return SecureBoundedFileSnapshot(
            sizeBytes: exceeded ? finalSizeBytes : snapshot.length,
            bytes: exceeded
                ? Uint8List.sublistView(snapshot, 0, maximumBytes)
                : snapshot,
            exceededLimit: exceeded,
          );
        } finally {
          if (buffer != null && buffer.address != 0) _free(buffer);
        }
      },
    );
  }

  static SecureFileReadResult? read({
    required String resolvedWorkspacePath,
    required String relativePath,
    required int previewLimit,
    int? maximumBytes,
    SecureFileCapability? expectedCapability,
    bool requireSingleLink = false,
  }) {
    return _withSecureFileDescriptor(
      resolvedWorkspacePath: resolvedWorkspacePath,
      relativePath: relativePath,
      expectedCapability: expectedCapability,
      requireSingleLink: requireSingleLink,
      action: (fileDescriptor, _, _) {
        final initialSize = _regularFileSize(fileDescriptor);
        if (initialSize == null ||
            (maximumBytes != null && initialSize > maximumBytes)) {
          return null;
        }
        Pointer<Void>? buffer;
        try {
          buffer = _malloc(_chunkSize);
          if (buffer.address == 0) return null;
          final bytes = buffer.cast<Uint8>().asTypedList(_chunkSize);
          final preview = BytesBuilder(copy: false);
          final digestSink = _DigestSink();
          final hashSink = sha256.startChunkedConversion(digestSink);
          var sizeBytes = 0;
          while (true) {
            final count = _read(fileDescriptor, buffer, _chunkSize);
            if (count < 0) return null;
            if (count == 0) break;
            sizeBytes += count;
            if (maximumBytes != null && sizeBytes > maximumBytes) return null;
            final chunk = Uint8List.sublistView(bytes, 0, count);
            hashSink.add(chunk);
            final remaining = previewLimit - preview.length;
            if (remaining > 0) {
              preview.add(
                chunk.sublist(0, count < remaining ? count : remaining),
              );
            }
          }
          hashSink.close();
          final digest = digestSink.value;
          if (digest == null) return null;
          return SecureFileReadResult(
            sizeBytes: sizeBytes,
            previewBytes: List<int>.unmodifiable(preview.takeBytes()),
            sha256: digest.toString(),
          );
        } finally {
          if (buffer != null && buffer.address != 0) _free(buffer);
        }
      },
    );
  }

  static T? _withSecureFileDescriptor<T>({
    required String resolvedWorkspacePath,
    required String relativePath,
    SecureFileCapability? expectedCapability,
    SecureDirectoryCapability? expectedRootCapability,
    bool requireSingleLink = false,
    required T? Function(
      int fileDescriptor,
      _SecureFileIdentity rootIdentity,
      _SecureFileIdentity fileIdentity,
    )
    action,
  }) {
    final segments = relativePath.split(Platform.pathSeparator);
    final rootSegments = resolvedWorkspacePath
        .split(Platform.pathSeparator)
        .where((segment) => segment.isNotEmpty)
        .toList(growable: false);
    if (!File(resolvedWorkspacePath).isAbsolute ||
        resolvedWorkspacePath.contains('\u0000') ||
        rootSegments.any((segment) => segment == '.' || segment == '..') ||
        relativePath.isEmpty ||
        relativePath.contains('\u0000') ||
        File(relativePath).isAbsolute ||
        segments.isEmpty ||
        segments.any(
          (segment) => segment.isEmpty || segment == '.' || segment == '..',
        )) {
      return null;
    }
    final directoryFlags = _readOnly | _directory | _noFollow | _closeOnExec;
    final fileFlags = _readOnly | _nonBlocking | _noFollow | _closeOnExec;
    final descriptors = <int>[];
    try {
      var directory = _withNativePath(
        Platform.pathSeparator,
        (path) => _open(path, directoryFlags),
      );
      if (directory < 0) return null;
      descriptors.add(directory);
      for (final segment in rootSegments) {
        final next = _withNativePath(
          segment,
          (path) => _openAt(directory, path, directoryFlags),
        );
        if (next < 0) return null;
        descriptors.add(next);
        directory = next;
      }
      final rootIdentity = _fileIdentity(directory);
      if (rootIdentity == null ||
          !_matchesDirectoryIdentity(expectedRootCapability, rootIdentity) ||
          !_matchesRootIdentity(expectedCapability, rootIdentity)) {
        return null;
      }
      for (final segment in segments.take(segments.length - 1)) {
        final next = _withNativePath(
          segment,
          (path) => _openAt(directory, path, directoryFlags),
        );
        if (next < 0) return null;
        descriptors.add(next);
        directory = next;
      }
      final fileDescriptor = _withNativePath(
        segments.last,
        (path) => _openAt(directory, path, fileFlags),
      );
      if (fileDescriptor < 0) return null;
      descriptors.add(fileDescriptor);
      if (!_isRegularFile(fileDescriptor)) return null;
      if (requireSingleLink && _regularFileLinkCount(fileDescriptor) != 1) {
        return null;
      }
      final fileIdentity = _fileIdentity(fileDescriptor);
      if (fileIdentity == null ||
          !_matchesFileIdentity(expectedCapability, fileIdentity)) {
        return null;
      }
      return action(fileDescriptor, rootIdentity, fileIdentity);
    } on Object {
      return null;
    } finally {
      for (final descriptor in descriptors.reversed) {
        _close(descriptor);
      }
    }
  }

  static T? _withSecureDirectoryDescriptor<T>({
    required String resolvedDirectoryPath,
    SecureDirectoryCapability? expectedCapability,
    required T? Function(int directoryDescriptor, _SecureFileIdentity identity)
    action,
  }) {
    final segments = resolvedDirectoryPath
        .split(Platform.pathSeparator)
        .where((segment) => segment.isNotEmpty)
        .toList(growable: false);
    if (!File(resolvedDirectoryPath).isAbsolute ||
        resolvedDirectoryPath.contains('\u0000') ||
        segments.any((segment) => segment == '.' || segment == '..')) {
      return null;
    }
    final directoryFlags = _readOnly | _directory | _noFollow | _closeOnExec;
    final descriptors = <int>[];
    try {
      var directory = _withNativePath(
        Platform.pathSeparator,
        (path) => _open(path, directoryFlags),
      );
      if (directory < 0) return null;
      descriptors.add(directory);
      for (final segment in segments) {
        final next = _withNativePath(
          segment,
          (path) => _openAt(directory, path, directoryFlags),
        );
        if (next < 0) return null;
        descriptors.add(next);
        directory = next;
      }
      final identity = _fileIdentity(directory);
      if (identity == null ||
          !_matchesDirectoryIdentity(expectedCapability, identity)) {
        return null;
      }
      return action(directory, identity);
    } on Object {
      return null;
    } finally {
      for (final descriptor in descriptors.reversed) {
        _close(descriptor);
      }
    }
  }

  static T _withNativePath<T>(
    String value,
    T Function(Pointer<Char> path) action,
  ) {
    final allocation = _allocateNativeString(value);
    try {
      return action(allocation);
    } finally {
      _free(allocation.cast<Void>());
    }
  }

  static Pointer<Char> _allocateNativeString(String value) {
    final encoded = utf8.encode(value);
    final allocation = _malloc(encoded.length + 1);
    if (allocation.address == 0) {
      throw StateError('Could not allocate a native string buffer.');
    }
    final bytes = allocation.cast<Uint8>().asTypedList(encoded.length + 1);
    bytes.setRange(0, encoded.length, encoded);
    bytes[encoded.length] = 0;
    return allocation.cast<Char>();
  }

  static T _withTwoNativePaths<T>(
    String first,
    String second,
    T Function(Pointer<Char> first, Pointer<Char> second) action,
  ) {
    return _withNativePath(
      first,
      (firstPath) => _withNativePath(
        second,
        (secondPath) => action(firstPath, secondPath),
      ),
    );
  }

  static bool _isSafeSinglePathComponent(
    String value, {
    bool allowEmpty = false,
  }) {
    if (value.contains('\u0000') || value.contains(Platform.pathSeparator)) {
      return false;
    }
    if (value == '.' || value == '..') return false;
    return allowEmpty || value.isNotEmpty;
  }

  static String _randomHex128(Random random) {
    final buffer = StringBuffer();
    for (var index = 0; index < 16; index += 1) {
      buffer.write(random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  static bool _clearDirectoryContentsSecurely(
    int directoryDescriptor, {
    required _SecureDirectoryRemovalBudget budget,
    required int remainingDepth,
  }) {
    final independentDescriptor = _withNativePath(
      '.',
      (path) => _openAt(directoryDescriptor, path, _directoryOpenFlags),
    );
    if (independentDescriptor < 0) return false;
    final directory = _fdOpenDirectory(independentDescriptor);
    if (directory.address == 0) {
      _close(independentDescriptor);
      return false;
    }
    final entries = <Uint8List>[];
    try {
      while (true) {
        _errnoLocation().value = 0;
        final entry = _readDirectoryEntry(directory);
        if (entry.address == 0) {
          return _errnoLocation().value == 0 &&
              _removeCollectedDirectoryEntries(
                directoryDescriptor,
                entries,
                budget: budget,
                remainingDepth: remainingDepth,
              );
        }
        final name = _directoryEntryNameBytes(entry);
        if (name == null) return false;
        if (_isDotDirectoryEntry(name)) continue;
        if (!budget.reserveEntry()) return false;
        entries.add(name);
      }
    } finally {
      _closeDirectory(directory);
    }
  }

  static bool _removeCollectedDirectoryEntries(
    int directoryDescriptor,
    List<Uint8List> entries, {
    required _SecureDirectoryRemovalBudget budget,
    required int remainingDepth,
  }) {
    for (final name in entries) {
      final removedFile = _withNativePathBytes(
        name,
        (path) => _unlinkAt(directoryDescriptor, path, 0),
      );
      if (removedFile == 0) continue;
      final removedEmptyDirectory = _withNativePathBytes(
        name,
        (path) => _unlinkAt(directoryDescriptor, path, _removeDirectory),
      );
      if (removedEmptyDirectory == 0) continue;
      if (remainingDepth <= 1) return false;
      _withNativePathBytes(
        name,
        (path) => _changeModeAt(
          directoryDescriptor,
          path,
          0x1c0,
          Platform.isMacOS ? 0x20 : 0x100,
        ),
      );
      final childDescriptor = _withNativePathBytes(
        name,
        (path) => _openAt(directoryDescriptor, path, _directoryOpenFlags),
      );
      if (childDescriptor < 0) return false;
      _SecureFileIdentity? childIdentity;
      try {
        childIdentity = _fileIdentity(childDescriptor);
        if (childIdentity == null ||
            !_clearDirectoryContentsSecurely(
              childDescriptor,
              budget: budget,
              remainingDepth: remainingDepth - 1,
            )) {
          return false;
        }
      } finally {
        _close(childDescriptor);
      }
      final observedDescriptor = _withNativePathBytes(
        name,
        (path) => _openAt(directoryDescriptor, path, _directoryOpenFlags),
      );
      if (observedDescriptor < 0) return false;
      _SecureFileIdentity? observedIdentity;
      try {
        observedIdentity = _fileIdentity(observedDescriptor);
      } finally {
        _close(observedDescriptor);
      }
      if (observedIdentity == null ||
          observedIdentity.device != childIdentity.device ||
          observedIdentity.inode != childIdentity.inode) {
        return false;
      }
      final removed = _withNativePathBytes(
        name,
        (path) => _unlinkAt(directoryDescriptor, path, _removeDirectory),
      );
      if (removed != 0) return false;
    }
    return true;
  }

  static Uint8List? _directoryEntryNameBytes(Pointer<Void> entry) {
    final offset = switch (Abi.current()) {
      Abi.macosArm64 || Abi.macosX64 => 21,
      Abi.linuxArm64 || Abi.linuxX64 => 19,
      _ => -1,
    };
    if (offset < 0) return null;
    int length;
    if (Platform.isMacOS) {
      length = (entry.cast<Uint8>() + 18).cast<Uint16>().value;
      if (length <= 0 || length > 255) return null;
    } else {
      final bytes = (entry.cast<Uint8>() + offset).asTypedList(256);
      length = bytes.indexOf(0);
      if (length <= 0) return null;
    }
    return Uint8List.fromList(
      (entry.cast<Uint8>() + offset).asTypedList(length),
    );
  }

  static bool _isDotDirectoryEntry(Uint8List name) =>
      name.length == 1 && name[0] == 0x2e ||
      name.length == 2 && name[0] == 0x2e && name[1] == 0x2e;

  static T _withNativePathBytes<T>(
    Uint8List value,
    T Function(Pointer<Char> path) action,
  ) {
    final allocation = _malloc(value.length + 1);
    if (allocation.address == 0) {
      throw StateError('Could not allocate a native path buffer.');
    }
    try {
      final bytes = allocation.cast<Uint8>().asTypedList(value.length + 1);
      bytes.setRange(0, value.length, value);
      bytes[value.length] = 0;
      return action(allocation.cast<Char>());
    } finally {
      _free(allocation);
    }
  }

  static int _createAnonymousRegularFile({
    required String resolvedDirectoryPath,
    required bool testReplaceBeforeUnlink,
    required bool testForceDescriptorNormalization,
  }) {
    return _withSecureDirectoryDescriptor<int>(
          resolvedDirectoryPath: resolvedDirectoryPath,
          action: (directoryDescriptor, _) {
            final random = Random.secure();
            for (var attempt = 0; attempt < 16; attempt += 1) {
              final name = '.ianvs-acp-ql-${_randomHex128(random)}';
              var descriptor = _withNativePath(
                name,
                (path) => _openAtMode(
                  directoryDescriptor,
                  path,
                  _readWrite | _create | _exclusive | _noFollow | _closeOnExec,
                  0x180,
                ),
              );
              if (descriptor < 0) continue;
              if (!_isRegularFile(descriptor) ||
                  _regularFileLinkCount(descriptor) != 1) {
                _close(descriptor);
                _withNativePath(
                  name,
                  (path) => _unlinkAt(directoryDescriptor, path, 0),
                );
                return -1;
              }
              String? movedName;
              if (testReplaceBeforeUnlink) {
                movedName = '$name.moved-${_randomHex128(random)}';
                final renamed = _withTwoNativePaths(
                  name,
                  movedName,
                  (oldName, newName) => _renameAtExclusive(
                    directoryDescriptor,
                    oldName,
                    directoryDescriptor,
                    newName,
                    Platform.isMacOS ? 0x14 : 0x1,
                  ),
                );
                if (renamed != 0) {
                  _close(descriptor);
                  return -1;
                }
                final substitute = _withNativePath(
                  name,
                  (path) => _openAtMode(
                    directoryDescriptor,
                    path,
                    _readWrite |
                        _create |
                        _exclusive |
                        _noFollow |
                        _closeOnExec,
                    0x180,
                  ),
                );
                if (substitute < 0) {
                  _close(descriptor);
                  _withNativePath(
                    movedName,
                    (path) => _unlinkAt(directoryDescriptor, path, 0),
                  );
                  return -1;
                }
                _close(substitute);
              }
              final unlinked = _withNativePath(
                name,
                (path) => _unlinkAt(directoryDescriptor, path, 0),
              );
              final safelyAnonymous =
                  unlinked == 0 &&
                  _isRegularFile(descriptor) &&
                  _regularFileLinkCount(descriptor) == 0;
              if (movedName != null) {
                _withNativePath(
                  movedName,
                  (path) => _unlinkAt(directoryDescriptor, path, 0),
                );
              }
              if (!safelyAnonymous) {
                _close(descriptor);
                return -1;
              }
              if (descriptor < 3 || testForceDescriptorNormalization) {
                final normalized = _fileControl(descriptor, 67, 3);
                _close(descriptor);
                descriptor = normalized;
              }
              if (descriptor < 3 ||
                  !_isRegularFile(descriptor) ||
                  _regularFileLinkCount(descriptor) != 0) {
                if (descriptor >= 0) _close(descriptor);
                return -1;
              }
              return descriptor;
            }
            return -1;
          },
        ) ??
        -1;
  }

  static int get _readOnly => 0;

  static int get _writeOnly => 1;

  static int get _readWrite => 2;

  static int get _create => Platform.isMacOS ? 0x00000200 : 0x00000040;

  static int get _exclusive => Platform.isMacOS ? 0x00000800 : 0x00000080;

  static int get _directory => Platform.isMacOS ? 0x00100000 : 0x00010000;

  static int get _noFollow => Platform.isMacOS ? 0x00000100 : 0x00020000;

  static int get _closeOnExec => Platform.isMacOS ? 0x01000000 : 0x00080000;

  static int get _nonBlocking => Platform.isMacOS ? 0x00000004 : 0x00000800;

  static int get _removeDirectory => Platform.isMacOS ? 0x80 : 0x200;

  static int get _directoryOpenFlags =>
      _readOnly | _directory | _noFollow | _closeOnExec;

  static bool _isPrivateOwnedEmptyDirectory(int directoryDescriptor) {
    final metadata = _fileMetadata(directoryDescriptor);
    return metadata != null &&
        metadata.mode & 0xf000 == 0x4000 &&
        metadata.mode & 0x1ff == 0x1c0 &&
        metadata.owner == _getUserId() &&
        _directoryIsEmpty(directoryDescriptor);
  }

  static bool _directoryIsEmpty(int directoryDescriptor) {
    final independentDescriptor = _withNativePath(
      '.',
      (path) => _openAt(directoryDescriptor, path, _directoryOpenFlags),
    );
    if (independentDescriptor < 0) return false;
    final directory = _fdOpenDirectory(independentDescriptor);
    if (directory.address == 0) {
      _close(independentDescriptor);
      return false;
    }
    try {
      while (true) {
        _errnoLocation().value = 0;
        final entry = _readDirectoryEntry(directory);
        if (entry.address == 0) return _errnoLocation().value == 0;
        final nameOffset = switch (Abi.current()) {
          Abi.macosArm64 || Abi.macosX64 => 21,
          Abi.linuxArm64 || Abi.linuxX64 => 19,
          _ => -1,
        };
        if (nameOffset < 0) return false;
        final name = (entry.cast<Uint8>() + nameOffset).asTypedList(3);
        final isDot = name[0] == 0x2e && name[1] == 0;
        final isDotDot = name[0] == 0x2e && name[1] == 0x2e && name[2] == 0;
        if (!isDot && !isDotDot) return false;
      }
    } finally {
      _closeDirectory(directory);
    }
  }

  static bool _isRegularFile(int fileDescriptor) {
    final metadata = _fileMetadata(fileDescriptor);
    return metadata != null && metadata.mode & 0xf000 == 0x8000;
  }

  static _SecureFileMetadata? _fileMetadata(int fileDescriptor) {
    final statBuffer = _malloc(512);
    if (statBuffer.address == 0) return null;
    try {
      if (_fstat(fileDescriptor, statBuffer) != 0) return null;
      final bytes = statBuffer.cast<Uint8>();
      final mode = switch (Abi.current()) {
        Abi.macosArm64 || Abi.macosX64 => (bytes + 4).cast<Uint16>().value,
        Abi.linuxArm64 => (bytes + 16).cast<Uint32>().value,
        Abi.linuxX64 => (bytes + 24).cast<Uint32>().value,
        _ => null,
      };
      final owner = switch (Abi.current()) {
        Abi.macosArm64 || Abi.macosX64 => (bytes + 16).cast<Uint32>().value,
        Abi.linuxArm64 => (bytes + 24).cast<Uint32>().value,
        Abi.linuxX64 => (bytes + 28).cast<Uint32>().value,
        _ => null,
      };
      if (mode == null || owner == null) return null;
      return _SecureFileMetadata(mode: mode, owner: owner);
    } finally {
      _free(statBuffer);
    }
  }

  static int? _regularFileSize(int fileDescriptor) {
    final statBuffer = _malloc(512);
    if (statBuffer.address == 0) return null;
    try {
      if (_fstat(fileDescriptor, statBuffer) != 0) return null;
      final offset = switch (Abi.current()) {
        Abi.macosArm64 || Abi.macosX64 => 96,
        Abi.linuxArm64 || Abi.linuxX64 => 48,
        _ => -1,
      };
      if (offset < 0) return null;
      final size = (statBuffer.cast<Uint8>() + offset).cast<Int64>().value;
      return size < 0 ? null : size;
    } finally {
      _free(statBuffer);
    }
  }

  static int? _regularFileLinkCount(int fileDescriptor) {
    final statBuffer = _malloc(512);
    if (statBuffer.address == 0) return null;
    try {
      if (_fstat(fileDescriptor, statBuffer) != 0) return null;
      final bytes = statBuffer.cast<Uint8>();
      return switch (Abi.current()) {
        Abi.macosArm64 || Abi.macosX64 => (bytes + 6).cast<Uint16>().value,
        Abi.linuxArm64 => (bytes + 20).cast<Uint32>().value,
        Abi.linuxX64 => (bytes + 16).cast<Uint64>().value,
        _ => null,
      };
    } finally {
      _free(statBuffer);
    }
  }

  static _SecureFileIdentity? _fileIdentity(int fileDescriptor) {
    final statBuffer = _malloc(512);
    if (statBuffer.address == 0) return null;
    try {
      if (_fstat(fileDescriptor, statBuffer) != 0) return null;
      final bytes = statBuffer.cast<Uint8>();
      final device = switch (Abi.current()) {
        Abi.macosArm64 || Abi.macosX64 => bytes.cast<Uint32>().value,
        Abi.linuxArm64 || Abi.linuxX64 => bytes.cast<Uint64>().value,
        _ => null,
      };
      final inode = switch (Abi.current()) {
        Abi.macosArm64 || Abi.macosX64 => (bytes + 8).cast<Uint64>().value,
        Abi.linuxArm64 || Abi.linuxX64 => (bytes + 8).cast<Uint64>().value,
        _ => null,
      };
      if (device == null || inode == null) return null;
      return _SecureFileIdentity(device: device, inode: inode);
    } finally {
      _free(statBuffer);
    }
  }

  static bool _matchesRootIdentity(
    SecureFileCapability? expected,
    _SecureFileIdentity observed,
  ) =>
      expected == null ||
      (expected.rootDevice == observed.device &&
          expected.rootInode == observed.inode);

  static bool _matchesDirectoryIdentity(
    SecureDirectoryCapability? expected,
    _SecureFileIdentity observed,
  ) =>
      expected == null ||
      (expected.device == observed.device && expected.inode == observed.inode);

  static bool _matchesFileIdentity(
    SecureFileCapability? expected,
    _SecureFileIdentity observed,
  ) =>
      expected == null ||
      (expected.fileDevice == observed.device &&
          expected.fileInode == observed.inode);
}

final class _SecureFileIdentity {
  const _SecureFileIdentity({required this.device, required this.inode});

  final int device;
  final int inode;
}

final class _SecureFileMetadata {
  const _SecureFileMetadata({required this.mode, required this.owner});

  final int mode;
  final int owner;
}

final class _SecureDirectoryRemovalBudget {
  _SecureDirectoryRemovalBudget(this.remainingEntries);

  int remainingEntries;

  bool reserveEntry() {
    if (remainingEntries <= 0) return false;
    remainingEntries -= 1;
    return true;
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) {
    value ??= data;
  }

  @override
  void close() {}
}
