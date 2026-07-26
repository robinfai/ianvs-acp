import 'dart:io';

import 'linux_secret_service_store.dart';
import 'macos_keychain_secret_store.dart';
import 'secret_store.dart';

final class PlatformSecretStore implements SecretStore {
  const PlatformSecretStore();

  SecretStore get _delegate {
    if (Platform.isMacOS) return const MacosKeychainSecretStore();
    if (Platform.isLinux) return LinuxSecretServiceStore();
    throw UnsupportedError(
      'Secure ACP configuration storage is unsupported on '
      '${Platform.operatingSystem}.',
    );
  }

  @override
  Future<String> put({
    required String namespace,
    required String key,
    required String value,
  }) => _delegate.put(namespace: namespace, key: key, value: value);

  @override
  Future<String?> get(String reference) => _delegate.get(reference);

  @override
  Future<void> delete(String reference) => _delegate.delete(reference);

  @override
  String referenceFor({required String namespace, required String key}) =>
      _delegate.referenceFor(namespace: namespace, key: key);

  @override
  bool referenceMatches(
    String reference, {
    required String namespace,
    required String key,
  }) => _delegate.referenceMatches(reference, namespace: namespace, key: key);
}

SecretStore createPlatformSecretStore() => const PlatformSecretStore();
