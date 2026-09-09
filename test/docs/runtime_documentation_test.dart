import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final architecture = File('docs/runtime_architecture.md').readAsStringSync();
  final capabilities = File('docs/product_capabilities.md').readAsStringSync();
  final conversationLoading = File(
    'docs/conversation_loading_architecture.md',
  ).readAsStringSync();
  final followUps = File('docs/manual_followups.md').readAsStringSync();

  test('canonical runtime documents describe the implemented boundaries', () {
    expect(architecture, contains('workspace-oriented ACP desktop client'));
    expect(architecture, contains('Flutter presents workspaces and sessions'));
    expect(architecture, contains('Raw protocol frames never cross the ABI'));
    expect(capabilities, contains('workspace and local ACP session client'));
    expect(capabilities, contains('does not implement `session/fork`'));
    expect(capabilities, contains('slash-command suggestions'));
    expect(capabilities, contains('Live ACP session-info updates'));
    expect(capabilities, contains('usage updates are not projected'));
    expect(conversationLoading, contains('`CommandsChanged`'));
    expect(conversationLoading, contains('slash-command'));
    expect(conversationLoading, contains('不投影 live session-info'));
  });

  test('documentation links resolve to the canonical files', () {
    const docs = <String>[
      'docs/runtime_architecture.md',
      'docs/product_capabilities.md',
      'docs/conversation_loading_architecture.md',
      'docs/manual_followups.md',
    ];
    for (final path in docs) {
      expect(File(path).existsSync(), isTrue, reason: 'Missing $path');
      expect(File(path).readAsStringSync(), contains('Updated: 2026-09-09'));
    }

    final readme = File('README.md').readAsStringSync();
    for (final path in docs) {
      expect(readme, contains(path));
    }
    expect(readme, isNot(contains('docs/acp_runtime_coverage.md')));

    for (final path in <String>['README.md', ...docs]) {
      final source = File(path).readAsStringSync();
      for (final match in RegExp(r'\[[^\]]+\]\(([^)]+)\)').allMatches(source)) {
        final target = match.group(1)!;
        if (target.startsWith('#') || Uri.parse(target).hasScheme) continue;
        final resolved = File.fromUri(
          File(path).absolute.uri.resolve(target.split('#').first),
        );
        expect(
          resolved.existsSync(),
          isTrue,
          reason: 'Broken local link from $path to $target',
        );
      }
    }
  });

  test('activity and terminal documentation use the consolidated model', () {
    for (final document in <String>[architecture, capabilities]) {
      expect(document, contains('Activity & Diagnostics'));
      expect(document, contains('`Events`'));
      expect(document, contains('`Permissions`'));
      expect(document, contains('`Runtime`'));
    }
    expect(
      architecture,
      contains('independent process handles and lifecycles'),
    );
    expect(capabilities, contains('new, empty ACP session'));
  });

  test('manual follow-ups contain only current decision areas', () {
    for (final heading in const <String>[
      'Remote ACP agent transports',
      'Unstable protocol features',
      'Live session metadata and usage',
      'Permission audit retention',
      'Terminal experience',
      'ACP Registry',
      'Desktop and real-agent validation',
    ]) {
      expect(followUps, contains('## $heading'));
    }
  });

  test('removed compatibility runtime cannot re-enter source or manifest', () {
    final removedPackage = '${'dart'}_${'acp'}';
    final forbiddenImport = 'package:$removedPackage/';
    final sourceFiles = <File>[
      ...Directory('lib').listSync(recursive: true).whereType<File>(),
      ...Directory('test').listSync(recursive: true).whereType<File>(),
      ...Directory('tool').listSync(recursive: true).whereType<File>(),
    ].where((file) => file.path.endsWith('.dart'));

    for (final file in sourceFiles) {
      expect(
        file.readAsStringSync(),
        isNot(contains(forbiddenImport)),
        reason: 'Removed compatibility import found in ${file.path}',
      );
    }
    expect(
      File('pubspec.yaml').readAsStringSync(),
      isNot(contains(removedPackage)),
    );
    expect(Directory('third_party/$removedPackage').existsSync(), isFalse);
  });
}
