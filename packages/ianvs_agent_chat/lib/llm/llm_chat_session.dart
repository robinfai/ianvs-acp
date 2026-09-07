import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'package:ianvs_agent_chat/ianvs_agent_chat.dart';
import 'package:flutter/foundation.dart';
import 'openai_chat_client.dart';

typedef ChatToolExecutor =
    Future<String> Function(
      Map<String, Object?> arguments,
      ChatCancellation cancellation,
    );

/// The host explicitly registers tools and validates their business arguments.
class ChatTool {
  const ChatTool({
    required this.name,
    required this.description,
    required this.parameters,
    required this.execute,
    this.requiresApproval = true,
  });
  final String name;
  final String description;
  final Map<String, Object?> parameters;
  final ChatToolExecutor execute;
  final bool requiresApproval;
  Map<String, Object?> toJson() => {
    'type': 'function',
    'function': {
      'name': name,
      'description': description,
      'parameters': parameters,
    },
  };
}

/// Each instance owns independent context, cancellation and permissions.
/// Only completed turns enter future requests. Tools execute in the host.
class LlmChatSession extends ChatSession with ChangeNotifier {
  LlmChatSession({
    required this.client,
    String? sessionId,
    this.agentName = 'Assistant',
    this.systemPrompt = '',
    this.supportsImages = false,
    List<ChatTool> tools = const [],
    this.maxToolRounds = 8,
    this.maxToolCallsPerRound = 32,
    this.maxHistoryTurns = 30,
    this.maxContextBytes = 4 * 1024 * 1024,
    this.inputBudget = const ChatInputBudget(),
  }) : sessionId =
           sessionId ??
           'llm-${DateTime.now().microsecondsSinceEpoch}-${_nextSession++}',
       tools = List.unmodifiable(tools) {
    inputBudget.validate();
    if (maxToolRounds <= 0 ||
        maxToolCallsPerRound <= 0 ||
        maxHistoryTurns <= 0 ||
        maxContextBytes <= 0) {
      throw ArgumentError('Session limits must be positive.');
    }
    if (tools.map((t) => t.name).toSet().length != tools.length ||
        tools.any((t) => t.name.trim().isEmpty)) {
      throw ArgumentError('Tools need unique, non-empty names.');
    }
    _checkContext([
      if (systemPrompt.isNotEmpty) {'role': 'system', 'content': systemPrompt},
    ]);
  }
  static int _nextSession = 0;
  final OpenAiChatClient client;
  final String sessionId, agentName, systemPrompt;
  final bool supportsImages;
  final List<ChatTool> tools;
  final int maxToolRounds,
      maxToolCallsPerRound,
      maxHistoryTurns,
      maxContextBytes;
  final ChatInputBudget inputBudget;
  final List<ChatMessageView> _messages = [];
  final List<List<Map<String, Object?>>> _history = [];
  ChatCancellation? _active;
  ChatPermissionRequest? _permission;
  Completer<ChatPermissionDecision>? _permissionDecision;
  int _turn = 0, _revision = 0;
  bool _disposed = false;
  String? _error;

  @override
  ChatSessionState get state => ChatSessionState(
    identity: sessionId,
    agentName: agentName,
    title: client.model,
    messages: UnmodifiableListView(_messages),
    messagesRevision: _revision,
    enabled: !_disposed && (_active == null || _permission != null),
    isSending: _active != null,
    permission: _permission,
    error: _error,
    capabilities: ChatCapabilities(
      prompt: ChatPromptCapabilities(
        files: false,
        image: supportsImages,
        audio: false,
        embeddedContext: false,
      ),
      attachments: supportsImages,
      tools: tools.isNotEmpty,
      permissions: tools.any((tool) => tool.requiresApproval),
    ),
    inputBudget: inputBudget,
  );

  @override
  Future<void> send(
    String text, {
    List<PromptAttachment> attachments = const [],
  }) async {
    if (_disposed) throw StateError('Session is disposed.');
    if (_active != null) throw StateError('A response is already running.');
    if (text.trim().isEmpty && attachments.isEmpty) return;
    final user = _userMessage(text, attachments);
    final system = <Map<String, Object?>>[
      if (systemPrompt.isNotEmpty) {'role': 'system', 'content': systemPrompt},
    ];
    _checkContext([...system, user]);
    final retained = List<List<Map<String, Object?>>>.of(_history);
    // Remove whole turns, preserving tool-call/result pairing.
    while (retained.isNotEmpty &&
        _contextSize([...system, ...retained.expand((t) => t), user]) >
            maxContextBytes) {
      retained.removeAt(0);
    }
    final history = retained.expand((t) => t).toList();
    final working = <Map<String, Object?>>[user];
    final cancellation = ChatCancellation();
    _active = cancellation;
    _error = null;
    _turn++;
    final turnId = _turn;
    _messages.add(
      ChatMessageData(
        id: '$sessionId:$turnId:user',
        role: ChatMessageRole.user,
        text: text,
        turnId: turnId,
        metadata: {
          if (attachments.isNotEmpty)
            'contentBlocks': [
              for (final a in attachments)
                {'type': 'image', 'data': a.data, 'mimeType': a.imageMimeType},
            ],
        },
      ),
    );
    _notify();
    try {
      for (var round = 0; round <= maxToolRounds; round++) {
        cancellation.check();
        final requestMessages = [...system, ...history, ...working];
        _checkContext(requestMessages);
        final message = _LlmTextMessage(
          '$sessionId:$turnId:$round',
          turnId,
          inputBudget,
        );
        final reasoning = StringBuffer();
        var reasoningBytes = 0;
        final calls = <int, _ToolCallBuffer>{};
        String? finishReason;
        var visible = false;
        await for (final chunk in client.stream(
          messages: requestMessages,
          cancellation: cancellation,
          tools: tools.map((t) => t.toJson()).toList(),
        )) {
          cancellation.check();
          final choices = chunk['choices'];
          if (choices is! List || choices.isEmpty) continue;
          final choice = choices
              .whereType<Map>()
              .where((c) => c['index'] == 0)
              .firstOrNull;
          if (choice == null) continue;
          final reason = choice['finish_reason'];
          if (reason is String) finishReason = reason;
          final delta = choice['delta'];
          if (delta is! Map) continue;
          final thought = delta['reasoning_content'];
          if (thought is String) {
            reasoningBytes += utf8.encode(thought).length;
            if (reasoningBytes > inputBudget.maxThoughtTextBytes) {
              throw const ChatApiException(
                'Reasoning exceeded its size limit.',
              );
            }
            reasoning.write(thought);
          }
          final content = delta['content'] ?? delta['refusal'];
          if (content is String && content.isNotEmpty) {
            message.append(content);
            if (!visible) {
              _messages.add(message);
              visible = true;
            }
          }
          final updates = delta['tool_calls'];
          if (updates is List) {
            for (final update in updates) {
              if (update is! Map || update['index'] is! int) {
                throw const ChatApiException('Invalid tool-call stream.');
              }
              final index = update['index'] as int;
              if (index < 0 || index >= maxToolCallsPerRound) {
                throw const ChatApiException(
                  'Too many tool calls in one response.',
                );
              }
              calls
                  .putIfAbsent(
                    index,
                    () => _ToolCallBuffer(inputBudget.maxMetadataBytes),
                  )
                  .add(update);
            }
          }
          _notify();
        }
        cancellation.check();
        message.finish();
        if (finishReason == null) {
          throw const ChatApiException(
            'The model did not finish its response.',
          );
        }
        if (calls.isEmpty) {
          if (finishReason == 'tool_calls') {
            throw const ChatApiException(
              'The model finished without its tool calls.',
            );
          }
          if (finishReason != 'stop') {
            throw ChatApiException(
              finishReason == 'length'
                  ? 'The model reached its output limit. The partial reply is shown.'
                  : 'The model could not complete this reply.',
            );
          }
          working.add({'role': 'assistant', 'content': message.text});
          _history
            ..clear()
            ..addAll(retained)
            ..add(working);
          while (_history.length > maxHistoryTurns) {
            _history.removeAt(0);
          }
          return;
        }
        if (finishReason != 'tool_calls') {
          throw const ChatApiException(
            'The model returned incomplete tool calls.',
          );
        }
        if (round >= maxToolRounds) {
          throw const ChatApiException('The tool round limit was reached.');
        }
        final ordered = calls.keys.toList()..sort();
        final completed = [for (final i in ordered) calls[i]!.finish()];
        if (completed.map((c) => c.id).toSet().length != completed.length) {
          throw const ChatApiException('The model reused a tool-call ID.');
        }
        working.add({
          'role': 'assistant',
          if (reasoning.isNotEmpty) 'reasoning_content': reasoning.toString(),
          'content': message.text.isEmpty ? null : message.text,
          'tool_calls': [for (final c in completed) c.toJson()],
        });
        for (final call in completed) {
          cancellation.check();
          final tool = tools.where((t) => t.name == call.name).firstOrNull;
          final index = _messages.length;
          _messages.add(
            ChatMessageData(
              id: '$sessionId:$turnId:tool:${call.id}',
              role: ChatMessageRole.tool,
              text: call.name,
              turnId: turnId,
              metadata: {
                'toolCallId': call.id,
                'title': call.name,
                'kind': 'tool',
                'status': 'in_progress',
                'rawInput': call.arguments,
              },
            ),
          );
          _notify();
          var failed = false;
          String output;
          if (tool == null) {
            output = 'Error: unknown tool.';
            failed = true;
          } else {
            Map<String, Object?>? arguments;
            try {
              final value = jsonDecode(call.arguments);
              if (value is Map<String, dynamic>) {
                arguments = Map<String, Object?>.from(value);
              }
            } catch (_) {
              /* Do not execute malformed arguments. */
            }
            if (arguments == null) {
              output = 'Error: tool arguments must be a JSON object.';
              failed = true;
            } else if (tool.requiresApproval &&
                !await _approve(call, cancellation)) {
              output = 'Tool execution denied by the user.';
              failed = true;
            } else {
              cancellation.check();
              try {
                output = await cancellation.bind(
                  tool.execute(arguments, cancellation),
                );
              } on ChatCancelled {
                rethrow;
              } catch (_) {
                output = 'Error: the tool failed.';
                failed = true;
              }
            }
          }
          cancellation.check();
          if (utf8.encode(output).length > inputBudget.maxMetadataBytes) {
            output = 'Error: tool output exceeded its size limit.';
            failed = true;
          }
          final original = _messages[index] as ChatMessageData;
          _messages[index] = original.copyWith(
            metadata: {
              ...original.metadata,
              'status': failed ? 'failed' : 'completed',
              'rawOutput': output,
            },
          );
          working.add({
            'role': 'tool',
            'tool_call_id': call.id,
            'content': output,
          });
          _notify();
        }
      }
    } on ChatCancelled {
      _settleTools('cancelled');
      _messages.add(
        ChatMessageData(
          role: ChatMessageRole.status,
          text: 'Response stopped.',
          turnId: turnId,
        ),
      );
    } catch (error) {
      _settleTools('failed');
      _error = error is ChatApiException
          ? error.toString()
          : 'The response could not be completed.';
      _messages.add(
        ChatMessageData(
          role: ChatMessageRole.error,
          text: _error!,
          turnId: turnId,
        ),
      );
    } finally {
      if (identical(_active, cancellation)) {
        _active = null;
        _permission = null;
        _permissionDecision = null;
        _trimTimeline();
        _notify();
      }
    }
  }

  Map<String, Object?> _userMessage(
    String text,
    List<PromptAttachment> attachments,
  ) {
    if (utf8.encode(text).length > inputBudget.maxMessageTextBytes) {
      throw const ChatApiException('The prompt exceeds its size limit.');
    }
    if (attachments.length > inputBudget.maxCollectionItems) {
      throw const ChatApiException('Too many attachments.');
    }
    for (final a in attachments) {
      if (!supportsImages || !a.isImage || a.data == null) {
        throw const ChatApiException(
          'This session accepts inline images only. The host must load the selected image first.',
        );
      }
      scanChatBase64(
        a.data!,
        maxDecodedBytes: inputBudget.maxEmbeddedMediaBytes,
        resource: 'image attachment',
      );
    }
    return {
      'role': 'user',
      'content': attachments.isEmpty
          ? text
          : [
              if (text.isNotEmpty) {'type': 'text', 'text': text},
              for (final a in attachments)
                {
                  'type': 'image_url',
                  'image_url': {
                    'url': 'data:${a.imageMimeType};base64,${a.data}',
                  },
                },
            ],
    };
  }

  Future<bool> _approve(_ToolCall call, ChatCancellation cancellation) async {
    final decision = Completer<ChatPermissionDecision>();
    _permissionDecision = decision;
    _permission = ChatPermissionRequest(
      id: '$sessionId:$_turn:${call.id}',
      title: 'Run ${call.name}?',
      rationale: 'The model requested this tool.',
      sessionId: sessionId,
      toolName: call.name,
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
      metadata: {'rawInput': call.arguments},
    );
    _notify();
    try {
      return await cancellation.bind(decision.future) ==
          ChatPermissionDecision.allow;
    } finally {
      _permission = null;
      _permissionDecision = null;
      _notify();
    }
  }

  @override
  Future<void> resolvePermission(ChatPermissionDecision decision) async {
    final pending = _permissionDecision;
    if (pending != null && !pending.isCompleted) pending.complete(decision);
  }

  @override
  Future<void> selectPermissionOption(String optionId) async {
    if (optionId == 'allow_once') {
      await resolvePermission(ChatPermissionDecision.allow);
    } else if (optionId == 'reject_once') {
      await resolvePermission(ChatPermissionDecision.deny);
    } else {
      throw ArgumentError.value(optionId, 'optionId');
    }
  }

  @override
  Future<void> stop() async {
    _active?.cancel();
  }

  int _contextSize(List<Map<String, Object?>> messages) =>
      utf8.encode(jsonEncode(messages)).length;
  void _checkContext(List<Map<String, Object?>> messages) {
    if (_contextSize(messages) > maxContextBytes) {
      throw const ChatApiException(
        'The conversation exceeds its context size limit. Start a new conversation.',
      );
    }
  }

  void _settleTools(String status) {
    for (var i = 0; i < _messages.length; i++) {
      final m = _messages[i];
      if (m is ChatMessageData &&
          m.turnId == _turn &&
          m.role == ChatMessageRole.tool &&
          m.metadata['status'] == 'in_progress') {
        _messages[i] = m.copyWith(metadata: {...m.metadata, 'status': status});
      }
    }
  }

  void _trimTimeline() {
    int size(ChatMessageView m) =>
        utf8.encode(m.text).length + utf8.encode(jsonEncode(m.metadata)).length;
    var bytes = _messages.fold<int>(0, (sum, m) => sum + size(m));
    while (_messages.isNotEmpty &&
        (_messages.length > inputBudget.maxTimelineItems ||
            bytes > inputBudget.maxTimelineBytes)) {
      final oldest = _messages.first.turnId;
      do {
        bytes -= size(_messages.removeAt(0));
      } while (_messages.isNotEmpty && _messages.first.turnId == oldest);
    }
  }

  void _notify() {
    _revision++;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _active?.cancel();
    super.dispose();
  }
}

class _LlmTextMessage implements ChatMessageView {
  _LlmTextMessage(this.id, this.turnId, ChatInputBudget budget)
    : counter = ChatUtf8LineBudgetCounter(
        maxBytes: budget.maxMessageTextBytes,
        maxLines: budget.maxMessageTextLines,
        resource: 'assistant text',
      );
  final String id;
  final ChatUtf8LineBudgetCounter counter;
  final StringBuffer _buffer = StringBuffer();
  String? _cached;
  String _preview = '';
  @override
  final int turnId;
  @override
  final DateTime timestamp = DateTime.now();
  @override
  int revision = 0;
  @override
  ChatMessageRole get role => ChatMessageRole.assistant;
  @override
  Map<String, Object?> get metadata => const {};
  @override
  List<ChatInputOmission> get omissions => const [];
  @override
  String get text => _cached ??= _buffer.toString();
  @override
  String get previewText => _preview;
  void append(String value) => _accept(counter.append(value));
  void finish() => _accept(counter.finish());
  void _accept(ChatTextBudgetChunk chunk) {
    if (chunk.omission != null) {
      throw const ChatApiException('The response exceeded its text limit.');
    }
    if (chunk.safePrefix.isEmpty) return;
    _buffer.write(chunk.safePrefix);
    _cached = null;
    revision++;
    if (_preview.length < 256) {
      _preview = (_preview + chunk.safePrefix).substring(
        0,
        (_preview.length + chunk.safePrefix.length).clamp(0, 256),
      );
    }
  }
}

class _ToolCall {
  const _ToolCall(this.id, this.name, this.arguments);
  final String id, name, arguments;
  Map<String, Object?> toJson() => {
    'id': id,
    'type': 'function',
    'function': {'name': name, 'arguments': arguments},
  };
}

class _ToolCallBuffer {
  _ToolCallBuffer(this.limit);
  final int limit;
  var bytes = 0;
  final StringBuffer id = StringBuffer(),
      name = StringBuffer(),
      arguments = StringBuffer();
  void add(Map<dynamic, dynamic> update) {
    void append(StringBuffer buffer, Object? value) {
      if (value == null) return;
      if (value is! String) {
        throw const ChatApiException('Invalid tool-call fragment.');
      }
      bytes += utf8.encode(value).length;
      if (bytes > limit) {
        throw const ChatApiException(
          'Tool arguments exceeded their size limit.',
        );
      }
      buffer.write(value);
    }

    append(id, update['id']);
    final function = update['function'];
    if (function is Map) {
      append(name, function['name']);
      append(arguments, function['arguments']);
    }
  }

  _ToolCall finish() {
    if (id.isEmpty || name.isEmpty) {
      throw const ChatApiException(
        'The model returned an incomplete tool call.',
      );
    }
    return _ToolCall(id.toString(), name.toString(), arguments.toString());
  }
}
