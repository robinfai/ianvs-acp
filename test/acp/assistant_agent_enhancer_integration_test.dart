import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/assistant_agent_enhancer.dart';
import 'package:ianvs_acp/acp/rust_acp_agent_client.dart';
import 'package:ianvs_acp/config/assistant_agent_config.dart';
import 'package:ianvs_acp/rust/ianvs_acp_native.dart';

void main() {
  final root = Directory.current.path;
  final libraryPath = '$root/rust/target/debug/libianvs_acp_ffi.dylib';
  final agentPath = '$root/rust/target/debug/ianvs-acp-fixture-agent';
  final artifactsAvailable =
      File(libraryPath).existsSync() && File(agentPath).existsSync();

  test(
    'real Rust helper agent handles a title followed by a turn summary',
    () async {
      final runtime = IanvsRustRuntime(
        native: FfiIanvsAcpNativeApi.open(libraryPath: libraryPath),
        pollInterval: const Duration(milliseconds: 1),
      );
      final client = RustAcpAgentClient(
        agentName: 'assistant-fixture',
        agentCommand: '/usr/bin/env',
        agentArgs: <String>[
          'IANVS_FIXTURE_SKIP_PERMISSION=1',
          agentPath,
        ],
        agentCwd: root,
        runtime: runtime,
      );
      final enhancer = AcpAssistantAgentEnhancer(
        client,
        root,
        config: const AssistantAgentConfig(
          enabled: true,
          agentName: 'assistant-fixture',
          model: 'quality',
          timeout: Duration(seconds: 5),
        ),
      );
      addTearDown(enhancer.dispose);

      final title = await enhancer.generateSessionTitle(
        sessionId: 'main-session',
        firstPrompt: 'Implement the queue',
      );
      final summary = await enhancer.summarizeTurn(
        const AssistantTurnSummaryRequest(
          sessionId: 'main-session',
          turnId: 1,
          userPrompt: 'Implement the queue',
          completedTurn: 'ASSISTANT:\nQueue implemented and tests passed.',
        ),
      );

      expect(title, 'headless fixture complete');
      expect(summary, 'headless fixture complete');
    },
    skip: artifactsAvailable
        ? false
        : 'Run tool/verify_rust_runtime.sh to build native test artifacts.',
    timeout: const Timeout(Duration(seconds: 20)),
  );
}
