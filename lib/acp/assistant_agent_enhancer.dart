import 'dart:async';

import '../config/assistant_agent_config.dart';
import 'acp_agent_client.dart';
import 'acp_session_settings.dart';
import 'agent_event.dart';

class AssistantTurnSummaryRequest {
  const AssistantTurnSummaryRequest({
    required this.sessionId,
    required this.turnId,
    required this.userPrompt,
    required this.completedTurn,
  });

  final String sessionId;
  final int turnId;
  final String userPrompt;
  final String completedTurn;
}

abstract interface class AssistantAgentEnhancer {
  AssistantAgentConfig get config;

  Future<String?> generateSessionTitle({
    required String sessionId,
    required String firstPrompt,
  });

  Future<String?> summarizeTurn(AssistantTurnSummaryRequest request);

  Future<void> dispose();
}

class AcpAssistantAgentEnhancer implements AssistantAgentEnhancer {
  AcpAssistantAgentEnhancer(this._client, this._cwd, {required this.config});

  final AcpAgentClient _client;
  final String _cwd;

  @override
  final AssistantAgentConfig config;

  Future<void> _tail = Future<void>.value();
  bool _connected = false;
  bool _disposed = false;

  @override
  Future<String?> generateSessionTitle({
    required String sessionId,
    required String firstPrompt,
  }) {
    if (!config.isConfigured || !config.generateSessionTitles) {
      return Future<String?>.value();
    }
    final boundedPrompt = _boundedInput(firstPrompt, 12000);
    return _enqueue(
      'Create a concise title for a coding-agent session.\n'
      'Return only the title: one line, no quotes, no markdown, at most '
      '48 characters. Preserve the language of the request.\n\n'
      'User request:\n$boundedPrompt',
    );
  }

  @override
  Future<String?> summarizeTurn(AssistantTurnSummaryRequest request) {
    if (!config.isConfigured || !config.summarizeTurns) {
      return Future<String?>.value();
    }
    final prompt = _boundedInput(request.userPrompt, 12000);
    final turn = _boundedInput(request.completedTurn, 48000);
    return _enqueue(
      'Summarize the completed coding-agent turn for the user. Focus on the '
      'final outcome, material changes, verification, and any remaining '
      'limitation. Use the user request language. Return compact Markdown '
      'with no heading, no preamble, and at most 6 bullets or 900 '
      'characters. Never claim an action that is absent from the transcript.'
      '\n\nUser request:\n$prompt\n\nCompleted turn:\n$turn',
    );
  }

  Future<String?> _enqueue(String prompt) {
    final completer = Completer<String?>();
    _tail = _tail.catchError((_) {}).then((_) async {
      if (_disposed) {
        if (!completer.isCompleted) completer.complete();
        return;
      }
      try {
        final result = await _run(prompt).timeout(config.timeout);
        if (!completer.isCompleted) completer.complete(result);
      } on Object {
        if (!completer.isCompleted) completer.complete();
      }
    });
    return completer.future;
  }

  Future<String?> _run(String prompt) async {
    if (!_connected) {
      await _client.connect();
      _connected = true;
    }
    final session = await _client.createSession(cwd: _cwd);
    try {
      await _selectConfiguredModel(session.id);
      final buffer = StringBuffer();
      await for (final event in _client.sendPrompt(
        sessionId: session.id,
        prompt: prompt,
      )) {
        if (event.type == AgentEventType.error) return null;
        if (event.type == AgentEventType.agentTextDelta) {
          buffer.write(event.text);
        } else if (event.type == AgentEventType.agentTextDone &&
            buffer.isEmpty) {
          buffer.write(event.text);
        }
      }
      final value = buffer.toString().trim();
      return value.isEmpty ? null : value;
    } finally {
      try {
        await _client.closeSession(sessionId: session.id);
      } on Object {
        // A failed helper cleanup must not affect the main task.
      }
    }
  }

  Future<void> _selectConfiguredModel(String sessionId) async {
    final requested = config.model?.trim();
    if (requested == null || requested.isEmpty) return;
    final settings = await _client.sessionSettings(sessionId);
    final option = settings.modelOption;
    if (option == null) return;
    final choice = _matchingChoice(option, requested);
    if (choice == null || choice.value == option.currentValue) return;
    await _client.setConfigOption(
      sessionId: sessionId,
      configId: option.id,
      value: choice.value,
    );
  }

  AcpConfigOptionChoice? _matchingChoice(
    AcpConfigOption option,
    String requested,
  ) {
    final normalized = requested.trim().toLowerCase();
    for (final choice in option.options) {
      if (choice.value.trim().toLowerCase() == normalized ||
          choice.label.trim().toLowerCase() == normalized) {
        return choice;
      }
    }
    return null;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _tail.catchError((_) {});
    await _client.dispose();
  }
}

String _boundedInput(String value, int maximumCharacters) {
  final trimmed = value.trim();
  if (trimmed.length <= maximumCharacters) return trimmed;
  return '${trimmed.substring(0, maximumCharacters - 1)}…';
}
