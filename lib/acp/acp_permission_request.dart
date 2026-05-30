enum AcpPermissionDecision { allow, deny, cancel }

class AcpPermissionRequest {
  const AcpPermissionRequest({
    required this.id,
    required this.title,
    required this.rationale,
    required this.sessionId,
    required this.toolName,
    required this.options,
    required this.requestedAt,
    this.toolKind,
  });

  final String id;
  final String title;
  final String rationale;
  final String sessionId;
  final String toolName;
  final String? toolKind;
  final List<String> options;
  final DateTime requestedAt;

  String get displayTitle {
    final trimmed = title.trim();
    return trimmed.isEmpty ? 'Permission requested' : trimmed;
  }

  String get displayRationale {
    final trimmed = rationale.trim();
    return trimmed.isEmpty ? 'The agent is asking before continuing.' : trimmed;
  }

  String get displayKind {
    final kind = toolKind?.trim();
    if (kind != null && kind.isNotEmpty) return kind;
    final name = toolName.trim();
    return name.isEmpty ? 'operation' : name;
  }
}
