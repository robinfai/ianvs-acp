import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/acp_permission_request.dart';
import 'package:ianvs_acp/acp/fake_agent_client.dart';
import 'package:ianvs_acp/config/acp_client_config.dart';
import 'package:ianvs_acp/state/chat_controller.dart';
import 'package:ianvs_acp/ui/components/activity_diagnostics_dialog.dart';

void main() {
  Future<ChatController> controller(FakeAgentClient client) async {
    final value = ChatController(client: client, cwd: '/workspace/app');
    addTearDown(value.dispose);
    expect(await value.newSession(), isTrue);
    return value;
  }

  void request(FakeAgentClient client, ChatController value, String id) {
    client.emitPermissionRequest(
      AcpPermissionRequest(
        id: id,
        requestedAt: DateTime.utc(2026, 9, 9),
        title: 'Read $id',
        rationale: 'Inspect a project file',
        sessionId: value.currentSession!.id,
        toolName: 'read_text_file',
        options: const ['Allow', 'Deny'],
      ),
    );
  }

  testWidgets(
    'events follow session changes while export preserves retained audit scope',
    (tester) async {
      final client = FakeAgentClient();
      final value = await controller(client);
      value.addMessageForTesting(
        ChatMessage(role: ChatMessageRole.user, text: 'First session content'),
        startsNewTurn: true,
      );
      request(client, value, 'first');
      await tester.pump();
      await value.resolvePermissionRequest(AcpPermissionDecision.deny);
      String? exported;
      await tester.pumpWidget(
        MaterialApp(
          home: ActivityDiagnosticsDialog(
            controller: value,
            runtimeConfig: const AcpClientConfig(),
            permissionExporter: (_, json) async {
              exported = json;
              return '/tmp/audit.json';
            },
          ),
        ),
      );
      expect(find.text('First session content'), findsOneWidget);

      expect(await value.newSession(), isTrue);
      value.addMessageForTesting(
        ChatMessage(role: ChatMessageRole.user, text: 'Second session content'),
        startsNewTurn: true,
      );
      request(client, value, 'second');
      await tester.pump();
      await value.resolvePermissionRequest(AcpPermissionDecision.deny);
      await tester.pumpAndSettle();
      expect(find.text('First session content'), findsNothing);
      expect(find.text('Second session content'), findsOneWidget);
      await tester.tap(find.text('Permissions'));
      await tester.pumpAndSettle();
      expect(find.textContaining('including other sessions'), findsOneWidget);
      await tester.tap(find.text('Export JSON'));
      await tester.pumpAndSettle();
      final entries = (jsonDecode(exported!) as Map)['entries'] as List;
      expect(
        entries.map((entry) => entry['request']['id']),
        containsAll(['first', 'second']),
      );
      expect(find.text('Permission history exported.'), findsOneWidget);
      await value.closeCurrentSession();
      await tester.pumpAndSettle();
      expect(find.text('Read second'), findsNothing);
      expect(find.text('Read first'), findsOneWidget);
      await tester.tap(find.text('Events'));
      await tester.pumpAndSettle();
      expect(find.text('Second session content'), findsNothing);
      expect(find.textContaining('No active session'), findsOneWidget);
    },
  );

  testWidgets('all tabs fit a compact window and Escape restores focus', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 560);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final value = await controller(FakeAgentClient());
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              focusNode: focus,
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => ActivityDiagnosticsDialog(
                  controller: value,
                  runtimeConfig: const AcpClientConfig(),
                ),
              ),
              child: const Text('Open diagnostics'),
            ),
          ),
        ),
      ),
    );
    focus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('Activity & Diagnostics'), findsOneWidget);
    for (final tab in ['Permissions', 'Runtime', 'Events']) {
      await tester.tap(find.text(tab));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: tab);
      if (tab == 'Runtime') {
        await tester.ensureVisible(find.text('Capability details'));
        await tester.tap(find.text('Capability details'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'Expanded capabilities');
      }
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Activity & Diagnostics'), findsNothing);
    expect(focus.hasFocus, isTrue);
  });

  testWidgets(
    'replacing controller drops old activity and late export status',
    (tester) async {
      final firstClient = FakeAgentClient();
      final first = await controller(firstClient);
      request(firstClient, first, 'old');
      await tester.pump();
      await first.resolvePermissionRequest(AcpPermissionDecision.deny);
      final second = await controller(FakeAgentClient());
      final pendingExport = Completer<String?>();
      Widget app(ChatController value) => MaterialApp(
        home: ActivityDiagnosticsDialog(
          controller: value,
          runtimeConfig: const AcpClientConfig(),
          initialTab: DiagnosticsTab.permissions,
          permissionExporter: (_, _) => pendingExport.future,
        ),
      );
      await tester.pumpWidget(app(first));
      await tester.tap(find.text('Export JSON'));
      await tester.pump();
      await tester.pumpWidget(app(second));
      pendingExport.complete('/tmp/old.json');
      await tester.pumpAndSettle();
      expect(find.text('Read old'), findsNothing);
      expect(find.text('No permission requests yet.'), findsOneWidget);
      expect(find.text('Permission history exported.'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
