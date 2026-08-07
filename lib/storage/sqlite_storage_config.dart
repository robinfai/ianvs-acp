enum SqliteStoreKind { workflow, taskInboxLegacy, acpSessions }

/// Application-wide retention and capacity policy for SQLite-backed data.
///
/// The configured limit is a total budget. Individual databases receive fixed
/// shares so enabling multiple stores cannot multiply the advertised limit.
class SqliteStorageConfig {
  const SqliteStorageConfig({
    this.maxSizeGb = defaultMaxSizeGb,
    this.retentionDays = defaultRetentionDays,
    this.cleanupIntervalHours = defaultCleanupIntervalHours,
  });

  static const int defaultMaxSizeGb = 50;
  static const int defaultRetentionDays = 30;
  static const int defaultCleanupIntervalHours = 24;
  static const int bytesPerGb = 1024 * 1024 * 1024;

  final int maxSizeGb;
  final int retentionDays;
  final int cleanupIntervalHours;

  int get maxBytes => maxSizeGb * bytesPerGb;

  Duration get retention => Duration(days: retentionDays);

  Duration get cleanupInterval => Duration(hours: cleanupIntervalHours);

  int budgetBytesFor(SqliteStoreKind kind) {
    final total = maxBytes;
    final legacy = total * 4 ~/ 100;
    final sessions = total ~/ 100;
    final workflow = total - legacy - sessions;
    return switch (kind) {
      SqliteStoreKind.workflow => workflow,
      SqliteStoreKind.taskInboxLegacy => legacy,
      SqliteStoreKind.acpSessions => sessions,
    };
  }

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
      cleanupIntervalHours: _positiveInt(
        raw['cleanup_interval_hours'] ?? raw['cleanupIntervalHours'],
        defaultCleanupIntervalHours,
        field: 'storage.cleanup_interval_hours',
        maximum: 24 * 30,
      ),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'max_size_gb': maxSizeGb,
    'retention_days': retentionDays,
    'cleanup_interval_hours': cleanupIntervalHours,
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
