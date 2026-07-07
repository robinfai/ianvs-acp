import 'dart:async';

import 'package:flutter/foundation.dart';

import '../acp/acp_permission_request.dart';
import '../acp/agent_event.dart';
import '../acp/agent_session.dart';
import '../state/chat_controller.dart';
import '../state/connection_state.dart';
import 'artifact_collector.dart';
import 'egress_policy.dart';
import 'task_inbox_controller.dart';
import 'task_record.dart';

typedef TaskControllerForAgent = ChatController? Function(String agentName);
typedef TaskRunnerClock = DateTime Function();

class TaskRunner {
  TaskRunner({
    required this.taskController,
    required this.controllerForAgent,
    ArtifactCollector? artifactCollector,
    TaskRunnerClock? clock,
  }) : artifactCollector = artifactCollector ?? ArtifactCollector(),
       _clock = clock ?? DateTime.now;

  final TaskInboxController taskController;
  final TaskControllerForAgent controllerForAgent;
  final ArtifactCollector artifactCollector;
  final TaskRunnerClock _clock;

  Future<TaskRecord> runTask(String taskId) async {
    final task = taskController.taskById(taskId);
    if (task == null) throw StateError('Task not found: $taskId');

    final prompt = taskExecutionPrompt(task);
    var eventWrites = Future<void>.value();
    var runFinished = false;
    String? activeSessionId;
    VoidCallback? removeAgentObserver;
    VoidCallback? removePermissionObserver;
    late TaskRunRecord run;

    void enqueueEventWrite(Future<void> Function() write) {
      eventWrites = eventWrites.then((_) => write());
    }

    Future<void> flushEventWrites() async {
      try {
        await eventWrites;
      } catch (_) {
        // Event capture should not mask the task run result.
      }
    }

    bool matchesSessionId(String? sessionId) {
      final trimmedSessionId = sessionId?.trim();
      if (trimmedSessionId == null || trimmedSessionId.isEmpty) return true;
      final active = activeSessionId?.trim();
      return active == null || active.isEmpty || trimmedSessionId == active;
    }

    void observeAgentEvent(AgentSession? session, AgentEvent event) {
      if (!matchesSessionId(session?.id)) return;
      final kind = _eventKindForAgentEvent(event.type);
      final text = _textForAgentEvent(event);
      if (text.isEmpty && event.type != AgentEventType.agentTextDone) return;
      enqueueEventWrite(
        () => taskController.appendEvent(
          taskId: task.id,
          runId: run.id,
          kind: kind,
          text: text,
          sessionId: session?.id,
          metadata: _metadataForAgentEvent(event),
        ),
      );
    }

    void observePermissionEvent(ChatPermissionEvent event) {
      if (!matchesSessionId(event.request.sessionId)) return;
      if (event.type == ChatPermissionEventType.requested) {
        enqueueEventWrite(() async {
          final egressMatch = egressPolicyMatchForPermission(event.request);
          await taskController.updateTaskStatus(
            task.id,
            TaskStatus.blockedOnPermission,
            summary: egressMatch == null
                ? null
                : 'Export-sensitive permission requires manual approval.',
          );
          await taskController.appendEvent(
            taskId: task.id,
            runId: run.id,
            kind: TaskEventKind.permission,
            text: egressMatch == null
                ? 'Permission requested: ${event.request.displayTitle}'
                : 'Export-sensitive permission requested: '
                      '${event.request.displayTitle}',
            sessionId: event.request.sessionId,
            metadata: _metadataForPermissionEvent(event),
          );
        });
        return;
      }

      enqueueEventWrite(() async {
        await taskController.appendEvent(
          taskId: task.id,
          runId: run.id,
          kind: TaskEventKind.permission,
          text:
              'Permission ${event.status.displayLabel}: '
              '${event.request.displayTitle}',
          sessionId: event.request.sessionId,
          metadata: _metadataForPermissionEvent(event),
        );
        if (!runFinished) {
          await taskController.updateTaskStatus(task.id, TaskStatus.running);
        }
      });
    }

    run = await taskController.createRun(
      taskId: task.id,
      status: TaskStatus.running,
      promptSnapshot: prompt,
    );
    await taskController.appendEvent(
      taskId: task.id,
      runId: run.id,
      kind: TaskEventKind.system,
      text: 'Task run started.',
    );

    try {
      final controller = controllerForAgent(task.agentName);
      if (controller == null) {
        throw StateError(
          'No ACP controller is available for ${task.agentName}.',
        );
      }
      removeAgentObserver = controller.addAgentEventObserver(observeAgentEvent);
      removePermissionObserver = controller.addPermissionEventObserver(
        observePermissionEvent,
      );

      await controller.newSession(cwd: task.workspacePath);
      _throwIfControllerFailed(controller, 'Task session setup failed');
      final session = controller.currentSession;
      if (session == null) {
        throw StateError('Task session setup did not return a session.');
      }
      activeSessionId = session.id;

      await taskController.updateRun(run.id, sessionId: session.id);
      await taskController.updateTask(
        task.id,
        status: TaskStatus.running,
        sessionId: session.id,
        currentRunId: run.id,
      );
      await taskController.appendEvent(
        taskId: task.id,
        runId: run.id,
        kind: TaskEventKind.system,
        text: 'Linked ACP session ${session.id}.',
        sessionId: session.id,
      );

      await controller.sendPrompt(prompt);
      await _waitForPromptTurn(controller);
      await flushEventWrites();
      _throwIfControllerFailed(controller, 'Task prompt failed');
      runFinished = true;

      await taskController.updateTaskStatus(
        task.id,
        TaskStatus.collectingArtifacts,
      );
      final currentTask = taskController.taskById(task.id) ?? task;
      final artifacts = await artifactCollector.collect(currentTask, run);
      await taskController.replaceArtifactsForRun(
        taskId: task.id,
        runId: run.id,
        artifacts: artifacts,
      );
      await taskController.appendEvent(
        taskId: task.id,
        runId: run.id,
        kind: TaskEventKind.artifact,
        text: artifacts.isEmpty
            ? 'Artifact collection found no candidate artifacts.'
            : 'Collected ${artifacts.length} candidate artifact(s).',
        sessionId: session.id,
        metadata: <String, Object?>{
          'artifact_count': artifacts.length,
          if (artifacts.isNotEmpty)
            'artifact_ids': artifacts.map((artifact) => artifact.id).toList(),
        },
      );
      await taskController.updateRun(
        run.id,
        status: TaskStatus.needsHumanReview,
        endedAt: _clock(),
      );
      await taskController.appendEvent(
        taskId: task.id,
        runId: run.id,
        kind: TaskEventKind.system,
        text: 'Task run completed; awaiting human review.',
        sessionId: session.id,
      );
      return taskController.updateTaskStatus(
        task.id,
        TaskStatus.needsHumanReview,
        summary:
            'Agent run completed. Review candidate artifacts before export.',
      );
    } catch (error) {
      runFinished = true;
      await flushEventWrites();
      final message = _messageForError(error);
      await taskController.updateRun(
        run.id,
        status: TaskStatus.failed,
        endedAt: _clock(),
        error: message,
      );
      await taskController.appendEvent(
        taskId: task.id,
        runId: run.id,
        kind: TaskEventKind.system,
        text: 'Task run failed: $message',
      );
      return taskController.updateTask(
        task.id,
        status: TaskStatus.failed,
        error: message,
      );
    } finally {
      removeAgentObserver?.call();
      removePermissionObserver?.call();
    }
  }

  static String taskExecutionPrompt(TaskRecord task) {
    final description = task.description.trim();
    return '''
You are executing a local task inside an ACP client.

Task ID: ${task.id}
Workspace: ${task.workspacePath}

Title:
${task.title}

Description:
${description.isEmpty ? '(No additional description provided.)' : description}

You may:
- inspect and modify files inside the workspace
- run local tests and static analysis
- write candidate artifacts under .ianvs/outbox/${task.id}/

You must not:
- push to remote git repositories
- create pull requests
- upload files
- call external webhooks
- use scp/rsync/ssh to send data externally
- copy artifacts outside the workspace

If the task requires export, prepare artifacts locally and stop.
The host app will ask the human for export approval.

When done, summarize:
1. What changed
2. How you verified it
3. Candidate artifacts
4. Whether export is needed
''';
  }

  Future<void> _waitForPromptTurn(ChatController controller) async {
    if (!controller.isStreaming) return;
    final completer = Completer<void>();
    late VoidCallback listener;
    listener = () {
      if (controller.isStreaming) return;
      controller.removeListener(listener);
      if (!completer.isCompleted) completer.complete();
    };
    controller.addListener(listener);
    listener();
    await completer.future;
  }

  void _throwIfControllerFailed(ChatController controller, String prefix) {
    if (controller.status != ConnectionStatus.error &&
        (controller.lastError == null || controller.lastError!.isEmpty)) {
      return;
    }
    final detail = controller.lastError;
    throw StateError(
      detail == null || detail.isEmpty ? prefix : '$prefix: $detail',
    );
  }

  String _messageForError(Object error) {
    if (error is StateError) return error.message;
    if (error is Exception) return error.toString();
    return '$error';
  }

  TaskEventKind _eventKindForAgentEvent(AgentEventType type) {
    return switch (type) {
      AgentEventType.userMessage => TaskEventKind.user,
      AgentEventType.agentTextDelta => TaskEventKind.assistant,
      AgentEventType.agentTextDone => TaskEventKind.status,
      AgentEventType.toolCall => TaskEventKind.tool,
      AgentEventType.error => TaskEventKind.error,
      AgentEventType.status => TaskEventKind.status,
    };
  }

  String _textForAgentEvent(AgentEvent event) {
    final text = event.text.trim();
    if (text.isNotEmpty) return text;
    return switch (event.type) {
      AgentEventType.agentTextDone => 'Assistant turn completed.',
      _ => '',
    };
  }

  Map<String, Object?> _metadataForAgentEvent(AgentEvent event) {
    return <String, Object?>{
      ...event.metadata,
      'agent_event_type': event.type.name,
      if (event.timestamp != null)
        'agent_event_timestamp': event.timestamp!.toIso8601String(),
    };
  }

  Map<String, Object?> _metadataForPermissionEvent(ChatPermissionEvent event) {
    final egressMatch = egressPolicyMatchForPermission(event.request);
    return <String, Object?>{
      'permission_event_type': event.type.name,
      'permission_request_id': event.request.id,
      'permission_tool_name': event.request.toolName,
      if (event.request.toolKind != null)
        'permission_tool_kind': event.request.toolKind,
      if (event.decision != null) 'permission_decision': event.decision!.name,
      if (event.decisionSource != null)
        'permission_decision_source': event.decisionSource!.name,
      'permission_status': event.status.name,
      if (egressMatch != null) ...<String, Object?>{
        'egress_sensitive': true,
        'egress_reason': egressMatch.reason,
        'egress_command_line': egressMatch.commandLine,
      },
      if (event.request.metadata.isNotEmpty)
        'permission_request_metadata': event.request.metadata,
    };
  }
}

extension on AcpPermissionAuditStatus {
  String get displayLabel {
    return switch (this) {
      AcpPermissionAuditStatus.pending => 'pending',
      AcpPermissionAuditStatus.allowed => 'allowed',
      AcpPermissionAuditStatus.denied => 'denied',
      AcpPermissionAuditStatus.cancelled => 'cancelled',
    };
  }
}
