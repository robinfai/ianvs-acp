import 'dart:io';
import 'package:path/path.dart' as p;
import '../security/workspace_jail.dart';

/// Abstraction for file system operations exposed to agents.
abstract class FsProvider {
  /// Read a text file; `line` and `limit` constrain the range.
  Future<String> readTextFile(String path, {int? line, int? limit});

  /// Write text content to a file (within workspace jail).
  Future<void> writeTextFile(String path, String content);
}

/// Default implementation enforcing a workspace jail.
class DefaultFsProvider implements FsProvider {
  /// Create a default file system provider with a workspace jail.
  DefaultFsProvider({
    required this.workspaceRoot,
    this.allowReadOutsideWorkspace = false,
  }) : _jail = WorkspaceJail(workspaceRoot: workspaceRoot);

  /// Workspace root directory.
  final String workspaceRoot;
  final WorkspaceJail _jail;

  /// When true, allow reads outside the workspace root (writes still denied).
  final bool allowReadOutsideWorkspace;

  // Writes outside the workspace are never allowed.

  @override
  Future<String> readTextFile(String path, {int? line, int? limit}) async {
    final filePath = allowReadOutsideWorkspace
        ? await _jail.resolveForgiving(path)
        : await _jail.resolveAndEnsureWithin(path);
    final file = File(filePath);
    if (!file.existsSync()) {
      throw FileSystemException('File not found', filePath);
    }
    final content = file.readAsStringSync();
    if (line == null && limit == null) return content;

    final lines = content.split('\n');
    // Interpret line as 1-based starting line and limit as number of lines.
    if (line != null) {
      final start = (line - 1).clamp(0, lines.length);
      final end = limit == null
          ? lines.length
          : (start + limit).clamp(0, lines.length);
      return lines.sublist(start, end).join('\n');
    }
    // limit only: return first N lines
    return lines.take(limit!).join('\n');
  }

  @override
  Future<void> writeTextFile(String path, String content) async {
    // Writes must stay within the workspace (never allowed outside).
    final canonical = await _jail.resolveForgiving(path);
    if (!await _jail.isWithinWorkspace(canonical)) {
      throw FileSystemException(
        'Write denied: path is outside the workspace root. '
        'Please write within the project directory or adjust the path.',
        canonical,
      );
    }
    final filePath = canonical;
    final dir = Directory(p.dirname(filePath));
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    final file = File(filePath);
    file.writeAsStringSync(content);
  }
}
