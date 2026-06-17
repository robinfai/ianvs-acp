import 'dart:convert';
import 'dart:io';

import '../acp/acp_permission_request.dart';

class AcpClientConfig {
  const AcpClientConfig({
    this.activeAgentServer,
    this.agentServers = const <AgentServerConfig>[],
    this.mcpServers = const <McpServerConfig>[],
    this.additionalDirectories = const <String>[],
    this.clientProviders = const AcpClientProviderConfig(),
    this.configPath,
    this.defaultAgentServerName,
  });

  static const String appConfigDirectoryName = 'ianvs-acp';
  static const String settingsFileName = 'settings.json';

  final AgentServerConfig? activeAgentServer;
  final List<AgentServerConfig> agentServers;
  final List<McpServerConfig> mcpServers;
  final List<String> additionalDirectories;
  final AcpClientProviderConfig clientProviders;
  final String? configPath;
  final String? defaultAgentServerName;

  String get agentName => activeAgentServer?.name ?? 'Codex';

  List<AgentServerConfig> get selectableAgentServers {
    if (agentServers.isNotEmpty) return List.unmodifiable(agentServers);
    final active = activeAgentServer;
    return active == null
        ? const <AgentServerConfig>[]
        : <AgentServerConfig>[active];
  }

  AgentServerConfig? agentServerNamed(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return null;
    for (final server in selectableAgentServers) {
      if (server.name == trimmed) return server;
    }
    return null;
  }

  AcpClientConfig withActiveAgentServer(String name) {
    final server = agentServerNamed(name);
    if (server == null) {
      throw FormatException('Unknown agent server "$name".');
    }
    return AcpClientConfig(
      activeAgentServer: server,
      agentServers: agentServers,
      mcpServers: mcpServers,
      additionalDirectories: additionalDirectories,
      clientProviders: clientProviders,
      configPath: configPath,
      defaultAgentServerName: defaultAgentServerName,
    );
  }

  static Future<AcpClientConfig> load({
    String? path,
    Map<String, String>? environment,
  }) async {
    final configPath = path ?? resolveConfigPath(environment: environment);
    if (configPath == null || configPath.trim().isEmpty) {
      return AcpClientConfig(configPath: configPath);
    }

    final file = File(configPath);
    if (!await file.exists()) {
      return AcpClientConfig(configPath: configPath);
    }

    final raw = jsonDecode(await file.readAsString());
    if (raw is! Map<String, dynamic>) {
      throw const FormatException('ACP config root must be a JSON object.');
    }
    return AcpClientConfig.fromJson(raw, configPath: configPath);
  }

  factory AcpClientConfig.fromJson(
    Map<String, dynamic> json, {
    String? configPath,
  }) {
    final mcpServers = _mcpServerList(
      json['mcp_servers'] ?? json['mcpServers'],
    );
    final additionalDirectories = _additionalDirectories(
      json['additional_directories'] ?? json['additionalDirectories'],
    );
    final clientProviders = AcpClientProviderConfig.fromJson(
      json['client_providers'] ?? json['clientProviders'],
    );
    final serversRaw = json['agent_servers'] ?? json['agentServers'];
    if (serversRaw == null) {
      return AcpClientConfig(
        configPath: configPath,
        mcpServers: mcpServers,
        additionalDirectories: additionalDirectories,
        clientProviders: clientProviders,
      );
    }
    if (serversRaw is! Map<String, dynamic>) {
      throw const FormatException('agent_servers must be a JSON object.');
    }

    final servers = <String, AgentServerConfig>{};
    for (final entry in serversRaw.entries) {
      final serverJson = entry.value;
      if (serverJson is! Map<String, dynamic>) {
        throw FormatException('Agent server "${entry.key}" must be an object.');
      }
      servers[entry.key] = AgentServerConfig.fromJson(
        name: entry.key,
        json: serverJson,
      );
    }

    if (servers.isEmpty) {
      return AcpClientConfig(
        configPath: configPath,
        mcpServers: mcpServers,
        additionalDirectories: additionalDirectories,
        clientProviders: clientProviders,
      );
    }

    final preferredName = _stringValue(
      json['default_agent_server'] ?? json['defaultAgentServer'],
    );
    final active = preferredName == null
        ? servers.values.first
        : servers[preferredName];
    if (active == null) {
      throw FormatException('Unknown default agent server "$preferredName".');
    }
    return AcpClientConfig(
      activeAgentServer: active,
      agentServers: servers.values.toList(),
      mcpServers: mcpServers,
      additionalDirectories: additionalDirectories,
      clientProviders: clientProviders,
      configPath: configPath,
      defaultAgentServerName: preferredName,
    );
  }

  static String? resolveConfigPath({Map<String, String>? environment}) {
    const dartDefinePath = String.fromEnvironment('ACP_CONFIG_PATH');
    if (dartDefinePath.trim().isNotEmpty) return dartDefinePath.trim();

    final env = environment ?? Platform.environment;
    final envPath = env['ACP_CONFIG_PATH'] ?? env['IANVS_ACP_CONFIG'];
    if (envPath != null && envPath.trim().isNotEmpty) {
      return envPath.trim();
    }

    final xdgConfigHome = env['XDG_CONFIG_HOME'];
    if (xdgConfigHome != null && xdgConfigHome.trim().isNotEmpty) {
      return '${xdgConfigHome.trim()}/$appConfigDirectoryName/$settingsFileName';
    }

    final home = env['HOME'];
    if (home == null || home.trim().isEmpty) return null;
    return '${home.trim()}/.config/$appConfigDirectoryName/$settingsFileName';
  }

  static String resolveWorkspaceCwd({
    Map<String, String>? environment,
    String? currentDirectory,
  }) {
    const dartDefineCwd = String.fromEnvironment('ACP_WORKSPACE_CWD');
    if (dartDefineCwd.trim().isNotEmpty) return dartDefineCwd.trim();

    final env = environment ?? Platform.environment;
    final envCwd = env['ACP_WORKSPACE_CWD'] ?? env['IANVS_ACP_WORKSPACE_CWD'];
    if (envCwd != null && envCwd.trim().isNotEmpty) {
      return envCwd.trim();
    }

    final current = (currentDirectory ?? Directory.current.path).trim();
    if (current.isNotEmpty && current != '/') return current;

    final pwd = env['PWD'];
    if (pwd != null && pwd.trim().isNotEmpty && pwd.trim() != '/') {
      return pwd.trim();
    }

    final home = env['HOME'];
    if (home != null && home.trim().isNotEmpty) return home.trim();

    return current.isEmpty ? Directory.current.path : current;
  }
}

class AcpClientProviderConfig {
  const AcpClientProviderConfig({
    this.filesystem = const AcpFilesystemProviderConfig(),
    this.terminal = const AcpTerminalProviderConfig(),
    this.permissions = const AcpPermissionProviderConfig(),
  });

  final AcpFilesystemProviderConfig filesystem;
  final AcpTerminalProviderConfig terminal;
  final AcpPermissionProviderConfig permissions;

  factory AcpClientProviderConfig.fromJson(Object? raw) {
    if (raw == null) return const AcpClientProviderConfig();
    if (raw is! Map) {
      throw const FormatException('client_providers must be a JSON object.');
    }
    final map = _jsonMap(raw, fieldName: 'client_providers');
    return AcpClientProviderConfig(
      filesystem: AcpFilesystemProviderConfig.fromJson(
        map['filesystem'] ?? map['fs'],
      ),
      terminal: AcpTerminalProviderConfig.fromJson(map['terminal']),
      permissions: AcpPermissionProviderConfig.fromJson(map['permissions']),
    );
  }

  Map<String, Object?> toJson() {
    final filesystemJson = filesystem.toJson();
    final terminalJson = terminal.toJson();
    final permissionsJson = permissions.toJson();
    return <String, Object?>{
      if (filesystemJson.isNotEmpty) 'filesystem': filesystemJson,
      if (terminalJson.isNotEmpty) 'terminal': terminalJson,
      if (permissionsJson.isNotEmpty) 'permissions': permissionsJson,
    };
  }
}

class AcpPermissionProviderConfig {
  const AcpPermissionProviderConfig({
    this.trustRules = const <AcpPermissionTrustRule>[],
    this.reviewAgent = const AcpPermissionReviewAgentConfig(),
  });

  final List<AcpPermissionTrustRule> trustRules;
  final AcpPermissionReviewAgentConfig reviewAgent;

  bool get hasTrustRules => trustRules.isNotEmpty;

  bool get hasReviewAgent => reviewAgent.enabled;

  factory AcpPermissionProviderConfig.fromJson(Object? raw) {
    if (raw == null) return const AcpPermissionProviderConfig();
    if (raw is! Map) {
      throw const FormatException(
        'client_providers.permissions must be a JSON object.',
      );
    }
    final map = _jsonMap(raw, fieldName: 'client_providers.permissions');
    final rulesRaw = map['trust_rules'] ?? map['trustRules'] ?? map['rules'];
    final reviewAgent = AcpPermissionReviewAgentConfig.fromJson(
      map['review_agent'] ?? map['reviewAgent'] ?? map['approval_agent'],
    );
    if (rulesRaw == null) {
      return AcpPermissionProviderConfig(reviewAgent: reviewAgent);
    }
    if (rulesRaw is! List) {
      throw const FormatException(
        'client_providers.permissions.trust_rules must be a JSON array.',
      );
    }
    return AcpPermissionProviderConfig(
      trustRules: rulesRaw.map(_permissionTrustRule).toList(growable: false),
      reviewAgent: reviewAgent,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      if (trustRules.isNotEmpty)
        'trust_rules': trustRules
            .map(_permissionTrustRuleJson)
            .toList(growable: false),
      if (reviewAgent.isConfigured) 'review_agent': reviewAgent.toJson(),
    };
  }
}

class AcpPermissionReviewAgentConfig {
  const AcpPermissionReviewAgentConfig({
    this.enabled = false,
    this.mcpServer,
    this.mcpServerName,
    this.toolName = 'review_permission',
    this.model,
    this.timeout = const Duration(seconds: 10),
  });

  final bool enabled;
  final McpServerConfig? mcpServer;
  final String? mcpServerName;
  final String toolName;
  final String? model;
  final Duration timeout;

  bool get hasMcpTarget {
    final name = mcpServerName?.trim();
    return mcpServer != null || (name != null && name.isNotEmpty);
  }

  bool get isConfigured {
    return enabled ||
        hasMcpTarget ||
        model?.trim().isNotEmpty == true ||
        toolName != 'review_permission' ||
        timeout != const Duration(seconds: 10);
  }

  String get displayTarget {
    final server = mcpServer;
    if (server != null) return server.name;
    final name = mcpServerName?.trim();
    return name == null || name.isEmpty ? 'Unconfigured' : name;
  }

  factory AcpPermissionReviewAgentConfig.fromJson(Object? raw) {
    if (raw == null) return const AcpPermissionReviewAgentConfig();
    if (raw is bool) {
      return AcpPermissionReviewAgentConfig(enabled: raw);
    }
    if (raw is! Map) {
      throw const FormatException(
        'client_providers.permissions.review_agent must be a JSON object.',
      );
    }
    final map = _jsonMap(
      raw,
      fieldName: 'client_providers.permissions.review_agent',
    );
    final enabled = map.containsKey('enabled')
        ? _boolConfigValue(
            map['enabled'],
            fieldName: 'client_providers.permissions.review_agent.enabled',
          )
        : true;
    final mcpServerRaw = map['mcp_server'] ?? map['mcpServer'];
    final mcpServer = mcpServerRaw == null
        ? null
        : _permissionReviewMcpServer(mcpServerRaw);
    final mcpServerName = _stringValue(
      map['mcp_server_name'] ?? map['mcpServerName'] ?? map['server_name'],
    );
    if (mcpServer != null && mcpServerName != null) {
      throw const FormatException(
        'client_providers.permissions.review_agent must define either mcp_server or mcp_server_name, not both.',
      );
    }
    final toolName =
        _stringValue(map['tool_name'] ?? map['toolName']) ??
        'review_permission';
    final timeoutMs = _positiveIntValue(
      map['timeout_ms'] ?? map['timeoutMs'],
      fieldName: 'client_providers.permissions.review_agent.timeout_ms',
    );
    return AcpPermissionReviewAgentConfig(
      enabled: enabled,
      mcpServer: mcpServer,
      mcpServerName: mcpServerName,
      toolName: toolName,
      model: _stringValue(map['model']),
      timeout: timeoutMs == null
          ? const Duration(seconds: 10)
          : Duration(milliseconds: timeoutMs),
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'enabled': enabled,
      if (mcpServer != null) 'mcp_server': mcpServer!.toJson(),
      if (mcpServerName?.trim().isNotEmpty == true)
        'mcp_server_name': mcpServerName!.trim(),
      if (toolName != 'review_permission') 'tool_name': toolName,
      if (model?.trim().isNotEmpty == true) 'model': model!.trim(),
      if (timeout != const Duration(seconds: 10))
        'timeout_ms': timeout.inMilliseconds,
    };
  }
}

AcpPermissionTrustRule _permissionTrustRule(Object? raw) {
  if (raw is! Map) {
    throw const FormatException(
      'client_providers.permissions.trust_rules entries must be JSON objects.',
    );
  }
  final map = _jsonMap(
    raw,
    fieldName: 'client_providers.permissions.trust_rules[]',
  );
  final toolName = _stringValue(map['tool_name'] ?? map['toolName']);
  if (toolName == null || toolName.isEmpty) {
    throw const FormatException(
      'client_providers.permissions.trust_rules[].tool_name is required.',
    );
  }
  final decision = _permissionTrustDecision(
    map['decision'],
    fieldName: 'client_providers.permissions.trust_rules[].decision',
  );
  final toolKind = _stringValue(map['tool_kind'] ?? map['toolKind']);
  return AcpPermissionTrustRule(
    toolName: toolName,
    toolKind: toolKind,
    decision: decision,
  );
}

Map<String, Object?> _permissionTrustRuleJson(AcpPermissionTrustRule rule) {
  return <String, Object?>{
    'tool_name': rule.toolName.trim(),
    if (rule.toolKind?.trim().isNotEmpty == true)
      'tool_kind': rule.toolKind!.trim(),
    'decision': switch (rule.decision) {
      AcpPermissionDecision.allow => 'allow',
      AcpPermissionDecision.deny => 'deny',
      AcpPermissionDecision.cancel => 'cancel',
    },
  };
}

McpServerConfig _permissionReviewMcpServer(Object? raw) {
  if (raw is! Map) {
    throw const FormatException(
      'client_providers.permissions.review_agent.mcp_server must be a JSON object.',
    );
  }
  return McpServerConfig.fromJson(index: 0, json: raw);
}

AcpPermissionDecision _permissionTrustDecision(
  Object? raw, {
  required String fieldName,
}) {
  final value = _stringValue(raw)?.toLowerCase();
  return switch (value) {
    'allow' || 'allowed' => AcpPermissionDecision.allow,
    'deny' || 'denied' || 'reject' || 'rejected' => AcpPermissionDecision.deny,
    _ => throw FormatException('$fieldName must be allow or deny.'),
  };
}

class AcpTerminalProviderConfig {
  const AcpTerminalProviderConfig({this.enabled = false});

  final bool enabled;

  factory AcpTerminalProviderConfig.fromJson(Object? raw) {
    if (raw == null) return const AcpTerminalProviderConfig();
    if (raw is! Map) {
      throw const FormatException(
        'client_providers.terminal must be a JSON object.',
      );
    }
    final map = _jsonMap(raw, fieldName: 'client_providers.terminal');
    return AcpTerminalProviderConfig(
      enabled: _boolConfigValue(
        map['enabled'],
        fieldName: 'client_providers.terminal.enabled',
      ),
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{if (enabled) 'enabled': true};
  }
}

class AcpFilesystemProviderConfig {
  const AcpFilesystemProviderConfig({
    this.readTextFile = false,
    this.writeTextFile = false,
    this.allowReadOutsideWorkspace = false,
  });

  final bool readTextFile;
  final bool writeTextFile;
  final bool allowReadOutsideWorkspace;

  bool get enabled => readTextFile || writeTextFile;

  factory AcpFilesystemProviderConfig.fromJson(Object? raw) {
    if (raw == null) return const AcpFilesystemProviderConfig();
    if (raw is! Map) {
      throw const FormatException(
        'client_providers.filesystem must be a JSON object.',
      );
    }
    final map = _jsonMap(raw, fieldName: 'client_providers.filesystem');
    return AcpFilesystemProviderConfig(
      readTextFile: _boolConfigValue(
        map['read_text_file'] ?? map['readTextFile'],
        fieldName: 'client_providers.filesystem.read_text_file',
      ),
      writeTextFile: _boolConfigValue(
        map['write_text_file'] ?? map['writeTextFile'],
        fieldName: 'client_providers.filesystem.write_text_file',
      ),
      allowReadOutsideWorkspace: _boolConfigValue(
        map['allow_read_outside_workspace'] ?? map['allowReadOutsideWorkspace'],
        fieldName: 'client_providers.filesystem.allow_read_outside_workspace',
      ),
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      if (readTextFile) 'read_text_file': true,
      if (writeTextFile) 'write_text_file': true,
      if (allowReadOutsideWorkspace) 'allow_read_outside_workspace': true,
    };
  }
}

class AgentServerConfig {
  const AgentServerConfig({
    required this.name,
    required this.type,
    this.command = '',
    this.cwd,
    this.url = '',
    this.args = const <String>[],
    this.env = const <String, String>{},
    this.headers = const <String, String>{},
    this.systemPrompt = '',
    this.defaultModel = '',
    this.defaultReasoningEffort = '',
    this.permissionReviewAgent = const AcpPermissionReviewAgentConfig(),
  });

  final String name;
  final String type;
  final String command;
  final String? cwd;
  final String url;
  final List<String> args;
  final Map<String, String> env;
  final Map<String, String> headers;
  final String systemPrompt;
  final String defaultModel;
  final String defaultReasoningEffort;
  final AcpPermissionReviewAgentConfig permissionReviewAgent;

  bool get isWebSocket => type == 'websocket' || type == 'ws';

  bool get isStreamableHttp =>
      type == 'http' ||
      type == 'https' ||
      type == 'sse' ||
      type == 'streamable_http' ||
      type == 'streamable-http';

  bool get isStdio => !isWebSocket && !isStreamableHttp;

  String get displayTarget => isStdio ? command : url;

  factory AgentServerConfig.fromJson({
    required String name,
    required Map<String, dynamic> json,
  }) {
    final type = (_stringValue(json['type']) ?? 'custom').trim().toLowerCase();
    if (type == 'websocket' || type == 'ws') {
      final url = _stringValue(json['url']);
      if (url == null || url.isEmpty) {
        throw FormatException('Agent server "$name" requires url.');
      }
      _ensureRemoteAgentUrl(
        url,
        serverName: name,
        allowedSchemes: const <String>{'ws', 'wss'},
        schemeLabel: 'ws or wss',
      );
      final headersRaw = json['headers'];
      final headers = headersRaw == null
          ? const <String, String>{}
          : _stringMapOrNameValueList(
              headersRaw,
              fieldName: 'headers',
              serverName: name,
            );
      return AgentServerConfig(
        name: name,
        type: type,
        url: url,
        headers: headers,
        systemPrompt: _agentSystemPrompt(json),
        defaultModel: _agentDefaultModel(json),
        defaultReasoningEffort: _agentDefaultReasoningEffort(json),
        permissionReviewAgent: _agentPermissionReviewAgent(json),
      );
    }

    if (type == 'http' ||
        type == 'https' ||
        type == 'sse' ||
        type == 'streamable_http' ||
        type == 'streamable-http') {
      final url = _stringValue(json['url']);
      if (url == null || url.isEmpty) {
        throw FormatException('Agent server "$name" requires url.');
      }
      _ensureRemoteAgentUrl(
        url,
        serverName: name,
        allowedSchemes: const <String>{'http', 'https'},
        schemeLabel: 'http or https',
      );
      final headersRaw = json['headers'];
      final headers = headersRaw == null
          ? const <String, String>{}
          : _stringMapOrNameValueList(
              headersRaw,
              fieldName: 'headers',
              serverName: name,
            );
      return AgentServerConfig(
        name: name,
        type: type,
        url: url,
        headers: headers,
        systemPrompt: _agentSystemPrompt(json),
        defaultModel: _agentDefaultModel(json),
        defaultReasoningEffort: _agentDefaultReasoningEffort(json),
        permissionReviewAgent: _agentPermissionReviewAgent(json),
      );
    }

    if (type != 'custom' && type != 'stdio') {
      throw FormatException(
        'Unsupported agent server type "$type". '
        'Supported types: custom, stdio, websocket, http, sse.',
      );
    }

    final command = _stringValue(json['command']);
    if (command == null || command.isEmpty) {
      throw FormatException('Agent server "$name" requires command.');
    }
    final cwd = _absolutePathValue(
      json['cwd'] ?? json['working_directory'] ?? json['workingDirectory'],
      fieldName: 'cwd',
      serverName: name,
    );

    final argsRaw = json['args'];
    final args = argsRaw == null
        ? const <String>[]
        : _stringList(argsRaw, fieldName: 'args', serverName: name);
    final envRaw = json['env'];
    final env = envRaw == null
        ? const <String, String>{}
        : _stringMap(envRaw, fieldName: 'env', serverName: name);

    return AgentServerConfig(
      name: name,
      type: type,
      command: command,
      cwd: cwd,
      args: args,
      env: env,
      systemPrompt: _agentSystemPrompt(json),
      defaultModel: _agentDefaultModel(json),
      defaultReasoningEffort: _agentDefaultReasoningEffort(json),
      permissionReviewAgent: _agentPermissionReviewAgent(json),
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'type': type,
      if (command.isNotEmpty) 'command': command,
      if (cwd != null) 'cwd': cwd,
      if (url.isNotEmpty) 'url': url,
      if (args.isNotEmpty) 'args': args,
      if (env.isNotEmpty) 'env': env,
      if (headers.isNotEmpty) 'headers': headers,
      if (systemPrompt.trim().isNotEmpty) 'system_prompt': systemPrompt.trim(),
      if (defaultModel.trim().isNotEmpty) 'default_model': defaultModel.trim(),
      if (defaultReasoningEffort.trim().isNotEmpty)
        'default_reasoning_effort': defaultReasoningEffort.trim(),
      if (permissionReviewAgent.isConfigured)
        'review_agent': permissionReviewAgent.toJson(),
    };
  }
}

class McpServerConfig {
  const McpServerConfig({required this.raw});

  final Map<String, dynamic> raw;

  String get name => _stringValue(raw['name']) ?? 'MCP server';

  String get type =>
      _stringValue(raw['type'])?.toLowerCase() ??
      (url.isEmpty ? 'stdio' : 'http');

  String get command => _stringValue(raw['command']) ?? '';

  String get url => _stringValue(raw['url']) ?? '';

  String get id => _stringValue(raw['id']) ?? '';

  List<String> get headerKeys {
    final headers = raw['headers'];
    final keys = <String>[];
    if (headers is Map) {
      for (final key in headers.keys) {
        if (key is String && key.trim().isNotEmpty) keys.add(key.trim());
      }
    } else if (headers is List) {
      for (final header in headers) {
        if (header is! Map) continue;
        final name = _stringValue(header['name']);
        if (name != null) keys.add(name);
      }
    }
    keys.sort();
    return List.unmodifiable(keys);
  }

  Map<String, dynamic> toJson() => _jsonMap(raw, fieldName: 'mcp_servers');

  factory McpServerConfig.fromJson({required int index, required Map json}) {
    final raw = _jsonMap(json, fieldName: 'mcp_servers[$index]');
    final name = _stringValue(raw['name']);
    if (name == null) {
      throw FormatException('MCP server at index $index requires name.');
    }

    final type = _stringValue(raw['type'])?.toLowerCase();
    if (type != null) raw['type'] = type;
    final command = _stringValue(raw['command']);
    final url = _stringValue(raw['url']);
    final id = _stringValue(raw['id']);
    if (type != null && !_supportedMcpTransportTypes.contains(type)) {
      throw FormatException(
        'MCP server "$name" type must be one of: '
        '${_supportedMcpTransportTypes.join(', ')}.',
      );
    }
    if (type == 'acp') {
      if (id == null) {
        throw FormatException('MCP server "$name" acp transport requires id.');
      }
      if (command != null || url != null) {
        throw FormatException(
          'MCP server "$name" acp transport must not define command or url.',
        );
      }
      raw['id'] = id;
      return McpServerConfig(raw: raw);
    }
    if (command == null && url == null) {
      throw FormatException('MCP server "$name" requires command or url.');
    }
    if (type == 'stdio') {
      if (command == null) {
        throw FormatException(
          'MCP server "$name" stdio transport requires command.',
        );
      }
      if (url != null) {
        throw FormatException(
          'MCP server "$name" stdio transport must not define url.',
        );
      }
    }
    if (type == 'http' || type == 'sse') {
      if (url == null) {
        throw FormatException(
          'MCP server "$name" $type transport requires url.',
        );
      }
      if (command != null) {
        throw FormatException(
          'MCP server "$name" $type transport must not define command.',
        );
      }
    }
    if (type == null && command != null && url != null) {
      throw FormatException(
        'MCP server "$name" must not define both command and url without type.',
      );
    }

    final inferredRemoteHttp = type == null && command == null && url != null;
    if (type == 'http' || type == 'sse' || inferredRemoteHttp) {
      _ensureHttpUrl(url!, serverName: name, transportType: type ?? 'http');
      _ensureRemoteHeaderList(raw, key: 'headers', serverName: name);
    } else {
      _ensureStringList(raw, key: 'args', serverName: name);
      _ensureNameValueList(raw, key: 'env', serverName: name);
    }

    return McpServerConfig(raw: raw);
  }
}

AcpPermissionReviewAgentConfig _agentPermissionReviewAgent(
  Map<String, dynamic> json,
) {
  final permissions = json['permissions'];
  Object? raw = json['review_agent'] ?? json['reviewAgent'];
  if (raw == null && permissions is Map) {
    raw =
        permissions['review_agent'] ??
        permissions['reviewAgent'] ??
        permissions['approval_agent'];
  }
  return AcpPermissionReviewAgentConfig.fromJson(raw);
}

String _agentSystemPrompt(Map<String, dynamic> json) {
  return _stringValue(json['system_prompt'] ?? json['systemPrompt']) ?? '';
}

String _agentDefaultModel(Map<String, dynamic> json) {
  return _stringValue(json['default_model'] ?? json['defaultModel']) ?? '';
}

String _agentDefaultReasoningEffort(Map<String, dynamic> json) {
  return _stringValue(
        json['default_reasoning_effort'] ?? json['defaultReasoningEffort'],
      ) ??
      '';
}

const Set<String> _supportedMcpTransportTypes = <String>{
  'stdio',
  'http',
  'sse',
  'acp',
};

String? _stringValue(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

String? _absolutePathValue(
  Object? value, {
  required String fieldName,
  required String serverName,
}) {
  if (value == null) return null;
  if (value is! String || value.trim().isEmpty) {
    throw FormatException(
      'Agent server "$serverName" $fieldName must be a non-empty string.',
    );
  }
  final path = value.trim();
  if (!File(path).isAbsolute) {
    throw FormatException(
      'Agent server "$serverName" $fieldName must be an absolute path.',
    );
  }
  return path;
}

List<String> _stringList(
  Object? value, {
  required String fieldName,
  required String serverName,
}) {
  if (value is! List) {
    throw FormatException(
      'Agent server "$serverName" $fieldName must be a list.',
    );
  }
  return value.map((item) {
    if (item is! String) {
      throw FormatException(
        'Agent server "$serverName" $fieldName entries must be strings.',
      );
    }
    return item;
  }).toList();
}

Map<String, String> _stringMap(
  Object? value, {
  required String fieldName,
  required String serverName,
}) {
  if (value is! Map) {
    throw FormatException(
      'Agent server "$serverName" $fieldName must be an object.',
    );
  }
  return value.map((key, item) {
    if (key is! String || item is! String) {
      throw FormatException(
        'Agent server "$serverName" $fieldName entries must be strings.',
      );
    }
    return MapEntry(key, item);
  });
}

Map<String, String> _stringMapOrNameValueList(
  Object? value, {
  required String fieldName,
  required String serverName,
}) {
  if (value is Map) {
    return value.map((key, item) {
      if (key is! String || item is! String) {
        throw FormatException(
          'Agent server "$serverName" $fieldName entries must be strings.',
        );
      }
      _validateHttpHeaderEntry(
        name: key,
        value: item,
        fieldName: fieldName,
        serverName: serverName,
      );
      return MapEntry(key, item);
    });
  }
  if (value is! List) {
    throw FormatException(
      'Agent server "$serverName" $fieldName must be an object or list.',
    );
  }
  final result = <String, String>{};
  for (var index = 0; index < value.length; index++) {
    final entry = _nameValueEntry(
      value[index],
      fieldName: fieldName,
      serverName: serverName,
      index: index,
    );
    result[entry.key] = entry.value;
  }
  return result;
}

MapEntry<String, String> _nameValueEntry(
  Object? value, {
  required String fieldName,
  required String serverName,
  required int index,
}) {
  if (value is! Map) {
    throw FormatException(
      'Agent server "$serverName" $fieldName entry $index must be an object.',
    );
  }
  final name = value['name'];
  final itemValue = value['value'];
  if (name is! String || itemValue is! String) {
    throw FormatException(
      'Agent server "$serverName" $fieldName entry $index requires name and value.',
    );
  }
  _validateHttpHeaderEntry(
    name: name,
    value: itemValue,
    fieldName: fieldName,
    serverName: serverName,
    index: index,
  );
  return MapEntry(name, itemValue);
}

final RegExp _httpHeaderNamePattern = RegExp(r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$");

void _ensureRemoteAgentUrl(
  String url, {
  required String serverName,
  required Set<String> allowedSchemes,
  required String schemeLabel,
}) {
  final uri = Uri.tryParse(url);
  if (uri == null || !allowedSchemes.contains(uri.scheme)) {
    throw FormatException(
      'Agent server "$serverName" url must use $schemeLabel.',
    );
  }
  if (uri.host.trim().isEmpty) {
    throw FormatException('Agent server "$serverName" url requires host.');
  }
}

void _validateHttpHeaderEntry({
  required String name,
  required String value,
  required String fieldName,
  required String serverName,
  int? index,
}) {
  final location = index == null
      ? 'Agent server "$serverName" $fieldName'
      : 'Agent server "$serverName" $fieldName entry $index';
  if (!_httpHeaderNamePattern.hasMatch(name)) {
    throw FormatException('$location requires a valid HTTP header name.');
  }
  if (value.trim().isEmpty || value.contains('\n') || value.contains('\r')) {
    throw FormatException('$location requires a non-empty HTTP header value.');
  }
}

List<McpServerConfig> _mcpServerList(Object? value) {
  if (value == null) return const <McpServerConfig>[];
  if (value is! List) {
    throw const FormatException('mcp_servers must be a list.');
  }
  final servers = <McpServerConfig>[];
  for (var index = 0; index < value.length; index++) {
    final json = value[index];
    if (json is! Map) {
      throw FormatException('MCP server at index $index must be an object.');
    }
    servers.add(McpServerConfig.fromJson(index: index, json: json));
  }
  return servers;
}

List<String> _additionalDirectories(Object? value) {
  if (value == null) return const <String>[];
  if (value is! List) {
    throw const FormatException('additional_directories must be a list.');
  }
  final directories = <String>[];
  final seen = <String>{};
  for (var index = 0; index < value.length; index++) {
    final raw = value[index];
    if (raw is! String || raw.trim().isEmpty) {
      throw FormatException(
        'additional_directories[$index] must be a non-empty string.',
      );
    }
    final path = raw.trim();
    if (!File(path).isAbsolute) {
      throw FormatException(
        'additional_directories[$index] must be an absolute path.',
      );
    }
    if (seen.add(path)) directories.add(path);
  }
  return List.unmodifiable(directories);
}

Map<String, dynamic> _jsonMap(Map raw, {required String fieldName}) {
  final result = <String, dynamic>{};
  for (final entry in raw.entries) {
    final key = entry.key;
    if (key is! String) {
      throw FormatException('$fieldName keys must be strings.');
    }
    result[key] = _jsonValue(entry.value, fieldName: '$fieldName.$key');
  }
  return result;
}

Object? _jsonValue(Object? value, {required String fieldName}) {
  if (value == null || value is String || value is num || value is bool) {
    return value;
  }
  if (value is List) {
    return [
      for (var index = 0; index < value.length; index++)
        _jsonValue(value[index], fieldName: '$fieldName[$index]'),
    ];
  }
  if (value is Map) return _jsonMap(value, fieldName: fieldName);
  throw FormatException('$fieldName must be JSON-compatible.');
}

bool _boolConfigValue(Object? value, {required String fieldName}) {
  if (value == null) return false;
  if (value is bool) return value;
  throw FormatException('$fieldName must be a boolean.');
}

int? _positiveIntValue(Object? value, {required String fieldName}) {
  if (value == null) return null;
  if (value is int && value > 0) return value;
  throw FormatException('$fieldName must be a positive integer.');
}

void _ensureStringList(
  Map<String, dynamic> raw, {
  required String key,
  required String serverName,
}) {
  final value = raw[key];
  if (value == null) {
    raw[key] = const <String>[];
    return;
  }
  if (value is! List || value.any((item) => item is! String)) {
    throw FormatException(
      'MCP server "$serverName" $key must be a string list.',
    );
  }
}

void _ensureNameValueList(
  Map<String, dynamic> raw, {
  required String key,
  required String serverName,
}) {
  final value = raw[key];
  if (value == null) {
    raw[key] = const <Map<String, String>>[];
    return;
  }
  if (value is! List) {
    throw FormatException('MCP server "$serverName" $key must be a list.');
  }
  for (var index = 0; index < value.length; index++) {
    final item = value[index];
    if (item is! Map) {
      throw FormatException(
        'MCP server "$serverName" $key entry $index must be an object.',
      );
    }
    final name = item['name'];
    final itemValue = item['value'];
    if (name is! String || name.trim().isEmpty || itemValue is! String) {
      throw FormatException(
        'MCP server "$serverName" $key entry $index requires name and value.',
      );
    }
  }
}

void _ensureRemoteHeaderList(
  Map<String, dynamic> raw, {
  required String key,
  required String serverName,
}) {
  final value = raw[key];
  if (value == null) {
    raw[key] = const <Map<String, String>>[];
    return;
  }
  final headers = <Map<String, String>>[];
  if (value is Map) {
    for (final entry in value.entries) {
      final name = entry.key;
      final itemValue = entry.value;
      if (name is! String || itemValue is! String) {
        throw FormatException(
          'MCP server "$serverName" $key entries must be strings.',
        );
      }
      _validateHttpHeaderEntry(
        name: name,
        value: itemValue,
        fieldName: key,
        serverName: serverName,
      );
      headers.add(<String, String>{'name': name, 'value': itemValue});
    }
    raw[key] = headers;
    return;
  }
  if (value is! List) {
    throw FormatException(
      'MCP server "$serverName" $key must be an object or list.',
    );
  }
  for (var index = 0; index < value.length; index++) {
    final item = value[index];
    if (item is! Map) {
      throw FormatException(
        'MCP server "$serverName" $key entry $index must be an object.',
      );
    }
    final name = item['name'];
    final itemValue = item['value'];
    if (name is! String || itemValue is! String) {
      throw FormatException(
        'MCP server "$serverName" $key entry $index requires name and value.',
      );
    }
    _validateHttpHeaderEntry(
      name: name,
      value: itemValue,
      fieldName: key,
      serverName: serverName,
      index: index,
    );
    headers.add(<String, String>{'name': name, 'value': itemValue});
  }
  raw[key] = headers;
}

void _ensureHttpUrl(
  String url, {
  required String serverName,
  required String transportType,
}) {
  final uri = Uri.tryParse(url);
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
    throw FormatException(
      'MCP server "$serverName" $transportType transport url must use http or https.',
    );
  }
  if (uri.host.trim().isEmpty) {
    throw FormatException(
      'MCP server "$serverName" $transportType transport url requires host.',
    );
  }
}
