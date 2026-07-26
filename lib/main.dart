import 'dart:io';

import 'package:flutter/material.dart';

import 'app.dart';
import 'config/acp_client_config.dart';
import 'config/acp_config_store.dart';
import 'config/platform_secret_store.dart';
import 'startup/startup_options.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final configPath = AcpClientConfig.resolveConfigPath();
  final startupOptions = StartupOptions.fromArgs([
    ...Platform.executableArguments,
    ...args,
  ]);
  final secretStore = createPlatformSecretStore();
  try {
    final config = await AcpConfigStore.loadConfig(
      configPath: configPath,
      secretStore: secretStore,
    );
    runApp(
      AcpClientApp(
        config: config,
        secretStore: secretStore,
        initialResumeSessionId: startupOptions.resumeSessionId,
        initialResumeCwd: startupOptions.resumeCwd,
        initialResumeAgentName: startupOptions.resumeAgentName,
        initialTaskId: startupOptions.taskId,
      ),
    );
  } catch (error) {
    runApp(
      AcpClientApp(
        config: AcpClientConfig(configPath: configPath),
        secretStore: secretStore,
        configurationWritable: false,
        startupError: 'Could not load ACP config: $error',
        initialResumeSessionId: startupOptions.resumeSessionId,
        initialResumeCwd: startupOptions.resumeCwd,
        initialResumeAgentName: startupOptions.resumeAgentName,
        initialTaskId: startupOptions.taskId,
      ),
    );
  }
}
