import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart' as mcp;

import '../config/acp_client_config.dart';
import 'task_center_agent_api.dart';
import 'task_center_store.dart';

class TaskCenterMcpHost {
  TaskCenterMcpHost({
    required this.store,
    this.host = '127.0.0.1',
    this.startPort = 38971,
    this.maxPortAttempts = 20,
  });

  static const String serverName = 'ianvs-task-center';

  final TaskCenterStore store;
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
    final api = TaskCenterAgentApi(store: store);
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

    return server;
  }
}

String _toolDescription(String name) {
  return switch (name) {
    'task_center_create_workspace' => 'Create a local task workspace.',
    'task_center_list_workspaces' => 'List local task workspaces.',
    'task_center_create_task' => 'Create a task in a workspace.',
    'task_center_update_task' =>
      'Update task title, description, status, or metadata.',
    'task_center_move_task' => 'Move a task to a status column and position.',
    'task_center_list_tasks' => 'List tasks in a workspace.',
    'task_center_delete_task' => 'Delete a task from a workspace.',
    _ => 'Task center tool.',
  };
}

mcp.JsonObject _toolInputSchema(String name) {
  return switch (name) {
    'task_center_create_workspace' => _schema(
      properties: <String, mcp.JsonSchema>{
        'title': _stringSchema('Workspace title.'),
        'description': _stringSchema('Optional workspace description.'),
      },
      required: const <String>['title'],
    ),
    'task_center_list_workspaces' => _schema(),
    'task_center_create_task' => _schema(
      properties: <String, mcp.JsonSchema>{
        'workspace_id': _stringSchema('Target workspace id.'),
        'title': _stringSchema('Task title.'),
        'description': _stringSchema('Optional task description.'),
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
        'status': _statusSchema(),
        'metadata': _objectSchema('Replacement task metadata.'),
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

mcp.JsonString _statusSchema() {
  return mcp.JsonSchema.string(
    enumValues: const <String>['todo', 'in_progress', 'review', 'done'],
    description: 'Task status column.',
  );
}
