import 'dart:async';

import 'package:flutter/material.dart';

import '../../tasks/task_inbox_controller.dart';
import '../../tasks/task_record.dart';
import '../../workspace/workspace.dart';
import '../theme/app_design_tokens.dart';
import 'task_editor_dialog.dart';
import 'task_status_badge.dart';

class TaskInboxSidebar extends StatefulWidget {
  const TaskInboxSidebar({
    super.key,
    required this.controller,
    required this.defaultWorkspacePath,
    required this.defaultAgentName,
    this.agentNames = const <String>[],
    this.selectedTaskId,
    this.onRunTask,
    this.onOpenLinkedSession,
  });

  final TaskInboxController controller;
  final String defaultWorkspacePath;
  final String defaultAgentName;
  final List<String> agentNames;
  final String? selectedTaskId;
  final FutureOr<void> Function(TaskRecord task)? onRunTask;
  final ValueChanged<TaskRecord>? onOpenLinkedSession;

  @override
  State<TaskInboxSidebar> createState() => _TaskInboxSidebarState();
}

class _TaskInboxSidebarState extends State<TaskInboxSidebar> {
  String? _selectedTaskId;
  final Set<String> _runningTaskIds = <String>{};

  @override
  void initState() {
    super.initState();
    _selectedTaskId = _trimmedOrNull(widget.selectedTaskId);
  }

  @override
  void didUpdateWidget(covariant TaskInboxSidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    final selectedTaskId = _trimmedOrNull(widget.selectedTaskId);
    if (selectedTaskId != null && selectedTaskId != _selectedTaskId) {
      _selectedTaskId = selectedTaskId;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.surfaceRaised,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 10, 7),
            child: Row(
              children: [
                Text(
                  'Inbox',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: AppColors.textPrimary,
                    letterSpacing: 0,
                  ),
                ),
                const Spacer(),
                _SidebarIconButton(
                  icon: Icons.add_task_rounded,
                  tooltip: 'New task',
                  onPressed: () => unawaited(_showNewTaskDialog(context)),
                ),
              ],
            ),
          ),
          Expanded(
            child: AnimatedBuilder(
              animation: widget.controller,
              builder: (context, _) {
                final groups = _groups(widget.controller.tasks);
                final artifactsByTask = _artifactsByTask(
                  widget.controller.artifacts,
                );
                final hasTasks = groups.any((group) => group.tasks.isNotEmpty);
                if (!hasTasks) {
                  return const _EmptyTaskInbox();
                }
                return ListView.separated(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
                  itemBuilder: (context, index) {
                    final group = groups[index];
                    if (group.tasks.isEmpty) return const SizedBox.shrink();
                    return _TaskStatusGroup(
                      group: group,
                      selectedTaskId: _selectedTaskId,
                      runningTaskIds: _runningTaskIds,
                      artifactsByTask: artifactsByTask,
                      onSelectTask: (task) {
                        setState(() => _selectedTaskId = task.id);
                      },
                      onRunTask: widget.onRunTask == null ? null : _runTask,
                      onOpenLinkedSession: widget.onOpenLinkedSession,
                      onMarkDoneLocally: _markDoneLocally,
                      onRequestChanges: _requestChanges,
                      onRejectTask: _rejectTask,
                    );
                  },
                  separatorBuilder: (context, index) {
                    return groups[index].tasks.isEmpty
                        ? const SizedBox.shrink()
                        : const SizedBox(height: 10);
                  },
                  itemCount: groups.length,
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showNewTaskDialog(BuildContext context) async {
    final draft = await showDialog<TaskDraft>(
      context: context,
      builder: (context) {
        return TaskEditorDialog(
          initialWorkspacePath: widget.defaultWorkspacePath,
          initialAgentName: widget.defaultAgentName,
          agentNames: widget.agentNames,
        );
      },
    );
    if (draft == null) return;
    try {
      final task = await widget.controller.createTask(
        title: draft.title,
        description: draft.description,
        workspacePath: draft.workspacePath,
        agentName: draft.agentName,
        priority: draft.priority,
      );
      if (!mounted) return;
      setState(() => _selectedTaskId = task.id);
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text('Could not create task: $error')));
    }
  }

  Future<void> _runTask(TaskRecord task) async {
    final runTask = widget.onRunTask;
    if (runTask == null || _runningTaskIds.contains(task.id)) return;
    setState(() {
      _selectedTaskId = task.id;
      _runningTaskIds.add(task.id);
    });
    try {
      await runTask(task);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text('Could not run task: $error')));
    } finally {
      if (mounted) {
        setState(() => _runningTaskIds.remove(task.id));
      }
    }
  }

  Future<void> _markDoneLocally(TaskRecord task) async {
    await _runReviewAction(
      () => widget.controller.markTaskDoneLocally(task.id),
      failureLabel: 'mark task done locally',
    );
  }

  Future<void> _requestChanges(TaskRecord task) async {
    await _runReviewAction(
      () => widget.controller.requestTaskChanges(task.id),
      failureLabel: 'request changes',
    );
  }

  Future<void> _rejectTask(TaskRecord task) async {
    await _runReviewAction(
      () => widget.controller.rejectTask(task.id),
      failureLabel: 'reject task',
    );
  }

  Future<void> _runReviewAction(
    Future<void> Function() action, {
    required String failureLabel,
  }) async {
    try {
      await action();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text('Could not $failureLabel: $error')),
      );
    }
  }
}

String? _trimmedOrNull(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

class _TaskStatusGroup extends StatelessWidget {
  const _TaskStatusGroup({
    required this.group,
    required this.selectedTaskId,
    required this.runningTaskIds,
    required this.artifactsByTask,
    required this.onSelectTask,
    required this.onMarkDoneLocally,
    required this.onRequestChanges,
    required this.onRejectTask,
    this.onRunTask,
    this.onOpenLinkedSession,
  });

  final _TaskGroup group;
  final String? selectedTaskId;
  final Set<String> runningTaskIds;
  final Map<String, List<ArtifactRecord>> artifactsByTask;
  final ValueChanged<TaskRecord> onSelectTask;
  final FutureOr<void> Function(TaskRecord task) onMarkDoneLocally;
  final FutureOr<void> Function(TaskRecord task) onRequestChanges;
  final FutureOr<void> Function(TaskRecord task) onRejectTask;
  final FutureOr<void> Function(TaskRecord task)? onRunTask;
  final ValueChanged<TaskRecord>? onOpenLinkedSession;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 5, 4, 6),
          child: Row(
            children: [
              Text(
                group.title,
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '${group.tasks.length}',
                style: const TextStyle(
                  color: AppColors.textTertiary,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0,
                ),
              ),
            ],
          ),
        ),
        for (final task in group.tasks) ...[
          _TaskTile(
            task: task,
            selected: task.id == selectedTaskId,
            running: runningTaskIds.contains(task.id),
            artifacts: artifactsByTask[task.id] ?? const <ArtifactRecord>[],
            onTap: () => onSelectTask(task),
            onRunTask: onRunTask,
            onOpenLinkedSession: onOpenLinkedSession,
            onMarkDoneLocally: onMarkDoneLocally,
            onRequestChanges: onRequestChanges,
            onRejectTask: onRejectTask,
          ),
          if (task != group.tasks.last) const SizedBox(height: 6),
        ],
      ],
    );
  }
}

class _TaskTile extends StatelessWidget {
  const _TaskTile({
    required this.task,
    required this.selected,
    required this.running,
    required this.artifacts,
    required this.onTap,
    this.onRunTask,
    this.onOpenLinkedSession,
    required this.onMarkDoneLocally,
    required this.onRequestChanges,
    required this.onRejectTask,
  });

  final TaskRecord task;
  final bool selected;
  final bool running;
  final List<ArtifactRecord> artifacts;
  final VoidCallback onTap;
  final FutureOr<void> Function(TaskRecord task)? onRunTask;
  final ValueChanged<TaskRecord>? onOpenLinkedSession;
  final FutureOr<void> Function(TaskRecord task) onMarkDoneLocally;
  final FutureOr<void> Function(TaskRecord task) onRequestChanges;
  final FutureOr<void> Function(TaskRecord task) onRejectTask;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(9),
          decoration: BoxDecoration(
            color: selected ? AppColors.primaryMist : AppColors.surface,
            borderRadius: BorderRadius.circular(AppRadius.sm),
            border: Border.all(
              color: selected ? AppColors.primarySoft : AppColors.borderSoft,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      task.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  TaskStatusBadge(status: task.status),
                ],
              ),
              const SizedBox(height: 7),
              Row(
                children: [
                  const Icon(
                    Icons.folder_open_rounded,
                    size: 14,
                    color: AppColors.textTertiary,
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      workspaceNameFromPath(task.workspacePath),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 5),
              Row(
                children: [
                  const Icon(
                    Icons.smart_toy_outlined,
                    size: 14,
                    color: AppColors.textTertiary,
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      task.agentName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _priorityLabel(task.priority),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.textTertiary,
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0,
                    ),
                  ),
                ],
              ),
              if (_skillSummary(task) != null) ...[
                const SizedBox(height: 5),
                Row(
                  children: [
                    const Icon(
                      Icons.school_outlined,
                      size: 14,
                      color: AppColors.textTertiary,
                    ),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text(
                        _skillSummary(task)!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              if (task.summary != null && task.summary!.trim().isNotEmpty) ...[
                const SizedBox(height: 7),
                Text(
                  task.summary!.trim(),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0,
                  ),
                ),
              ],
              const SizedBox(height: 8),
              Row(
                children: [
                  _TileActionButton(
                    icon: running
                        ? Icons.hourglass_top_rounded
                        : Icons.play_arrow_rounded,
                    tooltip: 'Run task',
                    onPressed: _canRun
                        ? () {
                            unawaited(
                              Future<void>.sync(() => onRunTask!(task)),
                            );
                          }
                        : null,
                  ),
                  const SizedBox(width: 6),
                  _TileActionButton(
                    icon: Icons.open_in_new_rounded,
                    tooltip: 'Open linked session',
                    onPressed: _canOpenLinkedSession
                        ? () => onOpenLinkedSession!(task)
                        : null,
                  ),
                ],
              ),
              if (selected && artifacts.isNotEmpty) ...[
                const SizedBox(height: 8),
                _ArtifactPreviewList(artifacts: artifacts),
              ],
              if (selected && _canReview) ...[
                const SizedBox(height: 8),
                _ReviewActionPanel(
                  onMarkDoneLocally: () => onMarkDoneLocally(task),
                  onRequestChanges: () => onRequestChanges(task),
                  onRejectTask: () => onRejectTask(task),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  bool get _canRun {
    if (running || onRunTask == null) return false;
    return switch (task.status) {
      TaskStatus.inbox ||
      TaskStatus.queued ||
      TaskStatus.failed ||
      TaskStatus.needsChanges => true,
      _ => false,
    };
  }

  bool get _canOpenLinkedSession {
    return onOpenLinkedSession != null &&
        task.sessionId != null &&
        task.sessionId!.trim().isNotEmpty;
  }

  bool get _canReview =>
      task.status == TaskStatus.needsHumanReview ||
      task.status == TaskStatus.approvedForExport ||
      task.status == TaskStatus.exporting;
}

class _ReviewActionPanel extends StatelessWidget {
  const _ReviewActionPanel({
    required this.onMarkDoneLocally,
    required this.onRequestChanges,
    required this.onRejectTask,
  });

  final FutureOr<void> Function() onMarkDoneLocally;
  final FutureOr<void> Function() onRequestChanges;
  final FutureOr<void> Function() onRejectTask;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.borderSoft)),
      ),
      child: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            OutlinedButton.icon(
              key: const Key('task-mark-done-locally-button'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(32),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
              ),
              onPressed: () => unawaited(Future<void>.sync(onMarkDoneLocally)),
              icon: const Icon(Icons.check_circle_outline, size: 15),
              label: const Text('Mark Done Locally'),
            ),
            const SizedBox(height: 6),
            OutlinedButton.icon(
              key: const Key('task-request-changes-button'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(32),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
              ),
              onPressed: () => unawaited(Future<void>.sync(onRequestChanges)),
              icon: const Icon(Icons.edit_note_outlined, size: 15),
              label: const Text('Request Changes'),
            ),
            const SizedBox(height: 6),
            OutlinedButton.icon(
              key: const Key('task-reject-button'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(32),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                foregroundColor: AppColors.danger,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
              ),
              onPressed: () => unawaited(Future<void>.sync(onRejectTask)),
              icon: const Icon(Icons.block_outlined, size: 15),
              label: const Text('Reject'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ArtifactPreviewList extends StatelessWidget {
  const _ArtifactPreviewList({required this.artifacts});

  final List<ArtifactRecord> artifacts;

  @override
  Widget build(BuildContext context) {
    final visible = artifacts.take(3).toList(growable: false);
    return DecoratedBox(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.borderSoft)),
      ),
      child: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.article_outlined,
                  size: 14,
                  color: AppColors.textTertiary,
                ),
                const SizedBox(width: 5),
                Text(
                  'Artifacts ${artifacts.length}',
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 11,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            for (final artifact in visible) ...[
              _ArtifactPreviewItem(artifact: artifact),
              if (artifact != visible.last) const SizedBox(height: 6),
            ],
            if (artifacts.length > visible.length) ...[
              const SizedBox(height: 5),
              Text(
                '+${artifacts.length - visible.length} more',
                style: const TextStyle(
                  color: AppColors.textTertiary,
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ArtifactPreviewItem extends StatelessWidget {
  const _ArtifactPreviewItem({required this.artifact});

  final ArtifactRecord artifact;

  @override
  Widget build(BuildContext context) {
    final preview = artifact.contentPreview?.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(_iconForArtifact(artifact.kind), size: 13),
            const SizedBox(width: 5),
            Expanded(
              child: Text(
                artifact.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0,
                ),
              ),
            ),
          ],
        ),
        if (preview != null && preview.isNotEmpty) ...[
          const SizedBox(height: 3),
          Text(
            preview,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 10,
              height: 1.25,
              fontFamily: 'monospace',
              letterSpacing: 0,
            ),
          ),
        ],
      ],
    );
  }
}

class _TileActionButton extends StatelessWidget {
  const _TileActionButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: IconButton(
        visualDensity: VisualDensity.compact,
        style: IconButton.styleFrom(
          fixedSize: const Size.square(28),
          backgroundColor: AppColors.surfaceRaised,
          foregroundColor: AppColors.textSecondary,
          disabledForegroundColor: AppColors.textTertiary,
          side: const BorderSide(color: AppColors.borderSoft),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
        ),
        onPressed: onPressed,
        icon: Icon(icon, size: 15),
      ),
    );
  }
}

class _EmptyTaskInbox extends StatelessWidget {
  const _EmptyTaskInbox();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Icon(Icons.inbox_rounded, size: 28, color: AppColors.textTertiary),
            SizedBox(height: 8),
            Text(
              'No tasks yet',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.textSecondary,
                fontWeight: FontWeight.w800,
                letterSpacing: 0,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SidebarIconButton extends StatelessWidget {
  const _SidebarIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: IconButton(
        visualDensity: VisualDensity.compact,
        style: IconButton.styleFrom(
          fixedSize: const Size.square(30),
          backgroundColor: AppColors.surface,
          foregroundColor: AppColors.textSecondary,
          disabledForegroundColor: AppColors.textTertiary,
          side: const BorderSide(color: AppColors.border),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
        ),
        onPressed: onPressed,
        icon: Icon(icon, size: 16),
      ),
    );
  }
}

class _TaskGroup {
  const _TaskGroup({required this.title, required this.tasks});

  final String title;
  final List<TaskRecord> tasks;
}

List<_TaskGroup> _groups(List<TaskRecord> tasks) {
  final sorted = [...tasks]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  return [
    _TaskGroup(
      title: 'Needs Review',
      tasks: _tasksWithStatuses(sorted, const {
        TaskStatus.needsHumanReview,
        TaskStatus.approvedForExport,
        TaskStatus.exporting,
      }),
    ),
    _TaskGroup(
      title: 'Running',
      tasks: _tasksWithStatuses(sorted, const {
        TaskStatus.queued,
        TaskStatus.dispatched,
        TaskStatus.running,
        TaskStatus.collectingArtifacts,
      }),
    ),
    _TaskGroup(
      title: 'Blocked',
      tasks: _tasksWithStatuses(sorted, const {
        TaskStatus.blockedOnPermission,
        TaskStatus.blockedOnUserInput,
        TaskStatus.failed,
      }),
    ),
    _TaskGroup(
      title: 'Inbox',
      tasks: _tasksWithStatuses(sorted, const {
        TaskStatus.inbox,
        TaskStatus.needsChanges,
      }),
    ),
    _TaskGroup(
      title: 'Done',
      tasks: _tasksWithStatuses(sorted, const {
        TaskStatus.done,
        TaskStatus.cancelled,
        TaskStatus.rejected,
      }),
    ),
  ];
}

List<TaskRecord> _tasksWithStatuses(
  List<TaskRecord> tasks,
  Set<TaskStatus> statuses,
) {
  return tasks
      .where((task) => statuses.contains(task.status))
      .toList(growable: false);
}

Map<String, List<ArtifactRecord>> _artifactsByTask(
  List<ArtifactRecord> artifacts,
) {
  final grouped = <String, List<ArtifactRecord>>{};
  for (final artifact in artifacts) {
    grouped
        .putIfAbsent(artifact.taskId, () => <ArtifactRecord>[])
        .add(artifact);
  }
  for (final entry in grouped.entries) {
    entry.value.sort((a, b) => a.createdAt.compareTo(b.createdAt));
  }
  return grouped;
}

IconData _iconForArtifact(ArtifactKind kind) {
  return switch (kind) {
    ArtifactKind.gitStatus => Icons.account_tree_outlined,
    ArtifactKind.gitDiff || ArtifactKind.patch => Icons.difference_outlined,
    ArtifactKind.outboxFile || ArtifactKind.file => Icons.insert_drive_file,
    ArtifactKind.testLog => Icons.fact_check_outlined,
    ArtifactKind.agentSummary => Icons.summarize_outlined,
  };
}

String _priorityLabel(TaskPriority priority) {
  return switch (priority) {
    TaskPriority.low => 'Low',
    TaskPriority.normal => 'Normal',
    TaskPriority.high => 'High',
    TaskPriority.urgent => 'Urgent',
  };
}

String? _skillSummary(TaskRecord task) {
  final paths = task.metadata['skill_paths'];
  if (paths is List) {
    final values = paths
        .whereType<String>()
        .map((path) => path.trim())
        .where((path) => path.isNotEmpty)
        .toList(growable: false);
    if (values.isNotEmpty) return values.join(', ');
  }
  if (task.skillIds.isEmpty) return null;
  return task.skillIds.join(', ');
}
