import '../../chat_strings.dart';
import '../../chat_theme.dart';
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:ianvs_design/ianvs_design.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../models/chat_capabilities.dart';
import '../../models/chat_input_budget.dart';
import '../../models/chat_permission_request.dart';
import '../../models/chat_session_settings.dart';
import '../../models/prompt_attachment.dart';
export '../../models/prompt_attachment.dart' show PromptAttachmentKind;
import '../../platform/chat_platform.dart';
export '../../platform/chat_platform.dart' show readDroppedImageAttachment;
import '../../platform/prompt_image_clipboard.dart';
export '../../platform/prompt_image_clipboard.dart' show emptyClipboardImage;
import '../../models/chat_message.dart';
import '../../models/permission_context.dart';
import '../bounded_metadata_preview.dart';
import 'accessible_text_field.dart';

typedef PromptSendCallback =
    void Function(String text, List<PromptAttachment> attachments);
typedef PromptAttachmentPicker = Future<List<PromptAttachment>> Function();
typedef PromptAttachmentKindPicker =
    Future<List<PromptAttachment>> Function(PromptAttachmentKind kind);
typedef PromptImageClipboardReader = Future<PromptAttachment?> Function();
typedef PromptDroppedImageReader =
    Future<PromptAttachment?> Function(PromptAttachment attachment);
typedef SessionConfigSelectionCallback =
    void Function(String configId, Object value);

bool _samePromptHistory(List<String> left, List<String> right) {
  if (identical(left, right)) return true;
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

class PromptAttachmentController {
  _PromptInputState? _state;
  Future<void> _pendingIngress = Future<void>.value();

  bool get isAttached => _state != null;
  Future<void> get pendingIngress => _pendingIngress;

  void _attach(_PromptInputState state) {
    _state = state;
  }

  void _detach(_PromptInputState state) {
    if (identical(_state, state)) _state = null;
  }

  void setDragging(bool value) {
    _state?._setExternalAttachmentDragging(value);
  }

  Future<void> addDroppedItems(
    List<DropItem> items, {
    bool inlineImages = false,
  }) {
    final state = _state;
    final operation = state == null
        ? Future<void>.value()
        : state._attachDroppedItems(items, inlineImages: inlineImages);
    _pendingIngress = operation;
    return operation;
  }
}

class PromptInput extends StatefulWidget {
  const PromptInput({
    super.key,
    this.agentName = 'Codex',
    this.enabled = true,
    required this.isSending,
    this.promptAppearsStalled = false,
    required this.onSend,
    required this.onStop,
    this.showAttachmentControl = true,
    this.showExecutionPolicy = true,
    this.canQueueWhileSending = true,
    this.availableCommands = const <Map<String, Object?>>[],
    this.availableCommandsRevision = 0,
    this.promptCapabilities,
    this.pendingPermissionRequest,
    this.onAllowPermission,
    this.onDenyPermission,
    this.onCancelPermission,
    this.onSelectPermissionOption,
    this.toolCallExecutionPolicy =
        ChatToolCallExecutionPolicy.defaultPermissions,
    this.hasPermissionReviewer = false,
    this.onToolCallExecutionPolicyChanged,
    this.modelOption,
    this.reasoningEffortOption,
    this.onModelSelected,
    this.onReasoningEffortSelected,
    this.configOptions = const <ChatConfigOption>[],
    this.onConfigOptionSelected,
    this.pickAttachments,
    this.pickAttachmentsForKind,
    this.attachmentController,
    this.readClipboardImage = emptyClipboardImage,
    this.readDroppedImage = readDroppedImageAttachment,
    this.workspaceRoots = const <String>[],
    this.imageAttachmentLimitation,
    this.promptHistory = const <String>[],
    this.queuedPrompts = const <ChatQueuedPrompt>[],
    this.onGuideQueuedPrompt,
    this.onRemoveQueuedPrompt,
    this.onClearQueuedPrompts,
    this.onReorderQueuedPrompt,
    this.inputBudget = const ChatInputBudget(),
  });

  final bool canQueueWhileSending;
  final bool showAttachmentControl;
  final bool showExecutionPolicy;
  final String agentName;
  final bool enabled;
  final bool isSending;
  final bool promptAppearsStalled;
  final PromptSendCallback onSend;
  final VoidCallback onStop;
  final List<Map<String, Object?>> availableCommands;
  final int availableCommandsRevision;
  final ChatPromptCapabilities? promptCapabilities;
  final ChatPermissionRequest? pendingPermissionRequest;
  final VoidCallback? onAllowPermission;
  final VoidCallback? onDenyPermission;
  final VoidCallback? onCancelPermission;
  final ValueChanged<String>? onSelectPermissionOption;
  final ChatToolCallExecutionPolicy toolCallExecutionPolicy;
  final bool hasPermissionReviewer;
  final ValueChanged<ChatToolCallExecutionPolicy>?
  onToolCallExecutionPolicyChanged;
  final ChatConfigOption? modelOption;
  final ChatConfigOption? reasoningEffortOption;
  final ValueChanged<String>? onModelSelected;
  final ValueChanged<String>? onReasoningEffortSelected;
  final List<ChatConfigOption> configOptions;
  final SessionConfigSelectionCallback? onConfigOptionSelected;
  final PromptAttachmentPicker? pickAttachments;
  final PromptAttachmentKindPicker? pickAttachmentsForKind;
  final PromptAttachmentController? attachmentController;
  final PromptImageClipboardReader readClipboardImage;
  final PromptDroppedImageReader readDroppedImage;
  final List<String> workspaceRoots;
  final String? imageAttachmentLimitation;
  final List<String> promptHistory;
  final List<ChatQueuedPrompt> queuedPrompts;
  final ValueChanged<int>? onGuideQueuedPrompt;
  final ValueChanged<int>? onRemoveQueuedPrompt;
  final VoidCallback? onClearQueuedPrompts;
  final void Function(int oldIndex, int newIndex)? onReorderQueuedPrompt;
  final ChatInputBudget inputBudget;

  @override
  State<PromptInput> createState() => _PromptInputState();
}

class _PromptInputState extends State<PromptInput> {
  final TextEditingController _controller = TextEditingController();
  final List<PromptAttachment> _attachments = <PromptAttachment>[];
  int? _historyIndex;
  bool _isDraggingAttachments = false;
  String? _commandQuery;
  List<_CommandSearchEntry> _commandSearchEntries = <_CommandSearchEntry>[];
  LinkedHashMap<_CommandSearchEntry, BoundedMetadataPreview?>
  _commandParameterPreviewMemo =
      LinkedHashMap<_CommandSearchEntry, BoundedMetadataPreview?>();

  @override
  void initState() {
    super.initState();
    widget.attachmentController?._attach(this);
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
    if (!identical(
      widget.attachmentController,
      oldWidget.attachmentController,
    )) {
      oldWidget.attachmentController?._detach(this);
      widget.attachmentController?._attach(this);
    }
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
    if (!widget.enabled && _isDraggingAttachments) {
      _isDraggingAttachments = false;
    }
    if (oldWidget.promptCapabilities?.image == true &&
        widget.promptCapabilities?.image != true) {
      final removedInlineImages = _attachments
          .where((attachment) => attachment.isInline && attachment.isImage)
          .length;
      if (removedInlineImages > 0) {
        _attachments.removeWhere(
          (attachment) => attachment.isInline && attachment.isImage,
        );
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'The selected model does not accept inline images. '
                'Reattach the image as a file to share its path.',
              ),
            ),
          );
        });
      }
    }
    if (!_samePromptHistory(oldWidget.promptHistory, widget.promptHistory)) {
      _historyIndex = null;
    }
  }

  bool get _canSend =>
      (_controller.text.trim().isNotEmpty || _attachments.isNotEmpty) &&
      widget.enabled &&
      (!widget.isSending || widget.canQueueWhileSending);

  List<_CommandSearchEntry> get _commandSuggestions {
    if (!widget.enabled || _commandSearchEntries.isEmpty) {
      return <_CommandSearchEntry>[];
    }
    final query = _commandQuery;
    if (query == null) return <_CommandSearchEntry>[];
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
    _commandSearchEntries = <_CommandSearchEntry>[];
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
          final parameters =
              entry.command['input'] ?? entry.command['parameters'];
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
    widget.attachmentController?._detach(this);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final commandSuggestions = _commandSuggestions;
    final commandParameterPreviews = _parameterPreviewsFor(commandSuggestions);
    final pendingPermissionRequest = widget.pendingPermissionRequest;
    final viewportHeight = MediaQuery.sizeOf(context).height;
    final maximumContentHeight = (viewportHeight * 0.552)
        .clamp(220.0, 520.0)
        .toDouble();
    return Container(
      color: ChatTheme.of(context).surface,
      padding: EdgeInsets.fromLTRB(20, 8, 20, 18),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 800,
            maxHeight: maximumContentHeight,
          ),
          child: SingleChildScrollView(
            key: Key('prompt-input-overflow-scroll'),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.promptAppearsStalled) ...[
                  _PromptIdleWarning(onStop: widget.onStop),
                  SizedBox(height: 8),
                ],
                if (widget.queuedPrompts.isNotEmpty) ...[
                  _PromptQueueTray(
                    prompts: widget.queuedPrompts,
                    onGuide: widget.onGuideQueuedPrompt,
                    onRemove: widget.onRemoveQueuedPrompt,
                    onClear: widget.onClearQueuedPrompts,
                    onReorder: widget.onReorderQueuedPrompt,
                  ),
                  SizedBox(height: 8),
                ],
                CallbackShortcuts(
                  bindings:
                      widget.promptCapabilities?.image == true && widget.enabled
                      ? <ShortcutActivator, VoidCallback>{
                          SingleActivator(
                            LogicalKeyboardKey.keyV,
                            meta: true,
                          ): () =>
                              unawaited(_pasteClipboardImageOrText()),
                          SingleActivator(
                            LogicalKeyboardKey.keyV,
                            control: true,
                          ): () =>
                              unawaited(_pasteClipboardImageOrText()),
                        }
                      : <ShortcutActivator, VoidCallback>{},
                  child: DropTarget(
                    key: Key('prompt-input-drop-target'),
                    enable:
                        widget.attachmentController == null && widget.enabled,
                    onDragEntered: _handleAttachmentDragEntered,
                    onDragExited: _handleAttachmentDragExited,
                    onDragDone: _handleAttachmentDrop,
                    child: AnimatedContainer(
                      key: Key('prompt-input-surface'),
                      duration: Duration(milliseconds: 120),
                      constraints: BoxConstraints(minHeight: 152),
                      decoration: BoxDecoration(
                        color: _isDraggingAttachments
                            ? ChatTheme.of(context).accentMist
                            : ChatTheme.of(context).surface,
                        borderRadius: BorderRadius.circular(
                          context.ianvs.panelRadius,
                        ),
                        border: Border.all(
                          color: _isDraggingAttachments
                              ? ChatTheme.of(context).accent
                              : ChatTheme.of(context).border,
                          width: _isDraggingAttachments ? 2 : 1,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: ChatTheme.of(context).textPrimary.withValues(
                              alpha: _isDraggingAttachments ? 0.11 : 0.045,
                            ),
                            blurRadius: _isDraggingAttachments ? 24 : 18,
                            offset: Offset(0, 6),
                          ),
                          BoxShadow(
                            color: ChatTheme.of(
                              context,
                            ).textPrimary.withValues(alpha: 0.025),
                            blurRadius: 4,
                            offset: Offset(0, 1),
                          ),
                        ],
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Column(
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
                                  padding: EdgeInsets.fromLTRB(8, 8, 8, 6),
                                  child: _PromptPermissionCard(
                                    request: pendingPermissionRequest,
                                    onAllow: widget.onAllowPermission,
                                    onDeny: widget.onDenyPermission,
                                    onCancel: widget.onCancelPermission,
                                    onSelectOption:
                                        widget.onSelectPermissionOption,
                                  ),
                                ),
                              if (commandSuggestions.isNotEmpty)
                                _CommandSuggestionPanel(
                                  entries: commandSuggestions,
                                  parameterPreviews: commandParameterPreviews,
                                  onSelect: _insertCommand,
                                ),
                              if (_attachments.isNotEmpty)
                                _AttachmentTray(
                                  attachments: _attachments,
                                  promptCapabilities: widget.promptCapabilities,
                                  onRemove: _removeAttachment,
                                ),
                              if (_attachments.any(
                                    (attachment) => attachment.isImage,
                                  ) &&
                                  widget.imageAttachmentLimitation != null)
                                _ImageAttachmentLimitationNotice(
                                  message: widget.imageAttachmentLimitation!,
                                ),
                              AccessibleTextField(
                                label: 'Prompt message for ${widget.agentName}',
                                description:
                                    'Write a prompt to ${widget.agentName}',
                                controller: _controller,
                                enabled: widget.enabled,
                                multiline: true,
                                onChanged: _handlePromptChanged,
                                builder: (focusNode) => Focus(
                                  canRequestFocus: false,
                                  skipTraversal: true,
                                  onKeyEvent: _handlePromptKeyEvent,
                                  child: TextField(
                                    controller: _controller,
                                    focusNode: focusNode,
                                    minLines: 1,
                                    maxLines: 6,
                                    keyboardType: TextInputType.multiline,
                                    enabled: widget.enabled,
                                    onChanged: _handlePromptChanged,
                                    style: TextStyle(
                                      color: ChatTheme.of(context).textPrimary,
                                      fontSize: 15,
                                      height: 1.48,
                                    ),
                                    decoration: InputDecoration(
                                      hint: ExcludeSemantics(
                                        child: Text(
                                          ChatStrings.of(
                                                context,
                                              )?.promptHint(widget.agentName) ??
                                              '发送消息给 ${widget.agentName}',
                                          style: TextStyle(
                                            color: ChatTheme.of(
                                              context,
                                            ).textTertiary,
                                            fontSize: 15,
                                            fontWeight: FontWeight.w400,
                                          ),
                                        ),
                                      ),
                                      filled: false,
                                      isCollapsed: true,
                                      contentPadding: EdgeInsets.fromLTRB(
                                        15,
                                        14,
                                        15,
                                        24,
                                      ),
                                      border: InputBorder.none,
                                      enabledBorder: InputBorder.none,
                                      focusedBorder: InputBorder.none,
                                      disabledBorder: InputBorder.none,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          Padding(
                            padding: EdgeInsets.fromLTRB(10, 0, 10, 10),
                            child: _ComposerControlBar(
                              enabled: widget.enabled,
                              isSending: widget.isSending,
                              canSend: _canSend,
                              onPickAttachments: widget.showAttachmentControl
                                  ? _pickAttachments
                                  : null,
                              showExecutionPolicy: widget.showExecutionPolicy,
                              promptCapabilities: widget.promptCapabilities,
                              pendingPermissionRequest:
                                  pendingPermissionRequest,
                              toolCallExecutionPolicy:
                                  widget.toolCallExecutionPolicy,
                              hasPermissionReviewer:
                                  widget.hasPermissionReviewer,
                              onToolCallExecutionPolicyChanged:
                                  widget.onToolCallExecutionPolicyChanged,
                              modelOption: widget.modelOption,
                              reasoningEffortOption:
                                  widget.reasoningEffortOption,
                              onModelSelected: widget.onModelSelected,
                              onReasoningEffortSelected:
                                  widget.onReasoningEffortSelected,
                              configOptions: widget.configOptions,
                              onConfigOptionSelected:
                                  widget.onConfigOptionSelected,
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
          ),
        ),
      ),
    );
  }

  KeyEventResult _handlePromptKeyEvent(FocusNode node, KeyEvent event) {
    if ((event is KeyDownEvent || event is KeyRepeatEvent) &&
        _handleHistoryKey(event)) {
      return KeyEventResult.handled;
    }
    final composing = _controller.value.composing;
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.enter ||
        HardwareKeyboard.instance.isShiftPressed ||
        (composing.isValid && !composing.isCollapsed)) {
      return KeyEventResult.ignored;
    }
    _submit();
    return KeyEventResult.handled;
  }

  void _submit() {
    if (!_canSend) return;
    final text = _controller.text;
    final attachments = List<PromptAttachment>.unmodifiable(_attachments);
    widget.onSend(text, attachments);
    _controller.clear();
    _historyIndex = null;
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
    _historyIndex = null;
    _commandQuery = _scanBoundedCommandQuery(value, budget: widget.inputBudget);
    setState(() {});
  }

  bool _handleHistoryKey(KeyEvent event) {
    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.arrowUp &&
        key != LogicalKeyboardKey.arrowDown) {
      return false;
    }
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isShiftPressed ||
        keyboard.isAltPressed ||
        keyboard.isControlPressed ||
        keyboard.isMetaPressed) {
      return false;
    }
    final composing = _controller.value.composing;
    if (composing.isValid && !composing.isCollapsed) return false;

    final history = widget.promptHistory;
    if (history.isEmpty) return false;
    if (!_isAtHistoryBoundary(moveUp: key == LogicalKeyboardKey.arrowUp)) {
      return false;
    }

    if (key == LogicalKeyboardKey.arrowUp) {
      final current = _historyIndex;
      _historyIndex = current == null
          ? history.length - 1
          : math.max(0, current - 1);
      _showHistoryText(history[_historyIndex!]);
      return true;
    }

    final current = _historyIndex;
    if (current == null) return false;
    if (current >= history.length - 1) {
      _historyIndex = null;
      _showHistoryText('');
      return true;
    }
    _historyIndex = current + 1;
    _showHistoryText(history[_historyIndex!]);
    return true;
  }

  bool _isAtHistoryBoundary({required bool moveUp}) {
    final value = _controller.value;
    final selection = value.selection;
    if (!selection.isValid || !selection.isCollapsed) return false;
    final caret = selection.extentOffset;
    if (moveUp) {
      return !value.text.substring(0, caret).contains('\n');
    }
    return !value.text.substring(caret).contains('\n');
  }

  void _showHistoryText(String text) {
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _commandQuery = _scanBoundedCommandQuery(text, budget: widget.inputBudget);
    setState(() {});
  }

  Future<void> _pickAttachments(PromptAttachmentKind kind) async {
    try {
      final selected = await switch (widget.pickAttachmentsForKind) {
        final picker? => picker(kind),
        null => switch (widget.pickAttachments) {
          final picker? => picker(),
          null => ChatPlatformScope.of(context).pickAttachments(kind),
        },
      };
      if (!mounted || !widget.enabled || selected.isEmpty) {
        return;
      }
      final prepared = await _prepareAttachments(
        selected,
        inlineImages: kind == PromptAttachmentKind.image,
      );
      if (!mounted || !widget.enabled) return;
      _addAttachments(prepared);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not attach file: $error')));
    }
  }

  void _handleAttachmentDragEntered(DropEventDetails details) {
    if (!widget.enabled || _isDraggingAttachments) return;
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
    if (!widget.enabled) return;
    unawaited(_attachDroppedItems(details.files));
  }

  Future<void> _attachDroppedItems(
    List<DropItem> items, {
    bool inlineImages = false,
  }) async {
    final selected = <PromptAttachment>[];
    var ignoredDirectories = 0;
    for (final item in items) {
      if (item is DropItemDirectory) {
        ignoredDirectories += 1;
        continue;
      }
      if (item.path.isEmpty) continue;
      final attachment = PromptAttachment.fromPath(
        path: item.path,
        name: item.name,
        mimeType: item.mimeType,
      );
      selected.add(attachment);
    }
    if (!mounted || !widget.enabled) return;
    final attachments = await _prepareAttachments(
      selected,
      inlineImages: inlineImages,
    );
    if (!mounted || !widget.enabled) return;
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
    if (!mounted || !widget.enabled) return;
    setState(() {
      for (final attachment in selected) {
        final duplicate = _attachments.any(
          (existing) => existing.identity == attachment.identity,
        );
        if (!duplicate) _attachments.add(attachment);
      }
    });
  }

  void _removeAttachment(PromptAttachment attachment) {
    setState(() {
      _attachments.removeWhere((item) => item.identity == attachment.identity);
    });
  }

  void _setExternalAttachmentDragging(bool value) {
    if (!mounted || !widget.enabled || _isDraggingAttachments == value) {
      return;
    }
    setState(() => _isDraggingAttachments = value);
  }

  Future<PromptAttachment?> _inlineImageAttachment(
    PromptAttachment attachment,
  ) async {
    try {
      return await (identical(
            widget.readDroppedImage,
            readDroppedImageAttachment,
          )
          ? ChatPlatformScope.of(context).readImage(attachment)
          : widget.readDroppedImage(attachment));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not attach image: $error')),
        );
      }
      return null;
    }
  }

  Future<List<PromptAttachment>> _prepareAttachments(
    Iterable<PromptAttachment> selected, {
    required bool inlineImages,
  }) async {
    final prepared = <PromptAttachment>[];
    final external = <PromptAttachment>[];
    for (final attachment in selected) {
      if (attachment.isInline ||
          attachment.path.isEmpty ||
          !await _isOutsideWorkspace(attachment.path)) {
        prepared.add(attachment);
      } else {
        external.add(attachment);
      }
    }

    if (external.isNotEmpty) {
      final approved = await _confirmOutsideWorkspaceRead(external);
      if (!mounted || !approved) return prepared;
      prepared.addAll(
        external.map(
          (attachment) =>
              attachment.copyWith(userApprovedOutsideWorkspace: true),
        ),
      );
    }

    if (widget.imageAttachmentLimitation != null) {
      for (var index = 0; index < prepared.length; index += 1) {
        final attachment = prepared[index];
        if (attachment.isImage && !attachment.isInline) {
          prepared[index] = attachment.copyWith(forceResourceLink: true);
        }
      }
    }

    if (!inlineImages || widget.promptCapabilities?.image != true) {
      return prepared;
    }

    final projected = <PromptAttachment>[];
    for (final attachment in prepared) {
      if (!attachment.isImage || attachment.isInline) {
        projected.add(attachment);
        continue;
      }
      final inlineAttachment = await _inlineImageAttachment(attachment);
      if (inlineAttachment != null) projected.add(inlineAttachment);
    }
    return projected;
  }

  Future<bool> _isOutsideWorkspace(String path) async {
    if (widget.workspaceRoots.isEmpty) return false;
    final normalizedPath = await _resolvedPath(path, isDirectory: false);
    for (final root in widget.workspaceRoots) {
      final trimmed = root.trim();
      if (trimmed.isEmpty) continue;
      final normalizedRoot = await _resolvedPath(trimmed, isDirectory: true);
      if (p.equals(normalizedPath, normalizedRoot) ||
          p.isWithin(normalizedRoot, normalizedPath)) {
        return false;
      }
    }
    return true;
  }

  Future<String> _resolvedPath(String path, {required bool isDirectory}) =>
      ChatPlatformScope.of(context).resolvePath(path, isDirectory: isDirectory);

  Future<bool> _confirmOutsideWorkspaceRead(
    List<PromptAttachment> attachments,
  ) async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: Key('prompt-outside-workspace-confirmation'),
        title: Text('Allow access outside this workspace?'),
        content: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 480),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                attachments.length == 1
                    ? 'ACP Client needs to read this file once to attach it to '
                          'the current prompt.'
                    : 'ACP Client needs to read these files once to attach '
                          'them to the current prompt.',
              ),
              SizedBox(height: 12),
              Container(
                constraints: BoxConstraints(maxHeight: 180),
                padding: EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: ChatTheme.of(context).surfaceRaised,
                  borderRadius: BorderRadius.circular(
                    context.ianvs.panelRadius,
                  ),
                  border: Border.all(color: ChatTheme.of(context).border),
                ),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final attachment in attachments)
                        Padding(
                          padding: EdgeInsets.symmetric(vertical: 3),
                          child: SelectableText(
                            attachment.path,
                            style: TextStyle(
                              color: ChatTheme.of(context).textSecondary,
                              fontFamily:
                                  context.ianvsTypography.code.fontFamily,
                              fontFamilyFallback: context
                                  .ianvsTypography
                                  .code
                                  .fontFamilyFallback,
                              fontSize: 11,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              SizedBox(height: 10),
              Text(
                'This approval applies only to these attachments and does not '
                'grant access to the containing folder.',
                style: TextStyle(
                  color: ChatTheme.of(context).textSecondary,
                  fontSize: 12,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            key: Key('prompt-outside-workspace-cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('Cancel'),
          ),
          FilledButton(
            key: Key('prompt-outside-workspace-allow-once'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('Allow once'),
          ),
        ],
      ),
    );
    return approved == true;
  }

  Future<void> _pasteClipboardImageOrText() async {
    try {
      final image = await widget.readClipboardImage();
      if (!mounted || !widget.enabled) return;
      if (image != null) {
        _addAttachments(<PromptAttachment>[image]);
        return;
      }
    } on MissingPluginException {
      // Fall through to plain text paste on platforms without image support.
    } on PlatformException catch (error) {
      if (error.code != 'clipboard_image_unavailable') {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                error.message ?? 'Could not paste clipboard image.',
              ),
            ),
          );
        }
        return;
      }
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not paste clipboard image: $error')),
        );
      }
      return;
    }

    final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted || clipboard?.text == null) return;
    _insertClipboardText(clipboard!.text!);
  }

  void _insertClipboardText(String text) {
    final value = _controller.value;
    final selection = value.selection;
    final start = selection.isValid ? selection.start : value.text.length;
    final end = selection.isValid ? selection.end : value.text.length;
    final nextText = value.text.replaceRange(start, end, text);
    final caret = start + text.length;
    _controller.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: caret),
    );
    _handlePromptChanged(nextText);
  }
}

class PromptAttachmentDropRegion extends StatefulWidget {
  const PromptAttachmentDropRegion({
    super.key,
    required this.controller,
    required this.enabled,
    required this.promptCapabilities,
    required this.child,
  });

  final PromptAttachmentController controller;
  final bool enabled;
  final ChatPromptCapabilities? promptCapabilities;
  final Widget child;

  @override
  State<PromptAttachmentDropRegion> createState() =>
      _PromptAttachmentDropRegionState();
}

class _PromptAttachmentDropRegionState
    extends State<PromptAttachmentDropRegion> {
  bool _dragging = false;

  @override
  void didUpdateWidget(covariant PromptAttachmentDropRegion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((!widget.enabled ||
            !identical(widget.controller, oldWidget.controller)) &&
        _dragging) {
      oldWidget.controller.setDragging(false);
      _dragging = false;
    }
  }

  @override
  void dispose() {
    if (_dragging) widget.controller.setDragging(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DropTarget(
      key: Key('prompt-conversation-drop-target'),
      enable: widget.enabled,
      onDragEntered: (_) => _setDragging(true),
      onDragExited: (_) => _setDragging(false),
      onDragDone: (details) {
        _setDragging(false);
        unawaited(
          widget.controller.addDroppedItems(details.files, inlineImages: true),
        );
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          if (_dragging)
            IgnorePointer(
              child: ColoredBox(
                key: Key('prompt-conversation-drop-overlay'),
                color: ChatTheme.of(context).surface.withValues(alpha: 0.82),
                child: Center(
                  child: Container(
                    padding: EdgeInsets.symmetric(horizontal: 24, vertical: 18),
                    decoration: BoxDecoration(
                      color: ChatTheme.of(context).surface,
                      borderRadius: BorderRadius.circular(
                        context.ianvs.panelRadius,
                      ),
                      border: Border.all(
                        color: ChatTheme.of(context).textSecondary,
                        width: 1.5,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Color(0x18000000),
                          blurRadius: 28,
                          offset: Offset(0, 10),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.add_photo_alternate_outlined,
                          color: ChatTheme.of(context).textPrimary,
                          size: 28,
                        ),
                        SizedBox(height: 8),
                        Text(
                          widget.promptCapabilities?.image == true
                              ? 'Drop images anywhere to attach'
                              : 'Drop files anywhere to attach',
                          style: TextStyle(
                            color: ChatTheme.of(context).textPrimary,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _setDragging(bool value) {
    if (!widget.enabled || _dragging == value) return;
    setState(() => _dragging = value);
    widget.controller.setDragging(value);
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

  final ChatPermissionRequest request;
  final VoidCallback? onAllow;
  final VoidCallback? onDeny;
  final VoidCallback? onCancel;
  final ValueChanged<String>? onSelectOption;

  bool _isRejectChoice(ChatPermissionChoice choice) {
    return choice.decision == ChatPermissionDecision.deny;
  }

  bool _canSelectChoice(
    ChatPermissionChoice choice, {
    required bool contextIsComplete,
  }) {
    return contextIsComplete
        ? choice.decision != null
        : choice.explicitDecision == ChatPermissionDecision.deny;
  }

  ChatPermissionChoice? _firstChoiceFor(ChatPermissionDecision decision) {
    for (final choice in request.choices) {
      if (choice.decision == decision) return choice;
    }
    return null;
  }

  ChatPermissionChoice? _firstSingleUseChoiceFor(
    ChatPermissionDecision decision,
  ) {
    for (final choice in request.choices) {
      if (choice.decision == decision && choice.isSingleUse) return choice;
    }
    return null;
  }

  Widget _structuredChoiceButton(
    BuildContext context,
    ChatPermissionChoice choice, {
    required bool contextIsComplete,
  }) {
    final canSelect = _canSelectChoice(
      choice,
      contextIsComplete: contextIsComplete,
    );
    final onPressed = onSelectOption == null || !canSelect
        ? null
        : () => onSelectOption!(choice.optionId);
    if (_isRejectChoice(choice)) {
      return OutlinedButton.icon(
        key: Key('prompt-permission-option-${choice.optionId}'),
        onPressed: onPressed,
        icon: Icon(Icons.block_rounded, size: 15),
        label: Text(choice.name),
        style: OutlinedButton.styleFrom(
          foregroundColor: ChatTheme.of(context).danger,
          backgroundColor: ChatTheme.of(context).surface,
          minimumSize: Size(0, 44),
          padding: EdgeInsets.symmetric(horizontal: 14),
          side: BorderSide(
            color: ChatTheme.of(context).danger.withValues(alpha: 0.3),
          ),
          tapTargetSize: MaterialTapTargetSize.padded,
        ),
      );
    }
    if (choice.decision != ChatPermissionDecision.allow) {
      return OutlinedButton(
        key: Key('prompt-permission-option-${choice.optionId}'),
        onPressed: null,
        child: Text(choice.name),
      );
    }
    return FilledButton.icon(
      key: Key('prompt-permission-option-${choice.optionId}'),
      onPressed: onPressed,
      icon: Icon(Icons.check_rounded, size: 15),
      label: Text(choice.name),
      style: FilledButton.styleFrom(
        foregroundColor: IanvsTheme.foregroundFor(
          ChatTheme.of(context).warning,
        ),
        backgroundColor: ChatTheme.of(context).warning,
        minimumSize: Size(0, 44),
        padding: EdgeInsets.symmetric(horizontal: 14),
        tapTargetSize: MaterialTapTargetSize.padded,
      ),
    );
  }

  Widget _structuredChoiceMenu(
    BuildContext context,
    List<ChatPermissionChoice> choices, {
    required bool contextIsComplete,
  }) {
    return PopupMenuButton<String>(
      key: Key('prompt-permission-more-choices'),
      tooltip: 'More permission choices',
      enabled: onSelectOption != null,
      onSelected: onSelectOption,
      itemBuilder: (context) => [
        for (final choice in choices)
          PopupMenuItem<String>(
            key: Key('prompt-permission-menu-option-${choice.optionId}'),
            value: choice.optionId,
            enabled: _canSelectChoice(
              choice,
              contextIsComplete: contextIsComplete,
            ),
            child: Text(
              choice.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelLarge!,
            ),
          ),
      ],
      child: Container(
        height: 44,
        padding: EdgeInsets.symmetric(horizontal: 13),
        decoration: BoxDecoration(
          color: ChatTheme.of(context).surface,
          borderRadius: BorderRadius.circular(context.ianvs.panelRadius),
          border: Border.all(color: ChatTheme.of(context).border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.more_horiz_rounded,
              size: 17,
              color: ChatTheme.of(context).textSecondary,
            ),
            SizedBox(width: 6),
            Text('More', style: Theme.of(context).textTheme.labelLarge!),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final displayContext = permissionDisplayContextForRequest(request);
    final preferredAllow =
        request.singleUseChoiceFor(ChatPermissionDecision.allow) ??
        _firstSingleUseChoiceFor(ChatPermissionDecision.allow);
    final preferredDeny =
        request.singleUseChoiceFor(ChatPermissionDecision.deny) ??
        _firstSingleUseChoiceFor(ChatPermissionDecision.deny) ??
        _firstChoiceFor(ChatPermissionDecision.deny);
    final featuredChoices = <ChatPermissionChoice>[
      ?preferredDeny,
      if (preferredAllow != null && preferredAllow != preferredDeny)
        preferredAllow,
    ];
    final secondaryChoices = request.choices
        .where((choice) => !featuredChoices.contains(choice))
        .toList(growable: false);
    final collapseSecondaryChoices = secondaryChoices.isNotEmpty;
    return Container(
      key: Key('prompt-permission-card'),
      width: double.infinity,
      decoration: BoxDecoration(
        color: ChatTheme.of(context).warning.withValues(alpha: .06),
        borderRadius: BorderRadius.circular(context.ianvs.controlRadius),
        border: Border.all(
          color: ChatTheme.of(context).warning.withValues(alpha: .30),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: 4,
            child: ColoredBox(color: ChatTheme.of(context).warning),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(16, 13, 12, 13),
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
                      decoration: BoxDecoration(
                        color: ChatTheme.of(
                          context,
                        ).warning.withValues(alpha: .12),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: ChatTheme.of(
                            context,
                          ).warning.withValues(alpha: .30),
                        ),
                      ),
                      child: Icon(
                        Icons.privacy_tip_rounded,
                        color: ChatTheme.of(context).warning,
                        size: 21,
                      ),
                    ),
                    SizedBox(width: 12),
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
                              Text(
                                'Tool call approval required',
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: ChatTheme.of(context).warning,
                                  fontFamily: Theme.of(
                                    context,
                                  ).textTheme.bodyMedium?.fontFamily,
                                  fontFamilyFallback: Theme.of(
                                    context,
                                  ).textTheme.bodyMedium?.fontFamilyFallback,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 0,
                                ),
                              ),
                              Container(
                                padding: EdgeInsets.symmetric(
                                  horizontal: 7,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: ChatTheme.of(
                                    context,
                                  ).warning.withValues(alpha: .12),
                                  borderRadius: BorderRadius.circular(999),
                                  border: Border.all(
                                    color: ChatTheme.of(
                                      context,
                                    ).warning.withValues(alpha: .30),
                                  ),
                                ),
                                child: Text(
                                  request.displayKind,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: ChatTheme.of(context).warning,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    letterSpacing: 0,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          SizedBox(height: 5),
                          Text(
                            request.displayTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: ChatTheme.of(context).textPrimary,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0,
                            ),
                          ),
                          SizedBox(height: 2),
                          Text(
                            request.displayRationale,
                            maxLines: compact ? 2 : 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: ChatTheme.of(context).textSecondary,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0,
                            ),
                          ),
                          if (!displayContext.isComplete ||
                              displayContext.entries.isNotEmpty) ...[
                            SizedBox(height: 8),
                            _PermissionContextView(
                              key: ObjectKey(request),
                              displayContext: displayContext,
                              maxHeight: constraints.maxWidth < 360 ? 96 : 180,
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
                      if (collapseSecondaryChoices) ...[
                        ...featuredChoices.map(
                          (choice) => _structuredChoiceButton(
                            context,
                            choice,
                            contextIsComplete: displayContext.isComplete,
                          ),
                        ),
                        if (secondaryChoices.isNotEmpty)
                          _structuredChoiceMenu(
                            context,
                            secondaryChoices,
                            contextIsComplete: displayContext.isComplete,
                          ),
                      ] else
                        ...request.choices.map(
                          (choice) => _structuredChoiceButton(
                            context,
                            choice,
                            contextIsComplete: displayContext.isComplete,
                          ),
                        )
                    else ...[
                      OutlinedButton.icon(
                        onPressed: onDeny,
                        icon: Icon(Icons.block_rounded, size: 15),
                        label: Text(request.denyActionLabel),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: ChatTheme.of(context).danger,
                          backgroundColor: ChatTheme.of(context).surface,
                          minimumSize: Size(0, 44),
                          padding: EdgeInsets.symmetric(horizontal: 14),
                          side: BorderSide(
                            color: ChatTheme.of(
                              context,
                            ).danger.withValues(alpha: 0.3),
                          ),
                          tapTargetSize: MaterialTapTargetSize.padded,
                        ),
                      ),
                      FilledButton.icon(
                        onPressed: displayContext.isComplete ? onAllow : null,
                        icon: Icon(Icons.check_rounded, size: 15),
                        label: Text(request.allowActionLabel),
                        style: FilledButton.styleFrom(
                          foregroundColor: IanvsTheme.foregroundFor(
                            ChatTheme.of(context).warning,
                          ),
                          backgroundColor: ChatTheme.of(context).warning,
                          minimumSize: Size(0, 44),
                          padding: EdgeInsets.symmetric(horizontal: 14),
                          tapTargetSize: MaterialTapTargetSize.padded,
                        ),
                      ),
                    ],
                    IconButton(
                      tooltip: 'Cancel permission request',
                      onPressed: onCancel,
                      icon: Icon(Icons.close_rounded, size: 18),
                      color: ChatTheme.of(context).textSecondary,
                      constraints: BoxConstraints.tightFor(
                        width: 44,
                        height: 44,
                      ),
                    ),
                  ],
                );

                if (compact) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      details,
                      SizedBox(height: 10),
                      SizedBox(width: double.infinity, child: actions),
                    ],
                  );
                }

                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: details),
                    SizedBox(width: 12),
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
  const _PermissionContextView({
    super.key,
    required this.displayContext,
    required this.maxHeight,
  });

  final PermissionDisplayContext displayContext;
  final double maxHeight;

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
      key: Key('prompt-permission-context'),
      constraints: BoxConstraints(maxHeight: widget.maxHeight),
      child: Scrollbar(
        controller: _scrollController,
        child: SingleChildScrollView(
          key: Key('prompt-permission-context-scroll'),
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
                        padding: EdgeInsets.only(bottom: 6),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              entry.label,
                              style: TextStyle(
                                color: ChatTheme.of(context).textSecondary,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            SelectableText(
                              entry.value,
                              style: TextStyle(
                                color: ChatTheme.of(context).textPrimary,
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
                  key: Key('prompt-permission-context-warning'),
                  style: TextStyle(
                    color: ChatTheme.of(context).danger,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
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
    'Additional details' => 'additional-details',
    _ => throw StateError('Unsupported permission context label: $label'),
  };
}

class _AttachmentDropIndicator extends StatelessWidget {
  const _AttachmentDropIndicator({required this.kinds});

  final List<PromptAttachmentKind> kinds;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: Key('prompt-attachment-drop-indicator'),
      width: double.infinity,
      margin: EdgeInsets.fromLTRB(8, 8, 8, 4),
      padding: EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: ChatTheme.of(context).surface.withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(context.ianvs.controlRadius),
        border: Border.all(
          color: ChatTheme.of(context).primary.withValues(alpha: 0.34),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.file_download_outlined,
            size: 18,
            color: ChatTheme.of(context).primaryDark,
          ),
          SizedBox(width: 8),
          Flexible(
            child: Text(
              _attachmentDropLabel(kinds),
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: ChatTheme.of(context).primaryDark,
                fontSize: 12,
                fontWeight: FontWeight.w600,
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
  final ChatPromptCapabilities? promptCapabilities;
  final ValueChanged<PromptAttachmentKind> onSelected;

  @override
  Widget build(BuildContext context) {
    final kinds = _availableAttachmentKinds(promptCapabilities);
    if (kinds.isEmpty) return const SizedBox.shrink();
    final tooltip = _attachmentPickerTooltip(kinds);
    if (kinds.length == 1) {
      return SizedBox(
        width: 34,
        height: 34,
        child: Semantics(
          button: true,
          label: tooltip,
          child: IconButton(
            tooltip: tooltip,
            onPressed: enabled ? () => onSelected(kinds.single) : null,
            icon: Icon(Icons.add_rounded, key: Key('prompt-attachment-picker')),
            color: ChatTheme.of(context).textSecondary,
            disabledColor: ChatTheme.of(context).textTertiary,
            iconSize: 19,
            padding: EdgeInsets.zero,
            constraints: BoxConstraints.tightFor(width: 34, height: 34),
            splashRadius: 17,
          ),
        ),
      );
    }

    return SizedBox(
      width: 34,
      height: 34,
      child: PopupMenuButton<PromptAttachmentKind>(
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
        icon: Icon(Icons.add_rounded, key: Key('prompt-attachment-picker')),
        padding: EdgeInsets.zero,
        color: ChatTheme.of(context).surface,
        iconColor: ChatTheme.of(context).textSecondary,
        iconSize: 19,
      ),
    );
  }
}

List<PromptAttachmentKind> _availableAttachmentKinds(
  ChatPromptCapabilities? capabilities,
) => <PromptAttachmentKind>[
  if (capabilities?.files != false) PromptAttachmentKind.file,
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
        Icon(icon, color: ChatTheme.of(context).primaryDark, size: 19),
        SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: ChatTheme.of(context).textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                description,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: ChatTheme.of(context).textSecondary,
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

class _PromptIdleWarning extends StatelessWidget {
  const _PromptIdleWarning({required this.onStop});

  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: Key('prompt-idle-warning'),
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(12, 9, 8, 9),
      decoration: BoxDecoration(
        color: ChatTheme.of(context).warning.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(context.ianvs.panelRadius),
        border: Border.all(
          color: ChatTheme.of(context).warning.withValues(alpha: 0.28),
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.schedule_rounded,
            size: 17,
            color: ChatTheme.of(context).warning,
          ),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'No agent updates for a while. The adapter may still be '
              'finishing this turn.',
              style: TextStyle(
                color: ChatTheme.of(context).textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          TextButton(
            key: Key('prompt-idle-warning-stop'),
            onPressed: onStop,
            style: TextButton.styleFrom(
              foregroundColor: ChatTheme.of(context).textPrimary,
              minimumSize: Size(0, 32),
              padding: EdgeInsets.symmetric(horizontal: 10),
              textStyle: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
            child: Text('Stop'),
          ),
        ],
      ),
    );
  }
}

class _PromptQueueTray extends StatelessWidget {
  const _PromptQueueTray({
    required this.prompts,
    required this.onGuide,
    required this.onRemove,
    required this.onClear,
    required this.onReorder,
  });

  final List<ChatQueuedPrompt> prompts;
  final ValueChanged<int>? onGuide;
  final ValueChanged<int>? onRemove;
  final VoidCallback? onClear;
  final void Function(int oldIndex, int newIndex)? onReorder;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: Key('prompt-queue-tray'),
      width: double.infinity,
      decoration: BoxDecoration(
        color: ChatTheme.of(context).surface,
        borderRadius: BorderRadius.circular(context.ianvs.panelRadius),
        border: Border.all(color: ChatTheme.of(context).border),
        boxShadow: kElevationToShadow[2]!,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(13, 9, 10, 7),
            child: Row(
              children: [
                Icon(
                  Icons.playlist_play_rounded,
                  size: 18,
                  color: ChatTheme.of(context).textSecondary,
                ),
                SizedBox(width: 7),
                Text(
                  '${prompts.length} queued',
                  style: TextStyle(
                    color: ChatTheme.of(context).textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Spacer(),
                if (onClear != null)
                  TextButton.icon(
                    key: Key('clear-prompt-queue'),
                    onPressed: onClear,
                    icon: Icon(Icons.delete_sweep_outlined, size: 15),
                    label: Text(
                      'Clear all',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    style: TextButton.styleFrom(
                      foregroundColor: ChatTheme.of(context).textSecondary,
                      padding: EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: Size(0, 28),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                if (onClear == null)
                  Text(
                    'Runs automatically after the current turn',
                    style: TextStyle(
                      color: ChatTheme.of(context).textTertiary,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
              ],
            ),
          ),
          Divider(height: 1, color: ChatTheme.of(context).borderSoft),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: 216),
            child: ReorderableListView.builder(
              shrinkWrap: true,
              buildDefaultDragHandles: false,
              padding: EdgeInsets.symmetric(vertical: 4),
              itemCount: prompts.length,
              onReorderItem: onReorder ?? (_, _) {},
              itemBuilder: (context, index) {
                final prompt = prompts[index];
                return _PromptQueueRow(
                  key: ValueKey('queued-prompt-${prompt.id}'),
                  prompt: prompt,
                  index: index,
                  canReorder: onReorder != null,
                  onGuide: onGuide == null ? null : () => onGuide!(prompt.id),
                  onRemove: onRemove == null
                      ? null
                      : () => onRemove!(prompt.id),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _PromptQueueRow extends StatelessWidget {
  const _PromptQueueRow({
    super.key,
    required this.prompt,
    required this.index,
    required this.canReorder,
    required this.onGuide,
    required this.onRemove,
  });

  final ChatQueuedPrompt prompt;
  final int index;
  final bool canReorder;
  final VoidCallback? onGuide;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final label = prompt.text.trim().isEmpty
        ? '${prompt.attachments.length} attachment'
        : prompt.text.trim();
    return Material(
      color: prompt.guide
          ? ChatTheme.of(context).surfaceMuted
          : Colors.transparent,
      child: Padding(
        padding: EdgeInsets.fromLTRB(8, 3, 5, 3),
        child: Row(
          children: [
            if (canReorder)
              ReorderableDragStartListener(
                index: index,
                child: Padding(
                  padding: EdgeInsets.all(5),
                  child: Icon(
                    Icons.drag_indicator_rounded,
                    size: 16,
                    color: ChatTheme.of(context).textTertiary,
                  ),
                ),
              )
            else
              SizedBox(width: 26),
            Icon(
              prompt.guide
                  ? Icons.subdirectory_arrow_right_rounded
                  : Icons.turn_right_rounded,
              size: 16,
              color: prompt.guide
                  ? ChatTheme.of(context).textPrimary
                  : ChatTheme.of(context).textTertiary,
            ),
            SizedBox(width: 7),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: ChatTheme.of(context).textPrimary,
                  fontSize: 12,
                  fontWeight: prompt.guide ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ),
            if (prompt.attachments.isNotEmpty) ...[
              SizedBox(width: 6),
              Text(
                '${prompt.attachments.length} attachment'
                '${prompt.attachments.length == 1 ? '' : 's'}',
                style: TextStyle(
                  color: ChatTheme.of(context).textTertiary,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            SizedBox(width: 4),
            Tooltip(
              message: prompt.guide
                  ? 'Guidance will run first after the current turn stops'
                  : 'Stop the current turn and guide it with this message',
              child: TextButton.icon(
                key: Key('guide-queued-prompt-${prompt.id}'),
                onPressed: onGuide,
                style: TextButton.styleFrom(
                  foregroundColor: ChatTheme.of(context).textSecondary,
                  padding: EdgeInsets.symmetric(horizontal: 7),
                  minimumSize: Size(0, 30),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                icon: Icon(
                  prompt.guide
                      ? Icons.near_me_rounded
                      : Icons.subdirectory_arrow_right_rounded,
                  size: 15,
                ),
                label: Text(prompt.guide ? 'Guiding' : 'Guide'),
              ),
            ),
            IconButton(
              key: Key('remove-queued-prompt-${prompt.id}'),
              tooltip: 'Remove from queue',
              onPressed: onRemove,
              visualDensity: VisualDensity.standard,
              constraints: BoxConstraints.tightFor(width: 30, height: 30),
              iconSize: 16,
              icon: Icon(Icons.delete_outline_rounded),
            ),
          ],
        ),
      ),
    );
  }
}

class _ComposerControlBar extends StatelessWidget {
  const _ComposerControlBar({
    required this.enabled,
    required this.isSending,
    required this.canSend,
    required this.onPickAttachments,
    this.showExecutionPolicy = true,
    required this.promptCapabilities,
    required this.pendingPermissionRequest,
    required this.toolCallExecutionPolicy,
    required this.hasPermissionReviewer,
    required this.onToolCallExecutionPolicyChanged,
    required this.modelOption,
    required this.reasoningEffortOption,
    required this.onModelSelected,
    required this.onReasoningEffortSelected,
    required this.configOptions,
    required this.onConfigOptionSelected,
    required this.onSend,
    required this.onStop,
  });

  final bool enabled;
  final bool isSending;
  final bool canSend;
  final ValueChanged<PromptAttachmentKind>? onPickAttachments;
  final bool showExecutionPolicy;
  final ChatPromptCapabilities? promptCapabilities;
  final ChatPermissionRequest? pendingPermissionRequest;
  final ChatToolCallExecutionPolicy toolCallExecutionPolicy;
  final bool hasPermissionReviewer;
  final ValueChanged<ChatToolCallExecutionPolicy>?
  onToolCallExecutionPolicyChanged;
  final ChatConfigOption? modelOption;
  final ChatConfigOption? reasoningEffortOption;
  final ValueChanged<String>? onModelSelected;
  final ValueChanged<String>? onReasoningEffortSelected;
  final List<ChatConfigOption> configOptions;
  final SessionConfigSelectionCallback? onConfigOptionSelected;
  final VoidCallback onSend;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final attach = onPickAttachments == null
        ? SizedBox.shrink()
        : _AttachmentPickerControl(
            enabled: enabled,
            promptCapabilities: promptCapabilities,
            onSelected: onPickAttachments!,
          );
    final policy = !showExecutionPolicy
        ? SizedBox.shrink()
        : _ToolCallPolicySelector(
            value: toolCallExecutionPolicy,
            hasPermissionReviewer: hasPermissionReviewer,
            enabled: enabled && onToolCallExecutionPolicyChanged != null,
            onChanged: onToolCallExecutionPolicyChanged,
          );
    final adaptiveOptions = configOptions
        .where((option) => option.isBooleanOption || option.options.length > 1)
        .toList(growable: false);
    final sessionConfig = pendingPermissionRequest != null
        ? null
        : adaptiveOptions.isNotEmpty
        ? _AdaptiveSessionConfigSelector(
            options: adaptiveOptions,
            enabled: enabled && !isSending && onConfigOptionSelected != null,
            onSelected: onConfigOptionSelected,
          )
        : (modelOption != null && modelOption!.options.isNotEmpty) ||
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
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 560) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  attach,
                  SizedBox(width: 2),
                  Flexible(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: policy,
                    ),
                  ),
                  SizedBox(width: 8),
                  action,
                ],
              ),
              if (sessionConfig != null) ...[
                SizedBox(height: 6),
                Align(alignment: Alignment.centerRight, child: sessionConfig),
              ],
            ],
          );
        }

        return Row(
          children: [
            attach,
            SizedBox(width: 2),
            Flexible(
              child: Align(alignment: Alignment.centerLeft, child: policy),
            ),
            Spacer(),
            if (sessionConfig != null) ...[
              Flexible(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: sessionConfig,
                ),
              ),
              SizedBox(width: 8),
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
    required this.hasPermissionReviewer,
    required this.enabled,
    required this.onChanged,
  });

  final ChatToolCallExecutionPolicy value;
  final bool hasPermissionReviewer;
  final bool enabled;
  final ValueChanged<ChatToolCallExecutionPolicy>? onChanged;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<ChatToolCallExecutionPolicy>(
      tooltip: 'Tool call execution policy',
      enabled: enabled,
      offset: Offset(80, 0),
      constraints: BoxConstraints(minWidth: 240, maxWidth: 280),
      onSelected: onChanged,
      itemBuilder: (context) => [
        for (final policy in ChatToolCallExecutionPolicy.values)
          PopupMenuItem<ChatToolCallExecutionPolicy>(
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
        emphasized: value == ChatToolCallExecutionPolicy.fullAccess,
      ),
    );
  }
}

class _AdaptiveSessionConfigSelector extends StatefulWidget {
  const _AdaptiveSessionConfigSelector({
    required this.options,
    required this.enabled,
    required this.onSelected,
  });

  final List<ChatConfigOption> options;
  final bool enabled;
  final SessionConfigSelectionCallback? onSelected;

  @override
  State<_AdaptiveSessionConfigSelector> createState() =>
      _AdaptiveSessionConfigSelectorState();
}

class _AdaptiveSessionConfigSelectorState
    extends State<_AdaptiveSessionConfigSelector> {
  final MenuController _menuController = MenuController();
  final OverlayPortalController _advancedOverlayController =
      OverlayPortalController();
  final LayerLink _advancedOverlayLink = LayerLink();
  final Object _advancedTapRegionGroup = Object();
  bool _advancedExpanded = false;
  double? _effortPreviewIndex;

  @override
  Widget build(BuildContext context) {
    final model = _firstOption((option) => option.isModelOption);
    final effort = _firstOption((option) => option.isReasoningEffortOption);
    final fast = _firstOption((option) => option.isFastOption);
    final primaryOptions = <ChatConfigOption?>[
      model,
      effort,
      fast,
    ].whereType<ChatConfigOption>().toList(growable: false);
    final labels = <String>[
      if (model != null) model.currentChoiceLabel,
      if (effort != null) effort.currentChoiceLabel,
      if (model == null && effort == null && widget.options.isNotEmpty)
        widget.options.first.currentChoiceLabel,
    ];
    final hasAdvancedControls =
        (effort != null && effort.options.length > 1) || fast != null;

    return CompositedTransformTarget(
      link: _advancedOverlayLink,
      child: TapRegion(
        groupId: _advancedTapRegionGroup,
        child: OverlayPortal(
          controller: _advancedOverlayController,
          overlayChildBuilder: (context) {
            return Stack(
              children: [
                CompositedTransformFollower(
                  link: _advancedOverlayLink,
                  showWhenUnlinked: false,
                  targetAnchor: Alignment.topRight,
                  followerAnchor: Alignment.bottomRight,
                  offset: Offset(0, -8),
                  child: TapRegion(
                    key: Key('prompt-session-config-advanced-overlay-region'),
                    groupId: _advancedTapRegionGroup,
                    consumeOutsideTaps: true,
                    onTapOutside: (_) => _closeAdvancedOverlay(),
                    child: Material(
                      type: MaterialType.transparency,
                      child: _SessionConfigAdvancedPanel(
                        effort: effort,
                        fast: fast,
                        enabled: widget.enabled,
                        effortPreviewIndex: _effortPreviewIndex,
                        onBack: _showPrimaryMenuFromAdvanced,
                        onEffortPreviewChanged: (value) {
                          setState(() => _effortPreviewIndex = value);
                        },
                        onEffortChanged: (value) {
                          if (effort == null || effort.options.isEmpty) return;
                          final index = value
                              .round()
                              .clamp(0, effort.options.length - 1)
                              .toInt();
                          widget.onSelected?.call(
                            effort.id,
                            effort.options[index].value,
                          );
                        },
                        onFastToggle: fast == null
                            ? null
                            : () => _toggleFast(fast),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
          child: MenuAnchor(
            controller: _menuController,
            style: _sessionConfigMenuStyle(context, width: 246),
            alignmentOffset: Offset(0, -6),
            onOpen: _closeAdvancedOverlay,
            menuChildren: [
              for (final option in primaryOptions) _configSubmenu(option),
              if (primaryOptions.isNotEmpty && hasAdvancedControls)
                Divider(height: 9, indent: 10, endIndent: 10),
              if (hasAdvancedControls)
                MenuItemButton(
                  key: Key('prompt-session-config-advanced'),
                  style: _sessionConfigButtonStyle(context, width: 246),
                  trailingIcon: Icon(
                    Icons.keyboard_arrow_up_rounded,
                    size: 19,
                    color: ChatTheme.of(context).textTertiary,
                  ),
                  onPressed: widget.enabled
                      ? () {
                          _menuController.close();
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (!mounted) return;
                            setState(() {
                              _advancedExpanded = true;
                              _effortPreviewIndex = null;
                            });
                            _advancedOverlayController.show();
                          });
                        }
                      : null,
                  child: _SessionConfigMenuRow(label: 'Advanced', value: ''),
                ),
            ],
            builder: (context, controller, child) {
              return Tooltip(
                message: 'Agent session configuration',
                child: InkWell(
                  key: Key('prompt-session-config-selector'),
                  borderRadius: BorderRadius.circular(999),
                  onTap: widget.enabled
                      ? () {
                          _closeAdvancedOverlay();
                          if (controller.isOpen) {
                            controller.close();
                          } else {
                            controller.open();
                          }
                        }
                      : null,
                  child: _SessionConfigSummaryButton(
                    label: labels.join(' '),
                    enabled: widget.enabled,
                    fastEnabled: fast?.isFastEnabled == true,
                    expanded: controller.isOpen,
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  void _closeAdvancedOverlay() {
    _advancedOverlayController.hide();
    if (!_advancedExpanded || !mounted) return;
    setState(() {
      _advancedExpanded = false;
      _effortPreviewIndex = null;
    });
  }

  void _showPrimaryMenuFromAdvanced() {
    _closeAdvancedOverlay();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _menuController.open();
    });
  }

  void _toggleFast(ChatConfigOption option) {
    if (option.isBooleanOption) {
      widget.onSelected?.call(option.id, !option.isFastEnabled);
      return;
    }
    final targetLabel = option.isFastEnabled ? 'Standard' : 'Fast';
    for (final choice in option.options) {
      if (_fastChoiceLabel(choice.value, choice.label) == targetLabel) {
        widget.onSelected?.call(option.id, choice.value);
        return;
      }
    }
  }

  Widget _configSubmenu(ChatConfigOption option, {double buttonWidth = 246}) {
    return SubmenuButton(
      key: Key('prompt-session-config-option-${option.id}'),
      style: _sessionConfigButtonStyle(context, width: buttonWidth),
      menuStyle: _sessionConfigMenuStyle(
        context,
        width: option.isModelOption ? 286 : 306,
      ),
      hoverOpenDelay: Duration(milliseconds: 90),
      menuChildren: _choiceMenuEntries(option),
      child: _SessionConfigMenuRow(
        label: _optionLabel(option),
        value: _currentOptionLabel(option),
        width: buttonWidth - 60,
      ),
    );
  }

  ChatConfigOption? _firstOption(bool Function(ChatConfigOption) test) {
    for (final option in widget.options) {
      if (test(option)) return option;
    }
    return null;
  }

  List<Widget> _choiceMenuEntries(ChatConfigOption option) {
    final entries = <Widget>[
      if (!option.isModelOption)
        _SessionConfigSubmenuHeader(label: _optionLabel(option)),
    ];
    if (option.isBooleanOption) {
      for (final value in [false, true]) {
        entries.add(
          MenuItemButton(
            key: Key(
              'prompt-session-config-choice-${option.id}-${value ? 'on' : 'off'}',
            ),
            style: _sessionConfigChoiceButtonStyle(
              context,
              width: option.isFastOption ? 306 : 286,
            ),
            trailingIcon: option.currentBoolValue == value
                ? Icon(
                    Icons.check_rounded,
                    size: 19,
                    color: ChatTheme.of(context).textSecondary,
                  )
                : null,
            onPressed: widget.enabled
                ? () => widget.onSelected?.call(option.id, value)
                : null,
            child: _SessionConfigChoiceLabel(
              label: option.isFastOption
                  ? (value ? 'Fast' : 'Standard')
                  : (value ? 'On' : 'Off'),
              description: option.isFastOption
                  ? (value
                        ? 'Faster responses, uses more quota'
                        : 'Default speed')
                  : (value ? (option.description ?? '') : ''),
            ),
          ),
        );
      }
      return entries;
    }

    for (final choice in option.options) {
      entries.add(
        MenuItemButton(
          key: Key('prompt-session-config-choice-${option.id}-${choice.value}'),
          style: _sessionConfigChoiceButtonStyle(
            context,
            width: option.isModelOption ? 286 : 306,
          ),
          trailingIcon: choice.value == option.currentValue
              ? Icon(
                  Icons.check_rounded,
                  size: 19,
                  color: ChatTheme.of(context).textSecondary,
                )
              : null,
          onPressed: widget.enabled
              ? () => widget.onSelected?.call(option.id, choice.value)
              : null,
          child: _SessionConfigChoiceLabel(
            label: option.isFastOption
                ? _fastChoiceLabel(choice.value, choice.label)
                : choice.label,
            description:
                choice.description ??
                (choice.groupName == null ? '' : choice.groupName!),
          ),
        ),
      );
    }
    return entries;
  }

  String _optionLabel(ChatConfigOption option) {
    if (option.isReasoningEffortOption) return 'Reasoning';
    if (option.isFastOption) return 'Speed';
    if (option.isModelOption) return 'Model';
    final name = option.name.trim();
    return name.isEmpty ? option.id : name;
  }

  String _currentOptionLabel(ChatConfigOption option) {
    if (option.isFastOption) {
      return option.isFastEnabled ? 'Fast' : 'Standard';
    }
    return option.currentChoiceLabel;
  }

  String _fastChoiceLabel(String value, String label) {
    final normalized = '$value $label'.trim().toLowerCase();
    if (normalized.contains('fast') ||
        normalized.contains('quick') ||
        normalized.contains('turbo') ||
        normalized.contains('on') ||
        normalized.contains('enabled') ||
        normalized.contains('true')) {
      return 'Fast';
    }
    if (normalized.contains('standard') ||
        normalized.contains('normal') ||
        normalized.contains('off') ||
        normalized.contains('disabled') ||
        normalized.contains('false')) {
      return 'Standard';
    }
    return label;
  }
}

class _SessionConfigAdvancedPanel extends StatefulWidget {
  const _SessionConfigAdvancedPanel({
    required this.effort,
    required this.fast,
    required this.enabled,
    required this.effortPreviewIndex,
    required this.onBack,
    required this.onEffortPreviewChanged,
    required this.onEffortChanged,
    required this.onFastToggle,
  });

  final ChatConfigOption? effort;
  final ChatConfigOption? fast;
  final bool enabled;
  final double? effortPreviewIndex;
  final VoidCallback onBack;
  final ValueChanged<double> onEffortPreviewChanged;
  final ValueChanged<double> onEffortChanged;
  final VoidCallback? onFastToggle;

  @override
  State<_SessionConfigAdvancedPanel> createState() =>
      _SessionConfigAdvancedPanelState();
}

class _SessionConfigAdvancedPanelState
    extends State<_SessionConfigAdvancedPanel> {
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final effortChoices = widget.effort?.options ?? <ChatConfigOptionChoice>[];
    final selectedEffortIndex = _selectedEffortIndex(widget.effort);
    final sliderValue =
        (widget.effortPreviewIndex ?? selectedEffortIndex.toDouble())
            .clamp(0, (effortChoices.length - 1).toDouble())
            .toDouble();

    return Container(
      key: Key('prompt-session-config-advanced-panel'),
      width: 228,
      padding: EdgeInsets.fromLTRB(12, 8, 12, 10),
      decoration: BoxDecoration(
        color: ChatTheme.of(context).surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: ChatTheme.of(context).border),
        boxShadow: [
          BoxShadow(
            color: Color(0x14000000),
            blurRadius: 18,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              if (_dragging) ...[
                Expanded(
                  child: Text(
                    'More efficient',
                    style: TextStyle(
                      color: ChatTheme.of(context).textTertiary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Text(
                  'Smarter',
                  style: TextStyle(
                    color: ChatTheme.of(context).textTertiary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ] else ...[
                Expanded(
                  child: InkWell(
                    key: Key('prompt-session-config-advanced-collapse'),
                    borderRadius: BorderRadius.circular(8),
                    onTap: widget.enabled ? widget.onBack : null,
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 2, vertical: 4),
                      child: Row(
                        children: [
                          Text(
                            'Advanced',
                            style: TextStyle(
                              color: ChatTheme.of(context).textTertiary,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          SizedBox(width: 2),
                          Icon(
                            Icons.keyboard_arrow_right_rounded,
                            size: 18,
                            color: ChatTheme.of(context).textTertiary,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
              if (!_dragging && widget.fast != null)
                Tooltip(
                  message: widget.fast!.isFastEnabled
                      ? 'Use standard speed'
                      : 'Use fast speed',
                  child: IconButton(
                    key: Key('prompt-session-config-advanced-fast-toggle'),
                    onPressed: widget.enabled ? widget.onFastToggle : null,
                    visualDensity: VisualDensity.standard,
                    constraints: BoxConstraints.tightFor(width: 32, height: 32),
                    padding: EdgeInsets.zero,
                    icon: Icon(
                      Icons.bolt_rounded,
                      size: 20,
                      color: ChatTheme.of(context).accent,
                    ),
                  ),
                ),
            ],
          ),
          if (effortChoices.length > 1) ...[
            SizedBox(height: 2),
            _ReasoningBalanceSlider(
              key: Key('prompt-session-config-advanced-effort-slider'),
              value: sliderValue,
              choiceLabels: effortChoices
                  .map((choice) => choice.label)
                  .toList(growable: false),
              enabled: widget.enabled,
              onChanged: widget.onEffortPreviewChanged,
              onChangeEnd: widget.onEffortChanged,
              onInteractionChanged: (dragging) {
                if (_dragging == dragging) return;
                setState(() => _dragging = dragging);
              },
            ),
          ] else if (widget.fast != null) ...[
            SizedBox(height: 2),
            Row(
              children: [
                Text(
                  'Speed',
                  style: TextStyle(
                    color: ChatTheme.of(context).textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Spacer(),
                Text(
                  widget.fast!.isFastEnabled ? 'Fast' : 'Standard',
                  style: TextStyle(
                    color: ChatTheme.of(context).textTertiary,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  int _selectedEffortIndex(ChatConfigOption? option) {
    if (option == null) return 0;
    final index = option.options.indexWhere(
      (choice) => choice.value == option.currentValue,
    );
    return index < 0 ? 0 : index;
  }
}

class _ReasoningBalanceSlider extends StatefulWidget {
  const _ReasoningBalanceSlider({
    super.key,
    required this.value,
    required this.choiceLabels,
    required this.enabled,
    required this.onChanged,
    required this.onChangeEnd,
    required this.onInteractionChanged,
  });

  final double value;
  final List<String> choiceLabels;
  final bool enabled;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;
  final ValueChanged<bool> onInteractionChanged;

  @override
  State<_ReasoningBalanceSlider> createState() =>
      _ReasoningBalanceSliderState();
}

class _ReasoningBalanceSliderState extends State<_ReasoningBalanceSlider>
    with SingleTickerProviderStateMixin {
  late final AnimationController _particleController;
  double? _interactionValue;

  double get _max => (widget.choiceLabels.length - 1).toDouble();

  @override
  void initState() {
    super.initState();
    _particleController = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: 1800),
    )..repeat();
  }

  @override
  void dispose() {
    _particleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final value = widget.value.clamp(0, _max).toDouble();
    final label = widget.choiceLabels[value.round()];
    return Semantics(
      label: 'Reasoning effort',
      value: label,
      hint:
          'Snapped to node ${value.round() + 1} of ${widget.choiceLabels.length}',
      slider: true,
      increasedValue: value < _max
          ? widget.choiceLabels[(value.round() + 1)
                .clamp(0, _max.toInt())
                .toInt()]
          : null,
      decreasedValue: value > 0
          ? widget.choiceLabels[(value.round() - 1)
                .clamp(0, _max.toInt())
                .toInt()]
          : null,
      onIncrease: widget.enabled && value < _max
          ? () => _commit((value + 1).clamp(0, _max).toDouble())
          : null,
      onDecrease: widget.enabled && value > 0
          ? () => _commit((value - 1).clamp(0, _max).toDouble())
          : null,
      child: LayoutBuilder(
        builder: (context, constraints) {
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: widget.enabled
                ? (details) {
                    final next = _valueForDx(
                      details.localPosition.dx,
                      constraints.maxWidth,
                    );
                    _updateInteraction(next);
                    widget.onChangeEnd(next);
                    _interactionValue = null;
                  }
                : null,
            onHorizontalDragStart: widget.enabled
                ? (details) {
                    widget.onInteractionChanged(true);
                    final next = _valueForDx(
                      details.localPosition.dx,
                      constraints.maxWidth,
                    );
                    _updateInteraction(next);
                  }
                : null,
            onHorizontalDragUpdate: widget.enabled
                ? (details) {
                    final next = _valueForDx(
                      details.localPosition.dx,
                      constraints.maxWidth,
                    );
                    _updateInteraction(next);
                  }
                : null,
            onHorizontalDragEnd: widget.enabled
                ? (details) {
                    widget.onInteractionChanged(false);
                    widget.onChangeEnd(
                      (_interactionValue ?? widget.value).roundToDouble(),
                    );
                    _interactionValue = null;
                  }
                : null,
            onHorizontalDragCancel: widget.enabled
                ? () {
                    _interactionValue = null;
                    widget.onInteractionChanged(false);
                  }
                : null,
            child: SizedBox(
              height: 46,
              width: double.infinity,
              child: CustomPaint(
                key: Key('prompt-session-config-advanced-particles'),
                painter: _ReasoningBalanceSliderPainter(
                  theme: ChatTheme.of(context),
                  fraction: _max == 0 ? 0 : value / _max,
                  divisions: widget.choiceLabels.length - 1,
                  particleAnimation: _particleController,
                  enabled: widget.enabled,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  double _valueForDx(double dx, double width) {
    const thumbRadius = 13.0;
    final usableWidth = math.max(width - thumbRadius * 2, 1);
    final fraction = ((dx - thumbRadius) / usableWidth).clamp(0.0, 1.0);
    return (fraction * _max).round().clamp(0, _max.toInt()).toDouble();
  }

  void _updateInteraction(double value) {
    final previousNode = (_interactionValue ?? widget.value).round();
    final nextNode = value.round();
    _interactionValue = value;
    if (previousNode != nextNode) {
      HapticFeedback.selectionClick();
    }
    widget.onChanged(value);
  }

  void _commit(double value) {
    widget.onChanged(value);
    widget.onChangeEnd(value);
  }
}

class _ReasoningBalanceSliderPainter extends CustomPainter {
  _ReasoningBalanceSliderPainter({
    required this.fraction,
    required this.theme,
    required this.divisions,
    required this.particleAnimation,
    required this.enabled,
  }) : super(repaint: particleAnimation);

  final double fraction;
  final ChatThemeData theme;
  final int divisions;
  final Animation<double> particleAnimation;
  final bool enabled;

  Color get _trackColor => theme.border;
  Color get _activeColor => theme.accent;

  @override
  void paint(Canvas canvas, Size size) {
    const trackHeight = 24.0;
    const thumbRadius = 13.0;
    final trackRect = Rect.fromLTWH(
      0,
      (size.height - trackHeight) / 2,
      size.width,
      trackHeight,
    );
    final trackRRect = RRect.fromRectAndRadius(
      trackRect,
      Radius.circular(trackHeight / 2),
    );
    canvas.drawRRect(
      trackRRect,
      Paint()..color = enabled ? _trackColor : theme.primaryMist,
    );

    final thumbCenterX =
        thumbRadius + (size.width - thumbRadius * 2) * fraction;
    canvas.save();
    canvas.clipRRect(trackRRect);
    canvas.drawRect(
      Rect.fromLTRB(
        trackRect.left,
        trackRect.top,
        thumbCenterX,
        trackRect.bottom,
      ),
      Paint()..color = enabled ? _activeColor : theme.border,
    );
    if (enabled && thumbCenterX > 34) {
      _paintParticles(canvas, trackRect, thumbCenterX);
    }
    canvas.restore();

    if (divisions > 1) {
      final tickPaint = Paint()..color = Color(0xFFAAAEB3);
      for (var index = 1; index < divisions; index++) {
        final x =
            thumbRadius + (size.width - thumbRadius * 2) * (index / divisions);
        if (x > thumbCenterX + thumbRadius) {
          canvas.drawCircle(Offset(x, size.height / 2), 2.1, tickPaint);
        }
      }
    }

    final thumbCenter = Offset(thumbCenterX, size.height / 2);
    final thumbPath = Path()
      ..addOval(Rect.fromCircle(center: thumbCenter, radius: thumbRadius));
    canvas.drawShadow(thumbPath, Color(0x33000000), 2, false);
    canvas.drawCircle(
      thumbCenter,
      thumbRadius,
      Paint()..color = enabled ? Colors.white : theme.surface,
    );
    canvas.drawCircle(
      thumbCenter,
      thumbRadius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8
        ..color = Color(0x1F000000),
    );
  }

  void _paintParticles(Canvas canvas, Rect trackRect, double activeEnd) {
    final particlePaint = Paint();
    final usableWidth = math.max(activeEnd - 24, 1);
    for (var index = 0; index < 12; index++) {
      final speed = 0.52 + (index % 4) * 0.13;
      final progress = (particleAnimation.value * speed + index * 0.173) % 1.0;
      final x = 8 + progress * usableWidth;
      final wave = math.sin(
        particleAnimation.value * math.pi * 2 + index * 1.71,
      );
      final y = trackRect.center.dy + wave * 6.2;
      final opacity = (0.35 + 0.55 * math.sin((progress + 0.18) * math.pi))
          .clamp(0.25, 0.9);
      particlePaint.color = Colors.white.withValues(alpha: opacity);
      canvas.drawCircle(
        Offset(x, y),
        index % 3 == 0 ? 1.6 : 1.1,
        particlePaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ReasoningBalanceSliderPainter oldDelegate) {
    return oldDelegate.theme.tokens != theme.tokens ||
        oldDelegate.theme.colors != theme.colors ||
        oldDelegate.fraction != fraction ||
        oldDelegate.divisions != divisions ||
        oldDelegate.particleAnimation != particleAnimation ||
        oldDelegate.enabled != enabled;
  }
}

class _SessionConfigMenuRow extends StatelessWidget {
  const _SessionConfigMenuRow({
    required this.label,
    required this.value,
    this.width = 186,
  });

  final String label;
  final String value;
  final double width;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: ChatTheme.of(context).textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                letterSpacing: 0,
              ),
            ),
          ),
          if (value.isNotEmpty) ...[
            SizedBox(width: 10),
            Flexible(
              child: Text(
                value,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.end,
                style: TextStyle(
                  color: ChatTheme.of(context).textTertiary,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SessionConfigSubmenuHeader extends StatelessWidget {
  const _SessionConfigSubmenuHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(14, 10, 14, 4),
      child: Text(
        label,
        style: TextStyle(
          color: ChatTheme.of(context).textTertiary,
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0,
        ),
      ),
    );
  }
}

class _SessionConfigChoiceLabel extends StatelessWidget {
  const _SessionConfigChoiceLabel({
    required this.label,
    required this.description,
  });

  final String label;
  final String description;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 238,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: ChatTheme.of(context).textPrimary,
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 0,
            ),
          ),
          if (description.trim().isNotEmpty)
            Text(
              description.trim(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: ChatTheme.of(context).textTertiary,
                fontSize: 11.5,
                fontWeight: FontWeight.w500,
                height: 1.3,
                letterSpacing: 0,
              ),
            ),
        ],
      ),
    );
  }
}

class _SessionConfigSummaryButton extends StatelessWidget {
  const _SessionConfigSummaryButton({
    required this.label,
    required this.enabled,
    required this.fastEnabled,
    required this.expanded,
  });

  final String label;
  final bool enabled;
  final bool fastEnabled;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final color = enabled
        ? ChatTheme.of(context).textPrimary
        : ChatTheme.of(context).textTertiary;
    return Container(
      height: 32,
      constraints: BoxConstraints(minWidth: 150, maxWidth: 228),
      padding: EdgeInsets.symmetric(horizontal: 11),
      decoration: BoxDecoration(
        color: ChatTheme.of(context).primaryMist,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            fastEnabled ? Icons.bolt_rounded : Icons.tune_rounded,
            color: color,
            size: 17,
          ),
          SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: color,
                fontSize: 13,
                fontWeight: FontWeight.w500,
                letterSpacing: 0,
              ),
            ),
          ),
          SizedBox(width: 5),
          Icon(
            expanded
                ? Icons.keyboard_arrow_up_rounded
                : Icons.keyboard_arrow_down_rounded,
            color: ChatTheme.of(context).textSecondary,
            size: 18,
          ),
        ],
      ),
    );
  }
}

MenuStyle _sessionConfigMenuStyle(
  BuildContext context, {
  required double width,
}) {
  return MenuStyle(
    backgroundColor: WidgetStatePropertyAll(ChatTheme.of(context).surface),
    surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
    shadowColor: WidgetStatePropertyAll(Color(0x18000000)),
    elevation: WidgetStatePropertyAll(10),
    padding: WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: 6, vertical: 7),
    ),
    minimumSize: WidgetStatePropertyAll(Size(width, 0)),
    maximumSize: WidgetStatePropertyAll(Size(width, 560)),
    shape: WidgetStatePropertyAll(
      RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: ChatTheme.of(context).border),
      ),
    ),
  );
}

ButtonStyle _sessionConfigButtonStyle(
  BuildContext context, {
  required double width,
}) {
  return ButtonStyle(
    minimumSize: WidgetStatePropertyAll(Size(width - 12, 42)),
    maximumSize: WidgetStatePropertyAll(Size(width - 12, 42)),
    padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 10)),
    shape: WidgetStatePropertyAll(
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
    ),
    foregroundColor: WidgetStatePropertyAll(ChatTheme.of(context).textPrimary),
    overlayColor: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.hovered) ||
          states.contains(WidgetState.focused)) {
        return ChatTheme.of(context).primaryMist;
      }
      return Colors.transparent;
    }),
  );
}

ButtonStyle _sessionConfigChoiceButtonStyle(
  BuildContext context, {
  required double width,
}) {
  return ButtonStyle(
    minimumSize: WidgetStatePropertyAll(Size(width - 12, 48)),
    maximumSize: WidgetStatePropertyAll(Size(width - 12, 56)),
    padding: WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: 12, vertical: 7),
    ),
    shape: WidgetStatePropertyAll(
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
    ),
    foregroundColor: WidgetStatePropertyAll(ChatTheme.of(context).textPrimary),
    overlayColor: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.hovered) ||
          states.contains(WidgetState.focused)) {
        return ChatTheme.of(context).primaryMist;
      }
      return Colors.transparent;
    }),
  );
}

class _SessionConfigSelectors extends StatelessWidget {
  const _SessionConfigSelectors({
    required this.modelOption,
    required this.reasoningEffortOption,
    required this.enabled,
    required this.onModelSelected,
    required this.onReasoningEffortSelected,
  });

  final ChatConfigOption? modelOption;
  final ChatConfigOption? reasoningEffortOption;
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
            key: Key('prompt-model-selector'),
            tooltip: 'Select model',
            icon: Icons.memory_rounded,
            option: modelOption!,
            enabled: modelEnabled,
            includeChoiceGroup: true,
            onSelected: onModelSelected,
          ),
        if (hasEffortChoices)
          _SessionConfigDropdown(
            key: Key('prompt-reasoning-effort-selector'),
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
  final ChatConfigOption option;
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
        ? ChatTheme.of(context).textTertiary
        : emphasized
        ? ChatTheme.of(context).danger
        : ChatTheme.of(context).primaryDark;
    final background = emphasized
        ? ChatTheme.of(context).danger.withValues(alpha: 0.08)
        : Colors.transparent;
    final borderColor = emphasized
        ? ChatTheme.of(context).danger.withValues(alpha: 0.3)
        : Colors.transparent;
    return Container(
      height: 30,
      constraints: BoxConstraints(maxWidth: 190),
      padding: EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: enabled ? borderColor : ChatTheme.of(context).border,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 15),
          SizedBox(width: 5),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: color,
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
                letterSpacing: 0,
              ),
            ),
          ),
          SizedBox(width: 3),
          Icon(Icons.keyboard_arrow_down_rounded, color: color, size: 16),
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
          color: selected
              ? ChatTheme.of(context).success
              : ChatTheme.of(context).primaryDark,
        ),
        SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: ChatTheme.of(context).textPrimary,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0,
                ),
              ),
              if (description.isNotEmpty)
                Text(
                  description,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: ChatTheme.of(context).textSecondary,
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
    final primary = SizedBox(
      width: 36,
      height: 36,
      child: Tooltip(
        message: isSending
            ? (ChatStrings.of(context)?.stop ?? 'Stop')
            : (ChatStrings.of(context)?.send ?? 'Send'),
        child: FilledButton(
          onPressed: isSending ? onStop : (canSend ? onSend : null),
          key: Key('prompt-action-button'),
          style: FilledButton.styleFrom(
            foregroundColor: IanvsTheme.foregroundFor(
              ChatTheme.of(context).textPrimary,
            ),
            disabledForegroundColor: ChatTheme.of(context).textTertiary,
            backgroundColor: ChatTheme.of(context).textPrimary,
            disabledBackgroundColor: ChatTheme.of(context).surfaceRaised,
            elevation: 0,
            padding: EdgeInsets.zero,
            shape: CircleBorder(),
          ),
          child: Icon(
            isSending ? Icons.stop_rounded : Icons.arrow_upward_rounded,
            size: 19,
          ),
        ),
      ),
    );
    if (!isSending) return primary;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (canSend) ...[
          Tooltip(
            message: 'Add this message to the queue',
            child: IconButton(
              key: Key('prompt-queue-button'),
              onPressed: onSend,
              visualDensity: VisualDensity.standard,
              iconSize: 19,
              icon: Icon(Icons.playlist_add_rounded),
            ),
          ),
          SizedBox(width: 4),
        ],
        primary,
      ],
    );
  }
}

IconData _policyIcon(ChatToolCallExecutionPolicy policy) {
  return switch (policy) {
    ChatToolCallExecutionPolicy.defaultPermissions =>
      Icons.admin_panel_settings_outlined,
    ChatToolCallExecutionPolicy.autoReview => Icons.verified_user_outlined,
    ChatToolCallExecutionPolicy.fullAccess => Icons.all_inclusive_rounded,
  };
}

String _policyLabel(ChatToolCallExecutionPolicy policy) {
  return switch (policy) {
    ChatToolCallExecutionPolicy.defaultPermissions => '默认权限',
    ChatToolCallExecutionPolicy.autoReview => '自动审查',
    ChatToolCallExecutionPolicy.fullAccess => '完全访问权限',
  };
}

String _policyDescription(
  ChatToolCallExecutionPolicy policy, {
  required bool hasPermissionReviewer,
}) {
  return switch (policy) {
    ChatToolCallExecutionPolicy.defaultPermissions => 'Agent 请求授权时由你确认',
    ChatToolCallExecutionPolicy.autoReview =>
      hasPermissionReviewer ? '先审查授权请求，未决时再确认' : '信任规则未命中时再确认',
    ChatToolCallExecutionPolicy.fullAccess => '自动批准 Agent 的授权请求',
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
      constraints: BoxConstraints(maxHeight: 154),
      child: ListView.separated(
        shrinkWrap: true,
        padding: EdgeInsets.fromLTRB(6, 6, 6, 4),
        itemBuilder: (context, index) {
          final entry = entries[index];
          return _CommandSuggestionTile(
            invocation: entry.invocation,
            description: entry.description,
            onTap: () => onSelect(entry),
            parametersPreview: parameterPreviews[entry],
          );
        },
        separatorBuilder: (_, _) => SizedBox(height: 3),
        itemCount: entries.length,
      ),
    );
  }
}

final class _CommandSearchEntry {
  _CommandSearchEntry({
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
      borderRadius: BorderRadius.circular(context.ianvs.controlRadius),
      onTap: onTap,
      child: Container(
        constraints: BoxConstraints(minHeight: 38),
        padding: EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: ChatTheme.of(context).surfaceRaised,
          borderRadius: BorderRadius.circular(context.ianvs.controlRadius),
          border: Border.all(color: ChatTheme.of(context).border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  Icons.terminal_rounded,
                  color: ChatTheme.of(context).primaryDark,
                  size: 15,
                ),
                SizedBox(width: 7),
                SizedBox(
                  width: 126,
                  child: Text(
                    invocation,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: ChatTheme.of(context).textPrimary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0,
                    ),
                  ),
                ),
                if (description.isNotEmpty) ...[
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      description,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: ChatTheme.of(context).textSecondary,
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
              SizedBox(height: 3),
              SelectableText(
                parametersPreview!.text,
                key: Key('command-parameters-preview'),
                maxLines: 1,
                style: TextStyle(
                  color: ChatTheme.of(context).textTertiary,
                  fontFamily: context.ianvsTypography.code.fontFamily,
                  fontFamilyFallback:
                      context.ianvsTypography.code.fontFamilyFallback,
                  fontSize: 10,
                ),
              ),
              if (parametersPreview!.omission != null)
                Text(
                  'Details omitted · ${parametersPreview!.omission!.resource}',
                  style: TextStyle(
                    color: ChatTheme.of(context).warning,
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
  required ChatInputBudget budget,
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

class _AttachmentTray extends StatelessWidget {
  const _AttachmentTray({
    required this.attachments,
    required this.promptCapabilities,
    required this.onRemove,
  });

  final List<PromptAttachment> attachments;
  final ChatPromptCapabilities? promptCapabilities;
  final ValueChanged<PromptAttachment> onRemove;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(8, 0, 8, 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final attachment in attachments)
              _AttachmentChip(
                key: ValueKey(attachment.identity),
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

class _ImageAttachmentLimitationNotice extends StatelessWidget {
  const _ImageAttachmentLimitationNotice({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(10, 0, 10, 8),
      child: Container(
        key: Key('prompt-image-model-limitation'),
        width: double.infinity,
        padding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: ChatTheme.of(context).warning.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(context.ianvs.panelRadius),
          border: Border.all(
            color: ChatTheme.of(context).warning.withValues(alpha: 0.25),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: EdgeInsets.only(top: 1),
              child: Icon(
                Icons.visibility_off_outlined,
                size: 15,
                color: ChatTheme.of(context).warning,
              ),
            ),
            SizedBox(width: 7),
            Expanded(
              child: Text(
                message,
                style: TextStyle(
                  color: ChatTheme.of(context).textSecondary,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  height: 1.35,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AttachmentChip extends StatelessWidget {
  const _AttachmentChip({
    super.key,
    required this.attachment,
    required this.promptCapabilities,
    required this.onRemove,
  });

  final PromptAttachment attachment;
  final ChatPromptCapabilities? promptCapabilities;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    if (attachment.isImage && promptCapabilities?.image == true) {
      return _ImageAttachmentPreview(
        attachment: attachment,
        onRemove: onRemove,
      );
    }
    final size = attachment.displaySize;
    final mode = attachment.promptMode(promptCapabilities);
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: 320),
      child: Container(
        padding: EdgeInsets.fromLTRB(8, 4, 4, 4),
        decoration: BoxDecoration(
          color: ChatTheme.of(context).surfaceRaised,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: ChatTheme.of(context).border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.insert_drive_file_outlined,
              color: ChatTheme.of(context).primaryDark,
              size: 14,
            ),
            SizedBox(width: 5),
            Flexible(
              child: Text(
                attachment.name,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: ChatTheme.of(context).textPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0,
                ),
              ),
            ),
            if (size.isNotEmpty) ...[
              SizedBox(width: 5),
              Text(
                size,
                style: TextStyle(
                  color: ChatTheme.of(context).textTertiary,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0,
                ),
              ),
            ],
            SizedBox(width: 5),
            _AttachmentModeBadge(mode: mode),
            SizedBox(
              width: 24,
              height: 24,
              child: IconButton(
                onPressed: onRemove,
                tooltip: 'Remove attachment',
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.standard,
                iconSize: 14,
                color: ChatTheme.of(context).textSecondary,
                icon: Icon(Icons.close_rounded),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ImageAttachmentPreview extends StatefulWidget {
  const _ImageAttachmentPreview({
    required this.attachment,
    required this.onRemove,
  });

  final PromptAttachment attachment;
  final VoidCallback onRemove;

  @override
  State<_ImageAttachmentPreview> createState() =>
      _ImageAttachmentPreviewState();
}

class _ImageAttachmentPreviewState extends State<_ImageAttachmentPreview> {
  ImageProvider<Object>? _previewProvider;
  Object? _previewError;

  @override
  void initState() {
    super.initState();
    _updatePreviewProvider();
  }

  @override
  void didUpdateWidget(covariant _ImageAttachmentPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.attachment.data != widget.attachment.data ||
        oldWidget.attachment.path != widget.attachment.path) {
      _updatePreviewProvider();
    }
  }

  void _updatePreviewProvider() {
    _previewProvider = null;
    _previewError = null;
    final attachment = widget.attachment;
    final data = attachment.data;
    try {
      final ImageProvider<Object> source;
      if (data == null) {
        source = ChatPlatformScope.of(context).imageForPath(attachment.path);
      } else {
        source = MemoryImage(base64Decode(data));
      }
      _previewProvider = ResizeImage.resizeIfNeeded(164, 164, source);
    } on FormatException catch (error) {
      _previewError = error;
    }
  }

  @override
  Widget build(BuildContext context) {
    final attachment = widget.attachment;
    final provider = _previewProvider;
    final preview = provider == null
        ? _imageErrorBuilder(
            context,
            _previewError ?? FormatException('Invalid image data'),
            null,
          )
        : Image(
            image: provider,
            width: 82,
            height: 82,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: _imageErrorBuilder,
          );

    return Semantics(
      label: 'Attached image ${attachment.name}',
      child: Tooltip(
        message: attachment.name,
        child: SizedBox(
          key: Key('prompt-image-attachment-${attachment.name}'),
          width: 88,
          height: 88,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: ChatTheme.of(context).surfaceRaised,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: ChatTheme.of(context).border),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(13),
                    child: preview,
                  ),
                ),
              ),
              Positioned(
                top: 5,
                right: 5,
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: IconButton.filled(
                    key: Key(
                      'prompt-image-attachment-remove-${attachment.name}',
                    ),
                    onPressed: widget.onRemove,
                    tooltip: 'Remove image',
                    padding: EdgeInsets.zero,
                    visualDensity: VisualDensity.standard,
                    style: IconButton.styleFrom(
                      backgroundColor: ChatTheme.of(context).textPrimary,
                      foregroundColor: ChatTheme.of(context).surface,
                    ),
                    iconSize: 16,
                    icon: Icon(Icons.close_rounded),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _imageErrorBuilder(
    BuildContext context,
    Object error,
    StackTrace? stackTrace,
  ) {
    return ColoredBox(
      color: ChatTheme.of(context).surfaceRaised,
      child: Center(
        child: Icon(
          Icons.broken_image_outlined,
          color: ChatTheme.of(context).textTertiary,
          size: 24,
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
    final color = _attachmentModeColor(context, mode);
    return Tooltip(
      message: _attachmentModeTooltip(mode),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.09),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: color.withValues(alpha: 0.24)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_attachmentModeIcon(mode), size: 11, color: color),
            SizedBox(width: 3),
            Text(
              _attachmentModeLabel(mode),
              style: TextStyle(
                color: color,
                fontSize: 10,
                fontWeight: FontWeight.w600,
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

Color _attachmentModeColor(
  BuildContext context,
  PromptAttachmentPromptMode mode,
) {
  return switch (mode) {
    PromptAttachmentPromptMode.image => ChatTheme.of(context).primaryDark,
    PromptAttachmentPromptMode.audio => ChatTheme.of(context).primaryDark,
    PromptAttachmentPromptMode.embeddedResource => ChatTheme.of(
      context,
    ).success,
    PromptAttachmentPromptMode.resourceLink => ChatTheme.of(
      context,
    ).textSecondary,
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
