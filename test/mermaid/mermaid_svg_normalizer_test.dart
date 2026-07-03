import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/mermaid/mermaid_svg_normalizer.dart';

void main() {
  test('inlines Mermaid class styles for flutter_svg', () {
    const svg = '''
<svg id="merman" viewBox="0 0 100 100">
  <style>
    #merman .node rect { fill: #f8fafc; stroke: #94a3b8; stroke-width: 1px; }
    #merman .node .label text, #merman span { fill: #111827; color: #111827; }
    #merman .edgePath .path { stroke: #475569; stroke-width: 1px; fill: none; }
  </style>
  <g class="node">
    <rect width="40" height="20"/>
    <g class="label"><text>开始</text></g>
  </g>
  <g class="edgePath"><path class="path" d="M 0 0 L 10 10"/></g>
</svg>
''';

    final normalized = normalizeMermaidSvgForFlutter(svg);

    expect(normalized, isNot(contains('<style')));
    expect(normalized, contains('fill="#f8fafc"'));
    expect(normalized, contains('stroke="#94a3b8"'));
    expect(normalized, contains('fill="#111827"'));
    expect(normalized, contains('stroke="#475569"'));
  });

  test('returns original SVG when it cannot be parsed', () {
    const svg = '<svg><style>.node { fill: red; }</style>';

    expect(normalizeMermaidSvgForFlutter(svg), svg);
  });
}
