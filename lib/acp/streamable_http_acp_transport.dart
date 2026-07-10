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
    this.requestTimeout = const Duration(seconds: 30),
    this.firstByteTimeout = const Duration(seconds: 15),
    this.sseIdleTimeout = const Duration(minutes: 5),
  }) : assert(requestTimeout > Duration.zero),
       assert(firstByteTimeout > Duration.zero),
       assert(sseIdleTimeout > Duration.zero);

  final Uri endpoint;
  final Map<String, String> headers;
  final void Function(String line)? onProtocolOut;
  final void Function(String line)? onProtocolIn;
  final Duration requestTimeout;
  final Duration firstByteTimeout;
  final Duration sseIdleTimeout;

  final Map<String, String> _pendingMethodsById = <String, String>{};
  final Map<String, String> _serverRequestSessionsById = <String, String>{};
  final Map<String, Future<void>> _streamStartsByKey = <String, Future<void>>{};
  final Map<String, Cookie> _cookiesByName = <String, Cookie>{};
  final List<StreamSubscription<String>> _streamSubscriptions =
      <StreamSubscription<String>>[];

  static const Duration _teardownTimeout = Duration(seconds: 2);
  static const String _protocolVersionHeader = 'Acp-Protocol-Version';

  HttpClient? _client;
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
    _stopping = false;
    _client ??= HttpClient();
    final controller = StreamChannelController<String>();
    _controller = controller;
    _outboundSubscription = controller.local.stream.listen((line) {
      unawaited(_sendLine(line));
    }, onError: controller.local.sink.addError);
  }

  Future<void> _sendLine(String line) async {
    final client = _client;
    if (_stopping || client == null) return;
    _notifyProtocolOut(line);
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

      final request = await client.postUrl(endpoint).timeout(requestTimeout);
      _applyRequestHeaders(
        request,
        contentType: ContentType.json,
        sessionId: sessionId,
      );
      request.write(line);
      final response = await request.close().timeout(firstByteTimeout);
      _storeCookies(response.cookies);

      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(requestTimeout);
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
        final sessionId = _sessionIdFromMap(params);
        if (sessionId != null) return sessionId;
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
    _startInboundStream(null);
    _addInboundLine(body);
  }

  void _startInboundStream(String? sessionId) {
    unawaited(
      _ensureInboundStream(sessionId).catchError((
        Object error,
        StackTrace stackTrace,
      ) {
        // _ensureInboundStream has already forwarded this failure to the
        // transport channel.
      }),
    );
  }

  Future<void> _ensureInboundStream(String? sessionId) {
    final connectionId = _connectionId;
    if (connectionId == null || connectionId.isEmpty) {
      throw StateError('ACP HTTP transport is not initialized.');
    }
    final client = _client;
    if (_stopping || client == null) {
      throw StateError('ACP HTTP transport is not started.');
    }
    final key = sessionId ?? '';
    return _streamStartsByKey.putIfAbsent(key, () async {
      try {
        final request = await client.getUrl(endpoint).timeout(requestTimeout);
        _applyRequestHeaders(request, accept: 'text/event-stream');
        request.headers.set('Acp-Connection-Id', connectionId);
        if (sessionId != null) {
          request.headers.set('Acp-Session-Id', sessionId);
        }
        final response = await request.close().timeout(firstByteTimeout);
        _storeCookies(response.cookies);
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw HttpException(
            'ACP HTTP SSE stream failed with ${response.statusCode}: ${response.reasonPhrase}',
            uri: endpoint,
          );
        }
        var streamFailed = false;
        late final StreamSubscription<String> subscription;
        subscription = _sseEvents(_withSseIdleTimeout(response)).listen(
          _handleSseEvent,
          onError: (Object error, StackTrace stackTrace) {
            streamFailed = true;
            if (!_stopping) {
              _controller?.local.sink.addError(error, stackTrace);
            }
          },
          onDone: () {
            _streamStartsByKey.remove(key);
            _streamSubscriptions.remove(subscription);
            if (!_stopping && !streamFailed) {
              _controller?.local.sink.addError(
                StateError(
                  sessionId == null
                      ? 'ACP connection SSE stream closed'
                      : 'ACP session SSE stream closed: $sessionId',
                ),
                StackTrace.current,
              );
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

  Stream<List<int>> _withSseIdleTimeout(Stream<List<int>> response) {
    return response.timeout(
      sseIdleTimeout,
      onTimeout: (sink) {
        sink.addError(
          TimeoutException(
            'ACP SSE stream was idle for $sseIdleTimeout',
            sseIdleTimeout,
          ),
          StackTrace.current,
        );
        sink.close();
      },
    );
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
    _notifyProtocolIn(line);
    _controller?.local.sink.add(line);
  }

  void _notifyProtocolOut(String line) {
    try {
      onProtocolOut?.call(line);
    } catch (error, stackTrace) {
      if (!_stopping) {
        _controller?.local.sink.addError(error, stackTrace);
      }
    }
  }

  void _notifyProtocolIn(String line) {
    try {
      onProtocolIn?.call(line);
    } catch (error, stackTrace) {
      if (!_stopping) {
        _controller?.local.sink.addError(error, stackTrace);
      }
    }
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
        final sessionId = _sessionIdFromResult(decoded);
        if (sessionId != null) {
          _startInboundStream(sessionId);
        }
      }
    }
    final method = decoded['method'];
    if (idKey != null && method is String) {
      final params = decoded['params'];
      final sessionId = params is Map ? _sessionIdFromMap(params) : null;
      if (sessionId != null) {
        _serverRequestSessionsById[idKey] = sessionId;
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

  String? _sessionIdFromResult(Map<String, dynamic> json) {
    final result = json['result'];
    if (result is! Map) return null;
    return _sessionIdFromMap(result) ?? _nonEmptyString(result['id']);
  }

  String? _sessionIdFromMap(Map map) {
    return _nonEmptyString(map['sessionId']) ??
        _nonEmptyString(map['session_id']);
  }

  String? _nonEmptyString(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  @override
  Future<void> stop() async {
    _stopping = true;
    await _outboundSubscription?.cancel();
    _outboundSubscription = null;
    await _terminateConnection();
    _client?.close(force: true);
    _client = null;
    final streamSubscriptions = List<StreamSubscription<String>>.of(
      _streamSubscriptions,
    );
    for (final subscription in streamSubscriptions) {
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
    final client = _client;
    if (client == null) return;
    try {
      final request = await client
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
