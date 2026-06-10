import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/memory/memory_api_client.dart';

void main() {
  test('MemorySearchRequest serializes scope with camelCase keys', () {
    final request = MemorySearchRequest(
      query: 'Flutter owns ACP',
      scope: const MemoryScopeData(
        userId: 'local-user',
        workspaceId: 'workspace-1',
        repoId: 'repo-1',
        agentId: 'agent-1',
        sessionId: 'session-1',
      ),
      limit: 12,
    );
    expect(request.toJson()['scope'], {
      'userId': 'local-user',
      'workspaceId': 'workspace-1',
      'repoId': 'repo-1',
      'agentId': 'agent-1',
      'sessionId': 'session-1',
    });
  });
}
