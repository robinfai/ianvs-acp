import 'dart:async';
import 'dart:io';

import 'package:boardview/board_item.dart';
import 'package:boardview/board_list.dart';
import 'package:boardview/boardview.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter/services.dart';

import '../../acp/agent_session.dart';
import '../../config/acp_client_config.dart';
import '../../state/chat_controller.dart';
import '../../task_center/task_center_controller.dart';
import '../../task_center/task_center_models.dart';
import '../theme/app_design_tokens.dart';
import 'chat_timeline.dart';

typedef TaskCenterWorkspaceMessageSender =
    Future<TaskCenterWorkspaceMessageReply> Function(
      TaskWorkspace workspace,
      String message,
    );

class TaskCenterWorkspaceMessageReply {
  const TaskCenterWorkspaceMessageReply({
    required this.controller,
    required this.messageStartIndex,
    required this.completedText,
    required this.createdAt,
  });

  factory TaskCenterWorkspaceMessageReply.started({
    required ChatController controller,
    required int messageStartIndex,
    required Future<String> completedText,
  }) {
    return TaskCenterWorkspaceMessageReply(
      controller: controller,
      messageStartIndex: messageStartIndex,
      completedText: completedText,
      createdAt: DateTime.now(),
    );
  }

  final ChatController controller;
  final int messageStartIndex;
  final Future<String> completedText;
  final DateTime createdAt;

  String get currentText {
    return _workspaceAgentReplyText(controller, messageStartIndex);
  }
}

class TaskCenterDialog extends StatelessWidget {
  const TaskCenterDialog({
    super.key,
    required this.controller,
    this.agentServers = const <AgentServerConfig>[],
    this.sessionControllers = const <ChatController>[],
    this.defaultWorkspaceCwd = '',
    this.onSelectSession,
    this.onSendWorkspaceMessage,
  });

  final TaskCenterController controller;
  final List<AgentServerConfig> agentServers;
  final List<ChatController> sessionControllers;
  final String defaultWorkspaceCwd;
  final ValueChanged<AgentSession>? onSelectSession;
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
          sessionControllers: sessionControllers,
          defaultWorkspaceCwd: defaultWorkspaceCwd,
          onSelectSession: onSelectSession,
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
    this.sessionControllers = const <ChatController>[],
    this.defaultWorkspaceCwd = '',
    this.renderBoardView = true,
    this.onSelectSession,
    this.onSendWorkspaceMessage,
  });

  final TaskCenterController controller;
  final List<AgentServerConfig> agentServers;
  final List<ChatController> sessionControllers;
  final String defaultWorkspaceCwd;
  final bool renderBoardView;
  final ValueChanged<AgentSession>? onSelectSession;
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
              : _TaskCenterWorkspaceTabs(
                  controller: widget.controller,
                  workspace: workspace,
                  renderBoardView: widget.renderBoardView,
                  selectedTask: selectedTask,
                  agentServers: widget.agentServers,
                  sessionControllers: widget.sessionControllers,
                  onSelectSession: widget.onSelectSession,
                  onSendWorkspaceMessage: widget.onSendWorkspaceMessage,
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
    final workspace = await widget.controller.createWorkspace(
      title: title,
      workspaceCwd: widget.defaultWorkspaceCwd,
    );
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
        defaultWorkspaceCwd: widget.defaultWorkspaceCwd,
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
            _RoleSummaryPill(
              label: 'Cwd',
              value: _workspaceCwdLabel(selectedWorkspace?.workspaceCwd ?? ''),
              fallback: 'app cwd',
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

String _workspaceCwdLabel(String cwd) {
  final clean = cwd.trim();
  if (clean.isEmpty) return '';
  final parts = clean.split(Platform.pathSeparator)
    ..removeWhere((part) => part.isEmpty);
  return parts.isEmpty ? clean : parts.last;
}

class _TaskCenterWorkspaceTabs extends StatelessWidget {
  const _TaskCenterWorkspaceTabs({
    required this.controller,
    required this.workspace,
    required this.renderBoardView,
    required this.selectedTask,
    required this.agentServers,
    required this.sessionControllers,
    required this.onSelectSession,
    required this.onSendWorkspaceMessage,
    required this.onSelectTask,
    required this.onMoveTask,
  });

  final TaskCenterController controller;
  final TaskWorkspace workspace;
  final bool renderBoardView;
  final TaskCenterTask? selectedTask;
  final List<AgentServerConfig> agentServers;
  final List<ChatController> sessionControllers;
  final ValueChanged<AgentSession>? onSelectSession;
  final TaskCenterWorkspaceMessageSender? onSendWorkspaceMessage;
  final ValueChanged<TaskCenterTask> onSelectTask;
  final void Function(TaskCenterTask task, TaskCenterStatus status, int index)
  onMoveTask;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      initialIndex: 0,
      child: Column(
        children: [
          Material(
            color: AppColors.surface,
            child: Align(
              alignment: Alignment.centerLeft,
              child: TabBar(
                isScrollable: true,
                labelColor: AppColors.primaryDark,
                unselectedLabelColor: AppColors.textSecondary,
                indicatorColor: AppColors.primary,
                tabs: const [
                  Tab(text: 'Workspace Chat'),
                  Tab(text: 'Agents'),
                  Tab(text: 'Kanban'),
                ],
              ),
            ),
          ),
          const Divider(height: 1, color: AppColors.border),
          Expanded(
            child: TabBarView(
              children: [
                _WorkspaceChatPanel(
                  controller: controller,
                  workspace: workspace,
                  onSendWorkspaceMessage: onSendWorkspaceMessage,
                ),
                _TaskCenterAgentsPanel(
                  workspace: workspace,
                  sessionControllers: sessionControllers,
                  onSelectSession: onSelectSession,
                ),
                _KanbanTaskWorkspace(
                  controller: controller,
                  workspace: workspace,
                  renderBoardView: renderBoardView,
                  selectedTask: selectedTask,
                  agentServers: agentServers,
                  onSelectTask: onSelectTask,
                  onMoveTask: onMoveTask,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _KanbanTaskWorkspace extends StatelessWidget {
  const _KanbanTaskWorkspace({
    required this.controller,
    required this.workspace,
    required this.renderBoardView,
    required this.selectedTask,
    required this.agentServers,
    required this.onSelectTask,
    required this.onMoveTask,
  });

  final TaskCenterController controller;
  final TaskWorkspace workspace;
  final bool renderBoardView;
  final TaskCenterTask? selectedTask;
  final List<AgentServerConfig> agentServers;
  final ValueChanged<TaskCenterTask> onSelectTask;
  final void Function(TaskCenterTask task, TaskCenterStatus status, int index)
  onMoveTask;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _BoardSurface(
            workspace: workspace,
            renderBoardView: renderBoardView,
            selectedTaskId: selectedTask?.id,
            onSelectTask: onSelectTask,
            onMoveTask: onMoveTask,
          ),
        ),
        const VerticalDivider(width: 1, color: AppColors.border),
        SizedBox(
          width: 360,
          child: _TaskProtocolPanel(
            controller: controller,
            workspace: workspace,
            task: selectedTask,
            agentServers: agentServers,
          ),
        ),
      ],
    );
  }
}

class _TaskCenterAgentsPanel extends StatefulWidget {
  const _TaskCenterAgentsPanel({
    required this.workspace,
    required this.sessionControllers,
    required this.onSelectSession,
  });

  final TaskWorkspace workspace;
  final List<ChatController> sessionControllers;
  final ValueChanged<AgentSession>? onSelectSession;

  @override
  State<_TaskCenterAgentsPanel> createState() => _TaskCenterAgentsPanelState();
}

class _TaskCenterAgentsPanelState extends State<_TaskCenterAgentsPanel> {
  String? _selectedSessionId;

  @override
  Widget build(BuildContext context) {
    final groups = _agentSessionGroups(
      widget.workspace,
      widget.sessionControllers,
    );
    final sessions = [for (final group in groups) ...group.sessions];
    final selectedSession = _selectedAgentSession(sessions);
    final selectedController = selectedSession == null
        ? null
        : _controllerForSession(selectedSession);
    final isSelectedActive =
        selectedController?.currentSession?.id == selectedSession?.id;

    return Row(
      children: [
        SizedBox(
          width: 300,
          child: ColoredBox(
            color: AppColors.surfaceRaised,
            child: groups.isEmpty
                ? const _EmptyAgentsPanel()
                : ListView(
                    padding: const EdgeInsets.fromLTRB(10, 10, 10, 12),
                    children: [
                      const Text(
                        'Agent Sessions',
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0,
                        ),
                      ),
                      const SizedBox(height: 8),
                      for (final group in groups)
                        _AgentSessionGroupView(
                          group: group,
                          tasks: widget.workspace.tasks,
                          selectedSessionId: selectedSession?.id,
                          onSelectSession: _selectSession,
                        ),
                    ],
                  ),
          ),
        ),
        const VerticalDivider(width: 1, color: AppColors.border),
        Expanded(
          child: selectedSession == null
              ? const _AgentTranscriptEmptyState()
              : isSelectedActive
              ? _AgentTranscriptView(
                  controller: selectedController!,
                  session: selectedSession,
                )
              : _AgentTranscriptLoadState(
                  session: selectedSession,
                  canLoad: widget.onSelectSession != null,
                ),
        ),
      ],
    );
  }

  AgentSession? _selectedAgentSession(List<AgentSession> sessions) {
    if (sessions.isEmpty) return null;
    final selectedId = _selectedSessionId;
    if (selectedId != null) {
      for (final session in sessions) {
        if (session.id == selectedId) return session;
      }
    }
    for (final controller in widget.sessionControllers) {
      final active = controller.currentSession;
      if (active == null) continue;
      if (sessions.any((session) => session.id == active.id)) return active;
    }
    return sessions.first;
  }

  ChatController? _controllerForSession(AgentSession session) {
    for (final controller in widget.sessionControllers) {
      final current = controller.currentSession;
      if (current?.id == session.id) return controller;
      if (controller.sessions.any((item) => item.id == session.id)) {
        return controller;
      }
    }
    return null;
  }

  void _selectSession(AgentSession session) {
    setState(() => _selectedSessionId = session.id);
    if (_controllerForSession(session)?.currentSession?.id == session.id) {
      return;
    }
    widget.onSelectSession?.call(session);
  }
}

class _AgentSessionGroupView extends StatelessWidget {
  const _AgentSessionGroupView({
    required this.group,
    required this.tasks,
    required this.selectedSessionId,
    required this.onSelectSession,
  });

  final _AgentSessionGroup group;
  final List<TaskCenterTask> tasks;
  final String? selectedSessionId;
  final ValueChanged<AgentSession> onSelectSession;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  group.roleLabel,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0,
                  ),
                ),
              ),
              if (group.agentName.isNotEmpty)
                _TinyPill(
                  label: group.agentName,
                  color: AppColors.primaryDark,
                  background: AppColors.primaryMist,
                ),
            ],
          ),
          const SizedBox(height: 6),
          if (group.sessions.isEmpty)
            const Text(
              'No sessions yet',
              style: TextStyle(
                color: AppColors.textTertiary,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 0,
              ),
            )
          else
            for (final session in group.sessions)
              _AgentSessionTile(
                session: session,
                tasks: tasks,
                selected: session.id == selectedSessionId,
                onPressed: () => onSelectSession(session),
              ),
        ],
      ),
    );
  }
}

class _AgentSessionTile extends StatelessWidget {
  const _AgentSessionTile({
    required this.session,
    required this.tasks,
    required this.selected,
    required this.onPressed,
  });

  final AgentSession session;
  final List<TaskCenterTask> tasks;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final runs = _runsForSession(tasks, session);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(AppRadius.sm),
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: selected ? AppColors.primaryMist : AppColors.surface,
              borderRadius: BorderRadius.circular(AppRadius.sm),
              border: Border.all(
                color: selected
                    ? AppColors.primary.withValues(alpha: 0.22)
                    : AppColors.borderSoft,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.chat_bubble_outline_rounded,
                      size: 15,
                      color: selected
                          ? AppColors.primaryDark
                          : AppColors.textSecondary,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        session.displayTitle,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  session.cwd,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 11,
                    height: 1.25,
                    letterSpacing: 0,
                  ),
                ),
                if (runs.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 5,
                    runSpacing: 5,
                    children: [
                      for (final run in runs.take(2))
                        _AgentSessionRunPill(run: run),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AgentSessionRunPill extends StatelessWidget {
  const _AgentSessionRunPill({required this.run});

  final TaskCenterWorkRun run;

  @override
  Widget build(BuildContext context) {
    final isProblem =
        run.state == TaskCenterWorkRunState.stale ||
        run.state == TaskCenterWorkRunState.blocked ||
        run.state == TaskCenterWorkRunState.failed;
    return _TinyPill(
      label: '${run.state.label} · ${_formatRunTime(run.lastHeartbeatAt)}',
      color: isProblem ? AppColors.danger : AppColors.primaryDark,
      background: isProblem ? const Color(0xfffff1f2) : AppColors.primaryMist,
    );
  }
}

class _AgentTranscriptView extends StatelessWidget {
  const _AgentTranscriptView({required this.controller, required this.session});

  final ChatController controller;
  final AgentSession session;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (controller.isStreaming) const _AgentTranscriptRunningBar(),
        Expanded(
          child: ChatTimeline(
            messages: controller.messages,
            agentName: session.agentName ?? controller.agentName,
            hasActiveSession: true,
            activeSessionLabel: session.displayTitle,
          ),
        ),
      ],
    );
  }
}

class _AgentTranscriptRunningBar extends StatelessWidget {
  const _AgentTranscriptRunningBar();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: const BoxDecoration(
        color: AppColors.surfaceRaised,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: const Row(
        children: [
          SizedBox(
            width: 10,
            height: 10,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: 8),
          Text(
            'Running',
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12,
              fontWeight: FontWeight.w800,
              letterSpacing: 0,
            ),
          ),
        ],
      ),
    );
  }
}

class _AgentTranscriptEmptyState extends StatelessWidget {
  const _AgentTranscriptEmptyState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Text(
        'Select an agent session to inspect its transcript.',
        style: TextStyle(
          color: AppColors.textSecondary,
          fontWeight: FontWeight.w700,
          letterSpacing: 0,
        ),
      ),
    );
  }
}

class _AgentTranscriptLoadState extends StatelessWidget {
  const _AgentTranscriptLoadState({
    required this.session,
    required this.canLoad,
  });

  final AgentSession session;
  final bool canLoad;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.manage_search_outlined,
              color: AppColors.primaryDark,
              size: 30,
            ),
            const SizedBox(height: 10),
            Text(
              session.displayTitle,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w900,
                letterSpacing: 0,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              canLoad
                  ? 'Loading this session will show its latest transcript here.'
                  : 'This session is not active, so its transcript is not loaded yet.',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontWeight: FontWeight.w600,
                letterSpacing: 0,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyAgentsPanel extends StatelessWidget {
  const _EmptyAgentsPanel();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(18),
        child: Text(
          'No agent sessions yet.',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppColors.textSecondary,
            fontWeight: FontWeight.w700,
            letterSpacing: 0,
          ),
        ),
      ),
    );
  }
}

class _AgentSessionGroup {
  const _AgentSessionGroup({
    required this.roleLabel,
    required this.agentName,
    required this.sessions,
  });

  final String roleLabel;
  final String agentName;
  final List<AgentSession> sessions;
}

class _AgentRoleSpec {
  const _AgentRoleSpec(this.roleLabel, this.agentName);

  final String roleLabel;
  final String agentName;
}

List<_AgentSessionGroup> _agentSessionGroups(
  TaskWorkspace workspace,
  List<ChatController> sessionControllers,
) {
  final config = workspace.agentConfig;
  final specs = <_AgentRoleSpec>[
    _AgentRoleSpec('Fast Agent', config.fastAgentName.trim()),
    _AgentRoleSpec('Thinking Agent', config.thinkingAgentName.trim()),
    for (final entry in config.workAgentNames.indexed)
      _AgentRoleSpec('Work Agent ${entry.$1 + 1}', entry.$2.trim()),
  ];
  final sessions = _agentSessions(sessionControllers)
    ..sort((a, b) => b.displayTime.compareTo(a.displayTime));
  final matchedIds = <String>{};
  final groups = <_AgentSessionGroup>[];

  for (final spec in specs) {
    if (spec.agentName.isEmpty) continue;
    final roleSessions = sessions
        .where((session) => _sessionAgentName(session) == spec.agentName)
        .toList(growable: false);
    matchedIds.addAll(roleSessions.map((session) => session.id));
    groups.add(
      _AgentSessionGroup(
        roleLabel: spec.roleLabel,
        agentName: spec.agentName,
        sessions: roleSessions,
      ),
    );
  }

  final otherSessions = sessions
      .where((session) => !matchedIds.contains(session.id))
      .toList(growable: false);
  if (otherSessions.isNotEmpty) {
    groups.add(
      _AgentSessionGroup(
        roleLabel: 'Other Agents',
        agentName: '',
        sessions: otherSessions,
      ),
    );
  }

  return groups;
}

List<AgentSession> _agentSessions(List<ChatController> sessionControllers) {
  final sessionsById = <String, AgentSession>{};
  for (final controller in sessionControllers) {
    for (final session in controller.sessions) {
      sessionsById[session.id] = _sessionWithControllerAgent(
        session,
        controller,
      );
    }
    final currentSession = controller.currentSession;
    if (currentSession != null) {
      sessionsById[currentSession.id] = _sessionWithControllerAgent(
        currentSession,
        controller,
      );
    }
  }
  return sessionsById.values.toList(growable: false);
}

AgentSession _sessionWithControllerAgent(
  AgentSession session,
  ChatController controller,
) {
  if (_sessionAgentName(session).isNotEmpty) return session;
  return session.copyWith(agentName: controller.agentName);
}

String _sessionAgentName(AgentSession session) {
  return session.agentName?.trim() ?? '';
}

TaskCenterWorkRun? _activeOrLatestRun(TaskCenterTask task) {
  if (task.workRuns.isEmpty) return null;
  for (final run in task.workRuns.reversed) {
    if (run.isActive) return run;
  }
  return task.workRuns.last;
}

List<TaskCenterWorkRun> _runsForSession(
  List<TaskCenterTask> tasks,
  AgentSession session,
) {
  return [
    for (final task in tasks)
      for (final run in task.workRuns)
        if (run.sessionId == session.id) run,
  ];
}

String _formatRunTime(DateTime value) {
  final local = value.toLocal();
  String two(int input) => input.toString().padLeft(2, '0');
  return '${two(local.month)}/${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
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
    final run = _activeOrLatestRun(task);
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
                if (run != null)
                  _TinyPill(
                    label: '${run.agentName} · ${run.state.label}',
                    color: run.state == TaskCenterWorkRunState.stale
                        ? AppColors.danger
                        : AppColors.primaryDark,
                    background: run.state == TaskCenterWorkRunState.stale
                        ? const Color(0xfffff1f2)
                        : AppColors.primaryMist,
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
  TaskCenterWorkspaceMessageReply? _streamingReply;

  @override
  void dispose() {
    _messageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final streamingReply = _streamingReply;
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
          _WaitingHumanConfirmations(
            controller: widget.controller,
            workspace: widget.workspace,
            onFastAgentMessage: _sendToFastAgent,
          ),
          _WorkerStalledRecoveries(
            controller: widget.controller,
            workspace: widget.workspace,
          ),
          Expanded(
            child: streamingReply == null
                ? _WorkspaceChatMessageList(
                    workspace: widget.workspace,
                    streamingReply: null,
                  )
                : ListenableBuilder(
                    listenable: streamingReply.controller,
                    builder: (context, _) {
                      return _WorkspaceChatMessageList(
                        workspace: widget.workspace,
                        streamingReply: streamingReply,
                      );
                    },
                  ),
          ),
          const Divider(height: 1, color: AppColors.border),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
            child: Row(
              children: [
                Expanded(
                  child: Focus(
                    onKeyEvent: (node, event) {
                      if (event is! KeyDownEvent ||
                          event.logicalKey != LogicalKeyboardKey.enter) {
                        return KeyEventResult.ignored;
                      }
                      if (HardwareKeyboard.instance.isShiftPressed) {
                        return KeyEventResult.ignored;
                      }
                      unawaited(_send());
                      return KeyEventResult.handled;
                    },
                    child: TextField(
                      key: const Key('workspace-chat-input'),
                      controller: _messageController,
                      enabled: !_sending,
                      minLines: 1,
                      maxLines: 3,
                      keyboardType: TextInputType.multiline,
                      textInputAction: TextInputAction.newline,
                      decoration: const InputDecoration(
                        isDense: true,
                        hintText: 'Message workspace',
                        border: OutlineInputBorder(),
                      ),
                    ),
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
    setState(() {
      _sending = true;
      _streamingReply = null;
    });
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
      await _sendToFastAgent(content: content);
    } catch (error) {
      await _postSystemMessage('$error');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _sendToFastAgent({
    required String content,
    String? taskId,
  }) async {
    final workspace = widget.workspace;
    final fastAgentName = workspace.agentConfig.fastAgentName.trim();
    if (fastAgentName.isEmpty) {
      await _postSystemMessage('fast agent is not configured.');
      return;
    }

    final sender = widget.onSendWorkspaceMessage;
    if (sender == null) {
      await _postSystemMessage('fast agent runner is not connected.');
      return;
    }

    TaskCenterWorkspaceMessageReply? reply;
    try {
      final beforeMessages = await widget.controller.listWorkspaceChatMessages(
        workspaceId: workspace.id,
      );
      reply = await sender(workspace, content);
      if (mounted) setState(() => _streamingReply = reply);
      final response = (await reply.completedText).trim();
      final afterMessages = await widget.controller.listWorkspaceChatMessages(
        workspaceId: workspace.id,
      );
      final fastAgentAlreadyPosted = afterMessages
          .skip(beforeMessages.length)
          .any(
            (message) =>
                message.role == TaskWorkspaceChatRole.fastAgent &&
                message.actor == fastAgentName,
          );
      if (response.isNotEmpty && !fastAgentAlreadyPosted) {
        await widget.controller.postWorkspaceChatMessage(
          workspaceId: workspace.id,
          role: TaskWorkspaceChatRole.fastAgent,
          actor: fastAgentName,
          agentName: fastAgentName,
          content: response,
          taskId: taskId,
        );
      }
    } finally {
      if (mounted && identical(_streamingReply, reply)) {
        setState(() => _streamingReply = null);
      }
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

class _WorkspaceChatMessageList extends StatefulWidget {
  const _WorkspaceChatMessageList({
    required this.workspace,
    required this.streamingReply,
  });

  final TaskWorkspace workspace;
  final TaskCenterWorkspaceMessageReply? streamingReply;

  @override
  State<_WorkspaceChatMessageList> createState() =>
      _WorkspaceChatMessageListState();
}

class _WorkspaceChatMessageListState extends State<_WorkspaceChatMessageList> {
  final ScrollController _scrollController = ScrollController();
  String _lastMessageKey = '';

  @override
  void initState() {
    super.initState();
    _lastMessageKey = _messageKey;
    _scheduleScrollToLatest();
  }

  @override
  void didUpdateWidget(covariant _WorkspaceChatMessageList oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextKey = _messageKey;
    if (nextKey == _lastMessageKey) return;
    _lastMessageKey = nextKey;
    _scheduleScrollToLatest();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final messages = _workspaceChatMessagesWithStreamingReply(
      widget.workspace,
      widget.streamingReply,
    );
    if (messages.isEmpty) return const SizedBox.shrink();
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
      itemCount: messages.length,
      itemBuilder: (context, index) {
        return _WorkspaceChatBubble(message: messages[index]);
      },
    );
  }

  String get _messageKey {
    final messages = _workspaceChatMessagesWithStreamingReply(
      widget.workspace,
      widget.streamingReply,
    );
    if (messages.isEmpty) return '0';
    final last = messages.last;
    return '${messages.length}:${last.id}:${last.content.length}';
  }

  void _scheduleScrollToLatest() {
    const delays = <Duration>[
      Duration.zero,
      Duration(milliseconds: 80),
      Duration(milliseconds: 240),
    ];
    for (final delay in delays) {
      unawaited(
        Future<void>.delayed(delay, () {
          if (!mounted) return;
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => _scrollToLatest(),
          );
        }),
      );
    }
  }

  void _scrollToLatest() {
    if (!mounted || !_scrollController.hasClients) return;
    final position = _scrollController.position;
    _scrollController.jumpTo(position.maxScrollExtent);
  }
}

class _WaitingHumanConfirmations extends StatefulWidget {
  const _WaitingHumanConfirmations({
    required this.controller,
    required this.workspace,
    required this.onFastAgentMessage,
  });

  final TaskCenterController controller;
  final TaskWorkspace workspace;
  final Future<void> Function({required String content, String? taskId})
  onFastAgentMessage;

  @override
  State<_WaitingHumanConfirmations> createState() =>
      _WaitingHumanConfirmationsState();
}

class _WaitingHumanConfirmationsState
    extends State<_WaitingHumanConfirmations> {
  final Map<String, String> _customAnswers = <String, String>{};
  String? _submittingQuestionId;

  @override
  Widget build(BuildContext context) {
    final pending = _pendingHumanQuestions(widget.workspace);
    if (pending.isEmpty) return const SizedBox.shrink();

    return DecoratedBox(
      decoration: const BoxDecoration(color: Color(0xfffffbeb)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
            child: Row(
              children: [
                const Icon(
                  Icons.rule_folder_outlined,
                  size: 17,
                  color: AppColors.warning,
                ),
                const SizedBox(width: 6),
                const Expanded(
                  child: Text(
                    'Waiting for you',
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0,
                    ),
                  ),
                ),
                _TinyPill(
                  label: '${pending.length}',
                  color: AppColors.warning,
                  background: const Color(0xfffff7ed),
                ),
              ],
            ),
          ),
          SizedBox(
            height: pending.length == 1 ? 224 : 252,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 10),
              itemCount: pending.length,
              separatorBuilder: (context, index) => const SizedBox(width: 10),
              itemBuilder: (context, index) {
                final item = pending[index];
                return _WaitingHumanCard(
                  task: item.task,
                  question: item.question,
                  customAnswer: _customAnswers[item.question.id] ?? '',
                  submitting: _submittingQuestionId == item.question.id,
                  onCustomAnswerChanged: (value) {
                    setState(() => _customAnswers[item.question.id] = value);
                  },
                  onAnswer: (answer) => unawaited(
                    _answerQuestion(item.task, item.question, answer),
                  ),
                );
              },
            ),
          ),
          const Divider(height: 1, color: AppColors.border),
        ],
      ),
    );
  }

  Future<void> _answerQuestion(
    TaskCenterTask task,
    TaskCenterHumanQuestion question,
    String answer,
  ) async {
    final cleanAnswer = answer.trim();
    if (cleanAnswer.isEmpty || _submittingQuestionId != null) return;
    setState(() => _submittingQuestionId = question.id);

    final workspace = widget.workspace;
    final content = [
      'Human confirmation answered',
      'Task ID: ${task.id}',
      'Task: ${task.title}',
      'Question: ${question.question}',
      'Answer: $cleanAnswer',
    ].join('\n');

    try {
      final answeredTask = await widget.controller.answerHumanQuestion(
        workspaceId: workspace.id,
        taskId: task.id,
        questionId: question.id,
        answer: cleanAnswer,
      );
      await widget.controller.postWorkspaceChatMessage(
        workspaceId: workspace.id,
        role: TaskWorkspaceChatRole.human,
        actor: 'human',
        content: content,
        taskId: task.id,
        metadata: <String, Object?>{
          'human_confirmation': 'answered',
          'question_id': question.id,
        },
      );

      if (answeredTask.humanQuestions.any((item) => !item.resolved)) return;

      final fastAgentName = workspace.agentConfig.fastAgentName.trim();
      if (fastAgentName.isEmpty) {
        await _postSystemMessage('fast agent is not configured.');
        return;
      }

      await widget.controller.transferTaskOwner(
        workspaceId: workspace.id,
        taskId: task.id,
        owner: TaskCenterTaskOwner.fastAgent(fastAgentName),
        readiness: TaskCenterReadiness.needsInfo,
        routeReason: 'Human confirmation answered.',
        actor: 'human',
      );

      await widget.onFastAgentMessage(content: content, taskId: task.id);
    } catch (error) {
      await _postSystemMessage('$error');
    } finally {
      if (mounted) setState(() => _submittingQuestionId = null);
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

class _WorkerStalledRecoveries extends StatefulWidget {
  const _WorkerStalledRecoveries({
    required this.controller,
    required this.workspace,
  });

  final TaskCenterController controller;
  final TaskWorkspace workspace;

  @override
  State<_WorkerStalledRecoveries> createState() =>
      _WorkerStalledRecoveriesState();
}

class _WorkerStalledRecoveriesState extends State<_WorkerStalledRecoveries> {
  List<TaskCenterTask> _stalled = const <TaskCenterTask>[];
  String? _submittingTaskId;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant _WorkerStalledRecoveries oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.workspace.id != widget.workspace.id ||
        oldWidget.workspace.updatedAt != widget.workspace.updatedAt) {
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final stalled = await widget.controller.listStalledWork(
      workspaceId: widget.workspace.id,
    );
    if (!mounted) return;
    setState(() => _stalled = stalled);
  }

  @override
  Widget build(BuildContext context) {
    if (_stalled.isEmpty) return const SizedBox.shrink();
    return DecoratedBox(
      decoration: const BoxDecoration(color: Color(0xfffff1f2)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
            child: Row(
              children: [
                const Icon(
                  Icons.report_problem_outlined,
                  size: 17,
                  color: AppColors.danger,
                ),
                const SizedBox(width: 6),
                const Expanded(
                  child: Text(
                    'Worker stalled',
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0,
                    ),
                  ),
                ),
                _TinyPill(
                  label: '${_stalled.length}',
                  color: AppColors.danger,
                  background: AppColors.surface,
                ),
              ],
            ),
          ),
          SizedBox(
            height: 224,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 10),
              itemCount: _stalled.length,
              separatorBuilder: (context, index) => const SizedBox(width: 10),
              itemBuilder: (context, index) {
                final task = _stalled[index];
                return _WorkerStalledCard(
                  task: task,
                  workspace: widget.workspace,
                  submitting: _submittingTaskId == task.id,
                  onRecover: (action, agentName) =>
                      unawaited(_recover(task, action, agentName)),
                );
              },
            ),
          ),
          const Divider(height: 1, color: AppColors.border),
        ],
      ),
    );
  }

  Future<void> _recover(
    TaskCenterTask task,
    TaskCenterRecoverAction action,
    String agentName,
  ) async {
    if (_submittingTaskId != null) return;
    setState(() => _submittingTaskId = task.id);
    try {
      await widget.controller.recoverStalledTask(
        workspaceId: widget.workspace.id,
        taskId: task.id,
        action: action,
        agentName: agentName,
        reason: 'Recovered from workspace chat.',
        actor: 'human',
      );
      await _load();
    } finally {
      if (mounted) setState(() => _submittingTaskId = null);
    }
  }
}

class _WorkerStalledCard extends StatelessWidget {
  const _WorkerStalledCard({
    required this.task,
    required this.workspace,
    required this.submitting,
    required this.onRecover,
  });

  final TaskCenterTask task;
  final TaskWorkspace workspace;
  final bool submitting;
  final void Function(TaskCenterRecoverAction action, String agentName)
  onRecover;

  @override
  Widget build(BuildContext context) {
    final run = task.workRuns.isEmpty ? null : task.workRuns.last;
    final reassignAgent = _nextWorkerName(workspace, task);
    return SizedBox(
      width: 360,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.border),
        ),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      task.title,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0,
                      ),
                    ),
                  ),
                  _TinyPill(
                    label: run?.state.label ?? 'Missing run',
                    color: AppColors.danger,
                    background: const Color(0xfffff1f2),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                task.routeReason.trim().isEmpty
                    ? 'Current owner: ${task.currentOwner.label}'
                    : task.routeReason,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  height: 1.3,
                  letterSpacing: 0,
                ),
              ),
              if (run != null && run.progressSummary.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  run.progressSummary,
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
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  FilledButton.tonal(
                    onPressed: submitting
                        ? null
                        : () => onRecover(
                            TaskCenterRecoverAction.nudgeWorker,
                            task.currentOwner.agentName,
                          ),
                    child: const Text('催一下 worker'),
                  ),
                  OutlinedButton(
                    onPressed: submitting || reassignAgent.isEmpty
                        ? null
                        : () => onRecover(
                            TaskCenterRecoverAction.reassignWorker,
                            reassignAgent,
                          ),
                    child: const Text('换一个 worker'),
                  ),
                  OutlinedButton(
                    onPressed: submitting
                        ? null
                        : () => onRecover(
                            TaskCenterRecoverAction.returnToFast,
                            '',
                          ),
                    child: const Text('交回 fast agent'),
                  ),
                  OutlinedButton(
                    onPressed: submitting
                        ? null
                        : () => onRecover(
                            TaskCenterRecoverAction.sendToThinking,
                            '',
                          ),
                    child: const Text('转 thinking agent'),
                  ),
                  OutlinedButton(
                    onPressed: submitting
                        ? null
                        : () =>
                              onRecover(TaskCenterRecoverAction.markFailed, ''),
                    child: const Text('标记失败'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WaitingHumanCard extends StatelessWidget {
  const _WaitingHumanCard({
    required this.task,
    required this.question,
    required this.customAnswer,
    required this.submitting,
    required this.onCustomAnswerChanged,
    required this.onAnswer,
  });

  final TaskCenterTask task;
  final TaskCenterHumanQuestion question;
  final String customAnswer;
  final bool submitting;
  final ValueChanged<String> onCustomAnswerChanged;
  final ValueChanged<String> onAnswer;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 360,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.border),
        ),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      task.title,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0,
                      ),
                    ),
                  ),
                  _TinyPill(
                    label: TaskCenterReadiness.waitingHuman.label,
                    color: AppColors.warning,
                    background: const Color(0xfffff7ed),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                question.question,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  height: 1.3,
                  letterSpacing: 0,
                ),
              ),
              if (task.routeReason.trim().isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  task.routeReason,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textTertiary,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0,
                  ),
                ),
              ],
              const SizedBox(height: 10),
              TextField(
                enabled: !submitting,
                minLines: 1,
                maxLines: 2,
                onChanged: onCustomAnswerChanged,
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: 'Custom answer',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 7),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  FilledButton.tonal(
                    onPressed: submitting ? null : () => onAnswer('确认可以继续。'),
                    child: const Text('确认可以继续'),
                  ),
                  OutlinedButton(
                    onPressed: submitting
                        ? null
                        : () => onAnswer('需要补充说明：请 fast agent 继续澄清。'),
                    child: const Text('需要补充说明'),
                  ),
                  OutlinedButton(
                    onPressed: submitting
                        ? null
                        : () => onAnswer('打回快速 agent：请重新梳理任务目标和验收条件。'),
                    child: const Text('打回快速 agent'),
                  ),
                  IconButton.filled(
                    tooltip: 'Send custom answer',
                    onPressed: submitting || customAnswer.trim().isEmpty
                        ? null
                        : () => onAnswer(customAnswer),
                    icon: submitting
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send_outlined, size: 18),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PendingHumanQuestion {
  const _PendingHumanQuestion({required this.task, required this.question});

  final TaskCenterTask task;
  final TaskCenterHumanQuestion question;
}

List<_PendingHumanQuestion> _pendingHumanQuestions(TaskWorkspace workspace) {
  final pending = <_PendingHumanQuestion>[];
  for (final task in workspace.tasks) {
    final waitingForHuman =
        task.readiness == TaskCenterReadiness.waitingHuman ||
        task.currentOwner.kind == TaskCenterOwnerKind.human;
    if (!waitingForHuman) continue;
    for (final question in task.humanQuestions) {
      if (question.resolved) continue;
      pending.add(_PendingHumanQuestion(task: task, question: question));
    }
  }
  pending.sort((a, b) => b.task.updatedAt.compareTo(a.task.updatedAt));
  return pending;
}

String _nextWorkerName(TaskWorkspace workspace, TaskCenterTask task) {
  for (final agentName in workspace.agentConfig.workAgentNames) {
    if (agentName != task.currentOwner.agentName) return agentName;
  }
  return workspace.agentConfig.workAgentNames.isEmpty
      ? task.currentOwner.agentName
      : workspace.agentConfig.workAgentNames.first;
}

List<TaskWorkspaceChatMessage> _workspaceChatMessagesWithStreamingReply(
  TaskWorkspace workspace,
  TaskCenterWorkspaceMessageReply? streamingReply,
) {
  final messages = List<TaskWorkspaceChatMessage>.of(workspace.chatMessages);
  if (streamingReply == null) return messages;

  final fastAgentName = workspace.agentConfig.fastAgentName.trim();
  final currentText = streamingReply.currentText.trim();
  messages.add(
    TaskWorkspaceChatMessage(
      id: 'streaming-fast-agent-reply',
      workspaceId: workspace.id,
      role: TaskWorkspaceChatRole.fastAgent,
      actor: fastAgentName.isEmpty ? 'fast agent' : fastAgentName,
      agentName: fastAgentName,
      content: currentText.isEmpty ? '...' : currentText,
      createdAt: streamingReply.createdAt,
      metadata: const <String, Object?>{'streaming': true},
    ),
  );
  return messages;
}

String _workspaceAgentReplyText(
  ChatController controller,
  int messageStartIndex,
) {
  return controller.messages
      .skip(messageStartIndex)
      .where((message) => message.role == ChatMessageRole.assistant)
      .map((message) => message.text.trim())
      .where((text) => text.isNotEmpty)
      .join('\n')
      .trim();
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
            MarkdownBody(
              data: message.content,
              selectable: true,
              onTapLink: (_, href, _) => _openWorkspaceChatLink(href),
              styleSheet: _workspaceChatMarkdownStyle(context),
            ),
          ],
        ),
      ),
    );
  }
}

MarkdownStyleSheet _workspaceChatMarkdownStyle(BuildContext context) {
  const baseTextStyle = TextStyle(
    color: AppColors.textPrimary,
    fontSize: 12.5,
    fontWeight: FontWeight.w600,
    height: 1.35,
    letterSpacing: 0,
  );
  return MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
    p: baseTextStyle,
    strong: baseTextStyle.copyWith(fontWeight: FontWeight.w900),
    em: baseTextStyle.copyWith(fontStyle: FontStyle.italic),
    a: baseTextStyle.copyWith(
      color: AppColors.primaryDark,
      fontWeight: FontWeight.w800,
      decoration: TextDecoration.underline,
      decorationColor: AppColors.primaryDark,
    ),
    code: baseTextStyle.copyWith(
      fontFamily: 'monospace',
      backgroundColor: AppColors.surfaceRaised,
      fontSize: 12,
    ),
    listBullet: baseTextStyle,
    blockSpacing: 8,
    listIndent: 22,
    codeblockPadding: const EdgeInsets.all(7),
    codeblockDecoration: BoxDecoration(
      color: AppColors.surfaceRaised,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      border: Border.all(color: AppColors.border),
    ),
    tableHead: baseTextStyle.copyWith(fontWeight: FontWeight.w900),
    tableBody: baseTextStyle,
    tableBorder: TableBorder.all(color: AppColors.border, width: 1),
    tableCellsPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
    tableHeadCellsPadding: const EdgeInsets.symmetric(
      horizontal: 8,
      vertical: 6,
    ),
    tableHeadCellsDecoration: const BoxDecoration(color: AppColors.surface),
  );
}

void _openWorkspaceChatLink(String? href) {
  final raw = href?.trim();
  if (raw == null || raw.isEmpty) return;
  final uri = Uri.tryParse(raw);
  if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) return;
  if (!Platform.isMacOS) return;
  unawaited(
    (() async {
      try {
        await Process.run('open', [uri.toString()]);
      } catch (_) {
        // Ignore link launch failures; the rendered URL remains selectable.
      }
    })(),
  );
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
                  _TaskExecutionPanel(task: task),
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
    required this.defaultWorkspaceCwd,
    required this.agentServers,
  });

  final TaskCenterController controller;
  final TaskWorkspace workspace;
  final String defaultWorkspaceCwd;
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
  late final TextEditingController _workspaceCwdController =
      TextEditingController(
        text: widget.workspace.workspaceCwd.trim().isEmpty
            ? widget.defaultWorkspaceCwd
            : widget.workspace.workspaceCwd,
      );
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
    _workspaceCwdController.dispose();
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
              _ProtocolTextField(
                label: 'Workspace cwd',
                controller: _workspaceCwdController,
                maxLines: 1,
              ),
              const SizedBox(height: 10),
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
      workspaceCwd: _workspaceCwdController.text,
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

class _TaskExecutionPanel extends StatelessWidget {
  const _TaskExecutionPanel({required this.task});

  final TaskCenterTask task;

  @override
  Widget build(BuildContext context) {
    final run = _activeOrLatestRun(task);
    if (run == null) {
      return const _PanelSection(
        title: 'Execution',
        children: [
          Text(
            'No worker run yet.',
            style: TextStyle(
              color: AppColors.textSecondary,
              fontWeight: FontWeight.w600,
              letterSpacing: 0,
            ),
          ),
        ],
      );
    }
    return _PanelSection(
      title: 'Execution',
      children: [
        _InfoRow(label: 'Worker', value: run.agentName),
        _InfoRow(label: 'State', value: run.state.label),
        _InfoRow(
          label: 'Last heartbeat',
          value: _formatRunTime(run.lastHeartbeatAt),
        ),
        if (run.progressSummary.isNotEmpty)
          _InfoRow(label: 'Progress', value: run.progressSummary),
        if (run.blockerReason.isNotEmpty)
          _InfoRow(label: 'Blocker', value: run.blockerReason),
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 98,
            child: Text(
              label,
              style: const TextStyle(
                color: AppColors.textTertiary,
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 0,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
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
