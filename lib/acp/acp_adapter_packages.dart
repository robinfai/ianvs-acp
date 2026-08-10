abstract final class AcpAdapterPackages {
  static const String codex = '@agentclientprotocol/codex-acp';
  static const String zedCodex = '@zed-industries/codex-acp';

  static const String cursorAgentName = 'Cursor';
  static const String codeBuddyAgentName = 'CodeBuddy';
  static const String codeBuddy = '@tencent-ai/codebuddy-code';

  static const String piVersion = '0.0.31';
  static const String pi = 'pi-acp@$piVersion';
  static const String piAgentName = 'Pi';
  static const String piAgentAlias = 'pi ACP';

  static bool isZedCodexPackage(Object? value) =>
      value == zedCodex || (value is String && value.startsWith('$zedCodex@'));

  static bool isPiPackage(Object? value) =>
      value == 'pi-acp' ||
      (value is String &&
          value.startsWith('pi-acp@') &&
          value.length > 'pi-acp@'.length);

  static bool isCodeBuddyPackage(Object? value) =>
      value == codeBuddy ||
      (value is String &&
          value.startsWith('$codeBuddy@') &&
          value.length > '$codeBuddy@'.length);

  static bool isCursorAdapterInvocation({
    required String command,
    required Iterable<String> args,
  }) {
    final commandName = _commandBaseName(command).toLowerCase();
    if (commandName != 'agent' &&
        commandName != 'agent.exe' &&
        commandName != 'agent.cmd' &&
        commandName != 'cursor-agent' &&
        commandName != 'cursor-agent.exe' &&
        commandName != 'cursor-agent.cmd') {
      return false;
    }
    final normalizedArgs = args
        .map((arg) => arg.trim())
        .where((arg) => arg.isNotEmpty)
        .toList(growable: false);
    return normalizedArgs.length == 1 && normalizedArgs.single == 'acp';
  }

  static bool isCodeBuddyAdapterInvocation({
    required String command,
    required Iterable<String> args,
  }) {
    final commandName = _commandBaseName(command).toLowerCase();
    final normalizedArgs = args
        .map((arg) => arg.trim())
        .where((arg) => arg.isNotEmpty)
        .toList(growable: false);
    if (commandName == 'codebuddy' ||
        commandName == 'codebuddy.exe' ||
        commandName == 'codebuddy.cmd') {
      return normalizedArgs.length == 1 && normalizedArgs.single == '--acp';
    }
    if (commandName != 'npx' && commandName != 'npx.cmd') return false;

    final packageArgs = normalizedArgs
        .where((arg) => arg != '-y' && arg != '--yes' && arg != '--')
        .toList(growable: false);
    return packageArgs.length == 2 &&
        isCodeBuddyPackage(packageArgs.first) &&
        packageArgs.last == '--acp';
  }

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
    return trimmed == piAgentName || trimmed == piAgentAlias;
  }

  static List<String> normalizeCodexAdapterArgs(Iterable<String> args) {
    final normalized = List<String>.unmodifiable(args);
    if (normalized.length == 1 && isZedCodexPackage(normalized.single)) {
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
