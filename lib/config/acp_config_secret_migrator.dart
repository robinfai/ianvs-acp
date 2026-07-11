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
    final configIdentity = await configSecretIdentity(config.configPath);
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
            configIdentity: configIdentity,
            targetKind: 'mcp/${server.name}',
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
    final targetKind = 'agent/${server.name}';
    final targetIdentity = agentSecretTargetIdentity(server);
    final env = await _prepareMap(
      ownerLabel: 'Agent server "${server.name}"',
      configIdentity: configIdentity,
      targetKind: targetKind,
      targetIdentity: targetIdentity,
      fieldName: 'env',
      values: server.env,
      refs: server.envRefs,
      refsResolved: server.secretRefsResolved,
      rollbacks: rollbacks,
    );
    final headers = await _prepareMap(
      ownerLabel: 'Agent server "${server.name}"',
      configIdentity: configIdentity,
      targetKind: targetKind,
      targetIdentity: targetIdentity,
      fieldName: 'headers',
      values: server.headers,
      refs: server.headerRefs,
      refsResolved: server.secretRefsResolved,
      rollbacks: rollbacks,
    );
    final reviewAgent = await _prepareReviewAgent(
      server.permissionReviewAgent,
      configIdentity: configIdentity,
      targetKind: 'review/agent/${server.name}',
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
    required String configIdentity,
    required String targetKind,
    required String ownerLabel,
    required List<Future<void> Function()> rollbacks,
  }) async {
    final targetIdentity = mcpSecretTargetIdentity(server);
    final env = await _prepareMap(
      ownerLabel: ownerLabel,
      configIdentity: configIdentity,
      targetKind: targetKind,
      targetIdentity: targetIdentity,
      fieldName: 'env',
      values: server.env,
      refs: server.envRefs,
      refsResolved: server.secretRefsResolved,
      rollbacks: rollbacks,
    );
    final headers = await _prepareMap(
      ownerLabel: ownerLabel,
      configIdentity: configIdentity,
      targetKind: targetKind,
      targetIdentity: targetIdentity,
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
          configIdentity: configIdentity,
          targetKind: 'review/global',
          ownerLabel: 'Global review agent',
          rollbacks: rollbacks,
        ),
      ),
    );
  }

  Future<AcpPermissionReviewAgentConfig> _prepareReviewAgent(
    AcpPermissionReviewAgentConfig config, {
    required String configIdentity,
    required String targetKind,
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
              configIdentity: configIdentity,
              targetKind: '$targetKind/${server.name}',
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
    required String configIdentity,
    required String targetKind,
    required String targetIdentity,
    required String fieldName,
    required Map<String, String> values,
    required Map<String, String> refs,
    required bool refsResolved,
    required List<Future<void> Function()> rollbacks,
  }) async {
    final resolved = <String, String>{};
    final desiredRefs = <String, String>{};
    final existingValues = <String, String>{};
    final referenceKinds = <String, _OwnedReferenceKind>{};
    final newlyCreatedReferences = <String>{};

    SecretOwner ownerFor(String key) => SecretOwner(
      configIdentity: configIdentity,
      targetKind: targetKind,
      targetIdentity: targetIdentity,
      fieldName: fieldName,
      key: key,
    );

    Future<String> putOwned(SecretOwner owner, String value) async {
      final reference = await _store.put(
        namespace: owner.namespace,
        key: owner.key,
        value: value,
      );
      if (!_store.referenceMatches(
        reference,
        namespace: owner.namespace,
        key: owner.key,
      )) {
        throw StateError(
          '$ownerLabel $fieldName "${owner.key}" returned a reference outside its owner.',
        );
      }
      return reference;
    }

    void addNewReferenceRollback(SecretOwner owner, String reference) {
      if (!newlyCreatedReferences.add(reference)) return;
      rollbacks.add(() async {
        if (_store.referenceMatches(
          reference,
          namespace: owner.namespace,
          key: owner.key,
        )) {
          await _store.delete(reference);
        }
      });
    }

    if (!refsResolved) {
      final mixedKeys = values.keys.where(refs.containsKey).toList();
      if (mixedKeys.isNotEmpty) {
        throw FormatException(
          '$ownerLabel $fieldName "${mixedKeys.first}" must not define both plaintext and a secret reference.',
        );
      }
      for (final entry in refs.entries) {
        final owner = ownerFor(entry.key);
        final read = await _readSecret(
          entry.value,
          owner: owner,
          ownerLabel: ownerLabel,
        );
        final value = read.value;
        if (value == null) {
          throw FormatException(
            '$ownerLabel $fieldName "${entry.key}" references a missing secret.',
          );
        }
        resolved[entry.key] = value;
        existingValues[entry.key] = value;
        referenceKinds[entry.key] = read.kind;
        if (read.kind == _OwnedReferenceKind.legacy) {
          final migrated = await putOwned(owner, value);
          desiredRefs[entry.key] = migrated;
          addNewReferenceRollback(owner, migrated);
        } else {
          desiredRefs[entry.key] = entry.value;
        }
      }
    }
    resolved.addAll(values);

    for (final entry in resolved.entries) {
      final owner = ownerFor(entry.key);
      final oldRef = refs[entry.key];
      if (oldRef != null) {
        final existingRead = existingValues.containsKey(entry.key)
            ? null
            : await _readSecret(oldRef, owner: owner, ownerLabel: ownerLabel);
        final oldValue = existingValues[entry.key] ?? existingRead?.value;
        if (oldValue == null) {
          throw FormatException(
            '$ownerLabel $fieldName "${entry.key}" references a missing secret.',
          );
        }
        final referenceKind = referenceKinds[entry.key] ?? existingRead!.kind;
        var desiredReference = desiredRefs[entry.key];
        if (referenceKind == _OwnedReferenceKind.legacy &&
            desiredReference == null) {
          desiredReference = await putOwned(owner, oldValue);
          addNewReferenceRollback(owner, desiredReference);
        }
        if (oldValue != entry.value) {
          final nextRef = await putOwned(owner, entry.value);
          desiredReference = nextRef;
          if (referenceKind == _OwnedReferenceKind.current) {
            rollbacks.add(() async {
              final restored = await putOwned(owner, oldValue);
              if (restored != oldRef) {
                throw StateError(
                  '$ownerLabel $fieldName "${entry.key}" could not restore its stable reference.',
                );
              }
            });
          }
        }
        desiredRefs[entry.key] = desiredReference ?? oldRef;
      } else {
        final reference = await putOwned(owner, entry.value);
        desiredRefs[entry.key] = reference;
        addNewReferenceRollback(owner, reference);
      }
    }
    return _PreparedSecretMap(
      Map.unmodifiable(resolved),
      Map.unmodifiable(desiredRefs),
    );
  }

  Future<_OwnedSecretRead> _readSecret(
    String reference, {
    required SecretOwner owner,
    required String ownerLabel,
  }) async {
    final kind =
        _store.referenceMatches(
          reference,
          namespace: owner.namespace,
          key: owner.key,
        )
        ? _OwnedReferenceKind.current
        : _store.referenceMatches(
            reference,
            namespace: owner.legacyNamespace,
            key: owner.key,
          )
        ? _OwnedReferenceKind.legacy
        : null;
    if (kind == null) {
      throw FormatException(
        '$ownerLabel ${owner.fieldName} "${owner.key}" references a secret outside its owner.',
      );
    }
    try {
      return _OwnedSecretRead(await _store.get(reference), kind);
    } catch (error) {
      throw FormatException(
        '$ownerLabel ${owner.fieldName} "${owner.key}" could not resolve its Keychain secret (${error.runtimeType}).',
      );
    }
  }
}

enum _OwnedReferenceKind { current, legacy }

final class _OwnedSecretRead {
  const _OwnedSecretRead(this.value, this.kind);

  final String? value;
  final _OwnedReferenceKind kind;
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
    Iterable<SecretCleanupIntent> intents,
  ) async {
    final errors = <String, Object>{};
    for (final intent in intents) {
      final reference = intent.reference;
      if (!secretStoreOwnsIntent(_store, intent, allowLegacy: true)) continue;
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

Future<Map<String, SecretOwner>> collectSecretReferenceOwners(
  AcpClientConfig config,
) async {
  final configIdentity = await configSecretIdentity(config.configPath);
  final owners = <String, SecretOwner>{};

  void addMap({
    required String targetKind,
    required String targetIdentity,
    required String fieldName,
    required Map<String, String> refs,
  }) {
    for (final entry in refs.entries) {
      owners[entry.value] = SecretOwner(
        configIdentity: configIdentity,
        targetKind: targetKind,
        targetIdentity: targetIdentity,
        fieldName: fieldName,
        key: entry.key,
      );
    }
  }

  void addMcp(String targetKind, McpServerConfig server) {
    final targetIdentity = mcpSecretTargetIdentity(server);
    addMap(
      targetKind: targetKind,
      targetIdentity: targetIdentity,
      fieldName: 'env',
      refs: server.envRefs,
    );
    addMap(
      targetKind: targetKind,
      targetIdentity: targetIdentity,
      fieldName: 'headers',
      refs: server.headerRefs,
    );
  }

  void addReview(String targetKind, AcpPermissionReviewAgentConfig review) {
    final server = review.mcpServer;
    if (server != null) addMcp('$targetKind/${server.name}', server);
  }

  final agents = config.agentServers.isNotEmpty
      ? config.agentServers
      : config.activeAgentServer == null
      ? const <AgentServerConfig>[]
      : <AgentServerConfig>[config.activeAgentServer!];
  for (final server in agents) {
    final targetKind = 'agent/${server.name}';
    final targetIdentity = agentSecretTargetIdentity(server);
    addMap(
      targetKind: targetKind,
      targetIdentity: targetIdentity,
      fieldName: 'env',
      refs: server.envRefs,
    );
    addMap(
      targetKind: targetKind,
      targetIdentity: targetIdentity,
      fieldName: 'headers',
      refs: server.headerRefs,
    );
    addReview('review/agent/${server.name}', server.permissionReviewAgent);
  }
  for (final server in config.mcpServers) {
    addMcp('mcp/${server.name}', server);
  }
  addReview('review/global', config.clientProviders.permissions.reviewAgent);
  return Map.unmodifiable(owners);
}

bool secretStoreOwnsIntent(
  SecretStore store,
  SecretCleanupIntent intent, {
  bool allowLegacy = false,
}) {
  final owner = intent.owner;
  if (store.referenceMatches(
    intent.reference,
    namespace: owner.namespace,
    key: owner.key,
  )) {
    return true;
  }
  return allowLegacy &&
      store.referenceMatches(
        intent.reference,
        namespace: owner.legacyNamespace,
        key: owner.key,
      );
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

String agentSecretTargetIdentity(AgentServerConfig server) {
  return _targetFingerprint(<String, Object?>{
    'type': server.type,
    'command': server.command,
    'url': server.url,
    'cwd': server.cwd,
    'args': server.args,
  });
}

String mcpSecretTargetIdentity(McpServerConfig server) {
  final raw = server.raw;
  return _targetFingerprint(<String, Object?>{
    'type': server.type,
    'command': server.command,
    'url': server.url,
    'id': server.id,
    'args': raw['args'] is List ? raw['args'] : const <Object?>[],
    'cwd': raw['cwd'] ?? raw['working_directory'] ?? raw['workingDirectory'],
  });
}

String _targetFingerprint(Map<String, Object?> target) {
  final canonical = _canonicalJsonValue(target);
  return sha256.convert(utf8.encode(jsonEncode(canonical))).toString();
}

Object? _canonicalJsonValue(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((key) => key.toString()).toList()..sort();
    return <String, Object?>{
      for (final key in keys) key: _canonicalJsonValue(value[key]),
    };
  }
  if (value is List) {
    return value.map(_canonicalJsonValue).toList(growable: false);
  }
  return value;
}

Future<String> configSecretIdentity(String? path) async {
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
