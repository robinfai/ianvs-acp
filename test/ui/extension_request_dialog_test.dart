import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/fake_agent_client.dart';
import 'package:ianvs_acp/state/chat_controller.dart';
import 'package:ianvs_acp/ui/components/extension_request_dialog.dart';

void main() {
  testWidgets('ExtensionRequestDialog sends custom JSON-RPC request', (
    tester,
  ) async {
    final fake = FakeAgentClient(
      extensionResponse: const {
        'buffers': [
          {'path': '/workspace/lib/main.dart'},
        ],
      },
    );
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);
    await controller.connect();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ExtensionRequestDialog(controller: controller)),
      ),
    );

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), '_zed.dev/workspace/buffers');
    await tester.enterText(fields.at(1), '{"language":"dart"}');
    await tester.tap(find.widgetWithText(FilledButton, 'Send'));
    await tester.pumpAndSettle();

    expect(fake.lastExtensionMethod, '_zed.dev/workspace/buffers');
    expect(fake.lastExtensionParams, {'language': 'dart'});
    expect(find.text('Result'), findsOneWidget);
    expect(find.textContaining('/workspace/lib/main.dart'), findsOneWidget);
  });

  testWidgets('ExtensionRequestDialog rejects non-object params JSON', (
    tester,
  ) async {
    final fake = FakeAgentClient();
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);
    await controller.connect();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ExtensionRequestDialog(controller: controller)),
      ),
    );

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), '_example.dev/ping');
    await tester.enterText(fields.at(1), '[]');
    await tester.tap(find.widgetWithText(FilledButton, 'Send'));
    await tester.pumpAndSettle();

    expect(fake.lastExtensionMethod, isNull);
    expect(find.text('Error'), findsOneWidget);
    expect(
      find.textContaining('Params JSON must be an object'),
      findsOneWidget,
    );
  });
}
