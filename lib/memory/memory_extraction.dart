import 'dart:convert';

class ExtractedMemoryCandidate {
  const ExtractedMemoryCandidate({
    required this.kind,
    required this.scope,
    required this.text,
    this.confidence,
    this.reason,
  });

  final String kind;
  final String scope;
  final String text;
  final double? confidence;
  final String? reason;

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind,
    'scope': scope,
    'text': text,
    if (confidence != null) 'confidence': confidence,
    if (reason != null) 'reason': reason,
  };

  factory ExtractedMemoryCandidate.fromJson(Object? raw) {
    if (raw is! Map) {
      throw const FormatException('Memory candidate must be an object.');
    }
    return ExtractedMemoryCandidate(
      kind: raw['kind'] as String? ?? '',
      scope: raw['scope'] as String? ?? '',
      text: raw['text'] as String? ?? '',
      confidence: (raw['confidence'] as num?)?.toDouble(),
      reason: raw['reason'] as String?,
    );
  }
}

String buildMemoryExtractionPrompt({
  required String userPrompt,
  required String assistantAnswer,
}) {
  return '''
You are a memory extraction engine for a local AI agent client.
Extract only durable, useful memories from the current turn.
Allowed memory kinds:
1. user_preference
2. project_rule
3. architecture_decision
4. session_summary
Do not extract secrets, temporary one-off instructions, unverified assumptions, long code snippets, or error logs.
Do not extract AGENTS.md, system/developer/agent operating constraints, tool-use rules, or repository instruction-file rules.
Return JSON only.
Schema:
{"candidates":[{"kind":"user_preference | project_rule | architecture_decision | session_summary","scope":"global | workspace | repo | session","text":"Clear, concise memory text.","confidence":0.0,"reason":"Short reason why this is durable and useful."}]}

User prompt:
$userPrompt

Assistant answer:
$assistantAnswer
''';
}

List<ExtractedMemoryCandidate> parseExtractedMemoryCandidates(String raw) {
  final decoded = jsonDecode(_jsonObjectText(raw));
  if (decoded is! Map) {
    throw const FormatException(
      'Memory extraction response must be an object.',
    );
  }
  final candidates = decoded['candidates'];
  if (candidates is! List) return const <ExtractedMemoryCandidate>[];
  return candidates
      .map(ExtractedMemoryCandidate.fromJson)
      .where((candidate) {
        return candidate.kind.trim().isNotEmpty &&
            candidate.scope.trim().isNotEmpty &&
            candidate.text.trim().isNotEmpty &&
            !isAgentOperatingConstraintMemoryText(candidate.text);
      })
      .toList(growable: false);
}

List<ExtractedMemoryCandidate> extractRuleBasedMemoryCandidates({
  required String userPrompt,
  required String assistantAnswer,
}) {
  final candidates = <ExtractedMemoryCandidate>[];
  final prompt = userPrompt.trim();
  if (prompt.isEmpty) return const <ExtractedMemoryCandidate>[];

  for (final content in _explicitMemoryDirectives(prompt)) {
    if (_looksSensitive(content)) continue;
    if (isAgentOperatingConstraintMemoryText(content)) continue;
    final kind = _memoryKindFor(content);
    final text = _memoryTextFor(content);
    if (text.isEmpty) continue;
    candidates.add(
      ExtractedMemoryCandidate(
        kind: kind,
        scope: _memoryScopeFor(content, kind),
        text: text,
        confidence: 0.93,
        reason: 'Explicit remember directive.',
      ),
    );
  }

  return mergeExtractedMemoryCandidates(
    const <ExtractedMemoryCandidate>[],
    candidates,
  );
}

List<ExtractedMemoryCandidate> mergeExtractedMemoryCandidates(
  Iterable<ExtractedMemoryCandidate> primary,
  Iterable<ExtractedMemoryCandidate> fallback,
) {
  final merged = <ExtractedMemoryCandidate>[];
  final seen = <String>{};

  void add(ExtractedMemoryCandidate candidate) {
    if (isAgentOperatingConstraintMemoryText(candidate.text)) return;
    final key = [
      candidate.kind.trim().toLowerCase(),
      candidate.scope.trim().toLowerCase(),
      candidate.text.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase(),
    ].join('\u0000');
    if (key.trim().isEmpty || !seen.add(key)) return;
    merged.add(candidate);
  }

  for (final candidate in primary) {
    add(candidate);
  }
  for (final candidate in fallback) {
    add(candidate);
  }

  return merged;
}

Iterable<String> _explicitMemoryDirectives(String prompt) sync* {
  final patterns = [
    RegExp(
      r'(?:请)?(?:帮我)?(?:记住|记一下|记下来|记得)\s*[:：,，]?\s*(.+)',
      caseSensitive: false,
    ),
    RegExp(r'\b(?:remember|note)\s+(?:that\s+)?(.+)', caseSensitive: false),
  ];

  for (final pattern in patterns) {
    for (final match in pattern.allMatches(prompt)) {
      final rawContent = match.group(1) ?? '';
      if (isAgentOperatingConstraintMemoryText(rawContent)) continue;
      final content = _firstMemorySentence(rawContent);
      if (content.isNotEmpty) yield content;
    }
  }
}

String _firstMemorySentence(String raw) {
  var text = raw.trim().replaceFirst(RegExp(r'^[\s:：,，。.!！-]+'), '');
  if (text.isEmpty) return '';
  final end = RegExp(r'[。.!！?？\n]').firstMatch(text);
  if (end != null) {
    text = text.substring(0, end.end);
  }
  return text.trim().replaceAll(RegExp(r'\s+'), ' ');
}

bool _looksSensitive(String content) {
  final lower = content.toLowerCase();
  if (RegExp(
    r'\b(api[_ -]?key|token|secret|password|passphrase|private key|bearer)\b',
  ).hasMatch(lower)) {
    return true;
  }
  return RegExp(r'(密码|密钥|私钥|访问令牌|令牌)').hasMatch(content);
}

bool isAgentOperatingConstraintMemoryText(String content) {
  final lower = content.toLowerCase();
  final mentionsAgents =
      lower.contains('agents.md') ||
      lower.contains('agent operating') ||
      lower.contains('agent instruction');
  final mentionsConstraint =
      lower.contains('constraint') ||
      lower.contains('instruction') ||
      lower.contains('tool-use') ||
      lower.contains('tool use') ||
      lower.contains('rule') ||
      RegExp(r'(约束|指令|工具规则|工具使用规则)').hasMatch(content);
  if (mentionsAgents && mentionsConstraint) return true;

  final mentionsNetcat =
      lower.contains('netcat') ||
      RegExp(r'(^|[^a-z0-9])nc([^a-z0-9]|$)').hasMatch(lower);
  final prohibits =
      lower.contains('do not use') ||
      lower.contains('never use') ||
      lower.contains('must not use') ||
      RegExp(r'(严禁使用|禁止使用|不要使用|禁用)').hasMatch(content);
  return mentionsNetcat && prohibits;
}

String _memoryKindFor(String content) {
  if (_preferredName(content) != null) return 'user_preference';
  if (_looksProjectScoped(content)) {
    return _looksArchitectureDecision(content)
        ? 'architecture_decision'
        : 'project_rule';
  }
  if (_looksUserPreference(content)) return 'user_preference';
  return 'session_summary';
}

String _memoryScopeFor(String content, String kind) {
  if (kind == 'user_preference') return 'global';
  if (_looksProjectScoped(content) || kind == 'architecture_decision') {
    return 'repo';
  }
  return 'session';
}

String _memoryTextFor(String content) {
  final name = _preferredName(content);
  if (name != null) return '用户称呼是 $name。';
  return _ensureTerminalPunctuation(content);
}

String? _preferredName(String content) {
  final patterns = [
    RegExp(r'^(?:我(?:是|叫)|我的名字是)\s*[:：]?\s*(.+)$'),
    RegExp(r'^叫我\s*[:：]?\s*(.+)$'),
    RegExp(r'^(?:my name is|call me)\s+(.+)$', caseSensitive: false),
  ];

  for (final pattern in patterns) {
    final match = pattern.firstMatch(content.trim());
    if (match == null) continue;
    final name = _cleanShortValue(match.group(1) ?? '');
    if (name.isNotEmpty) return name;
  }
  return null;
}

String _cleanShortValue(String raw) {
  var value = raw
      .trim()
      .replaceAll(RegExp(r'^[「『"“”]+'), '')
      .replaceAll(RegExp(r'[」』"“”]+$'), '')
      .replaceAll("'", '');
  final stop = RegExp(r'[，,。.!！?？]').firstMatch(value);
  if (stop != null) value = value.substring(0, stop.start);
  value = value.trim();
  if (value.length > 80) return '';
  return value;
}

bool _looksProjectScoped(String content) {
  final lower = content.toLowerCase();
  return RegExp(
    r'(本项目|这个项目|当前项目|本仓库|仓库|repo|repository|project)',
  ).hasMatch(lower);
}

bool _looksArchitectureDecision(String content) {
  final lower = content.toLowerCase();
  return RegExp(r'(架构|架构决策|技术选型|选用|采用.+作为|architecture|adr)').hasMatch(lower);
}

bool _looksUserPreference(String content) {
  final lower = content.toLowerCase();
  return RegExp(r'(我喜欢|我偏好|我的偏好|我习惯|称呼|prefer|preference)').hasMatch(lower);
}

String _ensureTerminalPunctuation(String content) {
  final text = content.trim();
  if (text.isEmpty) return '';
  if (RegExp(r'[。.!！?？]$').hasMatch(text)) return text;
  return '$text。';
}

String _jsonObjectText(String raw) {
  final trimmed = raw.trim();
  if (trimmed.startsWith('{') && trimmed.endsWith('}')) {
    return trimmed;
  }
  final start = trimmed.indexOf('{');
  final end = trimmed.lastIndexOf('}');
  if (start < 0 || end <= start) {
    throw const FormatException('Memory extraction response missing JSON.');
  }
  return trimmed.substring(start, end + 1);
}
