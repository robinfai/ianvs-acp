class AssistantAgentConfig {
  const AssistantAgentConfig({
    this.enabled = false,
    this.agentName,
    this.model,
    this.generateSessionTitles = true,
    this.summarizeTurns = true,
    this.collapseExecutionProcess = true,
    this.fallbackTitleCharacters = 24,
    this.timeout = const Duration(seconds: 30),
  });

  static const int minimumFallbackTitleCharacters = 8;
  static const int maximumFallbackTitleCharacters = 128;

  final bool enabled;
  final String? agentName;
  final String? model;
  final bool generateSessionTitles;
  final bool summarizeTurns;
  final bool collapseExecutionProcess;
  final int fallbackTitleCharacters;
  final Duration timeout;

  bool get isConfigured =>
      enabled && agentName != null && agentName!.trim().isNotEmpty;

  AssistantAgentConfig copyWith({
    bool? enabled,
    String? agentName,
    bool clearAgentName = false,
    String? model,
    bool clearModel = false,
    bool? generateSessionTitles,
    bool? summarizeTurns,
    bool? collapseExecutionProcess,
    int? fallbackTitleCharacters,
    Duration? timeout,
  }) {
    return AssistantAgentConfig(
      enabled: enabled ?? this.enabled,
      agentName: clearAgentName ? null : agentName ?? this.agentName,
      model: clearModel ? null : model ?? this.model,
      generateSessionTitles:
          generateSessionTitles ?? this.generateSessionTitles,
      summarizeTurns: summarizeTurns ?? this.summarizeTurns,
      collapseExecutionProcess:
          collapseExecutionProcess ?? this.collapseExecutionProcess,
      fallbackTitleCharacters:
          fallbackTitleCharacters ?? this.fallbackTitleCharacters,
      timeout: timeout ?? this.timeout,
    );
  }

  factory AssistantAgentConfig.fromJson(Object? raw) {
    if (raw == null) return const AssistantAgentConfig();
    if (raw is! Map) {
      throw const FormatException('assistant_agent must be an object.');
    }
    final json = Map<String, Object?>.from(raw);
    final fallbackTitleCharacters = _positiveInt(
      json['fallback_title_characters'] ?? json['fallbackTitleCharacters'],
      fallback: 24,
      fieldName: 'assistant_agent.fallback_title_characters',
    );
    if (fallbackTitleCharacters < minimumFallbackTitleCharacters ||
        fallbackTitleCharacters > maximumFallbackTitleCharacters) {
      throw FormatException(
        'assistant_agent.fallback_title_characters must be between '
        '$minimumFallbackTitleCharacters and '
        '$maximumFallbackTitleCharacters.',
      );
    }
    final timeoutMilliseconds = _positiveInt(
      json['timeout_ms'] ?? json['timeoutMs'],
      fallback: 30000,
      fieldName: 'assistant_agent.timeout_ms',
    );
    return AssistantAgentConfig(
      enabled: json['enabled'] == true,
      agentName: _trimmedString(
        json['agent'] ?? json['agent_name'] ?? json['agentName'],
      ),
      model: _trimmedString(json['model']),
      generateSessionTitles: _boolWithDefault(
        json['generate_session_titles'] ?? json['generateSessionTitles'],
        true,
      ),
      summarizeTurns: _boolWithDefault(
        json['summarize_turns'] ?? json['summarizeTurns'],
        true,
      ),
      collapseExecutionProcess: _boolWithDefault(
        json['collapse_execution_process'] ?? json['collapseExecutionProcess'],
        true,
      ),
      fallbackTitleCharacters: fallbackTitleCharacters,
      timeout: Duration(milliseconds: timeoutMilliseconds),
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'enabled': enabled,
      if (agentName?.trim().isNotEmpty == true) 'agent': agentName!.trim(),
      if (model?.trim().isNotEmpty == true) 'model': model!.trim(),
      'generate_session_titles': generateSessionTitles,
      'summarize_turns': summarizeTurns,
      'collapse_execution_process': collapseExecutionProcess,
      'fallback_title_characters': fallbackTitleCharacters,
      'timeout_ms': timeout.inMilliseconds,
    };
  }
}

String? _trimmedString(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

bool _boolWithDefault(Object? value, bool fallback) {
  return value is bool ? value : fallback;
}

int _positiveInt(
  Object? value, {
  required int fallback,
  required String fieldName,
}) {
  if (value == null) return fallback;
  final parsed = switch (value) {
    int value => value,
    String value => int.tryParse(value.trim()),
    _ => null,
  };
  if (parsed == null || parsed <= 0) {
    throw FormatException('$fieldName must be a positive integer.');
  }
  return parsed;
}
