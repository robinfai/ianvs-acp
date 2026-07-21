import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart' as mcp;

import 'acp_endpoint_validator.dart';
import 'transport_byte_budget.dart' as acp;

/// Minimal MCP Streamable HTTP transport whose requests never follow redirects.
///
/// This is intentionally implemented with dart:io because mcp_dart's HTTP
/// transport does not expose an HTTP client or redirect policy injection point.
class NoRedirectMcpHttpTransport implements mcp.Transport {
  NoRedirectMcpHttpTransport({
    required this.endpoint,
    this.headers = const <String, String>{},
    Duration requestTimeout = const Duration(seconds: 30),
    Duration teardownTimeout = const Duration(seconds: 2),
    this.byteBudget = const acp.TransportByteBudget(),
  }) : requestTimeout = _positiveDuration(requestTimeout, 'requestTimeout'),
       teardownTimeout = _positiveDuration(teardownTimeout, 'teardownTimeout') {
    byteBudget.validate();
    validateAcpEndpoint(
      endpoint,
      allowedSchemes: const <String>{'http', 'https'},
    );
  }

  final Uri endpoint;
  final Map<String, String> headers;
  final Duration requestTimeout;
  final Duration teardownTimeout;
  final acp.TransportByteBudget byteBudget;

  final List<StreamSubscription<String>> _sseSubscriptions =
      <StreamSubscription<String>>[];
  final Set<acp.TransportBodyReadOperation<Object?>> _pendingBodyReads =
      <acp.TransportBodyReadOperation<Object?>>{};

  HttpClient? _client;
  Future<void>? _sseStart;
  String? _sessionId;
  bool _closed = false;

  @override
  void Function()? onclose;

  @override
  void Function(Error error)? onerror;

  @override
  void Function(mcp.JsonRpcMessage message)? onmessage;

  @override
  String? get sessionId => _sessionId;

  /// Number of one-shot response bodies currently being read.
  int get activeBodyReadCount => _pendingBodyReads.length;

  @override
  Future<void> start() async {
    if (_client != null) {
      throw StateError('MCP HTTP transport is already started.');
    }
    if (_closed) {
      throw StateError('MCP HTTP transport is closed.');
    }
    _client = HttpClient();
  }

  @override
  Future<void> send(mcp.JsonRpcMessage message, {int? relatedRequestId}) async {
    final client = _requireClient();
    try {
      final request = await client.postUrl(endpoint).timeout(requestTimeout);
      request.followRedirects = false;
      _applyHeaders(
        request,
        contentType: ContentType.json,
        accept: 'application/json, text/event-stream',
      );
      request.write(jsonEncode(message.toJson()));
      final response = await request.close().timeout(requestTimeout);
      _captureSession(response);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        await _drainResponse(
          response,
          resource: 'MCP HTTP POST error response body',
          timeout: requestTimeout,
        );
        throw mcp.McpError(
          0,
          'MCP HTTP POST failed with ${response.statusCode}: '
          '${response.reasonPhrase}',
        );
      }
      if (response.statusCode == HttpStatus.accepted) {
        await _drainResponse(
          response,
          resource: 'MCP HTTP POST accepted response body',
          timeout: requestTimeout,
        );
      } else {
        _handleResponse(response);
      }

      if (_isInitializedNotification(message)) {
        unawaited(_ensureSseStream().catchError(_reportAsyncError));
      }
    } catch (error) {
      if (!_closed) _reportError(error);
      rethrow;
    }
  }

  void _handleResponse(HttpClientResponse response) {
    final contentType = response.headers.contentType?.mimeType.toLowerCase();
    if (contentType == 'text/event-stream') {
      _listenToSse(response);
      return;
    }
    if (contentType == 'application/json') {
      unawaited(
        _readResponseBody(
              response,
              resource: 'MCP HTTP JSON response body',
              timeout: requestTimeout,
            )
            .then<void>((body) {
              final decoded = acp.decodeTransportJson(
                body,
                resource: 'MCP HTTP POST JSON',
              );
              final messages = _decodeJsonRpcMessages(
                decoded,
                resource: 'MCP HTTP POST JSON',
              );
              _deliverJsonRpcMessages(messages);
            })
            .catchError(_reportAsyncError),
      );
      return;
    }
    unawaited(
      _drainResponse(
        response,
        resource: 'MCP HTTP unsupported response body',
        timeout: requestTimeout,
      ).catchError(_reportAsyncError),
    );
    throw mcp.McpError(
      0,
      'MCP HTTP response has unsupported content type: '
      '${response.headers.value(HttpHeaders.contentTypeHeader) ?? '<missing>'}',
    );
  }

  Future<void> _ensureSseStream() {
    final existing = _sseStart;
    if (existing != null) return existing;
    final start = _openSseStream();
    _sseStart = start;
    return start.whenComplete(() {
      if (identical(_sseStart, start)) {
        _sseStart = null;
      }
    });
  }

  Future<void> _openSseStream() async {
    final client = _requireClient();
    final request = await client.getUrl(endpoint).timeout(requestTimeout);
    request.followRedirects = false;
    _applyHeaders(request, accept: 'text/event-stream');
    final response = await request.close().timeout(requestTimeout);
    _captureSession(response);
    if (response.statusCode == HttpStatus.methodNotAllowed) {
      await _drainResponse(
        response,
        resource: 'MCP HTTP SSE method response body',
        timeout: requestTimeout,
      );
      return;
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await _drainResponse(
        response,
        resource: 'MCP HTTP SSE error response body',
        timeout: requestTimeout,
      );
      throw mcp.McpError(
        0,
        'MCP HTTP SSE GET failed with ${response.statusCode}: '
        '${response.reasonPhrase}',
      );
    }
    if (response.headers.contentType?.mimeType.toLowerCase() !=
        'text/event-stream') {
      await _drainResponse(
        response,
        resource: 'MCP HTTP SSE non-SSE response body',
        timeout: requestTimeout,
      );
      throw mcp.McpError(0, 'MCP HTTP SSE GET returned a non-SSE response.');
    }
    _listenToSse(response);
  }

  void _listenToSse(Stream<List<int>> response) {
    late final StreamSubscription<String> subscription;
    subscription = acp
        .decodeBoundedSse(
          response,
          budget: byteBudget,
          resource: 'MCP HTTP SSE',
        )
        .where((event) => event.event == null || event.event == 'message')
        .map((event) => event.data)
        .listen(
          (data) {
            if (_closed) return;
            final mcp.JsonRpcMessage message;
            try {
              message = _decodeJsonRpcMessage(
                acp.decodeTransportJson(data, resource: 'MCP HTTP SSE JSON'),
                resource: 'MCP HTTP SSE JSON',
              );
            } catch (error) {
              _reportError(error);
              return;
            }
            _deliverJsonRpcMessages(<mcp.JsonRpcMessage>[message]);
          },
          onError: (Object error, StackTrace stackTrace) {
            if (_closed) return;
            _reportError(error);
          },
          onDone: () {
            _sseSubscriptions.remove(subscription);
          },
        );
    _sseSubscriptions.add(subscription);
  }

  List<mcp.JsonRpcMessage> _decodeJsonRpcMessages(
    Object? decoded, {
    required String resource,
  }) {
    final values = decoded is List ? decoded : <Object?>[decoded];
    if (values.isEmpty) {
      throw acp.TransportProtocolDecodeError(resource: resource);
    }
    return values
        .map((value) => _decodeJsonRpcMessage(value, resource: resource))
        .toList(growable: false);
  }

  mcp.JsonRpcMessage _decodeJsonRpcMessage(
    Object? decoded, {
    required String resource,
  }) {
    final mcp.JsonRpcMessage message;
    try {
      if (decoded is! Map) {
        throw StateError('Remote JSON-RPC value is not an object.');
      }
      final json = decoded.map((key, value) => MapEntry(key.toString(), value));
      message = mcp.JsonRpcMessage.fromJson(json);
    } on Object {
      throw acp.TransportProtocolDecodeError(resource: resource);
    }
    return message;
  }

  void _deliverJsonRpcMessages(Iterable<mcp.JsonRpcMessage> messages) {
    for (final message in messages) {
      if (_closed) return;
      try {
        onmessage?.call(message);
      } catch (error) {
        if (!_closed) _reportError(error);
      }
    }
  }

  void _captureSession(HttpClientResponse response) {
    final session = response.headers.value('Mcp-Session-Id')?.trim();
    if (session != null && session.isNotEmpty) {
      _sessionId = session;
    }
  }

  void _applyHeaders(
    HttpClientRequest request, {
    ContentType? contentType,
    String? accept,
  }) {
    for (final entry in headers.entries) {
      request.headers.set(entry.key, entry.value);
    }
    if (contentType != null) request.headers.contentType = contentType;
    if (accept != null) request.headers.set(HttpHeaders.acceptHeader, accept);
    final session = _sessionId;
    if (session != null) request.headers.set('Mcp-Session-Id', session);
  }

  HttpClient _requireClient() {
    final client = _client;
    if (client == null || _closed) {
      throw StateError('MCP HTTP transport is not started.');
    }
    return client;
  }

  bool _isInitializedNotification(mcp.JsonRpcMessage message) {
    return message is mcp.JsonRpcNotification &&
        message.method == mcp.Method.notificationsInitialized;
  }

  FutureOr<void> _reportAsyncError(Object error) {
    if (_closed) return null;
    _reportError(error);
  }

  Future<String> _readResponseBody(
    HttpClientResponse response, {
    required String resource,
    required Duration timeout,
  }) async {
    await _enforceResponseContentLength(response, resource: resource);
    return _runBodyRead(
      acp.startBoundedUtf8BodyRead(
        response,
        limit: byteBudget.maxBodyBytes,
        resource: resource,
        timeout: timeout,
      ),
    );
  }

  Future<void> _drainResponse(
    HttpClientResponse response, {
    required String resource,
    required Duration timeout,
  }) async {
    await _enforceResponseContentLength(response, resource: resource);
    await _runBodyRead(
      acp.startBoundedByteDrain(
        response,
        limit: byteBudget.maxBodyBytes,
        resource: resource,
        timeout: timeout,
      ),
    );
  }

  Future<T> _runBodyRead<T>(acp.TransportBodyReadOperation<T> operation) async {
    _pendingBodyReads.add(operation);
    try {
      return await operation.future;
    } finally {
      _pendingBodyReads.remove(operation);
    }
  }

  Future<void> _cancelPendingBodyReads() async {
    final pending = List<acp.TransportBodyReadOperation<Object?>>.of(
      _pendingBodyReads,
    );
    await Future.wait<void>([
      for (final operation in pending)
        operation.cancel().catchError((Object _) {}),
    ]);
  }

  Future<void> _enforceResponseContentLength(
    HttpClientResponse response, {
    required String resource,
  }) async {
    try {
      acp.enforceTransportContentLength(
        contentLength: response.contentLength,
        limit: byteBudget.maxBodyBytes,
        resource: resource,
      );
    } on acp.TransportByteLimitExceeded {
      final subscription = response.listen((_) {});
      await subscription.cancel();
      rethrow;
    }
  }

  void _reportError(Object error) {
    onerror?.call(error is Error ? error : mcp.McpError(0, error.toString()));
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final sseCancellations = _cancelSseSubscriptions();
    await _cancelPendingBodyReads();
    final client = _client;
    _client = null;
    final session = _sessionId;
    _sessionId = null;
    try {
      await _closeNetworkResources(
        client: client,
        session: session,
      ).timeout(teardownTimeout);
    } on Object {
      // Remote teardown is best effort; local resources still close.
    } finally {
      await _cancelPendingBodyReads();
      client?.close(force: true);
      await Future.wait<void>(sseCancellations);
      await Future.wait<void>(_cancelSseSubscriptions());
      onclose?.call();
    }
  }

  List<Future<void>> _cancelSseSubscriptions() {
    final subscriptions = List<StreamSubscription<String>>.of(
      _sseSubscriptions,
    );
    _sseSubscriptions.clear();
    return <Future<void>>[
      for (final subscription in subscriptions)
        subscription.cancel().catchError((Object _) {}),
    ];
  }

  Future<void> _closeNetworkResources({
    required HttpClient? client,
    required String? session,
  }) async {
    if (client == null || session == null) return;

    final request = await client.deleteUrl(endpoint);
    request.followRedirects = false;
    for (final entry in headers.entries) {
      request.headers.set(entry.key, entry.value);
    }
    request.headers.set('Mcp-Session-Id', session);
    final response = await request.close();
    await _drainResponse(
      response,
      resource: 'MCP HTTP DELETE response body',
      timeout: teardownTimeout,
    );
  }
}

Duration _positiveDuration(Duration value, String name) {
  if (value <= Duration.zero) {
    throw ArgumentError.value(value, name, 'must be greater than zero');
  }
  return value;
}
