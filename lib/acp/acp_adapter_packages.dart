abstract final class AcpAdapterPackages {
  static const String codex = '@agentclientprotocol/codex-acp';
  static const String legacyCodex = '@zed-industries/codex-acp';

  static const String piVersion = '0.0.31';
  static const String pi = 'pi-acp@$piVersion';

  static bool isLegacyCodexPackage(Object? value) =>
      value == legacyCodex ||
      (value is String && value.startsWith('$legacyCodex@'));

  static List<String> normalizeCodexAdapterArgs(Iterable<String> args) {
    final normalized = List<String>.unmodifiable(args);
    if (normalized.length == 1 && isLegacyCodexPackage(normalized.single)) {
      return const <String>[codex];
    }
    return normalized;
  }
}
