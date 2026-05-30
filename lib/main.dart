import 'package:flutter/material.dart';

import 'app.dart';
import 'config/acp_client_config.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final configPath = AcpClientConfig.resolveConfigPath();
  try {
    final config = await AcpClientConfig.load(path: configPath);
    runApp(AcpClientApp(config: config));
  } catch (error) {
    runApp(
      AcpClientApp(
        config: AcpClientConfig(configPath: configPath),
        startupError: 'Could not load ACP config: $error',
      ),
    );
  }
}
