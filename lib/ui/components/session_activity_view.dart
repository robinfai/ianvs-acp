import 'package:ianvs_design/ianvs_design.dart';

import '../../state/chat_controller.dart';
import '../activity/session_activity_model.dart';

class SessionActivityView extends StatefulWidget {
  const SessionActivityView({
    super.key,
    required this.controller,
    this.maxEntries = 1000,
  });

  final ChatController controller;
  final int maxEntries;

  @override
  State<SessionActivityView> createState() => _SessionActivityViewState();
}

class _SessionActivityViewState extends State<SessionActivityView> {
  final SessionActivityProjectionCache _projectionCache =
      SessionActivityProjectionCache();

  @override
  void didUpdateWidget(SessionActivityView oldWidget) {
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
        return Column(
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
        color: context.ianvs.chrome,
        borderRadius: BorderRadius.circular(context.ianvs.panelRadius),
        border: Border.all(color: context.ianvs.separator, width: .75),
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
        color: context.ianvs.canvas,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: context.ianvs.muted),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              color: context.ianvs.muted,
              fontSize: 12,
              fontWeight: FontWeight.w400,
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
                    color: _activityColor(
                      context,
                      entry.kind,
                    ).withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    _activityIcon(entry.kind),
                    size: 15,
                    color: _activityColor(context, entry.kind),
                  ),
                ),
                if (!isLast)
                  Container(
                    width: 1,
                    height: 38,
                    color: context.ianvs.separator,
                  ),
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
                          style: TextStyle(
                            color: context.ianvs.text,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Text(
                        _timeLabel(entry.timestamp),
                        style: TextStyle(
                          color: context.ianvs.subtle,
                          fontSize: 11,
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
                      style: TextStyle(
                        color: context.ianvs.muted,
                        fontSize: 11.5,
                        height: 1.3,
                      ),
                    ),
                  ],
                  if (activityMetadata.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      activityMetadata.join(' · '),
                      style: TextStyle(
                        color: context.ianvs.subtle,
                        fontSize: 11,
                        fontWeight: FontWeight.w400,
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
    return Center(
      child: Text(
        'No activity has been recorded for this session.',
        style: TextStyle(color: context.ianvs.muted),
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

Color _activityColor(BuildContext context, SessionActivityKind kind) =>
    switch (kind) {
      SessionActivityKind.prompt => context.ianvs.focus,
      SessionActivityKind.response => context.ianvs.success,
      SessionActivityKind.tool => context.ianvs.accent,
      SessionActivityKind.status => context.ianvs.muted,
      SessionActivityKind.permission => context.ianvs.warning,
      SessionActivityKind.error => context.ianvs.danger,
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
