class MermaidRenderResult {
  const MermaidRenderResult({
    required this.source,
    required this.svg,
    required this.optionsJson,
    this.layoutJson,
    this.engineVersion,
    this.fromCache = false,
  });

  final String source;
  final String svg;
  final String optionsJson;
  final String? layoutJson;
  final String? engineVersion;
  final bool fromCache;
}

class MermaidValidationResult {
  const MermaidValidationResult({
    required this.valid,
    this.raw,
    this.errorMessage,
    this.code,
    this.codeName,
  });

  final bool valid;
  final Object? raw;
  final String? errorMessage;
  final int? code;
  final String? codeName;
}
