import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:ianvs_design/ianvs_design.dart';

import '../../acp/acp_permission_request.dart';

typedef PermissionHistoryExporter =
    Future<String?> Function(String fileName, String json);

class PermissionHistoryView extends StatefulWidget {
  const PermissionHistoryView({
    super.key,
    required this.entries,
    this.exporter,
  });
  final List<AcpPermissionAuditEntry> entries;
  final PermissionHistoryExporter? exporter;
  @override
  State<PermissionHistoryView> createState() => _PermissionHistoryViewState();
}

class _PermissionHistoryViewState extends State<PermissionHistoryView> {
  bool _exporting = false;
  String? _exportMessage;
  String? _exportError;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text(
        'Retained permission history for this connection, including other sessions. Other connections are not included. Export to keep a copy.',
      ),
      const SizedBox(height: 12),
      Expanded(
        child: widget.entries.isEmpty
            ? const SingleChildScrollView(child: _PermissionHistoryEmptyState())
            : ListView.separated(
                key: const Key('permission-history-list'),
                itemCount: widget.entries.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (_, index) =>
                    _PermissionHistoryRow(entry: widget.entries[index]),
              ),
      ),
      if (_exportMessage != null || _exportError != null) ...[
        const SizedBox(height: 10),
        _ExportStatus(
          text: _exportError ?? _exportMessage!,
          isError: _exportError != null,
        ),
      ],
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerRight,
        child: OutlinedButton.icon(
          onPressed: widget.entries.isEmpty || _exporting ? null : _export,
          icon: _exporting
              ? const SizedBox(
                  width: 15,
                  height: 15,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.download_rounded, size: 16),
          label: const Text('Export JSON'),
        ),
      ),
    ],
  );
  Future<void> _export() async {
    setState(() {
      _exporting = true;
      _exportMessage = null;
      _exportError = null;
    });

    try {
      final exporter = widget.exporter ?? savePermissionHistoryJson;
      final fileName = _permissionHistoryFileName(DateTime.now());
      final path = await exporter(
        fileName,
        acpPermissionAuditEntriesToJson(widget.entries),
      );
      if (!mounted) return;
      setState(() {
        _exportMessage = path == null
            ? 'Export cancelled.'
            : 'Permission history exported.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _exportError = 'Could not export permission history: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _exporting = false;
        });
      }
    }
  }
}

class _PermissionHistoryEmptyState extends StatelessWidget {
  const _PermissionHistoryEmptyState();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      decoration: BoxDecoration(
        color: context.ianvs.canvas,
        borderRadius: BorderRadius.circular(context.ianvs.panelRadius),
        border: Border.all(color: context.ianvs.border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.shield_outlined, size: 30, color: context.ianvs.subtle),
          SizedBox(height: 12),
          Text(
            'No permission requests yet.',
            style: TextStyle(
              color: context.ianvs.text,
              fontSize: 14,
              fontWeight: FontWeight.w600,
              letterSpacing: 0,
            ),
          ),
          SizedBox(height: 6),
          Text(
            'Requests that need your approval will be recorded here.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: context.ianvs.muted,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 0,
            ),
          ),
        ],
      ),
    );
  }
}

class _ExportStatus extends StatelessWidget {
  const _ExportStatus({required this.text, required this.isError});

  final String text;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final color = isError ? context.ianvs.danger : context.ianvs.success;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(context.ianvs.controlRadius),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0,
        ),
      ),
    );
  }
}

class _PermissionHistoryRow extends StatelessWidget {
  const _PermissionHistoryRow({required this.entry});

  final AcpPermissionAuditEntry entry;

  @override
  Widget build(BuildContext context) {
    final request = entry.request;
    final statusColor = _statusColor(context, entry.status);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(context.ianvs.controlRadius),
        border: Border.all(color: context.ianvs.border),
        color: context.ianvs.canvas,
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
                  style: TextStyle(
                    color: context.ianvs.text,
                    fontWeight: FontWeight.w600,
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
                  fontWeight: FontWeight.w600,
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
            style: TextStyle(
              color: context.ianvs.muted,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 0,
            ),
          ),
          if (entry.reviewResult case final review?) ...[
            const SizedBox(height: 6),
            Text(
              review.displayRationale,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: context.ianvs.muted,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                letterSpacing: 0,
              ),
            ),
          ],
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
              if (entry.displayDecisionSource != null)
                _MetaChip(
                  icon: Icons.rule_rounded,
                  label: entry.displayDecisionSource!,
                ),
              if (entry.reviewResult case final review?) ...[
                _MetaChip(
                  icon: Icons.health_and_safety_outlined,
                  label: 'Risk ${review.displayRisk}',
                ),
                if (review.model?.trim().isNotEmpty == true)
                  _MetaChip(
                    icon: Icons.memory_rounded,
                    label: review.model!.trim(),
                  ),
              ],
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
        color: context.ianvs.raised,
        borderRadius: BorderRadius.circular(context.ianvs.controlRadius),
        border: Border.all(color: context.ianvs.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: context.ianvs.subtle),
          const SizedBox(width: 4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 220),
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: context.ianvs.muted,
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

IconData _statusIcon(AcpPermissionAuditStatus status) {
  return switch (status) {
    AcpPermissionAuditStatus.pending => Icons.hourglass_top_rounded,
    AcpPermissionAuditStatus.allowed => Icons.check_circle_outline_rounded,
    AcpPermissionAuditStatus.denied => Icons.block_rounded,
    AcpPermissionAuditStatus.cancelled => Icons.cancel_outlined,
  };
}

Color _statusColor(BuildContext context, AcpPermissionAuditStatus status) {
  return switch (status) {
    AcpPermissionAuditStatus.pending => context.ianvs.warning,
    AcpPermissionAuditStatus.allowed => context.ianvs.success,
    AcpPermissionAuditStatus.denied => context.ianvs.danger,
    AcpPermissionAuditStatus.cancelled => context.ianvs.subtle,
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

Future<String?> savePermissionHistoryJson(String fileName, String json) async {
  return FilePicker.platform.saveFile(
    dialogTitle: 'Export Permission History',
    fileName: fileName,
    type: FileType.custom,
    allowedExtensions: const ['json'],
    bytes: Uint8List.fromList(utf8.encode(json)),
  );
}

String _permissionHistoryFileName(DateTime value) {
  final utc = value.toUtc();
  return 'ianvs-acp-permission-history-'
      '${utc.year.toString().padLeft(4, '0')}'
      '${utc.month.toString().padLeft(2, '0')}'
      '${utc.day.toString().padLeft(2, '0')}-'
      '${utc.hour.toString().padLeft(2, '0')}'
      '${utc.minute.toString().padLeft(2, '0')}'
      '${utc.second.toString().padLeft(2, '0')}.json';
}
