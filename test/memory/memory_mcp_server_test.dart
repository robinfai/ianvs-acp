import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/memory/memory_config.dart';
import 'package:ianvs_acp/memory/memory_daemon_manager.dart';
import 'package:ianvs_acp/memory/memory_mcp_server.dart';

void main() {
  test(
    'builds app-owned memory MCP server with daemon endpoint and policy',
    () {
      final server = buildMemoryMcpServerConfig(
        executable: '/tmp/memory-core',
        endpoint: MemoryDaemonEndpoint(
          baseUrl: Uri.parse('http://127.0.0.1:43129'),
          token: 'secret-token',
        ),
        memory: const MemoryConfig(
          review: MemoryReviewConfig(
            mode: 'high_confidence_auto',
            highConfidenceThreshold: 0.91,
          ),
        ),
      );

      expect(server['name'], 'ianvs-memory');
      expect(server['type'], 'stdio');
      expect(server['command'], '/tmp/memory-core');
      expect(server['args'], [
        '--mode',
        'mcp-stdio',
        '--daemon-url',
        'http://127.0.0.1:43129',
      ]);
      final env = (server['env'] as List).cast<Map<String, String>>();
      expect(
        env.any(
          (entry) =>
              entry['name'] == 'MEMORY_DAEMON_TOKEN' &&
              entry['value'] == 'secret-token',
        ),
        isTrue,
      );
      expect(
        env.any(
          (entry) =>
              entry['name'] == 'MEMORY_AUTO_APPROVE_THRESHOLD' &&
              entry['value'] == '0.91',
        ),
        isTrue,
      );
    },
  );

  test('omits memory MCP auto approve env when new memory is manual', () {
    final server = buildMemoryMcpServerConfig(
      executable: '/tmp/memory-core',
      endpoint: MemoryDaemonEndpoint(
        baseUrl: Uri.parse('http://127.0.0.1:43129'),
        token: 'secret-token',
      ),
      memory: const MemoryConfig(
        review: MemoryReviewConfig(mode: 'manual_review'),
      ),
    );

    expect(
      server['env'],
      isNot(
        contains(
          predicate<Map<String, String>>(
            (env) => env['name'] == 'MEMORY_AUTO_APPROVE_THRESHOLD',
          ),
        ),
      ),
    );
  });

  test('keeps MCP maintenance auto policy separate from candidate review', () {
    final server = buildMemoryMcpServerConfig(
      executable: '/tmp/memory-core',
      endpoint: MemoryDaemonEndpoint(
        baseUrl: Uri.parse('http://127.0.0.1:43129'),
        token: 'secret-token',
      ),
      memory: const MemoryConfig(
        review: MemoryReviewConfig(mode: 'manual_review'),
        maintenance: MemoryMaintenanceConfig(
          mode: 'high_confidence_auto',
          highConfidenceThreshold: 0.92,
        ),
      ),
    );

    final env = (server['env'] as List).cast<Map<String, String>>();
    expect(
      env.any((entry) => entry['name'] == 'MEMORY_AUTO_APPROVE_THRESHOLD'),
      isFalse,
    );
    expect(
      env.any(
        (entry) =>
            entry['name'] == 'MEMORY_CHANGE_REQUEST_AUTO_APPROVE_THRESHOLD' &&
            entry['value'] == '0.92',
      ),
      isTrue,
    );
  });
}
