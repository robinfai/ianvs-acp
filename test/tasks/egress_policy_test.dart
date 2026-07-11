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
        '/usr/bin/env curl https://example.com/upload',
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
