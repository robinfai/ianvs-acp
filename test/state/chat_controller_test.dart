import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/acp_permission_request.dart';
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
    expect(controller.sessionSettings.modes.currentModeId, 'ask');
  });

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
          sessionId: 'session-1',
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

  test('set session mode updates ACP session settings', () async {
    final fake = FakeAgentClient();
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    await controller.newSession();
    await controller.setSessionMode('edit');

    expect(fake.lastSetModeId, 'edit');
    expect(controller.sessionSettings.modes.currentModeId, 'edit');
    expect(controller.lastError, isNull);
  });

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
