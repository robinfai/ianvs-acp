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
  });
}

class _IdSequence {
  int _next = 1;

  String next() => 'id-${_next++}';
}
