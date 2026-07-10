import 'dart:collection';
import 'dart:convert';

import 'package:crypto/crypto.dart';

const int defaultTaskMetadataLimit = 64 * 1024;

/// Normalizes task metadata into deterministic JSON and bounds its stored size.
///
/// The class intentionally exposes one instance method so later sanitization
/// rules can be applied at the same persistence boundary.
class TaskDataSanitizer {
  const TaskDataSanitizer({this.maxMetadataBytes = defaultTaskMetadataLimit})
    : assert(maxMetadataBytes >= 0);

  final int maxMetadataBytes;

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
          key: _canonicalValue(value[key], activeContainers),
      });
    } finally {
      activeContainers.remove(value);
    }
  }

  Object? _canonicalValue(Object? value, Set<Object> activeContainers) {
    if (value == null || value is String || value is bool) {
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
}
