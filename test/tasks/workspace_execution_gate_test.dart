import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/tasks/workspace_execution_gate.dart';

void main() {
  test('WorkspaceExecutionGate locks normalized workspace paths', () {
    final gate = WorkspaceExecutionGate();

    expect(gate.tryAcquire('/workspace/app/', 'task-1'), isTrue);
    expect(gate.isLocked('/workspace/app'), isTrue);
    expect(gate.tryAcquire('/workspace/app', 'task-2'), isFalse);
    expect(gate.tryAcquire('/workspace/other', 'task-3'), isTrue);
  });

  test('WorkspaceExecutionGate only releases the owner task lock', () {
    final gate = WorkspaceExecutionGate();

    expect(gate.tryAcquire('/workspace/app', 'task-1'), isTrue);
    gate.release('/workspace/app', 'task-2');
    expect(gate.isLocked('/workspace/app'), isTrue);

    gate.release('/workspace/app/', 'task-1');
    expect(gate.isLocked('/workspace/app'), isFalse);
    expect(gate.tryAcquire('/workspace/app', 'task-2'), isTrue);
  });
}
