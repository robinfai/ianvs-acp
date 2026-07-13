import 'dart:convert';

import 'package:dart_acp/src/transport/byte_budget.dart';
import 'package:dart_acp/src/transport/raw_line_decoder.dart';
import 'package:flutter_test/flutter_test.dart';

const _segmentBytes = 64 * 1024;

void main() {
  test('raw line decoder requires a positive byte limit', () {
    expect(
      () => RawTransportLineDecoder(
        limit: 0,
        resource: 'test line',
        onLine: (_) {},
        onOverflow: (_) {},
      ),
      throwsA(
        isA<ArgumentError>()
            .having((error) => error.name, 'name', 'limit')
            .having((error) => error.invalidValue, 'invalidValue', 0),
      ),
    );
  });

  test('raw line uses fixed 64 KiB segments without exposing backing', () {
    final lines = <RawTransportLine>[];
    final decoder = RawTransportLineDecoder(
      limit: _segmentBytes * 2,
      resource: 'test line',
      onLine: lines.add,
      onOverflow: (_) => fail('unexpected overflow'),
    );
    final bytes = List<int>.filled(_segmentBytes + 2, 0x61, growable: true)
      ..add(0x0a);

    decoder.add(bytes);

    expect(lines, hasLength(1));
    expect(lines.single.byteLength, _segmentBytes + 2);
    expect(lines.single.segmentCount, 2);
    expect(lines.single.segmentLengths, <int>[_segmentBytes, 2]);
    expect(
      lines.single.segmentLengths.fold<int>(0, (sum, length) => sum + length),
      lines.single.byteLength,
    );
    expect(() => lines.single.segmentLengths[0] = 1, throwsUnsupportedError);
    expect(lines.single.decodeUtf8(), 'a' * (_segmentBytes + 2));
  });

  test('an empty line has no allocated byte segments', () {
    final lines = <RawTransportLine>[];
    final decoder = RawTransportLineDecoder(
      limit: 1,
      resource: 'test line',
      onLine: lines.add,
      onOverflow: (_) => fail('unexpected overflow'),
    );

    decoder.add(const <int>[0x0a]);

    expect(lines.single.byteLength, 0);
    expect(lines.single.segmentCount, 0);
    expect(lines.single.segmentLengths, isEmpty);
  });

  test('four-byte UTF-8 streams across a segment boundary', () {
    final lines = <RawTransportLine>[];
    final decoder = RawTransportLineDecoder(
      limit: _segmentBytes + 2,
      resource: 'test line',
      onLine: lines.add,
      onOverflow: (_) => fail('unexpected overflow'),
    );
    final bytes = List<int>.filled(_segmentBytes - 2, 0x61, growable: true)
      ..addAll(const <int>[0xf0, 0x9f, 0x98, 0x80, 0x0a]);

    decoder.add(bytes);

    expect(lines.single.segmentLengths, <int>[_segmentBytes, 2]);
    expect(lines.single.decodeUtf8(), '${'a' * (_segmentBytes - 2)}😀');
  });

  test('UTF-8 decoding streams a character across a segment boundary', () {
    final lines = <RawTransportLine>[];
    final decoder = RawTransportLineDecoder(
      limit: _segmentBytes + 1,
      resource: 'test line',
      onLine: lines.add,
      onOverflow: (_) => fail('unexpected overflow'),
    );
    final bytes = List<int>.filled(_segmentBytes - 1, 0x61, growable: true)
      ..addAll(const <int>[0xc3, 0xa9, 0x0a]);

    decoder.add(bytes);

    expect(lines.single.segmentLengths, <int>[_segmentBytes, 1]);
    expect(lines.single.decodeUtf8(), '${'a' * (_segmentBytes - 1)}é');
  });

  test('completed lines keep independent immutable storage', () {
    final lines = <RawTransportLine>[];
    final decoder = RawTransportLineDecoder(
      limit: _segmentBytes + 1,
      resource: 'test line',
      onLine: lines.add,
      onOverflow: (_) => fail('unexpected overflow'),
    );
    decoder
      ..add(<int>[...List<int>.filled(_segmentBytes, 0x61), 0x0a])
      ..add(utf8.encode('replacement\n'));

    expect(lines, hasLength(2));
    expect(lines.first.segmentLengths, <int>[_segmentBytes]);
    expect(lines.first.decodeUtf8(), 'a' * _segmentBytes);
    expect(lines.last.decodeUtf8(), 'replacement');
  });

  test('consecutive CR and close remain idempotent', () {
    final lines = <String>[];
    final decoder = RawTransportLineDecoder(
      limit: 8,
      resource: 'test line',
      onLine: (line) => lines.add(line.decodeUtf8()),
      onOverflow: (_) => fail('unexpected overflow'),
    );

    decoder
      ..add(utf8.encode('a\r\rb'))
      ..close()
      ..close()
      ..add(utf8.encode('late\n'));

    expect(lines, <String>['a', '', 'b']);
  });

  test('decoder preserves CR LF CRLF empty and final EOF line semantics', () {
    final lines = <String>[];
    final decoder = RawTransportLineDecoder(
      limit: 16,
      resource: 'test line',
      onLine: (line) => lines.add(line.decodeUtf8()),
      onOverflow: (_) => fail('unexpected overflow'),
    );

    decoder
      ..add(utf8.encode('a\r'))
      ..add(utf8.encode('\nb\rc\n\r\nlast\r'))
      ..close();

    expect(lines, <String>['a', 'b', 'c', '', 'last']);
  });

  test('decoder accepts exact limit and reports only limit plus one', () {
    final lines = <String>[];
    final errors = <TransportByteLimitExceeded>[];
    final decoder = RawTransportLineDecoder(
      limit: 3,
      resource: 'test line',
      onLine: (line) => lines.add(line.decodeUtf8()),
      onOverflow: errors.add,
    );

    decoder.add(utf8.encode('abc\n1234secret\nlater\n'));

    expect(lines, <String>['abc']);
    expect(errors, hasLength(1));
    expect(errors.single.limit, 3);
    expect(errors.single.observedAtLeast, 4);
    expect(errors.single.toString(), isNot(contains('secret')));
  });

  test('discard mode resumes after one oversized line', () {
    final lines = <String>[];
    final errors = <TransportByteLimitExceeded>[];
    final decoder = RawTransportLineDecoder(
      limit: 3,
      resource: 'test line',
      discardOversizedLines: true,
      onLine: (line) => lines.add(line.decodeUtf8()),
      onOverflow: errors.add,
    );

    decoder.add(utf8.encode('1234secret\rok\n'));

    expect(errors, hasLength(1));
    expect(errors.single.observedAtLeast, 4);
    expect(lines, <String>['ok']);
  });

  for (final terminator in <({String name, String value})>[
    (name: 'LF', value: '\n'),
    (name: 'CR', value: '\r'),
    (name: 'CRLF', value: '\r\n'),
  ]) {
    test('discard mode resumes after ${terminator.name}', () {
      final lines = <String>[];
      final decoder = RawTransportLineDecoder(
        limit: 3,
        resource: 'test line',
        discardOversizedLines: true,
        onLine: (line) => lines.add(line.decodeUtf8()),
        onOverflow: (_) {},
      );

      decoder.add(utf8.encode('1234secret${terminator.value}ok\n'));

      expect(lines, <String>['ok']);
    });
  }

  test('fatal overflow state is fixed before a reentrant callback', () {
    late RawTransportLineDecoder decoder;
    final lines = <String>[];
    decoder = RawTransportLineDecoder(
      limit: 3,
      resource: 'test line',
      onLine: (line) => lines.add(line.decodeUtf8()),
      onOverflow: (_) => decoder.add(utf8.encode('bad\n')),
    );

    decoder
      ..add(utf8.encode('1234'))
      ..add(utf8.encode('later\n'));

    expect(lines, isEmpty);
  });

  test('discard state is fixed before a reentrant overflow callback', () {
    late RawTransportLineDecoder decoder;
    final lines = <String>[];
    decoder = RawTransportLineDecoder(
      limit: 3,
      resource: 'test line',
      discardOversizedLines: true,
      onLine: (line) => lines.add(line.decodeUtf8()),
      onOverflow: (_) => decoder.add(utf8.encode('bad\n')),
    );

    decoder
      ..add(utf8.encode('1234'))
      ..add(utf8.encode('\nok\n'));

    expect(lines, <String>['ok']);
  });

  test('discard overflow ignores reentrant input until callback returns', () {
    late RawTransportLineDecoder decoder;
    final lines = <String>[];
    final errors = <TransportByteLimitExceeded>[];
    decoder = RawTransportLineDecoder(
      limit: 3,
      resource: 'test line',
      discardOversizedLines: true,
      onLine: (line) => lines.add(line.decodeUtf8()),
      onOverflow: (error) {
        errors.add(error);
        decoder.add(utf8.encode('bad\n'));
      },
    );

    decoder.add(utf8.encode('1234xy\nok\n'));

    expect(errors, hasLength(1));
    expect(lines, <String>['ok']);
  });

  test('overflow callback can still cancel the decoder directly', () {
    late RawTransportLineDecoder decoder;
    final lines = <String>[];
    final errors = <TransportByteLimitExceeded>[];
    decoder = RawTransportLineDecoder(
      limit: 3,
      resource: 'test line',
      discardOversizedLines: true,
      onLine: (line) => lines.add(line.decodeUtf8()),
      onOverflow: (error) {
        errors.add(error);
        decoder.cancel();
      },
    );

    decoder
      ..add(utf8.encode('1234xy\nok\n'))
      ..add(utf8.encode('later\n'));

    expect(errors, hasLength(1));
    expect(lines, isEmpty);
  });

  test('onLine can cancel reentrantly without retaining later bytes', () {
    late RawTransportLineDecoder decoder;
    final lines = <String>[];
    decoder = RawTransportLineDecoder(
      limit: 8,
      resource: 'test line',
      onLine: (line) {
        lines.add(line.decodeUtf8());
        decoder.cancel();
      },
      onOverflow: (_) => fail('unexpected overflow'),
    );

    decoder.add(utf8.encode('first\rsecond\n'));

    expect(lines, <String>['first']);
  });

  test('cancel drops an unfinished line and later input', () {
    final lines = <RawTransportLine>[];
    final decoder = RawTransportLineDecoder(
      limit: 8,
      resource: 'test line',
      onLine: lines.add,
      onOverflow: (_) => fail('unexpected overflow'),
    );

    decoder
      ..add(utf8.encode('part'))
      ..cancel()
      ..add(utf8.encode('later\n'))
      ..close();

    expect(lines, isEmpty);
  });

  test('streaming UTF-8 decode rejects malformed input', () {
    final lines = <RawTransportLine>[];
    final decoder = RawTransportLineDecoder(
      limit: _segmentBytes + 1,
      resource: 'test line',
      onLine: lines.add,
      onOverflow: (_) => fail('unexpected overflow'),
    );
    decoder.add(<int>[...List<int>.filled(_segmentBytes, 0x61), 0xff, 0x0a]);

    expect(lines, hasLength(1));
    expect(lines.single.decodeUtf8, throwsFormatException);
  });

  test('streaming UTF-8 rejects an invalid continuation across segments', () {
    final lines = <RawTransportLine>[];
    final decoder = RawTransportLineDecoder(
      limit: _segmentBytes + 1,
      resource: 'test line',
      onLine: lines.add,
      onOverflow: (_) => fail('unexpected overflow'),
    );
    decoder.add(<int>[
      ...List<int>.filled(_segmentBytes - 1, 0x61),
      0xc3,
      0x20,
      0x0a,
    ]);

    expect(lines.single.decodeUtf8, throwsFormatException);
  });

  test('streaming UTF-8 rejects an unfinished sequence at line EOF', () {
    final lines = <RawTransportLine>[];
    final decoder = RawTransportLineDecoder(
      limit: 1,
      resource: 'test line',
      onLine: lines.add,
      onOverflow: (_) => fail('unexpected overflow'),
    );
    decoder
      ..add(const <int>[0xc3])
      ..close();

    expect(lines.single.decodeUtf8, throwsFormatException);
  });

  for (final invalidByte in <int>[-1, 300]) {
    test('out-of-range byte $invalidByte is rejected without truncation', () {
      final lines = <RawTransportLine>[];
      final decoder = RawTransportLineDecoder(
        limit: 1,
        resource: 'test line',
        onLine: lines.add,
        onOverflow: (_) => fail('unexpected overflow'),
      );
      decoder.add(<int>[invalidByte, 0x0a]);

      expect(lines, hasLength(1));
      expect(lines.single.byteLength, 1);
      expect(lines.single.decodeUtf8, throwsFormatException);
    });
  }

  test('limit plus one overflows without delivering another segment', () {
    final lines = <RawTransportLine>[];
    final errors = <TransportByteLimitExceeded>[];
    final decoder = RawTransportLineDecoder(
      limit: _segmentBytes,
      resource: 'test line',
      onLine: lines.add,
      onOverflow: errors.add,
    );

    decoder.add(List<int>.filled(_segmentBytes + 1, 0x61));

    expect(lines, isEmpty);
    expect(errors.single.observedAtLeast, _segmentBytes + 1);
  });
}
