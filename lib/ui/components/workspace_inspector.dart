import 'package:flutter/material.dart';

import '../../acp/acp_session_settings.dart';
import '../../acp/acp_session_usage.dart';
import '../../acp/agent_session.dart';
import '../../config/acp_client_config.dart';
import '../../workspace/workspace.dart';
import 'session_time_label.dart';
import '../theme/app_design_tokens.dart';

class WorkspaceInspector extends StatelessWidget {
  const WorkspaceInspector({
    super.key,
    required this.workspace,
    required this.agentName,
    required this.currentSession,
    required this.mcpServers,
    required this.additionalDirectories,
    required this.clientProviders,
    this.environmentBranch,
    this.configPath,
    this.sessionSettings = const AcpSessionSettings(),
    this.sessionUsage,
    this.lastLatency,
    this.onConfigOptionSelected,
    this.onShowSessionSettings,
    this.onShowCapabilities,
  });

  final WorkspaceRecord workspace;
  final String agentName;
  final AgentSession? currentSession;
  final List<McpServerConfig> mcpServers;
  final List<String> additionalDirectories;
  final AcpClientProviderConfig clientProviders;
  final String? environmentBranch;
  final String? configPath;
  final AcpSessionSettings sessionSettings;
  final AcpSessionUsage? sessionUsage;
  final Duration? lastLatency;
  final void Function(String configId, Object value)? onConfigOptionSelected;
  final VoidCallback? onShowSessionSettings;
  final VoidCallback? onShowCapabilities;

  @override
  Widget build(BuildContext context) {
    final branch = environmentBranch ?? _sessionBranch(currentSession);
    return Material(
      color: AppColors.surface,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 38, 16, 16),
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(AppRadius.xl),
            border: Border.all(color: AppColors.border),
            boxShadow: AppShadows.soft,
          ),
          padding: const EdgeInsets.fromLTRB(18, 20, 18, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _CompactInspectorHeader(
                label: '会话信息',
                actionIcon: Icons.tune_rounded,
                actionTooltip: '会话设置',
                onAction: onShowSessionSettings,
                prominent: true,
              ),
              const SizedBox(height: 14),
              const Divider(height: 1, color: AppColors.borderSoft),
              const SizedBox(height: 18),
              _InspectorDisclosure(
                label: '环境',
                children: [
                  const _CompactSourceRow(
                    icon: Icons.computer_outlined,
                    label: '本地',
                  ),
                  _CompactSourceRow(
                    icon: Icons.account_tree_outlined,
                    label: branch ?? 'Git 工作区',
                  ),
                ],
              ),
              const SizedBox(height: 18),
              const Divider(height: 1, color: AppColors.borderSoft),
              const SizedBox(height: 18),
              _InspectorDisclosure(
                label: '上下文',
                children: [
                  _CompactSourceRow(
                    icon: Icons.folder_outlined,
                    label: workspace.name,
                  ),
                ],
              ),
              const SizedBox(height: 18),
              const Divider(height: 1, color: AppColors.borderSoft),
              const SizedBox(height: 18),
              const _CompactInspectorHeader(
                label: '来源',
                actionIcon: Icons.add_rounded,
                actionTooltip: '添加来源',
                onAction: null,
              ),
              const SizedBox(height: 8),
              _CompactSourceRow(
                icon: Icons.link_rounded,
                label: '查看全部',
                muted: true,
                trailing: Icons.north_east_rounded,
                onTap: () => _showDetails(context),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showDetails(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        child: SizedBox(width: 680, height: 620, child: _detailsBody()),
      ),
    );
  }

  Widget _detailsBody() {
    return DefaultTabController(
      key: ValueKey(
        currentSession == null
            ? 'workspace-inspector-overview'
            : 'workspace-inspector-context',
      ),
      length: 2,
      initialIndex: currentSession == null ? 0 : 1,
      child: Container(
        color: AppColors.surface,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: Row(
                children: [
                  const Icon(
                    Icons.menu_book_outlined,
                    color: AppColors.textSecondary,
                    size: 17,
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Workspace',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(
              height: 40,
              child: TabBar(
                labelColor: AppColors.textPrimary,
                unselectedLabelColor: AppColors.textSecondary,
                dividerColor: Colors.transparent,
                indicator: const UnderlineTabIndicator(
                  borderSide: BorderSide(color: AppColors.accent, width: 2),
                  insets: EdgeInsets.symmetric(horizontal: 26),
                ),
                indicatorSize: TabBarIndicatorSize.tab,
                labelStyle: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0,
                ),
                unselectedLabelStyle: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0,
                ),
                tabs: const [
                  Tab(text: 'Overview'),
                  Tab(text: 'Context'),
                ],
              ),
            ),
            const Divider(height: 1, color: AppColors.border),
            Expanded(
              child: TabBarView(
                children: [
                  _OverviewPane(
                    workspace: workspace,
                    agentName: agentName,
                    currentSession: currentSession,
                  ),
                  _ContextPane(
                    workspace: workspace,
                    agentName: agentName,
                    currentSession: currentSession,
                    sessionSettings: sessionSettings,
                    sessionUsage: sessionUsage,
                    lastLatency: lastLatency,
                    onConfigOptionSelected: onConfigOptionSelected,
                    onShowSessionSettings: onShowSessionSettings,
                    onShowCapabilities: onShowCapabilities,
                    mcpServers: mcpServers,
                    additionalDirectories: additionalDirectories,
                    clientProviders: clientProviders,
                    configPath: configPath,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String? _sessionBranch(AgentSession? session) {
  if (session == null) return null;
  const candidateKeys = [
    'branch',
    'branchName',
    'branch_name',
    'gitBranch',
    'git_branch',
    'worktreeBranch',
  ];
  final events = session.initialEvents;
  final start = events.length > 128 ? events.length - 128 : 0;
  for (var index = events.length - 1; index >= start; index -= 1) {
    final metadata = events[index].metadata;
    for (final key in candidateKeys) {
      final value = metadata[key];
      if (value == null) continue;
      final label = value.toString().trim().replaceAll(RegExp(r'\s+'), ' ');
      if (label.isNotEmpty) return label;
    }
  }
  return null;
}

class _CompactInspectorHeader extends StatelessWidget {
  const _CompactInspectorHeader({
    required this.label,
    required this.actionIcon,
    required this.actionTooltip,
    required this.onAction,
    this.prominent = false,
  });

  final String label;
  final IconData actionIcon;
  final String actionTooltip;
  final VoidCallback? onAction;
  final bool prominent;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 36,
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style:
                  const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 13.5,
                    height: 1.3,
                    fontWeight: FontWeight.w600,
                  ).copyWith(
                    color: prominent
                        ? AppColors.textPrimary
                        : AppColors.textSecondary,
                  ),
            ),
          ),
          if (onAction != null)
            IconButton(
              tooltip: actionTooltip,
              onPressed: onAction,
              icon: Icon(actionIcon, size: 17),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 28, height: 28),
            ),
        ],
      ),
    );
  }
}

class _CompactSourceRow extends StatelessWidget {
  const _CompactSourceRow({
    required this.icon,
    required this.label,
    this.muted = false,
    this.trailing,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final bool muted;
  final IconData? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        onTap: onTap,
        child: SizedBox(
          height: 40,
          child: Row(
            children: [
              Icon(icon, size: 17, color: AppColors.textSecondary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: muted
                        ? AppColors.textTertiary
                        : AppColors.textSecondary,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              if (trailing != null)
                Icon(trailing, size: 15, color: AppColors.textTertiary),
            ],
          ),
        ),
      ),
    );
  }
}

class _InspectorDisclosure extends StatefulWidget {
  const _InspectorDisclosure({required this.label, required this.children});

  final String label;
  final List<Widget> children;

  @override
  State<_InspectorDisclosure> createState() => _InspectorDisclosureState();
}

class _InspectorDisclosureState extends State<_InspectorDisclosure> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadius.sm),
            onTap: () => setState(() => _expanded = !_expanded),
            child: SizedBox(
              height: 40,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.label,
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_down_rounded
                        : Icons.chevron_right_rounded,
                    size: 18,
                    color: AppColors.textTertiary,
                  ),
                ],
              ),
            ),
          ),
        ),
        if (_expanded) ...widget.children,
      ],
    );
  }
}

class _OverviewPane extends StatelessWidget {
  const _OverviewPane({
    required this.workspace,
    required this.agentName,
    required this.currentSession,
  });

  final WorkspaceRecord workspace;
  final String agentName;
  final AgentSession? currentSession;

  @override
  Widget build(BuildContext context) {
    final recentSessions = workspace.sessions.take(3).toList(growable: false);
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 16),
      children: [
        _SectionTitle(icon: Icons.folder_open_rounded, label: 'Directory'),
        _InfoRow(label: 'Name', value: workspace.name),
        _InfoRow(label: 'Path', value: workspace.path, maxLines: 3),
        _InfoRow(label: 'Agent', value: agentName),
        _InfoRow(label: 'Sessions', value: workspace.sessionCount.toString()),
        _InfoRow(
          label: 'Last activity',
          value: _formatDate(workspace.lastActivityAt),
        ),
        if (currentSession != null)
          _InfoRow(
            label: 'Current',
            value: currentSession!.displayTitle,
            maxLines: 2,
          ),
        const _InspectorSectionDivider(),
        _SectionTitle(icon: Icons.forum_outlined, label: 'Recent Sessions'),
        if (recentSessions.isEmpty)
          const _EmptyLine(message: 'No sessions in this workspace yet.')
        else
          for (final session in recentSessions) _MiniSessionRow(session),
      ],
    );
  }
}

class _ContextPane extends StatelessWidget {
  const _ContextPane({
    required this.workspace,
    required this.agentName,
    required this.currentSession,
    required this.sessionSettings,
    required this.sessionUsage,
    required this.lastLatency,
    required this.onConfigOptionSelected,
    required this.onShowSessionSettings,
    required this.onShowCapabilities,
    required this.mcpServers,
    required this.additionalDirectories,
    required this.clientProviders,
    required this.configPath,
  });

  final WorkspaceRecord workspace;
  final String agentName;
  final AgentSession? currentSession;
  final AcpSessionSettings sessionSettings;
  final AcpSessionUsage? sessionUsage;
  final Duration? lastLatency;
  final void Function(String configId, Object value)? onConfigOptionSelected;
  final VoidCallback? onShowSessionSettings;
  final VoidCallback? onShowCapabilities;
  final List<McpServerConfig> mcpServers;
  final List<String> additionalDirectories;
  final AcpClientProviderConfig clientProviders;
  final String? configPath;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 16),
      children: [
        _SectionTitle(
          icon: Icons.chat_bubble_outline_rounded,
          label: 'Session',
        ),
        _InfoRow(label: 'Agent', value: agentName),
        if (currentSession == null)
          const _EmptyLine(message: 'Start a session to see its context.')
        else ...[
          for (final option in sessionSettings.configOptions)
            _SessionConfigRow(
              option: option,
              enabled: onConfigOptionSelected != null,
              onSelected: onConfigOptionSelected,
            ),
          _InfoRow(label: 'Session ID', value: currentSession!.id, maxLines: 2),
          if (sessionUsage != null) _UsageRow(usage: sessionUsage!),
          _InfoRow(
            label: 'Working dir',
            value: currentSession!.cwd,
            maxLines: 3,
          ),
        ],
        const SizedBox(height: 3),
        _DiagnosticsSection(
          lastLatency: lastLatency,
          onShowSessionSettings: onShowSessionSettings,
          onShowCapabilities: onShowCapabilities,
        ),
        const _InspectorSectionDivider(),
        _SectionTitle(icon: Icons.account_tree_outlined, label: 'Paths'),
        if (currentSession == null)
          _InfoRow(label: 'Workspace cwd', value: workspace.path, maxLines: 3),
        if (additionalDirectories.isEmpty)
          const _InfoRow(label: 'Additional dirs', value: 'None')
        else
          for (final directory in additionalDirectories)
            _InfoRow(label: 'Additional dir', value: directory, maxLines: 3),
        _InfoRow(label: 'Config', value: _fallback(configPath), maxLines: 3),
        const _InspectorSectionDivider(),
        _SectionTitle(icon: Icons.hub_outlined, label: 'MCP'),
        if (mcpServers.isEmpty)
          const _EmptyLine(message: 'No MCP servers configured.')
        else
          for (final server in mcpServers) _McpServerRow(server),
        const _InspectorSectionDivider(),
        _SectionTitle(icon: Icons.shield_outlined, label: 'Providers'),
        _InfoRow(
          label: 'Filesystem',
          value: _filesystemProviderLabel(clientProviders.filesystem),
        ),
        _InfoRow(
          label: 'Terminal',
          value: clientProviders.terminal.enabled ? 'Enabled' : 'Disabled',
        ),
        _InfoRow(
          label: 'Trust rules',
          value: clientProviders.permissions.trustRules.length.toString(),
        ),
      ],
    );
  }
}

class _SessionConfigRow extends StatelessWidget {
  const _SessionConfigRow({
    required this.option,
    required this.enabled,
    required this.onSelected,
  });

  final AcpConfigOption option;
  final bool enabled;
  final void Function(String configId, Object value)? onSelected;

  @override
  Widget build(BuildContext context) {
    final canChange =
        enabled && (option.isBooleanOption || option.options.length > 1);
    final label = option.name.trim().isEmpty ? option.id : option.name;
    if (!canChange) {
      return _InfoRow(label: label, value: option.currentChoiceLabel);
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.textTertiary,
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: PopupMenuButton<_InspectorConfigSelection>(
              tooltip: 'Change $label',
              onSelected: (selection) =>
                  onSelected?.call(selection.configId, selection.value),
              itemBuilder: (context) => _choices(),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      option.currentChoiceLabel,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  const Icon(
                    Icons.keyboard_arrow_down_rounded,
                    size: 15,
                    color: AppColors.textSecondary,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<PopupMenuEntry<_InspectorConfigSelection>> _choices() {
    if (option.isBooleanOption) {
      return [
        for (final value in const [false, true])
          PopupMenuItem<_InspectorConfigSelection>(
            value: _InspectorConfigSelection(option.id, value),
            child: _InspectorChoiceRow(
              selected: option.currentBoolValue == value,
              label: value ? 'On' : 'Off',
              description: value ? option.description : null,
            ),
          ),
      ];
    }
    return [
      for (final choice in option.options)
        PopupMenuItem<_InspectorConfigSelection>(
          value: _InspectorConfigSelection(option.id, choice.value),
          child: _InspectorChoiceRow(
            selected: choice.value == option.currentValue,
            label: choice.groupName == null
                ? choice.label
                : '${choice.groupName} · ${choice.label}',
            description: choice.description,
          ),
        ),
    ];
  }
}

class _InspectorConfigSelection {
  const _InspectorConfigSelection(this.configId, this.value);

  final String configId;
  final Object value;
}

class _InspectorChoiceRow extends StatelessWidget {
  const _InspectorChoiceRow({
    required this.selected,
    required this.label,
    required this.description,
  });

  final bool selected;
  final String label;
  final String? description;

  @override
  Widget build(BuildContext context) {
    final detail = description?.trim();
    return Row(
      children: [
        Icon(
          selected ? Icons.check_rounded : Icons.circle_outlined,
          size: 16,
          color: selected ? AppColors.textPrimary : AppColors.textTertiary,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (detail != null && detail.isNotEmpty)
                Text(
                  detail,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 10.5,
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

class _UsageRow extends StatelessWidget {
  const _UsageRow({required this.usage});

  final AcpSessionUsage usage;

  @override
  Widget build(BuildContext context) {
    final percent = usage.percentage;
    final progress = percent?.clamp(0.0, 1.0);
    final label = percent == null
        ? '${_compactNumber(usage.used)} / ${_compactNumber(usage.size)}'
        : '${(percent * 100).toStringAsFixed(0)}%  '
              '${_compactNumber(usage.used)} / ${_compactNumber(usage.size)}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _InfoRow(label: 'Context', value: label),
          Padding(
            padding: const EdgeInsets.only(left: 80),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.pill),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 3,
                backgroundColor: AppColors.surfaceMuted,
                color: _usageColor(percent),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Color _usageColor(double? percent) {
    if (percent == null) return AppColors.textSecondary;
    if (percent >= 0.95) return AppColors.danger;
    if (percent >= 0.75) return AppColors.warning;
    return AppColors.textPrimary;
  }
}

class _DiagnosticsSection extends StatelessWidget {
  const _DiagnosticsSection({
    required this.lastLatency,
    required this.onShowSessionSettings,
    required this.onShowCapabilities,
  });

  final Duration? lastLatency;
  final VoidCallback? onShowSessionSettings;
  final VoidCallback? onShowCapabilities;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: Material(
        color: AppColors.surface,
        child: ExpansionTile(
          key: const Key('workspace-diagnostics-section'),
          tilePadding: EdgeInsets.zero,
          childrenPadding: EdgeInsets.zero,
          minTileHeight: 34,
          dense: true,
          leading: const Icon(
            Icons.tune_rounded,
            size: 14,
            color: AppColors.textSecondary,
          ),
          title: const Text(
            'Diagnostics',
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          children: [
            _InfoRow(
              label: 'Latency',
              value: lastLatency == null
                  ? 'Not measured'
                  : '${lastLatency!.inMilliseconds} ms',
            ),
            if (onShowSessionSettings != null)
              _InspectorActionRow(
                icon: Icons.settings_outlined,
                label: 'Session settings',
                onTap: onShowSessionSettings!,
              ),
            if (onShowCapabilities != null)
              _InspectorActionRow(
                icon: Icons.fact_check_outlined,
                label: 'ACP compatibility',
                onTap: onShowCapabilities!,
              ),
          ],
        ),
      ),
    );
  }
}

class _InspectorActionRow extends StatelessWidget {
  const _InspectorActionRow({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.sm),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          children: [
            Icon(icon, size: 14, color: AppColors.textSecondary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            const Icon(
              Icons.chevron_right_rounded,
              size: 15,
              color: AppColors.textTertiary,
            ),
          ],
        ),
      ),
    );
  }
}

class _McpServerRow extends StatelessWidget {
  const _McpServerRow(this.server);

  final McpServerConfig server;

  @override
  Widget build(BuildContext context) {
    final target = server.safeDisplayTarget;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(AppRadius.sm),
              border: Border.all(color: AppColors.borderSoft),
            ),
            child: const Icon(
              Icons.hub_outlined,
              size: 13,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  server.name,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  target.isEmpty ? server.type : '${server.type} - $target',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 11,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniSessionRow extends StatelessWidget {
  const _MiniSessionRow(this.session);

  final AgentSession session;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.chat_bubble_outline_rounded,
            size: 15,
            color: AppColors.textSecondary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  session.displayTitle,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${session.agentName ?? 'Agent'} - ${formatRelativeSessionTime(session.displayTime)}',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textTertiary,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        children: [
          Icon(icon, size: 14, color: AppColors.textSecondary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
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

class _InspectorSectionDivider extends StatelessWidget {
  const _InspectorSectionDivider();

  @override
  Widget build(BuildContext context) {
    return const Divider(height: 25, thickness: 1, color: AppColors.borderSoft);
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value, this.maxLines = 1});

  final String label;
  final String value;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.textTertiary,
                fontSize: 10.5,
                fontWeight: FontWeight.w500,
                letterSpacing: 0,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value,
              maxLines: maxLines,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 12,
                height: 1.3,
                fontWeight: FontWeight.w500,
                letterSpacing: 0,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyLine extends StatelessWidget {
  const _EmptyLine({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Text(
      message,
      style: const TextStyle(
        color: AppColors.textSecondary,
        fontSize: 12,
        height: 1.35,
      ),
    );
  }
}

String _formatDate(DateTime? value) {
  if (value == null) return 'None';
  String two(int number) => number.toString().padLeft(2, '0');
  return '${value.year}-${two(value.month)}-${two(value.day)} '
      '${two(value.hour)}:${two(value.minute)}';
}

String _compactNumber(int value) {
  final absolute = value.abs();
  if (absolute >= 1000000) {
    return '${_trimCompact(value / 1000000)}M';
  }
  if (absolute >= 1000) return '${_trimCompact(value / 1000)}K';
  return value.toString();
}

String _trimCompact(double value) {
  final fixed = value.toStringAsFixed(value.abs() >= 10 ? 0 : 1);
  return fixed.endsWith('.0') ? fixed.substring(0, fixed.length - 2) : fixed;
}

String _filesystemProviderLabel(AcpFilesystemProviderConfig config) {
  final enabled = <String>[
    if (config.readTextFile) 'read',
    if (config.writeTextFile) 'write',
    if (config.allowReadOutsideWorkspace) 'outside workspace',
  ];
  return enabled.isEmpty ? 'Disabled' : enabled.join(', ');
}

String _fallback(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? 'None' : trimmed;
}
