import 'dart:convert';
import 'dart:io';

import 'task_inbox_snapshot.dart';
import 'task_store.dart';

class TaskInboxSqliteStore implements TaskStore {
  const TaskInboxSqliteStore({
    required this.path,
    this.sqliteExecutable = 'sqlite3',
  });

  static const String fileName = 'task_inbox_state.sqlite3';

  final String? path;
  final String sqliteExecutable;

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
    final databasePath = _pathOrNull();
    if (databasePath == null || !await File(databasePath).exists()) {
      return TaskInboxSnapshot.empty();
    }

    try {
      await _ensureSchema();
      final result = await _runSql(
        'SELECT payload FROM task_inbox_state WHERE id = 1;\n',
      );
      final payload = result.stdout.trim();
      if (payload.isEmpty) return TaskInboxSnapshot.empty();
      return TaskInboxSnapshot.fromJson(jsonDecode(payload));
    } catch (_) {
      return TaskInboxSnapshot.empty();
    }
  }

  @override
  Future<void> save(TaskInboxSnapshot snapshot) async {
    final databasePath = _pathOrNull();
    if (databasePath == null) return;

    await File(databasePath).parent.create(recursive: true);
    final payload = jsonEncode(snapshot.toJson());
    await _runSql('''
$_schemaSql
INSERT OR REPLACE INTO task_inbox_state (id, schema, updated_at, payload)
VALUES (
  1,
  ${_sqlString(TaskInboxSnapshot.schema)},
  ${_sqlString(snapshot.updatedAt.toIso8601String())},
  ${_sqlString(payload)}
);
''');
  }

  Future<void> _ensureSchema() async {
    await _runSql(_schemaSql);
  }

  Future<_SqliteResult> _runSql(String script) async {
    final databasePath = _pathOrNull();
    if (databasePath == null) return const _SqliteResult('', '');
    final process = await Process.start(sqliteExecutable, [databasePath]);
    process.stdin.write(script);
    await process.stdin.close();
    final stdout = process.stdout.transform(utf8.decoder).join();
    final stderr = process.stderr.transform(utf8.decoder).join();
    final exitCode = await process.exitCode;
    final output = await stdout;
    final error = await stderr;
    if (exitCode != 0) {
      throw StateError(
        'sqlite3 failed with exit code $exitCode: ${error.trim()}',
      );
    }
    return _SqliteResult(output, error);
  }

  String? _pathOrNull() {
    final targetPath = path?.trim();
    return targetPath == null || targetPath.isEmpty ? null : targetPath;
  }

  static String _joinPath(String directory, String basename) {
    if (directory.endsWith(Platform.pathSeparator)) {
      return '$directory$basename';
    }
    return '$directory${Platform.pathSeparator}$basename';
  }
}

const String _schemaSql = '''
CREATE TABLE IF NOT EXISTS task_inbox_state (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  schema TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  payload TEXT NOT NULL
);
''';

String _sqlString(String value) {
  return "'${value.replaceAll("'", "''")}'";
}

class _SqliteResult {
  const _SqliteResult(this.stdout, this.stderr);

  final String stdout;
  final String stderr;
}
