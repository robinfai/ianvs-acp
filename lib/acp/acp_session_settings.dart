class AcpSessionSettings {
  const AcpSessionSettings({
    this.modes = const AcpSessionModeInfo(),
    this.configOptions = const <AcpConfigOption>[],
  });

  final AcpSessionModeInfo modes;
  final List<AcpConfigOption> configOptions;

  bool get hasModes => modes.availableModes.isNotEmpty;

  bool get hasConfigOptions => configOptions.isNotEmpty;

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
    this.group,
  });

  final String id;
  final String name;
  final String type;
  final String currentValue;
  final List<AcpConfigOptionChoice> options;
  final String? description;
  final String? group;

  AcpConfigOption copyWith({String? currentValue}) {
    return AcpConfigOption(
      id: id,
      name: name,
      type: type,
      currentValue: currentValue ?? this.currentValue,
      options: options,
      description: description,
      group: group,
    );
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
