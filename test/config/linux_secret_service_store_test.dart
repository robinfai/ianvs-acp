import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/config/linux_secret_service_store.dart';

void main() {
  const account =
      '0db74c4ad37fe192df1fd286fafe9403f2b00d2318f3098e41f033d16bb0fab1';
  const reference = 'secret-service://ianvs-acp/$account';
  late List<({List<String> arguments, String? input})> calls;
  String? stored;
  late LinuxSecretServiceStore store;

  setUp(() {
    calls = <({List<String> arguments, String? input})>[];
    stored = null;
    store = LinuxSecretServiceStore(
      processRunner: (arguments, {input}) async {
        calls.add((arguments: arguments, input: input));
        return switch (arguments.first) {
          'store' => () {
            stored = input;
            return const LinuxSecretToolResult(exitCode: 0);
          }(),
          'lookup' =>
            stored == null
                ? const LinuxSecretToolResult(exitCode: 1)
                : LinuxSecretToolResult(exitCode: 0, stdout: '$stored\n'),
          'clear' => () {
            stored = null;
            return const LinuxSecretToolResult(exitCode: 0);
          }(),
          _ => const LinuxSecretToolResult(exitCode: 2),
        };
      },
    );
  });

  test('round-trips secrets through the Secret Service CLI envelope', () async {
    expect(
      await store.put(
        namespace: 'agent/Codex/env',
        key: 'OPENAI_API_KEY',
        value: 'secret\nwith trailing newline\n',
      ),
      reference,
    );
    expect(stored, startsWith('ianvs-acp:v1:'));
    expect(
      utf8.decode(base64Decode(stored!.substring('ianvs-acp:v1:'.length))),
      'secret\nwith trailing newline\n',
    );
    expect(await store.get(reference), 'secret\nwith trailing newline\n');

    await store.delete(reference);
    expect(await store.get(reference), isNull);
    expect(calls.map((call) => call.arguments.first), <String>[
      'store',
      'lookup',
      'clear',
      'lookup',
    ]);
    expect(calls.first.arguments, <String>[
      'store',
      '--label=ianvs ACP',
      'application',
      'ianvs-acp',
      'account',
      account,
    ]);
  });

  test('derives stable target-bound references', () {
    expect(
      store.referenceFor(namespace: 'agent/Codex/env', key: 'OPENAI_API_KEY'),
      reference,
    );
    expect(
      store.referenceMatches(
        reference,
        namespace: 'agent/Codex/env',
        key: 'OPENAI_API_KEY',
      ),
      isTrue,
    );
  });

  test('rejects malformed references without invoking secret-tool', () async {
    await expectLater(
      store.get('keychain://ianvs-acp/$account'),
      throwsFormatException,
    );
    await expectLater(
      store.delete('secret-service://ianvs-acp/not-a-hash'),
      throwsFormatException,
    );
    expect(calls, isEmpty);
  });

  test('does not expose secret values in command arguments', () async {
    await store.put(
      namespace: 'namespace',
      key: 'key',
      value: 'do-not-put-me-in-argv',
    );
    expect(calls.single.arguments.join(' '), isNot(contains('do-not-put-me')));
    expect(calls.single.input, isNot(contains('do-not-put-me')));
  });

  test('surfaces a bounded command failure', () async {
    final failing = LinuxSecretServiceStore(
      processRunner: (arguments, {input}) async => const LinuxSecretToolResult(
        exitCode: 2,
        stderr: 'Secret Service is unavailable.',
      ),
    );
    await expectLater(
      failing.put(namespace: 'namespace', key: 'key', value: 'secret'),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('Secret Service is unavailable'),
        ),
      ),
    );
  });
}
