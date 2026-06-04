import 'command_types.dart';
import 'content_types.dart';
import 'diff_types.dart';
import 'tool_types.dart';
import 'types.dart';

/// Base class for typed session/update events.
sealed class AcpUpdate {
  /// Create an update instance.
  const AcpUpdate();

  /// Get a text representation of this update.
  String get text;
}

/// Update containing the agent's current execution plan.
class PlanUpdate extends AcpUpdate {
  /// Construct with a typed plan.
  const PlanUpdate(this.plan);

  /// Create from raw JSON.
  factory PlanUpdate.fromJson(Map<String, dynamic> json) =>
      PlanUpdate(Plan.fromJson(json));

  /// The execution plan.
  final Plan plan;

  @override
  String get text => plan.title ?? 'Plan update';
}

/// Streaming message delta, for user/assistant content blocks.
class MessageDelta extends AcpUpdate {
  /// Create a message delta.
  const MessageDelta({
    required this.role,
    required this.content,
    this.isThought = false,
  });

  /// Create from raw content blocks.
  factory MessageDelta.fromRaw({
    required String role,
    required List<Map<String, dynamic>> rawContent,
    bool isThought = false,
  }) {
    final blocks = rawContent.map(ContentBlock.fromJson).toList();
    return MessageDelta(role: role, content: blocks, isThought: isThought);
  }

  /// Role of the author ('assistant' or 'user').
  final String role;

  /// Content blocks comprising this delta.
  final List<ContentBlock> content;

  /// Whether this is a thought chunk (vs a message chunk).
  final bool isThought;

  @override
  String get text {
    final buffer = StringBuffer();
    for (final block in content) {
      if (block is TextContent) {
        buffer.write(block.text);
      }
    }
    return buffer.toString();
  }
}

/// Tool call creation/progress/completion update.
class ToolCallUpdate extends AcpUpdate {
  /// Construct with a typed tool call.
  const ToolCallUpdate(this.toolCall);

  /// Create from raw JSON.
  factory ToolCallUpdate.fromJson(Map<String, dynamic> json) =>
      ToolCallUpdate(ToolCall.fromJson(json));

  /// The tool call information.
  final ToolCall toolCall;

  @override
  String get text =>
      '[Tool: ${toolCall.title ?? toolCall.toolCallId}] ${toolCall.status}';
}

/// File diff update with proposed changes.
class DiffUpdate extends AcpUpdate {
  /// Construct with a typed diff.
  const DiffUpdate(this.diff);

  /// Create from raw JSON.
  factory DiffUpdate.fromJson(Map<String, dynamic> json) =>
      DiffUpdate(Diff.fromJson(json));

  /// The diff information.
  final Diff diff;

  @override
  String get text => '[Diff: ${diff.uri ?? diff.id}]';
}

/// Update containing currently available commands for the agent.
class AvailableCommandsUpdate extends AcpUpdate {
  /// Construct with typed commands.
  const AvailableCommandsUpdate(this.commands);

  /// Create from raw command list.
  factory AvailableCommandsUpdate.fromRaw(List<Map<String, dynamic>> raw) {
    final cmds = raw.map(AvailableCommand.fromJson).toList();
    return AvailableCommandsUpdate(cmds);
  }

  /// Available commands.
  final List<AvailableCommand> commands;

  @override
  String get text {
    if (commands.isEmpty) return '[Commands: none]';
    final names = commands.map((c) => c.name).join(', ');
    return '[Commands: $names]';
  }
}

/// Cumulative session cost reported with a usage update.
class UsageCost {
  /// Construct a usage cost.
  const UsageCost({required this.amount, required this.currency});

  /// Create from raw JSON.
  factory UsageCost.fromJson(Map<String, dynamic> json) {
    final amount = _numFromRaw(json['amount']);
    final currency = json['currency']?.toString().trim() ?? '';
    return UsageCost(amount: amount ?? 0, currency: currency);
  }

  /// Total cumulative cost for the session.
  final num amount;

  /// Billing currency or unit.
  final String currency;

  /// Convert to JSON.
  Map<String, dynamic> toJson() => {'amount': amount, 'currency': currency};
}

/// Session-level context window and optional cumulative cost update.
class UsageUpdate extends AcpUpdate {
  /// Construct a usage update.
  const UsageUpdate({required this.used, required this.size, this.cost});

  /// Create from raw JSON.
  factory UsageUpdate.fromJson(Map<String, dynamic> json) {
    final cost = _usageCostFromRaw(json['cost']);
    return UsageUpdate(
      used: _intFromRaw(json['used']) ?? 0,
      size: _intFromRaw(json['size']) ?? 0,
      cost: cost,
    );
  }

  /// Tokens currently in context.
  final int used;

  /// Total context window size in tokens.
  final int size;

  /// Optional cumulative session cost.
  final UsageCost? cost;

  /// Convert to JSON.
  Map<String, dynamic> toJson() => {
    'sessionUpdate': 'usage_update',
    'used': used,
    'size': size,
    if (cost != null) 'cost': cost!.toJson(),
  };

  @override
  String get text => '[Usage: $used/$size]';
}

/// Terminal update indicating a prompt turn is complete.
class TurnEnded extends AcpUpdate {
  /// Construct with the terminal [stopReason].
  const TurnEnded(this.stopReason);

  /// Reason for stopping the turn.
  final StopReason stopReason;

  @override
  String get text => '[Session ended: $stopReason]';
}

/// Update type used for unclassified session/update payloads.
class UnknownUpdate extends AcpUpdate {
  /// Construct with the raw notification payload.
  const UnknownUpdate(this.raw);

  /// Raw session/update map.
  final Map<String, dynamic> raw;

  @override
  String get text =>
      '[Unknown update: ${raw['sessionUpdate'] ?? 'unspecified'}]';
}

/// Mode update indicating current session mode changed (extension).
class ModeUpdate extends AcpUpdate {
  /// Construct with the new current mode id.
  const ModeUpdate(this.currentModeId);

  /// Current mode id selected by the agent.
  final String currentModeId;

  @override
  String get text => '[Mode: $currentModeId]';
}

int? _intFromRaw(Object? raw) {
  if (raw is num) return raw.toInt();
  if (raw is String) return int.tryParse(raw.trim());
  return null;
}

num? _numFromRaw(Object? raw) {
  if (raw is num) return raw;
  if (raw is String) return num.tryParse(raw.trim());
  return null;
}

UsageCost? _usageCostFromRaw(Object? raw) {
  if (raw is! Map) return null;
  final mapped = raw.map((key, value) => MapEntry(key.toString(), value));
  final amount = _numFromRaw(mapped['amount']);
  final currency = mapped['currency']?.toString().trim() ?? '';
  if (amount == null || currency.isEmpty) return null;
  return UsageCost(amount: amount, currency: currency);
}
