import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUpAll(() async {
    final font = await File(
      '/System/Library/Fonts/Supplemental/Arial.ttf',
    ).readAsBytes();
    await (FontLoader(
      'Audit',
    )..addFont(Future.value(ByteData.sublistView(font)))).load();
  });

  testWidgets('compare native main window and refined settings', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const root = 'docs/macos-settings-refinement-2026-09-09/screenshots';
    const key = Key('comparison');
    Future<void> board(
      String output,
      Size pictureSize,
      List<(String, String)> items,
    ) async {
      final images = [
        for (final item in items)
          MemoryImage(File('$root/${item.$2}').readAsBytesSync()),
      ];
      tester.view.physicalSize = Size(
        pictureSize.width * items.length + 12 * (items.length - 1),
        pictureSize.height + 44,
      );
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: RepaintBoundary(
            key: key,
            child: ColoredBox(
              color: Colors.white,
              child: Row(
                children: [
                  for (var i = 0; i < items.length; i++) ...[
                    if (i > 0) const SizedBox(width: 12),
                    Column(
                      children: [
                        SizedBox(
                          width: pictureSize.width,
                          height: 44,
                          child: Center(
                            child: Text(
                              items[i].$1,
                              style: const TextStyle(
                                fontFamily: 'Audit',
                                fontSize: 18,
                                color: Colors.black,
                              ),
                            ),
                          ),
                        ),
                        Image(
                          image: images[i],
                          width: pictureSize.width,
                          height: pictureSize.height,
                          fit: BoxFit.contain,
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      );
      await tester.runAsync(() async {
        for (final image in images) {
          await precacheImage(image, tester.element(find.byKey(key)));
        }
      });
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byKey(key),
        matchesGoldenFile('screenshots/comparison/$output.png'),
      );
    }

    await board('main-settings-800', const Size(800, 600), [
      ('Main window baseline', 'before/01-main-800.jpg'),
      ('Settings before', 'before/02-settings-800.jpg'),
      ('Settings after', 'after/02-settings-800.jpg'),
    ]);
    await board('main-settings-wide', const Size(1225, 768), [
      ('Main window baseline', 'before/08-main-wide.jpg'),
      ('Settings after', 'after/01-settings-wide.jpg'),
    ]);
    await board('session-parameters', const Size(1225, 768), [
      ('Session parameters before', 'before/11-session-parameters-wide.jpg'),
      ('Session parameters after', 'after/11-session-parameters-wide.jpg'),
    ]);
  });
}
