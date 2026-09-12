import 'dart:async';
import 'dart:io';

import 'package:ianvs_acp_runtime/ianvs_acp_runtime.dart';

/// Usage: dart run example/local_chat.dart /path/to/agent [agent arguments...]
/// This minimal host declines permission requests; a UI should offer the choices.
Future<void> main(List<String> arguments) async {
  if (arguments.isEmpty) {
    stderr.writeln(
      'Usage: local_chat.dart <agent-command> [agent arguments...]',
    );
    exitCode = 64;
    return;
  }
  final runtime = IanvsRustRuntime();
  final events = StreamIterator<IanvsRuntimeEvent>(runtime.events);
  try {
    runtime.startAgent(
      agentName: 'Example assistant',
      command: arguments.first,
      args: arguments.skip(1).toList(),
      processCwd: Directory.current.path,
    );
    await nextWhere(events, (event) => event.status == 'ready');
    runtime.createSession(requestId: 'create-1', cwd: Directory.current.path);
    final created = await nextWhere(
      events,
      (event) => event.update?['kind'] == 'session_created',
    );
    runtime.prompt(
      requestId: 'prompt-1',
      sessionId: created.update!['sessionId']! as String,
      text: 'Introduce yourself briefly.',
    );
    while (true) {
      final event = await nextWhere(events, (_) => true);
      if (event.type == IanvsRuntimeEventType.permissionRequest) {
        final request = event.permissionRequest!;
        stderr.writeln('Declining permission: ${request['title']}');
        runtime.respondPermission(
          requestId: request['requestId']! as String,
          decision: const {'decision': 'cancelled'},
        );
      } else if (event.type == IanvsRuntimeEventType.renderUpdate) {
        final update = event.renderUpdate!;
        switch (update['kind']) {
          case 'assistant_text':
            stdout.write(update['text'] ?? '');
          case 'tool_call':
            stderr.writeln('Tool: ${update['metadata']}');
          case 'turn_completed':
            stdout.writeln();
            return;
        }
      }
    }
  } finally {
    await events.cancel();
    await runtime.dispose();
  }
}

Future<IanvsRuntimeEvent> nextWhere(
  StreamIterator<IanvsRuntimeEvent> events,
  bool Function(IanvsRuntimeEvent) predicate,
) async {
  while (await events.moveNext().timeout(const Duration(seconds: 30))) {
    final event = events.current;
    if (event.type == IanvsRuntimeEventType.runtimeError) {
      throw StateError('${event.errorCode}: ${event.errorMessage}');
    }
    if (event.status == 'failed' || event.status == 'recovering') {
      throw StateError('Agent disconnected: ${event.data['detail']}');
    }
    if (predicate(event)) return event;
  }
  throw StateError('Runtime closed before the expected event.');
}
