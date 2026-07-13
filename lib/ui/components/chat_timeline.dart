import 'dart:convert';

import 'package:dart_acp/dart_acp.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

import '../../mermaid/mermaid_view.dart';
import '../../state/chat_controller.dart';
import '../bounded_metadata_preview.dart';
import '../theme/app_design_tokens.dart';
import '../markdown_render_budget.dart';
import 'dot_grid_background.dart';

const List<String> _toolCallIdMetadataKeys = [
  'toolCallId',
  'tool_call_id',
  'id',
  'callId',
  'call_id',
];
const _userMessageSelectionColor = Color(0x3d000000);
const int _maxRenderedTimelineMessages = 200;
const int _inlineCollectionPreviewItems = 5;
const int _contentBlockProjectionBatchItems = 16;
const int _contentBlockVisiblePageItems = 3;
const double _contentBlocksMaxHeight = 320;
const double _nestedDetailsMaxHeight = 280;
const double _commandDetailsMaxHeight = 320;

class ChatTimeline extends StatefulWidget {
  const ChatTimeline({
    super.key,
    required this.messages,
    this.agentName = 'Codex',
    this.hasActiveSession = false,
    this.activeSessionLabel,
    this.isLoadingSession = false,
    this.messageListRevision = 0,
    this.onNewSession,
    this.inputBudget = const AcpInputBudget(),
  });

  final List<ChatMessage> messages;
  final String agentName;
  final bool hasActiveSession;
  final String? activeSessionLabel;
  final bool isLoadingSession;
  final int messageListRevision;
  final VoidCallback? onNewSession;
  final AcpInputBudget inputBudget;

  @override
  State<ChatTimeline> createState() => _ChatTimelineState();
}

class _ChatTimelineState extends State<ChatTimeline> {
  final ScrollController _scrollController = ScrollController();
  late int _messageSignature = _timelineMessagesSignature(
    widget.messages,
    messageListRevision: widget.messageListRevision,
    isLoadingSession: widget.isLoadingSession,
  );

  @override
  void initState() {
    super.initState();
    widget.inputBudget.validate();
    if (widget.messages.isNotEmpty) {
      _scheduleScrollToBottom();
    }
  }

  @override
  void didUpdateWidget(covariant ChatTimeline oldWidget) {
    super.didUpdateWidget(oldWidget);
    widget.inputBudget.validate();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _syncMessageSignature();

    if (widget.messages.isEmpty) {
      return DotGridBackground(
        child: Center(
          child: _EmptyTimeline(
            agentName: widget.agentName,
            hasActiveSession: widget.hasActiveSession,
            activeSessionLabel: widget.activeSessionLabel,
            isLoadingSession: widget.isLoadingSession,
            onNewSession: widget.onNewSession,
          ),
        ),
      );
    }

    final visibleMessages = _visibleTimelineMessages(widget.messages);
    final skippedMessageCount = widget.messages.length - visibleMessages.length;
    final hasTrimmedHistory = skippedMessageCount > 0;
    final entries = _timelineEntries(visibleMessages);
    final historyNoticeCount = hasTrimmedHistory ? 1 : 0;
    final loadingFooterCount = widget.isLoadingSession ? 1 : 0;

    return DotGridBackground(
      child: ListView.separated(
        key: const ValueKey('chat-timeline-list'),
        controller: _scrollController,
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
        itemCount: entries.length + historyNoticeCount + loadingFooterCount,
        separatorBuilder: (context, index) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          if (hasTrimmedHistory && index == entries.length) {
            return _TrimmedHistoryNotice(
              shownCount: visibleMessages.length,
              totalCount: widget.messages.length,
            );
          }
          if (index >= entries.length + historyNoticeCount) {
            return const _SessionLoadingFooter();
          }
          final entry = entries[index];
          return entry.toolMessages == null
              ? _MessageBubble(
                  message: entry.message!,
                  inputBudget: widget.inputBudget,
                )
              : _ToolGroupBubble(
                  messages: entry.toolMessages!,
                  inputBudget: widget.inputBudget,
                );
        },
      ),
    );
  }

  void _syncMessageSignature() {
    final nextSignature = _timelineMessagesSignature(
      widget.messages,
      messageListRevision: widget.messageListRevision,
      isLoadingSession: widget.isLoadingSession,
    );
    if (nextSignature == _messageSignature) return;
    _messageSignature = nextSignature;
    if (widget.messages.isNotEmpty) {
      _scheduleScrollToBottom();
    }
  }

  void _scheduleScrollToBottom({int remainingPasses = 2}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final position = _scrollController.position;
      if (!position.hasContentDimensions) {
        _scheduleScrollToBottom(remainingPasses: remainingPasses);
        return;
      }
      final bottom = position.maxScrollExtent;
      if (bottom.isFinite && (position.pixels - bottom).abs() > 0.5) {
        _scrollController.jumpTo(bottom);
      }
      if (remainingPasses > 0) {
        _scheduleScrollToBottom(remainingPasses: remainingPasses - 1);
      }
    });
  }
}

int _timelineMessagesSignature(
  List<ChatMessage> messages, {
  required int messageListRevision,
  required bool isLoadingSession,
}) {
  final visibleMessages = _visibleTimelineMessages(messages);
  return _messagesSignature(
    visibleMessages,
    messageListRevision: messageListRevision,
    isLoadingSession: isLoadingSession,
  );
}

List<ChatMessage> _visibleTimelineMessages(List<ChatMessage> messages) {
  if (messages.length <= _maxRenderedTimelineMessages) return messages;
  return messages.sublist(messages.length - _maxRenderedTimelineMessages);
}

int _messagesSignature(
  List<ChatMessage> messages, {
  required int messageListRevision,
  required bool isLoadingSession,
}) {
  return Object.hashAll([
    messageListRevision,
    isLoadingSession,
    for (final message in messages) ...[
      identityHashCode(message),
      message.revision,
    ],
  ]);
}

List<_TimelineEntry> _timelineEntries(List<ChatMessage> messages) {
  final entries = <_TimelineEntry>[];
  var index = 0;

  while (index < messages.length) {
    final message = messages[index];
    if (message.role != ChatMessageRole.tool) {
      entries.add(_TimelineEntry.message(message));
      index += 1;
      continue;
    }

    final tools = <ChatMessage>[];
    while (index < messages.length &&
        messages[index].role == ChatMessageRole.tool) {
      tools.add(messages[index]);
      index += 1;
    }

    final coalescedTools = _coalesceToolCallChunks(tools);
    if (coalescedTools.length == 1) {
      entries.add(_TimelineEntry.message(coalescedTools.single));
    } else {
      entries.add(_TimelineEntry.toolGroup(coalescedTools));
    }
  }

  return entries;
}

List<ChatMessage> _coalesceToolCallChunks(List<ChatMessage> tools) {
  final coalesced = <ChatMessage>[];
  final indexByCallId = <String, int>{};

  for (final tool in tools) {
    final callId = _toolCallIdMetadata(tool.metadata);
    if (callId == null) {
      coalesced.add(tool);
      continue;
    }

    final existingIndex = indexByCallId[callId];
    if (existingIndex == null) {
      indexByCallId[callId] = coalesced.length;
      coalesced.add(tool);
      continue;
    }

    final existing = coalesced[existingIndex];
    coalesced[existingIndex] = ChatMessage(
      role: ChatMessageRole.tool,
      text: tool.text.trim().isEmpty ? existing.text : tool.text,
      timestamp: existing.timestamp,
      metadata: _mergeToolMetadata(existing.metadata, tool.metadata),
    );
  }

  return coalesced;
}

Map<String, Object?> _mergeToolMetadata(
  Map<String, Object?> existing,
  Map<String, Object?> update,
) {
  final merged = Map<String, Object?>.from(existing);
  for (final entry in update.entries) {
    if (entry.value == null) continue;
    merged[entry.key] = entry.value;
  }
  return Map.unmodifiable(merged);
}

class _TimelineEntry {
  const _TimelineEntry.message(this.message) : toolMessages = null;

  const _TimelineEntry.toolGroup(this.toolMessages) : message = null;

  final ChatMessage? message;
  final List<ChatMessage>? toolMessages;
}

class _EmptyTimeline extends StatelessWidget {
  const _EmptyTimeline({
    required this.agentName,
    required this.hasActiveSession,
    this.activeSessionLabel,
    required this.isLoadingSession,
    this.onNewSession,
  });

  final String agentName;
  final bool hasActiveSession;
  final String? activeSessionLabel;
  final bool isLoadingSession;
  final VoidCallback? onNewSession;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxHeight < 360;
        return SingleChildScrollView(
          padding: const EdgeInsets.all(18),
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
                  isLoadingSession
                      ? SizedBox(
                          width: compact ? 34 : 40,
                          height: compact ? 34 : 40,
                          child: const CircularProgressIndicator(
                            strokeWidth: 2.4,
                            color: AppColors.primary,
                          ),
                        )
                      : _CodeCardIllustration(compact: compact),
                  SizedBox(height: compact ? 12 : 14),
                  Text(
                    isLoadingSession
                        ? 'Loading session'
                        : hasActiveSession
                        ? 'Session ready'
                        : 'Start a session to chat with $agentName',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: compact ? 17 : 19,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0,
                    ),
                  ),
                  SizedBox(height: compact ? 5 : 6),
                  Text(
                    isLoadingSession
                        ? _loadingSessionSubtitle()
                        : hasActiveSession
                        ? _activeSessionSubtitle()
                        : 'Ask questions, get help with code, and more.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: compact ? 12 : 13,
                      height: 1.4,
                    ),
                  ),
                  if (!hasActiveSession && onNewSession != null) ...[
                    SizedBox(height: compact ? 12 : 16),
                    FilledButton.icon(
                      onPressed: onNewSession,
                      icon: const Icon(Icons.add_rounded, size: 18),
                      label: const Text('New Session'),
                      style: FilledButton.styleFrom(
                        foregroundColor: AppColors.primaryDark,
                        backgroundColor: AppColors.primarySoft,
                        elevation: 0,
                        minimumSize: Size(154, compact ? 36 : 40),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(AppRadius.pill),
                        ),
                        textStyle: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  String _activeSessionSubtitle() {
    final label = activeSessionLabel?.trim();
    final prefix = label == null || label.isEmpty ? '' : '$label loaded. ';
    return '${prefix}No replayed messages were returned; continue below.';
  }

  String _loadingSessionSubtitle() {
    final label = activeSessionLabel?.trim();
    if (label == null || label.isEmpty) {
      return 'Loading conversation history. Large sessions can take a moment.';
    }
    return 'Loading $label. Large sessions can take a moment.';
  }
}

class _SessionLoadingFooter extends StatelessWidget {
  const _SessionLoadingFooter();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: const [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppColors.primary,
              ),
            ),
            SizedBox(width: 8),
            Text(
              'Loading session history',
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TrimmedHistoryNotice extends StatelessWidget {
  const _TrimmedHistoryNotice({
    required this.shownCount,
    required this.totalCount,
  });

  final int shownCount;
  final int totalCount;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
        decoration: BoxDecoration(
          color: AppColors.surfaceMuted,
          borderRadius: BorderRadius.circular(AppRadius.pill),
          border: Border.all(color: AppColors.borderSoft),
        ),
        child: Text(
          'Showing latest $shownCount of $totalCount messages',
          style: const TextStyle(
            color: AppColors.textSecondary,
            fontSize: 12,
            fontWeight: FontWeight.w700,
            letterSpacing: 0,
          ),
        ),
      ),
    );
  }
}

class _CodeCardIllustration extends StatelessWidget {
  const _CodeCardIllustration({required this.compact});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: compact ? 120 : 152,
      height: compact ? 82 : 108,
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
            height: 19,
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
                  width: 4,
                  height: 4,
                  margin: EdgeInsets.only(left: index == 0 ? 10 : 4),
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
                compact ? 10 : 13,
                compact ? 10 : 13,
                compact ? 10 : 13,
                compact ? 8 : 11,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: compact ? 26 : 32,
                    height: compact ? 26 : 32,
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
                      size: 18,
                    ),
                  ),
                  SizedBox(width: compact ? 8 : 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _IllustrationLine(
                          widthFactor: 0.78,
                          height: compact ? 4 : 5,
                        ),
                        SizedBox(height: compact ? 6 : 8),
                        _IllustrationLine(
                          widthFactor: 1,
                          height: compact ? 4 : 5,
                        ),
                        SizedBox(height: compact ? 7 : 12),
                        _IllustrationLine(
                          widthFactor: 0.72,
                          height: compact ? 4 : 5,
                        ),
                        SizedBox(height: compact ? 4 : 6),
                        _IllustrationLine(
                          widthFactor: 0.58,
                          height: compact ? 4 : 5,
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
  const _MessageBubble({required this.message, required this.inputBudget});

  final ChatMessage message;
  final AcpInputBudget inputBudget;

  @override
  Widget build(BuildContext context) {
    if (message.role == ChatMessageRole.tool) {
      return _ToolBubble(message: message, inputBudget: inputBudget);
    }
    if (message.role == ChatMessageRole.status &&
        _stringMetadata(message.metadata, 'kind') != null &&
        _stringMetadata(message.metadata, 'kind') != 'unknown') {
      return _StatusBubble(
        message: message,
        inputBudget: inputBudget,
        previewRevision: message.revision,
      );
    }

    final user = message.role == ChatMessageRole.user;
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
    final markdownDecision = message.text.isEmpty
        ? null
        : scanMarkdownForRendering(message.text, budget: inputBudget);
    final omissions = _distinctOmissions(
      message.omissions,
      markdownDecision?.omission,
    );

    return Align(
      alignment: user ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: user ? 720 : 820),
        child: Container(
          width: user ? null : double.infinity,
          padding: const EdgeInsets.all(11),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(AppRadius.sm),
            border: Border.all(color: borderColor),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 6,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Icon(
                    _iconForRole(message.role),
                    size: 14,
                    color: user ? Colors.white : _labelColor(message.role),
                  ),
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
              if (markdownDecision != null) ...[
                const SizedBox(height: 6),
                if (markdownDecision.useMarkdown)
                  _SelectableMessageMarkdown(
                    data: markdownDecision.text,
                    user: user,
                    styleSheet: _markdownStyle(context, textColor, user),
                  )
                else
                  SelectableText(
                    markdownDecision.text,
                    style: TextStyle(color: textColor, height: 1.42),
                  ),
              ],
              for (final omission in omissions)
                _InputOmissionNotice(omission: omission, user: user),
              _ContentBlocksPreview(
                message: message,
                inputBudget: inputBudget,
                previewRevision: message.revision,
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
      codeblockPadding: const EdgeInsets.all(7),
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

List<AcpInputOmission> _distinctOmissions(
  List<AcpInputOmission> existing,
  AcpInputOmission? additional,
) {
  final result = <AcpInputOmission>[];
  final keys = <String>{};
  for (final omission in <AcpInputOmission>[...existing, ?additional]) {
    if (keys.add('${omission.reason.name}:${omission.resource}')) {
      result.add(omission);
    }
  }
  return result;
}

class _InputOmissionNotice extends StatelessWidget {
  const _InputOmissionNotice({required this.omission, required this.user});

  final AcpInputOmission omission;
  final bool user;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text(
        'Content omitted · ${omission.resource}',
        style: TextStyle(
          color: user ? Colors.white70 : AppColors.warning,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _SelectableMessageMarkdown extends StatelessWidget {
  const _SelectableMessageMarkdown({
    required this.data,
    required this.user,
    required this.styleSheet,
  });

  final String data;
  final bool user;
  final MarkdownStyleSheet styleSheet;

  @override
  Widget build(BuildContext context) {
    final markdown = MarkdownBody(
      data: data,
      selectable: true,
      styleSheet: styleSheet,
      imageBuilder: _blockedMarkdownImage,
      builders: <String, MarkdownElementBuilder>{
        'pre': _MermaidCodeBlockBuilder(user: user),
      },
    );

    if (!user) return markdown;

    return TextSelectionTheme(
      data: TextSelectionTheme.of(context).copyWith(
        cursorColor: Colors.white,
        selectionColor: _userMessageSelectionColor,
        selectionHandleColor: Colors.white,
      ),
      child: DefaultSelectionStyle(
        cursorColor: Colors.white,
        selectionColor: _userMessageSelectionColor,
        child: markdown,
      ),
    );
  }
}

Widget _blockedMarkdownImage(Uri uri, String? title, String? alt) {
  final scheme = uri.scheme.trim().toLowerCase();
  final source = switch (scheme) {
    'http' || 'https' when uri.host.trim().isNotEmpty => uri.host.toLowerCase(),
    '' => 'unknown',
    _ => scheme,
  };
  final altText = alt?.trim();
  return ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 320),
    child: Container(
      padding: const EdgeInsets.only(left: 8, top: 3, bottom: 3),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              [
                'Image blocked · $source',
                if (altText != null && altText.isNotEmpty) altText,
              ].join(' — '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Copy blocked image link',
            visualDensity: VisualDensity.compact,
            iconSize: 16,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: uri.toString()));
            },
            icon: const Icon(Icons.content_copy_rounded),
          ),
        ],
      ),
    ),
  );
}

class _MermaidCodeBlockBuilder extends MarkdownElementBuilder {
  _MermaidCodeBlockBuilder({required this.user});

  final bool user;

  @override
  bool isBlockElement() => true;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final code = _codeChild(element);
    if (code == null || !_isMermaidCode(code)) return null;

    final source = code.textContent.trimRight();
    if (source.trim().isEmpty) return null;

    final background = user ? Colors.white : AppColors.surface;
    return Padding(
      padding: const EdgeInsets.all(7),
      child: ClipRect(
        child: ColoredBox(
          color: background,
          child: SizedBox(
            width: double.infinity,
            height: 280,
            child: MermaidView(
              source: source,
              semanticsLabel: 'Mermaid diagram',
              loadingBuilder: (_) => const Center(
                child: SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
              errorBuilder: (context, error) {
                final theme = Theme.of(context);
                return Padding(
                  padding: const EdgeInsets.all(10),
                  child: SelectableText(
                    'Mermaid render failed:\n$error',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  md.Element? _codeChild(md.Element element) {
    for (final child in element.children ?? const <md.Node>[]) {
      if (child is md.Element && child.tag == 'code') {
        return child;
      }
    }
    return null;
  }

  bool _isMermaidCode(md.Element code) {
    final className = code.attributes['class'] ?? '';
    return className
        .split(RegExp(r'\s+'))
        .any((part) => part == 'language-mermaid' || part == 'mermaid');
  }
}

class _ToolBubble extends StatelessWidget {
  const _ToolBubble({required this.message, required this.inputBudget});

  final ChatMessage message;
  final AcpInputBudget inputBudget;

  @override
  Widget build(BuildContext context) {
    final parsed = _ParsedTool.fromMessage(message);
    return _ToolFrame(
      child: _ToolCallCard(parsed: parsed, inputBudget: inputBudget),
    );
  }
}

class _ToolGroupBubble extends StatelessWidget {
  const _ToolGroupBubble({required this.messages, required this.inputBudget});

  final List<ChatMessage> messages;
  final AcpInputBudget inputBudget;

  @override
  Widget build(BuildContext context) {
    final parsedTools = messages.map(_ParsedTool.fromMessage).toList();
    final counts = <String, int>{};
    for (final parsed in parsedTools) {
      counts.update(parsed.title, (value) => value + 1, ifAbsent: () => 1);
    }
    final statusSummary = _ToolGroupStatusSummary.from(parsedTools);

    return _ToolFrame(
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: Material(
          color: Colors.transparent,
          child: ExpansionTile(
            tilePadding: const EdgeInsets.fromLTRB(10, 2, 10, 2),
            childrenPadding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
            initiallyExpanded: false,
            maintainState: true,
            leading: const Icon(
              Icons.account_tree_outlined,
              color: Color(0xff92400e),
              size: 18,
            ),
            title: _ToolGroupHeader(
              totalCount: messages.length,
              statusSummary: statusSummary,
              counts: counts,
            ),
            children: [
              const Divider(height: 12, color: Color(0xfffde68a)),
              for (var index = 0; index < parsedTools.length; index++) ...[
                _ToolSequenceCard(
                  index: index + 1,
                  parsed: parsedTools[index],
                  inputBudget: inputBudget,
                ),
                if (index != parsedTools.length - 1) const SizedBox(height: 6),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ToolFrame extends StatelessWidget {
  const _ToolFrame({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 820),
        child: child,
      ),
    );
  }
}

class _ToolCallCard extends StatefulWidget {
  const _ToolCallCard({required this.parsed, required this.inputBudget});

  final _ParsedTool parsed;
  final AcpInputBudget inputBudget;

  @override
  State<_ToolCallCard> createState() => _ToolCallCardState();
}

class _ToolCallCardState extends State<_ToolCallCard> {
  var _expanded = false;

  @override
  Widget build(BuildContext context) {
    final parsed = widget.parsed;
    final hasDetails =
        parsed.id.isNotEmpty ||
        parsed.kind.isNotEmpty ||
        parsed.locations.isNotEmpty ||
        _hasMetadataDetail(parsed.content) ||
        _hasMetadataDetail(parsed.input) ||
        _hasMetadataDetail(parsed.output);
    final details = !_expanded
        ? const <Widget>[]
        : <Widget>[
            if (parsed.id.isNotEmpty)
              _DetailBlock(entry: _DetailEntry('Call ID', parsed.id)),
            if (parsed.kind.isNotEmpty)
              _DetailBlock(entry: _DetailEntry('Kind', parsed.kind)),
            if (parsed.locations.isNotEmpty)
              _DetailBlock(
                entry: _DetailEntry('Locations', parsed.locations.join('\n')),
              ),
            if (_hasMetadataDetail(parsed.content))
              _BoundedMetadataDetail(
                key: const ValueKey('tool-content-preview'),
                label: 'Content',
                payload: parsed.content,
                inputBudget: widget.inputBudget,
                previewRevision: parsed.previewRevision,
              ),
            if (_hasMetadataDetail(parsed.input))
              _BoundedMetadataDetail(
                key: const ValueKey('tool-input-preview'),
                label: 'Input',
                payload: parsed.input,
                inputBudget: widget.inputBudget,
                previewRevision: parsed.previewRevision,
              ),
            if (_hasMetadataDetail(parsed.output))
              _BoundedMetadataDetail(
                key: const ValueKey('tool-output-preview'),
                label: 'Output',
                payload: parsed.output,
                inputBudget: widget.inputBudget,
                previewRevision: parsed.previewRevision,
              ),
          ];

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xfffffbeb),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: const Color(0xfffde68a)),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: !hasDetails
            ? Padding(
                padding: const EdgeInsets.all(10),
                child: _ToolHeader(parsed: parsed),
              )
            : Material(
                color: Colors.transparent,
                child: ExpansionTile(
                  tilePadding: const EdgeInsets.fromLTRB(10, 0, 10, 0),
                  childrenPadding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                  initiallyExpanded: false,
                  maintainState: true,
                  onExpansionChanged: (expanded) {
                    if (_expanded == expanded) return;
                    setState(() => _expanded = expanded);
                  },
                  leading: const Icon(
                    Icons.build_circle_outlined,
                    color: Color(0xff92400e),
                    size: 18,
                  ),
                  title: _ToolHeader(parsed: parsed, compact: true),
                  children: _expanded
                      ? [
                          for (final detail in details) ...[
                            detail,
                            if (detail != details.last)
                              const SizedBox(height: 6),
                          ],
                        ]
                      : const <Widget>[],
                ),
              ),
      ),
    );
  }
}

class _ToolSequenceCard extends StatelessWidget {
  const _ToolSequenceCard({
    required this.index,
    required this.parsed,
    required this.inputBudget,
  });

  final int index;
  final _ParsedTool parsed;
  final AcpInputBudget inputBudget;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 14),
          child: _ToolCallCard(parsed: parsed, inputBudget: inputBudget),
        ),
        Positioned(
          left: 0,
          top: 18,
          child: Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              border: Border.all(color: const Color(0xfffde68a)),
            ),
            child: Text(
              '$index',
              style: const TextStyle(
                color: Color(0xff92400e),
                fontSize: 10,
                fontWeight: FontWeight.w900,
                letterSpacing: 0,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ToolGroupHeader extends StatelessWidget {
  const _ToolGroupHeader({
    required this.totalCount,
    required this.statusSummary,
    required this.counts,
  });

  final int totalCount;
  final _ToolGroupStatusSummary statusSummary;
  final Map<String, int> counts;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '$totalCount tool calls',
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0,
                ),
              ),
            ),
            _StatusPill(label: statusSummary.label, color: statusSummary.color),
          ],
        ),
        const SizedBox(height: 5),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final entry in counts.entries)
              _ToolCountChip(label: entry.key, count: entry.value),
          ],
        ),
      ],
    );
  }
}

enum _ToolGroupStatusKind { pending, inProgress, completed, failed, cancelled }

class _ToolGroupStatusSummary {
  const _ToolGroupStatusSummary({required this.label, required this.color});

  final String label;
  final Color color;

  factory _ToolGroupStatusSummary.from(List<_ParsedTool> tools) {
    var pendingCount = 0;
    var inProgressCount = 0;
    var failedCount = 0;
    var cancelledCount = 0;

    for (final tool in tools) {
      switch (_toolGroupStatusKind(tool.status)) {
        case _ToolGroupStatusKind.pending:
          pendingCount += 1;
        case _ToolGroupStatusKind.inProgress:
          inProgressCount += 1;
        case _ToolGroupStatusKind.failed:
          failedCount += 1;
        case _ToolGroupStatusKind.cancelled:
          cancelledCount += 1;
        case _ToolGroupStatusKind.completed:
          break;
      }
    }

    if (pendingCount > 0) {
      return _ToolGroupStatusSummary(
        label: '$pendingCount pending',
        color: AppColors.warning,
      );
    }
    if (inProgressCount > 0) {
      return _ToolGroupStatusSummary(
        label: '$inProgressCount in progress',
        color: AppColors.primaryDark,
      );
    }
    if (failedCount > 0) {
      return _ToolGroupStatusSummary(
        label: '$failedCount failed',
        color: AppColors.danger,
      );
    }
    if (cancelledCount > 0) {
      return _ToolGroupStatusSummary(
        label: '$cancelledCount cancelled',
        color: AppColors.textSecondary,
      );
    }
    return const _ToolGroupStatusSummary(
      label: 'completed',
      color: AppColors.success,
    );
  }
}

_ToolGroupStatusKind _toolGroupStatusKind(String status) {
  final normalized = _normalizedStatusToken(status);
  return switch (normalized) {
    'completed' || 'applied' => _ToolGroupStatusKind.completed,
    'in_progress' ||
    'progress' ||
    'running' ||
    'started' => _ToolGroupStatusKind.inProgress,
    'failed' || 'error' || 'rejected' => _ToolGroupStatusKind.failed,
    'cancelled' || 'canceled' => _ToolGroupStatusKind.cancelled,
    _ => _ToolGroupStatusKind.pending,
  };
}

class _ToolCountChip extends StatelessWidget {
  const _ToolCountChip({required this.label, required this.count});

  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 260),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: const Color(0xfffde68a)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 0,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            'x$count',
            style: const TextStyle(
              color: Color(0xff92400e),
              fontSize: 11,
              fontWeight: FontWeight.w900,
              letterSpacing: 0,
            ),
          ),
        ],
      ),
    );
  }
}

class _ToolHeader extends StatelessWidget {
  const _ToolHeader({required this.parsed, this.compact = false});

  final _ParsedTool parsed;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (!compact) ...[
          const Icon(
            Icons.build_circle_outlined,
            color: Color(0xff92400e),
            size: 20,
          ),
          const SizedBox(width: 7),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Tool',
                style: TextStyle(
                  color: Color(0xff92400e),
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0,
                ),
              ),
              const SizedBox(height: 1),
              Text(
                parsed.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        _StatusPill(label: parsed.status, color: _statusColor(parsed.status)),
      ],
    );
  }
}

class _StatusBubble extends StatelessWidget {
  const _StatusBubble({
    required this.message,
    required this.inputBudget,
    required this.previewRevision,
  });

  final ChatMessage message;
  final AcpInputBudget inputBudget;
  final Object previewRevision;

  @override
  Widget build(BuildContext context) {
    final kind = _stringMetadata(message.metadata, 'kind') ?? 'status';
    final child = switch (kind) {
      'plan' => _PlanStatus(message: message),
      'diff' => _DiffStatus(message: message),
      'commands' => _CommandsStatus(
        message: message,
        inputBudget: inputBudget,
        previewRevision: previewRevision,
      ),
      'terminal' => _TerminalStatus(
        message: message,
        inputBudget: inputBudget,
        previewRevision: previewRevision,
      ),
      'mode' => _ModeStatus(message: message),
      'thought' => _ThoughtStatus(
        message: message,
        inputBudget: inputBudget,
        previewRevision: previewRevision,
      ),
      'turn' => _TurnStatus(message: message),
      _ => _PlainStatus(message: message),
    };

    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 820),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.surfaceRaised,
            borderRadius: BorderRadius.circular(AppRadius.sm),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              child,
              for (final omission in message.omissions)
                _InputOmissionNotice(omission: omission, user: false),
            ],
          ),
        ),
      ),
    );
  }
}

class _ThoughtStatus extends StatelessWidget {
  const _ThoughtStatus({
    required this.message,
    required this.inputBudget,
    required this.previewRevision,
  });

  final ChatMessage message;
  final AcpInputBudget inputBudget;
  final Object previewRevision;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader(
          icon: Icons.psychology_alt_outlined,
          label: 'Thought',
        ),
        if (message.text.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            message.text,
            style: const TextStyle(
              color: AppColors.textSecondary,
              height: 1.35,
            ),
          ),
        ],
        _ContentBlocksPreview(
          message: message,
          inputBudget: inputBudget,
          previewRevision: previewRevision,
        ),
      ],
    );
  }
}

class _TurnStatus extends StatelessWidget {
  const _TurnStatus({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final stopReason = _stringMetadata(message.metadata, 'stopReason') ?? '';
    return Row(
      children: [
        Expanded(
          child: _SectionHeader(
            icon: Icons.flag_circle_outlined,
            label: message.text.isEmpty ? 'Turn ended' : message.text,
          ),
        ),
        if (stopReason.isNotEmpty)
          _StatusPill(
            label: _wireStopReason(stopReason),
            color: _stopReasonColor(stopReason),
          ),
      ],
    );
  }
}

class _ContentBlocksPreview extends StatefulWidget {
  const _ContentBlocksPreview({
    required this.message,
    required this.inputBudget,
    required this.previewRevision,
  });

  final ChatMessage message;
  final AcpInputBudget inputBudget;
  final Object previewRevision;

  @override
  State<_ContentBlocksPreview> createState() => _ContentBlocksPreviewState();
}

class _ContentBlocksPreviewState extends State<_ContentBlocksPreview> {
  late _LazyNonTextBlockProjection _projection = _LazyNonTextBlockProjection(
    _rawBlocks,
  );
  var _projectionGeneration = 0;
  var _projectionScanScheduled = false;
  var _visibleTarget = _contentBlockVisiblePageItems;
  var _loadingMore = false;

  Object? get _rawBlocks => widget.message.metadata['contentBlocks'];

  @override
  void didUpdateWidget(covariant _ContentBlocksPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldRawBlocks = oldWidget.message.metadata['contentBlocks'];
    if (!identical(_rawBlocks, oldRawBlocks) ||
        widget.previewRevision != oldWidget.previewRevision) {
      _projection = _LazyNonTextBlockProjection(_rawBlocks);
      _projectionGeneration += 1;
      _projectionScanScheduled = false;
      _visibleTarget = _contentBlockVisiblePageItems;
      _loadingMore = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_projection.rawCount == 0) return const SizedBox.shrink();
    final needsMoreVisibleItems =
        !_projection.exhausted && _projection.visibleCount < _visibleTarget;
    if (needsMoreVisibleItems) _scheduleProjectionScan();
    if (_projection.visibleCount == 0) {
      if (_projection.exhausted) return const SizedBox.shrink();
      return Padding(
        padding: EdgeInsets.only(top: widget.message.text.isEmpty ? 0 : 8),
        child: const _ContentProjectionPendingNotice(),
      );
    }
    final hasPendingItems = !_projection.exhausted;
    final renderedItemCount =
        _projection.visibleCount + (hasPendingItems ? 1 : 0);

    return Padding(
      padding: EdgeInsets.only(top: widget.message.text.isEmpty ? 0 : 8),
      child: SizedBox(
        height: _boundedNestedListHeight(
          itemCount: renderedItemCount,
          estimatedItemHeight: 110,
          maxHeight: _contentBlocksMaxHeight,
        ),
        child: ListView.builder(
          key: const ValueKey('content-blocks-list'),
          primary: false,
          itemCount: renderedItemCount,
          itemBuilder: (context, index) {
            if (index >= _projection.visibleCount) {
              return needsMoreVisibleItems
                  ? _ContentProjectionPendingRow(
                      label: _loadingMore
                          ? 'Loading more content…'
                          : 'Preparing content preview…',
                    )
                  : _ContentProjectionLoadMoreRow(onPressed: _loadMore);
            }
            final block = _projection.blockAt(index);
            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: _ContentBlockCard(
                block: block,
                inputBudget: widget.inputBudget,
                previewRevision: widget.previewRevision,
              ),
            );
          },
        ),
      ),
    );
  }

  void _scheduleProjectionScan() {
    if (_projection.exhausted || _projectionScanScheduled) return;
    _projectionScanScheduled = true;
    final generation = _projectionGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _projectionGeneration) return;
      _projectionScanScheduled = false;
      _projection.scanNextBatch(
        _contentBlockProjectionBatchItems,
        visibleTarget: _visibleTarget,
      );
      if (_projection.exhausted || _projection.visibleCount >= _visibleTarget) {
        _loadingMore = false;
      }
      setState(() {});
    });
  }

  void _loadMore() {
    if (_projection.exhausted || _loadingMore) return;
    setState(() {
      _visibleTarget += _contentBlockVisiblePageItems;
      _loadingMore = true;
    });
  }
}

class _ContentProjectionPendingNotice extends StatelessWidget {
  const _ContentProjectionPendingNotice();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      height: 42,
      child: Row(
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: 8),
          Text(
            'Preparing content preview…',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _ContentProjectionPendingRow extends StatelessWidget {
  const _ContentProjectionPendingRow({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 42,
      child: Row(
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _ContentProjectionLoadMoreRow extends StatelessWidget {
  const _ContentProjectionLoadMoreRow({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 42,
      child: Align(
        alignment: Alignment.centerLeft,
        child: TextButton(
          onPressed: onPressed,
          child: const Text('Load more content'),
        ),
      ),
    );
  }
}

final class _LazyNonTextBlockProjection {
  _LazyNonTextBlockProjection(this._rawBlocks)
    : rawCount = _lazyMapCount(_rawBlocks);

  final Object? _rawBlocks;
  final int rawCount;
  final List<Map<String, Object?>> _visibleBlocks = <Map<String, Object?>>[];
  var _nextRawIndex = 0;

  bool get exhausted => _nextRawIndex >= rawCount;
  int get visibleCount => _visibleBlocks.length;

  Map<String, Object?> blockAt(int visibleIndex) =>
      _visibleBlocks[visibleIndex];

  void scanNextBatch(int maxItems, {required int visibleTarget}) {
    var scanned = 0;
    while (!exhausted && scanned < maxItems && visibleCount < visibleTarget) {
      final block = _lazyMapAt(_rawBlocks, _nextRawIndex);
      _nextRawIndex += 1;
      scanned += 1;
      if (block == null || _stringMetadata(block, 'type') == 'text') {
        continue;
      }
      _visibleBlocks.add(block);
    }
  }
}

class _ContentBlockCard extends StatelessWidget {
  const _ContentBlockCard({
    required this.block,
    required this.inputBudget,
    required this.previewRevision,
  });

  final Map<String, Object?> block;
  final AcpInputBudget inputBudget;
  final Object previewRevision;

  @override
  Widget build(BuildContext context) {
    final type = _stringMetadata(block, 'type') ?? 'unknown';
    return switch (type) {
      'image' => _ImageContentBlock(block: block),
      'audio' => _AudioContentBlock(block: block),
      'resource_link' || 'resource' => _ResourceContentBlock(
        block: block,
        inputBudget: inputBudget,
        previewRevision: previewRevision,
      ),
      _ => _UnknownContentBlock(
        block: block,
        inputBudget: inputBudget,
        previewRevision: previewRevision,
      ),
    };
  }
}

class _ImageContentBlock extends StatelessWidget {
  const _ImageContentBlock({required this.block});

  final Map<String, Object?> block;

  @override
  Widget build(BuildContext context) {
    final mimeType = _stringMetadata(block, 'mimeType') ?? 'image';
    final data = _stringMetadata(block, 'data');
    final bytes = data == null ? null : _tryDecodeBase64(data);
    return _InlineContentFrame(
      icon: Icons.image_outlined,
      title: 'Image',
      subtitle: '$mimeType${data == null ? '' : ' · ${data.length} chars'}',
      child: bytes == null
          ? null
          : ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.sm),
              child: Image.memory(
                bytes,
                height: 132,
                fit: BoxFit.contain,
                errorBuilder: (context, error, stackTrace) {
                  return const Text(
                    'Image preview unavailable.',
                    style: TextStyle(color: AppColors.textSecondary),
                  );
                },
              ),
            ),
    );
  }
}

class _ResourceContentBlock extends StatelessWidget {
  const _ResourceContentBlock({
    required this.block,
    required this.inputBudget,
    required this.previewRevision,
  });

  final Map<String, Object?> block;
  final AcpInputBudget inputBudget;
  final Object previewRevision;

  @override
  Widget build(BuildContext context) {
    final resource = _mapMetadata(block['resource']);
    final payload = resource.isEmpty ? block : resource;
    final uri =
        _stringMetadata(block, 'uri') ?? _stringMetadata(payload, 'uri') ?? '';
    final title =
        _stringMetadata(block, 'title') ??
        _stringMetadata(block, 'name') ??
        _stringMetadata(payload, 'title') ??
        _stringMetadata(payload, 'name') ??
        _resourceTitleFromUri(uri) ??
        'Resource';
    final mimeType =
        _stringMetadata(block, 'mimeType') ??
        _stringMetadata(payload, 'mimeType');
    final size =
        _numberMetadata(block, 'size') ?? _numberMetadata(payload, 'size');
    final text = _stringMetadata(payload, 'text');
    final blob = _stringMetadata(payload, 'blob');
    final details = [
      ?mimeType,
      if (size != null) _formatByteCount(size),
      if (text != null) 'text',
      if (blob != null) 'blob ${blob.length} chars',
    ];
    return _InlineContentFrame(
      icon: Icons.link_rounded,
      title: title,
      subtitle: details.isEmpty ? 'resource' : details.join(' · '),
      child: uri.isEmpty && text == null
          ? null
          : _ResourceContentDetails(
              uri: uri,
              text: text,
              inputBudget: inputBudget,
              previewRevision: previewRevision,
            ),
    );
  }
}

class _AudioContentBlock extends StatelessWidget {
  const _AudioContentBlock({required this.block});

  final Map<String, Object?> block;

  @override
  Widget build(BuildContext context) {
    final mimeType = _stringMetadata(block, 'mimeType') ?? 'audio';
    final data = _stringMetadata(block, 'data');
    final uri = _stringMetadata(block, 'uri');
    final details = [
      mimeType,
      if (data != null) '${data.length} chars',
      if (uri != null) 'linked',
    ];
    return _InlineContentFrame(
      icon: Icons.graphic_eq_rounded,
      title: 'Audio',
      subtitle: details.join(' · '),
      child: uri == null
          ? null
          : SelectableText(
              uri,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
                height: 1.35,
              ),
            ),
    );
  }
}

class _ResourceContentDetails extends StatelessWidget {
  const _ResourceContentDetails({
    required this.uri,
    required this.text,
    required this.inputBudget,
    required this.previewRevision,
  });

  final String uri;
  final String? text;
  final AcpInputBudget inputBudget;
  final Object previewRevision;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (uri.isNotEmpty)
          SelectableText(
            uri,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12,
              height: 1.35,
            ),
          ),
        if (text != null) ...[
          if (uri.isNotEmpty) const SizedBox(height: 8),
          _BoundedMetadataDetail(
            label: 'Text',
            payload: text,
            inputBudget: inputBudget,
            previewRevision: previewRevision,
          ),
        ],
      ],
    );
  }
}

class _UnknownContentBlock extends StatelessWidget {
  const _UnknownContentBlock({
    required this.block,
    required this.inputBudget,
    required this.previewRevision,
  });

  final Map<String, Object?> block;
  final AcpInputBudget inputBudget;
  final Object previewRevision;

  @override
  Widget build(BuildContext context) {
    return _InlineContentFrame(
      icon: Icons.extension_outlined,
      title: _stringMetadata(block, 'type') ?? 'Unknown content',
      subtitle: 'raw content block',
      child: _BoundedMetadataDetail(
        label: 'Content',
        payload: block,
        inputBudget: inputBudget,
        previewRevision: previewRevision,
      ),
    );
  }
}

class _InlineContentFrame extends StatelessWidget {
  const _InlineContentFrame({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.child,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.surfaceRaised,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: AppColors.primaryDark, size: 15),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  title,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0,
                  ),
                ),
              ),
              const SizedBox(width: 7),
              Text(
                subtitle,
                style: const TextStyle(
                  color: AppColors.textTertiary,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          if (child != null) ...[const SizedBox(height: 8), child!],
        ],
      ),
    );
  }
}

class _PlanStatus extends StatelessWidget {
  const _PlanStatus({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final title = _stringMetadata(message.metadata, 'title') ?? message.text;
    final description = _stringMetadata(message.metadata, 'description');
    final rawEntries = message.metadata['entries'];
    final entryCount = _lazyMapCount(rawEntries);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(icon: Icons.checklist_rounded, label: title),
        if (description != null) ...[
          const SizedBox(height: 6),
          Text(
            description,
            style: const TextStyle(
              color: AppColors.textSecondary,
              height: 1.35,
            ),
          ),
        ],
        if (entryCount > 0) ...[
          const SizedBox(height: 10),
          SizedBox(
            height: _boundedNestedListHeight(
              itemCount: entryCount,
              estimatedItemHeight: 54,
              maxHeight: _nestedDetailsMaxHeight,
            ),
            child: ListView.separated(
              key: const ValueKey('plan-entries-list'),
              primary: false,
              itemCount: entryCount,
              separatorBuilder: (context, index) => const SizedBox(height: 2),
              itemBuilder: (context, index) {
                final entry = _lazyMapAt(rawEntries, index);
                return entry == null
                    ? const SizedBox.shrink()
                    : _PlanEntryRow(entry: entry);
              },
            ),
          ),
        ],
        if (message.metadata['truncated'] == true) ...[
          const SizedBox(height: 6),
          const _DetailsIncompleteNotice(),
        ],
      ],
    );
  }
}

class _PlanEntryRow extends StatelessWidget {
  const _PlanEntryRow({required this.entry});

  final Map<String, Object?> entry;

  @override
  Widget build(BuildContext context) {
    final status = _stringMetadata(entry, 'status') ?? 'pending';
    final priority = _stringMetadata(entry, 'priority') ?? 'medium';
    final content = _stringMetadata(entry, 'content') ?? '';
    final color = _statusColor(status);
    final icon = switch (_normalizedStatusToken(status)) {
      'completed' => Icons.check_circle_rounded,
      'in_progress' => Icons.play_circle_outline_rounded,
      'failed' || 'error' || 'rejected' => Icons.error_outline_rounded,
      'cancelled' || 'canceled' => Icons.cancel_outlined,
      _ => Icons.radio_button_unchecked_rounded,
    };

    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 220;
        final contentRow = Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 16),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                content,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  height: 1.35,
                ),
              ),
            ),
          ],
        );

        if (narrow) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                contentRow,
                const SizedBox(height: 5),
                Padding(
                  padding: const EdgeInsets.only(left: 23),
                  child: _StatusPill(
                    label: priority,
                    color: AppColors.primaryDark,
                  ),
                ),
              ],
            ),
          );
        }

        return Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: color, size: 16),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  content,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    height: 1.35,
                  ),
                ),
              ),
              const SizedBox(width: 7),
              _StatusPill(label: priority, color: AppColors.primaryDark),
            ],
          ),
        );
      },
    );
  }
}

class _DiffStatus extends StatelessWidget {
  const _DiffStatus({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final uri = _stringMetadata(message.metadata, 'uri') ?? message.text;
    final status = _stringMetadata(message.metadata, 'status') ?? 'started';
    final rawChanges = message.metadata['changes'];
    final changeCount = _lazyMapCount(rawChanges);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: _SectionHeader(
                icon: Icons.difference_outlined,
                label: 'Diff',
              ),
            ),
            _StatusPill(label: status, color: _statusColor(status)),
          ],
        ),
        const SizedBox(height: 6),
        SelectableText(
          uri,
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w700,
          ),
        ),
        if (changeCount > 0) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _StatusPill(
                label: '$changeCount changes',
                color: AppColors.primaryDark,
              ),
            ],
          ),
          const SizedBox(height: 8),
          _DiffChangesList(rawChanges: rawChanges, changeCount: changeCount),
        ],
        if (message.metadata['truncated'] == true) ...[
          const SizedBox(height: 6),
          const _DetailsIncompleteNotice(),
        ],
      ],
    );
  }
}

class _DiffChangesList extends StatefulWidget {
  const _DiffChangesList({required this.rawChanges, required this.changeCount});

  final Object? rawChanges;
  final int changeCount;

  @override
  State<_DiffChangesList> createState() => _DiffChangesListState();
}

class _DiffChangesListState extends State<_DiffChangesList> {
  var _expanded = false;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: Material(
        color: Colors.transparent,
        child: ExpansionTile(
          onExpansionChanged: (expanded) {
            if (_expanded == expanded) return;
            setState(() => _expanded = expanded);
          },
          tilePadding: EdgeInsets.zero,
          childrenPadding: EdgeInsets.zero,
          initiallyExpanded: false,
          title: const Text(
            'Changed lines',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w800,
            ),
          ),
          children: _expanded
              ? [
                  SizedBox(
                    height: _boundedNestedListHeight(
                      itemCount: widget.changeCount,
                      estimatedItemHeight: 92,
                      maxHeight: _nestedDetailsMaxHeight,
                    ),
                    child: ListView.separated(
                      key: const ValueKey('diff-changes-list'),
                      primary: false,
                      itemCount: widget.changeCount,
                      separatorBuilder: (context, index) =>
                          const SizedBox(height: 6),
                      itemBuilder: (context, index) {
                        final change = _lazyMapAt(widget.rawChanges, index);
                        return change == null
                            ? const SizedBox.shrink()
                            : _DiffChangeRow(change: change);
                      },
                    ),
                  ),
                ]
              : const <Widget>[],
        ),
      ),
    );
  }
}

class _DiffChangeRow extends StatelessWidget {
  const _DiffChangeRow({required this.change});

  final Map<String, Object?> change;

  @override
  Widget build(BuildContext context) {
    final type = _stringMetadata(change, 'type') ?? 'change';
    final line = change['line'];
    final content = _stringMetadata(change, 'content');
    final oldContent = _stringMetadata(change, 'oldContent');
    final newContent = _stringMetadata(change, 'newContent');
    final body = [
      ?content,
      if (oldContent != null) '- $oldContent',
      if (newContent != null) '+ $newContent',
    ].join('\n');

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(9),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _StatusPill(label: type, color: _statusColor(type)),
              if (line != null) ...[
                const SizedBox(width: 7),
                Text(
                  'line $line',
                  style: const TextStyle(
                    color: AppColors.textTertiary,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ],
          ),
          if (body.isNotEmpty) ...[
            const SizedBox(height: 6),
            SelectableText(
              body,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontFamily: 'monospace',
                fontSize: 12,
                height: 1.35,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _CommandsStatus extends StatefulWidget {
  const _CommandsStatus({
    required this.message,
    required this.inputBudget,
    required this.previewRevision,
  });

  final ChatMessage message;
  final AcpInputBudget inputBudget;
  final Object previewRevision;

  @override
  State<_CommandsStatus> createState() => _CommandsStatusState();
}

class _CommandsStatusState extends State<_CommandsStatus> {
  var _expanded = false;

  @override
  Widget build(BuildContext context) {
    final rawCommands = widget.message.metadata['commands'];
    final commandCount = _lazyMapCount(rawCommands);
    final previewCount = commandCount < _inlineCollectionPreviewItems
        ? commandCount
        : _inlineCollectionPreviewItems;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader(
          icon: Icons.terminal_rounded,
          label: 'Available Commands',
        ),
        const SizedBox(height: 8),
        if (commandCount == 0)
          const Text(
            'No commands available.',
            style: TextStyle(color: AppColors.textSecondary),
          )
        else
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (var index = 0; index < previewCount; index++)
                    if (_lazyMapAt(rawCommands, index) case final command?)
                      Tooltip(
                        message: _stringMetadata(command, 'description') ?? '',
                        child: _CommandChip(
                          label: _stringMetadata(command, 'name') ?? 'command',
                        ),
                      ),
                  if (commandCount > previewCount)
                    _TinyCollectionPill('${commandCount - previewCount} more'),
                ],
              ),
              const SizedBox(height: 8),
              Theme(
                data: Theme.of(
                  context,
                ).copyWith(dividerColor: Colors.transparent),
                child: Material(
                  color: Colors.transparent,
                  child: ExpansionTile(
                    onExpansionChanged: (expanded) {
                      if (_expanded == expanded) return;
                      setState(() => _expanded = expanded);
                    },
                    tilePadding: EdgeInsets.zero,
                    childrenPadding: EdgeInsets.zero,
                    title: const Text(
                      'Command details',
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    children: _expanded
                        ? [
                            SizedBox(
                              height: _boundedNestedListHeight(
                                itemCount: commandCount,
                                estimatedItemHeight: 104,
                                maxHeight: _commandDetailsMaxHeight,
                              ),
                              child: ListView.separated(
                                key: const ValueKey('command-details-list'),
                                primary: false,
                                itemCount: commandCount,
                                separatorBuilder: (context, index) =>
                                    const SizedBox(height: 6),
                                itemBuilder: (context, index) {
                                  final command = _lazyMapAt(
                                    rawCommands,
                                    index,
                                  );
                                  return command == null
                                      ? const SizedBox.shrink()
                                      : _CommandDetailCard(
                                          command: command,
                                          inputBudget: widget.inputBudget,
                                          previewRevision:
                                              widget.previewRevision,
                                        );
                                },
                              ),
                            ),
                          ]
                        : const <Widget>[],
                  ),
                ),
              ),
            ],
          ),
      ],
    );
  }
}

class _TinyCollectionPill extends StatelessWidget {
  const _TinyCollectionPill(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: AppColors.surfaceMuted,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: AppColors.borderSoft),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: AppColors.textSecondary,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _DetailsIncompleteNotice extends StatelessWidget {
  const _DetailsIncompleteNotice();

  @override
  Widget build(BuildContext context) {
    return const Text(
      'Details omitted',
      style: TextStyle(
        color: AppColors.warning,
        fontSize: 11,
        fontWeight: FontWeight.w700,
      ),
    );
  }
}

class _CommandDetailCard extends StatelessWidget {
  const _CommandDetailCard({
    required this.command,
    required this.inputBudget,
    required this.previewRevision,
  });

  final Map<String, Object?> command;
  final AcpInputBudget inputBudget;
  final Object previewRevision;

  @override
  Widget build(BuildContext context) {
    final name = _stringMetadata(command, 'name') ?? 'command';
    final description = _stringMetadata(command, 'description');
    final input = command['input'];
    final parameters = command['parameters'];
    final inputHint = input is Map
        ? _stringMetadata(_objectMap(input), 'hint')
        : null;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(9),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            name,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w800,
              letterSpacing: 0,
            ),
          ),
          if (description != null) ...[
            const SizedBox(height: 5),
            Text(
              description,
              style: const TextStyle(
                color: AppColors.textSecondary,
                height: 1.35,
              ),
            ),
          ],
          if (inputHint != null) ...[
            const SizedBox(height: 6),
            _DetailBlock(entry: _DetailEntry('Input hint', inputHint)),
          ],
          if (parameters != null) ...[
            const SizedBox(height: 6),
            _BoundedMetadataDetail(
              label: 'Parameters',
              payload: parameters,
              inputBudget: inputBudget,
              previewRevision: previewRevision,
            ),
          ],
        ],
      ),
    );
  }
}

class _ModeStatus extends StatelessWidget {
  const _ModeStatus({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final mode = _stringMetadata(message.metadata, 'mode') ?? message.text;
    return Row(
      children: [
        const Expanded(
          child: _SectionHeader(icon: Icons.tune_rounded, label: 'Mode'),
        ),
        _StatusPill(
          label: mode.isEmpty ? 'default' : mode,
          color: AppColors.primaryDark,
        ),
      ],
    );
  }
}

class _TerminalStatus extends StatelessWidget {
  const _TerminalStatus({
    required this.message,
    required this.inputBudget,
    required this.previewRevision,
  });

  final ChatMessage message;
  final AcpInputBudget inputBudget;
  final Object previewRevision;

  @override
  Widget build(BuildContext context) {
    final status = _stringMetadata(message.metadata, 'status') ?? 'running';
    final event = _stringMetadata(message.metadata, 'terminalEvent');
    final command = _terminalCommand(message);
    final cwd = _stringMetadata(message.metadata, 'cwd');
    final output = _stringMetadata(message.metadata, 'output');
    final exitCode = _numberMetadata(message.metadata, 'exitCode');
    final truncated = message.metadata['truncated'] == true;
    final details = <String>[
      if (event != null) _humanizeStatus(event),
      if (exitCode != null) 'exit $exitCode',
      ?cwd,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: _SectionHeader(
                icon: Icons.terminal_rounded,
                label: 'Terminal',
              ),
            ),
            _StatusPill(label: status, color: _statusColor(status)),
          ],
        ),
        const SizedBox(height: 6),
        SelectableText(
          command.isEmpty ? 'Command unavailable' : command,
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontFamily: 'monospace',
            fontSize: 12,
            fontWeight: FontWeight.w700,
            height: 1.35,
          ),
        ),
        if (details.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            details.join(' · '),
            style: const TextStyle(
              color: AppColors.textTertiary,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
        if (output != null) ...[
          const SizedBox(height: 8),
          _BoundedMetadataDetail(
            label: truncated ? 'Output (truncated)' : 'Output',
            payload: output,
            inputBudget: inputBudget,
            previewRevision: previewRevision,
          ),
        ],
      ],
    );
  }
}

class _PlainStatus extends StatelessWidget {
  const _PlainStatus({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    return Text(
      message.text,
      style: const TextStyle(color: AppColors.textSecondary, height: 1.35),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: AppColors.primaryDark),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w800,
              letterSpacing: 0,
            ),
          ),
        ),
      ],
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Text(
        _humanizeStatus(label),
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: 0,
        ),
      ),
    );
  }
}

class _CommandChip extends StatelessWidget {
  const _CommandChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: AppColors.primarySoft,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.18)),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: AppColors.primaryDark,
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: 0,
        ),
      ),
    );
  }
}

class _DetailBlock extends StatelessWidget {
  const _DetailBlock({required this.entry});

  final _DetailEntry entry;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(9),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: const Color(0xfffde68a)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            entry.label,
            style: const TextStyle(
              color: Color(0xff92400e),
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 0,
            ),
          ),
          if (entry.value.isNotEmpty) ...[
            const SizedBox(height: 5),
            SelectableText(
              entry.value,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontFamily: 'monospace',
                fontSize: 12,
                height: 1.35,
              ),
            ),
          ],
          if (entry.omission != null)
            _InputOmissionNotice(omission: entry.omission!, user: false),
        ],
      ),
    );
  }
}

class _BoundedMetadataDetail extends StatefulWidget {
  const _BoundedMetadataDetail({
    super.key,
    required this.label,
    required this.payload,
    required this.inputBudget,
    required this.previewRevision,
  });

  final String label;
  final Object? payload;
  final AcpInputBudget inputBudget;
  final Object previewRevision;

  @override
  State<_BoundedMetadataDetail> createState() => _BoundedMetadataDetailState();
}

class _BoundedMetadataDetailState extends State<_BoundedMetadataDetail> {
  late _DetailEntry _entry = _writeEntry();

  @override
  void didUpdateWidget(covariant _BoundedMetadataDetail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.payload, oldWidget.payload) ||
        widget.previewRevision != oldWidget.previewRevision ||
        !identical(widget.inputBudget, oldWidget.inputBudget) ||
        widget.label != oldWidget.label) {
      _entry = _writeEntry();
    }
  }

  _DetailEntry _writeEntry() {
    final preview = writeBoundedMetadataPreview(
      widget.payload,
      budget: widget.inputBudget,
    );
    return _DetailEntry(
      widget.label,
      preview.omission == null && widget.payload is String
          ? widget.payload! as String
          : preview.text,
      preview.omission,
    );
  }

  @override
  Widget build(BuildContext context) => _DetailBlock(entry: _entry);
}

class _ParsedTool {
  const _ParsedTool({
    required this.title,
    required this.status,
    required this.id,
    required this.kind,
    required this.content,
    required this.input,
    required this.output,
    required this.locations,
    required this.previewRevision,
  });

  final String title;
  final String status;
  final String id;
  final String kind;
  final Object? content;
  final Object? input;
  final Object? output;
  final List<String> locations;
  final Object previewRevision;

  factory _ParsedTool.fromMessage(ChatMessage message) {
    final metadata = message.metadata;
    var title = _stringMetadata(metadata, 'title') ?? message.text;
    var status = _stringMetadata(metadata, 'status') ?? '';
    final legacy = RegExp(r'^\[Tool:\s*(.*?)\]\s*(.*)$').firstMatch(title);
    if (legacy != null) {
      title = legacy.group(1)?.trim() ?? title;
      status = status.isEmpty ? legacy.group(2)?.trim() ?? '' : status;
    }
    status = status.replaceFirst('ToolCallStatus.', '');
    if (status.isEmpty) status = 'completed';

    final locations = _mapList(metadata['locations'])
        .map((location) {
          final path = _stringMetadata(location, 'path') ?? '';
          final line = location['line'];
          return line == null ? path : '$path:$line';
        })
        .where((location) => location.isNotEmpty)
        .toList();

    return _ParsedTool(
      title: title.isEmpty ? 'Tool call' : title,
      status: status,
      id: _toolCallIdMetadata(metadata) ?? '',
      kind: _stringMetadata(metadata, 'kind') == 'tool'
          ? ''
          : _stringMetadata(metadata, 'kind') ?? '',
      content: metadata['content'],
      input: _firstMetadataValue(metadata, const ['rawInput', 'raw_input']),
      output: _firstMetadataValue(metadata, const ['rawOutput', 'raw_output']),
      locations: locations,
      previewRevision: message.revision,
    );
  }
}

class _DetailEntry {
  const _DetailEntry(this.label, this.value, [this.omission]);

  final String label;
  final String value;
  final AcpInputOmission? omission;
}

bool _hasMetadataDetail(Object? value) =>
    value != null && (value is! String || value.isNotEmpty);

String? _stringMetadata(Map<String, Object?> metadata, String key) {
  final value = metadata[key];
  if (value is String && value.trim().isNotEmpty) return value.trim();
  return null;
}

String? _toolCallIdMetadata(Map<String, Object?> metadata) {
  for (final key in _toolCallIdMetadataKeys) {
    final value = _stringMetadata(metadata, key);
    if (value != null) return value;
  }
  final nested = metadata['toolCall'];
  if (nested is Map) {
    final nestedMetadata = nested.map(
      (key, value) => MapEntry(key.toString(), value),
    );
    for (final key in _toolCallIdMetadataKeys) {
      final value = _stringMetadata(nestedMetadata, key);
      if (value != null) return value;
    }
  }
  return null;
}

Object? _firstMetadataValue(Map<String, Object?> metadata, List<String> keys) {
  for (final key in keys) {
    final value = metadata[key];
    if (value != null) return value;
  }
  return null;
}

int? _numberMetadata(Map<String, Object?> metadata, String key) {
  final value = metadata[key];
  if (value is int) return value;
  if (value is num) return value.toInt();
  return null;
}

String _terminalCommand(ChatMessage message) {
  final command = _stringMetadata(message.metadata, 'command');
  final args = message.metadata['args'];
  if (command == null) return message.text.trim();
  if (args is! List || args.isEmpty) return command;
  final normalizedArgs = args
      .whereType<Object>()
      .map((value) => value.toString().trim())
      .where((value) => value.isNotEmpty)
      .toList();
  if (normalizedArgs.isEmpty) return command;
  return '$command ${normalizedArgs.join(' ')}';
}

String _formatByteCount(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(kb < 10 ? 1 : 0)} KB';
  final mb = kb / 1024;
  if (mb < 1024) return '${mb.toStringAsFixed(mb < 10 ? 1 : 0)} MB';
  final gb = mb / 1024;
  return '${gb.toStringAsFixed(gb < 10 ? 1 : 0)} GB';
}

List<Map<String, Object?>> _mapList(Object? value) {
  if (value is! List) return const [];
  return value.whereType<Map>().map((entry) {
    if (entry is Map<String, Object?>) return entry;
    return entry.map((key, value) => MapEntry(key.toString(), value));
  }).toList();
}

int _lazyMapCount(Object? value) => value is List ? value.length : 0;

Map<String, Object?>? _lazyMapAt(Object? value, int index) {
  if (value is! List || index < 0 || index >= value.length) return null;
  final entry = value[index];
  if (entry is Map<String, Object?>) return entry;
  if (entry is! Map) return null;
  return entry.map((key, value) => MapEntry(key.toString(), value));
}

double _boundedNestedListHeight({
  required int itemCount,
  required double estimatedItemHeight,
  required double maxHeight,
}) {
  final estimated = itemCount * estimatedItemHeight;
  return estimated < maxHeight ? estimated : maxHeight;
}

Map<String, Object?> _mapMetadata(Object? value) {
  if (value is! Map) return const <String, Object?>{};
  if (value is Map<String, Object?>) return value;
  return value.map((key, value) => MapEntry(key.toString(), value));
}

String? _resourceTitleFromUri(String uri) {
  final parsed = Uri.tryParse(uri);
  if (parsed == null) return null;
  if (parsed.pathSegments.isNotEmpty) return parsed.pathSegments.last;
  return parsed.host.isEmpty ? null : parsed.host;
}

Map<String, Object?> _objectMap(Object? value) {
  if (value is! Map) return const <String, Object?>{};
  if (value is Map<String, Object?>) return value;
  return value.map((key, value) => MapEntry(key.toString(), value));
}

Color _statusColor(String status) {
  final normalized = _normalizedStatusToken(status);
  return switch (normalized) {
    'completed' || 'applied' => AppColors.success,
    'in_progress' ||
    'progress' ||
    'running' ||
    'started' => AppColors.primaryDark,
    'failed' || 'error' || 'rejected' => AppColors.danger,
    'cancelled' || 'canceled' => AppColors.textSecondary,
    _ => AppColors.warning,
  };
}

String _humanizeStatus(String value) {
  final cleaned = value.replaceFirst('ToolCallStatus.', '').trim();
  final spaced = cleaned
      .replaceAllMapped(
        RegExp(r'([a-z0-9])([A-Z])'),
        (match) => '${match.group(1)} ${match.group(2)}',
      )
      .replaceAll(RegExp(r'[_-]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (spaced.isEmpty) return 'unknown';
  final normalized = spaced.toLowerCase();
  return normalized[0].toUpperCase() + normalized.substring(1);
}

String _normalizedStatusToken(String value) {
  final cleaned = value.replaceFirst('ToolCallStatus.', '').trim();
  if (cleaned.isEmpty) return 'unknown';
  return cleaned
      .replaceAllMapped(
        RegExp(r'([a-z0-9])([A-Z])'),
        (match) => '${match.group(1)}_${match.group(2)}',
      )
      .replaceAll(RegExp(r'[\s-]+'), '_')
      .toLowerCase();
}

String _wireStopReason(String value) {
  return switch (value) {
    'endTurn' => 'end turn',
    'maxTokens' => 'max tokens',
    'maxTurnRequests' => 'max turn requests',
    _ => value.replaceAll('_', ' '),
  };
}

Color _stopReasonColor(String value) {
  return switch (value) {
    'endTurn' => AppColors.success,
    'cancelled' => AppColors.textSecondary,
    'maxTokens' || 'maxTurnRequests' => AppColors.warning,
    'refusal' => AppColors.danger,
    _ => AppColors.primaryDark,
  };
}

Uint8List? _tryDecodeBase64(String value) {
  try {
    return base64Decode(value);
  } on FormatException {
    return null;
  }
}
