import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_acp/dart_acp.dart' as acp;
import 'package:stream_channel/stream_channel.dart';

class StreamableHttpAcpTransport implements acp.AcpTransport {
  StreamableHttpAcpTransport({
    required this.endpoint,
    this.headers = const <String, String>{},
    this.onProtocolOut,
    this.onProtocolIn,
  });

  final Uri endpoint;
  final Map<String, String> headers;
  final void Function(String line)? onProtocolOut;
  final void Function(String line)? onProtocolIn;

  final HttpClient _client = HttpClient();
  final Map<String, String> _pendingMethodsById = <String, String>{};
  final Map<String, String> _serverRequestSessionsById = <String, String>{};
  final Map<String, Future<void>> _streamStartsByKey = <String, Future<void>>{};
  final Map<String, Cookie> _cookiesByName = <String, Cookie>{};
  final List<StreamSubscription<String>> _streamSubscriptions =
      <StreamSubscription<String>>[];

  static const Duration _teardownTimeout = Duration(seconds: 2);
  static const String _protocolVersionHeader = 'Acp-Protocol-Version';

  StreamChannelController<String>? _controller;
  StreamSubscription<String>? _outboundSubscription;
  String? _connectionId;
  bool _stopping = false;

  @override
  StreamChannel<String> get channel {
    final controller = _controller;
    if (controller == null) {
      throw StateError('Transport not started');
    }
    return controller.foreign;
  }

  @override
  Future<void> start() async {
    if (_controller != null) return;
    final controller = StreamChannelController<String>();
    _controller = controller;
    _outboundSubscription = controller.local.stream.listen((line) {
      unawaited(_sendLine(line));
    }, onError: controller.local.sink.addError);
  }

  Future<void> _sendLine(String line) async {
    if (_stopping) return;
    onProtocolOut?.call(line);
    String? pendingMethodIdKey;
    try {
      final message = jsonDecode(line);
      if (message is! Map<String, dynamic>) {
        throw const FormatException(
          'ACP HTTP transport requires JSON objects.',
        );
      }
      final idKey = _idKey(message['id']);
      final method = message['method'];
      if (idKey != null && method is String) {
        _pendingMethodsById[idKey] = method;
        pendingMethodIdKey = idKey;
      }

      final sessionId = _sessionIdForOutbound(message, idKey);
      final isInitialize = method == 'initialize';
      if (!isInitialize) {
        await _ensureInboundStream(null);
      }
      if (sessionId != null) {
        await _ensureInboundStream(sessionId);
      }

      final request = await _client.postUrl(endpoint);
      _applyRequestHeaders(
        request,
        contentType: ContentType.json,
        sessionId: sessionId,
      );
      request.write(line);
      final response = await request.close();
      _storeCookies(response.cookies);

      final body = await response.transform(utf8.decoder).join();
      if (isInitialize) {
        _handleInitializeResponse(response, body);
        return;
      }
      if (response.statusCode == HttpStatus.accepted && body.trim().isEmpty) {
        return;
      }
      if (response.statusCode >= 200 && response.statusCode < 300) {
        _addInboundLine(body);
        return;
      }
      throw HttpException(
        'ACP HTTP POST failed with ${response.statusCode}: ${response.reasonPhrase}',
        uri: endpoint,
      );
    } catch (error, stackTrace) {
      if (pendingMethodIdKey != null) {
        _pendingMethodsById.remove(pendingMethodIdKey);
      }
      if (!_stopping) {
        _controller?.local.sink.addError(error, stackTrace);
      }
    }
  }

  String? _sessionIdForOutbound(Map<String, dynamic> message, String? idKey) {
    final method = message['method'];
    if (method is String) {
      final params = message['params'];
      if (params is Map) {
        final sessionId = params['sessionId'];
        if (sessionId is String && sessionId.trim().isNotEmpty) {
          return sessionId.trim();
        }
      }
      return null;
    }
    if (idKey == null) return null;
    return _serverRequestSessionsById.remove(idKey);
  }

  void _handleInitializeResponse(HttpClientResponse response, String body) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'ACP HTTP initialize failed with ${response.statusCode}: ${response.reasonPhrase}',
        uri: endpoint,
      );
    }
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('ACP HTTP initialize returned invalid JSON.');
    }
    final connectionId =
        response.headers.value('Acp-Connection-Id') ??
        _stringFromPath(decoded, const ['result', 'connectionId']) ??
        _stringFromPath(decoded, const ['result', 'connection_id']);
    if (connectionId == null || connectionId.trim().isEmpty) {
      throw const FormatException(
        'ACP HTTP initialize response did not include Acp-Connection-Id.',
      );
    }
    _connectionId = connectionId.trim();
    unawaited(_ensureInboundStream(null));
    _addInboundLine(body);
  }

  Future<void> _ensureInboundStream(String? sessionId) {
    final connectionId = _connectionId;
    if (connectionId == null || connectionId.isEmpty) {
      throw StateError('ACP HTTP transport is not initialized.');
    }
    final key = sessionId ?? '';
    return _streamStartsByKey.putIfAbsent(key, () async {
      try {
        final request = await _client.getUrl(endpoint);
        _applyRequestHeaders(request, accept: 'text/event-stream');
        request.headers.set('Acp-Connection-Id', connectionId);
        if (sessionId != null) {
          request.headers.set('Acp-Session-Id', sessionId);
        }
        final response = await request.close();
        _storeCookies(response.cookies);
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw HttpException(
            'ACP HTTP SSE stream failed with ${response.statusCode}: ${response.reasonPhrase}',
            uri: endpoint,
          );
        }
        final subscription = _sseEvents(response).listen(
          _handleSseEvent,
          onError: (Object error, StackTrace stackTrace) {
            if (!_stopping) {
              _controller?.local.sink.addError(error, stackTrace);
            }
          },
        );
        _streamSubscriptions.add(subscription);
      } catch (error, stackTrace) {
        _streamStartsByKey.remove(key);
        if (_stopping) return;
        _controller?.local.sink.addError(error, stackTrace);
        rethrow;
      }
    });
  }

  Stream<String> _sseEvents(Stream<List<int>> response) async* {
    final dataLines = <String>[];
    await for (final line
        in response.transform(utf8.decoder).transform(const LineSplitter())) {
      if (line.isEmpty) {
        if (dataLines.isNotEmpty) {
          yield dataLines.join('\n');
          dataLines.clear();
        }
        continue;
      }
      if (line.startsWith(':')) continue;
      if (line.startsWith('data:')) {
        dataLines.add(line.substring(5).trimLeft());
      }
    }
    if (dataLines.isNotEmpty) {
      yield dataLines.join('\n');
    }
  }

  void _handleSseEvent(String event) {
    if (event.trim().isEmpty) return;
    try {
      _addInboundLine(event);
    } catch (error, stackTrace) {
      if (!_stopping) {
        _controller?.local.sink.addError(error, stackTrace);
      }
    }
  }

  void _addInboundLine(String line) {
    if (line.trim().isEmpty) return;
    _captureInboundMetadata(line);
    onProtocolIn?.call(line);
    _controller?.local.sink.add(line);
  }

  void _captureInboundMetadata(String line) {
    final decoded = jsonDecode(line);
    if (decoded is! Map<String, dynamic>) return;
    final idKey = _idKey(decoded['id']);
    final isResponse =
        decoded.containsKey('result') || decoded.containsKey('error');
    if (idKey != null && isResponse) {
      final method = _pendingMethodsById.remove(idKey);
      if (decoded.containsKey('result') &&
          (method == 'session/new' ||
              method == 'session/load' ||
              method == 'session/resume' ||
              method == 'session/fork')) {
        final sessionId = _stringFromPath(decoded, const [
          'result',
          'sessionId',
        ]);
        if (sessionId != null) {
          unawaited(_ensureInboundStream(sessionId));
        }
      }
    }
    final method = decoded['method'];
    if (idKey != null && method is String) {
      final params = decoded['params'];
      final sessionId = params is Map ? params['sessionId'] : null;
      if (sessionId is String && sessionId.trim().isNotEmpty) {
        _serverRequestSessionsById[idKey] = sessionId.trim();
      }
    }
  }

  void _applyRequestHeaders(
    HttpClientRequest request, {
    ContentType? contentType,
    String? accept,
    String? sessionId,
  }) {
    for (final entry in headers.entries) {
      request.headers.set(entry.key, entry.value);
    }
    if (contentType != null) {
      request.headers.contentType = contentType;
    }
    if (accept != null) {
      request.headers.set(HttpHeaders.acceptHeader, accept);
    }
    final connectionId = _connectionId;
    if (connectionId != null && connectionId.isNotEmpty) {
      request.headers.set('Acp-Connection-Id', connectionId);
      request.headers.set(_protocolVersionHeader, '1');
    }
    if (sessionId != null && sessionId.isNotEmpty) {
      request.headers.set('Acp-Session-Id', sessionId);
    }
    request.cookies.addAll(_cookiesByName.values);
  }

  void _storeCookies(List<Cookie> cookies) {
    for (final cookie in cookies) {
      _cookiesByName[cookie.name] = cookie;
    }
  }

  String? _idKey(Object? id) {
    if (id == null) return null;
    return jsonEncode(id);
  }

  String? _stringFromPath(Map<String, dynamic> json, List<String> path) {
    Object? current = json;
    for (final key in path) {
      if (current is! Map) return null;
      current = current[key];
    }
    return current is String && current.trim().isNotEmpty
        ? current.trim()
        : null;
  }

  @override
  Future<void> stop() async {
    _stopping = true;
    await _outboundSubscription?.cancel();
    _outboundSubscription = null;
    await _terminateConnection();
    _client.close(force: true);
    for (final subscription in _streamSubscriptions) {
      try {
        await subscription.cancel();
      } catch (error, stackTrace) {
        if (!_stopping) {
          Error.throwWithStackTrace(error, stackTrace);
        }
      }
    }
    _streamSubscriptions.clear();
    await _controller?.local.sink.close();
    _controller = null;
    _connectionId = null;
    _pendingMethodsById.clear();
    _serverRequestSessionsById.clear();
    _streamStartsByKey.clear();
    _cookiesByName.clear();
  }

  Future<void> _terminateConnection() async {
    final connectionId = _connectionId;
    if (connectionId == null || connectionId.isEmpty) return;
    try {
      final request = await _client
          .deleteUrl(endpoint)
          .timeout(_teardownTimeout);
      _applyRequestHeaders(request);
      request.headers.set('Acp-Connection-Id', connectionId);
      final response = await request.close().timeout(_teardownTimeout);
      _storeCookies(response.cookies);
      await response.drain<void>().timeout(_teardownTimeout);
    } on Object {
      // Remote teardown is best effort; local disposal must always finish.
    }
  }
}
