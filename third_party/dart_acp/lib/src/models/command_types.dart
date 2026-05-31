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
    switch (value) {
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
    switch (value) {
      case 'pending':
        return PlanEntryStatus.pending;
      case 'in_progress':
        return PlanEntryStatus.inProgress;
      case 'completed':
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
    content: json['content'] as String? ?? '',
    priority: PlanEntryPriority.fromWire(json['priority'] as String?),
    status: PlanEntryStatus.fromWire(json['status'] as String?),
    metadata: json['metadata'] as Map<String, dynamic>?,
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
    final entriesList =
        (json['entries'] as List?)
            ?.map((e) => PlanEntry.fromJson(e as Map<String, dynamic>))
            .toList() ??
        const [];

    return Plan(
      entries: entriesList,
      title: json['title'] as String?,
      description: json['description'] as String?,
      metadata: json['metadata'] as Map<String, dynamic>?,
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
