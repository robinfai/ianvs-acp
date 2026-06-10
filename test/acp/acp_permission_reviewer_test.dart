import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/acp_permission_request.dart';
import 'package:ianvs_acp/acp/acp_permission_reviewer.dart';
import 'package:ianvs_acp/acp/acp_session_settings.dart';
import 'package:ianvs_acp/acp/agent_event.dart';
import 'package:ianvs_acp/acp/agent_session.dart';
import 'package:ianvs_acp/acp/fake_agent_client.dart';
import 'package:ianvs_acp/acp/prompt_attachment.dart';

void main() {
  test('permission review payload includes command context and model', () {
    final payload = acpPermissionReviewPayload(
      AcpPermissionRequest(
        id: 'permission-1',
        title: 'Create terminal',
        rationale: 'Requested by agent',
        sessionId: 'session-1',
        toolName: 'terminal',
        toolKind: 'execute',
        options: const ['Allow', 'Deny'],
        requestedAt: DateTime.utc(2026, 5, 31, 12),
        metadata: const <String, Object?>{
          'command': 'git',
          'args': ['status'],
          'cwd': '/workspace',
          'workspaceRoot': '/workspace',
        },
      ),
      workspaceRoot: '/fallback',
      model: 'review-model',
    );

    expect(payload['schema'], 'ianvs-acp.permission-review.v1');
    expect(payload['model'], 'review-model');
    expect(payload['workspace'], {'root': '/workspace'});
    final command = payload['command'] as Map<String, Object?>;
    expect(command['line'], 'git status');
    expect(command['cwd'], '/workspace');
    final analysis = payload['analysis'] as Map<String, Object?>;
    expect(analysis['risk'], 'low');
    expect(analysis['suggestedDecision'], 'allow');
    expect(analysis['cwdWithinWorkspace'], isTrue);
  });

  test('permission review payload flags risky commands outside workspace', () {
    final payload = acpPermissionReviewPayload(
      AcpPermissionRequest(
        id: 'permission-1',
        title: 'Create terminal',
        rationale: 'Requested by agent',
        sessionId: 'session-1',
        toolName: 'terminal',
        toolKind: 'execute',
        options: const ['Allow', 'Deny'],
        requestedAt: DateTime.utc(2026, 5, 31, 12),
        metadata: const <String, Object?>{
          'command': 'rm -rf /tmp/build',
          'cwd': '/tmp',
          'workspaceRoot': '/workspace',
        },
      ),
      workspaceRoot: '/workspace',
    );

    final analysis = payload['analysis'] as Map<String, Object?>;
    expect(analysis['risk'], 'high');
    expect(analysis['suggestedDecision'], 'deny');
    expect(analysis['cwdWithinWorkspace'], isFalse);
    expect(analysis['signals'], contains('cwd_outside_workspace'));
    expect(analysis['signals'], contains('high_risk_command_pattern'));
  });

  test(
    'permission review payload treats additional directories as workspace',
    () {
      final payload = acpPermissionReviewPayload(
        AcpPermissionRequest(
          id: 'permission-1',
          title: 'Create terminal',
          rationale: 'Requested by agent',
          sessionId: 'session-1',
          toolName: 'terminal',
          toolKind: 'execute',
          options: const ['Allow', 'Deny'],
          requestedAt: DateTime.utc(2026, 5, 31, 12),
          metadata: const <String, Object?>{
            'command': 'ls',
            'cwd': '/shared/project',
            'workspaceRoot': '/workspace',
          },
        ),
        workspaceRoot: '/workspace',
        additionalDirectories: const ['/shared'],
      );

      expect(payload['workspace'], {
        'root': '/workspace',
        'additionalDirectories': ['/shared'],
      });
      final analysis = payload['analysis'] as Map<String, Object?>;
      expect(analysis['risk'], 'low');
      expect(analysis['suggestedDecision'], 'allow');
      expect(analysis['cwdWithinWorkspace'], isTrue);
      expect(analysis['signals'], isNot(contains('cwd_outside_workspace')));
      expect(analysis['workspaceRoots'], ['/workspace', '/shared']);
    },
  );

  test(
    'permission review payload extracts command from nested tool call input',
    () {
      final payload = acpPermissionReviewPayload(
        AcpPermissionRequest(
          id: 'permission-1',
          title: 'Bash',
          rationale: 'Requested by agent',
          sessionId: 'session-1',
          toolName: 'Bash',
          toolKind: 'execute',
          options: const ['Allow', 'Deny'],
          requestedAt: DateTime.utc(2026, 5, 31, 12),
          metadata: const <String, Object?>{
            'toolCall': {
              'title': 'Bash',
              'kind': 'execute',
              'rawInput': {'cmd': 'ls', 'cwd': '/workspace'},
            },
          },
        ),
        workspaceRoot: '/workspace',
      );

      final command = payload['command'] as Map<String, Object?>;
      expect(command['line'], 'ls');
      expect(command['cwd'], '/workspace');
      final analysis = payload['analysis'] as Map<String, Object?>;
      expect(analysis['risk'], 'low');
      expect(analysis['suggestedDecision'], 'allow');
      expect(analysis['signals'], contains('low_risk_command_pattern'));
      expect(analysis['signals'], isNot(contains('missing_command_context')));
    },
  );

  test('permission review payload extracts command from JSON raw input', () {
    final payload = acpPermissionReviewPayload(
      AcpPermissionRequest(
        id: 'permission-1',
        title: 'exec_command',
        rationale: 'Requested by agent',
        sessionId: 'session-1',
        toolName: 'exec_command',
        toolKind: 'execute',
        options: const ['Allow', 'Deny'],
        requestedAt: DateTime.utc(2026, 5, 31, 12),
        metadata: const <String, Object?>{
          'toolCall': {
            'title': 'exec_command',
            'kind': 'execute',
            'raw_input': '{"command":"ls -la","cwd":"/workspace"}',
          },
        },
      ),
      workspaceRoot: '/workspace',
    );

    final command = payload['command'] as Map<String, Object?>;
    expect(command['line'], 'ls -la');
    expect(command['cwd'], '/workspace');
    final analysis = payload['analysis'] as Map<String, Object?>;
    expect(analysis['risk'], 'low');
    expect(analysis['suggestedDecision'], 'allow');
  });

  test('permission review payload extracts command from permission title', () {
    final payload = acpPermissionReviewPayload(
      AcpPermissionRequest(
        id: 'permission-1',
        title: 'Running: ls -la',
        rationale: 'Requested by agent',
        sessionId: 'session-1',
        toolName: 'Bash',
        toolKind: 'execute',
        options: const ['Allow', 'Deny'],
        requestedAt: DateTime.utc(2026, 5, 31, 12),
      ),
      workspaceRoot: '/workspace',
    );

    final command = payload['command'] as Map<String, Object?>;
    expect(command['line'], 'ls -la');
    expect(command['cwd'], '/workspace');
    final analysis = payload['analysis'] as Map<String, Object?>;
    expect(analysis['risk'], 'low');
    expect(analysis['suggestedDecision'], 'allow');
    expect(analysis['signals'], contains('low_risk_command_pattern'));
  });

  test(
    'agent permission reviewer uses sidecar agent and model override',
    () async {
      final fake = _ReviewFakeAgentClient(
        reviewText:
            '{"decision":"allow","risk":"low","rationale":"Read-only list command."}',
        sessionSettings: const AcpSessionSettings(
          configOptions: [
            AcpConfigOption(
              id: 'model',
              name: 'Model',
              type: 'select',
              currentValue: 'primary-model',
              options: [
                AcpConfigOptionChoice(value: 'primary-model', name: 'Primary'),
                AcpConfigOptionChoice(value: 'review-model', name: 'Review'),
              ],
            ),
          ],
        ),
      );
      final reviewer = AcpAgentPermissionReviewer(
        agentName: 'Kimi Code Dev',
        modelOverride: 'review-model',
        clientFactory: () => fake,
      );
      addTearDown(reviewer.dispose);

      final result = await reviewer.review(
        AcpPermissionRequest(
          id: 'permission-1',
          title: 'Running: ls -la',
          rationale: 'Requested by agent',
          sessionId: 'session-1',
          toolName: 'Bash',
          toolKind: 'execute',
          options: const ['Allow', 'Deny'],
          requestedAt: DateTime.utc(2026, 5, 31, 12),
        ),
        workspaceRoot: '/workspace',
        additionalDirectories: const ['/shared'],
        model: 'primary-model',
      );

      expect(result?.decision, AcpPermissionDecision.allow);
      expect(result?.risk, 'low');
      expect(result?.reviewer, 'Kimi Code Dev');
      expect(result?.model, 'review-model');
      expect(fake.connected, isTrue);
      expect(fake.sessionCount, 1);
      expect(fake.lastCreateAdditionalDirectories, ['/shared']);
      expect(fake.lastConfigId, 'model');
      expect(fake.lastConfigValue, 'review-model');
      expect(fake.lastPrompt, contains('"model": "review-model"'));
      expect(fake.lastPrompt, contains('"additionalDirectories"'));
      expect(fake.lastPrompt, contains('"line": "ls -la"'));
    },
  );
}

class _ReviewFakeAgentClient extends FakeAgentClient {
  _ReviewFakeAgentClient({required this.reviewText, super.sessionSettings});

  final String reviewText;
  List<String> lastCreateAdditionalDirectories = const <String>[];

  @override
  Future<AgentSession> createSession({
    required String cwd,
    List<String> additionalDirectories = const <String>[],
  }) {
    lastCreateAdditionalDirectories = additionalDirectories;
    return super.createSession(
      cwd: cwd,
      additionalDirectories: additionalDirectories,
    );
  }

  @override
  Stream<AgentEvent> sendPrompt({
    required String sessionId,
    required String prompt,
    String? memoryContext,
    List<PromptAttachment> attachments = const <PromptAttachment>[],
  }) async* {
    lastPrompt = prompt;
    yield AgentEvent(
      type: AgentEventType.agentTextDelta,
      text: reviewText,
      timestamp: DateTime(2026, 5, 31, 12),
    );
    yield AgentEvent(
      type: AgentEventType.agentTextDone,
      text: '',
      timestamp: DateTime(2026, 5, 31, 12),
    );
  }
}
