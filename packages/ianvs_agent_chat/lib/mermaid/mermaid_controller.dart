import 'package:flutter/foundation.dart';

import 'mermaid_render_options.dart';
import 'mermaid_render_result.dart';
import 'mermaid_renderer.dart';
import 'native_merman_renderer.dart';

class MermaidController extends ChangeNotifier {
  MermaidController({MermaidRenderer? renderer})
    : _renderer = renderer ?? NativeMermanRenderer(),
      _ownsRenderer = renderer == null;

  final MermaidRenderer _renderer;
  final bool _ownsRenderer;
  bool _disposed = false;
  bool _isRendering = false;
  int _generation = 0;
  MermaidRenderResult? _lastResult;
  Object? _lastError;
  StackTrace? _lastStackTrace;

  bool get isRendering => _isRendering;

  MermaidRenderResult? get lastResult => _lastResult;

  Object? get lastError => _lastError;

  StackTrace? get lastStackTrace => _lastStackTrace;

  Future<MermaidRenderResult> render(
    String source, {
    MermaidRenderOptions options = MermaidRenderOptions.flutterSvgDefault,
    bool includeLayout = false,
  }) async {
    _checkNotDisposed();
    final generation = ++_generation;
    _isRendering = true;
    _lastError = null;
    _lastStackTrace = null;
    notifyListeners();

    try {
      final result = await _renderer.render(
        source,
        options: options,
        includeLayout: includeLayout,
      );
      if (generation == _generation && !_disposed) {
        _lastResult = result;
        _isRendering = false;
        notifyListeners();
      }
      return result;
    } catch (error, stackTrace) {
      if (generation == _generation && !_disposed) {
        _lastError = error;
        _lastStackTrace = stackTrace;
        _isRendering = false;
        notifyListeners();
      }
      rethrow;
    }
  }

  Future<MermaidValidationResult> validate(
    String source, {
    MermaidRenderOptions options = MermaidRenderOptions.flutterSvgDefault,
  }) {
    _checkNotDisposed();
    return _renderer.validate(source, options: options);
  }

  Future<String> layoutJson(
    String source, {
    MermaidRenderOptions options = MermaidRenderOptions.flutterSvgDefault,
  }) {
    _checkNotDisposed();
    return _renderer.layoutJson(source, options: options);
  }

  void clear() {
    _checkNotDisposed();
    _generation++;
    _isRendering = false;
    _lastResult = null;
    _lastError = null;
    _lastStackTrace = null;
    notifyListeners();
  }

  void _checkNotDisposed() {
    if (_disposed) {
      throw StateError('MermaidController has been disposed.');
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_ownsRenderer) {
      _renderer.dispose();
    }
    super.dispose();
  }
}
