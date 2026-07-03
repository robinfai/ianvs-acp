import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/mermaid/mermaid_render_options.dart';

void main() {
  test('serializes the Flutter SVG default for strict SVG consumers', () {
    const options = MermaidRenderOptions.flutterSvgDefault;

    final decoded = jsonDecode(options.toOptionsJson()) as Map<String, Object?>;
    final siteConfig = decoded['site_config'] as Map<String, Object?>;
    final themeVariables = siteConfig['themeVariables'] as Map<String, Object?>;
    final svg = decoded['svg'] as Map<String, Object?>;
    final resources = decoded['resources'] as Map<String, Object?>;

    expect(siteConfig['theme'], 'default');
    expect(themeVariables['primaryColor'], '#f8fafc');
    expect(themeVariables['primaryTextColor'], '#111827');
    expect(themeVariables['lineColor'], '#475569');
    expect(svg['pipeline'], 'resvg-safe');
    expect(svg['root_background_color'], 'transparent');
    expect(resources['profile'], 'interactive');
    expect(resources['max_source_bytes'], 524288);
    expect(resources['max_svg_bytes'], 8 * 1024 * 1024);
  });

  test('serializes deterministic snapshot settings', () {
    const options = MermaidRenderOptions.goldenTestDefault;

    final decoded = jsonDecode(options.toOptionsJson()) as Map<String, Object?>;
    final layout = decoded['layout'] as Map<String, Object?>;

    expect(decoded['fixed_today'], '2026-02-15');
    expect(decoded['fixed_local_offset_minutes'], 0);
    expect(layout['text_measurer'], 'deterministic');
    expect(layout['viewport_width'], 1024);
    expect(layout['viewport_height'], 768);
  });

  test('can include resource budgets for larger flowcharts', () {
    const options = MermaidRenderOptions(
      maxFlowchartNodes: 250,
      maxFlowchartEdges: 500,
    );

    final decoded = jsonDecode(options.toOptionsJson()) as Map<String, Object?>;
    final resources = decoded['resources'] as Map<String, Object?>;

    expect(resources['max_flowchart_nodes'], 250);
    expect(resources['max_flowchart_edges'], 500);
  });

  test('merges a custom font into the default light theme variables', () {
    const options = MermaidRenderOptions(fontFamily: 'Inter, sans-serif');

    final decoded = jsonDecode(options.toOptionsJson()) as Map<String, Object?>;
    final siteConfig = decoded['site_config'] as Map<String, Object?>;
    final themeVariables = siteConfig['themeVariables'] as Map<String, Object?>;

    expect(themeVariables['primaryColor'], '#f8fafc');
    expect(themeVariables['fontFamily'], 'Inter, sans-serif');
  });
}
