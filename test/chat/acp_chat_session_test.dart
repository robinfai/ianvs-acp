import 'package:ianvs_agent_chat/models/prompt_attachment.dart';
import 'package:ianvs_agent_chat/chat_submission.dart';
import 'package:ianvs_acp/acp/agent_event.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/fake_agent_client.dart';
import 'package:ianvs_acp/chat/acp_chat_session.dart';
import 'package:ianvs_acp/state/chat_controller.dart';

void main() {
  test(
    'first-send creation preserves identity and rejects failed setup without a duplicate user turn',
    () async {
      final controller = ChatController(
        client: SetupFailureClient(),
        cwd: '/workspace',
      );
      addTearDown(controller.dispose);
      final session = AcpChatSession(controller);
      final identity = session.state.identity;
      ChatSubmission request(String id) => ChatSubmission(
        id: id,
        sessionIdentity: identity,
        draftRevision: 0,
        text: 'retry me',
      );
      expect(
        (await session.submit(request('one'))).status,
        ChatSubmitStatus.rejected,
      );
      expect(session.state.identity, identity);
      expect(
        controller.messages.where((m) => m.role == ChatMessageRole.user),
        isEmpty,
      );
      expect(
        (await AcpChatSession(controller).submit(request('one'))).status,
        ChatSubmitStatus.rejected,
      );
      expect(
        (await session.submit(request('retry'))).status,
        ChatSubmitStatus.rejected,
      );
      expect(
        controller.messages.where((m) => m.role == ChatMessageRole.user),
        isEmpty,
      );
      await controller.newSession();
      expect(session.state.identity, isNot(identity));
    },
  );

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

class SetupFailureClient extends FakeAgentClient {
  @override
  Stream<AgentEvent> sendPrompt({
    required String sessionId,
    required String prompt,
    List<PromptAttachment> attachments = const [],
  }) => throw StateError('setup failed');
}
