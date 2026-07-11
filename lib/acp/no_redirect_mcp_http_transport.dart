import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_acp/dart_acp.dart' as acp;
import 'package:mcp_dart/mcp_dart.dart' as mcp;

import 'acp_endpoint_validator.dart';

/// Minimal MCP Streamable HTTP transport whose requests never follow redirects.
///
/// This is intentionally implemented with dart:io because mcp_dart's HTTP
/// transport does not expose an HTTP client or redirect policy injection point.
class NoRedirectMcpHttpTransport implements mcp.Transport {
  NoRedirectMcpHttpTransport({
    required this.endpoint,
    this.headers = const <String, String>{},
    this.requestTimeout = const Duration(seconds: 30),
    this.teardownTimeout = const Duration(seconds: 2),
    this.byteBudget = const acp.TransportByteBudget(),
  }) : assert(requestTimeout > Duration.zero),
       assert(teardownTimeout > Duration.zero) {
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
        );
      } else {
        _handleResponse(response);
      }

      if (_isInitializedNotification(message)) {
        unawaited(_ensureSseStream().catchError(_reportAsyncError));
      }
    } catch (error) {
      _reportError(error);
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
        _readResponseBody(response, resource: 'MCP HTTP JSON response body')
            .then<void>((body) {
              final decoded = jsonDecode(body);
              if (decoded is List) {
                for (final item in decoded) {
                  _emitJsonRpc(item);
                }
              } else {
                _emitJsonRpc(decoded);
              }
            })
            .catchError(_reportAsyncError),
      );
      return;
    }
    unawaited(
      _drainResponse(
        response,
        resource: 'MCP HTTP unsupported response body',
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
      );
      return;
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await _drainResponse(
        response,
        resource: 'MCP HTTP SSE error response body',
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
            try {
              _emitJsonRpc(jsonDecode(data));
            } catch (error) {
              _reportError(error);
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            _reportError(error);
          },
          onDone: () {
            _sseSubscriptions.remove(subscription);
          },
        );
    _sseSubscriptions.add(subscription);
  }

  void _emitJsonRpc(Object? decoded) {
    if (decoded is! Map) {
      throw const FormatException('MCP HTTP response must be a JSON object.');
    }
    final json = decoded.map((key, value) => MapEntry(key.toString(), value));
    onmessage?.call(mcp.JsonRpcMessage.fromJson(json));
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
    _reportError(error);
  }

  Future<String> _readResponseBody(
    HttpClientResponse response, {
    required String resource,
  }) async {
    await _enforceResponseContentLength(response, resource: resource);
    return acp.readBoundedUtf8Body(
      response,
      limit: byteBudget.maxBodyBytes,
      resource: resource,
    );
  }

  Future<void> _drainResponse(
    HttpClientResponse response, {
    required String resource,
  }) async {
    await _enforceResponseContentLength(response, resource: resource);
    await acp.drainBoundedBytes(
      response,
      limit: byteBudget.maxBodyBytes,
      resource: resource,
    );
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
    final subscriptions = List<StreamSubscription<String>>.of(
      _sseSubscriptions,
    );
    _sseSubscriptions.clear();
    final client = _client;
    _client = null;
    final session = _sessionId;
    _sessionId = null;
    try {
      await _closeNetworkResources(
        subscriptions: subscriptions,
        client: client,
        session: session,
      ).timeout(teardownTimeout);
    } on Object {
      // Remote teardown is best effort; local resources still close.
    } finally {
      client?.close(force: true);
      onclose?.call();
    }
  }

  Future<void> _closeNetworkResources({
    required List<StreamSubscription<String>> subscriptions,
    required HttpClient? client,
    required String? session,
  }) async {
    await Future.wait<void>([
      for (final subscription in subscriptions)
        subscription.cancel().catchError((Object _) {}),
    ]);
    if (client == null || session == null) return;

    final request = await client.deleteUrl(endpoint);
    request.followRedirects = false;
    for (final entry in headers.entries) {
      request.headers.set(entry.key, entry.value);
    }
    request.headers.set('Mcp-Session-Id', session);
    final response = await request.close();
    await _drainResponse(response, resource: 'MCP HTTP DELETE response body');
  }
}
