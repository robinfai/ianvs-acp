import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/config/acp_client_config.dart';
import 'package:ianvs_acp/config/acp_config_store.dart';
import 'package:ianvs_acp/storage/sqlite_storage_config.dart';

void main() {
  test('defaults to a 50 GB ACP session-registry budget', () {
    const storage = SqliteStorageConfig();

    expect(storage.maxSizeGb, 50);
    expect(storage.retentionDays, 30);
    expect(storage.maxBytes, 50 * SqliteStorageConfig.bytesPerGb);
  });

  test('loads and serializes a custom storage policy', () {
    final config = AcpClientConfig.fromJson({
      'storage': {'max_size_gb': 120, 'retention_days': 45},
    });

    expect(config.storage.maxSizeGb, 120);
    expect(config.storage.retentionDays, 45);
    expect(AcpConfigStore.toSettingsJson(config)['storage'], {
      'max_size_gb': 120,
      'retention_days': 45,
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
