import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/acp_session_catalog.dart';

void main() {
  test('groups ACP sessions by cwd and sorts by updated time', () {
    final projects = groupAcpSessionsByProject([
      AcpSessionEntry(
        id: 'session-a',
        cwd: '/workspace/project-a',
        title: 'Older session',
        updatedAt: DateTime(2026, 5, 27, 12),
      ),
      AcpSessionEntry(
        id: 'session-b',
        cwd: '/workspace/project-b',
        title: 'Newest session',
        updatedAt: DateTime(2026, 5, 29, 12),
      ),
      AcpSessionEntry(
        id: 'session-c',
        cwd: '/workspace/project-a',
        title: 'Newer project A session',
        updatedAt: DateTime(2026, 5, 28, 12),
      ),
    ]);

    expect(projects, hasLength(2));
    expect(projects.first.cwd, '/workspace/project-b');
    expect(projects.last.cwd, '/workspace/project-a');
    expect(projects.last.sessions.first.id, 'session-c');
    expect(projects.last.dropdownLabel, contains('project-a (2)'));
  });
}
