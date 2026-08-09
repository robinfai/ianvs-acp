import 'dart:io';

/// Resolves a file inside the app-owned state directory without requiring the
/// directory or file to exist yet.
String? resolveAppStateFilePath({
  required String fileName,
  String? configPath,
  Map<String, String>? environment,
}) {
  final config = configPath?.trim();
  if (config != null && config.isNotEmpty) {
    final configDirectory = File.fromUri(
      File(config).absolute.uri.normalizePath(),
    ).parent;
    final stateDirectory = _isAppOwnedStateDirectory(configDirectory)
        ? configDirectory.path
        : _joinPath(configDirectory.path, '.ianvs-acp');
    return _joinPath(stateDirectory, fileName);
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

String _joinPath(String directory, String basename) {
  if (directory.endsWith(Platform.pathSeparator)) {
    return '$directory$basename';
  }
  return '$directory${Platform.pathSeparator}$basename';
}

bool _isAppOwnedStateDirectory(Directory directory) {
  final segments = directory.uri.pathSegments
      .where((segment) => segment.isNotEmpty)
      .toList(growable: false);
  if (segments.isEmpty) return false;
  final name = segments.last.toLowerCase();
  return name == 'ianvs-acp' || name == '.ianvs-acp';
}
