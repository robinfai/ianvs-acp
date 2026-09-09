import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/config/acp_client_config.dart';
import 'package:ianvs_acp/ui/components/agent_config_dialog.dart';

void main() {
  testWidgets(
    'settings inputs expose names and keyboard save preserves drafts',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 1024);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final semantics = tester.ensureSemantics();
      AcpClientConfig? saved;
      var writes = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: AgentConfigDialog(
            agentServers: const [
              AgentServerConfig(name: 'Codex', type: 'custom', command: 'npx'),
            ],
            activeAgentName: 'Codex',
            defaultAgentName: 'Codex',
            configPath: '/tmp/settings-keyboard.json',
            onSaveConfig: (config) async {
              writes++;
              saved = config;
              return config;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      final labels = <String>[];
      void visit(SemanticsNode node) {
        if (node.flagsCollection.isTextField) labels.add(node.label);
        node.visitChildren((child) {
          visit(child);
          return true;
        });
      }

      visit(tester.getSemantics(find.byType(AgentConfigDialog)));
      expect(
        labels,
        containsAll([
          startsWith('名称'),
          startsWith('启动命令'),
          startsWith('启动工作目录'),
        ]),
      );
      semantics.dispose();
      final name = find.descendant(
        of: find.byKey(const Key('agent-name-field')),
        matching: find.byType(TextField),
      );
      await tester.enterText(name, 'Renamed');
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();
      expect(writes, 1);
      expect(saved!.activeAgentServer!.name, 'Renamed');
      expect(find.text('更改已保存'), findsOneWidget);
      await tester.enterText(name, 'Unsaved again');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('放弃未保存的更改？'), findsOneWidget);
      await tester.tap(find.text('继续编辑'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(name).controller!.text, 'Unsaved again');
      expect(writes, 1);
    },
  );
}
