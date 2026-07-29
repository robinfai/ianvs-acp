import 'dart:convert';

class ExtractedMemoryEntity {
  const ExtractedMemoryEntity({required this.text, this.type = 'entity'});

  final String text;
  final String type;

  Map<String, Object?> toJson() => <String, Object?>{
    'text': text,
    'type': type,
  };

  factory ExtractedMemoryEntity.fromJson(Object? raw) {
    if (raw is! Map) {
      throw const FormatException('Memory entity must be an object.');
    }
    return ExtractedMemoryEntity(
      text: raw['text'] as String? ?? '',
      type: raw['type'] as String? ?? 'entity',
    );
  }
}

class ExtractedTaskEpisode {
  const ExtractedTaskEpisode({
    required this.goal,
    this.constraints = const <String>[],
    this.toolsUsed = const <String>[],
    this.mistake,
    required this.successfulPattern,
  });

  final String goal;
  final List<String> constraints;
  final List<String> toolsUsed;
  final String? mistake;
  final String successfulPattern;

  bool get isValid =>
      goal.trim().isNotEmpty && successfulPattern.trim().isNotEmpty;

  Map<String, Object?> toJson() => <String, Object?>{
    'goal': goal,
    if (constraints.isNotEmpty) 'constraints': constraints,
    if (toolsUsed.isNotEmpty) 'toolsUsed': toolsUsed,
    if (mistake != null) 'mistake': mistake,
    'successfulPattern': successfulPattern,
  };

  factory ExtractedTaskEpisode.fromJson(Object? raw) {
    if (raw is! Map) {
      throw const FormatException('Task episode must be an object.');
    }
    return ExtractedTaskEpisode(
      goal: raw['goal'] as String? ?? '',
      constraints: _stringList(raw['constraints']),
      toolsUsed: _stringList(raw['toolsUsed'] ?? raw['tools_used']),
      mistake: raw['mistake'] as String?,
      successfulPattern:
          raw['successfulPattern'] as String? ??
          raw['successful_pattern'] as String? ??
          '',
    );
  }
}

class ExtractedMemoryCandidate {
  const ExtractedMemoryCandidate({
    required this.kind,
    required this.scope,
    required this.text,
    this.confidence,
    this.reason,
    this.instructionScopes = const <String>[],
    this.entities = const <ExtractedMemoryEntity>[],
    this.episode,
  });

  final String kind;
  final String scope;
  final String text;
  final double? confidence;
  final String? reason;
  final List<String> instructionScopes;
  final List<ExtractedMemoryEntity> entities;
  final ExtractedTaskEpisode? episode;

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind,
    'scope': scope,
    'text': text,
    if (confidence != null) 'confidence': confidence,
    if (reason != null) 'reason': reason,
    if (instructionScopes.isNotEmpty) 'instructionScopes': instructionScopes,
    if (entities.isNotEmpty)
      'entities': entities.map((entity) => entity.toJson()).toList(),
    if (episode != null) 'episode': episode!.toJson(),
  };

  factory ExtractedMemoryCandidate.fromJson(Object? raw) {
    if (raw is! Map) {
      throw const FormatException('Memory candidate must be an object.');
    }
    final entities = raw['entities'];
    final episode = raw['episode'];
    return ExtractedMemoryCandidate(
      kind: raw['kind'] as String? ?? '',
      scope: raw['scope'] as String? ?? '',
      text: raw['text'] as String? ?? '',
      confidence: (raw['confidence'] as num?)?.toDouble(),
      reason: raw['reason'] as String?,
      instructionScopes: _stringList(
        raw['instructionScopes'] ?? raw['instruction_scopes'],
      ),
      entities: entities is List
          ? entities
                .map(ExtractedMemoryEntity.fromJson)
                .where((entity) => entity.text.trim().isNotEmpty)
                .toList(growable: false)
          : const <ExtractedMemoryEntity>[],
      episode: episode is Map ? ExtractedTaskEpisode.fromJson(episode) : null,
    );
  }
}

String buildMemoryExtractionPrompt({
  required String userPrompt,
  required String assistantAnswer,
  String globalInstructions = '',
  String workspaceInstructions = '',
  String repoInstructions = '',
}) {
  final customInstructions = _customInstructionsBlock(
    globalInstructions: globalInstructions,
    workspaceInstructions: workspaceInstructions,
    repoInstructions: repoInstructions,
  );
  return '''
You are a memory extraction engine for a local AI agent client.
Extract only durable, useful memories from the current turn.
Allowed memory kinds:
1. user_preference
2. project_rule
3. architecture_decision
4. session_summary
5. task_episode
Do not extract secrets, temporary one-off instructions, unverified assumptions, long code snippets, or error logs.
If the user says something is only for this answer, turn, message, or request, return no candidate for it.
If the user says something is for this session, conversation, or chat, use kind "session_summary" and scope "session".
Treat clear self-introductions such as "我叫 Rodriguez", "我是 Rodriguez", "my name is Rodriguez", or "I'm Rodriguez" as durable user_preference memories unless the user marks them as one-off or session-only.
Treat clear preference statements such as "我偏好中文回复", "请始终用中文回复", "I prefer concise answers", "By default, reply in Chinese", or "Please reply in Chinese from now on" as user_preference memories unless the user marks them as one-off or session-only.
Treat clear project directives such as "本项目禁止使用 nc", "以后这个项目不要用 nc", or "In this repo, never use netcat" as project_rule memories, and clear architecture decision statements such as "架构决定..." or "Architecture decision: ..." as architecture_decision memories.
Use task_episode only when this turn contains a completed, reusable task outcome with concrete evidence. Store the goal, important constraints, tools used, a mistake to avoid when present, and the successful pattern. Prefer repo scope when the experience is project-specific, otherwise workspace scope. Do not create task episodes for routine chat, unverified attempts, or generic advice, and return at most one task_episode candidate per turn.
Return JSON only.
Schema:
{"candidates":[{"kind":"user_preference | project_rule | architecture_decision | session_summary | task_episode","scope":"global | workspace | repo | session","text":"Clear, concise memory summary.","confidence":0.0,"reason":"Short reason why this is durable and useful.","instructionScopes":["global | workspace | repo"],"entities":[{"text":"Named person, project, tool, identifier, short alias, or tag.","type":"person | project | tool | identifier | tag | entity"}],"episode":{"goal":"Completed task goal; required for task_episode only.","constraints":["Important constraint."],"toolsUsed":["Tool or verification command."],"mistake":"Optional mistake to avoid.","successfulPattern":"Reusable sequence that succeeded; required for task_episode only."}}]}
Use instructionScopes only when a custom memory instruction influenced this candidate.
$customInstructions

User prompt:
$userPrompt

Assistant answer:
$assistantAnswer
''';
}

String _customInstructionsBlock({
  required String globalInstructions,
  required String workspaceInstructions,
  required String repoInstructions,
}) {
  final lines = <String>[];
  void add(String scope, String value) {
    final trimmed = value.trim();
    if (trimmed.isNotEmpty) lines.add('[$scope] $trimmed');
  }

  add('global', globalInstructions);
  add('workspace', workspaceInstructions);
  add('repo', repoInstructions);
  if (lines.isEmpty) return '';
  return '''

Custom memory instructions:
${lines.join('\n')}
''';
}

List<String> _stringList(Object? raw) {
  if (raw is! List) return const <String>[];
  final values = <String>[];
  for (final item in raw) {
    if (item is! String) continue;
    final value = item.trim();
    if (value.isEmpty || values.contains(value)) continue;
    values.add(value);
  }
  return List.unmodifiable(values);
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
  final parsed = candidates
      .map(ExtractedMemoryCandidate.fromJson)
      .where((candidate) {
        return candidate.kind.trim().isNotEmpty &&
            candidate.scope.trim().isNotEmpty &&
            candidate.text.trim().isNotEmpty &&
            (candidate.kind.trim().toLowerCase() != 'task_episode' ||
                candidate.episode?.isValid == true);
      })
      .toList(growable: false);
  return normalizeExtractedMemoryCandidates(parsed);
}

List<ExtractedMemoryCandidate> normalizeExtractedMemoryCandidates(
  List<ExtractedMemoryCandidate> candidates,
) {
  if (candidates.isEmpty) return const <ExtractedMemoryCandidate>[];
  final normalized = <ExtractedMemoryCandidate>[];
  for (final candidate in candidates) {
    if (candidate.kind.trim().toLowerCase() == 'task_episode' &&
        !_validTaskEpisode(candidate.episode)) {
      continue;
    }
    final lifetime = _memoryLifetime(candidate.text);
    if (lifetime == _MemoryLifetime.oneOff) continue;
    if (lifetime == _MemoryLifetime.session) {
      final text = _stripMemoryLifetimeMarkers(
        _trimTrailingSentencePunctuation(candidate.text),
      );
      if (text.isEmpty || _looksLikeSecret(text)) continue;
      normalized.add(
        ExtractedMemoryCandidate(
          kind: 'session_summary',
          scope: 'session',
          text: text,
          confidence: _sessionScopedConfidence(candidate.confidence),
          reason: candidate.reason,
          instructionScopes: candidate.instructionScopes,
          entities: candidate.entities,
        ),
      );
      continue;
    }
    final text = candidate.text.trim();
    if (text.isEmpty || _looksLikeSecret(text)) continue;
    if (text == candidate.text) {
      normalized.add(candidate);
    } else {
      normalized.add(
        ExtractedMemoryCandidate(
          kind: candidate.kind,
          scope: candidate.scope,
          text: text,
          confidence: candidate.confidence,
          reason: candidate.reason,
          instructionScopes: candidate.instructionScopes,
          entities: candidate.entities,
          episode: candidate.episode,
        ),
      );
    }
  }
  return List.unmodifiable(normalized);
}

double _sessionScopedConfidence(double? confidence) {
  final value = confidence ?? 0.8;
  return value > 0.8 ? 0.8 : value;
}

List<ExtractedMemoryCandidate> explicitMemoryFallbackCandidates({
  required String userPrompt,
  required String assistantAnswer,
}) {
  final rawText = _explicitMemoryText(userPrompt);
  if (rawText == null) {
    return const <ExtractedMemoryCandidate>[];
  }
  final lifetime = _memoryLifetime('$userPrompt\n$rawText');
  if (lifetime == _MemoryLifetime.oneOff) {
    return const <ExtractedMemoryCandidate>[];
  }
  final text = _stripMemoryLifetimeMarkers(rawText);
  if (text.isEmpty || _looksLikeSecret(text)) {
    return const <ExtractedMemoryCandidate>[];
  }
  final kind = lifetime == _MemoryLifetime.session
      ? 'session_summary'
      : _explicitMemoryKind(text);
  final scope = lifetime == _MemoryLifetime.session
      ? 'session'
      : _explicitMemoryScope(kind, text);
  return <ExtractedMemoryCandidate>[
    ExtractedMemoryCandidate(
      kind: kind,
      scope: scope,
      text: text,
      confidence: lifetime == _MemoryLifetime.session ? 0.8 : 0.9,
      reason: lifetime == _MemoryLifetime.session
          ? 'User explicitly asked to remember this for the current session.'
          : 'User explicitly asked to remember this.',
      entities: _fallbackEntities(text, kind),
    ),
  ];
}

List<ExtractedMemoryCandidate> localMemoryFallbackCandidates({
  required String userPrompt,
  required String assistantAnswer,
}) {
  final explicit = explicitMemoryFallbackCandidates(
    userPrompt: userPrompt,
    assistantAnswer: assistantAnswer,
  );
  final preferredName = _preferredNameFromPrompt(userPrompt);
  if (preferredName == null || _looksLikeSecret(preferredName)) {
    final introducedName = _introducedNameFromPrompt(userPrompt);
    if (introducedName == null || _looksLikeSecret(introducedName)) {
      final preference = _durablePreferenceFromPrompt(userPrompt);
      if (preference == null || _looksLikeSecret(preference)) {
        final scopedMemory = _projectScopedFallbackCandidates(userPrompt);
        if (scopedMemory.isEmpty) return explicit;
        if (explicit.isNotEmpty) return explicit;
        return scopedMemory;
      }
      if (explicit.isNotEmpty) return explicit;
      return _durablePreferenceCandidates(
        userPrompt: userPrompt,
        preference: preference,
      );
    }
    if (explicit.isNotEmpty) return explicit;
    return _introducedNameCandidates(
      userPrompt: userPrompt,
      introducedName: introducedName,
    );
  }
  final lifetime = _memoryLifetime(userPrompt);
  if (lifetime == _MemoryLifetime.oneOff) {
    return explicit;
  }
  final isChinesePrompt = RegExp(r'[\u4e00-\u9fff]').hasMatch(userPrompt);
  if (lifetime == _MemoryLifetime.session) {
    final text = isChinesePrompt
        ? '本次会话称呼用户为 $preferredName'
        : 'For this session, call the user $preferredName';
    return <ExtractedMemoryCandidate>[
      ...explicit,
      ExtractedMemoryCandidate(
        kind: 'session_summary',
        scope: 'session',
        text: text,
        confidence: 0.8,
        reason: 'User asked to use this name for the current session.',
        entities: <ExtractedMemoryEntity>[
          ExtractedMemoryEntity(text: preferredName, type: 'person'),
        ],
      ),
    ];
  }
  final text = isChinesePrompt
      ? '用户希望被称呼为 $preferredName'
      : 'User prefers to be called $preferredName';
  return <ExtractedMemoryCandidate>[
    ...explicit,
    ExtractedMemoryCandidate(
      kind: 'user_preference',
      scope: 'global',
      text: text,
      confidence: 0.9,
      reason: 'User stated a preferred name.',
      entities: <ExtractedMemoryEntity>[
        ExtractedMemoryEntity(text: preferredName, type: 'person'),
      ],
    ),
  ];
}

List<ExtractedMemoryCandidate> _introducedNameCandidates({
  required String userPrompt,
  required String introducedName,
}) {
  final lifetime = _memoryLifetime(userPrompt);
  if (lifetime == _MemoryLifetime.oneOff) {
    return const <ExtractedMemoryCandidate>[];
  }
  final isChinesePrompt = RegExp(r'[\u4e00-\u9fff]').hasMatch(userPrompt);
  if (lifetime == _MemoryLifetime.session) {
    final text = isChinesePrompt
        ? '本次会话用户名字是 $introducedName'
        : "For this session, the user's name is $introducedName";
    return <ExtractedMemoryCandidate>[
      ExtractedMemoryCandidate(
        kind: 'session_summary',
        scope: 'session',
        text: text,
        confidence: 0.8,
        reason: 'User introduced their name for the current session.',
        entities: <ExtractedMemoryEntity>[
          ExtractedMemoryEntity(text: introducedName, type: 'person'),
        ],
      ),
    ];
  }
  final text = isChinesePrompt
      ? '用户名字是 $introducedName'
      : "User's name is $introducedName";
  return <ExtractedMemoryCandidate>[
    ExtractedMemoryCandidate(
      kind: 'user_preference',
      scope: 'global',
      text: text,
      confidence: 0.9,
      reason: 'User introduced their name.',
      entities: <ExtractedMemoryEntity>[
        ExtractedMemoryEntity(text: introducedName, type: 'person'),
      ],
    ),
  ];
}

List<ExtractedMemoryCandidate> _durablePreferenceCandidates({
  required String userPrompt,
  required String preference,
}) {
  final lifetime = _memoryLifetime(userPrompt);
  if (lifetime == _MemoryLifetime.oneOff) {
    return const <ExtractedMemoryCandidate>[];
  }
  final isChinesePrompt = RegExp(r'[\u4e00-\u9fff]').hasMatch(userPrompt);
  if (lifetime == _MemoryLifetime.session) {
    final text = isChinesePrompt
        ? '本次会话用户偏好$preference'
        : 'For this session, the user prefers $preference';
    return <ExtractedMemoryCandidate>[
      ExtractedMemoryCandidate(
        kind: 'session_summary',
        scope: 'session',
        text: text,
        confidence: 0.8,
        reason: 'User stated a preference for the current session.',
        entities: _preferenceEntities(preference),
      ),
    ];
  }
  final text = isChinesePrompt ? '用户偏好$preference' : 'User prefers $preference';
  return <ExtractedMemoryCandidate>[
    ExtractedMemoryCandidate(
      kind: 'user_preference',
      scope: 'global',
      text: text,
      confidence: 0.9,
      reason: 'User stated a clear preference.',
      entities: _preferenceEntities(preference),
    ),
  ];
}

List<ExtractedMemoryCandidate> _projectScopedFallbackCandidates(
  String userPrompt,
) {
  final architectureDecision = _architectureDecisionFromPrompt(userPrompt);
  if (architectureDecision != null) {
    return _scopedProjectCandidate(
      userPrompt: userPrompt,
      text: architectureDecision,
      kind: 'architecture_decision',
      durableReason: 'User stated a clear architecture decision.',
      sessionReason:
          'User stated an architecture decision for the current session.',
      confidence: 0.9,
    );
  }
  final projectRule = _projectRuleFromPrompt(userPrompt);
  if (projectRule == null) return const <ExtractedMemoryCandidate>[];
  return _scopedProjectCandidate(
    userPrompt: userPrompt,
    text: projectRule,
    kind: 'project_rule',
    durableReason: 'User stated a clear project rule.',
    sessionReason: 'User stated a project rule for the current session.',
    confidence: 0.9,
  );
}

List<ExtractedMemoryCandidate> _scopedProjectCandidate({
  required String userPrompt,
  required String text,
  required String kind,
  required String durableReason,
  required String sessionReason,
  required double confidence,
}) {
  final candidateText = _stripMemoryLifetimeMarkers(text);
  if (candidateText.isEmpty || _looksLikeSecret(candidateText)) {
    return const <ExtractedMemoryCandidate>[];
  }
  final lifetime = _memoryLifetime(userPrompt);
  if (lifetime == _MemoryLifetime.oneOff) {
    return const <ExtractedMemoryCandidate>[];
  }
  if (lifetime == _MemoryLifetime.session) {
    return <ExtractedMemoryCandidate>[
      ExtractedMemoryCandidate(
        kind: 'session_summary',
        scope: 'session',
        text: candidateText,
        confidence: 0.8,
        reason: sessionReason,
        entities: _fallbackEntities(candidateText, kind),
      ),
    ];
  }
  return <ExtractedMemoryCandidate>[
    ExtractedMemoryCandidate(
      kind: kind,
      scope: 'repo',
      text: candidateText,
      confidence: confidence,
      reason: durableReason,
      entities: _fallbackEntities(candidateText, kind),
    ),
  ];
}

List<ExtractedMemoryCandidate> mergeExtractedMemoryCandidates(
  List<ExtractedMemoryCandidate> primary,
  List<ExtractedMemoryCandidate> fallback,
) {
  if (fallback.isEmpty) return primary;
  final seen = <String>{};
  final merged = <ExtractedMemoryCandidate>[];
  for (final candidate in primary) {
    final key = _candidateExactKey(candidate);
    if (!seen.add(key)) continue;
    merged.add(candidate);
  }
  for (final candidate in fallback) {
    final duplicateIndex = _duplicateCandidateIndex(candidate, merged);
    if (duplicateIndex != null) {
      merged[duplicateIndex] = _mergeDuplicateCandidate(
        merged[duplicateIndex],
        candidate,
      );
      continue;
    }
    final key = _candidateExactKey(candidate);
    if (!seen.add(key)) continue;
    merged.add(candidate);
  }
  return List.unmodifiable(merged);
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

String? _explicitMemoryText(String userPrompt) {
  final patterns = <RegExp>[
    RegExp(
      r'^\s*(?:请|帮我|麻烦)?\s*(?:记住|记一下|记下来|记录|保存|留意)(?:一下)?\s*[:：,，]?\s*(.+)$',
      caseSensitive: false,
    ),
    RegExp(
      r'^\s*(?:please\s+)?(?:remember|make\s+a\s+note)(?:\s+that)?\s*[:：,，]?\s*(.+)$',
      caseSensitive: false,
    ),
  ];
  for (final pattern in patterns) {
    final match = pattern.firstMatch(userPrompt);
    final value = match?.group(1)?.trim();
    if (value != null && value.isNotEmpty) {
      return _trimTrailingSentencePunctuation(value);
    }
  }
  return null;
}

String? _preferredNameFromPrompt(String userPrompt) {
  final patterns = <RegExp>[
    RegExp(
      r'^\s*(?:以后|之后|接下来|以后都)?\s*(?:请|麻烦)?\s*(?:叫我|称呼我|喊我)\s*[:：,，]?\s*(.+)$',
      caseSensitive: false,
    ),
    RegExp(
      r'^\s*(?:please\s+)?(?:call|address)\s+me\s+(?:as\s+)?(.+)$',
      caseSensitive: false,
    ),
  ];
  for (final pattern in patterns) {
    final match = pattern.firstMatch(userPrompt);
    final value = match?.group(1)?.trim();
    if (value == null || value.isEmpty) continue;
    final name = _stripMemoryLifetimeMarkers(
      _trimTrailingSentencePunctuation(value),
    );
    if (name.isEmpty || name.length > 80) continue;
    return name;
  }
  return null;
}

String? _introducedNameFromPrompt(String userPrompt) {
  final patterns = <RegExp>[
    RegExp(
      r'^\s*(?:你好|hi|hello)?\s*[，,]?\s*(?:我(?:的)?(?:名字|姓名)\s*(?:是|叫)|我叫|我是)\s*[:：,，]?\s*(.+)$',
      caseSensitive: false,
    ),
    RegExp(
      r"^\s*(?:hi|hello)?\s*[，,]?\s*(?:my\s+name\s+is|i\s+am|i'm)\s+(.+)$",
      caseSensitive: false,
    ),
  ];
  for (final pattern in patterns) {
    final match = pattern.firstMatch(userPrompt);
    final value = match?.group(1)?.trim();
    if (value == null || value.isEmpty) continue;
    final name = _stripMemoryLifetimeMarkers(
      _trimTrailingSentencePunctuation(value),
    );
    if (!_looksLikeIntroducedName(name)) continue;
    return name;
  }
  return null;
}

String? _durablePreferenceFromPrompt(String userPrompt) {
  final patterns = <RegExp>[
    RegExp(r'^\s*我\s*(?:偏好|更喜欢|喜欢)\s*[:：,，]?\s*(.+)$', caseSensitive: false),
    RegExp(
      r'^\s*我\s*希望\s*(?:你)?\s*(?:以后|之后|接下来|默认|总是|一直|始终|都|今后|从现在起|从现在开始)\s*[:：,，]?\s*(.+)$',
      caseSensitive: false,
    ),
    RegExp(
      r'^\s*(?:请|麻烦)?\s*(?:以后|之后|接下来|默认|总是|一直|始终|今后|从现在起|从现在开始|以后都)\s*(?:请|麻烦)?\s*(?:你)?\s*(.+)$',
      caseSensitive: false,
    ),
    RegExp(r'^\s*i\s+(?:prefer|like)\s+(.+)$', caseSensitive: false),
    RegExp(
      r'^\s*i\s+would\s+like\s+you\s+to\s+always\s+(.+)$',
      caseSensitive: false,
    ),
    RegExp(
      r'^\s*(?:please\s+)?(?:always|by\s+default|from\s+now\s+on)\s*[,，]?\s+(.+)$',
      caseSensitive: false,
    ),
    RegExp(
      r'^\s*(?:please\s+)?(.+?)\s+(?:from\s+now\s+on|going\s+forward|by\s+default)\s*[.!?。！？]?\s*$',
      caseSensitive: false,
    ),
  ];
  for (final pattern in patterns) {
    final match = pattern.firstMatch(userPrompt);
    final value = match?.group(1)?.trim();
    if (value == null || value.isEmpty) continue;
    final preference = _cleanPreferenceText(
      _stripMemoryLifetimeMarkers(_trimTrailingSentencePunctuation(value)),
    );
    if (!_looksLikeDurablePreference(preference)) continue;
    return preference;
  }
  return null;
}

String? _architectureDecisionFromPrompt(String userPrompt) {
  final text = _trimTrailingSentencePunctuation(userPrompt);
  if (text.length < 6 || text.length > 240) return null;
  if (_looksLikeSecret(text)) return null;
  final lower = text.toLowerCase();
  if (_containsAny(lower, const [
    '架构决定',
    '架构决策',
    '架构上决定',
    '技术选型',
    '决定采用',
    'adr:',
    'architecture decision',
    'architectural decision',
  ])) {
    return text;
  }
  if (_containsAny(lower, const ['架构', 'architecture']) &&
      _containsAny(lower, const [
        '决定',
        '决策',
        '采用',
        '负责',
        '使用',
        'owns',
        'owner',
        'use',
        'uses',
        'adopt',
      ])) {
    return text;
  }
  return null;
}

String? _projectRuleFromPrompt(String userPrompt) {
  final text = _trimTrailingSentencePunctuation(userPrompt);
  if (text.length < 6 || text.length > 240) return null;
  if (_looksLikeSecret(text)) return null;
  final lower = text.toLowerCase();
  final hasScope = _containsAny(lower, const [
    '本项目',
    '这个项目',
    '当前项目',
    '本仓库',
    '这个仓库',
    '当前仓库',
    '仓库里',
    '项目里',
    'this project',
    'the project',
    'this repo',
    'the repo',
    'this repository',
    'the repository',
    'this codebase',
    'the codebase',
  ]);
  if (!hasScope) return null;
  final hasDirective = _containsAny(lower, const [
    '禁止',
    '严禁',
    '不要',
    '别',
    '不能',
    '必须',
    '需要',
    '统一',
    '默认',
    '只能',
    '应该',
    '采用',
    '使用',
    '优先',
    '规则',
    'must',
    'must not',
    'should',
    'should not',
    'never',
    'always',
    'do not',
    "don't",
    'use',
    'uses',
    'prefer',
    'requires',
    'forbid',
    'forbids',
    'rule',
    'convention',
  ]);
  if (!hasDirective) return null;
  return text;
}

String _cleanPreferenceText(String value) {
  var text = value.trim();
  final prefixes = <RegExp>[
    RegExp(r'^(?:你|请你|麻烦你)\s*'),
    RegExp(r'^(?:that\s+)?you\s+', caseSensitive: false),
    RegExp(r'^(?:to\s+)', caseSensitive: false),
  ];
  for (final prefix in prefixes) {
    text = text.replaceFirst(prefix, '').trim();
  }
  return text;
}

bool _looksLikeDurablePreference(String value) {
  final preference = value.trim();
  if (preference.length < 2 || preference.length > 120) return false;
  if (_looksLikeSecret(preference)) return false;
  if (RegExp(r'[\n。！？!?]').hasMatch(preference)) return false;
  final lower = preference.toLowerCase();
  if (_containsAny(lower, const [
    '这个',
    '这次',
    '当前',
    '刚才',
    '现在',
    'this ',
    'that ',
    'these ',
    'those ',
    'current ',
    'right now',
  ])) {
    return false;
  }
  if (RegExp(r'[\u4e00-\u9fff]').hasMatch(preference)) {
    return _containsAny(lower, const [
      '中文',
      '英文',
      '回复',
      '回答',
      '简洁',
      '详细',
      '格式',
      '风格',
      '用',
      '使用',
      '不要',
      '别',
      '优先',
      '称呼',
      '名字',
    ]);
  }
  final words = RegExp(r"[A-Za-z0-9_-]+").allMatches(preference).length;
  if (words == 0 || words > 18) return false;
  return true;
}

bool _looksLikeIntroducedName(String value) {
  final name = value.trim();
  if (name.length < 2 || name.length > 80) return false;
  if (_looksLikeSecret(name)) return false;
  final lower = name.toLowerCase();
  if (_containsAny(lower, const [
    '来',
    '想',
    '需要',
    '正在',
    '只是',
    '不是',
    '一个',
    '一名',
    'a ',
    'an ',
    'here to',
    'trying to',
    'going to',
    'looking for',
  ])) {
    return false;
  }
  if (RegExp(r'[\n。！？!?]').hasMatch(name)) return false;
  final latinWords = RegExp(
    r'[A-Za-z][A-Za-z0-9_-]*',
  ).allMatches(name).map((match) => match.group(0)!).toList(growable: false);
  if (latinWords.isNotEmpty) {
    if (latinWords.length > 4) return false;
    return latinWords.any((word) => RegExp(r'[A-Z]').hasMatch(word));
  }
  if (RegExp(r'^[\u4e00-\u9fff]{2,8}$').hasMatch(name)) return true;
  if (RegExp(r'^[\u4e00-\u9fffA-Za-z0-9_-]{2,40}$').hasMatch(name)) {
    return true;
  }
  return false;
}

List<ExtractedMemoryEntity> _preferenceEntities(String preference) {
  final entities = <ExtractedMemoryEntity>[];
  final seen = <String>{};
  void add(String text) {
    final value = text.trim();
    if (value.isEmpty || !seen.add(value.toLowerCase())) return;
    entities.add(ExtractedMemoryEntity(text: value, type: 'tag'));
  }

  final lower = preference.toLowerCase();
  if (preference.contains('中文') || lower.contains('chinese')) {
    add('Chinese');
  }
  if (preference.contains('英文') || lower.contains('english')) {
    add('English');
  }
  if (preference.contains('简洁') || lower.contains('concise')) {
    add('concise');
  }
  if (preference.contains('详细') || lower.contains('detailed')) {
    add('detailed');
  }
  return List.unmodifiable(entities);
}

enum _MemoryLifetime { durable, session, oneOff }

_MemoryLifetime _memoryLifetime(String text) {
  final lower = text.toLowerCase();
  if (_containsAny(lower, const [
    'for this answer',
    'for this response',
    'for this turn',
    'for this message',
    'for this request',
    'just this once',
    'only this once',
    '这次回答',
    '本次回答',
    '这个回答',
    '本轮',
    '这一轮',
    '这一次',
    '只这次',
    '仅这次',
  ])) {
    return _MemoryLifetime.oneOff;
  }
  if (_containsAny(lower, const [
    'for this session',
    'for this conversation',
    'for this chat',
    '本次会话',
    '这个会话',
    '本次对话',
    '这次对话',
  ])) {
    return _MemoryLifetime.session;
  }
  return _MemoryLifetime.durable;
}

String _stripMemoryLifetimeMarkers(String value) {
  var text = value.trim();
  final patterns = <RegExp>[
    RegExp(
      r'^(?:for\s+this\s+(?:answer|response|turn|message|request|session|conversation|chat)\s+)(?:that\s+)?',
      caseSensitive: false,
    ),
    RegExp(
      r'\s+for\s+this\s+(?:answer|response|turn|message|request|session|conversation|chat)$',
      caseSensitive: false,
    ),
    RegExp(
      r'[\s,，、:：]*(?:这次回答|本次回答|这个回答|本轮|这一轮|这一次|只这次|仅这次|本次会话|这个会话|本次对话|这次对话)$',
      caseSensitive: false,
    ),
  ];
  for (final pattern in patterns) {
    text = text.replaceFirst(pattern, '').trim();
  }
  return text;
}

String _candidateExactKey(ExtractedMemoryCandidate candidate) {
  return '${candidate.kind.trim().toLowerCase()}|'
      '${candidate.scope.trim().toLowerCase()}|'
      '${candidate.text.trim().toLowerCase()}';
}

int? _duplicateCandidateIndex(
  ExtractedMemoryCandidate candidate,
  List<ExtractedMemoryCandidate> existing,
) {
  for (final current in existing) {
    if (_candidateExactKey(candidate) == _candidateExactKey(current)) {
      return existing.indexOf(current);
    }
    if (_samePreferredNameMemory(candidate, current)) {
      return existing.indexOf(current);
    }
    if (_sameTaggedPreferenceMemory(candidate, current)) {
      return existing.indexOf(current);
    }
    if (_sameScopedEntityMemory(candidate, current)) {
      return existing.indexOf(current);
    }
  }
  return null;
}

ExtractedMemoryCandidate _mergeDuplicateCandidate(
  ExtractedMemoryCandidate existing,
  ExtractedMemoryCandidate fallback,
) {
  final existingConfidence = existing.confidence;
  final fallbackConfidence = fallback.confidence;
  final confidence = switch ((existingConfidence, fallbackConfidence)) {
    (null, null) => null,
    (final double value, null) => value,
    (null, final double value) => value,
    (final double left, final double right) => left > right ? left : right,
  };
  return ExtractedMemoryCandidate(
    kind: existing.kind,
    scope: existing.scope,
    text: existing.text,
    confidence: confidence,
    reason: existing.reason ?? fallback.reason,
    instructionScopes: _mergeStrings(
      existing.instructionScopes,
      fallback.instructionScopes,
    ),
    entities: _mergeEntities(existing.entities, fallback.entities),
    episode: existing.episode ?? fallback.episode,
  );
}

bool _validTaskEpisode(ExtractedTaskEpisode? episode) {
  if (episode == null || !episode.isValid) return false;
  final values = <String>[
    episode.goal,
    episode.successfulPattern,
    ...episode.constraints,
    ...episode.toolsUsed,
    ?episode.mistake,
  ];
  return !values.any(_looksLikeSecret);
}

List<String> _mergeStrings(List<String> primary, List<String> fallback) {
  if (fallback.isEmpty) return primary;
  final values = <String>[];
  final seen = <String>{};
  for (final value in <String>[...primary, ...fallback]) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) continue;
    if (!seen.add(trimmed.toLowerCase())) continue;
    values.add(trimmed);
  }
  return List.unmodifiable(values);
}

List<ExtractedMemoryEntity> _mergeEntities(
  List<ExtractedMemoryEntity> primary,
  List<ExtractedMemoryEntity> fallback,
) {
  if (fallback.isEmpty) return primary;
  final values = <ExtractedMemoryEntity>[];
  final seen = <String>{};
  for (final entity in <ExtractedMemoryEntity>[...primary, ...fallback]) {
    final text = entity.text.trim();
    if (text.isEmpty) continue;
    final type = entity.type.trim().toLowerCase();
    final key = '$type|${text.toLowerCase()}';
    if (!seen.add(key)) continue;
    values.add(ExtractedMemoryEntity(text: text, type: entity.type));
  }
  return List.unmodifiable(values);
}

bool _samePreferredNameMemory(
  ExtractedMemoryCandidate left,
  ExtractedMemoryCandidate right,
) {
  if (left.kind.trim().toLowerCase() != 'user_preference' ||
      right.kind.trim().toLowerCase() != 'user_preference') {
    return false;
  }
  if (left.scope.trim().toLowerCase() != right.scope.trim().toLowerCase()) {
    return false;
  }
  if (!_looksLikePreferredNameMemory(left.text) ||
      !_looksLikePreferredNameMemory(right.text)) {
    return false;
  }
  final leftNames = _personEntityNames(left);
  final rightNames = _personEntityNames(right);
  if (leftNames.isEmpty || rightNames.isEmpty) return false;
  return leftNames.any(rightNames.contains);
}

bool _sameTaggedPreferenceMemory(
  ExtractedMemoryCandidate left,
  ExtractedMemoryCandidate right,
) {
  if (left.kind.trim().toLowerCase() != 'user_preference' ||
      right.kind.trim().toLowerCase() != 'user_preference') {
    return false;
  }
  if (left.scope.trim().toLowerCase() != right.scope.trim().toLowerCase()) {
    return false;
  }
  if (_looksLikePreferredNameMemory(left.text) ||
      _looksLikePreferredNameMemory(right.text)) {
    return false;
  }
  if (!_looksLikePreferenceMemory(left.text) ||
      !_looksLikePreferenceMemory(right.text)) {
    return false;
  }
  final leftTags = _preferenceMemoryTags(left);
  final rightTags = _preferenceMemoryTags(right);
  if (leftTags.isEmpty || rightTags.isEmpty) return false;
  return leftTags.any(rightTags.contains);
}

bool _sameScopedEntityMemory(
  ExtractedMemoryCandidate left,
  ExtractedMemoryCandidate right,
) {
  final kind = left.kind.trim().toLowerCase();
  if (kind != right.kind.trim().toLowerCase()) return false;
  if (kind != 'project_rule' && kind != 'architecture_decision') {
    return false;
  }
  if (left.scope.trim().toLowerCase() != right.scope.trim().toLowerCase()) {
    return false;
  }
  final leftEntities = _scopedMemoryEntityKeys(left);
  final rightEntities = _scopedMemoryEntityKeys(right);
  if (leftEntities.isEmpty || rightEntities.isEmpty) return false;
  return leftEntities.any(rightEntities.contains);
}

Set<String> _scopedMemoryEntityKeys(ExtractedMemoryCandidate candidate) {
  final values = <String>{};
  for (final entity in candidate.entities) {
    final type = entity.type.trim().toLowerCase();
    if (type == 'person') continue;
    final value = _normalizedEntityKey(entity.text);
    if (value.length < 2) continue;
    values.add(value);
  }
  return values;
}

String _normalizedEntityKey(String value) {
  var text = value.trim().toLowerCase();
  text = text.replaceAll(RegExp(r'^[\s,，。.:：;；!?！？`]+'), '');
  text = text.replaceAll(RegExp(r'[\s,，。.:：;；!?！？`]+$'), '');
  return text;
}

bool _looksLikePreferredNameMemory(String text) {
  final lower = text.toLowerCase();
  return _containsAny(lower, const [
    '称呼',
    '名字',
    '叫',
    '喊',
    'called',
    'call me',
    'name is',
    'prefers to be called',
    'preferred name',
  ]);
}

bool _looksLikePreferenceMemory(String text) {
  final lower = text.toLowerCase();
  return _containsAny(lower, const [
    '偏好',
    '喜欢',
    '希望',
    '默认',
    '回复',
    '回答',
    '风格',
    '格式',
    'prefer',
    'prefers',
    'preference',
    'by default',
    'reply',
    'answer',
    'concise',
    'detailed',
    'chinese',
    'english',
  ]);
}

Set<String> _preferenceMemoryTags(ExtractedMemoryCandidate candidate) {
  final tags = <String>{};
  for (final entity in candidate.entities) {
    final value = entity.text.trim().toLowerCase();
    if (value.isEmpty) continue;
    final type = entity.type.trim().toLowerCase();
    if (type == 'person') continue;
    tags.add(value);
  }
  tags.addAll(_derivedPreferenceTags(candidate.text));
  return tags;
}

Set<String> _derivedPreferenceTags(String text) {
  final lower = text.toLowerCase();
  final tags = <String>{};
  if (text.contains('中文') || lower.contains('chinese')) tags.add('chinese');
  if (text.contains('英文') || lower.contains('english')) tags.add('english');
  if (text.contains('简洁') || lower.contains('concise')) tags.add('concise');
  if (text.contains('详细') || lower.contains('detailed')) tags.add('detailed');
  return tags;
}

Set<String> _personEntityNames(ExtractedMemoryCandidate candidate) {
  final names = <String>{};
  for (final entity in candidate.entities) {
    final value = entity.text.trim().toLowerCase();
    if (value.isEmpty) continue;
    final type = entity.type.trim().toLowerCase();
    if (type == 'person' || type == 'entity') names.add(value);
  }
  if (names.isNotEmpty) return names;
  for (final match in RegExp(
    r'\b[A-Z][A-Za-z0-9_-]{1,}\b',
  ).allMatches(candidate.text)) {
    final value = match.group(0)?.trim().toLowerCase();
    if (value != null && value.isNotEmpty) names.add(value);
  }
  return names;
}

String _trimTrailingSentencePunctuation(String value) {
  var trimmed = value.trim();
  while (trimmed.endsWith('。') ||
      trimmed.endsWith('.') ||
      trimmed.endsWith('！') ||
      trimmed.endsWith('!')) {
    trimmed = trimmed.substring(0, trimmed.length - 1).trim();
  }
  return trimmed;
}

bool _looksLikeSecret(String text) {
  final lower = text.toLowerCase();
  const markers = <String>[
    'api key',
    'apikey',
    'access key',
    'secret',
    'token',
    'bearer',
    'password',
    'passwd',
    '密码',
    '密钥',
    '私钥',
    '口令',
  ];
  if (markers.any(lower.contains)) return true;
  return RegExp(r'\bsk-[a-z0-9_-]{6,}\b', caseSensitive: false).hasMatch(text);
}

String _explicitMemoryKind(String text) {
  final lower = text.toLowerCase();
  if (_containsAny(lower, const [
    'architecture',
    'architectural',
    'adr',
    'decision',
    '架构',
    '决策',
    '决定采用',
    '技术选型',
  ])) {
    return 'architecture_decision';
  }
  if (_containsAny(lower, const [
    '本项目',
    '这个项目',
    '本仓库',
    '仓库',
    '验证暗号',
    '验证码',
    '验证短语',
    '暗号',
    'repo',
    'repository',
    'project',
    'verification phrase',
    'passphrase',
    'release phrase',
    '规则',
  ])) {
    return 'project_rule';
  }
  if (_containsAny(lower, const ['会话', 'session', '本次对话'])) {
    return 'session_summary';
  }
  if (_containsAny(lower, const [
    '我',
    '我的',
    '称呼',
    '名字',
    'call me',
    'my ',
    'i am ',
    "i'm ",
  ])) {
    return 'user_preference';
  }
  return 'session_summary';
}

String _explicitMemoryScope(String kind, String text) {
  return switch (kind) {
    'user_preference' => 'global',
    'project_rule' || 'architecture_decision' => 'repo',
    _ => 'session',
  };
}

List<ExtractedMemoryEntity> _fallbackEntities(String text, String kind) {
  final values = <String>{};
  final entities = <ExtractedMemoryEntity>[];
  final type = kind == 'user_preference' ? 'person' : 'identifier';
  void addEntity(String? raw, String entityType) {
    final value = raw?.trim();
    if (value == null || value.length < 2 || value.length > 80) return;
    if (_looksLikeSecret(value)) return;
    final key = value.toLowerCase();
    if (!values.add(key)) return;
    entities.add(ExtractedMemoryEntity(text: value, type: entityType));
  }

  for (final match in RegExp(r'\b[A-Z][A-Za-z0-9_-]{1,}\b').allMatches(text)) {
    addEntity(match.group(0), type);
  }
  if (kind != 'user_preference') {
    for (final pattern in <RegExp>[
      RegExp(r'(?:是|为|叫做|设为|设置为)\s*[:：]?\s*([^，。；;,.!?！？\n]{2,80})'),
      RegExp(
        r'(?:使用|采用|禁用|禁止使用|严禁使用|不要使用|必须使用|优先使用)\s*([^，。；;,.!?！？\n]{2,80})',
      ),
      RegExp(
        r'(?:用|禁用|别用|不要用|不能用|必须用|需要用|统一用|默认用|只能用|应该用|优先用)\s*([^，。；;,.!?！？\n]{2,80})',
      ),
      RegExp(r'\b(?:is|as|to)\s+([^.;,!?\n]{2,80})', caseSensitive: false),
      RegExp(
        r'\b(?:use|using|avoid|forbid|prefer|requires?|adopt)\s+([^.;,!?\n]{2,80})',
        caseSensitive: false,
      ),
    ]) {
      for (final match in pattern.allMatches(text)) {
        addEntity(match.group(1), 'identifier');
      }
    }
  }
  return List.unmodifiable(entities);
}

bool _containsAny(String text, List<String> values) {
  for (final value in values) {
    if (text.contains(value)) return true;
  }
  return false;
}
