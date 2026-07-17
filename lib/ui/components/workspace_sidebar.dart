import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../acp/agent_session.dart';
import '../../workspace/workspace.dart';
import '../../workspace/workspace_sidebar_state_store.dart';
import 'session_time_label.dart';
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
    this.pickWorkspaceDirectory,
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
  final Future<String?> Function()? pickWorkspaceDirectory;
  final WorkspaceSidebarStateStore? stateStore;

  @override
  State<WorkspaceSidebar> createState() => _WorkspaceSidebarState();
}

class _WorkspaceSidebarState extends State<WorkspaceSidebar> {
  static const Duration _currentWorkspaceAutoLoadDelay = Duration(
    milliseconds: 1,
  );
  static const int _defaultVisibleSessionCount = 5;

  final Set<String> _expandedWorkspacePaths = <String>{};
  final Set<String> _showAllSessionWorkspacePaths = <String>{};
  final Set<String> _pinnedWorkspacePaths = <String>{};
  final Set<String> _hiddenWorkspacePaths = <String>{};
  final Set<String> _loadingSessionWorkspacePaths = <String>{};
  final Set<String> _autoLoadWorkspacePaths = <String>{};
  final Set<String> _loadedSessionWorkspacePaths = <String>{};
  final Set<String> _manuallyAddedWorkspacePaths = <String>{};
  final Map<String, String> _workspaceDisplayNames = <String, String>{};
  final Map<String, String> _sessionLoadErrors = <String, String>{};
  final TextEditingController _searchController = TextEditingController();
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
    _searchController.dispose();
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
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 5),
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
                _CountPill(count: workspaces.length),
                const SizedBox(width: 4),
                IconButton(
                  key: const Key('add-workspace-button'),
                  tooltip: 'Add workspace',
                  onPressed: () => unawaited(_addWorkspace()),
                  icon: const Icon(Icons.create_new_folder_outlined, size: 18),
                  visualDensity: VisualDensity.compact,
                  splashRadius: 18,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
            child: _WorkspaceSearchField(
              controller: _searchController,
              onChanged: (_) => setState(() {}),
            ),
          ),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
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
                  workspace: workspace,
                  displayName: _workspaceName(workspace),
                  selected: selected,
                  hovered: hovered,
                  expanded: expanded,
                  currentSession: widget.currentSession,
                  visibleSessionLimit: _defaultVisibleSessionCount,
                  showAllSessions: _showAllSessionWorkspacePaths.contains(
                    workspace.path,
                  ),
                  onExpandSessions: () =>
                      _setWorkspaceSessionsVisible(workspace.path, true),
                  onCollapseSessions: () =>
                      _setWorkspaceSessionsVisible(workspace.path, false),
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
              separatorBuilder: (context, index) => const SizedBox(height: 4),
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
    final query = _searchController.text.trim().toLowerCase();
    final workspacesByPath = <String, WorkspaceRecord>{
      for (final workspace in widget.workspaces) workspace.path: workspace,
    };
    for (final path in _manuallyAddedWorkspacePaths) {
      workspacesByPath.putIfAbsent(
        path,
        () => WorkspaceRecord(
          path: path,
          name: workspaceNameFromPath(path),
          sessions: const <AgentSession>[],
          defaultAgentName: widget.currentWorkspace.defaultAgentName,
        ),
      );
    }
    final allWorkspaces = workspacesByPath.values.toList(growable: false);
    final originalIndex = <String, int>{
      for (var index = 0; index < allWorkspaces.length; index++)
        allWorkspaces[index].path: index,
    };
    final workspaces = allWorkspaces
        .where(
          (workspace) =>
              workspace.path == widget.currentWorkspace.path ||
              !_hiddenWorkspacePaths.contains(workspace.path),
        )
        .where((workspace) => _matchesSearch(workspace, query))
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

  Future<void> _addWorkspace() async {
    final pickDirectory =
        widget.pickWorkspaceDirectory ??
        () =>
            FilePicker.platform.getDirectoryPath(dialogTitle: 'Add Workspace');
    final selectedPath = await pickDirectory();
    if (!mounted) return;
    final path = normalizeWorkspacePath(selectedPath ?? '');
    if (path.isEmpty) return;

    setState(() {
      _manuallyAddedWorkspacePaths.add(path);
      _hiddenWorkspacePaths.remove(path);
      _expandedWorkspacePaths.add(path);
      _autoLoadWorkspacePaths.add(path);
    });
    _persistExpandedWorkspacePaths();
    _persistWorkspaceStates();

    final workspace = _visibleWorkspaces().where((item) => item.path == path);
    if (workspace.isNotEmpty) {
      unawaited(_loadWorkspaceSessions(workspace.first));
    }
  }

  bool _matchesSearch(WorkspaceRecord workspace, String query) {
    if (query.isEmpty) return true;
    final workspaceText = [
      _workspaceName(workspace),
      workspace.name,
      workspace.path,
      for (final session in workspace.sessions) session.displayTitle,
      for (final session in workspace.sessions) session.agentName ?? '',
    ].join('\n').toLowerCase();
    return workspaceText.contains(query);
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

  void _setWorkspaceSessionsVisible(String path, bool showAll) {
    setState(() {
      if (showAll) {
        _showAllSessionWorkspacePaths.add(path);
      } else {
        _showAllSessionWorkspacePaths.remove(path);
      }
    });
  }

  Future<void> _handleWorkspaceMenuAction(
    BuildContext context,
    WorkspaceRecord workspace,
    _WorkspaceMenuAction action,
  ) async {
    switch (action) {
      case _WorkspaceMenuAction.newSession:
        _newSessionCallbackFor(
          workspace,
          workspace.path == widget.currentWorkspace.path,
        )?.call();
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
        final wasShowingAllSessions = _showAllSessionWorkspacePaths.contains(
          workspace.path,
        );
        setState(() {
          _hiddenWorkspacePaths.add(workspace.path);
          _expandedWorkspacePaths.remove(workspace.path);
          _showAllSessionWorkspacePaths.remove(workspace.path);
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
          wasShowingAllSessions: wasShowingAllSessions,
        );
    }
  }

  void _showRemoveWorkspaceUndo(
    BuildContext context,
    WorkspaceRecord workspace, {
    required bool wasPinned,
    required bool wasExpanded,
    required bool wasAutoLoad,
    required bool wasShowingAllSessions,
  }) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text('Hidden "${_workspaceName(workspace)}".'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () {
            if (!mounted) return;
            setState(() {
              _hiddenWorkspacePaths.remove(workspace.path);
              if (wasPinned) _pinnedWorkspacePaths.add(workspace.path);
              if (wasExpanded) _expandedWorkspacePaths.add(workspace.path);
              if (wasShowingAllSessions) {
                _showAllSessionWorkspacePaths.add(workspace.path);
              }
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
      _manuallyAddedWorkspacePaths.clear();
      _workspaceDisplayNames.clear();
      for (final state in states) {
        if (state.pinned) _pinnedWorkspacePaths.add(state.path);
        if (state.hidden) _hiddenWorkspacePaths.add(state.path);
        if (state.manuallyAdded) {
          _manuallyAddedWorkspacePaths.add(state.path);
        }
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
      ..._manuallyAddedWorkspacePaths,
      ..._workspaceDisplayNames.keys,
    };
    final states = paths
        .map((path) {
          return WorkspaceSidebarWorkspaceState(
            path: path,
            displayName: _workspaceDisplayNames[path],
            pinned: _pinnedWorkspacePaths.contains(path),
            hidden: _hiddenWorkspacePaths.contains(path),
            manuallyAdded: _manuallyAddedWorkspacePaths.contains(path),
          );
        })
        .toList(growable: false);
    unawaited(store.saveWorkspaceStates(states).catchError((_) {}));
  }
}

class _WorkspaceSearchField extends StatelessWidget {
  const _WorkspaceSearchField({
    required this.controller,
    required this.onChanged,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 30,
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        textInputAction: TextInputAction.search,
        style: const TextStyle(
          color: AppColors.textPrimary,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0,
        ),
        decoration: InputDecoration(
          hintText: 'Search workspaces...',
          hintStyle: const TextStyle(
            color: AppColors.textTertiary,
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 0,
          ),
          prefixIcon: const Icon(
            Icons.search_rounded,
            size: 16,
            color: AppColors.textSecondary,
          ),
          suffixIcon: controller.text.isEmpty
              ? null
              : IconButton(
                  tooltip: 'Clear workspace search',
                  onPressed: () {
                    controller.clear();
                    onChanged('');
                  },
                  icon: const Icon(Icons.close_rounded, size: 15),
                  color: AppColors.textSecondary,
                  visualDensity: VisualDensity.compact,
                  splashRadius: 16,
                ),
          isDense: true,
          filled: true,
          fillColor: AppColors.surface,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 8,
            vertical: 6,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppRadius.sm),
            borderSide: const BorderSide(color: AppColors.borderSoft),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppRadius.sm),
            borderSide: const BorderSide(color: AppColors.borderSoft),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppRadius.sm),
            borderSide: const BorderSide(color: AppColors.primary),
          ),
        ),
      ),
    );
  }
}

class _WorkspaceGroup extends StatelessWidget {
  const _WorkspaceGroup({
    required this.workspace,
    required this.displayName,
    required this.selected,
    required this.hovered,
    required this.expanded,
    required this.currentSession,
    required this.visibleSessionLimit,
    required this.showAllSessions,
    required this.onExpandSessions,
    required this.onCollapseSessions,
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

  final WorkspaceRecord workspace;
  final String displayName;
  final bool selected;
  final bool hovered;
  final bool expanded;
  final AgentSession? currentSession;
  final int visibleSessionLimit;
  final bool showAllSessions;
  final VoidCallback onExpandSessions;
  final VoidCallback onCollapseSessions;
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
        key: Key('workspace-group:${workspace.path}'),
        decoration: BoxDecoration(
          color: !selected && hovered
              ? AppColors.surfaceMuted.withValues(alpha: 0.54)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadius.sm),
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
                workspaceName: displayName,
                active: selected,
              )
            else if (expanded)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 3, 5),
                child: _NestedSessionList(
                  workspace: workspace,
                  currentSession: currentSession,
                  visibleSessionLimit: visibleSessionLimit,
                  showAllSessions: showAllSessions,
                  onExpandSessions: onExpandSessions,
                  onCollapseSessions: onCollapseSessions,
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
    required this.workspace,
    required this.currentSession,
    required this.visibleSessionLimit,
    required this.showAllSessions,
    required this.onExpandSessions,
    required this.onCollapseSessions,
    required this.onSelectSession,
    required this.canForkSession,
    required this.onSessionMenuAction,
  });

  final WorkspaceRecord workspace;
  final AgentSession? currentSession;
  final int visibleSessionLimit;
  final bool showAllSessions;
  final VoidCallback onExpandSessions;
  final VoidCallback onCollapseSessions;
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
    final widgets = <Widget>[];
    final hasHiddenSessions = workspace.sessions.length > visibleSessionLimit;
    final sessions = hasHiddenSessions && !showAllSessions
        ? workspace.sessions.take(visibleSessionLimit)
        : workspace.sessions;
    for (final session in sessions) {
      final selected = _isCurrentSession(session);
      widgets.add(
        _SessionTile(
          session: session,
          selected: selected,
          onPressed: onSelectSession == null || selected
              ? null
              : () => onSelectSession!(session),
          canFork: canForkSession?.call(session) ?? false,
          onMenuAction: onSessionMenuAction,
        ),
      );
      widgets.add(const SizedBox(height: 5));
    }
    if (hasHiddenSessions) {
      widgets.add(
        _SessionListToggle(
          workspacePath: workspace.path,
          expanded: showAllSessions,
          onPressed: showAllSessions ? onCollapseSessions : onExpandSessions,
        ),
      );
      widgets.add(const SizedBox(height: 5));
    }
    if (widgets.isNotEmpty) widgets.removeLast();
    return widgets;
  }

  bool _isCurrentSession(AgentSession session) {
    final current = currentSession;
    if (current == null || session.id != current.id) return false;
    return _sessionAgentKey(session) == _sessionAgentKey(current) &&
        normalizeWorkspacePath(session.cwd) ==
            normalizeWorkspacePath(current.cwd);
  }

  String _sessionAgentKey(AgentSession session) {
    return session.agentName?.trim() ?? '';
  }
}

class _SessionListToggle extends StatelessWidget {
  const _SessionListToggle({
    required this.workspacePath,
    required this.expanded,
    required this.onPressed,
  });

  final String workspacePath;
  final bool expanded;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final label = expanded ? '折叠显示' : '展开显示';
    return Semantics(
      button: true,
      label: label,
      child: Tooltip(
        message: label,
        child: InkWell(
          key: Key(
            'workspace-session-${expanded ? 'collapse' : 'expand'}:$workspacePath',
          ),
          borderRadius: BorderRadius.circular(AppRadius.sm),
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 5, 4, 4),
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.textTertiary,
                fontSize: 11.5,
                fontWeight: FontWeight.w800,
                letterSpacing: 0,
                height: 1.1,
              ),
            ),
          ),
        ),
      ),
    );
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
    final reservesHoverBorder = !selected;
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
              key: Key('workspace-project-strip:${workspace.path}'),
              padding: reservesHoverBorder
                  ? const EdgeInsets.fromLTRB(2, 4, 4, 4)
                  : const EdgeInsets.fromLTRB(3, 5, 5, 5),
              decoration: BoxDecoration(
                color: !selected && hovered
                    ? AppColors.surface
                    : Colors.transparent,
                borderRadius: radius,
                border: reservesHoverBorder
                    ? Border.all(
                        color: hovered
                            ? AppColors.borderSoft
                            : Colors.transparent,
                      )
                    : null,
              ),
              child: Row(
                children: [
                  Container(
                    width: 3,
                    height: 34,
                    decoration: BoxDecoration(
                      color: selected ? AppColors.primary : AppColors.border,
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                    ),
                  ),
                  const SizedBox(width: 3),
                  _WorkspaceDisclosureButton(
                    expanded: expanded,
                    label: displayName,
                    onPressed: onToggleWorkspace,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          displayName,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 0,
                            height: 1.1,
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
                            height: 1.15,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 4),
                  _CountPill(count: workspace.sessionCount),
                  const SizedBox(width: 2),
                  _WorkspaceInlineActions(
                    workspace: workspace,
                    pinned: pinned,
                    canRevealInFinder: canRevealInFinder,
                    canCreatePermanentWorktree: canCreatePermanentWorktree,
                    canArchiveConversations: canArchiveConversations,
                    canRemove: canRemove,
                    canStartNewSession: onNewSession != null,
                    onMenuAction: onMenuAction,
                  ),
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
        canStartNewSession: onNewSession != null,
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
    required this.canStartNewSession,
    required this.onMenuAction,
  });

  final WorkspaceRecord workspace;
  final bool pinned;
  final bool canRevealInFinder;
  final bool canCreatePermanentWorktree;
  final bool canArchiveConversations;
  final bool canRemove;
  final bool canStartNewSession;
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
          canStartNewSession: canStartNewSession,
          onSelected: onMenuAction,
        ),
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
    required this.canStartNewSession,
    required this.onSelected,
  });

  final bool pinned;
  final bool canRevealInFinder;
  final bool canCreatePermanentWorktree;
  final bool canArchiveConversations;
  final bool canRemove;
  final bool canStartNewSession;
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
          canStartNewSession: canStartNewSession,
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
  required bool canStartNewSession,
}) {
  return [
    _workspaceMenuItem(
      value: _WorkspaceMenuAction.newSession,
      icon: Icons.edit_square,
      label: 'New Session',
      enabled: canStartNewSession,
    ),
    const PopupMenuDivider(height: 8),
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
      label: 'Hide from Sidebar',
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

enum _WorkspaceMenuAction {
  newSession,
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
                key: Key(
                  selected
                      ? 'workspace-session-active:${session.id}'
                      : 'workspace-session-history:${session.id}',
                ),
                padding: const EdgeInsets.fromLTRB(3, 3, 4, 3),
                decoration: BoxDecoration(
                  color: selected ? AppColors.primaryMist : Colors.transparent,
                  border: Border.all(
                    color: selected
                        ? AppColors.primary.withValues(alpha: 0.28)
                        : _hovered
                        ? AppColors.borderSoft
                        : Colors.transparent,
                  ),
                  borderRadius: radius,
                ),
                child: _sessionContent(
                  session,
                  onMenuAction,
                  showActions,
                  selected: selected,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _sessionContent(
    AgentSession session,
    FutureOr<void> Function(
      AgentSession session,
      WorkspaceSessionMenuAction action,
    )?
    onMenuAction,
    bool showActions, {
    required bool selected,
  }) {
    final titleColor = selected ? AppColors.primaryDark : AppColors.textPrimary;
    final timeColor = selected
        ? AppColors.primaryDark.withValues(alpha: 0.7)
        : AppColors.textTertiary;
    return Row(
      children: [
        Expanded(
          child: Text(
            session.displayTitle,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: titleColor,
              fontWeight: FontWeight.w800,
              fontSize: 11.5,
              letterSpacing: 0,
            ),
          ),
        ),
        if (session.pinned) ...[
          const SizedBox(width: 4),
          const Icon(Icons.push_pin, size: 12, color: AppColors.primaryDark),
        ],
        if (_agentLabel.isNotEmpty) ...[
          const SizedBox(width: 5),
          _AgentPill(label: _agentLabel, maxWidth: 58),
        ],
        const SizedBox(width: 5),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 44),
          child: Text(
            formatRelativeSessionTime(session.displayTime),
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: timeColor, fontSize: 10, height: 1.1),
          ),
        ),
        if (onMenuAction != null) ...[
          const SizedBox(width: 2),
          _SessionActionSlot(
            visible: showActions,
            child: _SessionMenuButton(
              session: session,
              canFork: widget.canFork,
              onSelected: (action) => onMenuAction.call(session, action),
            ),
          ),
        ],
      ],
    );
  }

  void _setHovered(bool hovered) {
    if (_hovered == hovered) return;
    setState(() {
      _hovered = hovered;
    });
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

class _SessionActionSlot extends StatelessWidget {
  const _SessionActionSlot({required this.visible, required this.child});

  final bool visible;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 36,
      height: 22,
      child: Offstage(offstage: !visible, child: child),
    );
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
      child: const SizedBox(
        width: 36,
        height: 22,
        child: Icon(
          Icons.more_horiz_rounded,
          size: 16,
          color: AppColors.textSecondary,
        ),
      ),
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
    required this.workspaceName,
    required this.active,
  });

  final String workspaceName;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(30, 0, 8, 7),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DecoratedBox(
            decoration: const BoxDecoration(
              border: Border(left: BorderSide(color: AppColors.borderSoft)),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 2, 0, 0),
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
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AgentPill extends StatelessWidget {
  const _AgentPill({required this.label, this.maxWidth = 78});

  final String label;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
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
