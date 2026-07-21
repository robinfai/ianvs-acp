import 'package:flutter/material.dart';

import '../../acp/agent_session.dart';
import '../../workspace/workspace.dart';
import '../theme/app_design_tokens.dart';

class WorkspaceHeader extends StatelessWidget {
  const WorkspaceHeader({
    super.key,
    required this.workspace,
    required this.agentName,
    required this.currentSession,
  });

  final WorkspaceRecord workspace;
  final String agentName;
  final AgentSession? currentSession;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.surface,
      padding: const EdgeInsets.fromLTRB(8, 7, 8, 7),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 620;
          final workspaceSurface = _WorkspaceHeaderSurface(
            key: const Key('workspace-header-workspace-surface'),
            icon: Icons.folder_open_rounded,
            accent: AppColors.primary,
            title: workspace.name,
            detail: workspace.path,
            trailing: _HeaderPill(
              icon: Icons.forum_outlined,
              label:
                  '${workspace.sessionCount} ${workspace.sessionCount == 1 ? 'session' : 'sessions'}',
            ),
          );
          final sessionSurface = _WorkspaceHeaderSurface(
            key: const Key('workspace-header-session-surface'),
            icon: currentSession == null
                ? Icons.chat_bubble_outline_rounded
                : Icons.bolt_rounded,
            accent: currentSession == null
                ? AppColors.textTertiary
                : AppColors.primaryDark,
            title: _sessionTitle(),
            detail: _sessionDetail(),
            trailing: compact
                ? null
                : _HeaderPill(icon: Icons.smart_toy_outlined, label: agentName),
          );

          if (compact) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                workspaceSurface,
                const SizedBox(height: 6),
                sessionSurface,
              ],
            );
          }

          return Row(
            children: [
              Expanded(flex: 6, child: workspaceSurface),
              const SizedBox(width: 7),
              Expanded(flex: 5, child: sessionSurface),
            ],
          );
        },
      ),
    );
  }

  String _sessionTitle() {
    final session = currentSession;
    if (session == null) return 'No active session';
    final title = session.displayTitle.trim();
    return title.isEmpty ? session.shortId : title;
  }

  String _sessionDetail() {
    final session = currentSession;
    if (session == null) return workspace.path;
    final agent = session.agentName?.trim();
    final shortId = session.shortId;
    if (agent == null || agent.isEmpty) return shortId;
    return '$agent / $shortId';
  }
}

class _WorkspaceHeaderSurface extends StatelessWidget {
  const _WorkspaceHeaderSurface({
    super.key,
    required this.icon,
    required this.accent,
    required this.title,
    required this.detail,
    this.trailing,
  });

  final IconData icon;
  final Color accent;
  final String title;
  final String detail;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 40),
      padding: const EdgeInsets.fromLTRB(7, 5, 7, 5),
      decoration: BoxDecoration(
        color: AppColors.surfaceRaised,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: AppColors.borderSoft),
      ),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 28,
            decoration: BoxDecoration(
              color: accent,
              borderRadius: BorderRadius.circular(AppRadius.pill),
            ),
          ),
          const SizedBox(width: 7),
          Icon(icon, size: 15, color: accent),
          const SizedBox(width: 7),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0,
                    height: 1.1,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  detail,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 10.5,
                    height: 1.15,
                  ),
                ),
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 7), trailing!],
        ],
      ),
    );
  }
}

class _HeaderPill extends StatelessWidget {
  const _HeaderPill({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 22,
      constraints: const BoxConstraints(maxWidth: 124),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: AppColors.surfaceRaised,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: AppColors.borderSoft),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: AppColors.textSecondary),
          const SizedBox(width: 3),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 10.5,
                fontWeight: FontWeight.w800,
                letterSpacing: 0,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
