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
    required this.onNewSession,
    required this.onResumeSession,
  });

  final WorkspaceRecord workspace;
  final String agentName;
  final AgentSession? currentSession;
  final VoidCallback? onNewSession;
  final VoidCallback? onResumeSession;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.surface,
      padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 620;
          return Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: AppColors.primarySoft,
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: const Icon(
                  Icons.folder_open_rounded,
                  color: AppColors.primaryDark,
                  size: 18,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            workspace.name,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 15,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 0,
                            ),
                          ),
                        ),
                        if (!compact) ...[
                          const SizedBox(width: 8),
                          _HeaderPill(
                            icon: Icons.smart_toy_outlined,
                            label: agentName,
                          ),
                          const SizedBox(width: 6),
                          _HeaderPill(
                            icon: Icons.forum_outlined,
                            label:
                                '${workspace.sessionCount} ${workspace.sessionCount == 1 ? 'session' : 'sessions'}',
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      _subtitle(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                        height: 1.25,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              _HeaderIconButton(
                icon: Icons.history_rounded,
                tooltip: 'Resume session',
                onPressed: onResumeSession,
              ),
              const SizedBox(width: 6),
              compact
                  ? _HeaderIconButton(
                      icon: Icons.add_rounded,
                      tooltip: 'New session',
                      onPressed: onNewSession,
                    )
                  : FilledButton.icon(
                      onPressed: onNewSession,
                      icon: const Icon(Icons.add_rounded, size: 17),
                      label: const Text('New Session'),
                      style: FilledButton.styleFrom(
                        foregroundColor: AppColors.primaryDark,
                        backgroundColor: AppColors.primarySoft,
                        elevation: 0,
                        minimumSize: const Size(128, 34),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(AppRadius.pill),
                        ),
                        textStyle: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0,
                        ),
                      ),
                    ),
            ],
          );
        },
      ),
    );
  }

  String _subtitle() {
    final session = currentSession;
    if (session == null) return workspace.path;
    final title = session.displayTitle.trim();
    if (title.isEmpty) return workspace.path;
    return '$title - ${workspace.path}';
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
      constraints: const BoxConstraints(maxWidth: 140),
      padding: const EdgeInsets.symmetric(horizontal: 7),
      decoration: BoxDecoration(
        color: AppColors.surfaceRaised,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: AppColors.borderSoft),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: AppColors.textSecondary),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 11,
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

class _HeaderIconButton extends StatelessWidget {
  const _HeaderIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: onPressed != null,
      label: tooltip,
      child: Tooltip(
        message: tooltip,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.sm),
          onTap: onPressed,
          child: Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: AppColors.surfaceRaised,
              borderRadius: BorderRadius.circular(AppRadius.sm),
              border: Border.all(color: AppColors.border),
            ),
            child: Icon(
              icon,
              color: onPressed == null
                  ? AppColors.textTertiary
                  : AppColors.textSecondary,
              size: 17,
            ),
          ),
        ),
      ),
    );
  }
}
