import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/acp_permission_request.dart';
import 'package:ianvs_acp/acp/acp_permission_reviewer.dart';
import 'package:ianvs_acp/acp/acp_session_settings.dart';
import 'package:ianvs_acp/acp/agent_event.dart';
import 'package:ianvs_acp/acp/agent_session.dart';
import 'package:ianvs_acp/acp/fake_agent_client.dart';
import 'package:ianvs_acp/acp/prompt_attachment.dart';
import 'package:ianvs_acp/state/chat_controller.dart';
import 'package:ianvs_acp/state/connection_state.dart' as app_state;

void main() {
  test('connect success sets connected status', () async {
    final controller = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    await controller.connect();

    expect(controller.status, app_state.ConnectionStatus.connected);
    expect(controller.lastError, isNull);
  });

  test('connect failure sets error status', () async {
    final controller = ChatController(
      client: FakeAgentClient(connectError: Exception('codex missing')),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    await controller.connect();

    expect(controller.status, app_state.ConnectionStatus.error);
    expect(controller.lastError, contains('codex missing'));
  });

  test('reconnect failure clears stale capabilities', () async {
    final fake = _FailingReconnectAgentClient();
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    await controller.connect();

    expect(controller.capabilities, isNotNull);
    expect(controller.canLogout, isTrue);
    expect(controller.canSendExtensionRequest, isTrue);

    await controller.reconnect();

    expect(controller.status, app_state.ConnectionStatus.error);
    expect(controller.capabilities, isNull);
    expect(controller.canLogout, isFalse);
    expect(controller.canSendExtensionRequest, isFalse);
    expect(controller.lastError, contains('connection dropped'));
  });

  test('reconnect accepts reused session setup permissions', () async {
    final fake = _ReusedSessionSetupPermissionAgentClient();
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    await controller.newSession();
    expect(controller.currentSession?.id, 'reused-session');

    await controller.closeCurrentSession();
    expect(controller.currentSession, isNull);

    await controller.reconnect();
    await controller.newSession();
    await pumpEventQueue();

    expect(controller.currentSession?.id, 'reused-session');
    expect(controller.pendingPermissionRequest?.id, 'permission-reused-2');
    expect(fake.lastPermissionRequestId, isNull);
  });

  test('create session success sets current session', () async {
    final controller = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    await controller.newSession();

    expect(controller.status, app_state.ConnectionStatus.sessionReady);
    expect(controller.currentSession?.id, 'fake-session-1');
    expect(controller.currentSession?.agentName, 'Codex');
    expect(controller.sessions, hasLength(1));
    expect(controller.sessionSettings.configOptions.single.id, 'approval');
    expect(controller.sessionSettings.modes.currentModeId, isNull);
  });

  test('new session preserves initial error events', () async {
    final controller = ChatController(
      client: FakeAgentClient(
        createSessionEvents: const [
          AgentEvent(type: AgentEventType.error, text: 'session setup failed'),
        ],
      ),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    await controller.newSession();

    expect(controller.currentSession?.id, 'fake-session-1');
    expect(controller.status, app_state.ConnectionStatus.error);
    expect(controller.lastError, contains('session setup failed'));
    expect(controller.messages.map((message) => message.role), [
      ChatMessageRole.error,
    ]);
  });

  test(
    'send prompt stops when automatic session setup emits an error',
    () async {
      final fake = FakeAgentClient(
        createSessionEvents: const [
          AgentEvent(type: AgentEventType.error, text: 'session setup failed'),
        ],
      );
      final controller = ChatController(client: fake, cwd: '/workspace');
      addTearDown(controller.dispose);

      await controller.sendPrompt('Hi');

      expect(fake.lastPrompt, isNull);
      expect(controller.currentSession?.id, 'fake-session-1');
      expect(controller.status, app_state.ConnectionStatus.error);
      expect(controller.lastError, contains('session setup failed'));
      expect(controller.messages.map((message) => message.role), [
        ChatMessageRole.error,
      ]);
    },
  );

  test('created sessions keep selected agent name', () async {
    final controller = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace',
      agentName: 'Kimi Code Dev',
    );
    addTearDown(controller.dispose);

    await controller.newSession();

    expect(controller.currentSession?.agentName, 'Kimi Code Dev');
    expect(controller.sessions.single.agentName, 'Kimi Code Dev');
  });

  test('new sessions append to sidebar history', () async {
    final controller = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    await controller.newSession();
    await controller.newSession();

    expect(controller.currentSession?.id, 'fake-session-2');
    expect(controller.sessions.map((session) => session.id), [
      'fake-session-2',
      'fake-session-1',
    ]);
  });

  test(
    'concurrent new session requests are ignored while one is running',
    () async {
      final fake = FakeAgentClient(
        createSessionDelay: const Duration(milliseconds: 20),
      );
      final controller = ChatController(client: fake, cwd: '/workspace');
      addTearDown(controller.dispose);

      final first = controller.newSession();
      final second = controller.newSession();
      await Future.wait([first, second]);

      expect(fake.sessionCount, 1);
      expect(controller.sessions, hasLength(1));
      expect(controller.isSessionOperationRunning, isFalse);
    },
  );

  test('dispose during pending connect ignores late notifications', () async {
    final controller = ChatController(
      client: FakeAgentClient(connectDelay: const Duration(milliseconds: 20)),
      cwd: '/workspace',
    );

    final pendingConnect = controller.connect();
    await pumpEventQueue();
    expect(controller.isSessionOperationRunning, isTrue);

    controller.dispose();
    await pendingConnect;
  });

  test('dispose ignores asynchronous cleanup errors', () async {
    final errors = <Object>[];

    final zoneDone = runZonedGuarded<Future<void>>(
      () async {
        final controller = ChatController(
          client: _FailingDisposeAgentClient(),
          cwd: '/workspace',
        );

        await controller.connect();
        controller.dispose();
        await pumpEventQueue(times: 4);
      },
      (error, stackTrace) {
        errors.add(error);
      },
    );
    if (zoneDone != null) {
      await zoneDone;
    }

    expect(errors, isEmpty);
  });

  test('list sessions keeps session operation lock while loading', () async {
    final fake = FakeAgentClient(
      listSessionsDelay: const Duration(milliseconds: 20),
    );
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    await controller.connect();
    final loading = controller.listSessions();
    await pumpEventQueue();

    expect(controller.isSessionOperationRunning, isTrue);

    final projects = await loading;

    expect(projects.single.cwd, '/workspace/project-a');
    expect(controller.isSessionOperationRunning, isFalse);
  });

  test('resume session replays history into timeline', () async {
    final controller = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    await controller.resumeSession('resumed-session-1');

    expect(controller.status, app_state.ConnectionStatus.sessionReady);
    expect(controller.currentSession?.id, 'resumed-session-1');
    expect(controller.currentSession?.agentName, 'Codex');
    expect(controller.sessions, hasLength(1));
    expect(controller.messages.map((message) => message.role), [
      ChatMessageRole.user,
      ChatMessageRole.assistant,
      ChatMessageRole.tool,
      ChatMessageRole.status,
    ]);
    expect(controller.messages[1].text, contains('medium-sized transcript'));
  });

  test('resume session preserves consecutive user messages', () async {
    final controller = ChatController(
      client: FakeAgentClient(
        resumeEvents: const [
          AgentEvent(type: AgentEventType.userMessage, text: 'First request'),
          AgentEvent(type: AgentEventType.userMessage, text: 'Second request'),
        ],
      ),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    await controller.resumeSession('resumed-session-users');

    expect(controller.messages, hasLength(2));
    expect(controller.messages.map((message) => message.role), [
      ChatMessageRole.user,
      ChatMessageRole.user,
    ]);
    expect(controller.messages.map((message) => message.text), [
      'First request',
      'Second request',
    ]);
  });

  test('resume session uses selected project cwd', () async {
    final fake = FakeAgentClient();
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    await controller.resumeSession('resumed-session-2', cwd: '/other/project');

    expect(controller.currentSession?.cwd, '/other/project');
    expect(fake.lastResumeCwd, '/other/project');
    expect(controller.sessionSettings.configOptions.single.id, 'approval');
  });

  test('failed resume restores previous active session state', () async {
    final fake = _FailingResumeAgentClient(
      createSessionEvents: const [
        AgentEvent(
          type: AgentEventType.status,
          text: 'review',
          metadata: {
            'kind': 'commands',
            'commands': [
              {'name': 'review', 'description': 'Review current changes.'},
            ],
          },
        ),
      ],
    );
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    await controller.newSession();

    final previousMessages = controller.messages
        .map((message) => message.text)
        .toList();

    await controller.resumeSession('failed-session', cwd: '/other/project');

    expect(fake.lastResumeCwd, '/other/project');
    expect(controller.status, app_state.ConnectionStatus.error);
    expect(controller.lastError, contains('resume failed'));
    expect(controller.currentSession?.id, 'fake-session-1');
    expect(controller.sessions.map((session) => session.id), [
      'fake-session-1',
    ]);
    expect(
      controller.messages.map((message) => message.text),
      previousMessages,
    );
    expect(controller.availableCommands.single['name'], 'review');
    expect(controller.sessionSettings.configOptions.single.id, 'approval');
  });

  test('resume session keeps ACP session title metadata', () async {
    final controller = ChatController(
      client: FakeAgentClient(
        resumeEvents: const [
          AgentEvent(
            type: AgentEventType.status,
            text: 'Updated session title',
            metadata: {
              'kind': 'session_info_update',
              'sessionId': 'resumed-session-title',
              'title': 'Updated session title',
              'updatedAt': '2026-05-30T04:12:00Z',
            },
          ),
        ],
      ),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    await controller.resumeSession(
      'resumed-session-title',
      title: 'Original session title',
    );

    expect(controller.messages, isEmpty);
    expect(controller.currentSession?.displayTitle, 'Updated session title');
    expect(controller.sessions.single.displayTitle, 'Updated session title');
  });

  test('resume session ignores blank ACP session title updates', () async {
    final controller = ChatController(
      client: FakeAgentClient(
        resumeEvents: const [
          AgentEvent(
            type: AgentEventType.status,
            text: 'Session info updated.',
            metadata: {
              'kind': 'session_info_update',
              'sessionId': 'resumed-session-title',
              'title': '   ',
              'updatedAt': '2026-05-30T04:12:00Z',
            },
          ),
        ],
      ),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    await controller.resumeSession(
      'resumed-session-title',
      title: 'Original session title',
    );

    expect(controller.messages, isEmpty);
    expect(controller.currentSession?.displayTitle, 'Original session title');
    expect(controller.sessions.single.displayTitle, 'Original session title');
    expect(controller.currentSession?.updatedAt, isNotNull);
  });

  test('plan status updates replace previous plan snapshot', () async {
    final controller = ChatController(
      client: FakeAgentClient(
        resumeEvents: const [
          AgentEvent(
            type: AgentEventType.status,
            text: 'Initial plan',
            metadata: {
              'kind': 'plan',
              'title': 'Initial plan',
              'entries': [
                {'content': 'Inspect', 'priority': 'high', 'status': 'pending'},
              ],
            },
          ),
          AgentEvent(
            type: AgentEventType.status,
            text: 'Updated plan',
            metadata: {
              'kind': 'plan',
              'title': 'Updated plan',
              'entries': [
                {
                  'content': 'Inspect',
                  'priority': 'high',
                  'status': 'completed',
                },
              ],
            },
          ),
        ],
      ),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    await controller.resumeSession('resumed-session-plan');

    expect(controller.messages, hasLength(1));
    expect(controller.messages.single.text, 'Updated plan');
  });

  test(
    'available command updates are retained for prompt suggestions',
    () async {
      final controller = ChatController(
        client: FakeAgentClient(
          resumeEvents: const [
            AgentEvent(
              type: AgentEventType.status,
              text: 'review',
              metadata: {
                'kind': 'commands',
                'commands': [
                  {
                    'name': 'review',
                    'description': 'Review the current change.',
                  },
                ],
              },
            ),
          ],
        ),
        cwd: '/workspace',
      );
      addTearDown(controller.dispose);

      await controller.resumeSession('resumed-session-commands');

      expect(controller.availableCommands, hasLength(1));
      expect(controller.availableCommands.single['name'], 'review');
      expect(controller.messages.single.metadata['kind'], 'commands');
    },
  );

  test(
    'new session applies initial command updates to prompt suggestions',
    () async {
      final controller = ChatController(
        client: FakeAgentClient(
          createSessionEvents: const [
            AgentEvent(
              type: AgentEventType.status,
              text: 'review',
              metadata: {
                'kind': 'commands',
                'commands': [
                  {
                    'name': 'review',
                    'description': 'Review the current change.',
                  },
                ],
              },
            ),
          ],
        ),
        cwd: '/workspace',
      );
      addTearDown(controller.dispose);

      await controller.newSession();

      expect(controller.availableCommands, hasLength(1));
      expect(controller.availableCommands.single['name'], 'review');
      expect(controller.messages.single.metadata['kind'], 'commands');
    },
  );

  test('terminal status updates merge by terminal id', () async {
    final controller = ChatController(
      client: FakeAgentClient(
        resumeEvents: const [
          AgentEvent(
            type: AgentEventType.status,
            text: 'printf terminal-output',
            metadata: {
              'kind': 'terminal',
              'terminalEvent': 'created',
              'terminalId': 'session-1:terminal-1',
              'status': 'running',
              'command': 'printf',
              'args': ['terminal-output'],
            },
          ),
          AgentEvent(
            type: AgentEventType.status,
            text: 'Terminal output.',
            metadata: {
              'kind': 'terminal',
              'terminalEvent': 'output',
              'terminalId': 'session-1:terminal-1',
              'status': 'completed',
              'output': 'terminal-output',
              'exitCode': 0,
            },
          ),
          AgentEvent(
            type: AgentEventType.status,
            text: 'Terminal released.',
            metadata: {
              'kind': 'terminal',
              'terminalEvent': 'released',
              'terminalId': 'session-1:terminal-1',
              'status': 'released',
            },
          ),
        ],
      ),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    await controller.resumeSession('session-1');

    expect(controller.messages, hasLength(1));
    expect(controller.messages.single.text, 'printf terminal-output');
    expect(controller.messages.single.metadata['status'], 'completed');
    expect(controller.messages.single.metadata['terminalEvent'], 'released');
    expect(controller.messages.single.metadata['command'], 'printf');
    expect(controller.messages.single.metadata['output'], 'terminal-output');
  });

  test('permission history records user decisions', () async {
    final fake = FakeAgentClient();
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    fake.emitPermissionRequest(
      AcpPermissionRequest(
        id: 'permission-1',
        title: 'Read file',
        rationale: 'Requested by agent',
        sessionId: 'session-1',
        toolName: 'read_text_file',
        toolKind: 'read',
        options: const ['Allow', 'Deny'],
        requestedAt: DateTime(2026, 5, 31, 12),
      ),
    );
    await pumpEventQueue();

    expect(controller.pendingPermissionRequest?.id, 'permission-1');
    expect(controller.permissionHistory, hasLength(1));
    expect(
      controller.permissionHistory.single.status,
      AcpPermissionAuditStatus.pending,
    );

    await controller.resolvePermissionRequest(AcpPermissionDecision.deny);

    expect(controller.pendingPermissionRequest, isNull);
    expect(fake.lastPermissionRequestId, 'permission-1');
    expect(fake.lastPermissionDecision, AcpPermissionDecision.deny);
    expect(
      controller.permissionHistory.single.status,
      AcpPermissionAuditStatus.denied,
    );
    expect(
      controller.permissionHistory.single.decisionSource,
      AcpPermissionDecisionSource.manual,
    );
    expect(controller.permissionHistory.single.resolvedAt, isNotNull);
  });

  test(
    'duplicate permission decisions are ignored while one is sending',
    () async {
      final fake = _DelayedPermissionResponseAgentClient();
      final controller = ChatController(client: fake, cwd: '/workspace');
      addTearDown(controller.dispose);

      fake.emitPermissionRequest(
        AcpPermissionRequest(
          id: 'permission-1',
          title: 'Read file',
          rationale: 'Requested by agent',
          sessionId: 'session-1',
          toolName: 'read_text_file',
          options: const ['Allow', 'Deny'],
          requestedAt: DateTime(2026, 5, 31, 12),
        ),
      );
      await pumpEventQueue();

      final allow = controller.resolvePermissionRequest(
        AcpPermissionDecision.allow,
      );
      await fake.responseStarted.future;
      final deny = controller.resolvePermissionRequest(
        AcpPermissionDecision.deny,
      );
      await pumpEventQueue();

      expect(fake.permissionResponseCount, 1);
      expect(controller.pendingPermissionRequest?.id, 'permission-1');

      fake.allowResponse.complete();
      await Future.wait([allow, deny]);

      expect(fake.permissionResponseCount, 1);
      expect(fake.lastPermissionDecision, AcpPermissionDecision.allow);
      expect(controller.pendingPermissionRequest, isNull);
      expect(
        controller.permissionHistory.single.status,
        AcpPermissionAuditStatus.allowed,
      );
    },
  );

  test(
    'resolved duplicate permission requests do not become pending again',
    () async {
      final fake = _CountingPermissionResponseAgentClient();
      final controller = ChatController(client: fake, cwd: '/workspace');
      addTearDown(controller.dispose);

      final request = AcpPermissionRequest(
        id: 'permission-1',
        title: 'Read file',
        rationale: 'Requested by agent',
        sessionId: 'session-1',
        toolName: 'read_text_file',
        options: const ['Allow', 'Deny'],
        requestedAt: DateTime(2026, 5, 31, 12),
      );

      fake.emitPermissionRequest(request);
      await pumpEventQueue();
      await controller.resolvePermissionRequest(AcpPermissionDecision.allow);

      expect(fake.permissionResponseCount, 1);
      expect(controller.pendingPermissionRequest, isNull);
      expect(
        controller.permissionHistory.single.status,
        AcpPermissionAuditStatus.allowed,
      );

      fake.emitPermissionRequest(request);
      await pumpEventQueue();

      expect(fake.permissionResponseCount, 1);
      expect(controller.pendingPermissionRequest, isNull);
      expect(controller.permissionHistory, hasLength(1));
      expect(
        controller.permissionHistory.single.status,
        AcpPermissionAuditStatus.allowed,
      );
      expect(
        controller.permissionHistory.single.decisionSource,
        AcpPermissionDecisionSource.manual,
      );
    },
  );

  test('failed manual permission responses keep the request pending', () async {
    final fake = FakeAgentClient(
      permissionResponseError: StateError('permission response failed'),
    );
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    fake.emitPermissionRequest(
      AcpPermissionRequest(
        id: 'permission-1',
        title: 'Read file',
        rationale: 'Requested by agent',
        sessionId: 'session-1',
        toolName: 'read_text_file',
        options: const ['Allow', 'Deny'],
        requestedAt: DateTime(2026, 5, 31, 12),
      ),
    );
    await pumpEventQueue();

    await controller.resolvePermissionRequest(AcpPermissionDecision.allow);

    expect(fake.lastPermissionRequestId, 'permission-1');
    expect(fake.lastPermissionDecision, AcpPermissionDecision.allow);
    expect(controller.pendingPermissionRequest?.id, 'permission-1');
    expect(
      controller.permissionHistory.single.status,
      AcpPermissionAuditStatus.pending,
    );
    expect(controller.permissionHistory.single.decisionSource, isNull);
    expect(controller.permissionHistory.single.resolvedAt, isNull);
    expect(controller.lastError, contains('permission response failed'));
  });

  test('permission history cancels superseded pending requests', () async {
    final fake = FakeAgentClient();
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    fake.emitPermissionRequest(
      AcpPermissionRequest(
        id: 'permission-1',
        title: 'Read file',
        rationale: 'Requested by agent',
        sessionId: 'session-1',
        toolName: 'read_text_file',
        options: const ['Allow', 'Deny'],
        requestedAt: DateTime(2026, 5, 31, 12),
      ),
    );
    await pumpEventQueue();
    fake.emitPermissionRequest(
      AcpPermissionRequest(
        id: 'permission-2',
        title: 'Run command',
        rationale: 'Requested by agent',
        sessionId: 'session-1',
        toolName: 'terminal',
        options: const ['Allow', 'Deny'],
        requestedAt: DateTime(2026, 5, 31, 12, 1),
      ),
    );
    await pumpEventQueue();

    expect(controller.pendingPermissionRequest?.id, 'permission-2');
    expect(fake.lastPermissionRequestId, 'permission-1');
    expect(fake.lastPermissionDecision, AcpPermissionDecision.cancel);
    expect(controller.permissionHistory.map((entry) => entry.request.id), [
      'permission-2',
      'permission-1',
    ]);
    expect(
      controller.permissionHistory[0].status,
      AcpPermissionAuditStatus.pending,
    );
    expect(
      controller.permissionHistory[1].status,
      AcpPermissionAuditStatus.cancelled,
    );
    expect(
      controller.permissionHistory[1].decisionSource,
      AcpPermissionDecisionSource.system,
    );
  });

  test(
    'permission requests for inactive sessions do not replace current pending',
    () async {
      final fake = FakeAgentClient();
      final controller = ChatController(client: fake, cwd: '/workspace');
      addTearDown(controller.dispose);

      await controller.newSession();
      fake.emitPermissionRequest(
        AcpPermissionRequest(
          id: 'permission-active',
          title: 'Read file',
          rationale: 'Requested by agent',
          sessionId: 'fake-session-1',
          toolName: 'read_text_file',
          options: const ['Allow', 'Deny'],
          requestedAt: DateTime(2026, 5, 31, 12),
        ),
      );
      await pumpEventQueue();

      expect(controller.pendingPermissionRequest?.id, 'permission-active');

      fake.emitPermissionRequest(
        AcpPermissionRequest(
          id: 'permission-stale',
          title: 'Run command',
          rationale: 'Requested by previous session',
          sessionId: 'previous-session',
          toolName: 'terminal',
          options: const ['Allow', 'Deny'],
          requestedAt: DateTime(2026, 5, 31, 12, 1),
        ),
      );
      await pumpEventQueue();

      expect(controller.pendingPermissionRequest?.id, 'permission-active');
      expect(fake.lastPermissionRequestId, 'permission-stale');
      expect(fake.lastPermissionDecision, AcpPermissionDecision.cancel);
      expect(controller.permissionHistory.map((entry) => entry.request.id), [
        'permission-stale',
        'permission-active',
      ]);
      expect(
        controller.permissionHistory[0].status,
        AcpPermissionAuditStatus.cancelled,
      );
      expect(
        controller.permissionHistory[0].decisionSource,
        AcpPermissionDecisionSource.system,
      );
      expect(
        controller.permissionHistory[1].status,
        AcpPermissionAuditStatus.pending,
      );
    },
  );

  test(
    'permission requests for closed sessions are cancelled without active session',
    () async {
      final fake = FakeAgentClient();
      final controller = ChatController(client: fake, cwd: '/workspace');
      addTearDown(controller.dispose);

      await controller.newSession();
      await controller.closeCurrentSession();
      expect(controller.currentSession, isNull);

      fake.emitPermissionRequest(
        AcpPermissionRequest(
          id: 'permission-stale',
          title: 'Run command',
          rationale: 'Requested by closed session',
          sessionId: 'fake-session-1',
          toolName: 'terminal',
          options: const ['Allow', 'Deny'],
          requestedAt: DateTime(2026, 5, 31, 12),
        ),
      );
      await pumpEventQueue();

      expect(controller.pendingPermissionRequest, isNull);
      expect(fake.lastPermissionRequestId, 'permission-stale');
      expect(fake.lastPermissionDecision, AcpPermissionDecision.cancel);
      expect(controller.permissionHistory, hasLength(1));
      expect(
        controller.permissionHistory.single.status,
        AcpPermissionAuditStatus.cancelled,
      );
      expect(
        controller.permissionHistory.single.decisionSource,
        AcpPermissionDecisionSource.system,
      );
    },
  );

  test(
    'stop continues prompt cancellation when permission cancel response fails',
    () async {
      final fake = FakeAgentClient(
        chunkDelay: const Duration(milliseconds: 20),
        permissionResponseError: StateError('permission response failed'),
      );
      final controller = ChatController(client: fake, cwd: '/workspace');
      addTearDown(controller.dispose);

      await controller.newSession();
      await controller.sendPrompt('Hi');
      fake.emitPermissionRequest(
        AcpPermissionRequest(
          id: 'permission-1',
          title: 'Run command',
          rationale: 'Requested by agent',
          sessionId: 'fake-session-1',
          toolName: 'terminal',
          options: const ['Allow', 'Deny'],
          requestedAt: DateTime(2026, 5, 31, 12),
        ),
      );
      await pumpEventQueue();

      expect(controller.pendingPermissionRequest?.id, 'permission-1');

      await controller.stop();

      expect(fake.lastPermissionRequestId, 'permission-1');
      expect(fake.lastPermissionDecision, AcpPermissionDecision.cancel);
      expect(fake.cancelled, isTrue);
      expect(controller.pendingPermissionRequest, isNull);
      expect(
        controller.permissionHistory.single.status,
        AcpPermissionAuditStatus.cancelled,
      );
      expect(controller.lastError, contains('permission response failed'));
    },
  );

  test(
    'permission history cancels pending request when stream closes',
    () async {
      final fake = FakeAgentClient();
      final controller = ChatController(client: fake, cwd: '/workspace');
      addTearDown(controller.dispose);

      fake.emitPermissionRequest(
        AcpPermissionRequest(
          id: 'permission-1',
          title: 'Read file',
          rationale: 'Requested by agent',
          sessionId: 'session-1',
          toolName: 'read_text_file',
          options: const ['Allow', 'Deny'],
          requestedAt: DateTime(2026, 5, 31, 12),
        ),
      );
      await pumpEventQueue();

      await fake.closePermissionRequests();
      await pumpEventQueue();

      expect(controller.pendingPermissionRequest, isNull);
      expect(
        controller.permissionHistory.single.status,
        AcpPermissionAuditStatus.cancelled,
      );
      expect(
        controller.permissionHistory.single.decisionSource,
        AcpPermissionDecisionSource.system,
      );
    },
  );

  test(
    'permission history cancels pending request when prompt stream ends',
    () async {
      final fake = FakeAgentClient(
        chunkDelay: const Duration(milliseconds: 10),
      );
      final controller = ChatController(client: fake, cwd: '/workspace');
      addTearDown(controller.dispose);

      await controller.newSession();
      await controller.sendPrompt('Hi');
      fake.emitPermissionRequest(
        AcpPermissionRequest(
          id: 'permission-1',
          title: 'Run command',
          rationale: 'Requested by agent',
          sessionId: 'fake-session-1',
          toolName: 'terminal',
          options: const ['Allow', 'Deny'],
          requestedAt: DateTime(2026, 5, 31, 12),
        ),
      );
      await pumpEventQueue();

      expect(controller.pendingPermissionRequest?.id, 'permission-1');

      await Future<void>.delayed(const Duration(milliseconds: 80));
      await pumpEventQueue(times: 4);

      expect(controller.isStreaming, isFalse);
      expect(controller.pendingPermissionRequest, isNull);
      expect(fake.lastPermissionRequestId, 'permission-1');
      expect(fake.lastPermissionDecision, AcpPermissionDecision.cancel);
      expect(
        controller.permissionHistory.single.status,
        AcpPermissionAuditStatus.cancelled,
      );
      expect(
        controller.permissionHistory.single.decisionSource,
        AcpPermissionDecisionSource.system,
      );
      expect(controller.lastError, isNull);
    },
  );

  test(
    'permission history drops oldest entries over the in-memory limit',
    () async {
      final fake = FakeAgentClient();
      final controller = ChatController(
        client: fake,
        cwd: '/workspace',
        permissionHistoryLimit: 2,
      );
      addTearDown(controller.dispose);

      for (var index = 1; index <= 3; index += 1) {
        fake.emitPermissionRequest(
          AcpPermissionRequest(
            id: 'permission-$index',
            title: 'Permission $index',
            rationale: 'Requested by agent',
            sessionId: 'session-1',
            toolName: 'read_text_file',
            options: const ['Allow', 'Deny'],
            requestedAt: DateTime(2026, 5, 31, 12, index),
          ),
        );
        await pumpEventQueue();
      }

      expect(controller.permissionHistory.map((entry) => entry.request.id), [
        'permission-3',
        'permission-2',
      ]);
      expect(
        controller.permissionHistory[0].status,
        AcpPermissionAuditStatus.pending,
      );
      expect(
        controller.permissionHistory[1].status,
        AcpPermissionAuditStatus.cancelled,
      );
      expect(
        controller.permissionHistory[1].decisionSource,
        AcpPermissionDecisionSource.system,
      );
    },
  );

  test('permission trust rules auto resolve matching requests', () async {
    final fake = FakeAgentClient();
    final controller = ChatController(
      client: fake,
      cwd: '/workspace',
      permissionTrustRules: const [
        AcpPermissionTrustRule(
          toolName: 'read_text_file',
          toolKind: 'read',
          decision: AcpPermissionDecision.allow,
        ),
      ],
    );
    addTearDown(controller.dispose);

    fake.emitPermissionRequest(
      AcpPermissionRequest(
        id: 'permission-1',
        title: 'Read file',
        rationale: 'Requested by agent',
        sessionId: 'session-1',
        toolName: 'read_text_file',
        toolKind: 'read',
        options: const ['Allow', 'Deny'],
        requestedAt: DateTime(2026, 5, 31, 12),
      ),
    );
    await pumpEventQueue();

    expect(controller.pendingPermissionRequest, isNull);
    expect(fake.lastPermissionRequestId, 'permission-1');
    expect(fake.lastPermissionDecision, AcpPermissionDecision.allow);
    expect(controller.permissionHistory, hasLength(1));
    expect(
      controller.permissionHistory.single.status,
      AcpPermissionAuditStatus.allowed,
    );
    expect(
      controller.permissionHistory.single.decisionSource,
      AcpPermissionDecisionSource.trustRule,
    );
    expect(controller.permissionHistory.single.resolvedAt, isNotNull);
  });

  test('auto review permission reviewer resolves requests', () async {
    final fake = FakeAgentClient();
    final reviewer = _FakePermissionReviewer(
      const AcpPermissionReviewResult(
        decision: AcpPermissionDecision.allow,
        risk: 'low',
        rationale: 'Command stays in the workspace.',
        reviewer: 'sidecar-reviewer',
        model: 'review-model',
      ),
    );
    final controller = ChatController(
      client: fake,
      cwd: '/workspace',
      permissionReviewer: reviewer,
    );
    controller.sessionSettings = const AcpSessionSettings(
      configOptions: [
        AcpConfigOption(
          id: 'model',
          name: 'Model',
          type: 'select',
          currentValue: 'primary-model',
          options: [
            AcpConfigOptionChoice(value: 'primary-model', name: 'Primary'),
          ],
        ),
      ],
    );
    addTearDown(controller.dispose);

    fake.emitPermissionRequest(
      AcpPermissionRequest(
        id: 'permission-1',
        title: 'Create terminal',
        rationale: 'Requested by agent',
        sessionId: 'session-1',
        toolName: 'terminal',
        toolKind: 'execute',
        options: const ['Allow', 'Deny'],
        requestedAt: DateTime(2026, 5, 31, 12),
        metadata: const <String, Object?>{
          'command': 'git status',
          'cwd': '/workspace',
          'workspaceRoot': '/workspace',
        },
      ),
    );
    await pumpEventQueue(times: 2);

    expect(reviewer.requests.single.id, 'permission-1');
    expect(reviewer.workspaceRoots.single, '/workspace');
    expect(reviewer.models.single, 'primary-model');
    expect(controller.pendingPermissionRequest, isNull);
    expect(fake.lastPermissionRequestId, 'permission-1');
    expect(fake.lastPermissionDecision, AcpPermissionDecision.allow);
    expect(
      controller.permissionHistory.single.status,
      AcpPermissionAuditStatus.allowed,
    );
    expect(
      controller.permissionHistory.single.decisionSource,
      AcpPermissionDecisionSource.reviewAgent,
    );
    expect(controller.permissionHistory.single.reviewResult?.risk, 'low');
    expect(
      controller.permissionHistory.single.reviewResult?.model,
      'review-model',
    );
  });

  test('auto review opinion without a decision keeps request manual', () async {
    final fake = FakeAgentClient();
    final reviewer = _FakePermissionReviewer(
      const AcpPermissionReviewResult(
        risk: 'medium',
        rationale: 'Needs human confirmation.',
        reviewer: 'sidecar-reviewer',
      ),
    );
    final controller = ChatController(
      client: fake,
      cwd: '/workspace',
      permissionReviewer: reviewer,
    );
    addTearDown(controller.dispose);

    fake.emitPermissionRequest(
      AcpPermissionRequest(
        id: 'permission-1',
        title: 'Create terminal',
        rationale: 'Requested by agent',
        sessionId: 'session-1',
        toolName: 'terminal',
        toolKind: 'execute',
        options: const ['Allow', 'Deny'],
        requestedAt: DateTime(2026, 5, 31, 12),
      ),
    );
    await pumpEventQueue(times: 2);

    expect(controller.pendingPermissionRequest?.id, 'permission-1');
    expect(fake.lastPermissionRequestId, isNull);
    expect(
      controller.permissionHistory.single.status,
      AcpPermissionAuditStatus.pending,
    );
    expect(controller.permissionHistory.single.decisionSource, isNull);
    expect(controller.permissionHistory.single.reviewResult?.risk, 'medium');
    expect(
      controller.permissionHistory.single.reviewResult?.rationale,
      'Needs human confirmation.',
    );
  });

  test('disposing controller ignores late permission review results', () async {
    final fake = FakeAgentClient();
    final reviewer = _DelayedPermissionReviewer();
    final controller = ChatController(
      client: fake,
      cwd: '/workspace',
      permissionReviewer: reviewer,
    );

    fake.emitPermissionRequest(
      AcpPermissionRequest(
        id: 'permission-1',
        title: 'Create terminal',
        rationale: 'Requested by agent',
        sessionId: 'session-1',
        toolName: 'terminal',
        toolKind: 'execute',
        options: const ['Allow', 'Deny'],
        requestedAt: DateTime(2026, 5, 31, 12),
      ),
    );
    await pumpEventQueue();

    expect(reviewer.requests.single.id, 'permission-1');
    expect(controller.pendingPermissionRequest?.id, 'permission-1');

    controller.dispose();
    reviewer.complete(
      const AcpPermissionReviewResult(
        decision: AcpPermissionDecision.allow,
        risk: 'low',
        rationale: 'Read-only command.',
      ),
    );
    await pumpEventQueue(times: 3);

    expect(fake.lastPermissionRequestId, isNull);
    expect(fake.lastPermissionDecision, isNull);
  });

  test(
    'default permission policy keeps matching trust rule requests manual',
    () async {
      final fake = FakeAgentClient();
      final controller = ChatController(
        client: fake,
        cwd: '/workspace',
        permissionTrustRules: const [
          AcpPermissionTrustRule(
            toolName: 'read_text_file',
            decision: AcpPermissionDecision.allow,
          ),
        ],
      );
      addTearDown(controller.dispose);
      controller.setToolCallExecutionPolicy(
        AcpToolCallExecutionPolicy.defaultPermissions,
      );

      fake.emitPermissionRequest(
        AcpPermissionRequest(
          id: 'permission-1',
          title: 'Read file',
          rationale: 'Requested by agent',
          sessionId: 'session-1',
          toolName: 'read_text_file',
          options: const ['Allow', 'Deny'],
          requestedAt: DateTime(2026, 5, 31, 12),
        ),
      );
      await pumpEventQueue();

      expect(controller.pendingPermissionRequest?.id, 'permission-1');
      expect(fake.lastPermissionRequestId, isNull);
      expect(
        controller.permissionHistory.single.status,
        AcpPermissionAuditStatus.pending,
      );
    },
  );

  test('full access permission policy allows requests automatically', () async {
    final fake = FakeAgentClient();
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);
    controller.setToolCallExecutionPolicy(
      AcpToolCallExecutionPolicy.fullAccess,
    );

    fake.emitPermissionRequest(
      AcpPermissionRequest(
        id: 'permission-1',
        title: 'Run command',
        rationale: 'Requested by agent',
        sessionId: 'session-1',
        toolName: 'terminal',
        toolKind: 'execute',
        options: const ['Allow', 'Deny'],
        requestedAt: DateTime(2026, 5, 31, 12),
      ),
    );
    await pumpEventQueue();

    expect(controller.pendingPermissionRequest, isNull);
    expect(fake.lastPermissionRequestId, 'permission-1');
    expect(fake.lastPermissionDecision, AcpPermissionDecision.allow);
    expect(
      controller.permissionHistory.single.status,
      AcpPermissionAuditStatus.allowed,
    );
    expect(
      controller.permissionHistory.single.decisionSource,
      AcpPermissionDecisionSource.policy,
    );
  });

  test(
    'switching to full access resolves the current pending request',
    () async {
      final fake = FakeAgentClient();
      final controller = ChatController(client: fake, cwd: '/workspace');
      addTearDown(controller.dispose);

      fake.emitPermissionRequest(
        AcpPermissionRequest(
          id: 'permission-1',
          title: 'Run command',
          rationale: 'Requested by agent',
          sessionId: 'session-1',
          toolName: 'terminal',
          toolKind: 'execute',
          options: const ['Allow', 'Deny'],
          requestedAt: DateTime(2026, 5, 31, 12),
        ),
      );
      await pumpEventQueue();
      expect(controller.pendingPermissionRequest?.id, 'permission-1');

      controller.setToolCallExecutionPolicy(
        AcpToolCallExecutionPolicy.fullAccess,
      );
      await pumpEventQueue();

      expect(controller.pendingPermissionRequest, isNull);
      expect(fake.lastPermissionRequestId, 'permission-1');
      expect(fake.lastPermissionDecision, AcpPermissionDecision.allow);
      expect(
        controller.permissionHistory.single.decisionSource,
        AcpPermissionDecisionSource.policy,
      );
    },
  );

  test(
    'failed trust rule permission responses keep the request pending',
    () async {
      final fake = FakeAgentClient(
        permissionResponseError: StateError('permission response failed'),
      );
      final controller = ChatController(
        client: fake,
        cwd: '/workspace',
        permissionTrustRules: const [
          AcpPermissionTrustRule(
            toolName: 'read_text_file',
            decision: AcpPermissionDecision.allow,
          ),
        ],
      );
      addTearDown(controller.dispose);

      fake.emitPermissionRequest(
        AcpPermissionRequest(
          id: 'permission-1',
          title: 'Read file',
          rationale: 'Requested by agent',
          sessionId: 'session-1',
          toolName: 'read_text_file',
          options: const ['Allow', 'Deny'],
          requestedAt: DateTime(2026, 5, 31, 12),
        ),
      );
      await pumpEventQueue();

      expect(fake.lastPermissionRequestId, 'permission-1');
      expect(fake.lastPermissionDecision, AcpPermissionDecision.allow);
      expect(controller.pendingPermissionRequest?.id, 'permission-1');
      expect(
        controller.permissionHistory.single.status,
        AcpPermissionAuditStatus.pending,
      );
      expect(controller.permissionHistory.single.decisionSource, isNull);
      expect(controller.permissionHistory.single.resolvedAt, isNull);
      expect(controller.lastError, contains('permission response failed'));
    },
  );

  test('set session mode updates ACP session settings', () async {
    final fake = FakeAgentClient(sessionSettings: _settingsWithMode('ask'));
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    await controller.newSession();
    await controller.setSessionMode('edit');

    expect(fake.lastSetModeId, 'edit');
    expect(controller.sessionSettings.modes.currentModeId, 'edit');
    expect(controller.lastError, isNull);
  });

  test(
    'set session mode is ignored when config options are available',
    () async {
      final fake = FakeAgentClient();
      final controller = ChatController(client: fake, cwd: '/workspace');
      addTearDown(controller.dispose);

      await controller.newSession();
      await controller.setSessionMode('edit');

      expect(fake.lastSetModeId, isNull);
      expect(controller.sessionSettings.modes.currentModeId, isNull);
      expect(controller.lastError, isNull);
    },
  );

  test('set config option updates ACP session settings', () async {
    final fake = FakeAgentClient();
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    await controller.newSession();
    await controller.setConfigOption('approval', 'auto');

    expect(fake.lastConfigId, 'approval');
    expect(fake.lastConfigValue, 'auto');
    expect(
      controller.sessionSettings.configOptions.single.currentValue,
      'auto',
    );
    expect(controller.lastError, isNull);
  });

  test('runtime config option updates clear legacy modes', () async {
    final controller = ChatController(
      client: _ConfigOptionUpdateAgentClient(),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    await controller.newSession();
    expect(controller.sessionSettings.modes.currentModeId, 'ask');

    await controller.sendPrompt('Update settings');
    await pumpEventQueue(times: 4);

    expect(controller.sessionSettings.configOptions.single.id, 'model');
    expect(controller.sessionSettings.currentModelLabel, 'GPT-5');
    expect(controller.sessionSettings.modes.currentModeId, isNull);
    expect(controller.sessionSettings.modes.availableModes, isEmpty);
  });

  test(
    'set config option preserves local options when response omits list',
    () async {
      final fake = _OmittingConfigOptionsAgentClient();
      final controller = ChatController(client: fake, cwd: '/workspace');
      addTearDown(controller.dispose);

      await controller.newSession();
      await controller.setConfigOption('approval', 'auto');

      expect(fake.lastConfigId, 'approval');
      expect(fake.lastConfigValue, 'auto');
      expect(controller.sessionSettings.configOptions, hasLength(1));
      expect(
        controller.sessionSettings.configOptions.single.currentValue,
        'auto',
      );
      expect(controller.lastError, isNull);
    },
  );

  test('set session model updates model config option', () async {
    final fake = FakeAgentClient(
      sessionSettings: const AcpSessionSettings(
        configOptions: [
          AcpConfigOption(
            id: 'model',
            name: 'Model',
            type: 'select',
            currentValue: 'gpt-5',
            options: [
              AcpConfigOptionChoice(value: 'gpt-5', name: 'GPT-5'),
              AcpConfigOptionChoice(
                value: 'claude-sonnet-4',
                name: 'Claude Sonnet 4',
              ),
            ],
          ),
        ],
      ),
    );
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    await controller.newSession();
    await controller.setSessionModel('claude-sonnet-4');

    expect(fake.lastConfigId, 'model');
    expect(fake.lastConfigValue, 'claude-sonnet-4');
    expect(controller.sessionSettings.currentModelLabel, 'Claude Sonnet 4');
    expect(controller.lastError, isNull);
  });

  test(
    'session settings changes are ignored while a session operation runs',
    () async {
      final fake = _DelayedForkAgentClient();
      final controller = ChatController(client: fake, cwd: '/workspace');
      addTearDown(controller.dispose);

      await controller.newSession();

      final fork = controller.forkCurrentSession();
      await fake.forkStarted.future;

      expect(controller.isSessionOperationRunning, isTrue);

      await controller.refreshSessionSettings();
      await controller.setSessionMode('edit');
      await controller.setConfigOption('approval', 'auto');
      await controller.setSessionModel('gpt-5');

      expect(fake.lastSetModeId, isNull);
      expect(fake.lastConfigId, isNull);

      fake.allowFork.complete();
      await fork;
    },
  );

  test(
    'stale session settings refresh does not overwrite forked session settings',
    () async {
      final fake = _StaleSessionSettingsAgentClient();
      final controller = ChatController(client: fake, cwd: '/workspace');
      addTearDown(controller.dispose);

      await controller.newSession();
      expect(controller.currentSession?.id, 'fake-session-1');
      expect(controller.sessionSettings.modes.currentModeId, 'ask');

      final refresh = controller.refreshSessionSettings();
      await fake.staleRefreshStarted.future;
      expect(controller.sessionSettingsLoading, isTrue);

      await controller.forkCurrentSession();

      expect(controller.currentSession?.id, 'fake-fork-2');
      expect(controller.sessionSettings.modes.currentModeId, 'edit');
      expect(controller.sessionSettingsLoading, isFalse);

      fake.allowStaleRefresh.complete();
      await refresh;

      expect(controller.currentSession?.id, 'fake-fork-2');
      expect(controller.sessionSettings.modes.currentModeId, 'edit');
      expect(controller.sessionSettingsLoading, isFalse);
    },
  );

  test('stale session mode response is ignored after session close', () async {
    final fake = _DelayedSettingsMutationAgentClient(
      sessionSettings: _settingsWithMode('ask'),
    );
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    await controller.newSession();
    final updateMode = controller.setSessionMode('edit');
    await fake.modeStarted.future;

    await controller.closeCurrentSession();
    fake.allowMode.complete();
    await updateMode;

    expect(fake.lastSetModeId, 'edit');
    expect(fake.lastClosedSessionId, 'fake-session-1');
    expect(controller.currentSession, isNull);
    expect(controller.sessionSettings.modes.currentModeId, isNull);
    expect(controller.sessionSettings.modes.availableModes, isEmpty);
    expect(controller.lastError, isNull);
  });

  test('stale config option response is ignored after session close', () async {
    final fake = _DelayedSettingsMutationAgentClient();
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    await controller.newSession();
    final updateConfig = controller.setConfigOption('approval', 'auto');
    await fake.configStarted.future;

    await controller.closeCurrentSession();
    fake.allowConfig.complete();
    await updateConfig;

    expect(fake.lastConfigId, 'approval');
    expect(fake.lastConfigValue, 'auto');
    expect(fake.lastClosedSessionId, 'fake-session-1');
    expect(controller.currentSession, isNull);
    expect(controller.sessionSettings.configOptions, isEmpty);
    expect(controller.lastError, isNull);
  });

  test('fork current session creates independent active session', () async {
    final fake = FakeAgentClient();
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    await controller.newSession();
    await controller.sendPrompt('Hi');
    await pumpEventQueue(times: 12);

    expect(controller.canForkCurrentSession, isTrue);
    expect(controller.sessions.map((session) => session.id), [
      'fake-session-1',
    ]);

    await controller.forkCurrentSession();

    expect(fake.lastForkedSessionId, 'fake-session-1');
    expect(controller.currentSession?.id, 'fake-fork-2');
    expect(controller.currentSession?.displayTitle, 'Fork of fake-ses');
    expect(controller.currentSession?.agentName, 'Codex');
    expect(controller.sessions.map((session) => session.id), [
      'fake-fork-2',
      'fake-session-1',
    ]);
    expect(controller.messages, isEmpty);
    expect(controller.status, app_state.ConnectionStatus.sessionReady);
  });

  test('fork current session applies initial fork events', () async {
    final fake = FakeAgentClient(
      forkSessionEvents: const [
        AgentEvent(
          type: AgentEventType.status,
          text: 'review',
          metadata: <String, Object?>{
            'kind': 'commands',
            'commands': [
              <String, Object?>{
                'name': 'review',
                'description': 'Review the forked session.',
              },
            ],
          },
        ),
      ],
    );
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    await controller.newSession();
    await controller.forkCurrentSession();

    expect(controller.currentSession?.id, 'fake-fork-2');
    expect(controller.availableCommands.single['name'], 'review');
    expect(controller.messages.single.metadata['kind'], 'commands');
  });

  test('fork current session preserves initial error events', () async {
    final fake = FakeAgentClient(
      forkSessionEvents: const [
        AgentEvent(type: AgentEventType.error, text: 'fork setup failed'),
      ],
    );
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    await controller.newSession();
    await controller.forkCurrentSession();

    expect(controller.currentSession?.id, 'fake-fork-2');
    expect(controller.status, app_state.ConnectionStatus.error);
    expect(controller.lastError, contains('fork setup failed'));
    expect(controller.messages.map((message) => message.role), [
      ChatMessageRole.error,
    ]);
  });

  test('close current session clears active state', () async {
    final fake = FakeAgentClient();
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    await controller.newSession();
    await controller.sendPrompt('Hi');
    await pumpEventQueue(times: 12);
    expect(controller.currentSession?.id, 'fake-session-1');
    expect(controller.messages, isNotEmpty);

    await controller.closeCurrentSession();

    expect(fake.lastClosedSessionId, 'fake-session-1');
    expect(controller.currentSession, isNull);
    expect(controller.sessions, isEmpty);
    expect(controller.messages, isEmpty);
    expect(controller.status, app_state.ConnectionStatus.connected);
  });

  test(
    'close current session ignores permission cleanup response errors',
    () async {
      final fake = FakeAgentClient(
        permissionResponseError: StateError('permission response failed'),
      );
      final controller = ChatController(client: fake, cwd: '/workspace');
      addTearDown(controller.dispose);

      await controller.newSession();
      fake.emitPermissionRequest(
        AcpPermissionRequest(
          id: 'permission-1',
          title: 'Run command',
          rationale: 'Requested by agent',
          sessionId: 'fake-session-1',
          toolName: 'terminal',
          options: const ['Allow', 'Deny'],
          requestedAt: DateTime(2026, 5, 31, 12),
        ),
      );
      await pumpEventQueue();

      expect(controller.pendingPermissionRequest?.id, 'permission-1');

      await controller.closeCurrentSession();

      expect(fake.lastClosedSessionId, 'fake-session-1');
      expect(fake.lastPermissionRequestId, 'permission-1');
      expect(fake.lastPermissionDecision, AcpPermissionDecision.cancel);
      expect(controller.currentSession, isNull);
      expect(controller.pendingPermissionRequest, isNull);
      expect(controller.lastError, isNull);
      expect(controller.status, app_state.ConnectionStatus.connected);
      expect(
        controller.permissionHistory.single.status,
        AcpPermissionAuditStatus.cancelled,
      );
    },
  );

  test('logout clears local session state', () async {
    final fake = FakeAgentClient();
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    await controller.newSession();
    await controller.sendPrompt('Hi');
    await pumpEventQueue(times: 12);
    expect(controller.canLogout, isTrue);

    await controller.logout();

    expect(fake.loggedOut, isTrue);
    expect(controller.currentSession, isNull);
    expect(controller.sessions, isEmpty);
    expect(controller.messages, isEmpty);
    expect(controller.status, app_state.ConnectionStatus.connected);

    fake.emitPermissionRequest(
      AcpPermissionRequest(
        id: 'permission-logout-stale',
        title: 'Run command',
        rationale: 'Requested by logged-out session',
        sessionId: 'fake-session-1',
        toolName: 'terminal',
        options: const ['Allow', 'Deny'],
        requestedAt: DateTime(2026, 5, 31, 12),
      ),
    );
    await pumpEventQueue();

    expect(controller.pendingPermissionRequest, isNull);
    expect(fake.lastPermissionRequestId, 'permission-logout-stale');
    expect(fake.lastPermissionDecision, AcpPermissionDecision.cancel);
  });

  test('authenticate invokes advertised auth method', () async {
    final fake = FakeAgentClient(
      authMethods: const [
        {
          'id': 'browser',
          'name': 'Browser sign-in',
          'description': 'Continue in the agent browser flow.',
        },
      ],
    );
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    await controller.connect();

    expect(controller.canAuthenticate, isTrue);
    expect(controller.authMethods.single['id'], 'browser');

    await controller.authenticate('browser');

    expect(fake.lastAuthenticatedMethodId, 'browser');
    expect(controller.lastError, isNull);
    expect(controller.isSessionOperationRunning, isFalse);
  });

  test('authenticate trims advertised auth method ids', () async {
    final fake = FakeAgentClient(
      authMethods: const [
        {'id': ' browser ', 'name': 'Browser sign-in'},
      ],
    );
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    await controller.connect();

    expect(controller.canAuthenticate, isTrue);
    await controller.authenticate('browser');

    expect(fake.lastAuthenticatedMethodId, 'browser');
    expect(controller.lastError, isNull);
  });

  test('send extension request forwards method and params', () async {
    final fake = FakeAgentClient(
      extensionResponse: const {
        'ok': true,
        'items': ['buffer.dart'],
      },
    );
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    await controller.connect();

    expect(controller.canSendExtensionRequest, isTrue);

    final result = await controller.sendExtensionRequest(
      method: '  _example.dev/listBuffers  ',
      params: const {'language': 'dart'},
    );

    expect(fake.lastExtensionMethod, '_example.dev/listBuffers');
    expect(fake.lastExtensionParams, {'language': 'dart'});
    expect(result['items'], ['buffer.dart']);
    expect(controller.lastError, isNull);
  });

  test('send extension request requires underscore-prefixed method', () async {
    final fake = FakeAgentClient();
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    await controller.connect();

    await expectLater(
      controller.sendExtensionRequest(
        method: 'example.dev/listBuffers',
        params: const {},
      ),
      throwsA(isA<StateError>()),
    );

    expect(fake.lastExtensionMethod, isNull);
  });

  test('auth required session errors point to authenticate action', () async {
    final controller = ChatController(
      client: FakeAgentClient(
        createSessionError: const _AuthRequiredError(),
        authMethods: const [
          {'id': 'browser', 'name': 'Browser sign-in'},
        ],
      ),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    await controller.newSession();

    expect(controller.status, app_state.ConnectionStatus.error);
    expect(controller.currentSession, isNull);
    expect(controller.lastError, contains('Authentication required'));
    expect(controller.lastError, contains('Agents menu'));
    expect(controller.lastError, contains('Authenticate'));
  });

  test('auth required prompt errors point to authenticate action', () async {
    final controller = ChatController(
      client: FakeAgentClient(
        promptError: const _AuthRequiredError(),
        authMethods: const [
          {'id': 'browser', 'name': 'Browser sign-in'},
        ],
      ),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    await controller.newSession();
    await controller.sendPrompt('Hi');
    await pumpEventQueue(times: 4);

    expect(controller.status, app_state.ConnectionStatus.error);
    expect(controller.lastError, contains('Agents menu'));
    expect(controller.messages.last.role, ChatMessageRole.error);
    expect(controller.messages.last.text, controller.lastError);
  });

  test('agentTextDone stop reason is rendered as a turn status', () async {
    final controller = ChatController(
      client: FakeAgentClient(
        resumeEvents: const [
          AgentEvent(
            type: AgentEventType.agentTextDone,
            text: '',
            metadata: {'stopReason': 'maxTokens', 'kind': 'turn'},
          ),
        ],
      ),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    await controller.resumeSession('resumed-session-3');

    expect(controller.messages, hasLength(1));
    expect(controller.messages.single.role, ChatMessageRole.status);
    expect(controller.messages.single.text, contains('token limit'));
    expect(controller.messages.single.metadata['stopReason'], 'maxTokens');
  });

  test('send prompt returns stream chunks appended to one message', () async {
    final controller = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    await controller.newSession();
    await controller.sendPrompt('Hi');
    await pumpEventQueue(times: 12);

    expect(controller.status, app_state.ConnectionStatus.sessionReady);
    expect(controller.isStreaming, isFalse);
    expect(controller.messages, hasLength(2));
    expect(controller.messages.first.role, ChatMessageRole.user);
    expect(controller.messages.first.text, 'Hi');
    expect(controller.messages.last.role, ChatMessageRole.assistant);
    expect(controller.messages.last.text, 'Hello, I am Codex.');
  });

  test('send prompt coalesces tool call chunks by call id', () async {
    final controller = ChatController(
      client: _ToolCallChunkAgentClient(),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    await controller.newSession();
    await controller.sendPrompt('Run command');
    await pumpEventQueue(times: 8);

    expect(controller.status, app_state.ConnectionStatus.sessionReady);
    expect(controller.isStreaming, isFalse);
    expect(controller.messages, hasLength(2));
    expect(controller.messages.first.role, ChatMessageRole.user);

    final toolMessage = controller.messages.last;
    expect(toolMessage.role, ChatMessageRole.tool);
    expect(toolMessage.text, 'Bash');
    expect(toolMessage.metadata['toolCallId'], 'call-1');
    expect(toolMessage.metadata['status'], 'completed');
    expect(toolMessage.metadata['rawInput'], {'command': 'echo hi'});
    expect(toolMessage.metadata['rawOutput'], 'hi');
  });

  test('send prompt coalesces tool call chunks by id aliases', () async {
    final controller = ChatController(
      client: _AliasToolCallChunkAgentClient(),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    await controller.newSession();
    await controller.sendPrompt('Run command');
    await pumpEventQueue(times: 8);

    expect(controller.status, app_state.ConnectionStatus.sessionReady);
    expect(controller.isStreaming, isFalse);
    expect(controller.messages, hasLength(2));

    final toolMessage = controller.messages.last;
    expect(toolMessage.role, ChatMessageRole.tool);
    expect(toolMessage.text, 'Bash');
    expect(toolMessage.metadata['id'], 'call-1');
    expect(toolMessage.metadata['callId'], 'call-1');
    expect(toolMessage.metadata['status'], 'completed');
    expect(toolMessage.metadata['rawOutput'], 'hi');
  });

  test(
    'send prompt coalesces tool call chunks by snake case id alias',
    () async {
      final controller = ChatController(
        client: _SnakeCaseToolCallChunkAgentClient(),
        cwd: '/workspace',
      );
      addTearDown(controller.dispose);

      await controller.newSession();
      await controller.sendPrompt('Run command');
      await pumpEventQueue(times: 8);

      expect(controller.status, app_state.ConnectionStatus.sessionReady);
      expect(controller.isStreaming, isFalse);
      expect(controller.messages, hasLength(2));

      final toolMessage = controller.messages.last;
      expect(toolMessage.role, ChatMessageRole.tool);
      expect(toolMessage.text, 'Bash');
      expect(toolMessage.metadata['tool_call_id'], 'call-1');
      expect(toolMessage.metadata['status'], 'completed');
      expect(toolMessage.metadata['raw_output'], 'hi');
    },
  );

  test(
    'send prompt forwards attachments and renders resource metadata',
    () async {
      final fake = FakeAgentClient();
      final controller = ChatController(client: fake, cwd: '/workspace');
      addTearDown(controller.dispose);
      const attachment = PromptAttachment(
        path: '/workspace/readme.md',
        name: 'readme.md',
        mimeType: 'text/markdown',
        size: 2048,
      );

      await controller.newSession();
      await controller.sendPrompt(
        'Review this file',
        attachments: [attachment],
      );
      await pumpEventQueue(times: 12);

      expect(fake.lastPrompt, 'Review this file');
      expect(fake.lastAttachments, [attachment]);
      expect(controller.messages.first.role, ChatMessageRole.user);
      expect(controller.messages.first.text, 'Review this file');
      expect(controller.messages.first.metadata['contentBlocks'], [
        attachment.toResourceLink(),
      ]);
    },
  );

  test('send prompt error is rendered as error message', () async {
    final controller = ChatController(
      client: FakeAgentClient(promptError: Exception('prompt failed')),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    await controller.newSession();
    await controller.sendPrompt('Hi');
    await pumpEventQueue(times: 4);

    expect(controller.status, app_state.ConnectionStatus.error);
    expect(controller.lastError, contains('prompt failed'));
    expect(controller.messages.last.role, ChatMessageRole.error);
  });

  test('send prompt error events finish streaming immediately', () async {
    final controller = ChatController(
      client: _OpenErrorEventAgentClient(),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    await controller.newSession();
    await controller.sendPrompt('Hi');
    await pumpEventQueue();

    expect(controller.status, app_state.ConnectionStatus.error);
    expect(controller.isStreaming, isFalse);
    expect(controller.lastError, contains('agent event failed'));
    expect(controller.messages.map((message) => message.role), [
      ChatMessageRole.user,
      ChatMessageRole.error,
    ]);
  });

  test('send prompt setup failures finish streaming with an error', () async {
    final controller = ChatController(
      client: _ThrowingPromptAgentClient(),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    await controller.newSession();
    await controller.sendPrompt('Hi');

    expect(controller.isStreaming, isFalse);
    expect(controller.status, app_state.ConnectionStatus.error);
    expect(controller.lastError, contains('prompt setup failed'));
    expect(controller.messages.map((message) => message.role), [
      ChatMessageRole.user,
      ChatMessageRole.error,
    ]);
  });

  test('stop cancels streaming', () async {
    final fake = FakeAgentClient(chunkDelay: const Duration(milliseconds: 50));
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    await controller.newSession();
    await controller.sendPrompt('Hi');
    expect(controller.isStreaming, isTrue);

    await controller.stop();

    expect(fake.cancelled, isTrue);
    expect(controller.isStreaming, isFalse);
    expect(controller.status, app_state.ConnectionStatus.sessionReady);
  });

  test('stop still finishes streaming when cancel fails', () async {
    final fake = FakeAgentClient(
      chunkDelay: const Duration(milliseconds: 50),
      cancelError: Exception('cancel failed'),
    );
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    await controller.newSession();
    await controller.sendPrompt('Hi');
    expect(controller.isStreaming, isTrue);

    await controller.stop();

    expect(controller.isStreaming, isFalse);
    expect(controller.status, app_state.ConnectionStatus.sessionReady);
    expect(controller.lastError, contains('cancel failed'));
  });
}

class _AuthRequiredError {
  const _AuthRequiredError();

  int get code => -32001;

  String get message => 'Authentication is required.';

  Map<String, Object?> get data => const <String, Object?>{
    'code': 'auth_required',
    'message': 'Sign in before creating a session.',
  };

  @override
  String toString() => 'JSON-RPC error -32001';
}

class _OmittingConfigOptionsAgentClient extends FakeAgentClient {
  @override
  Future<List<AcpConfigOption>> setConfigOption({
    required String sessionId,
    required String configId,
    required Object value,
  }) async {
    await super.setConfigOption(
      sessionId: sessionId,
      configId: configId,
      value: value,
    );
    return const <AcpConfigOption>[];
  }
}

class _FailingReconnectAgentClient extends FakeAgentClient {
  int _connectAttempts = 0;

  @override
  Future<void> connect() async {
    _connectAttempts += 1;
    if (_connectAttempts == 1) {
      await super.connect();
      return;
    }
    connected = false;
    throw Exception('connection dropped');
  }
}

class _ReusedSessionSetupPermissionAgentClient extends FakeAgentClient {
  int _createSessionCount = 0;

  @override
  Future<AgentSession> createSession({required String cwd}) async {
    if (!connected) {
      throw StateError('Fake client is not connected.');
    }

    _createSessionCount += 1;
    const sessionId = 'reused-session';
    if (_createSessionCount > 1) {
      emitPermissionRequest(
        AcpPermissionRequest(
          id: 'permission-reused-$_createSessionCount',
          title: 'Run command',
          rationale: 'Requested during session setup',
          sessionId: sessionId,
          toolName: 'terminal',
          options: const ['Allow', 'Deny'],
          requestedAt: DateTime(2026, 5, 31, 12),
        ),
      );
      await Future<void>.delayed(Duration.zero);
    }

    return AgentSession(
      id: sessionId,
      cwd: cwd,
      createdAt: DateTime(2026, 5, 28, 12),
    );
  }
}

class _FailingResumeAgentClient extends FakeAgentClient {
  _FailingResumeAgentClient({super.createSessionEvents});

  @override
  Future<List<AgentEvent>> resumeSession({
    required String sessionId,
    required String cwd,
  }) async {
    lastResumeCwd = cwd;
    throw StateError('resume failed');
  }
}

class _ConfigOptionUpdateAgentClient extends FakeAgentClient {
  _ConfigOptionUpdateAgentClient()
    : super(sessionSettings: _settingsWithMode('ask'));

  @override
  Stream<AgentEvent> sendPrompt({
    required String sessionId,
    required String prompt,
    List<PromptAttachment> attachments = const <PromptAttachment>[],
  }) async* {
    yield AgentEvent(
      type: AgentEventType.status,
      text: 'Session config options updated.',
      metadata: const <String, Object?>{
        'kind': 'config_option_update',
        'configOptions': <AcpConfigOption>[
          AcpConfigOption(
            id: 'model',
            name: 'Model',
            type: 'select',
            currentValue: 'gpt-5',
            category: 'model',
            options: [AcpConfigOptionChoice(value: 'gpt-5', name: 'GPT-5')],
          ),
        ],
      },
    );
    yield AgentEvent(
      type: AgentEventType.agentTextDone,
      text: '',
      timestamp: DateTime(2026, 5, 28, 12),
    );
  }
}

class _FailingDisposeAgentClient extends FakeAgentClient {
  @override
  Future<void> dispose() async {
    await super.dispose();
    throw StateError('dispose failed');
  }
}

class _DelayedPermissionResponseAgentClient extends FakeAgentClient {
  final Completer<void> responseStarted = Completer<void>();
  final Completer<void> allowResponse = Completer<void>();
  int permissionResponseCount = 0;

  @override
  Future<void> respondToPermissionRequest({
    required String id,
    required AcpPermissionDecision decision,
  }) async {
    permissionResponseCount += 1;
    if (!responseStarted.isCompleted) {
      responseStarted.complete();
    }
    await allowResponse.future;
    await super.respondToPermissionRequest(id: id, decision: decision);
  }
}

class _CountingPermissionResponseAgentClient extends FakeAgentClient {
  int permissionResponseCount = 0;

  @override
  Future<void> respondToPermissionRequest({
    required String id,
    required AcpPermissionDecision decision,
  }) async {
    permissionResponseCount += 1;
    await super.respondToPermissionRequest(id: id, decision: decision);
  }
}

class _ToolCallChunkAgentClient extends FakeAgentClient {
  @override
  Stream<AgentEvent> sendPrompt({
    required String sessionId,
    required String prompt,
    List<PromptAttachment> attachments = const <PromptAttachment>[],
  }) async* {
    yield AgentEvent(
      type: AgentEventType.toolCall,
      text: 'Bash',
      metadata: const <String, Object?>{
        'kind': 'tool',
        'toolCallId': 'call-1',
        'title': 'Bash',
        'status': 'pending',
      },
    );
    yield AgentEvent(
      type: AgentEventType.toolCall,
      text: 'Bash',
      metadata: const <String, Object?>{
        'kind': 'tool',
        'toolCallId': 'call-1',
        'title': 'Bash',
        'status': 'in_progress',
        'rawInput': '{"command"',
      },
    );
    yield AgentEvent(
      type: AgentEventType.toolCall,
      text: 'Bash',
      metadata: const <String, Object?>{
        'kind': 'tool',
        'toolCallId': 'call-1',
        'title': 'Bash',
        'status': 'completed',
        'rawInput': {'command': 'echo hi'},
        'rawOutput': 'hi',
      },
    );
    yield AgentEvent(
      type: AgentEventType.agentTextDone,
      text: '',
      timestamp: DateTime(2026, 5, 28, 12),
    );
  }
}

class _AliasToolCallChunkAgentClient extends FakeAgentClient {
  @override
  Stream<AgentEvent> sendPrompt({
    required String sessionId,
    required String prompt,
    List<PromptAttachment> attachments = const <PromptAttachment>[],
  }) async* {
    yield AgentEvent(
      type: AgentEventType.toolCall,
      text: 'Bash',
      metadata: const <String, Object?>{
        'kind': 'tool',
        'id': 'call-1',
        'title': 'Bash',
        'status': 'pending',
      },
    );
    yield AgentEvent(
      type: AgentEventType.toolCall,
      text: 'Bash',
      metadata: const <String, Object?>{
        'kind': 'tool',
        'callId': 'call-1',
        'title': 'Bash',
        'status': 'completed',
        'rawOutput': 'hi',
      },
    );
    yield AgentEvent(
      type: AgentEventType.agentTextDone,
      text: '',
      timestamp: DateTime(2026, 5, 28, 12),
    );
  }
}

class _SnakeCaseToolCallChunkAgentClient extends FakeAgentClient {
  @override
  Stream<AgentEvent> sendPrompt({
    required String sessionId,
    required String prompt,
    List<PromptAttachment> attachments = const <PromptAttachment>[],
  }) async* {
    yield AgentEvent(
      type: AgentEventType.toolCall,
      text: 'Bash',
      metadata: const <String, Object?>{
        'kind': 'tool',
        'tool_call_id': 'call-1',
        'title': 'Bash',
        'status': 'pending',
      },
    );
    yield AgentEvent(
      type: AgentEventType.toolCall,
      text: 'Bash',
      metadata: const <String, Object?>{
        'kind': 'tool',
        'tool_call_id': 'call-1',
        'title': 'Bash',
        'status': 'completed',
        'raw_output': 'hi',
      },
    );
    yield AgentEvent(
      type: AgentEventType.agentTextDone,
      text: '',
      timestamp: DateTime(2026, 5, 28, 12),
    );
  }
}

class _ThrowingPromptAgentClient extends FakeAgentClient {
  @override
  Stream<AgentEvent> sendPrompt({
    required String sessionId,
    required String prompt,
    List<PromptAttachment> attachments = const <PromptAttachment>[],
  }) {
    throw StateError('prompt setup failed');
  }
}

class _FakePermissionReviewer extends AcpPermissionReviewer {
  _FakePermissionReviewer(this.result);

  final AcpPermissionReviewResult result;
  final List<AcpPermissionRequest> requests = <AcpPermissionRequest>[];
  final List<String> workspaceRoots = <String>[];
  final List<String?> models = <String?>[];

  @override
  Future<AcpPermissionReviewResult?> review(
    AcpPermissionRequest request, {
    required String workspaceRoot,
    String? model,
  }) async {
    requests.add(request);
    workspaceRoots.add(workspaceRoot);
    models.add(model);
    return result;
  }
}

class _DelayedPermissionReviewer extends AcpPermissionReviewer {
  final Completer<AcpPermissionReviewResult?> _result =
      Completer<AcpPermissionReviewResult?>();
  final List<AcpPermissionRequest> requests = <AcpPermissionRequest>[];

  void complete(AcpPermissionReviewResult? result) {
    _result.complete(result);
  }

  @override
  Future<AcpPermissionReviewResult?> review(
    AcpPermissionRequest request, {
    required String workspaceRoot,
    String? model,
  }) {
    requests.add(request);
    return _result.future;
  }
}

class _OpenErrorEventAgentClient extends FakeAgentClient {
  @override
  Stream<AgentEvent> sendPrompt({
    required String sessionId,
    required String prompt,
    List<PromptAttachment> attachments = const <PromptAttachment>[],
  }) {
    late final StreamController<AgentEvent> controller;
    controller = StreamController<AgentEvent>(
      onListen: () {
        controller.add(
          AgentEvent(
            type: AgentEventType.error,
            text: 'agent event failed',
            timestamp: DateTime(2026, 5, 28, 12),
          ),
        );
      },
      onCancel: () => controller.close(),
    );
    return controller.stream;
  }
}

class _DelayedForkAgentClient extends FakeAgentClient {
  final Completer<void> forkStarted = Completer<void>();
  final Completer<void> allowFork = Completer<void>();

  @override
  Future<AgentSession> forkSession({
    required String sessionId,
    required String cwd,
  }) async {
    if (!forkStarted.isCompleted) {
      forkStarted.complete();
    }
    await allowFork.future;
    return super.forkSession(sessionId: sessionId, cwd: cwd);
  }
}

class _DelayedSettingsMutationAgentClient extends FakeAgentClient {
  _DelayedSettingsMutationAgentClient({super.sessionSettings});

  final Completer<void> modeStarted = Completer<void>();
  final Completer<void> allowMode = Completer<void>();
  final Completer<void> configStarted = Completer<void>();
  final Completer<void> allowConfig = Completer<void>();

  @override
  Future<bool> setSessionMode({
    required String sessionId,
    required String modeId,
  }) async {
    if (!modeStarted.isCompleted) {
      modeStarted.complete();
    }
    await allowMode.future;
    return super.setSessionMode(sessionId: sessionId, modeId: modeId);
  }

  @override
  Future<List<AcpConfigOption>> setConfigOption({
    required String sessionId,
    required String configId,
    required Object value,
  }) async {
    if (!configStarted.isCompleted) {
      configStarted.complete();
    }
    await allowConfig.future;
    return super.setConfigOption(
      sessionId: sessionId,
      configId: configId,
      value: value,
    );
  }
}

class _StaleSessionSettingsAgentClient extends FakeAgentClient {
  final Completer<void> staleRefreshStarted = Completer<void>();
  final Completer<void> allowStaleRefresh = Completer<void>();
  int _originalSessionSettingsCalls = 0;

  @override
  Future<AcpSessionSettings> sessionSettings(String sessionId) async {
    if (sessionId == 'fake-session-1') {
      _originalSessionSettingsCalls += 1;
      if (_originalSessionSettingsCalls == 1) {
        return _settingsWithMode('ask');
      }
      if (!staleRefreshStarted.isCompleted) {
        staleRefreshStarted.complete();
      }
      await allowStaleRefresh.future;
      return _settingsWithMode('ask');
    }
    if (sessionId.startsWith('fake-fork-')) {
      return _settingsWithMode('edit');
    }
    return super.sessionSettings(sessionId);
  }
}

AcpSessionSettings _settingsWithMode(String modeId) {
  return AcpSessionSettings(
    modes: AcpSessionModeInfo(
      currentModeId: modeId,
      availableModes: const [
        AcpSessionMode(id: 'ask', name: 'Ask'),
        AcpSessionMode(id: 'edit', name: 'Edit'),
      ],
    ),
  );
}
