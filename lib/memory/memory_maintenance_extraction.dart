import 'dart:convert';

import 'memory_extraction.dart';

class MemoryMaintenanceItem {
  const MemoryMaintenanceItem({
    required this.id,
    required this.kind,
    required this.scope,
    required this.text,
    this.status = 'active',
  });

  final String id;
  final String kind;
  final String scope;
  final String text;
  final String status;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'kind': kind,
    'scope': scope,
    'status': status,
    'text': text,
  };
}

class MaintenanceChangeRequestSuggestion {
  const MaintenanceChangeRequestSuggestion({
    required this.action,
    required this.targetMemoryIds,
    this.proposedKind,
    this.proposedScope,
    this.proposedText,
    this.confidence,
    this.reason,
  });

  final String action;
  final List<String> targetMemoryIds;
  final String? proposedKind;
  final String? proposedScope;
  final String? proposedText;
  final double? confidence;
  final String? reason;

  factory MaintenanceChangeRequestSuggestion.fromJson(Object? raw) {
    if (raw is! Map) {
      throw const FormatException(
        'Maintenance change request must be an object.',
      );
    }
    final targetMemoryIds = raw['targetMemoryIds'];
    return MaintenanceChangeRequestSuggestion(
      action: raw['action'] as String? ?? '',
      targetMemoryIds: targetMemoryIds is List
          ? targetMemoryIds
                .whereType<String>()
                .map((value) => value.trim())
                .where((value) => value.isNotEmpty)
                .toList(growable: false)
          : const <String>[],
      proposedKind: raw['proposedKind'] as String?,
      proposedScope: raw['proposedScope'] as String?,
      proposedText: raw['proposedText'] as String?,
      confidence: (raw['confidence'] as num?)?.toDouble(),
      reason: raw['reason'] as String?,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'action': action,
    'targetMemoryIds': targetMemoryIds,
    if (proposedKind != null) 'proposedKind': proposedKind,
    if (proposedScope != null) 'proposedScope': proposedScope,
    if (proposedText != null) 'proposedText': proposedText,
    if (confidence != null) 'confidence': confidence,
    if (reason != null) 'reason': reason,
  };
}

String buildMemoryMaintenancePrompt({
  required List<MemoryMaintenanceItem> memories,
}) {
  final encodedMemories = const JsonEncoder.withIndent(
    '  ',
  ).convert(memories.map((memory) => memory.toJson()).toList(growable: false));
  return '''
You are a maintenance engine for a local AI agent memory store.
Review only the provided memory records.
Do not infer new personal facts.
Do not include secrets, long code, logs, or temporary one-off details.
Do not propose AGENTS.md, system/developer/agent operating constraints, tool-use rules, or repository instruction-file rules as memory text.
Prefer concise updates, summaries, and merges that improve retrieval.
Merge duplicate facts toward broader scopes in this direction: session -> repo -> global.
Do not skip intermediate scopes when all duplicate records are at the same narrow level; repeated session-level memories promote to repo before global.
Never downgrade broader scopes; session plus global stays global, and repo plus global stays global.
Treat workspace as legacy-compatible with repo and do not promote into workspace.
Allowed actions: update, disable, delete, merge, summarize, expire.
Use delete only when the record should be removed from long-term memory.
Return JSON only.
Schema:
{"changeRequests":[{"action":"update | disable | delete | merge | summarize | expire","targetMemoryIds":["mem_id"],"proposedKind":"user_preference | project_rule | architecture_decision | session_summary","proposedScope":"global | workspace | repo | session","proposedText":"Clear replacement or merged text.","confidence":0.0,"reason":"Short reason."}]}

Memory records:
$encodedMemories
''';
}

List<MaintenanceChangeRequestSuggestion> parseMaintenanceChangeRequests(
  String raw,
) {
  final decoded = jsonDecode(_jsonObjectText(raw));
  if (decoded is! Map) {
    throw const FormatException('Maintenance response must be an object.');
  }
  final changeRequests = decoded['changeRequests'];
  if (changeRequests is! List) {
    return const <MaintenanceChangeRequestSuggestion>[];
  }
  return changeRequests
      .map(MaintenanceChangeRequestSuggestion.fromJson)
      .where((request) {
        return request.action.trim().isNotEmpty &&
            request.targetMemoryIds.isNotEmpty &&
            !_writesRejectedMemoryText(request);
      })
      .toList(growable: false);
}

bool _writesRejectedMemoryText(MaintenanceChangeRequestSuggestion request) {
  final action = request.action.trim().toLowerCase();
  if (action != 'update' && action != 'summarize' && action != 'merge') {
    return false;
  }
  final proposedText = request.proposedText;
  return proposedText != null &&
      isAgentOperatingConstraintMemoryText(proposedText);
}

List<MemoryMaintenanceItem> prefilterMaintenanceMemories({
  required List<MemoryMaintenanceItem> memories,
  int maxItems = 12,
}) {
  if (memories.length < 2) return const <MemoryMaintenanceItem>[];
  final limit = maxItems.clamp(2, 50);
  final selectedIds = <String>{};
  final selected = <MemoryMaintenanceItem>[];
  for (var leftIndex = 0; leftIndex < memories.length; leftIndex += 1) {
    for (final right in memories.skip(leftIndex + 1)) {
      final left = memories[leftIndex];
      if (left.kind != right.kind ||
          !_canCompareScopes(left.scope, right.scope)) {
        continue;
      }
      final leftSemanticKey = _semanticMemoryKey(left);
      final rightSemanticKey = _semanticMemoryKey(right);
      if (leftSemanticKey != null && rightSemanticKey != null) {
        if (leftSemanticKey != rightSemanticKey) continue;
        for (final memory in [left, right]) {
          if (selectedIds.add(memory.id)) {
            selected.add(memory);
            if (selected.length >= limit) return selected;
          }
        }
        continue;
      }
      final score = _tokenOverlapScore(left.text, right.text);
      if (score < 0.30) continue;
      for (final memory in [left, right]) {
        if (selectedIds.add(memory.id)) {
          selected.add(memory);
          if (selected.length >= limit) return selected;
        }
      }
    }
  }
  for (final memory in memories) {
    if (selectedIds.add(memory.id)) {
      selected.add(memory);
      if (selected.length >= limit) return selected;
    }
  }
  return selected;
}

bool _canCompareScopes(String left, String right) {
  final leftRank = _scopeRank(left);
  final rightRank = _scopeRank(right);
  if (leftRank == null || rightRank == null) return false;
  return (leftRank - rightRank).abs() <= 2;
}

int? _scopeRank(String scope) {
  switch (scope.trim().toLowerCase()) {
    case 'session':
      return 0;
    case 'repo':
    case 'workspace':
      return 1;
    case 'global':
      return 2;
  }
  return null;
}

String? _semanticMemoryKey(MemoryMaintenanceItem memory) {
  switch (memory.kind.trim().toLowerCase()) {
    case 'user_preference':
      return _userLanguagePreferenceKey(memory.text);
  }
  return null;
}

String? _userLanguagePreferenceKey(String text) {
  final compact = text.toLowerCase().replaceAll(
    RegExp(r'[^a-z0-9\u4e00-\u9fff]+'),
    '',
  );
  final language = compact.contains('中文') || compact.contains('汉语')
      ? 'zh'
      : compact.contains('英文') || compact.contains('英语')
      ? 'en'
      : null;
  if (language == null) return null;
  final mentionsPreference =
      compact.contains('偏好') ||
      compact.contains('喜欢') ||
      compact.contains('倾向') ||
      compact.contains('prefer');
  final mentionsCommunication =
      compact.contains('回复') ||
      compact.contains('交流') ||
      compact.contains('沟通') ||
      compact.contains('reply') ||
      compact.contains('response') ||
      compact.contains('communicat');
  if (!mentionsPreference || !mentionsCommunication) return null;
  return 'user_preference:language:$language';
}

String _jsonObjectText(String raw) {
  final trimmed = raw.trim();
  if (trimmed.startsWith('{') && trimmed.endsWith('}')) {
    return trimmed;
  }
  final start = trimmed.indexOf('{');
  final end = trimmed.lastIndexOf('}');
  if (start < 0 || end <= start) {
    throw const FormatException('Maintenance response missing JSON.');
  }
  return trimmed.substring(start, end + 1);
}

double _tokenOverlapScore(String left, String right) {
  final leftTokens = _tokens(left);
  final rightTokens = _tokens(right);
  final minLength = leftTokens.length < rightTokens.length
      ? leftTokens.length
      : rightTokens.length;
  if (minLength == 0) return 0;
  final matches = leftTokens
      .where((token) => rightTokens.contains(token))
      .length;
  return matches / minLength;
}

Set<String> _tokens(String value) {
  final normalized = value.toLowerCase().replaceAll(
    RegExp(r'[^a-z0-9\u4e00-\u9fff]+'),
    ' ',
  );
  final tokens = normalized
      .split(RegExp(r'\s+'))
      .map((token) => token.trim())
      .where((token) => token.length >= 2)
      .toSet();
  for (final match in RegExp(r'[\u4e00-\u9fff]+').allMatches(normalized)) {
    final chars = match
        .group(0)!
        .runes
        .map(String.fromCharCode)
        .toList(growable: false);
    for (var index = 0; index < chars.length - 1; index += 1) {
      tokens.add('${chars[index]}${chars[index + 1]}');
    }
  }
  return tokens;
}
