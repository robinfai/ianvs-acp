import 'acp_input_budget.dart' as acp;

class AcpSessionSettings {
  const AcpSessionSettings({
    this.modes = const AcpSessionModeInfo(),
    this.configOptions = const <AcpConfigOption>[],
    this.omissions = const <acp.AcpInputOmission>[],
    this.truncated = false,
  });

  final AcpSessionModeInfo modes;
  final List<AcpConfigOption> configOptions;
  final List<acp.AcpInputOmission> omissions;
  final bool truncated;

  bool get hasModes => modes.availableModes.isNotEmpty;

  bool get hasConfigOptions => configOptions.isNotEmpty;

  bool get shouldUseLegacyModes => !hasConfigOptions;

  AcpConfigOption? get modelOption {
    for (final option in configOptions) {
      if (option.isModelOption) return option;
    }
    return null;
  }

  AcpConfigOption? get reasoningEffortOption {
    for (final option in configOptions) {
      if (option.isReasoningEffortOption) return option;
    }
    return null;
  }

  List<AcpConfigOption> get nonModelConfigOptions {
    return configOptions.where((option) {
      return !option.isModelOption && !option.isReasoningEffortOption;
    }).toList();
  }

  String? get currentModelLabel {
    final option = modelOption;
    if (option == null) return null;
    return option.currentChoiceLabel;
  }

  String? get currentReasoningEffortLabel {
    final option = reasoningEffortOption;
    if (option == null) return null;
    return option.currentChoiceLabel;
  }

  AcpSessionSettings copyWith({
    AcpSessionModeInfo? modes,
    List<AcpConfigOption>? configOptions,
    List<acp.AcpInputOmission>? omissions,
    bool? truncated,
  }) {
    return AcpSessionSettings(
      modes: modes ?? this.modes,
      configOptions: configOptions ?? this.configOptions,
      omissions: omissions ?? this.omissions,
      truncated: truncated ?? this.truncated,
    );
  }

  AcpSessionSettings get withConfigOptionsPreference {
    if (configOptions.isEmpty) return this;
    return AcpSessionSettings(
      configOptions: configOptions,
      omissions: omissions,
      truncated: truncated,
    );
  }

  AcpSessionSettings withPreferredConfigOptions(List<AcpConfigOption> options) {
    if (options.isEmpty) return copyWith(configOptions: options);
    return AcpSessionSettings(
      configOptions: options,
      omissions: omissions,
      truncated: truncated,
    );
  }

  AcpSessionSettings withCurrentMode(String modeId) {
    return copyWith(modes: modes.copyWith(currentModeId: modeId));
  }
}

class AcpSessionModeInfo {
  const AcpSessionModeInfo({
    this.currentModeId,
    this.availableModes = const <AcpSessionMode>[],
  });

  final String? currentModeId;
  final List<AcpSessionMode> availableModes;

  AcpSessionModeInfo copyWith({
    String? currentModeId,
    List<AcpSessionMode>? availableModes,
  }) {
    return AcpSessionModeInfo(
      currentModeId: currentModeId ?? this.currentModeId,
      availableModes: availableModes ?? this.availableModes,
    );
  }
}

class AcpSessionMode {
  const AcpSessionMode({required this.id, required this.name});

  final String id;
  final String name;

  String get label => name.isEmpty ? id : name;
}

class AcpConfigOption {
  const AcpConfigOption({
    required this.id,
    required this.name,
    required this.type,
    required this.currentValue,
    required this.options,
    this.description,
    this.category,
    this.group,
  });

  final String id;
  final String name;
  final String type;
  final String currentValue;
  final List<AcpConfigOptionChoice> options;
  final String? description;
  final String? category;
  final String? group;

  AcpConfigOption copyWith({Object? currentValue}) {
    return AcpConfigOption(
      id: id,
      name: name,
      type: type,
      currentValue: _stringConfigValue(currentValue) ?? this.currentValue,
      options: options,
      description: description,
      category: category,
      group: group,
    );
  }

  bool get isBooleanOption => type.trim().toLowerCase() == 'boolean';

  bool get currentBoolValue => currentValue.trim().toLowerCase() == 'true';

  bool get isModelOption {
    if (options.isEmpty) return false;
    final tokens = <String>[id, name, category ?? '', group ?? '']
        .map((value) => value.trim().toLowerCase())
        .where((value) {
          return value.isNotEmpty;
        });

    for (final token in tokens) {
      if (token == 'model' ||
          token == '模型' ||
          token.endsWith('_model') ||
          token.endsWith('-model') ||
          token.contains('model id') ||
          token.contains('model_id') ||
          token.contains('model-id') ||
          token.contains('model name') ||
          token.contains('模型')) {
        return true;
      }
    }
    return false;
  }

  bool get isReasoningEffortOption {
    if (options.isEmpty) return false;
    final tokens = <String>[id, name, category ?? '', group ?? '']
        .map((value) => value.trim().toLowerCase())
        .where((value) {
          return value.isNotEmpty;
        });

    for (final token in tokens) {
      if (token == 'reasoning_effort' ||
          token == 'model_reasoning_effort' ||
          token == 'reasoning effort' ||
          token == 'reasoning-effort' ||
          token == 'thought_level' ||
          token == 'thought level' ||
          token == 'thought-level' ||
          token == 'thinking' ||
          token == 'thinking level' ||
          token == 'thinking-level' ||
          token == '思考等级' ||
          token.contains('reasoning effort') ||
          token.contains('reasoning_effort') ||
          token.contains('reasoning-effort') ||
          token.contains('thought level') ||
          token.contains('thought_level') ||
          token.contains('thought-level') ||
          token.contains('思考等级')) {
        return true;
      }
    }
    return false;
  }

  bool get isFastOption {
    final tokens = <String>[id, name, category ?? '', group ?? '']
        .map((value) => value.trim().toLowerCase())
        .where((value) => value.isNotEmpty);

    for (final token in tokens) {
      if (token == 'fast' ||
          token == 'speed' ||
          token == 'fast_mode' ||
          token == 'fast-mode' ||
          token == 'fast mode' ||
          token == '速度' ||
          token == '快速' ||
          token.contains('fast mode') ||
          token.contains('fast_mode') ||
          token.contains('fast-mode') ||
          token.contains('speed') ||
          token.contains('速度')) {
        return true;
      }
    }
    return false;
  }

  bool get isFastEnabled {
    if (!isFastOption) return false;
    if (isBooleanOption) return currentBoolValue;
    final rawValue = currentValue.trim().toLowerCase();
    final label = currentChoiceLabel.trim().toLowerCase();
    return rawValue == 'on' ||
        rawValue == 'enabled' ||
        rawValue == 'true' ||
        rawValue == '1' ||
        label == 'on' ||
        label == 'enabled' ||
        label.contains('fast') ||
        label.contains('quick') ||
        label.contains('turbo') ||
        label.contains('快速');
  }

  String get currentChoiceLabel {
    if (isBooleanOption) return currentBoolValue ? 'On' : 'Off';
    for (final choice in options) {
      if (choice.value == currentValue) return choice.label;
    }
    return currentValue;
  }
}

class AcpConfigOptionChoice {
  const AcpConfigOptionChoice({
    required this.value,
    required this.name,
    this.description,
    this.groupId,
    this.groupName,
  });

  final String value;
  final String name;
  final String? description;
  final String? groupId;
  final String? groupName;

  String get label => name.isEmpty ? value : name;
}

String? _stringConfigValue(Object? value) {
  if (value == null) return null;
  if (value is String) return value;
  if (value is bool) return value.toString();
  return null;
}
