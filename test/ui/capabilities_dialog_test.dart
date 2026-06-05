import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/acp_agent_capabilities.dart';
import 'package:ianvs_acp/ui/components/capabilities_dialog.dart';

void main() {
  testWidgets('CapabilitiesDialog renders negotiated ACP capabilities', (
    tester,
  ) async {
    const capabilities = AcpAgentCapabilities(
      protocolVersion: 1,
      loadSession: true,
      prompt: AcpPromptCapabilities(
        image: true,
        audio: false,
        embeddedContext: true,
      ),
      mcp: AcpMcpCapabilities(http: true, sse: false, acp: false),
      session: AcpSessionCapabilities(
        list: true,
        resume: false,
        fork: true,
        configOptions: false,
        additionalDirectories: true,
        close: true,
        rawKeys: ['additionalDirectories', 'close', 'fork', 'list'],
      ),
      auth: AcpAuthCapabilities(logout: true),
      client: AcpClientCapabilities(
        fsReadTextFile: false,
        fsWriteTextFile: false,
        terminal: false,
        hasFsProvider: false,
        hasTerminalProvider: false,
        allowReadOutsideWorkspace: false,
      ),
      rawAgentCapabilities: {
        'loadSession': true,
        'sessionCapabilities': {'list': {}, 'close': {}},
      },
      authMethods: [],
      agentInfo: {'name': 'Example Agent', 'version': '2.0.0'},
      clientInfo: {'name': 'ACP Client', 'version': '1.0.0'},
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: CapabilitiesDialog(capabilities: capabilities)),
      ),
    );

    expect(find.text('ACP Compatibility'), findsOneWidget);
    expect(find.text('Capability summary'), findsOneWidget);
    expect(find.text('Ready now'), findsOneWidget);
    expect(find.text('Needs attention'), findsOneWidget);
    expect(find.text('Image input'), findsWidgets);
    expect(find.text('SSE MCP'), findsWidgets);
    expect(find.text('Protocol version'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    expect(find.text('Client'), findsWidgets);
    expect(find.text('ACP Client 1.0.0'), findsOneWidget);
    expect(find.text('Agent'), findsOneWidget);
    expect(find.text('Example Agent 2.0.0'), findsOneWidget);
    expect(find.text('Image'), findsOneWidget);
    expect(find.text('Embedded context'), findsOneWidget);
    expect(find.text('List'), findsOneWidget);
    expect(find.text('Fork'), findsOneWidget);
    expect(find.text('Additional directories'), findsOneWidget);
    expect(find.text('Close'), findsWidgets);
    expect(find.text('Logout'), findsOneWidget);
    expect(find.text('Advertise fs/read_text_file'), findsOneWidget);
  });

  testWidgets('CapabilitiesDialog renders empty disconnected state', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: CapabilitiesDialog(capabilities: null)),
      ),
    );

    expect(
      find.text('Connect to an ACP agent to inspect capabilities.'),
      findsOneWidget,
    );
  });
}
