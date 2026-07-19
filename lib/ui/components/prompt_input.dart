import 'dart:collection';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../acp/acp_agent_capabilities.dart';
import '../../acp/acp_input_budget.dart';
import '../../acp/acp_permission_request.dart';
import '../../acp/acp_session_settings.dart';
import '../../acp/prompt_attachment.dart';
import '../../tasks/egress_policy.dart';
import '../theme/app_design_tokens.dart';
import '../bounded_metadata_preview.dart';

typedef PromptSendCallback =
    void Function(String text, List<PromptAttachment> attachments);
typedef PromptAttachmentPicker = Future<List<PromptAttachment>> Function();
typedef PromptAttachmentKindPicker =
    Future<List<PromptAttachment>> Function(PromptAttachmentKind kind);

enum PromptAttachmentKind { file, image, audio }

const Color _permissionAccent = Color(0xffea580c);
const Color _permissionAccentDark = Color(0xff9a3412);
const Color _permissionAccentSoft = Color(0xfffff7ed);
const Color _permissionAccentMist = Color(0xffffedd5);
const Color _permissionAccentBorder = Color(0xfffb923c);
const Color _permissionAccentBorderSoft = Color(0xfffed7aa);

class PromptInput extends StatefulWidget {
  const PromptInput({
    super.key,
    this.agentName = 'Codex',
    this.enabled = true,
    required this.isSending,
    required this.onSend,
    required this.onStop,
    this.availableCommands = const <Map<String, Object?>>[],
    this.availableCommandsRevision = 0,
    this.promptCapabilities,
    this.pendingPermissionRequest,
    this.onAllowPermission,
    this.onDenyPermission,
    this.onCancelPermission,
    this.onSelectPermissionOption,
    this.toolCallExecutionPolicy =
        AcpToolCallExecutionPolicy.defaultPermissions,
    this.hasPermissionReviewer = false,
    this.onToolCallExecutionPolicyChanged,
    this.modelOption,
    this.reasoningEffortOption,
    this.onModelSelected,
    this.onReasoningEffortSelected,
    this.pickAttachments,
    this.pickAttachmentsForKind,
    this.inputBudget = const AcpInputBudget(),
  });

  final String agentName;
  final bool enabled;
  final bool isSending;
  final PromptSendCallback onSend;
  final VoidCallback onStop;
  final List<Map<String, Object?>> availableCommands;
  final int availableCommandsRevision;
  final AcpPromptCapabilities? promptCapabilities;
  final AcpPermissionRequest? pendingPermissionRequest;
  final VoidCallback? onAllowPermission;
  final VoidCallback? onDenyPermission;
  final VoidCallback? onCancelPermission;
  final ValueChanged<String>? onSelectPermissionOption;
  final AcpToolCallExecutionPolicy toolCallExecutionPolicy;
  final bool hasPermissionReviewer;
  final ValueChanged<AcpToolCallExecutionPolicy>?
  onToolCallExecutionPolicyChanged;
  final AcpConfigOption? modelOption;
  final AcpConfigOption? reasoningEffortOption;
  final ValueChanged<String>? onModelSelected;
  final ValueChanged<String>? onReasoningEffortSelected;
  final PromptAttachmentPicker? pickAttachments;
  final PromptAttachmentKindPicker? pickAttachmentsForKind;
  final AcpInputBudget inputBudget;

  @override
  State<PromptInput> createState() => _PromptInputState();
}

class _PromptInputState extends State<PromptInput> {
  final TextEditingController _controller = TextEditingController();
  final List<PromptAttachment> _attachments = <PromptAttachment>[];
  bool _isDraggingAttachments = false;
  String? _commandQuery;
  List<_CommandSearchEntry> _commandSearchEntries =
      const <_CommandSearchEntry>[];
  LinkedHashMap<_CommandSearchEntry, BoundedMetadataPreview?>
  _commandParameterPreviewMemo =
      LinkedHashMap<_CommandSearchEntry, BoundedMetadataPreview?>();

  @override
  void initState() {
    super.initState();
    widget.inputBudget.validate();
    _commandQuery = _scanBoundedCommandQuery(
      _controller.text,
      budget: widget.inputBudget,
    );
    _rebuildCommandSearchEntries();
  }

  @override
  void didUpdateWidget(covariant PromptInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    widget.inputBudget.validate();
    if (!identical(widget.inputBudget, oldWidget.inputBudget)) {
      _commandQuery = _scanBoundedCommandQuery(
        _controller.text,
        budget: widget.inputBudget,
      );
    }
    if (!identical(widget.availableCommands, oldWidget.availableCommands) ||
        widget.availableCommandsRevision !=
            oldWidget.availableCommandsRevision ||
        !identical(widget.inputBudget, oldWidget.inputBudget)) {
      _rebuildCommandSearchEntries();
    }
    if ((!widget.enabled || widget.isSending) && _isDraggingAttachments) {
      _isDraggingAttachments = false;
    }
  }

  bool get _canSend =>
      (_controller.text.trim().isNotEmpty || _attachments.isNotEmpty) &&
      widget.enabled &&
      !widget.isSending;

  List<_CommandSearchEntry> get _commandSuggestions {
    if (!widget.enabled || widget.isSending || _commandSearchEntries.isEmpty) {
      return const <_CommandSearchEntry>[];
    }
    final query = _commandQuery;
    if (query == null) return const <_CommandSearchEntry>[];
    return _commandSearchEntries
        .where((entry) {
          if (query.isEmpty) return true;
          return entry.lowerName.contains(query) ||
              entry.lowerDescription.contains(query);
        })
        .take(5)
        .toList(growable: false);
  }

  void _rebuildCommandSearchEntries() {
    const maxSearchEntries = 1024;
    try {
      final commands = widget.availableCommands;
      final sourceLength = commands.length;
      final length = sourceLength < maxSearchEntries
          ? sourceLength
          : maxSearchEntries;
      final entries = <_CommandSearchEntry>[];
      for (var index = 0; index < length; index += 1) {
        final command = commands[index];
        final name = _commandString(command, 'name');
        final description = _commandString(command, 'description');
        final invocation = _commandInvocationFromName(name);
        if (invocation.isEmpty) continue;
        final lowerName = invocation.substring(1).toLowerCase();
        final entry = _CommandSearchEntry(
          command: command,
          invocation: invocation,
          lowerName: lowerName,
          lowerDescription: description.toLowerCase(),
          description: description,
        );
        entries.add(entry);
      }
      _commandSearchEntries = List<_CommandSearchEntry>.unmodifiable(entries);
      _commandParameterPreviewMemo =
          LinkedHashMap<_CommandSearchEntry, BoundedMetadataPreview?>();
    } on Object {
      _clearCommandSearchCache();
    }
  }

  void _clearCommandSearchCache() {
    _commandSearchEntries = const <_CommandSearchEntry>[];
    _commandParameterPreviewMemo =
        LinkedHashMap<_CommandSearchEntry, BoundedMetadataPreview?>();
  }

  Map<_CommandSearchEntry, BoundedMetadataPreview?> _parameterPreviewsFor(
    List<_CommandSearchEntry> entries,
  ) {
    const maxMemoEntries = 5;
    final visible = <_CommandSearchEntry, BoundedMetadataPreview?>{};
    for (final entry in entries) {
      final BoundedMetadataPreview? preview;
      if (_commandParameterPreviewMemo.containsKey(entry)) {
        preview = _commandParameterPreviewMemo.remove(entry);
      } else {
        BoundedMetadataPreview? built;
        try {
          final parameters = entry.command['parameters'];
          if (parameters != null) {
            built = writeBoundedMetadataPreview(
              parameters,
              budget: widget.inputBudget,
            );
          }
        } on Object {
          built = null;
        }
        preview = built;
        if (_commandParameterPreviewMemo.length >= maxMemoEntries) {
          _commandParameterPreviewMemo.remove(
            _commandParameterPreviewMemo.keys.first,
          );
        }
      }
      _commandParameterPreviewMemo[entry] = preview;
      visible[entry] = preview;
    }
    return Map<_CommandSearchEntry, BoundedMetadataPreview?>.unmodifiable(
      visible,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final commandSuggestions = _commandSuggestions;
    final commandParameterPreviews = _parameterPreviewsFor(commandSuggestions);
    final pendingPermissionRequest = widget.pendingPermissionRequest;
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
            child: DropTarget(
              key: const Key('prompt-input-drop-target'),
              enable: widget.enabled && !widget.isSending,
              onDragEntered: _handleAttachmentDragEntered,
              onDragExited: _handleAttachmentDragExited,
              onDragDone: _handleAttachmentDrop,
              child: AnimatedContainer(
                key: const Key('prompt-input-surface'),
                duration: const Duration(milliseconds: 120),
                constraints: const BoxConstraints(minHeight: 78),
                decoration: BoxDecoration(
                  color: _isDraggingAttachments
                      ? AppColors.primarySoft
                      : AppColors.surface,
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  border: Border.all(
                    color: _isDraggingAttachments
                        ? AppColors.primary
                        : AppColors.border,
                    width: _isDraggingAttachments ? 2 : 1,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: _isDraggingAttachments
                          ? AppColors.primary.withValues(alpha: 0.16)
                          : AppColors.textPrimary.withValues(alpha: 0.05),
                      blurRadius: _isDraggingAttachments ? 22 : 16,
                      offset: const Offset(0, 5),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_isDraggingAttachments)
                      _AttachmentDropIndicator(
                        kinds: _availableAttachmentKinds(
                          widget.promptCapabilities,
                        ),
                      ),
                    if (pendingPermissionRequest != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
                        child: _PromptPermissionCard(
                          request: pendingPermissionRequest,
                          onAllow: widget.onAllowPermission,
                          onDeny: widget.onDenyPermission,
                          onCancel: widget.onCancelPermission,
                          onSelectOption: widget.onSelectPermissionOption,
                        ),
                      ),
                    if (commandSuggestions.isNotEmpty)
                      _CommandSuggestionPanel(
                        entries: commandSuggestions,
                        parameterPreviews: commandParameterPreviews,
                        onSelect: _insertCommand,
                      ),
                    TextField(
                      controller: _controller,
                      minLines: 1,
                      maxLines: 4,
                      keyboardType: TextInputType.multiline,
                      enabled: widget.enabled && !widget.isSending,
                      onChanged: _handlePromptChanged,
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
                        contentPadding: const EdgeInsets.fromLTRB(
                          13,
                          12,
                          13,
                          8,
                        ),
                        border: InputBorder.none,
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
                        promptCapabilities: widget.promptCapabilities,
                        pendingPermissionRequest: pendingPermissionRequest,
                        toolCallExecutionPolicy: widget.toolCallExecutionPolicy,
                        hasPermissionReviewer: widget.hasPermissionReviewer,
                        onToolCallExecutionPolicyChanged:
                            widget.onToolCallExecutionPolicyChanged,
                        modelOption: widget.modelOption,
                        reasoningEffortOption: widget.reasoningEffortOption,
                        onModelSelected: widget.onModelSelected,
                        onReasoningEffortSelected:
                            widget.onReasoningEffortSelected,
                        onSend: _submit,
                        onStop: widget.onStop,
                      ),
                    ),
                  ],
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
    _commandQuery = null;
    _attachments.clear();
    setState(() {});
  }

  void _insertCommand(_CommandSearchEntry entry) {
    final text = '${entry.invocation} ';
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _commandQuery = null;
    setState(() {});
  }

  void _handlePromptChanged(String value) {
    _commandQuery = _scanBoundedCommandQuery(value, budget: widget.inputBudget);
    setState(() {});
  }

  Future<void> _pickAttachments(PromptAttachmentKind kind) async {
    try {
      final selected = await switch (widget.pickAttachmentsForKind) {
        final picker? => picker(kind),
        null => switch (widget.pickAttachments) {
          final picker? => picker(),
          null => _pickWithFilePicker(kind),
        },
      };
      if (!mounted || !widget.enabled || widget.isSending || selected.isEmpty) {
        return;
      }
      _addAttachments(selected);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not attach file: $error')));
    }
  }

  void _handleAttachmentDragEntered(DropEventDetails details) {
    if (!widget.enabled || widget.isSending || _isDraggingAttachments) return;
    setState(() => _isDraggingAttachments = true);
  }

  void _handleAttachmentDragExited(DropEventDetails details) {
    if (!_isDraggingAttachments) return;
    setState(() => _isDraggingAttachments = false);
  }

  void _handleAttachmentDrop(DropDoneDetails details) {
    if (_isDraggingAttachments) {
      setState(() => _isDraggingAttachments = false);
    }
    if (!widget.enabled || widget.isSending) return;
    _attachDroppedItems(details.files);
  }

  void _attachDroppedItems(List<DropItem> items) {
    final attachments = <PromptAttachment>[];
    var ignoredDirectories = 0;
    for (final item in items) {
      if (item is DropItemDirectory) {
        ignoredDirectories += 1;
        continue;
      }
      if (item.path.isEmpty) continue;
      attachments.add(
        PromptAttachment.fromPath(
          path: item.path,
          name: item.name,
          mimeType: item.mimeType,
        ),
      );
    }
    if (!mounted || !widget.enabled || widget.isSending) return;
    _addAttachments(attachments);
    if (ignoredDirectories > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ignoredDirectories == 1
                ? 'Folders cannot be attached. Drop individual files instead.'
                : '$ignoredDirectories folders were skipped. Drop individual files instead.',
          ),
        ),
      );
    }
  }

  void _addAttachments(Iterable<PromptAttachment> selected) {
    if (!mounted || !widget.enabled || widget.isSending) return;
    setState(() {
      for (final attachment in selected) {
        final duplicate = _attachments.any(
          (existing) => existing.path == attachment.path,
        );
        if (!duplicate) _attachments.add(attachment);
      }
    });
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
    required this.onSelectOption,
  });

  final AcpPermissionRequest request;
  final VoidCallback? onAllow;
  final VoidCallback? onDeny;
  final VoidCallback? onCancel;
  final ValueChanged<String>? onSelectOption;

  bool _isRejectChoice(AcpPermissionChoice choice) {
    return choice.decision == AcpPermissionDecision.deny;
  }

  Widget _structuredChoiceButton(
    AcpPermissionChoice choice, {
    required bool contextIsComplete,
  }) {
    final canSelect = contextIsComplete
        ? choice.decision != null
        : choice.explicitDecision == AcpPermissionDecision.deny;
    final onPressed = onSelectOption == null || !canSelect
        ? null
        : () => onSelectOption!(choice.optionId);
    if (_isRejectChoice(choice)) {
      return OutlinedButton.icon(
        key: Key('prompt-permission-option-${choice.optionId}'),
        onPressed: onPressed,
        icon: const Icon(Icons.block_rounded, size: 15),
        label: Text(choice.name),
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.danger,
          backgroundColor: Colors.white,
          minimumSize: const Size(0, 34),
          padding: const EdgeInsets.symmetric(horizontal: 11),
          side: const BorderSide(color: Color(0xfffecaca)),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.compact,
        ),
      );
    }
    if (choice.decision != AcpPermissionDecision.allow) {
      return OutlinedButton(
        key: Key('prompt-permission-option-${choice.optionId}'),
        onPressed: null,
        child: Text(choice.name),
      );
    }
    return FilledButton.icon(
      key: Key('prompt-permission-option-${choice.optionId}'),
      onPressed: onPressed,
      icon: const Icon(Icons.check_rounded, size: 15),
      label: Text(choice.name),
      style: FilledButton.styleFrom(
        foregroundColor: Colors.white,
        backgroundColor: const Color(0xffc2410c),
        minimumSize: const Size(0, 34),
        padding: const EdgeInsets.symmetric(horizontal: 11),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final displayContext = permissionDisplayContextForRequest(request);
    return Container(
      key: const Key('prompt-permission-card'),
      width: double.infinity,
      decoration: BoxDecoration(
        color: _permissionAccentSoft,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: _permissionAccentBorder, width: 2),
        boxShadow: [
          BoxShadow(
            color: _permissionAccent.withValues(alpha: 0.22),
            blurRadius: 22,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          const Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: 8,
            child: ColoredBox(color: _permissionAccent),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 12, 12),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final compact =
                    constraints.maxWidth < 700 || request.choices.length > 3;
                final details = Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 38,
                      height: 38,
                      decoration: const BoxDecoration(
                        color: _permissionAccent,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.privacy_tip_rounded,
                        color: Colors.white,
                        size: 21,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Wrap(
                            spacing: 7,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              const Text(
                                '等待 Tool Call 权限确认',
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: _permissionAccentDark,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: 0,
                                ),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 7,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: _permissionAccent,
                                  borderRadius: BorderRadius.circular(
                                    AppRadius.pill,
                                  ),
                                ),
                                child: const Text(
                                  '需要处理',
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: 0,
                                  ),
                                ),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 7,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: _permissionAccentMist,
                                  borderRadius: BorderRadius.circular(
                                    AppRadius.pill,
                                  ),
                                  border: Border.all(
                                    color: _permissionAccentBorderSoft,
                                  ),
                                ),
                                child: Text(
                                  request.displayKind,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: _permissionAccentDark,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: 0,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 5),
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
                            request.displayRationale,
                            maxLines: compact ? 2 : 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0,
                            ),
                          ),
                          if (!displayContext.isComplete ||
                              displayContext.entries.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            _PermissionContextView(
                              key: ObjectKey(request),
                              displayContext: displayContext,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                );
                final actions = Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  alignment: WrapAlignment.end,
                  children: [
                    if (request.choices.isNotEmpty)
                      ...request.choices.map(
                        (choice) => _structuredChoiceButton(
                          choice,
                          contextIsComplete: displayContext.isComplete,
                        ),
                      )
                    else ...[
                      OutlinedButton.icon(
                        onPressed: onDeny,
                        icon: const Icon(Icons.block_rounded, size: 15),
                        label: Text(request.denyActionLabel),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.danger,
                          backgroundColor: Colors.white,
                          minimumSize: const Size(0, 34),
                          padding: const EdgeInsets.symmetric(horizontal: 11),
                          side: const BorderSide(color: Color(0xfffecaca)),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                      FilledButton.icon(
                        onPressed: displayContext.isComplete ? onAllow : null,
                        icon: const Icon(Icons.check_rounded, size: 15),
                        label: Text(request.allowActionLabel),
                        style: FilledButton.styleFrom(
                          foregroundColor: Colors.white,
                          backgroundColor: const Color(0xffc2410c),
                          minimumSize: const Size(0, 34),
                          padding: const EdgeInsets.symmetric(horizontal: 11),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                    ],
                    IconButton(
                      tooltip: 'Cancel permission request',
                      onPressed: onCancel,
                      icon: const Icon(Icons.close_rounded, size: 18),
                      color: AppColors.textSecondary,
                      constraints: const BoxConstraints.tightFor(
                        width: 34,
                        height: 34,
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
                      const SizedBox(height: 10),
                      SizedBox(width: double.infinity, child: actions),
                    ],
                  );
                }

                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: details),
                    const SizedBox(width: 12),
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

class _PermissionContextView extends StatefulWidget {
  const _PermissionContextView({super.key, required this.displayContext});

  final PermissionDisplayContext displayContext;

  @override
  State<_PermissionContextView> createState() => _PermissionContextViewState();
}

class _PermissionContextViewState extends State<_PermissionContextView> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      key: const Key('prompt-permission-context'),
      constraints: const BoxConstraints(maxHeight: 180),
      child: Scrollbar(
        controller: _scrollController,
        child: SingleChildScrollView(
          key: const Key('prompt-permission-context-scroll'),
          controller: _scrollController,
          scrollDirection: Axis.vertical,
          child: widget.displayContext.isComplete
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final entry in widget.displayContext.entries)
                      Padding(
                        key: Key(
                          'prompt-permission-context-${_permissionContextEntryKey(entry.label)}',
                        ),
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              entry.label,
                              style: const TextStyle(
                                color: AppColors.textSecondary,
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            SelectableText(
                              entry.value,
                              style: const TextStyle(
                                color: AppColors.textPrimary,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                )
              : Text(
                  PermissionDisplayContext.incompleteWarning,
                  key: const Key('prompt-permission-context-warning'),
                  style: const TextStyle(
                    color: AppColors.danger,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
        ),
      ),
    );
  }
}

String _permissionContextEntryKey(String label) {
  return switch (label) {
    'Command' => 'command',
    'Working directory' => 'cwd',
    'Path' => 'path',
    'Target' => 'target',
    _ => throw StateError('Unsupported permission context label: $label'),
  };
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

class _AttachmentDropIndicator extends StatelessWidget {
  const _AttachmentDropIndicator({required this.kinds});

  final List<PromptAttachmentKind> kinds;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('prompt-attachment-drop-indicator'),
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.34)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.file_download_outlined,
            size: 18,
            color: AppColors.primaryDark,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              _attachmentDropLabel(kinds),
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.primaryDark,
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AttachmentPickerControl extends StatelessWidget {
  const _AttachmentPickerControl({
    required this.enabled,
    required this.promptCapabilities,
    required this.onSelected,
  });

  final bool enabled;
  final AcpPromptCapabilities? promptCapabilities;
  final ValueChanged<PromptAttachmentKind> onSelected;

  @override
  Widget build(BuildContext context) {
    final kinds = _availableAttachmentKinds(promptCapabilities);
    final tooltip = _attachmentPickerTooltip(kinds);
    if (kinds.length == 1) {
      return Semantics(
        button: true,
        label: tooltip,
        child: IconButton(
          tooltip: tooltip,
          onPressed: enabled
              ? () => onSelected(PromptAttachmentKind.file)
              : null,
          icon: const Icon(
            Icons.add_rounded,
            key: Key('prompt-attachment-picker'),
          ),
          color: AppColors.textSecondary,
          disabledColor: AppColors.textTertiary,
          iconSize: 20,
          visualDensity: VisualDensity.compact,
          splashRadius: 18,
        ),
      );
    }

    return PopupMenuButton<PromptAttachmentKind>(
      tooltip: tooltip,
      enabled: enabled,
      onSelected: onSelected,
      itemBuilder: (context) => <PopupMenuEntry<PromptAttachmentKind>>[
        for (final kind in kinds)
          PopupMenuItem<PromptAttachmentKind>(
            value: kind,
            child: _AttachmentPickerMenuItem(
              kind: kind,
              embedsFiles: promptCapabilities?.embeddedContext == true,
            ),
          ),
      ],
      icon: const Icon(Icons.add_rounded, key: Key('prompt-attachment-picker')),
      color: AppColors.surface,
      iconColor: AppColors.textSecondary,
      iconSize: 20,
    );
  }
}

List<PromptAttachmentKind> _availableAttachmentKinds(
  AcpPromptCapabilities? capabilities,
) => <PromptAttachmentKind>[
  PromptAttachmentKind.file,
  if (capabilities?.image == true) PromptAttachmentKind.image,
  if (capabilities?.audio == true) PromptAttachmentKind.audio,
];

String _attachmentDropLabel(List<PromptAttachmentKind> kinds) {
  final labels = kinds
      .map(
        (kind) => switch (kind) {
          PromptAttachmentKind.file => 'files',
          PromptAttachmentKind.image => 'images',
          PromptAttachmentKind.audio => 'audio',
        },
      )
      .toList(growable: false);
  if (labels.length == 1) return 'Drop ${labels.single} here';
  return 'Drop ${labels.sublist(0, labels.length - 1).join(', ')} or ${labels.last} here';
}

class _AttachmentPickerMenuItem extends StatelessWidget {
  const _AttachmentPickerMenuItem({
    required this.kind,
    required this.embedsFiles,
  });

  final PromptAttachmentKind kind;
  final bool embedsFiles;

  @override
  Widget build(BuildContext context) {
    final (icon, label, description) = switch (kind) {
      PromptAttachmentKind.file => (
        Icons.attach_file_rounded,
        'Add file',
        embedsFiles
            ? 'Embedded with ACP context'
            : 'Shared as an ACP resource link',
      ),
      PromptAttachmentKind.image => (
        Icons.image_outlined,
        'Add image',
        'Supported by the connected ACP agent',
      ),
      PromptAttachmentKind.audio => (
        Icons.audio_file_outlined,
        'Add audio',
        'Supported by the connected ACP agent',
      ),
    };
    return Row(
      children: [
        Icon(icon, color: AppColors.primaryDark, size: 19),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                ),
              ),
              Text(
                description,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

String _attachmentPickerTooltip(List<PromptAttachmentKind> kinds) {
  final labels = kinds
      .map(
        (kind) => switch (kind) {
          PromptAttachmentKind.file => 'file',
          PromptAttachmentKind.image => 'image',
          PromptAttachmentKind.audio => 'audio',
        },
      )
      .toList(growable: false);
  if (labels.length == 1) return 'Attach ${labels.single}';
  return 'Attach ${labels.sublist(0, labels.length - 1).join(', ')} or ${labels.last}';
}

class _ComposerControlBar extends StatelessWidget {
  const _ComposerControlBar({
    required this.enabled,
    required this.isSending,
    required this.canSend,
    required this.onPickAttachments,
    required this.promptCapabilities,
    required this.pendingPermissionRequest,
    required this.toolCallExecutionPolicy,
    required this.hasPermissionReviewer,
    required this.onToolCallExecutionPolicyChanged,
    required this.modelOption,
    required this.reasoningEffortOption,
    required this.onModelSelected,
    required this.onReasoningEffortSelected,
    required this.onSend,
    required this.onStop,
  });

  final bool enabled;
  final bool isSending;
  final bool canSend;
  final ValueChanged<PromptAttachmentKind> onPickAttachments;
  final AcpPromptCapabilities? promptCapabilities;
  final AcpPermissionRequest? pendingPermissionRequest;
  final AcpToolCallExecutionPolicy toolCallExecutionPolicy;
  final bool hasPermissionReviewer;
  final ValueChanged<AcpToolCallExecutionPolicy>?
  onToolCallExecutionPolicyChanged;
  final AcpConfigOption? modelOption;
  final AcpConfigOption? reasoningEffortOption;
  final ValueChanged<String>? onModelSelected;
  final ValueChanged<String>? onReasoningEffortSelected;
  final VoidCallback onSend;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final attach = _AttachmentPickerControl(
      enabled: enabled && !isSending,
      promptCapabilities: promptCapabilities,
      onSelected: onPickAttachments,
    );
    final policy = _ToolCallPolicySelector(
      value: toolCallExecutionPolicy,
      hasPermissionReviewer: hasPermissionReviewer,
      enabled: enabled && onToolCallExecutionPolicyChanged != null,
      onChanged: onToolCallExecutionPolicyChanged,
    );
    final sessionConfig =
        (modelOption != null && modelOption!.options.isNotEmpty) ||
            (reasoningEffortOption != null &&
                reasoningEffortOption!.options.isNotEmpty)
        ? _SessionConfigSelectors(
            modelOption: modelOption,
            reasoningEffortOption: reasoningEffortOption,
            enabled: enabled && !isSending,
            onModelSelected: onModelSelected,
            onReasoningEffortSelected: onReasoningEffortSelected,
          )
        : null;
    final action = _PromptActionButton(
      isSending: isSending,
      canSend: canSend,
      onSend: onSend,
      onStop: onStop,
    );
    final permissionChip = pendingPermissionRequest == null
        ? null
        : _PermissionServiceChip(request: pendingPermissionRequest!);

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 560) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (permissionChip != null) ...[
                Align(alignment: Alignment.centerLeft, child: permissionChip),
                const SizedBox(height: 6),
              ],
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
              if (sessionConfig != null) ...[
                const SizedBox(height: 6),
                Align(alignment: Alignment.centerRight, child: sessionConfig),
              ],
            ],
          );
        }

        return Row(
          children: [
            attach,
            const _ComposerDivider(),
            if (permissionChip != null) ...[
              Flexible(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: permissionChip,
                ),
              ),
              const SizedBox(width: 8),
            ],
            Flexible(
              child: Align(alignment: Alignment.centerLeft, child: policy),
            ),
            const Spacer(),
            if (sessionConfig != null) ...[
              Flexible(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: sessionConfig,
                ),
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

class _PermissionServiceChip extends StatelessWidget {
  const _PermissionServiceChip({required this.request});

  final AcpPermissionRequest request;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      label: 'Pending tool call permission',
      child: Container(
        key: const Key('prompt-permission-service-chip'),
        height: 30,
        constraints: const BoxConstraints(maxWidth: 236),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: _permissionAccent,
          borderRadius: BorderRadius.circular(AppRadius.pill),
          border: Border.all(color: _permissionAccentDark, width: 1.2),
          boxShadow: [
            BoxShadow(
              color: _permissionAccent.withValues(alpha: 0.26),
              blurRadius: 16,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.privacy_tip_rounded,
              color: Colors.white,
              size: 16,
            ),
            const SizedBox(width: 6),
            const Flexible(
              child: Text(
                'Tool Call 待确认',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Container(width: 1, height: 14, color: Colors.white54),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                request.displayKind,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ToolCallPolicySelector extends StatelessWidget {
  const _ToolCallPolicySelector({
    required this.value,
    required this.hasPermissionReviewer,
    required this.enabled,
    required this.onChanged,
  });

  final AcpToolCallExecutionPolicy value;
  final bool hasPermissionReviewer;
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
              description: _policyDescription(
                policy,
                hasPermissionReviewer: hasPermissionReviewer,
              ),
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

class _SessionConfigSelectors extends StatelessWidget {
  const _SessionConfigSelectors({
    required this.modelOption,
    required this.reasoningEffortOption,
    required this.enabled,
    required this.onModelSelected,
    required this.onReasoningEffortSelected,
  });

  final AcpConfigOption? modelOption;
  final AcpConfigOption? reasoningEffortOption;
  final bool enabled;
  final ValueChanged<String>? onModelSelected;
  final ValueChanged<String>? onReasoningEffortSelected;

  @override
  Widget build(BuildContext context) {
    final hasModelChoices =
        modelOption != null && modelOption!.options.isNotEmpty;
    final hasEffortChoices =
        reasoningEffortOption != null &&
        reasoningEffortOption!.options.isNotEmpty;
    final modelEnabled = enabled && hasModelChoices && onModelSelected != null;
    final effortEnabled =
        enabled && hasEffortChoices && onReasoningEffortSelected != null;
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      alignment: WrapAlignment.end,
      children: [
        if (hasModelChoices)
          _SessionConfigDropdown(
            key: const Key('prompt-model-selector'),
            tooltip: 'Select model',
            icon: Icons.memory_rounded,
            option: modelOption!,
            enabled: modelEnabled,
            includeChoiceGroup: true,
            onSelected: onModelSelected,
          ),
        if (hasEffortChoices)
          _SessionConfigDropdown(
            key: const Key('prompt-reasoning-effort-selector'),
            tooltip: 'Select reasoning effort',
            icon: Icons.psychology_alt_rounded,
            option: reasoningEffortOption!,
            enabled: effortEnabled,
            onSelected: onReasoningEffortSelected,
          ),
      ],
    );
  }
}

class _SessionConfigDropdown extends StatelessWidget {
  const _SessionConfigDropdown({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.option,
    required this.enabled,
    required this.onSelected,
    this.includeChoiceGroup = false,
  });

  final String tooltip;
  final IconData icon;
  final AcpConfigOption option;
  final bool enabled;
  final ValueChanged<String>? onSelected;
  final bool includeChoiceGroup;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: tooltip,
      enabled: enabled,
      onSelected: onSelected,
      itemBuilder: (context) => [
        for (final choice in option.options)
          PopupMenuItem<String>(
            value: choice.value,
            child: _PopupChoiceRow(
              selected: choice.value == option.currentValue,
              icon: icon,
              label: includeChoiceGroup && choice.groupName != null
                  ? '${choice.groupName} · ${choice.label}'
                  : choice.label,
              description: choice.description ?? '',
            ),
          ),
      ],
      child: _ComposerControlButton(
        icon: icon,
        label: option.currentChoiceLabel,
        enabled: enabled,
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
          key: const Key('prompt-action-button'),
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

String _policyDescription(
  AcpToolCallExecutionPolicy policy, {
  required bool hasPermissionReviewer,
}) {
  return switch (policy) {
    AcpToolCallExecutionPolicy.defaultPermissions => '所有请求都由你确认',
    AcpToolCallExecutionPolicy.autoReview =>
      hasPermissionReviewer ? '旁路 agent 审查，未决时再确认' : '使用信任规则，未命中时再确认',
    AcpToolCallExecutionPolicy.fullAccess => '自动允许所有 tool call',
  };
}

class _CommandSuggestionPanel extends StatelessWidget {
  const _CommandSuggestionPanel({
    required this.entries,
    required this.parameterPreviews,
    required this.onSelect,
  });

  final List<_CommandSearchEntry> entries;
  final Map<_CommandSearchEntry, BoundedMetadataPreview?> parameterPreviews;
  final ValueChanged<_CommandSearchEntry> onSelect;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 154),
      child: ListView.separated(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(6, 6, 6, 4),
        itemBuilder: (context, index) {
          final entry = entries[index];
          return _CommandSuggestionTile(
            invocation: entry.invocation,
            description: entry.description,
            onTap: () => onSelect(entry),
            parametersPreview: parameterPreviews[entry],
          );
        },
        separatorBuilder: (_, _) => const SizedBox(height: 3),
        itemCount: entries.length,
      ),
    );
  }
}

final class _CommandSearchEntry {
  const _CommandSearchEntry({
    required this.command,
    required this.invocation,
    required this.lowerName,
    required this.lowerDescription,
    required this.description,
  });

  final Map<String, Object?> command;
  final String invocation;
  final String lowerName;
  final String lowerDescription;
  final String description;
}

class _CommandSuggestionTile extends StatelessWidget {
  const _CommandSuggestionTile({
    required this.invocation,
    required this.description,
    required this.onTap,
    required this.parametersPreview,
  });

  final String invocation;
  final String description;
  final VoidCallback onTap;
  final BoundedMetadataPreview? parametersPreview;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.sm),
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 38),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: AppColors.surfaceRaised,
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
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
            if (parametersPreview != null) ...[
              const SizedBox(height: 3),
              SelectableText(
                parametersPreview!.text,
                key: const Key('command-parameters-preview'),
                maxLines: 1,
                style: const TextStyle(
                  color: AppColors.textTertiary,
                  fontFamily: 'monospace',
                  fontSize: 10,
                ),
              ),
              if (parametersPreview!.omission != null)
                Text(
                  'Details omitted · ${parametersPreview!.omission!.resource}',
                  style: const TextStyle(
                    color: AppColors.warning,
                    fontSize: 10,
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

String _commandInvocationFromName(String name) {
  if (name.isEmpty) return '';
  return name.startsWith('/') ? name : '/$name';
}

String? _scanBoundedCommandQuery(
  String input, {
  required AcpInputBudget budget,
}) {
  const maxCommandQueryCodeUnits = 1024;
  final limit = budget.maxStructuredStringBytes < maxCommandQueryCodeUnits
      ? budget.maxStructuredStringBytes
      : maxCommandQueryCodeUnits;
  final inputLength = input.length;
  var index = 0;

  while (index < inputLength) {
    if (index >= limit) return null;
    final scalar = _commandQueryScalarAt(input, index, limit: limit);
    if (scalar == null) return null;
    if (!_isUnicodeWhitespace(scalar.codePoint)) break;
    index += scalar.codeUnits;
  }
  if (index >= inputLength || index >= limit) return null;
  if (input.codeUnitAt(index) != 0x2f) return null;
  index += 1;
  final queryStart = index;

  while (index < inputLength) {
    if (index >= limit) return null;
    final scalar = _commandQueryScalarAt(input, index, limit: limit);
    if (scalar == null || _isUnicodeWhitespace(scalar.codePoint)) return null;
    index += scalar.codeUnits;
  }
  return input.substring(queryStart, index).toLowerCase();
}

({int codePoint, int codeUnits})? _commandQueryScalarAt(
  String input,
  int index, {
  required int limit,
}) {
  final first = input.codeUnitAt(index);
  if (first < 0xd800 || first > 0xdbff) {
    return (codePoint: first, codeUnits: 1);
  }
  final secondIndex = index + 1;
  if (secondIndex >= input.length) {
    return (codePoint: first, codeUnits: 1);
  }
  if (secondIndex >= limit) return null;
  final second = input.codeUnitAt(secondIndex);
  if (second < 0xdc00 || second > 0xdfff) {
    return (codePoint: first, codeUnits: 1);
  }
  return (
    codePoint: 0x10000 + ((first - 0xd800) << 10) + second - 0xdc00,
    codeUnits: 2,
  );
}

bool _isUnicodeWhitespace(int codePoint) {
  return (codePoint >= 0x09 && codePoint <= 0x0d) ||
      codePoint == 0x20 ||
      codePoint == 0x85 ||
      codePoint == 0xa0 ||
      codePoint == 0x1680 ||
      (codePoint >= 0x2000 && codePoint <= 0x200a) ||
      codePoint == 0x2028 ||
      codePoint == 0x2029 ||
      codePoint == 0x202f ||
      codePoint == 0x205f ||
      codePoint == 0x3000;
}

String _commandString(Map<String, Object?> command, String key) {
  final value = command[key];
  return value is String ? value.trim() : '';
}

Future<List<PromptAttachment>> _pickWithFilePicker(
  PromptAttachmentKind kind,
) async {
  final result = await FilePicker.platform.pickFiles(
    type: switch (kind) {
      PromptAttachmentKind.file => FileType.any,
      PromptAttachmentKind.image => FileType.image,
      PromptAttachmentKind.audio => FileType.audio,
    },
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
