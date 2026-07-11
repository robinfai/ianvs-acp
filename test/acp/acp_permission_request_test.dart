import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/acp_permission_request.dart';

void main() {
  AcpPermissionRequest request(List<String> options) {
    return AcpPermissionRequest(
      id: 'permission-1',
      title: 'Review action',
      rationale: 'Requested by agent',
      sessionId: 'session-1',
      toolName: 'tool',
      options: options,
      requestedAt: DateTime(2026, 5, 31, 12),
    );
  }

  test('permission labels match action keywords as words', () {
    final item = request(const ['Disallow', 'Allow']);

    expect(item.allowActionLabel, 'Allow Once');
    expect(item.denyActionLabel, 'Disallow');
  });

  test('permission labels keep specific agent action labels', () {
    final item = request(const ['Approve Plan', 'Reject Plan']);

    expect(item.allowActionLabel, 'Approve Plan');
    expect(item.denyActionLabel, 'Reject Plan');
  });

  test('permission labels treat negated allow phrases as deny actions', () {
    final item = request(const ['Do not allow', 'Allow']);

    expect(item.allowActionLabel, 'Allow Once');
    expect(item.denyActionLabel, 'Do not allow');
  });

  test('permission requests preserve structured agent choices', () {
    final item = AcpPermissionRequest(
      id: 'permission-1',
      title: 'Review action',
      rationale: 'Requested by agent',
      sessionId: 'session-1',
      toolName: 'tool',
      options: const ['Allow this time', 'Reject this time'],
      choices: const [
        AcpPermissionChoice(
          optionId: 'allow-once',
          name: 'Allow this time',
          kind: 'allow_once',
        ),
        AcpPermissionChoice(
          optionId: 'reject-once',
          name: 'Reject this time',
          kind: 'reject_once',
        ),
      ],
      requestedAt: DateTime(2026, 5, 31, 12),
    );

    expect(item.choices.first.optionId, 'allow-once');
    expect(item.choices.last.kind, 'reject_once');
    expect(item.toJson()['choices'], [
      {
        'optionId': 'allow-once',
        'name': 'Allow this time',
        'kind': 'allow_once',
      },
      {
        'optionId': 'reject-once',
        'name': 'Reject this time',
        'kind': 'reject_once',
      },
    ]);
  });

  test('permission fingerprints sort maps but preserve metadata strings', () {
    final first = AcpPermissionRequest(
      id: 'permission-a',
      title: ' Run command ',
      rationale: ' Requested by agent ',
      sessionId: ' session-1 ',
      toolName: ' terminal ',
      toolKind: ' execute ',
      options: const [' Allow ', ' Deny '],
      requestedAt: DateTime(2026, 5, 31, 12),
      metadata: const {
        'z': 'value',
        'nested': {'b': 2, 'a': 'one'},
      },
    );
    final second = AcpPermissionRequest(
      id: 'permission-b',
      title: 'Run command',
      rationale: 'Requested by agent',
      sessionId: 'session-1',
      toolName: 'terminal',
      toolKind: 'execute',
      options: const ['Allow', 'Deny'],
      requestedAt: DateTime(2026, 6, 1, 12),
      metadata: const {
        'nested': {'a': 'one', 'b': 2},
        'z': 'value',
      },
    );

    expect(first.contentFingerprint, second.contentFingerprint);
    final trailingPath = AcpPermissionRequest(
      id: first.id,
      title: first.title,
      rationale: first.rationale,
      sessionId: first.sessionId,
      toolName: first.toolName,
      toolKind: first.toolKind,
      options: first.options,
      requestedAt: first.requestedAt,
      metadata: const {'path': '/workspace/report '},
    );
    final exactPath = AcpPermissionRequest(
      id: first.id,
      title: first.title,
      rationale: first.rationale,
      sessionId: first.sessionId,
      toolName: first.toolName,
      toolKind: first.toolKind,
      options: first.options,
      requestedAt: first.requestedAt,
      metadata: const {'path': '/workspace/report'},
    );
    final leadingValue = AcpPermissionRequest(
      id: first.id,
      title: first.title,
      rationale: first.rationale,
      sessionId: first.sessionId,
      toolName: first.toolName,
      toolKind: first.toolKind,
      options: first.options,
      requestedAt: first.requestedAt,
      metadata: const {'key': ' value'},
    );
    final exactValue = AcpPermissionRequest(
      id: first.id,
      title: first.title,
      rationale: first.rationale,
      sessionId: first.sessionId,
      toolName: first.toolName,
      toolKind: first.toolKind,
      options: first.options,
      requestedAt: first.requestedAt,
      metadata: const {'key': 'value'},
    );

    expect(
      trailingPath.contentFingerprint,
      isNot(exactPath.contentFingerprint),
    );
    expect(
      leadingValue.contentFingerprint,
      isNot(exactValue.contentFingerprint),
    );
    expect(
      first.withGeneration(1).bindingKey,
      isNot(first.withGeneration(2).bindingKey),
    );
  });

  test('legacy persistent choices are not treated as single use', () {
    const choice = AcpPermissionChoice(
      optionId: 'allow-always',
      name: 'Always allow',
    );

    expect(choice.decision, AcpPermissionDecision.allow);
    expect(choice.isSingleUse, isFalse);
  });
}
