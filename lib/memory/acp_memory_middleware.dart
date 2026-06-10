typedef MemorySearchCallback =
    Future<String?> Function(MemoryPromptContext context);
typedef MemoryExtractCallback =
    Future<void> Function(MemoryTurnContext context);
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

class MemoryTurnContext {
  const MemoryTurnContext({
    required this.userPrompt,
    required this.assistantAnswer,
    this.sessionId,
    this.cwd,
  });

  final String userPrompt;
  final String assistantAnswer;
  final String? sessionId;
  final String? cwd;
}

class AcpMemoryMiddleware {
  const AcpMemoryMiddleware({
    required this.search,
    this.extract,
    this.onDispose,
  });

  final MemorySearchCallback search;
  final MemoryExtractCallback? extract;
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

  Future<void> extractTurn(MemoryTurnContext context) async {
    try {
      await extract?.call(context);
    } catch (_) {
      // Memory extraction is best-effort and must not affect the main turn.
    }
  }

  void dispose() => onDispose?.call();
}
