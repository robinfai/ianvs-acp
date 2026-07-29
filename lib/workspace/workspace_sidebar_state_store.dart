import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../acp/agent_session.dart';
import '../acp/session_title.dart';
import '../platform/secure_atomic_file.dart';

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
  static final Map<String, _WorkspaceStateCoordinator> _coordinators =
      <String, _WorkspaceStateCoordinator>{};

  final String? path;
  Future<Map<String, Object?>>? _cachedState;

  static String? defaultPath({
    String? configPath,
    Map<String, String>? environment,
  }) {
    final config = configPath?.trim();
    if (config != null && config.isNotEmpty) {
      return _joinPath(File(config).parent.path, fileName);
    }

    final env = environment ?? Platform.environment;
    final xdgConfigHome = env['XDG_CONFIG_HOME']?.trim();
    if (xdgConfigHome != null && xdgConfigHome.isNotEmpty) {
      return _joinPath(_joinPath(xdgConfigHome, 'ianvs-acp'), fileName);
    }

    final home = env['HOME']?.trim();
    if (home == null || home.isEmpty) return null;
    return _joinPath(
      _joinPath(_joinPath(home, '.config'), 'ianvs-acp'),
      fileName,
    );
  }

  Future<Set<String>> loadExpandedWorkspacePaths() async {
    final state = await _readState();
    final rawPaths =
        state['expanded_workspaces'] ?? state['expandedWorkspacePaths'];
    if (rawPaths is! List) return <String>{};
    return rawPaths
        .whereType<String>()
        .map((path) => path.trim())
        .where((path) => path.isNotEmpty)
        .toSet();
  }

  Future<bool> hasSavedExpandedWorkspacePaths() async {
    final state = await _readState();
    return state.containsKey('expanded_workspaces') ||
        state.containsKey('expandedWorkspacePaths');
  }

  Future<void> saveExpandedWorkspacePaths(Set<String> paths) async {
    final sortedPaths =
        paths
            .map((path) => path.trim())
            .where((path) => path.isNotEmpty)
            .toSet()
            .toList()
          ..sort();

    await _mutate((payload) {
      payload['expanded_workspaces'] = sortedPaths;
      payload.remove('expandedWorkspacePaths');
    });
  }

  Future<List<WorkspaceSidebarWorkspaceState>> loadWorkspaceStates() async {
    final state = await _readState();
    final rawWorkspaces = state['workspace_index'] ?? state['workspaceIndex'];
    if (rawWorkspaces is! List) {
      return const <WorkspaceSidebarWorkspaceState>[];
    }

    final workspaces = <WorkspaceSidebarWorkspaceState>[];
    for (final rawWorkspace in rawWorkspaces) {
      final workspace = _workspaceStateFromJson(rawWorkspace);
      if (workspace != null) workspaces.add(workspace);
    }
    workspaces.sort((a, b) => a.path.compareTo(b.path));
    return List.unmodifiable(workspaces);
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

    final sortedStates = statesByPath.values.toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    await _mutate((payload) {
      payload['workspace_index'] = sortedStates
          .map(_workspaceStateToJson)
          .toList();
      payload.remove('workspaceIndex');
    });
  }

  Future<List<AgentSession>> loadSessionIndex() async {
    final state = await _readState();
    final rawSessions = state['session_index'] ?? state['sessionIndex'];
    if (rawSessions is! List) return const <AgentSession>[];

    final sessions = <AgentSession>[];
    for (final rawSession in rawSessions) {
      final session = _sessionIndexFromJson(rawSession);
      if (session != null) sessions.add(session);
    }
    sessions.sort((a, b) => b.displayTime.compareTo(a.displayTime));
    return List.unmodifiable(sessions);
  }

  Future<void> saveSessionIndex(Iterable<AgentSession> sessions) async {
    final sessionsByKey = <String, AgentSession>{};
    for (final session in sessions) {
      final id = session.id.trim();
      final cwd = session.cwd.trim();
      if (id.isEmpty || cwd.isEmpty) continue;
      sessionsByKey['$cwd\u0000$id'] = session;
    }

    final sortedSessions = sessionsByKey.values.toList()
      ..sort((a, b) => b.displayTime.compareTo(a.displayTime));
    await _mutate((payload) {
      payload['session_index'] = sortedSessions
          .map(_sessionIndexToJson)
          .toList();
      payload.remove('sessionIndex');
    });
  }

  Future<Map<String, Object?>> _readState() async {
    final file = _fileOrNull();
    if (file == null) return <String, Object?>{};
    final cached = _cachedState;
    if (cached != null) return cached;
    final snapshot = _withCoordinator(file, (_) => _readStateFile(file));
    _cachedState = snapshot;
    return snapshot;
  }

  Future<void> _mutate(
    void Function(Map<String, Object?> state) mutation,
  ) async {
    final file = _fileOrNull();
    if (file == null) return;
    await _withCoordinator(file, (_) async {
      final state = await _readStateFile(file);
      mutation(state);

      const encoder = JsonEncoder.withIndent('  ');
      await SecureAtomicFile.writeString(
        file,
        '${encoder.convert(state)}\n',
        protectExistingParent: false,
      );
      _cachedState = Future<Map<String, Object?>>.value(state);
    });
  }

  Future<Map<String, Object?>> _readStateFile(File file) async {
    if (!await file.exists()) return <String, Object?>{};

    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return <String, Object?>{};
      return <String, Object?>{
        for (final entry in decoded.entries)
          if (entry.key is String) entry.key as String: entry.value,
      };
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

  static String _joinPath(String directory, String basename) {
    if (directory.endsWith(Platform.pathSeparator)) {
      return '$directory$basename';
    }
    return '$directory${Platform.pathSeparator}$basename';
  }
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
