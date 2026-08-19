import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/acp_agent_client.dart';
import 'package:ianvs_acp/acp/acp_available_commands.dart';
import 'package:ianvs_acp/acp/acp_permission_request.dart';
import 'package:ianvs_acp/acp/agent_event.dart';
import 'package:ianvs_acp/acp/agent_session.dart';
import 'package:ianvs_acp/acp/fake_agent_client.dart';
import 'package:ianvs_acp/acp/prompt_attachment.dart';
import 'package:ianvs_acp/acp/session_scoped_agent_client.dart';
import 'package:ianvs_acp/state/chat_controller.dart';
import 'package:ianvs_acp/storage/session_transcript_cache.dart';

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

  test('controller disposal completes for a pooled lease', () async {
    final underlying = _TrackingAgentClient();
    final controller = ChatController(
      client: SessionScopedAgentClientPool(underlying).acquire(),
      cwd: '/workspace',
    );

    controller.dispose();
    await controller.disposalComplete.timeout(const Duration(seconds: 1));

    expect(underlying.disposeCount, 1);
  });

  test(
    'routes late retired permissions for cancellation without audit',
    () async {
      final underlying = _TrackingAgentClient();
      final pool = SessionScopedAgentClientPool(underlying);
      final controller = ChatController(
        client: pool.acquire(),
        cwd: '/workspace',
      );
      addTearDown(controller.dispose);

      expect(await controller.newSession(), isTrue);
      final sessionId = controller.currentSession!.id;
      await controller.closeCurrentSession();
      underlying.emitPermissionRequest(
        _permissionRequest(id: 'late-retired', sessionId: sessionId),
      );
      await Future<void>.delayed(Duration.zero);

      expect(underlying.lastPermissionRequestId, 'late-retired');
      expect(underlying.lastPermissionDecision, AcpPermissionDecision.cancel);
      expect(controller.permissionHistory, isEmpty);
    },
  );

  test(
    'cancels retired permissions without a retired lease listener',
    () async {
      final underlying = _TrackingAgentClient();
      final pool = SessionScopedAgentClientPool(underlying);
      final retiredLease = pool.acquire();
      final observingLease = pool.acquire();
      addTearDown(retiredLease.dispose);
      addTearDown(observingLease.dispose);
      final observed = <AcpPermissionRequest>[];
      final subscription = observingLease.permissionRequests.listen(
        observed.add,
      );
      addTearDown(subscription.cancel);

      await retiredLease.connect();
      final session = await retiredLease.createSession(cwd: '/workspace');
      await retiredLease.closeSession(sessionId: session.id);
      underlying.emitPermissionRequest(
        _permissionRequest(id: 'late-without-listener', sessionId: session.id),
      );
      await Future<void>.delayed(Duration.zero);

      expect(observed, isEmpty);
      expect(underlying.lastPermissionRequestId, 'late-without-listener');
      expect(underlying.lastPermissionDecision, AcpPermissionDecision.cancel);
    },
  );

  test('routes setup permissions only to the creating lease', () async {
    final underlying = _SetupPermissionAgentClient();
    final pool = SessionScopedAgentClientPool(underlying);
    final idle = ChatController(client: pool.acquire(), cwd: '/workspace/idle');
    final creating = ChatController(
      client: pool.acquire(),
      cwd: '/workspace/creating',
    );
    addTearDown(idle.dispose);
    addTearDown(creating.dispose);

    await idle.connect();
    expect(await creating.newSession(), isTrue);
    await Future<void>.delayed(Duration.zero);

    expect(idle.pendingPermissionRequest, isNull);
    expect(idle.permissionHistory, isEmpty);
    expect(creating.pendingPermissionRequest?.id, 'setup-permission-1');
    expect(creating.currentSession?.id, 'setup-session-1');
  });

  test('cancels a setup permission whose session id does not match', () async {
    final underlying = _MismatchedSetupPermissionAgentClient();
    final controller = ChatController(
      client: SessionScopedAgentClientPool(underlying).acquire(),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    expect(await controller.newSession(), isTrue);
    await Future<void>.delayed(Duration.zero);

    expect(controller.currentSession?.id, 'actual-session');
    expect(controller.pendingPermissionRequest, isNull);
    expect(underlying.lastPermissionRequestId, 'mismatched-setup');
    expect(underlying.lastPermissionDecision, AcpPermissionDecision.cancel);
  });

  test('cancels provisional permissions when setup fails', () async {
    final underlying = _FailingSetupPermissionAgentClient();
    final controller = ChatController(
      client: SessionScopedAgentClientPool(underlying).acquire(),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    expect(await controller.newSession(), isFalse);
    await Future<void>.delayed(Duration.zero);

    expect(controller.currentSession, isNull);
    expect(controller.pendingPermissionRequest, isNull);
    expect(underlying.lastPermissionRequestId, 'failed-setup');
    expect(underlying.lastPermissionDecision, AcpPermissionDecision.cancel);
  });

  test(
    'failed create cancels late permission from the previous session',
    () async {
      final underlying = _FailingCreateWithPreviousPermissionAgentClient();
      final controller = ChatController(
        client: SessionScopedAgentClientPool(underlying).acquire(),
        cwd: '/workspace',
      );
      addTearDown(controller.dispose);

      expect(await controller.newSession(), isTrue);
      final previousSessionId = controller.currentSession!.id;
      controller.setToolCallExecutionPolicy(
        AcpToolCallExecutionPolicy.fullAccess,
      );
      expect(await controller.newSession(), isFalse);
      await Future<void>.delayed(Duration.zero);

      expect(controller.currentSession?.id, previousSessionId);
      expect(controller.pendingPermissionRequest, isNull);
      expect(underlying.lastPermissionRequestId, 'late-previous-permission');
      expect(underlying.lastPermissionDecision, AcpPermissionDecision.cancel);
    },
  );

  test(
    'reconnect rebinds an id without trusting retired setup events',
    () async {
      final underlying = _ReusedSetupPermissionAgentClient();
      final controller = ChatController(
        client: SessionScopedAgentClientPool(underlying).acquire(),
        cwd: '/workspace',
      );
      addTearDown(controller.dispose);

      expect(await controller.newSession(), isTrue);
      await controller.closeCurrentSession();
      await controller.reconnect();
      expect(await controller.newSession(), isTrue);
      await Future<void>.delayed(Duration.zero);

      expect(controller.currentSession?.id, 'reused-session');
      expect(controller.pendingPermissionRequest, isNull);
      expect(underlying.lastPermissionRequestId, 'reused-permission-2');
      expect(underlying.lastPermissionDecision, AcpPermissionDecision.cancel);
    },
  );

  test('close failure still isolates late permissions from siblings', () async {
    final underlying = _TrackingAgentClient(
      closeError: StateError('close failed'),
    );
    final pool = SessionScopedAgentClientPool(underlying);
    final idle = ChatController(client: pool.acquire(), cwd: '/workspace/idle');
    final active = ChatController(
      client: pool.acquire(),
      cwd: '/workspace/active',
    );
    addTearDown(idle.dispose);
    addTearDown(active.dispose);

    await idle.connect();
    expect(await active.newSession(), isTrue);
    final retiredSessionId = active.currentSession!.id;
    await active.closeCurrentSession();
    expect(await active.newSession(), isTrue);
    underlying.emitPermissionRequest(
      _permissionRequest(
        id: 'late-after-close-failure',
        sessionId: retiredSessionId,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(idle.pendingPermissionRequest, isNull);
    expect(active.pendingPermissionRequest, isNull);
    expect(underlying.lastPermissionRequestId, 'late-after-close-failure');
    expect(underlying.lastPermissionDecision, AcpPermissionDecision.cancel);
  });

  test('close failure cancels an already pending remote permission', () async {
    final underlying = _TrackingAgentClient(
      closeError: StateError('close failed'),
    );
    final controller = ChatController(
      client: SessionScopedAgentClientPool(underlying).acquire(),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    expect(await controller.newSession(), isTrue);
    underlying.emitPermissionRequest(
      _permissionRequest(
        id: 'pending-before-close',
        sessionId: controller.currentSession!.id,
      ),
    );
    expect(controller.pendingPermissionRequest, isNotNull);

    await controller.closeCurrentSession();
    await Future<void>.delayed(Duration.zero);

    expect(controller.pendingPermissionRequest, isNull);
    expect(underlying.lastPermissionRequestId, 'pending-before-close');
    expect(underlying.lastPermissionDecision, AcpPermissionDecision.cancel);
  });

  test(
    'delete failure preserves session but retires old permissions',
    () async {
      final underlying = _TrackingAgentClient(
        deleteError: StateError('delete failed'),
        supportsDelete: true,
      );
      final controller = ChatController(
        client: SessionScopedAgentClientPool(underlying).acquire(),
        cwd: '/workspace',
      );
      addTearDown(controller.dispose);

      expect(await controller.newSession(), isTrue);
      final sessionId = controller.currentSession!.id;
      underlying.emitPermissionRequest(
        _permissionRequest(id: 'pending-before-delete', sessionId: sessionId),
      );

      await controller.deleteCurrentSession();
      await Future<void>.delayed(Duration.zero);
      expect(controller.currentSession?.id, sessionId);
      expect(controller.pendingPermissionRequest, isNull);
      expect(underlying.lastPermissionRequestId, 'pending-before-delete');
      expect(underlying.lastPermissionDecision, AcpPermissionDecision.cancel);

      underlying.emitPermissionRequest(
        _permissionRequest(id: 'pending-after-delete', sessionId: sessionId),
      );
      expect(controller.pendingPermissionRequest?.id, 'pending-after-delete');
      await controller.resolvePermissionRequest(AcpPermissionDecision.allow);
      expect(underlying.lastPermissionRequestId, 'pending-after-delete');
      expect(underlying.lastPermissionDecision, AcpPermissionDecision.allow);
    },
  );

  test('stale leases cannot close or delete a transferred session', () async {
    final underlying = _TrackingAgentClient();
    final pool = SessionScopedAgentClientPool(underlying);
    final first = pool.acquire();
    final second = pool.acquire();
    addTearDown(first.dispose);
    addTearDown(second.dispose);

    await first.connect();
    final session = await first.createSession(cwd: '/workspace');
    await second.restoreSession(
      sessionId: session.id,
      cwd: '/workspace',
      onEvent: (_) {},
    );

    await expectLater(
      first.closeSession(sessionId: session.id),
      throwsStateError,
    );
    await expectLater(
      first.deleteSession(sessionId: session.id),
      throwsStateError,
    );
    await second.cancelSession(sessionId: session.id);
    expect(underlying.cancelledSessionIds, [session.id]);
  });

  test('close and restore cannot cross on the same session', () async {
    final underlying = _ControlledCloseAgentClient();
    final pool = SessionScopedAgentClientPool(underlying);
    final first = pool.acquire();
    final second = pool.acquire();
    addTearDown(first.dispose);
    addTearDown(second.dispose);

    await first.connect();
    final session = await first.createSession(cwd: '/workspace');
    final close = first.closeSession(sessionId: session.id);
    await underlying.closeStarted;

    expect(
      () => second.restoreSession(
        sessionId: session.id,
        cwd: '/workspace',
        onEvent: (_) {},
      ),
      throwsStateError,
    );

    underlying.releaseClose();
    await close;
  });

  test(
    'terminal close cancels existing and newly arriving permissions',
    () async {
      final underlying = _ControlledCloseAgentClient();
      final lease = SessionScopedAgentClientPool(underlying).acquire();
      addTearDown(lease.dispose);
      final requests = <AcpPermissionRequest>[];
      final invalidations = <AcpPermissionInvalidation>[];
      final requestSubscription = lease.permissionRequests.listen(requests.add);
      final invalidationSubscription = lease.permissionInvalidations.listen(
        invalidations.add,
      );
      addTearDown(requestSubscription.cancel);
      addTearDown(invalidationSubscription.cancel);

      await lease.connect();
      final session = await lease.createSession(cwd: '/workspace');
      underlying.emitPermissionRequest(
        _permissionRequest(id: 'before-terminal-close', sessionId: session.id),
      );
      expect(requests, hasLength(1));

      final close = lease.closeSession(sessionId: session.id);
      await underlying.closeStarted;
      await Future<void>.delayed(Duration.zero);
      expect(invalidations.single.requestId, 'before-terminal-close');
      await expectLater(
        lease.respondToPermissionRequest(
          id: 'before-terminal-close',
          decision: AcpPermissionDecision.allow,
        ),
        throwsStateError,
      );

      underlying.emitPermissionRequest(
        _permissionRequest(id: 'during-terminal-close', sessionId: session.id),
      );
      await Future<void>.delayed(Duration.zero);
      expect(requests, hasLength(1));
      expect(underlying.lastPermissionRequestId, 'during-terminal-close');
      expect(underlying.lastPermissionDecision, AcpPermissionDecision.cancel);

      underlying.releaseClose();
      await close;
    },
  );

  test(
    'close retires pooled ownership while a response is in flight',
    () async {
      final underlying = _ControlledPermissionResponseAgentClient();
      final controller = ChatController(
        client: SessionScopedAgentClientPool(underlying).acquire(),
        cwd: '/workspace',
      );
      addTearDown(controller.dispose);

      expect(await controller.newSession(), isTrue);
      final sessionId = controller.currentSession!.id;
      underlying.emitPermissionRequest(
        _permissionRequest(id: 'responding-during-close', sessionId: sessionId),
      );
      final response = controller.resolvePermissionRequest(
        AcpPermissionDecision.allow,
      );
      await underlying.responseStarted;

      await controller.closeCurrentSession();
      expect(controller.currentSession, isNull);
      underlying.releaseResponse();
      await response;
      underlying.emitPermissionRequest(
        _permissionRequest(
          id: 'late-after-rejected-close',
          sessionId: sessionId,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(controller.pendingPermissionRequest, isNull);
      expect(underlying.lastPermissionRequestId, 'late-after-rejected-close');
      expect(underlying.lastPermissionDecision, AcpPermissionDecision.cancel);
    },
  );

  test('terminal delete cancels permissions until deletion settles', () async {
    final underlying = _ControlledDeleteAgentClient();
    final lease = SessionScopedAgentClientPool(underlying).acquire();
    addTearDown(lease.dispose);
    final requests = <AcpPermissionRequest>[];
    final subscription = lease.permissionRequests.listen(requests.add);
    addTearDown(subscription.cancel);

    await lease.connect();
    final session = await lease.createSession(cwd: '/workspace');
    final deletion = lease.deleteSession(sessionId: session.id);
    await underlying.deleteStarted;
    underlying.emitPermissionRequest(
      _permissionRequest(id: 'during-terminal-delete', sessionId: session.id),
    );
    await Future<void>.delayed(Duration.zero);

    expect(requests, isEmpty);
    expect(underlying.lastPermissionRequestId, 'during-terminal-delete');
    expect(underlying.lastPermissionDecision, AcpPermissionDecision.cancel);
    underlying.releaseDelete();
    await deletion;
  });

  test(
    'available-command snapshot blocks session handoff until complete',
    () async {
      final underlying = _ControlledAvailableCommandsAgentClient();
      final pool = SessionScopedAgentClientPool(underlying);
      final first = pool.acquire();
      final second = pool.acquire();
      addTearDown(first.dispose);
      addTearDown(second.dispose);

      await first.connect();
      final session = await first.createSession(cwd: '/workspace');
      final commands = first.sessionAvailableCommands(session.id);
      await underlying.commandsStarted;

      await expectLater(
        second.restoreSession(
          sessionId: session.id,
          cwd: '/workspace',
          onEvent: (_) {},
        ),
        throwsStateError,
      );

      underlying.releaseCommands();
      expect((await commands)?.sessionId, session.id);
      await second.restoreSession(
        sessionId: session.id,
        cwd: '/workspace',
        onEvent: (_) {},
      );
    },
  );

  test(
    'sibling leases cannot read or change another session settings',
    () async {
      final underlying = _TrackingAgentClient();
      final pool = SessionScopedAgentClientPool(underlying);
      final first = pool.acquire();
      final second = pool.acquire();
      addTearDown(first.dispose);
      addTearDown(second.dispose);

      await first.connect();
      final session = await first.createSession(cwd: '/workspace/first');
      await second.createSession(cwd: '/workspace/second');

      expect(() => second.sessionSettings(session.id), throwsStateError);
      expect(
        () => second.setSessionMode(sessionId: session.id, modeId: 'plan'),
        throwsStateError,
      );
      expect(
        () => second.setConfigOption(
          sessionId: session.id,
          configId: 'model',
          value: 'fast',
        ),
        throwsStateError,
      );
    },
  );

  test('a retired session cannot be reclaimed by its former lease', () async {
    final underlying = _TrackingAgentClient();
    final lease = SessionScopedAgentClientPool(underlying).acquire();
    addTearDown(lease.dispose);

    await lease.connect();
    final session = await lease.createSession(cwd: '/workspace');
    await lease.closeSession(sessionId: session.id);

    await expectLater(
      lease.sendPrompt(sessionId: session.id, prompt: 'too late'),
      emitsError(isA<StateError>()),
    );
    expect(() => lease.sessionSettings(session.id), throwsStateError);
  });

  test('retiring a session revokes every lease local-view claim', () async {
    final underlying = _TrackingAgentClient();
    final pool = SessionScopedAgentClientPool(underlying);
    final first = pool.acquire();
    final second = pool.acquire();
    addTearDown(first.dispose);
    addTearDown(second.dispose);

    await first.connect();
    await first.restoreSession(
      sessionId: 'shared-retired',
      cwd: '/workspace',
      onEvent: (_) {},
    );
    await first.restoreSession(
      sessionId: 'first-current',
      cwd: '/workspace',
      onEvent: (_) {},
    );
    await second.restoreSession(
      sessionId: 'shared-retired',
      cwd: '/workspace',
      onEvent: (_) {},
    );
    await second.closeSession(sessionId: 'shared-retired');

    await expectLater(
      first.sendPrompt(sessionId: 'shared-retired', prompt: 'stale'),
      emitsError(isA<StateError>()),
    );
  });

  test('a lease cannot reclaim an unknown unowned session', () async {
    final underlying = _TrackingAgentClient();
    final pool = SessionScopedAgentClientPool(underlying);
    final first = pool.acquire();
    final stranger = pool.acquire();
    addTearDown(first.dispose);
    addTearDown(stranger.dispose);

    await first.connect();
    final oldSession = await first.createSession(cwd: '/workspace/old');
    await first.createSession(cwd: '/workspace/new');

    await expectLater(
      stranger.closeSession(sessionId: oldSession.id),
      throwsStateError,
    );
    await expectLater(
      stranger.forkSession(sessionId: oldSession.id, cwd: '/workspace/fork'),
      throwsStateError,
    );
    await expectLater(
      stranger.sendPrompt(sessionId: oldSession.id, prompt: 'stale'),
      emitsError(isA<StateError>()),
    );

    await first
        .sendPrompt(sessionId: oldSession.id, prompt: 'known local snapshot')
        .drain<void>();
    await first.cancelSession(sessionId: oldSession.id);
    expect(underlying.cancelledSessionIds, [oldSession.id]);
  });

  test(
    'an activated local view refreshes bounded ownership provenance',
    () async {
      final underlying = _TrackingAgentClient();
      final lease = SessionScopedAgentClientPool(underlying).acquire();
      addTearDown(lease.dispose);
      final ownership = lease as AcpLocalSessionViewOwnership;

      await lease.connect();
      final first = await lease.createSession(cwd: '/workspace/first');
      for (var index = 1; index < 513; index += 1) {
        await lease.createSession(cwd: '/workspace/$index');
      }

      ownership.retainLocalSessionView(first.id);
      await lease.sessionSettings(first.id);
      await lease.cancelSession(sessionId: first.id);
      expect(underlying.cancelledSessionIds, [first.id]);
    },
  );

  test(
    'inactive known session permissions never attach to another setup',
    () async {
      final underlying = _NthControlledCreateAgentClient(blockAtCall: 3);
      final pool = SessionScopedAgentClientPool(underlying);
      final owner = pool.acquire();
      final creating = pool.acquire();
      addTearDown(owner.dispose);
      addTearDown(creating.dispose);
      final creatingRequests = <AcpPermissionRequest>[];
      final subscription = creating.permissionRequests.listen(
        creatingRequests.add,
      );
      addTearDown(subscription.cancel);

      await owner.connect();
      final inactive = await owner.createSession(cwd: '/workspace/inactive');
      await owner.createSession(cwd: '/workspace/current');
      final create = creating.createSession(cwd: '/workspace/new');
      await underlying.blockedCreateStarted;
      underlying.emitPermissionRequest(
        _permissionRequest(id: 'late-inactive', sessionId: inactive.id),
      );
      await Future<void>.delayed(Duration.zero);

      expect(creatingRequests, isEmpty);
      expect(underlying.lastPermissionRequestId, 'late-inactive');
      expect(underlying.lastPermissionDecision, AcpPermissionDecision.cancel);
      underlying.releaseBlockedCreate();
      await create;
      await owner.sessionSettings(inactive.id);
      await owner.cancelSession(sessionId: inactive.id);
    },
  );

  test(
    'evicted known-session provenance still rejects setup misrouting',
    () async {
      final underlying = _NthControlledCreateAgentClient(blockAtCall: 514);
      final pool = SessionScopedAgentClientPool(underlying);
      final owner = pool.acquire();
      final creating = pool.acquire();
      addTearDown(owner.dispose);
      addTearDown(creating.dispose);
      final creatingRequests = <AcpPermissionRequest>[];
      final subscription = creating.permissionRequests.listen(
        creatingRequests.add,
      );
      addTearDown(subscription.cancel);

      await owner.connect();
      final first = await owner.createSession(cwd: '/workspace/0');
      for (var index = 1; index < 513; index += 1) {
        await owner.createSession(cwd: '/workspace/$index');
      }
      final create = creating.createSession(cwd: '/workspace/new');
      await underlying.blockedCreateStarted;
      underlying.emitPermissionRequest(
        _permissionRequest(id: 'late-evicted-known', sessionId: first.id),
      );
      await Future<void>.delayed(Duration.zero);

      expect(creatingRequests, isEmpty);
      expect(underlying.lastPermissionRequestId, 'late-evicted-known');
      expect(underlying.lastPermissionDecision, AcpPermissionDecision.cancel);
      underlying.releaseBlockedCreate();
      await create;
      final ownership = owner as AcpLocalSessionViewOwnership;
      ownership.retainLocalSessionView(first.id);
      await owner.sessionSettings(first.id);
      await owner.cancelSession(sessionId: first.id);
    },
  );

  test('session handoff revokes the previous permission owner', () async {
    final underlying = _TrackingAgentClient();
    final pool = SessionScopedAgentClientPool(underlying);
    final first = pool.acquire();
    final second = pool.acquire();
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    final invalidations = <AcpPermissionInvalidation>[];
    final requestSubscription = first.permissionRequests.listen((_) {});
    final invalidationSubscription = first.permissionInvalidations.listen(
      invalidations.add,
    );
    addTearDown(requestSubscription.cancel);
    addTearDown(invalidationSubscription.cancel);

    await first.connect();
    final session = await first.createSession(cwd: '/workspace');
    underlying.emitPermissionRequest(
      _permissionRequest(id: 'handoff-permission', sessionId: session.id),
    );
    await second.restoreSession(
      sessionId: session.id,
      cwd: '/workspace',
      onEvent: (_) {},
    );
    await Future<void>.delayed(Duration.zero);

    expect(invalidations.single.requestId, 'handoff-permission');
    expect(underlying.lastPermissionRequestId, 'handoff-permission');
    expect(underlying.lastPermissionDecision, AcpPermissionDecision.cancel);
    await expectLater(
      first.respondToPermissionRequest(
        id: 'handoff-permission',
        decision: AcpPermissionDecision.allow,
      ),
      throwsStateError,
    );
  });

  test(
    'failed session handoff preserves the previous permission owner',
    () async {
      final underlying = _FailingRestoreAgentClient();
      final pool = SessionScopedAgentClientPool(underlying);
      final first = pool.acquire();
      final second = pool.acquire();
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      final requestSubscription = first.permissionRequests.listen((_) {});
      addTearDown(requestSubscription.cancel);

      await first.connect();
      await first.restoreSession(
        sessionId: 'failed-handoff',
        cwd: '/workspace',
        onEvent: (_) {},
      );
      underlying.emitPermissionRequest(
        _permissionRequest(
          id: 'preserved-after-failed-handoff',
          sessionId: 'failed-handoff',
        ),
      );
      underlying.failRestore = true;

      await expectLater(
        second.restoreSession(
          sessionId: 'failed-handoff',
          cwd: '/workspace',
          onEvent: (_) {},
        ),
        throwsStateError,
      );
      await first.respondToPermissionRequest(
        id: 'preserved-after-failed-handoff',
        decision: AcpPermissionDecision.allow,
      );
      expect(underlying.lastPermissionDecision, AcpPermissionDecision.allow);
    },
  );

  test('create cannot take an id owned by another lease', () async {
    final underlying = _CollidingCreateAgentClient();
    final pool = SessionScopedAgentClientPool(underlying);
    final first = pool.acquire();
    final second = pool.acquire();
    addTearDown(first.dispose);
    addTearDown(second.dispose);

    await first.connect();
    final session = await first.createSession(cwd: '/workspace/first');
    await expectLater(
      second.createSession(cwd: '/workspace/second'),
      throwsStateError,
    );

    await first.cancelSession(sessionId: session.id);
    expect(underlying.cancelledSessionIds, [session.id]);
  });

  test('fork cannot take an id owned by another lease', () async {
    final underlying = _CollidingForkAgentClient();
    final pool = SessionScopedAgentClientPool(underlying);
    final first = pool.acquire();
    final second = pool.acquire();
    addTearDown(first.dispose);
    addTearDown(second.dispose);

    await first.connect();
    final collision = await first.createSession(cwd: '/workspace/first');
    await second.restoreSession(
      sessionId: 'fork-source',
      cwd: '/workspace/second',
      onEvent: (_) {},
    );
    await expectLater(
      second.forkSession(sessionId: 'fork-source', cwd: '/workspace/fork'),
      throwsStateError,
    );

    await first.cancelSession(sessionId: collision.id);
    expect(underlying.cancelledSessionIds, [collision.id]);
  });

  test('permission lifecycle reuse revokes the previous lease owner', () async {
    final underlying = _TrackingAgentClient();
    final pool = SessionScopedAgentClientPool(underlying);
    final first = pool.acquire();
    final second = pool.acquire();
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    final firstRequests = <AcpPermissionRequest>[];
    final secondRequests = <AcpPermissionRequest>[];
    final firstInvalidations = <AcpPermissionInvalidation>[];
    final firstSubscription = first.permissionRequests.listen(
      firstRequests.add,
    );
    final secondSubscription = second.permissionRequests.listen(
      secondRequests.add,
    );
    final firstInvalidationSubscription = first.permissionInvalidations.listen(
      firstInvalidations.add,
    );
    addTearDown(firstSubscription.cancel);
    addTearDown(secondSubscription.cancel);
    addTearDown(firstInvalidationSubscription.cancel);

    await first.connect();
    final firstSession = await first.createSession(cwd: '/workspace/first');
    final secondSession = await second.createSession(cwd: '/workspace/second');
    underlying.emitPermissionRequest(
      _permissionRequest(
        id: 'reused-permission',
        sessionId: firstSession.id,
        lifecycleId: 'old-lifecycle',
      ),
    );
    underlying.emitPermissionRequest(
      _permissionRequest(
        id: 'reused-permission',
        sessionId: secondSession.id,
        lifecycleId: 'new-lifecycle',
      ),
    );
    underlying.emitPermissionInvalidation(
      AcpPermissionInvalidation(
        requestId: 'reused-permission',
        lifecycleId: 'old-lifecycle',
        sessionId: firstSession.id,
        reason: AcpPermissionInvalidationReason.sessionClosed,
        invalidatedAt: DateTime(2026, 8, 20),
      ),
    );

    expect(firstRequests, hasLength(1));
    expect(secondRequests, hasLength(1));
    expect(firstInvalidations, hasLength(1));
    expect(firstInvalidations.single.lifecycleId, 'old-lifecycle');
    await expectLater(
      first.respondToPermissionRequest(
        id: 'reused-permission',
        decision: AcpPermissionDecision.allow,
      ),
      throwsStateError,
    );
    await second.respondToPermissionRequest(
      id: 'reused-permission',
      decision: AcpPermissionDecision.allow,
    );
    expect(underlying.lastPermissionRequestId, 'reused-permission');
  });

  test(
    'preserves opaque permission and lifecycle identifiers exactly',
    () async {
      final underlying = _TrackingAgentClient();
      final pool = SessionScopedAgentClientPool(underlying);
      final lease = pool.acquire();
      addTearDown(lease.dispose);
      final requests = <AcpPermissionRequest>[];
      final invalidations = <AcpPermissionInvalidation>[];
      final requestSubscription = lease.permissionRequests.listen(requests.add);
      final invalidationSubscription = lease.permissionInvalidations.listen(
        invalidations.add,
      );
      addTearDown(requestSubscription.cancel);
      addTearDown(invalidationSubscription.cancel);

      await lease.connect();
      final session = await lease.createSession(cwd: '/workspace');
      underlying.emitPermissionRequest(
        _permissionRequest(
          id: ' permission-with-space ',
          sessionId: session.id,
          lifecycleId: ' lifecycle-with-space ',
        ),
      );
      expect(requests.single.id, ' permission-with-space ');

      underlying.emitPermissionInvalidation(
        AcpPermissionInvalidation(
          requestId: ' permission-with-space ',
          lifecycleId: ' lifecycle-with-space ',
          sessionId: session.id,
          reason: AcpPermissionInvalidationReason.sessionClosed,
          invalidatedAt: DateTime(2026, 8, 20),
        ),
      );
      expect(invalidations.single.requestId, ' permission-with-space ');
    },
  );

  test('bounds permission ownership and cancels overflow requests', () async {
    final underlying = _TrackingAgentClient();
    final pool = SessionScopedAgentClientPool(underlying);
    final lease = pool.acquire();
    addTearDown(lease.dispose);
    final requests = <AcpPermissionRequest>[];
    final subscription = lease.permissionRequests.listen(requests.add);
    addTearDown(subscription.cancel);

    await lease.connect();
    final session = await lease.createSession(cwd: '/workspace');
    for (var index = 0; index < 513; index += 1) {
      underlying.emitPermissionRequest(
        _permissionRequest(id: 'permission-$index', sessionId: session.id),
      );
    }
    await Future<void>.delayed(Duration.zero);

    expect(requests, hasLength(512));
    expect(underlying.lastPermissionRequestId, 'permission-512');
    expect(underlying.lastPermissionDecision, AcpPermissionDecision.cancel);
  });

  test(
    'central permission cancellation participates in the logout gate',
    () async {
      final underlying = _ControlledPermissionResponseAgentClient();
      final pool = SessionScopedAgentClientPool(underlying);
      final first = pool.acquire();
      final second = pool.acquire();
      addTearDown(first.dispose);
      addTearDown(second.dispose);

      await first.connect();
      underlying.emitPermissionRequest(
        _permissionRequest(id: 'unowned', sessionId: 'unknown-session'),
      );
      await underlying.responseStarted;

      await expectLater(second.logout(), throwsStateError);
      underlying.releaseResponse();
      await Future<void>.delayed(Duration.zero);
    },
  );

  test(
    'defers a reused request id until central cancellation completes',
    () async {
      final underlying = _ControlledPermissionResponseAgentClient();
      final pool = SessionScopedAgentClientPool(underlying);
      final lease = pool.acquire();
      addTearDown(lease.dispose);
      final requests = <AcpPermissionRequest>[];
      final subscription = lease.permissionRequests.listen(requests.add);
      addTearDown(subscription.cancel);

      await lease.connect();
      final session = await lease.createSession(cwd: '/workspace');
      underlying.emitPermissionRequest(
        _permissionRequest(id: 'reused-during-cancel', sessionId: 'unknown'),
      );
      await underlying.responseStarted;
      underlying.emitPermissionRequest(
        _permissionRequest(
          id: 'reused-during-cancel',
          sessionId: session.id,
          lifecycleId: 'new-lifecycle',
        ),
      );

      expect(requests, isEmpty);
      underlying.releaseResponse();
      await Future<void>.delayed(Duration.zero);

      expect(requests.single.lifecycleId, 'new-lifecycle');
    },
  );

  test(
    'drops a deferred request invalidated during central cancellation',
    () async {
      final underlying = _ControlledPermissionResponseAgentClient();
      final pool = SessionScopedAgentClientPool(underlying);
      final lease = pool.acquire();
      addTearDown(lease.dispose);
      final requests = <AcpPermissionRequest>[];
      final subscription = lease.permissionRequests.listen(requests.add);
      addTearDown(subscription.cancel);

      await lease.connect();
      final session = await lease.createSession(cwd: '/workspace');
      underlying.emitPermissionRequest(
        _permissionRequest(
          id: 'invalidated-during-cancel',
          sessionId: 'unknown',
        ),
      );
      await underlying.responseStarted;
      underlying.emitPermissionRequest(
        _permissionRequest(
          id: 'invalidated-during-cancel',
          sessionId: session.id,
          lifecycleId: 'deferred-lifecycle',
        ),
      );
      underlying.emitPermissionInvalidation(
        AcpPermissionInvalidation(
          requestId: 'invalidated-during-cancel',
          lifecycleId: 'deferred-lifecycle',
          sessionId: session.id,
          reason: AcpPermissionInvalidationReason.timedOut,
          invalidatedAt: DateTime(2026, 8, 20),
        ),
      );

      underlying.releaseResponse();
      await Future<void>.delayed(Duration.zero);
      expect(requests, isEmpty);
    },
  );

  test(
    'drops a deferred request invalidated during an owned response',
    () async {
      final underlying = _ControlledPermissionResponseAgentClient();
      final pool = SessionScopedAgentClientPool(underlying);
      final first = pool.acquire();
      final second = pool.acquire();
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      final firstSubscription = first.permissionRequests.listen((_) {});
      final secondRequests = <AcpPermissionRequest>[];
      final secondSubscription = second.permissionRequests.listen(
        secondRequests.add,
      );
      addTearDown(firstSubscription.cancel);
      addTearDown(secondSubscription.cancel);

      await first.connect();
      final firstSession = await first.createSession(cwd: '/workspace/first');
      final secondSession = await second.createSession(
        cwd: '/workspace/second',
      );
      underlying.emitPermissionRequest(
        _permissionRequest(
          id: 'invalidated-during-response',
          sessionId: firstSession.id,
          lifecycleId: 'first-lifecycle',
        ),
      );
      final response = first.respondToPermissionRequest(
        id: 'invalidated-during-response',
        decision: AcpPermissionDecision.allow,
      );
      await underlying.responseStarted;
      underlying.emitPermissionRequest(
        _permissionRequest(
          id: 'invalidated-during-response',
          sessionId: secondSession.id,
          lifecycleId: 'second-lifecycle',
        ),
      );
      underlying.emitPermissionInvalidation(
        AcpPermissionInvalidation(
          requestId: 'invalidated-during-response',
          lifecycleId: 'second-lifecycle',
          sessionId: secondSession.id,
          reason: AcpPermissionInvalidationReason.timedOut,
          invalidatedAt: DateTime(2026, 8, 20),
        ),
      );

      underlying.releaseResponse();
      await response;
      expect(secondRequests, isEmpty);
    },
  );

  test(
    'does not revive an exact duplicate invalidated during response',
    () async {
      final underlying = _ControlledPermissionResponseAgentClient();
      final lease = SessionScopedAgentClientPool(underlying).acquire();
      addTearDown(lease.dispose);
      final requests = <AcpPermissionRequest>[];
      final subscription = lease.permissionRequests.listen(requests.add);
      addTearDown(subscription.cancel);

      await lease.connect();
      final session = await lease.createSession(cwd: '/workspace');
      final request = _permissionRequest(
        id: 'exact-duplicate',
        sessionId: session.id,
        lifecycleId: 'same-lifecycle',
      );
      underlying.emitPermissionRequest(request);
      final response = lease.respondToPermissionRequest(
        id: request.id,
        decision: AcpPermissionDecision.allow,
      );
      await underlying.responseStarted;
      underlying.emitPermissionRequest(request);
      underlying.emitPermissionInvalidation(
        AcpPermissionInvalidation(
          requestId: request.id,
          lifecycleId: request.lifecycleId,
          sessionId: request.sessionId,
          reason: AcpPermissionInvalidationReason.timedOut,
          invalidatedAt: DateTime(2026, 8, 20),
        ),
      );

      underlying.releaseResponse();
      await response;
      expect(requests, hasLength(1));
    },
  );

  test('bounds concurrent central permission cancellations', () async {
    final underlying = _ControlledPermissionResponseAgentClient();
    final lease = SessionScopedAgentClientPool(underlying).acquire();
    addTearDown(lease.dispose);

    await lease.connect();
    for (var index = 0; index < 100; index += 1) {
      underlying.emitPermissionRequest(
        _permissionRequest(id: 'unowned-$index', sessionId: 'unknown-$index'),
      );
    }
    await underlying.responseStarted;
    await Future<void>.delayed(Duration.zero);

    expect(underlying.responseCalls, 64);
    underlying.releaseResponse();
    await Future<void>.delayed(Duration.zero);
  });

  test(
    'defers a reused request id while central cancellation is queued',
    () async {
      final underlying = _ControlledPermissionResponseAgentClient();
      final lease = SessionScopedAgentClientPool(underlying).acquire();
      addTearDown(lease.dispose);
      final requests = <AcpPermissionRequest>[];
      final subscription = lease.permissionRequests.listen(requests.add);
      addTearDown(subscription.cancel);

      await lease.connect();
      final session = await lease.createSession(cwd: '/workspace');
      for (var index = 0; index < 64; index += 1) {
        underlying.emitPermissionRequest(
          _permissionRequest(id: 'active-cancel-$index', sessionId: 'unknown'),
        );
      }
      await underlying.responseStarted;
      underlying.emitPermissionRequest(
        _permissionRequest(id: 'queued-reuse', sessionId: 'unknown'),
      );
      underlying.emitPermissionRequest(
        _permissionRequest(
          id: 'queued-reuse',
          sessionId: session.id,
          lifecycleId: 'owned-lifecycle',
        ),
      );

      expect(requests, isEmpty);
      underlying.releaseResponse();
      for (var index = 0; index < 5 && requests.isEmpty; index += 1) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(requests.single.lifecycleId, 'owned-lifecycle');
    },
  );

  test(
    'old invalidation withdraws queued cancellation before id reuse',
    () async {
      final underlying = _ControlledPermissionResponseAgentClient();
      final lease = SessionScopedAgentClientPool(underlying).acquire();
      addTearDown(lease.dispose);
      final requests = <AcpPermissionRequest>[];
      final subscription = lease.permissionRequests.listen(requests.add);
      addTearDown(subscription.cancel);

      await lease.connect();
      final session = await lease.createSession(cwd: '/workspace');
      for (var index = 0; index < 64; index += 1) {
        underlying.emitPermissionRequest(
          _permissionRequest(id: 'active-old-$index', sessionId: 'unknown'),
        );
      }
      await underlying.responseStarted;
      underlying.emitPermissionRequest(
        _permissionRequest(
          id: 'queued-lifecycle-reuse',
          sessionId: 'old-session',
          lifecycleId: 'old-lifecycle',
        ),
      );
      underlying.emitPermissionInvalidation(
        AcpPermissionInvalidation(
          requestId: 'queued-lifecycle-reuse',
          lifecycleId: 'old-lifecycle',
          sessionId: 'old-session',
          reason: AcpPermissionInvalidationReason.timedOut,
          invalidatedAt: DateTime(2026, 8, 20),
        ),
      );
      underlying.emitPermissionRequest(
        _permissionRequest(
          id: 'queued-lifecycle-reuse',
          sessionId: session.id,
          lifecycleId: 'new-lifecycle',
        ),
      );

      expect(requests.single.lifecycleId, 'new-lifecycle');
      underlying.releaseResponse();
      await Future<void>.delayed(Duration.zero);
    },
  );

  test('retirement overflow preserves a new setup permission', () async {
    final underlying = _ThirdSetupPermissionAgentClient();
    final controller = ChatController(
      client: SessionScopedAgentClientPool(underlying).acquire(),
      cwd: '/workspace',
      permissionHistoryLimit: 1,
    );
    addTearDown(controller.dispose);

    expect(await controller.newSession(), isTrue);
    await controller.closeCurrentSession();
    expect(await controller.newSession(), isTrue);
    await controller.closeCurrentSession();
    expect(await controller.newSession(), isTrue);
    await Future<void>.delayed(Duration.zero);

    expect(controller.currentSession?.id, 'fake-session-3');
    expect(controller.pendingPermissionRequest?.id, 'third-setup-permission');
    expect(underlying.lastPermissionRequestId, isNull);
  });

  test('pool retirement overflow cancels evicted late permissions', () async {
    final underlying = _RetiredOverflowAgentClient();
    final pool = SessionScopedAgentClientPool(underlying);
    final retiring = pool.acquire();
    final creating = pool.acquire();
    addTearDown(retiring.dispose);
    addTearDown(creating.dispose);
    final creatingRequests = <AcpPermissionRequest>[];
    final subscription = creating.permissionRequests.listen(
      creatingRequests.add,
    );
    addTearDown(subscription.cancel);

    await retiring.connect();
    for (var index = 0; index < 513; index += 1) {
      final session = await retiring.createSession(cwd: '/workspace');
      await retiring.closeSession(sessionId: session.id);
    }
    final create = creating.createSession(cwd: '/workspace/new');
    await underlying.lastCreateStarted;
    underlying.emitPermissionRequest(
      _permissionRequest(id: 'evicted-late', sessionId: 'fake-session-1'),
    );
    await Future<void>.delayed(Duration.zero);

    expect(creatingRequests, isEmpty);
    expect(underlying.lastPermissionRequestId, 'evicted-late');
    expect(underlying.lastPermissionDecision, AcpPermissionDecision.cancel);
    underlying.releaseLastCreate();
    await create;
  });

  test(
    'retired history overflow still routes a fresh setup permission',
    () async {
      final underlying = _FreshSetupAfterRetirementAgentClient();
      final pool = SessionScopedAgentClientPool(underlying);
      final retiring = pool.acquire();
      final creating = pool.acquire();
      addTearDown(retiring.dispose);
      addTearDown(creating.dispose);
      final requests = <AcpPermissionRequest>[];
      final subscription = creating.permissionRequests.listen(requests.add);
      addTearDown(subscription.cancel);

      await retiring.connect();
      for (var index = 0; index < 513; index += 1) {
        final session = await retiring.createSession(cwd: '/workspace/$index');
        await retiring.closeSession(sessionId: session.id);
      }
      final session = await creating.createSession(cwd: '/workspace/fresh');
      await Future<void>.delayed(Duration.zero);

      expect(session.id, 'fake-session-514');
      expect(requests.single.id, 'fresh-after-retirement-history');
      expect(underlying.lastPermissionRequestId, isNull);
    },
  );

  test(
    'logout keeps provenance for late events on the shared stream',
    () async {
      final underlying = _NthControlledCreateAgentClient(blockAtCall: 2);
      final pool = SessionScopedAgentClientPool(underlying);
      final retiring = pool.acquire();
      final creating = pool.acquire();
      addTearDown(retiring.dispose);
      addTearDown(creating.dispose);
      final requests = <AcpPermissionRequest>[];
      final subscription = creating.permissionRequests.listen(requests.add);
      addTearDown(subscription.cancel);

      await retiring.connect();
      final retired = await retiring.createSession(cwd: '/workspace/old');
      await retiring.closeSession(sessionId: retired.id);
      await retiring.logout();
      final create = creating.createSession(cwd: '/workspace/new');
      await underlying.blockedCreateStarted;
      underlying.emitPermissionRequest(
        _permissionRequest(id: 'late-after-logout', sessionId: retired.id),
      );
      await Future<void>.delayed(Duration.zero);

      expect(requests, isEmpty);
      expect(underlying.lastPermissionRequestId, 'late-after-logout');
      expect(underlying.lastPermissionDecision, AcpPermissionDecision.cancel);
      underlying.releaseBlockedCreate();
      await create;
    },
  );

  test(
    'sibling connect does not clear retired permission provenance',
    () async {
      final underlying = _SiblingConnectAgentClient();
      final pool = SessionScopedAgentClientPool(underlying);
      final retiring = pool.acquire();
      final creating = pool.acquire();
      addTearDown(retiring.dispose);
      addTearDown(creating.dispose);
      final requests = <AcpPermissionRequest>[];
      final subscription = creating.permissionRequests.listen(requests.add);
      addTearDown(subscription.cancel);

      await retiring.connect();
      final retired = await retiring.createSession(cwd: '/workspace/old');
      await retiring.closeSession(sessionId: retired.id);
      await creating.connect();
      final create = creating.createSession(cwd: '/workspace/new');
      await underlying.secondCreateStarted;
      underlying.emitPermissionRequest(
        _permissionRequest(id: 'late-after-connect', sessionId: retired.id),
      );
      await Future<void>.delayed(Duration.zero);

      expect(requests, isEmpty);
      expect(underlying.lastPermissionRequestId, 'late-after-connect');
      underlying.releaseSecondCreate();
      await create;
    },
  );

  test('serializes setup operations across leases', () async {
    final underlying = _SerializedCreateAgentClient();
    final pool = SessionScopedAgentClientPool(underlying);
    final first = pool.acquire();
    final second = pool.acquire();
    addTearDown(first.dispose);
    addTearDown(second.dispose);

    await first.connect();
    final firstCreate = first.createSession(cwd: '/workspace/first');
    await underlying.firstCreateStarted;
    final secondCreate = second.createSession(cwd: '/workspace/second');
    await Future<void>.delayed(Duration.zero);
    expect(underlying.createCalls, 1);

    underlying.releaseFirstCreate();
    await firstCreate;
    await underlying.secondCreateStarted;
    expect(underlying.createCalls, 2);
    underlying.releaseSecondCreate();
    await secondCreate;
  });

  test('does not start a new setup with unresolved owned permission', () async {
    final underlying = _TrackingAgentClient();
    final lease = SessionScopedAgentClientPool(underlying).acquire();
    addTearDown(lease.dispose);
    final subscription = lease.permissionRequests.listen((_) {});
    addTearDown(subscription.cancel);

    await lease.connect();
    final session = await lease.createSession(cwd: '/workspace');
    underlying.emitPermissionRequest(
      _permissionRequest(id: 'unresolved-before-setup', sessionId: session.id),
    );

    await expectLater(
      lease.createSession(cwd: '/workspace/new'),
      throwsStateError,
    );
    expect(underlying.sessionCount, 1);
  });

  test('create cannot bind a session reserved by restore', () async {
    final underlying = _RestoreCollisionAgentClient();
    final pool = SessionScopedAgentClientPool(underlying);
    final restoring = pool.acquire();
    final creating = pool.acquire();
    addTearDown(restoring.dispose);
    addTearDown(creating.dispose);

    await restoring.connect();
    final restore = restoring.restoreSession(
      sessionId: 'reserved-target',
      cwd: '/workspace/restore',
      onEvent: (_) {},
    );
    await underlying.restoreStarted;
    await expectLater(
      creating.createSession(cwd: '/workspace/create'),
      throwsStateError,
    );

    underlying.releaseRestore();
    await restore;
    await restoring.cancelSession(sessionId: 'reserved-target');
    expect(underlying.cancelledSessionIds, ['reserved-target']);
  });

  test('rejects concurrent responses for one permission binding', () async {
    final underlying = _ControlledPermissionResponseAgentClient();
    final pool = SessionScopedAgentClientPool(underlying);
    final lease = pool.acquire();
    addTearDown(lease.dispose);
    final subscription = lease.permissionRequests.listen((_) {});
    addTearDown(subscription.cancel);

    await lease.connect();
    final session = await lease.createSession(cwd: '/workspace');
    underlying.emitPermissionRequest(
      _permissionRequest(id: 'single-response', sessionId: session.id),
    );
    final firstResponse = lease.respondToPermissionRequest(
      id: 'single-response',
      decision: AcpPermissionDecision.allow,
    );
    await underlying.responseStarted;

    await expectLater(
      lease.respondToPermissionRequest(
        id: 'single-response',
        decision: AcpPermissionDecision.deny,
      ),
      throwsStateError,
    );
    underlying.releaseResponse();
    await firstResponse;
  });

  test('future leases observe a terminal permission stream', () async {
    final underlying = _TrackingAgentClient();
    final pool = SessionScopedAgentClientPool(underlying);
    final first = pool.acquire();
    addTearDown(first.dispose);

    await underlying.closePermissionRequests();
    await Future<void>.delayed(Duration.zero);
    final second = pool.acquire();
    addTearDown(second.dispose);

    await expectLater(second.permissionRequests, emitsDone);
  });

  test('terminal permission streams cancel live remote requests', () async {
    final underlying = _TrackingAgentClient();
    final lease = SessionScopedAgentClientPool(underlying).acquire();
    addTearDown(lease.dispose);
    final subscription = lease.permissionRequests.listen((_) {});
    addTearDown(subscription.cancel);

    await lease.connect();
    final session = await lease.createSession(cwd: '/workspace');
    underlying.emitPermissionRequest(
      _permissionRequest(id: 'terminal-live', sessionId: session.id),
    );
    await underlying.closePermissionRequests();
    await Future<void>.delayed(Duration.zero);

    expect(underlying.lastPermissionRequestId, 'terminal-live');
    expect(underlying.lastPermissionDecision, AcpPermissionDecision.cancel);
    await expectLater(
      lease.respondToPermissionRequest(
        id: 'terminal-live',
        decision: AcpPermissionDecision.allow,
      ),
      throwsStateError,
    );
  });

  test(
    'terminal invalidation stream fails the permission channel closed',
    () async {
      final underlying = _TrackingAgentClient();
      final lease = SessionScopedAgentClientPool(underlying).acquire();
      addTearDown(lease.dispose);
      final requests = <AcpPermissionRequest>[];
      final invalidations = <AcpPermissionInvalidation>[];
      final requestDone = Completer<void>();
      final requestSubscription = lease.permissionRequests.listen(
        requests.add,
        onDone: requestDone.complete,
      );
      final invalidationSubscription = lease.permissionInvalidations.listen(
        invalidations.add,
      );
      addTearDown(requestSubscription.cancel);
      addTearDown(invalidationSubscription.cancel);

      await lease.connect();
      final session = await lease.createSession(cwd: '/workspace');
      underlying.emitPermissionRequest(
        _permissionRequest(
          id: 'live-before-invalidation-done',
          sessionId: session.id,
        ),
      );
      expect(requests, hasLength(1));

      await underlying.closePermissionInvalidations();
      await requestDone.future;
      await Future<void>.delayed(Duration.zero);
      expect(invalidations.single.requestId, 'live-before-invalidation-done');
      expect(
        underlying.lastPermissionRequestId,
        'live-before-invalidation-done',
      );
      expect(underlying.lastPermissionDecision, AcpPermissionDecision.cancel);

      underlying.emitPermissionRequest(
        _permissionRequest(
          id: 'future-after-invalidation-done',
          sessionId: session.id,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(requests, hasLength(1));
      expect(
        underlying.lastPermissionRequestId,
        'future-after-invalidation-done',
      );
      expect(underlying.lastPermissionDecision, AcpPermissionDecision.cancel);
    },
  );

  test('terminal permission streams discard deferred requests', () async {
    final underlying = _ControlledPermissionResponseAgentClient();
    final lease = SessionScopedAgentClientPool(underlying).acquire();
    addTearDown(lease.dispose);
    final requests = <AcpPermissionRequest>[];
    final subscription = lease.permissionRequests.listen(requests.add);
    addTearDown(subscription.cancel);

    await lease.connect();
    final session = await lease.createSession(cwd: '/workspace');
    underlying.emitPermissionRequest(
      _permissionRequest(id: 'terminal-deferred', sessionId: 'unknown-session'),
    );
    await underlying.responseStarted;
    underlying.emitPermissionRequest(
      _permissionRequest(
        id: 'terminal-deferred',
        sessionId: session.id,
        lifecycleId: 'new-lifecycle',
      ),
    );
    await underlying.closePermissionRequests();
    underlying.releaseResponse();
    for (
      var index = 0;
      index < 10 && underlying.responseCalls < 2;
      index += 1
    ) {
      await Future<void>.delayed(Duration.zero);
    }

    expect(requests, isEmpty);
    expect(underlying.responseIds, <String>[
      'terminal-deferred',
      'terminal-deferred',
    ]);
    expect(underlying.responseDecisions, <AcpPermissionDecision>[
      AcpPermissionDecision.cancel,
      AcpPermissionDecision.cancel,
    ]);
  });

  test('terminal permission streams cancel future busy-id requests', () async {
    final underlying = _ControlledPermissionResponseAgentClient();
    final lease = SessionScopedAgentClientPool(underlying).acquire();
    addTearDown(lease.dispose);
    final requests = <AcpPermissionRequest>[];
    final subscription = lease.permissionRequests.listen(requests.add);
    addTearDown(subscription.cancel);

    await lease.connect();
    final session = await lease.createSession(cwd: '/workspace');
    underlying.emitPermissionRequest(
      _permissionRequest(
        id: 'terminal-future-busy',
        sessionId: 'unknown-session',
      ),
    );
    await underlying.responseStarted;
    await underlying.closePermissionInvalidations();
    underlying.emitPermissionRequest(
      _permissionRequest(
        id: 'terminal-future-busy',
        sessionId: session.id,
        lifecycleId: 'future-lifecycle',
      ),
    );
    underlying.releaseResponse();
    for (
      var index = 0;
      index < 10 && underlying.responseCalls < 2;
      index += 1
    ) {
      await Future<void>.delayed(Duration.zero);
    }

    expect(requests, isEmpty);
    expect(underlying.responseIds, <String>[
      'terminal-future-busy',
      'terminal-future-busy',
    ]);
    expect(underlying.responseDecisions, <AcpPermissionDecision>[
      AcpPermissionDecision.cancel,
      AcpPermissionDecision.cancel,
    ]);
  });

  test(
    'terminal permission channel preserves an in-flight allow outcome',
    () async {
      final underlying = _ControlledPermissionResponseAgentClient();
      final controller = ChatController(
        client: SessionScopedAgentClientPool(underlying).acquire(),
        cwd: '/workspace',
      );
      addTearDown(controller.dispose);

      expect(await controller.newSession(), isTrue);
      underlying.emitPermissionRequest(
        _permissionRequest(
          id: 'allow-while-channel-closes',
          sessionId: controller.currentSession!.id,
        ),
      );
      expect(
        controller.pendingPermissionRequest?.id,
        'allow-while-channel-closes',
      );

      final response = controller.resolvePermissionRequest(
        AcpPermissionDecision.allow,
      );
      await underlying.responseStarted;
      await underlying.closePermissionInvalidations();
      await Future<void>.delayed(Duration.zero);

      expect(
        controller.pendingPermissionRequest?.id,
        'allow-while-channel-closes',
      );
      underlying.releaseResponse();
      await response;
      await Future<void>.delayed(Duration.zero);

      expect(controller.pendingPermissionRequest, isNull);
      expect(
        controller.permissionHistory.single.status,
        AcpPermissionAuditStatus.allowed,
      );
      expect(underlying.responseIds, <String>['allow-while-channel-closes']);
      expect(underlying.responseDecisions, <AcpPermissionDecision>[
        AcpPermissionDecision.allow,
      ]);
    },
  );

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

  test(
    'does not transfer a session while its owner resolves permission',
    () async {
      final underlying = _ControlledPermissionResponseAgentClient();
      final pool = SessionScopedAgentClientPool(underlying);
      final first = pool.acquire();
      final second = pool.acquire();
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      final subscription = first.permissionRequests.listen((_) {});
      addTearDown(subscription.cancel);

      await first.connect();
      final session = await first.createSession(cwd: '/workspace/a');
      underlying.emitPermissionRequest(
        _permissionRequest(id: 'handoff-response', sessionId: session.id),
      );
      final response = first.respondToPermissionRequest(
        id: 'handoff-response',
        decision: AcpPermissionDecision.allow,
      );
      await underlying.responseStarted;

      await expectLater(
        second.restoreSession(
          sessionId: session.id,
          cwd: '/workspace/b',
          onEvent: (_) {},
        ),
        throwsStateError,
      );
      underlying.releaseResponse();
      await response;
    },
  );

  test(
    'failed response after owner disposal is cancelled before id reuse',
    () async {
      final underlying = _FailingControlledPermissionResponseAgentClient();
      final pool = SessionScopedAgentClientPool(underlying);
      final first = pool.acquire();
      final second = pool.acquire();
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      final subscription = first.permissionRequests.listen((_) {});
      addTearDown(subscription.cancel);

      await first.connect();
      final session = await first.createSession(cwd: '/workspace/a');
      underlying.emitPermissionRequest(
        _permissionRequest(id: 'failed-response', sessionId: session.id),
      );
      final response = first.respondToPermissionRequest(
        id: 'failed-response',
        decision: AcpPermissionDecision.allow,
      );
      final failedResponse = expectLater(response, throwsStateError);
      await underlying.responseStarted;
      await first.dispose();

      await expectLater(
        second.restoreSession(
          sessionId: session.id,
          cwd: '/workspace/b',
          onEvent: (_) {},
        ),
        throwsStateError,
      );
      underlying.releaseResponse();
      await failedResponse;
      for (
        var index = 0;
        index < 5 && underlying.lastPermissionDecision == null;
        index += 1
      ) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(underlying.lastPermissionRequestId, 'failed-response');
      expect(underlying.lastPermissionDecision, AcpPermissionDecision.cancel);
      await second.restoreSession(
        sessionId: session.id,
        cwd: '/workspace/b',
        onEvent: (_) {},
      );
    },
  );

  test(
    'does not resolve permission after a sibling reserves handoff',
    () async {
      final underlying = _ControlledRestoreAgentClient();
      final pool = SessionScopedAgentClientPool(underlying);
      final first = pool.acquire();
      final second = pool.acquire();
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      final subscription = first.permissionRequests.listen((_) {});
      addTearDown(subscription.cancel);

      await first.connect();
      final session = await first.createSession(cwd: '/workspace/a');
      underlying.emitPermissionRequest(
        _permissionRequest(id: 'reserved-handoff', sessionId: session.id),
      );
      final restore = second.restoreSession(
        sessionId: session.id,
        cwd: '/workspace/b',
        onEvent: (_) {},
      );
      await Future<void>.delayed(Duration.zero);

      await expectLater(
        first.respondToPermissionRequest(
          id: 'reserved-handoff',
          decision: AcpPermissionDecision.allow,
        ),
        throwsStateError,
      );
      underlying.releaseRestore();
      await restore;
    },
  );

  test(
    'preserves setup permissions emitted during a session handoff',
    () async {
      final underlying = _RestorePermissionAgentClient();
      final pool = SessionScopedAgentClientPool(underlying);
      final first = pool.acquire();
      final second = pool.acquire();
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      final requests = <AcpPermissionRequest>[];
      final invalidations = <AcpPermissionInvalidation>[];
      final requestSubscription = second.permissionRequests.listen(
        requests.add,
      );
      final invalidationSubscription = second.permissionInvalidations.listen(
        invalidations.add,
      );
      addTearDown(requestSubscription.cancel);
      addTearDown(invalidationSubscription.cancel);

      await first.connect();
      await first.restoreSession(
        sessionId: 'handoff-with-setup',
        cwd: '/workspace',
        onEvent: (_) {},
      );
      underlying.emitOnRestore = true;
      await second.restoreSession(
        sessionId: 'handoff-with-setup',
        cwd: '/workspace',
        onEvent: (_) {},
      );

      expect(requests.single.id, 'restore-setup-permission');
      expect(invalidations, isEmpty);
      await second.respondToPermissionRequest(
        id: 'restore-setup-permission',
        decision: AcpPermissionDecision.allow,
      );
      expect(underlying.lastPermissionDecision, AcpPermissionDecision.allow);
    },
  );

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

  test('shared logout clears every idle controller in the pool', () async {
    final underlying = _TrackingAgentClient();
    final pool = SessionScopedAgentClientPool(underlying);
    final first = ChatController(client: pool.acquire(), cwd: '/workspace/a');
    final second = ChatController(client: pool.acquire(), cwd: '/workspace/b');
    addTearDown(first.dispose);
    addTearDown(second.dispose);

    expect(await first.newSession(), isTrue);
    expect(await second.newSession(), isTrue);
    expect(first.currentSession, isNotNull);
    expect(second.currentSession, isNotNull);

    await second.logout();

    expect(underlying.logoutCount, 1);
    expect(first.currentSession, isNull);
    expect(first.sessions, isEmpty);
    expect(second.currentSession, isNull);
    expect(second.sessions, isEmpty);
  });

  test('shared logout is rejected while another lease prompts', () async {
    final underlying = _TrackingAgentClient();
    final pool = SessionScopedAgentClientPool(underlying);
    final first = pool.acquire();
    final second = pool.acquire();
    addTearDown(first.dispose);
    addTearDown(second.dispose);

    await first.connect();
    final session = await first.createSession(cwd: '/workspace/a');
    final activePrompt = first
        .sendPrompt(sessionId: session.id, prompt: 'keep running')
        .listen(null);
    addTearDown(activePrompt.cancel);

    await expectLater(second.logout(), throwsStateError);
    expect(underlying.logoutCount, 0);
  });

  test('cancel remains available while the owned prompt is active', () async {
    final underlying = _HangingPromptAgentClient();
    final lease = SessionScopedAgentClientPool(underlying).acquire();
    addTearDown(lease.dispose);

    await lease.connect();
    final session = await lease.createSession(cwd: '/workspace');
    final promptDone = lease
        .sendPrompt(sessionId: session.id, prompt: 'keep running')
        .drain<void>();
    await Future<void>.delayed(Duration.zero);

    await lease.cancelSession(sessionId: session.id);
    await promptDone;
    expect(underlying.cancelledSessionIds, [session.id]);
  });

  test(
    'shared logout rejects a restore that starts while it is pending',
    () async {
      final underlying = _ControlledLogoutAgentClient();
      final pool = SessionScopedAgentClientPool(underlying);
      final first = pool.acquire();
      final second = pool.acquire();
      addTearDown(first.dispose);
      addTearDown(second.dispose);

      await first.connect();
      final logout = first.logout();
      await underlying.logoutStarted;

      await expectLater(
        second.restoreSession(
          sessionId: 'late-restore',
          cwd: '/workspace/b',
          onEvent: (_) {},
        ),
        throwsStateError,
      );

      underlying.releaseLogout();
      await logout;
      expect(underlying.logoutCount, 1);
    },
  );

  test('shared logout is rejected while a sibling create is pending', () async {
    final underlying = _ControlledCreateAgentClient();
    final pool = SessionScopedAgentClientPool(underlying);
    final first = pool.acquire();
    final second = pool.acquire();
    addTearDown(first.dispose);
    addTearDown(second.dispose);

    await first.connect();
    final create = first.createSession(cwd: '/workspace/a');
    await underlying.createStarted;

    await expectLater(second.logout(), throwsStateError);
    underlying.releaseCreate();
    await create;
    expect(underlying.logoutCount, 0);
  });

  test('queued owner setup blocks a sibling session handoff', () async {
    final underlying = _SiblingConnectAgentClient();
    final pool = SessionScopedAgentClientPool(underlying);
    final owner = pool.acquire();
    final blocker = pool.acquire();
    final restoring = pool.acquire();
    addTearDown(owner.dispose);
    addTearDown(blocker.dispose);
    addTearDown(restoring.dispose);

    await owner.connect();
    final owned = await owner.createSession(cwd: '/workspace/owner');
    final blockingCreate = blocker.createSession(cwd: '/workspace/blocker');
    await underlying.secondCreateStarted;
    final queuedCreate = owner.createSession(cwd: '/workspace/queued');

    await expectLater(
      restoring.restoreSession(
        sessionId: owned.id,
        cwd: '/workspace/restoring',
        onEvent: (_) {},
      ),
      throwsStateError,
    );

    underlying.releaseSecondCreate();
    await blockingCreate;
    await queuedCreate;
  });

  test(
    'shared logout rejects a prompt that starts while it is pending',
    () async {
      final underlying = _ControlledLogoutAgentClient();
      final pool = SessionScopedAgentClientPool(underlying);
      final first = pool.acquire();
      final second = pool.acquire();
      addTearDown(first.dispose);
      addTearDown(second.dispose);

      await first.connect();
      final session = await second.createSession(cwd: '/workspace/b');
      final logout = first.logout();
      await underlying.logoutStarted;

      await expectLater(
        second.sendPrompt(sessionId: session.id, prompt: 'too late'),
        emitsError(isA<StateError>()),
      );

      underlying.releaseLogout();
      await logout;
    },
  );

  test('final lease disposal waits for a pending shared logout', () async {
    final underlying = _ControlledLogoutAgentClient();
    final pool = SessionScopedAgentClientPool(underlying);
    final lease = pool.acquire();

    await lease.connect();
    final logout = lease.logout();
    await underlying.logoutStarted;
    await lease.dispose();
    expect(underlying.disposeCount, 0);

    underlying.releaseLogout();
    await logout;
    expect(underlying.disposeCount, 1);
  });

  test(
    'final lease disposal defers the underlying close during setup',
    () async {
      final underlying = _ControlledCreateAgentClient();
      final lease = SessionScopedAgentClientPool(underlying).acquire();

      await lease.connect();
      final create = lease.createSession(cwd: '/workspace');
      final failedCreate = expectLater(create, throwsStateError);
      await underlying.createStarted;
      await lease.dispose();
      expect(underlying.disposeCount, 0);

      underlying.releaseCreate();
      await failedCreate;
      await Future<void>.delayed(Duration.zero);
      expect(underlying.disposeCount, 1);
    },
  );

  test('shared logout invalidates a sibling resume waiting on cache', () async {
    final underlying = _TrackingAgentClient(supportsResumeSession: true);
    final pool = SessionScopedAgentClientPool(underlying);
    final cache = _ControlledTranscriptCache();
    final first = ChatController(
      client: pool.acquire(),
      cwd: '/workspace/a',
      sessionTranscriptCache: cache,
    );
    final second = ChatController(client: pool.acquire(), cwd: '/workspace/b');
    addTearDown(first.dispose);
    addTearDown(second.dispose);

    expect(await second.newSession(), isTrue);
    final updatedAt = DateTime.utc(2026, 8, 20);
    final resume = first.resumeSession('cached-session', updatedAt: updatedAt);
    await cache.loadStarted;
    await Future<void>.delayed(Duration.zero);
    expect(first.isSessionReplayLoading, isTrue);

    await second.logout();
    expect(underlying.logoutCount, 1);
    cache.complete();
    await resume;

    expect(underlying.restoreCount, 0);
    expect(first.currentSession, isNull);
    expect(first.isSessionReplayLoading, isFalse);
  });

  test('reconnect abandons the previous pooled session generation', () async {
    final underlying = _ControlledReconnectAgentClient();
    final controller = ChatController(
      client: SessionScopedAgentClientPool(underlying).acquire(),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    expect(await controller.newSession(), isTrue);
    final abandonedSessionId = controller.currentSession!.id;
    final reconnect = controller.reconnect();
    await underlying.reconnectStarted;
    underlying.emitPermissionRequest(
      _permissionRequest(
        id: 'late-reconnect-permission',
        sessionId: abandonedSessionId,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(controller.pendingPermissionRequest, isNull);
    expect(underlying.lastPermissionRequestId, 'late-reconnect-permission');
    expect(underlying.lastPermissionDecision, AcpPermissionDecision.cancel);
    underlying.releaseReconnect();
    await reconnect;
  });
}

AcpPermissionRequest _permissionRequest({
  required String id,
  required String sessionId,
  String? lifecycleId,
}) {
  return AcpPermissionRequest(
    id: id,
    lifecycleId: lifecycleId ?? '$id-lifecycle',
    title: 'Run tool',
    rationale: 'Test permission routing.',
    sessionId: sessionId,
    toolName: 'test_tool',
    options: const <String>['allow', 'deny'],
    requestedAt: DateTime(2026, 8, 11),
  );
}

class _TrackingAgentClient extends FakeAgentClient {
  _TrackingAgentClient({
    super.supportsResumeSession,
    super.closeError,
    super.deleteError,
    super.supportsDelete,
  });

  final List<String> cancelledSessionIds = <String>[];
  int disposeCount = 0;
  int logoutCount = 0;
  int restoreCount = 0;

  @override
  Future<void> cancelSession({required String sessionId}) async {
    cancelledSessionIds.add(sessionId);
  }

  @override
  Future<void> dispose() async {
    disposeCount += 1;
    await super.dispose();
  }

  @override
  Future<void> logout() async {
    logoutCount += 1;
    await super.logout();
  }

  @override
  Future<AcpSessionRestoreSummary> restoreSession({
    required String sessionId,
    required String cwd,
    List<String> additionalDirectories = const <String>[],
    bool replayHistory = true,
    required AcpSessionRestoreEventObserver onEvent,
  }) async {
    restoreCount += 1;
    return super.restoreSession(
      sessionId: sessionId,
      cwd: cwd,
      additionalDirectories: additionalDirectories,
      replayHistory: replayHistory,
      onEvent: onEvent,
    );
  }
}

final class _SetupPermissionAgentClient extends FakeAgentClient {
  @override
  Future<AgentSession> createSession({
    required String cwd,
    List<String> additionalDirectories = const <String>[],
  }) async {
    final id = 'setup-session-${sessionCount + 1}';
    emitPermissionRequest(
      _permissionRequest(id: 'setup-permission-1', sessionId: id),
    );
    await Future<void>.delayed(Duration.zero);
    sessionCount += 1;
    return AgentSession(
      id: id,
      cwd: cwd,
      createdAt: DateTime(2026, 8, 20),
      additionalDirectories: additionalDirectories,
    );
  }
}

final class _MismatchedSetupPermissionAgentClient extends FakeAgentClient {
  @override
  Future<AgentSession> createSession({
    required String cwd,
    List<String> additionalDirectories = const <String>[],
  }) async {
    emitPermissionRequest(
      _permissionRequest(id: 'mismatched-setup', sessionId: 'stale-session'),
    );
    await Future<void>.delayed(Duration.zero);
    return AgentSession(
      id: 'actual-session',
      cwd: cwd,
      createdAt: DateTime(2026, 8, 20),
      additionalDirectories: additionalDirectories,
    );
  }
}

final class _FailingSetupPermissionAgentClient extends FakeAgentClient {
  @override
  Future<AgentSession> createSession({
    required String cwd,
    List<String> additionalDirectories = const <String>[],
  }) async {
    emitPermissionRequest(
      _permissionRequest(id: 'failed-setup', sessionId: 'orphan-session'),
    );
    await Future<void>.delayed(Duration.zero);
    throw StateError('setup failed');
  }
}

final class _FailingCreateWithPreviousPermissionAgentClient
    extends FakeAgentClient {
  @override
  Future<AgentSession> createSession({
    required String cwd,
    List<String> additionalDirectories = const <String>[],
  }) async {
    if (sessionCount == 0) {
      return super.createSession(
        cwd: cwd,
        additionalDirectories: additionalDirectories,
      );
    }
    emitPermissionRequest(
      _permissionRequest(
        id: 'late-previous-permission',
        sessionId: 'fake-session-1',
      ),
    );
    await Future<void>.delayed(Duration.zero);
    throw StateError('create failed');
  }
}

final class _ReusedSetupPermissionAgentClient extends FakeAgentClient {
  int _createCount = 0;

  @override
  Future<AgentSession> createSession({
    required String cwd,
    List<String> additionalDirectories = const <String>[],
  }) async {
    _createCount += 1;
    if (_createCount > 1) {
      emitPermissionRequest(
        _permissionRequest(
          id: 'reused-permission-$_createCount',
          sessionId: 'reused-session',
        ),
      );
      await Future<void>.delayed(Duration.zero);
    }
    return AgentSession(
      id: 'reused-session',
      cwd: cwd,
      createdAt: DateTime(2026, 8, 20),
      additionalDirectories: additionalDirectories,
    );
  }
}

final class _ThirdSetupPermissionAgentClient extends FakeAgentClient {
  @override
  Future<AgentSession> createSession({
    required String cwd,
    List<String> additionalDirectories = const <String>[],
  }) async {
    if (sessionCount == 2) {
      emitPermissionRequest(
        _permissionRequest(
          id: 'third-setup-permission',
          sessionId: 'fake-session-3',
        ),
      );
      await Future<void>.delayed(Duration.zero);
    }
    return super.createSession(
      cwd: cwd,
      additionalDirectories: additionalDirectories,
    );
  }
}

final class _RetiredOverflowAgentClient extends _TrackingAgentClient {
  final Completer<void> _lastCreateStarted = Completer<void>();
  final Completer<void> _lastCreateGate = Completer<void>();

  Future<void> get lastCreateStarted => _lastCreateStarted.future;

  @override
  Future<AgentSession> createSession({
    required String cwd,
    List<String> additionalDirectories = const <String>[],
  }) async {
    if (sessionCount >= 513) {
      if (!_lastCreateStarted.isCompleted) _lastCreateStarted.complete();
      await _lastCreateGate.future;
    }
    return super.createSession(
      cwd: cwd,
      additionalDirectories: additionalDirectories,
    );
  }

  void releaseLastCreate() {
    if (!_lastCreateGate.isCompleted) _lastCreateGate.complete();
  }
}

final class _SiblingConnectAgentClient extends _TrackingAgentClient {
  final Completer<void> _secondCreateStarted = Completer<void>();
  final Completer<void> _secondCreateGate = Completer<void>();

  Future<void> get secondCreateStarted => _secondCreateStarted.future;

  @override
  Future<AgentSession> createSession({
    required String cwd,
    List<String> additionalDirectories = const <String>[],
  }) async {
    if (sessionCount >= 1) {
      if (!_secondCreateStarted.isCompleted) _secondCreateStarted.complete();
      await _secondCreateGate.future;
    }
    return super.createSession(
      cwd: cwd,
      additionalDirectories: additionalDirectories,
    );
  }

  void releaseSecondCreate() {
    if (!_secondCreateGate.isCompleted) _secondCreateGate.complete();
  }
}

final class _SerializedCreateAgentClient extends _TrackingAgentClient {
  final Completer<void> _firstCreateStarted = Completer<void>();
  final Completer<void> _firstCreateGate = Completer<void>();
  final Completer<void> _secondCreateStarted = Completer<void>();
  final Completer<void> _secondCreateGate = Completer<void>();
  int createCalls = 0;

  Future<void> get firstCreateStarted => _firstCreateStarted.future;
  Future<void> get secondCreateStarted => _secondCreateStarted.future;

  @override
  Future<AgentSession> createSession({
    required String cwd,
    List<String> additionalDirectories = const <String>[],
  }) async {
    createCalls += 1;
    if (createCalls == 1) {
      if (!_firstCreateStarted.isCompleted) _firstCreateStarted.complete();
      await _firstCreateGate.future;
    } else {
      if (!_secondCreateStarted.isCompleted) _secondCreateStarted.complete();
      await _secondCreateGate.future;
    }
    return super.createSession(
      cwd: cwd,
      additionalDirectories: additionalDirectories,
    );
  }

  void releaseFirstCreate() {
    if (!_firstCreateGate.isCompleted) _firstCreateGate.complete();
  }

  void releaseSecondCreate() {
    if (!_secondCreateGate.isCompleted) _secondCreateGate.complete();
  }
}

final class _ControlledPermissionResponseAgentClient
    extends _TrackingAgentClient {
  final Completer<void> _responseStarted = Completer<void>();
  final Completer<void> _responseGate = Completer<void>();
  int responseCalls = 0;
  final List<String> responseIds = <String>[];
  final List<AcpPermissionDecision> responseDecisions =
      <AcpPermissionDecision>[];

  Future<void> get responseStarted => _responseStarted.future;

  @override
  Future<void> respondToPermissionRequest({
    required String id,
    required AcpPermissionDecision decision,
    String? selectedOptionId,
  }) async {
    responseCalls += 1;
    responseIds.add(id);
    responseDecisions.add(decision);
    if (!_responseStarted.isCompleted) _responseStarted.complete();
    await _responseGate.future;
    await super.respondToPermissionRequest(
      id: id,
      decision: decision,
      selectedOptionId: selectedOptionId,
    );
  }

  void releaseResponse() {
    if (!_responseGate.isCompleted) _responseGate.complete();
  }
}

final class _NthControlledCreateAgentClient extends _TrackingAgentClient {
  _NthControlledCreateAgentClient({required this.blockAtCall});

  final int blockAtCall;
  final Completer<void> _blockedCreateStarted = Completer<void>();
  final Completer<void> _blockedCreateGate = Completer<void>();
  int createCalls = 0;

  Future<void> get blockedCreateStarted => _blockedCreateStarted.future;

  @override
  Future<AgentSession> createSession({
    required String cwd,
    List<String> additionalDirectories = const <String>[],
  }) async {
    createCalls += 1;
    if (createCalls == blockAtCall) {
      if (!_blockedCreateStarted.isCompleted) {
        _blockedCreateStarted.complete();
      }
      await _blockedCreateGate.future;
    }
    return super.createSession(
      cwd: cwd,
      additionalDirectories: additionalDirectories,
    );
  }

  void releaseBlockedCreate() {
    if (!_blockedCreateGate.isCompleted) _blockedCreateGate.complete();
  }
}

final class _FreshSetupAfterRetirementAgentClient extends _TrackingAgentClient {
  @override
  Future<AgentSession> createSession({
    required String cwd,
    List<String> additionalDirectories = const <String>[],
  }) async {
    if (sessionCount == 513) {
      emitPermissionRequest(
        _permissionRequest(
          id: 'fresh-after-retirement-history',
          sessionId: 'fake-session-514',
        ),
      );
      await Future<void>.delayed(Duration.zero);
    }
    return super.createSession(
      cwd: cwd,
      additionalDirectories: additionalDirectories,
    );
  }
}

final class _FailingControlledPermissionResponseAgentClient
    extends _TrackingAgentClient {
  final Completer<void> _responseStarted = Completer<void>();
  final Completer<void> _responseGate = Completer<void>();
  var _failNextResponse = true;

  Future<void> get responseStarted => _responseStarted.future;

  @override
  Future<void> respondToPermissionRequest({
    required String id,
    required AcpPermissionDecision decision,
    String? selectedOptionId,
  }) async {
    if (_failNextResponse) {
      _failNextResponse = false;
      if (!_responseStarted.isCompleted) _responseStarted.complete();
      await _responseGate.future;
      throw StateError('permission response failed');
    }
    await super.respondToPermissionRequest(
      id: id,
      decision: decision,
      selectedOptionId: selectedOptionId,
    );
  }

  void releaseResponse() {
    if (!_responseGate.isCompleted) _responseGate.complete();
  }
}

final class _RestorePermissionAgentClient extends _TrackingAgentClient {
  bool emitOnRestore = false;

  @override
  Future<AcpSessionRestoreSummary> restoreSession({
    required String sessionId,
    required String cwd,
    List<String> additionalDirectories = const <String>[],
    bool replayHistory = true,
    required AcpSessionRestoreEventObserver onEvent,
  }) async {
    if (emitOnRestore) {
      emitPermissionRequest(
        _permissionRequest(
          id: 'restore-setup-permission',
          sessionId: sessionId,
        ),
      );
      await Future<void>.delayed(Duration.zero);
    }
    return super.restoreSession(
      sessionId: sessionId,
      cwd: cwd,
      additionalDirectories: additionalDirectories,
      replayHistory: replayHistory,
      onEvent: onEvent,
    );
  }
}

final class _FailingRestoreAgentClient extends _TrackingAgentClient {
  bool failRestore = false;

  @override
  Future<AcpSessionRestoreSummary> restoreSession({
    required String sessionId,
    required String cwd,
    List<String> additionalDirectories = const <String>[],
    bool replayHistory = true,
    required AcpSessionRestoreEventObserver onEvent,
  }) async {
    if (failRestore) throw StateError('restore failed');
    return super.restoreSession(
      sessionId: sessionId,
      cwd: cwd,
      additionalDirectories: additionalDirectories,
      replayHistory: replayHistory,
      onEvent: onEvent,
    );
  }
}

final class _CollidingCreateAgentClient extends _TrackingAgentClient {
  @override
  Future<AgentSession> createSession({
    required String cwd,
    List<String> additionalDirectories = const <String>[],
  }) async {
    return AgentSession(
      id: 'colliding-session',
      cwd: cwd,
      createdAt: DateTime(2026, 8, 20),
      additionalDirectories: additionalDirectories,
    );
  }
}

final class _CollidingForkAgentClient extends _TrackingAgentClient {
  @override
  Future<AgentSession> createSession({
    required String cwd,
    List<String> additionalDirectories = const <String>[],
  }) async {
    return AgentSession(
      id: 'colliding-session',
      cwd: cwd,
      createdAt: DateTime(2026, 8, 20),
      additionalDirectories: additionalDirectories,
    );
  }

  @override
  Future<AgentSession> forkSession({
    required String sessionId,
    required String cwd,
    List<String> additionalDirectories = const <String>[],
  }) async {
    return AgentSession(
      id: 'colliding-session',
      cwd: cwd,
      createdAt: DateTime(2026, 8, 20),
      additionalDirectories: additionalDirectories,
    );
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

final class _RestoreCollisionAgentClient extends _TrackingAgentClient {
  final Completer<void> _restoreStarted = Completer<void>();
  final Completer<void> _restoreGate = Completer<void>();

  Future<void> get restoreStarted => _restoreStarted.future;

  @override
  Future<AgentSession> createSession({
    required String cwd,
    List<String> additionalDirectories = const <String>[],
  }) async {
    return AgentSession(
      id: 'reserved-target',
      cwd: cwd,
      createdAt: DateTime(2026, 8, 20),
      additionalDirectories: additionalDirectories,
    );
  }

  @override
  Future<AcpSessionRestoreSummary> restoreSession({
    required String sessionId,
    required String cwd,
    List<String> additionalDirectories = const <String>[],
    bool replayHistory = true,
    required AcpSessionRestoreEventObserver onEvent,
  }) async {
    if (!_restoreStarted.isCompleted) _restoreStarted.complete();
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

final class _ControlledLogoutAgentClient extends FakeAgentClient {
  final Completer<void> _logoutStarted = Completer<void>();
  final Completer<void> _logoutGate = Completer<void>();
  int logoutCount = 0;
  int disposeCount = 0;

  Future<void> get logoutStarted => _logoutStarted.future;

  @override
  Future<void> logout() async {
    logoutCount += 1;
    if (!_logoutStarted.isCompleted) _logoutStarted.complete();
    await _logoutGate.future;
  }

  void releaseLogout() {
    if (!_logoutGate.isCompleted) _logoutGate.complete();
  }

  @override
  Future<void> dispose() async {
    disposeCount += 1;
    await super.dispose();
  }
}

final class _ControlledCreateAgentClient extends _TrackingAgentClient {
  final Completer<void> _createStarted = Completer<void>();
  final Completer<void> _createGate = Completer<void>();

  Future<void> get createStarted => _createStarted.future;

  @override
  Future<AgentSession> createSession({
    required String cwd,
    List<String> additionalDirectories = const <String>[],
  }) async {
    if (!_createStarted.isCompleted) _createStarted.complete();
    await _createGate.future;
    return super.createSession(
      cwd: cwd,
      additionalDirectories: additionalDirectories,
    );
  }

  void releaseCreate() {
    if (!_createGate.isCompleted) _createGate.complete();
  }
}

final class _ControlledReconnectAgentClient extends _TrackingAgentClient {
  final Completer<void> _reconnectStarted = Completer<void>();
  final Completer<void> _reconnectGate = Completer<void>();
  int connectCalls = 0;

  Future<void> get reconnectStarted => _reconnectStarted.future;

  @override
  Future<void> connect() async {
    connectCalls += 1;
    if (connectCalls > 1) {
      if (!_reconnectStarted.isCompleted) _reconnectStarted.complete();
      await _reconnectGate.future;
    }
    await super.connect();
  }

  void releaseReconnect() {
    if (!_reconnectGate.isCompleted) _reconnectGate.complete();
  }
}

final class _ControlledCloseAgentClient extends _TrackingAgentClient {
  final Completer<void> _closeStarted = Completer<void>();
  final Completer<void> _closeGate = Completer<void>();

  Future<void> get closeStarted => _closeStarted.future;

  @override
  Future<void> closeSession({required String sessionId}) async {
    if (!_closeStarted.isCompleted) _closeStarted.complete();
    await _closeGate.future;
    await super.closeSession(sessionId: sessionId);
  }

  void releaseClose() {
    if (!_closeGate.isCompleted) _closeGate.complete();
  }
}

final class _ControlledDeleteAgentClient extends _TrackingAgentClient {
  _ControlledDeleteAgentClient() : super(supportsDelete: true);

  final Completer<void> _deleteStarted = Completer<void>();
  final Completer<void> _deleteGate = Completer<void>();

  Future<void> get deleteStarted => _deleteStarted.future;

  @override
  Future<void> deleteSession({required String sessionId}) async {
    if (!_deleteStarted.isCompleted) _deleteStarted.complete();
    await _deleteGate.future;
    await super.deleteSession(sessionId: sessionId);
  }

  void releaseDelete() {
    if (!_deleteGate.isCompleted) _deleteGate.complete();
  }
}

final class _ControlledAvailableCommandsAgentClient
    extends _TrackingAgentClient {
  final Completer<void> _commandsStarted = Completer<void>();
  final Completer<void> _commandsGate = Completer<void>();

  Future<void> get commandsStarted => _commandsStarted.future;

  @override
  Future<AcpAvailableCommandsUpdate?> sessionAvailableCommands(
    String sessionId,
  ) async {
    if (!_commandsStarted.isCompleted) _commandsStarted.complete();
    await _commandsGate.future;
    return AcpAvailableCommandsUpdate(
      sessionId: sessionId,
      commands: const <Map<String, Object?>>[
        <String, Object?>{'name': 'test-command'},
      ],
    );
  }

  void releaseCommands() {
    if (!_commandsGate.isCompleted) _commandsGate.complete();
  }
}

final class _HangingPromptAgentClient extends _TrackingAgentClient {
  final StreamController<AgentEvent> _events = StreamController<AgentEvent>();

  @override
  Stream<AgentEvent> sendPrompt({
    required String sessionId,
    required String prompt,
    List<PromptAttachment> attachments = const <PromptAttachment>[],
  }) {
    return _events.stream;
  }

  @override
  Future<void> cancelSession({required String sessionId}) async {
    await super.cancelSession(sessionId: sessionId);
    if (!_events.isClosed) await _events.close();
  }

  @override
  Future<void> dispose() async {
    if (!_events.isClosed) await _events.close();
    await super.dispose();
  }
}

final class _ControlledTranscriptCache implements SessionTranscriptCache {
  final Completer<void> _loadStarted = Completer<void>();
  final Completer<SessionTranscriptSnapshot?> _loadGate =
      Completer<SessionTranscriptSnapshot?>();

  Future<void> get loadStarted => _loadStarted.future;

  @override
  Future<SessionTranscriptSnapshot?> load(SessionTranscriptIdentity identity) {
    if (!_loadStarted.isCompleted) _loadStarted.complete();
    return _loadGate.future;
  }

  void complete() {
    if (!_loadGate.isCompleted) _loadGate.complete();
  }

  @override
  Future<void> save(SessionTranscriptSnapshot snapshot) async {}
}
