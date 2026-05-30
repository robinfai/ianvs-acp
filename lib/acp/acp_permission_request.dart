import 'dart:convert';

enum AcpPermissionDecision { allow, deny, cancel }

enum AcpPermissionAuditStatus { pending, allowed, denied, cancelled }

enum AcpPermissionDecisionSource { manual, trustRule, system }

class AcpPermissionTrustRule {
  const AcpPermissionTrustRule({
    required this.toolName,
    required this.decision,
    this.toolKind,
  });

  final String toolName;
  final String? toolKind;
  final AcpPermissionDecision decision;

  bool matches(AcpPermissionRequest request) {
    if (request.toolName.trim() != toolName.trim()) return false;
    final kind = toolKind?.trim();
    if (kind == null || kind.isEmpty) return true;
    return request.toolKind?.trim() == kind;
  }

  String get displayDecision {
    return switch (decision) {
      AcpPermissionDecision.allow => 'Allow',
      AcpPermissionDecision.deny => 'Deny',
      AcpPermissionDecision.cancel => 'Cancel',
    };
  }
}

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

  String get allowActionLabel {
    return _permissionOptionLabel(
      options,
      fallback: 'Allow Once',
      keywords: const [
        'allow',
        'allowed',
        'approve',
        'approved',
        'accept',
        'accepted',
        'continue',
        'proceed',
      ],
      genericLabels: const ['allow', 'allow once'],
    );
  }

  String get denyActionLabel {
    return _permissionOptionLabel(
      options,
      fallback: 'Deny',
      keywords: const [
        'deny',
        'denied',
        'reject',
        'rejected',
        'decline',
        'declined',
        'block',
        'blocked',
        'disallow',
      ],
      genericLabels: const ['deny', 'reject'],
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'title': title,
      'rationale': rationale,
      'sessionId': sessionId,
      'toolName': toolName,
      if (toolKind != null) 'toolKind': toolKind,
      'options': options,
      'requestedAt': requestedAt.toUtc().toIso8601String(),
    };
  }
}

class AcpPermissionAuditEntry {
  const AcpPermissionAuditEntry({
    required this.request,
    required this.status,
    required this.recordedAt,
    this.resolvedAt,
    this.decisionSource,
  });

  final AcpPermissionRequest request;
  final AcpPermissionAuditStatus status;
  final DateTime recordedAt;
  final DateTime? resolvedAt;
  final AcpPermissionDecisionSource? decisionSource;

  AcpPermissionAuditEntry copyWith({
    AcpPermissionRequest? request,
    AcpPermissionAuditStatus? status,
    DateTime? recordedAt,
    DateTime? resolvedAt,
    AcpPermissionDecisionSource? decisionSource,
  }) {
    return AcpPermissionAuditEntry(
      request: request ?? this.request,
      status: status ?? this.status,
      recordedAt: recordedAt ?? this.recordedAt,
      resolvedAt: resolvedAt ?? this.resolvedAt,
      decisionSource: decisionSource ?? this.decisionSource,
    );
  }

  String get displayStatus {
    return switch (status) {
      AcpPermissionAuditStatus.pending => 'Pending',
      AcpPermissionAuditStatus.allowed => 'Allowed',
      AcpPermissionAuditStatus.denied => 'Denied',
      AcpPermissionAuditStatus.cancelled => 'Cancelled',
    };
  }

  String? get displayDecisionSource {
    return switch (decisionSource) {
      AcpPermissionDecisionSource.manual => 'Manual',
      AcpPermissionDecisionSource.trustRule => 'Trust rule',
      AcpPermissionDecisionSource.system => 'System',
      null => null,
    };
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'status': status.name,
      'recordedAt': recordedAt.toUtc().toIso8601String(),
      if (resolvedAt != null)
        'resolvedAt': resolvedAt!.toUtc().toIso8601String(),
      if (decisionSource != null) 'decisionSource': decisionSource!.name,
      'request': request.toJson(),
    };
  }
}

String acpPermissionAuditEntriesToJson(List<AcpPermissionAuditEntry> entries) {
  const encoder = JsonEncoder.withIndent('  ');
  return encoder.convert(<String, Object?>{
    'schema': 'ianvs-acp.permission-history.v1',
    'exportedAt': DateTime.now().toUtc().toIso8601String(),
    'entries': entries.map((entry) => entry.toJson()).toList(growable: false),
  });
}

String _permissionOptionLabel(
  List<String> options, {
  required String fallback,
  required List<String> keywords,
  required List<String> genericLabels,
}) {
  for (final option in options) {
    final label = _normalizedPermissionOption(option);
    if (label.isEmpty) continue;
    final lowerLabel = label.toLowerCase();
    if (!_containsPermissionKeyword(lowerLabel, keywords)) continue;
    if (genericLabels.contains(lowerLabel)) return fallback;
    return _truncatePermissionOptionLabel(label);
  }
  return fallback;
}

bool _containsPermissionKeyword(String lowerLabel, List<String> keywords) {
  final words = lowerLabel
      .split(RegExp(r'[^a-z0-9]+'))
      .where((word) => word.isNotEmpty);
  return words.any(keywords.contains);
}

String _normalizedPermissionOption(String value) {
  return value.trim().replaceAll(RegExp(r'\s+'), ' ');
}

String _truncatePermissionOptionLabel(String value) {
  const maxLength = 24;
  if (value.length <= maxLength) return value;
  return '${value.substring(0, maxLength - 3).trimRight()}...';
}
