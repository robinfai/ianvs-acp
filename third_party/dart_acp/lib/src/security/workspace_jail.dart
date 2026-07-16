import 'dart:io';
import 'package:path/path.dart' as p;

final class SecureWriteResolution {
  const SecureWriteResolution({
    required this.canonicalRoot,
    required this.relativePath,
  });

  final String canonicalRoot;
  final String relativePath;
}

/// Resolver that enforces that paths remain within a workspace root.
class WorkspaceJail {
  /// Create a jail rooted at [workspaceRoot].
  WorkspaceJail({
    required this.workspaceRoot,
    List<String> additionalWorkspaceRoots = const <String>[],
  }) : additionalWorkspaceRoots = List.unmodifiable(
         additionalWorkspaceRoots.where((root) => root.trim().isNotEmpty),
       ) {
    if (!p.isAbsolute(workspaceRoot)) {
      throw ArgumentError('workspaceRoot must be absolute: $workspaceRoot');
    }
    for (final root in this.additionalWorkspaceRoots) {
      if (!p.isAbsolute(root)) {
        throw ArgumentError(
          'additional workspace root must be absolute: $root',
        );
      }
    }
  }

  /// Canonical workspace root.
  final String workspaceRoot;

  /// Additional workspace roots allowed by the session.
  final List<String> additionalWorkspaceRoots;

  /// Resolve a writable target into an already-canonical root and a relative
  /// path. Existing links are followed only while resolving the target; the
  /// native writer receives no absolute target path.
  Future<SecureWriteResolution> resolveForSecureWrite(String path) async {
    if (path.isEmpty || path.contains('\u0000')) {
      throw const FileSystemException('Secure write path is invalid');
    }
    final configuredRoots = <String>[
      workspaceRoot,
      ...additionalWorkspaceRoots,
    ];
    final normalizedConfiguredRoots = configuredRoots
        .map((root) => p.normalize(p.absolute(root)))
        .toList(growable: false);
    late final String joined;
    if (p.isAbsolute(path)) {
      joined = p.normalize(path);
      if (!normalizedConfiguredRoots.any(
        (root) => joined == root || p.isWithin(root, joined),
      )) {
        throw const FileSystemException('Access outside workspace is denied');
      }
    } else {
      joined = p.normalize(p.join(workspaceRoot, path));
      final normalizedMainRoot = normalizedConfiguredRoots.first;
      if (joined != normalizedMainRoot &&
          !p.isWithin(normalizedMainRoot, joined)) {
        throw const FileSystemException('Access outside workspace is denied');
      }
    }

    final canonicalRoots = <String>[];
    for (final configuredRoot in configuredRoots) {
      try {
        canonicalRoots.add(
          p.normalize(await Directory(configuredRoot).resolveSymbolicLinks()),
        );
      } on Object {
        throw const FileSystemException('Workspace root is unavailable');
      }
    }
    final canonicalTarget = await _canonicalizeForSecureWrite(joined);
    String? selectedRoot;
    for (final canonicalRoot in canonicalRoots) {
      if (canonicalTarget != canonicalRoot &&
          !p.isWithin(canonicalRoot, canonicalTarget)) {
        continue;
      }
      if (selectedRoot == null || canonicalRoot.length > selectedRoot.length) {
        selectedRoot = canonicalRoot;
      }
    }
    if (selectedRoot == null) {
      throw const FileSystemException('Access outside workspace is denied');
    }
    final relativePath = p.relative(canonicalTarget, from: selectedRoot);
    if (relativePath == '.' ||
        p.isAbsolute(relativePath) ||
        relativePath.split(p.separator).contains('..')) {
      throw const FileSystemException('Secure write path is invalid');
    }
    return SecureWriteResolution(
      canonicalRoot: selectedRoot,
      relativePath: relativePath,
    );
  }

  /// Resolve a path relative to [workspaceRoot] if needed and ensure it
  /// remains within the workspace. Throws [FileSystemException] if outside.
  Future<String> resolveAndEnsureWithin(String path) async {
    final joined = p.isAbsolute(path) ? path : p.join(workspaceRoot, path);
    final canonical = await _canonicalize(joined);
    if (!await _isWithinAnyWorkspaceRoot(canonical)) {
      throw FileSystemException(
        'Access outside workspace is denied',
        canonical,
      );
    }
    return canonical;
  }

  /// Resolve path relative to workspace if relative, but do not enforce
  /// workspace boundary. Useful for read-anywhere modes.
  Future<String> resolveForgiving(String path) async {
    final joined = p.isAbsolute(path) ? path : p.join(workspaceRoot, path);
    return _canonicalize(joined);
  }

  /// Return true if [path] is within the workspace root.
  Future<bool> isWithinWorkspace(String path) async {
    final canonical = await _canonicalize(path);
    return _isWithinAnyWorkspaceRoot(canonical);
  }

  Future<bool> _isWithinAnyWorkspaceRoot(String canonicalPath) async {
    for (final root in [workspaceRoot, ...additionalWorkspaceRoots]) {
      final rootCanonical = await _canonicalize(root);
      if (_isWithin(canonicalPath, rootCanonical)) return true;
    }
    return false;
  }

  bool _isWithin(String path, String root) {
    final normPath = p.normalize(path);
    final normRoot = p.normalize(root);
    return p.isWithin(normRoot, normPath) || normPath == normRoot;
  }

  Future<String> _canonicalize(String path) async {
    try {
      final link = File(path);
      return await link.resolveSymbolicLinks();
    } on Object catch (_) {
      // If file doesn't exist yet, canonicalize parent and append basename
      final dir = Directory(p.dirname(path));
      final base = p.basename(path);
      try {
        final parent = await dir.resolveSymbolicLinks();
        return p.join(parent, base);
      } on Object catch (_) {
        // Fall back to normalized absolute path
        return p.normalize(p.absolute(path));
      }
    }
  }

  Future<String> _canonicalizeForSecureWrite(String path) async {
    var current = p.normalize(p.absolute(path));
    final missingSegments = <String>[];
    while (true) {
      final type = await FileSystemEntity.type(current, followLinks: false);
      if (type != FileSystemEntityType.notFound) {
        late final String canonicalAncestor;
        try {
          canonicalAncestor = await File(current).resolveSymbolicLinks();
        } on Object {
          throw const FileSystemException('Secure write path is unavailable');
        }
        var resolved = p.normalize(canonicalAncestor);
        for (final segment in missingSegments.reversed) {
          resolved = p.join(resolved, segment);
        }
        return p.normalize(resolved);
      }
      final parent = p.dirname(current);
      if (parent == current) {
        throw const FileSystemException('Secure write path is unavailable');
      }
      missingSegments.add(p.basename(current));
      current = parent;
    }
  }
}
