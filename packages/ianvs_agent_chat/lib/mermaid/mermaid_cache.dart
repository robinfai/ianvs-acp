import 'dart:convert';

import 'package:crypto/crypto.dart';

class MermaidSvgCache {
  MermaidSvgCache.memory({this.maxEntries = 128}) : assert(maxEntries > 0);

  final int maxEntries;
  final Map<String, String> _map = <String, String>{};

  int get length => _map.length;

  static String keyFor({
    required String source,
    required String optionsJson,
    required String engineVersion,
  }) {
    final bytes = utf8.encode('$engineVersion\n$optionsJson\n$source');
    return sha256.convert(bytes).toString();
  }

  String? get(String key) {
    final value = _map.remove(key);
    if (value == null) return null;

    _map[key] = value;
    return value;
  }

  void set(String key, String svg) {
    if (_map.length >= maxEntries && !_map.containsKey(key)) {
      _map.remove(_map.keys.first);
    }
    _map[key] = svg;
  }

  void clear() => _map.clear();
}
