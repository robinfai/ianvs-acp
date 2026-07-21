import 'package:flutter/material.dart';

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
    this.configPath,
  });

  final WorkspaceRecord workspace;
  final String agentName;
  final AgentSession? currentSession;
  final List<McpServerConfig> mcpServers;
  final List<String> additionalDirectories;
  final AcpClientProviderConfig clientProviders;
  final String? configPath;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Container(
        color: AppColors.surfaceRaised,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
              child: Row(
                children: [
                  Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: AppColors.primarySoft,
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                    ),
                    child: const Icon(
                      Icons.info_outline_rounded,
                      color: AppColors.primaryDark,
                      size: 16,
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Workspace',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            TabBar(
              labelColor: AppColors.primaryDark,
              unselectedLabelColor: AppColors.textSecondary,
              indicatorColor: AppColors.primary,
              indicatorSize: TabBarIndicatorSize.tab,
              labelStyle: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w900,
                letterSpacing: 0,
              ),
              unselectedLabelStyle: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                letterSpacing: 0,
              ),
              tabs: const [
                Tab(text: 'Overview'),
                Tab(text: 'Context'),
              ],
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
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 18),
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
        const SizedBox(height: 16),
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
    required this.mcpServers,
    required this.additionalDirectories,
    required this.clientProviders,
    required this.configPath,
  });

  final WorkspaceRecord workspace;
  final List<McpServerConfig> mcpServers;
  final List<String> additionalDirectories;
  final AcpClientProviderConfig clientProviders;
  final String? configPath;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 18),
      children: [
        _SectionTitle(icon: Icons.account_tree_outlined, label: 'Paths'),
        _InfoRow(label: 'Workspace cwd', value: workspace.path, maxLines: 3),
        if (additionalDirectories.isEmpty)
          const _InfoRow(label: 'Additional dirs', value: 'None')
        else
          for (final directory in additionalDirectories)
            _InfoRow(label: 'Additional dir', value: directory, maxLines: 3),
        _InfoRow(label: 'Config', value: _fallback(configPath), maxLines: 3),
        const SizedBox(height: 16),
        _SectionTitle(icon: Icons.hub_outlined, label: 'MCP'),
        if (mcpServers.isEmpty)
          const _EmptyLine(message: 'No MCP servers configured.')
        else
          for (final server in mcpServers) _McpServerRow(server),
        const SizedBox(height: 16),
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

class _McpServerRow extends StatelessWidget {
  const _McpServerRow(this.server);

  final McpServerConfig server;

  @override
  Widget build(BuildContext context) {
    final target = server.url.isNotEmpty ? server.url : server.command;
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
                    fontWeight: FontWeight.w800,
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
                    fontWeight: FontWeight.w800,
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
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(icon, size: 14, color: AppColors.primaryDark),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 12,
                fontWeight: FontWeight.w900,
                letterSpacing: 0,
              ),
            ),
          ),
        ],
      ),
    );
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.textTertiary,
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 0,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            maxLines: maxLines,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12,
              height: 1.3,
              fontWeight: FontWeight.w700,
              letterSpacing: 0,
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
