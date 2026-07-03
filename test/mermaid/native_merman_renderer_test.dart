import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/mermaid/mermaid_exception.dart';
import 'package:ianvs_acp/mermaid/native_merman_renderer.dart';
import 'package:merman/merman.dart' as merman;

void main() {
  test(
    'renders and caches SVG by source, options, and engine version',
    () async {
      final engine = _FakeMermanEngine();
      final renderer = NativeMermanRenderer.withEngine(engine);

      final first = await renderer.render('flowchart TD\nA --> B');
      final second = await renderer.render('flowchart TD\nA --> B');

      expect(first.fromCache, isFalse);
      expect(second.fromCache, isTrue);
      expect(second.svg, first.svg);
      expect(engine.renderCalls, 1);
    },
  );

  test('can add layout JSON while reusing cached SVG', () async {
    final engine = _FakeMermanEngine();
    final renderer = NativeMermanRenderer.withEngine(engine);

    await renderer.render('flowchart TD\nA --> B');
    final withLayout = await renderer.render(
      'flowchart TD\nA --> B',
      includeLayout: true,
    );

    expect(withLayout.fromCache, isTrue);
    expect(withLayout.layoutJson, contains('"layout"'));
    expect(engine.renderCalls, 1);
    expect(engine.layoutCalls, 1);
  });

  test('validation exposes invalid source details without throwing', () async {
    final engine = _FakeMermanEngine();
    final renderer = NativeMermanRenderer.withEngine(engine);

    final validation = await renderer.validate('not a diagram');

    expect(validation.valid, isFalse);
    expect(validation.codeName, 'MERMAN_NO_DIAGRAM');
    expect(validation.errorMessage, 'No Mermaid diagram was detected.');
  });

  test('wraps unexpected render failures', () async {
    final engine = _FakeMermanEngine(throwUnexpected: true);
    final renderer = NativeMermanRenderer.withEngine(engine);

    expect(
      renderer.render('flowchart TD\nA --> B'),
      throwsA(isA<MermaidRenderFailure>()),
    );
  });

  test('throws after disposal', () async {
    final engine = _FakeMermanEngine();
    final renderer = NativeMermanRenderer.withEngine(engine)..dispose();

    expect(
      renderer.render('flowchart TD\nA --> B'),
      throwsA(isA<MermaidRendererDisposedException>()),
    );
  });

  test('renders a basic flowchart with the packaged native engine', () async {
    final libraryPath = await _nativeLibraryPath();
    if (libraryPath == null) return;

    final renderer = NativeMermanRenderer(
      openEngine: () => BundledMermanEngine.openPath(libraryPath),
    );
    final result = await renderer.render('flowchart TD\nA[Hello] --> B[World]');
    final validation = await renderer.validate('not a diagram');

    expect(result.svg, contains('<svg'));
    expect(result.svg, contains('Hello'));
    expect(result.svg, contains('World'));
    expect(result.svg, isNot(contains('<style')));
    expect(result.svg, contains('fill="#f8fafc"'));
    expect(result.svg, contains('stroke="#475569"'));
    expect(validation.valid, isFalse);

    renderer.dispose();
  });
}

class _FakeMermanEngine implements MermanEngine {
  _FakeMermanEngine({this.throwUnexpected = false});

  final bool throwUnexpected;
  int renderCalls = 0;
  int layoutCalls = 0;

  @override
  String get packageVersion => 'fake-0.7.0';

  @override
  String renderSvg(String source, {String? optionsJson}) {
    renderCalls++;
    if (throwUnexpected) {
      throw StateError('boom');
    }
    return '<svg data-options="$optionsJson"><text>$source</text></svg>';
  }

  @override
  String layoutJsonRaw(String source, {String? optionsJson}) {
    layoutCalls++;
    return '{"meta":{"source":"$source"},"layout":{}}';
  }

  @override
  merman.MermanValidationResult validate(String source, {String? optionsJson}) {
    final valid = source.startsWith('flowchart');
    return merman.MermanValidationResult(
      valid: valid,
      error: valid ? null : 'No Mermaid diagram was detected.',
      code: valid ? 0 : 4,
      codeName: valid ? 'MERMAN_OK' : 'MERMAN_NO_DIAGRAM',
    );
  }
}

Future<String?> _nativeLibraryPath() async {
  final packageDir = await _packageRoot('merman');
  if (packageDir == null) return null;
  final path = switch (Abi.current()) {
    Abi.macosArm64 ||
    Abi.macosX64 => '$packageDir/macos/Libraries/libmerman_ffi.dylib',
    Abi.linuxX64 => '$packageDir/linux/lib/x86_64/libmerman_ffi.so',
    Abi.linuxArm64 => '$packageDir/linux/lib/aarch64/libmerman_ffi.so',
    Abi.windowsX64 => '$packageDir/windows/merman_ffi.dll',
    _ => null,
  };
  if (path == null || !File(path).existsSync()) return null;
  return path;
}

Future<String?> _packageRoot(String packageName) async {
  final configFile = File('.dart_tool/package_config.json');
  if (!configFile.existsSync()) return null;

  final decoded =
      jsonDecode(await configFile.readAsString()) as Map<String, Object?>;
  final packages = decoded['packages'];
  if (packages is! List<Object?>) return null;

  for (final package in packages) {
    if (package is! Map<String, Object?> || package['name'] != packageName) {
      continue;
    }
    final rootUri = package['rootUri'];
    if (rootUri is! String) return null;
    return configFile.uri.resolve(rootUri).toFilePath();
  }
  return null;
}
