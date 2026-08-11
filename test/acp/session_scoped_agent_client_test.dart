import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/acp_agent_client.dart';
import 'package:ianvs_acp/acp/acp_permission_request.dart';
import 'package:ianvs_acp/acp/fake_agent_client.dart';
import 'package:ianvs_acp/acp/session_scoped_agent_client.dart';

void main() {
  test('routes sessions and permissions through one shared client', () async {
    final underlying = _TrackingAgentClient();
    final pool = SessionScopedAgentClientPool(underlying);
    final first = pool.acquire();
    final second = pool.acquire();

    await first.connect();
    await second.connect();
    final firstSession = await first.createSession(cwd: '/workspace/first');
    final secondSession = await second.createSession(cwd: '/workspace/second');

    final firstRequests = <AcpPermissionRequest>[];
    final secondRequests = <AcpPermissionRequest>[];
    final firstSubscription = first.permissionRequests.listen(
      firstRequests.add,
    );
    final secondSubscription = second.permissionRequests.listen(
      secondRequests.add,
    );
    addTearDown(firstSubscription.cancel);
    addTearDown(secondSubscription.cancel);

    underlying.emitPermissionRequest(
      _permissionRequest(id: 'permission-a', sessionId: firstSession.id),
    );
    underlying.emitPermissionRequest(
      _permissionRequest(id: 'permission-b', sessionId: secondSession.id),
    );

    expect(firstRequests.map((request) => request.id), ['permission-a']);
    expect(secondRequests.map((request) => request.id), ['permission-b']);
    await expectLater(
      second.respondToPermissionRequest(
        id: 'permission-a',
        decision: AcpPermissionDecision.allow,
      ),
      throwsStateError,
    );
    await first.respondToPermissionRequest(
      id: 'permission-a',
      decision: AcpPermissionDecision.allow,
    );
    expect(underlying.lastPermissionRequestId, 'permission-a');

    await first.cancelSession(sessionId: firstSession.id);
    expect(underlying.cancelledSessionIds, [firstSession.id]);
    await expectLater(
      first.cancelSession(sessionId: secondSession.id),
      throwsStateError,
    );

    await first.dispose();
    expect(underlying.disposeCount, 0);
    await second.dispose();
    expect(underlying.disposeCount, 1);
  });

  test('rejects restoring a session with an active prompt', () async {
    final underlying = _TrackingAgentClient();
    final pool = SessionScopedAgentClientPool(underlying);
    final first = pool.acquire();
    final second = pool.acquire();
    addTearDown(first.dispose);
    addTearDown(second.dispose);

    await first.connect();
    await first.restoreSession(
      sessionId: 'shared-session',
      cwd: '/workspace',
      onEvent: (_) {},
    );
    final activePrompt = first
        .sendPrompt(sessionId: 'shared-session', prompt: 'keep running')
        .listen(null);
    addTearDown(activePrompt.cancel);
    await expectLater(
      second.restoreSession(
        sessionId: 'shared-session',
        cwd: '/workspace',
        onEvent: (_) {},
      ),
      throwsStateError,
    );

    final firstRequests = <AcpPermissionRequest>[];
    final secondRequests = <AcpPermissionRequest>[];
    final firstSubscription = first.permissionRequests.listen(
      firstRequests.add,
    );
    final secondSubscription = second.permissionRequests.listen(
      secondRequests.add,
    );
    addTearDown(firstSubscription.cancel);
    addTearDown(secondSubscription.cancel);
    underlying.emitPermissionRequest(
      _permissionRequest(id: 'permission', sessionId: 'shared-session'),
    );

    expect(firstRequests, hasLength(1));
    expect(secondRequests, isEmpty);
  });

  test('transfers an idle session to a restoring lease', () async {
    final underlying = _TrackingAgentClient();
    final pool = SessionScopedAgentClientPool(underlying);
    final first = pool.acquire();
    final second = pool.acquire();
    addTearDown(first.dispose);
    addTearDown(second.dispose);

    await first.connect();
    await first.restoreSession(
      sessionId: 'idle-session',
      cwd: '/workspace',
      onEvent: (_) {},
    );
    await second.restoreSession(
      sessionId: 'idle-session',
      cwd: '/workspace',
      onEvent: (_) {},
    );

    await expectLater(
      first.sendPrompt(sessionId: 'idle-session', prompt: 'stale owner'),
      emitsError(isA<StateError>()),
    );
    await second
        .sendPrompt(sessionId: 'idle-session', prompt: 'new owner')
        .drain<void>();
    expect(underlying.lastPrompt, 'new owner');
  });

  test('reserves a session while its restore is pending', () async {
    final underlying = _ControlledRestoreAgentClient();
    final pool = SessionScopedAgentClientPool(underlying);
    final first = pool.acquire();
    final second = pool.acquire();
    addTearDown(first.dispose);
    addTearDown(second.dispose);

    await first.connect();
    final firstRestore = first.restoreSession(
      sessionId: 'pending-session',
      cwd: '/workspace',
      onEvent: (_) {},
    );
    await Future<void>.delayed(Duration.zero);

    await expectLater(
      second.restoreSession(
        sessionId: 'pending-session',
        cwd: '/workspace',
        onEvent: (_) {},
      ),
      throwsStateError,
    );

    underlying.releaseRestore();
    await firstRestore;
  });

  test('does not bind a restore that finishes after lease disposal', () async {
    final underlying = _ControlledRestoreAgentClient();
    final pool = SessionScopedAgentClientPool(underlying);
    final first = pool.acquire();
    final second = pool.acquire();
    addTearDown(first.dispose);
    addTearDown(second.dispose);

    await first.connect();
    final firstRestore = first.restoreSession(
      sessionId: 'disposed-restore',
      cwd: '/workspace',
      onEvent: (_) {},
    );
    final failedRestore = expectLater(firstRestore, throwsStateError);
    await Future<void>.delayed(Duration.zero);
    await first.dispose();
    underlying.releaseRestore();
    await failedRestore;

    await second.restoreSession(
      sessionId: 'disposed-restore',
      cwd: '/workspace',
      onEvent: (_) {},
    );
    await second.cancelSession(sessionId: 'disposed-restore');
    expect(underlying.cancelledSessionIds, ['disposed-restore']);
  });

  test('reclaims an unowned local snapshot before sending a prompt', () async {
    final underlying = _TrackingAgentClient();
    final pool = SessionScopedAgentClientPool(underlying);
    final lease = pool.acquire();
    addTearDown(lease.dispose);

    await lease.connect();
    await lease.restoreSession(
      sessionId: 'snapshot-a',
      cwd: '/workspace',
      onEvent: (_) {},
    );
    await lease.restoreSession(
      sessionId: 'snapshot-b',
      cwd: '/workspace',
      onEvent: (_) {},
    );

    await lease
        .sendPrompt(sessionId: 'snapshot-a', prompt: 'continue snapshot A')
        .drain<void>();

    expect(underlying.lastPrompt, 'continue snapshot A');
    await lease.cancelSession(sessionId: 'snapshot-a');
    expect(underlying.cancelledSessionIds, ['snapshot-a']);
  });

  test('does not reclaim a session owned by another lease', () async {
    final underlying = _TrackingAgentClient();
    final pool = SessionScopedAgentClientPool(underlying);
    final first = pool.acquire();
    final second = pool.acquire();
    addTearDown(first.dispose);
    addTearDown(second.dispose);

    await first.connect();
    await first.restoreSession(
      sessionId: 'shared-session',
      cwd: '/workspace',
      onEvent: (_) {},
    );
    await expectLater(
      second.sendPrompt(sessionId: 'shared-session', prompt: 'stale view'),
      emitsError(isA<StateError>()),
    );
  });
}

AcpPermissionRequest _permissionRequest({
  required String id,
  required String sessionId,
}) {
  return AcpPermissionRequest(
    id: id,
    lifecycleId: '$id-lifecycle',
    title: 'Run tool',
    rationale: 'Test permission routing.',
    sessionId: sessionId,
    toolName: 'test_tool',
    options: const <String>['allow', 'deny'],
    requestedAt: DateTime(2026, 8, 11),
  );
}

class _TrackingAgentClient extends FakeAgentClient {
  final List<String> cancelledSessionIds = <String>[];
  int disposeCount = 0;

  @override
  Future<void> cancelSession({required String sessionId}) async {
    cancelledSessionIds.add(sessionId);
  }

  @override
  Future<void> dispose() async {
    disposeCount += 1;
    await super.dispose();
  }
}

final class _ControlledRestoreAgentClient extends _TrackingAgentClient {
  final Completer<void> _restoreGate = Completer<void>();

  @override
  Future<AcpSessionRestoreSummary> restoreSession({
    required String sessionId,
    required String cwd,
    List<String> additionalDirectories = const <String>[],
    bool replayHistory = true,
    required AcpSessionRestoreEventObserver onEvent,
  }) async {
    await _restoreGate.future;
    return super.restoreSession(
      sessionId: sessionId,
      cwd: cwd,
      additionalDirectories: additionalDirectories,
      replayHistory: replayHistory,
      onEvent: onEvent,
    );
  }

  void releaseRestore() {
    if (!_restoreGate.isCompleted) _restoreGate.complete();
  }
}
