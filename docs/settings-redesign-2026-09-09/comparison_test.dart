import 'dart:io';

import 'package:ianvs_design/ianvs_design.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

final _captureTheme = IanvsTheme.build(platform: TargetPlatform.macOS);

void main() {
  setUpAll(() async {
    Future<ByteData> bytes(String path) async =>
        ByteData.sublistView(await File(path).readAsBytes());
    var sdk = File(Platform.resolvedExecutable).parent;
    while (!Directory(
      '${sdk.path}/bin/cache/artifacts/material_fonts',
    ).existsSync()) {
      if (sdk.parent.path == sdk.path) {
        throw StateError('Flutter font cache missing');
      }
      sdk = sdk.parent;
    }
    await Future.wait([
      (FontLoader(
        _captureTheme.textTheme.bodyMedium!.fontFamily!,
      )..addFont(bytes('/System/Library/Fonts/Supplemental/Arial.ttf'))).load(),
      (FontLoader(
        'PingFang SC',
      )..addFont(bytes('/System/Library/Fonts/Hiragino Sans GB.ttc'))).load(),
      (FontLoader(
            _captureTheme.extension<IanvsTypography>()!.code.fontFamily!,
          )..addFont(
            bytes(
              '${sdk.path}/bin/cache/dart-sdk/bin/resources/devtools/assets/fonts/Roboto_Mono/RobotoMono-Regular.ttf',
            ),
          ))
          .load(),
      (FontLoader('MaterialIcons')..addFont(
            bytes(
              '${sdk.path}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
            ),
          ))
          .load(),
    ]);
  });

  testWidgets('compare selected design and implementation', (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final source = File(
      'docs/settings-redesign-2026-09-09/concepts/workspace.png',
    ).readAsBytesSync();
    final actual = File(
      'docs/settings-redesign-2026-09-09/screenshots/after/04-agent-draft.png',
    ).readAsBytesSync();
    const frameKey = Key('comparison');
    Widget picture(Uint8List bytes) =>
        Image.memory(bytes, width: 1440, height: 1024, fit: BoxFit.fill);
    Widget focus(Uint8List bytes) => ClipRect(
      child: SizedBox(
        width: 828,
        height: 730,
        child: OverflowBox(
          alignment: Alignment.topLeft,
          maxWidth: 1440,
          maxHeight: 1024,
          child: Transform.translate(
            offset: const Offset(-600, -150),
            child: picture(bytes),
          ),
        ),
      ),
    );
    Future<void> board(
      String name,
      Size size,
      Widget left,
      Widget right,
    ) async {
      tester.view.physicalSize = size;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: RepaintBoundary(
            key: frameKey,
            child: ColoredBox(
              color: Colors.white,
              child: Column(
                children: [
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '方案 3 · ImageGen',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontFamily:
                                _captureTheme.textTheme.bodyMedium!.fontFamily!,
                            fontFamilyFallback: _captureTheme
                                .textTheme
                                .bodyMedium!
                                .fontFamilyFallback,
                            fontSize: 20,
                            color: Colors.black,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          '实际 Flutter 界面 · 草稿状态',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontFamily:
                                _captureTheme.textTheme.bodyMedium!.fontFamily!,
                            fontFamilyFallback: _captureTheme
                                .textTheme
                                .bodyMedium!
                                .fontFamilyFallback,
                            fontSize: 20,
                            color: Colors.black,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: Row(
                      children: [
                        Expanded(child: FittedBox(child: left)),
                        const SizedBox(width: 12),
                        Expanded(child: FittedBox(child: right)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.runAsync(() async {
        await precacheImage(
          MemoryImage(source),
          tester.element(find.byKey(frameKey)),
        );
        await precacheImage(
          MemoryImage(actual),
          tester.element(find.byKey(frameKey)),
        );
      });
      await tester.pumpAndSettle();
      await expectLater(
        find.byKey(frameKey),
        matchesGoldenFile('screenshots/comparison/$name.png'),
      );
    }

    await board(
      'full',
      const Size(1920, 735),
      picture(source),
      picture(actual),
    );
    await board('details', const Size(1670, 785), focus(source), focus(actual));
  });
}
