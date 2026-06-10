typedef MemorySearchCallback = Future<String?> Function(String prompt);

class PreparedPrompt {
  const PreparedPrompt({required this.prompt, this.memoryContext, this.error});

  final String prompt;
  final String? memoryContext;
  final String? error;
}

class AcpMemoryMiddleware {
  const AcpMemoryMiddleware({required this.search});

  final MemorySearchCallback search;

  Future<PreparedPrompt> preparePrompt(String prompt) async {
    try {
      final memoryContext = await search(prompt);
      return PreparedPrompt(prompt: prompt, memoryContext: memoryContext);
    } catch (error) {
      return PreparedPrompt(prompt: prompt, error: error.toString());
    }
  }
}
