import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/agent_event.dart';
import 'package:ianvs_acp/task_center/task_center_agent_api.dart';
import 'package:ianvs_acp/task_center/task_center_fast_agent_client.dart';
import 'package:ianvs_acp/task_center/task_center_models.dart';
import 'package:ianvs_acp/task_center/task_center_store.dart';

void main() {
  test('fast agent admits clear work without exposing local tools', () async {
    final temp = await Directory.systemTemp.createTemp('ianvs_fast_agent');
    addTearDown(() => temp.delete(recursive: true));
    final ids = _IdSequence();
    final store = TaskCenterStore(
      path: '${temp.path}/task_center.json',
      now: () => DateTime.utc(2026, 6, 18, 10),
      idGenerator: ids.next,
    );
    final workspace = await store.createWorkspace(
      title: 'bk-sec-ai',
      workspaceCwd: '/workspace/bk-sec-ai',
    );
    final client = TaskCenterFastAgentClient(
      api: TaskCenterAgentApi(store: store),
      agentName: 'codex-fast',
      workspaceCwd: '/workspace/bk-sec-ai',
    );

    await client.connect();
    final session = await client.createSession(cwd: '/workspace/bk-sec-ai');
    final events = await client
        .sendPrompt(
          sessionId: session.id,
          prompt: _prompt(
            workspaceId: workspace.id,
            message: '查询当前项目未完成任务数量，并把结果交付到任务中心。',
          ),
        )
        .toList();

    expect(
      events.any((event) => event.type == AgentEventType.agentTextDelta),
      isTrue,
    );
    final toolNames = _toolNames(events);
    expect(toolNames, isNotEmpty);
    expect(toolNames, everyElement(startsWith('task_center_')));
    expect(toolNames, isNot(contains('exec_command')));

    final snapshot = await store.load();
    final task = snapshot.workspaces.single.tasks.single;
    expect(task.status, TaskCenterStatus.inProgress);
    expect(task.currentOwner.kind, TaskCenterOwnerKind.workAgent);
    expect(task.currentOwner.agentName, 'codex-worker');
    expect(task.workRuns.single.agentName, 'codex-worker');
  });

  test('fast agent admits clear English delivery work', () async {
    final temp = await Directory.systemTemp.createTemp('ianvs_fast_agent');
    addTearDown(() => temp.delete(recursive: true));
    final ids = _IdSequence();
    final store = TaskCenterStore(
      path: '${temp.path}/task_center.json',
      now: () => DateTime.utc(2026, 6, 18, 10),
      idGenerator: ids.next,
    );
    final workspace = await store.createWorkspace(title: 'bk-sec-ai');
    final client = TaskCenterFastAgentClient(
      api: TaskCenterAgentApi(store: store),
      agentName: 'codex-fast',
      workspaceCwd: '/workspace/bk-sec-ai',
    );

    await client.connect();
    final session = await client.createSession(cwd: '/workspace/bk-sec-ai');
    await client
        .sendPrompt(
          sessionId: session.id,
          prompt: _prompt(
            workspaceId: workspace.id,
            message:
                'QA: count Task Center tasks by status and deliver DONE with counts.',
          ),
        )
        .drain<void>();

    final snapshot = await store.load();
    final task = snapshot.workspaces.single.tasks.single;
    expect(task.readiness, TaskCenterReadiness.ready);
    expect(task.status, TaskCenterStatus.inProgress);
    expect(task.currentOwner.kind, TaskCenterOwnerKind.workAgent);
  });

  test('fast agent routes English complex planning work to thinking', () async {
    final temp = await Directory.systemTemp.createTemp('ianvs_fast_agent');
    addTearDown(() => temp.delete(recursive: true));
    final ids = _IdSequence();
    final store = TaskCenterStore(
      path: '${temp.path}/task_center.json',
      now: () => DateTime.utc(2026, 6, 18, 10),
      idGenerator: ids.next,
    );
    final workspace = await store.createWorkspace(title: 'bk-sec-ai');
    final client = TaskCenterFastAgentClient(
      api: TaskCenterAgentApi(store: store),
      agentName: 'codex-fast',
      workspaceCwd: '/workspace/bk-sec-ai',
    );

    await client.connect();
    final session = await client.createSession(cwd: '/workspace/bk-sec-ai');
    await client
        .sendPrompt(
          sessionId: session.id,
          prompt: _prompt(
            workspaceId: workspace.id,
            message:
                'Design a multi-agent routing strategy and analyze risks before execution.',
          ),
        )
        .drain<void>();

    final snapshot = await store.load();
    final task = snapshot.workspaces.single.tasks.single;
    expect(task.readiness, TaskCenterReadiness.needsThinking);
    expect(task.status, TaskCenterStatus.inProgress);
    expect(task.currentOwner.kind, TaskCenterOwnerKind.thinkingAgent);
    expect(task.currentOwner.agentName, 'codex-thinking');
  });

  test('fast agent hands fully confirmed human task to worker', () async {
    final temp = await Directory.systemTemp.createTemp('ianvs_fast_agent');
    addTearDown(() => temp.delete(recursive: true));
    final ids = _IdSequence();
    final store = TaskCenterStore(
      path: '${temp.path}/task_center.json',
      now: () => DateTime.utc(2026, 6, 18, 10),
      idGenerator: ids.next,
    );
    final workspace = await store.createWorkspace(title: 'bk-sec-ai');
    final task = await store.createTask(
      workspaceId: workspace.id,
      title: 'Confirmed routing task',
      humanQuestions: const <TaskCenterHumanQuestion>[
        TaskCenterHumanQuestion(
          id: 'question-1',
          question: 'Confirm scope?',
          answer: '确认可以继续。',
          resolved: true,
        ),
      ],
      currentOwner: const TaskCenterTaskOwner.fastAgent('codex-fast'),
      readiness: TaskCenterReadiness.needsInfo,
      status: TaskCenterStatus.inProgress,
    );
    final client = TaskCenterFastAgentClient(
      api: TaskCenterAgentApi(store: store),
      agentName: 'codex-fast',
      workspaceCwd: '/workspace/bk-sec-ai',
    );

    await client.connect();
    final session = await client.createSession(cwd: '/workspace/bk-sec-ai');
    final events = await client
        .sendPrompt(
          sessionId: session.id,
          prompt: _prompt(
            workspaceId: workspace.id,
            message:
                'Human confirmation answered Task ID ${task.id} Task ${task.title} Answer 确认可以继续。',
          ),
        )
        .toList();

    final toolNames = _toolNames(events);
    expect(toolNames, contains('task_center_transfer_owner'));
    expect(toolNames, contains('task_center_start_work_run'));

    final snapshot = await store.load();
    final updated = snapshot.workspaces.single.tasks.single;
    expect(updated.readiness, TaskCenterReadiness.ready);
    expect(updated.status, TaskCenterStatus.inProgress);
    expect(updated.currentOwner.kind, TaskCenterOwnerKind.workAgent);
    expect(updated.currentOwner.agentName, 'codex-worker');
    expect(updated.workRuns.single.agentName, 'codex-worker');
  });

  test('fast agent sends unclear input to human confirmation only', () async {
    final temp = await Directory.systemTemp.createTemp('ianvs_fast_agent');
    addTearDown(() => temp.delete(recursive: true));
    final ids = _IdSequence();
    final store = TaskCenterStore(
      path: '${temp.path}/task_center.json',
      now: () => DateTime.utc(2026, 6, 18, 10),
      idGenerator: ids.next,
    );
    final workspace = await store.createWorkspace(title: 'bk-sec-ai');
    final client = TaskCenterFastAgentClient(
      api: TaskCenterAgentApi(store: store),
      agentName: 'codex-fast',
      workspaceCwd: '/workspace/bk-sec-ai',
    );

    await client.connect();
    final session = await client.createSession(cwd: '/workspace/bk-sec-ai');
    final events = await client
        .sendPrompt(
          sessionId: session.id,
          prompt: _prompt(workspaceId: workspace.id, message: '看看这个'),
        )
        .toList();

    final toolNames = _toolNames(events);
    expect(toolNames, everyElement(startsWith('task_center_')));
    expect(toolNames, isNot(contains('exec_command')));

    final snapshot = await store.load();
    final task = snapshot.workspaces.single.tasks.single;
    expect(task.readiness, TaskCenterReadiness.waitingHuman);
    expect(task.currentOwner.kind, TaskCenterOwnerKind.human);
    expect(task.humanQuestions, hasLength(1));
  });
}

String _prompt({required String workspaceId, required String message}) {
  return '''
你是工作区的主快速agent，负责收件箱准入和快速响应。
workspace_id: $workspaceId
workspace_title: bk-sec-ai
workspace_cwd: /workspace/bk-sec-ai
thinking_agent: codex-thinking
work_agents: codex-worker

human_message:
$message

处理要求:
只能使用 task center 工具。
''';
}

List<String> _toolNames(List<AgentEvent> events) {
  return events
      .where((event) => event.type == AgentEventType.toolCall)
      .map((event) => event.metadata['title'])
      .whereType<String>()
      .toList(growable: false);
}

class _IdSequence {
  var _next = 0;

  String next() {
    _next += 1;
    return 'id-$_next';
  }
}
