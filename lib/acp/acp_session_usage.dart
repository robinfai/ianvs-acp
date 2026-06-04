class AcpSessionUsage {
  const AcpSessionUsage({required this.used, required this.size, this.cost});

  final int used;
  final int size;
  final AcpSessionUsageCost? cost;

  int get remaining => size - used;

  double? get percentage => size <= 0 ? null : used / size;
}

class AcpSessionUsageCost {
  const AcpSessionUsageCost({required this.amount, required this.currency});

  final num amount;
  final String currency;
}
