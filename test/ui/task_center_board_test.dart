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
    expect(source, contains('BoardItem('));
    expect(source, contains('draggable: true'));
    expect(source, contains('onDropItem:'));
    expect(source, contains('widget.controller.moveTask('));
    expect(source, contains('TaskCenterStatus.values'));
    expect(source, contains('status.label'));
  });

  test(
    'TaskCenterBoard awaits text dialogs before disposing controllers',
    () async {
      final source = await File(
        'lib/ui/components/task_center_board.dart',
      ).readAsString();

      expect(source, contains('return await showDialog<String>('));
      expect(source, isNot(contains('return showDialog<String>(')));
    },
  );

  test('TaskCenterBoard sizes board columns from available width', () async {
    final source = await File(
      'lib/ui/components/task_center_board.dart',
    ).readAsString();

    expect(source, contains('LayoutBuilder('));
    expect(source, contains('_boardColumnWidth('));
  });

  test(
    'TaskCenterBoard clips BoardView hit testing to the board area',
    () async {
      final source = await File(
        'lib/ui/components/task_center_board.dart',
      ).readAsString();

      expect(source, contains('ClipRect('));
      expect(source, contains('child: BoardView('));
    },
  );

  test('TaskCenterBoard includes the task protocol side panel', () async {
    final source = await File(
      'lib/ui/components/task_center_board.dart',
    ).readAsString();

    expect(source, contains('_TaskProtocolPanel'));
    expect(source, contains('Acceptance'));
    expect(source, contains('Human Check'));
    expect(source, contains('Route'));
    expect(source, contains('Send to Thinking'));
    expect(source, contains('Ask Human'));
    expect(source, contains('Assign Work Agent'));
  });

  test(
    'TaskCenterBoard lets humans edit task titles in the protocol panel',
    () async {
      final source = await File(
        'lib/ui/components/task_center_board.dart',
      ).readAsString();

      expect(source, contains('_titleController'));
      expect(source, contains("label: 'Title'"));
      expect(source, contains('title: _titleController.text'));
    },
  );

  test(
    'TaskCenterBoard includes workspace chat with fast agent admission',
    () async {
      final source = await File(
        'lib/ui/components/task_center_board.dart',
      ).readAsString();

      expect(source, contains('Workspace Chat'));
      expect(source, contains('onSendWorkspaceMessage'));
      expect(source, contains('_WorkspaceChatPanel'));
      expect(source, contains('fast agent'));
    },
  );

  test(
    'TaskCenterBoard surfaces owner, readiness, and role settings',
    () async {
      final source = await File(
        'lib/ui/components/task_center_board.dart',
      ).readAsString();

      expect(source, contains('task.currentOwner.label'));
      expect(source, contains('task.readiness.label'));
      expect(source, contains('_WorkspaceAgentSettingsDialog'));
      expect(source, contains('fastAgentName'));
      expect(source, contains('thinkingAgentName'));
      expect(source, contains('workAgentNames'));
    },
  );
}

class _IdSequence {
  int _next = 1;

  String next() => 'id-${_next++}';
}
