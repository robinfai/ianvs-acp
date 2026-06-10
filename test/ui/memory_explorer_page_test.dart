import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/ui/components/memory_explorer_page.dart';

void main() {
  testWidgets('explorer exposes memory management tabs and clear data', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: MemoryExplorerPage()));

    expect(find.text('All memory'), findsOneWidget);
    expect(find.text('Candidates'), findsOneWidget);
    expect(find.text('Change requests'), findsOneWidget);
    expect(find.text('Audit log'), findsOneWidget);
    expect(find.text('Clear data'), findsOneWidget);
  });
}
