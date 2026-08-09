import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/storage/app_state_path.dart';

void main() {
  const fileName = 'acp_sessions.sqlite3';

  test('keeps session state beside an app-owned config directory', () {
    expect(
      resolveAppStateFilePath(
        fileName: fileName,
        configPath: _path('tmp', 'profile', 'ianvs-acp', 'settings.json'),
      ),
      _path('tmp', 'profile', 'ianvs-acp', fileName),
    );
    expect(
      resolveAppStateFilePath(
        fileName: fileName,
        configPath: _path('tmp', 'profile', '.ianvs-acp', 'settings.json'),
      ),
      _path('tmp', 'profile', '.ianvs-acp', fileName),
    );
  });

  test('isolates session state for a custom config location', () {
    expect(
      resolveAppStateFilePath(
        fileName: fileName,
        configPath: _path('tmp', 'custom', 'settings.json'),
      ),
      _path('tmp', 'custom', '.ianvs-acp', fileName),
    );
  });

  test('uses XDG_CONFIG_HOME when no config path is provided', () {
    expect(
      resolveAppStateFilePath(
        fileName: fileName,
        environment: {'XDG_CONFIG_HOME': _path('tmp', 'xdg')},
      ),
      _path('tmp', 'xdg', 'ianvs-acp', fileName),
    );
  });

  test('falls back to HOME when XDG_CONFIG_HOME is unavailable', () {
    expect(
      resolveAppStateFilePath(
        fileName: fileName,
        environment: {'HOME': _path('tmp', 'home')},
      ),
      _path('tmp', 'home', '.config', 'ianvs-acp', fileName),
    );
  });

  test('disables persistence only when no state root can be resolved', () {
    expect(
      resolveAppStateFilePath(fileName: fileName, environment: const {}),
      isNull,
    );
  });
}

String _path(
  String first,
  String second, [
  String? third,
  String? fourth,
  String? fifth,
]) {
  final segments = [first, second, third, fourth, fifth].whereType<String>();
  return '${Platform.pathSeparator}${segments.join(Platform.pathSeparator)}';
}
