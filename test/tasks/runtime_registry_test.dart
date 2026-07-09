import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/tasks/runtime_registry.dart';

void main() {
  test('LocalRuntimeRegistry returns unknown status before probe', () {
    final registry = LocalRuntimeRegistry(clock: () => DateTime(2026, 7, 8, 9));

    final status = registry.statusForAgent(' Codex ');

    expect(status.agentName, 'Codex');
    expect(status.availability, RuntimeAvailability.unknown);
    expect(status.available, isFalse);
  });

  test('LocalRuntimeRegistry probes and stores runtime status', () async {
    var notifications = 0;
    final registry = LocalRuntimeRegistry(
      clock: () => DateTime(2026, 7, 8, 9),
      probe: (agentName) => LocalRuntimeStatus.available(
        agentName: agentName,
        checkedAt: DateTime(2026, 7, 8, 9, 1),
        supportsSessionResume: true,
        supportsPermissions: true,
        maxConcurrentTasks: 2,
      ),
    );
    registry.addListener(() {
      notifications += 1;
    });

    final status = await registry.probeAgent(' Codex ');

    expect(status.availability, RuntimeAvailability.available);
    expect(status.available, isTrue);
    expect(status.supportsSessionResume, isTrue);
    expect(status.supportsPermissions, isTrue);
    expect(status.maxConcurrentTasks, 2);
    expect(registry.statusForAgent('Codex'), same(status));
    expect(notifications, 1);
  });

  test('LocalRuntimeRegistry records auth required status', () {
    final registry = LocalRuntimeRegistry();

    registry.setStatus(
      LocalRuntimeStatus.authRequired(
        agentName: 'Codex',
        checkedAt: DateTime(2026, 7, 8, 9),
        reason: 'Authentication expired.',
      ),
    );

    final status = registry.statusForAgent('Codex');
    expect(status.availability, RuntimeAvailability.authRequired);
    expect(status.unavailableReason, 'Authentication expired.');
  });
}
