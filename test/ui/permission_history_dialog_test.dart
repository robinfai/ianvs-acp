import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/acp_permission_request.dart';
import 'package:ianvs_acp/ui/components/permission_history_dialog.dart';

void main() {
  testWidgets('PermissionHistoryDialog exports audit entries as JSON', (
    tester,
  ) async {
    String? exportedFileName;
    String? exportedJson;
    final entry = AcpPermissionAuditEntry(
      request: AcpPermissionRequest(
        id: 'permission-1',
        title: 'Read file',
        rationale: 'Requested by agent',
        sessionId: 'session-1',
        toolName: 'read_text_file',
        toolKind: 'read',
        options: const ['Allow', 'Deny'],
        requestedAt: DateTime.utc(2026, 5, 31, 12),
      ),
      status: AcpPermissionAuditStatus.allowed,
      recordedAt: DateTime.utc(2026, 5, 31, 12),
      resolvedAt: DateTime.utc(2026, 5, 31, 12, 1),
      decisionSource: AcpPermissionDecisionSource.trustRule,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PermissionHistoryDialog(
            entries: [entry],
            exporter: (fileName, json) async {
              exportedFileName = fileName;
              exportedJson = json;
              return '/tmp/history.json';
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('Export JSON'));
    await tester.pumpAndSettle();

    expect(exportedFileName, startsWith('ianvs-acp-permission-history-'));
    final exported = jsonDecode(exportedJson!) as Map<String, Object?>;
    expect(exported['schema'], 'ianvs-acp.permission-history.v1');
    final entries = exported['entries'] as List<Object?>;
    final first = entries.single as Map<String, Object?>;
    expect(first['status'], 'allowed');
    expect(first['decisionSource'], 'trustRule');
    expect(first['recordedAt'], '2026-05-31T12:00:00.000Z');
    expect(first['resolvedAt'], '2026-05-31T12:01:00.000Z');
    final request = first['request'] as Map<String, Object?>;
    expect(request['id'], 'permission-1');
    expect(request['toolName'], 'read_text_file');
    expect(find.text('Trust rule'), findsOneWidget);
    expect(find.text('Permission history exported.'), findsOneWidget);
  });

  testWidgets('PermissionHistoryDialog disables export when empty', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: PermissionHistoryDialog(entries: [])),
      ),
    );

    final exportButton = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Export JSON'),
    );
    expect(exportButton.onPressed, isNull);
    expect(find.text('No permission requests yet.'), findsOneWidget);
    expect(
      find.text('Requests that need your approval will be recorded here.'),
      findsOneWidget,
    );
  });
}
