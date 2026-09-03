import 'package:flutter/material.dart';

import '../../acp/agent_session.dart';
import '../../config/acp_client_config.dart';
import '../../state/connection_state.dart' as app_state;
import '../theme/app_design_tokens.dart';
import 'workspace_sidebar.dart';

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
    this.onShowProtocolCoverage,
    this.onShowActivity,
    this.onShowRuntimeInventory,
    this.onAuthenticate,
    this.onShowPermissionHistory,
    this.onLogout,
    this.currentSession,
    this.canForkSession = false,
    this.supportsGitWorktrees = false,
    this.onSessionMenuAction,
    this.terminalPanelAction,
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
  final VoidCallback? onShowProtocolCoverage;
  final VoidCallback? onShowActivity;
  final VoidCallback? onShowRuntimeInventory;
  final VoidCallback? onAuthenticate;
  final VoidCallback? onShowPermissionHistory;
  final VoidCallback? onLogout;
  final AgentSession? currentSession;
  final bool canForkSession;
  final bool supportsGitWorktrees;
  final ValueChanged<WorkspaceSessionMenuAction>? onSessionMenuAction;
  final Widget? terminalPanelAction;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 54,
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.borderSoft)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final availableWidth = constraints.maxWidth.isFinite
              ? constraints.maxWidth
              : MediaQuery.sizeOf(context).width;
          final compact = !forceFullActions && availableWidth < 1240;
          final veryCompact = availableWidth < 620;
          final horizontalPadding = veryCompact
              ? 14.0
              : (compact ? 18.0 : 20.0);

          return Padding(
            padding: EdgeInsets.fromLTRB(
              horizontalPadding + windowControlsInset,
              8,
              horizontalPadding,
              8,
            ),
            child: Row(
              children: [
                Expanded(
                  child: _BrandMark(
                    title: title,
                    agentName: agentName,
                    status: status,
                    compact: compact,
                    veryCompact: veryCompact,
                    currentSession: currentSession,
                    canForkSession: canForkSession,
                    supportsGitWorktrees: supportsGitWorktrees,
                    onSessionMenuAction: onSessionMenuAction,
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
                  onShowProtocolCoverage: onShowProtocolCoverage,
                  onShowActivity: onShowActivity,
                  onShowRuntimeInventory: onShowRuntimeInventory,
                  onAuthenticate: onAuthenticate,
                  onShowPermissionHistory: onShowPermissionHistory,
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
    required this.onShowProtocolCoverage,
    required this.onShowActivity,
    required this.onShowRuntimeInventory,
    required this.onAuthenticate,
    required this.onShowPermissionHistory,
    required this.onLogout,
  });

  final String agentName;
  final List<AgentServerConfig> agentServers;
  final bool compact;
  final bool canSwitchAgent;
  final ValueChanged<String>? onSelectAgent;
  final VoidCallback? onShowAgentConfig;
  final VoidCallback? onShowProtocolCoverage;
  final VoidCallback? onShowActivity;
  final VoidCallback? onShowRuntimeInventory;
  final VoidCallback? onAuthenticate;
  final VoidCallback? onShowPermissionHistory;
  final VoidCallback? onLogout;

  @override
  Widget build(BuildContext context) {
    final hasMenu =
        agentServers.isNotEmpty ||
        onShowAgentConfig != null ||
        onShowProtocolCoverage != null ||
        onShowActivity != null ||
        onShowRuntimeInventory != null ||
        onAuthenticate != null ||
        onShowPermissionHistory != null ||
        onLogout != null;
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
          case _AgentMenuSelectionType.protocolCoverage:
            onShowProtocolCoverage?.call();
          case _AgentMenuSelectionType.activity:
            onShowActivity?.call();
          case _AgentMenuSelectionType.runtimeInventory:
            onShowRuntimeInventory?.call();
          case _AgentMenuSelectionType.authenticate:
            onAuthenticate?.call();
          case _AgentMenuSelectionType.permissionHistory:
            onShowPermissionHistory?.call();
          case _AgentMenuSelectionType.logout:
            onLogout?.call();
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
                fontWeight: FontWeight.w600,
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
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (onShowProtocolCoverage != null)
            const PopupMenuItem<_AgentMenuSelection>(
              value: _AgentMenuSelection.protocolCoverage(),
              child: Row(
                children: [
                  Icon(
                    Icons.fact_check_outlined,
                    size: 17,
                    color: AppColors.primaryDark,
                  ),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Protocol Coverage',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (onShowActivity != null)
            const PopupMenuItem<_AgentMenuSelection>(
              value: _AgentMenuSelection.activity(),
              child: Row(
                children: [
                  Icon(
                    Icons.timeline_rounded,
                    size: 17,
                    color: AppColors.primaryDark,
                  ),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Session Activity',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (onShowRuntimeInventory != null)
            const PopupMenuItem<_AgentMenuSelection>(
              value: _AgentMenuSelection.runtimeInventory(),
              child: Row(
                children: [
                  Icon(
                    Icons.account_tree_outlined,
                    size: 17,
                    color: AppColors.primaryDark,
                  ),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Runtime Inventory',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (onShowPermissionHistory != null &&
              (agentServers.isNotEmpty ||
                  onShowAgentConfig != null ||
                  onShowProtocolCoverage != null ||
                  onShowActivity != null ||
                  onShowRuntimeInventory != null))
            const PopupMenuDivider(),
          if (onShowPermissionHistory != null)
            const PopupMenuItem<_AgentMenuSelection>(
              value: _AgentMenuSelection.permissionHistory(),
              child: Row(
                children: [
                  Icon(
                    Icons.manage_history_rounded,
                    size: 17,
                    color: AppColors.primaryDark,
                  ),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Permission History',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (onAuthenticate != null &&
              (agentServers.isNotEmpty ||
                  onShowAgentConfig != null ||
                  onShowProtocolCoverage != null ||
                  onShowActivity != null ||
                  onShowRuntimeInventory != null ||
                  onShowPermissionHistory != null))
            const PopupMenuDivider(),
          if (onAuthenticate != null)
            const PopupMenuItem<_AgentMenuSelection>(
              value: _AgentMenuSelection.authenticate(),
              child: Row(
                children: [
                  Icon(
                    Icons.login_rounded,
                    size: 17,
                    color: AppColors.primaryDark,
                  ),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Authenticate',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (onLogout != null &&
              (agentServers.isNotEmpty ||
                  onShowAgentConfig != null ||
                  onShowProtocolCoverage != null ||
                  onShowActivity != null ||
                  onShowRuntimeInventory != null ||
                  onShowPermissionHistory != null ||
                  onAuthenticate != null))
            const PopupMenuDivider(),
          if (onLogout != null)
            const PopupMenuItem<_AgentMenuSelection>(
              value: _AgentMenuSelection.logout(),
              child: Row(
                children: [
                  Icon(Icons.logout_rounded, size: 17, color: AppColors.danger),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Log Out',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppColors.danger,
                        fontWeight: FontWeight.w600,
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

enum _AgentMenuSelectionType {
  agent,
  configure,
  protocolCoverage,
  activity,
  runtimeInventory,
  authenticate,
  permissionHistory,
  logout,
}

class _AgentMenuSelection {
  const _AgentMenuSelection.agent(this.agentName)
    : type = _AgentMenuSelectionType.agent;

  const _AgentMenuSelection.configure()
    : type = _AgentMenuSelectionType.configure,
      agentName = null;

  const _AgentMenuSelection.protocolCoverage()
    : type = _AgentMenuSelectionType.protocolCoverage,
      agentName = null;

  const _AgentMenuSelection.activity()
    : type = _AgentMenuSelectionType.activity,
      agentName = null;

  const _AgentMenuSelection.runtimeInventory()
    : type = _AgentMenuSelectionType.runtimeInventory,
      agentName = null;

  const _AgentMenuSelection.authenticate()
    : type = _AgentMenuSelectionType.authenticate,
      agentName = null;

  const _AgentMenuSelection.permissionHistory()
    : type = _AgentMenuSelectionType.permissionHistory,
      agentName = null;

  const _AgentMenuSelection.logout()
    : type = _AgentMenuSelectionType.logout,
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
          color: AppColors.surfaceMuted,
          borderRadius: BorderRadius.circular(AppRadius.pill),
          border: Border.all(color: AppColors.borderSoft),
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
          Icons.work_outline_rounded,
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
              fontSize: veryCompact ? 14.5 : 15.5,
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
      canFork: canForkSession,
      supportsGitWorktrees: supportsGitWorktrees,
      onSelected: onSelected,
    );
  }
}

class _ToolbarSessionActions extends StatelessWidget {
  const _ToolbarSessionActions({
    required this.label,
    required this.session,
    required this.canFork,
    required this.supportsGitWorktrees,
    required this.onSelected,
  });

  final Widget label;
  final AgentSession session;
  final bool canFork;
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
          menuChildren: [
            _toolbarMenuItem(
              WorkspaceSessionMenuAction.togglePinned,
              session.pinned ? Icons.push_pin : Icons.push_pin_outlined,
              session.pinned ? 'Unpin Conversation' : 'Pin Conversation',
              onSelected,
            ),
            _toolbarMenuItem(
              WorkspaceSessionMenuAction.rename,
              Icons.edit_outlined,
              'Rename Conversation',
              onSelected,
            ),
            _toolbarMenuItem(
              WorkspaceSessionMenuAction.toggleUnread,
              session.unread
                  ? Icons.mark_email_read_outlined
                  : Icons.mark_chat_unread_outlined,
              session.unread ? 'Mark as Read' : 'Mark as Unread',
              onSelected,
            ),
            _toolbarMenuItem(
              WorkspaceSessionMenuAction.archive,
              Icons.archive_outlined,
              'Archive Conversation',
              onSelected,
            ),
            const Divider(height: 9),
            _toolbarMenuItem(
              WorkspaceSessionMenuAction.openSideSession,
              Icons.add_circle_outline_rounded,
              'Open Side Session',
              onSelected,
            ),
            SubmenuButton(
              menuStyle: _toolbarMenuStyle(),
              leadingIcon: const Icon(Icons.copy_all_outlined, size: 17),
              menuChildren: [
                _toolbarMenuItem(
                  WorkspaceSessionMenuAction.copyWorkingDirectory,
                  Icons.folder_copy_outlined,
                  'Copy Working Directory',
                  onSelected,
                ),
                _toolbarMenuItem(
                  WorkspaceSessionMenuAction.copySessionId,
                  Icons.tag_rounded,
                  'Copy Session ID',
                  onSelected,
                ),
                _toolbarMenuItem(
                  WorkspaceSessionMenuAction.copyDeepLink,
                  Icons.link_rounded,
                  'Copy Deep Link',
                  onSelected,
                ),
                _toolbarMenuItem(
                  WorkspaceSessionMenuAction.copyMarkdown,
                  Icons.description_outlined,
                  'Copy as Markdown',
                  onSelected,
                ),
              ],
              child: const Text('Copy'),
            ),
            SubmenuButton(
              menuStyle: _toolbarMenuStyle(),
              leadingIcon: const Icon(Icons.account_tree_outlined, size: 17),
              menuChildren: [
                _toolbarMenuItem(
                  WorkspaceSessionMenuAction.forkLocally,
                  Icons.call_split_rounded,
                  'Continue in New Session',
                  onSelected,
                  enabled: canFork,
                ),
                if (supportsGitWorktrees)
                  _toolbarMenuItem(
                    WorkspaceSessionMenuAction.forkToNewWorktree,
                    Icons.account_tree_outlined,
                    'Continue in New Worktree',
                    onSelected,
                    enabled: canFork,
                  ),
              ],
              child: const Text('Continue in...'),
            ),
            const Divider(height: 9),
            _toolbarMenuItem(
              WorkspaceSessionMenuAction.openInNewWindow,
              Icons.open_in_new_rounded,
              'Open in New Window',
              onSelected,
            ),
          ],
          builder: (context, controller, child) {
            return Tooltip(
              message: 'Session actions',
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
}) {
  final color = enabled ? AppColors.textPrimary : AppColors.textTertiary;
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
        borderRadius: BorderRadius.circular(AppRadius.pill),
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
        borderRadius: BorderRadius.circular(AppRadius.pill),
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
            borderRadius: BorderRadius.circular(AppRadius.pill),
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
    final style = FilledButton.styleFrom(
      foregroundColor: AppColors.textPrimary,
      disabledForegroundColor: AppColors.textTertiary,
      backgroundColor: AppColors.surfaceMuted,
      disabledBackgroundColor: AppColors.surfaceRaised,
      elevation: 0,
      minimumSize: Size(compact ? 34 : 108, 34),
      padding: compact
          ? EdgeInsets.zero
          : const EdgeInsets.symmetric(horizontal: 12),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.standard,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        side: const BorderSide(color: AppColors.border),
      ),
    );

    final button = compact
        ? FilledButton(
            onPressed: onPressed,
            style: style,
            child: const Icon(Icons.add_rounded, size: 18),
          )
        : FilledButton.icon(
            onPressed: onPressed,
            style: style,
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text(
              'New Session',
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
        borderRadius: BorderRadius.circular(AppRadius.pill),
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
