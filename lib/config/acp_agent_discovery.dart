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
  static const String codexAcpVersion = AcpAdapterPackages.codexVersion;
  static const String codexAcpPackage = AcpAdapterPackages.codex;
  static const String piAgentName = 'pi ACP';
  static const String piAcpVersion = AcpAdapterPackages.piVersion;
  static const String piAcpPackage = AcpAdapterPackages.pi;

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
    final npx = _resolveExecutable(
      'npx',
      environment: environment,
      fileExists: fileExists,
      preferredPaths: const <String>[
        '/opt/homebrew/bin/npx',
        '/usr/local/bin/npx',
      ],
    );
    if (npx == null) return const <AgentServerConfig>[];

    final agents = <AgentServerConfig>[
      AgentServerConfig(
        name: codexAgentName,
        type: 'custom',
        command: npx,
        args: const <String>[codexAcpPackage],
      ),
    ];

    final pi = _resolveExecutable(
      'pi',
      environment: environment,
      fileExists: fileExists,
      preferredPaths: const <String>[
        '/opt/homebrew/bin/pi',
        '/usr/local/bin/pi',
      ],
    );
    if (pi != null) {
      agents.add(
        AgentServerConfig(
          name: piAgentName,
          type: 'custom',
          command: npx,
          args: const <String>['-y', piAcpPackage],
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
      if (server.name == candidate.name) return true;
      if (_sameStdioInvocation(server, candidate)) return true;
    }
    return false;
  }

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
