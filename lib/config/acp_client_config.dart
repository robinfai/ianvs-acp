import 'dart:convert';
import 'dart:io';

class AcpClientConfig {
  const AcpClientConfig({
    this.activeAgentServer,
    this.agentServers = const <AgentServerConfig>[],
    this.configPath,
    this.defaultAgentServerName,
  });

  static const String appConfigDirectoryName = 'ianvs-acp';
  static const String settingsFileName = 'settings.json';

  final AgentServerConfig? activeAgentServer;
  final List<AgentServerConfig> agentServers;
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
    final serversRaw = json['agent_servers'];
    if (serversRaw == null) {
      return AcpClientConfig(configPath: configPath);
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
      return AcpClientConfig(configPath: configPath);
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
