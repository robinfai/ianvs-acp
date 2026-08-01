import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../../acp/acp_input_budget.dart';
import '../../state/chat_controller.dart';
import '../bounded_metadata_preview.dart';
import '../image_decode_budget.dart';
import '../theme/app_design_tokens.dart';
import '../markdown_render_budget.dart';
import 'bounded_image_preview.dart';
import 'markdown_code_block.dart';

const List<String> _toolCallIdMetadataKeys = [
  'toolCallId',
  'tool_call_id',
  'id',
  'callId',
  'call_id',
];
const _userMessageSelectionColor = Color(0x3d000000);
const int _maxTimelineSignatureMessages = 200;
const int _inlineCollectionPreviewItems = 5;
const int _contentBlockProjectionBatchItems = 16;
const int _contentBlockVisiblePageItems = 3;
const double _contentBlocksMaxHeight = 320;
const double _nestedDetailsMaxHeight = 280;
const double _commandDetailsMaxHeight = 320;
const double _turnNavigationMarkerExtent = 14;
const double _turnNavigationMarkerPitch = 16;
const double _turnNavigationMarkerWidth = 38;
const double _turnNavigationIdleBarWidth = 7;
const double _turnNavigationHoverBarWidth = 34;
const double _conversationContentWidth = 760;

typedef MemoryFeedbackCallback =
    Future<void> Function({
      required String memoryId,
      required String rating,
      String? turnId,
      String? reason,
    });

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
    this.onTapLink,
    this.onMemoryFeedback,
    this.inputBudget = const AcpInputBudget(),
    this.imageDecodeLedger,
    this.boundedImageDecoder = const DartUiBoundedImageDecoder(),
  });

  final List<ChatMessage> messages;
  final String agentName;
  final bool hasActiveSession;
  final String? activeSessionLabel;
  final bool isLoadingSession;
  final int messageListRevision;
  final VoidCallback? onNewSession;
  final MarkdownTapLinkCallback? onTapLink;
  final MemoryFeedbackCallback? onMemoryFeedback;
  final AcpInputBudget inputBudget;
  final AcpImageDecodeBudgetLedger? imageDecodeLedger;
  final BoundedImageDecoder boundedImageDecoder;

  @override
  State<ChatTimeline> createState() => _ChatTimelineState();
}

class _ChatTimelineState extends State<ChatTimeline> {
  final ScrollController _scrollController = ScrollController();
  final Map<String, GlobalKey> _turnItemKeys = <String, GlobalKey>{};
  final GlobalKey _timelineViewportKey = GlobalKey();
  final GlobalKey _timelineCenterSliverKey = GlobalKey();
  late AcpImageDecodeBudgetLedger _imageDecodeLedger;
  int _activeTurnIndex = 0;
  int? _lockedTurnIndex;
  int _viewportAnchorTurnIndex = 0;
  int? _hoveredOutlineIndex;
  double? _hoveredMarkerGlobalY;
  late int _messageSignature = _timelineMessagesSignature(
    widget.messages,
    messageListRevision: widget.messageListRevision,
    isLoadingSession: widget.isLoadingSession,
  );

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_syncActiveTurnFromScroll);
    widget.inputBudget.validate();
    _imageDecodeLedger =
        widget.imageDecodeLedger ??
        AcpImageDecodeBudgetLedger(budget: widget.inputBudget);
    if (widget.messages.isNotEmpty) {
      _scheduleScrollToBottom();
    }
  }

  @override
  void didUpdateWidget(covariant ChatTimeline oldWidget) {
    super.didUpdateWidget(oldWidget);
    widget.inputBudget.validate();
    if (!identical(widget.imageDecodeLedger, oldWidget.imageDecodeLedger) ||
        (!identical(widget.inputBudget, oldWidget.inputBudget) &&
            widget.imageDecodeLedger == null)) {
      _imageDecodeLedger =
          widget.imageDecodeLedger ??
          AcpImageDecodeBudgetLedger(budget: widget.inputBudget);
    }
  }

  @override
  void dispose() {
    _scrollController.removeListener(_syncActiveTurnFromScroll);
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _syncMessageSignature();

    if (widget.messages.isEmpty) {
      return ColoredBox(
        color: AppColors.surface,
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

    final turns = _timelineTurns(widget.messages);
    final outlineEntries = _turnOutlineEntries(turns);
    final loadingFooterCount = widget.isLoadingSession ? 1 : 0;

    return _ImageDecodeScope(
      ledger: _imageDecodeLedger,
      decoder: widget.boundedImageDecoder,
      inputBudget: widget.inputBudget,
      child: ColoredBox(
        color: AppColors.surface,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final showNavigator =
                outlineEntries.length > 1 && constraints.maxWidth >= 700;
            final viewportAnchorTurnIndex = _viewportAnchorTurnIndex.clamp(
              0,
              turns.length - 1,
            );
            final activeOutlineIndex = _outlineIndexForTurn(
              outlineEntries,
              _activeTurnIndex.clamp(0, turns.length - 1),
            );
            final hoveredOutlineIndex = _hoveredOutlineIndex;
            final hasHoveredOutline =
                hoveredOutlineIndex != null &&
                hoveredOutlineIndex >= 0 &&
                hoveredOutlineIndex < outlineEntries.length;
            return Stack(
              key: _timelineViewportKey,
              children: [
                NotificationListener<ScrollNotification>(
                  onNotification: _handleTimelineScrollNotification,
                  child: CustomScrollView(
                    key: const ValueKey('chat-timeline-list'),
                    controller: _scrollController,
                    center: _timelineCenterSliverKey,
                    anchor: 0.08,
                    slivers: [
                      SliverPadding(
                        padding: EdgeInsets.fromLTRB(
                          showNavigator ? 62 : 22,
                          20,
                          24,
                          0,
                        ),
                        sliver: SliverList.builder(
                          itemCount: viewportAnchorTurnIndex,
                          itemBuilder: (context, index) {
                            final turnIndex =
                                viewportAnchorTurnIndex - index - 1;
                            return _buildTimelineTurn(turns, turnIndex);
                          },
                        ),
                      ),
                      SliverPadding(
                        key: _timelineCenterSliverKey,
                        padding: EdgeInsets.fromLTRB(
                          showNavigator ? 62 : 22,
                          0,
                          24,
                          22,
                        ),
                        sliver: SliverList.builder(
                          itemCount:
                              turns.length -
                              viewportAnchorTurnIndex +
                              loadingFooterCount,
                          itemBuilder: (context, index) {
                            final turnIndex = viewportAnchorTurnIndex + index;
                            if (turnIndex >= turns.length) {
                              return const _SessionLoadingFooter();
                            }
                            return _buildTimelineTurn(turns, turnIndex);
                          },
                        ),
                      ),
                    ],
                  ),
                ),
                if (showNavigator)
                  Positioned(
                    left: 16,
                    top: 20,
                    bottom: 22,
                    width: _turnNavigationMarkerWidth,
                    child: _TurnNavigationRail(
                      entries: outlineEntries,
                      activeIndex: activeOutlineIndex,
                      hoveredIndex: _hoveredOutlineIndex,
                      onHover: (index, globalY) {
                        if (_hoveredOutlineIndex == index &&
                            _hoveredMarkerGlobalY == globalY) {
                          return;
                        }
                        setState(() {
                          _hoveredOutlineIndex = index;
                          _hoveredMarkerGlobalY = globalY;
                        });
                      },
                      onTap: (index) => _selectOutlineTurn(
                        outlineEntries[index].turnIndex,
                        turns,
                      ),
                    ),
                  ),
                if (showNavigator)
                  AnimatedPositioned(
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOutCubic,
                    left: 62,
                    top: hasHoveredOutline
                        ? _turnPreviewTop(
                            markerGlobalY: _hoveredMarkerGlobalY,
                            viewportHeight: constraints.maxHeight,
                          )
                        : 12,
                    width: 360,
                    child: IgnorePointer(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 180),
                        reverseDuration: const Duration(milliseconds: 120),
                        switchInCurve: Curves.easeOutCubic,
                        switchOutCurve: Curves.easeInCubic,
                        transitionBuilder: (child, animation) {
                          final offset = Tween<Offset>(
                            begin: const Offset(-0.025, 0),
                            end: Offset.zero,
                          ).animate(animation);
                          return FadeTransition(
                            opacity: animation,
                            child: SlideTransition(
                              position: offset,
                              child: child,
                            ),
                          );
                        },
                        child: hasHoveredOutline
                            ? _TurnNavigationPreview(
                                key: ValueKey(
                                  'turn-navigation-preview-$hoveredOutlineIndex',
                                ),
                                entry: outlineEntries[hoveredOutlineIndex],
                              )
                            : const SizedBox.shrink(
                                key: ValueKey('turn-navigation-preview-empty'),
                              ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  GlobalKey _turnItemKey(_TimelineTurn turn, int index) {
    final identity = _turnItemIdentity(turn, index);
    return _turnItemKeys.putIfAbsent(identity, GlobalKey.new);
  }

  String _turnItemIdentity(_TimelineTurn turn, int index) =>
      '${turn.turnId ?? 'legacy'}-$index';

  Widget _buildTimelineTurn(List<_TimelineTurn> turns, int index) {
    final turn = turns[index];
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: KeyedSubtree(
        key: _turnItemKey(turn, index),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: _conversationContentWidth,
            ),
            child: _TurnSectionBubble(
              key: ValueKey('timeline-turn-${turn.turnId}-$index'),
              turn: turn,
              inputBudget: widget.inputBudget,
              onTapLink: widget.onTapLink,
              onMemoryFeedback: widget.onMemoryFeedback,
            ),
          ),
        ),
      ),
    );
  }

  double _turnPreviewTop({
    required double? markerGlobalY,
    required double viewportHeight,
  }) {
    final viewport = _timelineViewportKey.currentContext?.findRenderObject();
    final markerLocalY = viewport is RenderBox && markerGlobalY != null
        ? viewport.globalToLocal(Offset(0, markerGlobalY)).dy
        : 68.0;
    return (markerLocalY - 56).clamp(
      12.0,
      (viewportHeight - 172).clamp(12.0, double.infinity),
    );
  }

  void _syncActiveTurnFromScroll() {
    if (!mounted || !_scrollController.hasClients) return;
    if (_lockedTurnIndex != null) return;
    final turns = _timelineTurns(widget.messages);
    if (turns.length <= 1) return;
    final viewport = _timelineViewportKey.currentContext?.findRenderObject();
    if (viewport is! RenderBox) return;
    const focusY = 88.0;
    var next = _activeTurnIndex.clamp(0, turns.length - 1);
    var nearestDistance = double.infinity;
    for (var index = 0; index < turns.length; index++) {
      final item = _turnItemKeys[_turnItemIdentity(turns[index], index)]
          ?.currentContext
          ?.findRenderObject();
      if (item is! RenderBox || !item.attached) continue;
      final top = viewport.globalToLocal(item.localToGlobal(Offset.zero)).dy;
      final distance = (top - focusY).abs();
      if (distance < nearestDistance) {
        nearestDistance = distance;
        next = index;
      }
    }
    if (next == _activeTurnIndex) return;
    setState(() => _activeTurnIndex = next);
  }

  bool _handleTimelineScrollNotification(ScrollNotification notification) {
    if (_lockedTurnIndex == null) return false;
    final isDirectDrag =
        notification is ScrollStartNotification &&
        notification.dragDetails != null;
    final isUserDirection =
        notification is UserScrollNotification &&
        notification.direction != ScrollDirection.idle;
    if (!isDirectDrag && !isUserDirection) return false;
    setState(() => _lockedTurnIndex = null);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncActiveTurnFromScroll();
    });
    return false;
  }

  void _selectOutlineTurn(int index, List<_TimelineTurn> turns) {
    if (turns.isEmpty) return;
    final targetIndex = index.clamp(0, turns.length - 1);
    if (_lockedTurnIndex == targetIndex) return;
    setState(() {
      _viewportAnchorTurnIndex = targetIndex;
      _lockedTurnIndex = targetIndex;
      _activeTurnIndex = targetIndex;
    });
    if (_scrollController.hasClients && _scrollController.offset != 0) {
      _scrollController.jumpTo(0);
    }
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
      if (_lockedTurnIndex != null) return;
      final position = _scrollController.position;
      if (!position.hasContentDimensions) {
        _scheduleScrollToBottom(remainingPasses: remainingPasses);
        return;
      }
      final bottom = position.maxScrollExtent;
      if (bottom.isFinite && (position.pixels - bottom).abs() > 0.5) {
        _scrollController.jumpTo(bottom);
      }
      final turnCount = _timelineTurns(widget.messages).length;
      final lastTurnIndex = turnCount - 1;
      if (lastTurnIndex >= 0 && _activeTurnIndex != lastTurnIndex) {
        setState(() => _activeTurnIndex = lastTurnIndex);
      }
      if (remainingPasses > 0) {
        _scheduleScrollToBottom(remainingPasses: remainingPasses - 1);
      }
    });
  }
}

class _ImageDecodeScope extends InheritedWidget {
  const _ImageDecodeScope({
    required this.ledger,
    required this.decoder,
    required this.inputBudget,
    required super.child,
  });

  final AcpImageDecodeBudgetLedger ledger;
  final BoundedImageDecoder decoder;
  final AcpInputBudget inputBudget;

  static _ImageDecodeScope of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<_ImageDecodeScope>();
    if (scope == null) throw StateError('Missing image decode scope.');
    return scope;
  }

  @override
  bool updateShouldNotify(_ImageDecodeScope oldWidget) =>
      !identical(ledger, oldWidget.ledger) ||
      !identical(decoder, oldWidget.decoder) ||
      !identical(inputBudget, oldWidget.inputBudget);
}

int _timelineMessagesSignature(
  List<ChatMessage> messages, {
  required int messageListRevision,
  required bool isLoadingSession,
}) {
  final visibleMessages = _signatureTimelineMessages(messages);
  return _messagesSignature(
    visibleMessages,
    messageListRevision: messageListRevision,
    isLoadingSession: isLoadingSession,
  );
}

List<ChatMessage> _signatureTimelineMessages(List<ChatMessage> messages) {
  if (messages.length <= _maxTimelineSignatureMessages) return messages;
  return messages.sublist(messages.length - _maxTimelineSignatureMessages);
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

List<_TimelineTurn> _timelineTurns(List<ChatMessage> messages) {
  final turns = <_TimelineTurn>[];
  var index = 0;
  while (index < messages.length) {
    final first = messages[index];
    final turnId = _messageTurnId(first);
    if (turnId == null && first.role != ChatMessageRole.user) {
      if (first.role != ChatMessageRole.tool) {
        turns.add(_TimelineTurn(turnId: null, messages: [first]));
        index += 1;
        continue;
      }
      final toolMessages = <ChatMessage>[];
      while (index < messages.length &&
          _messageTurnId(messages[index]) == null &&
          messages[index].role == ChatMessageRole.tool) {
        toolMessages.add(messages[index]);
        index += 1;
      }
      turns.add(_TimelineTurn(turnId: null, messages: toolMessages));
      continue;
    }
    final turnMessages = <ChatMessage>[];
    while (index < messages.length) {
      final candidate = messages[index];
      final candidateTurnId = _messageTurnId(candidate);
      if (turnId != null && candidateTurnId != turnId) break;
      if (turnId == null && candidateTurnId != null) break;
      if (turnId == null &&
          turnMessages.isNotEmpty &&
          candidate.role == ChatMessageRole.user) {
        break;
      }
      turnMessages.add(messages[index]);
      index += 1;
    }
    turns.add(_TimelineTurn(turnId: turnId, messages: turnMessages));
  }
  return turns;
}

List<_TurnOutlineEntry> _turnOutlineEntries(List<_TimelineTurn> turns) {
  final entries = <_TurnOutlineEntry>[];
  for (var turnIndex = 0; turnIndex < turns.length; turnIndex++) {
    final turn = turns[turnIndex];
    final prompt = _outlinePromptPreview(turn.userMessages);
    if (prompt == null) continue;
    entries.add(
      _TurnOutlineEntry(
        turnIndex: turnIndex,
        promptPreview: prompt,
        responsePreview: turn.responsePreview,
      ),
    );
  }
  return entries;
}

String? _outlinePromptPreview(List<ChatMessage> messages) {
  final candidates = messages
      .map((message) => _userPromptDisplayText(message.text))
      .where((text) => text.isNotEmpty)
      .toList(growable: false);
  if (candidates.isEmpty) return null;
  for (final text in candidates) {
    if (!_isAttachmentProjectionText(text)) return text;
  }
  return null;
}

String _userPromptDisplayText(String text) {
  const marker = '## My request for Codex:';
  final markerIndex = text.indexOf(marker);
  if (markerIndex < 0) return text.trim();
  final request = text.substring(markerIndex + marker.length).trim();
  return request.isEmpty ? text.trim() : request;
}

bool _isAttachmentProjectionText(String text) {
  final normalized = text.trim();
  if (!normalized.startsWith('[') || !normalized.endsWith(')')) return false;
  return normalized.contains('](file://') ||
      normalized.startsWith('[@image](') ||
      normalized.startsWith('[@codex-clipboard-');
}

int _outlineIndexForTurn(List<_TurnOutlineEntry> entries, int activeTurnIndex) {
  var activeIndex = 0;
  for (var index = 0; index < entries.length; index++) {
    if (entries[index].turnIndex > activeTurnIndex) break;
    activeIndex = index;
  }
  return activeIndex;
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

class _TurnOutlineEntry {
  const _TurnOutlineEntry({
    required this.turnIndex,
    required this.promptPreview,
    required this.responsePreview,
  });

  final int turnIndex;
  final String promptPreview;
  final String responsePreview;
}

class _TimelineTurn {
  const _TimelineTurn({required this.turnId, required this.messages});

  final int? turnId;
  final List<ChatMessage> messages;

  ChatMessage? get summary {
    for (final message in messages.reversed) {
      if (message.metadata['kind'] == 'assistant_summary') return message;
    }
    return null;
  }

  ChatMessage? get finalResponse {
    final explicitSummary = summary;
    if (explicitSummary != null) return explicitSummary;
    for (final message in messages.reversed) {
      if (message.role == ChatMessageRole.assistant &&
          message.text.trim().isNotEmpty) {
        return message;
      }
    }
    return null;
  }

  List<ChatMessage> get userMessages => messages
      .where(
        (message) =>
            message.role == ChatMessageRole.user &&
            !_isPureAttachmentProjection(message),
      )
      .toList(growable: false);

  List<ChatMessage> get resultMessages =>
      messages.where(_isPersistentTurnResult).toList(growable: false);

  List<ChatMessage> get processMessages {
    final response = finalResponse;
    final results = resultMessages;
    return messages
        .where(
          (message) =>
              message.role != ChatMessageRole.user &&
              !identical(message, response) &&
              !results.any((result) => identical(result, message)),
        )
        .toList(growable: false);
  }

  bool get isComplete {
    if (summary != null) return true;
    return messages.any(
      (message) =>
          message.role == ChatMessageRole.status &&
          _stringMetadata(message.metadata, 'kind') == 'turn',
    );
  }

  String get elapsedLabel {
    if (messages.length < 2) return 'Processed';
    final first = _messageTimestamp(messages.first);
    final last = _messageTimestamp(messages.last);
    if (first == null || last == null) return 'Processed';
    final elapsed = last.difference(first);
    if (elapsed.isNegative) return 'Processed';
    if (elapsed.inSeconds == 0) return 'Processed';
    if (elapsed.inMinutes > 0) {
      return 'Processed ${elapsed.inMinutes}m ${elapsed.inSeconds % 60}s';
    }
    return 'Processed ${elapsed.inSeconds}s';
  }

  String get responsePreview {
    final response = finalResponse?.text.trim();
    if (response != null && response.isNotEmpty) {
      return response;
    }
    return 'Execution in progress';
  }
}

bool _isPureAttachmentProjection(ChatMessage message) {
  return _lazyMapCount(message.metadata['contentBlocks']) == 0 &&
      _isAttachmentProjectionText(message.text);
}

bool _isPersistentTurnResult(ChatMessage message) {
  if (message.role == ChatMessageRole.status) {
    return _stringMetadata(message.metadata, 'kind') == 'diff';
  }
  if (message.role != ChatMessageRole.tool) return false;
  final parsed = _ParsedTool.fromMessage(message);
  return _toolDiffs(parsed.content).isNotEmpty;
}

int? _messageTurnId(ChatMessage message) {
  try {
    return message.turnId;
  } on NoSuchMethodError {
    return null;
  }
}

DateTime? _messageTimestamp(ChatMessage message) {
  try {
    return message.timestamp;
  } on NoSuchMethodError {
    return null;
  }
}

class _TurnSectionBubble extends StatefulWidget {
  const _TurnSectionBubble({
    super.key,
    required this.turn,
    required this.inputBudget,
    required this.onTapLink,
    this.onMemoryFeedback,
  });

  final _TimelineTurn turn;
  final AcpInputBudget inputBudget;
  final MarkdownTapLinkCallback? onTapLink;
  final MemoryFeedbackCallback? onMemoryFeedback;

  @override
  State<_TurnSectionBubble> createState() => _TurnSectionBubbleState();
}

class _TurnSectionBubbleState extends State<_TurnSectionBubble> {
  late bool _expanded = _initiallyExpanded();

  bool _initiallyExpanded() {
    return !widget.turn.isComplete ||
        widget.turn.finalResponse == null ||
        widget.turn.processMessages.isEmpty;
  }

  @override
  void didUpdateWidget(covariant _TurnSectionBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.turn.isComplete && widget.turn.isComplete) {
      _expanded = _initiallyExpanded();
    }
  }

  @override
  Widget build(BuildContext context) {
    final response = widget.turn.finalResponse;
    final userEntries = _timelineEntries(widget.turn.userMessages);
    final processEntries = _timelineEntries(widget.turn.processMessages);
    final resultEntries = _timelineEntries(widget.turn.resultMessages);
    final hasCollapsibleProcess =
        widget.turn.isComplete && response != null && processEntries.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var index = 0; index < userEntries.length; index++) ...[
          _buildEntry(userEntries[index]),
          if (index != userEntries.length - 1) const SizedBox(height: 8),
        ],
        if (userEntries.isNotEmpty &&
            (hasCollapsibleProcess || response != null))
          const SizedBox(height: 32),
        if (hasCollapsibleProcess)
          _ProcessedTurnHeader(
            label: widget.turn.elapsedLabel,
            expanded: _expanded,
            onPressed: () => setState(() => _expanded = !_expanded),
          ),
        if (hasCollapsibleProcess) const SizedBox(height: 12),
        if (_expanded || !hasCollapsibleProcess)
          for (var index = 0; index < processEntries.length; index++) ...[
            _buildEntry(processEntries[index]),
            if (index != processEntries.length - 1) const SizedBox(height: 10),
          ],
        if ((_expanded || !hasCollapsibleProcess) &&
            processEntries.isNotEmpty &&
            response != null)
          const SizedBox(height: 14),
        if (response != null) _buildEntry(_TimelineEntry.message(response)),
        if (response != null && resultEntries.isNotEmpty)
          const SizedBox(height: 16),
        for (var index = 0; index < resultEntries.length; index++) ...[
          _buildEntry(resultEntries[index]),
          if (index != resultEntries.length - 1) const SizedBox(height: 12),
        ],
      ],
    );
  }

  Widget _buildEntry(_TimelineEntry entry) {
    if (entry.toolMessages != null) {
      return _ToolGroupBubble(
        messages: entry.toolMessages!,
        inputBudget: widget.inputBudget,
      );
    }
    return _MessageBubble(
      message: entry.message!,
      inputBudget: widget.inputBudget,
      onTapLink: widget.onTapLink,
      onMemoryFeedback: widget.onMemoryFeedback,
    );
  }
}

class _TurnNavigationRail extends StatefulWidget {
  const _TurnNavigationRail({
    required this.entries,
    required this.activeIndex,
    required this.hoveredIndex,
    required this.onHover,
    required this.onTap,
  });

  final List<_TurnOutlineEntry> entries;
  final int activeIndex;
  final int? hoveredIndex;
  final void Function(int? index, double? markerGlobalY) onHover;
  final ValueChanged<int> onTap;

  @override
  State<_TurnNavigationRail> createState() => _TurnNavigationRailState();
}

class _TurnNavigationRailState extends State<_TurnNavigationRail> {
  final ScrollController _controller = ScrollController();

  @override
  void initState() {
    super.initState();
    _scheduleActiveMarkerVisibility();
  }

  @override
  void didUpdateWidget(covariant _TurnNavigationRail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activeIndex != widget.activeIndex ||
        oldWidget.entries.length != widget.entries.length) {
      _scheduleActiveMarkerVisibility();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _scheduleActiveMarkerVisibility() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_controller.hasClients || widget.entries.isEmpty) {
        return;
      }
      final position = _controller.position;
      final activeIndex = widget.activeIndex.clamp(
        0,
        widget.entries.length - 1,
      );
      final centeredPadding =
          (position.viewportDimension -
                  widget.entries.length * _turnNavigationMarkerPitch)
              .clamp(0.0, double.infinity) /
          2;
      final markerCenter =
          centeredPadding +
          activeIndex * _turnNavigationMarkerPitch +
          _turnNavigationMarkerPitch / 2;
      final target = markerCenter - position.viewportDimension / 2;
      final clampedTarget = target.clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      if ((position.pixels - clampedTarget).abs() < 0.5) return;
      _controller.animateTo(
        clampedTarget,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: 'Conversation turn navigation',
      child: LayoutBuilder(
        builder: (context, constraints) {
          final contentExtent =
              widget.entries.length * _turnNavigationMarkerPitch;
          final centeredPadding = constraints.maxHeight.isFinite
              ? ((constraints.maxHeight - contentExtent) / 2).clamp(
                  0.0,
                  double.infinity,
                )
              : 0.0;
          return MouseRegion(
            onExit: (_) => widget.onHover(null, null),
            child: ListView.builder(
              key: const ValueKey('turn-navigation-outline-list'),
              controller: _controller,
              padding: EdgeInsets.symmetric(vertical: centeredPadding),
              physics: const ClampingScrollPhysics(),
              itemExtent: _turnNavigationMarkerPitch,
              itemCount: widget.entries.length,
              itemBuilder: (context, index) {
                final entry = widget.entries[index];
                final hoverInfluence = _hoverInfluence(index);
                final isActive = index == widget.activeIndex;
                final baseColor = isActive
                    ? AppColors.textPrimary
                    : AppColors.border;
                return Semantics(
                  button: true,
                  label:
                      'Go to user message ${index + 1}: ${entry.promptPreview}',
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    onEnter: (event) =>
                        widget.onHover(index, event.position.dy),
                    child: GestureDetector(
                      key: ValueKey('turn-navigation-marker-$index'),
                      behavior: HitTestBehavior.opaque,
                      onTap: () => widget.onTap(index),
                      child: SizedBox(
                        width: _turnNavigationMarkerWidth,
                        height: _turnNavigationMarkerExtent,
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: AnimatedContainer(
                            key: ValueKey('turn-navigation-bar-$index'),
                            duration: const Duration(milliseconds: 220),
                            curve: Curves.easeOutQuart,
                            width:
                                _turnNavigationIdleBarWidth +
                                (_turnNavigationHoverBarWidth -
                                        _turnNavigationIdleBarWidth) *
                                    hoverInfluence,
                            height: isActive || hoverInfluence > 0.65 ? 3 : 2,
                            decoration: BoxDecoration(
                              color: Color.lerp(
                                baseColor,
                                AppColors.textSecondary,
                                hoverInfluence,
                              ),
                              borderRadius: BorderRadius.circular(
                                AppRadius.pill,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }

  double _hoverInfluence(int index) {
    final hoveredIndex = widget.hoveredIndex;
    if (hoveredIndex == null) return 0;
    return switch ((index - hoveredIndex).abs()) {
      0 => 1,
      1 => 0.58,
      2 => 0.3,
      3 => 0.12,
      _ => 0,
    };
  }
}

class _TurnNavigationPreview extends StatelessWidget {
  const _TurnNavigationPreview({super.key, required this.entry});

  final _TurnOutlineEntry entry;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('turn-navigation-preview'),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 15),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.xl),
        border: Border.all(color: AppColors.border),
        boxShadow: AppShadows.raised,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            entry.promptPreview,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 13.5,
              height: 1.4,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 7),
          Text(
            entry.responsePreview,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12.5,
              height: 1.5,
              fontWeight: FontWeight.w400,
            ),
          ),
        ],
      ),
    );
  }
}

class _ProcessedTurnHeader extends StatelessWidget {
  const _ProcessedTurnHeader({
    required this.label,
    required this.expanded,
    required this.onPressed,
  });

  final String label;
  final bool expanded;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      key: const ValueKey('processed-turn-toggle'),
      button: true,
      expanded: expanded,
      label: expanded ? 'Collapse processed turn' : 'Expand processed turn',
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(
            children: [
              Text(
                label,
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 13,
                  height: 1.35,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(width: 4),
              AnimatedRotation(
                turns: expanded ? 0.25 : 0,
                duration: const Duration(milliseconds: 160),
                child: const Icon(
                  Icons.chevron_right_rounded,
                  size: 16,
                  color: AppColors.textTertiary,
                ),
              ),
              const SizedBox(width: 10),
              const Expanded(child: Divider(color: AppColors.borderSoft)),
            ],
          ),
        ),
      ),
    );
  }
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

class _CodeCardIllustration extends StatelessWidget {
  const _CodeCardIllustration({required this.compact});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: compact ? 40 : 46,
      height: compact ? 40 : 46,
      decoration: BoxDecoration(
        color: AppColors.surfaceRaised,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.border),
      ),
      child: Icon(
        Icons.terminal_rounded,
        color: AppColors.textSecondary,
        size: compact ? 19 : 22,
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.inputBudget,
    required this.onTapLink,
    this.onMemoryFeedback,
  });

  final ChatMessage message;
  final AcpInputBudget inputBudget;
  final MarkdownTapLinkCallback? onTapLink;
  final MemoryFeedbackCallback? onMemoryFeedback;

  @override
  Widget build(BuildContext context) {
    if (message.metadata['kind'] == 'assistant_summary') {
      return _AssistantSummaryBubble(
        message: message,
        inputBudget: inputBudget,
        onTapLink: onTapLink,
      );
    }
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
    final assistant = message.role == ChatMessageRole.assistant;
    final color = switch (message.role) {
      ChatMessageRole.user => AppColors.userMessageSurface,
      ChatMessageRole.assistant => Colors.transparent,
      ChatMessageRole.tool => const Color(0xfffffbeb),
      ChatMessageRole.error => const Color(0xfffef2f2),
      ChatMessageRole.status => AppColors.surfaceRaised,
    };
    final borderColor = switch (message.role) {
      ChatMessageRole.user => Colors.transparent,
      ChatMessageRole.assistant => Colors.transparent,
      ChatMessageRole.tool => const Color(0xfffde68a),
      ChatMessageRole.error => const Color(0xfffecaca),
      ChatMessageRole.status => AppColors.border,
    };
    const textColor = AppColors.textPrimary;
    final displayText = user
        ? _userPromptDisplayText(message.text)
        : message.text;
    final markdownDecision = displayText.isEmpty
        ? null
        : scanMarkdownForRendering(displayText, budget: inputBudget);
    final omissions = _distinctOmissions(
      message.omissions,
      markdownDecision?.omission,
    );

    if (user) {
      final hasContentBlocks =
          _lazyMapCount(message.metadata['contentBlocks']) > 0;
      return Align(
        alignment: Alignment.centerRight,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (hasContentBlocks)
                _ContentBlocksPreview(
                  message: message,
                  inputBudget: inputBudget,
                  previewRevision: message.revision,
                  beforeText: true,
                  compactImages: true,
                ),
              if (hasContentBlocks &&
                  (markdownDecision != null || omissions.isNotEmpty))
                const SizedBox(height: 8),
              if (markdownDecision != null || omissions.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.userMessageSurface,
                    borderRadius: BorderRadius.circular(AppRadius.xl),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (markdownDecision != null)
                        if (markdownDecision.useMarkdown)
                          _SelectableMessageMarkdown(
                            data: markdownDecision.text,
                            user: true,
                            styleSheet: _markdownStyle(
                              context,
                              textColor,
                              true,
                            ),
                            onTapLink: onTapLink,
                          )
                        else
                          SelectableText(
                            markdownDecision.text,
                            style: const TextStyle(
                              color: textColor,
                              fontSize: 14,
                              height: 1.5,
                              fontWeight: FontWeight.w400,
                            ),
                          ),
                      for (final omission in omissions)
                        _InputOmissionNotice(omission: omission, user: true),
                    ],
                  ),
                ),
            ],
          ),
        ),
      );
    }

    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 820),
        child: Container(
          width: double.infinity,
          padding: assistant
              ? const EdgeInsets.symmetric(vertical: 6)
              : const EdgeInsets.all(11),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(AppRadius.sm),
            border: Border.all(color: borderColor),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!user && !assistant)
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Icon(
                      _iconForRole(message.role),
                      size: 14,
                      color: _labelColor(message.role),
                    ),
                    Text(
                      _labelForRole(message.role),
                      style: TextStyle(
                        color: _labelColor(message.role),
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                        letterSpacing: 0,
                      ),
                    ),
                  ],
                ),
              if (markdownDecision != null) ...[
                if (!user && !assistant) const SizedBox(height: 6),
                if (markdownDecision.useMarkdown)
                  _SelectableMessageMarkdown(
                    data: markdownDecision.text,
                    user: user,
                    styleSheet: _markdownStyle(context, textColor, user),
                    onTapLink: onTapLink,
                  )
                else
                  SelectableText(
                    markdownDecision.text,
                    style: const TextStyle(
                      color: textColor,
                      fontSize: 14,
                      height: 1.55,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
              ],
              for (final omission in omissions)
                _InputOmissionNotice(omission: omission, user: user),
              _ContentBlocksPreview(
                message: message,
                inputBudget: inputBudget,
                previewRevision: message.revision,
              ),
              _MemoryUsedPreview(
                message: message,
                onMemoryFeedback: onMemoryFeedback,
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
    final baseTextStyle = TextStyle(
      color: textColor,
      fontSize: 14,
      height: 1.55,
      fontWeight: FontWeight.w400,
    );
    final codeBackground = user
        ? AppColors.surface.withValues(alpha: 0.72)
        : AppColors.surfaceRaised;
    return MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
      p: baseTextStyle,
      a: baseTextStyle.copyWith(
        color: AppColors.textPrimary,
        backgroundColor: user
            ? AppColors.surface.withValues(alpha: 0.62)
            : AppColors.primaryMist,
        decoration: TextDecoration.underline,
        decorationColor: user
            ? AppColors.textSecondary
            : AppColors.primary.withValues(alpha: 0.55),
        fontWeight: FontWeight.w700,
      ),
      strong: baseTextStyle.copyWith(fontWeight: FontWeight.w700),
      em: baseTextStyle.copyWith(fontStyle: FontStyle.italic),
      code: baseTextStyle.copyWith(
        fontFamily: 'monospace',
        backgroundColor: codeBackground,
        fontSize: 12.5,
      ),
      listBullet: baseTextStyle,
      blockSpacing: 8,
      listIndent: 24,
      codeblockPadding: const EdgeInsets.all(7),
      codeblockDecoration: BoxDecoration(
        color: codeBackground,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: AppColors.border),
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

class _AssistantSummaryBubble extends StatelessWidget {
  const _AssistantSummaryBubble({
    required this.message,
    required this.inputBudget,
    required this.onTapLink,
  });

  final ChatMessage message;
  final AcpInputBudget inputBudget;
  final MarkdownTapLinkCallback? onTapLink;

  @override
  Widget build(BuildContext context) {
    final decision = scanMarkdownForRendering(
      message.text,
      budget: inputBudget,
    );
    return Padding(
      key: const ValueKey('assistant-turn-summary'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (decision.useMarkdown)
            _SelectableMessageMarkdown(
              data: decision.text,
              user: false,
              styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context))
                  .copyWith(
                    p: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 14,
                      height: 1.55,
                      fontWeight: FontWeight.w400,
                    ),
                    listBullet: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 14,
                      height: 1.55,
                    ),
                    blockSpacing: 8,
                    listIndent: 22,
                  ),
              onTapLink: onTapLink,
            )
          else
            SelectableText(
              decision.text,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 14,
                height: 1.55,
                fontWeight: FontWeight.w400,
              ),
            ),
        ],
      ),
    );
  }
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
    required this.onTapLink,
  });

  final String data;
  final bool user;
  final MarkdownStyleSheet styleSheet;
  final MarkdownTapLinkCallback? onTapLink;

  @override
  Widget build(BuildContext context) {
    final markdown = MarkdownBody(
      data: data,
      selectable: true,
      styleSheet: styleSheet,
      onTapLink: onTapLink,
      imageBuilder: _blockedMarkdownImage,
      builders: <String, MarkdownElementBuilder>{
        'pre': MarkdownCodeBlockBuilder(user: user),
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

class _ToolBubble extends StatelessWidget {
  const _ToolBubble({required this.message, required this.inputBudget});

  final ChatMessage message;
  final AcpInputBudget inputBudget;

  @override
  Widget build(BuildContext context) {
    final parsed = _ParsedTool.fromMessage(message);
    final images = _toolImageBlocks(parsed.content);
    final diffs = _toolDiffs(parsed.content);
    if (images.isNotEmpty || diffs.isNotEmpty) {
      final statusSummary = _ToolGroupStatusSummary.from([parsed]);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (images.isNotEmpty)
            _ToolImageActivity(images: images, statusSummary: statusSummary),
          if (images.isNotEmpty && diffs.isNotEmpty) const SizedBox(height: 8),
          if (diffs.isNotEmpty)
            _ToolDiffActivity(diffs: diffs, statusSummary: statusSummary),
        ],
      );
    }
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
    final richMessages = <ChatMessage>[];
    final ordinaryMessages = <ChatMessage>[];
    final imageBlocks = <Map<String, Object?>>[];
    final diffs = <_ToolDiffProjection>[];
    for (var index = 0; index < messages.length; index++) {
      final images = _toolImageBlocks(parsedTools[index].content);
      final toolDiffs = _toolDiffs(parsedTools[index].content);
      if (images.isEmpty && toolDiffs.isEmpty) {
        ordinaryMessages.add(messages[index]);
      } else {
        richMessages.add(messages[index]);
        imageBlocks.addAll(images);
        diffs.addAll(toolDiffs);
      }
    }
    if (imageBlocks.isNotEmpty || diffs.isNotEmpty) {
      final richTools = richMessages
          .map(_ParsedTool.fromMessage)
          .toList(growable: false);
      final statusSummary = _ToolGroupStatusSummary.from(richTools);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (imageBlocks.isNotEmpty)
            _ToolImageActivity(
              images: imageBlocks,
              statusSummary: statusSummary,
            ),
          if (imageBlocks.isNotEmpty && diffs.isNotEmpty)
            const SizedBox(height: 8),
          if (diffs.isNotEmpty)
            _ToolDiffActivity(diffs: diffs, statusSummary: statusSummary),
          if (ordinaryMessages.isNotEmpty) const SizedBox(height: 8),
          if (ordinaryMessages.length == 1)
            _ToolBubble(
              message: ordinaryMessages.single,
              inputBudget: inputBudget,
            )
          else if (ordinaryMessages.length > 1)
            _ToolGroupBubble(
              messages: ordinaryMessages,
              inputBudget: inputBudget,
            ),
        ],
      );
    }
    final statusSummary = _ToolGroupStatusSummary.from(parsedTools);

    return _ToolFrame(
      child: _ToolGroupDisclosure(
        parsedTools: parsedTools,
        statusSummary: statusSummary,
      ),
    );
  }
}

class _ToolImageActivity extends StatefulWidget {
  const _ToolImageActivity({required this.images, required this.statusSummary});

  final List<Map<String, Object?>> images;
  final _ToolGroupStatusSummary statusSummary;

  @override
  State<_ToolImageActivity> createState() => _ToolImageActivityState();
}

class _ToolImageActivityState extends State<_ToolImageActivity> {
  var _expanded = false;

  @override
  Widget build(BuildContext context) {
    final visibleCount = widget.images.length.clamp(0, 4);
    final complete = widget.statusSummary.label == 'completed';
    return _ToolFrame(
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: Material(
          color: Colors.transparent,
          child: ExpansionTile(
            key: const ValueKey('tool-image-activity-toggle'),
            initiallyExpanded: false,
            maintainState: true,
            tilePadding: const EdgeInsets.symmetric(horizontal: 2),
            childrenPadding: const EdgeInsets.fromLTRB(2, 0, 2, 8),
            onExpansionChanged: (value) => setState(() => _expanded = value),
            leading: const Icon(
              Icons.photo_library_outlined,
              size: 17,
              color: AppColors.textSecondary,
            ),
            title: Text(
              '${complete ? 'Viewed' : 'Viewing'} ${widget.images.length} '
              'image${widget.images.length == 1 ? '' : 's'}',
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
            children: !_expanded
                ? const <Widget>[]
                : [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (var index = 0; index < visibleCount; index++)
                            _ImageContentBlock(
                              block: widget.images[index],
                              compact: true,
                            ),
                          if (widget.images.length > visibleCount)
                            Container(
                              width: 116,
                              height: 116,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: AppColors.surfaceRaised,
                                borderRadius: BorderRadius.circular(
                                  AppRadius.lg,
                                ),
                                border: Border.all(color: AppColors.border),
                              ),
                              child: Text(
                                '+${widget.images.length - visibleCount}',
                                style: const TextStyle(
                                  color: AppColors.textSecondary,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
          ),
        ),
      ),
    );
  }
}

class _ToolDiffActivity extends StatefulWidget {
  const _ToolDiffActivity({required this.diffs, required this.statusSummary});

  final List<_ToolDiffProjection> diffs;
  final _ToolGroupStatusSummary statusSummary;

  @override
  State<_ToolDiffActivity> createState() => _ToolDiffActivityState();
}

class _ToolDiffActivityState extends State<_ToolDiffActivity> {
  var _expanded = false;

  @override
  Widget build(BuildContext context) {
    final additionCount = widget.diffs.fold<int>(
      0,
      (total, diff) => total + diff.additionCount,
    );
    final deletionCount = widget.diffs.fold<int>(
      0,
      (total, diff) => total + diff.deletionCount,
    );
    return _ToolFrame(
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: Material(
          color: Colors.transparent,
          child: ExpansionTile(
            key: const ValueKey('tool-diff-activity-toggle'),
            initiallyExpanded: false,
            maintainState: true,
            tilePadding: const EdgeInsets.symmetric(horizontal: 2),
            childrenPadding: const EdgeInsets.fromLTRB(2, 0, 2, 8),
            onExpansionChanged: (value) => setState(() => _expanded = value),
            leading: const Icon(
              Icons.edit_note_outlined,
              size: 18,
              color: AppColors.textSecondary,
            ),
            title: Row(
              children: [
                Expanded(
                  child: Text(
                    '${widget.diffs.length} file'
                    '${widget.diffs.length == 1 ? '' : 's'} edited',
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(
                  '+$additionCount',
                  style: const TextStyle(
                    color: AppColors.success,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '-$deletionCount',
                  style: const TextStyle(
                    color: AppColors.danger,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
            children: !_expanded
                ? const <Widget>[]
                : [
                    for (
                      var index = 0;
                      index < widget.diffs.length;
                      index++
                    ) ...[
                      _ToolDiffCard(diff: widget.diffs[index]),
                      if (index != widget.diffs.length - 1)
                        const SizedBox(height: 8),
                    ],
                  ],
          ),
        ),
      ),
    );
  }
}

class _ToolDiffCard extends StatelessWidget {
  const _ToolDiffCard({required this.diff});

  final _ToolDiffProjection diff;

  @override
  Widget build(BuildContext context) {
    final lines = diff.visibleLines;
    return Container(
      width: double.infinity,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(11, 7, 5, 7),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    diff.path,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(
                  '+${diff.additionCount}',
                  style: const TextStyle(
                    color: AppColors.success,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(width: 5),
                Text(
                  '-${diff.deletionCount}',
                  style: const TextStyle(
                    color: AppColors.danger,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                IconButton(
                  key: ValueKey('copy-tool-diff-${diff.path}'),
                  tooltip: 'Copy diff',
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints.tightFor(
                    width: 30,
                    height: 30,
                  ),
                  onPressed: () => Clipboard.setData(
                    ClipboardData(text: diff.clipboardText),
                  ),
                  icon: const Icon(Icons.copy_all_outlined, size: 15),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: AppColors.borderSoft),
          SizedBox(
            height: _boundedNestedListHeight(
              itemCount: lines.length,
              estimatedItemHeight: 23,
              maxHeight: _nestedDetailsMaxHeight,
            ),
            child: ListView.builder(
              key: ValueKey('tool-diff-lines-${diff.path}'),
              primary: false,
              itemCount: lines.length,
              itemBuilder: (context, index) =>
                  _UnifiedDiffLineRow(line: lines[index]),
            ),
          ),
        ],
      ),
    );
  }
}

class _UnifiedDiffLineRow extends StatelessWidget {
  const _UnifiedDiffLineRow({required this.line});

  final _UnifiedDiffLine line;

  @override
  Widget build(BuildContext context) {
    final background = switch (line.kind) {
      _UnifiedDiffLineKind.addition => AppColors.success.withValues(
        alpha: 0.10,
      ),
      _UnifiedDiffLineKind.deletion => AppColors.danger.withValues(alpha: 0.09),
      _UnifiedDiffLineKind.context => Colors.transparent,
    };
    final accent = switch (line.kind) {
      _UnifiedDiffLineKind.addition => AppColors.success,
      _UnifiedDiffLineKind.deletion => AppColors.danger,
      _UnifiedDiffLineKind.context => AppColors.textTertiary,
    };
    final marker = switch (line.kind) {
      _UnifiedDiffLineKind.addition => '+',
      _UnifiedDiffLineKind.deletion => '-',
      _UnifiedDiffLineKind.context => ' ',
    };
    return ColoredBox(
      color: background,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _DiffLineNumber(value: line.oldLine),
          _DiffLineNumber(value: line.newLine),
          SizedBox(
            width: 18,
            child: Text(
              marker,
              style: TextStyle(
                color: accent,
                fontFamily: 'monospace',
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          Expanded(
            child: Text(
              line.text,
              softWrap: false,
              overflow: TextOverflow.fade,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontFamily: 'monospace',
                fontSize: 11,
                height: 1.55,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DiffLineNumber extends StatelessWidget {
  const _DiffLineNumber({required this.value});

  final int? value;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 38,
      padding: const EdgeInsets.only(right: 6),
      alignment: Alignment.topRight,
      child: Text(
        value?.toString() ?? '',
        style: const TextStyle(
          color: AppColors.textTertiary,
          fontFamily: 'monospace',
          fontSize: 10,
          height: 1.7,
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
        constraints: const BoxConstraints(maxWidth: 760),
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
        color: AppColors.surfaceRaised,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: AppColors.border),
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
                    color: AppColors.textSecondary,
                    size: 16,
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

class _ToolGroupDisclosure extends StatefulWidget {
  const _ToolGroupDisclosure({
    required this.parsedTools,
    required this.statusSummary,
  });

  final List<_ParsedTool> parsedTools;
  final _ToolGroupStatusSummary statusSummary;

  @override
  State<_ToolGroupDisclosure> createState() => _ToolGroupDisclosureState();
}

class _ToolGroupDisclosureState extends State<_ToolGroupDisclosure> {
  var _hovered = false;
  var _expanded = false;

  @override
  Widget build(BuildContext context) {
    final foreground = _hovered && !_expanded
        ? AppColors.textPrimary
        : AppColors.textSecondary;
    final showChevron = _hovered || _expanded;
    final statusLabel = widget.statusSummary.label == 'completed'
        ? null
        : _humanizeStatus(widget.statusSummary.label);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: Semantics(
            button: true,
            expanded: _expanded,
            label: _toolGroupActivitySummary(widget.parsedTools),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                key: const ValueKey('tool-call-group-toggle'),
                borderRadius: BorderRadius.circular(AppRadius.sm),
                hoverColor: Colors.transparent,
                splashColor: Colors.transparent,
                highlightColor: Colors.transparent,
                onTap: () => setState(() => _expanded = !_expanded),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TweenAnimationBuilder<Color?>(
                        duration: const Duration(milliseconds: 150),
                        curve: Curves.easeOutCubic,
                        tween: ColorTween(end: foreground),
                        builder: (context, color, child) => Icon(
                          _toolGroupActivityIcon(widget.parsedTools),
                          color: color,
                          size: 18,
                        ),
                      ),
                      const SizedBox(width: 9),
                      Flexible(
                        child: AnimatedDefaultTextStyle(
                          key: const ValueKey('tool-call-group-summary'),
                          duration: const Duration(milliseconds: 150),
                          curve: Curves.easeOutCubic,
                          style: TextStyle(
                            color: foreground,
                            fontSize: 13.5,
                            height: 1.3,
                            fontWeight: _hovered && !_expanded
                                ? FontWeight.w700
                                : FontWeight.w600,
                            letterSpacing: 0,
                          ),
                          child: Text(
                            _toolGroupActivitySummary(widget.parsedTools),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                      if (statusLabel != null) ...[
                        const SizedBox(width: 8),
                        Text(
                          statusLabel,
                          style: TextStyle(
                            color: widget.statusSummary.color,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                      const SizedBox(width: 3),
                      AnimatedOpacity(
                        key: const ValueKey('tool-call-group-chevron-opacity'),
                        duration: const Duration(milliseconds: 120),
                        curve: Curves.easeOut,
                        opacity: showChevron ? 1 : 0,
                        child: AnimatedRotation(
                          key: const ValueKey('tool-call-group-chevron'),
                          duration: const Duration(milliseconds: 160),
                          curve: Curves.easeOutCubic,
                          turns: _expanded ? 0.25 : 0,
                          child: Icon(
                            Icons.chevron_right_rounded,
                            size: 18,
                            color: foreground,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: _expanded
              ? Padding(
                  key: const ValueKey('tool-call-group-details'),
                  padding: const EdgeInsets.fromLTRB(0, 5, 0, 7),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final tool in widget.parsedTools)
                        _ToolActivityRow(
                          presentation: _toolActivityPresentation(tool),
                          status: tool.status,
                        ),
                    ],
                  ),
                )
              : const SizedBox.shrink(
                  key: ValueKey('tool-call-group-details-collapsed'),
                ),
        ),
      ],
    );
  }
}

class _ToolActivityRow extends StatelessWidget {
  const _ToolActivityRow({required this.presentation, required this.status});

  final _ToolActivityPresentation presentation;
  final String status;

  @override
  Widget build(BuildContext context) {
    final statusKind = _toolGroupStatusKind(status);
    final statusLabel = statusKind == _ToolGroupStatusKind.completed
        ? null
        : _humanizeStatus(status);
    return Semantics(
      label: presentation.semanticLabel,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(presentation.icon, size: 17, color: AppColors.textSecondary),
            const SizedBox(width: 9),
            Expanded(
              child: Tooltip(
                message: presentation.semanticLabel,
                waitDuration: const Duration(milliseconds: 450),
                child: Text.rich(
                  TextSpan(
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 13,
                      height: 1.35,
                      fontWeight: FontWeight.w500,
                    ),
                    children: [
                      TextSpan(text: presentation.action),
                      if (presentation.subject.isNotEmpty) ...[
                        const TextSpan(text: ' '),
                        TextSpan(
                          text: presentation.subject,
                          style: TextStyle(
                            decoration: presentation.linkSubject
                                ? TextDecoration.underline
                                : TextDecoration.none,
                            decorationColor: AppColors.textTertiary,
                            decorationStyle: TextDecorationStyle.dotted,
                          ),
                        ),
                      ],
                      if (presentation.suffix.isNotEmpty)
                        TextSpan(text: ' ${presentation.suffix}'),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            if (statusLabel != null) ...[
              const SizedBox(width: 8),
              Text(
                statusLabel,
                style: TextStyle(
                  color: _statusColor(status),
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

enum _ToolActivityKind {
  load,
  read,
  edit,
  run,
  search,
  interact,
  wait,
  context,
  generic,
}

class _ToolActivityPresentation {
  const _ToolActivityPresentation({
    required this.kind,
    required this.icon,
    required this.action,
    required this.subject,
    this.suffix = '',
    this.linkSubject = false,
  });

  final _ToolActivityKind kind;
  final IconData icon;
  final String action;
  final String subject;
  final String suffix;
  final bool linkSubject;

  String get semanticLabel => [
    action,
    if (subject.isNotEmpty) subject,
    if (suffix.isNotEmpty) suffix,
  ].join(' ');
}

_ToolActivityPresentation _toolActivityPresentation(_ParsedTool tool) {
  final kind = _toolActivityKind(tool);
  final input = _objectMap(tool.input);
  final diffs = _toolDiffs(tool.content);
  final path = _toolFilePath(tool, input, diffs);
  final subject = switch (kind) {
    _ToolActivityKind.read || _ToolActivityKind.edit => path,
    _ToolActivityKind.run => _toolCommand(tool, input),
    _ToolActivityKind.search => _firstNonEmptyString(input, const [
      'q',
      'query',
      'pattern',
      'search_term',
    ]),
    _ToolActivityKind.interact => 'the app',
    _ToolActivityKind.wait => 'for background work',
    _ToolActivityKind.context => 'context',
    _ToolActivityKind.load => _firstNonEmptyString(input, const [
      'name',
      'skill',
      'tool',
      'path',
    ]),
    _ToolActivityKind.generic => tool.title,
  };
  final additions = diffs.fold<int>(0, (sum, diff) => sum + diff.additionCount);
  final deletions = diffs.fold<int>(0, (sum, diff) => sum + diff.deletionCount);
  final suffix = additions == 0 && deletions == 0
      ? ''
      : '+$additions -$deletions';
  return switch (kind) {
    _ToolActivityKind.load => _ToolActivityPresentation(
      kind: kind,
      icon: Icons.extension_outlined,
      action: 'Loaded',
      subject: subject,
    ),
    _ToolActivityKind.read => _ToolActivityPresentation(
      kind: kind,
      icon: Icons.menu_book_outlined,
      action: 'Read',
      subject: subject,
      linkSubject: subject.isNotEmpty,
    ),
    _ToolActivityKind.edit => _ToolActivityPresentation(
      kind: kind,
      icon: Icons.edit_outlined,
      action: 'Edited',
      subject: subject,
      suffix: suffix,
      linkSubject: subject.isNotEmpty,
    ),
    _ToolActivityKind.run => _ToolActivityPresentation(
      kind: kind,
      icon: Icons.terminal_rounded,
      action: 'Ran',
      subject: subject,
    ),
    _ToolActivityKind.search => _ToolActivityPresentation(
      kind: kind,
      icon: Icons.search_rounded,
      action: 'Searched',
      subject: subject,
    ),
    _ToolActivityKind.interact => _ToolActivityPresentation(
      kind: kind,
      icon: Icons.touch_app_outlined,
      action: 'Controlled',
      subject: subject,
    ),
    _ToolActivityKind.wait => _ToolActivityPresentation(
      kind: kind,
      icon: Icons.schedule_rounded,
      action: 'Waited',
      subject: subject,
    ),
    _ToolActivityKind.context => _ToolActivityPresentation(
      kind: kind,
      icon: Icons.compress_rounded,
      action: 'Compacted',
      subject: subject,
    ),
    _ToolActivityKind.generic => _ToolActivityPresentation(
      kind: kind,
      icon: Icons.build_outlined,
      action: 'Used',
      subject: subject,
    ),
  };
}

_ToolActivityKind _toolActivityKind(_ParsedTool tool) {
  final title = tool.title.toLowerCase();
  if (title.contains('node_repl') ||
      title.contains('computer_use') ||
      title.contains('computer-use')) {
    return _ToolActivityKind.interact;
  }
  if (title == 'wait' || title.endsWith('.wait')) {
    return _ToolActivityKind.wait;
  }
  if (title.contains('context compact')) {
    return _ToolActivityKind.context;
  }
  if (title.contains('edit') ||
      title.contains('write') ||
      title.contains('patch') ||
      title.contains('create_file')) {
    return _ToolActivityKind.edit;
  }
  if (title == 'read' ||
      title.contains('read_file') ||
      title.contains('view_file') ||
      title.contains('open_file')) {
    return _ToolActivityKind.read;
  }
  if (title.contains('exec') ||
      title.contains('command') ||
      title.contains('shell') ||
      title.contains('bash') ||
      title.contains('terminal') ||
      title.contains('write_stdin')) {
    return _ToolActivityKind.run;
  }
  if (title.contains('search') || title == 'find' || title.contains('grep')) {
    return _ToolActivityKind.search;
  }
  if (title.contains('load') ||
      title.contains('skill') ||
      title.contains('tool_search')) {
    return _ToolActivityKind.load;
  }
  return _ToolActivityKind.generic;
}

String _toolFilePath(
  _ParsedTool tool,
  Map<String, Object?> input,
  List<_ToolDiffProjection> diffs,
) {
  final direct = _firstNonEmptyString(input, const [
    'path',
    'file_path',
    'filePath',
    'filename',
    'file',
  ]);
  final candidate = direct.isNotEmpty
      ? direct
      : diffs.isNotEmpty
      ? diffs.first.path
      : tool.locations.isNotEmpty
      ? tool.locations.first.split(':').first
      : _patchFilePath(tool.input);
  if (candidate.isEmpty) return '';
  final normalized = candidate.replaceAll('\\', '/');
  final parts = normalized.split('/').where((part) => part.isNotEmpty).toList();
  return parts.isEmpty ? candidate : parts.last;
}

String _patchFilePath(Object? input) {
  if (input is! String) return '';
  final match = RegExp(
    r'^\*\*\* (?:Update|Add|Delete) File:\s*(.+)$',
    multiLine: true,
  ).firstMatch(input);
  return match?.group(1)?.trim() ?? '';
}

String _toolCommand(_ParsedTool tool, Map<String, Object?> input) {
  final command = _firstNonEmptyString(input, const ['cmd', 'command']);
  if (command.isNotEmpty) return command;
  return tool.title;
}

String _firstNonEmptyString(Map<String, Object?> input, List<String> keys) {
  for (final key in keys) {
    final value = input[key];
    if (value is String && value.trim().isNotEmpty) return value.trim();
  }
  return '';
}

String _toolGroupActivitySummary(List<_ParsedTool> tools) {
  final kinds = tools.map(_toolActivityKind).toSet();
  final activities = <String>[
    if (kinds.contains(_ToolActivityKind.load)) 'loaded tools',
    if (kinds.contains(_ToolActivityKind.edit)) 'edited files',
    if (kinds.contains(_ToolActivityKind.read)) 'read files',
    if (kinds.contains(_ToolActivityKind.run)) 'ran commands',
    if (kinds.contains(_ToolActivityKind.search)) 'searched',
    if (kinds.contains(_ToolActivityKind.interact)) 'controlled the app',
    if (kinds.contains(_ToolActivityKind.wait)) 'waited for background work',
    if (kinds.contains(_ToolActivityKind.context)) 'compacted context',
  ];
  if (activities.isEmpty) {
    final titles = tools.map((tool) => tool.title).toSet();
    if (titles.length == 1) return 'Used ${titles.single}';
    return 'Used ${tools.length} tools';
  }
  final sentence = _naturalLanguageList(activities);
  return sentence[0].toUpperCase() + sentence.substring(1);
}

String _naturalLanguageList(List<String> items) {
  if (items.length == 1) return items.single;
  if (items.length == 2) return '${items.first} and ${items.last}';
  return '${items.take(items.length - 1).join(', ')}, and ${items.last}';
}

IconData _toolGroupActivityIcon(List<_ParsedTool> tools) {
  final edited = tools.any(
    (tool) => _toolActivityKind(tool) == _ToolActivityKind.edit,
  );
  return edited ? Icons.edit_outlined : Icons.build_outlined;
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
            color: AppColors.textSecondary,
            size: 18,
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
                  color: AppColors.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
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
    final minimal = kind == 'thought' || kind == 'turn';
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
          padding: minimal
              ? const EdgeInsets.symmetric(vertical: 5)
              : const EdgeInsets.all(10),
          decoration: minimal
              ? null
              : BoxDecoration(
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
          const SizedBox(height: 4),
          Text(
            _thoughtText(message.text),
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

String _thoughtText(String value) {
  return value
      .replaceAll(RegExp(r'\*{4,}'), ' · ')
      .replaceAll('**', '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
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

class _MemoryUsedPreview extends StatelessWidget {
  const _MemoryUsedPreview({
    required this.message,
    required this.onMemoryFeedback,
  });

  final ChatMessage message;
  final MemoryFeedbackCallback? onMemoryFeedback;

  @override
  Widget build(BuildContext context) {
    final memories = _mapList(message.metadata['memoryUsed'])
        .where((item) => _stringMetadata(item, 'id') != null)
        .toList(growable: false);
    if (memories.isEmpty) return const SizedBox.shrink();

    final turnId = _stringMetadata(message.metadata, 'memoryTurnId');
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: const Color(0xffddd6fe)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.memory_outlined,
                size: 15,
                color: AppColors.primary,
              ),
              const SizedBox(width: 6),
              Text(
                'Memory used · ${memories.length}',
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final memory in memories) ...[
            _MemoryUsedRow(
              memory: memory,
              turnId: turnId,
              onMemoryFeedback: onMemoryFeedback,
            ),
            if (memory != memories.last) const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}

class _MemoryUsedRow extends StatelessWidget {
  const _MemoryUsedRow({
    required this.memory,
    required this.turnId,
    required this.onMemoryFeedback,
  });

  final Map<String, Object?> memory;
  final String? turnId;
  final MemoryFeedbackCallback? onMemoryFeedback;

  @override
  Widget build(BuildContext context) {
    final memoryId = _stringMetadata(memory, 'id') ?? '';
    final kind = _stringMetadata(memory, 'kind') ?? 'memory';
    final scope = _stringMetadata(memory, 'scope') ?? 'scope';
    final text = _stringMetadata(memory, 'text') ?? memoryId;
    final score = memory['score'];
    final scoreLabel = score is num ? ' · ${(score * 100).round()}%' : '';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$kind · $scope$scoreLabel',
          style: const TextStyle(
            color: AppColors.textSecondary,
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 0,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          text,
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontSize: 12,
            height: 1.35,
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            _MemoryFeedbackButton(
              label: 'Helpful',
              memoryId: memoryId,
              rating: 'helpful',
              turnId: turnId,
              onMemoryFeedback: onMemoryFeedback,
            ),
            _MemoryFeedbackButton(
              label: 'Not relevant',
              memoryId: memoryId,
              rating: 'not_relevant',
              turnId: turnId,
              reason: 'Marked not relevant from chat timeline.',
              onMemoryFeedback: onMemoryFeedback,
            ),
            _MemoryFeedbackButton(
              label: 'Stale',
              memoryId: memoryId,
              rating: 'stale',
              turnId: turnId,
              reason: 'Marked stale from chat timeline.',
              onMemoryFeedback: onMemoryFeedback,
            ),
          ],
        ),
      ],
    );
  }
}

class _MemoryFeedbackButton extends StatelessWidget {
  const _MemoryFeedbackButton({
    required this.label,
    required this.memoryId,
    required this.rating,
    required this.turnId,
    required this.onMemoryFeedback,
    this.reason,
  });

  final String label;
  final String memoryId;
  final String rating;
  final String? turnId;
  final String? reason;
  final MemoryFeedbackCallback? onMemoryFeedback;

  @override
  Widget build(BuildContext context) {
    final callback = onMemoryFeedback;
    return OutlinedButton(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 30),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        textStyle: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: 0,
        ),
        side: const BorderSide(color: Color(0xffc4b5fd)),
      ),
      onPressed: callback == null || memoryId.isEmpty
          ? null
          : () {
              unawaited(
                callback(
                  memoryId: memoryId,
                  rating: rating,
                  turnId: turnId,
                  reason: reason,
                ),
              );
            },
      child: Text(label),
    );
  }
}

class _ContentBlocksPreview extends StatefulWidget {
  const _ContentBlocksPreview({
    required this.message,
    required this.inputBudget,
    required this.previewRevision,
    this.beforeText = false,
    this.compactImages = false,
  });

  final ChatMessage message;
  final AcpInputBudget inputBudget;
  final Object previewRevision;
  final bool beforeText;
  final bool compactImages;

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
        padding: EdgeInsets.only(
          top: widget.beforeText || widget.message.text.isEmpty ? 0 : 8,
        ),
        child: const _ContentProjectionPendingNotice(),
      );
    }
    final hasPendingItems = !_projection.exhausted;
    final renderedItemCount =
        _projection.visibleCount + (hasPendingItems ? 1 : 0);

    return Padding(
      padding: EdgeInsets.only(
        top: widget.beforeText || widget.message.text.isEmpty ? 0 : 8,
      ),
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
                compactImage: widget.compactImages,
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
    this.compactImage = false,
  });

  final Map<String, Object?> block;
  final AcpInputBudget inputBudget;
  final Object previewRevision;
  final bool compactImage;

  @override
  Widget build(BuildContext context) {
    final type = _stringMetadata(block, 'type') ?? 'unknown';
    return switch (type) {
      'image' => Align(
        alignment: compactImage ? Alignment.centerRight : Alignment.centerLeft,
        child: _ImageContentBlock(block: block, compact: compactImage),
      ),
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
  const _ImageContentBlock({required this.block, this.compact = false});

  final Map<String, Object?> block;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final mimeType = _stringMetadata(block, 'mimeType') ?? 'image';
    final data = _stringMetadata(block, 'data');
    final imageDecode = _ImageDecodeScope.of(context);
    final preview = data == null
        ? const Center(child: Text('Image preview unavailable.'))
        : ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.md),
            child: BoundedImagePreview(
              data: data,
              inputBudget: imageDecode.inputBudget,
              imageDecodeLedger: imageDecode.ledger,
              decoder: imageDecode.decoder,
            ),
          );
    if (compact) {
      return Container(
        key: const ValueKey('inline-image-thumbnail'),
        width: 116,
        height: 116,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(color: AppColors.border),
        ),
        child: preview,
      );
    }
    return _InlineContentFrame(
      icon: Icons.image_outlined,
      title: 'Image',
      subtitle: '$mimeType${data == null ? '' : ' · ${data.length} chars'}',
      child: preview,
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
          key: const ValueKey('diff-changes-toggle'),
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

List<Map<String, Object?>> _toolImageBlocks(Object? content) {
  final images = <Map<String, Object?>>[];
  for (final item in _mapList(content)) {
    Map<String, Object?> block;
    if (_stringMetadata(item, 'type') == 'content') {
      block = _objectMap(item['content']);
    } else {
      block = item;
    }
    if (_stringMetadata(block, 'type') == 'image') {
      images.add(block);
    }
  }
  return images;
}

List<_ToolDiffProjection> _toolDiffs(Object? content) {
  final diffs = <_ToolDiffProjection>[];
  for (final item in _mapList(content)) {
    if (_stringMetadata(item, 'type') != 'diff') continue;
    final path = _stringMetadata(item, 'path') ?? 'Edited file';
    final oldText = _nullableStringValue(
      _firstMetadataValue(item, const ['oldText', 'old_text']),
    );
    final newText = _nullableStringValue(
      _firstMetadataValue(item, const ['newText', 'new_text']),
    );
    diffs.add(
      _ToolDiffProjection(path: path, oldText: oldText, newText: newText),
    );
  }
  return diffs;
}

String? _nullableStringValue(Object? value) => value is String ? value : null;

enum _UnifiedDiffLineKind { context, addition, deletion }

class _UnifiedDiffLine {
  const _UnifiedDiffLine({
    required this.kind,
    required this.text,
    this.oldLine,
    this.newLine,
  });

  final _UnifiedDiffLineKind kind;
  final String text;
  final int? oldLine;
  final int? newLine;
}

class _ToolDiffProjection {
  _ToolDiffProjection({
    required this.path,
    required this.oldText,
    required this.newText,
  }) {
    final oldLines = _splitDiffText(oldText);
    final newLines = _splitDiffText(newText);
    var prefix = 0;
    while (prefix < oldLines.length &&
        prefix < newLines.length &&
        oldLines[prefix] == newLines[prefix]) {
      prefix += 1;
    }
    var suffix = 0;
    while (suffix < oldLines.length - prefix &&
        suffix < newLines.length - prefix &&
        oldLines[oldLines.length - suffix - 1] ==
            newLines[newLines.length - suffix - 1]) {
      suffix += 1;
    }

    additionCount = newLines.length - prefix - suffix;
    deletionCount = oldLines.length - prefix - suffix;
    final rows = <_UnifiedDiffLine>[];
    final contextStart = prefix > 2 ? prefix - 2 : 0;
    for (var index = contextStart; index < prefix; index++) {
      rows.add(
        _UnifiedDiffLine(
          kind: _UnifiedDiffLineKind.context,
          text: oldLines[index],
          oldLine: index + 1,
          newLine: index + 1,
        ),
      );
    }
    final oldChangedEnd = oldLines.length - suffix;
    for (var index = prefix; index < oldChangedEnd; index++) {
      rows.add(
        _UnifiedDiffLine(
          kind: _UnifiedDiffLineKind.deletion,
          text: oldLines[index],
          oldLine: index + 1,
        ),
      );
    }
    final newChangedEnd = newLines.length - suffix;
    for (var index = prefix; index < newChangedEnd; index++) {
      rows.add(
        _UnifiedDiffLine(
          kind: _UnifiedDiffLineKind.addition,
          text: newLines[index],
          newLine: index + 1,
        ),
      );
    }
    final visibleSuffix = suffix > 2 ? 2 : suffix;
    for (var offset = 0; offset < visibleSuffix; offset++) {
      final oldIndex = oldLines.length - suffix + offset;
      final newIndex = newLines.length - suffix + offset;
      rows.add(
        _UnifiedDiffLine(
          kind: _UnifiedDiffLineKind.context,
          text: oldLines[oldIndex],
          oldLine: oldIndex + 1,
          newLine: newIndex + 1,
        ),
      );
    }
    if (rows.isEmpty && oldLines.isNotEmpty) {
      rows.add(
        _UnifiedDiffLine(
          kind: _UnifiedDiffLineKind.context,
          text: oldLines.first,
          oldLine: 1,
          newLine: 1,
        ),
      );
    }
    visibleLines = _boundedDiffRows(rows);
    clipboardText = _buildClipboardDiff(
      path: path,
      rows: rows,
      oldText: oldText,
      newText: newText,
    );
  }

  final String path;
  final String? oldText;
  final String? newText;
  late final int additionCount;
  late final int deletionCount;
  late final List<_UnifiedDiffLine> visibleLines;
  late final String clipboardText;
}

List<String> _splitDiffText(String? text) {
  if (text == null || text.isEmpty) return const <String>[];
  final lines = text.split('\n');
  if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
  return lines;
}

List<_UnifiedDiffLine> _boundedDiffRows(List<_UnifiedDiffLine> rows) {
  const maxRows = 240;
  if (rows.length <= maxRows) return List.unmodifiable(rows);
  final omitted = rows.length - maxRows + 1;
  return List.unmodifiable([
    ...rows.take(119),
    _UnifiedDiffLine(
      kind: _UnifiedDiffLineKind.context,
      text: '… $omitted lines omitted …',
    ),
    ...rows.skip(rows.length - 120),
  ]);
}

String _buildClipboardDiff({
  required String path,
  required List<_UnifiedDiffLine> rows,
  required String? oldText,
  required String? newText,
}) {
  final buffer = StringBuffer()
    ..writeln('--- a/$path')
    ..writeln('+++ b/$path');
  for (final row in rows) {
    final marker = switch (row.kind) {
      _UnifiedDiffLineKind.addition => '+',
      _UnifiedDiffLineKind.deletion => '-',
      _UnifiedDiffLineKind.context => ' ',
    };
    buffer.writeln('$marker${row.text}');
  }
  if (rows.isEmpty && oldText != newText) {
    buffer
      ..writeln('-${oldText ?? ''}')
      ..writeln('+${newText ?? ''}');
  }
  return buffer.toString();
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
