import '../workspace/workspace.dart';
import 'task_record.dart';

enum ResourceType { localDirectory, gitRepo, docsDirectory }

class WorkspaceResource {
  const WorkspaceResource({
    required this.id,
    required this.type,
    required this.label,
    required this.ref,
    this.serial = true,
  });

  factory WorkspaceResource.localDirectory({
    required String id,
    required String label,
    required String path,
    bool serial = true,
  }) {
    final normalizedPath = normalizeWorkspacePath(path);
    return WorkspaceResource(
      id: _requiredText(id, 'id'),
      type: ResourceType.localDirectory,
      label: _requiredText(label, 'label'),
      ref: <String, Object?>{'path': normalizedPath},
      serial: serial,
    );
  }

  factory WorkspaceResource.inferredLocalDirectory(String workspacePath) {
    final path = normalizeWorkspacePath(workspacePath);
    return WorkspaceResource.localDirectory(
      id: 'local_directory:$path',
      label: workspaceNameFromPath(path),
      path: path,
    );
  }

  final String id;
  final ResourceType type;
  final String label;
  final Map<String, Object?> ref;
  final bool serial;

  String get serialGateKey {
    if (!serial) return '';
    return switch (type) {
      ResourceType.localDirectory ||
      ResourceType.gitRepo ||
      ResourceType.docsDirectory => normalizeWorkspacePath(
        ref['path'] is String ? ref['path'] as String : '',
      ),
    };
  }

  static WorkspaceResource? fromJson(Object? raw) {
    final json = _jsonMap(raw);
    if (json == null) return null;
    final id = _stringFromJson(json['id']);
    final type = resourceTypeFromJson(json['type']);
    final label = _stringFromJson(json['label']);
    final ref = _jsonMap(json['ref']);
    final path = ref?['path'];
    if (id == null ||
        type == null ||
        label == null ||
        ref == null ||
        path is! String ||
        path.isEmpty ||
        path.trim() != path) {
      return null;
    }
    return WorkspaceResource(
      id: id,
      type: type,
      label: label,
      ref: Map.unmodifiable(ref),
      serial: json['serial'] is bool ? json['serial'] as bool : true,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'type': type.jsonValue,
      'label': label,
      'ref': ref,
      'serial': serial,
    };
  }
}

WorkspaceResource workspaceResourceForTask(
  TaskRecord task,
  Iterable<WorkspaceResource> resources,
) {
  final resourceId = task.resourceId?.trim();
  if (resourceId != null && resourceId.isNotEmpty) {
    for (final resource in resources) {
      if (resource.id == resourceId) return resource;
    }
  }
  return WorkspaceResource.inferredLocalDirectory(task.workspacePath);
}

String serialGateKeyForTask(
  TaskRecord task,
  Iterable<WorkspaceResource> resources,
) {
  final resource = workspaceResourceForTask(task, resources);
  if (!resource.serial) return '';
  final key = resource.serialGateKey;
  return key.isEmpty ? normalizeWorkspacePath(task.workspacePath) : key;
}

extension ResourceTypeJson on ResourceType {
  String get jsonValue {
    return switch (this) {
      ResourceType.localDirectory => 'local_directory',
      ResourceType.gitRepo => 'git_repo',
      ResourceType.docsDirectory => 'docs_directory',
    };
  }
}

ResourceType? resourceTypeFromJson(Object? raw) {
  return switch (_enumToken(raw)) {
    'local_directory' || 'localdirectory' => ResourceType.localDirectory,
    'git_repo' || 'gitrepo' => ResourceType.gitRepo,
    'docs_directory' || 'docsdirectory' => ResourceType.docsDirectory,
    _ => null,
  };
}

String _requiredText(String value, String fieldName) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    throw ArgumentError.value(value, fieldName, 'Required');
  }
  return trimmed;
}

String? _enumToken(Object? raw) {
  final value = _stringFromJson(raw);
  if (value == null) return null;
  return value.replaceAll('-', '_').trim().toLowerCase();
}

Map<String, Object?>? _jsonMap(Object? raw) {
  if (raw is! Map) return null;
  return <String, Object?>{
    for (final entry in raw.entries)
      if (entry.key is String) entry.key as String: entry.value,
  };
}

String? _stringFromJson(Object? raw) {
  if (raw is! String) return null;
  final trimmed = raw.trim();
  return trimmed.isEmpty ? null : trimmed;
}
