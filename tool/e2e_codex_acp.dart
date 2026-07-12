import 'dart:io';

import 'package:dart_acp/dart_acp.dart';

Future<void> main(List<String> args) async {
  final prompt = _optionValue(args, '--prompt');
  final saveSessionPath = _optionValue(args, '--save-session');
  final resumeSessionId = _optionValue(args, '--resume');
  final stopwatch = Stopwatch()..start();
  AcpClient? client;

  stdout.writeln('E2E: starting local Codex ACP client');
  stdout.writeln('command: npx @agentclientprotocol/codex-acp');
  stdout.writeln('cwd: ${Directory.current.path}');

  try {
    client = await AcpClient.start(
      config: AcpConfig(
        agentCommand: 'npx',
        agentArgs: const ['@agentclientprotocol/codex-acp'],
      ),
    );
    stdout.writeln('transport: started');

    final init = await client.initialize();
    stdout.writeln('initialize: success');
    stdout.writeln('supportsLoadSession: ${init.supportsLoadSession}');

    late final String sessionId;
    late final List<ConfigOption>? configOptions;
    if (resumeSessionId == null) {
      final result = await client.newSessionResult(Directory.current.path);
      sessionId = result.sessionId;
      configOptions = result.configOptions;
      stdout.writeln('newSession: success');
      _printConfigOptions(configOptions);
    } else {
      sessionId = resumeSessionId;
      final result = await client.loadSession(
        sessionId: resumeSessionId,
        workspaceRoot: Directory.current.path,
      );
      configOptions = result.configOptions;
      stdout.writeln('loadSession: success');
      _printConfigOptions(configOptions);
    }
    stdout.writeln('sessionId: $sessionId');

    if (resumeSessionId == null) {
      await _verifyBooleanConfigOptionWrites(
        client,
        sessionId: sessionId,
        options: configOptions,
      );
    }

    if (saveSessionPath != null) {
      await File(saveSessionPath).writeAsString(sessionId);
      stdout.writeln('savedSessionPath: $saveSessionPath');
    }

    if (prompt != null && prompt.trim().isNotEmpty) {
      stdout.writeln('prompt: sending');
      await for (final update in client.prompt(
        sessionId: sessionId,
        content: prompt,
      )) {
        final text = update.text;
        if (text.isNotEmpty) {
          stdout.write(text);
        }
      }
      stdout.writeln();
      stdout.writeln('prompt: complete');
    }

    stdout.writeln('elapsedMs: ${stopwatch.elapsedMilliseconds}');
  } catch (error, stackTrace) {
    stderr.writeln('E2E failed after ${stopwatch.elapsedMilliseconds} ms');
    stderr.writeln(error);
    stderr.writeln(stackTrace);
    exitCode = 1;
  } finally {
    await client?.dispose();
  }
}

Future<void> _verifyBooleanConfigOptionWrites(
  AcpClient client, {
  required String sessionId,
  required List<ConfigOption>? options,
}) async {
  final booleanOptions = (options ?? const <ConfigOption>[]).where(
    (option) => option.type == 'boolean' && option.currentValue is bool,
  );
  if (booleanOptions.isEmpty) return;

  final option = booleanOptions.first;
  final original = option.currentValue as bool;
  await client.setConfigOption(
    sessionId: sessionId,
    configId: option.id,
    value: !original,
  );
  await client.setConfigOption(
    sessionId: sessionId,
    configId: option.id,
    value: original,
  );
  stdout.writeln('booleanConfigWrite: ${option.id} toggle+restore success');
}

void _printConfigOptions(List<ConfigOption>? options) {
  for (final option in options ?? const <ConfigOption>[]) {
    stdout.writeln(
      'configOption: ${option.id} type=${option.type} '
      'category=${option.category} current=${option.currentValue}',
    );
    for (final choice in option.options) {
      stdout.writeln(
        '  choice: ${choice.value} (${choice.name}) '
        'group=${choice.groupId ?? '-'}',
      );
    }
  }
}

String? _optionValue(List<String> args, String name) {
  final index = args.indexOf(name);
  if (index == -1 || index + 1 >= args.length) return null;
  return args[index + 1];
}
