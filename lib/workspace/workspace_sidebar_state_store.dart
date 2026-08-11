import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../acp/agent_session.dart';
import '../acp/session_title.dart';
import '../platform/bounded_file_snapshot.dart';
import '../platform/secure_atomic_file.dart';
import '../storage/app_state_path.dart';

class WorkspaceSidebarWorkspaceState {
  const WorkspaceSidebarWorkspaceState({
    required this.path,
    this.displayName,
    this.pinned = false,
    this.hidden = false,
    this.manuallyAdded = false,
  });

  final String path;
  final String? displayName;
  final bool pinned;
  final bool hidden;
  final bool manuallyAdded;

  bool get hasCustomState {
    final name = displayName?.trim();
    return manuallyAdded ||
        pinned ||
        hidden ||
        (name != null && name.isNotEmpty);
  }
}

class WorkspaceSidebarStateStore {
  WorkspaceSidebarStateStore({required this.path});

  static const String fileName = 'workspace_ui_state.json';
  static const int maxStateFileBytes = 16 * 1024 * 1024;
  static final Map<String, _WorkspaceStateCoordinator> _coordinators =
      <String, _WorkspaceStateCoordinator>{};

  final String? path;
  Set<String>? _expandedWorkspacePathsBase;
  Map<String, Map<String, Object?>>? _workspaceIndexBase;
  Map<String, Map<String, Object?>>? _sessionIndexBase;

  static String? defaultPath({
    String? configPath,
    Map<String, String>? environment,
  }) {
    return resolveAppStateFilePath(
      fileName: fileName,
      configPath: configPath,
      environment: environment,
    );
  }

  Future<Set<String>> loadExpandedWorkspacePaths() async {
    final file = _fileOrNull();
    if (file == null) {
      _expandedWorkspacePathsBase = <String>{};
      return <String>{};
    }
    return _withCoordinator(file, (_) async {
      return _synchronizedStateFile(file, (resolvedFile) async {
        final state = await _readStateFile(resolvedFile);
        final paths = _expandedPathsFromState(state);
        _expandedWorkspacePathsBase = Set<String>.of(paths);
        return paths;
      });
    });
  }

  Future<bool> hasSavedExpandedWorkspacePaths() async {
    final state = await _readState();
    return state.containsKey('expanded_workspaces') ||
        state.containsKey('expandedWorkspacePaths');
  }

  Future<void> saveExpandedWorkspacePaths(Set<String> paths) async {
    final desired = paths
        .map((path) => path.trim())
        .where((path) => path.isNotEmpty)
        .toSet();
    final file = _fileOrNull();
    if (file == null) {
      _expandedWorkspacePathsBase = Set<String>.of(desired);
      return;
    }
    await _withCoordinator(file, (_) async {
      await _synchronizedStateFile(file, (resolvedFile) async {
        final state = await _readStateFile(resolvedFile);
        final latest = _expandedPathsFromState(state);
        final base = _expandedWorkspacePathsBase ?? latest;
        final merged = Set<String>.of(latest)
          ..removeAll(base.difference(desired))
          ..addAll(desired.difference(base));
        final sortedPaths = merged.toList()..sort();
        state['expanded_workspaces'] = sortedPaths;
        state.remove('expandedWorkspacePaths');
        await _writeStateFile(resolvedFile, state);
      });
      _expandedWorkspacePathsBase = Set<String>.of(desired);
    });
  }

  Future<List<WorkspaceSidebarWorkspaceState>> loadWorkspaceStates() async {
    final file = _fileOrNull();
    if (file == null) {
      _workspaceIndexBase = <String, Map<String, Object?>>{};
      return const <WorkspaceSidebarWorkspaceState>[];
    }
    return _withCoordinator(file, (_) async {
      return _synchronizedStateFile(file, (resolvedFile) async {
        final state = await _readStateFile(resolvedFile);
        final records = _workspaceIndexRecords(state);
        _workspaceIndexBase = _canonicalWorkspaceIndex(records);
        final workspaces =
            records.values
                .map((record) => record.workspace)
                .toList(growable: false)
              ..sort((a, b) => a.path.compareTo(b.path));
        return List<WorkspaceSidebarWorkspaceState>.unmodifiable(workspaces);
      });
    });
  }

  Future<void> saveWorkspaceStates(
    Iterable<WorkspaceSidebarWorkspaceState> workspaces,
  ) async {
    final statesByPath = <String, WorkspaceSidebarWorkspaceState>{};
    for (final workspace in workspaces) {
      final path = workspace.path.trim();
      if (path.isEmpty || !workspace.hasCustomState) continue;
      statesByPath[path] = WorkspaceSidebarWorkspaceState(
        path: path,
        displayName: workspace.displayName,
        pinned: workspace.pinned,
        hidden: workspace.hidden,
        manuallyAdded: workspace.manuallyAdded,
      );
    }

    final desired = <String, Map<String, Object?>>{
      for (final entry in statesByPath.entries)
        entry.key: _workspaceStateToJson(entry.value),
    };
    final file = _fileOrNull();
    if (file == null) {
      _workspaceIndexBase = _cloneRecordIndex(desired);
      return;
    }
    await _withCoordinator(file, (_) async {
      await _synchronizedStateFile(file, (resolvedFile) async {
        final state = await _readStateFile(resolvedFile);
        final latestRecords = _workspaceIndexRecords(state);
        final base =
            _workspaceIndexBase ?? _canonicalWorkspaceIndex(latestRecords);
        final mergedRecords = _mergeWorkspaceIndex(
          base: base,
          desired: desired,
          latest: latestRecords,
        );
        final sortedRecords = mergedRecords.values.toList()
          ..sort(
            (left, right) =>
                left.workspace.path.compareTo(right.workspace.path),
          );
        state['workspace_index'] = sortedRecords
            .map((record) => record.raw)
            .toList(growable: false);
        state.remove('workspaceIndex');
        await _writeStateFile(resolvedFile, state);
      });
      _workspaceIndexBase = _cloneRecordIndex(desired);
    });
  }

  Future<List<AgentSession>> loadSessionIndex() async {
    final file = _fileOrNull();
    if (file == null) {
      _sessionIndexBase = <String, Map<String, Object?>>{};
      return const <AgentSession>[];
    }
    return _withCoordinator(file, (_) async {
      return _synchronizedStateFile(file, (resolvedFile) async {
        final state = await _readStateFile(resolvedFile);
        final records = _sessionIndexRecords(state);
        _sessionIndexBase = _canonicalSessionIndex(records);
        final sessions =
            records.values
                .map((record) => record.session)
                .toList(growable: false)
              ..sort((a, b) => b.displayTime.compareTo(a.displayTime));
        return List<AgentSession>.unmodifiable(sessions);
      });
    });
  }

  Future<void> saveSessionIndex(Iterable<AgentSession> sessions) async {
    final desired = <String, Map<String, Object?>>{};
    for (final session in sessions) {
      final id = session.id.trim();
      final cwd = session.cwd.trim();
      if (id.isEmpty || cwd.isEmpty) continue;
      final agentName = session.agentName?.trim() ?? '';
      desired['$cwd\u0000$agentName\u0000$id'] = _sessionIndexToJson(session);
    }

    final file = _fileOrNull();
    if (file == null) {
      _sessionIndexBase = _cloneRecordIndex(desired);
      return;
    }
    await _withCoordinator(file, (_) async {
      await _synchronizedStateFile(file, (resolvedFile) async {
        final state = await _readStateFile(resolvedFile);
        final latestRecords = _sessionIndexRecords(state);
        final base = _sessionIndexBase ?? _canonicalSessionIndex(latestRecords);
        final mergedRecords = _mergeSessionIndex(
          base: base,
          desired: desired,
          latest: latestRecords,
        );
        final sortedRecords = mergedRecords.values.toList()
          ..sort(
            (left, right) =>
                right.session.displayTime.compareTo(left.session.displayTime),
          );
        state['session_index'] = sortedRecords
            .map((record) => record.raw)
            .toList(growable: false);
        state.remove('sessionIndex');
        await _writeStateFile(resolvedFile, state);
      });
      _sessionIndexBase = _cloneRecordIndex(desired);
    });
  }

  Future<Map<String, Object?>> _readState() async {
    final file = _fileOrNull();
    if (file == null) return <String, Object?>{};
    return _withCoordinator(
      file,
      (_) => _synchronizedStateFile(file, _readStateFile),
    );
  }

  Future<T> _synchronizedStateFile<T>(
    File file,
    Future<T> Function(File resolvedFile) operation,
  ) {
    return SecureAtomicFile.synchronizedAcrossProcesses(
      file,
      operation,
      strictPrivateParent: true,
    );
  }

  Future<void> _writeStateFile(File file, Map<String, Object?> state) async {
    const encoder = JsonEncoder.withIndent('  ');
    await SecureAtomicFile.writeString(
      file,
      '${encoder.convert(state)}\n',
      protectExistingParent: false,
    );
  }

  Future<Map<String, Object?>> _readStateFile(File file) async {
    if (!await file.exists()) return <String, Object?>{};

    try {
      final decoded = jsonDecode(
        await readBoundedFileStringSnapshot(file, maxBytes: maxStateFileBytes),
      );
      if (decoded is! Map) return <String, Object?>{};
      return <String, Object?>{
        for (final entry in decoded.entries)
          if (entry.key is String) entry.key as String: entry.value,
      };
    } on BoundedFileSnapshotOverflowException {
      rethrow;
    } catch (_) {
      return <String, Object?>{};
    }
  }

  Future<T> _withCoordinator<T>(
    File file,
    Future<T> Function(_WorkspaceStateCoordinator coordinator) operation,
  ) {
    final key = Uri.file(file.absolute.path).normalizePath().toFilePath();
    final coordinator = _coordinators.putIfAbsent(
      key,
      _WorkspaceStateCoordinator.new,
    );
    coordinator.retain();
    return coordinator.schedule(() => operation(coordinator)).whenComplete(() {
      if (coordinator.release() && identical(_coordinators[key], coordinator)) {
        _coordinators.remove(key);
      }
    });
  }

  File? _fileOrNull() {
    final targetPath = path?.trim();
    if (targetPath == null || targetPath.isEmpty) return null;
    return File(targetPath);
  }

  WorkspaceSidebarWorkspaceState? _workspaceStateFromJson(Object? raw) {
    if (raw is! Map) return null;
    final json = <String, Object?>{
      for (final entry in raw.entries)
        if (entry.key is String) entry.key as String: entry.value,
    };

    final path = _stringFromJson(json['path']);
    if (path == null) return null;
    return WorkspaceSidebarWorkspaceState(
      path: path,
      displayName: _stringFromJson(json['display_name'] ?? json['displayName']),
      pinned: _boolFromJson(json['pinned']),
      hidden: _boolFromJson(json['hidden']),
      manuallyAdded: _boolFromJson(
        json['manually_added'] ?? json['manuallyAdded'],
      ),
    );
  }

  Map<String, Object?> _workspaceStateToJson(
    WorkspaceSidebarWorkspaceState workspace,
  ) {
    final displayName = workspace.displayName?.trim();
    return <String, Object?>{
      'path': workspace.path,
      if (displayName != null && displayName.isNotEmpty)
        'display_name': displayName,
      if (workspace.pinned) 'pinned': true,
      if (workspace.hidden) 'hidden': true,
      if (workspace.manuallyAdded) 'manually_added': true,
    };
  }

  Set<String> _expandedPathsFromState(Map<String, Object?> state) {
    final rawPaths =
        state['expanded_workspaces'] ?? state['expandedWorkspacePaths'];
    if (rawPaths is! List) return <String>{};
    return rawPaths
        .whereType<String>()
        .map((path) => path.trim())
        .where((path) => path.isNotEmpty)
        .toSet();
  }

  Map<String, _WorkspaceIndexRecord> _workspaceIndexRecords(
    Map<String, Object?> state,
  ) {
    final rawWorkspaces = state['workspace_index'] ?? state['workspaceIndex'];
    if (rawWorkspaces is! List) return <String, _WorkspaceIndexRecord>{};
    final records = <String, _WorkspaceIndexRecord>{};
    for (final rawWorkspace in rawWorkspaces) {
      final workspace = _workspaceStateFromJson(rawWorkspace);
      if (workspace == null || rawWorkspace is! Map) continue;
      records[workspace.path] = _WorkspaceIndexRecord(
        workspace: workspace,
        raw: _cloneObjectMap(rawWorkspace),
      );
    }
    return records;
  }

  Map<String, Map<String, Object?>> _canonicalWorkspaceIndex(
    Map<String, _WorkspaceIndexRecord> records,
  ) {
    return <String, Map<String, Object?>>{
      for (final entry in records.entries)
        entry.key: _workspaceStateToJson(entry.value.workspace),
    };
  }

  Map<String, _WorkspaceIndexRecord> _mergeWorkspaceIndex({
    required Map<String, Map<String, Object?>> base,
    required Map<String, Map<String, Object?>> desired,
    required Map<String, _WorkspaceIndexRecord> latest,
  }) {
    final merged = <String, _WorkspaceIndexRecord>{
      for (final entry in latest.entries)
        entry.key: _WorkspaceIndexRecord(
          workspace: entry.value.workspace,
          raw: _cloneObjectMap(entry.value.raw),
        ),
    };

    for (final path in base.keys) {
      if (!desired.containsKey(path)) merged.remove(path);
    }
    for (final entry in desired.entries) {
      final path = entry.key;
      final desiredRecord = entry.value;
      final baseRecord = base[path];
      if (baseRecord == null) {
        final workspace = _workspaceStateFromJson(desiredRecord);
        if (workspace != null) {
          merged[path] = _WorkspaceIndexRecord(
            workspace: workspace,
            raw: _cloneObjectMap(desiredRecord),
          );
        }
        continue;
      }
      if (_deepJsonEquals(baseRecord, desiredRecord)) continue;

      final target = merged[path]?.raw ?? _cloneObjectMap(baseRecord);
      for (final field in _workspaceIndexFieldAliases.keys) {
        if (_sameJsonField(baseRecord, desiredRecord, field)) continue;
        for (final alias in _workspaceIndexFieldAliases[field]!) {
          target.remove(alias);
        }
        if (desiredRecord.containsKey(field)) {
          target[field] = _cloneJsonValue(desiredRecord[field]);
        }
      }
      final workspace = _workspaceStateFromJson(target);
      if (workspace != null) {
        merged[path] = _WorkspaceIndexRecord(workspace: workspace, raw: target);
      }
    }
    return merged;
  }

  AgentSession? _sessionIndexFromJson(Object? raw) {
    if (raw is! Map) return null;
    final json = <String, Object?>{
      for (final entry in raw.entries)
        if (entry.key is String) entry.key as String: entry.value,
    };

    final id = _stringFromJson(json['id'] ?? json['session_id']);
    final cwd = _stringFromJson(json['cwd']);
    if (id == null || cwd == null) return null;

    final updatedAt = _dateTimeFromJson(
      json['updated_at'] ?? json['updatedAt'],
    );
    final createdAt =
        _dateTimeFromJson(json['created_at'] ?? json['createdAt']) ??
        updatedAt ??
        DateTime.fromMillisecondsSinceEpoch(0);
    final hasLocalUnstartedMarker =
        json.containsKey('local_unstarted') ||
        json.containsKey('localUnstarted');
    final localUnstarted = hasLocalUnstartedMarker
        ? _boolFromJson(json['local_unstarted'] ?? json['localUnstarted'])
        : updatedAt == null &&
              _sessionTitleFromJson(json['title']) == null &&
              _sessionTitleFromJson(
                    json['title_override'] ?? json['titleOverride'],
                  ) ==
                  null;

    return AgentSession(
      id: id,
      cwd: cwd,
      createdAt: createdAt,
      additionalDirectories: _stringListFromJson(
        json['additional_directories'] ?? json['additionalDirectories'],
      ),
      title: _sessionTitleFromJson(json['title']),
      titleOverride: _sessionTitleFromJson(
        json['title_override'] ?? json['titleOverride'],
      ),
      updatedAt: updatedAt,
      agentName: _stringFromJson(json['agent_name'] ?? json['agentName']),
      pinned: _boolFromJson(json['pinned']),
      archived: _boolFromJson(json['archived']),
      unread: _boolFromJson(json['unread']),
      localUnstarted: localUnstarted,
    );
  }

  Map<String, _SessionIndexRecord> _sessionIndexRecords(
    Map<String, Object?> state,
  ) {
    final rawSessions = state['session_index'] ?? state['sessionIndex'];
    if (rawSessions is! List) return <String, _SessionIndexRecord>{};
    final records = <String, _SessionIndexRecord>{};
    for (final rawSession in rawSessions) {
      final session = _sessionIndexFromJson(rawSession);
      if (session == null || rawSession is! Map) continue;
      final key = _sessionIndexKey(session);
      records[key] = _SessionIndexRecord(
        session: session,
        raw: _cloneObjectMap(rawSession),
      );
    }
    return records;
  }

  Map<String, Map<String, Object?>> _canonicalSessionIndex(
    Map<String, _SessionIndexRecord> records,
  ) {
    return <String, Map<String, Object?>>{
      for (final entry in records.entries)
        entry.key: _sessionIndexToJson(entry.value.session),
    };
  }

  Map<String, _SessionIndexRecord> _mergeSessionIndex({
    required Map<String, Map<String, Object?>> base,
    required Map<String, Map<String, Object?>> desired,
    required Map<String, _SessionIndexRecord> latest,
  }) {
    final merged = <String, _SessionIndexRecord>{
      for (final entry in latest.entries)
        entry.key: _SessionIndexRecord(
          session: entry.value.session,
          raw: _cloneObjectMap(entry.value.raw),
        ),
    };

    for (final key in base.keys) {
      if (!desired.containsKey(key)) merged.remove(key);
    }
    for (final entry in desired.entries) {
      final key = entry.key;
      final desiredRecord = entry.value;
      final baseRecord = base[key];
      if (baseRecord == null) {
        final session = _sessionIndexFromJson(desiredRecord);
        if (session != null) {
          merged[key] = _SessionIndexRecord(
            session: session,
            raw: _cloneObjectMap(desiredRecord),
          );
        }
        continue;
      }
      if (_deepJsonEquals(baseRecord, desiredRecord)) continue;

      final target = merged[key]?.raw ?? _cloneObjectMap(baseRecord);
      for (final field in _sessionIndexFieldAliases.keys) {
        if (_sameJsonField(baseRecord, desiredRecord, field)) continue;
        for (final alias in _sessionIndexFieldAliases[field]!) {
          target.remove(alias);
        }
        if (desiredRecord.containsKey(field)) {
          target[field] = _cloneJsonValue(desiredRecord[field]);
        }
      }
      final session = _sessionIndexFromJson(target);
      if (session != null) {
        merged[key] = _SessionIndexRecord(session: session, raw: target);
      }
    }
    return merged;
  }

  String _sessionIndexKey(AgentSession session) {
    final agentName = session.agentName?.trim() ?? '';
    return '${session.cwd.trim()}\u0000$agentName\u0000${session.id.trim()}';
  }

  Map<String, Object?> _sessionIndexToJson(AgentSession session) {
    final title = normalizeSessionTitle(session.title);
    final titleOverride = normalizeSessionTitle(session.titleOverride);
    final agentName = session.agentName?.trim();
    return <String, Object?>{
      'id': session.id,
      'cwd': session.cwd,
      'created_at': session.createdAt.toIso8601String(),
      if (session.updatedAt != null)
        'updated_at': session.updatedAt!.toIso8601String(),
      if (title != null && title.isNotEmpty) 'title': title,
      if (titleOverride != null && titleOverride.isNotEmpty)
        'title_override': titleOverride,
      if (agentName != null && agentName.isNotEmpty) 'agent_name': agentName,
      if (session.additionalDirectories.isNotEmpty)
        'additional_directories': session.additionalDirectories,
      if (session.pinned) 'pinned': true,
      if (session.archived) 'archived': true,
      if (session.unread) 'unread': true,
      'local_unstarted': session.localUnstarted,
    };
  }

  String? _stringFromJson(Object? raw) {
    if (raw is! String) return null;
    final trimmed = raw.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  String? _sessionTitleFromJson(Object? raw) {
    return raw is String ? normalizeSessionTitle(raw) : null;
  }

  List<String> _stringListFromJson(Object? raw) {
    if (raw is! List) return const <String>[];
    return raw
        .whereType<String>()
        .map((path) => path.trim())
        .where((path) => path.isNotEmpty)
        .toList(growable: false);
  }

  DateTime? _dateTimeFromJson(Object? raw) {
    final value = _stringFromJson(raw);
    if (value == null) return null;
    return DateTime.tryParse(value)?.toLocal();
  }

  bool _boolFromJson(Object? raw) {
    return raw == true;
  }
}

const Map<String, List<String>> _workspaceIndexFieldAliases =
    <String, List<String>>{
      'path': <String>['path'],
      'display_name': <String>['display_name', 'displayName'],
      'pinned': <String>['pinned'],
      'hidden': <String>['hidden'],
      'manually_added': <String>['manually_added', 'manuallyAdded'],
    };

const Map<String, List<String>> _sessionIndexFieldAliases =
    <String, List<String>>{
      'id': <String>['id', 'session_id'],
      'cwd': <String>['cwd'],
      'created_at': <String>['created_at', 'createdAt'],
      'updated_at': <String>['updated_at', 'updatedAt'],
      'title': <String>['title'],
      'title_override': <String>['title_override', 'titleOverride'],
      'agent_name': <String>['agent_name', 'agentName'],
      'additional_directories': <String>[
        'additional_directories',
        'additionalDirectories',
      ],
      'pinned': <String>['pinned'],
      'archived': <String>['archived'],
      'unread': <String>['unread'],
      'local_unstarted': <String>['local_unstarted', 'localUnstarted'],
    };

bool _sameJsonField(
  Map<String, Object?> left,
  Map<String, Object?> right,
  String field,
) {
  if (left.containsKey(field) != right.containsKey(field)) return false;
  return !left.containsKey(field) || _deepJsonEquals(left[field], right[field]);
}

bool _deepJsonEquals(Object? left, Object? right) {
  return jsonEncode(left) == jsonEncode(right);
}

Object? _cloneJsonValue(Object? value) => jsonDecode(jsonEncode(value));

Map<String, Object?> _cloneObjectMap(Map value) {
  return jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
}

Map<String, Map<String, Object?>> _cloneRecordIndex(
  Map<String, Map<String, Object?>> source,
) {
  return <String, Map<String, Object?>>{
    for (final entry in source.entries) entry.key: _cloneObjectMap(entry.value),
  };
}

class _WorkspaceIndexRecord {
  const _WorkspaceIndexRecord({required this.workspace, required this.raw});

  final WorkspaceSidebarWorkspaceState workspace;
  final Map<String, Object?> raw;
}

class _SessionIndexRecord {
  const _SessionIndexRecord({required this.session, required this.raw});

  final AgentSession session;
  final Map<String, Object?> raw;
}

class WorkspaceSessionIndexPersistenceQueue {
  WorkspaceSessionIndexPersistenceQueue({required this.store});

  final WorkspaceSidebarStateStore store;

  _PendingSessionIndex? _pending;
  Future<void>? _drainFuture;
  String? _persistedSignature;

  Future<void> get idle => _drainFuture ?? Future<void>.value();

  void enqueue({
    required Iterable<AgentSession> sessions,
    required String signature,
  }) {
    if (_drainFuture == null && signature == _persistedSignature) return;
    _pending = _PendingSessionIndex(
      sessions: List<AgentSession>.unmodifiable(sessions),
      signature: signature,
    );
    _startDrain();
  }

  void _startDrain() {
    if (_drainFuture != null) return;
    final completion = Completer<void>();
    _drainFuture = completion.future;
    scheduleMicrotask(() {
      unawaited(_runDrain(completion));
    });
  }

  Future<void> _runDrain(Completer<void> completion) async {
    try {
      await _drain();
    } catch (_) {
      // Keep sidebar persistence best effort even for an unexpected store
      // implementation failure.
    }
    _drainFuture = null;
    if (_pending != null) {
      _startDrain();
      await _drainFuture;
    }
    completion.complete();
  }

  Future<void> _drain() async {
    while (true) {
      final pending = _pending;
      if (pending == null) break;
      _pending = null;
      if (pending.signature == _persistedSignature) continue;
      try {
        await store.saveSessionIndex(pending.sessions);
      } catch (_) {
        // The app treats sidebar persistence as best effort. Keep the last
        // successful signature so a later enqueue retries failed state.
        continue;
      }
      _persistedSignature = pending.signature;
    }
  }
}

class _PendingSessionIndex {
  const _PendingSessionIndex({required this.sessions, required this.signature});

  final List<AgentSession> sessions;
  final String signature;
}

class _WorkspaceStateCoordinator {
  Future<void> _tail = Future<void>.value();
  int _references = 0;

  void retain() => _references += 1;

  bool release() {
    _references -= 1;
    return _references == 0;
  }

  Future<T> schedule<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }
}
