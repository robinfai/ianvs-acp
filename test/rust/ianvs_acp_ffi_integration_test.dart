import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/app.dart';
import 'package:ianvs_acp/acp/acp_permission_request.dart';
import 'package:ianvs_acp/acp/rust_acp_agent_client.dart';
import 'package:ianvs_acp/config/acp_client_config.dart';
import 'package:ianvs_acp/ui/shell/app_shell.dart';
import 'package:ianvs_acp/rust/ianvs_acp_native.dart';

import '../../packages/ianvs_acp_runtime/test/ianvs_acp_ffi_integration_test.dart'
    as shared;

void main() {
  final root = Directory.current.path;
  final libraryPath =
      Platform.environment['IANVS_ACP_RUST_LIBRARY'] ??
      '$root/rust/target/debug/libianvs_acp_ffi.dylib';
  final agentPath =
      Platform.environment['IANVS_ACP_FIXTURE_AGENT'] ??
      '$root/rust/target/debug/ianvs-acp-fixture-agent';
  final artifactsAvailable =
      File(libraryPath).existsSync() && File(agentPath).existsSync();

  shared.main();

  test(
    'client retries native startup failure and connects after MCP cleanup',
    () async {
      var includeUnsupportedMcp = true;
      final client = RustAcpAgentClient(
        agentName: 'retry-fixture',
        agentCommand: agentPath,
        mcpServersProvider: () async => includeUnsupportedMcp
            ? const <Map<String, Object?>>[
                <String, Object?>{
                  'type': 'http',
                  'name': 'unsupported-mcp',
                  'url': 'https://example.test/mcp',
                },
              ]
            : const <Map<String, Object?>>[],
        runtime: IanvsRustRuntime(
          native: FfiIanvsAcpNativeApi.open(libraryPath: libraryPath),
          pollInterval: const Duration(milliseconds: 1),
        ),
      );
      addTearDown(client.dispose);
      for (var attempt = 0; attempt < 2; attempt++) {
        await expectLater(
          client.connect(),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'original startup error',
              contains(
                'agent does not support configured HTTP MCP server unsupported-mcp',
              ),
            ),
          ),
        );
      }
      includeUnsupportedMcp = false;
      await client.connect();
      final session = await client.createSession(
        cwd: Directory.systemTemp.path,
      );
      expect(session.id, 'fixture-session');
    },
    skip: artifactsAvailable
        ? false
        : 'Run tool/verify_rust_runtime.sh to build native test artifacts.',
    timeout: const Timeout(Duration(seconds: 20)),
  );

  testWidgets(
    'saved application outside-read policy reaches Rust and still requires permission',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync(
        'ianvs-app-outside-read-',
      );
      final workspace = Directory('${directory.path}/workspace')..createSync();
      final outside = File('${directory.path}/outside.txt')
        ..writeAsStringSync('first\nexternal second\n');
      final output = File('${workspace.path}/output.txt');
      addTearDown(() => directory.deleteSync(recursive: true));
      final agent = AgentServerConfig(
        name: 'outside-read-fixture',
        type: 'custom',
        command: agentPath,
        env: {
          'IANVS_FIXTURE_USE_FILESYSTEM': '1',
          'IANVS_FIXTURE_FILESYSTEM_READ_PATH': outside.path,
        },
      );
      // Create the app's streams and setup queue in the same real async zone
      // as native event polling; fake-clock futures cannot drive subprocess IO.
      await tester.runAsync(() async {
        await tester.pumpWidget(
          AcpClientApp(
            configurationWritable: false,
            config: AcpClientConfig(
              configPath: '${directory.path}/settings.json',
              activeAgentServer: agent,
              agentServers: [agent],
              clientProviders: const AcpClientProviderConfig(
                filesystem: AcpFilesystemProviderConfig(
                  readTextFile: true,
                  writeTextFile: true,
                  allowReadOutsideWorkspace: true,
                ),
              ),
            ),
          ),
        );
        final controller = tester
            .widget<AppShell>(find.byType(AppShell))
            .controller;
        final turnCompleted = Completer<void>();
        void observeTurnCompletion() {
          if (!controller.isStreaming && !turnCompleted.isCompleted) {
            turnCompleted.complete();
          }
        }

        final permissions = StreamIterator(
          controller.client.permissionRequests,
        );
        try {
          expect(
            await controller
                .newSession(cwd: workspace.path)
                .timeout(const Duration(seconds: 5)),
            isTrue,
            reason: controller.lastError,
          );
          final prompt = controller.sendPrompt('read the requested file');
          expect(
            await permissions.moveNext().timeout(const Duration(seconds: 5)),
            isTrue,
          );
          expect(permissions.current.toolKind, 'read');
          expect(controller.isStreaming, isTrue);
          controller.addListener(observeTurnCompletion);
          expect(
            controller.pendingPermissionRequest?.id,
            permissions.current.id,
          );
          expect(output.existsSync(), isFalse);
          await controller.resolvePermissionRequest(
            AcpPermissionDecision.allow,
          );
          expect(
            await permissions.moveNext().timeout(const Duration(seconds: 5)),
            isTrue,
          );
          expect(permissions.current.toolKind, 'edit');
          expect(output.existsSync(), isFalse);
          await controller.resolvePermissionRequest(
            AcpPermissionDecision.allow,
          );
          await prompt.timeout(const Duration(seconds: 5));
          await turnCompleted.future.timeout(const Duration(seconds: 5));
          expect(controller.lastError, isNull);
          expect(output.readAsStringSync(), 'copy:external second\n');
          expect(outside.readAsStringSync(), 'first\nexternal second\n');
        } finally {
          controller.removeListener(observeTurnCompletion);
          await permissions.cancel();
          await tester.pumpWidget(const SizedBox.shrink());
          await controller.client.dispose();
        }
      });
    },
    skip: !artifactsAvailable,
    timeout: const Timeout(Duration(seconds: 20)),
  );
}
