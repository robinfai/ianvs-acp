typedef MemorySearchCallback =
    Future<String?> Function(MemoryPromptContext context);
typedef MemoryDisposeCallback = void Function();

class MemoryPromptContext {
  const MemoryPromptContext({required this.prompt, this.sessionId, this.cwd});

  final String prompt;
  final String? sessionId;
  final String? cwd;
}

class PreparedPrompt {
  const PreparedPrompt({required this.prompt, this.memoryContext, this.error});

  final String prompt;
  final String? memoryContext;
  final String? error;
}

class AcpMemoryMiddleware {
  const AcpMemoryMiddleware({required this.search, this.onDispose});

  final MemorySearchCallback search;
  final MemoryDisposeCallback? onDispose;

  Future<PreparedPrompt> preparePrompt(
    String prompt, {
    String? sessionId,
    String? cwd,
  }) async {
    try {
      final memoryContext = await search(
        MemoryPromptContext(prompt: prompt, sessionId: sessionId, cwd: cwd),
      );
      return PreparedPrompt(prompt: prompt, memoryContext: memoryContext);
    } catch (error) {
      return PreparedPrompt(prompt: prompt, error: error.toString());
    }
  }

  void dispose() => onDispose?.call();
}
