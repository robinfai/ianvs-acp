/// Information about an ACP client or agent implementation.
class AcpImplementation {
  /// Creates implementation metadata sent during initialization.
  const AcpImplementation({
    required this.name,
    required this.version,
    this.title,
    this.meta,
  });

  /// Human-readable implementation name.
  final String name;

  /// Implementation version.
  final String version;

  /// Human-readable display title.
  final String? title;

  /// ACP extension metadata.
  final Map<String, dynamic>? meta;

  /// Converts to the ACP wire representation.
  Map<String, dynamic> toJson() => {
    'name': name,
    'version': version,
    if (title != null) 'title': title,
    if (meta != null) '_meta': meta,
  };
}

/// Client support for session-scoped protocol extensions.
class ClientSessionCapabilities {
  /// Creates session capabilities.
  const ClientSessionCapabilities({
    this.configOptions = const SessionConfigOptionsCapabilities(),
    this.meta,
  });

  /// Supported session configuration option extensions.
  final SessionConfigOptionsCapabilities? configOptions;

  /// ACP extension metadata.
  final Map<String, dynamic>? meta;

  /// Converts to the ACP wire representation.
  Map<String, dynamic> toJson() => {
    if (configOptions != null) 'configOptions': configOptions!.toJson(),
    if (meta != null && meta!.isNotEmpty) '_meta': meta,
  };
}

/// Client support for session configuration option variants.
class SessionConfigOptionsCapabilities {
  /// Creates configuration option capabilities.
  const SessionConfigOptionsCapabilities({
    this.boolean = true,
    this.booleanMeta,
    this.meta,
  });

  /// Whether boolean configuration options are supported.
  ///
  /// ACP represents support as an empty capability object rather than `true`.
  final bool boolean;

  /// Optional extension metadata on the boolean capability object.
  final Map<String, dynamic>? booleanMeta;

  /// ACP extension metadata.
  final Map<String, dynamic>? meta;

  /// Converts to the ACP wire representation.
  Map<String, dynamic> toJson() => {
    if (boolean)
      'boolean': <String, dynamic>{
        if (booleanMeta != null && booleanMeta!.isNotEmpty)
          '_meta': booleanMeta,
      },
    if (meta != null && meta!.isNotEmpty) '_meta': meta,
  };
}

/// Advertised client capabilities in ACP initialization.
class AcpCapabilities {
  /// Creates capabilities.
  const AcpCapabilities({
    this.fs = const FsCapabilities(),
    this.terminal = false,
    this.session = const ClientSessionCapabilities(),
    this.plan = const <String, dynamic>{},
    this.auth,
    this.elicitation,
    this.nes,
    this.positionEncodings = const <String>[],
    this.meta,
  });

  /// File-system callbacks supported by the client.
  final FsCapabilities fs;

  /// Whether all `terminal/*` callbacks are supported.
  final bool terminal;

  /// Session-scoped capability extensions.
  final ClientSessionCapabilities? session;

  /// Unstable plan capability payload. Use `{}` to advertise support.
  final Map<String, dynamic>? plan;

  /// Unstable authentication capability payload.
  final Map<String, dynamic>? auth;

  /// Unstable elicitation capability payload.
  final Map<String, dynamic>? elicitation;

  /// Unstable Next Edit Suggestions capability payload.
  final Map<String, dynamic>? nes;

  /// Supported position encodings, in preference order.
  final List<String> positionEncodings;

  /// ACP extension metadata.
  final Map<String, dynamic>? meta;

  /// Converts to the ACP `clientCapabilities` payload.
  Map<String, dynamic> toJson() => {
    'fs': fs.toJson(),
    if (terminal) 'terminal': true,
    if (session != null) 'session': session!.toJson(),
    if (plan != null) 'plan': Map<String, dynamic>.from(plan!),
    if (auth != null) 'auth': Map<String, dynamic>.from(auth!),
    if (elicitation != null)
      'elicitation': Map<String, dynamic>.from(elicitation!),
    if (nes != null) 'nes': Map<String, dynamic>.from(nes!),
    if (positionEncodings.isNotEmpty)
      'positionEncodings': List<String>.from(positionEncodings),
    if (meta != null && meta!.isNotEmpty) '_meta': meta,
  };

  /// Creates a copy with modifications.
  AcpCapabilities copyWith({
    FsCapabilities? fs,
    bool? terminal,
    ClientSessionCapabilities? session,
    Map<String, dynamic>? plan,
    Map<String, dynamic>? auth,
    Map<String, dynamic>? elicitation,
    Map<String, dynamic>? nes,
    List<String>? positionEncodings,
    Map<String, dynamic>? meta,
  }) => AcpCapabilities(
    fs: fs ?? this.fs,
    terminal: terminal ?? this.terminal,
    session: session ?? this.session,
    plan: plan ?? this.plan,
    auth: auth ?? this.auth,
    elicitation: elicitation ?? this.elicitation,
    nes: nes ?? this.nes,
    positionEncodings: positionEncodings ?? this.positionEncodings,
    meta: meta ?? this.meta,
  );
}

/// File system capability flags.
class FsCapabilities {
  /// Creates file system capabilities.
  const FsCapabilities({
    this.readTextFile = true,
    this.writeTextFile = false,
    this.meta,
  });

  /// Whether `fs/read_text_file` is available.
  final bool readTextFile;

  /// Whether `fs/write_text_file` is available.
  final bool writeTextFile;

  /// ACP extension metadata.
  final Map<String, dynamic>? meta;

  /// JSON representation used in `clientCapabilities.fs`.
  Map<String, dynamic> toJson() => {
    'readTextFile': readTextFile,
    'writeTextFile': writeTextFile,
    if (meta != null && meta!.isNotEmpty) '_meta': meta,
  };
}
