import 'dart:io';
import 'package:path/path.dart' as p;

/// Resolver that enforces that paths remain within a workspace root.
class WorkspaceJail {
  /// Create a jail rooted at [workspaceRoot].
  WorkspaceJail({required this.workspaceRoot}) {
    if (!p.isAbsolute(workspaceRoot)) {
      throw ArgumentError('workspaceRoot must be absolute: $workspaceRoot');
    }
  }

  /// Canonical workspace root.
  final String workspaceRoot;

  /// Resolve a path relative to [workspaceRoot] if needed and ensure it
  /// remains within the workspace. Throws [FileSystemException] if outside.
  Future<String> resolveAndEnsureWithin(String path) async {
    final joined = p.isAbsolute(path) ? path : p.join(workspaceRoot, path);
    final canonical = await _canonicalize(joined);
    final rootCanonical = await _canonicalize(workspaceRoot);
    if (!_isWithin(canonical, rootCanonical)) {
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
    final rootCanonical = await _canonicalize(workspaceRoot);
    return _isWithin(canonical, rootCanonical);
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
