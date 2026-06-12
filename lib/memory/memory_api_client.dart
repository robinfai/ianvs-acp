import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'memory_context_builder.dart';
import 'memory_extraction.dart';
import 'memory_maintenance_extraction.dart';

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
  });

  final String query;
  final MemoryScopeData scope;
  final int limit;

  Map<String, Object?> toJson() => <String, Object?>{
    'query': query,
    'scope': scope.toJson(),
    'limit': limit,
  };
}

class MemorySearchItem {
  const MemorySearchItem({
    required this.id,
    required this.kind,
    required this.scope,
    required this.text,
    required this.score,
  });

  final String id;
  final String kind;
  final String scope;
  final String text;
  final double score;

  factory MemorySearchItem.fromJson(Object? raw) {
    if (raw is! Map) {
      throw const FormatException('Memory search item must be an object.');
    }
    return MemorySearchItem(
      id: raw['id'] as String? ?? '',
      kind: raw['kind'] as String? ?? '',
      scope: raw['scope'] as String? ?? '',
      text: raw['text'] as String? ?? '',
      score: (raw['score'] as num? ?? 0).toDouble(),
    );
  }
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
}

class MemoryCandidate {
  const MemoryCandidate({
    required this.id,
    required this.kind,
    required this.scope,
    required this.text,
    this.confidence,
    this.reason,
    required this.status,
    required this.createdAt,
    this.reviewedAt,
  });

  final String id;
  final String kind;
  final String scope;
  final String text;
  final double? confidence;
  final String? reason;
  final String status;
  final int createdAt;
  final int? reviewedAt;

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
      status: raw['status'] as String? ?? '',
      createdAt: raw['createdAt'] as int? ?? 0,
      reviewedAt: raw['reviewedAt'] as int?,
    );
  }

  Map<String, Object?> toApproveJson() => <String, Object?>{
    'kind': kind,
    'scope': scope,
    'text': text,
  };
}

class CreateCandidatesResult {
  const CreateCandidatesResult({
    required this.candidates,
    required this.approvedMemories,
  });

  static const empty = CreateCandidatesResult(
    candidates: <MemoryCandidate>[],
    approvedMemories: <MemoryRecord>[],
  );

  final List<MemoryCandidate> candidates;
  final List<MemoryRecord> approvedMemories;

  factory CreateCandidatesResult.fromJson(Object? raw) {
    if (raw is! Map) {
      throw const FormatException(
        'Candidate extraction response must be an object.',
      );
    }
    final candidates = raw['candidates'];
    final approvedMemories = raw['approvedMemories'];
    return CreateCandidatesResult(
      candidates: candidates is List
          ? candidates.map(MemoryCandidate.fromJson).toList(growable: false)
          : const <MemoryCandidate>[],
      approvedMemories: approvedMemories is List
          ? approvedMemories.map(MemoryRecord.fromJson).toList(growable: false)
          : const <MemoryRecord>[],
    );
  }
}

class MemoryRecord {
  const MemoryRecord({
    required this.id,
    required this.kind,
    required this.scope,
    required this.text,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String kind;
  final String scope;
  final String text;
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
      status: raw['status'] as String? ?? '',
      createdAt: raw['createdAt'] as int? ?? 0,
      updatedAt: raw['updatedAt'] as int? ?? 0,
    );
  }

  MemoryMaintenanceItem toMaintenanceItem() {
    return MemoryMaintenanceItem(
      id: id,
      kind: kind,
      scope: scope,
      text: text,
      status: status,
    );
  }
}

class MemoryAuditEntry {
  const MemoryAuditEntry({
    required this.id,
    required this.actor,
    required this.action,
    this.memoryId,
    this.candidateId,
    this.changeRequestId,
    required this.payload,
    required this.createdAt,
  });

  final String id;
  final String actor;
  final String action;
  final String? memoryId;
  final String? candidateId;
  final String? changeRequestId;
  final Map<String, Object?> payload;
  final int createdAt;

  factory MemoryAuditEntry.fromJson(Object? raw) {
    if (raw is! Map) {
      throw const FormatException('Memory audit entry must be an object.');
    }
    final payload = raw['payload'];
    return MemoryAuditEntry(
      id: raw['id'] as String? ?? '',
      actor: raw['actor'] as String? ?? '',
      action: raw['action'] as String? ?? '',
      memoryId: raw['memoryId'] as String?,
      candidateId: raw['candidateId'] as String?,
      changeRequestId: raw['changeRequestId'] as String?,
      payload: payload is Map
          ? Map<String, Object?>.from(payload)
          : const <String, Object?>{},
      createdAt: raw['createdAt'] as int? ?? 0,
    );
  }
}

class MaintenanceRunResult {
  const MaintenanceRunResult({
    required this.autoApplied,
    required this.needsReview,
    required this.skipped,
    required this.changeRequests,
  });

  final int autoApplied;
  final int needsReview;
  final int skipped;
  final List<MemoryChangeRequest> changeRequests;

  factory MaintenanceRunResult.fromJson(Object? raw) {
    if (raw is! Map) {
      throw const FormatException('Maintenance result must be an object.');
    }
    final changeRequests = raw['changeRequests'];
    return MaintenanceRunResult(
      autoApplied: raw['autoApplied'] as int? ?? 0,
      needsReview: raw['needsReview'] as int? ?? 0,
      skipped: raw['skipped'] as int? ?? 0,
      changeRequests: changeRequests is List
          ? changeRequests
                .map(MemoryChangeRequest.fromJson)
                .toList(growable: false)
          : const <MemoryChangeRequest>[],
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

  Future<String?> searchContext(MemorySearchRequest request) async {
    final items = await search(request);
    if (items.isEmpty) return null;
    return MemoryContextBuilder.build(
      items
          .map((item) => MemoryContextItem(kind: item.kind, text: item.text))
          .toList(growable: false),
    );
  }

  Future<CreateCandidatesResult> createCandidates({
    required MemoryScopeData scope,
    required List<ExtractedMemoryCandidate> candidates,
    double? autoApproveThreshold,
  }) async {
    if (candidates.isEmpty) return CreateCandidatesResult.empty;
    final response =
        await _postJson('/v1/memory/extract-candidates', <String, Object?>{
          'scope': scope.toJson(),
          if (autoApproveThreshold != null)
            'autoApproveThreshold': autoApproveThreshold,
          'preExtractedCandidates': candidates
              .map((candidate) => candidate.toJson())
              .toList(growable: false),
        });
    return CreateCandidatesResult.fromJson(response);
  }

  Future<List<MemoryCandidate>> listCandidates({
    String? userId,
    String? repoId,
    String? status = 'pending',
    MemoryScopeData? visibleScope,
  }) async {
    final query = _memoryListQuery(
      userId: userId,
      repoId: repoId,
      visibleScope: visibleScope,
    );
    if (status != null) query['status'] = status;
    final response = await _getJson('/v1/memory/candidates', query);
    final items = response['items'];
    if (items is! List) return const <MemoryCandidate>[];
    return items.map(MemoryCandidate.fromJson).toList(growable: false);
  }

  Future<MemoryRecord> approveCandidate(MemoryCandidate candidate) async {
    final response = await _postJson(
      '/v1/memory/candidates/${Uri.encodeComponent(candidate.id)}/approve',
      candidate.toApproveJson(),
    );
    return MemoryRecord.fromJson(response);
  }

  Future<MemoryCandidate> rejectCandidate(String id) async {
    final response = await _postJson(
      '/v1/memory/candidates/${Uri.encodeComponent(id)}/reject',
      const <String, Object?>{},
    );
    return MemoryCandidate.fromJson(response);
  }

  Future<List<MemoryChangeRequest>> listChangeRequests({
    String? userId,
    String? repoId,
    String? status = 'pending',
    MemoryScopeData? visibleScope,
  }) async {
    final query = _memoryListQuery(
      userId: userId,
      repoId: repoId,
      visibleScope: visibleScope,
    );
    if (status != null) query['status'] = status;
    final response = await _getJson('/v1/memory/change-requests', query);
    final items = response['items'];
    if (items is! List) return const <MemoryChangeRequest>[];
    return items.map(MemoryChangeRequest.fromJson).toList(growable: false);
  }

  Future<List<MemoryRecord>> listMemory({
    String? userId,
    String? repoId,
    String? status = 'active',
  }) async {
    final query = <String, String>{};
    if (userId != null) query['userId'] = userId;
    if (repoId != null) query['repoId'] = repoId;
    if (status != null) query['status'] = status;
    final response = await _getJson('/v1/memory', query);
    final items = response['items'];
    if (items is! List) return const <MemoryRecord>[];
    return items.map(MemoryRecord.fromJson).toList(growable: false);
  }

  Future<List<MemoryRecord>> listVisibleMemory({
    required MemoryScopeData scope,
  }) async {
    Future<List<MemoryRecord>> listStatus(String status) async {
      final query = <String, String>{
        'visible': 'true',
        'userId': scope.userId,
        if (scope.workspaceId != null) 'workspaceId': scope.workspaceId!,
        if (scope.repoId != null) 'repoId': scope.repoId!,
        if (scope.agentId != null) 'agentId': scope.agentId!,
        if (scope.sessionId != null) 'sessionId': scope.sessionId!,
        'status': status,
      };
      final response = await _getJson('/v1/memory', query);
      final items = response['items'];
      if (items is! List) return const <MemoryRecord>[];
      return items.map(MemoryRecord.fromJson).toList(growable: false);
    }

    final groups = await Future.wait([
      listStatus('active'),
      listStatus('disabled'),
    ]);
    final records = [for (final group in groups) ...group]
      ..sort((left, right) => right.updatedAt.compareTo(left.updatedAt));
    return records;
  }

  Future<MemoryRecord> updateMemory(MemoryRecord record) async {
    final response = await _patchJson(
      '/v1/memory/${Uri.encodeComponent(record.id)}',
      <String, Object?>{
        'kind': record.kind,
        'scope': record.scope,
        'text': record.text,
        'status': record.status,
      },
    );
    return MemoryRecord.fromJson(response);
  }

  Future<void> deleteMemory(String id) async {
    await _deleteJson('/v1/memory/${Uri.encodeComponent(id)}');
  }

  Future<List<MemoryAuditEntry>> listAudit({
    int limit = 100,
    MemoryScopeData? visibleScope,
  }) async {
    final query = _memoryListQuery(visibleScope: visibleScope)
      ..['limit'] = limit.toString();
    final response = await _getJson('/v1/memory/audit', query);
    final items = response['items'];
    if (items is! List) return const <MemoryAuditEntry>[];
    return items.map(MemoryAuditEntry.fromJson).toList(growable: false);
  }

  Future<MemoryChangeRequest> createChangeRequest({
    required MemoryScopeData scope,
    required String action,
    required List<String> targetMemoryIds,
    String? proposedKind,
    String? proposedScope,
    String? proposedText,
    String? reason,
    double? confidence,
  }) async {
    final response =
        await _postJson('/v1/memory/change-requests', <String, Object?>{
          'scope': scope.toJson(),
          'action': action,
          'targetMemoryIds': targetMemoryIds,
          if (proposedKind != null) 'proposedKind': proposedKind,
          if (proposedScope != null) 'proposedScope': proposedScope,
          if (proposedText != null) 'proposedText': proposedText,
          if (reason != null) 'reason': reason,
          if (confidence != null) 'confidence': confidence,
        });
    return MemoryChangeRequest.fromJson(response);
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
    List<MaintenanceChangeRequestSuggestion>? preExtractedChangeRequests,
  }) async {
    final response = await _postJson('/v1/memory/maintenance/run', {
      'scope': scope.toJson(),
      if (enabled != null) 'enabled': enabled,
      if (mode != null) 'mode': mode,
      if (costMode != null) 'costMode': costMode,
      if (highConfidenceThreshold != null)
        'highConfidenceThreshold': highConfidenceThreshold,
      if (reviewThreshold != null) 'reviewThreshold': reviewThreshold,
      if (maxItemsPerBatch != null) 'maxItemsPerBatch': maxItemsPerBatch,
      if (manualOnlyActions != null) 'manualOnlyActions': manualOnlyActions,
      if (preExtractedChangeRequests != null)
        'preExtractedChangeRequests': preExtractedChangeRequests
            .map((request) => request.toJson())
            .toList(growable: false),
    });
    return MaintenanceRunResult.fromJson(response);
  }

  Map<String, String> _memoryListQuery({
    String? userId,
    String? repoId,
    MemoryScopeData? visibleScope,
  }) {
    if (visibleScope != null) {
      return <String, String>{
        'visible': 'true',
        'userId': visibleScope.userId,
        if (visibleScope.workspaceId != null)
          'workspaceId': visibleScope.workspaceId!,
        if (visibleScope.repoId != null) 'repoId': visibleScope.repoId!,
        if (visibleScope.agentId != null) 'agentId': visibleScope.agentId!,
        if (visibleScope.sessionId != null)
          'sessionId': visibleScope.sessionId!,
      };
    }
    return <String, String>{
      if (userId != null) 'userId': userId,
      if (repoId != null) 'repoId': repoId,
    };
  }

  void close({bool force = false}) => _httpClient.close(force: force);

  Future<Map<String, Object?>> _getJson(
    String path,
    Map<String, String> query,
  ) async {
    return (() async {
      final uri = baseUrl
          .resolve(path)
          .replace(queryParameters: query.isEmpty ? null : query);
      final request = await _httpClient.getUrl(uri);
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      final response = await request.close();
      return _decodeJsonResponse(response, uri);
    })().timeout(timeout);
  }

  Future<Map<String, Object?>> _postJson(
    String path,
    Map<String, Object?> body,
  ) async {
    return (() async {
      final uri = baseUrl.resolve(path);
      final request = await _httpClient.postUrl(uri);
      request.headers.contentType = ContentType.json;
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      request.write(jsonEncode(body));
      final response = await request.close();
      return _decodeJsonResponse(response, uri);
    })().timeout(timeout);
  }

  Future<Map<String, Object?>> _patchJson(
    String path,
    Map<String, Object?> body,
  ) async {
    return (() async {
      final uri = baseUrl.resolve(path);
      final request = await _httpClient.patchUrl(uri);
      request.headers.contentType = ContentType.json;
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      request.write(jsonEncode(body));
      final response = await request.close();
      return _decodeJsonResponse(response, uri);
    })().timeout(timeout);
  }

  Future<Map<String, Object?>> _deleteJson(String path) async {
    return (() async {
      final uri = baseUrl.resolve(path);
      final request = await _httpClient.deleteUrl(uri);
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      final response = await request.close();
      return _decodeJsonResponse(response, uri);
    })().timeout(timeout);
  }

  Future<Map<String, Object?>> _decodeJsonResponse(
    HttpClientResponse response,
    Uri uri,
  ) async {
    final responseBody = await utf8.decodeStream(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'Memory daemon returned HTTP ${response.statusCode}: $responseBody',
        uri: uri,
      );
    }
    final decoded = jsonDecode(responseBody);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('Memory daemon response must be an object.');
    }
    return decoded;
  }
}
