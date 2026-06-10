import 'package:flutter/material.dart';

import '../theme/app_design_tokens.dart';

class MemoryReviewCandidate {
  const MemoryReviewCandidate({
    required this.id,
    required this.kind,
    required this.scope,
    required this.text,
    this.confidence,
    this.reason,
  });

  final String id;
  final String kind;
  final String scope;
  final String text;
  final double? confidence;
  final String? reason;
}

class MemoryReviewPanel extends StatelessWidget {
  const MemoryReviewPanel({
    super.key,
    this.candidates = const [],
    this.onApprove,
    this.onEdit,
    this.onReject,
  });

  final List<MemoryReviewCandidate> candidates;
  final ValueChanged<MemoryReviewCandidate>? onApprove;
  final ValueChanged<MemoryReviewCandidate>? onEdit;
  final ValueChanged<MemoryReviewCandidate>? onReject;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 300,
      color: AppColors.surfaceRaised,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Memory Review',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w800,
              letterSpacing: 0,
            ),
          ),
          const SizedBox(height: 10),
          if (candidates.isEmpty)
            const Text(
              'No candidates',
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 13,
                letterSpacing: 0,
              ),
            )
          else
            for (final candidate in candidates) ...[
              _MemoryCandidateCard(
                candidate: candidate,
                onApprove: onApprove,
                onEdit: onEdit,
                onReject: onReject,
              ),
              const SizedBox(height: 10),
            ],
        ],
      ),
    );
  }
}

class _MemoryCandidateCard extends StatelessWidget {
  const _MemoryCandidateCard({
    required this.candidate,
    this.onApprove,
    this.onEdit,
    this.onReject,
  });

  final MemoryReviewCandidate candidate;
  final ValueChanged<MemoryReviewCandidate>? onApprove;
  final ValueChanged<MemoryReviewCandidate>? onEdit;
  final ValueChanged<MemoryReviewCandidate>? onReject;

  @override
  Widget build(BuildContext context) {
    final confidence = candidate.confidence == null
        ? null
        : '${(candidate.confidence! * 100).round()}%';
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: AppColors.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              [candidate.kind, candidate.scope, ?confidence].join(' · '),
              style: const TextStyle(
                color: AppColors.textTertiary,
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 0,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              candidate.text,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 13,
                height: 1.35,
                fontWeight: FontWeight.w700,
                letterSpacing: 0,
              ),
            ),
            if (candidate.reason != null) ...[
              const SizedBox(height: 6),
              Text(
                candidate.reason!,
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                  height: 1.35,
                  letterSpacing: 0,
                ),
              ),
            ],
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                TextButton.icon(
                  onPressed: onApprove == null
                      ? null
                      : () => onApprove!(candidate),
                  icon: const Icon(Icons.check_rounded, size: 16),
                  label: const Text('Approve'),
                ),
                TextButton.icon(
                  onPressed: onEdit == null ? null : () => onEdit!(candidate),
                  icon: const Icon(Icons.edit_rounded, size: 15),
                  label: const Text('Edit'),
                ),
                TextButton.icon(
                  onPressed: onReject == null
                      ? null
                      : () => onReject!(candidate),
                  icon: const Icon(Icons.close_rounded, size: 15),
                  label: const Text('Reject'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
