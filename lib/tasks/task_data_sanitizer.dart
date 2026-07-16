import 'dart:collection';
import 'dart:convert';

import 'package:crypto/crypto.dart';

const int defaultTaskMetadataLimit = 64 * 1024;
const String taskDataRedactedValue = '<redacted>';

final RegExp _bearerSecretPattern = RegExp(
  r'(^|[^A-Za-z0-9])bearer\s{1,64}\S+',
  caseSensitive: false,
);
final RegExp _githubSecretPattern = RegExp(
  r'(^|[^A-Za-z0-9])(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})',
  caseSensitive: false,
);
final RegExp _openAiSecretPattern = RegExp(
  r'(^|[^A-Za-z0-9])sk-[A-Za-z0-9_-]{4,}',
  caseSensitive: false,
);
final RegExp _pemPrivateKeyPattern = RegExp(
  r'-----BEGIN(?: [A-Z0-9]{1,32}){0,4} PRIVATE KEY-----',
  caseSensitive: false,
);

/// Normalizes task metadata into deterministic JSON and bounds its stored size.
///
/// The class intentionally exposes one instance method so later sanitization
/// rules can be applied at the same persistence boundary.
class TaskDataSanitizer {
  const TaskDataSanitizer({this.maxMetadataBytes = defaultTaskMetadataLimit})
    : assert(maxMetadataBytes >= 0);

  final int maxMetadataBytes;

  String sanitizeText(String value) {
    return _looksLikeSecret(value) ? taskDataRedactedValue : value;
  }

  Map<String, Object?> sanitize(Map<String, Object?> metadata) {
    if (metadata.isEmpty) return const <String, Object?>{};
    final canonical = _canonicalMap(metadata, HashSet<Object>.identity());
    final bytes = utf8.encode(jsonEncode(canonical));
    if (bytes.length <= maxMetadataBytes) return canonical;
    return Map<String, Object?>.unmodifiable(<String, Object?>{
      'truncated': true,
      'original_bytes': bytes.length,
      'sha256': sha256.convert(bytes).toString(),
    });
  }

  Map<String, Object?> _canonicalMap(
    Map<Object?, Object?> value,
    Set<Object> activeContainers,
  ) {
    if (!activeContainers.add(value)) {
      throw const FormatException('Metadata must not contain cycles.');
    }
    try {
      final keys = <String>[];
      for (final key in value.keys) {
        if (key is! String) {
          throw const FormatException('Metadata object keys must be strings.');
        }
        keys.add(key);
      }
      keys.sort();
      return Map<String, Object?>.unmodifiable(<String, Object?>{
        for (final key in keys)
          key: _isSensitiveKey(key)
              ? taskDataRedactedValue
              : _isEnvironmentContainerKey(key)
              ? _canonicalEnvironment(value[key], activeContainers)
              : _isRawPayloadKey(key)
              ? _canonicalRawPayload(value[key], activeContainers)
              : _canonicalValue(value[key], activeContainers),
      });
    } finally {
      activeContainers.remove(value);
    }
  }

  Object? _canonicalValue(Object? value, Set<Object> activeContainers) {
    if (value is String) {
      return _looksLikeSecret(value) ? taskDataRedactedValue : value;
    }
    if (value == null || value is bool) {
      return value;
    }
    if (value is num) {
      if (!value.isFinite) {
        throw const FormatException(
          'Metadata numbers must be finite JSON values.',
        );
      }
      return value;
    }
    if (value is Map) return _canonicalMap(value, activeContainers);
    if (value is List) {
      if (!activeContainers.add(value)) {
        throw const FormatException('Metadata must not contain cycles.');
      }
      try {
        return List<Object?>.unmodifiable(
          value.map((item) => _canonicalValue(item, activeContainers)),
        );
      } finally {
        activeContainers.remove(value);
      }
    }
    throw FormatException(
      'Metadata values must be JSON-compatible: ${value.runtimeType}.',
    );
  }

  Object? _canonicalEnvironment(Object? value, Set<Object> activeContainers) {
    if (value is Map) {
      if (!activeContainers.add(value)) {
        throw const FormatException('Metadata must not contain cycles.');
      }
      try {
        final keys = <String>[];
        for (final key in value.keys) {
          if (key is! String) {
            throw const FormatException(
              'Metadata object keys must be strings.',
            );
          }
          keys.add(key);
        }
        keys.sort();
        return Map<String, Object?>.unmodifiable(<String, Object?>{
          for (final key in keys) key: taskDataRedactedValue,
        });
      } finally {
        activeContainers.remove(value);
      }
    }
    if (value is List) {
      if (!activeContainers.add(value)) {
        throw const FormatException('Metadata must not contain cycles.');
      }
      try {
        return List<Object?>.unmodifiable(
          value.map((item) {
            if (item is! Map) return taskDataRedactedValue;
            final name = item['name'];
            return Map<String, Object?>.unmodifiable(<String, Object?>{
              if (name is String) 'name': name,
              'value': taskDataRedactedValue,
            });
          }),
        );
      } finally {
        activeContainers.remove(value);
      }
    }
    return taskDataRedactedValue;
  }

  Object? _canonicalRawPayload(Object? value, Set<Object> activeContainers) {
    if (value is! String) return _canonicalValue(value, activeContainers);
    final trimmed = value.trimLeft();
    if (!trimmed.startsWith('{') && !trimmed.startsWith('[')) {
      return taskDataRedactedValue;
    }
    try {
      final decoded = jsonDecode(value);
      final sanitized = _canonicalValue(decoded, activeContainers);
      return jsonEncode(sanitized);
    } on FormatException {
      return taskDataRedactedValue;
    }
  }
}

bool _isEnvironmentContainerKey(String key) {
  final normalized = _normalizedKey(key);
  return normalized == 'env' || normalized == 'environment';
}

bool _isSensitiveKey(String key) {
  final normalized = _normalizedKey(key);
  const suffixes = <String>[
    'authorization',
    'cookie',
    'token',
    'secret',
    'password',
    'api_key',
    'apikey',
  ];
  return suffixes.any(normalized.endsWith);
}

bool _isRawPayloadKey(String key) {
  final normalized = _normalizedKey(key).replaceAll('_', '');
  return normalized == 'rawinput' || normalized == 'rawoutput';
}

String _normalizedKey(String key) =>
    key.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_');

bool _looksLikeSecret(String value) {
  return _bearerSecretPattern.hasMatch(value) ||
      _githubSecretPattern.hasMatch(value) ||
      _openAiSecretPattern.hasMatch(value) ||
      _pemPrivateKeyPattern.hasMatch(value);
}
