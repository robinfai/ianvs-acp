import 'dart:io';

import 'package:flutter/material.dart';

import 'config/acp_client_config.dart';
import 'startup/acp_client_bootstrap.dart';
import 'startup/startup_options.dart';

void main(List<String> args) {
  WidgetsFlutterBinding.ensureInitialized();
  final configPath = AcpClientConfig.resolveConfigPath();
  final startupOptions = StartupOptions.fromArgs([
    ...Platform.executableArguments,
    ...args,
  ]);
  runApp(
    AcpClientBootstrap(configPath: configPath, startupOptions: startupOptions),
  );
}
