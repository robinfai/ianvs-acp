import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/platform/bounded_file_snapshot.dart';

void main() {
  test('reads an exact bounded file snapshot', () async {
    final directory = await Directory.systemTemp.createTemp(
      'ianvs-bounded-file-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/snapshot.bin');
    await file.writeAsBytes(<int>[1, 2, 3, 4]);

    expect(await readBoundedFileSnapshot(file, maxBytes: 4), <int>[1, 2, 3, 4]);
  });

  test('throws a typed overflow without retaining content', () async {
    const canary = 'bounded-stream-secret-canary';
    final controller = StreamController<List<int>>();
    final reading = readBoundedByteStreamSnapshot(
      controller.stream,
      resourcePath: '/untrusted/snapshot',
      maxBytes: 4,
    );
    controller.add(<int>[1, 2, 3, 4]);
    controller.add(<int>[canary.codeUnitAt(0)]);
    await controller.close();

    await expectLater(
      reading,
      throwsA(
        isA<BoundedFileSnapshotOverflowException>()
            .having((error) => error.maxBytes, 'maxBytes', 4)
            .having(
              (error) => error.toString(),
              'message',
              isNot(contains(canary)),
            ),
      ),
    );
  });

  test('rejects a max plus one file snapshot', () async {
    final directory = await Directory.systemTemp.createTemp(
      'ianvs-bounded-file-overflow-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/snapshot.bin');
    await file.writeAsBytes(List<int>.filled(4 * 1024 * 1024 + 1, 1));

    await expectLater(
      readBoundedFileSnapshot(file, maxBytes: 4 * 1024 * 1024),
      throwsA(isA<BoundedFileSnapshotOverflowException>()),
    );
  });

  test('rejects a chunk that exceeds max plus one without retaining it', () {
    final reading = readBoundedByteStreamSnapshot(
      Stream<List<int>>.value(List<int>.filled(1024, 7)),
      resourcePath: '/untrusted/growing-snapshot',
      maxBytes: 8,
    );

    expect(reading, throwsA(isA<BoundedFileSnapshotOverflowException>()));
  });
}
