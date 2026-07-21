import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/tasks/local_skill.dart';

void main() {
  test('LocalSkillRegistry loads workspace and config skills', () async {
    final root = await Directory.systemTemp.createTemp('ianvs-acp-skills-');
    addTearDown(() async => root.delete(recursive: true));
    final workspace = Directory('${root.path}/workspace');
    final config = Directory('${root.path}/config');
    await File(
      '${workspace.path}/.ianvs/skills/workspace-skill/SKILL.md',
    ).create(recursive: true);
    await File(
      '${workspace.path}/.ianvs/skills/workspace-skill/SKILL.md',
    ).writeAsString('# Workspace Skill\nUse local context.');
    await File(
      '${config.path}/skills/config-skill/SKILL.md',
    ).create(recursive: true);
    await File(
      '${config.path}/skills/config-skill/SKILL.md',
    ).writeAsString('# Config Skill\nUse shared context.');

    final registry = LocalSkillRegistry(configDirectory: config.path);

    final workspaceSkill = await registry.findSkill(
      'workspace-skill',
      workspacePath: workspace.path,
    );
    final configSkill = await registry.findSkill(
      'config-skill',
      workspacePath: workspace.path,
    );

    expect(workspaceSkill?.trusted, isFalse);
    expect(workspaceSkill?.path, endsWith('workspace-skill/SKILL.md'));
    expect(workspaceSkill?.markdown, contains('Workspace Skill'));
    expect(configSkill?.trusted, isFalse);
    expect(configSkill?.path, endsWith('config-skill/SKILL.md'));
  });

  test('LocalSkill rejects unsafe ids', () async {
    final registry = LocalSkillRegistry(configDirectory: '/tmp/ianvs-acp');

    expect(
      () => registry.findSkill('../escape', workspacePath: '/workspace/app'),
      throwsA(isA<ArgumentError>()),
    );
  });
}
