import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/startup/deep_link_request.dart';
import 'package:ianvs_acp/startup/startup_options.dart';

void main() {
  test('StartupOptions parses resume command line flags', () {
    final options = StartupOptions.fromArgs([
      '--resume-session-id',
      ' session-1 ',
      '--resume-cwd=/workspace/project',
      '--resume-agent',
      'Codex',
    ]);

    expect(options.resumeSessionId, 'session-1');
    expect(options.resumeCwd, '/workspace/project');
    expect(options.resumeAgentName, 'Codex');
  });

  test('StartupOptions trusts explicit flags and ignores external links', () {
    final options = StartupOptions.fromArgs([
      'ianvs-acp://session?id=session-from-link&cwd=%2Flink&agent=LinkAgent',
      '--resume-session-id=session-from-flags',
      '--resume-cwd',
      '/flags',
    ]);

    expect(options.resumeSessionId, 'session-from-flags');
    expect(options.resumeCwd, '/flags');
    expect(options.resumeAgentName, isNull);
  });

  test('StartupOptions does not execute deep links from command line args', () {
    final options = StartupOptions.fromArgs([
      '--some-other-flag',
      'ianvs-acp://session?id=session-from-link&cwd=%2Flink',
    ]);

    expect(options.resumeSessionId, isNull);
  });

  test('DeepLinkRequest rejects oversized external links', () {
    final oversized =
        'ianvs-acp://session?id=s1&cwd=%2Ftmp&padding=${'x' * 8192}';

    expect(StartupOptions.fromDeepLink(oversized), isNull);
  });

  test('DeepLinkRequest parses without touching the candidate workspace', () {
    final temp = Directory.systemTemp.createTempSync('ianvs-deep-link-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final workspace = Directory('${temp.path}/workspace')..createSync();
    final alias = Link('${temp.path}/workspace-alias')
      ..createSync(workspace.path);

    final request = StartupOptions.fromDeepLink(
      'ianvs-acp://session?id=session-2&cwd=${Uri.encodeQueryComponent(alias.path)}&agent=Codex',
    );

    expect(request?.source, DeepLinkSource.external);
    expect(request?.sessionId, 'session-2');
    expect(request?.cwd, alias.path);
    expect(request?.agentName, 'Codex');
    expect(request?.validationErrors, isEmpty);
  });

  test('DeepLinkRequest rejects unsafe workspace syntax', () {
    final temp = Directory.systemTemp.createTempSync('ianvs-deep-link-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final missing = '${temp.path}/missing';
    final home = Platform.environment['HOME'];

    DeepLinkRequest requestFor(String cwd) {
      return StartupOptions.fromDeepLink(
        'ianvs-acp://session?id=s1&cwd=${Uri.encodeQueryComponent(cwd)}',
      )!;
    }

    expect(
      requestFor('/').validationErrors,
      contains('Workspace is too broad.'),
    );
    expect(
      requestFor('relative/workspace').validationErrors,
      contains('Workspace must be an absolute path.'),
    );
    expect(requestFor(missing).validationErrors, isEmpty);
    if (home != null && home.trim().isNotEmpty) {
      expect(
        requestFor(home).validationErrors,
        contains('Workspace is too broad.'),
      );
    }

    final rootAlias = Link('${temp.path}/root-alias')..createSync('/');
    expect(requestFor(rootAlias.path).validationErrors, isEmpty);
    if (home != null && home.trim().isNotEmpty) {
      final homeAlias = Link('${temp.path}/home-alias')..createSync(home);
      expect(requestFor(homeAlias.path).validationErrors, isEmpty);
    }
  });

  test(
    'workspace validation resolves aliases only after confirmation',
    () async {
      final temp = Directory.systemTemp.createTempSync('ianvs-deep-link-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final workspace = Directory('${temp.path}/workspace')..createSync();
      final alias = Link('${temp.path}/workspace-alias')
        ..createSync(workspace.path);
      final missing = '${temp.path}/missing';
      final rootAlias = Link('${temp.path}/root-alias')..createSync('/');

      expect(
        (await validateDeepLinkWorkspace(alias.path)).path,
        workspace.resolveSymbolicLinksSync(),
      );
      expect(
        (await validateDeepLinkWorkspace(missing)).errors,
        contains('Workspace does not exist.'),
      );
      expect(
        (await validateDeepLinkWorkspace(rootAlias.path)).errors,
        contains('Workspace is too broad.'),
      );
      final home = Platform.environment['HOME']?.trim();
      if (home != null && home.isNotEmpty) {
        final homeAlias = Link('${temp.path}/home-alias')..createSync(home);
        expect(
          (await validateDeepLinkWorkspace(homeAlias.path)).errors,
          contains('Workspace is too broad.'),
        );
      }
    },
  );

  test('DeepLinkRequest rejects unsupported link targets', () {
    expect(StartupOptions.fromDeepLink('ianvs-acp://unsupported?id=1'), isNull);
  });
}
