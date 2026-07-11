import 'dart:convert';
import 'dart:io';

import '../platform/secure_atomic_file.dart';
import 'acp_client_config.dart';
import 'acp_config_secret_migrator.dart';
import 'secret_store.dart';

typedef AcpConfigAtomicWriter =
    Future<void> Function(File file, String contents);

class AcpConfigStore {
  const AcpConfigStore._();

  static Future<AcpClientConfig> writeConfig({
    required AcpClientConfig config,
    String? configPath,
    SecretStore? secretStore,
    AcpConfigAtomicWriter? atomicWriter,
  }) async {
    final path = (configPath ?? config.configPath)?.trim();
    if (path == null || path.isEmpty) {
      throw const FormatException('ACP config path is not available.');
    }

    final requestedFile = File(path);
    return SecureAtomicFile.synchronizedAcrossProcesses(requestedFile, (
      file,
    ) async {
      final raw = await _readExistingJson(file);
      final previous = AcpClientConfig.fromJson(raw, configPath: path);
      validateUniqueSecretReferences(previous);
      final oldOwners = await collectSecretReferenceOwners(previous);
      final oldReferences = oldOwners.keys.toSet();
      final configIdentity = await configSecretIdentity(path);
      final proposal = _inheritCurrentSecretReferences(
        _withConfigPath(config, path),
        previous,
      );
      validateUniqueSecretReferences(proposal);
      if (secretStore != null) {
        await _retryPendingSecretCleanup(
          file,
          secretStore,
          configIdentity: configIdentity,
          protectedReferences: oldReferences.union(
            collectSecretReferences(proposal),
          ),
        );
      }
      final prepared = secretStore == null
          ? null
          : await AcpConfigSecretMigrator(secretStore).prepare(proposal);
      final resolved = prepared?.resolved ?? proposal;
      if (prepared == null && _containsUnreferencedSecrets(proposal)) {
        throw StateError(
          'A SecretStore is required to persist ACP env or header values.',
        );
      }
      final canonicalJson = _persistEditedConfig(raw, resolved);

      const encoder = JsonEncoder.withIndent('  ');
      try {
        final contents = '${encoder.convert(canonicalJson)}\n';
        final writer = atomicWriter;
        if (writer == null) {
          await SecureAtomicFile.writeString(
            file,
            contents,
            protectExistingParent: false,
          );
        } else {
          await writer(file, contents);
        }
      } catch (error, stackTrace) {
        if (prepared != null) await prepared.rollback(cause: error);
        Error.throwWithStackTrace(error, stackTrace);
      }
      prepared?.commit();
      final committed = _withConfigPath(resolved, path);
      final retired = oldReferences.difference(
        collectSecretReferences(resolved),
      );
      if (prepared != null && retired.isNotEmpty) {
        final intents = <SecretCleanupIntent>[
          for (final reference in retired)
            if (oldOwners[reference] case final owner?)
              SecretCleanupIntent(owner: owner, reference: reference),
        ];
        final cleanupErrors = await prepared.deleteReferences(intents);
        if (cleanupErrors.isNotEmpty) {
          try {
            await _persistPendingSecretCleanup(
              file,
              intents.where(
                (intent) => cleanupErrors.containsKey(intent.reference),
              ),
            );
          } catch (queueError) {
            cleanupErrors['<cleanup-queue>'] = queueError;
          }
          throw AcpConfigPostCommitCleanupException(committed, cleanupErrors);
        }
      }
      return committed;
    });
  }

  static Future<AcpClientConfig> loadConfig({
    required String? configPath,
    required SecretStore secretStore,
    AcpConfigAtomicWriter? atomicWriter,
  }) async {
    final path = configPath?.trim();
    if (path == null || path.isEmpty) {
      return AcpClientConfig(configPath: configPath);
    }
    final requestedFile = File(path);
    return SecureAtomicFile.synchronizedAcrossProcesses(requestedFile, (
      file,
    ) async {
      if (!await file.exists()) return AcpClientConfig(configPath: path);
      final raw = await _readExistingJson(file);
      final parsed = AcpClientConfig.fromJson(raw, configPath: path);
      validateUniqueSecretReferences(parsed);
      final configIdentity = await configSecretIdentity(path);
      await _retryPendingSecretCleanup(
        file,
        secretStore,
        configIdentity: configIdentity,
        protectedReferences: collectSecretReferences(parsed),
      );
      final prepared = await AcpConfigSecretMigrator(
        secretStore,
      ).prepare(parsed);
      final resolved = prepared.resolved;
      final canonical = persistResolvedSecretReferences(raw, resolved);
      if (!_deepJsonEquals(raw, canonical)) {
        const encoder = JsonEncoder.withIndent('  ');
        try {
          final contents = '${encoder.convert(canonical)}\n';
          final writer = atomicWriter;
          if (writer == null) {
            await SecureAtomicFile.writeString(
              file,
              contents,
              protectExistingParent: false,
            );
          } else {
            await writer(file, contents);
          }
        } catch (error, stackTrace) {
          await prepared.rollback(cause: error);
          Error.throwWithStackTrace(error, stackTrace);
        }
      }
      prepared.commit();
      return resolved;
    });
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
    };
  }

  /// Replaces only recognized secret values in a cloned raw tree, preserving
  /// unknown and forward-compatible configuration fields.
  static Map<String, dynamic> persistResolvedSecretReferences(
    Map<String, dynamic> raw,
    AcpClientConfig resolved,
  ) => _persistResolvedSecretReferences(raw, resolved);

  static bool hasUnreferencedSecrets(AcpClientConfig config) =>
      _containsUnreferencedSecrets(config);

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

final class AcpConfigPostCommitCleanupException implements Exception {
  const AcpConfigPostCommitCleanupException(
    this.committedConfig,
    this.cleanupErrors,
  );

  final AcpClientConfig committedConfig;
  final Map<String, Object> cleanupErrors;

  @override
  String toString() =>
      'ACP config was saved, but ${cleanupErrors.length} retired Keychain '
      'reference(s) could not be deleted.';
}

Future<void> _retryPendingSecretCleanup(
  File configFile,
  SecretStore secretStore, {
  required String configIdentity,
  required Set<String> protectedReferences,
}) async {
  final queue = await _secretCleanupQueueFile(configFile);
  if (!await queue.exists()) return;
  final intents = await _readSecretCleanupQueue(queue);
  final remaining = <SecretCleanupIntent>[];
  final seen = <String>{};
  for (final intent in intents) {
    final reference = intent.reference;
    if (!seen.add(reference)) continue;
    if (intent.owner.configIdentity != configIdentity ||
        !secretStoreOwnsIntent(secretStore, intent, allowLegacy: true)) {
      continue;
    }
    if (protectedReferences.contains(reference)) {
      remaining.add(intent);
      continue;
    }
    try {
      await secretStore.delete(reference);
    } catch (_) {
      remaining.add(intent);
    }
  }
  await _writeSecretCleanupQueue(queue, remaining);
}

Future<void> _persistPendingSecretCleanup(
  File configFile,
  Iterable<SecretCleanupIntent> intents,
) async {
  final queue = await _secretCleanupQueueFile(configFile);
  final pending = <String, SecretCleanupIntent>{
    for (final intent in intents) intent.reference: intent,
  };
  if (await queue.exists()) {
    for (final intent in await _readSecretCleanupQueue(queue)) {
      pending.putIfAbsent(intent.reference, () => intent);
    }
  }
  await _writeSecretCleanupQueue(queue, pending.values.toList(growable: false));
}

Future<File> _secretCleanupQueueFile(File configFile) async {
  final resolved = await configFile.exists()
      ? await configFile.resolveSymbolicLinks()
      : '${await configFile.parent.resolveSymbolicLinks()}/${configFile.uri.pathSegments.last}';
  final canonical = File(resolved);
  return File(
    '${canonical.parent.path}/.${canonical.uri.pathSegments.last}.secret-cleanup.json',
  );
}

Future<List<SecretCleanupIntent>> _readSecretCleanupQueue(File queue) async {
  final decoded = jsonDecode(await queue.readAsString());
  if (decoded is List) {
    await _writeSecretCleanupQueue(queue, const <SecretCleanupIntent>[]);
    return const <SecretCleanupIntent>[];
  }
  if (decoded is! Map ||
      decoded['version'] != 1 ||
      decoded['intents'] is! List) {
    throw const FormatException('Invalid ACP secret cleanup queue.');
  }
  final intents = <SecretCleanupIntent>[];
  for (final rawIntent in decoded['intents'] as List) {
    if (rawIntent is! Map) continue;
    try {
      intents.add(
        SecretCleanupIntent.fromJson(Map<String, dynamic>.from(rawIntent)),
      );
    } on FormatException {
      // Invalid intents are untrusted and are discarded without deletion.
    }
  }
  return intents;
}

Future<void> _writeSecretCleanupQueue(
  File queue,
  List<SecretCleanupIntent> intents,
) {
  intents.sort((a, b) => a.reference.compareTo(b.reference));
  return SecureAtomicFile.writeString(
    queue,
    '${jsonEncode(<String, Object?>{'version': 1, 'intents': intents.map((intent) => intent.toJson()).toList()})}\n',
    protectExistingParent: false,
  );
}

bool _containsUnreferencedSecrets(AcpClientConfig config) {
  bool mcpHasSecrets(McpServerConfig server) =>
      server.env.keys.any((key) => !server.envRefs.containsKey(key)) ||
      server.headers.keys.any((key) => !server.headerRefs.containsKey(key));
  bool reviewHasSecrets(AcpPermissionReviewAgentConfig review) =>
      review.mcpServer != null && mcpHasSecrets(review.mcpServer!);
  bool serverHasSecrets(AgentServerConfig server) =>
      server.env.keys.any((key) => !server.envRefs.containsKey(key)) ||
      server.headers.keys.any((key) => !server.headerRefs.containsKey(key)) ||
      reviewHasSecrets(server.permissionReviewAgent);
  if (config.agentServers.any(serverHasSecrets)) return true;
  if (config.agentServers.isEmpty &&
      config.activeAgentServer != null &&
      serverHasSecrets(config.activeAgentServer!)) {
    return true;
  }
  for (final server in config.mcpServers) {
    if (mcpHasSecrets(server)) return true;
  }
  return reviewHasSecrets(config.clientProviders.permissions.reviewAgent);
}

bool _deepJsonEquals(Object? left, Object? right) =>
    jsonEncode(left) == jsonEncode(right);

Map<String, dynamic> _persistEditedConfig(
  Map<String, dynamic> raw,
  AcpClientConfig resolved,
) {
  final result = _cloneJsonMap(raw);
  final desired = AcpConfigStore.toSettingsJson(resolved);

  _writeAliasedValue(result, const <String>[
    'default_agent_server',
    'defaultAgentServer',
  ], desired['default_agent_server']);

  final currentAgents = _valueForAliases(result, const <String>[
    'agent_servers',
    'agentServers',
  ], fieldName: 'agent_servers');
  final desiredAgents = desired['agent_servers'];
  Map<String, Object?>? mergedAgents;
  if (desiredAgents is Map) {
    mergedAgents = <String, Object?>{};
    final currentMap = currentAgents is Map
        ? currentAgents
        : const <Never, Never>{};
    final servers = <String, AgentServerConfig>{
      for (final server in resolved.selectableAgentServers) server.name: server,
    };
    for (final entry in desiredAgents.entries) {
      final name = entry.key.toString();
      final server = servers[name];
      if (entry.value is! Map || server == null) continue;
      final current = currentMap[name];
      mergedAgents[name] = _mergeAgentRaw(
        current is Map ? current : null,
        entry.value as Map,
        server.permissionReviewAgent,
      );
    }
  }
  _writeAliasedValue(result, const <String>[
    'agent_servers',
    'agentServers',
  ], mergedAgents);

  final currentMcp = _valueForAliases(result, const <String>[
    'mcp_servers',
    'mcpServers',
  ], fieldName: 'mcp_servers');
  final desiredMcp = desired['mcp_servers'];
  List<Object?>? mergedMcp;
  if (desiredMcp is List) {
    final currentByName = <String, Map>{};
    if (currentMcp is List) {
      for (final item in currentMcp) {
        if (item is Map && item['name'] is String) {
          currentByName[item['name'] as String] = item;
        }
      }
    }
    mergedMcp = <Object?>[
      for (final item in desiredMcp)
        if (item is Map)
          _mergeMcpRaw(
            item['name'] is String ? currentByName[item['name']] : null,
            item,
          ),
    ];
  }
  _writeAliasedValue(result, const <String>[
    'mcp_servers',
    'mcpServers',
  ], mergedMcp);
  _writeAliasedValue(result, const <String>[
    'additional_directories',
    'additionalDirectories',
  ], desired['additional_directories']);

  final currentProviders = _valueForAliases(result, const <String>[
    'client_providers',
    'clientProviders',
  ], fieldName: 'client_providers');
  final desiredProviders = desired['client_providers'];
  final mergedProviders = _mergeClientProvidersRaw(
    currentProviders is Map ? currentProviders : null,
    desiredProviders is Map ? desiredProviders : const <Never, Never>{},
  );
  _writeAliasedValue(result, const <String>[
    'client_providers',
    'clientProviders',
  ], mergedProviders.isEmpty ? null : mergedProviders);
  return result;
}

Map<String, dynamic> _mergeAgentRaw(
  Map? current,
  Map desired,
  AcpPermissionReviewAgentConfig review,
) {
  final result = current == null
      ? <String, dynamic>{}
      : _cloneJsonMap(Map<String, dynamic>.from(current));
  const directManaged = <String>[
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
  ];
  for (final key in directManaged) {
    result.remove(key);
  }
  for (final entry in desired.entries) {
    if (entry.key == 'review_agent' || entry.key == 'reviewAgent') continue;
    result[entry.key.toString()] = _cloneJsonValue(entry.value);
  }
  _mergeReviewLocation(
    result,
    review.isConfigured ? review.toJson() : null,
    allowNestedPermissions: true,
  );
  return result;
}

Map<String, dynamic> _mergeClientProvidersRaw(Map? current, Map desired) {
  final result = current == null
      ? <String, dynamic>{}
      : _cloneJsonMap(Map<String, dynamic>.from(current));

  final desiredFilesystem = desired['filesystem'];
  _mergeKnownAliasedObject(
    result,
    const <String>['filesystem', 'fs'],
    desiredFilesystem is Map ? desiredFilesystem : const <Never, Never>{},
    const <String>[
      'read_text_file',
      'readTextFile',
      'write_text_file',
      'writeTextFile',
      'allow_read_outside_workspace',
      'allowReadOutsideWorkspace',
    ],
  );
  final desiredTerminal = desired['terminal'];
  _mergeKnownAliasedObject(
    result,
    const <String>['terminal'],
    desiredTerminal is Map ? desiredTerminal : const <Never, Never>{},
    const <String>['enabled'],
  );

  final currentPermissions = result['permissions'];
  final permissions = currentPermissions is Map
      ? _cloneJsonMap(Map<String, dynamic>.from(currentPermissions))
      : <String, dynamic>{};
  final desiredPermissions = desired['permissions'];
  final desiredPermissionsMap = desiredPermissions is Map
      ? desiredPermissions
      : const <Never, Never>{};
  _writeAliasedValue(permissions, const <String>[
    'trust_rules',
    'trustRules',
    'rules',
  ], desiredPermissionsMap['trust_rules']);
  final desiredReview = desiredPermissionsMap['review_agent'];
  _mergeReviewLocation(
    permissions,
    desiredReview is Map ? desiredReview : null,
    allowNestedPermissions: false,
  );
  if (permissions.isEmpty) {
    result.remove('permissions');
  } else {
    result['permissions'] = permissions;
  }
  return result;
}

void _mergeKnownAliasedObject(
  Map<String, dynamic> container,
  List<String> aliases,
  Map desired,
  List<String> managedKeys,
) {
  final current = _valueForAliases(
    container,
    aliases,
    fieldName: aliases.first,
  );
  final merged = current is Map
      ? _cloneJsonMap(Map<String, dynamic>.from(current))
      : <String, dynamic>{};
  for (final key in managedKeys) {
    merged.remove(key);
  }
  for (final entry in desired.entries) {
    merged[entry.key.toString()] = _cloneJsonValue(entry.value);
  }
  _writeAliasedValue(container, aliases, merged.isEmpty ? null : merged);
}

void _mergeReviewLocation(
  Map<String, dynamic> container,
  Map? desired, {
  required bool allowNestedPermissions,
}) {
  const reviewAliases = <String>[
    'review_agent',
    'reviewAgent',
    'approval_agent',
  ];
  String? key;
  Map<String, dynamic> owner = container;
  for (final alias in reviewAliases) {
    if (container.containsKey(alias)) key = alias;
  }
  if (key == null && allowNestedPermissions) {
    final permissions = container['permissions'];
    if (permissions is Map) {
      owner = _cloneJsonMap(Map<String, dynamic>.from(permissions));
      container['permissions'] = owner;
      for (final alias in reviewAliases) {
        if (owner.containsKey(alias)) key = alias;
      }
    }
  }
  key ??= 'review_agent';
  final current = owner[key];
  final merged = _mergeReviewRaw(current is Map ? current : null, desired);
  if (merged == null) {
    owner.remove(key);
  } else {
    owner[key] = merged;
  }
}

Map<String, dynamic>? _mergeReviewRaw(Map? current, Map? desired) {
  final result = current == null
      ? <String, dynamic>{}
      : _cloneJsonMap(Map<String, dynamic>.from(current));
  const managed = <String>[
    'enabled',
    'mcp_server',
    'mcpServer',
    'mcp_server_name',
    'mcpServerName',
    'server_name',
    'tool_name',
    'toolName',
    'model',
    'timeout_ms',
    'timeoutMs',
  ];
  final currentMcp = _valueForAliases(result, const <String>[
    'mcp_server',
    'mcpServer',
  ], fieldName: 'review_agent.mcp_server');
  for (final key in managed) {
    result.remove(key);
  }
  if (desired != null) {
    for (final entry in desired.entries) {
      if (entry.key == 'mcp_server' || entry.key == 'mcpServer') continue;
      result[entry.key.toString()] = _cloneJsonValue(entry.value);
    }
    final desiredMcp = desired['mcp_server'] ?? desired['mcpServer'];
    if (desiredMcp is Map) {
      result['mcp_server'] = _mergeMcpRaw(
        currentMcp is Map ? currentMcp : null,
        desiredMcp,
      );
    }
  }
  if (desired == null && result.isNotEmpty) result['enabled'] = false;
  return result.isEmpty ? null : result;
}

Map<String, dynamic> _mergeMcpRaw(Map? current, Map desired) {
  final result = current == null
      ? <String, dynamic>{}
      : _cloneJsonMap(Map<String, dynamic>.from(current));
  const managed = <String>[
    'name',
    'type',
    'command',
    'url',
    'id',
    'args',
    'env',
    'headers',
    'env_refs',
    'envRefs',
    'header_refs',
    'headerRefs',
  ];
  for (final key in managed) {
    result.remove(key);
  }
  for (final entry in desired.entries) {
    result[entry.key.toString()] = _cloneJsonValue(entry.value);
  }
  return result;
}

Object? _valueForAliases(
  Map container,
  List<String> aliases, {
  required String fieldName,
}) {
  final present = <String>[
    for (final key in aliases)
      if (container.containsKey(key)) key,
  ];
  if (present.length > 1) {
    throw FormatException(
      '$fieldName must not define multiple aliases: ${present.join(', ')}.',
    );
  }
  return present.isEmpty ? null : container[present.single];
}

void _writeAliasedValue(
  Map<String, dynamic> container,
  List<String> aliases,
  Object? value,
) {
  String? key;
  for (final alias in aliases) {
    if (container.containsKey(alias)) key = alias;
  }
  for (final alias in aliases) {
    container.remove(alias);
  }
  if (value != null) {
    container[key ?? aliases.first] = _cloneJsonValue(value);
  }
}

Map<String, dynamic> _cloneJsonMap(Map<String, dynamic> value) =>
    jsonDecode(jsonEncode(value)) as Map<String, dynamic>;

Object? _cloneJsonValue(Object? value) => jsonDecode(jsonEncode(value));

Map<String, dynamic> _persistResolvedSecretReferences(
  Map<String, dynamic> raw,
  AcpClientConfig resolved,
) {
  final result = jsonDecode(jsonEncode(raw)) as Map<String, dynamic>;
  final agentsRaw = _valueForAliases(result, const <String>[
    'agent_servers',
    'agentServers',
  ], fieldName: 'agent_servers');
  if (agentsRaw is Map) {
    final agents = <String, AgentServerConfig>{
      for (final server in resolved.selectableAgentServers) server.name: server,
    };
    for (final entry in agentsRaw.entries) {
      final server = agents[entry.key];
      if (server == null || entry.value is! Map) continue;
      final serverRaw = entry.value as Map;
      _replaceSecretMaps(serverRaw, server.envRefs, server.headerRefs);
      _replaceInlineReviewSecrets(
        serverRaw,
        server.permissionReviewAgent.mcpServer,
      );
    }
  }

  final mcpRaw = _valueForAliases(result, const <String>[
    'mcp_servers',
    'mcpServers',
  ], fieldName: 'mcp_servers');
  if (mcpRaw is List) {
    for (
      var index = 0;
      index < mcpRaw.length && index < resolved.mcpServers.length;
      index += 1
    ) {
      final item = mcpRaw[index];
      if (item is! Map) continue;
      final server = resolved.mcpServers[index];
      _replaceSecretMaps(item, server.envRefs, server.headerRefs);
    }
  }

  final providersRaw = _valueForAliases(result, const <String>[
    'client_providers',
    'clientProviders',
  ], fieldName: 'client_providers');
  if (providersRaw is Map) {
    final permissionsRaw = providersRaw['permissions'];
    if (permissionsRaw is Map) {
      _replaceInlineReviewSecrets(
        permissionsRaw,
        resolved.clientProviders.permissions.reviewAgent.mcpServer,
      );
    }
  }
  return result;
}

void _replaceInlineReviewSecrets(
  Map container,
  McpServerConfig? resolvedServer,
) {
  final direct =
      container['review_agent'] ??
      container['reviewAgent'] ??
      container['approval_agent'];
  Map? reviewRaw = direct is Map ? direct : null;
  if (reviewRaw == null) {
    final permissions = container['permissions'];
    if (permissions is Map) {
      final nested =
          permissions['review_agent'] ??
          permissions['reviewAgent'] ??
          permissions['approval_agent'];
      if (nested is Map) reviewRaw = nested;
    }
  }
  if (reviewRaw == null || resolvedServer == null) return;
  final mcpRaw = reviewRaw['mcp_server'] ?? reviewRaw['mcpServer'];
  if (mcpRaw is Map) {
    _replaceSecretMaps(
      mcpRaw,
      resolvedServer.envRefs,
      resolvedServer.headerRefs,
    );
  }
}

void _replaceSecretMaps(
  Map raw,
  Map<String, String> envRefs,
  Map<String, String> headerRefs,
) {
  raw.remove('env');
  raw.remove('headers');
  raw.remove('env_refs');
  raw.remove('envRefs');
  raw.remove('header_refs');
  raw.remove('headerRefs');
  if (envRefs.isNotEmpty) raw['env_refs'] = Map<String, String>.from(envRefs);
  if (headerRefs.isNotEmpty) {
    raw['header_refs'] = Map<String, String>.from(headerRefs);
  }
}

AcpClientConfig _withConfigPath(AcpClientConfig config, String path) {
  return AcpClientConfig(
    activeAgentServer: config.activeAgentServer,
    agentServers: config.agentServers,
    mcpServers: config.mcpServers,
    additionalDirectories: config.additionalDirectories,
    clientProviders: config.clientProviders,
    configPath: path,
    defaultAgentServerName: config.defaultAgentServerName,
    runtimeSecretGeneration: config.runtimeSecretGeneration,
  );
}

AcpClientConfig _inheritCurrentSecretReferences(
  AcpClientConfig proposal,
  AcpClientConfig current,
) {
  final currentAgents = <String, AgentServerConfig>{
    for (final server in current.selectableAgentServers) server.name: server,
  };
  final agents = <AgentServerConfig>[
    for (final server in proposal.agentServers)
      _inheritAgentReferences(server, currentAgents[server.name]),
  ];
  AgentServerConfig? active;
  final activeProposal = proposal.activeAgentServer;
  if (activeProposal != null) {
    for (final server in agents) {
      if (server.name == activeProposal.name) active = server;
    }
    active ??= _inheritAgentReferences(
      activeProposal,
      currentAgents[activeProposal.name],
    );
  }

  final currentMcp = <String, McpServerConfig>{
    for (final server in current.mcpServers) server.name: server,
  };
  return AcpClientConfig(
    activeAgentServer: active,
    agentServers: List.unmodifiable(agents),
    mcpServers: List.unmodifiable([
      for (final server in proposal.mcpServers)
        _inheritMcpReferences(server, currentMcp[server.name]),
    ]),
    additionalDirectories: proposal.additionalDirectories,
    clientProviders: AcpClientProviderConfig(
      filesystem: proposal.clientProviders.filesystem,
      terminal: proposal.clientProviders.terminal,
      permissions: AcpPermissionProviderConfig(
        trustRules: proposal.clientProviders.permissions.trustRules,
        reviewAgent: _inheritReviewReferences(
          proposal.clientProviders.permissions.reviewAgent,
          current.clientProviders.permissions.reviewAgent,
        ),
      ),
    ),
    configPath: proposal.configPath,
    defaultAgentServerName: proposal.defaultAgentServerName,
    runtimeSecretGeneration: proposal.runtimeSecretGeneration,
  );
}

AgentServerConfig _inheritAgentReferences(
  AgentServerConfig proposal,
  AgentServerConfig? current,
) {
  if (!proposal.secretRefsResolved) return proposal;
  final targetChanged =
      current != null &&
      agentSecretTargetIdentity(proposal) != agentSecretTargetIdentity(current);
  return proposal.withSecrets(
    env: targetChanged
        ? _withoutPreviouslyProtectedValues(proposal.env, current.envRefs)
        : proposal.env,
    headers: targetChanged
        ? _withoutPreviouslyProtectedValues(
            proposal.headers,
            current.headerRefs,
          )
        : proposal.headers,
    envRefs: targetChanged
        ? const <String, String>{}
        : _refsForCurrentKeys(proposal.env, current?.envRefs),
    headerRefs: targetChanged
        ? const <String, String>{}
        : _refsForCurrentKeys(proposal.headers, current?.headerRefs),
    permissionReviewAgent: _inheritReviewReferences(
      proposal.permissionReviewAgent,
      current?.permissionReviewAgent,
    ),
  );
}

McpServerConfig _inheritMcpReferences(
  McpServerConfig proposal,
  McpServerConfig? current,
) {
  if (!proposal.secretRefsResolved) return proposal;
  final targetChanged =
      current != null &&
      mcpSecretTargetIdentity(proposal) != mcpSecretTargetIdentity(current);
  return proposal.withSecrets(
    env: targetChanged
        ? _withoutPreviouslyProtectedValues(proposal.env, current.envRefs)
        : proposal.env,
    headers: targetChanged
        ? _withoutPreviouslyProtectedValues(
            proposal.headers,
            current.headerRefs,
          )
        : proposal.headers,
    envRefs: targetChanged
        ? const <String, String>{}
        : _refsForCurrentKeys(proposal.env, current?.envRefs),
    headerRefs: targetChanged
        ? const <String, String>{}
        : _refsForCurrentKeys(proposal.headers, current?.headerRefs),
  );
}

Map<String, String> _withoutPreviouslyProtectedValues(
  Map<String, String> values,
  Map<String, String> currentRefs,
) {
  return Map.unmodifiable(<String, String>{
    for (final entry in values.entries)
      if (!currentRefs.containsKey(entry.key)) entry.key: entry.value,
  });
}

AcpPermissionReviewAgentConfig _inheritReviewReferences(
  AcpPermissionReviewAgentConfig proposal,
  AcpPermissionReviewAgentConfig? current,
) {
  final server = proposal.mcpServer;
  return AcpPermissionReviewAgentConfig(
    enabled: proposal.enabled,
    mcpServer: server == null
        ? null
        : _inheritMcpReferences(server, current?.mcpServer),
    mcpServerName: proposal.mcpServerName,
    toolName: proposal.toolName,
    model: proposal.model,
    timeout: proposal.timeout,
  );
}

Map<String, String> _refsForCurrentKeys(
  Map<String, String> values,
  Map<String, String>? currentRefs,
) {
  if (currentRefs == null || currentRefs.isEmpty) {
    return const <String, String>{};
  }
  return Map.unmodifiable(<String, String>{
    for (final key in values.keys)
      if (currentRefs[key] != null) key: currentRefs[key]!,
  });
}
