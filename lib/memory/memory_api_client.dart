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
