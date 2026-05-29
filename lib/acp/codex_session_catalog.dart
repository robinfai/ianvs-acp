import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

class CodexSessionCatalog {
  const CodexSessionCatalog({this.codexHome});

  final String? codexHome;

  Future<List<CodexProjectSessions>> load({
    bool includeTurnCounts = true,
  }) async {
    final home = _codexHomePath();
    if (home == null) return const [];

    final index = await _readSessionIndex(File('$home/session_index.jsonl'));
    final sessionsRoot = Directory('$home/sessions');
    if (!await sessionsRoot.exists()) return const [];

    final files = await _sessionFiles(sessionsRoot, index);
    final conversations = await _readConversations(
      files,
      index,
      includeTurnCounts: includeTurnCounts,
    );

    final projectsByCwd = <String, List<CodexConversationEntry>>{};
    for (final conversation in conversations) {
      projectsByCwd
          .putIfAbsent(conversation.cwd, () => <CodexConversationEntry>[])
          .add(conversation);
    }

    final projects = projectsByCwd.entries.map((entry) {
      final conversations = entry.value
        ..sort((a, b) => b.sortTime.compareTo(a.sortTime));
      return CodexProjectSessions(cwd: entry.key, conversations: conversations);
    }).toList()..sort((a, b) => b.sortTime.compareTo(a.sortTime));

    return projects;
  }

  Future<List<CodexConversationEntry>> _readConversations(
    List<File> files,
    Map<String, _IndexEntry> index, {
    required bool includeTurnCounts,
  }) async {
    final conversations = <CodexConversationEntry>[];
    var nextIndex = 0;

    Future<void> worker() async {
      while (true) {
        final currentIndex = nextIndex;
        if (currentIndex >= files.length) return;
        nextIndex += 1;

        final CodexConversationEntry? conversation;
        try {
          conversation = await _readConversation(
            files[currentIndex],
            index,
            includeTurnCounts: includeTurnCounts,
          );
        } catch (_) {
          continue;
        }
        if (conversation != null) {
          conversations.add(conversation);
        }
      }
    }

    final workerCount = math.min(4, files.length);
    await Future.wait(List.generate(workerCount, (_) => worker()));
    return conversations;
  }

  Future<int> turnCountFor(CodexConversationEntry conversation) async {
    return Isolate.run(() => _countTurnsInSessionFile(conversation.sourcePath));
  }

  Future<List<File>> _sessionFiles(
    Directory sessionsRoot,
    Map<String, _IndexEntry> index,
  ) async {
    final indexedFiles = <File>[];
    final fallbackFiles = <_SessionFileCandidate>[];
    final includeAll = index.isEmpty;

    await for (final entity in sessionsRoot.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File || !entity.path.endsWith('.jsonl')) continue;

      final id = _sessionIdFromPath(entity.path);
      if (includeAll || (id != null && index.containsKey(id))) {
        indexedFiles.add(entity);
        continue;
      }

      final stat = await entity.stat();
      if (stat.size > 24 * 1024 * 1024) continue;
      fallbackFiles.add(_SessionFileCandidate(file: entity, stat: stat));
    }

    if (includeAll) return indexedFiles;

    fallbackFiles.sort((a, b) => b.stat.modified.compareTo(a.stat.modified));
    return [
      ...indexedFiles,
      ...fallbackFiles.take(24).map((candidate) => candidate.file),
    ];
  }

  String? _codexHomePath() {
    final configured = codexHome?.trim();
    if (configured != null && configured.isNotEmpty) return configured;
    final fromEnvironment = Platform.environment['CODEX_HOME']?.trim();
    if (fromEnvironment != null && fromEnvironment.isNotEmpty) {
      return fromEnvironment;
    }
    final home = Platform.environment['HOME']?.trim();
    if (home == null || home.isEmpty) return null;
    return '$home/.codex';
  }

  Future<Map<String, _IndexEntry>> _readSessionIndex(File file) async {
    if (!await file.exists()) return const {};

    final entries = <String, _IndexEntry>{};
    await for (final line in _lines(file)) {
      final json = _decodeJson(line);
      if (json == null) continue;
      final id = json['id'];
      if (id is! String || id.isEmpty) continue;
      entries[id] = _IndexEntry(
        id: id,
        title: _stringValue(json['thread_name']),
        updatedAt: _dateValue(json['updated_at']),
      );
    }
    return entries;
  }

  Future<CodexConversationEntry?> _readConversation(
    File file,
    Map<String, _IndexEntry> index, {
    required bool includeTurnCounts,
  }) async {
    _SessionMeta? meta;
    String? fallbackTitle;
    var turnCount = 0;
    _IndexEntry? indexed = index[_sessionIdFromPath(file.path)];

    final lines = includeTurnCounts
        ? Stream<String>.fromIterable(
            const LineSplitter().convert(await file.readAsString()),
          )
        : _lines(file);

    await for (final line in lines) {
      if (!line.contains('session_meta') &&
          !line.contains('"role":"user"') &&
          !line.contains('"role": "user"')) {
        continue;
      }

      final json = _decodeJson(line);
      if (json == null) continue;

      meta ??= _metaFromJson(json);
      if (meta != null) {
        indexed ??= index[meta.id];
      }
      final userPrompt = _userPromptFromJson(json);
      if (userPrompt != null) {
        fallbackTitle ??= userPrompt;
        turnCount += 1;
      }

      if (!includeTurnCounts &&
          meta != null &&
          (indexed?.title != null || fallbackTitle != null)) {
        break;
      }
    }

    if (meta == null) return null;
    return CodexConversationEntry(
      id: meta.id,
      cwd: meta.cwd,
      title: indexed?.title ?? fallbackTitle ?? meta.id,
      createdAt: meta.createdAt,
      updatedAt: indexed?.updatedAt ?? meta.createdAt,
      sourcePath: file.path,
      turnCount: turnCount,
      turnCountKnown: includeTurnCounts,
    );
  }

  Stream<String> _lines(File file) {
    return file
        .openRead()
        .transform(utf8.decoder)
        .transform(const LineSplitter());
  }

  Map<String, dynamic>? _decodeJson(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return null;
    try {
      final decoded = jsonDecode(trimmed);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  _SessionMeta? _metaFromJson(Map<String, dynamic> json) {
    if (json['type'] != 'session_meta') return null;
    final payload = json['payload'];
    if (payload is! Map<String, dynamic>) return null;

    final id = payload['id'];
    final cwd = payload['cwd'];
    if (id is! String || id.isEmpty || cwd is! String || cwd.isEmpty) {
      return null;
    }

    return _SessionMeta(
      id: id,
      cwd: cwd,
      createdAt:
          _dateValue(payload['timestamp']) ?? _dateValue(json['timestamp']),
    );
  }

  String? _userPromptFromJson(Map<String, dynamic> json) {
    if (json['type'] != 'response_item') return null;
    final payload = json['payload'];
    if (payload is! Map<String, dynamic>) return null;
    if (payload['type'] != 'message' || payload['role'] != 'user') {
      return null;
    }

    final content = payload['content'];
    if (content is! List) return null;
    final buffer = StringBuffer();
    for (final item in content) {
      if (item is! Map<String, dynamic>) continue;
      final text = item['text'];
      if (text is String && text.trim().isNotEmpty) {
        buffer.write(' ');
        buffer.write(text.trim());
      }
    }
    final title = _cleanTitle(buffer.toString());
    if (title == null) return null;
    if (title.startsWith('<') || title.startsWith('>>>')) return null;
    if (title.startsWith('# AGENTS.md instructions')) return null;
    if (title.startsWith('Reviewed Codex session id:')) return null;
    if (title.startsWith('The following is the Codex agent history')) {
      return null;
    }
    return title;
  }

  String? _cleanTitle(String value) {
    final cleaned = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleaned.isEmpty) return null;
    return cleaned.length <= 96 ? cleaned : '${cleaned.substring(0, 96)}...';
  }

  String? _stringValue(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  DateTime? _dateValue(Object? value) {
    if (value is! String || value.trim().isEmpty) return null;
    return DateTime.tryParse(value)?.toLocal();
  }

  String? _sessionIdFromPath(String path) {
    final match = RegExp(
      r'([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$',
    ).firstMatch(path);
    return match?.group(1);
  }
}

class CodexProjectSessions {
  CodexProjectSessions({required this.cwd, required this.conversations});

  final String cwd;
  final List<CodexConversationEntry> conversations;

  String get name => _lastPathSegment(cwd);

  DateTime get sortTime {
    if (conversations.isEmpty) return DateTime.fromMillisecondsSinceEpoch(0);
    return conversations.first.sortTime;
  }

  String get dropdownLabel => '$name (${conversations.length}) - $cwd';
}

class CodexConversationEntry {
  const CodexConversationEntry({
    required this.id,
    required this.cwd,
    required this.title,
    required this.sourcePath,
    this.createdAt,
    this.updatedAt,
    this.turnCount = 0,
    this.turnCountKnown = true,
  });

  final String id;
  final String cwd;
  final String title;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final String sourcePath;
  final int turnCount;
  final bool turnCountKnown;

  String get shortId => id.length <= 8 ? id : id.substring(0, 8);

  String get turnCountLabel => turnCountKnown
      ? '$turnCount ${turnCount == 1 ? 'turn' : 'turns'}'
      : 'counting turns';

  DateTime get sortTime {
    return updatedAt ?? createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
  }

  String get dropdownLabel {
    final date = updatedAt == null ? '' : ' - ${_formatDateTime(updatedAt!)}';
    return '$title ($shortId) - $turnCountLabel$date';
  }

  CodexConversationEntry copyWith({int? turnCount, bool? turnCountKnown}) {
    return CodexConversationEntry(
      id: id,
      cwd: cwd,
      title: title,
      createdAt: createdAt,
      updatedAt: updatedAt,
      sourcePath: sourcePath,
      turnCount: turnCount ?? this.turnCount,
      turnCountKnown: turnCountKnown ?? this.turnCountKnown,
    );
  }
}

class _IndexEntry {
  const _IndexEntry({required this.id, this.title, this.updatedAt});

  final String id;
  final String? title;
  final DateTime? updatedAt;
}

class _SessionMeta {
  const _SessionMeta({required this.id, required this.cwd, this.createdAt});

  final String id;
  final String cwd;
  final DateTime? createdAt;
}

class _SessionFileCandidate {
  const _SessionFileCandidate({required this.file, required this.stat});

  final File file;
  final FileStat stat;
}

int _countTurnsInSessionFile(String path) {
  final content = File(path).readAsStringSync();
  var turnCount = 0;
  for (final line in const LineSplitter().convert(content)) {
    if (!line.contains('"role":"user"') && !line.contains('"role": "user"')) {
      continue;
    }

    final json = _decodeSessionJson(line);
    if (json == null) continue;
    if (_userPromptTitleFromSessionJson(json) != null) {
      turnCount += 1;
    }
  }
  return turnCount;
}

Map<String, dynamic>? _decodeSessionJson(String line) {
  final trimmed = line.trim();
  if (trimmed.isEmpty) return null;
  try {
    final decoded = jsonDecode(trimmed);
    return decoded is Map<String, dynamic> ? decoded : null;
  } catch (_) {
    return null;
  }
}

String? _userPromptTitleFromSessionJson(Map<String, dynamic> json) {
  if (json['type'] != 'response_item') return null;
  final payload = json['payload'];
  if (payload is! Map<String, dynamic>) return null;
  if (payload['type'] != 'message' || payload['role'] != 'user') return null;

  final content = payload['content'];
  if (content is! List) return null;
  final buffer = StringBuffer();
  for (final item in content) {
    if (item is! Map<String, dynamic>) continue;
    final text = item['text'];
    if (text is String && text.trim().isNotEmpty) {
      buffer.write(' ');
      buffer.write(text.trim());
    }
  }
  final title = _cleanSessionTitle(buffer.toString());
  if (title == null) return null;
  if (title.startsWith('<') || title.startsWith('>>>')) return null;
  if (title.startsWith('# AGENTS.md instructions')) return null;
  if (title.startsWith('Reviewed Codex session id:')) return null;
  if (title.startsWith('The following is the Codex agent history')) {
    return null;
  }
  return title;
}

String? _cleanSessionTitle(String value) {
  final cleaned = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (cleaned.isEmpty) return null;
  return cleaned.length <= 96 ? cleaned : '${cleaned.substring(0, 96)}...';
}

String _lastPathSegment(String path) {
  final normalized = path.replaceAll(RegExp(r'/+$'), '');
  if (normalized.isEmpty || normalized == '/') return normalized;
  final index = normalized.lastIndexOf('/');
  return index == -1 ? normalized : normalized.substring(index + 1);
}

String _formatDateTime(DateTime value) {
  String two(int input) => input.toString().padLeft(2, '0');
  return '${value.year}-${two(value.month)}-${two(value.day)} '
      '${two(value.hour)}:${two(value.minute)}';
}
