import 'memory_api_client.dart';
import 'memory_config.dart';

typedef MemoryCandidateApprover =
    Future<void> Function(MemoryCandidate candidate);
typedef MemoryMaintenanceRunner = Future<MaintenanceRunResult> Function();

class MemoryMaintenanceTrigger {
  const MemoryMaintenanceTrigger._();

  static const String postTurn = 'post_turn';
  static const String idle = 'idle';
}

class MemoryPostTurnAutomationResult {
  const MemoryPostTurnAutomationResult({
    required this.approvedCandidates,
    required this.pendingCandidateReviews,
    required this.autoAppliedChangeRequests,
    required this.maintenanceRun,
    this.maintenanceTrigger,
    this.maintenanceResult,
  });

  final int approvedCandidates;
  final int pendingCandidateReviews;
  final int autoAppliedChangeRequests;
  final bool maintenanceRun;
  final String? maintenanceTrigger;
  final MaintenanceRunResult? maintenanceResult;

  int get pendingChangeRequestReviews => maintenanceResult?.needsReview ?? 0;

  int get pendingReviews =>
      pendingCandidateReviews + pendingChangeRequestReviews;

  int get autoCleanedReviews => maintenanceResult?.autoCleaned ?? 0;

  int get autoResolvedReviews => maintenanceResult?.autoResolvedReviews ?? 0;

  int get pendingCandidateReviewDelta =>
      pendingCandidateReviews -
      (maintenanceResult?.autoRejectedCandidates ?? 0);

  int get pendingChangeRequestReviewDelta =>
      pendingChangeRequestReviews -
      (maintenanceResult?.autoRejectedChangeRequests ?? 0) -
      (maintenanceResult?.existingAutoApprovedChangeRequests ?? 0);

  int get pendingReviewDelta =>
      pendingCandidateReviewDelta + pendingChangeRequestReviewDelta;
}

class MemoryPostTurnAutomation {
  const MemoryPostTurnAutomation._();

  static Future<MemoryPostTurnAutomationResult> apply({
    required MemoryConfig memory,
    required List<MemoryCandidate> candidates,
    int autoAppliedChangeRequests = 0,
    int usedMemoryCount = 0,
    int pendingReviewCount = 0,
    int turnsSinceMaintenance = 0,
    required MemoryCandidateApprover approveCandidate,
    required MemoryMaintenanceRunner runMaintenance,
  }) async {
    if (!memory.enabled) {
      return const MemoryPostTurnAutomationResult(
        approvedCandidates: 0,
        pendingCandidateReviews: 0,
        autoAppliedChangeRequests: 0,
        maintenanceRun: false,
      );
    }

    var approvedCandidates = 0;
    final pendingCandidates = candidates
        .where(_isPendingCandidate)
        .toList(growable: false);
    final candidatesToApprove = _candidatesToApprove(memory, candidates);
    for (final candidate in candidatesToApprove) {
      try {
        await approveCandidate(candidate);
        approvedCandidates += 1;
      } catch (_) {
        // Leave failed approvals pending for later human review.
      }
    }

    MaintenanceRunResult? maintenanceResult;
    final maintenanceTrigger = _maintenanceTrigger(
      memory: memory,
      candidates: candidates,
      approvedCandidates: approvedCandidates,
      autoAppliedChangeRequests: autoAppliedChangeRequests,
      usedMemoryCount: usedMemoryCount,
      pendingReviewCount: pendingReviewCount,
      turnsSinceMaintenance: turnsSinceMaintenance,
    );
    if (maintenanceTrigger != null) {
      try {
        maintenanceResult = await runMaintenance();
      } catch (_) {
        // Maintenance is best-effort and must not affect the main turn.
      }
    }

    final remainingPendingCandidates =
        pendingCandidates.length - approvedCandidates;
    return MemoryPostTurnAutomationResult(
      approvedCandidates: approvedCandidates,
      pendingCandidateReviews: remainingPendingCandidates < 0
          ? 0
          : remainingPendingCandidates,
      autoAppliedChangeRequests: autoAppliedChangeRequests,
      maintenanceRun: maintenanceResult != null,
      maintenanceTrigger: maintenanceTrigger,
      maintenanceResult: maintenanceResult,
    );
  }

  static String? _maintenanceTrigger({
    required MemoryConfig memory,
    required List<MemoryCandidate> candidates,
    required int approvedCandidates,
    required int autoAppliedChangeRequests,
    required int usedMemoryCount,
    required int pendingReviewCount,
    required int turnsSinceMaintenance,
  }) {
    final maintenance = memory.maintenance;
    if (!maintenance.enabled || _isMaintenanceModeDisabled(maintenance.mode)) {
      return null;
    }
    final hasMemoryActivity =
        approvedCandidates > 0 ||
        autoAppliedChangeRequests > 0 ||
        usedMemoryCount > 0;
    if (maintenance.runAfterExtraction && hasMemoryActivity) {
      return MemoryMaintenanceTrigger.postTurn;
    }
    if (hasMemoryActivity) return null;
    if (!maintenance.idleEnabled) return null;
    final currentPendingReviews = _remainingPendingCandidateCount(
      candidates,
      approvedCandidates,
    );
    if (pendingReviewCount + currentPendingReviews >
        maintenance.idleMaxPendingReviews) {
      return null;
    }
    if (turnsSinceMaintenance < maintenance.idleAfterTurns) return null;
    return MemoryMaintenanceTrigger.idle;
  }

  static bool _isMaintenanceModeDisabled(String mode) {
    final normalized = mode.trim().toLowerCase().replaceAll(
      RegExp(r'[\s-]+'),
      '_',
    );
    return normalized == 'disabled' || normalized == 'off';
  }

  static List<MemoryCandidate> _candidatesToApprove(
    MemoryConfig memory,
    List<MemoryCandidate> candidates,
  ) {
    if (candidates.isEmpty) return const <MemoryCandidate>[];
    final mode = memory.review.approvalMode;
    final threshold = memory.review.highConfidenceThreshold;
    final sessionThreshold = memory.maintenance.reviewThreshold;
    return switch (mode) {
      MemoryApprovalMode.autoApprove =>
        candidates.where(_isPendingCandidate).toList(growable: false),
      MemoryApprovalMode.autoHighConfidence =>
        candidates
            .where(_isPendingCandidate)
            .where(
              (candidate) =>
                  candidate.kind.trim().toLowerCase() != 'task_episode',
            )
            .where(
              (candidate) =>
                  (candidate.confidence ?? 0) >= threshold ||
                  _isReviewBandAutoCandidate(candidate, sessionThreshold),
            )
            .toList(growable: false),
      _ => const <MemoryCandidate>[],
    };
  }

  static bool _isPendingCandidate(MemoryCandidate candidate) {
    return candidate.status.trim().toLowerCase() == 'pending';
  }

  static int _remainingPendingCandidateCount(
    List<MemoryCandidate> candidates,
    int approvedCandidates,
  ) {
    final pendingCount = candidates.where(_isPendingCandidate).length;
    final remaining = pendingCount - approvedCandidates;
    return remaining < 0 ? 0 : remaining;
  }

  static bool _isReviewBandAutoCandidate(
    MemoryCandidate candidate,
    double threshold,
  ) {
    if ((candidate.confidence ?? 0) < threshold) return false;
    final kind = candidate.kind.trim().toLowerCase();
    final scope = candidate.scope.trim().toLowerCase();
    return (kind == 'session_summary' && scope == 'session') ||
        (kind == 'user_preference' && scope == 'global') ||
        (kind == 'project_rule' && (scope == 'workspace' || scope == 'repo')) ||
        (kind == 'architecture_decision' &&
            (scope == 'workspace' || scope == 'repo'));
  }
}
