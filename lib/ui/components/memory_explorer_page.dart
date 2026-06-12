import 'dart:convert';

import 'package:flutter/material.dart';

import '../../memory/memory_api_client.dart';
import '../theme/app_design_tokens.dart';

enum MemoryExplorerInitialTab {
  allMemory,
  candidates,
  changeRequests,
  auditLog,
}

class MemoryExplorerActions {
  const MemoryExplorerActions({
    required this.loadChangeRequests,
    required this.approveChangeRequest,
    required this.rejectChangeRequest,
    this.loadMemory,
    this.updateMemory,
    this.deleteMemory,
    this.loadCandidates,
    this.approveCandidate,
    this.rejectCandidate,
    this.runMaintenance,
    this.loadAuditLog,
  });

  final Future<List<MemoryChangeRequest>> Function() loadChangeRequests;
  final Future<void> Function(MemoryChangeRequest request) approveChangeRequest;
  final Future<void> Function(MemoryChangeRequest request) rejectChangeRequest;
  final Future<List<MemoryRecord>> Function()? loadMemory;
  final Future<void> Function(MemoryRecord record)? updateMemory;
  final Future<void> Function(MemoryRecord record)? deleteMemory;
  final Future<List<MemoryCandidate>> Function()? loadCandidates;
  final Future<void> Function(MemoryCandidate candidate)? approveCandidate;
  final Future<void> Function(MemoryCandidate candidate)? rejectCandidate;
  final Future<MaintenanceRunResult> Function()? runMaintenance;
  final Future<List<MemoryAuditEntry>> Function()? loadAuditLog;
}

class MemoryExplorerPage extends StatefulWidget {
  const MemoryExplorerPage({
    super.key,
    this.onClearData,
    this.actions,
    this.initialTab = MemoryExplorerInitialTab.allMemory,
  });

  final VoidCallback? onClearData;
  final MemoryExplorerActions? actions;
  final MemoryExplorerInitialTab initialTab;

  @override
  State<MemoryExplorerPage> createState() => _MemoryExplorerPageState();
}

class _MemoryExplorerPageState extends State<MemoryExplorerPage> {
  Future<List<MemoryRecord>>? _memoryFuture;
  Future<List<MemoryChangeRequest>>? _changeRequestsFuture;
  Future<List<MemoryCandidate>>? _candidatesFuture;
  Future<List<MemoryAuditEntry>>? _auditFuture;
  String? _busyMemoryId;
  String? _busyChangeRequestId;
  String? _busyCandidateId;
  bool _maintenanceRunning = false;
  MaintenanceRunResult? _maintenanceResult;
  String? _maintenanceError;

  @override
  void initState() {
    super.initState();
    _reloadMemory();
    _reloadChangeRequests();
    _reloadCandidates();
    _reloadAuditLog();
  }

  @override
  void didUpdateWidget(covariant MemoryExplorerPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.actions != widget.actions) {
      _reloadMemory();
      _reloadChangeRequests();
      _reloadCandidates();
      _reloadAuditLog();
    }
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
      initialIndex: widget.initialTab.index,
      child: Scaffold(
        backgroundColor: AppColors.bg,
        appBar: AppBar(
          backgroundColor: AppColors.bg,
          foregroundColor: AppColors.textPrimary,
          elevation: 0,
          title: const Text(
            'Memory',
            style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 0),
          ),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: OutlinedButton.icon(
                onPressed: widget.onClearData,
                icon: const Icon(Icons.delete_outline_rounded, size: 18),
                label: const Text('Clear data'),
              ),
            ),
          ],
          bottom: const TabBar(
            isScrollable: true,
            labelColor: AppColors.primaryDark,
            unselectedLabelColor: AppColors.textSecondary,
            indicatorColor: AppColors.primaryDark,
            tabs: [
              Tab(text: 'All memory'),
              Tab(text: 'Candidates'),
              Tab(text: 'Change requests'),
              Tab(text: 'Audit log'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _AllMemoryPane(
              future: _memoryFuture,
              busyId: _busyMemoryId,
              canOrganize: widget.actions?.runMaintenance != null,
              running: _maintenanceRunning,
              result: _maintenanceResult,
              error: _maintenanceError,
              onOrganize: _runMaintenance,
              onUpdate: _updateMemory,
              onDelete: _deleteMemory,
            ),
            _CandidatesPane(
              future: _candidatesFuture,
              busyId: _busyCandidateId,
              onApprove: _approveCandidate,
              onReject: _rejectCandidate,
            ),
            _ChangeRequestsPane(
              future: _changeRequestsFuture,
              busyId: _busyChangeRequestId,
              onApprove: _approveChangeRequest,
              onReject: _rejectChangeRequest,
            ),
            _AuditPane(future: _auditFuture),
          ],
        ),
      ),
    );
  }

  void _reloadChangeRequests() {
    _changeRequestsFuture = widget.actions?.loadChangeRequests();
  }

  void _reloadMemory() {
    _memoryFuture = widget.actions?.loadMemory?.call();
  }

  void _reloadCandidates() {
    _candidatesFuture = widget.actions?.loadCandidates?.call();
  }

  void _reloadAuditLog() {
    _auditFuture = widget.actions?.loadAuditLog?.call();
  }

  Future<void> _runMaintenance() async {
    final runMaintenance = widget.actions?.runMaintenance;
    if (runMaintenance == null || _maintenanceRunning) return;
    setState(() {
      _maintenanceRunning = true;
      _maintenanceError = null;
    });
    try {
      final result = await runMaintenance();
      if (!mounted) return;
      setState(() {
        _maintenanceResult = result;
        _maintenanceRunning = false;
        _reloadMemory();
        _reloadCandidates();
        _reloadChangeRequests();
        _reloadAuditLog();
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _maintenanceRunning = false;
        _maintenanceError = 'Could not organize memory.';
      });
    }
  }

  Future<void> _approveChangeRequest(MemoryChangeRequest request) async {
    final actions = widget.actions;
    if (actions == null || _busyChangeRequestId != null) return;
    setState(() => _busyChangeRequestId = request.id);
    try {
      await actions.approveChangeRequest(request);
      if (!mounted) return;
      setState(() {
        _reloadMemory();
        _reloadChangeRequests();
        _reloadAuditLog();
      });
    } finally {
      if (mounted) setState(() => _busyChangeRequestId = null);
    }
  }

  Future<void> _rejectChangeRequest(MemoryChangeRequest request) async {
    final actions = widget.actions;
    if (actions == null || _busyChangeRequestId != null) return;
    setState(() => _busyChangeRequestId = request.id);
    try {
      await actions.rejectChangeRequest(request);
      if (!mounted) return;
      setState(() {
        _reloadChangeRequests();
        _reloadAuditLog();
      });
    } finally {
      if (mounted) setState(() => _busyChangeRequestId = null);
    }
  }

  Future<void> _approveCandidate(MemoryCandidate candidate) async {
    final approve = widget.actions?.approveCandidate;
    if (approve == null || _busyCandidateId != null) return;
    setState(() => _busyCandidateId = candidate.id);
    try {
      await approve(candidate);
      if (!mounted) return;
      setState(() {
        _reloadMemory();
        _reloadCandidates();
        _reloadAuditLog();
      });
    } finally {
      if (mounted) setState(() => _busyCandidateId = null);
    }
  }

  Future<void> _rejectCandidate(MemoryCandidate candidate) async {
    final reject = widget.actions?.rejectCandidate;
    if (reject == null || _busyCandidateId != null) return;
    setState(() => _busyCandidateId = candidate.id);
    try {
      await reject(candidate);
      if (!mounted) return;
      setState(() {
        _reloadCandidates();
        _reloadAuditLog();
      });
    } finally {
      if (mounted) setState(() => _busyCandidateId = null);
    }
  }

  Future<void> _updateMemory(MemoryRecord record) async {
    final update = widget.actions?.updateMemory;
    if (update == null || _busyMemoryId != null) return;
    setState(() => _busyMemoryId = record.id);
    try {
      await update(record);
      if (!mounted) return;
      setState(() {
        _reloadMemory();
        _reloadAuditLog();
      });
    } finally {
      if (mounted) setState(() => _busyMemoryId = null);
    }
  }

  Future<void> _deleteMemory(MemoryRecord record) async {
    final delete = widget.actions?.deleteMemory;
    if (delete == null || _busyMemoryId != null) return;
    setState(() => _busyMemoryId = record.id);
    try {
      await delete(record);
      if (!mounted) return;
      setState(() {
        _reloadMemory();
        _reloadAuditLog();
      });
    } finally {
      if (mounted) setState(() => _busyMemoryId = null);
    }
  }
}

class _AllMemoryPane extends StatelessWidget {
  const _AllMemoryPane({
    required this.future,
    required this.busyId,
    required this.canOrganize,
    required this.running,
    required this.result,
    required this.error,
    required this.onOrganize,
    required this.onUpdate,
    required this.onDelete,
  });

  final Future<List<MemoryRecord>>? future;
  final String? busyId;
  final bool canOrganize;
  final bool running;
  final MaintenanceRunResult? result;
  final String? error;
  final VoidCallback onOrganize;
  final ValueChanged<MemoryRecord> onUpdate;
  final ValueChanged<MemoryRecord> onDelete;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: canOrganize && !running ? onOrganize : null,
              icon: running
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.auto_fix_high_rounded, size: 18),
              label: Text(running ? 'Organizing' : 'Organize'),
            ),
          ),
          const SizedBox(height: 18),
          if (error != null || result != null) ...[
            _MemoryExplorerStatus(
              message: _statusText(),
              actionLabel: _shouldShowReviewAction()
                  ? 'Review change requests'
                  : null,
              onAction: _shouldShowReviewAction()
                  ? () => DefaultTabController.maybeOf(
                      context,
                    )?.animateTo(MemoryExplorerInitialTab.changeRequests.index)
                  : null,
            ),
            const SizedBox(height: 12),
          ],
          Expanded(
            child: _MemoryRecordsPane(
              future: future,
              busyId: busyId,
              onUpdate: onUpdate,
              onDelete: onDelete,
            ),
          ),
        ],
      ),
    );
  }

  String _statusText() {
    final error = this.error;
    if (error != null) return error;
    final result = this.result;
    if (result == null) return '';
    return '${result.autoApplied} auto applied · '
        '${result.needsReview} need review · '
        '${result.skipped} skipped';
  }

  bool _shouldShowReviewAction() {
    final result = this.result;
    return result != null && result.needsReview > 0;
  }
}

class _MemoryExplorerStatus extends StatelessWidget {
  const _MemoryExplorerStatus({
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final actionLabel = this.actionLabel;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Flexible(
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 13,
                fontWeight: FontWeight.w700,
                letterSpacing: 0,
              ),
            ),
          ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(width: 12),
            TextButton(onPressed: onAction, child: Text(actionLabel)),
          ],
        ],
      ),
    );
  }
}

class _MemoryRecordsPane extends StatelessWidget {
  const _MemoryRecordsPane({
    required this.future,
    required this.busyId,
    required this.onUpdate,
    required this.onDelete,
  });

  final Future<List<MemoryRecord>>? future;
  final String? busyId;
  final ValueChanged<MemoryRecord> onUpdate;
  final ValueChanged<MemoryRecord> onDelete;

  @override
  Widget build(BuildContext context) {
    final future = this.future;
    if (future == null) {
      return const _MemoryExplorerPane(message: 'No memory records yet.');
    }
    return FutureBuilder<List<MemoryRecord>>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return const _MemoryExplorerPane(message: 'Could not load memory.');
        }
        final records = snapshot.data ?? const <MemoryRecord>[];
        if (records.isEmpty) {
          return const _MemoryExplorerPane(message: 'No memory records yet.');
        }
        return ListView.separated(
          itemCount: records.length,
          separatorBuilder: (_, _) => const SizedBox(height: 12),
          itemBuilder: (context, index) {
            final record = records[index];
            return _MemoryRecordCard(
              record: record,
              busy: busyId == record.id,
              onUpdate: onUpdate,
              onDelete: onDelete,
            );
          },
        );
      },
    );
  }
}

class _MemoryRecordCard extends StatelessWidget {
  const _MemoryRecordCard({
    required this.record,
    required this.busy,
    required this.onUpdate,
    required this.onDelete,
  });

  final MemoryRecord record;
  final bool busy;
  final ValueChanged<MemoryRecord> onUpdate;
  final ValueChanged<MemoryRecord> onDelete;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  '${record.kind} · ${record.scope} · ${record.status}',
                  style: const TextStyle(
                    color: AppColors.primaryDark,
                    fontSize: 13,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Edit memory',
                onPressed: busy ? null : () => _showEditDialog(context),
                icon: const Icon(Icons.edit_rounded, size: 18),
              ),
              IconButton(
                tooltip: 'Delete memory',
                onPressed: busy ? null : () => onDelete(record),
                icon: const Icon(Icons.delete_outline_rounded, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            record.text,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w800,
              letterSpacing: 0,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showEditDialog(BuildContext context) async {
    final updated = await showDialog<MemoryRecord>(
      context: context,
      builder: (_) => _EditMemoryDialog(record: record),
    );
    if (updated != null) {
      onUpdate(updated);
    }
  }
}

class _EditMemoryDialog extends StatefulWidget {
  const _EditMemoryDialog({required this.record});

  final MemoryRecord record;

  @override
  State<_EditMemoryDialog> createState() => _EditMemoryDialogState();
}

class _EditMemoryDialogState extends State<_EditMemoryDialog> {
  late final TextEditingController _kindController;
  late final TextEditingController _scopeController;
  late final TextEditingController _textController;

  @override
  void initState() {
    super.initState();
    _kindController = TextEditingController(text: widget.record.kind);
    _scopeController = TextEditingController(text: widget.record.scope);
    _textController = TextEditingController(text: widget.record.text);
  }

  @override
  void dispose() {
    _kindController.dispose();
    _scopeController.dispose();
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit memory'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _kindController,
              decoration: const InputDecoration(labelText: 'Kind'),
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: _scopeController,
              decoration: const InputDecoration(labelText: 'Scope'),
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: _textController,
              decoration: const InputDecoration(labelText: 'Text'),
              minLines: 3,
              maxLines: 5,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.of(context).pop(
              MemoryRecord(
                id: widget.record.id,
                kind: _kindController.text.trim(),
                scope: _scopeController.text.trim(),
                text: _textController.text.trim(),
                status: widget.record.status,
                createdAt: widget.record.createdAt,
                updatedAt: widget.record.updatedAt,
              ),
            );
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _MemoryExplorerPane extends StatelessWidget {
  const _MemoryExplorerPane({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 520),
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: AppColors.border),
        ),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: AppColors.textSecondary,
            fontSize: 14,
            fontWeight: FontWeight.w700,
            letterSpacing: 0,
          ),
        ),
      ),
    );
  }
}

class _CandidatesPane extends StatelessWidget {
  const _CandidatesPane({
    required this.future,
    required this.busyId,
    required this.onApprove,
    required this.onReject,
  });

  final Future<List<MemoryCandidate>>? future;
  final String? busyId;
  final Future<void> Function(MemoryCandidate candidate) onApprove;
  final Future<void> Function(MemoryCandidate candidate) onReject;

  @override
  Widget build(BuildContext context) {
    final future = this.future;
    if (future == null) {
      return const _MemoryExplorerPane(message: 'No candidates yet.');
    }
    return FutureBuilder<List<MemoryCandidate>>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return const _MemoryExplorerPane(
            message: 'Could not load candidates.',
          );
        }
        final candidates = snapshot.data ?? const <MemoryCandidate>[];
        if (candidates.isEmpty) {
          return const _MemoryExplorerPane(message: 'No candidates yet.');
        }
        final pendingCandidates = candidates
            .where(
              (candidate) => candidate.status.trim().toLowerCase() == 'pending',
            )
            .toList(growable: false);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (pendingCandidates.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 18, 18, 0),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: busyId == null
                            ? () => _rejectAll(pendingCandidates)
                            : null,
                        icon: const Icon(Icons.close_rounded, size: 18),
                        label: Text('Reject all (${pendingCandidates.length})'),
                      ),
                      FilledButton.icon(
                        onPressed: busyId == null
                            ? () => _approveAll(pendingCandidates)
                            : null,
                        icon: const Icon(Icons.done_all_rounded, size: 18),
                        label: Text(
                          'Approve all (${pendingCandidates.length})',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            Expanded(
              child: ListView.separated(
                padding: EdgeInsets.fromLTRB(
                  18,
                  pendingCandidates.isEmpty ? 18 : 12,
                  18,
                  18,
                ),
                itemCount: candidates.length,
                separatorBuilder: (_, _) => const SizedBox(height: 12),
                itemBuilder: (context, index) {
                  final candidate = candidates[index];
                  return _CandidateCard(
                    key: ValueKey(candidate.id),
                    candidate: candidate,
                    busy: busyId == candidate.id,
                    onApprove: onApprove,
                    onReject: () => onReject(candidate),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _approveAll(List<MemoryCandidate> candidates) async {
    for (final candidate in candidates) {
      await onApprove(candidate);
    }
  }

  Future<void> _rejectAll(List<MemoryCandidate> candidates) async {
    for (final candidate in candidates) {
      await onReject(candidate);
    }
  }
}

class _CandidateCard extends StatefulWidget {
  const _CandidateCard({
    super.key,
    required this.candidate,
    required this.busy,
    required this.onApprove,
    required this.onReject,
  });

  final MemoryCandidate candidate;
  final bool busy;
  final Future<void> Function(MemoryCandidate candidate) onApprove;
  final VoidCallback onReject;

  @override
  State<_CandidateCard> createState() => _CandidateCardState();
}

class _CandidateCardState extends State<_CandidateCard> {
  late MemoryCandidate _candidate = widget.candidate;

  @override
  void didUpdateWidget(covariant _CandidateCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_candidateChanged(oldWidget.candidate, widget.candidate)) {
      _candidate = widget.candidate;
    }
  }

  bool _candidateChanged(MemoryCandidate before, MemoryCandidate after) {
    return before.id != after.id ||
        before.kind != after.kind ||
        before.scope != after.scope ||
        before.text != after.text ||
        before.confidence != after.confidence ||
        before.reason != after.reason ||
        before.status != after.status ||
        before.createdAt != after.createdAt ||
        before.reviewedAt != after.reviewedAt;
  }

  @override
  Widget build(BuildContext context) {
    final candidate = _candidate;
    final isPending = candidate.status.trim().toLowerCase() == 'pending';
    final confidence = candidate.confidence;
    final reason = candidate.reason?.trim();
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            [
              candidate.kind,
              candidate.scope,
              confidence == null
                  ? 'manual review'
                  : '${(confidence * 100).round()}%',
              candidate.status,
            ].join(' · '),
            style: const TextStyle(
              color: AppColors.primaryDark,
              fontSize: 13,
              fontWeight: FontWeight.w900,
              letterSpacing: 0,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            candidate.text,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w800,
              letterSpacing: 0,
            ),
          ),
          if (reason?.isNotEmpty == true) ...[
            const SizedBox(height: 10),
            Text(
              reason!,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                letterSpacing: 0,
              ),
            ),
          ],
          if (isPending) ...[
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                IconButton(
                  tooltip: 'Edit candidate',
                  onPressed: widget.busy
                      ? null
                      : () => _showEditDialog(context),
                  icon: const Icon(Icons.edit_outlined),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: widget.busy ? null : widget.onReject,
                  child: const Text('Reject'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: widget.busy
                      ? null
                      : () => widget.onApprove(_candidate),
                  child: widget.busy
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Approve'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _showEditDialog(BuildContext context) async {
    final edited = await showDialog<MemoryCandidate>(
      context: context,
      builder: (_) => _EditCandidateDialog(candidate: _candidate),
    );
    if (edited == null || !mounted) return;
    setState(() => _candidate = edited);
  }
}

class _EditCandidateDialog extends StatefulWidget {
  const _EditCandidateDialog({required this.candidate});

  final MemoryCandidate candidate;

  @override
  State<_EditCandidateDialog> createState() => _EditCandidateDialogState();
}

class _EditCandidateDialogState extends State<_EditCandidateDialog> {
  late final TextEditingController _kindController;
  late final TextEditingController _scopeController;
  late final TextEditingController _textController;

  @override
  void initState() {
    super.initState();
    _kindController = TextEditingController(text: widget.candidate.kind);
    _scopeController = TextEditingController(text: widget.candidate.scope);
    _textController = TextEditingController(text: widget.candidate.text);
  }

  @override
  void dispose() {
    _kindController.dispose();
    _scopeController.dispose();
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit candidate'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _kindController,
              decoration: const InputDecoration(labelText: 'Kind'),
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: _scopeController,
              decoration: const InputDecoration(labelText: 'Scope'),
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: _textController,
              decoration: const InputDecoration(labelText: 'Text'),
              minLines: 3,
              maxLines: 6,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.of(context).pop(
              MemoryCandidate(
                id: widget.candidate.id,
                kind: _kindController.text.trim().isEmpty
                    ? widget.candidate.kind
                    : _kindController.text.trim(),
                scope: _scopeController.text.trim().isEmpty
                    ? widget.candidate.scope
                    : _scopeController.text.trim(),
                text: _textController.text.trim().isEmpty
                    ? widget.candidate.text
                    : _textController.text.trim(),
                confidence: widget.candidate.confidence,
                reason: widget.candidate.reason,
                status: widget.candidate.status,
                createdAt: widget.candidate.createdAt,
                reviewedAt: widget.candidate.reviewedAt,
              ),
            );
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _ChangeRequestsPane extends StatelessWidget {
  const _ChangeRequestsPane({
    required this.future,
    required this.busyId,
    required this.onApprove,
    required this.onReject,
  });

  final Future<List<MemoryChangeRequest>>? future;
  final String? busyId;
  final Future<void> Function(MemoryChangeRequest request) onApprove;
  final Future<void> Function(MemoryChangeRequest request) onReject;

  @override
  Widget build(BuildContext context) {
    final future = this.future;
    if (future == null) {
      return const _MemoryExplorerPane(message: 'No change requests yet.');
    }
    return FutureBuilder<List<MemoryChangeRequest>>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return _MemoryExplorerPane(
            message: 'Could not load change requests.',
          );
        }
        final requests = snapshot.data ?? const <MemoryChangeRequest>[];
        if (requests.isEmpty) {
          return const _MemoryExplorerPane(message: 'No change requests yet.');
        }
        final safePendingRequests = requests
            .where(_canBatchApproveChangeRequest)
            .toList(growable: false);
        final pendingRequests = requests
            .where(
              (request) => request.status.trim().toLowerCase() == 'pending',
            )
            .toList(growable: false);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (pendingRequests.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 18, 18, 0),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: busyId == null
                            ? () => _rejectAll(pendingRequests)
                            : null,
                        icon: const Icon(Icons.close_rounded, size: 18),
                        label: Text('Reject all (${pendingRequests.length})'),
                      ),
                      if (safePendingRequests.isNotEmpty)
                        FilledButton.icon(
                          onPressed: busyId == null
                              ? () => _approveAll(safePendingRequests)
                              : null,
                          icon: const Icon(Icons.done_all_rounded, size: 18),
                          label: Text(
                            'Approve safe changes '
                            '(${safePendingRequests.length})',
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            Expanded(
              child: ListView.separated(
                padding: EdgeInsets.fromLTRB(
                  18,
                  pendingRequests.isEmpty ? 18 : 12,
                  18,
                  18,
                ),
                itemCount: requests.length,
                separatorBuilder: (_, _) => const SizedBox(height: 12),
                itemBuilder: (context, index) {
                  final request = requests[index];
                  return _ChangeRequestCard(
                    key: ValueKey(request.id),
                    request: request,
                    busy: busyId == request.id,
                    onApprove: onApprove,
                    onReject: () => onReject(request),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  bool _canBatchApproveChangeRequest(MemoryChangeRequest request) {
    final action = request.action.trim().toLowerCase();
    if (request.status.trim().toLowerCase() != 'pending') return false;
    return action == 'merge' || action == 'summarize' || action == 'update';
  }

  Future<void> _approveAll(List<MemoryChangeRequest> requests) async {
    for (final request in requests) {
      await onApprove(request);
    }
  }

  Future<void> _rejectAll(List<MemoryChangeRequest> requests) async {
    for (final request in requests) {
      await onReject(request);
    }
  }
}

class _ChangeRequestCard extends StatefulWidget {
  const _ChangeRequestCard({
    super.key,
    required this.request,
    required this.busy,
    required this.onApprove,
    required this.onReject,
  });

  final MemoryChangeRequest request;
  final bool busy;
  final Future<void> Function(MemoryChangeRequest request) onApprove;
  final VoidCallback onReject;

  @override
  State<_ChangeRequestCard> createState() => _ChangeRequestCardState();
}

class _ChangeRequestCardState extends State<_ChangeRequestCard> {
  late MemoryChangeRequest _request = widget.request;

  @override
  void didUpdateWidget(covariant _ChangeRequestCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_requestChanged(oldWidget.request, widget.request)) {
      _request = widget.request;
    }
  }

  bool _requestChanged(MemoryChangeRequest before, MemoryChangeRequest after) {
    return before.id != after.id ||
        before.action != after.action ||
        before.source != after.source ||
        before.targetMemoryIds.join('\u0000') !=
            after.targetMemoryIds.join('\u0000') ||
        before.targetMemoryText != after.targetMemoryText ||
        before.proposedKind != after.proposedKind ||
        before.proposedScope != after.proposedScope ||
        before.proposedText != after.proposedText ||
        before.reason != after.reason ||
        before.confidence != after.confidence ||
        before.status != after.status ||
        before.createdAt != after.createdAt ||
        before.reviewedAt != after.reviewedAt;
  }

  @override
  Widget build(BuildContext context) {
    final request = _request;
    final isPending = request.status.trim().toLowerCase() == 'pending';
    final source = request.source.trim();
    final canEdit = isPending && _canEditChangeRequest(request);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            [
              request.action,
              _confidenceLabel(request.confidence),
              request.status,
              if (source.isNotEmpty) source,
            ].join(' · '),
            style: const TextStyle(
              color: AppColors.primaryDark,
              fontSize: 13,
              fontWeight: FontWeight.w900,
              letterSpacing: 0,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'target ${request.targetMemoryIds.join(', ')}',
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 0,
            ),
          ),
          if (request.targetMemoryText?.trim().isNotEmpty == true) ...[
            const SizedBox(height: 12),
            const _FieldLabel('Original'),
            const SizedBox(height: 4),
            Text(
              request.targetMemoryText!.trim(),
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                letterSpacing: 0,
              ),
            ),
          ],
          if (request.proposedText?.trim().isNotEmpty == true) ...[
            const SizedBox(height: 12),
            const _FieldLabel('Proposed'),
            const SizedBox(height: 4),
            Text(
              request.proposedText!.trim(),
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w800,
                letterSpacing: 0,
              ),
            ),
          ],
          if (request.reason?.trim().isNotEmpty == true) ...[
            const SizedBox(height: 10),
            Text(
              request.reason!.trim(),
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                letterSpacing: 0,
              ),
            ),
          ],
          if (isPending) ...[
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (canEdit) ...[
                  IconButton(
                    tooltip: 'Edit change request',
                    onPressed: widget.busy
                        ? null
                        : () => _showEditDialog(context),
                    icon: const Icon(Icons.edit_outlined),
                  ),
                  const SizedBox(width: 8),
                ],
                TextButton(
                  onPressed: widget.busy ? null : widget.onReject,
                  child: const Text('Reject'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: widget.busy
                      ? null
                      : () => widget.onApprove(_request),
                  child: widget.busy
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Approve'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  bool _canEditChangeRequest(MemoryChangeRequest request) {
    const editableActions = {'merge', 'summarize', 'update'};
    return editableActions.contains(request.action.trim().toLowerCase());
  }

  Future<void> _showEditDialog(BuildContext context) async {
    final edited = await showDialog<MemoryChangeRequest>(
      context: context,
      builder: (_) => _EditChangeRequestDialog(request: _request),
    );
    if (edited == null || !mounted) return;
    setState(() => _request = edited);
  }

  String _confidenceLabel(double? confidence) {
    if (confidence == null) return 'manual review';
    return '${(confidence * 100).round()}%';
  }
}

class _EditChangeRequestDialog extends StatefulWidget {
  const _EditChangeRequestDialog({required this.request});

  final MemoryChangeRequest request;

  @override
  State<_EditChangeRequestDialog> createState() =>
      _EditChangeRequestDialogState();
}

class _EditChangeRequestDialogState extends State<_EditChangeRequestDialog> {
  late final TextEditingController _kindController;
  late final TextEditingController _scopeController;
  late final TextEditingController _textController;

  @override
  void initState() {
    super.initState();
    _kindController = TextEditingController(
      text: widget.request.proposedKind ?? '',
    );
    _scopeController = TextEditingController(
      text: widget.request.proposedScope ?? '',
    );
    _textController = TextEditingController(
      text: widget.request.proposedText ?? '',
    );
  }

  @override
  void dispose() {
    _kindController.dispose();
    _scopeController.dispose();
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit change request'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _kindController,
              decoration: const InputDecoration(labelText: 'Proposed kind'),
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: _scopeController,
              decoration: const InputDecoration(labelText: 'Proposed scope'),
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: _textController,
              decoration: const InputDecoration(labelText: 'Proposed text'),
              minLines: 3,
              maxLines: 6,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.of(context).pop(
              widget.request.copyWith(
                proposedKind: _kindController.text.trim().isEmpty
                    ? widget.request.proposedKind
                    : _kindController.text.trim(),
                proposedScope: _scopeController.text.trim().isEmpty
                    ? widget.request.proposedScope
                    : _scopeController.text.trim(),
                proposedText: _textController.text.trim().isEmpty
                    ? widget.request.proposedText
                    : _textController.text.trim(),
              ),
            );
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _AuditPane extends StatelessWidget {
  const _AuditPane({required this.future});

  final Future<List<MemoryAuditEntry>>? future;

  @override
  Widget build(BuildContext context) {
    final future = this.future;
    if (future == null) {
      return const _MemoryExplorerPane(message: 'No audit entries yet.');
    }
    return FutureBuilder<List<MemoryAuditEntry>>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return const _MemoryExplorerPane(
            message: 'Could not load audit log.',
          );
        }
        final entries = _visibleAuditEntries(
          snapshot.data ?? const <MemoryAuditEntry>[],
        );
        if (entries.isEmpty) {
          return const _MemoryExplorerPane(message: 'No audit entries yet.');
        }
        return ListView.separated(
          padding: const EdgeInsets.all(18),
          itemCount: entries.length,
          separatorBuilder: (_, _) => const SizedBox(height: 12),
          itemBuilder: (context, index) {
            return _AuditCard(entry: entries[index]);
          },
        );
      },
    );
  }
}

List<MemoryAuditEntry> _visibleAuditEntries(List<MemoryAuditEntry> entries) {
  final autoMemoryIds = entries
      .where((entry) => entry.action == 'candidate.auto_approve')
      .map((entry) => entry.memoryId?.trim())
      .whereType<String>()
      .where((id) => id.isNotEmpty)
      .toSet();
  final autoCandidateIds = entries
      .where((entry) => entry.action == 'candidate.auto_approve')
      .map((entry) => entry.candidateId?.trim())
      .whereType<String>()
      .where((id) => id.isNotEmpty)
      .toSet();
  final changeRequestOutcomeIds = entries
      .where(_isMemoryOutcomeAudit)
      .map((entry) => entry.changeRequestId?.trim())
      .whereType<String>()
      .where((id) => id.isNotEmpty)
      .toSet();

  return entries
      .where((entry) {
        final memoryId = entry.memoryId?.trim();
        final candidateId = entry.candidateId?.trim();
        final changeRequestId = entry.changeRequestId?.trim();
        if (entry.action == 'memory.create' &&
            memoryId != null &&
            autoMemoryIds.contains(memoryId)) {
          return false;
        }
        if (entry.action == 'candidate.create' &&
            candidateId != null &&
            autoCandidateIds.contains(candidateId)) {
          return false;
        }
        if (entry.action == 'change_request.approve' &&
            changeRequestId != null &&
            changeRequestOutcomeIds.contains(changeRequestId)) {
          return false;
        }
        return true;
      })
      .toList(growable: false);
}

bool _isMemoryOutcomeAudit(MemoryAuditEntry entry) {
  return switch (entry.action) {
    'memory.update' ||
    'memory.summarize' ||
    'memory.disable' ||
    'memory.expire' ||
    'memory.delete' ||
    'memory.merge' => true,
    _ => false,
  };
}

class _AuditCard extends StatelessWidget {
  const _AuditCard({required this.entry});

  final MemoryAuditEntry entry;

  @override
  Widget build(BuildContext context) {
    final presentation = _AuditPresentation.fromEntry(entry);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            presentation.title,
            style: const TextStyle(
              color: AppColors.primaryDark,
              fontSize: 13,
              fontWeight: FontWeight.w900,
              letterSpacing: 0,
            ),
          ),
          const SizedBox(height: 8),
          for (final line in presentation.lines) ...[
            Text(
              line,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0,
              ),
            ),
            const SizedBox(height: 4),
          ],
          Text(
            '时间：${presentation.timeLabel}',
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 0,
            ),
          ),
          if (presentation.hasDetails) ...[
            const SizedBox(height: 10),
            Theme(
              data: Theme.of(context).copyWith(
                dividerColor: Colors.transparent,
                splashColor: Colors.transparent,
                highlightColor: Colors.transparent,
              ),
              child: Material(
                type: MaterialType.transparency,
                child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: EdgeInsets.zero,
                  title: const Text(
                    '详情',
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0,
                    ),
                  ),
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: SelectableText(
                        presentation.detailText,
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _AuditPresentation {
  const _AuditPresentation({
    required this.title,
    required this.lines,
    required this.timeLabel,
    required this.detailText,
    required this.hasDetails,
  });

  final String title;
  final List<String> lines;
  final String timeLabel;
  final String detailText;
  final bool hasDetails;

  factory _AuditPresentation.fromEntry(MemoryAuditEntry entry) {
    final title = _titleFor(entry.action);
    final lines = <String>[];
    final content = _contentText(entry);
    final confidence = _confidenceLabel(entry.payload['confidence']);

    switch (entry.action) {
      case 'memory.search':
        final count =
            _intPayload(entry.payload, 'resultCount') ??
            _listPayload(entry.payload, 'memoryIds').length;
        lines.add('检索了 $count 条记忆');
        final hits = _hitTexts(entry);
        if (hits.isNotEmpty) {
          lines.add('命中：${hits.take(3).join('、')}');
        }
      case 'candidate.auto_approve':
        if (content != null) lines.add('内容：$content');
        lines.add('来源：对话提取器');
        if (confidence != null) lines.add('置信度：$confidence');
      case 'candidate.create':
        if (content != null) lines.add('内容：$content');
        lines.add('来源：对话提取器');
        if (confidence != null) lines.add('置信度：$confidence');
      case 'memory.create':
        if (content != null) lines.add('内容：$content');
        lines.add('来源：${_sourceLabel(entry.payload['source'], entry.actor)}');
      case 'memory.update':
      case 'memory.summarize':
        if (content != null) lines.add('内容：$content');
        lines.add('操作人：${_actorLabel(entry.actor)}');
      case 'memory.disable':
        if (content != null) lines.add('内容：$content');
        lines.add('结果：已从检索中移除');
      case 'memory.expire':
        if (content != null) lines.add('内容：$content');
        lines.add('结果：已按过期规则禁用');
      case 'memory.delete':
        if (content != null) lines.add('内容：$content');
        lines.add('方式：${_operationMethod(entry)}');
      case 'memory.merge':
        if (content != null) lines.add('内容：$content');
        lines.add('结果：已合并重复或相近记忆');
        lines.add('方式：${_operationMethod(entry)}');
      case 'change_request.create':
        lines.add('动作：${entry.payload['action'] ?? 'unknown'}');
        if (content != null) lines.add('建议：$content');
        if (confidence != null) lines.add('置信度：$confidence');
      case 'change_request.approve':
        lines.add('动作：${entry.payload['action'] ?? 'unknown'}');
        lines.add('操作人：${_actorLabel(entry.actor)}');
      case 'change_request.reject':
        lines.add('操作人：${_actorLabel(entry.actor)}');
      case 'maintenance.run':
        lines.add(
          '自动应用 ${_intPayload(entry.payload, 'autoApplied') ?? 0} · '
          '待核查 ${_intPayload(entry.payload, 'needsReview') ?? 0} · '
          '跳过 ${_intPayload(entry.payload, 'skipped') ?? 0}',
        );
      case 'maintenance.auto_approve':
        lines.add('动作：${entry.payload['action'] ?? 'unknown'}');
        if (confidence != null) lines.add('置信度：$confidence');
      case 'candidate.skip_duplicate':
        lines.add('原因：已有相同或更高层级记忆');
      case 'candidate.skip_below_auto_threshold':
        lines.add('原因：低于自动保存阈值');
        if (confidence != null) lines.add('置信度：$confidence');
      default:
        if (content != null) lines.add('内容：$content');
        lines.add('操作人：${_actorLabel(entry.actor)}');
    }

    return _AuditPresentation(
      title: title,
      lines: lines,
      timeLabel: _timeLabel(entry.createdAt),
      detailText: _detailText(entry),
      hasDetails: _hasDetails(entry),
    );
  }

  static String _titleFor(String action) {
    return switch (action) {
      'candidate.create' => '已创建候选记忆',
      'candidate.auto_approve' => '已自动保存记忆',
      'candidate.skip_duplicate' => '已跳过重复记忆',
      'candidate.skip_below_auto_threshold' => '已跳过低置信记忆',
      'memory.create' => '已保存记忆',
      'memory.update' => '已更新记忆',
      'memory.summarize' => '已摘要记忆',
      'memory.disable' => '已禁用记忆',
      'memory.expire' => '已过期记忆',
      'memory.delete' => '已删除记忆',
      'memory.merge' => '已合并记忆',
      'memory.search' => '已检索记忆',
      'change_request.create' => '已生成整理建议',
      'change_request.approve' => '已批准变更',
      'change_request.reject' => '已拒绝变更',
      'maintenance.run' => '已整理记忆',
      'maintenance.auto_approve' => '已自动应用整理',
      _ => '记忆事件',
    };
  }

  static String? _contentText(MemoryAuditEntry entry) {
    for (final key in const [
      'text',
      'memoryText',
      'proposedText',
      'targetMemoryText',
      'summary',
    ]) {
      final value = entry.payload[key];
      if (value is String && value.trim().isNotEmpty) return value.trim();
    }
    final hits = _hitTexts(entry);
    return hits.isEmpty ? null : hits.first;
  }

  static List<String> _hitTexts(MemoryAuditEntry entry) {
    final hits = _listPayload(entry.payload, 'hits');
    final texts = <String>[];
    for (final hit in hits) {
      if (hit is Map) {
        final text = hit['text'];
        if (text is String && text.trim().isNotEmpty) {
          texts.add(text.trim());
        }
      } else if (hit is String && hit.trim().isNotEmpty) {
        texts.add(hit.trim());
      }
    }
    final memoryTexts = _listPayload(entry.payload, 'memoryTexts');
    for (final text in memoryTexts) {
      if (text is String && text.trim().isNotEmpty) {
        texts.add(text.trim());
      }
    }
    return texts;
  }

  static List<Object?> _listPayload(Map<String, Object?> payload, String key) {
    final value = payload[key];
    return value is List ? value.cast<Object?>() : const <Object?>[];
  }

  static int? _intPayload(Map<String, Object?> payload, String key) {
    final value = payload[key];
    if (value is int) return value;
    if (value is num) return value.toInt();
    return null;
  }

  static String? _confidenceLabel(Object? value) {
    if (value is! num) return null;
    final percent = (value.clamp(0, 1) * 100).round();
    return '$percent%';
  }

  static String _sourceLabel(Object? value, String actor) {
    if (value is String) {
      return switch (value) {
        'manual' => '手动保存',
        'maintenance' => '记忆整理器',
        'extractor' => '对话提取器',
        _ => value,
      };
    }
    return _actorLabel(actor);
  }

  static String _operationMethod(MemoryAuditEntry entry) {
    if (entry.changeRequestId?.trim().isNotEmpty == true) {
      return 'Change request 审批';
    }
    return _actorLabel(entry.actor);
  }

  static String _actorLabel(String actor) {
    return switch (actor) {
      'system' => '系统',
      'user' => '用户',
      'extractor' => '对话提取器',
      'maintenance' => '记忆整理器',
      _ => actor.isEmpty ? '未知' : actor,
    };
  }

  static String _timeLabel(int createdAt) {
    if (createdAt <= 0) return '未知';
    final time = DateTime.fromMillisecondsSinceEpoch(createdAt).toLocal();
    final now = DateTime.now();
    final delta = now.difference(time);
    if (!delta.isNegative && delta.inSeconds < 60) return '刚刚';
    if (!delta.isNegative && delta.inMinutes < 60) {
      return '${delta.inMinutes} 分钟前';
    }
    if (time.year == now.year &&
        time.month == now.month &&
        time.day == now.day) {
      return _two(time.hour) + ':' + _two(time.minute);
    }
    return '${time.year}-${_two(time.month)}-${_two(time.day)} '
        '${_two(time.hour)}:${_two(time.minute)}';
  }

  static String _two(int value) => value.toString().padLeft(2, '0');

  static bool _hasDetails(MemoryAuditEntry entry) {
    return entry.action.isNotEmpty ||
        entry.actor.isNotEmpty ||
        entry.memoryId?.trim().isNotEmpty == true ||
        entry.candidateId?.trim().isNotEmpty == true ||
        entry.changeRequestId?.trim().isNotEmpty == true ||
        entry.payload.isNotEmpty;
  }

  static String _detailText(MemoryAuditEntry entry) {
    return const JsonEncoder.withIndent('  ').convert(<String, Object?>{
      'action': entry.action,
      'actor': entry.actor,
      if (entry.memoryId?.trim().isNotEmpty == true) 'memoryId': entry.memoryId,
      if (entry.candidateId?.trim().isNotEmpty == true)
        'candidateId': entry.candidateId,
      if (entry.changeRequestId?.trim().isNotEmpty == true)
        'changeRequestId': entry.changeRequestId,
      if (entry.payload.isNotEmpty) 'payload': entry.payload,
    });
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: const TextStyle(
        color: AppColors.primaryDark,
        fontSize: 11,
        fontWeight: FontWeight.w900,
        letterSpacing: 0,
      ),
    );
  }
}
