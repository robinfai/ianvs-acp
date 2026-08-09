import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../acp/acp_adapter_packages.dart';
import '../acp/acp_endpoint_validator.dart';
import '../acp/acp_permission_request.dart';
import '../storage/sqlite_storage_config.dart';
import 'assistant_agent_config.dart';
import 'secret_field_policy.dart';

class AcpClientConfig {
  const AcpClientConfig({
    this.activeAgentServer,
    this.agentServers = const <AgentServerConfig>[],
    this.mcpServers = const <McpServerConfig>[],
    this.additionalDirectories = const <String>[],
    this.clientProviders = const AcpClientProviderConfig(),
    this.storage = const SqliteStorageConfig(),
    this.assistantAgent = const AssistantAgentConfig(),
    this.configPath,
    this.defaultAgentServerName,
    this.runtimeSecretGeneration = 0,
  });

  static const String appConfigDirectoryName = 'ianvs-acp';
  static const String settingsFileName = 'settings.json';

  final AgentServerConfig? activeAgentServer;
  final List<AgentServerConfig> agentServers;
  final List<McpServerConfig> mcpServers;
  final List<String> additionalDirectories;
  final AcpClientProviderConfig clientProviders;
  final SqliteStorageConfig storage;
  final AssistantAgentConfig assistantAgent;
  final String? configPath;
  final String? defaultAgentServerName;

  /// Opaque in-memory revision used to invalidate clients after resolving or
  /// changing secrets. It is never serialized to settings JSON.
  final int runtimeSecretGeneration;

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

  AgentServerConfig? agentServerWithPersistenceIdentity(String identity) {
    final trimmed = identity.trim();
    if (trimmed.isEmpty) return null;
    for (final server in selectableAgentServers) {
      if (server.persistenceIdentity == trimmed) return server;
    }
    return null;
  }

  AgentServerConfig? agentServerWithPersistenceAlias(String alias) {
    final trimmed = alias.trim();
    if (trimmed.isEmpty) return null;
    AgentServerConfig? match;
    for (final server in selectableAgentServers) {
      if (!server.persistenceNames.contains(trimmed)) continue;
      if (match != null &&
          match.persistenceIdentity != server.persistenceIdentity) {
        return null;
      }
      match = server;
    }
    return match;
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
      storage: storage,
      assistantAgent: assistantAgent,
      configPath: configPath,
      defaultAgentServerName: defaultAgentServerName,
      runtimeSecretGeneration: runtimeSecretGeneration,
    );
  }

  AcpClientConfig normalizedAgentPersistenceNamespace() {
    final source = selectableAgentServers;
    if (source.isEmpty) return this;
    final normalized = _normalizedAgentPersistenceNamespace(source);
    final activeName = activeAgentServer?.name;
    final normalizedActive = activeName == null
        ? null
        : normalized.where((server) => server.name == activeName).firstOrNull;
    return AcpClientConfig(
      activeAgentServer: normalizedActive,
      agentServers: agentServers.isEmpty ? const [] : normalized,
      mcpServers: mcpServers,
      additionalDirectories: additionalDirectories,
      clientProviders: clientProviders,
      storage: storage,
      assistantAgent: assistantAgent,
      configPath: configPath,
      defaultAgentServerName: defaultAgentServerName,
      runtimeSecretGeneration: runtimeSecretGeneration,
    );
  }

  AcpClientConfig? configForSessionIndexAgent(String? name) {
    final trimmed = name?.trim();
    if (trimmed == null || trimmed.isEmpty) return this;
    final persistedServer = agentServerWithPersistenceIdentity(trimmed);
    if (persistedServer != null) {
      if (activeAgentServer?.persistenceIdentity ==
          persistedServer.persistenceIdentity) {
        return this;
      }
      return withActiveAgentServer(persistedServer.name);
    }
    if (activeAgentServer != null && agentName == trimmed) return this;
    if (agentServerNamed(trimmed) != null) {
      return withActiveAgentServer(trimmed);
    }
    final aliasedServer = agentServerWithPersistenceAlias(trimmed);
    if (aliasedServer != null) {
      return withActiveAgentServer(aliasedServer.name);
    }
    if (AcpAdapterPackages.isPiAgentAlias(trimmed)) {
      final matches = selectableAgentServers
          .where(
            (server) => AcpAdapterPackages.isPiAdapterInvocation(
              command: server.command,
              args: server.args,
            ),
          )
          .toList(growable: false);
      if (matches.length == 1) {
        final match = matches.single;
        if (activeAgentServer?.name == match.name) return this;
        return withActiveAgentServer(match.name);
      }
    }
    if (activeAgentServer == null &&
        selectableAgentServers.isEmpty &&
        agentName == trimmed) {
      return this;
    }
    return null;
  }

  static Future<AcpClientConfig> load({
    String? path,
    Map<String, String>? environment,
  }) async {
    final requestedPath = path ?? resolveConfigPath(environment: environment);
    if (requestedPath == null || requestedPath.trim().isEmpty) {
      return AcpClientConfig(configPath: requestedPath);
    }
    final configPath = _absoluteFilePath(requestedPath);

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
      _aliasedValue(json, const <String>[
        'mcp_servers',
        'mcpServers',
      ], fieldName: 'mcp_servers'),
    );
    final additionalDirectories = _additionalDirectories(
      _aliasedValue(json, const <String>[
        'additional_directories',
        'additionalDirectories',
      ], fieldName: 'additional_directories'),
    );
    final clientProviders = AcpClientProviderConfig.fromJson(
      _aliasedValue(json, const <String>[
        'client_providers',
        'clientProviders',
      ], fieldName: 'client_providers'),
    );
    final storage = SqliteStorageConfig.fromJson(
      _aliasedValue(json, const <String>[
        'storage',
        'sqliteStorage',
      ], fieldName: 'storage'),
    );
    final assistantAgent = AssistantAgentConfig.fromJson(
      _aliasedValue(json, const <String>[
        'assistant_agent',
        'assistantAgent',
      ], fieldName: 'assistant_agent'),
    );
    final serversRaw = _aliasedValue(json, const <String>[
      'agent_servers',
      'agentServers',
    ], fieldName: 'agent_servers');
    if (serversRaw == null) {
      return AcpClientConfig(
        configPath: configPath,
        mcpServers: mcpServers,
        additionalDirectories: additionalDirectories,
        clientProviders: clientProviders,
        storage: storage,
        assistantAgent: assistantAgent,
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
        storage: storage,
        assistantAgent: assistantAgent,
      );
    }

    final normalizedServers = _normalizedAgentPersistenceNamespace(
      servers.values,
    );
    final normalizedByName = <String, AgentServerConfig>{
      for (final server in normalizedServers) server.name: server,
    };
    final preferredName = _stringValue(
      _aliasedValue(json, const <String>[
        'default_agent_server',
        'defaultAgentServer',
      ], fieldName: 'default_agent_server'),
    );
    final active = preferredName == null
        ? normalizedServers.first
        : normalizedByName[preferredName];
    if (active == null) {
      throw FormatException('Unknown default agent server "$preferredName".');
    }
    return AcpClientConfig(
      activeAgentServer: active,
      agentServers: normalizedServers,
      mcpServers: mcpServers,
      additionalDirectories: additionalDirectories,
      clientProviders: clientProviders,
      storage: storage,
      assistantAgent: assistantAgent,
      configPath: configPath,
      defaultAgentServerName: preferredName,
    );
  }

  static String? resolveConfigPath({Map<String, String>? environment}) {
    const dartDefinePath = String.fromEnvironment('ACP_CONFIG_PATH');
    if (dartDefinePath.trim().isNotEmpty) {
      return _absoluteFilePath(dartDefinePath);
    }

    final env = environment ?? Platform.environment;
    final envPath = env['ACP_CONFIG_PATH'] ?? env['IANVS_ACP_CONFIG'];
    if (envPath != null && envPath.trim().isNotEmpty) {
      return _absoluteFilePath(envPath);
    }

    final xdgConfigHome = env['XDG_CONFIG_HOME'];
    if (xdgConfigHome != null && xdgConfigHome.trim().isNotEmpty) {
      return _absoluteFilePath(
        '${xdgConfigHome.trim()}/$appConfigDirectoryName/$settingsFileName',
      );
    }

    final home = env['HOME'];
    if (home == null || home.trim().isEmpty) return null;
    return _absoluteFilePath(
      '${home.trim()}/.config/$appConfigDirectoryName/$settingsFileName',
    );
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

String _absoluteFilePath(String path) {
  return File.fromUri(File(path.trim()).absolute.uri.normalizePath()).path;
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
        _aliasedValue(map, const <String>[
          'filesystem',
          'fs',
        ], fieldName: 'client_providers.filesystem'),
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
    final rulesRaw = _aliasedValue(map, const <String>[
      'trust_rules',
      'trustRules',
      'rules',
    ], fieldName: 'client_providers.permissions.trust_rules');
    final reviewAgent = AcpPermissionReviewAgentConfig.fromJson(
      _aliasedValue(map, const <String>[
        'review_agent',
        'reviewAgent',
        'approval_agent',
      ], fieldName: 'client_providers.permissions.review_agent'),
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
    final mcpServerRaw = _aliasedValue(map, const <String>[
      'mcp_server',
      'mcpServer',
    ], fieldName: 'client_providers.permissions.review_agent.mcp_server');
    final mcpServer = mcpServerRaw == null
        ? null
        : _permissionReviewMcpServer(mcpServerRaw);
    final mcpServerName = _stringValue(
      _aliasedValue(
        map,
        const <String>['mcp_server_name', 'mcpServerName', 'server_name'],
        fieldName: 'client_providers.permissions.review_agent.mcp_server_name',
      ),
    );
    if (mcpServer != null && mcpServerName != null) {
      throw const FormatException(
        'client_providers.permissions.review_agent must define either mcp_server or mcp_server_name, not both.',
      );
    }
    final toolName =
        _stringValue(
          _aliasedValue(map, const <String>[
            'tool_name',
            'toolName',
          ], fieldName: 'client_providers.permissions.review_agent.tool_name'),
        ) ??
        'review_permission';
    final timeoutMs = _positiveIntValue(
      _aliasedValue(map, const <String>[
        'timeout_ms',
        'timeoutMs',
      ], fieldName: 'client_providers.permissions.review_agent.timeout_ms'),
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

  Map<String, Object?> toRuntimeJson() {
    return <String, Object?>{
      ...toJson(),
      if (mcpServer != null) 'mcp_server': mcpServer!.toRuntimeJson(),
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
    this.persistenceId,
    this.persistenceAliases = const <String>[],
    this.command = '',
    this.cwd,
    this.url = '',
    this.args = const <String>[],
    this.env = const <String, String>{},
    this.headers = const <String, String>{},
    this.envRefs = const <String, String>{},
    this.headerRefs = const <String, String>{},
    this.explicitEnvKeys = const <String>{},
    this.explicitHeaderKeys = const <String>{},
    this.secretRefsResolved = true,
    this.additionalProperties = const <String, dynamic>{},
    this.permissionReviewAgent = const AcpPermissionReviewAgentConfig(),
  });

  final String name;
  final String type;
  final String? persistenceId;
  final List<String> persistenceAliases;
  final String command;
  final String? cwd;
  final String url;
  final List<String> args;
  final Map<String, String> env;
  final Map<String, String> headers;
  final Map<String, String> envRefs;
  final Map<String, String> headerRefs;
  final Set<String> explicitEnvKeys;
  final Set<String> explicitHeaderKeys;
  final bool secretRefsResolved;
  final Map<String, dynamic> additionalProperties;
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

  String get persistenceIdentity => _resolvedAgentPersistenceIdentity(
    configured: persistenceId ?? additionalProperties['persistence_id'],
    migrationName: name,
    type: type,
    command: command,
    cwd: cwd,
    url: url,
    args: args,
    environmentKeys: <String>{...env.keys, ...envRefs.keys},
    headerKeys: <String>{...headers.keys, ...headerRefs.keys},
    additionalProperties: additionalProperties,
  );

  List<String> get persistenceNames =>
      _resolvedAgentPersistenceAliases(persistenceAliases, currentName: name);

  factory AgentServerConfig.fromJson({
    required String name,
    required Map<String, dynamic> json,
  }) {
    final type = (_stringValue(json['type']) ?? 'custom').trim().toLowerCase();
    final configuredPersistenceIdentity = _persistenceIdentityValue(
      _aliasedValue(json, const <String>[
        'persistence_id',
        'persistenceIdentity',
      ], fieldName: 'persistence_id'),
    );
    final persistenceAliases = _resolvedAgentPersistenceAliases(
      _persistenceAliasesValue(
        _aliasedValue(json, const <String>[
          'persistence_aliases',
          'persistenceAliases',
        ], fieldName: 'persistence_aliases'),
      ),
      currentName: name,
    );
    final envRefs = _secretReferenceMapFromAliases(
      json['env_refs'],
      json['envRefs'],
      fieldName: 'env_refs',
      serverName: name,
    );
    final headerRefs = _secretReferenceMapFromAliases(
      json['header_refs'],
      json['headerRefs'],
      fieldName: 'header_refs',
      serverName: name,
    );
    final additionalProperties = Map<String, dynamic>.from(json);
    for (final key in _agentServerManagedKeys) {
      additionalProperties.remove(key);
    }
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
      final persistenceIdentity = _resolvedAgentPersistenceIdentity(
        configured: configuredPersistenceIdentity,
        migrationName: name,
        type: type,
        command: '',
        cwd: null,
        url: url,
        args: const <String>[],
        environmentKeys: envRefs.keys,
        headerKeys: <String>{...headers.keys, ...headerRefs.keys},
        additionalProperties: additionalProperties,
      );
      additionalProperties['persistence_id'] = persistenceIdentity;
      additionalProperties['persistence_aliases'] = persistenceAliases;
      return AgentServerConfig(
        name: name,
        type: type,
        persistenceId: persistenceIdentity,
        persistenceAliases: persistenceAliases,
        url: url,
        headers: headers,
        envRefs: envRefs,
        headerRefs: headerRefs,
        explicitHeaderKeys: Set.unmodifiable(headers.keys),
        secretRefsResolved: envRefs.isEmpty && headerRefs.isEmpty,
        additionalProperties: additionalProperties,
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
      final persistenceIdentity = _resolvedAgentPersistenceIdentity(
        configured: configuredPersistenceIdentity,
        migrationName: name,
        type: type,
        command: '',
        cwd: null,
        url: url,
        args: const <String>[],
        environmentKeys: envRefs.keys,
        headerKeys: <String>{...headers.keys, ...headerRefs.keys},
        additionalProperties: additionalProperties,
      );
      additionalProperties['persistence_id'] = persistenceIdentity;
      additionalProperties['persistence_aliases'] = persistenceAliases;
      return AgentServerConfig(
        name: name,
        type: type,
        persistenceId: persistenceIdentity,
        persistenceAliases: persistenceAliases,
        url: url,
        headers: headers,
        envRefs: envRefs,
        headerRefs: headerRefs,
        explicitHeaderKeys: Set.unmodifiable(headers.keys),
        secretRefsResolved: envRefs.isEmpty && headerRefs.isEmpty,
        additionalProperties: additionalProperties,
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

    final persistenceIdentity = _resolvedAgentPersistenceIdentity(
      configured: configuredPersistenceIdentity,
      migrationName: name,
      type: type,
      command: command,
      cwd: cwd,
      url: '',
      args: args,
      environmentKeys: <String>{...env.keys, ...envRefs.keys},
      headerKeys: headerRefs.keys,
      additionalProperties: additionalProperties,
    );
    additionalProperties['persistence_id'] = persistenceIdentity;
    additionalProperties['persistence_aliases'] = persistenceAliases;

    return AgentServerConfig(
      name: name,
      type: type,
      persistenceId: persistenceIdentity,
      persistenceAliases: persistenceAliases,
      command: command,
      cwd: cwd,
      args: args,
      env: env,
      envRefs: envRefs,
      headerRefs: headerRefs,
      explicitEnvKeys: Set.unmodifiable(env.keys),
      secretRefsResolved: envRefs.isEmpty && headerRefs.isEmpty,
      additionalProperties: additionalProperties,
      permissionReviewAgent: _agentPermissionReviewAgent(json),
    );
  }

  Map<String, Object?> toJson() {
    final plainEnv = _valuesWithoutReferences(
      env,
      envRefs,
      field: ConfigSecretField.environment,
    );
    final plainHeaders = _valuesWithoutReferences(
      headers,
      headerRefs,
      field: ConfigSecretField.header,
    );
    return <String, Object?>{
      ...additionalProperties,
      'persistence_id': persistenceIdentity,
      'persistence_aliases': persistenceNames,
      'type': type,
      if (command.isNotEmpty) 'command': command,
      if (cwd != null) 'cwd': cwd,
      if (url.isNotEmpty) 'url': url,
      if (args.isNotEmpty) 'args': args,
      if (plainEnv.isNotEmpty) 'env': plainEnv,
      if (plainHeaders.isNotEmpty) 'headers': plainHeaders,
      if (envRefs.isNotEmpty) 'env_refs': envRefs,
      if (headerRefs.isNotEmpty) 'header_refs': headerRefs,
      if (permissionReviewAgent.isConfigured)
        'review_agent': permissionReviewAgent.toJson(),
    };
  }

  Map<String, Object?> toRuntimeJson() {
    final json = <String, Object?>{
      ...toJson(),
      if (env.isNotEmpty) 'env': env,
      if (headers.isNotEmpty) 'headers': headers,
      if (permissionReviewAgent.isConfigured)
        'review_agent': permissionReviewAgent.toRuntimeJson(),
    };
    json.remove('env_refs');
    json.remove('envRefs');
    json.remove('header_refs');
    json.remove('headerRefs');
    return json;
  }

  AgentServerConfig withSecrets({
    required Map<String, String> env,
    required Map<String, String> headers,
    required Map<String, String> envRefs,
    required Map<String, String> headerRefs,
    Set<String>? explicitEnvKeys,
    Set<String>? explicitHeaderKeys,
    AcpPermissionReviewAgentConfig? permissionReviewAgent,
  }) {
    return AgentServerConfig(
      name: name,
      type: type,
      persistenceId: persistenceIdentity,
      persistenceAliases: persistenceNames,
      command: command,
      cwd: cwd,
      url: url,
      args: args,
      env: Map.unmodifiable(env),
      headers: Map.unmodifiable(headers),
      envRefs: Map.unmodifiable(envRefs),
      headerRefs: Map.unmodifiable(headerRefs),
      explicitEnvKeys: Set.unmodifiable(
        explicitEnvKeys ?? this.explicitEnvKeys,
      ),
      explicitHeaderKeys: Set.unmodifiable(
        explicitHeaderKeys ?? this.explicitHeaderKeys,
      ),
      secretRefsResolved: true,
      additionalProperties: additionalProperties,
      permissionReviewAgent:
          permissionReviewAgent ?? this.permissionReviewAgent,
    );
  }

  AgentServerConfig withPersistenceAliases(List<String> aliases) {
    return AgentServerConfig(
      name: name,
      type: type,
      persistenceId: persistenceIdentity,
      persistenceAliases: List<String>.unmodifiable(aliases),
      command: command,
      cwd: cwd,
      url: url,
      args: args,
      env: env,
      headers: headers,
      envRefs: envRefs,
      headerRefs: headerRefs,
      explicitEnvKeys: explicitEnvKeys,
      explicitHeaderKeys: explicitHeaderKeys,
      secretRefsResolved: secretRefsResolved,
      additionalProperties: additionalProperties,
      permissionReviewAgent: permissionReviewAgent,
    );
  }
}

List<AgentServerConfig> _normalizedAgentPersistenceNamespace(
  Iterable<AgentServerConfig> configured,
) {
  final servers = configured.toList(growable: false);
  final identityOwners = <String, String>{};
  final canonicalOwners = <String, String>{};

  void claimCanonical(String token, AgentServerConfig server) {
    final existing = canonicalOwners[token];
    if (existing != null && existing != server.name) {
      throw FormatException(
        'Agent persistence token "$token" is owned by both "$existing" '
        'and "${server.name}".',
      );
    }
    canonicalOwners[token] = server.name;
  }

  for (final server in servers) {
    final identity = server.persistenceIdentity;
    final identityOwner = identityOwners[identity];
    if (identityOwner != null && identityOwner != server.name) {
      throw FormatException(
        'Agent persistence_id "$identity" is shared by "$identityOwner" '
        'and "${server.name}".',
      );
    }
    identityOwners[identity] = server.name;
    claimCanonical(identity, server);
    claimCanonical(server.name, server);
  }

  final aliasOwners = <String, Set<String>>{};
  for (final server in servers) {
    for (final alias in server.persistenceNames) {
      aliasOwners.putIfAbsent(alias, () => <String>{}).add(server.name);
    }
  }

  return List<AgentServerConfig>.unmodifiable(
    servers.map((server) {
      final filtered = <String>[
        for (final alias in server.persistenceNames)
          if (canonicalOwners[alias] == server.name ||
              (canonicalOwners[alias] == null &&
                  aliasOwners[alias]?.length == 1))
            alias,
      ];
      return server.withPersistenceAliases(filtered);
    }),
  );
}

const Set<String> _agentServerManagedKeys = <String>{
  'persistence_id',
  'persistenceIdentity',
  'persistence_aliases',
  'persistenceAliases',
  'type',
  'command',
  'cwd',
  'working_directory',
  'workingDirectory',
  'url',
  'args',
  'env',
  'headers',
  'env_refs',
  'envRefs',
  'header_refs',
  'headerRefs',
  'review_agent',
  'reviewAgent',
  'permissions',
};

String? _persistenceIdentityValue(Object? raw) {
  if (raw == null) return null;
  if (raw is! String || !_isCanonicalPersistenceText(raw)) {
    throw const FormatException(
      'persistence_id must be canonical non-empty text up to 256 UTF-8 bytes.',
    );
  }
  return raw;
}

List<String> _persistenceAliasesValue(Object? raw) {
  if (raw == null) return const <String>[];
  if (raw is! List) {
    throw const FormatException('persistence_aliases must be a string list.');
  }
  final aliases = <String>[];
  for (final value in raw) {
    if (value is! String || !_isCanonicalPersistenceText(value)) {
      throw const FormatException(
        'persistence_aliases entries must be canonical non-empty text up to '
        '256 UTF-8 bytes.',
      );
    }
    if (!aliases.contains(value)) aliases.add(value);
  }
  return List<String>.unmodifiable(aliases);
}

List<String> _resolvedAgentPersistenceAliases(
  Iterable<String> configured, {
  required String currentName,
}) {
  final aliases = <String>[];
  for (final alias in configured) {
    if (!_isCanonicalPersistenceText(alias)) {
      throw const FormatException(
        'persistence_aliases entries must be canonical non-empty text up to '
        '256 UTF-8 bytes.',
      );
    }
    if (!aliases.contains(alias)) aliases.add(alias);
  }
  final canonicalName = currentName.trim();
  if (canonicalName.isNotEmpty) {
    if (!_isCanonicalPersistenceText(canonicalName)) {
      throw const FormatException(
        'Agent names used for persistence must fit in 256 UTF-8 bytes.',
      );
    }
    aliases.remove(canonicalName);
    aliases.add(canonicalName);
  }
  const maxAliasCount = 64;
  if (aliases.length > maxAliasCount) {
    aliases.removeRange(0, aliases.length - maxAliasCount);
  }
  return List<String>.unmodifiable(aliases);
}

bool _isCanonicalPersistenceText(String value) =>
    value.isNotEmpty &&
    value.trim() == value &&
    !value.contains('\u0000') &&
    utf8.encode(value).length <= 256;

String _resolvedAgentPersistenceIdentity({
  required Object? configured,
  required String migrationName,
  required String type,
  required String command,
  required String? cwd,
  required String url,
  required List<String> args,
  required Iterable<String> environmentKeys,
  required Iterable<String> headerKeys,
  required Map<String, dynamic> additionalProperties,
}) {
  final explicit = _persistenceIdentityValue(configured);
  if (explicit != null) return explicit;
  final envKeys = environmentKeys.toSet().toList()..sort();
  final headers = headerKeys.toSet().toList()..sort();
  final properties = <String, Object?>{
    for (final entry in additionalProperties.entries)
      if (entry.key != 'persistence_id' &&
          entry.key != 'persistenceIdentity' &&
          entry.key != 'persistence_aliases' &&
          entry.key != 'persistenceAliases')
        entry.key: entry.value,
  };
  final canonical = _canonicalAgentIdentityJson(<String, Object?>{
    'migrationName': migrationName.trim(),
    'type': type.trim().toLowerCase(),
    'command': command.trim(),
    'cwd': cwd?.trim(),
    'url': url.trim(),
    'args': args,
    'environmentKeys': envKeys,
    'headerKeys': headers,
    'properties': properties,
  });
  final digest = sha256.convert(utf8.encode(jsonEncode(canonical)));
  return 'agent-$digest';
}

Object? _canonicalAgentIdentityJson(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((key) => key.toString()).toList()..sort();
    return <String, Object?>{
      for (final key in keys) key: _canonicalAgentIdentityJson(value[key]),
    };
  }
  if (value is List) {
    return value.map(_canonicalAgentIdentityJson).toList(growable: false);
  }
  return value;
}

class McpServerConfig {
  const McpServerConfig({
    required this.raw,
    this.envRefs = const <String, String>{},
    this.headerRefs = const <String, String>{},
    this.explicitEnvKeys = const <String>{},
    this.explicitHeaderKeys = const <String>{},
    this.secretRefsResolved = true,
  });

  final Map<String, dynamic> raw;
  final Map<String, String> envRefs;
  final Map<String, String> headerRefs;
  final Set<String> explicitEnvKeys;
  final Set<String> explicitHeaderKeys;
  final bool secretRefsResolved;

  Map<String, String> get env => _runtimeSecretMap(raw['env']);

  Map<String, String> get headers => _runtimeSecretMap(raw['headers']);

  String get name => _stringValue(raw['name']) ?? 'MCP server';

  String get type =>
      _stringValue(raw['type'])?.toLowerCase() ??
      (url.isEmpty ? 'stdio' : 'http');

  String get command => _stringValue(raw['command']) ?? '';

  String get url => _stringValue(raw['url']) ?? '';

  String get id =>
      _stringValue(raw['serverId']) ?? _stringValue(raw['id']) ?? '';

  String get serverId => id;

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

  Map<String, dynamic> toJson() {
    final json = _jsonMap(raw, fieldName: 'mcp_servers');
    final plainEnv = _valuesWithoutReferences(
      env,
      envRefs,
      field: ConfigSecretField.environment,
    );
    final plainHeaders = _valuesWithoutReferences(
      headers,
      headerRefs,
      field: ConfigSecretField.header,
    );
    json.remove('env');
    json.remove('headers');
    json.remove('envRefs');
    json.remove('headerRefs');
    if (plainEnv.isNotEmpty) {
      json['env'] = <Map<String, String>>[
        for (final entry in plainEnv.entries)
          <String, String>{'name': entry.key, 'value': entry.value},
      ];
    }
    if (plainHeaders.isNotEmpty) {
      json['headers'] = <Map<String, String>>[
        for (final entry in plainHeaders.entries)
          <String, String>{'name': entry.key, 'value': entry.value},
      ];
    }
    if (envRefs.isNotEmpty) {
      json['env_refs'] = Map<String, String>.from(envRefs);
    }
    if (headerRefs.isNotEmpty) {
      json['header_refs'] = Map<String, String>.from(headerRefs);
    }
    return json;
  }

  Map<String, dynamic> toRuntimeJson() {
    final json = _jsonMap(raw, fieldName: 'mcp_servers');
    json.remove('env_refs');
    json.remove('envRefs');
    json.remove('header_refs');
    json.remove('headerRefs');
    return json;
  }

  factory McpServerConfig.fromJson({required int index, required Map json}) {
    final raw = _jsonMap(json, fieldName: 'mcp_servers[$index]');
    final explicitEnvKeys = Set<String>.unmodifiable(
      _runtimeSecretMap(raw['env']).keys,
    );
    final explicitHeaderKeys = Set<String>.unmodifiable(
      _runtimeSecretMap(raw['headers']).keys,
    );
    final name = _stringValue(raw['name']);
    if (name == null) {
      throw FormatException('MCP server at index $index requires name.');
    }

    final type = _stringValue(raw['type'])?.toLowerCase();
    if (type != null) raw['type'] = type;
    final command = _stringValue(raw['command']);
    final url = _stringValue(raw['url']);
    final id = _stringValue(raw['serverId'] ?? raw['id']);
    if (type != null && !_supportedMcpTransportTypes.contains(type)) {
      throw FormatException(
        'MCP server "$name" type must be one of: '
        '${_supportedMcpTransportTypes.join(', ')}.',
      );
    }
    if (type == 'acp') {
      if (id == null) {
        throw FormatException(
          'MCP server "$name" acp transport requires serverId.',
        );
      }
      if (command != null || url != null) {
        throw FormatException(
          'MCP server "$name" acp transport must not define command or url.',
        );
      }
      raw.remove('id');
      raw['serverId'] = id;
      return McpServerConfig(
        raw: raw,
        envRefs: _removeSecretReferenceAliases(
          raw,
          snakeKey: 'env_refs',
          camelKey: 'envRefs',
          fieldName: 'env_refs',
          serverName: name,
        ),
        headerRefs: _removeSecretReferenceAliases(
          raw,
          snakeKey: 'header_refs',
          camelKey: 'headerRefs',
          fieldName: 'header_refs',
          serverName: name,
        ),
        explicitEnvKeys: explicitEnvKeys,
        explicitHeaderKeys: explicitHeaderKeys,
        secretRefsResolved: false,
      );
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

    final envRefs = _removeSecretReferenceAliases(
      raw,
      snakeKey: 'env_refs',
      camelKey: 'envRefs',
      fieldName: 'env_refs',
      serverName: name,
    );
    final headerRefs = _removeSecretReferenceAliases(
      raw,
      snakeKey: 'header_refs',
      camelKey: 'headerRefs',
      fieldName: 'header_refs',
      serverName: name,
    );
    return McpServerConfig(
      raw: raw,
      envRefs: envRefs,
      headerRefs: headerRefs,
      explicitEnvKeys: explicitEnvKeys,
      explicitHeaderKeys: explicitHeaderKeys,
      secretRefsResolved: envRefs.isEmpty && headerRefs.isEmpty,
    );
  }

  McpServerConfig withSecrets({
    required Map<String, String> env,
    required Map<String, String> headers,
    required Map<String, String> envRefs,
    required Map<String, String> headerRefs,
    Set<String>? explicitEnvKeys,
    Set<String>? explicitHeaderKeys,
  }) {
    final nextRaw = _jsonMap(raw, fieldName: 'mcp_servers');
    if (env.isEmpty) {
      if (type == 'stdio') {
        nextRaw['env'] = <Map<String, String>>[];
      } else {
        nextRaw.remove('env');
      }
    } else {
      nextRaw['env'] = <Map<String, String>>[
        for (final entry in env.entries)
          <String, String>{'name': entry.key, 'value': entry.value},
      ];
    }
    if (headers.isEmpty) {
      if (type == 'http' || type == 'sse') {
        nextRaw['headers'] = <Map<String, String>>[];
      } else {
        nextRaw.remove('headers');
      }
    } else {
      nextRaw['headers'] = <Map<String, String>>[
        for (final entry in headers.entries)
          <String, String>{'name': entry.key, 'value': entry.value},
      ];
    }
    return McpServerConfig(
      raw: nextRaw,
      envRefs: Map.unmodifiable(envRefs),
      headerRefs: Map.unmodifiable(headerRefs),
      explicitEnvKeys: Set.unmodifiable(
        explicitEnvKeys ?? this.explicitEnvKeys,
      ),
      explicitHeaderKeys: Set.unmodifiable(
        explicitHeaderKeys ?? this.explicitHeaderKeys,
      ),
      secretRefsResolved: true,
    );
  }
}

Map<String, String> _runtimeSecretMap(Object? raw) {
  final values = <String, String>{};
  if (raw is Map) {
    for (final entry in raw.entries) {
      if (entry.key is String && entry.value is String) {
        values[entry.key as String] = entry.value as String;
      }
    }
  } else if (raw is List) {
    for (final item in raw) {
      if (item is! Map) continue;
      final name = item['name'];
      final value = item['value'];
      if (name is String && value is String) values[name] = value;
    }
  }
  return Map.unmodifiable(values);
}

Map<String, String> _valuesWithoutReferences(
  Map<String, String> values,
  Map<String, String> references, {
  required ConfigSecretField field,
}) {
  return <String, String>{
    for (final entry in values.entries)
      if (!references.containsKey(entry.key) &&
          !isProtectedConfigValue(field: field, key: entry.key))
        entry.key: entry.value,
  };
}

AcpPermissionReviewAgentConfig _agentPermissionReviewAgent(
  Map<String, dynamic> json,
) {
  final permissions = json['permissions'];
  final direct = _aliasedValue(json, const <String>[
    'review_agent',
    'reviewAgent',
  ], fieldName: 'agent_server.review_agent');
  final nested = permissions is Map
      ? _aliasedValue(permissions, const <String>[
          'review_agent',
          'reviewAgent',
          'approval_agent',
        ], fieldName: 'agent_server.permissions.review_agent')
      : null;
  if (direct != null && nested != null) {
    throw const FormatException(
      'Agent server must not define both direct and permissions review agents.',
    );
  }
  return AcpPermissionReviewAgentConfig.fromJson(direct ?? nested);
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

Object? _aliasedValue(Map map, List<String> keys, {required String fieldName}) {
  final present = <String>[
    for (final key in keys)
      if (map.containsKey(key)) key,
  ];
  if (present.length > 1) {
    throw FormatException(
      '$fieldName must not define multiple aliases: ${present.join(', ')}.',
    );
  }
  return present.isEmpty ? null : map[present.single];
}

Map<String, String> _secretReferenceMap(
  Object? value, {
  required String fieldName,
  required String serverName,
}) {
  if (value == null) return const <String, String>{};
  if (value is! Map) {
    throw FormatException(
      'Server "$serverName" $fieldName must be a JSON object.',
    );
  }
  final result = <String, String>{};
  for (final entry in value.entries) {
    if (entry.key is! String || (entry.key as String).trim().isEmpty) {
      throw FormatException(
        'Server "$serverName" $fieldName keys must be non-empty strings.',
      );
    }
    if (entry.value is! String ||
        !_keychainSecretReferencePattern.hasMatch(entry.value as String)) {
      throw FormatException(
        'Server "$serverName" $fieldName "${entry.key}" must be a Keychain reference.',
      );
    }
    result[(entry.key as String).trim()] = entry.value as String;
  }
  return Map.unmodifiable(result);
}

Map<String, String> _secretReferenceMapFromAliases(
  Object? snakeValue,
  Object? camelValue, {
  required String fieldName,
  required String serverName,
}) {
  if (snakeValue != null && camelValue != null) {
    throw FormatException(
      'Server "$serverName" must not define both $fieldName and its camelCase alias.',
    );
  }
  return _secretReferenceMap(
    snakeValue ?? camelValue,
    fieldName: fieldName,
    serverName: serverName,
  );
}

Map<String, String> _removeSecretReferenceAliases(
  Map<String, dynamic> raw, {
  required String snakeKey,
  required String camelKey,
  required String fieldName,
  required String serverName,
}) {
  final snakeValue = raw.remove(snakeKey);
  final camelValue = raw.remove(camelKey);
  return _secretReferenceMapFromAliases(
    snakeValue,
    camelValue,
    fieldName: fieldName,
    serverName: serverName,
  );
}

final RegExp _keychainSecretReferencePattern = RegExp(
  r'^keychain://ianvs-acp/[0-9a-f]{64}$',
);

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
  validateAcpEndpoint(uri);
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
  if (value.contains('\n') || value.contains('\r')) {
    throw FormatException(
      '$location requires an HTTP header value without line breaks.',
    );
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
  final seenNames = <String>{};
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
    if (!seenNames.add(name)) {
      throw FormatException(
        'MCP server "$serverName" $key contains duplicate name "$name".',
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
  final seenNames = <String>{};
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
      if (!seenNames.add(name.toLowerCase())) {
        throw FormatException(
          'MCP server "$serverName" $key contains duplicate header "$name".',
        );
      }
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
    if (!seenNames.add(name.toLowerCase())) {
      throw FormatException(
        'MCP server "$serverName" $key contains duplicate header "$name".',
      );
    }
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
  validateAcpEndpoint(uri);
}
