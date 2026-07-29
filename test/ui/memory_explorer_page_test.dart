import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/memory/memory_api_client.dart';
import 'package:ianvs_acp/ui/components/memory_explorer_page.dart';

void main() {
  testWidgets('explorer exposes memory management tabs and clear data', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: MemoryExplorerPage()));

    expect(find.text('All memory'), findsOneWidget);
    expect(find.text('Candidates'), findsOneWidget);
    expect(find.text('Change requests'), findsOneWidget);
    expect(find.text('Audit log'), findsOneWidget);
    expect(find.text('Clear data'), findsOneWidget);
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Clear data'),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets('clear data button calls provided callback', (tester) async {
    var cleared = false;
    await tester.pumpWidget(
      MaterialApp(home: MemoryExplorerPage(onClearData: () => cleared = true)),
    );

    await tester.tap(find.widgetWithText(OutlinedButton, 'Clear data'));
    await tester.pump();

    expect(cleared, isTrue);
  });

  testWidgets('clear data button confirms and clears scoped memory', (
    tester,
  ) async {
    String? clearedLevel;
    await tester.pumpWidget(
      MaterialApp(
        home: MemoryExplorerPage(
          actions: MemoryExplorerActions(
            loadMemory: () async => const [
              MemoryRecord(
                id: 'mem_1',
                kind: 'project_rule',
                scope: 'repo',
                text: 'Repo memory.',
                userId: 'local-user',
                source: 'manual',
                status: 'active',
                createdAt: 1,
                updatedAt: 1,
              ),
            ],
            loadCandidates: () async => const <MemoryCandidate>[],
            loadChangeRequests: () async => const <MemoryChangeRequest>[],
            loadAudit: () async => const <MemoryAuditEvent>[],
            approveCandidate: (_) async {},
            rejectCandidate: (_) async {},
            approveChangeRequest: (_) async {},
            rejectChangeRequest: (_) async {},
            runMaintenance: () async => const MaintenanceRunResult(
              autoApplied: 0,
              needsReview: 0,
              skipped: 0,
              changeRequests: <MemoryChangeRequest>[],
            ),
            clearData: (level) async {
              clearedLevel = level;
              return const MemoryClearResult(
                clearedMemory: 1,
                rejectedCandidates: 2,
                rejectedChangeRequests: 3,
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(OutlinedButton, 'Clear data'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Current repo').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Current session').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Clear'));
    await tester.pumpAndSettle();

    expect(clearedLevel, 'session');
    expect(
      find.text(
        '1 memory cleared · 2 candidates rejected · 3 change requests rejected',
      ),
      findsOneWidget,
    );
  });

  testWidgets('JSONL backup actions export and import with review choice', (
    tester,
  ) async {
    var exportCalls = 0;
    String? importMode;
    await tester.pumpWidget(
      MaterialApp(
        home: MemoryExplorerPage(
          actions: MemoryExplorerActions(
            loadMemory: () async => const <MemoryRecord>[],
            loadCandidates: () async => const <MemoryCandidate>[],
            loadChangeRequests: () async => const <MemoryChangeRequest>[],
            loadAudit: () async => const <MemoryAuditEvent>[],
            approveCandidate: (_) async {},
            rejectCandidate: (_) async {},
            approveChangeRequest: (_) async {},
            rejectChangeRequest: (_) async {},
            exportBackup: () async {
              exportCalls += 1;
              return const MemoryExportResult(
                jsonl: '{"version":1}\n',
                exported: 3,
                truncated: false,
              );
            },
            importBackup: (mode) async {
              importMode = mode;
              return const MemoryImportResult(
                imported: 0,
                pendingReview: 2,
                skipped: 1,
                errors: <MemoryImportError>[],
              );
            },
            runMaintenance: () async => const MaintenanceRunResult(
              autoApplied: 0,
              needsReview: 0,
              skipped: 0,
              changeRequests: <MemoryChangeRequest>[],
            ),
            clearData: (_) async => const MemoryClearResult(
              clearedMemory: 0,
              rejectedCandidates: 0,
              rejectedChangeRequests: 0,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Export JSONL backup'));
    await tester.pumpAndSettle();
    expect(exportCalls, 1);
    expect(find.text('3 memory records exported'), findsOneWidget);

    await tester.tap(find.byTooltip('Import JSONL backup'));
    await tester.pumpAndSettle();
    expect(find.text('Import memory backup'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Review first'));
    await tester.pumpAndSettle();

    expect(importMode, 'pending_review');
    expect(
      find.text('0 imported · 2 pending review · 1 skipped · 0 errors'),
      findsOneWidget,
    );
  });

  testWidgets('search filters memory review lists across tabs', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MemoryExplorerPage(
          actions: MemoryExplorerActions(
            loadMemory: () async => const [
              MemoryRecord(
                id: 'mem_blue',
                kind: 'project_rule',
                scope: 'repo',
                text: 'The verification phrase is blue lighthouse.',
                userId: 'local-user',
                source: 'extractor',
                status: 'active',
                createdAt: 1,
                updatedAt: 1,
              ),
              MemoryRecord(
                id: 'mem_name',
                kind: 'user_preference',
                scope: 'global',
                text: 'The user goes by Rodriguez.',
                userId: 'local-user',
                source: 'extractor',
                status: 'active',
                createdAt: 1,
                updatedAt: 1,
              ),
            ],
            loadCandidates: () async => const [
              MemoryCandidate(
                id: 'cand_blue',
                kind: 'project_rule',
                scope: 'repo',
                text: 'Remember the blue lighthouse verification phrase.',
                confidence: 0.91,
                reason: 'User asked to remember the phrase.',
                status: 'approved',
              ),
              MemoryCandidate(
                id: 'cand_name',
                kind: 'user_preference',
                scope: 'global',
                text: 'The user goes by Rodriguez.',
                confidence: 0.94,
                reason: 'User stated their name.',
                status: 'approved',
              ),
            ],
            loadChangeRequests: () async => const [
              MemoryChangeRequest(
                id: 'cr_blue',
                action: 'summarize',
                targetMemoryIds: ['mem_blue'],
                targetMemoryText: 'The verification phrase is blue lighthouse.',
                proposedText: 'Verification phrase: blue lighthouse.',
                reason: 'Shorter phrase memory.',
                confidence: 0.88,
                status: 'pending',
                createdAt: 1,
              ),
              MemoryChangeRequest(
                id: 'cr_name',
                action: 'update',
                targetMemoryIds: ['mem_name'],
                targetMemoryText: 'The user goes by Rodriguez.',
                proposedText: 'Call the user Rodriguez.',
                reason: 'Name preference.',
                confidence: 0.88,
                status: 'pending',
                createdAt: 1,
              ),
            ],
            loadAudit: () async => const [
              MemoryAuditEvent(
                id: 'audit_blue',
                actor: 'extractor',
                action: 'candidate.approve',
                memoryId: 'mem_blue',
                memoryText: 'The verification phrase is blue lighthouse.',
                createdAt: 1,
              ),
              MemoryAuditEvent(
                id: 'audit_name',
                actor: 'extractor',
                action: 'candidate.approve',
                memoryId: 'mem_name',
                memoryText: 'The user goes by Rodriguez.',
                createdAt: 1,
              ),
            ],
            approveCandidate: (_) async {},
            rejectCandidate: (_) async {},
            approveChangeRequest: (_) async {},
            rejectChangeRequest: (_) async {},
            runMaintenance: () async => const MaintenanceRunResult(
              autoApplied: 0,
              needsReview: 0,
              skipped: 0,
              changeRequests: <MemoryChangeRequest>[],
            ),
            clearData: (_) async => const MemoryClearResult(
              clearedMemory: 0,
              rejectedCandidates: 0,
              rejectedChangeRequests: 0,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('memory-search-field')),
      'blue',
    );
    await tester.pumpAndSettle();

    expect(
      find.text('The verification phrase is blue lighthouse.'),
      findsOneWidget,
    );
    expect(find.text('The user goes by Rodriguez.'), findsNothing);

    await tester.tap(find.text('Candidates'));
    await tester.pumpAndSettle();
    expect(
      find.text('Remember the blue lighthouse verification phrase.'),
      findsOneWidget,
    );
    expect(find.text('The user goes by Rodriguez.'), findsNothing);

    await tester.tap(find.text('Change requests'));
    await tester.pumpAndSettle();
    expect(find.text('Verification phrase: blue lighthouse.'), findsOneWidget);
    expect(find.text('Call the user Rodriguez.'), findsNothing);

    await tester.tap(find.text('Audit log'));
    await tester.pumpAndSettle();
    expect(
      find.text('The verification phrase is blue lighthouse.'),
      findsOneWidget,
    );
    expect(find.text('The user goes by Rodriguez.'), findsNothing);
  });

  testWidgets('All memory cards show the memory source for post-run review', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MemoryExplorerPage(
          actions: MemoryExplorerActions(
            loadMemory: () async => const [
              MemoryRecord(
                id: 'mem_auto',
                kind: 'project_rule',
                scope: 'repo',
                text: 'The verification phrase is blue lighthouse.',
                userId: 'local-user',
                source: 'extractor',
                sourceTurnId: 'turn-extract-1',
                pinned: true,
                profileBlock: {
                  'label': 'project_profile',
                  'description':
                      'Stable project rules and architecture decisions.',
                  'limit': 4,
                },
                status: 'active',
                createdAt: 1,
                updatedAt: 1,
              ),
            ],
            loadCandidates: () async => const <MemoryCandidate>[],
            loadChangeRequests: () async => const <MemoryChangeRequest>[],
            loadAudit: () async => const <MemoryAuditEvent>[],
            approveCandidate: (_) async {},
            rejectCandidate: (_) async {},
            approveChangeRequest: (_) async {},
            rejectChangeRequest: (_) async {},
            runMaintenance: () async => const MaintenanceRunResult(
              autoApplied: 0,
              needsReview: 0,
              skipped: 0,
              changeRequests: <MemoryChangeRequest>[],
            ),
            clearData: (_) async => const MemoryClearResult(
              clearedMemory: 0,
              rejectedCandidates: 0,
              rejectedChangeRequests: 0,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text(
        'project_rule · repo · active · extractor · project_profile · turn turn-extract-1',
      ),
      findsOneWidget,
    );
    expect(
      find.text('The verification phrase is blue lighthouse.'),
      findsOneWidget,
    );
  });

  testWidgets('Candidates tab lists pending candidates and approves them', (
    tester,
  ) async {
    MemoryCandidate? approved;
    await tester.pumpWidget(
      MaterialApp(
        home: MemoryExplorerPage(
          actions: MemoryExplorerActions(
            loadMemory: () async => const <MemoryRecord>[],
            loadCandidates: () async => const [
              MemoryCandidate(
                id: 'cand_1',
                kind: 'project_rule',
                scope: 'repo',
                text: '本项目的验证暗号是：蓝色灯塔-43130。',
                confidence: 0.94,
                reason: '用户明确要求记住。',
                source: 'extractor',
                instructionScopes: ['repo'],
                status: 'pending',
              ),
            ],
            loadChangeRequests: () async => const <MemoryChangeRequest>[],
            loadAudit: () async => const <MemoryAuditEvent>[],
            approveCandidate: (candidate) async => approved = candidate,
            rejectCandidate: (_) async {},
            approveChangeRequest: (_) async {},
            rejectChangeRequest: (_) async {},
            runMaintenance: () async => const MaintenanceRunResult(
              autoApplied: 0,
              needsReview: 0,
              skipped: 0,
              changeRequests: <MemoryChangeRequest>[],
            ),
            clearData: (_) async => const MemoryClearResult(
              clearedMemory: 0,
              rejectedCandidates: 0,
              rejectedChangeRequests: 0,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Candidates'));
    await tester.pumpAndSettle();

    expect(
      find.text('project_rule · repo · 94% · pending · extractor'),
      findsOneWidget,
    );
    expect(find.text('本项目的验证暗号是：蓝色灯塔-43130。'), findsOneWidget);
    expect(find.text('instructions repo'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Approve'));
    await tester.pumpAndSettle();

    expect(approved?.id, 'cand_1');
  });

  testWidgets('Candidates tab bulk approves visible pending candidates', (
    tester,
  ) async {
    final approved = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: MemoryExplorerPage(
          actions: MemoryExplorerActions(
            loadMemory: () async => const <MemoryRecord>[],
            loadCandidates: () async => const [
              MemoryCandidate(
                id: 'cand_blue',
                kind: 'project_rule',
                scope: 'repo',
                text: 'The verification phrase is blue lighthouse.',
                confidence: 0.76,
                reason: 'User mentioned a project phrase.',
                status: 'pending',
              ),
              MemoryCandidate(
                id: 'cand_name',
                kind: 'user_preference',
                scope: 'global',
                text: 'The user goes by Rodriguez.',
                confidence: 0.76,
                reason: 'User stated a name.',
                status: 'pending',
              ),
            ],
            loadChangeRequests: () async => const <MemoryChangeRequest>[],
            loadAudit: () async => const <MemoryAuditEvent>[],
            approveCandidate: (candidate) async => approved.add(candidate.id),
            rejectCandidate: (_) async {},
            approveChangeRequest: (_) async {},
            rejectChangeRequest: (_) async {},
            runMaintenance: () async => const MaintenanceRunResult(
              autoApplied: 0,
              needsReview: 0,
              skipped: 0,
              changeRequests: <MemoryChangeRequest>[],
            ),
            clearData: (_) async => const MemoryClearResult(
              clearedMemory: 0,
              rejectedCandidates: 0,
              rejectedChangeRequests: 0,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('memory-search-field')),
      'blue',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Candidates'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OutlinedButton, 'Approve visible'));
    await tester.pumpAndSettle();

    expect(approved, ['cand_blue']);
  });

  testWidgets('Candidates tab shows reviewed candidates as read-only history', (
    tester,
  ) async {
    var approvedCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: MemoryExplorerPage(
          actions: MemoryExplorerActions(
            loadMemory: () async => const <MemoryRecord>[],
            loadCandidates: () async => const [
              MemoryCandidate(
                id: 'cand_auto',
                kind: 'user_preference',
                scope: 'global',
                text: 'The user goes by Rodriguez.',
                confidence: 0.96,
                reason: 'User explicitly asked to remember this.',
                status: 'approved',
              ),
            ],
            loadChangeRequests: () async => const <MemoryChangeRequest>[],
            loadAudit: () async => const <MemoryAuditEvent>[],
            approveCandidate: (_) async => approvedCalls += 1,
            rejectCandidate: (_) async {},
            approveChangeRequest: (_) async {},
            rejectChangeRequest: (_) async {},
            runMaintenance: () async => const MaintenanceRunResult(
              autoApplied: 0,
              needsReview: 0,
              skipped: 0,
              changeRequests: <MemoryChangeRequest>[],
            ),
            clearData: (_) async => const MemoryClearResult(
              clearedMemory: 0,
              rejectedCandidates: 0,
              rejectedChangeRequests: 0,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Candidates'));
    await tester.pumpAndSettle();

    expect(find.text('The user goes by Rodriguez.'), findsOneWidget);
    expect(
      find.text('user_preference · global · 96% · approved'),
      findsOneWidget,
    );
    expect(find.widgetWithText(TextButton, 'Approve'), findsNothing);
    expect(find.widgetWithText(TextButton, 'Reject'), findsNothing);
    expect(find.widgetWithText(TextButton, 'Edit'), findsNothing);
    expect(approvedCalls, 0);
  });

  testWidgets('All memory tab runs organize and displays summary', (
    tester,
  ) async {
    var organized = false;
    var candidateLoads = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: MemoryExplorerPage(
          actions: MemoryExplorerActions(
            loadMemory: () async => const [
              MemoryRecord(
                id: 'mem_1',
                kind: 'user_preference',
                scope: 'global',
                text: 'The user goes by Rodriguez.',
                userId: 'local-user',
                source: 'manual',
                status: 'active',
                createdAt: 1,
                updatedAt: 1,
              ),
            ],
            loadCandidates: () async {
              candidateLoads += 1;
              return const <MemoryCandidate>[];
            },
            loadChangeRequests: () async => const [
              MemoryChangeRequest(
                id: 'cr_review',
                action: 'merge',
                source: 'maintenance',
                targetMemoryIds: ['mem_old', 'mem_new'],
                targetMemoryText: '用户名字是 Rod。',
                proposedKind: 'user_preference',
                proposedScope: 'global',
                proposedText: '用户希望被称呼为 Rodriguez。',
                reason: '整理发现两条称呼记忆可以合并。',
                confidence: 0.82,
                status: 'pending',
                createdAt: 1,
              ),
            ],
            loadAudit: () async => const <MemoryAuditEvent>[],
            approveCandidate: (_) async {},
            rejectCandidate: (_) async {},
            approveChangeRequest: (_) async {},
            rejectChangeRequest: (_) async {},
            runMaintenance: () async {
              organized = true;
              return const MaintenanceRunResult(
                autoApplied: 2,
                needsReview: 3,
                skipped: 5,
                existingAutoApprovedChangeRequests: 1,
                autoRejectedCandidates: 2,
                autoRejectedChangeRequests: 2,
                changeRequests: <MemoryChangeRequest>[],
              );
            },
            clearData: (_) async => const MemoryClearResult(
              clearedMemory: 0,
              rejectedCandidates: 0,
              rejectedChangeRequests: 0,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(OutlinedButton, 'Organize'));
    await tester.pumpAndSettle();

    expect(organized, isTrue);
    expect(candidateLoads, 2);
    expect(
      find.text('2 auto applied · 3 need review · 4 cleaned · 5 skipped'),
      findsOneWidget,
    );

    await tester.tap(find.widgetWithText(TextButton, 'Review changes'));
    await tester.pumpAndSettle();

    expect(
      find.text('用户希望被称呼为 Rodriguez。', skipOffstage: false),
      findsOneWidget,
    );
    expect(find.text('用户希望被称呼为 Rodriguez。'), findsOneWidget);
  });

  testWidgets('All memory organize links to auto-applied change history', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MemoryExplorerPage(
          actions: MemoryExplorerActions(
            loadMemory: () async => const <MemoryRecord>[],
            loadCandidates: () async => const <MemoryCandidate>[],
            loadChangeRequests: () async => const [
              MemoryChangeRequest(
                id: 'cr_auto',
                action: 'supersede',
                source: 'maintenance',
                targetMemoryIds: ['mem_old'],
                targetMemoryText: '用户名字是 Rod。',
                proposedKind: 'user_preference',
                proposedScope: 'global',
                proposedText: '用户希望被称呼为 Rodriguez。',
                reason: '整理自动应用了高置信称呼修正。',
                confidence: 0.94,
                status: 'approved',
                createdAt: 1,
                reviewedAt: 2,
              ),
            ],
            loadAudit: () async => const <MemoryAuditEvent>[],
            approveCandidate: (_) async {},
            rejectCandidate: (_) async {},
            approveChangeRequest: (_) async {},
            rejectChangeRequest: (_) async {},
            runMaintenance: () async => const MaintenanceRunResult(
              autoApplied: 1,
              needsReview: 0,
              skipped: 0,
              changeRequests: <MemoryChangeRequest>[],
            ),
            clearData: (_) async => const MemoryClearResult(
              clearedMemory: 0,
              rejectedCandidates: 0,
              rejectedChangeRequests: 0,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(OutlinedButton, 'Organize'));
    await tester.pumpAndSettle();

    expect(
      find.text('1 auto applied · 0 need review · 0 skipped'),
      findsOneWidget,
    );

    await tester.tap(find.widgetWithText(TextButton, 'Review changes'));
    await tester.pumpAndSettle();

    expect(find.text('用户希望被称呼为 Rodriguez。'), findsOneWidget);
    expect(
      find.text('supersede · 94% · approved · maintenance'),
      findsOneWidget,
    );
  });

  testWidgets('All memory organize links to cleaned candidate history', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MemoryExplorerPage(
          actions: MemoryExplorerActions(
            loadMemory: () async => const <MemoryRecord>[],
            loadCandidates: () async => const [
              MemoryCandidate(
                id: 'cand_cleaned',
                kind: 'project_rule',
                scope: 'repo',
                text: 'The verification phrase might be blue tower.',
                confidence: 0.61,
                reason: 'Low confidence candidate cleaned by maintenance.',
                status: 'rejected',
              ),
            ],
            loadChangeRequests: () async => const <MemoryChangeRequest>[],
            loadAudit: () async => const <MemoryAuditEvent>[],
            approveCandidate: (_) async {},
            rejectCandidate: (_) async {},
            approveChangeRequest: (_) async {},
            rejectChangeRequest: (_) async {},
            runMaintenance: () async => const MaintenanceRunResult(
              autoApplied: 0,
              needsReview: 0,
              skipped: 0,
              autoRejectedCandidates: 1,
              changeRequests: <MemoryChangeRequest>[],
            ),
            clearData: (_) async => const MemoryClearResult(
              clearedMemory: 0,
              rejectedCandidates: 0,
              rejectedChangeRequests: 0,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(OutlinedButton, 'Organize'));
    await tester.pumpAndSettle();

    expect(
      find.text('0 auto applied · 0 need review · 1 cleaned · 0 skipped'),
      findsOneWidget,
    );

    await tester.tap(find.widgetWithText(TextButton, 'Review candidates'));
    await tester.pumpAndSettle();

    expect(
      find.text('The verification phrase might be blue tower.'),
      findsOneWidget,
    );
    expect(find.text('project_rule · repo · 61% · rejected'), findsOneWidget);
  });

  testWidgets('All memory tab submits post-run feedback for active memory', (
    tester,
  ) async {
    final feedback = <String, String?>{};
    await tester.pumpWidget(
      MaterialApp(
        home: MemoryExplorerPage(
          actions: MemoryExplorerActions(
            loadMemory: () async => const [
              MemoryRecord(
                id: 'mem_1',
                kind: 'project_rule',
                scope: 'repo',
                text: 'The verification phrase is blue lighthouse.',
                userId: 'local-user',
                source: 'extractor',
                status: 'active',
                createdAt: 1,
                updatedAt: 1,
              ),
            ],
            loadCandidates: () async => const <MemoryCandidate>[],
            loadChangeRequests: () async => const <MemoryChangeRequest>[],
            loadAudit: () async => const <MemoryAuditEvent>[],
            approveCandidate: (_) async {},
            rejectCandidate: (_) async {},
            approveChangeRequest: (_) async {},
            rejectChangeRequest: (_) async {},
            submitFeedback: (record, rating, reason) async {
              feedback['memoryId'] = record.id;
              feedback['rating'] = rating;
              feedback['reason'] = reason;
            },
            runMaintenance: () async => const MaintenanceRunResult(
              autoApplied: 0,
              needsReview: 0,
              skipped: 0,
              changeRequests: <MemoryChangeRequest>[],
            ),
            clearData: (_) async => const MemoryClearResult(
              clearedMemory: 0,
              rejectedCandidates: 0,
              rejectedChangeRequests: 0,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(TextButton, 'Stale'));
    await tester.pumpAndSettle();

    expect(feedback['memoryId'], 'mem_1');
    expect(feedback['rating'], 'stale');
    expect(feedback['reason'], 'Marked stale from Memory Explorer.');
  });

  testWidgets(
    'All memory tab edits, disables, and restores reviewed memories',
    (tester) async {
      var records = const [
        MemoryRecord(
          id: 'mem_1',
          kind: 'project_rule',
          scope: 'repo',
          text: 'The verification phrase is blue lighthouse.',
          userId: 'local-user',
          source: 'extractor',
          status: 'active',
          createdAt: 1,
          updatedAt: 1,
        ),
      ];
      MemoryRecord? edited;
      MemoryRecord? disabled;
      MemoryRecord? restored;

      await tester.pumpWidget(
        MaterialApp(
          home: MemoryExplorerPage(
            actions: MemoryExplorerActions(
              loadMemory: () async => records,
              loadCandidates: () async => const <MemoryCandidate>[],
              loadChangeRequests: () async => const <MemoryChangeRequest>[],
              loadAudit: () async => const <MemoryAuditEvent>[],
              approveCandidate: (_) async {},
              rejectCandidate: (_) async {},
              approveChangeRequest: (_) async {},
              rejectChangeRequest: (_) async {},
              updateMemory: (record) async {
                edited = record;
                records = [record];
              },
              disableMemory: (record) async {
                disabled = record;
                records = [record.copyWith(status: 'disabled')];
              },
              restoreMemory: (record) async {
                restored = record;
                records = [record.copyWith(status: 'active')];
              },
              runMaintenance: () async => const MaintenanceRunResult(
                autoApplied: 0,
                needsReview: 0,
                skipped: 0,
                changeRequests: <MemoryChangeRequest>[],
              ),
              clearData: (_) async => const MemoryClearResult(
                clearedMemory: 0,
                rejectedCandidates: 0,
                rejectedChangeRequests: 0,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('The verification phrase is blue lighthouse.'),
        findsOneWidget,
      );

      await tester.tap(find.widgetWithText(TextButton, 'Edit'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField).last,
        'The verification phrase is green lighthouse.',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect(edited?.id, 'mem_1');
      expect(edited?.text, 'The verification phrase is green lighthouse.');

      await tester.tap(find.widgetWithText(TextButton, 'Disable'));
      await tester.pumpAndSettle();

      expect(disabled?.id, 'mem_1');
      expect(
        find.text('project_rule · repo · disabled · extractor'),
        findsOneWidget,
      );
      expect(find.widgetWithText(TextButton, 'Disable'), findsNothing);
      expect(find.widgetWithText(TextButton, 'Edit'), findsNothing);
      expect(find.widgetWithText(TextButton, 'Restore'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Restore'));
      await tester.pumpAndSettle();

      expect(restored?.id, 'mem_1');
      expect(
        find.text('project_rule · repo · active · extractor'),
        findsOneWidget,
      );
      expect(find.widgetWithText(TextButton, 'Edit'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Disable'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Restore'), findsNothing);
    },
  );

  testWidgets('Change requests tab lists and approves real requests', (
    tester,
  ) async {
    MemoryChangeRequest? approved;
    await tester.pumpWidget(
      MaterialApp(
        home: MemoryExplorerPage(
          actions: MemoryExplorerActions(
            loadMemory: () async => const <MemoryRecord>[],
            loadCandidates: () async => const <MemoryCandidate>[],
            loadChangeRequests: () async => const [
              MemoryChangeRequest(
                id: 'cr_1',
                action: 'merge',
                source: 'maintenance',
                targetMemoryIds: ['mem_1', 'mem_2'],
                targetMemoryText: 'The user goes by Rod.',
                proposedKind: 'user_preference',
                proposedScope: 'global',
                proposedText: 'The user goes by Rodriguez.',
                reason: 'Duplicate user name memories.',
                confidence: 0.93,
                status: 'pending',
                createdAt: 1,
              ),
            ],
            loadAudit: () async => const <MemoryAuditEvent>[],
            approveCandidate: (_) async {},
            rejectCandidate: (_) async {},
            approveChangeRequest: (request) async => approved = request,
            rejectChangeRequest: (_) async {},
            runMaintenance: () async => const MaintenanceRunResult(
              autoApplied: 0,
              needsReview: 0,
              skipped: 0,
              changeRequests: <MemoryChangeRequest>[],
            ),
            clearData: (_) async => const MemoryClearResult(
              clearedMemory: 0,
              rejectedCandidates: 0,
              rejectedChangeRequests: 0,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Change requests'));
    await tester.pumpAndSettle();

    expect(find.text('merge · 93% · pending · maintenance'), findsOneWidget);
    expect(find.text('target mem_1, mem_2'), findsOneWidget);
    expect(find.text('The user goes by Rodriguez.'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Approve'));
    await tester.pumpAndSettle();

    expect(approved?.id, 'cr_1');
  });

  testWidgets('Change requests tab persists edits before approval', (
    tester,
  ) async {
    var current = const MemoryChangeRequest(
      id: 'cr_1',
      action: 'update',
      source: 'maintenance',
      targetMemoryIds: ['mem_1'],
      targetMemoryText: 'The user goes by Rod.',
      proposedKind: 'user_preference',
      proposedScope: 'global',
      proposedText: 'The user goes by Rodriguez.',
      reason: 'Clarify preferred name.',
      confidence: 0.82,
      status: 'pending',
      createdAt: 1,
    );
    MemoryChangeRequest? updated;
    MemoryChangeRequest? approved;

    await tester.pumpWidget(
      MaterialApp(
        home: MemoryExplorerPage(
          actions: MemoryExplorerActions(
            loadMemory: () async => const <MemoryRecord>[],
            loadCandidates: () async => const <MemoryCandidate>[],
            loadChangeRequests: () async => [current],
            loadAudit: () async => const <MemoryAuditEvent>[],
            approveCandidate: (_) async {},
            rejectCandidate: (_) async {},
            approveChangeRequest: (request) async => approved = request,
            rejectChangeRequest: (_) async {},
            updateChangeRequest: (request) async {
              updated = request;
              current = request;
              return request;
            },
            runMaintenance: () async => const MaintenanceRunResult(
              autoApplied: 0,
              needsReview: 0,
              skipped: 0,
              changeRequests: <MemoryChangeRequest>[],
            ),
            clearData: (_) async => const MemoryClearResult(
              clearedMemory: 0,
              rejectedCandidates: 0,
              rejectedChangeRequests: 0,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Change requests'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Edit'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField).last,
      'Call the user Rodriguez.',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(updated?.proposedText, 'Call the user Rodriguez.');
    expect(find.text('Call the user Rodriguez.'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Approve'));
    await tester.pumpAndSettle();

    expect(approved?.proposedText, 'Call the user Rodriguez.');
  });

  testWidgets('Change requests tab bulk rejects visible pending requests', (
    tester,
  ) async {
    final rejected = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: MemoryExplorerPage(
          actions: MemoryExplorerActions(
            loadMemory: () async => const <MemoryRecord>[],
            loadCandidates: () async => const <MemoryCandidate>[],
            loadChangeRequests: () async => const [
              MemoryChangeRequest(
                id: 'cr_blue',
                action: 'summarize',
                targetMemoryIds: ['mem_blue'],
                targetMemoryText: 'The verification phrase is blue lighthouse.',
                proposedText: 'Verification phrase: blue lighthouse.',
                reason: 'Shorten project phrase memory.',
                confidence: 0.8,
                status: 'pending',
                createdAt: 1,
              ),
              MemoryChangeRequest(
                id: 'cr_name',
                action: 'update',
                targetMemoryIds: ['mem_name'],
                targetMemoryText: 'The user goes by Rodriguez.',
                proposedText: 'Call the user Rodriguez.',
                reason: 'Name preference.',
                confidence: 0.8,
                status: 'pending',
                createdAt: 1,
              ),
            ],
            loadAudit: () async => const <MemoryAuditEvent>[],
            approveCandidate: (_) async {},
            rejectCandidate: (_) async {},
            approveChangeRequest: (_) async {},
            rejectChangeRequest: (request) async => rejected.add(request.id),
            runMaintenance: () async => const MaintenanceRunResult(
              autoApplied: 0,
              needsReview: 0,
              skipped: 0,
              changeRequests: <MemoryChangeRequest>[],
            ),
            clearData: (_) async => const MemoryClearResult(
              clearedMemory: 0,
              rejectedCandidates: 0,
              rejectedChangeRequests: 0,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('memory-search-field')),
      'blue',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Change requests'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OutlinedButton, 'Reject visible'));
    await tester.pumpAndSettle();

    expect(rejected, ['cr_blue']);
  });

  testWidgets('Change requests tab shows reviewed requests as read-only', (
    tester,
  ) async {
    var approvedCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: MemoryExplorerPage(
          actions: MemoryExplorerActions(
            loadMemory: () async => const <MemoryRecord>[],
            loadCandidates: () async => const <MemoryCandidate>[],
            loadChangeRequests: () async => const [
              MemoryChangeRequest(
                id: 'cr_auto',
                action: 'supersede',
                targetMemoryIds: ['mem_old'],
                targetMemoryText:
                    'The project verification phrase is red bridge.',
                proposedKind: 'project_rule',
                proposedScope: 'repo',
                proposedText:
                    'The project verification phrase is blue lighthouse.',
                reason: 'High-confidence candidate updated the same topic.',
                confidence: 0.94,
                status: 'approved',
                createdAt: 1,
                reviewedAt: 2,
              ),
            ],
            loadAudit: () async => const <MemoryAuditEvent>[],
            approveCandidate: (_) async {},
            rejectCandidate: (_) async {},
            approveChangeRequest: (_) async => approvedCalls += 1,
            rejectChangeRequest: (_) async {},
            runMaintenance: () async => const MaintenanceRunResult(
              autoApplied: 0,
              needsReview: 0,
              skipped: 0,
              changeRequests: <MemoryChangeRequest>[],
            ),
            clearData: (_) async => const MemoryClearResult(
              clearedMemory: 0,
              rejectedCandidates: 0,
              rejectedChangeRequests: 0,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Change requests'));
    await tester.pumpAndSettle();

    expect(find.text('supersede · 94% · approved'), findsOneWidget);
    expect(
      find.text('The project verification phrase is blue lighthouse.'),
      findsOneWidget,
    );
    expect(find.widgetWithText(TextButton, 'Approve'), findsNothing);
    expect(find.widgetWithText(TextButton, 'Reject'), findsNothing);
    expect(find.widgetWithText(TextButton, 'Edit'), findsNothing);
    expect(approvedCalls, 0);
  });

  testWidgets('Audit tab lists retrieved memory events', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MemoryExplorerPage(
          actions: MemoryExplorerActions(
            loadMemory: () async => const <MemoryRecord>[],
            loadCandidates: () async => const <MemoryCandidate>[],
            loadChangeRequests: () async => const <MemoryChangeRequest>[],
            loadAudit: () async => const [
              MemoryAuditEvent(
                id: 'audit_1',
                actor: 'system',
                action: 'memory.retrieve',
                memoryId: 'mem_1',
                memoryText: 'The user goes by Rodriguez.',
                payload: {
                  'score': 0.9,
                  'diagnostics': {
                    'lexicalScore': 1.0,
                    'pinnedLayer': true,
                    'feedbackScore': 0.65,
                    'accessCount': 3,
                  },
                },
                createdAt: 42,
              ),
            ],
            approveCandidate: (_) async {},
            rejectCandidate: (_) async {},
            approveChangeRequest: (_) async {},
            rejectChangeRequest: (_) async {},
            runMaintenance: () async => const MaintenanceRunResult(
              autoApplied: 0,
              needsReview: 0,
              skipped: 0,
              changeRequests: <MemoryChangeRequest>[],
            ),
            clearData: (_) async => const MemoryClearResult(
              clearedMemory: 0,
              rejectedCandidates: 0,
              rejectedChangeRequests: 0,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Audit log'));
    await tester.pumpAndSettle();

    expect(find.text('memory.retrieve · system'), findsOneWidget);
    expect(find.text('The user goes by Rodriguez.'), findsOneWidget);
    expect(
      find.text('score 90% · pinned · lexical 100% · feedback 65% · used 3x'),
      findsOneWidget,
    );
  });

  testWidgets('Audit tab explains automatic memory layer changes', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MemoryExplorerPage(
          actions: MemoryExplorerActions(
            loadMemory: () async => const <MemoryRecord>[],
            loadCandidates: () async => const <MemoryCandidate>[],
            loadChangeRequests: () async => const <MemoryChangeRequest>[],
            loadAudit: () async => const [
              MemoryAuditEvent(
                id: 'audit_promote',
                actor: 'system',
                action: 'memory.promote',
                memoryId: 'mem_1',
                memoryText:
                    'The release verification phrase is blue lighthouse.',
                payload: {
                  'reason': 'access_reinforcement',
                  'accessCount': 3,
                  'threshold': 3,
                },
                createdAt: 43,
              ),
              MemoryAuditEvent(
                id: 'audit_expire',
                actor: 'system',
                action: 'memory.expire',
                memoryId: 'mem_2',
                memoryText: 'The user goes by Rodriguez.',
                payload: {
                  'reason': 'stale_feedback',
                  'feedbackReason': 'User corrected this memory.',
                },
                createdAt: 44,
              ),
            ],
            approveCandidate: (_) async {},
            rejectCandidate: (_) async {},
            approveChangeRequest: (_) async {},
            rejectChangeRequest: (_) async {},
            runMaintenance: () async => const MaintenanceRunResult(
              autoApplied: 0,
              needsReview: 0,
              skipped: 0,
              changeRequests: <MemoryChangeRequest>[],
            ),
            clearData: (_) async => const MemoryClearResult(
              clearedMemory: 0,
              rejectedCandidates: 0,
              rejectedChangeRequests: 0,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Audit log'));
    await tester.pumpAndSettle();

    expect(find.text('memory.promote · system'), findsOneWidget);
    expect(
      find.text('promoted · access reinforcement · used 3x · threshold 3'),
      findsOneWidget,
    );
    expect(find.text('memory.expire · system'), findsOneWidget);
    expect(
      find.text('expired · stale feedback · User corrected this memory.'),
      findsOneWidget,
    );
  });

  testWidgets('Audit tab explains automatic disable reasons', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MemoryExplorerPage(
          actions: MemoryExplorerActions(
            loadMemory: () async => const <MemoryRecord>[],
            loadCandidates: () async => const <MemoryCandidate>[],
            loadChangeRequests: () async => const <MemoryChangeRequest>[],
            loadAudit: () async => const [
              MemoryAuditEvent(
                id: 'audit_disable',
                actor: 'system',
                action: 'memory.disable',
                memoryId: 'mem_3',
                memoryText: 'The old verification phrase is blue lighthouse.',
                payload: {
                  'reason': 'repeated_not_relevant_feedback',
                  'feedbackReason': 'Marked not relevant twice.',
                },
                createdAt: 45,
              ),
            ],
            approveCandidate: (_) async {},
            rejectCandidate: (_) async {},
            approveChangeRequest: (_) async {},
            rejectChangeRequest: (_) async {},
            runMaintenance: () async => const MaintenanceRunResult(
              autoApplied: 0,
              needsReview: 0,
              skipped: 0,
              changeRequests: <MemoryChangeRequest>[],
            ),
            clearData: (_) async => const MemoryClearResult(
              clearedMemory: 0,
              rejectedCandidates: 0,
              rejectedChangeRequests: 0,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Audit log'));
    await tester.pumpAndSettle();

    expect(find.text('memory.disable · system'), findsOneWidget);
    expect(
      find.text(
        'disabled · repeated not relevant feedback · Marked not relevant twice.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('Audit tab filters events by category', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MemoryExplorerPage(
          actions: MemoryExplorerActions(
            loadMemory: () async => const <MemoryRecord>[],
            loadCandidates: () async => const <MemoryCandidate>[],
            loadChangeRequests: () async => const <MemoryChangeRequest>[],
            loadAudit: () async => const [
              MemoryAuditEvent(
                id: 'audit_retrieve',
                actor: 'system',
                action: 'memory.retrieve',
                memoryId: 'mem_1',
                memoryText: 'Retrieved memory text.',
                createdAt: 42,
              ),
              MemoryAuditEvent(
                id: 'audit_candidate',
                actor: 'extractor',
                action: 'candidate.approve',
                candidateId: 'cand_1',
                candidateText: 'Approved candidate text.',
                createdAt: 43,
              ),
              MemoryAuditEvent(
                id: 'audit_clear',
                actor: 'user',
                action: 'memory.clear',
                createdAt: 44,
              ),
            ],
            approveCandidate: (_) async {},
            rejectCandidate: (_) async {},
            approveChangeRequest: (_) async {},
            rejectChangeRequest: (_) async {},
            runMaintenance: () async => const MaintenanceRunResult(
              autoApplied: 0,
              needsReview: 0,
              skipped: 0,
              changeRequests: <MemoryChangeRequest>[],
            ),
            clearData: (_) async => const MemoryClearResult(
              clearedMemory: 0,
              rejectedCandidates: 0,
              rejectedChangeRequests: 0,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Audit log'));
    await tester.pumpAndSettle();

    expect(find.text('memory.retrieve · system'), findsOneWidget);
    expect(find.text('candidate.approve · extractor'), findsOneWidget);

    await tester.tap(find.text('Retrieval'));
    await tester.pumpAndSettle();

    expect(find.text('memory.retrieve · system'), findsOneWidget);
    expect(find.text('candidate.approve · extractor'), findsNothing);
    expect(find.text('memory.clear · user'), findsNothing);

    await tester.tap(find.text('Candidate events'));
    await tester.pumpAndSettle();

    expect(find.text('memory.retrieve · system'), findsNothing);
    expect(find.text('candidate.approve · extractor'), findsOneWidget);
    expect(find.text('memory.clear · user'), findsNothing);

    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();

    expect(find.text('memory.retrieve · system'), findsNothing);
    expect(find.text('candidate.approve · extractor'), findsNothing);
    expect(find.text('memory.clear · user'), findsOneWidget);
  });
}
