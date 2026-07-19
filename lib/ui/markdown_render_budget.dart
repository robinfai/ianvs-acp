import '../acp/acp_input_budget.dart';

final class MarkdownRenderDecision {
  const MarkdownRenderDecision({
    required this.text,
    required this.useMarkdown,
    this.omission,
  });

  final String text;
  final bool useMarkdown;
  final AcpInputOmission? omission;
}

MarkdownRenderDecision scanMarkdownForRendering(
  String source, {
  required AcpInputBudget budget,
}) {
  budget.validate();
  var tokens = 0;
  var syntaxExceeded = false;
  final lineScanner = _MarkdownLineScanner();
  final fallback = StringBuffer();
  var fallbackBytes = 0;
  var fallbackNextIndex = 0;
  var fallbackFull = false;

  for (var index = 0; index < source.length; index += 1) {
    final codeUnit = source.codeUnitAt(index);
    if (!fallbackFull && index == fallbackNextIndex) {
      final scalar = _plainFallbackScalar(source, index);
      if (scalar.bytes > budget.maxMarkdownFallbackBytes - fallbackBytes) {
        fallbackFull = true;
      } else {
        fallback.write(scalar.text);
        fallbackBytes += scalar.bytes;
        fallbackNextIndex += scalar.codeUnits;
      }
    }
    if (!syntaxExceeded) {
      final lineTokens = lineScanner.consume(codeUnit);
      final syntaxTokens = _isMarkdownSyntaxCodeUnit(codeUnit) ? 1 : 0;
      tokens += lineTokens + syntaxTokens;
      if (tokens > budget.maxMarkdownSyntaxTokens) {
        syntaxExceeded = true;
      }
    }
    if (syntaxExceeded && fallbackFull) break;
  }

  if (!syntaxExceeded) {
    tokens += lineScanner.finish();
    syntaxExceeded = tokens > budget.maxMarkdownSyntaxTokens;
  }

  if (!syntaxExceeded) {
    return MarkdownRenderDecision(text: source, useMarkdown: true);
  }

  return MarkdownRenderDecision(
    text: fallback.toString(),
    useMarkdown: false,
    omission: AcpInputOmission(
      reason: AcpInputOmissionReason.inputLimit,
      resource: 'markdown syntax tokens',
      truncated: true,
      limit: budget.maxMarkdownSyntaxTokens,
      observedAtLeast: tokens,
    ),
  );
}

bool _isMarkdownSyntaxCodeUnit(int codeUnit) {
  return switch (codeUnit) {
    0x21 || // ! image delimiter
    0x28 || // (
    0x29 || // )
    0x2a || // * emphasis/list marker
    0x3c || // < inline HTML opener
    0x5b || // [
    0x5c || // backslash escape / hard line break
    0x5d || // ]
    0x5f || // _ emphasis
    0x60 || // ` code delimiter
    0x7c || // | table separator
    0x7e => true, // ~ strike/fence delimiter
    _ => false,
  };
}

final class _MarkdownLineScanner {
  var _indent = 0;
  var _prefixOpen = true;
  var _orderedDigits = 0;
  int? _pendingOrderedDelimiter;
  var _equalsUnderline = false;
  var _equalsUnderlineValid = false;
  var _equalsTrailingWhitespace = false;
  var _currentLineHasContent = false;
  var _previousLineHasContent = false;
  var _previousWasCR = false;

  int consume(int codeUnit) {
    if (codeUnit == 0x0a && _previousWasCR) {
      _previousWasCR = false;
      return 0;
    }
    if (codeUnit == 0x0a || codeUnit == 0x0d) {
      final tokens = _finishLine();
      _previousWasCR = codeUnit == 0x0d;
      return tokens;
    }
    _previousWasCR = false;

    var tokens = 0;
    final pendingDelimiter = _pendingOrderedDelimiter;
    if (pendingDelimiter != null) {
      if (_isMarkdownSpace(codeUnit) && pendingDelimiter == 0x2e) {
        tokens += 1;
      }
      _pendingOrderedDelimiter = null;
    }

    if (_prefixOpen) {
      if (codeUnit == 0x20 && _orderedDigits == 0) {
        _indent += 1;
        if (_indent > 3) _prefixOpen = false;
        return tokens;
      }
      if (_isAsciiDigit(codeUnit)) {
        _currentLineHasContent = true;
        _orderedDigits += 1;
        if (_orderedDigits > 9) _prefixOpen = false;
        return tokens;
      }
      if (_orderedDigits > 0 && (codeUnit == 0x2e || codeUnit == 0x29)) {
        _currentLineHasContent = true;
        // A closing parenthesis already consumes one generic delimiter token.
        // A period has no generic meaning, so it is charged after the required
        // following whitespace or line ending confirms the ordered marker.
        _pendingOrderedDelimiter = codeUnit;
        _prefixOpen = false;
        return tokens;
      }

      _prefixOpen = false;
      if (!_isMarkdownSpace(codeUnit)) _currentLineHasContent = true;
      if (codeUnit == 0x3d) {
        _equalsUnderline = true;
        _equalsUnderlineValid = true;
        return tokens;
      }
      if (codeUnit == 0x23 ||
          codeUnit == 0x3e ||
          codeUnit == 0x2b ||
          codeUnit == 0x2d) {
        // One token represents the whole line-leading block marker. In
        // particular, later `-` code units in `---` are not counted again.
        return tokens + 1;
      }
      // `*` is both a list marker and a generic Markdown delimiter. The
      // generic scanner owns its single token so the block meaning is not
      // counted twice.
      return tokens;
    }

    if (!_isMarkdownSpace(codeUnit)) _currentLineHasContent = true;
    if (_equalsUnderline && _equalsUnderlineValid) {
      if (codeUnit == 0x3d && !_equalsTrailingWhitespace) {
        return tokens;
      }
      if (_isMarkdownSpace(codeUnit)) {
        _equalsTrailingWhitespace = true;
      } else {
        _equalsUnderlineValid = false;
      }
    }
    return tokens;
  }

  int finish() => _finishLine();

  int _finishLine() {
    var tokens = 0;
    final pendingDelimiter = _pendingOrderedDelimiter;
    if (pendingDelimiter == 0x2e) tokens += 1;
    final isSetextUnderline =
        _equalsUnderline && _equalsUnderlineValid && _previousLineHasContent;
    if (isSetextUnderline) tokens += 1;
    _previousLineHasContent = _currentLineHasContent && !isSetextUnderline;
    _indent = 0;
    _prefixOpen = true;
    _orderedDigits = 0;
    _pendingOrderedDelimiter = null;
    _equalsUnderline = false;
    _equalsUnderlineValid = false;
    _equalsTrailingWhitespace = false;
    _currentLineHasContent = false;
    return tokens;
  }
}

bool _isAsciiDigit(int codeUnit) => codeUnit >= 0x30 && codeUnit <= 0x39;

bool _isMarkdownSpace(int codeUnit) => codeUnit == 0x20 || codeUnit == 0x09;

({String text, int bytes, int codeUnits}) _plainFallbackScalar(
  String source,
  int index,
) {
  final first = source.codeUnitAt(index);
  if (_isHighSurrogate(first) &&
      index + 1 < source.length &&
      _isLowSurrogate(source.codeUnitAt(index + 1))) {
    return (text: source.substring(index, index + 2), bytes: 4, codeUnits: 2);
  }
  if (_isHighSurrogate(first) || _isLowSurrogate(first)) {
    return (text: '\uFFFD', bytes: 3, codeUnits: 1);
  }
  return (
    text: source.substring(index, index + 1),
    bytes: first <= 0x7f
        ? 1
        : first <= 0x7ff
        ? 2
        : 3,
    codeUnits: 1,
  );
}

bool _isHighSurrogate(int codeUnit) => codeUnit >= 0xd800 && codeUnit <= 0xdbff;

bool _isLowSurrogate(int codeUnit) => codeUnit >= 0xdc00 && codeUnit <= 0xdfff;
