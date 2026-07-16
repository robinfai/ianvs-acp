// Session extension types for ACP session management.
//
// These types support the session-related RFDs:
// - session/list - Enumerate existing sessions
// - session/resume - Resume without loading history
// - session/fork - Fork an existing session
// - session/set_config_option - Configure session options

/// Information about a session returned by session/list.
class SessionInfo {
  /// Creates a session info.
  const SessionInfo({
    required this.sessionId,
    required this.cwd,
    this.additionalDirectories = const <String>[],
    this.title,
    this.updatedAt,
    this.meta,
  });

  /// Creates from JSON response.
  factory SessionInfo.fromJson(Map<String, dynamic> json) => SessionInfo(
    sessionId:
        _optionalString(json['sessionId']) ??
        _optionalString(json['session_id']) ??
        _optionalString(json['id']) ??
        '',
    cwd:
        _optionalString(json['cwd']) ??
        _optionalString(json['workspaceRoot']) ??
        _optionalString(json['workspace_root']) ??
        _optionalString(json['workspace']) ??
        _optionalString(json['path']) ??
        '',
    additionalDirectories: _additionalDirectoriesFromRaw(
      json['additionalDirectories'] ?? json['additional_directories'],
    ),
    title:
        _optionalString(json['title']) ??
        _optionalString(json['name']) ??
        _optionalString(json['label']),
    updatedAt: _dateTimeFromRaw(json['updatedAt'] ?? json['updated_at']),
    meta: _optionalMap(json['_meta'] ?? json['metadata'] ?? json['meta']),
  );

  /// Unique session identifier.
  final String sessionId;

  /// Working directory for this session.
  final String cwd;

  /// Additional workspace roots for this session.
  final List<String> additionalDirectories;

  /// Human-readable title (optional).
  final String? title;

  /// Last updated timestamp (optional).
  final DateTime? updatedAt;

  /// Agent-specific metadata (optional).
  final Map<String, dynamic>? meta;

  /// Convert to JSON.
  Map<String, dynamic> toJson() => {
    'sessionId': sessionId,
    'cwd': cwd,
    if (additionalDirectories.isNotEmpty)
      'additionalDirectories': additionalDirectories,
    if (title != null) 'title': title,
    if (updatedAt != null) 'updatedAt': updatedAt!.toIso8601String(),
    if (meta != null) '_meta': meta,
  };

  @override
  String toString() => 'SessionInfo($sessionId, cwd: $cwd, title: $title)';
}

/// Result of session/list request.
class SessionListResult {
  /// Creates a session list result.
  const SessionListResult({required this.sessions, this.nextCursor});

  /// Creates from JSON response.
  factory SessionListResult.fromJson(Map<String, dynamic> json) {
    final sessionsList = _listFromRaw(
      json['sessions'] ?? json['items'] ?? json['entries'],
    );
    return SessionListResult(
      sessions: sessionsList
          .map(_sessionInfoFromRaw)
          .whereType<SessionInfo>()
          .toList(),
      nextCursor:
          _optionalString(json['nextCursor']) ??
          _optionalString(json['next_cursor']) ??
          _optionalString(json['cursor']),
    );
  }

  /// List of sessions.
  final List<SessionInfo> sessions;

  /// Opaque cursor for pagination (null if no more pages).
  final String? nextCursor;

  /// Whether there are more sessions to fetch.
  bool get hasMore => nextCursor != null;

  @override
  String toString() =>
      'SessionListResult(${sessions.length} sessions, hasMore: $hasMore)';
}

/// A configuration option available for a session.
class ConfigOption {
  /// Creates a config option.
  const ConfigOption({
    required this.id,
    required this.name,
    required this.type,
    required this.currentValue,
    required this.options,
    this.description,
    this.category,
    this.group,
    this.meta,
  });

  /// Creates from JSON response.
  factory ConfigOption.fromJson(Map<String, dynamic> json) {
    final id =
        _optionalString(json['id']) ??
        _optionalString(json['configId']) ??
        _optionalString(json['config_id']) ??
        _optionalString(json['key']) ??
        '';
    final options = _configChoicesFromRaw(
      json['options'] ?? json['choices'] ?? json['values'],
    );
    return ConfigOption(
      id: id,
      name:
          _optionalString(json['name']) ??
          _optionalString(json['label']) ??
          _optionalString(json['title']) ??
          id,
      type: _configTypeFromRaw(json['type']),
      currentValue: _configValueFromJson(
        json['currentValue'] ??
            json['current_value'] ??
            json['value'] ??
            json['selectedValue'] ??
            json['selected'],
      ),
      options: options,
      description: _optionalString(json['description']),
      category: _optionalString(json['category']),
      group: _optionalString(json['group']),
      meta: _optionalMap(json['_meta']),
    );
  }

  /// Unique identifier for this option.
  final String id;

  /// Human-readable name.
  final String name;

  /// Option type (currently "select").
  final String type;

  /// Currently selected value.
  final Object currentValue;

  /// Available choices.
  final List<ConfigOptionChoice> options;

  /// Optional description.
  final String? description;

  /// Semantic ACP category such as `model` or `thought_level`.
  final String? category;

  /// Optional group for organization.
  final String? group;

  /// ACP extension metadata.
  final Map<String, dynamic>? meta;

  /// Convert to JSON.
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'type': type,
    'currentValue': currentValue,
    if (type != 'boolean') 'options': _configChoicesToJson(options),
    if (description != null) 'description': description,
    if (category != null) 'category': category,
    if (group != null) 'group': group,
    if (meta != null) '_meta': meta,
  };

  @override
  String toString() => 'ConfigOption($id: $currentValue)';
}

Object _configValueFromJson(Object? value) {
  if (value is String) return value;
  if (value is bool) return value;
  if (value is num) return value.toString();
  return '';
}

String _configChoiceValueFromJson(Object? value) {
  final normalized = _configValueFromJson(value);
  return normalized is String ? normalized : normalized.toString();
}

/// A choice within a config option.
class ConfigOptionChoice {
  /// Creates a config option choice.
  const ConfigOptionChoice({
    required this.value,
    required this.name,
    this.description,
    this.groupId,
    this.groupName,
    this.groupMeta,
    this.meta,
  });

  /// Creates from JSON.
  factory ConfigOptionChoice.fromJson(Map<String, dynamic> json) {
    final value = _configChoiceValueFromJson(
      json['value'] ?? json['id'] ?? json['key'] ?? json['name'],
    );
    return ConfigOptionChoice(
      value: value,
      name:
          _optionalString(json['name']) ??
          _optionalString(json['label']) ??
          _optionalString(json['displayName']) ??
          value,
      description: _optionalString(json['description']),
      meta: _optionalMap(json['_meta']),
    );
  }

  /// The value to send when selecting this option.
  final String value;

  /// Human-readable name.
  final String name;

  /// Optional description.
  final String? description;

  /// Group identifier when this choice was nested in a grouped select option.
  final String? groupId;

  /// Human-readable group name.
  final String? groupName;

  /// ACP extension metadata from the containing select group.
  final Map<String, dynamic>? groupMeta;

  /// ACP extension metadata.
  final Map<String, dynamic>? meta;

  /// Convert to JSON.
  Map<String, dynamic> toJson() => {
    'value': value,
    'name': name,
    if (description != null) 'description': description,
    if (meta != null) '_meta': meta,
  };

  @override
  String toString() => 'ConfigOptionChoice($value: $name)';
}

/// Result of session/new, session/load, session/resume, or session/fork.
class SessionResult {
  /// Creates a session result.
  const SessionResult({required this.sessionId, this.configOptions, this.meta});

  /// Creates from JSON response.
  factory SessionResult.fromJson(Map<String, dynamic> json) {
    final configRaw = json['configOptions'] ?? json['config_options'];
    return SessionResult(
      sessionId:
          _optionalString(json['sessionId']) ??
          _optionalString(json['session_id']) ??
          _optionalString(json['id']) ??
          '',
      configOptions: configRaw == null
          ? null
          : _configOptionsFromRaw(configRaw),
      meta: _optionalMap(json['_meta'] ?? json['metadata'] ?? json['meta']),
    );
  }

  /// The session ID.
  final String sessionId;

  /// Available configuration options (optional).
  final List<ConfigOption>? configOptions;

  /// Agent-specific metadata (optional).
  final Map<String, dynamic>? meta;

  @override
  String toString() => 'SessionResult($sessionId)';
}

/// Session capabilities advertised by an agent.
class SessionCapabilities {
  /// Creates session capabilities.
  const SessionCapabilities({
    this.list = false,
    this.delete = false,
    this.resume = false,
    this.fork = false,
    this.close = false,
    this.configOptions = false,
    this.additionalDirectories = false,
  });

  /// Creates from the agentCapabilities map.
  factory SessionCapabilities.fromJson(Map<String, dynamic>? agentCaps) {
    if (agentCaps == null) return const SessionCapabilities();

    // Check for sessionCapabilities object (newer format)
    final sessionCaps = agentCaps['sessionCapabilities'];
    if (sessionCaps is Map<String, dynamic>) {
      return SessionCapabilities(
        list: _capabilityAdvertised(sessionCaps['list']),
        delete: _capabilityAdvertised(sessionCaps['delete']),
        resume: _capabilityAdvertised(sessionCaps['resume']),
        fork: _capabilityAdvertised(sessionCaps['fork']),
        close: _capabilityAdvertised(sessionCaps['close']),
        configOptions: _capabilityAdvertised(sessionCaps['configOptions']),
        additionalDirectories:
            _capabilityAdvertised(sessionCaps['additionalDirectories']) ||
            _capabilityAdvertised(sessionCaps['additional_directories']),
      );
    }

    // Fallback to checking session object (alternative format)
    final session = agentCaps['session'];
    if (session is Map<String, dynamic>) {
      return SessionCapabilities(
        list: _capabilityAdvertised(session['list']),
        delete: _capabilityAdvertised(session['delete']),
        resume: _capabilityAdvertised(session['resume']),
        fork: _capabilityAdvertised(session['fork']),
        close: _capabilityAdvertised(session['close']),
        configOptions: _capabilityAdvertised(session['configOptions']),
        additionalDirectories:
            _capabilityAdvertised(session['additionalDirectories']) ||
            _capabilityAdvertised(session['additional_directories']),
      );
    }

    return const SessionCapabilities();
  }

  /// Agent supports session/list.
  final bool list;

  /// Agent supports session/delete.
  final bool delete;

  /// Agent supports session/resume.
  final bool resume;

  /// Agent supports session/fork.
  final bool fork;

  /// Agent supports session/close.
  final bool close;

  /// Agent supports configOptions in session responses.
  final bool configOptions;

  /// Agent supports additionalDirectories in session setup requests.
  final bool additionalDirectories;

  @override
  String toString() =>
      'SessionCapabilities(list: $list, delete: $delete, resume: $resume, '
      'fork: $fork, close: $close, '
      'configOptions: $configOptions, '
      'additionalDirectories: $additionalDirectories)';
}

bool _capabilityAdvertised(Object? value) => value == true || value is Map;

String? _optionalString(Object? value) => value is String ? value : null;

Map<String, dynamic>? _optionalMap(Object? value) {
  if (value is! Map) return null;
  return value.map((key, value) => MapEntry(key.toString(), value));
}

List<dynamic> _listFromRaw(Object? raw) => raw is List ? raw : const [];

List<String> _additionalDirectoriesFromRaw(Object? raw) {
  if (raw is! List) return const <String>[];
  final directories = <String>[];
  final seen = <String>{};
  for (final item in raw) {
    if (item is! String) continue;
    final trimmed = item.trim();
    if (trimmed.isEmpty || !seen.add(trimmed)) continue;
    directories.add(trimmed);
  }
  return List.unmodifiable(directories);
}

String _configTypeFromRaw(Object? raw) {
  final type = _optionalString(raw)?.trim().toLowerCase();
  return type == null || type.isEmpty ? 'select' : type;
}

List<ConfigOption> _configOptionsFromRaw(Object? raw) {
  if (raw is! List) return const <ConfigOption>[];
  return raw
      .map(_configOptionFromRaw)
      .whereType<ConfigOption>()
      .toList(growable: false);
}

ConfigOption? _configOptionFromRaw(Object? raw) {
  final map = _optionalMap(raw);
  if (map == null) return null;
  final option = ConfigOption.fromJson(map);
  return option.id.isEmpty ? null : option;
}

List<ConfigOptionChoice> _configChoicesFromRaw(Object? raw) {
  if (raw is! List) return const <ConfigOptionChoice>[];
  final choices = <ConfigOptionChoice>[];
  for (final item in raw) {
    final map = _optionalMap(item);
    final nested = map?['options'];
    final groupId = _optionalString(map?['group']);
    if (nested is List && groupId != null) {
      final groupName = _optionalString(map?['name']) ?? groupId;
      final groupMeta = _optionalMap(map?['_meta']);
      for (final nestedItem in nested) {
        final choice = _configChoiceFromRaw(nestedItem);
        if (choice == null) continue;
        choices.add(
          ConfigOptionChoice(
            value: choice.value,
            name: choice.name,
            description: choice.description,
            groupId: groupId,
            groupName: groupName,
            groupMeta: groupMeta,
            meta: choice.meta,
          ),
        );
      }
      continue;
    }
    final choice = _configChoiceFromRaw(item);
    if (choice != null) choices.add(choice);
  }
  return List.unmodifiable(choices);
}

List<Map<String, dynamic>> _configChoicesToJson(
  List<ConfigOptionChoice> choices,
) {
  final result = <Map<String, dynamic>>[];
  final grouped = <String, List<ConfigOptionChoice>>{};
  final groupNames = <String, String>{};
  final groupMetas = <String, Map<String, dynamic>>{};
  for (final choice in choices) {
    final groupId = choice.groupId;
    if (groupId == null) {
      result.add(choice.toJson());
      continue;
    }
    grouped.putIfAbsent(groupId, () => <ConfigOptionChoice>[]).add(choice);
    groupNames[groupId] = choice.groupName ?? groupId;
    if (choice.groupMeta != null) groupMetas[groupId] = choice.groupMeta!;
  }
  for (final entry in grouped.entries) {
    result.add({
      'group': entry.key,
      'name': groupNames[entry.key],
      'options': entry.value.map((choice) => choice.toJson()).toList(),
      if (groupMetas[entry.key] != null) '_meta': groupMetas[entry.key],
    });
  }
  return result;
}

ConfigOptionChoice? _configChoiceFromRaw(Object? raw) {
  if (raw is String || raw is bool || raw is num) {
    final value = _configChoiceValueFromJson(raw);
    return value.isEmpty ? null : ConfigOptionChoice(value: value, name: value);
  }
  final map = _optionalMap(raw);
  if (map == null) return null;
  final choice = ConfigOptionChoice.fromJson(map);
  return choice.value.isEmpty ? null : choice;
}

SessionInfo? _sessionInfoFromRaw(Object? raw) {
  final map = _optionalMap(raw);
  if (map == null) return null;
  final session = SessionInfo.fromJson(map);
  return session.sessionId.isEmpty ? null : session;
}

DateTime? _dateTimeFromRaw(Object? raw) {
  final value = _optionalString(raw);
  if (value == null) return null;
  return DateTime.tryParse(value);
}
