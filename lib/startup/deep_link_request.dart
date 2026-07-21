import 'dart:io';

enum DeepLinkSource { external }

enum DeepLinkRequestKind { session, task }

class DeepLinkRequest {
  const DeepLinkRequest({
    required this.rawLink,
    required this.source,
    required this.kind,
    this.sessionId,
    this.cwd,
    this.agentName,
    this.taskId,
    this.validationErrors = const <String>[],
  });

  final String rawLink;
  final DeepLinkSource source;
  final DeepLinkRequestKind kind;
  final String? sessionId;
  final String? cwd;
  final String? agentName;
  final String? taskId;
  final List<String> validationErrors;

  static const int maxRawLinkLength = 8 * 1024;

  bool get requiresConfirmation => kind == DeepLinkRequestKind.session;
  bool get canConfirm => validationErrors.isEmpty;
}

class DeepLinkWorkspaceValidation {
  const DeepLinkWorkspaceValidation({required this.path, required this.errors});

  final String? path;
  final List<String> errors;
}

DeepLinkWorkspaceValidation validateDeepLinkWorkspace(String? value) {
  final rawPath = value?.trim();
  if (rawPath == null || rawPath.isEmpty) {
    return const DeepLinkWorkspaceValidation(
      path: null,
      errors: <String>['Workspace is required.'],
    );
  }
  if (!_isAbsolutePath(rawPath)) {
    return DeepLinkWorkspaceValidation(
      path: rawPath,
      errors: const <String>['Workspace must be an absolute path.'],
    );
  }

  final directory = Directory(rawPath);
  if (!directory.existsSync()) {
    return DeepLinkWorkspaceValidation(
      path: rawPath,
      errors: const <String>['Workspace does not exist.'],
    );
  }

  String canonicalPath;
  try {
    canonicalPath = directory.resolveSymbolicLinksSync();
  } on FileSystemException {
    return DeepLinkWorkspaceValidation(
      path: rawPath,
      errors: const <String>['Workspace could not be resolved.'],
    );
  }

  final broadPaths = <String>{Directory('/').resolveSymbolicLinksSync()};
  final home = Platform.environment['HOME']?.trim();
  if (home != null && home.isNotEmpty) {
    final homeDirectory = Directory(home);
    if (homeDirectory.existsSync()) {
      try {
        broadPaths.add(homeDirectory.resolveSymbolicLinksSync());
      } on FileSystemException {
        // An unreadable HOME cannot be selected through its raw path either.
        broadPaths.add(homeDirectory.absolute.path);
      }
    }
  }
  if (broadPaths.contains(canonicalPath)) {
    return DeepLinkWorkspaceValidation(
      path: canonicalPath,
      errors: const <String>['Workspace is too broad.'],
    );
  }

  return DeepLinkWorkspaceValidation(
    path: canonicalPath,
    errors: const <String>[],
  );
}

bool _isAbsolutePath(String path) {
  if (Platform.isWindows) {
    return RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(path) || path.startsWith(r'\\');
  }
  return path.startsWith('/');
}
