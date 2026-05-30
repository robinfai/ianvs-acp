import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_design_tokens.dart';

class PromptInput extends StatefulWidget {
  const PromptInput({
    super.key,
    this.agentName = 'Codex',
    required this.isSending,
    required this.onSend,
    required this.onStop,
  });

  final String agentName;
  final bool isSending;
  final ValueChanged<String> onSend;
  final VoidCallback onStop;

  @override
  State<PromptInput> createState() => _PromptInputState();
}

class _PromptInputState extends State<PromptInput> {
  final TextEditingController _controller = TextEditingController();

  bool get _canSend => _controller.text.trim().isNotEmpty && !widget.isSending;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.bg,
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 18),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
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
                constraints: const BoxConstraints(minHeight: 94),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(AppRadius.lg),
                  border: Border.all(color: AppColors.border),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.textPrimary.withValues(alpha: 0.04),
                      blurRadius: 22,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: Stack(
                  children: [
                    TextField(
                      controller: _controller,
                      minLines: 2,
                      maxLines: 5,
                      enabled: !widget.isSending,
                      onChanged: (_) => setState(() {}),
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 16,
                        height: 1.35,
                      ),
                      decoration: InputDecoration(
                        hintText: 'Send a prompt to ${widget.agentName}...',
                        hintStyle: const TextStyle(
                          color: AppColors.textTertiary,
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                        ),
                        isCollapsed: true,
                        contentPadding: const EdgeInsets.fromLTRB(
                          24,
                          20,
                          24,
                          44,
                        ),
                        border: InputBorder.none,
                      ),
                    ),
                    Positioned(
                      left: 18,
                      bottom: 12,
                      child: Tooltip(
                        message: 'Attach file',
                        child: IconButton(
                          onPressed: widget.isSending ? null : () {},
                          icon: const Icon(Icons.attach_file_rounded),
                          color: AppColors.textSecondary,
                          disabledColor: AppColors.textTertiary,
                          iconSize: 22,
                          visualDensity: VisualDensity.compact,
                          splashRadius: 18,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 22),
          SizedBox(
            width: 148,
            height: 66,
            child: FilledButton.icon(
              onPressed: _canSend ? _submit : null,
              icon: const Icon(Icons.near_me_outlined, size: 23),
              label: const Text('Send'),
              style: FilledButton.styleFrom(
                foregroundColor: AppColors.primaryDark,
                disabledForegroundColor: AppColors.textTertiary,
                backgroundColor: AppColors.primarySoft,
                disabledBackgroundColor: AppColors.primarySoft,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                textStyle: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0,
                ),
              ),
            ),
          ),
          const SizedBox(width: 18),
          SizedBox(
            width: 132,
            height: 66,
            child: OutlinedButton.icon(
              onPressed: widget.isSending ? widget.onStop : null,
              icon: const Icon(Icons.stop_circle_outlined, size: 23),
              label: const Text('Stop'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.textSecondary,
                disabledForegroundColor: AppColors.textTertiary,
                side: const BorderSide(color: AppColors.border),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                ),
                textStyle: const TextStyle(
                  fontSize: 17,
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
    widget.onSend(text);
    _controller.clear();
    setState(() {});
  }
}
