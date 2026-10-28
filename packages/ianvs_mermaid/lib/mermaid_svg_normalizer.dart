import 'package:xml/xml.dart';

const Set<String> _inlineSvgProperties = <String>{
  'color',
  'fill',
  'fill-opacity',
  'font-family',
  'font-size',
  'font-style',
  'font-weight',
  'opacity',
  'paint-order',
  'stroke',
  'stroke-dasharray',
  'stroke-linecap',
  'stroke-linejoin',
  'stroke-miterlimit',
  'stroke-opacity',
  'stroke-width',
  'text-anchor',
};

const Set<String> _attributeSvgProperties = <String>{
  'fill',
  'fill-opacity',
  'font-family',
  'font-size',
  'font-style',
  'font-weight',
  'opacity',
  'stroke',
  'stroke-dasharray',
  'stroke-linecap',
  'stroke-linejoin',
  'stroke-miterlimit',
  'stroke-opacity',
  'stroke-width',
  'text-anchor',
};

String normalizeMermaidSvgForFlutter(String svg) {
  if (!svg.contains('<style')) return svg;

  try {
    final document = XmlDocument.parse(svg);
    final styles = document.findAllElements('style').toList();
    if (styles.isEmpty) return svg;

    final rules = <_CssRule>[
      for (final style in styles) ..._parseCssRules(style.innerText),
    ];
    if (rules.isEmpty) return svg;

    for (final element in document.descendants.whereType<XmlElement>()) {
      final declarations = <String, String>{};
      for (final rule in rules) {
        if (_matchesSelector(element, rule.selector)) {
          declarations.addAll(rule.declarations);
        }
      }
      if (declarations.isNotEmpty) {
        _applyDeclarations(element, declarations);
      }
    }

    for (final style in styles) {
      style.parent?.children.remove(style);
    }
    return document.toXmlString();
  } catch (_) {
    return svg;
  }
}

List<_CssRule> _parseCssRules(String css) {
  final rules = <_CssRule>[];
  final cleaned = css.replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '');
  final rulePattern = RegExp(r'([^{}@][^{}]*)\{([^{}]*)\}');

  for (final match in rulePattern.allMatches(cleaned)) {
    final selectors = match.group(1);
    final body = match.group(2);
    if (selectors == null || body == null) continue;

    final declarations = _parseDeclarations(body);
    if (declarations.isEmpty) continue;

    for (final selector in selectors.split(',')) {
      final normalized = selector.trim();
      if (normalized.isEmpty || normalized.contains(':')) continue;
      if (normalized.contains('[') || normalized.contains('>')) continue;
      rules.add(_CssRule(normalized, declarations));
    }
  }

  return rules;
}

Map<String, String> _parseDeclarations(String body) {
  final declarations = <String, String>{};

  for (final declaration in body.split(';')) {
    final separator = declaration.indexOf(':');
    if (separator <= 0) continue;

    final property = declaration.substring(0, separator).trim();
    if (!_inlineSvgProperties.contains(property)) continue;

    final value = declaration
        .substring(separator + 1)
        .replaceAll('!important', '')
        .trim();
    if (value.isEmpty) continue;
    declarations[property] = value;
  }

  return declarations;
}

bool _matchesSelector(XmlElement element, String selector) {
  final parts = selector.split(RegExp(r'\s+')).where((part) {
    return part.isNotEmpty && part != 'svg';
  }).toList();
  if (parts.isEmpty) return false;
  if (!_matchesSimpleSelector(element, parts.last)) return false;

  var ancestor = element.parentElement;
  for (var index = parts.length - 2; index >= 0; index--) {
    final wanted = parts[index];
    var found = false;

    while (ancestor != null) {
      if (_matchesSimpleSelector(ancestor, wanted)) {
        found = true;
        ancestor = ancestor.parentElement;
        break;
      }
      ancestor = ancestor.parentElement;
    }

    if (!found) return false;
  }

  return true;
}

bool _matchesSimpleSelector(XmlElement element, String selector) {
  final normalized = selector.trim();
  if (normalized.isEmpty || normalized == '*') return true;

  final idMatch = RegExp(r'#([A-Za-z0-9_-]+)').firstMatch(normalized);
  if (idMatch != null && element.getAttribute('id') != idMatch.group(1)) {
    return false;
  }

  final classMatches = RegExp(r'\.([A-Za-z0-9_-]+)').allMatches(normalized);
  final classNames = _classNames(element);
  for (final match in classMatches) {
    final className = match.group(1);
    if (className == null || !classNames.contains(className)) return false;
  }

  final tag = normalized.replaceAll(RegExp(r'[#.][A-Za-z0-9_-]+'), '').trim();
  if (tag.isNotEmpty && element.name.local != tag) return false;

  return true;
}

Set<String> _classNames(XmlElement element) {
  final classAttribute = element.getAttribute('class') ?? '';
  return classAttribute
      .split(RegExp(r'\s+'))
      .where((className) => className.isNotEmpty)
      .toSet();
}

void _applyDeclarations(XmlElement element, Map<String, String> declarations) {
  final style = _parseDeclarations(element.getAttribute('style') ?? '');
  style.addAll(declarations);

  for (final entry in declarations.entries) {
    if (_attributeSvgProperties.contains(entry.key)) {
      element.setAttribute(entry.key, entry.value);
    }
  }

  if (style.isNotEmpty) {
    element.setAttribute(
      'style',
      style.entries.map((entry) => '${entry.key}: ${entry.value}').join('; '),
    );
  }
}

class _CssRule {
  const _CssRule(this.selector, this.declarations);

  final String selector;
  final Map<String, String> declarations;
}
