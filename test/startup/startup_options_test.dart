import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/startup/startup_options.dart';

void main() {
  test('StartupOptions parses resume command line flags', () {
    final options = StartupOptions.fromArgs([
      '--resume-session-id',
      ' session-1 ',
      '--resume-cwd=/workspace/project',
      '--resume-agent',
      'Codex',
    ]);

    expect(options.resumeSessionId, 'session-1');
    expect(options.resumeCwd, '/workspace/project');
    expect(options.resumeAgentName, 'Codex');
  });

  test('StartupOptions parses session deep links', () {
    final options = StartupOptions.fromDeepLink(
      'ianvs-acp://session?id=session-2&cwd=%2Fworkspace%2Fproject&agent=Codex',
    );

    expect(options?.resumeSessionId, 'session-2');
    expect(options?.resumeCwd, '/workspace/project');
    expect(options?.resumeAgentName, 'Codex');
    expect(options?.taskId, isNull);
  });

  test('StartupOptions parses task deep links', () {
    final options = StartupOptions.fromDeepLink('ianvs-acp://task?id=task-2');

    expect(options?.taskId, 'task-2');
    expect(options?.hasTaskLink, isTrue);
    expect(options?.hasResumeSession, isFalse);
  });

  test('StartupOptions parses task review deep links', () {
    final options = StartupOptions.fromDeepLink(
      'ianvs-acp://task-review?id=task-review-1',
    );

    expect(options?.taskId, 'task-review-1');
    expect(options?.hasTaskLink, isTrue);
    expect(options?.resumeSessionId, isNull);
  });

  test('StartupOptions uses command line flags over deep link values', () {
    final options = StartupOptions.fromArgs([
      'ianvs-acp://session?id=session-from-link&cwd=%2Flink&agent=LinkAgent',
      '--resume-session-id=session-from-flags',
      '--resume-cwd',
      '/flags',
    ]);

    expect(options.resumeSessionId, 'session-from-flags');
    expect(options.resumeCwd, '/flags');
    expect(options.resumeAgentName, 'LinkAgent');
  });

  test('StartupOptions extracts task deep links from command line args', () {
    final options = StartupOptions.fromArgs([
      '--some-other-flag',
      'ianvs-acp://task?id=task-from-link',
    ]);

    expect(options.taskId, 'task-from-link');
    expect(options.hasTaskLink, isTrue);
  });
}
