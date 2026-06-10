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
            candidate.text.trim().isNotEmpty;
      })
      .toList(growable: false);
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
