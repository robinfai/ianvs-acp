import 'dart:collection';

import 'package:dart_acp/dart_acp.dart';
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

  testWidgets(
    'CapabilitiesDialog caches raw previews across rebuilds and collapse',
    (tester) async {
      final budget = AcpInputBudget(
        maxMetadataPreviewChars: 24,
        maxMetadataPreviewBytes: 24,
      );
      final rawCapabilities = _countingPayload('RAW-CANARY');
      final authMethod = _countingPayload('AUTH-CANARY');
      final authMethods = <Map<String, Object?>>[authMethod];
      final capabilities = _capabilities(
        rawCapabilities,
        authMethods: authMethods,
      );

      await tester.pumpWidget(
        _app(capabilities: capabilities, inputBudget: budget),
      );

      expect(rawCapabilities.valueReads, 0);
      expect(authMethod.valueReads, 0);

      await _toggleRawCapabilities(tester);
      expect(rawCapabilities.valueReads, greaterThan(0));
      expect(rawCapabilities.valueReads, lessThan(8));
      expect(authMethod.valueReads, greaterThan(0));
      expect(authMethod.valueReads, lessThan(8));
      expect(find.textContaining('RAW-CANARY'), findsNothing);
      expect(find.textContaining('AUTH-CANARY'), findsNothing);
      expect(find.textContaining('Preview truncated'), findsNWidgets(2));

      rawCapabilities.valueReads = 0;
      authMethod.valueReads = 0;
      await tester.pumpWidget(
        _app(capabilities: capabilities, inputBudget: budget),
      );
      await tester.pump();

      expect(rawCapabilities.valueReads, 0);
      expect(authMethod.valueReads, 0);

      await _toggleRawCapabilities(tester);
      await _toggleRawCapabilities(tester);

      expect(rawCapabilities.valueReads, 0);
      expect(authMethod.valueReads, 0);

      await _toggleRawCapabilities(tester);
      final replacementRaw = _countingPayload('REPLACEMENT-CANARY');
      final replacementCapabilities = _capabilities(
        replacementRaw,
        authMethods: authMethods,
      );
      await tester.pumpWidget(
        _app(capabilities: replacementCapabilities, inputBudget: budget),
      );
      await tester.pump();

      expect(replacementRaw.valueReads, 0);
      expect(authMethod.valueReads, 0);

      await _toggleRawCapabilities(tester);

      expect(replacementRaw.valueReads, greaterThan(0));
      expect(replacementRaw.valueReads, lessThan(8));
      expect(authMethod.valueReads, 0);

      replacementRaw.valueReads = 0;
      final replacementBudget = AcpInputBudget(
        maxMetadataPreviewChars: 24,
        maxMetadataPreviewBytes: 24,
      );
      await tester.pumpWidget(
        _app(
          capabilities: replacementCapabilities,
          inputBudget: replacementBudget,
        ),
      );
      await tester.pump();

      expect(replacementRaw.valueReads, greaterThan(0));
      expect(replacementRaw.valueReads, lessThan(8));
      expect(authMethod.valueReads, greaterThan(0));
      expect(authMethod.valueReads, lessThan(8));

      replacementRaw.valueReads = 0;
      authMethod.valueReads = 0;
      await _toggleRawCapabilities(tester);
      final deferredRaw = _countingPayload('DEFERRED-CANARY');
      final deferredCapabilities = _capabilities(
        deferredRaw,
        authMethods: authMethods,
      );
      final deferredBudget = AcpInputBudget(
        maxMetadataPreviewChars: 20,
        maxMetadataPreviewBytes: 20,
      );
      await tester.pumpWidget(
        _app(capabilities: deferredCapabilities, inputBudget: deferredBudget),
      );
      await tester.pump();

      expect(deferredRaw.valueReads, 0);
      expect(authMethod.valueReads, 0);

      await _toggleRawCapabilities(tester);

      expect(deferredRaw.valueReads, greaterThan(0));
      expect(deferredRaw.valueReads, lessThan(8));
      expect(authMethod.valueReads, greaterThan(0));
      expect(authMethod.valueReads, lessThan(8));

      deferredRaw.valueReads = 0;
      authMethod.valueReads = 0;
      await _toggleRawCapabilities(tester);
      final withoutAuthMethods = _capabilities(deferredRaw);
      await tester.pumpWidget(
        _app(capabilities: withoutAuthMethods, inputBudget: deferredBudget),
      );
      await tester.pump();
      await tester.pumpWidget(
        _app(capabilities: deferredCapabilities, inputBudget: deferredBudget),
      );
      await tester.pump();

      expect(deferredRaw.valueReads, 0);
      expect(authMethod.valueReads, 0);

      await _toggleRawCapabilities(tester);

      expect(deferredRaw.valueReads, 0);
      expect(authMethod.valueReads, greaterThan(0));
      expect(authMethod.valueReads, lessThan(8));
    },
  );

  testWidgets(
    'CapabilitiesDialog exposes exact and plus-one preview boundaries',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CapabilitiesDialog(
              capabilities: _capabilities(<String, Object?>{'v': 'é'}),
              inputBudget: const AcpInputBudget(
                maxMetadataPreviewChars: 9,
                maxMetadataPreviewBytes: 10,
              ),
            ),
          ),
        ),
      );
      await _expandRawCapabilities(tester);

      expect(find.text('{"v":"é"}'), findsOneWidget);
      expect(find.textContaining('Preview truncated'), findsNothing);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CapabilitiesDialog(
              key: const ValueKey('char-plus-one'),
              capabilities: _capabilities(<String, Object?>{'v': 'éa'}),
              inputBudget: const AcpInputBudget(
                maxMetadataPreviewChars: 9,
                maxMetadataPreviewBytes: 64,
              ),
            ),
          ),
        ),
      );
      await _expandRawCapabilities(tester);

      expect(find.textContaining('Preview truncated'), findsOneWidget);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CapabilitiesDialog(
              key: const ValueKey('byte-plus-one'),
              capabilities: _capabilities(<String, Object?>{'v': 'éa'}),
              inputBudget: const AcpInputBudget(
                maxMetadataPreviewChars: 64,
                maxMetadataPreviewBytes: 10,
              ),
            ),
          ),
        ),
      );
      await _expandRawCapabilities(tester);

      expect(find.textContaining('Preview truncated'), findsOneWidget);
    },
  );

  testWidgets(
    'CapabilitiesDialog reports invalid raw data without calling toString',
    (tester) async {
      final hostile = _HostileToString();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CapabilitiesDialog(
              capabilities: _capabilities(<String, Object?>{'secret': hostile}),
            ),
          ),
        ),
      );
      await _expandRawCapabilities(tester);

      expect(tester.takeException(), isNull);
      expect(hostile.calls, 0);
      expect(find.textContaining('HOSTILE-CANARY'), findsNothing);
      expect(find.textContaining('Details omitted'), findsOneWidget);
    },
  );
}

Widget _app({
  required AcpAgentCapabilities capabilities,
  required AcpInputBudget inputBudget,
}) {
  return MaterialApp(
    home: Scaffold(
      body: CapabilitiesDialog(
        capabilities: capabilities,
        inputBudget: inputBudget,
      ),
    ),
  );
}

Future<void> _toggleRawCapabilities(WidgetTester tester) async {
  final tile = find.text('Raw capability data');
  await tester.ensureVisible(tile);
  await tester.tap(tile);
  await tester.pumpAndSettle();
}

Future<void> _expandRawCapabilities(WidgetTester tester) =>
    _toggleRawCapabilities(tester);

AcpAgentCapabilities _capabilities(
  Map<String, Object?> rawCapabilities, {
  List<Map<String, Object?>> authMethods = const <Map<String, Object?>>[],
}) {
  return AcpAgentCapabilities(
    protocolVersion: 1,
    loadSession: false,
    prompt: const AcpPromptCapabilities(
      image: false,
      audio: false,
      embeddedContext: false,
    ),
    mcp: const AcpMcpCapabilities(http: false, sse: false, acp: false),
    session: const AcpSessionCapabilities(
      list: false,
      resume: false,
      fork: false,
      configOptions: false,
      additionalDirectories: false,
      close: false,
      rawKeys: <String>[],
    ),
    auth: const AcpAuthCapabilities(logout: false),
    client: const AcpClientCapabilities(
      fsReadTextFile: false,
      fsWriteTextFile: false,
      terminal: false,
      hasFsProvider: false,
      hasTerminalProvider: false,
      allowReadOutsideWorkspace: false,
    ),
    rawAgentCapabilities: rawCapabilities,
    authMethods: authMethods,
  );
}

_CountingMap _countingPayload(String canary) {
  return _CountingMap(<String, Object?>{
    'visible': 'x' * 128,
    for (var index = 0; index < 255; index += 1)
      'field$index': index == 254 ? canary : 'value$index',
  });
}

final class _CountingMap extends MapBase<String, Object?> {
  _CountingMap(Map<String, Object?> values) : _values = values;

  final Map<String, Object?> _values;
  var valueReads = 0;

  @override
  Object? operator [](Object? key) {
    valueReads += 1;
    return _values[key];
  }

  @override
  void operator []=(String key, Object? value) => _values[key] = value;

  @override
  void clear() => _values.clear();

  @override
  Iterable<String> get keys => _values.keys;

  @override
  Object? remove(Object? key) => _values.remove(key);
}

final class _HostileToString {
  var calls = 0;

  @override
  String toString() {
    calls += 1;
    throw StateError('HOSTILE-CANARY');
  }
}
