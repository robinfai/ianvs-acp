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

  if (field == ConfigSecretField.header) {
    if (_protectedHeaderNames.contains(normalized) ||
        _protectedHeaderNames.contains(compact)) {
      return true;
    }
  }

  if (_protectedExactNames.contains(compact)) return true;
  if (words.any(_credentialWord)) return true;

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
  'authorization',
  'bearer',
  'client_secret',
  'connection_string',
  'database_url',
  'db_url',
  'dsn',
  'private_key',
  'secret_access_key',
  'signing_key',
};

const Set<String> _protectedPhrases = <String>{
  'access_key',
  'api_key',
  'auth_token',
  'client_secret',
  'connection_string',
  'private_key',
  'refresh_token',
  'secret_key',
  'signing_key',
};

bool _credentialWord(String word) {
  return word == 'credential' ||
      word == 'credentials' ||
      word == 'passwd' ||
      word == 'password' ||
      word == 'secret' ||
      word == 'token';
}
