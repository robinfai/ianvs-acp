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
    this.title,
    this.updatedAt,
    this.meta,
  });

  /// Creates from JSON response.
  factory SessionInfo.fromJson(Map<String, dynamic> json) => SessionInfo(
    sessionId: json['sessionId'] as String,
    cwd: json['cwd'] as String,
    title: json['title'] as String?,
    updatedAt: json['updatedAt'] != null
        ? DateTime.parse(json['updatedAt'] as String)
        : null,
    meta: json['_meta'] as Map<String, dynamic>?,
  );

  /// Unique session identifier.
  final String sessionId;

  /// Working directory for this session.
  final String cwd;

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
    final sessionsList = json['sessions'] as List<dynamic>? ?? [];
    return SessionListResult(
      sessions: sessionsList
          .map((s) => SessionInfo.fromJson(s as Map<String, dynamic>))
          .toList(),
      nextCursor: json['nextCursor'] as String?,
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
  factory ConfigOption.fromJson(Map<String, dynamic> json) {
    final optionsList = json['options'] as List<dynamic>? ?? [];
    return ConfigOption(
      id: json['id'] as String,
      name: json['name'] as String,
      type: json['type'] as String,
      currentValue: json['currentValue'] as String,
      options: optionsList
          .map((o) => ConfigOptionChoice.fromJson(o as Map<String, dynamic>))
          .toList(),
      description: json['description'] as String?,
      group: json['group'] as String?,
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
  factory ConfigOptionChoice.fromJson(Map<String, dynamic> json) =>
      ConfigOptionChoice(
        value: json['value'] as String,
        name: json['name'] as String,
        description: json['description'] as String?,
      );

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
  const SessionResult({required this.sessionId, this.configOptions, this.meta});

  /// Creates from JSON response.
  factory SessionResult.fromJson(Map<String, dynamic> json) {
    final configList = json['configOptions'] as List<dynamic>?;
    return SessionResult(
      sessionId: json['sessionId'] as String,
      configOptions: configList
          ?.map((c) => ConfigOption.fromJson(c as Map<String, dynamic>))
          .toList(),
      meta: json['_meta'] as Map<String, dynamic>?,
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
    this.resume = false,
    this.fork = false,
    this.configOptions = false,
  });

  /// Creates from the agentCapabilities map.
  factory SessionCapabilities.fromJson(Map<String, dynamic>? agentCaps) {
    if (agentCaps == null) return const SessionCapabilities();

    // Check for sessionCapabilities object (newer format)
    final sessionCaps = agentCaps['sessionCapabilities'];
    if (sessionCaps is Map<String, dynamic>) {
      return SessionCapabilities(
        list: sessionCaps['list'] != null,
        resume: sessionCaps['resume'] != null,
        fork: sessionCaps['fork'] != null,
        configOptions: sessionCaps['configOptions'] != null,
      );
    }

    // Fallback to checking session object (alternative format)
    final session = agentCaps['session'];
    if (session is Map<String, dynamic>) {
      return SessionCapabilities(
        list: session['list'] != null,
        resume: session['resume'] != null,
        fork: session['fork'] != null,
        configOptions: session['configOptions'] != null,
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

  @override
  String toString() =>
      'SessionCapabilities(list: $list, resume: $resume, fork: $fork, '
      'configOptions: $configOptions)';
}
