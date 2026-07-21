import 'task_inbox_controller.dart';
import 'task_inbox_snapshot.dart';
import 'task_record.dart';

class TaskTemplate {
  const TaskTemplate({
    required this.id,
    required this.title,
    required this.description,
    required this.agentName,
    this.priority = TaskPriority.normal,
    this.skillIds = const <String>[],
    this.metadata = const <String, Object?>{},
  });

  final String id;
  final String title;
  final String description;
  final String agentName;
  final TaskPriority priority;
  final List<String> skillIds;
  final Map<String, Object?> metadata;

  WorkflowTaskDraft instantiate({
    required String workspacePath,
    Map<String, String> variables = const <String, String>{},
  }) {
    return WorkflowTaskDraft(
      title: _replaceVariables(title, variables),
      description: _replaceVariables(description, variables),
      workspacePath: workspacePath,
      agentName: agentName,
      priority: priority,
      skillIds: List.unmodifiable(skillIds),
      metadata: <String, Object?>{...metadata, 'template_id': id},
    );
  }
}

class WorkflowTaskDraft {
  const WorkflowTaskDraft({
    required this.title,
    required this.description,
    required this.workspacePath,
    required this.agentName,
    required this.priority,
    this.skillIds = const <String>[],
    this.metadata = const <String, Object?>{},
  });

  final String title;
  final String description;
  final String workspacePath;
  final String agentName;
  final TaskPriority priority;
  final List<String> skillIds;
  final Map<String, Object?> metadata;
}

enum AutopilotTrigger { cron, manual, localWebhook }

class AutopilotTaskRequest {
  const AutopilotTaskRequest({
    required this.trigger,
    required this.title,
    required this.description,
    required this.workspacePath,
    required this.agentName,
    this.priority = TaskPriority.normal,
    this.skillIds = const <String>[],
    this.metadata = const <String, Object?>{},
    this.enqueue = false,
    this.runOnly = false,
  });

  final AutopilotTrigger trigger;
  final String title;
  final String description;
  final String workspacePath;
  final String agentName;
  final TaskPriority priority;
  final List<String> skillIds;
  final Map<String, Object?> metadata;
  final bool enqueue;
  final bool runOnly;
}

class LocalAutopilot {
  LocalAutopilot({required this.taskController});

  final TaskInboxController taskController;

  Future<TaskRecord> createTask(AutopilotTaskRequest request) async {
    if (request.runOnly) {
      throw ArgumentError.value(
        request.runOnly,
        'runOnly',
        'Local autopilot only supports createTask.',
      );
    }
    final task = await taskController.createTask(
      title: request.title,
      description: request.description,
      workspacePath: request.workspacePath,
      agentName: request.agentName,
      priority: request.priority,
      skillIds: request.skillIds,
      metadata: <String, Object?>{
        ...request.metadata,
        'autopilot_trigger': request.trigger.jsonValue,
        'run_only': false,
      },
    );
    if (!request.enqueue) return task;
    return taskController.updateTask(
      task.id,
      status: TaskStatus.queued,
      summary: 'Queued by local autopilot.',
    );
  }
}

class TaskRoutingRule {
  const TaskRoutingRule({
    required this.keyword,
    required this.agentName,
    this.skillIds = const <String>[],
  });

  final String keyword;
  final String agentName;
  final List<String> skillIds;
}

class TaskRouteRecommendation {
  const TaskRouteRecommendation({
    required this.agentName,
    this.skillIds = const <String>[],
    this.requiresHumanConfirmation = true,
  });

  final String agentName;
  final List<String> skillIds;
  final bool requiresHumanConfirmation;
}

class LocalTaskRouter {
  const LocalTaskRouter({required this.rules, required this.fallbackAgentName});

  final List<TaskRoutingRule> rules;
  final String fallbackAgentName;

  TaskRouteRecommendation recommend({
    required String title,
    required String description,
  }) {
    final haystack = '$title\n$description'.toLowerCase();
    for (final rule in rules) {
      if (haystack.contains(rule.keyword.toLowerCase())) {
        return TaskRouteRecommendation(
          agentName: rule.agentName,
          skillIds: List.unmodifiable(rule.skillIds),
        );
      }
    }
    return TaskRouteRecommendation(agentName: fallbackAgentName);
  }
}

enum TaskNotificationKind {
  permissionRequested,
  needsHumanReview,
  runtimeUnavailable,
  taskFailed,
}

class TaskNotification {
  const TaskNotification({
    required this.id,
    required this.taskId,
    required this.kind,
    required this.title,
    required this.createdAt,
    this.eventId,
  });

  final String id;
  final String taskId;
  final TaskNotificationKind kind;
  final String title;
  final DateTime createdAt;
  final String? eventId;
}

List<TaskNotification> buildTaskNotifications(TaskInboxSnapshot snapshot) {
  final notifications = <TaskNotification>[];
  for (final task in snapshot.tasks) {
    switch (task.status) {
      case TaskStatus.blockedOnPermission:
        notifications.add(
          _taskNotification(
            task,
            TaskNotificationKind.permissionRequested,
            'Permission requested',
          ),
        );
        break;
      case TaskStatus.needsHumanReview:
      case TaskStatus.approvedForExport:
      case TaskStatus.exporting:
        notifications.add(
          _taskNotification(
            task,
            TaskNotificationKind.needsHumanReview,
            'Task needs human review',
          ),
        );
        break;
      case TaskStatus.failed:
        notifications.add(
          _taskNotification(
            task,
            TaskNotificationKind.taskFailed,
            'Task failed',
          ),
        );
        break;
      default:
        break;
    }
  }

  for (final event in snapshot.events) {
    final runtime = event.metadata['runtime_availability'];
    if (runtime == 'unavailable' ||
        runtime == 'authRequired' ||
        runtime == 'misconfigured') {
      final task = _taskById(snapshot, event.taskId);
      if (task == null) continue;
      notifications.add(
        TaskNotification(
          id: 'runtime:${event.id}',
          taskId: task.id,
          eventId: event.id,
          kind: TaskNotificationKind.runtimeUnavailable,
          title: event.text,
          createdAt: event.createdAt,
        ),
      );
    }
  }
  return List.unmodifiable(notifications);
}

TaskRecord? _taskById(TaskInboxSnapshot snapshot, String taskId) {
  for (final task in snapshot.tasks) {
    if (task.id == taskId) return task;
  }
  return null;
}

TaskNotification _taskNotification(
  TaskRecord task,
  TaskNotificationKind kind,
  String title,
) {
  return TaskNotification(
    id: '${kind.name}:${task.id}',
    taskId: task.id,
    kind: kind,
    title: title,
    createdAt: task.updatedAt,
  );
}

String _replaceVariables(String input, Map<String, String> variables) {
  var result = input;
  for (final entry in variables.entries) {
    result = result.replaceAll('{${entry.key}}', entry.value);
  }
  return result;
}

extension on AutopilotTrigger {
  String get jsonValue {
    return switch (this) {
      AutopilotTrigger.cron => 'cron',
      AutopilotTrigger.manual => 'manual',
      AutopilotTrigger.localWebhook => 'local_webhook',
    };
  }
}
