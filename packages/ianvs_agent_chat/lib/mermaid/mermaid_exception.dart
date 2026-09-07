class MermaidRenderFailure implements Exception {
  const MermaidRenderFailure({
    required this.message,
    this.cause,
    this.stackTrace,
  });

  final String message;
  final Object? cause;
  final StackTrace? stackTrace;

  @override
  String toString() {
    if (cause == null) return 'MermaidRenderFailure($message)';
    return 'MermaidRenderFailure($message, cause: $cause)';
  }
}

class MermaidRendererDisposedException implements Exception {
  const MermaidRendererDisposedException();

  @override
  String toString() => 'MermaidRendererDisposedException';
}
