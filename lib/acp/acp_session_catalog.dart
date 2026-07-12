import 'package:dart_acp/dart_acp.dart' as acp;

class AcpProjectSessions {
  AcpProjectSessions({required this.cwd, required this.sessions});

  final String cwd;
  final List<AcpSessionEntry> sessions;

  String get name => _lastPathSegment(cwd);

  DateTime get sortTime {
    if (sessions.isEmpty) return DateTime.fromMillisecondsSinceEpoch(0);
    return sessions.first.sortTime;
  }

  String get dropdownLabel => '$name (${sessions.length}) - $cwd';
}

class AcpSessionEntry {
  const AcpSessionEntry({
    required this.id,
    required this.cwd,
    required this.title,
    this.additionalDirectories = const <String>[],
    this.updatedAt,
    this.meta = const <String, Object?>{},
    this.metaOmission,
  });

  final String id;
  final String cwd;
  final String title;
  final List<String> additionalDirectories;
  final DateTime? updatedAt;
  final Map<String, Object?> meta;
  final acp.AcpInputOmission? metaOmission;

  String get shortId => id.length <= 8 ? id : id.substring(0, 8);

  DateTime get sortTime {
    return updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
  }

  String get dropdownLabel {
    final date = updatedAt == null ? '' : ' - ${_formatDateTime(updatedAt!)}';
    return '$title ($shortId)$date';
  }

  bool get hasMeta => meta.isNotEmpty;
}

List<AcpProjectSessions> groupAcpSessionsByProject(
  Iterable<AcpSessionEntry> sessions,
) {
  final projectsByCwd = <String, List<AcpSessionEntry>>{};
  for (final session in sessions) {
    projectsByCwd
        .putIfAbsent(session.cwd, () => <AcpSessionEntry>[])
        .add(session);
  }

  return projectsByCwd.entries.map((entry) {
    final sessions = entry.value
      ..sort((a, b) => b.sortTime.compareTo(a.sortTime));
    return AcpProjectSessions(cwd: entry.key, sessions: sessions);
  }).toList()..sort((a, b) => b.sortTime.compareTo(a.sortTime));
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
