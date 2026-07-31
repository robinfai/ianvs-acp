import 'dart:io';

import 'package:path/path.dart' as p;

/// Builds the environment used to launch local ACP agents.
///
/// macOS applications opened from Finder inherit a small system `PATH`, rather
/// than the PATH configured by the user's interactive shell. This is especially
/// easy to miss for commands such as `npx`: the configured executable may be an
/// absolute path, while its `#!/usr/bin/env node` interpreter still depends on
/// PATH.
class AgentProcessEnvironment {
  const AgentProcessEnvironment._();

  static Map<String, String> resolve({
    required String command,
    Map<String, String> overrides = const <String, String>{},
    Map<String, String>? inherited,
  }) {
    if (overrides.containsKey('PATH') || Platform.isWindows) {
      return overrides;
    }

    final base = inherited ?? Platform.environment;
    final directories = <String>[];

    void add(String? directory) {
      final trimmed = directory?.trim();
      if (trimmed == null || trimmed.isEmpty || directories.contains(trimmed)) {
        return;
      }
      directories.add(trimmed);
    }

    final trimmedCommand = command.trim();
    if (trimmedCommand.isNotEmpty && p.isAbsolute(trimmedCommand)) {
      add(p.dirname(trimmedCommand));
      try {
        add(p.dirname(File(trimmedCommand).resolveSymbolicLinksSync()));
      } on FileSystemException {
        // Keep the configured path. Rust will surface a precise spawn error if
        // the executable itself does not exist.
      }
    }

    final home = base['HOME']?.trim();
    if (home != null && home.isNotEmpty) {
      add(p.join(home, '.local', 'bin'));
      add(p.join(home, '.cargo', 'bin'));
    }

    for (final directory in const <String>[
      '/opt/homebrew/bin',
      '/usr/local/bin',
    ]) {
      add(directory);
    }
    for (final directory in (base['PATH'] ?? '').split(':')) {
      add(directory);
    }
    for (final directory in const <String>[
      '/usr/bin',
      '/bin',
      '/usr/sbin',
      '/sbin',
    ]) {
      add(directory);
    }

    if (directories.isEmpty) return overrides;
    return <String, String>{...overrides, 'PATH': directories.join(':')};
  }
}
