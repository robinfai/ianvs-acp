import 'dart:convert';

enum MermaidSvgPipeline { parity, readable, resvgSafe }

const Map<String, String> kMermaidFlutterSvgThemeVariables = <String, String>{
  'primaryColor': '#f8fafc',
  'primaryTextColor': '#111827',
  'primaryBorderColor': '#94a3b8',
  'lineColor': '#475569',
  'secondaryColor': '#eef2ff',
  'secondaryTextColor': '#111827',
  'secondaryBorderColor': '#818cf8',
  'tertiaryColor': '#ffffff',
  'tertiaryTextColor': '#111827',
  'tertiaryBorderColor': '#cbd5e1',
  'edgeLabelBackground': '#ffffff',
  'clusterBkg': '#f8fafc',
  'clusterBorder': '#cbd5e1',
  'labelTextColor': '#111827',
  'textColor': '#111827',
  'mainBkg': '#f8fafc',
  'nodeBorder': '#94a3b8',
  'titleColor': '#111827',
};

extension MermaidSvgPipelineWire on MermaidSvgPipeline {
  String get wireName {
    return switch (this) {
      MermaidSvgPipeline.parity => 'parity',
      MermaidSvgPipeline.readable => 'readable',
      MermaidSvgPipeline.resvgSafe => 'resvg-safe',
    };
  }
}

class MermaidRenderOptions {
  const MermaidRenderOptions({
    this.diagramId,
    this.pipeline = MermaidSvgPipeline.resvgSafe,
    this.theme = 'default',
    this.themeVariables = kMermaidFlutterSvgThemeVariables,
    this.fontFamily,
    this.rootBackgroundColor = 'transparent',
    this.viewportWidth,
    this.viewportHeight,
    this.deterministicTextMetrics = false,
    this.fixedToday,
    this.fixedLocalOffsetMinutes,
    this.resourceProfile = 'interactive',
    this.maxSourceBytes = 524288,
    this.maxSvgBytes = 8 * 1024 * 1024,
    this.maxFlowchartNodes,
    this.maxFlowchartEdges,
  }) : assert(maxSourceBytes > 0),
       assert(maxSvgBytes > 0),
       assert(viewportWidth == null || viewportWidth > 0),
       assert(viewportHeight == null || viewportHeight > 0),
       assert(maxFlowchartNodes == null || maxFlowchartNodes > 0),
       assert(maxFlowchartEdges == null || maxFlowchartEdges > 0);

  final String? diagramId;
  final MermaidSvgPipeline pipeline;
  final String theme;
  final Map<String, String> themeVariables;
  final String? fontFamily;
  final String rootBackgroundColor;
  final double? viewportWidth;
  final double? viewportHeight;
  final bool deterministicTextMetrics;
  final String? fixedToday;
  final int? fixedLocalOffsetMinutes;
  final String resourceProfile;
  final int maxSourceBytes;
  final int maxSvgBytes;
  final int? maxFlowchartNodes;
  final int? maxFlowchartEdges;

  Map<String, Object?> toJson() {
    final mergedThemeVariables = <String, Object?>{
      ...themeVariables,
      if (fontFamily != null) 'fontFamily': fontFamily,
    };
    final siteConfig = <String, Object?>{
      'theme': theme,
      if (mergedThemeVariables.isNotEmpty)
        'themeVariables': mergedThemeVariables,
    };

    final layout = <String, Object?>{
      if (viewportWidth != null) 'viewport_width': viewportWidth,
      if (viewportHeight != null) 'viewport_height': viewportHeight,
      'text_measurer': deterministicTextMetrics ? 'deterministic' : 'vendored',
    };

    final resources = <String, Object?>{
      'profile': resourceProfile,
      'max_source_bytes': maxSourceBytes,
      'max_svg_bytes': maxSvgBytes,
      if (maxFlowchartNodes != null) 'max_flowchart_nodes': maxFlowchartNodes,
      if (maxFlowchartEdges != null) 'max_flowchart_edges': maxFlowchartEdges,
    };

    final svg = <String, Object?>{
      if (diagramId != null) 'diagram_id': diagramId,
      'pipeline': pipeline.wireName,
      'root_background_color': rootBackgroundColor,
    };

    return <String, Object?>{
      'version': 1,
      if (fixedToday != null) 'fixed_today': fixedToday,
      if (fixedLocalOffsetMinutes != null)
        'fixed_local_offset_minutes': fixedLocalOffsetMinutes,
      'site_config': siteConfig,
      'layout': layout,
      'resources': resources,
      'svg': svg,
    };
  }

  String toOptionsJson() => jsonEncode(toJson());

  static const flutterSvgDefault = MermaidRenderOptions(
    pipeline: MermaidSvgPipeline.resvgSafe,
    rootBackgroundColor: 'transparent',
    resourceProfile: 'interactive',
  );

  static const goldenTestDefault = MermaidRenderOptions(
    pipeline: MermaidSvgPipeline.resvgSafe,
    deterministicTextMetrics: true,
    fixedToday: '2026-02-15',
    fixedLocalOffsetMinutes: 0,
    viewportWidth: 1024,
    viewportHeight: 768,
  );
}
