import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('documentation links resolve to the canonical files', () {
    const docs = <String>[
      'docs/runtime_architecture.md',
      'docs/product_capabilities.md',
      'docs/conversation_loading_architecture.md',
      'docs/manual_followups.md',
    ];
    for (final path in docs) {
      expect(File(path).existsSync(), isTrue, reason: 'Missing $path');
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
