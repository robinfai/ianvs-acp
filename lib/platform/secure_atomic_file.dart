import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

typedef SecureAtomicProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);
typedef SecureAtomicRename =
    Future<File> Function(File source, String destination);

class SecureAtomicFile {
  const SecureAtomicFile._();

  static int _temporarySequence = 0;
  static final Map<String, _SecureAtomicFileCoordinator> _coordinators =
      <String, _SecureAtomicFileCoordinator>{};

  static Future<T> synchronized<T>(
    File target,
    Future<T> Function() operation,
  ) {
    final key = Uri.file(target.absolute.path).normalizePath().toFilePath();
    final coordinator = _coordinators.putIfAbsent(
      key,
      _SecureAtomicFileCoordinator.new,
    );
    coordinator.retain();
    return coordinator.schedule(operation).whenComplete(() {
      if (coordinator.release() && identical(_coordinators[key], coordinator)) {
        _coordinators.remove(key);
      }
    });
  }

  /// Serializes an operation both within this isolate and across processes.
  ///
  /// The persistent sidecar is intentionally retained: deleting a lock file
  /// while another process is waiting on its inode would split the lock.
  static Future<T> synchronizedAcrossProcesses<T>(
    File target,
    Future<T> Function(File resolvedTarget) operation,
  ) {
    return synchronized(target, () async {
      final parentExisted = await target.parent.exists();
      await target.parent.create(recursive: true);
      if (!parentExisted) {
        await _chmod(null, mode: '0700', path: target.parent.path);
      }
      final parentMode = (await target.parent.stat()).mode;
      final isWritableByOtherPrincipals = parentMode & 0x12 != 0;
      final hasStickyBit = parentMode & 0x200 != 0;
      final hasTrustedStickyOwner =
          hasStickyBit &&
          _NativeFilePermissions.isOwnedByEffectiveUserOrRoot(
            target.parent.path,
          );
      if (isWritableByOtherPrincipals && !hasTrustedStickyOwner) {
        throw FileSystemException(
          'Secure file parent must not be group- or world-writable.',
          target.parent.path,
        );
      }
      final targetType = await FileSystemEntity.type(
        target.path,
        followLinks: false,
      );
      final resolvedTarget = targetType == FileSystemEntityType.notFound
          ? '${await target.parent.resolveSymbolicLinks()}/${target.uri.pathSegments.last}'
          : await target.resolveSymbolicLinks();
      final resolvedFile = File(resolvedTarget);
      final parentPath = resolvedFile.parent.path;
      final basename = resolvedFile.uri.pathSegments.last;
      final lockPath = '$parentPath/.$basename.lock';
      final fileDescriptor = _NativeFilePermissions.openLock(lockPath, 0x180);
      var locked = false;
      try {
        await _NativeFilePermissions.lockExclusive(fileDescriptor, lockPath);
        locked = true;
        return await operation(resolvedFile);
      } finally {
        try {
          if (locked) _NativeFilePermissions.unlock(fileDescriptor, lockPath);
        } finally {
          _NativeFilePermissions.close(fileDescriptor);
        }
      }
    });
  }

  static Future<void> writeString(
    File target,
    String value, {
    SecureAtomicProcessRunner? processRunner,
    SecureAtomicRename? rename,
    bool protectExistingParent = false,
  }) async {
    final moveFile =
        rename ??
        (File source, String destination) => source.rename(destination);

    final parentExisted = await target.parent.exists();
    await target.parent.create(recursive: true);
    if (!parentExisted || protectExistingParent) {
      await _chmod(processRunner, mode: '0700', path: target.parent.path);
    }
    final parentMode = (await target.parent.stat()).mode;
    final isWritableByOtherPrincipals = parentMode & 0x12 != 0;
    final hasStickyBit = parentMode & 0x200 != 0;
    final hasTrustedStickyOwner =
        hasStickyBit &&
        _NativeFilePermissions.isOwnedByEffectiveUserOrRoot(target.parent.path);
    if (isWritableByOtherPrincipals && !hasTrustedStickyOwner) {
      throw FileSystemException(
        'Secure file parent must not be group- or world-writable.',
        target.parent.path,
      );
    }

    final temporary = File(
      '${target.path}.tmp-$pid-${DateTime.now().microsecondsSinceEpoch}-${_temporarySequence++}',
    );
    int? fileDescriptor;
    try {
      fileDescriptor = _NativeFilePermissions.openExclusive(
        temporary.path,
        0x180,
      );
      _NativeFilePermissions.fchmod(fileDescriptor, 0x180, temporary.path);
      if (processRunner != null) {
        await _chmod(processRunner, mode: '0600', path: temporary.path);
      }
      _ensureTemporaryIdentity(fileDescriptor, temporary);
      _NativeFilePermissions.writeAll(
        fileDescriptor,
        utf8.encode(value),
        temporary.path,
      );
      _NativeFilePermissions.flush(fileDescriptor, temporary.path);
      _ensureTemporaryIdentity(fileDescriptor, temporary);
      await moveFile(temporary, target.path);
    } catch (_) {
      try {
        final type = await FileSystemEntity.type(
          temporary.path,
          followLinks: false,
        );
        if (type != FileSystemEntityType.notFound) await temporary.delete();
      } catch (_) {
        // Preserve the original write failure.
      }
      rethrow;
    } finally {
      if (fileDescriptor != null) {
        _NativeFilePermissions.close(fileDescriptor);
      }
    }
  }

  /// Restricts an existing directory to its owner and rejects a final-path
  /// symbolic link. Callers should resolve trusted parent aliases first.
  static Future<void> protectPrivateDirectory(
    Directory directory, {
    SecureAtomicProcessRunner? processRunner,
  }) async {
    final type = await FileSystemEntity.type(
      directory.path,
      followLinks: false,
    );
    if (type != FileSystemEntityType.directory) {
      throw FileSystemException(
        'Private state parent must be a real directory.',
        directory.path,
      );
    }
    await _chmod(processRunner, mode: '0700', path: directory.path);
  }

  /// Creates or protects a regular private file without following a symbolic
  /// link. Returns false only when [create] is false and the file is absent.
  static Future<bool> protectPrivateFile(
    File file, {
    bool create = true,
  }) async {
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound && !create) return false;
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.file) {
      throw FileSystemException(
        'Private state file must be a regular file.',
        file.path,
      );
    }
    final fileDescriptor = _NativeFilePermissions.openLock(file.path, 0x180);
    try {
      if (!_NativeFilePermissions.matchesPath(fileDescriptor, file.path)) {
        throw FileSystemException(
          'Private state file changed while permissions were applied.',
          file.path,
        );
      }
      return true;
    } finally {
      _NativeFilePermissions.close(fileDescriptor);
    }
  }

  static void _ensureTemporaryIdentity(int fileDescriptor, File temporary) {
    if (!_NativeFilePermissions.matchesPath(fileDescriptor, temporary.path)) {
      throw FileSystemException(
        'Secure temporary file was replaced before commit.',
        temporary.path,
      );
    }
  }

  static Future<void> _chmod(
    SecureAtomicProcessRunner? processRunner, {
    required String mode,
    required String path,
  }) async {
    if (processRunner == null) {
      final error = _NativeFilePermissions.chmod(
        path,
        int.parse(mode, radix: 8),
      );
      if (error == 0) return;
      throw FileSystemException(
        'chmod $mode failed with errno $error',
        path,
        OSError('chmod $mode failed', error),
      );
    }

    final result = await processRunner('/bin/chmod', <String>[mode, path]);
    if (result.exitCode == 0) return;

    final message = result.stderr.toString().trim();
    throw FileSystemException(
      message.isEmpty
          ? 'chmod $mode failed with exit code ${result.exitCode}'
          : 'chmod $mode failed: $message',
      path,
      OSError(message, result.exitCode),
    );
  }
}

class _NativeFilePermissions {
  static final DynamicLibrary _libc = DynamicLibrary.process();
  static final int Function(Pointer<Char>, int) _chmodMac = _libc
      .lookupFunction<
        Int32 Function(Pointer<Char>, Uint16),
        int Function(Pointer<Char>, int)
      >('chmod');
  static final int Function(Pointer<Char>, int) _chmodLinux = _libc
      .lookupFunction<
        Int32 Function(Pointer<Char>, Uint32),
        int Function(Pointer<Char>, int)
      >('chmod');
  static final int Function(Pointer<Char>, int, int) _open = _libc
      .lookupFunction<
        Int32 Function(Pointer<Char>, Int32, Uint32),
        int Function(Pointer<Char>, int, int)
      >('open');
  static final int Function(int, int) _fchmodMac = _libc
      .lookupFunction<Int32 Function(Int32, Uint16), int Function(int, int)>(
        'fchmod',
      );
  static final int Function(int, int) _fchmodLinux = _libc
      .lookupFunction<Int32 Function(Int32, Uint32), int Function(int, int)>(
        'fchmod',
      );
  static final int Function(int, Pointer<Void>, int) _write = _libc
      .lookupFunction<
        IntPtr Function(Int32, Pointer<Void>, IntPtr),
        int Function(int, Pointer<Void>, int)
      >('write');
  static final int Function(int) _fsync = _libc
      .lookupFunction<Int32 Function(Int32), int Function(int)>('fsync');
  static final int Function(int) _close = _libc
      .lookupFunction<Int32 Function(Int32), int Function(int)>('close');
  static final int Function(int, int) _flock = _libc
      .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
        'flock',
      );
  static final int Function(int, Pointer<Void>) _fstat = _libc
      .lookupFunction<
        Int32 Function(Int32, Pointer<Void>),
        int Function(int, Pointer<Void>)
      >(_fstatSymbol);
  static final int Function(Pointer<Char>, Pointer<Void>) _lstat = _libc
      .lookupFunction<
        Int32 Function(Pointer<Char>, Pointer<Void>),
        int Function(Pointer<Char>, Pointer<Void>)
      >(_lstatSymbol);
  static final int Function(Pointer<Char>, Pointer<Void>) _stat = _libc
      .lookupFunction<
        Int32 Function(Pointer<Char>, Pointer<Void>),
        int Function(Pointer<Char>, Pointer<Void>)
      >(_statSymbol);
  static final int Function() _geteuid = _libc
      .lookupFunction<Uint32 Function(), int Function()>('geteuid');
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

  static int chmod(String path, int mode) {
    _requireSupportedPlatform();
    return _withNativePath(path, (nativePath) {
      final result = Platform.isMacOS
          ? _chmodMac(nativePath, mode)
          : _chmodLinux(nativePath, mode);
      if (result == 0) return 0;
      return _errno;
    });
  }

  static int openExclusive(String path, int mode) {
    _requireSupportedPlatform();
    return _withNativePath(path, (nativePath) {
      final flags = Platform.isMacOS
          ? 0x00000001 | 0x00000200 | 0x00000800 | 0x00000100 | 0x01000000
          : 0x00000001 | 0x00000040 | 0x00000080 | 0x00020000 | 0x00080000;
      final fileDescriptor = _open(nativePath, flags, mode);
      if (fileDescriptor >= 0) return fileDescriptor;
      final error = _errno;
      throw FileSystemException(
        'Could not create secure temporary file.',
        path,
        OSError('open failed', error),
      );
    });
  }

  static int openLock(String path, int mode) {
    _requireSupportedPlatform();
    return _withNativePath(path, (nativePath) {
      final flags = Platform.isMacOS
          ? 0x00000002 | 0x00000200 | 0x00000100 | 0x01000000
          : 0x00000002 | 0x00000040 | 0x00020000 | 0x00080000;
      final fileDescriptor = _open(nativePath, flags, mode);
      if (fileDescriptor < 0) {
        final error = _errno;
        throw FileSystemException(
          'Could not open secure transaction lock.',
          path,
          OSError('open failed', error),
        );
      }
      try {
        fchmod(fileDescriptor, mode, path);
        return fileDescriptor;
      } catch (_) {
        close(fileDescriptor);
        rethrow;
      }
    });
  }

  static Future<void> lockExclusive(int fileDescriptor, String path) async {
    const lockExclusiveNonBlocking = 0x02 | 0x04;
    while (true) {
      if (_flock(fileDescriptor, lockExclusiveNonBlocking) == 0) return;
      final error = _errno;
      final wouldBlock = Platform.isMacOS ? error == 35 : error == 11;
      final interrupted = error == 4;
      if (interrupted) continue;
      if (!wouldBlock) {
        throw FileSystemException(
          'Could not acquire secure transaction lock.',
          path,
          OSError('flock failed', error),
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  static void unlock(int fileDescriptor, String path) {
    if (_flock(fileDescriptor, 0x08) == 0) return;
    final error = _errno;
    throw FileSystemException(
      'Could not release secure transaction lock.',
      path,
      OSError('flock failed', error),
    );
  }

  static void fchmod(int fileDescriptor, int mode, String path) {
    final result = Platform.isMacOS
        ? _fchmodMac(fileDescriptor, mode)
        : _fchmodLinux(fileDescriptor, mode);
    if (result == 0) return;
    final error = _errno;
    throw FileSystemException(
      'Could not protect secure temporary file.',
      path,
      OSError('fchmod failed', error),
    );
  }

  static void writeAll(int fileDescriptor, List<int> value, String path) {
    if (value.isEmpty) return;
    final allocation = _malloc(value.length);
    if (allocation.address == 0) {
      throw StateError('Could not allocate a native write buffer.');
    }
    try {
      allocation.cast<Uint8>().asTypedList(value.length).setAll(0, value);
      var offset = 0;
      while (offset < value.length) {
        final written = _write(
          fileDescriptor,
          (allocation.cast<Uint8>() + offset).cast<Void>(),
          value.length - offset,
        );
        if (written <= 0) {
          final error = written < 0 ? _errno : 5;
          throw FileSystemException(
            'Could not write secure temporary file.',
            path,
            OSError('write failed', error),
          );
        }
        offset += written;
      }
    } finally {
      _free(allocation);
    }
  }

  static void flush(int fileDescriptor, String path) {
    if (_fsync(fileDescriptor) == 0) return;
    final error = _errno;
    throw FileSystemException(
      'Could not flush secure temporary file.',
      path,
      OSError('fsync failed', error),
    );
  }

  static void close(int fileDescriptor) {
    _close(fileDescriptor);
  }

  static bool matchesPath(int fileDescriptor, String path) {
    final descriptorStat = _malloc(512);
    final pathStat = _malloc(512);
    if (descriptorStat.address == 0 || pathStat.address == 0) {
      if (descriptorStat.address != 0) _free(descriptorStat);
      if (pathStat.address != 0) _free(pathStat);
      throw StateError('Could not allocate native stat buffers.');
    }
    try {
      if (_fstat(fileDescriptor, descriptorStat) != 0) return false;
      final pathResult = _withNativePath(
        path,
        (nativePath) => _lstat(nativePath, pathStat),
      );
      if (pathResult != 0) return false;
      if (Platform.isMacOS) {
        final descriptorDevice = descriptorStat.cast<Uint32>().value;
        final pathDevice = pathStat.cast<Uint32>().value;
        final descriptorInode = (descriptorStat.cast<Uint8>() + 8)
            .cast<Uint64>()
            .value;
        final pathInode = (pathStat.cast<Uint8>() + 8).cast<Uint64>().value;
        return descriptorDevice == pathDevice && descriptorInode == pathInode;
      }
      final descriptorDevice = descriptorStat.cast<Uint64>().value;
      final pathDevice = pathStat.cast<Uint64>().value;
      final descriptorInode = (descriptorStat.cast<Uint8>() + 8)
          .cast<Uint64>()
          .value;
      final pathInode = (pathStat.cast<Uint8>() + 8).cast<Uint64>().value;
      return descriptorDevice == pathDevice && descriptorInode == pathInode;
    } finally {
      _free(descriptorStat);
      _free(pathStat);
    }
  }

  static bool isOwnedByEffectiveUserOrRoot(String path) {
    final statBuffer = _malloc(512);
    if (statBuffer.address == 0) {
      throw StateError('Could not allocate a native stat buffer.');
    }
    try {
      final result = _withNativePath(
        path,
        (nativePath) => _stat(nativePath, statBuffer),
      );
      if (result != 0) return false;
      final uidOffset = switch (Abi.current()) {
        Abi.macosArm64 || Abi.macosX64 => 16,
        Abi.linuxArm64 => 24,
        Abi.linuxX64 => 28,
        _ => -1,
      };
      if (uidOffset < 0) return false;
      final owner = (statBuffer.cast<Uint8>() + uidOffset).cast<Uint32>().value;
      return owner == 0 || owner == _geteuid();
    } finally {
      _free(statBuffer);
    }
  }

  static T _withNativePath<T>(
    String path,
    T Function(Pointer<Char> path) action,
  ) {
    if (path.contains('\u0000')) {
      throw ArgumentError.value(path, 'path', 'Must not contain NUL.');
    }
    final encoded = utf8.encode(path);
    final allocation = _malloc(encoded.length + 1);
    if (allocation.address == 0) {
      throw StateError('Could not allocate a native path buffer.');
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

  static void _requireSupportedPlatform() {
    if (Platform.isMacOS || Platform.isLinux) return;
    throw UnsupportedError(
      'SecureAtomicFile permissions require macOS or Linux.',
    );
  }

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

  static String get _lstatSymbol =>
      Abi.current() == Abi.macosX64 ? r'lstat$INODE64' : 'lstat';

  static String get _statSymbol =>
      Abi.current() == Abi.macosX64 ? r'stat$INODE64' : 'stat';
}

class _SecureAtomicFileCoordinator {
  Future<void> _tail = Future<void>.value();
  int _references = 0;

  void retain() => _references += 1;

  bool release() {
    _references -= 1;
    return _references == 0;
  }

  Future<T> schedule<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }
}
