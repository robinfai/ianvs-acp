import 'dart:io';
import 'dart:isolate';

/// Builds the native library belonging to the version resolved by this project.
/// Run from the consuming Flutter/Dart project, including from an Xcode phase.
Future<void> main(List<String> arguments) async {
  if (arguments.isNotEmpty) {
    stdout.writeln('Usage: dart run ianvs_acp_runtime:build_macos');
    stdout.writeln(
      'Uses Xcode TARGET_BUILD_DIR/FRAMEWORKS_FOLDER_PATH or '
      'IANVS_ACP_FRAMEWORKS_DIR. Set CONFIGURATION=Release for a universal build. '
      'CARGO_TARGET_DIR overrides the consumer-owned Cargo cache.',
    );
    if (arguments.length != 1 || arguments.single != '--help') exitCode = 64;
    return;
  }
  if (!Platform.isMacOS) {
    stderr.writeln('The ianvs ACP native build currently supports macOS only.');
    exitCode = 64;
    return;
  }
  final library = await Isolate.resolvePackageUri(
    Uri.parse('package:ianvs_acp_runtime/ianvs_acp_runtime.dart'),
  );
  if (library == null || library.scheme != 'file') {
    throw StateError('Cannot resolve ianvs_acp_runtime. Run pub get first.');
  }
  final packageRoot = File.fromUri(library).parent.parent;
  final configuredTarget = Platform.environment['CARGO_TARGET_DIR'];
  final derivedFiles = Platform.environment['DERIVED_FILE_DIR'];
  final buildRoot = derivedFiles?.isNotEmpty == true
      ? derivedFiles!
      : '${Directory.current.path}/build';
  final cargoTarget = configuredTarget?.isNotEmpty == true
      ? configuredTarget!
      : '$buildRoot/ianvs_acp_runtime/cargo';
  // Keep generated files out of the downloaded package in the pub cache.
  final process = await Process.start(
    '/bin/sh',
    ['${packageRoot.path}/tool/build_macos.sh'],
    environment: {'CARGO_TARGET_DIR': cargoTarget},
    mode: ProcessStartMode.inheritStdio,
  );
  exitCode = await process.exitCode;
}
