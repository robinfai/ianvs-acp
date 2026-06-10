import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/memory/memory_context_builder.dart';

void main() {
  test('builds memory context as background block', () {
    final text = MemoryContextBuilder.build([
      const MemoryContextItem(
        kind: 'project_rule',
        text: 'Do not use nc/netcat.',
      ),
      const MemoryContextItem(
        kind: 'architecture_decision',
        text: 'Rust only owns memory.',
      ),
    ]);
    expect(text, contains('<agent_memory_context>'));
    expect(text, contains('current instruction wins'));
    expect(text, contains('[project_rule] Do not use nc/netcat.'));
  });
}
