/// Application-wide retention and capacity policy for SQLite-backed data.
class SqliteStorageConfig {
  const SqliteStorageConfig({
    this.maxSizeGb = defaultMaxSizeGb,
    this.retentionDays = defaultRetentionDays,
  });

  static const int defaultMaxSizeGb = 50;
  static const int defaultRetentionDays = 30;
  static const int bytesPerGb = 1024 * 1024 * 1024;

  final int maxSizeGb;
  final int retentionDays;

  int get maxBytes => maxSizeGb * bytesPerGb;

  Duration get retention => Duration(days: retentionDays);

  factory SqliteStorageConfig.fromJson(Object? raw) {
    if (raw is! Map) return const SqliteStorageConfig();
    return SqliteStorageConfig(
      maxSizeGb: _positiveInt(
        raw['max_size_gb'] ?? raw['maxSizeGb'],
        defaultMaxSizeGb,
        field: 'storage.max_size_gb',
        maximum: 8192,
      ),
      retentionDays: _positiveInt(
        raw['retention_days'] ?? raw['retentionDays'],
        defaultRetentionDays,
        field: 'storage.retention_days',
        maximum: 3650,
      ),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'max_size_gb': maxSizeGb,
    'retention_days': retentionDays,
  };
}

int _positiveInt(
  Object? raw,
  int fallback, {
  required String field,
  required int maximum,
}) {
  if (raw == null) return fallback;
  if (raw is! int || raw <= 0 || raw > maximum) {
    throw FormatException('$field must be an integer between 1 and $maximum.');
  }
  return raw;
}
