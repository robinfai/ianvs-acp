import 'package:flutter/material.dart';

import '../../state/chat_controller.dart';
import '../activity/session_activity_model.dart';
import '../theme/app_design_tokens.dart';

class SessionActivityDialog extends StatefulWidget {
  const SessionActivityDialog({
    super.key,
    required this.controller,
    this.maxEntries = 1000,
  });

  final ChatController controller;
  final int maxEntries;

  @override
  State<SessionActivityDialog> createState() => _SessionActivityDialogState();
}

class _SessionActivityDialogState extends State<SessionActivityDialog> {
  final SessionActivityProjectionCache _projectionCache =
      SessionActivityProjectionCache();

  @override
  void didUpdateWidget(SessionActivityDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.controller, oldWidget.controller)) {
      _projectionCache.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final snapshot = SessionActivitySnapshot.fromController(
          widget.controller,
          projectionCache: _projectionCache,
          maxEntries: widget.maxEntries,
        );
        return AlertDialog(
          title: const Text('Session Activity'),
          content: SizedBox(
            width: 760,
            height: 600,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _ActivitySummary(snapshot: snapshot),
                const SizedBox(height: 12),
                Expanded(
                  child: snapshot.entries.isEmpty
                      ? const _EmptyActivity()
                      : ListView.separated(
                          key: const ValueKey('session-activity-list'),
                          itemCount: snapshot.entries.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 6),
                          itemBuilder: (context, index) => _ActivityRow(
                            entry: snapshot.entries[index],
                            isLast: index == snapshot.entries.length - 1,
                          ),
                        ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }
}

class _ActivitySummary extends StatelessWidget {
  const _ActivitySummary({required this.snapshot});

  final SessionActivitySnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.primaryMist,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.borderSoft),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _SummaryChip(
            icon: Icons.timeline_rounded,
            label: snapshot.truncated
                ? 'Latest ${snapshot.entries.length} events'
                : '${snapshot.entries.length} events',
          ),
          _SummaryChip(
            icon: Icons.build_outlined,
            label: '${snapshot.toolCount} tools',
          ),
          _SummaryChip(
            icon: Icons.shield_outlined,
            label: '${snapshot.permissionCount} permissions',
          ),
          if (snapshot.lastLatency != null)
            _SummaryChip(
              icon: Icons.timer_outlined,
              label: 'Last ${_durationLabel(snapshot.lastLatency!)}',
            ),
          if (snapshot.sessionTemplateIdentity != null)
            _SummaryChip(
              icon: Icons.dashboard_customize_outlined,
              label: snapshot.sessionTemplateIdentity!,
            ),
        ],
      ),
    );
  }
}

class _SummaryChip extends StatelessWidget {
  const _SummaryChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: AppColors.borderSoft),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: AppColors.primaryDark),
          const SizedBox(width: 5),
          Text(
            label,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _ActivityRow extends StatelessWidget {
  const _ActivityRow({required this.entry, required this.isLast});

  final SessionActivityEntry entry;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final status = entry.status?.trim();
    final activityMetadata = <String>[
      if (status != null && status.isNotEmpty) status,
      if (entry.turnId != null) 'turn ${entry.turnId}',
      if (entry.elapsed != null) _durationLabel(entry.elapsed!),
    ];
    final semanticsLabel = <String>[
      entry.title,
      if (entry.detail.trim().isNotEmpty) entry.detail,
      ...activityMetadata,
    ].join(' ');
    return Semantics(
      label: semanticsLabel,
      excludeSemantics: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 34,
            child: Column(
              children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: _activityColor(entry.kind).withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    _activityIcon(entry.kind),
                    size: 15,
                    color: _activityColor(entry.kind),
                  ),
                ),
                if (!isLast)
                  Container(width: 1, height: 38, color: AppColors.borderSoft),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          entry.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Text(
                        _timeLabel(entry.timestamp),
                        style: const TextStyle(
                          color: AppColors.textTertiary,
                          fontSize: 10.5,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                  if (entry.detail.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      entry.detail,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 11.5,
                        height: 1.3,
                      ),
                    ),
                  ],
                  if (activityMetadata.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      activityMetadata.join(' · '),
                      style: const TextStyle(
                        color: AppColors.textTertiary,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyActivity extends StatelessWidget {
  const _EmptyActivity();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Text(
        'No activity has been recorded for this session.',
        style: TextStyle(color: AppColors.textSecondary),
      ),
    );
  }
}

IconData _activityIcon(SessionActivityKind kind) => switch (kind) {
  SessionActivityKind.prompt => Icons.person_outline_rounded,
  SessionActivityKind.response => Icons.smart_toy_outlined,
  SessionActivityKind.tool => Icons.build_outlined,
  SessionActivityKind.status => Icons.info_outline_rounded,
  SessionActivityKind.permission => Icons.shield_outlined,
  SessionActivityKind.error => Icons.error_outline_rounded,
};

Color _activityColor(SessionActivityKind kind) => switch (kind) {
  SessionActivityKind.prompt => AppColors.primaryDark,
  SessionActivityKind.response => AppColors.success,
  SessionActivityKind.tool => AppColors.primary,
  SessionActivityKind.status => AppColors.textSecondary,
  SessionActivityKind.permission => AppColors.warning,
  SessionActivityKind.error => AppColors.danger,
};

String _timeLabel(DateTime value) {
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
}

String _durationLabel(Duration value) {
  if (value.inMilliseconds < 1000) return '${value.inMilliseconds}ms';
  if (value.inSeconds < 60) {
    return '${(value.inMilliseconds / 1000).toStringAsFixed(1)}s';
  }
  return '${value.inMinutes}m ${value.inSeconds % 60}s';
}
