import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/bounded_utf8_accumulator.dart';

void main() {
  test('accepts complete Unicode scalars at the exact UTF-8 boundary', () {
    final accumulator = BoundedUtf8Accumulator(maxBytes: 4);

    accumulator.add('😀');

    expect(accumulator.lengthBytes, 4);
    expect(accumulator.toString(), '😀');
    expect(
      () => accumulator.add('x'),
      throwsA(isA<BoundedUtf8AccumulatorOverflowException>()),
    );
    expect(accumulator.toString(), '😀');
  });

  test('enforces one cumulative budget across multiple deltas', () {
    final accumulator = BoundedUtf8Accumulator(maxBytes: 5);

    accumulator.add('ab');
    accumulator.add('中');

    expect(accumulator.lengthBytes, 5);
    expect(accumulator.toString(), 'ab中');
    expect(
      () => accumulator.add('!'),
      throwsA(isA<BoundedUtf8AccumulatorOverflowException>()),
    );
  });

  test('counts a surrogate pair split across deltas as one scalar', () {
    final accumulator = BoundedUtf8Accumulator(maxBytes: 4);
    const emoji = '😀';

    accumulator.add(emoji.substring(0, 1));
    accumulator.add(emoji.substring(1));

    expect(accumulator.lengthBytes, 4);
    expect(accumulator.toString(), emoji);
  });

  test('does not retain an oversized single delta', () {
    final accumulator = BoundedUtf8Accumulator(maxBytes: 3);

    expect(
      () => accumulator.add('oversized'),
      throwsA(isA<BoundedUtf8AccumulatorOverflowException>()),
    );
    expect(accumulator.lengthBytes, 0);
    expect(accumulator.toString(), isEmpty);
  });
}
