import 'dart:convert';
import 'dart:io';

import 'task_inbox_snapshot.dart';
import 'task_store.dart';

class TaskInboxStateStore implements TaskStore {
  const TaskInboxStateStore({required this.path});

  static const String fileName = 'task_inbox_state.json';

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

  @override
  Future<TaskInboxSnapshot> load() async {
    final file = _fileOrNull();
    if (file == null || !await file.exists()) {
      return TaskInboxSnapshot.empty();
    }

    try {
      final decoded = jsonDecode(await file.readAsString());
      return TaskInboxSnapshot.fromJson(decoded);
    } catch (_) {
      return TaskInboxSnapshot.empty();
    }
  }

  @override
  Future<void> save(TaskInboxSnapshot snapshot) async {
    final file = _fileOrNull();
    if (file == null) return;

    const encoder = JsonEncoder.withIndent('  ');
    await file.parent.create(recursive: true);
    await file.writeAsString('${encoder.convert(snapshot.toJson())}\n');
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
