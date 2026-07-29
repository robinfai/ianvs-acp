import 'memory_config.dart';

Map<String, dynamic> buildMemoryMcpServerConfig({
  required String command,
  required Uri daemonUrl,
  required String token,
  required MemoryReviewConfig review,
  required MemoryMaintenanceConfig maintenance,
}) {
  return <String, dynamic>{
    'name': 'ianvs-memory',
    'type': 'stdio',
    'command': command,
    'args': <String>[
      '--mode',
      'mcp-stdio',
      '--daemon-url',
      daemonUrl.toString(),
    ],
    'env': <Map<String, String>>[
      <String, String>{'name': 'MEMORY_DAEMON_TOKEN', 'value': token},
      <String, String>{
        'name': 'MEMORY_REVIEW_APPROVAL_MODE',
        'value': review.approvalMode,
      },
      <String, String>{
        'name': 'MEMORY_REVIEW_HIGH_CONFIDENCE_THRESHOLD',
        'value': review.highConfidenceThreshold.toString(),
      },
      <String, String>{
        'name': 'MEMORY_MAINTENANCE_ENABLED',
        'value': maintenance.enabled.toString(),
      },
      <String, String>{
        'name': 'MEMORY_MAINTENANCE_MODE',
        'value': maintenance.mode,
      },
      <String, String>{
        'name': 'MEMORY_MAINTENANCE_COST_MODE',
        'value': maintenance.costMode,
      },
      <String, String>{
        'name': 'MEMORY_MAINTENANCE_RUN_AFTER_EXTRACTION',
        'value': maintenance.runAfterExtraction.toString(),
      },
      <String, String>{
        'name': 'MEMORY_MAINTENANCE_HIGH_CONFIDENCE_THRESHOLD',
        'value': maintenance.highConfidenceThreshold.toString(),
      },
      <String, String>{
        'name': 'MEMORY_MAINTENANCE_REVIEW_THRESHOLD',
        'value': maintenance.reviewThreshold.toString(),
      },
      <String, String>{
        'name': 'MEMORY_MAINTENANCE_MAX_ITEMS_PER_BATCH',
        'value': maintenance.maxItemsPerBatch.toString(),
      },
      <String, String>{
        'name': 'MEMORY_MAINTENANCE_MANUAL_ONLY_ACTIONS',
        'value': maintenance.manualOnlyActions.join(','),
      },
    ],
  };
}
