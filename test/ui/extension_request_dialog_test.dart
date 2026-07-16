import 'dart:async';
import 'dart:collection';

import 'package:dart_acp/dart_acp.dart';
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
    expect(find.text('Extension request failed.'), findsOneWidget);
  });

  testWidgets('ExtensionRequestDialog bounds the displayed result', (
    tester,
  ) async {
    final fake = FakeAgentClient(
      extensionResponse: const <String, Object?>{
        'visible': 'é',
        'secret': 'EXTENSION-RESULT-CANARY',
      },
    );
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);
    await controller.connect();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ExtensionRequestDialog(
            controller: controller,
            inputBudget: const AcpInputBudget(
              maxMetadataPreviewChars: 16,
              maxMetadataPreviewBytes: 16,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Send'));
    await tester.pumpAndSettle();

    expect(fake.lastExtensionMethod, '_');
    expect(find.text('Result'), findsOneWidget);
    expect(find.textContaining('EXTENSION-RESULT-CANARY'), findsNothing);
    expect(find.textContaining('Preview truncated'), findsOneWidget);
  });

  testWidgets(
    'ExtensionRequestDialog reports cyclic result without leaking values',
    (tester) async {
      final response = <String, Object?>{'visible': 'safe'};
      response['secret'] = response;
      final fake = FakeAgentClient(extensionResponse: response);
      final controller = ChatController(client: fake, cwd: '/workspace');
      addTearDown(controller.dispose);
      await controller.connect();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ExtensionRequestDialog(controller: controller)),
        ),
      );

      await tester.tap(find.widgetWithText(FilledButton, 'Send'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Result'), findsOneWidget);
      expect(find.textContaining('safe'), findsNothing);
      expect(find.textContaining('Details omitted'), findsOneWidget);
    },
  );

  testWidgets(
    'ExtensionRequestDialog caches only displayed results and refreshes inputs',
    (tester) async {
      final firstResult = _countingResult('FIRST-VISIBLE', 'FIRST-CANARY');
      final secondResult = _countingResult('SECOND-VISIBLE', 'SECOND-CANARY');
      final firstResponse = Completer<Map<String, Object?>>();
      final secondResponse = Completer<Map<String, Object?>>();
      final fake = _QueuedExtensionAgentClient(<Future<Map<String, Object?>>>[
        firstResponse.future,
        secondResponse.future,
      ]);
      final controller = ChatController(client: fake, cwd: '/workspace');
      addTearDown(controller.dispose);
      await controller.connect();
      final budget = AcpInputBudget(
        maxMetadataPreviewChars: 32,
        maxMetadataPreviewBytes: 32,
      );

      await tester.pumpWidget(
        _extensionApp(controller: controller, inputBudget: budget),
      );

      expect(firstResult.valueReads, 0);
      expect(secondResult.valueReads, 0);

      await tester.tap(find.widgetWithText(FilledButton, 'Send'));
      await tester.pump();

      expect(firstResult.valueReads, 0);
      expect(find.text('Result'), findsNothing);

      firstResponse.complete(firstResult);
      await tester.pumpAndSettle();

      expect(firstResult.valueReads, 1);
      expect(find.textContaining('FIRST-VISIBLE'), findsOneWidget);
      expect(find.textContaining('FIRST-CANARY'), findsNothing);

      await tester.pumpWidget(
        _extensionApp(controller: controller, inputBudget: budget),
      );
      await tester.pump();

      expect(firstResult.valueReads, 1);

      await tester.tap(find.widgetWithText(FilledButton, 'Send'));
      await tester.pump();

      expect(firstResult.valueReads, 1);
      expect(secondResult.valueReads, 0);
      expect(find.text('Result'), findsNothing);

      secondResponse.complete(secondResult);
      await tester.pumpAndSettle();

      expect(firstResult.valueReads, 1);
      expect(secondResult.valueReads, 1);
      expect(find.textContaining('FIRST-VISIBLE'), findsNothing);
      expect(find.textContaining('SECOND-VISIBLE'), findsOneWidget);
      expect(find.textContaining('SECOND-CANARY'), findsNothing);

      final replacementBudget = AcpInputBudget(
        maxMetadataPreviewChars: 40,
        maxMetadataPreviewBytes: 40,
      );
      await tester.pumpWidget(
        _extensionApp(controller: controller, inputBudget: replacementBudget),
      );
      await tester.pump();

      expect(firstResult.valueReads, 1);
      expect(secondResult.valueReads, 2);
    },
  );

  testWidgets(
    'ExtensionRequestDialog displays the controller bounded extension error',
    (tester) async {
      const canary = 'EXTENSION-ERROR-CANARY';
      final error = _CountingError('safe-prefix-$canary');
      final fake = FakeAgentClient(extensionError: error);
      const budget = AcpInputBudget(
        maxMessageTextBytes: 8,
        maxMessageTextLines: 1,
        maxMarkdownFallbackBytes: 8,
      );
      final controller = ChatController(
        client: fake,
        cwd: '/workspace',
        inputBudget: budget,
      );
      addTearDown(controller.dispose);
      await controller.connect();

      await tester.pumpWidget(
        _extensionApp(controller: controller, inputBudget: budget),
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Send'));
      await tester.pumpAndSettle();

      expect(error.toStringCalls, 1);
      expect(controller.lastError, isNotNull);
      expect(find.text(controller.lastError!), findsOneWidget);
      expect(find.textContaining(canary), findsNothing);
      expect(find.text('Error'), findsOneWidget);
    },
  );

  testWidgets(
    'ExtensionRequestDialog does not stringify an error again after catch',
    (tester) async {
      final error = _SelfThrowingToString();
      final fake = FakeAgentClient(extensionError: error);
      final controller = ChatController(client: fake, cwd: '/workspace');
      addTearDown(controller.dispose);
      await controller.connect();

      await tester.pumpWidget(
        _extensionApp(
          controller: controller,
          inputBudget: const AcpInputBudget(),
        ),
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Send'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(error.toStringCalls, 1);
      expect(controller.lastError, 'An unexpected error occurred.');
      expect(find.text('An unexpected error occurred.'), findsOneWidget);
      expect(find.text('Extension request failed.'), findsNothing);
      expect(find.text('Error'), findsOneWidget);
    },
  );

  testWidgets(
    'ExtensionRequestDialog ignores stale controller errors for local failures',
    (tester) async {
      final staleError = _CountingError('STALE-CONTROLLER-ERROR');
      final fake = FakeAgentClient(extensionError: staleError);
      final controller = ChatController(client: fake, cwd: '/workspace');
      addTearDown(controller.dispose);
      await controller.connect();

      await tester.pumpWidget(
        _extensionApp(
          controller: controller,
          inputBudget: const AcpInputBudget(),
        ),
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Send'));
      await tester.pumpAndSettle();

      final previousError = controller.lastError;
      expect(previousError, 'STALE-CONTROLLER-ERROR');
      expect(staleError.toStringCalls, 1);
      expect(find.text(previousError!), findsOneWidget);

      final fields = find.byType(TextField);
      await tester.enterText(fields.at(1), '[]');
      await tester.tap(find.widgetWithText(FilledButton, 'Send'));
      await tester.pumpAndSettle();

      expect(controller.lastError, previousError);
      expect(staleError.toStringCalls, 1);
      expect(find.text(previousError), findsNothing);
      expect(find.text('Extension request failed.'), findsOneWidget);
    },
  );

  testWidgets(
    'ExtensionRequestDialog shows this request bounded method error',
    (tester) async {
      final fake = FakeAgentClient();
      const budget = AcpInputBudget(
        maxMessageTextBytes: 8,
        maxMarkdownFallbackBytes: 8,
      );
      final controller = ChatController(
        client: fake,
        cwd: '/workspace',
        inputBudget: budget,
      );
      addTearDown(controller.dispose);
      await controller.connect();
      controller.lastError = 'STALE-METHOD-ERROR';

      await tester.pumpWidget(
        _extensionApp(controller: controller, inputBudget: budget),
      );
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'invalid-method');
      await tester.tap(find.widgetWithText(FilledButton, 'Send'));
      await tester.pumpAndSettle();

      expect(fake.lastExtensionMethod, isNull);
      expect(controller.lastError, isNotNull);
      expect(controller.lastError, isNot('STALE-METHOD-ERROR'));
      expect(controller.lastError, hasLength(8));
      expect(find.text(controller.lastError!), findsOneWidget);
      expect(find.text('Extension request failed.'), findsNothing);
    },
  );

  testWidgets(
    'ExtensionRequestDialog displays repeated identical controller errors',
    (tester) async {
      final error = _CountingError('REPEATED-EXTENSION-ERROR');
      final controller = ChatController(
        client: FakeAgentClient(extensionError: error),
        cwd: '/workspace',
      );
      addTearDown(controller.dispose);
      await controller.connect();

      await tester.pumpWidget(
        _extensionApp(
          controller: controller,
          inputBudget: const AcpInputBudget(),
        ),
      );
      final send = find.widgetWithText(FilledButton, 'Send');
      await tester.tap(send);
      await tester.pumpAndSettle();

      expect(error.toStringCalls, 1);
      expect(find.text('REPEATED-EXTENSION-ERROR'), findsOneWidget);

      await tester.tap(send);
      await tester.pumpAndSettle();

      expect(error.toStringCalls, 2);
      expect(find.text('REPEATED-EXTENSION-ERROR'), findsOneWidget);
      expect(find.text('Extension request failed.'), findsNothing);
    },
  );
}

Widget _extensionApp({
  required ChatController controller,
  required AcpInputBudget inputBudget,
}) {
  return MaterialApp(
    home: Scaffold(
      body: ExtensionRequestDialog(
        controller: controller,
        inputBudget: inputBudget,
      ),
    ),
  );
}

_CountingResult _countingResult(String visible, String canary) {
  return _CountingResult(<String, Object?>{
    'payload': '$visible-${'x' * 128}',
    'secret': canary,
  });
}

final class _QueuedExtensionAgentClient extends FakeAgentClient {
  _QueuedExtensionAgentClient(this.responses);

  final List<Future<Map<String, Object?>>> responses;
  var responseIndex = 0;

  @override
  Future<Map<String, Object?>> sendExtensionRequest({
    required String method,
    required Map<String, Object?> params,
  }) {
    lastExtensionMethod = method;
    lastExtensionParams = params;
    return responses[responseIndex++];
  }
}

final class _CountingResult extends MapBase<String, Object?> {
  _CountingResult(Map<String, Object?> values) : _values = values;

  final Map<String, Object?> _values;
  var valueReads = 0;

  @override
  Object? operator [](Object? key) {
    valueReads += 1;
    return _values[key];
  }

  @override
  void operator []=(String key, Object? value) => _values[key] = value;

  @override
  void clear() => _values.clear();

  @override
  Iterable<String> get keys => _values.keys;

  @override
  Object? remove(Object? key) => _values.remove(key);
}

final class _CountingError {
  _CountingError(this.message);

  final String message;
  var toStringCalls = 0;

  @override
  String toString() {
    toStringCalls += 1;
    return message;
  }
}

final class _SelfThrowingToString {
  var toStringCalls = 0;

  @override
  String toString() {
    toStringCalls += 1;
    throw this;
  }
}
