import 'dart:async';
import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:stream_channel/stream_channel.dart';

/// Alias for a JSON map used in requests/responses.
typedef Json = Map<String, dynamic>;

/// Thin wrapper around json_rpc_2.Peer with client handler hooks.
class JsonRpcPeer {
  /// Construct a peer bound to a [channel].
  JsonRpcPeer(StreamChannel<String> channel) : _peer = rpc.Peer(channel) {
    _registerClientHandlers();
    // Start listening for messages; fire-and-forget intentionally.
    unawaited(_peer.listen());
  }

  /// Underlying JSON-RPC peer.
  final rpc.Peer _peer;
  final StreamController<Json> _sessionUpdates = StreamController.broadcast();

  /// Close the peer and clean up resources.
  Future<void> close() async {
    await _peer.close();
    await _sessionUpdates.close();
  }

  /// Stream of raw `session/update` notifications.
  Stream<Json> get sessionUpdates => _sessionUpdates.stream;

  void _registerClientHandlers() {
    _peer.registerMethod('session/update', (rpc.Parameters params) async {
      final json = params.value as Map;
      _sessionUpdates.add(Map<String, dynamic>.from(json));
      return null;
    });
    // The following methods are handled by higher-level wiring. We expose
    // registration points for them via onX setters.
    // Filesystem callbacks (Agent -> Client)
    _peer.registerMethod('fs/read_text_file', (rpc.Parameters params) async {
      if (onReadTextFile == null) {
        throw rpc.RpcException.methodNotFound('fs/read_text_file');
      }
      final json = Map<String, dynamic>.from(params.value as Map);
      return onReadTextFile!(json);
    });
    _peer.registerMethod('fs/write_text_file', (rpc.Parameters params) async {
      if (onWriteTextFile == null) {
        throw rpc.RpcException.methodNotFound('fs/write_text_file');
      }
      final json = Map<String, dynamic>.from(params.value as Map);
      return onWriteTextFile!(json);
    });
    // Permissioning (Agent -> Client)
    _peer.registerMethod('session/request_permission', (
      rpc.Parameters params,
    ) async {
      if (onRequestPermission == null) {
        throw rpc.RpcException.methodNotFound('session/request_permission');
      }
      final json = Map<String, dynamic>.from(params.value as Map);
      return onRequestPermission!(json);
    });
    // Terminal callbacks (Agent -> Client)
    _peer.registerMethod('terminal/create', (rpc.Parameters params) async {
      if (onTerminalCreate == null) {
        throw rpc.RpcException.methodNotFound('terminal/create');
      }
      final json = Map<String, dynamic>.from(params.value as Map);
      return onTerminalCreate!(json);
    });
    _peer.registerMethod('terminal/output', (rpc.Parameters params) async {
      if (onTerminalOutput == null) {
        throw rpc.RpcException.methodNotFound('terminal/output');
      }
      final json = Map<String, dynamic>.from(params.value as Map);
      return onTerminalOutput!(json);
    });
    _peer.registerMethod('terminal/wait_for_exit', (
      rpc.Parameters params,
    ) async {
      if (onTerminalWaitForExit == null) {
        throw rpc.RpcException.methodNotFound('terminal/wait_for_exit');
      }
      final json = Map<String, dynamic>.from(params.value as Map);
      return onTerminalWaitForExit!(json);
    });
    _peer.registerMethod('terminal/kill', (rpc.Parameters params) async {
      if (onTerminalKill == null) {
        throw rpc.RpcException.methodNotFound('terminal/kill');
      }
      final json = Map<String, dynamic>.from(params.value as Map);
      return onTerminalKill!(json);
    });
    _peer.registerMethod('terminal/release', (rpc.Parameters params) async {
      if (onTerminalRelease == null) {
        throw rpc.RpcException.methodNotFound('terminal/release');
      }
      final json = Map<String, dynamic>.from(params.value as Map);
      return onTerminalRelease!(json);
    });
  }

  /// Client handlers (Agent -> Client callbacks)
  /// Handler invoked when agent requests `fs/read_text_file`.
  Future<dynamic> Function(Json)? onReadTextFile;

  /// Handler invoked when agent requests `fs/write_text_file`.
  Future<dynamic> Function(Json)? onWriteTextFile;

  /// Handler invoked when agent requests `session/request_permission`.
  Future<dynamic> Function(Json)? onRequestPermission;

  /// Handler invoked when agent requests `terminal/create`.
  Future<dynamic> Function(Json)? onTerminalCreate;

  /// Handler invoked when agent requests `terminal/output`.
  Future<dynamic> Function(Json)? onTerminalOutput;

  /// Handler invoked when agent requests `terminal/wait_for_exit`.
  Future<dynamic> Function(Json)? onTerminalWaitForExit;

  /// Handler invoked when agent requests `terminal/kill`.
  Future<dynamic> Function(Json)? onTerminalKill;

  /// Handler invoked when agent requests `terminal/release`.
  Future<dynamic> Function(Json)? onTerminalRelease;

  /// Send `initialize` and return the JSON payload.
  Future<Json> initialize(Json params) async =>
      Map<String, dynamic>.from(await _peer.sendRequest('initialize', params));

  /// Send `session/new` and return the JSON payload.
  Future<Json> newSession(Json params) async =>
      Map<String, dynamic>.from(await _peer.sendRequest('session/new', params));

  /// Send `session/load` for replay.
  Future<void> loadSession(Json params) async =>
      _peer.sendRequest('session/load', params);

  /// Send `session/prompt` and return the terminal result payload.
  Future<Json> prompt(Json params) async => Map<String, dynamic>.from(
    await _peer.sendRequest('session/prompt', params),
  );

  /// Send `session/cancel` as a notification.
  Future<void> cancel(Json params) async =>
      _peer.sendNotification('session/cancel', params);

  /// (Extension) Send `session/set_mode` to change the session's mode.
  Future<void> setSessionMode(Json params) async =>
      _peer.sendRequest('session/set_mode', params);

  /// Send an arbitrary JSON-RPC request by method name with params.
  Future<Json> sendRaw(String method, Json params) async =>
      Map<String, dynamic>.from(await _peer.sendRequest(method, params));

  /// Send an arbitrary JSON-RPC notification by method name with params.
  Future<void> sendNotificationRaw(String method, Json params) async =>
      _peer.sendNotification(method, params);
}
