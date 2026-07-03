import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'mermaid_render_options.dart';
import 'mermaid_renderer.dart';
import 'native_merman_renderer.dart';

class MermaidView extends StatefulWidget {
  const MermaidView({
    super.key,
    required this.source,
    this.renderer,
    this.options = MermaidRenderOptions.flutterSvgDefault,
    this.enablePanZoom = true,
    this.fit = BoxFit.contain,
    this.minScale = 0.25,
    this.maxScale = 4,
    this.boundaryMargin = const EdgeInsets.all(256),
    this.semanticsLabel,
    this.errorBuilder,
    this.loadingBuilder,
  });

  final String source;
  final MermaidRenderer? renderer;
  final MermaidRenderOptions options;
  final bool enablePanZoom;
  final BoxFit fit;
  final double minScale;
  final double maxScale;
  final EdgeInsets boundaryMargin;
  final String? semanticsLabel;
  final Widget Function(BuildContext context, Object error)? errorBuilder;
  final WidgetBuilder? loadingBuilder;

  @override
  State<MermaidView> createState() => _MermaidViewState();
}

class _MermaidViewState extends State<MermaidView> {
  late MermaidRenderer _renderer;
  late bool _ownsRenderer;
  late Future<String> _svgFuture;

  @override
  void initState() {
    super.initState();
    _configureRenderer();
    _svgFuture = _render();
  }

  @override
  void didUpdateWidget(covariant MermaidView oldWidget) {
    super.didUpdateWidget(oldWidget);

    final rendererChanged = oldWidget.renderer != widget.renderer;
    if (rendererChanged) {
      if (_ownsRenderer) {
        _renderer.dispose();
      }
      _configureRenderer();
    }

    final optionsChanged =
        oldWidget.options.toOptionsJson() != widget.options.toOptionsJson();
    if (rendererChanged ||
        oldWidget.source != widget.source ||
        optionsChanged) {
      _svgFuture = _render();
    }
  }

  @override
  void dispose() {
    if (_ownsRenderer) {
      _renderer.dispose();
    }
    super.dispose();
  }

  void _configureRenderer() {
    _renderer = widget.renderer ?? NativeMermanRenderer();
    _ownsRenderer = widget.renderer == null;
  }

  Future<String> _render() async {
    final result = await _renderer.render(
      widget.source,
      options: widget.options,
    );
    return result.svg;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: _svgFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return widget.loadingBuilder?.call(context) ??
              const Center(child: CircularProgressIndicator());
        }

        if (snapshot.hasError) {
          return widget.errorBuilder?.call(context, snapshot.error!) ??
              _DefaultMermaidError(error: snapshot.error!);
        }

        final svg = snapshot.data ?? '';
        final child = SvgPicture.string(
          svg,
          fit: widget.fit,
          semanticsLabel: widget.semanticsLabel,
          placeholderBuilder: (_) =>
              const Center(child: CircularProgressIndicator()),
        );

        if (!widget.enablePanZoom) {
          return child;
        }

        return InteractiveViewer(
          minScale: widget.minScale,
          maxScale: widget.maxScale,
          boundaryMargin: widget.boundaryMargin,
          child: child,
        );
      },
    );
  }
}

class _DefaultMermaidError extends StatelessWidget {
  const _DefaultMermaidError({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SelectableText(
      'Mermaid render failed:\n$error',
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.error,
      ),
    );
  }
}
