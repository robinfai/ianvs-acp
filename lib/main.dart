import 'dart:io';

import 'package:flutter/material.dart';

import 'app.dart';
import 'config/acp_client_config.dart';
import 'startup/startup_options.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final configPath = AcpClientConfig.resolveConfigPath();
  final startupOptions = StartupOptions.fromArgs([
    ...Platform.executableArguments,
    ...args,
  ]);
  try {
    final config = await AcpClientConfig.load(path: configPath);
    runApp(
      AcpClientApp(
        config: config,
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
        startupError: 'Could not load ACP config: $error',
        initialResumeSessionId: startupOptions.resumeSessionId,
        initialResumeCwd: startupOptions.resumeCwd,
        initialResumeAgentName: startupOptions.resumeAgentName,
        initialTaskId: startupOptions.taskId,
      ),
    );
  }
}
