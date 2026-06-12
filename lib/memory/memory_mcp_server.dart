import 'automatic_memory_maintenance.dart';
import 'memory_config.dart';
import 'memory_daemon_manager.dart';

const String memoryMcpServerName = 'ianvs-memory';

Map<String, dynamic> buildMemoryMcpServerConfig({
  required String executable,
  required MemoryDaemonEndpoint endpoint,
  required MemoryConfig memory,
}) {
  final env = <Map<String, String>>[
    {'name': 'MEMORY_DAEMON_TOKEN', 'value': endpoint.token},
  ];
  final threshold = candidateAutoApproveThreshold(memory.review);
  if (threshold != null) {
    env.add({
      'name': 'MEMORY_AUTO_APPROVE_THRESHOLD',
      'value': _formatThreshold(threshold),
    });
  }
  final changeRequestThreshold = changeRequestAutoApproveThreshold(
    memory.maintenance,
  );
  if (changeRequestThreshold != null) {
    env.add({
      'name': 'MEMORY_CHANGE_REQUEST_AUTO_APPROVE_THRESHOLD',
      'value': _formatThreshold(changeRequestThreshold),
    });
  }

  return <String, dynamic>{
    'name': memoryMcpServerName,
    'type': 'stdio',
    'command': executable,
    'args': <String>[
      '--mode',
      'mcp-stdio',
      '--daemon-url',
      endpoint.baseUrl.toString(),
    ],
    'env': env,
  };
}

String _formatThreshold(double threshold) {
  final clamped = threshold.clamp(0.0, 1.0);
  if (clamped == clamped.roundToDouble()) return clamped.toStringAsFixed(0);
  return clamped.toString();
}
