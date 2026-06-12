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

  testWidgets('Change requests tab lists and reviews real requests', (
    tester,
  ) async {
    var loadCount = 0;
    var memoryLoadCount = 0;
    final approved = <MemoryChangeRequest>[];
    final rejected = <String>[];
    var requests = const [
      MemoryChangeRequest(
        id: 'cr_update',
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
      ),
      MemoryChangeRequest(
        id: 'cr_delete',
        action: 'delete',
        source: 'maintenance',
        targetMemoryIds: ['mem_2'],
        targetMemoryText: 'Old temporary project note.',
        reason: 'No longer valid.',
        confidence: 0.78,
        status: 'pending',
        createdAt: 2,
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: MemoryExplorerPage(
          actions: MemoryExplorerActions(
            loadMemory: () async {
              memoryLoadCount += 1;
              return const [
                MemoryRecord(
                  id: 'mem_1',
                  kind: 'user_preference',
                  scope: 'global',
                  text: 'The user goes by Rod.',
                  status: 'active',
                  createdAt: 1,
                  updatedAt: 1,
                ),
              ];
            },
            loadChangeRequests: () async {
              loadCount += 1;
              return requests;
            },
            approveChangeRequest: (request) async {
              approved.add(request);
              requests = requests
                  .where((item) => item.id != request.id)
                  .toList(growable: false);
            },
            rejectChangeRequest: (request) async {
              rejected.add(request.id);
              requests = requests
                  .where((item) => item.id != request.id)
                  .toList(growable: false);
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Change requests'));
    await tester.pumpAndSettle();

    expect(find.text('update · 82% · pending · maintenance'), findsOneWidget);
    expect(find.text('The user goes by Rod.'), findsOneWidget);
    expect(find.text('The user goes by Rodriguez.'), findsOneWidget);
    expect(find.text('delete · 78% · pending · maintenance'), findsOneWidget);

    await tester.tap(find.byTooltip('Edit change request'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Proposed text'),
      'The user goes by Rodriguez Fai.',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(find.text('The user goes by Rodriguez Fai.'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Approve').first);
    await tester.pumpAndSettle();

    expect(approved.map((request) => request.id), ['cr_update']);
    expect(approved.single.proposedText, 'The user goes by Rodriguez Fai.');
    expect(loadCount, 2);
    expect(memoryLoadCount, 2);
    expect(find.text('The user goes by Rodriguez Fai.'), findsNothing);

    await tester.tap(find.widgetWithText(TextButton, 'Reject'));
    await tester.pumpAndSettle();

    expect(rejected, ['cr_delete']);
    expect(loadCount, 3);
    expect(find.text('No change requests yet.'), findsOneWidget);
  });

  testWidgets('Change requests tab can approve all safe pending requests', (
    tester,
  ) async {
    final approved = <String>[];
    var requests = const [
      MemoryChangeRequest(
        id: 'cr_update',
        action: 'update',
        source: 'maintenance',
        targetMemoryIds: ['mem_1'],
        proposedText: 'The user goes by Rodriguez.',
        confidence: 0.82,
        status: 'pending',
        createdAt: 1,
      ),
      MemoryChangeRequest(
        id: 'cr_merge',
        action: 'merge',
        source: 'maintenance',
        targetMemoryIds: ['mem_2', 'mem_3'],
        proposedText: 'Use curl for service checks.',
        confidence: 0.81,
        status: 'pending',
        createdAt: 2,
      ),
      MemoryChangeRequest(
        id: 'cr_delete',
        action: 'delete',
        source: 'maintenance',
        targetMemoryIds: ['mem_4'],
        confidence: 0.96,
        status: 'pending',
        createdAt: 3,
      ),
      MemoryChangeRequest(
        id: 'cr_disable',
        action: 'disable',
        source: 'maintenance',
        targetMemoryIds: ['mem_5'],
        confidence: 0.94,
        status: 'pending',
        createdAt: 4,
      ),
      MemoryChangeRequest(
        id: 'cr_expire',
        action: 'expire',
        source: 'maintenance',
        targetMemoryIds: ['mem_6'],
        confidence: 0.95,
        status: 'pending',
        createdAt: 5,
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: MemoryExplorerPage(
          actions: MemoryExplorerActions(
            loadChangeRequests: () async => requests,
            approveChangeRequest: (request) async {
              approved.add(request.id);
              requests = requests
                  .where((item) => item.id != request.id)
                  .toList(growable: false);
            },
            rejectChangeRequest: (_) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Change requests'));
    await tester.pumpAndSettle();

    await tester.tap(
      find.widgetWithText(FilledButton, 'Approve safe changes (2)'),
    );
    await tester.pumpAndSettle();

    expect(approved, ['cr_update', 'cr_merge']);
    expect(find.text('delete · 96% · pending · maintenance'), findsOneWidget);
    expect(find.text('disable · 94% · pending · maintenance'), findsOneWidget);
    expect(find.text('expire · 95% · pending · maintenance'), findsOneWidget);
    expect(find.text('Approve safe changes (2)'), findsNothing);
  });

  testWidgets('Change request batch approve keeps going after stale request', (
    tester,
  ) async {
    final approved = <String>[];
    var requests = const [
      MemoryChangeRequest(
        id: 'cr_stale',
        action: 'update',
        source: 'maintenance',
        targetMemoryIds: ['mem_1'],
        proposedText: 'The user goes by Rodriguez.',
        confidence: 0.91,
        status: 'pending',
        createdAt: 1,
      ),
      MemoryChangeRequest(
        id: 'cr_merge',
        action: 'merge',
        source: 'maintenance',
        targetMemoryIds: ['mem_2', 'mem_3'],
        proposedText: 'Use curl for service checks.',
        confidence: 0.92,
        status: 'pending',
        createdAt: 2,
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: MemoryExplorerPage(
          actions: MemoryExplorerActions(
            loadChangeRequests: () async => requests,
            approveChangeRequest: (request) async {
              if (request.id == 'cr_stale') {
                throw Exception('stale change request');
              }
              approved.add(request.id);
              requests = requests
                  .where((item) => item.id != request.id)
                  .toList(growable: false);
            },
            rejectChangeRequest: (_) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Change requests'));
    await tester.pumpAndSettle();

    await tester.tap(
      find.widgetWithText(FilledButton, 'Approve safe changes (2)'),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(approved, ['cr_merge']);
  });

  testWidgets('Change requests tab can reject all pending requests', (
    tester,
  ) async {
    final rejected = <String>[];
    var requests = const [
      MemoryChangeRequest(
        id: 'cr_update',
        action: 'update',
        source: 'maintenance',
        targetMemoryIds: ['mem_1'],
        proposedText: 'The user goes by Rodriguez.',
        confidence: 0.82,
        status: 'pending',
        createdAt: 1,
      ),
      MemoryChangeRequest(
        id: 'cr_delete',
        action: 'delete',
        source: 'maintenance',
        targetMemoryIds: ['mem_2'],
        confidence: 0.96,
        status: 'pending',
        createdAt: 2,
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: MemoryExplorerPage(
          actions: MemoryExplorerActions(
            loadChangeRequests: () async => requests,
            approveChangeRequest: (_) async {},
            rejectChangeRequest: (request) async {
              rejected.add(request.id);
              requests = requests
                  .where((item) => item.id != request.id)
                  .toList(growable: false);
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Change requests'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(OutlinedButton, 'Reject all (2)'));
    await tester.pumpAndSettle();

    expect(rejected, ['cr_update', 'cr_delete']);
    expect(find.text('No change requests yet.'), findsOneWidget);
  });

  testWidgets('Candidates tab lists and reviews real candidates', (
    tester,
  ) async {
    final approved = <MemoryCandidate>[];
    final rejected = <String>[];
    var candidates = const [
      MemoryCandidate(
        id: 'cand_1',
        kind: 'project_rule',
        scope: 'repo',
        text: 'Use curl for service checks.',
        confidence: 0.82,
        reason: 'Durable project rule.',
        status: 'pending',
        createdAt: 1,
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: MemoryExplorerPage(
          actions: MemoryExplorerActions(
            loadChangeRequests: () async => const <MemoryChangeRequest>[],
            loadCandidates: () async => candidates,
            approveCandidate: (candidate) async {
              approved.add(candidate);
              candidates = const <MemoryCandidate>[];
            },
            rejectCandidate: (candidate) async {
              rejected.add(candidate.id);
              candidates = const <MemoryCandidate>[];
            },
            approveChangeRequest: (_) async {},
            rejectChangeRequest: (_) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Candidates'));
    await tester.pumpAndSettle();

    expect(find.text('project_rule · repo · 82% · pending'), findsOneWidget);
    expect(find.text('Use curl for service checks.'), findsOneWidget);

    await tester.tap(find.byTooltip('Edit candidate'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Text'),
      'Use curl and lsof for service checks.',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(find.text('Use curl and lsof for service checks.'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Approve'));
    await tester.pumpAndSettle();

    expect(approved.single.id, 'cand_1');
    expect(approved.single.text, 'Use curl and lsof for service checks.');
    expect(find.text('No candidates yet.'), findsOneWidget);
  });

  testWidgets('Candidates tab can approve all pending candidates', (
    tester,
  ) async {
    final approved = <String>[];
    var candidates = const [
      MemoryCandidate(
        id: 'cand_1',
        kind: 'user_preference',
        scope: 'global',
        text: 'The user goes by Rodriguez.',
        confidence: 0.82,
        status: 'pending',
        createdAt: 1,
      ),
      MemoryCandidate(
        id: 'cand_2',
        kind: 'project_rule',
        scope: 'repo',
        text: 'Use curl for service checks.',
        confidence: 0.81,
        status: 'pending',
        createdAt: 2,
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: MemoryExplorerPage(
          actions: MemoryExplorerActions(
            loadChangeRequests: () async => const <MemoryChangeRequest>[],
            loadCandidates: () async => candidates,
            approveCandidate: (candidate) async {
              approved.add(candidate.id);
              candidates = candidates
                  .where((item) => item.id != candidate.id)
                  .toList(growable: false);
            },
            rejectCandidate: (_) async {},
            approveChangeRequest: (_) async {},
            rejectChangeRequest: (_) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Candidates'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Approve all (2)'));
    await tester.pumpAndSettle();

    expect(approved, ['cand_1', 'cand_2']);
    expect(find.text('No candidates yet.'), findsOneWidget);
  });

  testWidgets('Candidates tab can reject all pending candidates', (
    tester,
  ) async {
    final rejected = <String>[];
    var candidates = const [
      MemoryCandidate(
        id: 'cand_1',
        kind: 'user_preference',
        scope: 'global',
        text: 'The user goes by Rodriguez.',
        confidence: 0.62,
        status: 'pending',
        createdAt: 1,
      ),
      MemoryCandidate(
        id: 'cand_2',
        kind: 'session_summary',
        scope: 'session',
        text: 'Temporary note.',
        confidence: 0.58,
        status: 'pending',
        createdAt: 2,
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: MemoryExplorerPage(
          actions: MemoryExplorerActions(
            loadChangeRequests: () async => const <MemoryChangeRequest>[],
            loadCandidates: () async => candidates,
            approveCandidate: (_) async {},
            rejectCandidate: (candidate) async {
              rejected.add(candidate.id);
              candidates = candidates
                  .where((item) => item.id != candidate.id)
                  .toList(growable: false);
            },
            approveChangeRequest: (_) async {},
            rejectChangeRequest: (_) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Candidates'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(OutlinedButton, 'Reject all (2)'));
    await tester.pumpAndSettle();

    expect(rejected, ['cand_1', 'cand_2']);
    expect(find.text('No candidates yet.'), findsOneWidget);
  });

  testWidgets('All memory tab lists, edits, and deletes real records', (
    tester,
  ) async {
    final updated = <String>[];
    final deleted = <String>[];
    var records = const [
      MemoryRecord(
        id: 'mem_1',
        kind: 'user_preference',
        scope: 'global',
        text: 'The user goes by Rod.',
        status: 'active',
        createdAt: 1,
        updatedAt: 2,
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: MemoryExplorerPage(
          actions: MemoryExplorerActions(
            loadMemory: () async => records,
            updateMemory: (record) async {
              updated.add(record.text);
              records = [record];
            },
            deleteMemory: (record) async {
              deleted.add(record.id);
              records = const <MemoryRecord>[];
            },
            loadChangeRequests: () async => const <MemoryChangeRequest>[],
            approveChangeRequest: (_) async {},
            rejectChangeRequest: (_) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('user_preference · global · active'), findsOneWidget);
    expect(find.text('The user goes by Rod.'), findsOneWidget);

    await tester.tap(find.byTooltip('Edit memory'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Text'),
      'The user goes by Rodriguez.',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(updated, ['The user goes by Rodriguez.']);
    expect(find.text('The user goes by Rodriguez.'), findsOneWidget);

    await tester.tap(find.byTooltip('Delete memory'));
    await tester.pumpAndSettle();

    expect(deleted, ['mem_1']);
    expect(find.text('No memory records yet.'), findsOneWidget);
  });

  testWidgets('All memory tab runs organize and refreshes change requests', (
    tester,
  ) async {
    var organized = false;
    var requests = const <MemoryChangeRequest>[];

    await tester.pumpWidget(
      MaterialApp(
        home: MemoryExplorerPage(
          actions: MemoryExplorerActions(
            loadChangeRequests: () async => requests,
            approveChangeRequest: (_) async {},
            rejectChangeRequest: (_) async {},
            runMaintenance: () async {
              organized = true;
              requests = const [
                MemoryChangeRequest(
                  id: 'cr_merge',
                  action: 'merge',
                  source: 'maintenance',
                  targetMemoryIds: ['mem_1', 'mem_2'],
                  targetMemoryText: 'The user goes by Rod.',
                  proposedText: 'The user goes by Rodriguez.',
                  reason: 'Duplicate memory.',
                  confidence: 0.82,
                  status: 'pending',
                  createdAt: 1,
                ),
              ];
              return MaintenanceRunResult(
                autoApplied: 0,
                needsReview: 1,
                skipped: 2,
                changeRequests: requests,
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Organize'));
    await tester.pumpAndSettle();

    expect(organized, isTrue);
    expect(
      find.text('0 auto applied · 1 need review · 2 skipped'),
      findsOneWidget,
    );
    expect(find.text('Review change requests'), findsOneWidget);

    await tester.tap(find.text('Review change requests'));
    await tester.pumpAndSettle();

    expect(find.text('merge · 82% · pending · maintenance'), findsOneWidget);
  });

  testWidgets('Audit log tab presents audit entries for users', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MemoryExplorerPage(
          actions: MemoryExplorerActions(
            loadChangeRequests: () async => const <MemoryChangeRequest>[],
            approveChangeRequest: (_) async {},
            rejectChangeRequest: (_) async {},
            loadAuditLog: () async => const [
              MemoryAuditEntry(
                id: 'audit_search',
                actor: 'system',
                action: 'memory.search',
                payload: {
                  'resultCount': 3,
                  'memoryIds': ['mem_1', 'mem_2', 'mem_3'],
                  'queryHash': 'hash_1',
                  'hits': [
                    {'id': 'mem_1', 'text': '用户自称 Rodriguez。'},
                    {'id': 'mem_2', 'text': '用户偏好中文回复。'},
                  ],
                },
                createdAt: 3,
              ),
              MemoryAuditEntry(
                id: 'audit_auto',
                actor: 'system',
                action: 'candidate.auto_approve',
                memoryId: 'mem_saved',
                candidateId: 'cand_1',
                payload: {'text': '用户自称 Rodriguez。', 'confidence': 0.93},
                createdAt: 2,
              ),
              MemoryAuditEntry(
                id: 'audit_candidate_create',
                actor: 'extractor',
                action: 'candidate.create',
                candidateId: 'cand_1',
                payload: {'text': '用户自称 Rodriguez。', 'confidence': 0.93},
                createdAt: 2,
              ),
              MemoryAuditEntry(
                id: 'audit_memory_create',
                actor: 'user',
                action: 'memory.create',
                memoryId: 'mem_saved',
                payload: {'text': '用户自称 Rodriguez。', 'source': 'manual'},
                createdAt: 2,
              ),
              MemoryAuditEntry(
                id: 'audit_change_request_approve',
                actor: 'user',
                action: 'change_request.approve',
                changeRequestId: 'cr_1',
                payload: {'action': 'delete'},
                createdAt: 1,
              ),
              MemoryAuditEntry(
                id: 'audit_delete',
                actor: 'user',
                action: 'memory.delete',
                memoryId: 'mem_deleted',
                changeRequestId: 'cr_1',
                payload: {'text': '旧的临时记忆。', 'soft': true},
                createdAt: 1,
              ),
              MemoryAuditEntry(
                id: 'audit_merge',
                actor: 'user',
                action: 'memory.merge',
                memoryId: 'mem_merged',
                changeRequestId: 'cr_merge',
                payload: {
                  'text': '用户偏好中文回复。',
                  'targetMemoryIds': ['mem_old_1', 'mem_old_2'],
                },
                createdAt: 1,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Audit log'));
    await tester.pumpAndSettle();

    expect(find.text('已检索记忆'), findsOneWidget);
    expect(find.text('检索了 3 条记忆'), findsOneWidget);
    expect(find.text('命中：用户自称 Rodriguez。、用户偏好中文回复。'), findsOneWidget);
    expect(find.text('已自动保存记忆'), findsOneWidget);
    expect(find.text('内容：用户自称 Rodriguez。'), findsOneWidget);
    expect(find.text('来源：对话提取器'), findsOneWidget);
    expect(find.text('已创建候选记忆'), findsNothing);
    expect(find.text('已保存记忆'), findsNothing);
    expect(find.text('已批准变更'), findsNothing);
    expect(find.text('已删除记忆'), findsOneWidget);
    expect(find.text('内容：旧的临时记忆。'), findsOneWidget);
    expect(find.text('方式：Change request 审批'), findsOneWidget);

    await tester.drag(find.byType(ListView).last, const Offset(0, -360));
    await tester.pumpAndSettle();

    expect(find.text('已合并记忆'), findsOneWidget);
    expect(find.text('内容：用户偏好中文回复。'), findsOneWidget);
    expect(find.text('memory.search · system'), findsNothing);
    expect(find.text('memory mem_1'), findsNothing);
    expect(find.textContaining('queryHash'), findsNothing);
  });
}
