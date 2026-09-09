import 'package:flutter/material.dart';
import 'package:ianvs_acp/acp/acp_session_settings.dart';
import 'package:ianvs_acp/acp/fake_agent_client.dart';
import 'package:ianvs_acp/app.dart';
import 'package:ianvs_acp/config/acp_client_config.dart';
import 'package:ianvs_acp/workspace/workspace_sidebar_state_store.dart';

final settingsFixtureConfig = AcpClientConfig.fromJson({
  'default_agent_server': 'Codex',
  'agent_servers': {
    'Codex': {
      'type': 'custom',
      'command': 'npx',
      'args': ['@agentclientprotocol/codex-acp'],
    },
    'Claude Code': {
      'type': 'custom',
      'command': 'claude',
      'args': ['--acp'],
    },
    'Pi': {
      'type': 'custom',
      'command': 'npx',
      'args': ['-y', 'pi-acp'],
    },
  },
  'additional_directories': ['/workspace/shared-components'],
  'mcp_servers': [
    {
      'name': 'Project tools',
      'command': 'project-tools',
      'args': ['--stdio'],
    },
  ],
  'client_providers': {
    'filesystem': {'enabled': true},
    'terminal': {'enabled': false},
    'permissions': {
      'review_agent': {'enabled': false},
    },
  },
}, configPath: '/tmp/ianvs-settings-design/settings.json');

const settingsFixtureOptions = AcpSessionSettings(
  modes: AcpSessionModeInfo(
    currentModeId: 'ask',
    availableModes: [
      AcpSessionMode(id: 'ask', name: 'Ask'),
      AcpSessionMode(id: 'edit', name: 'Edit'),
    ],
  ),
  configOptions: [
    AcpConfigOption(
      id: 'model',
      name: 'Model',
      type: 'select',
      currentValue: 'gpt-5-codex',
      group: 'Model',
      options: [
        AcpConfigOptionChoice(value: 'gpt-5-codex', name: 'GPT-5 Codex'),
        AcpConfigOptionChoice(value: 'gpt-5', name: 'GPT-5'),
      ],
    ),
    AcpConfigOption(
      id: 'reasoning_effort',
      name: 'Reasoning effort',
      type: 'select',
      currentValue: 'medium',
      group: 'Model',
      options: [
        AcpConfigOptionChoice(value: 'low', name: 'Low'),
        AcpConfigOptionChoice(value: 'medium', name: 'Medium'),
        AcpConfigOptionChoice(value: 'high', name: 'High'),
      ],
    ),
  ],
);

Widget settingsFixtureApp() => AcpClientApp(
  config: settingsFixtureConfig,
  workspaceStateStore: WorkspaceSidebarStateStore(path: null),
  writeConfig: (config) async => config,
  createAgentClient: (_) =>
      FakeAgentClient(sessionSettings: settingsFixtureOptions),
  discoverAgentServers: (_) async => const [],
  gitWorkspaceDetector: (_) => false,
);
