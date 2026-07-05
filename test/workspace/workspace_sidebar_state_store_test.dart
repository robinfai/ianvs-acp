import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/workspace/workspace_sidebar_state_store.dart';

void main() {
  test('WorkspaceSidebarStateStore saves and loads expanded paths', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'ianvs-acp-sidebar-store-',
    );
    addTearDown(() async => tempDir.delete(recursive: true));
    final store = WorkspaceSidebarStateStore(
      path: '${tempDir.path}/nested/workspace_ui_state.json',
    );

    await store.saveExpandedWorkspacePaths({
      '/workspace/b',
      '/workspace/a',
      '',
    });

    expect(await store.loadExpandedWorkspacePaths(), {
      '/workspace/a',
      '/workspace/b',
    });

    final raw =
        jsonDecode(
              await File(
                '${tempDir.path}/nested/workspace_ui_state.json',
              ).readAsString(),
            )
            as Map<String, Object?>;
    expect(raw['expanded_workspaces'], ['/workspace/a', '/workspace/b']);
  });

  test('WorkspaceSidebarStateStore resolves default path near config', () {
    final path = WorkspaceSidebarStateStore.defaultPath(
      configPath: '/tmp/ianvs-acp/settings.json',
      environment: const {'HOME': '/Users/example'},
    );

    expect(path, '/tmp/ianvs-acp/workspace_ui_state.json');
  });

  test('WorkspaceSidebarStateStore resolves default path from XDG config', () {
    final path = WorkspaceSidebarStateStore.defaultPath(
      environment: const {
        'XDG_CONFIG_HOME': '/Users/example/.config-alt',
        'HOME': '/Users/example',
      },
    );

    expect(
      path,
      '/Users/example/.config-alt/ianvs-acp/workspace_ui_state.json',
    );
  });

  test(
    'WorkspaceSidebarStateStore tolerates missing and invalid files',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'ianvs-acp-sidebar-store-',
      );
      addTearDown(() async => tempDir.delete(recursive: true));
      final file = File('${tempDir.path}/workspace_ui_state.json');
      final store = WorkspaceSidebarStateStore(path: file.path);

      expect(await store.loadExpandedWorkspacePaths(), isEmpty);

      await file.writeAsString('{bad json');

      expect(await store.loadExpandedWorkspacePaths(), isEmpty);
    },
  );
}
