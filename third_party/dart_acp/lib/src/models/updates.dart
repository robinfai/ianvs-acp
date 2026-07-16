import 'command_types.dart';
import 'content_types.dart';
import 'diff_types.dart';
import 'session_types.dart';
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
    this.messageId,
    this.meta,
  });

  /// Create from raw content blocks.
  factory MessageDelta.fromRaw({
    required String role,
    required List<Map<String, dynamic>> rawContent,
    bool isThought = false,
    String? messageId,
    Map<String, dynamic>? meta,
  }) {
    final blocks = rawContent.map(ContentBlock.fromJson).toList();
    return MessageDelta(
      role: role,
      content: blocks,
      isThought: isThought,
      messageId: messageId,
      meta: meta,
    );
  }

  /// Role of the author ('assistant' or 'user').
  final String role;

  /// Content blocks comprising this delta.
  final List<ContentBlock> content;

  /// Whether this is a thought chunk (vs a message chunk).
  final bool isThought;

  /// Identifier shared by all chunks in the same message.
  final String? messageId;

  /// ACP extension metadata.
  final Map<String, dynamic>? meta;

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

/// Complete replacement of the session configuration option state.
class ConfigOptionUpdate extends AcpUpdate {
  /// Creates a configuration option update.
  const ConfigOptionUpdate(this.configOptions, {this.meta});

  /// Parses an ACP `config_option_update` payload.
  factory ConfigOptionUpdate.fromJson(Map<String, dynamic> json) {
    final raw = json['configOptions'];
    final options = raw is List
        ? raw
              .whereType<Map>()
              .map(
                (item) => ConfigOption.fromJson(
                  item.map((key, value) => MapEntry(key.toString(), value)),
                ),
              )
              .where((option) => option.id.isNotEmpty)
              .toList(growable: false)
        : const <ConfigOption>[];
    return ConfigOptionUpdate(options, meta: _mapFromRaw(json['_meta']));
  }

  /// Full configuration option list.
  final List<ConfigOption> configOptions;

  /// ACP extension metadata.
  final Map<String, dynamic>? meta;

  @override
  String get text => '[Config options: ${configOptions.length}]';
}

/// Partial update to session list metadata.
class SessionInfoUpdate extends AcpUpdate {
  /// Creates a session metadata update.
  const SessionInfoUpdate({this.title, this.updatedAt, this.meta});

  /// Parses an ACP `session_info_update` payload.
  factory SessionInfoUpdate.fromJson(Map<String, dynamic> json) =>
      SessionInfoUpdate(
        title: json['title'] is String ? json['title'] as String : null,
        updatedAt: json['updatedAt'] is String
            ? DateTime.tryParse(json['updatedAt'] as String)
            : null,
        meta: _mapFromRaw(json['_meta']),
      );

  /// New title, or null when absent/cleared.
  final String? title;

  /// New activity timestamp.
  final DateTime? updatedAt;

  /// ACP extension metadata.
  final Map<String, dynamic>? meta;

  @override
  String get text => title ?? '[Session info updated]';
}

/// Unstable plan content update retained without discarding new variants.
class StructuredPlanUpdate extends AcpUpdate {
  /// Creates an update from its raw payload.
  const StructuredPlanUpdate(this.raw);

  /// Raw `plan_update` payload.
  final Map<String, dynamic> raw;

  @override
  String get text => '[Plan updated]';
}

/// Unstable notification that a plan was removed.
class PlanRemovedUpdate extends AcpUpdate {
  /// Creates a removal update.
  const PlanRemovedUpdate(this.planId, {this.meta});

  /// Removed plan identifier.
  final String planId;

  /// ACP extension metadata.
  final Map<String, dynamic>? meta;

  @override
  String get text => '[Plan removed: $planId]';
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
  const TurnEnded(this.stopReason, {this.usage, this.meta});

  /// Reason for stopping the turn.
  final StopReason stopReason;

  /// Optional cumulative token usage returned with the prompt response.
  final PromptUsage? usage;

  /// ACP extension metadata.
  final Map<String, dynamic>? meta;

  @override
  String get text => '[Session ended: $stopReason]';
}

/// Token usage returned at the end of a prompt turn.
class PromptUsage {
  /// Creates prompt usage counters.
  const PromptUsage({
    required this.totalTokens,
    required this.inputTokens,
    required this.outputTokens,
    this.thoughtTokens,
    this.cachedReadTokens,
    this.cachedWriteTokens,
    this.meta,
  });

  /// Parses the unstable ACP end-turn usage shape.
  factory PromptUsage.fromJson(Map<String, dynamic> json) => PromptUsage(
    totalTokens: _intFromRaw(json['totalTokens']) ?? 0,
    inputTokens: _intFromRaw(json['inputTokens']) ?? 0,
    outputTokens: _intFromRaw(json['outputTokens']) ?? 0,
    thoughtTokens: _intFromRaw(json['thoughtTokens']),
    cachedReadTokens: _intFromRaw(json['cachedReadTokens']),
    cachedWriteTokens: _intFromRaw(json['cachedWriteTokens']),
    meta: _mapFromRaw(json['_meta']),
  );

  final int totalTokens;
  final int inputTokens;
  final int outputTokens;
  final int? thoughtTokens;
  final int? cachedReadTokens;
  final int? cachedWriteTokens;
  final Map<String, dynamic>? meta;

  /// Converts to the ACP wire representation.
  Map<String, dynamic> toJson() => {
    'totalTokens': totalTokens,
    'inputTokens': inputTokens,
    'outputTokens': outputTokens,
    if (thoughtTokens != null) 'thoughtTokens': thoughtTokens,
    if (cachedReadTokens != null) 'cachedReadTokens': cachedReadTokens,
    if (cachedWriteTokens != null) 'cachedWriteTokens': cachedWriteTokens,
    if (meta != null) '_meta': meta,
  };
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

Map<String, dynamic>? _mapFromRaw(Object? raw) {
  if (raw is! Map) return null;
  return raw.map((key, value) => MapEntry(key.toString(), value));
}
