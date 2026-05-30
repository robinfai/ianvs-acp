class AcpSessionSettings {
  const AcpSessionSettings({
    this.modes = const AcpSessionModeInfo(),
    this.configOptions = const <AcpConfigOption>[],
  });

  final AcpSessionModeInfo modes;
  final List<AcpConfigOption> configOptions;

  bool get hasModes => modes.availableModes.isNotEmpty;

  bool get hasConfigOptions => configOptions.isNotEmpty;

  bool get shouldUseLegacyModes => !hasConfigOptions;

  AcpConfigOption? get modelOption {
    for (final option in configOptions) {
      if (option.isModelOption) return option;
    }
    return null;
  }

  List<AcpConfigOption> get nonModelConfigOptions {
    return configOptions.where((option) => !option.isModelOption).toList();
  }

  String? get currentModelLabel {
    final option = modelOption;
    if (option == null) return null;
    return option.currentChoiceLabel;
  }

  AcpSessionSettings copyWith({
    AcpSessionModeInfo? modes,
    List<AcpConfigOption>? configOptions,
  }) {
    return AcpSessionSettings(
      modes: modes ?? this.modes,
      configOptions: configOptions ?? this.configOptions,
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
  });

  final String value;
  final String name;
  final String? description;

  String get label => name.isEmpty ? value : name;
}

String? _stringConfigValue(Object? value) {
  if (value == null) return null;
  if (value is String) return value;
  if (value is bool) return value.toString();
  return null;
}
