import 'package:flutter/material.dart';

import '../../acp/agent_session.dart';
import '../../config/acp_client_config.dart';
import '../../state/connection_state.dart' as app_state;
import 'package:ianvs_agent_chat/ui/theme/app_design_tokens.dart';
import 'session_menu_actions.dart';

class AgentToolbar extends StatelessWidget {
  const AgentToolbar({
    super.key,
    this.title = 'Codex',
    this.agentName = 'Codex',
    required this.status,
    required this.onNewSession,
    required this.onReconnect,
    this.agentServers = const <AgentServerConfig>[],
    this.canSwitchAgent = true,
    this.forceFullActions = false,
    this.windowControlsInset = 0,
    this.onSelectAgent,
    this.onShowAgentConfig,
    this.onOpenLlmChat,
    this.onShowDiagnostics,
    this.onAuthenticate,
    this.onLogout,
    this.currentSession,
    this.canForkSession = false,
    this.sessionActionAvailability = const SessionActionAvailability(),
    this.supportsGitWorktrees = false,
    this.onSessionMenuAction,
    this.terminalPanelAction,
    this.onToggleSidebar,
    this.onToggleInspector,
    this.sidebarVisible = true,
    this.inspectorVisible = true,
  });

  final String title;
  final String agentName;
  final app_state.ConnectionStatus status;
  final VoidCallback? onNewSession;
  final VoidCallback? onReconnect;
  final List<AgentServerConfig> agentServers;
  final bool canSwitchAgent;
  final bool forceFullActions;
  final double windowControlsInset;
  final ValueChanged<String>? onSelectAgent;
  final VoidCallback? onShowAgentConfig;
  final VoidCallback? onOpenLlmChat;
  final VoidCallback? onShowDiagnostics;
  final VoidCallback? onAuthenticate;
  final VoidCallback? onLogout;
  final AgentSession? currentSession;
  final bool canForkSession;
  final SessionActionAvailability sessionActionAvailability;
  final bool supportsGitWorktrees;
  final ValueChanged<WorkspaceSessionMenuAction>? onSessionMenuAction;
  final Widget? terminalPanelAction;
  final VoidCallback? onToggleSidebar;
  final VoidCallback? onToggleInspector;
  final bool sidebarVisible;
  final bool inspectorVisible;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 52,
      decoration: const BoxDecoration(
        color: AppColors.surfaceRaised,
        border: Border(bottom: BorderSide(color: AppColors.borderSoft)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final availableWidth = constraints.maxWidth.isFinite
              ? constraints.maxWidth
              : MediaQuery.sizeOf(context).width;
          final compact =
              availableWidth < 720 ||
              (!forceFullActions && availableWidth < 1240);
          final veryCompact = availableWidth < 620;
          final horizontalPadding = veryCompact ? 8.0 : 12.0;

          return Padding(
            padding: EdgeInsets.fromLTRB(
              horizontalPadding + windowControlsInset,
              8,
              horizontalPadding,
              8,
            ),
            child: Row(
              children: [
                if (onToggleSidebar != null) ...[
                  IconButton(
                    key: const Key('compact-workspaces-button'),
                    style: IconButton.styleFrom(
                      minimumSize: const Size(32, 32),
                      visualDensity: VisualDensity.standard,
                    ),
                    tooltip: sidebarVisible
                        ? 'Hide Sidebar (⌘⌃S)'
                        : 'Show Sidebar (⌘⌃S)',
                    onPressed: onToggleSidebar,
                    icon: Icon(
                      Icons.view_sidebar_outlined,
                      size: 18,
                      semanticLabel: sidebarVisible
                          ? 'Hide Sidebar'
                          : 'Show Sidebar',
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: _BrandMark(
                    title: title,
                    agentName: agentName,
                    status: status,
                    compact: compact,
                    veryCompact: veryCompact,
                    currentSession: currentSession,
                    canForkSession: canForkSession,
                    sessionActionAvailability: sessionActionAvailability,
                    supportsGitWorktrees: supportsGitWorktrees,
                    onSessionMenuAction: onSessionMenuAction,
                  ),
                ),
                SizedBox(width: compact ? 8 : 14),
                _AgentMenuButton(
                  agentName: agentName,
                  agentServers: agentServers,
                  compact: true,
                  canSwitchAgent: canSwitchAgent,
                  onSelectAgent: onSelectAgent,
                  onShowAgentConfig: onShowAgentConfig,
                  onOpenLlmChat: onOpenLlmChat,
                  onShowDiagnostics: onShowDiagnostics,
                  onAuthenticate: onAuthenticate,
                  onLogout: onLogout,
                ),
                if (onReconnect != null) ...[
                  SizedBox(width: compact ? 5 : 8),
                  _ToolbarAction(
                    icon: Icons.refresh_rounded,
                    label: compact ? null : 'Reconnect',
                    tooltip: 'Reconnect',
                    onPressed: onReconnect,
                  ),
                ],
                if (terminalPanelAction != null) ...[
                  SizedBox(width: compact ? 5 : 8),
                  terminalPanelAction!,
                ],
                if (onToggleInspector != null) ...[
                  const SizedBox(width: 4),
                  IconButton(
                    key: const Key('compact-context-button'),
                    style: IconButton.styleFrom(
                      minimumSize: const Size(32, 32),
                      visualDensity: VisualDensity.standard,
                    ),
                    tooltip: inspectorVisible
                        ? 'Hide Context (⌘⌥I)'
                        : 'Show Context (⌘⌥I)',
                    isSelected: inspectorVisible,
                    onPressed: onToggleInspector,
                    icon: Icon(
                      Icons.view_sidebar_outlined,
                      size: 18,
                      semanticLabel: inspectorVisible
                          ? 'Hide Context'
                          : 'Show Context',
                    ),
                  ),
                ],
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
    required this.onOpenLlmChat,
    required this.onShowDiagnostics,
    required this.onAuthenticate,
    required this.onLogout,
  });
  final String agentName;
  final List<AgentServerConfig> agentServers;
  final bool compact;
  final bool canSwitchAgent;
  final ValueChanged<String>? onSelectAgent;
  final VoidCallback? onShowAgentConfig;
  final VoidCallback? onOpenLlmChat;
  final VoidCallback? onShowDiagnostics;
  final VoidCallback? onAuthenticate;
  final VoidCallback? onLogout;

  @override
  Widget build(BuildContext context) {
    final hasMenu =
        agentServers.isNotEmpty ||
        onShowAgentConfig != null ||
        onOpenLlmChat != null ||
        onAuthenticate != null ||
        onLogout != null;
    PopupMenuItem<String> action(String value, String label, IconData icon) =>
        PopupMenuItem(
          value: value,
          child: Row(
            children: [
              Icon(icon, size: 17),
              const SizedBox(width: 8),
              Expanded(child: Text(label, overflow: TextOverflow.ellipsis)),
            ],
          ),
        );
    return PopupMenuButton<String>(
      tooltip: 'Agents',
      enabled: hasMenu,
      onSelected: (value) {
        if (value.startsWith('agent:')) {
          onSelectAgent?.call(value.substring(6));
          return;
        }
        switch (value) {
          case 'configure':
            onShowAgentConfig?.call();
          case 'diagnostics':
            onShowDiagnostics?.call();
          case 'authenticate':
            onAuthenticate?.call();
          case 'logout':
            onLogout?.call();
          case 'llm':
            onOpenLlmChat?.call();
        }
      },
      itemBuilder: (_) => [
        for (final server in agentServers)
          PopupMenuItem(
            value: 'agent:${server.name}',
            enabled:
                canSwitchAgent &&
                onSelectAgent != null &&
                server.name != agentName,
            child: _AgentMenuItem(
              server: server,
              selected: server.name == agentName,
            ),
          ),
        if (agentServers.isNotEmpty) const PopupMenuDivider(),
        if (onShowAgentConfig != null)
          action('configure', '管理 Agent…', Icons.tune_rounded),
        if (onAuthenticate != null)
          action('authenticate', '认证', Icons.login_rounded),
        if (onLogout != null) action('logout', '退出登录', Icons.logout_rounded),
        if (onOpenLlmChat != null) ...[
          const PopupMenuDivider(),
          const PopupMenuItem<String>(
            enabled: false,
            height: 28,
            child: Text('高级'),
          ),
          action('llm', '独立 LLM 对话', Icons.chat_bubble_outline_rounded),
        ],
      ],
      child: _ToolbarButtonShell(
        icon: Icons.manage_accounts_outlined,
        label: compact ? null : 'Agents',
        enabled: hasMenu,
      ),
    );
  }
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
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0,
                ),
              ),
              Text(
                server.safeDisplayTarget,
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
        decoration: BoxDecoration(
          color: label == null ? Colors.transparent : AppColors.surfaceMuted,
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: label == null
              ? null
              : Border.all(color: AppColors.borderSoft),
        ),
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
                  fontSize: 12,
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

class _BrandMark extends StatelessWidget {
  const _BrandMark({
    required this.title,
    required this.agentName,
    required this.status,
    required this.compact,
    required this.veryCompact,
    required this.currentSession,
    required this.canForkSession,
    required this.sessionActionAvailability,
    required this.supportsGitWorktrees,
    required this.onSessionMenuAction,
  });

  final String title;
  final String agentName;
  final app_state.ConnectionStatus status;
  final bool compact;
  final bool veryCompact;
  final AgentSession? currentSession;
  final bool canForkSession;
  final SessionActionAvailability sessionActionAvailability;
  final bool supportsGitWorktrees;
  final ValueChanged<WorkspaceSessionMenuAction>? onSessionMenuAction;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final showAgentChip =
            !compact && agentName != 'Codex' && constraints.maxWidth >= 360;
        final showStatus =
            !veryCompact &&
            constraints.maxWidth >= 150 &&
            status != app_state.ConnectionStatus.connected &&
            status != app_state.ConnectionStatus.sessionReady;
        return Row(
          children: [
            Expanded(child: _buildTitle()),
            if (showAgentChip) ...[
              const SizedBox(width: 9),
              _AgentChip(agentName: agentName),
            ],
            if (showStatus) ...[
              const SizedBox(width: 6),
              _ConnectionBadge(status: status),
            ],
          ],
        );
      },
    );
  }

  Widget _buildTitle() {
    final label = Row(
      children: [
        const Icon(
          Icons.folder_outlined,
          size: 17,
          color: AppColors.textSecondary,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            title,
            overflow: TextOverflow.ellipsis,
            softWrap: false,
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.05,
            ),
          ),
        ),
      ],
    );
    final session = currentSession;
    final onSelected = onSessionMenuAction;
    if (session == null || onSelected == null) return label;
    return _ToolbarSessionActions(
      label: label,
      session: session,
      availability: SessionActionAvailability(
        canFork: sessionActionAvailability.canFork || canForkSession,
        supportsClose: sessionActionAvailability.supportsClose,
        canClose: sessionActionAvailability.canClose,
        supportsDelete: sessionActionAvailability.supportsDelete,
        canDelete: sessionActionAvailability.canDelete,
      ),
      supportsGitWorktrees: supportsGitWorktrees,
      onSelected: onSelected,
    );
  }
}

class _ToolbarSessionActions extends StatelessWidget {
  const _ToolbarSessionActions({
    required this.label,
    required this.session,
    required this.availability,
    required this.supportsGitWorktrees,
    required this.onSelected,
  });

  final Widget label;
  final AgentSession session;
  final SessionActionAvailability availability;
  final bool supportsGitWorktrees;
  final ValueChanged<WorkspaceSessionMenuAction> onSelected;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: label),
        const SizedBox(width: 6),
        MenuAnchor(
          alignmentOffset: const Offset(0, 7),
          consumeOutsideTap: true,
          style: _toolbarMenuStyle(),
          menuChildren: _toolbarSessionMenuItems(
            session: session,
            availability: availability,
            supportsGitWorktrees: supportsGitWorktrees,
            onSelected: onSelected,
          ),
          builder: (context, controller, child) {
            return Tooltip(
              message: '会话操作',
              child: InkWell(
                key: const Key('toolbar-session-actions'),
                borderRadius: BorderRadius.circular(AppRadius.sm),
                onTap: () {
                  if (controller.isOpen) {
                    controller.close();
                  } else {
                    controller.open();
                  }
                },
                child: Container(
                  width: 32,
                  height: 32,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: controller.isOpen
                        ? AppColors.surfaceSelected
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                  child: const Icon(
                    Icons.more_horiz_rounded,
                    color: AppColors.textSecondary,
                    size: 17,
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

List<Widget> _toolbarSessionMenuItems({
  required AgentSession session,
  required SessionActionAvailability availability,
  required bool supportsGitWorktrees,
  required ValueChanged<WorkspaceSessionMenuAction> onSelected,
}) {
  final actions = visibleWorkspaceSessionMenuActions(
    availability: availability,
    supportsGitWorktrees: supportsGitWorktrees,
  );
  final items = <Widget>[];
  SessionMenuActionSection? previousSection;
  for (final action in actions) {
    if (previousSection != null && action.section != previousSection) {
      items.add(const Divider(height: 9));
    }
    items.add(
      _toolbarMenuItem(
        action,
        action.iconFor(session),
        action.labelFor(session),
        onSelected,
        enabled: availability.isEnabled(action),
        destructive: action.isDestructive,
      ),
    );
    previousSection = action.section;
  }
  return items;
}

MenuStyle _toolbarMenuStyle() {
  return MenuStyle(
    backgroundColor: const WidgetStatePropertyAll(AppColors.surface),
    surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
    elevation: const WidgetStatePropertyAll(0),
    padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 6)),
    shape: WidgetStatePropertyAll(
      RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        side: const BorderSide(color: AppColors.border),
      ),
    ),
  );
}

MenuItemButton _toolbarMenuItem(
  WorkspaceSessionMenuAction value,
  IconData icon,
  String label,
  ValueChanged<WorkspaceSessionMenuAction> onSelected, {
  bool enabled = true,
  bool destructive = false,
}) {
  final color = enabled
      ? destructive
            ? AppColors.danger
            : AppColors.textPrimary
      : AppColors.textTertiary;
  return MenuItemButton(
    onPressed: enabled ? () => onSelected(value) : null,
    leadingIcon: Icon(icon, size: 17, color: color),
    style: ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size(250, 38)),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 12),
      ),
      foregroundColor: WidgetStatePropertyAll(color),
    ),
    child: Text(
      label,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
    ),
  );
}

class _AgentChip extends StatelessWidget {
  const _AgentChip({required this.agentName});

  final String agentName;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppColors.surfaceRaised,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: AppColors.border),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 190),
        child: Text(
          agentName,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: AppColors.textSecondary,
            fontWeight: FontWeight.w600,
            fontSize: 11.5,
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
        borderRadius: BorderRadius.circular(AppRadius.sm),
        onTap: onPressed,
        child: Container(
          width: label == null ? 34 : null,
          height: 34,
          padding: label == null
              ? EdgeInsets.zero
              : const EdgeInsets.symmetric(horizontal: 8),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: onPressed == null
                ? AppColors.surfaceRaised
                : AppColors.surfaceMuted,
            borderRadius: BorderRadius.circular(AppRadius.sm),
            border: Border.all(color: AppColors.borderSoft),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: _color, size: 17),
              if (label != null) ...[
                const SizedBox(width: 5),
                Text(
                  label!,
                  style: TextStyle(
                    color: _color,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
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
      onPressed == null ? AppColors.textTertiary : AppColors.textSecondary;
}

class _PrimaryToolbarAction extends StatelessWidget {
  const _PrimaryToolbarAction({required this.compact, required this.onPressed});

  final bool compact;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final style = TextButton.styleFrom(
      foregroundColor: AppColors.accent,
      disabledForegroundColor: AppColors.textTertiary,
      minimumSize: Size(compact ? 34 : 72, 34),
      padding: compact
          ? EdgeInsets.zero
          : const EdgeInsets.symmetric(horizontal: 8),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.standard,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    );

    final button = compact
        ? TextButton(
            onPressed: onPressed,
            style: style,
            child: const Icon(Icons.add_rounded, size: 18),
          )
        : TextButton(
            onPressed: onPressed,
            style: style,
            child: const Text(
              '新会话',
              style: TextStyle(
                fontFamily: AppTypography.family,
                fontFamilyFallback: AppTypography.familyFallback,
                fontSize: 12,
                fontWeight: FontWeight.w600,
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
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: 5),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.sm),
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
              color: AppColors.textSecondary,
              fontWeight: FontWeight.w600,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}
