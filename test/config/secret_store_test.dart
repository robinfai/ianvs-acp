import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/config/macos_keychain_secret_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('ianvs_acp/keychain.test');
  const account =
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
  const reference = 'keychain://ianvs-acp/$account';
  late MacosKeychainSecretStore store;
  late List<MethodCall> calls;
  String? storedValue;

  setUp(() {
    calls = <MethodCall>[];
    storedValue = null;
    store = const MacosKeychainSecretStore(channel);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          final arguments = Map<String, Object?>.from(call.arguments as Map);
          switch (call.method) {
            case 'put':
              storedValue = arguments['value'] as String;
              return reference;
            case 'get':
              return storedValue;
            case 'delete':
              storedValue = null;
              return null;
          }
          throw MissingPluginException(call.method);
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('stores and resolves a secret by stable reference', () async {
    final firstReference = await store.put(
      namespace: 'agent/Codex/env',
      key: 'OPENAI_API_KEY',
      value: 'secret-value',
    );
    final updatedReference = await store.put(
      namespace: 'agent/Codex/env',
      key: 'OPENAI_API_KEY',
      value: 'updated-value',
    );

    expect(firstReference, reference);
    expect(updatedReference, firstReference);
    expect(await store.get(firstReference), 'updated-value');

    await store.delete(firstReference);
    expect(await store.get(firstReference), isNull);
    expect(calls.map((call) => call.method), <String>[
      'put',
      'put',
      'get',
      'delete',
      'get',
    ]);
    expect(calls.first.arguments, <String, Object?>{
      'namespace': 'agent/Codex/env',
      'key': 'OPENAI_API_KEY',
      'value': 'secret-value',
    });
    expect(calls[2].arguments, <String, Object?>{'account': account});
  });

  test('rejects references outside the strict keychain format', () async {
    for (final invalidReference in <String>[
      '',
      'file://ianvs-acp/$account',
      'keychain://other/$account',
      'keychain://ianvs-acp/not-a-sha256-account',
      'keychain://ianvs-acp/$account/extra',
      'keychain://ianvs-acp/${account.toUpperCase()}',
    ]) {
      await expectLater(store.get(invalidReference), throwsFormatException);
      await expectLater(store.delete(invalidReference), throwsFormatException);
    }
    expect(calls, isEmpty);
  });

  test('rejects an invalid reference returned by the platform', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => 'not-a-reference');

    await expectLater(
      store.put(namespace: 'namespace', key: 'key', value: 'value'),
      throwsStateError,
    );
  });

  test(
    'rejects empty identity components before invoking the platform',
    () async {
      await expectLater(
        store.put(namespace: '', key: 'key', value: 'value'),
        throwsArgumentError,
      );
      await expectLater(
        store.put(namespace: 'namespace', key: '', value: 'value'),
        throwsArgumentError,
      );
      expect(calls, isEmpty);
    },
  );

  test('rejects a non-string secret returned by the platform', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => 42);

    await expectLater(store.get(reference), throwsStateError);
  });
}
