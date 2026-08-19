import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/acp_permission_request.dart';
import 'package:ianvs_acp/acp/acp_permission_reviewer.dart';
import 'package:ianvs_acp/acp/acp_session_settings.dart';
import 'package:ianvs_acp/acp/agent_session.dart';
import 'package:ianvs_acp/acp/fake_agent_client.dart';
import 'package:ianvs_acp/config/acp_client_config.dart';
import 'package:ianvs_acp/state/chat_controller.dart';
import 'package:ianvs_acp/ui/components/runtime_inventory_dialog.dart';

void main() {
  testWidgets('runtime inventory is exact, drift-aware, and secret-safe', (
    tester,
  ) async {
    const reviewMcp = McpServerConfig(
      raw: <String, dynamic>{
        'name': 'permission-reviewer',
        'type': 'stdio',
        'command': 'review-agent',
        'env': <String, String>{'TOKEN': 'raw-review-secret'},
      },
      envRefs: <String, String>{'TOKEN': 'keychain://review-token'},
    );
    const agent = AgentServerConfig(
      name: 'Remote Agent',
      type: 'http',
      url:
          'https://alice:password@agent.example/acp?token=query-secret#fragment',
      env: <String, String>{'API_KEY': 'raw-agent-secret'},
      envRefs: <String, String>{'API_KEY': 'keychain://agent-key'},
      permissionReviewAgent: AcpPermissionReviewAgentConfig(
        enabled: true,
        mcpServer: reviewMcp,
        model: 'review-model',
      ),
    );
    const repositoryMcp = McpServerConfig(
      raw: <String, dynamic>{
        'name': 'repository',
        'type': 'stdio',
        'command': 'repo-mcp',
        'env': <String, String>{'TOKEN': 'raw-mcp-secret'},
      },
      envRefs: <String, String>{'TOKEN': 'keychain://repo-token'},
      secretRefsResolved: false,
    );
    const configuredTemplate = SessionTemplateConfig(
      id: 'review',
      name: 'Code review',
      version: 3,
    );
    const runtimeConfig = AcpClientConfig(
      activeAgentServer: agent,
      agentServers: <AgentServerConfig>[agent],
      mcpServers: <McpServerConfig>[repositoryMcp],
      additionalDirectories: <String>['/workspace/shared'],
      sessionTemplates: <SessionTemplateConfig>[configuredTemplate],
    );
    final controller = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace/app',
      agentName: agent.name,
      additionalDirectories: runtimeConfig.additionalDirectories,
    );
    addTearDown(controller.dispose);
    expect(
      await controller.newSession(
        template: const SessionTemplateConfig(
          id: 'review',
          name: 'Code review',
          version: 2,
        ),
      ),
      isTrue,
    );

    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RuntimeInventoryDialog(
            controller: controller,
            runtimeConfig: runtimeConfig,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Runtime Inventory'), findsOneWidget);
    expect(find.text('Agent runtime'), findsOneWidget);
    expect(find.text('Session recipe'), findsOneWidget);
    expect(find.text('MCP and client providers'), findsOneWidget);
    expect(find.text('Negotiated capabilities'), findsOneWidget);
    expect(find.text('Credential inventory'), findsOneWidget);
    expect(find.textContaining('https://agent.example'), findsOneWidget);
    expect(find.textContaining('https://agent.example/acp'), findsNothing);
    expect(find.text('repository (stdio)'), findsOneWidget);
    expect(find.text('permission-reviewer · review-model'), findsOneWidget);
    expect(
      find.text('redacted (inventory shows references only)'),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('runtime-inventory-degradations')),
      findsOneWidget,
    );
    expect(
      find.text(
        '• Session used review@2; configured version is 3. Base runtime is in use.',
      ),
      findsOneWidget,
    );

    for (final secret in <String>[
      'password',
      'query-secret',
      'raw-agent-secret',
      'raw-mcp-secret',
      'raw-review-secret',
      'keychain://agent-key',
      'keychain://repo-token',
      'keychain://review-token',
    ]) {
      expect(find.textContaining(secret), findsNothing, reason: secret);
    }
  });

  testWidgets('runtime inventory uses active roots and refreshes live', (
    tester,
  ) async {
    const runtimeConfig = AcpClientConfig(
      additionalDirectories: <String>['/workspace/configured'],
    );
    final controller = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace/app',
      additionalDirectories: runtimeConfig.additionalDirectories,
    );
    addTearDown(controller.dispose);
    controller.currentSession = AgentSession(
      id: 'restored-session',
      cwd: '/workspace/app',
      createdAt: DateTime(2026),
      additionalDirectories: const <String>['/workspace/session-only'],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RuntimeInventoryDialog(
            controller: controller,
            runtimeConfig: runtimeConfig,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('/workspace/session-only'), findsOneWidget);
    expect(find.text('/workspace/configured'), findsNothing);
    expect(find.text('restored-session'), findsOneWidget);
    expect(find.text('manual confirmation'), findsOneWidget);

    controller.setToolCallExecutionPolicy(
      AcpToolCallExecutionPolicy.fullAccess,
    );
    await tester.pump();

    expect(find.text('full access'), findsOneWidget);
    expect(find.text('manual confirmation'), findsNothing);
  });

  testWidgets(
    'runtime inventory honors empty session roots and actual fallback reviewer',
    (tester) async {
      const runtimeConfig = AcpClientConfig(
        additionalDirectories: <String>['/workspace/configured'],
      );
      final controller = ChatController(
        client: FakeAgentClient(),
        cwd: '/workspace/app',
        additionalDirectories: runtimeConfig.additionalDirectories,
        permissionReviewer: _StubPermissionReviewer(),
      );
      addTearDown(controller.dispose);
      controller.currentSession = AgentSession(
        id: 'empty-roots',
        cwd: '/workspace/app',
        createdAt: DateTime(2026),
        additionalDirectories: const <String>[],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RuntimeInventoryDialog(
              controller: controller,
              runtimeConfig: runtimeConfig,
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('/workspace/configured'), findsNothing);
      expect(find.text('0 MCP · 0 extra roots · disconnected'), findsOneWidget);
      expect(find.text('Codex (active-Agent fallback)'), findsOneWidget);
    },
  );

  testWidgets('runtime inventory reports Agent template fallback', (
    tester,
  ) async {
    final runtimeConfig = AcpClientConfig.fromJson(<String, Object?>{
      'default_agent_server': 'Agent A',
      'agent_servers': <String, Object?>{
        'Agent A': <String, Object?>{'type': 'custom', 'command': 'agent-a'},
        'Agent B': <String, Object?>{'type': 'custom', 'command': 'agent-b'},
      },
      'session_templates': <String, Object?>{
        'review': <String, Object?>{
          'name': 'Review',
          'version': 1,
          'agent_server': 'Agent B',
        },
      },
    });
    final controller = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace/app',
      agentName: 'Agent A',
    );
    addTearDown(controller.dispose);
    controller.currentSession = AgentSession(
      id: 'agent-drift',
      cwd: '/workspace/app',
      createdAt: DateTime(2026),
      agentName: runtimeConfig.activeAgentServer!.persistenceIdentity,
      sessionTemplateId: 'review',
      sessionTemplateVersion: 1,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RuntimeInventoryDialog(
            controller: controller,
            runtimeConfig: runtimeConfig,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('review@1 (base runtime fallback)'), findsOneWidget);
    expect(
      find.textContaining('now targets a different Agent'),
      findsOneWidget,
    );
  });

  testWidgets(
    'runtime inventory detects same-Agent template runtime fallback',
    (tester) async {
      final runtimeConfig = AcpClientConfig.fromJson(<String, Object?>{
        'default_agent_server': 'Codex',
        'agent_servers': <String, Object?>{
          'Codex': <String, Object?>{'type': 'custom', 'command': 'codex-acp'},
        },
        'mcp_servers': <Object?>[
          <String, Object?>{'name': 'repo', 'command': 'repo-mcp'},
        ],
        'session_templates': <String, Object?>{
          'strict': <String, Object?>{
            'name': 'Strict',
            'version': 1,
            'mcp_servers': <String>[],
          },
        },
      });
      final controller = ChatController(
        client: FakeAgentClient(),
        cwd: '/workspace/app',
        agentName: 'Codex',
      );
      addTearDown(controller.dispose);
      controller.currentSession = AgentSession(
        id: 'same-agent-fallback',
        cwd: '/workspace/app',
        createdAt: DateTime(2026),
        agentName: runtimeConfig.activeAgentServer!.persistenceIdentity,
        sessionTemplateId: 'strict',
        sessionTemplateVersion: 1,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RuntimeInventoryDialog(
              controller: controller,
              runtimeConfig: runtimeConfig,
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('strict@1 (base runtime fallback)'), findsOneWidget);
      expect(
        find.textContaining('active runtime does not match'),
        findsOneWidget,
      );
    },
  );

  testWidgets('runtime inventory compares restored roots with the template', (
    tester,
  ) async {
    final config = AcpClientConfig.fromJson(<String, Object?>{
      'additional_directories': <String>['/workspace/new-root'],
      'session_templates': <String, Object?>{
        'review': <String, Object?>{'name': 'Review', 'version': 1},
      },
    });
    final controller = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace/app',
    );
    addTearDown(controller.dispose);
    controller.currentSession = AgentSession(
      id: 'root-drift',
      cwd: '/workspace/app',
      createdAt: DateTime(2026),
      agentName: config.agentName,
      additionalDirectories: const <String>['/workspace/old-root'],
      sessionTemplateId: 'review',
      sessionTemplateVersion: 1,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RuntimeInventoryDialog(
            controller: controller,
            runtimeConfig: config,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('review@1 (base runtime fallback)'), findsOneWidget);
    expect(find.text('/workspace/old-root'), findsOneWidget);
    expect(
      find.textContaining('active runtime does not match'),
      findsOneWidget,
    );
  });

  testWidgets('runtime inventory reports template session setting drift', (
    tester,
  ) async {
    final baseConfig = AcpClientConfig.fromJson(<String, Object?>{
      'session_templates': <String, Object?>{
        'review': <String, Object?>{
          'name': 'Review',
          'version': 1,
          'mode': 'plan',
          'model': 'fast',
          'reasoning_effort': 'high',
        },
      },
    });
    final template = baseConfig.sessionTemplateNamed('review')!;
    final runtimeConfig = baseConfig.forSessionTemplate(template);
    final controller = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace/app',
    );
    addTearDown(controller.dispose);
    controller.currentSession = AgentSession(
      id: 'settings-drift',
      cwd: '/workspace/app',
      createdAt: DateTime.utc(2026, 8, 19),
      sessionTemplateId: 'review',
      sessionTemplateVersion: 1,
    );
    controller.sessionSettings = const AcpSessionSettings(
      modes: AcpSessionModeInfo(
        currentModeId: 'default',
        availableModes: <AcpSessionMode>[
          AcpSessionMode(id: 'default', name: 'Default'),
          AcpSessionMode(id: 'plan', name: 'Plan'),
        ],
      ),
      configOptions: <AcpConfigOption>[
        AcpConfigOption(
          id: 'model',
          name: 'Model',
          type: 'select',
          currentValue: 'slow',
          options: <AcpConfigOptionChoice>[
            AcpConfigOptionChoice(value: 'slow', name: 'Slow'),
            AcpConfigOptionChoice(value: 'fast', name: 'Fast'),
          ],
        ),
        AcpConfigOption(
          id: 'reasoning_effort',
          name: 'Reasoning effort',
          type: 'select',
          currentValue: 'low',
          options: <AcpConfigOptionChoice>[
            AcpConfigOptionChoice(value: 'low', name: 'Low'),
            AcpConfigOptionChoice(value: 'high', name: 'High'),
          ],
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RuntimeInventoryDialog(
            controller: controller,
            runtimeConfig: runtimeConfig,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.textContaining(
        'requested mode, model, reasoning effort do not match',
      ),
      findsOneWidget,
    );

    controller.sessionSettings = const AcpSessionSettings(
      modes: AcpSessionModeInfo(
        currentModeId: 'plan',
        availableModes: <AcpSessionMode>[
          AcpSessionMode(id: 'plan', name: 'Plan'),
        ],
      ),
      configOptions: <AcpConfigOption>[
        AcpConfigOption(
          id: 'model',
          name: 'Model',
          type: 'select',
          currentValue: 'fast',
          options: <AcpConfigOptionChoice>[
            AcpConfigOptionChoice(value: 'fast', name: 'Fast'),
          ],
        ),
        AcpConfigOption(
          id: 'reasoning_effort',
          name: 'Reasoning effort',
          type: 'select',
          currentValue: 'high',
          options: <AcpConfigOptionChoice>[
            AcpConfigOptionChoice(value: 'high', name: 'High'),
          ],
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RuntimeInventoryDialog(
            controller: controller,
            runtimeConfig: runtimeConfig,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.textContaining(
        'requested mode, model, reasoning effort do not match',
      ),
      findsNothing,
    );
    expect(find.text('review@1 · Review'), findsOneWidget);
  });

  testWidgets('runtime inventory bounds long values and item lists', (
    tester,
  ) async {
    final longSessionId = 'session-${'x' * 10000}';
    final directories = <String>[
      for (var index = 0; index < 100; index += 1)
        '/workspace/$index-${'y' * 1000}',
    ];
    final controller = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace/app',
    );
    addTearDown(controller.dispose);
    controller.currentSession = AgentSession(
      id: longSessionId,
      cwd: '/workspace/app',
      createdAt: DateTime(2026),
      additionalDirectories: directories,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RuntimeInventoryDialog(
            controller: controller,
            runtimeConfig: const AcpClientConfig(),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text(longSessionId), findsNothing);
    expect(find.textContaining('[truncated]'), findsWidgets);
    expect(find.textContaining('additional items truncated'), findsOneWidget);
  });
}

final class _StubPermissionReviewer extends AcpPermissionReviewer {
  @override
  Future<AcpPermissionReviewResult?> review(
    AcpPermissionRequest request, {
    required String workspaceRoot,
    List<String> additionalDirectories = const <String>[],
    String? model,
  }) async => null;
}
