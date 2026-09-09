import 'acp_client_config.dart';
import 'assistant_agent_config.dart';

/// Updates name-based references after Agent or MCP definitions are renamed.
///
/// Definition names are expected to have already been updated by the caller.
/// Each reference is looked up exactly once in its corresponding map, so a map
/// containing `A -> B` and `B -> C` changes an `A` reference to `B`, not `C`.
AcpClientConfig remapConfigurationReferences(
  AcpClientConfig config, {
  Map<String, String> agentNames = const <String, String>{},
  Map<String, String> mcpNames = const <String, String>{},
}) {
  if (agentNames.isEmpty && mcpNames.isEmpty) return config;

  var changed = false;

  final agentServers = <AgentServerConfig>[];
  for (final server in config.agentServers) {
    final remapped = _remapAgentServer(server, agentNames, mcpNames);
    agentServers.add(remapped);
    changed = changed || !identical(remapped, server);
  }
  final nextAgentServers = changed
      ? List<AgentServerConfig>.unmodifiable(agentServers)
      : config.agentServers;

  var activeAgentServer = config.activeAgentServer;
  if (activeAgentServer != null) {
    final originalActive = activeAgentServer;
    final mappedActiveName = _remapName(originalActive.name, agentNames);
    if (mappedActiveName != originalActive.name) {
      activeAgentServer = _agentNamed(nextAgentServers, mappedActiveName);
    }
    activeAgentServer ??= _remapAgentServer(
      originalActive,
      agentNames,
      mcpNames,
    );
    if (mappedActiveName == originalActive.name) {
      final originalIndex = config.agentServers.indexWhere(
        (server) => identical(server, originalActive),
      );
      activeAgentServer = originalIndex < 0
          ? _remapAgentServer(originalActive, agentNames, mcpNames)
          : nextAgentServers[originalIndex];
    }
    changed = changed || !identical(activeAgentServer, originalActive);
  }

  final defaultAgentServerName = _remapNullableName(
    config.defaultAgentServerName,
    agentNames,
  );
  changed = changed || defaultAgentServerName != config.defaultAgentServerName;

  final assistantAgent = _remapAssistant(config.assistantAgent, agentNames);
  changed = changed || !identical(assistantAgent, config.assistantAgent);

  final permissions = _remapPermissions(
    config.clientProviders.permissions,
    agentNames,
    mcpNames,
  );
  final clientProviders =
      identical(permissions, config.clientProviders.permissions)
      ? config.clientProviders
      : AcpClientProviderConfig(
          filesystem: config.clientProviders.filesystem,
          terminal: config.clientProviders.terminal,
          permissions: permissions,
        );
  changed = changed || !identical(clientProviders, config.clientProviders);

  var templatesChanged = false;
  final templates = <SessionTemplateConfig>[];
  for (final template in config.sessionTemplates) {
    final remapped = _remapTemplate(template, agentNames, mcpNames);
    templates.add(remapped);
    templatesChanged = templatesChanged || !identical(remapped, template);
  }
  final sessionTemplates = templatesChanged
      ? List<SessionTemplateConfig>.unmodifiable(templates)
      : config.sessionTemplates;
  changed = changed || templatesChanged;

  if (!changed) return config;
  return AcpClientConfig(
    activeAgentServer: activeAgentServer,
    agentServers: nextAgentServers,
    mcpServers: config.mcpServers,
    additionalDirectories: config.additionalDirectories,
    clientProviders: clientProviders,
    storage: config.storage,
    assistantAgent: assistantAgent,
    sessionTemplates: sessionTemplates,
    configPath: config.configPath,
    defaultAgentServerName: defaultAgentServerName,
    defaultSessionTemplateId: config.defaultSessionTemplateId,
    runtimeSecretGeneration: config.runtimeSecretGeneration,
  );
}

AgentServerConfig? _agentNamed(List<AgentServerConfig> servers, String name) {
  for (final server in servers) {
    if (server.name == name) return server;
  }
  return null;
}

AgentServerConfig _remapAgentServer(
  AgentServerConfig server,
  Map<String, String> agentNames,
  Map<String, String> mcpNames,
) {
  final reviewAgent = _remapReviewAgent(
    server.permissionReviewAgent,
    agentNames,
    mcpNames,
  );
  if (identical(reviewAgent, server.permissionReviewAgent)) return server;
  return AgentServerConfig(
    name: server.name,
    type: server.type,
    persistenceId: server.persistenceId,
    persistenceAliases: server.persistenceAliases,
    command: server.command,
    cwd: server.cwd,
    url: server.url,
    args: server.args,
    env: server.env,
    headers: server.headers,
    envRefs: server.envRefs,
    headerRefs: server.headerRefs,
    explicitEnvKeys: server.explicitEnvKeys,
    explicitHeaderKeys: server.explicitHeaderKeys,
    secretRefsResolved: server.secretRefsResolved,
    additionalProperties: server.additionalProperties,
    permissionReviewAgent: reviewAgent,
  );
}

AcpPermissionProviderConfig _remapPermissions(
  AcpPermissionProviderConfig permissions,
  Map<String, String> agentNames,
  Map<String, String> mcpNames,
) {
  final reviewAgent = _remapReviewAgent(
    permissions.reviewAgent,
    agentNames,
    mcpNames,
  );
  if (identical(reviewAgent, permissions.reviewAgent)) return permissions;
  return AcpPermissionProviderConfig(
    trustRules: permissions.trustRules,
    reviewAgent: reviewAgent,
  );
}

AcpPermissionReviewAgentConfig _remapReviewAgent(
  AcpPermissionReviewAgentConfig reviewAgent,
  Map<String, String> agentNames,
  Map<String, String> mcpNames,
) {
  final agentServerName = _remapNullableName(
    reviewAgent.agentServerName,
    agentNames,
  );
  final mcpServerName = _remapNullableName(reviewAgent.mcpServerName, mcpNames);
  if (agentServerName == reviewAgent.agentServerName &&
      mcpServerName == reviewAgent.mcpServerName) {
    return reviewAgent;
  }
  return AcpPermissionReviewAgentConfig(
    enabled: reviewAgent.enabled,
    mcpServer: reviewAgent.mcpServer,
    mcpServerName: mcpServerName,
    agentServerName: agentServerName,
    toolName: reviewAgent.toolName,
    model: reviewAgent.model,
    timeout: reviewAgent.timeout,
  );
}

AssistantAgentConfig _remapAssistant(
  AssistantAgentConfig assistant,
  Map<String, String> agentNames,
) {
  final agentName = _remapNullableName(assistant.agentName, agentNames);
  if (agentName == assistant.agentName) return assistant;
  return assistant.copyWith(agentName: agentName);
}

SessionTemplateConfig _remapTemplate(
  SessionTemplateConfig template,
  Map<String, String> agentNames,
  Map<String, String> mcpNames,
) {
  final agentServerName = _remapNullableName(
    template.agentServerName,
    agentNames,
  );
  final permissions = template.permissions == null
      ? null
      : _remapPermissions(template.permissions!, agentNames, mcpNames);
  final assistantAgent = template.assistantAgent == null
      ? null
      : _remapAssistant(template.assistantAgent!, agentNames);

  var mcpServerNames = template.mcpServerNames;
  if (mcpServerNames != null) {
    var namesChanged = false;
    final names = <String>[];
    for (final name in mcpServerNames) {
      final remapped = _remapName(name, mcpNames);
      names.add(remapped);
      namesChanged = namesChanged || remapped != name;
    }
    if (namesChanged) {
      mcpServerNames = List<String>.unmodifiable(names);
    }
  }

  if (agentServerName == template.agentServerName &&
      identical(permissions, template.permissions) &&
      identical(assistantAgent, template.assistantAgent) &&
      identical(mcpServerNames, template.mcpServerNames)) {
    return template;
  }
  return SessionTemplateConfig(
    id: template.id,
    name: template.name,
    version: template.version,
    description: template.description,
    agentServerName: agentServerName,
    mode: template.mode,
    model: template.model,
    reasoningEffort: template.reasoningEffort,
    additionalDirectories: template.additionalDirectories,
    mcpServerNames: mcpServerNames,
    permissions: permissions,
    assistantAgent: assistantAgent,
  );
}

String _remapName(String name, Map<String, String> renames) =>
    renames[name] ?? name;

String? _remapNullableName(String? name, Map<String, String> renames) =>
    name == null ? null : _remapName(name, renames);
