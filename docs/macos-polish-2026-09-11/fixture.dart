import 'package:flutter/widgets.dart';
import 'package:ianvs_acp/acp/fake_agent_client.dart';
import 'package:ianvs_acp/app.dart';
import 'package:ianvs_acp/workspace/workspace_sidebar_state_store.dart';

import '../design-audit-2026-06-05/audit_fixture.dart';
import '../settings-redesign-2026-09-09/fixture.dart';

/// Offline application using production widgets and an in-memory workspace.
Future<Widget> polishFixtureApp({String scenario = 'active'}) async {
  final fixture = await createAuditFixture(scenario);
  return _FixtureOwner(fixture: fixture);
}

class _FixtureOwner extends StatefulWidget {
  const _FixtureOwner({required this.fixture});
  final AuditFixture fixture;

  @override
  State<_FixtureOwner> createState() => _FixtureOwnerState();
}

class _FixtureOwnerState extends State<_FixtureOwner> {
  @override
  void dispose() {
    widget.fixture.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AcpClientApp(
    controller: widget.fixture.controller,
    config: settingsFixtureConfig,
    workspaceStateStore: WorkspaceSidebarStateStore(path: null),
    writeConfig: (config) async => config,
    createAgentClient: (_) => FakeAgentClient(
      sessionSettings: auditSeedSettings,
      createSessionEvents: auditSeedEvents,
    ),
    discoverAgentServers: (_) async => const [],
    gitWorkspaceDetector: (_) => false,
  );
}
