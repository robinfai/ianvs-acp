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
}
