import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/memory/memory_config.dart';
import 'package:ianvs_acp/memory/memory_mcp_server_config.dart';

void main() {
  test('memory MCP server receives review approval policy environment', () {
    final config = buildMemoryMcpServerConfig(
      command: '/tmp/memory-core',
      daemonUrl: Uri.parse('http://127.0.0.1:43130'),
      token: 'secret-token',
      review: const MemoryReviewConfig(
        approvalMode: MemoryApprovalMode.autoHighConfidence,
        highConfidenceThreshold: 0.91,
      ),
      maintenance: const MemoryMaintenanceConfig(
        enabled: false,
        mode: 'manual_review',
        costMode: 'low_cost',
        runAfterExtraction: false,
        highConfidenceThreshold: 0.93,
        reviewThreshold: 0.77,
        maxItemsPerBatch: 8,
        manualOnlyActions: ['delete', 'expire'],
      ),
    );

    expect(config['name'], 'ianvs-memory');
    expect(config['type'], 'stdio');
    expect(config['command'], '/tmp/memory-core');
    expect(config['args'], [
      '--mode',
      'mcp-stdio',
      '--daemon-url',
      'http://127.0.0.1:43130',
    ]);
    final env = {
      for (final entry in config['env'] as List)
        (entry as Map)['name'] as String: entry['value'] as String,
    };
    expect(env['MEMORY_DAEMON_TOKEN'], 'secret-token');
    expect(env['MEMORY_REVIEW_APPROVAL_MODE'], 'auto_high_confidence');
    expect(env['MEMORY_REVIEW_HIGH_CONFIDENCE_THRESHOLD'], '0.91');
    expect(env['MEMORY_MAINTENANCE_ENABLED'], 'false');
    expect(env['MEMORY_MAINTENANCE_MODE'], 'manual_review');
    expect(env['MEMORY_MAINTENANCE_COST_MODE'], 'low_cost');
    expect(env['MEMORY_MAINTENANCE_RUN_AFTER_EXTRACTION'], 'false');
    expect(env['MEMORY_MAINTENANCE_HIGH_CONFIDENCE_THRESHOLD'], '0.93');
    expect(env['MEMORY_MAINTENANCE_REVIEW_THRESHOLD'], '0.77');
    expect(env['MEMORY_MAINTENANCE_MAX_ITEMS_PER_BATCH'], '8');
    expect(env['MEMORY_MAINTENANCE_MANUAL_ONLY_ACTIONS'], 'delete,expire');
  });
}
