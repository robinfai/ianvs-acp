import 'memory_api_client.dart';

MemoryScopeData visibleMemoryScope({
  required String userId,
  required String fallbackCwd,
  required String agentName,
  String? sessionCwd,
  String? sessionId,
}) {
  final cwd = visibleMemoryCwd(
    fallbackCwd: fallbackCwd,
    sessionCwd: sessionCwd,
  );
  final trimmedSessionId = sessionId?.trim();
  return MemoryScopeData(
    userId: userId,
    workspaceId: cwd,
    repoId: cwd,
    agentId: agentName,
    sessionId: trimmedSessionId == null || trimmedSessionId.isEmpty
        ? null
        : trimmedSessionId,
  );
}

String visibleMemoryCwd({required String fallbackCwd, String? sessionCwd}) {
  final trimmed = sessionCwd?.trim();
  if (trimmed == null || trimmed.isEmpty) return fallbackCwd;
  return trimmed;
}
