import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/memory/memory_scope_visibility.dart';

void main() {
  test('visibleMemoryScope uses the current session cwd and id', () {
    final scope = visibleMemoryScope(
      userId: 'local-user',
      fallbackCwd: '/repo/fallback',
      agentName: 'Codex',
      sessionCwd: ' /repo/current ',
      sessionId: 'session-1',
    );

    expect(scope.userId, 'local-user');
    expect(scope.workspaceId, '/repo/current');
    expect(scope.repoId, '/repo/current');
    expect(scope.agentId, 'Codex');
    expect(scope.sessionId, 'session-1');
  });

  test('visibleMemoryScope falls back to workspace cwd without a session', () {
    final scope = visibleMemoryScope(
      userId: 'local-user',
      fallbackCwd: '/repo/fallback',
      agentName: 'Codex',
      sessionCwd: ' ',
      sessionId: ' ',
    );

    expect(scope.workspaceId, '/repo/fallback');
    expect(scope.repoId, '/repo/fallback');
    expect(scope.agentId, 'Codex');
    expect(scope.sessionId, isNull);
  });
}
