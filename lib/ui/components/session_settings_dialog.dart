import 'dart:async';

import 'package:flutter/material.dart';

import '../../acp/acp_input_budget.dart';
import '../../acp/acp_session_settings.dart';
import '../../state/chat_controller.dart';
import '../bounded_metadata_preview.dart';
import '../theme/app_design_tokens.dart';

const int _inlineChoicePreviewItems = 5;

class SessionSettingsDialog extends StatelessWidget {
  const SessionSettingsDialog({
    super.key,
    required this.controller,
    this.inputBudget = const AcpInputBudget(),
  });

  final ChatController controller;
  final AcpInputBudget inputBudget;

  @override
  Widget build(BuildContext context) {
    inputBudget.validate();
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return AlertDialog(
          title: const Text('Session Settings'),
          content: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.62,
            ),
            child: SizedBox(width: 600, child: _buildContent()),
          ),
          actions: [
            if (controller.currentSession != null &&
                controller.capabilities?.session.fork == true)
              TextButton.icon(
                onPressed: controller.canForkCurrentSession
                    ? () => unawaited(controller.forkCurrentSession())
                    : null,
                icon: const Icon(Icons.call_split_rounded),
                label: const Text('Fork Session'),
              ),
            if (controller.currentSession != null &&
                controller.capabilities?.session.close == true)
              TextButton.icon(
                onPressed: controller.canCloseCurrentSession
                    ? () => unawaited(_confirmCloseSession(context))
                    : null,
                icon: const Icon(Icons.close_rounded),
                label: const Text('Close Session'),
                style: TextButton.styleFrom(foregroundColor: AppColors.danger),
              ),
            if (controller.currentSession != null &&
                controller.capabilities?.session.delete == true)
              TextButton.icon(
                onPressed: controller.canDeleteCurrentSession
                    ? () => unawaited(_confirmDeleteSession(context))
                    : null,
                icon: const Icon(Icons.delete_outline_rounded),
                label: const Text('Delete Session'),
                style: TextButton.styleFrom(foregroundColor: AppColors.danger),
              ),
            TextButton.icon(
              onPressed:
                  controller.currentSession != null &&
                      !controller.isStreaming &&
                      !controller.isSessionOperationRunning &&
                      !controller.sessionSettingsLoading
                  ? () => unawaited(controller.refreshSessionSettings())
                  : null,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Refresh'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  Widget _buildContent() {
    final session = controller.currentSession;
    if (session == null) {
      return const _EmptyState(
        icon: Icons.tune_rounded,
        title: 'No active session',
        message: 'Create or resume a session to inspect settings.',
      );
    }

    return _SessionSettingsScroll(
      sessionId: session.shortId,
      cwd: session.cwd,
      loading: controller.sessionSettingsLoading,
      settings: controller.sessionSettings,
      enabled:
          !controller.isStreaming &&
          !controller.isSessionOperationRunning &&
          !controller.sessionSettingsLoading,
      inputBudget: inputBudget,
      onModelChanged: (value) {
        unawaited(controller.setSessionModel(value));
      },
      onReasoningEffortChanged: (value) {
        unawaited(controller.setSessionReasoningEffort(value));
      },
      onModeChanged: (value) {
        unawaited(controller.setSessionMode(value));
      },
      onConfigChanged: (id, value) {
        unawaited(controller.setConfigOption(id, value));
      },
    );
  }

  Future<void> _confirmCloseSession(BuildContext context) async {
    final session = controller.currentSession;
    if (session == null) return;
    final shouldClose = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Close Session?'),
          content: Text(
            'Close "${session.displayTitle}" and release agent resources. '
            'This does not delete persisted conversation history.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: FilledButton.styleFrom(
                foregroundColor: Colors.white,
                backgroundColor: AppColors.danger,
              ),
              child: const Text('Close Session'),
            ),
          ],
        );
      },
    );
    if (shouldClose != true) return;
    final closingSessionId = session.id;
    await controller.closeCurrentSession();
    if (controller.currentSession?.id == closingSessionId) return;
    if (context.mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _confirmDeleteSession(BuildContext context) async {
    final session = controller.currentSession;
    if (session == null) return;
    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Session?'),
        content: Text(
          'Permanently delete "${session.displayTitle}" from the agent\'s '
          'session history. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              foregroundColor: Colors.white,
              backgroundColor: AppColors.danger,
            ),
            child: const Text('Delete Session'),
          ),
        ],
      ),
    );
    if (shouldDelete != true) return;
    final deletingSessionId = session.id;
    await controller.deleteCurrentSession();
    if (controller.currentSession?.id == deletingSessionId) return;
    if (context.mounted) Navigator.of(context).pop();
  }
}

class _SessionSettingsScroll extends StatefulWidget {
  const _SessionSettingsScroll({
    required this.sessionId,
    required this.cwd,
    required this.loading,
    required this.settings,
    required this.enabled,
    required this.inputBudget,
    required this.onModelChanged,
    required this.onReasoningEffortChanged,
    required this.onModeChanged,
    required this.onConfigChanged,
  });

  final String sessionId;
  final String cwd;
  final bool loading;
  final AcpSessionSettings settings;
  final bool enabled;
  final AcpInputBudget inputBudget;
  final ValueChanged<String> onModelChanged;
  final ValueChanged<String> onReasoningEffortChanged;
  final ValueChanged<String> onModeChanged;
  final void Function(String id, Object value) onConfigChanged;

  @override
  State<_SessionSettingsScroll> createState() => _SessionSettingsScrollState();
}

class _SessionSettingsScrollState extends State<_SessionSettingsScroll> {
  late _SettingsProjection _projection = _SettingsProjection.from(
    widget.settings.configOptions,
  );

  @override
  void didUpdateWidget(covariant _SessionSettingsScroll oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(
      widget.settings.configOptions,
      oldWidget.settings.configOptions,
    )) {
      _projection = _SettingsProjection.from(widget.settings.configOptions);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = widget.settings;
    final modelOption = _projection.modelOption;
    final reasoningOption = _projection.reasoningEffortOption;
    final hasConfiguration = modelOption != null || reasoningOption != null;
    final hasModes = settings.shouldUseLegacyModes;
    final optionIndexes = _projection.nonModelOptionIndexes;
    final configBodyCount = optionIndexes.isEmpty ? 1 : optionIndexes.length;
    final hasIncompleteNotice =
        settings.truncated || settings.omissions.isNotEmpty;
    final itemCount =
        1 +
        (hasConfiguration ? 1 : 0) +
        (hasModes ? 1 : 0) +
        1 +
        configBodyCount +
        (hasIncompleteNotice ? 1 : 0);

    return CustomScrollView(
      key: const ValueKey('session-settings-scroll'),
      slivers: [
        SliverList(
          delegate: SliverChildBuilderDelegate((context, index) {
            var cursor = index;
            if (cursor == 0) {
              return _SessionHeader(
                sessionId: widget.sessionId,
                cwd: widget.cwd,
                loading: widget.loading,
              );
            }
            cursor -= 1;
            if (hasConfiguration) {
              if (cursor == 0) {
                return _SettingsSliverItem(
                  child: _SessionConfigurationSection(
                    modelOption: modelOption,
                    reasoningEffortOption: reasoningOption,
                    configOptionsActive: settings.hasConfigOptions,
                    enabled: widget.enabled,
                    inputBudget: widget.inputBudget,
                    onModelChanged: widget.onModelChanged,
                    onReasoningEffortChanged: widget.onReasoningEffortChanged,
                  ),
                );
              }
              cursor -= 1;
            }
            if (hasModes) {
              if (cursor == 0) {
                return _SettingsSliverItem(
                  child: _ModeSection(
                    settings: settings,
                    enabled: widget.enabled,
                    inputBudget: widget.inputBudget,
                    onChanged: widget.onModeChanged,
                  ),
                );
              }
              cursor -= 1;
            }
            if (cursor == 0) {
              return const _SettingsSliverItem(child: _ConfigSectionHeading());
            }
            cursor -= 1;
            if (cursor < configBodyCount) {
              if (optionIndexes.isEmpty) {
                return const _SettingsSliverItem(
                  compact: true,
                  child: _EmptyState.inline(
                    icon: Icons.rule_folder_outlined,
                    message: 'No config options exposed by this session.',
                  ),
                );
              }
              final option = settings.configOptions[optionIndexes[cursor]];
              return _SettingsSliverItem(
                compact: true,
                child: _ConfigOptionTile(
                  option: option,
                  enabled: widget.enabled,
                  inputBudget: widget.inputBudget,
                  onChanged: (value) =>
                      widget.onConfigChanged(option.id, value),
                ),
              );
            }
            return _SettingsSliverItem(
              compact: true,
              child: _SettingsIncompleteNotice(
                truncated: settings.truncated,
                omissions: settings.omissions,
              ),
            );
          }, childCount: itemCount),
        ),
      ],
    );
  }
}

final class _SettingsProjection {
  const _SettingsProjection({
    required this.modelOption,
    required this.reasoningEffortOption,
    required this.nonModelOptionIndexes,
  });

  factory _SettingsProjection.from(List<AcpConfigOption> options) {
    AcpConfigOption? modelOption;
    AcpConfigOption? reasoningEffortOption;
    final nonModelOptionIndexes = <int>[];
    for (var index = 0; index < options.length; index++) {
      final option = options[index];
      final isModel = option.isModelOption;
      final isReasoningEffort = option.isReasoningEffortOption;
      modelOption ??= isModel ? option : null;
      reasoningEffortOption ??= isReasoningEffort ? option : null;
      if (!isModel && !isReasoningEffort) {
        nonModelOptionIndexes.add(index);
      }
    }
    return _SettingsProjection(
      modelOption: modelOption,
      reasoningEffortOption: reasoningEffortOption,
      nonModelOptionIndexes: List<int>.unmodifiable(nonModelOptionIndexes),
    );
  }

  final AcpConfigOption? modelOption;
  final AcpConfigOption? reasoningEffortOption;
  final List<int> nonModelOptionIndexes;
}

class _SettingsSliverItem extends StatelessWidget {
  const _SettingsSliverItem({required this.child, this.compact = false});

  final Widget child;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(top: compact ? 6 : 8),
      child: child,
    );
  }
}

class _ConfigSectionHeading extends StatelessWidget {
  const _ConfigSectionHeading();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.surfaceRaised,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.border),
      ),
      child: const Row(
        children: [
          Icon(Icons.tune_rounded, size: 17, color: AppColors.primaryDark),
          SizedBox(width: 7),
          Text(
            'Config Options',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w900,
              letterSpacing: 0,
            ),
          ),
        ],
      ),
    );
  }
}

class _SessionHeader extends StatelessWidget {
  const _SessionHeader({
    required this.sessionId,
    required this.cwd,
    required this.loading,
  });

  final String sessionId;
  final String cwd;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.primaryMist,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.primarySoft),
      ),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: AppColors.primarySoft,
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: const Icon(
              Icons.settings_suggest_outlined,
              color: AppColors.primaryDark,
              size: 16,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Session $sessionId',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  cwd,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0,
                  ),
                ),
              ],
            ),
          ),
          if (loading) ...[
            const SizedBox(width: 10),
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ],
        ],
      ),
    );
  }
}

class _SessionConfigurationSection extends StatelessWidget {
  const _SessionConfigurationSection({
    required this.modelOption,
    required this.reasoningEffortOption,
    required this.configOptionsActive,
    required this.enabled,
    required this.inputBudget,
    required this.onModelChanged,
    required this.onReasoningEffortChanged,
  });

  final AcpConfigOption? modelOption;
  final AcpConfigOption? reasoningEffortOption;
  final bool configOptionsActive;
  final bool enabled;
  final AcpInputBudget inputBudget;
  final ValueChanged<String> onModelChanged;
  final ValueChanged<String> onReasoningEffortChanged;

  @override
  Widget build(BuildContext context) {
    final modelOption = this.modelOption;
    final reasoningEffortOption = this.reasoningEffortOption;
    return _Panel(
      icon: Icons.tune_rounded,
      title: 'Session Configuration',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (modelOption != null) ...[
            _ModelDropdown(
              option: modelOption,
              enabled: enabled,
              inputBudget: inputBudget,
              onChanged: onModelChanged,
            ),
          ],
          if (modelOption != null && reasoningEffortOption != null)
            const SizedBox(height: 10),
          if (reasoningEffortOption != null) ...[
            _ReasoningEffortControl(
              option: reasoningEffortOption,
              enabled: enabled,
              inputBudget: inputBudget,
              onChanged: onReasoningEffortChanged,
            ),
          ],
          const SizedBox(height: 10),
          _CapabilitySummary(
            hasModel: modelOption != null,
            hasReasoningEffort: reasoningEffortOption != null,
            configOptionsActive: configOptionsActive,
            reasoningEffortConfigId: reasoningEffortOption?.id,
          ),
        ],
      ),
    );
  }
}

class _ModelDropdown extends StatelessWidget {
  const _ModelDropdown({
    required this.option,
    required this.enabled,
    required this.inputBudget,
    required this.onChanged,
  });

  final AcpConfigOption option;
  final bool enabled;
  final AcpInputBudget inputBudget;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    if (option.options.length > _inlineChoicePreviewItems) {
      return _LargeChoiceControl(
        label: 'Active model',
        sourceIdentity: option.options,
        currentValue: option.currentValue,
        enabled: enabled,
        inputBudget: inputBudget,
        itemCount: option.options.length,
        valueAt: (index) => option.options[index].value,
        labelAt: (index) => option.options[index].label,
        descriptionAt: (index) => option.options[index].description,
        onChanged: onChanged,
      );
    }
    final selectedValue =
        option.options.any((choice) => choice.value == option.currentValue)
        ? option.currentValue
        : null;

    return DropdownButtonFormField<String>(
      isExpanded: true,
      initialValue: selectedValue,
      decoration: _inputDecoration('Active model'),
      items: option.options
          .map(
            (choice) => DropdownMenuItem<String>(
              value: choice.value,
              child: Text(choice.label, overflow: TextOverflow.ellipsis),
            ),
          )
          .toList(),
      hint: option.currentValue.isEmpty
          ? null
          : Text(option.currentValue, overflow: TextOverflow.ellipsis),
      onChanged: enabled
          ? (value) {
              if (value != null) onChanged(value);
            }
          : null,
    );
  }
}

class _ReasoningEffortControl extends StatelessWidget {
  const _ReasoningEffortControl({
    required this.option,
    required this.enabled,
    required this.inputBudget,
    required this.onChanged,
  });

  final AcpConfigOption option;
  final bool enabled;
  final AcpInputBudget inputBudget;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    if (option.options.length > _inlineChoicePreviewItems) {
      return _LargeChoiceControl(
        label: 'Reasoning effort',
        sourceIdentity: option.options,
        currentValue: option.currentValue,
        enabled: enabled,
        inputBudget: inputBudget,
        itemCount: option.options.length,
        valueAt: (index) => option.options[index].value,
        labelAt: (index) => option.options[index].label,
        descriptionAt: (index) => option.options[index].description,
        onChanged: onChanged,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Reasoning effort',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 13,
            fontWeight: FontWeight.w900,
            letterSpacing: 0,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final choice in option.options)
              ChoiceChip(
                label: Text(choice.label, overflow: TextOverflow.ellipsis),
                selected: choice.value == option.currentValue,
                onSelected: enabled
                    ? (_) {
                        onChanged(choice.value);
                      }
                    : null,
                selectedColor: AppColors.primarySoft,
                backgroundColor: AppColors.surface,
                side: BorderSide(
                  color: choice.value == option.currentValue
                      ? AppColors.primary
                      : AppColors.border,
                ),
                labelStyle: TextStyle(
                  color: choice.value == option.currentValue
                      ? AppColors.primaryDark
                      : AppColors.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0,
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _CapabilitySummary extends StatelessWidget {
  const _CapabilitySummary({
    required this.hasModel,
    required this.hasReasoningEffort,
    required this.configOptionsActive,
    required this.reasoningEffortConfigId,
  });

  final bool hasModel;
  final bool hasReasoningEffort;
  final bool configOptionsActive;
  final String? reasoningEffortConfigId;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: AppColors.bg,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: AppColors.borderSoft),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        children: [
          if (hasModel) const _TinyPill('Model switching supported'),
          if (hasReasoningEffort) const _TinyPill('Reasoning effort supported'),
          if (reasoningEffortConfigId != null &&
              reasoningEffortConfigId!.isNotEmpty)
            _TinyPill('ACP config option: $reasoningEffortConfigId'),
          if (configOptionsActive) const _TinyPill('Config options active'),
        ],
      ),
    );
  }
}

class _ModeSection extends StatelessWidget {
  const _ModeSection({
    required this.settings,
    required this.enabled,
    required this.inputBudget,
    required this.onChanged,
  });

  final AcpSessionSettings settings;
  final bool enabled;
  final AcpInputBudget inputBudget;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final modes = settings.modes.availableModes;
    final currentModeId = settings.modes.currentModeId;
    final selectedValue = modes.length <= _inlineChoicePreviewItems
        ? (modes.any((mode) => mode.id == currentModeId) ? currentModeId : null)
        : null;

    return _Panel(
      icon: Icons.swap_horiz_rounded,
      title: 'Mode',
      child: modes.isEmpty
          ? _EmptyState.inline(
              icon: Icons.info_outline_rounded,
              message: currentModeId == null || currentModeId.isEmpty
                  ? 'No modes exposed by this session.'
                  : 'Current mode is "$currentModeId", but no mode list was exposed.',
            )
          : modes.length > _inlineChoicePreviewItems
          ? _LargeChoiceControl(
              label: 'Current mode',
              sourceIdentity: modes,
              currentValue: currentModeId ?? '',
              enabled: enabled,
              inputBudget: inputBudget,
              itemCount: modes.length,
              valueAt: (index) => modes[index].id,
              labelAt: (index) => modes[index].label,
              descriptionAt: (index) => null,
              onChanged: onChanged,
            )
          : DropdownButtonFormField<String>(
              isExpanded: true,
              initialValue: selectedValue,
              decoration: _inputDecoration('Current mode'),
              items: modes
                  .map(
                    (mode) => DropdownMenuItem<String>(
                      value: mode.id,
                      child: Text(mode.label, overflow: TextOverflow.ellipsis),
                    ),
                  )
                  .toList(),
              hint: currentModeId == null || currentModeId.isEmpty
                  ? null
                  : Text(currentModeId, overflow: TextOverflow.ellipsis),
              onChanged: enabled
                  ? (value) {
                      if (value != null) onChanged(value);
                    }
                  : null,
            ),
    );
  }
}

class _ConfigOptionTile extends StatelessWidget {
  const _ConfigOptionTile({
    required this.option,
    required this.enabled,
    required this.inputBudget,
    required this.onChanged,
  });

  final AcpConfigOption option;
  final bool enabled;
  final AcpInputBudget inputBudget;
  final ValueChanged<Object> onChanged;

  @override
  Widget build(BuildContext context) {
    final selectedValue = option.options.length <= _inlineChoicePreviewItems
        ? (option.options.any((choice) => choice.value == option.currentValue)
              ? option.currentValue
              : null)
        : null;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: AppColors.borderSoft),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    Text(
                      option.name.isEmpty ? option.id : option.name,
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0,
                      ),
                    ),
                    _TinyPill(option.type),
                    if (option.category != null && option.category!.isNotEmpty)
                      _TinyPill(option.category!),
                    if (option.group != null && option.group!.isNotEmpty)
                      _TinyPill(option.group!),
                  ],
                ),
                if (option.description != null &&
                    option.description!.isNotEmpty) ...[
                  const SizedBox(height: 5),
                  Text(
                    option.description!,
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12,
                      height: 1.35,
                      letterSpacing: 0,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 180,
            child: option.isBooleanOption
                ? Align(
                    alignment: Alignment.centerLeft,
                    child: Switch.adaptive(
                      value: option.currentBoolValue,
                      onChanged: enabled ? (value) => onChanged(value) : null,
                      activeThumbColor: AppColors.primaryDark,
                    ),
                  )
                : option.options.isEmpty
                ? _ReadOnlyValue(value: option.currentValue)
                : option.options.length > _inlineChoicePreviewItems
                ? _LargeChoiceControl(
                    label: 'Value',
                    sourceIdentity: option.options,
                    currentValue: option.currentValue,
                    enabled: enabled,
                    inputBudget: inputBudget,
                    itemCount: option.options.length,
                    valueAt: (index) => option.options[index].value,
                    labelAt: (index) => option.options[index].label,
                    descriptionAt: (index) => option.options[index].description,
                    onChanged: onChanged,
                  )
                : DropdownButtonFormField<String>(
                    isExpanded: true,
                    initialValue: selectedValue,
                    decoration: _inputDecoration('Value'),
                    items: option.options
                        .map(
                          (choice) => DropdownMenuItem<String>(
                            value: choice.value,
                            child: Text(
                              choice.groupName == null
                                  ? choice.label
                                  : '${choice.groupName} · ${choice.label}',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                    hint: option.currentValue.isEmpty
                        ? null
                        : Text(
                            option.currentValue,
                            overflow: TextOverflow.ellipsis,
                          ),
                    onChanged: enabled
                        ? (value) {
                            if (value != null) onChanged(value);
                          }
                        : null,
                  ),
          ),
        ],
      ),
    );
  }
}

class _LargeChoiceControl extends StatefulWidget {
  const _LargeChoiceControl({
    required this.label,
    required this.sourceIdentity,
    required this.currentValue,
    required this.enabled,
    required this.inputBudget,
    required this.itemCount,
    required this.valueAt,
    required this.labelAt,
    required this.descriptionAt,
    required this.onChanged,
  });

  final String label;
  final Object sourceIdentity;
  final String currentValue;
  final bool enabled;
  final AcpInputBudget inputBudget;
  final int itemCount;
  final String Function(int index) valueAt;
  final String Function(int index) labelAt;
  final String? Function(int index) descriptionAt;
  final ValueChanged<String> onChanged;

  @override
  State<_LargeChoiceControl> createState() => _LargeChoiceControlState();
}

class _LargeChoiceControlState extends State<_LargeChoiceControl> {
  BuildContext? _dialogContext;
  var _dialogGeneration = 0;
  var _dialogOpen = false;
  var _dialogCloseScheduled = false;

  @override
  void didUpdateWidget(covariant _LargeChoiceControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_dialogOpen &&
        (widget.enabled != oldWidget.enabled ||
            widget.currentValue != oldWidget.currentValue ||
            widget.itemCount != oldWidget.itemCount ||
            !identical(widget.sourceIdentity, oldWidget.sourceIdentity) ||
            !identical(widget.inputBudget, oldWidget.inputBudget))) {
      _closeOpenDialog();
    }
  }

  @override
  void dispose() {
    _closeOpenDialog();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final previewCount = widget.itemCount < _inlineChoicePreviewItems
        ? widget.itemCount
        : _inlineChoicePreviewItems;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.label,
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontSize: 13,
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(height: 7),
        _ReadOnlyValue(value: widget.currentValue),
        const SizedBox(height: 7),
        Wrap(
          spacing: 7,
          runSpacing: 7,
          children: [
            for (var index = 0; index < previewCount; index++)
              ChoiceChip(
                label: Text(
                  widget.labelAt(index),
                  overflow: TextOverflow.ellipsis,
                ),
                selected: widget.valueAt(index) == widget.currentValue,
                onSelected: widget.enabled
                    ? (_) {
                        widget.onChanged(widget.valueAt(index));
                      }
                    : null,
              ),
            if (widget.itemCount > previewCount)
              TextButton(
                onPressed: widget.enabled
                    ? () => _openAllChoices(context)
                    : null,
                child: Text('${widget.itemCount - previewCount} more'),
              ),
          ],
        ),
      ],
    );
  }

  Future<void> _openAllChoices(BuildContext context) async {
    if (_dialogOpen || _dialogCloseScheduled) return;
    final generation = ++_dialogGeneration;
    _dialogOpen = true;
    String? value;
    try {
      value = await showDialog<String>(
        context: context,
        builder: (dialogContext) {
          final isCurrentDialog =
              mounted &&
              generation == _dialogGeneration &&
              _dialogOpen &&
              !_dialogCloseScheduled;
          if (isCurrentDialog) {
            _dialogContext = dialogContext;
          } else {
            _scheduleLateDialogClose(dialogContext);
          }
          return _SearchableChoiceDialog(
            title: widget.label,
            currentValue: widget.currentValue,
            enabled: widget.enabled,
            inputBudget: widget.inputBudget,
            itemCount: widget.itemCount,
            valueAt: widget.valueAt,
            labelAt: widget.labelAt,
            descriptionAt: widget.descriptionAt,
          );
        },
      );
    } finally {
      if (mounted && generation == _dialogGeneration) {
        _dialogOpen = false;
        _dialogContext = null;
        _dialogCloseScheduled = false;
      }
    }
    if (!mounted ||
        !context.mounted ||
        generation != _dialogGeneration ||
        !widget.enabled ||
        value == null) {
      return;
    }
    widget.onChanged(value);
  }

  void _scheduleLateDialogClose(BuildContext dialogContext) {
    final navigator = Navigator.of(dialogContext);
    final route = ModalRoute.of(dialogContext);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (navigator.mounted && route != null && route.isActive) {
        navigator.removeRoute(route);
      }
    });
  }

  void _closeOpenDialog() {
    if (!_dialogOpen || _dialogCloseScheduled) return;
    _dialogOpen = false;
    _dialogCloseScheduled = true;
    _dialogGeneration += 1;
    final closingGeneration = _dialogGeneration;
    final dialogContext = _dialogContext;
    _dialogContext = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (dialogContext != null && dialogContext.mounted) {
        Navigator.of(dialogContext).pop();
      }
      if (mounted && closingGeneration == _dialogGeneration) {
        _dialogCloseScheduled = false;
      }
    });
  }
}

class _SearchableChoiceDialog extends StatefulWidget {
  const _SearchableChoiceDialog({
    required this.title,
    required this.currentValue,
    required this.enabled,
    required this.inputBudget,
    required this.itemCount,
    required this.valueAt,
    required this.labelAt,
    required this.descriptionAt,
  });

  final String title;
  final String currentValue;
  final bool enabled;
  final AcpInputBudget inputBudget;
  final int itemCount;
  final String Function(int index) valueAt;
  final String Function(int index) labelAt;
  final String? Function(int index) descriptionAt;

  @override
  State<_SearchableChoiceDialog> createState() =>
      _SearchableChoiceDialogState();
}

class _SearchableChoiceDialogState extends State<_SearchableChoiceDialog> {
  final TextEditingController _searchController = TextEditingController();
  List<int>? _matches;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final matches = _matches;
    final visibleCount = matches?.length ?? widget.itemCount;
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 520,
        height: 420,
        child: Column(
          children: [
            TextField(
              key: const ValueKey('settings-choice-search'),
              controller: _searchController,
              autofocus: true,
              onChanged: _filter,
              decoration: _inputDecoration('Search choices'),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: visibleCount == 0
                  ? const _EmptyState.inline(
                      icon: Icons.search_off_rounded,
                      message: 'No matching choices.',
                    )
                  : ListView.builder(
                      key: const ValueKey('settings-choice-list'),
                      primary: false,
                      itemCount: visibleCount,
                      itemBuilder: (context, visibleIndex) {
                        final index = matches?[visibleIndex] ?? visibleIndex;
                        return _ChoiceListTile(
                          label: widget.labelAt(index),
                          value: widget.valueAt(index),
                          description: widget.descriptionAt(index),
                          selected:
                              widget.valueAt(index) == widget.currentValue,
                          enabled: widget.enabled,
                          inputBudget: widget.inputBudget,
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }

  void _filter(String rawQuery) {
    final query = rawQuery.trim().toLowerCase();
    if (query.isEmpty) {
      setState(() => _matches = null);
      return;
    }
    final matches = <int>[];
    for (var index = 0; index < widget.itemCount; index++) {
      if (widget.labelAt(index).toLowerCase().contains(query) ||
          widget.valueAt(index).toLowerCase().contains(query)) {
        matches.add(index);
      }
    }
    setState(() => _matches = matches);
  }
}

class _ChoiceListTile extends StatelessWidget {
  const _ChoiceListTile({
    required this.label,
    required this.value,
    required this.description,
    required this.selected,
    required this.enabled,
    required this.inputBudget,
  });

  final String label;
  final String value;
  final String? description;
  final bool selected;
  final bool enabled;
  final AcpInputBudget inputBudget;

  @override
  Widget build(BuildContext context) {
    final rawDescription = description;
    final preview = rawDescription == null || rawDescription.isEmpty
        ? null
        : writeBoundedMetadataPreview(rawDescription, budget: inputBudget);
    return ListTile(
      title: Text(label),
      subtitle: preview == null
          ? null
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  preview.text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (preview.omission != null)
                  Text(
                    'Details omitted · ${preview.omission!.resource}',
                    style: const TextStyle(
                      color: AppColors.warning,
                      fontSize: 11,
                    ),
                  ),
              ],
            ),
      trailing: selected ? const Icon(Icons.check_rounded) : null,
      enabled: enabled,
      onTap: enabled ? () => Navigator.of(context).pop(value) : null,
    );
  }
}

class _SettingsIncompleteNotice extends StatelessWidget {
  const _SettingsIncompleteNotice({
    required this.truncated,
    required this.omissions,
  });

  final bool truncated;
  final List<AcpInputOmission> omissions;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.surfaceRaised,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: AppColors.warning),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Settings incomplete',
            style: TextStyle(
              color: AppColors.warning,
              fontWeight: FontWeight.w900,
            ),
          ),
          if (truncated)
            const Text(
              'Some choices or options were omitted.',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
            ),
          for (final omission in omissions)
            Text(
              'Details omitted · ${omission.resource}',
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
        ],
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.icon, required this.title, required this.child});

  final IconData icon;
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.surfaceRaised,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 17, color: AppColors.primaryDark),
              const SizedBox(width: 7),
              Text(
                title,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

class _ReadOnlyValue extends StatelessWidget {
  const _ReadOnlyValue({required this.value});

  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 38,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: AppColors.bg,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: AppColors.border),
      ),
      child: Text(
        value.isEmpty ? 'Unset' : value,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: AppColors.textSecondary,
          fontWeight: FontWeight.w700,
          letterSpacing: 0,
        ),
      ),
    );
  }
}

class _TinyPill extends StatelessWidget {
  const _TinyPill(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.primarySoft,
        borderRadius: BorderRadius.circular(AppRadius.pill),
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

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.message,
  }) : inline = false;

  const _EmptyState.inline({required this.icon, required this.message})
    : title = null,
      inline = true;

  final IconData icon;
  final String? title;
  final String message;
  final bool inline;

  @override
  Widget build(BuildContext context) {
    final child = Row(
      mainAxisSize: inline ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, color: AppColors.primaryDark, size: inline ? 18 : 24),
        const SizedBox(width: 8),
        Flexible(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: inline
                ? CrossAxisAlignment.start
                : CrossAxisAlignment.center,
            children: [
              if (title != null) ...[
                Text(
                  title!,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0,
                  ),
                ),
                const SizedBox(height: 3),
              ],
              Text(
                message,
                textAlign: inline ? TextAlign.start : TextAlign.center,
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  height: 1.35,
                  letterSpacing: 0,
                ),
              ),
            ],
          ),
        ),
      ],
    );

    return Container(
      width: double.infinity,
      height: inline ? null : 150,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.surfaceRaised,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.border),
      ),
      child: child,
    );
  }
}

InputDecoration _inputDecoration(String label) {
  return InputDecoration(
    labelText: label,
    filled: true,
    fillColor: AppColors.surface,
    isDense: true,
    contentPadding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppRadius.sm),
      borderSide: const BorderSide(color: AppColors.border),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppRadius.sm),
      borderSide: const BorderSide(color: AppColors.border),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppRadius.sm),
      borderSide: const BorderSide(color: AppColors.primary),
    ),
  );
}
