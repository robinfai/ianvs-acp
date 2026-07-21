import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'acp_input_budget.dart' as acp;

enum AcpPermissionDecision { allow, deny, cancel }

enum AcpPermissionInvalidationReason {
  timedOut,
  promptEnded,
  promptCancelled,
  sessionClosed,
  connectionClosed,
  disposed,
}

final class AcpPermissionInvalidation {
  const AcpPermissionInvalidation({
    required this.requestId,
    required this.lifecycleId,
    required this.sessionId,
    required this.reason,
    required this.invalidatedAt,
  });

  final String requestId;
  final String lifecycleId;
  final String sessionId;
  final AcpPermissionInvalidationReason reason;
  final DateTime invalidatedAt;
}

enum AcpPermissionAuditStatus { pending, allowed, denied, cancelled }

enum AcpPermissionDecisionSource {
  manual,
  trustRule,
  reviewAgent,
  policy,
  system,
}

enum AcpToolCallExecutionPolicy { defaultPermissions, autoReview, fullAccess }

class AcpPermissionChoice {
  const AcpPermissionChoice({
    required this.optionId,
    required this.name,
    this.kind,
  });

  final String optionId;
  final String name;
  final String? kind;

  AcpPermissionDecision? get explicitDecision {
    final normalized = kind?.trim().toLowerCase() ?? '';
    if (normalized == 'allow' ||
        normalized == 'allow_once' ||
        normalized == 'allow_always') {
      return AcpPermissionDecision.allow;
    }
    if (normalized == 'deny' ||
        normalized == 'deny_once' ||
        normalized == 'deny_always' ||
        normalized == 'reject' ||
        normalized == 'reject_once' ||
        normalized == 'reject_always') {
      return AcpPermissionDecision.deny;
    }
    return null;
  }

  AcpPermissionDecision? get decision {
    final explicit = explicitDecision;
    if (explicit != null) return explicit;
    final words = name
        .trim()
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9]+'))
        .where((word) => word.isNotEmpty)
        .toSet();
    final looksDenied =
        words.any(_denyPermissionKeywords.contains) ||
        name.toLowerCase().contains("don't allow") ||
        name.toLowerCase().contains('do not allow');
    if (looksDenied) return AcpPermissionDecision.deny;
    if (words.any(_allowPermissionKeywords.contains)) {
      return AcpPermissionDecision.allow;
    }
    return null;
  }

  bool get isSingleUse {
    final normalized = kind?.trim().toLowerCase() ?? '';
    if (normalized.isNotEmpty) {
      return normalized.endsWith('_once') ||
          normalized == 'allow' ||
          normalized == 'deny' ||
          normalized == 'reject';
    }
    final legacyText = '$optionId $name'.trim().toLowerCase();
    final words = legacyText
        .split(RegExp(r'[^a-z0-9]+'))
        .where((word) => word.isNotEmpty)
        .toSet();
    return words.contains('once') ||
        legacyText.contains('this time') ||
        legacyText.contains('one time');
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'optionId': optionId,
      'name': name,
      if (kind != null) 'kind': kind,
    };
  }
}

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
    this.lifecycleId = '',
    required this.title,
    required this.rationale,
    required this.sessionId,
    required this.toolName,
    required this.options,
    required this.requestedAt,
    this.choices = const <AcpPermissionChoice>[],
    this.toolKind,
    this.metadata = const <String, Object?>{},
    this.transientPolicyContext = const <String, Object?>{},
    this.generation = 0,
  }) : _transientPolicyContextHash = null,
       _contentFingerprintOverride = null;

  const AcpPermissionRequest._retained({
    required this.id,
    required this.lifecycleId,
    required this.title,
    required this.rationale,
    required this.sessionId,
    required this.toolName,
    required this.options,
    required this.requestedAt,
    required this.choices,
    required this.toolKind,
    required this.metadata,
    required this.transientPolicyContext,
    required this.generation,
    required this._transientPolicyContextHash,
    required this._contentFingerprintOverride,
  });

  final String id;
  final String lifecycleId;
  final String title;
  final String rationale;
  final String sessionId;
  final String toolName;
  final String? toolKind;
  final List<String> options;
  final List<AcpPermissionChoice> choices;
  final DateTime requestedAt;
  final Map<String, Object?> metadata;
  final Map<String, Object?> transientPolicyContext;
  final int generation;
  final String? _transientPolicyContextHash;
  final String? _contentFingerprintOverride;

  String get transientPolicyContextFingerprint {
    final retainedHash = _transientPolicyContextHash;
    if (retainedHash != null && retainedHash.isNotEmpty) return retainedHash;
    if (transientPolicyContext.isEmpty) return '';
    final canonical = _canonicalPermissionValue(transientPolicyContext);
    return sha256.convert(utf8.encode(jsonEncode(canonical))).toString();
  }

  String get contentFingerprint {
    final retainedFingerprint = _contentFingerprintOverride;
    if (retainedFingerprint != null && retainedFingerprint.isNotEmpty) {
      return retainedFingerprint;
    }
    final content = <String, Object?>{
      'title': title.trim(),
      'rationale': rationale.trim(),
      'sessionId': sessionId.trim(),
      'toolName': toolName.trim(),
      if (toolKind?.trim().isNotEmpty == true) 'toolKind': toolKind!.trim(),
      'options': options.map((option) => option.trim()).toList(growable: false),
      'choices': choices
          .map(
            (choice) => <String, Object?>{
              'optionId': choice.optionId.trim(),
              'name': choice.name.trim(),
              if (choice.kind?.trim().isNotEmpty == true)
                'kind': choice.kind!.trim(),
            },
          )
          .toList(growable: false),
      'metadata': _canonicalPermissionValue(metadata),
      if (transientPolicyContextFingerprint.isNotEmpty)
        'transientPolicyContextHash': transientPolicyContextFingerprint,
    };
    return sha256.convert(utf8.encode(jsonEncode(content))).toString();
  }

  String get bindingKey => lifecycleId.isEmpty
      ? '$id:$contentFingerprint:$generation'
      : '$id:$lifecycleId:$contentFingerprint:$generation';

  AcpPermissionRequest withGeneration(int value) {
    final frozen = _freezePermissionRequestCollections(
      options: options,
      choices: choices,
      metadata: metadata,
      transientPolicyContext: transientPolicyContext,
    );
    final snapshot = AcpPermissionRequest._retained(
      id: id,
      lifecycleId: lifecycleId,
      title: title,
      rationale: rationale,
      sessionId: sessionId,
      toolName: toolName,
      options: frozen.options,
      requestedAt: requestedAt,
      choices: frozen.choices,
      toolKind: toolKind,
      metadata: frozen.metadata,
      transientPolicyContext: frozen.transientPolicyContext,
      generation: value,
      transientPolicyContextHash: null,
      contentFingerprintOverride: null,
    );
    return AcpPermissionRequest._retained(
      id: id,
      lifecycleId: lifecycleId,
      title: title,
      rationale: rationale,
      sessionId: sessionId,
      toolName: toolName,
      options: frozen.options,
      requestedAt: requestedAt,
      choices: frozen.choices,
      toolKind: toolKind,
      metadata: frozen.metadata,
      transientPolicyContext: frozen.transientPolicyContext,
      generation: value,
      transientPolicyContextHash: snapshot.transientPolicyContextFingerprint,
      contentFingerprintOverride: snapshot.contentFingerprint,
    );
  }

  AcpPermissionRequest forAudit({
    Map<String, Object?>? metadata,
    String? title,
    String? rationale,
  }) {
    final source = _freezePermissionRequestCollections(
      options: options,
      choices: choices,
      metadata: this.metadata,
      transientPolicyContext: transientPolicyContext,
    );
    final sourceSnapshot = AcpPermissionRequest._retained(
      id: id,
      lifecycleId: lifecycleId,
      title: this.title,
      rationale: this.rationale,
      sessionId: sessionId,
      toolName: toolName,
      options: source.options,
      requestedAt: requestedAt,
      choices: source.choices,
      toolKind: toolKind,
      metadata: source.metadata,
      transientPolicyContext: source.transientPolicyContext,
      generation: generation,
      transientPolicyContextHash: _transientPolicyContextHash,
      contentFingerprintOverride: _contentFingerprintOverride,
    );
    final audit = _freezePermissionRequestCollections(
      options: source.options,
      choices: source.choices,
      metadata: metadata ?? source.metadata,
      transientPolicyContext: const <String, Object?>{},
    );
    return AcpPermissionRequest._retained(
      id: id,
      lifecycleId: lifecycleId,
      title: title ?? this.title,
      rationale: rationale ?? this.rationale,
      sessionId: sessionId,
      toolName: toolName,
      options: audit.options,
      requestedAt: requestedAt,
      choices: audit.choices,
      toolKind: toolKind,
      metadata: audit.metadata,
      transientPolicyContext: const <String, Object?>{},
      generation: generation,
      transientPolicyContextHash:
          sourceSnapshot.transientPolicyContextFingerprint,
      contentFingerprintOverride: sourceSnapshot.contentFingerprint,
    );
  }

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

  AcpPermissionChoice? choiceById(String optionId) {
    final target = optionId.trim();
    if (target.isEmpty) return null;
    for (final choice in choices) {
      if (choice.optionId == target) return choice;
    }
    return null;
  }

  AcpPermissionChoice? singleUseChoiceFor(AcpPermissionDecision decision) {
    if (decision == AcpPermissionDecision.cancel) return null;
    final matching = choices
        .where((choice) => choice.decision == decision && choice.isSingleUse)
        .toList(growable: false);
    return matching.length == 1 ? matching.single : null;
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
      if (choices.isNotEmpty)
        'choices': choices.map((choice) => choice.toJson()).toList(),
      'requestedAt': requestedAt.toUtc().toIso8601String(),
      if (metadata.isNotEmpty) 'metadata': metadata,
      if (generation > 0) 'generation': generation,
      if (generation > 0) 'contentFingerprint': contentFingerprint,
    };
  }
}

({
  List<String> options,
  List<AcpPermissionChoice> choices,
  Map<String, Object?> metadata,
  Map<String, Object?> transientPolicyContext,
})
_freezePermissionRequestCollections({
  required List<String> options,
  required List<AcpPermissionChoice> choices,
  required Map<String, Object?> metadata,
  required Map<String, Object?> transientPolicyContext,
}) {
  final guard = acp.AcpStructuredUpdateGuard(
    budget: const acp.AcpInputBudget(),
    resource: 'permission request snapshot',
  );

  List<String> frozenOptions() {
    try {
      final copied = guard.copyJsonValue(options, field: 'options');
      return List<String>.unmodifiable(
        (copied! as List<Object?>).cast<String>(),
      );
    } on Object {
      return const <String>[];
    }
  }

  List<AcpPermissionChoice> frozenChoices() {
    try {
      final choiceCount = guard.checkCollection(choices, field: 'choices');
      final choiceValues = <Map<String, Object?>>[];
      for (var index = 0; index < choiceCount; index += 1) {
        final choice = choices[index];
        choiceValues.add(<String, Object?>{
          'optionId': choice.optionId,
          'name': choice.name,
          if (choice.kind != null) 'kind': choice.kind,
        });
      }
      final copied =
          guard.copyJsonValue(choiceValues, field: 'choices')! as List<Object?>;
      return List<AcpPermissionChoice>.unmodifiable(
        copied.map((value) {
          final choice = value! as Map<String, Object?>;
          return AcpPermissionChoice(
            optionId: choice['optionId']! as String,
            name: choice['name']! as String,
            kind: choice['kind'] as String?,
          );
        }),
      );
    } on Object {
      return const <AcpPermissionChoice>[];
    }
  }

  Map<String, Object?> frozenMetadata(
    Map<String, Object?> value, {
    required String field,
  }) {
    try {
      return guard.copyMetadata(value, field: field);
    } on Object {
      return const <String, Object?>{};
    }
  }

  return (
    options: frozenOptions(),
    choices: frozenChoices(),
    metadata: frozenMetadata(metadata, field: 'metadata'),
    transientPolicyContext: frozenMetadata(
      transientPolicyContext,
      field: 'transient policy context',
    ),
  );
}

Object? _canonicalPermissionValue(Object? value) {
  if (value == null || value is bool || value is num) return value;
  if (value is String) return value;
  if (value is List) {
    return value.map(_canonicalPermissionValue).toList(growable: false);
  }
  if (value is Map) {
    final entries =
        value.entries
            .map((entry) => MapEntry(entry.key.toString(), entry.value))
            .toList(growable: false)
          ..sort((a, b) => a.key.compareTo(b.key));
    return <String, Object?>{
      for (final entry in entries)
        entry.key: _canonicalPermissionValue(entry.value),
    };
  }
  return value.toString();
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

const int defaultPermissionReviewResultEncodedByteLimit = 64 * 1024;
const int defaultPermissionHistoryEncodedByteLimit = 4 * 1024 * 1024;
const String _permissionReviewSizeOmissionRationale =
    'Permission review result omitted because it exceeded safety limits.';
final int minimumPermissionReviewResultEncodedByteLimit = _encodedJsonBytes(
  _permissionReviewSizeOmission().toJson(),
);

AcpPermissionReviewResult sanitizeAcpPermissionReviewResult(
  AcpPermissionReviewResult result, {
  acp.AcpInputBudget inputBudget = const acp.AcpInputBudget(),
  int maxEncodedBytes = defaultPermissionReviewResultEncodedByteLimit,
}) {
  inputBudget.validate();
  if (maxEncodedBytes < minimumPermissionReviewResultEncodedByteLimit) {
    throw ArgumentError.value(
      maxEncodedBytes,
      'maxEncodedBytes',
      'must be at least $minimumPermissionReviewResultEncodedByteLimit',
    );
  }
  try {
    final guard = acp.AcpStructuredUpdateGuard(
      budget: inputBudget,
      resource: 'permission review result',
    );
    final copied = guard.copyMetadata(result.toJson(), field: 'value');
    if (_encodedJsonBytes(copied) > maxEncodedBytes) {
      return _permissionReviewSizeOmission();
    }
    return AcpPermissionReviewResult(
      decision: result.decision,
      risk: copied['risk'] as String? ?? '',
      rationale: copied['rationale'] as String? ?? '',
      reviewer: copied['reviewer'] as String? ?? '',
      model: copied['model'] as String?,
      details:
          copied['details'] as Map<String, Object?>? ??
          const <String, Object?>{},
    );
  } on Object {
    return _permissionReviewSizeOmission();
  }
}

AcpPermissionReviewResult _permissionReviewSizeOmission() {
  return const AcpPermissionReviewResult(
    risk: 'unknown',
    rationale: _permissionReviewSizeOmissionRationale,
    reviewer: 'permission-review-safety',
    details: <String, Object?>{'omission': 'size_limit'},
  );
}

class AcpPermissionAuditEntry {
  const AcpPermissionAuditEntry({
    required this.request,
    required this.status,
    required this.recordedAt,
    this.resolvedAt,
    this.decisionSource,
    this.reviewResult,
    this.selectedOptionId,
  });

  final AcpPermissionRequest request;
  final AcpPermissionAuditStatus status;
  final DateTime recordedAt;
  final DateTime? resolvedAt;
  final AcpPermissionDecisionSource? decisionSource;
  final AcpPermissionReviewResult? reviewResult;
  final String? selectedOptionId;

  AcpPermissionAuditEntry copyWith({
    AcpPermissionRequest? request,
    AcpPermissionAuditStatus? status,
    DateTime? recordedAt,
    DateTime? resolvedAt,
    AcpPermissionDecisionSource? decisionSource,
    AcpPermissionReviewResult? reviewResult,
    String? selectedOptionId,
  }) {
    return AcpPermissionAuditEntry(
      request: request ?? this.request,
      status: status ?? this.status,
      recordedAt: recordedAt ?? this.recordedAt,
      resolvedAt: resolvedAt ?? this.resolvedAt,
      decisionSource: decisionSource ?? this.decisionSource,
      reviewResult: reviewResult ?? this.reviewResult,
      selectedOptionId: selectedOptionId ?? this.selectedOptionId,
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
      if (selectedOptionId != null) 'selectedOptionId': selectedOptionId,
      if (reviewResult != null) 'review': reviewResult!.toJson(),
      'request': request.toJson(),
    };
  }
}

int acpPermissionAuditEntryEncodedBytes(AcpPermissionAuditEntry entry) {
  return _encodedJsonBytes(entry.toJson());
}

Map<String, Object?>? _permissionAuditEntryForExport(
  AcpPermissionAuditEntry entry,
) {
  try {
    final request = entry.request;
    final guard = acp.AcpStructuredUpdateGuard(
      budget: const acp.AcpInputBudget(),
      resource: 'permission audit export entry',
    );
    guard.checkCollection(request.choices, field: 'request.choices');
    final choices = <Map<String, Object?>>[
      for (final choice in request.choices)
        <String, Object?>{
          'optionId': choice.optionId,
          'name': choice.name,
          if (choice.kind != null) 'kind': choice.kind,
        },
    ];
    final reviewResult = entry.reviewResult;
    final source = <String, Object?>{
      'status': entry.status.name,
      'recordedAt': entry.recordedAt.toUtc().toIso8601String(),
      if (entry.resolvedAt != null)
        'resolvedAt': entry.resolvedAt!.toUtc().toIso8601String(),
      if (entry.decisionSource != null)
        'decisionSource': entry.decisionSource!.name,
      if (entry.selectedOptionId != null)
        'selectedOptionId': entry.selectedOptionId,
      if (reviewResult != null)
        'review': sanitizeAcpPermissionReviewResult(reviewResult).toJson(),
      'request': <String, Object?>{
        'id': request.id,
        '_lifecycleId': request.lifecycleId,
        'title': request.title,
        'rationale': request.rationale,
        'sessionId': request.sessionId,
        'toolName': request.toolName,
        if (request.toolKind != null) 'toolKind': request.toolKind,
        'options': request.options,
        if (choices.isNotEmpty) 'choices': choices,
        'requestedAt': request.requestedAt.toUtc().toIso8601String(),
        'metadata': request.metadata,
        '_transientPolicyContext': request.transientPolicyContext,
        'generation': request.generation,
        if (request._transientPolicyContextHash != null)
          '_transientPolicyContextHash': request._transientPolicyContextHash,
        if (request._contentFingerprintOverride != null)
          '_contentFingerprintOverride': request._contentFingerprintOverride,
      },
    };
    final copied = guard.copyMetadata(source, field: 'value');
    final copiedRequest = copied['request']! as Map<String, Object?>;
    final copiedChoices =
        (copiedRequest['choices'] as List<Object?>? ?? const <Object?>[])
            .map((value) {
              final choice = value! as Map<String, Object?>;
              return AcpPermissionChoice(
                optionId: choice['optionId']! as String,
                name: choice['name']! as String,
                kind: choice['kind'] as String?,
              );
            })
            .toList(growable: false);
    final boundedRequest = AcpPermissionRequest._retained(
      id: copiedRequest['id']! as String,
      lifecycleId: copiedRequest['_lifecycleId']! as String,
      title: copiedRequest['title']! as String,
      rationale: copiedRequest['rationale']! as String,
      sessionId: copiedRequest['sessionId']! as String,
      toolName: copiedRequest['toolName']! as String,
      options: List<String>.unmodifiable(
        (copiedRequest['options']! as List<Object?>).cast<String>(),
      ),
      requestedAt: DateTime.parse(copiedRequest['requestedAt']! as String),
      choices: List<AcpPermissionChoice>.unmodifiable(copiedChoices),
      toolKind: copiedRequest['toolKind'] as String?,
      metadata: copiedRequest['metadata']! as Map<String, Object?>,
      transientPolicyContext:
          copiedRequest['_transientPolicyContext']! as Map<String, Object?>,
      generation: copiedRequest['generation']! as int,
      transientPolicyContextHash:
          copiedRequest['_transientPolicyContextHash'] as String?,
      contentFingerprintOverride:
          copiedRequest['_contentFingerprintOverride'] as String?,
    );
    return Map<String, Object?>.of(copied)
      ..['request'] = boundedRequest.toJson();
  } on Object {
    return null;
  }
}

String acpPermissionAuditEntriesToJson(
  List<AcpPermissionAuditEntry> entries, {
  int maxEncodedBytes = defaultPermissionHistoryEncodedByteLimit,
}) {
  if (maxEncodedBytes <= 0) {
    throw ArgumentError.value(
      maxEncodedBytes,
      'maxEncodedBytes',
      'must be greater than zero',
    );
  }
  const encoder = JsonEncoder.withIndent('  ');
  final exportedAt = DateTime.now().toUtc().toIso8601String();
  final retained = <Map<String, Object?>>[];
  var compactEntryBytes = 0;
  for (final entry in entries) {
    final encodedEntry = _permissionAuditEntryForExport(entry);
    if (encodedEntry == null) break;
    final entryBytes = _encodedJsonBytes(encodedEntry);
    final separatorBytes = retained.isEmpty ? 0 : 1;
    if (entryBytes + separatorBytes > maxEncodedBytes - compactEntryBytes) {
      break;
    }
    retained.add(encodedEntry);
    compactEntryBytes += entryBytes + separatorBytes;
  }
  String encode(int count) => encoder.convert(<String, Object?>{
    'schema': 'ianvs-acp.permission-history.v1',
    'exportedAt': exportedAt,
    'entries': retained.take(count).toList(growable: false),
  });

  var lower = 0;
  var upper = retained.length;
  var encoded = encode(0);
  while (lower <= upper) {
    final midpoint = lower + ((upper - lower) ~/ 2);
    final candidate = encode(midpoint);
    if (_encodedStringBytes(candidate) <= maxEncodedBytes) {
      encoded = candidate;
      lower = midpoint + 1;
    } else {
      upper = midpoint - 1;
    }
  }
  if (_encodedStringBytes(encoded) > maxEncodedBytes) {
    throw ArgumentError.value(
      maxEncodedBytes,
      'maxEncodedBytes',
      'is too small for the permission history export envelope',
    );
  }
  return encoded;
}

int _encodedJsonBytes(Object? value) => _encodedStringBytes(jsonEncode(value));

int _encodedStringBytes(String value) => utf8.encode(value).length;

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

const Set<String> _denyPermissionKeywords = {
  'deny',
  'denied',
  'reject',
  'rejected',
  'decline',
  'declined',
  'block',
  'blocked',
  'disallow',
  'disallowed',
  'no',
};

const Set<String> _permissionNegationWords = {'no', 'not', 'never', 'without'};
