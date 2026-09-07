import 'mermaid_render_options.dart';
import 'mermaid_render_result.dart';

abstract interface class MermaidRenderer {
  Future<MermaidRenderResult> render(
    String source, {
    MermaidRenderOptions options = MermaidRenderOptions.flutterSvgDefault,
    bool includeLayout = false,
  });

  Future<MermaidValidationResult> validate(
    String source, {
    MermaidRenderOptions options = MermaidRenderOptions.flutterSvgDefault,
  });

  Future<String> layoutJson(
    String source, {
    MermaidRenderOptions options = MermaidRenderOptions.flutterSvgDefault,
  });

  void dispose();
}
