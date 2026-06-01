// Command and plan types for ACP.

/// Input specification for available commands.
class AvailableCommandInput {
  /// Creates an available command input specification.
  const AvailableCommandInput({this.hint});

  /// Create from JSON.
  factory AvailableCommandInput.fromJson(Map<String, dynamic> json) =>
      AvailableCommandInput(hint: json['hint'] as String?);

  /// Hint to display when input hasn't been provided yet.
  final String? hint;

  /// Convert to JSON.
  Map<String, dynamic> toJson() => {if (hint != null) 'hint': hint};
}

/// Available command that can be executed.
class AvailableCommand {
  /// Creates an available command.
  const AvailableCommand({
    required this.name,
    this.description,
    this.parameters,
    this.input,
  });

  /// Create from JSON.
  factory AvailableCommand.fromJson(Map<String, dynamic> json) =>
      AvailableCommand(
        name: json['name'] as String? ?? '',
        description: json['description'] as String?,
        parameters: json['parameters'] as Map<String, dynamic>?,
        input: json['input'] != null
            ? AvailableCommandInput.fromJson(
                json['input'] as Map<String, dynamic>,
              )
            : null,
      );

  /// Name/identifier of the command.
  final String name;

  /// Human-readable description.
  final String? description;

  /// Parameters for the command (agent-specific).
  final Map<String, dynamic>? parameters;

  /// Input specification for the command.
  final AvailableCommandInput? input;

  /// Convert to JSON.
  Map<String, dynamic> toJson() => {
    'name': name,
    if (description != null) 'description': description,
    if (parameters != null) 'parameters': parameters,
    if (input != null) 'input': input!.toJson(),
  };
}

/// Priority levels for plan entries.
enum PlanEntryPriority {
  /// High priority.
  high,

  /// Medium priority.
  medium,

  /// Low priority.
  low;

  /// Parse from wire format.
  static PlanEntryPriority fromWire(String? value) {
    switch (value?.trim().toLowerCase()) {
      case 'high':
        return PlanEntryPriority.high;
      case 'medium':
        return PlanEntryPriority.medium;
      case 'low':
        return PlanEntryPriority.low;
      default:
        return PlanEntryPriority.medium;
    }
  }

  /// Convert to wire format.
  String toWire() => name;
}

/// Status values for plan entries.
enum PlanEntryStatus {
  /// Entry is pending execution.
  pending,

  /// Entry is currently in progress.
  inProgress,

  /// Entry has been completed.
  completed;

  /// Parse from wire format.
  static PlanEntryStatus fromWire(String? value) {
    switch (_normalizedStatus(value)) {
      case 'pending':
        return PlanEntryStatus.pending;
      case 'in_progress':
      case 'running':
      case 'started':
        return PlanEntryStatus.inProgress;
      case 'completed':
      case 'complete':
      case 'done':
      case 'success':
        return PlanEntryStatus.completed;
      default:
        return PlanEntryStatus.pending;
    }
  }

  /// Convert to wire format.
  String toWire() {
    switch (this) {
      case PlanEntryStatus.inProgress:
        return 'in_progress';
      case PlanEntryStatus.pending:
      case PlanEntryStatus.completed:
        return name;
    }
  }
}

/// A entry in an execution plan.
class PlanEntry {
  /// Creates a plan entry.
  const PlanEntry({
    required this.content,
    required this.priority,
    required this.status,
    this.metadata,
  });

  /// Create from JSON.
  factory PlanEntry.fromJson(Map<String, dynamic> json) => PlanEntry(
    content:
        _optionalString(json['content']) ??
        _optionalString(json['text']) ??
        _optionalString(json['title']) ??
        _optionalString(json['task']) ??
        '',
    priority: PlanEntryPriority.fromWire(_optionalString(json['priority'])),
    status: PlanEntryStatus.fromWire(_optionalString(json['status'])),
    metadata: _optionalMap(json['metadata']),
  );

  /// Content/description of this plan step.
  final String content;

  /// Priority level of this entry.
  final PlanEntryPriority priority;

  /// Current execution status of this entry.
  final PlanEntryStatus status;

  /// Additional metadata (agent-specific).
  final Map<String, dynamic>? metadata;

  /// Convert to JSON.
  Map<String, dynamic> toJson() => {
    'content': content,
    'priority': priority.toWire(),
    'status': status.toWire(),
    if (metadata != null) 'metadata': metadata,
  };
}

/// Execution plan with structured entries.
class Plan {
  /// Creates a plan.
  const Plan({
    required this.entries,
    this.title,
    this.description,
    this.metadata,
  });

  /// Create from JSON.
  factory Plan.fromJson(Map<String, dynamic> json) {
    final entriesList = _planEntriesFromRaw(
      json['entries'] ?? json['steps'] ?? json['items'] ?? json['todos'],
    );

    return Plan(
      entries: entriesList,
      title: _optionalString(json['title']),
      description: _optionalString(json['description']),
      metadata: _optionalMap(json['metadata']),
    );
  }

  /// List of plan entries/steps.
  final List<PlanEntry> entries;

  /// Title of the plan.
  final String? title;

  /// Overall description.
  final String? description;

  /// Additional metadata (agent-specific).
  final Map<String, dynamic>? metadata;

  /// Convert to JSON.
  Map<String, dynamic> toJson() => {
    'entries': entries.map((e) => e.toJson()).toList(),
    if (title != null) 'title': title,
    if (description != null) 'description': description,
    if (metadata != null) 'metadata': metadata,
  };
}

String? _optionalString(Object? value) => value is String ? value : null;

String? _normalizedStatus(String? value) {
  if (value == null) return null;
  final cleaned = value.trim();
  if (cleaned.isEmpty) return null;
  return cleaned
      .replaceAllMapped(
        RegExp(r'([a-z0-9])([A-Z])'),
        (match) => '${match.group(1)}_${match.group(2)}',
      )
      .replaceAll(RegExp(r'[\s-]+'), '_')
      .toLowerCase();
}

Map<String, dynamic>? _optionalMap(Object? value) {
  if (value is! Map) return null;
  return value.map((key, value) => MapEntry(key.toString(), value));
}

List<PlanEntry> _planEntriesFromRaw(Object? raw) {
  if (raw is! List) return const <PlanEntry>[];
  return raw
      .map(_planEntryFromRaw)
      .whereType<PlanEntry>()
      .toList(growable: false);
}

PlanEntry? _planEntryFromRaw(Object? raw) {
  if (raw is String) {
    final content = raw.trim();
    if (content.isEmpty) return null;
    return PlanEntry(
      content: content,
      priority: PlanEntryPriority.medium,
      status: PlanEntryStatus.pending,
    );
  }
  if (raw is! Map) return null;
  return PlanEntry.fromJson(
    raw.map((key, value) => MapEntry(key.toString(), value)),
  );
}
