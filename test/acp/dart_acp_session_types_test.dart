// ignore_for_file: implementation_imports

import 'package:dart_acp/dart_acp.dart';
import 'package:dart_acp/src/session/session_manager.dart'
    show InitializeResult;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('initialize result treats capability objects as supported', () {
    final result = InitializeResult(
      protocolVersion: 1,
      agentCapabilities: <String, dynamic>{
        'loadSession': <String, dynamic>{},
        'sessionCapabilities': <String, dynamic>{
          'list': <String, dynamic>{},
          'resume': true,
          'fork': <String, dynamic>{},
          'configOptions': <String, dynamic>{},
        },
      },
      authMethods: const <Map<String, dynamic>>[],
    );

    expect(result.supportsLoadSession, isTrue);
    expect(result.supportsListSessions, isTrue);
    expect(result.supportsResumeSession, isTrue);
    expect(result.supportsForkSession, isTrue);
    expect(result.sessionCapabilities.configOptions, isTrue);
  });

  test('session capabilities do not treat false or null as supported', () {
    final capabilities = SessionCapabilities.fromJson(<String, dynamic>{
      'sessionCapabilities': <String, dynamic>{
        'list': false,
        'resume': null,
        'fork': true,
        'configOptions': <String, dynamic>{},
      },
    });

    expect(capabilities.list, isFalse);
    expect(capabilities.resume, isFalse);
    expect(capabilities.fork, isTrue);
    expect(capabilities.configOptions, isTrue);
  });

  test('legacy session capability object uses the same support rules', () {
    final capabilities = SessionCapabilities.fromJson(<String, dynamic>{
      'session': <String, dynamic>{
        'list': <String, dynamic>{},
        'resume': false,
        'fork': null,
        'configOptions': true,
      },
    });

    expect(capabilities.list, isTrue);
    expect(capabilities.resume, isFalse);
    expect(capabilities.fork, isFalse);
    expect(capabilities.configOptions, isTrue);
  });

  test('tool calls accept legacy content and location payloads', () {
    final toolCall = ToolCall.fromJson(<String, dynamic>{
      'tool_call_id': 'call-1',
      'status': 'started',
      'title': 'Read file',
      'content': 'reading now',
      'locations': <Object>[
        '/workspace/a.dart',
        <String, dynamic>{'path': '/workspace/b.dart', 'line': 12},
      ],
    });

    expect(toolCall.toolCallId, 'call-1');
    expect(toolCall.status, ToolCallStatus.pending);
    expect(toolCall.content, [containsPair('text', 'reading now')]);
    expect(toolCall.locations?.map((location) => location.path), [
      '/workspace/a.dart',
      '/workspace/b.dart',
    ]);
    expect(toolCall.locations?.last.line, 12);

    final merged = toolCall.merge(<String, dynamic>{
      'status': 'completed',
      'content': <String, dynamic>{'type': 'text', 'text': 'done'},
      'locations': '/workspace/done.dart',
    });

    expect(merged.status, ToolCallStatus.completed);
    expect(merged.content, [containsPair('text', 'done')]);
    expect(merged.locations?.single.path, '/workspace/done.dart');
  });
}
