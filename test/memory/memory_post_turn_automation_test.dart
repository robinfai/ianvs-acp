import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/memory/memory_api_client.dart';
import 'package:ianvs_acp/memory/memory_config.dart';
import 'package:ianvs_acp/memory/memory_post_turn_automation.dart';

void main() {
  test(
    'auto-approves high-confidence candidates then runs maintenance',
    () async {
      final approved = <String>[];
      var maintenanceRuns = 0;

      final result = await MemoryPostTurnAutomation.apply(
        memory: const MemoryConfig(enabled: true),
        candidates: const [
          MemoryCandidate(
            id: 'cand_high',
            kind: 'user_preference',
            scope: 'global',
            text: '用户称呼是 Rodriguez。',
            confidence: 0.96,
            reason: 'Explicit user instruction.',
            status: 'pending',
          ),
          MemoryCandidate(
            id: 'cand_low',
            kind: 'project_rule',
            scope: 'repo',
            text: '项目验证暗号可能是蓝色灯塔。',
            confidence: 0.72,
            reason: 'Low confidence.',
            status: 'pending',
          ),
        ],
        approveCandidate: (candidate) async => approved.add(candidate.id),
        runMaintenance: () async {
          maintenanceRuns += 1;
          return const MaintenanceRunResult(
            autoApplied: 1,
            needsReview: 2,
            skipped: 0,
            changeRequests: <MemoryChangeRequest>[],
          );
        },
      );

      expect(approved, ['cand_high']);
      expect(maintenanceRuns, 1);
      expect(result.approvedCandidates, 1);
      expect(result.pendingCandidateReviews, 1);
      expect(result.pendingReviews, 3);
      expect(result.maintenanceRun, isTrue);
    },
  );

  test(
    'does not run maintenance when no candidate was auto-approved',
    () async {
      var maintenanceRuns = 0;

      final result = await MemoryPostTurnAutomation.apply(
        memory: const MemoryConfig(
          enabled: true,
          review: MemoryReviewConfig(approvalMode: MemoryApprovalMode.manual),
        ),
        candidates: const [
          MemoryCandidate(
            id: 'cand_manual',
            kind: 'user_preference',
            scope: 'global',
            text: '用户称呼是 Rodriguez。',
            confidence: 0.99,
            reason: 'Explicit user instruction.',
            status: 'pending',
          ),
        ],
        approveCandidate: (_) async {},
        runMaintenance: () async {
          maintenanceRuns += 1;
          return const MaintenanceRunResult(
            autoApplied: 0,
            needsReview: 0,
            skipped: 0,
            changeRequests: <MemoryChangeRequest>[],
          );
        },
      );

      expect(maintenanceRuns, 0);
      expect(result.approvedCandidates, 0);
      expect(result.maintenanceRun, isFalse);
    },
  );

  test('keeps high-confidence task episodes pending for review', () async {
    final approved = <String>[];
    var maintenanceRuns = 0;

    final result = await MemoryPostTurnAutomation.apply(
      memory: const MemoryConfig(enabled: true),
      candidates: const [
        MemoryCandidate(
          id: 'cand_episode',
          kind: 'task_episode',
          scope: 'repo',
          text: 'Release validation succeeded with the full verify sequence.',
          confidence: 0.99,
          reason: 'Reusable task experience.',
          status: 'pending',
        ),
      ],
      approveCandidate: (candidate) async => approved.add(candidate.id),
      runMaintenance: () async {
        maintenanceRuns += 1;
        return const MaintenanceRunResult(
          autoApplied: 0,
          needsReview: 0,
          skipped: 0,
          changeRequests: <MemoryChangeRequest>[],
        );
      },
    );

    expect(approved, isEmpty);
    expect(maintenanceRuns, 0);
    expect(result.approvedCandidates, 0);
    expect(result.pendingCandidateReviews, 1);
  });

  test('does not call maintenance when maintenance mode is disabled', () async {
    var maintenanceRuns = 0;

    final result = await MemoryPostTurnAutomation.apply(
      memory: const MemoryConfig(
        enabled: true,
        maintenance: MemoryMaintenanceConfig(mode: 'disabled'),
      ),
      candidates: const [
        MemoryCandidate(
          id: 'cand_high',
          kind: 'user_preference',
          scope: 'global',
          text: '用户称呼是 Rodriguez。',
          confidence: 0.96,
          reason: 'Explicit user instruction.',
          status: 'pending',
        ),
      ],
      approveCandidate: (_) async {},
      runMaintenance: () async {
        maintenanceRuns += 1;
        return const MaintenanceRunResult(
          autoApplied: 0,
          needsReview: 0,
          skipped: 0,
          changeRequests: <MemoryChangeRequest>[],
        );
      },
    );

    expect(result.approvedCandidates, 1);
    expect(result.maintenanceRun, isFalse);
    expect(maintenanceRuns, 0);
  });

  test(
    'does not process candidates or maintenance when memory is disabled',
    () async {
      final approved = <String>[];
      var maintenanceRuns = 0;

      final result = await MemoryPostTurnAutomation.apply(
        memory: const MemoryConfig(enabled: false),
        candidates: const [
          MemoryCandidate(
            id: 'cand_disabled',
            kind: 'user_preference',
            scope: 'global',
            text: '用户称呼是 Rodriguez。',
            confidence: 0.99,
            reason: 'Explicit user instruction.',
            status: 'pending',
          ),
        ],
        usedMemoryCount: 1,
        pendingReviewCount: 1,
        turnsSinceMaintenance: 6,
        approveCandidate: (candidate) async => approved.add(candidate.id),
        runMaintenance: () async {
          maintenanceRuns += 1;
          return const MaintenanceRunResult(
            autoApplied: 0,
            needsReview: 1,
            skipped: 0,
            changeRequests: <MemoryChangeRequest>[],
          );
        },
      );

      expect(approved, isEmpty);
      expect(maintenanceRuns, 0);
      expect(result.approvedCandidates, 0);
      expect(result.pendingReviews, 0);
      expect(result.pendingReviewDelta, 0);
      expect(result.maintenanceRun, isFalse);
    },
  );

  test(
    'auto-approves review-band stable memories without approving unknown long-term candidates',
    () async {
      final approved = <String>[];

      final result = await MemoryPostTurnAutomation.apply(
        memory: const MemoryConfig(enabled: true),
        candidates: const [
          MemoryCandidate(
            id: 'cand_session',
            kind: 'session_summary',
            scope: 'session',
            text: '本轮确认了记忆模块的手动验证路径。',
            confidence: 0.78,
            reason: 'Useful current-session summary.',
            status: 'pending',
          ),
          MemoryCandidate(
            id: 'cand_repo',
            kind: 'project_rule',
            scope: 'repo',
            text: '项目规则是每次都打开调试日志。',
            confidence: 0.78,
            reason: 'Review-band stable repo rule.',
            status: 'pending',
          ),
          MemoryCandidate(
            id: 'cand_unknown',
            kind: 'scratch_note',
            scope: 'repo',
            text: '可能要临时保留一条草稿。',
            confidence: 0.78,
            reason: 'Unknown long-term candidate.',
            status: 'pending',
          ),
        ],
        approveCandidate: (candidate) async => approved.add(candidate.id),
        runMaintenance: () async => const MaintenanceRunResult(
          autoApplied: 0,
          needsReview: 0,
          skipped: 0,
          changeRequests: <MemoryChangeRequest>[],
        ),
      );

      expect(approved, ['cand_session', 'cand_repo']);
      expect(result.approvedCandidates, 2);
      expect(result.maintenanceRun, isTrue);
    },
  );

  test('auto-approves only pending candidates', () async {
    final approved = <String>[];

    final result = await MemoryPostTurnAutomation.apply(
      memory: const MemoryConfig(enabled: true),
      candidates: const [
        MemoryCandidate(
          id: 'cand_approved',
          kind: 'user_preference',
          scope: 'global',
          text: '用户称呼是 Rodriguez。',
          confidence: 0.96,
          reason: 'Already approved by the daemon.',
          status: 'approved',
        ),
        MemoryCandidate(
          id: 'cand_rejected',
          kind: 'project_rule',
          scope: 'repo',
          text: '本项目使用临时暗号。',
          confidence: 0.96,
          reason: 'Already rejected by reviewer.',
          status: 'rejected',
        ),
        MemoryCandidate(
          id: 'cand_pending',
          kind: 'architecture_decision',
          scope: 'repo',
          text: '架构决定：Flutter 负责 ACP 编排。',
          confidence: 0.96,
          reason: 'New pending stable decision.',
          status: 'pending',
        ),
      ],
      approveCandidate: (candidate) async => approved.add(candidate.id),
      runMaintenance: () async => const MaintenanceRunResult(
        autoApplied: 0,
        needsReview: 0,
        skipped: 0,
        changeRequests: <MemoryChangeRequest>[],
      ),
    );

    expect(approved, ['cand_pending']);
    expect(result.approvedCandidates, 1);
    expect(result.maintenanceRun, isTrue);
  });

  test(
    'runs maintenance after a memory-backed turn without new approvals',
    () async {
      var maintenanceRuns = 0;

      final result = await MemoryPostTurnAutomation.apply(
        memory: const MemoryConfig(enabled: true),
        candidates: const <MemoryCandidate>[],
        usedMemoryCount: 2,
        approveCandidate: (_) async {},
        runMaintenance: () async {
          maintenanceRuns += 1;
          return const MaintenanceRunResult(
            autoApplied: 0,
            needsReview: 1,
            skipped: 3,
            changeRequests: <MemoryChangeRequest>[],
          );
        },
      );

      expect(maintenanceRuns, 1);
      expect(result.approvedCandidates, 0);
      expect(result.maintenanceRun, isTrue);
      expect(result.maintenanceResult?.needsReview, 1);
    },
  );

  test('runs maintenance after daemon auto-applies change requests', () async {
    var maintenanceRuns = 0;

    final result = await MemoryPostTurnAutomation.apply(
      memory: const MemoryConfig(enabled: true),
      candidates: const <MemoryCandidate>[],
      autoAppliedChangeRequests: 1,
      approveCandidate: (_) async {},
      runMaintenance: () async {
        maintenanceRuns += 1;
        return const MaintenanceRunResult(
          autoApplied: 0,
          needsReview: 0,
          skipped: 1,
          changeRequests: <MemoryChangeRequest>[],
        );
      },
    );

    expect(maintenanceRuns, 1);
    expect(result.approvedCandidates, 0);
    expect(result.autoAppliedChangeRequests, 1);
    expect(result.maintenanceRun, isTrue);
  });

  test('keeps maintenance trigger when post-turn maintenance fails', () async {
    final approved = <String>[];

    final result = await MemoryPostTurnAutomation.apply(
      memory: const MemoryConfig(enabled: true),
      candidates: const [
        MemoryCandidate(
          id: 'cand_high',
          kind: 'user_preference',
          scope: 'global',
          text: '用户称呼是 Rodriguez。',
          confidence: 0.96,
          reason: 'Explicit user instruction.',
          status: 'pending',
        ),
      ],
      approveCandidate: (candidate) async => approved.add(candidate.id),
      runMaintenance: () async {
        throw Exception('maintenance unavailable');
      },
    );

    expect(approved, ['cand_high']);
    expect(result.maintenanceRun, isFalse);
    expect(result.maintenanceTrigger, MemoryMaintenanceTrigger.postTurn);
  });

  test(
    'reports negative pending delta when maintenance cleans old reviews',
    () async {
      final result = await MemoryPostTurnAutomation.apply(
        memory: const MemoryConfig(enabled: true),
        candidates: const <MemoryCandidate>[],
        usedMemoryCount: 1,
        pendingReviewCount: 3,
        approveCandidate: (_) async {},
        runMaintenance: () async => const MaintenanceRunResult(
          autoApplied: 0,
          needsReview: 0,
          skipped: 0,
          autoRejectedCandidates: 1,
          autoRejectedChangeRequests: 2,
          changeRequests: <MemoryChangeRequest>[],
        ),
      );

      expect(result.pendingReviews, 0);
      expect(result.autoCleanedReviews, 3);
      expect(result.pendingReviewDelta, -3);
    },
  );

  test(
    'reports negative pending delta when maintenance approves existing reviews',
    () async {
      final result = await MemoryPostTurnAutomation.apply(
        memory: const MemoryConfig(enabled: true),
        candidates: const <MemoryCandidate>[],
        usedMemoryCount: 1,
        pendingReviewCount: 2,
        approveCandidate: (_) async {},
        runMaintenance: () async => const MaintenanceRunResult(
          autoApplied: 1,
          needsReview: 0,
          skipped: 0,
          existingAutoApprovedChangeRequests: 1,
          changeRequests: <MemoryChangeRequest>[],
        ),
      );

      expect(result.pendingReviews, 0);
      expect(result.autoCleanedReviews, 0);
      expect(result.pendingReviewDelta, -1);
    },
  );

  test('reports maintenance review work as change request pending', () async {
    final result = await MemoryPostTurnAutomation.apply(
      memory: const MemoryConfig(enabled: true),
      candidates: const [
        MemoryCandidate(
          id: 'cand_low',
          kind: 'project_rule',
          scope: 'repo',
          text: '低置信项目规则需要稍后复核。',
          confidence: 0.62,
          reason: 'Below automatic approval threshold.',
          status: 'pending',
        ),
      ],
      usedMemoryCount: 1,
      approveCandidate: (_) async {},
      runMaintenance: () async => const MaintenanceRunResult(
        autoApplied: 0,
        needsReview: 2,
        skipped: 0,
        changeRequests: <MemoryChangeRequest>[],
      ),
    );

    expect(result.pendingCandidateReviews, 1);
    expect(result.pendingChangeRequestReviews, 2);
    expect(result.pendingCandidateReviewDelta, 1);
    expect(result.pendingChangeRequestReviewDelta, 2);
    expect(result.pendingReviews, 3);
    expect(result.pendingReviewDelta, 3);
  });

  test('runs idle maintenance after configured quiet turns', () async {
    var maintenanceRuns = 0;

    final result = await MemoryPostTurnAutomation.apply(
      memory: const MemoryConfig(
        enabled: true,
        maintenance: MemoryMaintenanceConfig(
          idleEnabled: true,
          idleAfterTurns: 3,
          idleMaxPendingReviews: 0,
        ),
      ),
      candidates: const <MemoryCandidate>[],
      pendingReviewCount: 0,
      turnsSinceMaintenance: 3,
      approveCandidate: (_) async {},
      runMaintenance: () async {
        maintenanceRuns += 1;
        return const MaintenanceRunResult(
          autoApplied: 0,
          needsReview: 0,
          skipped: 2,
          changeRequests: <MemoryChangeRequest>[],
        );
      },
    );

    expect(maintenanceRuns, 1);
    expect(result.maintenanceRun, isTrue);
    expect(result.maintenanceTrigger, MemoryMaintenanceTrigger.idle);
  });

  test(
    'does not run idle maintenance on a turn that auto-approved memory',
    () async {
      final approved = <String>[];
      var maintenanceRuns = 0;

      final result = await MemoryPostTurnAutomation.apply(
        memory: const MemoryConfig(
          enabled: true,
          maintenance: MemoryMaintenanceConfig(
            runAfterExtraction: false,
            idleEnabled: true,
            idleAfterTurns: 3,
            idleMaxPendingReviews: 0,
          ),
        ),
        candidates: const [
          MemoryCandidate(
            id: 'cand_high',
            kind: 'user_preference',
            scope: 'global',
            text: '用户称呼是 Rodriguez。',
            confidence: 0.96,
            reason: 'Explicit user instruction.',
            status: 'pending',
          ),
        ],
        pendingReviewCount: 0,
        turnsSinceMaintenance: 3,
        approveCandidate: (candidate) async => approved.add(candidate.id),
        runMaintenance: () async {
          maintenanceRuns += 1;
          return const MaintenanceRunResult(
            autoApplied: 0,
            needsReview: 0,
            skipped: 0,
            changeRequests: <MemoryChangeRequest>[],
          );
        },
      );

      expect(approved, ['cand_high']);
      expect(maintenanceRuns, 0);
      expect(result.maintenanceRun, isFalse);
    },
  );

  test(
    'runs conservative idle maintenance by default after quiet turns',
    () async {
      var maintenanceRuns = 0;

      final result = await MemoryPostTurnAutomation.apply(
        memory: const MemoryConfig(enabled: true),
        candidates: const <MemoryCandidate>[],
        pendingReviewCount: 0,
        turnsSinceMaintenance: 6,
        approveCandidate: (_) async {},
        runMaintenance: () async {
          maintenanceRuns += 1;
          return const MaintenanceRunResult(
            autoApplied: 0,
            needsReview: 0,
            skipped: 2,
            changeRequests: <MemoryChangeRequest>[],
          );
        },
      );

      expect(maintenanceRuns, 1);
      expect(result.maintenanceRun, isTrue);
      expect(result.maintenanceTrigger, MemoryMaintenanceTrigger.idle);
    },
  );

  test('idle maintenance ignores reviewed candidate history', () async {
    var maintenanceRuns = 0;

    final result = await MemoryPostTurnAutomation.apply(
      memory: const MemoryConfig(
        enabled: true,
        maintenance: MemoryMaintenanceConfig(
          idleEnabled: true,
          idleAfterTurns: 3,
          idleMaxPendingReviews: 0,
        ),
      ),
      candidates: const [
        MemoryCandidate(
          id: 'cand_approved',
          kind: 'user_preference',
          scope: 'global',
          text: '用户称呼是 Rodriguez。',
          confidence: 0.96,
          reason: 'Already approved.',
          status: 'approved',
        ),
        MemoryCandidate(
          id: 'cand_rejected',
          kind: 'project_rule',
          scope: 'repo',
          text: '本项目临时使用测试暗号。',
          confidence: 0.7,
          reason: 'Already rejected.',
          status: 'rejected',
        ),
      ],
      pendingReviewCount: 0,
      turnsSinceMaintenance: 3,
      approveCandidate: (_) async {},
      runMaintenance: () async {
        maintenanceRuns += 1;
        return const MaintenanceRunResult(
          autoApplied: 0,
          needsReview: 0,
          skipped: 2,
          changeRequests: <MemoryChangeRequest>[],
        );
      },
    );

    expect(maintenanceRuns, 1);
    expect(result.maintenanceRun, isTrue);
    expect(result.maintenanceTrigger, MemoryMaintenanceTrigger.idle);
  });

  test(
    'runs idle maintenance when pending reviews are within configured limit',
    () async {
      var maintenanceRuns = 0;

      final result = await MemoryPostTurnAutomation.apply(
        memory: const MemoryConfig(
          enabled: true,
          maintenance: MemoryMaintenanceConfig(
            idleEnabled: true,
            idleAfterTurns: 3,
            idleMaxPendingReviews: 2,
          ),
        ),
        candidates: const [
          MemoryCandidate(
            id: 'cand_review',
            kind: 'project_rule',
            scope: 'repo',
            text: '低置信项目规则需要稍后复核。',
            confidence: 0.62,
            reason: 'Below automatic approval threshold.',
            status: 'pending',
          ),
        ],
        pendingReviewCount: 1,
        turnsSinceMaintenance: 3,
        approveCandidate: (_) async {},
        runMaintenance: () async {
          maintenanceRuns += 1;
          return const MaintenanceRunResult(
            autoApplied: 0,
            needsReview: 0,
            skipped: 1,
            changeRequests: <MemoryChangeRequest>[],
          );
        },
      );

      expect(maintenanceRuns, 1);
      expect(result.pendingCandidateReviews, 1);
      expect(result.maintenanceRun, isTrue);
      expect(result.maintenanceTrigger, MemoryMaintenanceTrigger.idle);
    },
  );

  test(
    'skips idle maintenance before threshold or while reviews are pending',
    () async {
      var maintenanceRuns = 0;
      const memory = MemoryConfig(
        enabled: true,
        maintenance: MemoryMaintenanceConfig(
          idleEnabled: true,
          idleAfterTurns: 3,
          idleMaxPendingReviews: 0,
        ),
      );

      final beforeThreshold = await MemoryPostTurnAutomation.apply(
        memory: memory,
        candidates: const <MemoryCandidate>[],
        pendingReviewCount: 0,
        turnsSinceMaintenance: 2,
        approveCandidate: (_) async {},
        runMaintenance: () async {
          maintenanceRuns += 1;
          return const MaintenanceRunResult(
            autoApplied: 0,
            needsReview: 0,
            skipped: 0,
            changeRequests: <MemoryChangeRequest>[],
          );
        },
      );
      final pendingReviews = await MemoryPostTurnAutomation.apply(
        memory: memory,
        candidates: const <MemoryCandidate>[],
        pendingReviewCount: 1,
        turnsSinceMaintenance: 3,
        approveCandidate: (_) async {},
        runMaintenance: () async {
          maintenanceRuns += 1;
          return const MaintenanceRunResult(
            autoApplied: 0,
            needsReview: 0,
            skipped: 0,
            changeRequests: <MemoryChangeRequest>[],
          );
        },
      );

      expect(maintenanceRuns, 0);
      expect(beforeThreshold.maintenanceRun, isFalse);
      expect(pendingReviews.maintenanceRun, isFalse);
    },
  );
}
