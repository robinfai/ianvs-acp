import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
    this.pickAttachments,
  });

  final String agentName;
  final bool isSending;
  final PromptSendCallback onSend;
  final VoidCallback onStop;
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

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
  const _AttachmentTray({required this.attachments, required this.onRemove});

  final List<PromptAttachment> attachments;
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
                onRemove: () => onRemove(attachment),
              ),
          ],
        ),
      ),
    );
  }
}

class _AttachmentChip extends StatelessWidget {
  const _AttachmentChip({required this.attachment, required this.onRemove});

  final PromptAttachment attachment;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final size = attachment.displaySize;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 260),
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
