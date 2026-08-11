import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/config/secret_field_policy.dart';

void main() {
  test('ordinary process environment is not protected', () {
    for (final key in <String>[
      'PATH',
      'HOME',
      'LANG',
      'NODE_OPTIONS',
      'RUST_LOG',
      'FEATURE_ENABLED',
      'SSH_AUTH_SOCK',
      'AUTH_MODE',
      'OLDPWD',
      'PWD',
      'PASSWORDLESS_MODE',
      'COMPATIBILITY',
    ]) {
      expect(
        isProtectedConfigValue(field: ConfigSecretField.environment, key: key),
        isFalse,
        reason: key,
      );
    }
  });

  test('credential-shaped environment names are protected', () {
    for (final key in <String>[
      'OPENAI_API_KEY',
      'ACCESS_TOKEN',
      'CLIENT_SECRET',
      'DATABASE_URL',
      'SERVICE_PASSWORD',
      'AWS_SECRET_ACCESS_KEY',
      'PGPASSWORD',
      'MYSQL_PWD',
      'REDISCLI_AUTH',
      'GITHUB_PAT',
      'AUTH',
      'PAT',
      'HTTP_AUTHORIZATION',
      'DOCKER_AUTH_CONFIG',
      'SERVICE_AUTHENTICATION_DATA',
      'DB_PASS',
      'DATABASE_PASS',
      'OPENAI_APIKEY',
      'SERVICE_PASSPHRASE',
      'MONGODB_URI',
      'REDIS_URL',
      'DATABASE_URI',
      'SQLALCHEMY_DATABASE_URI',
      'SENTRY_DSN',
    ]) {
      expect(
        isProtectedConfigValue(field: ConfigSecretField.environment, key: key),
        isTrue,
        reason: key,
      );
    }
  });

  test('authentication headers are protected but ordinary headers are not', () {
    for (final key in <String>[
      'Authorization',
      'Proxy-Authorization',
      'Cookie',
      'X-API-Key',
      'X-Auth-Token',
    ]) {
      expect(
        isProtectedConfigValue(field: ConfigSecretField.header, key: key),
        isTrue,
        reason: key,
      );
    }
    for (final key in <String>['User-Agent', 'Accept', 'X-Trace-Id']) {
      expect(
        isProtectedConfigValue(field: ConfigSecretField.header, key: key),
        isFalse,
        reason: key,
      );
    }
  });
}
