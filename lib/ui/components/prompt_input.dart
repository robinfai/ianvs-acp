import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../acp/acp_agent_capabilities.dart';
import '../../acp/prompt_attachment.dart';
import '../theme/app_design_tokens.dart';

typedef PromptSendCallback =
    void Function(String text, List<PromptAttachment> attachments);
typedef PromptAttachmentPicker = Future<List<PromptAttachment>> Function();

class PromptInput extends StatefulWidget {
  const PromptInput({
    super.key,
    this.agentName = 'Codex',
    required this.isSending,
    required this.onSend,
    required this.onStop,
    this.availableCommands = const <Map<String, Object?>>[],
    this.promptCapabilities,
    this.pickAttachments,
  });

  final String agentName;
  final bool isSending;
  final PromptSendCallback onSend;
  final VoidCallback onStop;
  final List<Map<String, Object?>> availableCommands;
  final AcpPromptCapabilities? promptCapabilities;
  final PromptAttachmentPicker? pickAttachments;

  @override
  State<PromptInput> createState() => _PromptInputState();
}

class _PromptInputState extends State<PromptInput> {
  final TextEditingController _controller = TextEditingController();
  final List<PromptAttachment> _attachments = <PromptAttachment>[];

  bool get _canSend =>
      (_controller.text.trim().isNotEmpty || _attachments.isNotEmpty) &&
      !widget.isSending;

  List<Map<String, Object?>> get _commandSuggestions {
    if (widget.isSending || widget.availableCommands.isEmpty) {
      return const <Map<String, Object?>>[];
    }
    final input = _controller.text.trimLeft();
    if (!input.startsWith('/')) return const <Map<String, Object?>>[];
    if (RegExp(r'^/\S+\s').hasMatch(input)) {
      return const <Map<String, Object?>>[];
    }

    final query = input.substring(1).split(RegExp(r'\s+')).first.toLowerCase();
    return widget.availableCommands
        .where((command) {
          final invocation = _commandInvocation(command);
          if (invocation.isEmpty) return false;
          if (query.isEmpty) return true;
          final name = invocation.startsWith('/')
              ? invocation.substring(1).toLowerCase()
              : invocation.toLowerCase();
          final description = _commandString(
            command,
            'description',
          ).toLowerCase();
          return name.contains(query) || description.contains(query);
        })
        .take(5)
        .toList(growable: false);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final commandSuggestions = _commandSuggestions;
    return Container(
      color: AppColors.bg,
      padding: const EdgeInsets.fromLTRB(12, 3, 12, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Focus(
              onKeyEvent: (node, event) {
                if (event is! KeyDownEvent) return KeyEventResult.ignored;
                if (event.logicalKey != LogicalKeyboardKey.enter) {
                  return KeyEventResult.ignored;
                }
                if (HardwareKeyboard.instance.isShiftPressed) {
                  return KeyEventResult.ignored;
                }
                _submit();
                return KeyEventResult.handled;
              },
              child: Container(
                constraints: const BoxConstraints(minHeight: 52),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  border: Border.all(color: AppColors.border),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.textPrimary.withValues(alpha: 0.04),
                      blurRadius: 10,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (commandSuggestions.isNotEmpty)
                      _CommandSuggestionPanel(
                        commands: commandSuggestions,
                        onSelect: _insertCommand,
                      ),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(6, 6, 2, 0),
                          child: Semantics(
                            button: true,
                            label: 'Attach file',
                            child: IconButton(
                              tooltip: 'Attach file',
                              onPressed: widget.isSending
                                  ? null
                                  : _pickAttachments,
                              icon: const Icon(Icons.attach_file_rounded),
                              color: AppColors.textSecondary,
                              disabledColor: AppColors.textTertiary,
                              iconSize: 17,
                              visualDensity: VisualDensity.compact,
                              splashRadius: 18,
                            ),
                          ),
                        ),
                        Expanded(
                          child: TextField(
                            controller: _controller,
                            minLines: 1,
                            maxLines: 4,
                            keyboardType: TextInputType.multiline,
                            enabled: !widget.isSending,
                            onChanged: (_) => setState(() {}),
                            style: const TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 13,
                              height: 1.35,
                            ),
                            decoration: InputDecoration(
                              hintText:
                                  'Send a prompt to ${widget.agentName}...',
                              hintStyle: const TextStyle(
                                color: AppColors.textTertiary,
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                              isCollapsed: true,
                              contentPadding: const EdgeInsets.fromLTRB(
                                4,
                                12,
                                12,
                                10,
                              ),
                              border: InputBorder.none,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (_attachments.isNotEmpty)
                      _AttachmentTray(
                        attachments: _attachments,
                        promptCapabilities: widget.promptCapabilities,
                        onRemove: _removeAttachment,
                      ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 112,
            height: 38,
            child: FilledButton.icon(
              onPressed: _canSend ? _submit : null,
              icon: const Icon(Icons.near_me_outlined, size: 17),
              label: const Text('Send'),
              style: FilledButton.styleFrom(
                foregroundColor: AppColors.primaryDark,
                disabledForegroundColor: AppColors.textTertiary,
                backgroundColor: AppColors.primarySoft,
                disabledBackgroundColor: AppColors.primarySoft,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                textStyle: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 102,
            height: 38,
            child: OutlinedButton.icon(
              onPressed: widget.isSending ? widget.onStop : null,
              icon: const Icon(Icons.stop_circle_outlined, size: 17),
              label: const Text('Stop'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.textSecondary,
                disabledForegroundColor: AppColors.textTertiary,
                side: const BorderSide(color: AppColors.border),
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
          ),
        ],
      ),
    );
  }

  void _submit() {
    if (!_canSend) return;
    final text = _controller.text;
    final attachments = List<PromptAttachment>.unmodifiable(_attachments);
    widget.onSend(text, attachments);
    _controller.clear();
    _attachments.clear();
    setState(() {});
  }

  void _insertCommand(Map<String, Object?> command) {
    final invocation = _commandInvocation(command);
    if (invocation.isEmpty) return;
    final text = '$invocation ';
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    setState(() {});
  }

  Future<void> _pickAttachments() async {
    try {
      final picker = widget.pickAttachments ?? _pickWithFilePicker;
      final selected = await picker();
      if (!mounted || selected.isEmpty) return;
      setState(() {
        for (final attachment in selected) {
          final duplicate = _attachments.any(
            (existing) => existing.path == attachment.path,
          );
          if (!duplicate) {
            _attachments.add(attachment);
          }
        }
      });
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not attach file: $error')));
    }
  }

  void _removeAttachment(PromptAttachment attachment) {
    setState(() {
      _attachments.removeWhere((item) => item.path == attachment.path);
    });
  }
}

class _CommandSuggestionPanel extends StatelessWidget {
  const _CommandSuggestionPanel({
    required this.commands,
    required this.onSelect,
  });

  final List<Map<String, Object?>> commands;
  final ValueChanged<Map<String, Object?>> onSelect;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 154),
      child: ListView.separated(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(6, 6, 6, 4),
        itemBuilder: (context, index) {
          final command = commands[index];
          final invocation = _commandInvocation(command);
          final description = _commandString(command, 'description');
          return _CommandSuggestionTile(
            invocation: invocation,
            description: description,
            onTap: () => onSelect(command),
          );
        },
        separatorBuilder: (_, _) => const SizedBox(height: 3),
        itemCount: commands.length,
      ),
    );
  }
}

class _CommandSuggestionTile extends StatelessWidget {
  const _CommandSuggestionTile({
    required this.invocation,
    required this.description,
    required this.onTap,
  });

  final String invocation;
  final String description;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.sm),
      onTap: onTap,
      child: Container(
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: AppColors.surfaceRaised,
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.terminal_rounded,
              color: AppColors.primaryDark,
              size: 15,
            ),
            const SizedBox(width: 7),
            SizedBox(
              width: 126,
              child: Text(
                invocation,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0,
                ),
              ),
            ),
            if (description.isNotEmpty) ...[
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  description,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

String _commandInvocation(Map<String, Object?> command) {
  final name = _commandString(command, 'name');
  if (name.isEmpty) return '';
  return name.startsWith('/') ? name : '/$name';
}

String _commandString(Map<String, Object?> command, String key) {
  final value = command[key];
  return value is String ? value.trim() : '';
}

Future<List<PromptAttachment>> _pickWithFilePicker() async {
  final result = await FilePicker.platform.pickFiles(
    allowMultiple: true,
    withData: false,
  );
  if (result == null) return const <PromptAttachment>[];
  return result.files
      .where((file) => file.path != null && file.path!.isNotEmpty)
      .map(
        (file) => PromptAttachment.fromPath(
          path: file.path!,
          name: file.name,
          size: file.size,
        ),
      )
      .toList();
}

class _AttachmentTray extends StatelessWidget {
  const _AttachmentTray({
    required this.attachments,
    required this.promptCapabilities,
    required this.onRemove,
  });

  final List<PromptAttachment> attachments;
  final AcpPromptCapabilities? promptCapabilities;
  final ValueChanged<PromptAttachment> onRemove;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final attachment in attachments)
              _AttachmentChip(
                attachment: attachment,
                promptCapabilities: promptCapabilities,
                onRemove: () => onRemove(attachment),
              ),
          ],
        ),
      ),
    );
  }
}

class _AttachmentChip extends StatelessWidget {
  const _AttachmentChip({
    required this.attachment,
    required this.promptCapabilities,
    required this.onRemove,
  });

  final PromptAttachment attachment;
  final AcpPromptCapabilities? promptCapabilities;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final size = attachment.displaySize;
    final mode = attachment.promptMode(promptCapabilities);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 320),
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
        decoration: BoxDecoration(
          color: AppColors.surfaceRaised,
          borderRadius: BorderRadius.circular(AppRadius.pill),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.insert_drive_file_outlined,
              color: AppColors.primaryDark,
              size: 14,
            ),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                attachment.name,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0,
                ),
              ),
            ),
            if (size.isNotEmpty) ...[
              const SizedBox(width: 5),
              Text(
                size,
                style: const TextStyle(
                  color: AppColors.textTertiary,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0,
                ),
              ),
            ],
            const SizedBox(width: 5),
            _AttachmentModeBadge(mode: mode),
            SizedBox(
              width: 24,
              height: 24,
              child: IconButton(
                onPressed: onRemove,
                tooltip: 'Remove attachment',
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                iconSize: 14,
                color: AppColors.textSecondary,
                icon: const Icon(Icons.close_rounded),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AttachmentModeBadge extends StatelessWidget {
  const _AttachmentModeBadge({required this.mode});

  final PromptAttachmentPromptMode mode;

  @override
  Widget build(BuildContext context) {
    final color = _attachmentModeColor(mode);
    return Tooltip(
      message: _attachmentModeTooltip(mode),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.09),
          borderRadius: BorderRadius.circular(AppRadius.pill),
          border: Border.all(color: color.withValues(alpha: 0.24)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_attachmentModeIcon(mode), size: 11, color: color),
            const SizedBox(width: 3),
            Text(
              _attachmentModeLabel(mode),
              style: TextStyle(
                color: color,
                fontSize: 10,
                fontWeight: FontWeight.w800,
                letterSpacing: 0,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

IconData _attachmentModeIcon(PromptAttachmentPromptMode mode) {
  return switch (mode) {
    PromptAttachmentPromptMode.image => Icons.image_outlined,
    PromptAttachmentPromptMode.audio => Icons.graphic_eq_rounded,
    PromptAttachmentPromptMode.embeddedResource => Icons.data_object_rounded,
    PromptAttachmentPromptMode.resourceLink => Icons.link_rounded,
  };
}

Color _attachmentModeColor(PromptAttachmentPromptMode mode) {
  return switch (mode) {
    PromptAttachmentPromptMode.image => AppColors.primaryDark,
    PromptAttachmentPromptMode.audio => AppColors.primaryDark,
    PromptAttachmentPromptMode.embeddedResource => AppColors.success,
    PromptAttachmentPromptMode.resourceLink => AppColors.textSecondary,
  };
}

String _attachmentModeLabel(PromptAttachmentPromptMode mode) {
  return switch (mode) {
    PromptAttachmentPromptMode.image => 'Image',
    PromptAttachmentPromptMode.audio => 'Audio',
    PromptAttachmentPromptMode.embeddedResource => 'Embed',
    PromptAttachmentPromptMode.resourceLink => 'Link',
  };
}

String _attachmentModeTooltip(PromptAttachmentPromptMode mode) {
  return switch (mode) {
    PromptAttachmentPromptMode.image => 'Sent as image content',
    PromptAttachmentPromptMode.audio => 'Sent as audio content',
    PromptAttachmentPromptMode.embeddedResource => 'Embedded as resource data',
    PromptAttachmentPromptMode.resourceLink => 'Sent as a resource link',
  };
}
