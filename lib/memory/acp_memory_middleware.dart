import 'memory_context_builder.dart';

typedef MemorySearchCallback =
    Future<String?> Function(MemoryPromptContext context);
typedef MemorySearchDetailsCallback =
    Future<MemoryPromptResult?> Function(MemoryPromptContext context);
typedef MemoryExtractCallback =
    Future<void> Function(MemoryTurnContext context);
typedef MemoryTurnCompleteCallback =
    Future<void> Function(MemoryTurnContext context);
typedef MemoryFeedbackSubmitCallback =
    Future<void> Function(MemoryFeedbackContext context);
typedef MemoryDisposeCallback = void Function();

class MemoryPromptContext {
  const MemoryPromptContext({
    required this.prompt,
    this.sessionId,
    this.cwd,
    this.turnId,
  });

  final String prompt;
  final String? sessionId;
  final String? cwd;
  final String? turnId;
}

class MemoryPromptResult {
  const MemoryPromptResult({
    this.memoryContext,
    this.usedMemories = const <MemoryUsedItem>[],
  });

  final String? memoryContext;
  final List<MemoryUsedItem> usedMemories;
}

class MemoryUsedItem {
  const MemoryUsedItem({
    required this.id,
    required this.kind,
    required this.scope,
    required this.text,
    required this.score,
    this.metadata,
  });

  final String id;
  final String kind;
  final String scope;
  final String text;
  final double score;
  final Map<String, Object?>? metadata;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'kind': kind,
    'scope': scope,
    'text': text,
    'score': score,
    if (metadata != null) 'metadata': Map<String, Object?>.from(metadata!),
  };
}

class PreparedPrompt {
  const PreparedPrompt({
    required this.prompt,
    this.memoryContext,
    this.usedMemories = const <MemoryUsedItem>[],
    this.error,
  });

  final String prompt;
  final String? memoryContext;
  final List<MemoryUsedItem> usedMemories;
  final String? error;
}

class MemoryTurnContext {
  const MemoryTurnContext({
    required this.userPrompt,
    required this.assistantAnswer,
    this.sessionId,
    this.cwd,
    this.turnId,
    this.usedMemories = const <MemoryUsedItem>[],
  });

  final String userPrompt;
  final String assistantAnswer;
  final String? sessionId;
  final String? cwd;
  final String? turnId;
  final List<MemoryUsedItem> usedMemories;
}

class MemoryFeedbackContext {
  const MemoryFeedbackContext({
    required this.memoryId,
    required this.rating,
    this.turnId,
    this.reason,
  });

  final String memoryId;
  final String rating;
  final String? turnId;
  final String? reason;
}

class AcpMemoryMiddleware {
  const AcpMemoryMiddleware({
    required this.search,
    this.searchDetails,
    this.extract,
    this.onTurnComplete,
    this.feedback,
    this.onDispose,
  });

  final MemorySearchCallback search;
  final MemorySearchDetailsCallback? searchDetails;
  final MemoryExtractCallback? extract;
  final MemoryTurnCompleteCallback? onTurnComplete;
  final MemoryFeedbackSubmitCallback? feedback;
  final MemoryDisposeCallback? onDispose;

  Future<PreparedPrompt> preparePrompt(
    String prompt, {
    String? sessionId,
    String? cwd,
    String? turnId,
  }) async {
    try {
      final context = MemoryPromptContext(
        prompt: prompt,
        sessionId: sessionId,
        cwd: cwd,
        turnId: turnId,
      );
      final details = await searchDetails?.call(context);
      if (details != null) {
        return PreparedPrompt(
          prompt: prompt,
          memoryContext: MemoryContextBuilder.withCapabilityNotice(
            details.memoryContext,
          ),
          usedMemories: details.usedMemories,
        );
      }
      final memoryContext = await search(context);
      return PreparedPrompt(
        prompt: prompt,
        memoryContext: MemoryContextBuilder.withCapabilityNotice(memoryContext),
      );
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
    try {
      await onTurnComplete?.call(context);
    } catch (_) {
      // Post-turn refresh is best-effort and must not affect the main turn.
    }
  }

  Future<void> submitFeedback({
    required String memoryId,
    required String rating,
    String? turnId,
    String? reason,
  }) async {
    await feedback?.call(
      MemoryFeedbackContext(
        memoryId: memoryId,
        rating: rating,
        turnId: turnId,
        reason: reason,
      ),
    );
  }

  void dispose() => onDispose?.call();
}
