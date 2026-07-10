import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/tasks/task_data_sanitizer.dart';

void main() {
  test('TaskDataSanitizer preserves small metadata content', () {
    const sanitizer = TaskDataSanitizer();

    final result = sanitizer.sanitize(<String, Object?>{
      'z': <String, Object?>{'b': 2, 'a': 1},
      'a': <Object?>['value', true, null],
    });

    expect(result, <String, Object?>{
      'a': <Object?>['value', true, null],
      'z': <String, Object?>{'a': 1, 'b': 2},
    });
  });

  test('TaskDataSanitizer replaces oversized canonical JSON with digest', () {
    const sanitizer = TaskDataSanitizer(maxMetadataBytes: 32);
    final metadata = <String, Object?>{
      'z': 'xxxxxxxxxxxxxxxxxxxxxxxx',
      'a': <String, Object?>{'second': 2, 'first': 1},
    };
    const canonical =
        '{"a":{"first":1,"second":2},"z":"xxxxxxxxxxxxxxxxxxxxxxxx"}';
    final bytes = utf8.encode(canonical);

    final result = sanitizer.sanitize(metadata);

    expect(result, <String, Object?>{
      'truncated': true,
      'original_bytes': bytes.length,
      'sha256': sha256.convert(bytes).toString(),
    });
  });

  test('TaskDataSanitizer keeps metadata at the byte limit', () {
    const canonical = '{"value":"1234"}';
    final sanitizer = TaskDataSanitizer(
      maxMetadataBytes: utf8.encode(canonical).length,
    );

    expect(
      sanitizer.sanitize(const <String, Object?>{'value': '1234'}),
      const <String, Object?>{'value': '1234'},
    );
  });

  test('TaskDataSanitizer rejects non-finite numbers', () {
    const sanitizer = TaskDataSanitizer();

    expect(
      () => sanitizer.sanitize(<String, Object?>{'value': double.nan}),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => sanitizer.sanitize(<String, Object?>{'value': double.infinity}),
      throwsA(isA<FormatException>()),
    );
  });

  test('TaskDataSanitizer rejects non-JSON values', () {
    const sanitizer = TaskDataSanitizer();

    expect(
      () => sanitizer.sanitize(<String, Object?>{
        'value': DateTime.utc(2026, 7, 10),
      }),
      throwsA(isA<FormatException>()),
    );
  });

  test('TaskDataSanitizer measures Unicode metadata in UTF-8 bytes', () {
    const canonical = '{"value":"中文😀"}';
    final bytes = utf8.encode(canonical);
    final capped = TaskDataSanitizer(maxMetadataBytes: bytes.length - 1);

    final truncated = capped.sanitize(const <String, Object?>{'value': '中文😀'});

    expect(truncated['truncated'], isTrue);
    expect(truncated['original_bytes'], bytes.length);
    expect(truncated['sha256'], sha256.convert(bytes).toString());

    final exact = TaskDataSanitizer(maxMetadataBytes: bytes.length);
    expect(
      exact.sanitize(const <String, Object?>{'value': '中文😀'}),
      const <String, Object?>{'value': '中文😀'},
    );
  });

  test('TaskDataSanitizer rejects cyclic maps and lists', () {
    const sanitizer = TaskDataSanitizer();
    final cyclicMap = <String, Object?>{};
    cyclicMap['self'] = cyclicMap;
    final cyclicList = <Object?>[];
    cyclicList.add(cyclicList);

    expect(
      () => sanitizer.sanitize(cyclicMap),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => sanitizer.sanitize(<String, Object?>{'list': cyclicList}),
      throwsA(isA<FormatException>()),
    );
  });

  test('TaskDataSanitizer allows shared non-cyclic objects', () {
    const sanitizer = TaskDataSanitizer();
    final shared = <String, Object?>{'value': 1};

    final result = sanitizer.sanitize(<String, Object?>{
      'first': shared,
      'second': shared,
    });

    expect(result, <String, Object?>{
      'first': <String, Object?>{'value': 1},
      'second': <String, Object?>{'value': 1},
    });
  });
}
