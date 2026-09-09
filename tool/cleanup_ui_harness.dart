// Reproducible macOS acceptance fixture; no production agent or user storage.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:ianvs_acp/acp/acp_permission_request.dart';
import 'package:ianvs_acp/acp/agent_event.dart';
import 'package:ianvs_acp/acp/fake_agent_client.dart';
import 'package:ianvs_acp/app.dart';
import 'package:ianvs_acp/config/acp_client_config.dart';
import 'package:ianvs_acp/state/chat_controller.dart';
import 'package:ianvs_acp/workspace/workspace_sidebar_state_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final workspace = await Directory.systemTemp.createTemp('ianvs-cleanup-ui-');
  final client = FakeAgentClient(
    createSessionEvents: const [
      AgentEvent(
        type: AgentEventType.userMessage,
        text: 'Review this test workspace.',
      ),
      AgentEvent(
        type: AgentEventType.agentTextDelta,
        text:
            'The acceptance fixture is ready. Inspect events, permissions and runtime details.',
      ),
    ],
  );
  final controller = ChatController(
    client: client,
    cwd: workspace.path,
    agentName: 'Acceptance Agent',
  );
  await controller.newSession();
  client.emitPermissionRequest(
    AcpPermissionRequest(
      id: 'acceptance-read',
      title: 'Read the test workspace',
      rationale: 'Synthetic permission for export verification.',
      sessionId: controller.currentSession!.id,
      toolName: 'read_text_file',
      options: const ['Allow', 'Deny'],
      requestedAt: DateTime.now(),
    ),
  );
  await Future<void>.delayed(Duration.zero);
  await controller.resolvePermissionRequest(AcpPermissionDecision.deny);
  runApp(
    AcpClientApp(
      controller: controller,
      config: const AcpClientConfig(
        defaultAgentServerName: 'Acceptance Agent',
        activeAgentServer: AgentServerConfig(
          name: 'Acceptance Agent',
          type: 'custom',
          command: 'acceptance-fixture',
        ),
        agentServers: [
          AgentServerConfig(
            name: 'Acceptance Agent',
            type: 'custom',
            command: 'acceptance-fixture',
          ),
        ],
      ),
      configurationWritable: false,
      workspaceStateStore: WorkspaceSidebarStateStore(path: null),
      createAgentClient: (_) => FakeAgentClient(),
      gitWorkspaceDetector: (_) => false,
    ),
  );
}
