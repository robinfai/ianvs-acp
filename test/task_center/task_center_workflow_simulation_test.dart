import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/task_center/task_center_agent_api.dart';
import 'package:ianvs_acp/task_center/task_center_store.dart';

void main() {
  test(
    'simple task flows from human to fast admission to worker delivery',
    () async {
      final harness = await _WorkflowHarness.create();
      addTearDown(harness.dispose);

      final workspaceId = await harness.createWorkspace();
      await harness.postHuman(workspaceId, '简单任务：把按钮文案改成保存');
      final taskId = await harness.createTask(workspaceId, '简单任务：改按钮文案');

      await harness.api.call('task_center_record_admission_decision', {
        'workspace_id': workspaceId,
        'task_id': taskId,
        'agent_name': 'codex-fast',
        'decision': 'accepted',
        'reason': '目标清晰，可以直接执行。',
      });
      await harness.api.call('task_center_claim_work_task', {
        'workspace_id': workspaceId,
        'task_id': taskId,
        'agent_name': 'codex-worker',
        'actor': 'codex-worker',
      });
      await harness.api.call('task_center_deliver_work_result', {
        'workspace_id': workspaceId,
        'task_id': taskId,
        'agent_name': 'codex-worker',
        'execution_result': '按钮文案已更新为“保存”。',
        'verification_notes': '文案检查通过。',
        'status': 'done',
      });

      final messages = await harness.messages(workspaceId);
      expect(messages.map((message) => message['role']), [
        'human',
        'fast_agent',
        'work_agent',
      ]);
      expect(messages.last['content'], '按钮文案已更新为“保存”。');
    },
  );

  test('medium task asks thinking before asking human', () async {
    final harness = await _WorkflowHarness.create();
    addTearDown(harness.dispose);

    final workspaceId = await harness.createWorkspace();
    await harness.postHuman(workspaceId, '中等任务：新增任务筛选，需要确认筛选字段');
    final taskId = await harness.createTask(workspaceId, '中等任务：任务筛选');

    await harness.api.call('task_center_record_admission_decision', {
      'workspace_id': workspaceId,
      'task_id': taskId,
      'agent_name': 'codex-fast',
      'decision': 'needs_thinking',
      'reason': '筛选字段和验收条件需要先整理。',
    });
    await harness.api.call('task_center_request_thinking_alignment', {
      'workspace_id': workspaceId,
      'task_id': taskId,
      'fast_agent_name': 'codex-fast',
      'thinking_agent_name': 'codex-thinking',
      'question': '请整理需要人工确认的筛选字段。',
    });
    await harness.api.call('task_center_post_workspace_message', {
      'workspace_id': workspaceId,
      'role': 'thinking_agent',
      'actor': 'codex-thinking',
      'agent_name': 'codex-thinking',
      'task_id': taskId,
      'content': '建议 ask human：按状态、负责人、更新时间筛选是否足够？',
    });
    await harness.api.call('task_center_request_human_confirmation', {
      'workspace_id': workspaceId,
      'task_id': taskId,
      'questions': ['按状态、负责人、更新时间筛选是否足够？'],
      'actor': 'codex-thinking',
    });

    final messages = await harness.messages(workspaceId);
    expect(messages.map((message) => message['role']), [
      'human',
      'fast_agent',
      'fast_agent',
      'thinking_agent',
    ]);
    final listed = await harness.api.call('task_center_list_tasks', {
      'workspace_id': workspaceId,
    });
    final task =
        (listed['tasks'] as List<Object?>).single as Map<String, Object?>;
    expect((task['current_owner'] as Map<String, Object?>)['kind'], 'human');
  });

  test(
    'complex task completes after thinking, human confirmation, and worker delivery',
    () async {
      final harness = await _WorkflowHarness.create();
      addTearDown(harness.dispose);

      final workspaceId = await harness.createWorkspace();
      await harness.postHuman(workspaceId, '复杂任务：重构任务中心准入、执行和验收链路');
      final taskId = await harness.createTask(workspaceId, '复杂任务：任务中心链路');

      await harness.api.call('task_center_record_admission_decision', {
        'workspace_id': workspaceId,
        'task_id': taskId,
        'agent_name': 'codex-fast',
        'decision': 'needs_thinking',
        'reason': '影响范围大，需要先拆验收清单。',
      });
      await harness.api.call('task_center_request_thinking_alignment', {
        'workspace_id': workspaceId,
        'task_id': taskId,
        'fast_agent_name': 'codex-fast',
        'thinking_agent_name': 'codex-thinking',
        'question': '请拆出人工需要确认的范围和验收条件。',
      });
      final waiting = await harness.api.call(
        'task_center_request_human_confirmation',
        {
          'workspace_id': workspaceId,
          'task_id': taskId,
          'questions': ['是否必须覆盖简单、中等、复杂三类任务？'],
          'actor': 'codex-thinking',
        },
      );
      final waitingTask = waiting['task'] as Map<String, Object?>;
      final question =
          (waitingTask['human_questions'] as List<Object?>).single
              as Map<String, Object?>;
      await harness.api.call('task_center_answer_human_question', {
        'workspace_id': workspaceId,
        'task_id': taskId,
        'question_id': question['id'],
        'answer': '必须覆盖三类任务。',
        'actor': 'human',
      });
      await harness.api.call('task_center_claim_work_task', {
        'workspace_id': workspaceId,
        'task_id': taskId,
        'agent_name': 'codex-worker',
        'actor': 'codex-worker',
      });
      await harness.api.call('task_center_deliver_work_result', {
        'workspace_id': workspaceId,
        'task_id': taskId,
        'agent_name': 'codex-worker',
        'execution_result': '已覆盖三类任务链路并完成验证。',
        'verification_notes': '简单、中等、复杂流程测试通过。',
        'status': 'done',
      });

      final messages = await harness.messages(workspaceId);
      expect(messages.first['role'], 'human');
      expect(messages.last['role'], 'work_agent');
      expect(messages.last['content'], '已覆盖三类任务链路并完成验证。');

      final listed = await harness.api.call('task_center_list_tasks', {
        'workspace_id': workspaceId,
      });
      final task =
          (listed['tasks'] as List<Object?>).single as Map<String, Object?>;
      expect(task['status'], 'done');
      expect(task['execution_result'], '已覆盖三类任务链路并完成验证。');
    },
  );
}

class _WorkflowHarness {
  _WorkflowHarness._(this.temp, this.api);

  final Directory temp;
  final TaskCenterAgentApi api;

  static Future<_WorkflowHarness> create() async {
    final temp = await Directory.systemTemp.createTemp(
      'ianvs_task_center_workflow',
    );
    final ids = _IdSequence();
    return _WorkflowHarness._(
      temp,
      TaskCenterAgentApi(
        store: TaskCenterStore(
          path: '${temp.path}/task_center.json',
          now: () => DateTime.utc(2026, 6, 17, 14),
          idGenerator: ids.next,
        ),
      ),
    );
  }

  Future<void> dispose() => temp.delete(recursive: true);

  Future<String> createWorkspace() async {
    final result = await api.call('task_center_create_workspace', {
      'title': '测试workspace',
      'fast_agent_name': 'codex-fast',
      'thinking_agent_name': 'codex-thinking',
      'work_agent_names': ['codex-worker'],
    });
    return (result['workspace'] as Map<String, Object?>)['id'] as String;
  }

  Future<void> postHuman(String workspaceId, String content) async {
    await api.call('task_center_post_workspace_message', {
      'workspace_id': workspaceId,
      'role': 'human',
      'actor': 'human',
      'content': content,
    });
  }

  Future<String> createTask(String workspaceId, String title) async {
    final result = await api.call('task_center_create_task', {
      'workspace_id': workspaceId,
      'title': title,
      'current_owner': {'kind': 'fast_agent', 'agent_name': 'codex-fast'},
    });
    return (result['task'] as Map<String, Object?>)['id'] as String;
  }

  Future<List<Map<String, Object?>>> messages(String workspaceId) async {
    final listed = await api.call('task_center_list_workspace_messages', {
      'workspace_id': workspaceId,
    });
    return (listed['messages'] as List<Object?>)
        .map((message) => Map<String, Object?>.from(message as Map))
        .toList(growable: false);
  }
}

class _IdSequence {
  int _next = 1;

  String next() => 'id-${_next++}';
}
