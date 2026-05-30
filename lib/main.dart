import 'package:flutter/material.dart';

import 'app.dart';
import 'config/acp_client_config.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final config = await AcpClientConfig.load();
  runApp(AcpClientApp(config: config));
}
