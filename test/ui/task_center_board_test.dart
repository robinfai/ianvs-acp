import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/task_center/task_center_controller.dart';
import 'package:ianvs_acp/task_center/task_center_models.dart';
import 'package:ianvs_acp/task_center/task_center_store.dart';

void main() {
  test(
    'TaskCenterController exposes persisted task columns for the board',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'ianvs_task_center_ui',
      );
      addTearDown(() => temp.delete(recursive: true));
      final store = TaskCenterStore(
        path: '${temp.path}/task_center.json',
        now: () => DateTime.utc(2026, 6, 16, 13),
        idGenerator: _IdSequence().next,
      );
      final controller = TaskCenterController(store: store);
      final workspace = await controller.createWorkspace(title: 'UI Workspace');
      await controller.createTask(
        workspaceId: workspace.id,
        title: 'Design board',
        status: TaskCenterStatus.todo,
      );
      await controller.createTask(
        workspaceId: workspace.id,
        title: 'Expose MCP API',
        status: TaskCenterStatus.done,
      );

      expect(controller.selectedWorkspace?.title, 'UI Workspace');
      expect(controller.selectedWorkspace?.tasks, hasLength(2));
      expect(
        controller.selectedWorkspace?.tasks.map((task) => task.status),
        containsAll(<TaskCenterStatus>[
          TaskCenterStatus.todo,
          TaskCenterStatus.done,
        ]),
      );
    },
  );

  test('TaskCenterBoard production source uses BoardView columns', () async {
    final source = await File(
      'lib/ui/components/task_center_board.dart',
    ).readAsString();

    expect(source, contains("import 'package:boardview/boardview.dart';"));
    expect(source, contains('BoardView('));
    expect(source, contains('TaskCenterStatus.values'));
    expect(source, contains('status.label'));
  });
}

class _IdSequence {
  int _next = 1;

  String next() => 'id-${_next++}';
}
