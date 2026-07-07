import 'package:flutter/material.dart';

import '../../tasks/task_record.dart';
import '../theme/app_design_tokens.dart';

class TaskStatusBadge extends StatelessWidget {
  const TaskStatusBadge({super.key, required this.status});

  final TaskStatus status;

  @override
  Widget build(BuildContext context) {
    final colors = _colors(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: colors.border),
      ),
      child: Text(
        _label(status),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: colors.foreground,
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: 0,
        ),
      ),
    );
  }

  static String _label(TaskStatus status) {
    return switch (status) {
      TaskStatus.inbox => 'Inbox',
      TaskStatus.queued => 'Queued',
      TaskStatus.running => 'Running',
      TaskStatus.blockedOnPermission => 'Blocked',
      TaskStatus.blockedOnUserInput => 'Blocked',
      TaskStatus.collectingArtifacts => 'Collecting',
      TaskStatus.needsHumanReview => 'Review',
      TaskStatus.approvedForExport => 'Approved',
      TaskStatus.exporting => 'Exporting',
      TaskStatus.done => 'Done',
      TaskStatus.failed => 'Failed',
      TaskStatus.cancelled => 'Cancelled',
      TaskStatus.rejected => 'Rejected',
      TaskStatus.needsChanges => 'Changes',
    };
  }

  static _BadgeColors _colors(TaskStatus status) {
    return switch (status) {
      TaskStatus.running ||
      TaskStatus.queued ||
      TaskStatus.collectingArtifacts ||
      TaskStatus.exporting => const _BadgeColors(
        background: Color(0xffe0f2fe),
        border: Color(0xffbae6fd),
        foreground: Color(0xff0369a1),
      ),
      TaskStatus.needsHumanReview ||
      TaskStatus.approvedForExport => const _BadgeColors(
        background: Color(0xfffff7ed),
        border: Color(0xffffd7aa),
        foreground: AppColors.warning,
      ),
      TaskStatus.blockedOnPermission ||
      TaskStatus.blockedOnUserInput ||
      TaskStatus.failed => const _BadgeColors(
        background: Color(0xfffef2f2),
        border: Color(0xfffecaca),
        foreground: AppColors.danger,
      ),
      TaskStatus.done => const _BadgeColors(
        background: Color(0xffecfdf3),
        border: Color(0xffbbf7d0),
        foreground: AppColors.success,
      ),
      TaskStatus.cancelled || TaskStatus.rejected => const _BadgeColors(
        background: AppColors.disabled,
        border: Color(0xffd1d5db),
        foreground: AppColors.textSecondary,
      ),
      TaskStatus.inbox || TaskStatus.needsChanges => const _BadgeColors(
        background: AppColors.primaryMist,
        border: AppColors.primarySoft,
        foreground: AppColors.primaryDark,
      ),
    };
  }
}

class _BadgeColors {
  const _BadgeColors({
    required this.background,
    required this.border,
    required this.foreground,
  });

  final Color background;
  final Color border;
  final Color foreground;
}
