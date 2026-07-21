import 'dart:io';

import '../workspace/workspace.dart';

abstract class LocalSkillRepository {
  Future<LocalSkill?> findSkill(
    String skillId, {
    required String workspacePath,
  });
}

class LocalSkill {
  const LocalSkill({
    required this.id,
    required this.name,
    required this.path,
    required this.markdown,
    required this.trusted,
  });

  final String id;
  final String name;
  final String path;
  final String markdown;
  final bool trusted;
}

class LocalSkillRegistry implements LocalSkillRepository {
  LocalSkillRegistry({
    String? configDirectory,
    Map<String, String>? environment,
  }) : configDirectory =
           configDirectory ?? _defaultConfigDirectory(environment);

  final String configDirectory;

  @override
  Future<LocalSkill?> findSkill(
    String skillId, {
    required String workspacePath,
  }) async {
    final id = _safeSkillId(skillId);
    final workspace = normalizeWorkspacePath(workspacePath);
    final workspaceFile = File('$workspace/.ianvs/skills/$id/SKILL.md');
    if (await workspaceFile.exists()) {
      return _readSkill(id, workspaceFile, trusted: false);
    }

    final configFile = File(
      '${normalizeWorkspacePath(configDirectory)}/skills/$id/SKILL.md',
    );
    if (await configFile.exists()) {
      return _readSkill(id, configFile, trusted: false);
    }
    return null;
  }

  Future<LocalSkill> _readSkill(
    String id,
    File file, {
    required bool trusted,
  }) async {
    final markdown = await file.readAsString();
    return LocalSkill(
      id: id,
      name: _skillNameFromMarkdown(markdown) ?? id,
      path: file.path,
      markdown: markdown,
      trusted: trusted,
    );
  }
}

String _safeSkillId(String raw) {
  final id = raw.trim();
  final valid = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]*$');
  if (!valid.hasMatch(id) || id.contains('..')) {
    throw ArgumentError.value(raw, 'skillId', 'Unsafe skill id');
  }
  return id;
}

String? _skillNameFromMarkdown(String markdown) {
  for (final line in markdown.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.startsWith('# ')) return trimmed.substring(2).trim();
  }
  return null;
}

String _defaultConfigDirectory(Map<String, String>? environment) {
  final env = environment ?? Platform.environment;
  final xdg = env['XDG_CONFIG_HOME']?.trim();
  if (xdg != null && xdg.isNotEmpty) return '$xdg/ianvs-acp';
  final home = env['HOME']?.trim();
  if (home != null && home.isNotEmpty) return '$home/.config/ianvs-acp';
  return '.ianvs-acp';
}
