import 'command_types.dart';
import 'content_types.dart';
import 'diff_types.dart';
import 'session_types.dart';
import 'tool_types.dart';
import 'types.dart';
import '../input_budget.dart';

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
  factory PlanUpdate.fromJson(
    Map<String, dynamic> json, {
    AcpInputBudget inputBudget = const AcpInputBudget(),
    AcpStructuredUpdateGuard? structuredGuard,
  }) {
    final guard = _updateGuard(inputBudget, structuredGuard);
    guard.checkCollection(json, field: 'plan update');
    guard.consumeEntry(field: 'plan update');
    return PlanUpdate(
      Plan.fromJson(json, inputBudget: inputBudget, structuredGuard: guard),
    );
  }

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
    this.omissions = const <AcpInputOmission>[],
  });

  /// Create from raw content blocks.
  factory MessageDelta.fromRaw({
    required String role,
    required List<Object?> rawContent,
    bool isThought = false,
    String? messageId,
    Map<String, dynamic>? meta,
    AcpInputBudget inputBudget = const AcpInputBudget(),
    AcpStructuredUpdateGuard? structuredGuard,
  }) {
    final guard = _updateGuard(inputBudget, structuredGuard);
    final int reportedLength;
    try {
      reportedLength = rawContent.length;
    } catch (_) {
      throw const FormatException('Invalid ACP message content structure.');
    }
    if (reportedLength < 0) {
      throw const FormatException('Invalid ACP message content structure.');
    }
    guard.consumeEntry(field: 'message delta');
    final boundedRole = guard.copyString(role, field: 'message role');
    guard.consumeContainerNode(field: 'message content');
    final blocks = <ContentBlock>[];
    final omissions = <AcpInputOmission>[];
    final seen = <String>{};
    final Iterator<Object?> iterator;
    try {
      iterator = rawContent.iterator;
    } catch (_) {
      throw const FormatException('Invalid ACP message content structure.');
    }
    final retainedLength = reportedLength > inputBudget.maxCollectionItems
        ? inputBudget.maxCollectionItems
        : reportedLength;
    for (var index = 0; index < retainedLength; index += 1) {
      final bool hasNext;
      try {
        hasNext = iterator.moveNext();
      } catch (_) {
        throw const FormatException('Invalid ACP message content structure.');
      }
      if (!hasNext) {
        throw const FormatException('Invalid ACP message content structure.');
      }
      final Object? rawBlock;
      try {
        rawBlock = iterator.current;
      } catch (_) {
        throw const FormatException('Invalid ACP message content structure.');
      }
      final ContentBlock block;
      if (rawBlock is String) {
        final text = guard.copyString(rawBlock, field: 'legacy text content');
        block = TextContent.fromJson(
          <String, dynamic>{'type': 'text', 'text': text},
          inputBudget: inputBudget,
          structuredGuard: guard,
        );
      } else if (rawBlock is Map<String, dynamic>) {
        block = ContentBlock.fromJson(
          rawBlock,
          inputBudget: inputBudget,
          structuredGuard: guard,
        );
      } else {
        guard.consumeEntry(field: 'content block');
        block = UnknownContent.omitted(
          AcpInputOmission(
            reason: AcpInputOmissionReason.invalidStructure,
            resource: 'content_block',
            truncated: false,
          ),
        );
      }
      blocks.add(block);
      final omission = block.omission;
      if (omission != null && seen.add(_omissionIdentity(omission))) {
        omissions.add(omission);
      }
    }
    if (reportedLength > inputBudget.maxCollectionItems) {
      final omission = AcpInputOmission(
        reason: AcpInputOmissionReason.inputLimit,
        resource: 'message_content',
        truncated: true,
        limit: inputBudget.maxCollectionItems,
        observedAtLeast: reportedLength,
      );
      if (seen.add(_omissionIdentity(omission))) omissions.add(omission);
    } else {
      final bool hasExtra;
      try {
        hasExtra = iterator.moveNext();
      } catch (_) {
        throw const FormatException('Invalid ACP message content structure.');
      }
      if (hasExtra) {
        final omission = reportedLength >= inputBudget.maxCollectionItems
            ? AcpInputOmission(
                reason: AcpInputOmissionReason.inputLimit,
                resource: 'message_content',
                truncated: true,
                limit: inputBudget.maxCollectionItems,
                observedAtLeast: inputBudget.maxCollectionItems + 1,
              )
            : AcpInputOmission(
                reason: AcpInputOmissionReason.invalidStructure,
                resource: 'message_content',
                truncated: true,
              );
        if (seen.add(_omissionIdentity(omission))) omissions.add(omission);
      }
    }
    return MessageDelta(
      role: boundedRole,
      content: List<ContentBlock>.unmodifiable(blocks),
      isThought: isThought,
      messageId: messageId == null
          ? null
          : guard.copyString(messageId, field: 'message id'),
      meta: meta == null
          ? null
          : Map<String, dynamic>.unmodifiable(
              guard.copyMetadata(meta, field: 'message metadata'),
            ),
      omissions: List<AcpInputOmission>.unmodifiable(omissions),
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

  /// Host-owned omissions aggregated from bounded content blocks.
  final List<AcpInputOmission> omissions;

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
  factory ToolCallUpdate.fromJson(
    Map<String, dynamic> json, {
    AcpInputBudget inputBudget = const AcpInputBudget(),
    AcpStructuredUpdateGuard? structuredGuard,
  }) {
    final guard = _updateGuard(inputBudget, structuredGuard);
    guard.checkCollection(json, field: 'tool call update');
    guard.consumeEntry(field: 'tool call update');
    return ToolCallUpdate(
      ToolCall.fromJson(json, inputBudget: inputBudget, structuredGuard: guard),
    );
  }

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
  factory DiffUpdate.fromJson(
    Map<String, dynamic> json, {
    AcpInputBudget inputBudget = const AcpInputBudget(),
    AcpStructuredUpdateGuard? structuredGuard,
  }) {
    final guard = _updateGuard(inputBudget, structuredGuard);
    guard.checkCollection(json, field: 'diff update');
    guard.consumeEntry(field: 'diff update');
    return DiffUpdate(
      Diff.fromJson(json, inputBudget: inputBudget, structuredGuard: guard),
    );
  }

  /// The diff information.
  final Diff diff;

  @override
  String get text => '[Diff: ${diff.uri ?? diff.id}]';
}

/// Update containing currently available commands for the agent.
class AvailableCommandsUpdate extends AcpUpdate {
  /// Construct with typed commands.
  const AvailableCommandsUpdate(this.commands, {this.omission});

  /// Create from raw command list.
  factory AvailableCommandsUpdate.fromRaw(
    List<Object?> raw, {
    AcpInputBudget inputBudget = const AcpInputBudget(),
    AcpStructuredUpdateGuard? structuredGuard,
  }) {
    final guard = _updateGuard(inputBudget, structuredGuard);
    try {
      final reportedLength = guard.checkCollection(
        raw,
        field: 'available commands',
      );
      guard.consumeEntry(field: 'available commands update');
      guard.consumeContainerNode(field: 'available commands');
      final commands = <AvailableCommand>[];
      final Iterator<Object?> iterator;
      try {
        iterator = raw.iterator;
      } catch (_) {
        throw const FormatException('Invalid ACP available commands.');
      }
      for (var index = 0; index < reportedLength; index += 1) {
        final bool hasNext;
        try {
          hasNext = iterator.moveNext();
        } catch (_) {
          throw const FormatException('Invalid ACP available commands.');
        }
        if (!hasNext) {
          throw const FormatException('Invalid ACP available commands.');
        }
        final Object? rawCommand;
        try {
          rawCommand = iterator.current;
        } catch (_) {
          throw const FormatException('Invalid ACP available commands.');
        }
        if (rawCommand is String) {
          final name = guard
              .copyString(rawCommand, field: 'available command name')
              .trim();
          if (name.isEmpty) {
            throw const FormatException('Invalid ACP available command.');
          }
          commands.add(AvailableCommand(name: name));
          continue;
        }
        if (rawCommand is! Map<String, dynamic>) {
          throw const FormatException('Invalid ACP available command.');
        }
        commands.add(
          AvailableCommand.fromJson(
            rawCommand,
            inputBudget: inputBudget,
            structuredGuard: guard,
          ),
        );
      }
      final bool hasExtra;
      try {
        hasExtra = iterator.moveNext();
      } catch (_) {
        throw const FormatException('Invalid ACP available commands.');
      }
      if (hasExtra) {
        if (reportedLength >= inputBudget.maxCollectionItems) {
          throw AcpInputLimitExceeded(
            resource: 'available_commands',
            limit: inputBudget.maxCollectionItems,
            observedAtLeast: reportedLength + 1,
          );
        }
        throw const FormatException('Invalid ACP available commands.');
      }
      return AvailableCommandsUpdate(
        List<AvailableCommand>.unmodifiable(commands),
      );
    } on AcpInputLimitExceeded catch (error) {
      return AvailableCommandsUpdate(
        const <AvailableCommand>[],
        omission: AcpInputOmission(
          reason: AcpInputOmissionReason.inputLimit,
          resource: 'available_commands',
          truncated: false,
          limit: error.limit,
          observedAtLeast: error.observedAtLeast,
        ),
      );
    } catch (_) {
      return AvailableCommandsUpdate(
        const <AvailableCommand>[],
        omission: AcpInputOmission(
          reason: AcpInputOmissionReason.invalidStructure,
          resource: 'available_commands',
          truncated: false,
        ),
      );
    }
  }

  /// Available commands.
  final List<AvailableCommand> commands;

  /// Host-owned reason why the actionable list was rejected.
  final AcpInputOmission? omission;

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
  factory ConfigOptionUpdate.fromJson(
    Map<String, dynamic> json, {
    AcpInputBudget inputBudget = const AcpInputBudget(),
    AcpStructuredUpdateGuard? structuredGuard,
  }) {
    final guard = _updateGuard(inputBudget, structuredGuard);
    guard.checkCollection(json, field: 'config option update');
    guard.consumeEntry(field: 'config option update');
    final raw = _firstUpdateValue(json, const <String>['configOptions']);
    final options = <ConfigOption>[];
    if (!identical(raw, _absentUpdateField)) {
      if (raw is! List) {
        throw const FormatException('Invalid ACP config option update.');
      }
      guard.checkCollection(raw, field: 'config options');
      guard.consumeContainerNode(field: 'config options');
      for (final item in raw) {
        if (item is! Map<String, dynamic>) {
          throw const FormatException('Invalid ACP config option update.');
        }
        options.add(
          ConfigOption.fromJson(
            item,
            inputBudget: inputBudget,
            structuredGuard: guard,
          ),
        );
      }
    }
    return ConfigOptionUpdate(
      List<ConfigOption>.unmodifiable(options),
      meta: _boundedUpdateMetadata(
        json,
        guard,
        field: 'config update metadata',
      ),
    );
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
  factory SessionInfoUpdate.fromJson(
    Map<String, dynamic> json, {
    AcpInputBudget inputBudget = const AcpInputBudget(),
    AcpStructuredUpdateGuard? structuredGuard,
  }) {
    final guard = _updateGuard(inputBudget, structuredGuard);
    guard.checkCollection(json, field: 'session info update');
    guard.consumeEntry(field: 'session info update');
    final rawTitle = _firstUpdateValue(json, const <String>['title']);
    final rawUpdatedAt = _firstUpdateValue(json, const <String>['updatedAt']);
    final updatedAtText = identical(rawUpdatedAt, _absentUpdateField)
        ? null
        : guard.copyString(rawUpdatedAt, field: 'session updated timestamp');
    return SessionInfoUpdate(
      title: identical(rawTitle, _absentUpdateField)
          ? null
          : guard.copyString(rawTitle, field: 'session title'),
      updatedAt: updatedAtText == null
          ? null
          : DateTime.tryParse(updatedAtText),
      meta: _boundedUpdateMetadata(json, guard, field: 'session info metadata'),
    );
  }

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

  /// Creates an immutable bounded snapshot of a structured plan payload.
  factory StructuredPlanUpdate.fromJson(
    Map<String, dynamic> json, {
    AcpInputBudget inputBudget = const AcpInputBudget(),
    AcpStructuredUpdateGuard? structuredGuard,
  }) {
    final guard = _updateGuard(inputBudget, structuredGuard);
    guard.checkCollection(json, field: 'structured plan update');
    guard.consumeEntry(field: 'structured plan update');
    return StructuredPlanUpdate(
      Map<String, dynamic>.unmodifiable(
        guard.copyMetadata(json, field: 'structured plan payload'),
      ),
    );
  }

  /// Raw `plan_update` payload.
  final Map<String, dynamic> raw;

  @override
  String get text => '[Plan updated]';
}

/// Unstable notification that a plan was removed.
class PlanRemovedUpdate extends AcpUpdate {
  /// Creates a removal update.
  const PlanRemovedUpdate(this.planId, {this.meta});

  /// Parses a bounded ACP plan removal update.
  factory PlanRemovedUpdate.fromJson(
    Map<String, dynamic> json, {
    AcpInputBudget inputBudget = const AcpInputBudget(),
    AcpStructuredUpdateGuard? structuredGuard,
  }) {
    final guard = _updateGuard(inputBudget, structuredGuard);
    guard.checkCollection(json, field: 'plan removed update');
    guard.consumeEntry(field: 'plan removed update');
    final rawId = _firstUpdateValue(json, const <String>['planId']);
    return PlanRemovedUpdate(
      identical(rawId, _absentUpdateField)
          ? ''
          : guard.copyString(rawId, field: 'removed plan id'),
      meta: _boundedUpdateMetadata(json, guard, field: 'removed plan metadata'),
    );
  }

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
  factory UsageCost.fromJson(
    Map<String, dynamic> json, {
    AcpInputBudget inputBudget = const AcpInputBudget(),
    AcpStructuredUpdateGuard? structuredGuard,
  }) {
    final guard =
        structuredGuard ??
        AcpStructuredUpdateGuard(budget: inputBudget, resource: 'usage_cost');
    return UsageCost._fromMap(json, guard);
  }

  factory UsageCost._fromMap(Map json, AcpStructuredUpdateGuard guard) {
    guard.checkCollection(json, field: 'usage cost');
    guard.consumeEntry(field: 'usage cost');
    final rawAmount = _firstUpdateValue(json, const <String>['amount']);
    final rawCurrency = _firstUpdateValue(json, const <String>['currency']);
    return UsageCost(
      amount: identical(rawAmount, _absentUpdateField)
          ? 0
          : _boundedUsageNumber(rawAmount, guard, field: 'usage amount'),
      currency: identical(rawCurrency, _absentUpdateField)
          ? ''
          : guard.copyString(rawCurrency, field: 'usage currency').trim(),
    );
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
  factory UsageUpdate.fromJson(
    Map<String, dynamic> json, {
    AcpInputBudget inputBudget = const AcpInputBudget(),
    AcpStructuredUpdateGuard? structuredGuard,
  }) {
    final guard = _updateGuard(inputBudget, structuredGuard);
    guard.checkCollection(json, field: 'usage update');
    guard.consumeEntry(field: 'usage update');
    final rawUsed = _firstUpdateValue(json, const <String>['used']);
    final rawSize = _firstUpdateValue(json, const <String>['size']);
    final rawCost = _firstUpdateValue(json, const <String>['cost']);
    final cost = identical(rawCost, _absentUpdateField)
        ? null
        : _boundedUsageCost(rawCost, guard);
    return UsageUpdate(
      used: identical(rawUsed, _absentUpdateField)
          ? 0
          : _boundedUsageInt(rawUsed, guard, field: 'usage used'),
      size: identical(rawSize, _absentUpdateField)
          ? 0
          : _boundedUsageInt(rawSize, guard, field: 'usage size'),
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
  factory PromptUsage.fromJson(
    Map<String, dynamic> json, {
    AcpInputBudget inputBudget = const AcpInputBudget(),
    AcpStructuredUpdateGuard? structuredGuard,
  }) {
    final guard = _updateGuard(inputBudget, structuredGuard);
    guard.checkCollection(json, field: 'prompt usage');
    guard.consumeEntry(field: 'prompt usage');
    int? optionalInt(String field) {
      final raw = _firstUpdateValue(json, <String>[field]);
      return identical(raw, _absentUpdateField)
          ? null
          : _boundedUsageInt(raw, guard, field: field);
    }

    return PromptUsage(
      totalTokens: optionalInt('totalTokens') ?? 0,
      inputTokens: optionalInt('inputTokens') ?? 0,
      outputTokens: optionalInt('outputTokens') ?? 0,
      thoughtTokens: optionalInt('thoughtTokens'),
      cachedReadTokens: optionalInt('cachedReadTokens'),
      cachedWriteTokens: optionalInt('cachedWriteTokens'),
      meta: _boundedUpdateMetadata(json, guard, field: 'prompt usage metadata'),
    );
  }

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
  const UnknownUpdate(this.raw, {this.omission, this.boundedKind});

  /// Create an immutable bounded snapshot of an unclassified update.
  factory UnknownUpdate.fromJson(
    Map<String, dynamic> json, {
    AcpInputBudget inputBudget = const AcpInputBudget(),
    AcpStructuredUpdateGuard? structuredGuard,
  }) {
    final guard = _updateGuard(inputBudget, structuredGuard);
    try {
      guard.checkCollection(json, field: 'unknown update');
      guard.consumeEntry(field: 'unknown update');
      final copy = guard.copyMetadata(json, field: 'unknown update raw');
      final rawKind = copy['sessionUpdate'];
      final boundedKind = rawKind is String && rawKind.trim().isNotEmpty
          ? rawKind.trim()
          : null;
      return UnknownUpdate(
        Map<String, dynamic>.unmodifiable(copy),
        boundedKind: boundedKind,
      );
    } on AcpInputLimitExceeded catch (error) {
      return UnknownUpdate(
        const <String, dynamic>{},
        omission: AcpInputOmission(
          reason: AcpInputOmissionReason.inputLimit,
          resource: 'unknown_update',
          truncated: false,
          limit: error.limit,
          observedAtLeast: error.observedAtLeast,
        ),
      );
    } catch (_) {
      return UnknownUpdate(
        const <String, dynamic>{},
        omission: AcpInputOmission(
          reason: AcpInputOmissionReason.invalidStructure,
          resource: 'unknown_update',
          truncated: false,
        ),
      );
    }
  }

  /// Raw session/update map.
  final Map<String, dynamic> raw;

  /// Host-owned reason why the raw snapshot was rejected.
  final AcpInputOmission? omission;

  /// Host-owned bounded classification captured before a rejected raw copy.
  final String? boundedKind;

  @override
  String get text {
    return '[Unknown update: ${boundedKind ?? 'unspecified'}]';
  }
}

/// Mode update indicating current session mode changed (extension).
class ModeUpdate extends AcpUpdate {
  /// Construct with the new current mode id.
  const ModeUpdate(this.currentModeId, {this.omission});

  /// Create a bounded current-mode update.
  factory ModeUpdate.fromJson(
    Map<String, dynamic> json, {
    AcpInputBudget inputBudget = const AcpInputBudget(),
    AcpStructuredUpdateGuard? structuredGuard,
  }) {
    final guard = _updateGuard(inputBudget, structuredGuard);
    try {
      guard.checkCollection(json, field: 'mode update');
      guard.consumeEntry(field: 'mode update');
      final rawMode = _firstUpdateValue(json, const <String>[
        'currentModeId',
        'current_mode_id',
        'modeId',
        'mode_id',
      ]);
      final mode = identical(rawMode, _absentUpdateField)
          ? ''
          : guard.copyString(rawMode, field: 'current mode id');
      return ModeUpdate(mode);
    } on AcpInputLimitExceeded catch (error) {
      return ModeUpdate(
        '',
        omission: AcpInputOmission(
          reason: AcpInputOmissionReason.inputLimit,
          resource: 'current_mode',
          truncated: false,
          limit: error.limit,
          observedAtLeast: error.observedAtLeast,
        ),
      );
    } catch (_) {
      return ModeUpdate(
        '',
        omission: AcpInputOmission(
          reason: AcpInputOmissionReason.invalidStructure,
          resource: 'current_mode',
          truncated: false,
        ),
      );
    }
  }

  /// Current mode id selected by the agent.
  final String currentModeId;

  /// Host-owned reason why a mode field was rejected.
  final AcpInputOmission? omission;

  @override
  String get text => '[Mode: $currentModeId]';
}

AcpStructuredUpdateGuard _updateGuard(
  AcpInputBudget inputBudget,
  AcpStructuredUpdateGuard? structuredGuard,
) =>
    structuredGuard ??
    AcpStructuredUpdateGuard(budget: inputBudget, resource: 'acp_update');

String _omissionIdentity(AcpInputOmission omission) =>
    '${omission.reason.name}\u0000${omission.resource}';

const Object _absentUpdateField = Object();

Object? _firstUpdateValue(Map source, List<String> fields) {
  for (final field in fields) {
    try {
      if (!source.containsKey(field)) continue;
      final value = source[field];
      if (value != null) return value;
    } catch (_) {
      throw const FormatException('Invalid ACP update structure.');
    }
  }
  return _absentUpdateField;
}

int _boundedUsageInt(
  Object? raw,
  AcpStructuredUpdateGuard guard, {
  required String field,
}) {
  if (raw is String) {
    final value = int.tryParse(guard.copyString(raw, field: field).trim());
    if (value == null) throw const FormatException('Invalid ACP usage value.');
    return value;
  }
  final value = guard.copyScalar(raw, field: field);
  if (value is int) return value;
  if (value is double) return value.toInt();
  throw const FormatException('Invalid ACP usage value.');
}

num _boundedUsageNumber(
  Object? raw,
  AcpStructuredUpdateGuard guard, {
  required String field,
}) {
  final value = _tryBoundedUsageNumber(raw, guard, field: field);
  if (value == null) throw const FormatException('Invalid ACP usage value.');
  return value;
}

num? _tryBoundedUsageNumber(
  Object? raw,
  AcpStructuredUpdateGuard guard, {
  required String field,
}) {
  if (raw is String) {
    final value = num.tryParse(guard.copyString(raw, field: field).trim());
    if (value == null) return null;
    if (!value.isFinite) {
      throw const FormatException('Invalid ACP usage value.');
    }
    return value;
  }
  final value = guard.copyScalar(raw, field: field);
  if (value is num) return value;
  throw const FormatException('Invalid ACP usage value.');
}

UsageCost? _boundedUsageCost(Object? raw, AcpStructuredUpdateGuard guard) {
  if (raw is! Map) return null;
  guard.checkCollection(raw, field: 'usage cost');
  guard.consumeEntry(field: 'usage cost');
  final rawAmount = _firstUpdateValue(raw, const <String>['amount']);
  final rawCurrency = _firstUpdateValue(raw, const <String>['currency']);
  final amount = identical(rawAmount, _absentUpdateField)
      ? null
      : _tryBoundedUsageNumber(rawAmount, guard, field: 'usage amount');
  final currency = identical(rawCurrency, _absentUpdateField)
      ? null
      : guard.copyString(rawCurrency, field: 'usage currency').trim();
  if (amount == null || currency == null || currency.isEmpty) return null;
  return UsageCost(amount: amount, currency: currency);
}

Map<String, dynamic>? _boundedUpdateMetadata(
  Map source,
  AcpStructuredUpdateGuard guard, {
  required String field,
}) {
  final raw = _firstUpdateValue(source, const <String>['_meta']);
  if (identical(raw, _absentUpdateField)) return null;
  if (raw is! Map) {
    throw const FormatException('Invalid ACP update metadata.');
  }
  return Map<String, dynamic>.unmodifiable(
    guard.copyMetadata(raw, field: field),
  );
}
