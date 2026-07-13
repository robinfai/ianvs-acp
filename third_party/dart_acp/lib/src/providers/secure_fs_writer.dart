import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

const int secureFsWriteChunkSize = 64 * 1024;
const String secureFsWriteTempPrefix = '.dart-acp-write-';
const int secureFsWriteMetadataMaxItems = 128;
const int secureFsWriteMetadataMaxBytes = 1024 * 1024;

enum SecureFsWriteNativeAbi { darwin, linux }

bool get secureFsWriteNativeAbiIsSupportedForTesting =>
    _isSupportedSecureFsWriteNativeAbi;

SecureFsWriteNativeAbi get secureFsWriteNativeAbiForTesting {
  if (Platform.isMacOS &&
      (Abi.current() == Abi.macosArm64 || Abi.current() == Abi.macosX64)) {
    return SecureFsWriteNativeAbi.darwin;
  }
  if (Platform.isLinux &&
      (Abi.current() == Abi.linuxArm64 || Abi.current() == Abi.linuxX64)) {
    return SecureFsWriteNativeAbi.linux;
  }
  throw UnsupportedError('Unsupported secure filesystem write ABI.');
}

bool get _isSupportedSecureFsWriteNativeAbi {
  if (Platform.isMacOS) {
    return Abi.current() == Abi.macosArm64 || Abi.current() == Abi.macosX64;
  }
  if (Platform.isLinux) {
    return Abi.current() == Abi.linuxArm64 || Abi.current() == Abi.linuxX64;
  }
  return false;
}

final class SecureFsWriteLimitExceeded extends FileSystemException {
  const SecureFsWriteLimitExceeded()
    : super('Secure file write limit exceeded');
}

enum SecureFsWriteHookPhase {
  beforeDirectoryOpen,
  afterDirectoryCreate,
  beforeFinalOpen,
  afterFinalOpen,
  afterFinalValidation,
  beforeNativeWrite,
}

final class SecureFsWriteHookEvent {
  const SecureFsWriteHookEvent({
    required this.phase,
    required this.canonicalTarget,
    this.segment,
  });

  final SecureFsWriteHookPhase phase;
  final String canonicalTarget;
  final String? segment;
}

/// Internal-only controls for deterministic native-writer tests.
///
/// This type deliberately is not exported from `dart_acp.dart`.
final class SecureFsWriteTestHooks {
  const SecureFsWriteTestHooks({
    this.onHook,
    this.maxNativeWriteBytes,
    this.writeEintrCount = 0,
    this.forceZeroWrite = false,
    this.platformSupported,
    this.onNativeAllocation,
    this.closeFailureCount = 0,
    this.closeFailureAtAttempt,
    this.onCloseAttempt,
    this.forceNotRegularFile = false,
    this.forceMetadataCopyFailure = false,
  }) : assert(maxNativeWriteBytes == null || maxNativeWriteBytes > 0),
       assert(writeEintrCount >= 0),
       assert(closeFailureCount >= 0),
       assert(closeFailureAtAttempt == null || closeFailureAtAttempt > 0);

  final void Function(SecureFsWriteHookEvent event)? onHook;
  final int? maxNativeWriteBytes;
  final int writeEintrCount;
  final bool forceZeroWrite;
  final bool? platformSupported;
  final void Function(int bytes)? onNativeAllocation;
  final int closeFailureCount;
  final int? closeFailureAtAttempt;
  final void Function(int descriptor)? onCloseAttempt;
  final bool forceNotRegularFile;
  final bool forceMetadataCopyFailure;
}

Future<void> writeSecureTextFile({
  required String canonicalRoot,
  required String relativePath,
  required String content,
  required int maxWriteBytes,
  SecureFsWriteTestHooks? testHooks,
}) async {
  if (maxWriteBytes <= 0) {
    throw ArgumentError.value(maxWriteBytes, 'maxWriteBytes');
  }
  final maxNativeWriteBytes = testHooks?.maxNativeWriteBytes;
  if (maxNativeWriteBytes != null && maxNativeWriteBytes <= 0) {
    throw ArgumentError.value(maxNativeWriteBytes, 'maxNativeWriteBytes');
  }
  if ((testHooks?.writeEintrCount ?? 0) < 0) {
    throw ArgumentError.value(testHooks?.writeEintrCount, 'writeEintrCount');
  }
  if ((testHooks?.closeFailureCount ?? 0) < 0) {
    throw ArgumentError.value(
      testHooks?.closeFailureCount,
      'closeFailureCount',
    );
  }
  final closeFailureAtAttempt = testHooks?.closeFailureAtAttempt;
  if (closeFailureAtAttempt != null && closeFailureAtAttempt <= 0) {
    throw ArgumentError.value(closeFailureAtAttempt, 'closeFailureAtAttempt');
  }
  final platformSupported =
      testHooks?.platformSupported ?? (Platform.isMacOS || Platform.isLinux);
  if (!platformSupported) {
    throw UnsupportedError('Secure filesystem writes require macOS or Linux.');
  }
  if (!Platform.isMacOS && !Platform.isLinux) {
    throw UnsupportedError('Secure filesystem writes require macOS or Linux.');
  }
  if (!_isSupportedSecureFsWriteNativeAbi) {
    throw UnsupportedError('Unsupported secure filesystem write ABI.');
  }
  late final Map<String, Object?> outcome;
  try {
    outcome = await Isolate.run<Map<String, Object?>>(
      () => _PosixSecureFileWriter.write(
        canonicalRoot: canonicalRoot,
        relativePath: relativePath,
        content: content,
        maxWriteBytes: maxWriteBytes,
        testHooks: testHooks,
      ),
    );
  } on Object {
    throw const FileSystemException('Secure file write failed');
  }
  switch (outcome['failure']) {
    case null:
      return;
    case 'limit':
      throw const SecureFsWriteLimitExceeded();
    case 'invalid_budget':
      throw ArgumentError('Secure filesystem write budget is invalid.');
    case 'invalid_path':
      throw const FileSystemException('Secure file path is invalid');
    case 'not_regular':
      throw const FileSystemException('Secure file is not a regular file');
    default:
      throw const FileSystemException('Secure file write failed');
  }
}

final class _SecureFsCloseFailure implements Exception {
  const _SecureFsCloseFailure();
}

final class _PosixSecureFileWriter {
  static final DynamicLibrary _libc = DynamicLibrary.process();
  static final Pointer<NativeFunction<Void Function()>> _openPointer = _libc
      .lookup<NativeFunction<Void Function()>>('open');
  static final int Function(Pointer<Char>, int) _open = _openPointer
      .cast<NativeFunction<Int32 Function(Pointer<Char>, Int32, VarArgs<()>)>>()
      .asFunction();
  static final Pointer<NativeFunction<Void Function()>> _openAtPointer = _libc
      .lookup<NativeFunction<Void Function()>>('openat');
  static final int Function(int, Pointer<Char>, int) _openAt = _openAtPointer
      .cast<
        NativeFunction<Int32 Function(Int32, Pointer<Char>, Int32, VarArgs<()>)>
      >()
      .asFunction();
  static final int Function(int, Pointer<Char>, int, int) _openAtCreateDarwin =
      _openAtPointer
          .cast<
            NativeFunction<
              Int32 Function(Int32, Pointer<Char>, Int32, VarArgs<(Int32,)>)
            >
          >()
          .asFunction();
  static final int Function(int, Pointer<Char>, int, int) _openAtCreateLinux =
      _openAtPointer
          .cast<
            NativeFunction<
              Int32 Function(Int32, Pointer<Char>, Int32, VarArgs<(Uint32,)>)
            >
          >()
          .asFunction();
  static final int Function(int, Pointer<Char>, int) _mkdirAtDarwin = _libc
      .lookupFunction<
        Int32 Function(Int32, Pointer<Char>, Uint16),
        int Function(int, Pointer<Char>, int)
      >('mkdirat');
  static final int Function(int, Pointer<Char>, int) _mkdirAtLinux = _libc
      .lookupFunction<
        Int32 Function(Int32, Pointer<Char>, Uint32),
        int Function(int, Pointer<Char>, int)
      >('mkdirat');
  static final int Function(int, Pointer<Void>, int) _write = _libc
      .lookupFunction<
        IntPtr Function(Int32, Pointer<Void>, UintPtr),
        int Function(int, Pointer<Void>, int)
      >('write');
  static final int Function(int, Pointer<Void>) _fstat = _libc
      .lookupFunction<
        Int32 Function(Int32, Pointer<Void>),
        int Function(int, Pointer<Void>)
      >(_fstatSymbol);
  static final int Function(int, int) _fchmodDarwin = _libc
      .lookupFunction<Int32 Function(Int32, Uint16), int Function(int, int)>(
        'fchmod',
      );
  static final int Function(int, int) _fchmodLinux = _libc
      .lookupFunction<Int32 Function(Int32, Uint32), int Function(int, int)>(
        'fchmod',
      );
  static final int Function(int, Pointer<Char>, int, Pointer<Char>) _renameAt =
      _libc.lookupFunction<
        Int32 Function(Int32, Pointer<Char>, Int32, Pointer<Char>),
        int Function(int, Pointer<Char>, int, Pointer<Char>)
      >('renameat');
  static final int Function(int, Pointer<Char>, int) _unlinkAt = _libc
      .lookupFunction<
        Int32 Function(Int32, Pointer<Char>, Int32),
        int Function(int, Pointer<Char>, int)
      >('unlinkat');
  static final int Function(int, int, Pointer<Void>, int) _fcopyfile = _libc
      .lookupFunction<
        Int32 Function(Int32, Int32, Pointer<Void>, Uint32),
        int Function(int, int, Pointer<Void>, int)
      >('fcopyfile');
  static final int Function(int, Pointer<Char>, int) _flistxattr = _libc
      .lookupFunction<
        IntPtr Function(Int32, Pointer<Char>, UintPtr),
        int Function(int, Pointer<Char>, int)
      >('flistxattr');
  static final int Function(int, Pointer<Char>, Pointer<Void>, int) _fgetxattr =
      _libc.lookupFunction<
        IntPtr Function(Int32, Pointer<Char>, Pointer<Void>, UintPtr),
        int Function(int, Pointer<Char>, Pointer<Void>, int)
      >('fgetxattr');
  static final int Function(int, Pointer<Char>, Pointer<Void>, int, int)
  _fsetxattr = _libc
      .lookupFunction<
        Int32 Function(Int32, Pointer<Char>, Pointer<Void>, UintPtr, Int32),
        int Function(int, Pointer<Char>, Pointer<Void>, int, int)
      >('fsetxattr');
  static final int Function(int, Pointer<Char>) _fremovexattr = _libc
      .lookupFunction<
        Int32 Function(Int32, Pointer<Char>),
        int Function(int, Pointer<Char>)
      >('fremovexattr');
  static final int Function(int) _close = _libc
      .lookupFunction<Int32 Function(Int32), int Function(int)>('close');
  static final Pointer<Void> Function(int) _malloc = _libc
      .lookupFunction<
        Pointer<Void> Function(UintPtr),
        Pointer<Void> Function(int)
      >('malloc');
  static final void Function(Pointer<Void>) _free = _libc
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('free');

  static Map<String, Object?> write({
    required String canonicalRoot,
    required String relativePath,
    required String content,
    required int maxWriteBytes,
    required SecureFsWriteTestHooks? testHooks,
  }) {
    if (maxWriteBytes <= 0) {
      return const <String, Object?>{'failure': 'invalid_budget'};
    }
    final relativeSegments = p
        .split(relativePath)
        .where((segment) => segment.isNotEmpty && segment != '.')
        .toList(growable: false);
    final canonicalRootSegments = p
        .split(canonicalRoot)
        .where(
          (segment) =>
              segment.isNotEmpty && segment != p.rootPrefix(canonicalRoot),
        )
        .toList(growable: false);
    if (!p.isAbsolute(canonicalRoot) ||
        p.normalize(canonicalRoot) != canonicalRoot ||
        canonicalRoot.contains('\u0000') ||
        canonicalRootSegments.any(
          (segment) => segment == '.' || segment == '..',
        ) ||
        relativePath.contains('\u0000') ||
        p.isAbsolute(relativePath) ||
        relativeSegments.isEmpty ||
        relativeSegments.any((segment) => segment == '..')) {
      return const <String, Object?>{'failure': 'invalid_path'};
    }

    final measuredBytes = _measureUtf8UpToLimit(content, maxWriteBytes);
    if (measuredBytes == null) {
      return const <String, Object?>{'failure': 'limit'};
    }
    late final Uint8List encoded;
    try {
      encoded = Uint8List.fromList(utf8.encode(content));
    } on Object {
      return const <String, Object?>{'failure': 'write'};
    }
    if (encoded.length != measuredBytes || encoded.length > maxWriteBytes) {
      return const <String, Object?>{'failure': 'limit'};
    }

    final canonicalTarget = p.join(canonicalRoot, relativePath);
    final directoryFlags = _readOnly | _directory | _noFollow | _closeOnExec;
    final fileFlags = _writeOnly | _nonBlocking | _noFollow | _closeOnExec;
    final descriptors = <int>[];
    Pointer<Void>? nativeBytes;
    String? temporaryName;
    int? temporaryDescriptor;
    int? temporaryDirectory;
    String? modeProbeName;
    int? modeProbeDescriptor;
    var temporaryRenamed = false;
    var operationSucceeded = false;
    var simulatedCloseFailures = testHooks?.closeFailureCount ?? 0;
    var closeAttempt = 0;

    bool closeDescriptor(int descriptor) {
      var failed = false;
      closeAttempt += 1;
      try {
        testHooks?.onCloseAttempt?.call(descriptor);
      } on Object {
        failed = true;
      }
      try {
        if (_close(descriptor) != 0) failed = true;
      } on Object {
        failed = true;
      }
      if (simulatedCloseFailures > 0) {
        simulatedCloseFailures -= 1;
        failed = true;
      }
      if (testHooks?.closeFailureAtAttempt == closeAttempt) failed = true;
      return !failed;
    }

    try {
      var directory = _withNativePath(
        p.rootPrefix(canonicalRoot),
        (path) => _retryInt(() => _open(path, directoryFlags)),
      );
      if (directory < 0) {
        return const <String, Object?>{'failure': 'open'};
      }
      descriptors.add(directory);

      for (final segment in canonicalRootSegments) {
        _emitHook(
          testHooks,
          SecureFsWriteHookPhase.beforeDirectoryOpen,
          canonicalTarget,
          segment,
        );
        final next = _withNativePath(
          segment,
          (path) => _retryInt(() => _openAt(directory, path, directoryFlags)),
        );
        if (next < 0) {
          return const <String, Object?>{'failure': 'open'};
        }
        descriptors.add(next);
        directory = next;
      }

      for (final segment in relativeSegments.take(
        relativeSegments.length - 1,
      )) {
        _emitHook(
          testHooks,
          SecureFsWriteHookPhase.beforeDirectoryOpen,
          canonicalTarget,
          segment,
        );
        var next = _withNativePath(
          segment,
          (path) => _retryInt(() => _openAt(directory, path, directoryFlags)),
        );
        if (next < 0 && _errno == _noEntry) {
          final mkdirResult = _withNativePath(
            segment,
            (path) => _retryInt(() => _mkdirAt(directory, path, 0x1ff)),
          );
          if (mkdirResult != 0 && _errno != _alreadyExists) {
            return const <String, Object?>{'failure': 'open'};
          }
          if (mkdirResult == 0) {
            _emitHook(
              testHooks,
              SecureFsWriteHookPhase.afterDirectoryCreate,
              canonicalTarget,
              segment,
            );
          }
          next = _withNativePath(
            segment,
            (path) => _retryInt(() => _openAt(directory, path, directoryFlags)),
          );
        }
        if (next < 0) {
          return const <String, Object?>{'failure': 'open'};
        }
        descriptors.add(next);
        directory = next;
      }

      _emitHook(
        testHooks,
        SecureFsWriteHookPhase.beforeFinalOpen,
        canonicalTarget,
        relativeSegments.last,
      );
      final existingDescriptor = _withNativePath(
        relativeSegments.last,
        (path) => _retryInt(() => _openAt(directory, path, fileFlags)),
      );
      int? existingMode;
      if (existingDescriptor >= 0) {
        descriptors.add(existingDescriptor);
        _emitHook(
          testHooks,
          SecureFsWriteHookPhase.afterFinalOpen,
          canonicalTarget,
          relativeSegments.last,
        );
        existingMode = _regularFileMode(existingDescriptor);
        if ((testHooks?.forceNotRegularFile ?? false) || existingMode == null) {
          return const <String, Object?>{'failure': 'not_regular'};
        }
        _emitHook(
          testHooks,
          SecureFsWriteHookPhase.afterFinalValidation,
          canonicalTarget,
          relativeSegments.last,
        );
      } else if (_errno != _noEntry) {
        return const <String, Object?>{'failure': 'open'};
      }

      final temporaryFile = _createTemporaryFile(
        directory: directory,
        flags: fileFlags | _create | _exclusive,
        mode: _ownerReadWriteMode,
      );
      if (temporaryFile == null) {
        return const <String, Object?>{'failure': 'open'};
      }
      temporaryName = temporaryFile.name;
      temporaryDescriptor = temporaryFile.descriptor;
      temporaryDirectory = directory;
      int? finalMode = existingMode;
      if (existingDescriptor < 0) {
        _emitHook(
          testHooks,
          SecureFsWriteHookPhase.afterFinalOpen,
          canonicalTarget,
          relativeSegments.last,
        );
        if ((testHooks?.forceNotRegularFile ?? false) ||
            _regularFileMode(temporaryDescriptor) == null) {
          return const <String, Object?>{'failure': 'not_regular'};
        }
        _emitHook(
          testHooks,
          SecureFsWriteHookPhase.afterFinalValidation,
          canonicalTarget,
          relativeSegments.last,
        );
        final modeProbe = _createTemporaryFile(
          directory: directory,
          flags: fileFlags | _create | _exclusive,
          mode: _defaultFileCreationMode,
        );
        if (modeProbe == null) {
          return const <String, Object?>{'failure': 'open'};
        }
        modeProbeName = modeProbe.name;
        modeProbeDescriptor = modeProbe.descriptor;
        finalMode = _regularFileMode(modeProbeDescriptor);
        if (finalMode == null) {
          return const <String, Object?>{'failure': 'not_regular'};
        }
        final descriptorToClose = modeProbeDescriptor;
        modeProbeDescriptor = null;
        if (!closeDescriptor(descriptorToClose)) {
          return const <String, Object?>{'failure': 'write'};
        }
        final unlinkResult = _withNativePath(
          modeProbeName,
          (path) => _retryInt(() => _unlinkAt(directory, path, 0)),
        );
        if (unlinkResult != 0) {
          return const <String, Object?>{'failure': 'write'};
        }
        modeProbeName = null;
      }
      _emitHook(
        testHooks,
        SecureFsWriteHookPhase.beforeNativeWrite,
        canonicalTarget,
        relativeSegments.last,
      );
      if (encoded.isNotEmpty) {
        final nativeBufferLength = encoded.length < secureFsWriteChunkSize
            ? encoded.length
            : secureFsWriteChunkSize;
        nativeBytes = _malloc(nativeBufferLength);
        if (nativeBytes.address == 0) {
          return const <String, Object?>{'failure': 'malloc'};
        }
        testHooks?.onNativeAllocation?.call(nativeBufferLength);
        final nativeView = nativeBytes.cast<Uint8>().asTypedList(
          nativeBufferLength,
        );
        var encodedOffset = 0;
        var remainingEintr = testHooks?.writeEintrCount ?? 0;
        while (encodedOffset < encoded.length) {
          final remainingEncoded = encoded.length - encodedOffset;
          final chunkLength = remainingEncoded < nativeBufferLength
              ? remainingEncoded
              : nativeBufferLength;
          nativeView.setRange(0, chunkLength, encoded, encodedOffset);
          var chunkOffset = 0;
          while (chunkOffset < chunkLength) {
            var requested = chunkLength - chunkOffset;
            final maxNativeWriteBytes = testHooks?.maxNativeWriteBytes;
            if (maxNativeWriteBytes != null &&
                requested > maxNativeWriteBytes) {
              requested = maxNativeWriteBytes;
            }
            int count;
            var simulatedEintr = false;
            if (remainingEintr > 0) {
              remainingEintr -= 1;
              count = -1;
              simulatedEintr = true;
            } else if (testHooks?.forceZeroWrite ?? false) {
              count = 0;
            } else {
              count = _write(
                temporaryDescriptor,
                (nativeBytes.cast<Uint8>() + chunkOffset).cast<Void>(),
                requested,
              );
            }
            if (count < 0) {
              if (simulatedEintr) continue;
              if (_errno == _interrupted) continue;
              return const <String, Object?>{'failure': 'write'};
            }
            if (count == 0) {
              return const <String, Object?>{'failure': 'zero_write'};
            }
            chunkOffset += count;
          }
          encodedOffset += chunkLength;
        }
      }

      if (existingMode != null &&
          ((testHooks?.forceMetadataCopyFailure ?? false) ||
              !_copyMetadata(existingDescriptor, temporaryDescriptor))) {
        return const <String, Object?>{'failure': 'write'};
      }
      if (finalMode == null ||
          _retryInt(() => _fchmod(temporaryDescriptor!, finalMode! & 0x0fff)) !=
              0) {
        return const <String, Object?>{'failure': 'write'};
      }

      final descriptorToClose = temporaryDescriptor;
      temporaryDescriptor = null;
      if (!closeDescriptor(descriptorToClose)) {
        return const <String, Object?>{'failure': 'write'};
      }
      final renameResult = _withNativePath(
        temporaryName,
        (oldPath) => _withNativePath(
          relativeSegments.last,
          (newPath) => _retryInt(
            () => _renameAt(directory, oldPath, directory, newPath),
          ),
        ),
      );
      if (renameResult != 0) {
        return const <String, Object?>{'failure': 'write'};
      }
      temporaryRenamed = true;
      operationSucceeded = true;
      return const <String, Object?>{};
    } on Object {
      return const <String, Object?>{'failure': 'write'};
    } finally {
      if (nativeBytes != null && nativeBytes.address != 0) _free(nativeBytes);
      var closeFailed = false;
      final remainingModeProbeDescriptor = modeProbeDescriptor;
      modeProbeDescriptor = null;
      if (remainingModeProbeDescriptor != null &&
          !closeDescriptor(remainingModeProbeDescriptor)) {
        closeFailed = true;
      }
      final remainingTemporaryDescriptor = temporaryDescriptor;
      temporaryDescriptor = null;
      if (remainingTemporaryDescriptor != null &&
          !closeDescriptor(remainingTemporaryDescriptor)) {
        closeFailed = true;
      }
      if (!temporaryRenamed && temporaryName != null) {
        try {
          _withNativePath(
            temporaryName,
            (path) => _retryInt(() => _unlinkAt(temporaryDirectory!, path, 0)),
          );
        } on Object {
          // Cleanup failures never replace the primary write failure.
        }
      }
      if (modeProbeName != null) {
        try {
          _withNativePath(
            modeProbeName,
            (path) => _retryInt(() => _unlinkAt(temporaryDirectory!, path, 0)),
          );
        } on Object {
          // Cleanup failures never replace the primary write failure.
        }
      }
      for (final descriptor in descriptors.reversed) {
        if (!closeDescriptor(descriptor)) closeFailed = true;
      }
      if (operationSucceeded && closeFailed) {
        throw const _SecureFsCloseFailure();
      }
    }
  }

  static int? _measureUtf8UpToLimit(String value, int maxBytes) {
    var bytes = 0;
    for (var index = 0; index < value.length; index += 1) {
      final codeUnit = value.codeUnitAt(index);
      late final int nextBytes;
      if (codeUnit <= 0x7f) {
        nextBytes = 1;
      } else if (codeUnit <= 0x7ff) {
        nextBytes = 2;
      } else if (codeUnit >= 0xd800 && codeUnit <= 0xdbff) {
        if (index + 1 < value.length) {
          final low = value.codeUnitAt(index + 1);
          if (low >= 0xdc00 && low <= 0xdfff) {
            nextBytes = 4;
            index += 1;
          } else {
            nextBytes = 3;
          }
        } else {
          nextBytes = 3;
        }
      } else {
        nextBytes = 3;
      }
      if (nextBytes > maxBytes - bytes) return null;
      bytes += nextBytes;
    }
    return bytes;
  }

  static void _emitHook(
    SecureFsWriteTestHooks? hooks,
    SecureFsWriteHookPhase phase,
    String canonicalTarget,
    String segment,
  ) {
    hooks?.onHook?.call(
      SecureFsWriteHookEvent(
        phase: phase,
        canonicalTarget: canonicalTarget,
        segment: segment,
      ),
    );
  }

  static int _openAtCreate(
    int directory,
    Pointer<Char> path,
    int flags,
    int mode,
  ) {
    assert(_isSupportedSecureFsWriteNativeAbi);
    if (Platform.isMacOS) {
      assert(Abi.current() == Abi.macosArm64 || Abi.current() == Abi.macosX64);
      return _openAtCreateDarwin(directory, path, flags, mode);
    }
    assert(Platform.isLinux);
    assert(Abi.current() == Abi.linuxArm64 || Abi.current() == Abi.linuxX64);
    return _openAtCreateLinux(directory, path, flags, mode);
  }

  static int _mkdirAt(int directory, Pointer<Char> path, int mode) {
    assert(_isSupportedSecureFsWriteNativeAbi);
    if (Platform.isMacOS) {
      assert(Abi.current() == Abi.macosArm64 || Abi.current() == Abi.macosX64);
      return _mkdirAtDarwin(directory, path, mode);
    }
    assert(Platform.isLinux);
    assert(Abi.current() == Abi.linuxArm64 || Abi.current() == Abi.linuxX64);
    return _mkdirAtLinux(directory, path, mode);
  }

  static int _fchmod(int descriptor, int mode) {
    assert(_isSupportedSecureFsWriteNativeAbi);
    if (Platform.isMacOS) {
      assert(Abi.current() == Abi.macosArm64 || Abi.current() == Abi.macosX64);
      return _fchmodDarwin(descriptor, mode);
    }
    assert(Platform.isLinux);
    assert(Abi.current() == Abi.linuxArm64 || Abi.current() == Abi.linuxX64);
    return _fchmodLinux(descriptor, mode);
  }

  static bool _copyMetadata(int sourceDescriptor, int targetDescriptor) {
    if (Platform.isMacOS) {
      final result = _retryInt(
        () => _fcopyfile(
          sourceDescriptor,
          targetDescriptor,
          Pointer<Void>.fromAddress(0),
          _copyfileAcl | _copyfileXattr,
        ),
      );
      return result == 0;
    }
    if (Platform.isLinux) {
      return _copyLinuxExtendedAttributes(sourceDescriptor, targetDescriptor);
    }
    return false;
  }

  static bool _copyLinuxExtendedAttributes(
    int sourceDescriptor,
    int targetDescriptor,
  ) {
    final budget = _SecureFsMetadataBudget(
      remainingItems: secureFsWriteMetadataMaxItems,
      remainingBytes: secureFsWriteMetadataMaxBytes,
    );
    final cleared = _forEachLinuxExtendedAttribute(
      targetDescriptor,
      budget,
      (name) => _retryInt(() => _fremovexattr(targetDescriptor, name)) == 0,
    );
    if (!cleared) return false;
    return _forEachLinuxExtendedAttribute(
      sourceDescriptor,
      budget,
      (name) => _copyLinuxExtendedAttribute(
        sourceDescriptor,
        targetDescriptor,
        name,
        budget,
      ),
    );
  }

  static bool _forEachLinuxExtendedAttribute(
    int descriptor,
    _SecureFsMetadataBudget budget,
    bool Function(Pointer<Char> name) action,
  ) {
    final nullNameList = Pointer<Char>.fromAddress(0);
    final listLength = _retryInt(
      () => _flistxattr(descriptor, nullNameList, 0),
    );
    if (listLength < 0 || listLength > budget.remainingBytes) return false;
    if (listLength == 0) return true;
    final nameList = _malloc(listLength);
    if (nameList.address == 0) return false;
    try {
      final actualLength = _retryInt(
        () => _flistxattr(descriptor, nameList.cast<Char>(), listLength),
      );
      if (actualLength != listLength) return false;
      budget.remainingBytes -= listLength;
      final bytes = nameList.cast<Uint8>().asTypedList(listLength);
      var nameStart = 0;
      while (nameStart < listLength) {
        var nameEnd = nameStart;
        while (nameEnd < listLength && bytes[nameEnd] != 0) {
          nameEnd += 1;
        }
        if (nameEnd == nameStart || nameEnd >= listLength) return false;
        if (budget.remainingItems == 0) return false;
        budget.remainingItems -= 1;
        final name = (nameList.cast<Uint8>() + nameStart).cast<Char>();
        if (!action(name)) return false;
        nameStart = nameEnd + 1;
      }
      return true;
    } finally {
      _free(nameList);
    }
  }

  static bool _copyLinuxExtendedAttribute(
    int sourceDescriptor,
    int targetDescriptor,
    Pointer<Char> name,
    _SecureFsMetadataBudget budget,
  ) {
    final nullValue = Pointer<Void>.fromAddress(0);
    final valueLength = _retryInt(
      () => _fgetxattr(sourceDescriptor, name, nullValue, 0),
    );
    if (valueLength < 0 || valueLength > budget.remainingBytes) return false;
    budget.remainingBytes -= valueLength;
    Pointer<Void> value = nullValue;
    if (valueLength > 0) {
      value = _malloc(valueLength);
      if (value.address == 0) return false;
    }
    try {
      final actualLength = _retryInt(
        () => _fgetxattr(sourceDescriptor, name, value, valueLength),
      );
      if (actualLength != valueLength) return false;
      return _retryInt(
            () => _fsetxattr(targetDescriptor, name, value, valueLength, 0),
          ) ==
          0;
    } finally {
      if (value.address != 0) _free(value);
    }
  }

  static _OpenedSecureTempFile? _createTemporaryFile({
    required int directory,
    required int flags,
    required int mode,
  }) {
    final random = Random.secure();
    for (var attempt = 0; attempt < 32; attempt += 1) {
      final name = '$secureFsWriteTempPrefix${_randomHex(random, 24)}';
      final descriptor = _withNativePath(
        name,
        (path) => _retryInt(() => _openAtCreate(directory, path, flags, mode)),
      );
      if (descriptor >= 0) {
        return _OpenedSecureTempFile(name, descriptor);
      }
      if (_errno != _alreadyExists) return null;
    }
    return null;
  }

  static String _randomHex(Random random, int length) {
    const digits = '0123456789abcdef';
    final result = StringBuffer();
    for (var index = 0; index < length; index += 1) {
      result.write(digits[random.nextInt(digits.length)]);
    }
    return result.toString();
  }

  static int _retryInt(int Function() action) {
    while (true) {
      final result = action();
      if (result >= 0 || _errno != _interrupted) return result;
    }
  }

  static int? _regularFileMode(int fileDescriptor) {
    final statBuffer = _malloc(512);
    if (statBuffer.address == 0) return null;
    try {
      if (_fstat(fileDescriptor, statBuffer) != 0) return null;
      final mode = switch (Abi.current()) {
        Abi.macosArm64 ||
        Abi.macosX64 => (statBuffer.cast<Uint8>() + 4).cast<Uint16>().value,
        Abi.linuxArm64 => (statBuffer.cast<Uint8>() + 16).cast<Uint32>().value,
        Abi.linuxX64 => (statBuffer.cast<Uint8>() + 24).cast<Uint32>().value,
        _ => 0,
      };
      return mode & 0xf000 == 0x8000 ? mode : null;
    } finally {
      _free(statBuffer);
    }
  }

  static T _withNativePath<T>(
    String value,
    T Function(Pointer<Char> path) action,
  ) {
    if (value.contains('\u0000')) {
      throw ArgumentError.value(value, 'value', 'Must not contain NUL.');
    }
    final encoded = utf8.encode(value);
    final allocation = _malloc(encoded.length + 1);
    if (allocation.address == 0) {
      throw StateError('Could not allocate native path.');
    }
    try {
      final bytes = allocation.cast<Uint8>().asTypedList(encoded.length + 1);
      bytes.setRange(0, encoded.length, encoded);
      bytes[encoded.length] = 0;
      return action(allocation.cast<Char>());
    } finally {
      _free(allocation);
    }
  }

  static int get _readOnly => 0;
  static int get _writeOnly => 1;
  static int get _create => Platform.isMacOS ? 0x00000200 : 0x00000040;
  static int get _exclusive => Platform.isMacOS ? 0x00000800 : 0x00000080;
  static int get _directory => Platform.isMacOS ? 0x00100000 : 0x00010000;
  static int get _noFollow => Platform.isMacOS ? 0x00000100 : 0x00020000;
  static int get _closeOnExec => Platform.isMacOS ? 0x01000000 : 0x00080000;
  static int get _nonBlocking => Platform.isMacOS ? 0x00000004 : 0x00000800;

  static const int _ownerReadWriteMode = 0x180;
  static const int _defaultFileCreationMode = 0x1b6;
  static const int _copyfileAcl = 0x1;
  static const int _copyfileXattr = 0x4;

  static const int _interrupted = 4;
  static const int _noEntry = 2;
  static const int _alreadyExists = 17;

  static int get _errno {
    final symbol = Platform.isMacOS ? '__error' : '__errno_location';
    final accessor = _libc
        .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
          symbol,
        );
    return accessor().value;
  }

  static String get _fstatSymbol =>
      Abi.current() == Abi.macosX64 ? r'fstat$INODE64' : 'fstat';
}

final class _OpenedSecureTempFile {
  const _OpenedSecureTempFile(this.name, this.descriptor);

  final String name;
  final int descriptor;
}

final class _SecureFsMetadataBudget {
  _SecureFsMetadataBudget({
    required this.remainingItems,
    required this.remainingBytes,
  });

  int remainingItems;
  int remainingBytes;
}
