import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/tasks/retry_policy.dart';

void main() {
  test('RetryPolicy retries runtime offline twice', () {
    const policy = RetryPolicy();

    expect(policy.shouldRetry(TaskFailureReason.runtimeOffline, 1), isTrue);
    expect(policy.shouldRetry(TaskFailureReason.runtimeOffline, 2), isTrue);
    expect(policy.shouldRetry(TaskFailureReason.runtimeOffline, 3), isFalse);
  });

  test('RetryPolicy retries timeout once', () {
    const policy = RetryPolicy();

    expect(policy.shouldRetry(TaskFailureReason.timeout, 1), isTrue);
    expect(policy.shouldRetry(TaskFailureReason.timeout, 2), isFalse);
  });

  test('RetryPolicy does not retry human or permission failures', () {
    const policy = RetryPolicy();

    expect(policy.shouldRetry(TaskFailureReason.permissionDenied, 1), isFalse);
    expect(policy.shouldRetry(TaskFailureReason.humanRejected, 1), isFalse);
  });

  test('RetryPolicy recognizes the user-facing authentication message', () {
    expect(
      taskFailureReasonFromText(
        'Authentication required. Open the Agents menu and try again.',
      ),
      TaskFailureReason.authRequired,
    );
  });

  test('RetryPolicy increases delay by attempt', () {
    const policy = RetryPolicy(baseDelay: Duration(seconds: 2));

    expect(policy.delayForAttempt(1), const Duration(seconds: 2));
    expect(policy.delayForAttempt(2), const Duration(seconds: 4));
    expect(policy.delayForAttempt(3), const Duration(seconds: 8));
  });
}
