import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/platform/file_manager.dart';

void main() {
  test('revealPathInFileManager opens directories directly', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'ianvs-acp-file-manager-',
    );
    addTearDown(() async => tempDir.delete(recursive: true));
    final calls = <({String executable, List<String> arguments})>[];

    await revealPathInFileManager(
      tempDir.path,
      processRunner: (executable, arguments) async {
        calls.add((executable: executable, arguments: arguments));
        return ProcessResult(0, 0, '', '');
      },
    );

    expect(calls, hasLength(1));
    if (Platform.isMacOS) {
      expect(calls.single.executable, 'open');
      expect(calls.single.arguments, [tempDir.path]);
    } else if (Platform.isWindows) {
      expect(calls.single.executable, 'explorer');
      expect(calls.single.arguments, [tempDir.path]);
    } else {
      expect(calls.single.executable, 'xdg-open');
      expect(calls.single.arguments, [tempDir.path]);
    }
  });

  test(
    'revealPathInFileManager reveals files in their parent folder',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'ianvs-acp-file-manager-',
      );
      addTearDown(() async => tempDir.delete(recursive: true));
      final file = await File(
        '${tempDir.path}/session.txt',
      ).writeAsString('session');
      final calls = <({String executable, List<String> arguments})>[];

      await revealPathInFileManager(
        file.path,
        processRunner: (executable, arguments) async {
          calls.add((executable: executable, arguments: arguments));
          return ProcessResult(0, 0, '', '');
        },
      );

      expect(calls, hasLength(1));
      if (Platform.isMacOS) {
        expect(calls.single.executable, 'open');
        expect(calls.single.arguments, ['-R', file.path]);
      } else if (Platform.isWindows) {
        expect(calls.single.executable, 'explorer');
        expect(calls.single.arguments, ['/select,', file.path]);
      } else {
        expect(calls.single.executable, 'xdg-open');
        expect(calls.single.arguments, [tempDir.path]);
      }
    },
  );

  test('revealPathInFileManager reports missing paths', () async {
    await expectLater(
      revealPathInFileManager('/path/that/does/not/exist'),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('Path does not exist'),
        ),
      ),
    );
  });
}
