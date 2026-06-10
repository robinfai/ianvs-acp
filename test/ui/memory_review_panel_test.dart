import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/ui/components/memory_review_panel.dart';

void main() {
  testWidgets('review panel shows candidate actions', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MemoryReviewPanel(
            candidates: [
              MemoryReviewCandidate(
                id: 'cand-1',
                kind: 'project_rule',
                scope: 'repo',
                text: 'Do not use nc/netcat.',
                confidence: 0.95,
                reason: 'User explicitly gave a rule.',
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.text('Memory Review'), findsOneWidget);
    expect(find.text('Do not use nc/netcat.'), findsOneWidget);
    expect(find.text('Approve'), findsOneWidget);
    expect(find.text('Edit'), findsOneWidget);
    expect(find.text('Reject'), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Approve'))
          .onPressed,
      isNull,
    );
  });

  testWidgets('review panel action callbacks receive candidate', (
    tester,
  ) async {
    MemoryReviewCandidate? approved;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MemoryReviewPanel(
            candidates: const [
              MemoryReviewCandidate(
                id: 'cand-1',
                kind: 'project_rule',
                scope: 'repo',
                text: 'Do not use nc/netcat.',
              ),
            ],
            onApprove: (candidate) => approved = candidate,
          ),
        ),
      ),
    );

    await tester.tap(find.widgetWithText(TextButton, 'Approve'));
    await tester.pump();

    expect(approved?.id, 'cand-1');
  });
}
