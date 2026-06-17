import 'dart:async';

import 'package:boardview/board_item.dart';
import 'package:boardview/board_list.dart';
import 'package:boardview/boardview.dart';
import 'package:flutter/material.dart';

import '../../config/acp_client_config.dart';
import '../../task_center/task_center_controller.dart';
import '../../task_center/task_center_models.dart';
import '../theme/app_design_tokens.dart';

typedef TaskCenterWorkspaceMessageSender =
    Future<String> Function(TaskWorkspace workspace, String message);

class TaskCenterDialog extends StatelessWidget {
  const TaskCenterDialog({
    super.key,
    required this.controller,
    this.agentServers = const <AgentServerConfig>[],
    this.onSendWorkspaceMessage,
  });

  final TaskCenterController controller;
  final List<AgentServerConfig> agentServers;
  final TaskCenterWorkspaceMessageSender? onSendWorkspaceMessage;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(18),
      child: SizedBox(
        width: 1180,
        height: 720,
        child: TaskCenterBoard(
          controller: controller,
          agentServers: agentServers,
          onSendWorkspaceMessage: onSendWorkspaceMessage,
        ),
      ),
    );
  }
}

class TaskCenterBoard extends StatefulWidget {
  const TaskCenterBoard({
    super.key,
    required this.controller,
    this.agentServers = const <AgentServerConfig>[],
    this.renderBoardView = true,
    this.onSendWorkspaceMessage,
  });

  final TaskCenterController controller;
  final List<AgentServerConfig> agentServers;
  final bool renderBoardView;
  final TaskCenterWorkspaceMessageSender? onSendWorkspaceMessage;

  @override
  State<TaskCenterBoard> createState() => _TaskCenterBoardState();
}

class _TaskCenterBoardState extends State<TaskCenterBoard> {
  String? _selectedTaskId;

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
    if (!mounted) return;
    setState(() {
      final workspace = widget.controller.selectedWorkspace;
      if (workspace == null) {
        _selectedTaskId = null;
      } else if (_selectedTaskId != null &&
          !workspace.tasks.any((task) => task.id == _selectedTaskId)) {
        _selectedTaskId = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final workspace = widget.controller.selectedWorkspace;
    final selectedTask = _selectedTask(workspace);
    return Column(
      children: [
        _TaskCenterHeader(
          controller: widget.controller,
          selectedWorkspace: workspace,
          agentServers: widget.agentServers,
          onCreateWorkspace: _createWorkspace,
          onCreateTask: workspace == null ? null : () => _createTask(workspace),
          onConfigureWorkspace: workspace == null
              ? null
              : () => _configureWorkspace(workspace),
        ),
        const Divider(height: 1, color: AppColors.border),
        Expanded(
          child: workspace == null
              ? _EmptyTaskCenter(onCreateWorkspace: _createWorkspace)
              : Row(
                  children: [
                    Expanded(
                      child: Column(
                        children: [
                          Expanded(
                            child: _BoardSurface(
                              workspace: workspace,
                              renderBoardView: widget.renderBoardView,
                              selectedTaskId: selectedTask?.id,
                              onSelectTask: (task) {
                                setState(() => _selectedTaskId = task.id);
                              },
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
                          const Divider(height: 1, color: AppColors.border),
                          SizedBox(
                            height: 210,
                            child: _WorkspaceChatPanel(
                              controller: widget.controller,
                              workspace: workspace,
                              onSendWorkspaceMessage:
                                  widget.onSendWorkspaceMessage,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const VerticalDivider(width: 1, color: AppColors.border),
                    SizedBox(
                      width: 360,
                      child: _TaskProtocolPanel(
                        controller: widget.controller,
                        workspace: workspace,
                        task: selectedTask,
                        agentServers: widget.agentServers,
                      ),
                    ),
                  ],
                ),
        ),
      ],
    );
  }

  TaskCenterTask? _selectedTask(TaskWorkspace? workspace) {
    if (workspace == null || workspace.tasks.isEmpty) return null;
    final selectedId = _selectedTaskId;
    if (selectedId != null) {
      for (final task in workspace.tasks) {
        if (task.id == selectedId) return task;
      }
    }
    final sorted = List<TaskCenterTask>.of(workspace.tasks)
      ..sort((a, b) => a.updatedAt.compareTo(b.updatedAt));
    return sorted.last;
  }

  Future<void> _createWorkspace() async {
    final title = await _askForText(
      context: context,
      title: 'New Workspace',
      label: 'Name',
    );
    if (title == null) return;
    final workspace = await widget.controller.createWorkspace(title: title);
    setState(() => _selectedTaskId = null);
    if (!mounted) return;
    await _configureWorkspace(workspace);
  }

  Future<void> _createTask(TaskWorkspace workspace) async {
    final title = await _askForText(
      context: context,
      title: 'New Task',
      label: 'Title',
    );
    if (title == null) return;
    final task = await widget.controller.createTask(
      workspaceId: workspace.id,
      title: title,
      currentOwner: _initialOwner(workspace),
      routeReason: 'New task needs triage.',
    );
    setState(() => _selectedTaskId = task.id);
  }

  Future<void> _configureWorkspace(TaskWorkspace workspace) async {
    await showDialog<void>(
      context: context,
      builder: (context) => _WorkspaceAgentSettingsDialog(
        controller: widget.controller,
        workspace: workspace,
        agentServers: widget.agentServers,
      ),
    );
  }

  TaskCenterTaskOwner _initialOwner(TaskWorkspace workspace) {
    final fastAgentName = workspace.agentConfig.fastAgentName;
    if (fastAgentName.isNotEmpty) {
      return TaskCenterTaskOwner.fastAgent(fastAgentName);
    }
    return const TaskCenterTaskOwner.unassigned();
  }
}

class _TaskCenterHeader extends StatelessWidget {
  const _TaskCenterHeader({
    required this.controller,
    required this.selectedWorkspace,
    required this.agentServers,
    required this.onCreateWorkspace,
    required this.onCreateTask,
    required this.onConfigureWorkspace,
  });

  final TaskCenterController controller;
  final TaskWorkspace? selectedWorkspace;
  final List<AgentServerConfig> agentServers;
  final VoidCallback onCreateWorkspace;
  final VoidCallback? onCreateTask;
  final VoidCallback? onConfigureWorkspace;

  @override
  Widget build(BuildContext context) {
    final config = selectedWorkspace?.agentConfig;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
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
          const SizedBox(width: 10),
          if (config != null) ...[
            _RoleSummaryPill(
              label: 'Fast',
              value: config.fastAgentName,
              fallback: 'unset',
            ),
            _RoleSummaryPill(
              label: 'Thinking',
              value: config.thinkingAgentName,
              fallback: 'unset',
            ),
            _RoleSummaryPill(
              label: 'Work',
              value: '${config.workAgentNames.length}',
              fallback: '0',
            ),
          ],
          const Spacer(),
          IconButton(
            tooltip: 'Workspace agents',
            onPressed: onConfigureWorkspace,
            icon: const Icon(Icons.manage_accounts_outlined),
          ),
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
    required this.selectedTaskId,
    required this.onSelectTask,
    required this.onMoveTask,
  });

  final TaskWorkspace workspace;
  final bool renderBoardView;
  final String? selectedTaskId;
  final ValueChanged<TaskCenterTask> onSelectTask;
  final void Function(TaskCenterTask task, TaskCenterStatus status, int index)
  onMoveTask;

  @override
  Widget build(BuildContext context) {
    final lists = [
      for (final status in TaskCenterStatus.values)
        _buildList(status, _tasksForStatus(status)),
    ];
    if (!renderBoardView) {
      return _StaticBoard(workspace: workspace, onSelectTask: onSelectTask);
    }
    return LayoutBuilder(
      builder: (context, constraints) => ClipRect(
        child: ColoredBox(
          color: AppColors.bg,
          child: SizedBox.expand(
            child: BoardView(
              lists: lists,
              width: _boardColumnWidth(constraints.maxWidth),
              dragDelay: 140,
            ),
          ),
        ),
      ),
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
            item: _TaskCard(
              task: task,
              selected: task.id == selectedTaskId,
              onTap: () => onSelectTask(task),
            ),
          ),
      ],
    );
  }
}

double _boardColumnWidth(double availableWidth) {
  if (!availableWidth.isFinite || availableWidth <= 0) return 244;
  final fitted = availableWidth / TaskCenterStatus.values.length;
  return fitted.clamp(178, 260).toDouble();
}

class _StaticBoard extends StatelessWidget {
  const _StaticBoard({required this.workspace, required this.onSelectTask});

  final TaskWorkspace workspace;
  final ValueChanged<TaskCenterTask> onSelectTask;

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
                    _TaskCard(
                      task: task,
                      selected: false,
                      onTap: () => onSelectTask(task),
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _TaskCard extends StatelessWidget {
  const _TaskCard({
    required this.task,
    required this.selected,
    required this.onTap,
  });

  final TaskCenterTask task;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final detailPreview = task.details.isNotEmpty
        ? task.details
        : task.description;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: Container(
        margin: const EdgeInsets.fromLTRB(8, 6, 8, 2),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(
            color: selected ? AppColors.primary : AppColors.border,
            width: selected ? 1.4 : 1,
          ),
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
            if (detailPreview.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                detailPreview,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0,
                ),
              ),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 5,
              runSpacing: 5,
              children: [
                _TinyPill(
                  label: task.currentOwner.label,
                  color: AppColors.primaryDark,
                  background: AppColors.primaryMist,
                ),
                _TinyPill(
                  label: task.readiness.label,
                  color: _readinessColor(task.readiness),
                  background: _readinessBackground(task.readiness),
                ),
                _TinyPill(
                  label: task.acceptanceCriteria.isEmpty
                      ? 'No acceptance'
                      : '${task.acceptanceCriteria.length} checks',
                  color: task.acceptanceCriteria.isEmpty
                      ? AppColors.warning
                      : AppColors.success,
                  background: task.acceptanceCriteria.isEmpty
                      ? const Color(0xfffff7ed)
                      : const Color(0xfff0fdf4),
                ),
              ],
            ),
            if (task.routeReason.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                task.routeReason,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.textTertiary,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
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

class _WorkspaceChatPanel extends StatefulWidget {
  const _WorkspaceChatPanel({
    required this.controller,
    required this.workspace,
    this.onSendWorkspaceMessage,
  });

  final TaskCenterController controller;
  final TaskWorkspace workspace;
  final TaskCenterWorkspaceMessageSender? onSendWorkspaceMessage;

  @override
  State<_WorkspaceChatPanel> createState() => _WorkspaceChatPanelState();
}

class _WorkspaceChatPanelState extends State<_WorkspaceChatPanel> {
  final TextEditingController _messageController = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _messageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final messages = widget.workspace.chatMessages.reversed.toList(
      growable: false,
    );
    return ColoredBox(
      color: AppColors.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
            child: Row(
              children: [
                const Icon(
                  Icons.forum_outlined,
                  size: 18,
                  color: AppColors.primaryDark,
                ),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Workspace Chat',
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0,
                    ),
                  ),
                ),
                _TinyPill(
                  label: widget.workspace.agentConfig.fastAgentName.isEmpty
                      ? 'fast agent unset'
                      : widget.workspace.agentConfig.fastAgentName,
                  color: AppColors.primaryDark,
                  background: AppColors.primaryMist,
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: AppColors.border),
          Expanded(
            child: messages.isEmpty
                ? const SizedBox.shrink()
                : ListView.builder(
                    reverse: true,
                    padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
                    itemCount: messages.length,
                    itemBuilder: (context, index) {
                      return _WorkspaceChatBubble(message: messages[index]);
                    },
                  ),
          ),
          const Divider(height: 1, color: AppColors.border),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('workspace-chat-input'),
                    controller: _messageController,
                    enabled: !_sending,
                    minLines: 1,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      isDense: true,
                      hintText: 'Message workspace',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => unawaited(_send()),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  tooltip: 'Send to fast agent',
                  onPressed: _sending ? null : () => unawaited(_send()),
                  icon: _sending
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send_outlined),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _send() async {
    final content = _messageController.text.trim();
    if (content.isEmpty || _sending) return;
    setState(() => _sending = true);
    _messageController.clear();

    final workspace = widget.workspace;
    final fastAgentName = workspace.agentConfig.fastAgentName.trim();
    await widget.controller.postWorkspaceChatMessage(
      workspaceId: workspace.id,
      role: TaskWorkspaceChatRole.human,
      actor: 'human',
      content: content,
    );

    try {
      if (fastAgentName.isEmpty) {
        await _postSystemMessage('fast agent is not configured.');
        return;
      }
      final sender = widget.onSendWorkspaceMessage;
      if (sender == null) {
        await _postSystemMessage('fast agent runner is not connected.');
        return;
      }
      final response = (await sender(workspace, content)).trim();
      if (response.isNotEmpty) {
        await widget.controller.postWorkspaceChatMessage(
          workspaceId: workspace.id,
          role: TaskWorkspaceChatRole.fastAgent,
          actor: fastAgentName,
          agentName: fastAgentName,
          content: response,
        );
      }
    } catch (error) {
      await _postSystemMessage('$error');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _postSystemMessage(String content) {
    return widget.controller.postWorkspaceChatMessage(
      workspaceId: widget.workspace.id,
      role: TaskWorkspaceChatRole.system,
      actor: 'system',
      content: content,
    );
  }
}

class _WorkspaceChatBubble extends StatelessWidget {
  const _WorkspaceChatBubble({required this.message});

  final TaskWorkspaceChatMessage message;

  @override
  Widget build(BuildContext context) {
    final isHuman = message.role == TaskWorkspaceChatRole.human;
    final background = switch (message.role) {
      TaskWorkspaceChatRole.human => AppColors.primaryMist,
      TaskWorkspaceChatRole.fastAgent => const Color(0xfff0fdf4),
      TaskWorkspaceChatRole.thinkingAgent => const Color(0xffeef2ff),
      TaskWorkspaceChatRole.workAgent => const Color(0xfff8fafc),
      TaskWorkspaceChatRole.system => const Color(0xfffff7ed),
    };
    final foreground = switch (message.role) {
      TaskWorkspaceChatRole.human => AppColors.primaryDark,
      TaskWorkspaceChatRole.fastAgent => AppColors.success,
      TaskWorkspaceChatRole.thinkingAgent => AppColors.primaryDark,
      TaskWorkspaceChatRole.workAgent => AppColors.textPrimary,
      TaskWorkspaceChatRole.system => AppColors.warning,
    };
    return Align(
      alignment: isHuman ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 520),
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message.actor.isEmpty ? message.role.label : message.actor,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: foreground,
                fontSize: 11,
                fontWeight: FontWeight.w900,
                letterSpacing: 0,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              message.content,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                height: 1.35,
                letterSpacing: 0,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TaskProtocolPanel extends StatefulWidget {
  const _TaskProtocolPanel({
    required this.controller,
    required this.workspace,
    required this.task,
    required this.agentServers,
  });

  final TaskCenterController controller;
  final TaskWorkspace workspace;
  final TaskCenterTask? task;
  final List<AgentServerConfig> agentServers;

  @override
  State<_TaskProtocolPanel> createState() => _TaskProtocolPanelState();
}

class _TaskProtocolPanelState extends State<_TaskProtocolPanel> {
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _descriptionController = TextEditingController();
  final TextEditingController _detailsController = TextEditingController();
  final TextEditingController _objectiveController = TextEditingController();
  final TextEditingController _acceptanceController = TextEditingController();
  final TextEditingController _humanQuestionsController =
      TextEditingController();
  final TextEditingController _routeReasonController = TextEditingController();
  final TextEditingController _executionResultController =
      TextEditingController();
  final TextEditingController _verificationNotesController =
      TextEditingController();

  @override
  void initState() {
    super.initState();
    _syncTask();
  }

  @override
  void didUpdateWidget(covariant _TaskProtocolPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.task?.id != widget.task?.id ||
        oldWidget.task?.updatedAt != widget.task?.updatedAt) {
      _syncTask();
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    _detailsController.dispose();
    _objectiveController.dispose();
    _acceptanceController.dispose();
    _humanQuestionsController.dispose();
    _routeReasonController.dispose();
    _executionResultController.dispose();
    _verificationNotesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    if (task == null) {
      return const Center(
        child: Text(
          'Select a task to edit its protocol.',
          style: TextStyle(
            color: AppColors.textSecondary,
            fontWeight: FontWeight.w700,
            letterSpacing: 0,
          ),
        ),
      );
    }
    return ColoredBox(
      color: AppColors.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  task.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    _TinyPill(
                      label: task.currentOwner.label,
                      color: AppColors.primaryDark,
                      background: AppColors.primaryMist,
                    ),
                    _TinyPill(
                      label: task.readiness.label,
                      color: _readinessColor(task.readiness),
                      background: _readinessBackground(task.readiness),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: AppColors.border),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _PanelSection(
                    title: 'Details',
                    children: [
                      _ProtocolTextField(
                        label: 'Title',
                        controller: _titleController,
                        maxLines: 1,
                      ),
                      _ProtocolTextField(
                        label: 'Objective',
                        controller: _objectiveController,
                        maxLines: 2,
                      ),
                      _ProtocolTextField(
                        label: 'Description',
                        controller: _descriptionController,
                        maxLines: 2,
                      ),
                      _ProtocolTextField(
                        label: 'Notes',
                        controller: _detailsController,
                        maxLines: 4,
                      ),
                    ],
                  ),
                  _PanelSection(
                    title: 'Acceptance',
                    children: [
                      _ProtocolTextField(
                        label: 'One check per line',
                        controller: _acceptanceController,
                        maxLines: 4,
                      ),
                    ],
                  ),
                  _PanelSection(
                    title: 'Human Check',
                    children: [
                      _ProtocolTextField(
                        label: 'Questions for human confirmation',
                        controller: _humanQuestionsController,
                        maxLines: 4,
                      ),
                      if (task.humanQuestions.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        for (final question in task.humanQuestions)
                          _HumanQuestionRow(question: question),
                      ],
                    ],
                  ),
                  _PanelSection(
                    title: 'Route',
                    children: [
                      _ProtocolTextField(
                        label: 'Route reason',
                        controller: _routeReasonController,
                        maxLines: 2,
                      ),
                      _ProtocolTextField(
                        label: 'Execution result',
                        controller: _executionResultController,
                        maxLines: 3,
                      ),
                      _ProtocolTextField(
                        label: 'Verification notes',
                        controller: _verificationNotesController,
                        maxLines: 3,
                      ),
                    ],
                  ),
                  if (task.events.isNotEmpty)
                    _PanelSection(
                      title: 'History',
                      children: [
                        for (final event in task.events.reversed.take(5))
                          _EventRow(event: event),
                      ],
                    ),
                ],
              ),
            ),
          ),
          const Divider(height: 1, color: AppColors.border),
          Padding(
            padding: const EdgeInsets.all(10),
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: () => unawaited(_sendToThinking(task)),
                  icon: const Icon(Icons.psychology_alt_outlined, size: 18),
                  label: const Text('Send to Thinking'),
                ),
                OutlinedButton.icon(
                  onPressed: () => unawaited(_askHuman(task)),
                  icon: const Icon(Icons.rule_folder_outlined, size: 18),
                  label: const Text('Ask Human'),
                ),
                OutlinedButton.icon(
                  onPressed: () => unawaited(_assignWorkAgent(task)),
                  icon: const Icon(Icons.engineering_outlined, size: 18),
                  label: const Text('Assign Work Agent'),
                ),
                FilledButton.icon(
                  onPressed: () => unawaited(_save(task)),
                  icon: const Icon(Icons.save_outlined, size: 18),
                  label: const Text('Save'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _syncTask() {
    final task = widget.task;
    _titleController.text = task?.title ?? '';
    _descriptionController.text = task?.description ?? '';
    _detailsController.text = task?.details ?? '';
    _objectiveController.text = task?.objective ?? '';
    _acceptanceController.text = (task?.acceptanceCriteria ?? const <String>[])
        .join('\n');
    _humanQuestionsController.text =
        (task?.humanQuestions ?? const <TaskCenterHumanQuestion>[])
            .map((question) => question.question)
            .join('\n');
    _routeReasonController.text = task?.routeReason ?? '';
    _executionResultController.text = task?.executionResult ?? '';
    _verificationNotesController.text = task?.verificationNotes ?? '';
  }

  Future<void> _save(TaskCenterTask task) async {
    final questions = _splitLines(_humanQuestionsController.text)
        .mapIndexed(
          (index, question) => TaskCenterHumanQuestion(
            id: index < task.humanQuestions.length
                ? task.humanQuestions[index].id
                : 'manual-${DateTime.now().microsecondsSinceEpoch}-$index',
            question: question,
            answer: index < task.humanQuestions.length
                ? task.humanQuestions[index].answer
                : '',
            resolved: index < task.humanQuestions.length
                ? task.humanQuestions[index].resolved
                : false,
          ),
        )
        .toList(growable: false);
    await widget.controller.updateTask(
      workspaceId: widget.workspace.id,
      taskId: task.id,
      title: _titleController.text,
      description: _descriptionController.text,
      details: _detailsController.text,
      objective: _objectiveController.text,
      acceptanceCriteria: _splitLines(_acceptanceController.text),
      humanQuestions: questions,
      routeReason: _routeReasonController.text,
      executionResult: _executionResultController.text,
      verificationNotes: _verificationNotesController.text,
    );
  }

  Future<void> _sendToThinking(TaskCenterTask task) async {
    final thinkingAgentName = widget.workspace.agentConfig.thinkingAgentName;
    await widget.controller.transferTaskOwner(
      workspaceId: widget.workspace.id,
      taskId: task.id,
      owner: TaskCenterTaskOwner.thinkingAgent(thinkingAgentName),
      readiness: TaskCenterReadiness.needsThinking,
      routeReason: _routeReasonController.text.trim().isEmpty
          ? 'Needs deeper thinking.'
          : _routeReasonController.text,
      actor: 'human',
    );
  }

  Future<void> _askHuman(TaskCenterTask task) async {
    final questions = _splitLines(_humanQuestionsController.text);
    await widget.controller.requestHumanConfirmation(
      workspaceId: widget.workspace.id,
      taskId: task.id,
      questions: questions.isEmpty
          ? const <String>['Please confirm this task can proceed.']
          : questions,
      routeReason: _routeReasonController.text.trim().isEmpty
          ? 'Needs human confirmation.'
          : _routeReasonController.text,
      actor: 'human',
    );
  }

  Future<void> _assignWorkAgent(TaskCenterTask task) async {
    final workAgentNames = widget.workspace.agentConfig.workAgentNames;
    final agentName = workAgentNames.isEmpty
        ? 'Work Agent'
        : workAgentNames.first;
    await widget.controller.claimWorkTask(
      workspaceId: widget.workspace.id,
      taskId: task.id,
      agentName: agentName,
      actor: 'human',
    );
  }
}

class _WorkspaceAgentSettingsDialog extends StatefulWidget {
  const _WorkspaceAgentSettingsDialog({
    required this.controller,
    required this.workspace,
    required this.agentServers,
  });

  final TaskCenterController controller;
  final TaskWorkspace workspace;
  final List<AgentServerConfig> agentServers;

  @override
  State<_WorkspaceAgentSettingsDialog> createState() =>
      _WorkspaceAgentSettingsDialogState();
}

class _WorkspaceAgentSettingsDialogState
    extends State<_WorkspaceAgentSettingsDialog> {
  late String _fastAgentName = widget.workspace.agentConfig.fastAgentName;
  late String _thinkingAgentName =
      widget.workspace.agentConfig.thinkingAgentName;
  late final Set<String> _workAgentNames = widget
      .workspace
      .agentConfig
      .workAgentNames
      .toSet();
  late final TextEditingController _fastPromptController =
      TextEditingController(text: widget.workspace.agentConfig.fastAgentPrompt);
  late final TextEditingController _thinkingPromptController =
      TextEditingController(
        text: widget.workspace.agentConfig.thinkingAgentPrompt,
      );
  late final TextEditingController _workPromptController =
      TextEditingController(text: widget.workspace.agentConfig.workAgentPrompt);

  @override
  void dispose() {
    _fastPromptController.dispose();
    _thinkingPromptController.dispose();
    _workPromptController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final agentNames = widget.agentServers
        .map((server) => server.name)
        .toList();
    return AlertDialog(
      title: const Text('Workspace Agents'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _AgentRoleDropdown(
                label: 'Main Fast Agent',
                value: _fastAgentName,
                agentNames: agentNames,
                onChanged: (value) {
                  setState(() => _fastAgentName = value);
                },
              ),
              const SizedBox(height: 10),
              _AgentRoleDropdown(
                label: 'Main Thinking Agent',
                value: _thinkingAgentName,
                agentNames: agentNames,
                onChanged: (value) {
                  setState(() => _thinkingAgentName = value);
                },
              ),
              const SizedBox(height: 14),
              const Text(
                'Main Work Agents',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0,
                ),
              ),
              const SizedBox(height: 6),
              if (agentNames.isEmpty)
                const Text(
                  'No ACP agents configured yet.',
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0,
                  ),
                )
              else
                for (final name in agentNames)
                  CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(name),
                    value: _workAgentNames.contains(name),
                    onChanged: (selected) {
                      setState(() {
                        if (selected == true) {
                          _workAgentNames.add(name);
                        } else {
                          _workAgentNames.remove(name);
                        }
                      });
                    },
                  ),
              const SizedBox(height: 12),
              _ProtocolTextField(
                label: 'Fast agent role prompt',
                controller: _fastPromptController,
                maxLines: 3,
              ),
              _ProtocolTextField(
                label: 'Thinking agent role prompt',
                controller: _thinkingPromptController,
                maxLines: 3,
              ),
              _ProtocolTextField(
                label: 'Work agent role prompt',
                controller: _workPromptController,
                maxLines: 3,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => unawaited(_save()),
          child: const Text('Save Agents'),
        ),
      ],
    );
  }

  Future<void> _save() async {
    await widget.controller.updateWorkspaceAgentConfig(
      workspaceId: widget.workspace.id,
      agentConfig: TaskWorkspaceAgentConfig(
        fastAgentName: _fastAgentName,
        thinkingAgentName: _thinkingAgentName,
        workAgentNames: _workAgentNames.toList()..sort(),
        fastAgentPrompt: _fastPromptController.text,
        thinkingAgentPrompt: _thinkingPromptController.text,
        workAgentPrompt: _workPromptController.text,
      ),
    );
    if (!mounted) return;
    Navigator.of(context).pop();
  }
}

class _AgentRoleDropdown extends StatelessWidget {
  const _AgentRoleDropdown({
    required this.label,
    required this.value,
    required this.agentNames,
    required this.onChanged,
  });

  final String label;
  final String value;
  final List<String> agentNames;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String>(
      initialValue: value.isEmpty ? '' : value,
      decoration: InputDecoration(labelText: label),
      items: [
        const DropdownMenuItem<String>(value: '', child: Text('Not set')),
        for (final name in agentNames)
          DropdownMenuItem<String>(value: name, child: Text(name)),
      ],
      onChanged: (value) {
        if (value != null) onChanged(value);
      },
    );
  }
}

class _PanelSection extends StatelessWidget {
  const _PanelSection({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 12,
              fontWeight: FontWeight.w900,
              letterSpacing: 0,
            ),
          ),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    );
  }
}

class _ProtocolTextField extends StatelessWidget {
  const _ProtocolTextField({
    required this.label,
    required this.controller,
    this.maxLines = 1,
  });

  final String label;
  final TextEditingController controller;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        controller: controller,
        maxLines: maxLines,
        decoration: InputDecoration(
          labelText: label,
          isDense: true,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }
}

class _HumanQuestionRow extends StatelessWidget {
  const _HumanQuestionRow({required this.question});

  final TaskCenterHumanQuestion question;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            question.resolved
                ? Icons.check_circle_outline
                : Icons.help_outline_rounded,
            size: 16,
            color: question.resolved ? AppColors.success : AppColors.warning,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              question.answer.isEmpty
                  ? question.question
                  : '${question.question}\n${question.answer}',
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                letterSpacing: 0,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EventRow extends StatelessWidget {
  const _EventRow({required this.event});

  final TaskCenterEvent event;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        '${event.actor}: ${event.message}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: AppColors.textSecondary,
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0,
        ),
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

class _TinyPill extends StatelessWidget {
  const _TinyPill({
    required this.label,
    required this.color,
    required this.background,
  });

  final String label;
  final Color color;
  final Color background;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 150),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: color,
          fontSize: 10.5,
          fontWeight: FontWeight.w900,
          letterSpacing: 0,
        ),
      ),
    );
  }
}

class _RoleSummaryPill extends StatelessWidget {
  const _RoleSummaryPill({
    required this.label,
    required this.value,
    required this.fallback,
  });

  final String label;
  final String value;
  final String fallback;

  @override
  Widget build(BuildContext context) {
    final display = value.trim().isEmpty ? fallback : value.trim();
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: _TinyPill(
        label: '$label $display',
        color: AppColors.primaryDark,
        background: AppColors.primaryMist,
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

Color _readinessColor(TaskCenterReadiness readiness) {
  return switch (readiness) {
    TaskCenterReadiness.needsInfo => AppColors.warning,
    TaskCenterReadiness.needsThinking => AppColors.primaryDark,
    TaskCenterReadiness.waitingHuman => AppColors.warning,
    TaskCenterReadiness.ready => AppColors.success,
    TaskCenterReadiness.blocked => AppColors.danger,
  };
}

Color _readinessBackground(TaskCenterReadiness readiness) {
  return switch (readiness) {
    TaskCenterReadiness.needsInfo => const Color(0xfffff7ed),
    TaskCenterReadiness.needsThinking => AppColors.primaryMist,
    TaskCenterReadiness.waitingHuman => const Color(0xfffff7ed),
    TaskCenterReadiness.ready => const Color(0xfff0fdf4),
    TaskCenterReadiness.blocked => const Color(0xfffff1f2),
  };
}

List<String> _splitLines(String value) {
  return value
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList(growable: false);
}

Future<String?> _askForText({
  required BuildContext context,
  required String title,
  required String label,
}) async {
  return await showDialog<String>(
    context: context,
    builder: (context) =>
        _TaskCenterTextPromptDialog(title: title, label: label),
  );
}

class _TaskCenterTextPromptDialog extends StatefulWidget {
  const _TaskCenterTextPromptDialog({required this.title, required this.label});

  final String title;
  final String label;

  @override
  State<_TaskCenterTextPromptDialog> createState() =>
      _TaskCenterTextPromptDialogState();
}

class _TaskCenterTextPromptDialogState
    extends State<_TaskCenterTextPromptDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(labelText: widget.label),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Create')),
      ],
    );
  }

  void _submit() {
    final value = _controller.text.trim();
    if (value.isEmpty) return;
    Navigator.of(context).pop(value);
  }
}

extension _IndexedMap<T> on Iterable<T> {
  Iterable<R> mapIndexed<R>(R Function(int index, T value) convert) sync* {
    var index = 0;
    for (final value in this) {
      yield convert(index, value);
      index += 1;
    }
  }
}
