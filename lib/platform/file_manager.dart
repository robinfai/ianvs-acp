import 'dart:io';

typedef FileManagerProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);

Future<void> revealPathInFileManager(
  String path, {
  FileManagerProcessRunner? processRunner,
  bool checkExists = true,
}) async {
  final target = path.trim();
  if (target.isEmpty) return;

  var type = FileSystemEntityType.directory;
  if (checkExists) {
    type = await FileSystemEntity.type(target, followLinks: true);
    if (type == FileSystemEntityType.notFound) {
      throw StateError('Path does not exist: $target');
    }
  }

  final runner = processRunner ?? Process.run;
  final command = _fileManagerCommand(target, type);
  final result = await runner(command.executable, command.arguments);
  if (result.exitCode != 0) {
    throw StateError(result.stderr.toString());
  }
}

Future<void> openPathExternally(
  String path, {
  FileManagerProcessRunner? processRunner,
}) async {
  final target = path.trim();
  if (target.isEmpty) return;
  final type = await FileSystemEntity.type(target, followLinks: true);
  if (type == FileSystemEntityType.notFound) {
    throw StateError('Path does not exist: $target');
  }
  await _runOpenTarget(target, processRunner: processRunner);
}

Future<void> openUriExternally(
  Uri uri, {
  FileManagerProcessRunner? processRunner,
}) async {
  if (!const {'http', 'https', 'mailto'}.contains(uri.scheme.toLowerCase())) {
    throw ArgumentError.value(uri, 'uri', 'Unsupported external URI scheme');
  }
  await _runOpenTarget(uri.toString(), processRunner: processRunner);
}

Future<void> _runOpenTarget(
  String target, {
  FileManagerProcessRunner? processRunner,
}) async {
  final runner = processRunner ?? Process.run;
  final ({String executable, List<String> arguments}) command;
  if (Platform.isMacOS) {
    command = (executable: 'open', arguments: <String>[target]);
  } else if (Platform.isWindows) {
    command = (executable: 'explorer', arguments: <String>[target]);
  } else {
    command = (executable: 'xdg-open', arguments: <String>[target]);
  }
  final result = await runner(command.executable, command.arguments);
  if (result.exitCode != 0) {
    throw StateError(result.stderr.toString());
  }
}

({String executable, List<String> arguments}) _fileManagerCommand(
  String target,
  FileSystemEntityType type,
) {
  if (Platform.isMacOS) {
    return type == FileSystemEntityType.directory
        ? (executable: 'open', arguments: [target])
        : (executable: 'open', arguments: ['-R', target]);
  }

  if (Platform.isWindows) {
    return type == FileSystemEntityType.directory
        ? (executable: 'explorer', arguments: [target])
        : (executable: 'explorer', arguments: ['/select,', target]);
  }

  return type == FileSystemEntityType.directory
      ? (executable: 'xdg-open', arguments: [target])
      : (executable: 'xdg-open', arguments: [File(target).parent.path]);
}
