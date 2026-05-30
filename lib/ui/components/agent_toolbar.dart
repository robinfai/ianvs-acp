import 'package:flutter/material.dart';

import '../../config/acp_client_config.dart';
import '../../state/connection_state.dart' as app_state;
import '../theme/app_design_tokens.dart';

class AgentToolbar extends StatelessWidget {
  const AgentToolbar({
    super.key,
    this.agentName = 'Codex',
    required this.status,
    required this.onNewSession,
    required this.onResumeSession,
    required this.onReconnect,
    this.agentServers = const <AgentServerConfig>[],
    this.canSwitchAgent = true,
    this.onSelectAgent,
    this.onShowAgentConfig,
  });

  final String agentName;
  final app_state.ConnectionStatus status;
  final VoidCallback? onNewSession;
  final VoidCallback? onResumeSession;
  final VoidCallback? onReconnect;
  final List<AgentServerConfig> agentServers;
  final bool canSwitchAgent;
  final ValueChanged<String>? onSelectAgent;
  final VoidCallback? onShowAgentConfig;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 60,
      decoration: const BoxDecoration(color: AppColors.bg),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final availableWidth = constraints.maxWidth.isFinite
              ? constraints.maxWidth
              : MediaQuery.sizeOf(context).width;
          final compact = availableWidth < 1240;
          final veryCompact = availableWidth < 620;
          final horizontalPadding = veryCompact
              ? 14.0
              : (compact ? 18.0 : 24.0);

          return Padding(
            padding: EdgeInsets.fromLTRB(
              horizontalPadding,
              8,
              horizontalPadding,
              8,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: _BrandMark(
                      agentName: agentName,
                      status: status,
                      compact: compact,
                      veryCompact: veryCompact,
                    ),
                  ),
                ),
                SizedBox(width: compact ? 8 : 14),
                _AgentMenuButton(
                  agentName: agentName,
                  agentServers: agentServers,
                  compact: compact,
                  canSwitchAgent: canSwitchAgent,
                  onSelectAgent: onSelectAgent,
                  onShowAgentConfig: onShowAgentConfig,
                ),
                SizedBox(width: compact ? 5 : 8),
                _ToolbarAction(
                  icon: Icons.play_circle_outline,
                  label: compact ? null : 'Resume',
                  tooltip: 'Resume',
                  onPressed: onResumeSession,
                ),
                SizedBox(width: compact ? 5 : 8),
                _ToolbarAction(
                  icon: Icons.refresh_rounded,
                  label: compact ? null : 'Reconnect',
                  tooltip: 'Reconnect',
                  onPressed: onReconnect,
                ),
                SizedBox(width: compact ? 6 : 10),
                _PrimaryToolbarAction(
                  compact: compact,
                  onPressed: onNewSession,
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _AgentMenuButton extends StatelessWidget {
  const _AgentMenuButton({
    required this.agentName,
    required this.agentServers,
    required this.compact,
    required this.canSwitchAgent,
    required this.onSelectAgent,
    required this.onShowAgentConfig,
  });

  final String agentName;
  final List<AgentServerConfig> agentServers;
  final bool compact;
  final bool canSwitchAgent;
  final ValueChanged<String>? onSelectAgent;
  final VoidCallback? onShowAgentConfig;

  @override
  Widget build(BuildContext context) {
    final hasMenu = agentServers.isNotEmpty || onShowAgentConfig != null;
    return PopupMenuButton<_AgentMenuSelection>(
      tooltip: 'Agents',
      enabled: hasMenu,
      onSelected: (selection) {
        switch (selection.type) {
          case _AgentMenuSelectionType.agent:
            final agentName = selection.agentName;
            if (agentName != null) onSelectAgent?.call(agentName);
          case _AgentMenuSelectionType.configure:
            onShowAgentConfig?.call();
        }
      },
      itemBuilder: (context) {
        return [
          const PopupMenuItem<_AgentMenuSelection>(
            enabled: false,
            height: 32,
            child: Text(
              'Agents',
              style: TextStyle(
                color: AppColors.textTertiary,
                fontSize: 12,
                fontWeight: FontWeight.w800,
                letterSpacing: 0,
              ),
            ),
          ),
          for (final server in agentServers)
            PopupMenuItem<_AgentMenuSelection>(
              value: _AgentMenuSelection.agent(server.name),
              enabled:
                  canSwitchAgent &&
                  onSelectAgent != null &&
                  server.name != agentName,
              child: _AgentMenuItem(
                server: server,
                selected: server.name == agentName,
              ),
            ),
          if (agentServers.isNotEmpty && onShowAgentConfig != null)
            const PopupMenuDivider(),
          if (onShowAgentConfig != null)
            const PopupMenuItem<_AgentMenuSelection>(
              value: _AgentMenuSelection.configure(),
              child: Row(
                children: [
                  Icon(
                    Icons.tune_rounded,
                    size: 17,
                    color: AppColors.primaryDark,
                  ),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Agent Configuration',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ];
      },
      child: _ToolbarButtonShell(
        icon: Icons.manage_accounts_outlined,
        label: compact ? null : 'Agents',
        enabled: hasMenu,
      ),
    );
  }
}

enum _AgentMenuSelectionType { agent, configure }

class _AgentMenuSelection {
  const _AgentMenuSelection.agent(this.agentName)
    : type = _AgentMenuSelectionType.agent;

  const _AgentMenuSelection.configure()
    : type = _AgentMenuSelectionType.configure,
      agentName = null;

  final _AgentMenuSelectionType type;
  final String? agentName;
}

class _AgentMenuItem extends StatelessWidget {
  const _AgentMenuItem({required this.server, required this.selected});

  final AgentServerConfig server;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(
          selected ? Icons.check_circle_rounded : Icons.circle_outlined,
          size: 17,
          color: selected ? AppColors.success : AppColors.textTertiary,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                server.name,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0,
                ),
              ),
              Text(
                server.command,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.textTertiary,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ToolbarButtonShell extends StatelessWidget {
  const _ToolbarButtonShell({
    required this.icon,
    required this.label,
    required this.enabled,
  });

  final IconData icon;
  final String? label;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final color = enabled ? AppColors.primaryDark : AppColors.textTertiary;
    return Semantics(
      button: true,
      enabled: enabled,
      label: label ?? 'Agents',
      child: Container(
        width: label == null ? 32 : null,
        height: 32,
        padding: label == null
            ? EdgeInsets.zero
            : const EdgeInsets.symmetric(horizontal: 8),
        alignment: Alignment.center,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 18),
            if (label != null) ...[
              const SizedBox(width: 5),
              Text(
                label!,
                style: TextStyle(
                  color: color,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
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

class _BrandMark extends StatelessWidget {
  const _BrandMark({
    required this.agentName,
    required this.status,
    required this.compact,
    required this.veryCompact,
  });

  final String agentName;
  final app_state.ConnectionStatus status;
  final bool compact;
  final bool veryCompact;

  @override
  Widget build(BuildContext context) {
    final title = veryCompact ? 'ACP' : 'ACP Client';

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: AppColors.primarySoft,
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          child: const Icon(
            Icons.hub_outlined,
            color: AppColors.primary,
            size: 19,
          ),
        ),
        SizedBox(width: veryCompact ? 7 : 10),
        Flexible(
          child: Text(
            title,
            overflow: TextOverflow.ellipsis,
            softWrap: false,
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: veryCompact ? 16 : 19,
              fontWeight: FontWeight.w800,
              letterSpacing: 0,
            ),
          ),
        ),
        if (!compact) ...[
          SizedBox(width: compact ? 10 : 14),
          _AgentChip(agentName: agentName),
        ],
        if (!compact) ...[
          const SizedBox(width: 8),
          _ConnectionBadge(status: status),
        ],
      ],
    );
  }
}

class _AgentChip extends StatelessWidget {
  const _AgentChip({required this.agentName});

  final String agentName;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppColors.primarySoft,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.08)),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 190),
        child: Text(
          agentName,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: AppColors.primaryDark,
            fontWeight: FontWeight.w800,
            fontSize: 12,
          ),
        ),
      ),
    );
  }
}

class _ToolbarAction extends StatelessWidget {
  const _ToolbarAction({
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String? label;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final content = Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.pill),
        onTap: onPressed,
        child: Container(
          width: label == null ? 32 : null,
          height: 32,
          padding: label == null
              ? EdgeInsets.zero
              : const EdgeInsets.symmetric(horizontal: 8),
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: _color, size: 18),
              if (label != null) ...[
                const SizedBox(width: 5),
                Text(
                  label!,
                  style: TextStyle(
                    color: _color,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );

    return Semantics(
      button: true,
      enabled: onPressed != null,
      label: tooltip,
      child: Tooltip(message: tooltip, child: content),
    );
  }

  Color get _color =>
      onPressed == null ? AppColors.textTertiary : AppColors.primaryDark;
}

class _PrimaryToolbarAction extends StatelessWidget {
  const _PrimaryToolbarAction({required this.compact, required this.onPressed});

  final bool compact;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final style = FilledButton.styleFrom(
      foregroundColor: Colors.white,
      disabledForegroundColor: AppColors.textTertiary,
      backgroundColor: AppColors.primaryDark,
      disabledBackgroundColor: AppColors.surfaceRaised,
      elevation: 4,
      shadowColor: AppColors.primary.withValues(alpha: 0.32),
      minimumSize: Size(compact ? 38 : 142, 38),
      padding: compact
          ? EdgeInsets.zero
          : const EdgeInsets.symmetric(horizontal: 14),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
    );

    final button = compact
        ? FilledButton(
            onPressed: onPressed,
            style: style,
            child: const Icon(Icons.add_rounded, size: 20),
          )
        : FilledButton.icon(
            onPressed: onPressed,
            style: style,
            icon: const Icon(Icons.add_rounded, size: 20),
            label: const Text(
              'New Session',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                letterSpacing: 0,
              ),
            ),
          );

    return Tooltip(message: 'New Session', child: button);
  }
}

class _ConnectionBadge extends StatelessWidget {
  const _ConnectionBadge({required this.status});

  final app_state.ConnectionStatus status;

  @override
  Widget build(BuildContext context) {
    final (color, background) = switch (status) {
      app_state.ConnectionStatus.connected ||
      app_state.ConnectionStatus.sessionReady => (
        const Color(0xff047857),
        const Color(0xffecfdf5),
      ),
      app_state.ConnectionStatus.connecting ||
      app_state.ConnectionStatus.reconnecting ||
      app_state.ConnectionStatus.streaming => (
        const Color(0xff1d4ed8),
        const Color(0xffeff6ff),
      ),
      app_state.ConnectionStatus.error => (
        const Color(0xffb91c1c),
        const Color(0xfffef2f2),
      ),
      app_state.ConnectionStatus.disconnected => (
        const Color(0xff6b7280),
        const Color(0xfff3f4f6),
      ),
    };

    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            status.label,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w800,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}
