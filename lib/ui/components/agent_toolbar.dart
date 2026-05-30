import 'package:flutter/material.dart';

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
  });

  final String agentName;
  final app_state.ConnectionStatus status;
  final VoidCallback onNewSession;
  final VoidCallback onResumeSession;
  final VoidCallback onReconnect;

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
  final VoidCallback onPressed;

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
              Icon(icon, color: AppColors.primaryDark, size: 18),
              if (label != null) ...[
                const SizedBox(width: 5),
                Text(
                  label!,
                  style: const TextStyle(
                    color: AppColors.primaryDark,
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
      label: tooltip,
      child: Tooltip(message: tooltip, child: content),
    );
  }
}

class _PrimaryToolbarAction extends StatelessWidget {
  const _PrimaryToolbarAction({required this.compact, required this.onPressed});

  final bool compact;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final content = DecoratedBox(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [AppColors.primary, AppColors.primaryDark],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(AppRadius.pill),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withValues(alpha: 0.22),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.pill),
          onTap: onPressed,
          child: SizedBox(
            width: compact ? 38 : null,
            height: 38,
            child: Padding(
              padding: compact
                  ? EdgeInsets.zero
                  : const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.add_rounded, color: Colors.white, size: 20),
                  if (!compact) ...[
                    const SizedBox(width: 6),
                    const Text(
                      'New Session',
                      style: TextStyle(
                        color: Colors.white,
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
        ),
      ),
    );

    return Semantics(
      button: true,
      label: 'New Session',
      child: Tooltip(message: 'New Session', child: content),
    );
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
