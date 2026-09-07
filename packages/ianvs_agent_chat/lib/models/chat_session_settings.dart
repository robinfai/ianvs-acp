import 'chat_input_budget.dart' as acp;

class ChatSessionSettings {
  const ChatSessionSettings({
    this.modes = const ChatSessionModeInfo(),
    this.configOptions = const <ChatConfigOption>[],
    this.omissions = const <acp.ChatInputOmission>[],
    this.truncated = false,
  });

  final ChatSessionModeInfo modes;
  final List<ChatConfigOption> configOptions;
  final List<acp.ChatInputOmission> omissions;
  final bool truncated;

  bool get hasModes => modes.availableModes.isNotEmpty;

  bool get hasConfigOptions => configOptions.isNotEmpty;

  bool get shouldUseModeFallback => !hasConfigOptions;

  ChatConfigOption? get modelOption {
    for (final option in configOptions) {
      if (option.isModelOption) return option;
    }
    return null;
  }

  ChatConfigOption? get reasoningEffortOption {
    for (final option in configOptions) {
      if (option.isReasoningEffortOption) return option;
    }
    return null;
  }

  List<ChatConfigOption> get nonModelConfigOptions {
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

  ChatSessionSettings copyWith({
    ChatSessionModeInfo? modes,
    List<ChatConfigOption>? configOptions,
    List<acp.ChatInputOmission>? omissions,
    bool? truncated,
  }) {
    return ChatSessionSettings(
      modes: modes ?? this.modes,
      configOptions: configOptions ?? this.configOptions,
      omissions: omissions ?? this.omissions,
      truncated: truncated ?? this.truncated,
    );
  }

  ChatSessionSettings get withConfigOptionsPreference {
    if (configOptions.isEmpty) return this;
    return ChatSessionSettings(
      configOptions: configOptions,
      omissions: omissions,
      truncated: truncated,
    );
  }

  ChatSessionSettings withPreferredConfigOptions(
    List<ChatConfigOption> options,
  ) {
    if (options.isEmpty) return copyWith(configOptions: options);
    return ChatSessionSettings(
      configOptions: options,
      omissions: omissions,
      truncated: truncated,
    );
  }

  ChatSessionSettings withCurrentMode(String modeId) {
    return copyWith(modes: modes.copyWith(currentModeId: modeId));
  }
}

class ChatSessionModeInfo {
  const ChatSessionModeInfo({
    this.currentModeId,
    this.availableModes = const <ChatSessionMode>[],
  });

  final String? currentModeId;
  final List<ChatSessionMode> availableModes;

  ChatSessionModeInfo copyWith({
    String? currentModeId,
    List<ChatSessionMode>? availableModes,
  }) {
    return ChatSessionModeInfo(
      currentModeId: currentModeId ?? this.currentModeId,
      availableModes: availableModes ?? this.availableModes,
    );
  }
}

class ChatSessionMode {
  const ChatSessionMode({required this.id, required this.name});

  final String id;
  final String name;

  String get label => name.isEmpty ? id : name;
}

class ChatConfigOption {
  const ChatConfigOption({
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
  final List<ChatConfigOptionChoice> options;
  final String? description;
  final String? category;
  final String? group;

  ChatConfigOption copyWith({Object? currentValue}) {
    return ChatConfigOption(
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

class ChatConfigOptionChoice {
  const ChatConfigOptionChoice({
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
