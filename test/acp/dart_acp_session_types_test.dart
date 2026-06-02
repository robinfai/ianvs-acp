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
          'additionalDirectories': <String, dynamic>{},
        },
      },
      authMethods: const <Map<String, dynamic>>[],
    );

    expect(result.supportsLoadSession, isTrue);
    expect(result.supportsListSessions, isTrue);
    expect(result.supportsResumeSession, isTrue);
    expect(result.supportsForkSession, isTrue);
    expect(result.sessionCapabilities.configOptions, isTrue);
    expect(result.supportsAdditionalDirectories, isTrue);
  });

  test('session capabilities do not treat false or null as supported', () {
    final capabilities = SessionCapabilities.fromJson(<String, dynamic>{
      'sessionCapabilities': <String, dynamic>{
        'list': false,
        'resume': null,
        'fork': true,
        'configOptions': <String, dynamic>{},
        'additionalDirectories': false,
      },
    });

    expect(capabilities.list, isFalse);
    expect(capabilities.resume, isFalse);
    expect(capabilities.fork, isTrue);
    expect(capabilities.configOptions, isTrue);
    expect(capabilities.additionalDirectories, isFalse);
  });

  test('legacy session capability object uses the same support rules', () {
    final capabilities = SessionCapabilities.fromJson(<String, dynamic>{
      'session': <String, dynamic>{
        'list': <String, dynamic>{},
        'resume': false,
        'fork': null,
        'configOptions': true,
        'additionalDirectories': true,
      },
    });

    expect(capabilities.list, isTrue);
    expect(capabilities.resume, isFalse);
    expect(capabilities.fork, isFalse);
    expect(capabilities.configOptions, isTrue);
    expect(capabilities.additionalDirectories, isTrue);
  });

  test('session capabilities accept snake case additional directories', () {
    final capabilities = SessionCapabilities.fromJson(<String, dynamic>{
      'sessionCapabilities': <String, dynamic>{
        'additional_directories': <String, dynamic>{},
      },
    });

    expect(capabilities.additionalDirectories, isTrue);
  });

  test('session info parses additional directories', () {
    final session = SessionInfo.fromJson(<String, dynamic>{
      'sessionId': 'session-1',
      'cwd': '/workspace',
      'additionalDirectories': <Object>[
        '/workspace-extra',
        ' /workspace-other ',
        '/workspace-extra',
      ],
    });

    expect(session.additionalDirectories, [
      '/workspace-extra',
      '/workspace-other',
    ]);
    expect(session.toJson(), {
      'sessionId': 'session-1',
      'cwd': '/workspace',
      'additionalDirectories': ['/workspace-extra', '/workspace-other'],
    });
  });

  test('content blocks accept legacy text, image, and resource payloads', () {
    final delta = MessageDelta.fromRaw(
      role: 'assistant',
      rawContent: <Map<String, dynamic>>[
        <String, dynamic>{'content': 'hello from content'},
        <String, dynamic>{
          'type': 'image',
          'mime_type': 'image/png',
          'base64': 'aW1hZ2U=',
        },
        <String, dynamic>{
          'type': 'audio',
          'mime_type': 'audio/wav',
          'base64': 'YXVkaW8=',
        },
        <String, dynamic>{
          'type': 'resource',
          'resource': <String, dynamic>{
            'url': 'file:///workspace/README.md',
            'name': 'README.md',
            'mime_type': 'text/markdown',
            'content': '# Project notes',
          },
        },
        <String, dynamic>{
          'type': 'resourceLink',
          'path': 'file:///workspace/lib/main.dart',
          'label': 'main.dart',
        },
      ],
    );

    expect(delta.text, 'hello from content');
    expect(delta.content[0], isA<TextContent>());
    expect(delta.content[1].toJson(), {
      'type': 'image',
      'mimeType': 'image/png',
      'data': 'aW1hZ2U=',
    });
    expect(delta.content[2].toJson(), {
      'type': 'audio',
      'mimeType': 'audio/wav',
      'data': 'YXVkaW8=',
    });
    expect(delta.content[3].toJson(), {
      'type': 'resource',
      'resource': {
        'uri': 'file:///workspace/README.md',
        'title': 'README.md',
        'mimeType': 'text/markdown',
        'text': '# Project notes',
      },
    });
    expect(delta.content[4].toJson(), {
      'type': 'resource_link',
      'uri': 'file:///workspace/lib/main.dart',
      'title': 'main.dart',
    });
  });

  test('tool calls accept legacy content and location payloads', () {
    final toolCall = ToolCall.fromJson(<String, dynamic>{
      'tool_call_id': 'call-1',
      'status': 'started',
      'name': 'Read file',
      'tool_kind': 'read',
      'content': 'reading now',
      'locations': <Object>[
        '/workspace/a.dart',
        <String, dynamic>{'path': '/workspace/b.dart', 'line': 12},
      ],
    });

    expect(toolCall.toolCallId, 'call-1');
    expect(toolCall.status, ToolCallStatus.pending);
    expect(toolCall.title, 'Read file');
    expect(toolCall.kind, ToolKind.read);
    expect(toolCall.content, [containsPair('text', 'reading now')]);
    expect(toolCall.locations?.map((location) => location.path), [
      '/workspace/a.dart',
      '/workspace/b.dart',
    ]);
    expect(toolCall.locations?.last.line, 12);

    final merged = toolCall.merge(<String, dynamic>{
      'status': 'completed',
      'toolName': 'Write file',
      'toolKind': 'edit',
      'content': <String, dynamic>{'type': 'text', 'text': 'done'},
      'locations': '/workspace/done.dart',
    });

    expect(merged.status, ToolCallStatus.completed);
    expect(merged.title, 'Write file');
    expect(merged.kind, ToolKind.edit);
    expect(merged.content, [containsPair('text', 'done')]);
    expect(merged.locations?.single.path, '/workspace/done.dart');
  });

  test('available commands accept legacy names, inputs, and schemas', () {
    final review = AvailableCommand.fromJson(<String, dynamic>{
      'id': 'review',
      'summary': 'Review the current diff.',
      'schema': <String, dynamic>{'type': 'object'},
      'input': 'Optional focus',
    });

    expect(review.name, 'review');
    expect(review.description, 'Review the current diff.');
    expect(review.parameters, containsPair('type', 'object'));
    expect(review.input?.hint, 'Optional focus');

    final apply = AvailableCommand.fromJson(<String, dynamic>{
      'command': 'apply',
      'input_schema': <String, dynamic>{'type': 'object'},
      'arguments': <String, dynamic>{'placeholder': 'Patch description'},
    });

    expect(apply.name, 'apply');
    expect(apply.parameters, containsPair('type', 'object'));
    expect(apply.input?.hint, 'Patch description');
  });

  test('plans accept legacy string steps and status aliases', () {
    final plan = Plan.fromJson(<String, dynamic>{
      'title': 'Legacy plan',
      'steps': <Object>[
        'Inspect current state',
        <String, dynamic>{
          'text': 'Patch parser',
          'priority': 'HIGH',
          'status': 'inProgress',
        },
        <String, dynamic>{'task': 'Run tests', 'status': 'done'},
        7,
      ],
    });

    expect(plan.entries.map((entry) => entry.content), [
      'Inspect current state',
      'Patch parser',
      'Run tests',
    ]);
    expect(plan.entries[0].priority, PlanEntryPriority.medium);
    expect(plan.entries[1].priority, PlanEntryPriority.high);
    expect(plan.entries[1].status, PlanEntryStatus.inProgress);
    expect(plan.entries[2].status, PlanEntryStatus.completed);
  });

  test('diffs accept legacy paths, string changes, and status aliases', () {
    final diff = Diff.fromJson(<String, dynamic>{
      'filePath': '/workspace/lib/main.dart',
      'status': 'done',
      'changes': <Object>[
        '+final enabled = true;',
        '-final enabled = false;',
        <String, dynamic>{
          'type': 'modified',
          'lineNumber': '42',
          'old': 'old call',
          'new': 'new call',
        },
        13,
      ],
    });

    expect(diff.id, '/workspace/lib/main.dart');
    expect(diff.uri, '/workspace/lib/main.dart');
    expect(diff.status, DiffStatus.applied);
    expect(diff.changes.map((change) => change.type), [
      'addition',
      'deletion',
      'modification',
    ]);
    expect(diff.changes.first.content, 'final enabled = true;');
    expect(diff.changes[1].content, 'final enabled = false;');
    expect(diff.changes[2].line, 42);
    expect(diff.changes[2].oldContent, 'old call');
    expect(diff.changes[2].newContent, 'new call');

    final rawDiff = Diff.fromJson(<String, dynamic>{
      'path': '/workspace/README.md',
      'status': 'failed',
      'diff': '+hello\n-world',
    });

    expect(rawDiff.status, DiffStatus.error);
    expect(rawDiff.uri, '/workspace/README.md');
    expect(rawDiff.changes.map((change) => change.type), [
      'addition',
      'deletion',
    ]);
  });

  test('session lists accept legacy field names', () {
    final result = SessionListResult.fromJson(<String, dynamic>{
      'items': <Object>[
        <String, dynamic>{
          'id': 'legacy-1',
          'workspaceRoot': '/workspace/app',
          'name': 'Legacy app',
          'updated_at': '2026-06-01T08:30:00Z',
          'metadata': <String, dynamic>{'agent': 'kimi'},
        },
        <String, dynamic>{
          'session_id': 'legacy-2',
          'path': '/workspace/tools',
          'label': 'Tooling',
        },
        'not-a-session',
        <String, dynamic>{'cwd': '/missing-id'},
      ],
      'next_cursor': 'cursor-2',
    });

    expect(result.nextCursor, 'cursor-2');
    expect(result.sessions.map((session) => session.sessionId), [
      'legacy-1',
      'legacy-2',
    ]);
    expect(result.sessions.first.cwd, '/workspace/app');
    expect(result.sessions.first.title, 'Legacy app');
    expect(
      result.sessions.first.updatedAt?.toUtc().toIso8601String(),
      '2026-06-01T08:30:00.000Z',
    );
    expect(result.sessions.first.meta, containsPair('agent', 'kimi'));
    expect(result.sessions[1].cwd, '/workspace/tools');
    expect(result.sessions[1].title, 'Tooling');
  });

  test('session results accept legacy config option payloads', () {
    final result = SessionResult.fromJson(<String, dynamic>{
      'session_id': 'session-1',
      'metadata': <String, dynamic>{'source': 'resume'},
      'config_options': <Object>[
        <String, dynamic>{
          'key': 'model',
          'label': 'Model',
          'current_value': 'kimi-k2',
          'choices': <Object>[
            'kimi-k2',
            <String, dynamic>{'id': 'glm-4.6', 'displayName': 'GLM 4.6'},
            <String, dynamic>{'value': 4, 'name': 'Four'},
            <String, dynamic>{},
          ],
          'category': 'model',
        },
        <String, dynamic>{
          'configId': 'auto_apply',
          'name': 'Auto apply',
          'type': ' BOOLEAN ',
          'selected': true,
          'values': <Map<String, Object>>[
            <String, Object>{'value': true, 'label': 'On'},
            <String, Object>{'value': false, 'label': 'Off'},
          ],
        },
        'not-a-config-option',
        <String, dynamic>{'name': 'Missing id', 'currentValue': 'x'},
      ],
    });

    expect(result.sessionId, 'session-1');
    expect(result.meta, containsPair('source', 'resume'));
    expect(result.configOptions, hasLength(2));

    final model = result.configOptions!.first;
    expect(model.id, 'model');
    expect(model.name, 'Model');
    expect(model.type, 'select');
    expect(model.currentValue, 'kimi-k2');
    expect(model.group, 'model');
    expect(model.options.map((choice) => choice.value), [
      'kimi-k2',
      'glm-4.6',
      '4',
    ]);
    expect(model.options[1].name, 'GLM 4.6');

    final autoApply = result.configOptions!.last;
    expect(autoApply.id, 'auto_apply');
    expect(autoApply.type, 'boolean');
    expect(autoApply.currentValue, 'true');
    expect(autoApply.options.map((choice) => choice.value), ['true', 'false']);
    expect(autoApply.options.map((choice) => choice.name), ['On', 'Off']);
  });
}
