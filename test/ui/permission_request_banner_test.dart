import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/acp_permission_request.dart';
import 'package:ianvs_acp/ui/components/permission_request_banner.dart';

void main() {
  Widget banner({
    required AcpPermissionRequest request,
    VoidCallback? onAllow,
    VoidCallback? onDeny,
    VoidCallback? onCancel,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: PermissionRequestBanner(
          request: request,
          onAllow: onAllow ?? () {},
          onDeny: onDeny ?? () {},
          onCancel: onCancel ?? () {},
        ),
      ),
    );
  }

  AcpPermissionRequest request({
    List<String> options = const ['Allow', 'Deny'],
  }) {
    return AcpPermissionRequest(
      id: 'permission-1',
      title: 'Review plan',
      rationale: 'Requested by agent',
      sessionId: 'session-1',
      toolName: 'planning',
      toolKind: 'review',
      options: options,
      requestedAt: DateTime(2026, 5, 31, 12),
    );
  }

  testWidgets(
    'PermissionRequestBanner keeps default labels for generic options',
    (tester) async {
      await tester.pumpWidget(banner(request: request()));

      expect(find.text('Allow Once'), findsOneWidget);
      expect(find.text('Deny'), findsOneWidget);
    },
  );

  testWidgets('PermissionRequestBanner uses agent-provided action labels', (
    tester,
  ) async {
    var allowed = false;
    var denied = false;
    await tester.pumpWidget(
      banner(
        request: request(options: const ['Approve Plan', 'Reject Plan']),
        onAllow: () => allowed = true,
        onDeny: () => denied = true,
      ),
    );

    expect(find.text('Approve Plan'), findsOneWidget);
    expect(find.text('Reject Plan'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Approve Plan'));
    await tester.tap(find.widgetWithText(TextButton, 'Reject Plan'));

    expect(allowed, isTrue);
    expect(denied, isTrue);
  });
}
