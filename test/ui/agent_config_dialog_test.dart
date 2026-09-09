import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/acp_permission_request.dart';
import 'package:ianvs_acp/acp/acp_session_settings.dart';
import 'package:ianvs_acp/config/acp_client_config.dart';
import 'package:ianvs_acp/config/assistant_agent_config.dart';
import 'package:ianvs_acp/storage/sqlite_storage_config.dart';
import 'package:ianvs_acp/ui/components/agent_config_dialog.dart';

void main() {
  testWidgets('renders the settings workspace without exposing secrets', (
    tester,
  ) async {
    await _pump(
      tester,
      AgentConfigDialog(
        configPath: '/Users/example/.config/ianvs-acp/settings.json',
        activeAgentName: 'Codex',
        defaultAgentName: 'Kimi',
        additionalDirectories: const ['/workspace/a', '/workspace/b'],
        clientProviders: const AcpClientProviderConfig(
          filesystem: AcpFilesystemProviderConfig(readTextFile: true),
          terminal: AcpTerminalProviderConfig(enabled: true),
          permissions: AcpPermissionProviderConfig(
            reviewAgent: AcpPermissionReviewAgentConfig(
              enabled: true,
              mcpServerName: 'permission-reviewer',
              model: 'review-model',
            ),
            trustRules: [
              AcpPermissionTrustRule(
                toolName: 'read_text_file',
                toolKind: 'read',
                decision: AcpPermissionDecision.allow,
              ),
            ],
          ),
        ),
        mcpServers: const [
          McpServerConfig(
            raw: {
              'name': 'api-tools',
              'type': 'http',
              'url': 'https://api.example.com/mcp',
              'headers': [
                {'name': 'X-MCP-Token', 'value': 'secret'},
              ],
            },
          ),
          McpServerConfig(
            raw: {'name': 'nested-tools', 'type': 'acp', 'id': 'nested-agent'},
          ),
        ],
        agentServers: const [
          AgentServerConfig(
            name: 'Kimi',
            type: 'custom',
            command: '/usr/local/bin/kimi',
          ),
          _codex,
          AgentServerConfig(
            name: 'Remote',
            type: 'http',
            url: 'https://agent.example.com/acp',
            headers: {'Authorization': 'Bearer test-token'},
          ),
        ],
        onSaveConfig: (config) async => config,
      ),
    );

    for (final section in [
      'agents',
      'tools',
      'permissions',
      'assistant',
      'storage',
    ]) {
      expect(find.byKey(Key('settings-section-$section')), findsOneWidget);
    }
    expect(find.byKey(const Key('settings-agent-Codex')), findsOneWidget);
    expect(find.byKey(const Key('settings-agent-Remote')), findsOneWidget);
    expect(find.byKey(const Key('settings-save')), findsOneWidget);
    expect(find.text('Save Agent'), findsNothing);
    expect(find.text('Save MCP Server'), findsNothing);
    expect(find.textContaining('ready to add'), findsNothing);

    await tester.tap(find.byKey(const Key('settings-agent-Remote')));
    await tester.pump();
    expect(find.byKey(const Key('agent-url-field')), findsOneWidget);
    expect(find.byKey(const Key('agent-command-field')), findsNothing);
    expect(find.textContaining('远程 ACP 当前不可用'), findsOneWidget);
    expect(_editable(tester, 'agent-header-value-0-field').obscureText, isTrue);

    await _section(tester, 'tools');
    expect(find.byKey(const Key('settings-mcp-api-tools')), findsOneWidget);
    expect(find.byKey(const Key('settings-mcp-nested-tools')), findsOneWidget);
    await tester.tap(find.byKey(const Key('settings-mcp-api-tools')));
    await tester.pump();
    expect(_editable(tester, 'mcp-header-value-0-field').obscureText, isTrue);

    await _section(tester, 'permissions');
    expect(find.text('read_text_file / read -> Allow'), findsOneWidget);
    expect(find.byKey(const Key('review-model-field')), findsOneWidget);
    await _section(tester, 'storage');
    expect(
      find.text('/Users/example/.config/ianvs-acp/settings.json'),
      findsOneWidget,
    );
  });

  testWidgets('keeps cross-section drafts and saves them once', (tester) async {
    AcpClientConfig? saved;
    await _pump(
      tester,
      AgentConfigDialog(
        configPath: '/tmp/settings.json',
        activeAgentName: 'Codex',
        storage: const SqliteStorageConfig(maxSizeGb: 50, retentionDays: 30),
        agentServers: const [_codex],
        mcpServers: const [
          McpServerConfig(raw: {'name': 'tools', 'command': '/bin/tools'}),
        ],
        onSaveConfig: (config) async {
          saved = config;
          return config;
        },
      ),
    );
    await tester.enterText(
      find.byKey(const Key('agent-command-field')),
      '/bin/next',
    );
    await _section(tester, 'tools');
    await tester.tap(find.byKey(const Key('settings-mcp-tools')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('mcp-command-field')),
      '/bin/tools-next',
    );
    await _section(tester, 'storage');
    await tester.enterText(
      find.byKey(const Key('storage-max-size-gb-field')),
      '75',
    );
    await tester.enterText(
      find.byKey(const Key('storage-retention-days-field')),
      '60',
    );
    await _section(tester, 'agents');
    expect(_text(tester, 'agent-command-field'), '/bin/next');
    await _section(tester, 'tools');
    expect(_text(tester, 'mcp-command-field'), '/bin/tools-next');
    expect(find.text('有未保存的更改'), findsOneWidget);
    await _save(tester);
    expect(saved?.agentServers.single.command, '/bin/next');
    expect(saved?.mcpServers.single.command, '/bin/tools-next');
    expect(saved?.storage.maxSizeGb, 75);
    expect(saved?.storage.retentionDays, 60);
    expect(find.text('更改已保存'), findsOneWidget);
  });

  testWidgets('Assistant profile loads, validates and saves its model', (
    tester,
  ) async {
    AcpClientConfig? saved;
    AssistantAgentConfig? validated;
    String? modelsFor;
    await _pump(
      tester,
      AgentConfigDialog(
        configPath: '/tmp/settings.json',
        activeAgentName: 'Codex',
        agentServers: const [
          _codex,
          AgentServerConfig(name: 'Pi', type: 'custom', command: '/bin/pi'),
        ],
        onLoadAssistantAgentModels: (name) async {
          modelsFor = name;
          return _modelOption('v2', 'Model V2', extra: ('v3', 'Model V3'));
        },
        onValidateAssistantAgent: (config) async => validated = config,
        onSaveConfig: (config) async {
          saved = config;
          return config;
        },
      ),
    );
    await _section(tester, 'assistant');
    expect(find.byKey(const Key('assistant-agent-name-field')), findsNothing);
    _switch(tester, 'assistant-agent-enabled-switch').onChanged?.call(true);
    await tester.pump();
    _dropdown<String>(
      tester,
      'assistant-agent-name-field',
    ).onChanged?.call('Pi');
    await tester.pump();
    await tester.pump();
    expect(modelsFor, 'Pi');
    _dropdown<String>(
      tester,
      'assistant-agent-model-field',
    ).onChanged?.call('v3');
    await tester.enterText(
      find.byKey(const Key('assistant-title-character-limit-field')),
      '32',
    );
    tester
        .widget<OutlinedButton>(
          find.byKey(const Key('assistant-agent-validate-button')),
        )
        .onPressed
        ?.call();
    await tester.pump();
    expect(validated?.agentName, 'Pi');
    expect(validated?.model, 'v3');
    await _save(tester);
    expect(saved?.assistantAgent.enabled, isTrue);
    expect(saved?.assistantAgent.agentName, 'Pi');
    expect(saved?.assistantAgent.model, 'v3');
    expect(saved?.assistantAgent.fallbackTitleCharacters, 32);
  });

  testWidgets('Assistant ignores stale model results after Agent switch', (
    tester,
  ) async {
    final codex = Completer<AcpConfigOption?>();
    final pi = Completer<AcpConfigOption?>();
    await _pump(
      tester,
      AgentConfigDialog(
        activeAgentName: 'Codex',
        agentServers: const [
          _codex,
          AgentServerConfig(name: 'Pi', type: 'custom', command: '/bin/pi'),
        ],
        onLoadAssistantAgentModels: (name) =>
            name == 'Codex' ? codex.future : pi.future,
      ),
    );
    await _section(tester, 'assistant');
    _switch(tester, 'assistant-agent-enabled-switch').onChanged?.call(true);
    await tester.pump();
    _dropdown<String>(
      tester,
      'assistant-agent-name-field',
    ).onChanged?.call('Codex');
    await tester.pump();
    _dropdown<String>(
      tester,
      'assistant-agent-name-field',
    ).onChanged?.call('Pi');
    await tester.pump();
    pi.complete(_modelOption('pi', 'Pi Model'));
    await tester.pump();
    codex.complete(_modelOption('codex', 'Codex Model'));
    await tester.pump();
    final labels = _dropdownButton<String>(
      tester,
      'assistant-agent-model-field',
    ).items?.map((item) => (item.child as Text).data);
    expect(labels, contains('Pi Model'));
    expect(labels, isNot(contains('Codex Model')));
  });

  testWidgets('no-op and runtime busy states disable the only save', (
    tester,
  ) async {
    final busy = ValueNotifier<bool>(false);
    addTearDown(busy.dispose);
    await _pump(
      tester,
      AgentConfigDialog(
        configPath: '/tmp/settings.json',
        activeAgentName: 'Codex',
        agentServers: const [_codex],
        runtimeBusy: busy,
        onSaveConfig: (config) async => config,
      ),
    );
    expect(_saveButton(tester).onPressed, isNull);
    await tester.enterText(
      find.byKey(const Key('agent-command-field')),
      '/bin/changed',
    );
    await tester.pump();
    expect(_saveButton(tester).onPressed, isNotNull);
    busy.value = true;
    await tester.pump();
    expect(_saveButton(tester).onPressed, isNull);
    expect(find.textContaining('会话仍在运行或切换'), findsOneWidget);
  });

  testWidgets('read-only settings remain navigable while edits stay locked', (
    tester,
  ) async {
    await _pump(
      tester,
      const AgentConfigDialog(
        configPath: '/tmp/settings.json',
        activeAgentName: 'Codex',
        agentServers: [
          _codex,
          AgentServerConfig(
            name: 'Pi',
            type: 'custom',
            command: '/usr/local/bin/pi',
            cwd: '/workspace/pi-agent',
            args: [
              '--acp',
              '--profile',
              'read-only',
              '--log-level',
              'info',
              '--feature',
              'diagnostics',
            ],
            env: {
              'TOKEN': 'resolved-secret',
              'WORKSPACE': '/workspace/pi-agent',
              'PROFILE': 'read-only',
              'LOG_LEVEL': 'info',
              'CACHE_MODE': 'local',
              'TERM_MODE': 'separate',
              'FEATURES': 'diagnostics',
              'REGION': 'local',
            },
          ),
        ],
        mcpServers: [
          McpServerConfig(
            raw: {
              'name': 'tools',
              'command': '/usr/local/bin/tools',
              'args': ['--stdio'],
              'env': [
                {'name': 'TOKEN', 'value': 'resolved-secret'},
                {'name': 'WORKSPACE', 'value': '/workspace/tools'},
                {'name': 'PROFILE', 'value': 'read-only'},
                {'name': 'LOG_LEVEL', 'value': 'info'},
                {'name': 'CACHE_MODE', 'value': 'local'},
                {'name': 'TERM_MODE', 'value': 'separate'},
                {'name': 'FEATURES', 'value': 'diagnostics'},
                {'name': 'REGION', 'value': 'local'},
              ],
            },
          ),
        ],
      ),
    );

    expect(_saveButton(tester).onPressed, isNull);
    expect(find.textContaining('只读'), findsWidgets);
    expect(
      tester
          .widget<TextButton>(find.byKey(const Key('settings-add-agent')))
          .onPressed,
      isNull,
    );

    await tester.tap(find.byKey(const Key('settings-agent-Pi')));
    await tester.pump();
    expect(_text(tester, 'agent-name-field'), 'Pi');
    final agentScroll = find
        .ancestor(
          of: find.byKey(const Key('agent-cwd-field')),
          matching: find.byType(Scrollable),
        )
        .first;
    final before = tester.state<ScrollableState>(agentScroll).position.pixels;
    await tester.drag(agentScroll, const Offset(0, -260));
    await tester.pump();
    expect(
      tester.state<ScrollableState>(agentScroll).position.pixels,
      greaterThan(before),
    );
    await tester.ensureVisible(find.byKey(const Key('agent-cwd-field')));
    await tester.pump();
    expect(_text(tester, 'agent-cwd-field'), '/workspace/pi-agent');
    final agentAbsorb = find
        .ancestor(
          of: find.byKey(const Key('agent-command-field')),
          matching: find.byType(AbsorbPointer),
        )
        .first;
    expect(tester.widget<AbsorbPointer>(agentAbsorb).absorbing, isTrue);
    final agentMenu = find
        .ancestor(
          of: find.byTooltip('Agent 操作'),
          matching: find.byType(PopupMenuButton<String>),
        )
        .first;
    expect(tester.widget<PopupMenuButton<String>>(agentMenu).enabled, isFalse);

    await _section(tester, 'tools');
    expect(
      tester
          .widget<TextButton>(find.byKey(const Key('settings-add-mcp')))
          .onPressed,
      isNull,
    );
    await tester.tap(find.byKey(const Key('settings-mcp-tools')));
    await tester.pump();
    final mcpScroll = find
        .ancestor(
          of: find.byKey(const Key('mcp-env-value-7-field')),
          matching: find.byType(Scrollable),
        )
        .first;
    final mcpBefore = tester.state<ScrollableState>(mcpScroll).position.pixels;
    await tester.drag(mcpScroll, const Offset(0, -260));
    await tester.pump();
    expect(
      tester.state<ScrollableState>(mcpScroll).position.pixels,
      greaterThan(mcpBefore),
    );
    await tester.ensureVisible(find.byKey(const Key('mcp-env-value-7-field')));
    await tester.pump();
    expect(_text(tester, 'mcp-command-field'), '/usr/local/bin/tools');
    expect(_text(tester, 'mcp-env-value-7-field'), 'local');
    final mcpAbsorb = find
        .ancestor(
          of: find.byKey(const Key('mcp-command-field')),
          matching: find.byType(AbsorbPointer),
        )
        .first;
    expect(tester.widget<AbsorbPointer>(mcpAbsorb).absorbing, isTrue);
    final removeMcpButton = find
        .ancestor(
          of: find.byTooltip('移除此 MCP 连接'),
          matching: find.byType(IconButton),
        )
        .first;
    expect(tester.widget<IconButton>(removeMcpButton).onPressed, isNull);
  });

  testWidgets('failed save keeps the draft and can be retried', (tester) async {
    var calls = 0;
    await _pump(
      tester,
      AgentConfigDialog(
        configPath: '/tmp/settings.json',
        activeAgentName: 'Codex',
        agentServers: const [_codex],
        onSaveConfig: (config) async {
          calls += 1;
          if (calls == 1) throw StateError('disk unavailable');
          return config;
        },
      ),
    );
    await tester.enterText(
      find.byKey(const Key('agent-command-field')),
      '/bin/retry',
    );
    await _save(tester);
    expect(find.textContaining('disk unavailable'), findsOneWidget);
    expect(_text(tester, 'agent-command-field'), '/bin/retry');
    expect(_saveButton(tester).onPressed, isNotNull);
    await _save(tester);
    expect(calls, 2);
    expect(find.text('更改已保存'), findsOneWidget);
  });

  testWidgets('back and system pop stay blocked while save is pending', (
    tester,
  ) async {
    final pending = Completer<AcpClientConfig>();
    await _pump(
      tester,
      AgentConfigDialog(
        configPath: '/tmp/settings.json',
        activeAgentName: 'Codex',
        agentServers: const [_codex],
        onSaveConfig: (_) => pending.future,
      ),
    );
    await tester.enterText(
      find.byKey(const Key('agent-command-field')),
      '/bin/pending',
    );
    await _save(tester);
    expect(find.text('正在保存…'), findsWidgets);
    expect(
      tester
          .widget<TextButton>(find.byKey(const Key('settings-back')))
          .onPressed,
      isNull,
    );
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byType(AgentConfigDialog), findsOneWidget);
    pending.complete(
      const AcpClientConfig(
        activeAgentServer: _codex,
        agentServers: [_codex],
        configPath: '/tmp/settings.json',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('更改已保存'), findsOneWidget);
  });

  testWidgets('discard guard restores the saved connection draft', (
    tester,
  ) async {
    await _pump(
      tester,
      AgentConfigDialog(
        configPath: '/tmp/settings.json',
        activeAgentName: 'Codex',
        agentServers: const [_codex],
        onSaveConfig: (config) async => config,
      ),
    );
    await tester.enterText(
      find.byKey(const Key('agent-command-field')),
      '/bin/unsaved',
    );
    await tester.tap(find.byKey(const Key('settings-back')));
    await tester.pumpAndSettle();
    expect(find.text('放弃未保存的更改？'), findsOneWidget);
    await tester.tap(find.text('继续编辑'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-discard')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('放弃更改').last);
    await tester.pumpAndSettle();
    expect(_text(tester, 'agent-command-field'), _codex.command);
    expect(_saveButton(tester).onPressed, isNull);
  });

  testWidgets('480px page uses compact navigation without overflow', (
    tester,
  ) async {
    await _pump(
      tester,
      AgentConfigDialog(
        configPath: '/tmp/settings.json',
        activeAgentName: 'Codex',
        agentServers: const [_codex],
        onSaveConfig: (config) async => config,
      ),
      size: const Size(480, 900),
    );
    expect(find.byKey(const Key('settings-section-picker')), findsOneWidget);
    expect(find.byKey(const Key('settings-section-agents')), findsNothing);
    await tester.enterText(
      find.byKey(const Key('agent-command-field')),
      '/bin/narrow',
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('sets the startup default from the selected Agent menu', (
    tester,
  ) async {
    AcpClientConfig? saved;
    await _pump(
      tester,
      AgentConfigDialog(
        configPath: '/tmp/settings.json',
        activeAgentName: 'Kimi',
        defaultAgentName: 'Kimi',
        agentServers: const [
          AgentServerConfig(name: 'Kimi', type: 'custom', command: '/bin/kimi'),
          _codex,
        ],
        onSaveConfig: (config) async {
          saved = config;
          return config;
        },
      ),
    );
    await tester.tap(find.byKey(const Key('settings-agent-Codex')));
    await tester.pump();
    await tester.tap(find.byTooltip('Agent 操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('设为启动默认 Agent'));
    await tester.pumpAndSettle();
    await _save(tester);
    expect(saved?.defaultAgentServerName, 'Codex');
  });

  testWidgets('adds an Agent preset through the inline editor', (tester) async {
    AcpClientConfig? saved;
    await _pump(
      tester,
      AgentConfigDialog(
        configPath: '/tmp/settings.json',
        activeAgentName: 'Existing',
        agentServers: const [
          AgentServerConfig(
            name: 'Existing',
            type: 'custom',
            command: '/bin/existing',
          ),
        ],
        agentPresets: const [
          _codex,
          AgentServerConfig(
            name: 'Pi',
            type: 'custom',
            command: '/usr/local/bin/npx',
            args: ['-y', 'pi-acp@0.0.31'],
          ),
        ],
        onSaveConfig: (config) async {
          saved = config;
          return config;
        },
      ),
    );
    await tester.tap(find.byKey(const Key('settings-add-agent')));
    await tester.pump();
    expect(find.byKey(const Key('agent-preset-field')), findsOneWidget);
    expect(
      find.byKey(const Key('agent-command-field')).hitTestable(),
      findsOneWidget,
    );
    expect(find.byKey(const Key('agent-cwd-field')), findsOneWidget);
    _dropdown<String>(tester, 'agent-preset-field').onChanged?.call('Pi');
    await tester.pump();
    await _save(tester);
    final pi = saved?.agentServerNamed('Pi');
    expect(pi?.command, '/usr/local/bin/npx');
    expect(pi?.args, ['-y', 'pi-acp@0.0.31']);
  });

  for (final type in [
    'websocket',
    'ws',
    'https',
    'sse',
    'streamable_http',
    'streamable-http',
  ]) {
    testWidgets('preserves saved remote Agent alias $type', (tester) async {
      final originalUrl = type == 'websocket' || type == 'ws'
          ? 'wss://agent.example.com/acp'
          : 'https://agent.example.com/acp';
      final changedUrl = '$originalUrl/v2';
      AcpClientConfig? saved;
      await _pump(
        tester,
        AgentConfigDialog(
          configPath: '/tmp/settings.json',
          activeAgentName: 'Legacy',
          agentServers: [
            AgentServerConfig.fromJson(
              name: 'Legacy',
              json: {
                'type': type,
                'url': originalUrl,
                'headers': {'X-Example': 'keep-me'},
              },
            ),
          ],
          onSaveConfig: (config) async {
            saved = config;
            return config;
          },
        ),
      );
      expect(find.byKey(const Key('agent-url-field')), findsOneWidget);
      expect(find.byKey(const Key('agent-command-field')), findsNothing);
      expect(
        _dropdownButton<String>(
          tester,
          'agent-type-field',
        ).items?.singleWhere((item) => item.value == type).enabled,
        isFalse,
      );
      await tester.enterText(
        find.byKey(const Key('agent-url-field')),
        changedUrl,
      );
      await _save(tester);
      expect(saved?.agentServers.single.type, type);
      expect(saved?.agentServers.single.url, changedUrl);
      expect(saved?.agentServers.single.headers, {'X-Example': 'keep-me'});
    });
  }

  testWidgets('adds stdio and HTTP MCP connections inline', (tester) async {
    AcpClientConfig? saved;
    await _pump(
      tester,
      AgentConfigDialog(
        configPath: '/tmp/settings.json',
        activeAgentName: 'Codex',
        agentServers: const [_codex],
        onSaveConfig: (config) async {
          saved = config;
          return config;
        },
      ),
    );
    await _section(tester, 'tools');
    await tester.tap(find.byKey(const Key('settings-add-mcp')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('mcp-name-field')),
      'filesystem',
    );
    await tester.enterText(
      find.byKey(const Key('mcp-command-field')),
      '/bin/mcp-fs',
    );
    await tester.tap(find.byKey(const Key('settings-add-mcp')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('mcp-name-field')),
      'remote-tools',
    );
    _dropdown<String>(tester, 'mcp-type-field').onChanged?.call('http');
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('mcp-url-field')),
      'https://tools.example.com/mcp',
    );
    await _save(tester);
    expect(saved?.mcpServers.map((server) => server.name), [
      'filesystem',
      'remote-tools',
    ]);
    expect(saved?.mcpServers.first.command, '/bin/mcp-fs');
    expect(saved?.mcpServers.last.type, 'http');
  });

  testWidgets('preserves saved MCP-over-ACP without enabling it', (
    tester,
  ) async {
    AcpClientConfig? saved;
    await _pump(
      tester,
      AgentConfigDialog(
        configPath: '/tmp/settings.json',
        activeAgentName: 'Codex',
        agentServers: const [_codex],
        mcpServers: const [
          McpServerConfig(
            raw: {'name': 'legacy-tools', 'type': 'acp', 'id': 'nested-agent'},
          ),
        ],
        onSaveConfig: (config) async {
          saved = config;
          return config;
        },
      ),
    );
    await _section(tester, 'tools');
    await tester.tap(find.byKey(const Key('settings-mcp-legacy-tools')));
    await tester.pump();
    expect(find.textContaining('MCP-over-ACP is unavailable'), findsOneWidget);
    expect(
      _dropdownButton<String>(
        tester,
        'mcp-type-field',
      ).items?.singleWhere((item) => item.value == 'acp').enabled,
      isFalse,
    );
    await tester.enterText(
      find.byKey(const Key('mcp-name-field')),
      'renamed-tools',
    );
    await _save(tester);
    expect(saved?.mcpServers.single.name, 'renamed-tools');
    expect(saved?.mcpServers.single.type, 'acp');
    expect(saved?.mcpServers.single.id, 'nested-agent');
  });

  testWidgets('saves directories, providers, permissions and reviewer', (
    tester,
  ) async {
    AcpClientConfig? saved;
    await _pump(
      tester,
      AgentConfigDialog(
        configPath: '/tmp/settings.json',
        activeAgentName: 'Codex',
        agentServers: const [_codex],
        onSaveConfig: (config) async {
          saved = config;
          return config;
        },
      ),
    );
    await _section(tester, 'tools');
    await tester.tap(find.widgetWithText(TextButton, '添加目录'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('directory-path-field')),
      '/workspace/extra',
    );
    await tester.tap(find.widgetWithText(FilledButton, '添加到草稿'));
    await tester.pumpAndSettle();
    await _section(tester, 'permissions');
    _switch(tester, 'filesystem-read-switch').onChanged?.call(true);
    _switch(tester, 'filesystem-write-switch').onChanged?.call(true);
    _switch(tester, 'terminal-enabled-switch').onChanged?.call(true);
    _switch(tester, 'review-agent-enabled-switch').onChanged?.call(true);
    await tester.pump();
    _dropdown<String>(tester, 'review-target-kind').onChanged?.call('mcp');
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('review-mcp-server-name-field')),
      'permission-reviewer',
    );
    await tester.enterText(
      find.byKey(const Key('review-model-field')),
      'review-model',
    );
    await tester.enterText(
      find.byKey(const Key('review-timeout-field')),
      '5000',
    );
    await tester.ensureVisible(find.widgetWithText(TextButton, '添加规则'));
    await tester.pump();
    await tester.tap(find.widgetWithText(TextButton, '添加规则'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('trust-tool-name-field')),
      'read_text_file',
    );
    await tester.enterText(
      find.byKey(const Key('trust-tool-kind-field')),
      'read',
    );
    await tester.tap(find.widgetWithText(FilledButton, '添加到草稿'));
    await tester.pumpAndSettle();
    await _save(tester);
    expect(saved?.additionalDirectories, ['/workspace/extra']);
    expect(saved?.clientProviders.filesystem.readTextFile, isTrue);
    expect(saved?.clientProviders.filesystem.writeTextFile, isTrue);
    expect(saved?.clientProviders.terminal.enabled, isTrue);
    expect(
      saved?.clientProviders.permissions.trustRules.single.toolName,
      'read_text_file',
    );
    expect(
      saved?.clientProviders.permissions.reviewAgent.mcpServerName,
      'permission-reviewer',
    );
    expect(
      saved?.clientProviders.permissions.reviewAgent.timeout,
      const Duration(milliseconds: 5000),
    );
  });

  testWidgets('invalid reviewer input remains visible after save', (
    tester,
  ) async {
    await _pump(
      tester,
      AgentConfigDialog(
        configPath: '/tmp/settings.json',
        activeAgentName: 'Codex',
        agentServers: const [_codex],
        clientProviders: const AcpClientProviderConfig(
          permissions: AcpPermissionProviderConfig(
            reviewAgent: AcpPermissionReviewAgentConfig(
              enabled: true,
              agentServerName: 'Codex',
            ),
          ),
        ),
        onSaveConfig: (config) async => config,
      ),
    );
    await _section(tester, 'permissions');
    await tester.enterText(
      find.byKey(const Key('review-timeout-field')),
      'soon',
    );
    await _save(tester);
    expect(find.textContaining('positive integer'), findsOneWidget);
    expect(find.byKey(const Key('review-timeout-field')), findsOneWidget);
  });

  testWidgets('unrelated edits keep a configured reviewer disabled', (
    tester,
  ) async {
    AcpClientConfig? saved;
    await _pump(
      tester,
      AgentConfigDialog(
        configPath: '/tmp/settings.json',
        activeAgentName: 'Codex',
        agentServers: const [_codex],
        clientProviders: const AcpClientProviderConfig(
          permissions: AcpPermissionProviderConfig(
            reviewAgent: AcpPermissionReviewAgentConfig(
              mcpServerName: 'permission-reviewer',
            ),
          ),
        ),
        onSaveConfig: (config) async {
          saved = config;
          return config;
        },
      ),
    );
    await tester.enterText(
      find.byKey(const Key('agent-command-field')),
      '/bin/changed',
    );
    await _save(tester);
    expect(saved?.clientProviders.permissions.reviewAgent.enabled, isFalse);
    expect(
      saved?.clientProviders.permissions.reviewAgent.mcpServerName,
      'permission-reviewer',
    );
  });

  testWidgets('restored secret text remains an explicit edit', (tester) async {
    AcpClientConfig? saved;
    const ref =
        'keychain://ianvs-acp/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    await _pump(
      tester,
      AgentConfigDialog(
        configPath: '/tmp/settings.json',
        activeAgentName: 'Local',
        agentServers: const [
          AgentServerConfig(
            name: 'Local',
            type: 'custom',
            command: 'old-agent',
            env: {'TOKEN': 'agent-secret'},
            envRefs: {'TOKEN': ref},
          ),
        ],
        mcpServers: const [
          McpServerConfig(
            raw: {
              'name': 'tools',
              'command': 'old-tool',
              'env': [
                {'name': 'TOKEN', 'value': 'mcp-secret'},
              ],
            },
            envRefs: {'TOKEN': ref},
          ),
        ],
        onSaveConfig: (config) async {
          saved = config;
          return config;
        },
      ),
    );
    await tester.enterText(
      find.byKey(const Key('agent-command-field')),
      'new-agent',
    );
    await tester.enterText(
      find.byKey(const Key('agent-env-name-0-field')),
      'OTHER',
    );
    await tester.enterText(
      find.byKey(const Key('agent-env-name-0-field')),
      'TOKEN',
    );
    await tester.enterText(
      find.byKey(const Key('agent-env-value-0-field')),
      'changed',
    );
    await tester.enterText(
      find.byKey(const Key('agent-env-value-0-field')),
      'agent-secret',
    );
    await _section(tester, 'tools');
    await tester.tap(find.byKey(const Key('settings-mcp-tools')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('mcp-command-field')),
      'new-tool',
    );
    await tester.enterText(
      find.byKey(const Key('mcp-env-value-0-field')),
      'changed',
    );
    await tester.enterText(
      find.byKey(const Key('mcp-env-value-0-field')),
      'mcp-secret',
    );
    await _save(tester);
    expect(saved?.agentServers.single.explicitEnvKeys, {'TOKEN'});
    expect(saved?.mcpServers.single.explicitEnvKeys, {'TOKEN'});
    expect(
      saved?.agentServers.single.toJson(),
      isNot(contains('explicitEnvKeys')),
    );
    expect(
      saved?.mcpServers.single.toJson(),
      isNot(contains('explicitEnvKeys')),
    );
  });

  testWidgets('Agent rename retains inline reviewer values for rekeying', (
    tester,
  ) async {
    AcpClientConfig? saved;
    const ref =
        'keychain://ianvs-acp/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    await _pump(
      tester,
      AgentConfigDialog(
        configPath: '/tmp/settings.json',
        activeAgentName: 'Old',
        agentServers: const [
          AgentServerConfig(
            name: 'Old',
            type: 'custom',
            command: '/bin/agent',
            permissionReviewAgent: AcpPermissionReviewAgentConfig(
              enabled: true,
              mcpServer: McpServerConfig(
                raw: {
                  'name': 'inline-review',
                  'command': '/bin/review',
                  'env': [
                    {'name': 'TOKEN', 'value': 'resolved-secret'},
                  ],
                },
                envRefs: {'TOKEN': ref},
              ),
            ),
          ),
        ],
        onSaveConfig: (config) async {
          saved = config;
          return config;
        },
      ),
    );
    await tester.enterText(find.byKey(const Key('agent-name-field')), 'New');
    await _save(tester);
    final review = saved?.agentServers.single.permissionReviewAgent;
    expect(saved?.agentServers.single.name, 'New');
    expect(review?.enabled, isTrue);
    expect(review?.mcpServer?.env, {'TOKEN': 'resolved-secret'});
    expect(review?.mcpServer?.envRefs, isEmpty);
  });
}

const _codex = AgentServerConfig(
  name: 'Codex',
  type: 'custom',
  command: '/usr/local/bin/codex',
);

Future<void> _pump(
  WidgetTester tester,
  AgentConfigDialog dialog, {
  Size size = const Size(1440, 1024),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(home: dialog));
  await tester.pump();
}

Future<void> _section(WidgetTester tester, String name) async {
  await tester.tap(find.byKey(Key('settings-section-$name')));
  await tester.pump();
}

Future<void> _save(WidgetTester tester) async {
  await tester.pump();
  await tester.tap(find.byKey(const Key('settings-save')));
  await tester.pump();
}

FilledButton _saveButton(WidgetTester tester) =>
    tester.widget<FilledButton>(find.byKey(const Key('settings-save')));

String? _text(WidgetTester tester, String key) =>
    _editable(tester, key).controller.text;

EditableText _editable(WidgetTester tester, String key) =>
    tester.widget<EditableText>(
      find.descendant(
        of: find.byKey(Key(key)),
        matching: find.byType(EditableText),
        matchRoot: true,
      ),
    );

Switch _switch(WidgetTester tester, String key) => tester.widget<Switch>(
  find.descendant(of: find.byKey(Key(key)), matching: find.byType(Switch)),
);

DropdownButtonFormField<T> _dropdown<T>(WidgetTester tester, String key) =>
    tester.widget<DropdownButtonFormField<T>>(
      find.descendant(
        of: find.byKey(Key(key)),
        matching: find.byType(DropdownButtonFormField<T>),
        matchRoot: true,
      ),
    );

DropdownButton<T> _dropdownButton<T>(WidgetTester tester, String key) =>
    tester.widget<DropdownButton<T>>(
      find.descendant(
        of: find.byKey(Key(key)),
        matching: find.byType(DropdownButton<T>),
      ),
    );

AcpConfigOption _modelOption(
  String value,
  String name, {
  (String, String)? extra,
}) => AcpConfigOption(
  id: 'model',
  name: 'Model',
  type: 'select',
  currentValue: value,
  options: [
    AcpConfigOptionChoice(value: value, name: name),
    if (extra != null) AcpConfigOptionChoice(value: extra.$1, name: extra.$2),
  ],
);
