import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_agent_chat/ianvs_agent_chat.dart';
import 'package:ianvs_agent_chat/llm.dart';

// Explicit opt-in: ordinary test runs never spend API credits.
void main() {
  final enabled = Platform.environment['RUN_DEEPSEEK_TESTS'] == '1';
  final key = Platform.environment['DEEPSEEK_API_KEY'];
  final model = Platform.environment['DEEPSEEK_MODEL'] ?? 'deepseek-v4-flash';
  OpenAiChatClient client() => OpenAiChatClient(
    endpoint: Uri.parse('https://api.deepseek.com/chat/completions'),
    model: model,
    apiKey: key,
    extraBody: const {
      'thinking': {'type': 'disabled'},
      'max_tokens': 256,
      'temperature': 0,
    },
  );
  test(
    'DeepSeek streams a reply and retains multi-turn context',
    () async {
      expect(
        key?.isNotEmpty,
        isTrue,
        reason: 'Set DEEPSEEK_API_KEY without putting it in source files.',
      );
      final session = LlmChatSession(client: client());
      addTearDown(session.dispose);
      await session.send(
        'Remember the code word IANVS_BLUE. Reply with only IANVS_OK.',
      );
      expect(session.state.error, isNull);
      expect(session.state.messages.last.text, contains('IANVS_OK'));
      await session.send(
        'What is the code word? Reply with only the code word.',
      );
      expect(session.state.error, isNull);
      expect(session.state.messages.last.text, contains('IANVS_BLUE'));
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'DeepSeek invokes an approved host tool and consumes its result',
    () async {
      var calls = 0, approvals = 0;
      final session = LlmChatSession(
        client: client(),
        systemPrompt:
            'When asked to add integers, use add_integers exactly once, then answer with only the result returned by the tool.',
        tools: [
          ChatTool(
            name: 'add_integers',
            description: 'Add two integers.',
            parameters: const {
              'type': 'object',
              'properties': {
                'a': {'type': 'integer'},
                'b': {'type': 'integer'},
              },
              'required': ['a', 'b'],
              'additionalProperties': false,
            },
            execute: (arguments, cancellation) async {
              cancellation.check();
              calls++;
              return '${(arguments['a'] as int) + (arguments['b'] as int)}';
            },
          ),
        ],
      );
      addTearDown(session.dispose);
      String? lastRequest;
      session.addListener(() {
        final request = session.state.permission;
        if (request != null && request.id != lastRequest) {
          lastRequest = request.id;
          approvals++;
          session.resolvePermission(ChatPermissionDecision.allow);
        }
      });
      await session.send('Use add_integers to add 7 and 11.');
      expect(session.state.error, isNull);
      expect(calls, 1);
      expect(approvals, 1);
      expect(session.state.messages.last.text, contains('18'));
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
