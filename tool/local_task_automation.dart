import 'dart:convert';
import 'dart:io';

import 'package:ianvs_acp/tasks/task_inbox_snapshot.dart';
import 'package:ianvs_acp/tasks/task_inbox_state_store.dart';
import 'package:ianvs_acp/tasks/task_record.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty || args.first == '--help' || args.first == '-h') {
    _printUsage();
    return;
  }
  final command = args.first;
  final options = _CliOptions(args.skip(1).toList(growable: false));
  try {
    switch (command) {
      case 'create-task':
        await _createTask(options);
      default:
        stderr.writeln('Unsupported command: $command');
        _printUsage();
        exitCode = 64;
    }
  } on _CliUsageException {
    _printUsage();
  }
}

Future<void> _createTask(_CliOptions options) async {
  final title = options.requiredValue('--title');
  final workspacePath = options.requiredValue('--workspace');
  final agentName = options.value('--agent') ?? 'Codex';
  final description = options.value('--description') ?? '';
  final statePath =
      options.value('--state') ?? TaskInboxStateStore.defaultPath();
  final priority = _priorityFromText(options.value('--priority'));
  final trigger = _triggerText(options.value('--trigger'));
  final skillIds = options.values('--skill');
  if (statePath == null || statePath.trim().isEmpty) {
    stderr.writeln('Missing task inbox state path. Pass --state path.');
    exitCode = 64;
    throw const _CliUsageException();
  }

  final store = TaskInboxStateStore(path: statePath);
  final snapshot = await store.load();
  final now = DateTime.now();
  final task = TaskRecord(
    id: _nextId('task', snapshot),
    title: title,
    description: description.trim(),
    workspacePath: workspacePath.trim(),
    agentName: agentName.trim(),
    status: options.flag('--queued') ? TaskStatus.queued : TaskStatus.inbox,
    priority: priority,
    createdAt: now,
    updatedAt: now,
    skillIds: skillIds,
    summary: options.flag('--queued')
        ? 'Queued by local CLI automation.'
        : null,
    metadata: <String, Object?>{
      'source': 'cli',
      'autopilot_trigger': trigger,
      'run_only': false,
    },
  );
  await store.save(
    snapshot.copyWith(tasks: [...snapshot.tasks, task], updatedAt: now),
  );
  stdout.writeln(jsonEncode(task.toJson()));
}

TaskPriority _priorityFromText(String? raw) {
  return switch (raw?.trim().toLowerCase()) {
    'low' => TaskPriority.low,
    'high' => TaskPriority.high,
    'urgent' => TaskPriority.urgent,
    _ => TaskPriority.normal,
  };
}

String _triggerText(String? raw) {
  return switch (raw?.trim().toLowerCase().replaceAll('-', '_')) {
    'cron' => 'cron',
    'local_webhook' => 'local_webhook',
    _ => 'manual',
  };
}

String _nextId(String prefix, TaskInboxSnapshot snapshot) {
  final existingIds = <String>{
    for (final task in snapshot.tasks) task.id,
    for (final run in snapshot.runs) run.id,
    for (final event in snapshot.events) event.id,
    for (final artifact in snapshot.artifacts) artifact.id,
    for (final approval in snapshot.approvals) approval.id,
    for (final resource in snapshot.resources) resource.id,
  };
  for (var index = 1; index < 100000; index += 1) {
    final id = '$prefix-${DateTime.now().microsecondsSinceEpoch}-$index';
    if (!existingIds.contains(id)) return id;
  }
  throw StateError('Could not allocate task id.');
}

void _printUsage() {
  stdout.writeln('''
Usage:
  dart run tool/local_task_automation.dart create-task \\
    --title "Run checks" \\
    --workspace /path/to/workspace \\
    [--agent Codex] [--description "..."] [--priority normal] \\
    [--skill skill-id] [--queued] [--trigger manual] [--state path]

This local tool only creates inbox tasks. It does not run agents or export data.
''');
}

class _CliOptions {
  _CliOptions(this.args);

  final List<String> args;

  bool flag(String name) => args.contains(name);

  String requiredValue(String name) {
    final result = value(name);
    if (result == null || result.isEmpty) {
      stderr.writeln('Missing required option: $name');
      exitCode = 64;
      throw const _CliUsageException();
    }
    return result;
  }

  String? value(String name) {
    final index = args.indexOf(name);
    if (index < 0 || index + 1 >= args.length) return null;
    final candidate = args[index + 1];
    return candidate.startsWith('--') ? null : candidate;
  }

  List<String> values(String name) {
    final values = <String>[];
    for (var index = 0; index < args.length; index += 1) {
      if (args[index] != name || index + 1 >= args.length) continue;
      final candidate = args[index + 1];
      if (!candidate.startsWith('--') && candidate.trim().isNotEmpty) {
        values.add(candidate.trim());
      }
    }
    return List.unmodifiable(values);
  }
}

class _CliUsageException implements Exception {
  const _CliUsageException();
}
