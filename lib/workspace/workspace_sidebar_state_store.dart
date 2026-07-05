import 'dart:convert';
import 'dart:io';

class WorkspaceSidebarStateStore {
  const WorkspaceSidebarStateStore({required this.path});

  static const String fileName = 'workspace_ui_state.json';

  final String? path;

  static String? defaultPath({
    String? configPath,
    Map<String, String>? environment,
  }) {
    final config = configPath?.trim();
    if (config != null && config.isNotEmpty) {
      return _joinPath(File(config).parent.path, fileName);
    }

    final env = environment ?? Platform.environment;
    final xdgConfigHome = env['XDG_CONFIG_HOME']?.trim();
    if (xdgConfigHome != null && xdgConfigHome.isNotEmpty) {
      return _joinPath(_joinPath(xdgConfigHome, 'ianvs-acp'), fileName);
    }

    final home = env['HOME']?.trim();
    if (home == null || home.isEmpty) return null;
    return _joinPath(
      _joinPath(_joinPath(home, '.config'), 'ianvs-acp'),
      fileName,
    );
  }

  Future<Set<String>> loadExpandedWorkspacePaths() async {
    final file = _fileOrNull();
    if (file == null || !await file.exists()) return <String>{};

    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, Object?>) return <String>{};
      final rawPaths =
          decoded['expanded_workspaces'] ?? decoded['expandedWorkspacePaths'];
      if (rawPaths is! List) return <String>{};
      return rawPaths
          .whereType<String>()
          .map((path) => path.trim())
          .where((path) => path.isNotEmpty)
          .toSet();
    } catch (_) {
      return <String>{};
    }
  }

  Future<void> saveExpandedWorkspacePaths(Set<String> paths) async {
    final file = _fileOrNull();
    if (file == null) return;

    final sortedPaths =
        paths
            .map((path) => path.trim())
            .where((path) => path.isNotEmpty)
            .toSet()
            .toList()
          ..sort();
    final payload = <String, Object?>{'expanded_workspaces': sortedPaths};
    const encoder = JsonEncoder.withIndent('  ');

    await file.parent.create(recursive: true);
    await file.writeAsString('${encoder.convert(payload)}\n');
  }

  File? _fileOrNull() {
    final targetPath = path?.trim();
    if (targetPath == null || targetPath.isEmpty) return null;
    return File(targetPath);
  }

  static String _joinPath(String directory, String basename) {
    if (directory.endsWith(Platform.pathSeparator)) {
      return '$directory$basename';
    }
    return '$directory${Platform.pathSeparator}$basename';
  }
}
