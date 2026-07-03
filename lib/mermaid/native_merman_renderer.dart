import 'package:merman/merman.dart' as merman;

import 'mermaid_cache.dart';
import 'mermaid_exception.dart';
import 'mermaid_render_options.dart';
import 'mermaid_render_result.dart';
import 'mermaid_renderer.dart';
import 'mermaid_svg_normalizer.dart';

abstract interface class MermanEngine {
  String get packageVersion;

  String renderSvg(String source, {String? optionsJson});

  String layoutJsonRaw(String source, {String? optionsJson});

  merman.MermanValidationResult validate(String source, {String? optionsJson});
}

class BundledMermanEngine implements MermanEngine {
  BundledMermanEngine(this._engine);

  factory BundledMermanEngine.open() {
    return BundledMermanEngine(merman.Merman.open());
  }

  factory BundledMermanEngine.openPath(String path) {
    return BundledMermanEngine(merman.Merman.openPath(path));
  }

  final merman.Merman _engine;

  @override
  String get packageVersion => _engine.packageVersion;

  @override
  String renderSvg(String source, {String? optionsJson}) {
    return _engine.renderSvg(source, optionsJson: optionsJson);
  }

  @override
  String layoutJsonRaw(String source, {String? optionsJson}) {
    return _engine.layoutJsonRaw(source, optionsJson: optionsJson);
  }

  @override
  merman.MermanValidationResult validate(String source, {String? optionsJson}) {
    return _engine.validate(source, optionsJson: optionsJson);
  }
}

typedef MermanEngineOpener = MermanEngine Function();

class NativeMermanRenderer implements MermaidRenderer {
  NativeMermanRenderer({MermaidSvgCache? cache, MermanEngineOpener? openEngine})
    : _cache = cache ?? MermaidSvgCache.memory(),
      _openEngine = openEngine ?? BundledMermanEngine.open;

  factory NativeMermanRenderer.withEngine(
    MermanEngine engine, {
    MermaidSvgCache? cache,
  }) {
    return NativeMermanRenderer(cache: cache, openEngine: () => engine);
  }

  final MermaidSvgCache _cache;
  final MermanEngineOpener _openEngine;
  MermanEngine? _engine;
  bool _disposed = false;

  MermanEngine get _openedEngine {
    if (_disposed) {
      throw const MermaidRendererDisposedException();
    }
    return _engine ??= _openEngine();
  }

  @override
  Future<MermaidRenderResult> render(
    String source, {
    MermaidRenderOptions options = MermaidRenderOptions.flutterSvgDefault,
    bool includeLayout = false,
  }) async {
    final optionsJson = options.toOptionsJson();
    final engine = _openedEngine;
    final version = engine.packageVersion;
    final cacheKey = MermaidSvgCache.keyFor(
      source: source,
      optionsJson: optionsJson,
      engineVersion: version,
    );
    final cachedSvg = _cache.get(cacheKey);

    if (cachedSvg != null && !includeLayout) {
      return MermaidRenderResult(
        source: source,
        svg: cachedSvg,
        optionsJson: optionsJson,
        engineVersion: version,
        fromCache: true,
      );
    }

    try {
      final svg =
          cachedSvg ??
          normalizeMermaidSvgForFlutter(
            engine.renderSvg(source, optionsJson: optionsJson),
          );
      final layout = includeLayout
          ? engine.layoutJsonRaw(source, optionsJson: optionsJson)
          : null;

      if (cachedSvg == null) {
        _cache.set(cacheKey, svg);
      }

      return MermaidRenderResult(
        source: source,
        svg: svg,
        layoutJson: layout,
        optionsJson: optionsJson,
        engineVersion: version,
        fromCache: cachedSvg != null,
      );
    } on merman.MermanException {
      rethrow;
    } catch (error, stackTrace) {
      throw MermaidRenderFailure(
        message: 'Unexpected Mermaid render failure',
        cause: error,
        stackTrace: stackTrace,
      );
    }
  }

  @override
  Future<MermaidValidationResult> validate(
    String source, {
    MermaidRenderOptions options = MermaidRenderOptions.flutterSvgDefault,
  }) async {
    try {
      final validation = _openedEngine.validate(
        source,
        optionsJson: options.toOptionsJson(),
      );
      return MermaidValidationResult(
        valid: validation.valid,
        raw: validation,
        errorMessage: validation.error,
        code: validation.code,
        codeName: validation.codeName,
      );
    } on merman.MermanException catch (error) {
      return MermaidValidationResult(
        valid: false,
        raw: error,
        errorMessage: '${error.codeName}: ${error.message}',
        code: error.code,
        codeName: error.codeName,
      );
    }
  }

  @override
  Future<String> layoutJson(
    String source, {
    MermaidRenderOptions options = MermaidRenderOptions.flutterSvgDefault,
  }) async {
    return _openedEngine.layoutJsonRaw(
      source,
      optionsJson: options.toOptionsJson(),
    );
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _engine = null;
    _cache.clear();
  }
}
