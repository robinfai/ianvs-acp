enum TaskStatus {
  inbox,
  queued,
  dispatched,
  running,
  blockedOnPermission,
  blockedOnUserInput,
  collectingArtifacts,
  needsHumanReview,
  // Historical states remain readable, but no export action is exposed.
  approvedForExport,
  exporting,
  done,
  failed,
  cancelled,
  rejected,
  needsChanges,
}

enum TaskPriority { low, normal, high, urgent }

enum TaskEventKind {
  user,
  assistant,
  tool,
  status,
  permission,
  review,
  artifact,
  // Historical event kind retained for lossless v1 migration.
  export,
  error,
  system,
}

enum ArtifactKind {
  gitDiff,
  gitStatus,
  file,
  outboxFile,
  testLog,
  agentSummary,
  patch,
}

enum ArtifactStatus { candidate, reviewed, approved, rejected, exported }

enum ApprovalKind { toolPermission, export }

enum ApprovalStatus { pending, approved, denied, cancelled }

enum ExportTarget {
  simulated,
  gitCommit,
  gitPush,
  pullRequest,
  copyToExternalDirectory,
  uploadHttp,
  sendWebhook,
}

const Object _unchanged = Object();

class TaskRecord {
  const TaskRecord({
    required this.id,
    required this.title,
    required this.description,
    required this.workspacePath,
    required this.agentName,
    required this.status,
    required this.priority,
    required this.createdAt,
    required this.updatedAt,
    this.sessionId,
    this.currentRunId,
    this.summary,
    this.error,
    this.resourceId,
    this.skillIds = const <String>[],
    this.metadata = const <String, Object?>{},
  });

  final String id;
  final String title;
  final String description;
  final String workspacePath;
  final String agentName;
  final TaskStatus status;
  final TaskPriority priority;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? sessionId;
  final String? currentRunId;
  final String? summary;
  final String? error;
  final String? resourceId;
  final List<String> skillIds;
  final Map<String, Object?> metadata;

  TaskRecord copyWith({
    String? id,
    String? title,
    String? description,
    String? workspacePath,
    String? agentName,
    TaskStatus? status,
    TaskPriority? priority,
    DateTime? createdAt,
    DateTime? updatedAt,
    Object? sessionId = _unchanged,
    Object? currentRunId = _unchanged,
    Object? summary = _unchanged,
    Object? error = _unchanged,
    Object? resourceId = _unchanged,
    List<String>? skillIds,
    Map<String, Object?>? metadata,
  }) {
    return TaskRecord(
      id: id ?? this.id,
      title: title ?? this.title,
      description: description ?? this.description,
      workspacePath: workspacePath ?? this.workspacePath,
      agentName: agentName ?? this.agentName,
      status: status ?? this.status,
      priority: priority ?? this.priority,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      sessionId: identical(sessionId, _unchanged)
          ? this.sessionId
          : sessionId as String?,
      currentRunId: identical(currentRunId, _unchanged)
          ? this.currentRunId
          : currentRunId as String?,
      summary: identical(summary, _unchanged)
          ? this.summary
          : summary as String?,
      error: identical(error, _unchanged) ? this.error : error as String?,
      resourceId: identical(resourceId, _unchanged)
          ? this.resourceId
          : resourceId as String?,
      skillIds: skillIds ?? this.skillIds,
      metadata: metadata ?? this.metadata,
    );
  }

  static TaskRecord? fromJson(Object? raw) {
    final json = _jsonMap(raw);
    if (json == null) return null;
    final id = _stringFromJson(json['id']);
    final title = _stringFromJson(json['title']);
    final workspacePath = _stringFromJson(
      json['workspace_path'] ?? json['workspacePath'],
    );
    final agentName = _stringFromJson(json['agent_name'] ?? json['agentName']);
    final createdAt = _dateTimeFromJson(
      json['created_at'] ?? json['createdAt'],
    );
    final updatedAt = _dateTimeFromJson(
      json['updated_at'] ?? json['updatedAt'],
    );
    if (id == null ||
        title == null ||
        workspacePath == null ||
        agentName == null ||
        createdAt == null ||
        updatedAt == null) {
      return null;
    }

    return TaskRecord(
      id: id,
      title: title,
      description: _rawStringFromJson(json['description']) ?? '',
      workspacePath: workspacePath,
      agentName: agentName,
      status: taskStatusFromJson(json['status']),
      priority: taskPriorityFromJson(json['priority']),
      createdAt: createdAt,
      updatedAt: updatedAt,
      sessionId: _stringFromJson(json['session_id'] ?? json['sessionId']),
      currentRunId: _stringFromJson(
        json['current_run_id'] ?? json['currentRunId'],
      ),
      summary: _stringFromJson(json['summary']),
      error: _stringFromJson(json['error']),
      resourceId: _stringFromJson(json['resource_id'] ?? json['resourceId']),
      skillIds: _stringListFromJson(json['skill_ids'] ?? json['skillIds']),
      metadata: _jsonMap(json['metadata']) ?? const <String, Object?>{},
    );
  }

  Map<String, Object?> toJson() {
    final sessionId = this.sessionId?.trim();
    final currentRunId = this.currentRunId?.trim();
    final summary = this.summary?.trim();
    final error = this.error?.trim();
    final resourceId = this.resourceId?.trim();
    return <String, Object?>{
      'id': id,
      'title': title,
      'description': description,
      'workspace_path': workspacePath,
      'agent_name': agentName,
      'status': status.jsonValue,
      'priority': priority.jsonValue,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
      if (sessionId != null && sessionId.isNotEmpty) 'session_id': sessionId,
      if (currentRunId != null && currentRunId.isNotEmpty)
        'current_run_id': currentRunId,
      if (summary != null && summary.isNotEmpty) 'summary': summary,
      if (error != null && error.isNotEmpty) 'error': error,
      if (resourceId != null && resourceId.isNotEmpty)
        'resource_id': resourceId,
      if (skillIds.isNotEmpty) 'skill_ids': skillIds,
      if (metadata.isNotEmpty) 'metadata': metadata,
    };
  }
}

class TaskRunRecord {
  const TaskRunRecord({
    required this.id,
    required this.taskId,
    required this.attempt,
    required this.status,
    required this.startedAt,
    this.endedAt,
    this.sessionId,
    this.promptSnapshot,
    this.model,
    this.error,
  });

  final String id;
  final String taskId;
  final int attempt;
  final TaskStatus status;
  final DateTime startedAt;
  final DateTime? endedAt;
  final String? sessionId;
  final String? promptSnapshot;
  final String? model;
  final String? error;

  TaskRunRecord copyWith({
    String? id,
    String? taskId,
    int? attempt,
    TaskStatus? status,
    DateTime? startedAt,
    Object? endedAt = _unchanged,
    Object? sessionId = _unchanged,
    Object? promptSnapshot = _unchanged,
    Object? model = _unchanged,
    Object? error = _unchanged,
  }) {
    return TaskRunRecord(
      id: id ?? this.id,
      taskId: taskId ?? this.taskId,
      attempt: attempt ?? this.attempt,
      status: status ?? this.status,
      startedAt: startedAt ?? this.startedAt,
      endedAt: identical(endedAt, _unchanged)
          ? this.endedAt
          : endedAt as DateTime?,
      sessionId: identical(sessionId, _unchanged)
          ? this.sessionId
          : sessionId as String?,
      promptSnapshot: identical(promptSnapshot, _unchanged)
          ? this.promptSnapshot
          : promptSnapshot as String?,
      model: identical(model, _unchanged) ? this.model : model as String?,
      error: identical(error, _unchanged) ? this.error : error as String?,
    );
  }

  static TaskRunRecord? fromJson(Object? raw) {
    final json = _jsonMap(raw);
    if (json == null) return null;
    final id = _stringFromJson(json['id']);
    final taskId = _stringFromJson(json['task_id'] ?? json['taskId']);
    final startedAt = _dateTimeFromJson(
      json['started_at'] ?? json['startedAt'],
    );
    if (id == null || taskId == null || startedAt == null) return null;
    return TaskRunRecord(
      id: id,
      taskId: taskId,
      attempt: _intFromJson(json['attempt']) ?? 1,
      status: taskStatusFromJson(json['status'], fallback: TaskStatus.running),
      startedAt: startedAt,
      endedAt: _dateTimeFromJson(json['ended_at'] ?? json['endedAt']),
      sessionId: _stringFromJson(json['session_id'] ?? json['sessionId']),
      promptSnapshot: _stringFromJson(
        json['prompt_snapshot'] ?? json['promptSnapshot'],
      ),
      model: _stringFromJson(json['model']),
      error: _stringFromJson(json['error']),
    );
  }

  Map<String, Object?> toJson() {
    final sessionId = this.sessionId?.trim();
    final promptSnapshot = this.promptSnapshot?.trim();
    final model = this.model?.trim();
    final error = this.error?.trim();
    return <String, Object?>{
      'id': id,
      'task_id': taskId,
      'attempt': attempt,
      'status': status.jsonValue,
      'started_at': startedAt.toIso8601String(),
      if (endedAt != null) 'ended_at': endedAt!.toIso8601String(),
      if (sessionId != null && sessionId.isNotEmpty) 'session_id': sessionId,
      if (promptSnapshot != null && promptSnapshot.isNotEmpty)
        'prompt_snapshot': promptSnapshot,
      if (model != null && model.isNotEmpty) 'model': model,
      if (error != null && error.isNotEmpty) 'error': error,
    };
  }
}

class TaskEventRecord {
  const TaskEventRecord({
    required this.id,
    required this.taskId,
    required this.runId,
    required this.kind,
    required this.text,
    required this.createdAt,
    this.sessionId,
    this.metadata = const <String, Object?>{},
  });

  final String id;
  final String taskId;
  final String runId;
  final TaskEventKind kind;
  final String text;
  final DateTime createdAt;
  final String? sessionId;
  final Map<String, Object?> metadata;

  TaskEventRecord copyWith({
    String? id,
    String? taskId,
    String? runId,
    TaskEventKind? kind,
    String? text,
    DateTime? createdAt,
    Object? sessionId = _unchanged,
    Map<String, Object?>? metadata,
  }) {
    return TaskEventRecord(
      id: id ?? this.id,
      taskId: taskId ?? this.taskId,
      runId: runId ?? this.runId,
      kind: kind ?? this.kind,
      text: text ?? this.text,
      createdAt: createdAt ?? this.createdAt,
      sessionId: identical(sessionId, _unchanged)
          ? this.sessionId
          : sessionId as String?,
      metadata: metadata ?? this.metadata,
    );
  }

  static TaskEventRecord? fromJson(Object? raw) {
    final json = _jsonMap(raw);
    if (json == null) return null;
    final id = _stringFromJson(json['id']);
    final taskId = _stringFromJson(json['task_id'] ?? json['taskId']);
    final runId = _stringFromJson(json['run_id'] ?? json['runId']);
    final text = _rawStringFromJson(json['text']) ?? '';
    final createdAt = _dateTimeFromJson(
      json['created_at'] ?? json['createdAt'],
    );
    if (id == null || taskId == null || runId == null || createdAt == null) {
      return null;
    }
    return TaskEventRecord(
      id: id,
      taskId: taskId,
      runId: runId,
      kind: taskEventKindFromJson(json['kind']),
      text: text,
      createdAt: createdAt,
      sessionId: _stringFromJson(json['session_id'] ?? json['sessionId']),
      metadata: _jsonMap(json['metadata']) ?? const <String, Object?>{},
    );
  }

  Map<String, Object?> toJson() {
    final sessionId = this.sessionId?.trim();
    return <String, Object?>{
      'id': id,
      'task_id': taskId,
      'run_id': runId,
      'kind': kind.jsonValue,
      'text': text,
      'created_at': createdAt.toIso8601String(),
      if (sessionId != null && sessionId.isNotEmpty) 'session_id': sessionId,
      if (metadata.isNotEmpty) 'metadata': metadata,
    };
  }
}

class ArtifactRecord {
  const ArtifactRecord({
    required this.id,
    required this.taskId,
    required this.runId,
    required this.kind,
    required this.title,
    required this.createdAt,
    this.status = ArtifactStatus.candidate,
    this.path,
    this.contentPreview,
    this.sha256,
    this.sizeBytes,
    this.metadata = const <String, Object?>{},
  });

  final String id;
  final String taskId;
  final String runId;
  final ArtifactKind kind;
  final ArtifactStatus status;
  final String title;
  final DateTime createdAt;
  final String? path;
  final String? contentPreview;
  final String? sha256;
  final int? sizeBytes;
  final Map<String, Object?> metadata;

  ArtifactRecord copyWith({
    String? id,
    String? taskId,
    String? runId,
    ArtifactKind? kind,
    ArtifactStatus? status,
    String? title,
    DateTime? createdAt,
    Object? path = _unchanged,
    Object? contentPreview = _unchanged,
    Object? sha256 = _unchanged,
    Object? sizeBytes = _unchanged,
    Map<String, Object?>? metadata,
  }) {
    return ArtifactRecord(
      id: id ?? this.id,
      taskId: taskId ?? this.taskId,
      runId: runId ?? this.runId,
      kind: kind ?? this.kind,
      status: status ?? this.status,
      title: title ?? this.title,
      createdAt: createdAt ?? this.createdAt,
      path: identical(path, _unchanged) ? this.path : path as String?,
      contentPreview: identical(contentPreview, _unchanged)
          ? this.contentPreview
          : contentPreview as String?,
      sha256: identical(sha256, _unchanged) ? this.sha256 : sha256 as String?,
      sizeBytes: identical(sizeBytes, _unchanged)
          ? this.sizeBytes
          : sizeBytes as int?,
      metadata: metadata ?? this.metadata,
    );
  }

  static ArtifactRecord? fromJson(Object? raw) {
    final json = _jsonMap(raw);
    if (json == null) return null;
    final id = _stringFromJson(json['id']);
    final taskId = _stringFromJson(json['task_id'] ?? json['taskId']);
    final runId = _stringFromJson(json['run_id'] ?? json['runId']);
    final title = _stringFromJson(json['title']);
    final createdAt = _dateTimeFromJson(
      json['created_at'] ?? json['createdAt'],
    );
    if (id == null ||
        taskId == null ||
        runId == null ||
        title == null ||
        createdAt == null) {
      return null;
    }
    return ArtifactRecord(
      id: id,
      taskId: taskId,
      runId: runId,
      kind: artifactKindFromJson(json['kind']),
      status: artifactStatusFromJson(json['status']),
      title: title,
      createdAt: createdAt,
      path: _stringFromJson(json['path']),
      contentPreview: _rawStringFromJson(
        json['content_preview'] ?? json['contentPreview'],
        allowEmpty: false,
      ),
      sha256: _stringFromJson(json['sha256']),
      sizeBytes: _intFromJson(json['size_bytes'] ?? json['sizeBytes']),
      metadata: _jsonMap(json['metadata']) ?? const <String, Object?>{},
    );
  }

  Map<String, Object?> toJson() {
    final path = this.path?.trim();
    final contentPreview = this.contentPreview;
    final sha256 = this.sha256?.trim();
    return <String, Object?>{
      'id': id,
      'task_id': taskId,
      'run_id': runId,
      'kind': kind.jsonValue,
      'status': status.jsonValue,
      'title': title,
      'created_at': createdAt.toIso8601String(),
      if (path != null && path.isNotEmpty) 'path': path,
      if (contentPreview != null && contentPreview.isNotEmpty)
        'content_preview': contentPreview,
      if (sha256 != null && sha256.isNotEmpty) 'sha256': sha256,
      if (sizeBytes != null) 'size_bytes': sizeBytes,
      if (metadata.isNotEmpty) 'metadata': metadata,
    };
  }
}

class ApprovalRequestRecord {
  const ApprovalRequestRecord({
    required this.id,
    required this.taskId,
    required this.kind,
    required this.status,
    required this.createdAt,
    this.runId,
    this.resolvedAt,
    this.target,
    this.destination,
    this.riskSummary,
    this.rationale,
    this.artifactIds = const <String>[],
    this.metadata = const <String, Object?>{},
  });

  final String id;
  final String taskId;
  final String? runId;
  final ApprovalKind kind;
  final ApprovalStatus status;
  final DateTime createdAt;
  final DateTime? resolvedAt;
  final ExportTarget? target;
  final String? destination;
  final String? riskSummary;
  final String? rationale;
  final List<String> artifactIds;
  final Map<String, Object?> metadata;

  ApprovalRequestRecord copyWith({
    String? id,
    String? taskId,
    Object? runId = _unchanged,
    ApprovalKind? kind,
    ApprovalStatus? status,
    DateTime? createdAt,
    Object? resolvedAt = _unchanged,
    Object? target = _unchanged,
    Object? destination = _unchanged,
    Object? riskSummary = _unchanged,
    Object? rationale = _unchanged,
    List<String>? artifactIds,
    Map<String, Object?>? metadata,
  }) {
    return ApprovalRequestRecord(
      id: id ?? this.id,
      taskId: taskId ?? this.taskId,
      runId: identical(runId, _unchanged) ? this.runId : runId as String?,
      kind: kind ?? this.kind,
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
      resolvedAt: identical(resolvedAt, _unchanged)
          ? this.resolvedAt
          : resolvedAt as DateTime?,
      target: identical(target, _unchanged)
          ? this.target
          : target as ExportTarget?,
      destination: identical(destination, _unchanged)
          ? this.destination
          : destination as String?,
      riskSummary: identical(riskSummary, _unchanged)
          ? this.riskSummary
          : riskSummary as String?,
      rationale: identical(rationale, _unchanged)
          ? this.rationale
          : rationale as String?,
      artifactIds: artifactIds ?? this.artifactIds,
      metadata: metadata ?? this.metadata,
    );
  }

  static ApprovalRequestRecord? fromJson(Object? raw) {
    final json = _jsonMap(raw);
    if (json == null) return null;
    final id = _stringFromJson(json['id']);
    final taskId = _stringFromJson(json['task_id'] ?? json['taskId']);
    final createdAt = _dateTimeFromJson(
      json['created_at'] ?? json['createdAt'],
    );
    if (id == null || taskId == null || createdAt == null) return null;
    return ApprovalRequestRecord(
      id: id,
      taskId: taskId,
      runId: _stringFromJson(json['run_id'] ?? json['runId']),
      kind: approvalKindFromJson(json['kind']),
      status: approvalStatusFromJson(json['status']),
      createdAt: createdAt,
      resolvedAt: _dateTimeFromJson(json['resolved_at'] ?? json['resolvedAt']),
      target: exportTargetFromJson(json['target']),
      destination: _stringFromJson(json['destination']),
      riskSummary: _stringFromJson(json['risk_summary'] ?? json['riskSummary']),
      rationale: _stringFromJson(json['rationale']),
      artifactIds: _stringListFromJson(
        json['artifact_ids'] ?? json['artifactIds'],
      ),
      metadata: _jsonMap(json['metadata']) ?? const <String, Object?>{},
    );
  }

  Map<String, Object?> toJson() {
    final runId = this.runId?.trim();
    final destination = this.destination?.trim();
    final riskSummary = this.riskSummary?.trim();
    final rationale = this.rationale?.trim();
    return <String, Object?>{
      'id': id,
      'task_id': taskId,
      if (runId != null && runId.isNotEmpty) 'run_id': runId,
      'kind': kind.jsonValue,
      'status': status.jsonValue,
      'created_at': createdAt.toIso8601String(),
      if (resolvedAt != null) 'resolved_at': resolvedAt!.toIso8601String(),
      if (target != null) 'target': target!.jsonValue,
      if (destination != null && destination.isNotEmpty)
        'destination': destination,
      if (riskSummary != null && riskSummary.isNotEmpty)
        'risk_summary': riskSummary,
      if (rationale != null && rationale.isNotEmpty) 'rationale': rationale,
      if (artifactIds.isNotEmpty) 'artifact_ids': artifactIds,
      if (metadata.isNotEmpty) 'metadata': metadata,
    };
  }
}

extension TaskStatusJson on TaskStatus {
  String get jsonValue {
    return switch (this) {
      TaskStatus.inbox => 'inbox',
      TaskStatus.queued => 'queued',
      TaskStatus.dispatched => 'dispatched',
      TaskStatus.running => 'running',
      TaskStatus.blockedOnPermission => 'blocked_on_permission',
      TaskStatus.blockedOnUserInput => 'blocked_on_user_input',
      TaskStatus.collectingArtifacts => 'collecting_artifacts',
      TaskStatus.needsHumanReview => 'needs_human_review',
      TaskStatus.approvedForExport => 'approved_for_export',
      TaskStatus.exporting => 'exporting',
      TaskStatus.done => 'done',
      TaskStatus.failed => 'failed',
      TaskStatus.cancelled => 'cancelled',
      TaskStatus.rejected => 'rejected',
      TaskStatus.needsChanges => 'needs_changes',
    };
  }
}

extension TaskPriorityJson on TaskPriority {
  String get jsonValue {
    return switch (this) {
      TaskPriority.low => 'low',
      TaskPriority.normal => 'normal',
      TaskPriority.high => 'high',
      TaskPriority.urgent => 'urgent',
    };
  }
}

extension TaskEventKindJson on TaskEventKind {
  String get jsonValue {
    return switch (this) {
      TaskEventKind.user => 'user',
      TaskEventKind.assistant => 'assistant',
      TaskEventKind.tool => 'tool',
      TaskEventKind.status => 'status',
      TaskEventKind.permission => 'permission',
      TaskEventKind.review => 'review',
      TaskEventKind.artifact => 'artifact',
      TaskEventKind.export => 'export',
      TaskEventKind.error => 'error',
      TaskEventKind.system => 'system',
    };
  }
}

extension ArtifactKindJson on ArtifactKind {
  String get jsonValue {
    return switch (this) {
      ArtifactKind.gitDiff => 'git_diff',
      ArtifactKind.gitStatus => 'git_status',
      ArtifactKind.file => 'file',
      ArtifactKind.outboxFile => 'outbox_file',
      ArtifactKind.testLog => 'test_log',
      ArtifactKind.agentSummary => 'agent_summary',
      ArtifactKind.patch => 'patch',
    };
  }
}

extension ArtifactStatusJson on ArtifactStatus {
  String get jsonValue {
    return switch (this) {
      ArtifactStatus.candidate => 'candidate',
      ArtifactStatus.reviewed => 'reviewed',
      ArtifactStatus.approved => 'approved',
      ArtifactStatus.rejected => 'rejected',
      ArtifactStatus.exported => 'exported',
    };
  }
}

extension ApprovalKindJson on ApprovalKind {
  String get jsonValue {
    return switch (this) {
      ApprovalKind.toolPermission => 'tool_permission',
      ApprovalKind.export => 'export',
    };
  }
}

extension ExportTargetJson on ExportTarget {
  String get jsonValue {
    return switch (this) {
      ExportTarget.simulated => 'simulated',
      ExportTarget.gitCommit => 'git_commit',
      ExportTarget.gitPush => 'git_push',
      ExportTarget.pullRequest => 'pull_request',
      ExportTarget.copyToExternalDirectory => 'copy_to_external_directory',
      ExportTarget.uploadHttp => 'upload_http',
      ExportTarget.sendWebhook => 'send_webhook',
    };
  }
}

extension ApprovalStatusJson on ApprovalStatus {
  String get jsonValue {
    return switch (this) {
      ApprovalStatus.pending => 'pending',
      ApprovalStatus.approved => 'approved',
      ApprovalStatus.denied => 'denied',
      ApprovalStatus.cancelled => 'cancelled',
    };
  }
}

TaskStatus taskStatusFromJson(
  Object? raw, {
  TaskStatus fallback = TaskStatus.inbox,
}) {
  return switch (_enumToken(raw)) {
    'inbox' => TaskStatus.inbox,
    'queued' => TaskStatus.queued,
    'dispatched' => TaskStatus.dispatched,
    'running' => TaskStatus.running,
    'blocked_on_permission' ||
    'blockedonpermission' => TaskStatus.blockedOnPermission,
    'blocked_on_user_input' ||
    'blockedonuserinput' => TaskStatus.blockedOnUserInput,
    'collecting_artifacts' ||
    'collectingartifacts' => TaskStatus.collectingArtifacts,
    'needs_human_review' || 'needshumanreview' => TaskStatus.needsHumanReview,
    'approved_for_export' ||
    'approvedforexport' => TaskStatus.approvedForExport,
    'exporting' => TaskStatus.exporting,
    'done' => TaskStatus.done,
    'failed' => TaskStatus.failed,
    'cancelled' || 'canceled' => TaskStatus.cancelled,
    'rejected' => TaskStatus.rejected,
    'needs_changes' || 'needschanges' => TaskStatus.needsChanges,
    _ => fallback,
  };
}

TaskPriority taskPriorityFromJson(
  Object? raw, {
  TaskPriority fallback = TaskPriority.normal,
}) {
  return switch (_enumToken(raw)) {
    'low' => TaskPriority.low,
    'normal' => TaskPriority.normal,
    'high' => TaskPriority.high,
    'urgent' => TaskPriority.urgent,
    _ => fallback,
  };
}

TaskEventKind taskEventKindFromJson(
  Object? raw, {
  TaskEventKind fallback = TaskEventKind.system,
}) {
  return switch (_enumToken(raw)) {
    'user' => TaskEventKind.user,
    'assistant' => TaskEventKind.assistant,
    'tool' => TaskEventKind.tool,
    'status' => TaskEventKind.status,
    'permission' => TaskEventKind.permission,
    'review' => TaskEventKind.review,
    'artifact' => TaskEventKind.artifact,
    'export' => TaskEventKind.export,
    'error' => TaskEventKind.error,
    'system' => TaskEventKind.system,
    _ => fallback,
  };
}

ArtifactKind artifactKindFromJson(
  Object? raw, {
  ArtifactKind fallback = ArtifactKind.file,
}) {
  return switch (_enumToken(raw)) {
    'git_diff' || 'gitdiff' => ArtifactKind.gitDiff,
    'git_status' || 'gitstatus' => ArtifactKind.gitStatus,
    'file' => ArtifactKind.file,
    'outbox_file' || 'outboxfile' => ArtifactKind.outboxFile,
    'test_log' || 'testlog' => ArtifactKind.testLog,
    'agent_summary' || 'agentsummary' => ArtifactKind.agentSummary,
    'patch' => ArtifactKind.patch,
    _ => fallback,
  };
}

ArtifactStatus artifactStatusFromJson(
  Object? raw, {
  ArtifactStatus fallback = ArtifactStatus.candidate,
}) {
  return switch (_enumToken(raw)) {
    'candidate' => ArtifactStatus.candidate,
    'reviewed' => ArtifactStatus.reviewed,
    'approved' => ArtifactStatus.approved,
    'rejected' => ArtifactStatus.rejected,
    'exported' => ArtifactStatus.exported,
    _ => fallback,
  };
}

ApprovalKind approvalKindFromJson(
  Object? raw, {
  ApprovalKind fallback = ApprovalKind.toolPermission,
}) {
  return switch (_enumToken(raw)) {
    'tool_permission' || 'toolpermission' => ApprovalKind.toolPermission,
    'export' => ApprovalKind.export,
    _ => fallback,
  };
}

ApprovalStatus approvalStatusFromJson(
  Object? raw, {
  ApprovalStatus fallback = ApprovalStatus.pending,
}) {
  return switch (_enumToken(raw)) {
    'pending' => ApprovalStatus.pending,
    'approved' => ApprovalStatus.approved,
    'denied' => ApprovalStatus.denied,
    'cancelled' || 'canceled' => ApprovalStatus.cancelled,
    _ => fallback,
  };
}

ExportTarget? exportTargetFromJson(Object? raw) {
  return switch (_enumToken(raw)) {
    'simulated' => ExportTarget.simulated,
    'git_commit' || 'gitcommit' => ExportTarget.gitCommit,
    'git_push' || 'gitpush' => ExportTarget.gitPush,
    'pull_request' || 'pullrequest' => ExportTarget.pullRequest,
    'copy_to_external_directory' ||
    'copytoexternaldirectory' => ExportTarget.copyToExternalDirectory,
    'upload_http' || 'uploadhttp' => ExportTarget.uploadHttp,
    'send_webhook' || 'sendwebhook' => ExportTarget.sendWebhook,
    _ => null,
  };
}

String? _enumToken(Object? raw) {
  final value = _stringFromJson(raw);
  if (value == null) return null;
  return value.replaceAll('-', '_').trim().toLowerCase();
}

Map<String, Object?>? _jsonMap(Object? raw) {
  if (raw is! Map) return null;
  return <String, Object?>{
    for (final entry in raw.entries)
      if (entry.key is String) entry.key as String: entry.value,
  };
}

String? _stringFromJson(Object? raw) {
  if (raw is! String) return null;
  final trimmed = raw.trim();
  return trimmed.isEmpty ? null : trimmed;
}

String? _rawStringFromJson(Object? raw, {bool allowEmpty = true}) {
  if (raw is! String || (!allowEmpty && raw.isEmpty)) return null;
  return raw;
}

List<String> _stringListFromJson(Object? raw) {
  if (raw is! List) return const <String>[];
  return raw
      .whereType<String>()
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty)
      .toList(growable: false);
}

DateTime? _dateTimeFromJson(Object? raw) {
  final value = _stringFromJson(raw);
  if (value == null) return null;
  return DateTime.tryParse(value);
}

int? _intFromJson(Object? raw) {
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  final value = _stringFromJson(raw);
  return value == null ? null : int.tryParse(value);
}
