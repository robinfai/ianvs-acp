import 'dart:convert';
import 'dart:io';

import '../acp/agent_session.dart';

class WorkspaceSidebarWorkspaceState {
  const WorkspaceSidebarWorkspaceState({
    required this.path,
    this.displayName,
    this.pinned = false,
    this.hidden = false,
  });

  final String path;
  final String? displayName;
  final bool pinned;
  final bool hidden;

  bool get hasCustomState {
    final name = displayName?.trim();
    return pinned || hidden || (name != null && name.isNotEmpty);
  }
}

class WorkspaceSidebarStateStore {
  const WorkspaceSidebarStateStore({required this.path});

  static const String fileName = 'workspace_ui_state.json';

  final String? path;

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

    final payload = await _readState();
    payload['expanded_workspaces'] = sortedPaths;
    await _writeState(payload);
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
      );
    }

    final sortedStates = statesByPath.values.toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    final payload = await _readState();
    payload['workspace_index'] = sortedStates
        .map(_workspaceStateToJson)
        .toList();
    await _writeState(payload);
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
      final agentName = session.agentName?.trim() ?? '';
      sessionsByKey['$agentName\u0000$id'] = session;
    }

    final sortedSessions = sessionsByKey.values.toList()
      ..sort((a, b) => b.displayTime.compareTo(a.displayTime));
    final payload = await _readState();
    payload['session_index'] = sortedSessions.map(_sessionIndexToJson).toList();
    await _writeState(payload);
  }

  Future<Map<String, Object?>> _readState() async {
    final file = _fileOrNull();
    if (file == null || !await file.exists()) return <String, Object?>{};

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

  Future<void> _writeState(Map<String, Object?> payload) async {
    final file = _fileOrNull();
    if (file == null) return;

    const encoder = JsonEncoder.withIndent('  ');

    await file.parent.create(recursive: true);
    await file.writeAsString('${encoder.convert(payload)}\n');
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

    return AgentSession(
      id: id,
      cwd: cwd,
      createdAt: createdAt,
      additionalDirectories: _stringListFromJson(
        json['additional_directories'] ?? json['additionalDirectories'],
      ),
      title: _stringFromJson(json['title']),
      titleOverride: _stringFromJson(
        json['title_override'] ?? json['titleOverride'],
      ),
      updatedAt: updatedAt,
      agentName: _stringFromJson(json['agent_name'] ?? json['agentName']),
      pinned: _boolFromJson(json['pinned']),
      archived: _boolFromJson(json['archived']),
      unread: _boolFromJson(json['unread']),
    );
  }

  Map<String, Object?> _sessionIndexToJson(AgentSession session) {
    final title = session.title?.trim();
    final titleOverride = session.titleOverride?.trim();
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
    };
  }

  String? _stringFromJson(Object? raw) {
    if (raw is! String) return null;
    final trimmed = raw.trim();
    return trimmed.isEmpty ? null : trimmed;
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
