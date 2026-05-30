import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/dart_acp_agent_client.dart';

void main() {
  test('copies configured MCP servers for session setup', () {
    final mcpServer = <String, dynamic>{
      'name': 'filesystem',
      'command': '/usr/local/bin/mcp-filesystem',
      'args': ['--mode', 'readonly'],
    };

    final client = DartAcpAgentClient(mcpServers: [mcpServer]);
    mcpServer['name'] = 'mutated';

    expect(client.mcpServers, hasLength(1));
    expect(client.mcpServers.single['name'], 'filesystem');
    expect(
      client.mcpServers.single['command'],
      '/usr/local/bin/mcp-filesystem',
    );
  });
}
