import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../../state/chat_controller.dart';
import '../theme/app_design_tokens.dart';
import 'dot_grid_background.dart';

class ChatTimeline extends StatelessWidget {
  const ChatTimeline({super.key, required this.messages});

  final List<ChatMessage> messages;

  @override
  Widget build(BuildContext context) {
    if (messages.isEmpty) {
      return const DotGridBackground(child: Center(child: _EmptyTimeline()));
    }

    return DotGridBackground(
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(32, 28, 32, 32),
        itemCount: messages.length,
        separatorBuilder: (context, index) => const SizedBox(height: 16),
        itemBuilder: (context, index) =>
            _MessageBubble(message: messages[index]),
      ),
    );
  }
}

class _EmptyTimeline extends StatelessWidget {
  const _EmptyTimeline();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxHeight < 360;
        return SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: constraints.maxHeight > 56
                  ? constraints.maxHeight - 56
                  : 0,
            ),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _CodeCardIllustration(compact: compact),
                  SizedBox(height: compact ? 18 : 26),
                  Text(
                    'Start a session to chat with Codex',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: compact ? 20 : 24,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0,
                    ),
                  ),
                  SizedBox(height: compact ? 8 : 12),
                  Text(
                    'Ask questions, get help with code, and more.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: compact ? 14 : 16,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _CodeCardIllustration extends StatelessWidget {
  const _CodeCardIllustration({required this.compact});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: compact ? 154 : 210,
      height: compact ? 112 : 164,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.borderSoft),
        boxShadow: AppShadows.raised,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Container(
            height: 28,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xffb29cff), AppColors.primary],
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
              ),
            ),
            child: Row(
              children: List.generate(
                3,
                (index) => Container(
                  width: 7,
                  height: 7,
                  margin: EdgeInsets.only(left: index == 0 ? 14 : 6),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.62),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                compact ? 14 : 20,
                compact ? 14 : 20,
                compact ? 14 : 20,
                compact ? 12 : 18,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: compact ? 36 : 48,
                    height: compact ? 36 : 48,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xffb196ff), AppColors.primary],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                    ),
                    child: const Icon(
                      Icons.code_rounded,
                      color: Colors.white,
                      size: 26,
                    ),
                  ),
                  SizedBox(width: compact ? 12 : 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _IllustrationLine(
                          widthFactor: 0.78,
                          height: compact ? 6 : 8,
                        ),
                        SizedBox(height: compact ? 8 : 14),
                        _IllustrationLine(
                          widthFactor: 1,
                          height: compact ? 6 : 8,
                        ),
                        SizedBox(height: compact ? 10 : 28),
                        _IllustrationLine(
                          widthFactor: 0.72,
                          height: compact ? 6 : 8,
                        ),
                        SizedBox(height: compact ? 6 : 12),
                        _IllustrationLine(
                          widthFactor: 0.58,
                          height: compact ? 6 : 8,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _IllustrationLine extends StatelessWidget {
  const _IllustrationLine({required this.widthFactor, required this.height});

  final double widthFactor;
  final double height;

  @override
  Widget build(BuildContext context) {
    return FractionallySizedBox(
      alignment: Alignment.centerLeft,
      widthFactor: widthFactor,
      child: Container(
        height: height,
        decoration: BoxDecoration(
          color: AppColors.primarySoft,
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final user = message.role == ChatMessageRole.user;
    final error = message.role == ChatMessageRole.error;
    final tool = message.role == ChatMessageRole.tool;
    final status = message.role == ChatMessageRole.status;
    final color = switch (message.role) {
      ChatMessageRole.user => AppColors.primary,
      ChatMessageRole.assistant => AppColors.surface,
      ChatMessageRole.tool => const Color(0xfffffbeb),
      ChatMessageRole.error => const Color(0xfffef2f2),
      ChatMessageRole.status => AppColors.surfaceRaised,
    };
    final borderColor = switch (message.role) {
      ChatMessageRole.user => AppColors.primary,
      ChatMessageRole.assistant => AppColors.border,
      ChatMessageRole.tool => const Color(0xfffde68a),
      ChatMessageRole.error => const Color(0xfffecaca),
      ChatMessageRole.status => AppColors.border,
    };
    final textColor = user ? Colors.white : AppColors.textPrimary;

    return Align(
      alignment: user ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(color: borderColor),
            boxShadow: user || error || tool || status ? null : AppShadows.soft,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _iconForRole(message.role),
                    size: 14,
                    color: user ? Colors.white : _labelColor(message.role),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _labelForRole(message.role),
                    style: TextStyle(
                      color: user ? Colors.white : _labelColor(message.role),
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                      letterSpacing: 0,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              MarkdownBody(
                data: message.text,
                selectable: true,
                styleSheet: _markdownStyle(context, textColor, user),
              ),
            ],
          ),
        ),
      ),
    );
  }

  MarkdownStyleSheet _markdownStyle(
    BuildContext context,
    Color textColor,
    bool user,
  ) {
    final baseTextStyle = TextStyle(color: textColor, height: 1.42);
    final codeBackground = user
        ? Colors.white.withValues(alpha: 0.16)
        : AppColors.surfaceRaised;
    return MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
      p: baseTextStyle,
      strong: baseTextStyle.copyWith(fontWeight: FontWeight.w700),
      em: baseTextStyle.copyWith(fontStyle: FontStyle.italic),
      code: baseTextStyle.copyWith(
        fontFamily: 'monospace',
        backgroundColor: codeBackground,
        fontSize: 13,
      ),
      listBullet: baseTextStyle,
      blockSpacing: 8,
      listIndent: 24,
      codeblockPadding: const EdgeInsets.all(10),
      codeblockDecoration: BoxDecoration(
        color: codeBackground,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(
          color: user ? Colors.white.withValues(alpha: 0.18) : AppColors.border,
        ),
      ),
    );
  }

  IconData _iconForRole(ChatMessageRole role) => switch (role) {
    ChatMessageRole.user => Icons.person_outline,
    ChatMessageRole.assistant => Icons.smart_toy_outlined,
    ChatMessageRole.tool => Icons.build_outlined,
    ChatMessageRole.error => Icons.error_outline,
    ChatMessageRole.status => Icons.info_outline,
  };

  String _labelForRole(ChatMessageRole role) => switch (role) {
    ChatMessageRole.user => 'User',
    ChatMessageRole.assistant => 'Agent',
    ChatMessageRole.tool => 'Tool',
    ChatMessageRole.error => 'Error',
    ChatMessageRole.status => 'Status',
  };

  Color _labelColor(ChatMessageRole role) => switch (role) {
    ChatMessageRole.user => Colors.white,
    ChatMessageRole.assistant => AppColors.primaryDark,
    ChatMessageRole.tool => const Color(0xff92400e),
    ChatMessageRole.error => const Color(0xffb91c1c),
    ChatMessageRole.status => AppColors.textSecondary,
  };
}
