import 'package:agent_chat_demo/main.dart';
import 'package:ianvs_agent_chat/ianvs_agent_chat.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'standalone host renders without application or native clipboard',
    (tester) async {
      await tester.pumpWidget(const AgentChatDemo());
      expect(find.byType(AgentChatView), findsOneWidget);
      expect(find.text('Agent Chat'), findsOneWidget);
      await tester.tap(find.text('LLM API'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('llm-endpoint')), findsOneWidget);
      expect(find.byKey(const Key('llm-model')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  test(
    'demo approval and streaming work through the common session contract',
    () async {
      final session = DemoSession();
      addTearDown(session.dispose);
      final send = session.send('hello');
      expect(session.state.permission, isNotNull);
      await session.selectPermissionOption('allow_once');
      await send;
      expect(session.state.messages.last.text, contains('5 characters'));
      expect(session.state.isSending, isFalse);
    },
  );
}
