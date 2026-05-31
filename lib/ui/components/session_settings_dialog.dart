import 'dart:async';

import 'package:flutter/material.dart';

import '../../acp/acp_session_settings.dart';
import '../../state/chat_controller.dart';
import '../theme/app_design_tokens.dart';

class SessionSettingsDialog extends StatelessWidget {
  const SessionSettingsDialog({super.key, required this.controller});

  final ChatController controller;

  @override
  Widget build(BuildContext context) {
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

    final settings = controller.sessionSettings;
    final settingsEnabled =
        !controller.isStreaming &&
        !controller.isSessionOperationRunning &&
        !controller.sessionSettingsLoading;
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SessionHeader(
            sessionId: session.shortId,
            cwd: session.cwd,
            loading: controller.sessionSettingsLoading,
          ),
          if (settings.modelOption case final modelOption?) ...[
            const SizedBox(height: 8),
            _ModelSection(
              option: modelOption,
              enabled: settingsEnabled,
              onChanged: (modelValue) {
                unawaited(controller.setSessionModel(modelValue));
              },
            ),
          ],
          if (settings.shouldUseLegacyModes) ...[
            const SizedBox(height: 8),
            _ModeSection(
              settings: settings,
              enabled: settingsEnabled,
              onChanged: (modeId) {
                unawaited(controller.setSessionMode(modeId));
              },
            ),
          ],
          const SizedBox(height: 8),
          _ConfigSection(
            options: settings.nonModelConfigOptions,
            enabled: settingsEnabled,
            onChanged: (configId, value) {
              unawaited(controller.setConfigOption(configId, value));
            },
          ),
        ],
      ),
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

class _ModelSection extends StatelessWidget {
  const _ModelSection({
    required this.option,
    required this.enabled,
    required this.onChanged,
  });

  final AcpConfigOption option;
  final bool enabled;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final selectedValue =
        option.options.any((choice) => choice.value == option.currentValue)
        ? option.currentValue
        : null;

    return _Panel(
      icon: Icons.memory_rounded,
      title: 'Model',
      child: DropdownButtonFormField<String>(
        isExpanded: true,
        initialValue: selectedValue,
        decoration: _inputDecoration('Current model'),
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
      ),
    );
  }
}

class _ModeSection extends StatelessWidget {
  const _ModeSection({
    required this.settings,
    required this.enabled,
    required this.onChanged,
  });

  final AcpSessionSettings settings;
  final bool enabled;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final modes = settings.modes.availableModes;
    final currentModeId = settings.modes.currentModeId;
    final selectedValue = modes.any((mode) => mode.id == currentModeId)
        ? currentModeId
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

class _ConfigSection extends StatelessWidget {
  const _ConfigSection({
    required this.options,
    required this.enabled,
    required this.onChanged,
  });

  final List<AcpConfigOption> options;
  final bool enabled;
  final void Function(String configId, Object value) onChanged;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      icon: Icons.tune_rounded,
      title: 'Config Options',
      child: options.isEmpty
          ? const _EmptyState.inline(
              icon: Icons.rule_folder_outlined,
              message: 'No config options exposed by this session.',
            )
          : Column(
              children: [
                for (final option in options) ...[
                  _ConfigOptionTile(
                    option: option,
                    enabled: enabled,
                    onChanged: (value) => onChanged(option.id, value),
                  ),
                  if (option != options.last) const SizedBox(height: 8),
                ],
              ],
            ),
    );
  }
}

class _ConfigOptionTile extends StatelessWidget {
  const _ConfigOptionTile({
    required this.option,
    required this.enabled,
    required this.onChanged,
  });

  final AcpConfigOption option;
  final bool enabled;
  final ValueChanged<Object> onChanged;

  @override
  Widget build(BuildContext context) {
    final selectedValue =
        option.options.any((choice) => choice.value == option.currentValue)
        ? option.currentValue
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
                : DropdownButtonFormField<String>(
                    isExpanded: true,
                    initialValue: selectedValue,
                    decoration: _inputDecoration('Value'),
                    items: option.options
                        .map(
                          (choice) => DropdownMenuItem<String>(
                            value: choice.value,
                            child: Text(
                              choice.label,
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
