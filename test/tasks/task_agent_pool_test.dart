import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/acp_permission_request.dart';
import 'package:ianvs_acp/acp/acp_permission_reviewer.dart';
import 'package:ianvs_acp/acp/agent_session.dart';
import 'package:ianvs_acp/acp/fake_agent_client.dart';
import 'package:ianvs_acp/state/chat_controller.dart';
import 'package:ianvs_acp/state/connection_state.dart';
import 'package:ianvs_acp/tasks/runtime_registry.dart';
import 'package:ianvs_acp/tasks/task_agent_pool.dart';

void main() {
  test('TaskAgentPool leases each agent atomically and independently', () async {
    final controllers = <String, ChatController>{};
    final pool = LocalTaskAgentPool(
      controllerFactory: (agentName) => controllers.putIfAbsent(
        agentName,
        () => ChatController(
          client: FakeAgentClient(),
          cwd: '/workspace',
          agentName: agentName,
        ),
      ),
      clock: () => DateTime(2026, 7, 10, 12),
    );
    addTearDown(pool.dispose);

    final firstCodex = await pool.tryAcquire('Codex');
    final secondCodex = await pool.tryAcquire('Codex');
    final kimi = await pool.tryAcquire('Kimi');

    expect(firstCodex, isNotNull);
    expect(secondCodex, isNull);
    expect(kimi, isNotNull);
    expect(
      (await pool.probeAgent('Codex')).availability,
      RuntimeAvailability.busy,
    );
    expect(
      (await pool.probeAgent('Kimi')).availability,
      RuntimeAvailability.busy,
    );

    await firstCodex!.release();
    await firstCodex.release();
    final nextCodex = await pool.tryAcquire('Codex');
    expect(nextCodex, isNotNull);
    expect(identical(nextCodex!.controller, firstCodex.controller), isTrue);
    await firstCodex.release();
    expect(await pool.tryAcquire('Codex'), isNull);

    await nextCodex.release();
    await kimi!.release();
    expect(
      (await pool.probeAgent('Codex')).availability,
      RuntimeAvailability.available,
    );
  });

  test('TaskAgentPool disposal is awaitable and rejects new leases', () async {
    final clients = <_TrackingAgentClient>[];
    final reviewer = _TrackingPermissionReviewer();
    final pool = LocalTaskAgentPool(
      controllerFactory: (agentName) {
        final client = _TrackingAgentClient();
        clients.add(client);
        return ChatController(
          client: client,
          cwd: '/workspace',
          agentName: agentName,
          permissionReviewer: reviewer,
        );
      },
    );
    final lease = await pool.tryAcquire('Codex');

    await Future.wait([pool.dispose(), pool.dispose()]);

    expect(clients.single.disposed, isTrue);
    expect(reviewer.disposeCalls, 1);
    await lease!.release();
    await expectLater(pool.tryAcquire('Codex'), throwsStateError);
  });

  test('TaskAgentPool reports missing agent configuration', () async {
    final pool = LocalTaskAgentPool(controllerFactory: (_) => null);
    addTearDown(pool.dispose);

    expect(
      (await pool.probeAgent('Missing')).availability,
      RuntimeAvailability.unavailable,
    );
    await expectLater(
      pool.tryAcquire('Missing'),
      throwsA(isA<TaskAgentUnavailableException>()),
    );
  });

  test('TaskAgentPool waits for an explicit reset after authentication', () async {
    var authenticationRequired = true;
    final clients = <_RecoveringAuthAgentClient>[];
    final pool = LocalTaskAgentPool(
      controllerFactory: (agentName) {
        final client = _RecoveringAuthAgentClient()
          ..authenticationRequired = authenticationRequired;
        clients.add(client);
        return ChatController(
          client: client,
          cwd: '/workspace',
          agentName: agentName,
        );
      },
    );
    addTearDown(pool.dispose);

    final blocked = await pool.probeAgent('Codex');
    authenticationRequired = false;
    final stillBlocked = await pool.probeAgent('Codex');
    await pool.resetAgent('Codex');
    final recovered = await pool.probeAgent('Codex');

    expect(blocked.availability, RuntimeAvailability.authRequired);
    expect(stillBlocked.availability, RuntimeAvailability.authRequired);
    expect(recovered.availability, RuntimeAvailability.available);
    expect(clients, hasLength(2));
    expect(
      clients.fold<int>(0, (total, client) => total + client.connectCalls),
      2,
    );
  });

  test('TaskAgentPool authenticates the existing background process', () async {
    final client = _ProcessScopedAuthAgentClient();
    final pool = LocalTaskAgentPool(
      controllerFactory: (agentName) => ChatController(
        client: client,
        cwd: '/workspace',
        agentName: agentName,
      ),
    );
    addTearDown(pool.dispose);
    final lease = await pool.tryAcquire('Codex');

    expect(await lease!.controller.newSession(), isFalse);
    await lease.release();
    expect(
      (await pool.probeAgent('Codex')).availability,
      RuntimeAvailability.authRequired,
    );

    final authenticated = await pool.authenticateAgent('Codex', 'browser');

    expect(authenticated, isTrue);
    expect(client.lastAuthenticatedMethodId, 'browser');
    expect(
      (await pool.probeAgent('Codex')).availability,
      RuntimeAvailability.available,
    );
  });

  test('TaskAgentPool does not treat advertised auth as an auth error', () async {
    late final _RetainingAuthErrorController controller;
    final pool = LocalTaskAgentPool(
      controllerFactory: (agentName) => controller =
          _RetainingAuthErrorController(agentName),
    );
    addTearDown(pool.dispose);

    expect(
      (await pool.probeAgent('Codex')).availability,
      RuntimeAvailability.available,
    );
    controller.failReconnect = true;
    controller.status = ConnectionStatus.error;
    controller.lastError = 'workspace path is invalid';

    expect(
      (await pool.probeAgent('Codex')).availability,
      RuntimeAvailability.unavailable,
    );
  });

  test('TaskAgentPool can retry after controller factory failure', () async {
    var attempts = 0;
    final pool = LocalTaskAgentPool(
      controllerFactory: (agentName) {
        attempts += 1;
        if (attempts == 1) throw StateError('temporary factory failure');
        return ChatController(
          client: FakeAgentClient(),
          cwd: '/workspace',
          agentName: agentName,
        );
      },
    );
    addTearDown(pool.dispose);

    await expectLater(pool.tryAcquire('Codex'), throwsStateError);
    final lease = await pool.tryAcquire('Codex');

    expect(lease, isNotNull);
    expect(attempts, 2);
    await lease!.release();
  });

  test('TaskAgentPool probe cannot revive an entry during disposal', () async {
    final client = _BlockingConnectAgentClient();
    final pool = LocalTaskAgentPool(
      controllerFactory: (agentName) => ChatController(
        client: client,
        cwd: '/workspace',
        agentName: agentName,
      ),
    );

    final probing = pool.probeAgent('Codex');
    await client.connectStarted.future;
    final disposing = pool.dispose();
    final status = await probing;
    await disposing;

    expect(status.availability, RuntimeAvailability.unavailable);
    expect(client.disposed, isTrue);
    expect(client.connected, isFalse);
    await expectLater(pool.tryAcquire('Codex'), throwsStateError);
  });

  test('TaskAgentPool bounds a connection probe that never settles', () async {
    final client = _NeverConnectingAgentClient();
    final pool = LocalTaskAgentPool(
      controllerFactory: (agentName) => ChatController(
        client: client,
        cwd: '/workspace',
        agentName: agentName,
      ),
      connectTimeout: const Duration(milliseconds: 20),
    );
    addTearDown(pool.dispose);

    final status = await pool
        .probeAgent('Codex')
        .timeout(const Duration(seconds: 1));

    expect(status.availability, RuntimeAvailability.unavailable);
    expect(status.unavailableReason, contains('timed out'));
    expect(client.disposed, isTrue);
  });
}

class _TrackingAgentClient extends FakeAgentClient {
  bool disposed = false;

  @override
  Future<void> dispose() async {
    disposed = true;
    await super.dispose();
  }
}

class _TrackingPermissionReviewer extends AcpPermissionReviewer {
  int disposeCalls = 0;

  @override
  Future<AcpPermissionReviewResult?> review(
    AcpPermissionRequest request, {
    required String workspaceRoot,
    List<String> additionalDirectories = const <String>[],
    String? model,
  }) async {
    return null;
  }

  @override
  Future<void> dispose() async {
    disposeCalls += 1;
  }
}

class _RecoveringAuthAgentClient extends FakeAgentClient {
  bool authenticationRequired = true;
  int connectCalls = 0;

  @override
  Future<void> connect() async {
    connectCalls += 1;
    if (authenticationRequired) {
      throw StateError('authentication required');
    }
    await super.connect();
  }
}

class _BlockingConnectAgentClient extends FakeAgentClient {
  final Completer<void> connectStarted = Completer<void>();
  final Completer<void> _connectRelease = Completer<void>();
  bool disposed = false;

  @override
  Future<void> connect() async {
    if (!connectStarted.isCompleted) connectStarted.complete();
    await _connectRelease.future;
    await super.connect();
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    if (!_connectRelease.isCompleted) _connectRelease.complete();
    await super.dispose();
  }
}

class _NeverConnectingAgentClient extends FakeAgentClient {
  final Completer<void> _never = Completer<void>();
  bool disposed = false;

  @override
  Future<void> connect() => _never.future;

  @override
  Future<void> dispose() async {
    disposed = true;
    await super.dispose();
  }
}

class _ProcessScopedAuthAgentClient extends FakeAgentClient {
  _ProcessScopedAuthAgentClient()
    : super(
        authMethods: const [
          <String, Object?>{'id': 'browser', 'name': 'Browser sign-in'},
        ],
      );

  bool authenticated = false;

  @override
  Future<AgentSession> createSession({
    required String cwd,
    List<String> additionalDirectories = const <String>[],
  }) {
    if (!authenticated) throw StateError('auth_required');
    return super.createSession(
      cwd: cwd,
      additionalDirectories: additionalDirectories,
    );
  }

  @override
  Future<void> authenticate({required String methodId}) async {
    await super.authenticate(methodId: methodId);
    authenticated = true;
  }
}

class _RetainingAuthErrorController extends ChatController {
  _RetainingAuthErrorController(String agentName)
    : super(
        client: FakeAgentClient(
          authMethods: const [
            <String, Object?>{'id': 'browser', 'name': 'Browser sign-in'},
          ],
        ),
        cwd: '/workspace',
        agentName: agentName,
      );

  bool failReconnect = false;

  @override
  Future<void> connect() async {
    if (!failReconnect) return super.connect();
    status = ConnectionStatus.error;
    lastError = 'workspace path is invalid';
  }
}
