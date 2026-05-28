import 'dart:io';

import 'package:dart_acp/dart_acp.dart';

Future<void> main(List<String> args) async {
  final prompt = _optionValue(args, '--prompt');
  final saveSessionPath = _optionValue(args, '--save-session');
  final resumeSessionId = _optionValue(args, '--resume');
  final stopwatch = Stopwatch()..start();
  AcpClient? client;

  stdout.writeln('E2E: starting local Codex ACP client');
  stdout.writeln('command: npx @zed-industries/codex-acp');
  stdout.writeln('cwd: ${Directory.current.path}');

  try {
    client = await AcpClient.start(
      config: AcpConfig(
        agentCommand: 'npx',
        agentArgs: const ['@zed-industries/codex-acp'],
      ),
    );
    stdout.writeln('transport: started');

    final init = await client.initialize();
    stdout.writeln('initialize: success');
    stdout.writeln('supportsLoadSession: ${init.supportsLoadSession}');

    final sessionId =
        resumeSessionId ?? await client.newSession(Directory.current.path);
    if (resumeSessionId == null) {
      stdout.writeln('newSession: success');
    } else {
      await client.loadSession(
        sessionId: resumeSessionId,
        workspaceRoot: Directory.current.path,
      );
      stdout.writeln('loadSession: success');
    }
    stdout.writeln('sessionId: $sessionId');

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

String? _optionValue(List<String> args, String name) {
  final index = args.indexOf(name);
  if (index == -1 || index + 1 >= args.length) return null;
  return args[index + 1];
}
