import 'dart:convert';
import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart' as mcp;

import '../config/acp_client_config.dart';
import 'task_center_agent_api.dart';
import 'task_center_store.dart';

class TaskCenterMcpHost {
  TaskCenterMcpHost({
    required this.store,
    this.onChanged,
    this.host = '127.0.0.1',
    this.startPort = 38971,
    this.maxPortAttempts = 20,
  });

  static const String serverName = 'ianvs-task-center';
  static const String snapshotResourceUri = 'task-center://snapshot';

  final TaskCenterStore store;
  final TaskCenterChanged? onChanged;
  final String host;
  final int startPort;
  final int maxPortAttempts;

  mcp.StreamableMcpServer? _server;
  int? _port;

  bool get isStarted => _server != null;

  String get url {
    final port = _port;
    if (port == null) {
      throw StateError('Task center MCP server has not started.');
    }
    return 'http://$host:$port/mcp';
  }

  McpServerConfig get mcpServerConfig {
    return McpServerConfig(
      raw: <String, dynamic>{'name': serverName, 'type': 'http', 'url': url},
    );
  }

  Future<void> start() async {
    if (_server != null) return;
    Object? lastError;
    for (var offset = 0; offset < maxPortAttempts; offset += 1) {
      final port = startPort + offset;
      final candidate = mcp.StreamableMcpServer(
        serverFactory: (_) => _createServer(),
        host: host,
        port: port,
        enableDnsRebindingProtection: true,
        allowedHosts: {host, 'localhost'},
      );
      try {
        await candidate.start();
        _server = candidate;
        _port = port;
        return;
      } on SocketException catch (error) {
        lastError = error;
        await candidate.stop();
      }
    }
    throw StateError('Could not start task center MCP server: $lastError');
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    _port = null;
    await server?.stop();
  }

  mcp.McpServer _createServer() {
    final api = TaskCenterAgentApi(store: store, onChanged: onChanged);
    final server = mcp.McpServer(
      const mcp.Implementation(
        name: serverName,
        version: '1.0.0',
        description: 'Local Ianvs task center tools.',
      ),
      options: const mcp.McpServerOptions(
        instructions:
            'Use these tools to create local task workspaces, add tasks, and keep task status current.',
      ),
    );

    for (final name in api.toolNames) {
      server.registerTool(
        name,
        description: _toolDescription(name),
        inputSchema: _toolInputSchema(name),
        callback: (args, _) async {
          final result = await api.call(name, Map<String, Object?>.from(args));
          return mcp.CallToolResult.fromStructuredContent(
            Map<String, dynamic>.from(result),
          );
        },
      );
    }

    server.registerResource(
      'task-center-snapshot',
      snapshotResourceUri,
      (
        description:
            'Current local task center workspace, task, and chat data.',
        mimeType: 'application/json',
      ),
      (uri, _) async {
        final snapshot = await store.load();
        return mcp.ReadResourceResult(
          contents: <mcp.ResourceContents>[
            mcp.TextResourceContents(
              uri: uri.toString(),
              mimeType: 'application/json',
              text: jsonEncode(snapshot.toJson()),
            ),
          ],
        );
      },
    );

    return server;
  }
}

String _toolDescription(String name) {
  return switch (name) {
    'task_center_create_workspace' => 'Create a local task workspace.',
    'task_center_list_workspaces' => 'List local task workspaces.',
    'task_center_configure_workspace_agents' =>
      'Configure role agents for a task workspace.',
    'task_center_create_task' => 'Create a task in a workspace.',
    'task_center_update_task' =>
      'Update task title, protocol fields, status, or metadata.',
    'task_center_update_task_details' =>
      'Update human-readable task details and objective.',
    'task_center_set_acceptance' => 'Set task acceptance criteria.',
    'task_center_transfer_owner' =>
      'Transfer a task to the next owner role or agent.',
    'task_center_request_human_confirmation' =>
      'Request human confirmation with explicit questions.',
    'task_center_answer_human_question' =>
      'Record an answer to a human confirmation question.',
    'task_center_list_role_tasks' =>
      'List tasks currently assigned to an owner role.',
    'task_center_claim_work_task' => 'Claim a task for a concrete work agent.',
    'task_center_start_work_run' =>
      'Start a tracked work run for a concrete work agent.',
    'task_center_heartbeat_work_run' =>
      'Update heartbeat and progress for a tracked work run.',
    'task_center_report_work_blocker' =>
      'Report why a worker cannot continue and route the task.',
    'task_center_release_work_task' =>
      'Release a claimed work task back to the workspace.',
    'task_center_recover_stalled_task' =>
      'Apply a human or agent recovery action to stalled work.',
    'task_center_list_stalled_work' =>
      'List tasks with stale, blocked, failed, released, or missing worker runs.',
    'task_center_record_execution_result' =>
      'Record execution and verification notes for a task.',
    'task_center_list_task_events' => 'List task event history.',
    'task_center_move_task' => 'Move a task to a status column and position.',
    'task_center_list_tasks' => 'List tasks in a workspace.',
    'task_center_delete_task' => 'Delete a task from a workspace.',
    'task_center_post_workspace_message' =>
      'Post a workspace chat message for human-agent coordination.',
    'task_center_list_workspace_messages' =>
      'List workspace chat messages for fast-agent admission context.',
    'task_center_record_admission_decision' =>
      'Record the fast agent inbox admission decision in workspace chat.',
    'task_center_request_thinking_alignment' =>
      'Transfer a task to the thinking agent and record the alignment request.',
    'task_center_deliver_work_result' =>
      'Record worker execution result and deliver it to workspace chat.',
    _ => 'Task center tool.',
  };
}

mcp.JsonObject _toolInputSchema(String name) {
  return switch (name) {
    'task_center_create_workspace' => _schema(
      properties: <String, mcp.JsonSchema>{
        'title': _stringSchema('Workspace title.'),
        'description': _stringSchema('Optional workspace description.'),
        'workspace_cwd': _stringSchema(
          'Absolute working directory agents should use for this workspace.',
        ),
        'fast_agent_name': _stringSchema('Main fast agent name.'),
        'thinking_agent_name': _stringSchema('Main thinking agent name.'),
        'work_agent_names': _stringArraySchema('Main work agent names.'),
        'fast_agent_prompt': _stringSchema(
          'Workspace-level prompt supplement for the fast agent role.',
        ),
        'thinking_agent_prompt': _stringSchema(
          'Workspace-level prompt supplement for the thinking agent role.',
        ),
        'work_agent_prompt': _stringSchema(
          'Workspace-level prompt supplement for work agents.',
        ),
      },
      required: const <String>['title'],
    ),
    'task_center_list_workspaces' => _schema(),
    'task_center_configure_workspace_agents' => _schema(
      properties: <String, mcp.JsonSchema>{
        'workspace_id': _stringSchema('Target workspace id.'),
        'workspace_cwd': _stringSchema(
          'Absolute working directory agents should use for this workspace.',
        ),
        'fast_agent_name': _stringSchema('Main fast agent name.'),
        'thinking_agent_name': _stringSchema('Main thinking agent name.'),
        'work_agent_names': _stringArraySchema('Main work agent names.'),
        'fast_agent_prompt': _stringSchema(
          'Workspace-level prompt supplement for the fast agent role.',
        ),
        'thinking_agent_prompt': _stringSchema(
          'Workspace-level prompt supplement for the thinking agent role.',
        ),
        'work_agent_prompt': _stringSchema(
          'Workspace-level prompt supplement for work agents.',
        ),
      },
      required: const <String>['workspace_id'],
    ),
    'task_center_create_task' => _schema(
      properties: <String, mcp.JsonSchema>{
        'workspace_id': _stringSchema('Target workspace id.'),
        'title': _stringSchema('Task title.'),
        'description': _stringSchema('Optional task description.'),
        'details': _stringSchema('Human-editable task details.'),
        'objective': _stringSchema('Clear task objective.'),
        'acceptance_criteria': _stringArraySchema('Acceptance criteria.'),
        'current_owner': _ownerSchema(),
        'suggested_owner': _ownerSchema(),
        'readiness': _readinessSchema(),
        'route_reason': _stringSchema('Reason for current routing.'),
        'status': _statusSchema(),
        'metadata': _objectSchema('Optional task metadata.'),
      },
      required: const <String>['workspace_id', 'title'],
    ),
    'task_center_update_task' => _schema(
      properties: <String, mcp.JsonSchema>{
        'workspace_id': _stringSchema('Target workspace id.'),
        'task_id': _stringSchema('Task id.'),
        'title': _stringSchema('New title.'),
        'description': _stringSchema('New description.'),
        'details': _stringSchema('New task details.'),
        'objective': _stringSchema('New task objective.'),
        'acceptance_criteria': _stringArraySchema('Acceptance criteria.'),
        'current_owner': _ownerSchema(),
        'suggested_owner': _ownerSchema(),
        'readiness': _readinessSchema(),
        'route_reason': _stringSchema('Reason for current routing.'),
        'execution_result': _stringSchema('Execution result.'),
        'verification_notes': _stringSchema('Verification notes.'),
        'status': _statusSchema(),
        'metadata': _objectSchema('Replacement task metadata.'),
      },
      required: const <String>['workspace_id', 'task_id'],
    ),
    'task_center_update_task_details' => _schema(
      properties: <String, mcp.JsonSchema>{
        'workspace_id': _stringSchema('Target workspace id.'),
        'task_id': _stringSchema('Task id.'),
        'description': _stringSchema('New description.'),
        'details': _stringSchema('New task details.'),
        'objective': _stringSchema('New task objective.'),
      },
      required: const <String>['workspace_id', 'task_id'],
    ),
    'task_center_set_acceptance' => _schema(
      properties: <String, mcp.JsonSchema>{
        'workspace_id': _stringSchema('Target workspace id.'),
        'task_id': _stringSchema('Task id.'),
        'acceptance_criteria': _stringArraySchema('Acceptance criteria.'),
        'actor': _stringSchema('Actor recording the acceptance criteria.'),
      },
      required: const <String>[
        'workspace_id',
        'task_id',
        'acceptance_criteria',
      ],
    ),
    'task_center_transfer_owner' => _schema(
      properties: <String, mcp.JsonSchema>{
        'workspace_id': _stringSchema('Target workspace id.'),
        'task_id': _stringSchema('Task id.'),
        'owner': _ownerSchema(),
        'readiness': _readinessSchema(),
        'route_reason': _stringSchema('Reason for transferring this task.'),
        'actor': _stringSchema('Actor transferring the task.'),
      },
      required: const <String>['workspace_id', 'task_id', 'owner'],
    ),
    'task_center_request_human_confirmation' => _schema(
      properties: <String, mcp.JsonSchema>{
        'workspace_id': _stringSchema('Target workspace id.'),
        'task_id': _stringSchema('Task id.'),
        'questions': _stringArraySchema('Questions for the human operator.'),
        'route_reason': _stringSchema('Reason human input is required.'),
        'actor': _stringSchema('Actor requesting confirmation.'),
      },
      required: const <String>['workspace_id', 'task_id', 'questions'],
    ),
    'task_center_answer_human_question' => _schema(
      properties: <String, mcp.JsonSchema>{
        'workspace_id': _stringSchema('Target workspace id.'),
        'task_id': _stringSchema('Task id.'),
        'question_id': _stringSchema('Human question id.'),
        'answer': _stringSchema('Human answer.'),
        'actor': _stringSchema('Actor answering the question.'),
      },
      required: const <String>[
        'workspace_id',
        'task_id',
        'question_id',
        'answer',
      ],
    ),
    'task_center_list_role_tasks' => _schema(
      properties: <String, mcp.JsonSchema>{
        'workspace_id': _stringSchema('Target workspace id.'),
        'owner_kind': _ownerKindSchema(),
        'agent_name': _stringSchema('Optional concrete agent name.'),
      },
      required: const <String>['workspace_id', 'owner_kind'],
    ),
    'task_center_claim_work_task' => _schema(
      properties: <String, mcp.JsonSchema>{
        'workspace_id': _stringSchema('Target workspace id.'),
        'task_id': _stringSchema('Task id.'),
        'agent_name': _stringSchema('Concrete work agent name.'),
        'actor': _stringSchema('Actor claiming the task.'),
      },
      required: const <String>['workspace_id', 'task_id', 'agent_name'],
    ),
    'task_center_start_work_run' => _schema(
      properties: <String, mcp.JsonSchema>{
        'workspace_id': _stringSchema('Target workspace id.'),
        'task_id': _stringSchema('Task id.'),
        'agent_name': _stringSchema('Concrete work agent name.'),
        'session_id': _stringSchema('Optional ACP session id.'),
        'progress_summary': _stringSchema('Initial worker progress summary.'),
        'actor': _stringSchema('Actor starting this run.'),
      },
      required: const <String>['workspace_id', 'task_id', 'agent_name'],
    ),
    'task_center_heartbeat_work_run' => _schema(
      properties: <String, mcp.JsonSchema>{
        'workspace_id': _stringSchema('Target workspace id.'),
        'task_id': _stringSchema('Task id.'),
        'run_id': _stringSchema('Work run id.'),
        'state': _workRunStateSchema(),
        'progress_summary': _stringSchema('Latest worker progress summary.'),
        'next_check_minutes': mcp.JsonSchema.integer(
          description: 'Optional minutes until the next planned check.',
        ),
        'actor': _stringSchema('Actor updating this run.'),
      },
      required: const <String>['workspace_id', 'task_id', 'run_id', 'state'],
    ),
    'task_center_report_work_blocker' => _schema(
      properties: <String, mcp.JsonSchema>{
        'workspace_id': _stringSchema('Target workspace id.'),
        'task_id': _stringSchema('Task id.'),
        'run_id': _stringSchema('Work run id.'),
        'blocker_type': _workBlockerTypeSchema(),
        'blocker_reason': _stringSchema('Reason the worker cannot continue.'),
        'questions': _stringArraySchema('Questions for a human operator.'),
        'actor': _stringSchema('Actor reporting the blocker.'),
      },
      required: const <String>[
        'workspace_id',
        'task_id',
        'run_id',
        'blocker_type',
        'blocker_reason',
      ],
    ),
    'task_center_release_work_task' => _schema(
      properties: <String, mcp.JsonSchema>{
        'workspace_id': _stringSchema('Target workspace id.'),
        'task_id': _stringSchema('Task id.'),
        'run_id': _stringSchema('Work run id.'),
        'reason': _stringSchema('Reason the worker is releasing the task.'),
        'actor': _stringSchema('Actor releasing this run.'),
      },
      required: const <String>['workspace_id', 'task_id', 'run_id', 'reason'],
    ),
    'task_center_recover_stalled_task' => _schema(
      properties: <String, mcp.JsonSchema>{
        'workspace_id': _stringSchema('Target workspace id.'),
        'task_id': _stringSchema('Task id.'),
        'action': _recoverActionSchema(),
        'agent_name': _stringSchema(
          'Worker name required when action is reassign_worker.',
        ),
        'reason': _stringSchema('Reason for this recovery action.'),
        'actor': _stringSchema('Human or agent applying recovery.'),
      },
      required: const <String>['workspace_id', 'task_id', 'action'],
    ),
    'task_center_list_stalled_work' => _schema(
      properties: <String, mcp.JsonSchema>{
        'workspace_id': _stringSchema('Target workspace id.'),
      },
      required: const <String>['workspace_id'],
    ),
    'task_center_record_execution_result' => _schema(
      properties: <String, mcp.JsonSchema>{
        'workspace_id': _stringSchema('Target workspace id.'),
        'task_id': _stringSchema('Task id.'),
        'execution_result': _stringSchema('Execution result.'),
        'verification_notes': _stringSchema('Verification notes.'),
        'actor': _stringSchema('Actor recording the result.'),
      },
      required: const <String>['workspace_id', 'task_id', 'execution_result'],
    ),
    'task_center_list_task_events' => _schema(
      properties: <String, mcp.JsonSchema>{
        'workspace_id': _stringSchema('Target workspace id.'),
        'task_id': _stringSchema('Task id.'),
      },
      required: const <String>['workspace_id', 'task_id'],
    ),
    'task_center_move_task' => _schema(
      properties: <String, mcp.JsonSchema>{
        'workspace_id': _stringSchema('Target workspace id.'),
        'task_id': _stringSchema('Task id.'),
        'status': _statusSchema(),
        'index': mcp.JsonSchema.integer(
          description: 'Zero-based position inside the target status column.',
        ),
      },
      required: const <String>['workspace_id', 'task_id', 'status'],
    ),
    'task_center_list_tasks' => _schema(
      properties: <String, mcp.JsonSchema>{
        'workspace_id': _stringSchema('Target workspace id.'),
        'status': _statusSchema(),
      },
      required: const <String>['workspace_id'],
    ),
    'task_center_delete_task' => _schema(
      properties: <String, mcp.JsonSchema>{
        'workspace_id': _stringSchema('Target workspace id.'),
        'task_id': _stringSchema('Task id.'),
      },
      required: const <String>['workspace_id', 'task_id'],
    ),
    'task_center_post_workspace_message' => _schema(
      properties: <String, mcp.JsonSchema>{
        'workspace_id': _stringSchema('Target workspace id.'),
        'role': _chatRoleSchema(),
        'actor': _stringSchema('Human or agent name writing the message.'),
        'agent_name': _stringSchema('Optional concrete agent name.'),
        'content': _stringSchema('Message content.'),
        'task_id': _stringSchema('Optional linked task id.'),
        'metadata': _objectSchema('Optional message metadata.'),
      },
      required: const <String>['workspace_id', 'role', 'actor', 'content'],
    ),
    'task_center_list_workspace_messages' => _schema(
      properties: <String, mcp.JsonSchema>{
        'workspace_id': _stringSchema('Target workspace id.'),
      },
      required: const <String>['workspace_id'],
    ),
    'task_center_record_admission_decision' => _schema(
      properties: <String, mcp.JsonSchema>{
        'workspace_id': _stringSchema('Target workspace id.'),
        'task_id': _stringSchema('Optional linked task id.'),
        'agent_name': _stringSchema('Fast agent name.'),
        'decision': _admissionDecisionSchema(),
        'reason': _stringSchema('Reason for this admission decision.'),
        'content': _stringSchema('Optional chat message content override.'),
      },
      required: const <String>['workspace_id', 'agent_name', 'decision'],
    ),
    'task_center_request_thinking_alignment' => _schema(
      properties: <String, mcp.JsonSchema>{
        'workspace_id': _stringSchema('Target workspace id.'),
        'task_id': _stringSchema('Task id.'),
        'fast_agent_name': _stringSchema('Fast agent name.'),
        'thinking_agent_name': _stringSchema('Thinking agent name.'),
        'question': _stringSchema('Question or alignment request.'),
        'route_reason': _stringSchema('Reason the task needs thinking.'),
      },
      required: const <String>[
        'workspace_id',
        'task_id',
        'fast_agent_name',
        'thinking_agent_name',
        'question',
      ],
    ),
    'task_center_deliver_work_result' => _schema(
      properties: <String, mcp.JsonSchema>{
        'workspace_id': _stringSchema('Target workspace id.'),
        'task_id': _stringSchema('Task id.'),
        'agent_name': _stringSchema('Work agent name.'),
        'execution_result': _stringSchema('Execution result.'),
        'verification_notes': _stringSchema('Verification notes.'),
        'status': _statusSchema(
          'Optional final delivery column. Defaults to done; todo and in_progress are treated as done.',
        ),
      },
      required: const <String>[
        'workspace_id',
        'task_id',
        'agent_name',
        'execution_result',
      ],
    ),
    _ => _schema(),
  };
}

mcp.JsonObject _schema({
  Map<String, mcp.JsonSchema> properties = const <String, mcp.JsonSchema>{},
  List<String> required = const <String>[],
}) {
  return mcp.JsonSchema.object(
    properties: properties,
    required: required,
    additionalProperties: false,
  );
}

mcp.JsonString _stringSchema(String description) {
  return mcp.JsonSchema.string(description: description);
}

mcp.JsonObject _objectSchema(String description) {
  return mcp.JsonSchema.object(description: description);
}

mcp.JsonArray _stringArraySchema(String description) {
  return mcp.JsonSchema.array(
    description: description,
    items: mcp.JsonSchema.string(),
  );
}

mcp.JsonString _statusSchema([String description = 'Task status column.']) {
  return mcp.JsonSchema.string(
    enumValues: const <String>['todo', 'in_progress', 'review', 'done'],
    description: description,
  );
}

mcp.JsonString _chatRoleSchema() {
  return mcp.JsonSchema.string(
    enumValues: const <String>[
      'human',
      'fast_agent',
      'thinking_agent',
      'work_agent',
      'system',
    ],
    description: 'Workspace chat message role.',
  );
}

mcp.JsonString _admissionDecisionSchema() {
  return mcp.JsonSchema.string(
    enumValues: const <String>[
      'accepted',
      'needs_thinking',
      'needs_human',
      'rejected',
    ],
    description: 'Fast agent inbox admission decision.',
  );
}

mcp.JsonString _readinessSchema() {
  return mcp.JsonSchema.string(
    enumValues: const <String>[
      'needs_info',
      'needs_thinking',
      'waiting_human',
      'ready',
      'blocked',
    ],
    description: 'Task execution readiness.',
  );
}

mcp.JsonString _workRunStateSchema() {
  return mcp.JsonSchema.string(
    enumValues: const <String>[
      'claimed',
      'running',
      'waiting_permission',
      'waiting_human',
      'blocked',
      'stale',
      'failed',
      'released',
      'delivered',
    ],
    description: 'Worker run state.',
  );
}

mcp.JsonString _workBlockerTypeSchema() {
  return mcp.JsonSchema.string(
    enumValues: const <String>[
      'unclear_goal',
      'missing_acceptance',
      'needs_human',
      'permission',
      'tool_error',
      'external_dependency',
      'other',
    ],
    description: 'Reason category for a blocked worker run.',
  );
}

mcp.JsonString _recoverActionSchema() {
  return mcp.JsonSchema.string(
    enumValues: const <String>[
      'nudge_worker',
      'reassign_worker',
      'return_to_fast',
      'send_to_thinking',
      'ask_human',
      'mark_failed',
    ],
    description: 'Recovery action for stalled worker tasks.',
  );
}

mcp.JsonString _ownerKindSchema() {
  return mcp.JsonSchema.string(
    enumValues: const <String>[
      'unassigned',
      'fast_agent',
      'thinking_agent',
      'human',
      'work_agent_pool',
      'work_agent',
    ],
    description: 'Task owner role kind.',
  );
}

mcp.JsonObject _ownerSchema() {
  return mcp.JsonSchema.object(
    description: 'Task owner role.',
    properties: <String, mcp.JsonSchema>{
      'kind': _ownerKindSchema(),
      'agent_name': _stringSchema('Optional concrete agent name.'),
      'work_agent_index': mcp.JsonSchema.integer(
        description: 'Optional work agent index.',
      ),
    },
    required: const <String>['kind'],
    additionalProperties: false,
  );
}
