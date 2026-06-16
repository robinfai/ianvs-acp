import 'dart:async';

import 'package:boardview/board_item.dart';
import 'package:boardview/board_list.dart';
import 'package:boardview/boardview.dart';
import 'package:flutter/material.dart';

import '../../task_center/task_center_controller.dart';
import '../../task_center/task_center_models.dart';
import '../theme/app_design_tokens.dart';

class TaskCenterDialog extends StatelessWidget {
  const TaskCenterDialog({super.key, required this.controller});

  final TaskCenterController controller;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(18),
      child: SizedBox(
        width: 1040,
        height: 680,
        child: TaskCenterBoard(controller: controller),
      ),
    );
  }
}

class TaskCenterBoard extends StatefulWidget {
  const TaskCenterBoard({
    super.key,
    required this.controller,
    this.renderBoardView = true,
  });

  final TaskCenterController controller;
  final bool renderBoardView;

  @override
  State<TaskCenterBoard> createState() => _TaskCenterBoardState();
}

class _TaskCenterBoardState extends State<TaskCenterBoard> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    if (!widget.controller.loaded) {
      unawaited(widget.controller.load());
    }
  }

  @override
  void didUpdateWidget(covariant TaskCenterBoard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    oldWidget.controller.removeListener(_onControllerChanged);
    widget.controller.addListener(_onControllerChanged);
    if (!widget.controller.loaded) {
      unawaited(widget.controller.load());
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final workspace = widget.controller.selectedWorkspace;
    return Column(
      children: [
        _TaskCenterHeader(
          controller: widget.controller,
          selectedWorkspace: workspace,
          onCreateWorkspace: _createWorkspace,
          onCreateTask: workspace == null ? null : () => _createTask(workspace),
        ),
        const Divider(height: 1, color: AppColors.border),
        Expanded(
          child: workspace == null
              ? _EmptyTaskCenter(onCreateWorkspace: _createWorkspace)
              : _BoardSurface(
                  workspace: workspace,
                  renderBoardView: widget.renderBoardView,
                  onMoveTask: (task, status, index) => unawaited(
                    widget.controller.moveTask(
                      workspaceId: workspace.id,
                      taskId: task.id,
                      status: status,
                      index: index,
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  Future<void> _createWorkspace() async {
    final title = await _askForText(
      context: context,
      title: 'New Workspace',
      label: 'Name',
    );
    if (title == null) return;
    await widget.controller.createWorkspace(title: title);
  }

  Future<void> _createTask(TaskWorkspace workspace) async {
    final title = await _askForText(
      context: context,
      title: 'New Task',
      label: 'Title',
    );
    if (title == null) return;
    await widget.controller.createTask(workspaceId: workspace.id, title: title);
  }
}

class _TaskCenterHeader extends StatelessWidget {
  const _TaskCenterHeader({
    required this.controller,
    required this.selectedWorkspace,
    required this.onCreateWorkspace,
    required this.onCreateTask,
  });

  final TaskCenterController controller;
  final TaskWorkspace? selectedWorkspace;
  final VoidCallback onCreateWorkspace;
  final VoidCallback? onCreateTask;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Row(
        children: [
          const Icon(Icons.view_kanban_outlined, color: AppColors.primaryDark),
          const SizedBox(width: 8),
          const Text(
            'Task Center',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w900,
              letterSpacing: 0,
            ),
          ),
          const SizedBox(width: 12),
          if (controller.workspaces.isNotEmpty)
            DropdownButton<String>(
              key: const Key('task-center-workspace-menu'),
              value: selectedWorkspace?.id,
              underline: const SizedBox.shrink(),
              items: [
                for (final workspace in controller.workspaces)
                  DropdownMenuItem<String>(
                    value: workspace.id,
                    child: Text(workspace.title),
                  ),
              ],
              onChanged: (value) {
                if (value != null) controller.selectWorkspace(value);
              },
            ),
          const Spacer(),
          IconButton(
            tooltip: 'New workspace',
            onPressed: onCreateWorkspace,
            icon: const Icon(Icons.create_new_folder_outlined),
          ),
          IconButton(
            tooltip: 'New task',
            onPressed: onCreateTask,
            icon: const Icon(Icons.add_task_outlined),
          ),
        ],
      ),
    );
  }
}

class _BoardSurface extends StatelessWidget {
  const _BoardSurface({
    required this.workspace,
    required this.renderBoardView,
    required this.onMoveTask,
  });

  final TaskWorkspace workspace;
  final bool renderBoardView;
  final void Function(TaskCenterTask task, TaskCenterStatus status, int index)
  onMoveTask;

  @override
  Widget build(BuildContext context) {
    final lists = [
      for (final status in TaskCenterStatus.values)
        _buildList(status, _tasksForStatus(status)),
    ];
    if (!renderBoardView) {
      return _StaticBoard(workspace: workspace);
    }
    return ColoredBox(
      color: AppColors.bg,
      child: BoardView(lists: lists, width: 244, dragDelay: 140),
    );
  }

  List<TaskCenterTask> _tasksForStatus(TaskCenterStatus status) {
    final tasks =
        workspace.tasks
            .where((task) => task.status == status)
            .toList(growable: false)
          ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    return tasks;
  }

  BoardList _buildList(TaskCenterStatus status, List<TaskCenterTask> tasks) {
    return BoardList(
      draggable: false,
      backgroundColor: AppColors.surfaceRaised,
      headerBackgroundColor: AppColors.surface,
      header: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    status.label,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0,
                    ),
                  ),
                ),
                _CountPill(count: tasks.length),
              ],
            ),
          ),
        ),
      ],
      items: [
        for (final task in tasks)
          BoardItem(
            draggable: true,
            onDropItem:
                (listIndex, itemIndex, oldListIndex, oldItemIndex, state) {
                  final targetStatus = _statusFromListIndex(listIndex);
                  if (targetStatus == null) return;
                  onMoveTask(task, targetStatus, itemIndex ?? 0);
                },
            item: _TaskCard(task: task),
          ),
      ],
    );
  }
}

class _StaticBoard extends StatelessWidget {
  const _StaticBoard({required this.workspace});

  final TaskWorkspace workspace;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final status in TaskCenterStatus.values)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    status.label,
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0,
                    ),
                  ),
                  const SizedBox(height: 8),
                  for (final task in workspace.tasks.where(
                    (task) => task.status == status,
                  ))
                    _TaskCard(task: task),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _TaskCard extends StatelessWidget {
  const _TaskCard({required this.task});

  final TaskCenterTask task;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 6, 8, 2),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            task.title,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w900,
              letterSpacing: 0,
            ),
          ),
          if (task.description.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              task.description,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                letterSpacing: 0,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _CountPill extends StatelessWidget {
  const _CountPill({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 24),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '$count',
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: AppColors.primaryDark,
          fontSize: 11,
          fontWeight: FontWeight.w900,
          letterSpacing: 0,
        ),
      ),
    );
  }
}

class _EmptyTaskCenter extends StatelessWidget {
  const _EmptyTaskCenter({required this.onCreateWorkspace});

  final VoidCallback onCreateWorkspace;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: FilledButton.icon(
        onPressed: onCreateWorkspace,
        icon: const Icon(Icons.create_new_folder_outlined),
        label: const Text('New Workspace'),
      ),
    );
  }
}

TaskCenterStatus? _statusFromListIndex(int? index) {
  if (index == null || index < 0 || index >= TaskCenterStatus.values.length) {
    return null;
  }
  return TaskCenterStatus.values[index];
}

Future<String?> _askForText({
  required BuildContext context,
  required String title,
  required String label,
}) async {
  final controller = TextEditingController();
  try {
    return showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(title),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(labelText: label),
            onSubmitted: (_) => _submitText(context, controller),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => _submitText(context, controller),
              child: const Text('Create'),
            ),
          ],
        );
      },
    );
  } finally {
    controller.dispose();
  }
}

void _submitText(BuildContext context, TextEditingController controller) {
  final value = controller.text.trim();
  if (value.isEmpty) return;
  Navigator.of(context).pop(value);
}
