import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_acp/dart_acp.dart' as acp;
import 'package:dart_acp/src/providers/secure_fs_reader.dart';
import 'package:dart_acp/src/rpc/peer.dart' show JsonRpcPeer;
import 'package:dart_acp/src/session/session_manager.dart' show SessionManager;
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/acp_permission_request.dart';
import 'package:ianvs_acp/acp/dart_acp_agent_client.dart';
import 'package:stream_channel/stream_channel.dart';

void main() {
  group('DefaultFsProvider readTextFile', () {
    test('secure reader rejects invalid budgets before native reads', () async {
      final temp = await Directory.systemTemp.createTemp('acp-secure-budget-');
      addTearDown(() => temp.delete(recursive: true));
      final file = File('${temp.path}/value.txt');
      await file.writeAsString('x');

      await expectLater(
        readSecureTextFile(
          canonicalRoot: temp.path,
          relativePath: 'value.txt',
          maxReadBytes: 0,
          maxReturnedBytes: 1,
          line: null,
          limit: null,
        ),
        throwsArgumentError,
      );
      await expectLater(
        readSecureTextFile(
          canonicalRoot: temp.path,
          relativePath: 'value.txt',
          maxReadBytes: -1,
          maxReturnedBytes: 1,
          line: null,
          limit: null,
        ),
        throwsArgumentError,
      );
      await expectLater(
        readSecureTextFile(
          canonicalRoot: temp.path,
          relativePath: 'value.txt',
          maxReadBytes: 1,
          maxReturnedBytes: 0,
          line: null,
          limit: null,
        ),
        throwsArgumentError,
      );
      await expectLater(
        readSecureTextFile(
          canonicalRoot: temp.path,
          relativePath: 'value.txt',
          maxReadBytes: 1,
          maxReturnedBytes: -1,
          line: null,
          limit: null,
        ),
        throwsArgumentError,
      );
      await expectLater(
        readSecureTextFile(
          canonicalRoot: temp.path,
          relativePath: 'value.txt',
          maxReadBytes: 1,
          maxReturnedBytes: 2,
          line: null,
          limit: null,
        ),
        throwsArgumentError,
      );
    });

    test('defaults to at most two simultaneous filesystem reads', () {
      expect(acp.defaultFsConcurrentReadLimit, 2);
      expect(acp.DefaultFsProvider(workspaceRoot: '/').maxConcurrentReads, 2);
    });

    test('keeps the unnamed constructor available to subclasses', () async {
      final temp = await Directory.systemTemp.createTemp('acp-fs-subclass-');
      addTearDown(() => temp.delete(recursive: true));
      final file = File('${temp.path}/value.txt');
      await file.writeAsString('subclass');
      final provider = _SubclassedDefaultFsProvider(workspaceRoot: temp.path);

      expect(await provider.readTextFile(file.path), 'subclass');
    });

    test('validates read, return, and aggregate budgets', () {
      expect(
        () => acp.DefaultFsProvider(workspaceRoot: '/', maxReadBytes: 0),
        throwsArgumentError,
      );
      expect(
        () => acp.DefaultFsProvider(workspaceRoot: '/', maxReturnedBytes: 0),
        throwsArgumentError,
      );
      expect(
        () => acp.DefaultFsProvider(
          workspaceRoot: '/',
          maxReadBytes: 4,
          maxReturnedBytes: 5,
        ),
        throwsArgumentError,
      );
      expect(
        () => acp.DefaultFsProvider(workspaceRoot: '/', maxConcurrentReads: 0),
        throwsArgumentError,
      );
      expect(
        () => acp.DefaultFsProvider(
          workspaceRoot: '/',
          maxReadBytes: 64,
          maxReturnedBytes: 32,
          maxAggregateReadBytes: 32,
        ),
        throwsArgumentError,
      );
    });

    test('separates scan bytes from selected return bytes', () async {
      final temp = await Directory.systemTemp.createTemp('acp-fs-return-');
      addTearDown(() => temp.delete(recursive: true));
      final ranged = File('${temp.path}/ranged.txt');
      final exact = File('${temp.path}/exact.txt');
      final over = File('${temp.path}/over.txt');
      await ranged.writeAsString('123456789\nok');
      await exact.writeAsString('1234');
      await over.writeAsString('12345');
      final provider = acp.DefaultFsProvider(
        workspaceRoot: temp.path,
        maxReadBytes: 32,
        maxReturnedBytes: 4,
      );

      expect(await provider.readTextFile(ranged.path, line: 2, limit: 1), 'ok');
      expect(await provider.readTextFile(exact.path), '1234');
      await expectLater(
        provider.readTextFile(over.path),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('shares concurrent read capacity across bound providers', () async {
      final temp = await Directory.systemTemp.createTemp('acp-fs-concurrent-');
      addTearDown(() => temp.delete(recursive: true));
      final firstRoot = Directory('${temp.path}/first');
      final secondRoot = Directory('${temp.path}/second');
      await firstRoot.create();
      await secondRoot.create();
      await File('${firstRoot.path}/value.txt').writeAsString('first');
      await File('${secondRoot.path}/value.txt').writeAsString('second');
      final marker = acp.DefaultFsProvider(
        workspaceRoot: '/',
        maxReadBytes: 128 * 1024,
        maxReturnedBytes: 64 * 1024,
        maxConcurrentReads: 1,
      );
      final first = marker.bindToSession(
        workspaceRoot: firstRoot.path,
        allowReadOutsideWorkspace: false,
      );
      final second = marker.bindToSession(
        workspaceRoot: secondRoot.path,
        allowReadOutsideWorkspace: false,
      );

      final active = first.readTextFile('value.txt');
      await expectLater(
        second.readTextFile('value.txt'),
        throwsA(isA<FileSystemException>()),
      );
      expect(await active, 'first');
      expect(await second.readTextFile('value.txt'), 'second');
    });

    test(
      'enforces aggregate read capacity and releases after errors',
      () async {
        final temp = await Directory.systemTemp.createTemp('acp-fs-aggregate-');
        addTearDown(() => temp.delete(recursive: true));
        final valid = File('${temp.path}/valid.txt');
        final invalid = File('${temp.path}/invalid.txt');
        await valid.writeAsString('valid');
        await invalid.writeAsBytes(const <int>[0xff]);
        final provider = acp.DefaultFsProvider(
          workspaceRoot: temp.path,
          maxReadBytes: 64 * 1024,
          maxReturnedBytes: 32 * 1024,
          maxConcurrentReads: 2,
          maxAggregateReadBytes: 96 * 1024,
        );

        final active = provider.readTextFile(valid.path);
        await expectLater(
          provider.readTextFile(valid.path),
          throwsA(isA<FileSystemException>()),
        );
        expect(await active, 'valid');
        await expectLater(
          provider.readTextFile(invalid.path),
          throwsA(anything),
        );
        expect(await provider.readTextFile(valid.path), 'valid');
      },
    );

    test(
      'small scan budgets reserve only their actual native buffers',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'acp-fs-small-budget-',
        );
        addTearDown(() => temp.delete(recursive: true));
        final file = File('${temp.path}/value.txt');
        await file.writeAsString('x');
        final provider = acp.DefaultFsProvider(
          workspaceRoot: temp.path,
          maxReadBytes: 1,
          maxReturnedBytes: 1,
          maxConcurrentReads: 8,
          maxAggregateReadBytes: 9,
        );

        final reads = List<Future<String>>.generate(
          4,
          (_) => provider.readTextFile(file.path),
        );
        final rejected = expectLater(
          reads[3],
          throwsA(
            isA<acp.FsReadRejectedException>().having(
              (error) => error.reason,
              'reason',
              acp.FsReadRejectionReason.capacity,
            ),
          ),
        );

        expect(await reads[0], 'x');
        expect(await reads[1], 'x');
        expect(await reads[2], 'x');
        await rejected;
        expect(await provider.readTextFile(file.path), 'x');
      },
    );

    test(
      'accepts the exact byte boundary and rejects limit plus one',
      () async {
        final temp = await Directory.systemTemp.createTemp('acp-fs-budget-');
        addTearDown(() => temp.delete(recursive: true));
        final exact = File('${temp.path}/exact.txt');
        final over = File('${temp.path}/over.txt');
        await exact.writeAsString('1234');
        await over.writeAsString('12345');
        final provider = acp.DefaultFsProvider(
          workspaceRoot: temp.path,
          maxReadBytes: 4,
        );

        expect(await provider.readTextFile(exact.path), '1234');
        await expectLater(
          provider.readTextFile(over.path),
          throwsA(isA<FileSystemException>()),
        );
      },
    );

    test('rejects an overlong unterminated requested line', () async {
      final temp = await Directory.systemTemp.createTemp('acp-fs-long-line-');
      addTearDown(() => temp.delete(recursive: true));
      final file = File('${temp.path}/long.txt');
      await file.writeAsString('12345');
      final provider = acp.DefaultFsProvider(
        workspaceRoot: temp.path,
        maxReadBytes: 4,
      );

      await expectLater(
        provider.readTextFile(file.path, limit: 1),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('stops after requested line before later malformed UTF-8', () async {
      final temp = await Directory.systemTemp.createTemp('acp-fs-range-');
      addTearDown(() => temp.delete(recursive: true));
      final file = File('${temp.path}/mixed.txt');
      await file.writeAsBytes(<int>[...utf8.encode('first\n'), 0xff]);
      final provider = acp.DefaultFsProvider(
        workspaceRoot: temp.path,
        maxReadBytes: 64,
      );

      expect(await provider.readTextFile(file.path, limit: 1), 'first');
    });

    test('preserves UTF-8 split boundaries and selected line ranges', () async {
      final temp = await Directory.systemTemp.createTemp('acp-fs-utf8-');
      addTearDown(() => temp.delete(recursive: true));
      final boundaryText = '${'a' * (64 * 1024 - 1)}🙂';
      final boundaryFile = File('${temp.path}/boundary.txt');
      final linesFile = File('${temp.path}/lines.txt');
      await boundaryFile.writeAsString(boundaryText);
      await linesFile.writeAsString('one\n两🙂\nthree');
      final provider = acp.DefaultFsProvider(
        workspaceRoot: temp.path,
        maxReadBytes: utf8.encode(boundaryText).length,
      );

      expect(await provider.readTextFile(boundaryFile.path), boundaryText);
      expect(
        await provider.readTextFile(linesFile.path, line: 2, limit: 1),
        '两🙂',
      );
    });

    test('session binding preserves read policy and byte budget', () async {
      final temp = await Directory.systemTemp.createTemp('acp-fs-binding-');
      addTearDown(() => temp.delete(recursive: true));
      final outside = File('${temp.path}/outside.txt');
      final oversizedOutside = File('${temp.path}/oversized.txt');
      final workspace = Directory('${temp.path}/workspace');
      await outside.writeAsString('1234');
      await oversizedOutside.writeAsString('12345');
      await workspace.create();
      final marker = acp.DefaultFsProvider(
        workspaceRoot: '/',
        allowReadOutsideWorkspace: true,
        maxReadBytes: 4,
        maxReturnedBytes: 4,
      );

      final bound = marker.bindToSession(
        workspaceRoot: workspace.path,
        allowReadOutsideWorkspace: true,
      );

      expect(bound, isA<acp.DefaultFsProvider>());
      final defaultBound = bound as acp.DefaultFsProvider;
      expect(defaultBound.workspaceRoot, workspace.path);
      expect(defaultBound.allowReadOutsideWorkspace, isTrue);
      expect(defaultBound.maxReadBytes, 4);
      expect(defaultBound.maxReturnedBytes, 4);
      expect(await defaultBound.readTextFile(outside.path), '1234');
      await expectLater(
        defaultBound.readTextFile(oversizedOutside.path),
        throwsA(isA<FileSystemException>()),
      );
    });

    test(
      'allows safe symlinks and rejects links outside the workspace',
      () async {
        final temp = await Directory.systemTemp.createTemp('acp-fs-type-');
        addTearDown(() => temp.delete(recursive: true));
        final workspace = Directory('${temp.path}/workspace');
        final realDirectory = Directory('${workspace.path}/real');
        final outside = Directory('${temp.path}/outside');
        await realDirectory.create(recursive: true);
        await outside.create();
        final regular = File('${realDirectory.path}/regular.txt');
        final finalSymlink = Link('${workspace.path}/linked.txt');
        final directorySymlink = Link('${workspace.path}/linked-directory');
        final outsideFile = File('${outside.path}/outside.txt');
        final outsideSymlink = Link('${workspace.path}/outside-link.txt');
        await regular.writeAsString('safe');
        await outsideFile.writeAsString('outside');
        await finalSymlink.create(regular.path);
        await directorySymlink.create(realDirectory.path);
        await outsideSymlink.create(outsideFile.path);
        final provider = acp.DefaultFsProvider(workspaceRoot: workspace.path);

        expect(await provider.readTextFile(finalSymlink.path), 'safe');
        expect(
          await provider.readTextFile('${directorySymlink.path}/regular.txt'),
          'safe',
        );
        await expectLater(
          provider.readTextFile(outsideSymlink.path),
          throwsA(isA<FileSystemException>()),
        );
      },
    );

    test(
      'fails closed when a canonical target is replaced by a link',
      () async {
        final temp = await Directory.systemTemp.createTemp('acp-fs-swap-file-');
        addTearDown(() => temp.delete(recursive: true));
        final workspace = Directory('${temp.path}/workspace');
        final target = File('${workspace.path}/target.txt');
        final outside = File('${temp.path}/outside.txt');
        await workspace.create();
        await target.writeAsString('inside');
        await outside.writeAsString('outside');
        final canonicalRoot = await workspace.resolveSymbolicLinks();
        await target.delete();
        await Link(target.path).create(outside.path);

        await expectLater(
          readSecureTextFile(
            canonicalRoot: canonicalRoot,
            relativePath: 'target.txt',
            maxReadBytes: 1024,
            maxReturnedBytes: 1024,
            line: null,
            limit: null,
          ),
          throwsA(isA<FileSystemException>()),
        );
      },
    );

    test(
      'fails closed when a canonical directory is replaced by a link',
      () async {
        final temp = await Directory.systemTemp.createTemp('acp-fs-swap-dir-');
        addTearDown(() => temp.delete(recursive: true));
        final workspace = Directory('${temp.path}/workspace');
        final targetDirectory = Directory('${workspace.path}/target');
        final outsideDirectory = Directory('${temp.path}/outside');
        await targetDirectory.create(recursive: true);
        await outsideDirectory.create();
        await File('${targetDirectory.path}/value.txt').writeAsString('inside');
        await File(
          '${outsideDirectory.path}/value.txt',
        ).writeAsString('outside');
        final canonicalRoot = await workspace.resolveSymbolicLinks();
        await targetDirectory.delete(recursive: true);
        await Link(targetDirectory.path).create(outsideDirectory.path);

        await expectLater(
          readSecureTextFile(
            canonicalRoot: canonicalRoot,
            relativePath: 'target/value.txt',
            maxReadBytes: 1024,
            maxReturnedBytes: 1024,
            line: null,
            limit: null,
          ),
          throwsA(isA<FileSystemException>()),
        );
      },
    );

    test('securely reads a configured additional workspace root', () async {
      final temp = await Directory.systemTemp.createTemp('acp-fs-extra-');
      addTearDown(() => temp.delete(recursive: true));
      final workspace = Directory('${temp.path}/workspace');
      final additional = Directory('${temp.path}/additional');
      await workspace.create();
      await additional.create();
      final file = File('${additional.path}/value.txt');
      await file.writeAsString('additional');
      final provider = acp.DefaultFsProvider(
        workspaceRoot: workspace.path,
        additionalWorkspaceRoots: <String>[additional.path],
      );

      expect(await provider.readTextFile(file.path), 'additional');
    });

    test('rejects non-regular files without waiting on them', () async {
      final temp = await Directory.systemTemp.createTemp('acp-fs-type-');
      addTearDown(() => temp.delete(recursive: true));
      final fifoPath = '${temp.path}/fifo';
      final mkfifo = await Process.run('mkfifo', <String>[fifoPath]);
      expect(mkfifo.exitCode, 0, reason: mkfifo.stderr.toString());
      final provider = acp.DefaultFsProvider(workspaceRoot: temp.path);

      await expectLater(
        provider.readTextFile(fifoPath).timeout(const Duration(seconds: 1)),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(
        acp.DefaultFsProvider(
          workspaceRoot: '/',
        ).readTextFile('/dev/null').timeout(const Duration(seconds: 1)),
        throwsA(isA<FileSystemException>()),
      );
    });
  });

  group('SessionManager filesystem provider wiring', () {
    test(
      'keeps LineJsonChannel usable after bounded large file responses',
      () async {
        final temp = await Directory.systemTemp.createTemp('acp-fs-line-');
        addTearDown(() => temp.delete(recursive: true));
        final workspace = Directory('${temp.path}/workspace');
        await workspace.create();
        final nullFile = File('${workspace.path}/nulls.txt');
        final oversizedFile = File('${workspace.path}/oversized.txt');
        final smallFile = File('${workspace.path}/small.txt');
        final summaryFile = File('${temp.path}/summary.json');
        await _writeRepeatedByte(nullFile, 0, 2 * 1024 * 1024);
        await _writeRepeatedByte(oversizedFile, 0x61, 16 * 1024 * 1024);
        await smallFile.writeAsString('ok');
        final script = File('${temp.path}/agent.dart');
        final nullPath = jsonEncode(nullFile.path);
        final oversizedPath = jsonEncode(oversizedFile.path);
        final smallPath = jsonEncode(smallFile.path);
        final summaryPath = jsonEncode(summaryFile.path);
        await script.writeAsString('''
import 'dart:convert';
import 'dart:io';

void send(Map<String, dynamic> message) {
  stdout.writeln(jsonEncode(message));
}

void request(String id, String path) {
  send(<String, dynamic>{
    'jsonrpc': '2.0',
    'id': id,
    'method': 'fs/read_text_file',
    'params': <String, dynamic>{
      'sessionId': 'line-session',
      'path': path,
    },
  });
}

Future<void> main() async {
  var nullPayloadValid = false;
  var oversizedHasError = false;
  var oversizedHasResult = false;
  var oversizedEncodedLength = 0;
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      send(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{},
          'authMethods': <Map<String, dynamic>>[],
        },
      });
    } else if (message['method'] == 'session/new') {
      send(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'sessionId': 'line-session'},
      });
      request('read-nulls', $nullPath);
    } else if (message['id'] == 'read-nulls') {
      final result = message['result'] as Map<String, dynamic>?;
      final content = result?['content'] as String?;
      nullPayloadValid = content != null &&
          content.length == 2 * 1024 * 1024 &&
          content.codeUnits.every((value) => value == 0);
      request('read-oversized', $oversizedPath);
    } else if (message['id'] == 'read-oversized') {
      final encoded = jsonEncode(message);
      oversizedHasError = message.containsKey('error');
      oversizedHasResult = message.containsKey('result');
      oversizedEncodedLength = encoded.length;
      request('read-small', $smallPath);
    } else if (message['id'] == 'read-small') {
      final result = message['result'] as Map<String, dynamic>?;
      await File($summaryPath).writeAsString(jsonEncode(<String, dynamic>{
        'nullPayloadValid': nullPayloadValid,
        'oversizedHasError': oversizedHasError,
        'oversizedHasResult': oversizedHasResult,
        'oversizedEncodedLength': oversizedEncodedLength,
        'followUpContent': result?['content'],
      }));
    }
  }
}
''');
        late final DartAcpAgentClient client;
        client = DartAcpAgentClient(
          agentCommand: _dartExecutable(),
          agentArgs: <String>[script.path],
          enableFilesystemReadTextFile: true,
        );
        final subscription = client.permissionRequests.listen((request) {
          unawaited(
            client.respondToPermissionRequest(
              id: request.id,
              decision: AcpPermissionDecision.allow,
            ),
          );
        });
        addTearDown(() async {
          await subscription.cancel();
          await client.dispose();
        });

        await client.connect().timeout(const Duration(seconds: 10));
        await client.createSession(cwd: workspace.path);
        await _waitForFile(summaryFile, timeout: const Duration(seconds: 20));
        final summary = jsonDecode(await summaryFile.readAsString());

        expect(summary['nullPayloadValid'], isTrue);
        expect(summary['oversizedHasError'], isTrue);
        expect(summary['oversizedHasResult'], isFalse);
        expect(summary['oversizedEncodedLength'], lessThan(1024));
        expect(summary['followUpContent'], 'ok');
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'bounds concurrent large responses while the agent pauses stdin',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'acp-fs-line-backpressure-',
        );
        addTearDown(() => temp.delete(recursive: true));
        final workspace = Directory('${temp.path}/workspace');
        await workspace.create();
        final nullFile = File('${workspace.path}/nulls.txt');
        final smallFile = File('${workspace.path}/small.txt');
        final summaryFile = File('${temp.path}/summary.json');
        await _writeRepeatedByte(nullFile, 0, 2 * 1024 * 1024);
        await smallFile.writeAsString('ok');
        final script = File('${temp.path}/agent.dart');
        final nullPath = jsonEncode(nullFile.path);
        final smallPath = jsonEncode(smallFile.path);
        final summaryPath = jsonEncode(summaryFile.path);
        await script.writeAsString('''
import 'dart:async';
import 'dart:convert';
import 'dart:io';

void send(Map<String, dynamic> message) {
  stdout.writeln(jsonEncode(message));
}

void request(String id, String path) {
  send(<String, dynamic>{
    'jsonrpc': '2.0',
    'id': id,
    'method': 'fs/read_text_file',
    'params': <String, dynamic>{
      'sessionId': 'backpressure-session',
      'path': path,
    },
  });
}

Future<void> main() async {
  var burstResponses = 0;
  var largeResponses = 0;
  var smallErrors = 0;
  var largestErrorBytes = 0;
  final lines = StreamIterator<String>(stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter()));
  while (await lines.moveNext()) {
    final message = jsonDecode(lines.current) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      send(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{},
          'authMethods': <Map<String, dynamic>>[],
        },
      });
    } else if (message['method'] == 'session/new') {
      send(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'sessionId': 'backpressure-session',
        },
      });
      for (var index = 0; index < 4; index += 1) {
        request('burst-\$index', $nullPath);
      }
      // Keep the host's first large response blocked in its bounded stdin
      // queue while all four filesystem requests reach the provider.
      await Future<void>.delayed(const Duration(seconds: 1));
    } else if ((message['id'] as String?)?.startsWith('burst-') ?? false) {
      burstResponses += 1;
      final result = message['result'] as Map<String, dynamic>?;
      final content = result?['content'] as String?;
      if (content != null &&
          content.length == 2 * 1024 * 1024 &&
          content.codeUnits.every((value) => value == 0)) {
        largeResponses += 1;
      } else if (message.containsKey('error')) {
        smallErrors += 1;
        final encodedBytes = utf8.encode(jsonEncode(message)).length;
        if (encodedBytes > largestErrorBytes) {
          largestErrorBytes = encodedBytes;
        }
      }
      if (burstResponses == 4) {
        request('read-small', $smallPath);
      }
    } else if (message['id'] == 'read-small') {
      final result = message['result'] as Map<String, dynamic>?;
      await File($summaryPath).writeAsString(jsonEncode(<String, dynamic>{
        'burstResponses': burstResponses,
        'largeResponses': largeResponses,
        'smallErrors': smallErrors,
        'largestErrorBytes': largestErrorBytes,
        'followUpContent': result?['content'],
      }));
    }
  }
}
''');
        late final DartAcpAgentClient client;
        client = DartAcpAgentClient(
          agentCommand: _dartExecutable(),
          agentArgs: <String>[script.path],
          enableFilesystemReadTextFile: true,
        );
        final subscription = client.permissionRequests.listen((request) {
          unawaited(
            client.respondToPermissionRequest(
              id: request.id,
              decision: AcpPermissionDecision.allow,
            ),
          );
        });
        addTearDown(() async {
          await subscription.cancel();
          await client.dispose();
        });

        await client.connect().timeout(const Duration(seconds: 10));
        await client.createSession(cwd: workspace.path);
        await _waitForFile(summaryFile, timeout: const Duration(seconds: 30));
        final summary = jsonDecode(await summaryFile.readAsString());

        expect(summary['burstResponses'], 4);
        expect(summary['largeResponses'], 2);
        expect(summary['smallErrors'], 2);
        expect(summary['largestErrorBytes'], lessThan(1024));
        expect(summary['followUpContent'], 'ok');
      },
      timeout: const Timeout(Duration(seconds: 45)),
    );

    test('caches one stateful scoped provider per active session', () async {
      final temp = await Directory.systemTemp.createTemp('acp-stateful-fs-');
      addTearDown(() => temp.delete(recursive: true));
      final firstRoot = Directory('${temp.path}/first');
      final secondRoot = Directory('${temp.path}/second');
      await firstRoot.create();
      await secondRoot.create();
      final marker = _StatefulFsProvider();
      final harness = await _SessionFsHarness.start(
        workspaceRoot: firstRoot.path,
        provider: marker,
        sessionIds: const <String>[
          'first-session',
          'second-session',
          'first-session',
        ],
      );
      addTearDown(harness.close);

      await harness.request('fs/write_text_file', <String, dynamic>{
        'sessionId': 'first-session',
        'path': 'state',
        'content': 'first value',
      });
      final firstRead = await harness.request(
        'fs/read_text_file',
        <String, dynamic>{'sessionId': 'first-session', 'path': 'state'},
      );
      expect(firstRead['result'], <String, dynamic>{'content': 'first value'});
      expect(marker.bindCount, 1);

      await harness.manager.loadSession(
        sessionId: 'first-session',
        workspaceRoot: firstRoot.path,
      );
      await harness.manager.resumeSession(
        sessionId: 'first-session',
        workspaceRoot: firstRoot.path,
      );
      final afterSetup = await harness.request(
        'fs/read_text_file',
        <String, dynamic>{'sessionId': 'first-session', 'path': 'state'},
      );
      expect(afterSetup['result'], <String, dynamic>{'content': 'first value'});
      expect(marker.bindCount, 1);

      final secondSession = await harness.newSession(secondRoot.path);
      expect(secondSession, 'second-session');
      final secondInitial = await harness.request(
        'fs/read_text_file',
        <String, dynamic>{'sessionId': secondSession, 'path': 'state'},
      );
      expect(secondInitial['result'], <String, dynamic>{'content': ''});
      await harness.request('fs/write_text_file', <String, dynamic>{
        'sessionId': secondSession,
        'path': 'state',
        'content': 'second value',
      });
      expect(marker.bindCount, 2);

      final firstAgain = await harness.request(
        'fs/read_text_file',
        <String, dynamic>{'sessionId': 'first-session', 'path': 'state'},
      );
      expect(firstAgain['result'], <String, dynamic>{'content': 'first value'});
      expect(marker.bindCount, 2);

      await harness.manager.closeSession(sessionId: 'first-session');
      final reused = await harness.newSession(firstRoot.path);
      expect(reused, 'first-session');
      final reusedRead = await harness.request(
        'fs/read_text_file',
        <String, dynamic>{'sessionId': reused, 'path': 'state'},
      );
      expect(reusedRead['result'], <String, dynamic>{'content': ''});
      expect(marker.bindCount, 3);
    });

    test('keeps cached provider when remote close fails', () async {
      final temp = await Directory.systemTemp.createTemp('acp-fs-close-fail-');
      addTearDown(() => temp.delete(recursive: true));
      final workspace = Directory('${temp.path}/workspace');
      await workspace.create();
      final marker = _StatefulFsProvider();
      final harness = await _SessionFsHarness.start(
        workspaceRoot: workspace.path,
        provider: marker,
        failCloseRequests: true,
      );
      addTearDown(harness.close);
      await harness.request('fs/write_text_file', <String, dynamic>{
        'sessionId': harness.sessionId,
        'path': 'state',
        'content': 'retained',
      });

      await expectLater(
        harness.manager.closeSession(sessionId: harness.sessionId),
        throwsA(anything),
      );
      final read = await harness.request('fs/read_text_file', <String, dynamic>{
        'sessionId': harness.sessionId,
        'path': 'state',
      });

      expect(read['result'], <String, dynamic>{'content': 'retained'});
      expect(marker.bindCount, 1);
    });

    test('drops provider created during first setup rollback', () async {
      final temp = await Directory.systemTemp.createTemp('acp-fs-rollback-');
      addTearDown(() => temp.delete(recursive: true));
      final initialRoot = Directory('${temp.path}/initial');
      final loadedRoot = Directory('${temp.path}/loaded');
      await initialRoot.create();
      await loadedRoot.create();
      final marker = _StatefulFsProvider();
      final harness = await _SessionFsHarness.start(
        workspaceRoot: initialRoot.path,
        provider: marker,
        failFirstLoadAfterFsWrite: true,
      );
      addTearDown(harness.close);

      await expectLater(
        harness.manager.loadSession(
          sessionId: 'loaded-session',
          workspaceRoot: loadedRoot.path,
        ),
        throwsA(anything),
      );
      expect(marker.bindCount, 1);

      await harness.manager.loadSession(
        sessionId: 'loaded-session',
        workspaceRoot: loadedRoot.path,
      );
      final read = await harness.request('fs/read_text_file', <String, dynamic>{
        'sessionId': 'loaded-session',
        'path': 'state',
      });
      expect(read['result'], <String, dynamic>{'content': ''});
      expect(marker.bindCount, 2);
    });

    test('drops provider created during generated-session rollback', () async {
      final channel = StreamChannelController<String>();
      final peer = JsonRpcPeer(channel.foreign);
      late final SessionManager manager;
      final closeCompleted = Completer<void>();
      final readResponse = Completer<Map<String, dynamic>>();
      late final _StatefulFsProvider marker;
      marker = _StatefulFsProvider(
        onFirstWrite: () {
          unawaited(
            manager
                .closeSession(sessionId: 'source-session')
                .then(closeCompleted.complete)
                .catchError(closeCompleted.completeError),
          );
        },
      );
      manager = SessionManager(
        config: acp.AcpConfig(
          fsProvider: marker,
          permissionProvider: const _AllowAllPermissionProvider(),
        ),
        peer: peer,
      );
      final server = channel.local.stream.listen((line) {
        final message = jsonDecode(line) as Map<String, dynamic>;
        if (message['method'] == 'session/resume') {
          channel.local.sink.add(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': message['id'],
              'result': <String, dynamic>{'sessionId': 'source-session'},
            }),
          );
        } else if (message['method'] == 'session/fork') {
          channel.local.sink.add(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': message['id'],
              'result': <String, dynamic>{'sessionId': 'generated-session'},
            }),
          );
          scheduleMicrotask(() async {
            for (var attempt = 0; attempt < 20; attempt += 1) {
              try {
                manager.getWorkspaceRoot('generated-session');
                channel.local.sink.add(
                  jsonEncode(<String, dynamic>{
                    'jsonrpc': '2.0',
                    'id': 'generated-write',
                    'method': 'fs/write_text_file',
                    'params': <String, dynamic>{
                      'sessionId': 'generated-session',
                      'path': 'state',
                      'content': 'provisional',
                    },
                  }),
                );
                return;
              } on StateError {
                await Future<void>.microtask(() {});
              }
            }
          });
        } else if (message['method'] == 'session/close') {
          channel.local.sink.add(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': message['id'],
              'result': <String, dynamic>{},
            }),
          );
        } else if (message['method'] == 'session/new') {
          channel.local.sink.add(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': message['id'],
              'result': <String, dynamic>{'sessionId': 'generated-session'},
            }),
          );
        } else if (message['id'] == 'reuse-read' && !readResponse.isCompleted) {
          readResponse.complete(message);
        }
      });
      addTearDown(() async {
        await manager.dispose();
        await peer.close();
        await server.cancel();
        await channel.local.sink.close();
      });

      await manager.resumeSession(
        sessionId: 'source-session',
        workspaceRoot: '/workspace',
      );
      await expectLater(
        manager.forkSession(sessionId: 'source-session'),
        throwsStateError,
      );
      await closeCompleted.future.timeout(const Duration(seconds: 5));
      expect(marker.bindCount, 1);

      expect(
        await manager.newSession(workspaceRoot: '/workspace'),
        'generated-session',
      );
      channel.local.sink.add(
        jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': 'reuse-read',
          'method': 'fs/read_text_file',
          'params': <String, dynamic>{
            'sessionId': 'generated-session',
            'path': 'state',
          },
        }),
      );
      final reused = await readResponse.future.timeout(
        const Duration(seconds: 5),
      );
      expect(reused['result'], <String, dynamic>{'content': ''});
      expect(marker.bindCount, 2);
    });

    test(
      'forwards RPC reads and writes to a custom provider unchanged',
      () async {
        final temp = await Directory.systemTemp.createTemp('acp-custom-fs-');
        addTearDown(() => temp.delete(recursive: true));
        final provider = _SpyFsProvider();
        final harness = await _SessionFsHarness.start(
          workspaceRoot: '${temp.path}/workspace',
          provider: provider,
        );
        addTearDown(harness.close);
        final readPath = '${temp.path}/must-not-exist-read.txt';
        final writePath = '${temp.path}/must-not-exist-write.txt';

        final read = await harness.request(
          'fs/read_text_file',
          <String, dynamic>{
            'sessionId': harness.sessionId,
            'path': readPath,
            'line': 2,
            'limit': 3,
          },
        );
        final write = await harness
            .request('fs/write_text_file', <String, dynamic>{
              'sessionId': harness.sessionId,
              'path': writePath,
              'content': 'custom content',
            });

        expect(read['result'], <String, dynamic>{'content': 'custom result'});
        expect(write['result'], isNull);
        expect(provider.reads, <Object?>[readPath, 2, 3]);
        expect(provider.writes, <Object?>[writePath, 'custom content']);
        expect(await File(readPath).exists(), isFalse);
        expect(await File(writePath).exists(), isFalse);
      },
    );

    test('rebinds the default marker to the session workspace jail', () async {
      final temp = await Directory.systemTemp.createTemp('acp-default-fs-');
      addTearDown(() => temp.delete(recursive: true));
      final workspace = Directory('${temp.path}/workspace');
      await workspace.create();
      final outside = File('${temp.path}/outside.txt');
      final oversized = File('${workspace.path}/oversized.txt');
      await oversized.writeAsString('12345');
      final harness = await _SessionFsHarness.start(
        workspaceRoot: workspace.path,
        provider: acp.DefaultFsProvider(workspaceRoot: '/', maxReadBytes: 4),
      );
      addTearDown(harness.close);

      final readResponse = await harness.request(
        'fs/read_text_file',
        <String, dynamic>{
          'sessionId': harness.sessionId,
          'path': oversized.path,
        },
      );
      final response = await harness
          .request('fs/write_text_file', <String, dynamic>{
            'sessionId': harness.sessionId,
            'path': outside.path,
            'content': 'must stay jailed',
          });

      expect(readResponse, contains('error'));
      expect(readResponse, isNot(contains('result')));
      expect(response, contains('error'));
      expect(await outside.exists(), isFalse);
    });

    test('uses the exact AcpConfig outside-read policy for a marker', () async {
      final temp = await Directory.systemTemp.createTemp('acp-fs-policy-');
      addTearDown(() => temp.delete(recursive: true));
      final workspace = Directory('${temp.path}/workspace');
      final outside = File('${temp.path}/outside.txt');
      await workspace.create();
      await outside.writeAsString('outside data');

      final denied = await _SessionFsHarness.start(
        workspaceRoot: workspace.path,
        provider: acp.DefaultFsProvider(
          workspaceRoot: '/',
          allowReadOutsideWorkspace: true,
        ),
      );
      addTearDown(denied.close);
      final deniedResponse = await denied.request(
        'fs/read_text_file',
        <String, dynamic>{'sessionId': denied.sessionId, 'path': outside.path},
      );

      final allowed = await _SessionFsHarness.start(
        workspaceRoot: workspace.path,
        provider: acp.DefaultFsProvider(workspaceRoot: '/'),
        allowReadOutsideWorkspace: true,
      );
      addTearDown(allowed.close);
      final allowedResponse = await allowed.request(
        'fs/read_text_file',
        <String, dynamic>{'sessionId': allowed.sessionId, 'path': outside.path},
      );

      expect(deniedResponse, contains('error'));
      expect(deniedResponse, isNot(contains('result')));
      expect(allowedResponse['result'], <String, dynamic>{
        'content': 'outside data',
      });
    });
  });
}

Future<void> _writeRepeatedByte(File file, int byte, int length) async {
  final sink = file.openWrite();
  final chunk = Uint8List(64 * 1024)..fillRange(0, 64 * 1024, byte);
  try {
    var remaining = length;
    while (remaining > 0) {
      final count = remaining < chunk.length ? remaining : chunk.length;
      sink.add(
        count == chunk.length ? chunk : Uint8List.sublistView(chunk, 0, count),
      );
      remaining -= count;
    }
  } finally {
    await sink.close();
  }
}

String _dartExecutable() {
  final executable = Platform.resolvedExecutable;
  final cacheMarker =
      '${Platform.pathSeparator}bin${Platform.pathSeparator}'
      'cache${Platform.pathSeparator}';
  final cacheIndex = executable.indexOf(cacheMarker);
  if (cacheIndex != -1) {
    return '${executable.substring(0, cacheIndex)}'
        '${Platform.pathSeparator}bin'
        '${Platform.pathSeparator}cache'
        '${Platform.pathSeparator}dart-sdk'
        '${Platform.pathSeparator}bin'
        '${Platform.pathSeparator}dart';
  }
  return executable.endsWith('${Platform.pathSeparator}dart')
      ? executable
      : 'dart';
}

Future<void> _waitForFile(
  File file, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!await file.exists()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Timed out waiting for ${file.path}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

final class _SubclassedDefaultFsProvider extends acp.DefaultFsProvider {
  _SubclassedDefaultFsProvider({required super.workspaceRoot})
    : super(
        maxReadBytes: 16,
        maxReturnedBytes: 16,
        maxConcurrentReads: 1,
        maxAggregateReadBytes: 64,
      );
}

final class _SpyFsProvider implements acp.FsProvider {
  final List<Object?> reads = <Object?>[];
  final List<Object?> writes = <Object?>[];

  @override
  Future<String> readTextFile(String path, {int? line, int? limit}) async {
    reads.addAll(<Object?>[path, line, limit]);
    return 'custom result';
  }

  @override
  Future<void> writeTextFile(String path, String content) async {
    writes.addAll(<Object?>[path, content]);
  }
}

final class _StatefulFsProvider implements acp.SessionScopedFsProvider {
  _StatefulFsProvider({this.onFirstWrite});

  final void Function()? onFirstWrite;
  var bindCount = 0;
  var _didWrite = false;

  @override
  acp.FsProvider bindToSession({
    required String workspaceRoot,
    List<String> additionalWorkspaceRoots = const <String>[],
    required bool allowReadOutsideWorkspace,
  }) {
    bindCount += 1;
    return _StatefulBoundFsProvider(
      onWrite: () {
        if (_didWrite) return;
        _didWrite = true;
        onFirstWrite?.call();
      },
    );
  }

  @override
  Future<String> readTextFile(String path, {int? line, int? limit}) =>
      throw StateError('The unbound marker must not receive reads.');

  @override
  Future<void> writeTextFile(String path, String content) =>
      throw StateError('The unbound marker must not receive writes.');
}

final class _StatefulBoundFsProvider implements acp.FsProvider {
  _StatefulBoundFsProvider({required this.onWrite});

  final void Function() onWrite;
  final Map<String, String> _files = <String, String>{};

  @override
  Future<String> readTextFile(String path, {int? line, int? limit}) async =>
      _files[path] ?? '';

  @override
  Future<void> writeTextFile(String path, String content) async {
    onWrite();
    _files[path] = content;
  }
}

final class _AllowAllPermissionProvider implements acp.PermissionProvider {
  const _AllowAllPermissionProvider();

  @override
  Future<acp.PermissionDecision> request(acp.PermissionOptions options) async =>
      const acp.PermissionDecision(acp.PermissionOutcome.allow);
}

final class _SessionFsHarness {
  _SessionFsHarness._({
    required this.sessionId,
    required this.manager,
    required this.peer,
    required this.channel,
    required this.server,
  });

  static Future<_SessionFsHarness> start({
    required String workspaceRoot,
    required acp.FsProvider provider,
    bool allowReadOutsideWorkspace = false,
    List<String> sessionIds = const <String>['fs-session'],
    bool failCloseRequests = false,
    bool failFirstLoadAfterFsWrite = false,
  }) async {
    final channel = StreamChannelController<String>();
    final peer = JsonRpcPeer(channel.foreign);
    final manager = SessionManager(
      config: acp.AcpConfig(
        fsProvider: provider,
        permissionProvider: const _AllowAllPermissionProvider(),
        allowReadOutsideWorkspace: allowReadOutsideWorkspace,
      ),
      peer: peer,
    );
    final pendingSessionIds = Queue<String>.of(sessionIds);
    if (pendingSessionIds.isEmpty) {
      throw ArgumentError.value(sessionIds, 'sessionIds');
    }
    late final StreamSubscription<String> server;
    final pendingResponses = <Object, Completer<Map<String, dynamic>>>{};
    Object? pendingFailedLoadId;
    var shouldFailLoad = failFirstLoadAfterFsWrite;
    server = channel.local.stream.listen((line) {
      final message = jsonDecode(line) as Map<String, dynamic>;
      if (message['method'] == 'session/new') {
        final nextSessionId = pendingSessionIds.removeFirst();
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': message['id'],
            'result': <String, dynamic>{'sessionId': nextSessionId},
          }),
        );
        return;
      }
      if (message['method'] == 'session/close') {
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': message['id'],
            if (failCloseRequests)
              'error': <String, dynamic>{
                'code': -32000,
                'message': 'close failed',
              }
            else
              'result': <String, dynamic>{},
          }),
        );
        return;
      }
      if (message['method'] == 'session/load') {
        final params = message['params'] as Map<String, dynamic>;
        if (shouldFailLoad) {
          shouldFailLoad = false;
          pendingFailedLoadId = message['id'];
          channel.local.sink.add(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': 'load-fs-write',
              'method': 'fs/write_text_file',
              'params': <String, dynamic>{
                'sessionId': params['sessionId'],
                'path': 'state',
                'content': 'provisional',
              },
            }),
          );
        } else {
          channel.local.sink.add(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': message['id'],
              'result': <String, dynamic>{'sessionId': params['sessionId']},
            }),
          );
        }
        return;
      }
      if (message['method'] == 'session/resume') {
        final params = message['params'] as Map<String, dynamic>;
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': message['id'],
            'result': <String, dynamic>{'sessionId': params['sessionId']},
          }),
        );
        return;
      }
      if (message['id'] == 'load-fs-write' && pendingFailedLoadId != null) {
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': pendingFailedLoadId,
            'error': <String, dynamic>{
              'code': -32000,
              'message': 'load failed',
            },
          }),
        );
        pendingFailedLoadId = null;
        return;
      }
      final responseId = message['id'];
      pendingResponses.remove(responseId)?.complete(message);
    });
    final sessionId = await manager.newSession(workspaceRoot: workspaceRoot);
    return _SessionFsHarness._(
      sessionId: sessionId,
      manager: manager,
      peer: peer,
      channel: channel,
      server: server,
    ).._pendingResponses = pendingResponses;
  }

  final String sessionId;
  final SessionManager manager;
  final JsonRpcPeer peer;
  final StreamChannelController<String> channel;
  final StreamSubscription<String> server;
  late final Map<Object, Completer<Map<String, dynamic>>> _pendingResponses;
  var _nextRequestId = 0;

  Future<String> newSession(String workspaceRoot) =>
      manager.newSession(workspaceRoot: workspaceRoot);

  Future<Map<String, dynamic>> request(
    String method,
    Map<String, dynamic> params,
  ) async {
    final id = 'client-${++_nextRequestId}';
    final completer = Completer<Map<String, dynamic>>();
    _pendingResponses[id] = completer;
    channel.local.sink.add(
      jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params,
      }),
    );
    return completer.future.timeout(const Duration(seconds: 2));
  }

  Future<void> close() async {
    await manager.dispose();
    await peer.close();
    await server.cancel();
    await channel.local.sink.close();
  }
}
