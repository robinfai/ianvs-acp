enum ConfigSecretField { environment, header }

/// Returns whether a configuration entry is credential-like and should be
/// persisted in the platform secret store instead of settings.json.
///
/// Environment variables are not secrets by default. This keeps ordinary
/// process configuration such as PATH, HOME, LANG, and feature flags readable
/// without prompting for Keychain access. Credential-shaped names remain
/// protected, as do the standard HTTP authentication headers.
bool isProtectedConfigValue({
  required ConfigSecretField field,
  required String key,
}) {
  final normalized = key.trim().toLowerCase();
  if (normalized.isEmpty) return false;
  final words = normalized
      .split(RegExp(r'[^a-z0-9]+'))
      .where((word) => word.isNotEmpty)
      .toList(growable: false);
  final compact = words.join('_');

  if (_safeExactNames.contains(compact)) return false;

  if (field == ConfigSecretField.header) {
    if (_protectedHeaderNames.contains(normalized) ||
        _protectedHeaderNames.contains(compact)) {
      return true;
    }
  }

  if (_protectedExactNames.contains(compact)) return true;
  if (words.any(_credentialWord)) return true;
  if (words.any(_fusedCredentialWord)) return true;
  if (words.length > 1 && words.any(_credentialAbbreviation)) return true;
  if (compact.endsWith('_auth')) return true;

  return _protectedPhrases.any(
    (phrase) =>
        compact == phrase ||
        compact.startsWith('${phrase}_') ||
        compact.endsWith('_$phrase') ||
        compact.contains('_${phrase}_'),
  );
}

const Set<String> _protectedHeaderNames = <String>{
  'authorization',
  'proxy-authorization',
  'proxy_authorization',
  'cookie',
  'set-cookie',
  'set_cookie',
  'www-authenticate',
  'www_authenticate',
  'x-api-key',
  'x_api_key',
  'api-key',
  'api_key',
  'x-auth-token',
  'x_auth_token',
  'x-access-token',
  'x_access_token',
};

const Set<String> _protectedExactNames = <String>{
  'auth',
  'authorization',
  'bearer',
  'client_secret',
  'connection_string',
  'database_url',
  'db_url',
  'dsn',
  'private_key',
  'pat',
  'secret_access_key',
  'signing_key',
};

const Set<String> _protectedPhrases = <String>{
  'access_key',
  'amqp_url',
  'api_key',
  'auth_token',
  'broker_url',
  'client_secret',
  'connection_string',
  'connection_uri',
  'database_pass',
  'database_uri',
  'db_pass',
  'elasticsearch_url',
  'jdbc_url',
  'mariadb_url',
  'mongo_url',
  'mongodb_uri',
  'mysql_url',
  'postgres_url',
  'postgresql_url',
  'private_key',
  'rabbitmq_url',
  'redis_url',
  'refresh_token',
  'secret_key',
  'signing_key',
};

bool _credentialWord(String word) {
  return word == 'authentication' ||
      word == 'authorization' ||
      word == 'credential' ||
      word == 'credentials' ||
      word == 'dsn' ||
      word == 'apikey' ||
      word == 'passwd' ||
      word == 'password' ||
      word == 'passphrase' ||
      word == 'secret' ||
      word == 'token';
}

bool _fusedCredentialWord(String word) {
  return _fusedCredentialSuffixes.any(
    (suffix) => word.length > suffix.length && word.endsWith(suffix),
  );
}

bool _credentialAbbreviation(String word) =>
    word == 'auth' || word == 'pat' || word == 'pwd';

const Set<String> _safeExactNames = <String>{'auth_mode', 'ssh_auth_sock'};

const Set<String> _fusedCredentialSuffixes = <String>{
  'apikey',
  'credential',
  'credentials',
  'passphrase',
  'passwd',
  'password',
  'privatekey',
  'secret',
  'token',
};
