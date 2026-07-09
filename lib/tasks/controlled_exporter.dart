import 'dart:async';
import 'dart:io';

import 'task_inbox_controller.dart';
import 'task_record.dart';

typedef ControlledExporterClock = DateTime Function();
typedef SimulatedExportExecutor =
    FutureOr<ExportExecutionResult> Function(ExportContext context);

class ControlledExporter {
  ControlledExporter({
    required this.taskController,
    ControlledExporterClock? clock,
    SimulatedExportExecutor? simulatedExecutor,
  }) : _clock = clock ?? DateTime.now,
       _simulatedExecutor = simulatedExecutor ?? _defaultSimulatedExecutor;

  final TaskInboxController taskController;
  final ControlledExporterClock _clock;
  final SimulatedExportExecutor _simulatedExecutor;

  Future<ExportResult> export(String approvalId) async {
    final approval = _approvalById(approvalId);
    if (approval == null) {
      throw ExportException('Approval request not found: $approvalId');
    }
    _validateApprovalIsApprovedExport(approval);
    final task = taskController.taskById(approval.taskId);
    if (task == null) {
      throw ExportException('Task not found: ${approval.taskId}');
    }
    final artifacts = _artifactsForApproval(approval);
    final missingArtifactIds = approval.artifactIds
        .where(
          (artifactId) =>
              !artifacts.any((artifact) => artifact.id == artifactId),
        )
        .toList(growable: false);
    if (missingArtifactIds.isNotEmpty) {
      throw ExportException(
        'Approval references missing artifact(s): ${missingArtifactIds.join(', ')}',
      );
    }
    final unapprovedArtifactIds = artifacts
        .where((artifact) => artifact.status != ArtifactStatus.approved)
        .map((artifact) => artifact.id)
        .toList(growable: false);
    if (unapprovedArtifactIds.isNotEmpty) {
      throw ExportException(
        'Approval references artifact(s) not approved for export: '
        '${unapprovedArtifactIds.join(', ')}',
      );
    }

    final target = approval.target ?? ExportTarget.simulated;
    final startedAt = _clock();
    await taskController.updateTaskStatus(task.id, TaskStatus.exporting);
    await _appendExportEvent(
      task,
      approval,
      'Export started.',
      metadata: <String, Object?>{
        'approval_id': approval.id,
        'target': target.name,
        'artifact_count': artifacts.length,
        'artifact_ids': artifacts.map((artifact) => artifact.id).toList(),
      },
    );

    try {
      final execution = await _executeTarget(
        ExportContext(
          task: taskController.taskById(task.id) ?? task,
          approval: approval,
          artifacts: artifacts,
          startedAt: startedAt,
        ),
        target,
      );
      final endedAt = _clock();
      await taskController.updateArtifactStatuses(
        taskId: task.id,
        artifactIds: artifacts.map((artifact) => artifact.id),
        status: ArtifactStatus.exported,
      );
      await taskController.updateTaskStatus(
        task.id,
        TaskStatus.done,
        summary: execution.message,
        error: null,
      );
      await _appendExportEvent(
        taskController.taskById(task.id) ?? task,
        approval,
        'Export completed.',
        metadata: <String, Object?>{
          'approval_id': approval.id,
          'target': target.name,
          'message': execution.message,
          ...execution.metadata,
        },
      );
      return ExportResult(
        approvalId: approval.id,
        taskId: task.id,
        target: target,
        success: true,
        message: execution.message,
        startedAt: startedAt,
        endedAt: endedAt,
        metadata: execution.metadata,
      );
    } catch (error) {
      final endedAt = _clock();
      final message = _messageForError(error);
      await taskController.updateTask(
        task.id,
        status: TaskStatus.failed,
        error: message,
      );
      await _appendExportEvent(
        taskController.taskById(task.id) ?? task,
        approval,
        'Export failed: $message',
        metadata: <String, Object?>{
          'approval_id': approval.id,
          'target': target.name,
          'error': message,
        },
      );
      return ExportResult(
        approvalId: approval.id,
        taskId: task.id,
        target: target,
        success: false,
        message: message,
        startedAt: startedAt,
        endedAt: endedAt,
      );
    }
  }

  ApprovalRequestRecord? _approvalById(String approvalId) {
    final target = approvalId.trim();
    if (target.isEmpty) return null;
    for (final approval in taskController.approvals) {
      if (approval.id == target) return approval;
    }
    return null;
  }

  void _validateApprovalIsApprovedExport(ApprovalRequestRecord approval) {
    if (approval.kind != ApprovalKind.export) {
      throw ExportException(
        'Approval ${approval.id} is not an export approval.',
      );
    }
    if (approval.status != ApprovalStatus.approved) {
      throw ExportException(
        'Approval ${approval.id} is ${approval.status.name}, not approved.',
      );
    }
  }

  List<ArtifactRecord> _artifactsForApproval(ApprovalRequestRecord approval) {
    if (approval.artifactIds.isEmpty) return const <ArtifactRecord>[];
    return taskController.artifacts
        .where(
          (artifact) =>
              artifact.taskId == approval.taskId &&
              approval.artifactIds.contains(artifact.id),
        )
        .toList(growable: false);
  }

  Future<ExportExecutionResult> _executeTarget(
    ExportContext context,
    ExportTarget target,
  ) async {
    return switch (target) {
      ExportTarget.simulated => _simulatedExecutor(context),
      ExportTarget.gitCommit => _gitCommit(context),
      _ => throw ExportException('Unsupported export target: ${target.name}'),
    };
  }

  Future<ExportExecutionResult> _gitCommit(ExportContext context) async {
    final workspacePath = context.task.workspacePath.trim();
    if (workspacePath.isEmpty || !await Directory(workspacePath).exists()) {
      throw ExportException('Workspace does not exist: $workspacePath');
    }
    await _runGit(workspacePath, ['rev-parse', '--is-inside-work-tree']);
    final statusBeforeAdd = await _runGit(workspacePath, [
      'status',
      '--porcelain',
    ]);
    if (statusBeforeAdd.trim().isEmpty) {
      throw const ExportException('No local changes to commit.');
    }

    await _runGit(workspacePath, ['add', '-A']);
    final statusAfterAdd = await _runGit(workspacePath, [
      'status',
      '--porcelain',
    ]);
    if (statusAfterAdd.trim().isEmpty) {
      throw const ExportException('No staged changes to commit.');
    }

    final message = _commitMessageFor(context);
    await _runGit(workspacePath, [
      '-c',
      'user.name=Ianvs ACP',
      '-c',
      'user.email=ianvs-acp@local.invalid',
      'commit',
      '-m',
      message,
    ]);
    final commit = (await _runGit(workspacePath, ['rev-parse', 'HEAD'])).trim();
    final shortCommit = commit.length > 12 ? commit.substring(0, 12) : commit;
    return ExportExecutionResult(
      message: 'Created git commit $shortCommit.',
      metadata: <String, Object?>{
        'mode': 'git_commit',
        'commit': commit,
        'commit_message': message,
      },
    );
  }

  String _commitMessageFor(ExportContext context) {
    final destination = context.approval.destination?.trim();
    if (destination != null && destination.isNotEmpty) {
      return destination.replaceAll(RegExp(r'\s+'), ' ');
    }
    final title = context.task.title.trim();
    return title.isEmpty
        ? 'Export approved task artifacts'
        : title.replaceAll(RegExp(r'\s+'), ' ');
  }

  Future<String> _runGit(String workingDirectory, List<String> args) async {
    final result = await Process.run(
      'git',
      args,
      workingDirectory: workingDirectory,
    );
    if (result.exitCode != 0) {
      final stderr = (result.stderr as String).trim();
      final stdout = (result.stdout as String).trim();
      final detail = stderr.isNotEmpty ? stderr : stdout;
      throw ExportException(
        detail.isEmpty
            ? 'git ${args.join(' ')} failed.'
            : 'git ${args.join(' ')} failed: $detail',
      );
    }
    return result.stdout as String;
  }

  Future<void> _appendExportEvent(
    TaskRecord task,
    ApprovalRequestRecord approval,
    String text, {
    Map<String, Object?> metadata = const <String, Object?>{},
  }) async {
    final runId = approval.runId ?? task.currentRunId;
    if (runId == null || runId.trim().isEmpty) return;
    final runExists = taskController.runs.any((run) => run.id == runId);
    if (!runExists) return;
    await taskController.appendEvent(
      taskId: task.id,
      runId: runId,
      kind: TaskEventKind.export,
      text: text,
      sessionId: task.sessionId,
      metadata: metadata,
    );
  }

  String _messageForError(Object error) {
    if (error is ExportException) return error.message;
    if (error is StateError) return error.message;
    if (error is Exception) return error.toString();
    return '$error';
  }

  static ExportExecutionResult _defaultSimulatedExecutor(
    ExportContext context,
  ) {
    return ExportExecutionResult(
      message:
          'Simulated export completed for ${context.artifacts.length} artifact(s).',
      metadata: <String, Object?>{'mode': 'simulated'},
    );
  }
}

class ExportContext {
  const ExportContext({
    required this.task,
    required this.approval,
    required this.artifacts,
    required this.startedAt,
  });

  final TaskRecord task;
  final ApprovalRequestRecord approval;
  final List<ArtifactRecord> artifacts;
  final DateTime startedAt;
}

class ExportExecutionResult {
  const ExportExecutionResult({
    required this.message,
    this.metadata = const <String, Object?>{},
  });

  final String message;
  final Map<String, Object?> metadata;
}

class ExportResult {
  const ExportResult({
    required this.approvalId,
    required this.taskId,
    required this.target,
    required this.success,
    required this.message,
    required this.startedAt,
    required this.endedAt,
    this.metadata = const <String, Object?>{},
  });

  final String approvalId;
  final String taskId;
  final ExportTarget target;
  final bool success;
  final String message;
  final DateTime startedAt;
  final DateTime endedAt;
  final Map<String, Object?> metadata;
}

class ExportException implements Exception {
  const ExportException(this.message);

  final String message;

  @override
  String toString() => message;
}
