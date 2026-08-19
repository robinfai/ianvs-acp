import 'dart:collection';

import '../../state/chat_controller.dart';
import '../tool_presentation/tool_presentation_registry.dart';
import '../user_message_projection.dart';

enum SessionActivityKind { prompt, response, tool, status, permission, error }

final class SessionActivityEntry {
  const SessionActivityEntry({
    required this.kind,
    required this.timestamp,
    required this.title,
    required this.detail,
    this.status,
    this.turnId,
    this.toolCallId,
    this.elapsed,
  });

  final SessionActivityKind kind;
  final DateTime timestamp;
  final String title;
  final String detail;
  final String? status;
  final int? turnId;
  final String? toolCallId;
  final Duration? elapsed;
}

final class SessionActivitySnapshot {
  const SessionActivitySnapshot({
    required this.sessionId,
    required this.sessionTemplateIdentity,
    required this.entries,
    required this.lastLatency,
    required this.truncated,
  });

  factory SessionActivitySnapshot.fromController(
    ChatController controller, {
    ToolPresentationRegistry? toolPresentations,
    SessionActivityProjectionCache? projectionCache,
    int maxEntries = 1000,
  }) {
    assert(maxEntries > 0);
    final registry = toolPresentations ?? ToolPresentationRegistry.defaults;
    final session = controller.currentSession;
    if (session == null) {
      return SessionActivitySnapshot(
        sessionId: '',
        sessionTemplateIdentity: null,
        entries: const <SessionActivityEntry>[],
        lastLatency: controller.lastLatency,
        truncated: false,
      );
    }
    final ordered = <({int ordinal, SessionActivityEntry entry})>[];
    var ordinal = 0;

    final visibleMessages = controller.visibleMessages;
    projectionCache?.retainMessages(visibleMessages);
    final latestMessageEntries = <SessionActivityEntry>[];
    var truncated = controller.timelineHistoryWasTruncated;
    for (var index = visibleMessages.length - 1; index >= 0; index -= 1) {
      final message = visibleMessages[index];
      final entry =
          projectionCache?.messageActivity(message, registry) ??
          _messageActivity(message, registry);
      if (entry == null) continue;
      if (latestMessageEntries.length >= maxEntries) {
        truncated = true;
        break;
      }
      latestMessageEntries.add(entry);
    }
    for (final entry in latestMessageEntries.reversed) {
      ordered.add((ordinal: ordinal++, entry: entry));
    }

    final sessionId = session.id.trim();
    final permissions =
        projectionCache?._permissionActivities(
          controller,
          sessionId: sessionId,
          maxEntries: maxEntries,
        ) ??
        _buildPermissionActivities(
          controller,
          sessionId: sessionId,
          maxEntries: maxEntries,
        );
    truncated = truncated || permissions.truncated;
    for (final entry in permissions.entries) {
      ordered.add((ordinal: ordinal++, entry: entry));
    }

    ordered.sort((left, right) {
      final byTime = left.entry.timestamp.compareTo(right.entry.timestamp);
      return byTime == 0 ? left.ordinal.compareTo(right.ordinal) : byTime;
    });
    final start = ordered.length > maxEntries ? ordered.length - maxEntries : 0;
    truncated = truncated || start > 0;
    final templateId = session.sessionTemplateId?.trim();
    final templateVersion = session.sessionTemplateVersion;
    return SessionActivitySnapshot(
      sessionId: session.id,
      sessionTemplateIdentity: templateId == null || templateId.isEmpty
          ? null
          : templateVersion == null
          ? templateId
          : '$templateId@$templateVersion',
      entries: List<SessionActivityEntry>.unmodifiable(
        ordered.skip(start).map((item) => item.entry),
      ),
      lastLatency: controller.lastLatency,
      truncated: truncated,
    );
  }

  final String sessionId;
  final String? sessionTemplateIdentity;
  final List<SessionActivityEntry> entries;
  final Duration? lastLatency;
  final bool truncated;

  int get toolCount =>
      entries.where((entry) => entry.kind == SessionActivityKind.tool).length;

  int get permissionCount => entries
      .where((entry) => entry.kind == SessionActivityKind.permission)
      .length;
}

/// Reuses projections for immutable timeline entries and permission history
/// revisions while a live activity dialog listens to streaming updates.
final class SessionActivityProjectionCache {
  final HashMap<ChatMessage, _CachedMessageActivity> _messages =
      HashMap<ChatMessage, _CachedMessageActivity>.identity();
  ToolPresentationRegistry? _registry;
  int? _permissionRevision;
  String? _permissionSessionId;
  int? _permissionMaxEntries;
  _PermissionActivities? _permissions;

  SessionActivityEntry? messageActivity(
    ChatMessage message,
    ToolPresentationRegistry registry,
  ) {
    if (!identical(_registry, registry)) {
      _messages.clear();
      _registry = registry;
    }
    final cached = _messages[message];
    if (cached != null && cached.revision == message.revision) {
      return cached.entry;
    }
    final entry = _messageActivity(message, registry);
    _messages[message] = _CachedMessageActivity(
      revision: message.revision,
      entry: entry,
    );
    return entry;
  }

  void retainMessages(Iterable<ChatMessage> retainedMessages) {
    final retained = HashSet<ChatMessage>.identity()..addAll(retainedMessages);
    _messages.removeWhere((message, _) => !retained.contains(message));
  }

  _PermissionActivities _permissionActivities(
    ChatController controller, {
    required String sessionId,
    required int maxEntries,
  }) {
    final revision = controller.permissionHistoryRevision;
    final cached = _permissions;
    if (cached != null &&
        _permissionRevision == revision &&
        _permissionSessionId == sessionId &&
        _permissionMaxEntries == maxEntries) {
      return cached;
    }
    final projected = _buildPermissionActivities(
      controller,
      sessionId: sessionId,
      maxEntries: maxEntries,
    );
    _permissionRevision = revision;
    _permissionSessionId = sessionId;
    _permissionMaxEntries = maxEntries;
    _permissions = projected;
    return projected;
  }

  void clear() {
    _messages.clear();
    _permissions = null;
    _permissionRevision = null;
    _permissionSessionId = null;
    _permissionMaxEntries = null;
  }
}

final class _CachedMessageActivity {
  const _CachedMessageActivity({required this.revision, required this.entry});

  final int revision;
  final SessionActivityEntry? entry;
}

final class _PermissionActivities {
  const _PermissionActivities({required this.entries, required this.truncated});

  final List<SessionActivityEntry> entries;
  final bool truncated;
}

_PermissionActivities _buildPermissionActivities(
  ChatController controller, {
  required String sessionId,
  required int maxEntries,
}) {
  if (sessionId.isEmpty) {
    return const _PermissionActivities(entries: [], truncated: false);
  }
  final entries = <SessionActivityEntry>[];
  var truncated = controller.permissionHistoryWasTruncatedForSession(sessionId);
  for (final audit in controller.permissionHistory) {
    if (audit.request.sessionId.trim() != sessionId) continue;
    if (entries.length >= maxEntries) {
      truncated = true;
      break;
    }
    final source = audit.displayDecisionSource;
    final detail = source == null ? '' : 'via $source';
    entries.add(
      SessionActivityEntry(
        kind: SessionActivityKind.permission,
        timestamp: audit.recordedAt,
        title: 'Permission ${audit.displayStatus.toLowerCase()}',
        detail: _singleLine(detail),
        status: audit.status.name,
        toolCallId: audit.request.id,
        elapsed: audit.resolvedAt?.difference(audit.recordedAt),
      ),
    );
  }
  return _PermissionActivities(
    entries: List<SessionActivityEntry>.unmodifiable(entries),
    truncated: truncated,
  );
}

SessionActivityEntry? _messageActivity(
  ChatMessage message,
  ToolPresentationRegistry registry,
) {
  final turnId = _messageTurnId(message);
  switch (message.role) {
    case ChatMessageRole.user:
      final display = userPromptDisplayText(message.text);
      if (display.isEmpty || isAttachmentProjectionText(display)) return null;
      return SessionActivityEntry(
        kind: SessionActivityKind.prompt,
        timestamp: message.timestamp,
        title: 'Prompt',
        detail: _singleLine(display),
        turnId: turnId,
      );
    case ChatMessageRole.assistant:
      return SessionActivityEntry(
        kind: SessionActivityKind.response,
        timestamp: message.timestamp,
        title: 'Assistant response',
        detail: _singleLine(message.previewText),
        turnId: turnId,
      );
    case ChatMessageRole.tool:
      final source = ToolPresentationSource.fromMessage(message);
      final presentation = registry.resolve(source);
      return SessionActivityEntry(
        kind: SessionActivityKind.tool,
        timestamp: message.timestamp,
        title: _singleLine(_safeToolActivityTitle(presentation)),
        detail: '',
        status: _safeToolActivityStatus(source.status),
        turnId: turnId,
        toolCallId: source.id.isEmpty ? null : source.id,
      );
    case ChatMessageRole.status:
      final kind = _metadataString(message.metadata, 'kind');
      return SessionActivityEntry(
        kind: SessionActivityKind.status,
        timestamp: message.timestamp,
        title: _statusTitle(kind),
        detail: '',
        turnId: turnId,
      );
    case ChatMessageRole.error:
      return SessionActivityEntry(
        kind: SessionActivityKind.error,
        timestamp: message.timestamp,
        title: 'Error',
        detail: '',
        status: 'failed',
        turnId: turnId,
      );
  }
}

String? _safeToolActivityStatus(String status) {
  return switch (status.trim().toLowerCase().replaceAll('-', '_')) {
    'pending' || 'queued' => 'pending',
    'in_progress' || 'in progress' || 'running' => 'in progress',
    'completed' ||
    'complete' ||
    'succeeded' ||
    'success' ||
    'done' => 'completed',
    'failed' || 'failure' || 'error' => 'failed',
    'cancelled' || 'canceled' => 'cancelled',
    _ => null,
  };
}

String _safeToolActivityTitle(ToolActivityPresentation presentation) {
  return switch (presentation.kind) {
    ToolActivityKind.run => 'Ran command',
    ToolActivityKind.search => 'Searched',
    ToolActivityKind.load => 'Loaded tool',
    ToolActivityKind.read => 'Read file',
    ToolActivityKind.edit => 'Edited file',
    ToolActivityKind.interact => 'Interacted with tool',
    ToolActivityKind.wait => 'Waited',
    ToolActivityKind.context => 'Updated context',
    ToolActivityKind.generic => 'Used tool',
  };
}

int? _messageTurnId(ChatMessage message) {
  try {
    return message.turnId;
  } on NoSuchMethodError {
    return null;
  }
}

String _statusTitle(String? kind) {
  return switch (kind) {
    'plan' => 'Plan updated',
    'usage_update' => 'Usage updated',
    'assistant_summary' => 'Turn summarized',
    'diff' => 'Workspace diff updated',
    'thought' => 'Reasoning update',
    'turn' => 'Turn status',
    _ => 'Session status',
  };
}

String _singleLine(String value) {
  const maxPreviewCodeUnits = 4096;
  var bounded = value;
  if (bounded.length > maxPreviewCodeUnits) {
    var end = maxPreviewCodeUnits;
    final last = bounded.codeUnitAt(end - 1);
    if (last >= 0xD800 && last <= 0xDBFF) end -= 1;
    bounded = '${bounded.substring(0, end)}…';
  }
  return bounded.trim().replaceAll(RegExp(r'\s+'), ' ');
}

String? _metadataString(Map<String, Object?> metadata, String key) {
  final value = metadata[key];
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}
