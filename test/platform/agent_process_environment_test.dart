import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/platform/agent_process_environment.dart';

void main() {
  test('adds an absolute agent command directory to a GUI-safe PATH', () {
    final environment = AgentProcessEnvironment.resolve(
      command: '/opt/homebrew/bin/npx',
      inherited: const <String, String>{
        'HOME': '/Users/example',
        'PATH': '/usr/bin:/bin',
      },
    );

    final paths = environment['PATH']!.split(':');
    expect(paths.first, '/opt/homebrew/bin');
    expect(
      paths,
      containsAll(<String>[
        '/Users/example/.local/bin',
        '/Users/example/.cargo/bin',
        '/usr/local/bin',
        '/usr/bin',
        '/bin',
        '/usr/sbin',
        '/sbin',
      ]),
    );
    expect(paths.toSet(), hasLength(paths.length));
  });

  test('preserves an explicitly configured agent PATH', () {
    final environment = AgentProcessEnvironment.resolve(
      command: '/opt/homebrew/bin/npx',
      overrides: const <String, String>{
        'PATH': '/custom/node/bin',
        'TOKEN': 'secret',
      },
      inherited: const <String, String>{'PATH': '/usr/bin:/bin'},
    );

    expect(environment, const <String, String>{
      'PATH': '/custom/node/bin',
      'TOKEN': 'secret',
    });
  });

  test('keeps unrelated agent environment overrides', () {
    final environment = AgentProcessEnvironment.resolve(
      command: 'custom-acp',
      overrides: const <String, String>{'TOKEN': 'secret'},
      inherited: const <String, String>{
        'HOME': '/Users/example',
        'PATH': '/custom/bin:/usr/bin',
      },
    );

    expect(environment['TOKEN'], 'secret');
    expect(environment['PATH'], contains('/custom/bin'));
  });
}
