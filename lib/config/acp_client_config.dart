import 'dart:convert';
import 'dart:io';

class AcpClientConfig {
  const AcpClientConfig({this.activeAgentServer});

  final AgentServerConfig? activeAgentServer;

  String get agentName => activeAgentServer?.name ?? 'Codex';

  static Future<AcpClientConfig> load({
    String? path,
    Map<String, String>? environment,
  }) async {
    final configPath = path ?? resolveConfigPath(environment: environment);
    if (configPath == null || configPath.trim().isEmpty) {
      return const AcpClientConfig();
    }

    final file = File(configPath);
    if (!await file.exists()) {
      return const AcpClientConfig();
    }

    final raw = jsonDecode(await file.readAsString());
    if (raw is! Map<String, dynamic>) {
      throw const FormatException('ACP config root must be a JSON object.');
    }
    return AcpClientConfig.fromJson(raw);
  }

  factory AcpClientConfig.fromJson(Map<String, dynamic> json) {
    final serversRaw = json['agent_servers'];
    if (serversRaw == null) {
      return const AcpClientConfig();
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
      return const AcpClientConfig();
    }

    final preferredName =
        _stringValue(json['default_agent_server']) ??
        _stringValue(json['active_agent_server']);
    final active = preferredName == null
        ? servers.values.first
        : servers[preferredName];
    if (active == null) {
      throw FormatException('Unknown default agent server "$preferredName".');
    }
    return AcpClientConfig(activeAgentServer: active);
  }

  static String? resolveConfigPath({Map<String, String>? environment}) {
    const dartDefinePath = String.fromEnvironment('ACP_CONFIG_PATH');
    if (dartDefinePath.trim().isNotEmpty) return dartDefinePath.trim();

    final env = environment ?? Platform.environment;
    final envPath = env['ACP_CONFIG_PATH'] ?? env['IANVS_ACP_CONFIG'];
    if (envPath != null && envPath.trim().isNotEmpty) {
      return envPath.trim();
    }

    final home = env['HOME'];
    if (home == null || home.trim().isEmpty) return null;
    return '${home.trim()}/.ianvs_acp/config.json';
  }
}

class AgentServerConfig {
  const AgentServerConfig({
    required this.name,
    required this.type,
    required this.command,
    this.args = const <String>[],
  });

  final String name;
  final String type;
  final String command;
  final List<String> args;

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

    return AgentServerConfig(
      name: name,
      type: type,
      command: command,
      args: args,
    );
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
