import 'dart:convert';
import 'dart:io';

import '../acp/acp_adapter_packages.dart';
import '../platform/secure_atomic_file.dart';
import 'acp_client_config.dart';
import 'acp_config_secret_migrator.dart';
import 'acp_config_store.dart';
import 'secret_store.dart';

typedef FileExists = bool Function(String path);

class AcpAgentDiscovery {
  const AcpAgentDiscovery._();

  static const String codexAgentName = 'Codex';
  static const String codexAcpPackage = AcpAdapterPackages.codex;
  static const String zedCodexAcpPackage = AcpAdapterPackages.zedCodex;
  static const String piAgentName = AcpAdapterPackages.piAgentName;
  static const String piAcpVersion = AcpAdapterPackages.piVersion;
  static const String piAcpPackage = AcpAdapterPackages.pi;
  static const String cursorAgentName = AcpAdapterPackages.cursorAgentName;
  static const String codeBuddyAgentName =
      AcpAdapterPackages.codeBuddyAgentName;
  static const String codeBuddyAcpPackage = AcpAdapterPackages.codeBuddy;

  static List<AgentServerConfig> discoverMissing(
    AcpClientConfig config, {
    Map<String, String>? environment,
    FileExists? fileExists,
  }) {
    final candidates = discover(
      environment: environment,
      fileExists: fileExists,
    );
    return candidates
        .where((candidate) => !_hasEquivalentAgent(config, candidate))
        .toList(growable: false);
  }

  static List<AgentServerConfig> discover({
    Map<String, String>? environment,
    FileExists? fileExists,
  }) {
    final env = environment ?? Platform.environment;
    final npx = _resolveExecutable(
      'npx',
      environment: env,
      fileExists: fileExists,
      preferredPaths: _preferredExecutablePaths('npx', env),
    );

    final agents = <AgentServerConfig>[];
    if (npx != null) {
      agents.add(
        AgentServerConfig(
          name: codexAgentName,
          type: 'custom',
          command: npx,
          args: const <String>[codexAcpPackage],
        ),
      );
    }

    final pi = _resolveExecutable(
      'pi',
      environment: env,
      fileExists: fileExists,
      preferredPaths: _preferredExecutablePaths('pi', env),
    );
    if (npx != null && pi != null) {
      agents.add(
        AgentServerConfig(
          name: piAgentName,
          type: 'custom',
          command: npx,
          args: const <String>['-y', piAcpPackage],
        ),
      );
    }

    final cursor =
        _resolveExecutable(
          'agent',
          environment: env,
          fileExists: fileExists,
          preferredPaths: _preferredExecutablePaths('agent', env),
        ) ??
        _resolveExecutable(
          'cursor-agent',
          environment: env,
          fileExists: fileExists,
          preferredPaths: _preferredExecutablePaths('cursor-agent', env),
        );
    if (cursor != null) {
      agents.add(
        AgentServerConfig(
          name: cursorAgentName,
          type: 'custom',
          command: cursor,
          args: const <String>['acp'],
        ),
      );
    }

    final codeBuddy = _resolveExecutable(
      'codebuddy',
      environment: env,
      fileExists: fileExists,
      preferredPaths: _preferredExecutablePaths('codebuddy', env),
    );
    if (codeBuddy != null) {
      agents.add(
        AgentServerConfig(
          name: codeBuddyAgentName,
          type: 'custom',
          command: codeBuddy,
          args: const <String>['--acp'],
        ),
      );
    } else if (npx != null) {
      agents.add(
        AgentServerConfig(
          name: codeBuddyAgentName,
          type: 'custom',
          command: npx,
          args: const <String>['-y', codeBuddyAcpPackage, '--acp'],
        ),
      );
    }

    return agents;
  }

  static Future<AcpClientConfig> writeSelectedAgentServers(
    AcpClientConfig config,
    List<AgentServerConfig> servers, {
    SecretStore? secretStore,
  }) async {
    if (servers.isEmpty) return config;
    if (secretStore == null &&
        AcpConfigStore.hasUnreferencedSecrets(
          AcpClientConfig(agentServers: servers),
        )) {
      throw StateError(
        'A SecretStore is required to persist discovered ACP env or header values.',
      );
    }

    final configPath = config.configPath?.trim();
    if (configPath == null || configPath.isEmpty) {
      throw const FormatException('ACP config path is not available.');
    }

    final requestedFile = File(configPath);
    final written = await SecureAtomicFile.synchronizedAcrossProcesses(
      requestedFile,
      (file) async {
        Map<String, dynamic> raw;
        if (await file.exists()) {
          final decoded = jsonDecode(await file.readAsString());
          if (decoded is! Map<String, dynamic>) {
            throw const FormatException(
              'ACP config root must be a JSON object.',
            );
          }
          raw = Map<String, dynamic>.from(decoded);
        } else {
          raw = <String, dynamic>{};
        }

        final serversKey =
            raw.containsKey('agentServers') && !raw.containsKey('agent_servers')
            ? 'agentServers'
            : 'agent_servers';
        final existingServers = _agentServersJson(raw[serversKey]);
        final hadConfiguredAgents = existingServers.isNotEmpty;

        for (final server in servers) {
          if (_upgradeZedCodexServer(existingServers, server)) continue;
          if (existingServers.containsKey(server.name)) continue;
          existingServers[server.name] = server.toRuntimeJson();
        }
        raw[serversKey] = existingServers;

        if (!hadConfiguredAgents &&
            !raw.containsKey('default_agent_server') &&
            !raw.containsKey('defaultAgentServer')) {
          raw['default_agent_server'] = servers.first.name;
        }

        final parsed = AcpClientConfig.fromJson(raw, configPath: configPath);
        final prepared = secretStore == null
            ? null
            : await AcpConfigSecretMigrator(secretStore).prepare(parsed);
        final resolved = prepared?.resolved ?? parsed;
        final persisted = prepared == null
            ? raw
            : AcpConfigStore.persistResolvedSecretReferences(raw, resolved);
        const encoder = JsonEncoder.withIndent('  ');
        try {
          await SecureAtomicFile.writeString(
            file,
            '${encoder.convert(persisted)}\n',
            protectExistingParent: false,
          );
        } catch (error, stackTrace) {
          if (prepared != null) await prepared.rollback(cause: error);
          Error.throwWithStackTrace(error, stackTrace);
        }
        prepared?.commit();
        return resolved;
      },
    );
    return written;
  }

  static Map<String, dynamic> _agentServersJson(Object? raw) {
    if (raw == null) return <String, dynamic>{};
    if (raw is! Map<String, dynamic>) {
      throw const FormatException('agent_servers must be a JSON object.');
    }
    return Map<String, dynamic>.from(raw);
  }

  static bool _hasEquivalentAgent(
    AcpClientConfig config,
    AgentServerConfig candidate,
  ) {
    for (final server in config.selectableAgentServers) {
      if (_isZedCodexInvocation(server) &&
          _isCurrentCodexInvocation(candidate)) {
        continue;
      }
      if (_isPiAcpInvocation(server) && _isPiAcpInvocation(candidate)) {
        return true;
      }
      if (_isCursorAcpInvocation(server) && _isCursorAcpInvocation(candidate)) {
        return true;
      }
      if (_isCodeBuddyAcpInvocation(server) &&
          _isCodeBuddyAcpInvocation(candidate)) {
        return true;
      }
      if (server.name == candidate.name) return true;
      if (_sameStdioInvocation(server, candidate)) return true;
    }
    return false;
  }

  static bool _upgradeZedCodexServer(
    Map<String, dynamic> existingServers,
    AgentServerConfig candidate,
  ) {
    if (!_isCurrentCodexInvocation(candidate)) return false;
    var upgraded = false;
    for (final entry in existingServers.entries) {
      final raw = entry.value;
      if (raw is! Map) continue;
      final mapped = raw.map((key, value) => MapEntry(key.toString(), value));
      final args = mapped['args'];
      if (args is! List ||
          args.length != 1 ||
          !_isZedCodexPackage(args.single)) {
        continue;
      }
      mapped['args'] = <String>[codexAcpPackage];
      existingServers[entry.key] = mapped;
      upgraded = true;
    }
    return upgraded;
  }

  static bool _isCurrentCodexInvocation(AgentServerConfig server) =>
      server.isStdio &&
      server.args.length == 1 &&
      server.args.single == codexAcpPackage;

  static bool _isZedCodexInvocation(AgentServerConfig server) =>
      server.isStdio &&
      server.args.length == 1 &&
      _isZedCodexPackage(server.args.single);

  static bool _isPiAcpInvocation(AgentServerConfig server) =>
      server.isStdio &&
      AcpAdapterPackages.isPiAdapterInvocation(
        command: server.command,
        args: server.args,
      );

  static bool _isCursorAcpInvocation(AgentServerConfig server) =>
      server.isStdio &&
      AcpAdapterPackages.isCursorAdapterInvocation(
        command: server.command,
        args: server.args,
      );

  static bool _isCodeBuddyAcpInvocation(AgentServerConfig server) =>
      server.isStdio &&
      AcpAdapterPackages.isCodeBuddyAdapterInvocation(
        command: server.command,
        args: server.args,
      );

  static bool _isZedCodexPackage(Object? value) =>
      AcpAdapterPackages.isZedCodexPackage(value);

  static bool _sameStdioInvocation(
    AgentServerConfig left,
    AgentServerConfig right,
  ) {
    if (!left.isStdio || !right.isStdio) return false;
    if (left.args.length != right.args.length) return false;
    for (var index = 0; index < left.args.length; index += 1) {
      if (left.args[index] != right.args[index]) return false;
    }
    return _commandBaseName(left.command) == _commandBaseName(right.command);
  }

  static String _commandBaseName(String command) {
    final trimmed = command.trim();
    if (trimmed.isEmpty) return '';
    return trimmed.split(Platform.pathSeparator).last;
  }

  static List<String> _preferredExecutablePaths(
    String executable,
    Map<String, String> environment,
  ) {
    final home = environment['HOME']?.trim();
    return <String>[
      if (home != null && home.isNotEmpty) '$home/.local/bin/$executable',
      '/opt/homebrew/bin/$executable',
      '/usr/local/bin/$executable',
    ];
  }

  static String? _resolveExecutable(
    String executable, {
    Map<String, String>? environment,
    FileExists? fileExists,
    List<String> preferredPaths = const <String>[],
  }) {
    final exists = fileExists ?? (String path) => File(path).existsSync();
    for (final path in preferredPaths) {
      if (exists(path)) return path;
    }

    final env = environment ?? Platform.environment;
    final pathValue = env['PATH'];
    if (pathValue == null || pathValue.trim().isEmpty) return null;
    for (final dir in pathValue.split(':')) {
      final trimmed = dir.trim();
      if (trimmed.isEmpty) continue;
      final path = '$trimmed/$executable';
      if (exists(path)) return path;
    }
    return null;
  }
}
