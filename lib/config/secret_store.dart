abstract interface class SecretStore {
  Future<String> put({
    required String namespace,
    required String key,
    required String value,
  });

  Future<String?> get(String reference);

  Future<void> delete(String reference);
}
