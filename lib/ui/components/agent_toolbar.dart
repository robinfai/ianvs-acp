import 'package:flutter/material.dart';

import '../../state/connection_state.dart' as app_state;
import '../theme/app_design_tokens.dart';

class AgentToolbar extends StatelessWidget {
  const AgentToolbar({
    super.key,
    required this.status,
    required this.onNewSession,
    required this.onResumeSession,
    required this.onReconnect,
  });

  final app_state.ConnectionStatus status;
  final VoidCallback onNewSession;
  final VoidCallback onResumeSession;
  final VoidCallback onReconnect;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 92,
      padding: const EdgeInsets.fromLTRB(32, 18, 32, 16),
      decoration: const BoxDecoration(color: AppColors.bg),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 980;
          final actions = [
            _ToolbarAction(
              icon: Icons.play_circle_outline,
              label: 'Resume',
              onPressed: onResumeSession,
            ),
            const SizedBox(width: 12),
            _ToolbarAction(
              icon: Icons.refresh_rounded,
              label: 'Reconnect',
              onPressed: onReconnect,
            ),
            const SizedBox(width: 18),
            _PrimaryToolbarAction(onPressed: onNewSession),
          ];

          final row = Row(
            mainAxisSize: wide ? MainAxisSize.max : MainAxisSize.min,
            children: [
              _BrandMark(status: status),
              if (wide) const Spacer() else const SizedBox(width: 28),
              ...actions,
            ],
          );

          if (wide) return row;

          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: row,
          );
        },
      ),
    );
  }
}

class _BrandMark extends StatelessWidget {
  const _BrandMark({required this.status});

  final app_state.ConnectionStatus status;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: AppColors.primarySoft,
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          child: const Icon(
            Icons.hub_outlined,
            color: AppColors.primary,
            size: 28,
          ),
        ),
        const SizedBox(width: 14),
        const Text(
          'ACP Client',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 24,
            fontWeight: FontWeight.w800,
            letterSpacing: 0,
          ),
        ),
        const SizedBox(width: 22),
        const _AgentChip(),
        const SizedBox(width: 14),
        _ConnectionBadge(status: status),
      ],
    );
  }
}

class _AgentChip extends StatelessWidget {
  const _AgentChip();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 18),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppColors.primarySoft,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.08)),
      ),
      child: const Text(
        'Codex',
        style: TextStyle(
          color: AppColors.primaryDark,
          fontWeight: FontWeight.w800,
          fontSize: 15,
        ),
      ),
    );
  }
}

class _ToolbarAction extends StatelessWidget {
  const _ToolbarAction({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.pill),
        onTap: onPressed,
        child: Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: AppColors.primaryDark, size: 25),
              const SizedBox(width: 8),
              Text(
                label,
                style: const TextStyle(
                  color: AppColors.primaryDark,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PrimaryToolbarAction extends StatelessWidget {
  const _PrimaryToolbarAction({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
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
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.pill),
          onTap: onPressed,
          child: const SizedBox(
            height: 52,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.add_rounded, color: Colors.white, size: 28),
                  SizedBox(width: 10),
                  Text(
                    'New Session',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
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
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 7),
          Text(
            status.label,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w800,
              fontSize: 15,
            ),
          ),
        ],
      ),
    );
  }
}
