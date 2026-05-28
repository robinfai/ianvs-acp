import 'package:flutter/material.dart';

import '../../acp/agent_session.dart';
import '../theme/app_design_tokens.dart';

class SessionSidebar extends StatelessWidget {
  const SessionSidebar({
    super.key,
    required this.sessions,
    required this.currentSession,
    required this.onNewSession,
  });

  final List<AgentSession> sessions;
  final AgentSession? currentSession;
  final VoidCallback onNewSession;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.surfaceRaised,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 22, 18, 12),
            child: Row(
              children: [
                Text(
                  'Sessions',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: AppColors.textPrimary,
                    letterSpacing: 0,
                  ),
                ),
                const Spacer(),
                _IconShell(
                  icon: Icons.tune_rounded,
                  tooltip: 'Session filters',
                  onPressed: () {},
                ),
              ],
            ),
          ),
          Expanded(
            child: sessions.isEmpty
                ? _EmptySessions(onNewSession: onNewSession)
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(14, 4, 14, 18),
                    itemBuilder: (context, index) {
                      final session = sessions[index];
                      return _SessionTile(
                        session: session,
                        selected: session.id == currentSession?.id,
                      );
                    },
                    separatorBuilder: (context, index) =>
                        const SizedBox(height: 8),
                    itemCount: sessions.length,
                  ),
          ),
        ],
      ),
    );
  }
}

class _EmptySessions extends StatelessWidget {
  const _EmptySessions({required this.onNewSession});

  final VoidCallback onNewSession;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxHeight < 360;
        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(24, compact ? 10 : 12, 24, 28),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: constraints.maxHeight > 28
                  ? constraints.maxHeight - 28
                  : 0,
            ),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _ChatIllustration(size: compact ? 82 : 118),
                  SizedBox(height: compact ? 12 : 18),
                  Text(
                    'No sessions yet',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: compact ? 19 : 22,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0,
                    ),
                  ),
                  SizedBox(height: compact ? 5 : 8),
                  Text(
                    'Start a new session to chat\nwith Codex.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: compact ? 14 : 16,
                      height: 1.35,
                    ),
                  ),
                  SizedBox(height: compact ? 18 : 28),
                  OutlinedButton.icon(
                    onPressed: onNewSession,
                    icon: const Icon(Icons.add_rounded, size: 24),
                    label: const Text('New Session'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.primaryDark,
                      minimumSize: Size(196, compact ? 50 : 58),
                      side: const BorderSide(color: Color(0xffd8c8ff)),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppRadius.pill),
                      ),
                      textStyle: TextStyle(
                        fontSize: compact ? 16 : 18,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SessionTile extends StatelessWidget {
  const _SessionTile({required this.session, required this.selected});

  final AgentSession session;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: selected ? AppColors.primaryMist : AppColors.surface,
        border: Border.all(
          color: selected
              ? AppColors.primary.withValues(alpha: 0.22)
              : AppColors.borderSoft,
        ),
        borderRadius: BorderRadius.circular(AppRadius.md),
        boxShadow: selected ? AppShadows.soft : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: selected
                      ? AppColors.primarySoft
                      : AppColors.surfaceRaised,
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: Icon(
                  Icons.chat_bubble_outline_rounded,
                  size: 16,
                  color: selected
                      ? AppColors.primaryDark
                      : AppColors.textSecondary,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  session.shortId,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            session.cwd,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              const Icon(
                Icons.access_time_rounded,
                size: 13,
                color: AppColors.textTertiary,
              ),
              const SizedBox(width: 5),
              Text(
                _formatCreatedAt(session.createdAt),
                style: const TextStyle(
                  color: AppColors.textTertiary,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _formatCreatedAt(DateTime createdAt) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${createdAt.year}-${two(createdAt.month)}-${two(createdAt.day)} '
        '${two(createdAt.hour)}:${two(createdAt.minute)}';
  }
}

class _IconShell extends StatelessWidget {
  const _IconShell({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        onTap: onPressed,
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(AppRadius.sm),
            border: Border.all(color: AppColors.border),
          ),
          child: Icon(icon, color: AppColors.textSecondary, size: 22),
        ),
      ),
    );
  }
}

class _ChatIllustration extends StatelessWidget {
  const _ChatIllustration({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: size,
            height: size,
            decoration: const BoxDecoration(
              color: AppColors.primaryMist,
              shape: BoxShape.circle,
            ),
          ),
          Positioned(
            left: size * 0.18,
            top: size * 0.32,
            child: _Bubble(
              width: size * 0.56,
              height: size * 0.38,
              color: AppColors.surface,
              borderColor: Color(0xffbba2ff),
              tailLeft: true,
            ),
          ),
          Positioned(
            right: size * 0.16,
            top: size * 0.42,
            child: _Bubble(
              width: size * 0.42,
              height: size * 0.34,
              color: const Color(0xffaa8cff),
              borderColor: Color(0xffaa8cff),
              tailLeft: false,
            ),
          ),
          Positioned(
            left: size * 0.02,
            top: size * 0.18,
            child: const _TinyDiamond(),
          ),
          Positioned(
            right: size * 0.02,
            bottom: size * 0.22,
            child: const _TinyDiamond(),
          ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.width,
    required this.height,
    required this.color,
    required this.borderColor,
    required this.tailLeft,
  });

  final double width;
  final double height;
  final Color color;
  final Color borderColor;
  final bool tailLeft;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _BubbleTailPainter(
        color: color,
        borderColor: borderColor,
        tailLeft: tailLeft,
      ),
      child: SizedBox(
        width: width,
        height: height,
        child: Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: List.generate(
                3,
                (index) => Container(
                  width: 7,
                  height: 7,
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  decoration: BoxDecoration(
                    color: tailLeft
                        ? const Color(0xffbba2ff)
                        : Colors.white.withValues(alpha: 0.8),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BubbleTailPainter extends CustomPainter {
  const _BubbleTailPainter({
    required this.color,
    required this.borderColor,
    required this.tailLeft,
  });

  final Color color;
  final Color borderColor;
  final bool tailLeft;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & Size(size.width, size.height - 10);
    final radius = Radius.circular(AppRadius.md);
    final path = Path()..addRRect(RRect.fromRectAndRadius(rect, radius));
    final tailX = tailLeft ? size.width * 0.18 : size.width * 0.72;
    path
      ..moveTo(tailX, size.height - 11)
      ..lineTo(tailX + (tailLeft ? -8 : 8), size.height)
      ..lineTo(tailX + (tailLeft ? 12 : -12), size.height - 11)
      ..close();

    canvas.drawPath(path, Paint()..color = color);
    canvas.drawPath(
      path,
      Paint()
        ..color = borderColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(covariant _BubbleTailPainter oldDelegate) {
    return color != oldDelegate.color ||
        borderColor != oldDelegate.borderColor ||
        tailLeft != oldDelegate.tailLeft;
  }
}

class _TinyDiamond extends StatelessWidget {
  const _TinyDiamond();

  @override
  Widget build(BuildContext context) {
    return Transform.rotate(
      angle: 0.78,
      child: Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          border: Border.all(color: const Color(0xffc6b4ff), width: 1.5),
        ),
      ),
    );
  }
}
