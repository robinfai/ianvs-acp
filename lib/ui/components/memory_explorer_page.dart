import 'package:flutter/material.dart';

import '../../memory/memory_api_client.dart';
import '../theme/app_design_tokens.dart';

class MemoryExplorerActions {
  const MemoryExplorerActions({
    required this.loadMemory,
    required this.loadCandidates,
    required this.loadChangeRequests,
    required this.loadAudit,
    required this.approveCandidate,
    required this.rejectCandidate,
    required this.approveChangeRequest,
    required this.rejectChangeRequest,
    required this.runMaintenance,
    required this.clearData,
    this.updateChangeRequest,
    this.updateMemory,
    this.disableMemory,
    this.restoreMemory,
    this.submitFeedback,
    this.maintenanceEnabled = true,
    this.maintenanceMaxItemsPerBatch = 12,
  });

  final Future<List<MemoryRecord>> Function() loadMemory;
  final Future<List<MemoryCandidate>> Function() loadCandidates;
  final Future<List<MemoryChangeRequest>> Function() loadChangeRequests;
  final Future<List<MemoryAuditEvent>> Function() loadAudit;
  final Future<void> Function(MemoryCandidate candidate) approveCandidate;
  final Future<void> Function(MemoryCandidate candidate) rejectCandidate;
  final Future<void> Function(MemoryChangeRequest request) approveChangeRequest;
  final Future<void> Function(MemoryChangeRequest request) rejectChangeRequest;
  final Future<MemoryChangeRequest> Function(MemoryChangeRequest request)?
  updateChangeRequest;
  final Future<void> Function(MemoryRecord record)? updateMemory;
  final Future<void> Function(MemoryRecord record)? disableMemory;
  final Future<void> Function(MemoryRecord record)? restoreMemory;
  final Future<void> Function(
    MemoryRecord record,
    String rating,
    String? reason,
  )?
  submitFeedback;
  final Future<MaintenanceRunResult> Function() runMaintenance;
  final Future<MemoryClearResult> Function(String level) clearData;
  final bool maintenanceEnabled;
  final int maintenanceMaxItemsPerBatch;
}

enum MemoryExplorerInitialTab {
  allMemory,
  candidates,
  changeRequests,
  auditLog,
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

class _MemoryExplorerPageState extends State<MemoryExplorerPage>
    with SingleTickerProviderStateMixin {
  Future<List<MemoryRecord>>? _memoryFuture;
  Future<List<MemoryCandidate>>? _candidateFuture;
  Future<List<MemoryChangeRequest>>? _changeRequestFuture;
  Future<List<MemoryAuditEvent>>? _auditFuture;
  late final TabController _tabController;
  final Map<String, MemoryCandidate> _candidateEdits =
      <String, MemoryCandidate>{};
  final Map<String, MemoryChangeRequest> _changeRequestEdits =
      <String, MemoryChangeRequest>{};
  late final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  String _auditFilter = _AuditFilter.all;
  String? _busyMemoryId;
  String? _busyCandidateId;
  String? _busyChangeRequestId;
  bool _organizing = false;
  bool _clearingData = false;
  MemoryExplorerInitialTab? _organizeReviewTab;
  String? _organizeSummary;
  String? _clearSummary;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 4,
      vsync: this,
      initialIndex: widget.initialTab.index,
    );
    _reloadAll();
  }

  @override
  void didUpdateWidget(covariant MemoryExplorerPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialTab != widget.initialTab) {
      _tabController.animateTo(widget.initialTab.index);
    }
    if (oldWidget.actions != widget.actions) {
      setState(_reloadAll);
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
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
              onPressed: _clearDataHandler(),
              icon: const Icon(Icons.delete_outline_rounded, size: 18),
              label: const Text('Clear data'),
            ),
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          labelColor: AppColors.primaryDark,
          unselectedLabelColor: AppColors.textSecondary,
          indicatorColor: AppColors.primaryDark,
          tabs: const [
            Tab(text: 'All memory'),
            Tab(text: 'Candidates'),
            Tab(text: 'Change requests'),
            Tab(text: 'Audit log'),
          ],
        ),
      ),
      body: Column(
        children: [
          if (widget.actions != null)
            _MemorySearchField(
              controller: _searchController,
              onChanged: (value) => setState(() => _searchQuery = value),
              onClear: () {
                _searchController.clear();
                setState(() => _searchQuery = '');
              },
            ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildMemoryPane(),
                _buildCandidatesPane(),
                _buildChangeRequestsPane(),
                _buildAuditPane(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMemoryPane() {
    if (widget.actions == null) {
      return const _MemoryExplorerPane(message: 'Memory is not connected yet.');
    }
    return FutureBuilder<List<MemoryRecord>>(
      future: _memoryFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const _LoadingPane();
        }
        if (snapshot.hasError) {
          return _ErrorPane(message: '${snapshot.error}');
        }
        final items = _filterMemoryRecords(
          snapshot.data ?? const <MemoryRecord>[],
        );
        return _ListSurface(
          children: [
            _MemoryPaneHeader(
              organizing: _organizing,
              summary: _clearSummary ?? _organizeSummary,
              reviewTab: _clearSummary == null ? _organizeReviewTab : null,
              maintenanceEnabled: widget.actions?.maintenanceEnabled ?? true,
              maintenanceMaxItemsPerBatch:
                  widget.actions?.maintenanceMaxItemsPerBatch ?? 12,
              onOrganize: widget.actions?.maintenanceEnabled == false
                  ? null
                  : _organizeMemory,
              onReview: _showOrganizeReviewTab,
            ),
            if (items.isEmpty)
              _InlineEmptyState(
                message: _hasSearchQuery
                    ? 'No matching memory records.'
                    : 'No memory records yet.',
              )
            else
              for (final item in items)
                Builder(
                  builder: (context) {
                    final status = item.status.trim().toLowerCase();
                    return _MemoryRecordCard(
                      record: item,
                      busy: _busyMemoryId == item.id,
                      onEdit:
                          widget.actions?.updateMemory == null ||
                              status != 'active'
                          ? null
                          : () => _editMemoryRecord(item),
                      onDisable:
                          widget.actions?.disableMemory == null ||
                              status != 'active'
                          ? null
                          : () => _disableMemoryRecord(item),
                      onRestore:
                          widget.actions?.restoreMemory == null ||
                              status != 'disabled'
                          ? null
                          : () => _restoreMemoryRecord(item),
                      onHelpful:
                          widget.actions?.submitFeedback == null ||
                              status != 'active'
                          ? null
                          : () => _submitMemoryFeedback(
                              item,
                              'helpful',
                              'Marked helpful from Memory Explorer.',
                            ),
                      onNotRelevant:
                          widget.actions?.submitFeedback == null ||
                              status != 'active'
                          ? null
                          : () => _submitMemoryFeedback(
                              item,
                              'not_relevant',
                              'Marked not relevant from Memory Explorer.',
                            ),
                      onStale:
                          widget.actions?.submitFeedback == null ||
                              status != 'active'
                          ? null
                          : () => _submitMemoryFeedback(
                              item,
                              'stale',
                              'Marked stale from Memory Explorer.',
                            ),
                    );
                  },
                ),
          ],
        );
      },
    );
  }

  VoidCallback? _clearDataHandler() {
    if (_clearingData) return null;
    if (widget.actions != null) return _confirmClearData;
    return widget.onClearData;
  }

  Widget _buildCandidatesPane() {
    if (widget.actions == null) {
      return const _MemoryExplorerPane(message: 'Memory is not connected yet.');
    }
    return FutureBuilder<List<MemoryCandidate>>(
      future: _candidateFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const _LoadingPane();
        }
        if (snapshot.hasError) {
          return _ErrorPane(message: '${snapshot.error}');
        }
        final candidates = _filterCandidates(
          snapshot.data ?? const <MemoryCandidate>[],
        );
        if (candidates.isEmpty) {
          return _MemoryExplorerPane(
            message: _hasSearchQuery
                ? 'No matching candidates.'
                : 'No candidates yet.',
          );
        }
        final pendingCandidates = candidates
            .where((candidate) {
              final current = _candidateEdits[candidate.id] ?? candidate;
              return current.status.trim().toLowerCase() == 'pending';
            })
            .toList(growable: false);
        return _ListSurface(
          children: [
            if (pendingCandidates.isNotEmpty)
              _BulkReviewBar(
                label: '${pendingCandidates.length} visible pending candidates',
                approving: _busyCandidateId != null,
                rejecting: _busyCandidateId != null,
                onApprove: () => _approveVisibleCandidates(pendingCandidates),
                onReject: () => _rejectVisibleCandidates(pendingCandidates),
              ),
            for (final candidate in candidates)
              _MemoryCandidateCard(
                candidate: _candidateEdits[candidate.id] ?? candidate,
                busy: _busyCandidateId == candidate.id,
                edited: _candidateEdits.containsKey(candidate.id),
                onApprove: () => _approveCandidate(candidate),
                onReject: () => _rejectCandidate(candidate),
                onEdit: () => _editCandidate(candidate),
              ),
          ],
        );
      },
    );
  }

  Widget _buildChangeRequestsPane() {
    if (widget.actions == null) {
      return const _MemoryExplorerPane(message: 'Memory is not connected yet.');
    }
    return FutureBuilder<List<MemoryChangeRequest>>(
      future: _changeRequestFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const _LoadingPane();
        }
        if (snapshot.hasError) {
          return _ErrorPane(message: '${snapshot.error}');
        }
        final requests = _filterChangeRequests(
          snapshot.data ?? const <MemoryChangeRequest>[],
        );
        if (requests.isEmpty) {
          return _MemoryExplorerPane(
            message: _hasSearchQuery
                ? 'No matching change requests.'
                : 'No change requests yet.',
          );
        }
        final pendingRequests = requests
            .where((request) {
              final current = _changeRequestEdits[request.id] ?? request;
              return current.status.trim().toLowerCase() == 'pending';
            })
            .toList(growable: false);
        return _ListSurface(
          children: [
            if (pendingRequests.isNotEmpty)
              _BulkReviewBar(
                label: '${pendingRequests.length} visible pending requests',
                approving: _busyChangeRequestId != null,
                rejecting: _busyChangeRequestId != null,
                onApprove: () => _approveVisibleChangeRequests(pendingRequests),
                onReject: () => _rejectVisibleChangeRequests(pendingRequests),
              ),
            for (final request in requests)
              _MemoryChangeRequestCard(
                request: _changeRequestEdits[request.id] ?? request,
                busy: _busyChangeRequestId == request.id,
                edited: _changeRequestEdits.containsKey(request.id),
                onApprove: () => _approveChangeRequest(request),
                onReject: () => _rejectChangeRequest(request),
                onEdit: () => _editChangeRequest(request),
              ),
          ],
        );
      },
    );
  }

  Widget _buildAuditPane() {
    if (widget.actions == null) {
      return const _MemoryExplorerPane(message: 'Memory is not connected yet.');
    }
    return FutureBuilder<List<MemoryAuditEvent>>(
      future: _auditFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const _LoadingPane();
        }
        if (snapshot.hasError) {
          return _ErrorPane(message: '${snapshot.error}');
        }
        final allEvents = snapshot.data ?? const <MemoryAuditEvent>[];
        final events = _filterAuditEvents(allEvents);
        if (allEvents.isEmpty) {
          return _MemoryExplorerPane(
            message: _hasSearchQuery
                ? 'No matching audit events.'
                : 'No audit events yet.',
          );
        }
        return _ListSurface(
          children: [
            _AuditFilterBar(
              selected: _auditFilter,
              onChanged: (value) => setState(() => _auditFilter = value),
            ),
            if (events.isEmpty)
              _InlineEmptyState(
                message: _hasSearchQuery || _auditFilter != _AuditFilter.all
                    ? 'No matching audit events.'
                    : 'No audit events yet.',
              )
            else
              for (final event in events) _MemoryAuditEventCard(event: event),
          ],
        );
      },
    );
  }

  bool get _hasSearchQuery => _searchQuery.trim().isNotEmpty;

  List<MemoryRecord> _filterMemoryRecords(List<MemoryRecord> records) {
    final query = _searchQuery.trim().toLowerCase();
    if (query.isEmpty) return records;
    return records
        .where((record) {
          return _matchesSearch(
            query,
            _joinSearchFields([
              record.id,
              record.kind,
              record.scope,
              record.status,
              record.text,
              record.userId,
              record.workspaceId,
              record.repoId,
              record.agentId,
              record.sessionId,
              record.source,
              record.sourceSessionId,
              record.sourceTurnId,
              _memoryProfileBlockLabel(record),
              _memorySourceTurnLabel(record),
            ]),
          );
        })
        .toList(growable: false);
  }

  List<MemoryCandidate> _filterCandidates(List<MemoryCandidate> candidates) {
    final query = _searchQuery.trim().toLowerCase();
    if (query.isEmpty) return candidates;
    return candidates
        .where((candidate) {
          final current = _candidateEdits[candidate.id] ?? candidate;
          return _matchesSearch(
            query,
            _joinSearchFields([
              current.id,
              current.kind,
              current.scope,
              current.status,
              current.text,
              current.reason,
              current.confidence,
              ...current.instructionScopes,
            ]),
          );
        })
        .toList(growable: false);
  }

  List<MemoryChangeRequest> _filterChangeRequests(
    List<MemoryChangeRequest> requests,
  ) {
    final query = _searchQuery.trim().toLowerCase();
    if (query.isEmpty) return requests;
    return requests
        .where((request) {
          final current = _changeRequestEdits[request.id] ?? request;
          return _matchesSearch(
            query,
            _joinSearchFields([
              current.id,
              current.action,
              current.status,
              current.targetMemoryText,
              current.proposedKind,
              current.proposedScope,
              current.proposedText,
              current.reason,
              current.confidence,
              ...current.targetMemoryIds,
            ]),
          );
        })
        .toList(growable: false);
  }

  List<MemoryAuditEvent> _filterAuditEvents(List<MemoryAuditEvent> events) {
    final query = _searchQuery.trim().toLowerCase();
    return events
        .where((event) {
          if (!_matchesAuditFilter(event, _auditFilter)) return false;
          if (query.isEmpty) return true;
          return _matchesSearch(
            query,
            _joinSearchFields([
              event.id,
              event.actor,
              event.action,
              event.memoryId,
              event.candidateId,
              event.changeRequestId,
              event.memoryText,
              event.candidateText,
              event.changeRequestText,
              event.payload,
            ]),
          );
        })
        .toList(growable: false);
  }

  bool _matchesAuditFilter(MemoryAuditEvent event, String filter) {
    if (filter == _AuditFilter.all) return true;
    return _auditFilterForAction(event.action) == filter;
  }

  bool _matchesSearch(String query, String text) {
    return text.toLowerCase().contains(query);
  }

  String _joinSearchFields(Iterable<Object?> fields) {
    return fields
        .whereType<Object>()
        .map((field) => field.toString().trim())
        .where((field) => field.isNotEmpty)
        .join(' ');
  }

  void _reloadAll() {
    final actions = widget.actions;
    if (actions == null) return;
    _memoryFuture = actions.loadMemory();
    _candidateFuture = actions.loadCandidates();
    _changeRequestFuture = actions.loadChangeRequests();
    _auditFuture = actions.loadAudit();
  }

  void _reloadAfterReview() {
    final actions = widget.actions;
    if (actions == null || !mounted) return;
    setState(() {
      _memoryFuture = actions.loadMemory();
      _candidateFuture = actions.loadCandidates();
      _changeRequestFuture = actions.loadChangeRequests();
      _auditFuture = actions.loadAudit();
    });
  }

  Future<void> _organizeMemory() async {
    final actions = widget.actions;
    if (actions == null || _organizing) return;
    setState(() {
      _organizing = true;
      _organizeReviewTab = null;
      _organizeSummary = null;
    });
    try {
      final result = await actions.runMaintenance();
      if (!mounted) return;
      setState(() {
        _organizeSummary = _maintenanceSummary(result);
        _organizeReviewTab = _organizeReviewTabFor(result);
        _memoryFuture = actions.loadMemory();
        _candidateFuture = actions.loadCandidates();
        _changeRequestFuture = actions.loadChangeRequests();
        _auditFuture = actions.loadAudit();
      });
    } finally {
      if (mounted) setState(() => _organizing = false);
    }
  }

  String _maintenanceSummary(MaintenanceRunResult result) {
    final parts = <String>[
      '${result.autoApplied} auto applied',
      '${result.needsReview} need review',
    ];
    if (result.autoCleaned > 0) {
      parts.add('${result.autoCleaned} cleaned');
    }
    parts.add('${result.skipped} skipped');
    return parts.join(' · ');
  }

  MemoryExplorerInitialTab? _organizeReviewTabFor(MaintenanceRunResult result) {
    if (result.needsReview > 0 ||
        result.autoApplied > 0 ||
        result.existingAutoApprovedChangeRequests > 0 ||
        result.autoRejectedChangeRequests > 0) {
      return MemoryExplorerInitialTab.changeRequests;
    }
    if (result.autoRejectedCandidates > 0) {
      return MemoryExplorerInitialTab.candidates;
    }
    return null;
  }

  void _showOrganizeReviewTab(MemoryExplorerInitialTab tab) {
    setState(() => _tabController.index = tab.index);
  }

  Future<void> _confirmClearData() async {
    final actions = widget.actions;
    if (actions == null || _clearingData) return;
    final level = await showDialog<String>(
      context: context,
      builder: (context) => const _ClearDataDialog(),
    );
    if (level == null || !mounted) return;
    setState(() {
      _clearingData = true;
      _organizeReviewTab = null;
      _clearSummary = null;
    });
    try {
      final result = await actions.clearData(level);
      if (!mounted) return;
      setState(() {
        _clearSummary =
            '${result.clearedMemory} memory cleared · '
            '${result.rejectedCandidates} candidates rejected · '
            '${result.rejectedChangeRequests} change requests rejected';
        _memoryFuture = actions.loadMemory();
        _candidateFuture = actions.loadCandidates();
        _changeRequestFuture = actions.loadChangeRequests();
        _auditFuture = actions.loadAudit();
      });
    } finally {
      if (mounted) setState(() => _clearingData = false);
    }
  }

  Future<void> _approveCandidate(MemoryCandidate candidate) async {
    final actions = widget.actions;
    if (actions == null || _busyCandidateId != null) return;
    final reviewedCandidate = _candidateEdits[candidate.id] ?? candidate;
    setState(() => _busyCandidateId = candidate.id);
    try {
      await actions.approveCandidate(reviewedCandidate);
      _candidateEdits.remove(candidate.id);
      _reloadAfterReview();
    } finally {
      if (mounted) setState(() => _busyCandidateId = null);
    }
  }

  Future<void> _rejectCandidate(MemoryCandidate candidate) async {
    final actions = widget.actions;
    if (actions == null || _busyCandidateId != null) return;
    setState(() => _busyCandidateId = candidate.id);
    try {
      await actions.rejectCandidate(candidate);
      _candidateEdits.remove(candidate.id);
      _reloadAfterReview();
    } finally {
      if (mounted) setState(() => _busyCandidateId = null);
    }
  }

  Future<void> _approveVisibleCandidates(
    List<MemoryCandidate> candidates,
  ) async {
    final actions = widget.actions;
    if (actions == null || _busyCandidateId != null) return;
    setState(() => _busyCandidateId = '__bulk_candidates__');
    try {
      for (final candidate in candidates) {
        final reviewedCandidate = _candidateEdits[candidate.id] ?? candidate;
        await actions.approveCandidate(reviewedCandidate);
        _candidateEdits.remove(candidate.id);
      }
      _reloadAfterReview();
    } finally {
      if (mounted) setState(() => _busyCandidateId = null);
    }
  }

  Future<void> _rejectVisibleCandidates(
    List<MemoryCandidate> candidates,
  ) async {
    final actions = widget.actions;
    if (actions == null || _busyCandidateId != null) return;
    setState(() => _busyCandidateId = '__bulk_candidates__');
    try {
      for (final candidate in candidates) {
        await actions.rejectCandidate(candidate);
        _candidateEdits.remove(candidate.id);
      }
      _reloadAfterReview();
    } finally {
      if (mounted) setState(() => _busyCandidateId = null);
    }
  }

  Future<void> _editCandidate(MemoryCandidate candidate) async {
    final current = _candidateEdits[candidate.id] ?? candidate;
    final edited = await showDialog<MemoryCandidate>(
      context: context,
      builder: (context) => _CandidateEditorDialog(candidate: current),
    );
    if (edited == null || !mounted) return;
    setState(() => _candidateEdits[candidate.id] = edited);
  }

  Future<void> _approveChangeRequest(MemoryChangeRequest request) async {
    final actions = widget.actions;
    if (actions == null || _busyChangeRequestId != null) return;
    final reviewedRequest = _changeRequestEdits[request.id] ?? request;
    setState(() => _busyChangeRequestId = request.id);
    try {
      await actions.approveChangeRequest(reviewedRequest);
      _changeRequestEdits.remove(request.id);
      _reloadAfterReview();
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
      _changeRequestEdits.remove(request.id);
      _reloadAfterReview();
    } finally {
      if (mounted) setState(() => _busyChangeRequestId = null);
    }
  }

  Future<void> _approveVisibleChangeRequests(
    List<MemoryChangeRequest> requests,
  ) async {
    final actions = widget.actions;
    if (actions == null || _busyChangeRequestId != null) return;
    setState(() => _busyChangeRequestId = '__bulk_change_requests__');
    try {
      for (final request in requests) {
        final reviewedRequest = _changeRequestEdits[request.id] ?? request;
        await actions.approveChangeRequest(reviewedRequest);
        _changeRequestEdits.remove(request.id);
      }
      _reloadAfterReview();
    } finally {
      if (mounted) setState(() => _busyChangeRequestId = null);
    }
  }

  Future<void> _rejectVisibleChangeRequests(
    List<MemoryChangeRequest> requests,
  ) async {
    final actions = widget.actions;
    if (actions == null || _busyChangeRequestId != null) return;
    setState(() => _busyChangeRequestId = '__bulk_change_requests__');
    try {
      for (final request in requests) {
        await actions.rejectChangeRequest(request);
        _changeRequestEdits.remove(request.id);
      }
      _reloadAfterReview();
    } finally {
      if (mounted) setState(() => _busyChangeRequestId = null);
    }
  }

  Future<void> _editChangeRequest(MemoryChangeRequest request) async {
    final current = _changeRequestEdits[request.id] ?? request;
    final edited = await showDialog<MemoryChangeRequest>(
      context: context,
      builder: (context) => _ChangeRequestEditorDialog(request: current),
    );
    if (edited == null || !mounted) return;
    final updateChangeRequest = widget.actions?.updateChangeRequest;
    if (updateChangeRequest == null) {
      setState(() => _changeRequestEdits[request.id] = edited);
      return;
    }
    setState(() => _busyChangeRequestId = request.id);
    try {
      final saved = await updateChangeRequest(edited);
      _changeRequestEdits.remove(request.id);
      _changeRequestEdits.remove(saved.id);
      _reloadAfterReview();
    } finally {
      if (mounted) setState(() => _busyChangeRequestId = null);
    }
  }

  Future<void> _editMemoryRecord(MemoryRecord record) async {
    final actions = widget.actions;
    final updateMemory = actions?.updateMemory;
    if (actions == null || updateMemory == null || _busyMemoryId != null) {
      return;
    }
    final edited = await showDialog<MemoryRecord>(
      context: context,
      builder: (context) => _MemoryRecordEditorDialog(record: record),
    );
    if (edited == null || !mounted) return;
    setState(() => _busyMemoryId = record.id);
    try {
      await updateMemory(edited);
      _reloadAfterReview();
    } finally {
      if (mounted) setState(() => _busyMemoryId = null);
    }
  }

  Future<void> _disableMemoryRecord(MemoryRecord record) async {
    final actions = widget.actions;
    final disableMemory = actions?.disableMemory;
    if (actions == null || disableMemory == null || _busyMemoryId != null) {
      return;
    }
    setState(() => _busyMemoryId = record.id);
    try {
      await disableMemory(record);
      _reloadAfterReview();
    } finally {
      if (mounted) setState(() => _busyMemoryId = null);
    }
  }

  Future<void> _restoreMemoryRecord(MemoryRecord record) async {
    final actions = widget.actions;
    final restoreMemory = actions?.restoreMemory;
    if (actions == null || restoreMemory == null || _busyMemoryId != null) {
      return;
    }
    setState(() => _busyMemoryId = record.id);
    try {
      await restoreMemory(record);
      _reloadAfterReview();
    } finally {
      if (mounted) setState(() => _busyMemoryId = null);
    }
  }

  Future<void> _submitMemoryFeedback(
    MemoryRecord record,
    String rating,
    String? reason,
  ) async {
    final actions = widget.actions;
    final submitFeedback = actions?.submitFeedback;
    if (actions == null || submitFeedback == null || _busyMemoryId != null) {
      return;
    }
    setState(() => _busyMemoryId = record.id);
    try {
      await submitFeedback(record, rating, reason);
      _reloadAfterReview();
    } finally {
      if (mounted) setState(() => _busyMemoryId = null);
    }
  }
}

class _ListSurface extends StatelessWidget {
  const _ListSurface({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.all(18),
      itemBuilder: (context, index) => children[index],
      separatorBuilder: (context, index) => const SizedBox(height: 10),
      itemCount: children.length,
    );
  }
}

class _MemorySearchField extends StatelessWidget {
  const _MemorySearchField({
    required this.controller,
    required this.onChanged,
    required this.onClear,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final hasText = controller.text.trim().isNotEmpty;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
      decoration: const BoxDecoration(
        color: AppColors.bg,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: TextField(
        key: const Key('memory-search-field'),
        controller: controller,
        onChanged: onChanged,
        decoration: InputDecoration(
          isDense: true,
          hintText: 'Search memory',
          prefixIcon: const Icon(Icons.search_rounded, size: 18),
          suffixIcon: hasText
              ? IconButton(
                  tooltip: 'Clear search',
                  onPressed: onClear,
                  icon: const Icon(Icons.close_rounded, size: 18),
                )
              : null,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
        ),
      ),
    );
  }
}

class _BulkReviewBar extends StatelessWidget {
  const _BulkReviewBar({
    required this.label,
    required this.approving,
    required this.rejecting,
    required this.onApprove,
    required this.onReject,
  });

  final String label;
  final bool approving;
  final bool rejecting;
  final VoidCallback onApprove;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    final busy = approving || rejecting;
    return _ExplorerCard(
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w800,
                letterSpacing: 0,
              ),
            ),
          ),
          OutlinedButton(
            onPressed: busy ? null : onReject,
            child: const Text('Reject visible'),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            onPressed: busy ? null : onApprove,
            child: busy
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Approve visible'),
          ),
        ],
      ),
    );
  }
}

class _ClearDataDialog extends StatefulWidget {
  const _ClearDataDialog();

  @override
  State<_ClearDataDialog> createState() => _ClearDataDialogState();
}

class _ClearDataDialogState extends State<_ClearDataDialog> {
  String _level = 'repo';

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Clear memory data'),
      content: SizedBox(
        width: 420,
        child: DropdownButtonFormField<String>(
          initialValue: _level,
          decoration: const InputDecoration(labelText: 'Scope'),
          items: const [
            DropdownMenuItem(value: 'session', child: Text('Current session')),
            DropdownMenuItem(value: 'repo', child: Text('Current repo')),
            DropdownMenuItem(
              value: 'workspace',
              child: Text('Current workspace'),
            ),
            DropdownMenuItem(value: 'all', child: Text('All local memory')),
          ],
          onChanged: (value) {
            if (value != null) setState(() => _level = value);
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_level),
          child: const Text('Clear'),
        ),
      ],
    );
  }
}

class _MemoryPaneHeader extends StatelessWidget {
  const _MemoryPaneHeader({
    required this.organizing,
    required this.summary,
    required this.reviewTab,
    required this.maintenanceEnabled,
    required this.maintenanceMaxItemsPerBatch,
    required this.onOrganize,
    required this.onReview,
  });

  final bool organizing;
  final String? summary;
  final MemoryExplorerInitialTab? reviewTab;
  final bool maintenanceEnabled;
  final int maintenanceMaxItemsPerBatch;
  final VoidCallback? onOrganize;
  final ValueChanged<MemoryExplorerInitialTab> onReview;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: summary?.trim().isNotEmpty == true || !maintenanceEnabled
              ? Text(
                  maintenanceEnabled ? summary! : 'Maintenance disabled',
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0,
                  ),
                )
              : const SizedBox.shrink(),
        ),
        if (reviewTab != null) ...[
          TextButton.icon(
            onPressed: () => onReview(reviewTab!),
            icon: const Icon(Icons.rate_review_outlined, size: 18),
            label: Text(
              reviewTab == MemoryExplorerInitialTab.candidates
                  ? 'Review candidates'
                  : 'Review changes',
            ),
          ),
          const SizedBox(width: 8),
        ],
        Tooltip(
          message:
              'Organizes the latest $maintenanceMaxItemsPerBatch scoped memory items',
          child: OutlinedButton.icon(
            onPressed: organizing ? null : onOrganize,
            icon: organizing
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.auto_fix_high_rounded, size: 18),
            label: const Text('Organize'),
          ),
        ),
      ],
    );
  }
}

class _AuditFilter {
  const _AuditFilter._();

  static const String all = 'all';
  static const String retrieval = 'retrieval';
  static const String memory = 'memory';
  static const String candidates = 'candidates';
  static const String changeRequests = 'change_requests';
  static const String maintenance = 'maintenance';
  static const String clear = 'clear';

  static const List<(String, String)> options = [
    (all, 'All'),
    (retrieval, 'Retrieval'),
    (memory, 'Memory changes'),
    (candidates, 'Candidate events'),
    (changeRequests, 'Change reqs'),
    (maintenance, 'Maintenance'),
    (clear, 'Clear'),
  ];
}

String _auditFilterForAction(String action) {
  final normalized = action.trim().toLowerCase();
  if (normalized == 'memory.retrieve') return _AuditFilter.retrieval;
  if (normalized.startsWith('candidate.')) return _AuditFilter.candidates;
  if (normalized.startsWith('change_request.')) {
    return _AuditFilter.changeRequests;
  }
  if (normalized.startsWith('maintenance.')) return _AuditFilter.maintenance;
  if (normalized.contains('clear')) return _AuditFilter.clear;
  if (normalized.startsWith('memory.')) return _AuditFilter.memory;
  return _AuditFilter.memory;
}

class _AuditFilterBar extends StatelessWidget {
  const _AuditFilterBar({required this.selected, required this.onChanged});

  final String selected;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return _ExplorerCard(
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final option in _AuditFilter.options)
            ChoiceChip(
              label: Text(option.$2),
              selected: selected == option.$1,
              onSelected: (_) => onChanged(option.$1),
            ),
        ],
      ),
    );
  }
}

class _InlineEmptyState extends StatelessWidget {
  const _InlineEmptyState({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 64),
      child: Center(
        child: Text(
          message,
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

class _MemoryRecordCard extends StatelessWidget {
  const _MemoryRecordCard({
    required this.record,
    required this.busy,
    required this.onEdit,
    required this.onDisable,
    required this.onRestore,
    required this.onHelpful,
    required this.onNotRelevant,
    required this.onStale,
  });

  final MemoryRecord record;
  final bool busy;
  final VoidCallback? onEdit;
  final VoidCallback? onDisable;
  final VoidCallback? onRestore;
  final VoidCallback? onHelpful;
  final VoidCallback? onNotRelevant;
  final VoidCallback? onStale;

  @override
  Widget build(BuildContext context) {
    final source = record.source.trim();
    final blockLabel = _memoryProfileBlockLabel(record);
    final sourceTurnLabel = _memorySourceTurnLabel(record);
    return _ExplorerCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _MetaLine(
            label: [
              record.kind,
              record.scope,
              record.status,
              if (source.isNotEmpty) source,
              ?blockLabel,
              ?sourceTurnLabel,
            ].join(' · '),
          ),
          const SizedBox(height: 8),
          Text(
            record.text,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w700,
              letterSpacing: 0,
            ),
          ),
          if (onEdit != null ||
              onDisable != null ||
              onRestore != null ||
              onHelpful != null ||
              onNotRelevant != null ||
              onStale != null) ...[
            const SizedBox(height: 10),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 4,
              children: [
                if (onHelpful != null)
                  TextButton(
                    onPressed: busy ? null : onHelpful,
                    child: const Text('Helpful'),
                  ),
                if (onNotRelevant != null)
                  TextButton(
                    onPressed: busy ? null : onNotRelevant,
                    child: const Text('Not relevant'),
                  ),
                if (onStale != null)
                  TextButton(
                    onPressed: busy ? null : onStale,
                    child: const Text('Stale'),
                  ),
                if (onEdit != null)
                  TextButton(
                    onPressed: busy ? null : onEdit,
                    child: const Text('Edit'),
                  ),
                if (onDisable != null)
                  TextButton(
                    onPressed: busy ? null : onDisable,
                    child: busy
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Disable'),
                  ),
                if (onRestore != null)
                  TextButton(
                    onPressed: busy ? null : onRestore,
                    child: busy
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Restore'),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

String? _memoryProfileBlockLabel(MemoryRecord record) {
  if (!record.pinned) return null;
  final label = record.profileBlock?['label'];
  if (label is! String) return null;
  final trimmed = label.trim();
  return trimmed.isEmpty ? null : trimmed;
}

String? _memorySourceTurnLabel(MemoryRecord record) {
  final sourceTurnId = record.sourceTurnId?.trim();
  if (sourceTurnId == null || sourceTurnId.isEmpty) return null;
  return 'turn $sourceTurnId';
}

class _MemoryRecordEditorDialog extends StatefulWidget {
  const _MemoryRecordEditorDialog({required this.record});

  final MemoryRecord record;

  @override
  State<_MemoryRecordEditorDialog> createState() =>
      _MemoryRecordEditorDialogState();
}

class _MemoryRecordEditorDialogState extends State<_MemoryRecordEditorDialog> {
  static const List<String> _kinds = [
    'user_preference',
    'project_rule',
    'architecture_decision',
    'session_summary',
  ];
  static const List<String> _scopes = [
    'global',
    'workspace',
    'repo',
    'session',
  ];

  late String _kind = _knownOrFirst(widget.record.kind, _kinds);
  late String _scope = _knownOrFirst(widget.record.scope, _scopes);
  late final TextEditingController _textController = TextEditingController(
    text: widget.record.text,
  );

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit memory'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              initialValue: _kind,
              decoration: const InputDecoration(labelText: 'Kind'),
              items: [
                for (final kind in _kinds)
                  DropdownMenuItem(value: kind, child: Text(kind)),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _kind = value);
              },
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              initialValue: _scope,
              decoration: const InputDecoration(labelText: 'Scope'),
              items: [
                for (final scope in _scopes)
                  DropdownMenuItem(value: scope, child: Text(scope)),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _scope = value);
              },
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _textController,
              minLines: 3,
              maxLines: 6,
              decoration: const InputDecoration(labelText: 'Text'),
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
            final text = _textController.text.trim();
            if (text.isEmpty) return;
            Navigator.of(context).pop(
              widget.record.copyWith(kind: _kind, scope: _scope, text: text),
            );
          },
          child: const Text('Save'),
        ),
      ],
    );
  }

  static String _knownOrFirst(String value, List<String> values) {
    return values.contains(value) ? value : values.first;
  }
}

class _MemoryAuditEventCard extends StatelessWidget {
  const _MemoryAuditEventCard({required this.event});

  final MemoryAuditEvent event;

  @override
  Widget build(BuildContext context) {
    final text =
        event.memoryText ?? event.candidateText ?? event.changeRequestText;
    final diagnosticsLabel = _diagnosticsLabel(event);
    return _ExplorerCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _MetaLine(label: '${event.action} · ${event.actor}'),
          if (text?.trim().isNotEmpty == true) ...[
            const SizedBox(height: 8),
            Text(
              text!.trim(),
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w700,
                letterSpacing: 0,
              ),
            ),
          ],
          if (diagnosticsLabel != null) ...[
            const SizedBox(height: 6),
            Text(
              diagnosticsLabel,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                letterSpacing: 0,
              ),
            ),
          ],
          if (event.memoryId?.trim().isNotEmpty == true ||
              event.candidateId?.trim().isNotEmpty == true ||
              event.changeRequestId?.trim().isNotEmpty == true) ...[
            const SizedBox(height: 6),
            Text(
              _targetLabel(event),
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                letterSpacing: 0,
              ),
            ),
          ],
        ],
      ),
    );
  }

  String? _diagnosticsLabel(MemoryAuditEvent event) {
    final payload = event.payload;
    if (payload == null) return null;
    if (event.action == 'memory.promote' ||
        event.action == 'memory.unpin' ||
        event.action == 'memory.expire' ||
        event.action == 'memory.disable' ||
        event.action == 'memory.restore') {
      return _layerChangeLabel(event.action, payload);
    }
    if (event.action != 'memory.retrieve') return null;
    final diagnostics = payload['diagnostics'];
    final diagnosticsMap = diagnostics is Map ? diagnostics : const {};
    final parts = <String>[
      if (_percent(payload['score']) != null)
        'score ${_percent(payload['score'])}',
      if (diagnosticsMap['pinnedLayer'] == true) 'pinned',
      if (_percent(diagnosticsMap['lexicalScore']) != null)
        'lexical ${_percent(diagnosticsMap['lexicalScore'])}',
      if (_percent(diagnosticsMap['feedbackScore']) != null)
        'feedback ${_percent(diagnosticsMap['feedbackScore'])}',
      if (diagnosticsMap['accessCount'] is num)
        'used ${(diagnosticsMap['accessCount'] as num).toInt()}x',
    ];
    if (parts.isEmpty) return null;
    return parts.join(' · ');
  }

  String? _layerChangeLabel(String action, Map<String, Object?> payload) {
    final reason = _reasonLabel(payload['reason']);
    final feedbackReason = payload['feedbackReason']?.toString().trim();
    final parts = <String>[
      switch (action) {
        'memory.promote' => 'promoted',
        'memory.unpin' => 'unpinned',
        'memory.expire' => 'expired',
        'memory.disable' => 'disabled',
        'memory.restore' => 'restored',
        _ => action,
      },
      ?reason,
      if (payload['accessCount'] is num)
        'used ${(payload['accessCount'] as num).toInt()}x',
      if (payload['threshold'] is num)
        'threshold ${(payload['threshold'] as num).toInt()}',
      if (feedbackReason != null && feedbackReason.isNotEmpty) feedbackReason,
    ];
    return parts.join(' · ');
  }

  String? _reasonLabel(Object? raw) {
    final value = raw?.toString().trim();
    if (value == null || value.isEmpty) return null;
    return value.replaceAll('_', ' ');
  }

  String? _percent(Object? raw) {
    if (raw is! num) return null;
    return '${(raw * 100).round()}%';
  }

  String _targetLabel(MemoryAuditEvent event) {
    final parts = <String>[
      if (event.memoryId?.trim().isNotEmpty == true)
        'memory ${event.memoryId!.trim()}',
      if (event.candidateId?.trim().isNotEmpty == true)
        'candidate ${event.candidateId!.trim()}',
      if (event.changeRequestId?.trim().isNotEmpty == true)
        'change request ${event.changeRequestId!.trim()}',
    ];
    return parts.join(' · ');
  }
}

class _MemoryCandidateCard extends StatelessWidget {
  const _MemoryCandidateCard({
    required this.candidate,
    required this.busy,
    required this.edited,
    required this.onApprove,
    required this.onReject,
    required this.onEdit,
  });

  final MemoryCandidate candidate;
  final bool busy;
  final bool edited;
  final VoidCallback onApprove;
  final VoidCallback onReject;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final isPending = candidate.status.trim().toLowerCase() == 'pending';
    final source = candidate.source.trim();
    final metaParts = [
      candidate.kind,
      candidate.scope,
      _confidenceLabel(candidate.confidence),
      candidate.status,
      if (source.isNotEmpty) source,
    ];
    return _ExplorerCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: _MetaLine(label: metaParts.join(' · '))),
              if (edited && isPending) const _EditedPill(),
            ],
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
          if (candidate.reason?.trim().isNotEmpty == true) ...[
            const SizedBox(height: 6),
            Text(
              candidate.reason!.trim(),
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                letterSpacing: 0,
              ),
            ),
          ],
          if (candidate.instructionScopes.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              'instructions ${candidate.instructionScopes.join(', ')}',
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0,
              ),
            ),
          ],
          if (isPending) ...[
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: busy ? null : onEdit,
                  child: const Text('Edit'),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: busy ? null : onReject,
                  child: const Text('Reject'),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: busy ? null : onApprove,
                  child: busy
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

  String _confidenceLabel(double? confidence) {
    if (confidence == null) return 'confidence --';
    return '${(confidence * 100).round()}%';
  }
}

class _MemoryChangeRequestCard extends StatelessWidget {
  const _MemoryChangeRequestCard({
    required this.request,
    required this.busy,
    required this.edited,
    required this.onApprove,
    required this.onReject,
    required this.onEdit,
  });

  final MemoryChangeRequest request;
  final bool busy;
  final bool edited;
  final VoidCallback onApprove;
  final VoidCallback onReject;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final isPending = request.status.trim().toLowerCase() == 'pending';
    final source = request.source.trim();
    return _ExplorerCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: _MetaLine(
                  label: [
                    request.action,
                    _confidenceLabel(request.confidence),
                    request.status,
                    if (source.isNotEmpty) source,
                  ].join(' · '),
                ),
              ),
              if (edited && isPending) const _EditedPill(),
            ],
          ),
          const SizedBox(height: 6),
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
            const SizedBox(height: 10),
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
            const SizedBox(height: 10),
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
            const SizedBox(height: 8),
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
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: busy ? null : onEdit,
                  child: const Text('Edit'),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: busy ? null : onReject,
                  child: const Text('Reject'),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: busy ? null : onApprove,
                  child: busy
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

  String _confidenceLabel(double? confidence) {
    if (confidence == null) return 'manual review';
    return '${(confidence * 100).round()}%';
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

class _CandidateEditorDialog extends StatefulWidget {
  const _CandidateEditorDialog({required this.candidate});

  final MemoryCandidate candidate;

  @override
  State<_CandidateEditorDialog> createState() => _CandidateEditorDialogState();
}

class _CandidateEditorDialogState extends State<_CandidateEditorDialog> {
  static const List<String> _kinds = [
    'user_preference',
    'project_rule',
    'architecture_decision',
    'session_summary',
  ];
  static const List<String> _scopes = [
    'global',
    'workspace',
    'repo',
    'session',
  ];

  late String _kind = _knownOrFirst(widget.candidate.kind, _kinds);
  late String _scope = _knownOrFirst(widget.candidate.scope, _scopes);
  late final TextEditingController _textController = TextEditingController(
    text: widget.candidate.text,
  );

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit candidate'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              initialValue: _kind,
              decoration: const InputDecoration(labelText: 'Kind'),
              items: [
                for (final kind in _kinds)
                  DropdownMenuItem(value: kind, child: Text(kind)),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _kind = value);
              },
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              initialValue: _scope,
              decoration: const InputDecoration(labelText: 'Scope'),
              items: [
                for (final scope in _scopes)
                  DropdownMenuItem(value: scope, child: Text(scope)),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _scope = value);
              },
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _textController,
              minLines: 3,
              maxLines: 6,
              decoration: const InputDecoration(labelText: 'Text'),
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
            final text = _textController.text.trim();
            if (text.isEmpty) return;
            Navigator.of(context).pop(
              widget.candidate.copyWith(kind: _kind, scope: _scope, text: text),
            );
          },
          child: const Text('Save'),
        ),
      ],
    );
  }

  static String _knownOrFirst(String value, List<String> values) {
    return values.contains(value) ? value : values.first;
  }
}

class _ChangeRequestEditorDialog extends StatefulWidget {
  const _ChangeRequestEditorDialog({required this.request});

  final MemoryChangeRequest request;

  @override
  State<_ChangeRequestEditorDialog> createState() =>
      _ChangeRequestEditorDialogState();
}

class _ChangeRequestEditorDialogState
    extends State<_ChangeRequestEditorDialog> {
  static const List<String> _kinds = [
    'user_preference',
    'project_rule',
    'architecture_decision',
    'session_summary',
  ];
  static const List<String> _scopes = [
    'global',
    'workspace',
    'repo',
    'session',
  ];

  late String _kind = _knownOrFirst(widget.request.proposedKind, _kinds);
  late String _scope = _knownOrFirst(widget.request.proposedScope, _scopes);
  late final TextEditingController _textController = TextEditingController(
    text: widget.request.proposedText ?? '',
  );

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit change request'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              initialValue: _kind,
              decoration: const InputDecoration(labelText: 'Kind'),
              items: [
                for (final kind in _kinds)
                  DropdownMenuItem(value: kind, child: Text(kind)),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _kind = value);
              },
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              initialValue: _scope,
              decoration: const InputDecoration(labelText: 'Scope'),
              items: [
                for (final scope in _scopes)
                  DropdownMenuItem(value: scope, child: Text(scope)),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _scope = value);
              },
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _textController,
              minLines: 3,
              maxLines: 6,
              decoration: const InputDecoration(labelText: 'Proposed text'),
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
            final text = _textController.text.trim();
            Navigator.of(context).pop(
              widget.request.copyWith(
                proposedKind: _kind,
                proposedScope: _scope,
                proposedText: text.isEmpty ? widget.request.proposedText : text,
              ),
            );
          },
          child: const Text('Save'),
        ),
      ],
    );
  }

  static String _knownOrFirst(String? value, List<String> values) {
    return value != null && values.contains(value) ? value : values.first;
  }
}

class _ExplorerCard extends StatelessWidget {
  const _ExplorerCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.border),
      ),
      child: child,
    );
  }
}

class _MetaLine extends StatelessWidget {
  const _MetaLine({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        color: AppColors.primaryDark,
        fontSize: 12,
        fontWeight: FontWeight.w900,
        letterSpacing: 0,
      ),
    );
  }
}

class _EditedPill extends StatelessWidget {
  const _EditedPill();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: const Text(
        'Edited',
        style: TextStyle(
          color: AppColors.primaryDark,
          fontSize: 11,
          fontWeight: FontWeight.w900,
          letterSpacing: 0,
        ),
      ),
    );
  }
}

class _LoadingPane extends StatelessWidget {
  const _LoadingPane();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: SizedBox(
        width: 22,
        height: 22,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
    );
  }
}

class _ErrorPane extends StatelessWidget {
  const _ErrorPane({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 560),
        margin: const EdgeInsets.all(18),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.danger.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: AppColors.danger.withValues(alpha: 0.22)),
        ),
        child: Text(
          message,
          style: const TextStyle(
            color: AppColors.danger,
            fontSize: 12,
            fontWeight: FontWeight.w700,
            letterSpacing: 0,
          ),
        ),
      ),
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
