import 'dart:convert';

enum AcpPermissionDecision { allow, deny, cancel }

enum AcpPermissionAuditStatus { pending, allowed, denied, cancelled }

enum AcpPermissionDecisionSource {
  manual,
  trustRule,
  reviewAgent,
  policy,
  system,
}

enum AcpToolCallExecutionPolicy { defaultPermissions, autoReview, fullAccess }

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
    this.metadata = const <String, Object?>{},
  });

  final String id;
  final String title;
  final String rationale;
  final String sessionId;
  final String toolName;
  final String? toolKind;
  final List<String> options;
  final DateTime requestedAt;
  final Map<String, Object?> metadata;

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
      keywords: _allowPermissionKeywords,
      genericLabels: const ['allow', 'allow once'],
      negatedKeywords: _allowPermissionKeywords,
      skipNegatedKeywords: true,
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
      negatedKeywords: _allowPermissionKeywords,
      includeNegatedKeywords: true,
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
      if (metadata.isNotEmpty) 'metadata': metadata,
    };
  }
}

class AcpPermissionReviewResult {
  const AcpPermissionReviewResult({
    this.decision,
    this.risk = '',
    this.rationale = '',
    this.reviewer = '',
    this.model,
    this.details = const <String, Object?>{},
  });

  final AcpPermissionDecision? decision;
  final String risk;
  final String rationale;
  final String reviewer;
  final String? model;
  final Map<String, Object?> details;

  String get displayRisk {
    final trimmed = risk.trim();
    return trimmed.isEmpty ? 'unknown' : trimmed;
  }

  String get displayRationale {
    final trimmed = rationale.trim();
    return trimmed.isEmpty ? 'No review rationale provided.' : trimmed;
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      if (decision != null) 'decision': decision!.name,
      if (risk.trim().isNotEmpty) 'risk': risk.trim(),
      if (rationale.trim().isNotEmpty) 'rationale': rationale.trim(),
      if (reviewer.trim().isNotEmpty) 'reviewer': reviewer.trim(),
      if (model?.trim().isNotEmpty == true) 'model': model!.trim(),
      if (details.isNotEmpty) 'details': details,
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
    this.reviewResult,
  });

  final AcpPermissionRequest request;
  final AcpPermissionAuditStatus status;
  final DateTime recordedAt;
  final DateTime? resolvedAt;
  final AcpPermissionDecisionSource? decisionSource;
  final AcpPermissionReviewResult? reviewResult;

  AcpPermissionAuditEntry copyWith({
    AcpPermissionRequest? request,
    AcpPermissionAuditStatus? status,
    DateTime? recordedAt,
    DateTime? resolvedAt,
    AcpPermissionDecisionSource? decisionSource,
    AcpPermissionReviewResult? reviewResult,
  }) {
    return AcpPermissionAuditEntry(
      request: request ?? this.request,
      status: status ?? this.status,
      recordedAt: recordedAt ?? this.recordedAt,
      resolvedAt: resolvedAt ?? this.resolvedAt,
      decisionSource: decisionSource ?? this.decisionSource,
      reviewResult: reviewResult ?? this.reviewResult,
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
      AcpPermissionDecisionSource.reviewAgent => 'Review agent',
      AcpPermissionDecisionSource.policy => 'Policy',
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
      if (reviewResult != null) 'review': reviewResult!.toJson(),
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
  List<String> negatedKeywords = const <String>[],
  bool includeNegatedKeywords = false,
  bool skipNegatedKeywords = false,
}) {
  for (final option in options) {
    final label = _normalizedPermissionOption(option);
    if (label.isEmpty) continue;
    final lowerLabel = label.toLowerCase();
    final matchesKeyword = _containsPermissionKeyword(lowerLabel, keywords);
    final matchesNegatedKeyword =
        negatedKeywords.isNotEmpty &&
        _containsNegatedPermissionKeyword(lowerLabel, negatedKeywords);
    if (skipNegatedKeywords && matchesNegatedKeyword) continue;
    if (!matchesKeyword && !(includeNegatedKeywords && matchesNegatedKeyword)) {
      continue;
    }
    if (genericLabels.contains(lowerLabel)) return fallback;
    return _truncatePermissionOptionLabel(label);
  }
  return fallback;
}

bool _containsPermissionKeyword(String lowerLabel, List<String> keywords) {
  final words = _permissionWords(lowerLabel);
  return words.any(keywords.contains);
}

bool _containsNegatedPermissionKeyword(
  String lowerLabel,
  List<String> keywords,
) {
  final words = _permissionWords(lowerLabel).toList();
  final hasKeyword = words.any(keywords.contains);
  if (!hasKeyword) return false;
  return words.any(_permissionNegationWords.contains) ||
      lowerLabel.contains("don't");
}

Iterable<String> _permissionWords(String lowerLabel) {
  return lowerLabel
      .split(RegExp(r'[^a-z0-9]+'))
      .where((word) => word.isNotEmpty);
}

String _normalizedPermissionOption(String value) {
  return value.trim().replaceAll(RegExp(r'\s+'), ' ');
}

String _truncatePermissionOptionLabel(String value) {
  const maxLength = 24;
  if (value.length <= maxLength) return value;
  return '${value.substring(0, maxLength - 3).trimRight()}...';
}

const List<String> _allowPermissionKeywords = [
  'allow',
  'allowed',
  'approve',
  'approved',
  'accept',
  'accepted',
  'continue',
  'proceed',
];

const Set<String> _permissionNegationWords = {'no', 'not', 'never', 'without'};
