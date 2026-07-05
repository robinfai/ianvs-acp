import 'package:flutter/material.dart';

import '../../acp/agent_session.dart';
import '../../workspace/workspace.dart';
import '../theme/app_design_tokens.dart';

class WorkspaceSidebar extends StatefulWidget {
  const WorkspaceSidebar({
    super.key,
    this.agentName = 'Codex',
    required this.workspaces,
    required this.currentWorkspace,
    required this.currentSession,
    required this.onNewSession,
    required this.onResumeSession,
    this.onSelectSession,
    this.onRevealWorkspace,
  });

  final String agentName;
  final List<WorkspaceRecord> workspaces;
  final WorkspaceRecord currentWorkspace;
  final AgentSession? currentSession;
  final VoidCallback? onNewSession;
  final VoidCallback? onResumeSession;
  final ValueChanged<AgentSession>? onSelectSession;
  final ValueChanged<WorkspaceRecord>? onRevealWorkspace;

  @override
  State<WorkspaceSidebar> createState() => _WorkspaceSidebarState();
}

class _WorkspaceSidebarState extends State<WorkspaceSidebar> {
  final Set<String> _expandedWorkspacePaths = <String>{};
  final Set<String> _pinnedWorkspacePaths = <String>{};
  final Set<String> _hiddenWorkspacePaths = <String>{};
  final Map<String, String> _workspaceDisplayNames = <String, String>{};
  String? _hoveredWorkspacePath;

  @override
  void initState() {
    super.initState();
    _expandedWorkspacePaths.add(widget.currentWorkspace.path);
  }

  @override
  void didUpdateWidget(covariant WorkspaceSidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    _expandedWorkspacePaths.add(widget.currentWorkspace.path);
    final availablePaths = widget.workspaces
        .map((workspace) => workspace.path)
        .toSet();
    _expandedWorkspacePaths.removeWhere(
      (path) => !availablePaths.contains(path),
    );
  }

  @override
  Widget build(BuildContext context) {
    final workspaces = _visibleWorkspaces();
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
                  'Workspaces',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: AppColors.textPrimary,
                    letterSpacing: 0,
                  ),
                ),
                const Spacer(),
                _SidebarIconButton(
                  icon: Icons.add_rounded,
                  tooltip: 'New session',
                  onPressed: widget.onNewSession,
                ),
                const SizedBox(width: 5),
                _SidebarIconButton(
                  icon: Icons.history_rounded,
                  tooltip: 'Resume session',
                  onPressed: widget.onResumeSession,
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
              itemBuilder: (context, index) {
                final workspace = workspaces[index];
                final selected = workspace.path == widget.currentWorkspace.path;
                final hovered = workspace.path == _hoveredWorkspacePath;
                final expanded =
                    selected ||
                    _expandedWorkspacePaths.contains(workspace.path);
                return _WorkspaceGroup(
                  agentName: widget.agentName,
                  workspace: workspace,
                  displayName: _workspaceName(workspace),
                  selected: selected,
                  hovered: hovered,
                  expanded: expanded,
                  currentSession: widget.currentSession,
                  onWorkspacePressed: selected
                      ? null
                      : () => _toggleWorkspace(workspace.path),
                  onSelectSession: widget.onSelectSession,
                  onNewSession: selected ? widget.onNewSession : null,
                  pinned: _isPinned(workspace),
                  canRevealInFinder: widget.onRevealWorkspace != null,
                  canRemove: !selected,
                  onHoverChanged: (hovered) =>
                      _setHoveredWorkspace(workspace.path, hovered),
                  onMenuAction: (action) =>
                      _handleWorkspaceMenuAction(context, workspace, action),
                );
              },
              separatorBuilder: (context, index) => const SizedBox(height: 8),
              itemCount: workspaces.length,
            ),
          ),
        ],
      ),
    );
  }

  void _toggleWorkspace(String path) {
    setState(() {
      if (!_expandedWorkspacePaths.remove(path)) {
        _expandedWorkspacePaths.add(path);
      }
    });
  }

  List<WorkspaceRecord> _visibleWorkspaces() {
    final originalIndex = <String, int>{
      for (var index = 0; index < widget.workspaces.length; index++)
        widget.workspaces[index].path: index,
    };
    final workspaces = widget.workspaces
        .where(
          (workspace) =>
              workspace.path == widget.currentWorkspace.path ||
              !_hiddenWorkspacePaths.contains(workspace.path),
        )
        .toList();
    workspaces.sort((a, b) {
      final aCurrent = a.path == widget.currentWorkspace.path;
      final bCurrent = b.path == widget.currentWorkspace.path;
      if (aCurrent && !bCurrent) return -1;
      if (bCurrent && !aCurrent) return 1;

      final aPinned = _isPinned(a);
      final bPinned = _isPinned(b);
      if (aPinned && !bPinned) return -1;
      if (bPinned && !aPinned) return 1;

      return (originalIndex[a.path] ?? 0).compareTo(originalIndex[b.path] ?? 0);
    });
    return workspaces;
  }

  bool _isPinned(WorkspaceRecord workspace) {
    return workspace.pinned || _pinnedWorkspacePaths.contains(workspace.path);
  }

  String _workspaceName(WorkspaceRecord workspace) {
    final displayName = _workspaceDisplayNames[workspace.path]?.trim();
    return displayName == null || displayName.isEmpty
        ? workspace.name
        : displayName;
  }

  void _setHoveredWorkspace(String path, bool hovered) {
    setState(() {
      if (hovered) {
        _hoveredWorkspacePath = path;
      } else if (_hoveredWorkspacePath == path) {
        _hoveredWorkspacePath = null;
      }
    });
  }

  Future<void> _handleWorkspaceMenuAction(
    BuildContext context,
    WorkspaceRecord workspace,
    _WorkspaceMenuAction action,
  ) async {
    switch (action) {
      case _WorkspaceMenuAction.togglePinned:
        setState(() {
          if (!_pinnedWorkspacePaths.remove(workspace.path)) {
            _pinnedWorkspacePaths.add(workspace.path);
          }
        });
      case _WorkspaceMenuAction.revealInFinder:
        widget.onRevealWorkspace?.call(workspace);
      case _WorkspaceMenuAction.createPermanentWorktree:
      case _WorkspaceMenuAction.archiveConversations:
        break;
      case _WorkspaceMenuAction.rename:
        await _renameWorkspace(context, workspace);
      case _WorkspaceMenuAction.remove:
        if (workspace.path == widget.currentWorkspace.path) return;
        setState(() {
          _hiddenWorkspacePaths.add(workspace.path);
          _expandedWorkspacePaths.remove(workspace.path);
          _pinnedWorkspacePaths.remove(workspace.path);
        });
    }
  }

  Future<void> _renameWorkspace(
    BuildContext context,
    WorkspaceRecord workspace,
  ) async {
    var draftName = _workspaceName(workspace);
    final nextName = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Rename Workspace'),
          content: SizedBox(
            width: 320,
            child: TextFormField(
              initialValue: draftName,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Display name',
                border: OutlineInputBorder(),
              ),
              onChanged: (value) => draftName = value,
              onFieldSubmitted: (value) => Navigator.of(context).pop(value),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(draftName),
              child: const Text('Rename'),
            ),
          ],
        );
      },
    );
    final trimmed = nextName?.trim();
    if (trimmed == null || trimmed.isEmpty) return;
    if (!mounted) return;
    setState(() {
      _workspaceDisplayNames[workspace.path] = trimmed;
    });
  }
}

class _WorkspaceGroup extends StatelessWidget {
  const _WorkspaceGroup({
    required this.agentName,
    required this.workspace,
    required this.displayName,
    required this.selected,
    required this.hovered,
    required this.expanded,
    required this.currentSession,
    required this.onWorkspacePressed,
    required this.onSelectSession,
    required this.onNewSession,
    required this.pinned,
    required this.canRevealInFinder,
    required this.canRemove,
    required this.onHoverChanged,
    required this.onMenuAction,
  });

  final String agentName;
  final WorkspaceRecord workspace;
  final String displayName;
  final bool selected;
  final bool hovered;
  final bool expanded;
  final AgentSession? currentSession;
  final VoidCallback? onWorkspacePressed;
  final ValueChanged<AgentSession>? onSelectSession;
  final VoidCallback? onNewSession;
  final bool pinned;
  final bool canRevealInFinder;
  final bool canRemove;
  final ValueChanged<bool> onHoverChanged;
  final ValueChanged<_WorkspaceMenuAction> onMenuAction;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => onHoverChanged(true),
      onExit: (_) => onHoverChanged(false),
      child: Container(
        decoration: BoxDecoration(
          color: selected
              ? AppColors.primaryMist
              : hovered
              ? AppColors.surfaceMuted.withValues(alpha: 0.54)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(
            color: selected
                ? AppColors.primary.withValues(alpha: 0.18)
                : AppColors.borderSoft.withValues(alpha: hovered ? 1 : 0),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _WorkspaceTile(
              workspace: workspace,
              displayName: displayName,
              selected: selected,
              hovered: hovered,
              expanded: expanded,
              pinned: pinned,
              canRevealInFinder: canRevealInFinder,
              canRemove: canRemove,
              onPressed: onWorkspacePressed,
              onNewSession: onNewSession,
              onMenuAction: onMenuAction,
            ),
            if (expanded && workspace.sessions.isEmpty)
              _InlineEmptyWorkspaceSessions(
                agentName: agentName,
                workspaceName: displayName,
                active: selected,
                onNewSession: onNewSession,
              )
            else if (expanded)
              Padding(
                padding: const EdgeInsets.fromLTRB(28, 0, 6, 7),
                child: _NestedSessionList(
                  agentName: agentName,
                  workspace: workspace,
                  currentSession: currentSession,
                  onSelectSession: onSelectSession,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _NestedSessionList extends StatelessWidget {
  const _NestedSessionList({
    required this.agentName,
    required this.workspace,
    required this.currentSession,
    required this.onSelectSession,
  });

  final String agentName;
  final WorkspaceRecord workspace;
  final AgentSession? currentSession;
  final ValueChanged<AgentSession>? onSelectSession;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        border: Border(left: BorderSide(color: AppColors.borderSoft)),
      ),
      child: Padding(
        padding: const EdgeInsets.only(left: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: _sessionGroups(),
        ),
      ),
    );
  }

  List<Widget> _sessionGroups() {
    final grouped = workspace.sessionsByAgent(preferredAgent: agentName);
    final showAgentHeadings = grouped.length > 1;
    final widgets = <Widget>[];
    for (final entry in grouped.entries) {
      if (showAgentHeadings) {
        widgets.add(_AgentGroupLabel(label: entry.key));
      }
      for (final session in entry.value) {
        widgets.add(
          _SessionTile(
            session: session,
            selected: session.id == currentSession?.id,
            onPressed:
                onSelectSession == null || session.id == currentSession?.id
                ? null
                : () => onSelectSession!(session),
          ),
        );
        widgets.add(const SizedBox(height: 5));
      }
      if (showAgentHeadings) widgets.add(const SizedBox(height: 3));
    }
    if (widgets.isNotEmpty) widgets.removeLast();
    return widgets;
  }
}

class _WorkspaceTile extends StatelessWidget {
  const _WorkspaceTile({
    required this.workspace,
    required this.displayName,
    required this.selected,
    required this.hovered,
    required this.expanded,
    required this.pinned,
    required this.canRevealInFinder,
    required this.canRemove,
    required this.onPressed,
    required this.onNewSession,
    required this.onMenuAction,
  });

  final WorkspaceRecord workspace;
  final String displayName;
  final bool selected;
  final bool hovered;
  final bool expanded;
  final bool pinned;
  final bool canRevealInFinder;
  final bool canRemove;
  final VoidCallback? onPressed;
  final VoidCallback? onNewSession;
  final ValueChanged<_WorkspaceMenuAction> onMenuAction;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(AppRadius.sm);
    final showActions = selected || hovered;
    return Semantics(
      button: onPressed != null,
      selected: selected,
      label: displayName,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: radius,
          onTap: onPressed,
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: selected ? AppColors.primaryMist : Colors.transparent,
              borderRadius: radius,
              border: Border.all(
                color: selected
                    ? AppColors.primary.withValues(alpha: 0.22)
                    : Colors.transparent,
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: selected ? AppColors.primarySoft : AppColors.surface,
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                    border: Border.all(color: AppColors.borderSoft),
                  ),
                  child: Icon(
                    expanded
                        ? Icons.folder_open_rounded
                        : Icons.folder_outlined,
                    size: 14,
                    color: selected
                        ? AppColors.primaryDark
                        : AppColors.textSecondary,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        displayName,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        workspace.path,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.textTertiary,
                          fontSize: 10,
                          height: 1.2,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                if (showActions)
                  _WorkspaceInlineActions(
                    workspace: workspace,
                    pinned: pinned,
                    canRevealInFinder: canRevealInFinder,
                    canRemove: canRemove,
                    onNewSession: selected ? onNewSession : null,
                    onMenuAction: onMenuAction,
                  )
                else
                  _CountPill(count: workspace.sessionCount),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _WorkspaceInlineActions extends StatelessWidget {
  const _WorkspaceInlineActions({
    required this.workspace,
    required this.pinned,
    required this.canRevealInFinder,
    required this.canRemove,
    required this.onNewSession,
    required this.onMenuAction,
  });

  final WorkspaceRecord workspace;
  final bool pinned;
  final bool canRevealInFinder;
  final bool canRemove;
  final VoidCallback? onNewSession;
  final ValueChanged<_WorkspaceMenuAction> onMenuAction;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _WorkspaceMenuButton(
          pinned: pinned,
          canRevealInFinder: canRevealInFinder,
          canRemove: canRemove,
          onSelected: onMenuAction,
        ),
        if (onNewSession != null) ...[
          const SizedBox(width: 4),
          _TinyActionButton(
            icon: Icons.edit_square,
            tooltip: 'New session in this workspace',
            onPressed: onNewSession,
          ),
        ],
      ],
    );
  }
}

class _WorkspaceMenuButton extends StatelessWidget {
  const _WorkspaceMenuButton({
    required this.pinned,
    required this.canRevealInFinder,
    required this.canRemove,
    required this.onSelected,
  });

  final bool pinned;
  final bool canRevealInFinder;
  final bool canRemove;
  final ValueChanged<_WorkspaceMenuAction> onSelected;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<_WorkspaceMenuAction>(
      tooltip: 'Workspace actions',
      padding: EdgeInsets.zero,
      icon: const Icon(Icons.more_horiz_rounded, size: 17),
      iconColor: AppColors.textSecondary,
      surfaceTintColor: Colors.transparent,
      color: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        side: const BorderSide(color: AppColors.border),
      ),
      onSelected: onSelected,
      itemBuilder: (context) {
        return [
          _menuItem(
            value: _WorkspaceMenuAction.togglePinned,
            icon: pinned ? Icons.push_pin : Icons.push_pin_outlined,
            label: pinned ? 'Unpin Project' : 'Pin Project',
          ),
          _menuItem(
            value: _WorkspaceMenuAction.revealInFinder,
            icon: Icons.folder_open_outlined,
            label: 'Show in Finder',
            enabled: canRevealInFinder,
          ),
          _menuItem(
            value: _WorkspaceMenuAction.createPermanentWorktree,
            icon: Icons.call_split_rounded,
            label: 'Create Permanent Worktree',
            enabled: false,
          ),
          _menuItem(
            value: _WorkspaceMenuAction.rename,
            icon: Icons.edit_outlined,
            label: 'Rename Project',
          ),
          const PopupMenuDivider(height: 8),
          _menuItem(
            value: _WorkspaceMenuAction.archiveConversations,
            icon: Icons.archive_outlined,
            label: 'Archive Conversations',
            enabled: false,
          ),
          _menuItem(
            value: _WorkspaceMenuAction.remove,
            icon: Icons.close_rounded,
            label: 'Remove',
            enabled: canRemove,
            destructive: true,
          ),
        ];
      },
    );
  }

  PopupMenuItem<_WorkspaceMenuAction> _menuItem({
    required _WorkspaceMenuAction value,
    required IconData icon,
    required String label,
    bool enabled = true,
    bool destructive = false,
  }) {
    final color = destructive ? AppColors.danger : AppColors.textPrimary;
    final disabledColor = AppColors.textTertiary;
    return PopupMenuItem<_WorkspaceMenuAction>(
      value: value,
      enabled: enabled,
      height: 38,
      child: Row(
        children: [
          Icon(icon, size: 17, color: enabled ? color : disabledColor),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: enabled ? color : disabledColor,
                fontSize: 13,
                fontWeight: FontWeight.w800,
                letterSpacing: 0,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TinyActionButton extends StatelessWidget {
  const _TinyActionButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: onPressed != null,
      label: tooltip,
      child: Tooltip(
        message: tooltip,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.sm),
          onTap: onPressed,
          child: Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(AppRadius.sm),
              border: Border.all(color: AppColors.borderSoft),
            ),
            child: Icon(
              icon,
              color: onPressed == null
                  ? AppColors.textTertiary
                  : AppColors.textSecondary,
              size: 15,
            ),
          ),
        ),
      ),
    );
  }
}

enum _WorkspaceMenuAction {
  togglePinned,
  revealInFinder,
  createPermanentWorktree,
  rename,
  archiveConversations,
  remove,
}

class _SessionTile extends StatelessWidget {
  const _SessionTile({
    required this.session,
    required this.selected,
    required this.onPressed,
  });

  final AgentSession session;
  final bool selected;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(AppRadius.sm);
    return Semantics(
      button: onPressed != null,
      selected: selected,
      label: session.displayTitle,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: radius,
          onTap: onPressed,
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: selected ? AppColors.primaryMist : AppColors.surface,
              border: Border.all(
                color: selected
                    ? AppColors.primary.withValues(alpha: 0.22)
                    : AppColors.borderSoft,
              ),
              borderRadius: radius,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        color: selected
                            ? AppColors.primarySoft
                            : AppColors.surfaceRaised,
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                      ),
                      child: Icon(
                        Icons.chat_bubble_outline_rounded,
                        size: 13,
                        color: selected
                            ? AppColors.primaryDark
                            : AppColors.textSecondary,
                      ),
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        session.displayTitle,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.w800,
                          fontSize: 12,
                          letterSpacing: 0,
                        ),
                      ),
                    ),
                    if (_agentLabel.isNotEmpty) ...[
                      const SizedBox(width: 6),
                      _AgentPill(label: _agentLabel),
                    ],
                  ],
                ),
                const SizedBox(height: 5),
                Row(
                  children: [
                    const Icon(
                      Icons.access_time_rounded,
                      size: 12,
                      color: AppColors.textTertiary,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        _formatCreatedAt(session.displayTime),
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.textTertiary,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _formatCreatedAt(DateTime createdAt) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${createdAt.year}-${two(createdAt.month)}-${two(createdAt.day)} '
        '${two(createdAt.hour)}:${two(createdAt.minute)}';
  }

  String get _agentLabel => session.agentName?.trim() ?? '';
}

class _InlineEmptyWorkspaceSessions extends StatelessWidget {
  const _InlineEmptyWorkspaceSessions({
    required this.agentName,
    required this.workspaceName,
    required this.active,
    required this.onNewSession,
  });

  final String agentName;
  final String workspaceName;
  final bool active;
  final VoidCallback? onNewSession;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(36, 0, 10, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DecoratedBox(
            decoration: const BoxDecoration(
              border: Border(left: BorderSide(color: AppColors.borderSoft)),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(9, 3, 0, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    active
                        ? 'No sessions yet'
                        : 'No sessions in $workspaceName',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      height: 1.25,
                      letterSpacing: 0,
                    ),
                  ),
                  if (active && onNewSession != null) ...[
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: onNewSession,
                      icon: const Icon(Icons.add_rounded, size: 15),
                      label: const Text('New Session'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.primaryDark,
                        minimumSize: const Size(124, 30),
                        side: const BorderSide(color: Color(0xffd8c8ff)),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(AppRadius.pill),
                        ),
                        textStyle: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
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
    return Semantics(
      button: true,
      enabled: onPressed != null,
      label: tooltip,
      child: Tooltip(
        message: tooltip,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.sm),
          onTap: onPressed,
          child: Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(AppRadius.sm),
              border: Border.all(color: AppColors.border),
            ),
            child: Icon(
              icon,
              color: onPressed == null
                  ? AppColors.textTertiary
                  : AppColors.textSecondary,
              size: 16,
            ),
          ),
        ),
      ),
    );
  }
}

class _AgentGroupLabel extends StatelessWidget {
  const _AgentGroupLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 6),
      child: Text(
        label,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: AppColors.textTertiary,
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: 0,
        ),
      ),
    );
  }
}

class _AgentPill extends StatelessWidget {
  const _AgentPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 78),
      child: Container(
        height: 20,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppColors.primarySoft,
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
        child: Text(
          label,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: AppColors.primaryDark,
            fontSize: 10,
            fontWeight: FontWeight.w800,
            letterSpacing: 0,
          ),
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
      constraints: const BoxConstraints(minWidth: 22),
      height: 20,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: AppColors.borderSoft),
      ),
      child: Text(
        count.toString(),
        style: const TextStyle(
          color: AppColors.textSecondary,
          fontSize: 10,
          fontWeight: FontWeight.w800,
          letterSpacing: 0,
        ),
      ),
    );
  }
}
