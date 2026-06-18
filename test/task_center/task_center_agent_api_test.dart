import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/task_center/task_center_agent_api.dart';
import 'package:ianvs_acp/task_center/task_center_models.dart';
import 'package:ianvs_acp/task_center/task_center_store.dart';

void main() {
  test('agent API creates workspace and maintains task status', () async {
    final temp = await Directory.systemTemp.createTemp('ianvs_task_center_api');
    addTearDown(() => temp.delete(recursive: true));
    final ids = _IdSequence();
    final store = TaskCenterStore(
      path: '${temp.path}/task_center.json',
      now: () => DateTime.utc(2026, 6, 16, 11),
      idGenerator: ids.next,
    );
    final api = TaskCenterAgentApi(store: store);

    final createdWorkspace = await api.call('task_center_create_workspace', {
      'title': 'Agent managed workspace',
    });
    final workspace = createdWorkspace['workspace'] as Map<String, Object?>;
    expect(workspace['id'], 'id-1');

    final createdTask = await api.call('task_center_create_task', {
      'workspace_id': 'id-1',
      'title': 'Move me',
      'description': 'Agent will update this status.',
      'status': 'todo',
    });
    final task = createdTask['task'] as Map<String, Object?>;
    expect(task['id'], 'id-2');
    expect(task['status'], 'todo');

    final movedTask = await api.call('task_center_move_task', {
      'workspace_id': 'id-1',
      'task_id': 'id-2',
      'status': 'done',
      'index': 0,
    });
    expect((movedTask['task'] as Map<String, Object?>)['status'], 'done');

    final listed = await api.call('task_center_list_tasks', {
      'workspace_id': 'id-1',
    });
    final tasks = listed['tasks'] as List<Object?>;
    expect(tasks, hasLength(1));
    expect((tasks.single as Map<String, Object?>)['status'], 'done');
  });

  test('agent API completes task when work result is delivered', () async {
    final temp = await Directory.systemTemp.createTemp('ianvs_task_center_api');
    addTearDown(() => temp.delete(recursive: true));
    final ids = _IdSequence();
    final api = TaskCenterAgentApi(
      store: TaskCenterStore(
        path: '${temp.path}/task_center.json',
        now: () => DateTime.utc(2026, 6, 17, 13),
        idGenerator: ids.next,
      ),
    );

    final workspaceResult = await api.call('task_center_create_workspace', {
      'title': 'Delivery workspace',
    });
    final workspace = workspaceResult['workspace'] as Map<String, Object?>;
    final workspaceId = workspace['id'] as String;

    final taskResult = await api.call('task_center_create_task', {
      'workspace_id': workspaceId,
      'title': 'Deliver default status',
      'current_owner': {'kind': 'work_agent', 'agent_name': 'codex-worker'},
      'readiness': 'ready',
    });
    final task = taskResult['task'] as Map<String, Object?>;
    final taskId = task['id'] as String;

    final delivered = await api.call('task_center_deliver_work_result', {
      'workspace_id': workspaceId,
      'task_id': taskId,
      'agent_name': 'codex-worker',
      'execution_result': 'Finished and verified.',
    });

    expect((delivered['task'] as Map<String, Object?>)['status'], 'done');
  });

  test('agent API treats in-progress delivery status as completed', () async {
    final temp = await Directory.systemTemp.createTemp('ianvs_task_center_api');
    addTearDown(() => temp.delete(recursive: true));
    final ids = _IdSequence();
    final api = TaskCenterAgentApi(
      store: TaskCenterStore(
        path: '${temp.path}/task_center.json',
        now: () => DateTime.utc(2026, 6, 17, 14),
        idGenerator: ids.next,
      ),
    );

    final workspaceResult = await api.call('task_center_create_workspace', {
      'title': 'Delivery workspace',
    });
    final workspace = workspaceResult['workspace'] as Map<String, Object?>;
    final workspaceId = workspace['id'] as String;

    final taskResult = await api.call('task_center_create_task', {
      'workspace_id': workspaceId,
      'title': 'Delivered but marked in progress',
      'status': 'in_progress',
      'current_owner': {'kind': 'work_agent', 'agent_name': 'codex-worker'},
      'readiness': 'ready',
    });
    final task = taskResult['task'] as Map<String, Object?>;
    final taskId = task['id'] as String;

    final delivered = await api.call('task_center_deliver_work_result', {
      'workspace_id': workspaceId,
      'task_id': taskId,
      'agent_name': 'codex-worker',
      'execution_result': 'Finished and verified.',
      'status': 'in_progress',
    });

    expect((delivered['task'] as Map<String, Object?>)['status'], 'done');
  });

  test('agent API exposes a discoverable tool catalog', () {
    final api = TaskCenterAgentApi(store: TaskCenterStore(path: 'unused.json'));

    expect(api.toolNames, contains('task_center_create_workspace'));
    expect(api.toolNames, contains('task_center_create_task'));
    expect(api.toolNames, contains('task_center_update_task'));
    expect(api.toolNames, contains('task_center_move_task'));
    expect(api.toolNames, contains('task_center_list_workspaces'));
    expect(api.toolNames, contains('task_center_list_tasks'));
    expect(api.toolNames, contains('task_center_delete_task'));
    expect(api.toolNames, contains('task_center_configure_workspace_agents'));
    expect(api.toolNames, contains('task_center_update_task_details'));
    expect(api.toolNames, contains('task_center_set_acceptance'));
    expect(api.toolNames, contains('task_center_transfer_owner'));
    expect(api.toolNames, contains('task_center_request_human_confirmation'));
    expect(api.toolNames, contains('task_center_answer_human_question'));
    expect(api.toolNames, contains('task_center_list_role_tasks'));
    expect(api.toolNames, contains('task_center_claim_work_task'));
    expect(api.toolNames, contains('task_center_record_execution_result'));
    expect(api.toolNames, contains('task_center_list_task_events'));
    expect(api.toolNames, contains('task_center_post_workspace_message'));
    expect(api.toolNames, contains('task_center_list_workspace_messages'));
    expect(api.toolNames, contains('task_center_record_admission_decision'));
    expect(api.toolNames, contains('task_center_request_thinking_alignment'));
    expect(api.toolNames, contains('task_center_deliver_work_result'));
  });

  test('agent API starts heartbeats and recovers stalled work', () async {
    final temp = await Directory.systemTemp.createTemp('ianvs_task_center_api');
    addTearDown(() => temp.delete(recursive: true));
    final ids = _IdSequence();
    final api = TaskCenterAgentApi(
      store: TaskCenterStore(
        path: '${temp.path}/task_center.json',
        now: () => DateTime.utc(2026, 6, 17, 18),
        idGenerator: ids.next,
      ),
    );

    final workspaceResult = await api.call('task_center_create_workspace', {
      'title': 'Recovery API',
      'fast_agent_name': 'codex-fast',
      'thinking_agent_name': 'codex-thinking',
      'work_agent_names': ['codex-worker', 'codex-worker-2'],
    });
    final workspaceId =
        (workspaceResult['workspace'] as Map<String, Object?>)['id'] as String;

    final taskResult = await api.call('task_center_create_task', {
      'workspace_id': workspaceId,
      'title': 'Recover me',
    });
    final taskId = (taskResult['task'] as Map<String, Object?>)['id'] as String;

    final started = await api.call('task_center_start_work_run', {
      'workspace_id': workspaceId,
      'task_id': taskId,
      'agent_name': 'codex-worker',
      'session_id': 'session-1',
      'progress_summary': 'Starting.',
    });
    final run =
        (((started['task'] as Map<String, Object?>)['work_runs']
                    as List<Object?>)
                .single
            as Map<String, Object?>);
    expect(run['state'], 'running');

    final heartbeat = await api.call('task_center_heartbeat_work_run', {
      'workspace_id': workspaceId,
      'task_id': taskId,
      'run_id': run['id'],
      'state': 'running',
      'progress_summary': 'Still working.',
    });
    expect(
      ((((heartbeat['task'] as Map<String, Object?>)['work_runs']
                  as List<Object?>)
              .single
          as Map<String, Object?>)['progress_summary']),
      'Still working.',
    );

    final blocker = await api.call('task_center_report_work_blocker', {
      'workspace_id': workspaceId,
      'task_id': taskId,
      'run_id': run['id'],
      'blocker_type': 'missing_acceptance',
      'blocker_reason': 'Acceptance is not clear.',
    });
    expect(
      (blocker['task'] as Map<String, Object?>)['readiness'],
      'needs_info',
    );

    final recovered = await api.call('task_center_recover_stalled_task', {
      'workspace_id': workspaceId,
      'task_id': taskId,
      'action': 'reassign_worker',
      'agent_name': 'codex-worker-2',
      'reason': 'Original worker blocked.',
    });
    expect(
      ((recovered['task'] as Map<String, Object?>)['current_owner']
          as Map<String, Object?>)['agent_name'],
      'codex-worker-2',
    );
  });

  test('agent API exposes worker recovery tools in catalog', () {
    final api = TaskCenterAgentApi(store: TaskCenterStore(path: 'unused.json'));

    expect(api.toolNames, contains('task_center_start_work_run'));
    expect(api.toolNames, contains('task_center_heartbeat_work_run'));
    expect(api.toolNames, contains('task_center_report_work_blocker'));
    expect(api.toolNames, contains('task_center_release_work_task'));
    expect(api.toolNames, contains('task_center_recover_stalled_task'));
    expect(api.toolNames, contains('task_center_list_stalled_work'));
  });

  test('agent API exposes intent actions for the task protocol', () async {
    final temp = await Directory.systemTemp.createTemp('ianvs_task_center_api');
    addTearDown(() => temp.delete(recursive: true));
    final ids = _IdSequence();
    final api = TaskCenterAgentApi(
      store: TaskCenterStore(
        path: '${temp.path}/task_center.json',
        now: () => DateTime.utc(2026, 6, 17, 10),
        idGenerator: ids.next,
      ),
    );

    final workspaceResult = await api.call('task_center_create_workspace', {
      'title': 'Protocol workspace',
    });
    final workspace = workspaceResult['workspace'] as Map<String, Object?>;
    final workspaceId = workspace['id'] as String;

    final configured = await api.call(
      'task_center_configure_workspace_agents',
      {
        'workspace_id': workspaceId,
        'fast_agent_name': 'quick-agent',
        'thinking_agent_name': 'thinking-agent',
        'work_agent_names': ['work-agent-1', 'work-agent-2'],
        'fast_agent_prompt': 'Collect context quickly.',
        'thinking_agent_prompt': 'Prepare human questions.',
        'work_agent_prompt': 'Validate before execution.',
      },
    );
    expect(
      ((configured['workspace'] as Map<String, Object?>)['agent_config']
          as Map<String, Object?>)['thinking_agent_name'],
      'thinking-agent',
    );

    final taskResult = await api.call('task_center_create_task', {
      'workspace_id': workspaceId,
      'title': 'Clarify execution goal',
      'objective': 'Make the task executable by a work agent.',
      'current_owner': {'kind': 'fast_agent', 'agent_name': 'quick-agent'},
      'readiness': 'needs_info',
    });
    final task = taskResult['task'] as Map<String, Object?>;
    final taskId = task['id'] as String;

    await api.call('task_center_set_acceptance', {
      'workspace_id': workspaceId,
      'task_id': taskId,
      'acceptance_criteria': ['Goal is clear', 'Checks are listed'],
      'actor': 'quick-agent',
    });

    final transferred = await api.call('task_center_transfer_owner', {
      'workspace_id': workspaceId,
      'task_id': taskId,
      'owner': {'kind': 'thinking_agent', 'agent_name': 'thinking-agent'},
      'readiness': 'needs_thinking',
      'route_reason': 'Needs a human decision checklist.',
      'actor': 'quick-agent',
    });
    expect(
      (((transferred['task'] as Map<String, Object?>)['current_owner']
          as Map<String, Object?>)['kind']),
      'thinking_agent',
    );

    final waiting = await api.call('task_center_request_human_confirmation', {
      'workspace_id': workspaceId,
      'task_id': taskId,
      'questions': ['Which checks are mandatory?'],
      'route_reason': 'Acceptance needs a human call.',
      'actor': 'thinking-agent',
    });
    final waitingTask = waiting['task'] as Map<String, Object?>;
    final question =
        (waitingTask['human_questions'] as List<Object?>).single
            as Map<String, Object?>;
    expect(
      (waitingTask['current_owner'] as Map<String, Object?>)['kind'],
      'human',
    );

    await api.call('task_center_answer_human_question', {
      'workspace_id': workspaceId,
      'task_id': taskId,
      'question_id': question['id'],
      'answer': 'Both listed checks are mandatory.',
      'actor': 'human',
    });

    await api.call('task_center_claim_work_task', {
      'workspace_id': workspaceId,
      'task_id': taskId,
      'agent_name': 'work-agent-1',
      'actor': 'work-agent-1',
    });

    final executed = await api.call('task_center_record_execution_result', {
      'workspace_id': workspaceId,
      'task_id': taskId,
      'execution_result': 'Completed the implementation.',
      'verification_notes': 'Tests passed for the task center workflow.',
      'actor': 'work-agent-1',
    });
    expect(
      (executed['task'] as Map<String, Object?>)['execution_result'],
      contains('Completed'),
    );

    final roleTasks = await api.call('task_center_list_role_tasks', {
      'workspace_id': workspaceId,
      'owner_kind': 'work_agent',
      'agent_name': 'work-agent-1',
    });
    expect(roleTasks['tasks'], isA<List<Object?>>());

    final events = await api.call('task_center_list_task_events', {
      'workspace_id': workspaceId,
      'task_id': taskId,
    });
    expect(events['events'], isA<List<Object?>>());
    expect(events['events'] as List<Object?>, isNotEmpty);
  });

  test('agent API treats recorded active worker results as delivery', () async {
    final temp = await Directory.systemTemp.createTemp('ianvs_agent_api');
    addTearDown(() => temp.delete(recursive: true));
    final store = TaskCenterStore(path: '${temp.path}/task_center.json');
    final api = TaskCenterAgentApi(store: store);
    final workspace = await store.createWorkspace(title: 'Worker delivery');
    final task = await store.createTask(
      workspaceId: workspace.id,
      title: 'Finish active worker task',
    );
    await store.startWorkRun(
      workspaceId: workspace.id,
      taskId: task.id,
      agentName: 'work-agent-1',
    );

    final recorded = await api.call('task_center_record_execution_result', {
      'workspace_id': workspace.id,
      'task_id': task.id,
      'execution_result': 'DONE from record fallback.',
      'verification_notes': 'No extra checks needed.',
      'actor': 'work-agent-1',
    });

    expect((recorded['task'] as Map<String, Object?>)['status'], 'done');

    final snapshot = await store.load();
    final updated = snapshot.workspaces.single.tasks.single;
    expect(updated.status, TaskCenterStatus.done);
    expect(updated.workRuns.single.state, TaskCenterWorkRunState.delivered);
    expect(
      snapshot.workspaces.single.chatMessages.single.content,
      contains('DONE'),
    );
  });

  test('agent API notifies after mutating task center state', () async {
    final temp = await Directory.systemTemp.createTemp('ianvs_task_center_api');
    addTearDown(() => temp.delete(recursive: true));
    final ids = _IdSequence();
    final notifications = <String>[];
    final api = TaskCenterAgentApi(
      store: TaskCenterStore(
        path: '${temp.path}/task_center.json',
        idGenerator: ids.next,
      ),
      onChanged: () async {
        notifications.add('changed');
      },
    );

    await api.call('task_center_create_workspace', {
      'title': 'Agent workspace',
    });
    expect(notifications, ['changed']);

    await api.call('task_center_list_workspaces', const <String, Object?>{});
    expect(notifications, ['changed']);

    await api.call('task_center_create_task', {
      'workspace_id': 'id-1',
      'title': 'Agent task',
    });
    expect(notifications, ['changed', 'changed']);
  });

  test('agent API posts and lists workspace chat messages', () async {
    final temp = await Directory.systemTemp.createTemp('ianvs_task_center_api');
    addTearDown(() => temp.delete(recursive: true));
    final ids = _IdSequence();
    final api = TaskCenterAgentApi(
      store: TaskCenterStore(
        path: '${temp.path}/task_center.json',
        now: () => DateTime.utc(2026, 6, 17, 12),
        idGenerator: ids.next,
      ),
    );

    final workspaceResult = await api.call('task_center_create_workspace', {
      'title': 'Workspace chat',
    });
    final workspace = workspaceResult['workspace'] as Map<String, Object?>;
    final workspaceId = workspace['id'] as String;

    final posted = await api.call('task_center_post_workspace_message', {
      'workspace_id': workspaceId,
      'role': 'fast_agent',
      'actor': 'quick-agent',
      'agent_name': 'quick-agent',
      'content': '已准入并创建任务。',
      'metadata': {'admission': 'accepted'},
    });
    final message = posted['message'] as Map<String, Object?>;
    expect(message['id'], 'id-2');
    expect(message['role'], 'fast_agent');
    expect(message['content'], '已准入并创建任务。');

    final listed = await api.call('task_center_list_workspace_messages', {
      'workspace_id': workspaceId,
    });
    final messages = listed['messages'] as List<Object?>;
    expect(messages, hasLength(1));
    expect((messages.single as Map<String, Object?>)['actor'], 'quick-agent');
  });

  test('agent API supports fast-thinking-worker group workflow', () async {
    final temp = await Directory.systemTemp.createTemp('ianvs_task_center_api');
    addTearDown(() => temp.delete(recursive: true));
    final ids = _IdSequence();
    final api = TaskCenterAgentApi(
      store: TaskCenterStore(
        path: '${temp.path}/task_center.json',
        now: () => DateTime.utc(2026, 6, 17, 13),
        idGenerator: ids.next,
      ),
    );

    final workspaceResult = await api.call('task_center_create_workspace', {
      'title': 'Workflow workspace',
      'fast_agent_name': 'codex-fast',
      'thinking_agent_name': 'codex-thinking',
      'work_agent_names': ['codex-worker'],
    });
    final workspace = workspaceResult['workspace'] as Map<String, Object?>;
    final workspaceId = workspace['id'] as String;

    final taskResult = await api.call('task_center_create_task', {
      'workspace_id': workspaceId,
      'title': '复杂任务准入',
      'current_owner': {'kind': 'fast_agent', 'agent_name': 'codex-fast'},
    });
    final task = taskResult['task'] as Map<String, Object?>;
    final taskId = task['id'] as String;

    final admission = await api.call('task_center_record_admission_decision', {
      'workspace_id': workspaceId,
      'task_id': taskId,
      'agent_name': 'codex-fast',
      'decision': 'needs_thinking',
      'reason': '需求有验收边界疑问，先找 thinking 对齐。',
    });
    expect(
      (admission['message'] as Map<String, Object?>)['metadata'],
      containsPair('admission', 'needs_thinking'),
    );

    final aligned = await api.call('task_center_request_thinking_alignment', {
      'workspace_id': workspaceId,
      'task_id': taskId,
      'fast_agent_name': 'codex-fast',
      'thinking_agent_name': 'codex-thinking',
      'question': '请梳理需要 ask human 的确认清单。',
      'route_reason': '验收条件不够明确。',
    });
    final alignedTask = aligned['task'] as Map<String, Object?>;
    expect(
      (alignedTask['current_owner'] as Map<String, Object?>)['kind'],
      'thinking_agent',
    );

    await api.call('task_center_request_human_confirmation', {
      'workspace_id': workspaceId,
      'task_id': taskId,
      'questions': ['是否需要保留审计记录？'],
      'actor': 'codex-thinking',
    });

    await api.call('task_center_claim_work_task', {
      'workspace_id': workspaceId,
      'task_id': taskId,
      'agent_name': 'codex-worker',
      'actor': 'codex-worker',
    });

    final delivered = await api.call('task_center_deliver_work_result', {
      'workspace_id': workspaceId,
      'task_id': taskId,
      'agent_name': 'codex-worker',
      'execution_result': '完成实现并记录审计。',
      'verification_notes': '简单、中等、复杂流程均有测试覆盖。',
      'status': 'done',
    });
    expect(
      (delivered['task'] as Map<String, Object?>)['execution_result'],
      '完成实现并记录审计。',
    );
    expect((delivered['task'] as Map<String, Object?>)['status'], 'done');

    final listed = await api.call('task_center_list_workspace_messages', {
      'workspace_id': workspaceId,
    });
    final messages = listed['messages'] as List<Object?>;
    expect(
      messages.map((message) => (message as Map<String, Object?>)['role']),
      containsAll(['fast_agent', 'work_agent']),
    );
    expect(
      messages.last as Map<String, Object?>,
      containsPair('content', '完成实现并记录审计。'),
    );
  });
}

class _IdSequence {
  int _next = 1;

  String next() => 'id-${_next++}';
}
