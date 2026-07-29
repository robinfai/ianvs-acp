import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'memory_context_builder.dart';
import 'memory_extraction.dart';

class MemoryScopeData {
  const MemoryScopeData({
    required this.userId,
    this.workspaceId,
    this.repoId,
    this.agentId,
    this.sessionId,
  });

  final String userId;
  final String? workspaceId;
  final String? repoId;
  final String? agentId;
  final String? sessionId;

  Map<String, Object?> toJson() => <String, Object?>{
    'userId': userId,
    if (workspaceId != null) 'workspaceId': workspaceId,
    if (repoId != null) 'repoId': repoId,
    if (agentId != null) 'agentId': agentId,
    if (sessionId != null) 'sessionId': sessionId,
  };
}

class MemorySearchRequest {
  const MemorySearchRequest({
    required this.query,
    required this.scope,
    this.limit = 12,
    this.pinnedProfileLimit = 4,
    this.turnId,
    this.referenceTime,
  });

  final String query;
  final MemoryScopeData scope;
  final int limit;
  final int pinnedProfileLimit;
  final String? turnId;
  final int? referenceTime;

  Map<String, Object?> toJson() => <String, Object?>{
    'query': query,
    'scope': scope.toJson(),
    'limit': limit,
    if (pinnedProfileLimit != 4) 'pinnedProfileLimit': pinnedProfileLimit,
    if (turnId != null) 'turnId': turnId,
    if (referenceTime != null) 'referenceTime': referenceTime,
  };
}

class MemorySearchItem {
  const MemorySearchItem({
    required this.id,
    required this.kind,
    required this.scope,
    required this.text,
    required this.score,
    this.metadata,
  });

  final String id;
  final String kind;
  final String scope;
  final String text;
  final double score;
  final Map<String, Object?>? metadata;

  factory MemorySearchItem.fromJson(Object? raw) {
    if (raw is! Map) {
      throw const FormatException('Memory search item must be an object.');
    }
    final metadata = raw['metadata'];
    return MemorySearchItem(
      id: raw['id'] as String? ?? '',
      kind: raw['kind'] as String? ?? '',
      scope: raw['scope'] as String? ?? '',
      text: raw['text'] as String? ?? '',
      score: (raw['score'] as num? ?? 0).toDouble(),
      metadata: metadata is Map ? Map<String, Object?>.from(metadata) : null,
    );
  }
}

class MemoryRecord {
  const MemoryRecord({
    required this.id,
    required this.kind,
    required this.scope,
    required this.text,
    required this.userId,
    this.workspaceId,
    this.repoId,
    this.agentId,
    this.sessionId,
    required this.source,
    this.sourceSessionId,
    this.sourceTurnId,
    this.pinned = false,
    this.profileBlock,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String kind;
  final String scope;
  final String text;
  final String userId;
  final String? workspaceId;
  final String? repoId;
  final String? agentId;
  final String? sessionId;
  final String source;
  final String? sourceSessionId;
  final String? sourceTurnId;
  final bool pinned;
  final Map<String, Object?>? profileBlock;
  final String status;
  final int createdAt;
  final int updatedAt;

  factory MemoryRecord.fromJson(Object? raw) {
    if (raw is! Map) {
      throw const FormatException('Memory record must be an object.');
    }
    return MemoryRecord(
      id: raw['id'] as String? ?? '',
      kind: raw['kind'] as String? ?? '',
      scope: raw['scope'] as String? ?? '',
      text: raw['text'] as String? ?? '',
      userId: raw['userId'] as String? ?? '',
      workspaceId: raw['workspaceId'] as String?,
      repoId: raw['repoId'] as String?,
      agentId: raw['agentId'] as String?,
      sessionId: raw['sessionId'] as String?,
      source: raw['source'] as String? ?? '',
      sourceSessionId: raw['sourceSessionId'] as String?,
      sourceTurnId: raw['sourceTurnId'] as String?,
      pinned: raw['pinned'] as bool? ?? false,
      profileBlock: raw['profileBlock'] is Map
          ? Map<String, Object?>.from(raw['profileBlock'] as Map)
          : null,
      status: raw['status'] as String? ?? '',
      createdAt: raw['createdAt'] as int? ?? 0,
      updatedAt: raw['updatedAt'] as int? ?? 0,
    );
  }

  MemoryRecord copyWith({
    String? kind,
    String? scope,
    String? text,
    String? status,
  }) {
    return MemoryRecord(
      id: id,
      kind: kind ?? this.kind,
      scope: scope ?? this.scope,
      text: text ?? this.text,
      userId: userId,
      workspaceId: workspaceId,
      repoId: repoId,
      agentId: agentId,
      sessionId: sessionId,
      source: source,
      sourceSessionId: sourceSessionId,
      sourceTurnId: sourceTurnId,
      pinned: pinned,
      profileBlock: profileBlock,
      status: status ?? this.status,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }

  Map<String, Object?> toPatchJson() => <String, Object?>{
    'kind': kind,
    'scope': scope,
    'text': text,
  };
}

class MemoryCandidate {
  const MemoryCandidate({
    required this.id,
    required this.kind,
    required this.scope,
    required this.text,
    this.confidence,
    this.reason,
    this.source = '',
    this.instructionScopes = const <String>[],
    required this.status,
  });

  final String id;
  final String kind;
  final String scope;
  final String text;
  final double? confidence;
  final String? reason;
  final String source;
  final List<String> instructionScopes;
  final String status;

  factory MemoryCandidate.fromJson(Object? raw) {
    if (raw is! Map) {
      throw const FormatException('Memory candidate must be an object.');
    }
    return MemoryCandidate(
      id: raw['id'] as String? ?? '',
      kind: raw['kind'] as String? ?? '',
      scope: raw['scope'] as String? ?? '',
      text: raw['text'] as String? ?? '',
      confidence: (raw['confidence'] as num?)?.toDouble(),
      reason: raw['reason'] as String?,
      source: raw['source'] as String? ?? '',
      instructionScopes: _stringList(
        raw['instructionScopes'] ?? raw['instruction_scopes'],
      ),
      status: raw['status'] as String? ?? '',
    );
  }

  MemoryCandidate copyWith({
    String? kind,
    String? scope,
    String? text,
    double? confidence,
    String? reason,
    String? source,
    List<String>? instructionScopes,
    String? status,
  }) {
    return MemoryCandidate(
      id: id,
      kind: kind ?? this.kind,
      scope: scope ?? this.scope,
      text: text ?? this.text,
      confidence: confidence ?? this.confidence,
      reason: reason ?? this.reason,
      source: source ?? this.source,
      instructionScopes: instructionScopes ?? this.instructionScopes,
      status: status ?? this.status,
    );
  }

  Map<String, Object?> toApproveJson({String? actor}) => <String, Object?>{
    'kind': kind,
    'scope': scope,
    'text': text,
    if (actor?.trim().isNotEmpty == true) 'actor': actor!.trim(),
  };
}

class MemoryCandidateExtractionResult {
  const MemoryCandidateExtractionResult({
    required this.candidates,
    this.autoAppliedChangeRequests = 0,
  });

  final List<MemoryCandidate> candidates;
  final int autoAppliedChangeRequests;

  static const empty = MemoryCandidateExtractionResult(
    candidates: <MemoryCandidate>[],
  );

  factory MemoryCandidateExtractionResult.fromJson(Object? raw) {
    if (raw is! Map) {
      throw const FormatException(
        'Memory candidate extraction result must be an object.',
      );
    }
    final created = raw['candidates'];
    final candidates = created is List
        ? created.map(MemoryCandidate.fromJson).toList(growable: false)
        : const <MemoryCandidate>[];
    return MemoryCandidateExtractionResult(
      candidates: candidates,
      autoAppliedChangeRequests: raw['autoAppliedChangeRequests'] as int? ?? 0,
    );
  }
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

class MemoryChangeRequest {
  const MemoryChangeRequest({
    required this.id,
    required this.action,
    this.source = '',
    required this.targetMemoryIds,
    this.targetMemoryText,
    this.proposedKind,
    this.proposedScope,
    this.proposedText,
    this.reason,
    this.confidence,
    required this.status,
    required this.createdAt,
    this.reviewedAt,
  });

  final String id;
  final String action;
  final String source;
  final List<String> targetMemoryIds;
  final String? targetMemoryText;
  final String? proposedKind;
  final String? proposedScope;
  final String? proposedText;
  final String? reason;
  final double? confidence;
  final String status;
  final int createdAt;
  final int? reviewedAt;

  factory MemoryChangeRequest.fromJson(Object? raw) {
    if (raw is! Map) {
      throw const FormatException('Memory change request must be an object.');
    }
    final targetMemoryIds = raw['targetMemoryIds'];
    return MemoryChangeRequest(
      id: raw['id'] as String? ?? '',
      action: raw['action'] as String? ?? '',
      source: raw['source'] as String? ?? '',
      targetMemoryIds: targetMemoryIds is List
          ? targetMemoryIds.whereType<String>().toList(growable: false)
          : const <String>[],
      targetMemoryText: raw['targetMemoryText'] as String?,
      proposedKind: raw['proposedKind'] as String?,
      proposedScope: raw['proposedScope'] as String?,
      proposedText: raw['proposedText'] as String?,
      reason: raw['reason'] as String?,
      confidence: (raw['confidence'] as num?)?.toDouble(),
      status: raw['status'] as String? ?? '',
      createdAt: raw['createdAt'] as int? ?? 0,
      reviewedAt: raw['reviewedAt'] as int?,
    );
  }

  MemoryChangeRequest copyWith({
    String? proposedKind,
    String? proposedScope,
    String? proposedText,
    String? status,
  }) {
    return MemoryChangeRequest(
      id: id,
      action: action,
      source: source,
      targetMemoryIds: targetMemoryIds,
      targetMemoryText: targetMemoryText,
      proposedKind: proposedKind ?? this.proposedKind,
      proposedScope: proposedScope ?? this.proposedScope,
      proposedText: proposedText ?? this.proposedText,
      reason: reason,
      confidence: confidence,
      status: status ?? this.status,
      createdAt: createdAt,
      reviewedAt: reviewedAt,
    );
  }

  Map<String, Object?> toApproveJson() => <String, Object?>{
    if (proposedKind != null) 'proposedKind': proposedKind,
    if (proposedScope != null) 'proposedScope': proposedScope,
    if (proposedText != null) 'proposedText': proposedText,
  };

  Map<String, Object?> toPatchJson() => <String, Object?>{
    if (proposedKind != null) 'proposedKind': proposedKind,
    if (proposedScope != null) 'proposedScope': proposedScope,
    if (proposedText != null) 'proposedText': proposedText,
  };
}

class MaintenanceRunResult {
  const MaintenanceRunResult({
    required this.autoApplied,
    required this.needsReview,
    required this.skipped,
    this.existingAutoApprovedChangeRequests = 0,
    this.autoRejectedCandidates = 0,
    this.autoRejectedChangeRequests = 0,
    required this.changeRequests,
  });

  final int autoApplied;
  final int needsReview;
  final int skipped;
  final int existingAutoApprovedChangeRequests;
  final int autoRejectedCandidates;
  final int autoRejectedChangeRequests;
  final List<MemoryChangeRequest> changeRequests;

  int get autoCleaned => autoRejectedCandidates + autoRejectedChangeRequests;

  int get autoResolvedReviews =>
      existingAutoApprovedChangeRequests +
      autoRejectedCandidates +
      autoRejectedChangeRequests;

  factory MaintenanceRunResult.fromJson(Object? raw) {
    if (raw is! Map) {
      throw const FormatException('Maintenance result must be an object.');
    }
    final changeRequests = raw['changeRequests'];
    return MaintenanceRunResult(
      autoApplied: raw['autoApplied'] as int? ?? 0,
      needsReview: raw['needsReview'] as int? ?? 0,
      skipped: raw['skipped'] as int? ?? 0,
      existingAutoApprovedChangeRequests:
          raw['existingAutoApprovedChangeRequests'] as int? ?? 0,
      autoRejectedCandidates: raw['autoRejectedCandidates'] as int? ?? 0,
      autoRejectedChangeRequests:
          raw['autoRejectedChangeRequests'] as int? ?? 0,
      changeRequests: changeRequests is List
          ? changeRequests
                .map(MemoryChangeRequest.fromJson)
                .toList(growable: false)
          : const <MemoryChangeRequest>[],
    );
  }
}

class MemoryClearResult {
  const MemoryClearResult({
    required this.clearedMemory,
    required this.rejectedCandidates,
    required this.rejectedChangeRequests,
  });

  final int clearedMemory;
  final int rejectedCandidates;
  final int rejectedChangeRequests;

  factory MemoryClearResult.fromJson(Object? raw) {
    if (raw is! Map) {
      throw const FormatException('Memory clear result must be an object.');
    }
    return MemoryClearResult(
      clearedMemory: raw['clearedMemory'] as int? ?? 0,
      rejectedCandidates: raw['rejectedCandidates'] as int? ?? 0,
      rejectedChangeRequests: raw['rejectedChangeRequests'] as int? ?? 0,
    );
  }
}

class MemoryAuditEvent {
  const MemoryAuditEvent({
    required this.id,
    required this.actor,
    required this.action,
    this.memoryId,
    this.candidateId,
    this.changeRequestId,
    this.memoryText,
    this.candidateText,
    this.changeRequestText,
    this.payload,
    required this.createdAt,
  });

  final String id;
  final String actor;
  final String action;
  final String? memoryId;
  final String? candidateId;
  final String? changeRequestId;
  final String? memoryText;
  final String? candidateText;
  final String? changeRequestText;
  final Map<String, Object?>? payload;
  final int createdAt;

  factory MemoryAuditEvent.fromJson(Object? raw) {
    if (raw is! Map) {
      throw const FormatException('Memory audit event must be an object.');
    }
    final payload = raw['payload'];
    return MemoryAuditEvent(
      id: raw['id'] as String? ?? '',
      actor: raw['actor'] as String? ?? '',
      action: raw['action'] as String? ?? '',
      memoryId: raw['memoryId'] as String?,
      candidateId: raw['candidateId'] as String?,
      changeRequestId: raw['changeRequestId'] as String?,
      memoryText: raw['memoryText'] as String?,
      candidateText: raw['candidateText'] as String?,
      changeRequestText: raw['changeRequestText'] as String?,
      payload: payload is Map ? Map<String, Object?>.from(payload) : null,
      createdAt: raw['createdAt'] as int? ?? 0,
    );
  }
}

class MemoryApiClient {
  MemoryApiClient({
    required this.baseUrl,
    required this.token,
    this.timeout = const Duration(seconds: 2),
    HttpClient? httpClient,
  }) : _httpClient = httpClient ?? HttpClient();

  final Uri baseUrl;
  final String token;
  final Duration timeout;
  final HttpClient _httpClient;

  Future<List<MemorySearchItem>> search(MemorySearchRequest request) async {
    final response = await _postJson('/v1/memory/search', request.toJson());
    final items = response['items'];
    if (items is! List) return const <MemorySearchItem>[];
    return items.map(MemorySearchItem.fromJson).toList(growable: false);
  }

  Future<String?> searchContext(
    MemorySearchRequest request, {
    int? pinnedProfileLimit,
  }) async {
    final items = await search(request);
    if (items.isEmpty) return null;
    return MemoryContextBuilder.build(
      items
          .map(
            (item) => MemoryContextItem(
              kind: item.kind,
              scope: item.scope,
              text: item.text,
              score: item.score,
              metadata: item.metadata,
            ),
          )
          .toList(growable: false),
      pinnedProfileLimit: pinnedProfileLimit ?? request.pinnedProfileLimit,
    );
  }

  Future<void> submitFeedback({
    required String memoryId,
    required String rating,
    String? turnId,
    String? reason,
  }) async {
    final payload = <String, Object?>{'rating': rating};
    if (turnId != null) payload['turnId'] = turnId;
    if (reason != null) payload['reason'] = reason;
    await _postJson(
      '/v1/memory/${Uri.encodeComponent(memoryId)}/feedback',
      payload,
    );
  }

  Future<List<MemoryRecord>> listMemory({
    String? userId,
    String? workspaceId,
    String? repoId,
    String? agentId,
    String? sessionId,
    String? kind,
    String status = 'active',
    int? limit,
    int? offset,
  }) async {
    final query = <String, String>{};
    if (userId != null) query['userId'] = userId;
    if (workspaceId != null) query['workspaceId'] = workspaceId;
    if (repoId != null) query['repoId'] = repoId;
    if (agentId != null) query['agentId'] = agentId;
    if (sessionId != null) query['sessionId'] = sessionId;
    if (kind != null) query['kind'] = kind;
    query['status'] = status;
    if (limit != null) query['limit'] = limit.toString();
    if (offset != null) query['offset'] = offset.toString();
    final response = await _getJson('/v1/memory', query);
    final items = response['items'];
    if (items is! List) return const <MemoryRecord>[];
    return items.map(MemoryRecord.fromJson).toList(growable: false);
  }

  Future<MemoryRecord> updateMemory(MemoryRecord record) async {
    final response = await _patchJson(
      '/v1/memory/${Uri.encodeComponent(record.id)}',
      record.toPatchJson(),
    );
    return MemoryRecord.fromJson(response);
  }

  Future<MemoryRecord> disableMemory(String id) async {
    final response = await _patchJson(
      '/v1/memory/${Uri.encodeComponent(id)}',
      const <String, Object?>{'status': 'disabled'},
    );
    return MemoryRecord.fromJson(response);
  }

  Future<MemoryRecord> restoreMemory(String id) async {
    final response = await _patchJson(
      '/v1/memory/${Uri.encodeComponent(id)}',
      const <String, Object?>{'status': 'active'},
    );
    return MemoryRecord.fromJson(response);
  }

  Future<List<MemoryCandidate>> listCandidates({
    String? userId,
    String? workspaceId,
    String? repoId,
    String? agentId,
    String? sessionId,
    String? status = 'pending',
    int? limit,
    int? offset,
  }) async {
    final query = <String, String>{};
    if (userId != null) query['userId'] = userId;
    if (workspaceId != null) query['workspaceId'] = workspaceId;
    if (repoId != null) query['repoId'] = repoId;
    if (agentId != null) query['agentId'] = agentId;
    if (sessionId != null) query['sessionId'] = sessionId;
    if (status != null) query['status'] = status;
    if (limit != null) query['limit'] = limit.toString();
    if (offset != null) query['offset'] = offset.toString();
    final response = await _getJson('/v1/memory/candidates', query);
    final candidates = response['candidates'];
    if (candidates is! List) return const <MemoryCandidate>[];
    return candidates.map(MemoryCandidate.fromJson).toList(growable: false);
  }

  Future<List<MemoryChangeRequest>> listChangeRequests({
    String? userId,
    String? workspaceId,
    String? repoId,
    String? agentId,
    String? sessionId,
    String? status = 'pending',
  }) async {
    final query = <String, String>{};
    if (userId != null) query['userId'] = userId;
    if (workspaceId != null) query['workspaceId'] = workspaceId;
    if (repoId != null) query['repoId'] = repoId;
    if (agentId != null) query['agentId'] = agentId;
    if (sessionId != null) query['sessionId'] = sessionId;
    if (status != null) query['status'] = status;
    final response = await _getJson('/v1/memory/change-requests', query);
    final items = response['items'];
    if (items is! List) return const <MemoryChangeRequest>[];
    return items.map(MemoryChangeRequest.fromJson).toList(growable: false);
  }

  Future<List<MemoryAuditEvent>> listAudit({
    String? userId,
    String? workspaceId,
    String? repoId,
    String? agentId,
    String? sessionId,
  }) async {
    final query = <String, String>{};
    if (userId != null) query['userId'] = userId;
    if (workspaceId != null) query['workspaceId'] = workspaceId;
    if (repoId != null) query['repoId'] = repoId;
    if (agentId != null) query['agentId'] = agentId;
    if (sessionId != null) query['sessionId'] = sessionId;
    final response = await _getJson('/v1/memory/audit', query);
    final items = response['items'];
    if (items is! List) return const <MemoryAuditEvent>[];
    return items.map(MemoryAuditEvent.fromJson).toList(growable: false);
  }

  Future<MemoryCandidateExtractionResult> createCandidates({
    required MemoryScopeData scope,
    required List<ExtractedMemoryCandidate> candidates,
    String? sourceTurnId,
  }) async {
    if (candidates.isEmpty) return MemoryCandidateExtractionResult.empty;
    final response =
        await _postJson('/v1/memory/extract-candidates', <String, Object?>{
          'scope': scope.toJson(),
          'sourceTurnId': ?sourceTurnId,
          'preExtractedCandidates': candidates
              .map((candidate) => candidate.toJson())
              .toList(growable: false),
        });
    return MemoryCandidateExtractionResult.fromJson(response);
  }

  Future<MemoryRecord> approveCandidate(
    MemoryCandidate candidate, {
    String? actor,
  }) async {
    final response = await _postJson(
      '/v1/memory/candidates/${Uri.encodeComponent(candidate.id)}/approve',
      candidate.toApproveJson(actor: actor),
    );
    return MemoryRecord.fromJson(response);
  }

  Future<void> rejectCandidate(String id) async {
    await _postJson(
      '/v1/memory/candidates/${Uri.encodeComponent(id)}/reject',
      const <String, Object?>{},
    );
  }

  Future<MemoryChangeRequest> approveChangeRequest(
    MemoryChangeRequest request,
  ) async {
    final response = await _postJson(
      '/v1/memory/change-requests/${Uri.encodeComponent(request.id)}/approve',
      request.toApproveJson(),
    );
    return MemoryChangeRequest.fromJson(response);
  }

  Future<MemoryChangeRequest> updateChangeRequest(
    MemoryChangeRequest request,
  ) async {
    final response = await _patchJson(
      '/v1/memory/change-requests/${Uri.encodeComponent(request.id)}',
      request.toPatchJson(),
    );
    return MemoryChangeRequest.fromJson(response);
  }

  Future<MemoryChangeRequest> rejectChangeRequest(String id) async {
    final response = await _postJson(
      '/v1/memory/change-requests/${Uri.encodeComponent(id)}/reject',
      const <String, Object?>{},
    );
    return MemoryChangeRequest.fromJson(response);
  }

  Future<MaintenanceRunResult> runMaintenance({
    required MemoryScopeData scope,
    bool? enabled,
    String? mode,
    String? costMode,
    double? highConfidenceThreshold,
    double? reviewThreshold,
    int? maxItemsPerBatch,
    List<String>? manualOnlyActions,
  }) async {
    final body = <String, Object?>{'scope': scope.toJson()};
    if (enabled != null) {
      body['enabled'] = enabled;
    }
    if (mode != null) {
      body['mode'] = mode;
    }
    if (costMode != null) {
      body['costMode'] = costMode;
    }
    if (highConfidenceThreshold != null) {
      body['highConfidenceThreshold'] = highConfidenceThreshold;
    }
    if (reviewThreshold != null) {
      body['reviewThreshold'] = reviewThreshold;
    }
    if (maxItemsPerBatch != null) {
      body['maxItemsPerBatch'] = maxItemsPerBatch;
    }
    if (manualOnlyActions != null) {
      body['manualOnlyActions'] = manualOnlyActions;
    }
    final response = await _postJson('/v1/memory/maintenance/run', body);
    return MaintenanceRunResult.fromJson(response);
  }

  Future<MemoryClearResult> clearMemory({
    required MemoryScopeData scope,
    String level = 'repo',
  }) async {
    final response = await _postJson('/v1/memory/clear', {
      'scope': scope.toJson(),
      'level': level,
    });
    return MemoryClearResult.fromJson(response);
  }

  void close({bool force = false}) => _httpClient.close(force: force);

  Future<Map<String, Object?>> _getJson(
    String path,
    Map<String, String> query,
  ) async {
    return (() async {
      final uri = _resolve(path, query);
      final request = await _httpClient.getUrl(uri);
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      final response = await request.close();
      final responseBody = await utf8.decodeStream(response);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException(
          'Memory daemon returned HTTP ${response.statusCode}: $responseBody',
          uri: uri,
        );
      }
      final decoded = jsonDecode(responseBody);
      if (decoded is! Map<String, Object?>) {
        throw const FormatException(
          'Memory daemon response must be an object.',
        );
      }
      return decoded;
    })().timeout(timeout);
  }

  Future<Map<String, Object?>> _postJson(
    String path,
    Map<String, Object?> body,
  ) async {
    return (() async {
      final uri = _resolve(path, const <String, String>{});
      final request = await _httpClient.postUrl(uri);
      request.headers.contentType = ContentType.json;
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      request.write(jsonEncode(body));
      final response = await request.close();
      final responseBody = await utf8.decodeStream(response);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException(
          'Memory daemon returned HTTP ${response.statusCode}: $responseBody',
          uri: uri,
        );
      }
      final decoded = jsonDecode(responseBody);
      if (decoded is! Map<String, Object?>) {
        throw const FormatException(
          'Memory daemon response must be an object.',
        );
      }
      return decoded;
    })().timeout(timeout);
  }

  Future<Map<String, Object?>> _patchJson(
    String path,
    Map<String, Object?> body,
  ) async {
    return (() async {
      final uri = _resolve(path, const <String, String>{});
      final request = await _httpClient.patchUrl(uri);
      request.headers.contentType = ContentType.json;
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      request.write(jsonEncode(body));
      final response = await request.close();
      final responseBody = await utf8.decodeStream(response);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException(
          'Memory daemon returned HTTP ${response.statusCode}: $responseBody',
          uri: uri,
        );
      }
      final decoded = jsonDecode(responseBody);
      if (decoded is! Map<String, Object?>) {
        throw const FormatException(
          'Memory daemon response must be an object.',
        );
      }
      return decoded;
    })().timeout(timeout);
  }

  Uri _resolve(String path, Map<String, String> query) {
    final uri = baseUrl.resolve(path);
    if (query.isEmpty) return uri;
    return uri.replace(
      queryParameters: <String, String>{...uri.queryParameters, ...query},
    );
  }
}
