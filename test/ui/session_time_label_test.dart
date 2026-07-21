import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/ui/components/session_time_label.dart';

void main() {
  tearDown(() {
    debugSessionTimeNow = null;
  });

  test('formatRelativeSessionTime formats compact relative labels', () {
    final now = DateTime(2026, 7, 8, 12);

    expect(
      formatRelativeSessionTime(
        now.subtract(const Duration(seconds: 45)),
        now: now,
      ),
      'just now',
    );
    expect(
      formatRelativeSessionTime(
        now.subtract(const Duration(minutes: 5)),
        now: now,
      ),
      '5m ago',
    );
    expect(
      formatRelativeSessionTime(
        now.subtract(const Duration(hours: 2)),
        now: now,
      ),
      '2h ago',
    );
    expect(
      formatRelativeSessionTime(
        now.subtract(const Duration(days: 3)),
        now: now,
      ),
      '3d ago',
    );
  });

  test('formatRelativeSessionTime handles older and future times', () {
    final now = DateTime(2026, 7, 8, 12);

    expect(
      formatRelativeSessionTime(
        now.subtract(const Duration(days: 8)),
        now: now,
      ),
      '1w ago',
    );
    expect(
      formatRelativeSessionTime(
        now.subtract(const Duration(days: 45)),
        now: now,
      ),
      '1mo ago',
    );
    expect(
      formatRelativeSessionTime(
        now.subtract(const Duration(days: 400)),
        now: now,
      ),
      '1y ago',
    );
    expect(
      formatRelativeSessionTime(now.add(const Duration(minutes: 5)), now: now),
      'just now',
    );
  });

  test('formatRelativeSessionTime can use the test clock override', () {
    final now = DateTime(2026, 7, 8, 12);
    debugSessionTimeNow = () => now;

    expect(
      formatRelativeSessionTime(now.subtract(const Duration(hours: 4))),
      '4h ago',
    );
  });
}
