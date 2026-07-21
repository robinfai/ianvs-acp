import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final architecture = File('docs/runtime_architecture.md').readAsStringSync();
  final coverage = File('docs/acp_runtime_coverage.md').readAsStringSync();
  final capabilities = File('docs/product_capabilities.md').readAsStringSync();
  final followUps = File('docs/manual_followups.md').readAsStringSync();

  test('canonical runtime documents describe one Rust authority', () {
    expect(architecture, contains('authoritative ownership contract'));
    expect(architecture, contains('Rust-only production authority'));
    expect(architecture, contains('No generic JSON-RPC client'));
    expect(coverage, contains('Raw JSON-RPC envelopes do not cross the ABI'));
    expect(coverage, contains('Unsupported operations fail'));
    expect(coverage, contains('closed instead of switching runtimes'));
    expect(capabilities, contains('one production authority'));
  });

  test('documentation links resolve to the canonical files', () {
    const docs = <String>[
      'docs/runtime_architecture.md',
      'docs/acp_runtime_coverage.md',
      'docs/product_capabilities.md',
      'docs/manual_followups.md',
    ];
    for (final path in docs) {
      expect(File(path).existsSync(), isTrue, reason: 'Missing $path');
      expect(File(path).readAsStringSync(), contains('Updated: 2026-07-21'));
    }

    final readme = File('README.md').readAsStringSync();
    for (final path in docs) {
      expect(readme, contains(path));
    }
  });

  test('manual follow-ups contain only current decision areas', () {
    for (final heading in const <String>[
      'Remote ACP agent transports',
      'Unstable protocol features',
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
