import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_agent_chat/ui/components/accessible_text_field.dart';

void main() {
  testWidgets('macOS hosts without a native factory use Flutter semantics', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AccessibleTextField(
            label: 'Shared prompt',
            description: 'Type a message',
            controller: controller,
            onChanged: (_) {},
            builder: (focus) =>
                TextField(controller: controller, focusNode: focus),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(AppKitView), findsNothing);
    expect(find.bySemanticsLabel(RegExp('Shared prompt')), findsWidgets);
    expect(tester.takeException(), isNull);
    semantics.dispose();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
    'clears native handlers across semantics proxy lifecycles',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        final controller = TextEditingController();
        addTearDown(controller.dispose);
        var changed = <String>[];

        Widget subject() => MaterialApp(
          home: ChatNativeTextFieldScope(
            child: Scaffold(
              body: AccessibleTextField(
                label: 'Search workspaces',
                description: 'Filter the workspace list',
                controller: controller,
                onChanged: changed.add,
                builder: (focusNode) =>
                    TextField(controller: controller, focusNode: focusNode),
              ),
            ),
          ),
        );

        final semantics = tester.ensureSemantics();
        await tester.pumpWidget(subject());
        await tester.pump();

        final firstView = tester.widget<AppKitView>(find.byType(AppKitView));
        firstView.onPlatformViewCreated?.call(11);
        await _sendText(tester, 11, 'first');
        expect(controller.text, 'first');
        expect(changed, <String>['first']);

        semantics.dispose();
        await tester.pump();
        await _sendText(tester, 11, 'stale');
        expect(controller.text, 'first');

        final nextSemantics = tester.ensureSemantics();
        await tester.pump();
        await tester.pump();
        final secondView = tester.widget<AppKitView>(find.byType(AppKitView));
        secondView.onPlatformViewCreated?.call(12);

        await _sendText(tester, 11, 'still stale');
        expect(controller.text, 'first');
        await _sendText(tester, 12, 'second');
        expect(controller.text, 'second');
        expect(changed, <String>['first', 'second']);

        await tester.pumpWidget(const SizedBox.shrink());
        await _sendText(tester, 12, 'disposed');
        expect(controller.text, 'second');
        nextSemantics.dispose();
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
    semanticsEnabled: false,
  );
}

Future<void> _sendText(WidgetTester tester, int viewId, String text) async {
  final response = Completer<ByteData?>();
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'com.ianvs.acp/accessible-text-field/$viewId',
    const StandardMethodCodec().encodeMethodCall(MethodCall('setText', text)),
    response.complete,
  );
  await response.future;
  await tester.pump();
}
