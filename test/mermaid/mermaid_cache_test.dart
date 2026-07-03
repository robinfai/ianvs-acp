import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/mermaid/mermaid_cache.dart';

void main() {
  test('cache key includes source, options, and engine version', () {
    final base = MermaidSvgCache.keyFor(
      source: 'flowchart TD\nA --> B',
      optionsJson: '{"svg":{"pipeline":"resvg-safe"}}',
      engineVersion: '0.7.0',
    );

    expect(
      MermaidSvgCache.keyFor(
        source: 'flowchart TD\nA --> C',
        optionsJson: '{"svg":{"pipeline":"resvg-safe"}}',
        engineVersion: '0.7.0',
      ),
      isNot(base),
    );
    expect(
      MermaidSvgCache.keyFor(
        source: 'flowchart TD\nA --> B',
        optionsJson: '{"svg":{"pipeline":"readable"}}',
        engineVersion: '0.7.0',
      ),
      isNot(base),
    );
    expect(
      MermaidSvgCache.keyFor(
        source: 'flowchart TD\nA --> B',
        optionsJson: '{"svg":{"pipeline":"resvg-safe"}}',
        engineVersion: '0.8.0',
      ),
      isNot(base),
    );
  });

  test('evicts the least recently used entry', () {
    final cache = MermaidSvgCache.memory(maxEntries: 2);

    cache.set('a', '<svg>a</svg>');
    cache.set('b', '<svg>b</svg>');
    expect(cache.get('a'), '<svg>a</svg>');

    cache.set('c', '<svg>c</svg>');

    expect(cache.get('b'), isNull);
    expect(cache.get('a'), '<svg>a</svg>');
    expect(cache.get('c'), '<svg>c</svg>');
    expect(cache.length, 2);
  });
}
