import 'dart:async';
import 'dart:io';

enum DeepLinkSource { external }

enum DeepLinkRequestKind { session }

class DeepLinkRequest {
  const DeepLinkRequest({
    required this.rawLink,
    required this.source,
    required this.kind,
    this.sessionId,
    this.cwd,
    this.agentName,
    this.validationErrors = const <String>[],
  });

  final String rawLink;
  final DeepLinkSource source;
  final DeepLinkRequestKind kind;
  final String? sessionId;
  final String? cwd;
  final String? agentName;
  final List<String> validationErrors;

  static const int maxRawLinkLength = 8 * 1024;

  bool get requiresConfirmation => true;
  bool get canConfirm => validationErrors.isEmpty;
}

class DeepLinkWorkspaceValidation {
  const DeepLinkWorkspaceValidation({required this.path, required this.errors});

  final String? path;
  final List<String> errors;
}

DeepLinkWorkspaceValidation validateDeepLinkWorkspaceSyntax(String? value) {
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

  if (_isLexicallyBroadPath(rawPath)) {
    return DeepLinkWorkspaceValidation(
      path: rawPath,
      errors: const <String>['Workspace is too broad.'],
    );
  }

  return DeepLinkWorkspaceValidation(path: rawPath, errors: const <String>[]);
}

Future<DeepLinkWorkspaceValidation> validateDeepLinkWorkspace(
  String? value, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final syntax = validateDeepLinkWorkspaceSyntax(value);
  if (syntax.errors.isNotEmpty || syntax.path == null) return syntax;
  final rawPath = syntax.path!;

  final directory = Directory(rawPath);
  bool exists;
  try {
    exists = await directory.exists().timeout(timeout);
  } on TimeoutException {
    return DeepLinkWorkspaceValidation(
      path: rawPath,
      errors: const <String>['Workspace validation timed out.'],
    );
  }
  if (!exists) {
    return DeepLinkWorkspaceValidation(
      path: rawPath,
      errors: const <String>['Workspace does not exist.'],
    );
  }

  String canonicalPath;
  try {
    canonicalPath = await directory.resolveSymbolicLinks().timeout(timeout);
  } on Object {
    return DeepLinkWorkspaceValidation(
      path: rawPath,
      errors: const <String>['Workspace could not be resolved.'],
    );
  }

  if (_isLexicallyBroadPath(canonicalPath)) {
    return DeepLinkWorkspaceValidation(
      path: canonicalPath,
      errors: const <String>['Workspace is too broad.'],
    );
  }

  final broadPaths = <String>{};
  try {
    broadPaths.add(
      await Directory('/').resolveSymbolicLinks().timeout(timeout),
    );
  } on Object {
    broadPaths.add(Directory('/').absolute.path);
  }
  for (final home in _platformHomePaths()) {
    final homeDirectory = Directory(home);
    if (await homeDirectory.exists().timeout(timeout, onTimeout: () => false)) {
      try {
        broadPaths.add(
          await homeDirectory.resolveSymbolicLinks().timeout(timeout),
        );
      } on Object {
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

bool _isLexicallyBroadPath(String path) {
  if (Platform.isWindows) {
    final normalized = path.replaceAll('/', r'\').toLowerCase();
    return RegExp(r'^[a-z]:\\?$').hasMatch(normalized) ||
        RegExp(r'^\\\\[^\\]+\\[^\\]+\\?$').hasMatch(normalized) ||
        _platformHomePaths().any(
          (home) => normalized == home.replaceAll('/', r'\').toLowerCase(),
        );
  }
  return path == '/' || _platformHomePaths().contains(path);
}

Set<String> _platformHomePaths() {
  final environment = Platform.environment;
  final homes = <String>{};
  void add(String? value) {
    final trimmed = value?.trim();
    if (trimmed != null && trimmed.isNotEmpty) homes.add(trimmed);
  }

  add(environment['HOME']);
  if (Platform.isWindows) {
    add(environment['USERPROFILE']);
    final drive = environment['HOMEDRIVE']?.trim();
    final path = environment['HOMEPATH']?.trim();
    if (drive != null && drive.isNotEmpty && path != null && path.isNotEmpty) {
      add('$drive$path');
    }
  }
  return homes;
}

bool _isAbsolutePath(String path) {
  if (Platform.isWindows) {
    return RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(path) || path.startsWith(r'\\');
  }
  return path.startsWith('/');
}
