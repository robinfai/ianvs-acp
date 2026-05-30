import 'package:flutter/material.dart';

import '../../state/chat_controller.dart';
import '../../state/connection_state.dart' as app_state;
import '../theme/app_design_tokens.dart';

class StatusBar extends StatelessWidget {
  const StatusBar({
    super.key,
    required this.controller,
    required this.onShowCapabilities,
    required this.onShowSessionSettings,
  });

  final ChatController controller;
  final VoidCallback onShowCapabilities;
  final VoidCallback onShowSessionSettings;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 30,
      decoration: const BoxDecoration(
        color: AppColors.bg,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          return Align(
            alignment: Alignment.centerRight,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              reverse: true,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _StatusItem(
                    icon: Icons.folder_open_outlined,
                    label: controller.cwd,
                    maxWidth: constraints.maxWidth < 960 ? 220 : 320,
                  ),
                  const SizedBox(width: 14),
                  _StatusItem(
                    icon: Icons.tag_rounded,
                    label: controller.currentSession?.shortId ?? 'no session',
                  ),
                  if (_currentModeLabel(controller) != null) ...[
                    const SizedBox(width: 14),
                    _StatusItem(
                      icon: Icons.swap_horiz_rounded,
                      label: _currentModeLabel(controller)!,
                      color: AppColors.primaryDark,
                    ),
                  ],
                  const SizedBox(width: 14),
                  _StatusItem(
                    icon: Icons.radio_button_checked,
                    label: controller.status.label,
                    color: _statusColor(controller.status),
                  ),
                  const SizedBox(width: 14),
                  _StatusItem(
                    icon: Icons.bolt_outlined,
                    label: controller.isStreaming ? 'streaming' : 'idle',
                  ),
                  const SizedBox(width: 14),
                  _StatusItem(
                    icon: Icons.timer_outlined,
                    label: _latencyLabel(controller.lastLatency),
                  ),
                  if (controller.lastError != null) ...[
                    const SizedBox(width: 14),
                    _StatusItem(
                      icon: Icons.error_outline,
                      label: controller.lastError!,
                      color: AppColors.danger,
                      maxWidth: 320,
                    ),
                  ],
                  const SizedBox(width: 14),
                  _StatusIcon(
                    icon: Icons.tune_rounded,
                    tooltip: 'Session settings',
                    onPressed: onShowSessionSettings,
                  ),
                  const SizedBox(width: 8),
                  _StatusIcon(
                    icon: Icons.fact_check_outlined,
                    tooltip: 'ACP compatibility',
                    onPressed: onShowCapabilities,
                  ),
                  const SizedBox(width: 8),
                  const _StatusIcon(
                    icon: Icons.wb_sunny_outlined,
                    tooltip: 'Theme',
                    onPressed: null,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Color _statusColor(app_state.ConnectionStatus status) => switch (status) {
    app_state.ConnectionStatus.connected ||
    app_state.ConnectionStatus.sessionReady => AppColors.success,
    app_state.ConnectionStatus.connecting ||
    app_state.ConnectionStatus.reconnecting ||
    app_state.ConnectionStatus.streaming => AppColors.primaryDark,
    app_state.ConnectionStatus.error => AppColors.danger,
    app_state.ConnectionStatus.disconnected => AppColors.textSecondary,
  };

  String _latencyLabel(Duration? latency) {
    if (latency == null) return 'latency --';
    return 'latency ${latency.inMilliseconds} ms';
  }

  String? _currentModeLabel(ChatController controller) {
    final modeId = controller.sessionSettings.modes.currentModeId;
    if (modeId == null || modeId.isEmpty) return null;
    for (final mode in controller.sessionSettings.modes.availableModes) {
      if (mode.id == modeId) {
        return 'mode ${mode.label}';
      }
    }
    return 'mode $modeId';
  }
}

class _StatusItem extends StatelessWidget {
  const _StatusItem({
    required this.icon,
    required this.label,
    this.color = AppColors.textSecondary,
    this.maxWidth,
  });

  final IconData icon;
  final String label;
  final Color color;
  final double? maxWidth;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth ?? double.infinity),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: color,
                fontSize: 11,
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

class _StatusIcon extends StatelessWidget {
  const _StatusIcon({
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
          child: SizedBox(
            width: 24,
            height: 24,
            child: Icon(
              icon,
              size: 15,
              color: onPressed == null
                  ? AppColors.textTertiary
                  : AppColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}
