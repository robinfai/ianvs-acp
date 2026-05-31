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
}
