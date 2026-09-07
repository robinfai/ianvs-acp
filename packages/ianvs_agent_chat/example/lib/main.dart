import 'dart:async';
import 'package:ianvs_agent_chat/llm.dart';
import 'package:ianvs_agent_chat/llm_chat_panel.dart';
import 'package:ianvs_agent_chat/ianvs_agent_chat.dart';
import 'package:flutter/material.dart';

void main() => runApp(const AgentChatDemo());

class AgentChatDemo extends StatefulWidget {
  const AgentChatDemo({super.key});
  @override
  State<AgentChatDemo> createState() => _AgentChatDemoState();
}

class _AgentChatDemoState extends State<AgentChatDemo> {
  final _demo = DemoSession();
  int _tab = 0;
  @override
  void dispose() {
    _demo.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      colorSchemeSeed: const Color(0xff0b57d0),
    ),
    home: Scaffold(
      appBar: AppBar(
        title: const Text('Agent Chat'),
        actions: [
          TextButton(
            onPressed: () => setState(() => _tab = 0),
            child: const Text('Demo'),
          ),
          TextButton(
            onPressed: () => setState(() => _tab = 1),
            child: const Text('LLM API'),
          ),
        ],
      ),
      body: IndexedStack(
        index: _tab,
        children: [
          AgentChatView(session: _demo),
          LlmChatPanel(
            initialEndpoint: const String.fromEnvironment('LLM_ENDPOINT'),
            initialModel: const String.fromEnvironment('LLM_MODEL'),
            tools: [
              ChatTool(
                name: 'current_time',
                description: 'Read the current local time.',
                parameters: const {
                  'type': 'object',
                  'properties': <String, Object?>{},
                  'additionalProperties': false,
                },
                execute: (arguments, cancellation) async {
                  cancellation.check();
                  return DateTime.now().toIso8601String();
                },
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

/// An independent host implementation: no ACP client, application controller,
/// workspace, database, native app channel or credentials are imported.
class DemoSession extends ChatSession with ChangeNotifier {
  final List<ChatMessageView> _messages = [
    ChatMessageData(
      role: ChatMessageRole.assistant,
      text:
          'Send a message to try streaming, tool approval and cancellation. Use **LLM API** to connect a real model.',
      turnId: 0,
    ),
  ];
  int _turn = 0, _revision = 0;
  ChatCancellation? _active;
  ChatPermissionRequest? _permission;
  Completer<ChatPermissionDecision>? _decision;
  bool _disposed = false;
  @override
  ChatSessionState get state => ChatSessionState(
    identity: 'demo',
    agentName: 'Demo Agent',
    messages: List.unmodifiable(_messages),
    messagesRevision: _revision,
    isSending: _active != null,
    enabled: _active == null || _permission != null,
    permission: _permission,
    capabilities: const ChatCapabilities(tools: true, permissions: true),
  );
  void _notify() {
    _revision++;
    if (!_disposed) notifyListeners();
  }

  @override
  Future<void> send(
    String text, {
    List<PromptAttachment> attachments = const [],
  }) async {
    if (_active != null || text.trim().isEmpty || _disposed) return;
    final cancellation = ChatCancellation();
    _active = cancellation;
    _turn++;
    _messages.add(
      ChatMessageData(role: ChatMessageRole.user, text: text, turnId: _turn),
    );
    final toolIndex = _messages.length;
    _messages.add(
      ChatMessageData(
        role: ChatMessageRole.tool,
        text: 'Count characters',
        turnId: _turn,
        metadata: {
          'toolCallId': 'count-$_turn',
          'title': 'Count characters',
          'status': 'in_progress',
          'rawInput': {'text': text},
        },
      ),
    );
    _decision = Completer<ChatPermissionDecision>();
    _permission = ChatPermissionRequest(
      id: 'count-$_turn',
      title: 'Count message characters?',
      rationale: 'This demo tool counts the characters in your message.',
      sessionId: 'demo',
      toolName: 'count_characters',
      options: const ['allow_once', 'reject_once'],
      choices: const [
        ChatPermissionChoice(
          optionId: 'allow_once',
          name: 'Allow once',
          kind: 'allow_once',
        ),
        ChatPermissionChoice(
          optionId: 'reject_once',
          name: 'Deny',
          kind: 'reject_once',
        ),
      ],
      requestedAt: DateTime.now(),
    );
    _notify();
    try {
      final allowed =
          await cancellation.bind(_decision!.future) ==
          ChatPermissionDecision.allow;
      _permission = null;
      final tool = _messages[toolIndex] as ChatMessageData;
      _messages[toolIndex] = tool.copyWith(
        metadata: {
          ...tool.metadata,
          'status': allowed ? 'completed' : 'failed',
          'rawOutput': allowed
              ? '${text.runes.length} characters'
              : 'Denied by user',
        },
      );
      final index = _messages.length;
      var message = ChatMessageData(
        role: ChatMessageRole.assistant,
        text: '',
        turnId: _turn,
      );
      _messages.add(message);
      final reply = allowed
          ? 'Your message contains **${text.runes.length} characters**.\n\nThe same chat components work with ACP and an OpenAI-compatible API.'
          : 'Tool execution was denied. You can still chat normally.';
      for (final word in reply.split(' ')) {
        await cancellation.bind(
          Future<void>.delayed(const Duration(milliseconds: 35)),
        );
        message = message.copyWith(text: '${message.text}$word ');
        _messages[index] = message;
        _notify();
      }
    } on ChatCancelled {
      final tool = _messages[toolIndex] as ChatMessageData;
      if (tool.metadata['status'] == 'in_progress') {
        _messages[toolIndex] = tool.copyWith(
          metadata: {...tool.metadata, 'status': 'cancelled'},
        );
      }
      _messages.add(
        ChatMessageData(
          role: ChatMessageRole.status,
          text: 'Response stopped.',
          turnId: _turn,
        ),
      );
    } finally {
      _permission = null;
      _decision = null;
      _active = null;
      _notify();
    }
  }

  @override
  Future<void> resolvePermission(ChatPermissionDecision decision) async {
    if (_decision?.isCompleted == false) _decision!.complete(decision);
  }

  @override
  Future<void> selectPermissionOption(String optionId) => resolvePermission(
    optionId == 'allow_once'
        ? ChatPermissionDecision.allow
        : ChatPermissionDecision.deny,
  );
  @override
  Future<void> stop() async => _active?.cancel();
  @override
  void dispose() {
    _disposed = true;
    _active?.cancel();
    super.dispose();
  }
}
