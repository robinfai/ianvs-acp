import 'dart:async';

import 'package:flutter/material.dart';

import '../../acp/agent_session.dart';
import '../../workspace/workspace.dart';
import '../../workspace/workspace_sidebar_state_store.dart';
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
    this.onNewSessionInWorkspace,
    this.onSelectSession,
    this.canForkSession,
    this.onSessionMenuAction,
    this.onRevealWorkspace,
    this.onCreateWorkspaceWorktree,
    this.onArchiveWorkspaceSessions,
    this.onLoadWorkspaceSessions,
    this.stateStore,
  });

  final String agentName;
  final List<WorkspaceRecord> workspaces;
  final WorkspaceRecord currentWorkspace;
  final AgentSession? currentSession;
  final VoidCallback? onNewSession;
  final VoidCallback? onResumeSession;
  final ValueChanged<WorkspaceRecord>? onNewSessionInWorkspace;
  final ValueChanged<AgentSession>? onSelectSession;
  final bool Function(AgentSession session)? canForkSession;
  final FutureOr<void> Function(
    AgentSession session,
    WorkspaceSessionMenuAction action,
  )?
  onSessionMenuAction;
  final ValueChanged<WorkspaceRecord>? onRevealWorkspace;
  final FutureOr<void> Function(WorkspaceRecord workspace)?
  onCreateWorkspaceWorktree;
  final FutureOr<void> Function(WorkspaceRecord workspace)?
  onArchiveWorkspaceSessions;
  final Future<void> Function(WorkspaceRecord workspace)?
  onLoadWorkspaceSessions;
  final WorkspaceSidebarStateStore? stateStore;

  @override
  State<WorkspaceSidebar> createState() => _WorkspaceSidebarState();
}

class _WorkspaceSidebarState extends State<WorkspaceSidebar> {
  static const Duration _currentWorkspaceAutoLoadDelay = Duration(
    milliseconds: 1,
  );

  final Set<String> _expandedWorkspacePaths = <String>{};
  final Set<String> _pinnedWorkspacePaths = <String>{};
  final Set<String> _hiddenWorkspacePaths = <String>{};
  final Set<String> _loadingSessionWorkspacePaths = <String>{};
  final Set<String> _autoLoadWorkspacePaths = <String>{};
  final Set<String> _loadedSessionWorkspacePaths = <String>{};
  final Map<String, String> _workspaceDisplayNames = <String, String>{};
  final Map<String, String> _sessionLoadErrors = <String, String>{};
  Timer? _currentWorkspaceAutoLoadTimer;
  String? _hoveredWorkspacePath;

  @override
  void initState() {
    super.initState();
    _expandedWorkspacePaths.add(widget.currentWorkspace.path);
    _scheduleLoadCurrentWorkspaceSessions();
    unawaited(_restoreExpandedWorkspacePaths());
    unawaited(_restoreWorkspaceStates());
  }

  @override
  void didUpdateWidget(covariant WorkspaceSidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentWorkspace.path != widget.currentWorkspace.path) {
      _expandedWorkspacePaths.add(widget.currentWorkspace.path);
      _autoLoadWorkspacePaths.add(widget.currentWorkspace.path);
      _persistExpandedWorkspacePaths();
    }

    if (oldWidget.stateStore?.path != widget.stateStore?.path) {
      unawaited(_restoreExpandedWorkspacePaths());
      unawaited(_restoreWorkspaceStates());
    }

    final loaderBecameAvailable =
        oldWidget.onLoadWorkspaceSessions == null &&
        widget.onLoadWorkspaceSessions != null;
    if (loaderBecameAvailable ||
        oldWidget.currentWorkspace.path != widget.currentWorkspace.path) {
      _scheduleLoadCurrentWorkspaceSessions();
    }

    if (loaderBecameAvailable) {
      _scheduleLoadSessionsForAutoLoadWorkspaces();
    }
  }

  @override
  void dispose() {
    _currentWorkspaceAutoLoadTimer?.cancel();
    super.dispose();
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
                final expanded = _expandedWorkspacePaths.contains(
                  workspace.path,
                );
                final sessionLoading = _loadingSessionWorkspacePaths.contains(
                  workspace.path,
                );
                return _WorkspaceGroup(
                  agentName: widget.agentName,
                  workspace: workspace,
                  displayName: _workspaceName(workspace),
                  selected: selected,
                  hovered: hovered,
                  expanded: expanded,
                  currentSession: widget.currentSession,
                  onWorkspacePressed: _workspacePressedCallback(
                    workspace,
                    selected,
                  ),
                  onToggleWorkspace: () => _toggleWorkspace(workspace),
                  onSelectSession: widget.onSelectSession,
                  canForkSession: widget.canForkSession,
                  onSessionMenuAction: widget.onSessionMenuAction,
                  onNewSession: _newSessionCallbackFor(workspace, selected),
                  sessionLoading: sessionLoading,
                  sessionLoadError: _sessionLoadErrors[workspace.path],
                  onRetryLoadSessions: widget.onLoadWorkspaceSessions == null
                      ? null
                      : () => unawaited(
                          _loadWorkspaceSessions(workspace, force: true),
                        ),
                  pinned: _isPinned(workspace),
                  canRevealInFinder: widget.onRevealWorkspace != null,
                  canCreatePermanentWorktree:
                      widget.onCreateWorkspaceWorktree != null,
                  canArchiveConversations:
                      widget.onArchiveWorkspaceSessions != null &&
                      workspace.sessions.isNotEmpty,
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

  VoidCallback? _newSessionCallbackFor(
    WorkspaceRecord workspace,
    bool selected,
  ) {
    final workspaceCallback = widget.onNewSessionInWorkspace;
    if (workspaceCallback != null) {
      return () => workspaceCallback(workspace);
    }
    if (!selected) return null;
    return widget.onNewSession;
  }

  VoidCallback? _workspacePressedCallback(
    WorkspaceRecord workspace,
    bool selected,
  ) {
    if (selected) return null;
    final selectSession = widget.onSelectSession;
    if (selectSession != null && workspace.sessions.isNotEmpty) {
      return () => selectSession(workspace.sessions.first);
    }
    return () => _toggleWorkspace(workspace);
  }

  void _toggleWorkspace(WorkspaceRecord workspace) {
    var expanded = false;
    setState(() {
      if (!_expandedWorkspacePaths.remove(workspace.path)) {
        _expandedWorkspacePaths.add(workspace.path);
        _autoLoadWorkspacePaths.add(workspace.path);
        expanded = true;
      } else {
        _autoLoadWorkspacePaths.remove(workspace.path);
      }
    });
    _persistExpandedWorkspacePaths();
    if (expanded) {
      unawaited(_loadWorkspaceSessions(workspace));
    }
  }

  Future<void> _restoreExpandedWorkspacePaths() async {
    final store = widget.stateStore;
    if (store != null) {
      final hasSavedPaths = await store.hasSavedExpandedWorkspacePaths();
      final paths = await store.loadExpandedWorkspacePaths();
      if (!mounted) return;
      setState(() {
        _expandedWorkspacePaths
          ..clear()
          ..addAll(paths);
        _autoLoadWorkspacePaths.addAll(paths);
        if (!hasSavedPaths) {
          _expandedWorkspacePaths.add(widget.currentWorkspace.path);
        }
      });
    }
    if (!mounted) return;
    _scheduleLoadSessionsForAutoLoadWorkspaces();
  }

  void _scheduleLoadSessionsForAutoLoadWorkspaces() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _loadSessionsForAutoLoadWorkspaces();
    });
  }

  void _scheduleLoadCurrentWorkspaceSessions() {
    if (widget.onLoadWorkspaceSessions == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.onLoadWorkspaceSessions == null) return;
      _currentWorkspaceAutoLoadTimer?.cancel();
      _currentWorkspaceAutoLoadTimer = Timer(
        _currentWorkspaceAutoLoadDelay,
        () {
          _currentWorkspaceAutoLoadTimer = null;
          if (!mounted || widget.onLoadWorkspaceSessions == null) return;
          unawaited(_loadWorkspaceSessions(widget.currentWorkspace));
        },
      );
    });
  }

  void _persistExpandedWorkspacePaths() {
    final store = widget.stateStore;
    if (store == null) return;
    unawaited(
      store
          .saveExpandedWorkspacePaths(Set<String>.from(_expandedWorkspacePaths))
          .catchError((_) {}),
    );
  }

  void _loadSessionsForAutoLoadWorkspaces() {
    for (final workspace in _visibleWorkspaces()) {
      if (!_autoLoadWorkspacePaths.contains(workspace.path)) continue;
      if (!_expandedWorkspacePaths.contains(workspace.path)) continue;
      unawaited(_loadWorkspaceSessions(workspace));
    }
  }

  Future<void> _loadWorkspaceSessions(
    WorkspaceRecord workspace, {
    bool force = false,
  }) async {
    final loader = widget.onLoadWorkspaceSessions;
    if (loader == null) return;
    if (_loadedSessionWorkspacePaths.contains(workspace.path) && !force) {
      return;
    }
    if (_loadingSessionWorkspacePaths.contains(workspace.path)) return;

    setState(() {
      _loadingSessionWorkspacePaths.add(workspace.path);
      _sessionLoadErrors.remove(workspace.path);
    });

    try {
      await loader(workspace);
      if (!mounted) return;
      setState(() {
        _loadedSessionWorkspacePaths.add(workspace.path);
        _loadingSessionWorkspacePaths.remove(workspace.path);
        _sessionLoadErrors.remove(workspace.path);
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingSessionWorkspacePaths.remove(workspace.path);
        _sessionLoadErrors[workspace.path] = error.toString();
      });
    }
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
        _persistWorkspaceStates();
      case _WorkspaceMenuAction.revealInFinder:
        widget.onRevealWorkspace?.call(workspace);
      case _WorkspaceMenuAction.createPermanentWorktree:
        await widget.onCreateWorkspaceWorktree?.call(workspace);
      case _WorkspaceMenuAction.archiveConversations:
        await widget.onArchiveWorkspaceSessions?.call(workspace);
      case _WorkspaceMenuAction.rename:
        await _renameWorkspace(context, workspace);
      case _WorkspaceMenuAction.remove:
        if (workspace.path == widget.currentWorkspace.path) return;
        final wasPinned = _pinnedWorkspacePaths.contains(workspace.path);
        final wasExpanded = _expandedWorkspacePaths.contains(workspace.path);
        final wasAutoLoad = _autoLoadWorkspacePaths.contains(workspace.path);
        setState(() {
          _hiddenWorkspacePaths.add(workspace.path);
          _expandedWorkspacePaths.remove(workspace.path);
          _autoLoadWorkspacePaths.remove(workspace.path);
          _pinnedWorkspacePaths.remove(workspace.path);
        });
        _persistExpandedWorkspacePaths();
        _persistWorkspaceStates();
        _showRemoveWorkspaceUndo(
          context,
          workspace,
          wasPinned: wasPinned,
          wasExpanded: wasExpanded,
          wasAutoLoad: wasAutoLoad,
        );
    }
  }

  void _showRemoveWorkspaceUndo(
    BuildContext context,
    WorkspaceRecord workspace, {
    required bool wasPinned,
    required bool wasExpanded,
    required bool wasAutoLoad,
  }) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text('Removed "${_workspaceName(workspace)}".'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () {
            if (!mounted) return;
            setState(() {
              _hiddenWorkspacePaths.remove(workspace.path);
              if (wasPinned) _pinnedWorkspacePaths.add(workspace.path);
              if (wasExpanded) _expandedWorkspacePaths.add(workspace.path);
              if (wasAutoLoad) _autoLoadWorkspacePaths.add(workspace.path);
            });
            _persistExpandedWorkspacePaths();
            _persistWorkspaceStates();
          },
        ),
      ),
    );
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
    _persistWorkspaceStates();
  }

  Future<void> _restoreWorkspaceStates() async {
    final store = widget.stateStore;
    if (store == null) return;
    final states = await store.loadWorkspaceStates();
    if (!mounted) return;
    setState(() {
      _pinnedWorkspacePaths.clear();
      _hiddenWorkspacePaths.clear();
      _workspaceDisplayNames.clear();
      for (final state in states) {
        if (state.pinned) _pinnedWorkspacePaths.add(state.path);
        if (state.hidden) _hiddenWorkspacePaths.add(state.path);
        final displayName = state.displayName?.trim();
        if (displayName != null && displayName.isNotEmpty) {
          _workspaceDisplayNames[state.path] = displayName;
        }
      }
      _hiddenWorkspacePaths.remove(widget.currentWorkspace.path);
    });
  }

  void _persistWorkspaceStates() {
    final store = widget.stateStore;
    if (store == null) return;
    final paths = <String>{
      ..._pinnedWorkspacePaths,
      ..._hiddenWorkspacePaths,
      ..._workspaceDisplayNames.keys,
    };
    final states = paths
        .map((path) {
          return WorkspaceSidebarWorkspaceState(
            path: path,
            displayName: _workspaceDisplayNames[path],
            pinned: _pinnedWorkspacePaths.contains(path),
            hidden: _hiddenWorkspacePaths.contains(path),
          );
        })
        .toList(growable: false);
    unawaited(store.saveWorkspaceStates(states).catchError((_) {}));
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
    required this.onToggleWorkspace,
    required this.onSelectSession,
    required this.canForkSession,
    required this.onSessionMenuAction,
    required this.onNewSession,
    required this.sessionLoading,
    required this.sessionLoadError,
    required this.onRetryLoadSessions,
    required this.pinned,
    required this.canRevealInFinder,
    required this.canCreatePermanentWorktree,
    required this.canArchiveConversations,
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
  final VoidCallback? onToggleWorkspace;
  final ValueChanged<AgentSession>? onSelectSession;
  final bool Function(AgentSession session)? canForkSession;
  final FutureOr<void> Function(
    AgentSession session,
    WorkspaceSessionMenuAction action,
  )?
  onSessionMenuAction;
  final VoidCallback? onNewSession;
  final bool sessionLoading;
  final String? sessionLoadError;
  final VoidCallback? onRetryLoadSessions;
  final bool pinned;
  final bool canRevealInFinder;
  final bool canCreatePermanentWorktree;
  final bool canArchiveConversations;
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
              canCreatePermanentWorktree: canCreatePermanentWorktree,
              canArchiveConversations: canArchiveConversations,
              canRemove: canRemove,
              onPressed: onWorkspacePressed,
              onToggleWorkspace: onToggleWorkspace,
              onNewSession: onNewSession,
              onMenuAction: onMenuAction,
            ),
            if (expanded && sessionLoading && workspace.sessions.isEmpty)
              _InlineSessionLoadStatus(workspaceName: displayName)
            else if (expanded &&
                sessionLoadError != null &&
                workspace.sessions.isEmpty)
              _InlineSessionLoadError(
                workspaceName: displayName,
                message: sessionLoadError!,
                onRetry: onRetryLoadSessions,
              )
            else if (expanded && workspace.sessions.isEmpty)
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
                  canForkSession: canForkSession,
                  onSessionMenuAction: onSessionMenuAction,
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
    required this.canForkSession,
    required this.onSessionMenuAction,
  });

  final String agentName;
  final WorkspaceRecord workspace;
  final AgentSession? currentSession;
  final ValueChanged<AgentSession>? onSelectSession;
  final bool Function(AgentSession session)? canForkSession;
  final FutureOr<void> Function(
    AgentSession session,
    WorkspaceSessionMenuAction action,
  )?
  onSessionMenuAction;

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
            canFork: canForkSession?.call(session) ?? false,
            onMenuAction: onSessionMenuAction,
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
    required this.canCreatePermanentWorktree,
    required this.canArchiveConversations,
    required this.canRemove,
    required this.onPressed,
    required this.onToggleWorkspace,
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
  final bool canCreatePermanentWorktree;
  final bool canArchiveConversations;
  final bool canRemove;
  final VoidCallback? onPressed;
  final VoidCallback? onToggleWorkspace;
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
        child: GestureDetector(
          onSecondaryTapDown: (details) =>
              _showContextMenu(context, details.globalPosition),
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
                  _WorkspaceDisclosureButton(
                    expanded: expanded,
                    label: displayName,
                    onPressed: onToggleWorkspace,
                  ),
                  const SizedBox(width: 2),
                  Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: selected
                          ? AppColors.primarySoft
                          : AppColors.surface,
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
                      canCreatePermanentWorktree: canCreatePermanentWorktree,
                      canArchiveConversations: canArchiveConversations,
                      canRemove: canRemove,
                      onNewSession: onNewSession,
                      onMenuAction: onMenuAction,
                    )
                  else
                    _CountPill(count: workspace.sessionCount),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showContextMenu(BuildContext context, Offset position) async {
    final overlay = Overlay.of(context).context.findRenderObject();
    if (overlay is! RenderBox) return;
    final action = await showMenu<_WorkspaceMenuAction>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(position.dx, position.dy, 1, 1),
        Offset.zero & overlay.size,
      ),
      surfaceTintColor: Colors.transparent,
      color: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        side: const BorderSide(color: AppColors.border),
      ),
      items: _workspaceMenuItems(
        pinned: pinned,
        canRevealInFinder: canRevealInFinder,
        canCreatePermanentWorktree: canCreatePermanentWorktree,
        canArchiveConversations: canArchiveConversations,
        canRemove: canRemove,
      ),
    );
    if (action == null) return;
    onMenuAction(action);
  }
}

class _WorkspaceDisclosureButton extends StatelessWidget {
  const _WorkspaceDisclosureButton({
    required this.expanded,
    required this.label,
    required this.onPressed,
  });

  final bool expanded;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final tooltip = expanded ? 'Collapse $label' : 'Expand $label';
    return Semantics(
      button: true,
      enabled: onPressed != null,
      label: tooltip,
      child: Tooltip(
        message: tooltip,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.sm),
          onTap: onPressed,
          child: SizedBox(
            width: 18,
            height: 28,
            child: Icon(
              expanded
                  ? Icons.keyboard_arrow_down_rounded
                  : Icons.chevron_right_rounded,
              size: 17,
              color: onPressed == null
                  ? AppColors.textTertiary
                  : AppColors.textSecondary,
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
    required this.canCreatePermanentWorktree,
    required this.canArchiveConversations,
    required this.canRemove,
    required this.onNewSession,
    required this.onMenuAction,
  });

  final WorkspaceRecord workspace;
  final bool pinned;
  final bool canRevealInFinder;
  final bool canCreatePermanentWorktree;
  final bool canArchiveConversations;
  final bool canRemove;
  final VoidCallback? onNewSession;
  final ValueChanged<_WorkspaceMenuAction> onMenuAction;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _WorkspaceMenuButton(
          key: ValueKey<String>('workspace-actions:${workspace.path}'),
          pinned: pinned,
          canRevealInFinder: canRevealInFinder,
          canCreatePermanentWorktree: canCreatePermanentWorktree,
          canArchiveConversations: canArchiveConversations,
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
    super.key,
    required this.pinned,
    required this.canRevealInFinder,
    required this.canCreatePermanentWorktree,
    required this.canArchiveConversations,
    required this.canRemove,
    required this.onSelected,
  });

  final bool pinned;
  final bool canRevealInFinder;
  final bool canCreatePermanentWorktree;
  final bool canArchiveConversations;
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
        return _workspaceMenuItems(
          pinned: pinned,
          canRevealInFinder: canRevealInFinder,
          canCreatePermanentWorktree: canCreatePermanentWorktree,
          canArchiveConversations: canArchiveConversations,
          canRemove: canRemove,
        );
      },
    );
  }
}

List<PopupMenuEntry<_WorkspaceMenuAction>> _workspaceMenuItems({
  required bool pinned,
  required bool canRevealInFinder,
  required bool canCreatePermanentWorktree,
  required bool canArchiveConversations,
  required bool canRemove,
}) {
  return [
    _workspaceMenuItem(
      value: _WorkspaceMenuAction.togglePinned,
      icon: pinned ? Icons.push_pin : Icons.push_pin_outlined,
      label: pinned ? 'Unpin Project' : 'Pin Project',
    ),
    _workspaceMenuItem(
      value: _WorkspaceMenuAction.revealInFinder,
      icon: Icons.folder_open_outlined,
      label: 'Show in Finder',
      enabled: canRevealInFinder,
    ),
    _workspaceMenuItem(
      value: _WorkspaceMenuAction.createPermanentWorktree,
      icon: Icons.call_split_rounded,
      label: 'Create Permanent Worktree',
      enabled: canCreatePermanentWorktree,
    ),
    _workspaceMenuItem(
      value: _WorkspaceMenuAction.rename,
      icon: Icons.edit_outlined,
      label: 'Rename Project',
    ),
    const PopupMenuDivider(height: 8),
    _workspaceMenuItem(
      value: _WorkspaceMenuAction.archiveConversations,
      icon: Icons.archive_outlined,
      label: 'Archive Conversations',
      enabled: canArchiveConversations,
    ),
    _workspaceMenuItem(
      value: _WorkspaceMenuAction.remove,
      icon: Icons.close_rounded,
      label: 'Remove',
      enabled: canRemove,
      destructive: true,
    ),
  ];
}

PopupMenuItem<_WorkspaceMenuAction> _workspaceMenuItem({
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

enum WorkspaceSessionMenuAction {
  togglePinned,
  rename,
  archive,
  toggleUnread,
  revealInFinder,
  copyWorkingDirectory,
  copySessionId,
  copyDeepLink,
  forkLocally,
  forkToNewWorktree,
  openInNewWindow,
}

class _SessionTile extends StatefulWidget {
  const _SessionTile({
    required this.session,
    required this.selected,
    required this.onPressed,
    required this.canFork,
    required this.onMenuAction,
  });

  final AgentSession session;
  final bool selected;
  final VoidCallback? onPressed;
  final bool canFork;
  final FutureOr<void> Function(
    AgentSession session,
    WorkspaceSessionMenuAction action,
  )?
  onMenuAction;

  @override
  State<_SessionTile> createState() => _SessionTileState();
}

class _SessionTileState extends State<_SessionTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(AppRadius.sm);
    final selected = widget.selected;
    final session = widget.session;
    final onPressed = widget.onPressed;
    final onMenuAction = widget.onMenuAction;
    final showActions = selected || _hovered;
    return Semantics(
      button: onPressed != null,
      selected: selected,
      label: session.displayTitle,
      child: Material(
        color: Colors.transparent,
        child: MouseRegion(
          onEnter: (_) => _setHovered(true),
          onExit: (_) => _setHovered(false),
          child: GestureDetector(
            onSecondaryTapDown: onMenuAction == null
                ? null
                : (details) =>
                      _showContextMenu(context, details.globalPosition),
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
                        Stack(
                          clipBehavior: Clip.none,
                          children: [
                            Container(
                              width: 22,
                              height: 22,
                              decoration: BoxDecoration(
                                color: selected
                                    ? AppColors.primarySoft
                                    : AppColors.surfaceRaised,
                                borderRadius: BorderRadius.circular(
                                  AppRadius.sm,
                                ),
                              ),
                              child: Icon(
                                session.unread
                                    ? Icons.mark_chat_unread_outlined
                                    : Icons.chat_bubble_outline_rounded,
                                size: 13,
                                color: selected
                                    ? AppColors.primaryDark
                                    : AppColors.textSecondary,
                              ),
                            ),
                            if (session.unread)
                              Positioned(
                                right: -2,
                                top: -2,
                                child: Container(
                                  width: 7,
                                  height: 7,
                                  decoration: BoxDecoration(
                                    color: AppColors.primary,
                                    borderRadius: BorderRadius.circular(
                                      AppRadius.pill,
                                    ),
                                    border: Border.all(
                                      color: selected
                                          ? AppColors.primaryMist
                                          : AppColors.surface,
                                      width: 1.2,
                                    ),
                                  ),
                                ),
                              ),
                          ],
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
                        if (session.pinned) ...[
                          const SizedBox(width: 5),
                          const Icon(
                            Icons.push_pin,
                            size: 13,
                            color: AppColors.primaryDark,
                          ),
                        ],
                        if (_agentLabel.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          _AgentPill(label: _agentLabel),
                        ],
                        if (onMenuAction != null && showActions) ...[
                          const SizedBox(width: 4),
                          _SessionMenuButton(
                            session: session,
                            canFork: widget.canFork,
                            onSelected: (action) =>
                                onMenuAction.call(session, action),
                          ),
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
        ),
      ),
    );
  }

  void _setHovered(bool hovered) {
    if (_hovered == hovered) return;
    setState(() {
      _hovered = hovered;
    });
  }

  String _formatCreatedAt(DateTime createdAt) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${createdAt.year}-${two(createdAt.month)}-${two(createdAt.day)} '
        '${two(createdAt.hour)}:${two(createdAt.minute)}';
  }

  String get _agentLabel => widget.session.agentName?.trim() ?? '';

  Future<void> _showContextMenu(BuildContext context, Offset position) async {
    final overlay = Overlay.of(context).context.findRenderObject();
    if (overlay is! RenderBox) return;
    final action = await showMenu<WorkspaceSessionMenuAction>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(position.dx, position.dy, 1, 1),
        Offset.zero & overlay.size,
      ),
      surfaceTintColor: Colors.transparent,
      color: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        side: const BorderSide(color: AppColors.border),
      ),
      items: _sessionMenuItems(
        session: widget.session,
        canFork: widget.canFork,
      ),
    );
    if (action == null) return;
    await widget.onMenuAction?.call(widget.session, action);
  }
}

class _SessionMenuButton extends StatelessWidget {
  const _SessionMenuButton({
    required this.session,
    required this.canFork,
    required this.onSelected,
  });

  final AgentSession session;
  final bool canFork;
  final ValueChanged<WorkspaceSessionMenuAction> onSelected;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<WorkspaceSessionMenuAction>(
      tooltip: 'Session actions',
      padding: EdgeInsets.zero,
      icon: const Icon(Icons.more_horiz_rounded, size: 16),
      iconColor: AppColors.textSecondary,
      surfaceTintColor: Colors.transparent,
      color: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        side: const BorderSide(color: AppColors.border),
      ),
      onSelected: onSelected,
      itemBuilder: (context) {
        return _sessionMenuItems(session: session, canFork: canFork);
      },
    );
  }
}

List<PopupMenuEntry<WorkspaceSessionMenuAction>> _sessionMenuItems({
  required AgentSession session,
  required bool canFork,
}) {
  return [
    _sessionMenuItem(
      value: WorkspaceSessionMenuAction.togglePinned,
      icon: session.pinned ? Icons.push_pin : Icons.push_pin_outlined,
      label: session.pinned ? 'Unpin Conversation' : 'Pin Conversation',
    ),
    _sessionMenuItem(
      value: WorkspaceSessionMenuAction.rename,
      icon: Icons.edit_outlined,
      label: 'Rename Conversation',
    ),
    _sessionMenuItem(
      value: WorkspaceSessionMenuAction.archive,
      icon: Icons.archive_outlined,
      label: 'Archive Conversation',
    ),
    _sessionMenuItem(
      value: WorkspaceSessionMenuAction.toggleUnread,
      icon: session.unread
          ? Icons.mark_chat_read_outlined
          : Icons.mark_chat_unread_outlined,
      label: session.unread ? 'Mark as Read' : 'Mark as Unread',
    ),
    const PopupMenuDivider(height: 8),
    _sessionMenuItem(
      value: WorkspaceSessionMenuAction.revealInFinder,
      icon: Icons.folder_open_outlined,
      label: 'Show in Finder',
    ),
    _sessionMenuItem(
      value: WorkspaceSessionMenuAction.copyWorkingDirectory,
      icon: Icons.content_copy_rounded,
      label: 'Copy Working Directory',
    ),
    _sessionMenuItem(
      value: WorkspaceSessionMenuAction.copySessionId,
      icon: Icons.tag_rounded,
      label: 'Copy Session ID',
    ),
    _sessionMenuItem(
      value: WorkspaceSessionMenuAction.copyDeepLink,
      icon: Icons.link_rounded,
      label: 'Copy Deep Link',
    ),
    const PopupMenuDivider(height: 8),
    _sessionMenuItem(
      value: WorkspaceSessionMenuAction.forkLocally,
      icon: Icons.call_split_rounded,
      label: 'Fork Locally',
      enabled: canFork,
    ),
    _sessionMenuItem(
      value: WorkspaceSessionMenuAction.forkToNewWorktree,
      icon: Icons.account_tree_outlined,
      label: 'Fork to New Worktree',
      enabled: canFork,
    ),
    const PopupMenuDivider(height: 8),
    _sessionMenuItem(
      value: WorkspaceSessionMenuAction.openInNewWindow,
      icon: Icons.open_in_new_rounded,
      label: 'Open in New Window',
    ),
  ];
}

PopupMenuItem<WorkspaceSessionMenuAction> _sessionMenuItem({
  required WorkspaceSessionMenuAction value,
  required IconData icon,
  required String label,
  bool enabled = true,
}) {
  final color = enabled ? AppColors.textPrimary : AppColors.textTertiary;
  return PopupMenuItem<WorkspaceSessionMenuAction>(
    value: value,
    enabled: enabled,
    height: 38,
    child: Row(
      children: [
        Icon(icon, size: 17, color: color),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: color,
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

class _InlineSessionLoadStatus extends StatelessWidget {
  const _InlineSessionLoadStatus({required this.workspaceName});

  final String workspaceName;

  @override
  Widget build(BuildContext context) {
    return _InlineWorkspaceStatusFrame(
      child: Row(
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Loading sessions in $workspaceName...',
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
          ),
        ],
      ),
    );
  }
}

class _InlineSessionLoadError extends StatelessWidget {
  const _InlineSessionLoadError({
    required this.workspaceName,
    required this.message,
    required this.onRetry,
  });

  final String workspaceName;
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return _InlineWorkspaceStatusFrame(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Could not load sessions in $workspaceName.',
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
          const SizedBox(height: 3),
          Text(
            message,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.textTertiary,
              fontSize: 10,
              height: 1.2,
            ),
          ),
          if (onRetry != null) ...[
            const SizedBox(height: 6),
            TextButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded, size: 14),
              label: const Text('Retry'),
              style: TextButton.styleFrom(
                foregroundColor: AppColors.primaryDark,
                minimumSize: const Size(70, 28),
                padding: const EdgeInsets.symmetric(horizontal: 8),
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
    );
  }
}

class _InlineWorkspaceStatusFrame extends StatelessWidget {
  const _InlineWorkspaceStatusFrame({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(36, 0, 10, 10),
      child: DecoratedBox(
        decoration: const BoxDecoration(
          border: Border(left: BorderSide(color: AppColors.borderSoft)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(9, 3, 0, 0),
          child: child,
        ),
      ),
    );
  }
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
                  if (onNewSession != null) ...[
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
