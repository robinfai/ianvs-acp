import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'acp_client_config.dart';
import 'secret_field_policy.dart';
import 'secret_store.dart';

final class AcpConfigSecretMigrator {
  const AcpConfigSecretMigrator(this._store);

  static int _runtimeSecretGeneration = 0;

  final SecretStore _store;

  Future<PreparedAcpConfigSecrets> prepare(AcpClientConfig config) async {
    validateUniqueSecretReferences(config);
    final configIdentity = await configSecretIdentity(config.configPath);
    final rollbacks = <Future<void> Function()>[];
    final writes = _OwnedSecretWrites(_store, rollbacks);
    try {
      final agents = <AgentServerConfig>[];
      for (final server in config.agentServers) {
        agents.add(await _prepareAgent(server, configIdentity, writes));
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
          writes,
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
            writes: writes,
          ),
        );
      }
      final clientProviders = await _prepareClientProviders(
        config.clientProviders,
        configIdentity,
        writes,
      );
      final prepared = PreparedAcpConfigSecrets._(
        AcpClientConfig(
          activeAgentServer: active,
          agentServers: List.unmodifiable(agents),
          mcpServers: List.unmodifiable(mcp),
          additionalDirectories: config.additionalDirectories,
          clientProviders: clientProviders,
          storage: config.storage,
          assistantAgent: config.assistantAgent,
          sessionTemplates: config.sessionTemplates,
          configPath: config.configPath,
          defaultAgentServerName: config.defaultAgentServerName,
          defaultSessionTemplateId: config.defaultSessionTemplateId,
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
    _OwnedSecretWrites writes,
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
      writes: writes,
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
      writes: writes,
    );
    final reviewAgent = await _prepareReviewAgent(
      server.permissionReviewAgent,
      configIdentity: configIdentity,
      targetKind: 'review/agent/${server.name}',
      ownerLabel: 'Agent server "${server.name}" review agent',
      writes: writes,
    );
    return server.withSecrets(
      env: env.values,
      headers: headers.values,
      envRefs: env.refs,
      headerRefs: headers.refs,
      explicitEnvKeys: const <String>{},
      explicitHeaderKeys: const <String>{},
      permissionReviewAgent: reviewAgent,
    );
  }

  Future<McpServerConfig> _prepareMcp(
    McpServerConfig server, {
    required String configIdentity,
    required String targetKind,
    required String ownerLabel,
    required _OwnedSecretWrites writes,
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
      writes: writes,
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
      writes: writes,
    );
    return server.withSecrets(
      env: env.values,
      headers: headers.values,
      envRefs: env.refs,
      headerRefs: headers.refs,
      explicitEnvKeys: const <String>{},
      explicitHeaderKeys: const <String>{},
    );
  }

  Future<AcpClientProviderConfig> _prepareClientProviders(
    AcpClientProviderConfig providers,
    String configIdentity,
    _OwnedSecretWrites writes,
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
          writes: writes,
        ),
      ),
    );
  }

  Future<AcpPermissionReviewAgentConfig> _prepareReviewAgent(
    AcpPermissionReviewAgentConfig config, {
    required String configIdentity,
    required String targetKind,
    required String ownerLabel,
    required _OwnedSecretWrites writes,
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
              writes: writes,
            ),
      mcpServerName: config.mcpServerName,
      agentServerName: config.agentServerName,
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
    required _OwnedSecretWrites writes,
  }) async {
    final resolved = <String, String>{};
    final desiredRefs = <String, String>{};
    final existingValues = <String, String>{};
    final referenceKinds = <String, _OwnedReferenceKind>{};

    SecretOwner ownerFor(String key) => SecretOwner(
      configIdentity: configIdentity,
      targetKind: targetKind,
      targetIdentity: targetIdentity,
      fieldName: fieldName,
      key: key,
    );
    bool shouldProtect(String key) => isProtectedConfigValue(
      field: fieldName == 'headers'
          ? ConfigSecretField.header
          : ConfigSecretField.environment,
      key: key,
    );

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
        if (shouldProtect(entry.key)) {
          if (read.kind == _OwnedReferenceKind.unscoped) {
            final migrated = await writes.put(
              owner,
              value,
              ownerLabel: ownerLabel,
            );
            desiredRefs[entry.key] = migrated;
          } else {
            desiredRefs[entry.key] = entry.value;
          }
        }
      }
    }
    resolved.addAll(values);

    for (final entry in resolved.entries) {
      if (!shouldProtect(entry.key)) continue;
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
        if (referenceKind == _OwnedReferenceKind.unscoped &&
            desiredReference == null) {
          desiredReference = await writes.put(
            owner,
            oldValue,
            ownerLabel: ownerLabel,
          );
        }
        if (oldValue != entry.value) {
          final nextRef = await writes.put(
            owner,
            entry.value,
            ownerLabel: ownerLabel,
          );
          desiredReference = nextRef;
        }
        desiredRefs[entry.key] = desiredReference ?? oldRef;
      } else {
        final reference = await writes.put(
          owner,
          entry.value,
          ownerLabel: ownerLabel,
        );
        desiredRefs[entry.key] = reference;
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
        ? _OwnedReferenceKind.targetScoped
        : _store.referenceMatches(
            reference,
            namespace: owner.unscopedNamespace,
            key: owner.key,
          )
        ? _OwnedReferenceKind.unscoped
        : null;
    if (kind == null) {
      throw FormatException(
        '$ownerLabel ${owner.fieldName} "${owner.key}" references a secret outside its owner.',
      );
    }
    try {
      return _OwnedSecretRead(await _store.get(reference), kind);
    } on SecretStoreInteractionRequiredException {
      rethrow;
    } catch (error) {
      throw FormatException(
        '$ownerLabel ${owner.fieldName} "${owner.key}" could not resolve its Keychain secret (${error.runtimeType}).',
      );
    }
  }
}

final class _OwnedSecretWrites {
  _OwnedSecretWrites(this._store, this._rollbacks);

  final SecretStore _store;
  final List<Future<void> Function()> _rollbacks;
  final Map<String, _OwnedSecretSnapshot> _snapshots =
      <String, _OwnedSecretSnapshot>{};

  Future<String> put(
    SecretOwner owner,
    String value, {
    required String ownerLabel,
  }) async {
    final expected = _store.referenceFor(
      namespace: owner.namespace,
      key: owner.key,
    );
    if (!_store.referenceMatches(
      expected,
      namespace: owner.namespace,
      key: owner.key,
    )) {
      throw StateError(
        '$ownerLabel ${owner.fieldName} "${owner.key}" has an invalid deterministic reference.',
      );
    }

    final existingSnapshot = _snapshots[expected];
    if (existingSnapshot == null) {
      String? previousValue;
      try {
        previousValue = await _store.get(expected);
      } on SecretStoreInteractionRequiredException {
        rethrow;
      } catch (error) {
        throw FormatException(
          '$ownerLabel ${owner.fieldName} "${owner.key}" could not snapshot its Keychain secret (${error.runtimeType}).',
        );
      }
      final snapshot = _OwnedSecretSnapshot(
        owner: owner,
        reference: expected,
        previousValue: previousValue,
        ownerLabel: ownerLabel,
      );
      _snapshots[expected] = snapshot;
      _rollbacks.add(() => _restore(snapshot));
    } else if (existingSnapshot.owner.namespace != owner.namespace ||
        existingSnapshot.owner.key != owner.key) {
      throw StateError(
        '$ownerLabel ${owner.fieldName} "${owner.key}" collides with another secret owner.',
      );
    }

    final reference = await _store.put(
      namespace: owner.namespace,
      key: owner.key,
      value: value,
    );
    if (reference != expected ||
        !_store.referenceMatches(
          reference,
          namespace: owner.namespace,
          key: owner.key,
        )) {
      throw StateError(
        '$ownerLabel ${owner.fieldName} "${owner.key}" returned a reference outside its owner.',
      );
    }
    return reference;
  }

  Future<void> _restore(_OwnedSecretSnapshot snapshot) async {
    final owner = snapshot.owner;
    final reference = snapshot.reference;
    if (!_store.referenceMatches(
      reference,
      namespace: owner.namespace,
      key: owner.key,
    )) {
      throw StateError(
        '${snapshot.ownerLabel} ${owner.fieldName} "${owner.key}" cannot safely roll back its reference.',
      );
    }
    final previousValue = snapshot.previousValue;
    if (previousValue == null) {
      await _store.delete(reference);
      return;
    }
    final restored = await _store.put(
      namespace: owner.namespace,
      key: owner.key,
      value: previousValue,
    );
    if (restored != reference ||
        !_store.referenceMatches(
          restored,
          namespace: owner.namespace,
          key: owner.key,
        )) {
      throw StateError(
        '${snapshot.ownerLabel} ${owner.fieldName} "${owner.key}" could not restore its stable reference.',
      );
    }
  }
}

final class _OwnedSecretSnapshot {
  const _OwnedSecretSnapshot({
    required this.owner,
    required this.reference,
    required this.previousValue,
    required this.ownerLabel,
  });

  final SecretOwner owner;
  final String reference;
  final String? previousValue;
  final String ownerLabel;
}

enum _OwnedReferenceKind { targetScoped, unscoped }

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
      if (!secretStoreOwnsIntent(
        _store,
        intent,
        allowUnscopedNamespace: true,
      )) {
        continue;
      }
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
  bool allowUnscopedNamespace = false,
}) {
  final owner = intent.owner;
  if (store.referenceMatches(
    intent.reference,
    namespace: owner.namespace,
    key: owner.key,
  )) {
    return true;
  }
  return allowUnscopedNamespace &&
      store.referenceMatches(
        intent.reference,
        namespace: owner.unscopedNamespace,
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
    'type': raw['type'] is String ? raw['type'] : server.type,
    'command': raw['command'] is String ? raw['command'] : server.command,
    'url': raw['url'] is String ? raw['url'] : server.url,
    'id': raw['id'] is String ? raw['id'] : server.id,
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
