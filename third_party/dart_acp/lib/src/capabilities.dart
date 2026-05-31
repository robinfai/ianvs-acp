/// Advertised client capabilities in ACP initialization.
class AcpCapabilities {
  /// Create capabilities; defaults to read-only file system support.
  const AcpCapabilities({
    this.fs = const FsCapabilities(),
    this.terminal = false,
    this.meta,
  });

  /// File system capability flags.
  final FsCapabilities fs;

  /// Whether terminal methods are available (`terminal/*`).
  final bool terminal;

  /// Extension metadata for custom capabilities (`_meta` field).
  ///
  /// Use this to advertise vendor-specific capabilities:
  /// ```dart
  /// AcpCapabilities(
  ///   meta: {
  ///     'mycompany.com': {
  ///       'customFeature': true,
  ///     },
  ///   },
  /// )
  /// ```
  final Map<String, dynamic>? meta;

  /// Convert to JSON payload for the `initialize` request.
  Map<String, dynamic> toJson() => {
    'fs': fs.toJson(),
    if (terminal) 'terminal': true,
    if (meta != null && meta!.isNotEmpty) '_meta': meta,
  };

  /// Create a copy with modifications.
  AcpCapabilities copyWith({
    FsCapabilities? fs,
    bool? terminal,
    Map<String, dynamic>? meta,
  }) => AcpCapabilities(
    fs: fs ?? this.fs,
    terminal: terminal ?? this.terminal,
    meta: meta ?? this.meta,
  );
}

/// File system capability flags for client-provided fs methods.
class FsCapabilities {
  /// By default, allow reading but disallow writing.
  const FsCapabilities({this.readTextFile = true, this.writeTextFile = false});

  /// Whether `fs/read_text_file` is available.
  final bool readTextFile;

  /// Whether `fs/write_text_file` is available.
  final bool writeTextFile;

  /// JSON representation used in `clientCapabilities.fs`.
  Map<String, dynamic> toJson() => {
    'readTextFile': readTextFile,
    'writeTextFile': writeTextFile,
  };
}
