import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/config/acp_client_config.dart';
import 'package:ianvs_acp/config/acp_config_store.dart';
import 'package:ianvs_acp/storage/sqlite_storage_config.dart';

void main() {
  test('defaults to a shared 50 GB SQLite budget', () {
    const storage = SqliteStorageConfig();

    expect(storage.maxSizeGb, 50);
    expect(storage.retentionDays, 30);
    expect(storage.cleanupIntervalHours, 24);
    expect(
      SqliteStoreKind.values
          .map(storage.budgetBytesFor)
          .reduce((left, right) => left + right),
      storage.maxBytes,
    );
  });

  test('loads and serializes a custom storage policy', () {
    final config = AcpClientConfig.fromJson({
      'storage': {
        'max_size_gb': 120,
        'retention_days': 45,
        'cleanup_interval_hours': 6,
      },
    });

    expect(config.storage.maxSizeGb, 120);
    expect(config.storage.retentionDays, 45);
    expect(config.storage.cleanupIntervalHours, 6);
    expect(AcpConfigStore.toSettingsJson(config)['storage'], {
      'max_size_gb': 120,
      'retention_days': 45,
      'cleanup_interval_hours': 6,
    });
  });

  test('rejects unsafe storage policy values', () {
    expect(
      () => AcpClientConfig.fromJson({
        'storage': {'max_size_gb': 0},
      }),
      throwsFormatException,
    );
    expect(
      () => AcpClientConfig.fromJson({
        'storage': {'retention_days': -1},
      }),
      throwsFormatException,
    );
  });
}
