import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../acp/acp_agent_capabilities.dart';
import '../../acp/acp_permission_request.dart';
import '../../acp/acp_session_settings.dart';
import '../../acp/prompt_attachment.dart';
import '../theme/app_design_tokens.dart';

typedef PromptSendCallback =
    void Function(String text, List<PromptAttachment> attachments);
typedef PromptAttachmentPicker = Future<List<PromptAttachment>> Function();

class PromptInput extends StatefulWidget {
  const PromptInput({
    super.key,
    this.agentName = 'Codex',
    this.enabled = true,
    required this.isSending,
    required this.onSend,
    required this.onStop,
    this.availableCommands = const <Map<String, Object?>>[],
    this.promptCapabilities,
    this.pendingPermissionRequest,
    this.onAllowPermission,
    this.onDenyPermission,
    this.onCancelPermission,
    this.toolCallExecutionPolicy = AcpToolCallExecutionPolicy.autoReview,
    this.onToolCallExecutionPolicyChanged,
    this.modelOption,
    this.onModelSelected,
    this.pickAttachments,
  });

  final String agentName;
  final bool enabled;
  final bool isSending;
  final PromptSendCallback onSend;
  final VoidCallback onStop;
  final List<Map<String, Object?>> availableCommands;
  final AcpPromptCapabilities? promptCapabilities;
  final AcpPermissionRequest? pendingPermissionRequest;
  final VoidCallback? onAllowPermission;
  final VoidCallback? onDenyPermission;
  final VoidCallback? onCancelPermission;
  final AcpToolCallExecutionPolicy toolCallExecutionPolicy;
  final ValueChanged<AcpToolCallExecutionPolicy>?
  onToolCallExecutionPolicyChanged;
  final AcpConfigOption? modelOption;
  final ValueChanged<String>? onModelSelected;
  final PromptAttachmentPicker? pickAttachments;

  @override
  State<PromptInput> createState() => _PromptInputState();
}

class _PromptInputState extends State<PromptInput> {
  final TextEditingController _controller = TextEditingController();
  final List<PromptAttachment> _attachments = <PromptAttachment>[];

  bool get _canSend =>
      (_controller.text.trim().isNotEmpty || _attachments.isNotEmpty) &&
      widget.enabled &&
      !widget.isSending;

  List<Map<String, Object?>> get _commandSuggestions {
    if (!widget.enabled ||
        widget.isSending ||
        widget.availableCommands.isEmpty) {
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
    final pendingPermissionRequest = widget.pendingPermissionRequest;
    final hasPendingPermission = pendingPermissionRequest != null;
    return Container(
      color: AppColors.bg,
      padding: const EdgeInsets.fromLTRB(12, 3, 12, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Focus(
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
              key: const Key('prompt-input-surface'),
              constraints: const BoxConstraints(minHeight: 78),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(AppRadius.md),
                border: Border.all(
                  color: hasPendingPermission
                      ? const Color(0xfff97316)
                      : AppColors.border,
                  width: hasPendingPermission ? 1.4 : 1,
                ),
                boxShadow: [
                  BoxShadow(
                    color: hasPendingPermission
                        ? const Color(0xfff97316).withValues(alpha: 0.18)
                        : AppColors.textPrimary.withValues(alpha: 0.05),
                    blurRadius: hasPendingPermission ? 22 : 16,
                    offset: Offset(0, hasPendingPermission ? 7 : 5),
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
                  TextField(
                    controller: _controller,
                    minLines: 1,
                    maxLines: 4,
                    keyboardType: TextInputType.multiline,
                    enabled: widget.enabled && !widget.isSending,
                    onChanged: (_) => setState(() {}),
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 13,
                      height: 1.35,
                    ),
                    decoration: InputDecoration(
                      hintText: 'Send a prompt to ${widget.agentName}...',
                      hintStyle: const TextStyle(
                        color: AppColors.textTertiary,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                      isCollapsed: true,
                      contentPadding: const EdgeInsets.fromLTRB(13, 12, 13, 8),
                      border: InputBorder.none,
                    ),
                  ),
                  if (pendingPermissionRequest != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 1, 8, 8),
                      child: _PromptPermissionCard(
                        request: pendingPermissionRequest,
                        onAllow: widget.onAllowPermission,
                        onDeny: widget.onDenyPermission,
                        onCancel: widget.onCancelPermission,
                      ),
                    ),
                  if (_attachments.isNotEmpty)
                    _AttachmentTray(
                      attachments: _attachments,
                      promptCapabilities: widget.promptCapabilities,
                      onRemove: _removeAttachment,
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
                    child: _ComposerControlBar(
                      enabled: widget.enabled,
                      isSending: widget.isSending,
                      canSend: _canSend,
                      onPickAttachments: _pickAttachments,
                      toolCallExecutionPolicy: widget.toolCallExecutionPolicy,
                      onToolCallExecutionPolicyChanged:
                          widget.onToolCallExecutionPolicyChanged,
                      modelOption: widget.modelOption,
                      onModelSelected: widget.onModelSelected,
                      onSend: _submit,
                      onStop: widget.onStop,
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
      if (!mounted || !widget.enabled || widget.isSending || selected.isEmpty) {
        return;
      }
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

class _PromptPermissionCard extends StatelessWidget {
  const _PromptPermissionCard({
    required this.request,
    required this.onAllow,
    required this.onDeny,
    required this.onCancel,
  });

  final AcpPermissionRequest request;
  final VoidCallback? onAllow;
  final VoidCallback? onDeny;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('prompt-permission-card'),
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xfffff7ed),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: const Color(0xfffb923c), width: 1.3),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          const Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: 5,
            child: ColoredBox(color: Color(0xfff97316)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final compact = constraints.maxWidth < 700;
                final details = Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.privacy_tip_rounded,
                          color: Color(0xffc2410c),
                          size: 17,
                        ),
                        const SizedBox(width: 7),
                        Flexible(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xffffedd5),
                              borderRadius: BorderRadius.circular(
                                AppRadius.pill,
                              ),
                              border: Border.all(
                                color: const Color(0xfffed7aa),
                              ),
                            ),
                            child: const Text(
                              'Tool call needs approval',
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Color(0xff9a3412),
                                fontSize: 11,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 0,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      request.displayTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${request.displayRationale} (${request.displayKind})',
                      maxLines: compact ? 2 : 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0,
                      ),
                    ),
                  ],
                );
                final actions = Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  alignment: WrapAlignment.end,
                  children: [
                    OutlinedButton.icon(
                      onPressed: onDeny,
                      icon: const Icon(Icons.block_rounded, size: 15),
                      label: Text(request.denyActionLabel),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.danger,
                        minimumSize: const Size(0, 32),
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        side: const BorderSide(color: Color(0xfffecaca)),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                    FilledButton.icon(
                      onPressed: onAllow,
                      icon: const Icon(Icons.check_rounded, size: 15),
                      label: Text(request.allowActionLabel),
                      style: FilledButton.styleFrom(
                        foregroundColor: Colors.white,
                        backgroundColor: const Color(0xffc2410c),
                        minimumSize: const Size(0, 32),
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Cancel permission request',
                      onPressed: onCancel,
                      icon: const Icon(Icons.close_rounded, size: 18),
                      color: AppColors.textSecondary,
                      constraints: const BoxConstraints.tightFor(
                        width: 32,
                        height: 32,
                      ),
                      visualDensity: VisualDensity.compact,
                    ),
                  ],
                );

                if (compact) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      details,
                      const SizedBox(height: 9),
                      SizedBox(width: double.infinity, child: actions),
                    ],
                  );
                }

                return Row(
                  children: [
                    Expanded(child: details),
                    const SizedBox(width: 10),
                    actions,
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ComposerDivider extends StatelessWidget {
  const _ComposerDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 24,
      margin: const EdgeInsets.symmetric(horizontal: 6),
      color: AppColors.border,
    );
  }
}

class _ComposerControlBar extends StatelessWidget {
  const _ComposerControlBar({
    required this.enabled,
    required this.isSending,
    required this.canSend,
    required this.onPickAttachments,
    required this.toolCallExecutionPolicy,
    required this.onToolCallExecutionPolicyChanged,
    required this.modelOption,
    required this.onModelSelected,
    required this.onSend,
    required this.onStop,
  });

  final bool enabled;
  final bool isSending;
  final bool canSend;
  final VoidCallback onPickAttachments;
  final AcpToolCallExecutionPolicy toolCallExecutionPolicy;
  final ValueChanged<AcpToolCallExecutionPolicy>?
  onToolCallExecutionPolicyChanged;
  final AcpConfigOption? modelOption;
  final ValueChanged<String>? onModelSelected;
  final VoidCallback onSend;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final attach = Semantics(
      button: true,
      label: 'Attach file',
      child: IconButton(
        tooltip: 'Attach file',
        onPressed: !enabled || isSending ? null : onPickAttachments,
        icon: const Icon(Icons.add_rounded),
        color: AppColors.textSecondary,
        disabledColor: AppColors.textTertiary,
        iconSize: 20,
        visualDensity: VisualDensity.compact,
        splashRadius: 18,
      ),
    );
    final policy = _ToolCallPolicySelector(
      value: toolCallExecutionPolicy,
      enabled: enabled && onToolCallExecutionPolicyChanged != null,
      onChanged: onToolCallExecutionPolicyChanged,
    );
    final model = modelOption != null && modelOption!.options.isNotEmpty
        ? _ModelSelector(
            option: modelOption,
            enabled: enabled && !isSending && onModelSelected != null,
            onSelected: onModelSelected,
          )
        : null;
    final action = _PromptActionButton(
      isSending: isSending,
      canSend: canSend,
      onSend: onSend,
      onStop: onStop,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 560) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  attach,
                  const _ComposerDivider(),
                  Flexible(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: policy,
                    ),
                  ),
                  const SizedBox(width: 8),
                  action,
                ],
              ),
              if (model != null) ...[
                const SizedBox(height: 6),
                Align(alignment: Alignment.centerRight, child: model),
              ],
            ],
          );
        }

        return Row(
          children: [
            attach,
            const _ComposerDivider(),
            Flexible(
              child: Align(alignment: Alignment.centerLeft, child: policy),
            ),
            const Spacer(),
            if (model != null) ...[
              Flexible(
                child: Align(alignment: Alignment.centerRight, child: model),
              ),
              const SizedBox(width: 8),
            ],
            action,
          ],
        );
      },
    );
  }
}

class _ToolCallPolicySelector extends StatelessWidget {
  const _ToolCallPolicySelector({
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final AcpToolCallExecutionPolicy value;
  final bool enabled;
  final ValueChanged<AcpToolCallExecutionPolicy>? onChanged;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<AcpToolCallExecutionPolicy>(
      tooltip: 'Tool call execution policy',
      enabled: enabled,
      onSelected: onChanged,
      itemBuilder: (context) => [
        for (final policy in AcpToolCallExecutionPolicy.values)
          PopupMenuItem<AcpToolCallExecutionPolicy>(
            value: policy,
            child: _PopupChoiceRow(
              selected: policy == value,
              icon: _policyIcon(policy),
              label: _policyLabel(policy),
              description: _policyDescription(policy),
            ),
          ),
      ],
      child: _ComposerControlButton(
        icon: _policyIcon(value),
        label: _policyLabel(value),
        enabled: enabled,
        emphasized: value == AcpToolCallExecutionPolicy.fullAccess,
      ),
    );
  }
}

class _ModelSelector extends StatelessWidget {
  const _ModelSelector({
    required this.option,
    required this.enabled,
    required this.onSelected,
  });

  final AcpConfigOption? option;
  final bool enabled;
  final ValueChanged<String>? onSelected;

  @override
  Widget build(BuildContext context) {
    final modelOption = option;
    final label = modelOption?.currentChoiceLabel ?? 'Model';
    final hasChoices = modelOption != null && modelOption.options.isNotEmpty;
    return PopupMenuButton<String>(
      tooltip: 'Model',
      enabled: enabled && hasChoices,
      onSelected: onSelected,
      itemBuilder: (context) => [
        for (final choice
            in modelOption?.options ?? const <AcpConfigOptionChoice>[])
          PopupMenuItem<String>(
            value: choice.value,
            child: _PopupChoiceRow(
              selected: choice.value == modelOption?.currentValue,
              icon: Icons.memory_rounded,
              label: choice.label,
              description: choice.description ?? '',
            ),
          ),
      ],
      child: _ComposerControlButton(
        icon: Icons.memory_rounded,
        label: label,
        enabled: enabled && hasChoices,
      ),
    );
  }
}

class _ComposerControlButton extends StatelessWidget {
  const _ComposerControlButton({
    required this.icon,
    required this.label,
    required this.enabled,
    this.emphasized = false,
  });

  final IconData icon;
  final String label;
  final bool enabled;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final color = !enabled
        ? AppColors.textTertiary
        : emphasized
        ? AppColors.danger
        : AppColors.primaryDark;
    final background = emphasized
        ? const Color(0xfffef2f2)
        : AppColors.primarySoft;
    final borderColor = emphasized
        ? const Color(0xfffecaca)
        : AppColors.primary.withValues(alpha: 0.14);
    return Container(
      height: 30,
      constraints: const BoxConstraints(maxWidth: 190),
      padding: const EdgeInsets.symmetric(horizontal: 9),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: enabled ? borderColor : AppColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 16),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: color,
                fontSize: 13,
                fontWeight: FontWeight.w900,
                letterSpacing: 0,
              ),
            ),
          ),
          const SizedBox(width: 3),
          Icon(Icons.keyboard_arrow_down_rounded, color: color, size: 17),
        ],
      ),
    );
  }
}

class _PopupChoiceRow extends StatelessWidget {
  const _PopupChoiceRow({
    required this.selected,
    required this.icon,
    required this.label,
    required this.description,
  });

  final bool selected;
  final IconData icon;
  final String label;
  final String description;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(
          selected ? Icons.check_circle_rounded : icon,
          size: 17,
          color: selected ? AppColors.success : AppColors.primaryDark,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0,
                ),
              ),
              if (description.isNotEmpty)
                Text(
                  description,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PromptActionButton extends StatelessWidget {
  const _PromptActionButton({
    required this.isSending,
    required this.canSend,
    required this.onSend,
    required this.onStop,
  });

  final bool isSending;
  final bool canSend;
  final VoidCallback onSend;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final icon = isSending ? Icons.stop_rounded : Icons.arrow_upward_rounded;
    final tooltip = isSending ? 'Stop' : 'Send';
    final onPressed = isSending ? onStop : (canSend ? onSend : null);
    return SizedBox(
      width: 38,
      height: 38,
      child: Tooltip(
        message: tooltip,
        child: FilledButton(
          onPressed: onPressed,
          style: FilledButton.styleFrom(
            foregroundColor: Colors.white,
            disabledForegroundColor: AppColors.textTertiary,
            backgroundColor: isSending
                ? AppColors.danger
                : AppColors.textPrimary,
            disabledBackgroundColor: AppColors.surfaceRaised,
            elevation: onPressed == null ? 0 : 2,
            padding: EdgeInsets.zero,
            shape: const CircleBorder(),
          ),
          child: Icon(icon, size: 20),
        ),
      ),
    );
  }
}

IconData _policyIcon(AcpToolCallExecutionPolicy policy) {
  return switch (policy) {
    AcpToolCallExecutionPolicy.defaultPermissions =>
      Icons.admin_panel_settings_outlined,
    AcpToolCallExecutionPolicy.autoReview => Icons.verified_user_outlined,
    AcpToolCallExecutionPolicy.fullAccess => Icons.all_inclusive_rounded,
  };
}

String _policyLabel(AcpToolCallExecutionPolicy policy) {
  return switch (policy) {
    AcpToolCallExecutionPolicy.defaultPermissions => '默认权限',
    AcpToolCallExecutionPolicy.autoReview => '自动审查',
    AcpToolCallExecutionPolicy.fullAccess => '完全访问权限',
  };
}

String _policyDescription(AcpToolCallExecutionPolicy policy) {
  return switch (policy) {
    AcpToolCallExecutionPolicy.defaultPermissions => '所有请求都由你确认',
    AcpToolCallExecutionPolicy.autoReview => '使用信任规则，未命中时再确认',
    AcpToolCallExecutionPolicy.fullAccess => '自动允许所有 tool call',
  };
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
