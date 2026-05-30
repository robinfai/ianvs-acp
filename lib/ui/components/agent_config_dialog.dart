import 'package:flutter/material.dart';

import '../../acp/acp_permission_request.dart';
import '../../config/acp_client_config.dart';
import '../theme/app_design_tokens.dart';

class AgentConfigDialog extends StatelessWidget {
  const AgentConfigDialog({
    super.key,
    required this.agentServers,
    required this.activeAgentName,
    this.mcpServers = const <McpServerConfig>[],
    this.clientProviders = const AcpClientProviderConfig(),
    this.configPath,
    this.defaultAgentName,
  });

  final List<AgentServerConfig> agentServers;
  final List<McpServerConfig> mcpServers;
  final AcpClientProviderConfig clientProviders;
  final String activeAgentName;
  final String? configPath;
  final String? defaultAgentName;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Agent Configuration'),
      content: SizedBox(
        width: 640,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _ConfigPathPanel(path: configPath),
              if (mcpServers.isNotEmpty) ...[
                const SizedBox(height: 10),
                _McpServersPanel(servers: mcpServers),
              ],
              if (clientProviders.filesystem.enabled ||
                  clientProviders.filesystem.allowReadOutsideWorkspace ||
                  clientProviders.terminal.enabled ||
                  clientProviders.permissions.hasTrustRules) ...[
                const SizedBox(height: 10),
                _ClientProvidersPanel(providers: clientProviders),
              ],
              const SizedBox(height: 10),
              if (agentServers.isEmpty)
                const _EmptyState()
              else
                Column(
                  children: [
                    for (final server in agentServers) ...[
                      _AgentServerPanel(
                        server: server,
                        selected: server.name == activeAgentName,
                        isDefault: server.name == defaultAgentName,
                      ),
                      if (server != agentServers.last)
                        const SizedBox(height: 8),
                    ],
                  ],
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _ClientProvidersPanel extends StatelessWidget {
  const _ClientProvidersPanel({required this.providers});

  final AcpClientProviderConfig providers;

  @override
  Widget build(BuildContext context) {
    final fs = providers.filesystem;
    final terminal = providers.terminal;
    final permissions = providers.permissions;
    return _Panel(
      icon: Icons.security_rounded,
      title: 'Client Providers',
      accent: AppColors.warning,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _DetailRow(
            label: 'FS read',
            value: fs.readTextFile ? 'Enabled' : 'Disabled',
          ),
          const SizedBox(height: 6),
          _DetailRow(
            label: 'FS write',
            value: fs.writeTextFile ? 'Enabled' : 'Disabled',
          ),
          const SizedBox(height: 6),
          _DetailRow(
            label: 'Outside',
            value: fs.allowReadOutsideWorkspace ? 'Read allowed' : 'Jailed',
          ),
          const SizedBox(height: 6),
          _DetailRow(
            label: 'Terminal',
            value: terminal.enabled ? 'Enabled' : 'Disabled',
          ),
          const SizedBox(height: 6),
          _DetailRow(
            label: 'Trust rules',
            value: permissions.hasTrustRules
                ? '${permissions.trustRules.length}'
                : 'None',
          ),
          for (final rule in permissions.trustRules) ...[
            const SizedBox(height: 6),
            _DetailRow(label: 'Rule', value: _permissionTrustRuleLabel(rule)),
          ],
        ],
      ),
    );
  }
}

String _permissionTrustRuleLabel(AcpPermissionTrustRule rule) {
  final kind = rule.toolKind?.trim();
  final target = kind == null || kind.isEmpty
      ? rule.toolName.trim()
      : '${rule.toolName.trim()} / $kind';
  return '$target -> ${rule.displayDecision}';
}

class _McpServersPanel extends StatelessWidget {
  const _McpServersPanel({required this.servers});

  final List<McpServerConfig> servers;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      icon: Icons.extension_rounded,
      title: 'MCP Servers',
      accent: AppColors.success,
      trailing: _TinyPill('${servers.length}', AppColors.success),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final server in servers) ...[
            _DetailRow(label: 'Name', value: server.name),
            const SizedBox(height: 6),
            _DetailRow(label: 'Type', value: server.type),
            const SizedBox(height: 6),
            _DetailRow(
              label: server.command.isNotEmpty ? 'Command' : 'URL',
              value: server.command.isNotEmpty ? server.command : server.url,
            ),
            if (server != servers.last) ...[
              const SizedBox(height: 8),
              const Divider(height: 1, color: AppColors.border),
              const SizedBox(height: 8),
            ],
          ],
        ],
      ),
    );
  }
}

class _ConfigPathPanel extends StatelessWidget {
  const _ConfigPathPanel({required this.path});

  final String? path;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      icon: Icons.description_outlined,
      title: 'User Config',
      child: SelectableText(
        path == null || path!.isEmpty ? 'Not resolved' : path!,
        style: const TextStyle(
          color: AppColors.textSecondary,
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 0,
        ),
      ),
    );
  }
}

class _AgentServerPanel extends StatelessWidget {
  const _AgentServerPanel({
    required this.server,
    required this.selected,
    required this.isDefault,
  });

  final AgentServerConfig server;
  final bool selected;
  final bool isDefault;

  @override
  Widget build(BuildContext context) {
    final args = server.args.isEmpty ? 'No args' : server.args.join(' ');
    final envKeys = server.env.keys.toList()..sort();
    final headerKeys = server.headers.keys.toList()..sort();

    return _Panel(
      icon: selected ? Icons.check_circle_rounded : Icons.hub_outlined,
      title: server.name,
      accent: selected ? AppColors.success : AppColors.primaryDark,
      trailing: Wrap(
        spacing: 5,
        runSpacing: 5,
        children: [
          if (selected) const _TinyPill('Current', AppColors.success),
          if (isDefault) const _TinyPill('Default', AppColors.primaryDark),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _DetailRow(label: 'Type', value: server.type),
          const SizedBox(height: 6),
          if (!server.isStdio) ...[
            _DetailRow(label: 'URL', value: server.url),
            const SizedBox(height: 6),
            _DetailRow(
              label: 'Headers',
              value: headerKeys.isEmpty
                  ? 'No header keys'
                  : headerKeys.join(', '),
            ),
          ] else ...[
            _DetailRow(label: 'Command', value: server.command),
            const SizedBox(height: 6),
            _DetailRow(label: 'Args', value: args),
            const SizedBox(height: 6),
            _DetailRow(
              label: 'Env',
              value: envKeys.isEmpty ? 'No env keys' : envKeys.join(', '),
            ),
          ],
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 82,
          child: Text(
            label,
            style: const TextStyle(
              color: AppColors.textTertiary,
              fontSize: 12,
              fontWeight: FontWeight.w800,
              letterSpacing: 0,
            ),
          ),
        ),
        Expanded(
          child: SelectableText(
            value,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 0,
            ),
          ),
        ),
      ],
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({
    required this.icon,
    required this.title,
    required this.child,
    this.accent = AppColors.primaryDark,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final Widget child;
  final Color accent;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.surfaceRaised,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 17, color: accent),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  title,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0,
                  ),
                ),
              ),
              if (trailing != null) ...[const SizedBox(width: 8), trailing!],
            ],
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

class _TinyPill extends StatelessWidget {
  const _TinyPill(this.label, this.color);

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w900,
          letterSpacing: 0,
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      height: 130,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.surfaceRaised,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.border),
      ),
      child: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.info_outline_rounded, color: AppColors.primaryDark),
          SizedBox(height: 8),
          Text(
            'No user-configured agent servers.',
            style: TextStyle(
              color: AppColors.textSecondary,
              fontWeight: FontWeight.w700,
              letterSpacing: 0,
            ),
          ),
        ],
      ),
    );
  }
}
