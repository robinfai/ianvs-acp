import 'memory_api_client.dart';
import 'memory_config.dart';

bool shouldRunAutomaticMemoryMaintenance(MemoryMaintenanceConfig maintenance) {
  if (!maintenance.enabled) return false;
  final mode = maintenance.mode.trim().toLowerCase();
  return mode == 'high_confidence_auto' ||
      mode == 'auto' ||
      mode == 'automatic';
}

double? candidateAutoApproveThreshold(MemoryReviewConfig review) {
  final mode = review.mode.trim().toLowerCase();
  if (mode == 'auto' || mode == 'automatic') return 0.0;
  if (mode == 'high_confidence' || mode == 'high_confidence_auto') {
    return review.highConfidenceThreshold.clamp(0.0, 1.0);
  }
  return null;
}

double? changeRequestAutoApproveThreshold(MemoryMaintenanceConfig maintenance) {
  if (!shouldRunAutomaticMemoryMaintenance(maintenance)) return null;
  return maintenance.highConfidenceThreshold.clamp(0.0, 1.0);
}

bool shouldRunMaintenanceAfterCandidateExtraction({
  required MemoryMaintenanceConfig maintenance,
  required CreateCandidatesResult result,
}) {
  if (!maintenance.enabled || result.approvedMemories.isEmpty) return false;
  return shouldRunAutomaticMemoryMaintenance(maintenance);
}

bool shouldRunMaintenanceAfterCandidateApproval({
  required MemoryMaintenanceConfig maintenance,
}) {
  return shouldRunAutomaticMemoryMaintenance(maintenance);
}
