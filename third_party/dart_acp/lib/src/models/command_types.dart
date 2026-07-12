// Command and plan types for ACP.

import '../input_budget.dart';

/// Input specification for available commands.
class AvailableCommandInput {
  /// Creates an available command input specification.
  const AvailableCommandInput({this.hint});

  /// Create from JSON.
  factory AvailableCommandInput.fromJson(
    Map<String, dynamic> json, {
    AcpInputBudget inputBudget = const AcpInputBudget(),
    AcpStructuredUpdateGuard? structuredGuard,
  }) {
    final guard =
        structuredGuard ??
        AcpStructuredUpdateGuard(
          budget: inputBudget,
          resource: 'available_command_input',
        );
    guard.checkCollection(json, field: 'command input');
    guard.consumeEntry(field: 'command input');
    return AvailableCommandInput(
      hint: _copyOptionalStringAliases(
        json,
        const <String>['hint', 'placeholder', 'description'],
        guard,
        field: 'command input hint',
      ),
    );
  }

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
  factory AvailableCommand.fromJson(
    Map<String, dynamic> json, {
    AcpInputBudget inputBudget = const AcpInputBudget(),
    AcpStructuredUpdateGuard? structuredGuard,
  }) {
    final guard =
        structuredGuard ??
        AcpStructuredUpdateGuard(
          budget: inputBudget,
          resource: _availableCommandsResource,
        );
    return _availableCommandFromMap(json, guard);
  }

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
  factory PlanEntry.fromJson(
    Map<String, dynamic> json, {
    AcpInputBudget inputBudget = const AcpInputBudget(),
    AcpStructuredUpdateGuard? structuredGuard,
  }) {
    final guard =
        structuredGuard ??
        AcpStructuredUpdateGuard(budget: inputBudget, resource: 'plan_entry');
    return _boundedPlanEntry(json, guard)!;
  }

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
    this.truncated = false,
    this.omission,
  });

  /// Create from JSON.
  factory Plan.fromJson(
    Map<String, dynamic> json, {
    AcpInputBudget inputBudget = const AcpInputBudget(),
    AcpStructuredUpdateGuard? structuredGuard,
  }) {
    final guard =
        structuredGuard ??
        AcpStructuredUpdateGuard(budget: inputBudget, resource: 'plan');
    guard.checkCollection(json, field: 'plan');
    guard.consumeEntry(field: 'plan');
    final title = _copyOptionalStringAliases(
      json,
      const <String>['title'],
      guard,
      field: 'title',
    );
    final description = _copyOptionalStringAliases(
      json,
      const <String>['description'],
      guard,
      field: 'description',
    );
    final rawEntries = _firstNonNull(json, const <String>[
      'entries',
      'steps',
      'items',
      'todos',
    ]);
    final entriesResult = _boundedPlanEntries(
      rawEntries,
      inputBudget: inputBudget,
      guard: guard,
    );
    Map<String, dynamic>? metadata;
    var omission = entriesResult.omission;
    final rawMetadata = _firstNonNull(json, const <String>['metadata']);
    if (!identical(rawMetadata, _absentCommandField)) {
      try {
        metadata = Map<String, dynamic>.unmodifiable(
          guard.copyMetadata(rawMetadata, field: 'metadata'),
        );
      } on AcpInputLimitExceeded catch (error) {
        omission ??= _limitOmission(
          resource: _planMetadataResource,
          error: error,
          truncated: false,
        );
      } catch (_) {
        omission ??= _invalidOmission(
          resource: _planMetadataResource,
          truncated: false,
        );
      }
    }

    return Plan(
      entries: entriesResult.entries,
      title: title,
      description: description,
      metadata: metadata,
      truncated: entriesResult.truncated,
      omission: omission,
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

  /// Whether only a safe display prefix of entries was retained.
  final bool truncated;

  /// Host-owned reason for omitted plan data.
  final AcpInputOmission? omission;

  /// Convert to JSON.
  Map<String, dynamic> toJson() => {
    'entries': entries.map((e) => e.toJson()).toList(),
    if (title != null) 'title': title,
    if (description != null) 'description': description,
    if (metadata != null) 'metadata': metadata,
  };
}

const Object _absentCommandField = Object();
const String _availableCommandsResource = 'available_commands';
const String _planEntriesResource = 'plan_entries';
const String _planMetadataResource = 'plan_metadata';

Object? _firstNonNull(Map source, List<String> fields) {
  for (final field in fields) {
    try {
      if (!source.containsKey(field)) continue;
      final value = source[field];
      if (value != null) return value;
    } catch (_) {
      throw const FormatException('Invalid ACP command structure.');
    }
  }
  return _absentCommandField;
}

String? _copyOptionalStringAliases(
  Map source,
  List<String> fields,
  AcpStructuredUpdateGuard guard, {
  required String field,
}) {
  final value = _firstNonNull(source, fields);
  if (identical(value, _absentCommandField)) return null;
  return guard.copyString(value, field: field);
}

AvailableCommand _availableCommandFromMap(
  Map source,
  AcpStructuredUpdateGuard guard,
) {
  guard.checkCollection(source, field: 'command');
  guard.consumeEntry(field: 'command');
  final name =
      _copyOptionalStringAliases(
        source,
        const <String>['name', 'id', 'command', 'title'],
        guard,
        field: 'command name',
      ) ??
      '';
  if (name.isEmpty) {
    throw const FormatException('Invalid ACP available command.');
  }
  final description = _copyOptionalStringAliases(
    source,
    const <String>['description', 'summary'],
    guard,
    field: 'command description',
  );
  final rawParameters = _firstNonNull(source, const <String>[
    'parameters',
    'params',
    'schema',
    'inputSchema',
    'input_schema',
  ]);
  Map<String, dynamic>? parameters;
  if (!identical(rawParameters, _absentCommandField)) {
    final copy = guard.copyMetadata(rawParameters, field: 'command parameters');
    if (copy.isNotEmpty) {
      parameters = Map<String, dynamic>.unmodifiable(copy);
    }
  }
  final rawInput = _firstNonNull(source, const <String>[
    'input',
    'argument',
    'arguments',
    'inputHint',
    'input_hint',
  ]);
  final input = identical(rawInput, _absentCommandField)
      ? null
      : _boundedCommandInput(rawInput, guard);
  return AvailableCommand(
    name: name,
    description: description,
    parameters: parameters,
    input: input,
  );
}

AvailableCommandInput? _boundedCommandInput(
  Object? raw,
  AcpStructuredUpdateGuard guard,
) {
  if (raw is String) {
    guard.consumeEntry(field: 'command input');
    final hint = guard.copyString(raw, field: 'command input hint').trim();
    return hint.isEmpty ? null : AvailableCommandInput(hint: hint);
  }
  if (raw is! Map) {
    throw const FormatException('Invalid ACP command input structure.');
  }
  guard.checkCollection(raw, field: 'command input');
  guard.consumeEntry(field: 'command input');
  final hint = _copyOptionalStringAliases(
    raw,
    const <String>['hint', 'placeholder', 'description'],
    guard,
    field: 'command input hint',
  );
  return hint == null ? null : AvailableCommandInput(hint: hint);
}

({List<PlanEntry> entries, bool truncated, AcpInputOmission? omission})
_boundedPlanEntries(
  Object? raw, {
  required AcpInputBudget inputBudget,
  required AcpStructuredUpdateGuard guard,
}) {
  if (identical(raw, _absentCommandField)) {
    return (entries: const <PlanEntry>[], truncated: false, omission: null);
  }
  if (raw is! List) {
    return (
      entries: const <PlanEntry>[],
      truncated: true,
      omission: _invalidOmission(
        resource: _planEntriesResource,
        truncated: false,
      ),
    );
  }

  final int reportedLength;
  try {
    reportedLength = raw.length;
  } catch (_) {
    return (
      entries: const <PlanEntry>[],
      truncated: true,
      omission: _invalidOmission(
        resource: _planEntriesResource,
        truncated: false,
      ),
    );
  }
  if (reportedLength < 0) {
    return (
      entries: const <PlanEntry>[],
      truncated: true,
      omission: _invalidOmission(
        resource: _planEntriesResource,
        truncated: false,
      ),
    );
  }
  guard.consumeContainerNode(field: 'entries');
  final entries = <PlanEntry>[];
  final Iterator<Object?> iterator;
  try {
    iterator = raw.iterator;
  } catch (_) {
    return (
      entries: const <PlanEntry>[],
      truncated: true,
      omission: _invalidOmission(
        resource: _planEntriesResource,
        truncated: false,
      ),
    );
  }
  AcpInputOmission? omission;
  var observedItems = 0;
  while (true) {
    final bool hasNext;
    try {
      hasNext = iterator.moveNext();
    } catch (_) {
      omission = _invalidOmission(
        resource: _planEntriesResource,
        truncated: false,
      );
      break;
    }
    if (!hasNext) break;
    observedItems += 1;
    if (observedItems > inputBudget.maxCollectionItems) {
      omission = AcpInputOmission(
        reason: AcpInputOmissionReason.inputLimit,
        resource: _planEntriesResource,
        truncated: true,
        limit: inputBudget.maxCollectionItems,
        observedAtLeast: observedItems,
      );
      break;
    }
    if (observedItems > reportedLength) {
      omission = _invalidOmission(
        resource: _planEntriesResource,
        truncated: true,
      );
      break;
    }
    final Object? item;
    try {
      item = iterator.current;
    } catch (_) {
      omission = _invalidOmission(
        resource: _planEntriesResource,
        truncated: false,
      );
      break;
    }
    try {
      final entry = _boundedPlanEntry(item, guard);
      if (entry != null) entries.add(entry);
    } on AcpInputLimitExceeded catch (error) {
      omission = _limitOmission(
        resource: _planEntriesResource,
        error: error,
        truncated: true,
      );
      break;
    } catch (_) {
      omission = _invalidOmission(
        resource: _planEntriesResource,
        truncated: false,
      );
      break;
    }
  }

  if (omission == null) {
    if (reportedLength > inputBudget.maxCollectionItems) {
      omission = AcpInputOmission(
        reason: AcpInputOmissionReason.inputLimit,
        resource: _planEntriesResource,
        truncated: true,
        limit: inputBudget.maxCollectionItems,
        observedAtLeast: reportedLength,
      );
    } else if (observedItems != reportedLength) {
      omission = _invalidOmission(
        resource: _planEntriesResource,
        truncated: true,
      );
    }
  }
  return (
    entries: List<PlanEntry>.unmodifiable(entries),
    truncated: omission != null,
    omission: omission,
  );
}

PlanEntry? _boundedPlanEntry(Object? raw, AcpStructuredUpdateGuard guard) {
  if (raw is String) {
    guard.consumeEntry(field: 'plan entry');
    final content = guard.copyString(raw, field: 'plan entry content').trim();
    if (content.isEmpty) return null;
    return PlanEntry(
      content: content,
      priority: PlanEntryPriority.medium,
      status: PlanEntryStatus.pending,
    );
  }
  if (raw is! Map) {
    throw const FormatException('Invalid ACP plan entry structure.');
  }
  guard.checkCollection(raw, field: 'plan entry');
  guard.consumeEntry(field: 'plan entry');
  final content =
      _copyOptionalStringAliases(
        raw,
        const <String>['content', 'text', 'title', 'task'],
        guard,
        field: 'plan entry content',
      ) ??
      '';
  final priority = _copyOptionalStringAliases(
    raw,
    const <String>['priority'],
    guard,
    field: 'plan entry priority',
  );
  final status = _copyOptionalStringAliases(
    raw,
    const <String>['status'],
    guard,
    field: 'plan entry status',
  );
  final rawMetadata = _firstNonNull(raw, const <String>['metadata']);
  Map<String, dynamic>? metadata;
  if (!identical(rawMetadata, _absentCommandField)) {
    metadata = Map<String, dynamic>.unmodifiable(
      guard.copyMetadata(rawMetadata, field: 'plan entry metadata'),
    );
  }
  return PlanEntry(
    content: content,
    priority: PlanEntryPriority.fromWire(priority),
    status: PlanEntryStatus.fromWire(status),
    metadata: metadata,
  );
}

AcpInputOmission _limitOmission({
  required String resource,
  required AcpInputLimitExceeded error,
  required bool truncated,
}) => AcpInputOmission(
  reason: AcpInputOmissionReason.inputLimit,
  resource: resource,
  truncated: truncated,
  limit: error.limit,
  observedAtLeast: error.observedAtLeast,
);

AcpInputOmission _invalidOmission({
  required String resource,
  required bool truncated,
}) => AcpInputOmission(
  reason: AcpInputOmissionReason.invalidStructure,
  resource: resource,
  truncated: truncated,
);

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
