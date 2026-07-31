import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/config/macos_keychain_secret_store.dart';
import 'package:ianvs_acp/config/secret_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('ianvs_acp/keychain.test');
  const account =
      '0db74c4ad37fe192df1fd286fafe9403f2b00d2318f3098e41f033d16bb0fab1';
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
              return keychainReferenceFor(
                namespace: arguments['namespace'] as String,
                key: arguments['key'] as String,
              );
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
    expect(calls[2].arguments, <String, Object?>{
      'account': account,
      'allowInteraction': false,
    });
  });

  test('derives and verifies references with the Swift identity algorithm', () {
    const expected =
        'keychain://ianvs-acp/0db74c4ad37fe192df1fd286fafe9403f2b00d2318f3098e41f033d16bb0fab1';

    expect(
      store.referenceFor(namespace: 'agent/Codex/env', key: 'OPENAI_API_KEY'),
      expected,
    );
    expect(
      store.referenceMatches(
        expected,
        namespace: 'agent/Codex/env',
        key: 'OPENAI_API_KEY',
      ),
      isTrue,
    );
    expect(
      store.referenceMatches(
        expected,
        namespace: 'agent/Other/env',
        key: 'OPENAI_API_KEY',
      ),
      isFalse,
    );
    expect(
      store.referenceMatches(
        expected,
        namespace: 'agent/Codex/env',
        key: 'OTHER_KEY',
      ),
      isFalse,
    );
  });

  test('SecretOwner derives target-bound and legacy namespaces', () {
    const owner = SecretOwner(
      configIdentity: 'config/abc',
      targetKind: 'agent/Codex',
      targetIdentity: 'target-sha',
      fieldName: 'env',
      key: 'TOKEN',
    );

    expect(owner.namespace, 'config/abc/agent/Codex/target/target-sha/env');
    expect(owner.legacyNamespace, 'config/abc/agent/Codex/env');
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

  test('maps a platform approval request to a typed exception', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (call) async =>
              throw PlatformException(code: 'keychain_interaction_required'),
        );

    await expectLater(
      store.get(reference),
      throwsA(isA<SecretStoreInteractionRequiredException>()),
    );
  });

  test('interactive reads opt in explicitly on the platform channel', () async {
    const interactiveStore = MacosKeychainSecretStore.withUserInteraction(
      channel,
    );

    await interactiveStore.get(reference);

    expect(calls.single.arguments, <String, Object?>{
      'account': account,
      'allowInteraction': true,
    });
  });
}
