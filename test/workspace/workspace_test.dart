import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/workspace/workspace.dart';

void main() {
  test(
    'workspaceSupportsGitWorktrees recognizes repositories and worktrees',
    () {
      final root = Directory.systemTemp.createTempSync('ianvs-acp-git-test-');
      addTearDown(() => root.deleteSync(recursive: true));

      final repository = Directory('${root.path}/repository')..createSync();
      final nested = Directory('${repository.path}/packages/app')
        ..createSync(recursive: true);
      Directory('${repository.path}/.git').createSync();

      final worktree = Directory('${root.path}/worktree')..createSync();
      File(
        '${worktree.path}/.git',
      ).writeAsStringSync('gitdir: ${repository.path}/.git/worktrees/example');

      final ordinary = Directory('${root.path}/ordinary')..createSync();

      expect(workspaceSupportsGitWorktrees(repository.path), isTrue);
      expect(workspaceSupportsGitWorktrees(nested.path), isTrue);
      expect(workspaceSupportsGitWorktrees(worktree.path), isTrue);
      expect(workspaceSupportsGitWorktrees(ordinary.path), isFalse);
      expect(
        workspaceSupportsGitWorktrees('${root.path}/does-not-exist'),
        isFalse,
      );
    },
  );
}
