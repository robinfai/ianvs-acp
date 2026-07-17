abstract final class AcpAdapterPackages {
  static const String codex = '@agentclientprotocol/codex-acp';
  static const String legacyCodex = '@zed-industries/codex-acp';

  static const String piVersion = '0.0.31';
  static const String pi = 'pi-acp@$piVersion';
  static const String piAgentName = 'Pi';
  static const String legacyPiAgentName = 'pi ACP';

  static bool isLegacyCodexPackage(Object? value) =>
      value == legacyCodex ||
      (value is String && value.startsWith('$legacyCodex@'));

  static bool isPiPackage(Object? value) =>
      value == 'pi-acp' ||
      (value is String &&
          value.startsWith('pi-acp@') &&
          value.length > 'pi-acp@'.length);

  static bool isPiAdapterInvocation({
    required String command,
    required Iterable<String> args,
  }) {
    final commandName = _commandBaseName(command);
    if (commandName == 'pi-acp') return true;
    if (commandName != 'npx' && commandName != 'npx.cmd') return false;

    final packageArgs = args
        .map((arg) => arg.trim())
        .where((arg) => arg.isNotEmpty && arg != '-y' && arg != '--yes')
        .toList(growable: false);
    return packageArgs.length == 1 && isPiPackage(packageArgs.single);
  }

  static bool isPiAgentAlias(String name) {
    final trimmed = name.trim();
    return trimmed == piAgentName || trimmed == legacyPiAgentName;
  }

  static List<String> normalizeCodexAdapterArgs(Iterable<String> args) {
    final normalized = List<String>.unmodifiable(args);
    if (normalized.length == 1 && isLegacyCodexPackage(normalized.single)) {
      return const <String>[codex];
    }
    return normalized;
  }

  static String _commandBaseName(String command) {
    final trimmed = command.trim().replaceAll('\\', '/');
    if (trimmed.isEmpty) return '';
    return trimmed.split('/').last;
  }
}
