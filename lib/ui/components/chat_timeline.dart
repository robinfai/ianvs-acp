import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../../state/chat_controller.dart';
import '../theme/app_design_tokens.dart';
import 'dot_grid_background.dart';

class ChatTimeline extends StatelessWidget {
  const ChatTimeline({
    super.key,
    required this.messages,
    this.agentName = 'Codex',
  });

  final List<ChatMessage> messages;
  final String agentName;

  @override
  Widget build(BuildContext context) {
    if (messages.isEmpty) {
      return DotGridBackground(
        child: Center(child: _EmptyTimeline(agentName: agentName)),
      );
    }

    final entries = _timelineEntries(messages);

    return DotGridBackground(
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(32, 28, 32, 32),
        itemCount: entries.length,
        separatorBuilder: (context, index) => const SizedBox(height: 16),
        itemBuilder: (context, index) {
          final entry = entries[index];
          return entry.toolMessages == null
              ? _MessageBubble(message: entry.message!)
              : _ToolGroupBubble(messages: entry.toolMessages!);
        },
      ),
    );
  }
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

    if (tools.length == 1) {
      entries.add(_TimelineEntry.message(tools.single));
    } else {
      entries.add(_TimelineEntry.toolGroup(tools));
    }
  }

  return entries;
}

class _TimelineEntry {
  const _TimelineEntry.message(this.message) : toolMessages = null;

  const _TimelineEntry.toolGroup(this.toolMessages) : message = null;

  final ChatMessage? message;
  final List<ChatMessage>? toolMessages;
}

class _EmptyTimeline extends StatelessWidget {
  const _EmptyTimeline({required this.agentName});

  final String agentName;

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
                    'Start a session to chat with $agentName',
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
    if (message.role == ChatMessageRole.tool) {
      return _ToolBubble(message: message);
    }
    if (message.role == ChatMessageRole.status &&
        _stringMetadata(message.metadata, 'kind') != null &&
        _stringMetadata(message.metadata, 'kind') != 'unknown') {
      return _StatusBubble(message: message);
    }

    final user = message.role == ChatMessageRole.user;
    final error = message.role == ChatMessageRole.error;
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
        constraints: BoxConstraints(maxWidth: user ? 720 : 820),
        child: Container(
          width: user ? null : double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(color: borderColor),
            boxShadow: user || error || status ? null : AppShadows.soft,
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
              if (message.text.isNotEmpty) ...[
                const SizedBox(height: 8),
                MarkdownBody(
                  data: message.text,
                  selectable: true,
                  styleSheet: _markdownStyle(context, textColor, user),
                ),
              ],
              _ContentBlocksPreview(message: message),
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

class _ToolBubble extends StatelessWidget {
  const _ToolBubble({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final parsed = _ParsedTool.fromMessage(message);
    return _ToolFrame(child: _ToolCallCard(parsed: parsed));
  }
}

class _ToolGroupBubble extends StatelessWidget {
  const _ToolGroupBubble({required this.messages});

  final List<ChatMessage> messages;

  @override
  Widget build(BuildContext context) {
    final parsedTools = messages.map(_ParsedTool.fromMessage).toList();
    final counts = <String, int>{};
    for (final parsed in parsedTools) {
      counts.update(parsed.title, (value) => value + 1, ifAbsent: () => 1);
    }
    final completedCount = parsedTools.where((tool) {
      return _statusColor(tool.status) == AppColors.success;
    }).length;

    return _ToolFrame(
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: Material(
          color: Colors.transparent,
          child: ExpansionTile(
            tilePadding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
            childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
            initiallyExpanded: false,
            maintainState: true,
            leading: const Icon(
              Icons.account_tree_outlined,
              color: Color(0xff92400e),
              size: 20,
            ),
            title: _ToolGroupHeader(
              totalCount: messages.length,
              completedCount: completedCount,
              counts: counts,
            ),
            children: [
              const Divider(height: 18, color: Color(0xfffde68a)),
              for (var index = 0; index < parsedTools.length; index++) ...[
                _ToolSequenceCard(index: index + 1, parsed: parsedTools[index]),
                if (index != parsedTools.length - 1) const SizedBox(height: 10),
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

class _ToolCallCard extends StatelessWidget {
  const _ToolCallCard({required this.parsed});

  final _ParsedTool parsed;

  @override
  Widget build(BuildContext context) {
    final details = <_DetailEntry>[
      if (parsed.id.isNotEmpty) _DetailEntry('Call ID', parsed.id),
      if (parsed.kind.isNotEmpty) _DetailEntry('Kind', parsed.kind),
      if (parsed.locations.isNotEmpty)
        _DetailEntry('Locations', parsed.locations.join('\n')),
      if (parsed.content.isNotEmpty) _DetailEntry('Content', parsed.content),
      if (parsed.input.isNotEmpty) _DetailEntry('Input', parsed.input),
      if (parsed.output.isNotEmpty) _DetailEntry('Output', parsed.output),
    ];

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xfffffbeb),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: const Color(0xfffde68a)),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: details.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(14),
                child: _ToolHeader(parsed: parsed),
              )
            : Material(
                color: Colors.transparent,
                child: ExpansionTile(
                  tilePadding: const EdgeInsets.fromLTRB(14, 4, 14, 4),
                  childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                  initiallyExpanded: false,
                  maintainState: true,
                  leading: const Icon(
                    Icons.build_circle_outlined,
                    color: Color(0xff92400e),
                    size: 20,
                  ),
                  title: _ToolHeader(parsed: parsed, compact: true),
                  children: [
                    for (final detail in details) ...[
                      _DetailBlock(entry: detail),
                      if (detail != details.last) const SizedBox(height: 10),
                    ],
                  ],
                ),
              ),
      ),
    );
  }
}

class _ToolSequenceCard extends StatelessWidget {
  const _ToolSequenceCard({required this.index, required this.parsed});

  final int index;
  final _ParsedTool parsed;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 18),
          child: _ToolCallCard(parsed: parsed),
        ),
        Positioned(
          left: 0,
          top: 18,
          child: Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              border: Border.all(color: const Color(0xfffde68a)),
              boxShadow: AppShadows.soft,
            ),
            child: Text(
              '$index',
              style: const TextStyle(
                color: Color(0xff92400e),
                fontSize: 11,
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
    required this.completedCount,
    required this.counts,
  });

  final int totalCount;
  final int completedCount;
  final Map<String, int> counts;

  @override
  Widget build(BuildContext context) {
    final pendingCount = totalCount - completedCount;
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
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0,
                ),
              ),
            ),
            _StatusPill(
              label: pendingCount == 0 ? 'completed' : '$pendingCount pending',
              color: pendingCount == 0 ? AppColors.success : AppColors.warning,
            ),
          ],
        ),
        const SizedBox(height: 8),
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

class _ToolCountChip extends StatelessWidget {
  const _ToolCountChip({required this.label, required this.count});

  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 260),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
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
                fontSize: 12,
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
              fontSize: 12,
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
          const SizedBox(width: 8),
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
              const SizedBox(height: 3),
              Text(
                parsed.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        _StatusPill(label: parsed.status, color: _statusColor(parsed.status)),
      ],
    );
  }
}

class _StatusBubble extends StatelessWidget {
  const _StatusBubble({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final kind = _stringMetadata(message.metadata, 'kind') ?? 'status';
    final child = switch (kind) {
      'plan' => _PlanStatus(message: message),
      'diff' => _DiffStatus(message: message),
      'commands' => _CommandsStatus(message: message),
      'mode' => _ModeStatus(message: message),
      'thought' => _ThoughtStatus(message: message),
      'turn' => _TurnStatus(message: message),
      _ => _PlainStatus(message: message),
    };

    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 820),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.surfaceRaised,
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(color: AppColors.border),
          ),
          child: child,
        ),
      ),
    );
  }
}

class _ThoughtStatus extends StatelessWidget {
  const _ThoughtStatus({required this.message});

  final ChatMessage message;

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
          const SizedBox(height: 8),
          Text(
            message.text,
            style: const TextStyle(
              color: AppColors.textSecondary,
              height: 1.35,
            ),
          ),
        ],
        _ContentBlocksPreview(message: message),
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

class _ContentBlocksPreview extends StatelessWidget {
  const _ContentBlocksPreview({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final blocks = _mapList(
      message.metadata['contentBlocks'],
    ).where((block) => _stringMetadata(block, 'type') != 'text').toList();
    if (blocks.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: EdgeInsets.only(top: message.text.isEmpty ? 0 : 10),
      child: Column(
        children: [
          for (final block in blocks) ...[
            _ContentBlockCard(block: block),
            if (block != blocks.last) const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}

class _ContentBlockCard extends StatelessWidget {
  const _ContentBlockCard({required this.block});

  final Map<String, Object?> block;

  @override
  Widget build(BuildContext context) {
    final type = _stringMetadata(block, 'type') ?? 'unknown';
    return switch (type) {
      'image' => _ImageContentBlock(block: block),
      'resource_link' || 'resource' => _ResourceContentBlock(block: block),
      _ => _UnknownContentBlock(block: block),
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
                height: 160,
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
  const _ResourceContentBlock({required this.block});

  final Map<String, Object?> block;

  @override
  Widget build(BuildContext context) {
    final uri = _stringMetadata(block, 'uri') ?? '';
    final title = _stringMetadata(block, 'title') ?? 'Resource';
    final mimeType = _stringMetadata(block, 'mimeType');
    return _InlineContentFrame(
      icon: Icons.link_rounded,
      title: title,
      subtitle: mimeType ?? 'resource link',
      child: uri.isEmpty
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

class _UnknownContentBlock extends StatelessWidget {
  const _UnknownContentBlock({required this.block});

  final Map<String, Object?> block;

  @override
  Widget build(BuildContext context) {
    return _InlineContentFrame(
      icon: Icons.extension_outlined,
      title: _stringMetadata(block, 'type') ?? 'Unknown content',
      subtitle: 'raw content block',
      child: SelectableText(
        _previewObject(block),
        style: const TextStyle(
          color: AppColors.textSecondary,
          fontFamily: 'monospace',
          fontSize: 12,
          height: 1.35,
        ),
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
      padding: const EdgeInsets.all(12),
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
              Icon(icon, color: AppColors.primaryDark, size: 17),
              const SizedBox(width: 8),
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
              const SizedBox(width: 8),
              Text(
                subtitle,
                style: const TextStyle(
                  color: AppColors.textTertiary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          if (child != null) ...[const SizedBox(height: 10), child!],
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
    final entries = _mapList(message.metadata['entries']);

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
        if (entries.isNotEmpty) ...[
          const SizedBox(height: 12),
          for (final entry in entries) _PlanEntryRow(entry: entry),
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
    final icon = switch (status) {
      'completed' => Icons.check_circle_rounded,
      'in_progress' => Icons.play_circle_outline_rounded,
      _ => Icons.radio_button_unchecked_rounded,
    };

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              content,
              style: const TextStyle(
                color: AppColors.textPrimary,
                height: 1.35,
              ),
            ),
          ),
          const SizedBox(width: 8),
          _StatusPill(label: priority, color: AppColors.primaryDark),
        ],
      ),
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
    final changes = _mapList(message.metadata['changes']);
    final additions = changes.where((change) {
      return _stringMetadata(change, 'type') == 'addition';
    }).length;
    final deletions = changes.where((change) {
      return _stringMetadata(change, 'type') == 'deletion';
    }).length;

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
        const SizedBox(height: 8),
        SelectableText(
          uri,
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w700,
          ),
        ),
        if (changes.isNotEmpty) ...[
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _StatusPill(label: '+$additions', color: AppColors.success),
              _StatusPill(label: '-$deletions', color: AppColors.danger),
              _StatusPill(
                label: '${changes.length} changes',
                color: AppColors.primaryDark,
              ),
            ],
          ),
          const SizedBox(height: 10),
          _DiffChangesList(changes: changes),
        ],
      ],
    );
  }
}

class _DiffChangesList extends StatelessWidget {
  const _DiffChangesList({required this.changes});

  final List<Map<String, Object?>> changes;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: Material(
        color: Colors.transparent,
        child: ExpansionTile(
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
          children: [
            for (final change in changes) ...[
              _DiffChangeRow(change: change),
              if (change != changes.last) const SizedBox(height: 8),
            ],
          ],
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
      padding: const EdgeInsets.all(10),
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
                const SizedBox(width: 8),
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
            const SizedBox(height: 8),
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

class _CommandsStatus extends StatelessWidget {
  const _CommandsStatus({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final commands = _mapList(message.metadata['commands']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader(
          icon: Icons.terminal_rounded,
          label: 'Available Commands',
        ),
        const SizedBox(height: 10),
        if (commands.isEmpty)
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
                  for (final command in commands)
                    Tooltip(
                      message: _stringMetadata(command, 'description') ?? '',
                      child: _CommandChip(
                        label: _stringMetadata(command, 'name') ?? 'command',
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Theme(
                data: Theme.of(
                  context,
                ).copyWith(dividerColor: Colors.transparent),
                child: Material(
                  color: Colors.transparent,
                  child: ExpansionTile(
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
                    children: [
                      for (final command in commands) ...[
                        _CommandDetailCard(command: command),
                        if (command != commands.last) const SizedBox(height: 8),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
      ],
    );
  }
}

class _CommandDetailCard extends StatelessWidget {
  const _CommandDetailCard({required this.command});

  final Map<String, Object?> command;

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
      padding: const EdgeInsets.all(10),
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
            const SizedBox(height: 6),
            Text(
              description,
              style: const TextStyle(
                color: AppColors.textSecondary,
                height: 1.35,
              ),
            ),
          ],
          if (inputHint != null) ...[
            const SizedBox(height: 8),
            _DetailBlock(entry: _DetailEntry('Input hint', inputHint)),
          ],
          if (parameters != null) ...[
            const SizedBox(height: 8),
            _DetailBlock(
              entry: _DetailEntry('Parameters', _previewObject(parameters)),
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
        Icon(icon, size: 16, color: AppColors.primaryDark),
        const SizedBox(width: 7),
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
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: AppColors.primarySoft,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.18)),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: AppColors.primaryDark,
          fontSize: 12,
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
      padding: const EdgeInsets.all(10),
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
          const SizedBox(height: 6),
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
      ),
    );
  }
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
  });

  final String title;
  final String status;
  final String id;
  final String kind;
  final String content;
  final String input;
  final String output;
  final List<String> locations;

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
      id: _stringMetadata(metadata, 'toolCallId') ?? '',
      kind: _stringMetadata(metadata, 'kind') == 'tool'
          ? ''
          : _stringMetadata(metadata, 'kind') ?? '',
      content: _previewObject(metadata['content']),
      input: _previewObject(metadata['rawInput']),
      output: _previewObject(metadata['rawOutput']),
      locations: locations,
    );
  }
}

class _DetailEntry {
  const _DetailEntry(this.label, this.value);

  final String label;
  final String value;
}

String? _stringMetadata(Map<String, Object?> metadata, String key) {
  final value = metadata[key];
  if (value is String && value.trim().isNotEmpty) return value.trim();
  return null;
}

List<Map<String, Object?>> _mapList(Object? value) {
  if (value is! List) return const [];
  return value.whereType<Map>().map((entry) {
    return entry.map((key, value) => MapEntry(key.toString(), value));
  }).toList();
}

String _previewObject(Object? value) {
  if (value == null) return '';
  final text = value is String ? value : _jsonPreview(value);
  final cleaned = text.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  if (cleaned.length <= 1200) return cleaned;
  return '${cleaned.substring(0, 1200)}\n...';
}

String _jsonPreview(Object value) {
  try {
    const encoder = JsonEncoder.withIndent('  ');
    return encoder.convert(value);
  } on Object {
    return value.toString();
  }
}

Map<String, Object?> _objectMap(Object? value) {
  if (value is! Map) return const <String, Object?>{};
  return value.map((key, value) => MapEntry(key.toString(), value));
}

Color _statusColor(String status) {
  final normalized = status.replaceFirst('ToolCallStatus.', '');
  return switch (normalized) {
    'completed' || 'applied' => AppColors.success,
    'in_progress' || 'started' => AppColors.primaryDark,
    'failed' || 'error' || 'rejected' => AppColors.danger,
    'cancelled' => AppColors.textSecondary,
    _ => AppColors.warning,
  };
}

String _humanizeStatus(String value) {
  final cleaned = value
      .replaceFirst('ToolCallStatus.', '')
      .replaceAll('_', ' ');
  if (cleaned.isEmpty) return 'unknown';
  return cleaned[0].toUpperCase() + cleaned.substring(1);
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
