// ACP extension support for custom methods, metadata, and capabilities.
//
// The Agent Client Protocol provides built-in extension mechanisms:
// - **_meta field**: Attach custom information to any protocol type
// - **Extension methods**: Custom requests/notifications starting with `_`
// - **Custom capabilities**: Advertise extensions via `_meta` in capabilities
//
// See: https://agentclientprotocol.com/protocol/extensibility

// Builder pattern methods intentionally return this for chaining.
// ignore_for_file: avoid_returning_this

import 'package:meta/meta.dart';

/// Validates that an extension method name follows ACP conventions.
///
/// Extension methods MUST start with an underscore (`_`).
/// Recommended format: `_vendor.domain/method_name`
///
/// Example: `_zed.dev/workspace/buffers`
bool isValidExtensionMethod(String methodName) => methodName.startsWith('_');

/// Creates a properly namespaced extension method name.
///
/// Uses the format `_vendor.domain/method_name` as recommended by ACP.
///
/// Example:
/// ```dart
/// final method = extensionMethodName('zed.dev', 'workspace/buffers');
/// // Returns: '_zed.dev/workspace/buffers'
/// ```
String extensionMethodName(String vendorDomain, String methodName) =>
    '_$vendorDomain/$methodName';

/// Extension metadata that can be attached to any ACP type.
///
/// The `_meta` field allows implementations to attach custom information
/// to requests, responses, notifications, and nested types (content blocks,
/// tool calls, plan entries, capability objects).
///
/// Keys should use reverse domain notation to avoid conflicts:
/// ```dart
/// final meta = ExtensionMeta({
///   'zed.dev/debugMode': true,
///   'mycompany.com/requestId': 'abc123',
/// });
/// ```
@immutable
class ExtensionMeta {
  /// Creates extension metadata from a map of key-value pairs.
  const ExtensionMeta([this._data = const {}]);

  /// Creates extension metadata from JSON.
  factory ExtensionMeta.fromJson(Map<String, dynamic>? json) =>
      json == null ? const ExtensionMeta() : ExtensionMeta(Map.from(json));

  final Map<String, dynamic> _data;

  /// Whether this metadata is empty.
  bool get isEmpty => _data.isEmpty;

  /// Whether this metadata is not empty.
  bool get isNotEmpty => _data.isNotEmpty;

  /// Get a value by key.
  dynamic operator [](String key) => _data[key];

  /// Check if a key exists.
  bool containsKey(String key) => _data.containsKey(key);

  /// Get all keys.
  Iterable<String> get keys => _data.keys;

  /// Get all entries.
  Iterable<MapEntry<String, dynamic>> get entries => _data.entries;

  /// Get a typed value with a default.
  T get<T>(String key, T defaultValue) {
    final value = _data[key];
    return value is T ? value : defaultValue;
  }

  /// Get a nested map value for vendor-specific data.
  ///
  /// Example:
  /// ```dart
  /// final zedData = meta.getVendorData('zed.dev');
  /// if (zedData != null) {
  ///   final workspace = zedData['workspace'];
  /// }
  /// ```
  Map<String, dynamic>? getVendorData(String vendorDomain) {
    final value = _data[vendorDomain];
    return value is Map<String, dynamic> ? value : null;
  }

  /// Create a copy with additional entries.
  ExtensionMeta copyWith(Map<String, dynamic> additional) =>
      ExtensionMeta({..._data, ...additional});

  /// Convert to JSON for wire format (the `_meta` field value).
  Map<String, dynamic> toJson() => Map.unmodifiable(_data);

  @override
  String toString() => 'ExtensionMeta($_data)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ExtensionMeta && _mapEquals(_data, other._data);

  @override
  int get hashCode => Object.hashAll(_data.entries);
}

bool _mapEquals(Map<String, dynamic> a, Map<String, dynamic> b) {
  if (a.length != b.length) return false;
  for (final key in a.keys) {
    if (!b.containsKey(key) || a[key] != b[key]) return false;
  }
  return true;
}

/// Custom capabilities advertised via `_meta` in capability objects.
///
/// Extensions should advertise their custom capabilities during initialization
/// so callers can check availability before using extension methods.
///
/// Example:
/// ```dart
/// final customCaps = ExtensionCapabilities({
///   'zed.dev': {
///     'workspace': true,
///     'fileNotifications': true,
///   },
///   'mycompany.com': {
///     'customAnalysis': true,
///     'version': '1.0.0',
///   },
/// });
/// ```
class ExtensionCapabilities {
  /// Creates extension capabilities from vendor data.
  const ExtensionCapabilities([this._vendors = const {}]);

  /// Creates extension capabilities from JSON (the `_meta` field in
  /// capabilities).
  factory ExtensionCapabilities.fromJson(Map<String, dynamic>? json) =>
      json == null
      ? const ExtensionCapabilities()
      : ExtensionCapabilities(Map.from(json));

  final Map<String, dynamic> _vendors;

  /// Whether any extension capabilities are defined.
  bool get isEmpty => _vendors.isEmpty;

  /// Whether extension capabilities are defined.
  bool get isNotEmpty => _vendors.isNotEmpty;

  /// Check if a vendor has registered capabilities.
  bool hasVendor(String vendorDomain) => _vendors.containsKey(vendorDomain);

  /// Get capabilities for a specific vendor.
  ///
  /// Returns null if the vendor hasn't registered capabilities.
  Map<String, dynamic>? getVendorCapabilities(String vendorDomain) {
    final value = _vendors[vendorDomain];
    return value is Map<String, dynamic> ? value : null;
  }

  /// Check if a specific capability is supported by a vendor.
  ///
  /// Example:
  /// ```dart
  /// if (caps.supports('zed.dev', 'workspace')) {
  ///   // Safe to call _zed.dev/workspace/* methods
  /// }
  /// ```
  bool supports(String vendorDomain, String capability) {
    final vendorCaps = getVendorCapabilities(vendorDomain);
    if (vendorCaps == null) return false;
    final value = vendorCaps[capability];
    return value == true || (value != null && value != false);
  }

  /// Get a capability value for a vendor.
  T? getValue<T>(String vendorDomain, String capability) {
    final vendorCaps = getVendorCapabilities(vendorDomain);
    if (vendorCaps == null) return null;
    final value = vendorCaps[capability];
    return value is T ? value : null;
  }

  /// All vendor domains with registered capabilities.
  Iterable<String> get vendors => _vendors.keys;

  /// Convert to JSON for wire format (the `_meta` field value in capabilities).
  Map<String, dynamic> toJson() => Map.unmodifiable(_vendors);

  @override
  String toString() => 'ExtensionCapabilities($_vendors)';
}

/// Result of sending an extension request.
///
/// Wraps the raw JSON response from custom extension methods.
class ExtensionResponse {
  /// Creates an extension response from raw JSON result.
  const ExtensionResponse(this._result);

  final Map<String, dynamic> _result;

  /// The raw JSON result.
  Map<String, dynamic> get raw => _result;

  /// Get a value from the result.
  dynamic operator [](String key) => _result[key];

  /// Check if a key exists in the result.
  bool containsKey(String key) => _result.containsKey(key);

  /// Get a typed value with a default.
  T get<T>(String key, T defaultValue) {
    final value = _result[key];
    return value is T ? value : defaultValue;
  }

  /// Get the `_meta` field if present.
  ExtensionMeta? get meta {
    final metaJson = _result['_meta'];
    return metaJson is Map<String, dynamic>
        ? ExtensionMeta.fromJson(metaJson)
        : null;
  }

  @override
  String toString() => 'ExtensionResponse($_result)';
}

/// Parameters for sending an extension request.
///
/// Provides a builder-like API for constructing extension method parameters.
class ExtensionParams {
  /// Creates extension parameters.
  ExtensionParams([Map<String, dynamic>? initial])
    : _params = initial != null ? Map.from(initial) : {};

  final Map<String, dynamic> _params;

  /// Set a parameter value.
  ExtensionParams set(String key, dynamic value) {
    _params[key] = value;
    return this;
  }

  /// Set multiple parameter values.
  ExtensionParams setAll(Map<String, dynamic> values) {
    _params.addAll(values);
    return this;
  }

  /// Add `_meta` field to the parameters.
  ExtensionParams withMeta(ExtensionMeta meta) {
    if (meta.isNotEmpty) {
      _params['_meta'] = meta.toJson();
    }
    return this;
  }

  /// Convert to JSON for the wire format.
  Map<String, dynamic> toJson() => Map.unmodifiable(_params);

  @override
  String toString() => 'ExtensionParams($_params)';
}

/// Mixin for types that support the `_meta` extension field.
///
/// Provides helper methods for working with extension metadata.
mixin ExtensionMetaMixin {
  /// The `_meta` field containing extension data.
  ExtensionMeta? get extensionMeta;

  /// Check if extension metadata is present.
  bool get hasExtensionMeta =>
      extensionMeta != null && extensionMeta!.isNotEmpty;

  /// Get a value from extension metadata.
  T? getMetaValue<T>(String key) {
    if (extensionMeta == null) return null;
    final value = extensionMeta![key];
    return value is T ? value : null;
  }

  /// Get vendor-specific data from extension metadata.
  Map<String, dynamic>? getVendorMeta(String vendorDomain) =>
      extensionMeta?.getVendorData(vendorDomain);
}

/// ACP error codes for extension-related errors.
abstract class ExtensionErrorCodes {
  ExtensionErrorCodes._();

  /// Method not found (standard JSON-RPC).
  /// Returned when a custom extension method is not recognized.
  static const int methodNotFound = -32601;

  /// Reserved range start for implementation-defined errors.
  static const int reservedRangeStart = -32000;

  /// Reserved range end for implementation-defined errors.
  static const int reservedRangeEnd = -32099;

  /// Check if an error code is in the reserved implementation range.
  static bool isImplementationError(int code) =>
      code >= reservedRangeEnd && code <= reservedRangeStart;
}
