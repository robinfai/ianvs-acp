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

  test('TaskDataSanitizer redacts sensitive keys recursively', () {
    const sanitizer = TaskDataSanitizer();

    expect(
      sanitizer.sanitize(const <String, Object?>{
        'Authorization': 'Bearer abc',
        'headers': <String, Object?>{
          'Cookie': 'session=secret',
          'X-Request-Id': 'safe',
        },
        'env': <String, Object?>{
          'OPENAI_API_KEY': 'sk-test',
          'SAFE_VALUE': 'must-still-redact-inside-env',
        },
        'nested': <String, Object?>{
          'accessToken': 'github_pat_secret',
          'db_password': 'password',
          'client_secret': 'secret',
        },
        'command': 'echo safe',
      }),
      const <String, Object?>{
        'Authorization': '<redacted>',
        'command': 'echo safe',
        'env': <String, Object?>{
          'OPENAI_API_KEY': '<redacted>',
          'SAFE_VALUE': '<redacted>',
        },
        'headers': <String, Object?>{
          'Cookie': '<redacted>',
          'X-Request-Id': 'safe',
        },
        'nested': <String, Object?>{
          'accessToken': '<redacted>',
          'client_secret': '<redacted>',
          'db_password': '<redacted>',
        },
      },
    );
  });

  test('TaskDataSanitizer redacts known secret-shaped string values', () {
    const sanitizer = TaskDataSanitizer();

    expect(
      sanitizer.sanitize(const <String, Object?>{
        'bearer': 'Bearer abc.def.ghi',
        'header': 'Authorization:Bearer colon-secret',
        'argument': '--header=Authorization:Bearer argument-secret',
        'json': '{"Authorization":"Bearer json-secret"}',
        'github': 'ghp_123456789012345678901234567890123456',
        'githubFineGrained': 'github_pat_1234567890abcdefghijklmnop',
        'openai': 'sk-test-secret-value',
        'pem': '-----BEGIN PRIVATE KEY-----\nabc',
        'safe': 'ordinary text',
      }),
      const <String, Object?>{
        'bearer': '<redacted>',
        'header': '<redacted>',
        'argument': '<redacted>',
        'json': '<redacted>',
        'github': '<redacted>',
        'githubFineGrained': '<redacted>',
        'openai': '<redacted>',
        'pem': '<redacted>',
        'safe': 'ordinary text',
      },
    );
  });

  test('TaskDataSanitizer bounds streaming credential grammar', () {
    const sanitizer = TaskDataSanitizer();

    expect(
      sanitizer.sanitizeText('Bearer ${' ' * 63}bounded-token'),
      taskDataRedactedValue,
    );
    expect(
      sanitizer.sanitizeText('Bearer ${' ' * 64}out-of-grammar-token'),
      isNot(taskDataRedactedValue),
    );
    expect(
      sanitizer.sanitizeText('-----BEGIN RSA PRIVATE KEY-----'),
      taskDataRedactedValue,
    );
    expect(
      sanitizer.sanitizeText('-----BEGIN ${'A' * 33} PRIVATE KEY-----'),
      isNot(taskDataRedactedValue),
    );
  });

  test('TaskDataSanitizer sanitizes JSON encoded raw tool payloads', () {
    const sanitizer = TaskDataSanitizer();

    final sanitized = sanitizer.sanitize(const <String, Object?>{
      'rawInput': '{"password":"plain","command":"echo safe"}',
      'raw_output': '[{"Authorization":"Bearer hidden"}]',
      'rawOutput': 'password=unstructured-secret',
    });

    expect(jsonDecode(sanitized['rawInput']! as String), {
      'command': 'echo safe',
      'password': '<redacted>',
    });
    expect(jsonDecode(sanitized['raw_output']! as String), [
      {'Authorization': '<redacted>'},
    ]);
    expect(sanitized['rawOutput'], '<redacted>');
  });
}
