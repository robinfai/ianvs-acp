import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/tasks/task_inbox_snapshot.dart';
import 'package:ianvs_acp/tasks/task_inbox_state_store.dart';
import 'package:ianvs_acp/tasks/task_record.dart';
import 'package:ianvs_acp/tasks/workspace_resource.dart';

void main() {
  test('TaskInboxStateStore resolves default path near config', () {
    final path = TaskInboxStateStore.defaultPath(
      configPath: '/tmp/ianvs-acp/settings.json',
      environment: const {'HOME': '/Users/example'},
    );

    expect(path, '/tmp/ianvs-acp/task_inbox_state.json');
  });

  test('TaskInboxStateStore resolves default path from XDG config', () {
    final path = TaskInboxStateStore.defaultPath(
      environment: const {
        'XDG_CONFIG_HOME': '/Users/example/.config-alt',
        'HOME': '/Users/example',
      },
    );

    expect(path, '/Users/example/.config-alt/ianvs-acp/task_inbox_state.json');
  });

  test(
    'TaskInboxStateStore loads missing and malformed files as empty',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'ianvs-acp-task-store-',
      );
      addTearDown(() async => tempDir.delete(recursive: true));
      final file = File('${tempDir.path}/task_inbox_state.json');
      final store = TaskInboxStateStore(path: file.path);

      expect((await store.load()).tasks, isEmpty);

      await file.writeAsString('{bad json');
      final malformed = await store.load();

      expect(malformed.tasks, isEmpty);
      expect(malformed.runs, isEmpty);
      expect(malformed.events, isEmpty);
      expect(malformed.artifacts, isEmpty);
      expect(malformed.approvals, isEmpty);
    },
  );

  test('TaskInboxStateStore saves and loads complete task snapshot', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'ianvs-acp-task-store-',
    );
    addTearDown(() async => tempDir.delete(recursive: true));
    final file = File('${tempDir.path}/nested/task_inbox_state.json');
    final store = TaskInboxStateStore(path: file.path);
    final createdAt = DateTime(2026, 7, 7, 8);
    final updatedAt = DateTime(2026, 7, 7, 9);
    final snapshot = TaskInboxSnapshot(
      updatedAt: updatedAt,
      tasks: [
        TaskRecord(
          id: 'task-1',
          title: 'Implement inbox',
          description: 'Add local task store',
          workspacePath: '/workspace/app',
          agentName: 'Codex',
          status: TaskStatus.needsHumanReview,
          priority: TaskPriority.high,
          createdAt: createdAt,
          updatedAt: updatedAt,
          sessionId: 'session-1',
          currentRunId: 'run-1',
          summary: 'Ready for review',
          resourceId: 'resource-1',
          skillIds: const ['skill-review'],
          metadata: const {'source': 'test'},
        ),
      ],
      resources: [
        WorkspaceResource.localDirectory(
          id: 'resource-1',
          label: 'App workspace',
          path: '/workspace/app',
        ),
      ],
      runs: [
        TaskRunRecord(
          id: 'run-1',
          taskId: 'task-1',
          attempt: 2,
          status: TaskStatus.collectingArtifacts,
          startedAt: createdAt,
          endedAt: updatedAt,
          sessionId: 'session-1',
          promptSnapshot: 'prompt text',
          model: 'gpt-5',
        ),
      ],
      events: [
        TaskEventRecord(
          id: 'event-1',
          taskId: 'task-1',
          runId: 'run-1',
          kind: TaskEventKind.system,
          text: 'started',
          createdAt: createdAt,
          sessionId: 'session-1',
          metadata: const {'phase': 'run'},
        ),
      ],
      artifacts: [
        ArtifactRecord(
          id: 'artifact-1',
          taskId: 'task-1',
          runId: 'run-1',
          kind: ArtifactKind.gitDiff,
          status: ArtifactStatus.approved,
          title: 'Git diff',
          createdAt: updatedAt,
          path: 'lib/tasks/task_record.dart',
          contentPreview: 'diff --git',
          sha256: 'abc123',
          sizeBytes: 42,
          metadata: const {'truncated': false},
        ),
      ],
      approvals: [
        ApprovalRequestRecord(
          id: 'approval-1',
          taskId: 'task-1',
          runId: 'run-1',
          kind: ApprovalKind.toolPermission,
          status: ApprovalStatus.pending,
          createdAt: updatedAt,
          rationale: 'Test approval',
          metadata: const {'requestedBy': 'user'},
        ),
      ],
    );

    await store.save(snapshot);
    final loaded = await store.load();

    expect(loaded.tasks, hasLength(1));
    expect(loaded.tasks.single.title, 'Implement inbox');
    expect(loaded.tasks.single.status, TaskStatus.needsHumanReview);
    expect(loaded.tasks.single.priority, TaskPriority.high);
    expect(loaded.tasks.single.sessionId, 'session-1');
    expect(loaded.tasks.single.resourceId, 'resource-1');
    expect(loaded.tasks.single.skillIds, ['skill-review']);
    expect(loaded.resources.single.id, 'resource-1');
    expect(loaded.resources.single.type, ResourceType.localDirectory);
    expect(loaded.resources.single.ref['path'], '/workspace/app');
    expect(loaded.runs.single.attempt, 2);
    expect(loaded.runs.single.model, 'gpt-5');
    expect(loaded.events.single.kind, TaskEventKind.system);
    expect(loaded.events.single.metadata['phase'], 'run');
    expect(loaded.artifacts.single.kind, ArtifactKind.gitDiff);
    expect(loaded.artifacts.single.status, ArtifactStatus.approved);
    expect(loaded.artifacts.single.sizeBytes, 42);
    expect(loaded.approvals.single.kind, ApprovalKind.toolPermission);
    expect(loaded.approvals.single.rationale, 'Test approval');

    final raw = jsonDecode(await file.readAsString()) as Map<String, Object?>;
    expect(raw['schema'], TaskInboxSnapshot.schema);
    expect(raw['tasks'], isA<List<Object?>>());
    expect(raw['resources'], isA<List<Object?>>());
  });

  test('TaskInboxSnapshot handles unknown enum values safely', () {
    final snapshot = TaskInboxSnapshot.fromJson({
      'updated_at': '2026-07-07T09:00:00.000',
      'tasks': [
        {
          'id': 'task-1',
          'title': 'Unknown status task',
          'description': '',
          'workspace_path': '/workspace/app',
          'agent_name': 'Codex',
          'status': 'future_status',
          'priority': 'future_priority',
          'created_at': '2026-07-07T08:00:00.000',
          'updated_at': '2026-07-07T09:00:00.000',
        },
      ],
      'events': [
        {
          'id': 'event-1',
          'task_id': 'task-1',
          'run_id': 'run-1',
          'kind': 'future_event',
          'text': 'unknown',
          'created_at': '2026-07-07T09:00:00.000',
        },
      ],
      'artifacts': [
        {
          'id': 'artifact-1',
          'task_id': 'task-1',
          'run_id': 'run-1',
          'kind': 'future_artifact',
          'status': 'future_artifact_status',
          'title': 'unknown',
          'created_at': '2026-07-07T09:00:00.000',
        },
      ],
      'approvals': [
        {
          'id': 'approval-1',
          'task_id': 'task-1',
          'kind': 'future_approval',
          'status': 'future_status',
          'created_at': '2026-07-07T09:00:00.000',
        },
      ],
    });

    expect(snapshot.tasks.single.status, TaskStatus.inbox);
    expect(snapshot.tasks.single.priority, TaskPriority.normal);
    expect(snapshot.events.single.kind, TaskEventKind.system);
    expect(snapshot.artifacts.single.kind, ArtifactKind.file);
    expect(snapshot.artifacts.single.status, ArtifactStatus.candidate);
    expect(snapshot.approvals.single.kind, ApprovalKind.toolPermission);
    expect(snapshot.approvals.single.status, ApprovalStatus.pending);
  });

  test('TaskInboxSnapshot persists dispatched task status', () {
    final snapshot = TaskInboxSnapshot.fromJson({
      'updated_at': '2026-07-09T09:00:00.000',
      'tasks': [
        {
          'id': 'task-1',
          'title': 'Dispatched task',
          'description': '',
          'workspace_path': '/workspace/app',
          'agent_name': 'Codex',
          'status': 'dispatched',
          'priority': 'normal',
          'created_at': '2026-07-09T08:00:00.000',
          'updated_at': '2026-07-09T09:00:00.000',
        },
      ],
      'runs': [
        {
          'id': 'run-1',
          'task_id': 'task-1',
          'attempt': 1,
          'status': 'dispatched',
          'started_at': '2026-07-09T09:00:00.000',
        },
      ],
    });

    expect(snapshot.tasks.single.status, TaskStatus.dispatched);
    expect(snapshot.runs.single.status, TaskStatus.dispatched);
    expect(
      snapshot.toJson()['tasks'],
      contains(containsPair('status', 'dispatched')),
    );
  });

  test('TaskInboxSnapshot resolves duplicate ids deterministically', () {
    final snapshot = TaskInboxSnapshot.fromJson({
      'tasks': [
        {
          'id': 'task-1',
          'title': 'First value',
          'description': '',
          'workspace_path': '/workspace/app',
          'agent_name': 'Codex',
          'status': 'inbox',
          'priority': 'normal',
          'created_at': '2026-07-07T08:00:00.000',
          'updated_at': '2026-07-07T08:00:00.000',
        },
        {
          'id': 'task-1',
          'title': 'Last value',
          'description': '',
          'workspace_path': '/workspace/app',
          'agent_name': 'Codex',
          'status': 'done',
          'priority': 'normal',
          'created_at': '2026-07-07T08:00:00.000',
          'updated_at': '2026-07-07T09:00:00.000',
        },
      ],
    });

    expect(snapshot.tasks, hasLength(1));
    expect(snapshot.tasks.single.title, 'Last value');
    expect(snapshot.tasks.single.status, TaskStatus.done);
  });
}
