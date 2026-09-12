import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:ianvs_design/ianvs_design.dart';

import '../../acp/acp_input_budget.dart';
import '../../acp/acp_session_catalog.dart';
import '../../workspace/workspace.dart';
import 'package:ianvs_agent_chat/ui/bounded_metadata_preview.dart';
import 'package:ianvs_agent_chat/ui/components/accessible_text_field.dart';

final class ResumeSessionAgentOption {
  const ResumeSessionAgentOption({
    required this.id,
    required this.name,
    required this.loadSessions,
    this.description = 'Ready',
    this.enabled = true,
    this.isCurrent = false,
    this.authenticate,
  });

  final String id;
  final String name;
  final String description;
  final bool enabled;
  final bool isCurrent;
  final Future<bool> Function()? authenticate;
  final Future<List<AcpProjectSessions>> Function() loadSessions;
}

class ResumeSessionSelection {
  const ResumeSessionSelection({
    required this.agentId,
    required this.agentName,
    required this.project,
    required this.conversation,
  });

  final String agentId;
  final String agentName;
  final AcpProjectSessions project;
  final AcpSessionEntry conversation;
}

class ResumeSessionDialog extends StatefulWidget {
  const ResumeSessionDialog({
    super.key,
    required this.agents,
    this.initialAgentId,
    this.initialCwd,
    this.workspaceCwd,
    this.inputBudget = const AcpInputBudget(),
  });

  final List<ResumeSessionAgentOption> agents;
  final String? initialAgentId;
  final String? initialCwd;
  final String? workspaceCwd;
  final AcpInputBudget inputBudget;

  @override
  State<ResumeSessionDialog> createState() => _ResumeSessionDialogState();
}

class _ResumeSessionDialogState extends State<ResumeSessionDialog> {
  final TextEditingController _sessionSearchController =
      TextEditingController();

  final Map<String, List<AcpProjectSessions>> _catalogs =
      <String, List<AcpProjectSessions>>{};
  final Map<String, Object> _catalogErrors = <String, Object>{};
  ResumeSessionAgentOption? _selectedAgent;
  List<AcpProjectSessions> _projects = const [];
  AcpProjectSessions? _selectedProject;
  AcpSessionEntry? _selectedConversation;
  AcpSessionEntry? _expandedConversation;
  Object? _error;
  bool _loading = false;
  int _loadGeneration = 0;
  String? _authenticatingAgentId;
  final Set<String> _authenticatedAgentIds = <String>{};

  @override
  void initState() {
    super.initState();
    widget.inputBudget.validate();
    _selectedAgent = _initialAgent();
    _loading = _selectedAgent != null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final selectedAgent = _selectedAgent;
      if (mounted && selectedAgent != null) {
        unawaited(_loadAgent(selectedAgent));
      }
    });
  }

  @override
  void didUpdateWidget(covariant ResumeSessionDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    widget.inputBudget.validate();
  }

  @override
  void dispose() {
    _sessionSearchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final viewportHeight = MediaQuery.sizeOf(context).height;
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      titlePadding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
      contentPadding: EdgeInsets.zero,
      actionsPadding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
      title: Text(
        'Resume ACP Session',
        style: Theme.of(context).textTheme.titleLarge!,
      ),
      content: SizedBox(
        width: 808,
        height: math.min(539, math.max(360, viewportHeight * 0.62)),
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.symmetric(
              horizontal: BorderSide(color: context.ianvs.separator),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: 258, child: _agentPane()),
              const VerticalDivider(width: 1, thickness: 1),
              Expanded(child: _sessionPane()),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          style: TextButton.styleFrom(
            minimumSize: const Size(0, 32),
            visualDensity: VisualDensity.standard,
          ),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: !_canLoadSelection()
              ? null
              : () {
                  Navigator.of(context).pop(
                    ResumeSessionSelection(
                      agentId: _selectedAgent!.id,
                      agentName: _selectedAgent!.name,
                      project: _selectedProject!,
                      conversation: _selectedConversation!,
                    ),
                  );
                },
          style: FilledButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.onPrimary,
            backgroundColor: context.ianvs.accent,
            minimumSize: const Size(0, 32),
            padding: const EdgeInsets.symmetric(horizontal: 18),
            visualDensity: VisualDensity.standard,
          ),
          child: const Text('Open Session'),
        ),
      ],
    );
  }

  bool _canLoadSelection() {
    final selectedProject = _selectedProject;
    final selectedConversation = _selectedConversation;
    if (_loading ||
        _error != null ||
        !_isAgentEnabled(_selectedAgent) ||
        selectedProject == null ||
        selectedConversation == null) {
      return false;
    }
    return _sessionMatchesSearch(selectedProject, selectedConversation);
  }

  Widget _agentPane() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(24, 12, 16, 8),
          child: Text(
            'Agent for this session',
            style: Theme.of(context).textTheme.titleMedium!,
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(left: 16),
            child: _AgentSelectionList(
              agents: widget.agents,
              selected: _selectedAgent,
              authenticatedAgentIds: _authenticatedAgentIds,
              onSelected: _selectAgent,
            ),
          ),
        ),
      ],
    );
  }

  Widget _sessionPane() {
    final selectedAgent = _selectedAgent;
    final canRefresh = _isAgentEnabled(selectedAgent) && !_loading;
    final authenticationAgent = _authenticationAgent();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 24, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  selectedAgent == null
                      ? 'Sessions'
                      : 'Sessions for ${selectedAgent.name}',
                  key: const ValueKey('resume-session-pane-title'),
                  style: Theme.of(context).textTheme.titleMedium!,
                ),
                const SizedBox(height: 4),
                Text(
                  _sessionScopeDescription(selectedAgent),
                  key: const ValueKey('resume-session-scope'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: context.ianvs.subtle,
                    fontSize: 12,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: _SearchField(
                        key: const ValueKey('resume-session-search'),
                        controller: _sessionSearchController,
                        semanticsLabel: 'Filter sessions',
                        hintText: 'Search sessions...',
                        enabled: selectedAgent != null && !_loading,
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                    const SizedBox(width: 16),
                    IconButton.outlined(
                      key: const ValueKey('resume-session-refresh'),
                      tooltip: 'Refresh sessions',
                      onPressed: canRefresh
                          ? () => _loadAgent(selectedAgent!, refresh: true)
                          : null,
                      style: IconButton.styleFrom(
                        fixedSize: const Size(40, 32),
                        padding: EdgeInsets.zero,
                        visualDensity: VisualDensity.standard,
                      ),
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: IanvsMotion.resolve(context),
                    transitionBuilder: _sessionResultTransition,
                    child: _sessionResults(selectedAgent),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (authenticationAgent != null)
          _AuthenticationBanner(
            agent: authenticationAgent,
            authenticating: _authenticatingAgentId == authenticationAgent.id,
            onAuthenticate: authenticationAgent.authenticate == null
                ? null
                : () => _authenticateAgent(authenticationAgent),
          ),
      ],
    );
  }

  Widget _sessionResults(ResumeSessionAgentOption? selectedAgent) {
    if (selectedAgent == null) {
      return const _MessagePanel(
        title: 'No resumable agents',
        message: 'No configured ACP agent can list and restore sessions.',
      );
    }
    if (!_isAgentEnabled(selectedAgent)) {
      return _MessagePanel(
        title: selectedAgent.description,
        message:
            'This agent cannot list sessions right now. Select another agent or try again after its current operation finishes.',
      );
    }
    if (_loading) {
      return _LoadingPanel(agentName: selectedAgent.name);
    }
    if (_error != null) {
      return _MessagePanel(
        title: 'Could not list ${selectedAgent.name} sessions',
        message: _error.toString(),
      );
    }
    if (_projects.isEmpty) {
      final workspaceCwd = widget.workspaceCwd?.trim();
      return _MessagePanel(
        title: workspaceCwd == null || workspaceCwd.isEmpty
            ? 'No sessions from ${selectedAgent.name}'
            : 'No sessions in this workspace',
        message: workspaceCwd == null || workspaceCwd.isEmpty
            ? 'This agent did not return any resumable sessions.'
            : '${selectedAgent.name} did not return any resumable sessions for $workspaceCwd.',
      );
    }
    return _GroupedSessionList(
      key: ValueKey((selectedAgent.id, _sessionSearchController.text)),
      projects: _projects,
      query: _sessionSearchController.text,
      selectedProject: _selectedProject,
      selectedConversation: _selectedConversation,
      expandedConversation: _expandedConversation,
      agentName: selectedAgent.name,
      inputBudget: widget.inputBudget,
      onSelected: _selectSession,
    );
  }

  ResumeSessionAgentOption? _initialAgent() {
    final initialAgentId = widget.initialAgentId?.trim();
    if (initialAgentId != null && initialAgentId.isNotEmpty) {
      for (final agent in widget.agents) {
        if (agent.id == initialAgentId) return agent;
      }
    }
    for (final agent in widget.agents) {
      if (agent.isCurrent && _isAgentEnabled(agent)) return agent;
    }
    for (final agent in widget.agents) {
      if (_isAgentEnabled(agent)) return agent;
    }
    for (final agent in widget.agents) {
      if (agent.isCurrent) return agent;
    }
    return widget.agents.isEmpty ? null : widget.agents.first;
  }

  String _sessionScopeDescription(ResumeSessionAgentOption? agent) {
    if (agent == null) return 'Choose an Agent to list resumable sessions.';
    final workspaceCwd = widget.workspaceCwd?.trim();
    if (workspaceCwd == null || workspaceCwd.isEmpty) {
      return 'Showing every workspace returned by ${agent.name}.';
    }
    return 'Limited to sessions in $workspaceCwd returned by ${agent.name}.';
  }

  void _selectAgent(ResumeSessionAgentOption agent) {
    if (identical(agent, _selectedAgent)) return;
    _loadGeneration += 1;
    _sessionSearchController.clear();
    final cached = _catalogs[agent.id];
    setState(() {
      _selectedAgent = agent;
      _error = _catalogErrors[agent.id];
      _loading = _isAgentEnabled(agent) && cached == null && _error == null;
      _applyProjects(cached ?? const <AcpProjectSessions>[]);
    });
    if (_isAgentEnabled(agent) && cached == null && _error == null) {
      unawaited(_loadAgent(agent));
    }
  }

  void _selectSession(
    AcpProjectSessions project,
    AcpSessionEntry conversation,
  ) {
    setState(() {
      final wasSelected =
          identical(_selectedProject, project) &&
          identical(_selectedConversation, conversation);
      _selectedProject = project;
      _selectedConversation = conversation;
      _expandedConversation =
          wasSelected && !identical(_expandedConversation, conversation)
          ? conversation
          : null;
    });
  }

  Future<void> _loadAgent(
    ResumeSessionAgentOption agent, {
    bool refresh = false,
  }) async {
    if (!_isAgentEnabled(agent)) return;
    final generation = ++_loadGeneration;
    if (refresh) {
      _catalogs.remove(agent.id);
      _catalogErrors.remove(agent.id);
    }
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
        _applyProjects(const <AcpProjectSessions>[]);
      });
    }

    try {
      final projects = await agent.loadSessions();
      _catalogs[agent.id] = projects;
      _catalogErrors.remove(agent.id);
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _applyProjects(projects);
        _sessionSearchController.clear();
        _loading = false;
      });
    } catch (error) {
      _catalogErrors[agent.id] = error;
      _catalogs.remove(agent.id);
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _error = error;
        _applyProjects(const <AcpProjectSessions>[]);
        _loading = false;
      });
    }
  }

  void _applyProjects(List<AcpProjectSessions> projects) {
    final scopedProjects = _projectsInWorkspace(projects);
    final selectedProject = _initialProject(scopedProjects);
    _projects = scopedProjects;
    _selectedProject = selectedProject;
    _selectedConversation =
        selectedProject == null || selectedProject.sessions.isEmpty
        ? null
        : selectedProject.sessions.first;
    _expandedConversation = null;
  }

  List<AcpProjectSessions> _projectsInWorkspace(
    List<AcpProjectSessions> projects,
  ) {
    final workspaceCwd = normalizeWorkspacePath(widget.workspaceCwd ?? '');
    if (workspaceCwd.isEmpty) return projects;
    return projects
        .where((project) => normalizeWorkspacePath(project.cwd) == workspaceCwd)
        .toList(growable: false);
  }

  AcpProjectSessions? _initialProject(List<AcpProjectSessions> projects) {
    if (projects.isEmpty) return null;
    final initialCwd = widget.initialCwd;
    if (initialCwd == null || initialCwd.isEmpty) return projects.first;
    for (final project in projects) {
      if (project.cwd == initialCwd) return project;
    }
    return projects.first;
  }

  bool _sessionMatchesSearch(
    AcpProjectSessions project,
    AcpSessionEntry conversation,
  ) {
    return _sessionMatchesQuery(
      project,
      conversation,
      _sessionSearchController.text.trim().toLowerCase(),
    );
  }

  bool _isAgentEnabled(ResumeSessionAgentOption? agent) {
    return agent != null &&
        (agent.enabled || _authenticatedAgentIds.contains(agent.id));
  }

  ResumeSessionAgentOption? _authenticationAgent() {
    final agent = _selectedAgent;
    if (agent == null || _authenticatedAgentIds.contains(agent.id)) return null;
    return agent.description.toLowerCase().contains('authentication required')
        ? agent
        : null;
  }

  Future<void> _authenticateAgent(ResumeSessionAgentOption agent) async {
    final authenticate = agent.authenticate;
    if (authenticate == null || _authenticatingAgentId != null) return;
    setState(() => _authenticatingAgentId = agent.id);
    try {
      final authenticated = await authenticate();
      if (!mounted || !authenticated) return;
      setState(() => _authenticatedAgentIds.add(agent.id));
      if (identical(agent, _selectedAgent)) {
        await _loadAgent(agent, refresh: true);
      }
    } finally {
      if (mounted) setState(() => _authenticatingAgentId = null);
    }
  }
}

Widget _sessionResultTransition(Widget child, Animation<double> animation) {
  // Keep the transition itself unkeyed so AnimatedSwitcher assigns its
  // monotonically increasing entry key. Its default transition derives a key
  // from child.key, which collides when several keyless loading/message panels
  // are still fading out during a fast refresh cycle.
  return FadeTransition(opacity: animation, child: child);
}

class _AgentSelectionList extends StatelessWidget {
  const _AgentSelectionList({
    required this.agents,
    required this.selected,
    required this.authenticatedAgentIds,
    required this.onSelected,
  });

  final List<ResumeSessionAgentOption> agents;
  final ResumeSessionAgentOption? selected;
  final Set<String> authenticatedAgentIds;
  final ValueChanged<ResumeSessionAgentOption> onSelected;

  @override
  Widget build(BuildContext context) {
    if (agents.isEmpty) {
      return const _MessagePanel(
        title: 'No configured agents',
        message: 'Add an ACP agent before resuming a session.',
      );
    }
    return Material(
      color: context.ianvs.canvas,
      child: ListView.builder(
        key: const ValueKey('resume-agent-list'),
        primary: false,
        itemExtent: 62,
        itemCount: agents.length,
        itemBuilder: (context, index) {
          final agent = agents[index];
          final isSelected = identical(agent, selected);
          final description = authenticatedAgentIds.contains(agent.id)
              ? 'Ready'
              : agent.description;
          return InkWell(
            onTap: () => onSelected(agent),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: isSelected
                    ? context.ianvs.accent.withValues(alpha: .08)
                    : context.ianvs.canvas,
                border: Border(
                  left: BorderSide(
                    color: isSelected
                        ? context.ianvs.accent
                        : Colors.transparent,
                    width: 3,
                  ),
                  bottom: BorderSide(color: context.ianvs.separator),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(13, 9, 12, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            agent.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: isSelected
                                  ? context.ianvs.accent
                                  : context.ianvs.text,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (agent.isCurrent) ...[
                          const SizedBox(width: 6),
                          Text(
                            'Current Agent',
                            style: TextStyle(
                              color: context.ianvs.subtle,
                              fontSize: 11,
                              fontWeight: FontWeight.w400,
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Icon(
                          Icons.circle,
                          size: 8,
                          color: _agentStatusColor(context, agent, description),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            description,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: context.ianvs.subtle,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

Color _agentStatusColor(
  BuildContext context,
  ResumeSessionAgentOption agent,
  String visibleDescription,
) {
  final description = visibleDescription.toLowerCase();
  if (description.contains('auth') || description.contains('error')) {
    return context.ianvs.danger;
  }
  if (description.contains('progress') ||
      description.contains('connecting') ||
      description.contains('reconnecting')) {
    return context.ianvs.warning;
  }
  if ((!agent.enabled && description != 'ready') ||
      description.contains('unsupported')) {
    return context.ianvs.subtle;
  }
  return context.ianvs.success;
}

class _AuthenticationBanner extends StatelessWidget {
  const _AuthenticationBanner({
    required this.agent,
    required this.authenticating,
    required this.onAuthenticate,
  });

  final ResumeSessionAgentOption agent;
  final bool authenticating;
  final VoidCallback? onAuthenticate;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: ValueKey('resume-authentication-${agent.id}'),
      constraints: const BoxConstraints(minHeight: 60),
      padding: const EdgeInsets.fromLTRB(16, 8, 24, 8),
      decoration: BoxDecoration(
        color: context.ianvs.canvas,
        border: Border(top: BorderSide(color: context.ianvs.separator)),
      ),
      child: Row(
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: context.ianvs.danger,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Authentication required',
                  style: TextStyle(
                    color: context.ianvs.text,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '${agent.name} needs new credentials to list sessions.',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: context.ianvs.subtle, fontSize: 11),
                ),
              ],
            ),
          ),
          if (onAuthenticate != null) ...[
            const SizedBox(width: 12),
            OutlinedButton(
              onPressed: authenticating ? null : onAuthenticate,
              child: authenticating
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Authenticate'),
            ),
          ],
        ],
      ),
    );
  }
}

class _LoadingPanel extends StatelessWidget {
  const _LoadingPanel({required this.agentName});

  final String agentName;

  @override
  Widget build(BuildContext context) {
    return Center(
      key: ValueKey('resume-loading-$agentName'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
          const SizedBox(height: 12),
          Text(
            'Loading sessions from $agentName...',
            style: TextStyle(color: context.ianvs.muted, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _GroupedSessionList extends StatelessWidget {
  const _GroupedSessionList({
    super.key,
    required this.projects,
    required this.query,
    required this.selectedProject,
    required this.selectedConversation,
    required this.expandedConversation,
    required this.agentName,
    required this.inputBudget,
    required this.onSelected,
  });

  final List<AcpProjectSessions> projects;
  final String query;
  final AcpProjectSessions? selectedProject;
  final AcpSessionEntry? selectedConversation;
  final AcpSessionEntry? expandedConversation;
  final String agentName;
  final AcpInputBudget inputBudget;
  final void Function(AcpProjectSessions, AcpSessionEntry) onSelected;

  @override
  Widget build(BuildContext context) {
    final normalizedQuery = query.trim().toLowerCase();
    final _SessionRowSource source = normalizedQuery.isEmpty
        ? _LazySessionRowSource(projects)
        : _FilteredSessionRowSource(projects, normalizedQuery);
    if (source.itemCount == 0) {
      return const _MessagePanel(
        title: 'No matching sessions',
        message: 'Try a different title, id, or workspace path.',
      );
    }
    return ListView.builder(
      key: const ValueKey('resume-session-list'),
      primary: false,
      itemCount: source.itemCount,
      itemBuilder: (context, index) {
        final row = source.rowAt(index);
        if (row == null) return null;
        if (row is _WorkspaceSessionRow) {
          return _WorkspaceGroupHeader(
            project: row.project,
            addTopSpacing: index > 0,
          );
        }
        final sessionRow = row as _ConversationSessionRow;
        final isSelected =
            identical(sessionRow.project, selectedProject) &&
            identical(sessionRow.conversation, selectedConversation);
        final isExpanded =
            isSelected &&
            identical(sessionRow.conversation, expandedConversation);
        return _SessionResultTile(
          project: sessionRow.project,
          conversation: sessionRow.conversation,
          selected: isSelected,
          expanded: isExpanded,
          agentName: agentName,
          inputBudget: inputBudget,
          onTap: () => onSelected(sessionRow.project, sessionRow.conversation),
        );
      },
    );
  }
}

class _WorkspaceGroupHeader extends StatelessWidget {
  const _WorkspaceGroupHeader({
    required this.project,
    required this.addTopSpacing,
  });

  final AcpProjectSessions project;
  final bool addTopSpacing;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: addTopSpacing ? 38 : 31,
      child: Padding(
        padding: EdgeInsets.only(top: addTopSpacing ? 7 : 0),
        child: Row(
          children: [
            Icon(
              CupertinoIcons.chevron_down,
              size: 16,
              color: context.ianvs.muted,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                project.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: context.ianvs.text,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(child: Divider(color: context.ianvs.separator)),
          ],
        ),
      ),
    );
  }
}

class _SessionResultTile extends StatelessWidget {
  const _SessionResultTile({
    required this.project,
    required this.conversation,
    required this.selected,
    required this.expanded,
    required this.agentName,
    required this.inputBudget,
    required this.onTap,
  });

  final AcpProjectSessions project;
  final AcpSessionEntry conversation;
  final bool selected;
  final bool expanded;
  final String agentName;
  final AcpInputBudget inputBudget;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: selected
              ? context.ianvs.accent.withValues(alpha: .08)
              : context.ianvs.canvas,
          child: InkWell(
            onTap: onTap,
            child: Container(
              key: ValueKey('resume-session-${conversation.id}'),
              height: 60,
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(
                    width: 3,
                    color: selected ? context.ianvs.accent : Colors.transparent,
                  ),
                ),
              ),
              padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          conversation.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: context.ianvs.text,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          conversation.id,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: context.ianvs.subtle,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    _formatRelativeDateTime(conversation.updatedAt),
                    style: TextStyle(color: context.ianvs.subtle, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (expanded)
          Padding(
            padding: const EdgeInsets.fromLTRB(3, 6, 0, 10),
            child: _ConversationPreview(
              agentName: agentName,
              conversation: conversation,
              inputBudget: inputBudget,
            ),
          ),
      ],
    );
  }
}

sealed class _SessionListRow {
  const _SessionListRow();
}

final class _WorkspaceSessionRow extends _SessionListRow {
  const _WorkspaceSessionRow(this.project);

  final AcpProjectSessions project;
}

final class _ConversationSessionRow extends _SessionListRow {
  const _ConversationSessionRow(this.project, this.conversation);

  final AcpProjectSessions project;
  final AcpSessionEntry conversation;
}

abstract interface class _SessionRowSource {
  int? get itemCount;

  _SessionListRow? rowAt(int index);
}

final class _LazySessionRowSource implements _SessionRowSource {
  _LazySessionRowSource(this.projects);

  final List<AcpProjectSessions> projects;
  final List<_WorkspaceSpan> _spans = <_WorkspaceSpan>[];
  var _nextProjectIndex = 0;
  var _rowCount = 0;
  var _complete = false;

  @override
  int? get itemCount => null;

  @override
  _SessionListRow? rowAt(int index) {
    if (index < 0) return null;
    while (!_complete && index >= _rowCount) {
      if (_nextProjectIndex >= projects.length) {
        _complete = true;
        break;
      }
      final project = projects[_nextProjectIndex++];
      if (project.sessions.isEmpty) continue;
      final span = _WorkspaceSpan(
        project: project,
        start: _rowCount,
        end: _rowCount + project.sessions.length + 1,
      );
      _spans.add(span);
      _rowCount = span.end;
    }
    if (index >= _rowCount) return null;
    var low = 0;
    var high = _spans.length - 1;
    while (low <= high) {
      final middle = (low + high) >> 1;
      final span = _spans[middle];
      if (index < span.start) {
        high = middle - 1;
      } else if (index >= span.end) {
        low = middle + 1;
      } else {
        final offset = index - span.start;
        if (offset == 0) return _WorkspaceSessionRow(span.project);
        return _ConversationSessionRow(
          span.project,
          span.project.sessions[offset - 1],
        );
      }
    }
    return null;
  }
}

final class _WorkspaceSpan {
  const _WorkspaceSpan({
    required this.project,
    required this.start,
    required this.end,
  });

  final AcpProjectSessions project;
  final int start;
  final int end;
}

final class _FilteredSessionRowSource implements _SessionRowSource {
  _FilteredSessionRowSource(List<AcpProjectSessions> projects, String query) {
    for (final project in projects) {
      final matching = project.sessions
          .where((session) => _sessionMatchesQuery(project, session, query))
          .toList(growable: false);
      if (matching.isEmpty) continue;
      _rows.add(_WorkspaceSessionRow(project));
      for (final session in matching) {
        _rows.add(_ConversationSessionRow(project, session));
      }
    }
  }

  final List<_SessionListRow> _rows = <_SessionListRow>[];

  @override
  int get itemCount => _rows.length;

  @override
  _SessionListRow? rowAt(int index) {
    if (index < 0 || index >= _rows.length) return null;
    return _rows[index];
  }
}

bool _sessionMatchesQuery(
  AcpProjectSessions project,
  AcpSessionEntry conversation,
  String query,
) {
  if (query.isEmpty) return true;
  final updatedAt = conversation.updatedAt == null
      ? ''
      : _formatDateTime(conversation.updatedAt!);
  return project.name.toLowerCase().contains(query) ||
      project.cwd.toLowerCase().contains(query) ||
      conversation.title.toLowerCase().contains(query) ||
      conversation.id.toLowerCase().contains(query) ||
      conversation.shortId.toLowerCase().contains(query) ||
      conversation.cwd.toLowerCase().contains(query) ||
      conversation.dropdownLabel.toLowerCase().contains(query) ||
      updatedAt.toLowerCase().contains(query);
}

class _SearchField extends StatelessWidget {
  const _SearchField({
    super.key,
    required this.controller,
    required this.semanticsLabel,
    required this.hintText,
    required this.onChanged,
    this.enabled = true,
  });

  final TextEditingController controller;
  final String semanticsLabel;
  final String hintText;
  final ValueChanged<String> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return AccessibleTextField(
      label: semanticsLabel,
      description: hintText,
      controller: controller,
      enabled: enabled,
      onChanged: onChanged,
      builder: (focusNode) => TextField(
        controller: controller,
        focusNode: focusNode,
        enabled: enabled,
        onChanged: onChanged,
        style: TextStyle(
          color: context.ianvs.text,
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0,
        ),
        decoration: _inputDecoration(
          context,
          icon: Icons.search_rounded,
          hintText: hintText,
        ),
      ),
    );
  }
}

InputDecoration _inputDecoration(
  BuildContext context, {
  required IconData icon,
  required String hintText,
}) {
  return InputDecoration(
    prefixIcon: Icon(icon, size: 18, color: context.ianvs.muted),
    hint: ExcludeSemantics(
      child: Text(
        hintText,
        style: TextStyle(
          color: context.ianvs.subtle,
          fontSize: 12,
          fontWeight: FontWeight.w400,
          letterSpacing: 0,
        ),
      ),
    ),
    filled: true,
    fillColor: context.ianvs.canvas,
    isDense: true,
    contentPadding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
    constraints: const BoxConstraints(minHeight: 32),
    prefixIconConstraints: const BoxConstraints(minWidth: 32, minHeight: 32),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(context.ianvs.controlRadius),
      borderSide: BorderSide(color: context.ianvs.border),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(context.ianvs.controlRadius),
      borderSide: BorderSide(color: context.ianvs.border),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(context.ianvs.controlRadius),
      borderSide: BorderSide(color: context.ianvs.accent),
    ),
    disabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(context.ianvs.controlRadius),
      borderSide: BorderSide(color: context.ianvs.separator),
    ),
  );
}

class _ConversationPreview extends StatelessWidget {
  const _ConversationPreview({
    required this.agentName,
    required this.conversation,
    required this.inputBudget,
  });

  final String agentName;
  final AcpSessionEntry? conversation;
  final AcpInputBudget inputBudget;

  @override
  Widget build(BuildContext context) {
    final conversation = this.conversation;
    if (conversation == null) {
      return const _MessagePanel(
        title: 'Select a session',
        message: 'Choose a session to inspect its details.',
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: context.ianvs.raised,
        border: Border.all(color: context.ianvs.separator, width: .75),
        borderRadius: BorderRadius.circular(context.ianvs.panelRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            conversation.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: context.ianvs.text,
              fontWeight: FontWeight.w600,
              letterSpacing: 0,
            ),
          ),
          const SizedBox(height: 8),
          _PreviewRow(icon: Icons.tag_rounded, label: conversation.id),
          const SizedBox(height: 5),
          if (agentName.trim().isNotEmpty) ...[
            _PreviewRow(
              icon: Icons.smart_toy_outlined,
              label: agentName.trim(),
            ),
            const SizedBox(height: 5),
          ],
          _PreviewPathRow(label: 'Main workspace', path: conversation.cwd),
          for (final directory in _visibleAdditionalDirectories(
            conversation,
          )) ...[
            const SizedBox(height: 5),
            _PreviewPathRow(label: 'Additional directory', path: directory),
          ],
          if (conversation.updatedAt != null) ...[
            const SizedBox(height: 5),
            _PreviewRow(
              icon: Icons.access_time_rounded,
              label: _formatDateTime(conversation.updatedAt!),
            ),
          ],
          if (conversation.hasMeta || conversation.metaOmission != null) ...[
            const SizedBox(height: 8),
            if (conversation.hasMeta)
              _MetadataPreview(
                meta: conversation.meta,
                inputBudget: inputBudget,
                sessionIdentity: conversation,
              ),
            if (conversation.metaOmission != null)
              _MetadataOmissionLabel(omission: conversation.metaOmission!),
          ],
        ],
      ),
    );
  }
}

class _MetadataPreview extends StatefulWidget {
  const _MetadataPreview({
    required this.meta,
    required this.inputBudget,
    required this.sessionIdentity,
  });

  final Map<String, Object?> meta;
  final AcpInputBudget inputBudget;
  final Object sessionIdentity;

  @override
  State<_MetadataPreview> createState() => _MetadataPreviewState();
}

class _MetadataPreviewState extends State<_MetadataPreview> {
  BoundedMetadataPreview? _preview;
  var _expanded = false;

  @override
  void didUpdateWidget(covariant _MetadataPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(widget.sessionIdentity, oldWidget.sessionIdentity) &&
        identical(widget.meta, oldWidget.meta) &&
        identical(widget.inputBudget, oldWidget.inputBudget)) {
      return;
    }
    _preview = _expanded ? _writePreview() : null;
  }

  BoundedMetadataPreview _writePreview() =>
      writeBoundedMetadataPreview(widget.meta, budget: widget.inputBudget);

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: Material(
        color: Colors.transparent,
        child: ExpansionTile(
          onExpansionChanged: (expanded) {
            setState(() {
              _expanded = expanded;
              _preview = expanded ? _writePreview() : null;
            });
          },
          tilePadding: EdgeInsets.zero,
          childrenPadding: EdgeInsets.zero,
          title: Text(
            'Metadata',
            style: TextStyle(
              color: context.ianvs.text,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          leading: Icon(
            Icons.data_object_rounded,
            color: context.ianvs.focus,
            size: 18,
          ),
          children: _preview == null
              ? const <Widget>[]
              : [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(9),
                    decoration: BoxDecoration(
                      color: context.ianvs.canvas,
                      borderRadius: BorderRadius.circular(
                        context.ianvs.controlRadius,
                      ),
                      border: Border.all(
                        color: context.ianvs.separator,
                        width: .75,
                      ),
                    ),
                    child: SelectableText(
                      _preview!.text,
                      style: TextStyle(
                        color: context.ianvs.muted,
                        fontFamily: context.ianvsTypography.code.fontFamily,
                        fontFamilyFallback:
                            context.ianvsTypography.code.fontFamilyFallback,
                        fontSize: 12,
                        height: 1.35,
                      ),
                    ),
                  ),
                  if (_preview!.omission != null)
                    _MetadataOmissionLabel(omission: _preview!.omission!),
                ],
        ),
      ),
    );
  }
}

class _MetadataOmissionLabel extends StatelessWidget {
  const _MetadataOmissionLabel({required this.omission});

  final AcpInputOmission omission;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text(
        'Details omitted · ${omission.resource}',
        style: TextStyle(
          color: context.ianvs.warning,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _PreviewRow extends StatelessWidget {
  const _PreviewRow({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 15, color: context.ianvs.subtle),
        const SizedBox(width: 7),
        Expanded(
          child: Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: context.ianvs.muted,
              fontSize: 12,
              fontWeight: FontWeight.w400,
            ),
          ),
        ),
      ],
    );
  }
}

List<String> _visibleAdditionalDirectories(AcpSessionEntry conversation) {
  final mainWorkspace = conversation.cwd.trim();
  final seen = <String>{if (mainWorkspace.isNotEmpty) mainWorkspace};
  final directories = <String>[];
  for (final rawDirectory in conversation.additionalDirectories) {
    final directory = rawDirectory.trim();
    if (directory.isEmpty || !seen.add(directory)) continue;
    directories.add(directory);
  }
  return directories;
}

class _PreviewPathRow extends StatelessWidget {
  const _PreviewPathRow({required this.label, required this.path});

  final String label;
  final String path;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.only(top: 2),
          child: Icon(
            Icons.folder_outlined,
            size: 15,
            color: context.ianvs.subtle,
          ),
        ),
        const SizedBox(width: 7),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: context.ianvs.subtle,
                  fontSize: 11,
                  fontWeight: FontWeight.w400,
                ),
              ),
              SelectableText(
                path,
                style: TextStyle(
                  color: context.ianvs.muted,
                  fontFamily: context.ianvsTypography.code.fontFamily,
                  fontFamilyFallback:
                      context.ianvsTypography.code.fontFamilyFallback,
                  fontSize: 12,
                  height: 1.3,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MessagePanel extends StatelessWidget {
  const _MessagePanel({required this.title, required this.message});

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: context.ianvs.raised,
        border: Border.all(color: context.ianvs.separator, width: .75),
        borderRadius: BorderRadius.circular(context.ianvs.panelRadius),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            title,
            style: TextStyle(
              color: context.ianvs.text,
              fontWeight: FontWeight.w600,
              letterSpacing: 0,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(color: context.ianvs.muted, height: 1.35),
          ),
        ],
      ),
    );
  }
}

String _formatDateTime(DateTime value) {
  String two(int input) => input.toString().padLeft(2, '0');
  return '${value.year}-${two(value.month)}-${two(value.day)} '
      '${two(value.hour)}:${two(value.minute)}';
}

String _formatRelativeDateTime(DateTime? value) {
  if (value == null) return '';
  final elapsed = DateTime.now().difference(value);
  if (elapsed.isNegative || elapsed.inMinutes < 1) return 'just now';
  if (elapsed.inHours < 1) return '${elapsed.inMinutes}m ago';
  if (elapsed.inDays < 1) return '${elapsed.inHours}h ago';
  if (elapsed.inDays < 7) return '${elapsed.inDays}d ago';
  final weeks = elapsed.inDays ~/ 7;
  if (weeks < 5) return '${weeks}w ago';
  return _formatDateTime(value);
}
