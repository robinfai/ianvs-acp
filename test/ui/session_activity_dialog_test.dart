import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/agent_session.dart';
import 'package:ianvs_acp/acp/acp_input_budget.dart';
import 'package:ianvs_acp/acp/acp_permission_request.dart';
import 'package:ianvs_acp/acp/fake_agent_client.dart';
import 'package:ianvs_acp/config/acp_client_config.dart';
import 'package:ianvs_acp/state/chat_controller.dart';
import 'package:ianvs_acp/ui/activity/session_activity_model.dart';
import 'package:ianvs_acp/ui/components/session_activity_dialog.dart';

void main() {
  testWidgets(
    'activity snapshot and dialog expose a chronological trajectory',
    (tester) async {
      final client = FakeAgentClient();
      final controller = ChatController(client: client, cwd: '/workspace/app');
      addTearDown(controller.dispose);
      const template = SessionTemplateConfig(
        id: 'review',
        name: 'Review',
        version: 2,
      );
      expect(await controller.newSession(template: template), isTrue);

      controller.addMessageForTesting(
        ChatMessage(
          role: ChatMessageRole.user,
          text: 'Review the workspace',
          timestamp: DateTime.utc(2026, 8, 19, 12),
        ),
        startsNewTurn: true,
      );
      controller.addMessageForTesting(
        ChatMessage(
          role: ChatMessageRole.tool,
          text: '[Tool: exec_command] ToolCallStatus.completed',
          timestamp: DateTime.utc(2026, 8, 19, 12, 1),
          metadata: const <String, Object?>{
            'toolCallId': 'call-1',
            'rawInput': <String, Object?>{'cmd': 'dart test'},
          },
        ),
      );
      controller.addMessageForTesting(
        ChatMessage(
          role: ChatMessageRole.assistant,
          text: 'The checks passed.',
          timestamp: DateTime.utc(2026, 8, 19, 12, 2),
        ),
      );
      client.emitPermissionRequest(
        AcpPermissionRequest(
          id: 'permission-1',
          title: 'Write report',
          rationale: 'Save the review output',
          sessionId: controller.currentSession!.id,
          toolName: 'write_text_file',
          options: const <String>['Allow', 'Deny'],
          requestedAt: DateTime.utc(2026, 8, 19, 12, 3),
        ),
      );
      client.emitPermissionRequest(
        AcpPermissionRequest(
          id: 'permission-unscoped',
          title: 'Unscoped invalid request',
          rationale: 'Must not enter a session trajectory',
          sessionId: '',
          toolName: 'write_text_file',
          options: const <String>['Allow', 'Deny'],
          requestedAt: DateTime.utc(2026, 8, 19, 12, 4),
        ),
      );
      await tester.pump();
      controller.lastLatency = const Duration(milliseconds: 1250);

      final snapshot = SessionActivitySnapshot.fromController(controller);
      expect(snapshot.sessionTemplateIdentity, 'review@2');
      expect(snapshot.toolCount, 1);
      expect(snapshot.permissionCount, 1);
      expect(snapshot.entries.map((entry) => entry.title), <String>[
        'Prompt',
        'Ran command',
        'Assistant response',
        'Permission pending',
      ]);

      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: SessionActivityDialog(controller: controller)),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Session Activity'), findsOneWidget);
      expect(find.text('4 events'), findsOneWidget);
      expect(find.text('1 tools'), findsOneWidget);
      expect(find.text('1 permissions'), findsOneWidget);
      expect(find.text('Last 1.3s'), findsOneWidget);
      expect(find.text('review@2'), findsOneWidget);
      expect(find.text('Ran command'), findsOneWidget);
      expect(
        find.bySemanticsLabel(RegExp(r'Ran command completed')),
        findsOneWidget,
      );
      expect(find.text('Permission pending'), findsOneWidget);
      expect(find.textContaining('Unscoped invalid request'), findsNothing);
    },
  );

  testWidgets('activity tool summaries never expose command credentials', (
    tester,
  ) async {
    const secretCommand =
        "curl https://alice:password@agent.example/private?token=secret-canary "
        "-H 'Authorization: Bearer bearer-canary'";
    final controller = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace/app',
    );
    addTearDown(controller.dispose);
    expect(await controller.newSession(), isTrue);
    controller.addMessageForTesting(
      ChatMessage(
        role: ChatMessageRole.tool,
        text:
            '[Tool: exec_command curl '
            'https://alice:password@agent.example/private?token=secret-canary] '
            'ToolCallStatus.completed',
        metadata: const <String, Object?>{
          'toolCallId': 'secret-tool-call',
          'title': 'exec_command Authorization: Bearer metadata-bearer-canary',
          'status': 'Authorization: Bearer status-secret-canary',
          'rawInput': <String, Object?>{'cmd': secretCommand},
        },
      ),
    );

    final snapshot = SessionActivitySnapshot.fromController(controller);
    expect(snapshot.entries.single.title, 'Ran command');
    expect(snapshot.entries.single.status, isNull);
    expect(snapshot.entries.single.detail, isNot(contains('password')));
    expect(snapshot.entries.single.detail, isNot(contains('secret-canary')));
    expect(snapshot.entries.single.detail, isNot(contains('bearer-canary')));
    expect(
      snapshot.entries.single.detail,
      isNot(contains('metadata-bearer-canary')),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SessionActivityDialog(controller: controller)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('password'), findsNothing);
    expect(find.textContaining('secret-canary'), findsNothing);
    expect(find.textContaining('bearer-canary'), findsNothing);
    expect(find.textContaining('metadata-bearer-canary'), findsNothing);
    expect(find.textContaining('status-secret-canary'), findsNothing);
  });

  testWidgets('activity hides raw terminal and error credential text', (
    tester,
  ) async {
    final controller = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace/app',
    );
    addTearDown(controller.dispose);
    expect(await controller.newSession(), isTrue);
    controller.addMessageForTesting(
      ChatMessage(
        role: ChatMessageRole.status,
        text:
            'curl https://alice:password@agent.example/private?token=status-canary',
        metadata: const <String, Object?>{'kind': 'terminal'},
      ),
    );
    controller.addMessageForTesting(
      ChatMessage(
        role: ChatMessageRole.error,
        text: 'Authorization: Bearer error-bearer-canary',
      ),
    );

    final snapshot = SessionActivitySnapshot.fromController(controller);
    expect(snapshot.entries, hasLength(2));
    expect(snapshot.entries.every((entry) => entry.detail.isEmpty), isTrue);
    expect(
      snapshot.entries.map((entry) => entry.detail).join(),
      isNot(contains('status-canary')),
    );
    expect(
      snapshot.entries.map((entry) => entry.detail).join(),
      isNot(contains('error-bearer-canary')),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SessionActivityDialog(controller: controller)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('password'), findsNothing);
    expect(find.textContaining('status-canary'), findsNothing);
    expect(find.textContaining('error-bearer-canary'), findsNothing);
  });

  testWidgets('activity redacts attachment envelopes and updates live', (
    tester,
  ) async {
    final controller = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace/app',
    );
    addTearDown(controller.dispose);
    await controller.newSession();
    controller.addMessageForTesting(
      ChatMessage(
        role: ChatMessageRole.user,
        text: '''# Files mentioned by the user:

## reference.png: /private/tmp/private-reference.png

## My request for Codex:
Review the screenshot''',
      ),
      startsNewTurn: true,
    );
    controller.addMessageForTesting(
      ChatMessage(
        role: ChatMessageRole.user,
        text: '[@image](file:///private/tmp/private-reference.png)',
      ),
    );

    final snapshot = SessionActivitySnapshot.fromController(controller);
    expect(snapshot.entries, hasLength(1));
    expect(snapshot.entries.single.detail, 'Review the screenshot');
    expect(
      snapshot.entries.map((entry) => entry.detail).join(),
      isNot(contains('/private/tmp')),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SessionActivityDialog(controller: controller)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('1 events'), findsOneWidget);
    expect(find.textContaining('/private/tmp'), findsNothing);

    controller.addMessageForTesting(
      ChatMessage(
        role: ChatMessageRole.assistant,
        text: 'The screenshot is clear.',
      ),
    );
    controller.setToolCallExecutionPolicy(
      AcpToolCallExecutionPolicy.fullAccess,
    );
    await tester.pump();

    expect(find.text('2 events'), findsOneWidget);
    expect(find.text('The screenshot is clear.'), findsOneWidget);
  });

  test(
    'activity cache reuses stable projections and reports truncation',
    () async {
      final controller = ChatController(
        client: FakeAgentClient(),
        cwd: '/workspace/app',
      );
      addTearDown(controller.dispose);
      await controller.newSession();
      for (var index = 0; index < 3; index += 1) {
        controller.addMessageForTesting(
          ChatMessage(
            role: ChatMessageRole.status,
            text: 'Status $index',
            timestamp: DateTime.utc(2026, 8, 19, 12, index),
          ),
        );
      }
      final cache = SessionActivityProjectionCache();
      final first = SessionActivitySnapshot.fromController(
        controller,
        projectionCache: cache,
        maxEntries: 2,
      );
      final second = SessionActivitySnapshot.fromController(
        controller,
        projectionCache: cache,
        maxEntries: 2,
      );

      expect(first.truncated, isTrue);
      expect(first.entries, hasLength(2));
      expect(identical(first.entries.first, second.entries.first), isTrue);
    },
  );

  testWidgets('activity dialog labels a limited trajectory as latest', (
    tester,
  ) async {
    final controller = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace/app',
    );
    addTearDown(controller.dispose);
    await controller.newSession();
    for (var index = 0; index < 3; index += 1) {
      controller.addMessageForTesting(
        ChatMessage(role: ChatMessageRole.status, text: 'Status $index'),
      );
    }

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SessionActivityDialog(controller: controller, maxEntries: 2),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Latest 2 events'), findsOneWidget);
  });

  test('attachment-only messages do not displace visible activity', () async {
    final controller = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace/app',
    );
    addTearDown(controller.dispose);
    await controller.newSession();
    controller.addMessageForTesting(
      ChatMessage(role: ChatMessageRole.user, text: 'Keep this prompt'),
      startsNewTurn: true,
    );
    for (var index = 0; index < 3; index += 1) {
      controller.addMessageForTesting(
        ChatMessage(
          role: ChatMessageRole.user,
          text: '[@image](file:///private/tmp/private-$index.png)',
        ),
      );
    }

    final snapshot = SessionActivitySnapshot.fromController(
      controller,
      maxEntries: 1,
    );

    expect(snapshot.entries, hasLength(1));
    expect(snapshot.entries.single.detail, 'Keep this prompt');
    expect(snapshot.truncated, isFalse);
  });

  test(
    'activity reports controller-level timeline and permission eviction',
    () async {
      final client = FakeAgentClient();
      final controller = ChatController(
        client: client,
        cwd: '/workspace/app',
        permissionHistoryLimit: 1,
      );
      addTearDown(controller.dispose);
      await controller.newSession();
      controller.addMessageForTesting(
        ChatMessage(
          role: ChatMessageRole.status,
          text: '',
          omissions: <AcpInputOmission>[
            AcpInputOmission(
              reason: AcpInputOmissionReason.inputLimit,
              resource: 'timeline history',
              truncated: true,
              limit: 1,
              observedAtLeast: 2,
            ),
          ],
        ),
      );
      for (var index = 0; index < 2; index += 1) {
        client.emitPermissionRequest(
          AcpPermissionRequest(
            id: 'permission-$index',
            title: 'Permission $index',
            rationale: 'Test eviction',
            sessionId: controller.currentSession!.id,
            toolName: 'write_text_file',
            options: const <String>['Allow', 'Deny'],
            requestedAt: DateTime.utc(2026, 8, 19, 12, index),
          ),
        );
      }

      final snapshot = SessionActivitySnapshot.fromController(controller);

      expect(controller.timelineHistoryWasTruncated, isTrue);
      expect(controller.permissionHistoryWasTruncated, isTrue);
      expect(snapshot.truncated, isTrue);
    },
  );

  test('timeline truncation survives eviction of its visible marker', () async {
    final controller = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace/app',
      inputBudget: const AcpInputBudget(maxTimelineItems: 1),
    );
    addTearDown(controller.dispose);
    await controller.newSession();
    controller.addMessageForTesting(
      ChatMessage(role: ChatMessageRole.user, text: 'First turn'),
      startsNewTurn: true,
    );
    controller.addMessageForTesting(
      ChatMessage(role: ChatMessageRole.user, text: 'Second turn'),
      startsNewTurn: true,
    );

    expect(controller.visibleMessages, hasLength(1));
    expect(controller.timelineHistoryWasTruncated, isTrue);
    expect(
      SessionActivitySnapshot.fromController(controller).truncated,
      isTrue,
    );
    final truncatedSessionId = controller.currentSession!.id;

    await controller.newSession();
    expect(controller.timelineHistoryWasTruncated, isFalse);
    await controller.resumeSession(truncatedSessionId);
    expect(controller.timelineHistoryWasTruncated, isTrue);
  });

  test('permission truncation stays scoped to the affected session', () async {
    final client = FakeAgentClient();
    final controller = ChatController(
      client: client,
      cwd: '/workspace/app',
      permissionHistoryLimit: 1,
    );
    addTearDown(controller.dispose);
    await controller.newSession();
    final firstSessionId = controller.currentSession!.id;
    for (var index = 0; index < 2; index += 1) {
      client.emitPermissionRequest(
        AcpPermissionRequest(
          id: 'first-session-permission-$index',
          title: 'Permission $index',
          rationale: 'Test session-scoped eviction',
          sessionId: firstSessionId,
          toolName: 'write_text_file',
          options: const <String>['Allow', 'Deny'],
          requestedAt: DateTime.utc(2026, 8, 19, 13, index),
        ),
      );
    }
    expect(
      controller.permissionHistoryWasTruncatedForSession(firstSessionId),
      isTrue,
    );

    await controller.newSession();
    final secondSessionId = controller.currentSession!.id;
    final snapshot = SessionActivitySnapshot.fromController(controller);

    expect(secondSessionId, isNot(firstSessionId));
    expect(
      controller.permissionHistoryWasTruncatedForSession(secondSessionId),
      isFalse,
    );
    expect(snapshot.entries, isEmpty);
    expect(snapshot.truncated, isFalse);
  });

  test('late catalog sessions retain permission eviction provenance', () async {
    final client = FakeAgentClient();
    final controller = ChatController(
      client: client,
      cwd: '/workspace/app',
      permissionHistoryLimit: 1,
    );
    addTearDown(controller.dispose);
    await controller.newSession();
    for (var index = 0; index < 2; index += 1) {
      client.emitPermissionRequest(
        AcpPermissionRequest(
          id: 'late-permission-$index',
          title: 'Late permission $index',
          rationale: 'Arrived before the session catalog',
          sessionId: 'late-session',
          toolName: 'write_text_file',
          options: const <String>['Allow', 'Deny'],
          requestedAt: DateTime.utc(2026, 8, 19, 14, index),
        ),
      );
    }
    expect(controller.permissionHistory, hasLength(1));
    final currentSessionId = controller.currentSession!.id;
    client.emitPermissionRequest(
      AcpPermissionRequest(
        id: 'current-permission',
        title: 'Current permission',
        rationale: 'Evicts the final retained late-session audit',
        sessionId: currentSessionId,
        toolName: 'write_text_file',
        options: const <String>['Allow', 'Deny'],
        requestedAt: DateTime.utc(2026, 8, 19, 14, 3),
      ),
    );
    expect(
      controller.permissionHistory.single.request.sessionId,
      currentSessionId,
    );

    controller.mergeSessionIndex(<AgentSession>[
      AgentSession(
        id: 'late-session',
        cwd: '/workspace/app',
        createdAt: DateTime.utc(2026, 8, 19, 14),
      ),
    ]);
    await controller.resumeSession('late-session');
    final snapshot = SessionActivitySnapshot.fromController(controller);

    expect(
      controller.permissionHistoryWasTruncatedForSession('late-session'),
      isTrue,
    );
    expect(snapshot.permissionCount, 0);
    expect(snapshot.truncated, isTrue);
  });

  test('late catalog provenance survives the marker cap', () async {
    final client = FakeAgentClient();
    final controller = ChatController(
      client: client,
      cwd: '/workspace/app',
      permissionHistoryLimit: 1,
    );
    addTearDown(controller.dispose);
    await controller.newSession();
    for (final sessionId in <String>['late-a', 'late-b', 'late-c']) {
      client.emitPermissionRequest(
        AcpPermissionRequest(
          id: 'permission-$sessionId',
          title: 'Permission for $sessionId',
          rationale: 'Arrived before the session catalog',
          sessionId: sessionId,
          toolName: 'write_text_file',
          options: const <String>['Allow', 'Deny'],
          requestedAt: DateTime.utc(2026, 8, 19, 15),
        ),
      );
    }
    final activeSessionId = controller.currentSession!.id;
    expect(
      controller.permissionHistoryWasTruncatedForSession(activeSessionId),
      isFalse,
    );

    void emitSecondPermission(String sessionId) {
      client.emitPermissionRequest(
        AcpPermissionRequest(
          id: 'second-permission-$sessionId',
          title: 'Second permission for $sessionId',
          rationale: 'Exercises marker eviction after an exemption',
          sessionId: sessionId,
          toolName: 'write_text_file',
          options: const <String>['Allow', 'Deny'],
          requestedAt: DateTime.utc(2026, 8, 19, 15, 1),
        ),
      );
    }

    emitSecondPermission(activeSessionId);
    expect(
      controller.permissionHistoryWasTruncatedForSession(activeSessionId),
      isFalse,
    );
    emitSecondPermission('late-d');
    expect(
      controller.permissionHistoryWasTruncatedForSession(activeSessionId),
      isTrue,
    );
    emitSecondPermission('late-e');
    expect(
      controller.permissionHistoryWasTruncatedForSession(activeSessionId),
      isTrue,
    );

    controller.mergeSessionIndex(<AgentSession>[
      AgentSession(
        id: 'late-a',
        cwd: '/workspace/app',
        createdAt: DateTime.utc(2026, 8, 19, 15),
      ),
    ]);
    await controller.resumeSession('late-a');

    expect(
      controller.permissionHistoryWasTruncatedForSession('late-a'),
      isTrue,
    );
    expect(
      SessionActivitySnapshot.fromController(controller).truncated,
      isTrue,
    );
  });

  test('a new fork stays complete after provenance overflow', () async {
    final client = FakeAgentClient();
    final controller = ChatController(
      client: client,
      cwd: '/workspace/app',
      permissionHistoryLimit: 1,
    );
    addTearDown(controller.dispose);
    await controller.newSession();
    for (final sessionId in <String>['late-a', 'late-b', 'late-c']) {
      client.emitPermissionRequest(
        AcpPermissionRequest(
          id: 'overflow-$sessionId',
          title: 'Overflow $sessionId',
          rationale: 'Create provenance overflow before the fork',
          sessionId: sessionId,
          toolName: 'write_text_file',
          options: const <String>['Allow', 'Deny'],
          requestedAt: DateTime.utc(2026, 8, 19, 15, 2),
        ),
      );
    }

    await controller.forkCurrentSession();
    final forkId = controller.currentSession!.id;
    expect(controller.permissionHistoryWasTruncatedForSession(forkId), isFalse);

    for (final sessionId in <String>[forkId, 'late-d']) {
      client.emitPermissionRequest(
        AcpPermissionRequest(
          id: 'fork-$sessionId',
          title: 'Fork permission $sessionId',
          rationale: 'Truncate the new fork permission history',
          sessionId: sessionId,
          toolName: 'write_text_file',
          options: const <String>['Allow', 'Deny'],
          requestedAt: DateTime.utc(2026, 8, 19, 15, 3),
        ),
      );
    }
    expect(controller.permissionHistoryWasTruncatedForSession(forkId), isTrue);
  });

  test(
    'terminal session close clears its permission activity identity',
    () async {
      final client = FakeAgentClient();
      final controller = ChatController(
        client: client,
        cwd: '/workspace/app',
        permissionHistoryLimit: 1,
      );
      addTearDown(controller.dispose);
      await controller.newSession();
      final sessionId = controller.currentSession!.id;
      for (var index = 0; index < 2; index += 1) {
        client.emitPermissionRequest(
          AcpPermissionRequest(
            id: 'closing-permission-$index',
            title: 'Closing permission $index',
            rationale: 'Test terminal lifecycle cleanup',
            sessionId: sessionId,
            toolName: 'write_text_file',
            options: const <String>['Allow', 'Deny'],
            requestedAt: DateTime.utc(2026, 8, 19, 15, index),
          ),
        );
      }
      expect(
        controller.permissionHistoryWasTruncatedForSession(sessionId),
        isTrue,
      );

      await controller.closeCurrentSession();
      client.emitPermissionRequest(
        AcpPermissionRequest(
          id: 'late-retired-permission',
          title: 'Late retired permission',
          rationale: 'Arrived after terminal cleanup',
          sessionId: sessionId,
          toolName: 'write_text_file',
          options: const <String>['Allow', 'Deny'],
          requestedAt: DateTime.utc(2026, 8, 19, 15, 30),
        ),
      );
      controller.currentSession = AgentSession(
        id: sessionId,
        cwd: '/workspace/app',
        createdAt: DateTime.utc(2026, 8, 19, 16),
      );

      expect(controller.permissionHistory, isEmpty);
      expect(
        controller.permissionHistoryWasTruncatedForSession(sessionId),
        isFalse,
      );
      expect(
        SessionActivitySnapshot.fromController(controller).truncated,
        isFalse,
      );
    },
  );

  test(
    'retired session overflow cancels unknown late requests conservatively',
    () async {
      final client = FakeAgentClient();
      final controller = ChatController(
        client: client,
        cwd: '/workspace/app',
        permissionHistoryLimit: 1,
      );
      addTearDown(controller.dispose);

      for (var index = 0; index < 2; index += 1) {
        expect(await controller.newSession(), isTrue);
        await controller.closeCurrentSession();
      }
      client.emitPermissionRequest(
        AcpPermissionRequest(
          id: 'late-after-retirement-overflow',
          title: 'Late permission',
          rationale: 'Arrived after retired session provenance overflowed',
          sessionId: 'unknown-old-session',
          toolName: 'write_text_file',
          options: const <String>['Allow', 'Deny'],
          requestedAt: DateTime.utc(2026, 8, 19, 17),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(controller.pendingPermissionRequest, isNull);
      expect(controller.permissionHistory, isEmpty);
      expect(client.lastPermissionRequestId, 'late-after-retirement-overflow');
      expect(client.lastPermissionDecision, AcpPermissionDecision.cancel);
    },
  );
}
