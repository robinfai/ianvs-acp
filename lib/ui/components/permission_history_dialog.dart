import 'package:flutter/material.dart';

import '../../acp/acp_permission_request.dart';
import '../theme/app_design_tokens.dart';

class PermissionHistoryDialog extends StatelessWidget {
  const PermissionHistoryDialog({super.key, required this.entries});

  final List<AcpPermissionAuditEntry> entries;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Permission History'),
      content: SizedBox(
        width: 680,
        child: entries.isEmpty
            ? const Text('No permission requests yet.')
            : ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 460),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: entries.length,
                  separatorBuilder: (context, index) =>
                      const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    return _PermissionHistoryRow(entry: entries[index]);
                  },
                ),
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _PermissionHistoryRow extends StatelessWidget {
  const _PermissionHistoryRow({required this.entry});

  final AcpPermissionAuditEntry entry;

  @override
  Widget build(BuildContext context) {
    final request = entry.request;
    final statusColor = _statusColor(entry.status);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: AppColors.border),
        color: AppColors.surface,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(_statusIcon(entry.status), color: statusColor, size: 17),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  request.displayTitle,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                entry.displayStatus,
                style: TextStyle(
                  color: statusColor,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            request.displayRationale,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 0,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _MetaChip(
                icon: Icons.build_circle_outlined,
                label: request.displayKind,
              ),
              _MetaChip(
                icon: Icons.folder_copy_outlined,
                label: request.sessionId,
              ),
              _MetaChip(
                icon: Icons.schedule_rounded,
                label: _formatTimestamp(entry.recordedAt),
              ),
              if (entry.resolvedAt != null)
                _MetaChip(
                  icon: Icons.done_all_rounded,
                  label: _formatTimestamp(entry.resolvedAt!),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MetaChip extends StatelessWidget {
  const _MetaChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.surfaceRaised,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: AppColors.textTertiary),
          const SizedBox(width: 4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 220),
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

IconData _statusIcon(AcpPermissionAuditStatus status) {
  return switch (status) {
    AcpPermissionAuditStatus.pending => Icons.hourglass_top_rounded,
    AcpPermissionAuditStatus.allowed => Icons.check_circle_outline_rounded,
    AcpPermissionAuditStatus.denied => Icons.block_rounded,
    AcpPermissionAuditStatus.cancelled => Icons.cancel_outlined,
  };
}

Color _statusColor(AcpPermissionAuditStatus status) {
  return switch (status) {
    AcpPermissionAuditStatus.pending => AppColors.warning,
    AcpPermissionAuditStatus.allowed => AppColors.success,
    AcpPermissionAuditStatus.denied => AppColors.danger,
    AcpPermissionAuditStatus.cancelled => AppColors.textTertiary,
  };
}

String _formatTimestamp(DateTime value) {
  final local = value.toLocal();
  return '${local.year.toString().padLeft(4, '0')}-'
      '${local.month.toString().padLeft(2, '0')}-'
      '${local.day.toString().padLeft(2, '0')} '
      '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
}
