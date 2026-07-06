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
