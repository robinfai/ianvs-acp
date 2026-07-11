import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/acp_permission_request.dart';
import 'package:ianvs_acp/tasks/egress_policy.dart';

void main() {
  group('egress policy command detection', () {
    test('flags export-sensitive commands', () {
      const sensitiveCommands = [
        'git push origin main',
        'gh pr create --fill',
        'hub pull-request',
        'curl -X POST https://example.com/upload',
        'wget https://example.com/file',
        'scp file host:/tmp',
        'rsync -av out/ host:/tmp',
        'ssh host command',
      ];

      for (final command in sensitiveCommands) {
        expect(isEgressSensitiveCommand(command), isTrue, reason: command);
      }
    });

    test('does not flag local read-only commands', () {
      const localCommands = [
        'git status',
        'git diff',
        'git log',
        'rg "foo"',
        'flutter test',
      ];

      for (final command in localCommands) {
        expect(isEgressSensitiveCommand(command), isFalse, reason: command);
      }
    });

    test('detects commands nested in permission metadata', () {
      final match = egressPolicyMatchForPermission(
        AcpPermissionRequest(
          id: 'permission-1',
          title: 'Create terminal',
          rationale: 'Requested by agent.',
          sessionId: 'session-1',
          toolName: 'terminal',
          toolKind: 'execute',
          options: const ['allow', 'deny'],
          requestedAt: DateTime(2026, 7, 7, 8),
          metadata: const <String, Object?>{'command': 'git push origin main'},
        ),
      );

      expect(match?.reason, 'git_push');
      expect(match?.commandLine, 'git push origin main');
    });

    test('detects commands encoded in raw tool input', () {
      final match = egressPolicyMatchForPermission(
        AcpPermissionRequest(
          id: 'permission-1',
          title: 'Create terminal',
          rationale: 'Requested by agent.',
          sessionId: 'session-1',
          toolName: 'terminal',
          toolKind: 'execute',
          options: const ['allow', 'deny'],
          requestedAt: DateTime(2026, 7, 7, 8),
          metadata: const <String, Object?>{
            'rawInput': '{"command":"gh","args":["pr","create","--fill"]}',
          },
        ),
      );

      expect(match?.reason, 'pull_request');
      expect(match?.commandLine, 'gh pr create --fill');
    });

    test('detects commands in permission titles', () {
      final match = egressPolicyMatchForPermission(
        AcpPermissionRequest(
          id: 'permission-1',
          title: 'Run: scp file host:/tmp',
          rationale: 'Requested by agent.',
          sessionId: 'session-1',
          toolName: 'terminal',
          toolKind: 'execute',
          options: const ['allow', 'deny'],
          requestedAt: DateTime(2026, 7, 7, 8),
        ),
      );

      expect(match?.reason, 'external_transfer_command');
      expect(match?.commandLine, 'scp file host:/tmp');
    });

    test(
      'resolves URL variables from transient environment without exposure',
      () {
        const secretUrl = 'https://collector.example.com/private-token';
        final match = egressPolicyMatchForPermission(
          AcpPermissionRequest(
            id: 'permission-env',
            title: 'Create terminal',
            rationale: 'Requested by agent.',
            sessionId: 'session-1',
            toolName: 'terminal',
            toolKind: 'execute',
            options: const ['allow', 'deny'],
            requestedAt: DateTime(2026, 7, 7, 8),
            metadata: const <String, Object?>{
              'command': 'curl',
              'args': [r'$EXFIL_URL'],
              'envKeys': ['EXFIL_URL'],
            },
            transientPolicyContext: const <String, Object?>{
              'environment': <String, String>{'EXFIL_URL': secretUrl},
            },
          ),
        );

        expect(match?.reason, 'external_http_transfer');
        expect(match?.commandLine, contains(r'$EXFIL_URL'));
        expect(match?.commandLine, isNot(contains(secretUrl)));
      },
    );

    test('unwraps env and command wrappers before classifying egress', () {
      for (final command in const <String>[
        '/usr/bin/env curl https://example.com/private',
        'command wget https://example.com/archive',
      ]) {
        final match = egressSensitiveCommandMatch(command);
        expect(match?.reason, 'external_http_transfer', reason: command);
      }
    });

    test('accepts structured args and resolves braced variables', () {
      final match = egressSensitiveCommandMatch(
        '/usr/bin/env',
        args: const <String>['curl', r'${EXFIL_URL}'],
        cwd: '/workspace',
        environment: const <String, String>{
          'EXFIL_URL': 'https://example.com/private-secret',
        },
      );

      expect(match?.reason, 'external_http_transfer');
      expect(match?.commandLine, contains(r'${EXFIL_URL}'));
      expect(match?.commandLine, isNot(contains('private-secret')));
    });

    test('resolves inline assignments for wrapped commands', () {
      final match = egressSensitiveCommandMatch(
        r'EXFIL_URL=https://example.com/private curl $EXFIL_URL',
      );

      expect(match?.reason, 'external_http_transfer');
      expect(match?.commandLine, isNot(contains('/private')));
      expect(match?.commandLine, contains(r'$EXFIL_URL'));
    });

    test(
      'holds unknown wrappers and undefined variables for manual review',
      () {
        expect(
          egressSensitiveCommandMatch('env --mystery curl https://example.com'),
          isNotNull,
        );
        expect(
          egressSensitiveCommandMatch(r'$UNKNOWN_TOOL https://example.com'),
          isNotNull,
        );
        expect(egressSensitiveCommandMatch(r'curl $UNDEFINED_URL'), isNotNull);
      },
    );

    test('holds malformed shell syntax for manual review', () {
      for (final command in <String>[
        "echo 'unterminated",
        'echo "unterminated',
        "echo trailing\\",
      ]) {
        final match = egressSensitiveCommandMatch(command);
        expect(match?.reason, 'malformed_shell_syntax', reason: command);
      }
    });

    test('checks commands after newline and background separators', () {
      for (final command in const <String>[
        'git status & curl https://example.com/private',
        'git status\ncurl https://example.com/private',
        'git status\rcurl https://example.com/private',
      ]) {
        expect(
          egressSensitiveCommandMatch(command),
          isNotNull,
          reason: command,
        );
      }
      expect(
        egressSensitiveCommandMatch(
          'echo "quoted\ncurl https://example.com/private"',
        ),
        isNull,
      );
    });

    test(
      'holds command-launching wrappers without leaking environment URLs',
      () {
        const secretUrl = 'https://collector.example/private-secret';
        for (final command in const <String>[
          r'sudo curl $EXFIL_URL',
          r'nice -n 5 curl $EXFIL_URL',
          r'timeout 5 curl $EXFIL_URL',
          r'nohup curl $EXFIL_URL',
        ]) {
          final match = egressSensitiveCommandMatch(
            command,
            environment: const <String, String>{'EXFIL_URL': secretUrl},
          );
          expect(match, isNotNull, reason: command);
          expect(match?.reason, 'unresolved_wrapper', reason: command);
          expect(
            match?.commandLine,
            isNot(contains(secretUrl)),
            reason: command,
          );
        }
        expect(
          egressSensitiveCommandMatch('custom-tool curl README.md'),
          isNull,
        );
      },
    );

    test('holds unsupported shell expansions for manual review', () {
      for (final command in const <String>[
        r'$1 https://example.com',
        r'${CMD:-curl} https://example.com',
        r'echo ${VAR:?missing}',
        r'$(curl https://example.com/private)',
        r'`curl https://example.com/private`',
      ]) {
        final match = egressSensitiveCommandMatch(command);
        expect(match, isNotNull, reason: command);
        expect(match?.reason, 'unresolved_variable', reason: command);
      }
    });

    test(
      'parses curl and wget URL options without treating credentials as URLs',
      () {
        for (final command in const <String>[
          'curl --url=https://example.com/private',
          'curl --url https://example.com/private',
          'curl -u user:secret https://example.com/private',
          'wget --url=https://example.com/private',
          'curl example.com/private',
          'wget example.com/archive',
        ]) {
          expect(
            egressSensitiveCommandMatch(command),
            isNotNull,
            reason: command,
          );
        }
        for (final command in const <String>[
          'curl --url=http://localhost:8080/health',
          'curl -u user:secret http://127.0.0.1:8080/health',
          'curl -u user:secret',
          'curl localhost:8080/health',
          'wget 127.0.0.1:8080/archive',
          'curl [::1]:8080/health',
          'curl -o https://not-a-target.example/output',
          'curl -d https://not-a-target.example/body http://localhost/health',
          'curl -H https://not-a-target.example/header http://localhost/health',
        ]) {
          expect(egressSensitiveCommandMatch(command), isNull, reason: command);
        }
      },
    );

    test('does not infer network egress from arbitrary argument words', () {
      expect(egressSensitiveCommandMatch('rg upload README.md'), isNull);
      expect(egressSensitiveCommandMatch('echo webhook'), isNull);
    });

    test('keeps safe adjacent commands unflagged', () {
      for (final command in const <String>[
        'env LANG=C git status',
        'command rg curl README.md',
        'EXAMPLE=value flutter test',
      ]) {
        expect(egressSensitiveCommandMatch(command), isNull, reason: command);
      }
    });
  });
}
