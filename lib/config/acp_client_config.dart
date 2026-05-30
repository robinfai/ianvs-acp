import 'dart:convert';
import 'dart:io';

class AcpClientConfig {
  const AcpClientConfig({
    this.activeAgentServer,
    this.agentServers = const <AgentServerConfig>[],
    this.mcpServers = const <McpServerConfig>[],
    this.clientProviders = const AcpClientProviderConfig(),
    this.configPath,
    this.defaultAgentServerName,
  });

  static const String appConfigDirectoryName = 'ianvs-acp';
  static const String settingsFileName = 'settings.json';

  final AgentServerConfig? activeAgentServer;
  final List<AgentServerConfig> agentServers;
  final List<McpServerConfig> mcpServers;
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
    final clientProviders = AcpClientProviderConfig.fromJson(
      json['client_providers'] ?? json['clientProviders'],
    );
    final serversRaw = json['agent_servers'];
    if (serversRaw == null) {
      return AcpClientConfig(
        configPath: configPath,
        mcpServers: mcpServers,
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
        clientProviders: clientProviders,
      );
    }

    final preferredName = _stringValue(json['default_agent_server']);
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
  });

  final AcpFilesystemProviderConfig filesystem;

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
    );
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
}

class AgentServerConfig {
  const AgentServerConfig({
    required this.name,
    required this.type,
    required this.command,
    this.args = const <String>[],
    this.env = const <String, String>{},
  });

  final String name;
  final String type;
  final String command;
  final List<String> args;
  final Map<String, String> env;

  factory AgentServerConfig.fromJson({
    required String name,
    required Map<String, dynamic> json,
  }) {
    final type = _stringValue(json['type']) ?? 'custom';
    if (type != 'custom') {
      throw FormatException('Unsupported agent server type "$type".');
    }

    final command = _stringValue(json['command']);
    if (command == null || command.isEmpty) {
      throw FormatException('Agent server "$name" requires command.');
    }

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
      args: args,
      env: env,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'type': type,
      'command': command,
      if (args.isNotEmpty) 'args': args,
      if (env.isNotEmpty) 'env': env,
    };
  }
}

class McpServerConfig {
  const McpServerConfig({required this.raw});

  final Map<String, dynamic> raw;

  String get name => _stringValue(raw['name']) ?? 'MCP server';

  String get type =>
      _stringValue(raw['type']) ?? (url.isEmpty ? 'stdio' : 'http');

  String get command => _stringValue(raw['command']) ?? '';

  String get url => _stringValue(raw['url']) ?? '';

  Map<String, dynamic> toJson() => _jsonMap(raw, fieldName: 'mcp_servers');

  factory McpServerConfig.fromJson({required int index, required Map json}) {
    final raw = _jsonMap(json, fieldName: 'mcp_servers[$index]');
    final name = _stringValue(raw['name']);
    if (name == null) {
      throw FormatException('MCP server at index $index requires name.');
    }

    final type = _stringValue(raw['type']);
    final command = _stringValue(raw['command']);
    final url = _stringValue(raw['url']);
    if (type != null && !_supportedMcpTransportTypes.contains(type)) {
      throw FormatException(
        'MCP server "$name" type must be one of: '
        '${_supportedMcpTransportTypes.join(', ')}.',
      );
    }
    if (command == null && url == null) {
      throw FormatException('MCP server "$name" requires command or url.');
    }
    if ((type == 'http' || type == 'sse') || (command == null && url != null)) {
      _ensureNameValueList(raw, key: 'headers', serverName: name);
    } else {
      _ensureStringList(raw, key: 'args', serverName: name);
      _ensureNameValueList(raw, key: 'env', serverName: name);
    }

    return McpServerConfig(raw: raw);
  }
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
