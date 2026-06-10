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
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Clear data'),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets('clear data button calls provided callback', (tester) async {
    var cleared = false;
    await tester.pumpWidget(
      MaterialApp(home: MemoryExplorerPage(onClearData: () => cleared = true)),
    );

    await tester.tap(find.widgetWithText(OutlinedButton, 'Clear data'));
    await tester.pump();

    expect(cleared, isTrue);
  });
}
