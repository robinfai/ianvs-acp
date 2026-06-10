import 'dart:convert';
import 'dart:io';

import 'acp_client_config.dart';

class AcpConfigStore {
  const AcpConfigStore._();

  static Future<AcpClientConfig> writeConfig({
    required AcpClientConfig config,
    String? configPath,
  }) async {
    final path = (configPath ?? config.configPath)?.trim();
    if (path == null || path.isEmpty) {
      throw const FormatException('ACP config path is not available.');
    }

    final file = File(path);
    final raw = await _readExistingJson(file);
    for (final key in _managedConfigKeys) {
      raw.remove(key);
    }
    final canonicalJson = <String, dynamic>{...raw, ...toSettingsJson(config)};

    await file.parent.create(recursive: true);
    const encoder = JsonEncoder.withIndent('  ');
    await file.writeAsString('${encoder.convert(canonicalJson)}\n');
    return AcpClientConfig.fromJson(canonicalJson, configPath: path);
  }

  static Map<String, Object?> toSettingsJson(AcpClientConfig config) {
    final servers = _agentServers(config);
    final clientProviders = config.clientProviders.toJson();
    return <String, Object?>{
      if (config.defaultAgentServerName?.trim().isNotEmpty == true)
        'default_agent_server': config.defaultAgentServerName!.trim(),
      if (servers.isNotEmpty)
        'agent_servers': <String, Object?>{
          for (final server in servers) server.name: server.toJson(),
        },
      if (config.mcpServers.isNotEmpty)
        'mcp_servers': config.mcpServers
            .map((server) => server.toJson())
            .toList(growable: false),
      if (config.additionalDirectories.isNotEmpty)
        'additional_directories': config.additionalDirectories,
      if (clientProviders.isNotEmpty) 'client_providers': clientProviders,
      'memory': config.memory.toJson(),
    };
  }

  static Future<Map<String, dynamic>> _readExistingJson(File file) async {
    if (!await file.exists()) return <String, dynamic>{};
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('ACP config root must be a JSON object.');
    }
    return Map<String, dynamic>.from(decoded);
  }

  static List<AgentServerConfig> _agentServers(AcpClientConfig config) {
    final source = config.agentServers.isNotEmpty
        ? config.agentServers
        : config.activeAgentServer == null
        ? const <AgentServerConfig>[]
        : <AgentServerConfig>[config.activeAgentServer!];
    final result = <AgentServerConfig>[];
    final seen = <String>{};
    for (final server in source) {
      if (seen.add(server.name)) result.add(server);
    }
    return List.unmodifiable(result);
  }
}

const Set<String> _managedConfigKeys = <String>{
  'default_agent_server',
  'defaultAgentServer',
  'agent_servers',
  'agentServers',
  'mcp_servers',
  'mcpServers',
  'additional_directories',
  'additionalDirectories',
  'client_providers',
  'clientProviders',
  'memory',
  'memoryConfig',
};
