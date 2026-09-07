import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/fake_agent_client.dart';
import 'package:ianvs_acp/chat/acp_chat_session.dart';
import 'package:ianvs_acp/state/chat_controller.dart';

void main() {
  test(
    'ACP bridge uses the existing controller transcript and forwards actions',
    () async {
      final controller = ChatController(
        client: FakeAgentClient(),
        cwd: '/workspace',
      );
      addTearDown(controller.dispose);
      final session = AcpChatSession(controller);
      var notifications = 0;
      void listener() {
        notifications++;
      }

      session.addListener(listener);
      await controller.connect();
      await controller.newSession();
      await session.send('hello');
      while (controller.isStreaming) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(session.state.capabilities.tools, isTrue);
      expect(session.state.messages.length, controller.visibleMessages.length);
      expect(
        session.state.messages.first,
        same(controller.visibleMessages.first),
      );
      expect(notifications, greaterThan(0));
      session.removeListener(listener);
      final previous = notifications;
      await session.send('again');
      while (controller.isStreaming) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(notifications, previous);
      expect(
        controller.visibleMessages
            .where((m) => m.role == ChatMessageRole.user)
            .length,
        2,
      );
    },
  );
}
