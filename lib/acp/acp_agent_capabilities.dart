class AcpAgentCapabilities {
  const AcpAgentCapabilities({
    required this.protocolVersion,
    required this.loadSession,
    required this.prompt,
    required this.mcp,
    required this.session,
    required this.auth,
    required this.client,
    required this.rawAgentCapabilities,
    required this.authMethods,
    this.agentInfo = const <String, Object?>{},
    this.clientInfo = const <String, Object?>{},
  });

  factory AcpAgentCapabilities.fromInitialize({
    required int protocolVersion,
    required Map<String, dynamic>? agentCapabilities,
    required List<Map<String, dynamic>>? authMethods,
    required Map<String, dynamic> clientCapabilities,
    required bool hasFsProvider,
    required bool hasTerminalProvider,
    required bool allowReadOutsideWorkspace,
    Map<String, dynamic>? agentInfo,
    Map<String, dynamic>? clientInfo,
  }) {
    final rawAgent = _objectMap(agentCapabilities);
    return AcpAgentCapabilities(
      protocolVersion: protocolVersion,
      loadSession: rawAgent['loadSession'] == true,
      prompt: AcpPromptCapabilities.fromRaw(rawAgent['promptCapabilities']),
      mcp: AcpMcpCapabilities.fromRaw(rawAgent['mcpCapabilities']),
      session: AcpSessionCapabilities.fromRaw(rawAgent),
      auth: AcpAuthCapabilities.fromRaw(rawAgent['auth']),
      client: AcpClientCapabilities.fromRaw(
        clientCapabilities,
        hasFsProvider: hasFsProvider,
        hasTerminalProvider: hasTerminalProvider,
        allowReadOutsideWorkspace: allowReadOutsideWorkspace,
      ),
      rawAgentCapabilities: rawAgent,
      authMethods:
          authMethods?.map((method) => _objectMap(method)).toList() ??
          const <Map<String, Object?>>[],
      agentInfo: _objectMap(agentInfo),
      clientInfo: _objectMap(clientInfo),
    );
  }

  final int protocolVersion;
  final bool loadSession;
  final AcpPromptCapabilities prompt;
  final AcpMcpCapabilities mcp;
  final AcpSessionCapabilities session;
  final AcpAuthCapabilities auth;
  final AcpClientCapabilities client;
  final Map<String, Object?> rawAgentCapabilities;
  final List<Map<String, Object?>> authMethods;
  final Map<String, Object?> agentInfo;
  final Map<String, Object?> clientInfo;

  Map<String, Object?> get extensionMeta {
    final meta = rawAgentCapabilities['_meta'];
    return meta is Map ? _objectMap(meta) : const <String, Object?>{};
  }
}

class AcpAuthCapabilities {
  const AcpAuthCapabilities({required this.logout});

  factory AcpAuthCapabilities.fromRaw(Object? raw) {
    final caps = raw is Map ? _objectMap(raw) : const <String, Object?>{};
    return AcpAuthCapabilities(logout: _capabilityAdvertised(caps['logout']));
  }

  final bool logout;
}

class AcpPromptCapabilities {
  const AcpPromptCapabilities({
    required this.image,
    required this.audio,
    required this.embeddedContext,
  });

  factory AcpPromptCapabilities.fromRaw(Object? raw) {
    final caps = raw is Map ? _objectMap(raw) : const <String, Object?>{};
    return AcpPromptCapabilities(
      image: caps['image'] == true,
      audio: caps['audio'] == true,
      embeddedContext: caps['embeddedContext'] == true,
    );
  }

  final bool image;
  final bool audio;
  final bool embeddedContext;
}

class AcpMcpCapabilities {
  const AcpMcpCapabilities({
    required this.http,
    required this.sse,
    required this.acp,
  });

  factory AcpMcpCapabilities.fromRaw(Object? raw) {
    final caps = raw is Map ? _objectMap(raw) : const <String, Object?>{};
    return AcpMcpCapabilities(
      http: caps['http'] == true,
      sse: caps['sse'] == true,
      acp: caps['acp'] == true,
    );
  }

  final bool http;
  final bool sse;
  final bool acp;
}

class AcpSessionCapabilities {
  const AcpSessionCapabilities({
    required this.list,
    required this.resume,
    required this.fork,
    required this.configOptions,
    required this.close,
    required this.rawKeys,
  });

  factory AcpSessionCapabilities.fromRaw(Map<String, Object?> agentCaps) {
    final raw = agentCaps['sessionCapabilities'] is Map
        ? _objectMap(agentCaps['sessionCapabilities'])
        : agentCaps['session'] is Map
        ? _objectMap(agentCaps['session'])
        : const <String, Object?>{};
    return AcpSessionCapabilities(
      list: _capabilityAdvertised(raw['list']),
      resume: _capabilityAdvertised(raw['resume']),
      fork: _capabilityAdvertised(raw['fork']),
      configOptions: _capabilityAdvertised(raw['configOptions']),
      close: _capabilityAdvertised(raw['close']),
      rawKeys: raw.keys.toList()..sort(),
    );
  }

  final bool list;
  final bool resume;
  final bool fork;
  final bool configOptions;
  final bool close;
  final List<String> rawKeys;
}

class AcpClientCapabilities {
  const AcpClientCapabilities({
    required this.fsReadTextFile,
    required this.fsWriteTextFile,
    required this.terminal,
    required this.hasFsProvider,
    required this.hasTerminalProvider,
    required this.allowReadOutsideWorkspace,
  });

  factory AcpClientCapabilities.fromRaw(
    Map<String, dynamic> raw, {
    required bool hasFsProvider,
    required bool hasTerminalProvider,
    required bool allowReadOutsideWorkspace,
  }) {
    final fs = raw['fs'] is Map
        ? _objectMap(raw['fs'])
        : const <String, Object?>{};
    return AcpClientCapabilities(
      fsReadTextFile: fs['readTextFile'] == true,
      fsWriteTextFile: fs['writeTextFile'] == true,
      terminal: raw['terminal'] == true,
      hasFsProvider: hasFsProvider,
      hasTerminalProvider: hasTerminalProvider,
      allowReadOutsideWorkspace: allowReadOutsideWorkspace,
    );
  }

  final bool fsReadTextFile;
  final bool fsWriteTextFile;
  final bool terminal;
  final bool hasFsProvider;
  final bool hasTerminalProvider;
  final bool allowReadOutsideWorkspace;
}

Map<String, Object?> _objectMap(Object? raw) {
  if (raw is! Map) return const <String, Object?>{};
  return raw.map((key, value) => MapEntry(key.toString(), _jsonValue(value)));
}

Object? _jsonValue(Object? value) {
  if (value is Map) return _objectMap(value);
  if (value is List) return value.map(_jsonValue).toList();
  return value;
}

bool _capabilityAdvertised(Object? value) {
  return value is Map || value == true;
}
