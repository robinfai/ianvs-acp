import 'package:flutter/widgets.dart';

import 'fixture.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const scenario = String.fromEnvironment(
    'POLISH_SCENARIO',
    defaultValue: 'active',
  );
  runApp(await polishFixtureApp(scenario: scenario));
}
