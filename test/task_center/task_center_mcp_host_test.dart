import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/task_center/task_center_mcp_host.dart';
import 'package:ianvs_acp/task_center/task_center_store.dart';
import 'package:mcp_dart/mcp_dart.dart' as mcp;

void main() {
  test('serves task center tools over local streamable HTTP MCP', () async {
    final temp = await Directory.systemTemp.createTemp('ianvs_task_center_mcp');
    addTearDown(() => temp.delete(recursive: true));
    final ids = _IdSequence();
    final store = TaskCenterStore(
      path: '${temp.path}/task_center.json',
      now: () => DateTime.utc(2026, 6, 16, 12),
      idGenerator: ids.next,
    );
    final host = TaskCenterMcpHost(store: store, startPort: 48651);
    await host.start();
    addTearDown(host.stop);

    expect(host.mcpServerConfig.url, 'http://127.0.0.1:48651/mcp');

    final transport = mcp.StreamableHttpClientTransport(
      Uri.parse(host.mcpServerConfig.url),
    );
    final client = mcp.McpClient(
      const mcp.Implementation(name: 'task-center-test', version: '1.0.0'),
    );
    await client.connect(transport);
    addTearDown(() async {
      await transport.close();
    });

    final tools = await client.listTools();
    expect(
      tools.tools.map((tool) => tool.name),
      contains('task_center_create_workspace'),
    );
    expect(
      tools.tools.map((tool) => tool.name),
      contains('task_center_start_work_run'),
    );
    expect(
      tools.tools.map((tool) => tool.name),
      contains('task_center_recover_stalled_task'),
    );

    final result = await client.callTool(
      mcp.CallToolRequest(
        name: 'task_center_create_workspace',
        arguments: {'title': 'MCP workspace'},
      ),
    );

    expect(result.structuredContent?['workspace'], isA<Map<String, Object?>>());
    expect(
      (result.structuredContent!['workspace'] as Map<String, Object?>)['id'],
      'id-1',
    );

    final taskResult = await client.callTool(
      mcp.CallToolRequest(
        name: 'task_center_create_task',
        arguments: {
          'workspace_id': 'id-1',
          'title': 'MCP worker task',
          'current_owner': {'kind': 'work_agent', 'agent_name': 'worker-a'},
          'readiness': 'ready',
        },
      ),
    );
    expect(
      (taskResult.structuredContent!['task'] as Map<String, Object?>)['id'],
      'id-2',
    );

    final startRunResult = await client.callTool(
      mcp.CallToolRequest(
        name: 'task_center_start_work_run',
        arguments: {
          'workspace_id': 'id-1',
          'task_id': 'id-2',
          'agent_name': 'worker-a',
          'session_id': 'session-1',
          'progress_summary': 'started',
        },
      ),
    );
    final startedTask =
        startRunResult.structuredContent!['task'] as Map<String, Object?>;
    final workRuns = startedTask['work_runs'] as List<Object?>;
    expect(workRuns, hasLength(1));
    expect((workRuns.single as Map<String, Object?>)['id'], 'id-3');

    final heartbeatResult = await client.callTool(
      mcp.CallToolRequest(
        name: 'task_center_heartbeat_work_run',
        arguments: {
          'workspace_id': 'id-1',
          'task_id': 'id-2',
          'run_id': 'id-3',
          'state': 'running',
          'progress_summary': 'still running',
          'next_check_minutes': 5,
          'actor': 'worker-a',
        },
      ),
    );
    final heartbeatTask =
        heartbeatResult.structuredContent!['task'] as Map<String, Object?>;
    final heartbeatRuns = heartbeatTask['work_runs'] as List<Object?>;
    expect(
      (heartbeatRuns.single as Map<String, Object?>)['progress_summary'],
      'still running',
    );
    final persistedAfterHeartbeat = await store.load();
    expect(
      persistedAfterHeartbeat.workspaces.single.tasks.single.events.map(
        (event) => event.type,
      ),
      contains('work_run_heartbeat'),
    );

    final resources = await client.listResources();
    const snapshotResourceUri = 'task-center://snapshot';
    expect(
      resources.resources.map((resource) => resource.uri),
      contains(snapshotResourceUri),
    );

    final snapshot = await client.readResource(
      const mcp.ReadResourceRequest(uri: snapshotResourceUri),
    );
    final content = snapshot.contents.single as mcp.TextResourceContents;
    expect(content.mimeType, 'application/json');
    expect(content.text, contains('"title":"MCP workspace"'));
  });
}

class _IdSequence {
  int _next = 1;

  String next() => 'id-${_next++}';
}
