import 'package:ianvs_markdown/ianvs_markdown.dart' as markdown;

import '../models/chat_input_budget.dart';

final class MarkdownRenderDecision {
  const MarkdownRenderDecision({
    required this.text,
    required this.useMarkdown,
    this.omission,
  });
  final String text;
  final bool useMarkdown;
  final ChatInputOmission? omission;
}

/// Use exactly the same grammar and budget as the body renderer. Retain chat's
/// typed omission notice so both preflight and rendering communicate the limit.
MarkdownRenderDecision scanMarkdownForRendering(
  String source, {
  required ChatInputBudget budget,
}) {
  budget.validate();
  final decision = markdown.scanMarkdownForRendering(
    source,
    syntaxPreset: markdown.IanvsMarkdownSyntaxPreset.standard,
    budget: markdown.IanvsMarkdownRenderBudget(
      maxSyntaxTokens: budget.maxMarkdownSyntaxTokens,
      maxFallbackBytes: budget.maxMarkdownFallbackBytes,
    ),
  );
  return MarkdownRenderDecision(
    text: decision.text,
    useMarkdown: decision.useMarkdown,
    omission: decision.useMarkdown
        ? null
        : ChatInputOmission(
            reason: ChatInputOmissionReason.inputLimit,
            resource: 'markdown syntax tokens',
            truncated: true,
            limit: budget.maxMarkdownSyntaxTokens,
            observedAtLeast: decision.syntaxTokens,
          ),
  );
}
