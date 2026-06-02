import 'dart:io';
import 'package:path/path.dart' as p;

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
}
