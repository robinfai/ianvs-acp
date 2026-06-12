class MemoryPendingReviewSummary {
  const MemoryPendingReviewSummary({
    required this.candidateCount,
    required this.changeRequestCount,
  });

  static const empty = MemoryPendingReviewSummary(
    candidateCount: 0,
    changeRequestCount: 0,
  );

  final int candidateCount;
  final int changeRequestCount;

  int get totalCount => candidateCount + changeRequestCount;

  bool get hasPending => totalCount > 0;
}
