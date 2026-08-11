import 'dart:io';

/// Resolves a file inside the app-owned state directory without requiring the
/// directory or file to exist yet.
String? resolveAppStateFilePath({
  required String fileName,
  String? configPath,
  Map<String, String>? environment,
}) {
  final stateDirectory = resolveAppStateDirectoryPath(
    configPath: configPath,
    environment: environment,
  );
  if (stateDirectory == null) return null;
  return _joinPath(stateDirectory, fileName);
}

/// Resolves the app-owned state directory without creating or modifying it.
String? resolveAppStateDirectoryPath({
  String? configPath,
  Map<String, String>? environment,
}) {
  final config = configPath?.trim();
  if (config != null && config.isNotEmpty) {
    final configDirectory = File.fromUri(
      File(config).absolute.uri.normalizePath(),
    ).parent;
    return _isAppOwnedStateDirectory(configDirectory)
        ? configDirectory.path
        : _joinPath(configDirectory.path, '.ianvs-acp');
  }

  final env = environment ?? Platform.environment;
  final xdgConfigHome = env['XDG_CONFIG_HOME']?.trim();
  if (xdgConfigHome != null && xdgConfigHome.isNotEmpty) {
    return _joinPath(xdgConfigHome, 'ianvs-acp');
  }

  final home = env['HOME']?.trim();
  if (home == null || home.isEmpty) return null;
  return _joinPath(_joinPath(home, '.config'), 'ianvs-acp');
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
