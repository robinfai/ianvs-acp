import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

final class SecretOwner {
  const SecretOwner({
    required this.configIdentity,
    required this.targetKind,
    required this.targetIdentity,
    required this.fieldName,
    required this.key,
  });

  final String configIdentity;
  final String targetKind;
  final String targetIdentity;
  final String fieldName;
  final String key;

  String get namespace =>
      '$configIdentity/$targetKind/target/$targetIdentity/$fieldName';

  String get unscopedNamespace => '$configIdentity/$targetKind/$fieldName';

  Map<String, Object?> toJson() => <String, Object?>{
    'config_identity': configIdentity,
    'target_kind': targetKind,
    'target_identity': targetIdentity,
    'field_name': fieldName,
    'key': key,
  };

  factory SecretOwner.fromJson(Map<String, dynamic> json) {
    String requiredString(String key) {
      final value = json[key];
      if (value is! String || value.isEmpty) {
        throw FormatException('Secret owner $key must be a non-empty string.');
      }
      return value;
    }

    return SecretOwner(
      configIdentity: requiredString('config_identity'),
      targetKind: requiredString('target_kind'),
      targetIdentity: requiredString('target_identity'),
      fieldName: requiredString('field_name'),
      key: requiredString('key'),
    );
  }
}

final class SecretCleanupIntent {
  const SecretCleanupIntent({required this.owner, required this.reference});

  final SecretOwner owner;
  final String reference;

  Map<String, Object?> toJson() => <String, Object?>{
    'owner': owner.toJson(),
    'reference': reference,
  };

  factory SecretCleanupIntent.fromJson(Map<String, dynamic> json) {
    final owner = json['owner'];
    final reference = json['reference'];
    if (owner is! Map || reference is! String || reference.isEmpty) {
      throw const FormatException('Invalid secret cleanup intent.');
    }
    return SecretCleanupIntent(
      owner: SecretOwner.fromJson(Map<String, dynamic>.from(owner)),
      reference: reference,
    );
  }
}

abstract interface class SecretStore {
  Future<String> put({
    required String namespace,
    required String key,
    required String value,
  });

  Future<String?> get(String reference);

  Future<void> delete(String reference);

  String referenceFor({required String namespace, required String key});

  bool referenceMatches(
    String reference, {
    required String namespace,
    required String key,
  });
}

final class SecretStoreInteractionRequiredException implements Exception {
  const SecretStoreInteractionRequiredException();

  @override
  String toString() => 'Keychain access requires user approval.';
}

String keychainReferenceFor({required String namespace, required String key}) {
  if (namespace.isEmpty) {
    throw ArgumentError.value(namespace, 'namespace', 'Must not be empty.');
  }
  if (key.isEmpty) {
    throw ArgumentError.value(key, 'key', 'Must not be empty.');
  }
  final namespaceBytes = utf8.encode(namespace);
  final length = ByteData(8)..setUint64(0, namespaceBytes.length, Endian.big);
  final identity = BytesBuilder(copy: false)
    ..add(length.buffer.asUint8List())
    ..add(namespaceBytes)
    ..add(utf8.encode(key));
  final account = sha256.convert(identity.takeBytes());
  return 'keychain://ianvs-acp/$account';
}
