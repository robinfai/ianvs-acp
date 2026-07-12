// Session extension types for ACP session management.
//
// These types support the session-related RFDs:
// - session/list - Enumerate existing sessions
// - session/resume - Resume without loading history
// - session/fork - Fork an existing session
// - session/set_config_option - Configure session options

import '../input_budget.dart';

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
    this.metaOmission,
  });

  /// Creates from JSON response.
  factory SessionInfo.fromJson(
    Map<String, dynamic> json, {
    AcpInputBudget inputBudget = const AcpInputBudget(),
    AcpStructuredUpdateGuard? structuredGuard,
  }) {
    final guard = _sessionGuard(
      inputBudget,
      structuredGuard,
      resource: 'session_info',
    );
    guard.checkCollection(json, field: 'session info');
    guard.consumeEntry(field: 'session info');
    final sessionId =
        _copyOptionalSessionString(
          json,
          const <String>['sessionId', 'session_id', 'id'],
          guard,
          field: 'session id',
        ) ??
        '';
    final cwd =
        _copyOptionalSessionString(
          json,
          const <String>[
            'cwd',
            'workspaceRoot',
            'workspace_root',
            'workspace',
            'path',
          ],
          guard,
          field: 'cwd',
        ) ??
        '';
    final rawDirectories = _firstSessionValue(json, const <String>[
      'additionalDirectories',
      'additional_directories',
    ]);
    final directories = identical(rawDirectories, _absentSessionField)
        ? const <String>[]
        : _boundedAdditionalDirectories(rawDirectories, inputBudget, guard);
    final title = _copyOptionalSessionString(
      json,
      const <String>['title', 'name', 'label'],
      guard,
      field: 'title',
    );
    final rawUpdatedAt = _firstSessionValue(json, const <String>[
      'updatedAt',
      'updated_at',
    ]);
    DateTime? updatedAt;
    if (!identical(rawUpdatedAt, _absentSessionField)) {
      updatedAt = DateTime.tryParse(
        guard.copyString(rawUpdatedAt, field: 'updated at'),
      );
    }
    final rawMeta = _firstSessionValue(json, const <String>[
      '_meta',
      'metadata',
      'meta',
    ]);
    Map<String, dynamic>? meta;
    AcpInputOmission? metaOmission;
    if (!identical(rawMeta, _absentSessionField)) {
      try {
        meta = Map<String, dynamic>.unmodifiable(
          guard.copyMetadata(rawMeta, field: 'session metadata'),
        );
      } on AcpInputLimitExceeded catch (error) {
        meta = const <String, dynamic>{};
        metaOmission = _sessionLimitOmission('session_meta', error);
      } catch (_) {
        meta = const <String, dynamic>{};
        metaOmission = _sessionInvalidOmission('session_meta');
      }
    }
    return SessionInfo(
      sessionId: sessionId,
      cwd: cwd,
      additionalDirectories: directories,
      title: title,
      updatedAt: updatedAt,
      meta: meta,
      metaOmission: metaOmission,
    );
  }

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

  /// Host-owned reason why display metadata was dropped.
  final AcpInputOmission? metaOmission;

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
  factory SessionListResult.fromJson(
    Map<String, dynamic> json, {
    AcpInputBudget inputBudget = const AcpInputBudget(),
    AcpStructuredUpdateGuard? structuredGuard,
  }) {
    final guard = _sessionGuard(
      inputBudget,
      structuredGuard,
      resource: 'session_list_result',
    );
    guard.checkCollection(json, field: 'session list result');
    guard.consumeEntry(field: 'session list result');
    final rawSessions = _firstSessionValue(json, const <String>[
      'sessions',
      'items',
      'entries',
    ]);
    final sessionsList = identical(rawSessions, _absentSessionField)
        ? const <SessionInfo>[]
        : _boundedSessionInfos(rawSessions, inputBudget, guard);
    return SessionListResult(
      sessions: sessionsList,
      nextCursor: _copyOptionalSessionString(
        json,
        const <String>['nextCursor', 'next_cursor', 'cursor'],
        guard,
        field: 'next cursor',
      ),
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
    this.group,
  });

  /// Creates from JSON response.
  factory ConfigOption.fromJson(
    Map<String, dynamic> json, {
    AcpInputBudget inputBudget = const AcpInputBudget(),
    AcpStructuredUpdateGuard? structuredGuard,
  }) {
    final guard = _sessionGuard(
      inputBudget,
      structuredGuard,
      resource: 'config_option',
    );
    return _boundedConfigOption(json, inputBudget, guard);
  }

  factory ConfigOption._fromBounded(
    Map source,
    AcpInputBudget inputBudget,
    AcpStructuredUpdateGuard guard,
  ) {
    final id =
        _copyOptionalSessionString(
          source,
          const <String>['id', 'configId', 'config_id', 'key'],
          guard,
          field: 'config id',
        ) ??
        '';
    final rawOptions = _firstSessionValue(source, const <String>[
      'options',
      'choices',
      'values',
    ]);
    final options = identical(rawOptions, _absentSessionField)
        ? const <ConfigOptionChoice>[]
        : _boundedConfigChoices(rawOptions, inputBudget, guard);
    return ConfigOption(
      id: id,
      name:
          _copyOptionalSessionString(
            source,
            const <String>['name', 'label', 'title'],
            guard,
            field: 'config name',
          ) ??
          id,
      type: _boundedConfigType(
        _firstSessionValue(source, const <String>['type']),
        guard,
      ),
      currentValue: _boundedConfigValue(
        _firstSessionValue(source, const <String>[
          'currentValue',
          'current_value',
          'value',
          'selectedValue',
          'selected',
        ]),
        guard,
        field: 'config current value',
      ),
      options: options,
      description: _copyOptionalSessionString(
        source,
        const <String>['description'],
        guard,
        field: 'config description',
      ),
      group: _copyOptionalSessionString(
        source,
        const <String>['group', 'category'],
        guard,
        field: 'config group',
      ),
    );
  }

  /// Unique identifier for this option.
  final String id;

  /// Human-readable name.
  final String name;

  /// Option type (currently "select").
  final String type;

  /// Currently selected value.
  final String currentValue;

  /// Available choices.
  final List<ConfigOptionChoice> options;

  /// Optional description.
  final String? description;

  /// Optional group for organization.
  final String? group;

  /// Convert to JSON.
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'type': type,
    'currentValue': currentValue,
    'options': options.map((o) => o.toJson()).toList(),
    if (description != null) 'description': description,
    if (group != null) 'group': group,
  };

  @override
  String toString() => 'ConfigOption($id: $currentValue)';
}

/// A choice within a config option.
class ConfigOptionChoice {
  /// Creates a config option choice.
  const ConfigOptionChoice({
    required this.value,
    required this.name,
    this.description,
  });

  /// Creates from JSON.
  factory ConfigOptionChoice.fromJson(
    Map<String, dynamic> json, {
    AcpInputBudget inputBudget = const AcpInputBudget(),
    AcpStructuredUpdateGuard? structuredGuard,
  }) {
    final guard = _sessionGuard(
      inputBudget,
      structuredGuard,
      resource: 'config_option_choice',
    );
    return _boundedConfigChoice(json, guard);
  }

  /// The value to send when selecting this option.
  final String value;

  /// Human-readable name.
  final String name;

  /// Optional description.
  final String? description;

  /// Convert to JSON.
  Map<String, dynamic> toJson() => {
    'value': value,
    'name': name,
    if (description != null) 'description': description,
  };

  @override
  String toString() => 'ConfigOptionChoice($value: $name)';
}

/// Result of session/new, session/load, session/resume, or session/fork.
class SessionResult {
  /// Creates a session result.
  const SessionResult({
    required this.sessionId,
    this.configOptions,
    this.meta,
    this.modes,
    this.omissions = const <AcpInputOmission>[],
  });

  /// Creates from JSON response.
  factory SessionResult.fromJson(
    Map<String, dynamic> json, {
    AcpInputBudget inputBudget = const AcpInputBudget(),
    AcpStructuredUpdateGuard? structuredGuard,
  }) {
    final guard = _sessionGuard(
      inputBudget,
      structuredGuard,
      resource: 'session_result',
    );
    guard.checkCollection(json, field: 'session result');
    guard.consumeEntry(field: 'session result');
    final sessionId =
        _copyOptionalSessionString(
          json,
          const <String>['sessionId', 'session_id', 'id'],
          guard,
          field: 'session id',
        ) ??
        '';
    final omissions = <AcpInputOmission>[];
    final configRaw = _firstSessionValue(json, const <String>[
      'configOptions',
      'config_options',
    ]);
    List<ConfigOption>? configOptions;
    if (!identical(configRaw, _absentSessionField)) {
      try {
        configOptions = _boundedConfigOptions(configRaw, inputBudget, guard);
      } on AcpInputLimitExceeded catch (error) {
        configOptions = const <ConfigOption>[];
        omissions.add(_sessionLimitOmission('config_options', error));
      } catch (_) {
        configOptions = const <ConfigOption>[];
        omissions.add(_sessionInvalidOmission('config_options'));
      }
    }
    final rawMeta = _firstSessionValue(json, const <String>[
      '_meta',
      'metadata',
      'meta',
    ]);
    Map<String, dynamic>? meta;
    if (!identical(rawMeta, _absentSessionField)) {
      try {
        meta = Map<String, dynamic>.unmodifiable(
          guard.copyMetadata(rawMeta, field: 'session result metadata'),
        );
      } on AcpInputLimitExceeded catch (error) {
        meta = const <String, dynamic>{};
        omissions.add(_sessionLimitOmission('session_result_meta', error));
      } catch (_) {
        meta = const <String, dynamic>{};
        omissions.add(_sessionInvalidOmission('session_result_meta'));
      }
    }
    ({String? currentModeId, List<({String id, String name})> availableModes})?
    modes;
    try {
      modes = _boundedSessionModes(json, inputBudget, guard);
    } on AcpInputLimitExceeded catch (error) {
      omissions.add(_sessionLimitOmission('session_modes', error));
    } catch (_) {
      omissions.add(_sessionInvalidOmission('session_modes'));
    }
    return SessionResult(
      sessionId: sessionId,
      configOptions: configOptions,
      meta: meta,
      modes: modes,
      omissions: List<AcpInputOmission>.unmodifiable(omissions),
    );
  }

  /// The session ID.
  final String sessionId;

  /// Available configuration options (optional).
  final List<ConfigOption>? configOptions;

  /// Agent-specific metadata (optional).
  final Map<String, dynamic>? meta;

  /// Immediate, immutable session mode projection.
  final ({
    String? currentModeId,
    List<({String id, String name})> availableModes,
  })?
  modes;

  /// Host-owned omissions for rejected immediate fields.
  final List<AcpInputOmission> omissions;

  @override
  String toString() => 'SessionResult($sessionId)';
}

/// Session capabilities advertised by an agent.
class SessionCapabilities {
  /// Creates session capabilities.
  const SessionCapabilities({
    this.list = false,
    this.resume = false,
    this.fork = false,
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
        resume: _capabilityAdvertised(sessionCaps['resume']),
        fork: _capabilityAdvertised(sessionCaps['fork']),
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
        resume: _capabilityAdvertised(session['resume']),
        fork: _capabilityAdvertised(session['fork']),
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

  /// Agent supports session/resume.
  final bool resume;

  /// Agent supports session/fork.
  final bool fork;

  /// Agent supports configOptions in session responses.
  final bool configOptions;

  /// Agent supports additionalDirectories in session setup requests.
  final bool additionalDirectories;

  @override
  String toString() =>
      'SessionCapabilities(list: $list, resume: $resume, fork: $fork, '
      'configOptions: $configOptions, '
      'additionalDirectories: $additionalDirectories)';
}

bool _capabilityAdvertised(Object? value) => value == true || value is Map;

const Object _absentSessionField = Object();

AcpStructuredUpdateGuard _sessionGuard(
  AcpInputBudget inputBudget,
  AcpStructuredUpdateGuard? structuredGuard, {
  required String resource,
}) =>
    structuredGuard ??
    AcpStructuredUpdateGuard(budget: inputBudget, resource: resource);

Object? _firstSessionValue(Map source, List<String> fields) {
  for (final field in fields) {
    try {
      if (!source.containsKey(field)) continue;
      final value = source[field];
      if (value != null) return value;
    } catch (_) {
      throw const FormatException('Invalid ACP session structure.');
    }
  }
  return _absentSessionField;
}

String? _copyOptionalSessionString(
  Map source,
  List<String> fields,
  AcpStructuredUpdateGuard guard, {
  required String field,
}) {
  final value = _firstSessionValue(source, fields);
  if (identical(value, _absentSessionField)) return null;
  return guard.copyString(value, field: field);
}

List<String> _boundedAdditionalDirectories(
  Object? raw,
  AcpInputBudget inputBudget,
  AcpStructuredUpdateGuard guard,
) {
  if (raw is! List) {
    throw const FormatException('Invalid ACP additional directories.');
  }
  final reportedLength = guard.checkCollection(
    raw,
    field: 'additional directories',
  );
  guard.consumeContainerNode(field: 'additional directories');
  final directories = <String>[];
  final seen = <String>{};
  _forEachReportedListItem(
    raw,
    reportedLength: reportedLength,
    maxItems: inputBudget.maxCollectionItems,
    resource: 'additional directories',
    visit: (item) {
      if (item is! String) {
        throw const FormatException('Invalid ACP additional directory.');
      }
      final trimmed = guard
          .copyString(item, field: 'additional directory')
          .trim();
      if (trimmed.isNotEmpty && seen.add(trimmed)) directories.add(trimmed);
    },
  );
  return List<String>.unmodifiable(directories);
}

List<SessionInfo> _boundedSessionInfos(
  Object? raw,
  AcpInputBudget inputBudget,
  AcpStructuredUpdateGuard guard,
) {
  if (raw is! List) {
    throw const FormatException('Invalid ACP session list.');
  }
  final reportedLength = guard.checkCollection(raw, field: 'sessions');
  guard.consumeContainerNode(field: 'sessions');
  final sessions = <SessionInfo>[];
  _forEachReportedListItem(
    raw,
    reportedLength: reportedLength,
    maxItems: inputBudget.maxCollectionItems,
    resource: 'sessions',
    visit: (item) {
      if (item is! Map) return;
      if (item is! Map<String, dynamic>) {
        throw const FormatException('Invalid ACP session map.');
      }
      final session = SessionInfo.fromJson(
        item,
        inputBudget: inputBudget,
        structuredGuard: guard,
      );
      if (session.sessionId.isNotEmpty) sessions.add(session);
    },
  );
  return List<SessionInfo>.unmodifiable(sessions);
}

ConfigOption _boundedConfigOption(
  Map source,
  AcpInputBudget inputBudget,
  AcpStructuredUpdateGuard guard,
) {
  guard.checkCollection(source, field: 'config option');
  guard.consumeEntry(field: 'config option');
  final option = ConfigOption._fromBounded(source, inputBudget, guard);
  if (option.id.isEmpty) {
    throw const FormatException('Invalid ACP config option.');
  }
  return option;
}

List<ConfigOption> _boundedConfigOptions(
  Object? raw,
  AcpInputBudget inputBudget,
  AcpStructuredUpdateGuard guard,
) {
  if (raw is! List) {
    throw const FormatException('Invalid ACP config options.');
  }
  final reportedLength = guard.checkCollection(raw, field: 'config options');
  guard.consumeContainerNode(field: 'config options');
  final options = <ConfigOption>[];
  _forEachReportedListItem(
    raw,
    reportedLength: reportedLength,
    maxItems: inputBudget.maxCollectionItems,
    resource: 'config options',
    visit: (item) {
      if (item is! Map) {
        throw const FormatException('Invalid ACP config option.');
      }
      final option = _boundedConfigOption(item, inputBudget, guard);
      options.add(option);
    },
  );
  return List<ConfigOption>.unmodifiable(options);
}

List<ConfigOptionChoice> _boundedConfigChoices(
  Object? raw,
  AcpInputBudget inputBudget,
  AcpStructuredUpdateGuard guard,
) {
  if (raw is! List) {
    throw const FormatException('Invalid ACP config choices.');
  }
  final reportedLength = guard.checkCollection(raw, field: 'config choices');
  guard.consumeContainerNode(field: 'config choices');
  final choices = <ConfigOptionChoice>[];
  _forEachReportedListItem(
    raw,
    reportedLength: reportedLength,
    maxItems: inputBudget.maxCollectionItems,
    resource: 'config choices',
    visit: (item) {
      choices.add(_boundedConfigChoice(item, guard));
    },
  );
  return List<ConfigOptionChoice>.unmodifiable(choices);
}

ConfigOptionChoice _boundedConfigChoice(
  Object? item,
  AcpStructuredUpdateGuard guard,
) {
  if (item is String || item is bool || item is int || item is double) {
    guard.consumeEntry(field: 'config choice');
    final value = _boundedConfigValue(
      item,
      guard,
      field: 'config choice value',
    );
    if (value.isEmpty) {
      throw const FormatException('Invalid ACP config choice.');
    }
    return ConfigOptionChoice(value: value, name: value);
  }
  if (item is! Map) {
    throw const FormatException('Invalid ACP config choice.');
  }
  guard.checkCollection(item, field: 'config choice');
  guard.consumeEntry(field: 'config choice');
  final rawValue = _firstSessionValue(item, const <String>[
    'value',
    'id',
    'key',
    'name',
  ]);
  final value = _boundedConfigValue(
    rawValue,
    guard,
    field: 'config choice value',
  );
  if (value.isEmpty) {
    throw const FormatException('Invalid ACP config choice.');
  }
  final name =
      _copyOptionalSessionString(
        item,
        const <String>['name', 'label', 'displayName'],
        guard,
        field: 'config choice name',
      ) ??
      value;
  final description = _copyOptionalSessionString(
    item,
    const <String>['description'],
    guard,
    field: 'config choice description',
  );
  return ConfigOptionChoice(value: value, name: name, description: description);
}

String _boundedConfigType(Object? raw, AcpStructuredUpdateGuard guard) {
  if (identical(raw, _absentSessionField)) return 'select';
  final type = guard.copyString(raw, field: 'config type').trim().toLowerCase();
  return type.isEmpty ? 'select' : type;
}

String _boundedConfigValue(
  Object? raw,
  AcpStructuredUpdateGuard guard, {
  required String field,
}) {
  if (identical(raw, _absentSessionField)) return '';
  if (raw is String) return guard.copyString(raw, field: field);
  if (raw is int || raw is double || raw is bool) {
    return guard.copyScalar(raw, field: field).toString();
  }
  throw const FormatException('Invalid ACP config value.');
}

({String? currentModeId, List<({String id, String name})> availableModes})?
_boundedSessionModes(
  Map<String, dynamic> json,
  AcpInputBudget inputBudget,
  AcpStructuredUpdateGuard guard,
) {
  final rawCurrent = _firstSessionValue(json, const <String>[
    'currentModeId',
    'current_mode_id',
    'modeId',
    'mode_id',
  ]);
  final rawModes = _firstSessionValue(json, const <String>[
    'availableModes',
    'available_modes',
  ]);
  if (identical(rawCurrent, _absentSessionField) &&
      identical(rawModes, _absentSessionField)) {
    return null;
  }
  final currentModeId = identical(rawCurrent, _absentSessionField)
      ? null
      : guard.copyString(rawCurrent, field: 'current mode id');
  if (identical(rawModes, _absentSessionField)) {
    return (
      currentModeId: currentModeId,
      availableModes: const <({String id, String name})>[],
    );
  }
  if (rawModes is! List) {
    throw const FormatException('Invalid ACP session modes.');
  }
  final reportedLength = guard.checkCollection(
    rawModes,
    field: 'available modes',
  );
  guard.consumeContainerNode(field: 'available modes');
  final modes = <({String id, String name})>[];
  _forEachReportedListItem(
    rawModes,
    reportedLength: reportedLength,
    maxItems: inputBudget.maxCollectionItems,
    resource: 'available modes',
    visit: (item) {
      if (item is! Map) {
        throw const FormatException('Invalid ACP session mode.');
      }
      guard.checkCollection(item, field: 'available mode');
      guard.consumeEntry(field: 'available mode');
      final id =
          _copyOptionalSessionString(
            item,
            const <String>['id', 'modeId', 'mode_id', 'value'],
            guard,
            field: 'mode id',
          ) ??
          '';
      if (id.isEmpty) {
        throw const FormatException('Invalid ACP session mode.');
      }
      final name =
          _copyOptionalSessionString(
            item,
            const <String>['name', 'label', 'displayName', 'display_name'],
            guard,
            field: 'mode name',
          ) ??
          id;
      modes.add((id: id, name: name));
    },
  );
  return (
    currentModeId: currentModeId,
    availableModes: List<({String id, String name})>.unmodifiable(modes),
  );
}

void _forEachReportedListItem(
  List raw, {
  required int reportedLength,
  required int maxItems,
  required String resource,
  required void Function(Object? item) visit,
}) {
  final Iterator<Object?> iterator;
  try {
    iterator = raw.iterator;
  } catch (_) {
    throw FormatException('Invalid ACP $resource collection.');
  }
  var observedItems = 0;
  while (true) {
    final bool hasNext;
    try {
      hasNext = iterator.moveNext();
    } catch (_) {
      throw FormatException('Invalid ACP $resource collection.');
    }
    if (!hasNext) break;
    observedItems += 1;
    if (observedItems > maxItems) {
      throw AcpInputLimitExceeded(
        resource: resource,
        limit: maxItems,
        observedAtLeast: observedItems,
      );
    }
    if (observedItems > reportedLength) {
      throw FormatException('Invalid ACP $resource collection.');
    }
    final Object? item;
    try {
      item = iterator.current;
    } catch (_) {
      throw FormatException('Invalid ACP $resource collection.');
    }
    visit(item);
  }
  if (observedItems != reportedLength) {
    throw FormatException('Invalid ACP $resource collection.');
  }
}

AcpInputOmission _sessionLimitOmission(
  String resource,
  AcpInputLimitExceeded error,
) => AcpInputOmission(
  reason: AcpInputOmissionReason.inputLimit,
  resource: resource,
  truncated: false,
  limit: error.limit,
  observedAtLeast: error.observedAtLeast,
);

AcpInputOmission _sessionInvalidOmission(String resource) => AcpInputOmission(
  reason: AcpInputOmissionReason.invalidStructure,
  resource: resource,
  truncated: false,
);
