import 'package:ianvs_design/ianvs_design.dart';

import '../../acp/acp_session_settings.dart';
import '../../acp/acp_session_usage.dart';
import '../../acp/agent_session.dart';
import '../../config/acp_client_config.dart';
import '../../workspace/workspace.dart';
import 'session_time_label.dart';

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
  final VoidCallback? onShowSessionSettings;
  final VoidCallback? onShowCapabilities;

  @override
  Widget build(BuildContext context) {
    final branch = environmentBranch ?? _sessionBranch(currentSession);
    final model = sessionSettings.modelOption?.currentChoiceLabel.trim();
    final reasoning = sessionSettings.reasoningEffortOption?.currentChoiceLabel
        .trim();
    final mode = _sessionModeLabel(sessionSettings);
    return Material(
      color: context.ianvs.canvas,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Padding(
          padding: EdgeInsets.zero,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _CompactInspectorHeader(
                label: '当前会话',
                actionIcon: Icons.tune_rounded,
                actionTooltip: '打开会话参数',
                onAction: onShowSessionSettings,
                prominent: true,
              ),
              if (currentSession == null)
                const _CompactSourceRow(
                  icon: Icons.chat_bubble_outline_rounded,
                  label: '尚未开始会话',
                  muted: true,
                )
              else ...[
                _CompactSourceRow(
                  icon: Icons.smart_toy_outlined,
                  label: agentName,
                ),
                if (model != null && model.isNotEmpty)
                  _CompactSourceRow(icon: Icons.memory_outlined, label: model),
                if (reasoning != null && reasoning.isNotEmpty)
                  _CompactSourceRow(
                    icon: Icons.psychology_outlined,
                    label: reasoning,
                  ),
                if (mode != null)
                  _CompactSourceRow(
                    icon: Icons.swap_horiz_rounded,
                    label: mode,
                  ),
              ],
              const SizedBox(height: 14),
              Divider(height: 1, color: context.ianvs.separator),
              const SizedBox(height: 12),
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
              const SizedBox(height: 12),
              Divider(height: 1, color: context.ianvs.separator),
              const SizedBox(height: 12),
              _InspectorDisclosure(
                label: '上下文',
                children: [
                  _CompactSourceRow(
                    icon: Icons.folder_outlined,
                    label: workspace.name,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Divider(height: 1, color: context.ianvs.separator),
              const SizedBox(height: 12),
              const _CompactInspectorHeader(
                label: '详细信息',
                actionIcon: Icons.add_rounded,
                actionTooltip: '添加来源',
                onAction: null,
              ),
              const SizedBox(height: 8),
              _CompactSourceRow(
                icon: Icons.link_rounded,
                label: '查看会话详情',
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
        child: SizedBox(width: 680, height: 620, child: _detailsBody(context)),
      ),
    );
  }

  Widget _detailsBody(BuildContext context) {
    return DefaultTabController(
      key: ValueKey(
        currentSession == null
            ? 'workspace-inspector-overview'
            : 'workspace-inspector-context',
      ),
      length: 2,
      initialIndex: currentSession == null ? 0 : 1,
      child: Container(
        color: context.ianvs.canvas,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: Row(
                children: [
                  Icon(
                    Icons.menu_book_outlined,
                    color: context.ianvs.muted,
                    size: 17,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '会话详情',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: context.ianvs.text,
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
                labelColor: context.ianvs.text,
                unselectedLabelColor: context.ianvs.muted,
                dividerColor: Colors.transparent,
                indicator: UnderlineTabIndicator(
                  borderSide: BorderSide(color: context.ianvs.accent, width: 2),
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
                  Tab(text: '概览'),
                  Tab(text: '上下文'),
                ],
              ),
            ),
            Divider(height: 1, color: context.ianvs.border),
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

String? _sessionModeLabel(AcpSessionSettings settings) {
  if (!settings.shouldUseModeFallback) return null;
  final currentId = settings.modes.currentModeId?.trim();
  if (currentId == null || currentId.isEmpty) return null;
  for (final mode in settings.modes.availableModes) {
    if (mode.id == currentId) return mode.label;
  }
  return currentId;
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
                  TextStyle(
                    color: context.ianvs.text,
                    fontSize: 13.5,
                    height: 1.3,
                    fontWeight: FontWeight.w600,
                  ).copyWith(
                    color: prominent ? context.ianvs.text : context.ianvs.muted,
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
        borderRadius: BorderRadius.circular(context.ianvs.controlRadius),
        onTap: onTap,
        child: SizedBox(
          height: 40,
          child: Row(
            children: [
              Icon(icon, size: 17, color: context.ianvs.muted),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: muted ? context.ianvs.subtle : context.ianvs.muted,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              if (trailing != null)
                Icon(trailing, size: 15, color: context.ianvs.subtle),
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
            borderRadius: BorderRadius.circular(context.ianvs.controlRadius),
            onTap: () => setState(() => _expanded = !_expanded),
            child: SizedBox(
              height: 40,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.label,
                      style: TextStyle(
                        color: context.ianvs.muted,
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
                    color: context.ianvs.subtle,
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
        _SectionTitle(icon: Icons.folder_open_rounded, label: '目录'),
        _InfoRow(label: '名称', value: workspace.name),
        _InfoRow(label: '路径', value: workspace.path, maxLines: 3),
        _InfoRow(label: 'Agent', value: agentName),
        _InfoRow(label: '会话数', value: workspace.sessionCount.toString()),
        _InfoRow(label: '最近活动', value: _formatDate(workspace.lastActivityAt)),
        if (currentSession != null)
          _InfoRow(
            label: '当前会话',
            value: currentSession!.displayTitle,
            maxLines: 2,
          ),
        const _InspectorSectionDivider(),
        _SectionTitle(icon: Icons.forum_outlined, label: '最近会话'),
        if (recentSessions.isEmpty)
          const _EmptyLine(message: '此工作区还没有会话。')
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
        _SectionTitle(icon: Icons.chat_bubble_outline_rounded, label: '当前会话'),
        _InfoRow(label: 'Agent', value: agentName),
        if (currentSession == null)
          const _EmptyLine(message: '开始会话后可查看上下文。')
        else ...[
          if (sessionSettings.modelOption case final option?)
            _InfoRow(label: '模型', value: option.currentChoiceLabel),
          if (sessionSettings.reasoningEffortOption case final option?)
            _InfoRow(label: '推理', value: option.currentChoiceLabel),
          if (_sessionModeLabel(sessionSettings) case final mode?)
            _InfoRow(label: '模式', value: mode),
          _InfoRow(label: '会话 ID', value: currentSession!.id, maxLines: 2),
          if (sessionUsage != null) _UsageRow(usage: sessionUsage!),
          _InfoRow(label: '工作目录', value: currentSession!.cwd, maxLines: 3),
          if (onShowSessionSettings != null)
            _InspectorActionRow(
              icon: Icons.tune_rounded,
              label: '打开会话参数…',
              onTap: onShowSessionSettings!,
            ),
        ],
        const SizedBox(height: 3),
        _DiagnosticsSection(
          lastLatency: lastLatency,
          onShowCapabilities: onShowCapabilities,
        ),
        const _InspectorSectionDivider(),
        _SectionTitle(icon: Icons.account_tree_outlined, label: '路径'),
        if (currentSession == null)
          _InfoRow(label: '工作区', value: workspace.path, maxLines: 3),
        if (additionalDirectories.isEmpty)
          const _InfoRow(label: '额外目录', value: '无')
        else
          for (final directory in additionalDirectories)
            _InfoRow(label: '额外目录', value: directory, maxLines: 3),
        _InfoRow(label: '配置文件', value: _fallback(configPath), maxLines: 3),
        const _InspectorSectionDivider(),
        _SectionTitle(icon: Icons.hub_outlined, label: 'MCP'),
        if (mcpServers.isEmpty)
          const _EmptyLine(message: '未配置 MCP 服务。')
        else
          for (final server in mcpServers) _McpServerRow(server),
        const _InspectorSectionDivider(),
        _SectionTitle(icon: Icons.shield_outlined, label: '客户端能力'),
        _InfoRow(
          label: '文件系统',
          value: _filesystemProviderLabel(clientProviders.filesystem),
        ),
        _InfoRow(
          label: '终端',
          value: clientProviders.terminal.enabled ? '已启用' : '已停用',
        ),
        _InfoRow(
          label: '信任规则',
          value: clientProviders.permissions.trustRules.length.toString(),
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
          _InfoRow(label: '上下文', value: label),
          Padding(
            padding: const EdgeInsets.only(left: 80),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 3,
                backgroundColor: context.ianvs.chrome,
                color: _usageColor(context, percent),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Color _usageColor(BuildContext context, double? percent) {
    if (percent == null) return context.ianvs.muted;
    if (percent >= 0.95) return context.ianvs.danger;
    if (percent >= 0.75) return context.ianvs.warning;
    return context.ianvs.text;
  }
}

class _DiagnosticsSection extends StatelessWidget {
  const _DiagnosticsSection({
    required this.lastLatency,
    required this.onShowCapabilities,
  });

  final Duration? lastLatency;
  final VoidCallback? onShowCapabilities;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: Material(
        color: context.ianvs.canvas,
        child: ExpansionTile(
          key: const Key('workspace-diagnostics-section'),
          tilePadding: EdgeInsets.zero,
          childrenPadding: EdgeInsets.zero,
          minTileHeight: 34,
          dense: true,
          leading: Icon(
            Icons.tune_rounded,
            size: 14,
            color: context.ianvs.muted,
          ),
          title: Text(
            '诊断',
            style: TextStyle(
              color: context.ianvs.muted,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          children: [
            _InfoRow(
              label: '延迟',
              value: lastLatency == null
                  ? '尚未测量'
                  : '${lastLatency!.inMilliseconds} ms',
            ),
            if (onShowCapabilities != null)
              _InspectorActionRow(
                icon: Icons.fact_check_outlined,
                label: '打开运行诊断…',
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
      borderRadius: BorderRadius.circular(context.ianvs.controlRadius),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          children: [
            Icon(icon, size: 14, color: context.ianvs.muted),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: context.ianvs.text,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              size: 15,
              color: context.ianvs.subtle,
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
              color: context.ianvs.canvas,
              borderRadius: BorderRadius.circular(context.ianvs.controlRadius),
              border: Border.all(color: context.ianvs.separator),
            ),
            child: Icon(
              Icons.hub_outlined,
              size: 13,
              color: context.ianvs.muted,
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
                  style: TextStyle(
                    color: context.ianvs.text,
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
                  style: TextStyle(
                    color: context.ianvs.muted,
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
          Icon(
            Icons.chat_bubble_outline_rounded,
            size: 15,
            color: context.ianvs.muted,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  session.displayTitle,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: context.ianvs.text,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${session.agentName ?? 'Agent'} - ${formatRelativeSessionTime(session.displayTime)}',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: context.ianvs.subtle, fontSize: 11),
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
          Icon(icon, size: 14, color: context.ianvs.muted),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: context.ianvs.muted,
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
    return Divider(height: 25, thickness: 1, color: context.ianvs.separator);
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
              style: TextStyle(
                color: context.ianvs.subtle,
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
              style: TextStyle(
                color: context.ianvs.text,
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
      style: TextStyle(color: context.ianvs.muted, fontSize: 12, height: 1.35),
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
    if (config.readTextFile) '读取',
    if (config.writeTextFile) '写入',
    if (config.allowReadOutsideWorkspace) '工作区外读取',
  ];
  return enabled.isEmpty ? '已停用' : enabled.join('、');
}

String _fallback(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? '无' : trimmed;
}
