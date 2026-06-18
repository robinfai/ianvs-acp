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
    'TaskCenterBoard renders workspace chat markdown tables and links',
    () async {
      final source = await File(
        'lib/ui/components/task_center_board.dart',
      ).readAsString();

      expect(
        source,
        contains(
          "import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';",
        ),
      );
      expect(source, contains('MarkdownBody('));
      expect(source, contains('data: message.content'));
      expect(source, contains('selectable: true'));
      expect(source, contains('onTapLink:'));
      expect(source, contains('_openWorkspaceChatLink'));
      expect(source, contains('tableBorder:'));
      expect(source, contains('a:'));
    },
  );

  test(
    'TaskCenterBoard sends workspace chat on Enter and keeps Shift Enter for newlines',
    () async {
      final source = await File(
        'lib/ui/components/task_center_board.dart',
      ).readAsString();

      expect(source, contains('onKeyEvent:'));
      expect(source, contains('LogicalKeyboardKey.enter'));
      expect(source, contains('HardwareKeyboard.instance.isShiftPressed'));
      expect(source, contains('KeyEventResult.handled'));
      expect(source, contains('KeyEventResult.ignored'));
      expect(source, contains('TextInputAction.newline'));
    },
  );

  test(
    'TaskCenterBoard streams fast agent replies in workspace chat',
    () async {
      final source = await File(
        'lib/ui/components/task_center_board.dart',
      ).readAsString();

      expect(source, contains('TaskCenterWorkspaceMessageReply'));
      expect(source, contains('Future<TaskCenterWorkspaceMessageReply>'));
      expect(source, contains('_streamingReply'));
      expect(source, contains('completedText'));
      expect(source, contains('fastAgentAlreadyPosted'));
      expect(source, contains('listWorkspaceChatMessages'));
      expect(source, contains('_workspaceChatMessagesWithStreamingReply'));
      expect(source, contains('ListenableBuilder'));
    },
  );

  test(
    'TaskCenterBoard keeps workspace chat pinned to latest messages',
    () async {
      final source = await File(
        'lib/ui/components/task_center_board.dart',
      ).readAsString();

      expect(source, contains('ScrollController'));
      expect(source, contains('_scrollToLatest'));
      expect(source, contains('Future<void>.delayed'));
      expect(source, contains('position.maxScrollExtent'));
      expect(source, isNot(contains('reverse: true')));
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

  test(
    'TaskCenterBoard defaults to workspace chat and groups Kanban with task details',
    () async {
      final source = await File(
        'lib/ui/components/task_center_board.dart',
      ).readAsString();

      expect(source, contains('_TaskCenterWorkspaceTabs'));
      expect(source, contains('initialIndex: 0'));
      expect(source, contains("Tab(text: 'Workspace Chat')"));
      expect(source, contains("Tab(text: 'Kanban')"));
      expect(source, contains('_KanbanTaskWorkspace'));
      expect(source, contains('_WorkspaceChatPanel('));
      expect(source, contains('_TaskProtocolPanel('));
      expect(
        source.indexOf('_WorkspaceChatPanel('),
        lessThan(source.indexOf('_KanbanTaskWorkspace')),
      );
    },
  );

  test(
    'TaskCenterBoard exposes Agents tab with session list and transcript',
    () async {
      final source = await File(
        'lib/ui/components/task_center_board.dart',
      ).readAsString();

      expect(source, contains("Tab(text: 'Agents')"));
      expect(source, contains('_TaskCenterAgentsPanel'));
      expect(source, contains('sessionControllers'));
      expect(source, contains('onSelectSession'));
      expect(source, contains('ChatTimeline('));
      expect(source, contains('_AgentSessionTile'));
      expect(source, contains('_agentSessionGroups'));
    },
  );

  test(
    'TaskCenterBoard renders live Agents transcript streaming text',
    () async {
      final source = await File(
        'lib/ui/components/task_center_board.dart',
      ).readAsString();

      expect(source, contains('_AgentTranscriptView'));
      expect(source, contains('_AgentTranscriptRunningBar'));
      expect(source, contains('messages: controller.messages'));
      expect(source, isNot(contains('_stableAgentTranscriptMessages')));
    },
  );

  test(
    'TaskCenterBoard collects active current sessions for Agents tab',
    () async {
      final source = await File(
        'lib/ui/components/task_center_board.dart',
      ).readAsString();

      expect(source, contains('_agentSessions('));
      expect(source, contains('controller.currentSession'));
      expect(source, contains('sessionsById'));
      expect(source, contains('copyWith(agentName: controller.agentName)'));
      expect(
        source.indexOf('_agentSessions(sessionControllers)'),
        lessThan(source.indexOf('b.displayTime.compareTo(a.displayTime)')),
      );
    },
  );

  test(
    'TaskCenterBoard lets humans answer waiting confirmations in workspace chat',
    () async {
      final source = await File(
        'lib/ui/components/task_center_board.dart',
      ).readAsString();

      expect(source, contains('_WaitingHumanConfirmations'));
      expect(source, contains('_WaitingHumanCard'));
      expect(source, contains('answerHumanQuestion('));
      expect(source, contains('TaskCenterReadiness.waitingHuman'));
      expect(source, contains('TaskCenterTaskOwner.fastAgent'));
      expect(source, contains('Human confirmation answered'));
      expect(source, contains('确认可以继续'));
      expect(source, contains('需要补充说明'));
      expect(source, contains('打回快速 agent'));

      final cardStart = source.indexOf('class _WaitingHumanCard');
      final cardEnd = source.indexOf('class _PendingHumanQuestion');
      final cardSource = source.substring(cardStart, cardEnd);

      expect(cardSource, contains('SingleChildScrollView('));
      expect(cardSource, isNot(contains('const Spacer()')));
    },
  );

  test(
    'TaskCenterBoard surfaces stalled worker recovery in workspace chat',
    () async {
      final source = await File(
        'lib/ui/components/task_center_board.dart',
      ).readAsString();

      expect(source, contains('_WorkerStalledRecoveries'));
      expect(source, contains('_WorkerStalledCard'));
      expect(source, contains('listStalledWork('));
      expect(source, contains('recoverStalledTask('));
      expect(source, contains('Worker stalled'));
      expect(source, contains('催一下 worker'));
      expect(source, contains('换一个 worker'));
      expect(source, contains('交回 fast agent'));
      expect(source, contains('转 thinking agent'));
      expect(source, contains('标记失败'));
      expect(source, isNot(contains('height: 166')));
      expect(source, contains('SingleChildScrollView('));
    },
  );

  test('TaskCenterBoard shows work run execution context', () async {
    final source = await File(
      'lib/ui/components/task_center_board.dart',
    ).readAsString();

    expect(source, contains('_TaskExecutionPanel'));
    expect(source, contains('Execution'));
    expect(source, contains('lastHeartbeatAt'));
    expect(source, contains('progressSummary'));
    expect(source, contains('workRuns'));
    expect(source, contains('_AgentSessionRunPill'));
  });

  test(
    'AcpClientApp refreshes task center after creating fast agent controller',
    () async {
      final source = await File('lib/app.dart').readAsString();

      expect(source, contains('_cachedControllerFor('));
      expect(
        source,
        contains('localToolAccess: TaskCenterAgentLocalToolAccess.disabled'),
      );
      expect(source, contains('_ensureAgentControllerVisible('));
      expect(source, contains('_ensureAgentControllerVisible(controller)'));
    },
  );
}

class _IdSequence {
  int _next = 1;

  String next() => 'id-${_next++}';
}
