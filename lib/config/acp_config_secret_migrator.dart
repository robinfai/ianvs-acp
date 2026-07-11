import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'acp_client_config.dart';
import 'secret_store.dart';

final class AcpConfigSecretMigrator {
  const AcpConfigSecretMigrator(this._store);

  static int _runtimeSecretGeneration = 0;

  final SecretStore _store;

  Future<PreparedAcpConfigSecrets> prepare(AcpClientConfig config) async {
    validateUniqueSecretReferences(config);
    final configIdentity = await _configIdentity(config.configPath);
    final rollbacks = <Future<void> Function()>[];
    try {
      final agents = <AgentServerConfig>[];
      for (final server in config.agentServers) {
        agents.add(await _prepareAgent(server, configIdentity, rollbacks));
      }
      final activeName = config.activeAgentServer?.name;
      AgentServerConfig? active;
      if (activeName != null) {
        for (final server in agents) {
          if (server.name == activeName) active = server;
        }
        active ??= await _prepareAgent(
          config.activeAgentServer!,
          configIdentity,
          rollbacks,
        );
      }

      final mcp = <McpServerConfig>[];
      for (final server in config.mcpServers) {
        mcp.add(
          await _prepareMcp(
            server,
            namespace: '$configIdentity/mcp/${server.name}',
            ownerLabel: 'MCP server "${server.name}"',
            rollbacks: rollbacks,
          ),
        );
      }
      final clientProviders = await _prepareClientProviders(
        config.clientProviders,
        configIdentity,
        rollbacks,
      );
      final prepared = PreparedAcpConfigSecrets._(
        AcpClientConfig(
          activeAgentServer: active,
          agentServers: List.unmodifiable(agents),
          mcpServers: List.unmodifiable(mcp),
          additionalDirectories: config.additionalDirectories,
          clientProviders: clientProviders,
          configPath: config.configPath,
          defaultAgentServerName: config.defaultAgentServerName,
          runtimeSecretGeneration: ++_runtimeSecretGeneration,
        ),
        _store,
        rollbacks,
      );
      validateUniqueSecretReferences(prepared.resolved);
      return prepared;
    } catch (error, stackTrace) {
      final rollbackErrors = await _runRollbacks(rollbacks);
      if (rollbackErrors.isNotEmpty) {
        Error.throwWithStackTrace(
          AcpSecretRollbackException(error, rollbackErrors),
          stackTrace,
        );
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<AgentServerConfig> _prepareAgent(
    AgentServerConfig server,
    String configIdentity,
    List<Future<void> Function()> rollbacks,
  ) async {
    final env = await _prepareMap(
      ownerLabel: 'Agent server "${server.name}"',
      namespace: '$configIdentity/agent/${server.name}/env',
      fieldName: 'env',
      values: server.env,
      refs: server.envRefs,
      refsResolved: server.secretRefsResolved,
      rollbacks: rollbacks,
    );
    final headers = await _prepareMap(
      ownerLabel: 'Agent server "${server.name}"',
      namespace: '$configIdentity/agent/${server.name}/headers',
      fieldName: 'headers',
      values: server.headers,
      refs: server.headerRefs,
      refsResolved: server.secretRefsResolved,
      rollbacks: rollbacks,
    );
    final reviewAgent = await _prepareReviewAgent(
      server.permissionReviewAgent,
      namespace: '$configIdentity/review/agent/${server.name}',
      ownerLabel: 'Agent server "${server.name}" review agent',
      rollbacks: rollbacks,
    );
    return server.withSecrets(
      env: env.values,
      headers: headers.values,
      envRefs: env.refs,
      headerRefs: headers.refs,
      permissionReviewAgent: reviewAgent,
    );
  }

  Future<McpServerConfig> _prepareMcp(
    McpServerConfig server, {
    required String namespace,
    required String ownerLabel,
    required List<Future<void> Function()> rollbacks,
  }) async {
    final env = await _prepareMap(
      ownerLabel: ownerLabel,
      namespace: '$namespace/env',
      fieldName: 'env',
      values: server.env,
      refs: server.envRefs,
      refsResolved: server.secretRefsResolved,
      rollbacks: rollbacks,
    );
    final headers = await _prepareMap(
      ownerLabel: ownerLabel,
      namespace: '$namespace/headers',
      fieldName: 'headers',
      values: server.headers,
      refs: server.headerRefs,
      refsResolved: server.secretRefsResolved,
      rollbacks: rollbacks,
    );
    return server.withSecrets(
      env: env.values,
      headers: headers.values,
      envRefs: env.refs,
      headerRefs: headers.refs,
    );
  }

  Future<AcpClientProviderConfig> _prepareClientProviders(
    AcpClientProviderConfig providers,
    String configIdentity,
    List<Future<void> Function()> rollbacks,
  ) async {
    return AcpClientProviderConfig(
      filesystem: providers.filesystem,
      terminal: providers.terminal,
      permissions: AcpPermissionProviderConfig(
        trustRules: providers.permissions.trustRules,
        reviewAgent: await _prepareReviewAgent(
          providers.permissions.reviewAgent,
          namespace: '$configIdentity/review/global',
          ownerLabel: 'Global review agent',
          rollbacks: rollbacks,
        ),
      ),
    );
  }

  Future<AcpPermissionReviewAgentConfig> _prepareReviewAgent(
    AcpPermissionReviewAgentConfig config, {
    required String namespace,
    required String ownerLabel,
    required List<Future<void> Function()> rollbacks,
  }) async {
    final server = config.mcpServer;
    return AcpPermissionReviewAgentConfig(
      enabled: config.enabled,
      mcpServer: server == null
          ? null
          : await _prepareMcp(
              server,
              namespace: '$namespace/${server.name}',
              ownerLabel: '$ownerLabel MCP server "${server.name}"',
              rollbacks: rollbacks,
            ),
      mcpServerName: config.mcpServerName,
      toolName: config.toolName,
      model: config.model,
      timeout: config.timeout,
    );
  }

  Future<_PreparedSecretMap> _prepareMap({
    required String ownerLabel,
    required String namespace,
    required String fieldName,
    required Map<String, String> values,
    required Map<String, String> refs,
    required bool refsResolved,
    required List<Future<void> Function()> rollbacks,
  }) async {
    final resolved = <String, String>{};
    final desiredRefs = <String, String>{};
    final existingValues = <String, String>{};

    if (!refsResolved) {
      final mixedKeys = values.keys.where(refs.containsKey).toList();
      if (mixedKeys.isNotEmpty) {
        throw FormatException(
          '$ownerLabel $fieldName "${mixedKeys.first}" must not define both plaintext and a secret reference.',
        );
      }
      for (final entry in refs.entries) {
        final value = await _readSecret(
          entry.value,
          ownerLabel: ownerLabel,
          fieldName: fieldName,
          key: entry.key,
        );
        if (value == null) {
          throw FormatException(
            '$ownerLabel $fieldName "${entry.key}" references a missing secret.',
          );
        }
        resolved[entry.key] = value;
        existingValues[entry.key] = value;
        desiredRefs[entry.key] = entry.value;
      }
    }
    resolved.addAll(values);

    for (final entry in resolved.entries) {
      final oldRef = refs[entry.key];
      if (oldRef != null) {
        final oldValue =
            existingValues[entry.key] ??
            await _readSecret(
              oldRef,
              ownerLabel: ownerLabel,
              fieldName: fieldName,
              key: entry.key,
            );
        if (oldValue == null) {
          throw FormatException(
            '$ownerLabel $fieldName "${entry.key}" references a missing secret.',
          );
        }
        if (oldValue != entry.value) {
          final nextRef = await _store.put(
            namespace: namespace,
            key: entry.key,
            value: entry.value,
          );
          if (nextRef != oldRef) {
            final mismatch = StateError(
              '$ownerLabel $fieldName "${entry.key}" changed its stable secret reference.',
            );
            try {
              await _store.delete(nextRef);
            } catch (cleanupError) {
              throw AcpSecretRollbackException(mismatch, [cleanupError]);
            }
            throw mismatch;
          }
          rollbacks.add(
            () => _store.put(
              namespace: namespace,
              key: entry.key,
              value: oldValue,
            ),
          );
        }
        desiredRefs[entry.key] = oldRef;
      } else {
        final reference = await _store.put(
          namespace: namespace,
          key: entry.key,
          value: entry.value,
        );
        desiredRefs[entry.key] = reference;
        rollbacks.add(() => _store.delete(reference));
      }
    }
    return _PreparedSecretMap(
      Map.unmodifiable(resolved),
      Map.unmodifiable(desiredRefs),
    );
  }

  Future<String?> _readSecret(
    String reference, {
    required String ownerLabel,
    required String fieldName,
    required String key,
  }) async {
    try {
      return await _store.get(reference);
    } catch (error) {
      throw FormatException(
        '$ownerLabel $fieldName "$key" could not resolve its Keychain secret (${error.runtimeType}).',
      );
    }
  }
}

final class PreparedAcpConfigSecrets {
  PreparedAcpConfigSecrets._(this.resolved, this._store, this._rollbacks);

  final AcpClientConfig resolved;
  final SecretStore _store;
  final List<Future<void> Function()> _rollbacks;
  bool _finished = false;

  Set<String> get references => collectSecretReferences(resolved);

  void commit() {
    _finished = true;
    _rollbacks.clear();
  }

  Future<void> rollback({Object? cause}) async {
    if (_finished) return;
    _finished = true;
    final errors = await _runRollbacks(_rollbacks);
    _rollbacks.clear();
    if (errors.isNotEmpty) {
      throw AcpSecretRollbackException(
        cause ?? StateError('ACP config persistence failed.'),
        errors,
      );
    }
  }

  Future<Map<String, Object>> deleteReferences(
    Iterable<String> references,
  ) async {
    final errors = <String, Object>{};
    for (final reference in references) {
      try {
        await _store.delete(reference);
      } catch (error) {
        errors[reference] = error;
      }
    }
    return errors;
  }
}

final class AcpSecretRollbackException implements Exception {
  const AcpSecretRollbackException(this.cause, this.rollbackErrors);

  final Object cause;
  final List<Object> rollbackErrors;

  @override
  String toString() =>
      'Secret migration failed ($cause), and rollback had '
      '${rollbackErrors.length} error(s).';
}

Set<String> collectSecretReferences(AcpClientConfig config) {
  return _secretReferencePaths(config).keys.toSet();
}

void validateUniqueSecretReferences(AcpClientConfig config) {
  final agentNames = <String>{};
  for (final server in config.agentServers) {
    if (!agentNames.add(server.name)) {
      throw FormatException('Duplicate agent server name "${server.name}".');
    }
  }
  final mcpNames = <String>{};
  for (final server in config.mcpServers) {
    if (!mcpNames.add(server.name)) {
      throw FormatException('Duplicate MCP server name "${server.name}".');
    }
  }
  _secretReferencePaths(config);
}

Map<String, String> _secretReferencePaths(AcpClientConfig config) {
  final paths = <String, String>{};
  void addMap(String prefix, Map<String, String> refs) {
    for (final entry in refs.entries) {
      final path = '$prefix.${entry.key}';
      final existing = paths[entry.value];
      if (existing != null && existing != path) {
        throw FormatException(
          'Secret reference ${entry.value} is reused by both $existing and $path.',
        );
      }
      paths[entry.value] = path;
    }
  }

  void addMcp(String prefix, McpServerConfig server) {
    addMap('$prefix.env_refs', server.envRefs);
    addMap('$prefix.header_refs', server.headerRefs);
  }

  void addReview(String prefix, AcpPermissionReviewAgentConfig review) {
    final server = review.mcpServer;
    if (server != null) addMcp('$prefix.mcp_server', server);
  }

  final agents = config.agentServers.isNotEmpty
      ? config.agentServers
      : config.activeAgentServer == null
      ? const <AgentServerConfig>[]
      : <AgentServerConfig>[config.activeAgentServer!];
  for (final server in agents) {
    final prefix = 'agent_servers.${server.name}';
    addMap('$prefix.env_refs', server.envRefs);
    addMap('$prefix.header_refs', server.headerRefs);
    addReview('$prefix.review_agent', server.permissionReviewAgent);
  }
  for (final server in config.mcpServers) {
    addMcp('mcp_servers.${server.name}', server);
  }
  addReview(
    'client_providers.permissions.review_agent',
    config.clientProviders.permissions.reviewAgent,
  );
  return paths;
}

final class _PreparedSecretMap {
  const _PreparedSecretMap(this.values, this.refs);

  final Map<String, String> values;
  final Map<String, String> refs;
}

Future<List<Object>> _runRollbacks(
  List<Future<void> Function()> rollbacks,
) async {
  final errors = <Object>[];
  for (final rollback in rollbacks.reversed) {
    try {
      await rollback();
    } catch (error) {
      errors.add(error);
    }
  }
  return errors;
}

Future<String> _configIdentity(String? path) async {
  final trimmed = path?.trim();
  if (trimmed == null || trimmed.isEmpty) {
    throw const FormatException(
      'ACP config path is required to namespace secret references.',
    );
  }
  final file = File(trimmed).absolute;
  await file.parent.create(recursive: true);
  final normalized = await file.exists()
      ? await file.resolveSymbolicLinks()
      : '${await file.parent.resolveSymbolicLinks()}/${file.uri.pathSegments.last}';
  return 'config/${sha256.convert(utf8.encode(normalized))}';
}
