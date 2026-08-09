import 'package:flutter/material.dart';

import 'audit_fixture.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const buildScenario = String.fromEnvironment('AUDIT_SCENARIO');
  final scenario = buildScenario.isNotEmpty
      ? buildScenario
      : Uri.base.queryParameters['scenario'] ?? 'empty';
  final fixture = await createAuditFixture(scenario);

  runApp(
    fixture.app(
      startupError: scenario == 'startup-error'
          ? 'Could not load ACP config: unexpected trailing comma at line 8'
          : null,
    ),
  );
}
