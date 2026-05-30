import 'dart:convert';

enum AcpPermissionDecision { allow, deny, cancel }

enum AcpPermissionAuditStatus { pending, allowed, denied, cancelled }

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
  });

  final AcpPermissionRequest request;
  final AcpPermissionAuditStatus status;
  final DateTime recordedAt;
  final DateTime? resolvedAt;

  AcpPermissionAuditEntry copyWith({
    AcpPermissionRequest? request,
    AcpPermissionAuditStatus? status,
    DateTime? recordedAt,
    DateTime? resolvedAt,
  }) {
    return AcpPermissionAuditEntry(
      request: request ?? this.request,
      status: status ?? this.status,
      recordedAt: recordedAt ?? this.recordedAt,
      resolvedAt: resolvedAt ?? this.resolvedAt,
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

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'status': status.name,
      'recordedAt': recordedAt.toUtc().toIso8601String(),
      if (resolvedAt != null)
        'resolvedAt': resolvedAt!.toUtc().toIso8601String(),
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
