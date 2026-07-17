import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:dart_acp/dart_acp.dart' as acp;
import 'package:dart_acp/src/rpc/peer.dart' show JsonRpcPeer;
import 'package:dart_acp/src/session/session_manager.dart' show SessionManager;
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/acp_agent_capabilities.dart';
import 'package:ianvs_acp/acp/acp_permission_request.dart';
import 'package:ianvs_acp/acp/acp_session_catalog.dart';
import 'package:ianvs_acp/acp/acp_session_settings.dart';
import 'package:ianvs_acp/acp/agent_event.dart';
import 'package:ianvs_acp/acp/agent_session.dart';
import 'package:ianvs_acp/acp/dart_acp_agent_client.dart';
import 'package:ianvs_acp/acp/prompt_attachment.dart';
import 'package:ianvs_acp/state/chat_controller.dart';
import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:stream_channel/stream_channel.dart';

final _testOmission = acp.AcpInputOmission(
  reason: acp.AcpInputOmissionReason.invalidStructure,
  resource: 'test_resource',
  truncated: false,
);

enum _RawUnavailableFirst {
  transportClose,
  requestFatal,
  explicitClose,
  dispose,
}

enum _RawCloseRaceOrder { listenerFirst, resultErrorFirst, userCancelFirst }

enum _RawExternalUnavailableCause { explicitClose, dispose }

enum _RawPreOwnerExit { cancel, reconnect, dispose }

enum _RawPostOwnerExit { reconnect, dispose }

const bridgePermissionMethods = <String>[
  'session/request_permission',
  'fs/read_text_file',
  'fs/write_text_file',
  'terminal/create',
];

const bridgeInvalidationReasons = <AcpPermissionInvalidationReason>[
  AcpPermissionInvalidationReason.timedOut,
  AcpPermissionInvalidationReason.promptEnded,
  AcpPermissionInvalidationReason.promptCancelled,
  AcpPermissionInvalidationReason.sessionClosed,
  AcpPermissionInvalidationReason.connectionClosed,
  AcpPermissionInvalidationReason.disposed,
];

enum UnavailableFirstReason {
  requestFatal,
  transportClose,
  explicitClose,
  dispose,
}

enum _DeferredPermissionExit { reconnect, dispose }

AcpPermissionInvalidationReason expectedReasonFor(
  UnavailableFirstReason reason,
) => switch (reason) {
  UnavailableFirstReason.dispose => AcpPermissionInvalidationReason.disposed,
  UnavailableFirstReason.requestFatal ||
  UnavailableFirstReason.transportClose ||
  UnavailableFirstReason.explicitClose =>
    AcpPermissionInvalidationReason.connectionClosed,
};

final class _PermissionWireProbe {
  const _PermissionWireProbe({
    required this.request,
    required this.response,
    required this.responseCapture,
    required this.agentParams,
    required this.control,
  });

  final AcpPermissionRequest request;
  final Future<_CapturedWireResponse> response;
  final File responseCapture;
  final Map<String, Object?> agentParams;
  final Map<String, Object?> control;
}

final class _CapturedWireResponse {
  const _CapturedWireResponse(this.raw);

  final Map<String, Object?> raw;

  Map<String, Object?>? get _error {
    final value = raw['error'];
    return value is Map ? Map<String, Object?>.from(value) : null;
  }

  Map<String, Object?>? get _result {
    final value = raw['result'];
    return value is Map ? Map<String, Object?>.from(value) : null;
  }

  bool get hasErrorData => _error?.containsKey('data') ?? false;
  bool get hasError => _error != null;
  int? get errorCode => _error?['code'] as int?;
  String? get errorText => _error?['message'] as String?;
  String? get terminalId => _result?['terminalId'] as String?;

  String? get selectedOutcome {
    final outcome = _result?['outcome'];
    if (outcome is String) return outcome;
    if (outcome is Map<String, Object?>) {
      return outcome['outcome'] as String?;
    }
    return null;
  }

  String? get selectedOptionId {
    final outcome = _result?['outcome'];
    if (outcome is Map<String, Object?>) {
      return outcome['optionId'] as String?;
    }
    return null;
  }
}

enum _PermissionFileWaitSignal { retry, disposed, unavailable }

final class _CanaryCancellationToken {
  const _CanaryCancellationToken(this.canary);

  final String canary;

  @override
  String toString() => 'ACP cancellation token <$canary>';
}

const _rawAgentSource = r'''
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final promptSeen = File(args[0]);
  final cancelSeen = File(args[1]);
  final releaseResponse = File(args[2]);
  final lateTerminalSent = File(args[3]);
  final control = File(args[4]);
  final providerResponse = File(args[5]);
  final requestFatalSeen = File(args[6]);
  Map<String, dynamic>? promptRequest;
  var stopped = false;
  var providerSent = false;
  var newCount = 0;
  var promptCount = 0;

  void send(Map<String, dynamic> message) {
    stdout.writeln(jsonEncode(message));
  }

  Future<void> poll() async {
    while (!stopped) {
      if (await control.exists() &&
          (await control.readAsString()).trim() == 'transport-close') {
        await stdout.flush();
        exit(0);
      }
      if (await control.exists()) {
        final action = (await control.readAsString()).trim();
        if (!providerSent && action.startsWith('provider:')) {
          providerSent = true;
          final method = action.substring('provider:'.length);
          final params = switch (method) {
            'fs/read_text_file' => <String, dynamic>{
              'sessionId': 'session-1',
              'path': 'input.txt',
            },
            'fs/write_text_file' => <String, dynamic>{
              'sessionId': 'session-1',
              'path': 'output.txt',
              'content': 'fixed output',
            },
            'terminal/create' => <String, dynamic>{
              'sessionId': 'session-1',
              'command': 'printf fixed',
              'args': <String>[],
            },
            _ => throw StateError('Unsupported provider method: $method'),
          };
          send(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': 'raw-provider-1',
            'method': method,
            'params': params,
          });
          await stdout.flush();
        }
      }
      final current = promptRequest;
      if (current != null && await releaseResponse.exists()) {
        final terminal = (await releaseResponse.readAsString()).trim();
        promptRequest = null;
        if (terminal == 'success') {
          send(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': current['id'],
            'result': <String, dynamic>{'stopReason': 'end_turn'},
          });
        } else {
          final error = Map<String, dynamic>.from(
            jsonDecode(terminal) as Map,
          );
          send(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': current['id'],
            'error': error,
          });
        }
        await stdout.flush();
        await lateTerminalSent.writeAsString('sent');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  final polling = poll();
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final decoded = jsonDecode(line);
    if (decoded is! Map) continue;
    final message = Map<String, dynamic>.from(decoded);
    if (message['id'] == 'raw-provider-1' && message['method'] == null) {
      await providerResponse.writeAsString(jsonEncode(message));
      continue;
    }
    switch (message['method']) {
      case 'initialize':
        send(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': message['id'],
          'result': <String, dynamic>{
            'protocolVersion': 1,
            'agentCapabilities': <String, dynamic>{
              'promptCapabilities': <String, dynamic>{},
            },
            'authMethods': <Map<String, dynamic>>[],
          },
        });
        break;
      case 'session/new':
        newCount += 1;
        send(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': message['id'],
          'result': <String, dynamic>{
            'sessionId': 'session-' + newCount.toString(),
          },
        });
        break;
      case 'session/prompt':
        promptCount += 1;
        promptRequest = message;
        await promptSeen.writeAsString(promptCount.toString());
        break;
      case 'session/cancel':
        await cancelSeen.writeAsString('seen');
        break;
      case '_raw/request-fatal':
        await requestFatalSeen.writeAsString('seen');
        break;
      case 'logout':
        send(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': message['id'],
          'result': <String, dynamic>{},
        });
        break;
    }
    await stdout.flush();
  }
  stopped = true;
  await polling;
}
''';

const _permissionAgentSource = r'''
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final controlFile = File(args[0]);
  final ackDirectory = Directory(args[1]);
  final responseDirectory = Directory(args[2]);
  final transportClosedFile = File(args[3]);
  final markerDirectory = Directory(args[4]);
  final defaultWorkspacePath = args[5];
  var handledControlSequence = 0;
  var nextPermissionId = 1000;
  var nextSessionId = 1;
  Object? activePromptId;
  var controlBusy = false;
  final responseTargets = <Object?, File>{};
  final responseLogs = <Object?, File>{};

  void send(Map<String, Object?> message) {
    stdout.writeln(jsonEncode(message));
  }

  Map<String, Object?> permissionParams(
    String method,
    Map<String, Object?> control,
  ) {
    final sessionId = control['sessionId'] as String? ?? 'session-1';
    final canary = control['canary'] as String? ?? '';
    final workspacePath =
        control['workspacePath'] as String? ?? defaultWorkspacePath;
    final transient = control['transientMetadata'];
    return switch (method) {
      'session/request_permission' => <String, Object?>{
        'sessionId': sessionId,
        'options': <Map<String, Object?>>[
          <String, Object?>{'optionId': 'allow', 'name': 'Allow'},
          <String, Object?>{'optionId': 'deny', 'name': 'Deny'},
        ],
        'toolCall': <String, Object?>{
          'title': 'Permission request',
          'kind': 'read',
          if (transient is Map) 'transientPolicyContext': transient,
        },
      },
      'fs/read_text_file' => <String, Object?>{
        'sessionId': sessionId,
        'path': '$workspacePath/input-$canary.txt',
      },
      'fs/write_text_file' => <String, Object?>{
        'sessionId': sessionId,
        'path': '$workspacePath/output-$canary.txt',
        'content': 'fixed',
      },
      'terminal/create' => <String, Object?>{
        'sessionId': sessionId,
        'command': '/usr/bin/true',
        'args': <String>[],
      },
      _ => <String, Object?>{'sessionId': sessionId},
    };
  }

  Future<void> handleControl() async {
    if (controlBusy || !await controlFile.exists()) return;
    controlBusy = true;
    try {
      final Object? decoded;
      try {
        decoded = jsonDecode(await controlFile.readAsString());
      } on FormatException {
        return;
      } on FileSystemException {
        return;
      }
      if (decoded is! Map) return;
      final control = Map<String, Object?>.from(decoded);
      final sequence = control['sequence'];
      if (sequence is! int || sequence <= handledControlSequence) return;
      final action = control['action'];
      if (action == 'permission') {
        final method = control['method'] as String;
        final id = nextPermissionId++;
        final responseSequence = control['responseSequence'] as int;
        final params = permissionParams(method, control);
        await File('${responseDirectory.path}/request-$responseSequence.json')
            .writeAsString(jsonEncode(params), flush: true);
        responseTargets[id] = File(
          '${responseDirectory.path}/'
          '${method.replaceAll('/', '_')}-$responseSequence.json',
        );
        responseLogs[id] = File(
          '${responseDirectory.path}/wire-$responseSequence.jsonl',
        );
        send(<String, Object?>{
          'jsonrpc': '2.0',
          'id': id,
          'method': method,
          'params': params,
        });
      } else if (action == 'finish-prompt' && activePromptId != null) {
        send(<String, Object?>{
          'jsonrpc': '2.0',
          'id': activePromptId,
          'result': <String, Object?>{'stopReason': 'end_turn'},
        });
        activePromptId = null;
      } else if (action == 'transport-close') {
        await transportClosedFile.writeAsString('closed');
      }
      handledControlSequence = sequence;
      await controlFile.delete();
      await File('${ackDirectory.path}/$sequence.ack')
          .writeAsString('$sequence', flush: true);
      if (action == 'transport-close') exit(0);
    } finally {
      controlBusy = false;
    }
  }

  final controlTimer = Timer.periodic(
    const Duration(milliseconds: 5),
    (_) => unawaited(handleControl()),
  );

  try {
    await for (final line in stdin
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      final decoded = jsonDecode(line);
      if (decoded is! Map) continue;
      final message = Map<String, Object?>.from(decoded);
      final method = message['method'];
      if (method == 'initialize') {
        send(<String, Object?>{
          'jsonrpc': '2.0',
          'id': message['id'],
          'result': <String, Object?>{
            'protocolVersion': 1,
            'agentCapabilities': <String, Object?>{
              'auth': <String, Object?>{'logout': true},
              'sessionCapabilities': <String, Object?>{'close': true},
            },
            'authMethods': <Map<String, Object?>>[],
          },
        });
      } else if (method == 'session/new') {
        final sessionId = 'session-${nextSessionId++}';
        send(<String, Object?>{
          'jsonrpc': '2.0',
          'id': message['id'],
          'result': <String, Object?>{'sessionId': sessionId},
        });
      } else if (method == 'session/prompt') {
        activePromptId = message['id'];
        await File('${markerDirectory.path}/owner-prompt-seen')
            .writeAsString('seen');
      } else if (method == 'logout' ||
          method == 'authenticate/logout' ||
          method == '_permission_fixture_echo' ||
          method == 'session/close') {
        send(<String, Object?>{
          'jsonrpc': '2.0',
          'id': message['id'],
          'result': method == '_permission_fixture_echo'
              ? <String, Object?>{'value': 'ok'}
              : <String, Object?>{},
        });
      } else if (method == '_permission_fixture_timeout') {
        await File('${markerDirectory.path}/request-fatal-seen')
            .writeAsString('seen');
      } else if (!message.containsKey('method') &&
          message.containsKey('id')) {
        final target = responseTargets[message['id']];
        final log = responseLogs[message['id']];
        if (target != null && log != null) {
          await log.writeAsString(
            '${jsonEncode(message)}\n',
            mode: FileMode.append,
            flush: true,
          );
          if (!await target.exists()) {
            await target.writeAsString(jsonEncode(message), flush: true);
          }
        }
      }
    }
  } finally {
    controlTimer.cancel();
  }
}
''';

final class _PermissionStdioFixture {
  _PermissionStdioFixture._({
    required this.tempDir,
    required this.workspaceDirectory,
    required this.client,
    required this.acpClient,
    required this.session,
    required this.controlFile,
    required this.controlAckDirectory,
    required this.responseDirectory,
    required this.markerDirectory,
    required this.transportClosedFile,
    required this.transientMetadata,
    required this._unavailable,
  });

  final Directory tempDir;
  final Directory workspaceDirectory;
  final DartAcpAgentClient client;
  final acp.AcpClient acpClient;
  final AgentSession session;
  final File controlFile;
  final Directory controlAckDirectory;
  final Directory responseDirectory;
  final Directory markerDirectory;
  final File transportClosedFile;
  final Map<String, Object?> transientMetadata;
  Future<acp.AcpPeerUnavailableState> _unavailable;
  late final StreamSubscription<acp.AcpPeerUnavailableState>
  _peerUnavailableSubscription;
  late final StreamSubscription<AcpPermissionInvalidation>
  _permissionInvalidationSubscription;
  int _controlSequence = 0;
  int _responseSequence = 0;
  final List<Object> cancellationTokensCreatedForTesting = <Object>[];
  _CanaryCancellationToken? _injectedCancellationToken;
  Future<void>? _clientDisposeFuture;
  Future<void>? _disposeFuture;
  final Completer<void> _stopFileWaits = Completer<void>.sync();
  Future<void>? _ownerPromptStarted;
  StreamSubscription<AgentEvent>? _ownerPromptSubscription;
  final Map<String, File> responseLogsByLifecycle = <String, File>{};
  int _peerCloseCount = 0;

  static Future<_PermissionStdioFixture> startPermissionScenario({
    acp.AcpTimeouts timeouts = const acp.AcpTimeouts(
      request: Duration(milliseconds: 75),
      permission: Duration(milliseconds: 750),
      promptCancelGrace: Duration(milliseconds: 750),
    ),
    Map<String, Object?> transientMetadata = const <String, Object?>{},
  }) async {
    final tempDir = await Directory.systemTemp.createTemp('permission-stdio-');
    File path(String name) => File('${tempDir.path}/$name');
    final ackDirectory = Directory('${tempDir.path}/acks');
    final responseDirectory = Directory('${tempDir.path}/responses');
    final markerDirectory = Directory('${tempDir.path}/markers');
    final workspaceDirectory = Directory('${tempDir.path}/workspace');
    await Future.wait<Directory>(<Future<Directory>>[
      ackDirectory.create(),
      responseDirectory.create(),
      markerDirectory.create(),
      workspaceDirectory.create(),
    ]);
    final script = path('permission_agent.dart');
    final control = path('control.json');
    final transportClosed = path('transport-closed');
    await script.writeAsString(_permissionAgentSource);
    final client = DartAcpAgentClient(
      agentCommand: _dartExecutable(),
      agentArgs: <String>[
        script.path,
        control.path,
        ackDirectory.path,
        responseDirectory.path,
        transportClosed.path,
        markerDirectory.path,
        workspaceDirectory.path,
      ],
      timeouts: timeouts,
      enableFilesystemReadTextFile: true,
      enableFilesystemWriteTextFile: true,
      enableTerminalProvider: true,
    );
    await client.connect().timeout(const Duration(seconds: 2));
    final session = await client.createSession(cwd: workspaceDirectory.path);
    final unavailable = client.peerUnavailableForTesting.first;
    final fixture = _PermissionStdioFixture._(
      tempDir: tempDir,
      workspaceDirectory: workspaceDirectory,
      client: client,
      acpClient: client.acpClientForTesting,
      session: session,
      controlFile: control,
      controlAckDirectory: ackDirectory,
      responseDirectory: responseDirectory,
      markerDirectory: markerDirectory,
      transportClosedFile: transportClosed,
      transientMetadata: Map<String, Object?>.unmodifiable(transientMetadata),
      unavailable: unavailable,
    );
    fixture._peerUnavailableSubscription = client.peerUnavailableForTesting
        .listen((state) {
          fixture._peerCloseCount += 1;
        });
    fixture._permissionInvalidationSubscription = client.permissionInvalidations
        .listen((event) {
          if (event.reason == AcpPermissionInvalidationReason.timedOut) {
            unawaited(fixture.permissionTimedOutFile.writeAsString('seen'));
            unawaited(
              fixture
                  .permissionTimedOutFileFor(event.lifecycleId)
                  .writeAsString('seen'),
            );
          }
        });
    return fixture;
  }

  File controlAck(int sequence) =>
      File('${controlAckDirectory.path}/$sequence.ack');
  File responseFile(String method, int sequence) => File(
    '${responseDirectory.path}/'
    '${method.replaceAll('/', '_')}-$sequence.json',
  );
  File responseLogFile(int sequence) =>
      File('${responseDirectory.path}/wire-$sequence.jsonl');
  File agentParamsFile(int sequence) =>
      File('${responseDirectory.path}/request-$sequence.json');
  File get requestFatalSeenFile =>
      File('${markerDirectory.path}/request-fatal-seen');
  File get permissionTimedOutFile =>
      File('${markerDirectory.path}/permission-timed-out');
  File permissionTimedOutFileFor(String lifecycleId) =>
      File('${markerDirectory.path}/permission-timed-out-$lifecycleId');
  File bridgeSettledFile(String lifecycleId) =>
      File('${markerDirectory.path}/bridge-settled-$lifecycleId');
  File get ownerPromptSeenFile =>
      File('${markerDirectory.path}/owner-prompt-seen');

  void injectCancellationTokenCanary(String canary) {
    if (_injectedCancellationToken != null ||
        cancellationTokensCreatedForTesting.isNotEmpty) {
      throw StateError('A cancellation-token canary is already installed.');
    }
    final token = _CanaryCancellationToken(canary);
    _injectedCancellationToken = token;
    acpClient.replacePermissionCancellationTokenFactoryForTesting(() {
      cancellationTokensCreatedForTesting.add(token);
      return token;
    });
  }

  _CanaryCancellationToken get injectedCancellationTokenForTesting =>
      _injectedCancellationToken ??
      (throw StateError('No cancellation-token canary is installed.'));

  Future<void> _waitForScenarioFile(File file) async {
    while (!await file.exists()) {
      final signal = await Future.any<_PermissionFileWaitSignal>([
        Future<_PermissionFileWaitSignal>.delayed(
          const Duration(milliseconds: 5),
          () => _PermissionFileWaitSignal.retry,
        ),
        _stopFileWaits.future.then((_) => _PermissionFileWaitSignal.disposed),
        _unavailable.then((_) => _PermissionFileWaitSignal.unavailable),
      ]);
      switch (signal) {
        case _PermissionFileWaitSignal.retry:
          break;
        case _PermissionFileWaitSignal.disposed:
          if (await file.exists()) return;
          throw StateError(
            'Permission fixture disposed while waiting for ${file.path}.',
          );
        case _PermissionFileWaitSignal.unavailable:
          if (await file.exists()) return;
          throw StateError(
            'ACP peer became unavailable while waiting for ${file.path}.',
          );
      }
    }
  }

  Future<int> _sendAgentControl(
    String action, [
    Map<String, Object?> fields = const <String, Object?>{},
  ]) async {
    final sequence = ++_controlSequence;
    final staged = File('${controlFile.path}.$sequence.tmp');
    await staged.writeAsString(
      jsonEncode(<String, Object?>{
        'sequence': sequence,
        'action': action,
        ...fields,
      }),
      flush: true,
    );
    await staged.rename(controlFile.path);
    final ack = controlAck(sequence);
    await _waitForScenarioFile(ack);
    final acknowledged = await ack.readAsString();
    if (acknowledged != '$sequence') {
      throw StateError('Unexpected control acknowledgement $acknowledged.');
    }
    return sequence;
  }

  Future<int> sendNoopControlForTesting() => _sendAgentControl('noop');

  Future<_CapturedWireResponse> nextWireResponse(File file) async {
    await _waitForScenarioFile(file);
    return _CapturedWireResponse(
      Map<String, Object?>.from(jsonDecode(await file.readAsString()) as Map),
    );
  }

  Future<void> get requestFatalSeen =>
      _waitForScenarioFile(requestFatalSeenFile);
  Future<void> get permissionTimedOut =>
      _waitForScenarioFile(permissionTimedOutFile);
  Future<void> permissionTimedOutFor(AcpPermissionRequest request) =>
      _waitForScenarioFile(permissionTimedOutFileFor(request.lifecycleId));
  Future<void> bridgeSettledFor(AcpPermissionRequest request) =>
      _waitForScenarioFile(bridgeSettledFile(request.lifecycleId));
  Future<void> get peerUnavailable => _unavailable.then<void>((_) {});

  void refreshUnavailableWatcherAfterReconnect() {
    _unavailable = client.peerUnavailableForTesting.first;
  }

  Future<_PermissionWireProbe> sendPermission({
    required String method,
    String canary = '',
    bool ownerScoped = false,
    String? sessionId,
    String? workspacePath,
  }) async {
    if (ownerScoped) await ensureOwnerPromptStarted();
    final effectiveWorkspace = workspacePath ?? workspaceDirectory.path;
    if (method == 'fs/read_text_file') {
      await File(
        '$effectiveWorkspace/input-$canary.txt',
      ).writeAsString('fixed input', flush: true);
    }
    final requestSeen = client.permissionRequests.first;
    final responseSequence = ++_responseSequence;
    final responseCapture = responseFile(method, responseSequence);
    final responseLog = responseLogFile(responseSequence);
    final response = nextWireResponse(responseCapture);
    unawaited(
      response.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
    final controlFields = <String, Object?>{
      'method': method,
      'canary': canary,
      'transientMetadata': transientMetadata,
      'ownerScoped': ownerScoped,
      'responseSequence': responseSequence,
      'workspacePath': effectiveWorkspace,
      'sessionId': ?sessionId,
    };
    final controlSequence = await _sendAgentControl(
      'permission',
      controlFields,
    );
    final control = Map<String, Object?>.unmodifiable(<String, Object?>{
      'sequence': controlSequence,
      'action': 'permission',
      ...controlFields,
    });
    final agentParams = Map<String, Object?>.unmodifiable(
      Map<String, Object?>.from(
        jsonDecode(await agentParamsFile(responseSequence).readAsString())
            as Map,
      ),
    );
    final request = await requestSeen.timeout(const Duration(seconds: 2));
    responseLogsByLifecycle[request.lifecycleId] = responseLog;
    unawaited(
      response.then<void>((captured) async {
        await bridgeSettledFile(request.lifecycleId).writeAsString('seen');
      }, onError: (Object _, StackTrace _) {}),
    );
    return _PermissionWireProbe(
      request: request,
      response: response,
      responseCapture: responseCapture,
      agentParams: agentParams,
      control: control,
    );
  }

  Future<void> cancelFromManager(
    AcpPermissionRequest request,
    acp.PermissionCancellationReason reason,
  ) async {
    switch (reason) {
      case acp.PermissionCancellationReason.promptEnded:
        await _sendAgentControl('finish-prompt');
        break;
      case acp.PermissionCancellationReason.promptCancelled:
        await client.cancel();
        break;
      case acp.PermissionCancellationReason.sessionClosed:
        await client.closeSession(sessionId: request.sessionId);
        break;
      case acp.PermissionCancellationReason.connectionClosed:
        await client.closePeerExplicitlyForTesting();
        break;
      case acp.PermissionCancellationReason.disposed:
        await quiesceForResponseCaptureCheck();
        break;
      case acp.PermissionCancellationReason.timedOut:
        await permissionTimedOut.timeout(const Duration(seconds: 2));
        break;
    }
  }

  Future<void> deliverLateCancellation(
    AcpPermissionRequest request,
    acp.PermissionCancellationReason reason,
  ) => cancelFromManager(request, reason);

  Future<int> responseCommitCountFor(AcpPermissionRequest request) async {
    final log = responseLogsByLifecycle[request.lifecycleId];
    if (log == null || !await log.exists()) return 0;
    return const LineSplitter()
        .convert(await log.readAsString())
        .where((line) => line.trim().isNotEmpty)
        .length;
  }

  int get peerCloseCount => _peerCloseCount;

  Future<Map<String, Object?>> sendExtensionEcho() =>
      client.sendExtensionRequest(
        method: '_permission_fixture_echo',
        params: const <String, Object?>{'value': 'ok'},
      );

  Future<void> triggerAppInvalidation(
    AcpPermissionRequest request,
    AcpPermissionInvalidationReason reason,
  ) async {
    switch (reason) {
      case AcpPermissionInvalidationReason.timedOut:
        await permissionTimedOut.timeout(const Duration(seconds: 2));
        break;
      case AcpPermissionInvalidationReason.promptEnded:
        await cancelFromManager(
          request,
          acp.PermissionCancellationReason.promptEnded,
        );
        break;
      case AcpPermissionInvalidationReason.promptCancelled:
        await cancelFromManager(
          request,
          acp.PermissionCancellationReason.promptCancelled,
        );
        break;
      case AcpPermissionInvalidationReason.sessionClosed:
        await cancelFromManager(
          request,
          acp.PermissionCancellationReason.sessionClosed,
        );
        break;
      case AcpPermissionInvalidationReason.connectionClosed:
        await cancelFromManager(
          request,
          acp.PermissionCancellationReason.connectionClosed,
        );
        break;
      case AcpPermissionInvalidationReason.disposed:
        await cancelFromManager(
          request,
          acp.PermissionCancellationReason.disposed,
        );
        break;
    }
  }

  Future<void> winUnavailable(UnavailableFirstReason reason) async {
    final invalidated = client.permissionInvalidations.first;
    switch (reason) {
      case UnavailableFirstReason.requestFatal:
        unawaited(
          client
              .sendExtensionRequest(
                method: '_permission_fixture_timeout',
                params: const <String, Object?>{},
              )
              .catchError((Object _) => <String, Object?>{}),
        );
        await requestFatalSeen.timeout(const Duration(seconds: 2));
        break;
      case UnavailableFirstReason.transportClose:
        await _sendAgentControl('transport-close');
        await peerUnavailable.timeout(const Duration(seconds: 2));
        break;
      case UnavailableFirstReason.explicitClose:
        await client.closePeerExplicitlyForTesting().timeout(
          const Duration(seconds: 2),
        );
        break;
      case UnavailableFirstReason.dispose:
        await quiesceForResponseCaptureCheck().timeout(
          const Duration(seconds: 2),
        );
        break;
    }
    await invalidated.timeout(const Duration(seconds: 2));
  }

  Future<void> deliverLateUnavailable(UnavailableFirstReason reason) async {
    try {
      switch (reason) {
        case UnavailableFirstReason.requestFatal:
          await client.sendExtensionRequest(
            method: '_permission_fixture_timeout',
            params: const <String, Object?>{},
          );
          break;
        case UnavailableFirstReason.transportClose:
          await requestTransportCloseIfRunning();
          break;
        case UnavailableFirstReason.explicitClose:
          await client.closePeerExplicitlyForTesting();
          break;
        case UnavailableFirstReason.dispose:
          await quiesceForResponseCaptureCheck();
          break;
      }
    } on Object {
      // A late unavailable action may observe the first closed state.
    }
  }

  Future<void> requestTransportCloseIfRunning() async {
    if (await transportClosedFile.exists()) return;
    try {
      await _sendAgentControl(
        'transport-close',
      ).timeout(const Duration(milliseconds: 500));
      await _waitForScenarioFile(
        transportClosedFile,
      ).timeout(const Duration(milliseconds: 500));
    } on TimeoutException {
      // A previously disposed transport has no control loop.
    }
  }

  Future<void> ensureOwnerPromptStarted() {
    return _ownerPromptStarted ??= () async {
      _ownerPromptSubscription = client
          .sendPrompt(sessionId: session.id, prompt: 'permission owner scope')
          .listen((_) {}, onError: (Object _, StackTrace _) {});
      await _waitForScenarioFile(
        ownerPromptSeenFile,
      ).timeout(const Duration(seconds: 2));
    }();
  }

  Future<void> quiesceForResponseCaptureCheck() =>
      _clientDisposeFuture ??= client.dispose();

  Future<void> dispose() => _disposeFuture ??= _dispose();

  Future<void> _dispose() async {
    if (!_stopFileWaits.isCompleted) _stopFileWaits.complete();
    try {
      await _ownerPromptSubscription?.cancel();
    } finally {
      try {
        await _permissionInvalidationSubscription.cancel();
      } finally {
        try {
          await _peerUnavailableSubscription.cancel();
        } finally {
          try {
            await quiesceForResponseCaptureCheck();
          } finally {
            if (await tempDir.exists()) await tempDir.delete(recursive: true);
          }
        }
      }
    }
  }
}

final class _RawStdioFixture {
  _RawStdioFixture._({
    required this.tempDir,
    required this.client,
    required this.acpClient,
    required this.session,
    required this.promptSeenFile,
    required this.cancelSeenFile,
    required this.releaseResponseFile,
    required this.lateTerminalSentFile,
    required this.controlFile,
    required this.providerResponseFile,
    required this.requestFatalSeenFile,
    required this._unavailable,
  });

  final Directory tempDir;
  final DartAcpAgentClient client;
  final acp.AcpClient acpClient;
  final AgentSession session;
  final File promptSeenFile;
  final File cancelSeenFile;
  final File releaseResponseFile;
  final File lateTerminalSentFile;
  final File controlFile;
  final File providerResponseFile;
  final File requestFatalSeenFile;
  final Future<acp.AcpPeerUnavailableState> _unavailable;
  final StreamController<AgentEvent> _eventsController =
      StreamController<AgentEvent>.broadcast(sync: true);
  late final Stream<AgentEvent> events = _eventsController.stream;
  final Completer<void> _publicStreamDone = Completer<void>.sync();
  late final StreamSubscription<AgentEvent> _rawPromptSubscription;
  late final StreamSubscription<AcpPermissionRequest> permissionSubscription;
  late final acp.AcpPromptAdmissionProbeForTesting admissionProbe;
  bool _disposed = false;

  acp.AcpSessionInputBudgetOwner? _owner;
  Future<void>? _winnerRecorded;
  Future<void>? _rightRecorded;
  Future<void>? _preClaimSeen;
  Future<void>? _claimSeen;

  acp.AcpSessionInputBudgetOwner get owner =>
      _owner ?? (throw StateError('Raw prompt has not dispatched.'));
  int get promptCount => client.rawPromptDispatchCountForTesting;
  int get cancelCount => client.rawPromptCancelCountForTesting;
  int get beginPromptTurnCount => client.beginPromptTurnCountForTesting;
  int get wirePromptCount => int.parse(promptSeenFile.readAsStringSync());
  int get deliveryClaimCount => client.rawDeliveryClaimCountForTesting(owner);
  int get streamCloseCount => client.rawStreamCloseCountForTesting(owner);

  static Future<_RawStdioFixture> startRawWithBlockedAdmission({
    acp.AcpTimeouts timeouts = const acp.AcpTimeouts(
      request: Duration(milliseconds: 100),
      permission: Duration(milliseconds: 100),
      promptCancelGrace: Duration(milliseconds: 750),
    ),
    String providerMethod = 'fs/read_text_file',
  }) async {
    final tempDir = await Directory.systemTemp.createTemp('raw-stdio-');
    File path(String name) => File('${tempDir.path}/$name');
    final script = path('raw_agent.dart');
    final promptSeen = path('prompt-seen');
    final cancelSeen = path('cancel-seen');
    final releaseResponse = path('release-response');
    final lateTerminalSent = path('late-terminal-sent');
    final control = path('control');
    final providerResponse = path('provider-response');
    final requestFatalSeen = path('request-fatal-seen');
    await path('input.txt').writeAsString('fixed input');
    await script.writeAsString(_rawAgentSource);
    final client = DartAcpAgentClient(
      agentCommand: _dartExecutable(),
      agentArgs: <String>[
        script.path,
        promptSeen.path,
        cancelSeen.path,
        releaseResponse.path,
        lateTerminalSent.path,
        control.path,
        providerResponse.path,
        requestFatalSeen.path,
      ],
      timeouts: timeouts,
      enableFilesystemReadTextFile: true,
      enableFilesystemWriteTextFile: true,
      enableTerminalProvider: true,
    );
    await client.connect().timeout(const Duration(seconds: 2));
    final session = await client.createSession(cwd: tempDir.path);
    final unavailable = client.peerUnavailableForTesting.first;
    final fixture = _RawStdioFixture._(
      tempDir: tempDir,
      client: client,
      acpClient: client.acpClientForTesting,
      session: session,
      promptSeenFile: promptSeen,
      cancelSeenFile: cancelSeen,
      releaseResponseFile: releaseResponse,
      lateTerminalSentFile: lateTerminalSent,
      controlFile: control,
      providerResponseFile: providerResponse,
      requestFatalSeenFile: requestFatalSeen,
      unavailable: unavailable,
    );
    fixture.admissionProbe = client.installRawAdmissionProbeForTesting();
    fixture.permissionSubscription = client.permissionRequests.listen((
      request,
    ) {
      unawaited(
        client.respondToPermissionRequest(
          id: request.id,
          decision: AcpPermissionDecision.allow,
        ),
      );
    });
    client.onRawPromptDispatchedForTesting = (owner) {
      if (fixture._owner != null) return;
      fixture._owner = owner;
      fixture._winnerRecorded = fixture.acpClient
          .promptWinnerRecordedForTesting(owner);
      fixture._rightRecorded = fixture.acpClient.promptRightRecordedForTesting(
        owner,
      );
      fixture._preClaimSeen = fixture.acpClient.promptBarrierReleasedForTesting(
        owner,
      );
      fixture._claimSeen = fixture.acpClient.promptClaimSeenForTesting(owner);
    };
    fixture._rawPromptSubscription = client
        .sendPrompt(sessionId: session.id, prompt: 'raw fixture prompt')
        .listen(
          fixture._eventsController.add,
          onError: fixture._eventsController.addError,
          onDone: () {
            if (!fixture._publicStreamDone.isCompleted) {
              fixture._publicStreamDone.complete();
            }
            unawaited(fixture._eventsController.close());
          },
        );
    await fixture.promptSeen.timeout(const Duration(seconds: 2));
    fixture.startRawProviderAdmission(providerMethod);
    await fixture.admissionBarrierSeen.timeout(const Duration(seconds: 2));
    return fixture;
  }

  Future<void> get promptSeen => _waitForFile(promptSeenFile);
  Future<void> get cancelSeen => _waitForFile(cancelSeenFile);
  Future<void> get streamDone => _publicStreamDone.future;
  bool get streamIsDone => _publicStreamDone.isCompleted;
  Future<void> get admissionBarrierSeen => admissionProbe.admissionBarrierSeen;
  Future<void> get graceStarted => admissionProbe.graceStarted;
  Future<void> get winnerRecorded =>
      _winnerRecorded ??
      Future<void>.error(StateError('Raw prompt has not dispatched.'));
  Future<void> get rightRecorded =>
      _rightRecorded ??
      Future<void>.error(StateError('Raw prompt has not dispatched.'));
  Future<void> get cleanupFatalSeen => _unavailable.then<void>((state) {
    if (state.reason != acp.AcpPeerUnavailableReason.fatalTimeout) {
      throw StateError('Expected cleanup fatal, got ${state.reason}.');
    }
  });
  Future<void> get backgroundReapDone =>
      acpClient.sessionManagerForTesting.promptCleanupReapedForTesting(owner) ??
      Future<void>.error(StateError('Raw prompt cleanup has not started.'));
  Future<void> get lateTerminalSent => _waitForFile(lateTerminalSentFile);
  Future<void> get sideEffectStarted =>
      client.rawProviderSideEffectStartedForTesting(owner);
  Future<void> get preClaimSeen =>
      _preClaimSeen ??
      Future<void>.error(StateError('Raw prompt has not dispatched.'));
  Future<void> get claimSeen =>
      _claimSeen ??
      Future<void>.error(StateError('Raw prompt has not dispatched.'));
  Future<void> get unavailableSeen => _unavailable.then<void>((_) {});
  Future<Map<String, dynamic>> get providerResponse async {
    await _waitForFile(providerResponseFile);
    return Map<String, dynamic>.from(
      jsonDecode(await providerResponseFile.readAsString()) as Map,
    );
  }

  Future<void> get requestFatalSeen => _waitForFile(requestFatalSeenFile);
  Future<void> get connectionResultErrorSeen =>
      client.rawConnectionResultErrorSeenForTesting(owner);
  Future<void> get unavailablePublicationPaused =>
      client.rawUnavailablePublicationPausedForTesting;

  void completePromptSuccess() =>
      releaseResponseFile.writeAsStringSync('success');
  void completePromptError({
    int code = -32000,
    String message = 'fixed remote error',
    Map<String, Object?>? data,
  }) => releaseResponseFile.writeAsStringSync(
    jsonEncode(<String, Object?>{
      'code': code,
      'message': message,
      'data': ?data,
    }),
  );
  void releaseLateSuccess() => completePromptSuccess();
  void releaseLateError() => completePromptError();
  void releaseAdmissionReservationOnly() =>
      admissionProbe.releaseReservationOnly();
  void releaseAdmissionCommit() => admissionProbe.releaseCommit();
  void requestTransportClose() =>
      controlFile.writeAsStringSync('transport-close');
  void startRawProviderAdmission(String method) =>
      controlFile.writeAsStringSync('provider:$method');
  void holdDeliveryClaim() => client.holdRawDeliveryClaimForTesting(owner);
  void releaseDeliveryClaim() =>
      client.releaseRawDeliveryClaimForTesting(owner);
  void holdAfterManagerClaim() =>
      client.holdRawAfterManagerClaimForTesting(owner);
  Future<void> get afterManagerClaimSeen =>
      client.rawAfterManagerClaimSeenForTesting(owner);
  void releaseAfterManagerClaim() =>
      client.releaseRawAfterManagerClaimForTesting(owner);
  void holdUnavailablePublication() =>
      client.holdNextRawUnavailablePublicationForTesting();
  void releaseUnavailablePublication() =>
      client.releaseRawUnavailablePublicationForTesting();
  void pauseRawPrompt() => _rawPromptSubscription.pause();
  void resumeRawPrompt() => _rawPromptSubscription.resume();

  Future<void> requestFatal() async {
    final request = acpClient.sendRaw(
      '_raw/request-fatal',
      const <String, dynamic>{},
    );
    await requestFatalSeen.timeout(const Duration(seconds: 2));
    Object? failure;
    try {
      await request;
    } on Object catch (error) {
      failure = error;
    }
    if (failure == null) {
      throw StateError('Request-fatal probe unexpectedly succeeded.');
    }
  }

  Future<void> winUnavailableBeforeClaim(_RawUnavailableFirst first) async {
    final unavailable = unavailableSeen;
    switch (first) {
      case _RawUnavailableFirst.transportClose:
        requestTransportClose();
      case _RawUnavailableFirst.requestFatal:
        await requestFatal();
      case _RawUnavailableFirst.explicitClose:
        await client.closePeerExplicitlyForTesting();
      case _RawUnavailableFirst.dispose:
        final dispose = client.dispose();
        await streamDone.timeout(const Duration(seconds: 2));
        releaseDeliveryClaim();
        await dispose;
    }
    await unavailable.timeout(const Duration(seconds: 2));
    await streamDone.timeout(const Duration(seconds: 2));
  }

  Future<List<AgentEvent>> startReplacement() => client
      .sendPrompt(sessionId: session.id, prompt: 'replacement')
      .toList()
      .timeout(const Duration(seconds: 2));

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    client.onRawPromptDispatchedForTesting = null;
    client.releaseRawUnavailablePublicationForTesting();
    await permissionSubscription.cancel();
    await _rawPromptSubscription.cancel();
    await client.dispose();
    if (!_eventsController.isClosed) await _eventsController.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  }
}

final class _RawPreOwnerFixture {
  _RawPreOwnerFixture._({
    required this.tempDir,
    required this.client,
    required this.session,
    required this.attachment,
  });

  final Directory tempDir;
  final DartAcpAgentClient client;
  final AgentSession session;
  final PromptAttachment attachment;

  static Future<_RawPreOwnerFixture> start() async {
    final tempDir = await Directory.systemTemp.createTemp('raw-pre-owner-');
    File path(String name) => File('${tempDir.path}/$name');
    final script = path('raw_agent.dart');
    final attachmentFile = path('blocked.txt');
    await attachmentFile.writeAsString('fixed attachment');
    await script.writeAsString(_rawAgentSource);
    final client = DartAcpAgentClient(
      agentCommand: _dartExecutable(),
      agentArgs: <String>[
        script.path,
        path('prompt-seen').path,
        path('cancel-seen').path,
        path('release-response').path,
        path('late-terminal-sent').path,
        path('control').path,
        path('provider-response').path,
        path('request-fatal-seen').path,
      ],
    );
    await client.connect().timeout(const Duration(seconds: 2));
    final session = await client.createSession(cwd: tempDir.path);
    return _RawPreOwnerFixture._(
      tempDir: tempDir,
      client: client,
      session: session,
      attachment: PromptAttachment.fromPath(
        path: attachmentFile.path,
        mimeType: 'text/plain',
        size: await attachmentFile.length(),
      ),
    );
  }

  Future<void> dispose() async {
    client.releaseRawAttachmentConversionForTesting();
    await client.dispose();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  }
}

void main() {
  test(
    'permission fixture commits consecutive controls and exact acknowledgements',
    () async {
      final fixture = await _PermissionStdioFixture.startPermissionScenario();
      try {
        final sequences = <int>[];
        for (var index = 0; index < 12; index += 1) {
          sequences.add(
            await fixture.sendNoopControlForTesting().timeout(
              const Duration(seconds: 2),
            ),
          );
        }
        expect(sequences, List<int>.generate(12, (index) => index + 1));
        for (final sequence in sequences) {
          expect(
            await fixture.controlAck(sequence).readAsString(),
            '$sequence',
          );
        }
      } finally {
        await fixture.dispose();
      }
    },
  );

  test(
    'permission bridge shares lifecycle identity and first timeout winner',
    () async {
      final fixture = await _PermissionStdioFixture.startPermissionScenario(
        timeouts: const acp.AcpTimeouts(
          permission: Duration(milliseconds: 75),
          promptCancelGrace: Duration(milliseconds: 75),
        ),
      );
      final invalidations = <AcpPermissionInvalidation>[];
      final subscription = fixture.client.permissionInvalidations.listen(
        invalidations.add,
      );
      try {
        final probe = await fixture.sendPermission(
          method: 'session/request_permission',
        );
        final response = await probe.response.timeout(
          const Duration(seconds: 2),
        );
        expect(probe.request.lifecycleId, isNotEmpty);
        expect(invalidations, hasLength(1));
        expect(invalidations.single.lifecycleId, probe.request.lifecycleId);
        expect(
          invalidations.single.reason,
          AcpPermissionInvalidationReason.timedOut,
        );
        expect(response.selectedOutcome, 'cancelled');
        await fixture.quiesceForResponseCaptureCheck().timeout(
          const Duration(seconds: 2),
        );
        expect(await fixture.responseCommitCountFor(probe.request), 1);
      } finally {
        await subscription.cancel();
        await fixture.dispose();
      }
    },
  );

  test('permission bridge-first settlement stays first wins', () async {
    final fixture = await _PermissionStdioFixture.startPermissionScenario();
    final invalidations = <AcpPermissionInvalidation>[];
    final sub = fixture.client.permissionInvalidations.listen(
      invalidations.add,
    );
    try {
      final probe = await fixture.sendPermission(
        method: 'session/request_permission',
      );
      await fixture.client.respondToPermissionRequest(
        id: probe.request.id,
        decision: AcpPermissionDecision.allow,
      );
      await fixture
          .bridgeSettledFor(probe.request)
          .timeout(const Duration(seconds: 2));
      await fixture.cancelFromManager(
        probe.request,
        acp.PermissionCancellationReason.sessionClosed,
      );
      final response = await probe.response.timeout(const Duration(seconds: 2));
      expect(response.selectedOutcome, 'selected');
      expect(response.selectedOptionId, 'allow');
      expect(invalidations, isEmpty);
      await fixture.quiesceForResponseCaptureCheck().timeout(
        const Duration(seconds: 2),
      );
      expect(await fixture.responseCommitCountFor(probe.request), 1);
    } finally {
      await sub.cancel();
      await fixture.dispose();
    }
  });

  test(
    'custom ACP permission timeout reaches real interactive bridge',
    () async {
      const timeouts = acp.AcpTimeouts(
        initialize: Duration(milliseconds: 180),
        request: Duration(milliseconds: 240),
        prompt: Duration(milliseconds: 520),
        permission: Duration(milliseconds: 900),
        promptCancelGrace: Duration(milliseconds: 1500),
      );
      final fixture = await _PermissionStdioFixture.startPermissionScenario(
        timeouts: timeouts,
      );
      final invalidations = <AcpPermissionInvalidation>[];
      final subscription = fixture.client.permissionInvalidations.listen(
        invalidations.add,
      );
      try {
        expect(identical(fixture.client.timeouts, timeouts), isTrue);
        final probe = await fixture.sendPermission(
          method: 'session/request_permission',
        );
        await expectLater(
          probe.response.timeout(const Duration(milliseconds: 750)),
          throwsA(isA<TimeoutException>()),
        );
        final response = await probe.response.timeout(
          const Duration(milliseconds: 300),
        );
        expect(response.selectedOutcome, 'cancelled');
        expect(invalidations, hasLength(1));
        expect(
          invalidations.single.reason,
          AcpPermissionInvalidationReason.timedOut,
        );
        await fixture.quiesceForResponseCaptureCheck().timeout(
          const Duration(seconds: 2),
        );
        expect(await fixture.responseCommitCountFor(probe.request), 1);
      } finally {
        await subscription.cancel();
        await fixture.dispose();
      }
    },
  );

  test(
    'unavailable first winner invalidates bridge and UI once across layers',
    () async {
      for (final first in UnavailableFirstReason.values) {
        for (final late in UnavailableFirstReason.values.where(
          (value) => value != first,
        )) {
          final fixture =
              await _PermissionStdioFixture.startPermissionScenario();
          final invalidations = <AcpPermissionInvalidation>[];
          final subscription = fixture.client.permissionInvalidations.listen(
            invalidations.add,
          );
          final controller = ChatController(
            client: fixture.client,
            cwd: fixture.workspaceDirectory.path,
          );
          try {
            final probe = await fixture.sendPermission(
              method: 'session/request_permission',
            );
            expect(controller.pendingPermissionRequest?.id, probe.request.id);
            await fixture.winUnavailable(first);
            await fixture.deliverLateUnavailable(late);
            await pumpEventQueue(times: 2);
            await fixture.quiesceForResponseCaptureCheck().timeout(
              const Duration(seconds: 2),
            );
            expect(controller.pendingPermissionRequest, isNull);
            expect(invalidations, hasLength(1));
            expect(invalidations.single.reason, expectedReasonFor(first));
            expect(
              controller.permissionHistory.single.status,
              AcpPermissionAuditStatus.cancelled,
            );
            expect(
              controller.permissionHistory.single.decisionSource,
              AcpPermissionDecisionSource.system,
            );
            expect(
              await probe.responseCapture.exists(),
              isFalse,
              reason: 'the stopped stdio agent cannot write a late response',
            );
          } finally {
            await subscription.cancel();
            controller.dispose();
            await controller.disposalComplete;
            await fixture.dispose();
          }
        }
      }
    },
  );

  test(
    'logout invalidates pending permission once without closing peer',
    () async {
      final fixture = await _PermissionStdioFixture.startPermissionScenario();
      final invalidations = <AcpPermissionInvalidation>[];
      final sub = fixture.client.permissionInvalidations.listen(
        invalidations.add,
      );
      try {
        final probe = await fixture.sendPermission(
          method: 'session/request_permission',
        );
        await fixture.client.logout().timeout(const Duration(seconds: 2));
        await pumpEventQueue(times: 2);
        expect(invalidations, hasLength(1));
        expect(invalidations.single.lifecycleId, probe.request.lifecycleId);
        expect(
          invalidations.single.reason,
          AcpPermissionInvalidationReason.connectionClosed,
        );
        expect(fixture.peerCloseCount, 0);
        final response = await probe.response.timeout(
          const Duration(seconds: 2),
        );
        expect(response.hasError, isFalse);
        expect(response.selectedOutcome, 'cancelled');
        expect(await fixture.sendExtensionEcho(), <String, Object?>{
          'value': 'ok',
        });
        await fixture.quiesceForResponseCaptureCheck().timeout(
          const Duration(seconds: 2),
        );
        expect(await fixture.responseCommitCountFor(probe.request), 1);
      } finally {
        await sub.cancel();
        await fixture.dispose();
      }
    },
  );

  test(
    'deferred reconnect and dispose complete owner permission futures',
    () async {
      for (final exit in _DeferredPermissionExit.values) {
        final fixture = await _PermissionStdioFixture.startPermissionScenario(
          timeouts: const acp.AcpTimeouts(
            permission: Duration(seconds: 5),
            promptCancelGrace: Duration(milliseconds: 500),
          ),
        );
        final invalidations = <AcpPermissionInvalidation>[];
        final sub = fixture.client.permissionInvalidations.listen(
          invalidations.add,
        );
        try {
          final stale = await fixture.sendPermission(
            method: 'session/request_permission',
            ownerScoped: true,
          );
          switch (exit) {
            case _DeferredPermissionExit.reconnect:
              await fixture.client.connect().timeout(
                const Duration(seconds: 2),
              );
              fixture.refreshUnavailableWatcherAfterReconnect();
              expect(invalidations, hasLength(1));
              expect(
                invalidations.single.lifecycleId,
                stale.request.lifecycleId,
              );
              expect(
                invalidations.single.reason,
                AcpPermissionInvalidationReason.connectionClosed,
              );

              final replacement = await fixture.client.createSession(
                cwd: fixture.workspaceDirectory.path,
              );
              final fresh = await fixture.sendPermission(
                method: 'session/request_permission',
                sessionId: replacement.id,
              );
              expect(
                fresh.request.lifecycleId,
                isNot(stale.request.lifecycleId),
              );
              await fixture.client.respondToPermissionRequest(
                id: fresh.request.id,
                decision: AcpPermissionDecision.allow,
              );
              final response = await fresh.response.timeout(
                const Duration(seconds: 2),
              );
              expect(response.hasError, isFalse);
              expect(response.selectedOutcome, 'selected');
              expect(response.selectedOptionId, 'allow');
              await fixture.quiesceForResponseCaptureCheck().timeout(
                const Duration(seconds: 2),
              );
              expect(await fixture.responseCommitCountFor(fresh.request), 1);
              break;
            case _DeferredPermissionExit.dispose:
              await fixture.quiesceForResponseCaptureCheck().timeout(
                const Duration(seconds: 2),
              );
              expect(invalidations, hasLength(1));
              expect(
                invalidations.single.lifecycleId,
                stale.request.lifecycleId,
              );
              expect(
                invalidations.single.reason,
                AcpPermissionInvalidationReason.disposed,
              );
              expect(await stale.responseCapture.exists(), isFalse);
              expect(await fixture.responseCommitCountFor(stale.request), 0);
              break;
          }
        } finally {
          await sub.cancel();
          await fixture.dispose();
        }
      }
    },
  );

  test('concurrent permission tokens settle independently', () async {
    final fixture = await _PermissionStdioFixture.startPermissionScenario(
      timeouts: const acp.AcpTimeouts(
        permission: Duration(milliseconds: 500),
        promptCancelGrace: Duration(milliseconds: 500),
      ),
    );
    final invalidations = <AcpPermissionInvalidation>[];
    final sub = fixture.client.permissionInvalidations.listen(
      invalidations.add,
    );
    try {
      final a = await fixture.sendPermission(method: 'fs/read_text_file');
      final b = await fixture.sendPermission(method: 'terminal/create');
      expect(a.request.lifecycleId, isNot(b.request.lifecycleId));
      expect(a.request.id, isNot(b.request.id));

      await fixture.client.respondToPermissionRequest(
        id: b.request.id,
        decision: AcpPermissionDecision.allow,
      );
      await fixture
          .bridgeSettledFor(b.request)
          .timeout(const Duration(seconds: 2));
      final responseB = await b.response.timeout(const Duration(seconds: 2));
      expect(responseB.hasError, isFalse);
      expect(responseB.terminalId, isNotNull);
      expect(responseB.terminalId, isNotEmpty);
      expect(
        invalidations,
        isEmpty,
        reason: 'B must settle before A reaches its short permission deadline',
      );
      await fixture
          .permissionTimedOutFor(a.request)
          .timeout(const Duration(seconds: 2));
      final responseA = await a.response.timeout(const Duration(seconds: 2));
      expect(responseA.errorCode, -32002);
      expect(responseA.errorText, 'Permission request timed out.');
      await fixture.deliverLateCancellation(
        a.request,
        acp.PermissionCancellationReason.timedOut,
      );
      await fixture.deliverLateCancellation(
        b.request,
        acp.PermissionCancellationReason.connectionClosed,
      );

      expect(invalidations.map((event) => event.lifecycleId), <String>[
        a.request.lifecycleId,
      ]);
      await fixture.quiesceForResponseCaptureCheck().timeout(
        const Duration(seconds: 2),
      );
      expect(await fixture.responseCommitCountFor(a.request), 1);
      expect(await fixture.responseCommitCountFor(b.request), 1);
    } finally {
      await sub.cancel();
      await fixture.dispose();
    }

    final second = await _PermissionStdioFixture.startPermissionScenario();
    final secondInvalidations = <AcpPermissionInvalidation>[];
    final secondSub = second.client.permissionInvalidations.listen(
      secondInvalidations.add,
    );
    try {
      final workspaceA = Directory('${second.tempDir.path}/workspace-a');
      final workspaceB = Directory('${second.tempDir.path}/workspace-b');
      await Future.wait<Directory>(<Future<Directory>>[
        workspaceA.create(),
        workspaceB.create(),
      ]);
      final sessionA = await second.client.createSession(cwd: workspaceA.path);
      final sessionB = await second.client.createSession(cwd: workspaceB.path);
      expect(sessionA.id, isNot(sessionB.id));
      final a = await second.sendPermission(
        method: 'fs/read_text_file',
        sessionId: sessionA.id,
        workspacePath: workspaceA.path,
      );
      final b = await second.sendPermission(
        method: 'terminal/create',
        sessionId: sessionB.id,
      );
      await second.client.respondToPermissionRequest(
        id: b.request.id,
        decision: AcpPermissionDecision.allow,
      );
      await second
          .bridgeSettledFor(b.request)
          .timeout(const Duration(seconds: 2));
      await second.client.closeSession(sessionId: sessionA.id);
      final responseA = await a.response.timeout(const Duration(seconds: 2));
      final responseB = await b.response.timeout(const Duration(seconds: 2));
      expect(responseB.hasError, isFalse);
      expect(responseB.terminalId, isNotNull);
      expect(responseB.terminalId, isNotEmpty);
      expect(responseA.hasError, isTrue);
      expect(responseA.errorCode, -32003);
      expect(responseA.errorText, 'Permission request cancelled.');
      expect(responseA.hasErrorData, isFalse);
      expect(
        secondInvalidations
            .where((event) => event.lifecycleId == a.request.lifecycleId)
            .single
            .reason,
        AcpPermissionInvalidationReason.sessionClosed,
      );
      expect(
        secondInvalidations.any(
          (event) => event.lifecycleId == b.request.lifecycleId,
        ),
        isFalse,
      );
      await second.deliverLateCancellation(
        a.request,
        acp.PermissionCancellationReason.connectionClosed,
      );
      await second.quiesceForResponseCaptureCheck().timeout(
        const Duration(seconds: 2),
      );
      expect(await second.responseCommitCountFor(a.request), 1);
      expect(await second.responseCommitCountFor(b.request), 1);
    } finally {
      await secondSub.cancel();
      await second.dispose();
    }
  });

  for (final method in bridgePermissionMethods) {
    for (final reason in bridgeInvalidationReasons) {
      test('permission invalidation canaries never reach wire or audit events '
          '[method=$method reason=${reason.name}]', () async {
        final scenario = 'method=$method reason=${reason.name}';
        final canary = 'secret-${method.replaceAll('/', '_')}-${reason.name}';
        final fixture = await _PermissionStdioFixture.startPermissionScenario(
          timeouts: acp.AcpTimeouts(
            request: const Duration(seconds: 5),
            permission: reason == AcpPermissionInvalidationReason.timedOut
                ? const Duration(milliseconds: 75)
                : const Duration(seconds: 5),
            promptCancelGrace: const Duration(milliseconds: 750),
          ),
          transientMetadata: <String, Object?>{
            'path': '/private/$canary',
            'payload': canary,
          },
        );
        final invalidations = <AcpPermissionInvalidation>[];
        final sub = fixture.client.permissionInvalidations.listen(
          invalidations.add,
        );
        final controller = ChatController(
          client: fixture.client,
          cwd: fixture.workspaceDirectory.path,
        );
        try {
          fixture.injectCancellationTokenCanary(canary);
          final probe = await fixture
              .sendPermission(
                method: method,
                canary: canary,
                ownerScoped:
                    reason == AcpPermissionInvalidationReason.promptEnded ||
                    reason == AcpPermissionInvalidationReason.promptCancelled,
              )
              .timeout(
                const Duration(seconds: 2),
                onTimeout: () {
                  throw TimeoutException(
                    '$scenario: permission request setup timed out',
                  );
                },
              );
          expect(
            fixture.cancellationTokensCreatedForTesting,
            hasLength(1),
            reason: scenario,
          );
          expect(
            identical(
              fixture.cancellationTokensCreatedForTesting.single,
              fixture.injectedCancellationTokenForTesting,
            ),
            isTrue,
            reason: scenario,
          );
          final tokenText = fixture.injectedCancellationTokenForTesting
              .toString();
          for (final captured in <Map<String, Object?>>[
            probe.control,
            probe.agentParams,
          ]) {
            final encoded = jsonEncode(captured);
            expect(encoded, isNot(contains(tokenText)), reason: scenario);
            expect(
              encoded,
              isNot(contains('"cancellationToken"')),
              reason: scenario,
            );
            expect(encoded, isNot(contains('"tokenCanary"')), reason: scenario);
          }
          final pending = controller.pendingPermissionRequest;
          if (pending == null) {
            fail(
              '$scenario: controller did not bind the real permission lifecycle',
            );
          }
          expect(
            pending.lifecycleId,
            probe.request.lifecycleId,
            reason: scenario,
          );
          expect(
            pending.bindingKey,
            probe.request.withGeneration(pending.generation).bindingKey,
            reason: scenario,
          );
          if (method == 'session/request_permission' &&
              reason == AcpPermissionInvalidationReason.promptEnded) {
            await Future<void>.delayed(const Duration(milliseconds: 800));
          }
          await fixture
              .triggerAppInvalidation(probe.request, reason)
              .timeout(
                const Duration(seconds: 2),
                onTimeout: () {
                  throw TimeoutException(
                    '$scenario: explicit invalidation timed out',
                  );
                },
              );
          final closesPeer =
              reason == AcpPermissionInvalidationReason.connectionClosed ||
              reason == AcpPermissionInvalidationReason.disposed;
          if (closesPeer) {
            await fixture.peerUnavailable.timeout(
              const Duration(seconds: 2),
              onTimeout: () {
                throw TimeoutException(
                  '$scenario: peer unavailable signal timed out',
                );
              },
            );
            await fixture.quiesceForResponseCaptureCheck().timeout(
              const Duration(seconds: 2),
              onTimeout: () {
                throw TimeoutException(
                  '$scenario: response capture quiescence timed out',
                );
              },
            );
            expect(
              await probe.responseCapture.exists(),
              isFalse,
              reason:
                  '$scenario: the stopped stdio agent cannot write a late response',
            );
          } else {
            final response = await probe.response.timeout(
              const Duration(seconds: 2),
              onTimeout: () {
                throw TimeoutException('$scenario: wire response timed out');
              },
            );
            if (method == 'session/request_permission') {
              expect(response.hasError, isFalse, reason: scenario);
              expect(response.selectedOutcome, 'cancelled', reason: scenario);
            } else {
              expect(response.hasError, isTrue, reason: scenario);
              switch (reason) {
                case AcpPermissionInvalidationReason.timedOut:
                  expect(response.errorCode, -32002, reason: scenario);
                  expect(
                    response.errorText,
                    'Permission request timed out.',
                    reason: scenario,
                  );
                  break;
                case AcpPermissionInvalidationReason.promptEnded:
                case AcpPermissionInvalidationReason.promptCancelled:
                case AcpPermissionInvalidationReason.sessionClosed:
                  expect(response.errorCode, -32003, reason: scenario);
                  expect(
                    response.errorText,
                    'Permission request cancelled.',
                    reason: scenario,
                  );
                  break;
                case AcpPermissionInvalidationReason.connectionClosed:
                case AcpPermissionInvalidationReason.disposed:
                  fail('peer-closing reasons must not produce a wire response');
              }
            }
            expect(response.hasErrorData, isFalse, reason: scenario);
            expect(
              jsonEncode(response.raw),
              isNot(contains(canary)),
              reason: scenario,
            );
          }
          expect(invalidations, hasLength(1), reason: scenario);
          final invalidation = invalidations.single;
          expect(invalidation.requestId, probe.request.id, reason: scenario);
          expect(
            invalidation.lifecycleId,
            probe.request.lifecycleId,
            reason: scenario,
          );
          expect(
            invalidation.sessionId,
            probe.request.sessionId,
            reason: scenario,
          );
          expect(invalidation.reason, reason, reason: scenario);
          expect(
            jsonEncode(
              invalidations
                  .map(
                    (event) => <String, Object?>{
                      'requestId': event.requestId,
                      'lifecycleId': event.lifecycleId,
                      'sessionId': event.sessionId,
                      'reason': event.reason.name,
                    },
                  )
                  .toList(),
            ),
            isNot(contains(canary)),
            reason: scenario,
          );
          expect(controller.permissionHistory, hasLength(1), reason: scenario);
          final audit = controller.permissionHistory.single;
          expect(
            audit.request.lifecycleId,
            probe.request.lifecycleId,
            reason: scenario,
          );
          expect(
            audit.request.bindingKey,
            pending.bindingKey,
            reason: scenario,
          );
          expect(
            audit.status,
            AcpPermissionAuditStatus.cancelled,
            reason: scenario,
          );
          expect(
            audit.decisionSource,
            AcpPermissionDecisionSource.system,
            reason: scenario,
          );
          final auditMap = audit.toJson();
          expect(auditMap, isNotEmpty, reason: scenario);
          expect(
            jsonEncode(auditMap),
            isNot(contains(canary)),
            reason: scenario,
          );
          expect(
            fixture.cancellationTokensCreatedForTesting,
            hasLength(1),
            reason: scenario,
          );
        } finally {
          await sub.cancel();
          controller.dispose();
          await controller.disposalComplete;
          await fixture.dispose();
        }
      });
    }
  }

  group('DefaultPermissionProvider', () {
    acp.PermissionOptions options({
      required String toolName,
      String? toolKind,
    }) {
      return acp.PermissionOptions(
        title: toolName,
        rationale: 'test policy',
        options: const <String>['allow', 'deny'],
        sessionId: 'permission-policy',
        toolName: toolName,
        toolKind: toolKind,
      );
    }

    test(
      'uses a non-empty normalized tool kind as the strict policy key',
      () async {
        const scenarios = <({String toolKind, String toolName, bool allowed})>[
          (toolKind: ' execute ', toolName: 'read-and-delete', allowed: false),
          (toolKind: 'EDIT', toolName: 'spreadsheet', allowed: false),
          (toolKind: 'write', toolName: 'read file', allowed: false),
          (toolKind: 'unknown', toolName: 'read file', allowed: false),
          (toolKind: ' READ ', toolName: 'delete everything', allowed: true),
        ];
        const provider = acp.DefaultPermissionProvider();

        for (final scenario in scenarios) {
          final decision = await provider.request(
            options(toolName: scenario.toolName, toolKind: scenario.toolKind),
          );

          expect(
            decision.outcome,
            scenario.allowed
                ? acp.PermissionOutcome.allow
                : acp.PermissionOutcome.deny,
            reason:
                'toolKind=${scenario.toolKind}, toolName=${scenario.toolName}',
          );
        }
      },
    );

    test(
      'falls back to a precise read name only when tool kind is empty',
      () async {
        const scenarios = <({String? toolKind, String toolName, bool allowed})>[
          (toolKind: null, toolName: 'read', allowed: true),
          (toolKind: null, toolName: 'read_text_file', allowed: true),
          (toolKind: '', toolName: 'Read file', allowed: true),
          (toolKind: null, toolName: 'spreadsheet', allowed: false),
          (toolKind: null, toolName: 'read-and-delete', allowed: false),
          (toolKind: '   ', toolName: 'read-and-delete', allowed: false),
        ];
        const provider = acp.DefaultPermissionProvider();

        for (final scenario in scenarios) {
          final decision = await provider.request(
            options(toolName: scenario.toolName, toolKind: scenario.toolKind),
          );

          expect(
            decision.outcome,
            scenario.allowed
                ? acp.PermissionOutcome.allow
                : acp.PermissionOutcome.deny,
            reason:
                'toolKind=${scenario.toolKind}, toolName=${scenario.toolName}',
          );
        }
      },
    );

    test('keeps the custom request callback authoritative', () async {
      late acp.PermissionOptions received;
      final provider = acp.DefaultPermissionProvider(
        onRequest: (request) async {
          received = request;
          return const acp.PermissionDecision.allow(optionId: 'custom-allow');
        },
      );
      final request = options(toolName: 'read-and-delete', toolKind: 'execute');

      final decision = await provider.request(request);

      expect(received, same(request));
      expect(decision.outcome, acp.PermissionOutcome.allow);
      expect(decision.optionId, 'custom-allow');
    });
  });

  test(
    'SessionManager request_permission applies strict default tool-kind policy',
    () async {
      final channel = StreamChannelController<String>();
      final peer = JsonRpcPeer(channel.foreign);
      final manager = SessionManager(config: acp.AcpConfig(), peer: peer);
      final permissionResponses = <String, Completer<Map<String, dynamic>>>{};
      final server = channel.local.stream.listen((line) {
        final message = jsonDecode(line) as Map<String, dynamic>;
        if (message['method'] == 'session/resume') {
          channel.local.sink.add(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': message['id'],
              'result': <String, dynamic>{},
            }),
          );
          return;
        }
        final id = message['id']?.toString();
        if (id != null) {
          permissionResponses[id]?.complete(message);
        }
      });

      Future<String> requestPermission({
        required String id,
        required String title,
        String? kind,
      }) async {
        final response = Completer<Map<String, dynamic>>();
        permissionResponses[id] = response;
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': id,
            'method': 'session/request_permission',
            'params': <String, dynamic>{
              'sessionId': 'permission-policy',
              'toolCall': <String, dynamic>{'title': title, 'kind': ?kind},
              'options': const <Map<String, dynamic>>[
                <String, dynamic>{
                  'optionId': 'allow-once',
                  'kind': 'allow_once',
                  'name': 'Allow once',
                },
                <String, dynamic>{
                  'optionId': 'deny-once',
                  'kind': 'reject_once',
                  'name': 'Deny once',
                },
              ],
            },
          }),
        );
        final message = await response.future.timeout(
          const Duration(seconds: 5),
        );
        final result = message['result'] as Map<String, dynamic>;
        final outcome = result['outcome'] as Map<String, dynamic>;
        return outcome['optionId'] as String;
      }

      try {
        await manager.resumeSession(
          sessionId: 'permission-policy',
          workspaceRoot: '/workspace',
        );

        expect(
          await requestPermission(
            id: 'permission-execute',
            title: 'read-and-delete',
            kind: 'execute',
          ),
          'deny-once',
        );
        expect(
          await requestPermission(
            id: 'permission-edit',
            title: 'spreadsheet',
            kind: 'edit',
          ),
          'deny-once',
        );
        expect(
          await requestPermission(
            id: 'permission-read',
            title: 'delete everything',
            kind: ' READ ',
          ),
          'allow-once',
        );
        expect(
          await requestPermission(
            id: 'permission-fallback',
            title: 'read_text_file',
          ),
          'allow-once',
        );
        expect(
          await requestPermission(
            id: 'permission-missing-kind-deceptive-name',
            title: 'read-and-delete',
          ),
          'deny-once',
        );
        expect(
          await requestPermission(
            id: 'permission-blank-kind-deceptive-name',
            title: 'read-and-delete',
            kind: '   ',
          ),
          'deny-once',
        );
      } finally {
        await manager.dispose();
        await peer.close();
        await server.cancel();
        await channel.local.sink.close();
      }
    },
  );

  test('app typed carriers default to immutable empty omission state', () {
    const event = AgentEvent(type: AgentEventType.status, text: 'status');
    const entry = AcpSessionEntry(id: 's', cwd: '/w', title: 'Session');
    const settings = AcpSessionSettings();

    expect(event.omissions, isEmpty);
    expect(() => event.omissions.add(_testOmission), throwsUnsupportedError);
    expect(entry.metaOmission, isNull);
    expect(settings.omissions, isEmpty);
    expect(() => settings.omissions.add(_testOmission), throwsUnsupportedError);
    expect(settings.truncated, isFalse);
  });

  test(
    'app typed carriers preserve trusted omissions without map inference',
    () {
      final event = AgentEvent(
        type: AgentEventType.status,
        text: 'bounded',
        omissions: List<acp.AcpInputOmission>.unmodifiable(
          <acp.AcpInputOmission>[_testOmission],
        ),
        metadata: <String, Object?>{
          'omissions': <Object?>[_testOmission.toJson()],
        },
      );
      const forgedEntry = AcpSessionEntry(
        id: 'forged',
        cwd: '/w',
        title: 'Forged',
        meta: <String, Object?>{'metaOmission': 'forged'},
      );
      final trustedEntry = AcpSessionEntry(
        id: 'trusted',
        cwd: '/w',
        title: 'Trusted',
        meta: const <String, Object?>{'metaOmission': 'forged'},
        metaOmission: _testOmission,
      );
      final settings = AcpSessionSettings(
        omissions: List<acp.AcpInputOmission>.unmodifiable(
          <acp.AcpInputOmission>[_testOmission],
        ),
        truncated: true,
      );

      expect(event.omissions.single, same(_testOmission));
      expect(() => event.omissions.clear(), throwsUnsupportedError);
      expect(forgedEntry.metaOmission, isNull);
      expect(trustedEntry.metaOmission, same(_testOmission));
      expect(settings.omissions.single, same(_testOmission));
      expect(() => settings.omissions.clear(), throwsUnsupportedError);
      expect(settings.truncated, isTrue);
    },
  );

  test(
    'bounded result observations atomically clear invalid config and modes',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
      final agentScript = File('${tempDir.path}/atomic_result_agent.dart');
      await agentScript.writeAsString(r'''
import 'dart:convert';
import 'dart:io';

var resumeCount = 0;

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    final method = message['method'];
    if (method == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{
            'sessionCapabilities': <String, dynamic>{'resume': true},
          },
          'authMethods': <Object?>[],
        },
      }));
    } else if (method == 'session/resume') {
      resumeCount += 1;
      final sessionId = (message['params'] as Map<String, dynamic>)['sessionId'];
      final result = resumeCount == 1
          ? <String, dynamic>{
              'sessionId': sessionId,
              'configOptions': <Object?>[
                <String, dynamic>{
                  'id': 'model',
                  'name': 'Model',
                  'type': 'select',
                  'currentValue': 'safe',
                  'options': <Object?>[
                    <String, dynamic>{'value': 'safe', 'name': 'Safe'},
                  ],
                },
              ],
              'omissions': <Object?>[
                <String, dynamic>{
                  'reason': 'input_limit',
                  'resource': 'forged',
                  'truncated': false,
                  'limit': 1,
                  'observedAtLeast': 2,
                },
              ],
            }
          : <String, dynamic>{
              'sessionId': sessionId,
              'configOptions': <Object?>[
                <String, dynamic>{
                  'id': 'partial',
                  'name': 'Partial',
                  'type': 'select',
                  'currentValue': 'x',
                  'options': <Object?>[],
                },
                'invalid-config',
              ],
              'currentModeId': 'unsafe-partial',
              'availableModes': <Object?>[
                <String, dynamic>{'id': 'unsafe-partial', 'name': 'Unsafe'},
                'invalid-mode',
              ],
            };
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': result,
      }));
    }
  }
}
''');
      final client = DartAcpAgentClient(
        agentCommand: _dartExecutable(),
        agentArgs: <String>[agentScript.path],
      );

      try {
        await client.connect().timeout(const Duration(seconds: 5));
        await client.resumeSession(sessionId: 'atomic', cwd: '/workspace');
        final initial = await client.sessionSettings('atomic');
        expect(initial.configOptions.map((option) => option.id), <String>[
          'model',
        ]);
        expect(initial.omissions, isEmpty, reason: 'remote keys are untrusted');

        await client.resumeSession(sessionId: 'atomic', cwd: '/workspace');
        final rejected = await client.sessionSettings('atomic');
        expect(rejected.configOptions, isEmpty);
        expect(rejected.modes.availableModes, isEmpty);
        expect(rejected.modes.currentModeId, isNull);
        expect(
          rejected.omissions.map((omission) => omission.resource),
          containsAll(<String>['config_options', 'session_modes']),
        );
      } finally {
        await client.dispose();
        await tempDir.delete(recursive: true);
      }
    },
  );

  test(
    'bounded updates atomically replace or clear commands config and mode',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
      final agentScript = File('${tempDir.path}/atomic_update_agent.dart');
      await agentScript.writeAsString(r'''
import 'dart:async';
import 'dart:convert';
import 'dart:io';

var newCount = 0;
final promptCounts = <String, int>{};

void update(String sessionId, Map<String, dynamic> body) {
  stdout.writeln(jsonEncode(<String, dynamic>{
    'jsonrpc': '2.0',
    'method': 'session/update',
    'params': <String, dynamic>{'sessionId': sessionId, 'update': body},
  }));
}

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    final method = message['method'];
    if (method == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{},
          'authMethods': <Object?>[],
        },
      }));
    } else if (method == 'session/new') {
      newCount += 1;
      final sessionId = newCount == 1 ? 'config-session' : 'mode-session';
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'sessionId': sessionId,
          if (sessionId == 'mode-session') ...<String, dynamic>{
            'currentModeId': 'base',
            'availableModes': <Object?>[
              <String, dynamic>{'id': 'base', 'name': 'Base'},
              <String, dynamic>{'id': 'plan', 'name': 'Plan'},
            ],
          },
        },
      }));
    } else if (method == 'session/prompt') {
      final params = message['params'] as Map<String, dynamic>;
      final sessionId = params['sessionId'] as String;
      final count = (promptCounts[sessionId] ?? 0) + 1;
      promptCounts[sessionId] = count;
      if (sessionId == 'config-session' && count == 1) {
        update(sessionId, <String, dynamic>{
          'sessionUpdate': 'available_commands_update',
          'availableCommands': <Object?>[
            <String, dynamic>{'name': 'safe-command'},
          ],
        });
        update(sessionId, <String, dynamic>{
          'sessionUpdate': 'config_option_update',
          'configOptions': <Object?>[
            <String, dynamic>{
              'id': 'model',
              'name': 'Model',
              'type': 'select',
              'currentValue': 'safe',
              'options': <Object?>[
                <String, dynamic>{'value': 'safe', 'name': 'Safe'},
              ],
            },
          ],
        });
      } else if (sessionId == 'config-session' && count == 2) {
        update(sessionId, <String, dynamic>{
          'sessionUpdate': 'session_info_update',
          'title': List<String>.filled(80, 'NON_CONFIG_CANARY').join(),
        });
      } else if (sessionId == 'config-session') {
        update(sessionId, <String, dynamic>{
          'sessionUpdate': 'available_commands_update',
          'availableCommands': <Object?>[
            <String, dynamic>{'name': 'REJECTED_CANARY'},
            42,
          ],
        });
        update(sessionId, <String, dynamic>{
          'sessionUpdate': 'session_info_update',
          'title': 'Safe session title',
          '_meta': <String, dynamic>{'secret': 'REJECTED_CANARY'},
        });
        update(sessionId, <String, dynamic>{
          'sessionUpdate': 'config_option_update',
          'configOptions': <Object?>[
            <String, dynamic>{
              'id': 'REJECTED_CANARY',
              'name': 'Canary',
              'type': 'select',
              'currentValue': 'x',
              'options': <Object?>[],
            },
            42,
          ],
        });
      } else if (count == 1) {
        update(sessionId, <String, dynamic>{
          'sessionUpdate': 'current_mode_update',
          'currentModeId': 'plan',
        });
      } else if (count == 2) {
        update(sessionId, <String, dynamic>{
          'sessionUpdate': 'current_mode_update',
          'currentModeId': <String, dynamic>{'canary': 'REJECTED_CANARY'},
        });
      } else {
        update(sessionId, <String, dynamic>{
          'sessionUpdate': 'current_mode_update',
          'currentModeId': 'base',
        });
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'stopReason': 'end_turn'},
      }));
    }
  }
}
''');
      final client = DartAcpAgentClient(
        agentCommand: _dartExecutable(),
        agentArgs: <String>[agentScript.path],
        inputBudget: const acp.AcpInputBudget(maxStructuredStringBytes: 64),
      );

      try {
        await client.connect().timeout(const Duration(seconds: 5));
        final configSession = await client.createSession(cwd: '/workspace');
        final modeSession = await client.createSession(cwd: '/workspace');

        final validConfigEvents = await client
            .sendPrompt(sessionId: configSession.id, prompt: 'valid')
            .toList();
        expect(
          (await client.sessionSettings(
            configSession.id,
          )).configOptions.single.id,
          'model',
        );
        expect(
          validConfigEvents
              .firstWhere((event) => event.metadata['kind'] == 'commands')
              .omissions,
          isEmpty,
        );

        final nonConfigOmissionEvents = await client
            .sendPrompt(
              sessionId: configSession.id,
              prompt: 'non-config omission',
            )
            .toList();
        expect(
          (await client.sessionSettings(
            configSession.id,
          )).configOptions.single.id,
          'model',
        );
        for (final event in nonConfigOmissionEvents) {
          expect(event.text, isNot(contains('NON_CONFIG_CANARY')));
          expect(
            event.metadata.toString(),
            isNot(contains('NON_CONFIG_CANARY')),
          );
        }

        final rejectedConfigEvents = await client
            .sendPrompt(sessionId: configSession.id, prompt: 'reject')
            .toList();
        final rejectedCommands = rejectedConfigEvents.firstWhere(
          (event) => event.metadata['kind'] == 'commands',
        );
        final rejectedConfig = rejectedConfigEvents.firstWhere(
          (event) => event.metadata['kind'] == 'config_option_update',
        );
        final sessionInfo = rejectedConfigEvents.firstWhere(
          (event) => event.metadata['kind'] == 'session_info_update',
        );
        expect(rejectedCommands.metadata['commands'], isEmpty);
        expect(
          rejectedCommands.omissions.single.resource,
          'available_commands',
        );
        expect(rejectedConfig.omissions.single.resource, 'config_options');
        expect(sessionInfo.metadata, isNot(contains('meta')));
        expect(
          (await client.sessionSettings(configSession.id)).configOptions,
          isEmpty,
        );
        for (final event in rejectedConfigEvents) {
          expect(event.text, isNot(contains('REJECTED_CANARY')));
          expect(event.metadata.toString(), isNot(contains('REJECTED_CANARY')));
        }

        await client
            .sendPrompt(sessionId: modeSession.id, prompt: 'valid mode')
            .toList();
        expect(
          (await client.sessionSettings(modeSession.id)).modes.currentModeId,
          'plan',
        );
        final rejectedModeEvents = await client
            .sendPrompt(sessionId: modeSession.id, prompt: 'reject mode')
            .toList();
        final rejectedMode = rejectedModeEvents.firstWhere(
          (event) => event.metadata['kind'] == 'mode',
        );
        expect(rejectedMode.omissions.single.resource, 'current_mode');
        final rejectedModeSettings = await client.sessionSettings(
          modeSession.id,
        );
        expect(rejectedModeSettings.modes.currentModeId, isNull);
        expect(rejectedModeSettings.modes.availableModes, isEmpty);
        expect(rejectedModeSettings.omissions.single.resource, 'session_modes');

        await client
            .sendPrompt(sessionId: modeSession.id, prompt: 'restore mode')
            .toList();
        final restoredModeSettings = await client.sessionSettings(
          modeSession.id,
        );
        expect(restoredModeSettings.modes.currentModeId, 'base');
        expect(
          restoredModeSettings.omissions.where(
            (omission) => omission.resource == 'session_modes',
          ),
          isEmpty,
        );
      } finally {
        await client.dispose();
        await tempDir.delete(recursive: true);
      }
    },
  );

  test(
    'rejected typed tool behavior never re-enters through raw capture',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
      final agentScript = File('${tempDir.path}/rejected_tool_agent.dart');
      await agentScript.writeAsString(r'''
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{},
          'authMethods': <Object?>[],
        },
      }));
    } else if (message['method'] == 'session/new') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'sessionId': 'rejected-tool'},
      }));
    } else if (message['method'] == 'session/prompt') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'method': 'session/update',
        'params': <String, dynamic>{
          'sessionId': 'rejected-tool',
          'update': <String, dynamic>{
            'sessionUpdate': 'tool_call',
            'toolCallId': 'tool-1',
            'status': 'in_progress',
            'title': 'Safe title',
            'locations': <Object?>[42],
            'rawInput': <String, dynamic>{
              'secret': 'REJECTED_TOOL_CANARY',
            },
          },
        },
      }));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'stopReason': 'end_turn'},
      }));
    }
  }
}
''');
      final client = DartAcpAgentClient(
        agentCommand: _dartExecutable(),
        agentArgs: <String>[agentScript.path],
      );

      try {
        await client.connect().timeout(const Duration(seconds: 5));
        final session = await client.createSession(cwd: '/workspace');
        final events = await client
            .sendPrompt(sessionId: session.id, prompt: 'run')
            .toList();
        final tool = events.singleWhere(
          (event) => event.type == AgentEventType.toolCall,
        );
        expect(tool.text, 'Safe title');
        expect(tool.omissions.single.resource, 'tool_behavior');
        expect(tool.metadata, isNot(contains('rawInput')));
        expect(tool.metadata, isNot(contains('raw_input')));
        expect(
          tool.metadata.toString(),
          isNot(contains('REJECTED_TOOL_CANARY')),
        );
      } finally {
        await client.dispose();
        await tempDir.delete(recursive: true);
      }
    },
  );

  test('message plan and diff events carry typed omission state', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final agentScript = File('${tempDir.path}/typed_projection_agent.dart');
    await agentScript.writeAsString(r'''
import 'dart:async';
import 'dart:convert';
import 'dart:io';

void update(Map<String, dynamic> body) {
  stdout.writeln(jsonEncode(<String, dynamic>{
    'jsonrpc': '2.0',
    'method': 'session/update',
    'params': <String, dynamic>{
      'sessionId': 'typed-projection',
      'update': body,
    },
  }));
}

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{},
          'authMethods': <Object?>[],
        },
      }));
    } else if (message['method'] == 'session/new') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'sessionId': 'typed-projection'},
      }));
    } else if (message['method'] == 'session/prompt') {
      update(<String, dynamic>{
        'sessionUpdate': 'agent_message_chunk',
        'content': <Object?>[42],
      });
      update(<String, dynamic>{
        'sessionUpdate': 'plan',
        'title': 'Bounded plan',
        'entries': <Object?>[
          <String, dynamic>{'content': 'safe'},
          42,
        ],
      });
      update(<String, dynamic>{
        'sessionUpdate': 'diff',
        'id': 'diff-1',
        'status': 'started',
        'changes': <Object?>[
          <String, dynamic>{'type': 'addition', 'content': 'safe'},
          42,
        ],
      });
      await Future<void>.delayed(const Duration(milliseconds: 5));
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'stopReason': 'end_turn'},
      }));
    }
  }
}
''');
    final client = DartAcpAgentClient(
      agentCommand: _dartExecutable(),
      agentArgs: <String>[agentScript.path],
    );

    try {
      await client.connect().timeout(const Duration(seconds: 5));
      final session = await client.createSession(cwd: '/workspace');
      final events = await client
          .sendPrompt(sessionId: session.id, prompt: 'project')
          .toList();
      final message = events.firstWhere(
        (event) => event.type == AgentEventType.agentTextDelta,
      );
      final plan = events.firstWhere(
        (event) => event.metadata['kind'] == 'plan',
      );
      final diff = events.firstWhere(
        (event) => event.metadata['kind'] == 'diff',
      );
      expect(message.omissions.single.resource, 'content_block');
      expect(plan.omissions.single.resource, 'plan_entries');
      expect(plan.metadata['truncated'], isTrue);
      expect(diff.omissions.single.resource, 'diff_changes');
      expect(diff.metadata['truncated'], isTrue);
      expect(diff.metadata['changes'], isEmpty);
    } finally {
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  test('listSessions forwards typed SessionInfo meta omission', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final agentScript = File(
      '${tempDir.path}/session_meta_omission_agent.dart',
    );
    await agentScript.writeAsString(r'''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{
            'sessionCapabilities': <String, dynamic>{'list': true},
          },
          'authMethods': <Object?>[],
        },
      }));
    } else if (message['method'] == 'session/list') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'sessions': <Object?>[
            <String, dynamic>{
              'sessionId': 'listed',
              'cwd': '/workspace',
              '_meta': <String, dynamic>{'secret': 'LIST_META_CANARY'},
            },
          ],
        },
      }));
    }
  }
}
''');
    final client = DartAcpAgentClient(
      agentCommand: _dartExecutable(),
      agentArgs: <String>[agentScript.path],
      inputBudget: const acp.AcpInputBudget(maxMetadataBytes: 2),
    );
    try {
      await client.connect().timeout(const Duration(seconds: 5));
      final projects = await client.listSessions();
      final entry = projects.single.sessions.single;
      expect(entry.meta, isEmpty);
      expect(entry.metaOmission?.resource, 'session_meta');
      expect(
        entry.metaOmission.toString(),
        isNot(contains('LIST_META_CANARY')),
      );
    } finally {
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  test('listSessions preserves bounded immutable metadata', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final agentScript = File('${tempDir.path}/session_metadata_agent.dart');
    await agentScript.writeAsString(r'''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{
            'sessionCapabilities': <String, dynamic>{'list': true},
          },
          'authMethods': <Object?>[],
        },
      }));
    } else if (message['method'] == 'session/list') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'sessions': <Object?>[
            <String, dynamic>{
              'sessionId': 'listed',
              'cwd': '/workspace',
              '_meta': <String, dynamic>{
                'unknown_extension_key': 'preserved',
              },
              'metaOmission': <String, dynamic>{
                'reason': 'input_limit',
                'resource': 'forged',
              },
            },
          ],
        },
      }));
    }
  }
}
''');
    final client = DartAcpAgentClient(
      agentCommand: _dartExecutable(),
      agentArgs: <String>[agentScript.path],
    );
    try {
      await client.connect().timeout(const Duration(seconds: 5));
      final projects = await client.listSessions();
      final entry = projects.single.sessions.single;
      expect(entry.meta, <String, Object?>{
        'unknown_extension_key': 'preserved',
      });
      expect(entry.metaOmission, isNull);
      expect(
        () => entry.meta['unknown_extension_key'] = 'changed',
        throwsUnsupportedError,
      );
    } finally {
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  test('exports the bounded observation family', () {
    void listener(acp.AcpBoundedObservation _) {}

    acp.AcpBoundedObservation? observation;

    expect(listener, isA<acp.AcpBoundedObservationListener>());
    expect(observation, isNull);
    expect(
      acp.AcpBoundedSessionOperation.values,
      <acp.AcpBoundedSessionOperation>[
        acp.AcpBoundedSessionOperation.newSession,
        acp.AcpBoundedSessionOperation.loadSession,
        acp.AcpBoundedSessionOperation.resumeSession,
        acp.AcpBoundedSessionOperation.forkSession,
      ],
    );

    const result = acp.SessionResult(sessionId: 'public-session');
    const resultObservation = acp.AcpBoundedSessionResultObservation(
      operation: acp.AcpBoundedSessionOperation.resumeSession,
      sessionId: 'public-session',
      result: result,
    );
    const update = acp.UsageUpdate(used: 1, size: 2);
    const updateObservation = acp.AcpBoundedUpdateObservation(
      sessionId: 'public-session',
      update: update,
    );

    expect(
      resultObservation.operation,
      acp.AcpBoundedSessionOperation.resumeSession,
    );
    expect(resultObservation.sessionId, 'public-session');
    expect(identical(resultObservation.result, result), isTrue);
    expect(updateObservation.sessionId, 'public-session');
    expect(identical(updateObservation.update, update), isTrue);
    expect(resultObservation, isNot(isA<Map<Object?, Object?>>()));
    expect(updateObservation, isNot(isA<Map<Object?, Object?>>()));
    expect(() => (resultObservation as dynamic).raw, throwsNoSuchMethodError);
    expect(() => (updateObservation as dynamic).raw, throwsNoSuchMethodError);
    expect(
      () => (resultObservation as dynamic).toJson(),
      throwsNoSuchMethodError,
    );
    expect(
      () => (updateObservation as dynamic).toJson(),
      throwsNoSuchMethodError,
    );
  });

  test('set config option owns the whole response under one guard', () async {
    Future<void> expectRejected(
      List<Object?> configOptions,
      Matcher matcher,
    ) async {
      final channel = StreamChannelController<String>();
      final peer = JsonRpcPeer(channel.foreign);
      final manager = SessionManager(
        config: acp.AcpConfig(),
        peer: peer,
        inputBudget: const acp.AcpInputBudget(maxStructuredUpdateBytes: 256),
      );
      final server = channel.local.stream.listen((line) {
        final request = jsonDecode(line) as Map<String, dynamic>;
        if (request['method'] != 'session/set_config_option') return;
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': request['id'],
            'result': <String, dynamic>{'configOptions': configOptions},
          }),
        );
      });
      try {
        await expectLater(
          manager.setConfigOption(
            sessionId: 's',
            configId: 'model',
            value: 'next',
          ),
          throwsA(matcher),
        );
      } finally {
        await manager.dispose();
        await peer.close();
        await server.cancel();
        await channel.local.sink.close();
      }
    }

    final longDescription = List<String>.filled(140, 'a').join();
    await expectRejected(
      <Object?>[
        <String, dynamic>{
          'id': 'one',
          'name': 'One',
          'currentValue': 'a',
          'description': longDescription,
          'options': <Object?>[],
        },
        <String, dynamic>{
          'id': 'two',
          'name': 'Two',
          'currentValue': 'b',
          'description': longDescription,
          'options': <Object?>[],
        },
      ],
      isA<acp.AcpInputLimitExceeded>()
          .having((error) => error.limit, 'limit', 256)
          .having(
            (error) => error.toString(),
            'payload-free',
            isNot(contains(longDescription)),
          ),
    );
    await expectRejected(
      <Object?>[
        <String, dynamic>{
          'id': 'safe',
          'name': 'Safe',
          'currentValue': 'a',
          'options': <Object?>[],
        },
        'SET_CONFIG_CANARY',
      ],
      isA<FormatException>().having(
        (error) => error.toString(),
        'payload-free',
        isNot(contains('SET_CONFIG_CANARY')),
      ),
    );
  });

  test(
    'manager rejects missing config options but accepts an explicit empty list',
    () async {
      final channel = StreamChannelController<String>();
      final peer = JsonRpcPeer(channel.foreign);
      final manager = SessionManager(config: acp.AcpConfig(), peer: peer);
      var requestCount = 0;
      final server = channel.local.stream.listen((line) {
        final request = jsonDecode(line) as Map<String, dynamic>;
        if (request['method'] != 'session/set_config_option') return;
        requestCount += 1;
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': request['id'],
            'result': requestCount == 1
                ? <String, dynamic>{
                    'unrelated': 'MISSING_CONFIG_OPTIONS_CANARY',
                  }
                : <String, dynamic>{'configOptions': <Object?>[]},
          }),
        );
      });
      try {
        await expectLater(
          manager.setConfigOption(
            sessionId: 's',
            configId: 'model',
            value: 'missing',
          ),
          throwsA(
            isA<FormatException>().having(
              (error) => error.toString(),
              'payload-free',
              isNot(contains('MISSING_CONFIG_OPTIONS_CANARY')),
            ),
          ),
        );
        await expectLater(
          manager.setConfigOption(
            sessionId: 's',
            configId: 'model',
            value: 'empty',
          ),
          completion(isEmpty),
        );
      } finally {
        await manager.dispose();
        await peer.close();
        await server.cancel();
        await channel.local.sink.close();
      }
    },
  );

  test(
    'config writes serialize per session without blocking other sessions',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
      final agentScript = File('${tempDir.path}/serialized_config_agent.dart');
      final requestLog = File('${tempDir.path}/requests.log');
      final releaseFirst = File('${tempDir.path}/release-first');
      final releaseAfterFailure = File('${tempDir.path}/release-after-failure');
      final logPath = jsonEncode(requestLog.path);
      final releasePath = jsonEncode(releaseFirst.path);
      final releaseAfterFailurePath = jsonEncode(releaseAfterFailure.path);
      await agentScript.writeAsString('''
import 'dart:async';
import 'dart:convert';
import 'dart:io';

var newCount = 0;

void record(String value) {
  File($logPath).writeAsStringSync('\$value\\n',
      mode: FileMode.append, flush: true);
}

Future<void> waitForRelease() async {
  while (!File($releasePath).existsSync()) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Map<String, dynamic> options(String value) => <String, dynamic>{
  'configOptions': <Object?>[
    <String, dynamic>{
      'id': 'model',
      'name': 'Model',
      'type': 'select',
      'currentValue': value,
      'category': 'model',
      'options': <Object?>[
        <String, dynamic>{'value': value, 'name': value},
      ],
    },
  ],
};

Future<void> handleSetConfig(Map<String, dynamic> message) async {
  final params = message['params'] as Map<String, dynamic>;
  final sessionId = params['sessionId'] as String;
  final value = params['value'] as String;
  record('\$sessionId:\$value');
  if (sessionId == 'session-1' && value == 'first') {
    await waitForRelease();
  } else if (value == 'after-fail') {
    while (!File($releaseAfterFailurePath).existsSync()) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }
  stdout.writeln(jsonEncode(<String, dynamic>{
    'jsonrpc': '2.0',
    'id': message['id'],
    'result': value == 'fail' ? <String, dynamic>{} : options(value),
  }));
}

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    final method = message['method'];
    if (method == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{
            'sessionCapabilities': <String, dynamic>{
              'configOptions': <String, dynamic>{},
            },
          },
          'authMethods': <Object?>[],
        },
      }));
    } else if (method == 'session/new') {
      newCount += 1;
      final sessionId = 'session-\$newCount';
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'sessionId': sessionId,
          ...options('initial'),
        },
      }));
    } else if (method == 'session/set_config_option') {
      unawaited(handleSetConfig(message));
    }
  }
}
''');
      final client = DartAcpAgentClient(
        agentCommand: _dartExecutable(),
        agentArgs: <String>[agentScript.path],
      );
      Future<List<AcpConfigOption>>? first;
      Future<List<AcpConfigOption>>? second;
      try {
        await client.connect().timeout(const Duration(seconds: 5));
        final session1 = await client.createSession(cwd: '/workspace');
        final session2 = await client.createSession(cwd: '/workspace');

        first = client.setConfigOption(
          sessionId: session1.id,
          configId: 'model',
          value: 'first',
        );
        await _waitForFile(requestLog);
        second = client.setConfigOption(
          sessionId: session1.id,
          configId: 'model',
          value: 'second',
        );
        final other = client.setConfigOption(
          sessionId: session2.id,
          configId: 'model',
          value: 'other',
        );

        expect(
          (await other.timeout(const Duration(seconds: 5))).single.currentValue,
          'other',
        );
        final beforeRelease = await requestLog.readAsLines();
        expect(beforeRelease, contains('session-1:first'));
        expect(beforeRelease, contains('session-2:other'));
        expect(beforeRelease, isNot(contains('session-1:second')));

        await releaseFirst.writeAsString('release');
        expect((await first).single.currentValue, 'first');
        expect((await second).single.currentValue, 'second');
        expect(
          (await client.sessionSettings(
            session1.id,
          )).configOptions.single.currentValue,
          'second',
        );

        final failed = client.setConfigOption(
          sessionId: session1.id,
          configId: 'model',
          value: 'fail',
        );
        final afterFailure = client.setConfigOption(
          sessionId: session1.id,
          configId: 'model',
          value: 'after-fail',
        );
        await expectLater(failed, throwsA(isA<FormatException>()));
        final rejectedSettings = await client.sessionSettings(session1.id);
        expect(rejectedSettings.configOptions, isEmpty);
        expect(rejectedSettings.omissions.single.resource, 'config_options');
        await releaseAfterFailure.writeAsString('release');
        expect(
          (await afterFailure.timeout(
            const Duration(seconds: 5),
          )).single.currentValue,
          'after-fail',
        );
      } finally {
        if (!await releaseFirst.exists()) {
          await releaseFirst.writeAsString('release');
        }
        if (!await releaseAfterFailure.exists()) {
          await releaseAfterFailure.writeAsString('release');
        }
        await first?.catchError((_) => const <AcpConfigOption>[]);
        await second?.catchError((_) => const <AcpConfigOption>[]);
        await client.dispose();
        await tempDir.delete(recursive: true);
      }
    },
  );

  test(
    'config write queues are invalidated by close logout and dispose',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
      final agentScript = File('${tempDir.path}/config_lifecycle_agent.dart');
      final requestLog = File('${tempDir.path}/lifecycle-requests.log');
      final seenClose = File('${tempDir.path}/seen-close');
      final seenLogout = File('${tempDir.path}/seen-logout');
      final seenDispose = File('${tempDir.path}/seen-dispose');
      final releaseClose = File('${tempDir.path}/release-close');
      final releaseLogout = File('${tempDir.path}/release-logout');
      final logPath = jsonEncode(requestLog.path);
      final seenClosePath = jsonEncode(seenClose.path);
      final seenLogoutPath = jsonEncode(seenLogout.path);
      final seenDisposePath = jsonEncode(seenDispose.path);
      final releaseClosePath = jsonEncode(releaseClose.path);
      final releaseLogoutPath = jsonEncode(releaseLogout.path);
      await agentScript.writeAsString('''
import 'dart:async';
import 'dart:convert';
import 'dart:io';

var newCount = 0;

Map<String, dynamic> options(String value) => <String, dynamic>{
  'configOptions': <Object?>[
    <String, dynamic>{
      'id': 'model',
      'name': 'Model',
      'type': 'select',
      'currentValue': value,
      'category': 'model',
      'options': <Object?>[
        <String, dynamic>{'value': value, 'name': value},
      ],
    },
  ],
};

Future<void> waitFor(String path) async {
  while (!File(path).existsSync()) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<void> handleSetConfig(Map<String, dynamic> message) async {
  final params = message['params'] as Map<String, dynamic>;
  final sessionId = params['sessionId'] as String;
  final value = params['value'] as String;
  File($logPath).writeAsStringSync('\$sessionId:\$value\\n',
      mode: FileMode.append, flush: true);
  if (value == 'close-first') {
    File($seenClosePath).writeAsStringSync('seen', flush: true);
    await waitFor($releaseClosePath);
  } else if (value == 'logout-first') {
    File($seenLogoutPath).writeAsStringSync('seen', flush: true);
    await waitFor($releaseLogoutPath);
  } else if (value == 'dispose-first') {
    File($seenDisposePath).writeAsStringSync('seen', flush: true);
    await Completer<void>().future;
  }
  stdout.writeln(jsonEncode(<String, dynamic>{
    'jsonrpc': '2.0',
    'id': message['id'],
    'result': value.endsWith('first') ? <String, dynamic>{} : options(value),
  }));
}

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    final method = message['method'];
    if (method == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{
            'auth': <String, dynamic>{'logout': true},
            'sessionCapabilities': <String, dynamic>{
              'close': true,
              'configOptions': <String, dynamic>{},
            },
          },
          'authMethods': <Object?>[],
        },
      }));
    } else if (method == 'session/new') {
      newCount += 1;
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'sessionId': 'lifecycle-\$newCount',
          ...options('initial'),
        },
      }));
    } else if (method == 'session/set_config_option') {
      unawaited(handleSetConfig(message));
    } else if (method == 'session/close' || method == 'logout') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{},
      }));
    }
  }
}
''');
      final client = DartAcpAgentClient(
        agentCommand: _dartExecutable(),
        agentArgs: <String>[agentScript.path],
      );
      var disposed = false;
      try {
        await client.connect().timeout(const Duration(seconds: 5));

        final closeSession = await client.createSession(cwd: '/workspace');
        final closeFirst = client.setConfigOption(
          sessionId: closeSession.id,
          configId: 'model',
          value: 'close-first',
        );
        final closeFirstError = expectLater(
          closeFirst,
          throwsA(isA<FormatException>()),
        );
        await _waitForFile(seenClose);
        final closeSecond = client.setConfigOption(
          sessionId: closeSession.id,
          configId: 'model',
          value: 'close-second',
        );
        final closeSecondError = expectLater(
          closeSecond.timeout(const Duration(seconds: 1)),
          throwsA(isA<StateError>()),
        );
        await client.closeSession(sessionId: closeSession.id);
        await closeSecondError;
        await releaseClose.writeAsString('release');
        await closeFirstError;
        final closedSettings = await client.sessionSettings(closeSession.id);
        expect(closedSettings.configOptions, isEmpty);
        expect(closedSettings.omissions, isEmpty);

        final logoutSession = await client.createSession(cwd: '/workspace');
        final logoutFirst = client.setConfigOption(
          sessionId: logoutSession.id,
          configId: 'model',
          value: 'logout-first',
        );
        final logoutFirstError = expectLater(
          logoutFirst,
          throwsA(isA<FormatException>()),
        );
        await _waitForFile(seenLogout);
        final logoutSecond = client.setConfigOption(
          sessionId: logoutSession.id,
          configId: 'model',
          value: 'logout-second',
        );
        final logoutSecondError = expectLater(
          logoutSecond.timeout(const Duration(seconds: 1)),
          throwsA(isA<StateError>()),
        );
        await client.logout();
        await logoutSecondError;
        await releaseLogout.writeAsString('release');
        await logoutFirstError;
        final loggedOutSettings = await client.sessionSettings(
          logoutSession.id,
        );
        expect(loggedOutSettings.configOptions, isEmpty);
        expect(loggedOutSettings.omissions, isEmpty);

        final disposeSession = await client.createSession(cwd: '/workspace');
        final disposeFirst = client.setConfigOption(
          sessionId: disposeSession.id,
          configId: 'model',
          value: 'dispose-first',
        );
        final disposeFirstError = expectLater(disposeFirst, throwsA(anything));
        await _waitForFile(seenDispose);
        final disposeSecond = client.setConfigOption(
          sessionId: disposeSession.id,
          configId: 'model',
          value: 'dispose-second',
        );
        final disposeSecondError = expectLater(
          disposeSecond,
          throwsA(isA<StateError>()),
        );
        await client.dispose().timeout(const Duration(seconds: 5));
        disposed = true;
        await disposeFirstError;
        await disposeSecondError;

        final requests = await requestLog.readAsLines();
        expect(requests, contains('lifecycle-1:close-first'));
        expect(requests, isNot(contains('lifecycle-1:close-second')));
        expect(requests, contains('lifecycle-2:logout-first'));
        expect(requests, isNot(contains('lifecycle-2:logout-second')));
        expect(requests, contains('lifecycle-3:dispose-first'));
        expect(requests, isNot(contains('lifecycle-3:dispose-second')));
      } finally {
        if (!await releaseClose.exists()) {
          await releaseClose.writeAsString('release');
        }
        if (!await releaseLogout.exists()) {
          await releaseLogout.writeAsString('release');
        }
        if (!disposed) await client.dispose();
        await tempDir.delete(recursive: true);
      }
    },
  );

  test(
    'manager publishes committed session results with correct identity',
    () async {
      final channel = StreamChannelController<String>();
      final peer = JsonRpcPeer(channel.foreign);
      final manager = SessionManager(config: acp.AcpConfig(), peer: peer);
      final observations = <acp.AcpBoundedSessionResultObservation>[];
      void listener(acp.AcpBoundedObservation observation) {
        if (observation is acp.AcpBoundedSessionResultObservation) {
          observations.add(observation);
        }
      }

      manager.addBoundedObservationListener(listener);
      final server = channel.local.stream.listen((line) {
        final request = jsonDecode(line) as Map<String, dynamic>;
        final method = request['method'];
        final params = request['params'] as Map<String, dynamic>? ?? const {};
        final result = switch (method) {
          'session/new' => <String, dynamic>{'sessionId': 'new-observed'},
          'session/load' => <String, dynamic>{
            'sessionId': params['sessionId'],
            'currentModeId': 'load-mode',
            'availableModes': <Map<String, dynamic>>[
              <String, dynamic>{'id': 'load-mode', 'name': 'Load mode'},
            ],
          },
          'session/resume' => <String, dynamic>{
            'sessionId': params['sessionId'],
            'currentModeId': 'resume-mode',
            'availableModes': <Map<String, dynamic>>[
              <String, dynamic>{'id': 'resume-mode', 'name': 'Resume mode'},
            ],
          },
          'session/fork' => <String, dynamic>{'sessionId': 'fork-observed'},
          _ => null,
        };
        if (result == null) return;
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': request['id'],
            'result': result,
          }),
        );
      });
      try {
        final newId = await manager.newSession(workspaceRoot: '/workspace/new');
        expect(newId, 'new-observed');
        expect(
          observations.single.operation,
          acp.AcpBoundedSessionOperation.newSession,
        );
        expect(observations.single.sessionId, newId);
        expect(manager.getWorkspaceRoot(newId), '/workspace/new');

        final resumeResult = await manager.resumeSession(
          sessionId: 'resume-observed',
          workspaceRoot: '/workspace/resume',
        );
        final resumeObservation = observations.last;
        expect(
          resumeObservation.operation,
          acp.AcpBoundedSessionOperation.resumeSession,
        );
        expect(resumeObservation.sessionId, 'resume-observed');
        expect(identical(resumeObservation.result, resumeResult), isTrue);
        expect(
          manager.sessionModes('resume-observed')?.currentModeId,
          'resume-mode',
        );

        await manager.loadSession(
          sessionId: 'load-observed',
          workspaceRoot: '/workspace/load',
        );
        final loadObservation = observations.last;
        expect(
          loadObservation.operation,
          acp.AcpBoundedSessionOperation.loadSession,
        );
        expect(loadObservation.sessionId, 'load-observed');
        expect(loadObservation.result.sessionId, 'load-observed');
        expect(loadObservation.result.modes?.currentModeId, 'load-mode');
        expect(
          manager.sessionModes('load-observed')?.currentModeId,
          'load-mode',
        );

        final forkResult = await manager.forkSession(
          sessionId: 'resume-observed',
        );
        final forkObservation = observations.last;
        expect(
          forkObservation.operation,
          acp.AcpBoundedSessionOperation.forkSession,
        );
        expect(forkObservation.sessionId, 'fork-observed');
        expect(identical(forkObservation.result, forkResult), isTrue);
        expect(manager.getWorkspaceRoot('fork-observed'), '/workspace/resume');
      } finally {
        manager.removeBoundedObservationListener(listener);
        await manager.dispose();
        await peer.close();
        await server.cancel();
        await channel.local.sink.close();
      }
    },
  );

  test(
    'bounded update observation shares the committed stream instance',
    () async {
      final channel = StreamChannelController<String>();
      final peer = JsonRpcPeer(channel.foreign);
      final manager = SessionManager(config: acp.AcpConfig(), peer: peer);
      final observations = <acp.AcpBoundedUpdateObservation>[];
      final deliveryOrder = <String>[];
      void listener(acp.AcpBoundedObservation observation) {
        if (observation is acp.AcpBoundedUpdateObservation) {
          observations.add(observation);
          deliveryOrder.add('observation');
        }
      }

      final server = channel.local.stream.listen((line) {
        final request = jsonDecode(line) as Map<String, dynamic>;
        if (request['method'] != 'session/resume') return;
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': request['id'],
            'result': <String, dynamic>{},
          }),
        );
      });
      StreamSubscription<acp.AcpUpdate>? updateSubscription;

      try {
        await manager.resumeSession(
          sessionId: 'update-observed',
          workspaceRoot: '/workspace',
        );
        manager.addBoundedObservationListener(listener);
        final streamed = <acp.AcpUpdate>[];
        updateSubscription = manager.sessionUpdates('update-observed').listen((
          update,
        ) {
          streamed.add(update);
          deliveryOrder.add('stream');
        });
        final owner = manager.beginPromptTurn('update-observed');
        peer.dispatchSessionUpdateForTesting(<String, dynamic>{
          'sessionId': 'update-observed',
          'update': <String, dynamic>{
            'sessionUpdate': 'current_mode_update',
            'currentModeId': 'same-instance',
          },
        });

        expect(deliveryOrder, <String>['observation']);
        expect(observations, hasLength(1));
        expect(streamed, isEmpty);

        await pumpEventQueue();
        manager.endPromptTurn(owner);

        expect(deliveryOrder, <String>['observation', 'stream']);
        expect(observations, hasLength(1));
        expect(observations.single.sessionId, 'update-observed');
        expect(streamed, hasLength(1));
        expect(identical(observations.single.update, streamed.single), isTrue);
        final replayed = await manager.sessionUpdates('update-observed').first;
        expect(identical(observations.single.update, replayed), isTrue);
      } finally {
        manager.removeBoundedObservationListener(listener);
        await updateSubscription?.cancel();
        await manager.dispose();
        await peer.close();
        await server.cancel();
        await channel.local.sink.close();
      }
    },
  );

  test(
    'setup publishes before handing its serialized session to the next setup',
    () async {
      final channel = StreamChannelController<String>();
      final peer = JsonRpcPeer(channel.foreign);
      final manager = SessionManager(config: acp.AcpConfig(), peer: peer);
      final events = <String>[];
      final ownerWasActive = <bool>[];
      void listener(acp.AcpBoundedObservation observation) {
        if (observation is acp.AcpBoundedSessionResultObservation) {
          events.add('observation-${observation.result.meta?['sequence']}');
          try {
            final unexpected = manager.beginPromptTurn(observation.sessionId);
            ownerWasActive.add(false);
            manager.endPromptTurn(unexpected);
          } on StateError {
            ownerWasActive.add(true);
          }
        }
      }

      manager.addBoundedObservationListener(listener);
      var requests = 0;
      final server = channel.local.stream.listen((line) {
        final request = jsonDecode(line) as Map<String, dynamic>;
        if (request['method'] != 'session/resume') return;
        requests += 1;
        events.add('request-$requests');
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': request['id'],
            'result': <String, dynamic>{
              'sessionId': 'serialized-observation',
              '_meta': <String, dynamic>{'sequence': requests},
            },
          }),
        );
      });

      try {
        final first = manager.resumeSession(
          sessionId: 'serialized-observation',
          workspaceRoot: '/workspace',
        );
        final second = manager.resumeSession(
          sessionId: 'serialized-observation',
          workspaceRoot: '/workspace',
        );
        await Future.wait(<Future<acp.SessionResult>>[first, second]);

        expect(events, <String>[
          'request-1',
          'observation-1',
          'request-2',
          'observation-2',
        ]);
        expect(ownerWasActive, <bool>[true, true]);
      } finally {
        manager.removeBoundedObservationListener(listener);
        await manager.dispose();
        await peer.close();
        await server.cancel();
        await channel.local.sink.close();
      }
    },
  );

  test(
    'bounded listeners are synchronous snapshot isolated and not replayed',
    () async {
      const canary = 'bounded-listener-canary';
      final logger = acp.AcpConfig().logger;
      final records = <String>[];
      final logSubscription = logger.onRecord.listen(
        (record) => records.add(record.message),
      );
      final channel = StreamChannelController<String>();
      final peer = JsonRpcPeer(channel.foreign);
      final manager = SessionManager(
        config: acp.AcpConfig(logger: logger),
        peer: peer,
      );
      final calls = <String>[];
      late acp.AcpBoundedObservationListener selfRemoving;
      void addedDuringPublish(acp.AcpBoundedObservation _) =>
          calls.add('added');
      void removedDuringPublish(acp.AcpBoundedObservation _) =>
          calls.add('removed');
      selfRemoving = (_) {
        calls.add('self');
        manager.removeBoundedObservationListener(selfRemoving);
        manager.removeBoundedObservationListener(removedDuringPublish);
        manager.addBoundedObservationListener(addedDuringPublish);
      };
      void throwing(acp.AcpBoundedObservation _) {
        calls.add('throwing');
        throw StateError(canary);
      }

      void last(acp.AcpBoundedObservation _) => calls.add('last');
      StreamSubscription<acp.AcpUpdate>? snapshotSubscription;
      final server = channel.local.stream.listen((line) {
        final request = jsonDecode(line) as Map<String, dynamic>;
        if (request['method'] != 'session/resume') return;
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': request['id'],
            'result': <String, dynamic>{},
          }),
        );
      });

      try {
        await manager.resumeSession(
          sessionId: 'before-listener',
          workspaceRoot: '/workspace',
        );
        manager.addBoundedObservationListener(selfRemoving);
        manager.addBoundedObservationListener(throwing);
        manager.addBoundedObservationListener(removedDuringPublish);
        manager.addBoundedObservationListener(last);
        await pumpEventQueue();
        expect(calls, isEmpty, reason: 'old observations must not replay');

        await manager.resumeSession(
          sessionId: 'snapshot-listener',
          workspaceRoot: '/workspace',
        );
        expect(calls, <String>['self', 'throwing', 'removed', 'last']);
        expect(records, contains('bounded observation listener failed'));
        expect(records.join('\n'), isNot(contains(canary)));

        calls.clear();
        await manager.resumeSession(
          sessionId: 'after-snapshot',
          workspaceRoot: '/workspace',
        );
        expect(calls, <String>['throwing', 'last', 'added']);

        final streamed = <acp.AcpUpdate>[];
        snapshotSubscription = manager
            .sessionUpdates('after-snapshot')
            .listen(streamed.add);
        await pumpEventQueue();
        calls.clear();
        final owner = manager.beginPromptTurn('after-snapshot');
        peer.dispatchSessionUpdateForTesting(<String, dynamic>{
          'sessionId': 'after-snapshot',
          'update': <String, dynamic>{
            'sessionUpdate': 'current_mode_update',
            'currentModeId': 'listener-isolated',
          },
        });
        await pumpEventQueue();
        manager.endPromptTurn(owner);
        expect(calls, <String>['throwing', 'last', 'added']);
        expect(streamed, hasLength(1));

        await manager.dispose();
        calls.clear();
        peer.dispatchSessionUpdateForTesting(<String, dynamic>{
          'sessionId': 'after-snapshot',
          'update': <String, dynamic>{
            'sessionUpdate': 'current_mode_update',
            'currentModeId': canary,
          },
        });
        expect(calls, isEmpty);
      } finally {
        await snapshotSubscription?.cancel();
        await manager.dispose();
        await peer.close();
        await server.cancel();
        await channel.local.sink.close();
        await logSubscription.cancel();
      }
    },
  );

  test(
    'result listener disposal does not undo commit or the current snapshot',
    () async {
      final channel = StreamChannelController<String>();
      final peer = JsonRpcPeer(channel.foreign);
      final manager = SessionManager(config: acp.AcpConfig(), peer: peer);
      final delivered = <acp.AcpBoundedSessionResultObservation>[];
      Future<void>? disposing;

      void disposingListener(acp.AcpBoundedObservation observation) {
        if (observation is! acp.AcpBoundedSessionResultObservation) return;
        delivered.add(observation);
        disposing = manager.dispose();
      }

      void remainingListener(acp.AcpBoundedObservation observation) {
        if (observation is acp.AcpBoundedSessionResultObservation) {
          delivered.add(observation);
        }
      }

      manager.addBoundedObservationListener(disposingListener);
      manager.addBoundedObservationListener(remainingListener);
      final server = channel.local.stream.listen((line) {
        final request = jsonDecode(line) as Map<String, dynamic>;
        if (request['method'] != 'session/resume') return;
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': request['id'],
            'result': <String, dynamic>{'sessionId': 'dispose-observed'},
          }),
        );
      });

      try {
        final result = await manager.resumeSession(
          sessionId: 'dispose-observed',
          workspaceRoot: '/workspace',
        );

        expect(result.sessionId, 'dispose-observed');
        expect(delivered, hasLength(2));
        expect(identical(delivered.first, delivered.last), isTrue);
        expect(identical(delivered.first.result, result), isTrue);
        expect(disposing, isNotNull);
        await disposing;

        peer.dispatchSessionUpdateForTesting(<String, dynamic>{
          'sessionId': 'dispose-observed',
          'update': <String, dynamic>{
            'sessionUpdate': 'current_mode_update',
            'currentModeId': 'after-dispose',
          },
        });
        expect(delivered, hasLength(2));
      } finally {
        await disposing;
        await manager.dispose();
        await peer.close();
        await server.cancel();
        await channel.local.sink.close();
      }
    },
  );

  test('AcpClient proxies bounded observations and listener removal', () async {
    final transport = _TrackingAcpTransport();
    final client = await acp.AcpClient.start(
      config: acp.AcpConfig(),
      transport: transport,
    );
    final observations = <acp.AcpBoundedObservation>[];
    void listener(acp.AcpBoundedObservation observation) {
      observations.add(observation);
    }

    var newRequests = 0;
    final server = transport._controller.local.stream.listen((line) {
      final request = jsonDecode(line) as Map<String, dynamic>;
      if (request['method'] != 'session/new') return;
      newRequests += 1;
      transport._controller.local.sink.add(
        jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': request['id'],
          'result': <String, dynamic>{
            'sessionId': 'client-observed-$newRequests',
          },
        }),
      );
    });

    try {
      expect(client, isA<acp.AcpBoundedObservationSource>());
      client.addBoundedObservationListener(listener);
      final first = await client.newSession('/workspace/first');
      expect(first, 'client-observed-1');
      expect(observations, hasLength(1));
      expect(
        (observations.single as acp.AcpBoundedSessionResultObservation)
            .sessionId,
        first,
      );

      client.removeBoundedObservationListener(listener);
      final second = await client.newSession('/workspace/second');
      expect(second, 'client-observed-2');
      expect(observations, hasLength(1));
    } finally {
      await client.dispose();
      await server.cancel();
      await transport._controller.local.sink.close();
    }
  });

  test(
    'rejected unknown and unowned updates do not publish observations',
    () async {
      const canary = 'rejected-observation-canary';
      final logger = acp.AcpConfig().logger;
      final records = <String>[];
      final logSubscription = logger.onRecord.listen(
        (record) => records.add(record.message),
      );
      final channel = StreamChannelController<String>();
      final peer = JsonRpcPeer(channel.foreign);
      final manager = SessionManager(
        config: acp.AcpConfig(logger: logger),
        peer: peer,
      );
      final observations = <acp.AcpBoundedObservation>[];
      final streamErrors = <Object>[];
      void listener(acp.AcpBoundedObservation observation) {
        observations.add(observation);
      }

      final server = channel.local.stream.listen((line) {
        final request = jsonDecode(line) as Map<String, dynamic>;
        if (request['method'] != 'session/resume') return;
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': request['id'],
            'result': <String, dynamic>{},
          }),
        );
      });
      StreamSubscription<acp.AcpUpdate>? updateSubscription;

      try {
        await manager.resumeSession(
          sessionId: 'rejection-known',
          workspaceRoot: '/workspace',
        );
        manager.addBoundedObservationListener(listener);
        updateSubscription = manager
            .sessionUpdates('rejection-known')
            .listen((_) {}, onError: streamErrors.add);
        await pumpEventQueue();

        peer.dispatchSessionUpdateForTesting(<String, dynamic>{
          'sessionId': 'unknown-session',
          'update': <String, dynamic>{
            'sessionUpdate': 'current_mode_update',
            'currentModeId': canary,
          },
        });
        peer.dispatchSessionUpdateForTesting(<String, dynamic>{
          'sessionId': 'rejection-known',
          'update': <String, dynamic>{
            'sessionUpdate': 'current_mode_update',
            'currentModeId': canary,
          },
        });

        final owner = manager.beginPromptTurn('rejection-known');
        peer.dispatchSessionUpdateForTesting(<String, dynamic>{
          'sessionId': 'rejection-known',
          'update': _ThrowingGetterMap(
            <String, dynamic>{'sessionUpdate': 'current_mode_update'},
            throwKey: 'sessionUpdate',
            error: StateError(canary),
          ),
        });
        await pumpEventQueue();
        manager.endPromptTurn(owner);

        expect(observations, isEmpty);
        expect(streamErrors, hasLength(1));
        expect(streamErrors.join('\n'), isNot(contains(canary)));
        expect(records, contains('session update rejected'));
        expect(records.join('\n'), isNot(contains(canary)));
      } finally {
        manager.removeBoundedObservationListener(listener);
        await updateSubscription?.cancel();
        await manager.dispose();
        await peer.close();
        await server.cancel();
        await channel.local.sink.close();
        await logSubscription.cancel();
      }
    },
  );

  test(
    'rolled back and late session results do not publish observations',
    () async {
      const canary = 'failed-result-observation-canary';
      final channel = StreamChannelController<String>();
      final peer = JsonRpcPeer(channel.foreign);
      final manager = SessionManager(config: acp.AcpConfig(), peer: peer);
      final observations = <acp.AcpBoundedObservation>[];
      final lateNewId = Completer<Object?>();
      void listener(acp.AcpBoundedObservation observation) {
        observations.add(observation);
      }

      manager.addBoundedObservationListener(listener);
      final server = channel.local.stream.listen((line) {
        final request = jsonDecode(line) as Map<String, dynamic>;
        if (request['method'] == 'session/resume') {
          channel.local.sink.add(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': request['id'],
              'result': <String, dynamic>{'sessionId': canary},
            }),
          );
        } else if (request['method'] == 'session/new' &&
            !lateNewId.isCompleted) {
          lateNewId.complete(request['id']);
        }
      });

      try {
        Object? rollbackError;
        try {
          await manager.resumeSession(
            sessionId: 'rollback-observed',
            workspaceRoot: '/workspace',
          );
        } catch (error) {
          rollbackError = error;
        }
        expect(rollbackError, isA<FormatException>());
        expect(rollbackError.toString(), isNot(contains(canary)));
        expect(observations, isEmpty);
        expect(
          () => manager.getWorkspaceRoot('rollback-observed'),
          throwsStateError,
        );

        final pending = manager.newSession(workspaceRoot: '/workspace');
        final requestId = await lateNewId.future.timeout(
          const Duration(seconds: 5),
        );
        await manager.dispose();
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': requestId,
            'result': <String, dynamic>{'sessionId': canary},
          }),
        );
        await expectLater(pending, throwsStateError);
        expect(observations, isEmpty);
      } finally {
        await manager.dispose();
        await peer.close();
        await server.cancel();
        await channel.local.sink.close();
      }
    },
  );

  test('pins the default Codex ACP adapter version', () {
    final client = DartAcpAgentClient(agentCommand: 'unused');

    expect(client.agentArgs, ['@agentclientprotocol/codex-acp']);
  });

  test('rewrites legacy Codex ACP adapter arguments at runtime', () {
    final unversioned = DartAcpAgentClient(
      agentCommand: 'unused',
      agentArgs: const ['@zed-industries/codex-acp'],
    );
    final versioned = DartAcpAgentClient(
      agentCommand: 'unused',
      agentArgs: const ['@zed-industries/codex-acp@0.16.0'],
    );

    expect(unversioned.agentArgs, ['@agentclientprotocol/codex-acp']);
    expect(versioned.agentArgs, ['@agentclientprotocol/codex-acp']);
  });

  test('terminal handle limits validate and expose configured values', () {
    expect(
      () => DartAcpAgentClient(maxTerminalHandles: 0),
      throwsArgumentError,
    );
    expect(
      () => DartAcpAgentClient(
        maxTerminalHandles: 1,
        maxTerminalHandlesPerSession: 2,
      ),
      throwsArgumentError,
    );
    expect(
      () => DartAcpAgentClient(maxTerminalHandlesPerSession: 0),
      throwsArgumentError,
    );

    final client = DartAcpAgentClient(
      maxTerminalHandles: 4,
      maxTerminalHandlesPerSession: 2,
    );
    expect(client.maxTerminalHandles, 4);
    expect(client.maxTerminalHandlesPerSession, 2);
    final defaults = DartAcpAgentClient();
    expect(defaults.maxTerminalHandles, acp.defaultMaxTerminalHandles);
    expect(
      defaults.maxTerminalHandlesPerSession,
      acp.defaultMaxTerminalHandlesPerSession,
    );
  });

  test('rejects plaintext remote endpoints at the client boundary', () {
    expect(
      () => DartAcpAgentClient(
        agentWebSocketUrl: Uri.parse('ws://agent.example.com/acp'),
      ),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => DartAcpAgentClient(
        agentHttpUrl: Uri.parse('http://agent.example.com/acp'),
      ),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => DartAcpAgentClient(
        mcpServers: const <Map<String, dynamic>>[
          <String, dynamic>{
            'name': 'remote-tools',
            'type': 'http',
            'url': 'http://tools.example.com/mcp',
          },
        ],
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects endpoint credentials at the client boundary', () {
    expect(
      () => DartAcpAgentClient(
        agentHttpUrl: Uri.parse(
          'https://embedded:canary-secret@agent.example.com/acp',
        ),
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.toString(),
          'message',
          isNot(contains('canary-secret')),
        ),
      ),
    );
  });

  test('copies configured MCP servers for session setup', () {
    final mcpServer = <String, dynamic>{
      'name': 'filesystem',
      'type': ' STDIO ',
      'command': '/usr/local/bin/mcp-filesystem',
      'args': ['--mode', 'readonly'],
    };

    final client = DartAcpAgentClient(mcpServers: [mcpServer]);
    mcpServer['name'] = 'mutated';

    expect(client.mcpServers, hasLength(1));
    expect(client.mcpServers.single['name'], 'filesystem');
    expect(client.mcpServers.single['type'], 'stdio');
    expect(
      client.mcpServers.single['command'],
      '/usr/local/bin/mcp-filesystem',
    );
    expect(
      () => client.mcpServers.single['url'] = 'http://mutated.example.com/mcp',
      throwsUnsupportedError,
    );
  });

  test('dispose closes permission request stream', () async {
    final client = DartAcpAgentClient(agentCommand: 'unused');
    var streamClosed = false;
    final subscription = client.permissionRequests.listen(
      (_) {},
      onDone: () {
        streamClosed = true;
      },
    );

    await client.dispose();
    await pumpEventQueue();

    expect(streamClosed, isTrue);
    await subscription.cancel();
  });

  test('dispose stops an agent whose initialize request is pending', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final startedFile = File('${tempDir.path}/initialize_started');
    final pidFile = File('${tempDir.path}/agent_pid');
    final releaseFile = File('${tempDir.path}/release_initialize');
    final agentScript = File('${tempDir.path}/pending_initialize_agent.dart');
    final startedPath = jsonEncode(startedFile.path);
    final pidPath = jsonEncode(pidFile.path);
    final releasePath = jsonEncode(releaseFile.path);
    await agentScript.writeAsString('''
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await File($pidPath).writeAsString('\$pid');
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] != 'initialize') continue;
    await File($startedPath).writeAsString('started');
    while (!File($releasePath).existsSync()) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    stdout.writeln(jsonEncode(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': message['id'],
      'result': <String, dynamic>{
        'protocolVersion': 1,
        'agentCapabilities': <String, dynamic>{},
        'authMethods': <Map<String, dynamic>>[],
      },
    }));
  }
}

''');
    final client = DartAcpAgentClient(
      agentCommand: _dartExecutable(),
      agentArgs: [agentScript.path],
    );
    final connecting = client.connect();

    try {
      await _waitForFile(startedFile);
      final connectionFailure = expectLater(connecting, throwsA(anything));
      await client.dispose().timeout(const Duration(seconds: 2));

      await connectionFailure.timeout(const Duration(seconds: 2));
      final agentPid = int.parse(await pidFile.readAsString());
      expect(Process.killPid(agentPid, ProcessSignal.sigterm), isFalse);
    } finally {
      await releaseFile.writeAsString('release');
      try {
        await connecting.timeout(const Duration(seconds: 2));
      } on Object {
        // A disposed pending connection must settle with an error.
      }
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  test('starts stdio agent in configured working directory', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final launchDir = Directory('${tempDir.path}/launch-root');
    await launchDir.create();
    final cwdFile = File('${tempDir.path}/agent_cwd.txt');
    final cwdFilePath = jsonEncode(cwdFile.path);
    final agentScript = File('${tempDir.path}/fake_cwd_agent.dart');
    await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      await File($cwdFilePath).writeAsString(Directory.current.path);
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{},
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    }
  }
}
''');

    final client = DartAcpAgentClient(
      agentCommand: _dartExecutable(),
      agentArgs: [agentScript.path],
      agentCwd: launchDir.path,
    );

    try {
      await client.connect().timeout(const Duration(seconds: 5));
      await _waitForFile(cwdFile);

      expect(
        await Directory(await cwdFile.readAsString()).resolveSymbolicLinks(),
        await launchDir.resolveSymbolicLinks(),
      );
    } finally {
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  test('agent exit terminates an in-flight prompt', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final agentScript = File('${tempDir.path}/fake_crashing_agent.dart');
    await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{},
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/new') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'sessionId': 'session-crash'},
      }));
    } else if (message['method'] == 'session/prompt') {
      exit(7);
    }
  }
}
''');

    final client = DartAcpAgentClient(
      agentCommand: _dartExecutable(),
      agentArgs: [agentScript.path],
    );

    try {
      await client.connect().timeout(const Duration(seconds: 5));
      final session = await client.createSession(cwd: '/workspace');
      final events = await client
          .sendPrompt(sessionId: session.id, prompt: 'crash now')
          .toList()
          .timeout(const Duration(seconds: 2));

      expect(events.any((event) => event.type == AgentEventType.error), isTrue);
    } finally {
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  test('accepts legacy string message chunk content', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final agentScript = File('${tempDir.path}/fake_string_content_agent.dart');
    await agentScript.writeAsString('''
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{},
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/new') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'sessionId': 'session-legacy-content'},
      }));
    } else if (message['method'] == 'session/prompt') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'method': 'session/update',
        'params': <String, dynamic>{
          'sessionId': 'session-legacy-content',
          'update': <String, dynamic>{
            'sessionUpdate': 'agent_message_chunk',
            'content': 'hello legacy',
          },
        },
      }));
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'method': 'session/update',
        'params': <String, dynamic>{
          'sessionId': 'session-legacy-content',
          'update': <String, dynamic>{
            'sessionUpdate': 'agent_message_chunk',
            'content': <Object>[
              ' list text',
              <String, dynamic>{'text': ' and untyped text'},
            ],
          },
        },
      }));
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'method': 'session/update',
        'params': <String, dynamic>{
          'sessionId': 'session-legacy-content',
          'update': <String, dynamic>{
            'sessionUpdate': 'agent_message_chunk',
            'content': <String, dynamic>{
              'type': 'resource',
              'resource': <String, dynamic>{
                'url': 'file:///workspace/README.md',
                'name': 'README.md',
                'mime_type': 'text/markdown',
                'content': '# Project notes',
              },
            },
          },
        },
      }));
      await Future<void>.delayed(const Duration(milliseconds: 25));
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'stopReason': 'end_turn'},
      }));
    }
  }
}
''');

    final client = DartAcpAgentClient(
      agentCommand: _dartExecutable(),
      agentArgs: [agentScript.path],
    );

    try {
      await client.connect().timeout(const Duration(seconds: 5));
      final session = await client.createSession(cwd: '/workspace');
      final events = await client
          .sendPrompt(sessionId: session.id, prompt: 'say hi')
          .toList()
          .timeout(const Duration(seconds: 5));

      expect(
        events
            .where((event) => event.type == AgentEventType.agentTextDelta)
            .map((event) => event.text),
        [
          'hello legacy',
          ' list text and untyped text',
          'Received resource content.',
        ],
      );
      final resourceEvent = events.firstWhere(
        (event) => event.text == 'Received resource content.',
      );
      expect(resourceEvent.metadata['contentBlocks'], [
        {
          'type': 'resource',
          'resource': {
            'uri': 'file:///workspace/README.md',
            'mimeType': 'text/markdown',
            'text': '# Project notes',
          },
        },
      ]);
      expect(events.last.metadata['stopReason'], 'endTurn');
    } finally {
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  test('filters MCP server transports by agent capabilities', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final sessionParamsFile = File('${tempDir.path}/session_params.json');
    final agentScript = File('${tempDir.path}/fake_mcp_agent.dart');
    final sessionParamsPath = jsonEncode(sessionParamsFile.path);
    await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{
            'mcpCapabilities': <String, dynamic>{'sse': true, 'acp': true},
          },
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/new') {
      await File($sessionParamsPath).writeAsString(
        jsonEncode(message['params']),
      );
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'sessionId': 'session-1'},
      }));
    }
  }
}
''');

    final client = DartAcpAgentClient(
      agentCommand: _dartExecutable(),
      agentArgs: [agentScript.path],
      mcpServers: const [
        {
          'name': 'stdio-tools',
          'command': '/usr/local/bin/mcp-tools',
          'args': <String>[],
          'env': <Map<String, String>>[],
        },
        {
          'name': 'http-tools',
          'type': 'http',
          'url': 'https://api.example.com/mcp',
          'headers': <Map<String, String>>[],
        },
        {
          'name': 'sse-tools',
          'type': ' SSE ',
          'url': 'https://events.example.com/mcp',
          'headers': <Map<String, String>>[],
        },
        {'name': 'acp-tools', 'type': 'acp', 'serverId': 'nested-agent'},
        {
          'name': 'typo-tools',
          'type': 'htp',
          'url': 'https://typo.example.com/mcp',
          'headers': <Map<String, String>>[],
        },
      ],
      mcpConnectProvider: (params) async => {'connectionId': 'connection-1'},
      mcpMessageProvider: (params) async => const <String, dynamic>{},
      mcpDisconnectProvider: (params) async => const <String, dynamic>{},
    );

    try {
      await client.connect().timeout(const Duration(seconds: 5));
      await client.createSession(cwd: '/workspace');

      final sessionParams =
          jsonDecode(await sessionParamsFile.readAsString())
              as Map<String, dynamic>;
      final forwardedServers = sessionParams['mcpServers'] as List<dynamic>;

      expect(
        forwardedServers.cast<Map<String, dynamic>>().map(
          (server) => server['name'],
        ),
        ['stdio-tools', 'sse-tools', 'acp-tools'],
      );
      expect(forwardedServers.cast<Map<String, dynamic>>()[1]['type'], 'sse');
      expect(
        forwardedServers.cast<Map<String, dynamic>>().last['serverId'],
        'nested-agent',
      );
    } finally {
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'sends additional directories only when the agent advertises support',
    () async {
      final advertised = await _captureSessionSetupParams(
        advertiseAdditionalDirectories: true,
      );
      final unsupported = await _captureSessionSetupParams(
        advertiseAdditionalDirectories: false,
      );

      expect(advertised.calls.map((call) => call['method']), [
        'session/new',
        'session/resume',
        'session/fork',
      ]);
      for (final call in advertised.calls) {
        final params = call['params'] as Map<String, dynamic>;
        expect(params['additionalDirectories'], advertised.directories);
      }
      expect(advertised.listedAdditionalDirectories, advertised.directories);

      for (final call in unsupported.calls) {
        final params = call['params'] as Map<String, dynamic>;
        expect(params, isNot(contains('additionalDirectories')));
      }
      expect(unsupported.listedAdditionalDirectories, unsupported.directories);
    },
  );

  test('embeds text attachments when embedded context is advertised', () async {
    final promptParams = await _capturePromptParamsForAttachment(
      embeddedContext: true,
    );
    final prompt = promptParams['prompt'] as List<dynamic>;

    expect(prompt, hasLength(2));
    expect(prompt.first, {'type': 'text', 'text': 'Please inspect this.'});

    final resourceBlock = prompt.last as Map<String, dynamic>;
    expect(resourceBlock['type'], 'resource');
    expect(
      resourceBlock['resource'],
      containsPair('text', 'embedded attachment text'),
    );
    expect(resourceBlock['resource'], containsPair('mimeType', 'text/plain'));
  });

  test(
    'falls back to resource links without embedded context support',
    () async {
      final promptParams = await _capturePromptParamsForAttachment(
        embeddedContext: false,
      );
      final prompt = promptParams['prompt'] as List<dynamic>;

      expect(prompt, hasLength(2));
      final resourceLink = prompt.last as Map<String, dynamic>;
      expect(resourceLink['type'], 'resource_link');
      expect(resourceLink['name'], 'attachment.txt');
      expect(resourceLink['uri'], startsWith('file://'));
    },
  );

  test('embeds image attachments when image prompts are advertised', () async {
    final promptParams = await _capturePromptParamsForAttachment(
      image: true,
      attachmentName: 'pixel.png',
      attachmentBytes: _transparentPngBytes,
      mimeType: 'image/png',
    );
    final prompt = promptParams['prompt'] as List<dynamic>;

    expect(prompt, hasLength(2));
    final imageBlock = prompt.last as Map<String, dynamic>;
    expect(imageBlock['type'], 'image');
    expect(imageBlock['mimeType'], 'image/png');
    expect(imageBlock['data'], base64Encode(_transparentPngBytes));
    expect(imageBlock['uri'], startsWith('file://'));
  });

  test('falls back to resource links without image prompt support', () async {
    final promptParams = await _capturePromptParamsForAttachment(
      image: false,
      attachmentName: 'pixel.png',
      attachmentBytes: _transparentPngBytes,
      mimeType: 'image/png',
    );
    final prompt = promptParams['prompt'] as List<dynamic>;

    expect(prompt, hasLength(2));
    final resourceLink = prompt.last as Map<String, dynamic>;
    expect(resourceLink['type'], 'resource_link');
    expect(resourceLink['name'], 'pixel.png');
    expect(resourceLink['mimeType'], 'image/png');
  });

  test('embeds audio attachments when audio prompts are advertised', () async {
    final promptParams = await _capturePromptParamsForAttachment(
      audio: true,
      attachmentName: 'sample.wav',
      attachmentBytes: _tinyWavBytes,
      mimeType: 'audio/wav',
    );
    final prompt = promptParams['prompt'] as List<dynamic>;

    expect(prompt, hasLength(2));
    final audioBlock = prompt.last as Map<String, dynamic>;
    expect(audioBlock['type'], 'audio');
    expect(audioBlock['mimeType'], 'audio/wav');
    expect(audioBlock['data'], base64Encode(_tinyWavBytes));
    expect(audioBlock, isNot(contains('uri')));
  });

  test('falls back to resource links without audio prompt support', () async {
    final promptParams = await _capturePromptParamsForAttachment(
      audio: false,
      attachmentName: 'sample.wav',
      attachmentBytes: _tinyWavBytes,
      mimeType: 'audio/wav',
    );
    final prompt = promptParams['prompt'] as List<dynamic>;

    expect(prompt, hasLength(2));
    final resourceLink = prompt.last as Map<String, dynamic>;
    expect(resourceLink['type'], 'resource_link');
    expect(resourceLink['name'], 'sample.wav');
    expect(resourceLink['mimeType'], 'audio/wav');
  });

  test(
    'embeds binary attachments when embedded context is advertised',
    () async {
      final promptParams = await _capturePromptParamsForAttachment(
        embeddedContext: true,
        attachmentName: 'sample.bin',
        attachmentBytes: _binaryBytes,
        mimeType: 'application/octet-stream',
      );
      final prompt = promptParams['prompt'] as List<dynamic>;

      expect(prompt, hasLength(2));
      final resourceBlock = prompt.last as Map<String, dynamic>;
      expect(resourceBlock['type'], 'resource');
      final resource = resourceBlock['resource'] as Map<String, dynamic>;
      expect(resource['mimeType'], 'application/octet-stream');
      expect(resource['blob'], base64Encode(_binaryBytes));
      expect(resource['uri'], startsWith('file://'));
    },
  );

  test('attachment prompt budgets must be positive', () {
    for (final invalid in <DartAcpAgentClient Function()>[
      () => DartAcpAgentClient(maxPromptAttachmentCount: 0),
      () => DartAcpAgentClient(maxPromptAttachmentSourceBytes: 0),
      () => DartAcpAgentClient(maxPromptAttachmentEncodedBytes: 0),
      () => DartAcpAgentClient(maxPromptAttachmentEncodedBytes: 1),
    ]) {
      expect(invalid, throwsArgumentError);
    }

    final exactEmptyArray = DartAcpAgentClient(
      maxPromptAttachmentEncodedBytes: 2,
    );
    expect(exactEmptyArray.maxPromptAttachmentEncodedBytes, 2);
  });

  test(
    'attachment source budget accepts exact bytes and rejects plus one',
    () async {
      final exact = await _capturePromptParamsForAttachment(
        embeddedContext: true,
        attachmentName: 'exact.bin',
        attachmentBytes: const <int>[1, 2, 3],
        mimeType: 'application/octet-stream',
        maxPromptAttachmentSourceBytes: 3,
        maxPromptAttachmentEncodedBytes: 4096,
      );
      final plusOne = await _capturePromptParamsForAttachment(
        embeddedContext: true,
        attachmentName: 'plus-one.bin',
        attachmentBytes: const <int>[1, 2, 3, 4],
        mimeType: 'application/octet-stream',
        declaredAttachmentSize: 1,
        maxPromptAttachmentSourceBytes: 3,
        maxPromptAttachmentEncodedBytes: 4096,
      );

      expect(_attachmentBlock(exact)['type'], 'resource');
      expect(_attachmentBlock(plusOne)['type'], 'resource_link');
    },
  );

  test(
    'attachment encoded budget accounts for exact base64 expansion',
    () async {
      final exactEncodedBytes = utf8
          .encode(
            jsonEncode(<Map<String, dynamic>>[
              <String, dynamic>{
                'type': 'audio',
                'mimeType': 'audio/wav',
                'data': base64Encode(const <int>[1, 2, 3]),
              },
            ]),
          )
          .length;
      final exact = await _capturePromptParamsForAttachment(
        audio: true,
        attachmentName: 'exact.wav',
        attachmentBytes: const <int>[1, 2, 3],
        mimeType: 'audio/wav',
        maxPromptAttachmentSourceBytes: 64,
        maxPromptAttachmentEncodedBytes: exactEncodedBytes,
      );
      final tooSmall = await _capturePromptParamsForAttachment(
        audio: true,
        attachmentName: 'too-small.wav',
        attachmentBytes: const <int>[1, 2, 3],
        mimeType: 'audio/wav',
        maxPromptAttachmentSourceBytes: 64,
        maxPromptAttachmentEncodedBytes: exactEncodedBytes - 1,
      );

      expect(_attachmentBlock(exact)['type'], 'audio');
      expect(tooSmall['prompt'], hasLength(1));
    },
  );

  test(
    'attachment budget spans mixed content and bounds embedded count',
    () async {
      final sourceBounded = await _capturePromptParamsForAttachments(
        attachments: const <_TestPromptAttachment>[
          _TestPromptAttachment(
            name: 'first.txt',
            bytes: <int>[0x61, 0x62],
            mimeType: 'text/plain',
          ),
          _TestPromptAttachment(
            name: 'second.bin',
            bytes: <int>[1, 2, 3],
            mimeType: 'application/octet-stream',
          ),
        ],
        maxPromptAttachmentCount: 2,
        maxPromptAttachmentSourceBytes: 4,
        maxPromptAttachmentEncodedBytes: 4096,
      );
      final countBounded = await _capturePromptParamsForAttachments(
        attachments: const <_TestPromptAttachment>[
          _TestPromptAttachment(
            name: 'first.txt',
            bytes: <int>[0x61],
            mimeType: 'text/plain',
          ),
          _TestPromptAttachment(
            name: 'second.txt',
            bytes: <int>[0x62],
            mimeType: 'text/plain',
          ),
        ],
        maxPromptAttachmentCount: 1,
        maxPromptAttachmentSourceBytes: 64,
        maxPromptAttachmentEncodedBytes: 4096,
      );

      expect(_attachmentTypes(sourceBounded), <String>[
        'resource',
        'resource_link',
      ]);
      expect(_attachmentTypes(countBounded), <String>['resource']);
    },
  );

  test(
    'unsupported stale attachments still consume the prompt count',
    () async {
      final promptParams = await _capturePromptParamsForAttachments(
        attachments: const <_TestPromptAttachment>[
          _TestPromptAttachment(
            name: 'first.bin',
            bytes: <int>[1],
            mimeType: 'application/octet-stream',
            declaredSize: -100,
          ),
          _TestPromptAttachment(
            name: 'second.bin',
            bytes: <int>[2],
            mimeType: 'application/octet-stream',
            declaredSize: 0,
          ),
          _TestPromptAttachment(
            name: 'third.bin',
            bytes: <int>[3],
            mimeType: 'application/octet-stream',
            declaredSize: 1,
          ),
        ],
        embeddedContext: false,
        maxPromptAttachmentCount: 2,
        maxPromptAttachmentSourceBytes: 64,
        maxPromptAttachmentEncodedBytes: 4096,
      );

      expect(_attachmentTypes(promptParams), <String>[
        'resource_link',
        'resource_link',
      ]);
    },
  );

  test(
    'text attachment budget includes JSON control-character escaping',
    () async {
      final plain = await _capturePromptParamsForAttachment(
        embeddedContext: true,
        attachmentName: 'plain.txt',
        attachmentBytes: List<int>.filled(256, 0x61),
        mimeType: 'text/plain',
        maxPromptAttachmentSourceBytes: 512,
        maxPromptAttachmentEncodedBytes: 1000,
      );
      final escaped = await _capturePromptParamsForAttachment(
        embeddedContext: true,
        attachmentName: 'escaped.txt',
        attachmentBytes: List<int>.filled(256, 0),
        mimeType: 'text/plain',
        maxPromptAttachmentSourceBytes: 512,
        maxPromptAttachmentEncodedBytes: 1000,
      );

      expect(_attachmentBlock(plain)['type'], 'resource');
      expect(_attachmentBlock(escaped)['type'], 'resource_link');
    },
  );

  test(
    'attachment encoded budget measures mixed blocks at exact JSON bytes',
    () async {
      const attachments = <_TestPromptAttachment>[
        _TestPromptAttachment(
          name: 'notes.txt',
          bytes: <int>[0x61, 0x62],
          mimeType: 'text/plain',
        ),
        _TestPromptAttachment(
          name: 'sound.wav',
          bytes: <int>[1, 2, 3],
          mimeType: 'audio/wav',
        ),
      ];
      final measured = await _capturePromptParamsForAttachments(
        attachments: attachments,
        maxPromptAttachmentCount: 2,
        maxPromptAttachmentSourceBytes: 64,
        maxPromptAttachmentEncodedBytes: 4096,
      );
      final measuredBlocks = (measured['prompt'] as List<dynamic>)
          .skip(1)
          .toList();
      final exactBytes = utf8.encode(jsonEncode(measuredBlocks)).length;
      final exact = await _capturePromptParamsForAttachments(
        attachments: attachments,
        maxPromptAttachmentCount: 2,
        maxPromptAttachmentSourceBytes: 64,
        maxPromptAttachmentEncodedBytes: exactBytes,
      );
      final plusOne = await _capturePromptParamsForAttachments(
        attachments: attachments,
        maxPromptAttachmentCount: 2,
        maxPromptAttachmentSourceBytes: 64,
        maxPromptAttachmentEncodedBytes: exactBytes - 1,
      );

      expect(_attachmentTypes(exact), <String>['resource', 'audio']);
      expect(_attachmentTypes(plusOne), <String>['resource']);
    },
  );

  test('oversized programmatic attachment metadata is omitted', () async {
    final hugePath = '/${List<String>.filled(4096, 'x').join()}';
    final promptParams = await _capturePromptParamsForAttachment(
      embeddedContext: false,
      attachmentName: 'huge.bin',
      attachmentPathOverride: hugePath,
      declaredAttachmentSize: -1,
      mimeType: 'application/octet-stream',
      maxPromptAttachmentCount: 1,
      maxPromptAttachmentSourceBytes: 64,
      maxPromptAttachmentEncodedBytes: 256,
    );

    expect(promptParams['prompt'], hasLength(1));
  });

  test(
    'attachment size selected earlier cannot bypass the send-time budget',
    () async {
      final promptParams = await _capturePromptParamsForAttachment(
        embeddedContext: true,
        attachmentName: 'grown.txt',
        attachmentBytes: const <int>[0x61],
        attachmentBytesAfterSelection: utf8.encode(
          'content selected, then grown',
        ),
        mimeType: 'text/plain',
        maxPromptAttachmentSourceBytes: 4,
        maxPromptAttachmentEncodedBytes: 4096,
      );

      expect(_attachmentBlock(promptParams)['type'], 'resource_link');
    },
  );

  test(
    'oversized attachment falls back and the next prompt still embeds',
    () async {
      final prompts = await _captureTwoAttachmentPrompts(
        firstBytes: const <int>[1, 2, 3, 4],
        secondBytes: const <int>[1, 2, 3],
        maxPromptAttachmentSourceBytes: 3,
        maxPromptAttachmentEncodedBytes: 4096,
      );

      expect(_attachmentBlock(prompts.first)['type'], 'resource_link');
      expect(_attachmentBlock(prompts.last)['type'], 'resource');
    },
  );

  test(
    'non-regular attachment falls back without waiting for FIFO input',
    () async {
      if (Platform.isWindows) return;
      final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-fifo-');
      final fifo = File('${tempDir.path}/attachment.txt');
      final result = await Process.run('mkfifo', <String>[fifo.path]);
      expect(result.exitCode, 0);

      try {
        final promptParams = await _capturePromptParamsForAttachment(
          embeddedContext: true,
          attachmentName: 'attachment.txt',
          attachmentPathOverride: fifo.path,
          declaredAttachmentSize: 1,
          maxPromptAttachmentSourceBytes: 64,
          maxPromptAttachmentEncodedBytes: 4096,
        ).timeout(const Duration(seconds: 2));

        expect(_attachmentBlock(promptParams)['type'], 'resource_link');
      } finally {
        await tempDir.delete(recursive: true);
      }
    },
  );

  test('attachment final symlink safely embeds its canonical target', () async {
    if (!Platform.isMacOS && !Platform.isLinux) return;
    final tempDir = await Directory.systemTemp.createTemp(
      'ianvs-acp-attachment-link-',
    );
    final target = File('${tempDir.path}/target.txt');
    final link = Link('${tempDir.path}/selected.txt');
    await target.writeAsString('safe linked attachment', flush: true);
    await link.create(target.path);

    try {
      final promptParams = await _capturePromptParamsForAttachment(
        embeddedContext: true,
        attachmentName: 'selected.txt',
        attachmentPathOverride: link.path,
        declaredAttachmentSize: await target.length(),
        mimeType: 'text/plain',
      );

      expect(_attachmentBlock(promptParams), <String, dynamic>{
        'type': 'resource',
        'resource': <String, dynamic>{
          'uri': Uri.file(link.path).toString(),
          'mimeType': 'text/plain',
          'text': 'safe linked attachment',
        },
      });
    } finally {
      await tempDir.delete(recursive: true);
    }
  });

  test('dangling attachment final symlink falls back safely', () async {
    if (!Platform.isMacOS && !Platform.isLinux) return;
    final tempDir = await Directory.systemTemp.createTemp(
      'ianvs-acp-attachment-dangling-',
    );
    final link = Link('${tempDir.path}/selected.txt');
    await link.create('${tempDir.path}/missing.txt');

    try {
      final promptParams = await _capturePromptParamsForAttachment(
        embeddedContext: true,
        attachmentName: 'selected.txt',
        attachmentPathOverride: link.path,
        declaredAttachmentSize: 1,
        mimeType: 'text/plain',
      );

      expect(_attachmentBlock(promptParams)['type'], 'resource_link');
    } finally {
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'attachment replaced by FIFO before open falls back without blocking',
    () async {
      if (!Platform.isMacOS && !Platform.isLinux) return;
      var replacementCompleted = false;
      final promptParams = await _capturePromptParamsForAttachment(
        embeddedContext: true,
        attachmentName: 'swapped.txt',
        attachmentBytes: utf8.encode('original'),
        mimeType: 'text/plain',
        beforeAttachmentSecureOpen: (_, canonicalPath) async {
          final canonicalTarget = File(canonicalPath);
          await canonicalTarget.delete();
          final result = await Process.run('mkfifo', <String>[
            canonicalTarget.path,
          ]);
          expect(result.exitCode, 0, reason: result.stderr.toString());
          replacementCompleted = true;
        },
        maxPromptAttachmentSourceBytes: 64,
        maxPromptAttachmentEncodedBytes: 4096,
      ).timeout(const Duration(seconds: 2));

      expect(replacementCompleted, isTrue);
      expect(_attachmentBlock(promptParams)['type'], 'resource_link');
    },
  );

  test(
    'attachment replaced by external symlink before open never leaks target',
    () async {
      if (!Platform.isMacOS && !Platform.isLinux) return;
      File? canary;
      var replacementCompleted = false;
      try {
        const secret = 'external-canary-must-not-be-embedded';
        final promptParams = await _capturePromptParamsForAttachment(
          embeddedContext: true,
          attachmentName: 'swapped.txt',
          attachmentBytes: utf8.encode('original'),
          mimeType: 'text/plain',
          beforeAttachmentSecureOpen: (_, canonicalPath) async {
            final canonicalTarget = File(canonicalPath);
            canary = File('${canonicalTarget.parent.path}-outside.txt');
            await canary!.writeAsString(secret, flush: true);
            await canonicalTarget.delete();
            await Link(canonicalTarget.path).create(canary!.path);
            replacementCompleted = true;
          },
          maxPromptAttachmentSourceBytes: 64,
          maxPromptAttachmentEncodedBytes: 4096,
        );

        expect(replacementCompleted, isTrue);
        expect(_attachmentBlock(promptParams)['type'], 'resource_link');
        expect(jsonEncode(promptParams), isNot(contains(secret)));
      } finally {
        final outside = canary;
        if (outside != null && await outside.exists()) {
          await outside.delete();
        }
      }
    },
  );

  test(
    'falls back to resource links for binary attachments without embedded context',
    () async {
      final promptParams = await _capturePromptParamsForAttachment(
        embeddedContext: false,
        attachmentName: 'sample.bin',
        attachmentBytes: _binaryBytes,
        mimeType: 'application/octet-stream',
      );
      final prompt = promptParams['prompt'] as List<dynamic>;

      expect(prompt, hasLength(2));
      final resourceLink = prompt.last as Map<String, dynamic>;
      expect(resourceLink['type'], 'resource_link');
      expect(resourceLink['name'], 'sample.bin');
      expect(resourceLink['mimeType'], 'application/octet-stream');
    },
  );

  test('preserves prompt mentions when sending attachments', () async {
    final promptParams = await _capturePromptParamsForAttachment(
      prompt: 'Please inspect @notes.md with this.',
      attachmentName: 'attachment.bin',
      attachmentBytes: _binaryBytes,
      mimeType: 'application/octet-stream',
      extraFiles: const {'notes.md': '# Notes'},
    );
    final prompt = promptParams['prompt'] as List<dynamic>;

    expect(prompt, hasLength(3));
    expect(prompt.first, {
      'type': 'text',
      'text': 'Please inspect @notes.md with this.',
    });
    final mention = prompt[1] as Map<String, dynamic>;
    expect(mention['type'], 'resource_link');
    expect(mention['name'], 'notes.md');
    expect(mention['uri'], endsWith('/notes.md'));
    expect(mention['mimeType'], 'text/markdown');

    final attachment = prompt[2] as Map<String, dynamic>;
    expect(attachment['type'], 'resource_link');
    expect(attachment['name'], 'attachment.bin');
    expect(attachment['mimeType'], 'application/octet-stream');
  });

  test('preserves prompt mentions without selected attachments', () async {
    final promptParams = await _capturePromptParamsForAttachment(
      includeAttachment: false,
      prompt: 'Please inspect @notes.md.',
      extraFiles: const {'notes.md': '# Notes'},
    );
    final prompt = promptParams['prompt'] as List<dynamic>;

    expect(prompt, hasLength(2));
    expect(prompt.first, {'type': 'text', 'text': 'Please inspect @notes.md.'});
    final mention = prompt[1] as Map<String, dynamic>;
    expect(mention['type'], 'resource_link');
    expect(mention['name'], 'notes.md');
    expect(mention['uri'], endsWith('/notes.md'));
    expect(mention['mimeType'], 'text/markdown');
  });

  test('trims sentence punctuation from prompt mention links', () async {
    final promptParams = await _capturePromptParamsForAttachment(
      includeAttachment: false,
      prompt: 'Compare (@notes.md) with @https://example.com/readme.md.',
      extraFiles: const {'notes.md': '# Notes'},
    );
    final prompt = promptParams['prompt'] as List<dynamic>;

    expect(prompt, hasLength(3));
    expect(prompt.first, {
      'type': 'text',
      'text': 'Compare (@notes.md) with @https://example.com/readme.md.',
    });
    final fileMention = prompt[1] as Map<String, dynamic>;
    expect(fileMention['name'], 'notes.md');
    expect(fileMention['uri'], endsWith('/notes.md'));

    final urlMention = prompt[2] as Map<String, dynamic>;
    expect(urlMention['name'], 'readme.md');
    expect(urlMention['uri'], 'https://example.com/readme.md');
  });

  test('ignores inline email addresses and empty prompt mentions', () async {
    final promptParams = await _capturePromptParamsForAttachment(
      includeAttachment: false,
      prompt: 'Email dev@example.com, inspect @notes.md, ignore @.',
      extraFiles: const {'notes.md': '# Notes'},
    );
    final prompt = promptParams['prompt'] as List<dynamic>;

    expect(prompt, hasLength(2));
    expect(prompt.first, {
      'type': 'text',
      'text': 'Email dev@example.com, inspect @notes.md, ignore @.',
    });
    final mention = prompt[1] as Map<String, dynamic>;
    expect(mention['type'], 'resource_link');
    expect(mention['name'], 'notes.md');
    expect(mention['uri'], endsWith('/notes.md'));
  });

  test('sends clientInfo and preserves agentInfo during initialize', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final initializeParamsFile = File('${tempDir.path}/initialize_params.json');
    final agentScript = File('${tempDir.path}/fake_agent.dart');
    final initializeParamsPath = jsonEncode(initializeParamsFile.path);
    await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] != 'initialize') continue;
    await File($initializeParamsPath).writeAsString(
      jsonEncode(message['params']),
    );
    stdout.writeln(jsonEncode(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': message['id'],
      'result': <String, dynamic>{
        'protocolVersion': 1,
        'agentInfo': <String, dynamic>{
          'name': 'Test Agent',
          'version': '0.0.1',
        },
        'agentCapabilities': <String, dynamic>{
          'sessionCapabilities': <String, dynamic>{
            'list': <String, dynamic>{},
          },
        },
        'authMethods': <Map<String, dynamic>>[],
      },
    }));
  }
}
''');

    final client = DartAcpAgentClient(
      agentCommand: _dartExecutable(),
      agentArgs: [agentScript.path],
    );

    try {
      await client.connect().timeout(const Duration(seconds: 5));

      final capabilities = client.capabilities;
      expect(capabilities, isNotNull);
      expect(capabilities!.clientInfo['name'], 'ACP Client');
      expect(capabilities.clientInfo['version'], '1.0.0');
      expect(capabilities.agentInfo['name'], 'Test Agent');
      expect(capabilities.agentInfo['version'], '0.0.1');
      expect(capabilities.session.list, isTrue);

      final initializeParams =
          jsonDecode(await initializeParamsFile.readAsString())
              as Map<String, dynamic>;
      expect(
        initializeParams['clientInfo'],
        containsPair('name', 'ACP Client'),
      );
      expect(
        initializeParams['clientCapabilities'],
        containsPair('fs', containsPair('readTextFile', false)),
      );
      final clientCapabilities =
          initializeParams['clientCapabilities'] as Map<String, dynamic>;
      expect(
        clientCapabilities,
        containsPair(
          'session',
          containsPair('configOptions', containsPair('boolean', isA<Map>())),
        ),
      );
      expect(clientCapabilities, containsPair('plan', isA<Map>()));
    } finally {
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  test('raw stdio initialize enforces the effective depth boundary', () async {
    final atBoundary = await _runRawInitializeInput(
      agentCapabilities: <String, dynamic>{
        'nested': <String, dynamic>{'leaf': true},
      },
      inputBudget: const acp.AcpInputBudget(maxJsonDepth: 2),
    );
    expect(atBoundary.rawAgentCapabilities['nested'], isA<Map>());

    const secret = 'raw-depth-secret';
    await expectLater(
      _runRawInitializeInput(
        agentCapabilities: <String, dynamic>{
          'nested': <String, dynamic>{
            'tooDeep': <String, dynamic>{'value': secret},
          },
        },
        inputBudget: const acp.AcpInputBudget(maxJsonDepth: 2),
      ),
      throwsA(
        isA<acp.AcpInputLimitExceeded>()
            .having((error) => error.limit, 'limit', 2)
            .having((error) => error.observedAtLeast, 'observedAtLeast', 3)
            .having(
              (error) => error.toString(),
              'payload-free',
              isNot(contains(secret)),
            ),
      ),
    );
  });

  test('raw stdio initialize prechecks auth method count', () async {
    final atBoundary = await _runRawInitializeInput(
      authMethods: <Object?>[
        <String, dynamic>{'id': 'one'},
        <String, dynamic>{'id': 'two'},
      ],
      inputBudget: const acp.AcpInputBudget(maxAuthMethods: 2),
    );
    expect(atBoundary.authMethods, hasLength(2));

    await expectLater(
      _runRawInitializeInput(
        authMethods: <Object?>[
          <String, dynamic>{'id': 'one'},
          <String, dynamic>{'id': 'two'},
          <String, dynamic>{'id': 'raw-auth-secret'},
        ],
        inputBudget: const acp.AcpInputBudget(maxAuthMethods: 2),
      ),
      throwsA(
        isA<acp.AcpInputLimitExceeded>()
            .having((error) => error.limit, 'limit', 2)
            .having((error) => error.observedAtLeast, 'observedAtLeast', 3)
            .having(
              (error) => error.toString(),
              'payload-free',
              isNot(contains('raw-auth-secret')),
            ),
      ),
    );
  });

  test('raw stdio initialize rejects wrong auth method shapes', () async {
    const secret = 'raw-auth-shape-secret';
    for (final authMethods in <Object?>[
      secret,
      <Object?>[
        const <String, dynamic>{'id': 'valid'},
        secret,
      ],
    ]) {
      await expectLater(
        _runRawInitializeInput(
          authMethods: authMethods,
          inputBudget: const acp.AcpInputBudget(),
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.toString(),
            'payload-free',
            isNot(contains(secret)),
          ),
        ),
      );
    }
  });

  test('connects to websocket ACP agent servers', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final initializeParamsFile = File('${tempDir.path}/initialize_params.json');
    String? authorizationHeader;
    final serverSubscription = server.listen((request) async {
      authorizationHeader = request.headers.value(
        HttpHeaders.authorizationHeader,
      );
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen((data) async {
        final message = jsonDecode(data as String) as Map<String, dynamic>;
        final id = message['id'];
        final method = message['method'];
        if (method == 'initialize') {
          await initializeParamsFile.writeAsString(
            jsonEncode(message['params']),
          );
          socket.add(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': id,
              'result': <String, dynamic>{
                'protocolVersion': 1,
                'agentInfo': <String, dynamic>{'name': 'Remote Agent'},
                'agentCapabilities': <String, dynamic>{},
                'authMethods': <Map<String, dynamic>>[],
              },
            }),
          );
        } else if (method == 'session/new') {
          socket.add(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': id,
              'result': <String, dynamic>{'sessionId': 'ws-session'},
            }),
          );
        } else if (method == 'session/prompt') {
          socket.add(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'method': 'session/update',
              'params': <String, dynamic>{
                'sessionId': 'ws-session',
                'update': <String, dynamic>{
                  'sessionUpdate': 'agent_message_chunk',
                  'content': <String, dynamic>{
                    'type': 'text',
                    'text': 'hello websocket',
                  },
                },
              },
            }),
          );
          await Future<void>.delayed(const Duration(milliseconds: 25));
          socket.add(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': id,
              'result': <String, dynamic>{'stopReason': 'end_turn'},
            }),
          );
        }
      });
    });
    final client = DartAcpAgentClient(
      agentWebSocketUrl: Uri.parse('ws://127.0.0.1:${server.port}/acp'),
      agentHeaders: const {'Authorization': 'Bearer test-token'},
    );

    try {
      await client.connect().timeout(const Duration(seconds: 5));
      final session = await client.createSession(cwd: '/workspace');
      final events = await client
          .sendPrompt(sessionId: session.id, prompt: 'say hi')
          .toList()
          .timeout(const Duration(seconds: 5));

      expect(authorizationHeader, 'Bearer test-token');
      expect(client.capabilities?.agentInfo['name'], 'Remote Agent');
      expect(session.id, 'ws-session');
      expect(events.map((event) => event.text), contains('hello websocket'));
      expect(events.last.metadata['stopReason'], 'endTurn');
      final initializeParams =
          jsonDecode(await initializeParamsFile.readAsString())
              as Map<String, dynamic>;
      expect(
        initializeParams['clientInfo'],
        containsPair('name', 'ACP Client'),
      );
    } finally {
      await client.dispose();
      await serverSubscription.cancel();
      await server.close(force: true);
      await tempDir.delete(recursive: true);
    }
  });

  test('preserves snake case tool call ids in typed session updates', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final agentScript = File('${tempDir.path}/fake_snake_tool_agent.dart');
    await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

void send(Map<String, dynamic> message) {
  stdout.writeln(jsonEncode(message));
}

void sendSessionUpdate(Map<String, dynamic> update) {
  send(<String, dynamic>{
    'jsonrpc': '2.0',
    'method': 'session/update',
    'params': <String, dynamic>{
      'session_id': 'session-1',
      'update': update,
    },
  });
}

Future<void> main() async {
  var promptCount = 0;
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
        'result': <String, dynamic>{'sessionId': 'session-1'},
      });
    } else if (message['method'] == 'session/prompt') {
      promptCount += 1;
      if (promptCount == 2) {
        sendSessionUpdate(<String, dynamic>{
          'sessionUpdate': 'tool_call_update',
          'tool_call_id': 'call-a',
          'status': 'pending',
          'raw_output': 'new orphan update',
        });
        await Future<void>.delayed(const Duration(milliseconds: 25));
        send(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': message['id'],
          'result': <String, dynamic>{'stopReason': 'end_turn'},
        });
        continue;
      }
      sendSessionUpdate(<String, dynamic>{
        'sessionUpdate': 'tool_call',
        'tool_call_id': 'call-a',
        'title': 'Bash A',
        'status': 'pending',
        'content': 'running A',
        'locations': <Object>[
          '/workspace/a.dart',
          <String, dynamic>{'path': '/workspace/b.dart', 'line': 7},
        ],
      });
      sendSessionUpdate(<String, dynamic>{
        'sessionUpdate': 'tool_call',
        'tool_call_id': 'call-b',
        'title': 'Bash B',
        'status': 'pending',
      });
      sendSessionUpdate(<String, dynamic>{
        'sessionUpdate': 'tool_call_update',
        'tool_call_id': 'call-a',
        'status': 'completed',
        'raw_output': 'a done',
      });
      sendSessionUpdate(<String, dynamic>{
        'sessionUpdate': 'tool_call_update',
        'tool_call_id': 'call-b',
        'status': 'completed',
        'raw_output': 'b done',
      });
      await Future<void>.delayed(const Duration(milliseconds: 25));
      send(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'stopReason': 'end_turn'},
      });
    }
  }
}
''');

    final client = DartAcpAgentClient(
      agentCommand: _dartExecutable(),
      agentArgs: [agentScript.path],
    );

    try {
      await client.connect().timeout(const Duration(seconds: 5));
      final session = await client.createSession(cwd: '/workspace');
      final events = await client
          .sendPrompt(sessionId: session.id, prompt: 'run tools')
          .toList()
          .timeout(const Duration(seconds: 5));

      final toolEvents = events
          .where((event) => event.type == AgentEventType.toolCall)
          .toList();

      expect(toolEvents.map((event) => event.metadata['toolCallId']), [
        'call-a',
        'call-b',
        'call-a',
        'call-b',
      ]);
      expect(toolEvents.map((event) => event.metadata['status']), [
        'pending',
        'pending',
        'completed',
        'completed',
      ]);
      expect(toolEvents[2].text, 'Bash A');
      expect(toolEvents.first.metadata['content'], [
        {'type': 'text', 'text': 'running A'},
      ]);
      expect(toolEvents.first.metadata['locations'], [
        {'path': '/workspace/a.dart'},
        {'path': '/workspace/b.dart', 'line': 7},
      ]);
      expect(toolEvents[2].metadata['title'], 'Bash A');
      expect(toolEvents[2].metadata['status'], 'completed');
      expect(toolEvents[2].metadata['rawOutput'], 'a done');
      expect(toolEvents[3].text, 'Bash B');
      expect(toolEvents[3].metadata['title'], 'Bash B');
      expect(toolEvents[3].metadata['status'], 'completed');
      expect(toolEvents[3].metadata['rawOutput'], 'b done');

      final reusedEvents = await client
          .sendPrompt(sessionId: session.id, prompt: 'run orphan update')
          .toList()
          .timeout(const Duration(seconds: 5));
      final reusedToolEvents = reusedEvents
          .where((event) => event.type == AgentEventType.toolCall)
          .toList();

      expect(reusedToolEvents, hasLength(1));
      expect(reusedToolEvents.single.text, 'Bash A');
      expect(reusedToolEvents.single.metadata['toolCallId'], 'call-a');
      expect(reusedToolEvents.single.metadata['title'], 'Bash A');
      expect(reusedToolEvents.single.metadata['status'], 'pending');
      expect(
        reusedToolEvents.single.metadata['rawOutput'],
        'new orphan update',
      );
    } finally {
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  test('connects to streamable HTTP ACP agent servers', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final openResponses = <HttpResponse>[];
    final connectionStream = Completer<HttpResponse>();
    final sessionStream = Completer<HttpResponse>();
    String? authorizationHeader;
    String? connectionHeader;
    String? sessionHeader;
    String? cookieHeader;
    String? deleteConnectionHeader;
    String? deleteCookieHeader;
    String? connectionStreamProtocolHeader;
    String? sessionPostProtocolHeader;
    String? deleteProtocolHeader;
    var disposed = false;

    Future<void> sendSse(
      Completer<HttpResponse> stream,
      Map<String, dynamic> message,
    ) async {
      final response = await stream.future;
      response
        ..write('event: message\n')
        ..write('data: ${jsonEncode(message)}\n\n');
      await response.flush();
    }

    Future<void> openSse(HttpRequest request) async {
      final sessionId = request.headers.value('Acp-Session-Id');
      connectionStreamProtocolHeader ??= request.headers.value(
        'Acp-Protocol-Version',
      );
      request.response.bufferOutput = false;
      request.response.headers
        ..contentType = ContentType('text', 'event-stream', charset: 'utf-8')
        ..set(HttpHeaders.cacheControlHeader, 'no-cache');
      request.response.write(': connected\n\n');
      await request.response.flush();
      openResponses.add(request.response);
      if (sessionId == null) {
        if (!connectionStream.isCompleted) {
          connectionStream.complete(request.response);
        }
      } else if (!sessionStream.isCompleted) {
        sessionStream.complete(request.response);
      }
    }

    final serverSubscription = server.listen((request) async {
      authorizationHeader ??= request.headers.value(
        HttpHeaders.authorizationHeader,
      );
      if (request.method == 'DELETE') {
        deleteConnectionHeader = request.headers.value('Acp-Connection-Id');
        deleteCookieHeader = request.headers.value(HttpHeaders.cookieHeader);
        deleteProtocolHeader = request.headers.value('Acp-Protocol-Version');
        request.response.statusCode = HttpStatus.accepted;
        await request.response.close();
        return;
      }
      if (request.method == 'GET') {
        await openSse(request);
        return;
      }

      final body = await utf8.decoder.bind(request).join();
      final message = jsonDecode(body) as Map<String, dynamic>;
      final id = message['id'];
      final method = message['method'];
      if (method == 'initialize') {
        request.response
          ..headers.contentType = ContentType.json
          ..headers.set('Acp-Connection-Id', 'connection-1')
          ..cookies.add(Cookie('sticky', 'yes'))
          ..write(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': id,
              'result': <String, dynamic>{
                'connectionId': 'connection-1',
                'protocolVersion': 1,
                'agentInfo': <String, dynamic>{'name': 'HTTP Agent'},
                'agentCapabilities': <String, dynamic>{},
                'authMethods': <Map<String, dynamic>>[],
              },
            }),
          );
        await request.response.close();
      } else if (method == 'session/new') {
        connectionHeader = request.headers.value('Acp-Connection-Id');
        cookieHeader = request.headers.value(HttpHeaders.cookieHeader);
        request.response.statusCode = HttpStatus.accepted;
        await request.response.close();
        await sendSse(connectionStream, <String, dynamic>{
          'jsonrpc': '2.0',
          'id': id,
          'result': <String, dynamic>{'sessionId': 'http-session'},
        });
      } else if (method == 'session/prompt') {
        sessionHeader = request.headers.value('Acp-Session-Id');
        sessionPostProtocolHeader = request.headers.value(
          'Acp-Protocol-Version',
        );
        request.response.statusCode = HttpStatus.accepted;
        await request.response.close();
        await sendSse(sessionStream, <String, dynamic>{
          'jsonrpc': '2.0',
          'method': 'session/update',
          'params': <String, dynamic>{
            'sessionId': 'http-session',
            'update': <String, dynamic>{
              'sessionUpdate': 'agent_message_chunk',
              'content': <String, dynamic>{
                'type': 'text',
                'text': 'hello http',
              },
            },
          },
        });
        await Future<void>.delayed(const Duration(milliseconds: 25));
        await sendSse(sessionStream, <String, dynamic>{
          'jsonrpc': '2.0',
          'id': id,
          'result': <String, dynamic>{'stopReason': 'end_turn'},
        });
      }
    });

    final client = DartAcpAgentClient(
      agentHttpUrl: Uri.parse('http://127.0.0.1:${server.port}/acp'),
      agentHeaders: const {'Authorization': 'Bearer test-token'},
    );

    try {
      await client.connect().timeout(const Duration(seconds: 5));
      final session = await client.createSession(cwd: '/workspace');
      final events = await client
          .sendPrompt(sessionId: session.id, prompt: 'say hi')
          .toList()
          .timeout(const Duration(seconds: 5));

      expect(authorizationHeader, 'Bearer test-token');
      expect(connectionHeader, 'connection-1');
      expect(connectionStreamProtocolHeader, '1');
      expect(sessionHeader, 'http-session');
      expect(sessionPostProtocolHeader, '1');
      expect(cookieHeader, contains('sticky=yes'));
      expect(client.capabilities?.agentInfo['name'], 'HTTP Agent');
      expect(session.id, 'http-session');
      expect(events.map((event) => event.text), contains('hello http'));
      expect(events.last.metadata['stopReason'], 'endTurn');
      await client.dispose().timeout(const Duration(seconds: 5));
      disposed = true;
      expect(deleteConnectionHeader, 'connection-1');
      expect(deleteCookieHeader, contains('sticky=yes'));
      expect(deleteProtocolHeader, '1');
    } finally {
      if (!disposed) {
        await client.dispose();
      }
      for (final response in openResponses) {
        await response.close();
      }
      await serverSubscription.cancel();
      await server.close(force: true);
    }
  });

  test('opens streamable HTTP SSE stream for forked sessions', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final openResponses = <HttpResponse>[];
    final connectionStream = Completer<HttpResponse>();
    final originalSessionStream = Completer<HttpResponse>();
    final forkedSessionStream = Completer<HttpResponse>();
    String? forkPostSessionHeader;
    var disposed = false;

    Future<void> sendSse(
      Completer<HttpResponse> stream,
      Map<String, dynamic> message,
    ) async {
      final response = await stream.future;
      response
        ..write('event: message\n')
        ..write('data: ${jsonEncode(message)}\n\n');
      await response.flush();
    }

    Future<void> openSse(HttpRequest request) async {
      final sessionId = request.headers.value('Acp-Session-Id');
      request.response.bufferOutput = false;
      request.response.headers
        ..contentType = ContentType('text', 'event-stream', charset: 'utf-8')
        ..set(HttpHeaders.cacheControlHeader, 'no-cache');
      request.response.write(': connected\n\n');
      await request.response.flush();
      openResponses.add(request.response);
      if (sessionId == null) {
        if (!connectionStream.isCompleted) {
          connectionStream.complete(request.response);
        }
      } else if (sessionId == 'http-session') {
        if (!originalSessionStream.isCompleted) {
          originalSessionStream.complete(request.response);
        }
      } else if (sessionId == 'http-fork') {
        if (!forkedSessionStream.isCompleted) {
          forkedSessionStream.complete(request.response);
        }
      }
    }

    final serverSubscription = server.listen((request) async {
      if (request.method == 'DELETE') {
        request.response.statusCode = HttpStatus.accepted;
        await request.response.close();
        return;
      }
      if (request.method == 'GET') {
        await openSse(request);
        return;
      }

      final body = await utf8.decoder.bind(request).join();
      final message = jsonDecode(body) as Map<String, dynamic>;
      final id = message['id'];
      final method = message['method'];
      if (method == 'initialize') {
        request.response
          ..headers.contentType = ContentType.json
          ..headers.set('Acp-Connection-Id', 'connection-1')
          ..write(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': id,
              'result': <String, dynamic>{
                'connectionId': 'connection-1',
                'protocolVersion': 1,
                'agentCapabilities': <String, dynamic>{
                  'sessionCapabilities': <String, dynamic>{
                    'fork': <String, dynamic>{},
                  },
                },
                'authMethods': <Map<String, dynamic>>[],
              },
            }),
          );
        await request.response.close();
      } else if (method == 'session/new') {
        request.response.statusCode = HttpStatus.accepted;
        await request.response.close();
        await sendSse(connectionStream, <String, dynamic>{
          'jsonrpc': '2.0',
          'id': id,
          'result': <String, dynamic>{'sessionId': 'http-session'},
        });
      } else if (method == 'session/fork') {
        forkPostSessionHeader = request.headers.value('Acp-Session-Id');
        request.response.statusCode = HttpStatus.accepted;
        await request.response.close();
        await sendSse(originalSessionStream, <String, dynamic>{
          'jsonrpc': '2.0',
          'id': id,
          'result': <String, dynamic>{'sessionId': 'http-fork'},
        });
      }
    });

    final client = DartAcpAgentClient(
      agentHttpUrl: Uri.parse('http://127.0.0.1:${server.port}/acp'),
    );

    try {
      await client.connect().timeout(const Duration(seconds: 5));
      final session = await client.createSession(cwd: '/workspace');
      final forked = await client
          .forkSession(sessionId: session.id, cwd: '/workspace')
          .timeout(const Duration(seconds: 5));

      await forkedSessionStream.future.timeout(const Duration(seconds: 5));

      expect(session.id, 'http-session');
      expect(forked.id, 'http-fork');
      expect(forkPostSessionHeader, 'http-session');
      await client.dispose().timeout(const Duration(seconds: 5));
      disposed = true;
    } finally {
      if (!disposed) {
        await client.dispose();
      }
      for (final response in openResponses) {
        await response.close();
      }
      await serverSubscription.cancel();
      await server.close(force: true);
    }
  });

  test('sends custom extension JSON-RPC requests', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final extensionParamsFile = File('${tempDir.path}/extension_params.json');
    final agentScript = File('${tempDir.path}/fake_extension_agent.dart');
    final extensionParamsPath = jsonEncode(extensionParamsFile.path);
    await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{
            '_meta': <String, dynamic>{
              'example.dev': <String, dynamic>{'ping': true},
            },
          },
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == '_example.dev/ping') {
      await File($extensionParamsPath).writeAsString(
        jsonEncode(message['params']),
      );
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'pong': true},
      }));
    }
  }
}
''');

    final client = DartAcpAgentClient(
      agentCommand: _dartExecutable(),
      agentArgs: [agentScript.path],
    );

    try {
      await client.connect().timeout(const Duration(seconds: 5));

      expect(client.capabilities?.extensionMeta['example.dev'], isNotNull);
      final result = await client
          .sendExtensionRequest(
            method: '_example.dev/ping',
            params: const {'message': 'hello'},
          )
          .timeout(const Duration(seconds: 5));

      expect(result, containsPair('pong', true));
      final extensionParams =
          jsonDecode(await extensionParamsFile.readAsString())
              as Map<String, dynamic>;
      expect(extensionParams, {'message': 'hello'});
    } finally {
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  test('advertises configured filesystem provider capabilities', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final initializeParamsFile = File('${tempDir.path}/initialize_params.json');
    final agentScript = File('${tempDir.path}/fake_fs_caps_agent.dart');
    final initializeParamsPath = jsonEncode(initializeParamsFile.path);
    await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      await File($initializeParamsPath).writeAsString(
        jsonEncode(message['params']),
      );
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{},
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    }
  }
}
''');

    final client = DartAcpAgentClient(
      agentCommand: _dartExecutable(),
      agentArgs: [agentScript.path],
      enableFilesystemReadTextFile: true,
      enableFilesystemWriteTextFile: true,
      allowFilesystemReadOutsideWorkspace: true,
    );

    try {
      await client.connect().timeout(const Duration(seconds: 5));

      final capabilities = client.capabilities;
      expect(capabilities?.client.fsReadTextFile, isTrue);
      expect(capabilities?.client.fsWriteTextFile, isTrue);
      expect(capabilities?.client.hasFsProvider, isTrue);
      expect(capabilities?.client.allowReadOutsideWorkspace, isTrue);

      final initializeParams =
          jsonDecode(await initializeParamsFile.readAsString())
              as Map<String, dynamic>;
      expect(
        initializeParams['clientCapabilities'],
        containsPair('fs', containsPair('readTextFile', true)),
      );
      expect(
        initializeParams['clientCapabilities'],
        containsPair('fs', containsPair('writeTextFile', true)),
      );
    } finally {
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  test('advertises configured terminal provider capabilities', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final initializeParamsFile = File('${tempDir.path}/initialize_params.json');
    final agentScript = File('${tempDir.path}/fake_terminal_caps_agent.dart');
    final initializeParamsPath = jsonEncode(initializeParamsFile.path);
    await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      await File($initializeParamsPath).writeAsString(
        jsonEncode(message['params']),
      );
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{},
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    }
  }
}
''');

    final client = DartAcpAgentClient(
      agentCommand: _dartExecutable(),
      agentArgs: [agentScript.path],
      enableTerminalProvider: true,
    );

    try {
      await client.connect().timeout(const Duration(seconds: 5));

      final capabilities = client.capabilities;
      expect(capabilities?.client.terminal, isTrue);
      expect(capabilities?.client.hasTerminalProvider, isTrue);

      final initializeParams =
          jsonDecode(await initializeParamsFile.readAsString())
              as Map<String, dynamic>;
      expect(
        initializeParams['clientCapabilities'],
        containsPair('terminal', true),
      );
    } finally {
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  test('serves filesystem read requests after permission approval', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final workspace = Directory('${tempDir.path}/workspace');
    await workspace.create();
    await File('${workspace.path}/fixture.txt').writeAsString('hello fs');
    final fsResponseFile = File('${tempDir.path}/fs_response.json');
    final agentScript = File('${tempDir.path}/fake_fs_read_agent.dart');
    final fsResponsePath = jsonEncode(fsResponseFile.path);
    await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{},
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/new') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'sessionId': 'session-fs'},
      }));
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': 'fs-read-1',
        'method': 'fs/read_text_file',
        'params': <String, dynamic>{
          'sessionId': 'session-fs',
          'path': 'fixture.txt',
        },
      }));
    } else if (message['id'] == 'fs-read-1') {
      await File($fsResponsePath).writeAsString(jsonEncode(message));
    }
  }
}
''');

    late final DartAcpAgentClient client;
    client = DartAcpAgentClient(
      agentCommand: _dartExecutable(),
      agentArgs: [agentScript.path],
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

    try {
      await client.connect().timeout(const Duration(seconds: 5));
      final session = await client.createSession(cwd: workspace.path);
      await _waitForFile(fsResponseFile);

      expect(session.id, 'session-fs');
      final fsResponse =
          jsonDecode(await fsResponseFile.readAsString())
              as Map<String, dynamic>;
      expect(fsResponse['id'], 'fs-read-1');
      expect(fsResponse['result'], containsPair('content', 'hello fs'));
    } finally {
      await subscription.cancel();
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  test('rejects filesystem read requests without a session id', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final workspace = Directory('${tempDir.path}/workspace');
    await workspace.create();
    await File('${workspace.path}/fixture.txt').writeAsString('private data');
    final fsResponseFile = File('${tempDir.path}/fs_response.json');
    final agentScript = File('${tempDir.path}/fake_fs_missing_session.dart');
    final fsResponsePath = jsonEncode(fsResponseFile.path);
    await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{},
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/new') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'sessionId': 'session-fs'},
      }));
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': 'fs-read-missing-session',
        'method': 'fs/read_text_file',
        'params': <String, dynamic>{'path': 'fixture.txt'},
      }));
    } else if (message['id'] == 'fs-read-missing-session') {
      await File($fsResponsePath).writeAsString(jsonEncode(message));
    }
  }
}
''');

    final client = DartAcpAgentClient(
      agentCommand: _dartExecutable(),
      agentArgs: [agentScript.path],
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

    try {
      await client.connect().timeout(const Duration(seconds: 5));
      await client.createSession(cwd: workspace.path);
      await _waitForFile(fsResponseFile);

      final response =
          jsonDecode(await fsResponseFile.readAsString())
              as Map<String, dynamic>;
      expect(response['id'], 'fs-read-missing-session');
      expect(response, contains('error'));
      expect(response, isNot(contains('result')));
    } finally {
      await subscription.cancel();
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  for (final scenario in const [
    (
      name: 'filesystem read with unknown session',
      method: 'fs/read_text_file',
      sessionId: 'unknown-session',
    ),
    (
      name: 'filesystem write without session',
      method: 'fs/write_text_file',
      sessionId: null,
    ),
    (
      name: 'filesystem write with unknown session',
      method: 'fs/write_text_file',
      sessionId: 'unknown-session',
    ),
    (
      name: 'permission without session',
      method: 'session/request_permission',
      sessionId: null,
    ),
    (
      name: 'permission with unknown session',
      method: 'session/request_permission',
      sessionId: 'unknown-session',
    ),
  ]) {
    test('rejects ${scenario.name}', () async {
      final result = await _runInvalidSessionRequest(
        method: scenario.method,
        sessionId: scenario.sessionId,
      );

      expect(result.response, contains('error'));
      expect(result.response, isNot(contains('result')));
      expect(result.permissionRequestCount, 0);
      expect(result.writeTargetExists, isFalse);
    });
  }

  test(
    'rejects reusing a session id with a different workspace root',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
      final agentScript = File('${tempDir.path}/fake_reused_session_id.dart');
      await agentScript.writeAsString(r'''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{
            'sessionCapabilities': <String, dynamic>{
              'additionalDirectories': true,
            },
          },
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/new') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'sessionId': 'reused-session'},
      }));
    }
  }
}
''');

      final client = DartAcpAgentClient(
        agentCommand: _dartExecutable(),
        agentArgs: [agentScript.path],
      );

      try {
        await client.connect().timeout(const Duration(seconds: 5));
        await client.createSession(
          cwd: '/workspace/first',
          additionalDirectories: const ['/workspace/a', '/workspace/b'],
        );

        await expectLater(
          client.createSession(
            cwd: '/workspace/first',
            additionalDirectories: const ['/workspace/b', '/workspace/a'],
          ),
          throwsA(isA<StateError>()),
        );

        await expectLater(
          client.createSession(
            cwd: '/workspace/first',
            additionalDirectories: const ['/workspace/a', '/workspace/c'],
          ),
          throwsA(isA<StateError>()),
        );

        await expectLater(
          client.createSession(cwd: '/workspace/second'),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('already registered'),
            ),
          ),
        );
      } finally {
        await client.dispose();
        await tempDir.delete(recursive: true);
      }
    },
  );

  test(
    'failed resume rolls back only newly registered session state',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
      final agentScript = File(
        '${tempDir.path}/fake_resume_rollback_agent.dart',
      );
      await agentScript.writeAsString(r'''
import 'dart:convert';
import 'dart:io';

void send(Map<String, dynamic> message) => stdout.writeln(jsonEncode(message));

Future<void> main() async {
  var resumeCount = 0;
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
          'agentCapabilities': <String, dynamic>{
            'sessionCapabilities': <String, dynamic>{'resume': true},
          },
          'authMethods': <Map<String, dynamic>>[],
        },
      });
    } else if (message['method'] == 'session/resume') {
      resumeCount += 1;
      if (resumeCount == 1 || resumeCount == 3) {
        if (resumeCount == 1) {
          send(<String, dynamic>{
            'jsonrpc': '2.0',
            'method': 'session/update',
            'params': <String, dynamic>{
              'sessionId': 'session-rollback',
              'update': <String, dynamic>{
                'sessionUpdate': 'current_mode_update',
                'currentModeId': 'stale-mode',
              },
            },
          });
        }
        send(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': message['id'],
          'error': <String, dynamic>{
            'code': -32000,
            'message': 'resume failed',
          },
        });
      } else {
        send(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': message['id'],
          'result': <String, dynamic>{},
        });
      }
    } else if (message['method'] == 'session/prompt') {
      send(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'stopReason': 'end_turn'},
      });
    }
  }
}
''');

      final client = await acp.AcpClient.start(
        config: acp.AcpConfig(
          agentCommand: _dartExecutable(),
          agentArgs: [agentScript.path],
        ),
      );
      var sessionUpdatesDone = false;
      final sessionUpdates = client
          .sessionUpdates('session-rollback')
          .listen((_) {}, onDone: () => sessionUpdatesDone = true);

      try {
        await client.initialize().timeout(const Duration(seconds: 5));
        await pumpEventQueue();

        await expectLater(
          client.resumeSession(
            sessionId: 'session-rollback',
            workspaceRoot: '/workspace/wrong',
          ),
          throwsA(anything),
        );
        await pumpEventQueue();
        expect(sessionUpdatesDone, isFalse);
        expect(client.sessionModes('session-rollback'), isNull);
        expect(
          () => client.prompt(
            sessionId: 'session-rollback',
            content: 'must be invalid',
          ),
          throwsA(isA<StateError>()),
        );

        await client.resumeSession(
          sessionId: 'session-rollback',
          workspaceRoot: '/workspace/correct',
        );
        await expectLater(
          client.resumeSession(
            sessionId: 'session-rollback',
            workspaceRoot: '/workspace/correct',
          ),
          throwsA(anything),
        );

        await client
            .prompt(sessionId: 'session-rollback', content: 'still valid')
            .drain<void>()
            .timeout(const Duration(seconds: 5));
      } finally {
        await sessionUpdates.cancel();
        await client.dispose();
        await tempDir.delete(recursive: true);
      }
    },
  );

  for (final operation in const <String>['new', 'fork']) {
    test(
      '$operation registration waits for a failed resume rollback',
      () => _expectGeneratedSessionRegistrationAfterFailedResume(operation),
    );
  }

  test('failed retry preserves updates owned by an existing session', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final agentScript = File(
      '${tempDir.path}/fake_existing_session_retry_agent.dart',
    );
    await agentScript.writeAsString(r'''
import 'dart:convert';
import 'dart:io';

void send(Map<String, dynamic> message) => stdout.writeln(jsonEncode(message));

Future<void> main() async {
  var resumeCount = 0;
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
          'agentCapabilities': <String, dynamic>{
            'sessionCapabilities': <String, dynamic>{'resume': true},
          },
          'authMethods': <Map<String, dynamic>>[],
        },
      });
    } else if (message['method'] == 'session/resume') {
      resumeCount += 1;
      if (resumeCount == 1) {
        send(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': message['id'],
          'result': <String, dynamic>{},
        });
      } else {
        send(<String, dynamic>{
          'jsonrpc': '2.0',
          'method': 'session/update',
          'params': <String, dynamic>{
            'sessionId': 'existing-session',
            'update': <String, dynamic>{
              'sessionUpdate': 'current_mode_update',
              'currentModeId': 'retry-mode',
            },
          },
        });
        send(<String, dynamic>{
          'jsonrpc': '2.0',
          'method': 'session/update',
          'params': <String, dynamic>{
            'sessionId': 'existing-session',
            'update': <String, dynamic>{
              'sessionUpdate': 'tool_call',
              'toolCallId': 'retry-call',
              'status': 'in_progress',
              'title': 'Preserved tool',
              'kind': 'execute',
            },
          },
        });
        send(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': message['id'],
          'error': <String, dynamic>{
            'code': -32000,
            'message': 'retry failed',
          },
        });
      }
    } else if (message['method'] == 'session/prompt') {
      send(<String, dynamic>{
        'jsonrpc': '2.0',
        'method': 'session/update',
        'params': <String, dynamic>{
          'sessionId': 'existing-session',
          'update': <String, dynamic>{
            'sessionUpdate': 'tool_call_update',
            'toolCallId': 'retry-call',
            'status': 'completed',
            'rawOutput': 'done',
          },
        },
      });
      send(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'stopReason': 'end_turn'},
      });
    }
  }
}
''');

    final client = await acp.AcpClient.start(
      config: acp.AcpConfig(
        agentCommand: _dartExecutable(),
        agentArgs: [agentScript.path],
      ),
    );

    try {
      await client.initialize().timeout(const Duration(seconds: 5));
      await client.resumeSession(
        sessionId: 'existing-session',
        workspaceRoot: '/workspace/existing',
      );

      await expectLater(
        client.resumeSession(
          sessionId: 'existing-session',
          workspaceRoot: '/workspace/existing',
        ),
        throwsA(anything),
      );
      await pumpEventQueue();

      expect(
        client.sessionModes('existing-session')?.currentModeId,
        'retry-mode',
      );
      final replay = await client
          .sessionUpdates('existing-session')
          .take(2)
          .toList()
          .timeout(const Duration(seconds: 5));
      expect(replay.whereType<acp.ModeUpdate>(), hasLength(1));
      expect(
        replay.whereType<acp.ToolCallUpdate>().single.toolCall.title,
        'Preserved tool',
      );

      final promptToolUpdate = await client
          .prompt(sessionId: 'existing-session', content: 'finish tool')
          .where((update) => update is acp.ToolCallUpdate)
          .cast<acp.ToolCallUpdate>()
          .single
          .timeout(const Duration(seconds: 5));
      expect(promptToolUpdate.toolCall.title, 'Preserved tool');
      expect(promptToolUpdate.toolCall.rawOutput, 'done');
    } finally {
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  test('session manager prompt requires a workspace binding', () async {
    final channel = StreamChannelController<String>();
    final peer = JsonRpcPeer(channel.foreign);
    final manager = SessionManager(config: acp.AcpConfig(), peer: peer);
    final updates = manager.sessionUpdates('unbound-session').listen((_) {});

    try {
      await pumpEventQueue();

      expect(
        () => manager.prompt(
          sessionId: 'unbound-session',
          content: const <Map<String, dynamic>>[],
        ),
        throwsA(isA<StateError>()),
      );
    } finally {
      await updates.cancel();
      await manager.dispose();
      await peer.close();
      await channel.local.sink.close();
    }
  });

  test(
    'invalid input budgets fail before client or manager side effects',
    () async {
      const invalidBudget = acp.AcpInputBudget(maxJsonDepth: 0);
      final channel = StreamChannelController<String>();
      final peer = JsonRpcPeer(channel.foreign);

      expect(
        () => SessionManager(
          config: acp.AcpConfig(),
          peer: peer,
          inputBudget: invalidBudget,
        ),
        throwsArgumentError,
      );
      expect(peer.onReadTextFile, isNull);
      expect(peer.onWriteTextFile, isNull);
      expect(peer.onRequestPermission, isNull);
      expect(peer.onTerminalCreate, isNull);

      final transport = _TrackingAcpTransport();
      await expectLater(
        acp.AcpClient.start(
          config: acp.AcpConfig(),
          transport: transport,
          inputBudget: invalidBudget,
        ),
        throwsArgumentError,
      );
      expect(transport.startCount, 0);

      expect(
        () => DartAcpAgentClient(
          agentHttpUrl: Uri.parse('http://agent.example.com/acp'),
          inputBudget: invalidBudget,
        ),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.toString(),
            'message',
            contains('maxJsonDepth'),
          ),
        ),
      );

      await peer.close();
      await channel.local.sink.close();
    },
  );

  test('phase owners reject overlap and stale end or cancel', () async {
    final channel = StreamChannelController<String>();
    final peer = JsonRpcPeer(channel.foreign);
    final manager = SessionManager(config: acp.AcpConfig(), peer: peer);
    var cancelRequests = 0;
    final server = channel.local.stream.listen((line) {
      final request = jsonDecode(line) as Map<String, dynamic>;
      if (request['method'] == 'session/resume') {
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': request['id'],
            'result': <String, dynamic>{},
          }),
        );
      } else if (request['method'] == 'session/cancel') {
        cancelRequests += 1;
      }
    });

    try {
      await manager.resumeSession(
        sessionId: 'owner-session',
        workspaceRoot: '/workspace/owner',
      );
      await manager.resumeSession(
        sessionId: 'parallel-session',
        workspaceRoot: '/workspace/parallel',
      );
      final first = manager.beginPromptTurn('owner-session');
      expect(first.sessionId, 'owner-session');
      expect(first.generation, greaterThan(0));
      expect(() => manager.beginPromptTurn('owner-session'), throwsStateError);

      manager.endPromptTurn(first);
      final second = manager.beginPromptTurn('owner-session');
      expect(second.generation, greaterThan(first.generation));

      manager.endPromptTurn(first);
      expect(
        () => manager.beginPromptTurn('owner-session'),
        throwsStateError,
        reason: 'a stale owner must not clear the newer phase',
      );
      await expectLater(manager.cancelPromptTurn(first), throwsStateError);
      await pumpEventQueue();
      expect(cancelRequests, 0, reason: 'stale cancel must not reach the peer');

      final parallel = manager.beginPromptTurn('parallel-session');
      manager.endPromptTurn(parallel);
      manager.endPromptTurn(second);
    } finally {
      await manager.dispose();
      await peer.close();
      await server.cancel();
      await channel.local.sink.close();
    }
  });

  test(
    'cancel, close, and dispose invalidate only their exact owners',
    () async {
      final channel = StreamChannelController<String>();
      final peer = JsonRpcPeer(channel.foreign);
      final manager = SessionManager(config: acp.AcpConfig(), peer: peer);
      final requestIds = <String, List<Object?>>{};
      final server = channel.local.stream.listen((line) {
        final request = jsonDecode(line) as Map<String, dynamic>;
        final method = request['method'] as String?;
        if (method == null) return;
        requestIds.putIfAbsent(method, () => <Object?>[]).add(request['id']);
        if (method == 'session/resume' ||
            method == 'session/cancel' ||
            method == 'session/close') {
          channel.local.sink.add(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': request['id'],
              'result': <String, dynamic>{},
            }),
          );
        }
      });

      try {
        for (final sessionId in <String>[
          'cancel-session',
          'close-session',
          'unaffected-session',
          'dispose-session',
        ]) {
          await manager.resumeSession(
            sessionId: sessionId,
            workspaceRoot: '/workspace/$sessionId',
          );
        }
        final cancelled = manager.beginPromptTurn('cancel-session');
        await manager.cancelPromptTurn(cancelled);
        final replacement = manager.beginPromptTurn('cancel-session');
        await expectLater(
          manager.cancelPromptTurn(cancelled),
          throwsStateError,
        );
        expect(requestIds['session/cancel'], hasLength(1));

        final closed = manager.beginPromptTurn('close-session');
        final unaffected = manager.beginPromptTurn('unaffected-session');
        await manager.closeSession(sessionId: 'close-session');
        expect(
          () => manager.beginPromptTurn('unaffected-session'),
          throwsStateError,
        );
        await manager.resumeSession(
          sessionId: 'close-session',
          workspaceRoot: '/workspace/close-session',
        );
        final afterClose = manager.beginPromptTurn('close-session');
        manager.endPromptTurn(closed);
        expect(
          () => manager.beginPromptTurn('close-session'),
          throwsStateError,
          reason: 'late close callbacks must not clear a new generation',
        );

        manager.endPromptTurn(replacement);
        manager.endPromptTurn(unaffected);
        manager.endPromptTurn(afterClose);
        final disposed = manager.beginPromptTurn('dispose-session');
        await manager.dispose();
        manager.endPromptTurn(disposed);
        expect(
          () => manager.beginPromptTurn('dispose-session'),
          throwsStateError,
        );
      } finally {
        await manager.dispose();
        await peer.close();
        await server.cancel();
        await channel.local.sink.close();
      }
    },
  );

  test(
    'resume and load own serialized phases without a global mutex',
    () async {
      final channel = StreamChannelController<String>();
      final peer = JsonRpcPeer(channel.foreign);
      final manager = SessionManager(config: acp.AcpConfig(), peer: peer);
      final resumeRequest = Completer<Object?>();
      final loadRequest = Completer<Object?>();
      var resumeCount = 0;
      var loadCount = 0;
      final server = channel.local.stream.listen((line) {
        final request = jsonDecode(line) as Map<String, dynamic>;
        if (request['method'] == 'session/resume') {
          final sessionId = (request['params'] as Map)['sessionId'];
          if (sessionId == 'other-session') {
            channel.local.sink.add(
              jsonEncode(<String, dynamic>{
                'jsonrpc': '2.0',
                'id': request['id'],
                'result': <String, dynamic>{},
              }),
            );
            return;
          }
          resumeCount += 1;
          if (!resumeRequest.isCompleted) resumeRequest.complete(request['id']);
        } else if (request['method'] == 'session/load') {
          loadCount += 1;
          if (!loadRequest.isCompleted) loadRequest.complete(request['id']);
        }
      });

      void respond(Object? id) {
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': id,
            'result': <String, dynamic>{},
          }),
        );
      }

      try {
        await manager.resumeSession(
          sessionId: 'other-session',
          workspaceRoot: '/workspace/other',
        );
        final resume = manager.resumeSession(
          sessionId: 'setup-session',
          workspaceRoot: '/workspace',
        );
        final resumeId = await resumeRequest.future.timeout(
          const Duration(seconds: 5),
        );
        expect(
          () => manager.beginPromptTurn('setup-session'),
          throwsStateError,
        );

        final load = manager.loadSession(
          sessionId: 'setup-session',
          workspaceRoot: '/workspace',
        );
        await pumpEventQueue();
        expect(
          loadCount,
          0,
          reason: 'existing setup serialization is preserved',
        );
        expect(
          () => manager.beginPromptTurn('setup-session'),
          throwsStateError,
        );

        final other = manager.beginPromptTurn('other-session');
        manager.endPromptTurn(other);
        respond(resumeId);
        await resume;
        final loadId = await loadRequest.future.timeout(
          const Duration(seconds: 5),
        );
        expect(resumeCount, 1);
        expect(
          () => manager.beginPromptTurn('setup-session'),
          throwsStateError,
        );
        respond(loadId);
        await load;

        final afterSetup = manager.beginPromptTurn('setup-session');
        manager.endPromptTurn(afterSetup);
      } finally {
        await manager.dispose();
        await peer.close();
        await server.cancel();
        await channel.local.sink.close();
      }
    },
  );

  test(
    'overlapping prompt failure stays local to the rejected stream',
    () async {
      final channel = StreamChannelController<String>();
      final peer = JsonRpcPeer(channel.foreign);
      final manager = SessionManager(config: acp.AcpConfig(), peer: peer);
      final firstPromptId = Completer<Object?>();
      var promptRequests = 0;
      final server = channel.local.stream.listen((line) {
        final request = jsonDecode(line) as Map<String, dynamic>;
        if (request['method'] == 'session/resume') {
          channel.local.sink.add(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': request['id'],
              'result': <String, dynamic>{},
            }),
          );
        } else if (request['method'] == 'session/prompt') {
          promptRequests += 1;
          if (!firstPromptId.isCompleted) firstPromptId.complete(request['id']);
        }
      });

      final sharedUpdates = <acp.AcpUpdate>[];
      final sharedErrors = <Object>[];
      StreamSubscription<acp.AcpUpdate>? shared;
      try {
        await manager.resumeSession(
          sessionId: 'prompt-overlap',
          workspaceRoot: '/workspace',
        );
        shared = manager
            .sessionUpdates('prompt-overlap')
            .listen(sharedUpdates.add, onError: sharedErrors.add);
        final first = manager
            .prompt(
              sessionId: 'prompt-overlap',
              content: const <Map<String, dynamic>>[],
            )
            .toList();
        final firstId = await firstPromptId.future.timeout(
          const Duration(seconds: 5),
        );

        await expectLater(
          manager
              .prompt(
                sessionId: 'prompt-overlap',
                content: const <Map<String, dynamic>>[],
              )
              .toList(),
          throwsStateError,
        );
        await pumpEventQueue();
        expect(promptRequests, 1);
        expect(sharedErrors, isEmpty);
        expect(sharedUpdates.whereType<acp.TurnEnded>(), isEmpty);

        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': firstId,
            'result': <String, dynamic>{'stopReason': 'end_turn'},
          }),
        );
        await first.timeout(const Duration(seconds: 5));
      } finally {
        await shared?.cancel();
        await manager.dispose();
        await peer.close();
        await server.cancel();
        await channel.local.sink.close();
      }
    },
  );

  for (final lateOutcome in const <String>['success', 'error']) {
    test(
      'stale cancelled prompt $lateOutcome reaps before its replacement',
      () async {
        final channel = StreamChannelController<String>();
        final peer = JsonRpcPeer(channel.foreign);
        final manager = SessionManager(config: acp.AcpConfig(), peer: peer);
        final promptIds = <Object?>[];
        final promptSeen = StreamController<void>.broadcast();
        final server = channel.local.stream.listen((line) {
          final request = jsonDecode(line) as Map<String, dynamic>;
          if (request['method'] == 'session/resume') {
            channel.local.sink.add(
              jsonEncode(<String, dynamic>{
                'jsonrpc': '2.0',
                'id': request['id'],
                'result': <String, dynamic>{},
              }),
            );
          } else if (request['method'] == 'session/prompt') {
            promptIds.add(request['id']);
            promptSeen.add(null);
          }
        });
        final sharedUpdates = <acp.AcpUpdate>[];
        final sharedErrors = <Object>[];
        StreamSubscription<acp.AcpUpdate>? shared;
        StreamSubscription<acp.AcpUpdate>? first;

        try {
          await manager.resumeSession(
            sessionId: 'stale-prompt',
            workspaceRoot: '/workspace',
          );
          shared = manager
              .sessionUpdates('stale-prompt')
              .listen(sharedUpdates.add, onError: sharedErrors.add);
          final firstSeen = promptSeen.stream.first;
          first = manager
              .prompt(
                sessionId: 'stale-prompt',
                content: const <Map<String, dynamic>>[],
              )
              .listen((_) {});
          await firstSeen.timeout(const Duration(seconds: 5));
          await first.cancel();
          first = null;

          await expectLater(
            manager
                .prompt(
                  sessionId: 'stale-prompt',
                  content: const <Map<String, dynamic>>[],
                )
                .toList(),
            throwsStateError,
          );
          expect(promptIds, hasLength(1));

          channel.local.sink.add(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': promptIds.first,
              if (lateOutcome == 'success')
                'result': <String, dynamic>{'stopReason': 'end_turn'}
              else
                'error': <String, dynamic>{
                  'code': -32000,
                  'message': 'fixed stale prompt failure',
                },
            }),
          );
          await pumpEventQueue();
          expect(sharedUpdates.whereType<acp.TurnEnded>(), isEmpty);
          expect(sharedErrors, isEmpty);

          final secondSeen = promptSeen.stream.first;
          final replacement = manager
              .prompt(
                sessionId: 'stale-prompt',
                content: const <Map<String, dynamic>>[],
              )
              .toList();
          await secondSeen.timeout(const Duration(seconds: 5));
          expect(promptIds, hasLength(2));
          channel.local.sink.add(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': promptIds.last,
              'result': <String, dynamic>{'stopReason': 'end_turn'},
            }),
          );
          final updates = await replacement.timeout(const Duration(seconds: 5));
          expect(updates.whereType<acp.TurnEnded>(), hasLength(1));
        } finally {
          await first?.cancel();
          await shared?.cancel();
          await promptSeen.close();
          await manager.dispose();
          await peer.close();
          await server.cancel();
          await channel.local.sink.close();
        }
      },
    );
  }

  test('immediate prompt stream cancel releases its exact owner', () async {
    final channel = StreamChannelController<String>();
    final peer = JsonRpcPeer(channel.foreign);
    final manager = SessionManager(config: acp.AcpConfig(), peer: peer);
    final cancelSeen = Completer<void>();
    final promptId = Completer<Object?>();
    final server = channel.local.stream.listen((line) {
      final request = jsonDecode(line) as Map<String, dynamic>;
      if (request['method'] == 'session/resume') {
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': request['id'],
            'result': <String, dynamic>{},
          }),
        );
      } else if (request['method'] == 'session/cancel') {
        if (!cancelSeen.isCompleted) cancelSeen.complete();
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': request['id'],
            'result': <String, dynamic>{},
          }),
        );
      } else if (request['method'] == 'session/prompt' &&
          !promptId.isCompleted) {
        promptId.complete(request['id']);
      }
    });

    try {
      await manager.resumeSession(
        sessionId: 'immediate-cancel',
        workspaceRoot: '/workspace',
      );
      final subscription = manager
          .prompt(
            sessionId: 'immediate-cancel',
            content: const <Map<String, dynamic>>[],
          )
          .listen((_) {});
      await subscription.cancel();
      await cancelSeen.future.timeout(const Duration(seconds: 5));

      expect(
        () => manager.beginPromptTurn('immediate-cancel'),
        throwsStateError,
        reason: 'owner-bound prompt remains settling until request reap',
      );
      final id = await promptId.future.timeout(const Duration(seconds: 5));
      channel.local.sink.add(
        jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': id,
          'result': <String, dynamic>{'stopReason': 'end_turn'},
        }),
      );
      await pumpEventQueue();
      final replacement = manager.beginPromptTurn('immediate-cancel');
      manager.endPromptTurn(replacement);
    } finally {
      await manager.dispose();
      await peer.close();
      await server.cancel();
      await channel.local.sink.close();
    }
  });

  test('prompt RPC error releases the exact owner', () async {
    final channel = StreamChannelController<String>();
    final peer = JsonRpcPeer(channel.foreign);
    final manager = SessionManager(config: acp.AcpConfig(), peer: peer);
    final server = channel.local.stream.listen((line) {
      final request = jsonDecode(line) as Map<String, dynamic>;
      if (request['method'] == 'session/resume') {
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': request['id'],
            'result': <String, dynamic>{},
          }),
        );
      } else if (request['method'] == 'session/prompt') {
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': request['id'],
            'error': <String, dynamic>{
              'code': -32000,
              'message': 'fixed prompt failure',
            },
          }),
        );
      }
    });

    try {
      await manager.resumeSession(
        sessionId: 'prompt-error',
        workspaceRoot: '/workspace',
      );
      await expectLater(
        manager
            .prompt(
              sessionId: 'prompt-error',
              content: const <Map<String, dynamic>>[],
            )
            .toList(),
        throwsA(anything),
      );
      final replacement = manager.beginPromptTurn('prompt-error');
      manager.endPromptTurn(replacement);
    } finally {
      await manager.dispose();
      await peer.close();
      await server.cancel();
      await channel.local.sink.close();
    }
  });

  test('cancel submission failure still releases the owned phase', () async {
    final channel = StreamChannelController<String>();
    final peer = JsonRpcPeer(channel.foreign);
    final manager = SessionManager(config: acp.AcpConfig(), peer: peer);
    final server = channel.local.stream.listen((line) {
      final request = jsonDecode(line) as Map<String, dynamic>;
      if (request['method'] == 'session/resume') {
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': request['id'],
            'result': <String, dynamic>{},
          }),
        );
      }
    });

    try {
      await manager.resumeSession(
        sessionId: 'cancel-error',
        workspaceRoot: '/workspace/cancel-error',
      );
      final owner = manager.beginPromptTurn('cancel-error');
      peer.failNextCancelSubmissionForTesting();
      await expectLater(
        manager.cancelPromptTurn(owner),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'fixed session/cancel submission failure',
          ),
        ),
      );
      await pumpEventQueue();
      final replacement = manager.beginPromptTurn('cancel-error');
      manager.endPromptTurn(replacement);
    } finally {
      await manager.dispose();
      await peer.close();
      await server.cancel();
      await channel.local.sink.close();
    }
  });

  test(
    'late generated-session callback cannot recreate state after dispose',
    () async {
      final channel = StreamChannelController<String>();
      final peer = JsonRpcPeer(channel.foreign);
      final manager = SessionManager(config: acp.AcpConfig(), peer: peer);
      final requestId = Completer<Object?>();
      final server = channel.local.stream.listen((line) {
        final request = jsonDecode(line) as Map<String, dynamic>;
        if (request['method'] == 'session/new' && !requestId.isCompleted) {
          requestId.complete(request['id']);
        }
      });

      try {
        final pending = manager.newSession(workspaceRoot: '/workspace');
        final id = await requestId.future.timeout(const Duration(seconds: 5));
        await manager.dispose();
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': id,
            'result': <String, dynamic>{'sessionId': 'late-session'},
          }),
        );

        await expectLater(pending, throwsStateError);
        expect(
          () => manager.prompt(
            sessionId: 'late-session',
            content: const <Map<String, dynamic>>[],
          ),
          throwsArgumentError,
        );
      } finally {
        await manager.dispose();
        await peer.close();
        await server.cancel();
        await channel.local.sink.close();
      }
    },
  );

  test('session close waits for an earlier resume mutation', () async {
    final channel = StreamChannelController<String>();
    final peer = JsonRpcPeer(channel.foreign);
    final manager = SessionManager(config: acp.AcpConfig(), peer: peer);
    final resumeId = Completer<Object?>();
    final closeId = Completer<Object?>();
    final server = channel.local.stream.listen((line) {
      final request = jsonDecode(line) as Map<String, dynamic>;
      if (request['method'] == 'session/resume') {
        if (!resumeId.isCompleted) resumeId.complete(request['id']);
      } else if (request['method'] == 'session/close') {
        if (!closeId.isCompleted) closeId.complete(request['id']);
      }
    });

    void respond(Object? id) {
      channel.local.sink.add(
        jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': id,
          'result': <String, dynamic>{},
        }),
      );
    }

    try {
      final resume = manager.resumeSession(
        sessionId: 'closing-resume',
        workspaceRoot: '/workspace',
      );
      final pendingResumeId = await resumeId.future.timeout(
        const Duration(seconds: 5),
      );
      final close = manager.closeSession(sessionId: 'closing-resume');
      await pumpEventQueue();
      expect(closeId.isCompleted, isFalse);
      respond(pendingResumeId);
      await resume.timeout(const Duration(seconds: 5));
      final pendingCloseId = await closeId.future.timeout(
        const Duration(seconds: 5),
      );
      respond(pendingCloseId);
      await close.timeout(const Duration(seconds: 5));
      expect(
        manager.localSessionStateKeysForTesting('closing-resume'),
        isEmpty,
      );
      expect(manager.sessionCloseSelectionCountForTesting('closing-resume'), 0);
    } finally {
      await manager.dispose();
      await peer.close();
      await server.cancel();
      await channel.local.sink.close();
    }
  });

  test('late load response fails after manager dispose', () async {
    final channel = StreamChannelController<String>();
    final peer = JsonRpcPeer(channel.foreign);
    final manager = SessionManager(config: acp.AcpConfig(), peer: peer);
    final loadId = Completer<Object?>();
    final server = channel.local.stream.listen((line) {
      final request = jsonDecode(line) as Map<String, dynamic>;
      if (request['method'] == 'session/load' && !loadId.isCompleted) {
        loadId.complete(request['id']);
      }
    });

    try {
      final load = manager.loadSession(
        sessionId: 'disposed-load',
        workspaceRoot: '/workspace',
      );
      final pendingLoadId = await loadId.future.timeout(
        const Duration(seconds: 5),
      );
      await manager.dispose();
      channel.local.sink.add(
        jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': pendingLoadId,
          'result': <String, dynamic>{},
        }),
      );

      await expectLater(load, throwsStateError);
      expect(() => manager.getWorkspaceRoot('disposed-load'), throwsStateError);
    } finally {
      await manager.dispose();
      await peer.close();
      await server.cancel();
      await channel.local.sink.close();
    }
  });

  test(
    'session updates drop unknown sessions but accept load-time updates after binding',
    () async {
      final channel = StreamChannelController<String>();
      final peer = JsonRpcPeer(channel.foreign);
      final manager = SessionManager(config: acp.AcpConfig(), peer: peer);
      final updates = <acp.AcpUpdate>[];
      final subscription = manager
          .sessionUpdates('session-route')
          .listen(updates.add);
      final server = channel.local.stream.listen((line) {
        final request = jsonDecode(line) as Map<String, dynamic>;
        if (request['method'] != 'session/load') return;
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'method': 'session/update',
            'params': <String, dynamic>{
              'sessionId': 'session-route',
              'update': <String, dynamic>{
                'sessionUpdate': 'current_mode_update',
                'currentModeId': 'bound',
              },
            },
          }),
        );
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': request['id'],
            'result': <String, dynamic>{},
          }),
        );
      });

      try {
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'method': 'session/update',
            'params': <String, dynamic>{
              'sessionId': 'session-route',
              'update': <String, dynamic>{
                'sessionUpdate': 'current_mode_update',
                'currentModeId': 'unbound',
              },
            },
          }),
        );
        await pumpEventQueue();
        expect(updates, isEmpty);

        await manager.loadSession(
          sessionId: 'session-route',
          workspaceRoot: '/workspace',
        );
        await pumpEventQueue();

        expect(
          updates.whereType<acp.ModeUpdate>().single.currentModeId,
          'bound',
        );
      } finally {
        await subscription.cancel();
        await manager.dispose();
        await peer.close();
        await server.cancel();
        await channel.local.sink.close();
      }
    },
  );

  test(
    'new and fork responses are bounded before generated sessions register',
    () async {
      const budget = acp.AcpInputBudget(maxStructuredStringBytes: 4);
      final channel = StreamChannelController<String>();
      final peer = JsonRpcPeer(channel.foreign);
      final manager = SessionManager(
        config: acp.AcpConfig(),
        peer: peer,
        inputBudget: budget,
      );
      final server = channel.local.stream.listen((line) {
        final request = jsonDecode(line) as Map<String, dynamic>;
        final method = request['method'];
        if (method == 'session/resume') {
          channel.local.sink.add(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': request['id'],
              'result': <String, dynamic>{},
            }),
          );
        } else if (method == 'session/new' || method == 'session/fork') {
          channel.local.sink.add(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': request['id'],
              'result': <String, dynamic>{'sessionId': '12345'},
            }),
          );
        }
      });

      try {
        await expectLater(
          manager.newSession(workspaceRoot: '/workspace'),
          throwsA(isA<acp.AcpInputLimitExceeded>()),
        );
        expect(
          () => manager.prompt(
            sessionId: '12345',
            content: const <Map<String, dynamic>>[],
          ),
          throwsArgumentError,
        );

        await manager.resumeSession(
          sessionId: 's',
          workspaceRoot: '/workspace',
        );
        await expectLater(
          manager.forkSession(sessionId: 's'),
          throwsA(isA<acp.AcpInputLimitExceeded>()),
        );
        expect(
          () => manager.prompt(
            sessionId: '12345',
            content: const <Map<String, dynamic>>[],
          ),
          throwsArgumentError,
        );
      } finally {
        await manager.dispose();
        await peer.close();
        await server.cancel();
        await channel.local.sink.close();
      }
    },
  );

  for (final activePrompt in const <bool>[false, true]) {
    test(
      'generated id collision preserves ${activePrompt ? 'active' : 'idle'} session state',
      () async {
        final channel = StreamChannelController<String>();
        final peer = JsonRpcPeer(channel.foreign);
        final manager = SessionManager(config: acp.AcpConfig(), peer: peer);
        final server = channel.local.stream.listen((line) {
          final request = jsonDecode(line) as Map<String, dynamic>;
          final method = request['method'];
          if (method == 'session/resume') {
            channel.local.sink.add(
              jsonEncode(<String, dynamic>{
                'jsonrpc': '2.0',
                'id': request['id'],
                'result': <String, dynamic>{'currentModeId': 'existing-mode'},
              }),
            );
          } else if (method == 'session/new' || method == 'session/fork') {
            channel.local.sink.add(
              jsonEncode(<String, dynamic>{
                'jsonrpc': '2.0',
                'id': request['id'],
                'result': <String, dynamic>{'sessionId': 'live-session'},
              }),
            );
          }
        });
        final updates = <acp.AcpUpdate>[];
        var streamDone = false;
        StreamSubscription<acp.AcpUpdate>? subscription;
        acp.AcpSessionInputBudgetOwner? owner;

        void sendTool(String status, {String? title}) {
          channel.local.sink.add(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'method': 'session/update',
              'params': <String, dynamic>{
                'sessionId': 'live-session',
                'update': <String, dynamic>{
                  'sessionUpdate': status == 'pending'
                      ? 'tool_call'
                      : 'tool_call_update',
                  'toolCallId': 'existing-tool',
                  'status': status,
                  'title': ?title,
                },
              },
            }),
          );
        }

        try {
          await manager.resumeSession(
            sessionId: 'live-session',
            workspaceRoot: '/workspace',
          );
          subscription = manager
              .sessionUpdates('live-session')
              .listen(updates.add, onDone: () => streamDone = true);
          owner = manager.beginPromptTurn('live-session');
          sendTool('pending', title: 'Original tool');
          await pumpEventQueue();
          if (!activePrompt) {
            manager.endPromptTurn(owner);
            owner = null;
          }

          final newCollision = manager.newSession(workspaceRoot: '/workspace');
          final forkCollision = manager.forkSession(sessionId: 'live-session');
          await Future.wait<void>(<Future<void>>[
            expectLater(newCollision, throwsStateError),
            expectLater(forkCollision, throwsStateError),
          ]);

          expect(manager.getWorkspaceRoot('live-session'), '/workspace');
          expect(
            manager.sessionModes('live-session')?.currentModeId,
            'existing-mode',
          );
          expect(streamDone, isFalse);
          if (activePrompt) {
            expect(
              () => manager.beginPromptTurn('live-session'),
              throwsStateError,
            );
          } else {
            owner = manager.beginPromptTurn('live-session');
          }
          sendTool('completed');
          await pumpEventQueue();
          final completed = updates
              .whereType<acp.ToolCallUpdate>()
              .where(
                (update) =>
                    update.toolCall.status == acp.ToolCallStatus.completed,
              )
              .single;
          expect(completed.toolCall.title, 'Original tool');
        } finally {
          if (owner != null) manager.endPromptTurn(owner);
          await subscription?.cancel();
          await manager.dispose();
          await peer.close();
          await server.cancel();
          await channel.local.sink.close();
        }
      },
    );
  }

  test(
    'generated id collision preserves an unknown-session listener',
    () async {
      final channel = StreamChannelController<String>();
      final peer = JsonRpcPeer(channel.foreign);
      final manager = SessionManager(config: acp.AcpConfig(), peer: peer);
      var streamDone = false;
      final subscription = manager
          .sessionUpdates('reserved-id')
          .listen((_) {}, onDone: () => streamDone = true);
      final server = channel.local.stream.listen((line) {
        final request = jsonDecode(line) as Map<String, dynamic>;
        if (request['method'] != 'session/new') return;
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': request['id'],
            'result': <String, dynamic>{'sessionId': 'reserved-id'},
          }),
        );
      });
      try {
        await expectLater(
          manager.newSession(workspaceRoot: '/workspace'),
          throwsStateError,
        );
        expect(streamDone, isFalse);
        expect(() => manager.getWorkspaceRoot('reserved-id'), throwsStateError);
      } finally {
        await subscription.cancel();
        await manager.dispose();
        await peer.close();
        await server.cancel();
        await channel.local.sink.close();
      }
    },
  );

  test(
    'generated session drops pre-response updates and owns post-response updates',
    () async {
      const canary = 'PRE_RESPONSE_OVERSIZE_CANARY';
      final channel = StreamChannelController<String>();
      final peer = JsonRpcPeer(channel.foreign);
      final manager = SessionManager(
        config: acp.AcpConfig(),
        peer: peer,
        inputBudget: const acp.AcpInputBudget(maxStructuredStringBytes: 24),
      );
      final server = channel.local.stream.listen((line) {
        final request = jsonDecode(line) as Map<String, dynamic>;
        if (request['method'] != 'session/new') return;
        for (final update in <Object?>[
          <Object?>['non-map-pre-response'],
          <String, dynamic>{
            'sessionUpdate': 'current_mode_update',
            'currentModeId': canary,
          },
        ]) {
          channel.local.sink.add(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'method': 'session/update',
              'params': <String, dynamic>{
                'sessionId': 'generated-order',
                'update': update,
              },
            }),
          );
        }
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': request['id'],
            'result': <String, dynamic>{'sessionId': 'generated-order'},
          }),
        );
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'method': 'session/update',
            'params': <String, dynamic>{
              'sessionId': 'generated-order',
              'update': <String, dynamic>{
                'sessionUpdate': 'current_mode_update',
                'currentModeId': 'post-response',
              },
            },
          }),
        );
      });

      try {
        final sessionId = await manager.newSession(workspaceRoot: '/workspace');
        expect(sessionId, 'generated-order');
        expect(manager.sessionModes(sessionId)?.currentModeId, 'post-response');
        final replay = await manager.sessionUpdates(sessionId).take(1).toList();
        expect(replay.single, isA<acp.ModeUpdate>());
        expect(
          (replay.single as acp.ModeUpdate).currentModeId,
          'post-response',
        );
        expect(replay.toString(), isNot(contains(canary)));
      } finally {
        await manager.dispose();
        await peer.close();
        await server.cancel();
        await channel.local.sink.close();
      }
    },
  );

  test(
    'session updates require an owning phase and use its structured guard',
    () async {
      const budget = acp.AcpInputBudget(maxStructuredStringBytes: 20);
      final channel = StreamChannelController<String>();
      final peer = JsonRpcPeer(channel.foreign);
      final manager = SessionManager(
        config: acp.AcpConfig(),
        peer: peer,
        inputBudget: budget,
      );
      final updates = <acp.AcpUpdate>[];
      final server = channel.local.stream.listen((line) {
        final request = jsonDecode(line) as Map<String, dynamic>;
        if (request['method'] != 'session/resume') return;
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': request['id'],
            'result': <String, dynamic>{},
          }),
        );
      });
      StreamSubscription<acp.AcpUpdate>? subscription;

      void sendMode(String currentModeId) {
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'method': 'session/update',
            'params': <String, dynamic>{
              'sessionId': 'owned-route',
              'update': <String, dynamic>{
                'sessionUpdate': 'current_mode_update',
                'currentModeId': currentModeId,
              },
            },
          }),
        );
      }

      try {
        await manager.resumeSession(
          sessionId: 'owned-route',
          workspaceRoot: '/workspace',
        );
        subscription = manager
            .sessionUpdates('owned-route')
            .listen(updates.add);

        sendMode('late');
        await pumpEventQueue();
        expect(
          updates,
          isEmpty,
          reason: 'updates without a phase are rejected',
        );

        final owner = manager.beginPromptTurn('owned-route');
        sendMode('123456789012345678901');
        await pumpEventQueue();
        final bounded = updates.single as acp.ModeUpdate;
        expect(bounded.currentModeId, isEmpty);
        expect(bounded.omission?.reason, acp.AcpInputOmissionReason.inputLimit);
        manager.endPromptTurn(owner);

        sendMode('late');
        await pumpEventQueue();
        expect(updates, hasLength(1));
      } finally {
        await subscription?.cancel();
        await manager.dispose();
        await peer.close();
        await server.cancel();
        await channel.local.sink.close();
      }
    },
  );

  test(
    'unknown session rejects a non-map update before typed access',
    () async {
      final uncaught = <Object>[];
      await runZonedGuarded<Future<void>>(() async {
        final channel = StreamChannelController<String>();
        final peer = JsonRpcPeer(channel.foreign);
        final manager = SessionManager(config: acp.AcpConfig(), peer: peer);
        try {
          channel.local.sink.add(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'method': 'session/update',
              'params': <String, dynamic>{
                'sessionId': 'never-registered',
                'update': <Object?>['must-not-be-cast'],
              },
            }),
          );
          await pumpEventQueue();
          expect(
            () => manager.prompt(
              sessionId: 'never-registered',
              content: const <Map<String, dynamic>>[],
            ),
            throwsArgumentError,
          );
        } finally {
          await manager.dispose();
          await peer.close();
          await channel.local.sink.close();
        }
      }, (error, _) => uncaught.add(error));
      expect(uncaught, isEmpty);
    },
  );

  test(
    'session update RPC ignores non-object and huge unknown envelopes',
    () async {
      final uncaught = <Object>[];
      await runZonedGuarded<Future<void>>(() async {
        final channel = StreamChannelController<String>();
        final peer = JsonRpcPeer(channel.foreign);
        final manager = SessionManager(config: acp.AcpConfig(), peer: peer);
        final responses = <Object?, Map<String, dynamic>>{};
        final responsesComplete = Completer<void>();
        final server = channel.local.stream.listen((line) {
          final message = jsonDecode(line) as Map<String, dynamic>;
          responses[message['id']] = message;
          if (responses.length == 2 && !responsesComplete.isCompleted) {
            responsesComplete.complete();
          }
        });
        try {
          channel.local.sink.add(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': 'non-object',
              'method': 'session/update',
              'params': <Object?>['not-an-object'],
            }),
          );
          final hugeUnknown = <String, dynamic>{
            'sessionId': 'unknown-envelope',
            for (var index = 0; index < 4096; index += 1)
              'ignored-$index': 'UNKNOWN_ENVELOPE_CANARY',
            'update': <Object?>['must-not-be-cast'],
          };
          channel.local.sink.add(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': 'huge-unknown',
              'method': 'session/update',
              'params': hugeUnknown,
            }),
          );
          await responsesComplete.future.timeout(const Duration(seconds: 5));
          for (final id in const <String>['non-object', 'huge-unknown']) {
            expect(responses[id]?['result'], isNull);
            expect(responses[id], isNot(contains('error')));
          }
          expect(
            () => manager.getWorkspaceRoot('unknown-envelope'),
            throwsStateError,
          );
        } finally {
          await manager.dispose();
          await peer.close();
          await server.cancel();
          await channel.local.sink.close();
        }
      }, (error, _) => uncaught.add(error));
      expect(uncaught, isEmpty);
    },
  );

  test('session update routing isolates hostile map getters', () async {
    const canary = 'HOSTILE_SESSION_UPDATE_CANARY';
    final uncaught = <Object>[];
    await runZonedGuarded<Future<void>>(() async {
      final channel = StreamChannelController<String>();
      final peer = JsonRpcPeer(channel.foreign);
      final logger = acp.AcpConfig().logger;
      final logs = <String>[];
      final logSubscription = logger.onRecord.listen(
        (record) => logs.add(record.message),
      );
      final manager = SessionManager(
        config: acp.AcpConfig(logger: logger),
        peer: peer,
      );
      final updatesA = <acp.AcpUpdate>[];
      final errorsA = <Object>[];
      final updatesB = <acp.AcpUpdate>[];
      final errorsB = <Object>[];
      var reentrantGetterCalled = false;
      final subscriptionA = manager
          .sessionUpdates('hostile-a')
          .listen(updatesA.add, onError: errorsA.add);
      final subscriptionB = manager
          .sessionUpdates('hostile-b')
          .listen(updatesB.add, onError: errorsB.add);
      final server = channel.local.stream.listen((line) {
        final request = jsonDecode(line) as Map<String, dynamic>;
        if (request['method'] != 'session/resume') return;
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': request['id'],
            'result': <String, dynamic>{},
          }),
        );
      });

      try {
        await manager.resumeSession(
          sessionId: 'hostile-a',
          workspaceRoot: '/workspace/a',
        );
        await manager.resumeSession(
          sessionId: 'hostile-b',
          workspaceRoot: '/workspace/b',
        );
        await server.cancel();
        final ownerA = manager.beginPromptTurn('hostile-a');
        final ownerB = manager.beginPromptTurn('hostile-b');

        peer.dispatchSessionUpdateForTesting(
          _ThrowingGetterMap(
            <String, dynamic>{'update': const <String, dynamic>{}},
            throwKey: 'sessionId',
            error: StateError(canary),
          ),
        );
        peer.dispatchSessionUpdateForTesting(
          _ReentrantSessionEnvelope(
            onSessionIdRead: () {
              reentrantGetterCalled = true;
              peer.dispatchSessionUpdateForTesting(<String, dynamic>{
                'sessionId': 'hostile-b',
                'update': <String, dynamic>{
                  'sessionUpdate': 'current_mode_update',
                  'currentModeId': 'reentrant-safe',
                },
              });
            },
          ),
        );
        peer.dispatchSessionUpdateForTesting(
          _ThrowingGetterMap(
            <String, dynamic>{'sessionId': 'hostile-a'},
            throwKey: 'update',
            error: StateError(canary),
          ),
        );
        peer.dispatchSessionUpdateForTesting(<String, dynamic>{
          'sessionId': 'hostile-a',
          'update': _ThrowingGetterMap(
            const <String, dynamic>{},
            throwKey: 'sessionUpdate',
            error: StateError(canary),
          ),
        });
        peer.dispatchSessionUpdateForTesting(<String, dynamic>{
          'sessionId': 'hostile-a',
          'update': _ThrowingGetterMap(
            const <String, dynamic>{},
            throwKey: 'sessionUpdate',
            error: const acp.AcpInputLimitExceeded(
              resource: canary,
              limit: 1,
              observedAtLeast: 2,
            ),
          ),
        });
        peer.dispatchSessionUpdateForTesting(<String, dynamic>{
          'sessionId': 'hostile-a',
          'update': _ThrowingGetterMap(
            const <String, dynamic>{},
            throwKey: 'sessionUpdate',
            error: acp.AcpInputLimitExceeded(
              resource: 'session input phase ${'x' * 300} nodes',
              limit: 0x1fffffffffffff,
              observedAtLeast: 0x1fffffffffffff,
            ),
          ),
        });
        peer.dispatchSessionUpdateForTesting(<String, dynamic>{
          'sessionId': 'hostile-a',
          'update': _ThrowingGetterMap(
            const <String, dynamic>{},
            throwKey: 'sessionUpdate',
            error: const acp.AcpInputLimitExceeded(
              resource: 'session input phase $canary',
              limit: 0x1fffffffffffff,
              observedAtLeast: 0x1fffffffffffff,
            ),
          ),
        });
        peer.dispatchSessionUpdateForTesting(<String, dynamic>{
          'sessionId': 'hostile-a',
          'update': _ThrowingGetterMap(
            const <String, dynamic>{},
            throwKey: 'sessionUpdate',
            error: const acp.AcpInputLimitExceeded(
              resource: 'session input phase $canary string bytes',
              limit: 0x1fffffffffffff,
              observedAtLeast: 0x1fffffffffffff,
            ),
          ),
        });
        peer.dispatchSessionUpdateForTesting(<String, dynamic>{
          'sessionId': 'hostile-b',
          'update': <String, dynamic>{
            'sessionUpdate': 'current_mode_update',
            'currentModeId': 'after-hostile',
          },
        });
        await pumpEventQueue();
        manager.endPromptTurn(ownerA);
        manager.endPromptTurn(ownerB);
      } finally {
        await subscriptionA.cancel();
        await subscriptionB.cancel();
        await manager.dispose();
        await peer.close();
        await logSubscription.cancel();
        await channel.local.sink.close();
      }

      expect(errorsA, hasLength(6));
      for (final error in errorsA.take(5)) {
        expect(error, isA<FormatException>());
        expect(
          error.toString(),
          'FormatException: Invalid ACP session update.',
        );
        expect(error.toString(), isNot(contains(canary)));
      }
      final normalizedLimit = errorsA.last as acp.AcpInputLimitExceeded;
      expect(normalizedLimit.resource, 'session structured string bytes');
      expect(
        normalizedLimit.limit,
        const acp.AcpInputBudget().maxStructuredStringBytes,
      );
      expect(
        normalizedLimit.observedAtLeast,
        const acp.AcpInputBudget().maxStructuredStringBytes + 1,
      );
      expect(normalizedLimit.toString(), isNot(contains(canary)));
      expect(errorsB, isEmpty);
      expect(reentrantGetterCalled, isTrue);
      expect(
        updatesB.whereType<acp.ModeUpdate>().map(
          (update) => update.currentModeId,
        ),
        ['after-hostile'],
      );
      expect(updatesA, isEmpty);
      expect(logs, hasLength(6));
      expect(logs, everyElement('session update rejected'));
      expect(logs.toString(), isNot(contains(canary)));
    }, (error, _) => uncaught.add(error));
    expect(uncaught, isEmpty);
  });

  test('session update reports the real structured byte limit', () async {
    final channel = StreamChannelController<String>();
    final peer = JsonRpcPeer(channel.foreign);
    final manager = SessionManager(
      config: acp.AcpConfig(),
      peer: peer,
      inputBudget: const acp.AcpInputBudget(maxStructuredUpdateBytes: 5),
    );
    final updates = <acp.AcpUpdate>[];
    final errors = <Object>[];
    final subscription = manager
        .sessionUpdates('structured-byte-limit')
        .listen(updates.add, onError: errors.add);
    final server = channel.local.stream.listen((line) {
      final request = jsonDecode(line) as Map<String, dynamic>;
      if (request['method'] != 'session/resume') return;
      channel.local.sink.add(
        jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': request['id'],
          'result': <String, dynamic>{},
        }),
      );
    });

    try {
      await manager.resumeSession(
        sessionId: 'structured-byte-limit',
        workspaceRoot: '/workspace',
      );
      await server.cancel();
      final owner = manager.beginPromptTurn('structured-byte-limit');
      peer.dispatchSessionUpdateForTesting(<String, dynamic>{
        'sessionId': 'structured-byte-limit',
        'update': <String, dynamic>{
          'sessionUpdate': 'plan',
          'title': 'ab',
          'entries': const <Object?>[],
        },
      });
      await pumpEventQueue();
      manager.endPromptTurn(owner);
    } finally {
      await subscription.cancel();
      await manager.dispose();
      await peer.close();
      await channel.local.sink.close();
    }

    expect(updates, isEmpty);
    final error = errors.single as acp.AcpInputLimitExceeded;
    expect(error.resource, 'session structured bytes');
    expect(error.limit, 5);
    expect(error.observedAtLeast, 6);
  });

  test(
    'load replay update and immediate result use independent structured roots',
    () async {
      Future<void> runCase({
        required int maxNodes,
        required bool succeeds,
      }) async {
        final channel = StreamChannelController<String>();
        final peer = JsonRpcPeer(channel.foreign);
        final manager = SessionManager(
          config: acp.AcpConfig(),
          peer: peer,
          inputBudget: acp.AcpInputBudget(maxStructuredUpdateNodes: maxNodes),
        );
        final updates = <acp.AcpUpdate>[];
        final subscription = manager
            .sessionUpdates('shared-root')
            .listen(updates.add, onError: (_) {});
        final server = channel.local.stream.listen((line) {
          final request = jsonDecode(line) as Map<String, dynamic>;
          if (request['method'] != 'session/load') return;
          channel.local.sink.add(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'method': 'session/update',
              'params': <String, dynamic>{
                'sessionId': 'shared-root',
                'update': <String, dynamic>{
                  'sessionUpdate': 'current_mode_update',
                  'currentModeId': 'm',
                },
              },
            }),
          );
          Future<void>.delayed(const Duration(milliseconds: 10), () {
            channel.local.sink.add(
              jsonEncode(<String, dynamic>{
                'jsonrpc': '2.0',
                'id': request['id'],
                'result': <String, dynamic>{},
              }),
            );
          });
        });

        try {
          final load = manager.loadSession(
            sessionId: 'shared-root',
            workspaceRoot: '/workspace',
          );
          if (succeeds) {
            await load;
            expect(updates.whereType<acp.ModeUpdate>(), hasLength(1));
          } else {
            await expectLater(load, throwsA(isA<acp.AcpInputLimitExceeded>()));
          }
        } finally {
          await subscription.cancel();
          await manager.dispose();
          await peer.close();
          await server.cancel();
          await channel.local.sink.close();
        }
      }

      await runCase(maxNodes: 3, succeeds: true);
    },
  );

  test(
    'load update and immediate result use independent item and retained budgets',
    () async {
      Future<
        ({
          SessionManager manager,
          JsonRpcPeer peer,
          StreamSubscription<String> server,
          StreamChannelController<String> channel,
        })
      >
      createCase({
        required acp.AcpInputBudget budget,
        required String metaValue,
        bool seedOldMode = false,
      }) async {
        final channel = StreamChannelController<String>();
        final peer = JsonRpcPeer(channel.foreign);
        final manager = SessionManager(
          config: acp.AcpConfig(),
          peer: peer,
          inputBudget: budget,
        );
        final server = channel.local.stream.listen((line) {
          final request = jsonDecode(line) as Map<String, dynamic>;
          if (request['method'] == 'session/resume') {
            channel.local.sink.add(
              jsonEncode(<String, dynamic>{
                'jsonrpc': '2.0',
                'id': request['id'],
                'result': <String, dynamic>{
                  if (seedOldMode) 'currentModeId': 'old',
                },
              }),
            );
          } else if (request['method'] == 'session/load') {
            channel.local.sink.add(
              jsonEncode(<String, dynamic>{
                'jsonrpc': '2.0',
                'method': 'session/update',
                'params': <String, dynamic>{
                  'sessionId': 'combined-budget',
                  'update': <String, dynamic>{
                    'sessionUpdate': 'plan',
                    'entries': const <Object?>[],
                  },
                },
              }),
            );
            Future<void>.delayed(const Duration(milliseconds: 10), () {
              channel.local.sink.add(
                jsonEncode(<String, dynamic>{
                  'jsonrpc': '2.0',
                  'id': request['id'],
                  'result': <String, dynamic>{
                    if (seedOldMode) 'currentModeId': 'new',
                    'meta': <String, dynamic>{'x': metaValue},
                  },
                }),
              );
            });
          }
        });
        return (manager: manager, peer: peer, server: server, channel: channel);
      }

      for (final metaValue in const <String>['', 'a']) {
        final state = await createCase(
          budget: const acp.AcpInputBudget(maxTurnRetainedBytes: 364),
          metaValue: metaValue,
        );
        try {
          await state.manager.loadSession(
            sessionId: 'combined-budget',
            workspaceRoot: '/workspace',
          );
        } finally {
          await state.manager.dispose();
          await state.peer.close();
          await state.server.cancel();
          await state.channel.local.sink.close();
        }
      }

      final itemState = await createCase(
        budget: const acp.AcpInputBudget(maxTurnItems: 1),
        metaValue: '',
        seedOldMode: true,
      );
      try {
        await itemState.manager.resumeSession(
          sessionId: 'combined-budget',
          workspaceRoot: '/workspace',
        );
        await itemState.manager.loadSession(
          sessionId: 'combined-budget',
          workspaceRoot: '/workspace',
        );
        expect(
          itemState.manager.sessionModes('combined-budget')?.currentModeId,
          'new',
        );
      } finally {
        await itemState.manager.dispose();
        await itemState.peer.close();
        await itemState.server.cancel();
        await itemState.channel.local.sink.close();
      }
    },
  );

  test('late load response cannot restore modes after dispose', () async {
    final channel = StreamChannelController<String>();
    final peer = JsonRpcPeer(channel.foreign);
    final manager = SessionManager(config: acp.AcpConfig(), peer: peer);
    final loadId = Completer<Object?>();
    final server = channel.local.stream.listen((line) {
      final request = jsonDecode(line) as Map<String, dynamic>;
      if (request['method'] == 'session/resume') {
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': request['id'],
            'result': <String, dynamic>{
              'currentModeId': 'old',
              'availableModes': <Map<String, dynamic>>[
                <String, dynamic>{'id': 'old', 'name': 'Old'},
              ],
            },
          }),
        );
      } else if (request['method'] == 'session/load' && !loadId.isCompleted) {
        loadId.complete(request['id']);
      }
    });

    try {
      await manager.resumeSession(
        sessionId: 'late-modes',
        workspaceRoot: '/workspace',
      );
      expect(manager.sessionModes('late-modes')?.currentModeId, 'old');

      final load = manager.loadSession(
        sessionId: 'late-modes',
        workspaceRoot: '/workspace',
      );
      final pendingId = await loadId.future.timeout(const Duration(seconds: 5));
      await manager.dispose();
      channel.local.sink.add(
        jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': pendingId,
          'result': <String, dynamic>{
            'currentModeId': 'new',
            'availableModes': <Map<String, dynamic>>[
              <String, dynamic>{'id': 'new', 'name': 'New'},
            ],
          },
        }),
      );

      await expectLater(load, throwsStateError);
      expect(manager.sessionModes('late-modes'), isNull);
    } finally {
      await manager.dispose();
      await peer.close();
      await server.cancel();
      await channel.local.sink.close();
    }
  });

  test('closing a fork source invalidates its pending request guard', () async {
    final channel = StreamChannelController<String>();
    final peer = JsonRpcPeer(channel.foreign);
    final manager = SessionManager(config: acp.AcpConfig(), peer: peer);
    final forkId = Completer<Object?>();
    final closeId = Completer<Object?>();
    final server = channel.local.stream.listen((line) {
      final request = jsonDecode(line) as Map<String, dynamic>;
      if (request['method'] == 'session/resume') {
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': request['id'],
            'result': <String, dynamic>{},
          }),
        );
      } else if (request['method'] == 'session/fork') {
        if (!forkId.isCompleted) forkId.complete(request['id']);
      } else if (request['method'] == 'session/close') {
        if (!closeId.isCompleted) closeId.complete(request['id']);
      }
    });

    try {
      await manager.resumeSession(
        sessionId: 'fork-source',
        workspaceRoot: '/workspace',
      );
      final fork = manager.forkSession(sessionId: 'fork-source');
      final pendingForkId = await forkId.future.timeout(
        const Duration(seconds: 5),
      );
      final close = manager.closeSession(sessionId: 'fork-source');
      final pendingCloseId = await closeId.future.timeout(
        const Duration(seconds: 5),
      );
      channel.local.sink.add(
        jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': pendingCloseId,
          'result': <String, dynamic>{},
        }),
      );
      await close;
      channel.local.sink.add(
        jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': pendingForkId,
          'result': <String, dynamic>{'sessionId': 'late-fork'},
        }),
      );

      await expectLater(fork, throwsStateError);
      expect(
        () => manager.prompt(
          sessionId: 'late-fork',
          content: const <Map<String, dynamic>>[],
        ),
        throwsArgumentError,
      );
    } finally {
      await manager.dispose();
      await peer.close();
      await server.cancel();
      await channel.local.sink.close();
    }
  });

  test(
    'closing an explicit-workspace unknown fork source invalidates its request',
    () async {
      final channel = StreamChannelController<String>();
      final peer = JsonRpcPeer(channel.foreign);
      final manager = SessionManager(config: acp.AcpConfig(), peer: peer);
      final forkId = Completer<Object?>();
      final closeId = Completer<Object?>();
      final server = channel.local.stream.listen((line) {
        final request = jsonDecode(line) as Map<String, dynamic>;
        if (request['method'] == 'session/fork') {
          if (!forkId.isCompleted) forkId.complete(request['id']);
        } else if (request['method'] == 'session/close') {
          if (!closeId.isCompleted) closeId.complete(request['id']);
        }
      });
      try {
        final fork = manager.forkSession(
          sessionId: 'explicit-source',
          workspaceRoot: '/workspace',
        );
        final pendingForkId = await forkId.future.timeout(
          const Duration(seconds: 5),
        );
        final close = manager.closeSession(sessionId: 'explicit-source');
        final pendingCloseId = await closeId.future.timeout(
          const Duration(seconds: 5),
        );
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': pendingCloseId,
            'result': <String, dynamic>{},
          }),
        );
        await close;
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': pendingForkId,
            'result': <String, dynamic>{'sessionId': 'must-not-register'},
          }),
        );

        await expectLater(fork, throwsStateError);
        expect(
          () => manager.getWorkspaceRoot('must-not-register'),
          throwsStateError,
        );
      } finally {
        await manager.dispose();
        await peer.close();
        await server.cancel();
        await channel.local.sink.close();
      }
    },
  );

  test(
    'closing a fork source during drain rolls back its registration',
    () async {
      final channel = StreamChannelController<String>();
      final peer = JsonRpcPeer(channel.foreign);
      late final SessionManager manager;
      manager = SessionManager(config: acp.AcpConfig(), peer: peer);
      final closeCompleted = Completer<void>();
      final server = channel.local.stream.listen((line) {
        final request = jsonDecode(line) as Map<String, dynamic>;
        if (request['method'] == 'session/resume') {
          channel.local.sink.add(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': request['id'],
              'result': <String, dynamic>{},
            }),
          );
        } else if (request['method'] == 'session/fork') {
          channel.local.sink.add(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': request['id'],
              'result': <String, dynamic>{'sessionId': 'fork-drain-window'},
            }),
          );
          scheduleMicrotask(() async {
            for (var attempt = 0; attempt < 20; attempt += 1) {
              try {
                manager.getWorkspaceRoot('fork-drain-window');
                break;
              } on StateError {
                await Future<void>.microtask(() {});
              }
            }
            try {
              await manager.closeSession(sessionId: 'fork-drain-source');
              closeCompleted.complete();
            } on Object catch (error, stackTrace) {
              closeCompleted.completeError(error, stackTrace);
            }
          });
        } else if (request['method'] == 'session/close') {
          channel.local.sink.add(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': request['id'],
              'result': <String, dynamic>{},
            }),
          );
        }
      });

      try {
        await manager.resumeSession(
          sessionId: 'fork-drain-source',
          workspaceRoot: '/workspace',
        );
        final fork = manager.forkSession(sessionId: 'fork-drain-source');

        await expectLater(fork, throwsStateError);
        await closeCompleted.future.timeout(const Duration(seconds: 5));
        expect(
          () => manager.getWorkspaceRoot('fork-drain-window'),
          throwsStateError,
        );
      } finally {
        await manager.dispose();
        await peer.close();
        await server.cancel();
        await channel.local.sink.close();
      }
    },
  );

  test(
    'turn text thought and media aggregates enforce exact plus one',
    () async {
      const budget = acp.AcpInputBudget(
        maxMessageTextBytes: 4,
        maxMarkdownFallbackBytes: 4,
        maxThoughtTextBytes: 2,
        maxEmbeddedMediaBytes: 1,
      );
      final channel = StreamChannelController<String>();
      final peer = JsonRpcPeer(channel.foreign);
      final manager = SessionManager(
        config: acp.AcpConfig(),
        peer: peer,
        inputBudget: budget,
      );
      final updates = <acp.AcpUpdate>[];
      final errors = <Object>[];
      final server = channel.local.stream.listen((line) {
        final request = jsonDecode(line) as Map<String, dynamic>;
        if (request['method'] != 'session/resume') return;
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': request['id'],
            'result': <String, dynamic>{},
          }),
        );
      });
      StreamSubscription<acp.AcpUpdate>? subscription;

      void sendChunk(String kind, Map<String, dynamic> block) {
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'method': 'session/update',
            'params': <String, dynamic>{
              'sessionId': 'aggregate-turn',
              'update': <String, dynamic>{
                'sessionUpdate': kind,
                'content': <Map<String, dynamic>>[block],
              },
            },
          }),
        );
      }

      try {
        await manager.resumeSession(
          sessionId: 'aggregate-turn',
          workspaceRoot: '/workspace',
        );
        subscription = manager
            .sessionUpdates('aggregate-turn')
            .listen(updates.add, onError: errors.add);
        final owner = manager.beginPromptTurn('aggregate-turn');

        sendChunk('agent_message_chunk', <String, dynamic>{
          'type': 'text',
          'text': 'ab',
        });
        sendChunk('agent_message_chunk', <String, dynamic>{
          'type': 'text',
          'text': 'cd',
        });
        sendChunk('agent_message_chunk', <String, dynamic>{
          'type': 'text',
          'text': 'e',
        });
        sendChunk('agent_thought_chunk', <String, dynamic>{
          'type': 'text',
          'text': 'ab',
        });
        sendChunk('agent_thought_chunk', <String, dynamic>{
          'type': 'text',
          'text': 'c',
        });
        sendChunk('agent_message_chunk', <String, dynamic>{
          'type': 'image',
          'mimeType': 'image/png',
          'data': 'YQ==',
        });
        sendChunk('agent_message_chunk', <String, dynamic>{
          'type': 'image',
          'mimeType': 'image/png',
          'data': 'YQ==',
        });
        await pumpEventQueue();

        final deltas = updates.whereType<acp.MessageDelta>().toList();
        expect(deltas, hasLength(7));
        expect(deltas[0].text, 'ab');
        expect(deltas[1].text, 'cd');
        expect(deltas[2].text, isEmpty);
        expect(deltas[2].omissions.single.resource, 'message text');
        expect(deltas[3].text, 'ab');
        expect(deltas[4].text, isEmpty);
        expect(deltas[4].omissions.single.resource, 'thought text');
        expect(deltas[5].content.single, isA<acp.ImageContent>());
        expect(deltas[6].content.single, isA<acp.UnknownContent>());
        expect(
          (deltas[6].content.single as acp.UnknownContent).omission?.resource,
          'turn_media',
        );
        expect(errors, isEmpty);

        manager.endPromptTurn(owner);
        updates.clear();
        final replacement = manager.beginPromptTurn('aggregate-turn');
        sendChunk('agent_message_chunk', <String, dynamic>{
          'type': 'text',
          'text': 'abcd',
        });
        await pumpEventQueue();
        expect(updates.whereType<acp.MessageDelta>().single.text, 'abcd');
        manager.endPromptTurn(replacement);
      } finally {
        await subscription?.cancel();
        await manager.dispose();
        await peer.close();
        await server.cancel();
        await channel.local.sink.close();
      }
    },
  );

  test('retained rejection restores text thought and media budgets', () async {
    Future<void> runCase({
      required String sessionId,
      required acp.AcpInputBudget budget,
      required Map<String, dynamic> rejectedUpdate,
      required Map<String, dynamic> acceptedUpdate,
      required void Function(acp.MessageDelta update) verify,
    }) async {
      final channel = StreamChannelController<String>();
      final peer = JsonRpcPeer(channel.foreign);
      final manager = SessionManager(
        config: acp.AcpConfig(),
        peer: peer,
        inputBudget: budget,
      );
      final updates = <acp.AcpUpdate>[];
      final errors = <Object>[];
      final server = channel.local.stream.listen((line) {
        final request = jsonDecode(line) as Map<String, dynamic>;
        if (request['method'] != 'session/resume') return;
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': request['id'],
            'result': <String, dynamic>{},
          }),
        );
      });
      final subscription = manager
          .sessionUpdates(sessionId)
          .listen(updates.add, onError: errors.add);

      void send(Map<String, dynamic> update) {
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'method': 'session/update',
            'params': <String, dynamic>{
              'sessionId': sessionId,
              'update': update,
            },
          }),
        );
      }

      try {
        await manager.resumeSession(
          sessionId: sessionId,
          workspaceRoot: '/workspace',
        );
        final owner = manager.beginPromptTurn(sessionId);
        send(rejectedUpdate);
        await pumpEventQueue();
        expect(errors.single, isA<acp.AcpInputLimitExceeded>());
        expect(updates, isEmpty);

        send(acceptedUpdate);
        await pumpEventQueue();
        verify(updates.whereType<acp.MessageDelta>().single);
        expect(errors, hasLength(1));
        manager.endPromptTurn(owner);
      } finally {
        await subscription.cancel();
        await manager.dispose();
        await peer.close();
        await server.cancel();
        await channel.local.sink.close();
      }
    }

    for (final kind in const <String>[
      'agent_message_chunk',
      'agent_thought_chunk',
    ]) {
      await runCase(
        sessionId: 'rollback-$kind',
        budget: const acp.AcpInputBudget(
          maxMessageTextBytes: 100,
          maxThoughtTextBytes: 100,
          maxMarkdownFallbackBytes: 100,
          maxTurnRetainedBytes: 600,
        ),
        rejectedUpdate: <String, dynamic>{
          'sessionUpdate': kind,
          'content': <String, dynamic>{'type': 'text', 'text': 'x' * 100},
        },
        acceptedUpdate: <String, dynamic>{
          'sessionUpdate': kind,
          'content': <String, dynamic>{'type': 'text', 'text': 'a'},
        },
        verify: (update) => expect(update.text, 'a'),
      );
    }

    await runCase(
      sessionId: 'rollback-media',
      budget: const acp.AcpInputBudget(
        maxEmbeddedMediaBytes: 2,
        maxTurnRetainedBytes: 600,
      ),
      rejectedUpdate: <String, dynamic>{
        'sessionUpdate': 'agent_message_chunk',
        'content': <Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'image',
            'mimeType': 'image/png',
            'data': 'YQ==',
          },
          <String, dynamic>{
            'type': 'image',
            'mimeType': 'image/png',
            'data': 'YQ==',
          },
        ],
      },
      acceptedUpdate: <String, dynamic>{
        'sessionUpdate': 'agent_message_chunk',
        'content': <String, dynamic>{
          'type': 'image',
          'mimeType': 'image/png',
          'data': 'YQ==',
        },
      },
      verify: (update) =>
          expect(update.content.single, isA<acp.ImageContent>()),
    );
  });

  for (final budgetCase in const <({String name, acp.AcpInputBudget budget})>[
    (name: 'items', budget: acp.AcpInputBudget(maxTurnItems: 2)),
    (
      name: 'retained bytes',
      budget: acp.AcpInputBudget(maxTurnRetainedBytes: 220),
    ),
  ]) {
    test('turn ${budgetCase.name} enforce exact plus one and reset', () async {
      final channel = StreamChannelController<String>();
      final peer = JsonRpcPeer(channel.foreign);
      final manager = SessionManager(
        config: acp.AcpConfig(),
        peer: peer,
        inputBudget: budgetCase.budget,
      );
      final updates = <acp.AcpUpdate>[];
      final errors = <Object>[];
      final server = channel.local.stream.listen((line) {
        final request = jsonDecode(line) as Map<String, dynamic>;
        if (request['method'] != 'session/resume') return;
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': request['id'],
            'result': <String, dynamic>{},
          }),
        );
      });
      final subscription = manager
          .sessionUpdates('turn-root')
          .listen(updates.add, onError: errors.add);

      void sendMode() {
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'method': 'session/update',
            'params': <String, dynamic>{
              'sessionId': 'turn-root',
              'update': <String, dynamic>{
                'sessionUpdate': 'current_mode_update',
                'currentModeId': 'x',
              },
            },
          }),
        );
      }

      try {
        await manager.resumeSession(
          sessionId: 'turn-root',
          workspaceRoot: '/workspace',
        );
        final owner = manager.beginPromptTurn('turn-root');
        sendMode();
        sendMode();
        sendMode();
        await pumpEventQueue();
        expect(updates.whereType<acp.ModeUpdate>(), hasLength(2));
        expect(errors, hasLength(1));
        expect(errors.single, isA<acp.AcpInputLimitExceeded>());
        manager.endPromptTurn(owner);

        final replacement = manager.beginPromptTurn('turn-root');
        sendMode();
        await pumpEventQueue();
        expect(updates.whereType<acp.ModeUpdate>(), hasLength(3));
        expect(errors, hasLength(1));
        manager.endPromptTurn(replacement);
      } finally {
        await subscription.cancel();
        await manager.dispose();
        await peer.close();
        await server.cancel();
        await channel.local.sink.close();
      }
    });
  }

  test('every ordinary update family uses the owning phase guard', () async {
    final overlong = List<String>.filled(65, 'x').join();
    final cases =
        <
          ({
            String name,
            Map<String, dynamic> update,
            void Function(List<acp.AcpUpdate>, List<Object>) verify,
          })
        >[
          (
            name: 'commands',
            update: <String, dynamic>{
              'sessionUpdate': 'available_commands_update',
              'availableCommands': <Map<String, dynamic>>[
                <String, dynamic>{'name': overlong},
              ],
            },
            verify: (updates, errors) {
              final value = updates.single as acp.AvailableCommandsUpdate;
              expect(value.commands, isEmpty);
              expect(value.omission, isNotNull);
              expect(errors, isEmpty);
            },
          ),
          (
            name: 'plan',
            update: <String, dynamic>{
              'sessionUpdate': 'plan',
              'title': overlong,
              'entries': const <Object?>[],
            },
            verify: (updates, errors) {
              expect(updates, isEmpty);
              expect(errors.single, isA<acp.AcpInputLimitExceeded>());
            },
          ),
          (
            name: 'tool',
            update: <String, dynamic>{
              'sessionUpdate': 'tool_call',
              'toolCallId': overlong,
              'status': 'pending',
            },
            verify: (updates, errors) {
              expect(updates, isEmpty);
              expect(errors.single, isA<acp.AcpInputLimitExceeded>());
            },
          ),
          (
            name: 'message',
            update: <String, dynamic>{
              'sessionUpdate': 'agent_message_chunk',
              'content': <Map<String, dynamic>>[
                <String, dynamic>{'type': overlong},
              ],
            },
            verify: (updates, errors) {
              final value = updates.single as acp.MessageDelta;
              expect(value.content.single, isA<acp.UnknownContent>());
              expect(value.omissions, isNotEmpty);
              expect(errors, isEmpty);
            },
          ),
          (
            name: 'diff',
            update: <String, dynamic>{
              'sessionUpdate': 'diff',
              'id': overlong,
              'changes': const <Object?>[],
            },
            verify: (updates, errors) {
              expect(updates, isEmpty);
              expect(errors.single, isA<acp.AcpInputLimitExceeded>());
            },
          ),
          (
            name: 'mode',
            update: <String, dynamic>{
              'sessionUpdate': 'current_mode_update',
              'currentModeId': overlong,
            },
            verify: (updates, errors) {
              final value = updates.single as acp.ModeUpdate;
              expect(value.currentModeId, isEmpty);
              expect(value.omission, isNotNull);
              expect(errors, isEmpty);
            },
          ),
          (
            name: 'usage',
            update: <String, dynamic>{
              'sessionUpdate': 'usage_update',
              'used': 1,
              'size': 2,
              'cost': <String, dynamic>{'amount': 1, 'currency': overlong},
            },
            verify: (updates, errors) {
              expect(updates, isEmpty);
              expect(errors.single, isA<acp.AcpInputLimitExceeded>());
            },
          ),
          (
            name: 'unknown',
            update: <String, dynamic>{
              'sessionUpdate': 'vendor_update',
              'metadata': <String, dynamic>{'value': overlong},
            },
            verify: (updates, errors) {
              final value = updates.single as acp.UnknownUpdate;
              expect(value.raw['sessionId'], 's');
              expect(value.raw['update'], isEmpty);
              expect(value.omission, isNotNull);
              expect(errors, isEmpty);
            },
          ),
        ];

    for (final family in cases) {
      final channel = StreamChannelController<String>();
      final peer = JsonRpcPeer(channel.foreign);
      final manager = SessionManager(
        config: acp.AcpConfig(),
        peer: peer,
        inputBudget: const acp.AcpInputBudget(maxStructuredStringBytes: 64),
      );
      final updates = <acp.AcpUpdate>[];
      final errors = <Object>[];
      final server = channel.local.stream.listen((line) {
        final request = jsonDecode(line) as Map<String, dynamic>;
        if (request['method'] != 'session/resume') return;
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': request['id'],
            'result': <String, dynamic>{},
          }),
        );
      });
      StreamSubscription<acp.AcpUpdate>? subscription;
      try {
        await manager.resumeSession(
          sessionId: 's',
          workspaceRoot: '/workspace',
        );
        subscription = manager
            .sessionUpdates('s')
            .listen(updates.add, onError: errors.add);
        final owner = manager.beginPromptTurn('s');
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'method': 'session/update',
            'params': <String, dynamic>{
              'sessionId': 's',
              'update': family.update,
            },
          }),
        );
        await pumpEventQueue();
        family.verify(updates, errors);
        manager.endPromptTurn(owner);
      } finally {
        await subscription?.cancel();
        await manager.dispose();
        await peer.close();
        await server.cancel();
        await channel.local.sink.close();
      }
    }
  });

  test('tool routing id consumes the owning root exactly once', () async {
    Future<void> runCase({
      required int maxNodes,
      required bool succeeds,
    }) async {
      final channel = StreamChannelController<String>();
      final peer = JsonRpcPeer(channel.foreign);
      final manager = SessionManager(
        config: acp.AcpConfig(),
        peer: peer,
        inputBudget: acp.AcpInputBudget(maxStructuredUpdateNodes: maxNodes),
      );
      final updates = <acp.AcpUpdate>[];
      final errors = <Object>[];
      final server = channel.local.stream.listen((line) {
        final request = jsonDecode(line) as Map<String, dynamic>;
        if (request['method'] != 'session/resume') return;
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': request['id'],
            'result': <String, dynamic>{},
          }),
        );
      });
      final subscription = manager
          .sessionUpdates('tool-root')
          .listen(updates.add, onError: errors.add);

      void send(String kind, String status) {
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'method': 'session/update',
            'params': <String, dynamic>{
              'sessionId': 'tool-root',
              'update': <String, dynamic>{
                'sessionUpdate': kind,
                'toolCallId': 'x',
                'status': status,
              },
            },
          }),
        );
      }

      try {
        await manager.resumeSession(
          sessionId: 'tool-root',
          workspaceRoot: '/workspace',
        );
        var owner = manager.beginPromptTurn('tool-root');
        send('tool_call', 'pending');
        await pumpEventQueue();
        manager.endPromptTurn(owner);
        if (succeeds) {
          expect(updates.whereType<acp.ToolCallUpdate>(), hasLength(1));
          expect(errors, isEmpty);
          owner = manager.beginPromptTurn('tool-root');
          send('tool_call_update', 'completed');
          await pumpEventQueue();
          manager.endPromptTurn(owner);
          expect(updates.whereType<acp.ToolCallUpdate>(), hasLength(2));
          expect(
            updates.whereType<acp.ToolCallUpdate>().last.toolCall.status,
            acp.ToolCallStatus.completed,
          );
        } else {
          expect(updates, isEmpty);
          expect(errors.single, isA<acp.AcpInputLimitExceeded>());
        }
      } finally {
        await subscription.cancel();
        await manager.dispose();
        await peer.close();
        await server.cancel();
        await channel.local.sink.close();
      }
    }

    await runCase(maxNodes: 4, succeeds: true);
    await runCase(maxNodes: 3, succeeds: false);
  });

  test(
    'cancel error close and dispose release exact aggregate counters',
    () async {
      const budget = acp.AcpInputBudget(
        maxMessageTextBytes: 4,
        maxMarkdownFallbackBytes: 4,
      );
      final channel = StreamChannelController<String>();
      final peer = JsonRpcPeer(channel.foreign);
      final manager = SessionManager(
        config: acp.AcpConfig(),
        peer: peer,
        inputBudget: budget,
      );
      final server = channel.local.stream.listen((line) {
        final request = jsonDecode(line) as Map<String, dynamic>;
        if (request['method'] == 'session/resume' ||
            request['method'] == 'session/close') {
          channel.local.sink.add(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': request['id'],
              'result': <String, dynamic>{},
            }),
          );
        } else if (request['method'] == 'session/prompt') {
          channel.local.sink.add(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'method': 'session/update',
              'params': <String, dynamic>{
                'sessionId': 'release-counters',
                'update': <String, dynamic>{
                  'sessionUpdate': 'agent_message_chunk',
                  'content': <Map<String, dynamic>>[
                    <String, dynamic>{'type': 'text', 'text': 'abcd'},
                  ],
                },
              },
            }),
          );
          Future<void>.delayed(const Duration(milliseconds: 10), () {
            channel.local.sink.add(
              jsonEncode(<String, dynamic>{
                'jsonrpc': '2.0',
                'id': request['id'],
                'error': <String, dynamic>{
                  'code': -32000,
                  'message': 'fixed prompt failure',
                },
              }),
            );
          });
        }
      });
      var updates = <acp.AcpUpdate>[];
      StreamSubscription<acp.AcpUpdate>? subscription;

      void sendText() {
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'method': 'session/update',
            'params': <String, dynamic>{
              'sessionId': 'release-counters',
              'update': <String, dynamic>{
                'sessionUpdate': 'agent_message_chunk',
                'content': <Map<String, dynamic>>[
                  <String, dynamic>{'type': 'text', 'text': 'abcd'},
                ],
              },
            },
          }),
        );
      }

      try {
        await manager.resumeSession(
          sessionId: 'release-counters',
          workspaceRoot: '/workspace',
        );
        subscription = manager
            .sessionUpdates('release-counters')
            .listen(updates.add, onError: (_) {});

        final cancelled = manager.beginPromptTurn('release-counters');
        sendText();
        await pumpEventQueue();
        await manager.cancelPromptTurn(cancelled);
        final afterCancel = manager.beginPromptTurn('release-counters');
        sendText();
        await pumpEventQueue();
        expect(
          updates.whereType<acp.MessageDelta>().map((update) => update.text),
          <String>['abcd', 'abcd'],
        );
        manager.endPromptTurn(afterCancel);

        await expectLater(
          manager
              .prompt(
                sessionId: 'release-counters',
                content: const <Map<String, dynamic>>[],
              )
              .toList(),
          throwsA(anything),
        );
        final afterError = manager.beginPromptTurn('release-counters');
        sendText();
        await pumpEventQueue();
        expect(updates.whereType<acp.MessageDelta>().last.text, 'abcd');
        manager.endPromptTurn(afterError);

        final beforeClose = manager.beginPromptTurn('release-counters');
        sendText();
        await pumpEventQueue();
        await manager.closeSession(sessionId: 'release-counters');
        manager.endPromptTurn(beforeClose);
        await subscription.cancel();
        subscription = null;

        await manager.resumeSession(
          sessionId: 'release-counters',
          workspaceRoot: '/workspace',
        );
        updates = <acp.AcpUpdate>[];
        subscription = manager
            .sessionUpdates('release-counters')
            .listen(updates.add, onError: (_) {});
        final afterClose = manager.beginPromptTurn('release-counters');
        sendText();
        await pumpEventQueue();
        expect(updates.whereType<acp.MessageDelta>().single.text, 'abcd');
        manager.endPromptTurn(afterClose);

        final beforeDispose = manager.beginPromptTurn('release-counters');
        sendText();
        await pumpEventQueue();
        await manager.dispose();
        manager.endPromptTurn(beforeDispose);
        sendText();
        await pumpEventQueue();
        expect(
          () => manager.beginPromptTurn('release-counters'),
          throwsStateError,
        );
      } finally {
        await subscription?.cancel();
        await manager.dispose();
        await peer.close();
        await server.cancel();
        await channel.local.sink.close();
      }
    },
  );

  test(
    'session replay is item bounded and carries a truncation marker',
    () async {
      final channel = StreamChannelController<String>();
      final peer = JsonRpcPeer(channel.foreign);
      final manager = SessionManager(
        config: acp.AcpConfig(),
        peer: peer,
        maxReplayItems: 3,
        maxReplayBytes: 64 * 1024,
      );
      final server = channel.local.stream.listen((line) {
        final request = jsonDecode(line) as Map<String, dynamic>;
        if (request['method'] == 'session/resume') {
          channel.local.sink.add(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': request['id'],
              'result': <String, dynamic>{},
            }),
          );
        }
      });

      try {
        await manager.resumeSession(
          sessionId: 'bounded-replay',
          workspaceRoot: '/workspace',
        );
        final owner = manager.beginPromptTurn('bounded-replay');
        for (var index = 0; index < 5; index += 1) {
          channel.local.sink.add(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'method': 'session/update',
              'params': <String, dynamic>{
                'sessionId': 'bounded-replay',
                'update': <String, dynamic>{
                  'sessionUpdate': 'current_mode_update',
                  'currentModeId': 'mode-$index',
                },
              },
            }),
          );
        }
        await pumpEventQueue();
        manager.endPromptTurn(owner);

        final replay = await manager
            .sessionUpdates('bounded-replay')
            .take(3)
            .toList();
        expect(replay, hasLength(3));
        expect(
          (replay.first as acp.UnknownUpdate).raw['sessionUpdate'],
          'replay_truncated',
        );
        expect(
          replay.whereType<acp.ModeUpdate>().map(
            (update) => update.currentModeId,
          ),
          ['mode-3', 'mode-4'],
        );
      } finally {
        await manager.dispose();
        await peer.close();
        await server.cancel();
        await channel.local.sink.close();
      }
    },
  );

  test('session replay is UTF-8 byte bounded', () async {
    final channel = StreamChannelController<String>();
    final peer = JsonRpcPeer(channel.foreign);
    final manager = SessionManager(
      config: acp.AcpConfig(),
      peer: peer,
      maxReplayItems: 10,
      maxReplayBytes: 64,
    );
    final server = channel.local.stream.listen((line) {
      final request = jsonDecode(line) as Map<String, dynamic>;
      if (request['method'] == 'session/resume') {
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': request['id'],
            'result': <String, dynamic>{},
          }),
        );
      }
    });
    try {
      await manager.resumeSession(
        sessionId: 'byte-replay',
        workspaceRoot: '/workspace',
      );
      final owner = manager.beginPromptTurn('byte-replay');
      channel.local.sink.add(
        jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'method': 'session/update',
          'params': <String, dynamic>{
            'sessionId': 'byte-replay',
            'update': <String, dynamic>{
              'sessionUpdate': 'agent_message_chunk',
              'content': <String, dynamic>{'type': 'text', 'text': '界' * 80},
            },
          },
        }),
      );
      await pumpEventQueue();
      manager.endPromptTurn(owner);
      final replay = await manager
          .sessionUpdates('byte-replay')
          .take(1)
          .toList();
      expect((replay.single as acp.UnknownUpdate).raw['truncated'], isTrue);
    } finally {
      await manager.dispose();
      await peer.close();
      await server.cancel();
      await channel.local.sink.close();
    }
  });

  test(
    'tool state evicts completed calls before reporting a manual limit error',
    () async {
      final channel = StreamChannelController<String>();
      final peer = JsonRpcPeer(channel.foreign);
      final manager = SessionManager(
        config: acp.AcpConfig(),
        peer: peer,
        maxToolCallItems: 2,
        maxToolCallBytes: 500,
      );
      final errors = <Object>[];
      final subscription = manager
          .sessionUpdates('bounded-tools')
          .listen((_) {}, onError: errors.add);
      final server = channel.local.stream.listen((line) {
        final request = jsonDecode(line) as Map<String, dynamic>;
        if (request['method'] == 'session/resume') {
          channel.local.sink.add(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': request['id'],
              'result': <String, dynamic>{},
            }),
          );
        }
      });

      void sendTool(String id, String status) {
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'method': 'session/update',
            'params': <String, dynamic>{
              'sessionId': 'bounded-tools',
              'update': <String, dynamic>{
                'sessionUpdate': 'tool_call',
                'toolCallId': id,
                'title': id,
                'status': status,
              },
            },
          }),
        );
      }

      try {
        await manager.resumeSession(
          sessionId: 'bounded-tools',
          workspaceRoot: '/workspace',
        );
        final owner = manager.beginPromptTurn('bounded-tools');
        sendTool('active-a', 'in_progress');
        sendTool('completed', 'completed');
        sendTool('active-b', 'in_progress');
        await pumpEventQueue();
        expect(
          errors,
          isEmpty,
          reason: 'completed state should be evicted first',
        );

        sendTool('active-c', 'in_progress');
        await pumpEventQueue();
        expect(errors.single, isA<acp.SessionToolStateLimitException>());
        expect(
          errors.single.toString(),
          contains('manual intervention required'),
        );
        expect(errors.single.toString(), isNot(contains('active-c')));
        manager.endPromptTurn(owner);
      } finally {
        await subscription.cancel();
        await manager.dispose();
        await peer.close();
        await server.cancel();
        await channel.local.sink.close();
      }
    },
  );

  test(
    'tool state retains completed calls while still below its limits',
    () async {
      final channel = StreamChannelController<String>();
      final peer = JsonRpcPeer(channel.foreign);
      final manager = SessionManager(
        config: acp.AcpConfig(),
        peer: peer,
        maxToolCallItems: 3,
        maxToolCallBytes: 10000,
      );
      final updates = <acp.AcpUpdate>[];
      final errors = <Object>[];
      final server = channel.local.stream.listen((line) {
        final request = jsonDecode(line) as Map<String, dynamic>;
        if (request['method'] != 'session/resume') return;
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': request['id'],
            'result': <String, dynamic>{},
          }),
        );
      });
      final subscription = manager
          .sessionUpdates('retain-completed-tool')
          .listen(updates.add, onError: errors.add);

      void send(Map<String, dynamic> update) {
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'method': 'session/update',
            'params': <String, dynamic>{
              'sessionId': 'retain-completed-tool',
              'update': update,
            },
          }),
        );
      }

      try {
        await manager.resumeSession(
          sessionId: 'retain-completed-tool',
          workspaceRoot: '/workspace',
        );
        var owner = manager.beginPromptTurn('retain-completed-tool');
        send(<String, dynamic>{
          'sessionUpdate': 'tool_call',
          'toolCallId': 'completed-a',
          'status': 'completed',
          'title': 'Preserved A',
          'content': 'preserved content',
          'rawInput': <String, Object?>{'input': true},
          'rawOutput': <String, Object?>{'output': true},
        });
        send(<String, dynamic>{
          'sessionUpdate': 'tool_call',
          'toolCallId': 'active-b',
          'status': 'in_progress',
          'title': 'Active B',
        });
        await pumpEventQueue();
        expect(errors, isEmpty);
        manager.endPromptTurn(owner);

        updates.clear();
        owner = manager.beginPromptTurn('retain-completed-tool');
        send(<String, dynamic>{
          'sessionUpdate': 'tool_call_update',
          'toolCallId': 'completed-a',
          'status': 'in_progress',
        });
        await pumpEventQueue();
        final inherited = updates
            .whereType<acp.ToolCallUpdate>()
            .single
            .toolCall;
        expect(inherited.title, 'Preserved A');
        expect(inherited.content, [containsPair('text', 'preserved content')]);
        expect(inherited.rawInput, <String, Object?>{'input': true});
        expect(inherited.rawOutput, <String, Object?>{'output': true});
        expect(errors, isEmpty);
        manager.endPromptTurn(owner);
      } finally {
        await subscription.cancel();
        await manager.dispose();
        await peer.close();
        await server.cancel();
        await channel.local.sink.close();
      }
    },
  );

  test('tool store rejection does not consume the owning phase', () async {
    final channel = StreamChannelController<String>();
    final peer = JsonRpcPeer(channel.foreign);
    final manager = SessionManager(
      config: acp.AcpConfig(),
      peer: peer,
      inputBudget: const acp.AcpInputBudget(maxTurnItems: 1),
      maxToolCallItems: 1,
    );
    final updates = <acp.AcpUpdate>[];
    final errors = <Object>[];
    final server = channel.local.stream.listen((line) {
      final request = jsonDecode(line) as Map<String, dynamic>;
      if (request['method'] != 'session/resume') return;
      channel.local.sink.add(
        jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': request['id'],
          'result': <String, dynamic>{},
        }),
      );
    });
    final subscription = manager
        .sessionUpdates('atomic-tool-store')
        .listen(updates.add, onError: errors.add);

    void send(Map<String, dynamic> update) {
      channel.local.sink.add(
        jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'method': 'session/update',
          'params': <String, dynamic>{
            'sessionId': 'atomic-tool-store',
            'update': update,
          },
        }),
      );
    }

    try {
      await manager.resumeSession(
        sessionId: 'atomic-tool-store',
        workspaceRoot: '/workspace',
      );
      var owner = manager.beginPromptTurn('atomic-tool-store');
      send(<String, dynamic>{
        'sessionUpdate': 'tool_call',
        'toolCallId': 'active-a',
        'status': 'in_progress',
      });
      await pumpEventQueue();
      manager.endPromptTurn(owner);
      updates.clear();

      owner = manager.beginPromptTurn('atomic-tool-store');
      send(<String, dynamic>{
        'sessionUpdate': 'tool_call',
        'toolCallId': 'active-b',
        'status': 'in_progress',
      });
      await pumpEventQueue();
      expect(errors.single, isA<acp.SessionToolStateLimitException>());

      send(<String, dynamic>{
        'sessionUpdate': 'current_mode_update',
        'currentModeId': 'accepted',
      });
      await pumpEventQueue();
      expect(
        updates.whereType<acp.ModeUpdate>().single.currentModeId,
        'accepted',
      );
      expect(errors, hasLength(1));
      manager.endPromptTurn(owner);
    } finally {
      await subscription.cancel();
      await manager.dispose();
      await peer.close();
      await server.cancel();
      await channel.local.sink.close();
    }
  });

  test('tool estimator failure preserves the previous tool state', () async {
    final channel = StreamChannelController<String>();
    final peer = JsonRpcPeer(channel.foreign);
    final manager = SessionManager(
      config: acp.AcpConfig(),
      peer: peer,
      inputBudget: const acp.AcpInputBudget(maxMetadataNodes: 5),
    );
    final updates = <acp.AcpUpdate>[];
    final errors = <Object>[];
    final server = channel.local.stream.listen((line) {
      final request = jsonDecode(line) as Map<String, dynamic>;
      if (request['method'] != 'session/resume') return;
      channel.local.sink.add(
        jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': request['id'],
          'result': <String, dynamic>{},
        }),
      );
    });
    final subscription = manager
        .sessionUpdates('atomic-tool-estimator')
        .listen(updates.add, onError: errors.add);

    void send(Map<String, dynamic> update) {
      channel.local.sink.add(
        jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'method': 'session/update',
          'params': <String, dynamic>{
            'sessionId': 'atomic-tool-estimator',
            'update': update,
          },
        }),
      );
    }

    try {
      await manager.resumeSession(
        sessionId: 'atomic-tool-estimator',
        workspaceRoot: '/workspace',
      );
      var owner = manager.beginPromptTurn('atomic-tool-estimator');
      send(<String, dynamic>{
        'sessionUpdate': 'tool_call',
        'toolCallId': 'stable',
        'status': 'in_progress',
        'title': 'preserved',
      });
      await pumpEventQueue();
      manager.endPromptTurn(owner);

      owner = manager.beginPromptTurn('atomic-tool-estimator');
      send(<String, dynamic>{
        'sessionUpdate': 'tool_call_update',
        'toolCallId': 'stable',
        'rawInput': 'a',
        'rawOutput': 'b',
      });
      await pumpEventQueue();
      expect(errors.single, isA<acp.AcpInputLimitExceeded>());
      manager.endPromptTurn(owner);

      updates.clear();
      owner = manager.beginPromptTurn('atomic-tool-estimator');
      send(<String, dynamic>{
        'sessionUpdate': 'tool_call_update',
        'toolCallId': 'stable',
        'status': 'completed',
      });
      await pumpEventQueue();
      final completed = updates.whereType<acp.ToolCallUpdate>().single.toolCall;
      expect(completed.title, 'preserved');
      expect(completed.status, acp.ToolCallStatus.completed);
      manager.endPromptTurn(owner);
    } finally {
      await subscription.cancel();
      await manager.dispose();
      await peer.close();
      await server.cancel();
      await channel.local.sink.close();
    }
  });

  test('omitted tool state counts omission bytes at exact limits', () async {
    final rawTool = <String, dynamic>{
      'toolCallId': 'omitted-tool',
      'status': 'in_progress',
      'locations': 42,
    };
    final omittedTool = acp.ToolCall.fromJson(rawTool);
    expect(
      omittedTool.omission?.reason,
      acp.AcpInputOmissionReason.invalidStructure,
    );
    final retainedProjection = <String, Object?>{
      'toolCallId': omittedTool.toolCallId,
      'status': omittedTool.status.toWire(),
      'omission': omittedTool.omission!.toJson(),
    };
    final exactBytes = acp.AcpRetainedSizeEstimator(
      budget: const acp.AcpInputBudget(),
    ).estimate(retainedProjection);

    Future<void> runCase({
      required String name,
      required int maxToolCallBytes,
      required int maxTurnRetainedBytes,
      required bool succeeds,
      required Type rejectedType,
    }) async {
      final channel = StreamChannelController<String>();
      final peer = JsonRpcPeer(channel.foreign);
      final manager = SessionManager(
        config: acp.AcpConfig(),
        peer: peer,
        maxToolCallBytes: maxToolCallBytes,
        inputBudget: acp.AcpInputBudget(
          maxTurnRetainedBytes: maxTurnRetainedBytes,
        ),
      );
      final updates = <acp.AcpUpdate>[];
      final errors = <Object>[];
      final server = channel.local.stream.listen((line) {
        final request = jsonDecode(line) as Map<String, dynamic>;
        if (request['method'] != 'session/resume') return;
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': request['id'],
            'result': <String, dynamic>{},
          }),
        );
      });
      final subscription = manager
          .sessionUpdates(name)
          .listen(updates.add, onError: errors.add);
      try {
        await manager.resumeSession(
          sessionId: name,
          workspaceRoot: '/workspace',
        );
        final owner = manager.beginPromptTurn(name);
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'method': 'session/update',
            'params': <String, dynamic>{
              'sessionId': name,
              'update': <String, dynamic>{
                'sessionUpdate': 'tool_call',
                ...rawTool,
              },
            },
          }),
        );
        await pumpEventQueue();
        if (succeeds) {
          expect(errors, isEmpty);
          final update = updates.whereType<acp.ToolCallUpdate>().single;
          expect(update.toolCall.omission, isNotNull);
        } else {
          expect(updates, isEmpty);
          expect(errors.single.runtimeType, rejectedType);
        }
        manager.endPromptTurn(owner);
      } finally {
        await subscription.cancel();
        await manager.dispose();
        await peer.close();
        await server.cancel();
        await channel.local.sink.close();
      }
    }

    await runCase(
      name: 'tool-store-omission-exact',
      maxToolCallBytes: exactBytes,
      maxTurnRetainedBytes: 1024 * 1024,
      succeeds: true,
      rejectedType: acp.SessionToolStateLimitException,
    );
    await runCase(
      name: 'tool-store-omission-plus-one',
      maxToolCallBytes: exactBytes - 1,
      maxTurnRetainedBytes: 1024 * 1024,
      succeeds: false,
      rejectedType: acp.SessionToolStateLimitException,
    );
    await runCase(
      name: 'turn-retained-omission-exact',
      maxToolCallBytes: 1024 * 1024,
      maxTurnRetainedBytes: exactBytes,
      succeeds: true,
      rejectedType: acp.AcpInputLimitExceeded,
    );
    await runCase(
      name: 'turn-retained-omission-plus-one',
      maxToolCallBytes: 1024 * 1024,
      maxTurnRetainedBytes: exactBytes - 1,
      succeeds: false,
      rejectedType: acp.AcpInputLimitExceeded,
    );
  });

  test(
    'session manager close drops later updates and cleans state on RPC failure',
    () async {
      final channel = StreamChannelController<String>();
      final peer = JsonRpcPeer(channel.foreign);
      final manager = SessionManager(config: acp.AcpConfig(), peer: peer);
      final server = channel.local.stream.listen((line) {
        final request = jsonDecode(line) as Map<String, dynamic>;
        final method = request['method'];
        if (method == 'session/resume') {
          channel.local.sink.add(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': request['id'],
              'result': <String, dynamic>{},
            }),
          );
        } else if (method == 'session/close') {
          channel.local.sink.add(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': request['id'],
              'error': <String, dynamic>{'code': -32000, 'message': 'failed'},
            }),
          );
        }
      });

      try {
        await manager.resumeSession(
          sessionId: 'close-state',
          workspaceRoot: '/workspace',
        );
        await expectLater(
          manager.closeSession(sessionId: 'close-state'),
          throwsA(
            isA<rpc.RpcException>()
                .having((error) => error.code, 'code', -32000)
                .having((error) => error.message, 'message', 'failed'),
          ),
        );
        expect(manager.localSessionStateKeysForTesting('close-state'), isEmpty);
        expect(manager.sessionGenerationForTesting('close-state'), isNull);
        expect(manager.sessionCloseSelectionCountForTesting('close-state'), 0);
        expect(manager.terminalLeaseCountForTesting, 0);
        expect(manager.managedTerminalCountForTesting, 0);
        expect(() => manager.getWorkspaceRoot('close-state'), throwsStateError);
        expect(manager.sessionModes('close-state'), isNull);

        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'method': 'session/update',
            'params': <String, dynamic>{
              'sessionId': 'close-state',
              'update': <String, dynamic>{
                'sessionUpdate': 'current_mode_update',
                'currentModeId': 'must-drop',
              },
            },
          }),
        );
        await pumpEventQueue();
        expect(manager.sessionModes('close-state'), isNull);
      } finally {
        await manager.dispose();
        await peer.close();
        await server.cancel();
        await channel.local.sink.close();
      }
    },
  );

  group('terminal handle manager admission', () {
    test('terminal handle limits reject invalid manager configuration', () {
      final channel = StreamChannelController<String>();
      final peer = JsonRpcPeer(channel.foreign);

      expect(
        () => SessionManager(
          config: acp.AcpConfig(),
          peer: peer,
          maxTerminalHandles: 0,
        ),
        throwsArgumentError,
      );
      expect(peer.onTerminalCreate, isNull);
      expect(
        () => SessionManager(
          config: acp.AcpConfig(),
          peer: peer,
          maxTerminalHandlesPerSession: 0,
        ),
        throwsArgumentError,
      );
      expect(peer.onTerminalCreate, isNull);
      expect(
        () => SessionManager(
          config: acp.AcpConfig(),
          peer: peer,
          maxTerminalHandles: 1,
          maxTerminalHandlesPerSession: 2,
        ),
        throwsArgumentError,
      );
      expect(peer.onTerminalCreate, isNull);
      expect(peer.onReadTextFile, isNull);
      expect(peer.onRequestPermission, isNull);
      unawaited(peer.close());
      unawaited(channel.local.sink.close());
    });

    test(
      'terminal handle quota enforces per session and global boundaries',
      () async {
        var permissionCalls = 0;
        final provider = _RecordingTerminalProvider();
        final harness = _TerminalAdmissionHarness(
          provider: provider,
          permissionProvider: acp.DefaultPermissionProvider(
            onRequest: (_) async {
              permissionCalls += 1;
              return const acp.PermissionDecision.allow();
            },
          ),
          maxTerminalHandles: 2,
          maxTerminalHandlesPerSession: 1,
        );
        final logs = <String>[];
        final logSubscription = harness.manager.config.logger.onRecord.listen(
          (record) => logs.add(record.message),
        );

        try {
          await harness.resume('session-a');
          await harness.resume('session-b');
          await harness.resume('session-c');
          final first = await harness.createTerminal(
            id: 'terminal-handle-first',
            sessionId: 'session-a',
          );
          expect(first, contains('result'));
          final sessionOverflow = await harness.createTerminal(
            id: 'terminal-handle-session-overflow',
            sessionId: 'session-a',
            command: 'session-command-canary',
            envValue: 'session-env-canary',
          );
          _expectTerminalHandleLimit(sessionOverflow);
          final second = await harness.createTerminal(
            id: 'terminal-handle-second',
            sessionId: 'session-b',
          );
          expect(second, contains('result'));
          final globalOverflow = await harness.createTerminal(
            id: 'terminal-handle-global-overflow',
            sessionId: 'session-c',
            command: 'global-command-canary',
            envValue: 'global-env-canary',
          );
          _expectTerminalHandleLimit(globalOverflow);
          expect(provider.createCalls, 2);
          expect(permissionCalls, 2);
          final joinedLogs = logs.join('\n');
          expect(joinedLogs, isNot(contains('session-command-canary')));
          expect(joinedLogs, isNot(contains('session-env-canary')));
          expect(joinedLogs, isNot(contains('global-command-canary')));
          expect(joinedLogs, isNot(contains('global-env-canary')));
        } finally {
          await logSubscription.cancel();
          await harness.dispose();
        }
      },
    );

    test(
      'terminal handle quota is reserved before requesting permission',
      () async {
        final permissionBarrier = Completer<acp.PermissionDecision>();
        final permissionStarted = Completer<void>();
        var permissionCalls = 0;
        final provider = _RecordingTerminalProvider();
        final harness = _TerminalAdmissionHarness(
          provider: provider,
          permissionProvider: acp.DefaultPermissionProvider(
            onRequest: (_) {
              permissionCalls += 1;
              if (!permissionStarted.isCompleted) permissionStarted.complete();
              return permissionBarrier.future;
            },
          ),
          maxTerminalHandles: 1,
          maxTerminalHandlesPerSession: 1,
        );

        try {
          await harness.resume('session-a');
          final first = harness.createTerminal(
            id: 'terminal-handle-permission-pending',
            sessionId: 'session-a',
          );
          await permissionStarted.future.timeout(const Duration(seconds: 5));
          final overflow = await harness.createTerminal(
            id: 'terminal-handle-permission-overflow',
            sessionId: 'session-a',
          );
          _expectTerminalHandleLimit(overflow);
          expect(permissionCalls, 1);
          expect(provider.createCalls, 0);

          permissionBarrier.complete(const acp.PermissionDecision.allow());
          expect(await first, contains('result'));
        } finally {
          if (!permissionBarrier.isCompleted) {
            permissionBarrier.complete(const acp.PermissionDecision.deny());
          }
          await harness.dispose();
        }
      },
    );

    test(
      'terminal handle quota counts provider creates that are pending',
      () async {
        final firstBarrier = Completer<void>();
        final secondBarrier = Completer<void>();
        final provider = _RecordingTerminalProvider(
          createBarriers: <int, Completer<void>>{
            1: firstBarrier,
            2: secondBarrier,
          },
        );
        final harness = _TerminalAdmissionHarness(
          provider: provider,
          permissionProvider: acp.DefaultPermissionProvider(
            onRequest: (_) async => const acp.PermissionDecision.allow(),
          ),
          maxTerminalHandles: 2,
          maxTerminalHandlesPerSession: 2,
        );

        try {
          await harness.resume('session-a');
          await harness.resume('session-b');
          await harness.resume('session-c');
          final first = harness.createTerminal(
            id: 'terminal-handle-provider-first',
            sessionId: 'session-a',
          );
          final second = harness.createTerminal(
            id: 'terminal-handle-provider-second',
            sessionId: 'session-b',
          );
          await _waitForTerminalTestCondition(() => provider.createCalls == 2);
          final overflow = await harness.createTerminal(
            id: 'terminal-handle-provider-overflow',
            sessionId: 'session-c',
          );
          _expectTerminalHandleLimit(overflow);
          expect(provider.createCalls, 2);

          firstBarrier.complete();
          secondBarrier.complete();
          expect(await first, contains('result'));
          expect(await second, contains('result'));
        } finally {
          if (!firstBarrier.isCompleted) firstBarrier.complete();
          if (!secondBarrier.isCompleted) secondBarrier.complete();
          await harness.dispose();
        }
      },
    );

    test(
      'terminal handle permission and create failures roll back quota',
      () async {
        var permissionCall = 0;
        final provider = _RecordingTerminalProvider(
          failCreateCalls: const <int>{1},
        );
        final harness = _TerminalAdmissionHarness(
          provider: provider,
          permissionProvider: acp.DefaultPermissionProvider(
            onRequest: (_) async {
              permissionCall += 1;
              return switch (permissionCall) {
                1 => const acp.PermissionDecision.deny(),
                2 => const acp.PermissionDecision.cancelled(),
                3 => throw StateError('permission-provider-canary'),
                _ => const acp.PermissionDecision.allow(),
              };
            },
          ),
          maxTerminalHandles: 1,
          maxTerminalHandlesPerSession: 1,
        );

        try {
          await harness.resume('session-a');
          for (var attempt = 1; attempt <= 4; attempt += 1) {
            final response = await harness.createTerminal(
              id: 'terminal-handle-rollback-$attempt',
              sessionId: 'session-a',
            );
            expect(response, contains('error'));
          }
          final retried = await harness.createTerminal(
            id: 'terminal-handle-rollback-retried',
            sessionId: 'session-a',
          );
          expect(retried, contains('result'));
          expect(permissionCall, 5);
          expect(provider.createCalls, 2);
        } finally {
          await harness.dispose();
        }
      },
    );

    test(
      'terminal handle provider quota error is payload free and reusable',
      () async {
        final provider = _RecordingTerminalProvider(
          failLimitCalls: const <int>{2},
        );
        final harness = _TerminalAdmissionHarness(
          provider: provider,
          permissionProvider: acp.DefaultPermissionProvider(
            onRequest: (_) async => const acp.PermissionDecision.allow(),
          ),
          maxTerminalHandles: 2,
          maxTerminalHandlesPerSession: 2,
        );

        try {
          await harness.resume('provider-limit-session-canary');
          final first = await harness.createTerminal(
            id: 'terminal-handle-provider-limit-first',
            sessionId: 'provider-limit-session-canary',
          );
          expect(first, contains('result'));

          final rejected = await harness.createTerminal(
            id: 'terminal-handle-provider-limit-rejected',
            sessionId: 'provider-limit-session-canary',
            command: 'provider-limit-command-canary',
            envValue: 'provider-limit-env-canary',
          );
          expect(rejected['error'], <String, dynamic>{
            'code': -32001,
            'message': 'Terminal handle limit exceeded.',
          });
          final serialized = rejected.toString();
          expect(serialized, isNot(contains('data')));
          expect(serialized, isNot(contains('provider-limit-session-canary')));
          expect(serialized, isNot(contains('provider-limit-command-canary')));
          expect(serialized, isNot(contains('provider-limit-env-canary')));

          final retried = await harness.createTerminal(
            id: 'terminal-handle-provider-limit-retried',
            sessionId: 'provider-limit-session-canary',
          );
          expect(retried, contains('result'));
          expect(provider.createCalls, 3);
        } finally {
          await harness.dispose();
        }
      },
    );

    test('terminal handle close revokes a permission pending lease', () async {
      final firstPermission = Completer<acp.PermissionDecision>();
      final permissionStarted = Completer<void>();
      var permissionCalls = 0;
      final provider = _RecordingTerminalProvider();
      final harness = _TerminalAdmissionHarness(
        provider: provider,
        permissionProvider: acp.DefaultPermissionProvider(
          onRequest: (_) {
            permissionCalls += 1;
            if (permissionCalls == 1) {
              permissionStarted.complete();
              return firstPermission.future;
            }
            return Future<acp.PermissionDecision>.value(
              const acp.PermissionDecision.allow(),
            );
          },
        ),
        maxTerminalHandles: 1,
        maxTerminalHandlesPerSession: 1,
      );

      try {
        await harness.resume('session-a');
        await harness.resume('session-b');
        final late = harness.createTerminal(
          id: 'terminal-handle-permission-late',
          sessionId: 'session-a',
        );
        await permissionStarted.future.timeout(const Duration(seconds: 5));
        await harness.manager.closeSession(sessionId: 'session-a');
        final replacement = await harness.createTerminal(
          id: 'terminal-handle-permission-replacement',
          sessionId: 'session-b',
        );
        expect(replacement, contains('result'));

        firstPermission.complete(const acp.PermissionDecision.allow());
        final lateResponse = await late;
        expect(lateResponse['error'], <String, dynamic>{
          'code': -32003,
          'message': 'Permission request cancelled.',
        });
        expect(provider.createCalls, 1);
      } finally {
        if (!firstPermission.isCompleted) {
          firstPermission.complete(const acp.PermissionDecision.deny());
        }
        await harness.dispose();
      }
    });

    test(
      'terminal handle close releases a creating lease before late cleanup',
      () async {
        final createBarrier = Completer<void>();
        final provider = _RecordingTerminalProvider(
          createBarriers: <int, Completer<void>>{1: createBarrier},
        );
        final harness = _TerminalAdmissionHarness(
          provider: provider,
          permissionProvider: acp.DefaultPermissionProvider(
            onRequest: (_) async => const acp.PermissionDecision.allow(),
          ),
          maxTerminalHandles: 1,
          maxTerminalHandlesPerSession: 1,
        );

        try {
          await harness.resume('session-a');
          await harness.resume('session-b');
          final late = harness.createTerminal(
            id: 'terminal-handle-create-late',
            sessionId: 'session-a',
          );
          await _waitForTerminalTestCondition(() => provider.createCalls == 1);
          await harness.manager.closeSession(sessionId: 'session-a');
          final replacement = await harness.createTerminal(
            id: 'terminal-handle-create-replacement',
            sessionId: 'session-b',
          );
          expect(replacement, contains('result'));
          expect(provider.createCalls, 2);

          createBarrier.complete();
          final lateResponse = await late;
          expect(lateResponse['error'], <String, dynamic>{
            'code': -32003,
            'message': 'Permission request cancelled.',
          });
          await _waitForTerminalTestCondition(
            () => provider.releaseAttempts.length == 1,
          );
          expect(provider.releaseAttempts, ['terminal-1']);
        } finally {
          if (!createBarrier.isCompleted) createBarrier.complete();
          await harness.dispose();
        }
      },
    );

    test(
      'terminal handle duplicate id releases new ownership without overwrite',
      () async {
        final provider = _RecordingTerminalProvider(
          terminalIdsByCall: const <int, String>{
            1: 'duplicate-terminal',
            2: 'duplicate-terminal',
          },
        );
        final harness = _TerminalAdmissionHarness(
          provider: provider,
          permissionProvider: acp.DefaultPermissionProvider(
            onRequest: (_) async => const acp.PermissionDecision.allow(),
          ),
          maxTerminalHandles: 2,
          maxTerminalHandlesPerSession: 1,
        );

        try {
          await harness.resume('session-a');
          await harness.resume('session-b');
          final original = await harness.createTerminal(
            id: 'terminal-handle-duplicate-original',
            sessionId: 'session-a',
          );
          expect(original, contains('result'));
          final duplicate = await harness.createTerminal(
            id: 'terminal-handle-duplicate-new',
            sessionId: 'session-b',
          );
          expect(duplicate, contains('error'));
          expect(duplicate.toString(), contains('duplicate terminalId'));
          expect(provider.releaseAttempts, ['duplicate-terminal']);
          expect(provider.releaseHandles, hasLength(1));
          expect(
            provider.releaseHandles.single,
            same(provider.createdHandles[1]),
          );

          await harness.manager.releaseTerminal('duplicate-terminal');
          expect(provider.releaseAttempts, <String>[
            'duplicate-terminal',
            'duplicate-terminal',
          ]);
          expect(provider.releaseHandles, hasLength(2));
          expect(provider.releaseHandles[1], same(provider.createdHandles[0]));
        } finally {
          await harness.dispose();
        }
      },
    );

    test(
      'terminal handle rpc release is idempotent and immediately reusable',
      () async {
        final provider = _RecordingTerminalProvider();
        final harness = _TerminalAdmissionHarness(
          provider: provider,
          permissionProvider: acp.DefaultPermissionProvider(
            onRequest: (_) async => const acp.PermissionDecision.allow(),
          ),
          maxTerminalHandles: 1,
          maxTerminalHandlesPerSession: 1,
        );
        final releasedIds = <String>[];
        final events = harness.manager.terminalEvents.listen((event) {
          if (event is acp.TerminalReleased) {
            releasedIds.add(event.terminalId);
          }
        });

        try {
          await harness.resume('session-a');
          final first = await harness.createTerminal(
            id: 'terminal-handle-rpc-release-first',
            sessionId: 'session-a',
          );
          final terminalId =
              (first['result'] as Map<String, dynamic>)['terminalId'] as String;

          expect(
            await harness.releaseTerminal(
              id: 'terminal-handle-rpc-release-once',
              terminalId: terminalId,
            ),
            contains('result'),
          );
          expect(
            await harness.createTerminal(
              id: 'terminal-handle-rpc-release-replacement',
              sessionId: 'session-a',
            ),
            contains('result'),
          );
          expect(
            await harness.releaseTerminal(
              id: 'terminal-handle-rpc-release-repeat',
              terminalId: terminalId,
            ),
            contains('result'),
          );
          expect(
            await harness.releaseTerminal(
              id: 'terminal-handle-rpc-release-unknown',
              terminalId: 'unknown-terminal',
            ),
            contains('result'),
          );
          await Future<void>.delayed(Duration.zero);

          expect(provider.releaseAttempts, ['terminal-1']);
          expect(releasedIds, ['terminal-1']);
        } finally {
          await events.cancel();
          await harness.dispose();
        }
      },
    );

    test(
      'terminal handle concurrent rpc public and close release owns handle once',
      () async {
        final releaseBarrier = Completer<void>();
        final releaseStarted = Completer<void>();
        final provider = _RecordingTerminalProvider(
          releaseBarrier: releaseBarrier,
          releaseStarted: releaseStarted,
        );
        final harness = _TerminalAdmissionHarness(
          provider: provider,
          permissionProvider: acp.DefaultPermissionProvider(
            onRequest: (_) async => const acp.PermissionDecision.allow(),
          ),
          maxTerminalHandles: 1,
          maxTerminalHandlesPerSession: 1,
        );

        try {
          await harness.resume('session-a');
          final created = await harness.createTerminal(
            id: 'terminal-handle-concurrent-release-create',
            sessionId: 'session-a',
          );
          final terminalId =
              (created['result'] as Map<String, dynamic>)['terminalId']
                  as String;
          final rpcRelease = harness.releaseTerminal(
            id: 'terminal-handle-concurrent-release-rpc',
            terminalId: terminalId,
          );
          await releaseStarted.future.timeout(const Duration(seconds: 5));

          final publicRelease = harness.manager.releaseTerminal(terminalId);
          final close = harness.manager.closeSession(sessionId: 'session-a');
          await Future.wait<void>([publicRelease, close]);
          expect(provider.releaseAttempts, [terminalId]);

          releaseBarrier.complete();
          expect(await rpcRelease, contains('result'));
          expect(provider.releaseAttempts, [terminalId]);
          expect(
            provider.releaseHandles.single,
            same(provider.createdHandles.single),
          );
        } finally {
          if (!releaseBarrier.isCompleted) releaseBarrier.complete();
          await harness.dispose();
        }
      },
    );

    test(
      'terminal handle dispose waits for an rpc owned release before events close',
      () async {
        const requestCanary = 'release-dispose-request-canary';
        final releaseBarrier = Completer<void>();
        final releaseStarted = Completer<void>();
        final provider = _RecordingTerminalProvider(
          releaseBarrier: releaseBarrier,
          releaseStarted: releaseStarted,
        );
        final harness = _TerminalAdmissionHarness(
          provider: provider,
          permissionProvider: acp.DefaultPermissionProvider(
            onRequest: (_) async => const acp.PermissionDecision.allow(),
          ),
          maxTerminalHandles: 1,
          maxTerminalHandlesPerSession: 1,
        );
        final releasedIds = <String>[];
        final events = harness.manager.terminalEvents.listen((event) {
          if (event is acp.TerminalReleased) {
            releasedIds.add(event.terminalId);
          }
        });
        var disposeCompleted = false;

        try {
          await harness.resume('session-a');
          final created = await harness.createTerminal(
            id: 'terminal-handle-dispose-release-create',
            sessionId: 'session-a',
          );
          final terminalId =
              (created['result'] as Map<String, dynamic>)['terminalId']
                  as String;
          final rpcRelease = harness.releaseTerminal(
            id: 'terminal-handle-dispose-release-rpc',
            terminalId: terminalId,
            canary: requestCanary,
          );
          await releaseStarted.future.timeout(const Duration(seconds: 5));

          final dispose = harness.manager.dispose().then((_) {
            disposeCompleted = true;
          });
          await pumpEventQueue();
          final disposeWaitedForRelease = !disposeCompleted;

          releaseBarrier.complete();
          final response = await rpcRelease;
          await dispose.timeout(const Duration(seconds: 5));
          await Future<void>.delayed(Duration.zero);

          expect(disposeWaitedForRelease, isTrue);
          expect(response, contains('result'));
          expect(response, isNot(contains('error')));
          expect(response.toString(), isNot(contains('data')));
          expect(response.toString(), isNot(contains(requestCanary)));
          expect(provider.releaseAttempts, [terminalId]);
          expect(releasedIds, [terminalId]);
          expect(disposeCompleted, isTrue);
        } finally {
          if (!releaseBarrier.isCompleted) releaseBarrier.complete();
          await events.cancel();
          await harness.dispose();
        }
      },
    );

    test(
      'terminal handle release failure still returns manager quota',
      () async {
        final provider = _RecordingTerminalProvider(
          failReleaseIds: const <String>{'terminal-1'},
        );
        final harness = _TerminalAdmissionHarness(
          provider: provider,
          permissionProvider: acp.DefaultPermissionProvider(
            onRequest: (_) async => const acp.PermissionDecision.allow(),
          ),
          maxTerminalHandles: 1,
          maxTerminalHandlesPerSession: 1,
        );

        try {
          await harness.resume('session-a');
          final first = await harness.createTerminal(
            id: 'terminal-handle-release-first',
            sessionId: 'session-a',
          );
          final terminalId =
              (first['result'] as Map<String, dynamic>)['terminalId'] as String;
          await expectLater(
            harness.manager.releaseTerminal(terminalId),
            throwsStateError,
          );
          final replacement = await harness.createTerminal(
            id: 'terminal-handle-release-replacement',
            sessionId: 'session-a',
          );
          expect(replacement, contains('result'));
          expect(provider.createCalls, 2);
        } finally {
          await harness.dispose();
        }
      },
    );

    test(
      'terminal handle rpc release failure is payload free and reusable',
      () async {
        const providerSecret = 'rpc-release-provider-secret';
        const requestCanary = 'rpc-release-request-canary';
        const terminalIdCanary = 'rpc-release-terminal-canary';
        final provider = _RecordingTerminalProvider(
          failReleaseIds: const <String>{terminalIdCanary},
          releaseErrorMessage: providerSecret,
          terminalIdsByCall: const <int, String>{1: terminalIdCanary},
        );
        final harness = _TerminalAdmissionHarness(
          provider: provider,
          permissionProvider: acp.DefaultPermissionProvider(
            onRequest: (_) async => const acp.PermissionDecision.allow(),
          ),
          maxTerminalHandles: 1,
          maxTerminalHandlesPerSession: 1,
        );
        final releasedIds = <String>[];
        final events = harness.manager.terminalEvents.listen((event) {
          if (event is acp.TerminalReleased) {
            releasedIds.add(event.terminalId);
          }
        });

        try {
          await harness.resume('session-a');
          final first = await harness.createTerminal(
            id: 'terminal-handle-rpc-release-failure-first',
            sessionId: 'session-a',
          );
          final terminalId =
              (first['result'] as Map<String, dynamic>)['terminalId'] as String;
          final failed = await harness.releaseTerminal(
            id: 'terminal-handle-rpc-release-failure',
            terminalId: terminalId,
            canary: requestCanary,
          );

          expect(failed['error'], <String, dynamic>{
            'code': -32000,
            'message': 'Terminal release failed.',
          });
          final serialized = failed.toString();
          expect(serialized, isNot(contains('data')));
          expect(serialized, isNot(contains(providerSecret)));
          expect(serialized, isNot(contains(requestCanary)));
          expect(serialized, isNot(contains(terminalIdCanary)));
          await Future<void>.delayed(Duration.zero);
          expect(releasedIds, [terminalIdCanary]);

          expect(
            await harness.releaseTerminal(
              id: 'terminal-handle-rpc-release-failure-repeat',
              terminalId: terminalId,
              canary: requestCanary,
            ),
            contains('result'),
          );
          await Future<void>.delayed(Duration.zero);
          expect(releasedIds, [terminalIdCanary]);
          expect(
            await harness.createTerminal(
              id: 'terminal-handle-rpc-release-after-failure',
              sessionId: 'session-a',
            ),
            contains('result'),
          );
          expect(provider.releaseAttempts, [terminalIdCanary]);
        } finally {
          await events.cancel();
          await harness.dispose();
        }
      },
    );

    test(
      'terminal handle dispose releases a late create before returning quota',
      () async {
        const providerSecret = 'late-dispose-provider-secret';
        final createBarrier = Completer<void>();
        final provider = _RecordingTerminalProvider(
          createBarriers: <int, Completer<void>>{1: createBarrier},
          failReleaseIds: const <String>{'terminal-1'},
          releaseErrorMessage: providerSecret,
        );
        final harness = _TerminalAdmissionHarness(
          provider: provider,
          permissionProvider: acp.DefaultPermissionProvider(
            onRequest: (_) async => const acp.PermissionDecision.allow(),
          ),
          maxTerminalHandles: 1,
          maxTerminalHandlesPerSession: 1,
        );
        final logs = <String>[];
        final logSubscription = harness.manager.config.logger.onRecord.listen(
          (record) => logs.add(record.message),
        );

        try {
          await harness.resume('session-a');
          final late = harness.createTerminal(
            id: 'terminal-handle-dispose-late',
            sessionId: 'session-a',
          );
          await _waitForTerminalTestCondition(() => provider.createCalls == 1);
          await harness.manager.dispose();
          createBarrier.complete();

          final lateResponse = await late;
          expect(lateResponse['error'], <String, dynamic>{
            'code': -32000,
            'message': 'ACP connection closed.',
          });
          expect(lateResponse.toString(), isNot(contains(providerSecret)));
          await _waitForTerminalTestCondition(
            () => provider.releaseAttempts.length == 1,
          );
          expect(provider.releaseAttempts, ['terminal-1']);
          expect(logs.join('\n'), isNot(contains(providerSecret)));
          expect(
            await harness.manager.readTerminalOutput('terminal-1'),
            isEmpty,
          );
        } finally {
          if (!createBarrier.isCompleted) createBarrier.complete();
          await logSubscription.cancel();
          await harness.dispose();
        }
      },
    );
  });

  test(
    'close releases only owned terminals and aggregates cleanup failures',
    () async {
      final channel = StreamChannelController<String>();
      final peer = JsonRpcPeer(channel.foreign);
      final provider = _RecordingTerminalProvider(
        failReleaseIds: {'terminal-1'},
      );
      final manager = SessionManager(
        config: acp.AcpConfig(
          terminalProvider: provider,
          permissionProvider: acp.DefaultPermissionProvider(
            onRequest: (_) async => const acp.PermissionDecision.allow(),
          ),
        ),
        peer: peer,
      );
      final terminalResponses = <String, Completer<void>>{};
      final server = channel.local.stream.listen((line) {
        final message = jsonDecode(line) as Map<String, dynamic>;
        final method = message['method'];
        if (method == 'session/resume' || method == 'session/close') {
          channel.local.sink.add(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': message['id'],
              'result': <String, dynamic>{},
            }),
          );
        } else {
          terminalResponses[message['id']?.toString()]?.complete();
        }
      });

      Future<void> createTerminal(String sessionId, String requestId) async {
        final response = Completer<void>();
        terminalResponses[requestId] = response;
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': requestId,
            'method': 'terminal/create',
            'params': <String, dynamic>{
              'sessionId': sessionId,
              'command': 'unused',
              'args': <String>[],
            },
          }),
        );
        await response.future.timeout(const Duration(seconds: 5));
      }

      try {
        await manager.resumeSession(
          sessionId: 'session-a',
          workspaceRoot: '/a',
        );
        await manager.resumeSession(
          sessionId: 'session-b',
          workspaceRoot: '/b',
        );
        await createTerminal('session-a', 'create-a1');
        await createTerminal('session-a', 'create-a2');
        await createTerminal('session-b', 'create-b1');

        await expectLater(
          manager.closeSession(sessionId: 'session-a'),
          throwsA(isA<acp.SessionCloseCleanupException>()),
        );
        expect(
          provider.releaseAttempts,
          containsAll(['terminal-1', 'terminal-2']),
        );
        expect(provider.releaseAttempts, isNot(contains('terminal-3')));
        expect(() => manager.getWorkspaceRoot('session-a'), throwsStateError);
        expect(manager.getWorkspaceRoot('session-b'), '/b');
      } finally {
        await manager.dispose();
        await peer.close();
        await server.cancel();
        await channel.local.sink.close();
      }
    },
  );

  test(
    'paused session listener does not block close cleanup or leak provider errors',
    () async {
      const providerSecret = 'terminal-release-provider-secret';
      final channel = StreamChannelController<String>();
      final peer = JsonRpcPeer(channel.foreign);
      final provider = _RecordingTerminalProvider(
        failReleaseIds: const <String>{'terminal-1'},
        releaseErrorMessage: providerSecret,
      );
      final config = acp.AcpConfig(
        terminalProvider: provider,
        permissionProvider: acp.DefaultPermissionProvider(
          onRequest: (_) async => const acp.PermissionDecision.allow(),
        ),
      );
      final logs = <String>[];
      final logSubscription = config.logger.onRecord.listen(
        (record) => logs.add(record.message),
      );
      final manager = SessionManager(config: config, peer: peer);
      final terminalCreated = Completer<void>();
      final server = channel.local.stream.listen((line) {
        final message = jsonDecode(line) as Map<String, dynamic>;
        final method = message['method'];
        if (method == 'session/resume' || method == 'session/close') {
          channel.local.sink.add(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': message['id'],
              'result': <String, dynamic>{},
            }),
          );
        } else if (message['id'] == 'paused-terminal') {
          terminalCreated.complete();
        }
      });

      try {
        await manager.resumeSession(
          sessionId: 'paused-close',
          workspaceRoot: '/workspace',
        );
        final modeOwner = manager.beginPromptTurn('paused-close');
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'method': 'session/update',
            'params': <String, dynamic>{
              'sessionId': 'paused-close',
              'update': <String, dynamic>{
                'sessionUpdate': 'current_mode_update',
                'currentModeId': 'seeded-mode',
              },
            },
          }),
        );
        await pumpEventQueue();
        manager.endPromptTurn(modeOwner);
        expect(
          manager.sessionModes('paused-close')?.currentModeId,
          'seeded-mode',
        );
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': 'paused-terminal',
            'method': 'terminal/create',
            'params': <String, dynamic>{
              'sessionId': 'paused-close',
              'command': 'unused',
              'args': <String>[],
            },
          }),
        );
        await terminalCreated.future.timeout(const Duration(seconds: 5));
        final updates = manager.sessionUpdates('paused-close').listen((_) {});
        updates.pause();

        await expectLater(
          manager
              .closeSession(sessionId: 'paused-close')
              .timeout(const Duration(seconds: 1)),
          throwsA(isA<acp.SessionCloseCleanupException>()),
        );

        expect(provider.releaseAttempts, ['terminal-1']);
        expect(
          () => manager.getWorkspaceRoot('paused-close'),
          throwsStateError,
        );
        expect(manager.sessionModes('paused-close'), isNull);
        expect(logs.join('\n'), contains('terminals'));
        expect(logs.join('\n'), isNot(contains(providerSecret)));
        await updates.cancel();
      } finally {
        await manager.dispose();
        await logSubscription.cancel();
        await peer.close();
        await server.cancel();
        await channel.local.sink.close();
      }
    },
  );

  test('paused session listener does not block manager dispose', () async {
    final channel = StreamChannelController<String>();
    final peer = JsonRpcPeer(channel.foreign);
    final manager = SessionManager(config: acp.AcpConfig(), peer: peer);
    final server = channel.local.stream.listen((line) {
      final message = jsonDecode(line) as Map<String, dynamic>;
      if (message['method'] != 'session/resume') return;
      channel.local.sink.add(
        jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': message['id'],
          'result': <String, dynamic>{},
        }),
      );
    });
    StreamSubscription<acp.AcpUpdate>? updates;
    Future<void>? disposeFuture;

    try {
      await manager.resumeSession(
        sessionId: 'paused-dispose',
        workspaceRoot: '/workspace',
      );
      updates = manager.sessionUpdates('paused-dispose').listen((_) {});
      await pumpEventQueue();
      updates.pause();

      disposeFuture = manager.dispose();
      await disposeFuture.timeout(const Duration(seconds: 1));
    } finally {
      await updates?.cancel();
      if (disposeFuture != null) await disposeFuture;
      await peer.close();
      await server.cancel();
      await channel.local.sink.close();
    }
  });

  test(
    'paused session listener does not block the original setup RPC error',
    () async {
      const originalErrorMessage = 'original setup RPC failure';
      final channel = StreamChannelController<String>();
      final peer = JsonRpcPeer(channel.foreign);
      final manager = SessionManager(config: acp.AcpConfig(), peer: peer);
      final requestId = Completer<Object?>();
      final server = channel.local.stream.listen((line) {
        final message = jsonDecode(line) as Map<String, dynamic>;
        if (message['method'] == 'session/resume' && !requestId.isCompleted) {
          requestId.complete(message['id']);
        }
      });
      final setup = manager.resumeSession(
        sessionId: 'paused-setup-rollback',
        workspaceRoot: '/workspace',
      );
      final setupError = setup.then<Object?>(
        (_) => null,
        onError: (Object error, StackTrace _) => error,
      );
      StreamSubscription<acp.AcpUpdate>? updates;

      try {
        final id = await requestId.future.timeout(const Duration(seconds: 5));
        updates = manager
            .sessionUpdates('paused-setup-rollback')
            .listen((_) {});
        await pumpEventQueue();
        updates.pause();
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': id,
            'error': <String, dynamic>{
              'code': -32000,
              'message': originalErrorMessage,
            },
          }),
        );

        final error = await setupError.timeout(const Duration(seconds: 1));
        expect(error, isNotNull);
        expect(error.toString(), contains(originalErrorMessage));
      } finally {
        await updates?.cancel();
        await setupError;
        await manager.dispose();
        await peer.close();
        await server.cancel();
        await channel.local.sink.close();
      }
    },
  );

  test(
    'manager dispose logs terminal cleanup failures without payload',
    () async {
      const providerSecret = 'dispose-terminal-provider-secret';
      const expectedLog =
          'session dispose cleanup stage terminals failed (count: 1)';
      final channel = StreamChannelController<String>();
      final peer = JsonRpcPeer(channel.foreign);
      final provider = _RecordingTerminalProvider(
        failReleaseIds: const <String>{'terminal-1'},
        releaseErrorMessage: providerSecret,
      );
      final config = acp.AcpConfig(
        terminalProvider: provider,
        permissionProvider: acp.DefaultPermissionProvider(
          onRequest: (_) async => const acp.PermissionDecision.allow(),
        ),
      );
      final logs = <String>[];
      final logSubscription = config.logger.onRecord.listen(
        (record) => logs.add(record.message),
      );
      final manager = SessionManager(config: config, peer: peer);
      final terminalCreated = Completer<void>();
      final server = channel.local.stream.listen((line) {
        final message = jsonDecode(line) as Map<String, dynamic>;
        if (message['method'] == 'session/resume') {
          channel.local.sink.add(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': message['id'],
              'result': <String, dynamic>{},
            }),
          );
        } else if (message['id'] == 'dispose-terminal') {
          terminalCreated.complete();
        }
      });

      try {
        await manager.resumeSession(
          sessionId: 'dispose-terminal-session',
          workspaceRoot: '/workspace',
        );
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': 'dispose-terminal',
            'method': 'terminal/create',
            'params': <String, dynamic>{
              'sessionId': 'dispose-terminal-session',
              'command': 'unused',
              'args': <String>[],
            },
          }),
        );
        await terminalCreated.future.timeout(const Duration(seconds: 5));

        await manager.dispose();

        expect(provider.releaseAttempts, ['terminal-1']);
        expect(logs, contains(expectedLog));
        expect(logs.join('\n'), isNot(contains(providerSecret)));
      } finally {
        await logSubscription.cancel();
        await peer.close();
        await server.cancel();
        await channel.local.sink.close();
      }
    },
  );

  test(
    'late terminal create is released and never registered after close',
    () async {
      const providerSecret = 'late-terminal-release-secret';
      final channel = StreamChannelController<String>();
      final peer = JsonRpcPeer(channel.foreign);
      final createBarrier = Completer<void>();
      final createStarted = Completer<void>();
      final provider = _RecordingTerminalProvider(
        failReleaseIds: const <String>{'terminal-1'},
        releaseErrorMessage: providerSecret,
        createBarrier: createBarrier,
        createStarted: createStarted,
      );
      final manager = SessionManager(
        config: acp.AcpConfig(
          terminalProvider: provider,
          permissionProvider: acp.DefaultPermissionProvider(
            onRequest: (_) async => const acp.PermissionDecision.allow(),
          ),
        ),
        peer: peer,
      );
      final terminalResponse = Completer<Map<String, dynamic>>();
      final server = channel.local.stream.listen((line) {
        final message = jsonDecode(line) as Map<String, dynamic>;
        final method = message['method'];
        if (method == 'session/resume' || method == 'session/close') {
          channel.local.sink.add(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': message['id'],
              'result': <String, dynamic>{},
            }),
          );
        } else if (message['id'] == 'late-terminal' &&
            !terminalResponse.isCompleted) {
          terminalResponse.complete(message);
        }
      });

      try {
        await manager.resumeSession(
          sessionId: 'terminal-race',
          workspaceRoot: '/workspace',
        );
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': 'late-terminal',
            'method': 'terminal/create',
            'params': <String, dynamic>{
              'sessionId': 'terminal-race',
              'command': 'unused',
              'args': <String>[],
            },
          }),
        );
        await createStarted.future.timeout(const Duration(seconds: 5));

        await manager.closeSession(sessionId: 'terminal-race');
        createBarrier.complete();
        final response = await terminalResponse.future.timeout(
          const Duration(seconds: 5),
        );

        expect(response['error'], <String, dynamic>{
          'code': -32003,
          'message': 'Permission request cancelled.',
        });
        expect(response.toString(), isNot(contains(providerSecret)));
        await _waitForTerminalTestCondition(
          () => provider.releaseAttempts.length == 1,
        );
        expect(provider.releaseAttempts, ['terminal-1']);
        expect(await manager.readTerminalOutput('terminal-1'), isEmpty);
      } finally {
        if (!createBarrier.isCompleted) createBarrier.complete();
        await manager.dispose();
        await peer.close();
        await server.cancel();
        await channel.local.sink.close();
      }
    },
  );

  test(
    'serialized close owners gate queued setup and stale rollback',
    () async {
      final channel = StreamChannelController<String>();
      final peer = JsonRpcPeer(channel.foreign);
      final manager = SessionManager(config: acp.AcpConfig(), peer: peer);
      final firstCloseRequestId = Completer<Object?>();
      final secondCloseRequestId = Completer<Object?>();
      final gateResumeId = Completer<Object?>();
      final replacementResumeId = Completer<Object?>();
      final replacementLoadId = Completer<Object?>();
      final newRequestId = Completer<Object?>();
      var resumeRequests = 0;
      var loadRequests = 0;
      var closeRequests = 0;
      final server = channel.local.stream.listen((line) {
        final message = jsonDecode(line) as Map<String, dynamic>;
        switch (message['method']) {
          case 'session/resume':
            resumeRequests += 1;
            if (resumeRequests == 1) {
              channel.local.sink.add(
                jsonEncode(<String, dynamic>{
                  'jsonrpc': '2.0',
                  'id': message['id'],
                  'result': <String, dynamic>{},
                }),
              );
            } else if (resumeRequests == 2 && !gateResumeId.isCompleted) {
              gateResumeId.complete(message['id']);
            } else if (!replacementResumeId.isCompleted) {
              replacementResumeId.complete(message['id']);
            }
            break;
          case 'session/load':
            loadRequests += 1;
            if (!replacementLoadId.isCompleted) {
              replacementLoadId.complete(message['id']);
            }
            break;
          case 'session/new':
            if (!newRequestId.isCompleted) newRequestId.complete(message['id']);
            break;
          case 'session/close':
            closeRequests += 1;
            if (closeRequests == 1 && !firstCloseRequestId.isCompleted) {
              firstCloseRequestId.complete(message['id']);
            } else if (!secondCloseRequestId.isCompleted) {
              secondCloseRequestId.complete(message['id']);
            }
            break;
        }
      });

      void respond(Object? id, Map<String, dynamic> result) {
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': id,
            'result': result,
          }),
        );
      }

      try {
        await manager.resumeSession(
          sessionId: 'shared-close',
          workspaceRoot: '/workspace',
        );
        final originalGeneration = manager.sessionGenerationForTesting(
          'shared-close',
        );
        final lateRegistration = manager.newSession(
          workspaceRoot: '/workspace',
        );
        final lateRegistrationFailure = expectLater(
          lateRegistration,
          throwsStateError,
        );
        final pendingNewId = await newRequestId.future.timeout(
          const Duration(seconds: 5),
        );
        final gateSetup = manager.resumeSession(
          sessionId: 'shared-close',
          workspaceRoot: '/workspace',
        );
        final gateId = await gateResumeId.future.timeout(
          const Duration(seconds: 5),
        );
        final staleSetupRollback = manager
            .captureSessionSetupRollbackCallbackForTesting();

        final closeOne = manager.closeSession(sessionId: 'shared-close');
        final closeTwo = manager.closeSession(sessionId: 'shared-close');
        final queuedResume = manager.resumeSession(
          sessionId: 'shared-close',
          workspaceRoot: '/workspace',
        );
        final queuedLoad = manager.loadSession(
          sessionId: 'shared-close',
          workspaceRoot: '/workspace',
        );
        await pumpEventQueue();
        expect(closeRequests, 0);
        expect(firstCloseRequestId.isCompleted, isFalse);
        expect(secondCloseRequestId.isCompleted, isFalse);
        expect(resumeRequests, 2);
        expect(loadRequests, 0);
        expect(manager.sessionCloseSelectionCountForTesting('shared-close'), 0);

        respond(gateId, const <String, dynamic>{});
        await gateSetup.timeout(const Duration(seconds: 5));
        final firstCloseId = await firstCloseRequestId.future.timeout(
          const Duration(seconds: 5),
        );
        expect(closeRequests, 1);
        expect(resumeRequests, 2);
        expect(loadRequests, 0);
        expect(manager.sessionCloseSelectionCountForTesting('shared-close'), 1);
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'method': 'session/update',
            'params': <String, dynamic>{
              'sessionId': 'shared-close',
              'update': <String, dynamic>{
                'sessionUpdate': 'current_mode_update',
                'currentModeId': 'must-drop-during-close',
              },
            },
          }),
        );
        await pumpEventQueue();
        expect(manager.sessionModes('shared-close'), isNull);

        respond(firstCloseId, const <String, dynamic>{});
        await closeOne;
        final secondCloseId = await secondCloseRequestId.future.timeout(
          const Duration(seconds: 5),
        );
        expect(closeRequests, 2);
        expect(resumeRequests, 2);
        expect(loadRequests, 0);
        expect(manager.sessionCloseSelectionCountForTesting('shared-close'), 1);
        respond(pendingNewId, const <String, dynamic>{
          'sessionId': 'shared-close',
        });
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'method': 'session/update',
            'params': <String, dynamic>{
              'sessionId': 'shared-close',
              'update': <String, dynamic>{
                'sessionUpdate': 'current_mode_update',
                'currentModeId': 'must-drop-late-registration',
              },
            },
          }),
        );
        await pumpEventQueue();
        expect(manager.sessionModes('shared-close'), isNull);

        respond(secondCloseId, const <String, dynamic>{});
        await closeTwo;
        final resumeId = await replacementResumeId.future.timeout(
          const Duration(seconds: 5),
        );
        expect(loadRequests, 0, reason: 'load must wait for queued resume');
        respond(resumeId, const <String, dynamic>{});
        await queuedResume.timeout(const Duration(seconds: 5));
        final resumedGeneration = manager.sessionGenerationForTesting(
          'shared-close',
        );
        expect(resumedGeneration, isNot(same(originalGeneration)));
        final loadId = await replacementLoadId.future.timeout(
          const Duration(seconds: 5),
        );
        respond(loadId, const <String, dynamic>{});
        await queuedLoad.timeout(const Duration(seconds: 5));
        await lateRegistrationFailure;
        final replacementGeneration = manager.sessionGenerationForTesting(
          'shared-close',
        );
        expect(replacementGeneration, isNot(same(resumedGeneration)));
        expect(manager.sessionCloseSelectionCountForTesting('shared-close'), 0);
        expect(manager.getWorkspaceRoot('shared-close'), '/workspace');

        final acceptedOwner = manager.beginPromptTurn('shared-close');
        staleSetupRollback();
        await pumpEventQueue();
        expect(
          manager.sessionGenerationForTesting('shared-close'),
          same(replacementGeneration),
        );
        expect(manager.getWorkspaceRoot('shared-close'), '/workspace');
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'method': 'session/update',
            'params': <String, dynamic>{
              'sessionId': 'shared-close',
              'update': <String, dynamic>{
                'sessionUpdate': 'current_mode_update',
                'currentModeId': 'accepted-after-close',
              },
            },
          }),
        );
        await pumpEventQueue();
        manager.endPromptTurn(acceptedOwner);
        expect(
          manager.sessionModes('shared-close')?.currentModeId,
          'accepted-after-close',
        );
        expect(resumeRequests, 3);
        expect(loadRequests, 1);
        expect(closeRequests, 2);
      } finally {
        await manager.dispose();
        await peer.close();
        await server.cancel();
        await channel.local.sink.close();
      }
    },
  );

  test('session replay rejects every byte budget below its marker size', () {
    for (var maxBytes = 1; maxBytes < 64; maxBytes += 1) {
      expect(
        () => DartAcpAgentClient(
          agentCommand: 'unused',
          maxSessionReplayBytes: maxBytes,
        ),
        throwsArgumentError,
        reason: 'maxSessionReplayBytes=$maxBytes',
      );
    }
    expect(
      () =>
          DartAcpAgentClient(agentCommand: 'unused', maxSessionReplayBytes: 64),
      returnsNormally,
    );
  });

  test(
    'fork requires a known or explicit workspace before contacting agent',
    () async {
      final channel = StreamChannelController<String>();
      final peer = JsonRpcPeer(channel.foreign);
      final manager = SessionManager(config: acp.AcpConfig(), peer: peer);
      var forkRequestCount = 0;
      final server = channel.local.stream.listen((line) {
        final request = jsonDecode(line) as Map<String, dynamic>;
        if (request['method'] != 'session/fork') return;
        forkRequestCount += 1;
        final params = request['params'] as Map<String, dynamic>;
        final generatedId = params.containsKey('cwd')
            ? 'explicit-fork'
            : 'unexpected-fork';
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': request['id'],
            'result': <String, dynamic>{'sessionId': generatedId},
          }),
        );
      });

      try {
        Object? missingRootError;
        try {
          await manager.forkSession(sessionId: 'unknown-source');
        } catch (error) {
          missingRootError = error;
        }

        expect(missingRootError, isA<StateError>());
        expect(forkRequestCount, 0);
        expect(
          () => manager.prompt(
            sessionId: 'unexpected-fork',
            content: const <Map<String, dynamic>>[],
          ),
          throwsArgumentError,
        );

        final explicit = await manager.forkSession(
          sessionId: 'unknown-source',
          workspaceRoot: '/workspace/explicit',
        );
        expect(explicit.sessionId, 'explicit-fork');
        expect(forkRequestCount, 1);
        expect(
          manager.getWorkspaceRoot('explicit-fork'),
          '/workspace/explicit',
        );
      } finally {
        await manager.dispose();
        await peer.close();
        await server.cancel();
        await channel.local.sink.close();
      }
    },
  );

  test(
    'filesystem provider allows configured additional directories',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
      final workspace = Directory('${tempDir.path}/workspace');
      final extraWorkspace = Directory('${tempDir.path}/extra-workspace');
      await workspace.create();
      await extraWorkspace.create();
      final extraFixture = File('${extraWorkspace.path}/fixture.txt');
      final extraCreated = File('${extraWorkspace.path}/created.txt');
      final outsideFile = File('${tempDir.path}/outside.txt');
      await extraFixture.writeAsString('hello extra');
      final readResponseFile = File('${tempDir.path}/fs_read_response.json');
      final writeResponseFile = File('${tempDir.path}/fs_write_response.json');
      final outsideResponseFile = File(
        '${tempDir.path}/fs_outside_response.json',
      );
      final agentScript = File('${tempDir.path}/fake_fs_extra_agent.dart');
      final readResponsePath = jsonEncode(readResponseFile.path);
      final writeResponsePath = jsonEncode(writeResponseFile.path);
      final outsideResponsePath = jsonEncode(outsideResponseFile.path);
      final extraFixturePath = jsonEncode(extraFixture.path);
      final extraCreatedPath = jsonEncode(extraCreated.path);
      final outsidePath = jsonEncode(outsideFile.path);
      await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

void request(String id, String method, Map<String, dynamic> params) {
  stdout.writeln(jsonEncode(<String, dynamic>{
    'jsonrpc': '2.0',
    'id': id,
    'method': method,
    'params': params,
  }));
}

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{
            'sessionCapabilities': <String, dynamic>{
              'additionalDirectories': true,
            },
          },
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/new') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'sessionId': 'session-fs'},
      }));
      request('fs-read-extra', 'fs/read_text_file', <String, dynamic>{
        'sessionId': 'session-fs',
        'path': $extraFixturePath,
      });
      request('fs-write-extra', 'fs/write_text_file', <String, dynamic>{
        'sessionId': 'session-fs',
        'path': $extraCreatedPath,
        'content': 'created in extra workspace',
      });
      request('fs-write-outside', 'fs/write_text_file', <String, dynamic>{
        'sessionId': 'session-fs',
        'path': $outsidePath,
        'content': 'outside',
      });
    } else if (message['id'] == 'fs-read-extra') {
      await File($readResponsePath).writeAsString(jsonEncode(message));
    } else if (message['id'] == 'fs-write-extra') {
      await File($writeResponsePath).writeAsString(jsonEncode(message));
    } else if (message['id'] == 'fs-write-outside') {
      await File($outsideResponsePath).writeAsString(jsonEncode(message));
    }
  }
}
''');

      late final DartAcpAgentClient client;
      client = DartAcpAgentClient(
        agentCommand: _dartExecutable(),
        agentArgs: [agentScript.path],
        additionalDirectories: [extraWorkspace.path],
        enableFilesystemReadTextFile: true,
        enableFilesystemWriteTextFile: true,
      );
      final subscription = client.permissionRequests.listen((request) {
        unawaited(
          client.respondToPermissionRequest(
            id: request.id,
            decision: AcpPermissionDecision.allow,
          ),
        );
      });
      try {
        await client.connect().timeout(const Duration(seconds: 5));
        await client.createSession(cwd: workspace.path);
        await _waitForFile(readResponseFile);
        await _waitForFile(writeResponseFile);
        await _waitForFile(outsideResponseFile);

        final readResponse =
            jsonDecode(await readResponseFile.readAsString())
                as Map<String, dynamic>;
        final writeResponse =
            jsonDecode(await writeResponseFile.readAsString())
                as Map<String, dynamic>;
        final outsideResponse =
            jsonDecode(await outsideResponseFile.readAsString())
                as Map<String, dynamic>;

        expect(readResponse, contains('result'), reason: '$readResponse');
        expect(readResponse['result'], containsPair('content', 'hello extra'));
        expect(writeResponse, containsPair('result', isEmpty));
        expect(await extraCreated.readAsString(), 'created in extra workspace');
        expect(outsideResponse, contains('error'));
        expect(await outsideFile.exists(), isFalse);
      } finally {
        await subscription.cancel();
        await client.dispose();
        await tempDir.delete(recursive: true);
      }
    },
  );

  test('rejects unadvertised filesystem write requests', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final workspace = Directory('${tempDir.path}/workspace');
    await workspace.create();
    final fsResponseFile = File('${tempDir.path}/fs_response.json');
    final agentScript = File('${tempDir.path}/fake_fs_write_agent.dart');
    final fsResponsePath = jsonEncode(fsResponseFile.path);
    await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{},
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/new') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'sessionId': 'session-fs'},
      }));
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': 'fs-write-1',
        'method': 'fs/write_text_file',
        'params': <String, dynamic>{
          'sessionId': 'session-fs',
          'path': 'created.txt',
          'content': 'should not write',
        },
      }));
    } else if (message['id'] == 'fs-write-1') {
      await File($fsResponsePath).writeAsString(jsonEncode(message));
    }
  }
}
''');

    late final DartAcpAgentClient client;
    client = DartAcpAgentClient(
      agentCommand: _dartExecutable(),
      agentArgs: [agentScript.path],
      enableFilesystemReadTextFile: true,
      enableFilesystemWriteTextFile: false,
    );
    final subscription = client.permissionRequests.listen((request) {
      unawaited(
        client.respondToPermissionRequest(
          id: request.id,
          decision: AcpPermissionDecision.allow,
        ),
      );
    });

    try {
      await client.connect().timeout(const Duration(seconds: 5));
      await client.createSession(cwd: workspace.path);
      await _waitForFile(fsResponseFile);

      final fsResponse =
          jsonDecode(await fsResponseFile.readAsString())
              as Map<String, dynamic>;
      expect(fsResponse['id'], 'fs-write-1');
      expect(fsResponse, contains('error'));
      expect(await File('${workspace.path}/created.txt').exists(), isFalse);
    } finally {
      await subscription.cancel();
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  test('emits terminal lifecycle events after permission approval', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final workspace = Directory('${tempDir.path}/workspace');
    await workspace.create();
    final terminalResponseFile = File('${tempDir.path}/terminal_response.json');
    final agentScript = File('${tempDir.path}/fake_terminal_agent.dart');
    final terminalResponsePath = jsonEncode(terminalResponseFile.path);
    await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  Object? promptId;
  String? terminalId;

  void respond(Object? id, Object? result) {
    stdout.writeln(jsonEncode(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': id,
      'result': result,
    }));
  }

  void request(String id, String method, Map<String, dynamic> params) {
    stdout.writeln(jsonEncode(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    }));
  }

  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      respond(message['id'], <String, dynamic>{
        'protocolVersion': 1,
        'agentCapabilities': <String, dynamic>{},
        'authMethods': <Map<String, dynamic>>[],
      });
    } else if (message['method'] == 'session/new') {
      respond(message['id'], <String, dynamic>{'sessionId': 'session-term'});
    } else if (message['method'] == 'session/prompt') {
      promptId = message['id'];
      request('terminal-create-1', 'terminal/create', <String, dynamic>{
        'sessionId': 'session-term',
        'command': 'printf terminal-output',
        'args': <String>[],
        'env': <Map<String, String>>[
          <String, String>{
            'name': 'EXFIL_URL',
            'value': 'https://collector.example/private-secret',
          },
        ],
        'outputByteLimit': 8,
      });
    } else if (message['id'] == 'terminal-create-1') {
      terminalId = (message['result'] as Map<String, dynamic>)['terminalId']
          as String;
      request('terminal-wait-1', 'terminal/wait_for_exit', <String, dynamic>{
        'terminalId': terminalId,
      });
    } else if (message['id'] == 'terminal-wait-1') {
      request('terminal-output-1', 'terminal/output', <String, dynamic>{
        'terminalId': terminalId,
      });
    } else if (message['id'] == 'terminal-output-1') {
      await File($terminalResponsePath).writeAsString(jsonEncode(message));
      request('terminal-release-1', 'terminal/release', <String, dynamic>{
        'terminalId': terminalId,
      });
    } else if (message['id'] == 'terminal-release-1') {
      respond(promptId, <String, dynamic>{'stopReason': 'end_turn'});
    }
  }
}
''');

    late final DartAcpAgentClient client;
    client = DartAcpAgentClient(
      agentCommand: _dartExecutable(),
      agentArgs: [agentScript.path],
      enableTerminalProvider: true,
    );
    final permissionRequests = <AcpPermissionRequest>[];
    final subscription = client.permissionRequests.listen((request) {
      permissionRequests.add(request);
      unawaited(
        client.respondToPermissionRequest(
          id: request.id,
          decision: AcpPermissionDecision.allow,
        ),
      );
    });

    try {
      await client.connect().timeout(const Duration(seconds: 5));
      final session = await client.createSession(cwd: workspace.path);
      final events = await client
          .sendPrompt(sessionId: session.id, prompt: 'run command')
          .toList()
          .timeout(const Duration(seconds: 5));
      await _waitForFile(terminalResponseFile);

      expect(permissionRequests, hasLength(1));
      expect(permissionRequests.single.toolName, 'terminal');
      expect(permissionRequests.single.toolKind, 'execute');
      expect(permissionRequests.single.metadata['envKeys'], ['EXFIL_URL']);
      expect(
        permissionRequests.single.metadata.toString(),
        isNot(contains('private-secret')),
      );
      expect(
        permissionRequests.single.transientPolicyContext['environment'],
        containsPair('EXFIL_URL', 'https://collector.example/private-secret'),
      );
      expect(
        permissionRequests.single.toJson().toString(),
        isNot(contains('private-secret')),
      );

      final terminalEvents = events
          .where((event) => event.metadata['kind'] == 'terminal')
          .toList();
      expect(
        terminalEvents.map((event) => event.metadata['terminalEvent']),
        containsAll(['created', 'exited', 'output', 'released']),
      );
      expect(
        terminalEvents.first.metadata['command'],
        'printf terminal-output',
      );
      expect(
        terminalEvents
            .where((event) => event.metadata['terminalEvent'] == 'output')
            .single
            .metadata['output'],
        'l-output',
      );
      expect(
        terminalEvents
            .where((event) => event.metadata['terminalEvent'] == 'output')
            .single
            .metadata['truncated'],
        isTrue,
      );
      expect(events.last.metadata['stopReason'], 'endTurn');

      final terminalResponse =
          jsonDecode(await terminalResponseFile.readAsString())
              as Map<String, dynamic>;
      expect(terminalResponse['result'], <String, Object?>{
        'output': 'l-output',
        'truncated': true,
        'exitStatus': <String, Object?>{'exitCode': 0},
      });
    } finally {
      await subscription.cancel();
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'terminal handle limits flow through the raw client terminal lifecycle',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
      final workspace = Directory('${tempDir.path}/workspace');
      await workspace.create();
      final resultFile = File('${tempDir.path}/terminal_limits.json');
      final agentScript = File(
        '${tempDir.path}/fake_terminal_limits_agent.dart',
      );
      final resultPath = jsonEncode(resultFile.path);
      await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  Object? promptId;
  String? firstTerminalId;
  String? thirdTerminalId;
  Map<String, dynamic>? secondResponse;

  void respond(Object? id, Object? result) {
    stdout.writeln(jsonEncode(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': id,
      'result': result,
    }));
  }

  void request(String id, String method, Map<String, dynamic> params) {
    stdout.writeln(jsonEncode(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    }));
  }

  Map<String, dynamic> createParams(String command) => <String, dynamic>{
    'sessionId': 'session-terminal-limits',
    'command': command,
    'args': <String>[],
    'env': <Map<String, String>>[
      <String, String>{
        'name': 'TERMINAL_LIMIT_CANARY',
        'value': 'raw-terminal-limit-secret',
      },
    ],
  };

  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      respond(message['id'], <String, dynamic>{
        'protocolVersion': 1,
        'agentCapabilities': <String, dynamic>{},
        'authMethods': <Map<String, dynamic>>[],
      });
    } else if (message['method'] == 'session/new') {
      respond(
        message['id'],
        <String, dynamic>{'sessionId': 'session-terminal-limits'},
      );
    } else if (message['method'] == 'session/prompt') {
      promptId = message['id'];
      request(
        'terminal-limit-create-1',
        'terminal/create',
        createParams('sleep 30'),
      );
    } else if (message['id'] == 'terminal-limit-create-1') {
      firstTerminalId =
          (message['result'] as Map<String, dynamic>)['terminalId'] as String;
      request(
        'terminal-limit-create-2',
        'terminal/create',
        createParams('second-command-canary'),
      );
    } else if (message['id'] == 'terminal-limit-create-2') {
      secondResponse = message;
      request(
        'terminal-limit-release-1',
        'terminal/release',
        <String, dynamic>{'terminalId': firstTerminalId},
      );
    } else if (message['id'] == 'terminal-limit-release-1') {
      request(
        'terminal-limit-create-3',
        'terminal/create',
        createParams('sleep 30'),
      );
    } else if (message['id'] == 'terminal-limit-create-3') {
      thirdTerminalId =
          (message['result'] as Map<String, dynamic>)['terminalId'] as String;
      request(
        'terminal-limit-release-3',
        'terminal/release',
        <String, dynamic>{'terminalId': thirdTerminalId},
      );
    } else if (message['id'] == 'terminal-limit-release-3') {
      await File($resultPath).writeAsString(
        jsonEncode(<String, dynamic>{
          'firstTerminalId': firstTerminalId,
          'secondResponse': secondResponse,
          'thirdTerminalId': thirdTerminalId,
        }),
      );
      respond(promptId, <String, dynamic>{'stopReason': 'end_turn'});
    }
  }
}
''');

      final client = DartAcpAgentClient(
        agentCommand: _dartExecutable(),
        agentArgs: <String>[agentScript.path],
        enableTerminalProvider: true,
        maxTerminalHandles: 1,
        maxTerminalHandlesPerSession: 1,
      );
      final permissionRequests = <AcpPermissionRequest>[];
      final subscription = client.permissionRequests.listen((request) {
        permissionRequests.add(request);
        unawaited(
          client.respondToPermissionRequest(
            id: request.id,
            decision: AcpPermissionDecision.allow,
          ),
        );
      });

      try {
        await client.connect().timeout(const Duration(seconds: 5));
        final session = await client.createSession(cwd: workspace.path);
        final events = await client
            .sendPrompt(sessionId: session.id, prompt: 'exercise limits')
            .toList()
            .timeout(const Duration(seconds: 10));
        await _waitForFile(resultFile);

        final result =
            jsonDecode(await resultFile.readAsString()) as Map<String, dynamic>;
        final second = result['secondResponse'] as Map<String, dynamic>;
        expect(second['error'], <String, dynamic>{
          'code': -32001,
          'message': 'Terminal handle limit exceeded.',
        });
        expect(
          (second['error'] as Map<String, dynamic>),
          isNot(contains('data')),
        );
        expect(second.toString(), isNot(contains('raw-terminal-limit-secret')));
        expect(second.toString(), isNot(contains('second-command-canary')));
        expect(result['firstTerminalId'], isNotEmpty);
        expect(result['thirdTerminalId'], isNotEmpty);
        expect(result['thirdTerminalId'], isNot(result['firstTerminalId']));
        expect(permissionRequests, hasLength(2));
        expect(events.last.metadata['stopReason'], 'endTurn');
      } finally {
        await subscription.cancel();
        await client.dispose();
        await tempDir.delete(recursive: true);
      }
    },
  );

  test(
    'raw prompt immediate cancel stays pre-owner and sends no RPC',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
      final cancelSeenFile = File('${tempDir.path}/cancel_seen');
      final promptSeenFile = File('${tempDir.path}/prompt_seen');
      final agentScript = File(
        '${tempDir.path}/fake_immediate_cancel_agent.dart',
      );
      final cancelSeenPath = jsonEncode(cancelSeenFile.path);
      final promptSeenPath = jsonEncode(promptSeenFile.path);
      await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{},
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/new') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'sessionId': 'session-1'},
      }));
    } else if (message['method'] == 'session/cancel') {
      await File($cancelSeenPath).writeAsString('cancelled');
    } else if (message['method'] == 'session/prompt') {
      final params = message['params'] as Map<String, dynamic>;
      final prompt = params['prompt'] as List<dynamic>;
      final first = prompt.first as Map<String, dynamic>;
      if (first['text'] == 'cancel immediately') {
        await File($promptSeenPath).writeAsString('prompted');
      } else {
        stdout.writeln(jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'method': 'session/update',
          'params': <String, dynamic>{
            'sessionId': params['sessionId'],
            'update': <String, dynamic>{
              'sessionUpdate': 'agent_message_chunk',
              'content': <String, dynamic>{
                'type': 'text',
                'text': 'replacement-only',
              },
            },
          },
        }));
      }
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'stopReason': 'end_turn'},
      }));
    }
  }
}
''');

      final client = DartAcpAgentClient(
        agentCommand: _dartExecutable(),
        agentArgs: <String>[agentScript.path],
      );

      try {
        await client.connect().timeout(const Duration(seconds: 5));
        final session = await client.createSession(cwd: '/workspace');
        final promptEvents = client
            .sendPrompt(sessionId: session.id, prompt: 'cancel immediately')
            .toList();
        await client.cancel();
        expect(client.beginPromptTurnCountForTesting, 0);
        expect(client.rawPromptDispatchCountForTesting, 0);
        expect(client.rawPromptCancelCountForTesting, 0);
        final replacement = await client
            .sendPrompt(sessionId: session.id, prompt: 'replacement barrier')
            .toList()
            .timeout(const Duration(seconds: 5));
        expect(replacement.last.metadata['stopReason'], 'endTurn');
        expect(await promptEvents.timeout(const Duration(seconds: 5)), isEmpty);
        expect(client.beginPromptTurnCountForTesting, 1);
        expect(client.rawPromptDispatchCountForTesting, 1);
        expect(client.rawPromptCancelCountForTesting, 0);
        expect(await cancelSeenFile.exists(), isFalse);
        expect(await promptSeenFile.exists(), isFalse);
      } finally {
        await client.dispose();
        await tempDir.delete(recursive: true);
      }
    },
  );

  test(
    'paused pre-owner raw cancel releases identity without cancel RPC',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
      final cancelSeenFile = File('${tempDir.path}/cancel_seen');
      final unexpectedPromptFile = File('${tempDir.path}/unexpected_prompt');
      final agentScript = File('${tempDir.path}/fake_paused_cancel_agent.dart');
      final cancelSeenPath = jsonEncode(cancelSeenFile.path);
      final unexpectedPromptPath = jsonEncode(unexpectedPromptFile.path);
      await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{},
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/new') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'sessionId': 'session-1'},
      }));
    } else if (message['method'] == 'session/cancel') {
      await File($cancelSeenPath).writeAsString('cancelled');
    } else if (message['method'] == 'session/prompt') {
      final params = message['params'] as Map<String, dynamic>;
      final prompt = params['prompt'] as List<dynamic>;
      final first = prompt.first as Map<String, dynamic>;
      if (first['text'] == 'paused cancel') {
        await File($unexpectedPromptPath).writeAsString('unexpected');
      }
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'stopReason': 'end_turn'},
      }));
    }
  }
}
''');
      final client = DartAcpAgentClient(
        agentCommand: _dartExecutable(),
        agentArgs: <String>[agentScript.path],
      );
      StreamSubscription<AgentEvent>? subscription;

      try {
        await client.connect().timeout(const Duration(seconds: 5));
        final session = await client.createSession(cwd: '/workspace');
        subscription = client
            .sendPrompt(sessionId: session.id, prompt: 'paused cancel')
            .listen((_) {});
        subscription.pause();

        await client.cancel().timeout(const Duration(seconds: 5));
        final replacement = await client
            .sendPrompt(sessionId: session.id, prompt: 'replacement barrier')
            .toList()
            .timeout(const Duration(seconds: 5));
        expect(replacement.last.metadata['stopReason'], 'endTurn');
        expect(client.beginPromptTurnCountForTesting, 1);
        expect(client.rawPromptDispatchCountForTesting, 1);
        expect(client.rawPromptCancelCountForTesting, 0);
        expect(await cancelSeenFile.exists(), isFalse);
        expect(await unexpectedPromptFile.exists(), isFalse);
      } finally {
        subscription?.resume();
        await subscription?.cancel();
        await client.dispose();
        await tempDir.delete(recursive: true);
      }
    },
  );

  test(
    'raw cancel notification precedes public done and background reap',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
      final promptSeenFile = File('${tempDir.path}/prompt_seen');
      final cancelSeenFile = File('${tempDir.path}/cancel_seen');
      final releaseResponseFile = File('${tempDir.path}/release_response');
      final agentScript = File('${tempDir.path}/fake_stream_cancel_agent.dart');
      final promptSeenPath = jsonEncode(promptSeenFile.path);
      final cancelSeenPath = jsonEncode(cancelSeenFile.path);
      final releaseResponsePath = jsonEncode(releaseResponseFile.path);
      await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  var promptCount = 0;
  Object? firstPromptId;
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{},
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/new') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'sessionId': 'session-1'},
      }));
    } else if (message['method'] == 'session/prompt') {
      promptCount += 1;
      if (promptCount == 1) {
        firstPromptId = message['id'];
        await File($promptSeenPath).writeAsString('prompted');
      } else {
        stdout.writeln(jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': message['id'],
          'result': <String, dynamic>{'stopReason': 'end_turn'},
        }));
      }
    } else if (message['method'] == 'session/cancel') {
      await File($cancelSeenPath).writeAsString('cancelled');
      while (!await File($releaseResponsePath).exists()) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': firstPromptId,
        'result': <String, dynamic>{'stopReason': 'cancelled'},
      }));
    }
  }
}
''');
      final client = DartAcpAgentClient(
        agentCommand: _dartExecutable(),
        agentArgs: <String>[agentScript.path],
      );
      StreamSubscription<AgentEvent>? first;
      final firstDone = Completer<void>.sync();
      acp.AcpSessionInputBudgetOwner? firstOwner;
      client.onRawPromptDispatchedForTesting = (owner) {
        firstOwner ??= owner;
      };

      try {
        await client.connect().timeout(const Duration(seconds: 5));
        final session = await client.createSession(cwd: '/workspace');
        first = client
            .sendPrompt(sessionId: session.id, prompt: 'hold first')
            .listen((_) {}, onDone: firstDone.complete);
        await _waitForFile(promptSeenFile);
        await client.cancel().timeout(const Duration(seconds: 5));
        await _waitForFile(cancelSeenFile);
        await firstDone.future.timeout(const Duration(seconds: 5));
        final owner = firstOwner!;
        final backgroundReap = client
            .acpClientForTesting
            .sessionManagerForTesting
            .promptCleanupReapedForTesting(owner)!;
        await expectLater(
          client
              .sendPrompt(sessionId: session.id, prompt: 'too early')
              .toList(),
          throwsA(isA<StateError>()),
        );
        await releaseResponseFile.writeAsString('release');
        await backgroundReap.timeout(const Duration(seconds: 5));

        final events = await client
            .sendPrompt(sessionId: session.id, prompt: 'replacement')
            .toList()
            .timeout(const Duration(seconds: 5));
        expect(events.last.metadata['stopReason'], 'endTurn');
      } finally {
        client.onRawPromptDispatchedForTesting = null;
        try {
          await first?.cancel().timeout(const Duration(seconds: 1));
        } on Object {
          // Keep cleanup bounded if an earlier cancellation assertion fails.
        }
        await client.dispose();
        await tempDir.delete(recursive: true);
      }
    },
  );

  for (final lateError in <bool>[false, true]) {
    final lateOutcome = lateError ? 'error' : 'success';
    test('post-owner raw cancel quarantines replacement updates and late '
        '$lateOutcome', () async {
      final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
      final promptSeenFile = File('${tempDir.path}/prompt_seen');
      final cancelSeenFile = File('${tempDir.path}/cancel_seen');
      final releaseResponseFile = File('${tempDir.path}/release_response');
      final releaseLateFile = File('${tempDir.path}/release_late');
      final lateSentFile = File('${tempDir.path}/late_sent');
      final agentScript = File(
        '${tempDir.path}/fake_post_owner_cancel_agent.dart',
      );
      final promptSeenPath = jsonEncode(promptSeenFile.path);
      final cancelSeenPath = jsonEncode(cancelSeenFile.path);
      final releaseResponsePath = jsonEncode(releaseResponseFile.path);
      final releaseLatePath = jsonEncode(releaseLateFile.path);
      final lateSentPath = jsonEncode(lateSentFile.path);
      await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  Object? firstPromptId;
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{},
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/new') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'sessionId': 'session-1'},
      }));
    } else if (message['method'] == 'session/cancel') {
      await File($cancelSeenPath).writeAsString('cancelled');
      while (!await File($releaseLatePath).exists()) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      if ($lateError) {
        stdout.writeln(jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': firstPromptId,
          'error': <String, dynamic>{
            'code': -32000,
            'message': 'late failure',
          },
        }));
      } else {
        stdout.writeln(jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': firstPromptId,
          'result': <String, dynamic>{'stopReason': 'end_turn'},
        }));
      }
      await File($lateSentPath).writeAsString('sent');
    } else if (message['method'] == 'session/prompt') {
      final params = message['params'] as Map<String, dynamic>;
      final prompt = params['prompt'] as List<dynamic>;
      final first = prompt.first as Map<String, dynamic>;
      if (first['text'] == 'hold first') {
        firstPromptId = message['id'];
        await File($promptSeenPath).writeAsString('prompted');
        continue;
      }
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'method': 'session/update',
        'params': <String, dynamic>{
          'sessionId': params['sessionId'],
          'update': <String, dynamic>{
            'sessionUpdate': 'agent_message_chunk',
            'content': <String, dynamic>{
              'type': 'text',
              'text': 'replacement-canary',
            },
          },
        },
      }));
      while (!await File($releaseResponsePath).exists()) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'stopReason': 'end_turn'},
      }));
    }
  }
}
''');
      final client = DartAcpAgentClient(
        agentCommand: _dartExecutable(),
        agentArgs: <String>[agentScript.path],
      );
      final firstEvents = <AgentEvent>[];
      final firstDone = Completer<void>();
      var firstDoneCount = 0;
      final replacementEvents = <AgentEvent>[];
      final replacementCanary = Completer<void>();
      final replacementDone = Completer<void>();
      StreamSubscription<AgentEvent>? first;
      StreamSubscription<AgentEvent>? replacement;
      acp.AcpSessionInputBudgetOwner? firstOwner;
      client.onRawPromptDispatchedForTesting = (owner) {
        firstOwner ??= owner;
      };

      try {
        await client.connect().timeout(const Duration(seconds: 5));
        final session = await client.createSession(cwd: '/workspace');
        first = client
            .sendPrompt(sessionId: session.id, prompt: 'hold first')
            .listen(
              firstEvents.add,
              onError: firstDone.completeError,
              onDone: () {
                firstDoneCount += 1;
                if (!firstDone.isCompleted) firstDone.complete();
              },
            );
        await _waitForFile(promptSeenFile);
        first.pause();

        await client.cancel().timeout(const Duration(seconds: 5));
        expect(client.rawPromptCancelCountForTesting, 1);
        expect(firstEvents, isEmpty);
        await _waitForFile(cancelSeenFile);
        first.resume();
        await firstDone.future.timeout(const Duration(seconds: 5));
        expect(firstDoneCount, 1);
        final backgroundReap = client
            .acpClientForTesting
            .sessionManagerForTesting
            .promptCleanupReapedForTesting(firstOwner!)!;
        await expectLater(
          client
              .sendPrompt(sessionId: session.id, prompt: 'too early')
              .toList(),
          throwsA(isA<StateError>()),
        );
        await releaseLateFile.writeAsString('release');
        await _waitForFile(lateSentFile);
        await backgroundReap.timeout(const Duration(seconds: 5));
        replacement = client
            .sendPrompt(sessionId: session.id, prompt: 'replacement')
            .listen(
              (event) {
                replacementEvents.add(event);
                if (event.text == 'replacement-canary' &&
                    !replacementCanary.isCompleted) {
                  replacementCanary.complete();
                }
              },
              onError: replacementDone.completeError,
              onDone: replacementDone.complete,
            );
        await replacementCanary.future.timeout(const Duration(seconds: 5));
        await releaseResponseFile.writeAsString('release');
        await replacementDone.future.timeout(const Duration(seconds: 5));
        expect(
          replacementEvents.map((event) => event.text),
          contains('replacement-canary'),
        );
        expect(replacementEvents.last.metadata['stopReason'], 'endTurn');
        expect(firstEvents, isEmpty);
        expect(firstDoneCount, 1);
      } finally {
        client.onRawPromptDispatchedForTesting = null;
        first?.resume();
        await first?.cancel();
        await replacement?.cancel();
        await client.dispose();
        await tempDir.delete(recursive: true);
      }
    });
  }

  test(
    'raw stream cancel before owner never sends prompt or leaks phase',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
      final promptSeenFile = File('${tempDir.path}/prompt_seen');
      final agentScript = File(
        '${tempDir.path}/fake_pre_owner_cancel_agent.dart',
      );
      final promptSeenPath = jsonEncode(promptSeenFile.path);
      await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{},
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/new') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'sessionId': 'session-1'},
      }));
    } else if (message['method'] == 'session/prompt') {
      final params = message['params'] as Map<String, dynamic>;
      final prompt = params['prompt'] as List<dynamic>;
      final first = prompt.first as Map<String, dynamic>;
      final text = first['text'];
      if (text == 'cancel before owner') {
        await File($promptSeenPath).writeAsString('unexpected');
      }
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'stopReason': 'end_turn'},
      }));
    }
  }
}
''');
      final client = DartAcpAgentClient(
        agentCommand: _dartExecutable(),
        agentArgs: <String>[agentScript.path],
      );

      try {
        await client.connect().timeout(const Duration(seconds: 5));
        final session = await client.createSession(cwd: '/workspace');
        final first = client
            .sendPrompt(sessionId: session.id, prompt: 'cancel before owner')
            .listen((_) {});
        await first.cancel().timeout(const Duration(seconds: 5));

        final events = await client
            .sendPrompt(sessionId: session.id, prompt: 'replacement')
            .toList()
            .timeout(const Duration(seconds: 5));
        expect(events.last.metadata['stopReason'], 'endTurn');
        expect(await promptSeenFile.exists(), isFalse);
      } finally {
        await client.dispose();
        await tempDir.delete(recursive: true);
      }
    },
  );

  test(
    'raw pre-owner cancel reconnect and dispose settle blocked attachment once',
    () async {
      for (final cause in _RawPreOwnerExit.values) {
        final fixture = await _RawPreOwnerFixture.start();
        final events = <AgentEvent>[];
        final streamErrors = <Object>[];
        final done = Completer<void>.sync();
        StreamSubscription<AgentEvent>? subscription;
        var doneCount = 0;
        try {
          fixture.client.holdNextRawAttachmentConversionForTesting();
          subscription = fixture.client
              .sendPrompt(
                sessionId: fixture.session.id,
                prompt: 'pre-owner-${cause.name}',
                attachments: <PromptAttachment>[fixture.attachment],
              )
              .listen(
                events.add,
                onError: (Object error, StackTrace _) =>
                    streamErrors.add(error),
                onDone: () {
                  doneCount += 1;
                  if (!done.isCompleted) done.complete();
                },
              );
          await fixture.client.rawAttachmentConversionPausedForTesting.timeout(
            const Duration(seconds: 2),
            onTimeout: () => throw StateError(
              'raw attachment conversion never reached the held gate',
            ),
          );

          switch (cause) {
            case _RawPreOwnerExit.cancel:
              await fixture.client.cancel().timeout(
                const Duration(seconds: 2),
                onTimeout: () => throw StateError(
                  'pre-owner cancel did not settle while attachment blocked',
                ),
              );
            case _RawPreOwnerExit.reconnect:
              await fixture.client.connect().timeout(
                const Duration(seconds: 2),
                onTimeout: () => throw StateError(
                  'pre-owner reconnect did not settle while attachment blocked',
                ),
              );
              expect(
                done.isCompleted,
                isTrue,
                reason: 'replacement cannot cross the old finished barrier',
              );
            case _RawPreOwnerExit.dispose:
              await fixture.client.dispose().timeout(
                const Duration(seconds: 2),
                onTimeout: () => throw StateError(
                  'pre-owner dispose did not settle while attachment blocked',
                ),
              );
          }

          await done.future.timeout(
            const Duration(seconds: 2),
            onTimeout: () => throw StateError(
              'pre-owner public stream did not close for ${cause.name}',
            ),
          );
          expect(streamErrors, isEmpty, reason: cause.name);
          expect(doneCount, 1, reason: cause.name);
          if (cause == _RawPreOwnerExit.dispose) {
            expect(events, hasLength(1));
            expect(events.single.type, AgentEventType.error);
            expect(events.single.text, 'ACP connection closed.');
          } else {
            expect(events, isEmpty, reason: cause.name);
          }
          expect(
            fixture.client.rawPromptDispatchCountForTesting,
            0,
            reason: cause.name,
          );
          expect(
            fixture.client.rawPromptCancelCountForTesting,
            0,
            reason: cause.name,
          );
          expect(
            fixture.client.beginPromptTurnCountForTesting,
            0,
            reason: cause.name,
          );
        } finally {
          fixture.client.releaseRawAttachmentConversionForTesting();
          await subscription?.cancel();
          await fixture.dispose();
        }
      }
    },
  );

  test('raw cleanup fatal preserves one cached success terminal', () async {
    final fixture = await _RawStdioFixture.startRawWithBlockedAdmission(
      timeouts: const acp.AcpTimeouts(
        request: Duration(milliseconds: 100),
        permission: Duration(milliseconds: 100),
        promptCancelGrace: Duration(milliseconds: 75),
      ),
    );
    try {
      final eventsFuture = fixture.events.toList();
      fixture.completePromptSuccess();
      await fixture.winnerRecorded.timeout(
        const Duration(seconds: 2),
        onTimeout: () => throw StateError(
          'cached success did not record an owner-bound winner',
        ),
      );
      await fixture.rightRecorded.timeout(
        const Duration(seconds: 2),
        onTimeout: () =>
            throw StateError('cached success did not record a delivery right'),
      );
      fixture.releaseAdmissionReservationOnly();
      await fixture.graceStarted.timeout(const Duration(seconds: 2));
      await fixture.cleanupFatalSeen.timeout(const Duration(seconds: 2));
      final events = await eventsFuture.timeout(const Duration(seconds: 2));
      expect(events, hasLength(1));
      expect(events.single.type, AgentEventType.agentTextDone);
      expect(events.single.text, isEmpty);
      expect(events.single.metadata['kind'], 'turn');
      expect(events.single.metadata['stopReason'], 'endTurn');
      expect(fixture.deliveryClaimCount, 1);
      expect(fixture.streamCloseCount, 1);
    } finally {
      await fixture.dispose();
    }
  });

  test(
    'raw cleanup fatal preserves one cached remote error terminal',
    () async {
      final fixture = await _RawStdioFixture.startRawWithBlockedAdmission(
        timeouts: const acp.AcpTimeouts(
          request: Duration(milliseconds: 100),
          permission: Duration(milliseconds: 100),
          promptCancelGrace: Duration(milliseconds: 75),
        ),
      );
      try {
        final eventsFuture = fixture.events.toList();
        const canary = 'raw-remote-secret-canary';
        fixture.completePromptError(
          code: -32000,
          message: 'fixed remote error',
          data: const <String, Object?>{
            'path': '/private/raw-remote-secret-canary',
            'payload': <String, Object?>{'token': 'raw-remote-secret-canary'},
          },
        );
        await fixture.winnerRecorded.timeout(
          const Duration(seconds: 2),
          onTimeout: () => throw StateError(
            'cached remote error did not record an owner-bound winner',
          ),
        );
        await fixture.rightRecorded.timeout(
          const Duration(seconds: 2),
          onTimeout: () => throw StateError(
            'cached remote error did not record a delivery right',
          ),
        );
        fixture.releaseAdmissionReservationOnly();
        await fixture.graceStarted.timeout(const Duration(seconds: 2));
        await fixture.cleanupFatalSeen.timeout(const Duration(seconds: 2));
        final events = await eventsFuture.timeout(const Duration(seconds: 2));
        final errors = events
            .where((event) => event.type == AgentEventType.error)
            .toList();
        expect(events, hasLength(1));
        expect(errors, hasLength(1));
        expect(errors.single.text, 'fixed remote error');
        expect(errors.single.text, isNot('ACP connection closed.'));
        expect(errors.single.metadata, const <String, Object?>{
          'kind': 'turn',
          'terminalKind': 'remoteError',
        });
        expect(
          jsonEncode(<String, Object?>{
            'text': errors.single.text,
            'metadata': errors.single.metadata,
          }),
          isNot(contains(canary)),
        );
        expect(fixture.deliveryClaimCount, 1);
        expect(fixture.streamCloseCount, 1);
      } finally {
        await fixture.dispose();
      }
    },
  );

  test('raw external close and terminal claim are first wins', () async {
    for (final cause in _RawExternalUnavailableCause.values) {
      for (final closeFirst in <bool>[true, false]) {
        final fixture = await _RawStdioFixture.startRawWithBlockedAdmission();
        try {
          final eventsFuture = fixture.events.toList();
          await fixture.promptSeen.timeout(const Duration(seconds: 2));
          fixture.holdDeliveryClaim();
          fixture.completePromptSuccess();
          await fixture.winnerRecorded.timeout(const Duration(seconds: 2));
          await fixture.rightRecorded.timeout(const Duration(seconds: 2));
          fixture.releaseAdmissionCommit();
          await fixture.preClaimSeen.timeout(const Duration(seconds: 2));
          final unavailable = fixture.unavailableSeen;

          Future<void> makeUnavailable() => switch (cause) {
            _RawExternalUnavailableCause.explicitClose =>
              fixture.client.closePeerExplicitlyForTesting(),
            _RawExternalUnavailableCause.dispose => fixture.client.dispose(),
          };

          if (closeFirst) {
            if (cause == _RawExternalUnavailableCause.dispose) {
              final dispose = makeUnavailable();
              await fixture.streamDone.timeout(const Duration(seconds: 2));
              fixture.releaseDeliveryClaim();
              await dispose;
            } else {
              await makeUnavailable();
              fixture.releaseDeliveryClaim();
            }
            await unavailable.timeout(const Duration(seconds: 2));
          } else {
            if (cause == _RawExternalUnavailableCause.dispose) {
              fixture.holdAfterManagerClaim();
            }
            fixture.releaseDeliveryClaim();
            await fixture.claimSeen.timeout(const Duration(seconds: 2));
            if (cause == _RawExternalUnavailableCause.dispose) {
              await fixture.afterManagerClaimSeen.timeout(
                const Duration(seconds: 2),
              );
              final dispose = makeUnavailable();
              await pumpEventQueue();
              expect(
                fixture.streamIsDone,
                isFalse,
                reason: 'dispose must not close output after manager claim',
              );
              fixture.releaseAfterManagerClaim();
              await dispose;
            } else {
              await makeUnavailable();
            }
            await unavailable.timeout(const Duration(seconds: 2));
          }
          final events = await eventsFuture.timeout(const Duration(seconds: 2));
          final connectionClosed = events.where(
            (event) =>
                event.type == AgentEventType.error &&
                event.text == 'ACP connection closed.',
          );
          final cachedTerminal = events.where(
            (event) => event.type == AgentEventType.agentTextDone,
          );
          expect(
            connectionClosed,
            closeFirst ? hasLength(1) : isEmpty,
            reason: '${cause.name}/closeFirst=$closeFirst',
          );
          expect(
            cachedTerminal,
            closeFirst ? isEmpty : hasLength(1),
            reason: '${cause.name}/closeFirst=$closeFirst',
          );
          expect(fixture.deliveryClaimCount, closeFirst ? 0 : 1);
          expect(fixture.streamCloseCount, 1);
        } finally {
          fixture.releaseDeliveryClaim();
          fixture.releaseAfterManagerClaim();
          await fixture.dispose();
        }
      }
    }
  });

  test(
    'raw cancel after dispatch closes stream while background reap continues',
    () async {
      final fixture = await _RawStdioFixture.startRawWithBlockedAdmission();
      try {
        final eventsFuture = fixture.events.toList();
        await fixture.promptSeen.timeout(const Duration(seconds: 2));
        await fixture.client.cancel().timeout(const Duration(seconds: 2));
        await fixture.streamDone.timeout(const Duration(seconds: 2));
        expect(await eventsFuture.timeout(const Duration(seconds: 2)), isEmpty);
        expect(fixture.cancelCount, 1);
        expect(fixture.deliveryClaimCount, 0);
        expect(fixture.streamCloseCount, 1);
        await expectLater(
          fixture.startReplacement(),
          throwsA(isA<StateError>()),
        );
        fixture.releaseLateSuccess();
        fixture.releaseAdmissionCommit();
        await fixture.backgroundReapDone.timeout(const Duration(seconds: 2));
        expect(await fixture.startReplacement(), isNotEmpty);
      } finally {
        await fixture.dispose();
      }
    },
  );

  test(
    'raw direct reconnect closes transport before waiting for in-flight finish',
    () async {
      final fixture = await _RawStdioFixture.startRawWithBlockedAdmission();
      Future<void>? reconnecting;
      try {
        final eventsFuture = fixture.events.toList();
        var reconnectCompleted = false;
        reconnecting = fixture.client.connect().whenComplete(
          () => reconnectCompleted = true,
        );
        await fixture.streamDone.timeout(const Duration(seconds: 2));
        expect(await eventsFuture.timeout(const Duration(seconds: 2)), isEmpty);
        expect(fixture.cancelCount, 0);
        expect(reconnectCompleted, isFalse);

        await reconnecting.timeout(
          const Duration(seconds: 2),
          onTimeout: () => throw StateError(
            'direct reconnect waited for the old result before transport close',
          ),
        );
        expect(reconnectCompleted, isTrue);
        expect(fixture.client.rawInFlightPromptCountForTesting, 0);
        expect(fixture.cancelCount, 0);
      } finally {
        fixture.releaseLateSuccess();
        fixture.releaseAdmissionCommit();
        try {
          await reconnecting?.timeout(const Duration(seconds: 2));
        } on Object {
          // Keep the RED failure cleanup bounded.
        }
        await fixture.dispose();
      }
    },
  );

  test('raw teardown snapshot rejects listeners on the old client', () async {
    for (final cause in _RawPostOwnerExit.values) {
      final fixture = await _RawStdioFixture.startRawWithBlockedAdmission();
      Future<void>? exiting;
      try {
        final otherSession = await fixture.client.createSession(
          cwd: fixture.tempDir.path,
        );
        final snapshotTaken = Completer<void>.sync();
        fixture.client.onRawTeardownSnapshotForTesting = () {
          if (!snapshotTaken.isCompleted) snapshotTaken.complete();
        };
        fixture.pauseRawPrompt();

        exiting = switch (cause) {
          _RawPostOwnerExit.reconnect => fixture.client.connect(),
          _RawPostOwnerExit.dispose => fixture.client.dispose(),
        };
        await snapshotTaken.future.timeout(const Duration(seconds: 2));
        expect(fixture.client.rawInFlightPromptCountForTesting, 1);

        await expectLater(
          fixture.client
              .sendPrompt(
                sessionId: otherSession.id,
                prompt: 'must not enter the frozen snapshot',
              )
              .toList()
              .timeout(const Duration(seconds: 2)),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              'ACP raw prompt operations are not being accepted.',
            ),
          ),
        );
        expect(fixture.client.rawInFlightPromptCountForTesting, 1);
        expect(fixture.beginPromptTurnCount, 1);
        expect(fixture.wirePromptCount, 1);

        fixture.resumeRawPrompt();
        await exiting.timeout(const Duration(seconds: 2));
        expect(fixture.client.rawInFlightPromptCountForTesting, 0);
        expect(fixture.beginPromptTurnCount, 1);
        expect(fixture.wirePromptCount, 1);
      } finally {
        fixture.client.onRawTeardownSnapshotForTesting = null;
        fixture.resumeRawPrompt();
        try {
          await exiting?.timeout(const Duration(seconds: 2));
        } on Object {
          // Keep failure-path cleanup bounded.
        }
        await fixture.dispose();
      }
    }
  });

  test(
    'raw local admission rejections emit one error without zone leaks',
    () async {
      final zoneErrors = <Object>[];
      final bodyDone = Completer<void>();
      runZonedGuarded(() async {
        Future<void> expectRejected(
          DartAcpAgentClient client,
          String sessionId,
          String expectedMessage,
        ) async {
          final events = <AgentEvent>[];
          final errors = <Object>[];
          final done = Completer<void>.sync();
          var doneCount = 0;
          client
              .sendPrompt(sessionId: sessionId, prompt: 'must reject')
              .listen(
                events.add,
                onError: (Object error, StackTrace _) => errors.add(error),
                onDone: () {
                  doneCount += 1;
                  if (!done.isCompleted) done.complete();
                },
              );
          await done.future.timeout(const Duration(seconds: 2));
          await pumpEventQueue();
          expect(events, isEmpty);
          expect(errors, hasLength(1));
          expect(errors.single, isA<StateError>());
          expect((errors.single as StateError).message, expectedMessage);
          expect(doneCount, 1);
        }

        final beforeConnect = DartAcpAgentClient(
          agentCommand: _dartExecutable(),
        );
        await expectRejected(
          beforeConnect,
          'before-connect',
          'ACP raw prompt operations are not being accepted.',
        );
        await beforeConnect.dispose();
        await expectRejected(
          beforeConnect,
          'after-dispose',
          'ACP raw prompt operations are not being accepted.',
        );

        final failedDir = await Directory.systemTemp.createTemp(
          'raw-failed-connect-',
        );
        final failedScript = File('${failedDir.path}/failed_agent.dart');
        await failedScript.writeAsString('void main() {}');
        final failedConnect = DartAcpAgentClient(
          agentCommand: _dartExecutable(),
          agentArgs: <String>[failedScript.path],
        );
        try {
          await expectLater(
            failedConnect.connect().timeout(const Duration(seconds: 2)),
            throwsA(anything),
          );
          await expectRejected(
            failedConnect,
            'failed-connect',
            'ACP raw prompt operations are not being accepted.',
          );
        } finally {
          await failedConnect.dispose();
          await failedDir.delete(recursive: true);
        }

        final fixture = await _RawStdioFixture.startRawWithBlockedAdmission();
        Future<void>? reconnecting;
        try {
          await expectRejected(
            fixture.client,
            fixture.session.id,
            'An ACP prompt operation is already active.',
          );
          final otherSession = await fixture.client.createSession(
            cwd: fixture.tempDir.path,
          );
          final snapshotTaken = Completer<void>.sync();
          fixture.client.onRawTeardownSnapshotForTesting = () {
            if (!snapshotTaken.isCompleted) snapshotTaken.complete();
          };
          fixture.pauseRawPrompt();
          reconnecting = fixture.client.connect();
          await snapshotTaken.future.timeout(const Duration(seconds: 2));
          await expectRejected(
            fixture.client,
            otherSession.id,
            'ACP raw prompt operations are not being accepted.',
          );
          fixture.resumeRawPrompt();
          await reconnecting.timeout(const Duration(seconds: 2));
        } finally {
          fixture.client.onRawTeardownSnapshotForTesting = null;
          fixture.resumeRawPrompt();
          try {
            await reconnecting?.timeout(const Duration(seconds: 2));
          } on Object {
            // Keep failure-path cleanup bounded.
          }
          await fixture.dispose();
        }

        await pumpEventQueue();
        bodyDone.complete();
      }, (error, _) => zoneErrors.add(error));

      await bodyDone.future.timeout(const Duration(seconds: 15));
      await pumpEventQueue();
      expect(zoneErrors, isEmpty);
    },
  );

  test(
    'raw post-owner cancel reconnect and dispose wait for in-flight finish',
    () async {
      for (final cause in _RawPostOwnerExit.values) {
        final fixture = await _RawStdioFixture.startRawWithBlockedAdmission();
        try {
          final eventsFuture = fixture.events.toList();
          await fixture.client.cancel().timeout(const Duration(seconds: 2));
          await fixture.cancelSeen.timeout(const Duration(seconds: 2));
          await fixture.streamDone.timeout(const Duration(seconds: 2));
          expect(
            await eventsFuture.timeout(const Duration(seconds: 2)),
            isEmpty,
          );
          expect(
            fixture.client.rawInFlightPromptCountForTesting,
            1,
            reason: cause.name,
          );
          var exitCompleted = false;
          final exiting = switch (cause) {
            _RawPostOwnerExit.reconnect => fixture.client.connect(),
            _RawPostOwnerExit.dispose => fixture.client.dispose(),
          }.whenComplete(() => exitCompleted = true);
          expect(exitCompleted, isFalse, reason: cause.name);
          expect(
            fixture.client.rawInFlightPromptCountForTesting,
            1,
            reason: cause.name,
          );

          final backgroundReap = fixture.backgroundReapDone;
          fixture.releaseLateSuccess();
          fixture.releaseAdmissionCommit();
          await backgroundReap.timeout(const Duration(seconds: 2));
          await exiting.timeout(const Duration(seconds: 2));
          expect(exitCompleted, isTrue, reason: cause.name);
          expect(
            fixture.client.rawInFlightPromptCountForTesting,
            0,
            reason: cause.name,
          );
        } finally {
          await fixture.dispose();
        }
      }
    },
  );

  test(
    'raw cancel or close before terminal hook cannot backfill right',
    () async {
      for (final closePeer in <bool>[false, true]) {
        for (final lateError in <bool>[false, true]) {
          final fixture = await _RawStdioFixture.startRawWithBlockedAdmission();
          try {
            final eventsFuture = fixture.events.toList();
            await fixture.promptSeen.timeout(const Duration(seconds: 2));
            if (closePeer) {
              final unavailable = fixture.unavailableSeen;
              await fixture.client.closePeerExplicitlyForTesting();
              await unavailable.timeout(const Duration(seconds: 2));
            } else {
              await fixture.client.cancel().timeout(const Duration(seconds: 2));
              await fixture.cancelSeen.timeout(const Duration(seconds: 2));
            }
            expect(
              fixture.acpClient.hasPromptDeliveryRight(fixture.owner),
              isFalse,
            );
            if (lateError) {
              fixture.releaseLateError();
            } else {
              fixture.releaseLateSuccess();
            }
            await fixture.lateTerminalSent.timeout(const Duration(seconds: 2));
            expect(
              fixture.acpClient.hasPromptDeliveryRight(fixture.owner),
              isFalse,
            );
            expect(fixture.deliveryClaimCount, 0);
            expect(fixture.streamCloseCount, 1);
            final events = await eventsFuture.timeout(
              const Duration(seconds: 2),
            );
            expect(
              events.where(
                (event) => event.type == AgentEventType.agentTextDone,
              ),
              isEmpty,
            );
            expect(
              events.where((event) => event.type == AgentEventType.error),
              closePeer ? hasLength(1) : isEmpty,
            );
          } finally {
            await fixture.dispose();
          }
        }
      }
    },
  );

  test('raw late success and error after cancel emit zero terminals', () async {
    for (final lateError in <bool>[false, true]) {
      final fixture = await _RawStdioFixture.startRawWithBlockedAdmission();
      try {
        final events = <AgentEvent>[];
        var doneCount = 0;
        final done = Completer<void>.sync();
        fixture.events.listen(
          events.add,
          onDone: () {
            doneCount += 1;
            if (!done.isCompleted) done.complete();
          },
        );
        await fixture.promptSeen.timeout(const Duration(seconds: 2));
        await fixture.client.cancel().timeout(const Duration(seconds: 2));
        await done.future.timeout(const Duration(seconds: 2));
        expect(events, isEmpty);
        expect(doneCount, 1);
        expect(fixture.cancelCount, 1);
        await expectLater(
          fixture.startReplacement(),
          throwsA(isA<StateError>()),
        );
        if (lateError) {
          fixture.releaseLateError();
        } else {
          fixture.releaseLateSuccess();
        }
        fixture.releaseAdmissionCommit();
        await fixture.backgroundReapDone.timeout(const Duration(seconds: 2));
        expect(events, isEmpty);
        expect(doneCount, 1);
        expect(await fixture.startReplacement(), isNotEmpty);
      } finally {
        await fixture.dispose();
      }
    }
  });

  test(
    'raw fs read write and terminal allow side effects before success',
    () async {
      for (final method in const <String>[
        'fs/read_text_file',
        'fs/write_text_file',
        'terminal/create',
      ]) {
        final fixture = await _RawStdioFixture.startRawWithBlockedAdmission(
          providerMethod: method,
        );
        try {
          final eventsFuture = fixture.events.toList();
          await fixture.promptSeen.timeout(const Duration(seconds: 2));
          await fixture.sideEffectStarted.timeout(const Duration(seconds: 2));
          fixture.releaseAdmissionCommit();
          final providerResponse = await fixture.providerResponse.timeout(
            const Duration(seconds: 2),
          );
          expect(providerResponse['error'], isNull, reason: method);
          fixture.completePromptSuccess();
          await fixture.winnerRecorded.timeout(const Duration(seconds: 2));
          await fixture.rightRecorded.timeout(const Duration(seconds: 2));
          final events = await eventsFuture.timeout(const Duration(seconds: 2));
          expect(fixture.deliveryClaimCount, 1, reason: method);
          expect(fixture.streamCloseCount, 1, reason: method);
          final promptDone = events
              .where((event) => event.type == AgentEventType.agentTextDone)
              .toList();
          final promptErrors = events
              .where((event) => event.type == AgentEventType.error)
              .toList();
          expect(promptDone, hasLength(1), reason: method);
          expect(promptErrors, isEmpty, reason: method);
          expect(
            <AgentEvent>[...promptDone, ...promptErrors],
            hasLength(1),
            reason: method,
          );
        } finally {
          await fixture.dispose();
        }
      }
    },
  );

  test(
    'raw fs read write and terminal allow side effects before remote error',
    () async {
      for (final method in const <String>[
        'fs/read_text_file',
        'fs/write_text_file',
        'terminal/create',
      ]) {
        final fixture = await _RawStdioFixture.startRawWithBlockedAdmission(
          providerMethod: method,
        );
        try {
          final eventsFuture = fixture.events.toList();
          await fixture.promptSeen.timeout(const Duration(seconds: 2));
          await fixture.sideEffectStarted.timeout(const Duration(seconds: 2));
          fixture.releaseAdmissionCommit();
          final providerResponse = await fixture.providerResponse.timeout(
            const Duration(seconds: 2),
          );
          expect(providerResponse['error'], isNull, reason: method);
          fixture.completePromptError();
          await fixture.winnerRecorded.timeout(const Duration(seconds: 2));
          await fixture.rightRecorded.timeout(const Duration(seconds: 2));
          final events = await eventsFuture.timeout(const Duration(seconds: 2));
          expect(fixture.deliveryClaimCount, 1, reason: method);
          expect(fixture.streamCloseCount, 1, reason: method);
          final promptDone = events
              .where((event) => event.type == AgentEventType.agentTextDone)
              .toList();
          final promptErrors = events
              .where((event) => event.type == AgentEventType.error)
              .toList();
          expect(promptDone, isEmpty, reason: method);
          expect(promptErrors, hasLength(1), reason: method);
          expect(
            <AgentEvent>[...promptDone, ...promptErrors],
            hasLength(1),
            reason: method,
          );
        } finally {
          await fixture.dispose();
        }
      }
    },
  );

  test(
    'raw transport request fatal explicit close and dispose before claim revoke right',
    () async {
      for (final first in _RawUnavailableFirst.values) {
        final fixture = await _RawStdioFixture.startRawWithBlockedAdmission(
          timeouts: const acp.AcpTimeouts(
            request: Duration(milliseconds: 250),
            permission: Duration(milliseconds: 100),
            promptCancelGrace: Duration(milliseconds: 750),
          ),
        );
        try {
          final eventsFuture = fixture.events.toList();
          await fixture.promptSeen.timeout(const Duration(seconds: 2));
          fixture.holdDeliveryClaim();
          fixture.completePromptSuccess();
          await fixture.winnerRecorded.timeout(const Duration(seconds: 2));
          await fixture.rightRecorded.timeout(const Duration(seconds: 2));
          fixture.releaseAdmissionCommit();
          await fixture.preClaimSeen.timeout(const Duration(seconds: 2));
          await fixture.winUnavailableBeforeClaim(first);
          fixture.releaseDeliveryClaim();
          expect(
            fixture.acpClient.hasPromptDeliveryRight(fixture.owner),
            isFalse,
            reason: first.name,
          );
          expect(fixture.deliveryClaimCount, 0, reason: first.name);
          expect(fixture.streamCloseCount, 1, reason: first.name);
          final events = await eventsFuture.timeout(const Duration(seconds: 2));
          expect(events, hasLength(1), reason: first.name);
          expect(events.single.type, AgentEventType.error, reason: first.name);
          expect(
            events.single.text,
            'ACP connection closed.',
            reason: first.name,
          );
        } finally {
          fixture.releaseDeliveryClaim();
          await fixture.dispose();
        }
      }
    },
  );

  test(
    'raw connection closed and close are once across callback orders',
    () async {
      for (final order in _RawCloseRaceOrder.values) {
        final fixture = await _RawStdioFixture.startRawWithBlockedAdmission();
        try {
          final eventsFuture = fixture.events.toList();
          await fixture.promptSeen.timeout(const Duration(seconds: 2));
          switch (order) {
            case _RawCloseRaceOrder.listenerFirst:
              fixture.requestTransportClose();
              await fixture.unavailableSeen.timeout(const Duration(seconds: 2));
            case _RawCloseRaceOrder.resultErrorFirst:
              fixture.holdUnavailablePublication();
              final resultError = fixture.connectionResultErrorSeen;
              fixture.requestTransportClose();
              await fixture.unavailablePublicationPaused.timeout(
                const Duration(seconds: 2),
              );
              await resultError.timeout(const Duration(seconds: 2));
              fixture.releaseUnavailablePublication();
              await fixture.unavailableSeen.timeout(const Duration(seconds: 2));
            case _RawCloseRaceOrder.userCancelFirst:
              await fixture.client.cancel().timeout(const Duration(seconds: 2));
              await fixture.cancelSeen.timeout(const Duration(seconds: 2));
              await fixture.streamDone.timeout(const Duration(seconds: 2));
              fixture.requestTransportClose();
              await fixture.unavailableSeen.timeout(const Duration(seconds: 2));
          }
          final events = await eventsFuture.timeout(const Duration(seconds: 2));
          final connectionClosed = events.where(
            (event) =>
                event.type == AgentEventType.error &&
                event.text == 'ACP connection closed.',
          );
          expect(
            connectionClosed,
            order == _RawCloseRaceOrder.userCancelFirst
                ? isEmpty
                : hasLength(1),
            reason: order.name,
          );
          expect(events.length, connectionClosed.length, reason: order.name);
          expect(fixture.streamCloseCount, 1, reason: order.name);
        } finally {
          fixture.releaseUnavailablePublication();
          await fixture.dispose();
        }
      }
    },
  );

  test('locally invalidated raw stream cancel has no zone leak', () async {
    final zoneErrors = <Object>[];
    final bodyDone = Completer<void>();
    runZonedGuarded(
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'ianvs-acp-test-',
        );
        final promptSeenFile = File('${tempDir.path}/prompt_seen');
        final releasePromptFile = File('${tempDir.path}/release_prompt');
        final agentScript = File(
          '${tempDir.path}/fake_stale_stream_cancel_agent.dart',
        );
        final promptSeenPath = jsonEncode(promptSeenFile.path);
        final releasePromptPath = jsonEncode(releasePromptFile.path);
        await agentScript.writeAsString('''
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{
            'sessionCapabilities': <String, dynamic>{'close': true},
          },
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/new') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'sessionId': 'session-1'},
      }));
    } else if (message['method'] == 'session/prompt') {
      await File($promptSeenPath).writeAsString('prompted');
      final promptId = message['id'];
      unawaited(() async {
        while (!await File($releasePromptPath).exists()) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        stdout.writeln(jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': promptId,
          'result': <String, dynamic>{'stopReason': 'cancelled'},
        }));
      }());
    } else if (message['method'] == 'session/close') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{},
      }));
    }
  }
}
''');
        final client = DartAcpAgentClient(
          agentCommand: _dartExecutable(),
          agentArgs: <String>[agentScript.path],
        );
        StreamSubscription<AgentEvent>? subscription;
        final streamDone = Completer<void>.sync();
        final streamErrors = <Object>[];
        acp.AcpSessionInputBudgetOwner? owner;
        client.onRawPromptDispatchedForTesting = (value) => owner ??= value;
        final unavailableStates = <acp.AcpPeerUnavailableState>[];
        final unavailableSubscription = client.peerUnavailableForTesting.listen(
          unavailableStates.add,
        );

        try {
          await client.connect().timeout(const Duration(seconds: 5));
          final session = await client.createSession(cwd: '/workspace');
          subscription = client
              .sendPrompt(sessionId: session.id, prompt: 'hold stale')
              .listen(
                (_) {},
                onError: (Object error, StackTrace _) =>
                    streamErrors.add(error),
                onDone: streamDone.complete,
              );
          await _waitForFile(promptSeenFile);
          final closing = client
              .closeSession(sessionId: session.id)
              .then<({Object? error, StackTrace? stackTrace})>(
                (_) => (error: null, stackTrace: null),
                onError: (Object error, StackTrace stackTrace) =>
                    (error: error, stackTrace: stackTrace),
              );
          await streamDone.future.timeout(const Duration(seconds: 5));
          expect(client.rawPromptCancelCountForTesting, 0);
          expect(client.rawStreamCloseCountForTesting(owner!), 1);
          final cleanup = client.acpClientForTesting.sessionManagerForTesting
              .promptCleanupReapedForTesting(owner!);
          await releasePromptFile.writeAsString('release');
          if (cleanup != null) {
            await cleanup.timeout(const Duration(seconds: 5));
          }
          final closeOutcome = await closing.timeout(
            const Duration(seconds: 5),
          );
          final closeError = closeOutcome.error;
          expect(
            closeError,
            isNull,
            reason: 'peer unavailable states: $unavailableStates',
          );

          Object? cancelError;
          try {
            await subscription.cancel().timeout(const Duration(seconds: 5));
          } on Object catch (error) {
            cancelError = error;
          }
          subscription = null;
          expect(cancelError, isNull);
          expect(streamErrors, isEmpty);
          expect(zoneErrors, isEmpty);
        } finally {
          client.onRawPromptDispatchedForTesting = null;
          try {
            await subscription?.cancel().timeout(const Duration(seconds: 1));
          } on Object {
            // Keep failure-path cleanup bounded.
          }
          await unavailableSubscription.cancel();
          await client.dispose();
          await tempDir.delete(recursive: true);
        }
        bodyDone.complete();
      },
      (error, _) {
        zoneErrors.add(error);
        if (!bodyDone.isCompleted) bodyDone.complete();
      },
    );

    await bodyDone.future.timeout(const Duration(seconds: 10));
    expect(zoneErrors, isEmpty);
  });

  test(
    'explicit and stream raw cancel settle once without zone leak',
    () async {
      final zoneErrors = <Object>[];
      final bodyDone = Completer<void>();
      runZonedGuarded(
        () async {
          final tempDir = await Directory.systemTemp.createTemp(
            'ianvs-acp-test-',
          );
          final promptSeenFile = File('${tempDir.path}/prompt_seen');
          final cancelCountFile = File('${tempDir.path}/cancel_count');
          final releaseFirstFile = File('${tempDir.path}/release_first');
          final agentScript = File(
            '${tempDir.path}/fake_concurrent_cancel_agent.dart',
          );
          final promptSeenPath = jsonEncode(promptSeenFile.path);
          final cancelCountPath = jsonEncode(cancelCountFile.path);
          final releaseFirstPath = jsonEncode(releaseFirstFile.path);
          await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  var promptCount = 0;
  var cancelCount = 0;
  Object? firstPromptId;
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{},
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/new') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'sessionId': 'session-1'},
      }));
    } else if (message['method'] == 'session/prompt') {
      promptCount += 1;
      if (promptCount == 1) {
        firstPromptId = message['id'];
        await File($promptSeenPath).writeAsString('prompted');
      } else {
        stdout.writeln(jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': message['id'],
          'result': <String, dynamic>{'stopReason': 'end_turn'},
        }));
      }
    } else if (message['method'] == 'session/cancel') {
      cancelCount += 1;
      await File($cancelCountPath).writeAsString(cancelCount.toString());
      while (!await File($releaseFirstPath).exists()) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': firstPromptId,
        'result': <String, dynamic>{'stopReason': 'cancelled'},
      }));
    }
  }
}
''');
          final client = DartAcpAgentClient(
            agentCommand: _dartExecutable(),
            agentArgs: <String>[agentScript.path],
          );
          StreamSubscription<AgentEvent>? subscription;
          acp.AcpSessionInputBudgetOwner? owner;
          client.onRawPromptDispatchedForTesting = (value) => owner ??= value;

          try {
            await client.connect().timeout(const Duration(seconds: 5));
            final session = await client.createSession(cwd: '/workspace');
            subscription = client
                .sendPrompt(sessionId: session.id, prompt: 'hold concurrent')
                .listen((_) {});
            await _waitForFile(promptSeenFile);

            final explicitCancel = client.cancel();
            final streamCancel = subscription.cancel();
            await Future.wait<void>(<Future<void>>[
              explicitCancel,
              streamCancel,
            ]).timeout(const Duration(seconds: 5));
            subscription = null;
            await _waitForFile(cancelCountFile);
            expect(await cancelCountFile.readAsString(), '1');
            expect(client.rawStreamCloseCountForTesting(owner!), 1);
            final backgroundReap = client
                .acpClientForTesting
                .sessionManagerForTesting
                .promptCleanupReapedForTesting(owner!)!;
            await releaseFirstFile.writeAsString('release');
            await backgroundReap.timeout(const Duration(seconds: 5));
            expect(zoneErrors, isEmpty);

            final events = await client
                .sendPrompt(sessionId: session.id, prompt: 'replacement')
                .toList()
                .timeout(const Duration(seconds: 5));
            expect(events.last.metadata['stopReason'], 'endTurn');
          } finally {
            client.onRawPromptDispatchedForTesting = null;
            await subscription?.cancel();
            await client.dispose();
            await tempDir.delete(recursive: true);
          }
          bodyDone.complete();
        },
        (error, _) {
          zoneErrors.add(error);
          if (!bodyDone.isCompleted) bodyDone.complete();
        },
      );

      await bodyDone.future.timeout(const Duration(seconds: 10));
      expect(zoneErrors, isEmpty);
    },
  );

  for (final lateOutcome in const <String>['success', 'error']) {
    test(
      'raw close drops held late $lateOutcome and preserves other session',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'ianvs-acp-test-',
        );
        final firstSeenFile = File('${tempDir.path}/first_seen');
        final otherSeenFile = File('${tempDir.path}/other_seen');
        final releaseLateFile = File('${tempDir.path}/release_late');
        final agentScript = File('${tempDir.path}/fake_close_held_agent.dart');
        final firstSeenPath = jsonEncode(firstSeenFile.path);
        final otherSeenPath = jsonEncode(otherSeenFile.path);
        final releaseLatePath = jsonEncode(releaseLateFile.path);
        final lateOutcomeLiteral = jsonEncode(lateOutcome);
        await agentScript.writeAsString('''
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  Object? firstPromptId;
  var newCount = 0;
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{
            'sessionCapabilities': <String, dynamic>{'close': true},
          },
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/new') {
      newCount += 1;
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'sessionId': newCount == 1 ? 'session-a' : 'session-b',
        },
      }));
    } else if (message['method'] == 'session/prompt') {
      final params = message['params'] as Map<String, dynamic>;
      if (params['sessionId'] == 'session-a') {
        firstPromptId = message['id'];
        await File($firstSeenPath).writeAsString('seen');
        unawaited(() async {
          final release = File($releaseLatePath);
          while (!await release.exists()) {
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
          if ($lateOutcomeLiteral == 'success') {
            stdout.writeln(jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': firstPromptId,
              'result': <String, dynamic>{'stopReason': 'end_turn'},
            }));
          } else {
            stdout.writeln(jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': firstPromptId,
              'error': <String, dynamic>{
                'code': -32000,
                'message': 'fixed late close failure',
              },
            }));
          }
        }());
      } else {
        await File($otherSeenPath).writeAsString('seen');
      }
    } else if (message['method'] == 'session/close') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{},
      }));
    }
  }
}
''');
        final client = DartAcpAgentClient(
          agentCommand: _dartExecutable(),
          agentArgs: <String>[agentScript.path],
        );

        try {
          await client.connect().timeout(const Duration(seconds: 5));
          final sessionA = await client.createSession(cwd: '/workspace');
          final sessionB = await client.createSession(cwd: '/workspace');
          final firstEvents = client
              .sendPrompt(sessionId: sessionA.id, prompt: 'hold a')
              .toList();
          await _waitForFile(firstSeenFile);
          var otherCompleted = false;
          final otherEvents = client
              .sendPrompt(sessionId: sessionB.id, prompt: 'hold b')
              .toList()
              .whenComplete(() => otherCompleted = true);
          await _waitForFile(otherSeenFile);

          final closing = client.closeSession(sessionId: sessionA.id);
          expect(
            await firstEvents.timeout(const Duration(seconds: 5)),
            isEmpty,
          );
          expect(otherCompleted, isFalse);

          await releaseLateFile.writeAsString('release');
          await closing.timeout(const Duration(seconds: 5));
          expect(otherCompleted, isFalse);

          await client.cancel().timeout(const Duration(seconds: 5));
          expect(
            await otherEvents.timeout(const Duration(seconds: 5)),
            isEmpty,
          );
        } finally {
          await client.dispose();
          await tempDir.delete(recursive: true);
        }
      },
    );
  }

  test(
    'raw dispose completes every held prompt with connection closed once',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
      final firstSeenFile = File('${tempDir.path}/first_seen');
      final secondSeenFile = File('${tempDir.path}/second_seen');
      final agentScript = File('${tempDir.path}/fake_dispose_held_agent.dart');
      final firstSeenPath = jsonEncode(firstSeenFile.path);
      final secondSeenPath = jsonEncode(secondSeenFile.path);
      await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  var newCount = 0;
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{},
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/new') {
      newCount += 1;
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'sessionId': 'session-' + newCount.toString(),
        },
      }));
    } else if (message['method'] == 'session/prompt') {
      final params = message['params'] as Map<String, dynamic>;
      final target = params['sessionId'] == 'session-1'
          ? File($firstSeenPath)
          : File($secondSeenPath);
      await target.writeAsString('seen');
    }
  }
}
''');
      final client = DartAcpAgentClient(
        agentCommand: _dartExecutable(),
        agentArgs: <String>[agentScript.path],
      );

      try {
        await client.connect().timeout(const Duration(seconds: 5));
        final first = await client.createSession(cwd: '/workspace');
        final second = await client.createSession(cwd: '/workspace');
        final firstEvents = client
            .sendPrompt(sessionId: first.id, prompt: 'hold first')
            .toList();
        final secondEvents = client
            .sendPrompt(sessionId: second.id, prompt: 'hold second')
            .toList();
        await _waitForFile(firstSeenFile);
        await _waitForFile(secondSeenFile);

        await client.dispose().timeout(const Duration(seconds: 5));
        for (final events in <List<AgentEvent>>[
          await firstEvents.timeout(const Duration(seconds: 5)),
          await secondEvents.timeout(const Duration(seconds: 5)),
        ]) {
          expect(events, hasLength(1));
          expect(events.single.type, AgentEventType.error);
          expect(events.single.text, 'ACP connection closed.');
        }
      } finally {
        await client.dispose();
        await tempDir.delete(recursive: true);
      }
    },
  );

  test('paused raw prompt close waits for public stream settlement', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final promptSeenFile = File('${tempDir.path}/prompt_seen');
    final releasePromptFile = File('${tempDir.path}/release_prompt');
    final agentScript = File('${tempDir.path}/fake_paused_close_agent.dart');
    final promptSeenPath = jsonEncode(promptSeenFile.path);
    final releasePromptPath = jsonEncode(releasePromptFile.path);
    await agentScript.writeAsString('''
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{
            'sessionCapabilities': <String, dynamic>{'close': true},
          },
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/new') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'sessionId': 'session-1'},
      }));
    } else if (message['method'] == 'session/prompt') {
      await File($promptSeenPath).writeAsString('seen');
      final promptId = message['id'];
      unawaited(() async {
        while (!await File($releasePromptPath).exists()) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        stdout.writeln(jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': promptId,
          'result': <String, dynamic>{'stopReason': 'cancelled'},
        }));
      }());
    } else if (message['method'] == 'session/close') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{},
      }));
    }
  }
}
''');
    final client = DartAcpAgentClient(
      agentCommand: _dartExecutable(),
      agentArgs: <String>[agentScript.path],
    );
    StreamSubscription<AgentEvent>? subscription;
    final streamDone = Completer<void>.sync();
    acp.AcpSessionInputBudgetOwner? owner;
    client.onRawPromptDispatchedForTesting = (value) => owner ??= value;

    try {
      await client.connect().timeout(const Duration(seconds: 5));
      final session = await client.createSession(cwd: '/workspace');
      subscription = client
          .sendPrompt(sessionId: session.id, prompt: 'pause close')
          .listen((_) {}, onDone: streamDone.complete);
      await _waitForFile(promptSeenFile);
      subscription.pause();

      var closeCompleted = false;
      final closing = client
          .closeSession(sessionId: session.id)
          .then<({Object? error, StackTrace? stackTrace})>(
            (_) {
              closeCompleted = true;
              return (error: null, stackTrace: null);
            },
            onError: (Object error, StackTrace stackTrace) {
              closeCompleted = true;
              return (error: error, stackTrace: stackTrace);
            },
          );
      expect(closeCompleted, isFalse);
      expect(client.rawPromptCancelCountForTesting, 0);
      subscription.resume();
      await streamDone.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () => throw StateError('paused close public done timed out'),
      );
      final cleanup = client.acpClientForTesting.sessionManagerForTesting
          .promptCleanupReapedForTesting(owner!);
      await releasePromptFile.writeAsString('release');
      if (cleanup != null) {
        await cleanup.timeout(
          const Duration(seconds: 2),
          onTimeout: () => throw StateError('paused close reap timed out'),
        );
      }
      final closeOutcome = await closing.timeout(
        const Duration(seconds: 2),
        onTimeout: () => throw StateError('paused close completion timed out'),
      );
      expect(closeOutcome.error, isNull);
    } finally {
      client.onRawPromptDispatchedForTesting = null;
      subscription?.resume();
      await subscription?.cancel();
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'paused raw prompt dispose waits for public stream settlement',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
      final promptSeenFile = File('${tempDir.path}/prompt_seen');
      final agentScript = File(
        '${tempDir.path}/fake_paused_dispose_agent.dart',
      );
      final promptSeenPath = jsonEncode(promptSeenFile.path);
      await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{},
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/new') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'sessionId': 'session-1'},
      }));
    } else if (message['method'] == 'session/prompt') {
      await File($promptSeenPath).writeAsString('seen');
    }
  }
}
''');
      final client = DartAcpAgentClient(
        agentCommand: _dartExecutable(),
        agentArgs: <String>[agentScript.path],
      );
      StreamSubscription<AgentEvent>? subscription;
      final events = <AgentEvent>[];
      final streamDone = Completer<void>.sync();
      acp.AcpSessionInputBudgetOwner? owner;
      client.onRawPromptDispatchedForTesting = (value) => owner ??= value;

      try {
        await client.connect().timeout(const Duration(seconds: 5));
        final session = await client.createSession(cwd: '/workspace');
        subscription = client
            .sendPrompt(sessionId: session.id, prompt: 'pause dispose')
            .listen(events.add, onDone: streamDone.complete);
        await _waitForFile(promptSeenFile);
        subscription.pause();

        var disposeCompleted = false;
        final disposing = client.dispose().whenComplete(
          () => disposeCompleted = true,
        );
        expect(disposeCompleted, isFalse);
        expect(client.rawPromptCancelCountForTesting, 0);
        subscription.resume();
        await streamDone.future.timeout(const Duration(seconds: 2));
        await disposing.timeout(const Duration(seconds: 2));
        expect(events, hasLength(1));
        expect(events.single.type, AgentEventType.error);
        expect(events.single.text, 'ACP connection closed.');
        expect(owner, isNotNull);
      } finally {
        client.onRawPromptDispatchedForTesting = null;
        subscription?.resume();
        await subscription?.cancel();
        await client.dispose();
        await tempDir.delete(recursive: true);
      }
    },
  );

  test(
    'unlistened raw prompt does not reserve or cancel an operation',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
      final agentScript = File('${tempDir.path}/fake_lazy_prompt_agent.dart');
      await agentScript.writeAsString(r'''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{},
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/new') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'sessionId': 'session-1'},
      }));
    } else if (message['method'] == 'session/prompt') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'stopReason': 'end_turn'},
      }));
    }
  }
}
''');
      final client = DartAcpAgentClient(
        agentCommand: _dartExecutable(),
        agentArgs: <String>[agentScript.path],
      );

      try {
        await client.connect().timeout(const Duration(seconds: 5));
        final session = await client.createSession(cwd: '/workspace');
        client.sendPrompt(sessionId: session.id, prompt: 'never listened');
        await client.cancel();

        final events = await client
            .sendPrompt(sessionId: session.id, prompt: 'real prompt')
            .toList()
            .timeout(const Duration(seconds: 5));
        expect(events.last.metadata['stopReason'], 'endTurn');
      } finally {
        await client.dispose();
        await tempDir.delete(recursive: true);
      }
    },
  );

  test('cancelled turn does not cancel permissions in the next turn', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final firstPromptStartedFile = File('${tempDir.path}/first_prompt_started');
    final cancelSeenFile = File('${tempDir.path}/cancel_seen');
    final releaseFirstFile = File('${tempDir.path}/release_first');
    final permissionResponseFile = File(
      '${tempDir.path}/permission_response.json',
    );
    final agentScript = File('${tempDir.path}/fake_cancelled_turn_agent.dart');
    final firstPromptStartedPath = jsonEncode(firstPromptStartedFile.path);
    final cancelSeenPath = jsonEncode(cancelSeenFile.path);
    final releaseFirstPath = jsonEncode(releaseFirstFile.path);
    final permissionResponsePath = jsonEncode(permissionResponseFile.path);
    await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  Object? firstPromptId;
  Object? secondPromptId;
  var promptCount = 0;
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{},
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/new') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'sessionId': 'session-1'},
      }));
    } else if (message['method'] == 'session/prompt') {
      promptCount += 1;
      if (promptCount == 1) {
        firstPromptId = message['id'];
        await File($firstPromptStartedPath).writeAsString('started');
      } else {
        secondPromptId = message['id'];
        stdout.writeln(jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': 'permission-second-turn',
          'method': 'session/request_permission',
          'params': <String, dynamic>{
            'sessionId': 'session-1',
            'toolCall': <String, dynamic>{
              'title': 'Run second turn command',
              'kind': 'execute',
            },
            'options': <Map<String, dynamic>>[
              <String, dynamic>{
                'optionId': 'allow-once',
                'kind': 'allow_once',
                'name': 'Allow once',
              },
              <String, dynamic>{
                'optionId': 'reject-once',
                'kind': 'reject_once',
                'name': 'Reject once',
              },
            ],
          },
        }));
      }
    } else if (message['method'] == 'session/cancel') {
      await File($cancelSeenPath).writeAsString('cancelled');
      while (!await File($releaseFirstPath).exists()) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': firstPromptId,
        'result': <String, dynamic>{'stopReason': 'cancelled'},
      }));
    } else if (message['id'] == 'permission-second-turn') {
      await File($permissionResponsePath).writeAsString(jsonEncode(message));
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': secondPromptId,
        'result': <String, dynamic>{'stopReason': 'end_turn'},
      }));
    }
  }
}
''');

    final client = DartAcpAgentClient(
      agentCommand: _dartExecutable(),
      agentArgs: [agentScript.path],
    );
    final secondPermission = Completer<AcpPermissionRequest>();
    acp.AcpSessionInputBudgetOwner? firstOwner;
    client.onRawPromptDispatchedForTesting = (owner) {
      firstOwner ??= owner;
    };
    final subscription = client.permissionRequests.listen((request) {
      if (!secondPermission.isCompleted) {
        secondPermission.complete(request);
      }
    });

    try {
      await client.connect().timeout(const Duration(seconds: 5));
      final session = await client.createSession(cwd: '/workspace');

      final firstTurn = client
          .sendPrompt(sessionId: session.id, prompt: 'first turn')
          .toList();
      await _waitForFile(firstPromptStartedFile);
      await client.cancel();
      await _waitForFile(cancelSeenFile);
      await firstTurn.timeout(const Duration(seconds: 5));
      final backgroundReap = client.acpClientForTesting.sessionManagerForTesting
          .promptCleanupReapedForTesting(firstOwner!)!;
      await expectLater(
        client.sendPrompt(sessionId: session.id, prompt: 'too early').toList(),
        throwsA(isA<StateError>()),
      );
      await releaseFirstFile.writeAsString('release');
      await backgroundReap.timeout(const Duration(seconds: 5));

      final secondTurn = client
          .sendPrompt(sessionId: session.id, prompt: 'second turn')
          .toList();
      final request = await secondPermission.future.timeout(
        const Duration(seconds: 5),
      );
      expect(request.sessionId, 'session-1');
      await client.respondToPermissionRequest(
        id: request.id,
        decision: AcpPermissionDecision.allow,
        selectedOptionId: 'allow-once',
      );
      await secondTurn.timeout(const Duration(seconds: 5));

      await _waitForFile(permissionResponseFile);
      final permissionResponse =
          jsonDecode(await permissionResponseFile.readAsString())
              as Map<String, dynamic>;
      expect(
        permissionResponse['result'],
        containsPair('outcome', containsPair('optionId', 'allow-once')),
      );
    } finally {
      client.onRawPromptDispatchedForTesting = null;
      await subscription.cancel();
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'cancels agent permission requests when no interactive UI is listening',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
      final permissionResponseFile = File(
        '${tempDir.path}/permission_response.json',
      );
      final agentScript = File('${tempDir.path}/fake_permission_agent.dart');
      final permissionResponsePath = jsonEncode(permissionResponseFile.path);
      await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{},
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/new') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'sessionId': 'session-1'},
      }));
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': 'permission-1',
        'method': 'session/request_permission',
        'params': <String, dynamic>{
          'sessionId': 'session-1',
          'toolCall': <String, dynamic>{
            'title': 'Read file',
            'kind': 'read',
          },
          'options': <Map<String, dynamic>>[
            <String, dynamic>{
              'optionId': 'allow',
              'kind': 'allow_once',
              'name': 'Allow',
            },
            <String, dynamic>{
              'optionId': 'allow-always',
              'kind': 'allow_always',
              'name': 'Always allow',
            },
            <String, dynamic>{
              'optionId': 'deny',
              'kind': 'reject_once',
              'name': 'Deny',
            },
          ],
        },
      }));
    } else if (message['id'] == 'permission-1') {
      await File($permissionResponsePath).writeAsString(jsonEncode(message));
    }
  }
}
''');

      final client = DartAcpAgentClient(
        agentCommand: _dartExecutable(),
        agentArgs: [agentScript.path],
      );

      try {
        await client.connect().timeout(const Duration(seconds: 5));
        await client.createSession(cwd: '/workspace');
        await _waitForFile(permissionResponseFile);

        final permissionResponse =
            jsonDecode(await permissionResponseFile.readAsString())
                as Map<String, dynamic>;
        expect(permissionResponse['id'], 'permission-1');
        expect(
          permissionResponse['result'],
          containsPair('outcome', containsPair('outcome', 'cancelled')),
        );
      } finally {
        await client.dispose();
        await tempDir.delete(recursive: true);
      }
    },
  );

  test(
    'approves agent permission requests through interactive response',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
      final permissionResponseFile = File(
        '${tempDir.path}/permission_response.json',
      );
      final agentScript = File('${tempDir.path}/fake_permission_agent.dart');
      final permissionResponsePath = jsonEncode(permissionResponseFile.path);
      await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{},
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/new') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'sessionId': 'session-1'},
      }));
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': 'permission-1',
        'method': 'session/request_permission',
        'params': <String, dynamic>{
          'sessionId': 'session-1',
          'toolCall': <String, dynamic>{
            'title': 'Read file',
            'kind': 'read',
          },
          'options': <Map<String, dynamic>>[
            <String, dynamic>{
              'optionId': 'allow',
              'kind': 'allow_once',
              'name': 'Allow',
            },
            <String, dynamic>{
              'optionId': 'allow-always',
              'kind': 'allow_always',
              'name': 'Always allow',
            },
            <String, dynamic>{
              'optionId': 'deny',
              'kind': 'reject_once',
              'name': 'Deny',
            },
          ],
        },
      }));
    } else if (message['id'] == 'permission-1') {
      await File($permissionResponsePath).writeAsString(jsonEncode(message));
    }
  }
}
''');

      late final DartAcpAgentClient client;
      client = DartAcpAgentClient(
        agentCommand: _dartExecutable(),
        agentArgs: [agentScript.path],
      );
      final requestCompleter = Completer<AcpPermissionRequest>();
      final subscription = client.permissionRequests.listen((request) {
        if (!requestCompleter.isCompleted) {
          requestCompleter.complete(request);
        }
        unawaited(
          client.respondToPermissionRequest(
            id: request.id,
            decision: AcpPermissionDecision.allow,
            selectedOptionId: 'allow-always',
          ),
        );
      });

      try {
        await client.connect().timeout(const Duration(seconds: 5));
        await client.createSession(cwd: '/workspace');
        final request = await requestCompleter.future.timeout(
          const Duration(seconds: 5),
        );
        await _waitForFile(permissionResponseFile);

        expect(request.displayTitle, 'Read file');
        expect(request.displayKind, 'read');
        expect(request.choices.map((choice) => choice.optionId), const [
          'allow',
          'allow-always',
          'deny',
        ]);
        expect(request.choices.map((choice) => choice.kind), const [
          'allow_once',
          'allow_always',
          'reject_once',
        ]);
        final permissionResponse =
            jsonDecode(await permissionResponseFile.readAsString())
                as Map<String, dynamic>;
        expect(permissionResponse['id'], 'permission-1');
        expect(
          permissionResponse['result'],
          containsPair('outcome', containsPair('outcome', 'selected')),
        );
        expect(
          permissionResponse['result'],
          containsPair('outcome', containsPair('optionId', 'allow-always')),
        );
      } finally {
        await subscription.cancel();
        await client.dispose();
        await tempDir.delete(recursive: true);
      }
    },
  );

  for (final scenario in const [
    (
      name: 'does not turn deny into the only allow option',
      optionId: 'allow-once',
      optionKind: 'allow_once',
      optionName: 'Allow once',
      decision: AcpPermissionDecision.deny,
    ),
    (
      name: 'does not turn allow into the only reject option',
      optionId: 'reject-once',
      optionKind: 'reject_once',
      optionName: 'Reject once',
      decision: AcpPermissionDecision.allow,
    ),
  ]) {
    test(scenario.name, () async {
      final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
      final permissionResponseFile = File(
        '${tempDir.path}/permission_response.json',
      );
      final agentScript = File(
        '${tempDir.path}/fake_single_permission_agent.dart',
      );
      final permissionResponsePath = jsonEncode(permissionResponseFile.path);
      final optionId = jsonEncode(scenario.optionId);
      final optionKind = jsonEncode(scenario.optionKind);
      final optionName = jsonEncode(scenario.optionName);
      await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{},
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/new') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'sessionId': 'session-1'},
      }));
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': 'permission-single',
        'method': 'session/request_permission',
        'params': <String, dynamic>{
          'sessionId': 'session-1',
          'toolCall': <String, dynamic>{
            'title': 'Single choice',
            'kind': 'execute',
          },
          'options': <Map<String, dynamic>>[
            <String, dynamic>{
              'optionId': $optionId,
              'kind': $optionKind,
              'name': $optionName,
            },
          ],
        },
      }));
    } else if (message['id'] == 'permission-single') {
      await File($permissionResponsePath).writeAsString(jsonEncode(message));
    }
  }
}
''');

      final client = DartAcpAgentClient(
        agentCommand: _dartExecutable(),
        agentArgs: [agentScript.path],
      );
      final subscription = client.permissionRequests.listen((request) {
        unawaited(
          client.respondToPermissionRequest(
            id: request.id,
            decision: scenario.decision,
          ),
        );
      });

      try {
        await client.connect().timeout(const Duration(seconds: 5));
        await client.createSession(cwd: '/workspace');
        await _waitForFile(permissionResponseFile);
        final permissionResponse =
            jsonDecode(await permissionResponseFile.readAsString())
                as Map<String, dynamic>;

        expect(
          permissionResponse['result'],
          containsPair('outcome', containsPair('outcome', 'cancelled')),
        );
        expect(
          jsonEncode(permissionResponse),
          isNot(contains(scenario.optionId)),
        );
      } finally {
        await subscription.cancel();
        await client.dispose();
        await tempDir.delete(recursive: true);
      }
    });
  }

  for (final scenario in const [
    (
      name: 'selects allow for string permission options',
      decision: AcpPermissionDecision.allow,
      expectedOptionId: 'allow',
    ),
    (
      name: 'selects deny for string permission options',
      decision: AcpPermissionDecision.deny,
      expectedOptionId: 'deny',
    ),
  ]) {
    test(scenario.name, () async {
      final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
      final permissionResponseFile = File(
        '${tempDir.path}/permission_response.json',
      );
      final agentScript = File(
        '${tempDir.path}/fake_string_permission_agent.dart',
      );
      final permissionResponsePath = jsonEncode(permissionResponseFile.path);
      await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{},
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/new') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'sessionId': 'session-1'},
      }));
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': 'permission-strings',
        'method': 'session/request_permission',
        'params': <String, dynamic>{
          'sessionId': 'session-1',
          'toolCall': <String, dynamic>{
            'title': 'Run command',
            'kind': 'execute',
          },
          'options': <String>['always allow', 'allow', 'deny'],
        },
      }));
    } else if (message['id'] == 'permission-strings') {
      await File($permissionResponsePath).writeAsString(jsonEncode(message));
    }
  }
}
''');

      late final DartAcpAgentClient client;
      client = DartAcpAgentClient(
        agentCommand: _dartExecutable(),
        agentArgs: [agentScript.path],
      );
      final requestCompleter = Completer<AcpPermissionRequest>();
      final subscription = client.permissionRequests.listen((request) {
        if (!requestCompleter.isCompleted) {
          requestCompleter.complete(request);
        }
        unawaited(
          client.respondToPermissionRequest(
            id: request.id,
            decision: scenario.decision,
          ),
        );
      });

      try {
        await client.connect().timeout(const Duration(seconds: 5));
        await client.createSession(cwd: '/workspace');
        final request = await requestCompleter.future.timeout(
          const Duration(seconds: 5),
        );
        await _waitForFile(permissionResponseFile);

        expect(request.options, const ['always allow', 'allow', 'deny']);
        final permissionResponse =
            jsonDecode(await permissionResponseFile.readAsString())
                as Map<String, dynamic>;
        expect(permissionResponse['id'], 'permission-strings');
        expect(
          permissionResponse['result'],
          containsPair('outcome', containsPair('outcome', 'selected')),
        );
        expect(
          permissionResponse['result'],
          containsPair(
            'outcome',
            containsPair('optionId', scenario.expectedOptionId),
          ),
        );
      } finally {
        await subscription.cancel();
        await client.dispose();
        await tempDir.delete(recursive: true);
      }
    });
  }

  test('accepts legacy permission tool call aliases', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final permissionResponseFile = File(
      '${tempDir.path}/permission_response.json',
    );
    final agentScript = File(
      '${tempDir.path}/fake_permission_alias_agent.dart',
    );
    final permissionResponsePath = jsonEncode(permissionResponseFile.path);
    await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{},
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/new') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'sessionId': 'session-1'},
      }));
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': 'permission-aliases',
        'method': 'session/request_permission',
        'params': <String, dynamic>{
          'sessionId': 'session-1',
          'toolCall': <String, dynamic>{
            'tool_call_id': 'call-1',
            'tool_name': 'Bash',
            'tool_kind': 'execute',
            'raw_input': <String, dynamic>{'command': 'echo hi'},
          },
          'options': <String>['allow', 'deny'],
        },
      }));
    } else if (message['id'] == 'permission-aliases') {
      await File($permissionResponsePath).writeAsString(jsonEncode(message));
    }
  }
}
''');

    late final DartAcpAgentClient client;
    client = DartAcpAgentClient(
      agentCommand: _dartExecutable(),
      agentArgs: [agentScript.path],
    );
    final requestCompleter = Completer<AcpPermissionRequest>();
    final subscription = client.permissionRequests.listen((request) {
      if (!requestCompleter.isCompleted) {
        requestCompleter.complete(request);
      }
      unawaited(
        client.respondToPermissionRequest(
          id: request.id,
          decision: AcpPermissionDecision.allow,
        ),
      );
    });

    try {
      await client.connect().timeout(const Duration(seconds: 5));
      await client.createSession(cwd: '/workspace');
      final request = await requestCompleter.future.timeout(
        const Duration(seconds: 5),
      );
      await _waitForFile(permissionResponseFile);

      expect(request.displayTitle, 'Bash');
      expect(request.toolName, 'Bash');
      expect(request.displayKind, 'execute');
      expect(request.toolKind, 'execute');
      expect(
        request.metadata['toolCall'],
        containsPair('raw_input', {'command': 'echo hi'}),
      );
      final permissionResponse =
          jsonDecode(await permissionResponseFile.readAsString())
              as Map<String, dynamic>;
      expect(permissionResponse['id'], 'permission-aliases');
      expect(
        permissionResponse['result'],
        containsPair('outcome', containsPair('optionId', 'allow')),
      );
    } finally {
      await subscription.cancel();
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'closeSession cancels pending permission requests for the session',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
      final closeRequestFile = File('${tempDir.path}/close_request.json');
      final permissionResponseFile = File(
        '${tempDir.path}/permission_response.json',
      );
      final agentScript = File(
        '${tempDir.path}/fake_close_permission_agent.dart',
      );
      final closeRequestPath = jsonEncode(closeRequestFile.path);
      final permissionResponsePath = jsonEncode(permissionResponseFile.path);
      await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{
            'sessionCapabilities': <String, dynamic>{'close': true},
          },
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/new') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'sessionId': 'session-close'},
      }));
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': 'permission-close',
        'method': 'session/request_permission',
        'params': <String, dynamic>{
          'sessionId': 'session-close',
          'toolCall': <String, dynamic>{
            'title': 'Read file',
            'kind': 'read',
          },
          'options': <Map<String, dynamic>>[
            <String, dynamic>{
              'optionId': 'allow',
              'kind': 'allow_once',
              'name': 'Allow',
            },
            <String, dynamic>{
              'optionId': 'deny',
              'kind': 'reject_once',
              'name': 'Deny',
            },
          ],
        },
      }));
    } else if (message['method'] == 'session/close') {
      await File($closeRequestPath).writeAsString(jsonEncode(message));
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{},
      }));
    } else if (message['id'] == 'permission-close') {
      await File($permissionResponsePath).writeAsString(jsonEncode(message));
    }
  }
}
''');

      final client = DartAcpAgentClient(
        agentCommand: _dartExecutable(),
        agentArgs: [agentScript.path],
      );
      final requestCompleter = Completer<AcpPermissionRequest>();
      final subscription = client.permissionRequests.listen((request) {
        if (!requestCompleter.isCompleted) {
          requestCompleter.complete(request);
        }
      });

      try {
        await client.connect().timeout(const Duration(seconds: 5));
        final session = await client.createSession(cwd: '/workspace');
        final request = await requestCompleter.future.timeout(
          const Duration(seconds: 5),
        );

        expect(session.id, 'session-close');
        expect(request.sessionId, 'session-close');

        await client.closeSession(sessionId: session.id);
        await _waitForFile(closeRequestFile);
        await _waitForFile(permissionResponseFile);

        final closeRequest =
            jsonDecode(await closeRequestFile.readAsString())
                as Map<String, dynamic>;
        expect(closeRequest['method'], 'session/close');
        expect(
          closeRequest['params'],
          containsPair('sessionId', 'session-close'),
        );

        final permissionResponse =
            jsonDecode(await permissionResponseFile.readAsString())
                as Map<String, dynamic>;
        expect(permissionResponse['id'], 'permission-close');
        expect(
          permissionResponse['result'],
          containsPair('outcome', containsPair('outcome', 'cancelled')),
        );
      } finally {
        await subscription.cancel();
        await client.dispose();
        await tempDir.delete(recursive: true);
      }
    },
  );

  test(
    'closeSession clears wrapper state and permissions on remote failure',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
      final permissionResponseFile = File(
        '${tempDir.path}/permission_response.json',
      );
      final agentScript = File('${tempDir.path}/fake_failed_close_agent.dart');
      final permissionResponsePath = jsonEncode(permissionResponseFile.path);
      await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{
            'sessionCapabilities': <String, dynamic>{
              'close': true,
              'configOptions': <String, dynamic>{},
            },
          },
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/new') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'sessionId': 'failed-close',
          'configOptions': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'model',
              'name': 'Model',
              'type': 'select',
              'currentValue': 'safe',
              'options': <Map<String, dynamic>>[
                <String, dynamic>{'value': 'safe', 'name': 'Safe'},
              ],
            },
          ],
        },
      }));
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': 'permission-failed-close',
        'method': 'session/request_permission',
        'params': <String, dynamic>{
          'sessionId': 'failed-close',
          'toolCall': <String, dynamic>{'title': 'Read file', 'kind': 'read'},
          'options': <Map<String, dynamic>>[
            <String, dynamic>{
              'optionId': 'allow',
              'kind': 'allow_once',
              'name': 'Allow',
            },
          ],
        },
      }));
    } else if (message['method'] == 'session/close') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'error': <String, dynamic>{'code': -32000, 'message': 'close failed'},
      }));
    } else if (message['id'] == 'permission-failed-close') {
      File($permissionResponsePath).writeAsStringSync(
        jsonEncode(message),
        flush: true,
      );
    }
  }
}
''');

      final client = DartAcpAgentClient(
        agentCommand: _dartExecutable(),
        agentArgs: <String>[agentScript.path],
      );
      final requestCompleter = Completer<AcpPermissionRequest>();
      final subscription = client.permissionRequests.listen((request) {
        if (!requestCompleter.isCompleted) requestCompleter.complete(request);
      });

      try {
        await client.connect().timeout(const Duration(seconds: 5));
        final session = await client.createSession(cwd: '/workspace');
        await requestCompleter.future.timeout(const Duration(seconds: 5));
        expect(
          (await client.sessionSettings(session.id)).configOptions,
          hasLength(1),
        );

        await expectLater(
          client.closeSession(sessionId: session.id),
          throwsA(
            isA<rpc.RpcException>()
                .having((error) => error.code, 'code', -32000)
                .having((error) => error.message, 'message', 'close failed'),
          ),
        );

        expect(client.activeSessionIdForTesting, isNull);
        final settings = await client.sessionSettings(session.id);
        expect(settings.configOptions, isEmpty);
        expect(settings.omissions, isEmpty);
        await _waitForFile(permissionResponseFile);
        final permissionResponse =
            jsonDecode(await permissionResponseFile.readAsString())
                as Map<String, dynamic>;
        expect(
          permissionResponse['result'],
          containsPair('outcome', containsPair('outcome', 'cancelled')),
        );
      } finally {
        await subscription.cancel();
        await client.dispose();
        await tempDir.delete(recursive: true);
      }
    },
  );

  test('closeSession clears wrapper state on request timeout', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final agentScript = File('${tempDir.path}/fake_timed_out_close_agent.dart');
    await agentScript.writeAsString(r'''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{
            'sessionCapabilities': <String, dynamic>{
              'close': true,
              'configOptions': <String, dynamic>{},
            },
          },
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/new') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'sessionId': 'timed-out-close',
          'configOptions': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'model',
              'name': 'Model',
              'type': 'select',
              'currentValue': 'safe',
              'options': <Map<String, dynamic>>[
                <String, dynamic>{'value': 'safe', 'name': 'Safe'},
              ],
            },
          ],
        },
      }));
    }
  }
}
''');

    final client = DartAcpAgentClient(
      agentCommand: _dartExecutable(),
      agentArgs: <String>[agentScript.path],
      timeouts: const acp.AcpTimeouts(request: Duration(milliseconds: 75)),
    );

    try {
      await client.connect().timeout(const Duration(seconds: 5));
      final session = await client.createSession(cwd: '/workspace');
      expect(
        (await client.sessionSettings(session.id)).configOptions,
        hasLength(1),
      );

      await expectLater(
        client.closeSession(sessionId: session.id),
        throwsA(isA<acp.AcpRequestTimeoutException>()),
      );

      expect(client.activeSessionIdForTesting, isNull);
      final settings = await client.sessionSettings(session.id);
      expect(settings.configOptions, isEmpty);
      expect(settings.omissions, isEmpty);
    } finally {
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  test('logout cancels pending permission requests', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final logoutRequestFile = File('${tempDir.path}/logout_request.json');
    final permissionResponseFile = File(
      '${tempDir.path}/permission_response.json',
    );
    final agentScript = File(
      '${tempDir.path}/fake_logout_permission_agent.dart',
    );
    final logoutRequestPath = jsonEncode(logoutRequestFile.path);
    final permissionResponsePath = jsonEncode(permissionResponseFile.path);
    await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{
            'auth': <String, dynamic>{'logout': true},
          },
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/new') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'sessionId': 'session-logout'},
      }));
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': 'permission-logout',
        'method': 'session/request_permission',
        'params': <String, dynamic>{
          'sessionId': 'session-logout',
          'toolCall': <String, dynamic>{
            'title': 'Run command',
            'kind': 'execute',
          },
          'options': <Map<String, dynamic>>[
            <String, dynamic>{
              'optionId': 'allow',
              'kind': 'allow_once',
              'name': 'Allow',
            },
            <String, dynamic>{
              'optionId': 'deny',
              'kind': 'reject_once',
              'name': 'Deny',
            },
          ],
        },
      }));
    } else if (message['method'] == 'logout') {
      await File($logoutRequestPath).writeAsString(jsonEncode(message));
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{},
      }));
    } else if (message['id'] == 'permission-logout') {
      await File($permissionResponsePath).writeAsString(jsonEncode(message));
    }
  }
}
''');

    final client = DartAcpAgentClient(
      agentCommand: _dartExecutable(),
      agentArgs: [agentScript.path],
    );
    final requestCompleter = Completer<AcpPermissionRequest>();
    final subscription = client.permissionRequests.listen((request) {
      if (!requestCompleter.isCompleted) {
        requestCompleter.complete(request);
      }
    });

    try {
      await client.connect().timeout(const Duration(seconds: 5));
      final session = await client.createSession(cwd: '/workspace');
      final request = await requestCompleter.future.timeout(
        const Duration(seconds: 5),
      );

      expect(session.id, 'session-logout');
      expect(request.sessionId, 'session-logout');

      await client.logout();
      await _waitForFile(logoutRequestFile);
      await _waitForFile(permissionResponseFile);

      final logoutRequest =
          jsonDecode(await logoutRequestFile.readAsString())
              as Map<String, dynamic>;
      expect(logoutRequest['method'], 'logout');

      final permissionResponse =
          jsonDecode(await permissionResponseFile.readAsString())
              as Map<String, dynamic>;
      expect(permissionResponse['id'], 'permission-logout');
      expect(
        permissionResponse['result'],
        containsPair('outcome', containsPair('outcome', 'cancelled')),
      );
    } finally {
      await subscription.cancel();
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'prefers config options over modes returned by session creation',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
      final setConfigParamsFile = File(
        '${tempDir.path}/set_config_params.json',
      );
      final setConfigParamsPath = jsonEncode(setConfigParamsFile.path);
      final agentScript = File(
        '${tempDir.path}/fake_session_result_agent.dart',
      );
      await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{
            'sessionCapabilities': <String, dynamic>{
              'configOptions': <String, dynamic>{},
            },
          },
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/new') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'sessionId': 'session-1',
          'modes': <String, dynamic>{
            'currentModeId': 'plan',
            'availableModes': <Map<String, dynamic>>[
              <String, dynamic>{'id': 'plan', 'name': 'Plan'},
              <String, dynamic>{'id': 'act', 'name': 'Act'},
            ],
          },
          'configOptions': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'model',
              'name': 'Model',
              'type': 'select',
              'currentValue': 'gpt-5.6-sol',
              'category': 'model',
              'options': <Map<String, dynamic>>[
                <String, dynamic>{
                  'group': 'openai',
                  'name': 'OpenAI',
                  'options': <Map<String, dynamic>>[
                    <String, dynamic>{
                      'value': 'gpt-5.6-sol',
                      'name': 'GPT-5.6-Sol',
                    },
                    <String, dynamic>{
                      'value': 'gpt-5.5',
                      'name': 'GPT-5.5',
                    },
                  ],
                },
              ],
            },
            <String, dynamic>{
              'id': 'reasoning_effort',
              'name': 'Reasoning effort',
              'type': 'select',
              'currentValue': 'max',
              'category': 'thought_level',
              'options': <Map<String, dynamic>>[
                <String, dynamic>{'value': 'high', 'name': 'High'},
                <String, dynamic>{'value': 'max', 'name': 'Max'},
                <String, dynamic>{'value': 'ultra', 'name': 'Ultra'},
              ],
            },
            <String, dynamic>{
              'id': 'fast-mode',
              'name': 'Fast mode',
              'type': 'boolean',
              'currentValue': false,
              'category': 'model_config',
            },
          ],
        },
      }));
    } else if (message['method'] == 'session/set_config_option') {
      await File($setConfigParamsPath).writeAsString(
        jsonEncode(message['params']),
      );
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'configOptions': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'fast-mode',
              'name': 'Fast mode',
              'type': 'boolean',
              'currentValue': true,
              'category': 'model_config',
            },
          ],
        },
      }));
    }
  }
}
''');

      final client = DartAcpAgentClient(
        agentCommand: _dartExecutable(),
        agentArgs: [agentScript.path],
      );

      try {
        await client.connect().timeout(const Duration(seconds: 5));

        final session = await client.createSession(cwd: '/workspace');
        final settings = await client.sessionSettings(session.id);

        expect(session.id, 'session-1');
        expect(settings.configOptions, hasLength(3));
        expect(settings.currentModelLabel, 'GPT-5.6-Sol');
        expect(settings.currentReasoningEffortLabel, 'Max');
        expect(settings.modelOption!.options.last.value, 'gpt-5.5');
        expect(settings.modelOption!.options.first.groupName, 'OpenAI');
        expect(settings.nonModelConfigOptions.single.currentBoolValue, isFalse);
        expect(settings.modes.currentModeId, isNull);
        expect(settings.modes.availableModes, isEmpty);

        final updated = await client.setConfigOption(
          sessionId: session.id,
          configId: 'fast-mode',
          value: true,
        );
        await _waitForFile(setConfigParamsFile);
        expect(
          jsonDecode(await setConfigParamsFile.readAsString()),
          <String, dynamic>{
            'sessionId': 'session-1',
            'configId': 'fast-mode',
            'type': 'boolean',
            'value': true,
          },
        );
        expect(updated.single.currentBoolValue, isTrue);
      } finally {
        await client.dispose();
        await tempDir.delete(recursive: true);
      }
    },
  );

  test('bounded result observation ignores colliding agent requests', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final agentScript = File(
      '${tempDir.path}/fake_colliding_request_agent.dart',
    );
    await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{
            'sessionCapabilities': <String, dynamic>{
              'configOptions': <String, dynamic>{},
            },
          },
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/new') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'method': 'session/request_permission',
        'params': <String, dynamic>{
          'sessionId': 'session-1',
          'toolCall': <String, dynamic>{
            'title': 'Read file',
            'kind': 'read',
          },
          'options': <Map<String, dynamic>>[
            <String, dynamic>{
              'optionId': 'deny',
              'kind': 'reject_once',
              'name': 'Deny',
            },
          ],
        },
      }));
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'sessionId': 'session-1',
          'configOptions': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'model',
              'name': 'Model',
              'type': 'select',
              'currentValue': 'gpt-5',
              'category': 'model',
              'options': <Map<String, dynamic>>[
                <String, dynamic>{'value': 'gpt-5', 'name': 'GPT-5'},
              ],
            },
          ],
        },
      }));
    }
  }
}
''');

    final client = DartAcpAgentClient(
      agentCommand: _dartExecutable(),
      agentArgs: [agentScript.path],
    );

    try {
      await client.connect().timeout(const Duration(seconds: 5));

      final session = await client.createSession(cwd: '/workspace');
      final settings = await client.sessionSettings(session.id);

      expect(session.id, 'session-1');
      expect(settings.configOptions.map((option) => option.id), ['model']);
      expect(settings.currentModelLabel, 'GPT-5');
    } finally {
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  test('invalid typed config option clears the entire field', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final agentScript = File('${tempDir.path}/fake_unknown_config_agent.dart');
    await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{
            'sessionCapabilities': <String, dynamic>{
              'configOptions': <String, dynamic>{},
            },
          },
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/new') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'sessionId': 'session-1',
          'configOptions': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'model',
              'name': 'Model',
              'type': ' SELECT ',
              'currentValue': 'gpt-5',
              'category': 'model',
              'options': <Map<String, dynamic>>[
                <String, dynamic>{'value': 'gpt-5', 'name': 'GPT-5'},
              ],
            },
            <String, dynamic>{
              'id': 'temperature',
              'name': 'Temperature',
              'type': 'slider',
              'currentValue': '0.3',
              'options': <Map<String, dynamic>>[],
            },
            <String, dynamic>{
              'id': 'bad-select',
              'name': 'Bad select',
              'type': 'select',
              'currentValue': true,
              'options': <Map<String, dynamic>>[
                <String, dynamic>{'value': 'true', 'name': 'True'},
              ],
            },
            <String, dynamic>{
              'id': 'read_only',
              'name': 'Read only',
              'type': ' BOOLEAN ',
              'currentValue': true,
              'options': <Map<String, dynamic>>[],
            },
          ],
        },
      }));
    }
  }
}
''');

    final client = DartAcpAgentClient(
      agentCommand: _dartExecutable(),
      agentArgs: [agentScript.path],
    );

    try {
      await client.connect().timeout(const Duration(seconds: 5));

      final session = await client.createSession(cwd: '/workspace');
      final settings = await client.sessionSettings(session.id);

      expect(settings.configOptions, isEmpty);
      expect(settings.omissions.single.resource, 'config_options');
    } finally {
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'owns all-valid legacy config aliases through the bounded result',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
      final agentScript = File('${tempDir.path}/fake_legacy_config_agent.dart');
      await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{
            'sessionCapabilities': <String, dynamic>{
              'configOptions': <String, dynamic>{},
            },
          },
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/new') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'session_id': 'session-1',
          'config_options': <Object>[
            <String, dynamic>{
              'key': 'model',
              'label': 'Model',
              'current_value': 'kimi-k2',
              'choices': <Object>[
                'kimi-k2',
                <String, dynamic>{
                  'id': 'glm-4.6',
                  'displayName': 'GLM 4.6',
                },
              ],
              'category': 'model',
            },
            <String, dynamic>{
              'config_id': 'auto_apply',
              'label': 'Auto apply',
              'type': 'boolean',
              'selected': true,
              'values': <Map<String, Object>>[
                <String, Object>{'value': true, 'label': 'On'},
                <String, Object>{'value': false, 'label': 'Off'},
              ],
            },
          ],
        },
      }));
    }
  }
}
''');

      final client = DartAcpAgentClient(
        agentCommand: _dartExecutable(),
        agentArgs: [agentScript.path],
      );

      try {
        await client.connect().timeout(const Duration(seconds: 5));

        final session = await client.createSession(cwd: '/workspace');
        final settings = await client.sessionSettings(session.id);

        expect(settings.configOptions.map((option) => option.id), [
          'model',
          'auto_apply',
        ]);
        expect(settings.currentModelLabel, 'kimi-k2');
        expect(
          settings.configOptions.first.options.map((choice) => choice.value),
          ['kimi-k2', 'glm-4.6'],
        );
        expect(settings.configOptions.first.options.last.name, 'GLM 4.6');
        expect(settings.configOptions.last.type, 'boolean');
        expect(settings.configOptions.last.currentValue, 'true');
        expect(
          settings.configOptions.last.options.map((choice) => choice.name),
          ['On', 'Off'],
        );
        expect(settings.omissions, isEmpty);
      } finally {
        await client.dispose();
        await tempDir.delete(recursive: true);
      }
    },
  );

  test('owns nested legacy modes when config options are omitted', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final agentScript = File('${tempDir.path}/fake_legacy_modes_agent.dart');
    await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{},
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/new') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'sessionId': 'session-legacy',
          'modes': <String, dynamic>{
            'current_mode_id': 'plan',
            'available_modes': <Map<String, dynamic>>[
              <String, dynamic>{'id': 'plan', 'name': 'Plan'},
              <String, dynamic>{'mode_id': 'act', 'display_name': 'Act'},
            ],
          },
        },
      }));
    }
  }
}
''');

    final client = DartAcpAgentClient(
      agentCommand: _dartExecutable(),
      agentArgs: [agentScript.path],
    );

    try {
      await client.connect().timeout(const Duration(seconds: 5));

      final session = await client.createSession(cwd: '/workspace');
      final settings = await client.sessionSettings(session.id);

      expect(session.id, 'session-legacy');
      expect(settings.configOptions, isEmpty);
      expect(settings.modes.currentModeId, 'plan');
      expect(settings.modes.availableModes.map((mode) => mode.id), [
        'plan',
        'act',
      ]);
      expect(settings.modes.availableModes.map((mode) => mode.name), [
        'Plan',
        'Act',
      ]);
    } finally {
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  test('does not synthesize config options from legacy raw models', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final agentScript = File('${tempDir.path}/fake_models_agent.dart');
    await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{},
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/new') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'sessionId': 'session-models',
          'models': <String, dynamic>{
            'current_model_id': 'kimi-k2',
            'available_models': <Map<String, dynamic>>[
              <String, dynamic>{
                'model_id': 'kimi-k2',
                'display_name': 'Kimi K2',
                'description': 'Moonshot K2',
              },
              <String, dynamic>{
                'model_id': 'kimi-pro',
                'label': 'Kimi Pro',
              },
            ],
          },
        },
      }));
    }
  }
}
''');

    final client = DartAcpAgentClient(
      agentCommand: _dartExecutable(),
      agentArgs: [agentScript.path],
    );

    try {
      await client.connect().timeout(const Duration(seconds: 5));

      final session = await client.createSession(cwd: '/workspace');
      final settings = await client.sessionSettings(session.id);

      expect(settings.configOptions, isEmpty);
      expect(settings.currentModelLabel, isNull);
    } finally {
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  test('setting model config uses the typed config option RPC', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final setModelParamsFile = File('${tempDir.path}/set_model_params.json');
    final setModelParamsPath = jsonEncode(setModelParamsFile.path);
    final agentScript = File('${tempDir.path}/fake_set_model_agent.dart');
    await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{},
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/new') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'sessionId': 'session-models',
          'models': <String, dynamic>{
            'currentModelId': 'kimi-k2',
            'availableModels': <Map<String, dynamic>>[
              <String, dynamic>{'modelId': 'kimi-k2', 'name': 'Kimi K2'},
              <String, dynamic>{'modelId': 'kimi-pro', 'name': 'Kimi Pro'},
            ],
          },
        },
      }));
    } else if (message['method'] == 'session/set_config_option') {
      final params = message['params'] as Map<String, dynamic>;
      await File($setModelParamsPath).writeAsString(
        jsonEncode(params),
      );
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'configOptions': <Object?>[
            <String, dynamic>{
              'id': 'model',
              'name': 'Model',
              'type': 'select',
              'currentValue': params['value'],
              'category': 'model',
              'options': <Map<String, dynamic>>[
                <String, dynamic>{'value': 'kimi-k2', 'name': 'Kimi K2'},
                <String, dynamic>{
                  'value': 'kimi-pro',
                  'name': 'Kimi Pro Updated',
                },
              ],
            },
            if (params['value'] == 'reject') 'SET_CONFIG_CANARY',
          ],
        },
      }));
    } else if (message['method'] == 'session/set_model') {
      await File($setModelParamsPath).writeAsString(
        jsonEncode(<String, dynamic>{'wrongMethod': message['method']}),
      );
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{},
      }));
    }
  }
}
''');

    final client = DartAcpAgentClient(
      agentCommand: _dartExecutable(),
      agentArgs: [agentScript.path],
    );

    try {
      await client.connect().timeout(const Duration(seconds: 5));

      final session = await client.createSession(cwd: '/workspace');
      final updatedOptions = await client.setConfigOption(
        sessionId: session.id,
        configId: 'model',
        value: 'kimi-pro',
      );
      await _waitForFile(setModelParamsFile);
      final setModelParams =
          jsonDecode(await setModelParamsFile.readAsString())
              as Map<String, dynamic>;
      final settings = await client.sessionSettings(session.id);

      expect(setModelParams, {
        'sessionId': 'session-models',
        'configId': 'model',
        'value': 'kimi-pro',
      });
      expect(updatedOptions.single.currentValue, 'kimi-pro');
      expect(updatedOptions.single.options.last.name, 'Kimi Pro Updated');
      expect(settings.currentModelLabel, 'Kimi Pro Updated');

      await expectLater(
        client.setConfigOption(
          sessionId: session.id,
          configId: 'model',
          value: 'reject',
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.toString(),
            'payload-free',
            isNot(contains('SET_CONFIG_CANARY')),
          ),
        ),
      );
      final rejectedSettings = await client.sessionSettings(session.id);
      expect(rejectedSettings.configOptions, isEmpty);
      expect(rejectedSettings.omissions.single.resource, 'config_options');
    } finally {
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'runtime config option updates replace ignored legacy models state',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
      final setConfigParamsFile = File(
        '${tempDir.path}/set_config_params.json',
      );
      final setConfigParamsPath = jsonEncode(setConfigParamsFile.path);
      final agentScript = File(
        '${tempDir.path}/fake_models_then_config_agent.dart',
      );
      await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{},
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/new') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'sessionId': 'session-models',
          'models': <String, dynamic>{
            'currentModelId': 'legacy-model',
            'availableModels': <Map<String, dynamic>>[
              <String, dynamic>{
                'modelId': 'legacy-model',
                'name': 'Legacy Model',
              },
            ],
          },
        },
      }));
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'method': 'session/update',
        'params': <String, dynamic>{
          'sessionId': 'session-models',
          'update': <String, dynamic>{
            'sessionUpdate': 'config_option_update',
            'configOptions': <Map<String, dynamic>>[
              <String, dynamic>{
                'id': 'model',
                'name': 'Model',
                'type': 'select',
                'currentValue': 'stable-a',
                'category': 'model',
                'options': <Map<String, dynamic>>[
                  <String, dynamic>{'value': 'stable-a', 'name': 'Stable A'},
                  <String, dynamic>{'value': 'stable-b', 'name': 'Stable B'},
                ],
              },
            ],
          },
        },
      }));
    } else if (message['method'] == 'session/set_config_option') {
      await File($setConfigParamsPath).writeAsString(
        jsonEncode(message['params']),
      );
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'configOptions': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'model',
              'name': 'Model',
              'type': 'select',
              'currentValue': 'stable-b',
              'category': 'model',
              'options': <Map<String, dynamic>>[
                <String, dynamic>{'value': 'stable-a', 'name': 'Stable A'},
                <String, dynamic>{'value': 'stable-b', 'name': 'Stable B'},
              ],
            },
          ],
        },
      }));
    } else if (message['method'] == 'session/set_model') {
      await File($setConfigParamsPath).writeAsString(
        jsonEncode(<String, dynamic>{'wrongMethod': message['method']}),
      );
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{},
      }));
    }
  }
}
''');

      final client = DartAcpAgentClient(
        agentCommand: _dartExecutable(),
        agentArgs: [agentScript.path],
      );

      try {
        await client.connect().timeout(const Duration(seconds: 5));

        final session = await client.createSession(cwd: '/workspace');
        final settings = await client.sessionSettings(session.id);
        await client.setConfigOption(
          sessionId: session.id,
          configId: 'model',
          value: 'stable-b',
        );
        await _waitForFile(setConfigParamsFile);
        final setConfigParams =
            jsonDecode(await setConfigParamsFile.readAsString())
                as Map<String, dynamic>;

        expect(settings.currentModelLabel, 'Stable A');
        expect(setConfigParams, {
          'sessionId': 'session-models',
          'configId': 'model',
          'value': 'stable-b',
        });
      } finally {
        await client.dispose();
        await tempDir.delete(recursive: true);
      }
    },
  );

  test('ignores legacy raw models returned by resume and fork', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final agentScript = File('${tempDir.path}/fake_resume_fork_models.dart');
    await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{
            'sessionCapabilities': <String, dynamic>{
              'resume': <String, dynamic>{},
              'fork': <String, dynamic>{},
            },
          },
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/resume') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'models': <String, dynamic>{
            'currentModelId': 'resume-model',
            'availableModels': <Map<String, dynamic>>[
              <String, dynamic>{
                'modelId': 'resume-model',
                'name': 'Resume Model',
              },
            ],
          },
        },
      }));
    } else if (message['method'] == 'session/fork') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'sessionId': 'session-forked',
          'models': <String, dynamic>{
            'currentModelId': 'fork-model',
            'availableModels': <Map<String, dynamic>>[
              <String, dynamic>{
                'modelId': 'fork-model',
                'name': 'Fork Model',
              },
            ],
          },
        },
      }));
    }
  }
}
''');

    final client = DartAcpAgentClient(
      agentCommand: _dartExecutable(),
      agentArgs: [agentScript.path],
    );

    try {
      await client.connect().timeout(const Duration(seconds: 5));

      final resumeEvents = await client.resumeSession(
        sessionId: 'session-resume',
        cwd: '/workspace',
      );
      final resumeSettings = await client.sessionSettings('session-resume');
      final forked = await client.forkSession(
        sessionId: 'session-resume',
        cwd: '/workspace',
      );
      final forkSettings = await client.sessionSettings(forked.id);

      expect(resumeEvents, isEmpty);
      expect(resumeSettings.currentModelLabel, isNull);
      expect(forked.id, 'session-forked');
      expect(forkSettings.currentModelLabel, isNull);
    } finally {
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'caches immediate config option updates after session creation',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
      final agentScript = File('${tempDir.path}/fake_config_agent.dart');
      await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{
            'sessionCapabilities': <String, dynamic>{
              'configOptions': <String, dynamic>{},
            },
          },
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/new') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'sessionId': 'session-1'},
      }));
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'method': 'session/update',
        'params': <String, dynamic>{
          'session_id': 'session-1',
          'update': <String, dynamic>{
            'sessionUpdate': 'config_option_update',
            'configOptions': <Map<String, dynamic>>[
              <String, dynamic>{
                'id': 'model',
                'name': 'Model',
                'type': 'select',
                'currentValue': 'gpt-5',
                'category': 'model',
                'options': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'value': 'gpt-5',
                    'name': 'GPT-5',
                  },
                ],
              },
            ],
          },
        },
      }));
    }
  }
}
''');

      final client = DartAcpAgentClient(
        agentCommand: _dartExecutable(),
        agentArgs: [agentScript.path],
      );

      try {
        await client.connect().timeout(const Duration(seconds: 5));

        final session = await client.createSession(cwd: '/workspace');
        final settings = await client.sessionSettings(session.id);

        expect(session.id, 'session-1');
        expect(settings.configOptions, hasLength(1));
        expect(settings.configOptions.single.id, 'model');
        expect(settings.currentModelLabel, 'GPT-5');
      } finally {
        await client.dispose();
        await tempDir.delete(recursive: true);
      }
    },
  );

  test('returns immediate command updates with created sessions', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final agentScript = File('${tempDir.path}/fake_commands_agent.dart');
    await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{
            'sessionCapabilities': <String, dynamic>{},
          },
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/new') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'sessionId': 'session-commands'},
      }));
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'method': 'session/update',
        'params': <String, dynamic>{
          'sessionId': 'session-commands',
          'update': <String, dynamic>{
            'sessionUpdate': 'available_commands_update',
            'availableCommands': <Object>[
              <String, dynamic>{'name': 'review'},
              <String, dynamic>{
                'id': 'explain',
                'summary': 'Explain the current change.',
                'schema': <String, dynamic>{'type': 'object'},
                'input': 'Optional focus',
              },
              <String, dynamic>{
                'name': 'fix',
                'description': 'Fix the current change.',
                'input': <String, dynamic>{
                  'placeholder': 'Patch instructions',
                },
              },
            ],
          },
        },
      }));
    }
  }
}
''');

    final client = DartAcpAgentClient(
      agentCommand: _dartExecutable(),
      agentArgs: [agentScript.path],
    );

    try {
      await client.connect().timeout(const Duration(seconds: 5));

      final session = await client.createSession(cwd: '/workspace');

      expect(session.id, 'session-commands');
      expect(session.initialEvents, hasLength(1));
      final event = session.initialEvents.single;
      expect(event.metadata['kind'], 'commands');
      expect(event.text, 'review, explain, fix');
      final commands = event.metadata['commands'] as List<dynamic>;
      expect(commands, hasLength(3));
      expect(commands.first, containsPair('name', 'review'));
      expect(
        commands[1],
        containsPair('description', 'Explain the current change.'),
      );
      expect(commands[1], containsPair('parameters', {'type': 'object'}));
      expect(commands[1], containsPair('input', {'hint': 'Optional focus'}));
      expect(
        commands.last,
        containsPair('description', 'Fix the current change.'),
      );
      expect(
        commands.last,
        containsPair('input', {'hint': 'Patch instructions'}),
      );
    } finally {
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  test('ignores unspecified session updates', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final agentScript = File(
      '${tempDir.path}/fake_unspecified_update_agent.dart',
    );
    await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{
            'sessionCapabilities': <String, dynamic>{},
          },
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/new') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'sessionId': 'session-empty-update'},
      }));
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'method': 'session/update',
        'params': <String, dynamic>{
          'sessionId': 'session-empty-update',
          'update': <String, dynamic>{},
        },
      }));
    }
  }
}
''');

    final client = DartAcpAgentClient(
      agentCommand: _dartExecutable(),
      agentArgs: [agentScript.path],
    );

    try {
      await client.connect().timeout(const Duration(seconds: 5));

      final session = await client.createSession(cwd: '/workspace');

      expect(session.id, 'session-empty-update');
      expect(session.initialEvents, isEmpty);
    } finally {
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  test('maps usage updates during prompt streams', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final agentScript = File('${tempDir.path}/fake_usage_update_agent.dart');
    await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{
            'sessionCapabilities': <String, dynamic>{},
          },
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/new') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'sessionId': 'session-usage-update'},
      }));
    } else if (message['method'] == 'session/prompt') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'method': 'session/update',
        'params': <String, dynamic>{
          'sessionId': 'session-usage-update',
          'update': <String, dynamic>{
            'sessionUpdate': 'usage_update',
            'used': 53000,
            'size': 200000,
            'cost': <String, dynamic>{'amount': 0.045, 'currency': 'USD'},
          },
        },
      }));
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'method': 'session/update',
        'params': <String, dynamic>{
          'sessionId': 'session-usage-update',
          'update': <String, dynamic>{
            'sessionUpdate': 'agent_message_chunk',
            'content': <String, dynamic>{'type': 'text', 'text': 'hello'},
          },
        },
      }));
      await Future<void>.delayed(const Duration(milliseconds: 25));
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'stopReason': 'end_turn'},
      }));
    }
  }
}
''');

    final client = DartAcpAgentClient(
      agentCommand: _dartExecutable(),
      agentArgs: [agentScript.path],
    );

    try {
      await client.connect().timeout(const Duration(seconds: 5));
      final session = await client.createSession(cwd: '/workspace');
      final events = await client
          .sendPrompt(sessionId: session.id, prompt: 'say hi')
          .toList()
          .timeout(const Duration(seconds: 5));

      expect(events.map((event) => event.text), contains('hello'));
      expect(
        events.map((event) => event.text),
        isNot(contains('[Unknown update: usage_update]')),
      );
      final usageEvent = events.singleWhere(
        (event) => event.metadata['kind'] == 'usage_update',
      );
      expect(usageEvent.text, 'Context 27%');
      expect(usageEvent.metadata['used'], 53000);
      expect(usageEvent.metadata['size'], 200000);
      expect(usageEvent.metadata['cost'], <String, Object?>{
        'amount': 0.045,
        'currency': 'USD',
      });
    } finally {
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'session load turns oversized updates into one omission and continues',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
      final agentScript = File(
        '${tempDir.path}/fake_oversized_load_agent.dart',
      );
      await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{'loadSession': true},
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/load') {
      final params = message['params'] as Map<String, dynamic>;
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'method': 'session/update',
        'params': <String, dynamic>{
          'sessionId': params['sessionId'],
          'update': <String, dynamic>{
            'sessionUpdate': 'plan',
            'title': 'ab',
            'entries': <Object?>[],
          },
        },
      }));
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'method': 'session/update',
        'params': <String, dynamic>{
          'sessionId': params['sessionId'],
          'update': <String, dynamic>{
            'sessionUpdate': 'plan',
            'entries': <Object?>[],
          },
        },
      }));
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{},
      }));
    }
  }
}
''');

      final client = DartAcpAgentClient(
        agentCommand: _dartExecutable(),
        agentArgs: <String>[agentScript.path],
        inputBudget: const acp.AcpInputBudget(maxStructuredUpdateBytes: 5),
      );

      try {
        await client.connect().timeout(const Duration(seconds: 5));
        final events = await client.resumeSession(
          sessionId: 'oversized-history',
          cwd: '/workspace',
        );

        expect(events, hasLength(2));
        expect(events.first.type, AgentEventType.status);
        expect(events.first.text, 'Oversized session data omitted.');
        expect(events.first.metadata['kind'], 'omission');
        expect(
          events.first.omissions.single.resource,
          'session structured bytes',
        );
        expect(events.last.type, AgentEventType.status);
        expect(events.last.metadata['kind'], 'plan');
      } finally {
        await client.dispose();
        await tempDir.delete(recursive: true);
      }
    },
  );

  test('returns immediate command updates after session resume', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final agentScript = File('${tempDir.path}/fake_resume_agent.dart');
    await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{
            'sessionCapabilities': <String, dynamic>{
              'resume': <String, dynamic>{},
            },
          },
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/resume') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{},
      }));
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'method': 'session/update',
        'params': <String, dynamic>{
          'sessionId': 'session-resume',
          'update': <String, dynamic>{
            'sessionUpdate': 'available_commands_update',
            'availableCommands': <Map<String, dynamic>>[
              <String, dynamic>{
                'name': 'summarize',
                'description': 'Summarize the resumed session.',
              },
            ],
          },
        },
      }));
    }
  }
}
''');

    final client = DartAcpAgentClient(
      agentCommand: _dartExecutable(),
      agentArgs: [agentScript.path],
    );

    try {
      await client.connect().timeout(const Duration(seconds: 5));

      final events = await client.resumeSession(
        sessionId: 'session-resume',
        cwd: '/workspace',
      );

      expect(events, hasLength(1));
      expect(events.single.metadata['kind'], 'commands');
      expect(
        events.single.metadata['commands'],
        contains(containsPair('name', 'summarize')),
      );
    } finally {
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  test('caches config options returned by session load', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final agentScript = File('${tempDir.path}/fake_load_settings_agent.dart');
    await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{
            'loadSession': true,
            'sessionCapabilities': <String, dynamic>{
              'configOptions': <String, dynamic>{},
            },
          },
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/load') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'modes': <String, dynamic>{
            'currentModeId': 'plan',
            'availableModes': <Map<String, dynamic>>[
              <String, dynamic>{'id': 'plan', 'name': 'Plan'},
              <String, dynamic>{'id': 'act', 'name': 'Act'},
            ],
          },
          'configOptions': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'temperature',
              'name': 'Temperature',
              'type': 'select',
              'currentValue': 'gpt-5-pro',
              'category': 'model',
              'group': 'advanced',
              'options': <Map<String, dynamic>>[
                <String, dynamic>{
                  'value': 'gpt-5-pro',
                  'name': 'GPT-5 Pro',
                },
              ],
            },
          ],
        },
      }));
    }
  }
}
''');

    final client = DartAcpAgentClient(
      agentCommand: _dartExecutable(),
      agentArgs: [agentScript.path],
    );

    try {
      await client.connect().timeout(const Duration(seconds: 5));

      final events = await client.resumeSession(
        sessionId: 'session-load',
        cwd: '/workspace',
      );
      final settings = await client.sessionSettings('session-load');

      expect(events, isEmpty);
      expect(settings.configOptions, hasLength(1));
      expect(settings.configOptions.single.category, 'model');
      expect(settings.configOptions.single.group, 'advanced');
      expect(settings.configOptions.single.isModelOption, isTrue);
      expect(settings.currentModelLabel, 'GPT-5 Pro');
      expect(settings.modes.currentModeId, isNull);
      expect(settings.modes.availableModes, isEmpty);
    } finally {
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'session load mode updates use the loaded session config state',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
      final agentScript = File(
        '${tempDir.path}/fake_load_mode_update_agent.dart',
      );
      await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{
            'loadSession': true,
            'sessionCapabilities': <String, dynamic>{
              'configOptions': <String, dynamic>{},
            },
          },
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/new') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'sessionId': 'session-with-config',
          'configOptions': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'model',
              'name': 'Model',
              'type': 'select',
              'currentValue': 'gpt-5',
              'category': 'model',
              'options': <Map<String, dynamic>>[
                <String, dynamic>{'value': 'gpt-5', 'name': 'GPT-5'},
              ],
            },
          ],
        },
      }));
    } else if (message['method'] == 'session/load') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'method': 'session/update',
        'params': <String, dynamic>{
          'sessionId': 'session-legacy-mode',
          'update': <String, dynamic>{
            'sessionUpdate': 'current_mode_update',
            'current_mode_id': 'plan',
          },
        },
      }));
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{},
      }));
    }
  }
}
''');

      final client = DartAcpAgentClient(
        agentCommand: _dartExecutable(),
        agentArgs: [agentScript.path],
      );

      try {
        await client.connect().timeout(const Duration(seconds: 5));
        await client.createSession(cwd: '/workspace');

        final events = await client.resumeSession(
          sessionId: 'session-legacy-mode',
          cwd: '/workspace',
        );
        final settings = await client.sessionSettings('session-legacy-mode');

        expect(events, hasLength(1));
        expect(events.single.type, AgentEventType.status);
        expect(events.single.text, 'plan');
        expect(events.single.metadata['kind'], 'mode');
        expect(settings.modes.currentModeId, 'plan');
      } finally {
        await client.dispose();
        await tempDir.delete(recursive: true);
      }
    },
  );

  test('session resume accepts boolean config option current values', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final agentScript = File(
      '${tempDir.path}/fake_resume_boolean_config_agent.dart',
    );
    await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{
            'sessionCapabilities': <String, dynamic>{
              'resume': <String, dynamic>{},
              'configOptions': <String, dynamic>{},
            },
          },
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/resume') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'configOptions': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'thinking',
              'name': 'Thinking',
              'type': 'boolean',
              'currentValue': true,
              'options': <Map<String, dynamic>>[],
            },
          ],
        },
      }));
    }
  }
}
''');

    final client = DartAcpAgentClient(
      agentCommand: _dartExecutable(),
      agentArgs: [agentScript.path],
    );

    try {
      await client.connect().timeout(const Duration(seconds: 5));

      final events = await client.resumeSession(
        sessionId: 'session-boolean',
        cwd: '/workspace',
      );
      final settings = await client.sessionSettings('session-boolean');

      expect(events, isEmpty);
      expect(settings.configOptions, hasLength(1));
      expect(settings.configOptions.single.id, 'thinking');
      expect(settings.configOptions.single.currentValue, 'true');
    } finally {
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'session load keeps immediate config options when result only has modes',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
      final agentScript = File(
        '${tempDir.path}/fake_load_config_update_agent.dart',
      );
      await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{
            'loadSession': true,
            'sessionCapabilities': <String, dynamic>{
              'configOptions': <String, dynamic>{},
            },
          },
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/load') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'method': 'session/update',
        'params': <String, dynamic>{
          'sessionId': 'session-load',
          'update': <String, dynamic>{
            'sessionUpdate': 'config_option_update',
            'configOptions': <Map<String, dynamic>>[
              <String, dynamic>{
                'id': 'model',
                'name': 'Model',
                'type': 'select',
                'currentValue': 'gpt-5',
                'category': 'model',
                'options': <Map<String, dynamic>>[
                  <String, dynamic>{'value': 'gpt-5', 'name': 'GPT-5'},
                ],
              },
            ],
          },
        },
      }));
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'modes': <String, dynamic>{
            'currentModeId': 'plan',
            'availableModes': <Map<String, dynamic>>[
              <String, dynamic>{'id': 'plan', 'name': 'Plan'},
            ],
          },
        },
      }));
    }
  }
}
''');

      final client = DartAcpAgentClient(
        agentCommand: _dartExecutable(),
        agentArgs: [agentScript.path],
      );

      try {
        await client.connect().timeout(const Duration(seconds: 5));

        final events = await client.resumeSession(
          sessionId: 'session-load',
          cwd: '/workspace',
        );
        final settings = await client.sessionSettings('session-load');

        expect(events, hasLength(1));
        expect(events.single.metadata['kind'], 'config_option_update');
        expect(settings.configOptions, hasLength(1));
        expect(settings.currentModelLabel, 'GPT-5');
        expect(settings.modes.currentModeId, isNull);
        expect(settings.modes.availableModes, isEmpty);
      } finally {
        await client.dispose();
        await tempDir.delete(recursive: true);
      }
    },
  );

  test('rejects prompt locally while loading session history', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final agentScript = File(
      '${tempDir.path}/fake_load_prompt_error_agent.dart',
    );
    await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{
            'loadSession': true,
          },
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/new') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'sessionId': 'session-load',
        },
      }));
    } else if (message['method'] == 'session/load') {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{},
      }));
    }
  }
}
''');

    final client = DartAcpAgentClient(
      agentCommand: _dartExecutable(),
      agentArgs: [agentScript.path],
    );

    try {
      await client.connect().timeout(const Duration(seconds: 5));
      final session = await client.createSession(cwd: '/workspace');

      final resumeFuture = client.resumeSession(
        sessionId: session.id,
        cwd: '/workspace',
      );
      await Future<void>.delayed(Duration.zero);
      await expectLater(
        client.sendPrompt(sessionId: session.id, prompt: 'fail now').toList(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'Session is closing or setup is active.',
          ),
        ),
      );
      final loadEvents = await resumeFuture.timeout(const Duration(seconds: 5));

      expect(loadEvents, isEmpty);
    } finally {
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'prefers config options over modes returned by session resume',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
      final agentScript = File(
        '${tempDir.path}/fake_resume_settings_agent.dart',
      );
      await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{
            'sessionCapabilities': <String, dynamic>{
              'resume': <String, dynamic>{},
              'configOptions': <String, dynamic>{},
            },
          },
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/resume') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'modes': <String, dynamic>{
            'currentModeId': 'act',
            'availableModes': <Map<String, dynamic>>[
              <String, dynamic>{'id': 'plan', 'name': 'Plan'},
              <String, dynamic>{'id': 'act', 'name': 'Act'},
            ],
          },
          'configOptions': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'model',
              'name': 'Model',
              'type': 'select',
              'currentValue': 'gpt-5-mini',
              'category': 'model',
              'options': <Map<String, dynamic>>[
                <String, dynamic>{
                  'value': 'gpt-5-mini',
                  'name': 'GPT-5 Mini',
                },
              ],
            },
          ],
        },
      }));
    }
  }
}
''');

      final client = DartAcpAgentClient(
        agentCommand: _dartExecutable(),
        agentArgs: [agentScript.path],
      );

      try {
        await client.connect().timeout(const Duration(seconds: 5));

        final events = await client.resumeSession(
          sessionId: 'session-resume',
          cwd: '/workspace',
        );
        final settings = await client.sessionSettings('session-resume');

        expect(events, isEmpty);
        expect(settings.currentModelLabel, 'GPT-5 Mini');
        expect(settings.modes.currentModeId, isNull);
        expect(settings.modes.availableModes, isEmpty);
      } finally {
        await client.dispose();
        await tempDir.delete(recursive: true);
      }
    },
  );

  test('prefers config options over modes returned by session fork', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final agentScript = File('${tempDir.path}/fake_fork_settings_agent.dart');
    await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{
            'sessionCapabilities': <String, dynamic>{
              'fork': <String, dynamic>{},
              'configOptions': <String, dynamic>{},
            },
          },
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/fork') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'sessionId': 'session-forked',
          'modes': <String, dynamic>{
            'currentModeId': 'review',
            'availableModes': <Map<String, dynamic>>[
              <String, dynamic>{'id': 'act', 'name': 'Act'},
              <String, dynamic>{'id': 'review', 'name': 'Review'},
            ],
          },
          'configOptions': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'model',
              'name': 'Model',
              'type': 'select',
              'currentValue': 'gpt-5',
              'category': 'model',
              'options': <Map<String, dynamic>>[
                <String, dynamic>{
                  'value': 'gpt-5',
                  'name': 'GPT-5',
                },
              ],
            },
          ],
        },
      }));
    }
  }
}
''');

    final client = DartAcpAgentClient(
      agentCommand: _dartExecutable(),
      agentArgs: [agentScript.path],
    );

    try {
      await client.connect().timeout(const Duration(seconds: 5));

      final forked = await client.forkSession(
        sessionId: 'session-original',
        cwd: '/workspace',
      );
      final settings = await client.sessionSettings('session-forked');

      expect(forked.id, 'session-forked');
      expect(forked.initialEvents, isEmpty);
      expect(settings.currentModelLabel, 'GPT-5');
      expect(settings.modes.currentModeId, isNull);
      expect(settings.modes.availableModes, isEmpty);
    } finally {
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  for (final scenario
      in <
        ({
          String name,
          int maxPages,
          int maxEntries,
          int maxCursorBytes,
          String responseMode,
          AcpSessionListBudgetReason reason,
        })
      >[
        (
          name: 'rejects a repeated pagination cursor',
          maxPages: 4,
          maxEntries: 10,
          maxCursorBytes: 128,
          responseMode: 'repeated',
          reason: AcpSessionListBudgetReason.repeatedCursor,
        ),
        (
          name: 'rejects infinitely many unique pagination cursors',
          maxPages: 2,
          maxEntries: 10,
          maxCursorBytes: 128,
          responseMode: 'unique',
          reason: AcpSessionListBudgetReason.pageLimit,
        ),
        (
          name: 'rejects an oversized accumulated session list',
          maxPages: 4,
          maxEntries: 1,
          maxCursorBytes: 128,
          responseMode: 'entries',
          reason: AcpSessionListBudgetReason.entryLimit,
        ),
        (
          name: 'measures pagination cursors in UTF-8 bytes',
          maxPages: 4,
          maxEntries: 10,
          maxCursorBytes: 5,
          responseMode: 'cursor-bytes',
          reason: AcpSessionListBudgetReason.cursorByteLimit,
        ),
      ]) {
    test('listSessions ${scenario.name}', () async {
      final error = await _listSessionsBudgetFailure(
        maxPages: scenario.maxPages,
        maxEntries: scenario.maxEntries,
        maxCursorBytes: scenario.maxCursorBytes,
        responseMode: scenario.responseMode,
      );

      expect(error, isA<AcpSessionListBudgetException>());
      final typed = error as AcpSessionListBudgetException;
      expect(typed.reason, scenario.reason);
      expect(typed.toString(), isNot(contains('secret-cursor')));
      expect(typed.toString(), isNot(contains('秘密')));
    });
  }
}

void _expectTerminalHandleLimit(Map<String, dynamic> response) {
  expect(response['error'], <String, dynamic>{
    'code': -32001,
    'message': 'Terminal handle limit exceeded.',
  });
  final serialized = response.toString();
  for (final canary in const <String>[
    'session-a',
    'session-c',
    'session-command-canary',
    'session-env-canary',
    'global-command-canary',
    'global-env-canary',
  ]) {
    expect(serialized, isNot(contains(canary)));
  }
}

Future<void> _waitForTerminalTestCondition(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Timed out waiting for terminal test condition.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

class _TerminalAdmissionHarness {
  _TerminalAdmissionHarness({
    required _RecordingTerminalProvider provider,
    required acp.PermissionProvider permissionProvider,
    required int maxTerminalHandles,
    required int maxTerminalHandlesPerSession,
  }) : channel = StreamChannelController<String>() {
    peer = JsonRpcPeer(channel.foreign);
    manager = SessionManager(
      config: acp.AcpConfig(
        terminalProvider: provider,
        permissionProvider: permissionProvider,
      ),
      peer: peer,
      maxTerminalHandles: maxTerminalHandles,
      maxTerminalHandlesPerSession: maxTerminalHandlesPerSession,
    );
    server = channel.local.stream.listen((line) {
      final message = jsonDecode(line) as Map<String, dynamic>;
      final method = message['method'];
      if (method == 'session/resume' || method == 'session/close') {
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': message['id'],
            'result': <String, dynamic>{},
          }),
        );
        return;
      }
      final id = message['id']?.toString();
      if (id != null) _responses[id]?.complete(message);
    });
  }

  final StreamChannelController<String> channel;
  late JsonRpcPeer peer;
  late SessionManager manager;
  late StreamSubscription<String> server;
  final Map<String, Completer<Map<String, dynamic>>> _responses =
      <String, Completer<Map<String, dynamic>>>{};

  Future<void> resume(String sessionId) => manager.resumeSession(
    sessionId: sessionId,
    workspaceRoot: '/workspace/$sessionId',
  );

  Future<Map<String, dynamic>> createTerminal({
    required String id,
    required String sessionId,
    String command = 'unused',
    String? envValue,
  }) async {
    final response = Completer<Map<String, dynamic>>();
    _responses[id] = response;
    channel.local.sink.add(
      jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': id,
        'method': 'terminal/create',
        'params': <String, dynamic>{
          'sessionId': sessionId,
          'command': command,
          'args': const <String>[],
          if (envValue != null)
            'env': <Map<String, dynamic>>[
              <String, dynamic>{'name': 'CANARY', 'value': envValue},
            ],
        },
      }),
    );
    return response.future.timeout(const Duration(seconds: 5));
  }

  Future<Map<String, dynamic>> releaseTerminal({
    required String id,
    required String terminalId,
    String? canary,
  }) async {
    final response = Completer<Map<String, dynamic>>();
    _responses[id] = response;
    channel.local.sink.add(
      jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': id,
        'method': 'terminal/release',
        'params': <String, dynamic>{
          'terminalId': terminalId,
          'canary': ?canary,
        },
      }),
    );
    return response.future.timeout(const Duration(seconds: 5));
  }

  Future<void> dispose() async {
    await manager.dispose();
    await peer.close();
    await server.cancel();
    await channel.local.sink.close();
  }
}

Future<Object> _listSessionsBudgetFailure({
  required int maxPages,
  required int maxEntries,
  required int maxCursorBytes,
  required String responseMode,
}) async {
  final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-list-');
  final agentScript = File('${tempDir.path}/fake_list_budget_agent.dart');
  final modeLiteral = jsonEncode(responseMode);
  await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  var page = 0;
  const mode = $modeLiteral;
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{
            'sessionCapabilities': <String, dynamic>{'list': true},
          },
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/list') {
      page += 1;
      final sessions = mode == 'entries'
          ? <Map<String, dynamic>>[
              <String, dynamic>{'sessionId': 'one', 'cwd': '/one'},
              <String, dynamic>{'sessionId': 'two', 'cwd': '/two'},
            ]
          : <Map<String, dynamic>>[
              <String, dynamic>{'sessionId': 'session-\$page', 'cwd': '/ws'},
            ];
      final nextCursor = switch (mode) {
        'repeated' => 'secret-cursor',
        'unique' => 'cursor-\$page',
        'cursor-bytes' => '秘密',
        _ => null,
      };
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'sessions': sessions,
          if (nextCursor != null) 'nextCursor': nextCursor,
        },
      }));
    }
  }
}
''');

  final client = DartAcpAgentClient(
    agentCommand: _dartExecutable(),
    agentArgs: [agentScript.path],
    sessionListMaxPages: maxPages,
    sessionListMaxEntries: maxEntries,
    sessionListMaxCursorBytes: maxCursorBytes,
  );
  try {
    await client.connect().timeout(const Duration(seconds: 5));
    try {
      await client.listSessions().timeout(const Duration(seconds: 5));
    } catch (error) {
      return error;
    }
    throw StateError('Expected listSessions to reject the response sequence.');
  } finally {
    await client.dispose();
    await tempDir.delete(recursive: true);
  }
}

Future<AcpAgentCapabilities> _runRawInitializeInput({
  Object? agentCapabilities = const <String, dynamic>{},
  Object? authMethods = const <Object?>[],
  Object? agentInfo = const <String, dynamic>{},
  required acp.AcpInputBudget inputBudget,
}) async {
  final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-input-');
  final agentScript = File('${tempDir.path}/fake_initialize_input_agent.dart');
  final resultLiteral = jsonEncode(
    jsonEncode(<String, dynamic>{
      'protocolVersion': 1,
      'agentCapabilities': agentCapabilities,
      'authMethods': authMethods,
      'agentInfo': agentInfo,
    }),
  );
  await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final result = jsonDecode($resultLiteral) as Map<String, dynamic>;
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] != 'initialize') continue;
    stdout.writeln(jsonEncode(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': message['id'],
      'result': result,
    }));
  }
}
''');
  final client = DartAcpAgentClient(
    agentCommand: _dartExecutable(),
    agentArgs: <String>[agentScript.path],
    inputBudget: inputBudget,
  );

  try {
    await client.connect().timeout(const Duration(seconds: 5));
    return client.capabilities!;
  } finally {
    await client.dispose();
    await tempDir.delete(recursive: true);
  }
}

Future<Map<String, dynamic>> _capturePromptParamsForAttachment({
  bool embeddedContext = false,
  bool image = false,
  bool audio = false,
  bool includeAttachment = true,
  String prompt = 'Please inspect this.',
  String attachmentName = 'attachment.txt',
  List<int>? attachmentBytes,
  List<int>? attachmentBytesAfterSelection,
  String? mimeType,
  Map<String, String> extraFiles = const <String, String>{},
  int? declaredAttachmentSize,
  String? attachmentPathOverride,
  FutureOr<void> Function(File attachmentFile, String canonicalPath)?
  beforeAttachmentSecureOpen,
  int maxPromptAttachmentCount = 16,
  int maxPromptAttachmentSourceBytes = 8 * 1024 * 1024,
  int maxPromptAttachmentEncodedBytes = 12 * 1024 * 1024,
}) async {
  final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
  final promptParamsFile = File('${tempDir.path}/prompt_params.json');
  final attachmentFile = File(
    attachmentPathOverride ?? '${tempDir.path}/$attachmentName',
  );
  final agentScript = File('${tempDir.path}/fake_prompt_agent.dart');
  final promptParamsPath = jsonEncode(promptParamsFile.path);
  final promptCapabilities = <String>[
    if (embeddedContext) "'embeddedContext': true",
    if (image) "'image': true",
    if (audio) "'audio': true",
  ].join(', ');
  final agentCapabilities = promptCapabilities.isEmpty
      ? '<String, dynamic>{}'
      : "<String, dynamic>{'promptCapabilities': <String, dynamic>{$promptCapabilities}}";
  final bytes = attachmentBytes ?? utf8.encode('embedded attachment text');
  if (attachmentPathOverride == null) {
    await attachmentFile.writeAsBytes(bytes);
  }
  for (final entry in extraFiles.entries) {
    await File('${tempDir.path}/${entry.key}').writeAsString(entry.value);
  }
  final selectedAttachment = includeAttachment
      ? PromptAttachment.fromPath(
          path: attachmentFile.path,
          mimeType: mimeType,
          size: declaredAttachmentSize ?? await attachmentFile.length(),
        )
      : null;
  final replacementBytes = attachmentBytesAfterSelection;
  if (replacementBytes != null) {
    await attachmentFile.writeAsBytes(replacementBytes, flush: true);
  }
  await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': $agentCapabilities,
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/new') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'sessionId': 'session-1'},
      }));
    } else if (message['method'] == 'session/prompt') {
      await File($promptParamsPath).writeAsString(
        jsonEncode(message['params']),
      );
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'stopReason': 'end_turn'},
      }));
    }
  }
}
''');

  final client = DartAcpAgentClient(
    agentCommand: _dartExecutable(),
    agentArgs: [agentScript.path],
    maxPromptAttachmentCount: maxPromptAttachmentCount,
    maxPromptAttachmentSourceBytes: maxPromptAttachmentSourceBytes,
    maxPromptAttachmentEncodedBytes: maxPromptAttachmentEncodedBytes,
    beforeAttachmentSecureOpenForTesting: beforeAttachmentSecureOpen == null
        ? null
        : (canonicalPath) =>
              beforeAttachmentSecureOpen(attachmentFile, canonicalPath),
  );

  try {
    await client.connect().timeout(const Duration(seconds: 5));
    final session = await client.createSession(cwd: tempDir.path);
    final events = await client
        .sendPrompt(
          sessionId: session.id,
          prompt: prompt,
          attachments: selectedAttachment == null
              ? const <PromptAttachment>[]
              : <PromptAttachment>[selectedAttachment],
        )
        .toList()
        .timeout(const Duration(seconds: 5));
    expect(events.last.metadata['stopReason'], 'endTurn');
    return jsonDecode(await promptParamsFile.readAsString())
        as Map<String, dynamic>;
  } finally {
    await client.dispose();
    await tempDir.delete(recursive: true);
  }
}

Map<String, dynamic> _attachmentBlock(Map<String, dynamic> promptParams) {
  final prompt = promptParams['prompt'] as List<dynamic>;
  return prompt.last as Map<String, dynamic>;
}

List<String> _attachmentTypes(Map<String, dynamic> promptParams) {
  final prompt = promptParams['prompt'] as List<dynamic>;
  return prompt
      .skip(1)
      .map((block) => (block as Map<String, dynamic>)['type'] as String)
      .toList();
}

class _TestPromptAttachment {
  const _TestPromptAttachment({
    required this.name,
    required this.bytes,
    required this.mimeType,
    this.declaredSize,
  });

  final String name;
  final List<int> bytes;
  final String mimeType;
  final int? declaredSize;
}

Future<Map<String, dynamic>> _capturePromptParamsForAttachments({
  required List<_TestPromptAttachment> attachments,
  required int maxPromptAttachmentCount,
  required int maxPromptAttachmentSourceBytes,
  required int maxPromptAttachmentEncodedBytes,
  bool embeddedContext = true,
  bool image = true,
  bool audio = true,
}) async {
  final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
  final promptParamsFile = File('${tempDir.path}/prompt_params.json');
  final agentScript = File('${tempDir.path}/fake_prompt_agent.dart');
  final selected = <PromptAttachment>[];
  for (final attachment in attachments) {
    final file = File('${tempDir.path}/${attachment.name}');
    await file.writeAsBytes(attachment.bytes);
    selected.add(
      PromptAttachment.fromPath(
        path: file.path,
        mimeType: attachment.mimeType,
        size: attachment.declaredSize ?? attachment.bytes.length,
      ),
    );
  }
  await agentScript.writeAsString(
    _attachmentPromptAgentScript(
      promptParamsFile.path,
      embeddedContext: embeddedContext,
      image: image,
      audio: audio,
    ),
  );
  final client = DartAcpAgentClient(
    agentCommand: _dartExecutable(),
    agentArgs: <String>[agentScript.path],
    maxPromptAttachmentCount: maxPromptAttachmentCount,
    maxPromptAttachmentSourceBytes: maxPromptAttachmentSourceBytes,
    maxPromptAttachmentEncodedBytes: maxPromptAttachmentEncodedBytes,
  );
  try {
    await client.connect().timeout(const Duration(seconds: 5));
    final session = await client.createSession(cwd: tempDir.path);
    final events = await client
        .sendPrompt(
          sessionId: session.id,
          prompt: 'Inspect attachments.',
          attachments: selected,
        )
        .toList()
        .timeout(const Duration(seconds: 5));
    expect(events.last.metadata['stopReason'], 'endTurn');
    return jsonDecode(await promptParamsFile.readAsString())
        as Map<String, dynamic>;
  } finally {
    await client.dispose();
    await tempDir.delete(recursive: true);
  }
}

Future<List<Map<String, dynamic>>> _captureTwoAttachmentPrompts({
  required List<int> firstBytes,
  required List<int> secondBytes,
  required int maxPromptAttachmentSourceBytes,
  required int maxPromptAttachmentEncodedBytes,
}) async {
  final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
  final promptParamsFile = File('${tempDir.path}/prompt_params.json');
  final attachmentFile = File('${tempDir.path}/attachment.bin');
  final agentScript = File('${tempDir.path}/fake_prompt_agent.dart');
  await agentScript.writeAsString(
    _attachmentPromptAgentScript(promptParamsFile.path, append: true),
  );
  final client = DartAcpAgentClient(
    agentCommand: _dartExecutable(),
    agentArgs: <String>[agentScript.path],
    maxPromptAttachmentSourceBytes: maxPromptAttachmentSourceBytes,
    maxPromptAttachmentEncodedBytes: maxPromptAttachmentEncodedBytes,
  );
  try {
    await client.connect().timeout(const Duration(seconds: 5));
    final session = await client.createSession(cwd: tempDir.path);
    for (final bytes in <List<int>>[firstBytes, secondBytes]) {
      await attachmentFile.writeAsBytes(bytes, flush: true);
      await client
          .sendPrompt(
            sessionId: session.id,
            prompt: 'Inspect attachment.',
            attachments: <PromptAttachment>[
              PromptAttachment.fromPath(
                path: attachmentFile.path,
                mimeType: 'application/octet-stream',
                size: 1,
              ),
            ],
          )
          .toList()
          .timeout(const Duration(seconds: 5));
    }
    return (jsonDecode(await promptParamsFile.readAsString()) as List<dynamic>)
        .cast<Map<String, dynamic>>();
  } finally {
    await client.dispose();
    await tempDir.delete(recursive: true);
  }
}

String _attachmentPromptAgentScript(
  String promptParamsPath, {
  bool append = false,
  bool embeddedContext = true,
  bool image = true,
  bool audio = true,
}) {
  final encodedPath = jsonEncode(promptParamsPath);
  return '''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{
            'promptCapabilities': <String, dynamic>{
              'embeddedContext': $embeddedContext,
              'image': $image,
              'audio': $audio,
            },
          },
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/new') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'sessionId': 'session-1'},
      }));
    } else if (message['method'] == 'session/prompt') {
      final file = File($encodedPath);
      ${append ? "final prompts = file.existsSync() ? jsonDecode(file.readAsStringSync()) as List<dynamic> : <dynamic>[]; prompts.add(message['params']); await file.writeAsString(jsonEncode(prompts));" : "await file.writeAsString(jsonEncode(message['params']));"}
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'stopReason': 'end_turn'},
      }));
    }
  }
}
''';
}

Future<
  ({
    List<Map<String, dynamic>> calls,
    List<String> directories,
    List<String> listedAdditionalDirectories,
  })
>
_captureSessionSetupParams({
  required bool advertiseAdditionalDirectories,
}) async {
  final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
  final setupParamsFile = File('${tempDir.path}/session_setup_params.json');
  final agentScript = File('${tempDir.path}/fake_session_setup_agent.dart');
  final setupParamsPath = jsonEncode(setupParamsFile.path);
  final directories = ['${tempDir.path}/extra-a', '${tempDir.path}/extra-b'];
  final directoriesLiteral = '[${directories.map(jsonEncode).join(', ')}]';
  final additionalCapability = advertiseAdditionalDirectories
      ? "'additionalDirectories': <String, dynamic>{},"
      : '';
  await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

void record(String method, Map<String, dynamic> params) {
  final file = File($setupParamsPath);
  final calls = file.existsSync()
      ? jsonDecode(file.readAsStringSync()) as List<dynamic>
      : <dynamic>[];
  calls.add(<String, dynamic>{'method': method, 'params': params});
  file.writeAsStringSync(jsonEncode(calls));
}

Future<void> main() async {
  final directories = <String>$directoriesLiteral;
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    final method = message['method'] as String?;
    if (method == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{
            'sessionCapabilities': <String, dynamic>{
              'list': true,
              'resume': true,
              'fork': true,
              $additionalCapability
            },
          },
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (method == 'session/list') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'sessions': <Map<String, dynamic>>[
            <String, dynamic>{
              'sessionId': 'session-1',
              'cwd': '/workspace',
              'title': 'Listed session',
              'additionalDirectories': directories,
            },
          ],
        },
      }));
    } else if (method == 'session/new') {
      record(method!, message['params'] as Map<String, dynamic>);
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'sessionId': 'session-1'},
      }));
    } else if (method == 'session/resume') {
      record(method!, message['params'] as Map<String, dynamic>);
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{},
      }));
    } else if (method == 'session/fork') {
      record(method!, message['params'] as Map<String, dynamic>);
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'sessionId': 'session-forked'},
      }));
    }
  }
}
''');

  final client = DartAcpAgentClient(
    agentCommand: _dartExecutable(),
    agentArgs: [agentScript.path],
    additionalDirectories: directories,
  );

  try {
    await client.connect().timeout(const Duration(seconds: 5));
    final listed = await client.listSessions();
    await client.createSession(cwd: '/workspace');
    await client.resumeSession(sessionId: 'session-1', cwd: '/workspace');
    await client.forkSession(sessionId: 'session-1', cwd: '/workspace');

    final calls =
        (jsonDecode(await setupParamsFile.readAsString()) as List<dynamic>)
            .cast<Map<String, dynamic>>();
    return (
      calls: calls,
      directories: directories,
      listedAdditionalDirectories:
          listed.single.sessions.single.additionalDirectories,
    );
  } finally {
    await client.dispose();
    await tempDir.delete(recursive: true);
  }
}

const _transparentPngBytes = <int>[
  0x89,
  0x50,
  0x4e,
  0x47,
  0x0d,
  0x0a,
  0x1a,
  0x0a,
  0x00,
  0x00,
  0x00,
  0x0d,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1f,
  0x15,
  0xc4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0a,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9c,
  0x63,
  0x00,
  0x01,
  0x00,
  0x00,
  0x05,
  0x00,
  0x01,
  0x0d,
  0x0a,
  0x2d,
  0xb4,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4e,
  0x44,
  0xae,
  0x42,
  0x60,
  0x82,
];

const _tinyWavBytes = <int>[
  0x52,
  0x49,
  0x46,
  0x46,
  0x24,
  0x00,
  0x00,
  0x00,
  0x57,
  0x41,
  0x56,
  0x45,
  0x66,
  0x6d,
  0x74,
  0x20,
  0x10,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x01,
  0x00,
  0x40,
  0x1f,
  0x00,
  0x00,
  0x80,
  0x3e,
  0x00,
  0x00,
  0x02,
  0x00,
  0x10,
  0x00,
  0x64,
  0x61,
  0x74,
  0x61,
  0x00,
  0x00,
  0x00,
  0x00,
];

const _binaryBytes = <int>[0x00, 0xff, 0x10, 0x80, 0x42, 0x24];

Future<void> _expectGeneratedSessionRegistrationAfterFailedResume(
  String operation,
) async {
  final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
  final agentScript = File('${tempDir.path}/fake_${operation}_race_agent.dart');
  await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

void send(Map<String, dynamic> message) => stdout.writeln(jsonEncode(message));

Future<void> main() async {
  Object? pendingResumeId;
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
          'agentCapabilities': <String, dynamic>{
            'sessionCapabilities': <String, dynamic>{
              'resume': true,
              'fork': true,
            },
          },
          'authMethods': <Map<String, dynamic>>[],
        },
      });
    } else if (message['method'] == 'session/resume') {
      pendingResumeId = message['id'];
    } else if (message['method'] == 'session/$operation') {
      send(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'sessionId': 'shared-session',
          'registrationMarker': '$operation',
        },
      });
    } else if (message['method'] == 'test/release') {
      send(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': pendingResumeId,
        'error': <String, dynamic>{
          'code': -32000,
          'message': 'resume failed',
        },
      });
      send(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{},
      });
    } else if (message['method'] == 'session/prompt') {
      send(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'stopReason': 'end_turn'},
      });
    }
  }
}
''');

  final registrationResponse = Completer<void>();
  final client = await acp.AcpClient.start(
    config: acp.AcpConfig(
      agentCommand: _dartExecutable(),
      agentArgs: [agentScript.path],
      onProtocolIn: (line) {
        if (line.contains('"registrationMarker":"$operation"') &&
            !registrationResponse.isCompleted) {
          registrationResponse.complete();
        }
      },
    ),
  );

  try {
    await client.initialize().timeout(const Duration(seconds: 5));
    final resume = client.resumeSession(
      sessionId: 'shared-session',
      workspaceRoot: '/workspace/provisional',
    );
    final resumeFailure = expectLater(resume, throwsA(anything));
    await pumpEventQueue();

    final Future<String> generated = operation == 'new'
        ? client.newSession('/workspace/generated')
        : client
              .forkSession(
                sessionId: 'source-session',
                workspaceRoot: '/workspace/generated',
              )
              .then((result) => result.sessionId);
    var registrationCompleted = false;
    Object? registrationError;
    final trackedRegistration = generated.then(
      (sessionId) {
        registrationCompleted = true;
        return sessionId;
      },
      onError: (Object error) {
        registrationCompleted = true;
        registrationError = error;
        return 'registration-failed';
      },
    );

    await registrationResponse.future.timeout(const Duration(seconds: 5));
    await pumpEventQueue(times: 2);
    final completedBeforeRollback = registrationCompleted;

    await client
        .sendRaw('test/release', const <String, dynamic>{})
        .timeout(const Duration(seconds: 5));
    await resumeFailure;

    expect(completedBeforeRollback, isFalse);
    expect(registrationError, isNull);
    expect(await trackedRegistration, 'shared-session');
    await client
        .prompt(sessionId: 'shared-session', content: 'still valid')
        .drain<void>()
        .timeout(const Duration(seconds: 5));
  } finally {
    await client.dispose();
    await tempDir.delete(recursive: true);
  }
}

Future<
  ({
    Map<String, dynamic> response,
    int permissionRequestCount,
    bool writeTargetExists,
  })
>
_runInvalidSessionRequest({
  required String method,
  required String? sessionId,
}) async {
  final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
  final workspace = Directory('${tempDir.path}/workspace');
  await workspace.create();
  await File('${workspace.path}/fixture.txt').writeAsString('fixture');
  final writeTarget = File('${workspace.path}/should-not-exist.txt');
  final responseFile = File('${tempDir.path}/invalid_session_response.json');
  final agentScript = File('${tempDir.path}/fake_invalid_session_agent.dart');
  final params = <String, Object?>{
    'sessionId': ?sessionId,
    if (method == 'fs/read_text_file') 'path': 'fixture.txt',
    if (method == 'fs/write_text_file') ...{
      'path': writeTarget.path,
      'content': 'must not be written',
    },
    if (method == 'session/request_permission') ...{
      'toolCall': <String, Object?>{'title': 'Run command', 'kind': 'execute'},
      'options': <Map<String, Object?>>[
        {'optionId': 'allow', 'kind': 'allow_once', 'name': 'Allow'},
        {'optionId': 'deny', 'kind': 'reject_once', 'name': 'Deny'},
      ],
    },
  };
  final methodLiteral = jsonEncode(method);
  final paramsLiteral = jsonEncode(params);
  final responsePath = jsonEncode(responseFile.path);
  final pendingResponsePath = jsonEncode('${responseFile.path}.pending');
  await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{},
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/new') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'sessionId': 'session-1'},
      }));
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': 'invalid-session-request',
        'method': $methodLiteral,
        'params': $paramsLiteral,
      }));
    } else if (message['id'] == 'invalid-session-request') {
      final pendingResponse = File($pendingResponsePath);
      await pendingResponse.writeAsString(jsonEncode(message));
      await pendingResponse.rename($responsePath);
    }
  }
}
''');

  final client = DartAcpAgentClient(
    agentCommand: _dartExecutable(),
    agentArgs: [agentScript.path],
    enableFilesystemReadTextFile: method == 'fs/read_text_file',
    enableFilesystemWriteTextFile: method == 'fs/write_text_file',
  );
  var permissionRequestCount = 0;
  final subscription = client.permissionRequests.listen((request) {
    permissionRequestCount += 1;
    unawaited(
      client.respondToPermissionRequest(
        id: request.id,
        decision: AcpPermissionDecision.deny,
      ),
    );
  });

  try {
    await client.connect().timeout(const Duration(seconds: 5));
    await client.createSession(cwd: workspace.path);
    await _waitForFile(responseFile);
    final response =
        jsonDecode(await responseFile.readAsString()) as Map<String, dynamic>;
    return (
      response: response,
      permissionRequestCount: permissionRequestCount,
      writeTargetExists: await writeTarget.exists(),
    );
  } finally {
    await subscription.cancel();
    await client.dispose();
    await tempDir.delete(recursive: true);
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

Future<void> _waitForFile(File file) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!await file.exists()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Timed out waiting for ${file.path}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

class _TrackingAcpTransport implements acp.AcpTransport {
  final StreamChannelController<String> _controller =
      StreamChannelController<String>();
  var startCount = 0;

  @override
  StreamChannel<String> get channel => _controller.foreign;

  @override
  Future<void> start() async {
    startCount += 1;
  }

  @override
  Future<void> stop() async {}
}

class _ThrowingGetterMap extends MapBase<String, dynamic> {
  _ThrowingGetterMap(
    this._values, {
    required this.throwKey,
    required this.error,
  });

  final Map<String, dynamic> _values;
  final String throwKey;
  final Object error;

  @override
  dynamic operator [](Object? key) {
    if (key == throwKey) throw error;
    return _values[key];
  }

  @override
  void operator []=(String key, dynamic value) => _values[key] = value;

  @override
  void clear() => _values.clear();

  @override
  Iterable<String> get keys => _values.keys;

  @override
  dynamic remove(Object? key) => _values.remove(key);
}

class _ReentrantSessionEnvelope extends MapBase<String, dynamic> {
  _ReentrantSessionEnvelope({required this.onSessionIdRead});

  final void Function() onSessionIdRead;
  var _read = false;

  @override
  dynamic operator [](Object? key) {
    if (key == 'sessionId' && !_read) {
      _read = true;
      onSessionIdRead();
      return 'unowned-reentrant-envelope';
    }
    return null;
  }

  @override
  void operator []=(String key, dynamic value) =>
      throw UnsupportedError('immutable');

  @override
  void clear() => throw UnsupportedError('immutable');

  @override
  Iterable<String> get keys => const <String>['sessionId'];

  @override
  dynamic remove(Object? key) => throw UnsupportedError('immutable');
}

class _RecordingTerminalProvider implements acp.TerminalProvider {
  _RecordingTerminalProvider({
    this.failReleaseIds = const <String>{},
    this.releaseErrorMessage = 'injected terminal release failure',
    this.createBarrier,
    this.createStarted,
    this.releaseBarrier,
    this.releaseStarted,
    this.failCreateCalls = const <int>{},
    this.failLimitCalls = const <int>{},
    Map<int, Completer<void>>? createBarriers,
    this.terminalIdsByCall = const <int, String>{},
  }) : createBarriers = createBarriers ?? <int, Completer<void>>{};

  final Set<String> failReleaseIds;
  final String releaseErrorMessage;
  final Completer<void>? createBarrier;
  final Completer<void>? createStarted;
  final Completer<void>? releaseBarrier;
  final Completer<void>? releaseStarted;
  final Set<int> failCreateCalls;
  final Set<int> failLimitCalls;
  final Map<int, Completer<void>> createBarriers;
  final Map<int, String> terminalIdsByCall;
  final List<String> createSessions = <String>[];
  final List<String> releaseAttempts = <String>[];
  final List<acp.TerminalProcessHandle> createdHandles =
      <acp.TerminalProcessHandle>[];
  final List<acp.TerminalProcessHandle> releaseHandles =
      <acp.TerminalProcessHandle>[];

  int get createCalls => createSessions.length;

  @override
  Future<acp.TerminalProcessHandle> create({
    required String sessionId,
    required String command,
    List<String> args = const <String>[],
    String? cwd,
    Map<String, String>? env,
    int? outputByteLimit,
  }) async {
    createSessions.add(sessionId);
    final call = createCalls;
    final started = createStarted;
    if (started != null && !started.isCompleted) started.complete();
    await (createBarriers[call] ?? createBarrier)?.future;
    if (failCreateCalls.contains(call)) {
      throw StateError('injected terminal create failure');
    }
    if (failLimitCalls.contains(call)) {
      throw const acp.TerminalHandleLimitException(
        reason: acp.TerminalHandleLimitReason.global,
        limit: 1,
      );
    }
    final process = await Process.start('/bin/sh', const <String>[
      '-c',
      'sleep 30',
    ]);
    final handle = acp.TerminalProcessHandle(
      terminalId: terminalIdsByCall[call] ?? 'terminal-$call',
      process: process,
      outputByteLimit: outputByteLimit,
    );
    createdHandles.add(handle);
    return handle;
  }

  @override
  Future<String> currentOutput(acp.TerminalProcessHandle handle) async =>
      handle.currentOutput();

  @override
  Future<void> kill(acp.TerminalProcessHandle handle) => handle.kill();

  @override
  Future<void> release(acp.TerminalProcessHandle handle) async {
    releaseAttempts.add(handle.terminalId);
    releaseHandles.add(handle);
    final started = releaseStarted;
    if (started != null && !started.isCompleted) started.complete();
    await releaseBarrier?.future;
    await handle.release();
    if (failReleaseIds.contains(handle.terminalId)) {
      throw StateError(releaseErrorMessage);
    }
  }

  @override
  Future<int> waitForExit(acp.TerminalProcessHandle handle) =>
      handle.waitForExit();
}
