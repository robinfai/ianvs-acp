import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_agent_chat/ianvs_agent_chat.dart';
import 'package:ianvs_agent_core/ianvs_agent_core.dart';

void main() {
  for (final width in [320.0, 390.0]) {
    testWidgets(
      'narrow $width timeline keeps table words readable and scrollable',
      (tester) async {
        tester.view.physicalSize = Size(width, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ChatTimeline(
                agentName: 'Fixture',
                messages: [
                  ChatMessageData(
                    role: ChatMessageRole.assistant,
                    text:
                        '''| Package | Verification | Assignee | Environment | Outcome |
| --- | --- | --- | --- | --- |
| Alpha | Ready | Robin | China | Passed |
| Beta | Ready | Casey | Europe | Passed |
''',
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final paragraphs = tester
            .stateList<EditableTextState>(find.byType(EditableText))
            .map((state) => state.renderEditable);
        for (final word in ['Alpha', 'Ready', 'Robin', 'China', 'Passed']) {
          final paragraph = paragraphs.firstWhere(
            (p) => p.text?.toPlainText() == word,
          );
          final boxes = paragraph.getBoxesForSelection(
            TextSelection(baseOffset: 0, extentOffset: word.length),
          );
          expect(
            boxes.map((box) => box.top).toSet(),
            hasLength(1),
            reason: '$word must not wrap into individual characters',
          );
        }
        final horizontal = find.byWidgetPredicate(
          (widget) =>
              widget is Scrollable &&
              axisDirectionToAxis(widget.axisDirection) == Axis.horizontal,
        );
        final scrollable = horizontal
            .evaluate()
            .map(
              (element) =>
                  (element as StatefulElement).state as ScrollableState,
            )
            .firstWhere((state) => state.position.maxScrollExtent > 0);
        expect(scrollable.position.viewportDimension, lessThanOrEqualTo(width));
        scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
        await tester.pumpAndSettle();
        expect(scrollable.position.pixels, greaterThan(0));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('timeline ordered markers retain room for two-digit numbers', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatTimeline(
            agentName: 'Fixture',
            messages: [
              ChatMessageData(
                role: ChatMessageRole.assistant,
                text: List.generate(
                  12,
                  (index) => '${index + 1}. Item ${index + 1}',
                ).join('\n'),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final markers = find.byWidgetPredicate(
      (widget) =>
          widget is Text && RegExp(r'^\d+\.$').hasMatch(widget.data ?? ''),
    );
    expect(markers, findsNWidgets(12));
    for (final element in markers.evaluate()) {
      final richText = find.descendant(
        of: find.byWidget(element.widget),
        matching: find.byType(RichText),
      );
      final paragraph = tester.renderObject<RenderParagraph>(richText);
      expect(
        paragraph.size.width + 0.1,
        greaterThanOrEqualTo(paragraph.getMaxIntrinsicWidth(double.infinity)),
        reason: '${paragraph.text.toPlainText()} needs its full marker width',
      );
    }
    expect(tester.takeException(), isNull);
  });
}
