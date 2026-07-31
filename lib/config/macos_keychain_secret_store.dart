import 'package:flutter/services.dart';

import 'secret_store.dart';

final class MacosKeychainSecretStore implements SecretStore {
  const MacosKeychainSecretStore([
    this._channel = const MethodChannel('ianvs_acp/keychain'),
  ]) : allowUserInteraction = false;

  const MacosKeychainSecretStore.withUserInteraction([
    this._channel = const MethodChannel('ianvs_acp/keychain'),
  ]) : allowUserInteraction = true;

  static final RegExp _referencePattern = RegExp(
    r'^keychain://ianvs-acp/([0-9a-f]{64})$',
  );

  final MethodChannel _channel;
  final bool allowUserInteraction;

  @override
  Future<String> put({
    required String namespace,
    required String key,
    required String value,
  }) async {
    if (namespace.isEmpty) {
      throw ArgumentError.value(namespace, 'namespace', 'Must not be empty.');
    }
    if (key.isEmpty) {
      throw ArgumentError.value(key, 'key', 'Must not be empty.');
    }
    final expectedReference = referenceFor(namespace: namespace, key: key);
    final response = await _channel.invokeMethod<Object?>('put', {
      'namespace': namespace,
      'key': key,
      'value': value,
    });
    if (response != expectedReference) {
      throw StateError('Keychain returned an invalid secret reference.');
    }
    return expectedReference;
  }

  @override
  Future<String?> get(String reference) async {
    final account = _accountFromReference(reference);
    final Object? response;
    try {
      response = await _channel.invokeMethod<Object?>('get', {
        'account': account,
        'allowInteraction': allowUserInteraction,
      });
    } on PlatformException catch (error) {
      if (error.code == 'keychain_interaction_required') {
        throw const SecretStoreInteractionRequiredException();
      }
      rethrow;
    }
    if (response == null || response is String) {
      return response as String?;
    }
    throw StateError('Keychain returned an invalid secret value.');
  }

  @override
  Future<void> delete(String reference) async {
    final account = _accountFromReference(reference);
    await _channel.invokeMethod<void>('delete', {'account': account});
  }

  static String _accountFromReference(String reference) {
    final match = _referencePattern.firstMatch(reference);
    if (match == null) {
      throw FormatException('Invalid Keychain secret reference.', reference);
    }
    return match.group(1)!;
  }

  @override
  String referenceFor({required String namespace, required String key}) =>
      keychainReferenceFor(namespace: namespace, key: key);

  @override
  bool referenceMatches(
    String reference, {
    required String namespace,
    required String key,
  }) => reference == referenceFor(namespace: namespace, key: key);
}
